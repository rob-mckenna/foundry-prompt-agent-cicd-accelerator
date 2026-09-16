# Samples

Three complete, validated agents. Each resolves and passes governance in all four environments; the offline
validation suite proves it on every run.

| Sample | Tools | Read it for |
| --- | --- | --- |
| [simple-agent](simple-agent) | none | The minimum valid agent. Prove the pipeline before adding capability. |
| [rag-agent](rag-agent) | `azure_ai_search`, `file_search` | Per-environment index binding from one package, grounding gates. |
| [multi-tool-agent](multi-tool-agent) | five, two disabled above TEST | Environment-scoped capability, three-layer egress control, Key Vault references, an inlined OpenAPI spec. |

Start with `simple-agent` to validate your platform setup, then read `multi-tool-agent` to see every pattern
the accelerator supports in one place.

## Resolved shape per environment

| Sample | DEV | TEST | UAT | PROD |
| --- | --- | --- | --- | --- |
| `simple-support-agent` | gpt-4o-mini, 0.3, 0 tools | gpt-4o-mini, 0.3, 0 tools | gpt-4o, 0.2, 0 tools | gpt-4o, 0.1, 0 tools |
| `kb-research-agent` | gpt-4o-mini, 0.3, 2 tools, `kb-dev-v1` | gpt-4o-mini, 0.2, 2 tools, `kb-test-v1` | gpt-4o, 0.2, 2 tools, `kb-uat-v1` | gpt-4o, 0.1, 2 tools, `kb-prod-v3` |
| `operations-copilot` | gpt-4o-mini, 0.3, 5 tools | gpt-4o-mini, 0.2, 5 tools | gpt-4o, 0.2, 3 tools | gpt-4o, 0.1, 3 tools |

Verify it yourself, offline:

```powershell
Import-Module ./scripts/modules/FoundryAgentOps/FoundryAgentOps.psd1 -Force
foreach ($sample in 'simple-agent','rag-agent','multi-tool-agent') {
  foreach ($environment in 'dev','test','uat','prod') {
    $definition = Resolve-AgentDefinition -Path ./samples/$sample -Environment $environment -SkipPlaceholderExpansion
    $payload = ConvertTo-FoundryAgentPayload -Definition $definition
    "{0,-18} {1,-5} model={2,-12} tools={3}" -f $sample, $environment, $payload['model'], @($payload['tools']).Count
  }
}
```

## Using a sample as a starting point

```powershell
Copy-Item -Recurse ./samples/rag-agent ./agents/my-agent
```

Then change, at minimum: `name` (permanent, lowercase kebab), `version` to `1.0.0`, `displayName`,
`description`, `owner`, `classification.responsibleAiReviewId`, the instruction text, the index names in each
overlay, the evaluation dataset, and `metadata.service`.

```powershell
./scripts/Invoke-Validation.ps1
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
| Change record | `CHG-0000000`, overridden by `${env:CHANGE_RECORD_ID}` |

None of them resolve to anything real. Replace them for your tenant before deploying.
