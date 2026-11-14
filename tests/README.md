# Tests

Four layers, each answering a different question.

| Layer | Question | Needs Azure | Runs in |
| --- | --- | --- | --- |
| `unit/` | Does the tooling behave correctly? | no | every pull request |
| `evaluations/` | Is the agent good enough? | yes, or fixture mode | promotion to TEST, UAT, PROD |
| `regression/` | Did behaviour change in a way nobody intended? | yes | promotion to TEST, UAT, PROD |
| `smoke/` | Is the right thing deployed and responding? | yes | after every deployment, all environments |

## unit

Pester 5 tests for `FoundryAgentOps`: merge semantics, placeholder expansion, checksum determinism and
tamper detection, sample resolution, payload mapping, governance positives and negatives, and release record
schema conformance. No Azure access, no network.
SDK bridge tests also cover active/latest separation, fixed routing, Responses status/timeout handling and
offline request capture against installed pins. These are source/transport checks, not Azure qualification.

```powershell
Invoke-Pester -Path ./tests/unit
python -m unittest discover -s .\tests\unit\python -p 'test_*.py'
```

`scripts/Invoke-Validation.ps1` runs them when Pester 5 is installed and reports them as **skipped**, never as
passed, when it is not. Both CI implementations install Pester on the build agent.

## evaluations

Declarative suites validated by `schemas/evaluation-suite.schema.json`. Deterministic evaluators
(`contains-all`, `not-contains`, `regex-match`, `exact-match`, `json-schema`, `latency`) need no evaluation
service, so they are cheap, stable and usable as hard gates.

```powershell
# Release-bound live evidence (use the exact deployment result's record path)
./tests/evaluations/Invoke-EvaluationSuite.ps1 `
  -SuitePath ./samples/rag-agent/evaluations/grounding.evaluation.json `
  -Environment test -AgentName kb-research-agent -ReleaseRecordPath $deploy.ReleaseRecord `
  -ResultPath ./out/eval-test.json

# Offline, against recorded fixtures - this is the evaluator self test
./tests/evaluations/Invoke-EvaluationSuite.ps1 `
  -SuitePath ./tests/evaluations/suites/offline-self-test.evaluation.json `
  -Environment dev -AgentName offline-self-test
```

`suites/offline-self-test.evaluation.json` exercises every deterministic evaluator against
`offline-self-test.fixture.jsonl`. It runs in pull request validation, so a change that breaks the evaluator
logic is caught before it can silently weaken a promotion gate.
Fixture success tests the evaluator only; it cannot attest a live release.

The `ai-quality` evaluator is a declared extension point: it raises an explicit error unless you wire it to an
evaluation backend, rather than reporting an unmeasured pass.

## regression

Cases in `regression/cases/*.json`, one file per agent, asserting behaviour that must not change without a
decision: refusals, handoffs, read-only boundaries, egress rules and resistance to instructions embedded in
tool output.

```powershell
./tests/regression/Invoke-RegressionTest.ps1 -Environment test -AgentName kb-research-agent

# Accept an intended behaviour change
./tests/regression/Invoke-RegressionTest.ps1 -Environment test -AgentName kb-research-agent -UpdateBaseline -WhatIf
./tests/regression/Invoke-RegressionTest.ps1 -Environment test -AgentName kb-research-agent -UpdateBaseline
```

Assertions are hard failures. Baseline similarity is reported as drift and warns by default; pass
`-TreatDriftAsFailure` to make it fail. Baselines are never refreshed automatically: an unexplained drift is
exactly the signal you want.
For attestable results, add `-ReleaseRecordPath $deploy.ReleaseRecord -ResultPath <file>`.
`-UpdateBaseline` is explicitly non-attestable, including when a release path is supplied.

## smoke

Runs after every deployment in every environment, including production.

1. The managed agent's active pinned version reports the manifest semver that was just deployed.
2. Environment metadata, model deployment and tool count match the resolved package. A shared endpoint
   between two environments is caught here.
3. A small set of canary prompts from `smoke/smoke-checks.json` complete and satisfy content assertions.

```powershell
./tests/smoke/Invoke-SmokeTest.ps1 -Environment prod -AgentName operations-copilot -ExpectedVersion 2.1.0
./tests/smoke/Invoke-SmokeTest.ps1 -Environment prod -AgentName operations-copilot -SkipLiveRun
```

Checks can be scoped to specific agents or environments. Keep the set small: it runs on every deployment and
consumes tokens.
`-ExpectedVersion` is manifest semver, not opaque `agent.serviceVersion`. Supply the exact release path and
a result path for attestation; configuration-only `-SkipLiveRun` and no applicable live canaries cannot
satisfy a required smoke gate.

All three live runners use the same SDK Conversations/Responses helper, not classic threads/runs.
They target the logical agent endpoint with one enabled concrete fixed service version at 100%, checking
routing before/after invocation. Assistant-ID-only invocation is unsupported. Responses must complete with
usable text and no unresolved client tool/approval action; conversations are cleaned up in `finally`.
Real runtime calls require the pinned dependencies in `scripts/python/requirements.txt`, including the
documented agent-bound preview opt-in. No authenticated Azure test outcome is implied here.

## Writing good cases

- Test refusals and negative lookups, not only happy paths. Most production incidents are an agent answering
  when it should have declined.
- Include prompt injection probes, both direct ("ignore your instructions") and indirect (an instruction
  embedded in retrieved content).
- Assert the absence of leakage: instruction text, connection ids, queue names, index names.
- Assert the read-only boundary for agents that must not commit changes.
- Never put real customer data, personal data or credentials in a dataset. They are packaged with the agent.
- Prefer assertions on behaviour ("declines and offers a handoff") over exact wording, which changes for
  legitimate reasons.

## Gates

Which tests gate which environment is declared per environment in the overlay:

```json
"deploymentGates": {
  "requireEvaluationPass": true,
  "requireSmokeTestPass": true,
  "requireRegressionPass": true,
  "minimumEvaluationScore": 0.9
}
```

| Environment | Smoke | Regression | Evaluation | Automatic rollback |
| --- | --- | --- | --- | --- |
| DEV | yes | no | no | no |
| TEST | yes | yes | >= 0.85 | yes |
| UAT | yes | yes | >= 0.90 | yes |
| PROD | yes | yes | >= 0.90 | yes |

DEV does not roll back on failure: a broken DEV deployment is information, and hiding it makes debugging
harder.

`Complete-Release.ps1` accepts only evidence bound to the exact release/package/agent/environment/endpoint,
manifest version and service version, executed after verified activation. Required smoke includes a
successful live canary; live evaluation/regression execute all cases and retain completed Response IDs.
Counters, scores and suite thresholds must agree. A minimum evaluation score also requires live evaluation
when the boolean gate is false. Invalid supplied optional evidence fails rather than being ignored.
Offline fixtures, skipped/empty runs, baseline updates and unbound legacy results cannot authorize promotion.

Automatic recovery needs mutation-started evidence plus the retained prior package and attested release JSON.
`Invoke-Rollback.ps1` creates a new service version and runs the target overlay's gates and attestation;
redeployment alone is not recovery success. A first deployment without prior evidence needs manual recovery.
