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
        return [PSCustomObject]@{ Ok = $false; FailMessage = 'az CLI missing' }
    }
    $azVersion = (az version --output json 2>$null | ConvertFrom-Json).'azure-cli'
    Write-Host "  OK  az CLI present (v$azVersion)" -ForegroundColor Green
    return [PSCustomObject]@{ Ok = $true; FailMessage = $null }
}


function Confirm-AzDevOpsExtension {
    if (-not (Test-AzDevOpsExtensionInstalled)) {
        Write-Host "  !  azure-devops extension not installed" -ForegroundColor Yellow
        $resp = Read-Host "    Install now? [Y/n]"
        if ($resp -match '^(n|no)$') {
            Write-Host "    Hint: az extension add --name azure-devops"
            return [PSCustomObject]@{ Ok = $false; FailMessage = 'extension missing' }
        }
        az extension add --name azure-devops 2>&1 | Out-Host
        if (-not (Test-AzDevOpsExtensionInstalled)) {
            return [PSCustomObject]@{ Ok = $false; FailMessage = 'extension install failed' }
        }
    }
    Write-Host "  OK  azure-devops extension installed" -ForegroundColor Green
    return [PSCustomObject]@{ Ok = $true; FailMessage = $null }
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
        return [PSCustomObject]@{ Ok = $false; FailMessage = 'env vars missing' }
    }
    Write-Host "  OK  AZ_DEVOPS_ORG = $env:AZ_DEVOPS_ORG" -ForegroundColor Green
    Write-Host "  OK  AZ_PROJECT    = $env:AZ_PROJECT" -ForegroundColor Green
    return [PSCustomObject]@{ Ok = $true; FailMessage = $null }
}


function Confirm-AzDevOpsLogin {
    if (-not (Test-AzDevOpsLoggedIn)) {
        Write-Host "  !  No active az login session" -ForegroundColor Yellow
        $resp = Read-Host "    Run 'az login' now? [Y/n]"
        if ($resp -match '^(n|no)$') {
            Write-Host "    Hint: az login"
            return [PSCustomObject]@{ Ok = $false; FailMessage = 'not logged in' }
        }
        az login | Out-Host
        if (-not (Test-AzDevOpsLoggedIn)) {
            return [PSCustomObject]@{ Ok = $false; FailMessage = 'az login failed' }
        }
    }
    $account = az account show --output json 2>$null | ConvertFrom-Json
    Write-Host "  OK  Logged in as $($account.user.name) (sub: $($account.name))" -ForegroundColor Green
    return [PSCustomObject]@{ Ok = $true; FailMessage = $null }
}


function Set-AzDevOpsDefaults {
    $configOutput = az devops configure --defaults "organization=$env:AZ_DEVOPS_ORG" "project=$env:AZ_PROJECT" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  X az devops configure failed" -ForegroundColor Red
        Write-Host "    $configOutput"
        return [PSCustomObject]@{ Ok = $false; FailMessage = 'configure failed' }
    }
    Write-Host "  OK  Defaults set: org=$env:AZ_DEVOPS_ORG project=$env:AZ_PROJECT" -ForegroundColor Green
    return [PSCustomObject]@{ Ok = $true; FailMessage = $null }
}


function Confirm-AzDevOpsSmokeQuery {
    $count = Invoke-AzDevOpsSmokeQuery
    if ($null -eq $count) {
        Write-Host "  X Smoke query failed" -ForegroundColor Red
        Write-Host "    Try: az boards query --wiql 'Select [System.Id] From WorkItems Where [System.AssignedTo] = @Me'"
        return [PSCustomObject]@{ Ok = $false; FailMessage = 'smoke query failed' }
    }
    Write-Host "  OK  Smoke test passed ($count items assigned to you)" -ForegroundColor Green
    return [PSCustomObject]@{ Ok = $true; FailMessage = $null }
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
    $json = az boards query --wiql $Wiql --output json 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $json
}


function Sync-AzDevOpsCache {
    if (-not (Test-AzDevOpsAuth)) {
        Write-Host "Sync-AzDevOpsCache aborted - Test-AzDevOpsAuth returned false. Run Connect-AzDevOps." -ForegroundColor Red
        return
    }

    $paths = Initialize-AzDevOpsCacheDir
    Write-AzDevOpsSyncLog 'sync started'

    # Mentions: WIQL has no first-class @-mention predicate. Best effort is
    # [System.History] Contains 'literal'. Prefer "@<user-email>" when set,
    # otherwise fall back to a bare "@" - the latter is noisy but at least
    # populates the cache shape so downstream commands keep working.
    $mentionsToken = if ($env:AZ_USER_EMAIL) { "@$env:AZ_USER_EMAIL" } else { '@' }

    $datasets = @(
        @{
            Name = 'assigned'
            Path = $paths.Assigned
            Wiql = 'Select [System.Id], [System.Title], [System.WorkItemType], [System.State] From WorkItems Where [System.AssignedTo] = @Me'
        },
        @{
            Name = 'mentions'
            Path = $paths.Mentions
            Wiql = "Select [System.Id], [System.Title], [System.WorkItemType], [System.State] From WorkItems Where [System.History] Contains '$mentionsToken'"
        },
        @{
            Name = 'hierarchy'
            Path = $paths.Hierarchy
            Wiql = "Select [System.Id], [System.Title], [System.WorkItemType], [System.State] From WorkItemLinks Where [Source].[System.TeamProject] = @Project AND [Source].[System.WorkItemType] IN ('Epic', 'Feature', 'User Story') AND [Target].[System.WorkItemType] IN ('Epic', 'Feature', 'User Story') AND [System.Links.LinkType] = 'System.LinkTypes.Hierarchy-Forward' Mode (MustContain)"
        }
    )

    $counts = [ordered]@{}
    foreach ($ds in $datasets) {
        $json = Invoke-AzDevOpsBoardsQuery -Wiql $ds.Wiql
        if ($null -eq $json) {
            Write-Host "  X $($ds.Name) query failed" -ForegroundColor Red
            Write-AzDevOpsSyncLog "ERROR $($ds.Name) query failed"
            continue
        }
        try {
            $parsed = $json | ConvertFrom-Json
        } catch {
            Write-Host "  X $($ds.Name) parse failed" -ForegroundColor Red
            Write-AzDevOpsSyncLog "ERROR $($ds.Name) parse failed"
            continue
        }
        $count  = @($parsed).Count
        $pretty = $parsed | ConvertTo-Json -Depth 10
        Write-AzDevOpsCacheFile -Path $ds.Path -Content $pretty
        $counts[$ds.Name] = $count
        Write-Host "  OK  $($ds.Name) - $count rows" -ForegroundColor Green
        Write-AzDevOpsSyncLog "$($ds.Name) wrote $count rows"
    }

    $lastSync = [PSCustomObject]@{
        Timestamp = (Get-Date).ToString('o')
        Counts    = $counts
    }
    Write-AzDevOpsCacheFile -Path $paths.LastSync -Content ($lastSync | ConvertTo-Json -Depth 5)
    Write-AzDevOpsSyncLog 'sync complete'
}


function Get-AzDevOpsCacheStatus {
    $paths = Get-AzDevOpsCachePaths
    if (-not (Test-Path -LiteralPath $paths.LastSync)) {
        Write-Host "No cache yet - run Sync-AzDevOpsCache" -ForegroundColor Yellow
        return
    }

    $info   = Get-Content -LiteralPath $paths.LastSync -Raw | ConvertFrom-Json
    $synced = [datetime]$info.Timestamp
    $age    = (Get-Date) - $synced

    $ageText = if ($age.TotalMinutes -lt 60) {
        "$([int]$age.TotalMinutes) min ago"
    } elseif ($age.TotalHours -lt 24) {
        "$([math]::Round($age.TotalHours, 1)) hours ago"
    } else {
        "$([int]$age.TotalDays) days ago"
    }

    if ($age.TotalHours -lt 6) {
        Write-Host "OK fresh - synced $ageText" -ForegroundColor Green
    } else {
        Write-Host "STALE - last synced $ageText" -ForegroundColor Yellow
    }

    if ($info.Counts) {
        $info.Counts.PSObject.Properties | ForEach-Object {
            Write-Host "  $($_.Name): $($_.Value) rows"
        }
    }
}


function Register-AzDevOpsSyncSchedule {
    $isWin    = $IsWindows -or ($env:OS -eq 'Windows_NT')
    $pwshPath = (Get-Process -Id $PID).Path
    # Loads the user's $profile so $env:AZ_* and the dot-sourced module are
    # available; without -NoProfile, the scheduled invocation has the same
    # context as an interactive shell.
    $command = 'Sync-AzDevOpsCache'

    if ($isWin) {
        $taskName = 'BashcutsAzDevOpsSync'
        $action   = New-ScheduledTaskAction -Execute $pwshPath -Argument "-Command `"$command`""
        $trigger  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) `
                        -RepetitionInterval (New-TimeSpan -Hours 5)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Force | Out-Null
        Write-Host "Registered: scheduled task '$taskName' (every 5 hours)" -ForegroundColor Green
        return
    }

    if ($IsMacOS -or $IsLinux) {
        $tag         = '# bashcuts-azdevops-sync'
        $cronLine    = "0 */5 * * * $pwshPath -Command `"$command`" $tag"
        $existingRaw = crontab -l 2>$null
        $existing    = if ($existingRaw) {
            @($existingRaw -split "`n" | Where-Object { $_ -and ($_ -notmatch [regex]::Escape($tag)) })
        } else { @() }
        $newCron = (@($existing) + $cronLine) -join "`n"
        $newCron | crontab -
        Write-Host "Registered: cron entry - $cronLine" -ForegroundColor Green
        return
    }

    Write-Host "Unsupported OS for Register-AzDevOpsSyncSchedule" -ForegroundColor Red
}


function Unregister-AzDevOpsSyncSchedule {
    $isWin = $IsWindows -or ($env:OS -eq 'Windows_NT')

    if ($isWin) {
        $taskName = 'BashcutsAzDevOpsSync'
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Host "Unregistered: scheduled task '$taskName'" -ForegroundColor Green
        } else {
            Write-Host "No scheduled task '$taskName' to remove" -ForegroundColor Yellow
        }
        return
    }

    if ($IsMacOS -or $IsLinux) {
        $tag         = '# bashcuts-azdevops-sync'
        $existingRaw = crontab -l 2>$null
        $existing    = if ($existingRaw) { @($existingRaw -split "`n") } else { @() }
        $filtered    = @($existing | Where-Object { $_ -and ($_ -notmatch [regex]::Escape($tag)) })
        if ($filtered.Count -eq ($existing | Where-Object { $_ }).Count) {
            Write-Host "No bashcuts-azdevops-sync cron entry to remove" -ForegroundColor Yellow
            return
        }
        ($filtered -join "`n") | crontab -
        Write-Host "Unregistered: removed bashcuts-azdevops-sync cron entry" -ForegroundColor Green
        return
    }

    Write-Host "Unsupported OS for Unregister-AzDevOpsSyncSchedule" -ForegroundColor Red
}
