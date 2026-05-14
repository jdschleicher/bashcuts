# ============================================================================
# Azure DevOps Work-Item Shortcuts
# ============================================================================
#
# Foundation file for Azure DevOps work-item navigation shortcuts.
#
# User-facing functions:
#   az-Connect-AzDevOps            - interactive first-run auth + setup helper
#                                    (run once on a fresh machine, or any time
#                                    auth feels stale)
#   az-Test-AzDevOpsAuth           - silent yes/no auth assertion intended for
#                                    callers in later AzDevOps commands;
#                                    returns $true / $false
#   az-Open-AzDevOpsHierarchyWiqls - open each ~/.bashcuts-az-devops-app/config/
#                                    queries/{epics,features,user-stories}.wiql
#                                    in the default editor (seeds the defaults
#                                    on first run)
#
# Step functions invoked by az-Connect-AzDevOps (also exposed for direct use,
# e.g. to debug a single failing step). Each returns a [PSCustomObject]
# with Ok (bool) and FailMessage (string or $null) properties, and prints
# its own status:
#   az-Confirm-AzDevOpsCli              - step 1 (CLI on PATH + version echo)
#   az-Confirm-AzDevOpsExtension        - step 2 (azure-devops extension; offers install)
#   az-Confirm-AzDevOpsEnvVars          - step 3 (required $profile env vars set)
#   az-Confirm-AzDevOpsLogin            - step 4 (az login session; offers login)
#   az-Set-AzDevOpsDefaults             - step 5 (az devops configure --defaults)
#   az-Confirm-AzDevOpsQueryFiles       - step 6 (seed ~/.bashcuts-az-devops-app/config WIQL files)
#   az-Confirm-AzDevOpsSmokeQuery       - step 7 (az boards query smoke test)
#
# Silent diagnostic helpers (pure checks, no I/O — used by az-Test-AzDevOpsAuth):
#   Test-AzDevOpsCliPresent          - is the `az` CLI on PATH?
#   Test-AzDevOpsExtensionInstalled  - is the `azure-devops` extension installed?
#   Test-AzDevOpsLoggedIn            - does `az account show` succeed?
#   Invoke-AzDevOpsSmokeQuery        - runs WIQL "items assigned to me",
#                                       returns count or $null on failure
#
# Required setup (run once):
#   az devops configure --defaults organization=https://dev.azure.com/myorg project="My Project"
#   (or run az-Connect-AzDevOps which walks you through this interactively)
#
# Optional $profile environment variables:
#
#   $env:AZ_USER_EMAIL = 'user@example.com'              # your AAD email (mentions WIQL)
#   $env:AZ_AREA       = 'My Project\My Team'            # default area path (hierarchy WIQL)
#   $env:AZ_ITERATION  = 'My Project\Sprint 42'          # default iteration (work item creation)
#
# Prereqs:
#   - Azure CLI        : https://aka.ms/installazurecli
#   - azure-devops ext : az extension add --name azure-devops
#
# First-run:
#   PS> az-Connect-AzDevOps
#
# ----------------------------------------------------------------------------
# Verb coverage matrix (az-Get- / az-Show- / az-Find- across nouns)
#
# Verb contracts:
#   az-Get-*   - returns [PSCustomObject] rows for the pipeline; may also open
#                Show-AzDevOpsRows -PassThru so the same call doubles as an
#                interactive grid (Assigned / Mentions).
#   az-Show-*  - writes a human-readable view (tree / board / table); no
#                pipeline data.
#   az-Find-*  - interactive drill-down via Out-ConsoleGridView; emits the
#                picked value(s) on the pipeline. Prints an install hint and
#                returns when Microsoft.PowerShell.ConsoleGuiTools is missing.
#
# Coverage:
#                          Get-                  Show-                Find-
#   Project                Projects              Project              Project
#   Work Item (hierarchy)  --                    Tree, Board          WorkItem
#   Work Item (assigned)   Assigned [pickable]   --                   --
#   Work Item (mentions)   Mentions [pickable]   --                   --
#   Area                   Areas                 Areas                Area
#   Iteration              Iterations            Iterations           Iteration
#   Cache                  CacheStatus           --                   --
#   Schema                 Schema                --                   --
#
# Deliberately-empty cells:
#   Assigned / Mentions Show-: az-Get-* already grid-renders; Show- would dupe.
#   Cache / Schema Show- / Find-: no tree to drill, no pick semantics.
#   Hierarchy Get-: Tree and Board cover the listing surface; Find- emits IDs.
# ============================================================================


# ---------------------------------------------------------------------------
# Silent diagnostic helpers (no I/O; safe for az-Test-AzDevOpsAuth callers)
# ---------------------------------------------------------------------------

function Test-AzDevOpsCliPresent {
    return [bool](Get-Command az -ErrorAction SilentlyContinue)
}


function Test-AzDevOpsExtensionInstalled {
    $name = az extension list --query "[?name=='azure-devops'].name" -o tsv 2>$null
    return ($LASTEXITCODE -eq 0 -and $name -eq 'azure-devops')
}


function Test-AzDevOpsLoggedIn {
    $null = az account show 2>$null
    return ($LASTEXITCODE -eq 0)
}


function Invoke-AzDevOpsSmokeQuery {
    $wiql = 'Select [System.Id] From WorkItems Where [System.AssignedTo] = @Me'
    $result = Invoke-AzDevOpsBoardsQuery -Wiql $wiql
    if ($result.ExitCode -ne 0) {
        return $null
    }

    try {
        $items = $result.Json | ConvertFrom-Json
        return @($items).Count
    }
    catch {
        return $null
    }
}


function az-Test-AzDevOpsAuth {
    if (-not (Test-AzDevOpsCliPresent)) {
        return $false
    }
    if ($null -eq (Invoke-AzDevOpsSmokeQuery)) {
        return $false
    }

    return $true
}


function Assert-AzDevOpsAuthOrAbort {
    # Standard auth-test-and-abort prologue used by every command that calls
    # az on the user's behalf (az-Sync-AzDevOpsCache, az-New-AzDevOpsUserStory,
    # az-Initialize-AzDevOpsSchema, az-Test-AzDevOpsSchema). Returns $true when
    # auth is good. On failure, prints the standard "<command> aborted -
    # az-Test-AzDevOpsAuth returned false. Run az-Connect-AzDevOps." line and
    # returns $false so callers `if (-not (Assert-...)) { return }`.
    param([Parameter(Mandatory)] [string] $CommandName)

    if (az-Test-AzDevOpsAuth) {
        return $true
    }

    Write-Host "$CommandName aborted - az-Test-AzDevOpsAuth returned false. Run az-Connect-AzDevOps." -ForegroundColor Red
    return $false
}


# ---------------------------------------------------------------------------
# Step functions invoked by az-Connect-AzDevOps. Each owns its print + I/O for
# one step and returns a [PSCustomObject] with Ok (bool) and FailMessage
# (string or $null) properties.
# ---------------------------------------------------------------------------

function New-AzDevOpsStepResult {
    param(
        [Parameter(Mandatory)] [bool] $Ok,
        $FailMessage = $null
    )
    return [PSCustomObject]@{ Ok = $Ok; FailMessage = $FailMessage }
}


function Read-AzDevOpsYesNo {
    # Default-yes Y/n prompt used by Confirm-* steps that offer a remediation
    # action. Returns $true when the user accepts (empty input or anything
    # other than n/no), $false on explicit refusal.
    param([Parameter(Mandatory)] [string] $Prompt)
    $resp = Read-Host "    $Prompt [Y/n]"
    return -not ($resp -match '^(n|no)$')
}


function az-Confirm-AzDevOpsCli {
    if (-not (Test-AzDevOpsCliPresent)) {
        Write-Host "  X az CLI not on PATH" -ForegroundColor Red
        if ($IsWindows) {
            Write-Host "    Install via: winget install Microsoft.AzureCLI"
            Write-Host "    Or see: https://aka.ms/installazurecli"
        }
        elseif ($IsMacOS) {
            Write-Host "    Install via: brew install azure-cli"
            Write-Host "    Or see: https://aka.ms/installazurecli-mac"
        }
        else {
            Write-Host "    See: https://learn.microsoft.com/cli/azure/install-azure-cli-linux"
        }
        return New-AzDevOpsStepResult -Ok $false -FailMessage 'az CLI missing'
    }
    $azVersion = (az version --output json 2>$null | ConvertFrom-Json).'azure-cli'
    Write-Host "  OK  az CLI present (v$azVersion)" -ForegroundColor Green
    return New-AzDevOpsStepResult -Ok $true
}


function az-Confirm-AzDevOpsExtension {
    if (-not (Test-AzDevOpsExtensionInstalled)) {
        Write-Host "  !  azure-devops extension not installed" -ForegroundColor Yellow
        if (-not (Read-AzDevOpsYesNo -Prompt 'Install now?')) {
            Write-Host "    Hint: az extension add --name azure-devops"
            return New-AzDevOpsStepResult -Ok $false -FailMessage 'extension missing'
        }
        az extension add --name azure-devops 2>&1 | Out-Host
        if (-not (Test-AzDevOpsExtensionInstalled)) {
            return New-AzDevOpsStepResult -Ok $false -FailMessage 'extension install failed'
        }
    }
    Write-Host "  OK  azure-devops extension installed" -ForegroundColor Green
    return New-AzDevOpsStepResult -Ok $true
}


function az-Confirm-AzDevOpsEnvVars {
    # Org and project come from `az devops configure --defaults` (the user's
    # Microsoft profile). AZ_USER_EMAIL and AZ_AREA are optional but improve
    # the mentions WIQL and hierarchy query respectively.
    if ($env:AZ_USER_EMAIL) {
        Write-Host "  OK  AZ_USER_EMAIL = $env:AZ_USER_EMAIL" -ForegroundColor Green
    } else {
        Write-Host "  --  AZ_USER_EMAIL not set (mentions WIQL will use '@' fallback)" -ForegroundColor DarkYellow
        Write-Host "      Add to `$profile: `$env:AZ_USER_EMAIL = 'you@example.com'"
    }

    if ($env:AZ_AREA) {
        Write-Host "  OK  AZ_AREA = $env:AZ_AREA" -ForegroundColor Green
    } else {
        Write-Host "  --  AZ_AREA not set (hierarchy WIQL token {{AZ_AREA}} will need manual edit)" -ForegroundColor DarkYellow
        Write-Host "      Add to `$profile: `$env:AZ_AREA = 'My Project\My Team'"
    }

    return New-AzDevOpsStepResult -Ok $true
}


function az-Confirm-AzDevOpsProjectMap {
    # Validates `$global:AzDevOpsProjectMap` when it's defined; silently passes
    # when it isn't (multi-project mode is opt-in). When the map is defined but
    # `$global:AzDevOpsDefaultProject` is unset, prompts the user with a numbered
    # menu of project names and calls az-Use-AzDevOpsProject -Quiet on the
    # choice. When the active project is missing required keys (Org / Project),
    # returns Ok=$false with a clear FailMessage so the orchestrator bails.
    if (-not (Get-Command Test-AzDevOpsProjectMapDefined -ErrorAction SilentlyContinue)) {
        Write-Host "  -- Skipped (multi-project resolver layer not loaded)" -ForegroundColor DarkGray
        return New-AzDevOpsStepResult -Ok $true
    }

    if (-not (Test-AzDevOpsProjectMapDefined)) {
        Write-Host "  -- Skipped (`$global:AzDevOpsProjectMap not defined - single-project mode)" -ForegroundColor DarkGray
        return New-AzDevOpsStepResult -Ok $true
    }

    $activeName = Get-AzDevOpsActiveProjectName
    if (-not $activeName) {
        Write-Host "  !  `$global:AzDevOpsProjectMap defined but no active project chosen" -ForegroundColor Yellow

        $names = @($global:AzDevOpsProjectMap.Keys | Sort-Object)
        Write-Host ""
        Write-Host "    Available projects:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $names.Count; $i++) {
            Write-Host ("      {0}. {1}" -f ($i + 1), $names[$i])
        }

        $idx = 0
        while ($true) {
            $resp = Read-Host "    Pick a project (1..$($names.Count))"
            if ([int]::TryParse($resp, [ref]$idx) -and $idx -ge 1 -and $idx -le $names.Count) {
                break
            }
            Write-Host "      Please enter 1..$($names.Count)." -ForegroundColor Yellow
        }

        $activeName = $names[$idx - 1]
        az-Use-AzDevOpsProject -Name $activeName -Quiet
    }

    $config = Get-AzDevOpsActiveProjectConfig
    if ($null -eq $config) {
        return New-AzDevOpsStepResult -Ok $false -FailMessage "active project '$activeName' missing from `$global:AzDevOpsProjectMap"
    }

    foreach ($requiredKey in @('Org', 'Project')) {
        if (-not $config.ContainsKey($requiredKey) -or -not $config[$requiredKey]) {
            return New-AzDevOpsStepResult -Ok $false -FailMessage "project '$activeName' missing required key '$requiredKey' in `$global:AzDevOpsProjectMap"
        }
    }

    Write-Host "  OK  Active project: $activeName" -ForegroundColor Green
    return New-AzDevOpsStepResult -Ok $true
}


function az-Confirm-AzDevOpsLogin {
    if (-not (Test-AzDevOpsLoggedIn)) {
        Write-Host "  !  No active az login session" -ForegroundColor Yellow
        if (-not (Read-AzDevOpsYesNo -Prompt "Run 'az login' now?")) {
            Write-Host "    Hint: az login"
            return New-AzDevOpsStepResult -Ok $false -FailMessage 'not logged in'
        }
        az login | Out-Host
        if (-not (Test-AzDevOpsLoggedIn)) {
            return New-AzDevOpsStepResult -Ok $false -FailMessage 'az login failed'
        }
    }
    $account = az account show --output json 2>$null | ConvertFrom-Json
    Write-Host "  OK  Logged in as $($account.user.name) (sub: $($account.name))" -ForegroundColor Green
    return New-AzDevOpsStepResult -Ok $true
}


function az-Set-AzDevOpsDefaults {
    # Shows the currently-configured az devops defaults (stored in the user's
    # Microsoft profile via `az devops configure --defaults`). Guides the user
    # to set them if either is missing; the smoke query in the next step will
    # surface auth/scope failures if defaults aren't pointing at a valid org.
    $defaults = Get-AzDevOpsConfiguredDefaults

    if ($defaults.Org) {
        Write-Host "  OK  organization = $($defaults.Org)" -ForegroundColor Green
    } else {
        Write-Host "  !   organization not configured" -ForegroundColor Yellow
        Write-Host "      Run: az devops configure --defaults organization=https://dev.azure.com/myorg"
    }

    if ($defaults.Project) {
        Write-Host "  OK  project = $($defaults.Project)" -ForegroundColor Green
    } else {
        Write-Host "  !   project not configured" -ForegroundColor Yellow
        Write-Host "      Run: az devops configure --defaults project=`"My Project`""
    }

    return New-AzDevOpsStepResult -Ok $true
}


function az-Confirm-AzDevOpsQueryFiles {
    $init = Initialize-AzDevOpsQueryFiles

    $newlySeeded = @($init.Seeded | Where-Object { $_.Seeded })

    if ($newlySeeded.Count -gt 0) {
        foreach ($entry in $newlySeeded) {
            Write-Host "  OK  Wrote default $($entry.Name).wiql to $($entry.Path)" -ForegroundColor Green
        }
        Write-Host "      Edit these files to customize what az-Sync-AzDevOpsCache fetches." -ForegroundColor DarkGray
    } else {
        Write-Host "  OK  Query files at $($init.Paths.QueriesDir)" -ForegroundColor Green
    }

    $stepResult = New-AzDevOpsStepResult -Ok $true
    return $stepResult
}


function az-Open-AzDevOpsHierarchyWiqls {
    # Opens all user-machine WIQL files (epics, features, user-stories,
    # assigned, mentions) in the OS default editor. Defensively seeds the
    # defaults via Initialize-AzDevOpsQueryFiles so a fresh machine that
    # skipped az-Connect-AzDevOps can still discover and customize the
    # queries in one step (no "file not found" detour).
    $init = Initialize-AzDevOpsQueryFiles

    foreach ($entry in $init.Seeded) {
        if ($entry.Seeded) {
            Write-Host "Wrote default $($entry.Name).wiql to $($entry.Path) - opening for editing" -ForegroundColor Green
        } else {
            Write-Host "Opening $($entry.Path)" -ForegroundColor DarkGray
        }

        Start-Process $entry.Path
    }
}


function az-Confirm-AzDevOpsSmokeQuery {
    $count = Invoke-AzDevOpsSmokeQuery
    if ($null -eq $count) {
        Write-Host "  X Smoke query failed" -ForegroundColor Red
        Write-Host "    Try: az boards query --wiql 'Select [System.Id] From WorkItems Where [System.AssignedTo] = @Me'"
        return New-AzDevOpsStepResult -Ok $false -FailMessage 'smoke query failed'
    }
    Write-Host "  OK  Smoke test passed ($count items assigned to you)" -ForegroundColor Green
    return New-AzDevOpsStepResult -Ok $true
}


# ---------------------------------------------------------------------------
# az-Connect-AzDevOps — thin orchestrator that runs each step in order and
# bails on the first failure with a clear NOT READY verdict.
# ---------------------------------------------------------------------------

function az-Connect-AzDevOps {

    Write-Host ""
    Write-Host "az-Connect-AzDevOps" -ForegroundColor Cyan
    Write-Host "================" -ForegroundColor Cyan

    # $steps is a closed internal array of step descriptors. Each Action is a
    # hardcoded scriptblock invoking a known function; nothing here accepts
    # untrusted input, so & $step.Action below has no injection surface.
    $steps = @(
        @{ Num = 1; Name = 'Azure CLI'; Action = { az-Confirm-AzDevOpsCli } },
        @{ Num = 2; Name = 'azure-devops extension'; Action = { az-Confirm-AzDevOpsExtension } },
        @{ Num = 3; Name = 'Optional profile env vars (AZ_USER_EMAIL, AZ_AREA)'; Action = { az-Confirm-AzDevOpsEnvVars } },
        @{ Num = 4; Name = 'Project map (multi-project)'; Action = { az-Confirm-AzDevOpsProjectMap } },
        @{ Num = 5; Name = 'Azure login session'; Action = { az-Confirm-AzDevOpsLogin } },
        @{ Num = 6; Name = 'Configure az devops defaults'; Action = { az-Set-AzDevOpsDefaults } },
        @{ Num = 7; Name = 'User-machine query files'; Action = { az-Confirm-AzDevOpsQueryFiles } },
        @{ Num = 8; Name = 'Smoke test (az boards query)'; Action = { az-Confirm-AzDevOpsSmokeQuery } }
    )

    foreach ($step in $steps) {
        Write-Host ""
        Write-Host "Step $($step.Num) of $($steps.Count) - $($step.Name)" -ForegroundColor White
        $result = & $step.Action
        if (-not $result.Ok) {
            Write-Host ""
            Write-Host "NOT READY - blocked at step $($step.Num): $($result.FailMessage)" -ForegroundColor Red
            return
        }
    }

    Write-Host ""
    $defaults = Get-AzDevOpsConfiguredDefaults
    Write-Host "READY - Azure DevOps connection verified (org=$($defaults.Org) project=$($defaults.Project))" -ForegroundColor Green
}


# ---------------------------------------------------------------------------
# Single hidden parent folder under $HOME that contains every AzDevOps state
# subdirectory (cache/, config/, schema/). Consolidates what used to be three
# separate top-level dotfolders (.bashcuts-cache, .bashcuts-config, .bashcuts)
# into one easy-to-find location.
# ---------------------------------------------------------------------------

function Get-AzDevOpsAppRoot {
    $root = Join-Path $HOME '.bashcuts-az-devops-app'
    return $root
}


# ---------------------------------------------------------------------------
# Local cache + scheduled refresh
#
# Cache directory: $HOME/.bashcuts-az-devops-app/cache/
#   assigned.json   - items where [System.AssignedTo] = @Me
#   mentions.json   - items where the user's email (or '@') appears in
#                     [System.History] (best-effort - WIQL has no first-class
#                     "@-mention" predicate)
#   hierarchy.json  - WorkItemLinks tree of Epic/Feature/User Story rows
#                     in the configured project (parent->child Hierarchy-Forward)
#   last-sync.json  - { Timestamp (round-trip), Counts: {dataset: rows} }
#   sync.log        - append-only, rotated to sync.log.1 at ~1 MB
#
# Public functions:
#   az-Sync-AzDevOpsCache              - one-shot refresh of all three datasets
#   az-Get-AzDevOpsCacheStatus         - prints freshness vs 6h threshold
#   az-Register-AzDevOpsSyncSchedule   - Task Scheduler (Windows) or crontab
#                                      (macOS/Linux) entry, every 5 hours
#   az-Unregister-AzDevOpsSyncSchedule - removes the schedule on either OS
# ---------------------------------------------------------------------------

function Get-AzDevOpsCachePaths {
    # Cache directory is segmented by active project slug when one is set, so
    # az-Use-AzDevOpsProject can flip boards without contaminating cached
    # hierarchy / assigned / mentions data across projects. Falls back to the
    # legacy unsegmented layout when no project map is active, which keeps
    # single-project users unaffected (no migration needed for them).
    $rootDir = Join-Path (Get-AzDevOpsAppRoot) 'cache'
    $cacheDir = $rootDir

    if (Get-Command Get-AzDevOpsActiveProjectSlug -ErrorAction SilentlyContinue) {
        $slug = Get-AzDevOpsActiveProjectSlug
        if ($slug) {
            $cacheDir = Join-Path $rootDir $slug
        }
    }

    return [PSCustomObject]@{
        Dir        = $cacheDir
        Assigned   = Join-Path $cacheDir 'assigned.json'
        Mentions   = Join-Path $cacheDir 'mentions.json'
        Hierarchy  = Join-Path $cacheDir 'hierarchy.json'
        Iterations = Join-Path $cacheDir 'iterations.json'
        Areas      = Join-Path $cacheDir 'areas.json'
        LastSync   = Join-Path $cacheDir 'last-sync.json'
        Log        = Join-Path $cacheDir 'sync.log'
    }
}


function New-AzDevOpsDirectoryIfMissing {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}


function Initialize-AzDevOpsCacheDir {
    $paths = Get-AzDevOpsCachePaths
    New-AzDevOpsDirectoryIfMissing -Path $paths.Dir
    return $paths
}


# ---------------------------------------------------------------------------
# User-machine config (queries)
#
# Config directory: $HOME/.bashcuts-az-devops-app/config/queries/
#   epics.wiql         - WIQL for the Epic tier of the hierarchy. Filtered by
#                        [System.AreaPath] UNDER '{{AZ_AREA}}' and category
#                        group 'Microsoft.EpicCategory'.
#   features.wiql      - WIQL for the Feature tier. Same area filter, category
#                        group 'Microsoft.FeatureCategory'.
#   user-stories.wiql  - WIQL for the User Story tier. Same area filter,
#                        category group 'Microsoft.RequirementCategory'
#                        (covers User Story / Product Backlog Item /
#                        Requirement / Issue across process templates).
#
# The three files together drive the 'hierarchy' dataset in
# Get-AzDevOpsSyncDatasets: az-Sync-AzDevOpsCache fires one WIQL per tier and
# merges the results into hierarchy.json. Splitting per-tier dodges the
# combined-IN-GROUP query's partial-result behavior under large projects and
# lets users tune each tier's filter independently.
#
# Placeholder tokens (substituted at read time by Get-AzDevOpsWiql):
#   {{AZ_AREA}}  - $env:AZ_AREA. Keeps the files portable across machines /
#                  projects without forcing users to hard-code their own area.
# ---------------------------------------------------------------------------

$script:AzDevOpsAreaToken      = '{{AZ_AREA}}'
$script:AzDevOpsUserEmailToken = '{{AZ_USER_EMAIL}}'

$script:AzDevOpsDefaultEpicsWiql = @"
Select [System.Id], [System.Title], [System.WorkItemType], [System.State], [System.IterationPath], [System.AreaPath], [System.Parent] From WorkItems Where [System.AreaPath] UNDER '{{AZ_AREA}}' AND [System.WorkItemType] IN GROUP 'Microsoft.EpicCategory'
"@

$script:AzDevOpsDefaultFeaturesWiql = @"
Select [System.Id], [System.Title], [System.WorkItemType], [System.State], [System.IterationPath], [System.AreaPath], [System.Parent] From WorkItems Where [System.AreaPath] UNDER '{{AZ_AREA}}' AND [System.WorkItemType] IN GROUP 'Microsoft.FeatureCategory'
"@

$script:AzDevOpsDefaultUserStoriesWiql = @"
Select [System.Id], [System.Title], [System.WorkItemType], [System.State], [System.IterationPath], [System.AreaPath], [System.Parent] From WorkItems Where [System.AreaPath] UNDER '{{AZ_AREA}}' AND [System.WorkItemType] IN GROUP 'Microsoft.RequirementCategory'
"@

$script:AzDevOpsDefaultAssignedWiql = @"
Select [System.Id], [System.Title], [System.WorkItemType], [System.State], [System.IterationPath], [System.ChangedDate], [Microsoft.VSTS.Common.Priority] From WorkItems Where [System.AssignedTo] = @Me
"@

$script:AzDevOpsDefaultMentionsWiql = @"
Select [System.Id], [System.Title], [System.WorkItemType], [System.State], [System.ChangedBy], [System.AreaPath], [System.ChangedDate] From WorkItems Where [System.History] Contains '{{AZ_USER_EMAIL}}'
"@


function Get-AzDevOpsConfigPaths {
    $configDir  = Join-Path (Get-AzDevOpsAppRoot) 'config'
    $queriesDir = Join-Path $configDir 'queries'

    return [PSCustomObject]@{
        Dir              = $configDir
        QueriesDir       = $queriesDir
        EpicsQuery       = Join-Path $queriesDir 'epics.wiql'
        FeaturesQuery    = Join-Path $queriesDir 'features.wiql'
        UserStoriesQuery = Join-Path $queriesDir 'user-stories.wiql'
        AssignedQuery    = Join-Path $queriesDir 'assigned.wiql'
        MentionsQuery    = Join-Path $queriesDir 'mentions.wiql'
    }
}


function Get-AzDevOpsQueryDefaults {
    # Single source of truth for all WIQL files: their logical name (also the
    # -Name parameter for Get-AzDevOpsWiql), their on-disk path, and the
    # default WIQL seeded on first run. Initialize, read, sync, and the
    # user-facing open shortcut all iterate this list, so adding a new query
    # later is a one-place edit.
    $paths = Get-AzDevOpsConfigPaths

    $defaults = @(
        [PSCustomObject]@{
            Name    = 'epics'
            Path    = $paths.EpicsQuery
            Default = $script:AzDevOpsDefaultEpicsWiql
        },
        [PSCustomObject]@{
            Name    = 'features'
            Path    = $paths.FeaturesQuery
            Default = $script:AzDevOpsDefaultFeaturesWiql
        },
        [PSCustomObject]@{
            Name    = 'user-stories'
            Path    = $paths.UserStoriesQuery
            Default = $script:AzDevOpsDefaultUserStoriesWiql
        },
        [PSCustomObject]@{
            Name    = 'assigned'
            Path    = $paths.AssignedQuery
            Default = $script:AzDevOpsDefaultAssignedWiql
        },
        [PSCustomObject]@{
            Name    = 'mentions'
            Path    = $paths.MentionsQuery
            Default = $script:AzDevOpsDefaultMentionsWiql
        }
    )

    return $defaults
}


function Initialize-AzDevOpsQueryFiles {
    # Idempotent: creates the queries directory if absent and seeds each
    # default .wiql file only when the file does not already exist. Returns
    # the resolved paths plus per-file Seeded flags so callers (the
    # az-Connect-AzDevOps step and az-Open-AzDevOpsHierarchyWiqls) can print
    # consistent status lines.
    $paths = Get-AzDevOpsConfigPaths
    New-AzDevOpsDirectoryIfMissing -Path $paths.QueriesDir

    $defaults = Get-AzDevOpsQueryDefaults
    $seeded = New-Object System.Collections.Generic.List[PSCustomObject]

    foreach ($entry in $defaults) {
        $wasSeeded = $false
        if (-not (Test-Path -LiteralPath $entry.Path)) {
            Set-Content -LiteralPath $entry.Path -Value $entry.Default -Encoding UTF8
            $wasSeeded = $true
        }

        $seeded.Add([PSCustomObject]@{
            Name   = $entry.Name
            Path   = $entry.Path
            Seeded = $wasSeeded
        })
    }

    return [PSCustomObject]@{
        Paths  = $paths
        Seeded = @($seeded)
    }
}


function Get-AzDevOpsHierarchyQueryNames {
    $hierarchyNames = @('epics', 'features', 'user-stories')
    return $hierarchyNames
}


function Get-AzDevOpsWiql {
    # Reads a named WIQL file from the user-machine config dir, substituting
    # known placeholder tokens. Defensively seeds defaults so callers don't
    # need to remember to call Initialize-AzDevOpsQueryFiles first.
    #
    # Tokens substituted at read time:
    #   {{AZ_AREA}}       - $env:AZ_AREA (throws if missing for area-filtered queries)
    #   {{AZ_USER_EMAIL}} - "@$env:AZ_USER_EMAIL" when set, otherwise "@" fallback
    param(
        [Parameter(Mandatory)]
        [ValidateSet('epics', 'features', 'user-stories', 'assigned', 'mentions')]
        [string] $Name
    )

    $init  = Initialize-AzDevOpsQueryFiles
    $entry = $init.Seeded | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    $path  = $entry.Path

    $rawContent = Get-Content -LiteralPath $path -Raw
    $wiql       = $rawContent.Trim()

    if ($wiql -match [regex]::Escape($script:AzDevOpsAreaToken)) {
        if ([string]::IsNullOrWhiteSpace($env:AZ_AREA)) {
            throw "Get-AzDevOpsWiql: `$env:AZ_AREA must be set to substitute $script:AzDevOpsAreaToken in $path."
        }

        # Escape single quotes — area paths with apostrophes would otherwise
        # break out of the [System.AreaPath] UNDER '...' WIQL literal.
        $areaEscaped = $env:AZ_AREA.Replace("'", "''")
        $wiql        = $wiql.Replace($script:AzDevOpsAreaToken, $areaEscaped)
    }

    if ($wiql -match [regex]::Escape($script:AzDevOpsUserEmailToken)) {
        $emailRaw   = if ($env:AZ_USER_EMAIL) {
            "@$env:AZ_USER_EMAIL"
        } else {
            '@'
        }
        # Escape single quotes for WIQL string-literal safety — same rationale
        # as $areaEscaped above.
        $emailValue = $emailRaw.Replace("'", "''")
        $wiql       = $wiql.Replace($script:AzDevOpsUserEmailToken, $emailValue)
    }

    return $wiql
}


function Invoke-AzDevOpsHierarchyQueries {
    # Runs the three per-tier hierarchy WIQLs (epics, features, user-stories)
    # sequentially, each filtered by [System.AreaPath] UNDER '{{AZ_AREA}}',
    # and returns the merged work-item array in the same { Json, Error,
    # ExitCode } envelope that Invoke-AzDevOpsBoardsQuery emits. Splitting the
    # prior single-query hierarchy into three category-scoped calls dodges the
    # combined IN-GROUP query's partial-result behavior under larger projects
    # and lets each tier's filter be tuned independently.
    #
    # On the first failing tier we short-circuit and return the underlying
    # exit code + stderr (prefixed with the tier name) so Invoke-AzDevOpsAzDataset
    # treats the dataset as failed and skips the cache write.

    $names = Get-AzDevOpsHierarchyQueryNames
    $merged = New-Object System.Collections.Generic.List[object]

    foreach ($name in $names) {
        $wiql = Get-AzDevOpsWiql -Name $name
        $result = Invoke-AzDevOpsBoardsQuery -Wiql $wiql

        if ($result.ExitCode -ne 0) {
            $errEnvelope = [PSCustomObject]@{
                Json     = ''
                Error    = "[$name] $($result.Error)"
                ExitCode = $result.ExitCode
            }
            return $errEnvelope
        }

        try {
            $parsed = $result.Json | ConvertFrom-Json
        }
        catch {
            $parseErrEnvelope = [PSCustomObject]@{
                Json     = ''
                Error    = "[$name] parse failed: $($_.Exception.Message)"
                ExitCode = 1
            }
            return $parseErrEnvelope
        }

        foreach ($item in @($parsed)) {
            if ($null -ne $item) {
                $merged.Add($item)
            }
        }
    }

    # Invoke-AzDevOpsAzDataset re-parses + re-serializes Json before writing
    # the cache, and it applies its own -AsArray when the descriptor sets
    # AsArray=$true (the hierarchy descriptor does). The -Depth 10 here is
    # only for the in-flight envelope passed back to that helper; downstream
    # depth is governed by the descriptor's JsonDepth.
    $mergedJson = ConvertTo-Json -InputObject @($merged) -Depth 10 -AsArray

    $envelope = [PSCustomObject]@{
        Json     = $mergedJson
        Error    = ''
        ExitCode = 0
    }
    return $envelope
}


function Write-AzDevOpsCacheFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Content
    )
    $tmp = "$Path.tmp"
    Set-Content -LiteralPath $tmp -Value $Content -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}


function Write-AzDevOpsSyncLog {
    param([Parameter(Mandatory)] [string] $Message)
    $paths = Get-AzDevOpsCachePaths
    if (-not (Test-Path -LiteralPath $paths.Dir)) { return }

    if (Test-Path -LiteralPath $paths.Log) {
        $size = (Get-Item -LiteralPath $paths.Log).Length
        if ($size -gt 1MB) {
            Move-Item -LiteralPath $paths.Log -Destination "$($paths.Log).1" -Force
        }
    }
    $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    Add-Content -LiteralPath $paths.Log -Value "$stamp $Message"
}


# ---------------------------------------------------------------------------
# Sync helpers — extracted so az-Sync-AzDevOpsCache stays a small orchestrator
# and the duplicated "first stderr line" / "build error status" / "log raw
# stderr" patterns live in one place each (per CLAUDE.md DRY rule).
# ---------------------------------------------------------------------------

function Get-AzDevOpsFirstStderrLine {
    param([string] $Stderr)
    if (-not $Stderr) { return '' }
    $line = $Stderr -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1
    if ($line) { return $line } else { return '' }
}


function New-AzDevOpsDatasetStatus {
    param(
        [Parameter(Mandatory)] [ValidateSet('ok', 'error')] [string] $Status,
        [int]    $Rows,
        [string] $Message,
        [string] $Elapsed,
        [int]    $MaxErrorChars = 500
    )

    if ($Status -eq 'ok') {
        return [PSCustomObject]@{
            Status  = 'ok'
            Rows    = $Rows
            Elapsed = $Elapsed
        }
    }

    $msg = if ($Message) { $Message.TrimEnd() } else { '' }
    if ($msg.Length -gt $MaxErrorChars) { $msg = $msg.Substring(0, $MaxErrorChars) }

    return [PSCustomObject]@{
        Status  = 'error'
        Error   = $msg
        Elapsed = $Elapsed
    }
}


function Write-AzDevOpsSyncStderr {
    param(
        [Parameter(Mandatory)] [string] $DatasetName,
        [Parameter(Mandatory)] [int]    $ExitCode,
        [Parameter(Mandatory)] [string] $Elapsed,
        [string] $Stderr
    )

    Write-AzDevOpsSyncLog "ERROR $DatasetName query failed (exit=$ExitCode, elapsed=$Elapsed)"
    if (-not $Stderr) { return }

    foreach ($line in ($Stderr -split "`r?`n")) {
        if ($line.Trim()) {
            Write-AzDevOpsSyncLog "  [$DatasetName] $line"
        }
    }
}


function Get-AzDevOpsSyncDatasets {
    param([Parameter(Mandatory)] [PSCustomObject] $Paths)

    # Assigned and mentions WIQLs are read from user-editable files under
    # ~/.bashcuts-az-devops-app/config/queries/ (assigned.wiql / mentions.wiql).
    # Hierarchy is built from three per-tier WIQL files (epics.wiql /
    # features.wiql / user-stories.wiql). Invoke-AzDevOpsHierarchyQueries runs
    # each WIQL sequentially and merges results into hierarchy.json.
    $assignedWiql = Get-AzDevOpsWiql -Name 'assigned'
    $mentionsWiql = Get-AzDevOpsWiql -Name 'mentions'

    $rowCounter  = { param($parsed) @($parsed).Count }
    $treeCounter = { param($parsed) Measure-AzDevOpsClassificationNodes -Node $parsed }

    $datasets = @(
        @{
            Name     = 'assigned'
            Label    = 'System.AssignedTo = @Me'
            Path     = $Paths.Assigned
            Fetch    = { Invoke-AzDevOpsBoardsQuery -Wiql $assignedWiql }.GetNewClosure()
            Counter  = $rowCounter
            RowLabel = 'rows'
            AsArray  = $true
        },
        @{
            Name     = 'mentions'
            Label    = 'System.History Contains email (from mentions.wiql)'
            Path     = $Paths.Mentions
            Fetch    = { Invoke-AzDevOpsBoardsQuery -Wiql $mentionsWiql }.GetNewClosure()
            Counter  = $rowCounter
            RowLabel = 'rows'
            AsArray  = $true
        },
        @{
            Name     = 'hierarchy'
            Label    = 'Epic + Feature + User Story tiers (3 area-filtered WIQLs)'
            Path     = $Paths.Hierarchy
            Fetch    = { Invoke-AzDevOpsHierarchyQueries }
            Counter  = $rowCounter
            RowLabel = 'rows'
            AsArray  = $true
        },
        @{
            Name      = 'iterations'
            Label     = 'Project iterations (tree)'
            Path      = $Paths.Iterations
            Fetch     = { Get-AzDevOpsClassificationList -Kind 'Iteration' -Depth 5 }
            Counter   = $treeCounter
            RowLabel  = 'nodes'
            JsonDepth = 20
        },
        @{
            Name      = 'areas'
            Label     = 'Project areas (tree)'
            Path      = $Paths.Areas
            Fetch     = { Get-AzDevOpsClassificationList -Kind 'Area' -Depth 5 }
            Counter   = $treeCounter
            RowLabel  = 'nodes'
            JsonDepth = 20
        }
    )

    return $datasets
}


function Invoke-AzDevOpsAzDataset {
    # Single sync helper for any cache dataset that calls az and writes JSON.
    # Callers supply: a -Fetch scriptblock returning {Json,Error,ExitCode}, a
    # -Counter scriptblock that turns parsed JSON into a row count, a label
    # for the count noun (rows / nodes), and the on-disk JSON depth. Replaces
    # the previously-duplicated WIQL- and classification-specific sync paths
    # per CLAUDE.md's extract-repeated-branches rule.
    #
    # -AsArray forces the on-disk JSON to keep [{...}] shape even when the
    # parsed payload is a single object or $null. Required for the WIQL-style
    # datasets (assigned / mentions / hierarchy) whose downstream readers index
    # the JSON as an array; classification trees (iterations / areas) leave it
    # off so their root object stays an object.
    param(
        [Parameter(Mandatory)] [string]      $Name,
        [Parameter(Mandatory)] [string]      $Label,
        [Parameter(Mandatory)] [string]      $Path,
        [Parameter(Mandatory)] [scriptblock] $Fetch,
        [scriptblock] $Counter = { param($parsed) @($parsed).Count },
        [string]      $RowLabel = 'rows',
        [int]         $JsonDepth = 10,
        [switch]      $AsArray
    )

    Write-Host "-> Querying $Name ($Label)..." -ForegroundColor Cyan

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = & $Fetch
    $sw.Stop()
    $elapsed = '{0:N1}s' -f $sw.Elapsed.TotalSeconds

    if ($result.ExitCode -ne 0) {
        $firstLine = Get-AzDevOpsFirstStderrLine -Stderr $result.Error
        if (-not $firstLine) { $firstLine = "az exited with code $($result.ExitCode)" }

        Write-Host "  X $Name - $firstLine (in $elapsed)" -ForegroundColor Red
        Write-AzDevOpsSyncStderr -DatasetName $Name -ExitCode $result.ExitCode -Elapsed $elapsed -Stderr $result.Error

        $errStatus = New-AzDevOpsDatasetStatus -Status 'error' -Message $result.Error -Elapsed $elapsed
        return $errStatus
    }

    try {
        $parsed = $result.Json | ConvertFrom-Json
    }
    catch {
        $msg = $_.Exception.Message
        Write-Host "  X $Name - parse failed: $msg (in $elapsed)" -ForegroundColor Red
        Write-AzDevOpsSyncLog "ERROR $Name parse failed (elapsed=$elapsed): $msg"
        $parseErrStatus = New-AzDevOpsDatasetStatus -Status 'error' -Message "parse failed: $msg" -Elapsed $elapsed
        return $parseErrStatus
    }

    $count = & $Counter $parsed

    $pretty = if ($AsArray) {
        ConvertTo-Json -InputObject @($parsed) -Depth $JsonDepth -AsArray
    } else {
        $parsed | ConvertTo-Json -Depth $JsonDepth
    }

    Write-AzDevOpsCacheFile -Path $Path -Content $pretty
    Write-Host "  OK  $Name - $count $RowLabel in $elapsed" -ForegroundColor Green
    Write-AzDevOpsSyncLog "$Name wrote $count $RowLabel in $elapsed"

    $okStatus = New-AzDevOpsDatasetStatus -Status 'ok' -Rows $count -Elapsed $elapsed
    return $okStatus
}


function Measure-AzDevOpsClassificationNodes {
    # Recursively counts nodes in an iteration / area-path tree returned by
    # `az boards iteration project list` / `az boards area project list`. Used
    # for the classification-dataset row count so the sync prints something
    # meaningful per dataset.
    param($Node)

    if ($null -eq $Node) { return 0 }

    $count = 1
    if ($Node.children) {
        foreach ($child in $Node.children) {
            $count += Measure-AzDevOpsClassificationNodes -Node $child
        }
    }
    return $count
}


function az-Sync-AzDevOpsCache {
    if (-not (Assert-AzDevOpsAuthOrAbort -CommandName 'az-Sync-AzDevOpsCache')) {
        return
    }

    $paths = Initialize-AzDevOpsCacheDir
    Write-AzDevOpsSyncLog 'sync started'

    $datasets = Get-AzDevOpsSyncDatasets -Paths $paths

    $counts = [ordered]@{}
    $statuses = [ordered]@{}
    $errored = 0

    foreach ($ds in $datasets) {
        $status = Invoke-AzDevOpsAzDataset @ds
        $statuses[$ds.Name] = $status

        if ($status.Status -eq 'ok') {
            $counts[$ds.Name] = $status.Rows
        }
        else {
            $errored++
        }
    }

    $lastSync = [PSCustomObject]@{
        Timestamp = (Get-Date).ToString('o')
        Counts    = $counts
        Datasets  = $statuses
    }
    Write-AzDevOpsCacheFile -Path $paths.LastSync -Content ($lastSync | ConvertTo-Json -Depth 5)
    Write-AzDevOpsSyncLog 'sync complete'

    Write-Host ""
    Write-Host "Cache: $($paths.Dir)" -ForegroundColor Cyan
    if ($errored -gt 0) {
        Write-Host "Partial sync - $errored of $($datasets.Count) dataset(s) failed. See $($paths.Log)" -ForegroundColor Yellow
    }
}


function Get-AzDevOpsCacheAge {
    $paths = Get-AzDevOpsCachePaths
    if (-not (Test-Path -LiteralPath $paths.LastSync)) { return $null }

    $info = Get-Content -LiteralPath $paths.LastSync -Raw | ConvertFrom-Json
    $synced = [datetime]$info.Timestamp
    $age = (Get-Date) - $synced

    $ageText = if ($age.TotalMinutes -lt 60) {
        "$([int]$age.TotalMinutes) min ago"
    }
    elseif ($age.TotalHours -lt 24) {
        "$([math]::Round($age.TotalHours, 1)) hours ago"
    }
    else {
        "$([int]$age.TotalDays) days ago"
    }

    return [PSCustomObject]@{
        Synced   = $synced
        Age      = $age
        AgeText  = $ageText
        IsStale  = ($age.TotalHours -ge 6)
        Counts   = $info.Counts
        Datasets = $info.Datasets
        LogPath  = $paths.Log
    }
}


function Get-AzDevOpsCacheStatusRows {
    # Joins $cacheAge.Counts (dataset -> row count) with $cacheAge.Datasets
    # (dataset -> {Status, Error}) into one flat row per dataset so the
    # table / grid shows everything cache-related on a single sortable surface.
    param([Parameter(Mandatory)] $CacheAge)

    $rows = New-Object System.Collections.Generic.List[PSCustomObject]

    $countsObj = $CacheAge.Counts
    $datasetsObj = $CacheAge.Datasets

    $countNames = if ($countsObj) {
        @($countsObj.PSObject.Properties.Name)
    }
    else {
        @()
    }

    $datasetNames = if ($datasetsObj) {
        @($datasetsObj.PSObject.Properties.Name)
    }
    else {
        @()
    }

    $allNames = @($countNames + $datasetNames | Select-Object -Unique | Sort-Object)

    foreach ($name in $allNames) {
        $count = if ($countsObj -and $countsObj.PSObject.Properties[$name]) {
            $countsObj.$name
        }
        else {
            $null
        }

        $datasetEntry = if ($datasetsObj -and $datasetsObj.PSObject.Properties[$name]) {
            $datasetsObj.$name
        }
        else {
            $null
        }

        $status = if ($datasetEntry -and $datasetEntry.Status) {
            $datasetEntry.Status
        }
        else {
            'ok'
        }

        $errorText = if ($datasetEntry -and $datasetEntry.Error) {
            Get-AzDevOpsFirstStderrLine -Stderr $datasetEntry.Error
        }
        else {
            ''
        }

        $row = [PSCustomObject]@{
            Dataset = $name
            Status  = $status
            Count   = $count
            Error   = $errorText
        }
        $rows.Add($row)
    }

    $result = , @($rows)
    return $result
}


function az-Get-AzDevOpsCacheStatus {
    $cacheAge = Get-AzDevOpsCacheAge
    if ($null -eq $cacheAge) {
        Write-Host "No cache yet - run az-Sync-AzDevOpsCache" -ForegroundColor Yellow
        return
    }

    if ($cacheAge.IsStale) {
        Write-Host "STALE - last synced $($cacheAge.AgeText)" -ForegroundColor Yellow
    }
    else {
        Write-Host "OK fresh - synced $($cacheAge.AgeText)" -ForegroundColor Green
    }

    $rows = Get-AzDevOpsCacheStatusRows -CacheAge $cacheAge
    if (@($rows).Count -gt 0) {
        Show-AzDevOpsRows -Rows $rows -Title "Azure DevOps cache - $($cacheAge.AgeText)"
    }

    if ($cacheAge.Datasets) {
        $errored = @($cacheAge.Datasets.PSObject.Properties | Where-Object { $_.Value.Status -eq 'error' })
        if ($errored.Count -gt 0) {
            Write-Host ""
            Write-Host "Partial sync - $($errored.Count) dataset(s) errored. See $($cacheAge.LogPath) for full az stderr." -ForegroundColor Yellow
        }
    }
}


# ---------------------------------------------------------------------------
# Scheduling helpers — shared by Register-/az-Unregister-AzDevOpsSyncSchedule
# so the platform branch and the cron-tag filter live in one place each
# (CLAUDE.md explicitly names Get-AzDevOpsPlatform / Get-AzDevOpsCronLine).
# ---------------------------------------------------------------------------

function Get-AzDevOpsPlatform {
    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
        return 'Windows'
    }

    if ($IsMacOS -or $IsLinux) {
        return 'Posix'
    }

    return 'Unknown'
}


function Get-AzDevOpsScheduledTaskName {
    return 'BashcutsAzDevOpsSync'
}


function Get-AzDevOpsSyncIntervalHours {
    return 5
}


function Get-AzDevOpsCronTag {
    return '# bashcuts-azdevops-sync'
}


function Get-AzDevOpsCronLine {
    param([Parameter(Mandatory)] [string] $PwshPath)
    $tag = Get-AzDevOpsCronTag
    $hours = Get-AzDevOpsSyncIntervalHours
    return "0 */$hours * * * $PwshPath -Command `"az-Sync-AzDevOpsCache`" $tag"
}


function Get-AzDevOpsCrontabSplit {
    # Reads the current crontab and partitions it into bashcuts-tagged lines
    # vs everything else. Returns the non-bashcuts lines plus a HadBashcuts
    # flag so Unregister doesn't have to re-grep to know whether it changed
    # anything. crontab returning no output / nonzero is normalized to empty.
    $tag = Get-AzDevOpsCronTag
    $existingRaw = crontab -l 2>$null

    if (-not $existingRaw) {
        return [PSCustomObject]@{ Other = @(); HadBashcuts = $false }
    }

    $allLines = @($existingRaw -split "`n" | Where-Object { $_ })
    $otherLines = @($allLines | Where-Object { $_ -notmatch [regex]::Escape($tag) })
    $hadBashcuts = ($otherLines.Count -lt $allLines.Count)

    return [PSCustomObject]@{ Other = $otherLines; HadBashcuts = $hadBashcuts }
}


function az-Register-AzDevOpsSyncSchedule {
    $platform = Get-AzDevOpsPlatform
    # Loads the user's $profile so $env:AZ_* and the dot-sourced module are
    # available; without -NoProfile, the scheduled invocation has the same
    # context as an interactive shell.
    $pwshPath = (Get-Process -Id $PID).Path
    $hours = Get-AzDevOpsSyncIntervalHours

    if ($platform -eq 'Windows') {
        $taskName = Get-AzDevOpsScheduledTaskName
        $action = New-ScheduledTaskAction -Execute $pwshPath -Argument "-Command `"az-Sync-AzDevOpsCache`""
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) `
            -RepetitionInterval (New-TimeSpan -Hours $hours)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Force | Out-Null
        Write-Host "Registered: scheduled task '$taskName' (every $hours hours)" -ForegroundColor Green
        return
    }

    if ($platform -eq 'Posix') {
        $cronLine = Get-AzDevOpsCronLine -PwshPath $pwshPath
        $split = Get-AzDevOpsCrontabSplit
        $newCron = (@($split.Other) + $cronLine) -join "`n"
        $newCron | crontab -
        Write-Host "Registered: cron entry - $cronLine" -ForegroundColor Green
        return
    }

    Write-Host "Unsupported OS for az-Register-AzDevOpsSyncSchedule" -ForegroundColor Red
}


function az-Unregister-AzDevOpsSyncSchedule {
    $platform = Get-AzDevOpsPlatform

    if ($platform -eq 'Windows') {
        $taskName = Get-AzDevOpsScheduledTaskName
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Host "Unregistered: scheduled task '$taskName'" -ForegroundColor Green
        }
        else {
            Write-Host "No scheduled task '$taskName' to remove" -ForegroundColor Yellow
        }
        return
    }

    if ($platform -eq 'Posix') {
        $split = Get-AzDevOpsCrontabSplit
        if (-not $split.HadBashcuts) {
            Write-Host "No bashcuts-azdevops-sync cron entry to remove" -ForegroundColor Yellow
            return
        }
        ($split.Other -join "`n") | crontab -
        Write-Host "Unregistered: removed bashcuts-azdevops-sync cron entry" -ForegroundColor Green
        return
    }

    Write-Host "Unsupported OS for az-Unregister-AzDevOpsSyncSchedule" -ForegroundColor Red
}


# ---------------------------------------------------------------------------
# Grid presentation helpers
#
# Out-ConsoleGridView gives the user a sortable, filterable, click-to-select
# TUI in the terminal for every list and every picker. It ships in
# Microsoft.PowerShell.ConsoleGuiTools and is cross-platform (Windows /
# macOS / Linux), unlike the WPF-based Out-GridView which is Windows-only.
# These helpers centralize the capability check + the call site so each
# public function calls one line instead of repeating the if/else
# (CLAUDE.md "extract repeated branches" rule).
#
#   Test-AzDevOpsGridAvailable - $true if Out-ConsoleGridView resolves
#   Show-AzDevOpsRows          - render rows as grid (display-only or PassThru),
#                              fall back to Format-Table when grid unavailable
#   Read-AzDevOpsGridPick      - single-select grid picker; returns $null when
#                              grid unavailable so the caller can run its
#                              Read-Host numbered menu
# ---------------------------------------------------------------------------

function Test-AzDevOpsGridAvailable {
    $available = Test-ConsoleGridAvailable
    return $available
}


function Show-AzDevOpsRows {
    param(
        $Rows,
        [Parameter(Mandatory)] [string] $Title,
        [switch] $PassThru
    )

    if ($null -eq $Rows) {
        return
    }

    if (Test-AzDevOpsGridAvailable) {
        if ($PassThru) {
            $selected = $Rows | Out-ConsoleGridView -Title $Title
            return $selected
        }

        $Rows | Out-ConsoleGridView -Title $Title -OutputMode None
        return
    }

    if ($PassThru) {
        return $Rows
    }

    $Rows | Format-Table -AutoSize | Out-Host
}


function Read-AzDevOpsGridPick {
    param(
        $Rows,
        [Parameter(Mandatory)] [string] $Title
    )

    if ($null -eq $Rows -or @($Rows).Count -eq 0) {
        return $null
    }

    if (-not (Test-AzDevOpsGridAvailable)) {
        return $null
    }

    $picked = $Rows | Out-ConsoleGridView -Title $Title -OutputMode Single
    return $picked
}


# ---------------------------------------------------------------------------
# Cache consumers - read-only commands that surface cached work items
#
# Public functions:
#   az-Get-AzDevOpsAssigned   - table of work items assigned to me
#   az-Open-AzDevOpsAssigned  - open a single assigned item in the browser
#   az-Get-AzDevOpsMentions   - table of work items where I've been @-mentioned
#   az-Open-AzDevOpsMention   - open a single mentioned item in the browser
#
# All four read $HOME/.bashcuts-az-devops-app/cache/{assigned,mentions}.json
# (built by az-Sync-AzDevOpsCache). They never call `az` directly - if the cache
# is missing, they print a hint and bail.
#
# Default order for the two Get- listings: most recently changed first
# (AssignedAt / MentionedAt descending). Click the column header in
# Out-ConsoleGridView to re-sort by Id, State, etc.
# ---------------------------------------------------------------------------

function ConvertFrom-AzDevOpsAssignedItem {
    param([Parameter(Mandatory)] $Raw)

    $f = $Raw.fields

    $id = if ($f.'System.Id') {
        [int]$f.'System.Id'
    } else {
        [int]$Raw.id
    }

    $assignedAt = if ($f.'System.ChangedDate') {
        [datetime]$f.'System.ChangedDate'
    } else {
        $null
    }

    $priority = if ($null -ne $f.'Microsoft.VSTS.Common.Priority') {
        [int]$f.'Microsoft.VSTS.Common.Priority'
    } else {
        $null
    }

    return [PSCustomObject]@{
        Id         = $id
        Type       = $f.'System.WorkItemType'
        State      = $f.'System.State'
        Title      = $f.'System.Title'
        Iteration  = $f.'System.IterationPath'
        Priority   = $priority
        AssignedAt = $assignedAt
    }
}


function Read-AzDevOpsJsonCache {
    # Shared shape for every cache reader: missing-cache hint, ConvertFrom-Json
    # with try/catch, then map each row through a per-dataset converter. Each
    # caller supplies its own $Path, a short $Description for the hint line,
    # and a scriptblock that turns one parsed row into a typed PSCustomObject.
    param(
        [Parameter(Mandatory)] [string]      $Path,
        [Parameter(Mandatory)] [string]      $Description,
        [Parameter(Mandatory)] [scriptblock] $Converter
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "No $Description cache at $Path." -ForegroundColor Yellow
        Write-Host "  Run: az-Sync-AzDevOpsCache              # one-shot refresh" -ForegroundColor Yellow
        Write-Host "  Run: az-Register-AzDevOpsSyncSchedule   # recurring refresh (~5h)" -ForegroundColor Yellow
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        Write-Host "Could not parse ${Path}: $_" -ForegroundColor Red
        return $null
    }

    $items = @($raw | ForEach-Object { & $Converter $_ })
    return $items
}


# ---------------------------------------------------------------------------
# Shared scaffolding for the Get-/Open-AzDevOps{Assigned,Mentions} pairs
#
# These private helpers exist because the same blocks were duplicated across
# the parallel pairs (CLAUDE.md "extract repeated branches" rule):
#   - stale-cache banner          - Write-AzDevOpsStaleBanner
#   - default open-ish state filter + explicit -State filter
#                                  - Select-AzDevOpsActiveItems
#   - Title truncation projection - Format-AzDevOpsTruncatedTitle
#   - id lookup w/ standard miss-hint + LASTEXITCODE=1
#                                  - Find-AzDevOpsCachedWorkItem
#   - env-var guard + URL build + Start-Process
#                                  - Open-AzDevOpsWorkItemUrl
#   - newest-first sort with $null dates pushed to the bottom
#                                  - Sort-AzDevOpsByDateDesc
# ---------------------------------------------------------------------------

function Get-AzDevOpsClosedStates {
    return @('Closed', 'Removed')
}


function Write-AzDevOpsStaleBanner {
    $cacheAge = Get-AzDevOpsCacheAge
    if ($cacheAge -and $cacheAge.IsStale) {
        Write-Host "WARNING stale (last sync: $($cacheAge.AgeText))" -ForegroundColor Yellow
    }
}


function Select-AzDevOpsActiveItems {
    param(
        [Parameter(Mandatory)] $Items,
        [string[]] $State
    )

    $closedStates = Get-AzDevOpsClosedStates

    $filtered = if ($State) {
        $Items | Where-Object { $_.State -in $State }
    }
    else {
        $Items | Where-Object { $_.State -notin $closedStates }
    }

    return $filtered
}


function Sort-AzDevOpsByDateDesc {
    # Newest first. Sort-Object -Descending on a date alone would surface
    # rows whose date is $null at the *top* of the list, because PowerShell
    # sorts $null below every value. Two-key sort: the first key pushes
    # null-date rows to the bottom; the second orders the non-nulls
    # newest-first. Used by the Get-AzDevOpsAssigned / Get-AzDevOpsMentions
    # listings so each one is a one-line call.
    param(
        [Parameter(Mandatory)] $Items,
        [Parameter(Mandatory)] [string] $Field
    )

    $sorted = $Items | Sort-Object `
    @{ Expression = { $null -ne $_.$Field }; Descending = $true }, `
    @{ Expression = $Field; Descending = $true }

    return @($sorted)
}


function Format-AzDevOpsTruncatedTitle {
    param([string] $Title)

    $titleMaxLen = 80
    $ellipsis = '...'

    if ($Title -and $Title.Length -gt $titleMaxLen) {
        $truncated = $Title.Substring(0, $titleMaxLen - $ellipsis.Length) + $ellipsis
        return $truncated
    }

    return $Title
}


function Get-AzDevOpsTitleColumn {
    # Returns a Select-Object calculated-property hashtable that renders the
    # Title column with the standard 80-char ellipsis truncation. Used by
    # az-Get-AzDevOpsAssigned and az-Get-AzDevOpsMentions so the projection lives
    # in one place.
    return @{
        Name       = 'Title'
        Expression = { Format-AzDevOpsTruncatedTitle -Title $_.Title }
    }
}


function Find-AzDevOpsCachedWorkItem {
    # Looks up $Id in $Items. On hit, returns the matched row. On miss,
    # prints the standard "not in your <description> cache" hint, optionally
    # echoes a directly-pasteable URL fallback, sets $LASTEXITCODE = 1, and
    # returns $null. Callers check for $null and return.
    param(
        [Parameter(Mandatory)] $Items,
        [Parameter(Mandatory)] [int]    $Id,
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [string] $ListCommand,
        [switch] $IncludeUrlFallback
    )

    $match = $Items | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if ($match) {
        return $match
    }

    Write-Host "Work item $Id is not in your $Description cache." -ForegroundColor Red
    Write-Host "  Tip: run $ListCommand to list valid IDs, or az-Sync-AzDevOpsCache to refresh." -ForegroundColor Yellow

    if ($IncludeUrlFallback) {
        $fallbackUrl = Get-AzDevOpsWorkItemUrl -Id $Id
        if ($fallbackUrl) {
            Write-Host "  Or open it directly: $fallbackUrl" -ForegroundColor Yellow
        }
    }

    $global:LASTEXITCODE = 1
    return $null
}


function Get-AzDevOpsWorkItemUrlPrefix {
    # Quiet URL-prefix builder. Returns "$org/$projectEnc/_workitems/edit/" when
    # az devops defaults are configured; returns '' when either is missing.
    # Designed for callers that build URLs for many ids in a loop (e.g.
    # Out-ConsoleGridView row projections in Get-AzDevOpsTreeRows) so the prefix
    # is computed once instead of per row, and so per-row use does not pollute
    # $LASTEXITCODE.
    $defaults = Get-AzDevOpsConfiguredDefaults
    if (-not $defaults.Org -or -not $defaults.Project) {
        return ''
    }

    $org        = $defaults.Org.TrimEnd('/')
    $projectEnc = [uri]::EscapeDataString($defaults.Project)
    $prefix     = "$org/$projectEnc/_workitems/edit/"
    return $prefix
}


function Get-AzDevOpsWorkItemUrl {
    # Single-shot URL builder. Returns the full work-item edit URL when env
    # vars are set; returns $null when they aren't. Caller decides whether
    # missing env vars warrants $LASTEXITCODE / Write-Host - this helper stays
    # quiet so callers like Find-AzDevOpsCachedWorkItem URL-fallback can branch
    # on $null without spamming side effects.
    param([Parameter(Mandatory)] [int] $Id)

    $prefix = Get-AzDevOpsWorkItemUrlPrefix
    if (-not $prefix) {
        return $null
    }

    $url = "$prefix$Id"
    return $url
}


function Open-AzDevOpsWorkItemUrl {
    # env-var guard + URL build + Start-Process. Sets $LASTEXITCODE = 1 and
    # returns when env-vars are missing; otherwise launches the OS browser.
    param([Parameter(Mandatory)] [int] $Id)

    $url = Get-AzDevOpsWorkItemUrl -Id $Id
    if ($null -eq $url) {
        Write-Host "az devops defaults not configured. Run: az devops configure --defaults organization=<url> project=<name>" -ForegroundColor Red
        $global:LASTEXITCODE = 1
        return
    }

    Write-Host "Opening $url" -ForegroundColor Cyan
    Start-Process $url
}


function Read-AzDevOpsAssignedCache {
    $paths = Get-AzDevOpsCachePaths
    $items = Read-AzDevOpsJsonCache `
        -Path        $paths.Assigned `
        -Description 'assigned-items' `
        -Converter { param($r) ConvertFrom-AzDevOpsAssignedItem -Raw $r }
    return $items
}


function az-Get-AzDevOpsAssigned {
    [CmdletBinding()]
    param(
        [string[]] $State
    )

    $items = Read-AzDevOpsAssignedCache
    if ($null -eq $items) { return }

    Write-AzDevOpsStaleBanner

    $filtered = Select-AzDevOpsActiveItems -Items $items -State $State
    $sorted = Sort-AzDevOpsByDateDesc -Items $filtered -Field 'AssignedAt'

    $rows = @($sorted | Select-Object Id, Type, State, (Get-AzDevOpsTitleColumn), Iteration, AssignedAt)
    $title = "Assigned to me - $($rows.Count) items"

    $selected = Show-AzDevOpsRows -Rows $rows -Title $title -PassThru
    return $selected
}


function az-Open-AzDevOpsAssigned {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [int] $Id
    )

    $items = Read-AzDevOpsAssignedCache
    if ($null -eq $items) { return }

    $match = Find-AzDevOpsCachedWorkItem `
        -Items       $items `
        -Id          $Id `
        -Description 'assigned-items' `
        -ListCommand 'az-Get-AzDevOpsAssigned' `
        -IncludeUrlFallback
    if (-not $match) { return }

    Open-AzDevOpsWorkItemUrl -Id $Id
}


function Get-AzDevOpsMentionedByDisplayName {
    # System.ChangedBy lands as either a complex identity object (displayName /
    # uniqueName), a "Name <email>" string, or $null depending on the az CLI
    # version + how it serialized the WIQL row. Normalize all three to a single
    # string the table column can render.
    param($ChangedBy)

    if ($null -eq $ChangedBy) {
        return $null
    }

    if ($ChangedBy -is [string]) {
        return $ChangedBy
    }

    if ($ChangedBy.displayName) {
        return $ChangedBy.displayName
    }

    if ($ChangedBy.uniqueName) {
        return $ChangedBy.uniqueName
    }

    return "$ChangedBy"
}


function ConvertFrom-AzDevOpsMentionItem {
    param([Parameter(Mandatory)] $Raw)

    $f = $Raw.fields

    $id = if ($f.'System.Id') {
        [int]$f.'System.Id'
    }
    else {
        [int]$Raw.id
    }

    $mentionedAt = if ($f.'System.ChangedDate') {
        [datetime]$f.'System.ChangedDate'
    }
    else {
        $null
    }

    $mentionedBy = Get-AzDevOpsMentionedByDisplayName -ChangedBy $f.'System.ChangedBy'

    return [PSCustomObject]@{
        Id          = $id
        Type        = $f.'System.WorkItemType'
        State       = $f.'System.State'
        Title       = $f.'System.Title'
        MentionedBy = $mentionedBy
        MentionedAt = $mentionedAt
    }
}


function Read-AzDevOpsMentionsCache {
    $paths = Get-AzDevOpsCachePaths
    $items = Read-AzDevOpsJsonCache `
        -Path        $paths.Mentions `
        -Description 'mentions' `
        -Converter { param($r) ConvertFrom-AzDevOpsMentionItem -Raw $r }
    return $items
}


function az-Get-AzDevOpsMentions {
    [CmdletBinding()]
    param(
        [string[]] $State,
        [datetime] $Since,
        [switch]   $IncludeAssigned
    )

    $items = Read-AzDevOpsMentionsCache
    if ($null -eq $items) { return }

    Write-AzDevOpsStaleBanner

    if (-not $IncludeAssigned) {
        $assigned = Read-AzDevOpsAssignedCache

        $assignedIds = if ($assigned) {
            @($assigned | ForEach-Object { $_.Id })
        }
        else {
            @()
        }

        if ($assignedIds.Count -gt 0) {
            $items = $items | Where-Object { $_.Id -notin $assignedIds }
        }
    }

    $filtered = Select-AzDevOpsActiveItems -Items $items -State $State

    if ($Since) {
        $filtered = $filtered | Where-Object {
            $_.MentionedAt -and $_.MentionedAt -ge $Since
        }
    }

    $sorted = Sort-AzDevOpsByDateDesc -Items $filtered -Field 'MentionedAt'

    $rows = @($sorted | Select-Object Id, Type, State, (Get-AzDevOpsTitleColumn), MentionedBy, MentionedAt)
    $title = "Mentions - $($rows.Count) items"

    $selected = Show-AzDevOpsRows -Rows $rows -Title $title -PassThru
    return $selected
}


function az-Open-AzDevOpsMention {
    # Plain /_workitems/edit/<id> URL only - Azure DevOps' #comment-NNNN
    # anchor is an ephemeral comment id that isn't stable across syncs, so
    # there's no reliable way to deep-link into the discussion thread; the
    # discussion tab is one click away once the work item is open.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [int] $Id
    )

    $items = Read-AzDevOpsMentionsCache
    if ($null -eq $items) { return }

    $match = Find-AzDevOpsCachedWorkItem `
        -Items       $items `
        -Id          $Id `
        -Description 'mentions' `
        -ListCommand 'az-Get-AzDevOpsMentions' `
        -IncludeUrlFallback
    if (-not $match) { return }

    Open-AzDevOpsWorkItemUrl -Id $Id
}


# ---------------------------------------------------------------------------
# Hierarchy tree view
#
# Public functions:
#   az-Show-AzDevOpsTree   - prints the project's Epic/Feature/requirement-tier
#                          tree from the cached hierarchy.json (no `az` calls)
#   az-Show-AzDevOpsBoard  - cached items grouped by State (board-style view);
#                          relies on Out-ConsoleGridView's column group-by.
#                          Defined further down in its own section.
#
# Reads $HOME/.bashcuts-az-devops-app/cache/hierarchy.json (built by
# az-Sync-AzDevOpsCache). The hierarchy WIQL selects [System.Parent] so each
# item carries its parent link directly - no follow-up resolution needed.
# ---------------------------------------------------------------------------

# Requirement-tier work-item types across the four stock process templates.
# Sync-AzDevOpsCache's hierarchy WIQL fetches by Microsoft.RequirementCategory,
# so hierarchy.json can carry any of these depending on the project's process:
#   Agile  -> 'User Story'
#   Scrum  -> 'Product Backlog Item'
#   CMMI   -> 'Requirement'
#   Basic  -> 'Issue'
# Tree consumers test set membership instead of matching the Agile literal so
# Scrum/CMMI/Basic projects render leaves under each Feature.
$script:AzDevOpsRequirementTypes = @(
    'User Story',
    'Product Backlog Item',
    'Requirement',
    'Issue'
)


function ConvertFrom-AzDevOpsHierarchyItem {
    param([Parameter(Mandatory)] $Raw)

    $f = $Raw.fields

    $parent = if ($null -ne $f.'System.Parent' -and "$($f.'System.Parent')" -ne '') {
        [int]$f.'System.Parent'
    }
    else {
        $null
    }

    $id = if ($f.'System.Id') {
        [int]$f.'System.Id'
    }
    else {
        [int]$Raw.id
    }

    $item = [PSCustomObject]@{
        Id        = $id
        Type      = $f.'System.WorkItemType'
        State     = $f.'System.State'
        Title     = $f.'System.Title'
        Iteration = $f.'System.IterationPath'
        AreaPath  = $f.'System.AreaPath'
        Parent    = $parent
    }
    return $item
}


function Read-AzDevOpsHierarchyCache {
    $paths = Get-AzDevOpsCachePaths
    $items = Read-AzDevOpsJsonCache `
        -Path        $paths.Hierarchy `
        -Description 'hierarchy' `
        -Converter { param($r) ConvertFrom-AzDevOpsHierarchyItem -Raw $r }
    return $items
}


function Get-AzDevOpsTreeIndent {
    param([Parameter(Mandatory)] [int] $Depth)

    $indentUnit = '    '   # 4 spaces per tree level
    $indent = $indentUnit * $Depth
    return $indent
}


function Get-AzDevOpsTreeIcon {
    param([Parameter(Mandatory)] [string] $Type)

    $iconEpic = "$([char]0x1F4E6)"   # package
    $iconFeature = "$([char]0x1F3AF)"   # bullseye
    $iconStory = "$([char]0x1F4DD)"   # memo
    $iconUnknown = '*'

    if ($Type -in $script:AzDevOpsRequirementTypes) {
        return $iconStory
    }

    switch ($Type) {
        'Epic' {
            return $iconEpic
        }

        'Feature' {
            return $iconFeature
        }

        default {
            return $iconUnknown
        }
    }
}


function Format-AzDevOpsTreeNode {
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Item,
        [Parameter(Mandatory)] [int] $Depth
    )

    $indent = Get-AzDevOpsTreeIndent -Depth $Depth
    $icon = Get-AzDevOpsTreeIcon -Type $Item.Type
    $separator = "$([char]0x2014)"   # em-dash

    # Requirement-tier lines drop the type label per the issue spec; epics +
    # features keep it so '📦 Epic 1234' / '🎯 Feature 1240' read clearly.
    if ($Item.Type -in $script:AzDevOpsRequirementTypes) {
        return "$indent$icon $($Item.Id) $separator $($Item.Title) [$($Item.State)]"
    }

    return "$indent$icon $($Item.Type) $($Item.Id) $separator $($Item.Title) [$($Item.State)]"
}


function Get-AzDevOpsTreeRows {
    # Walks the Epic -> Feature -> requirement-tier hierarchy and emits one
    # flat row per node with a Path column ('Epic 1 / Feature 2 / Story 3')
    # so the grid view stays sortable and filterable without losing the parent
    # context the indented tree gives the eye.
    param(
        [Parameter(Mandatory)] $Items,
        [Parameter(Mandatory)] $ByParent
    )

    $rows = New-Object System.Collections.Generic.List[PSCustomObject]
    $epics = @($Items | Where-Object { $_.Type -eq 'Epic' } | Sort-Object Id)

    # Build the URL prefix once instead of resolving env vars + escaping the
    # project name per row. Empty string when env vars are unset - callers see
    # an empty Url column instead of a per-row $LASTEXITCODE flip.
    $urlPrefix = Get-AzDevOpsWorkItemUrlPrefix

    foreach ($epic in $epics) {
        $epicPath = "Epic $($epic.Id) / $($epic.Title)"
        $epicUrl = if ($urlPrefix) {
            "$urlPrefix$($epic.Id)"
        }
        else {
            ''
        }

        $rows.Add([PSCustomObject]@{
                Type  = 'Epic'
                Id    = $epic.Id
                Title = $epic.Title
                State = $epic.State
                Depth = 0
                Path  = $epicPath
                Url   = $epicUrl
            })

        $features = @($ByParent[$epic.Id] | Where-Object { $_.Type -eq 'Feature' } | Sort-Object Id)
        foreach ($feature in $features) {
            $featurePath = "$epicPath / Feature $($feature.Id) / $($feature.Title)"
            $featureUrl = if ($urlPrefix) {
                "$urlPrefix$($feature.Id)"
            }
            else {
                ''
            }

            $rows.Add([PSCustomObject]@{
                    Type  = 'Feature'
                    Id    = $feature.Id
                    Title = $feature.Title
                    State = $feature.State
                    Depth = 1
                    Path  = $featurePath
                    Url   = $featureUrl
                })

            $stories = @($ByParent[$feature.Id] | Where-Object { $_.Type -in $script:AzDevOpsRequirementTypes } | Sort-Object Id)
            foreach ($story in $stories) {
                $storyPath = "$featurePath / Story $($story.Id) / $($story.Title)"
                $storyUrl = if ($urlPrefix) {
                    "$urlPrefix$($story.Id)"
                }
                else {
                    ''
                }

                $rows.Add([PSCustomObject]@{
                        Type  = $story.Type
                        Id    = $story.Id
                        Title = $story.Title
                        State = $story.State
                        Depth = 2
                        Path  = $storyPath
                        Url   = $storyUrl
                    })
            }
        }
    }

    $result = , @($rows)
    return $result
}


function az-Show-AzDevOpsTree {
    [CmdletBinding()]
    param()

    $items = Read-AzDevOpsHierarchyCache
    if ($null -eq $items) { return }

    Write-AzDevOpsStaleBanner

    $byParent = @{}
    foreach ($item in $items) {
        $key = if ($null -ne $item.Parent) {
            $item.Parent
        }
        else {
            0
        }

        if (-not $byParent.ContainsKey($key)) {
            $byParent[$key] = @()
        }
        $byParent[$key] += $item
    }

    $epics = @($items | Where-Object { $_.Type -eq 'Epic' } | Sort-Object Id)
    if ($epics.Count -eq 0) {
        Write-Host "(no epics in hierarchy cache)" -ForegroundColor Yellow
        return
    }

    if (Test-AzDevOpsGridAvailable) {
        $rows = Get-AzDevOpsTreeRows -Items $items -ByParent $byParent
        Show-AzDevOpsRows -Rows $rows -Title "Azure DevOps hierarchy - $(@($rows).Count) items"
        return
    }

    foreach ($epic in $epics) {
        Write-Output (Format-AzDevOpsTreeNode -Item $epic -Depth 0)

        $children = @($byParent[$epic.Id])
        $features = @($children | Where-Object { $_.Type -eq 'Feature' } | Sort-Object Id)

        if ($features.Count -eq 0) {
            $featuresIndent = Get-AzDevOpsTreeIndent -Depth 1
            Write-Output "$featuresIndent(no features)"
            continue
        }

        foreach ($feature in $features) {
            Write-Output (Format-AzDevOpsTreeNode -Item $feature -Depth 1)

            $stories = @($byParent[$feature.Id] | Where-Object { $_.Type -in $script:AzDevOpsRequirementTypes } | Sort-Object Id)
            foreach ($story in $stories) {
                Write-Output (Format-AzDevOpsTreeNode -Item $story -Depth 2)
            }
        }
    }
}


# ---------------------------------------------------------------------------
# Board view (group cached items by State)
#
# Public function:
#   az-Show-AzDevOpsBoard  - column-grouped board-style view of the cached
#                            hierarchy. Pipes through Show-AzDevOpsRows -PassThru
#                            so Out-ConsoleGridView's built-in group-by-State
#                            handles the kanban affordance interactively.
#
# Reuses the same $HOME/.bashcuts-az-devops-app/cache/hierarchy.json that
# az-Show-AzDevOpsTree consumes; never calls `az` directly. Default -Type list
# matches what the hierarchy WIQL pulls (Epic / Feature / requirement-tier).
# Default -State filter excludes closed states via Select-AzDevOpsActiveItems;
# pass -State Closed,Resolved to flip to the archive view.
# ---------------------------------------------------------------------------

function az-Show-AzDevOpsBoard {
    [CmdletBinding()]
    param(
        [string[]] $Type = @('Epic', 'Feature', 'User Story'),
        [string[]] $State
    )

    $items = Read-AzDevOpsHierarchyCache
    if ($null -eq $items) { return }

    Write-AzDevOpsStaleBanner

    $byType = @($items | Where-Object { $_.Type -in $Type })
    $byState = Select-AzDevOpsActiveItems -Items $byType -State $State

    $rows = @($byState | Sort-Object State, Type, Id | Select-Object State, Id, Type, (Get-AzDevOpsTitleColumn), Iteration)

    $title = "Board - $($rows.Count) items"

    $selected = Show-AzDevOpsRows -Rows $rows -Title $title -PassThru
    return $selected
}


# ---------------------------------------------------------------------------
# Interactive hierarchy drill-down
#
# Public function:
#   az-Find-AzDevOpsWorkItem - drills Epic -> Feature -> requirement-tier
#                              in Out-ConsoleGridView grids with a "Go Back"
#                              affordance at each tier and an inline "Open
#                              in browser" action. Loops on the outer Epic
#                              grid so the user can navigate multiple
#                              branches in one session and emits picked
#                              work-item ids on the pipeline.
#
# Reads the same $HOME/.bashcuts-az-devops-app/cache/hierarchy.json that
# az-Show-AzDevOpsTree consumes; never calls `az` directly. Modeled on the
# while ($running) { ... } + ".. [Go Back]" pattern from issue #39.
# ---------------------------------------------------------------------------

function New-AzDevOpsActionRow {
    # Synthetic grid row for EXIT / Go Back / Open shortcuts. Same column
    # shape as a hierarchy item so Out-ConsoleGridView columns don't collapse;
    # Type='Action' is the marker the drill-down loop dispatches on.
    param([Parameter(Mandatory)] [string] $Title)

    $row = [PSCustomObject]@{
        Type   = 'Action'
        Id     = 0
        Title  = $Title
        State  = ''
        Parent = $null
    }

    return $row
}


function az-Find-AzDevOpsWorkItem {
    [CmdletBinding()]
    param(
        [switch] $IncludeClosed
    )

    if (-not (Test-AzDevOpsGridAvailable)) {
        Write-AzDevOpsGridUnavailable -CommandName 'az-Find-AzDevOpsWorkItem'
        return
    }

    $items = Read-AzDevOpsHierarchyCache
    if ($null -eq $items) { return }

    Write-AzDevOpsStaleBanner

    $closedStates = Get-AzDevOpsClosedStates
    $visibleItems = if ($IncludeClosed) {
        $items
    }
    else {
        $items | Where-Object { $_.State -notin $closedStates }
    }

    $byParent = @{}
    foreach ($item in $visibleItems) {
        $key = if ($null -ne $item.Parent) {
            $item.Parent
        }
        else {
            0
        }

        if (-not $byParent.ContainsKey($key)) {
            $byParent[$key] = @()
        }
        $byParent[$key] += $item
    }

    $epics = @($visibleItems | Where-Object { $_.Type -eq 'Epic' } | Sort-Object Id)
    if ($epics.Count -eq 0) {
        Write-Host "(no epics in hierarchy cache)" -ForegroundColor Yellow
        return
    }

    $exitLabel = 'EXIT'
    $backLabel = '.. [Go Back]'
    $openEpicLabel = '.. [Open this Epic]'
    $openFeatureLabel = '.. [Open this Feature]'
    $openStoryLabel = '.. [Open this Story]'

    $running = $true
    $tier = 1
    $currentEpic = $null
    $currentFeature = $null
    $currentStory = $null

    while ($running) {

        if ($tier -eq 1) {
            $rows = @(New-AzDevOpsActionRow -Title $exitLabel) + $epics
            $title = "ALM Browser - pick an Epic ('EXIT' or Esc to quit)"
            $picked = $rows | Out-ConsoleGridView -Title $title -OutputMode Single

            if ($null -eq $picked -or $picked.Title -eq $exitLabel) {
                $running = $false
                continue
            }

            $currentEpic = $picked
            $tier = 2
            continue
        }

        if ($tier -eq 2) {
            $features = @($byParent[$currentEpic.Id] | Where-Object { $_.Type -eq 'Feature' } | Sort-Object Id)
            $rows = @(New-AzDevOpsActionRow -Title $backLabel) + $features + @(New-AzDevOpsActionRow -Title $openEpicLabel)

            $title = "Epic $($currentEpic.Id) - $($currentEpic.Title) - pick a Feature"
            $picked = $rows | Out-ConsoleGridView -Title $title -OutputMode Single

            if ($null -eq $picked -or $picked.Title -eq $backLabel) {
                $tier = 1
                continue
            }

            if ($picked.Title -eq $openEpicLabel) {
                Open-AzDevOpsWorkItemUrl -Id $currentEpic.Id
                Write-Output $currentEpic.Id
                continue
            }

            $currentFeature = $picked
            $tier = 3
            continue
        }

        if ($tier -eq 3) {
            $stories = @($byParent[$currentFeature.Id] | Where-Object { $_.Type -in $script:AzDevOpsRequirementTypes } | Sort-Object Id)
            $rows = @(New-AzDevOpsActionRow -Title $backLabel) + $stories + @(New-AzDevOpsActionRow -Title $openFeatureLabel)

            $title = "Feature $($currentFeature.Id) - $($currentFeature.Title) - pick a Story"
            $picked = $rows | Out-ConsoleGridView -Title $title -OutputMode Single

            if ($null -eq $picked -or $picked.Title -eq $backLabel) {
                $tier = 2
                continue
            }

            if ($picked.Title -eq $openFeatureLabel) {
                Open-AzDevOpsWorkItemUrl -Id $currentFeature.Id
                Write-Output $currentFeature.Id
                continue
            }

            $currentStory = $picked
            $tier = 4
            continue
        }

        if ($tier -eq 4) {
            $rows = @(
                New-AzDevOpsActionRow -Title $backLabel
                New-AzDevOpsActionRow -Title $openStoryLabel
            )

            $title = "Story $($currentStory.Id) - $($currentStory.Title) - choose action"
            $picked = $rows | Out-ConsoleGridView -Title $title -OutputMode Single

            if ($null -eq $picked -or $picked.Title -eq $backLabel) {
                $tier = 3
                continue
            }

            Open-AzDevOpsWorkItemUrl -Id $currentStory.Id
            Write-Output $currentStory.Id

            $tier = 1
            continue
        }
    }
}


# ---------------------------------------------------------------------------
# Interactive new-user-story creator
#
# Public function:
#   az-New-AzDevOpsUserStory   - prompts for title/description/priority/SP/AC,
#                              then walks parent-Feature / iteration / area
#                              pickers, calls `az boards work-item create`,
#                              links the chosen parent, and opens the new
#                              story in the browser.
#
# All prompts are skippable via parameters so the function works
# non-interactively in scripts.
# ---------------------------------------------------------------------------

function Read-AzDevOpsClassificationCache {
    # Reads iterations.json or areas.json from the cache. Returns the parsed
    # tree root, or $null when the cache file is missing / unparseable so
    # callers can fall back to a live `az` fetch.
    param([Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind)

    $paths = Get-AzDevOpsCachePaths
    $cachePath = if ($Kind -eq 'Iteration') {
        $paths.Iterations
    }
    else {
        $paths.Areas
    }

    if (-not (Test-Path -LiteralPath $cachePath)) {
        return $null
    }

    try {
        $tree = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
        return $tree
    }
    catch {
        return $null
    }
}


function Invoke-AzDevOpsClassificationLive {
    # Fetches the iteration / area tree directly from `az` when the cache
    # doesn't have it yet. Used as a fallback so the new-story flow keeps
    # working before the user runs az-Sync-AzDevOpsCache after this update.
    param([Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind)

    $result = Get-AzDevOpsClassificationList -Kind $Kind -Depth 5
    if ($result.ExitCode -ne 0) {
        return $null
    }

    try {
        $tree = $result.Json | ConvertFrom-Json
        return $tree
    }
    catch {
        return $null
    }
}


function ConvertTo-AzDevOpsWorkItemPath {
    # Converts an `az boards iteration/area project list` API path to the
    # IterationPath / AreaPath form used by WIQL and `az boards work-item
    # create`. The API returns paths like '\MyProject\Iteration\Sprint 42'
    # whereas work-items want 'MyProject\Sprint 42' (and 'MyProject\TeamA\
    # Backend' for areas). The classification root node ('\MyProject\Iteration')
    # has no work-item-path equivalent, so we return $null for it - callers
    # filter $null out of the picker list.
    param(
        [Parameter(Mandatory)] [string] $ApiPath,
        [Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind
    )

    $pattern = "^\\([^\\]+)\\$Kind\\"
    if ($ApiPath -match $pattern) {
        $converted = $ApiPath -replace $pattern, '$1\'
        return $converted
    }

    return $null
}


function ConvertTo-AzDevOpsClassificationPaths {
    # Flattens the tree returned by Read-AzDevOpsClassificationCache /
    # Invoke-AzDevOpsClassificationLive into a sorted, deduplicated array of
    # IterationPath / AreaPath strings ready for the picker.
    param(
        [Parameter(Mandatory)] $Root,
        [Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind
    )

    if ($null -eq $Root) {
        return @()
    }

    $collected = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)

    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        if ($null -eq $node) { continue }

        if ($node.path) {
            $converted = ConvertTo-AzDevOpsWorkItemPath -ApiPath $node.path -Kind $Kind
            if ($converted) {
                $collected.Add($converted)
            }
        }

        if ($node.children) {
            foreach ($child in $node.children) {
                $stack.Push($child)
            }
        }
    }

    $unique = $collected | Sort-Object -Unique
    $uniqueList = , @($unique)
    return $uniqueList
}


function Get-AzDevOpsClassificationPaths {
    # Single entry point for picker consumers: read from cache first, fall
    # back to live `az` with a one-line "(run az-Sync-AzDevOpsCache to make this
    # instant)" notice so the function stays usable before the user re-syncs.
    param([Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind)

    $tree = Read-AzDevOpsClassificationCache -Kind $Kind
    if ($null -eq $tree) {
        $azKind = $Kind.ToLower()
        Write-Host "(fetching ${azKind}s live - run az-Sync-AzDevOpsCache to make this instant)" -ForegroundColor Yellow
        $tree = Invoke-AzDevOpsClassificationLive -Kind $Kind
    }

    $paths = ConvertTo-AzDevOpsClassificationPaths -Root $tree -Kind $Kind
    return $paths
}


# ---------------------------------------------------------------------------
# Classification tree views
#
# Public functions:
#   az-Show-AzDevOpsAreas       - prints the project's area-path tree
#   az-Show-AzDevOpsIterations  - prints the project's iteration-path tree
#                                 (with start/finish dates per node)
#
# Both read from the cache first (areas.json / iterations.json built by
# az-Sync-AzDevOpsCache) and fall back to a live `az boards <kind> project
# list` call when the cache is missing - same pattern as the picker's
# Get-AzDevOpsClassificationPaths. Renders to Out-ConsoleGridView when
# available, falls back to an indented text tree otherwise.
# ---------------------------------------------------------------------------

function ConvertFrom-AzDevOpsClassificationTree {
    # Walks the classification tree (depth-first, children in declaration
    # order) and emits one PSCustomObject per node. Skips the synthetic root
    # node (whose path is the bare '\<Project>\<Kind>' shell with no work-
    # item-path equivalent) so consumers only see pickable entries.
    #
    # Row shape:
    #   Areas:      Depth, Name, Path, HasChildren
    #   Iterations: Depth, Name, Path, HasChildren, StartDate, FinishDate
    #
    # StartDate / FinishDate are [datetime]? so pipeline callers can use
    # `Where-Object { $_.StartDate -ge (Get-Date) }`. Display callers
    # (az-Show-AzDevOps*) format them to ISO yyyy-MM-dd strings just before
    # rendering.
    param(
        [Parameter(Mandatory)] $Tree,
        [Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind
    )

    $rows = New-Object System.Collections.Generic.List[PSCustomObject]
    if ($null -eq $Tree) {
        $empty = , @($rows)
        return $empty
    }

    $walk = {
        param($Node, $Depth)

        if ($null -eq $Node) { return }

        # Only emit the synthetic root's children onward - the root itself
        # is the bare project/kind shell that ConvertTo-AzDevOpsWorkItemPath
        # filters out (returns $null for it). Emit Path in work-item-path
        # form ('MyProject\TeamA\Backend') so pipeline callers can drop it
        # straight into WIQL or `az boards work-item create`.
        if ($Depth -gt 0) {
            $workItemPath = ConvertTo-AzDevOpsWorkItemPath -ApiPath $Node.path -Kind $Kind

            if ($workItemPath) {
                $hasChildren = [bool]($Node.children -and @($Node.children).Count -gt 0)

                $row = if ($Kind -eq 'Iteration') {
                    $startDate = if ($Node.attributes -and $Node.attributes.startDate) {
                        $Node.attributes.startDate -as [datetime]
                    }
                    else {
                        $null
                    }

                    $finishDate = if ($Node.attributes -and $Node.attributes.finishDate) {
                        $Node.attributes.finishDate -as [datetime]
                    }
                    else {
                        $null
                    }

                    [PSCustomObject]@{
                        Depth       = $Depth
                        Name        = $Node.name
                        Path        = $workItemPath
                        HasChildren = $hasChildren
                        StartDate   = $startDate
                        FinishDate  = $finishDate
                    }
                }
                else {
                    [PSCustomObject]@{
                        Depth       = $Depth
                        Name        = $Node.name
                        Path        = $workItemPath
                        HasChildren = $hasChildren
                    }
                }

                $rows.Add($row)
            }
        }

        if ($Node.children) {
            foreach ($child in $Node.children) {
                & $walk $child ($Depth + 1)
            }
        }
    }

    & $walk $Tree 0

    $result = , @($rows)
    return $result
}


function Format-AzDevOpsClassificationDate {
    # Renders a [datetime]? as ISO yyyy-MM-dd, or '' when $null. Single
    # source of truth for the date formatting used by the Show- display
    # projection and Format-AzDevOpsClassificationNode's text fallback.
    param([datetime] $Date)

    if ($null -eq $Date) {
        return ''
    }

    $iso = $Date.ToString('yyyy-MM-dd')
    return $iso
}


function ConvertTo-AzDevOpsClassificationDisplayRows {
    # Projects the typed rows from ConvertFrom-AzDevOpsClassificationTree
    # into the display-shaped rows az-Show-AzDevOpsAreas /
    # az-Show-AzDevOpsIterations render in the grid: dates become ISO
    # strings, HasChildren is dropped (display noise).
    param(
        [Parameter(Mandatory)] $Rows,
        [Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind
    )

    if ($null -eq $Rows -or @($Rows).Count -eq 0) {
        $empty = , @()
        return $empty
    }

    $displayRows = if ($Kind -eq 'Iteration') {
        @($Rows | ForEach-Object {
            $startIso  = Format-AzDevOpsClassificationDate -Date $_.StartDate
            $finishIso = Format-AzDevOpsClassificationDate -Date $_.FinishDate

            [PSCustomObject]@{
                Depth      = $_.Depth
                Name       = $_.Name
                Path       = $_.Path
                StartDate  = $startIso
                FinishDate = $finishIso
            }
        })
    }
    else {
        @($Rows | Select-Object Depth, Name, Path)
    }

    $result = , $displayRows
    return $result
}


function Format-AzDevOpsClassificationNode {
    # Text-fallback per-node line. '<indent><name>' for areas; for iterations
    # appends '<tab><start> -> <finish>' when both dates are present (omits
    # the date suffix when either is blank). The tab separator keeps the
    # dates copy-paste-able into a spreadsheet. Accepts the typed rows from
    # ConvertFrom-AzDevOpsClassificationTree (dates as [datetime]?).
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Row,
        [Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind
    )

    $indent = Get-AzDevOpsTreeIndent -Depth ($Row.Depth - 1)
    $arrowGlyph = "$([char]0x2192)"   # rightwards arrow
    $line = "$indent$($Row.Name)"

    if ($Kind -eq 'Iteration' -and $Row.StartDate -and $Row.FinishDate) {
        $startIso  = Format-AzDevOpsClassificationDate -Date $Row.StartDate
        $finishIso = Format-AzDevOpsClassificationDate -Date $Row.FinishDate
        $line = "$line`t$startIso $arrowGlyph $finishIso"
    }

    return $line
}


function Read-AzDevOpsClassificationRows {
    # Cache-first + live-fallback read + flatten. Emits the stale banner and
    # the live-fetch notice as Write-Host side effects (metadata, not data).
    # Returns the typed rows from ConvertFrom-AzDevOpsClassificationTree, or
    # $null when neither the cache nor a live fetch yields a tree (e.g. the
    # user cancels the auth gate). Shared by az-Show-AzDevOps* /
    # az-Get-AzDevOps* / az-Find-AzDevOps* for the classification trees.
    param(
        [Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind,
        [Parameter(Mandatory)] [string] $CommandName
    )

    $azKind = $Kind.ToLower()
    $kindLabelLow = "${azKind}s"

    $tree = Read-AzDevOpsClassificationCache -Kind $Kind
    $cameFromCache = $true

    if ($null -eq $tree) {
        if (-not (Assert-AzDevOpsAuthOrAbort -CommandName $CommandName)) {
            return $null
        }

        Write-Host "(fetching $kindLabelLow live - run az-Sync-AzDevOpsCache to make this instant)" -ForegroundColor Yellow
        $tree = Invoke-AzDevOpsClassificationLive -Kind $Kind
        $cameFromCache = $false
    }

    if ($null -eq $tree) {
        return $null
    }

    if ($cameFromCache) {
        Write-AzDevOpsStaleBanner
    }

    $rows = ConvertFrom-AzDevOpsClassificationTree -Tree $tree -Kind $Kind
    return $rows
}


function Show-AzDevOpsClassification {
    # Orchestrator for az-Show-AzDevOpsAreas / az-Show-AzDevOpsIterations.
    # Reads + flattens via Read-AzDevOpsClassificationRows, projects typed
    # rows to display rows, then renders to Out-ConsoleGridView when
    # available or to an indented text tree via Format-AzDevOpsClassificationNode
    # otherwise. Mirrors the az-Show-AzDevOpsTree post-#36 shape so the Show-
    # family stays uniform.
    param([Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind)

    $azKind = $Kind.ToLower()
    $kindLabelLow = "${azKind}s"
    $publicCommand = "az-Show-AzDevOps$($Kind)s"

    $rows = Read-AzDevOpsClassificationRows -Kind $Kind -CommandName $publicCommand
    if ($null -eq $rows) {
        return
    }

    if (@($rows).Count -eq 0) {
        Write-Host "(no $kindLabelLow defined)" -ForegroundColor Yellow
        return
    }

    if (Test-AzDevOpsGridAvailable) {
        $displayRows = ConvertTo-AzDevOpsClassificationDisplayRows -Rows $rows -Kind $Kind
        $title = "Azure DevOps $kindLabelLow - $(@($rows).Count) nodes"
        Show-AzDevOpsRows -Rows $displayRows -Title $title
        return
    }

    foreach ($row in $rows) {
        Write-Output (Format-AzDevOpsClassificationNode -Row $row -Kind $Kind)
    }
}


function az-Show-AzDevOpsAreas {
    [CmdletBinding()]
    param()

    Show-AzDevOpsClassification -Kind 'Area'
}


function az-Show-AzDevOpsIterations {
    [CmdletBinding()]
    param()

    Show-AzDevOpsClassification -Kind 'Iteration'
}


# ---------------------------------------------------------------------------
# Classification rows for pipeline consumers
#
# Public functions:
#   az-Get-AzDevOpsAreas       - pipeable rows for the area-path tree
#                                (Depth / Name / Path / HasChildren)
#   az-Get-AzDevOpsIterations  - pipeable rows for the iteration tree
#                                (adds StartDate / FinishDate as [datetime]?)
#
# Both wrap Read-AzDevOpsClassificationRows so the cache-first / live-fallback
# behavior matches az-Show-AzDevOps*. Path is the work-item-path form
# ('MyProject\TeamA\Backend') so callers can pipe straight into WIQL or
# `az boards work-item create --area-path ...`.
# ---------------------------------------------------------------------------

function az-Get-AzDevOpsAreas {
    [CmdletBinding()]
    param()

    $rows = Read-AzDevOpsClassificationRows -Kind 'Area' -CommandName 'az-Get-AzDevOpsAreas'
    return $rows
}


function az-Get-AzDevOpsIterations {
    [CmdletBinding()]
    param()

    $rows = Read-AzDevOpsClassificationRows -Kind 'Iteration' -CommandName 'az-Get-AzDevOpsIterations'
    return $rows
}


# ---------------------------------------------------------------------------
# Classification pickers (interactive drill-down for the classification trees)
#
# Public functions:
#   az-Find-AzDevOpsArea       - Out-ConsoleGridView picker over the area tree;
#                                emits the picked Path (work-item-path form)
#                                or $null when the user cancels.
#   az-Find-AzDevOpsIteration  - same shape, plus StartDate / FinishDate grid
#                                columns so the user can pick by sprint dates.
#
# Both require Microsoft.PowerShell.ConsoleGuiTools - they print the install
# hint and return when the cmdlet is missing. Neither function has side
# effects (does not set $env:AZ_AREA / $env:AZ_ITERATION); callers that want
# that behavior can pipe the result into Set-Item env:AZ_AREA.
# ---------------------------------------------------------------------------

$script:AzDevOpsConsoleGuiToolsInstallHint = 'Install with: Install-Module Microsoft.PowerShell.ConsoleGuiTools -Scope CurrentUser'


function Write-AzDevOpsGridUnavailable {
    # Single source of truth for the "Out-ConsoleGridView is required for X"
    # message shape so every az-Find-AzDevOps* uses the same wording.
    param([Parameter(Mandatory)] [string] $CommandName)

    Write-Host "Out-ConsoleGridView is required for $CommandName." -ForegroundColor Yellow
    Write-Host "  $script:AzDevOpsConsoleGuiToolsInstallHint" -ForegroundColor Yellow
}


function az-Find-AzDevOpsArea {
    [CmdletBinding()]
    param()

    if (-not (Test-AzDevOpsGridAvailable)) {
        Write-AzDevOpsGridUnavailable -CommandName 'az-Find-AzDevOpsArea'
        return
    }

    $rows = Read-AzDevOpsClassificationRows -Kind 'Area' -CommandName 'az-Find-AzDevOpsArea'
    if ($null -eq $rows -or @($rows).Count -eq 0) {
        Write-Host '(no areas available)' -ForegroundColor Yellow
        return
    }

    $paths = @($rows | ForEach-Object { $_.Path } | Where-Object { $_ })
    if ($paths.Count -eq 0) {
        Write-Host '(no pickable area paths)' -ForegroundColor Yellow
        return
    }

    # Read-AzDevOpsClassificationPick returns its $Default param on cancel,
    # which falls back to '' (empty string) when no default is supplied here.
    # Normalize that to $null so this function and az-Find-AzDevOpsIteration
    # share the same "cancelled" signal on the pipeline.
    $picked = Read-AzDevOpsClassificationPick -Kind 'Area' -Paths $paths
    if (-not $picked) {
        return $null
    }

    return $picked
}


function az-Find-AzDevOpsIteration {
    [CmdletBinding()]
    param()

    if (-not (Test-AzDevOpsGridAvailable)) {
        Write-AzDevOpsGridUnavailable -CommandName 'az-Find-AzDevOpsIteration'
        return
    }

    $rows = Read-AzDevOpsClassificationRows -Kind 'Iteration' -CommandName 'az-Find-AzDevOpsIteration'
    if ($null -eq $rows -or @($rows).Count -eq 0) {
        Write-Host '(no iterations available)' -ForegroundColor Yellow
        return
    }

    $displayRows = ConvertTo-AzDevOpsClassificationDisplayRows -Rows $rows -Kind 'Iteration'
    $pickRows = @($displayRows | Select-Object Path, StartDate, FinishDate)

    $picked = Read-AzDevOpsGridPick -Rows $pickRows -Title 'Pick iteration'
    if ($null -eq $picked) {
        return $null
    }

    $pickedPath = [string]$picked.Path
    return $pickedPath
}


function Get-AzDevOpsReuseHint {
    # Builds the " (Enter to reuse '<value>')" suffix used by batch-flow readers
    # that carry forward the prior loop's answer. Returns '' when Previous has
    # no usable value so the prompt collapses cleanly to its non-batch form.
    param([object] $Previous)

    if ($null -eq $Previous -or "$Previous" -eq '') {
        return ''
    }

    $hint = " (Enter to reuse '$Previous')"
    return $hint
}


function Read-AzDevOpsPriority {
    # -Previous lets batch flows (az-New-AzDevOpsFeatureStories) carry the
    # prior priority forward: empty input reuses Previous, any 1-4 digit
    # overrides. Single-shot callers omit -Previous and get the original
    # required-prompt behavior.
    param([int] $Previous = -1)

    $hasPrevious = $Previous -ge 1 -and $Previous -le 4
    $hint = if ($hasPrevious) {
        Get-AzDevOpsReuseHint -Previous $Previous
    }
    else {
        ''
    }

    while ($true) {
        $resp = Read-Host "Priority? 1=LOW, 2=MEDIUM, 3=HIGH, 4=SUPER-HIGH$hint"
        if (-not $resp -and $hasPrevious) {
            return $Previous
        }
        if ($resp -match '^[1-4]$') {
            $priority = [int]$resp
            return $priority
        }
        Write-Host "  Please enter 1, 2, 3, or 4." -ForegroundColor Yellow
    }
}


function Read-AzDevOpsStoryPoints {
    # -Previous mirrors Read-AzDevOpsPriority's reuse shorthand for batch flows.
    param([int] $Previous = -1)

    $hasPrevious = $Previous -ge 0
    $hint = if ($hasPrevious) {
        Get-AzDevOpsReuseHint -Previous $Previous
    }
    else {
        ''
    }

    $val = 0
    while ($true) {
        $resp = Read-Host "Story points? (integer)$hint"
        if (-not $resp -and $hasPrevious) {
            return $Previous
        }
        if ([int]::TryParse($resp, [ref]$val) -and $val -ge 0) {
            return $val
        }
        Write-Host "  Please enter a non-negative integer." -ForegroundColor Yellow
    }
}


function Read-AzDevOpsAcceptanceCriteria {
    # One initial AC, then loop on Y/N. Joins additional ACs with '<br/><br/>'
    # so they render as separate lines in the work-item editor. The existing
    # az-create-userstory used `until ($resp -eq 'n')` which loops forever on
    # any non-'n' reply (empty Enter, 'yes', 'q'); this version exits on
    # anything that isn't an affirmative yes/y.
    $first = Read-Host 'Acceptance criterion #1'
    $dash = '-'
    $break = '<br/><br/>'
    $ac = "$dash $first"

    while ($true) {
        $resp = Read-Host 'More AC? (Y/N)'
        if ($resp -notmatch '^(y|yes)$') {
            break
        }

        $next = Read-Host 'Enter additional AC'
        $ac = "$ac $break $dash $next"
    }

    return $ac
}


function Test-AzDevOpsAreaPathMatch {
    # Returns $true when $CandidatePath equals any element of $AllowedPaths
    # exactly OR is a sub-path of one (matches at backslash boundary). Path
    # comparison is case-insensitive to match Azure DevOps' own semantics:
    # 'Project ABC\Portfolio' matches both 'Project ABC\Portfolio' and
    # 'Project ABC\Portfolio\R&D'.
    param(
        [string]   $CandidatePath,
        [string[]] $AllowedPaths
    )

    if (-not $CandidatePath) {
        return $false
    }

    foreach ($allowed in $AllowedPaths) {
        if (-not $allowed) {
            continue
        }
        if ($CandidatePath -ieq $allowed) {
            return $true
        }
        $prefix = "$allowed\"
        if ($CandidatePath.Length -gt $prefix.Length -and
            $CandidatePath.Substring(0, $prefix.Length) -ieq $prefix) {
            return $true
        }
    }

    return $false
}


function Read-AzDevOpsParentPick {
    # Generic parent picker shared by Read-AzDevOpsFeaturePick (story -> Feature)
    # and Read-AzDevOpsEpicPick (Feature -> Epic). Lists active rows of the
    # requested ParentType from the hierarchy cache and returns the chosen Id,
    # or 0 when the user picks 'orphan' / cancels. Out-ConsoleGridView TUI when
    # available, Read-Host numbered menu otherwise.
    #
    # -AreaPaths narrows the candidate list to rows whose AreaPath equals or is
    # a sub-path of any provided value (sourced from
    # ParentScope.AreaPaths in the active project map). When the hierarchy rows
    # carry no AreaPath the filter is a silent no-op (logged once at -Verbose).
    #
    # Limitation: Basic-template projects skip the Feature tier entirely
    # (Epic -> Issue, no Feature). For -ParentType Feature this filter
    # returns zero rows on Basic projects and the caller falls through to
    # the orphan path - acceptable while the create flow stays Agile/Scrum/
    # CMMI-focused.
    param(
        [Parameter(Mandatory)] [ValidateSet('Feature', 'Epic')] [string] $ParentType,
        [Parameter(Mandatory)] $Hierarchy,
        [string]   $ChildLabel = 'item',
        [string[]] $AreaPaths
    )

    $closedStates = Get-AzDevOpsClosedStates
    $candidates = @($Hierarchy |
        Where-Object { $_.Type -eq $ParentType -and $_.State -notin $closedStates } |
        Sort-Object Id)

    $orphanLabel = "(no parent - orphan $ChildLabel)"

    if ($candidates.Count -eq 0) {
        Write-Host "(no active ${ParentType}s in hierarchy.json - $ChildLabel will be orphaned)" -ForegroundColor Yellow
        return 0
    }

    if ($AreaPaths -and $AreaPaths.Count -gt 0) {
        $hasAreaField = $false
        foreach ($row in $candidates) {
            if ($row.PSObject.Properties.Match('AreaPath').Count -gt 0 -and $row.AreaPath) {
                $hasAreaField = $true
                break
            }
        }

        if (-not $hasAreaField) {
            Write-Verbose "Read-AzDevOpsParentPick: hierarchy rows lack AreaPath; ParentScope.AreaPaths filter skipped. Run az-Sync-AzDevOpsCache to refresh."
        }
        else {
            $filtered = @($candidates |
                Where-Object { Test-AzDevOpsAreaPathMatch -CandidatePath $_.AreaPath -AllowedPaths $AreaPaths })

            if ($filtered.Count -eq 0) {
                Write-Host "(no ${ParentType}s match ParentScope.AreaPaths - $ChildLabel will be orphaned)" -ForegroundColor Yellow
                return 0
            }

            $candidates = $filtered
        }
    }

    if (Test-AzDevOpsGridAvailable) {
        $orphanRow = [PSCustomObject]@{
            Id    = 0
            Title = $orphanLabel
            State = ''
        }

        $candidateRows = $candidates | ForEach-Object {
            $title = Format-AzDevOpsTruncatedTitle -Title $_.Title
            [PSCustomObject]@{
                Id    = $_.Id
                Title = $title
                State = $_.State
            }
        }

        $gridRows = @($orphanRow) + @($candidateRows)
        $picked = Read-AzDevOpsGridPick -Rows $gridRows -Title "Pick a parent $ParentType (Esc = orphan $ChildLabel)"

        if ($null -eq $picked) {
            return 0
        }

        $parentId = [int]$picked.Id
        return $parentId
    }

    Write-Host ""
    Write-Host "Active ${ParentType}s:" -ForegroundColor Cyan
    Write-Host "  0. $orphanLabel"
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $c = $candidates[$i]
        $title = Format-AzDevOpsTruncatedTitle -Title $c.Title
        Write-Host ("  {0}. {1} - {2} [{3}]" -f ($i + 1), $c.Id, $title, $c.State)
    }

    $idx = 0
    while ($true) {
        $resp = Read-Host "Pick a parent $ParentType (0 for no parent)"
        if (-not [int]::TryParse($resp, [ref]$idx)) {
            Write-Host "  Please enter a number." -ForegroundColor Yellow
            continue
        }

        if ($idx -eq 0) {
            return 0
        }

        if ($idx -ge 1 -and $idx -le $candidates.Count) {
            $parentId = $candidates[$idx - 1].Id
            return $parentId
        }

        Write-Host "  Please enter 0..$($candidates.Count)." -ForegroundColor Yellow
    }
}


function Get-AzDevOpsParentScopeAreaPaths {
    # Looks up ParentScope.AreaPaths for the given child work-item type via the
    # Phase A resolver layer. Returns a (possibly empty) string[] - callers
    # forward straight to Read-AzDevOpsParentPick -AreaPaths and the filter is
    # a no-op on empty.
    param([Parameter(Mandatory)] [string] $ChildType)

    if (-not (Get-Command Resolve-AzDevOpsTypeParentScope -ErrorAction SilentlyContinue)) {
        return @()
    }

    $scope = Resolve-AzDevOpsTypeParentScope -Type $ChildType
    if ($null -eq $scope) {
        return @()
    }

    $paths = @($scope.AreaPaths)
    return $paths
}


function Read-AzDevOpsFeaturePick {
    # Story -> Feature parent picker. Thin wrapper over Read-AzDevOpsParentPick
    # so az-New-AzDevOpsUserStory keeps its current call site unchanged.
    # -ChildType drives the ParentScope.AreaPaths lookup; defaults to USER_STORY.
    param(
        [Parameter(Mandatory)] $Hierarchy,
        [string] $ChildType = 'USER_STORY'
    )

    $areaPaths = Get-AzDevOpsParentScopeAreaPaths -ChildType $ChildType
    $featureId = Read-AzDevOpsParentPick -ParentType 'Feature' -Hierarchy $Hierarchy -ChildLabel 'story' -AreaPaths $areaPaths
    return $featureId
}


function Read-AzDevOpsEpicPick {
    # Feature -> Epic parent picker. Thin wrapper over Read-AzDevOpsParentPick
    # used by az-New-AzDevOpsFeature. -ChildType drives the ParentScope.AreaPaths
    # lookup; defaults to FEATURE.
    param(
        [Parameter(Mandatory)] $Hierarchy,
        [string] $ChildType = 'FEATURE'
    )

    $areaPaths = Get-AzDevOpsParentScopeAreaPaths -ChildType $ChildType
    $epicId = Read-AzDevOpsParentPick -ParentType 'Epic' -Hierarchy $Hierarchy -ChildLabel 'Feature' -AreaPaths $areaPaths
    return $epicId
}


function Read-AzDevOpsClassificationPick {
    # Picker shared by iteration + area selection. When Out-ConsoleGridView
    # is available, renders a Path / IsDefault grid; Cancel returns the
    # supplied default (typically $env:AZ_ITERATION / $env:AZ_AREA).
    # Otherwise falls back to the Read-Host numbered menu where empty
    # input selects the default.
    param(
        [Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind,
        [Parameter(Mandatory)] [string[]] $Paths,
        [string] $Default
    )

    if (Test-AzDevOpsGridAvailable) {
        $gridRows = $Paths | ForEach-Object {
            [PSCustomObject]@{
                Path      = $_
                IsDefault = ($Default -and $_ -eq $Default)
            }
        }

        $title = if ($Default) {
            "Pick $Kind (Esc = use default '$Default')"
        }
        else {
            "Pick $Kind"
        }

        $picked = Read-AzDevOpsGridPick -Rows $gridRows -Title $title

        if ($null -eq $picked) {
            return $Default
        }

        $pickedPath = [string]$picked.Path
        return $pickedPath
    }

    Write-Host ""
    Write-Host "Available ${Kind}s:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Paths.Count; $i++) {
        $marker = if ($Default -and $Paths[$i] -eq $Default) {
            ' (default)'
        }
        else {
            ''
        }
        Write-Host ("  {0}. {1}{2}" -f ($i + 1), $Paths[$i], $marker)
    }

    $defaultPrompt = if ($Default) {
        " (Enter for default '$Default')"
    }
    else {
        ''
    }

    $idx = 0
    while ($true) {
        $resp = Read-Host "Pick $Kind$defaultPrompt"
        if (-not $resp -and $Default) {
            return $Default
        }

        if (-not [int]::TryParse($resp, [ref]$idx)) {
            Write-Host "  Please enter a number." -ForegroundColor Yellow
            continue
        }

        if ($idx -ge 1 -and $idx -le $Paths.Count) {
            $pickedPath = $Paths[$idx - 1]
            return $pickedPath
        }

        Write-Host "  Please enter 1..$($Paths.Count)." -ForegroundColor Yellow
    }
}


function Read-AzDevOpsKindPick {
    # Single iteration / area picker shared by both kinds. Reads the
    # cache (or falls back to live `az`), then either renders the numbered
    # menu or - if no paths are available - returns the matching $env:AZ_*
    # default. Returns $null if both the cache and the env-var default are
    # empty; callers must guard for that and abort cleanly.
    param([Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind)

    $envName = if ($Kind -eq 'Iteration') {
        'AZ_ITERATION'
    }
    else {
        'AZ_AREA'
    }

    $envFallback = if ($Kind -eq 'Iteration') {
        $env:AZ_ITERATION
    }
    else {
        $env:AZ_AREA
    }

    $paths = Get-AzDevOpsClassificationPaths -Kind $Kind
    if ($paths.Count -eq 0) {
        if (-not $envFallback) {
            Write-Host "(no ${Kind}s available and `$env:$envName is unset)" -ForegroundColor Red
            return $null
        }
        Write-Host "(no ${Kind}s available - falling back to `$env:$envName='$envFallback')" -ForegroundColor Yellow
        return $envFallback
    }

    $picked = Read-AzDevOpsClassificationPick -Kind $Kind -Paths $paths -Default $envFallback
    return $picked
}


function Invoke-AzDevOpsWorkItemCreate {
    # Wraps `az boards work-item create --type <Type> ...` so the orchestrator
    # can react to a non-zero exit cleanly. Returns a result object with
    # Ok / Error / Id / Url so the caller can decide whether to attempt the
    # parent-link step and what URL to echo / open.
    #
    # -Type defaults to 'User Story' so existing az-New-AzDevOpsUserStory
    # callers stay binary-compatible. -StoryPoints accepts -1 ("omit field")
    # so Feature creates can skip the story-points field cleanly - Features
    # don't carry story points in the default Agile / Scrum templates.
    param(
        [Parameter(Mandatory)] [string] $Title,
        [string] $Description,
        [Parameter(Mandatory)] [int]    $Priority,
        [int]    $StoryPoints = -1,
        [string] $AcceptanceCriteria,
        [string] $Iteration,
        [string] $Area = $env:AZ_AREA,
        [string] $Type = 'User Story',
        [string[]]  $Tags,
        [hashtable] $ExtraFields
    )

    $fields = @(
        "Microsoft.VSTS.Common.Priority=$Priority",
        "Microsoft.VSTS.Common.AcceptanceCriteria=$AcceptanceCriteria"
    )

    if ($StoryPoints -ge 0) {
        $fields += "Microsoft.VSTS.Scheduling.StoryPoints=$StoryPoints"
    }

    if ($Tags -and $Tags.Count -gt 0) {
        $tagList = ($Tags | Where-Object { $_ } | ForEach-Object { [string]$_ }) -join '; '
        if ($tagList) {
            $fields += "System.Tags=$tagList"
        }
    }

    if ($ExtraFields -and $ExtraFields.Count -gt 0) {
        foreach ($key in $ExtraFields.Keys) {
            $value = $ExtraFields[$key]
            if ($null -eq $value) {
                continue
            }
            $fields += "$key=$value"
        }
    }

    $result = New-AzDevOpsWorkItem `
        -Type        $Type `
        -Title       $Title `
        -Description $Description `
        -AssignedTo  $env:AZ_USER_EMAIL `
        -Area        $Area `
        -Iteration   $Iteration `
        -Fields      $fields

    if ($result.ExitCode -ne 0) {
        return [PSCustomObject]@{
            Ok    = $false
            Error = $result.Error
            Id    = 0
            Url   = $null
        }
    }

    try {
        $created = $result.Json | ConvertFrom-Json
    }
    catch {
        return [PSCustomObject]@{
            Ok    = $false
            Error = "parse failed: $($_.Exception.Message)"
            Id    = 0
            Url   = $null
        }
    }

    $newId = [int]$created.id

    $urlPrefix = Get-AzDevOpsWorkItemUrlPrefix
    $url = if ($urlPrefix) {
        "$urlPrefix$newId"
    } else {
        $null
    }

    return [PSCustomObject]@{
        Ok    = $true
        Error = $null
        Id    = $newId
        Url   = $url
    }
}


function Invoke-AzDevOpsParentLink {
    # `az boards work-item relation add --relation-type parent --id <new>
    # --target-id <feature>` wrapper. Failure here doesn't undo the create -
    # the orchestrator surfaces both the orphaned new-id and the az error so
    # the user can re-link manually.
    param(
        [Parameter(Mandatory)] [int] $Id,
        [Parameter(Mandatory)] [int] $ParentId
    )

    $result = Add-AzDevOpsWorkItemRelation -Id $Id -TargetId $ParentId -RelationType 'parent'

    if ($result.ExitCode -ne 0) {
        return [PSCustomObject]@{ Ok = $false; Error = $result.Error }
    }

    return [PSCustomObject]@{ Ok = $true; Error = $null }
}


function Test-AzDevOpsCreateGate {
    # Auth + AZ_USER_EMAIL gate shared by every az-New-AzDevOps* creator.
    # Prints the abort message and returns $false on miss so callers can
    # short-circuit with a single `if (-not (Test-AzDevOpsCreateGate ...))`.
    param([Parameter(Mandatory)] [string] $CommandName)

    if (-not (Assert-AzDevOpsAuthOrAbort -CommandName $CommandName)) {
        return $false
    }

    if (-not $env:AZ_USER_EMAIL) {
        Write-Host "$CommandName aborted - `$env:AZ_USER_EMAIL is not set in your `$profile." -ForegroundColor Red
        return $false
    }

    return $true
}


function Read-AzDevOpsRequiredFields {
    # Walks Resolve-AzDevOpsTypeRequiredFields output for the given type and
    # returns a hashtable of <RefName> = <value> ready to feed
    # Invoke-AzDevOpsWorkItemCreate -ExtraFields. Entries whose value is the
    # literal 'prompt' (case-insensitive) trigger a Read-Host; any other value
    # passes through unchanged. Empty input on a 'prompt' entry skips that field
    # rather than sending an empty string to `az boards work-item create`.
    param([Parameter(Mandatory)] [string] $Type)

    $result = @{}
    if (-not (Get-Command Resolve-AzDevOpsTypeRequiredFields -ErrorAction SilentlyContinue)) {
        return $result
    }

    $required = Resolve-AzDevOpsTypeRequiredFields -Type $Type
    if ($null -eq $required -or $required.Count -eq 0) {
        return $result
    }

    foreach ($refName in $required.Keys) {
        $value = $required[$refName]
        if ("$value".Trim().ToLower() -eq 'prompt') {
            $answer = Read-Host "Enter $refName"
            if ($answer) {
                $result[$refName] = $answer
            }
        }
        else {
            $result[$refName] = $value
        }
    }

    return $result
}


function Resolve-AzDevOpsTypePriorityOrPrompt {
    # Type override -> Read-AzDevOpsPriority fallback. Used by az-New-AzDevOps*
    # creators to skip the prompt when the active project pins a DefaultPriority.
    # -Previous flows the batch-loop "Enter to reuse" hint through when applicable.
    param(
        [Parameter(Mandatory)] [string] $Type,
        [int] $Previous = -1
    )

    if (Get-Command Resolve-AzDevOpsTypeDefaultPriority -ErrorAction SilentlyContinue) {
        $default = Resolve-AzDevOpsTypeDefaultPriority -Type $Type
        if ($null -ne $default) {
            return [int]$default
        }
    }

    $priority = Read-AzDevOpsPriority -Previous $Previous
    return $priority
}


function Resolve-AzDevOpsTypeStoryPointsOrPrompt {
    # Type override -> Read-AzDevOpsStoryPoints fallback. Same shape as
    # Resolve-AzDevOpsTypePriorityOrPrompt; only meaningful for USER_STORY in
    # default Agile / Scrum templates.
    param(
        [Parameter(Mandatory)] [string] $Type,
        [int] $Previous = -1
    )

    if (Get-Command Resolve-AzDevOpsTypeDefaultStoryPoints -ErrorAction SilentlyContinue) {
        $default = Resolve-AzDevOpsTypeDefaultStoryPoints -Type $Type
        if ($null -ne $default) {
            return [int]$default
        }
    }

    $storyPoints = Read-AzDevOpsStoryPoints -Previous $Previous
    return $storyPoints
}


function Resolve-AzDevOpsTypeTagsOrEmpty {
    # Thin wrapper that hides the Get-Command guard so creators stay readable.
    # Always returns a string[] (possibly empty).
    param([Parameter(Mandatory)] [string] $Type)

    if (-not (Get-Command Resolve-AzDevOpsTypeTags -ErrorAction SilentlyContinue)) {
        return @()
    }

    $tags = @(Resolve-AzDevOpsTypeTags -Type $Type)
    return $tags
}


function Resolve-AzDevOpsIterationArea {
    # Picker + env-var fallback shared by every az-New-AzDevOps* creator. For
    # each kind: if the caller already passed a value, keep it; otherwise consult
    # the per-type project-map override (Resolve-AzDevOpsType{Area,Iteration})
    # when -Type is set; finally fall back to Read-AzDevOpsKindPick. Missing-
    # after-pick prints the standard "Set `$env:AZ_* or run az-Sync-AzDevOpsCache"
    # abort. Returns a result object with .Ok / .Iteration / .Area so callers
    # can short-circuit with a single `if (-not $resolved.Ok) { return }`.
    param(
        [string] $Iteration,
        [string] $Area,
        [string] $Type
    )

    if (-not $Iteration -and $Type) {
        if (Get-Command Resolve-AzDevOpsTypeIteration -ErrorAction SilentlyContinue) {
            $Iteration = Resolve-AzDevOpsTypeIteration -Type $Type
        }
    }
    if (-not $Iteration) {
        $Iteration = Read-AzDevOpsKindPick -Kind 'Iteration'
    }
    if (-not $Iteration) {
        Write-Host "Iteration is required - aborting. Set `$env:AZ_ITERATION or run az-Sync-AzDevOpsCache." -ForegroundColor Red
        return [PSCustomObject]@{ Ok = $false; Iteration = $null; Area = $null }
    }

    if (-not $Area -and $Type) {
        if (Get-Command Resolve-AzDevOpsTypeArea -ErrorAction SilentlyContinue) {
            $Area = Resolve-AzDevOpsTypeArea -Type $Type
        }
    }
    if (-not $Area) {
        $Area = Read-AzDevOpsKindPick -Kind 'Area'
    }
    if (-not $Area) {
        Write-Host "Area is required - aborting. Set `$env:AZ_AREA or run az-Sync-AzDevOpsCache." -ForegroundColor Red
        return [PSCustomObject]@{ Ok = $false; Iteration = $null; Area = $null }
    }

    $resolved = [PSCustomObject]@{ Ok = $true; Iteration = $Iteration; Area = $Area }
    return $resolved
}


function Invoke-AzDevOpsCreateAndLink {
    # Wraps the create -> parent-link -> echo URL tail shared by every
    # az-New-AzDevOps* creator: az-New-AzDevOpsUserStory, az-New-AzDevOpsFeature,
    # and the per-iteration body of az-New-AzDevOpsFeatureStories. Returns a
    # result object with .Ok / .Id / .Url so the caller can short-circuit on
    # failure or hand the new id to a follow-up step (browser launch, hand-off
    # prompt, append to a batch summary).
    #
    # ChildLabel / ParentLabel feed the user-facing status lines ("Creating
    # User Story...", "Linking story 5001 to parent Feature 1240..."), so the
    # existing UX is preserved verbatim - the helper only consolidates the
    # control flow.
    param(
        [Parameter(Mandatory)] [string]    $ChildLabel,
        [Parameter(Mandatory)] [string]    $ParentLabel,
        [Parameter(Mandatory)] [hashtable] $CreateArgs,
        [int]    $ParentId = 0,
        [string] $OrphanLabel,
        [switch] $OpenInBrowser
    )

    if (-not $OrphanLabel) {
        $OrphanLabel = $ChildLabel
    }

    Write-Host ""
    Write-Host "Creating $ChildLabel..." -ForegroundColor Cyan
    $createResult = Invoke-AzDevOpsWorkItemCreate @CreateArgs

    if (-not $createResult.Ok) {
        Write-Host "STEP FAILED: az boards work-item create" -ForegroundColor Red
        Write-Host "  $($createResult.Error)" -ForegroundColor Red
        return [PSCustomObject]@{ Ok = $false; Id = 0; Url = $null }
    }

    $newId = $createResult.Id
    $newUrl = $createResult.Url
    Write-Host "OK Created $ChildLabel $newId" -ForegroundColor Green

    if ($ParentId -gt 0) {
        Write-Host "Linking $OrphanLabel $newId to parent $ParentLabel $ParentId..." -ForegroundColor Cyan
        $linkResult = Invoke-AzDevOpsParentLink -Id $newId -ParentId $ParentId
        if (-not $linkResult.Ok) {
            Write-Host "STEP FAILED: az boards work-item relation add ($OrphanLabel $newId is orphaned, fix manually)" -ForegroundColor Red
            Write-Host "  $($linkResult.Error)" -ForegroundColor Red
        }
        else {
            Write-Host "OK Linked $newId -> $ParentLabel $ParentId" -ForegroundColor Green
        }
    }
    else {
        Write-Host "(no parent linked - orphan $OrphanLabel)" -ForegroundColor Yellow
    }

    if ($newUrl) {
        Write-Host "URL: $newUrl" -ForegroundColor Cyan
        if ($OpenInBrowser) {
            Start-Process $newUrl
        }
    }

    $outcome = [PSCustomObject]@{ Ok = $true; Id = $newId; Url = $newUrl }
    return $outcome
}


function az-New-AzDevOpsUserStory {
    [CmdletBinding()]
    param(
        [string] $Title,
        [string] $Description,
        [int]    $Priority = -1,
        [int]    $StoryPoints = -1,
        [string] $AcceptanceCriteria,
        [int]    $FeatureId = -1,
        [string] $Iteration,
        [string] $Area,
        [switch] $NoOpen
    )

    if (-not (Test-AzDevOpsCreateGate -CommandName 'az-New-AzDevOpsUserStory')) {
        return
    }

    $hierarchy = Read-AzDevOpsHierarchyCache
    if ($null -eq $hierarchy) {
        return
    }

    if (-not $Title) {
        $Title = Read-Host 'What is the title of the User Story?'
    }
    if (-not $Title) {
        Write-Host "Title is required - aborting." -ForegroundColor Red
        return
    }

    if (-not $PSBoundParameters.ContainsKey('Description')) {
        $Description = Read-Host 'What is the description?'
    }

    if ($Priority -lt 1 -or $Priority -gt 4) {
        $Priority = Resolve-AzDevOpsTypePriorityOrPrompt -Type 'USER_STORY'
    }

    if ($StoryPoints -lt 0) {
        $StoryPoints = Resolve-AzDevOpsTypeStoryPointsOrPrompt -Type 'USER_STORY'
    }

    if (-not $PSBoundParameters.ContainsKey('AcceptanceCriteria')) {
        $AcceptanceCriteria = Read-AzDevOpsAcceptanceCriteria
    }

    if ($FeatureId -lt 0) {
        $FeatureId = Read-AzDevOpsFeaturePick -Hierarchy $hierarchy -ChildType 'USER_STORY'
    }

    $resolved = Resolve-AzDevOpsIterationArea -Iteration $Iteration -Area $Area -Type 'USER_STORY'
    if (-not $resolved.Ok) {
        return
    }
    $Iteration = $resolved.Iteration
    $Area = $resolved.Area

    $tags = Resolve-AzDevOpsTypeTagsOrEmpty   -Type 'USER_STORY'
    $extraFields = Read-AzDevOpsRequiredFields       -Type 'USER_STORY'

    $createArgs = @{
        Title              = $Title
        Description        = $Description
        Priority           = $Priority
        StoryPoints        = $StoryPoints
        AcceptanceCriteria = $AcceptanceCriteria
        Iteration          = $Iteration
        Area               = $Area
        Tags               = $tags
        ExtraFields        = $extraFields
    }

    $outcome = Invoke-AzDevOpsCreateAndLink `
        -ChildLabel    'User Story' `
        -ParentLabel   'Feature' `
        -OrphanLabel   'story' `
        -CreateArgs    $createArgs `
        -ParentId      $FeatureId `
        -OpenInBrowser:(-not $NoOpen)

    if (-not $outcome.Ok) {
        return
    }

    $newId = $outcome.Id
    return $newId
}


function az-New-AzDevOpsFeature {
    # Interactive Feature creator. Mirrors az-New-AzDevOpsUserStory's UX one
    # tier up the tree: pick a parent Epic from the cached hierarchy, fill
    # title / description / priority / area / iteration / acceptance criteria,
    # create the Feature, link it to the Epic. Story points are intentionally
    # skipped - Features don't carry story points in the default Agile / Scrum
    # templates.
    #
    # Ends with an "Add child stories now?" hand-off via Read-AzDevOpsYesNo;
    # on yes calls az-New-AzDevOpsFeatureStories -ParentId $newFeatureId with
    # the same area / iteration pre-seeded so the user doesn't re-pick them.
    #
    # Returns the new Feature's [int] id.
    [CmdletBinding()]
    param(
        [string] $Title,
        [string] $Description,
        [int]    $Priority = -1,
        [string] $AcceptanceCriteria,
        [int]    $ParentEpicId = -1,
        [string] $Iteration,
        [string] $Area,
        [switch] $NoOpen,
        [switch] $NoChildStoriesPrompt
    )

    if (-not (Test-AzDevOpsCreateGate -CommandName 'az-New-AzDevOpsFeature')) {
        return
    }

    $hierarchy = Read-AzDevOpsHierarchyCache
    if ($null -eq $hierarchy) {
        return
    }

    if (-not $Title) {
        $Title = Read-Host 'What is the title of the Feature?'
    }
    if (-not $Title) {
        Write-Host "Title is required - aborting." -ForegroundColor Red
        return
    }

    if (-not $PSBoundParameters.ContainsKey('Description')) {
        $Description = Read-Host 'What is the description?'
    }

    if ($Priority -lt 1 -or $Priority -gt 4) {
        $Priority = Resolve-AzDevOpsTypePriorityOrPrompt -Type 'FEATURE'
    }

    if (-not $PSBoundParameters.ContainsKey('AcceptanceCriteria')) {
        $AcceptanceCriteria = Read-AzDevOpsAcceptanceCriteria
    }

    if ($ParentEpicId -lt 0) {
        $ParentEpicId = Read-AzDevOpsEpicPick -Hierarchy $hierarchy -ChildType 'FEATURE'
    }

    $resolved = Resolve-AzDevOpsIterationArea -Iteration $Iteration -Area $Area -Type 'FEATURE'
    if (-not $resolved.Ok) {
        return
    }
    $Iteration = $resolved.Iteration
    $Area = $resolved.Area

    $tags = Resolve-AzDevOpsTypeTagsOrEmpty -Type 'FEATURE'
    $extraFields = Read-AzDevOpsRequiredFields     -Type 'FEATURE'

    $createArgs = @{
        Type               = 'Feature'
        Title              = $Title
        Description        = $Description
        Priority           = $Priority
        AcceptanceCriteria = $AcceptanceCriteria
        Iteration          = $Iteration
        Area               = $Area
        Tags               = $tags
        ExtraFields        = $extraFields
    }

    $outcome = Invoke-AzDevOpsCreateAndLink `
        -ChildLabel    'Feature' `
        -ParentLabel   'Epic' `
        -CreateArgs    $createArgs `
        -ParentId      $ParentEpicId `
        -OpenInBrowser:(-not $NoOpen)

    if (-not $outcome.Ok) {
        return
    }

    $newId = $outcome.Id

    if (-not $NoChildStoriesPrompt) {
        Write-Host ""
        if (Read-AzDevOpsYesNo -Prompt 'Add child stories now?') {
            az-New-AzDevOpsFeatureStories `
                -ParentId  $newId `
                -Iteration $Iteration `
                -Area      $Area | Out-Null
        }
    }

    return $newId
}


function Read-AzDevOpsBatchContinue {
    # Three-way batch-loop prompt used by az-New-AzDevOpsFeatureStories at the
    # end of each story. Mirrors Read-AzDevOpsYesNo's style but adds a third
    # 'c' option that flags "re-pick area / iteration before the next story".
    # Returns 'continue' / 'stop' / 'change'.
    $resp = Read-Host '    Add another story? (y/N/c=change area or iteration)'

    if ($resp -match '^(y|yes)$') {
        return 'continue'
    }

    if ($resp -match '^(c|change)$') {
        return 'change'
    }

    return 'stop'
}


function Test-AzDevOpsParentIsFeature {
    # Validates -ParentId resolves to a Feature row in the cached hierarchy
    # before az-New-AzDevOpsFeatureStories enters the loop. Emits a clear
    # Write-Host on either failure mode (id missing entirely, or id present
    # but not a Feature) so the caller can abort with the right hint.
    param(
        [Parameter(Mandatory)] [int] $ParentId,
        [Parameter(Mandatory)] $Hierarchy
    )

    $candidates = @($Hierarchy | Where-Object { $_.Id -eq $ParentId })

    if ($candidates.Count -eq 0) {
        Write-Host "ParentId $ParentId not found in hierarchy.json. Run az-Sync-AzDevOpsCache and retry." -ForegroundColor Red
        return $false
    }

    $found = $candidates[0]
    if ($found.Type -ne 'Feature') {
        Write-Host "ParentId $ParentId is a $($found.Type), not a Feature. Pick a Feature parent." -ForegroundColor Red
        return $false
    }

    return $true
}


function az-New-AzDevOpsFeatureStories {
    # Batch-create child User Stories under an existing Feature. Captures
    # parent / area / iteration ONCE up front; loops per-story prompts for
    # title, AC, priority (Enter to reuse last), story points (same). At the
    # end of each story prompts "Add another story? (y/N/c)" - 'c' re-picks
    # area / iteration without exiting the loop. Empty title at the top of
    # any iteration aborts the batch cleanly.
    #
    # Each child create runs through the same Invoke-AzDevOpsWorkItemCreate
    # + Invoke-AzDevOpsParentLink path the single-shot az-New-AzDevOpsUserStory
    # uses, so failure modes / exit codes / schema enforcement stay identical.
    # A failed create is logged and the loop continues; the user can retry the
    # one that failed via az-New-AzDevOpsUserStory -ParentId $ParentId.
    #
    # Designed to be invoked stand-alone, or chained off the end of
    # az-New-AzDevOpsFeature via its "Add child stories now?" hand-off prompt.
    # Returns [int[]] of successfully-created story ids.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]    $ParentId,
        [string] $Iteration,
        [string] $Area
    )

    [int[]] $createdIds = @()

    if (-not (Test-AzDevOpsCreateGate -CommandName 'az-New-AzDevOpsFeatureStories')) {
        return $createdIds
    }

    $hierarchy = Read-AzDevOpsHierarchyCache
    if ($null -eq $hierarchy) {
        return $createdIds
    }

    if (-not (Test-AzDevOpsParentIsFeature -ParentId $ParentId -Hierarchy $hierarchy)) {
        return $createdIds
    }

    $resolved = Resolve-AzDevOpsIterationArea -Iteration $Iteration -Area $Area -Type 'USER_STORY'
    if (-not $resolved.Ok) {
        return $createdIds
    }
    $Iteration = $resolved.Iteration
    $Area = $resolved.Area

    $tags = Resolve-AzDevOpsTypeTagsOrEmpty -Type 'USER_STORY'

    Write-Host ""
    Write-Host "Batch-creating child User Stories under Feature $ParentId" -ForegroundColor Cyan
    Write-Host "  Area      : $Area"
    Write-Host "  Iteration : $Iteration"
    Write-Host "  (empty title at the next prompt ends the batch cleanly)"

    $failedTitles = @()
    $createdUrls = @()
    $previousPriority = -1
    $previousStoryPoints = -1
    $iterationNumber = 1

    while ($true) {
        Write-Host ""
        Write-Host ("--- Story #{0} ---" -f $iterationNumber) -ForegroundColor Cyan

        $title = Read-Host 'Story title (Enter to finish batch)'
        if (-not $title) {
            break
        }

        $acceptanceCriteria = Read-AzDevOpsAcceptanceCriteria
        $priority = Resolve-AzDevOpsTypePriorityOrPrompt    -Type 'USER_STORY' -Previous $previousPriority
        $storyPoints = Resolve-AzDevOpsTypeStoryPointsOrPrompt -Type 'USER_STORY' -Previous $previousStoryPoints
        $extraFields = Read-AzDevOpsRequiredFields             -Type 'USER_STORY'

        $createArgs = @{
            Title              = $title
            Description        = ''
            Priority           = $priority
            StoryPoints        = $storyPoints
            AcceptanceCriteria = $acceptanceCriteria
            Iteration          = $Iteration
            Area               = $Area
            Tags               = $tags
            ExtraFields        = $extraFields
        }

        $outcome = Invoke-AzDevOpsCreateAndLink `
            -ChildLabel  'User Story' `
            -ParentLabel 'Feature' `
            -OrphanLabel 'story' `
            -CreateArgs  $createArgs `
            -ParentId    $ParentId

        if (-not $outcome.Ok) {
            $failedTitles += $title
        }
        else {
            if ($outcome.Url) {
                $createdUrls += $outcome.Url
            }
            $createdIds += $outcome.Id
            $previousPriority = $priority
            $previousStoryPoints = $storyPoints
        }

        $iterationNumber++

        $next = Read-AzDevOpsBatchContinue
        if ($next -eq 'stop') {
            break
        }

        if ($next -eq 'change') {
            $newIteration = Read-AzDevOpsKindPick -Kind 'Iteration'
            if ($newIteration) {
                $Iteration = $newIteration
            }

            $newArea = Read-AzDevOpsKindPick -Kind 'Area'
            if ($newArea) {
                $Area = $newArea
            }

            Write-Host "  Area      : $Area"
            Write-Host "  Iteration : $Iteration"
        }
    }

    Write-Host ""
    $createdCount = $createdIds.Count
    $failedCount = $failedTitles.Count
    $idsList = if ($createdCount -gt 0) {
        ($createdIds -join ', ')
    }
    else {
        '(none)'
    }

    if ($failedCount -gt 0) {
        Write-Host ("Created {0}, Failed {1} child stories under Feature #{2}: {3}" -f $createdCount, $failedCount, $ParentId, $idsList) -ForegroundColor Yellow
        Write-Host ("Failed titles: {0}" -f ($failedTitles -join ' | ')) -ForegroundColor Yellow
    }
    else {
        Write-Host ("Created {0} child stories under Feature #{1}: {2}" -f $createdCount, $ParentId, $idsList) -ForegroundColor Green
    }

    foreach ($url in $createdUrls) {
        Write-Host "  $url" -ForegroundColor Cyan
    }

    return $createdIds
}


# ---------------------------------------------------------------------------
# Local field-schema config
#
# Schema directory: $HOME/.bashcuts-az-devops-app/schema/   (separate from the
#                   auto-managed cache/ subtree under the same parent)
# Schema file:      schema-<orgslug>.json                   (per-org keyed off
#                   the configured organization URL; falls back to schema.json when unset)
#
# Public functions:
#   az-Get-AzDevOpsSchema          - print summary table of the configured
#                                  required/optional/custom fields per
#                                  work-item type. -PassThru returns objects.
#   az-Edit-AzDevOpsSchema         - open the schema file in $env:EDITOR /
#                                  code / notepad / nano. Creates a stub
#                                  if the file does not exist.
#   az-Initialize-AzDevOpsSchema   - introspect the org via
#                                  `az devops invoke --area wit --resource
#                                  workitemtypes` and write a starter schema.
#                                  User refines afterward via az-Edit-AzDevOpsSchema.
#   az-Test-AzDevOpsSchema         - validate JSON parses, every ref still
#                                  exists in the org, and picklist options
#                                  are a subset of allowedValues. Verdict:
#                                  VALID / STALE / INVALID.
#
# Internal integration point (consumed by future schema-aware updates to
# az-New-AzDevOpsUserStory, az-Get-AzDevOpsAssigned, az-Show-AzDevOpsTree, etc.):
#   Get-AzDevOpsSchemaForType   - returns the parsed schema entry for one
#                                  work-item type, or $null if no schema
#                                  is configured / type not present.
# ---------------------------------------------------------------------------

function Get-AzDevOpsSchemaValidTypes {
    return @('string', 'int', 'picklist', 'bool', 'date', 'multiline')
}


function Get-AzDevOpsSchemaWorkItemTypes {
    # Standard process-template work-item types az-Initialize-AzDevOpsSchema
    # introspects. Types not present in the org's process are skipped with
    # a warning rather than failing the whole introspection.
    return @('Epic', 'Feature', 'User Story', 'Bug', 'Task')
}


function Get-AzDevOpsSchemaSystemRefs {
    # Reference names that ship with every Azure DevOps process template
    # (Agile / Scrum / CMMI). az-Initialize-AzDevOpsSchema filters these out
    # so the produced schema only carries org-specific fields.
    return @(
        'System.Id', 'System.Title', 'System.Description', 'System.State',
        'System.Reason', 'System.AssignedTo', 'System.AreaPath',
        'System.IterationPath', 'System.WorkItemType', 'System.History',
        'System.Tags', 'System.CreatedBy', 'System.CreatedDate',
        'System.ChangedBy', 'System.ChangedDate', 'System.Parent',
        'System.Rev', 'System.AuthorizedDate', 'System.RevisedDate',
        'System.AuthorizedAs', 'System.IterationId', 'System.AreaId',
        'System.NodeName', 'System.TeamProject', 'System.BoardColumn',
        'System.BoardColumnDone', 'System.BoardLane', 'System.CommentCount',
        'System.PersonId', 'System.Watermark',
        'Microsoft.VSTS.Common.Priority',
        'Microsoft.VSTS.Common.AcceptanceCriteria',
        'Microsoft.VSTS.Scheduling.StoryPoints',
        'Microsoft.VSTS.Common.ActivatedBy',
        'Microsoft.VSTS.Common.ActivatedDate',
        'Microsoft.VSTS.Common.ResolvedBy',
        'Microsoft.VSTS.Common.ResolvedDate',
        'Microsoft.VSTS.Common.ResolvedReason',
        'Microsoft.VSTS.Common.ClosedBy',
        'Microsoft.VSTS.Common.ClosedDate',
        'Microsoft.VSTS.Common.StateChangeDate',
        'Microsoft.VSTS.Common.Risk',
        'Microsoft.VSTS.Common.Severity',
        'Microsoft.VSTS.Common.StackRank',
        'Microsoft.VSTS.Common.ValueArea',
        'Microsoft.VSTS.Common.BusinessValue',
        'Microsoft.VSTS.Common.TimeCriticality',
        'Microsoft.VSTS.Scheduling.Effort',
        'Microsoft.VSTS.Scheduling.RemainingWork',
        'Microsoft.VSTS.Scheduling.OriginalEstimate',
        'Microsoft.VSTS.Scheduling.CompletedWork',
        'Microsoft.VSTS.Scheduling.StartDate',
        'Microsoft.VSTS.Scheduling.TargetDate'
    )
}


function Get-AzDevOpsSchemaOrgSlug {
    # Per-org keying: the path-tail segment of the configured organization URL,
    # lowercased and reduced to [a-z0-9-]. Returns $null when org is not
    # configured, so Get-AzDevOpsSchemaPaths falls back to unsuffixed schema.json.
    $defaults = Get-AzDevOpsConfiguredDefaults
    if (-not $defaults.Org) {
        return $null
    }

    $segment = ($defaults.Org.TrimEnd('/') -split '/')[-1]
    if (-not $segment) {
        return $null
    }

    $slug = ($segment.ToLower() -replace '[^a-z0-9-]', '-').Trim('-')
    if (-not $slug) {
        return $null
    }

    return $slug
}


function Get-AzDevOpsSchemaPaths {
    $configDir = Join-Path (Get-AzDevOpsAppRoot) 'schema'
    $slug = Get-AzDevOpsSchemaOrgSlug

    $fileName = if ($slug) {
        "schema-$slug.json"
    }
    else {
        'schema.json'
    }

    return [PSCustomObject]@{
        Dir  = $configDir
        File = Join-Path $configDir $fileName
        Slug = $slug
    }
}


function Initialize-AzDevOpsSchemaDir {
    # Creates $HOME/.bashcuts-az-devops-app/schema with 0700 on Unix. Windows
    # gets default NTFS ACLs inherited from %USERPROFILE%, which are user-only
    # for files created under $HOME.
    $paths = Get-AzDevOpsSchemaPaths

    if (-not (Test-Path -LiteralPath $paths.Dir)) {
        New-Item -ItemType Directory -Path $paths.Dir -Force | Out-Null
    }

    if ((Get-AzDevOpsPlatform) -eq 'Posix') {
        & chmod 700 $paths.Dir 2>$null
    }

    return $paths
}


function Write-AzDevOpsSchemaFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $Schema
    )

    $json = $Schema | ConvertTo-Json -Depth 6
    $tmp = "$Path.tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}


function Read-AzDevOpsSchemaFile {
    # Returns the parsed schema object, or $null when the file is missing
    # or unparseable. Used by az-Get-AzDevOpsSchema, Get-AzDevOpsSchemaForType,
    # and az-Test-AzDevOpsSchema.
    $paths = Get-AzDevOpsSchemaPaths
    if (-not (Test-Path -LiteralPath $paths.File)) {
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $paths.File -Raw
        $schema = $raw | ConvertFrom-Json
        return $schema
    }
    catch {
        Write-Host "Could not parse schema at $($paths.File): $_" -ForegroundColor Red
        return $null
    }
}


function Get-AzDevOpsSchemaForType {
    # Internal integration point for schema-aware consumers (az-New-AzDevOpsUserStory,
    # the read commands, the tree). Returns the parsed { required = ..., optional = ... }
    # entry for one work-item type, or $null when no schema is configured / the
    # type is not present.
    param([Parameter(Mandatory)] [string] $Type)

    $schema = Read-AzDevOpsSchemaFile
    if ($null -eq $schema) {
        return $null
    }

    $prop = $schema.PSObject.Properties[$Type]
    if ($null -eq $prop) {
        return $null
    }

    $entry = $prop.Value
    return $entry
}


function New-AzDevOpsSchemaStub {
    # Empty starter schema used by az-Edit-AzDevOpsSchema when no file exists
    # yet and the user just wants to hand-edit one in. az-Initialize-AzDevOpsSchema
    # produces a richer file by introspecting the org.
    return [ordered]@{
        'User Story' = [ordered]@{
            required = @()
            optional = @()
        }

        'Feature'    = [ordered]@{
            required = @()
            optional = @()
        }

        'Bug'        = [ordered]@{
            required = @()
            optional = @()
        }
    }
}


function ConvertFrom-AzDevOpsSchemaToRows {
    # Flattens the nested schema into one PSCustomObject per field, suitable
    # for a Format-Table summary or PassThru consumption.
    param([Parameter(Mandatory)] $Schema)

    $rows = New-Object System.Collections.Generic.List[PSCustomObject]

    foreach ($prop in $Schema.PSObject.Properties) {
        $wiType = $prop.Name
        $entry = $prop.Value

        foreach ($section in @('required', 'optional')) {
            $sectionList = $entry.$section
            if (-not $sectionList) { continue }

            foreach ($f in $sectionList) {
                $optionsText = if ($f.type -eq 'picklist' -and $f.options) {
                    ($f.options -join ', ')
                }
                else {
                    ''
                }

                $row = [PSCustomObject]@{
                    WorkItemType = $wiType
                    Field        = $f.name
                    Ref          = $f.ref
                    Required     = ($section -eq 'required')
                    FieldType    = $f.type
                    Options      = $optionsText
                }
                $rows.Add($row)
            }
        }
    }

    $result = , @($rows)
    return $result
}


function az-Get-AzDevOpsSchema {
    [CmdletBinding()]
    param([switch] $PassThru)

    $schema = Read-AzDevOpsSchemaFile
    if ($null -eq $schema) {
        $paths = Get-AzDevOpsSchemaPaths
        Write-Host "No schema configured at $($paths.File)." -ForegroundColor Yellow
        Write-Host "  Run: az-Initialize-AzDevOpsSchema   # populate from your org's work-item types" -ForegroundColor Yellow
        Write-Host "  Or:  az-Edit-AzDevOpsSchema         # create + hand-edit a stub" -ForegroundColor Yellow
        return
    }

    $rows = ConvertFrom-AzDevOpsSchemaToRows -Schema $schema

    if ($PassThru) {
        return $rows
    }

    Show-AzDevOpsRows -Rows $rows -Title "Azure DevOps schema - $(@($rows).Count) fields"
}


function Resolve-AzDevOpsEditor {
    # Editor fallback chain: $env:EDITOR -> `code` (when on PATH) -> notepad
    # on Windows, nano on macOS / Linux. Honors EDITOR strings that include
    # arguments (e.g. 'code --wait').
    if ($env:EDITOR) {
        return $env:EDITOR
    }

    if (Get-Command code -ErrorAction SilentlyContinue) {
        return 'code'
    }

    if ((Get-AzDevOpsPlatform) -eq 'Windows') {
        return 'notepad'
    }

    return 'nano'
}


function az-Edit-AzDevOpsSchema {
    [CmdletBinding()]
    param()

    $paths = Initialize-AzDevOpsSchemaDir

    if (-not (Test-Path -LiteralPath $paths.File)) {
        $stub = New-AzDevOpsSchemaStub
        Write-AzDevOpsSchemaFile -Path $paths.File -Schema $stub
        Write-Host "Created stub schema at $($paths.File)." -ForegroundColor Cyan
        Write-Host "  Edit and run az-Test-AzDevOpsSchema to validate against your org." -ForegroundColor Cyan
    }

    $editor = Resolve-AzDevOpsEditor
    $editorTokens = @($editor -split '\s+' | Where-Object { $_ })

    if ($editorTokens.Count -eq 0) {
        Write-Host "No editor resolved (EDITOR / code / notepad / nano all unavailable)." -ForegroundColor Red
        return
    }

    $cmd = $editorTokens[0]

    $extraArgs = if ($editorTokens.Count -gt 1) {
        $editorTokens[1..($editorTokens.Count - 1)]
    }
    else {
        @()
    }

    Write-Host "Opening $($paths.File) in '$editor'..." -ForegroundColor Cyan
    & $cmd @extraArgs $paths.File
}


function Invoke-AzDevOpsWorkItemTypeShow {
    # Wraps `az devops invoke --area wit --resource workitemtypes` for one
    # type. Returns Ok / Error / Type so callers can react to a missing type
    # (org's process doesn't have one of the standards) without taking down
    # the whole flow.
    param([Parameter(Mandatory)] [string] $Type)

    $result = Get-AzDevOpsWorkItemTypeDefinition -Type $Type
    if ($result.ExitCode -ne 0) {
        return [PSCustomObject]@{ Ok = $false; Error = $result.Error; Type = $null }
    }

    try {
        # -AsHashtable because the workitemtypes REST payload contains
        # properties with empty-string names (typically in _links / extension
        # blocks); PS 7's default ConvertFrom-Json refuses those with
        # "provided JSON includes a property whose name is an empty string".
        $parsed = $result.Json | ConvertFrom-Json -AsHashtable
        return [PSCustomObject]@{ Ok = $true; Error = $null; Type = $parsed }
    }
    catch {
        $msg = "parse failed: $($_.Exception.Message)"
        return [PSCustomObject]@{ Ok = $false; Error = $msg; Type = $null }
    }
}


function ConvertTo-AzDevOpsSchemaFieldEntry {
    # Maps one fieldInstances[] element to our { name, ref, type, options? }
    # shape. Type defaults to 'string' since the workitemtypes REST response
    # doesn't surface the underlying field type; presence of allowedValues
    # promotes it to 'picklist'. Users refine via az-Edit-AzDevOpsSchema.
    param([Parameter(Mandatory)] $FieldInstance)

    $name = $FieldInstance.field.name
    $ref = $FieldInstance.field.referenceName

    $allowed = @()
    if ($FieldInstance.allowedValues) {
        $allowed = @($FieldInstance.allowedValues)
    }

    $type = if ($allowed.Count -gt 0) {
        'picklist'
    }
    else {
        'string'
    }

    $entry = [ordered]@{
        name = $name
        ref  = $ref
        type = $type
    }

    if ($type -eq 'picklist') {
        $entry.options = $allowed
    }

    return $entry
}


function az-Initialize-AzDevOpsSchema {
    [CmdletBinding()]
    param()

    if (-not (Assert-AzDevOpsAuthOrAbort -CommandName 'az-Initialize-AzDevOpsSchema')) {
        return
    }

    $paths = Initialize-AzDevOpsSchemaDir
    $knownRefs = Get-AzDevOpsSchemaSystemRefs
    $wiTypes = Get-AzDevOpsSchemaWorkItemTypes

    $schema = [ordered]@{}

    foreach ($wiType in $wiTypes) {
        Write-Host "-> Introspecting '$wiType'..." -ForegroundColor Cyan

        $showResult = Invoke-AzDevOpsWorkItemTypeShow -Type $wiType
        if (-not $showResult.Ok) {
            $firstLine = Get-AzDevOpsFirstStderrLine -Stderr $showResult.Error
            if (-not $firstLine) { $firstLine = '(unknown az error)' }
            Write-Host "  ! skipped '$wiType': $firstLine" -ForegroundColor Yellow
            continue
        }

        $required = @()
        $optional = @()

        $fieldInstances = @($showResult.Type.fieldInstances)
        foreach ($fi in $fieldInstances) {
            if (-not $fi.field) { continue }
            if ($fi.field.referenceName -in $knownRefs) { continue }

            $entry = ConvertTo-AzDevOpsSchemaFieldEntry -FieldInstance $fi

            if ($fi.alwaysRequired) {
                $required += $entry
            }
            else {
                $optional += $entry
            }
        }

        $schema[$wiType] = [ordered]@{
            required = $required
            optional = $optional
        }

        Write-Host "  OK  '$wiType' - $($required.Count) required, $($optional.Count) optional custom field(s)" -ForegroundColor Green
    }

    Write-AzDevOpsSchemaFile -Path $paths.File -Schema $schema

    Write-Host ""
    Write-Host "Wrote $($paths.File)" -ForegroundColor Cyan
    Write-Host "Refine field types and picklist options via az-Edit-AzDevOpsSchema, then run az-Test-AzDevOpsSchema." -ForegroundColor Cyan
}


function az-Test-AzDevOpsSchema {
    [CmdletBinding()]
    param()

    $paths = Get-AzDevOpsSchemaPaths
    if (-not (Test-Path -LiteralPath $paths.File)) {
        Write-Host "No schema configured at $($paths.File). Run az-Initialize-AzDevOpsSchema." -ForegroundColor Yellow
        return
    }

    $schema = Read-AzDevOpsSchemaFile
    if ($null -eq $schema) {
        Write-Host "INVALID - schema could not be loaded (see message above)" -ForegroundColor Red
        return
    }

    if (-not (Assert-AzDevOpsAuthOrAbort -CommandName 'az-Test-AzDevOpsSchema')) {
        return
    }

    $validTypes = Get-AzDevOpsSchemaValidTypes
    $unknownRefs = New-Object System.Collections.Generic.List[string]
    $picklistMismatches = New-Object System.Collections.Generic.List[string]
    $unknownTypes = New-Object System.Collections.Generic.List[string]

    foreach ($wiTypeProp in $schema.PSObject.Properties) {
        $wiType = $wiTypeProp.Name
        $entry = $wiTypeProp.Value

        $showResult = Invoke-AzDevOpsWorkItemTypeShow -Type $wiType
        if (-not $showResult.Ok) {
            Write-Host "  ! could not introspect '$wiType' - skipping ref check" -ForegroundColor Yellow
            continue
        }

        $orgFields = @{}
        foreach ($fi in @($showResult.Type.fieldInstances)) {
            if ($fi.field -and $fi.field.referenceName) {
                $orgFields[$fi.field.referenceName] = $fi
            }
        }

        foreach ($section in @('required', 'optional')) {
            $sectionList = $entry.$section
            if (-not $sectionList) { continue }

            foreach ($f in $sectionList) {
                if ($f.type -and ($f.type -notin $validTypes)) {
                    $unknownTypes.Add("$wiType.$($f.ref) (type='$($f.type)')")
                }

                if (-not $orgFields.ContainsKey($f.ref)) {
                    $unknownRefs.Add("$wiType.$($f.ref)")
                    continue
                }

                if ($f.type -eq 'picklist' -and $f.options) {
                    $allowed = @($orgFields[$f.ref].allowedValues)
                    foreach ($opt in $f.options) {
                        if ($opt -notin $allowed) {
                            $picklistMismatches.Add("$wiType.$($f.ref) option '$opt' not in org allowedValues")
                        }
                    }
                }
            }
        }
    }

    if ($unknownTypes.Count -gt 0) {
        Write-Host "  ! Unknown field types (treated as 'string'):" -ForegroundColor Yellow
        foreach ($t in $unknownTypes) {
            Write-Host "    - $t"
        }
    }

    if ($unknownRefs.Count -eq 0 -and $picklistMismatches.Count -eq 0) {
        Write-Host "VALID - schema parses, all refs exist, picklist options check out" -ForegroundColor Green
        return
    }

    if ($picklistMismatches.Count -eq 0) {
        Write-Host "STALE - unknown refs in $($paths.File):" -ForegroundColor Yellow
        foreach ($r in $unknownRefs) {
            Write-Host "  - $r"
        }
        return
    }

    Write-Host "INVALID - schema does not match org:" -ForegroundColor Red
    if ($unknownRefs.Count -gt 0) {
        Write-Host "  Unknown refs:"
        foreach ($r in $unknownRefs) {
            Write-Host "    - $r"
        }
    }
    if ($picklistMismatches.Count -gt 0) {
        Write-Host "  Picklist option mismatches:"
        foreach ($m in $picklistMismatches) {
            Write-Host "    - $m"
        }
    }
}


# ---------------------------------------------------------------------------
# az-Open-AzDevOps* family - direct openers for every folder and file under
# $HOME/.bashcuts-az-devops-app/. Every public function below resolves its
# path through the existing Get-AzDevOps* helpers so cache openers auto-follow
# the active project slice set by az-Use-AzDevOpsProject, and the schema
# opener auto-follows the per-org $env:AZ_DEVOPS_ORG slug.
#
# Discovery: tab-tab on `az-Open-AzDevOps` in any pwsh session.
# ---------------------------------------------------------------------------

function Open-AzDevOpsPathIfExists {
    # Private helper used by every public az-Open-AzDevOps* function in this
    # section. Centralizes the "exists? -> Start-Process, missing? -> yellow
    # hint + return" branch so the 15 public openers stay one-liners. Uses an
    # unapproved verb on purpose - it isn't user-facing, so it doesn't need to
    # pass Get-Verb.
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $HintMessage
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "Not found: $Path" -ForegroundColor Yellow
        Write-Host "  $HintMessage" -ForegroundColor Yellow
        return
    }

    Write-Host "Opening $Path" -ForegroundColor DarkGray
    Start-Process $Path
}


# --- Folder openers (4) ----------------------------------------------------

function az-Open-AzDevOpsAppRoot {
    $root = Get-AzDevOpsAppRoot
    Open-AzDevOpsPathIfExists -Path $root `
        -HintMessage "Run az-Connect-AzDevOps to scaffold the app root."
}


function az-Open-AzDevOpsCacheDir {
    $paths = Get-AzDevOpsCachePaths
    Open-AzDevOpsPathIfExists -Path $paths.Dir `
        -HintMessage "Run az-Sync-AzDevOpsCache to populate the active project's cache slice."
}


function az-Open-AzDevOpsConfigDir {
    $paths = Get-AzDevOpsConfigPaths
    Open-AzDevOpsPathIfExists -Path $paths.QueriesDir `
        -HintMessage "Run az-Connect-AzDevOps (or az-Open-AzDevOpsHierarchyWiqls) to seed the default WIQL files."
}


function az-Open-AzDevOpsSchemaDir {
    $paths = Get-AzDevOpsSchemaPaths
    Open-AzDevOpsPathIfExists -Path $paths.Dir `
        -HintMessage "Run az-Initialize-AzDevOpsSchema (or az-Edit-AzDevOpsSchema) to create the schema directory."
}


# --- Cache file openers (7) ------------------------------------------------

function az-Open-AzDevOpsAssignedCache {
    $paths = Get-AzDevOpsCachePaths
    Open-AzDevOpsPathIfExists -Path $paths.Assigned `
        -HintMessage "Run az-Sync-AzDevOpsCache to populate assigned.json."
}


function az-Open-AzDevOpsMentionsCache {
    $paths = Get-AzDevOpsCachePaths
    Open-AzDevOpsPathIfExists -Path $paths.Mentions `
        -HintMessage "Run az-Sync-AzDevOpsCache to populate mentions.json."
}


function az-Open-AzDevOpsHierarchyCache {
    $paths = Get-AzDevOpsCachePaths
    Open-AzDevOpsPathIfExists -Path $paths.Hierarchy `
        -HintMessage "Run az-Sync-AzDevOpsCache to populate hierarchy.json."
}


function az-Open-AzDevOpsIterationsCache {
    $paths = Get-AzDevOpsCachePaths
    Open-AzDevOpsPathIfExists -Path $paths.Iterations `
        -HintMessage "Run az-Sync-AzDevOpsCache to populate iterations.json."
}


function az-Open-AzDevOpsAreasCache {
    $paths = Get-AzDevOpsCachePaths
    Open-AzDevOpsPathIfExists -Path $paths.Areas `
        -HintMessage "Run az-Sync-AzDevOpsCache to populate areas.json."
}


function az-Open-AzDevOpsLastSync {
    $paths = Get-AzDevOpsCachePaths
    Open-AzDevOpsPathIfExists -Path $paths.LastSync `
        -HintMessage "Run az-Sync-AzDevOpsCache to write the first last-sync.json."
}


function az-Open-AzDevOpsSyncLog {
    $paths = Get-AzDevOpsCachePaths
    Open-AzDevOpsPathIfExists -Path $paths.Log `
        -HintMessage "Run az-Sync-AzDevOpsCache - the log is appended only when a sync runs."
}


# --- Config file openers (3) -----------------------------------------------

function az-Open-AzDevOpsEpicsWiql {
    $paths = Get-AzDevOpsConfigPaths
    Open-AzDevOpsPathIfExists -Path $paths.EpicsQuery `
        -HintMessage "Run az-Open-AzDevOpsHierarchyWiqls (or az-Connect-AzDevOps) to seed epics.wiql with the default."
}


function az-Open-AzDevOpsFeaturesWiql {
    $paths = Get-AzDevOpsConfigPaths
    Open-AzDevOpsPathIfExists -Path $paths.FeaturesQuery `
        -HintMessage "Run az-Open-AzDevOpsHierarchyWiqls (or az-Connect-AzDevOps) to seed features.wiql with the default."
}


function az-Open-AzDevOpsUserStoriesWiql {
    $paths = Get-AzDevOpsConfigPaths
    Open-AzDevOpsPathIfExists -Path $paths.UserStoriesQuery `
        -HintMessage "Run az-Open-AzDevOpsHierarchyWiqls (or az-Connect-AzDevOps) to seed user-stories.wiql with the default."
}


# --- Schema file opener (1) ------------------------------------------------

function az-Open-AzDevOpsSchema {
    $paths = Get-AzDevOpsSchemaPaths
    Open-AzDevOpsPathIfExists -Path $paths.File `
        -HintMessage "Run az-Initialize-AzDevOpsSchema to introspect your org, or az-Edit-AzDevOpsSchema to scaffold a stub."
}
