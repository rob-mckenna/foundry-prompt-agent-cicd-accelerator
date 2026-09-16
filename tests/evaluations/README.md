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
  -SuitePath <suite> -Environment <env> -AgentName <agent> [-AgentId <id>] [-ResultPath <file>]
```

The agent id is resolved from the environment release record, or by metadata discovery, unless you pass
`-AgentId`.

## Fixture mode

Set `execution.mode` to `offline-fixture` and supply `execution.fixtureFile`. The runner replays recorded
responses instead of calling Azure, which is how the evaluator logic itself is tested in a pull request.

Fixture lines are keyed by the dataset record `id`:

```json
{"id":"t-001","output":"...","latencyMs":1420}
```

A dataset record with no matching fixture is an error, not a skip.

## Result file

`-ResultPath` writes the full result set: per-record pass or fail, per-evaluator outcome and message,
latency, and the aggregate pass rate, p95 latency and threshold verdict. Pipelines publish it as an artifact
so a failed gate can be diagnosed after the fact.
