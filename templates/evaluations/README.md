# Evaluation templates

Evaluation suites are declarative. `tests/evaluations/Invoke-EvaluationSuite.ps1` reads the suite, replays the
dataset against a deployed agent and applies the evaluators and thresholds. Suites are validated by
`schemas/evaluation-suite.schema.json` during offline validation, so a malformed suite fails the pull request
rather than the deployment.

## Files

| File | Purpose |
| --- | --- |
| `baseline.evaluation.json` | Quality, grounding and safety checks every agent should pass before leaving DEV. |
| `dataset.jsonl` | Example dataset: one JSON object per line. |

Copy both into your agent's `evaluations/` folder and point the manifest at the suite:

```json
"evaluations": {
  "suiteFile": "evaluations/baseline.evaluation.json",
  "required": true
}
```

## Dataset format

One JSON object per line:

```json
{"id":"q-001","query":"...","expected":{"mustContain":["..."],"requiresCitation":true},"context":"...","tags":["..."]}
```

- `id` must be unique and stable. Failures are reported by id.
- `query` is sent to the agent.
- `expected` carries whatever the evaluators reference, which keeps the dataset self-describing.
- `tags` let you slice results, for example `safety` versus `core`.

Never put real customer data, credentials or personal data in a dataset. Datasets are committed to a public
repository pattern and are packaged with the agent.

## Evaluator types

| Type | Behaviour | Needs Azure |
| --- | --- | --- |
| `exact-match` | Output equals the expected string after trimming. | no |
| `contains-all` | Output contains every required term. | no |
| `not-contains` | Output contains none of the listed terms. Use for leakage and refusal checks. | no |
| `regex-match` | Output matches the pattern. | no |
| `json-schema` | Output parses as JSON and validates against a schema. | no |
| `latency` | Wall-clock time of the run stays under `maximumMs`. | no |
| `ai-quality` | Delegates to an Azure AI evaluation run (groundedness, relevance, fluency). | yes |

Deterministic evaluators run in CI without extra cost and give stable pass/fail gates. `ai-quality` is a
clearly marked extension point: the runner raises an explicit "not configured" error unless you wire it to an
evaluation backend, rather than silently reporting a pass.

## Thresholds and gates

```json
"thresholds": { "minimumPassRate": 0.9, "maximumP95LatencyMs": 20000, "maximumFailures": 1 }
```

The overlay decides whether a suite is a gate for a given environment:

```json
"deploymentGates": {
  "requireEvaluationPass": true,
  "requireRegressionPass": true,
  "minimumEvaluationScore": 0.9
}
```

## Offline mode

Set `execution.mode` to `offline-fixture` and supply `fixtureFile` to replay recorded responses. This lets the
evaluation logic itself be tested in a pull request with no Azure access, which is how the accelerator keeps
`validate.yml` credential free.
