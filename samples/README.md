# Samples

Three illustrative agent configurations for offline resolution and governance checks, not Azure-qualified
deployments. There has been **no authenticated Azure qualification** for this tranche. External dependencies,
live quality and tenant policy still need verification.

| Sample | Tools | Read it for |
| --- | --- | --- |
| [simple-agent](simple-agent) | none | The minimum valid agent. Prove the pipeline before adding capability. |
| [rag-agent](rag-agent) | `azure_ai_search`, `file_search` | Per-environment index binding from one package, grounding gates. |
| [multi-tool-agent](multi-tool-agent) | five, two disabled above TEST | Environment-scoped capability, layered tool policy, Key Vault references, an inlined OpenAPI spec. |

Start with `simple-agent` for the offline package path, then read `multi-tool-agent` for environment-scoped tools.
Use the [root quickstart](../README.md#quick-start) to build, verify and preview DEV without credentials.

## Resolved shape per environment

| Sample | DEV | TEST | UAT | PROD |
| --- | --- | --- | --- | --- |
| `simple-support-agent` | gpt-4o-mini, 0.3, 0 tools | gpt-4o-mini, 0.3, 0 tools | gpt-4o, 0.2, 0 tools | gpt-4o, 0.1, 0 tools |
| `kb-research-agent` | gpt-4o-mini, 0.3, 2 tools, `kb-dev-v1` | gpt-4o-mini, 0.2, 2 tools, `kb-test-v1` | gpt-4o, 0.2, 2 tools, `kb-uat-v1` | gpt-4o, 0.1, 2 tools, `kb-prod-v3` |
| `operations-copilot` | gpt-4o-mini, 0.3, 5 tools | gpt-4o-mini, 0.2, 5 tools | gpt-4o, 0.2, 3 tools | gpt-4o, 0.1, 3 tools |

These model deployment names and parameters are examples, not current availability or lifecycle guarantees.
Qualify deployed model versions, regional support and retirement dates before using them. One package carries
all overlays; effective models, tools and external data can differ by environment. Content identity is not a
promise of immutable model behaviour or knowledge.

Inspect the configured shapes yourself, offline (not a live invocation or full governance check):

```powershell
Import-Module .\scripts\modules\FoundryAgentOps\FoundryAgentOps.psd1 -Force
foreach ($sample in 'simple-agent','rag-agent','multi-tool-agent') {
  foreach ($environment in 'dev','test','uat','prod') {
    $definition = Resolve-AgentDefinition -Path ".\samples\$sample" -Environment $environment -SkipPlaceholderExpansion
    $payload = ConvertTo-FoundryAgentPayload -Definition $definition
    "{0,-18} {1,-5} model={2,-12} tools={3}" -f $sample, $environment, $payload['model'], @($payload['tools']).Count
  }
}
```

## Using a sample as a starting point

```powershell
New-Item -ItemType Directory -Force .\agents | Out-Null
Copy-Item -Recurse .\samples\rag-agent .\agents\my-agent
```

Then change, at minimum: `name` (permanent, lowercase kebab), `version` to `1.0.0`, `displayName`,
`description`, `owner`, `classification.responsibleAiReviewId`, the instruction text, the index names in each
overlay, the evaluation dataset, and `metadata.service`.

```powershell
.\scripts\Invoke-Validation.ps1 -SkipInfrastructure
```

## Placeholders in the samples

Everything that identifies a tenant is a placeholder:

| Value | Placeholder |
| --- | --- |
| Subscription | `${env:AZURE_SUBSCRIPTION_ID}`, supplied by the pipeline |
| Resource group | `rg-foundry-agents-<env>` |
| Foundry account and project | `aifagents<env>`, `proj-agents-<env>` |
| Connections | `kb-search`, `ops-search`, `orders-api`, `bing-grounding` |
| Key Vault | `kv-fnd-agents-<env>` |
| Domains | `contoso.example.com`, `example.com` |
| Change record | `${env:CHANGE_RECORD_ID}`, supplied through approved `-ChangeRecordId` |

Replace them for your tenant before deploying. PROD also requires `-BusinessSignoffId`; placeholder
references are not approval evidence. Connections may use Entra authentication and can be IaC-created, but
the supplied templates do not create them. Search indexes/content, vector stores, models and Function/API
implementations are external prerequisites, not implicitly provisioned by packaging.

Deployment returns `pending-verification`. Use release-bound live tests and `Complete-Release.ps1` before
promotion; see [scripts/README.md](../scripts/README.md). Offline fixtures cannot attest a release.
