# Table of Contents

* [Choose which Prerequisite CLI's and Other Tools to Install](#tools-used)
* [System Setup for bash and PowerShell Profiles](#system-setup)
* [Machine Setup: PowerShell Profile & Azure CLI](#machine-setup)
* [How to use bashcuts](#how-to)
* [Azure DevOps work-item shortcuts](#azure-devops)
* [Timer sessions](#timer-sessions)
* [Unplanned work sessions](#unplanned-work)

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

> **New to PowerShell profiles or the Azure CLI?** See [Machine Setup: PowerShell Profile & Azure CLI](#machine-setup) below for a from-zero walkthrough of finding, creating, and editing your `$profile` (with screenshots) plus installing and configuring `az`. The snippet below assumes you already have a profile file open for editing.

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

For the PowerShell terminal from the VS Code PowerShell extension, we can use the same steps as above. It more than likely will be a different profile to update. See [Machine Setup: PowerShell Profile & Azure CLI](#machine-setup) for the difference between the standalone-pwsh profile and the VS Code-host profile.

***

<br>

# <a name="machine-setup"></a>Machine Setup: PowerShell Profile & Azure CLI

This section is a from-zero walkthrough for a fresh machine: get your PowerShell `$profile` under control, then install and configure the Azure CLI (`az`) so the `az-*` shortcuts work. Everything below is one-time-per-machine setup.

<br>

## Managing your PowerShell profile

Your `$profile` is the script PowerShell runs every time a terminal starts — it's where bashcuts gets wired in (see [System Setup](#system-setup) above) and where you set the `$env:AZ_*` variables the Azure DevOps shortcuts read.

### Find the active profile

```powershell
$profile                      # path PowerShell loads for the current host
$PROFILE.CurrentUserAllHosts  # shared across every PowerShell host on this machine
```

**Heads up — VS Code uses a different profile.** A standalone `pwsh` terminal and the VS Code PowerShell-extension terminal each load their **own** `$profile` path. Run `$profile` in each terminal to see the two distinct paths; if a shortcut works in one but not the other, you've likely only wired up one of them. `$PROFILE.CurrentUserAllHosts` is the path that applies to both, if you'd rather maintain a single file.

### Create it if it doesn't exist

```powershell
New-Item -ItemType File -Path $profile -Force
```

`-Force` creates any missing parent directories so this works on a clean machine.

### Edit it

```powershell
code $profile    # open in VS Code (recommended — syntax highlighting for .ps1)
start $profile   # or open in your OS default editor
```

If `start $profile` prompts for which application to open the file in, choose VS Code and tick the checkbox to use VS Code for all `.ps1` files.

Here's a screen shot of the empty profile being opened in VS Code:

![image](https://github.com/jdschleicher/bashcuts/assets/3968818/c76f2eb0-6091-496a-bfe5-d1dafe557b27)

Here's a side-by-side view of a regular PowerShell core terminal and the PowerShell VS Code extension terminal — note each has its own profile:

![image](https://github.com/jdschleicher/bashcuts/assets/3968818/f52313f0-a877-4971-828a-954fead5c25d)

### Reload after editing

You don't have to close and reopen the terminal — dot-source the profile to re-run it in the current session:

```powershell
. $profile
```

<br>

## Configuring the Azure CLI (`az`)

The Azure DevOps shortcuts (`az-Connect-AzDevOps`, `az-Sync-AzDevOpsCache`, the work-item views and creators) all shell out to the Azure CLI. Get `az` installed and configured once and they all light up. (`az-Connect-AzDevOps` automates several of these steps interactively on first run — this is the manual reference.)

### 1. Install the Azure CLI

Follow Microsoft's per-OS installer: https://aka.ms/installazurecli

### 2. Verify the install

```powershell
az version
```

You should see a JSON blob with `azure-cli` and your installed version. If `az` isn't found, reopen your terminal so the updated `PATH` takes effect.

### 3. Sign in

```powershell
az login
```

This opens a browser to authenticate. On a headless box, or when the browser flow won't complete, use device-code auth:

```powershell
az login --use-device-code
```

If your organization spans multiple Entra ID tenants, target the right one explicitly:

```powershell
az login --tenant <tenant-id-or-domain>
```

### 4. Keep it current

```powershell
az upgrade
```

The `azure-devops` extension and the `az boards` surface move quickly; an out-of-date CLI is a common cause of confusing errors.

### 5. Pick the right subscription

```powershell
az account show                          # which subscription am I on?
az account list --output table           # all subscriptions available to me
az account set --subscription "<name-or-id>"
```

### 6. Add the `azure-devops` extension

Required for every `az boards` / `az devops` call the shortcuts make:

```powershell
az extension add --name azure-devops
```

(`az-Connect-AzDevOps` will offer to install this for you on first run.)

### 7. Set your org and project defaults

Org and project are stored in your Azure CLI profile — not in PowerShell env vars — so you only do this once per machine (or after switching orgs):

```powershell
az devops configure --defaults organization='https://dev.azure.com/myorg' project='My Project'
```

With those seven steps done, head to [Azure DevOps work-item shortcuts](#azure-devops) to set the optional `$env:AZ_*` profile variables and run `az-Connect-AzDevOps` to confirm everything is wired up.

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

> **Lost in the surface?** Run `az-help` (defined in `powcuts_by_cli/azdevops_help.ps1`) for an interactive `Out-ConsoleGridView` walkthrough that groups every `az-AzDevOps*` function by workflow phase (Onboarding → DailyRead → Create → MultiProject) and shows the order of operations + source / diagram / issue links for each function. `az-h<Tab>` lands directly on it.

PowerShell shortcuts in `powcuts_by_cli/azdevops_*.ps1` (split across `azdevops_auth.ps1`, `azdevops_paths.ps1`, `azdevops_sync.ps1`, `azdevops_views.ps1`, `azdevops_find.ps1`, `azdevops_classification.ps1`, `azdevops_create_pickers.ps1`, `azdevops_create.ps1`, `azdevops_schema.ps1`, `azdevops_openers.ps1`) provide guided setup and work-item navigation against an Azure DevOps organization. Today this includes a guided `az-Connect-AzDevOps` first-run helper, a cached background sync (`az-Sync-AzDevOpsCache`, which also refreshes itself silently on shell open when the cache is stale), a list/open pair for items assigned to you (`az-Get-AzDevOpsAssigned`, `az-Open-Assigned`), the matching pair for items where you've been @-mentioned in discussion (`az-Get-AzDevOpsMentions`, `az-Open-Mention`), an open-any-item-by-id shortcut (`az-Open-WorkItemById`), an Epic→Feature→User Story tree view (`az-Show-Tree`, rendering the project's requirement-tier rows — `User Story` on Agile, `Product Backlog Item` on Scrum, `Requirement` on CMMI, `Issue` on Basic), a board-style group-by-State view of the same cached items (`az-Show-Board`), an orphan finder that lists parentless Features and stories under the active area so stray items can be re-parented (`az-Show-Orphans`), area- and iteration-path tree views (`az-Show-Areas`, `az-Show-Iterations`), an interactive Epic→Feature→Story drill-down picker (`az-Find-AzDevOpsWorkItem`), an interactive new-user-story creator with parent-feature, iteration, and area-path pickers (`az-New-AzDevOpsUserStory`), an interactive new-Feature creator one tier up (parent-Epic picker, area / iteration / priority / AC) with a hand-off prompt to spawn child stories (`az-New-AzDevOpsFeature`), a top-tier Epic creator with no parent picker (`az-New-AzDevOpsEpic`) — which the Story and Feature creators can also spawn inline from their orphan path (pick "no parent" and they offer to create the missing Feature/Epic and link to it in one flow), a batch child-story creator that decomposes a Feature into 3-7 stories with a single area / iteration captured once and priority / story points carried forward across the loop (`az-New-AzDevOpsFeatureStories`), an interactive Task creator one tier down with a parent-User-Story picker (`az-New-Task`, also the child action when you select a Story in `az-Show-Tree` / `az-Show-Board`), and a per-org field-schema config (`az-Initialize-AzDevOpsSchema`, `az-Get-AzDevOpsSchema`, `az-Edit-AzDevOpsSchema`, `az-Test-AzDevOpsSchema`) that future schema-aware updates to the work-item commands consume.

### Prerequisites

The Azure CLI (`az`), the `azure-devops` extension, an active `az login` session, and your org/project defaults (`az devops configure --defaults`) all need to be in place. See **[Machine Setup: PowerShell Profile & Azure CLI](#machine-setup)** for the full from-zero walkthrough — or just run `az-Connect-AzDevOps`, which checks each prerequisite and offers to install the extension / start an `az login` for you on first run.

### Optional profile environment variables

Add any of these to your PowerShell `$profile` to enable additional features:

```powershell
$env:AZ_USER_EMAIL = 'user@example.com'   # enables accurate mentions WIQL
$env:AZ_AREA       = 'My Project\My Team' # default area path for hierarchy queries
$env:AZ_ITERATION  = 'My Project\Sprint 42' # default iteration for work item creation
$env:AZ_DEBRIEF_TEAM = 'alice@example.com;bob@example.com' # teammates taggable in unplanned-work debriefs
$env:BASHCUTS_NO_SPINNER = '1'            # opt out of the az-call loading spinner
```

Every AzDevOps command routes its underlying `az` call through one wrapper, which now shows a small terminal spinner while the call is in flight and clears it cleanly when the call returns — so a multi-second `az-Sync-AzDevOpsCache` or `az-New-AzDevOpsUserStory` always signals that work is happening. The spinner suppresses itself when output is redirected or piped (CI, `> out.txt`, `| cmd`) so it never leaks into captured JSON; set `BASHCUTS_NO_SPINNER` to turn it off everywhere.

### First run

In a fresh PowerShell terminal:

```powershell
az-Connect-AzDevOps
```

This walks through seven checks (Azure CLI present, `azure-devops` extension installed, env vars set, `az login` session active, `az devops` defaults configured, user-machine WIQL query files seeded, smoke `az boards query` succeeds) and prints a clear `READY` or `NOT READY` verdict at the end. It will offer to install the extension and run `az login` for you if either is missing.

After `az-Connect-AzDevOps` reports `READY` once, the read/sync commands (`az-Sync-AzDevOpsCache`, the schema commands) use the silent `az-Test-AzDevOpsAuth` check at startup to confirm the environment is still good before they hit the cache. The result is cached in-session for a few minutes so the check isn't repeated on every command. The `az-New-AzDevOps*` creators skip that live check entirely — they only confirm the `az` CLI is on PATH and let the `az boards work-item create` call itself surface any auth problem, so creating a work item makes no extra `az` round-trip beyond the create and parent-link.

### Customizing WIQL queries

The `hierarchy` dataset that `az-Sync-AzDevOpsCache` writes into `hierarchy.json` is built from three per-tier WIQL files on your own machine, not from code in this repo:

- POSIX: `~/.bashcuts-az-devops-app/config/queries/{epics,features,user-stories}.wiql`
- Windows: `%USERPROFILE%\.bashcuts-az-devops-app\config\queries\{epics,features,user-stories}.wiql`

Each sync fires one `az boards query` per file (epics, then features, then user stories) and merges the results into a single `hierarchy.json`. Splitting per tier sidesteps the partial-result behavior that the previous single combined query hit on larger projects, and lets you tune each tier's filter independently.

`az-Connect-AzDevOps` (and the first run of `az-Sync-AzDevOpsCache` if you skipped Connect) seeds each file with a sensible default — items under `{{AZ_AREA}}` scoped to one of `Microsoft.EpicCategory` / `Microsoft.FeatureCategory` / `Microsoft.RequirementCategory`, where `{{AZ_AREA}}` is substituted from `$env:AZ_AREA` at read time. Edit any file to add fields to the SELECT clause, filter by state, scope by tag, or otherwise tailor what lands in `hierarchy.json`. Re-run `az-Sync-AzDevOpsCache` to pick up your changes — no `reinit` needed, since the files are read every sync.

The fast way to open all three for editing is the dedicated shortcut:

```powershell
az-Open-HierarchyWiqls
```

It seeds any missing defaults (so it works on a fresh machine even before `az-Connect-AzDevOps`) and then opens each path in your OS default editor.

If you delete a file, the next sync writes that default back. The placeholder `{{AZ_AREA}}` is the only one currently supported; everything else in each file is passed through to `az boards query --wiql` verbatim.

### Opening cache / config / schema files

Every folder and file under `~/.bashcuts-az-devops-app/` has a dedicated opener — most under the `az-Open-*` prefix (tab-tab on `az-Open-` to see the full list), with the config-queries and schema directories under the `o-az-devops-*` open prefix. Each opener launches the path in your OS default handler (`Start-Process`); if the target doesn't exist yet it prints a one-line yellow hint pointing at the function that produces it (e.g. `az-Sync-AzDevOpsCache`) and returns without spawning anything.

Folders:

```powershell
az-Open-AppRoot                 # ~/.bashcuts-az-devops-app/
az-Open-CacheDir                # cache/  (or cache/<project-slug>/ when az-Use-AzDevOpsProject is active)
o-az-devops-queries-config-dir  # config/queries/
o-az-devops-schema-dir          # schema/
```

Cache files (all resolved through the active project slice):

```powershell
az-Open-AssignedCache    # assigned.json
az-Open-MentionsCache    # mentions.json
az-Open-HierarchyCache   # hierarchy.json
az-Open-IterationsCache  # iterations.json
az-Open-AreasCache       # areas.json
az-Open-LastSync         # last-sync.json
az-Open-SyncLog          # sync.log
```

Config WIQL files (per file; `az-Open-HierarchyWiqls` above remains the "open all three" convenience):

```powershell
az-Open-EpicsWiql        # config/queries/epics.wiql
az-Open-FeaturesWiql     # config/queries/features.wiql
az-Open-UserStoriesWiql  # config/queries/user-stories.wiql
```

Schema file (per-org `schema-<slug>.json`, falling back to `schema.json` when `$env:AZ_DEVOPS_ORG` is unset):

```powershell
az-Open-Schema
```

### Day-to-day work-item shortcuts

These read the local cache populated by `az-Sync-AzDevOpsCache` (which also runs silently in the background on shell open when the cache is stale — see below). They never call `az` directly, so they return instantly.

```powershell
az-Get-AzDevOpsAssigned                       # everything assigned to you (excludes Closed/Removed)
az-Get-AzDevOpsAssigned -State Active         # filter to a single state
az-Get-AzDevOpsAssigned -State Active,New     # filter to multiple states
az-Get-AzDevOpsAssigned | Format-Table -AutoSize

az-Open-Assigned 12345                        # open one of your assigned items in the browser
az-Open-WorkItemById 12345                    # open ANY work item by id in the browser (no cache lookup; works even if it isn't assigned to / mentioning you)

az-Get-AzDevOpsMentions                                  # work items where you've been @-mentioned (excludes items you're already assigned to)
az-Get-AzDevOpsMentions -State Active                    # filter to a single state
az-Get-AzDevOpsMentions -Since (Get-Date).AddDays(-7)    # only mentions whose last activity was in the past week
az-Get-AzDevOpsMentions -IncludeAssigned                 # also surface mentioned items already assigned to you
az-Get-AzDevOpsMentions | Format-Table -AutoSize

az-Open-Mention 12345                         # open one of your mentioned items in the browser

az-Show-Tree                          # Epic -> Feature -> User Story tree; select a row to open it or create a child work item
az-Show-Board                         # board view: cached items grouped by State (click the State header in the grid to group)
az-Show-Board -State Active,New       # filter to one or more states (default excludes Closed/Removed)
az-Show-Board -State Closed,Resolved  # flip to the archive view
az-Show-Board -Type Bug,Task          # custom-template work-item types (default: Epic, Feature, User Story)

az-Show-Epics                         # Epics from the active project's hierarchy cache; select a row to open it or create a child Feature
az-Show-Epics -State Closed,Resolved  # flip to the archive view
                                      # tick several rows -> prompted to open them all in the browser at once

az-Show-Features                      # cross-project Features view: every project in $global:AzDevOpsProjectMap, tagged with a Project column
az-Show-Features -Project ProjectABC  # narrow to one registered project's Features (no need to az-Use-AzDevOpsProject first)
az-Show-Features -State Closed        # flip to the archive view across all projects

az-Show-Orphans                       # parentless Features + stories under the active area (Epics excluded - they're roots); select a row to open it or create a child
az-Show-Orphans -Area 'ProjABC\Team'  # narrow to a sub-path of the cached area
az-Show-Orphans -State Closed,Resolved # include closed orphans (default shows active only)

az-Show-Areas                         # print the project's area-path tree (cache-first, live fallback)
az-Show-Iterations                    # print the project's iteration-path tree (with start/finish dates)

az-Get-AzDevOpsAreas                          # pipeable rows for the area tree (Depth / Name / Path / HasChildren)
az-Get-AzDevOpsIterations                     # pipeable iteration rows + [datetime]? StartDate / FinishDate, e.g.:
az-Get-AzDevOpsIterations | Where-Object { $_.StartDate -le (Get-Date) -and $_.FinishDate -ge (Get-Date) }  # the current sprint

az-Find-AzDevOpsWorkItem                      # interactive drill-down: pick an Epic, then a Feature, then a Story; '.. [Go Back]' climbs a tier; '.. [Open this <Type>]' launches the browser; loops until you pick 'EXIT' or hit Esc
az-Find-AzDevOpsWorkItem -IncludeClosed       # include Closed/Removed items in the drill-down grids
az-Find-AzDevOpsArea                          # pick an area path from the tree; emits the picked Path on the pipeline
az-Find-AzDevOpsIteration                     # pick an iteration; grid shows StartDate / FinishDate columns; emits Path
az-Find-AzDevOpsProject                       # pick from $global:AzDevOpsProjectMap (Active / Name / Project / Org)
az-Find-AzDevOpsProject -Use                  # ... and switch to it (calls az-Use-AzDevOpsProject on the pick)
```

If the cache is older than 6 hours, `az-Get-AzDevOpsAssigned`, `az-Get-AzDevOpsMentions`, `az-Show-Tree`, `az-Show-Board`, `az-Show-Epics`, `az-Show-Features`, `az-Show-Orphans`, `az-Show-Areas`, `az-Show-Iterations`, and `az-Find-AzDevOpsWorkItem` each print a one-line `WARNING stale (last sync: ...)` notice above their output and still render the cached data.

**Automatic on-open refresh.** You don't have to schedule anything. Every time a PowerShell session loads bashcuts, it checks the cache age and — if it's stale (older than 6 hours, or never synced) — spawns a detached, hidden `pwsh` that runs `az-Sync-AzDevOpsCache` in the background. Your prompt returns instantly and no sync chatter prints into the terminal; the next command you run reads the freshly-updated cache (the background sync's progress goes to `~/.bashcuts-az-devops-app/cache/sync.log`). The background process does the network auth check itself and exits quietly if you're not connected, so a not-connected shell is a silent no-op. To disable this entirely, set `$env:AZ_DEVOPS_NO_AUTOSYNC = '1'` in your `$profile` (run `az-Sync-AzDevOpsCache` by hand when you want a refresh). A short-lived lock under the cache directory keeps several terminals opened in quick succession from each kicking off a sync.

`az-Show-Tree` (and any future hierarchy-view commands) include a `Url` column on every row so you can copy or click straight to the work item from `Out-ConsoleGridView`.

After you select a row in `az-Show-Tree`, `az-Show-Board`, `az-Show-Epics`, `az-Show-Features`, or `az-Show-Orphans`, you're prompted to either open the item in your browser or create the hierarchically-appropriate child work item — a Feature under an Epic, a User Story under a Feature, or a Task under a User Story (via `az-New-Task`) — with the selected row pre-filled as the new item's parent. When you tick **more than one** row, you're first offered a single "Open all N in browser?" shortcut (Enter opens them all); decline it to fall through to the per-row open/create-child prompt. Selecting a node in `az-Show-Areas` / `az-Show-Iterations` offers to open the project's Boards hub. (The post-selection prompt is PowerShell-only; the bash `az-show-features` shortcut prints a static query table.)

Every list and picker (`az-Get-AzDevOpsAssigned`, `az-Get-AzDevOpsMentions`, `az-Get-AzDevOpsSchema`, `az-Get-AzDevOpsCacheStatus`, `az-Show-Tree`, `az-Show-Board`, `az-Show-Epics`, `az-Show-Features`, `az-Show-Orphans`, `az-Show-Areas`, `az-Show-Iterations`, `az-Find-AzDevOpsWorkItem`, plus the parent-Feature / iteration / area pickers in `az-New-AzDevOpsUserStory`) renders through `Out-ConsoleGridView` — a sortable, filterable, click-to-select TUI grid that runs in your terminal on Windows, macOS, and Linux. Use the arrow keys to navigate, `Space` to select rows, `Enter` to confirm, `Esc` to cancel. Selected rows from the listing functions are emitted to the pipeline, so e.g. `az-Get-AzDevOpsAssigned | ForEach-Object { az-Open-Assigned $_.Id }` opens every row you ticked. The grid ships in a separate module — install once with `Install-Module Microsoft.PowerShell.ConsoleGuiTools -Scope CurrentUser`. If the module isn't installed, every command falls back to the existing `Format-Table` / numbered-menu output — except `az-Find-AzDevOpsWorkItem`, which is grid-only by design and prints the install hint above instead of running.

`az-Sync-AzDevOpsCache` populates two more cache files alongside the existing `assigned.json` / `mentions.json` / `hierarchy.json`: `iterations.json` and `areas.json`. The new-user-story command below uses these for instant iteration / area-path pickers; if you've upgraded but haven't re-synced yet, the picker fetches them live with a one-line "(run az-Sync-AzDevOpsCache to make this instant)" notice.

#### Verb coverage at a glance

Tab-tab on `az-Get-`, `az-Show-`, or `az-Find-` to discover commands. The matrix is also kept inline at the top of `powcuts_by_cli/azdevops_auth.ps1`.

| Noun                  | `az-Get-`             | `az-Show-`         | `az-Find-`  |
|-----------------------|-----------------------|--------------------|-------------|
| Project               | `Projects`            | `Project`          | `Project`   |
| Work Item (hierarchy) | —                     | `Tree`, `Board`, `Epics` | `WorkItem`  |
| Work Item (assigned)  | `Assigned` (pickable) | —                  | —           |
| Work Item (mentions)  | `Mentions` (pickable) | —                  | —           |
| Area                  | `Areas`               | `Areas`            | `Area`      |
| Iteration             | `Iterations`          | `Iterations`       | `Iteration` |
| Cache                 | `CacheStatus`         | —                  | —           |
| Schema                | `Schema`              | —                  | —           |

`az-Get-*` returns pipeable rows (`[PSCustomObject]`); `az-Show-*` writes a human-readable view; `az-Find-*` is an interactive picker over `Out-ConsoleGridView` that emits the picked value on the pipeline. `Assigned` / `Mentions` already open a grid via `Show-AzDevOpsRows -PassThru` so they double as pickers; that's why there is no separate `Show-` or `Find-` for them.

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

`-FeatureId 0` creates an orphan (no parent link) with no prompt. `-NoOpen` skips the browser launch and just echoes the new work-item URL — handy in scripts.

When you reach the parent-Feature picker interactively and pick `0` / cancel (orphan), the creator asks `Create a new parent Feature now? [y/N]` first. On **yes** it runs the full `az-New-AzDevOpsFeature` walk-through (which can itself chain up to a new Epic), then links your new Story to the Feature it just created — so you can build a fresh Epic → Feature → Story slice in one command. On **no/Enter** it creates the orphan exactly as before. (Passing `-FeatureId 0` explicitly still means "force orphan" and skips this prompt.)

### Creating a new Feature

`az-New-AzDevOpsFeature` is the tier-one-up counterpart to the user-story creator. It walks you through title / description / priority, then offers an interactive picker for the parent Epic (active Epics pulled from `hierarchy.json`), the iteration, and the area path. Same `Out-ConsoleGridView` / Read-Host fallback rules. The description is built from two guided prompts — **Summary** and **Business Value** — each rendered as a bold heading in the work-item Description field. Story points and acceptance criteria are intentionally skipped — Features don't carry story points in the default Agile / Scrum templates, and acceptance criteria belong on the child User Stories.

After it creates the Feature and links the chosen Epic, it asks `Add child stories now? [Y/n]`; on yes it hands off to `az-New-AzDevOpsFeatureStories -ParentId <newFeatureId>` with the same area / iteration pre-seeded so you can decompose the Feature into its child stories in the same flow. Pass `-NoChildStoriesPrompt` to skip the hand-off (useful in scripts).

```powershell
az-New-AzDevOpsFeature                                  # full interactive walk-through
az-New-AzDevOpsFeature `
    -Title        "Customer impact dashboard" `
    -Description  "Surface customer-impact rollups on the team home page." `
    -Priority     2 `
    -ParentEpicId 1180 `
    -Iteration    "My Project\Sprint 42" `
    -Area         "My Project\My Team" `
    -NoOpen `
    -NoChildStoriesPrompt
```

`-ParentEpicId 0` creates an orphan (no parent link) with no prompt.

Just like the user-story creator, picking `0` / cancel at the interactive parent-Epic picker prompts `Create a new parent Epic now? [y/N]`. On **yes** it runs `az-New-AzDevOpsEpic` and links your new Feature to it; on **no/Enter** it creates the orphan as before. (Explicit `-ParentEpicId 0` skips the prompt.)

### Creating a new Epic

`az-New-AzDevOpsEpic` is the top tier of the Epic → Feature → Story hierarchy, so it has **no parent picker** — Epics are root items. It mirrors `az-New-AzDevOpsFeature`'s walk-through otherwise (title / description / priority / iteration / area / tags / required fields), then creates the Epic and opens it in your browser. It returns the new Epic's `[int]` id, which is what makes it usable as the inline "create a parent Epic" target from `az-New-AzDevOpsFeature`'s orphan path. Story points and the child-stories hand-off are intentionally skipped — those belong to the lower tiers.

```powershell
az-New-AzDevOpsEpic                                # full interactive walk-through
az-New-AzDevOpsEpic `
    -Title       "Customer-impact analytics" `
    -Description "All customer-impact reporting work for FY26." `
    -Priority    2 `
    -Iteration   "My Project\Sprint 42" `
    -Area        "My Project\My Team" `
    -NoOpen
```

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

Every Azure DevOps org configures its own required + custom fields via process templates (e.g. a "Customer Impact" required field on every User Story, or a "Compliance Risk" picklist). The schema-management commands let you declare those fields once per org so future schema-aware updates to `az-New-AzDevOpsUserStory`, `az-Get-AzDevOpsAssigned`, `az-Show-Tree`, etc. can prompt for / surface them automatically.

The schema lives at `$HOME/.bashcuts-az-devops-app/schema/schema-<org>.json` (per-org keyed off `$env:AZ_DEVOPS_ORG`; falls back to `schema.json` when unset). The directory is created with `0700` permissions on macOS / Linux; Windows inherits the user-only ACL from `%USERPROFILE%`.

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

<br>

***

<br>

# <a name="timer-sessions"></a>Timer sessions

`Start-TimerSession` runs a focus-timer Pomodoro against an item from one of your registered integrations and auto-posts your debrief notes as a discussion comment on the chosen item. The Azure DevOps integration is registered out of the box — it reads your cached assigned items (`az-Sync-AzDevOpsCache`), shows them sorted by State + Priority, and posts the debrief via `az boards work-item update --discussion`.

### Run a session

```powershell
# 25-minute default
Start-TimerSession

# Custom duration
Start-TimerSession -Minutes 45

# Skip the integration picker (one registered integration is also auto-selected)
Start-TimerSession -Integration 'Azure DevOps - User Stories'
```

Flow:
1. Pick an integration (skipped when `-Integration` is supplied or only one is registered)
2. Pick an item from the integration's grid
3. Countdown runs for `$Minutes` — WPF circular overlay on Windows, snake animation on macOS/Linux
4. Capture your debrief (`debrief notes`, `what's next`) → comment posted on the picked item

### The debrief

On **Windows** the countdown morphs into a themed debrief form that shares the timer's dark/blue style: one window with a **Debrief** field and a **Next step** field plus a **Post Debrief** button. While the comment posts, the button is replaced by a spinner / `Posting...` state, and the **Start another session?** choice only appears once the comment posts successfully — so you always know the debrief landed before deciding whether to loop into a fresh timer. The choice is three buttons: **Same item** reopens a new countdown on the work item you just debriefed (skipping both the integration and item pickers so you can keep grinding on the same ID), **Pick another** loops back to the picker, and **Done** ends the session. Right-click the form to cancel without posting. A failed post keeps the form open with the error so you can retry.

On **macOS/Linux** the debrief is collected with terminal `Read-Host` prompts after the snake animation, and a `Posting...` indicator shows while the comment is sent.

### Closing the story when a session finishes the task

When the chosen integration supplies a `CloseItem` capability, the debrief surface adds a one-click way to transition the work item to its done state right after the comment lands — so a session that actually finished the task doesn't leave the item lingering in **Active**. On **Windows** the debrief form renders a **Work complete — resolve this story** checkbox above **Post Debrief**; ticking it makes the post sequence run the comment, then the state transition, and reports both outcomes before the **Start another session?** choice appears. On **macOS/Linux** the same trigger is a `Resolve this item now? [y/N]` prompt that follows a successful comment post (default **No** — your work item is never resolved without an explicit yes).

The built-in **Azure DevOps** integration maps `CloseItem` to `System.State=Resolved` (Agile process: New → Active → Resolved → Closed). Override with a single line in your `$profile` if your process template uses a different done-state:

```powershell
$script:TimerCloseState = 'Done'   # Scrum / Basic process
```

A failed state transition (e.g. an invalid workflow move) is reported distinctly — the comment still lands; the resolve verdict tells you the state update didn't, so you can fix it in the AzDO UI without losing the debrief.

### Interrupting a session

Press **Esc** during the countdown (or use **Mark Complete Early** on the Windows overlay) to end the session early and still go through the debrief. The posted comment header reflects the outcome:

- Completed: `Pomodoro complete — 25:00`
- Interrupted: `Session interrupted at 04:30 of 25:00`

On both platforms the **Start another session?** choice appears after every successful post (completed or interrupted). On macOS/Linux it's a terminal prompt — `[s] Same item / [p] Pick another item / [d] Done` (blank or `d` ends the session) — mirroring the Windows buttons: **Same item** loops straight back to the countdown on the work item you just debriefed, **Pick another** returns to the picker so you can pivot to a different story / integration without retyping the command. **Ctrl-C** is still a hard exit — no debrief, no comment.

### Registering your own integration

Add to your `$profile` (or any file dot-sourced from it). Registering with an existing `Name` replaces the prior entry, so you can override the built-in AzDO integration without touching tracked code.

```powershell
Register-TimerIntegration `
    -Name        'My Tracker' `
    -Description 'Items from my custom tracker' `
    -FetchItems  {
        # Return rows with at least Id, Type, State, Title.
        # Optional: Priority, Iteration, anything else you want in the picker.
        Get-MyTrackerItems | Where-Object { $_.Status -ne 'Done' }
    } `
    -AddComment  {
        param([Parameter(Mandatory)] [int] $Id, [Parameter(Mandatory)] [string] $Body)
        Add-MyTrackerComment -Id $Id -Body $Body
    } `
    -ViewHint    {
        param([Parameter(Mandatory)] [int] $Id)
        "View: my-tracker open $Id"
    } `
    -CloseItem   {
        # Optional. When present, the debrief shows a resolve checkbox
        # (Windows) / `Resolve this item now? [y/N]` prompt (terminal) that
        # fires after a successful comment post.
        param([Parameter(Mandatory)] [int] $Id)
        Set-MyTrackerItemDone -Id $Id
    }
```

<br>

***

# <a name="unplanned-work"></a>Unplanned work sessions

`Start-UnplannedWork` is the free-for-all companion to the Pomodoro timer for firefighting that can't be time-boxed. Each day rolls up under a single **Unplanned Work — yyyy-MM-dd** User Story; every firefight you start becomes a child **Task** with its own debrief. PowerShell-only, like the timer (the Windows balloon reminder and key-poll loop have no bash counterpart).

### Run a session

```powershell
# Prompts for the firefight title, reminds every 5 min
Start-UnplannedWork

# Skip the title prompt, custom reminder cadence
Start-UnplannedWork -Title 'Help Dana with the deploy' -ReminderMinutes 10

# No balloon reminder
Start-UnplannedWork -NoReminder
```

Flow:
1. Prompts for the firefight title, then starts the session **immediately** — no waiting on Azure DevOps round-trips up front (the story and Task are created when you stop, at debrief time)
2. Runs a foreground session — press **Space** to log a timestamped item, **Esc/Q** to stop (Windows shows a circular WPF stopwatch overlay; macOS/Linux a terminal counter)
3. A reminder balloon pops every `-ReminderMinutes` until you stop
4. On stop: today's daily **Unplanned Work** story is found or created (its id is cached for the rest of the day, so the next firefight grabs it instantly) and a child **Task** for this firefight is created and linked; captured items flush to the Task **description**, then you're prompted for debrief notes and whether there's an opportunity for a new feature / user story to prevent the firefight in future (it can spin one up via `az-New-AzDevOpsUserStory`). A single debrief comment (time spent + notes + opportunity) is posted on the Task.

Start three separate firefights in a day and you get three Tasks under the one daily story — exactly the "three different chats, three different efforts" shape.

### End-of-day roll-up

```powershell
# Today
New-UnplannedWorkDebrief

# A past day
New-UnplannedWorkDebrief -Date 2026-05-19
```

Reads the day's local ledger (kept under the AzDO cache dir so total time can be summed — AzDO doesn't store per-session minutes), prints the per-Task breakdown with total time, and on confirm posts a roll-up comment on the daily story.

### Tagging teammates

Set `$env:AZ_DEBRIEF_TEAM` to a `;`-separated list of teammate emails (names work too) to make people taggable from the debrief flow. Commas also work as separators, so avoid them inside a value (use emails, which never contain a comma):

```powershell
$env:AZ_DEBRIEF_TEAM = 'alice@example.com;bob@example.com'
az-Sync-UnplannedTeam   # resolve the roster to Azure DevOps identities and cache it
```

`az-Sync-UnplannedTeam` resolves each entry to an Azure DevOps identity (display name + email + identity id) via the identities API and caches it under the AzDO cache dir next to the per-day ledger — re-run it whenever you change the env var. Both debriefs (the per-firefight `Start-UnplannedWork` stop and the `New-UnplannedWorkDebrief` roll-up) then ask **"Tag teammate(s) on this debrief?"**. Answer yes and you get a type-to-filter picker showing each teammate's **name and email** so you can confirm the right person; the ones you pick are added to the posted comment as real Azure DevOps `@`-mentions, so they're notified. Tagging is always optional — pick nobody (or skip the prompt) and the debrief posts exactly as before.

