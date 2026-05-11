# ============================================================================
# Azure DevOps Work-Item Shortcuts
# ============================================================================
#
# Foundation file for Azure DevOps work-item navigation shortcuts.
#
# User-facing functions:
#   az-Connect-AzDevOps   - interactive first-run auth + setup helper (run once
#                        on a fresh machine, or any time auth feels stale)
#   az-Test-AzDevOpsAuth  - silent yes/no auth assertion intended for callers
#                        in later AzDevOps commands; returns $true / $false
#
# Step functions invoked by az-Connect-AzDevOps (also exposed for direct use,
# e.g. to debug a single failing step). Each returns a [PSCustomObject]
# with Ok (bool) and FailMessage (string or $null) properties, and prints
# its own status:
#   az-Confirm-AzDevOpsCli              - step 1 (CLI on PATH + version echo)
#   az-Confirm-AzDevOpsExtension        - step 2 (azure-devops extension; offers install)
#   az-Confirm-AzDevOpsEnvVars          - step 3 (required $profile env vars set)
#   az-Confirm-AzDevOpsProjectMap       - step 4 ($global:AzDevOpsProjectMap;
#                                              opt-in, no-op when unset)
#   az-Confirm-AzDevOpsLogin            - step 5 (az login session; offers login)
#   az-Set-AzDevOpsDefaults             - step 6 (az devops configure --defaults)
#   az-Confirm-AzDevOpsSmokeQuery       - step 7 (az boards query smoke test)
#
# Silent diagnostic helpers (pure checks, no I/O — used by az-Test-AzDevOpsAuth):
#   Test-AzDevOpsCliPresent          - is the `az` CLI on PATH?
#   Test-AzDevOpsExtensionInstalled  - is the `azure-devops` extension installed?
#   Get-AzDevOpsMissingEnvVars       - returns array of required env vars not set
#   Test-AzDevOpsLoggedIn            - does `az account show` succeed?
#   Invoke-AzDevOpsSmokeQuery        - runs WIQL "items assigned to me",
#                                       returns count or $null on failure
#
# Expected $profile environment variables (set these once in your $profile):
#
#   $env:AZ_DEVOPS_ORG = 'https://dev.azure.com/myorg'   # full org URL
#   $env:AZ_PROJECT    = 'My Project'                    # project name
#   $env:AZ_USER_EMAIL = 'user@example.com'              # your AAD email
#   $env:AZ_AREA       = 'My Project\My Team'            # default area path
#   $env:AZ_ITERATION  = 'My Project\Sprint 42'          # default iteration
#
# Prereqs:
#   - Azure CLI        : https://aka.ms/installazurecli
#   - azure-devops ext : az extension add --name azure-devops
#
# First-run:
#   PS> az-Connect-AzDevOps
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


function Get-AzDevOpsMissingEnvVars {
    $missing = @()
    if (-not $env:AZ_DEVOPS_ORG) { $missing += 'AZ_DEVOPS_ORG' }
    if (-not $env:AZ_PROJECT)    { $missing += 'AZ_PROJECT' }
    return ,$missing
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
    } catch {
        return $null
    }
}


function az-Test-AzDevOpsAuth {
    if (-not (Test-AzDevOpsCliPresent))                { return $false }
    if ((Get-AzDevOpsMissingEnvVars).Count -gt 0)      { return $false }
    if ($null -eq (Invoke-AzDevOpsSmokeQuery))         { return $false }
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
        } elseif ($IsMacOS) {
            Write-Host "    Install via: brew install azure-cli"
            Write-Host "    Or see: https://aka.ms/installazurecli-mac"
        } else {
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
    $missing = Get-AzDevOpsMissingEnvVars
    if ($missing.Count -gt 0) {
        Write-Host "  X Missing env vars: $($missing -join ', ')" -ForegroundColor Red
        Write-Host ""
        Write-Host "    Add this block to your `$profile and reload (open a new terminal):" -ForegroundColor Yellow
        Write-Host "    ---------------------------------------------------------------"
        Write-Host "    `$env:AZ_DEVOPS_ORG = 'https://dev.azure.com/myorg'"
        Write-Host "    `$env:AZ_PROJECT    = 'My Project'"
        Write-Host "    `$env:AZ_USER_EMAIL = 'user@example.com'"
        Write-Host "    `$env:AZ_AREA       = 'My Project\My Team'"
        Write-Host "    `$env:AZ_ITERATION  = 'My Project\Sprint 42'"
        Write-Host "    ---------------------------------------------------------------"
        Write-Host "    See README section 'Azure DevOps work-item shortcuts' for details."
        return New-AzDevOpsStepResult -Ok $false -FailMessage 'env vars missing'
    }
    Write-Host "  OK  AZ_DEVOPS_ORG = $env:AZ_DEVOPS_ORG" -ForegroundColor Green
    Write-Host "  OK  AZ_PROJECT    = $env:AZ_PROJECT" -ForegroundColor Green
    return New-AzDevOpsStepResult -Ok $true
}


function az-Confirm-AzDevOpsProjectMap {
    # Project-map step in the az-Connect-AzDevOps orchestrator. The map is
    # opt-in, so the default verdict when no map is defined is Ok=$true with
    # an informational status line.
    #
    # When the map is defined:
    #   - $global:AzDevOpsActiveProject set + active entry has Org + Project
    #     non-empty: Ok=$true
    #   - $global:AzDevOpsDefaultProject set but ActiveProject unset: hydrate
    #     via az-Use-AzDevOpsProject -Quiet, then verify Org + Project keys
    #   - Map defined but neither default nor active set: prompt the user to
    #     pick one (numbered menu) and call az-Use-AzDevOpsProject -Quiet on
    #     the choice
    #   - Map defined but the active project entry is missing Org or Project:
    #     Ok=$false with a clear FailMessage
    if (-not $global:AzDevOpsProjectMap) {
        Write-Host "  -  No `$global:AzDevOpsProjectMap defined (single-project mode)" -ForegroundColor DarkGray
        return New-AzDevOpsStepResult -Ok $true
    }

    if (-not $global:AzDevOpsActiveProject -and $global:AzDevOpsDefaultProject) {
        if ($global:AzDevOpsProjectMap.ContainsKey($global:AzDevOpsDefaultProject)) {
            az-Use-AzDevOpsProject -Name $global:AzDevOpsDefaultProject -Quiet
        }
    }

    if (-not $global:AzDevOpsActiveProject) {
        $names = az-Get-AzDevOpsProjects
        if (-not $names -or $names.Count -eq 0) {
            return New-AzDevOpsStepResult -Ok $false -FailMessage '$global:AzDevOpsProjectMap is empty'
        }

        Write-Host '  ?  No active Azure DevOps project. Pick one:' -ForegroundColor Yellow
        for ($i = 0; $i -lt $names.Count; $i++) {
            Write-Host ("    {0}. {1}" -f ($i + 1), $names[$i])
        }

        $idx = 0
        while ($true) {
            $resp = Read-Host "    Pick 1..$($names.Count)"
            if ([int]::TryParse($resp, [ref]$idx) -and $idx -ge 1 -and $idx -le $names.Count) {
                break
            }
            Write-Host "    Please enter a number between 1 and $($names.Count)." -ForegroundColor Yellow
        }

        az-Use-AzDevOpsProject -Name $names[$idx - 1] -Quiet
    }

    $active = Get-AzDevOpsActiveProject
    if ($null -eq $active) {
        return New-AzDevOpsStepResult -Ok $false -FailMessage "active project '$global:AzDevOpsActiveProject' not found in map"
    }
    if (-not $active.Org) {
        return New-AzDevOpsStepResult -Ok $false -FailMessage "active project '$global:AzDevOpsActiveProject' is missing required key 'Org'"
    }
    if (-not $active.Project) {
        return New-AzDevOpsStepResult -Ok $false -FailMessage "active project '$global:AzDevOpsActiveProject' is missing required key 'Project'"
    }

    Write-Host "  OK  Active project: $global:AzDevOpsActiveProject (org=$($active.Org) project=$($active.Project))" -ForegroundColor Green
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
    $configOutput = az devops configure --defaults "organization=$env:AZ_DEVOPS_ORG" "project=$env:AZ_PROJECT" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  X az devops configure failed" -ForegroundColor Red
        Write-Host "    $configOutput"
        return New-AzDevOpsStepResult -Ok $false -FailMessage 'configure failed'
    }
    Write-Host "  OK  Defaults set: org=$env:AZ_DEVOPS_ORG project=$env:AZ_PROJECT" -ForegroundColor Green
    return New-AzDevOpsStepResult -Ok $true
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
        @{ Num = 1; Name = 'Azure CLI';                     Action = { az-Confirm-AzDevOpsCli } },
        @{ Num = 2; Name = 'azure-devops extension';        Action = { az-Confirm-AzDevOpsExtension } },
        @{ Num = 3; Name = 'Profile environment variables'; Action = { az-Confirm-AzDevOpsEnvVars } },
        @{ Num = 4; Name = 'Azure DevOps project map';      Action = { az-Confirm-AzDevOpsProjectMap } },
        @{ Num = 5; Name = 'Azure login session';           Action = { az-Confirm-AzDevOpsLogin } },
        @{ Num = 6; Name = 'Configure az devops defaults';  Action = { az-Set-AzDevOpsDefaults } },
        @{ Num = 7; Name = 'Smoke test (az boards query)';  Action = { az-Confirm-AzDevOpsSmokeQuery } }
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
    Write-Host "READY - Azure DevOps connection verified for project=$env:AZ_PROJECT in org=$env:AZ_DEVOPS_ORG" -ForegroundColor Green
}


# ---------------------------------------------------------------------------
# Local cache + scheduled refresh
#
# Cache directory: $HOME/.bashcuts-cache/azure-devops/
#   assigned.json   - items where [System.AssignedTo] = @Me
#   mentions.json   - items where the user's email (or '@') appears in
#                     [System.History] (best-effort - WIQL has no first-class
#                     "@-mention" predicate)
#   hierarchy.json  - WorkItemLinks tree of Epic/Feature/User Story rows
#                     in $env:AZ_PROJECT (parent->child Hierarchy-Forward)
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
    # When $global:AzDevOpsProjectMap is in play, the cache splits into
    # per-project subdirs under ~/.bashcuts-cache/azure-devops/<slug>/ so
    # switching projects loads the right assigned/mentions/hierarchy set.
    # Get-AzDevOpsProjectCacheSlug returns '' for single-project users so
    # the legacy path stays put.
    $base = Join-Path (Join-Path $HOME '.bashcuts-cache') 'azure-devops'

    $slug = if (Get-Command Get-AzDevOpsProjectCacheSlug -ErrorAction SilentlyContinue) {
        Get-AzDevOpsProjectCacheSlug
    } else {
        ''
    }

    $cacheDir = if ($slug) {
        Join-Path $base $slug
    } else {
        $base
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


function Initialize-AzDevOpsCacheDir {
    $paths = Get-AzDevOpsCachePaths
    if (-not (Test-Path -LiteralPath $paths.Dir)) {
        New-Item -ItemType Directory -Path $paths.Dir -Force | Out-Null
    }
    return $paths
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

    # Mentions: WIQL has no first-class @-mention predicate. Best effort is
    # [System.History] Contains 'literal'. Prefer "@<user-email>" when set,
    # otherwise fall back to a bare "@" - the latter is noisy but at least
    # populates the cache shape so downstream commands keep working.
    $mentionsToken = if ($env:AZ_USER_EMAIL) { "@$env:AZ_USER_EMAIL" } else { '@' }

    $assignedWiql  = 'Select [System.Id], [System.Title], [System.WorkItemType], [System.State], [System.IterationPath], [System.ChangedDate] From WorkItems Where [System.AssignedTo] = @Me'
    $mentionsWiql  = "Select [System.Id], [System.Title], [System.WorkItemType], [System.State], [System.ChangedBy], [System.ChangedDate] From WorkItems Where [System.History] Contains '$mentionsToken'"
    # Flat work-items query (not link-mode): az boards query resolves
    # System.Parent + the rest of the fields for each item in one shot,
    # giving az-Show-AzDevOpsTree everything it needs without re-calling az.
    # IN GROUP queries by work-item-type *category* so this works on every
    # process template - 'User Story' only exists in Agile; Scrum uses
    # 'Product Backlog Item', CMMI uses 'Requirement', Basic uses 'Issue'.
    # Project scope is supplied by --project on the az invocation
    # (Invoke-AzDevOpsAzJson injects it from $env:AZ_PROJECT), so the WIQL
    # itself no longer needs a [System.TeamProject] = @Project clause.
    # [System.AreaPath] is included so the Phase B parent picker can filter
    # candidates against $global:AzDevOpsProjectMap..Types..ParentScope.AreaPaths.
    # Older caches written without AreaPath stay valid - the filter is a
    # silent no-op when the field is missing on a row.
    $hierarchyWiql = "Select [System.Id], [System.Title], [System.WorkItemType], [System.State], [System.IterationPath], [System.AreaPath], [System.Parent] From WorkItems Where [System.WorkItemType] IN GROUP 'Microsoft.EpicCategory' OR [System.WorkItemType] IN GROUP 'Microsoft.FeatureCategory' OR [System.WorkItemType] IN GROUP 'Microsoft.RequirementCategory'"

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
        },
        @{
            Name     = 'mentions'
            Label    = "System.History Contains '$mentionsToken'"
            Path     = $Paths.Mentions
            Fetch    = { Invoke-AzDevOpsBoardsQuery -Wiql $mentionsWiql }.GetNewClosure()
            Counter  = $rowCounter
            RowLabel = 'rows'
        },
        @{
            Name     = 'hierarchy'
            Label    = 'Epic/Feature/Requirement-tier hierarchy'
            Path     = $Paths.Hierarchy
            Fetch    = { Invoke-AzDevOpsBoardsQuery -Wiql $hierarchyWiql }.GetNewClosure()
            Counter  = $rowCounter
            RowLabel = 'rows'
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
    param(
        [Parameter(Mandatory)] [string]      $Name,
        [Parameter(Mandatory)] [string]      $Label,
        [Parameter(Mandatory)] [string]      $Path,
        [Parameter(Mandatory)] [scriptblock] $Fetch,
        [scriptblock] $Counter   = { param($parsed) @($parsed).Count },
        [string]      $RowLabel  = 'rows',
        [int]         $JsonDepth = 10
    )

    Write-Host "-> Querying $Name ($Label)..." -ForegroundColor Cyan

    $sw      = [System.Diagnostics.Stopwatch]::StartNew()
    $result  = & $Fetch
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
    } catch {
        $msg = $_.Exception.Message
        Write-Host "  X $Name - parse failed: $msg (in $elapsed)" -ForegroundColor Red
        Write-AzDevOpsSyncLog "ERROR $Name parse failed (elapsed=$elapsed): $msg"
        $parseErrStatus = New-AzDevOpsDatasetStatus -Status 'error' -Message "parse failed: $msg" -Elapsed $elapsed
        return $parseErrStatus
    }

    $count  = & $Counter $parsed
    $pretty = $parsed | ConvertTo-Json -Depth $JsonDepth
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

    $counts   = [ordered]@{}
    $statuses = [ordered]@{}
    $errored  = 0

    foreach ($ds in $datasets) {
        $status = Invoke-AzDevOpsAzDataset @ds
        $statuses[$ds.Name] = $status

        if ($status.Status -eq 'ok') {
            $counts[$ds.Name] = $status.Rows
        } else {
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

    $info     = Get-Content -LiteralPath $paths.LastSync -Raw | ConvertFrom-Json
    $synced   = [datetime]$info.Timestamp
    $age      = (Get-Date) - $synced

    $ageText  = if ($age.TotalMinutes -lt 60) {
        "$([int]$age.TotalMinutes) min ago"
    } elseif ($age.TotalHours -lt 24) {
        "$([math]::Round($age.TotalHours, 1)) hours ago"
    } else {
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

    $countsObj   = $CacheAge.Counts
    $datasetsObj = $CacheAge.Datasets

    $countNames = if ($countsObj) {
        @($countsObj.PSObject.Properties.Name)
    } else {
        @()
    }

    $datasetNames = if ($datasetsObj) {
        @($datasetsObj.PSObject.Properties.Name)
    } else {
        @()
    }

    $allNames = @($countNames + $datasetNames | Select-Object -Unique | Sort-Object)

    foreach ($name in $allNames) {
        $count = if ($countsObj -and $countsObj.PSObject.Properties[$name]) {
            $countsObj.$name
        } else {
            $null
        }

        $datasetEntry = if ($datasetsObj -and $datasetsObj.PSObject.Properties[$name]) {
            $datasetsObj.$name
        } else {
            $null
        }

        $status = if ($datasetEntry -and $datasetEntry.Status) {
            $datasetEntry.Status
        } else {
            'ok'
        }

        $errorText = if ($datasetEntry -and $datasetEntry.Error) {
            Get-AzDevOpsFirstStderrLine -Stderr $datasetEntry.Error
        } else {
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

    $result = ,@($rows)
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
    } else {
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
    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) { return 'Windows' }
    if ($IsMacOS -or $IsLinux)                     { return 'Posix' }
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
    $tag   = Get-AzDevOpsCronTag
    $hours = Get-AzDevOpsSyncIntervalHours
    return "0 */$hours * * * $PwshPath -Command `"az-Sync-AzDevOpsCache`" $tag"
}


function Get-AzDevOpsCrontabSplit {
    # Reads the current crontab and partitions it into bashcuts-tagged lines
    # vs everything else. Returns the non-bashcuts lines plus a HadBashcuts
    # flag so Unregister doesn't have to re-grep to know whether it changed
    # anything. crontab returning no output / nonzero is normalized to empty.
    $tag         = Get-AzDevOpsCronTag
    $existingRaw = crontab -l 2>$null

    if (-not $existingRaw) {
        return [PSCustomObject]@{ Other = @(); HadBashcuts = $false }
    }

    $allLines    = @($existingRaw -split "`n" | Where-Object { $_ })
    $otherLines  = @($allLines | Where-Object { $_ -notmatch [regex]::Escape($tag) })
    $hadBashcuts = ($otherLines.Count -lt $allLines.Count)

    return [PSCustomObject]@{ Other = $otherLines; HadBashcuts = $hadBashcuts }
}


function az-Register-AzDevOpsSyncSchedule {
    $platform = Get-AzDevOpsPlatform
    # Loads the user's $profile so $env:AZ_* and the dot-sourced module are
    # available; without -NoProfile, the scheduled invocation has the same
    # context as an interactive shell.
    $pwshPath = (Get-Process -Id $PID).Path
    $hours    = Get-AzDevOpsSyncIntervalHours

    if ($platform -eq 'Windows') {
        $taskName = Get-AzDevOpsScheduledTaskName
        $action   = New-ScheduledTaskAction -Execute $pwshPath -Argument "-Command `"az-Sync-AzDevOpsCache`""
        $trigger  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) `
                        -RepetitionInterval (New-TimeSpan -Hours $hours)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Force | Out-Null
        Write-Host "Registered: scheduled task '$taskName' (every $hours hours)" -ForegroundColor Green
        return
    }

    if ($platform -eq 'Posix') {
        $cronLine = Get-AzDevOpsCronLine -PwshPath $pwshPath
        $split    = Get-AzDevOpsCrontabSplit
        $newCron  = (@($split.Other) + $cronLine) -join "`n"
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
        } else {
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
    $cmd       = Get-Command Out-ConsoleGridView -ErrorAction SilentlyContinue
    $available = ($null -ne $cmd)
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
# All four read $HOME/.bashcuts-cache/azure-devops/{assigned,mentions}.json
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
    return [PSCustomObject]@{
        Id         = if ($f.'System.Id') { [int]$f.'System.Id' } else { [int]$Raw.id }
        Type       = $f.'System.WorkItemType'
        State      = $f.'System.State'
        Title      = $f.'System.Title'
        Iteration  = $f.'System.IterationPath'
        AssignedAt = if ($f.'System.ChangedDate') { [datetime]$f.'System.ChangedDate' } else { $null }
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
    } catch {
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
    } else {
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
        @{ Expression = $Field;                  Descending = $true }

    return @($sorted)
}


function Format-AzDevOpsTruncatedTitle {
    param([string] $Title)

    $titleMaxLen = 80
    $ellipsis    = '...'

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
    # both env vars are set; returns '' when either is missing. Designed for
    # callers that build URLs for many ids in a loop (e.g. Out-ConsoleGridView
    # row projections in Get-AzDevOpsTreeRows) so the prefix is computed once
    # instead of per row, and so per-row use does not pollute $LASTEXITCODE.
    if (-not $env:AZ_DEVOPS_ORG -or -not $env:AZ_PROJECT) {
        return ''
    }

    $org        = $env:AZ_DEVOPS_ORG.TrimEnd('/')
    $projectEnc = [uri]::EscapeDataString($env:AZ_PROJECT)
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
        Write-Host "AZ_DEVOPS_ORG and AZ_PROJECT must both be set in your `$profile." -ForegroundColor Red
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
        -Converter   { param($r) ConvertFrom-AzDevOpsAssignedItem -Raw $r }
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
    $sorted   = Sort-AzDevOpsByDateDesc -Items $filtered -Field 'AssignedAt'

    $rows  = @($sorted | Select-Object Id, Type, State, (Get-AzDevOpsTitleColumn), Iteration, AssignedAt)
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
    } else {
        [int]$Raw.id
    }

    $mentionedAt = if ($f.'System.ChangedDate') {
        [datetime]$f.'System.ChangedDate'
    } else {
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
        -Converter   { param($r) ConvertFrom-AzDevOpsMentionItem -Raw $r }
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
        } else {
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

    $rows  = @($sorted | Select-Object Id, Type, State, (Get-AzDevOpsTitleColumn), MentionedBy, MentionedAt)
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
# Reads $HOME/.bashcuts-cache/azure-devops/hierarchy.json (built by
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
    } else {
        $null
    }

    $id = if ($f.'System.Id') {
        [int]$f.'System.Id'
    } else {
        [int]$Raw.id
    }

    $area = if ($null -ne $f.'System.AreaPath' -and "$($f.'System.AreaPath')" -ne '') {
        [string]$f.'System.AreaPath'
    } else {
        $null
    }

    $item = [PSCustomObject]@{
        Id        = $id
        Type      = $f.'System.WorkItemType'
        State     = $f.'System.State'
        Title     = $f.'System.Title'
        Iteration = $f.'System.IterationPath'
        AreaPath  = $area
        Parent    = $parent
    }
    return $item
}


function Read-AzDevOpsHierarchyCache {
    $paths = Get-AzDevOpsCachePaths
    $items = Read-AzDevOpsJsonCache `
        -Path        $paths.Hierarchy `
        -Description 'hierarchy' `
        -Converter   { param($r) ConvertFrom-AzDevOpsHierarchyItem -Raw $r }
    return $items
}


function Get-AzDevOpsTreeIndent {
    param([Parameter(Mandatory)] [int] $Depth)

    $indentUnit = '    '   # 4 spaces per tree level
    $indent     = $indentUnit * $Depth
    return $indent
}


function Get-AzDevOpsTreeIcon {
    param([Parameter(Mandatory)] [string] $Type)

    $iconEpic    = "$([char]0x1F4E6)"   # package
    $iconFeature = "$([char]0x1F3AF)"   # bullseye
    $iconStory   = "$([char]0x1F4DD)"   # memo
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

    $indent    = Get-AzDevOpsTreeIndent -Depth $Depth
    $icon      = Get-AzDevOpsTreeIcon -Type $Item.Type
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

    $rows  = New-Object System.Collections.Generic.List[PSCustomObject]
    $epics = @($Items | Where-Object { $_.Type -eq 'Epic' } | Sort-Object Id)

    # Build the URL prefix once instead of resolving env vars + escaping the
    # project name per row. Empty string when env vars are unset - callers see
    # an empty Url column instead of a per-row $LASTEXITCODE flip.
    $urlPrefix = Get-AzDevOpsWorkItemUrlPrefix

    foreach ($epic in $epics) {
        $epicPath = "Epic $($epic.Id) / $($epic.Title)"
        $epicUrl  = if ($urlPrefix) {
            "$urlPrefix$($epic.Id)"
        } else {
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
            $featureUrl  = if ($urlPrefix) {
                "$urlPrefix$($feature.Id)"
            } else {
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
                $storyUrl  = if ($urlPrefix) {
                    "$urlPrefix$($story.Id)"
                } else {
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

    $result = ,@($rows)
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
        } else {
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
# Reuses the same $HOME/.bashcuts-cache/azure-devops/hierarchy.json that
# az-Show-AzDevOpsTree consumes; never calls `az` directly. Default -Type list
# matches what the hierarchy WIQL pulls (Epic / Feature / requirement-tier).
# Default -State filter excludes closed states via Select-AzDevOpsActiveItems;
# pass -State Closed,Resolved to flip to the archive view.
# ---------------------------------------------------------------------------

function az-Show-AzDevOpsBoard {
    [CmdletBinding()]
    param(
        [string[]] $Type  = @('Epic', 'Feature', 'User Story'),
        [string[]] $State
    )

    $items = Read-AzDevOpsHierarchyCache
    if ($null -eq $items) { return }

    Write-AzDevOpsStaleBanner

    $byType  = @($items | Where-Object { $_.Type -in $Type })
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
# Reads the same $HOME/.bashcuts-cache/azure-devops/hierarchy.json that
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
        Write-Host "Out-ConsoleGridView is required for az-Find-AzDevOpsWorkItem." -ForegroundColor Yellow
        Write-Host "  Install with: Install-Module Microsoft.PowerShell.ConsoleGuiTools -Scope CurrentUser" -ForegroundColor Yellow
        return
    }

    $items = Read-AzDevOpsHierarchyCache
    if ($null -eq $items) { return }

    Write-AzDevOpsStaleBanner

    $closedStates = Get-AzDevOpsClosedStates
    $visibleItems = if ($IncludeClosed) {
        $items
    } else {
        $items | Where-Object { $_.State -notin $closedStates }
    }

    $byParent = @{}
    foreach ($item in $visibleItems) {
        $key = if ($null -ne $item.Parent) {
            $item.Parent
        } else {
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

    $exitLabel        = 'EXIT'
    $backLabel        = '.. [Go Back]'
    $openEpicLabel    = '.. [Open this Epic]'
    $openFeatureLabel = '.. [Open this Feature]'
    $openStoryLabel   = '.. [Open this Story]'

    $running        = $true
    $tier           = 1
    $currentEpic    = $null
    $currentFeature = $null
    $currentStory   = $null

    while ($running) {

        if ($tier -eq 1) {
            $rows   = @(New-AzDevOpsActionRow -Title $exitLabel) + $epics
            $title  = "ALM Browser - pick an Epic ('EXIT' or Esc to quit)"
            $picked = $rows | Out-ConsoleGridView -Title $title -OutputMode Single

            if ($null -eq $picked -or $picked.Title -eq $exitLabel) {
                $running = $false
                continue
            }

            $currentEpic = $picked
            $tier        = 2
            continue
        }

        if ($tier -eq 2) {
            $features = @($byParent[$currentEpic.Id] | Where-Object { $_.Type -eq 'Feature' } | Sort-Object Id)
            $rows     = @(New-AzDevOpsActionRow -Title $backLabel) + $features + @(New-AzDevOpsActionRow -Title $openEpicLabel)

            $title  = "Epic $($currentEpic.Id) - $($currentEpic.Title) - pick a Feature"
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
            $tier           = 3
            continue
        }

        if ($tier -eq 3) {
            $stories = @($byParent[$currentFeature.Id] | Where-Object { $_.Type -in $script:AzDevOpsRequirementTypes } | Sort-Object Id)
            $rows    = @(New-AzDevOpsActionRow -Title $backLabel) + $stories + @(New-AzDevOpsActionRow -Title $openFeatureLabel)

            $title  = "Feature $($currentFeature.Id) - $($currentFeature.Title) - pick a Story"
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
            $tier         = 4
            continue
        }

        if ($tier -eq 4) {
            $rows = @(
                New-AzDevOpsActionRow -Title $backLabel
                New-AzDevOpsActionRow -Title $openStoryLabel
            )

            $title  = "Story $($currentStory.Id) - $($currentStory.Title) - choose action"
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
# non-interactively in scripts. The existing `az-create-userstory` in
# pow_az_cli.ps1 is left untouched (parallel coexistence).
# ---------------------------------------------------------------------------

function Read-AzDevOpsClassificationCache {
    # Reads iterations.json or areas.json from the cache. Returns the parsed
    # tree root, or $null when the cache file is missing / unparseable so
    # callers can fall back to a live `az` fetch.
    param([Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind)

    $paths    = Get-AzDevOpsCachePaths
    $cachePath = if ($Kind -eq 'Iteration') {
        $paths.Iterations
    } else {
        $paths.Areas
    }

    if (-not (Test-Path -LiteralPath $cachePath)) {
        return $null
    }

    try {
        $tree = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
        return $tree
    } catch {
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
    } catch {
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
    $stack     = New-Object System.Collections.Stack
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

    $unique     = $collected | Sort-Object -Unique
    $uniqueList = ,@($unique)
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

function Get-AzDevOpsClassificationRows {
    # Walks the classification tree (depth-first, children in declaration
    # order) and emits one PSCustomObject per node. Skips the synthetic root
    # node (whose path is the bare '\<Project>\<Kind>' shell with no work-
    # item-path equivalent) so the grid only shows pickable entries. For
    # iterations, surfaces the startDate / finishDate attributes as ISO
    # yyyy-MM-dd strings; areas omit those columns.
    param(
        [Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind,
        [Parameter(Mandatory)] $Root
    )

    $rows = New-Object System.Collections.Generic.List[PSCustomObject]
    if ($null -eq $Root) {
        $empty = ,@($rows)
        return $empty
    }

    $walk = {
        param($Node, $Depth)

        if ($null -eq $Node) { return }

        # Only emit the synthetic root's children onward - the root itself
        # is the bare project/kind shell that ConvertTo-AzDevOpsWorkItemPath
        # also filters out (returns $null for it).
        if ($Depth -gt 0) {
            $row = if ($Kind -eq 'Iteration') {
                $startIso = if ($Node.attributes -and $Node.attributes.startDate) {
                    ($Node.attributes.startDate -as [datetime]).ToString('yyyy-MM-dd')
                } else {
                    ''
                }

                $finishIso = if ($Node.attributes -and $Node.attributes.finishDate) {
                    ($Node.attributes.finishDate -as [datetime]).ToString('yyyy-MM-dd')
                } else {
                    ''
                }

                [PSCustomObject]@{
                    Depth      = $Depth
                    Name       = $Node.name
                    Path       = $Node.path
                    StartDate  = $startIso
                    FinishDate = $finishIso
                }
            } else {
                [PSCustomObject]@{
                    Depth = $Depth
                    Name  = $Node.name
                    Path  = $Node.path
                }
            }

            $rows.Add($row)
        }

        if ($Node.children) {
            foreach ($child in $Node.children) {
                & $walk $child ($Depth + 1)
            }
        }
    }

    & $walk $Root 0

    $result = ,@($rows)
    return $result
}


function Format-AzDevOpsClassificationNode {
    # Text-fallback per-node line. '<indent><name>' for areas; for iterations
    # appends '<tab><start> -> <finish>' when both dates are present (omits
    # the date suffix when either is blank, matching the Get- helper). The
    # tab separator keeps the dates copy-paste-able into a spreadsheet.
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Row,
        [Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind
    )

    $indent     = Get-AzDevOpsTreeIndent -Depth ($Row.Depth - 1)
    $arrowGlyph = "$([char]0x2192)"   # rightwards arrow
    $line       = "$indent$($Row.Name)"

    if ($Kind -eq 'Iteration' -and $Row.StartDate -and $Row.FinishDate) {
        $line = "$line`t$($Row.StartDate) $arrowGlyph $($Row.FinishDate)"
    }

    return $line
}


function Show-AzDevOpsClassification {
    # Orchestrator for az-Show-AzDevOpsAreas / az-Show-AzDevOpsIterations.
    # Cache-first with live fallback (gated by Assert-AzDevOpsAuthOrAbort so
    # the live `az` call doesn't fire on a stale env). Emits to
    # Out-ConsoleGridView when available, falls back to an indented text tree
    # via Format-AzDevOpsClassificationNode + Write-Output. Mirrors the
    # az-Show-AzDevOpsTree post-#36 shape so the Show- family stays uniform.
    param([Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind)

    $azKind        = $Kind.ToLower()
    $publicCommand = "az-Show-AzDevOps$($Kind)s"
    $kindLabelLow  = "${azKind}s"

    $tree = Read-AzDevOpsClassificationCache -Kind $Kind
    $cameFromCache = $true

    if ($null -eq $tree) {
        if (-not (Assert-AzDevOpsAuthOrAbort -CommandName $publicCommand)) {
            return
        }

        Write-Host "(fetching $kindLabelLow live - run az-Sync-AzDevOpsCache to make this instant)" -ForegroundColor Yellow
        $tree = Invoke-AzDevOpsClassificationLive -Kind $Kind
        $cameFromCache = $false
    }

    if ($null -eq $tree) {
        return
    }

    if ($cameFromCache) {
        Write-AzDevOpsStaleBanner
    }

    $rows = Get-AzDevOpsClassificationRows -Kind $Kind -Root $tree
    if (@($rows).Count -eq 0) {
        Write-Host "(no $kindLabelLow defined)" -ForegroundColor Yellow
        return
    }

    if (Test-AzDevOpsGridAvailable) {
        $title = "Azure DevOps $kindLabelLow - $(@($rows).Count) nodes"
        Show-AzDevOpsRows -Rows $rows -Title $title
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
    } else {
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
    } else {
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
    $dash  = '-'
    $break = '<br/><br/>'
    $ac    = "$dash $first"

    while ($true) {
        $resp = Read-Host 'More AC? (Y/N)'
        if ($resp -notmatch '^(y|yes)$') {
            break
        }

        $next = Read-Host 'Enter additional AC'
        $ac   = "$ac $break $dash $next"
    }

    return $ac
}


function Test-AzDevOpsAreaPathMatch {
    # True when $RowArea is equal to, or a sub-path of, any path in
    # $ScopePaths. Sub-path comparison uses backslash boundaries so
    # 'Project ABC\Portfolio' matches 'Project ABC\Portfolio\R&D' but
    # does NOT match 'Project ABC\PortfolioOther'. Case-insensitive to
    # match Azure DevOps's own path semantics.
    param(
        [string]   $RowArea,
        [string[]] $ScopePaths
    )

    if (-not $RowArea) {
        return $false
    }
    if (-not $ScopePaths -or $ScopePaths.Count -eq 0) {
        return $false
    }

    foreach ($scope in $ScopePaths) {
        if (-not $scope) {
            continue
        }
        if ($RowArea -ieq $scope) {
            return $true
        }
        $prefix = "$scope\"
        if ($RowArea.Length -gt $prefix.Length -and $RowArea.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
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
    # -AreaPaths narrows the candidate list to rows whose AreaPath equals or
    # is a sub-path of any provided path - sourced from
    # $global:AzDevOpsProjectMap..Types..ParentScope.AreaPaths by
    # the type-aware wrappers below. Silent no-op when the hierarchy cache
    # was written before the AreaPath field was added (older rows -> the
    # filter sees $null and treats them as non-matches; we then surface
    # the empty list via the existing "no active parents" path).
    #
    # Limitation: Basic-template projects skip the Feature tier entirely
    # (Epic -> Issue, no Feature). For -ParentType Feature this filter
    # returns zero rows on Basic projects and the caller falls through to
    # the orphan path - acceptable while the create flow stays Agile/Scrum/
    # CMMI-focused.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Feature','Epic')] [string] $ParentType,
        [Parameter(Mandatory)] $Hierarchy,
        [string]   $ChildLabel = 'item',
        [string[]] $AreaPaths
    )

    $closedStates = Get-AzDevOpsClosedStates
    $candidates   = @($Hierarchy |
        Where-Object { $_.Type -eq $ParentType -and $_.State -notin $closedStates } |
        Sort-Object Id)

    $orphanLabel = "(no parent - orphan $ChildLabel)"

    if ($candidates.Count -eq 0) {
        Write-Host "(no active ${ParentType}s in hierarchy.json - $ChildLabel will be orphaned)" -ForegroundColor Yellow
        return 0
    }

    if ($AreaPaths -and $AreaPaths.Count -gt 0) {
        # ConvertFrom-AzDevOpsHierarchyItem always defines an AreaPath property,
        # but cache files written before the WIQL schema bump have it set to
        # $null on every row. Detect that case (no row carries a non-empty
        # AreaPath) and skip the filter silently to preserve current behavior
        # until the user re-runs az-Sync-AzDevOpsCache.
        $hasAreaField = @($candidates | Where-Object { $_.AreaPath }).Count -gt 0
        if (-not $hasAreaField) {
            Write-Verbose "ParentScope.AreaPaths filter skipped - hierarchy cache rows do not carry AreaPath. Run az-Sync-AzDevOpsCache to refresh."
        } else {
            $filtered = @($candidates | Where-Object {
                Test-AzDevOpsAreaPathMatch -RowArea $_.AreaPath -ScopePaths $AreaPaths
            })

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
        $picked   = Read-AzDevOpsGridPick -Rows $gridRows -Title "Pick a parent $ParentType (Esc = orphan $ChildLabel)"

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
        $c     = $candidates[$i]
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


function Get-AzDevOpsTypeParentScopeAreaPaths {
    # Looks up the AreaPaths array off Types..ParentScope for the
    # given child type and returns it (or $null when no map / no scope).
    # Centralizes the resolver call so the Feature/Epic pickers stay one-liners.
    param([Parameter(Mandatory)] [string] $ChildType)

    if (-not (Get-Command Resolve-AzDevOpsTypeParentScope -ErrorAction SilentlyContinue)) {
        return $null
    }

    $scope = Resolve-AzDevOpsTypeParentScope -Type $ChildType
    if ($null -eq $scope) {
        return $null
    }
    if ($null -eq $scope.AreaPaths) {
        return $null
    }

    $paths = [string[]]@($scope.AreaPaths)
    return ,$paths
}


function Read-AzDevOpsFeaturePick {
    # Story -> Feature parent picker. Thin wrapper over Read-AzDevOpsParentPick
    # so az-New-AzDevOpsUserStory keeps its current call site unchanged.
    # Looks up Types.USER_STORY.ParentScope.AreaPaths to narrow the candidate
    # list when configured (Phase B multi-project support).
    param([Parameter(Mandatory)] $Hierarchy)

    $areaPaths = Get-AzDevOpsTypeParentScopeAreaPaths -ChildType 'USER_STORY'

    $featureId = if ($areaPaths -and $areaPaths.Count -gt 0) {
        Read-AzDevOpsParentPick -ParentType 'Feature' -Hierarchy $Hierarchy -ChildLabel 'story' -AreaPaths $areaPaths
    } else {
        Read-AzDevOpsParentPick -ParentType 'Feature' -Hierarchy $Hierarchy -ChildLabel 'story'
    }

    return $featureId
}


function Read-AzDevOpsEpicPick {
    # Feature -> Epic parent picker. Thin wrapper over Read-AzDevOpsParentPick
    # used by az-New-AzDevOpsFeature. Looks up Types.FEATURE.ParentScope.AreaPaths
    # to narrow the candidate list when configured.
    param([Parameter(Mandatory)] $Hierarchy)

    $areaPaths = Get-AzDevOpsTypeParentScopeAreaPaths -ChildType 'FEATURE'

    $epicId = if ($areaPaths -and $areaPaths.Count -gt 0) {
        Read-AzDevOpsParentPick -ParentType 'Epic' -Hierarchy $Hierarchy -ChildLabel 'Feature' -AreaPaths $areaPaths
    } else {
        Read-AzDevOpsParentPick -ParentType 'Epic' -Hierarchy $Hierarchy -ChildLabel 'Feature'
    }

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
        } else {
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
        } else {
            ''
        }
        Write-Host ("  {0}. {1}{2}" -f ($i + 1), $Paths[$i], $marker)
    }

    $defaultPrompt = if ($Default) {
        " (Enter for default '$Default')"
    } else {
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
    } else {
        'AZ_AREA'
    }

    $envFallback = if ($Kind -eq 'Iteration') {
        $env:AZ_ITERATION
    } else {
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
        [Parameter(Mandatory)] [string] $Iteration,
        [Parameter(Mandatory)] [string] $Area,
        [string]    $Type = 'User Story',
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

    # Tags: appended only when non-empty so the field is not touched on
    # creates that don't opt in (preserves today's "don't pass System.Tags"
    # behavior for users without $global:AzDevOpsProjectMap).
    if ($Tags -and $Tags.Count -gt 0) {
        $tagList = ($Tags -join '; ')
        $fields += "System.Tags=$tagList"
    }

    # ExtraFields: any RefName -> value pair the caller wants merged into the
    # `--fields` list (e.g. Types.<TYPE>.RequiredFields resolved upstream).
    # Values are passed through verbatim; the caller is responsible for
    # turning 'prompt' into a real user-supplied value before getting here.
    if ($ExtraFields -and $ExtraFields.Count -gt 0) {
        foreach ($refName in $ExtraFields.Keys) {
            $value = $ExtraFields[$refName]
            $fields += "$refName=$value"
        }
    }

    $result = New-AzDevOpsWorkItem `
        -Type        $Type `
        -Title       $Title `
        -Description $Description `
        -AssignedTo  $env:AZ_USER_EMAIL `
        -Project     $env:AZ_PROJECT `
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
    } catch {
        return [PSCustomObject]@{
            Ok    = $false
            Error = "parse failed: $($_.Exception.Message)"
            Id    = 0
            Url   = $null
        }
    }

    $newId = [int]$created.id

    $url = if ($env:AZ_DEVOPS_ORG -and $env:AZ_PROJECT) {
        $org        = $env:AZ_DEVOPS_ORG.TrimEnd('/')
        $projectEnc = [uri]::EscapeDataString($env:AZ_PROJECT)
        "$org/$projectEnc/_workitems/edit/$newId"
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


function Resolve-AzDevOpsIterationArea {
    # Picker + env-var fallback shared by every az-New-AzDevOps* creator. For
    # each kind: if the caller already passed a value, keep it; otherwise
    # consult the active project's Types..Area / Iteration overrides
    # (Phase B multi-project support); if still empty, prompt via
    # Read-AzDevOpsKindPick. Missing-after-pick prints the standard "Set
    # `$env:AZ_* or run az-Sync-AzDevOpsCache" abort. Returns a result object
    # with .Ok / .Iteration / .Area so callers can short-circuit with a single
    # `if (-not $resolved.Ok) { return }`.
    #
    # -Type names the work-item type the resolver should look up in
    # $global:AzDevOpsProjectMap..Types.. When unset (or no map
    # defined), the resolver layer returns $null and the function falls
    # through to today's env-var + prompt flow - preserving single-project
    # behavior for users who never opt into the map.
    param(
        [string] $Iteration,
        [string] $Area,
        [string] $Type
    )

    if (-not $Iteration -and $Type) {
        $typeIteration = Resolve-AzDevOpsTypeIteration -Type $Type
        if ($typeIteration) {
            $Iteration = $typeIteration
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
        $typeArea = Resolve-AzDevOpsTypeArea -Type $Type
        if ($typeArea) {
            $Area = $typeArea
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


function Resolve-AzDevOpsPriorityWithDefault {
    # Three-step priority resolution shared by every az-New-AzDevOps* creator
    # (CLAUDE.md extract-repeated-branches): explicit -Priority param wins,
    # then the active project's Types.<TYPE>.DefaultPriority, then an
    # interactive Read-AzDevOpsPriority prompt.
    param(
        [int]    $Current,
        [Parameter(Mandatory)] [string] $Type
    )

    if ($Current -ge 1 -and $Current -le 4) {
        return $Current
    }

    $typePriority = Resolve-AzDevOpsTypeDefaultPriority -Type $Type
    if ($typePriority -ge 1 -and $typePriority -le 4) {
        return $typePriority
    }

    $picked = Read-AzDevOpsPriority
    return $picked
}


function Resolve-AzDevOpsStoryPointsWithDefault {
    # Three-step story-points resolution shared by az-New-AzDevOps* creators
    # that carry story points. Mirrors Resolve-AzDevOpsPriorityWithDefault's
    # explicit -> type-default -> prompt walk.
    param(
        [int]    $Current,
        [Parameter(Mandatory)] [string] $Type
    )

    if ($Current -ge 0) {
        return $Current
    }

    $typeStoryPoints = Resolve-AzDevOpsTypeDefaultStoryPoints -Type $Type
    if ($typeStoryPoints -ge 0) {
        return $typeStoryPoints
    }

    $picked = Read-AzDevOpsStoryPoints
    return $picked
}


function Resolve-AzDevOpsRequiredFieldValues {
    # Walks the Types..RequiredFields hashtable returned by
    # Resolve-AzDevOpsTypeRequiredFields and produces a flat hashtable of
    # RefName -> value ready to splat as Invoke-AzDevOpsWorkItemCreate
    # -ExtraFields. Values equal to 'prompt' (case-insensitive) are turned
    # into a Read-Host so the user supplies the value at create time; any
    # other value is passed through verbatim.
    #
    # Returns an empty hashtable when no map / no override, so callers can
    # skip the parameter entirely when .Count is 0.
    param([string] $Type)

    if (-not (Get-Command Resolve-AzDevOpsTypeRequiredFields -ErrorAction SilentlyContinue)) {
        return @{}
    }

    $required = Resolve-AzDevOpsTypeRequiredFields -Type $Type
    if ($null -eq $required -or $required.Count -eq 0) {
        return @{}
    }

    $resolved = @{}
    foreach ($refName in $required.Keys) {
        $value = $required[$refName]
        if ("$value" -ieq 'prompt') {
            $entered = Read-Host "Enter $refName"
            $resolved[$refName] = $entered
        } else {
            $resolved[$refName] = $value
        }
    }

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
        [int]    $ParentId      = 0,
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

    $newId  = $createResult.Id
    $newUrl = $createResult.Url
    Write-Host "OK Created $ChildLabel $newId" -ForegroundColor Green

    if ($ParentId -gt 0) {
        Write-Host "Linking $OrphanLabel $newId to parent $ParentLabel $ParentId..." -ForegroundColor Cyan
        $linkResult = Invoke-AzDevOpsParentLink -Id $newId -ParentId $ParentId
        if (-not $linkResult.Ok) {
            Write-Host "STEP FAILED: az boards work-item relation add ($OrphanLabel $newId is orphaned, fix manually)" -ForegroundColor Red
            Write-Host "  $($linkResult.Error)" -ForegroundColor Red
        } else {
            Write-Host "OK Linked $newId -> $ParentLabel $ParentId" -ForegroundColor Green
        }
    } else {
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
        [int]    $Priority    = -1,
        [int]    $StoryPoints = -1,
        [string] $AcceptanceCriteria,
        [int]    $FeatureId   = -1,
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

    $Priority    = Resolve-AzDevOpsPriorityWithDefault    -Current $Priority    -Type 'USER_STORY'
    $StoryPoints = Resolve-AzDevOpsStoryPointsWithDefault -Current $StoryPoints -Type 'USER_STORY'

    if (-not $PSBoundParameters.ContainsKey('AcceptanceCriteria')) {
        $AcceptanceCriteria = Read-AzDevOpsAcceptanceCriteria
    }

    if ($FeatureId -lt 0) {
        $FeatureId = Read-AzDevOpsFeaturePick -Hierarchy $hierarchy
    }

    $resolved = Resolve-AzDevOpsIterationArea -Iteration $Iteration -Area $Area -Type 'USER_STORY'
    if (-not $resolved.Ok) {
        return
    }
    $Iteration = $resolved.Iteration
    $Area      = $resolved.Area

    $typeTags     = Resolve-AzDevOpsTypeTags -Type 'USER_STORY'
    $extraFields  = Resolve-AzDevOpsRequiredFieldValues -Type 'USER_STORY'

    $createArgs = @{
        Title              = $Title
        Description        = $Description
        Priority           = $Priority
        StoryPoints        = $StoryPoints
        AcceptanceCriteria = $AcceptanceCriteria
        Iteration          = $Iteration
        Area               = $Area
    }

    if ($typeTags -and $typeTags.Count -gt 0) {
        $createArgs['Tags'] = $typeTags
    }
    if ($extraFields -and $extraFields.Count -gt 0) {
        $createArgs['ExtraFields'] = $extraFields
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
        [int]    $Priority    = -1,
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

    $Priority = Resolve-AzDevOpsPriorityWithDefault -Current $Priority -Type 'FEATURE'

    if (-not $PSBoundParameters.ContainsKey('AcceptanceCriteria')) {
        $AcceptanceCriteria = Read-AzDevOpsAcceptanceCriteria
    }

    if ($ParentEpicId -lt 0) {
        $ParentEpicId = Read-AzDevOpsEpicPick -Hierarchy $hierarchy
    }

    $resolved = Resolve-AzDevOpsIterationArea -Iteration $Iteration -Area $Area -Type 'FEATURE'
    if (-not $resolved.Ok) {
        return
    }
    $Iteration = $resolved.Iteration
    $Area      = $resolved.Area

    $typeTags    = Resolve-AzDevOpsTypeTags -Type 'FEATURE'
    $extraFields = Resolve-AzDevOpsRequiredFieldValues -Type 'FEATURE'

    $createArgs = @{
        Type               = 'Feature'
        Title              = $Title
        Description        = $Description
        Priority           = $Priority
        AcceptanceCriteria = $AcceptanceCriteria
        Iteration          = $Iteration
        Area               = $Area
    }

    if ($typeTags -and $typeTags.Count -gt 0) {
        $createArgs['Tags'] = $typeTags
    }
    if ($extraFields -and $extraFields.Count -gt 0) {
        $createArgs['ExtraFields'] = $extraFields
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
    $Area      = $resolved.Area

    # Tags are static across the batch (board + type config is invariant for
    # the duration of the loop). RequiredFields with literal values are also
    # static; 'prompt' entries get re-asked per story so each child can carry
    # its own value when that is what the schema requires.
    $typeTags        = Resolve-AzDevOpsTypeTags -Type 'USER_STORY'
    $requiredRaw     = if (Get-Command Resolve-AzDevOpsTypeRequiredFields -ErrorAction SilentlyContinue) {
        Resolve-AzDevOpsTypeRequiredFields -Type 'USER_STORY'
    } else {
        @{}
    }

    Write-Host ""
    Write-Host "Batch-creating child User Stories under Feature $ParentId" -ForegroundColor Cyan
    Write-Host "  Area      : $Area"
    Write-Host "  Iteration : $Iteration"
    Write-Host "  (empty title at the next prompt ends the batch cleanly)"

    # Resolve-AzDevOpsTypeDefault{Priority,StoryPoints} already returns -1
    # when no map / no override / out-of-range, so the values can seed the
    # Read-* "previous" reuse hint directly. The first iteration's Enter
    # accepts the default; subsequent iterations roll forward the user's
    # last answer (existing behavior preserved).
    $failedTitles        = @()
    $createdUrls         = @()
    $previousPriority    = Resolve-AzDevOpsTypeDefaultPriority    -Type 'USER_STORY'
    $previousStoryPoints = Resolve-AzDevOpsTypeDefaultStoryPoints -Type 'USER_STORY'
    $iterationNumber     = 1

    while ($true) {
        Write-Host ""
        Write-Host ("--- Story #{0} ---" -f $iterationNumber) -ForegroundColor Cyan

        $title = Read-Host 'Story title (Enter to finish batch)'
        if (-not $title) {
            break
        }

        $acceptanceCriteria = Read-AzDevOpsAcceptanceCriteria
        $priority           = Read-AzDevOpsPriority    -Previous $previousPriority
        $storyPoints        = Read-AzDevOpsStoryPoints -Previous $previousStoryPoints

        # Resolve RequiredFields per child so 'prompt' entries are re-asked.
        $extraFields = @{}
        foreach ($refName in $requiredRaw.Keys) {
            $value = $requiredRaw[$refName]
            if ("$value" -ieq 'prompt') {
                $entered = Read-Host "Enter $refName"
                $extraFields[$refName] = $entered
            } else {
                $extraFields[$refName] = $value
            }
        }

        $createArgs = @{
            Title              = $title
            Description        = ''
            Priority           = $priority
            StoryPoints        = $storyPoints
            AcceptanceCriteria = $acceptanceCriteria
            Iteration          = $Iteration
            Area               = $Area
        }

        if ($typeTags -and $typeTags.Count -gt 0) {
            $createArgs['Tags'] = $typeTags
        }
        if ($extraFields.Count -gt 0) {
            $createArgs['ExtraFields'] = $extraFields
        }

        $outcome = Invoke-AzDevOpsCreateAndLink `
            -ChildLabel  'User Story' `
            -ParentLabel 'Feature' `
            -OrphanLabel 'story' `
            -CreateArgs  $createArgs `
            -ParentId    $ParentId

        if (-not $outcome.Ok) {
            $failedTitles += $title
        } else {
            if ($outcome.Url) {
                $createdUrls += $outcome.Url
            }
            $createdIds          += $outcome.Id
            $previousPriority     = $priority
            $previousStoryPoints  = $storyPoints
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
    $failedCount  = $failedTitles.Count
    $idsList = if ($createdCount -gt 0) {
        ($createdIds -join ', ')
    } else {
        '(none)'
    }

    if ($failedCount -gt 0) {
        Write-Host ("Created {0}, Failed {1} child stories under Feature #{2}: {3}" -f $createdCount, $failedCount, $ParentId, $idsList) -ForegroundColor Yellow
        Write-Host ("Failed titles: {0}" -f ($failedTitles -join ' | ')) -ForegroundColor Yellow
    } else {
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
# Schema directory: $HOME/.bashcuts/azure-devops/   (separate from the
#                   auto-managed $HOME/.bashcuts-cache/ tree)
# Schema file:      schema-<orgslug>.json           (per-org keyed off
#                   $env:AZ_DEVOPS_ORG; falls back to schema.json when unset)
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
    # Per-org keying: the path-tail segment of $env:AZ_DEVOPS_ORG, lowercased
    # and reduced to [a-z0-9-]. Returns $null when the env var is unset, so
    # Get-AzDevOpsSchemaPaths can fall back to the unsuffixed schema.json.
    if (-not $env:AZ_DEVOPS_ORG) {
        return $null
    }

    $segment = ($env:AZ_DEVOPS_ORG.TrimEnd('/') -split '/')[-1]
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
    $configDir = Join-Path (Join-Path $HOME '.bashcuts') 'azure-devops'
    $slug      = Get-AzDevOpsSchemaOrgSlug

    $fileName = if ($slug) {
        "schema-$slug.json"
    } else {
        'schema.json'
    }

    return [PSCustomObject]@{
        Dir  = $configDir
        File = Join-Path $configDir $fileName
        Slug = $slug
    }
}


function Initialize-AzDevOpsSchemaDir {
    # Creates $HOME/.bashcuts/azure-devops with 0700 on Unix. Windows gets
    # default NTFS ACLs inherited from %USERPROFILE%, which are user-only
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
    $tmp  = "$Path.tmp"
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
        $raw    = Get-Content -LiteralPath $paths.File -Raw
        $schema = $raw | ConvertFrom-Json
        return $schema
    } catch {
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

        'Feature' = [ordered]@{
            required = @()
            optional = @()
        }

        'Bug' = [ordered]@{
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
        $entry  = $prop.Value

        foreach ($section in @('required', 'optional')) {
            $sectionList = $entry.$section
            if (-not $sectionList) { continue }

            foreach ($f in $sectionList) {
                $optionsText = if ($f.type -eq 'picklist' -and $f.options) {
                    ($f.options -join ', ')
                } else {
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

    $result = ,@($rows)
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

    $editor       = Resolve-AzDevOpsEditor
    $editorTokens = @($editor -split '\s+' | Where-Object { $_ })

    if ($editorTokens.Count -eq 0) {
        Write-Host "No editor resolved (EDITOR / code / notepad / nano all unavailable)." -ForegroundColor Red
        return
    }

    $cmd = $editorTokens[0]

    $extraArgs = if ($editorTokens.Count -gt 1) {
        $editorTokens[1..($editorTokens.Count - 1)]
    } else {
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
        $parsed = $result.Json | ConvertFrom-Json
        return [PSCustomObject]@{ Ok = $true; Error = $null; Type = $parsed }
    } catch {
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
    $ref  = $FieldInstance.field.referenceName

    $allowed = @()
    if ($FieldInstance.allowedValues) {
        $allowed = @($FieldInstance.allowedValues)
    }

    $type = if ($allowed.Count -gt 0) {
        'picklist'
    } else {
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

    $paths     = Initialize-AzDevOpsSchemaDir
    $knownRefs = Get-AzDevOpsSchemaSystemRefs
    $wiTypes   = Get-AzDevOpsSchemaWorkItemTypes

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
            } else {
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

    $validTypes         = Get-AzDevOpsSchemaValidTypes
    $unknownRefs        = New-Object System.Collections.Generic.List[string]
    $picklistMismatches = New-Object System.Collections.Generic.List[string]
    $unknownTypes       = New-Object System.Collections.Generic.List[string]

    foreach ($wiTypeProp in $schema.PSObject.Properties) {
        $wiType = $wiTypeProp.Name
        $entry  = $wiTypeProp.Value

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
