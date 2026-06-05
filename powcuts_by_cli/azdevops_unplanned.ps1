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
#   New-UnplannedWorkDebrief - read the day's ledger, total the time across all
#                              firefights, and post a roll-up comment on the
#                              daily story.
#   az-Sync-UnplannedTeam      - resolve $env:AZ_DEBRIEF_TEAM (';'-separated
#                              emails/names) to Azure DevOps identities and
#                              cache them, so both debriefs can offer a
#                              type-to-filter picker that tags teammates with
#                              real notifying @-mentions.
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

$script:UnplannedTeamEnvVar    = 'AZ_DEBRIEF_TEAM'
$script:UnplannedTeamCacheFile = 'debrief-team.json'
$script:UnplannedMentionVersion = 'version:2.0'

$script:UnplannedIconFire   = [char]::ConvertFromUtf32(0x1F525)   # fire
$script:UnplannedIconMemo   = [char]::ConvertFromUtf32(0x1F4DD)   # memo
$script:UnplannedIconClock  = [char]::ConvertFromUtf32(0x23F0)    # alarm clock
$script:UnplannedIconCheck  = [char]::ConvertFromUtf32(0x2705)    # check mark
$script:UnplannedIconRocket = [char]::ConvertFromUtf32(0x1F680)   # rocket
$script:UnplannedIconBullet = [char]::ConvertFromUtf32(0x2022)    # bullet
$script:UnplannedIconPeople = [char]::ConvertFromUtf32(0x1F465)   # busts in silhouette


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
        $lines += $Debrief
        $lines += ''
    }

    if ($FutureFeature) {
        $lines += "$iconRocket Future opportunity:"
        $lines += $FutureFeature
        $lines += ''
    }

    $mentionLine = Format-UnplannedMentionLine -Members $Mentions
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

    $mentionLine = Format-UnplannedMentionLine -Members $Mentions
    if ($mentionLine) {
        $lines += ''
        $lines += $mentionLine
    }

    $lines += ''
    $lines += '<em>via bashcuts New-UnplannedWorkDebrief</em>'

    $body = $lines -join '<br/>'
    return $body
}


# ---------------------------------------------------------------------------
# Debrief team tagging
#
# A roster of teammates (sourced from $env:AZ_DEBRIEF_TEAM, ';'- or
# ','-separated emails/names) is resolved to Azure DevOps identities and cached
# under the AzDO cache dir next to the per-day ledger. Both debriefs offer a
# type-to-filter picker over that roster; the picked teammates are injected
# into the comment as data-vss-mention anchors so they are actually notified.
# Identity resolution (Get-AzDevOpsIdentity) and the anchor shape
# (Format-UnplannedMentionAnchor) are the two places to revisit if a tagged
# teammate does not receive a notification.
# ---------------------------------------------------------------------------

function Get-UnplannedTeamRoster {
    # Split $env:AZ_DEBRIEF_TEAM into a clean list of teammate identifiers
    # (emails and/or names). Accepts ';' or ',' separators, trims whitespace,
    # and drops blanks and case-insensitive duplicates. Returns an empty array
    # when the env var is unset.
    $raw = [Environment]::GetEnvironmentVariable($script:UnplannedTeamEnvVar)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $separators = [char[]]@(';', ',')
    $parts      = $raw.Split($separators, [StringSplitOptions]::RemoveEmptyEntries)

    $seen   = New-Object System.Collections.Generic.HashSet[string]
    $roster = New-Object System.Collections.Generic.List[string]
    foreach ($part in $parts) {
        $trimmed = $part.Trim()
        if ($trimmed -and $seen.Add($trimmed.ToLowerInvariant())) {
            $roster.Add($trimmed)
        }
    }

    $result = @($roster)
    return $result
}


function Get-UnplannedTeamCachePath {
    # Resolved-roster cache (display name + email + identity GUID) under the
    # AzDO cache dir, so debriefs build mention anchors without re-hitting the
    # identities API every session. Returns $null when the cache layout isn't
    # available (same guard as Get-UnplannedLedgerPath).
    if (-not (Get-Command Get-AzDevOpsCachePaths -ErrorAction SilentlyContinue)) {
        return $null
    }

    $paths = Get-AzDevOpsCachePaths
    if (-not $paths.Dir) {
        return $null
    }

    $cacheFile = $script:UnplannedTeamCacheFile
    $path      = Join-Path $paths.Dir $cacheFile
    return $path
}


function Resolve-UnplannedTeamMember {
    # Resolve one roster entry (email or display name) to a { DisplayName,
    # Email, Id } record via the identities API. The Id is the identity GUID
    # the discussion control needs for a notifying @-mention. Returns $null
    # when the lookup fails or matches nobody, so Sync-UnplannedDebriefTeam can
    # report the miss and skip it rather than caching a half-resolved entry.
    param([Parameter(Mandatory)] [string] $Identifier)

    if (-not (Get-Command Get-AzDevOpsIdentity -ErrorAction SilentlyContinue)) {
        return $null
    }

    $result = Get-AzDevOpsIdentity -Query $Identifier
    if ($result.ExitCode -ne 0) {
        return $null
    }

    try {
        $parsed = $result.Json | ConvertFrom-Json
    }
    catch {
        return $null
    }

    $candidates = @($parsed.value)
    if ($candidates.Count -eq 0) {
        return $null
    }

    $identity = $candidates[0]

    $displayName = if ($identity.providerDisplayName) {
        $identity.providerDisplayName
    } else {
        $Identifier
    }

    $email = if ($identity.properties -and $identity.properties.Mail -and $identity.properties.Mail.'$value') {
        $identity.properties.Mail.'$value'
    } else {
        $Identifier
    }

    $record = [PSCustomObject]@{
        DisplayName = $displayName
        Email       = $email
        Id          = $identity.id
    }
    return $record
}


function Save-UnplannedTeamCache {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Members)

    $path = Get-UnplannedTeamCachePath
    if (-not $path) {
        return
    }

    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $json = ConvertTo-Json -InputObject @($Members) -Depth 5 -AsArray
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
}


function Read-UnplannedTeamCache {
    $path = Get-UnplannedTeamCachePath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        return @()
    }

    try {
        $members = @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
    }
    catch {
        return @()
    }

    return $members
}


function Sync-UnplannedDebriefTeam {
    # Resolve every $env:AZ_DEBRIEF_TEAM entry to an identity record and write
    # the roster cache. Returns the resolved records. Entries that don't resolve
    # are reported and skipped so one bad email doesn't sink the whole roster.
    $roster = Get-UnplannedTeamRoster
    if ($roster.Count -eq 0) {
        $envVar = $script:UnplannedTeamEnvVar
        Write-Host "No team configured. Set `$env:$envVar (';'-separated emails) to enable debrief tagging." -ForegroundColor Yellow
        return @()
    }

    $resolved = New-Object System.Collections.Generic.List[object]
    foreach ($member in $roster) {
        $record = Resolve-UnplannedTeamMember -Identifier $member
        if ($null -eq $record -or -not $record.Id) {
            Write-Host "  Could not resolve '$member' to an Azure DevOps identity - skipping." -ForegroundColor Yellow
            continue
        }

        $resolved.Add($record)
    }

    $records = @($resolved)
    Save-UnplannedTeamCache -Members $records
    return $records
}


function Get-UnplannedDebriefTeam {
    # Cached roster reader. Auto-syncs from $env:AZ_DEBRIEF_TEAM the first time
    # (or after the cache is cleared) so callers don't have to run
    # az-Sync-UnplannedTeam by hand. Returns an empty array when no team is
    # configured.
    $cached = Read-UnplannedTeamCache
    if ($cached.Count -gt 0) {
        return $cached
    }

    $roster = Get-UnplannedTeamRoster
    if ($roster.Count -eq 0) {
        return @()
    }

    $synced = Sync-UnplannedDebriefTeam
    return $synced
}


function Format-UnplannedMentionAnchor {
    # Build the Azure DevOps discussion @-mention anchor for one resolved
    # teammate. The data-vss-mention attribute carries the identity GUID; the
    # work-item discussion control turns this exact anchor shape into a real
    # notification on save, and the version token mirrors what the AzDO web
    # editor emits. If a tagged teammate is NOT notified, this anchor (and the
    # identity GUID feeding it from Get-AzDevOpsIdentity) is what to revisit.
    param([Parameter(Mandatory)] [object] $Member)

    $mentionVersion = $script:UnplannedMentionVersion
    $atSign         = '@'
    $quote          = '"'

    $dataAttr = "data-vss-mention=$quote$mentionVersion,$($Member.Id)$quote"
    $anchor   = "<a href=$quote#$quote $dataAttr>$atSign$($Member.DisplayName)</a>"
    return $anchor
}


function Format-UnplannedMentionLine {
    # Compose the single "Tagged: @a @b" line appended to a debrief comment.
    # Returns '' for an empty selection so both formatters can skip the line
    # (and keep posting exactly as before) when nobody is tagged.
    param([AllowEmptyCollection()] [object[]] $Members)

    # Drop $null / unresolved entries so an omitted -Mentions arg (which arrives
    # as @($null), a 1-element array) collapses to an empty line rather than a
    # broken anchor.
    $memberList = @($Members | Where-Object { $null -ne $_ -and $_.Id })
    if ($memberList.Count -eq 0) {
        return ''
    }

    $iconPeople = $script:UnplannedIconPeople

    $anchors = New-Object System.Collections.Generic.List[string]
    foreach ($member in $memberList) {
        $anchor = Format-UnplannedMentionAnchor -Member $member
        $anchors.Add($anchor)
    }

    $line = "$iconPeople Tagged: " + ($anchors -join ' ')
    return $line
}


function Select-UnplannedMentionFromMenu {
    # Numbered Read-Host fallback for Select-UnplannedDebriefMention when no
    # Out-ConsoleGridView host is available. Accepts a comma-separated list of
    # indices; ignores blanks and out-of-range entries. Returns the chosen
    # member records.
    param([Parameter(Mandatory)] [object[]] $Team)

    Write-Host ''
    Write-Host 'Teammates available to tag:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $Team.Count; $i++) {
        $member = $Team[$i]
        Write-Host ("  {0}) {1}  <{2}>" -f ($i + 1), $member.DisplayName, $member.Email)
    }

    $raw = Read-Host 'Numbers to tag (comma-separated, blank = none)'
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $separators = [char[]]@(';', ',')
    $tokens     = $raw.Split($separators, [StringSplitOptions]::RemoveEmptyEntries)

    $picked = New-Object System.Collections.Generic.List[object]
    foreach ($token in $tokens) {
        $index = 0
        if ([int]::TryParse($token.Trim(), [ref]$index)) {
            $zeroBased = $index - 1
            if ($zeroBased -ge 0 -and $zeroBased -lt $Team.Count) {
                $picked.Add($Team[$zeroBased])
            }
        }
    }

    $result = @($picked)
    return $result
}


function Select-UnplannedDebriefMention {
    # Type-to-filter picker over the cached roster for debrief tagging. Shows
    # Name + Email so the user can confirm the right person before tagging.
    # Out-ConsoleGridView multi-select when available (its filter box is the
    # "type and the right names bubble up" behavior); a Read-Host numbered menu
    # otherwise. Returns the selected member records - possibly empty, since
    # tagging is always optional and 'tag nobody' leaves the debrief unchanged.
    $team = Get-UnplannedDebriefTeam
    if ($team.Count -eq 0) {
        return @()
    }

    if (-not (Read-UnplannedYesNo -Prompt 'Tag teammate(s) on this debrief?')) {
        return @()
    }

    if (Test-AzDevOpsGridAvailable) {
        $grid = $team |
            Select-Object DisplayName, Email, Id |
            Out-ConsoleGridView -Title 'Pick teammate(s) to tag (filter as you type, Esc = none)' -OutputMode Multiple

        $picked = @($grid)
        return $picked
    }

    $menuPicked = Select-UnplannedMentionFromMenu -Team $team
    return $menuPicked
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

    $mentions = Select-UnplannedDebriefMention

    $commentBody = Format-UnplannedDebriefComment `
        -ElapsedMinutes $elapsedMinutes `
        -ItemCount      $itemList.Count `
        -Debrief        $debrief `
        -FutureFeature  $futureFeature `
        -Mentions       $mentions

    Write-Host ""
    Write-Host "Posting debrief comment to Task #$TaskId..." -ForegroundColor Cyan
    $commentResult = Add-AzDevOpsDiscussionComment -Id $TaskId -Body $commentBody
    if ($commentResult.ExitCode -eq 0) {
        Write-Host "$iconCheck Debrief posted on Task #$TaskId." -ForegroundColor Green
        Write-Host "   View: az-Open-WorkItemById $TaskId" -ForegroundColor DarkGray
    } else {
        Write-Host "Debrief comment failed: $($commentResult.Error)" -ForegroundColor Red
    }

    Add-UnplannedLedgerEntry -StoryId $StoryId -TaskId $TaskId -Title $Title -Minutes $elapsedMinutes -ItemCount $itemList.Count
}


function Show-WpfStopwatch {
    # WPF circular overlay stopwatch for Windows unplanned-work sessions.
    # Arc fills as time passes (amber colour distinguishes it from the Pomodoro
    # blue). "Log Item" opens an input dialog; "Create New Story" hides the overlay,
    # runs az-New-AzDevOpsUserStory in the terminal, then resumes. "Stop" /
    # right-click closes and returns the list of captured items.
    param(
        [Parameter(Mandatory)] [int]    $TaskId,
        [Parameter(Mandatory)] [string] $TaskTitle,
        [Parameter(Mandatory)] [int]    $ReminderMinutes,
        [switch] $NoReminder
    )

    Add-Type -AssemblyName PresentationFramework, WindowsBase, PresentationCore
    Add-Type -AssemblyName Microsoft.VisualBasic

    $maxDisplaySecs = $script:WpfStopwatchMaxSeconds

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

    $titleLabel = New-Object System.Windows.Controls.TextBlock -Property @{
        Text                = "Task #$TaskId"
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
            Show-UnplannedReminder -Balloon $balloon -TaskId $TaskId -TaskTitle $TaskTitle
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

    $items = @($Script:WpfItems)
    return $items
}


function az-Start-UnplannedWork {
    # Orchestrator. Find-or-create today's daily story, create a child Task for
    # this firefight, then run the foreground session: Space logs a timestamped
    # item, Esc/Q stops. A reminder balloon fires every -ReminderMinutes. On
    # stop the captured items flush to the Task description and a debrief comment
    # (time spent + notes + optional future-feature opportunity) is posted; the
    # session is recorded in the day's ledger for New-UnplannedWorkDebrief.
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
    Write-Host "Starting session." -ForegroundColor Green
    Start-Sleep -Seconds 2

    $startTime = Get-Date
    $balloon   = $null

    $previousEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    try {
        $onWindows = Test-WpfIsWindows

        if ($onWindows) {
            $items = Show-WpfStopwatch `
                -TaskId          $taskId `
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

                # Drive the display from wall-clock, not the iteration count — the
                # space branch's blocking Read-Host means a single iteration can
                # span many seconds, so $elapsed++ would undercount.
                $elapsed = [int]((Get-Date) - $startTime).TotalSeconds

                Show-UnplannedStatus -TaskId $taskId -TaskTitle $Title -ElapsedSeconds $elapsed -ItemCount $items.Count -ReminderMinutes $ReminderMinutes

                if (-not $NoReminder -and ($elapsed - $lastReminderAt) -ge $reminderSeconds) {
                    Show-UnplannedReminder -Balloon $balloon -TaskId $taskId -TaskTitle $Title
                    $lastReminderAt = $elapsed
                }
            }
        }

        Invoke-UnplannedDebrief -TaskId $taskId -StoryId $storyId -Title $Title -StartTime $startTime -Items $items
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

    $mentions = Select-UnplannedDebriefMention

    $body = Format-UnplannedDailyDebrief -Entries $entries -TotalMinutes $totalMinutes -Date $Date -Mentions $mentions
    $result = Add-AzDevOpsDiscussionComment -Id $storyId -Body $body
    if ($result.ExitCode -eq 0) {
        Write-Host "Posted daily roll-up on story #$storyId." -ForegroundColor Green
    } else {
        Write-Host "Failed to post roll-up: $($result.Error)" -ForegroundColor Red
    }
}


function az-Sync-UnplannedTeam {
    # Refresh the cached debrief-tagging roster from $env:AZ_DEBRIEF_TEAM. Run
    # this after changing the env var so the next debrief's tag picker reflects
    # the new team. Resolution uses the Azure DevOps identities API, so it needs
    # a configured org (same create gate as the other write commands).
    [CmdletBinding()]
    param()

    if (-not (Test-AzDevOpsCreateGate -CommandName 'az-Sync-UnplannedTeam')) {
        return
    }

    $members = Sync-UnplannedDebriefTeam
    if ($members.Count -eq 0) {
        return
    }

    Write-Host ""
    Write-Host "Cached $($members.Count) teammate(s) for debrief tagging:" -ForegroundColor Green
    foreach ($member in $members) {
        Write-Host ("  {0}  <{1}>" -f $member.DisplayName, $member.Email)
    }
}
