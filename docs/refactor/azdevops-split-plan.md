# Azure DevOps PowerShell Refactor — Split Plan

## Scope

Only `powcuts_by_cli/azdevops_workitems.ps1` is in scope. The other AzDevOps files are reasonable:

| File | LOC | Verdict |
|---|---:|---|
| `azdevops_workitems.ps1` | **4,886** | Split into 10 files |
| `azdevops_projects.ps1`  |   597 | Leave alone |
| `azdevops_db.ps1`        |   341 | Leave alone |
| `bashcuts_by_cli/.az_bashcuts` | 268 | Leave alone |

This is a **pure split**. No renames. No behavior changes. No DRY pass. Every function name stays identical, so user muscle memory, `o-az` discovery, tab-completion, and the diagram doc's function-name references all keep working.

## Target layout

10 new files under `powcuts_by_cli/`, replacing `azdevops_workitems.ps1`:

| New file | Source range | LOC | Purpose |
|---|---|---:|---|
| `azdevops_auth.ps1`           | 1–432       |  430 | Diagnostics, confirm-steps, `az-Connect-AzDevOps` |
| `azdevops_paths.ps1`          | 434–811     |  380 | App root, cache paths, config paths, WIQL defaults, query init |
| `azdevops_sync.ps1`           | 814–1315    |  505 | Sync engine + scheduled-task / cron registration |
| `azdevops_views.ps1`          | 1318–2295   |  980 | Grid helpers, Assigned/Mentions/Tree/Board/Features views |
| `azdevops_find.ps1`           | 2298–2475   |  180 | `az-Find-AzDevOpsWorkItem` |
| `azdevops_classification.ps1` | 2477–3021   |  545 | Areas + iterations (show / get / find) |
| `azdevops_create_pickers.ps1` | 3024–3434   |  410 | Field prompts + parent/feature/epic/classification/kind pickers |
| `azdevops_create.ps1`         | 3437–4171   |  735 | Creator orchestration + `az-New-AzDevOps{UserStory,Feature,FeatureStories}` |
| `azdevops_schema.ps1`         | 4174–4741   |  570 | Field-schema cache (`az-Get/Edit/Initialize/Test-AzDevOpsSchema`) |
| `azdevops_openers.ps1`        | 4744–4886   |  140 | `az-Open-AzDevOps*` folder / cache / config / schema openers |
| **total** |  | **~4,895** |  |

## Function → file map

### `azdevops_auth.ps1` (silent diagnostics, confirm-steps, connect orchestrator)

Public (`az-*`):
- `az-Test-AzDevOpsAuth`
- `az-Confirm-AzDevOpsCli`
- `az-Confirm-AzDevOpsExtension`
- `az-Confirm-AzDevOpsEnvVars`
- `az-Confirm-AzDevOpsProjectMap`
- `az-Confirm-AzDevOpsLogin`
- `az-Set-AzDevOpsDefaults`
- `az-Confirm-AzDevOpsQueryFiles`
- `az-Open-AzDevOpsHierarchyWiqls`
- `az-Confirm-AzDevOpsSmokeQuery`
- `az-Connect-AzDevOps`

Helpers:
- `Test-AzDevOpsCliPresent`
- `Test-AzDevOpsExtensionInstalled`
- `Test-AzDevOpsLoggedIn`
- `Invoke-AzDevOpsSmokeQuery`
- `Assert-AzDevOpsAuthOrAbort`
- `New-AzDevOpsStepResult`
- `Read-AzDevOpsYesNo`

Also gets the master header docstring (verb-coverage matrix, prereqs, first-run instructions) because `az-Connect-AzDevOps` is the user-facing entry.

### `azdevops_paths.ps1` (filesystem layout + WIQL defaults)

Public: none (pure plumbing)

Helpers:
- `Get-AzDevOpsAppRoot`
- `Get-AzDevOpsCachePathsForSlug`
- `New-AzDevOpsDirectoryIfMissing`
- `Get-AzDevOpsCachePaths`
- `Initialize-AzDevOpsCacheDir`
- `Get-AzDevOpsConfigPaths`
- `Get-AzDevOpsQueryDefaults`
- `Initialize-AzDevOpsQueryFiles`
- `Get-AzDevOpsHierarchyQueryNames`
- `Get-AzDevOpsWiql`
- `Invoke-AzDevOpsHierarchyQueries`
- `Write-AzDevOpsCacheFile`
- `Write-AzDevOpsSyncLog`

### `azdevops_sync.ps1` (sync engine + schedule registration)

Public (`az-*`):
- `az-Sync-AzDevOpsCache`
- `az-Get-AzDevOpsCacheStatus`
- `az-Register-AzDevOpsSyncSchedule`
- `az-Unregister-AzDevOpsSyncSchedule`

Helpers:
- `Get-AzDevOpsFirstStderrLine`
- `New-AzDevOpsDatasetStatus`
- `Write-AzDevOpsSyncStderr`
- `Get-AzDevOpsSyncDatasets`
- `Invoke-AzDevOpsAzDataset`
- `Measure-AzDevOpsClassificationNodes`
- `Get-AzDevOpsCacheAge`
- `Get-AzDevOpsCacheStatusRows`
- `Get-AzDevOpsPlatform`
- `Get-AzDevOpsScheduledTaskName`
- `Get-AzDevOpsSyncIntervalHours`
- `Get-AzDevOpsCronTag`
- `Get-AzDevOpsCronLine`
- `Get-AzDevOpsCrontabSplit`

### `azdevops_views.ps1` (assigned / mentions / tree / board / features)

Public (`az-*`):
- `az-Get-AzDevOpsAssigned`
- `az-Open-AzDevOpsAssigned`
- `az-Get-AzDevOpsMentions`
- `az-Open-AzDevOpsMention`
- `az-Show-AzDevOpsTree`
- `az-Show-AzDevOpsBoard`
- `az-Show-AzDevOpsFeatures`

Helpers (grid + cache-consumer scaffolding):
- `Test-AzDevOpsGridAvailable`
- `Show-AzDevOpsRows`
- `Read-AzDevOpsGridPick`
- `ConvertFrom-AzDevOpsAssignedItem`
- `Read-AzDevOpsJsonCache`
- `Get-AzDevOpsClosedStates`
- `Write-AzDevOpsStaleBanner`
- `Select-AzDevOpsActiveItems`
- `Sort-AzDevOpsByDateDesc`
- `Format-AzDevOpsTruncatedTitle`
- `Get-AzDevOpsTitleColumn`
- `Find-AzDevOpsCachedWorkItem`
- `Get-AzDevOpsWorkItemUrlPrefix`
- `Get-AzDevOpsWorkItemUrl`
- `Open-AzDevOpsWorkItemUrl`
- `Read-AzDevOpsAssignedCache`
- `Get-AzDevOpsMentionedByDisplayName`
- `ConvertFrom-AzDevOpsMentionItem`
- `Read-AzDevOpsMentionsCache`
- `ConvertFrom-AzDevOpsHierarchyItem`
- `Read-AzDevOpsHierarchyCache`
- `Read-AzDevOpsHierarchyCacheForProject`
- `Get-AzDevOpsTreeIndent`
- `Get-AzDevOpsTreeIcon`
- `Format-AzDevOpsTreeNode`
- `Get-AzDevOpsTreeRows`
- `Get-AzDevOpsFeaturesProjectNames`

### `azdevops_find.ps1` (interactive hierarchy drill-down)

Public (`az-*`):
- `az-Find-AzDevOpsWorkItem`

Helpers:
- `New-AzDevOpsActionRow`

### `azdevops_classification.ps1` (areas + iterations: show / get / find)

Public (`az-*`):
- `az-Show-AzDevOpsAreas`
- `az-Show-AzDevOpsIterations`
- `az-Get-AzDevOpsAreas`
- `az-Get-AzDevOpsIterations`
- `az-Find-AzDevOpsArea`
- `az-Find-AzDevOpsIteration`

Helpers:
- `Read-AzDevOpsClassificationCache`
- `Invoke-AzDevOpsClassificationLive`
- `ConvertTo-AzDevOpsWorkItemPath`
- `ConvertTo-AzDevOpsClassificationPaths`
- `Get-AzDevOpsClassificationPaths`
- `ConvertFrom-AzDevOpsClassificationTree`
- `Format-AzDevOpsClassificationDate`
- `ConvertTo-AzDevOpsClassificationDisplayRows`
- `Format-AzDevOpsClassificationNode`
- `Read-AzDevOpsClassificationRows`
- `Show-AzDevOpsClassification`
- `Write-AzDevOpsGridUnavailable`

### `azdevops_create_pickers.ps1` (field prompts + create-flow pickers)

Public: none (interactive pickers consumed by the creators)

Helpers:
- `Get-AzDevOpsReuseHint`
- `Read-AzDevOpsPriority`
- `Read-AzDevOpsStoryPoints`
- `Read-AzDevOpsAcceptanceCriteria`
- `Test-AzDevOpsAreaPathMatch`
- `Read-AzDevOpsParentPick`
- `Get-AzDevOpsParentScopeAreaPaths`
- `Read-AzDevOpsFeaturePick`
- `Read-AzDevOpsEpicPick`
- `Read-AzDevOpsClassificationPick`
- `Read-AzDevOpsKindPick`

### `azdevops_create.ps1` (creator orchestration + public entry points)

Public (`az-*`):
- `az-New-AzDevOpsUserStory`
- `az-New-AzDevOpsFeature`
- `az-New-AzDevOpsFeatureStories`

Helpers:
- `Invoke-AzDevOpsWorkItemCreate`
- `Invoke-AzDevOpsParentLink`
- `Test-AzDevOpsCreateGate`
- `Read-AzDevOpsRequiredFields`
- `Resolve-AzDevOpsTypePriorityOrPrompt`
- `Resolve-AzDevOpsTypeStoryPointsOrPrompt`
- `Resolve-AzDevOpsTypeTagsOrEmpty`
- `Resolve-AzDevOpsIterationArea`
- `Invoke-AzDevOpsCreateAndLink`
- `Read-AzDevOpsBatchContinue`
- `Test-AzDevOpsParentIsFeature`

### `azdevops_schema.ps1` (field-schema cache)

Public (`az-*`):
- `az-Get-AzDevOpsSchema`
- `az-Edit-AzDevOpsSchema`
- `az-Initialize-AzDevOpsSchema`
- `az-Test-AzDevOpsSchema`

Helpers:
- `Get-AzDevOpsSchemaValidTypes`
- `Get-AzDevOpsSchemaWorkItemTypes`
- `Get-AzDevOpsSchemaSystemRefs`
- `Get-AzDevOpsSchemaOrgSlug`
- `Get-AzDevOpsSchemaPaths`
- `Initialize-AzDevOpsSchemaDir`
- `Write-AzDevOpsSchemaFile`
- `Read-AzDevOpsSchemaFile`
- `Get-AzDevOpsSchemaForType`
- `New-AzDevOpsSchemaStub`
- `ConvertFrom-AzDevOpsSchemaToRows`
- `Resolve-AzDevOpsEditor`
- `Invoke-AzDevOpsWorkItemTypeShow`
- `ConvertTo-AzDevOpsSchemaFieldEntry`

### `azdevops_openers.ps1` (folder / cache / config / schema openers)

Public (`az-*`) — 15 functions:
- `az-Open-AzDevOpsAppRoot`
- `az-Open-AzDevOpsCacheDir`
- `az-Open-AzDevOpsConfigDir`
- `az-Open-AzDevOpsSchemaDir`
- `az-Open-AzDevOpsAssignedCache`
- `az-Open-AzDevOpsMentionsCache`
- `az-Open-AzDevOpsHierarchyCache`
- `az-Open-AzDevOpsIterationsCache`
- `az-Open-AzDevOpsAreasCache`
- `az-Open-AzDevOpsLastSync`
- `az-Open-AzDevOpsSyncLog`
- `az-Open-AzDevOpsEpicsWiql`
- `az-Open-AzDevOpsFeaturesWiql`
- `az-Open-AzDevOpsUserStoriesWiql`
- `az-Open-AzDevOpsSchema`

Helpers:
- `Open-AzDevOpsPathIfExists`

## Wire-up changes

### `powcuts_home.ps1`

Replace the single `azdevops_workitems.ps1` `Get-Content`/`if`/dot-source block with 10 sibling blocks in this order (deps flow downward — pure plumbing first, then orchestrators):

1. `azdevops_auth.ps1`
2. `azdevops_paths.ps1`
3. `azdevops_sync.ps1`
4. `azdevops_views.ps1`
5. `azdevops_find.ps1`
6. `azdevops_classification.ps1`
7. `azdevops_create_pickers.ps1`
8. `azdevops_create.ps1`
9. `azdevops_schema.ps1`
10. `azdevops_openers.ps1`

(All files only define functions, so dot-source order is technically irrelevant at runtime — the order above is for readability of `powcuts_home.ps1`.)

### `docs/azure-devops-diagrams.md`

7 existing references to `azdevops_workitems.ps1` in the diagram doc rewritten to point at the new file each function/section now lives in (plus parallel mentions in `README.md`, `CLAUDE.md`, sibling `azdevops_db.ps1` / `azdevops_projects.ps1` comments, `pow_open.ps1`'s `o-pow-azdevops`, and the `azdevops-diagrams-check` slash-command frontmatter). Function names don't change, only the filename portion of each reference. Bundled into the same commit as the split.

## Out of scope (deliberate)

- **No DRY consolidation** — the parallel `Read-AzDevOps*Pick` family, the 15 near-identical openers, and the parallel `Get-AzDevOps*Cache` readers all stay duplicative. That's option (b) and is a separate PR.
- **No bash refactor** — `.az_bashcuts` is 268 lines and is fine.
- **No `azdevops_projects.ps1` / `azdevops_db.ps1` split** — both under 600 lines.
- **No function renames** — every name stays exactly as-is.

## Verification plan (post-split)

1. `bash -n` is N/A (no bash files change beyond `.bcut_home` if at all — and `.bcut_home` doesn't reference workitems).
2. `pwsh -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile(...)"` on each of the 9 new files and `powcuts_home.ps1`. *(pwsh is not on PATH in the current sandbox — the user will need to confirm parse cleanliness in their own shell.)*
3. `grep -c "function " powcuts_by_cli/azdevops_*.ps1` total should equal the pre-split count from `azdevops_workitems.ps1` (162 functions).
4. In a fresh PowerShell terminal, dot-source `powcuts_home.ps1` and run:
   - `Get-Command az-Connect-AzDevOps` → from `azdevops_auth.ps1`
   - `Get-Command az-Sync-AzDevOpsCache` → from `azdevops_sync.ps1`
   - `Get-Command az-Show-AzDevOpsTree` → from `azdevops_views.ps1`
   - `Get-Command az-New-AzDevOpsFeatureStories` → from `azdevops_create.ps1`
   - `Get-Command az-Open-AzDevOpsAppRoot` → from `azdevops_openers.ps1`
   - All 155 functions visible: `Get-Command -Name 'az-*-AzDevOps*' | Measure-Object`.
5. Smoke a public command end-to-end (e.g. `az-Get-AzDevOpsAssigned` or `az-Show-AzDevOpsTree`) to confirm cross-file calls resolve.

## Rollback

`git revert` of the split commit restores `azdevops_workitems.ps1` and the original `powcuts_home.ps1`. No data migrations, no schema changes, no state in the new layout — all caches under `~/.bashcuts-az-devops-app/` are untouched.
