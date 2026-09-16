# Templates

Starting points. Copy, do not reference: a template is a snapshot you own once you copy it.

| Folder | Copy to | Contains |
| --- | --- | --- |
| [prompt-agent](prompt-agent) | `agents/<name>/` | Manifest, instructions, four overlays, a baseline evaluation suite |
| [tools](tools) | `agents/<name>/tools/` | One definition per supported tool type, plus an example OpenAPI specification |
| [evaluations](evaluations) | `agents/<name>/evaluations/` | A baseline suite and dataset covering quality, grounding and safety |

```powershell
Copy-Item -Recurse ./templates/prompt-agent ./agents/my-agent
Copy-Item ./templates/tools/azure-ai-search-knowledge.json ./agents/my-agent/tools/knowledge-search.json
./scripts/Invoke-Validation.ps1
```

## Before you commit

Search for markers:

```powershell
Select-String -Path ./agents/my-agent -Pattern 'REPLACE|replace-|TODO' -Recurse
```

The template manifest uses lowercase placeholders (`replace-agent-name`, `replace-owning-team`) so that it
still satisfies the schema while it is obviously unfinished. Validation will pass on an uncustomised template;
review will not.

## Relative paths

Templates use `$schema` paths relative to their location in this repository. When you copy a template to a
different depth, fix the `$schema` value so that editor validation keeps working. The pipeline resolves
schemas from the repository root, so a stale `$schema` affects your editor only.

| Copied to | `$schema` prefix |
| --- | --- |
| `agents/<name>/agent.manifest.json` | `../../schemas/` |
| `agents/<name>/environments/<env>.overlay.json` | `../../../schemas/` |
| `agents/<name>/tools/<tool>.json` | `../../../schemas/` |
| `agents/<name>/evaluations/<suite>.json` | `../../../schemas/` |
