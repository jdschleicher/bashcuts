# Table of Contents

* [Choose which Prerequisite CLI's and Other Tools to Install](#tools-used)
* [System Setup for bash and PowerShell Profiles](#system-setup)
* [How to use bashcuts](#how-to)
* [Azure DevOps work-item shortcuts](#azure-devops)

<br>

***

<br>

# <a name="tools-used"></a>Choose which Prerequisite CLI's and Other Tools to Install

- node - https://nodejs.org/en/download
- in order to use powershell shortcuts -> Powershell 7 (and higher) - Installation instructions by operating system: https://github.com/powershell/powershell#get-powershell
- GitHub CLI: https://cli.github.com/
- CumulusCI: https://cumulusci.readthedocs.io/en/stable/
- jQ: https://stedolan.github.io/jq/
- Azure CLI (only if you use the Azure DevOps work-item shortcuts): https://aka.ms/installazurecli
  - plus the `azure-devops` extension: `az extension add --name azure-devops`
- sfdx plugins:
  - sfdx scanner: https://forcedotcom.github.io/sfdx-scanner/
  - sfdx texei: https://github.com/texei/texei-sfdx-plugin
  - sfdx shane-plugins: https://github.com/mshanemc/shane-sfdx-plugins
  - sfdx data move utility sfdmu: https://github.com/forcedotcom/SFDX-Data-Move-Utility
 
<br>

***

<br>

# <a name="system-setup"></a> System Setup for bash and PowerShell Profiles

<br>

**IMPORTANT FOR MAC USERS** There are several use cases of the command "start" that allows files and websites to be opened from the terminal. An "if check conditional" has been introduced to create an alias for the mac command "open" to run whenever "start" is entered. From my initial setup on a mac this has been working for me but if any erros around "start is not a command" we can also replace all instances of "start" with "open" locally in your bashcuts clone to your machine.

<br>

## SETUP FOR BASH TERMINAL:

Shortcuts using bashrc or bash_profile files. Many of the shortcuts provide prompts to support populated necessary arguments/flags to make the functions work

You may not already have a .bashrc file on your system. To create one, open a bash terminal and copy and paste the below command in the terminal or create a new file in your user directory with the name **.bashrc**

**touch ~/.bashrc**

You can also use the .bash_profile file instead of the .bashrc.

To get started, add the below content and associated logic to the your .bashrc file and from there it will load up all the aliases and functions referenced from the .bcut_home file.

To open the .bashrc file that was created above type in the terminal: start ~/.bashrc

**IMPORTANT** -- clone the bashcuts directory into a folder directory structure without spaces or the source command won't be able to evaluate the path correctly (still working on setting it up correctly to not care about spaces). Also note you will have to provide that path to the variable below:

```
PATH_TO_BASHCUTS="/c/path/to/your-parent-directory-where-bashcuts-will-be-cloned-into/"  
if [ -f $PATH_TO_BASHCUTS/bashcuts/.bcut_home ]; 
then 
    echo "bashrc loaded"
    source $PATH_TO_BASHCUTS/bashcuts/.bcut_home
else
    echo "missing bashrc"
fi
	
```

<br>

## SETUP FOR PowerShell Terminal AND PowerShell Debugger Terminal in VS Code:

Once PowerShell Core has been installed on your machine you can open up a new PowerShell terminal in VS Code or a standalone PowerShell Terminal.

With the terminal open enter "$profile" into the terminal to see where the terminal's expecting a profile file to exist. This file may not exist so we may need to create it. 

To create the file enter the below powershell command to create an empty file at the expected profile path:

```
New-Item -ItemType File -Path $profile
```

To edit the profile select, enter the below command:

```
start $profile
```

This will open up the PowerShell profile and may prompt for which application to open the file in. Choose VSCode and select the checkbox to use VSCode for all ps1 files. This gives us syntax highlighting and other features that can be leveraged within the VS Code IDE.

With the PowerShell Profile open add the following code snippet AND **IMPORTANT** replace the path directories to point to where the bashcuts directory was cloned to.

We will know if its working as expected if the terminal prompts out "powershell starting" on initialization/opening:

```

$path_to_bashcuts_parent_directory = 'C:\git'
$bashcuts_git_directory = "bashcuts"
if ("$path_to_bashcuts_parent_directory\$bashcuts_git_directory" -ne $NULL) {
    $path_to_bashcuts = "$path_to_bashcuts_parent_directory\$bashcuts_git_directory"
    Write-Host "PowerShell bashcuts exists"
	. "$path_to_bashcuts\powcuts_home.ps1"
} else {
	Write-Host "Cannot find bashcuts"
    Write-Host "pow_home not setup"
}

```

For the PowerShell terminal from the VS Code PowerShell extension, we can use the same steps as above. It more than likely will be a different profile to update.

Here's a screen shot of the commands to the empty profile being opened in VS Code:

![image](https://github.com/jdschleicher/bashcuts/assets/3968818/c76f2eb0-6091-496a-bfe5-d1dafe557b27)

Here's a side-by-side view of a regular PowerShell core terminal and the PowerShell VS Code extension terminal:

![image](https://github.com/jdschleicher/bashcuts/assets/3968818/f52313f0-a877-4971-828a-954fead5c25d)

***

<br>

# <a name="how-to"></a>How to use bashcuts

<br>

### The bashcuts commands (for the majority of commands) have a convention of 'verb-noun' and meant to be auto-filled with tab-tab to avoid any typos or copy/paste mistakes
![image](https://github.com/jdschleicher/bashcuts/assets/3968818/6eeb578a-e6f1-4e3e-89f2-efd4e09872dc)


### Press tab twice for auto-fill and available command options:
![image](https://github.com/jdschleicher/bashcuts/assets/3968818/3e4b7f16-831e-4134-a5a5-3998f5e6032e)


### To See Where Shortcuts are Loaded and may be available
- "o-" for "Open" --> "o-sfdx" will open the file containing all aliases and supporting logic for sfdx cli shortcuts. With the sfdx-bashcuts (or any bashcuts commands file) can be easily searched, modified, or new commands added and can be committed. When modifying files enter the command "reinit" when done to reload the current terminal instead of closing and repopening.
- To see all possible aliases and associated functions, in bash terminal, type "o-" and then press tab twice to see options of each file of shortcuts
![image](https://github.com/jdschleicher/bashcuts/assets/3968818/cc4af98b-2e74-4d30-b64e-1637c7fd0823)

![image](https://github.com/jdschleicher/bashcuts/assets/3968818/87f2fefe-f81f-42a8-b6fc-100e2292703b)

## Opening VS Code Snipppets

When using VS Code it is HIGHLY recommend to setup VSCode settings sync: https://code.visualstudio.com/docs/editor/settings-sync

This will sync settings, keyboard shortcuts, much more, AND SNIPPETS. 

For windows machines, the snippets are stored in an expected directory, so we can created custom snippet files or use VSCode made snippet files and quickly open them to add new snippets as needed. VS-Code saves those snippets via sync and bashcuts allows us to easily open, edit, and add to them without leaving our VS Code editor.

![image](https://github.com/jdschleicher/bashcuts/assets/3968818/00f97b96-60a3-488a-9eca-71202fd922d2)

***

<br>

# <a name="azure-devops"></a>Azure DevOps work-item shortcuts

PowerShell shortcuts in `powcuts_by_cli/azdevops_workitems.ps1` provide guided setup and work-item navigation against an Azure DevOps organization. Today this includes a guided `az-Connect-AzDevOps` first-run helper, a cached background sync (`az-Sync-AzDevOpsCache` + `az-Register-AzDevOpsSyncSchedule`), a list/open pair for items assigned to you (`az-Get-AzDevOpsAssigned`, `az-Open-AzDevOpsAssigned`), the matching pair for items where you've been @-mentioned in discussion (`az-Get-AzDevOpsMentions`, `az-Open-AzDevOpsMention`), an Epic→Feature→User Story tree view (`az-Show-AzDevOpsTree`, rendering the project's requirement-tier rows — `User Story` on Agile, `Product Backlog Item` on Scrum, `Requirement` on CMMI, `Issue` on Basic), a board-style group-by-State view of the same cached items (`az-Show-AzDevOpsBoard`), area- and iteration-path tree views (`az-Show-AzDevOpsAreas`, `az-Show-AzDevOpsIterations`), an interactive Epic→Feature→Story drill-down picker (`az-Find-AzDevOpsWorkItem`), an interactive new-user-story creator with parent-feature, iteration, and area-path pickers (`az-New-AzDevOpsUserStory`), an interactive new-Feature creator one tier up (parent-Epic picker, area / iteration / priority / AC) with a hand-off prompt to spawn child stories (`az-New-AzDevOpsFeature`), a batch child-story creator that decomposes a Feature into 3-7 stories with a single area / iteration captured once and priority / story points carried forward across the loop (`az-New-AzDevOpsFeatureStories`), and a per-org field-schema config (`az-Initialize-AzDevOpsSchema`, `az-Get-AzDevOpsSchema`, `az-Edit-AzDevOpsSchema`, `az-Test-AzDevOpsSchema`) that future schema-aware updates to the work-item commands consume.

### Prerequisites

- Azure CLI: https://aka.ms/installazurecli
- `azure-devops` CLI extension: `az extension add --name azure-devops` (`az-Connect-AzDevOps` will offer to install this for you on first run)
- An active `az login` session (`az-Connect-AzDevOps` will offer to start one for you on first run)

### Profile environment variables

Add this block to your PowerShell `$profile` and reload (open a new terminal). Replace each value with what's appropriate for your organization:

```powershell
$env:AZ_DEVOPS_ORG = 'https://dev.azure.com/myorg'
$env:AZ_PROJECT    = 'My Project'
$env:AZ_USER_EMAIL = 'user@example.com'
$env:AZ_AREA       = 'My Project\My Team'
$env:AZ_ITERATION  = 'My Project\Sprint 42'
```

### First run

In a fresh PowerShell terminal:

```powershell
az-Connect-AzDevOps
```

This walks through seven checks (Azure CLI present, `azure-devops` extension installed, env vars set, `az login` session active, `az devops` defaults configured, user-machine WIQL query files seeded, smoke `az boards query` succeeds) and prints a clear `READY` or `NOT READY` verdict at the end. It will offer to install the extension and run `az login` for you if either is missing.

After `az-Connect-AzDevOps` reports `READY` once, later commands in the AzDevOps batch use the silent `az-Test-AzDevOpsAuth` check at startup to confirm the environment is still good before they hit the cache.

### Customizing WIQL queries

The `hierarchy` dataset that `az-Sync-AzDevOpsCache` writes into `hierarchy.json` is built from three per-tier WIQL files on your own machine, not from code in this repo:

- POSIX: `~/.bashcuts-config/azure-devops/queries/{epics,features,user-stories}.wiql`
- Windows: `%USERPROFILE%\.bashcuts-config\azure-devops\queries\{epics,features,user-stories}.wiql`

Each sync fires one `az boards query` per file (epics, then features, then user stories) and merges the results into a single `hierarchy.json`. Splitting per tier sidesteps the partial-result behavior that the previous single combined query hit on larger projects, and lets you tune each tier's filter independently.

`az-Connect-AzDevOps` (and the first run of `az-Sync-AzDevOpsCache` if you skipped Connect) seeds each file with a sensible default — items under `{{AZ_AREA}}` scoped to one of `Microsoft.EpicCategory` / `Microsoft.FeatureCategory` / `Microsoft.RequirementCategory`, where `{{AZ_AREA}}` is substituted from `$env:AZ_AREA` at read time. Edit any file to add fields to the SELECT clause, filter by state, scope by tag, or otherwise tailor what lands in `hierarchy.json`. Re-run `az-Sync-AzDevOpsCache` to pick up your changes — no `reinit` needed, since the files are read every sync.

The fast way to open all three for editing is the dedicated shortcut:

```powershell
az-Open-AzDevOpsHierarchyWiqls
```

It seeds any missing defaults (so it works on a fresh machine even before `az-Connect-AzDevOps`) and then opens each path in your OS default editor.

If you delete a file, the next sync writes that default back. The placeholder `{{AZ_AREA}}` is the only one currently supported; everything else in each file is passed through to `az boards query --wiql` verbatim.

### Day-to-day work-item shortcuts

These read the local cache populated by `az-Sync-AzDevOpsCache` (and the recurring `az-Register-AzDevOpsSyncSchedule` job). They never call `az` directly, so they return instantly.

```powershell
az-Get-AzDevOpsAssigned                       # everything assigned to you (excludes Closed/Removed)
az-Get-AzDevOpsAssigned -State Active         # filter to a single state
az-Get-AzDevOpsAssigned -State Active,New     # filter to multiple states
az-Get-AzDevOpsAssigned | Format-Table -AutoSize

az-Open-AzDevOpsAssigned 12345                # open one of your assigned items in the browser

az-Get-AzDevOpsMentions                                  # work items where you've been @-mentioned (excludes items you're already assigned to)
az-Get-AzDevOpsMentions -State Active                    # filter to a single state
az-Get-AzDevOpsMentions -Since (Get-Date).AddDays(-7)    # only mentions whose last activity was in the past week
az-Get-AzDevOpsMentions -IncludeAssigned                 # also surface mentioned items already assigned to you
az-Get-AzDevOpsMentions | Format-Table -AutoSize

az-Open-AzDevOpsMention 12345                 # open one of your mentioned items in the browser

az-Show-AzDevOpsTree                          # print the project's Epic -> Feature -> User Story tree
az-Show-AzDevOpsBoard                         # board view: cached items grouped by State (click the State header in the grid to group)
az-Show-AzDevOpsBoard -State Active,New       # filter to one or more states (default excludes Closed/Removed)
az-Show-AzDevOpsBoard -State Closed,Resolved  # flip to the archive view
az-Show-AzDevOpsBoard -Type Bug,Task          # custom-template work-item types (default: Epic, Feature, User Story)

az-Show-AzDevOpsAreas                         # print the project's area-path tree (cache-first, live fallback)
az-Show-AzDevOpsIterations                    # print the project's iteration-path tree (with start/finish dates)

az-Find-AzDevOpsWorkItem                      # interactive drill-down: pick an Epic, then a Feature, then a Story; '.. [Go Back]' climbs a tier; '.. [Open this <Type>]' launches the browser; loops until you pick 'EXIT' or hit Esc
az-Find-AzDevOpsWorkItem -IncludeClosed       # include Closed/Removed items in the drill-down grids
```

If the cache is older than 6 hours, `az-Get-AzDevOpsAssigned`, `az-Get-AzDevOpsMentions`, `az-Show-AzDevOpsTree`, `az-Show-AzDevOpsBoard`, `az-Show-AzDevOpsAreas`, `az-Show-AzDevOpsIterations`, and `az-Find-AzDevOpsWorkItem` each print a one-line `WARNING stale (last sync: ...)` notice above their output and still render the cached data.

`az-Show-AzDevOpsTree` (and any future hierarchy-view commands) include a `Url` column on every row so you can copy or click straight to the work item from `Out-ConsoleGridView`.

Every list and picker (`az-Get-AzDevOpsAssigned`, `az-Get-AzDevOpsMentions`, `az-Get-AzDevOpsSchema`, `az-Get-AzDevOpsCacheStatus`, `az-Show-AzDevOpsTree`, `az-Show-AzDevOpsBoard`, `az-Show-AzDevOpsAreas`, `az-Show-AzDevOpsIterations`, `az-Find-AzDevOpsWorkItem`, plus the parent-Feature / iteration / area pickers in `az-New-AzDevOpsUserStory`) renders through `Out-ConsoleGridView` — a sortable, filterable, click-to-select TUI grid that runs in your terminal on Windows, macOS, and Linux. Use the arrow keys to navigate, `Space` to select rows, `Enter` to confirm, `Esc` to cancel. Selected rows from the listing functions are emitted to the pipeline, so e.g. `az-Get-AzDevOpsAssigned | ForEach-Object { az-Open-AzDevOpsAssigned $_.Id }` opens every row you ticked. The grid ships in a separate module — install once with `Install-Module Microsoft.PowerShell.ConsoleGuiTools -Scope CurrentUser`. If the module isn't installed, every command falls back to the existing `Format-Table` / numbered-menu output — except `az-Find-AzDevOpsWorkItem`, which is grid-only by design and prints the install hint above instead of running.

`az-Sync-AzDevOpsCache` populates two more cache files alongside the existing `assigned.json` / `mentions.json` / `hierarchy.json`: `iterations.json` and `areas.json`. The new-user-story command below uses these for instant iteration / area-path pickers; if you've upgraded but haven't re-synced yet, the picker fetches them live with a one-line "(run az-Sync-AzDevOpsCache to make this instant)" notice.

### Creating a new User Story

`az-New-AzDevOpsUserStory` walks you through title / description / priority / story points / acceptance criteria, then offers an interactive picker for the parent Feature (active Features pulled from `hierarchy.json`), the iteration, and the area path. The picker uses `Out-ConsoleGridView` when available, otherwise a Read-Host numbered menu (see "Day-to-day work-item shortcuts" above for the fallback rules). After it creates the story it links the chosen parent and opens the new work item in your browser.

```powershell
az-New-AzDevOpsUserStory                       # full interactive walk-through
```

Every prompt is skippable via a parameter, so the function works non-interactively in a script:

```powershell
az-New-AzDevOpsUserStory `
    -Title              "Add new dashboard widget" `
    -Description        "Surface deploy frequency on the team home page." `
    -Priority           2 `
    -StoryPoints        3 `
    -AcceptanceCriteria "- Widget renders for all team members`n- Updates within 60s of new deploy" `
    -FeatureId          1240 `
    -Iteration          "My Project\Sprint 42" `
    -Area               "My Project\My Team" `
    -NoOpen
```

`-FeatureId 0` creates an orphan (no parent link). `-NoOpen` skips the browser launch and just echoes the new work-item URL — handy in scripts. The existing `az-create-userstory` in `pow_az_cli.ps1` is left in place for users who prefer the original flow.

### Creating a new Feature

`az-New-AzDevOpsFeature` is the tier-one-up counterpart to the user-story creator. It walks you through title / description / priority / acceptance criteria, then offers an interactive picker for the parent Epic (active Epics pulled from `hierarchy.json`), the iteration, and the area path. Same `Out-ConsoleGridView` / Read-Host fallback rules. Story points are intentionally skipped — Features don't carry story points in the default Agile / Scrum templates.

After it creates the Feature and links the chosen Epic, it asks `Add child stories now? [Y/n]`; on yes it hands off to `az-New-AzDevOpsFeatureStories -ParentId <newFeatureId>` with the same area / iteration pre-seeded so you can decompose the Feature into its child stories in the same flow. Pass `-NoChildStoriesPrompt` to skip the hand-off (useful in scripts).

```powershell
az-New-AzDevOpsFeature                                  # full interactive walk-through
az-New-AzDevOpsFeature `
    -Title              "Customer impact dashboard" `
    -Description        "Surface customer-impact rollups on the team home page." `
    -Priority           2 `
    -AcceptanceCriteria "- Rollup widget renders for all team members`n- Updates within 60s of new deploy" `
    -ParentEpicId       1180 `
    -Iteration          "My Project\Sprint 42" `
    -Area               "My Project\My Team" `
    -NoOpen `
    -NoChildStoriesPrompt
```

`-ParentEpicId 0` creates an orphan (no parent link).

### Batch-creating child stories under a Feature

`az-New-AzDevOpsFeatureStories -ParentId <feature-id>` decomposes an existing Feature into its 3-7 child User Stories without making you re-answer parent / area / iteration on every story. The flow:

1. Validates the `-ParentId` resolves to a Feature in `hierarchy.json` (run `az-Sync-AzDevOpsCache` first if it doesn't).
2. Picks the iteration + area **once** for the whole batch (or accepts `-Iteration` / `-Area` to skip the pickers).
3. Loops: **title** (Enter to finish the batch) → **acceptance criteria** → **priority** (Enter reuses the previous story's answer; any digit overrides) → **story points** (same `[Enter] to reuse` shorthand) → creates the story via the same `Invoke-AzDevOpsWorkItemCreate` + `Invoke-AzDevOpsParentLink` path the single-shot creator uses, so failure modes / schema enforcement stay identical.
4. After each story prompts `Add another story? (y/N/c)`. `n` (default) ends the batch; `y` continues; `c` re-picks area / iteration before the next story (escape hatch when one story in the batch belongs to a different sprint).
5. Mid-batch failures don't abort — the error is logged, the loop continues, and the failed titles are listed at the end so you can retry them via `az-New-AzDevOpsUserStory -ParentId $ParentId`.
6. Emits a single summary line — `Created N child stories under Feature #1240: 5001, 5002, 5003` (or `Created N, Failed M` when partial) — followed by one URL per created story for quick post-batch review. Returns `[int[]]` of the created story ids so it composes into pipelines.

```powershell
az-New-AzDevOpsFeatureStories -ParentId 1240               # full interactive batch
az-New-AzDevOpsFeatureStories -ParentId 1240 `
    -Iteration "My Project\Sprint 42" `
    -Area      "My Project\My Team"                       # skip the pickers
```

### Per-org field-schema config

Every Azure DevOps org configures its own required + custom fields via process templates (e.g. a "Customer Impact" required field on every User Story, or a "Compliance Risk" picklist). The schema-management commands let you declare those fields once per org so future schema-aware updates to `az-New-AzDevOpsUserStory`, `az-Get-AzDevOpsAssigned`, `az-Show-AzDevOpsTree`, etc. can prompt for / surface them automatically.

The schema lives at `$HOME/.bashcuts/azure-devops/schema-<org>.json` (per-org keyed off `$env:AZ_DEVOPS_ORG`; falls back to `schema.json` when unset). The directory is created with `0700` permissions on macOS / Linux; Windows inherits the user-only ACL from `%USERPROFILE%`.

```powershell
az-Initialize-AzDevOpsSchema     # introspect your org via
                              #   `az devops invoke --area wit --resource workitemtypes`
                              #   and write a starter schema. Refine afterward.
az-Get-AzDevOpsSchema            # print summary table of every required/optional field
az-Get-AzDevOpsSchema -PassThru  # return objects (pipeable / scriptable)
az-Edit-AzDevOpsSchema           # open the schema in $env:EDITOR / code / notepad / nano
                              #   (creates a stub if the file doesn't exist yet)
az-Test-AzDevOpsSchema           # validate the JSON, that every ref still exists in the
                              #   org, and that picklist options are a subset of
                              #   the org's allowedValues. Verdict: VALID / STALE /
                              #   INVALID with a list of any unknown refs / option
                              #   mismatches.
```

Schema file format (one entry per work-item type, each with `required` and `optional` field arrays):

```json
{
  "User Story": {
    "required": [
      { "name": "Customer Impact", "ref": "Custom.CustomerImpact", "type": "string" },
      { "name": "Compliance Risk", "ref": "Custom.ComplianceRisk", "type": "picklist",
        "options": ["Low","Medium","High"] }
    ],
    "optional": [
      { "name": "Epic Owner Name", "ref": "Custom.EpicOwnerName", "type": "string" }
    ]
  }
}
```

Supported `type` values: `string`, `int`, `picklist`, `bool`, `date`, `multiline`. Unknown types are treated as `string` with a warning from `az-Test-AzDevOpsSchema`.

