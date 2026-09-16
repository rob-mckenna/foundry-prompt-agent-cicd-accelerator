# Contributing

Thank you for helping improve this accelerator. It is used to bootstrap real enterprise deployments, so
correctness and honesty about limitations matter more than breadth of features.

## Ground rules

1. **No secrets, ever.** No key, token, connection string, real tenant id, real endpoint or customer data in
   any file, commit message or issue. `scripts/Invoke-Validation.ps1` runs credential heuristics, but you are
   the primary control.
2. **No invented APIs.** Only use Azure CLI commands, REST paths and resource types that are documented and
   that you have verified. If behaviour varies by API version or preview state, parameterise it and fail
   clearly rather than guessing.
3. **Fail loudly.** No silent fallback, no broad `catch { }` that swallows an error, no "assume success". A
   deployment that half-worked is worse than one that stopped.
4. **Offline validation must stay offline.** `Invoke-Validation.ps1` must keep working with no Azure
   credentials and must not install global tooling.
5. **ASCII only** in source and documentation unless there is a specific reason otherwise.

## Getting set up

Requirements:

- PowerShell 7.2 or later
- Git
- Optional but recommended: Azure CLI with the Bicep extension, Terraform 1.9+, Pester 5, PSScriptAnalyzer

```powershell
git clone https://github.com/OWNER/foundry-prompt-agent-cicd-accelerator.git
cd foundry-prompt-agent-cicd-accelerator
./scripts/Invoke-Validation.ps1
```

Optional local tooling, installed to your user scope only:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser
```

Validation skips both when they are absent and reports them as skipped rather than passed.

## Before you open a pull request

```powershell
./scripts/Invoke-Validation.ps1
Invoke-Pester -Path ./tests/unit
./tests/evaluations/Invoke-EvaluationSuite.ps1 -SuitePath ./tests/evaluations/suites/offline-self-test.evaluation.json -Environment dev -AgentName offline-self-test
```

All three must pass. The same checks run in `validate.yml`.

## PowerShell conventions

- `#Requires -Version 7.2` and `Set-StrictMode -Version 3.0` at the top of every script.
- `$ErrorActionPreference = 'Stop'` in scripts. Use `Continue` only in a failure-handling block that must
  complete.
- `[CmdletBinding(SupportsShouldProcess)]` on every script that changes remote or on-disk state, with a
  meaningful `ShouldProcess` target and description. Validation enforces this for the mutating scripts.
- Validate parameters with `[ValidateSet]`, `[ValidatePattern]`, `[ValidateRange]` or
  `[ValidateNotNullOrEmpty]` rather than checking inside the body.
- Approved verbs and full cmdlet names. No aliases in committed code.
- Catch specific exception types. Never `catch { }` with an empty body.
- Error messages must say what failed, what was expected and what to do next.
- Secrets are `SecureString` end to end. Never `ConvertFrom-SecureString -AsPlainText` in committed code, and
  never place a secret on a command line where it would reach a process list or a transcript.

## Schema changes

`schemas/*.schema.json` are contracts. Changing one can invalidate packages that are already promoted.

- Additive, optional fields: allowed within the current `schemaVersion`.
- Anything required, removed or renamed: bump `schemaVersion`, keep the previous schema readable, and describe
  the migration in the pull request and in `docs/package-format.md`.
- Update every template and sample in the same pull request. Validation will catch it if you do not.

## Adding a tool type

1. Add the type to the `type` enum and to the `allOf` conditional block in
   `schemas/tool-definition.schema.json`.
2. Add a mapping branch to `ConvertTo-FoundryAgentPayload` in
   `scripts/modules/FoundryAgentOps/FoundryAgentOps.psm1`. Do not add a default that silently skips.
3. Add a template to `templates/tools/` with a governance block and a realistic `dataEgress` value.
4. Add the type to `governance.allowedToolTypes` only in the environments where it is genuinely appropriate.
   External egress tools should not default into UAT or PROD.
5. Add a unit test asserting the payload shape.
6. Document the mapping in `docs/deployment-patterns.md`.

## Pipeline changes

- Keep the required filenames: `validate.yml`, `deploy-dev.yml`, `deploy-test.yml`, `deploy-prod.yml` under
  `.github/workflows` and `azure-devops/pipelines`.
- Put shared logic in the reusable workflow or template, not in the entry-point file. Deployment behaviour
  must not drift between environments.
- Never add an approval decision to YAML. Approvals belong on GitHub Environments and Azure DevOps
  Environments where they are auditable and cannot be changed by a pull request to this repository.
- Pin actions to a major version tag. Dependabot keeps them current.

## Documentation

- Every new capability needs documentation in `docs/` and a line in the relevant README.
- State prerequisites and user-supplied values explicitly.
- Mermaid diagrams belong in `docs/diagrams/` and should also be referenced from `docs/architecture.md`.
- Do not describe behaviour that is not implemented. If something is a pattern rather than working code, say
  so in the text.

## Commit and pull request style

- Conventional commits: `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `test:`.
- One logical change per pull request.
- In the description, state what you changed, why, how you validated it, and any behaviour that still requires
  live Azure resources to verify.

## Code of conduct

Be respectful and assume good intent. Report unacceptable behaviour to the owners listed in
`.github/CODEOWNERS`.
