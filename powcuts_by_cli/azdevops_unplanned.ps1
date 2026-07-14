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
#                              description and a debrief comment is posted - on
#                              Windows via the same themed WPF debrief form the
#                              Pomodoro timer uses (Show-WpfTimerDebrief),
#                              re-labelled for firefighting; on macOS/Linux via
#                              the terminal debrief.
#   New-UnplannedWorkDebrief - read the day's ledger, total the time across all
#                              firefights, and post a roll-up comment on the
#                              daily story.
#
# Both debriefs can tag teammates with real notifying @-mentions; that roster
# and picker are shared with the Pomodoro timer and live in azdevops_team.ps1
# (Select-AzDevOpsMention / Format-AzDevOpsMentionLine, cached via
# az-Sync-AzDevOpsTeam).
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


function Read-UnplannedParentFeature {
    # Interactive Story -> Feature parent pick for the daily catch-all story,
    # mirroring az-New-AzDevOpsUserStory: pick a Feature from the cached
    # hierarchy, and on an orphan pick offer to create one inline. Returns the
    # chosen Feature id, or 0 to leave the daily story parentless - a skipped or
    # failed pick must never block the firefight. Runs only when the daily story
    # is first created for the day (a cached / existing story skips it).
    $hierarchy = Read-AzDevOpsHierarchyCache
    if ($null -eq $hierarchy) {
        return 0
    }

    $featureId = Read-AzDevOpsFeaturePick -Hierarchy $hierarchy -ChildType 'USER_STORY'

    if ($featureId -eq 0) {
        $featureId = Resolve-AzDevOpsOrphanParent -ParentLabel 'Feature' -CreateParent {
            az-New-AzDevOpsFeature -NoChildStoriesPrompt -NoOpen
        }
    }

    return $featureId
}


function New-UnplannedWorkStory {
    # Creates the daily catch-all User Story via the shared create path so
    # priority / area / iteration / schema handling matches az-New-AzDevOps*.
    # Prompts once (first creation of the day) for a parent Feature so the day's
    # firefighting rolls up under a real Feature; a skipped / failed pick leaves
    # the story parentless rather than blocking the session. Returns the new id,
    # or 0 on failure. -Progress is the session's WPF progress controller (a
    # no-op stub off Windows); the parent pick is interactive, so the window is
    # suspended around it and the az writes report their step.
    param(
        [Parameter(Mandatory)] [string] $Title,
        [object] $Progress
    )

    if ($null -eq $Progress) {
        $Progress = New-WpfProgressWindow -Disabled
    }

    & $Progress.Suspend
    $featureId = Read-UnplannedParentFeature
    $resolved  = Resolve-AzDevOpsIterationArea -Type 'USER_STORY'
    & $Progress.Resume

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

    & $Progress.SetStatus 'Creating today''s story...'
    $created = Invoke-AzDevOpsWorkItemCreate @createArgs
    if (-not $created.Ok) {
        Write-Host "Failed to create the daily Unplanned Work story: $($created.Error)" -ForegroundColor Red
        return 0
    }

    $newId = $created.Id

    if ($featureId -gt 0) {
        & $Progress.SetStatus 'Linking story to Feature...'
        $link = Invoke-AzDevOpsParentLink -Id $newId -ParentId $featureId
        if (-not $link.Ok) {
            Write-Host "Story #$newId created but linking to Feature #$featureId failed: $($link.Error)" -ForegroundColor Yellow
            Write-Host "  Re-link manually if needed." -ForegroundColor Yellow
        }
    }

    return $newId
}


function Get-UnplannedStoryCachePath {
    # Per-day cache of today's daily-story id so a second firefight in the same
    # day grabs it instantly - no WIQL lookup, and no risk of two sessions
    # racing into creating duplicate daily stories. Lives next to the per-day
    # ledger under the AzDO cache dir. Returns $null when the cache layout isn't
    # available.
    param([datetime] $Date = (Get-Date))

    $stamp = $Date.ToString('yyyy-MM-dd')
    $path  = Get-AzDevOpsCacheFilePath -FileName "unplanned-story-$stamp.json"
    return $path
}


function Get-UnplannedCachedStoryId {
    # Read today's cached daily-story id, or 0 when nothing is cached / the
    # cache layout isn't available.
    param([datetime] $Date = (Get-Date))

    $path = Get-UnplannedStoryCachePath -Date $Date
    if (-not $path) {
        return 0
    }

    $rows = Read-AzDevOpsJsonArrayCache -Path $path
    if (@($rows).Count -eq 0) {
        return 0
    }

    $first = @($rows)[0]
    $id = [int]$first.StoryId
    return $id
}


function Save-UnplannedCachedStoryId {
    # Persist today's daily-story id so the next firefight grabs it without a
    # WIQL round-trip. Written the moment the story is found or created.
    param(
        [Parameter(Mandatory)] [int] $Id,
        [datetime] $Date = (Get-Date)
    )

    $path = Get-UnplannedStoryCachePath -Date $Date
    if (-not $path) {
        return
    }

    $entry = [PSCustomObject]@{
        StoryId  = $Id
        Title    = Get-UnplannedWorkDailyStoryTitle -Date $Date
        CachedAt = (Get-Date).ToString('o')
    }

    Save-AzDevOpsJsonArrayCache -Path $path -Items @($entry)
}


function Get-UnplannedWorkDailyStory {
    # Find-or-create today's daily story. Checks the per-day id cache first so a
    # repeat firefight grabs the story with no WIQL lookup (and two sessions
    # can't race into creating duplicates), then falls back to a WIQL lookup,
    # then creates. The resolved id is cached on the way out. -NoCreate returns
    # 0 instead of creating when none exists (used by the daily-debrief reader).
    # -Progress flows the session's WPF progress controller into the create path
    # so New-UnplannedWorkStory can report its az-boards steps.
    param(
        [switch] $NoCreate,
        [object] $Progress
    )

    $title = Get-UnplannedWorkDailyStoryTitle

    $cachedId = Get-UnplannedCachedStoryId
    if ($cachedId -gt 0) {
        Write-Host "Using cached daily story #$cachedId : $title" -ForegroundColor DarkGray
        return $cachedId
    }

    $existingId = Find-UnplannedWorkStoryId -Title $title
    if ($existingId -gt 0) {
        Save-UnplannedCachedStoryId -Id $existingId
        Write-Host "Using existing daily story #$existingId : $title" -ForegroundColor DarkGray
        return $existingId
    }

    if ($NoCreate) {
        return 0
    }

    Write-Host "No daily story for today yet - creating '$title'..." -ForegroundColor Cyan
    $newId = New-UnplannedWorkStory -Title $title -Progress $Progress
    if ($newId -gt 0) {
        Save-UnplannedCachedStoryId -Id $newId
    }

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
    if (-not (Test-WpfIsWindows)) {
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
        [Parameter(Mandatory)] [string] $TaskTitle
    )

    if ($null -eq $Balloon) {
        return
    }

    $iconFire = $script:UnplannedIconFire

    $Balloon.BalloonTipIcon  = [System.Windows.Forms.ToolTipIcon]::Warning
    $Balloon.BalloonTipTitle = "$iconFire Unplanned work in progress"
    $Balloon.BalloonTipText  = "Still firefighting: $TaskTitle. Space = log item, Esc = stop."
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
    Write-Host "  $TaskTitle" -ForegroundColor Yellow
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
            $itemText = ConvertTo-AzDevOpsHtmlLineBreak -Text $entry.Text
            $lines += "$bullet [$($entry.Time)] $itemText"
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
        [string] $FutureFeature,
        [AllowEmptyCollection()] [object[]] $Mentions
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
        $lines += ConvertTo-AzDevOpsHtmlLineBreak -Text $Debrief
        $lines += ''
    }

    if ($FutureFeature) {
        $lines += "$iconRocket Future opportunity:"
        $lines += ConvertTo-AzDevOpsHtmlLineBreak -Text $FutureFeature
        $lines += ''
    }

    $mentionLine = Format-AzDevOpsMentionLine -Members $Mentions
    if ($mentionLine) {
        $lines += $mentionLine
        $lines += ''
    }

    $lines += '<em>via bashcuts az-Start-UnplannedWork</em>'

    $body = $lines -join '<br/>'
    return $body
}


function Get-UnplannedLedgerPath {
    # Per-day ledger under the AzDO cache dir so New-UnplannedWorkDebrief can
    # total time across firefights (AzDO doesn't store our per-session minutes).
    # Returns $null when the cache layout isn't available. The generic JSON-array
    # cache helpers it leans on live in azdevops_paths.ps1.
    param([datetime] $Date = (Get-Date))

    $stamp = $Date.ToString('yyyy-MM-dd')
    $path  = Get-AzDevOpsCacheFilePath -FileName "unplanned-$stamp.json"
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

    $existing = Read-AzDevOpsJsonArrayCache -Path $path

    $entry = [PSCustomObject]@{
        StoryId   = $StoryId
        TaskId    = $TaskId
        Title     = $Title
        Minutes   = $Minutes
        ItemCount = $ItemCount
        EndedAt   = (Get-Date).ToString('o')
    }

    $all = @($existing) + $entry

    Save-AzDevOpsJsonArrayCache -Path $path -Items $all
}


function Format-UnplannedDailyDebrief {
    param(
        [Parameter(Mandatory)] [object[]] $Entries,
        [Parameter(Mandatory)] [int]      $TotalMinutes,
        [datetime] $Date = (Get-Date),
        [AllowEmptyCollection()] [object[]] $Mentions
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

    $mentionLine = Format-AzDevOpsMentionLine -Members $Mentions
    if ($mentionLine) {
        $lines += ''
        $lines += $mentionLine
    }

    $lines += ''
    $lines += '<em>via bashcuts New-UnplannedWorkDebrief</em>'

    $body = $lines -join '<br/>'
    return $body
}


function Show-UnplannedCapturedItemsFallback {
    # Last-resort dump of the items captured during a session when the daily
    # story / Task couldn't be created at debrief time, so the work isn't lost -
    # the user can paste these into the work item by hand.
    param(
        [Parameter(Mandatory)] [string] $Title,
        [object[]] $Items
    )

    $itemList = @($Items)

    Write-Host ""
    Write-Host "Captured items for '$Title' (not posted - create failed):" -ForegroundColor Yellow

    if ($itemList.Count -eq 0) {
        Write-Host "  (no items captured)" -ForegroundColor DarkGray
        return
    }

    $bullet = $script:UnplannedIconBullet
    foreach ($entry in $itemList) {
        Write-Host "  $bullet [$($entry.Time)] $($entry.Text)"
    }
}


function Save-UnplannedItemsToTask {
    # Flush the captured items to the Task description. Done up-front, before the
    # debrief is collected, so the firefight log survives even if the user
    # cancels the debrief form without posting a comment. A failed update is
    # surfaced but non-fatal — the debrief still proceeds.
    param(
        [Parameter(Mandatory)] [int]    $TaskId,
        [Parameter(Mandatory)] [string] $Title,
        [object[]] $Items
    )

    $descriptionBody = Format-UnplannedItemsDescription -TaskTitle $Title -Items @($Items)

    Write-Host "Updating Task #$TaskId description with captured items..." -ForegroundColor Cyan
    $descResult = Set-AzDevOpsWorkItemField -Id $TaskId -Fields @("System.Description=$descriptionBody")
    if ($descResult.ExitCode -ne 0) {
        Write-Host "  Could not update description: $($descResult.Error)" -ForegroundColor Yellow
    }
}


function Write-UnplannedPostVerdict {
    # Shared post-comment verdict for both debrief paths: a green check + view
    # hint on success, a red line on failure. Reads the AddComment envelope's
    # outcome through the timer's Get-TimerResultExitCode so the two features
    # interpret "missing ExitCode means success" the same way.
    param(
        [Parameter(Mandatory)] $Result,
        [Parameter(Mandatory)] [int] $TaskId
    )

    $iconCheck = $script:UnplannedIconCheck
    $exitCode  = Get-TimerResultExitCode -Result $Result

    if ($exitCode -eq 0) {
        Write-Host "$iconCheck Debrief posted on Task #$TaskId." -ForegroundColor Green
        Write-Host "   View: az-Open-WorkItemById $TaskId" -ForegroundColor DarkGray
    } else {
        Write-Host "Debrief comment failed: $($Result.Error)" -ForegroundColor Red
    }
}


function New-UnplannedFutureStory {
    # Terminal tail shared by both debrief paths: when the user captured a
    # prevent-this-firefight opportunity, offer to spin it into a user story via
    # az-New-AzDevOpsUserStory. Blank text is a no-op. Kept out of the WPF form
    # deliberately so story creation stays an interactive terminal flow.
    param([AllowEmptyString()] [string] $FutureText)

    if (-not $FutureText) {
        return
    }

    if (-not (Read-UnplannedYesNo -Prompt 'Create a user story for that opportunity now?')) {
        return
    }

    if (Get-Command az-New-AzDevOpsUserStory -ErrorAction SilentlyContinue) {
        az-New-AzDevOpsUserStory -Title $FutureText | Out-Null
    }
}


function Invoke-UnplannedDebriefConsole {
    # macOS / Linux debrief path: terminal prompts for the debrief notes and the
    # optional future-opportunity, the console mention picker, then post + verdict.
    # The captured items are already on the Task description (flushed by the
    # dispatcher), so this only gathers notes and posts the comment.
    param(
        [Parameter(Mandatory)] [int] $TaskId,
        [Parameter(Mandatory)] [int] $ElapsedMinutes,
        [object[]] $Items
    )

    $itemList = @($Items)

    $iconMemo = $script:UnplannedIconMemo
    $debrief  = Read-Host "$iconMemo Debrief notes for this firefight"

    $futureFeature = ''
    if (Read-UnplannedYesNo -Prompt 'Is there an opportunity for a new feature / user story to prevent this firefight in future?') {
        $futureFeature = Read-Host '  Describe the opportunity (one line)'
    }

    $mentions = Select-AzDevOpsMention

    $commentBody = Format-UnplannedDebriefComment `
        -ElapsedMinutes $ElapsedMinutes `
        -ItemCount      $itemList.Count `
        -Debrief        $debrief `
        -FutureFeature  $futureFeature `
        -Mentions       $mentions

    Write-Host ""
    Write-Host "Posting debrief comment to Task #$TaskId..." -ForegroundColor Cyan
    $commentResult = Add-AzDevOpsDiscussionComment -Id $TaskId -Body $commentBody
    Write-UnplannedPostVerdict -Result $commentResult -TaskId $TaskId

    New-UnplannedFutureStory -FutureText $futureFeature
}


function Invoke-UnplannedDebriefWpf {
    # Windows debrief path: the same themed WPF form the Pomodoro timer uses
    # (Show-WpfTimerDebrief), re-labelled for firefighting. The form carries the
    # debrief notes + future-opportunity fields, an "Open in Azure DevOps" button
    # for the just-created Task, and the in-form tag-teammates box (replacing the
    # console mention picker). The captured items are already flushed to the Task
    # description, so the form omits the read-only review list (it passes no
    # -Items). Its SubmitAction composes + posts the debrief comment under the
    # form's spinner; the future-opportunity → create-story prompt runs in the
    # terminal tail after the form closes, fed by the form's captured text.
    param(
        [Parameter(Mandatory)] [int] $TaskId,
        [Parameter(Mandatory)] [int] $ElapsedMinutes,
        [object[]] $Items
    )

    $itemList   = @($Items)
    $teamRoster = @(Get-AzDevOpsTeam)

    $submitAction = {
        param(
            [string]   $DebriefText,
            [string]   $FutureText,
            [object[]] $Mentions
        )

        $commentBody = Format-UnplannedDebriefComment `
            -ElapsedMinutes $ElapsedMinutes `
            -ItemCount      $itemList.Count `
            -Debrief        $DebriefText `
            -FutureFeature  $FutureText `
            -Mentions       $Mentions

        $posted = Add-AzDevOpsDiscussionComment -Id $TaskId -Body $commentBody
        return $posted
    }.GetNewClosure()

    $openAction = {
        az-Open-WorkItemById $TaskId
    }.GetNewClosure()

    $header         = "Unplanned session complete — $ElapsedMinutes min, $($itemList.Count) item(s)"
    $primaryLabel   = 'Debrief notes for this firefight'
    $secondaryLabel = 'Future opportunity (optional) — a feature/user story to prevent this firefight?'

    $debriefResult = Show-WpfTimerDebrief `
        -Interrupted    $false `
        -SubmitAction   $submitAction `
        -TeamRoster     $teamRoster `
        -OpenAction     $openAction `
        -OpenLabel      'Open in Azure DevOps' `
        -WindowTitle    'Unplanned Work Debrief' `
        -HeaderText     $header `
        -PrimaryLabel   $primaryLabel `
        -SecondaryLabel $secondaryLabel `
        -NoRestart

    if (-not $debriefResult.PostResult) {
        Write-Host "No debrief posted - captured items were saved to the Task description." -ForegroundColor DarkGray
        return
    }

    Write-UnplannedPostVerdict -Result $debriefResult.PostResult -TaskId $TaskId

    New-UnplannedFutureStory -FutureText $debriefResult.SecondaryText
}


function Invoke-UnplannedDebrief {
    # Stop-of-session tail, split out of az-Start-UnplannedWork so the orchestrator
    # reads as gate -> story -> task -> loop -> debrief. Computes the elapsed
    # minutes from $StartTime (accurate regardless of the on-screen counter),
    # flushes the captured items to the Task description, then dispatches to the
    # shared WPF debrief form on Windows or the terminal debrief elsewhere, and
    # records the session in the day's ledger. -Progress is the session's WPF
    # progress controller (a no-op stub off Windows): the items-flush reports its
    # step under it, then it's closed before the debrief form opens so the form
    # isn't left sitting behind the progress window.
    param(
        [Parameter(Mandatory)] [int]      $TaskId,
        [Parameter(Mandatory)] [int]      $StoryId,
        [Parameter(Mandatory)] [string]   $Title,
        [Parameter(Mandatory)] [datetime] $StartTime,
        [object[]] $Items,
        [object] $Progress
    )

    if ($null -eq $Progress) {
        $Progress = New-WpfProgressWindow -Disabled
    }

    $itemList = @($Items)

    $elapsedMinutes = [int][math]::Round(((Get-Date) - $StartTime).TotalMinutes)
    if ($elapsedMinutes -lt 1) {
        $elapsedMinutes = 1
    }

    Clear-Host
    $iconCheck = $script:UnplannedIconCheck
    Write-Host "$iconCheck Unplanned session complete - $elapsedMinutes min, $($itemList.Count) item(s)." -ForegroundColor Green
    Write-Host ""

    & $Progress.SetStatus 'Saving captured items...'
    Save-UnplannedItemsToTask -TaskId $TaskId -Title $Title -Items $itemList

    & $Progress.Stop

    if (Test-WpfIsWindows) {
        Invoke-UnplannedDebriefWpf -TaskId $TaskId -ElapsedMinutes $elapsedMinutes -Items $itemList
    } else {
        Invoke-UnplannedDebriefConsole -TaskId $TaskId -ElapsedMinutes $elapsedMinutes -Items $itemList
    }

    Add-UnplannedLedgerEntry -StoryId $StoryId -TaskId $TaskId -Title $Title -Minutes $elapsedMinutes -ItemCount $itemList.Count
}


function Show-WpfStopwatch {
    # WPF circular overlay stopwatch for Windows unplanned-work sessions.
    # Arc fills as time passes (amber colour distinguishes it from the Pomodoro
    # blue). "Log Item" opens an input dialog; "Create New Story" hides the overlay,
    # runs az-New-AzDevOpsUserStory in the terminal, then resumes. "Stop" /
    # right-click closes and returns the list of captured items. The work item
    # doesn't exist yet - it's created at debrief time - so the overlay shows
    # the firefight title rather than a Task id.
    param(
        [Parameter(Mandatory)] [string] $TaskTitle,
        [Parameter(Mandatory)] [int]    $ReminderMinutes,
        [switch] $NoReminder
    )

    Add-Type -AssemblyName PresentationFramework, WindowsBase, PresentationCore
    Add-Type -AssemblyName Microsoft.VisualBasic

    $maxDisplaySecs = [double]$script:WpfStopwatchMaxSeconds

    $Script:WpfElapsed = 0.0
    $Script:WpfItems   = New-Object System.Collections.Generic.List[object]

    $balloon = if ($NoReminder) {
        $null
    } else {
        New-UnplannedBalloon
    }

    $reminderIntervalMs = $ReminderMinutes * 60 * 1000

    # ---- Build window ----

    $brushes    = New-WpfBrushSet -ProgressColor $script:WpfColorProgressUnplanned
    $circleRes  = New-WpfCircleResources -Title 'Unplanned Work' -Brushes $brushes -ArcStartsFull $false
    $mainWin    = $circleRes.Window
    $circleGrid = $circleRes.Grid
    $arcSegment = $circleRes.ArcSegment

    $vbox = New-Object System.Windows.Controls.StackPanel -Property @{
        VerticalAlignment   = 'Center'
        HorizontalAlignment = 'Center'
    }

    $titleEllipsis = [char]0x2026
    $titleMaxChars = 28
    $titleText = if ($TaskTitle.Length -gt $titleMaxChars) {
        $TaskTitle.Substring(0, $titleMaxChars - 1) + $titleEllipsis
    } else {
        $TaskTitle
    }

    $titleLabel = New-Object System.Windows.Controls.TextBlock -Property @{
        Text                = $titleText
        FontSize            = 11
        Foreground          = $brushes.Hint
        HorizontalAlignment = 'Center'
        Margin              = '0,0,0,2'
    }
    $vbox.Children.Add($titleLabel) | Out-Null

    $clockText = New-Object System.Windows.Controls.TextBlock -Property @{
        Text                = '00:00.0'
        FontSize            = 34
        FontFamily          = 'Consolas'
        Foreground          = $brushes.White
        HorizontalAlignment = 'Center'
        Margin              = '0,0,0,6'
    }
    $vbox.Children.Add($clockText) | Out-Null

    $itemCountLabel = New-Object System.Windows.Controls.TextBlock -Property @{
        Text                = '0 item(s)'
        FontSize            = 11
        Foreground          = $brushes.Hint
        HorizontalAlignment = 'Center'
        Margin              = '0,0,0,6'
    }
    $vbox.Children.Add($itemCountLabel) | Out-Null

    $btnRow = New-Object System.Windows.Controls.StackPanel -Property @{
        Orientation         = 'Horizontal'
        HorizontalAlignment = 'Center'
        Margin              = '0,0,0,5'
    }
    $btnLogItem = New-Object System.Windows.Controls.Button -Property @{
        Content    = 'Log Item'
        Width      = 72
        Height     = 22
        Background = $brushes.Button
        Foreground = $brushes.White
        Margin     = 2
    }
    $btnCapture = New-Object System.Windows.Controls.Button -Property @{
        Content    = 'Create New Story'
        Width      = 88
        Height     = 22
        Background = $brushes.Button
        Foreground = $brushes.White
        Margin     = 2
    }
    $btnStop = New-Object System.Windows.Controls.Button -Property @{
        Content    = 'Stop'
        Width      = 44
        Height     = 22
        Background = $brushes.Button
        Foreground = $brushes.White
        Margin     = 2
    }
    $btnRow.Children.Add($btnLogItem) | Out-Null
    $btnRow.Children.Add($btnCapture) | Out-Null
    $btnRow.Children.Add($btnStop)    | Out-Null
    $vbox.Children.Add($btnRow) | Out-Null

    $exitHint = New-Object System.Windows.Controls.TextBlock -Property @{
        Text                = 'Right-click to stop'
        FontSize            = 9
        Foreground          = $brushes.Hint
        HorizontalAlignment = 'Center'
        Margin              = '0,8,0,0'
    }
    $vbox.Children.Add($exitHint) | Out-Null

    $circleGrid.Children.Add($vbox) | Out-Null

    # ---- UI update helper ----

    $updateUi = {
        $ts = [TimeSpan]::FromSeconds($Script:WpfElapsed)
        $clockText.Text      = $ts.ToString('mm\:ss\.f')
        $itemCountLabel.Text = "$($Script:WpfItems.Count) item(s)"

        $pct = $Script:WpfElapsed / $maxDisplaySecs
        Set-WpfArcPoint -Pct $pct -ArcSegment $arcSegment
    }

    $clockTick = New-Object System.Windows.Threading.DispatcherTimer -Property @{
        Interval = [TimeSpan]::FromMilliseconds(100)
    }

    $reminderTick = New-Object System.Windows.Threading.DispatcherTimer -Property @{
        Interval = [TimeSpan]::FromMilliseconds($reminderIntervalMs)
    }

    # ---- Event handlers ----

    $mainWin.Add_MouseLeftButtonDown({ $mainWin.DragMove() })

    $mainWin.Add_MouseRightButtonDown({
        $clockTick.Stop()
        $reminderTick.Stop()
        $mainWin.Close()
    })

    $clockTick.Add_Tick({
        $Script:WpfElapsed += 0.1
        & $updateUi
    })

    $reminderTick.Add_Tick({
        if ($null -ne $balloon) {
            Show-UnplannedReminder -Balloon $balloon -TaskTitle $TaskTitle
        }
    })

    $btnLogItem.Add_Click({
        $clockTick.Stop()
        $itemText = [Microsoft.VisualBasic.Interaction]::InputBox('What happened?', 'Log Item', '')

        if ($itemText) {
            $record = [PSCustomObject]@{
                Time = (Get-Date).ToString('HH:mm')
                Text = $itemText
            }
            $Script:WpfItems.Add($record)
            & $updateUi
        }

        $clockTick.Start()
    })

    $btnCapture.Add_Click({
        $clockTick.Stop()
        $reminderTick.Stop()
        $mainWin.Hide()

        az-New-AzDevOpsUserStory

        $mainWin.Show()
        $clockTick.Start()

        if (-not $NoReminder) {
            $reminderTick.Start()
        }
    })

    $btnStop.Add_Click({
        $clockTick.Stop()
        $reminderTick.Stop()
        $mainWin.Close()
    })

    # ---- Show ----

    & $updateUi
    $clockTick.Start()

    if (-not $NoReminder) {
        $reminderTick.Start()
    }

    $mainWin.ShowDialog() | Out-Null

    if ($null -ne $balloon) {
        $balloon.Dispose()
    }

    $items = $Script:WpfItems
    return $items
}


function az-Start-UnplannedWork {
    # Orchestrator. Prompt for the firefight first, then start the session
    # immediately - the Azure DevOps daily story + child Task are created at the
    # END (debrief time), so a burning fire isn't blocked on az boards round-trips
    # at start. Space logs a timestamped item, Esc/Q stops; a reminder balloon
    # fires every -ReminderMinutes. On stop the daily story is found-or-created
    # (cached for the rest of the day so the next firefight grabs it instantly),
    # the child Task is created and linked, captured items flush to its
    # description, and a debrief comment is posted and recorded in the ledger.
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

    if (-not $Title) {
        $Title = Read-Host 'What is this firefight about? (Task title)'
    }
    if (-not $Title) {
        Write-Host "Task title is required - aborting." -ForegroundColor Red
        return
    }

    $startTime = Get-Date
    $balloon   = $null

    $previousEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    try {
        $onWindows = Test-WpfIsWindows

        if ($onWindows) {
            $items = Show-WpfStopwatch `
                -TaskTitle       $Title `
                -ReminderMinutes $ReminderMinutes `
                -NoReminder:$NoReminder
        } else {
            # Console loop — macOS / Linux fallback
            $items   = New-Object System.Collections.Generic.List[object]
            $balloon = New-UnplannedBalloon

            $reminderSeconds = $ReminderMinutes * 60
            $pollsPerSecond  = $script:UnplannedPollsPerSecond
            $pollIntervalMs  = $script:UnplannedPollIntervalMs

            $elapsed        = 0
            $lastReminderAt = 0
            $stopRequested  = $false

            Write-Host "Space logs an item, Esc/Q stops and debriefs." -ForegroundColor Green

            Show-UnplannedStatus -TaskTitle $Title -ElapsedSeconds 0 -ItemCount 0 -ReminderMinutes $ReminderMinutes

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
                        Show-UnplannedStatus -TaskTitle $Title -ElapsedSeconds $elapsed -ItemCount $items.Count -ReminderMinutes $ReminderMinutes
                        break
                    }

                    Start-Sleep -Milliseconds $pollIntervalMs
                }

                if ($stopRequested) {
                    break
                }

                # Drive the display from wall-clock, not the iteration count — the
                # space branch's blocking Read-Host means a single iteration can
                # span many seconds, so $elapsed++ would undercount.
                $elapsed = [int]((Get-Date) - $startTime).TotalSeconds

                Show-UnplannedStatus -TaskTitle $Title -ElapsedSeconds $elapsed -ItemCount $items.Count -ReminderMinutes $ReminderMinutes

                if (-not $NoReminder -and ($elapsed - $lastReminderAt) -ge $reminderSeconds) {
                    Show-UnplannedReminder -Balloon $balloon -TaskTitle $Title
                    $lastReminderAt = $elapsed
                }
            }
        }

        # Creation is deferred to here: the session is over, so the daily story
        # + child Task are created now, just before the debrief flushes the
        # captured items and posts the comment. A failed create surfaces the
        # captured items rather than losing them.
        #
        # On Windows a small progress window names the az-boards step in flight
        # (find/create story → create Task → save items) so the user isn't left
        # staring at a frozen terminal; off Windows it's a no-op stub and the
        # per-step Write-Host lines stay the feedback. Invoke-UnplannedDebrief
        # closes it before opening the debrief form; the finally closes it again
        # (idempotent) on any early return.
        $progress = New-WpfProgressWindow -Title 'Unplanned Work' -InitialStatus 'Finding today''s story...'

        try {
            $storyId = Get-UnplannedWorkDailyStory -Progress $progress
            if ($storyId -le 0) {
                Write-Host "No daily Unplanned Work story available - cannot record this session." -ForegroundColor Red
                Show-UnplannedCapturedItemsFallback -Title $Title -Items $items
                return
            }

            & $progress.SetStatus 'Creating firefight Task...'
            $taskId = New-UnplannedWorkTask -Title $Title -StoryId $storyId
            if ($taskId -le 0) {
                Write-Host "Could not create the firefight Task - cannot record this session." -ForegroundColor Red
                Show-UnplannedCapturedItemsFallback -Title $Title -Items $items
                return
            }

            Invoke-UnplannedDebrief -TaskId $taskId -StoryId $storyId -Title $Title -StartTime $startTime -Items $items -Progress $progress
        }
        finally {
            & $progress.Stop
        }
    }
    finally {
        [Console]::OutputEncoding = $previousEncoding

        if ($null -ne $balloon) {
            $balloon.Dispose()
        }
    }
}


function New-UnplannedWorkDebrief {
    # End-of-day roll-up. Reads the day's ledger, totals time across firefights,
    # prints the per-Task breakdown, and (on confirm) posts a roll-up comment on
    # the daily story. -Date debriefs a past day's ledger.
    [CmdletBinding()]
    param([datetime] $Date = (Get-Date))

    if (-not (Test-AzDevOpsCreateGate -CommandName 'New-UnplannedWorkDebrief')) {
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

    $mentions = Select-AzDevOpsMention

    $body = Format-UnplannedDailyDebrief -Entries $entries -TotalMinutes $totalMinutes -Date $Date -Mentions $mentions
    $result = Add-AzDevOpsDiscussionComment -Id $storyId -Body $body
    if ($result.ExitCode -eq 0) {
        Write-Host "Posted daily roll-up on story #$storyId." -ForegroundColor Green
    } else {
        Write-Host "Failed to post roll-up: $($result.Error)" -ForegroundColor Red
    }
}
