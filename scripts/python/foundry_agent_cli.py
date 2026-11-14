"""Azure AI Foundry agent SDK bridge for PowerShell automation."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import Any


def _warn(message: str) -> None:
    print(f"WARNING: {message}", file=sys.stderr)


def _emit_json(payload: dict[str, Any], *, stream: Any | None = None) -> None:
    if stream is None:
        stream = sys.stdout
    json.dump(payload, stream, separators=(",", ":"))
    stream.write("\n")


def _emit_error(message: str, exit_code: int = 1) -> int:
    _emit_json({"error": message}, stream=sys.stderr)
    return exit_code


def _load_sdk():
    try:
        from azure.ai.projects import AIProjectClient
        from azure.ai.projects.models import (
            AgentEndpointConfig,
            FixedRatioVersionSelectionRule,
            MCPTool,
            PromptAgentDefinition,
            PromptAgentDefinitionTextOptions,
            ProtocolConfiguration,
            ResponsesProtocolConfiguration,
            TextResponseFormatJsonObject,
            TextResponseFormatJsonSchema,
            TextResponseFormatText,
            VersionSelector,
        )
        from azure.core.exceptions import HttpResponseError, ResourceNotFoundError, ServiceRequestError
        from azure.identity import DefaultAzureCredential
    except ImportError as exc:  # pragma: no cover - exercised in wrapper/integration paths
        raise RuntimeError(
            "Missing Azure SDK dependency. Install dependencies with "
            "'python -m pip install -r scripts/python/requirements.txt'."
        ) from exc

    return {
        "AIProjectClient": AIProjectClient,
        "AgentEndpointConfig": AgentEndpointConfig,
        "DefaultAzureCredential": DefaultAzureCredential,
        "FixedRatioVersionSelectionRule": FixedRatioVersionSelectionRule,
        "HttpResponseError": HttpResponseError,
        "MCPTool": MCPTool,
        "PromptAgentDefinition": PromptAgentDefinition,
        "PromptAgentDefinitionTextOptions": PromptAgentDefinitionTextOptions,
        "ProtocolConfiguration": ProtocolConfiguration,
        "ResourceNotFoundError": ResourceNotFoundError,
        "ResponsesProtocolConfiguration": ResponsesProtocolConfiguration,
        "ServiceRequestError": ServiceRequestError,
        "TextResponseFormatJsonObject": TextResponseFormatJsonObject,
        "TextResponseFormatJsonSchema": TextResponseFormatJsonSchema,
        "TextResponseFormatText": TextResponseFormatText,
        "VersionSelector": VersionSelector,
    }


def _credential_kwargs(tenant_id: str | None) -> dict[str, Any]:
    kwargs: dict[str, Any] = {}
    if not tenant_id:
        return kwargs

    os.environ["AZURE_TENANT_ID"] = tenant_id
    kwargs["broker_tenant_id"] = tenant_id
    kwargs["interactive_browser_tenant_id"] = tenant_id
    kwargs["shared_cache_tenant_id"] = tenant_id
    kwargs["visual_studio_code_tenant_id"] = tenant_id
    kwargs["workload_identity_tenant_id"] = tenant_id
    return kwargs


def _create_client(
    endpoint: str, tenant_id: str | None, *, runtime: bool = False,
    timeout: float = 30, disable_create_retries: bool = False,
):
    sdk = _load_sdk()
    credential_options = _credential_kwargs(tenant_id)
    if os.environ.get("FOUNDRY_QUALIFICATION_PRIVATE_ROOT"):
        if os.environ.get("AZURE_TOKEN_CREDENTIALS") != "AzureCliCredential":
            raise ValueError("QUAL_IDENTITY_BLOCKED")
        credential_options["require_envvar"] = True
    credential = sdk["DefaultAzureCredential"](**credential_options)
    options = dict(allow_preview=True, retry_total=0, connection_timeout=timeout, read_timeout=timeout) if runtime else {}
    if disable_create_retries:
        options.update(retry_total=0, retry_connect=0, retry_read=0, retry_status=0, logging_enable=False)
    client = sdk["AIProjectClient"](endpoint=endpoint, credential=credential, **options)
    return sdk, credential, client


def _close_if_supported(obj: Any) -> None:
    close = getattr(obj, "close", None)
    if callable(close):
        close()


def _definition_to_sdk_kwargs(payload: dict[str, Any], sdk: dict[str, Any] | None = None) -> dict[str, Any]:
    if sdk is None:
        sdk = _load_sdk()

    def require_object(value: Any, field: str) -> dict[str, Any]:
        if not isinstance(value, dict):
            raise ValueError(f"{field} must be an object.")
        return value

    def require_array(value: Any, field: str) -> list[Any]:
        if not isinstance(value, list):
            raise ValueError(f"{field} must be an array.")
        return value

    def require_string(value: Any, field: str) -> str:
        if not isinstance(value, str) or not value.strip():
            raise ValueError(f"{field} must be a non-empty string.")
        return value

    definition: dict[str, Any] = {}
    payload = dict(payload)

    model = payload.get("model")
    if not model:
        raise ValueError("Payload field 'model' is required.")
    definition["model"] = model

    instructions = payload.get("instructions")
    if instructions is not None:
        definition["instructions"] = instructions

    if "temperature" in payload:
        definition["temperature"] = payload["temperature"]
    if "top_p" in payload:
        definition["top_p"] = payload["top_p"]

    response_format = payload.get("response_format")
    if response_format is not None:
        if not isinstance(response_format, dict):
            raise ValueError("Payload field 'response_format' must be an object.")
        response_type = response_format.get("type")
        if response_type == "text":
            if set(response_format) != {"type"}:
                raise ValueError("response_format.type 'text' does not accept additional fields.")
            sdk_response_format = sdk["TextResponseFormatText"]()
        elif response_type == "json_object":
            if set(response_format) != {"type"}:
                raise ValueError("response_format.type 'json_object' does not accept additional fields.")
            sdk_response_format = sdk["TextResponseFormatJsonObject"]()
        elif response_type == "json_schema":
            required = ("name", "schema")
            missing = [key for key in required if key not in response_format]
            if missing:
                raise ValueError(
                    "response_format.type 'json_schema' requires flat name and schema fields; "
                    f"missing: {', '.join(missing)}."
                )
            if not isinstance(response_format["name"], str) or not response_format["name"]:
                raise ValueError("response_format.name must be a non-empty string.")
            if not isinstance(response_format["schema"], dict):
                raise ValueError("response_format.schema must be an object.")
            if "strict" in response_format and not isinstance(response_format["strict"], bool):
                raise ValueError("response_format.strict must be a boolean.")
            if "description" in response_format and not isinstance(response_format["description"], str):
                raise ValueError("response_format.description must be a string.")
            unexpected = set(response_format) - {"type", "name", "schema", "strict", "description"}
            if unexpected:
                raise ValueError(
                    "Unsupported json_schema response format field(s): "
                    f"{', '.join(sorted(unexpected))}."
                )
            schema_kwargs = {
                key: response_format[key]
                for key in ("name", "schema", "strict", "description")
                if key in response_format
            }
            sdk_response_format = sdk["TextResponseFormatJsonSchema"](**schema_kwargs)
        else:
            raise ValueError(
                f"Unsupported response_format.type '{response_type}'. "
                "azure-ai-projects 2.7.0 supports text, json_object, and json_schema; "
                "omit response_format to use the SDK default."
            )
        definition["text"] = sdk["PromptAgentDefinitionTextOptions"](format=sdk_response_format)

    tools = require_array(payload.get("tools", []), "Payload field 'tools'")
    tool_resources = require_object(payload.get("tool_resources", {}), "Payload field 'tool_resources'")
    mapped_tools: list[Any] = []

    file_search_resources = require_object(
        tool_resources.get("file_search", {}), "tool_resources.file_search"
    )
    azure_ai_search_resources = require_object(
        tool_resources.get("azure_ai_search", {}), "tool_resources.azure_ai_search"
    )
    code_interpreter_resources = require_object(
        tool_resources.get("code_interpreter", {}), "tool_resources.code_interpreter"
    )

    if code_interpreter_resources.get("file_ids"):
        _warn("Ignoring code_interpreter.file_ids because PromptAgentDefinition has no SDK equivalent for them.")

    for position, tool in enumerate(tools):
        require_object(tool, f"Payload tool at index {position}")

        tool_type = tool.get("type")
        if tool_type == "code_interpreter":
            mapped_tools.append({"type": "code_interpreter"})
            continue

        if tool_type == "file_search":
            entry = {"type": "file_search"}
            vector_store_ids = require_array(
                file_search_resources.get("vector_store_ids", []),
                "tool_resources.file_search.vector_store_ids",
            )
            for vector_store_id in vector_store_ids:
                require_string(vector_store_id, "tool_resources.file_search.vector_store_ids entry")
            if vector_store_ids:
                entry["vector_store_ids"] = vector_store_ids
            else:
                _warn("file_search tool had no vector_store_ids in tool_resources; creating tool without attached stores.")
            mapped_tools.append(entry)
            continue

        if tool_type == "azure_ai_search":
            indexes = []
            for index in require_array(
                azure_ai_search_resources.get("indexes", []),
                "tool_resources.azure_ai_search.indexes",
            ):
                require_object(index, "tool_resources.azure_ai_search.indexes entry")
                mapped_index = {}
                for source_key, target_key in (
                    ("index_connection_id", "project_connection_id"),
                    ("index_name", "index_name"),
                    ("query_type", "query_type"),
                    ("top_k", "top_k"),
                    ("filter", "filter"),
                    ("index_asset_id", "index_asset_id"),
                ):
                    if source_key in index and index[source_key] is not None:
                        mapped_index[target_key] = index[source_key]
                if not mapped_index:
                    raise ValueError("tool_resources.azure_ai_search.indexes entry has no supported fields.")
                indexes.append(mapped_index)
            mapped_tools.append({"type": "azure_ai_search", "azure_ai_search": {"indexes": indexes}})
            continue

        if tool_type == "openapi":
            openapi = require_object(tool.get("openapi"), "tool.openapi")
            auth = require_object(openapi.get("auth"), "tool.openapi.auth")
            auth_type = auth.get("type")
            if auth_type == "connection":
                scheme = require_object(auth.get("security_scheme"), "tool.openapi.auth.security_scheme")
                mapped_auth: dict[str, Any] = {
                    "type": "project_connection",
                    "security_scheme": {
                        "project_connection_id": require_string(
                            scheme.get("connection_id"), "tool.openapi.auth.security_scheme.connection_id"
                        )
                    },
                }
            elif auth_type == "managed_identity":
                scheme = require_object(auth.get("security_scheme"), "tool.openapi.auth.security_scheme")
                mapped_auth = {
                    "type": "managed_identity",
                    "security_scheme": {
                        "audience": require_string(
                            scheme.get("audience"), "tool.openapi.auth.security_scheme.audience"
                        )
                    },
                }
            elif auth_type == "anonymous":
                mapped_auth = {"type": "anonymous"}
            else:
                raise ValueError(
                    f"Unsupported OpenAPI auth type '{auth_type}'. "
                    "Expected anonymous, connection, or managed_identity."
                )

            mapped_openapi = {
                "name": require_string(openapi.get("name"), "tool.openapi.name"),
                "spec": require_object(openapi.get("spec"), "tool.openapi.spec"),
                "auth": mapped_auth,
            }
            if openapi.get("description"):
                mapped_openapi["description"] = openapi["description"]
            mapped_tools.append({"type": "openapi", "openapi": mapped_openapi})
            continue

        if tool_type == "function":
            function = require_object(tool.get("function"), "tool.function")
            if "strict" in function and not isinstance(function["strict"], bool):
                raise ValueError("tool.function.strict must be a boolean.")
            mapped_tools.append(
                {
                    "type": "function",
                    "name": require_string(function.get("name"), "tool.function.name"),
                    "description": function.get("description"),
                    "parameters": require_object(function.get("parameters"), "tool.function.parameters"),
                    "strict": function.get("strict", False),
                }
            )
            continue

        if tool_type == "azure_function":
            require_object(tool.get("azure_function"), "tool.azure_function")
            mapped_tools.append(tool)
            continue

        if tool_type == "bing_grounding":
            grounding = require_object(tool.get("bing_grounding"), "tool.bing_grounding")
            mapped_configs = []
            for config in require_array(
                grounding.get("search_configurations", []),
                "tool.bing_grounding.search_configurations",
            ):
                require_object(config, "tool.bing_grounding.search_configurations entry")
                mapped_config = {}
                for source_key, target_key in (
                    ("connection_id", "project_connection_id"),
                    ("count", "count"),
                    ("market", "market"),
                    ("set_lang", "set_lang"),
                    ("freshness", "freshness"),
                ):
                    if source_key in config and config[source_key] is not None:
                        mapped_config[target_key] = config[source_key]
                if not mapped_config:
                    raise ValueError("tool.bing_grounding.search_configurations entry has no supported fields.")
                mapped_configs.append(mapped_config)
            mapped_tools.append({"type": "bing_grounding", "bing_grounding": {"search_configurations": mapped_configs}})
            continue

        if tool_type == "mcp":
            require_approval = tool.get("require_approval")
            if require_approval is not None and (
                not isinstance(require_approval, str) or require_approval not in {"always", "never"}
            ):
                raise ValueError(
                    f"Unsupported MCP require_approval '{require_approval}'. Expected 'always' or 'never'."
                )
            unexpected = set(tool) - {
                "type",
                "server_label",
                "server_url",
                "allowed_tools",
                "require_approval",
            }
            if unexpected:
                raise ValueError(
                    f"Unsupported MCP tool field(s): {', '.join(sorted(unexpected))}."
                )
            for key in ("server_label", "server_url"):
                require_string(tool.get(key), f"tool.mcp.{key}")
            if "allowed_tools" in tool:
                for allowed_tool in require_array(tool["allowed_tools"], "tool.mcp.allowed_tools"):
                    require_string(allowed_tool, "tool.mcp.allowed_tools entry")
            mapped_mcp = {
                key: tool[key]
                for key in ("server_label", "server_url", "allowed_tools", "require_approval")
                if key in tool
            }
            mapped_tools.append(sdk["MCPTool"](**mapped_mcp))
            continue

        raise ValueError(f"Unsupported tool type '{tool_type}' at index {position}.")

    if mapped_tools:
        definition["tools"] = mapped_tools

    if payload.get("name"):
        _warn("Ignoring payload field 'name'; the logical agent name is supplied separately.")

    handled = {
        "description",
        "instructions",
        "metadata",
        "model",
        "name",
        "response_format",
        "temperature",
        "tool_resources",
        "tools",
        "top_p",
    }
    for key in payload:
        if key not in handled:
            _warn(f"Ignoring unsupported payload field '{key}'.")

    return definition


def _read_json_stdin() -> dict[str, Any]:
    raw = sys.stdin.read()
    if not raw.strip():
        raise ValueError("Expected JSON payload on stdin.")
    payload = json.loads(raw)
    if not isinstance(payload, dict):
        raise ValueError("Expected a JSON object on stdin.")
    return payload


def _handle_preflight(args: argparse.Namespace) -> dict[str, Any]:
    sdk, credential, client = _create_client(args.endpoint, args.tenant_id)
    try:
        next(iter(client.deployments.list()), None)
        return {"ok": True}
    finally:
        _close_if_supported(client)
        _close_if_supported(credential)


def _active_version(agent: Any, expected: str | None = None) -> str:
    endpoint = getattr(agent, "agent_endpoint", None)
    details = endpoint.as_dict() if endpoint is not None and hasattr(endpoint, "as_dict") else {}
    rules = details.get("version_selector", {}).get("version_selection_rules", [])
    protocols = details.get("protocol_configuration", {})
    valid = (
        getattr(agent, "state", None) == "enabled"
        and getattr(agent, "configuration_state", None) == "enabled"
        and isinstance(protocols, dict) and isinstance(protocols.get("responses"), dict)
        and isinstance(rules, list) and len(rules) == 1
        and isinstance(rules[0], dict)
        and rules[0].get("type") == "FixedRatio"
        and type(rules[0].get("traffic_percentage")) is int
        and rules[0]["traffic_percentage"] == 100
        and isinstance(rules[0].get("agent_version"), str)
        and bool(rules[0]["agent_version"].strip())
        and rules[0]["agent_version"].lower() not in ("latest", "default", "*")
    )
    if not valid:
        raise ValueError(
            "Unsupported live endpoint: require an enabled Responses endpoint with one concrete "
            f"FixedRatio selector at 100%. Explicitly pin a known version with promote-version. Routing: {details!r}"
        )
    active = rules[0]["agent_version"]
    if expected is not None and active != expected:
        raise ValueError(f"Active selector mismatch: expected '{expected}', found '{active}'.")
    return active


def _handle_get_agent(args: argparse.Namespace) -> dict[str, Any]:
    sdk, credential, client = _create_client(args.endpoint, args.tenant_id)
    try:
        try:
            agent = client.agents.get(agent_name=args.agent_name)
        except sdk["ResourceNotFoundError"]:
            return {"found": False}

        latest_version = None
        versions = getattr(agent, "versions", None)
        latest = getattr(versions, "latest", None)
        if latest is not None:
            latest_version = getattr(latest, "version", None)
        active_version = _active_version(agent)

        result: dict[str, Any] = {
            "found": True,
            "id": agent.id,
            "name": agent.name,
            "latestVersion": latest_version,
            "activeVersion": active_version,
            "state": agent.state,
        }

        if getattr(agent, "agent_endpoint", None) is not None and hasattr(agent.agent_endpoint, "as_dict"):
            result["agentEndpoint"] = agent.agent_endpoint.as_dict()

        if active_version:
            version = client.agents.get_version(agent_name=args.agent_name, agent_version=active_version)
            result["versionId"] = version.id
            result["version"] = version.version
            if getattr(version, "description", None):
                result["description"] = version.description
            if getattr(version, "metadata", None):
                result["metadata"] = version.metadata
            if getattr(version, "definition", None) is not None and hasattr(version.definition, "as_dict"):
                definition = version.definition.as_dict()
                result["definition"] = definition
                for key in ("instructions", "model", "reasoning", "structured_inputs", "text", "tools", "top_p", "temperature"):
                    if key in definition:
                        result[key] = definition[key]

        return result
    finally:
        _close_if_supported(client)
        _close_if_supported(credential)


def _handle_create_version(args: argparse.Namespace) -> dict[str, Any]:
    payload = _read_json_stdin()
    options = {"disable_create_retries": True} if getattr(args, "disable_create_retries", False) else {}
    sdk, credential, client = _create_client(args.endpoint, args.tenant_id, **options)
    try:
        definition_kwargs = _definition_to_sdk_kwargs(payload, sdk)
        definition = sdk["PromptAgentDefinition"](**definition_kwargs)
        create_kwargs: dict[str, Any] = {
            "agent_name": args.agent_name,
            "definition": definition,
        }

        metadata = payload.get("metadata")
        if metadata is not None:
            if not isinstance(metadata, dict) or any(
                not isinstance(key, str) or not isinstance(value, str)
                for key, value in metadata.items()
            ):
                raise ValueError("Payload field 'metadata' must be an object with string keys and values.")
            create_kwargs["metadata"] = metadata

        description = payload.get("description")
        if description is not None:
            if not isinstance(description, str):
                raise ValueError("Payload field 'description' must be a string.")
            create_kwargs["description"] = description

        created = client.agents.create_version(**create_kwargs)

        result = {
            "id": created.id,
            "name": created.name,
            "version": created.version,
        }

        try:
            agent = client.agents.get(agent_name=args.agent_name)
            result["agentId"] = agent.id
        except sdk["ResourceNotFoundError"]:
            pass

        return result
    finally:
        _close_if_supported(client)
        _close_if_supported(credential)


def _handle_promote_version(args: argparse.Namespace) -> dict[str, Any]:
    sdk, credential, client = _create_client(args.endpoint, args.tenant_id)
    try:
        agent = client.agents.get(agent_name=args.agent_name)
        endpoint = getattr(agent, "agent_endpoint", None)
        endpoint_fields = endpoint.as_dict() if endpoint is not None else {}
        if getattr(agent, "state", None) != "enabled" or getattr(agent, "configuration_state", None) != "enabled":
            raise ValueError("Cannot activate a disabled agent.")
        if not isinstance(endpoint_fields.get("protocol_configuration", {}).get("responses"), dict):
            raise ValueError("Cannot activate an endpoint without Responses support.")
        # Preserve authorization schemes and all unrelated per-protocol settings.
        endpoint_fields["version_selector"] = sdk["VersionSelector"](
                version_selection_rules=[
                    sdk["FixedRatioVersionSelectionRule"](agent_version=args.agent_version, traffic_percentage=100)
                ]
            ).as_dict()
        endpoint_config = sdk["AgentEndpointConfig"](endpoint_fields)
        client.agents.update_details(agent_name=args.agent_name, agent_endpoint=endpoint_config)
        verified = client.agents.get(agent_name=args.agent_name)
        return {"ok": True, "activeVersion": _active_version(verified, args.agent_version)}
    finally:
        _close_if_supported(client)
        _close_if_supported(credential)


def _handle_invoke_agent(args: argparse.Namespace) -> dict[str, Any]:
    payload = _read_json_stdin()
    prompt = payload.get("prompt")
    timeout = payload.get("timeoutSeconds", 120)
    interval = payload.get("pollIntervalSeconds", 2)
    if not isinstance(prompt, str) or not prompt.strip():
        raise ValueError("prompt must be nonempty text.")
    if type(timeout) not in (int, float) or not 1 <= timeout <= 600:
        raise ValueError("timeoutSeconds must be between 1 and 600.")
    if type(interval) not in (int, float) or not 0 < interval <= timeout:
        raise ValueError("pollIntervalSeconds must be positive and no greater than the timeout.")
    start = time.monotonic()
    deadline = start + timeout
    work_deadline = deadline - min(5, timeout / 10)

    def remaining(end: float = work_deadline) -> float:
        seconds = end - time.monotonic()
        if seconds <= 0:
            raise TimeoutError("Agent invocation exceeded its overall deadline.")
        return seconds

    sdk, credential, client = _create_client(args.endpoint, args.tenant_id, runtime=True, timeout=remaining())
    openai_client = None
    conversation_id = None
    conversation_attempted = False
    response_id = None
    qualification = bool(os.environ.get("FOUNDRY_QUALIFICATION_PRIVATE_ROOT"))
    result: dict[str, Any] = {
        "Output": None, "Status": "failed", "Error": None,
        "ConversationId": None, "ResponseId": None,
        "AgentName": args.agent_name, "ServiceVersion": args.agent_version,
    }
    try:
        def verify_route() -> None:
            seconds = remaining()
            agent = client.agents.get(agent_name=args.agent_name, connection_timeout=seconds, read_timeout=seconds)
            _active_version(agent, args.agent_version)

        verify_route()
        openai_client = client.get_openai_client(agent_name=args.agent_name, timeout=remaining(), max_retries=0)
        conversation_attempted = True
        conversation = openai_client.conversations.create(timeout=remaining())
        conversation_id = conversation.id
        if not conversation_id:
            raise ValueError("Conversations API returned no conversation id.")
        response = openai_client.responses.create(conversation=conversation_id, input=prompt, timeout=remaining())
        response_id = response.id
        if not response_id:
            raise ValueError("Responses API returned no response id.")
        while response.status in ("queued", "in_progress"):
            time.sleep(min(interval, remaining()))
            response = openai_client.responses.retrieve(response_id, timeout=remaining())
        result["Status"] = response.status
        if response.status == "completed":
            supported_output = {
                "message", "reasoning", "file_search_call", "web_search_call",
                "code_interpreter_call", "image_generation_call", "mcp_call",
                "mcp_list_tools", "compaction",
            }
            unresolved = [
                item for item in response.output
                if getattr(item, "type", "") not in supported_output
                or getattr(item, "status", None) in ("in_progress", "incomplete", "calling")
            ]
            output = response.output_text
            if unresolved:
                result.update(Status="requires_action", Error="Unresolved client tool or approval request; CI cannot supply tool results.")
            elif not isinstance(output, str) or not output.strip():
                result.update(Status="failed", Error="Completed response has no usable text.")
            else:
                result["Output"] = output
        else:
            result["Error"] = f"Response ended in '{response.status}': {getattr(response, 'error', None) or getattr(response, 'incomplete_details', None)}"
        verify_route()
    except TimeoutError as exc:
        result.update(Status="timeout", Output=None, Error=str(exc))
    except Exception as exc:
        result.update(Status="failed", Output=None, Error=str(exc))
    finally:
        primary_status = result["Status"]
        cleanup_failures = []
        disposition = "unverified" if conversation_attempted else "not-created"
        if conversation_id and openai_client:
            try:
                openai_client.conversations.delete(conversation_id, timeout=remaining(deadline))
                disposition = "deleted"
            except Exception as exc:
                disposition = "failed"
                cleanup_failures.append("conversation-delete-failed")
                if not qualification:
                    _warn(f"Conversation {conversation_id} cleanup failed: {exc}")
        elif conversation_attempted:
            cleanup_failures.append("conversation-creation-unverified")
        resources_closed = True
        for name, resource in (("openai-client", openai_client), ("project-client", client), ("credential", credential)):
            try:
                _close_if_supported(resource)
            except Exception as exc:
                resources_closed = False
                cleanup_failures.append(f"{name}-close-failed")
                if not qualification:
                    _warn(f"Client cleanup failed: {exc}")
        if qualification:
            verified = not cleanup_failures and disposition in ("deleted", "not-created") and resources_closed
            result.update(
                PrimaryStatus=primary_status,
                InvocationCleanup={
                    "verified": verified, "conversationDisposition": disposition,
                    "resourcesClosed": resources_closed, "failureCategories": cleanup_failures,
                },
            )
            if not verified:
                result.update(Status="failed" if primary_status == "completed" else primary_status, Output=None)
                if not result["Error"]:
                    result["Error"] = "QUAL_INVOCATION_CLEANUP_FAILED"
        result.update(ConversationId=conversation_id, ResponseId=response_id, LatencyMs=int((time.monotonic() - start) * 1000))
    return result


def _handle_qualification_login(_args: argparse.Namespace) -> dict[str, Any]:
    # In-process invocation avoids an OS credential argument, not CLI/MSAL disk caching.
    # The workflow owns the isolated credential-bearing directory and its final teardown.
    import contextlib
    import io
    import urllib.parse
    import urllib.request

    from azure.cli.core import get_default_cli

    try:
        url = os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"]
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode({"audience": "api://AzureADTokenExchange"})
        request = urllib.request.Request(
            url, headers={"Authorization": "Bearer " + os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]})
        with urllib.request.urlopen(request, timeout=30) as response:
            federated_token = json.load(response)["value"]
        if not isinstance(federated_token, str) or not federated_token:
            raise ValueError("Missing OIDC response")
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            cli = get_default_cli()
            status = cli.invoke([
                "login", "--service-principal", "--username", os.environ["AZURE_CLIENT_ID"],
                "--tenant", os.environ["AZURE_TENANT_ID"], "--federated-token", federated_token,
                "--only-show-errors", "--output", "none",
            ])
            if status != 0:
                raise ValueError("Login failed")
            status = cli.invoke([
                "account", "set", "--subscription", os.environ["AZURE_SUBSCRIPTION_ID"],
                "--only-show-errors",
            ])
            if status != 0:
                raise ValueError("Subscription selection failed")
        return {"authenticated": True}
    except Exception:
        raise RuntimeError("QUAL_IDENTITY_BLOCKED") from None


def _qualification_snapshot(client, sdk) -> dict[str, Any]:
    model = os.environ["QUAL_MODEL_DEPLOYMENT"]
    matched = any(getattr(deployment, "name", None) == model for deployment in client.deployments.list())
    if not matched:
        raise ValueError("QUAL_MODEL_BLOCKED")
    name = os.environ["QUAL_AGENT_NAME"]
    try:
        agent = client.agents.get(agent_name=name)
    except sdk["ResourceNotFoundError"]:
        return {"found": False, "modelMatched": True}
    versions = sorted([
        {"id": version.id, "version": version.version, "metadata": version.metadata or {}}
        for version in client.agents.list_versions(agent_name=name)
    ], key=lambda version: version["id"])
    active = _active_version(agent)
    active_details = client.agents.get_version(agent_name=name, agent_version=active)
    active_definition = active_details.definition.as_dict()
    active_definition["tools"] = active_definition.get("tools") or []
    return {
        "found": True, "modelMatched": True, "id": agent.id, "name": agent.name,
        "activeVersion": active, "versions": versions,
        "activeDefinition": active_definition,
    }


def _handle_qualification_target(args: argparse.Namespace) -> dict[str, Any]:
    if os.environ.get("AZURE_TOKEN_CREDENTIALS") != "AzureCliCredential":
        raise ValueError("QUAL_IDENTITY_BLOCKED")
    sdk, credential, client = _create_client(
        os.environ["QUAL_PROJECT_ENDPOINT"], os.environ["AZURE_TENANT_ID"], disable_create_retries=True)
    try:
        snapshot = _qualification_snapshot(client, sdk)
        if args.command == "qualification-snapshot":
            return snapshot
        expected = _read_json_stdin()
        if not snapshot["found"] or not expected.get("found") or snapshot != expected:
            raise ValueError("QUAL_CLEANUP_BLOCKED")
        if not snapshot["versions"] or len(snapshot["versions"]) > 3 or any(
            version["metadata"].get("qualification_experiment") != os.environ["QUAL_EXPERIMENT_ID"]
            for version in snapshot["versions"]
        ):
            raise ValueError("QUAL_CLEANUP_BLOCKED")
        # No force-delete or unrelated resource enumeration.
        client.agents.delete(agent_name=os.environ["QUAL_AGENT_NAME"])
        try:
            client.agents.get(agent_name=os.environ["QUAL_AGENT_NAME"])
        except sdk["ResourceNotFoundError"]:
            return {"absent": True, "deleted": snapshot}
        raise ValueError("QUAL_CLEANUP_BLOCKED")
    finally:
        _close_if_supported(client)
        _close_if_supported(credential)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Azure AI Foundry agent SDK wrapper")
    subparsers = parser.add_subparsers(dest="command", required=True)

    def add_common_arguments(subparser: argparse.ArgumentParser, *, include_agent_name: bool = False) -> None:
        subparser.add_argument("--endpoint", required=True)
        subparser.add_argument(
            "--api-version",
            required=True,
            help="Retained REST apiVersion from environment configuration; the SDK selects its own service version.",
        )
        subparser.add_argument("--tenant-id")
        if include_agent_name:
            subparser.add_argument("--agent-name", required=True)

    preflight = subparsers.add_parser("preflight")
    add_common_arguments(preflight)
    preflight.set_defaults(handler=_handle_preflight)

    get_agent = subparsers.add_parser("get-agent")
    add_common_arguments(get_agent, include_agent_name=True)
    get_agent.set_defaults(handler=_handle_get_agent)

    create_version = subparsers.add_parser("create-version")
    add_common_arguments(create_version, include_agent_name=True)
    create_version.add_argument("--disable-create-retries", action="store_true")
    create_version.set_defaults(handler=_handle_create_version)

    promote_version = subparsers.add_parser("promote-version")
    add_common_arguments(promote_version, include_agent_name=True)
    promote_version.add_argument("--agent-version", required=True)
    promote_version.set_defaults(handler=_handle_promote_version)

    invoke_agent = subparsers.add_parser("invoke-agent")
    add_common_arguments(invoke_agent, include_agent_name=True)
    invoke_agent.add_argument("--agent-version", required=True)
    invoke_agent.set_defaults(handler=_handle_invoke_agent)

    login = subparsers.add_parser("qualification-login")
    login.set_defaults(handler=_handle_qualification_login)
    for command in ("qualification-snapshot", "qualification-delete"):
        qualification = subparsers.add_parser(command)
        qualification.set_defaults(handler=_handle_qualification_target)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    try:
        result = args.handler(args)
        _emit_json(result)
        return 0
    except RuntimeError as exc:
        return _emit_error(str(exc))
    except json.JSONDecodeError as exc:
        return _emit_error(f"Invalid JSON payload: {exc.msg}")
    except ValueError as exc:
        return _emit_error(str(exc))
    except Exception as exc:  # pragma: no cover - exercised via live SDK/integration behavior
        sdk = None
        try:
            sdk = _load_sdk()
        except RuntimeError:
            sdk = None

        if sdk and isinstance(exc, (sdk["HttpResponseError"], sdk["ServiceRequestError"])):
            return _emit_error(str(exc))

        return _emit_error(str(exc))


if __name__ == "__main__":
    raise SystemExit(main())
