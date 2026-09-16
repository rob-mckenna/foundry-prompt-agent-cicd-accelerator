# Schemas

JSON Schema (draft-07) contracts. Validated with the built-in PowerShell `Test-Json` cmdlet, so no external
validator is installed.

| Schema | Validates | Referenced by |
| --- | --- | --- |
| `agent-manifest.schema.json` | `agent.manifest.json` | `Resolve-AgentDefinition`, `Invoke-Validation.ps1` |
| `environment-overlay.schema.json` | `environments/<env>.overlay.json` | `Resolve-AgentDefinition`, `Invoke-Validation.ps1` |
| `tool-definition.schema.json` | `tools/*.json` | `Resolve-AgentDefinition`, `Invoke-Validation.ps1` |
| `evaluation-suite.schema.json` | `*.evaluation.json` | `Invoke-EvaluationSuite.ps1`, `Resolve-AgentDefinition` |
| `environment-config.schema.json` | `config/environments/<env>.json` | `Get-EnvironmentConfig` |
| `package-descriptor.schema.json` | `package.json` inside a package | `New-AgentPackage.ps1`, `Read-PackageDescriptor` |
| `release-record.schema.json` | release records | `New-ReleaseRecord`, unit tests |

## Editor support

Reference the schema from the document so that your editor validates as you type:

```json
{
  "$schema": "../../schemas/agent-manifest.schema.json",
  "schemaVersion": "1.0.0"
}
```

`$schema` is accepted by every schema here and is ignored at runtime; validation always resolves the schema
from the repository root.

## Design choices

**Draft-07 with `definitions`.** The built-in `Test-Json` uses NJsonSchema. Draft-07 with internal
`definitions` and `#/definitions/...` references is the interoperable subset, so schemas stay self-contained
and need no network resolution.

**`additionalProperties: false` on document roots.** A typo such as `instuctions` is a validation error, not a
silently ignored key. Freeform sub-objects that must stay extensible (`config` on a tool,
`function.parameters`) deliberately allow additional properties.

**Conditional validation per tool type.** `tool-definition.schema.json` uses `allOf` with `if`/`then` so that
an `azure_ai_search` tool must declare `connectionId` and `indexName`, while a `code_interpreter` tool needs
no configuration at all. One schema, precise rules per type.

**Patterns on identifiers.** Agent names match `^[a-z][a-z0-9-]{2,62}$` and versions match semantic
versioning. Identity is the promotion key, so it is constrained at the contract boundary.

**No secret-shaped fields.** No schema has a field for a password, key or connection string.
`environment-overlay.schema.json` accepts `secretRefs` only in the Key Vault reference form, enforced by a
regular expression, so a literal value fails validation.

## Versioning

Every document carries `schemaVersion`, currently `1.0.0` for all seven.

| Change | Requires a version bump |
| --- | --- |
| New optional property | no |
| New enum value | no, if absence was previously an error anyway |
| New required property | yes |
| Removed or renamed property | yes |
| Tightened constraint that invalidates existing documents | yes |

When you bump a version, keep the old schema readable, update every template and sample in the same pull
request, and describe the migration in `docs/package-format.md`.

## Validating by hand

```powershell
Import-Module ./scripts/modules/FoundryAgentOps/FoundryAgentOps.psd1 -Force
Test-JsonFileSchema -Path ./samples/rag-agent/agent.manifest.json -SchemaPath ./schemas/agent-manifest.schema.json
```

Or the whole repository:

```powershell
./scripts/Invoke-Validation.ps1
```
