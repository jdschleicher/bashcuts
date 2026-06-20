# ============================================================================
# Azure DevOps — Cache sync engine + on-open background refresh
# ============================================================================
# Backs az-Sync-AzDevOpsCache (the orchestrator), az-Get-AzDevOpsCacheStatus
# (table-of-staleness reader), and Start-AzDevOpsBackgroundSync (the silent
# on-shell-open refresh that spawns a detached, hidden pwsh when the cache has
# gone stale).
#
# Loaded by powcuts_home.ps1. See azdevops_auth.ps1 for the master docstring.

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
    $activityWiql = Get-AzDevOpsWiql -Name 'activity'

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
            Name     = 'activity'
            Label    = 'System.ChangedBy = @Me (from activity.wiql)'
            Path     = $Paths.Activity
            Fetch    = { Invoke-AzDevOpsBoardsQuery -Wiql $activityWiql }.GetNewClosure()
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

    if (Get-Command Clear-AzDevOpsClassificationMemo -ErrorAction SilentlyContinue) {
        Clear-AzDevOpsClassificationMemo
    }

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
# Platform helper — kept here (rather than inlined) because azdevops_schema.ps1
# also branches on it (CLAUDE.md explicitly names Get-AzDevOpsPlatform).
# ---------------------------------------------------------------------------

function Get-AzDevOpsPlatform {
    if ($IsWindows -or ($env:OS -eq 'Windows_NT')) { return 'Windows' }
    if ($IsMacOS -or $IsLinux) { return 'Posix' }
    return 'Unknown'
}


# ---------------------------------------------------------------------------
# On-open background refresh
#
# Start-AzDevOpsBackgroundSync runs on shell open (invoked from powcuts_home.ps1
# after every azdevops_*.ps1 file is dot-sourced, so the active-project cache
# path resolves correctly). It keeps the foreground gate cheap — opt-out env
# var, az present, stale/missing cache, no active lock — then spawns a detached,
# hidden pwsh running az-Sync-AzDevOpsCache so the interactive prompt is never
# blocked. The network auth check is intentionally NOT done in the foreground
# (az-Test-AzDevOpsAuth runs a smoke query that would stall the shell); it lives
# inside the child instead, where az-Sync-AzDevOpsCache calls
# Assert-AzDevOpsAuthOrAbort and exits quietly if the session isn't connected.
# ---------------------------------------------------------------------------

function Get-AzDevOpsAutoSyncOptOutVar {
    return 'AZ_DEVOPS_NO_AUTOSYNC'
}


function Get-AzDevOpsAutoSyncChildVar {
    return 'AZ_DEVOPS_AUTOSYNC_CHILD'
}


function Get-AzDevOpsAutoSyncLockMaxAgeMinutes {
    return 30
}


function Get-AzDevOpsAutoSyncLockPath {
    $paths = Get-AzDevOpsCachePaths
    $lockPath = Join-Path $paths.Dir 'autosync.lock'
    return $lockPath
}


function Test-AzDevOpsAutoSyncLockActive {
    # A lock younger than the TTL means another terminal (or an in-flight child)
    # already kicked a sync, so this open should not spawn another. A stale lock
    # (older than the TTL, e.g. a crashed child) is treated as inactive so a
    # later open can retry.
    param([Parameter(Mandatory)] [string] $LockPath)

    if (-not (Test-Path -LiteralPath $LockPath)) {
        return $false
    }

    $lockAge = (Get-Date) - (Get-Item -LiteralPath $LockPath).LastWriteTime
    $maxAge = Get-AzDevOpsAutoSyncLockMaxAgeMinutes

    $isActive = ($lockAge.TotalMinutes -lt $maxAge)
    return $isActive
}


function Start-AzDevOpsBackgroundSync {
    $childVar = Get-AzDevOpsAutoSyncChildVar
    if ([Environment]::GetEnvironmentVariable($childVar)) {
        return
    }

    $optOutVar = Get-AzDevOpsAutoSyncOptOutVar
    if ([Environment]::GetEnvironmentVariable($optOutVar)) {
        return
    }

    if (-not (Test-AzDevOpsCliPresent)) {
        return
    }

    $cacheAge = Get-AzDevOpsCacheAge
    $isStale = ($null -eq $cacheAge) -or $cacheAge.IsStale
    if (-not $isStale) {
        return
    }

    $lockPath = Get-AzDevOpsAutoSyncLockPath
    if (Test-AzDevOpsAutoSyncLockActive -LockPath $lockPath) {
        return
    }

    $paths = Initialize-AzDevOpsCacheDir
    Set-Content -LiteralPath $lockPath -Value (Get-Date).ToString('o')

    $pwshPath = (Get-Process -Id $PID).Path

    # Set the child marker on this process's environment so the spawned pwsh —
    # which loads $profile to pull in az-Sync-AzDevOpsCache and $env:AZ_* — sees
    # it during its own profile load and skips re-spawning (no infinite cascade).
    # Start-Process snapshots the environment at creation, so clearing the marker
    # immediately afterward leaves the parent session clean.
    [Environment]::SetEnvironmentVariable($childVar, '1')
    try {
        Start-Process -FilePath $pwshPath `
            -ArgumentList '-Command', 'az-Sync-AzDevOpsCache' `
            -WindowStyle Hidden
    }
    finally {
        [Environment]::SetEnvironmentVariable($childVar, $null)
    }
}
