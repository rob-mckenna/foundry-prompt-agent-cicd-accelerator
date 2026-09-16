# Smoke tests

The fastest possible answer to "did the right thing land, and is it alive". Runs after every deployment in
every environment, including production.

## What it checks

| Layer | Check | Catches |
| --- | --- | --- |
| Identity | The managed agent exists in the target project | A deployment that silently targeted the wrong project |
| Identity | `metadata.agent_version` equals the deployed version | A stale agent, or a deployment that did not take effect |
| Configuration | `metadata.environment` equals the target | Two environments sharing a `projectEndpoint` |
| Configuration | Model deployment matches the overlay (`-ExpectedModelDeployment`) | The wrong overlay applied |
| Configuration | Tool count matches the resolved package (`-ExpectedToolCount`) | A tool dropped or disabled by mistake |
| Liveness | Canary prompts complete and satisfy content assertions | A broken model deployment, a missing connection, a regressed refusal |

## Running

```powershell
./tests/smoke/Invoke-SmokeTest.ps1 -Environment dev -AgentName simple-support-agent -ExpectedVersion 1.0.0

./tests/smoke/Invoke-SmokeTest.ps1 -Environment prod -AgentName operations-copilot `
  -ExpectedVersion 2.1.0 -ExpectedModelDeployment gpt-4o -ExpectedToolCount 3 `
  -ResultPath ./out/smoke-prod.json

# Identity and configuration only, no conversation
./tests/smoke/Invoke-SmokeTest.ps1 -Environment prod -AgentName operations-copilot -SkipLiveRun
```

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

- Each canary creates a thread and a run and consumes tokens. Keep the set to a handful of prompts.
- Threads are deleted after each check, including on failure.
- Never use real customer data in a canary prompt.
- In production, prefer read-only prompts. Use `-SkipLiveRun` where even a canary conversation is not
  acceptable; the identity and configuration layers still run.

## On failure

A smoke failure in TEST, UAT or PROD should trigger a rollback. Both CI implementations do this
automatically; manually it is:

```powershell
./scripts/Invoke-Rollback.ps1 -AgentName <agent> -Environment <env> -ArtifactDirectory ./artifacts -Reason '<incident>'
./tests/smoke/Invoke-SmokeTest.ps1 -Environment <env> -AgentName <agent>
```

Always re-run the smoke test after a rollback before closing the incident.
