# ============================================================================
# Azure DevOps — Daily Viewer local server + cache contract
# ============================================================================
# Serves daily-viewer/ on 127.0.0.1 and exposes a small JSON API over the
# per-tile cache. Two strictly separate paths:
#
#   GET  /                       -> the page + static assets (cheap)
#   GET  /api/tiles/<name>       -> that tile's cached JSON (cheap read)
#   POST /api/tiles/<name>/refresh -> re-run that tile's query, rewrite its
#                                     cache, return fresh JSON (expensive)
#
# The cache reuses the existing per-project cache root (Get-AzDevOpsCachePaths)
# so it follows the active project slice exactly like assigned.json /
# hierarchy.json — one JSON file per tile under a daily-viewer/ subfolder.
# Staleness is the file's mtime age, surfaced to the client so the page can
# render "cached Nm ago" without a second source of truth.
#
# SECURITY: the listener binds to 127.0.0.1 only (never 0.0.0.0), and the
# az login / PAT stays in this server process — responses carry only work-item
# and agenda data. Every response also ships a strict Content-Security-Policy
# (default-src 'self', no unsafe-inline) plus nosniff / no-referrer / DENY
# framing headers, so even a work-item title carrying markup renders inert:
# the page has no inline-script/style path for it to escape into.
#
# Loaded by powcuts_home.ps1. See azdevops_auth.ps1 for the master docstring.

$script:AzDevOpsDailyViewerDefaultPort     = 8770
$script:AzDevOpsDailyViewerStaleSeconds    = 900     # 15 min: mtime age past which a tile reads "stale"
$script:AzDevOpsDailyViewerCacheSubdir     = 'daily-viewer'
$script:AzDevOpsDailyViewerLoopbackAddress = '127.0.0.1'
$script:AzDevOpsDailyViewerJsonDepth       = 10      # nesting the tile payloads / API responses serialize to
$script:AzDevOpsDailyViewerPrepWindowDays  = 14      # "events to prepare for" look-ahead: the next two weeks
$script:AzDevOpsDailyViewerMarkerNeeded    = 'needed'  # a newly-pulled meeting starts "prep still needed"
$script:AzDevOpsDailyViewerRefreshStampFile = 'refreshed-on.json'  # per-day full-refresh marker beside the tile cache
$script:AzDevOpsDailyViewerDayKeyFormat     = 'yyyy-MM-dd'         # calendar-day granularity the daily refresh gates on

# Strict Content-Security-Policy for the served app. The page loads styles.css +
# app.js as external same-origin assets and fetches /api/tiles/* same-origin;
# there are no inline handlers/styles, CDN scripts, or webfonts, so 'self' with
# no 'unsafe-inline' loads clean. Inline <svg> in the markup uses presentation
# attributes (fill/stroke), which CSP does not gate. base-uri/object/frame/form
# are locked down so an injected <base>/<object>/framing can't reroute the page.
$script:AzDevOpsDailyViewerContentSecurityPolicy = @(
    "default-src 'self'"
    "base-uri 'none'"
    "object-src 'none'"
    "frame-ancestors 'none'"
    "form-action 'self'"
    "img-src 'self' data:"
) -join '; '

$script:AzDevOpsDailyViewerTitleDash = "$([char]0x2014)"   # em dash — "Story #1234 — <title>"
$script:AzDevOpsDailyViewerMiddot    = "$([char]0x00B7)"   # middle dot — "<sub> · <state>"
$script:AzDevOpsDailyViewerJoinLabel = "Join meeting $([char]0x2192)"   # right arrow

$script:AzDevOpsDailyViewerMimeTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'text/javascript; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.svg'  = 'image/svg+xml'
    '.ico'  = 'image/x-icon'
    '.png'  = 'image/png'
    '.woff2'= 'font/woff2'
}


# ---------------------------------------------------------------------------
# Tile identity + filesystem layout
# ---------------------------------------------------------------------------

function Get-AzDevOpsDailyViewerTileNames {
    $names = @('agenda', 'week', 'activity', 'focus')
    return $names
}


function Test-AzDevOpsDailyViewerTileName {
    param([Parameter(Mandatory)] [string] $Name)

    $known = Get-AzDevOpsDailyViewerTileNames
    $isKnown = $known -contains $Name
    return $isKnown
}


function Get-AzDevOpsDailyViewerStaticRoot {
    # The static assets (index.html / styles.css / app.js) live in daily-viewer/
    # at the repo root, one level up from this file's powcuts_by_cli/ folder.
    $root = Join-Path (Split-Path -Parent $PSScriptRoot) 'daily-viewer'
    return $root
}


function Get-AzDevOpsDailyViewerCacheDir {
    # A daily-viewer/ subfolder under the ACTIVE project's cache slice, so the
    # tile cache follows az-Use-AzDevOpsProject exactly like the synced datasets
    # rather than growing a parallel cache structure.
    $paths = Get-AzDevOpsCachePaths
    if (-not $paths.Dir) {
        return $null
    }

    $dir = Join-Path $paths.Dir $script:AzDevOpsDailyViewerCacheSubdir
    return $dir
}


function Get-AzDevOpsDailyViewerTilePath {
    param([Parameter(Mandatory)] [string] $Tile)

    $dir = Get-AzDevOpsDailyViewerCacheDir
    if (-not $dir) {
        return $null
    }

    $path = Join-Path $dir "$Tile.json"
    return $path
}


# ---------------------------------------------------------------------------
# Per-tile query + normalization — the EXPENSIVE seam
#
# Each builder runs its real source (the Outlook module for the agenda tile,
# `az boards query` via the shared WIQL defaults for the rest) and normalizes
# the result into the "items" payload shaped like the front-end model in
# daily-viewer/app.js. The transport and cache contract above/below this block
# stay put. Every builder fails soft: a missing az login, an Outlook that isn't
# reachable, or a parse error yields an empty payload (logged server-side) so
# the tile renders a clean empty state instead of taking down the serving loop.
# ---------------------------------------------------------------------------

function Get-AzDevOpsDailyViewerQueryRows {
    # Run a named WIQL default (assigned / mentions / activity) through
    # Invoke-AzDevOpsBoardsQuery and map each row with $Converter (the same
    # ConvertFrom-AzDevOps* projections the az-Show-* views use). Returns @() on
    # any failure so a tile fails soft to an empty state — the expensive refresh
    # path must never surface a 500 for a query the user simply isn't logged in
    # for. Failures are recorded in the sync log for later diagnosis.
    param(
        [Parameter(Mandatory)] [string]      $Name,
        [Parameter(Mandatory)] [scriptblock] $Converter
    )

    try {
        $wiql   = Get-AzDevOpsWiql -Name $Name
        $result = Invoke-AzDevOpsBoardsQuery -Wiql $wiql

        if ($result.ExitCode -ne 0) {
            Write-AzDevOpsSyncLog "daily-viewer: query '$Name' failed (exit $($result.ExitCode)): $($result.Error)"
            return @()
        }

        $raw = $result.Json | ConvertFrom-Json
        if ($null -eq $raw) {
            return @()
        }

        $rows = @($raw | ForEach-Object { & $Converter $_ })
        return $rows
    }
    catch {
        Write-AzDevOpsSyncLog "daily-viewer: query '$Name' error: $($_.Exception.Message)"
        return @()
    }
}


function New-AzDevOpsDailyViewerWorkItemNode {
    # Map a normalized { Id; Type; State; Title } row (as emitted by the
    # ConvertFrom-AzDevOps* projections) to the front-end work-item row shape.
    # Both the id chip and — with -LinkTitle — the title link to the item's
    # dev.azure.com/.../_workitems/edit/<id> page. Get-AzDevOpsWorkItemUrl
    # returns $null when az devops defaults are unset; the view drops the href
    # and still renders the id/title as inert text, so no link is never a crash.
    param(
        [Parameter(Mandatory)] $Row,
        [switch] $LinkTitle,
        $Date
    )

    $id  = [int]$Row.Id
    $url = Get-AzDevOpsWorkItemUrl -Id $id

    $node = [ordered]@{
        type  = $Row.Type
        id    = $id
        url   = $url
        title = $Row.Title
        state = $Row.State
    }

    if ($null -ne $Row.Priority) {
        $node.priority = [int]$Row.Priority
    }

    if ($Date) {
        $node.date = Format-AzDevOpsDailyViewerShortDate -When $Date
    }

    if ($LinkTitle -and $url) {
        $node.titleUrl = $url
    }

    return $node
}


function Get-AzDevOpsDailyViewerActiveRows {
    # Drop closed / removed / done rows — the "still open" filter every tile
    # applies to its query output before projecting. Comma-wrapped so an
    # all-closed result stays an empty array through the caller's assignment
    # instead of unrolling to $null. Private helper (unapproved verb is fine).
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rows)

    $closedStates = Get-AzDevOpsClosedStates
    $active = @($Rows | Where-Object { $_.State -notin $closedStates })

    return ,$active
}


function Get-AzDevOpsDailyViewerRelativeTime {
    # Compact "how long ago" label for the activity tile's note column
    # (e.g. "2h ago"). Mirrors the front-end formatAge buckets so cached notes
    # and freshly-refreshed ones read the same.
    param([Parameter(Mandatory)] [datetime] $When)

    $span = (Get-Date) - $When

    if ($span.TotalMinutes -lt 1) {
        return 'just now'
    }

    if ($span.TotalMinutes -lt 60) {
        $mins = [int]$span.TotalMinutes
        return "${mins}m ago"
    }

    if ($span.TotalHours -lt 24) {
        $hours = [int]$span.TotalHours
        return "${hours}h ago"
    }

    $days = [int]$span.TotalDays
    return "${days}d ago"
}


function Format-AzDevOpsDailyViewerShortDate {
    # Compact date for a work-item row's date chip (e.g. "Jul 18"), matching the
    # front-end model's short-date look. The year is appended only when the date
    # falls outside the current year, so near-term due dates stay terse.
    param([Parameter(Mandatory)] [datetime] $When)

    $sameYear = $When.Year -eq (Get-Date).Year

    $format = if ($sameYear) {
        'MMM d'
    } else {
        'MMM d, yyyy'
    }

    $short = $When.ToString($format)
    return $short
}


function Get-AzDevOpsDailyViewerAssignedRows {
    # Shared source of the user's assigned work items for the week + focus
    # tiles (each refreshes independently, so both run the query on their own
    # refresh). Reuses the 'assigned' WIQL default and the assigned projection.
    $rows = Get-AzDevOpsDailyViewerQueryRows -Name 'assigned' -Converter {
        param($r) ConvertFrom-AzDevOpsAssignedItem -Raw $r
    }

    return $rows
}


function Get-AzDevOpsDailyViewerAgendaEvents {
    # Shared source of calendar events for the agenda tile (today, the default)
    # and the week tile's prep list (the two-week window, via -Days).
    # ol-Get-OutlookAgenda fails soft to $null off Windows / desktop Outlook (or
    # when the module isn't loaded); normalize that to an empty array so callers
    # render a clean empty state instead of tripping on $null.
    param([int] $Days = 1)

    if (-not (Get-Command ol-Get-OutlookAgenda -ErrorAction SilentlyContinue)) {
        return @()
    }

    $events = ol-Get-OutlookAgenda -Days $Days
    if ($null -eq $events) {
        return @()
    }

    return @($events)
}


# --- Agenda tile ------------------------------------------------------------

function New-AzDevOpsDailyViewerLocation {
    # Build the front-end location object for one calendar event: a Teams join
    # link when the meeting carries one, the room/place text otherwise, and a
    # neutral badge when neither is set. The badge is always present because the
    # view renders it unconditionally.
    param([Parameter(Mandatory)] $CalendarEvent)

    $joinUrl = $CalendarEvent.MeetingUrl
    if ($joinUrl) {
        $location = [ordered]@{
            badge    = 'Teams'
            url      = $joinUrl
            urlLabel = $script:AzDevOpsDailyViewerJoinLabel
        }
        return $location
    }

    $place = [string]$CalendarEvent.Location
    if ($place) {
        $location = [ordered]@{ badge = 'In person'; text = $place }
        return $location
    }

    $location = [ordered]@{ badge = 'No location' }
    return $location
}


function New-AzDevOpsDailyViewerAgendaNode {
    # Normalize one ol-Get-OutlookAgenda row into the front-end event shape.
    param([Parameter(Mandatory)] $CalendarEvent)

    $start = $CalendarEvent.Start

    $timeLabel = if ($CalendarEvent.IsAllDay) {
        'All day'
    } else {
        $start.ToString('h:mm tt')
    }

    $time = [ordered]@{
        label    = $timeLabel
        datetime = $start.ToString('o')
    }

    $location = New-AzDevOpsDailyViewerLocation -CalendarEvent $CalendarEvent

    $details = New-Object System.Collections.Generic.List[object]
    if ($CalendarEvent.Organizer) {
        $details.Add([ordered]@{ label = 'With'; text = [string]$CalendarEvent.Organizer })
    }

    $node = [ordered]@{
        time     = $time
        title    = [string]$CalendarEvent.Subject
        location = $location
        details  = $details
    }

    return $node
}


function Get-AzDevOpsDailyViewerAgendaItems {
    $events = @(Get-AzDevOpsDailyViewerAgendaEvents)

    $eventNodes = @($events | ForEach-Object { New-AzDevOpsDailyViewerAgendaNode -CalendarEvent $_ })

    $items = [ordered]@{
        events = $eventNodes
    }

    return $items
}


# --- This week's focus tile -------------------------------------------------

function Get-AzDevOpsDailyViewerPrepItems {
    # "Events to prepare for" = the next two weeks of meetings, widened from
    # today so nothing on the calendar sneaks up unprepared. Each row carries a
    # short date chip, the meeting's ISO datetime, a default "prep still needed"
    # marker the viewer can toggle to "all set", and a Teams join link when the
    # meeting has one. Durable marker state is a follow-up — the model ships the
    # default and the page owns the toggle.
    $events = @(Get-AzDevOpsDailyViewerAgendaEvents -Days $script:AzDevOpsDailyViewerPrepWindowDays)

    $prep = @($events | ForEach-Object {
        $node = [ordered]@{
            title    = [string]$_.Subject
            date     = Format-AzDevOpsDailyViewerShortDate -When $_.Start
            datetime = $_.Start.ToString('o')
            marker   = $script:AzDevOpsDailyViewerMarkerNeeded
        }

        if ($_.MeetingUrl) {
            $node.link = [ordered]@{ text = 'Join meeting'; url = $_.MeetingUrl }
        }

        $node
    })

    return $prep
}


function Get-AzDevOpsDailyViewerWeekItems {
    $assigned = @(Get-AzDevOpsDailyViewerAssignedRows)

    $activeRows = Get-AzDevOpsDailyViewerActiveRows -Rows $assigned
    $storyItems = @($activeRows | ForEach-Object {
        New-AzDevOpsDailyViewerWorkItemNode -Row $_ -LinkTitle -Date $_.TargetDate
    })

    $prepItems = Get-AzDevOpsDailyViewerPrepItems

    $items = [ordered]@{
        stories = [ordered]@{
            label = 'Stories to complete'
            open  = $true
            items = $storyItems
        }
        prep = [ordered]@{
            label = 'Events to prepare for'
            open  = $true
            items = $prepItems
        }
    }

    return $items
}


# --- Recent activity tile ---------------------------------------------------

function New-AzDevOpsDailyViewerActivityGroup {
    # One collapsible activity group: sort the rows newest-first, project each
    # to a work-item node, and stamp a relative-time note from $DateField (the
    # per-source timestamp — MentionedAt for mentions, ChangedDate for activity).
    param(
        [Parameter(Mandatory)] [string] $Label,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rows,
        [Parameter(Mandatory)] [string] $DateField,
        [switch] $Open
    )

    $sorted = Sort-AzDevOpsByDateDesc -Items $Rows -Field $DateField

    $items = @($sorted | ForEach-Object {
        $node = New-AzDevOpsDailyViewerWorkItemNode -Row $_ -LinkTitle

        $when = $_.$DateField
        if ($when) {
            $node.note = Get-AzDevOpsDailyViewerRelativeTime -When $when
        }

        $node
    })

    $group = [ordered]@{
        label = $Label
        open  = [bool]$Open
        items = $items
    }

    return $group
}


function Get-AzDevOpsDailyViewerCurrentSprintRows {
    # Filter activity rows to the current sprint. The iteration path comes from
    # the cache-only Resolve-AzDevOpsCurrentIterationFromCache (no live `az`
    # callout, honoring the viewer's read path), falling back to $env:AZ_ITERATION;
    # when neither resolves, the group renders empty rather than guessing a sprint.
    # Exact-path match mirrors Get-AzDevOpsDayViewRows. Comma-wrapped returns so an
    # empty result stays an empty array through the caller's assignment instead of
    # unrolling to $null (which the -Rows [object[]] bind would reject).
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rows
    )

    $current = Resolve-AzDevOpsCurrentIterationFromCache

    $iterationPath = Resolve-AzDevOpsIterationPathOrEnv -Current $current

    if (-not $iterationPath) {
        return ,@()
    }

    $inSprint = @($Rows | Where-Object { $_.Iteration -eq $iterationPath })

    return ,$inSprint
}


function Get-AzDevOpsDailyViewerActivityItems {
    $mentions = @(Get-AzDevOpsDailyViewerQueryRows -Name 'mentions' -Converter {
        param($r) ConvertFrom-AzDevOpsMentionItem -Raw $r
    })
    $activity = @(Get-AzDevOpsDailyViewerQueryRows -Name 'activity' -Converter {
        param($r) ConvertFrom-AzDevOpsActivityItem -Raw $r
    })

    $taggedRows = Get-AzDevOpsDailyViewerActiveRows -Rows $mentions
    $updateRows = Get-AzDevOpsDailyViewerActiveRows -Rows $activity
    $sprintRows = Get-AzDevOpsDailyViewerCurrentSprintRows -Rows $activity

    $groups = New-Object System.Collections.Generic.List[object]
    $groups.Add((New-AzDevOpsDailyViewerActivityGroup -Label 'Tagged discussions' -Rows $taggedRows -DateField 'MentionedAt' -Open))
    $groups.Add((New-AzDevOpsDailyViewerActivityGroup -Label 'Recent updates'     -Rows $updateRows -DateField 'ChangedDate'))
    $groups.Add((New-AzDevOpsDailyViewerActivityGroup -Label 'Current sprint'      -Rows $sprintRows -DateField 'ChangedDate'))

    $items = [ordered]@{
        groups = $groups
    }

    return $items
}


# --- Today's focus tile -----------------------------------------------------

function Get-AzDevOpsDailyFocusId {
    # The pinned "today's focus" work item is a user-set config value
    # ($global:AzDevOpsDailyFocus) rather than a query, so the tile shows the one
    # thing you chose to commit to. Returns $null when it is unset or not a
    # positive integer, and the focus tile then renders its support bucket only.
    $raw = $global:AzDevOpsDailyFocus
    if (-not $raw) {
        return $null
    }

    $id = 0
    if ([int]::TryParse([string]$raw, [ref] $id) -and $id -gt 0) {
        return $id
    }

    return $null
}


function New-AzDevOpsDailyViewerFocusPrimary {
    # Build the pinned-item header from the configured focus id, enriching the
    # title + state from the assigned rows when the id is one of them. Returns
    # $null when no focus id is configured so the view renders support only.
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Assigned)

    $focusId = Get-AzDevOpsDailyFocusId
    if (-not $focusId) {
        return $null
    }

    $match = $Assigned | Where-Object { [int]$_.Id -eq $focusId } | Select-Object -First 1

    $title = if ($match) {
        "$($match.Type) #$focusId $script:AzDevOpsDailyViewerTitleDash $($match.Title)"
    } else {
        "Work item #$focusId"
    }

    $sub = if ($match) {
        "Primary commitment for today $script:AzDevOpsDailyViewerMiddot $($match.State)"
    } else {
        'Primary commitment for today'
    }

    $url = Get-AzDevOpsWorkItemUrl -Id $focusId

    $primary = [ordered]@{
        title = $title
        url   = $url
        sub   = $sub
    }

    return $primary
}


function Get-AzDevOpsDailyViewerFocusItems {
    $assigned = @(Get-AzDevOpsDailyViewerAssignedRows)

    $primary = New-AzDevOpsDailyViewerFocusPrimary -Assigned $assigned
    $focusId = Get-AzDevOpsDailyFocusId

    $activeRows = Get-AzDevOpsDailyViewerActiveRows -Rows $assigned
    $supportRows = @($activeRows | Where-Object {
        -not $focusId -or [int]$_.Id -ne $focusId
    })
    $supportItems = @($supportRows | ForEach-Object {
        New-AzDevOpsDailyViewerWorkItemNode -Row $_ -LinkTitle -Date $_.TargetDate
    })

    $items = [ordered]@{
        primary = $primary
        support = [ordered]@{
            label = 'Assigned & unplanned support'
            open  = $true
            items = $supportItems
        }
    }

    return $items
}


function New-AzDevOpsDailyViewerTileItems {
    # Dispatch to the per-tile builder. Each returns the tile's normalized
    # "items" payload; Write-AzDevOpsDailyViewerTile stamps + persists it.
    param([Parameter(Mandatory)] [string] $Tile)

    switch ($Tile) {
        'agenda' {
            $items = Get-AzDevOpsDailyViewerAgendaItems
            return $items
        }

        'week' {
            $items = Get-AzDevOpsDailyViewerWeekItems
            return $items
        }

        'activity' {
            $items = Get-AzDevOpsDailyViewerActivityItems
            return $items
        }

        'focus' {
            $items = Get-AzDevOpsDailyViewerFocusItems
            return $items
        }

        default {
            throw "New-AzDevOpsDailyViewerTileItems: unknown tile '$Tile'."
        }
    }
}


# ---------------------------------------------------------------------------
# Cache read / write — cheap read, expensive write kept in separate helpers
# ---------------------------------------------------------------------------

function Write-AzDevOpsDailyViewerTile {
    # EXPENSIVE path: build the tile's payload, then persist it under the active
    # cache slice with a written-at stamp. Returns the same read-model the cheap
    # path returns so POST /refresh and GET share one response shape.
    param([Parameter(Mandatory)] [string] $Tile)

    $path = Get-AzDevOpsDailyViewerTilePath -Tile $Tile
    if (-not $path) {
        throw "Write-AzDevOpsDailyViewerTile: no active cache dir (run az-Connect-AzDevOps first)."
    }

    $dir = Split-Path -Parent $path
    New-AzDevOpsDirectoryIfMissing -Path $dir

    $items = New-AzDevOpsDailyViewerTileItems -Tile $Tile

    $record = [ordered]@{
        tile      = $Tile
        writtenAt = (Get-Date).ToString('o')
        items     = $items
    }

    $json = $record | ConvertTo-Json -Depth $script:AzDevOpsDailyViewerJsonDepth
    Write-AzDevOpsCacheFile -Path $path -Content $json

    $model = Read-AzDevOpsDailyViewerTile -Tile $Tile
    return $model
}


function Read-AzDevOpsDailyViewerTile {
    # CHEAP path: read one tile's cache file and derive its staleness from the
    # file's mtime. Returns $null when the tile has never been written, so the
    # caller can answer 404 rather than fabricate empty data.
    param([Parameter(Mandatory)] [string] $Tile)

    $path = Get-AzDevOpsDailyViewerTilePath -Tile $Tile
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        return $null
    }

    $file = Get-Item -LiteralPath $path
    $ageSeconds = [int]((Get-Date) - $file.LastWriteTime).TotalSeconds
    $isStale = ($ageSeconds -ge $script:AzDevOpsDailyViewerStaleSeconds)

    $raw = Get-Content -LiteralPath $path -Raw

    $record = $null
    try {
        $record = $raw | ConvertFrom-Json
    }
    catch {
        $record = $null
    }

    $writtenAt = if ($record -and $record.writtenAt) {
        $record.writtenAt
    } else {
        $file.LastWriteTime.ToString('o')
    }

    $items = if ($record) {
        $record.items
    } else {
        $null
    }

    $model = [ordered]@{
        tile       = $Tile
        writtenAt  = $writtenAt
        ageSeconds = $ageSeconds
        stale      = $isStale
        items      = $items
    }

    return $model
}


function Initialize-AzDevOpsDailyViewerCache {
    # Seed any tile that has never been written so the very first page load reads
    # data from cache instead of a wall of 404s. Cheap: only fills gaps, never
    # rewrites a tile that already exists (that's what POST /refresh is for).
    $names = Get-AzDevOpsDailyViewerTileNames

    foreach ($name in $names) {
        $path = Get-AzDevOpsDailyViewerTilePath -Tile $name

        if ($path -and -not (Test-Path -LiteralPath $path)) {
            $null = Write-AzDevOpsDailyViewerTile -Tile $name
        }
    }
}


# ---------------------------------------------------------------------------
# Daily full-refresh gating — rebuild every tile once per calendar day
# ---------------------------------------------------------------------------

function Get-AzDevOpsDailyViewerRefreshStampPath {
    # Path to the per-day full-refresh stamp, alongside the tile cache under the
    # active project slice. $null when no cache dir resolves (not connected yet).
    $dir = Get-AzDevOpsDailyViewerCacheDir
    if (-not $dir) {
        return $null
    }

    $path = Join-Path $dir $script:AzDevOpsDailyViewerRefreshStampFile
    return $path
}


function Get-AzDevOpsDailyViewerDayKey {
    # Today's calendar-day key ("2026-07-16") — the unit the daily refresh gates
    # on, so a rebuild happens at most once per day but on the first startup of it.
    param([datetime] $When = (Get-Date))

    $key = $When.ToString($script:AzDevOpsDailyViewerDayKeyFormat)
    return $key
}


function Read-AzDevOpsDailyViewerRefreshDay {
    # The day key recorded by the last full refresh, or $null when the stamp is
    # missing / unreadable (the due check treats that as "never refreshed").
    $path = Get-AzDevOpsDailyViewerRefreshStampPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        return $null
    }

    try {
        $raw    = Get-Content -LiteralPath $path -Raw
        $record = $raw | ConvertFrom-Json

        $day = $record.day
        return $day
    }
    catch {
        return $null
    }
}


function Write-AzDevOpsDailyViewerRefreshStamp {
    # Record that a full refresh ran today, so same-day restarts skip the rebuild.
    $path = Get-AzDevOpsDailyViewerRefreshStampPath
    if (-not $path) {
        return
    }

    $dir = Split-Path -Parent $path
    New-AzDevOpsDirectoryIfMissing -Path $dir

    $record = [ordered]@{
        day         = Get-AzDevOpsDailyViewerDayKey
        refreshedAt = (Get-Date).ToString('o')
    }

    $json = $record | ConvertTo-Json -Depth $script:AzDevOpsDailyViewerJsonDepth
    Write-AzDevOpsCacheFile -Path $path -Content $json
}


function Test-AzDevOpsDailyViewerRefreshDue {
    # $true when no full refresh has run today (stamp missing or from a prior day)
    # — this is what makes the first viewer startup of the day rebuild every tile.
    $recorded = Read-AzDevOpsDailyViewerRefreshDay
    if (-not $recorded) {
        return $true
    }

    $today = Get-AzDevOpsDailyViewerDayKey
    $isDue = ($recorded -ne $today)
    return $isDue
}


function Update-AzDevOpsDailyViewerAllTiles {
    # EXPENSIVE: rebuild every tile's cache, then stamp today's date. Each tile is
    # isolated in its own try/catch so one failing source (a lapsed az login,
    # Outlook unreachable) rebuilds the rest and never aborts startup; the
    # per-tile builders already fail soft, this guards the rare hard throw.
    # Per-tile failures are logged server-side for later diagnosis. The day is
    # stamped only when at least one tile rebuilt, so a startup where every tile
    # hard-throws doesn't burn the day's refresh — the next startup retries.
    $names = Get-AzDevOpsDailyViewerTileNames

    $rebuilt = 0
    foreach ($name in $names) {
        try {
            $null = Write-AzDevOpsDailyViewerTile -Tile $name
            $rebuilt++
        }
        catch {
            Write-AzDevOpsSyncLog "daily-viewer: full refresh of tile '$name' failed: $($_.Exception.Message)"
        }
    }

    if ($rebuilt -gt 0) {
        Write-AzDevOpsDailyViewerRefreshStamp
    }
}


# ---------------------------------------------------------------------------
# Static asset serving
# ---------------------------------------------------------------------------

function Get-AzDevOpsDailyViewerContentType {
    param([Parameter(Mandatory)] [string] $Path)

    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()

    $type = if ($script:AzDevOpsDailyViewerMimeTypes.ContainsKey($ext)) {
        $script:AzDevOpsDailyViewerMimeTypes[$ext]
    } else {
        'application/octet-stream'
    }

    return $type
}


function Resolve-AzDevOpsDailyViewerAssetPath {
    # Map a request path to a file inside the static root, refusing anything that
    # escapes the root (path traversal). Returns $null when the target is outside
    # the root or does not exist, so the router answers 404.
    param(
        [Parameter(Mandatory)] [string] $RequestPath,
        [Parameter(Mandatory)] [string] $Root
    )

    $relative = $RequestPath.TrimStart('/')
    if (-not $relative) {
        $relative = 'index.html'
    }

    $candidate = Join-Path $Root $relative
    $fullCandidate = [System.IO.Path]::GetFullPath($candidate)
    $fullRoot = [System.IO.Path]::GetFullPath($Root)

    $rootPrefix = $fullRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullCandidate.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $fullCandidate -PathType Leaf)) {
        return $null
    }

    return $fullCandidate
}


# ---------------------------------------------------------------------------
# HTTP response writers
# ---------------------------------------------------------------------------

function Add-AzDevOpsDailyViewerSecurityHeaders {
    # Stamp the hardening headers on every response — HTML, static asset, JSON,
    # and error alike — since all of them funnel through the byte writer below.
    # A strict same-origin CSP is the anchor; nosniff stops MIME-confusion,
    # no-referrer keeps local URLs off the wire, and DENY refuses any framing.
    param([Parameter(Mandatory)] [System.Net.HttpListenerResponse] $Response)

    $Response.Headers['Content-Security-Policy'] = $script:AzDevOpsDailyViewerContentSecurityPolicy
    $Response.Headers['X-Content-Type-Options']  = 'nosniff'
    $Response.Headers['Referrer-Policy']         = 'no-referrer'
    $Response.Headers['X-Frame-Options']         = 'DENY'
}


function Write-AzDevOpsDailyViewerBytes {
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerResponse] $Response,
        [Parameter(Mandatory)] [int]    $StatusCode,
        [Parameter(Mandatory)] [string] $ContentType,
        [byte[]] $Body = @()
    )

    Add-AzDevOpsDailyViewerSecurityHeaders -Response $Response

    $Response.StatusCode  = $StatusCode
    $Response.ContentType = $ContentType
    $Response.ContentLength64 = $Body.Length

    if ($Body.Length -gt 0) {
        $Response.OutputStream.Write($Body, 0, $Body.Length)
    }

    $Response.OutputStream.Close()
    $Response.Close()
}


function Write-AzDevOpsDailyViewerJson {
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerResponse] $Response,
        [Parameter(Mandatory)] [int] $StatusCode,
        [Parameter(Mandatory)] [AllowNull()] $Object
    )

    $json = $Object | ConvertTo-Json -Depth $script:AzDevOpsDailyViewerJsonDepth
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    Write-AzDevOpsDailyViewerBytes -Response $Response -StatusCode $StatusCode `
        -ContentType 'application/json; charset=utf-8' -Body $bytes
}


function Write-AzDevOpsDailyViewerError {
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerResponse] $Response,
        [Parameter(Mandatory)] [int]    $StatusCode,
        [Parameter(Mandatory)] [string] $Message
    )

    $payload = [ordered]@{ error = $Message }
    Write-AzDevOpsDailyViewerJson -Response $Response -StatusCode $StatusCode -Object $payload
}


# ---------------------------------------------------------------------------
# Request routing — cheap GET vs expensive POST /refresh kept distinct
# ---------------------------------------------------------------------------

function Get-AzDevOpsDailyViewerTileRoute {
    # Parse an /api/tiles/... path into { Tile; IsRefresh } or $null when it
    # isn't a tile route. Keeps the router readable and the two API verbs apart.
    param([Parameter(Mandatory)] [string] $Path)

    $prefix = '/api/tiles/'
    if (-not $Path.StartsWith($prefix)) {
        return $null
    }

    $rest = $Path.Substring($prefix.Length).Trim('/')
    if (-not $rest) {
        return $null
    }

    $segments = $rest -split '/'
    $tile = $segments[0]

    $isRefresh = ($segments.Count -eq 2 -and $segments[1] -eq 'refresh')
    $isPlain   = ($segments.Count -eq 1)

    if (-not $isRefresh -and -not $isPlain) {
        return $null
    }

    $route = [PSCustomObject]@{
        Tile      = $tile
        IsRefresh = $isRefresh
    }
    return $route
}


function Invoke-AzDevOpsDailyViewerApiRequest {
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerContext] $Context,
        [Parameter(Mandatory)] [PSCustomObject] $Route
    )

    $request  = $Context.Request
    $response = $Context.Response
    $method   = $request.HttpMethod

    if (-not (Test-AzDevOpsDailyViewerTileName -Name $Route.Tile)) {
        Write-AzDevOpsDailyViewerError -Response $response -StatusCode 404 -Message "Unknown tile '$($Route.Tile)'."
        return
    }

    if ($Route.IsRefresh) {
        if ($method -ne 'POST') {
            Write-AzDevOpsDailyViewerError -Response $response -StatusCode 405 -Message 'Refresh requires POST.'
            return
        }

        $model = Write-AzDevOpsDailyViewerTile -Tile $Route.Tile
        Write-AzDevOpsDailyViewerJson -Response $response -StatusCode 200 -Object $model
        return
    }

    if ($method -ne 'GET') {
        Write-AzDevOpsDailyViewerError -Response $response -StatusCode 405 -Message 'Tile read requires GET.'
        return
    }

    $model = Read-AzDevOpsDailyViewerTile -Tile $Route.Tile
    if ($null -eq $model) {
        Write-AzDevOpsDailyViewerError -Response $response -StatusCode 404 -Message "Tile '$($Route.Tile)' has no cache yet."
        return
    }

    Write-AzDevOpsDailyViewerJson -Response $response -StatusCode 200 -Object $model
}


function Invoke-AzDevOpsDailyViewerStaticRequest {
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerContext] $Context,
        [Parameter(Mandatory)] [string] $StaticRoot
    )

    $request  = $Context.Request
    $response = $Context.Response

    if ($request.HttpMethod -ne 'GET') {
        Write-AzDevOpsDailyViewerError -Response $response -StatusCode 405 -Message 'Static assets are GET only.'
        return
    }

    $assetPath = Resolve-AzDevOpsDailyViewerAssetPath -RequestPath $request.Url.AbsolutePath -Root $StaticRoot
    if (-not $assetPath) {
        Write-AzDevOpsDailyViewerError -Response $response -StatusCode 404 -Message 'Not found.'
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes($assetPath)
    $contentType = Get-AzDevOpsDailyViewerContentType -Path $assetPath

    Write-AzDevOpsDailyViewerBytes -Response $response -StatusCode 200 -ContentType $contentType -Body $bytes
}


function Invoke-AzDevOpsDailyViewerRequest {
    # Front door: API routes go to the tile handler (cheap GET / expensive POST),
    # everything else is treated as a static-asset GET. Any handler failure is
    # turned into a 500 so one bad request can never kill the serving loop.
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerContext] $Context,
        [Parameter(Mandatory)] [string] $StaticRoot
    )

    $response = $Context.Response

    try {
        $route = Get-AzDevOpsDailyViewerTileRoute -Path $Context.Request.Url.AbsolutePath

        if ($null -ne $route) {
            Invoke-AzDevOpsDailyViewerApiRequest -Context $Context -Route $route
        } else {
            Invoke-AzDevOpsDailyViewerStaticRequest -Context $Context -StaticRoot $StaticRoot
        }
    }
    catch {
        # Keep the exception detail (which can name filesystem paths) server-side;
        # hand the browser a generic message only.
        Write-Host "Daily viewer request error: $($_.Exception.Message)" -ForegroundColor Red

        try {
            Write-AzDevOpsDailyViewerError -Response $response -StatusCode 500 -Message 'Internal server error.'
        }
        catch {
            # response already closed / client gone — nothing more we can do
        }
    }
}


# ---------------------------------------------------------------------------
# Server lifecycle
# ---------------------------------------------------------------------------

function Get-AzDevOpsDailyViewerPrefix {
    param([Parameter(Mandatory)] [int] $Port)

    $prefix = "http://$($script:AzDevOpsDailyViewerLoopbackAddress):$Port/"
    return $prefix
}


function Open-AzDevOpsDailyViewerBrowser {
    param([Parameter(Mandatory)] [string] $Url)

    try {
        if (Test-WpfIsWindows) {
            Start-Process $Url
        } elseif ($IsMacOS) {
            & open $Url
        } else {
            & xdg-open $Url
        }
    }
    catch {
        Write-Host "Open $Url in your browser." -ForegroundColor Yellow
    }
}


function az-Start-AzDevOpsDailyViewer {
    <#
    .SYNOPSIS
        Serve the Azure DevOps daily viewer on 127.0.0.1 with a per-tile cache API.

    .DESCRIPTION
        Binds a System.Net.HttpListener to loopback only, serves daily-viewer/'s
        static assets, and exposes GET /api/tiles/<name> (cheap cache read) and
        POST /api/tiles/<name>/refresh (expensive re-query + cache rewrite). The
        az login / PAT never leaves this process; responses carry only work-item
        and agenda data. Press Ctrl+C to stop.

        On the first startup of each calendar day every tile is rebuilt before
        serving, so the dashboard opens on today's real agenda and work instead
        of yesterday's cache. Same-day restarts skip the rebuild (and only fill
        any missing tile) so they stay instant. Pass -Refresh to force a full
        rebuild on demand regardless of the day.

    .PARAMETER Port
        Loopback TCP port to listen on. Defaults to 8770.

    .PARAMETER NoBrowser
        Skip auto-opening the default browser (useful for scripted / curl checks).

    .PARAMETER Refresh
        Force a full rebuild of all four tiles at startup, regardless of whether
        the daily refresh has already run. Use it to reload the whole dashboard
        without waiting for the next day or clicking refresh on each tile.
    #>
    param(
        [int]    $Port = $script:AzDevOpsDailyViewerDefaultPort,
        [switch] $NoBrowser,
        [switch] $Refresh
    )

    $staticRoot = Get-AzDevOpsDailyViewerStaticRoot
    if (-not (Test-Path -LiteralPath $staticRoot)) {
        Write-Host "Daily viewer assets not found at $staticRoot" -ForegroundColor Red
        return
    }

    $cacheDir = Get-AzDevOpsDailyViewerCacheDir
    if (-not $cacheDir) {
        Write-Host 'No active Azure DevOps cache dir. Run az-Connect-AzDevOps first.' -ForegroundColor Yellow
        return
    }

    if ($Refresh -or (Test-AzDevOpsDailyViewerRefreshDue)) {
        Write-Host 'Refreshing all tiles for today...' -ForegroundColor Cyan
        Update-AzDevOpsDailyViewerAllTiles
    } else {
        Initialize-AzDevOpsDailyViewerCache
    }

    $prefix = Get-AzDevOpsDailyViewerPrefix -Port $Port
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($prefix)

    try {
        $listener.Start()
    }
    catch [System.Net.HttpListenerException] {
        Write-Host "Could not bind $prefix - $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'On Windows a one-time URL reservation may be needed:' -ForegroundColor Yellow
        Write-Host "  netsh http add urlacl url=$prefix user=$env:USERNAME" -ForegroundColor Yellow
        Write-Host 'Or pass a different -Port.' -ForegroundColor Yellow
        return
    }

    Write-Host "Daily viewer serving at $prefix (Ctrl+C to stop)" -ForegroundColor Green
    Write-Host "  cache: $cacheDir" -ForegroundColor DarkGray

    if (-not $NoBrowser) {
        Open-AzDevOpsDailyViewerBrowser -Url $prefix
    }

    try {
        while ($listener.IsListening) {
            $context = $listener.GetContext()
            Invoke-AzDevOpsDailyViewerRequest -Context $context -StaticRoot $staticRoot
        }
    }
    catch {
        # GetContext throws when the listener is stopped (Ctrl+C / disposal) —
        # fall through to the finally so shutdown stays clean.
    }
    finally {
        if ($listener.IsListening) {
            $listener.Stop()
        }
        $listener.Close()
        Write-Host 'Daily viewer stopped.' -ForegroundColor DarkGray
    }
}
