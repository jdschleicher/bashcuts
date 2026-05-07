# ============================================================================
# Azure DevOps Work-Item Shortcuts
# ============================================================================
#
# Foundation file for Azure DevOps work-item navigation shortcuts.
#
# User-facing functions:
#   Connect-AzDevOps   - interactive first-run auth + setup helper (run once
#                        on a fresh machine, or any time auth feels stale)
#   Test-AzDevOpsAuth  - silent yes/no auth assertion intended for callers
#                        in later AzDevOps commands; returns $true / $false
#
# Step functions invoked by Connect-AzDevOps (also exposed for direct use,
# e.g. to debug a single failing step). Each returns a [PSCustomObject]
# with Ok (bool) and FailMessage (string or $null) properties, and prints
# its own status:
#   Confirm-AzDevOpsCli              - step 1 (CLI on PATH + version echo)
#   Confirm-AzDevOpsExtension        - step 2 (azure-devops extension; offers install)
#   Confirm-AzDevOpsEnvVars          - step 3 (required $profile env vars set)
#   Confirm-AzDevOpsLogin            - step 4 (az login session; offers login)
#   Set-AzDevOpsDefaults             - step 5 (az devops configure --defaults)
#   Confirm-AzDevOpsSmokeQuery       - step 6 (az boards query smoke test)
#
# Silent diagnostic helpers (pure checks, no I/O — used by Test-AzDevOpsAuth):
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
#   PS> Connect-AzDevOps
# ============================================================================


# ---------------------------------------------------------------------------
# Silent diagnostic helpers (no I/O; safe for Test-AzDevOpsAuth callers)
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


function Test-AzDevOpsAuth {
    if (-not (Test-AzDevOpsCliPresent))                { return $false }
    if ((Get-AzDevOpsMissingEnvVars).Count -gt 0)      { return $false }
    if ($null -eq (Invoke-AzDevOpsSmokeQuery))         { return $false }
    return $true
}


# ---------------------------------------------------------------------------
# Step functions invoked by Connect-AzDevOps. Each owns its print + I/O for
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


function Confirm-AzDevOpsCli {
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


function Confirm-AzDevOpsExtension {
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


function Confirm-AzDevOpsEnvVars {
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


function Confirm-AzDevOpsLogin {
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


function Set-AzDevOpsDefaults {
    $configOutput = az devops configure --defaults "organization=$env:AZ_DEVOPS_ORG" "project=$env:AZ_PROJECT" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  X az devops configure failed" -ForegroundColor Red
        Write-Host "    $configOutput"
        return New-AzDevOpsStepResult -Ok $false -FailMessage 'configure failed'
    }
    Write-Host "  OK  Defaults set: org=$env:AZ_DEVOPS_ORG project=$env:AZ_PROJECT" -ForegroundColor Green
    return New-AzDevOpsStepResult -Ok $true
}


function Confirm-AzDevOpsSmokeQuery {
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
# Connect-AzDevOps — thin orchestrator that runs each step in order and
# bails on the first failure with a clear NOT READY verdict.
# ---------------------------------------------------------------------------

function Connect-AzDevOps {

    Write-Host ""
    Write-Host "Connect-AzDevOps" -ForegroundColor Cyan
    Write-Host "================" -ForegroundColor Cyan

    # $steps is a closed internal array of step descriptors. Each Action is a
    # hardcoded scriptblock invoking a known function; nothing here accepts
    # untrusted input, so & $step.Action below has no injection surface.
    $steps = @(
        @{ Num = 1; Name = 'Azure CLI';                     Action = { Confirm-AzDevOpsCli } },
        @{ Num = 2; Name = 'azure-devops extension';        Action = { Confirm-AzDevOpsExtension } },
        @{ Num = 3; Name = 'Profile environment variables'; Action = { Confirm-AzDevOpsEnvVars } },
        @{ Num = 4; Name = 'Azure login session';           Action = { Confirm-AzDevOpsLogin } },
        @{ Num = 5; Name = 'Configure az devops defaults';  Action = { Set-AzDevOpsDefaults } },
        @{ Num = 6; Name = 'Smoke test (az boards query)';  Action = { Confirm-AzDevOpsSmokeQuery } }
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
#   Sync-AzDevOpsCache              - one-shot refresh of all three datasets
#   Get-AzDevOpsCacheStatus         - prints freshness vs 6h threshold
#   Register-AzDevOpsSyncSchedule   - Task Scheduler (Windows) or crontab
#                                      (macOS/Linux) entry, every 5 hours
#   Unregister-AzDevOpsSyncSchedule - removes the schedule on either OS
# ---------------------------------------------------------------------------

function Get-AzDevOpsCachePaths {
    $cacheDir = Join-Path (Join-Path $HOME '.bashcuts-cache') 'azure-devops'
    return [PSCustomObject]@{
        Dir       = $cacheDir
        Assigned  = Join-Path $cacheDir 'assigned.json'
        Mentions  = Join-Path $cacheDir 'mentions.json'
        Hierarchy = Join-Path $cacheDir 'hierarchy.json'
        LastSync  = Join-Path $cacheDir 'last-sync.json'
        Log       = Join-Path $cacheDir 'sync.log'
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


function Invoke-AzDevOpsBoardsQuery {
    param([Parameter(Mandatory)] [string] $Wiql)

    # Redirecting stderr to a temp file (rather than $null or 2>&1) lets us
    # keep stdout JSON parseable while still preserving the az error text for
    # callers to surface to the user / log on failure.
    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $json = az boards query --wiql $Wiql --output json 2>$stderrFile
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


# ---------------------------------------------------------------------------
# Sync helpers — extracted so Sync-AzDevOpsCache stays a small orchestrator
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

    return @(
        @{
            Name  = 'assigned'
            Label = 'System.AssignedTo = @Me'
            Path  = $Paths.Assigned
            Wiql  = 'Select [System.Id], [System.Title], [System.WorkItemType], [System.State], [System.IterationPath], [System.ChangedDate] From WorkItems Where [System.AssignedTo] = @Me'
        },
        @{
            Name  = 'mentions'
            Label = "System.History Contains '$mentionsToken'"
            Path  = $Paths.Mentions
            Wiql  = "Select [System.Id], [System.Title], [System.WorkItemType], [System.State] From WorkItems Where [System.History] Contains '$mentionsToken'"
        },
        @{
            Name  = 'hierarchy'
            Label = 'Epic/Feature/Story hierarchy in @Project'
            Path  = $Paths.Hierarchy
            # Flat work-items query (not link-mode): az boards query resolves
            # System.Parent + the rest of the fields for each item in one shot,
            # giving Show-AzDevOpsTree everything it needs without re-calling az.
            Wiql  = "Select [System.Id], [System.Title], [System.WorkItemType], [System.State], [System.Parent] From WorkItems Where [System.TeamProject] = @Project AND [System.WorkItemType] IN ('Epic', 'Feature', 'User Story')"
        }
    )
}


function Invoke-AzDevOpsDatasetSync {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Label,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Wiql
    )

    Write-Host "-> Querying $Name ($Label)..." -ForegroundColor Cyan

    $sw      = [System.Diagnostics.Stopwatch]::StartNew()
    $result  = Invoke-AzDevOpsBoardsQuery -Wiql $Wiql
    $sw.Stop()
    $elapsed = '{0:N1}s' -f $sw.Elapsed.TotalSeconds

    if ($result.ExitCode -ne 0) {
        $firstLine = Get-AzDevOpsFirstStderrLine -Stderr $result.Error
        if (-not $firstLine) { $firstLine = "az exited with code $($result.ExitCode)" }

        Write-Host "  X $Name - $firstLine (in $elapsed)" -ForegroundColor Red
        Write-AzDevOpsSyncStderr -DatasetName $Name -ExitCode $result.ExitCode -Elapsed $elapsed -Stderr $result.Error

        return New-AzDevOpsDatasetStatus -Status 'error' -Message $result.Error -Elapsed $elapsed
    }

    try {
        $parsed = $result.Json | ConvertFrom-Json
    } catch {
        $msg = $_.Exception.Message
        Write-Host "  X $Name - parse failed: $msg (in $elapsed)" -ForegroundColor Red
        Write-AzDevOpsSyncLog "ERROR $Name parse failed (elapsed=$elapsed): $msg"
        return New-AzDevOpsDatasetStatus -Status 'error' -Message "parse failed: $msg" -Elapsed $elapsed
    }

    $count  = @($parsed).Count
    $pretty = $parsed | ConvertTo-Json -Depth 10
    Write-AzDevOpsCacheFile -Path $Path -Content $pretty
    Write-Host "  OK  $Name - $count rows in $elapsed" -ForegroundColor Green
    Write-AzDevOpsSyncLog "$Name wrote $count rows in $elapsed"

    return New-AzDevOpsDatasetStatus -Status 'ok' -Rows $count -Elapsed $elapsed
}


function Sync-AzDevOpsCache {
    if (-not (Test-AzDevOpsAuth)) {
        Write-Host "Sync-AzDevOpsCache aborted - Test-AzDevOpsAuth returned false. Run Connect-AzDevOps." -ForegroundColor Red
        return
    }

    $paths = Initialize-AzDevOpsCacheDir
    Write-AzDevOpsSyncLog 'sync started'

    $datasets = Get-AzDevOpsSyncDatasets -Paths $paths

    $counts   = [ordered]@{}
    $statuses = [ordered]@{}
    $errored  = 0

    foreach ($ds in $datasets) {
        $status = Invoke-AzDevOpsDatasetSync @ds
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


function Get-AzDevOpsCacheStatus {
    $cacheAge = Get-AzDevOpsCacheAge
    if ($null -eq $cacheAge) {
        Write-Host "No cache yet - run Sync-AzDevOpsCache" -ForegroundColor Yellow
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
# Scheduling helpers — shared by Register-/Unregister-AzDevOpsSyncSchedule
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
    return "0 */$hours * * * $PwshPath -Command `"Sync-AzDevOpsCache`" $tag"
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


function Register-AzDevOpsSyncSchedule {
    $platform = Get-AzDevOpsPlatform
    # Loads the user's $profile so $env:AZ_* and the dot-sourced module are
    # available; without -NoProfile, the scheduled invocation has the same
    # context as an interactive shell.
    $pwshPath = (Get-Process -Id $PID).Path
    $hours    = Get-AzDevOpsSyncIntervalHours

    if ($platform -eq 'Windows') {
        $taskName = Get-AzDevOpsScheduledTaskName
        $action   = New-ScheduledTaskAction -Execute $pwshPath -Argument "-Command `"Sync-AzDevOpsCache`""
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

    Write-Host "Unsupported OS for Register-AzDevOpsSyncSchedule" -ForegroundColor Red
}


function Unregister-AzDevOpsSyncSchedule {
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

    Write-Host "Unsupported OS for Unregister-AzDevOpsSyncSchedule" -ForegroundColor Red
}


# ---------------------------------------------------------------------------
# Cache consumers - read-only commands that surface cached work items
#
# Public functions:
#   Get-AzDevOpsAssigned   - table of work items assigned to me
#   Open-AzDevOpsAssigned  - open a single assigned item in the browser
#
# Both functions read $HOME/.bashcuts-cache/azure-devops/assigned.json (built
# by Sync-AzDevOpsCache). They never call `az` directly - if the cache is
# missing, they print a hint and bail.
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
        Write-Host "  Run: Sync-AzDevOpsCache              # one-shot refresh" -ForegroundColor Yellow
        Write-Host "  Run: Register-AzDevOpsSyncSchedule   # recurring refresh (~5h)" -ForegroundColor Yellow
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


function Read-AzDevOpsAssignedCache {
    $paths = Get-AzDevOpsCachePaths
    $items = Read-AzDevOpsJsonCache `
        -Path        $paths.Assigned `
        -Description 'assigned-items' `
        -Converter   { param($r) ConvertFrom-AzDevOpsAssignedItem -Raw $r }
    return $items
}


function Get-AzDevOpsAssigned {
    [CmdletBinding()]
    param(
        [string[]] $State
    )

    $items = Read-AzDevOpsAssignedCache
    if ($null -eq $items) { return }

    $cacheAge = Get-AzDevOpsCacheAge
    if ($cacheAge -and $cacheAge.IsStale) {
        Write-Host "WARNING stale (last sync: $($cacheAge.AgeText))" -ForegroundColor Yellow
    }

    $filtered = if ($State) {
        $items | Where-Object { $_.State -in $State }
    } else {
        $items | Where-Object { $_.State -notin @('Closed', 'Removed') }
    }

    $titleMaxLen = 80

    return $filtered | Select-Object Id, Type, State,
        @{ Name = 'Title'; Expression = {
            if ($_.Title -and $_.Title.Length -gt $titleMaxLen) {
                $_.Title.Substring(0, $titleMaxLen - 3) + '...'
            } else {
                $_.Title
            }
        } },
        Iteration, AssignedAt
}


function Open-AzDevOpsAssigned {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [int] $Id
    )

    $items = Read-AzDevOpsAssignedCache
    if ($null -eq $items) { return }

    $match = $items | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $match) {
        Write-Host "Work item $Id is not in your assigned-items cache." -ForegroundColor Red
        Write-Host "  Tip: run Get-AzDevOpsAssigned to list valid IDs, or Sync-AzDevOpsCache to refresh." -ForegroundColor Yellow
        $global:LASTEXITCODE = 1
        return
    }

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


# ---------------------------------------------------------------------------
# Hierarchy tree view
#
# Public function:
#   Show-AzDevOpsTree   - prints the project's Epic/Feature/User Story tree
#                          from the cached hierarchy.json (no `az` calls)
#
# Reads $HOME/.bashcuts-cache/azure-devops/hierarchy.json (built by
# Sync-AzDevOpsCache). The hierarchy WIQL selects [System.Parent] so each
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

    $indent    = '    ' * $Depth
    $icon      = Get-AzDevOpsTreeIcon -Type $Item.Type
    $separator = "$([char]0x2014)"   # em-dash

    # User Story lines drop the type label per the issue spec; epics + features
    # keep it so '📦 Epic 1234' / '🎯 Feature 1240' read clearly.
    if ($Item.Type -eq 'User Story') {
        return "$indent$icon $($Item.Id) $separator $($Item.Title) [$($Item.State)]"
    }

    return "$indent$icon $($Item.Type) $($Item.Id) $separator $($Item.Title) [$($Item.State)]"
}


function Show-AzDevOpsTree {
    [CmdletBinding()]
    param()

    $items = Read-AzDevOpsHierarchyCache
    if ($null -eq $items) { return }

    $cacheAge = Get-AzDevOpsCacheAge
    if ($cacheAge -and $cacheAge.IsStale) {
        Write-Host "WARNING stale (last sync: $($cacheAge.AgeText))" -ForegroundColor Yellow
    }

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
            Write-Output '    (no features)'
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
