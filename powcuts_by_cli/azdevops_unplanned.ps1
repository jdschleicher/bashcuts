# ============================================================================
# Azure DevOps — Unplanned / firefighting work sessions
# ============================================================================
# A free-for-all companion to the Pomodoro timer (pow_timer.ps1) for work that
# can't be time-boxed. Each day rolls up under a single "Unplanned Work" User
# Story; every firefight you start becomes a child Task with its own debrief.
#
# Public surface:
#   az-Start-UnplannedWork      - find-or-create today's daily story, create a
#                              child Task for this firefight, then run a
#                              foreground session: press Space to log an item,
#                              Esc/Q to stop and debrief. A reminder balloon
#                              pops every -ReminderMinutes until you stop. On
#                              stop the captured items flush to the Task
#                              description and a debrief comment is posted.
#   az-New-UnplannedWorkDebrief - read the day's ledger, total the time across all
#                              firefights, and post a roll-up comment on the
#                              daily story.
#
# Like pow_timer.ps1 this is PowerShell-only - the Windows balloon reminder and
# the non-blocking key poll have no bash counterpart.
#
# Loaded by powcuts_home.ps1. See azdevops_auth.ps1 for the master docstring.

$script:UnplannedStoryTitlePrefix       = 'Unplanned Work'
$script:UnplannedTitleDash              = "$([char]0x2014)"            # em dash
$script:UnplannedDefaultReminderMinutes = 5
$script:UnplannedDefaultStoryPriority   = 2
$script:UnplannedPollIntervalMs         = 100
$script:UnplannedPollsPerSecond         = 10

$script:UnplannedIconFire   = [char]::ConvertFromUtf32(0x1F525)   # fire
$script:UnplannedIconMemo   = [char]::ConvertFromUtf32(0x1F4DD)   # memo
$script:UnplannedIconClock  = [char]::ConvertFromUtf32(0x23F0)    # alarm clock
$script:UnplannedIconCheck  = [char]::ConvertFromUtf32(0x2705)    # check mark
$script:UnplannedIconRocket = [char]::ConvertFromUtf32(0x1F680)   # rocket
$script:UnplannedIconBullet = [char]::ConvertFromUtf32(0x2022)    # bullet


function Test-UnplannedIsWindows {
    $isWin = ($IsWindows -or ($env:OS -eq 'Windows_NT'))
    return $isWin
}


function Read-UnplannedYesNo {
    param([Parameter(Mandatory)] [string] $Prompt)

    $raw = Read-Host "$Prompt [y/N]"
    if (-not $raw) {
        return $false
    }

    $normalized = $raw.Trim().ToLowerInvariant()
    $result = ($normalized -eq 'y' -or $normalized -eq 'yes')
    return $result
}


function Format-UnplannedElapsed {
    # mm:ss for short firefights, h:mm:ss once a session crosses the hour mark
    # (unplanned work has no fixed cap, unlike the Pomodoro countdown).
    param([Parameter(Mandatory)] [int] $Seconds)

    $ts = [TimeSpan]::FromSeconds($Seconds)
    $display = if ($ts.TotalHours -ge 1) {
        '{0:00}:{1:00}:{2:00}' -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds
    } else {
        '{0:00}:{1:00}' -f $ts.Minutes, $ts.Seconds
    }

    return $display
}


function Get-UnplannedWorkDailyStoryTitle {
    param([datetime] $Date = (Get-Date))

    $stamp  = $Date.ToString('yyyy-MM-dd')
    $prefix = $script:UnplannedStoryTitlePrefix
    $dash   = $script:UnplannedTitleDash
    $title  = "$prefix $dash $stamp"

    return $title
}


function Find-UnplannedWorkStoryId {
    # WIQL lookup for an existing daily story by exact title. Narrowed to
    # $env:AZ_AREA when set so a same-named story in another area doesn't match.
    # Returns the work-item id, or 0 when none exists / the query fails.
    param([Parameter(Mandatory)] [string] $Title)

    $titleLiteral = $Title.Replace("'", "''")
    $wiql = "SELECT [System.Id] FROM WorkItems WHERE [System.WorkItemType] = 'User Story' AND [System.Title] = '$titleLiteral'"

    if ($env:AZ_AREA) {
        $areaLiteral = $env:AZ_AREA.Replace("'", "''")
        $wiql = "$wiql AND [System.AreaPath] UNDER '$areaLiteral'"
    }

    $result = Invoke-AzDevOpsBoardsQuery -Wiql $wiql
    if ($result.ExitCode -ne 0) {
        Write-Host "Could not query for the daily story: $($result.Error)" -ForegroundColor Red
        return 0
    }

    try {
        $parsed = $result.Json | ConvertFrom-Json
    }
    catch {
        return 0
    }

    $rows = @($parsed)
    if ($rows.Count -eq 0) {
        return 0
    }

    $first = $rows[0]
    $id = if ($first.id) {
        [int]$first.id
    } else {
        [int]$first.fields.'System.Id'
    }

    return $id
}


function New-UnplannedWorkStory {
    # Creates the daily catch-all User Story via the shared create path so
    # priority / area / iteration / schema handling matches az-New-AzDevOps*.
    # Returns the new id, or 0 on failure.
    param([Parameter(Mandatory)] [string] $Title)

    $resolved = Resolve-AzDevOpsIterationArea -Type 'USER_STORY'
    if (-not $resolved.Ok) {
        return 0
    }

    $description = 'Daily catch-all for unplanned / firefighting work. Each firefight is a child Task with its own debrief.'

    $createArgs = @{
        Title              = $Title
        Description        = $description
        Priority           = $script:UnplannedDefaultStoryPriority
        StoryPoints        = -1
        AcceptanceCriteria = ''
        Iteration          = $resolved.Iteration
        Area               = $resolved.Area
    }

    $created = Invoke-AzDevOpsWorkItemCreate @createArgs
    if (-not $created.Ok) {
        Write-Host "Failed to create the daily Unplanned Work story: $($created.Error)" -ForegroundColor Red
        return 0
    }

    $newId = $created.Id
    return $newId
}


function Get-UnplannedWorkDailyStory {
    # Find-or-create today's daily story. -NoCreate returns 0 instead of
    # creating when none exists (used by the daily-debrief reader).
    param([switch] $NoCreate)

    $title = Get-UnplannedWorkDailyStoryTitle

    $existingId = Find-UnplannedWorkStoryId -Title $title
    if ($existingId -gt 0) {
        Write-Host "Using existing daily story #$existingId : $title" -ForegroundColor DarkGray
        return $existingId
    }

    if ($NoCreate) {
        return 0
    }

    Write-Host "No daily story for today yet - creating '$title'..." -ForegroundColor Cyan
    $newId = New-UnplannedWorkStory -Title $title
    return $newId
}


function New-UnplannedWorkTask {
    # Creates the firefight Task and links it to the daily story as a child.
    # Tasks carry no priority / story-points / acceptance-criteria in the stock
    # templates, so this goes straight through New-AzDevOpsWorkItem rather than
    # Invoke-AzDevOpsWorkItemCreate (which always stamps those fields). Returns
    # the new Task id, or 0 on create failure; a link failure is surfaced but
    # still returns the id so the session can proceed.
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [int]    $StoryId
    )

    $created = New-AzDevOpsWorkItem `
        -Type       'Task' `
        -Title      $Title `
        -AssignedTo $env:AZ_USER_EMAIL `
        -Area       $env:AZ_AREA `
        -Iteration  $env:AZ_ITERATION

    if ($created.ExitCode -ne 0) {
        Write-Host "Failed to create the firefight Task: $($created.Error)" -ForegroundColor Red
        return 0
    }

    try {
        $taskObj = $created.Json | ConvertFrom-Json
    }
    catch {
        Write-Host "Created the Task but could not parse its id." -ForegroundColor Red
        return 0
    }

    $taskId = [int]$taskObj.id

    $link = Invoke-AzDevOpsParentLink -Id $taskId -ParentId $StoryId
    if (-not $link.Ok) {
        Write-Host "Task #$taskId created but linking to story #$StoryId failed: $($link.Error)" -ForegroundColor Yellow
        Write-Host "  Re-link manually if needed." -ForegroundColor Yellow
    }

    return $taskId
}


function New-UnplannedBalloon {
    # One reusable NotifyIcon for the whole session - reused on each reminder
    # tick and disposed in the orchestrator's finally so a multi-hour session
    # doesn't accumulate tray icons. Returns $null off Windows or when the
    # Windows.Forms types aren't available, in which case reminders no-op.
    if (-not (Test-UnplannedIsWindows)) {
        return $null
    }

    try {
        if (-not ([System.Management.Automation.PSTypeName]'System.Windows.Forms.NotifyIcon').Type) {
            Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        }

        $balloon = New-Object System.Windows.Forms.NotifyIcon
        $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon((Get-Process -Id $PID).Path)
        $balloon.Visible = $true
        return $balloon
    }
    catch {
        return $null
    }
}


function Show-UnplannedReminder {
    param(
        $Balloon,
        [Parameter(Mandatory)] [int]    $TaskId,
        [Parameter(Mandatory)] [string] $TaskTitle
    )

    if ($null -eq $Balloon) {
        return
    }

    $iconFire = $script:UnplannedIconFire

    $Balloon.BalloonTipIcon  = [System.Windows.Forms.ToolTipIcon]::Warning
    $Balloon.BalloonTipTitle = "$iconFire Unplanned work in progress"
    $Balloon.BalloonTipText  = "Task #$TaskId still open: $TaskTitle. Space = log item, Esc = stop."
    $Balloon.ShowBalloonTip(0)
}


function Read-UnplannedKeyPress {
    # Non-blocking probe. Returns 'space', 'stop' (Esc or Q), or '' when no key
    # is waiting. Guarded so the loop still runs in hosts without a console
    # keyboard - there the session becomes time-only (reminders still fire,
    # Space/Esc are disabled) until the user closes the terminal.
    try {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)

            if ($key.Key -eq [ConsoleKey]::Spacebar) {
                return 'space'
            }

            if ($key.Key -eq [ConsoleKey]::Escape -or $key.Key -eq [ConsoleKey]::Q) {
                return 'stop'
            }
        }
    }
    catch {
        # Host does not expose console keyboard - treat as no key pressed.
    }

    return ''
}


function Show-UnplannedStatus {
    param(
        [Parameter(Mandatory)] [int]    $TaskId,
        [Parameter(Mandatory)] [string] $TaskTitle,
        [Parameter(Mandatory)] [int]    $ElapsedSeconds,
        [Parameter(Mandatory)] [int]    $ItemCount,
        [Parameter(Mandatory)] [int]    $ReminderMinutes
    )

    $iconFire  = $script:UnplannedIconFire
    $iconClock = $script:UnplannedIconClock
    $elapsed   = Format-UnplannedElapsed -Seconds $ElapsedSeconds

    Clear-Host
    Write-Host ""
    Write-Host "  $iconFire UNPLANNED WORK SESSION" -ForegroundColor Red
    Write-Host "  Task #$TaskId  $TaskTitle" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  $iconClock Elapsed: $elapsed     Items captured: $ItemCount" -ForegroundColor Cyan
    Write-Host "  Reminder every $ReminderMinutes min" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [Space] log an item     [Esc/Q] stop and debrief" -ForegroundColor DarkGray
}


function Format-UnplannedItemsDescription {
    # Composes the Task description from the captured items as a single physical
    # line with <br/> separators - same cmd.exe-CRLF-truncation guard the timer
    # uses for its discussion body (see Format-TimerCommentBody).
    param(
        [Parameter(Mandatory)] [string] $TaskTitle,
        [object[]] $Items
    )

    $bullet = $script:UnplannedIconBullet
    $header = "Unplanned work log: $TaskTitle"
    $lines  = @($header, '')

    if (@($Items).Count -eq 0) {
        $lines += '(no items captured)'
    } else {
        foreach ($entry in $Items) {
            $lines += "$bullet [$($entry.Time)] $($entry.Text)"
        }
    }

    $body = $lines -join '<br/>'
    return $body
}


function Format-UnplannedDebriefComment {
    param(
        [Parameter(Mandatory)] [int]    $ElapsedMinutes,
        [Parameter(Mandatory)] [int]    $ItemCount,
        [string] $Debrief,
        [string] $FutureFeature
    )

    $iconCheck  = $script:UnplannedIconCheck
    $iconMemo   = $script:UnplannedIconMemo
    $iconRocket = $script:UnplannedIconRocket
    $timestamp  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    $lines = @(
        "$iconCheck Unplanned work debrief - $ElapsedMinutes min, $ItemCount item(s)",
        "<em>$timestamp</em>",
        ''
    )

    if ($Debrief) {
        $lines += "$iconMemo Debrief:"
        $lines += $Debrief
        $lines += ''
    }

    if ($FutureFeature) {
        $lines += "$iconRocket Future opportunity:"
        $lines += $FutureFeature
        $lines += ''
    }

    $lines += '<em>via bashcuts az-Start-UnplannedWork</em>'

    $body = $lines -join '<br/>'
    return $body
}


function Get-UnplannedLedgerPath {
    # Per-day ledger under the AzDO cache dir so az-New-UnplannedWorkDebrief can
    # total time across firefights (AzDO doesn't store our per-session minutes).
    # Returns $null when the cache layout isn't available.
    param([datetime] $Date = (Get-Date))

    if (-not (Get-Command Get-AzDevOpsCachePaths -ErrorAction SilentlyContinue)) {
        return $null
    }

    $paths = Get-AzDevOpsCachePaths
    if (-not $paths.Dir) {
        return $null
    }

    $stamp = $Date.ToString('yyyy-MM-dd')
    $path  = Join-Path $paths.Dir "unplanned-$stamp.json"
    return $path
}


function Add-UnplannedLedgerEntry {
    param(
        [Parameter(Mandatory)] [int]    $StoryId,
        [Parameter(Mandatory)] [int]    $TaskId,
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [int]    $Minutes,
        [Parameter(Mandatory)] [int]    $ItemCount
    )

    $path = Get-UnplannedLedgerPath
    if (-not $path) {
        return
    }

    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $existing = @()
    if (Test-Path -LiteralPath $path) {
        try {
            $existing = @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
        }
        catch {
            $existing = @()
        }
    }

    $entry = [PSCustomObject]@{
        StoryId   = $StoryId
        TaskId    = $TaskId
        Title     = $Title
        Minutes   = $Minutes
        ItemCount = $ItemCount
        EndedAt   = (Get-Date).ToString('o')
    }

    $all  = @($existing) + $entry
    $json = ConvertTo-Json -InputObject @($all) -Depth 5 -AsArray
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
}


function Format-UnplannedDailyDebrief {
    param(
        [Parameter(Mandatory)] [object[]] $Entries,
        [Parameter(Mandatory)] [int]      $TotalMinutes,
        [datetime] $Date = (Get-Date)
    )

    $iconCheck = $script:UnplannedIconCheck
    $iconClock = $script:UnplannedIconClock
    $bullet    = $script:UnplannedIconBullet
    $stamp     = $Date.ToString('yyyy-MM-dd')

    $lines = @(
        "$iconCheck Unplanned work daily roll-up - $stamp",
        "$iconClock $($Entries.Count) firefight(s), $TotalMinutes min total",
        ''
    )

    foreach ($e in $Entries) {
        $lines += "$bullet Task #$($e.TaskId) - $($e.Minutes) min, $($e.ItemCount) item(s): $($e.Title)"
    }

    $lines += ''
    $lines += '<em>via bashcuts az-New-UnplannedWorkDebrief</em>'

    $body = $lines -join '<br/>'
    return $body
}


function Invoke-UnplannedDebrief {
    # Stop-of-session tail, split out of az-Start-UnplannedWork so the orchestrator
    # reads as gate -> story -> task -> loop -> debrief. Flushes the captured
    # items to the Task description, prompts for debrief notes + an optional
    # future-feature opportunity (offering to create a user story for it via
    # az-New-AzDevOpsUserStory), posts the debrief comment, and records the
    # session in the day's ledger. Elapsed minutes come from $StartTime so the
    # recorded time is accurate regardless of the on-screen counter.
    param(
        [Parameter(Mandatory)] [int]      $TaskId,
        [Parameter(Mandatory)] [int]      $StoryId,
        [Parameter(Mandatory)] [string]   $Title,
        [Parameter(Mandatory)] [datetime] $StartTime,
        [object[]] $Items
    )

    $itemList = @($Items)

    $elapsedMinutes = [int][math]::Round(((Get-Date) - $StartTime).TotalMinutes)
    if ($elapsedMinutes -lt 1) {
        $elapsedMinutes = 1
    }

    Clear-Host
    $iconCheck = $script:UnplannedIconCheck
    Write-Host "$iconCheck Unplanned session complete - $elapsedMinutes min, $($itemList.Count) item(s)." -ForegroundColor Green
    Write-Host ""

    $descriptionBody = Format-UnplannedItemsDescription -TaskTitle $Title -Items $itemList
    Write-Host "Updating Task #$TaskId description with captured items..." -ForegroundColor Cyan
    $descResult = Set-AzDevOpsWorkItemField -Id $TaskId -Fields @("System.Description=$descriptionBody")
    if ($descResult.ExitCode -ne 0) {
        Write-Host "  Could not update description: $($descResult.Error)" -ForegroundColor Yellow
    }

    $iconMemo = $script:UnplannedIconMemo
    $debrief = Read-Host "$iconMemo Debrief notes for this firefight"

    $futureFeature = ''
    if (Read-UnplannedYesNo -Prompt 'Is there an opportunity for a new feature / user story to prevent this firefight in future?') {
        $futureFeature = Read-Host '  Describe the opportunity (one line)'

        if ($futureFeature -and (Read-UnplannedYesNo -Prompt '  Create that user story now?')) {
            if (Get-Command az-New-AzDevOpsUserStory -ErrorAction SilentlyContinue) {
                az-New-AzDevOpsUserStory -Title $futureFeature | Out-Null
            }
        }
    }

    $commentBody = Format-UnplannedDebriefComment `
        -ElapsedMinutes $elapsedMinutes `
        -ItemCount      $itemList.Count `
        -Debrief        $debrief `
        -FutureFeature  $futureFeature

    Write-Host ""
    Write-Host "Posting debrief comment to Task #$TaskId..." -ForegroundColor Cyan
    $commentResult = Add-AzDevOpsDiscussionComment -Id $TaskId -Body $commentBody
    if ($commentResult.ExitCode -eq 0) {
        Write-Host "$iconCheck Debrief posted on Task #$TaskId." -ForegroundColor Green
        Write-Host "   View: az-Open-AzDevOpsAssigned $TaskId" -ForegroundColor DarkGray
    } else {
        Write-Host "Debrief comment failed: $($commentResult.Error)" -ForegroundColor Red
    }

    Add-UnplannedLedgerEntry -StoryId $StoryId -TaskId $TaskId -Title $Title -Minutes $elapsedMinutes -ItemCount $itemList.Count
}


function az-Start-UnplannedWork {
    # Orchestrator. Find-or-create today's daily story, create a child Task for
    # this firefight, then run the foreground session: Space logs a timestamped
    # item, Esc/Q stops. A reminder balloon fires every -ReminderMinutes. On
    # stop the captured items flush to the Task description and a debrief comment
    # (time spent + notes + optional future-feature opportunity) is posted; the
    # session is recorded in the day's ledger for az-New-UnplannedWorkDebrief.
    #
    # UTF-8 output encoding is applied around the loop so the glyphs render in
    # non-UTF-8 codepages, and restored on exit (including Ctrl-C) via finally.
    [CmdletBinding()]
    param(
        [string] $Title,
        [ValidateRange(1, [int]::MaxValue)] [int] $ReminderMinutes = $script:UnplannedDefaultReminderMinutes,
        [switch] $NoReminder
    )

    if (-not (Test-AzDevOpsCreateGate -CommandName 'az-Start-UnplannedWork')) {
        return
    }

    $storyId = Get-UnplannedWorkDailyStory
    if ($storyId -le 0) {
        Write-Host "No daily Unplanned Work story available - aborting." -ForegroundColor Red
        return
    }

    if (-not $Title) {
        $Title = Read-Host 'What is this firefight about? (Task title)'
    }
    if (-not $Title) {
        Write-Host "Task title is required - aborting." -ForegroundColor Red
        return
    }

    $taskId = New-UnplannedWorkTask -Title $Title -StoryId $storyId
    if ($taskId -le 0) {
        Write-Host "Could not create the firefight Task - aborting." -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "Firefight Task #$taskId created under story #$storyId." -ForegroundColor Green
    Write-Host "Starting session. Space logs an item, Esc/Q stops and debriefs." -ForegroundColor Green
    Start-Sleep -Seconds 2

    $startTime = Get-Date
    $items = New-Object System.Collections.Generic.List[object]

    $balloon = if ($NoReminder) {
        $null
    } else {
        New-UnplannedBalloon
    }

    $previousEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    try {
        $reminderSeconds = $ReminderMinutes * 60
        $pollsPerSecond  = $script:UnplannedPollsPerSecond
        $pollIntervalMs  = $script:UnplannedPollIntervalMs

        $elapsed        = 0
        $lastReminderAt = 0
        $stopRequested  = $false

        Show-UnplannedStatus -TaskId $taskId -TaskTitle $Title -ElapsedSeconds 0 -ItemCount 0 -ReminderMinutes $ReminderMinutes

        while (-not $stopRequested) {
            for ($p = 0; $p -lt $pollsPerSecond; $p++) {
                $key = Read-UnplannedKeyPress

                if ($key -eq 'stop') {
                    $stopRequested = $true
                    break
                }

                if ($key -eq 'space') {
                    Write-Host ""
                    $itemText = Read-Host 'Log item'

                    if ($itemText) {
                        $record = [PSCustomObject]@{
                            Time = (Get-Date).ToString('HH:mm')
                            Text = $itemText
                        }
                        $items.Add($record)
                    }

                    $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
                    Show-UnplannedStatus -TaskId $taskId -TaskTitle $Title -ElapsedSeconds $elapsed -ItemCount $items.Count -ReminderMinutes $ReminderMinutes
                    break
                }

                Start-Sleep -Milliseconds $pollIntervalMs
            }

            if ($stopRequested) {
                break
            }

            # Drive the display from wall-clock, not the iteration count - the
            # space branch's blocking Read-Host means a single iteration can
            # span many seconds, so $elapsed++ would undercount.
            $elapsed = [int]((Get-Date) - $startTime).TotalSeconds

            Show-UnplannedStatus -TaskId $taskId -TaskTitle $Title -ElapsedSeconds $elapsed -ItemCount $items.Count -ReminderMinutes $ReminderMinutes

            if (-not $NoReminder -and ($elapsed - $lastReminderAt) -ge $reminderSeconds) {
                Show-UnplannedReminder -Balloon $balloon -TaskId $taskId -TaskTitle $Title
                $lastReminderAt = $elapsed
            }
        }

        Invoke-UnplannedDebrief -TaskId $taskId -StoryId $storyId -Title $Title -StartTime $startTime -Items @($items)
    }
    finally {
        [Console]::OutputEncoding = $previousEncoding
        if ($null -ne $balloon) {
            $balloon.Dispose()
        }
    }
}


function az-New-UnplannedWorkDebrief {
    # End-of-day roll-up. Reads the day's ledger, totals time across firefights,
    # prints the per-Task breakdown, and (on confirm) posts a roll-up comment on
    # the daily story. -Date debriefs a past day's ledger.
    [CmdletBinding()]
    param([datetime] $Date = (Get-Date))

    if (-not (Test-AzDevOpsCreateGate -CommandName 'az-New-UnplannedWorkDebrief')) {
        return
    }

    $path = Get-UnplannedLedgerPath -Date $Date
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        Write-Host "No unplanned-work ledger for $($Date.ToString('yyyy-MM-dd'))." -ForegroundColor Yellow
        return
    }

    $entries = @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
    if ($entries.Count -eq 0) {
        Write-Host "Ledger is empty for $($Date.ToString('yyyy-MM-dd'))." -ForegroundColor Yellow
        return
    }

    $totalMinutes = [int]($entries | Measure-Object -Property Minutes -Sum).Sum
    $storyId = [int]$entries[0].StoryId

    Write-Host ""
    Write-Host "Unplanned work - $($Date.ToString('yyyy-MM-dd'))" -ForegroundColor Cyan
    foreach ($e in $entries) {
        Write-Host ("  Task #{0}  {1} min  {2} item(s)  {3}" -f $e.TaskId, $e.Minutes, $e.ItemCount, $e.Title)
    }
    Write-Host ("  Total: {0} firefight(s), {1} min" -f $entries.Count, $totalMinutes) -ForegroundColor Green

    if (-not (Read-UnplannedYesNo -Prompt "Post a roll-up debrief comment on story #${storyId}?")) {
        return
    }

    $body = Format-UnplannedDailyDebrief -Entries $entries -TotalMinutes $totalMinutes -Date $Date
    $result = Add-AzDevOpsDiscussionComment -Id $storyId -Body $body
    if ($result.ExitCode -eq 0) {
        Write-Host "Posted daily roll-up on story #$storyId." -ForegroundColor Green
    } else {
        Write-Host "Failed to post roll-up: $($result.Error)" -ForegroundColor Red
    }
}
