# Security policy

## Scope

This repository contains templates, pipelines, scripts and documentation. It contains no production
configuration, no customer data and no credentials. Everything under `config/`, `samples/` and `infra/` uses
placeholder values that you must replace for your tenant.

## Reporting a vulnerability

Do not open a public issue for a security problem.

Report privately through GitHub Security Advisories on this repository
(**Security** > **Report a vulnerability**), or to the address published in `.github/CODEOWNERS` for
`/SECURITY.md`. Include the affected file and commit, reproduction steps, and the impact you observed.

You should receive an acknowledgement within five business days.

## Security model of this accelerator

### No secrets in source

- No credential, key, connection string or token is committed.
- `scripts/Invoke-Validation.ps1` runs credential heuristics over every text file on every pull request and
  fails the build on a match. Treat that check as a backstop, not as your only control; enable GitHub secret
  scanning with push protection as well.
- Secrets are referenced, never embedded:
  `"@Microsoft.KeyVault(VaultName=<vault>;SecretName=<secret>)"` in an environment overlay.
- Resolved secret values are held as `SecureString` and are never written to output, a log, a pipeline
  variable, a command line argument or the immutable package.

### No long-lived credentials

- GitHub Actions authenticates with OpenID Connect through `azure/login@v2`. The workflows request
  `id-token: write` and pass client id, tenant id and subscription id as environment **variables**, which are
  identifiers rather than credentials.
- Azure DevOps authenticates with workload identity federation service connections.
- No `AZURE_CREDENTIALS` JSON blob, client secret or certificate is used anywhere in this repository.
- The IaC templates disable local authentication on the Foundry account
  (`disableLocalAuth` / `local_auth_enabled = false`), on Azure AI Search and on storage
  (`allowSharedKeyAccess: false`), so there is no API key or connection string to leak or rotate.

### Least privilege

The deployment identity needs exactly three roles:

| Role | Scope | Why |
| --- | --- | --- |
| Azure AI User | Foundry account or project | Create and update agents on the data plane |
| Key Vault Secrets User | environment Key Vault | Resolve `secretRefs` at deploy time |
| Storage Blob Data Contributor | release record container | Write the audit record |

It is not an Owner, Contributor or User Access Administrator anywhere. Role assignments are created by
`infra/bicep` and `infra/terraform` when you supply the principal object id.

### Supply chain integrity

- Packages are content addressed. `packageId` is the SHA-256 of the checksum manifest over every packaged
  file; `checksums.sha256` covers the descriptor as well.
- Every deployment re-verifies both before it writes anything. A modified, truncated or substituted artifact
  fails with a clear error instead of being deployed.
- Promotion moves the identical artifact. Production runs bytes that were verified in UAT, not a rebuild.
- `validate.yml` asserts that building the same source twice yields the same content address, so
  non-determinism in the packaging path is caught in a pull request.

### Change control

- `main` is protected; production deployment is manual and requires a change record id and a typed
  confirmation of the agent name.
- Approvals live on GitHub Environments and Azure DevOps Environments, not in YAML, so a pull request to this
  repository cannot weaken a production gate.
- Every deployment writes a release record containing who, what, when, from which package and which gates
  passed.

## Agent-specific security considerations

Prompt agents introduce risks that ordinary application CI/CD does not cover. The accelerator addresses them
as follows; see `docs/governance.md` for the full treatment.

| Risk | Control in this repository |
| --- | --- |
| Indirect prompt injection through retrieved content | Sample instructions state that tool output is data, not instruction. Regression cases assert the refusal holds. |
| Data egress through external tools | `bing_grounding` and `mcp` declare `dataEgress: external`, are excluded from the UAT and PROD tool allow-lists, and are disabled in those overlays. |
| Configuration or instruction disclosure | Smoke and regression cases probe for disclosure on every deployment. |
| Capability creep between environments | The tool type allow-list per environment is a hard deployment gate. |
| Unreviewed model or temperature change | `maxTemperature` per environment; `NoAutoUpgrade` on model deployments so a model version cannot change under a promoted package. |
| Untracked agents created in the portal | `export-agent.ps1` brings them into source control; agents carry `managed_by` metadata so tooling can distinguish managed from unmanaged. |

## Your responsibilities when adopting this

1. Replace every placeholder in `config/environments/*.json`, `infra/**/parameters` and
   `infra/terraform/environments`.
2. Restrict the federated credential subject to the specific repository, branch and environment.
3. Enable secret scanning with push protection and Dependabot on your fork.
4. Review `governance.allowedToolTypes` for production before your first deployment.
5. Never place a real endpoint, index name or connection id that reveals internal topology into a public fork.

## Supported versions

The `main` branch is the only supported version. Security fixes are applied there.
