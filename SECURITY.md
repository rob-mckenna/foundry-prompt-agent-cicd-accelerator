# Security policy

## Scope

This repository is community reference tooling, not a production-certified service or a security approval.
The supplied templates, pipelines, scripts and samples are intended to use placeholder configuration.
Review your copy for credentials, customer data and internal topology before publishing or deploying it.

The current release-control qualification is offline and narrowly scoped. Unit tests and SDK request
captures are not live Azure acceptance evidence; they do not establish effective tenant permissions,
network isolation, model availability or production security.

## Reporting a vulnerability

Do not open a public issue for a security problem.

Report privately through GitHub Security Advisories on this repository
(**Security** > **Report a vulnerability**), or to the address published in `.github/CODEOWNERS` for
`/SECURITY.md`. Include the affected file and commit, reproduction steps, and the impact you observed.

You should receive an acknowledgement within five business days.

## Security model of this accelerator

### No secrets in source

- Do not commit credentials, keys, connection strings or tokens.
- `scripts/Invoke-Validation.ps1` includes credential heuristics. Require validation in your CI and treat
  that check as a backstop, not an exhaustive detector; enable GitHub secret scanning with push protection
  as well.
- Use secret references rather than embedded values:
  `"@Microsoft.KeyVault(VaultName=<vault>;SecretName=<secret>)"` in an environment overlay.
- Optional Key Vault reference validation captures the Azure CLI result in process memory before converting
  it to `SecureString`; it is not a plaintext-free execution guarantee. The resolver does not intentionally
  log the value or insert it into the package or agent definition.
- Placeholder expansion uses a closed variable map. Only names declared in the target configuration's
  `runtime.allowedVariables` may be read from the process environment or supplied as runtime overrides;
  explicit overrides take precedence. Credential-like names are rejected heuristically. This does not
  detect a secret disguised as an allowed identifier: keep all substituted values nonsecret.

### Federated deployment authentication

- GitHub Actions authenticates with OpenID Connect through `azure/login@v2`. The workflows request
  `id-token: write` and pass client id, tenant id and subscription id as environment **variables**, which are
  identifiers rather than credentials.
- Azure DevOps authenticates with workload identity federation service connections.
- The supplied deployment pipelines do not require an `AZURE_CREDENTIALS` JSON blob, client secret or
  certificate. The Python bridge creates its own `DefaultAzureCredential`; verify which credential and
  identity that chain selects in your runner. PowerShell does not pass its access token to the bridge.
- Agent version creation, discovery and activation use the pinned Azure AI Projects SDK. Live runners use
  its agent-bound OpenAI client with explicit preview opt-in and Conversations/Responses, not classic
  threads/runs. A separate legacy REST export-by-ID path remains; the configured REST `apiVersion` does
  not select the SDK's API version.
- The IaC templates configure local authentication as disabled on the Foundry account
  (`disableLocalAuth` / `local_auth_enabled = false`), on Azure AI Search and on storage
  (`allowSharedKeyAccess: false`). Verify the deployed settings and protect any other credentials in your
  environment; these template settings are not proof that no keys exist.

### Least privilege

The templates assign the following deployment roles when a deployment principal is supplied. These are
starting points, not a verified minimum for every tool, tenant or infrastructure provisioning identity:

| Role | Intended access (actual assignment scopes below) | Why |
| --- | --- | --- |
| Azure AI User | Foundry account or project | Create and update agents on the data plane |
| Key Vault Secrets User | environment Key Vault | Validate `secretRefs` when requested |
| Storage Blob Data Contributor | package and release stores | Publish/read retained packages and write/read release records |

**The implementations have different effective scopes.** The shared Bicep role-assignment module creates
resource-group-scoped assignments, including the deployment and project-identity roles. Its
`resourceIdForName` input only affects the assignment name; it does not narrow scope. Terraform scopes
the corresponding assignments to the Foundry account, Key Vault, storage account and Search service,
not individual blob containers. Do not describe the Bicep defaults as resource-scoped least privilege.

Review inherited permissions and constrain identities for your deployment. Ensure access covers **both**
the package store and release store, including separately configured accounts or containers. Neither
implementation proves that a principal lacks other roles. Provisioning role assignments requires separate
management-plane authority; this release-control tranche does not repair or live-qualify RBAC or networks.

### Supply chain integrity

- New packages use `foundry-agent-package/2`. Their ID is SHA-256 over the format discriminator, canonical
  stable descriptor projection and source-file checksum manifest. The projection excludes `packageId`
  and `build.createdUtc`, `buildRunId`, `buildRunUrl`, `builder` and `sourceRef`; source commit/repository,
  tool version, governance identity and inventory remain bound. `checksums.sha256` also covers the final
  descriptor. Strict descriptor-bound `/1` verification remains; there is no checksum-only fallback.
- Deployment verifies checksums, content address, inventory and declared identity before publication or
  runtime mutation. These are integrity checks, **not signatures or authenticated build provenance**.
  Someone able to replace both an artifact and its expected identity can regenerate valid hashes.
  Informational build fields are checksum-protected, not package-ID-bound or independently authenticated.
- Promotion transports the original archive unchanged; repeat builds may share a content ID without being
  byte-identical ZIPs. Publication rejects an existing same-ID blob if its archive bytes differ.
- The same archive does not imply identical environments: overlays, allowlisted runtime values, model
  deployments, connections, indexes, secrets and external services can differ or change independently.
- `validate.yml` asserts that building the same source twice yields the same content address, so
  non-determinism in the packaging path is caught in a pull request.

### Change control

- The production workflow is manual and checks a change-record format and typed agent-name confirmation.
  Configure branch protection and required checks on your fork; source files alone do not enable them.
  Change, business-signoff and Responsible AI references are not validated against external approval systems.
- Configure GitHub Environment reviewers, deployment branch rules and Azure DevOps Environment checks
  outside YAML. GitHub required reviewers are **one-of**, not proof that both platform and service owners
  approved. Use additional independently enforced controls if both approvals are required. JSON
  `approvalRequired` and `approverGroups` do not provision or enforce those platform controls.
- Protect workflow code and environment administration too: external approvals do not make a malicious
  workflow or privileged operator harmless. Read approval history in the CI platform; scripts do not
  populate release-record approval identities.
- New release records distinguish manifest semver, logical agent resource ID and opaque service-version
  identity. Mutation intent is persisted before version creation; activation is completed only after
  selector read-back. Supported live routing is an enabled Responses endpoint with one explicit concrete
  version at 100%; implicit/latest, split, disabled and unknown routing are rejected by managed import.
- Required gate evidence must be live, nonempty and bound to the exact release, package, agent, environment,
  project endpoint, manifest version and service version, with valid post-activation timing and completed
  Responses IDs. Fixtures, skipped canaries and baseline updates cannot authorize required live gates.
  An invalid supplied result fails validation even for an optional gate. Legacy release records are
  audit-only, not eligible for new live attestation or promotion.
- Result-file hashes and release JSON are pipeline-generated evidence, not service-signed attestation or
  protection against a malicious authorized pipeline. Protect artifacts and audit stores accordingly.
- Rollback redeploys verified prior package bytes as a **new service version** and reports recovery only
  after the target's required live gates and attestation succeed. It does not revoke or delete older
  versions, restore frozen external configuration, or prove clients cannot invoke another version.
  First deployments without a prior artifact require explicit manual recovery.
- Serialize deployment, testing and rollback per agent/environment. Before/after route checks detect
  observed drift, not every transient out-of-band edit. Creation/activation can expose a candidate before
  post-deployment gates complete; this is not a zero-exposure staging system.

## Agent-specific security considerations

Prompt agents introduce risks that ordinary application CI/CD does not cover. These reference controls
reduce particular risks, not guarantee safe model behavior; see `docs/governance.md`.

| Risk | Control in this repository |
| --- | --- |
| Indirect prompt injection through retrieved content | Sample instructions and regression assertions provide bounded checks, not a general prompt-injection defense. |
| Data egress through external tools | Supplied configurations exclude `bing_grounding` and `mcp` from UAT/PROD allowlists and disable them in sample overlays. These declarations are not a network egress policy. |
| Configuration or instruction disclosure | Applicable smoke/regression cases can detect specified disclosures when run and required; they do not exhaust disclosure paths. |
| Capability creep between environments | Managed import enforces the environment tool-type allowlist. It does not govern out-of-band portal/API edits or authorize every operation exposed by an allowed tool. |
| Unreviewed model or temperature change | Import checks `maxTemperature`; IaC requests `NoAutoUpgrade`. This does not freeze model behavior forever or override retirement, service policy, safety-system changes or operator edits. |
| Untracked agents created in the portal | `export-agent.ps1` supports a reviewed source-control handoff. `managed_by` metadata is a convention, not an authorization boundary or automatic discovery/enforcement service. |

The PowerShell payload converter rejects unsupported tool types and OpenAPI authentication types. The
Python mapper also rejects unsupported or missing tool/authentication types and checked malformed input
shapes before version creation, alongside unsupported response formats and MCP approval settings.
Explicitly declared anonymous authentication remains supported. These checks are not complete
OpenAPI/tool-schema validation or external authorization enforcement. Unresolved client tool/approval
actions cannot pass the live invocation helper.

## Your responsibilities when adopting this

1. Replace every placeholder in `config/environments/*.json`, `infra/**/parameters` and
   `infra/terraform/environments`.
2. Restrict the federated credential subject to the specific repository, branch and environment.
3. Enable secret scanning with push protection and Dependabot on your fork.
4. Review `governance.allowedToolTypes` for production before your first deployment.
5. Never place a real endpoint, index name or connection id that reveals internal topology into a public fork.
6. Independently validate effective RBAC on both stores, environment approvals, network controls, tool
   authorization and model lifecycle behavior in an explicitly authorized Azure qualification.

## Supported versions

The `main` branch is the only supported version. Security fixes are applied there.
