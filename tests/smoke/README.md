# Smoke tests

The fastest possible answer to "did the right thing land, and is it alive". Runs after every deployment in
every environment, including production.

## What it checks

| Layer | Check | Catches |
| --- | --- | --- |
| Identity | The managed agent exists in the target project | A deployment that silently targeted the wrong project |
| Identity | Active version `metadata.agent_version` equals manifest semver (`-ExpectedVersion`) | A stale agent, or a deployment that did not take effect |
| Routing | Enabled Responses endpoint pins exactly one concrete service version at 100% | Latest/split/disabled routing or service-version drift |
| Configuration | `metadata.environment` equals the target | Two environments sharing a `projectEndpoint` |
| Configuration | Model deployment matches the overlay (`-ExpectedModelDeployment`) | The wrong overlay applied |
| Configuration | Tool count matches the resolved package (`-ExpectedToolCount`) | A tool dropped or disabled by mistake |
| Liveness | Canary prompts complete and satisfy content assertions | A broken model deployment, a missing connection, a regressed refusal |

## Running

```powershell
./tests/smoke/Invoke-SmokeTest.ps1 -Environment dev -AgentName simple-support-agent -ExpectedVersion 1.0.0

./tests/smoke/Invoke-SmokeTest.ps1 -Environment prod -AgentName operations-copilot `
  -ExpectedVersion 2.1.0 -ExpectedModelDeployment gpt-4o -ExpectedToolCount 3 `
  -ReleaseRecordPath $deploy.ReleaseRecord -ResultPath ./out/smoke-prod.json

# Identity and configuration only, no conversation
./tests/smoke/Invoke-SmokeTest.ps1 -Environment prod -AgentName operations-copilot -SkipLiveRun
```

For attestation, pass the exact import/promotion result's `ReleaseRecord` path, never rediscover
`latest.json`. `-ExpectedVersion` is manifest semver, not opaque `agent.serviceVersion`. Standalone runs
without a release path are diagnostic, not release-bound evidence. A required smoke gate needs at least one
successful live canary; `-SkipLiveRun` or no applicable canaries cannot authorize it.

## Canary checks

`smoke-checks.json` holds the prompts. Each check may be scoped:

```json
{
  "id": "order-routing",
  "agents": ["operations-copilot"],
  "environments": ["dev", "test"],
  "prompt": "What is the status of order AB-123456?",
  "mustContain": ["AB-123456"],
  "mustNotContain": ["I have refunded"],
  "maximumLatencyMs": 30000,
  "timeoutSeconds": 120
}
```

Omit `agents` or `environments` to apply a check everywhere. The shipped set includes a liveness probe, a
configuration-disclosure probe, and agent-specific routing and degraded-capability checks.

## Cost and hygiene

- Each canary uses the shared SDK Conversations/Responses helper and consumes tokens. Keep the set small.
- Conversations are deleted in `finally`, including on failure; cleanup errors are warnings, not inference success.
- Never use real customer data in a canary prompt.
- In production, prefer read-only prompts. `-SkipLiveRun` retains identity/configuration diagnostics but
  cannot satisfy a required live gate.

The helper verifies fixed routing before/after invocation; only a completed Response with usable text and no
unresolved client tool/approval requirement can pass. Live result details include status, Response and
Conversation IDs, separately from configuration checks. The `1.1.0` live envelope binds release/package,
agent/environment/endpoint, manifest/service versions and post-activation execution times.
Out-of-band concurrent routing changes are unsupported; checks do not prove absence of transient edits.
Pinned SDK offline request-capture tests are not authenticated Azure qualification.

## On failure

A smoke failure in TEST, UAT or PROD can trigger one verified recovery attempt when mutation started and
the prior package **and attested release JSON** were staged. Manually:

```powershell
./scripts/Invoke-Rollback.ps1 -AgentName <agent> -Environment <env> -ArtifactDirectory ./artifacts `
  -ReleaseRecordPath .\artifacts\<failed-or-current-releaseId>.json `
  -EvaluationSuitePath .\artifacts\<suite>.json -Reason '<incident>'
```

Supply the evaluation suite when the target overlay requires it, and PROD governance inputs as described in
[the runbook](../../docs/deployment-runbook.md#rb-07-roll-back). Rollback centrally creates a new service
version, runs required target-overlay gates and attests them; only `outcome=succeeded` is verified recovery.
First deployment without a known-good prior artifact requires explicit manual recovery.
