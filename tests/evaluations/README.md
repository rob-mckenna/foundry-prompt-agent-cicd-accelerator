# Evaluation suites

Suites that belong to the accelerator itself rather than to a specific agent.

| File | Purpose | Azure |
| --- | --- | --- |
| `suites/offline-self-test.evaluation.json` | Exercises every deterministic evaluator against recorded fixtures | no |
| `suites/offline-self-test.dataset.jsonl` | Three cases: citation required, refusal, multi-term match | - |
| `suites/offline-self-test.fixture.jsonl` | Recorded responses keyed by dataset `id` | - |

Agent-specific suites live with the agent, for example
`samples/rag-agent/evaluations/grounding.evaluation.json`, so that they are packaged and promoted together
with the behaviour they measure.

## Running

```powershell
./tests/evaluations/Invoke-EvaluationSuite.ps1 `
  -SuitePath <suite> -Environment <env> -AgentName <agent> `
  -ReleaseRecordPath $deploy.ReleaseRecord -ResultPath .\out\evaluation.json
```

`$deploy.ReleaseRecord` is the exact import/promotion result's release path, not `latest.json`.
Omitting `-ReleaseRecordPath` permits standalone diagnostics but produces non-attestable evidence.
Live discovery uses the logical name and active pinned service version; assistant-ID-only invocation is
unsupported. Manifest semver and opaque service version are distinct.
The shared SDK helper uses agent-bound Conversations/Responses, verifies a single enabled fixed version
at 100% before/after invocation, and cleans up conversations. Unsupported client tool/approval actions,
timeouts and incomplete/failed Responses cannot pass as completed answers.

## Fixture mode

Set `execution.mode` to `offline-fixture` and supply `execution.fixtureFile`. The runner replays recorded
responses instead of calling Azure, which is how the evaluator logic itself is tested in a pull request.
Fixture results are explicitly offline and cannot satisfy release attestation, even if they pass or a
release record path is supplied.

Fixture lines are keyed by the dataset record `id`:

```json
{"id":"t-001","output":"...","latencyMs":1420}
```

A dataset record with no matching fixture is an error, not a skip.

## Result file

`-ResultPath` writes the full result set: per-record pass or fail, per-evaluator outcome and message,
latency, and the aggregate pass rate, p95 latency and threshold verdict. Pipelines publish it as an artifact
so a failed gate can be diagnosed after the fact.
Attestable results add the `1.1.0` live envelope: gate, release/package/agent/environment/normalized endpoint,
manifest and service versions, start/finish times and `liveExecuted`. All cases must execute live after
verified activation, with completed Response IDs and consistent counts, scores and suite thresholds.
Attestation also applies the packaged minimum score, even if `requireEvaluationPass` is false, and retains
the result SHA-256. A hash binds bytes; it is not an Azure-signed inference attestation.

Offline SDK serialization/request capture does not qualify authenticated Azure execution. Rehearse the live
path with the pinned SDK dependencies and documented preview opt-in before adoption.
