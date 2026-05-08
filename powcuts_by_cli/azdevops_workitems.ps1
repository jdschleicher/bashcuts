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
#   az-Confirm-AzDevOpsLogin            - step 4 (az login session; offers login)
#   az-Set-AzDevOpsDefaults             - step 5 (az devops configure --defaults)
#   az-Confirm-AzDevOpsSmokeQuery       - step 6 (az boards query smoke test)
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
    $json = az boards query --wiql $wiql --output json 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    try {
        $items = $json | ConvertFrom-Json
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
    # az on the user's behalf (Sync-AzDevOpsCache, New-AzDevOpsUserStory,
    # az-Initialize-AzDevOpsSchema, az-Test-AzDevOpsSchema). Returns $true when
    # auth is good. On failure, prints the standard "<command> aborted -
    # Test-AzDevOpsAuth returned false. Run Connect-AzDevOps." line and
    # returns $false so callers `if (-not (Assert-...)) { return }`.
    param([Parameter(Mandatory)] [string] $CommandName)

    if (Test-AzDevOpsAuth) {
        return $true
    }

    Write-Host "$CommandName aborted - Test-AzDevOpsAuth returned false. Run Connect-AzDevOps." -ForegroundColor Red
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
        @{ Num = 4; Name = 'Azure login session';           Action = { az-Confirm-AzDevOpsLogin } },
        @{ Num = 5; Name = 'Configure az devops defaults';  Action = { az-Set-AzDevOpsDefaults } },
        @{ Num = 6; Name = 'Smoke test (az boards query)';  Action = { az-Confirm-AzDevOpsSmokeQuery } }
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
    $cacheDir = Join-Path (Join-Path $HOME '.bashcuts-cache') 'azure-devops'
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


function Invoke-AzDevOpsAzJson {
    # Generic wrapper around `az ... --output json` that captures stdout JSON
    # and stderr text separately. Used by Invoke-AzDevOpsBoardsQuery (WIQL) and
    # the iteration/area classification list calls so both paths share one
    # stderr-to-tempfile pattern instead of repeating it.
    param([Parameter(Mandatory)] [string[]] $ArgList)

    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $json = & az @ArgList --output json 2>$stderrFile
        $exit = $LASTEXITCODE
        $stderr = if (Test-Path -LiteralPath $stderrFile) {
            (Get-Content -LiteralPath $stderrFile -Raw)
        } else { '' }
    } finally {
        Remove-Item -LiteralPath $stderrFile -ErrorAction SilentlyContinue
    }

    if ($null -eq $stderr) { $stderr = '' }

    return [PSCustomObject]@{
        Json     = $json
        Error    = $stderr
        ExitCode = $exit
    }
}


function Invoke-AzDevOpsBoardsQuery {
    param([Parameter(Mandatory)] [string] $Wiql)

    $result = Invoke-AzDevOpsAzJson -ArgList @('boards', 'query', '--wiql', $Wiql)
    return $result
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
    $hierarchyWiql = "Select [System.Id], [System.Title], [System.WorkItemType], [System.State], [System.Parent] From WorkItems Where [System.TeamProject] = @Project AND [System.WorkItemType] IN ('Epic', 'Feature', 'User Story')"

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
            Label    = 'Epic/Feature/Story hierarchy in @Project'
            Path     = $Paths.Hierarchy
            Fetch    = { Invoke-AzDevOpsBoardsQuery -Wiql $hierarchyWiql }.GetNewClosure()
            Counter  = $rowCounter
            RowLabel = 'rows'
        },
        @{
            Name      = 'iterations'
            Label     = 'Project iterations (tree)'
            Path      = $Paths.Iterations
            Fetch     = { Invoke-AzDevOpsAzJson -ArgList @('boards', 'iteration', 'project', 'list', '--depth', '5') }
            Counter   = $treeCounter
            RowLabel  = 'nodes'
            JsonDepth = 20
        },
        @{
            Name      = 'areas'
            Label     = 'Project areas (tree)'
            Path      = $Paths.Areas
            Fetch     = { Invoke-AzDevOpsAzJson -ArgList @('boards', 'area', 'project', 'list', '--depth', '5') }
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

    if ($cacheAge.Counts) {
        $cacheAge.Counts.PSObject.Properties | ForEach-Object {
            Write-Host "  $($_.Name): $($_.Value) rows"
        }
    }

    if ($cacheAge.Datasets) {
        $errored = @($cacheAge.Datasets.PSObject.Properties | Where-Object { $_.Value.Status -eq 'error' })
        if ($errored.Count -gt 0) {
            Write-Host ""
            Write-Host "Partial sync - $($errored.Count) dataset(s) errored:" -ForegroundColor Yellow
            foreach ($e in $errored) {
                $msg = Get-AzDevOpsFirstStderrLine -Stderr $e.Value.Error
                if (-not $msg) { $msg = '(no error text)' }
                Write-Host "  X $($e.Name): $msg" -ForegroundColor Red
            }
            Write-Host "  See $($cacheAge.LogPath) for full az stderr" -ForegroundColor Yellow
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

    if ($IncludeUrlFallback -and $env:AZ_DEVOPS_ORG -and $env:AZ_PROJECT) {
        $org        = $env:AZ_DEVOPS_ORG.TrimEnd('/')
        $projectEnc = [uri]::EscapeDataString($env:AZ_PROJECT)
        Write-Host "  Or open it directly: $org/$projectEnc/_workitems/edit/$Id" -ForegroundColor Yellow
    }

    $global:LASTEXITCODE = 1
    return $null
}


function Open-AzDevOpsWorkItemUrl {
    # env-var guard + URL build + Start-Process. Sets $LASTEXITCODE = 1 and
    # returns when env-vars are missing; otherwise launches the OS browser.
    param([Parameter(Mandatory)] [int] $Id)

    if (-not $env:AZ_DEVOPS_ORG -or -not $env:AZ_PROJECT) {
        Write-Host "AZ_DEVOPS_ORG and AZ_PROJECT must both be set in your `$profile." -ForegroundColor Red
        $global:LASTEXITCODE = 1
        return
    }

    $org        = $env:AZ_DEVOPS_ORG.TrimEnd('/')
    $projectEnc = [uri]::EscapeDataString($env:AZ_PROJECT)
    $url        = "$org/$projectEnc/_workitems/edit/$Id"

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

    $rows = $filtered | Select-Object Id, Type, State, (Get-AzDevOpsTitleColumn), Iteration, AssignedAt
    return $rows
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

    $rows = $filtered | Select-Object Id, Type, State, (Get-AzDevOpsTitleColumn), MentionedBy, MentionedAt
    return $rows
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
# Public function:
#   az-Show-AzDevOpsTree   - prints the project's Epic/Feature/User Story tree
#                          from the cached hierarchy.json (no `az` calls)
#
# Reads $HOME/.bashcuts-cache/azure-devops/hierarchy.json (built by
# az-Sync-AzDevOpsCache). The hierarchy WIQL selects [System.Parent] so each
# item carries its parent link directly - no follow-up resolution needed.
# ---------------------------------------------------------------------------

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

    $item = [PSCustomObject]@{
        Id     = $id
        Type   = $f.'System.WorkItemType'
        State  = $f.'System.State'
        Title  = $f.'System.Title'
        Parent = $parent
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

    switch ($Type) {
        'Epic' {
            return $iconEpic
        }

        'Feature' {
            return $iconFeature
        }

        'User Story' {
            return $iconStory
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

    # User Story lines drop the type label per the issue spec; epics + features
    # keep it so '📦 Epic 1234' / '🎯 Feature 1240' read clearly.
    if ($Item.Type -eq 'User Story') {
        return "$indent$icon $($Item.Id) $separator $($Item.Title) [$($Item.State)]"
    }

    return "$indent$icon $($Item.Type) $($Item.Id) $separator $($Item.Title) [$($Item.State)]"
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

            $stories = @($byParent[$feature.Id] | Where-Object { $_.Type -eq 'User Story' } | Sort-Object Id)
            foreach ($story in $stories) {
                Write-Output (Format-AzDevOpsTreeNode -Item $story -Depth 2)
            }
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

    $azKind = $Kind.ToLower()
    $result = Invoke-AzDevOpsAzJson -ArgList @('boards', $azKind, 'project', 'list', '--depth', '5')
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


function Read-AzDevOpsPriority {
    while ($true) {
        $resp = Read-Host 'Priority? 1=LOW, 2=MEDIUM, 3=HIGH, 4=SUPER-HIGH'
        if ($resp -match '^[1-4]$') {
            $priority = [int]$resp
            return $priority
        }
        Write-Host "  Please enter 1, 2, 3, or 4." -ForegroundColor Yellow
    }
}


function Read-AzDevOpsStoryPoints {
    $val = 0
    while ($true) {
        $resp = Read-Host 'Story points? (integer)'
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


function Read-AzDevOpsFeaturePick {
    # Lists active Features from hierarchy.json, prompts for a 1-based index
    # (or 0 for "no parent - orphan"). Returns the chosen Feature Id, or 0
    # for orphan.
    param([Parameter(Mandatory)] $Hierarchy)

    $closedStates = Get-AzDevOpsClosedStates
    $features     = @($Hierarchy |
        Where-Object { $_.Type -eq 'Feature' -and $_.State -notin $closedStates } |
        Sort-Object Id)

    if ($features.Count -eq 0) {
        Write-Host "(no active Features in hierarchy.json - story will be orphaned)" -ForegroundColor Yellow
        return 0
    }

    Write-Host ""
    Write-Host "Active Features:" -ForegroundColor Cyan
    Write-Host "  0. (no parent - orphan story)"
    for ($i = 0; $i -lt $features.Count; $i++) {
        $f     = $features[$i]
        $title = Format-AzDevOpsTruncatedTitle -Title $f.Title
        Write-Host ("  {0}. {1} - {2} [{3}]" -f ($i + 1), $f.Id, $title, $f.State)
    }

    $idx = 0
    while ($true) {
        $resp = Read-Host "Pick a parent Feature (0 for no parent)"
        if (-not [int]::TryParse($resp, [ref]$idx)) {
            Write-Host "  Please enter a number." -ForegroundColor Yellow
            continue
        }

        if ($idx -eq 0) {
            return 0
        }

        if ($idx -ge 1 -and $idx -le $features.Count) {
            $featureId = $features[$idx - 1].Id
            return $featureId
        }

        Write-Host "  Please enter 0..$($features.Count)." -ForegroundColor Yellow
    }
}


function Read-AzDevOpsClassificationPick {
    # Numbered picker shared by iteration + area selection. Empty input
    # selects the supplied default (typically $env:AZ_ITERATION /
    # $env:AZ_AREA) when one is available.
    param(
        [Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind,
        [Parameter(Mandatory)] [string[]] $Paths,
        [string] $Default
    )

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
    # Wraps `az boards work-item create --type 'User Story' ...` so the
    # orchestrator can react to a non-zero exit cleanly. Returns a result
    # object with Ok / Error / Id / Url so the caller can decide whether to
    # attempt the parent-link step and what URL to echo / open.
    param(
        [Parameter(Mandatory)] [string] $Title,
        [string] $Description,
        [Parameter(Mandatory)] [int]    $Priority,
        [Parameter(Mandatory)] [int]    $StoryPoints,
        [string] $AcceptanceCriteria,
        [Parameter(Mandatory)] [string] $Iteration,
        [Parameter(Mandatory)] [string] $Area
    )

    $argList = @(
        'boards', 'work-item', 'create',
        '--type',        'User Story',
        '--title',       $Title,
        '--description', $Description,
        '--assigned-to', $env:AZ_USER_EMAIL,
        '--project',     $env:AZ_PROJECT,
        '--area',        $Area,
        '--iteration',   $Iteration,
        '--fields',
            "Microsoft.VSTS.Scheduling.StoryPoints=$StoryPoints",
            "Microsoft.VSTS.Common.Priority=$Priority",
            "Microsoft.VSTS.Common.AcceptanceCriteria=$AcceptanceCriteria"
    )

    $result = Invoke-AzDevOpsAzJson -ArgList $argList

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

    $result = Invoke-AzDevOpsAzJson -ArgList @(
        'boards', 'work-item', 'relation', 'add',
        '--id',            "$Id",
        '--relation-type', 'parent',
        '--target-id',     "$ParentId"
    )

    if ($result.ExitCode -ne 0) {
        return [PSCustomObject]@{ Ok = $false; Error = $result.Error }
    }

    return [PSCustomObject]@{ Ok = $true; Error = $null }
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

    if (-not (Assert-AzDevOpsAuthOrAbort -CommandName 'az-New-AzDevOpsUserStory')) {
        return
    }

    if (-not $env:AZ_USER_EMAIL) {
        Write-Host "az-New-AzDevOpsUserStory aborted - `$env:AZ_USER_EMAIL is not set in your `$profile." -ForegroundColor Red
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
        $Priority = Read-AzDevOpsPriority
    }

    if ($StoryPoints -lt 0) {
        $StoryPoints = Read-AzDevOpsStoryPoints
    }

    if (-not $PSBoundParameters.ContainsKey('AcceptanceCriteria')) {
        $AcceptanceCriteria = Read-AzDevOpsAcceptanceCriteria
    }

    if ($FeatureId -lt 0) {
        $FeatureId = Read-AzDevOpsFeaturePick -Hierarchy $hierarchy
    }

    if (-not $Iteration) {
        $Iteration = Read-AzDevOpsKindPick -Kind 'Iteration'
    }
    if (-not $Iteration) {
        Write-Host "Iteration is required - aborting. Set `$env:AZ_ITERATION or run az-Sync-AzDevOpsCache." -ForegroundColor Red
        return
    }

    if (-not $Area) {
        $Area = Read-AzDevOpsKindPick -Kind 'Area'
    }
    if (-not $Area) {
        Write-Host "Area is required - aborting. Set `$env:AZ_AREA or run az-Sync-AzDevOpsCache." -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "Creating User Story..." -ForegroundColor Cyan
    $createResult = Invoke-AzDevOpsWorkItemCreate `
        -Title              $Title `
        -Description        $Description `
        -Priority           $Priority `
        -StoryPoints        $StoryPoints `
        -AcceptanceCriteria $AcceptanceCriteria `
        -Iteration          $Iteration `
        -Area               $Area

    if (-not $createResult.Ok) {
        Write-Host "STEP FAILED: az boards work-item create" -ForegroundColor Red
        Write-Host "  $($createResult.Error)" -ForegroundColor Red
        return
    }

    $newId  = $createResult.Id
    $newUrl = $createResult.Url
    Write-Host "OK Created User Story $newId" -ForegroundColor Green

    if ($FeatureId -gt 0) {
        Write-Host "Linking story $newId to parent Feature $FeatureId..." -ForegroundColor Cyan
        $linkResult = Invoke-AzDevOpsParentLink -Id $newId -ParentId $FeatureId

        if (-not $linkResult.Ok) {
            Write-Host "STEP FAILED: az boards work-item relation add (story $newId is orphaned, fix manually)" -ForegroundColor Red
            Write-Host "  $($linkResult.Error)" -ForegroundColor Red
        } else {
            Write-Host "OK Linked $newId -> Feature $FeatureId" -ForegroundColor Green
        }
    } else {
        Write-Host "(no parent linked - orphan story)" -ForegroundColor Yellow
    }

    if ($newUrl) {
        Write-Host "URL: $newUrl" -ForegroundColor Cyan
        if (-not $NoOpen) {
            Start-Process $newUrl
        }
    }

    return $newId
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
#                                  `az boards work-item-type show` and
#                                  write a starter schema. User refines
#                                  afterward via az-Edit-AzDevOpsSchema.
#   az-Test-AzDevOpsSchema         - validate JSON parses, every ref still
#                                  exists in the org, and picklist options
#                                  are a subset of allowedValues. Verdict:
#                                  VALID / STALE / INVALID.
#
# Internal integration point (consumed by future schema-aware updates to
# New-AzDevOpsUserStory, Get-AzDevOpsAssigned, Show-AzDevOpsTree, etc.):
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
    # Internal integration point for schema-aware consumers (New-AzDevOpsUserStory,
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

    $rows | Format-Table -AutoSize | Out-Host
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
    # Wraps `az boards work-item-type show --type <T>`. Returns Ok / Error /
    # Type so callers can react to a missing type (org's process doesn't have
    # one of the standards) without taking down the whole flow.
    param([Parameter(Mandatory)] [string] $Type)

    $result = Invoke-AzDevOpsAzJson -ArgList @('boards', 'work-item-type', 'show', '--type', $Type)
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
    # shape. Type defaults to 'string' since `az boards work-item-type show`
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
