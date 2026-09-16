## What changes

<!-- One sentence: what behaviour is different after this merge. -->

## Why

<!-- The problem, the incident id, or the request this addresses. -->

## Type

- [ ] Agent definition (manifest, instructions, tools, overlays)
- [ ] Pipeline or workflow
- [ ] Script or shared module
- [ ] Schema (contract change)
- [ ] Infrastructure (Bicep or Terraform)
- [ ] Governance policy (`config/environments/`)
- [ ] Documentation only

## Agent changes

- Agent: `<name>`
- Version: `<old>` -> `<new>`
- Environments affected: DEV / TEST / UAT / PROD
- Behaviour change visible to users: yes / no

## Validation

- [ ] `./scripts/Invoke-Validation.ps1` passes
- [ ] `Invoke-Pester -Path ./tests/unit` passes, or Pester 5 is not installed locally and CI will run it
- [ ] `import-agent.ps1 -WhatIf` reviewed for every affected environment
- [ ] Evaluation or regression cases added or updated for the behaviour change
- [ ] Version bumped in `agent.manifest.json` if anything deployable changed

## Governance

- [ ] No secret, key, token, real endpoint or customer data added
- [ ] `classification` still accurate (sensitivity, personal data, human in the loop)
- [ ] No new tool type added to a higher environment's `allowedToolTypes` without security review
- [ ] Any new tool declares `governance.dataEgress` honestly
- [ ] Responsible AI review reference present if this reaches UAT or PROD

## Rollback

<!-- How to undo this if it misbehaves. For an agent change this is normally the previous package id. -->

## Reviewer notes

<!-- Anything that needs live Azure resources to verify, and who will verify it. -->
