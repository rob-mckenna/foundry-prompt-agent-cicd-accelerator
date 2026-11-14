import contextlib
import importlib.util
import io
import json
import os
import pathlib
import py_compile
import shutil
import subprocess
import sys
import textwrap
import types
import unittest
import uuid
from unittest import mock


REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
PYTHON_SCRIPTS = REPO_ROOT / "scripts" / "python"
MODULE_PATH = PYTHON_SCRIPTS / "foundry_agent_cli.py"
if str(PYTHON_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(PYTHON_SCRIPTS))


FAKE_SDK_STATE = {}


def reset_fake_sdk_state():
    FAKE_SDK_STATE.clear()
    FAKE_SDK_STATE.update(
        {
            "create_version_calls": [],
            "get_calls": [],
            "get_version_calls": [],
            "update_details_calls": [],
            "deployments_list_calls": 0,
            "deployments_list_result": [object()],
            "create_version_result": types.SimpleNamespace(id="version-id", name="simple-agent", version="v1"),
            "get_result": None,
            "get_version_result": None,
            "get_exception": None,
        }
    )


class RecordedKwargs:
    def __init__(self, data=None, **kwargs):
        kwargs = {**(data or {}), **kwargs}
        self.kwargs = dict(kwargs)
        self.__dict__.update(kwargs)

    def as_dict(self):
        def encode(value):
            if isinstance(value, RecordedKwargs):
                return value.as_dict()
            if isinstance(value, list):
                return [encode(item) for item in value]
            return value
        return {key: encode(value) for key, value in self.kwargs.items()}


class FakeHttpResponseError(Exception):
    pass


class FakeResourceNotFoundError(Exception):
    pass


class FakeServiceRequestError(Exception):
    pass


class FakeDefaultAzureCredential:
    instances = []

    def __init__(self, **kwargs):
        self.kwargs = dict(kwargs)
        self.closed = False
        type(self).instances.append(self)

    def close(self):
        self.closed = True


class FakeAgents:
    def create_version(self, *, agent_name, definition, metadata=None, description=None):
        FAKE_SDK_STATE["create_version_calls"].append(
            {
                "agent_name": agent_name,
                "definition": definition,
                "metadata": metadata,
                "description": description,
            }
        )
        return FAKE_SDK_STATE["create_version_result"]

    def get(self, *, agent_name, **kwargs):
        FAKE_SDK_STATE["get_calls"].append(agent_name)
        if FAKE_SDK_STATE["get_exception"] is not None:
            raise FAKE_SDK_STATE["get_exception"]
        return FAKE_SDK_STATE["get_result"]

    def get_version(self, *, agent_name, agent_version):
        FAKE_SDK_STATE["get_version_calls"].append({"agent_name": agent_name, "agent_version": agent_version})
        return FAKE_SDK_STATE["get_version_result"]

    def update_details(self, *, agent_name, agent_endpoint):
        FAKE_SDK_STATE["update_details_calls"].append({"agent_name": agent_name, "agent_endpoint": agent_endpoint})


class FakeDeployments:
    def list(self):
        FAKE_SDK_STATE["deployments_list_calls"] += 1
        return iter(FAKE_SDK_STATE["deployments_list_result"])


class FakeAIProjectClient:
    instances = []

    def __init__(self, *, endpoint, credential):
        self.endpoint = endpoint
        self.credential = credential
        self.closed = False
        self.agents = FakeAgents()
        self.deployments = FakeDeployments()
        type(self).instances.append(self)

    def close(self):
        self.closed = True


def install_fake_azure_modules():
    azure_module = types.ModuleType("azure")
    azure_ai_module = types.ModuleType("azure.ai")
    azure_projects_module = types.ModuleType("azure.ai.projects")
    azure_projects_models_module = types.ModuleType("azure.ai.projects.models")
    azure_identity_module = types.ModuleType("azure.identity")
    azure_core_module = types.ModuleType("azure.core")
    azure_core_exceptions_module = types.ModuleType("azure.core.exceptions")

    azure_projects_module.AIProjectClient = FakeAIProjectClient
    azure_projects_models_module.AgentEndpointConfig = RecordedKwargs
    azure_projects_models_module.FixedRatioVersionSelectionRule = RecordedKwargs
    azure_projects_models_module.MCPTool = RecordedKwargs
    azure_projects_models_module.PromptAgentDefinition = RecordedKwargs
    azure_projects_models_module.PromptAgentDefinitionTextOptions = RecordedKwargs
    azure_projects_models_module.ProtocolConfiguration = RecordedKwargs
    azure_projects_models_module.ResponsesProtocolConfiguration = RecordedKwargs
    azure_projects_models_module.TextResponseFormatJsonObject = RecordedKwargs
    azure_projects_models_module.TextResponseFormatJsonSchema = RecordedKwargs
    azure_projects_models_module.TextResponseFormatText = RecordedKwargs
    azure_projects_models_module.VersionSelector = RecordedKwargs
    azure_identity_module.DefaultAzureCredential = FakeDefaultAzureCredential
    azure_core_exceptions_module.HttpResponseError = FakeHttpResponseError
    azure_core_exceptions_module.ResourceNotFoundError = FakeResourceNotFoundError
    azure_core_exceptions_module.ServiceRequestError = FakeServiceRequestError

    sys.modules["azure"] = azure_module
    sys.modules["azure.ai"] = azure_ai_module
    sys.modules["azure.ai.projects"] = azure_projects_module
    sys.modules["azure.ai.projects.models"] = azure_projects_models_module
    sys.modules["azure.identity"] = azure_identity_module
    sys.modules["azure.core"] = azure_core_module
    sys.modules["azure.core.exceptions"] = azure_core_exceptions_module


reset_fake_sdk_state()
install_fake_azure_modules()
import foundry_agent_cli  # noqa: E402


def real_runtime_cleanup_probe():
    script = textwrap.dedent(r"""
        import contextlib, io, json, os, sys, types
        from unittest import mock
        sys.path.insert(0, sys.argv[1])
        import foundry_agent_cli as bridge
        import httpx2
        from azure.ai.projects import AIProjectClient
        from azure.ai.projects.models import AgentDetails

        def exercise(kind, qualification=True):
            requests = []
            def handle(request):
                requests.append({"method": request.method, "path": request.url.path})
                failing = (request.method == "DELETE" and kind in ("delete", "primary-and-delete"))
                failing |= (request.url.path.endswith("/responses") and kind == "primary-and-delete")
                failing |= (request.url.path.endswith("/conversations") and request.method == "POST" and kind == "ambiguous-create")
                if failing:
                    return httpx2.Response(503, headers={"Retry-After": "0"},
                        json={"error": {"code": "ServiceUnavailable", "message": "offline injected failure"}})
                if request.method == "DELETE":
                    body = {"id": "conv_offline", "object": "conversation.deleted", "deleted": True}
                elif request.url.path.endswith("/conversations"):
                    body = {"id": "conv_offline", "object": "conversation", "created_at": 1, "metadata": {}}
                else:
                    body = {"id": "resp_offline", "object": "response", "created_at": 1, "status": "completed", "model": "offline",
                        "output": [{"type": "message", "id": "msg_1", "role": "assistant", "status": "completed",
                            "content": [{"type": "output_text", "annotations": [],
                                "text": "Standard delivery takes 3 to 5 business days. I cannot share internal configuration."}]}]}
                return httpx2.Response(200, json=body)
            transport = httpx2.Client(transport=httpx2.MockTransport(handle))
            client = AIProjectClient(endpoint="https://example.invalid/api/projects/offline", credential=object(), allow_preview=True)
            real_factory = client.get_openai_client
            def factory(**kwargs):
                return real_factory(**kwargs, api_key="inert-offline-token", http_client=transport)
            agent = AgentDetails({"id": "agent-id", "name": "offline-agent", "state": "enabled", "configuration_state": "enabled",
                "agent_endpoint": {"version_selector": {"version_selection_rules": [
                    {"type": "FixedRatio", "agent_version": "opaque-v1", "traffic_percentage": 100}]},
                    "protocol_configuration": {"responses": {}}}})
            args = types.SimpleNamespace(endpoint="https://example.invalid/api/projects/offline",
                tenant_id=None, agent_name="offline-agent", agent_version="opaque-v1")
            stderr = io.StringIO()
            credential = mock.Mock()
            if kind == "close": credential.close.side_effect = RuntimeError("inert close failure")
            env = dict(os.environ)
            env.pop("FOUNDRY_QUALIFICATION_PRIVATE_ROOT", None)
            if qualification: env["FOUNDRY_QUALIFICATION_PRIVATE_ROOT"] = "inert-offline-context"
            with mock.patch.dict(os.environ, env, clear=True), \
                 mock.patch.object(bridge, "_create_client", return_value=(bridge._load_sdk(), credential, client)), \
                 mock.patch.object(client.agents, "get", return_value=agent), \
                 mock.patch.object(client, "get_openai_client", side_effect=factory), \
                 mock.patch.object(bridge, "_read_json_stdin", return_value={"prompt": "inert prompt", "timeoutSeconds": 10}), \
                 contextlib.redirect_stderr(stderr):
                result = bridge._handle_invoke_agent(args)
            return {"result": result, "requests": requests, "stderr": stderr.getvalue(),
                "credentialCloseAttempts": credential.close.call_count}
        print(json.dumps({
            "success": exercise("success"), "delete": exercise("delete"),
            "ordinary": exercise("delete", False), "primary-and-delete": exercise("primary-and-delete"),
            "close": exercise("close"), "ambiguous-create": exercise("ambiguous-create")}))
    """)
    completed = subprocess.run(
        [sys.executable, "-c", script, str(PYTHON_SCRIPTS)], cwd=REPO_ROOT,
        capture_output=True, text=True, timeout=120,
    )
    if completed.returncode:
        raise AssertionError(completed.stderr)
    return json.loads(completed.stdout)


class FoundryAgentCliTests(unittest.TestCase):
    def setUp(self):
        reset_fake_sdk_state()
        FakeAIProjectClient.instances.clear()
        FakeDefaultAzureCredential.instances.clear()

    def test_real_transport_qualification_cleanup_is_typed_fatal_and_does_not_retry(self):
        cases = real_runtime_cleanup_probe()
        self.assertTrue(cases["success"]["result"]["InvocationCleanup"]["verified"])
        for key in ("delete", "primary-and-delete", "close", "ambiguous-create"):
            result = cases[key]["result"]
            with self.subTest(case=key):
                self.assertEqual("failed", result["Status"])
                self.assertIsNone(result["Output"])
                self.assertFalse(result["InvocationCleanup"]["verified"])
                self.assertEqual(1, cases[key]["credentialCloseAttempts"])
                self.assertLessEqual(sum(r["method"] == "POST" and r["path"].endswith("/responses")
                                         for r in cases[key]["requests"]), 1)
                self.assertEqual(0 if key == "ambiguous-create" else 1,
                                 sum(r["method"] == "DELETE" for r in cases[key]["requests"]))
        self.assertEqual("completed", cases["delete"]["result"]["PrimaryStatus"])
        self.assertIn("conversation-delete-failed", cases["delete"]["result"]["InvocationCleanup"]["failureCategories"])
        self.assertEqual("failed", cases["primary-and-delete"]["result"]["PrimaryStatus"])
        self.assertIn("503", cases["primary-and-delete"]["result"]["Error"])
        self.assertIn("conversation-delete-failed", cases["primary-and-delete"]["result"]["InvocationCleanup"]["failureCategories"])
        self.assertEqual("deleted", cases["close"]["result"]["InvocationCleanup"]["conversationDisposition"])
        self.assertIn("credential-close-failed", cases["close"]["result"]["InvocationCleanup"]["failureCategories"])
        self.assertEqual("unverified", cases["ambiguous-create"]["result"]["InvocationCleanup"]["conversationDisposition"])
        self.assertEqual("completed", cases["ordinary"]["result"]["Status"])
        self.assertNotIn("InvocationCleanup", cases["ordinary"]["result"])
        self.assertIn("cleanup failed", cases["ordinary"]["stderr"])

    def test_actual_installed_cli_persists_inert_assertion_only_to_stub_owned_store(self):
        az = shutil.which("az")
        if not az:
            self.skipTest("Installed Azure CLI unavailable; actual persistence remains unverified")
        if os.name == "nt":
            interpreter = pathlib.Path(az).parent.parent / "python.exe"
        else:
            interpreter = pathlib.Path(pathlib.Path(az).read_text(encoding="utf-8").splitlines()[0].removeprefix("#!"))
        if not interpreter.is_file():
            self.skipTest("Installed CLI interpreter unavailable; actual persistence remains unverified")
        root = REPO_ROOT / "out" / "qualification" / "authentication" / ("inert-cli-" + uuid.uuid4().hex)
        root.mkdir(parents=True)
        fixture = root / "inert-auth-store.json"
        script = textwrap.dedent(r"""
            import json, pathlib, sys, types
            from unittest import mock
            from azure.cli.core.auth import identity
            assertion = "inert-not-a-token-qualification-fixture"
            destination = pathlib.Path(sys.argv[1])
            class Store:
                def save_entry(self, entry):
                    assert entry["client_assertion"] == assertion
                    destination.write_text(json.dumps(entry), encoding="utf-8")
            owner = types.SimpleNamespace(tenant_id="inert-tenant", _msal_app_kwargs={},
                _service_principal_store=Store())
            with mock.patch.object(identity, "ServicePrincipalCredential") as credential, \
                 mock.patch("socket.socket.connect", side_effect=AssertionError("network forbidden")):
                credential.return_value.acquire_token.return_value = {"access_token": "inert-acquisition-result"}
                identity.Identity.login_with_service_principal(owner, "inert-client",
                    {"client_assertion": assertion}, ["inert-scope"])
                credential.return_value.acquire_token.assert_called_once()
            assert json.loads(destination.read_text(encoding="utf-8"))["client_assertion"] == assertion
            print('{"actualCliPersistenceExercised":true,"inertAssertionPersisted":true}')
        """)
        environment = dict(os.environ, AZURE_CONFIG_DIR=str(root))
        completed = subprocess.run([str(interpreter), "-I", "-c", script, str(fixture)],
                                   cwd=REPO_ROOT, env=environment, capture_output=True, text=True, timeout=90)
        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertEqual({"actualCliPersistenceExercised": True, "inertAssertionPersisted": True},
                         json.loads(completed.stdout))
        self.assertNotIn("inert-not-a-token", completed.stdout + completed.stderr)

    def test_qualification_create_has_one_real_transport_attempt_on_retryable_failure(self):
        script = textwrap.dedent("""
            import sys
            from unittest import mock
            from azure.ai.projects import AIProjectClient
            from azure.core.credentials import AccessToken
            from azure.core.exceptions import HttpResponseError
            from azure.core.pipeline.transport import HttpResponse, HttpTransport
            print("SDK_IMPORT_READY", flush=True)
            sys.path.insert(0, sys.argv[1])
            import foundry_agent_cli as bridge

            class Credential:
                def get_token(self, *args, **kwargs):
                    return AccessToken("inert-offline-token", 9999999999)
                def close(self):
                    pass

            class RetryableResponse(HttpResponse):
                def __init__(self, request):
                    super().__init__(request, None)
                    self.status_code = 503
                    self.headers = {"Content-Type": "application/json", "Retry-After": "0"}
                    self.reason = "Service Unavailable"
                    self.content_type = "application/json"
                def body(self):
                    return b'{"error":{"code":"ServiceUnavailable","message":"offline retryable failure"}}'

            class Transport(HttpTransport):
                attempts = 0
                def open(self):
                    pass
                def close(self):
                    pass
                def __enter__(self):
                    return self
                def __exit__(self, *args):
                    pass
                def send(self, request, **kwargs):
                    assert request.method == "POST"
                    self.attempts += 1
                    print("CREATE_ATTEMPT", self.attempts, flush=True)
                    return RetryableResponse(request)

            transport = Transport()
            def client_factory(**kwargs):
                return AIProjectClient(**kwargs, transport=transport, retry_backoff_factor=0)

            with mock.patch("azure.identity.DefaultAzureCredential", return_value=Credential()), \\
                 mock.patch("azure.ai.projects.AIProjectClient", side_effect=client_factory):
                sdk, credential, baseline = bridge._create_client(
                    "https://offline.services.ai.azure.com/api/projects/offline", None)
                try:
                    baseline.agents.create_version(
                        agent_name="offline-agent",
                        definition=sdk["PromptAgentDefinition"](model="offline-model", instructions="Benign."))
                except HttpResponseError:
                    pass
                finally:
                    baseline.close()
                assert transport.attempts > 1, transport.attempts
                transport.attempts = 0
                sdk, credential, client = bridge._create_client(
                    "https://offline.services.ai.azure.com/api/projects/offline", None,
                    disable_create_retries=True)
                try:
                    client.agents.create_version(
                        agent_name="offline-agent",
                        definition=sdk["PromptAgentDefinition"](model="offline-model", instructions="Benign."))
                except HttpResponseError:
                    pass
                else:
                    raise AssertionError("retryable failure was swallowed")
                finally:
                    client.close()
            assert transport.attempts == 1, transport.attempts
        """)
        executable = (
            ["py", f"-{sys.version_info.major}.{sys.version_info.minor}"]
            if sys.platform == "win32" else [sys.executable]
        )
        try:
            completed = subprocess.run(
                [*executable, "-c", script, str(PYTHON_SCRIPTS)],
                text=True, capture_output=True, timeout=120)
        except subprocess.TimeoutExpired as exc:
            self.fail(f"Offline transport probe timed out: {exc.stdout!r}; {exc.stderr!r}")
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_qualification_login_keeps_federated_token_in_process_and_discards_cli_output(self):
        import urllib.request

        calls = []
        token = "inert-oidc-token-not-a-credential"
        class Cli:
            def invoke(self, arguments):
                calls.append(arguments)
                print(token)
                print(token, file=sys.stderr)
                return 0
        core = types.ModuleType("azure.cli.core")
        core.get_default_cli = lambda: Cli()
        env = {
            "ACTIONS_ID_TOKEN_REQUEST_URL": "https://example.invalid/oidc?request=offline",
            "ACTIONS_ID_TOKEN_REQUEST_TOKEN": "inert-request-token",
            "AZURE_CLIENT_ID": "offline-client", "AZURE_TENANT_ID": "offline-tenant",
            "AZURE_SUBSCRIPTION_ID": "offline-subscription",
        }
        response = io.BytesIO(json.dumps({"value": token}).encode())
        output, error = io.StringIO(), io.StringIO()
        with mock.patch.dict(sys.modules, {"azure.cli.core": core}), mock.patch.dict(os.environ, env), \
             mock.patch.object(urllib.request, "urlopen", return_value=response), \
             mock.patch.object(subprocess, "Popen") as process, \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
            result = foundry_agent_cli._handle_qualification_login(types.SimpleNamespace())
        self.assertEqual(result, {"authenticated": True})
        self.assertEqual(calls[0][calls[0].index("--federated-token") + 1], token)
        process.assert_not_called()
        self.assertNotIn(token, output.getvalue() + error.getvalue() + json.dumps(result))

    def test_qualification_preflight_requires_exact_model_and_agent_absence(self):
        client = types.SimpleNamespace(
            deployments=types.SimpleNamespace(list=mock.Mock(return_value=[])),
            agents=types.SimpleNamespace(get=mock.Mock(side_effect=FakeResourceNotFoundError())))
        sdk = {"ResourceNotFoundError": FakeResourceNotFoundError}
        with mock.patch.dict(os.environ, {"QUAL_MODEL_DEPLOYMENT": "offline-model", "QUAL_AGENT_NAME": "offline-agent"}):
            with self.assertRaisesRegex(ValueError, "QUAL_MODEL_BLOCKED"):
                foundry_agent_cli._qualification_snapshot(client, sdk)
            client.agents.get.assert_not_called()
            client.deployments.list.return_value = [types.SimpleNamespace(name="offline-model")]
            self.assertEqual(foundry_agent_cli._qualification_snapshot(client, sdk),
                             {"found": False, "modelMatched": True})

    def test_qualification_delete_rejects_unowned_inventory_or_changed_snapshot(self):
        client = types.SimpleNamespace(agents=types.SimpleNamespace(delete=mock.Mock()))
        snapshot = {"found": True, "versions": [{"id": "owned-id", "metadata": {"qualification_experiment": "other"}}]}
        env = {"QUAL_PROJECT_ENDPOINT": "https://example.invalid", "AZURE_TENANT_ID": "offline-tenant",
               "AZURE_TOKEN_CREDENTIALS": "AzureCliCredential", "QUAL_EXPERIMENT_ID": "owned-experiment"}
        with mock.patch.dict(os.environ, env), \
             mock.patch.object(foundry_agent_cli, "_create_client", return_value=({}, object(), client)), \
             mock.patch.object(foundry_agent_cli, "_qualification_snapshot", return_value=snapshot), \
             mock.patch.object(foundry_agent_cli, "_read_json_stdin", return_value=snapshot):
            with self.assertRaisesRegex(ValueError, "QUAL_CLEANUP_BLOCKED"):
                foundry_agent_cli._handle_qualification_target(types.SimpleNamespace(command="qualification-delete"))
            client.agents.delete.assert_not_called()
            with mock.patch.object(foundry_agent_cli, "_read_json_stdin", return_value={"found": True, "versions": []}):
                with self.assertRaisesRegex(ValueError, "QUAL_CLEANUP_BLOCKED"):
                    foundry_agent_cli._handle_qualification_target(types.SimpleNamespace(command="qualification-delete"))
            client.agents.delete.assert_not_called()

    def test_definition_to_sdk_kwargs_maps_supported_fields_and_warns_for_unsupported_input(self):
        payload = {
            "name": "simple-agent",
            "description": "Human-readable description",
            "metadata": {"owner": "team"},
            "model": "gpt-4o-mini",
            "instructions": "Be helpful.",
            "temperature": 0.25,
            "top_p": 0.8,
            "response_format": {"type": "json_object"},
            "tool_resources": {
                "code_interpreter": {"file_ids": ["file-1"]},
                "file_search": {"vector_store_ids": ["vs-1"]},
                "azure_ai_search": {
                    "indexes": [
                        {
                            "index_connection_id": "conn-1",
                            "index_name": "kb-index",
                            "query_type": "vector_semantic_hybrid",
                            "top_k": 7,
                            "filter": "category eq 'docs'",
                            "index_asset_id": "asset-1",
                        }
                    ]
                },
            },
            "tools": [
                {"type": "code_interpreter"},
                {"type": "file_search"},
                {"type": "azure_ai_search"},
                {
                    "type": "openapi",
                    "openapi": {
                        "name": "connected-api",
                        "spec": {"openapi": "3.0.3"},
                        "auth": {
                            "type": "connection",
                            "security_scheme": {"connection_id": "project-connection-1"},
                        },
                    },
                },
                {
                    "type": "openapi",
                    "openapi": {
                        "name": "managed-api",
                        "spec": {"openapi": "3.0.3"},
                        "auth": {
                            "type": "managed_identity",
                            "security_scheme": {"audience": "api://contoso"},
                        },
                    },
                },
                {
                    "type": "openapi",
                    "openapi": {
                        "name": "anonymous-api",
                        "spec": {"openapi": "3.0.3"},
                        "auth": {"type": "anonymous"},
                    },
                },
                {
                    "type": "function",
                    "function": {
                        "name": "lookup_status",
                        "description": "Look up status",
                        "parameters": {"type": "object", "properties": {"ticket": {"type": "string"}}},
                        "strict": True,
                    },
                },
                {
                    "type": "azure_function",
                    "azure_function": {"function_app_resource_id": "/subscriptions/123/resourceGroups/rg/providers/Microsoft.Web/sites/app"},
                },
                {
                    "type": "bing_grounding",
                    "bing_grounding": {
                        "search_configurations": [
                            {
                                "connection_id": "bing-connection",
                                "count": 5,
                                "market": "en-US",
                                "set_lang": "en",
                                "freshness": "Day",
                            }
                        ]
                    },
                },
                {
                    "type": "mcp",
                    "server_label": "knowledge",
                    "server_url": "https://mcp.contoso.example",
                    "require_approval": "always",
                },
            ],
            "unknown_field": "value",
        }

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            result = foundry_agent_cli._definition_to_sdk_kwargs(payload)

        self.assertEqual("gpt-4o-mini", result["model"])
        self.assertEqual("Be helpful.", result["instructions"])
        self.assertEqual(0.25, result["temperature"])
        self.assertEqual(0.8, result["top_p"])
        self.assertIsInstance(result["text"], RecordedKwargs)
        self.assertIsInstance(result["text"].format, RecordedKwargs)
        self.assertEqual({}, result["text"].format.kwargs)

        tools = result["tools"]
        self.assertEqual(10, len(tools))
        self.assertEqual("code_interpreter", tools[0]["type"])
        self.assertEqual(["vs-1"], tools[1]["vector_store_ids"])
        self.assertEqual("conn-1", tools[2]["azure_ai_search"]["indexes"][0]["project_connection_id"])
        self.assertEqual("project_connection", tools[3]["openapi"]["auth"]["type"])
        self.assertEqual(
            "project-connection-1",
            tools[3]["openapi"]["auth"]["security_scheme"]["project_connection_id"],
        )
        self.assertEqual("managed_identity", tools[4]["openapi"]["auth"]["type"])
        self.assertEqual("api://contoso", tools[4]["openapi"]["auth"]["security_scheme"]["audience"])
        self.assertEqual("anonymous", tools[5]["openapi"]["auth"]["type"])
        self.assertEqual("lookup_status", tools[6]["name"])
        self.assertEqual("azure_function", tools[7]["type"])
        self.assertEqual("bing-connection", tools[8]["bing_grounding"]["search_configurations"][0]["project_connection_id"])
        self.assertIsInstance(tools[9], RecordedKwargs)
        self.assertEqual("knowledge", tools[9].server_label)
        self.assertEqual("always", tools[9].require_approval)

        warnings = stderr.getvalue()
        self.assertIn("Ignoring code_interpreter.file_ids", warnings)
        self.assertIn("Ignoring payload field 'name'", warnings)
        self.assertIn("Ignoring unsupported payload field 'unknown_field'", warnings)

    def _assert_create_version_rejects_definition(self, fields, message):
        reset_fake_sdk_state()
        FakeAIProjectClient.instances.clear()
        FakeDefaultAzureCredential.instances.clear()
        FAKE_SDK_STATE["get_result"] = types.SimpleNamespace(id="agent-id")
        payload = {"model": "gpt-4o-mini", **fields}
        args = types.SimpleNamespace(
            endpoint="https://example.invalid/api/projects/offline",
            tenant_id=None,
            agent_name="simple-agent",
        )
        with mock.patch("sys.stdin", io.StringIO(json.dumps(payload))):
            with self.assertRaisesRegex(ValueError, message):
                foundry_agent_cli._handle_create_version(args)
        self.assertEqual([], FAKE_SDK_STATE["create_version_calls"])
        self.assertTrue(FakeAIProjectClient.instances[0].closed)
        self.assertTrue(FakeDefaultAzureCredential.instances[0].closed)

    def test_definition_rejects_unknown_tool_and_openapi_auth_before_mutation(self):
        for tool_type in ("unsupported_tool", "", None, 7, []):
            with self.subTest(tool_type=tool_type):
                self._assert_create_version_rejects_definition(
                    {"tools": [{"type": tool_type}]}, "Unsupported tool type"
                )
        for auth_type in ("unsupported", "", None, 7, []):
            with self.subTest(auth_type=auth_type):
                self._assert_create_version_rejects_definition(
                    {
                        "tools": [{
                            "type": "openapi",
                            "openapi": {
                                "name": "protected-api",
                                "spec": {"openapi": "3.0.3"},
                                "auth": {"type": auth_type},
                            },
                        }]
                    },
                    "Unsupported OpenAPI auth type",
                )

    def test_definition_rejects_malformed_tool_collections_before_mutation(self):
        for tools in (None, False, {}, "", "file_search"):
            with self.subTest(tools=tools):
                self._assert_create_version_rejects_definition(
                    {"tools": tools}, "tools.*must be an array"
                )
        for tool in (None, False, 7, "file_search", []):
            with self.subTest(tool=tool):
                self._assert_create_version_rejects_definition(
                    {"tools": [{"type": "code_interpreter"}, tool]},
                    "tool.*must be an object",
                )
        self._assert_create_version_rejects_definition(
            {"tools": [{}]}, "Unsupported tool type"
        )

    def test_definition_rejects_malformed_supported_tools_before_mutation(self):
        cases = (
            ({"tools": [{"type": "openapi"}]}, "openapi.*must be an object"),
            ({"tools": [{"type": "openapi", "openapi": []}]}, "openapi.*must be an object"),
            ({"tools": [{"type": "openapi", "openapi": {"auth": []}}]}, "auth.*must be an object"),
            ({"tools": [{"type": "openapi", "openapi": {"auth": {}}}]}, "Unsupported OpenAPI auth type"),
            (
                {"tools": [{"type": "openapi", "openapi": {"auth": {
                    "type": "connection", "security_scheme": [],
                }}}]},
                "security_scheme.*must be an object",
            ),
            (
                {"tools": [{"type": "openapi", "openapi": {"auth": {
                    "type": "connection", "security_scheme": {},
                }}}]},
                "connection_id.*non-empty string",
            ),
            (
                {"tools": [{"type": "openapi", "openapi": {"auth": {
                    "type": "managed_identity", "security_scheme": {"audience": None},
                }}}]},
                "audience.*non-empty string",
            ),
            ({"tools": [{"type": "function"}]}, "function.*must be an object"),
            ({"tools": [{"type": "function", "function": []}]}, "function.*must be an object"),
            ({"tools": [{"type": "function", "function": {}}]}, "name.*non-empty string"),
            (
                {"tools": [{"type": "function", "function": {"name": "lookup", "parameters": []}}]},
                "parameters.*must be an object",
            ),
            (
                {"tools": [{"type": "function", "function": {
                    "name": "lookup", "parameters": {}, "strict": "false",
                }}]},
                "strict.*must be a boolean",
            ),
            ({"tools": [{"type": "azure_function", "azure_function": None}]}, "azure_function.*must be an object"),
            ({"tools": [{"type": "bing_grounding", "bing_grounding": []}]}, "bing_grounding.*must be an object"),
            (
                {"tools": [{"type": "bing_grounding", "bing_grounding": {"search_configurations": [None]}}]},
                "search_configurations.*must be an object",
            ),
            ({"tools": [{"type": "mcp", "server_label": "knowledge"}]}, "server_url.*non-empty string"),
            (
                {"tools": [{"type": "mcp", "server_label": "knowledge", "server_url": "https://example.invalid", "allowed_tools": "lookup"}]},
                "allowed_tools.*must be an array",
            ),
            ({"tool_resources": []}, "tool_resources.*must be an object"),
            ({"tool_resources": {"file_search": []}}, "file_search.*must be an object"),
            (
                {"tools": [{"type": "file_search"}], "tool_resources": {"file_search": {"vector_store_ids": "vs-1"}}},
                "vector_store_ids.*must be an array",
            ),
            (
                {"tools": [{"type": "azure_ai_search"}], "tool_resources": {"azure_ai_search": {"indexes": [None]}}},
                "indexes.*must be an object",
            ),
        )
        for fields, message in cases:
            with self.subTest(fields=fields):
                self._assert_create_version_rejects_definition(fields, message)

    def test_response_formats_and_mcp_approval_fail_closed(self):
        json_schema = {
            "type": "json_schema",
            "name": "support_reply",
            "schema": {"type": "object", "properties": {"answer": {"type": "string"}}},
            "strict": True,
        }
        result = foundry_agent_cli._definition_to_sdk_kwargs(
            {
                "model": "gpt-4o-mini",
                "response_format": json_schema,
                "tools": [
                    {
                        "type": "mcp",
                        "server_label": "knowledge",
                        "server_url": "https://mcp.contoso.example",
                        "require_approval": "never",
                    }
                ],
            }
        )
        self.assertIsInstance(result["text"], RecordedKwargs)
        self.assertIsInstance(result["text"].format, RecordedKwargs)
        self.assertEqual(
            {
                "name": "support_reply",
                "schema": {"type": "object", "properties": {"answer": {"type": "string"}}},
                "strict": True,
            },
            result["text"].format.kwargs,
        )
        self.assertIsInstance(result["tools"][0], RecordedKwargs)
        self.assertEqual("never", result["tools"][0].require_approval)

        text_result = foundry_agent_cli._definition_to_sdk_kwargs(
            {"model": "gpt-4o-mini", "response_format": {"type": "text"}}
        )
        self.assertIsInstance(text_result["text"], RecordedKwargs)
        self.assertEqual({}, text_result["text"].format.kwargs)

        default_result = foundry_agent_cli._definition_to_sdk_kwargs({"model": "gpt-4o-mini"})
        self.assertNotIn("text", default_result)

        for payload, expected in (
            ({"model": "gpt-4o-mini", "response_format": "auto"}, "must be an object"),
            (
                {"model": "gpt-4o-mini", "response_format": {"type": "auto"}},
                "Unsupported response_format.type",
            ),
            (
                {
                    "model": "gpt-4o-mini",
                    "response_format": {
                        "type": "json_schema",
                        "json_schema": {"name": "old-shape", "schema": {"type": "object"}},
                    },
                },
                "requires flat name and schema",
            ),
            (
                {
                    "model": "gpt-4o-mini",
                    "tools": [
                        {
                            "type": "mcp",
                            "server_label": "knowledge",
                            "server_url": "https://mcp.contoso.example",
                            "require_approval": "sometimes",
                        }
                    ],
                },
                "Unsupported MCP require_approval",
            ),
        ):
            with self.subTest(expected=expected):
                with self.assertRaisesRegex(ValueError, expected):
                    foundry_agent_cli._definition_to_sdk_kwargs(payload)

    def test_create_version_reads_stdin_calls_sdk_and_writes_json(self):
        FAKE_SDK_STATE["create_version_result"] = types.SimpleNamespace(id="version-id-2", name="simple-agent", version="v2")
        FAKE_SDK_STATE["get_result"] = types.SimpleNamespace(id="agent-id-9")
        payload = {
            "model": "gpt-4o-mini",
            "instructions": "Be helpful.",
            "temperature": 0.1,
            "description": "Support agent",
            "metadata": {
                "logical_name": "simple-agent",
                "agent_version": "1.2.3",
                "environment": "test",
                "managed_by": "foundry-prompt-agent-cicd-accelerator",
            },
        }

        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch("sys.stdin", io.StringIO(json.dumps(payload))):
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                exit_code = foundry_agent_cli.main(
                    [
                        "create-version",
                        "--endpoint",
                        "https://contoso.services.ai.azure.com/api/projects/project",
                        "--api-version",
                        "v1",
                        "--agent-name",
                        "simple-agent",
                    ]
                )

        self.assertEqual(0, exit_code)
        self.assertEqual("", stderr.getvalue())
        response = json.loads(stdout.getvalue())
        self.assertEqual(
            {"id": "version-id-2", "name": "simple-agent", "version": "v2", "agentId": "agent-id-9"},
            response,
        )

        self.assertEqual(1, len(FAKE_SDK_STATE["create_version_calls"]))
        create_call = FAKE_SDK_STATE["create_version_calls"][0]
        self.assertEqual("simple-agent", create_call["agent_name"])
        self.assertIsInstance(create_call["definition"], RecordedKwargs)
        self.assertEqual("gpt-4o-mini", create_call["definition"].model)
        self.assertEqual("Be helpful.", create_call["definition"].instructions)
        self.assertEqual(0.1, create_call["definition"].temperature)
        self.assertEqual("Support agent", create_call["description"])
        self.assertEqual("simple-agent", create_call["metadata"]["logical_name"])
        self.assertEqual("1.2.3", create_call["metadata"]["agent_version"])
        self.assertEqual("test", create_call["metadata"]["environment"])
        self.assertTrue(FakeAIProjectClient.instances[0].closed)
        self.assertTrue(FakeDefaultAzureCredential.instances[0].closed)

    def test_create_version_rejects_non_string_metadata_before_calling_sdk(self):
        payload = {
            "model": "gpt-4o-mini",
            "metadata": {"environment": "test", "retry_count": 2},
        }
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch("sys.stdin", io.StringIO(json.dumps(payload))):
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                exit_code = foundry_agent_cli.main(
                    [
                        "create-version",
                        "--endpoint",
                        "https://contoso.services.ai.azure.com/api/projects/project",
                        "--api-version",
                        "v1",
                        "--agent-name",
                        "simple-agent",
                    ]
                )

        self.assertNotEqual(0, exit_code)
        self.assertEqual([], FAKE_SDK_STATE["create_version_calls"])
        self.assertIn("string keys and values", json.loads(stderr.getvalue())["error"])

    def test_get_agent_returns_found_false_for_missing_agent(self):
        FAKE_SDK_STATE["get_exception"] = FakeResourceNotFoundError("missing")

        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            exit_code = foundry_agent_cli.main(
                [
                    "get-agent",
                    "--endpoint",
                    "https://contoso.services.ai.azure.com/api/projects/project",
                    "--api-version",
                    "v1",
                    "--agent-name",
                    "missing-agent",
                ]
            )

        self.assertEqual(0, exit_code)
        self.assertEqual({"found": False}, json.loads(stdout.getvalue()))

    def test_get_agent_returns_agent_details_and_latest_version(self):
        agent_endpoint = RecordedKwargs(
            version_selector={"version_selection_rules": [{"type": "FixedRatio", "agent_version": "v4", "traffic_percentage": 100}]},
            protocol_configuration={"responses": {}},
        )
        versions = types.SimpleNamespace(latest=types.SimpleNamespace(version="v5"))
        FAKE_SDK_STATE["get_result"] = types.SimpleNamespace(
            id="agent-55",
            name="simple-agent",
            versions=versions,
            agent_endpoint=agent_endpoint,
            state="enabled", configuration_state="enabled",
        )
        FAKE_SDK_STATE["get_version_result"] = types.SimpleNamespace(
            id="version-55",
            version="v4",
            description="Current version",
            metadata={"managed_by": "accelerator"},
            definition=types.SimpleNamespace(
                as_dict=lambda: {
                    "instructions": "Be helpful.",
                    "model": "gpt-4o-mini",
                    "tools": [{"type": "function"}],
                    "temperature": 0.2,
                    "top_p": 0.9,
                }
            ),
        )

        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            exit_code = foundry_agent_cli.main(
                [
                    "get-agent",
                    "--endpoint",
                    "https://contoso.services.ai.azure.com/api/projects/project",
                    "--api-version",
                    "v1",
                    "--agent-name",
                    "simple-agent",
                ]
            )

        self.assertEqual(0, exit_code)
        response = json.loads(stdout.getvalue())
        self.assertTrue(response["found"])
        self.assertEqual("agent-55", response["id"])
        self.assertEqual("simple-agent", response["name"])
        self.assertEqual("v5", response["latestVersion"])
        self.assertEqual("v4", response["activeVersion"])
        self.assertEqual([{"agent_name": "simple-agent", "agent_version": "v4"}], FAKE_SDK_STATE["get_version_calls"])
        self.assertEqual("version-55", response["versionId"])
        self.assertEqual("Current version", response["description"])
        self.assertEqual({"managed_by": "accelerator"}, response["metadata"])
        self.assertEqual("Be helpful.", response["instructions"])
        self.assertEqual("gpt-4o-mini", response["model"])
        self.assertEqual(0.9, response["top_p"])
        self.assertEqual(0.2, response["temperature"])
        self.assertEqual([{"type": "function"}], response["tools"])

    def test_promote_version_updates_agent_endpoint_with_selected_version(self):
        FAKE_SDK_STATE["get_result"] = self.live_agent("v3")
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            exit_code = foundry_agent_cli.main(
                [
                    "promote-version",
                    "--endpoint",
                    "https://contoso.services.ai.azure.com/api/projects/project",
                    "--api-version",
                    "v1",
                    "--agent-name",
                    "simple-agent",
                    "--agent-version",
                    "v3",
                ]
            )

        self.assertEqual(0, exit_code)
        self.assertEqual({"ok": True, "activeVersion": "v3"}, json.loads(stdout.getvalue()))
        self.assertEqual(1, len(FAKE_SDK_STATE["update_details_calls"]))

        update_call = FAKE_SDK_STATE["update_details_calls"][0]
        self.assertEqual("simple-agent", update_call["agent_name"])
        endpoint = update_call["agent_endpoint"]
        self.assertIsInstance(endpoint, RecordedKwargs)
        self.assertEqual("v3", endpoint.version_selector["version_selection_rules"][0]["agent_version"])
        self.assertEqual(100, endpoint.version_selector["version_selection_rules"][0]["traffic_percentage"])
        self.assertEqual({"responses": {}}, endpoint.protocol_configuration)
        self.assertEqual(["preserved"], endpoint.authorization_schemes)

    @staticmethod
    def live_agent(version="v3"):
        return types.SimpleNamespace(
            id="agent-id", name="simple-agent", state="enabled", configuration_state="enabled",
            agent_endpoint=RecordedKwargs(
                version_selector={"version_selection_rules": [{"type": "FixedRatio", "agent_version": version, "traffic_percentage": 100}]},
                protocol_configuration={"responses": {}}, authorization_schemes=["preserved"],
            ),
        )

    def test_selectors_reject_latest_split_unknown_disabled_and_wrong_readback(self):
        for mutation in ("latest", "split", "unknown", "disabled", "no-responses", "ratio"):
            agent = self.live_agent()
            data = agent.agent_endpoint.kwargs
            rule = data["version_selector"]["version_selection_rules"][0]
            if mutation == "latest": rule["agent_version"] = "latest"
            if mutation == "split": data["version_selector"]["version_selection_rules"].append(dict(rule))
            if mutation == "unknown": rule["type"] = "Latest"
            if mutation == "disabled": agent.state = "disabled"
            if mutation == "no-responses": data["protocol_configuration"] = {}
            if mutation == "ratio": rule["traffic_percentage"] = 99
            with self.subTest(mutation=mutation), self.assertRaisesRegex(ValueError, "Unsupported live endpoint"):
                foundry_agent_cli._active_version(agent)
        FAKE_SDK_STATE["get_result"] = self.live_agent("old")
        with self.assertRaisesRegex(ValueError, "selector mismatch"):
            foundry_agent_cli._handle_promote_version(types.SimpleNamespace(endpoint="https://example.invalid", tenant_id=None, agent_name="simple-agent", agent_version="new"))

    def test_runtime_polls_cleans_up_and_rejects_nonterminal_or_unusable_results(self):
        args = types.SimpleNamespace(endpoint="https://example.invalid", tenant_id=None, agent_name="simple-agent", agent_version="v3")
        for status, output, items, expected in (
            ("completed", "answer", [], "completed"),
            ("failed", "", [], "failed"),
            ("incomplete", "", [], "incomplete"),
            ("cancelled", "", [], "cancelled"),
            ("requires_action", "", [], "requires_action"),
            ("completed", "", [], "failed"),
            ("completed", "text", [types.SimpleNamespace(type="function_call")], "requires_action"),
            ("completed", "text", [types.SimpleNamespace(type="mcp_approval_request")], "requires_action"),
        ):
            with self.subTest(status=status, expected=expected):
                client = mock.Mock()
                client.agents.get.return_value = self.live_agent()
                runtime = mock.Mock()
                client.get_openai_client.return_value = runtime
                runtime.conversations.create.return_value = types.SimpleNamespace(id="conv_1")
                runtime.responses.create.return_value = types.SimpleNamespace(id="resp_1", status="in_progress")
                runtime.responses.retrieve.return_value = types.SimpleNamespace(id="resp_1", status=status, output_text=output, output=items, error=None, incomplete_details=None)
                with mock.patch.object(foundry_agent_cli, "_create_client", return_value=({}, mock.Mock(), client)), \
                     mock.patch.object(foundry_agent_cli, "_read_json_stdin", return_value={"prompt": "hello", "timeoutSeconds": 10, "pollIntervalSeconds": 0.01}):
                    result = foundry_agent_cli._handle_invoke_agent(args)
                self.assertEqual(expected, result["Status"])
                self.assertEqual("resp_1", result["ResponseId"])
                self.assertEqual(2, client.agents.get.call_count)
                runtime.conversations.delete.assert_called_once()
                self.assertEqual("v3", result["ServiceVersion"])

    def test_runtime_rejects_route_drift_and_bounds_timeout_and_cleanup_failure(self):
        args = types.SimpleNamespace(endpoint="https://example.invalid", tenant_id=None, agent_name="simple-agent", agent_version="v3")
        for kind in ("drift", "timeout", "cleanup"):
            client = mock.Mock()
            client.agents.get.side_effect = [self.live_agent(), self.live_agent("v4" if kind == "drift" else "v3")]
            runtime = mock.Mock()
            client.get_openai_client.return_value = runtime
            runtime.conversations.create.return_value = types.SimpleNamespace(id="conv_1")
            runtime.responses.create.return_value = types.SimpleNamespace(id="resp_1", status="completed", output_text="answer", output=[])
            if kind == "timeout": runtime.responses.create.side_effect = TimeoutError("deadline")
            if kind == "cleanup": runtime.conversations.delete.side_effect = RuntimeError("cleanup failed")
            with mock.patch.object(foundry_agent_cli, "_create_client", return_value=({}, mock.Mock(), client)), \
                 mock.patch.object(foundry_agent_cli, "_read_json_stdin", return_value={"prompt": "hello", "timeoutSeconds": 1}), \
                 contextlib.redirect_stderr(io.StringIO()):
                # The poll interval must fit the overall timeout.
                with mock.patch.object(foundry_agent_cli, "_read_json_stdin", return_value={"prompt": "hello", "timeoutSeconds": 1, "pollIntervalSeconds": 0.1}):
                    result = foundry_agent_cli._handle_invoke_agent(args)
            self.assertEqual({"drift": "failed", "timeout": "timeout", "cleanup": "completed"}[kind], result["Status"])
            runtime.conversations.delete.assert_called_once()

    def test_real_agent_bound_responses_wire_capture(self):
        probe = textwrap.dedent(f'''
            import json, sys, types, importlib.metadata
            from unittest import mock
            sys.path.insert(0, {str(PYTHON_SCRIPTS)!r})
            import foundry_agent_cli as bridge
            from azure.ai.projects import AIProjectClient
            from azure.ai.projects.models import AgentDetails
            import httpx2
            requests = []
            def handle(request):
                requests.append({{"url": str(request.url), "method": request.method, "body": json.loads(request.content) if request.content else None}})
                if request.method == "DELETE":
                    body = {{"id": "conv_offline", "object": "conversation.deleted", "deleted": True}}
                elif request.url.path.endswith("/conversations"):
                    body = {{"id": "conv_offline", "object": "conversation", "created_at": 1, "metadata": {{}}}}
                else:
                    body = {{"id": "resp_offline", "object": "response", "created_at": 1, "status": "completed", "model": "offline", "output": [{{"type": "message", "id": "msg_1", "role": "assistant", "status": "completed", "content": [{{"type": "output_text", "text": "wire answer", "annotations": []}}]}}]}}
                return httpx2.Response(200, json=body)
            transport = httpx2.Client(transport=httpx2.MockTransport(handle))
            client = AIProjectClient(endpoint="https://example.invalid/api/projects/offline", credential=object(), allow_preview=True)
            real_factory = client.get_openai_client
            def factory(**kwargs):
                return real_factory(**kwargs, api_key="offline", http_client=transport)
            agent = AgentDetails({{"id": "agent-id", "name": "simple-agent", "state": "enabled", "configuration_state": "enabled", "agent_endpoint": {{"version_selector": {{"version_selection_rules": [{{"type": "FixedRatio", "agent_version": "opaque-v3", "traffic_percentage": 100}}]}}, "protocol_configuration": {{"responses": {{}}}}}}}})
            args = types.SimpleNamespace(endpoint="https://example.invalid/api/projects/offline", tenant_id=None, agent_name="simple-agent", agent_version="opaque-v3")
            with mock.patch.object(bridge, "_create_client", return_value=(bridge._load_sdk(), object(), client)), mock.patch.object(client.agents, "get", return_value=agent), mock.patch.object(client, "get_openai_client", side_effect=factory), mock.patch.object(bridge, "_read_json_stdin", return_value={{"prompt": "private stdin prompt", "timeoutSeconds": 10}}):
                result = bridge._handle_invoke_agent(args)
            print(json.dumps({{"requests": requests, "result": result, "previewOptIn": client._config.allow_preview, "openai": importlib.metadata.version("openai")}}))
        ''')
        completed = subprocess.run([sys.executable, "-c", probe], cwd=REPO_ROOT, capture_output=True, text=True, timeout=90)
        self.assertEqual(0, completed.returncode, completed.stderr)
        result = json.loads(completed.stdout)
        self.assertEqual("3.17.0", result["openai"])
        self.assertTrue(result["previewOptIn"])
        self.assertEqual("completed", result["result"]["Status"])
        self.assertEqual("wire answer", result["result"]["Output"])
        self.assertEqual(["POST", "POST", "DELETE"], [item["method"] for item in result["requests"]])
        for request in result["requests"]:
            self.assertIn("/agents/simple-agent/endpoint/protocols/openai/", request["url"])
        self.assertEqual({"conversation": "conv_offline", "input": "private stdin prompt"}, result["requests"][1]["body"])

    def test_preflight_lists_deployments_and_returns_ok(self):
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            exit_code = foundry_agent_cli.main(
                [
                    "preflight",
                    "--endpoint",
                    "https://contoso.services.ai.azure.com/api/projects/project",
                    "--api-version",
                    "v1",
                ]
            )

        self.assertEqual(0, exit_code)
        self.assertEqual({"ok": True}, json.loads(stdout.getvalue()))
        self.assertEqual(1, FAKE_SDK_STATE["deployments_list_calls"])

    def test_create_version_reports_clean_json_errors_for_empty_or_malformed_stdin(self):
        for raw_stdin, expected_message in (
            ("", "Expected JSON payload on stdin."),
            ("{", "Invalid JSON payload"),
        ):
            with self.subTest(raw_stdin=raw_stdin):
                stdout = io.StringIO()
                stderr = io.StringIO()
                with mock.patch("sys.stdin", io.StringIO(raw_stdin)):
                    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                        exit_code = foundry_agent_cli.main(
                            [
                                "create-version",
                                "--endpoint",
                                "https://contoso.services.ai.azure.com/api/projects/project",
                                "--api-version",
                                "v1",
                                "--agent-name",
                                "simple-agent",
                            ]
                        )

                self.assertNotEqual(0, exit_code)
                self.assertEqual("", stdout.getvalue())
                error_payload = json.loads(stderr.getvalue())
                self.assertIn(expected_message, error_payload["error"])

    def test_module_import_and_py_compile_work_without_real_azure_packages(self):
        removed_modules = {}
        for name in list(sys.modules):
            if name == "azure" or name.startswith("azure."):
                removed_modules[name] = sys.modules.pop(name)

        try:
            spec = importlib.util.spec_from_file_location("foundry_agent_cli_noazure", MODULE_PATH)
            fresh_module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(fresh_module)
            self.assertTrue(callable(fresh_module.main))
            py_compile.compile(str(MODULE_PATH), doraise=True)
        finally:
            sys.modules.update(removed_modules)

    def test_real_2_7_0_sdk_models_and_operation_signatures_when_installed(self):
        probe = textwrap.dedent(
            f"""
            import inspect
            import importlib.metadata
            import json
            import pathlib
            import sys

            scripts = pathlib.Path({str(PYTHON_SCRIPTS)!r})
            sys.path.insert(0, str(scripts))
            try:
                from azure.ai.projects import AIProjectClient
                from azure.ai.projects.models import (
                    AgentEndpointConfig,
                    FixedRatioVersionSelectionRule,
                    MCPTool,
                    PromptAgentDefinition,
                    ProtocolConfiguration,
                    ResponsesProtocolConfiguration,
                    TextResponseFormatConfigurationType,
                    VersionSelector,
                )
                from azure.core.pipeline.transport import HttpTransport
                import foundry_agent_cli
            except ImportError as exc:
                print(json.dumps({{"available": False, "reason": str(exc)}}))
                raise SystemExit(0)

            version = importlib.metadata.version("azure-ai-projects")
            client = AIProjectClient(
                endpoint="https://example.invalid/api/projects/offline-signature-check",
                credential=object(),
            )
            create_signature = inspect.signature(client.agents.create_version)
            update_signature = inspect.signature(client.agents.update_details)

            definition_kwargs = foundry_agent_cli._definition_to_sdk_kwargs({{
                "model": "gpt-4o-mini",
                "instructions": "Be helpful.",
                "temperature": 0.2,
                "top_p": 0.8,
                "response_format": {{
                    "type": "json_schema",
                    "name": "support_reply",
                    "schema": {{"type": "object", "properties": {{"answer": {{"type": "string"}}}}}},
                    "strict": True,
                }},
                "tool_resources": {{"file_search": {{"vector_store_ids": ["vs-1"]}}}},
                "tools": [
                    {{
                        "type": "function",
                        "function": {{
                            "name": "lookup_status",
                            "description": "Look up status",
                            "parameters": {{"type": "object"}},
                            "strict": True,
                        }},
                    }},
                    {{"type": "file_search"}},
                    {{
                        "type": "mcp",
                        "server_label": "knowledge",
                        "server_url": "https://mcp.contoso.example",
                        "require_approval": "always",
                    }},
                ],
            }})
            definition = PromptAgentDefinition(**definition_kwargs).as_dict()
            text_definition = PromptAgentDefinition(**foundry_agent_cli._definition_to_sdk_kwargs({{
                "model": "gpt-4o-mini",
                "response_format": {{"type": "text"}},
            }})).as_dict()
            mcp_approvals = [
                MCPTool(
                    server_label="knowledge",
                    server_url="https://mcp.contoso.example",
                    require_approval=value,
                ).as_dict()["require_approval"]
                for value in ("always", "never")
            ]
            endpoint = AgentEndpointConfig(
                version_selector=VersionSelector(
                    version_selection_rules=[
                        FixedRatioVersionSelectionRule(
                            agent_version="v3",
                            traffic_percentage=100,
                        )
                    ]
                ),
                protocol_configuration=ProtocolConfiguration(
                    responses=ResponsesProtocolConfiguration()
                ),
            ).as_dict()

            class CaptureRequest(Exception):
                pass

            class OfflineCredential:
                def get_token(self, *scopes, **kwargs):
                    return type("Token", (), {{"token": "offline", "expires_on": 4102444800}})()

            class CaptureTransport(HttpTransport):
                def __init__(self):
                    self.body = None

                def open(self):
                    pass

                def close(self):
                    pass

                def __exit__(self, *args):
                    self.close()

                def send(self, request, **kwargs):
                    raw = request.body.decode() if isinstance(request.body, bytes) else request.body
                    self.body = json.loads(raw)
                    raise CaptureRequest()

            transport = CaptureTransport()
            wire_client = AIProjectClient(
                endpoint="https://example.invalid/api/projects/offline-wire-check",
                credential=OfflineCredential(),
                transport=transport,
            )
            try:
                wire_client.agents.create_version(
                    "support-agent",
                    definition=PromptAgentDefinition(**definition_kwargs),
                    metadata={{
                        "agent_version": "1.2.3",
                        "environment": "test",
                    }},
                    description="Support agent",
                )
            except CaptureRequest:
                pass

            print(json.dumps({{
                "available": True,
                "version": version,
                "create_parameters": list(create_signature.parameters),
                "update_parameters": list(update_signature.parameters),
                "definition": definition,
                "text_definition": text_definition,
                "mcp_approvals": mcp_approvals,
                "endpoint": endpoint,
                "response_format_types": [item.value for item in TextResponseFormatConfigurationType],
                "wire_body": transport.body,
            }}))
            """
        )
        completed = subprocess.run(
            [sys.executable, "-c", probe],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(0, completed.returncode, completed.stderr)
        result = json.loads(completed.stdout)
        if not result["available"]:
            self.skipTest("azure-ai-projects is unavailable; mocked offline SDK tests remain authoritative")

        self.assertEqual("2.7.0", result["version"])
        self.assertIn("agent_name", result["create_parameters"])
        self.assertIn("definition", result["create_parameters"])
        self.assertIn("metadata", result["create_parameters"])
        self.assertIn("description", result["create_parameters"])
        self.assertIn("agent_name", result["update_parameters"])
        self.assertIn("agent_endpoint", result["update_parameters"])
        self.assertEqual("prompt", result["definition"]["kind"])
        self.assertEqual("gpt-4o-mini", result["definition"]["model"])
        self.assertEqual("lookup_status", result["definition"]["tools"][0]["name"])
        self.assertEqual(["vs-1"], result["definition"]["tools"][1]["vector_store_ids"])
        self.assertEqual("always", result["definition"]["tools"][2]["require_approval"])
        self.assertEqual({"type": "text"}, result["text_definition"]["text"]["format"])
        response_format = result["definition"]["text"]["format"]
        self.assertEqual("json_schema", response_format["type"])
        self.assertEqual("support_reply", response_format["name"])
        self.assertEqual({"type": "object", "properties": {"answer": {"type": "string"}}}, response_format["schema"])
        self.assertNotIn("json_schema", response_format)
        self.assertEqual(["always", "never"], result["mcp_approvals"])
        self.assertEqual(["text", "json_schema", "json_object"], result["response_format_types"])
        self.assertEqual(
            {"agent_version": "1.2.3", "environment": "test"},
            result["wire_body"]["metadata"],
        )
        self.assertEqual("Support agent", result["wire_body"]["description"])
        self.assertNotIn("metadata", result["wire_body"]["definition"])
        self.assertNotIn("description", result["wire_body"]["definition"])
        self.assertEqual(
            "always",
            result["wire_body"]["definition"]["tools"][2]["require_approval"],
        )
        self.assertEqual(
            "json_schema",
            result["wire_body"]["definition"]["text"]["format"]["type"],
        )
        selection_rule = result["endpoint"]["version_selector"]["version_selection_rules"][0]
        self.assertEqual("v3", selection_rule["agent_version"])
        self.assertEqual(100, selection_rule["traffic_percentage"])
        self.assertEqual("FixedRatio", selection_rule["type"])
        self.assertEqual({}, result["endpoint"]["protocol_configuration"]["responses"])


if __name__ == "__main__":
    unittest.main()
