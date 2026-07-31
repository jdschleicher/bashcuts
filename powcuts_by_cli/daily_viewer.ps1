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
$script:AzDevOpsDailyViewerMarkerSet       = 'set'     # the viewer toggled this meeting to "all set"
$script:AzDevOpsDailyViewerPrepTile        = 'prep'    # the tile whose prep list carries the toggle
$script:AzDevOpsDailyViewerMarkerStoreFile = 'prep-markers.json'  # durable "all set" ids, beside the tile cache
$script:AzDevOpsDailyViewerMaxRequestBytes = 4096      # cap on an API request body (the marker POST is tiny)
$script:AzDevOpsDailyViewerMaxCreateBytes  = 65536     # cap on a create POST body (description + AC + a story batch)
$script:AzDevOpsDailyViewerTimerMaxSeconds = 86400     # sanity cap on a client-reported timer duration (one day)
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

# The week tile is "Stories to complete" — the work the user personally finishes.
# Assigned Tasks/Features are excluded; only these completable types survive the filter.
$script:AzDevOpsDailyViewerWeekTypes = @('User Story', 'Bug')

# Create-mode work-item types (Epic #228 sub-issue B). Each maps a form type to
# the parent type it links up to (empty = a root item) and whether it carries
# story points / acceptance criteria in the stock Agile and Scrum templates — so
# one spec drives both the create call and which fields the endpoint honors.
# 'FeatureStories' is handled as a batch (a Feature plus its child User Stories)
# and reuses the Feature / User Story specs below rather than adding a fourth row.
$script:AzDevOpsDailyViewerCreateTypes = [ordered]@{
    'User Story' = @{ ParentType = 'Feature';    HasPoints = $true;  HasAcceptance = $true  }
    'Task'       = @{ ParentType = 'User Story'; HasPoints = $false; HasAcceptance = $false }
    'Feature'    = @{ ParentType = 'Epic';       HasPoints = $false; HasAcceptance = $false }
    'Epic'       = @{ ParentType = '';           HasPoints = $false; HasAcceptance = $false }
}

$script:AzDevOpsDailyViewerEpicType           = 'Epic'
$script:AzDevOpsDailyViewerStoryType          = 'User Story'
$script:AzDevOpsDailyViewerFeatureType        = 'Feature'
$script:AzDevOpsDailyViewerFeatureStoriesType = 'FeatureStories'  # batch: a Feature + its child User Stories
$script:AzDevOpsDailyViewerDefaultPriority    = 2                 # ADO 1-4 ramp midpoint, used when a form omits priority
$script:AzDevOpsDailyViewerMinPriority        = 1
$script:AzDevOpsDailyViewerMaxPriority        = 4

# Draft-mode item types (Epic #228 sub-issue C). The browser brain-dump builder
# nests these four tiers exactly like the terminal draft (azdevops_draft.ps1);
# the add endpoint validates a supplied type against this set and the parent /
# child tier rules against the draft's own Test-AzDevOpsDraftTypeMatchesTier.
$script:AzDevOpsDailyViewerDraftTypes = @('Epic', 'Feature', 'User Story', 'Task')

# Unplanned-work capture (Epic #228 sub-issue E, #233). The browser files a
# firefight against the daily catch-all story reusing azdevops_unplanned.ps1's
# helpers; these bound a client-supplied payload so a bogus minutes / item count
# stays sane.
$script:AzDevOpsDailyViewerUnplannedDefaultMinutes = 5      # firefight minutes the panel pre-fills
$script:AzDevOpsDailyViewerUnplannedMaxMinutes     = 1440   # sanity cap on client-reported minutes (one day)
$script:AzDevOpsDailyViewerUnplannedMaxItems       = 200    # cap on captured items per firefight
$script:AzDevOpsDailyViewerUnplannedMaxTitle       = 255    # server-side clamp on the firefight title (mirrors the client maxlength)

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
    $names = @('agenda', 'prep', 'week', 'activity', 'focus')
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

    return $events
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


function New-AzDevOpsDailyViewerTime {
    # Front-end time object for one calendar event: a 'h:mm tt' clock label for a
    # timed meeting, 'All day' for an all-day one, plus the event's ISO start so the
    # view can stamp a <time datetime> attribute. Shared by the agenda and prep
    # nodes so both tiles read a meeting's start identically (extracted per
    # CLAUDE.md's no-copy-paste rule when the prep node became the second copy).
    param([Parameter(Mandatory)] $CalendarEvent)

    $start = $CalendarEvent.Start

    $label = if ($CalendarEvent.IsAllDay) {
        'All day'
    } else {
        $start.ToString('h:mm tt')
    }

    $time = [ordered]@{
        label    = $label
        datetime = $start.ToString('o')
    }

    return $time
}


function New-AzDevOpsDailyViewerAgendaNode {
    # Normalize one ol-Get-OutlookAgenda row into the front-end event shape.
    param([Parameter(Mandatory)] $CalendarEvent)

    $time = New-AzDevOpsDailyViewerTime -CalendarEvent $CalendarEvent

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


# --- Events-to-prepare-for tile ---------------------------------------------

function Get-AzDevOpsDailyViewerPrepItems {
    # "Events to prepare for" = the next two weeks of meetings, widened from
    # today so nothing on the calendar sneaks up unprepared. Each row carries a
    # stable event id, a short date chip, the meeting's ISO datetime, the same
    # agenda-style time + location detail the Agenda tile shows, and a default
    # "prep still needed" marker. The Teams join link rides on the location object
    # (via New-AzDevOpsDailyViewerLocation) exactly like the agenda node, so the
    # front-end prepRow renders it once — no top-level link to double it up.
    # The builder always writes the default marker; the durable "all set" choice
    # is overlaid by id on the way out (see Set-AzDevOpsDailyViewerPrepMarkersFromStore)
    # so it survives a cache reload.
    $events = @(Get-AzDevOpsDailyViewerAgendaEvents -Days $script:AzDevOpsDailyViewerPrepWindowDays)

    $prep = @($events | ForEach-Object {
        $node = [ordered]@{
            id       = [string]$_.Id
            title    = [string]$_.Subject
            date     = Format-AzDevOpsDailyViewerShortDate -When $_.Start
            datetime = $_.Start.ToString('o')
            time     = New-AzDevOpsDailyViewerTime -CalendarEvent $_
            location = New-AzDevOpsDailyViewerLocation -CalendarEvent $_
            marker   = $script:AzDevOpsDailyViewerMarkerNeeded
        }

        $node
    })

    return $prep
}


function Get-AzDevOpsDailyViewerPrepTileItems {
    # The prep tile is a flat "items" payload (the front-end renderPrep reads
    # model.items directly). The durable "all set" markers are overlaid by id on
    # read, so the builder just emits the default-marker rows here.
    $prepItems = Get-AzDevOpsDailyViewerPrepItems

    $items = [ordered]@{
        items = $prepItems
    }

    return $items
}


# --- This week's focus tile -------------------------------------------------

function Get-AzDevOpsDailyViewerWeekItems {
    $assigned = @(Get-AzDevOpsDailyViewerAssignedRows)

    $activeRows = Get-AzDevOpsDailyViewerActiveRows -Rows $assigned

    $completableRows = @($activeRows | Where-Object { $_.Type -in $script:AzDevOpsDailyViewerWeekTypes })

    $sprintRows = Get-AzDevOpsDailyViewerCurrentSprintRows -Rows $completableRows -FallbackToAllActive

    $storyItems = @($sprintRows | ForEach-Object {
        New-AzDevOpsDailyViewerWorkItemNode -Row $_ -LinkTitle -Date $_.TargetDate
    })

    $items = [ordered]@{
        stories = [ordered]@{
            label = 'Stories to complete'
            open  = $true
            items = $storyItems
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
    # Filter rows to the current sprint. The iteration path comes from the
    # cache-only Resolve-AzDevOpsCurrentIterationFromCache (no live `az` callout,
    # honoring the viewer's read path), falling back to $env:AZ_ITERATION. When
    # neither resolves the default is to return empty rather than guessing a
    # sprint (the Recent Activity "Current sprint" group), but the focus tiles pass
    # -FallbackToAllActive to get the input rows back unfiltered instead, so a
    # stale or empty iteration cache widens scope to all active items rather than
    # blanking the tile. Exact-path match mirrors Get-AzDevOpsDayViewRows.
    # Comma-wrapped returns so an empty result stays an empty array through the
    # caller's assignment instead of unrolling to $null (which the -Rows
    # [object[]] bind would reject).
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rows,
        [switch] $FallbackToAllActive
    )

    $current = Resolve-AzDevOpsCurrentIterationFromCache

    $iterationPath = Resolve-AzDevOpsIterationPathOrEnv -Current $current

    if (-not $iterationPath) {
        if ($FallbackToAllActive) {
            return ,$Rows
        }

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
    $sprintRows = Get-AzDevOpsDailyViewerCurrentSprintRows -Rows $activeRows -FallbackToAllActive
    $supportRows = @($sprintRows | Where-Object {
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

        'prep' {
            $items = Get-AzDevOpsDailyViewerPrepTileItems
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

    # The prep tile's markers live in their own store, not the tile cache, so a
    # toggle survives a reload without a re-query. Overlay it here — the one seam
    # both the cheap GET and the POST /refresh return through (refresh ends by
    # re-reading) — so every response reflects the marker the user last chose.
    if ($Tile -eq $script:AzDevOpsDailyViewerPrepTile) {
        Set-AzDevOpsDailyViewerPrepMarkersFromStore -Items $items
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
# Prep "all set" marker store — durable per-project toggle state
#
# The prep tile's rows carry an "all set" / "prep still needed" marker the
# viewer flips per meeting. That choice has to outlive a cache reload, so it
# lives in its own tiny JSON file beside the tile cache (the set of "all set"
# event ids), keyed by the stable Outlook event id. It sits under the same
# active-project cache slice as the tiles, so it follows az-Use-AzDevOpsProject
# and never leaks one project's choices into another. The read path overlays it
# onto the prep payload, so the store — not the tile cache — is the single
# source of truth for markers.
# ---------------------------------------------------------------------------

function Get-AzDevOpsDailyViewerMarkerStorePath {
    $dir = Get-AzDevOpsDailyViewerCacheDir
    if (-not $dir) {
        return $null
    }

    $path = Join-Path $dir $script:AzDevOpsDailyViewerMarkerStoreFile
    return $path
}


function Read-AzDevOpsDailyViewerMarkerStore {
    # The set of "all set" event ids as a hashtable used as a set (id -> $true),
    # so callers test membership with .ContainsKey. Fails soft to an empty set
    # when the file is missing or unreadable — a corrupt store never blocks a
    # render, it just falls back to "nothing marked".
    $set = @{}

    $path = Get-AzDevOpsDailyViewerMarkerStorePath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        return $set
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw
        $record = $raw | ConvertFrom-Json

        foreach ($id in @($record.setIds)) {
            $key = [string]$id
            if ($key) {
                $set[$key] = $true
            }
        }
    }
    catch {
        return @{}
    }

    return $set
}


function Save-AzDevOpsDailyViewerMarkerStore {
    # Persist the "all set" id set wholesale — the set is small and the write is
    # atomic through Write-AzDevOpsCacheFile. Throws when there's no active cache
    # dir so the POST handler can answer rather than silently drop the toggle.
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $SetIds)

    $path = Get-AzDevOpsDailyViewerMarkerStorePath
    if (-not $path) {
        throw "Save-AzDevOpsDailyViewerMarkerStore: no active cache dir (run az-Connect-AzDevOps first)."
    }

    $dir = Split-Path -Parent $path
    New-AzDevOpsDirectoryIfMissing -Path $dir

    $record = [ordered]@{
        setIds    = @($SetIds)
        updatedAt = (Get-Date).ToString('o')
    }

    $json = $record | ConvertTo-Json -Depth $script:AzDevOpsDailyViewerJsonDepth
    Write-AzDevOpsCacheFile -Path $path -Content $json
}


function Set-AzDevOpsDailyViewerPrepMarker {
    # Flip one meeting's durable marker: add its id to the "all set" set, or drop
    # it back to "prep still needed". Returns the marker that was stored so the
    # caller can echo it back to the client.
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Marker
    )

    $store = Read-AzDevOpsDailyViewerMarkerStore

    if ($Marker -eq $script:AzDevOpsDailyViewerMarkerSet) {
        $store[$Id] = $true
    } else {
        $store.Remove($Id)
    }

    $ids = @($store.Keys)
    Save-AzDevOpsDailyViewerMarkerStore -SetIds $ids

    return $Marker
}


function Set-AzDevOpsDailyViewerPrepMarkersFromStore {
    # Overlay the durable "all set" set onto the prep tile's rows in place, so the
    # marker the user last chose wins over the default the builder wrote. The prep
    # tile payload is a flat { items = @(rows) }; no-op when it has no rows (an
    # empty or legacy cache).
    param([Parameter(Mandatory)] [AllowNull()] $Items)

    if ($null -eq $Items -or $null -eq $Items.items) {
        return
    }

    $store = Read-AzDevOpsDailyViewerMarkerStore

    foreach ($item in @($Items.items)) {
        $id = [string]$item.id

        $item.marker = if ($id -and $store.ContainsKey($id)) {
            $script:AzDevOpsDailyViewerMarkerSet
        } else {
            $script:AzDevOpsDailyViewerMarkerNeeded
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

function Read-AzDevOpsDailyViewerRequestJson {
    # Parse a small JSON request body, bounded so a runaway/oversized POST can't
    # exhaust memory. Returns the parsed object, or $null when the body is too
    # large, empty, or not valid JSON — the caller answers 400 on $null. The
    # store is never touched here, so a rejected body can't corrupt it. -MaxBytes
    # lets a larger surface (the create payloads, which carry descriptions,
    # acceptance criteria, and story batches) raise the cap above the tiny
    # prep-marker default without loosening it for the marker path.
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerRequest] $Request,
        [int] $MaxBytes = $script:AzDevOpsDailyViewerMaxRequestBytes
    )

    $maxBytes = $MaxBytes

    # A chunked / unknown-length body reports ContentLength64 -1 and would skip
    # the size guard (ReadToEnd would buffer it all first), so reject it up front
    # along with anything over the cap.
    if ($Request.ContentLength64 -lt 0 -or $Request.ContentLength64 -gt $maxBytes) {
        return $null
    }

    # Require a JSON content type. Beyond correctness this blunts cross-site POSTs:
    # a browser can't set application/json cross-origin without a preflight this
    # loopback server never satisfies, so a simple-request forgery can't reach the
    # store — it lands here as a rejected body instead.
    $contentType = [string]$Request.ContentType
    if ($contentType -notlike '*application/json*') {
        return $null
    }

    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    try {
        $text = $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }

    if (-not $text -or $text.Length -gt $maxBytes) {
        return $null
    }

    try {
        $parsed = $text | ConvertFrom-Json
    }
    catch {
        return $null
    }

    return $parsed
}


function Split-AzDevOpsDailyViewerApiPath {
    # Shared scaffolding for the /api/* route parsers: require a known prefix,
    # trim the surrounding slashes, and split what's left into path segments.
    # Returns $null when the path doesn't carry the prefix or is empty after it,
    # so each parser (tiles / create) keeps only its own segment-shape rules. The
    # unary-comma return keeps a single-segment result an array — PowerShell would
    # otherwise unroll it to a scalar and break the callers' .Count checks.
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Prefix
    )

    if (-not $Path.StartsWith($Prefix)) {
        return $null
    }

    $rest = $Path.Substring($Prefix.Length).Trim('/')
    if (-not $rest) {
        return $null
    }

    $segments = $rest -split '/'
    return ,$segments
}


function Get-AzDevOpsDailyViewerActionRoute {
    # Parse a single-segment /api/<namespace>/<action> path into { Action } or $null.
    # Shared by the create / draft / timer / unplanned route parsers — every one of
    # those namespaces is a flat "one action per path" surface, so the only thing that
    # varies is the prefix. (The tile route stays separate: it carries multi-segment
    # /<name>/refresh|prep-marker paths.)
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Prefix
    )

    $segments = Split-AzDevOpsDailyViewerApiPath -Path $Path -Prefix $Prefix
    if ($null -eq $segments) {
        return $null
    }

    if ($segments.Count -ne 1) {
        return $null
    }

    $route = [PSCustomObject]@{
        Action = $segments[0]
    }
    return $route
}


function Test-AzDevOpsDailyViewerActionMethod {
    # Shared method / content-type gate for the single-action write surfaces (create /
    # draft / timer / unplanned): the read-only action answers a GET, every other
    # action requires POST + application/json — a JSON content-type forces a preflight
    # this loopback server never answers, so a cross-origin simple-request forgery
    # can't reach a write. Writes the 405 / 415 error itself and returns $false when
    # the method or content-type is wrong; $true when the handler may proceed to its
    # action switch. Private helper, so an unapproved verb is fine.
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerRequest]  $Request,
        [Parameter(Mandatory)] [System.Net.HttpListenerResponse] $Response,
        [Parameter(Mandatory)] [string] $Action,
        [Parameter(Mandatory)] [string] $ReadOnlyAction,
        [Parameter(Mandatory)] [string] $WriteLabel
    )

    if ($Action -eq $ReadOnlyAction) {
        if ($Request.HttpMethod -ne 'GET') {
            Write-AzDevOpsDailyViewerError -Response $Response -StatusCode 405 -Message "The $ReadOnlyAction action is read-only (GET)."
            return $false
        }

        return $true
    }

    if ($Request.HttpMethod -ne 'POST') {
        Write-AzDevOpsDailyViewerError -Response $Response -StatusCode 405 -Message "$WriteLabel require POST."
        return $false
    }

    if ([string]$Request.ContentType -notlike '*application/json*') {
        Write-AzDevOpsDailyViewerError -Response $Response -StatusCode 415 -Message "$WriteLabel require an application/json body."
        return $false
    }

    return $true
}


function Get-AzDevOpsDailyViewerTileRoute {
    # Parse an /api/tiles/... path into { Tile; IsRefresh; IsPrepMarker } or
    # $null when it isn't a tile route. Keeps the router readable and the API
    # verbs (cheap GET, expensive refresh, prep-marker write) apart.
    param([Parameter(Mandatory)] [string] $Path)

    $segments = Split-AzDevOpsDailyViewerApiPath -Path $Path -Prefix '/api/tiles/'
    if ($null -eq $segments) {
        return $null
    }

    $tile = $segments[0]

    $isRefresh    = ($segments.Count -eq 2 -and $segments[1] -eq 'refresh')
    $isPrepMarker = ($segments.Count -eq 2 -and $segments[1] -eq 'prep-marker')
    $isPlain      = ($segments.Count -eq 1)

    if (-not $isRefresh -and -not $isPrepMarker -and -not $isPlain) {
        return $null
    }

    $route = [PSCustomObject]@{
        Tile         = $tile
        IsRefresh    = $isRefresh
        IsPrepMarker = $isPrepMarker
    }
    return $route
}


function Get-AzDevOpsDailyViewerCreateRoute {
    # Parse an /api/create/<action> path into { Action } or $null when it isn't a
    # create route. The create surface is the Azure DevOps creation mode (Epic
    # #228): the whole namespace is POST + JSON only, enforced by the handler.
    # Only single-segment actions are recognized; the foundation ships `ping` and
    # sub-issues B–E add their own actions to the handler's switch.
    param([Parameter(Mandatory)] [string] $Path)

    $route = Get-AzDevOpsDailyViewerActionRoute -Path $Path -Prefix '/api/create/'
    return $route
}


function Get-AzDevOpsDailyViewerParentCandidates {
    # Cached parent-picker rows for one work-item type: the id / title / state of
    # every item of $Type in hierarchy.json, so the create forms offer a real
    # parent instead of a free-text id. Cache-only — an empty/missing cache yields
    # an empty list and the form falls back to "no parent".
    param(
        [Parameter(Mandatory)] [AllowNull()] $Hierarchy,
        [Parameter(Mandatory)] [string] $Type
    )

    $rows = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Hierarchy) {
        return $rows
    }

    foreach ($item in $Hierarchy) {
        if ($item.Type -eq $Type) {
            $rows.Add([ordered]@{
                id    = $item.Id
                title = $item.Title
                state = $item.State
            })
        }
    }

    return $rows
}


function Get-AzDevOpsDailyViewerCreateOptions {
    # Picker data for the create forms, read from the local cache only — never a
    # live az call, since this answers a GET and must stay instant: the project's
    # area and iteration paths plus the parent candidates per type (Epics for a
    # Feature, Features for a Story, User Stories for a Task). Reuses the same
    # classification + hierarchy caches the terminal pickers read, so the browser
    # and terminal offer the same choices. Empty caches yield empty lists.
    $areaTree = Read-AzDevOpsClassificationCache -Kind 'Area'
    $areas    = ConvertTo-AzDevOpsClassificationPaths -Root $areaTree -Kind 'Area'

    $iterationTree = Read-AzDevOpsClassificationCache -Kind 'Iteration'
    $iterations    = ConvertTo-AzDevOpsClassificationPaths -Root $iterationTree -Kind 'Iteration'

    $hierarchy = Read-AzDevOpsHierarchyCache

    $parents = [ordered]@{
        Epic         = Get-AzDevOpsDailyViewerParentCandidates -Hierarchy $hierarchy -Type $script:AzDevOpsDailyViewerEpicType
        Feature      = Get-AzDevOpsDailyViewerParentCandidates -Hierarchy $hierarchy -Type $script:AzDevOpsDailyViewerFeatureType
        'User Story' = Get-AzDevOpsDailyViewerParentCandidates -Hierarchy $hierarchy -Type $script:AzDevOpsDailyViewerStoryType
    }

    $options = [ordered]@{
        areas            = @($areas)
        iterations       = @($iterations)
        parents          = $parents
        defaultArea      = $env:AZ_AREA
        defaultIteration = $env:AZ_ITERATION
    }
    return $options
}


function Get-AzDevOpsDailyViewerCreatePriority {
    # Clamp a form-supplied priority to the ADO 1-4 range, falling back to the
    # midpoint default when it's absent or out of range — the create funcs'
    # "default when unset" posture, without a prompt.
    param([AllowNull()] $Value)

    $priority = $script:AzDevOpsDailyViewerDefaultPriority
    if ($null -eq $Value) {
        return $priority
    }

    $parsed = 0
    $inRange =
        [int]::TryParse([string]$Value, [ref]$parsed) -and
        $parsed -ge $script:AzDevOpsDailyViewerMinPriority -and
        $parsed -le $script:AzDevOpsDailyViewerMaxPriority

    if ($inRange) {
        $priority = $parsed
    }
    return $priority
}


function Get-AzDevOpsDailyViewerCreatePoints {
    # Parse form-supplied story points to a non-negative int, or -1 to omit the
    # field (Invoke-AzDevOpsWorkItemCreate treats -1 as "don't send it").
    param([AllowNull()] $Value)

    if ($null -eq $Value -or [string]$Value -eq '') {
        return -1
    }

    $parsed = -1
    if ([int]::TryParse([string]$Value, [ref]$parsed) -and $parsed -ge 0) {
        return $parsed
    }
    return -1
}


function Get-AzDevOpsDailyViewerParentId {
    # Resolve the parent id a create links to: -1 (no link) when the type is a
    # root item or the form left it blank / invalid, else the positive id. Parent
    # linking is best-effort in the create core, so an orphan is allowed rather
    # than an error.
    param(
        [AllowNull()] $Value,
        [bool] $HasParent
    )

    if (-not $HasParent -or $null -eq $Value) {
        return -1
    }

    $parsed = -1
    if ([int]::TryParse([string]$Value, [ref]$parsed) -and $parsed -gt 0) {
        return $parsed
    }
    return -1
}


function New-AzDevOpsDailyViewerWorkItem {
    # Create one work item — and link it to a parent when one applies — through
    # the non-interactive create core: Invoke-AzDevOpsWorkItemCreate then
    # Invoke-AzDevOpsParentLink, the same helpers the terminal az-New-* functions
    # wrap. The interactive orchestrators are deliberately NOT used here: they
    # prompt for required fields / parent / description and open a browser, any of
    # which would block this HTTP handler. Returns an ordered result object.
    param(
        [Parameter(Mandatory)] [string] $CreateType,
        [Parameter(Mandatory)] [string] $Title,
        [string] $Description,
        [Parameter(Mandatory)] [int] $Priority,
        [int]    $StoryPoints = -1,
        [string] $AcceptanceCriteria,
        [Parameter(Mandatory)] [string] $Area,
        [Parameter(Mandatory)] [string] $Iteration,
        [int]    $ParentId = -1
    )

    $created = Invoke-AzDevOpsWorkItemCreate `
        -Type               $CreateType `
        -Title              $Title `
        -Description        $Description `
        -Priority           $Priority `
        -StoryPoints        $StoryPoints `
        -AcceptanceCriteria $AcceptanceCriteria `
        -Area               $Area `
        -Iteration          $Iteration

    if (-not $created.Ok) {
        return [ordered]@{
            ok    = $false
            type  = $CreateType
            title = $Title
            error = $created.Error
        }
    }

    $result = [ordered]@{
        ok     = $true
        id     = $created.Id
        url    = $created.Url
        type   = $CreateType
        title  = $Title
        linked = $false
    }

    if ($ParentId -gt 0) {
        $link = Invoke-AzDevOpsParentLink -Id $created.Id -ParentId $ParentId
        $result.linked = $link.Ok
        if (-not $link.Ok) {
            $result.linkError = $link.Error
        }
    }

    # Append the new item to hierarchy.json so a chained create in the same
    # session sees it — the parent pickers and az-Show-Tree read that cache, so a
    # Feature just made from the browser is immediately pickable as a Story's
    # parent without waiting for the next az-Sync-AzDevOpsCache. Best-effort: the
    # helper swallows any cache-write failure so it never fails the create that
    # just succeeded. The recorded parent reflects the actual server link — the
    # parent id only when the link succeeded, 0 (parentless) otherwise — matching
    # the terminal creators' Invoke-AzDevOpsCreateAndLink behavior.
    $linkedParentId = if ($ParentId -gt 0 -and $result.linked) {
        $ParentId
    } else {
        0
    }

    Add-AzDevOpsHierarchyCacheItem `
        -Id        $created.Id `
        -Type      $CreateType `
        -Title     $Title `
        -Iteration $Iteration `
        -AreaPath  $Area `
        -ParentId  $linkedParentId

    return $result
}


function New-AzDevOpsDailyViewerFeatureWithStories {
    # The Feature+Stories batch: create the Feature, then each child User Story
    # linked to it — the same two-tier result the terminal az-New-AzDevOpsFeature
    # -> az-New-AzDevOpsFeatureStories hand-off produces, but driven from the
    # supplied payload instead of a Read-Host loop. A story with a blank title is
    # skipped; a story create that fails is recorded and the batch continues,
    # matching the terminal batch's fail-soft behavior.
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Payload,
        [Parameter(Mandatory)] [string] $Area,
        [Parameter(Mandatory)] [string] $Iteration
    )

    $featurePriority = Get-AzDevOpsDailyViewerCreatePriority -Value $Payload.priority
    $featureParentId = Get-AzDevOpsDailyViewerParentId -Value $Payload.parentId -HasParent $true

    $feature = New-AzDevOpsDailyViewerWorkItem `
        -CreateType  $script:AzDevOpsDailyViewerFeatureType `
        -Title       ([string]$Payload.title).Trim() `
        -Description ([string]$Payload.description) `
        -Priority    $featurePriority `
        -Area        $Area `
        -Iteration   $Iteration `
        -ParentId    $featureParentId

    $storyResults = New-Object System.Collections.Generic.List[object]

    if ($feature.ok) {
        $stories = @($Payload.stories)
        foreach ($story in $stories) {
            if ($null -eq $story) {
                continue
            }

            $storyTitle = ([string]$story.title).Trim()
            if (-not $storyTitle) {
                continue
            }

            $storyPriority = Get-AzDevOpsDailyViewerCreatePriority -Value $story.priority
            $storyPoints   = Get-AzDevOpsDailyViewerCreatePoints -Value $story.storyPoints

            $storyResult = New-AzDevOpsDailyViewerWorkItem `
                -CreateType         $script:AzDevOpsDailyViewerStoryType `
                -Title              $storyTitle `
                -Description        ([string]$story.description) `
                -Priority           $storyPriority `
                -StoryPoints        $storyPoints `
                -AcceptanceCriteria ([string]$story.acceptanceCriteria) `
                -Area               $Area `
                -Iteration          $Iteration `
                -ParentId           $feature.id

            $storyResults.Add($storyResult)
        }
    }

    $batch = [ordered]@{
        ok      = $feature.ok
        feature = $feature
        stories = $storyResults
    }
    return $batch
}


function New-AzDevOpsDailyViewerCreateError {
    # Shape a create failure response — { StatusCode; Body{ ok:$false; error } } —
    # in one place so the validator and gate don't repeat the literal. 400 for a
    # malformed/incomplete payload; 200 with ok:$false for an auth/create failure
    # the form surfaces (nothing 500s silently).
    param(
        [Parameter(Mandatory)] [int]    $Code,
        [Parameter(Mandatory)] [string] $Message
    )

    $body = [ordered]@{ ok = $false; error = $Message }
    $outcome = @{ StatusCode = $Code; Body = $body }
    return $outcome
}


function New-AzDevOpsDailyViewerSingleWorkItem {
    # The single-item arm: resolve the spec-gated fields (points / acceptance only
    # when the type carries them, parent only when it links up) and create + link
    # one work item. Peer of New-AzDevOpsDailyViewerFeatureWithStories, so
    # Invoke-AzDevOpsDailyViewerCreateWorkItem stays a clean validate -> dispatch.
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Payload,
        [Parameter(Mandatory)] [string]    $Type,
        [Parameter(Mandatory)] [hashtable] $Spec,
        [Parameter(Mandatory)] [string]    $Title,
        [Parameter(Mandatory)] [string]    $Area,
        [Parameter(Mandatory)] [string]    $Iteration
    )

    $priority = Get-AzDevOpsDailyViewerCreatePriority -Value $Payload.priority

    $points = if ($Spec.HasPoints) {
        Get-AzDevOpsDailyViewerCreatePoints -Value $Payload.storyPoints
    } else {
        -1
    }

    $acceptance = if ($Spec.HasAcceptance) {
        [string]$Payload.acceptanceCriteria
    } else {
        $null
    }

    $parentId = Get-AzDevOpsDailyViewerParentId -Value $Payload.parentId -HasParent ([bool]$Spec.ParentType)

    $result = New-AzDevOpsDailyViewerWorkItem `
        -CreateType         $Type `
        -Title              $Title `
        -Description        ([string]$Payload.description) `
        -Priority           $priority `
        -StoryPoints        $points `
        -AcceptanceCriteria $acceptance `
        -Area               $Area `
        -Iteration          $Iteration `
        -ParentId           $parentId

    return $result
}


function Invoke-AzDevOpsDailyViewerCreateWorkItem {
    # Validate a create payload, auth-gate, then dispatch to one of two symmetric
    # arms — the Feature+Stories batch or a single item. Returns { StatusCode; Body }
    # so the handler just writes it.
    param([Parameter(Mandatory)] [AllowNull()] $Payload)

    if ($null -eq $Payload) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message 'Request body must be JSON.'
        return $failure
    }

    $type = [string]$Payload.type
    $isBatch = ($type -eq $script:AzDevOpsDailyViewerFeatureStoriesType)

    if (-not $isBatch -and -not $script:AzDevOpsDailyViewerCreateTypes.Contains($type)) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message "Unknown work-item type '$type'."
        return $failure
    }

    $area      = [string]$Payload.area
    $iteration = [string]$Payload.iteration
    if (-not $area -or -not $iteration) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message 'Area and iteration are required.'
        return $failure
    }

    $title = ([string]$Payload.title).Trim()
    if (-not $title) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message 'Title is required.'
        return $failure
    }

    if (-not (Test-AzDevOpsCreateGate -CommandName 'daily-viewer create')) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 200 -Message 'Not signed in to Azure DevOps (az login), or $env:AZ_USER_EMAIL is unset. See the server console.'
        return $failure
    }

    if ($isBatch) {
        $batch = New-AzDevOpsDailyViewerFeatureWithStories -Payload $Payload -Area $area -Iteration $iteration
        return @{ StatusCode = 200; Body = $batch }
    }

    $spec = $script:AzDevOpsDailyViewerCreateTypes[$type]
    $single = New-AzDevOpsDailyViewerSingleWorkItem -Payload $Payload -Type $type -Spec $spec -Title $title -Area $area -Iteration $iteration
    return @{ StatusCode = 200; Body = $single }
}


function Invoke-AzDevOpsDailyViewerCreateRequest {
    # Handle an /api/create/<action> request. Read-only actions (`options`) answer
    # a GET; write actions (`ping`, `workitem`) require POST + an application/json
    # body — a JSON content-type forces a CORS preflight this loopback server
    # never answers, so a cross-origin "simple request" forgery can't reach a
    # write. `options` serves the cache-backed picker data; `workitem` runs the
    # non-interactive create core. Sub-issues C–E add their actions to the switch.
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerContext] $Context,
        [Parameter(Mandatory)] [PSCustomObject] $Route
    )

    $request  = $Context.Request
    $response = $Context.Response

    $action         = $Route.Action
    $pingAction     = 'ping'
    $optionsAction  = 'options'
    $workitemAction = 'workitem'

    if (-not (Test-AzDevOpsDailyViewerActionMethod -Request $request -Response $response -Action $action -ReadOnlyAction $optionsAction -WriteLabel 'Create actions')) {
        return
    }

    switch ($action) {
        $optionsAction {
            $options = Get-AzDevOpsDailyViewerCreateOptions
            Write-AzDevOpsDailyViewerJson -Response $response -StatusCode 200 -Object $options
            return
        }

        $pingAction {
            $ack = [ordered]@{
                ok      = $true
                service = 'daily-viewer'
                action  = $pingAction
            }
            Write-AzDevOpsDailyViewerJson -Response $response -StatusCode 200 -Object $ack
            return
        }

        $workitemAction {
            $payload = Read-AzDevOpsDailyViewerRequestJson -Request $request -MaxBytes $script:AzDevOpsDailyViewerMaxCreateBytes
            $outcome = Invoke-AzDevOpsDailyViewerCreateWorkItem -Payload $payload
            Write-AzDevOpsDailyViewerJson -Response $response -StatusCode $outcome.StatusCode -Object $outcome.Body
            return
        }

        default {
            Write-AzDevOpsDailyViewerError -Response $response -StatusCode 404 -Message "Unknown create action '$action'."
            return
        }
    }
}


# ---------------------------------------------------------------------------
# Draft surface — the browser brain-dump builder (Epic #228 sub-issue C)
# Assemble an Epic -> Feature -> User Story -> Task hierarchy locally, then
# publish it once. Every endpoint reuses the non-interactive helpers in
# azdevops_draft.ps1 so the browser and terminal share one draft.json store.
# ---------------------------------------------------------------------------

function Get-AzDevOpsDailyViewerDraftRoute {
    # Parse an /api/draft/<action> path into { Action } or $null. `state` reads the
    # on-disk draft (GET); every mutation (add/set/remove/clear/publish) is POST +
    # JSON only, enforced by the handler. Single-segment actions only.
    param([Parameter(Mandatory)] [string] $Path)

    $route = Get-AzDevOpsDailyViewerActionRoute -Path $Path -Prefix '/api/draft/'
    return $route
}


function Get-AzDevOpsDailyViewerParentRef {
    # Parse a form-supplied draft Ref / work-item id to a positive int, or 0 when
    # absent / blank / non-positive (the draft's "no parent" sentinel).
    param([AllowNull()] $Value)

    if ($null -eq $Value -or [string]$Value -eq '') {
        return 0
    }

    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed) -and $parsed -gt 0) {
        return $parsed
    }
    return 0
}


function Get-AzDevOpsDailyViewerDraftPriority {
    # Parse a form-supplied priority to the ADO 1-4 range, or -1 when absent /
    # blank / out of range. Unlike the create form's coercer this keeps "unset" as
    # -1 (which lowers the drafted item's completeness) rather than defaulting to
    # the midpoint — a drafted item is meant to be filled in later.
    param([AllowNull()] $Value)

    if ($null -eq $Value -or [string]$Value -eq '') {
        return -1
    }

    $parsed = -1
    $inRange =
        [int]::TryParse([string]$Value, [ref]$parsed) -and
        $parsed -ge $script:AzDevOpsDailyViewerMinPriority -and
        $parsed -le $script:AzDevOpsDailyViewerMaxPriority

    if ($inRange) {
        return $parsed
    }
    return -1
}


function New-AzDevOpsDailyViewerDraftNode {
    # Flatten one draft item into the JSON shape the browser tree renders: the raw
    # editable fields plus the completeness score / missing-field labels computed by
    # the same helpers az-Show-AzDevOpsDraft uses, and an isRoot flag (true for a
    # top-level item or one whose ParentRef dangles) so the client groups roots
    # exactly like the terminal tree.
    param(
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)] [hashtable] $RefSet
    )

    $completeness = Get-AzDevOpsDraftCompleteness -Item $Item
    $missing      = Get-AzDevOpsDraftMissingLabels -Item $Item

    $parentRef = [int]$Item.ParentRef
    $isRoot    = ($parentRef -le 0 -or -not $RefSet.ContainsKey($parentRef))

    $node = [ordered]@{
        ref                = [int]$Item.Ref
        type               = [string]$Item.Type
        title              = [string]$Item.Title
        description        = [string]$Item.Description
        priority           = [int]$Item.Priority
        storyPoints        = [int]$Item.StoryPoints
        acceptanceCriteria = [string]$Item.AcceptanceCriteria
        iteration          = [string]$Item.Iteration
        area               = [string]$Item.Area
        parentRef          = $parentRef
        parentId           = [int]$Item.ParentId
        percent            = $completeness.Percent
        filled             = $completeness.Filled
        total              = $completeness.Total
        missing            = @($missing)
        isRoot             = $isRoot
    }
    return $node
}


function Get-AzDevOpsDailyViewerDraftState {
    # Build the full draft snapshot the browser renders: every item as a flat node
    # (the client nests them by parentRef) plus the summary counts az-Show prints.
    # Read-only, cache-only — no `az`. Reuses Read-AzDevOpsDraft so the browser and
    # terminal share one store; an absent cache yields an empty, valid snapshot.
    $draft  = @(Read-AzDevOpsDraft)
    $refSet = Get-AzDevOpsDraftRefSet -Draft $draft

    $nodes      = New-Object System.Collections.Generic.List[object]
    $percentSum = 0
    $readyCount = 0

    foreach ($item in $draft) {
        $node = New-AzDevOpsDailyViewerDraftNode -Item $item -RefSet $refSet
        $nodes.Add($node)

        $percentSum += $node.percent
        if ($node.percent -ge 100) {
            $readyCount++
        }
    }

    $count = $nodes.Count
    $avgPercent = if ($count -gt 0) {
        [int][math]::Round($percentSum / $count)
    } else {
        0
    }

    $state = [ordered]@{
        ok         = $true
        items      = $nodes
        count      = $count
        avgPercent = $avgPercent
        readyCount = $readyCount
    }
    return $state
}


function Test-AzDevOpsDailyViewerDraftParent {
    # Enforce the draft tier rules before an add / re-parent writes: a parent, when
    # one is given, must be the tier the child nests under (Feature under Epic,
    # Story under Feature, Task under Story). The terminal add relies on its
    # interactive picker to filter candidates by tier; the browser passes an
    # explicit ParentRef / ParentId, so the constraint (Test-AzDevOpsDraftType-
    # MatchesTier) is re-checked here. An orphan (no parent) is always allowed.
    # Returns { Ok; Error }.
    param(
        [Parameter(Mandatory)] [string] $ChildType,
        [int] $ParentRef = 0,
        [int] $ParentId = 0,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Draft
    )

    if ($ParentRef -le 0 -and $ParentId -le 0) {
        $ok = [PSCustomObject]@{ Ok = $true; Error = '' }
        return $ok
    }

    $expectedParentType = Get-AzDevOpsDraftParentType -Type $ChildType
    if ($expectedParentType -eq '') {
        $bad = [PSCustomObject]@{ Ok = $false; Error = "A $ChildType sits at the top of the tree and can't have a parent." }
        return $bad
    }

    if ($ParentRef -gt 0) {
        $parent = Get-AzDevOpsDraftItemByRef -Draft $Draft -Ref $ParentRef
        if ($null -eq $parent) {
            $bad = [PSCustomObject]@{ Ok = $false; Error = "No draft item with ref #$ParentRef to nest under." }
            return $bad
        }

        $candidateType = [string]$parent.Type
        if (-not (Test-AzDevOpsDraftTypeMatchesTier -CandidateType $candidateType -ParentType $expectedParentType)) {
            $bad = [PSCustomObject]@{ Ok = $false; Error = "A $ChildType must nest under a $expectedParentType, not a $candidateType." }
            return $bad
        }
    }

    if ($ParentId -gt 0) {
        $hierarchy = @(Read-AzDevOpsHierarchyCache)
        $existing  = $hierarchy | Where-Object { [int]$_.Id -eq $ParentId } | Select-Object -First 1

        if ($null -ne $existing) {
            $candidateType = [string]$existing.Type
            if (-not (Test-AzDevOpsDraftTypeMatchesTier -CandidateType $candidateType -ParentType $expectedParentType)) {
                $bad = [PSCustomObject]@{ Ok = $false; Error = "A $ChildType must nest under a $expectedParentType, not a $candidateType." }
                return $bad
            }
        }
    }

    $ok = [PSCustomObject]@{ Ok = $true; Error = '' }
    return $ok
}


function Invoke-AzDevOpsDailyViewerDraftAdd {
    # Validate an add payload and append one item to the draft via the same
    # az-Add-AzDevOpsDraftItem helper the terminal uses — params supplied, so no
    # prompt runs. Type + title are required; a parent, if given, is tier-checked
    # first. Returns { StatusCode; Body } with the refreshed draft state so the
    # browser re-renders in one round-trip.
    param([Parameter(Mandatory)] [AllowNull()] $Payload)

    if ($null -eq $Payload) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message 'Request body must be JSON.'
        return $failure
    }

    $type = [string]$Payload.type
    if ($type -notin $script:AzDevOpsDailyViewerDraftTypes) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message "Unknown draft item type '$type'."
        return $failure
    }

    $title = ([string]$Payload.title).Trim()
    if (-not $title) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message 'Title is required.'
        return $failure
    }

    $draft     = @(Read-AzDevOpsDraft)
    $parentRef = Get-AzDevOpsDailyViewerParentRef -Value $Payload.parentRef
    $parentId  = Get-AzDevOpsDailyViewerParentRef -Value $Payload.parentId

    $parentCheck = Test-AzDevOpsDailyViewerDraftParent -ChildType $type -ParentRef $parentRef -ParentId $parentId -Draft $draft
    if (-not $parentCheck.Ok) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message $parentCheck.Error
        return $failure
    }

    $addArgs = @{
        Type               = $type
        Title              = $title
        Description        = [string]$Payload.description
        Priority           = Get-AzDevOpsDailyViewerDraftPriority -Value $Payload.priority
        StoryPoints        = Get-AzDevOpsDailyViewerCreatePoints  -Value $Payload.storyPoints
        AcceptanceCriteria = [string]$Payload.acceptanceCriteria
    }

    if ($parentRef -gt 0) {
        $addArgs.ParentRef = $parentRef
    } elseif ($parentId -gt 0) {
        $addArgs.ParentId = $parentId
    } else {
        $addArgs.Orphan = $true
    }

    $ref = az-Add-AzDevOpsDraftItem @addArgs
    if (-not $ref -or [int]$ref -le 0) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 200 -Message 'Could not save the draft — is a project cache available (az-Connect-AzDevOps)? See the server console.'
        return $failure
    }

    $state = Get-AzDevOpsDailyViewerDraftState
    $body  = [ordered]@{ ok = $true; ref = [int]$ref; draft = $state }
    $outcome = @{ StatusCode = 200; Body = $body }
    return $outcome
}


function Invoke-AzDevOpsDailyViewerDraftSet {
    # Edit an existing draft item via az-Set-AzDevOpsDraftItem — only the fields the
    # payload carries are written (the helper's ContainsKey semantics), and -Details
    # is never passed so no reader prompts. A re-parent (orphan / parentRef /
    # parentId) is tier-checked first. Returns { StatusCode; Body } with the
    # refreshed draft state.
    param([Parameter(Mandatory)] [AllowNull()] $Payload)

    if ($null -eq $Payload) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message 'Request body must be JSON.'
        return $failure
    }

    $ref = Get-AzDevOpsDailyViewerParentRef -Value $Payload.ref
    if ($ref -le 0) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message 'A draft item ref is required.'
        return $failure
    }

    $draft = @(Read-AzDevOpsDraft)
    $item  = Get-AzDevOpsDraftItemByRef -Draft $draft -Ref $ref
    if ($null -eq $item) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message "No draft item with ref #$ref."
        return $failure
    }

    $setArgs = @{ Ref = $ref }

    if ($null -ne $Payload.title) {
        $setArgs.Title = ([string]$Payload.title).Trim()
    }
    if ($null -ne $Payload.description) {
        $setArgs.Description = [string]$Payload.description
    }
    if ($null -ne $Payload.priority -and [string]$Payload.priority -ne '') {
        $setArgs.Priority = Get-AzDevOpsDailyViewerDraftPriority -Value $Payload.priority
    }
    if ($null -ne $Payload.storyPoints -and [string]$Payload.storyPoints -ne '') {
        $setArgs.StoryPoints = Get-AzDevOpsDailyViewerCreatePoints -Value $Payload.storyPoints
    }
    if ($null -ne $Payload.acceptanceCriteria) {
        $setArgs.AcceptanceCriteria = [string]$Payload.acceptanceCriteria
    }

    $childType = [string]$item.Type

    if ($Payload.orphan -eq $true) {
        $setArgs.Orphan = $true
    } elseif ($null -ne $Payload.parentRef -and [string]$Payload.parentRef -ne '') {
        $newParentRef = Get-AzDevOpsDailyViewerParentRef -Value $Payload.parentRef

        if ($newParentRef -eq $ref) {
            $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message "A draft item can't be its own parent."
            return $failure
        }

        $parentCheck = Test-AzDevOpsDailyViewerDraftParent -ChildType $childType -ParentRef $newParentRef -Draft $draft
        if (-not $parentCheck.Ok) {
            $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message $parentCheck.Error
            return $failure
        }

        $setArgs.ParentRef = $newParentRef
    } elseif ($null -ne $Payload.parentId -and [string]$Payload.parentId -ne '') {
        $newParentId = Get-AzDevOpsDailyViewerParentRef -Value $Payload.parentId

        $parentCheck = Test-AzDevOpsDailyViewerDraftParent -ChildType $childType -ParentId $newParentId -Draft $draft
        if (-not $parentCheck.Ok) {
            $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message $parentCheck.Error
            return $failure
        }

        $setArgs.ParentId = $newParentId
    }

    az-Set-AzDevOpsDraftItem @setArgs | Out-Null

    $state = Get-AzDevOpsDailyViewerDraftState
    $body  = [ordered]@{ ok = $true; ref = $ref; draft = $state }
    $outcome = @{ StatusCode = 200; Body = $body }
    return $outcome
}


function Invoke-AzDevOpsDailyViewerDraftRemove {
    # Remove one draft item via az-Remove-AzDevOpsDraftItem. By default its children
    # reparent to the grandparent; a truthy `recurse` deletes the whole sub-tree.
    # Returns { StatusCode; Body } with the refreshed draft state.
    param([Parameter(Mandatory)] [AllowNull()] $Payload)

    if ($null -eq $Payload) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message 'Request body must be JSON.'
        return $failure
    }

    $ref = Get-AzDevOpsDailyViewerParentRef -Value $Payload.ref
    if ($ref -le 0) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message 'A draft item ref is required.'
        return $failure
    }

    $draft = @(Read-AzDevOpsDraft)
    $item  = Get-AzDevOpsDraftItemByRef -Draft $draft -Ref $ref
    if ($null -eq $item) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message "No draft item with ref #$ref."
        return $failure
    }

    $recurse = ($Payload.recurse -eq $true)
    if ($recurse) {
        az-Remove-AzDevOpsDraftItem -Ref $ref -Recurse
    } else {
        az-Remove-AzDevOpsDraftItem -Ref $ref
    }

    $state = Get-AzDevOpsDailyViewerDraftState
    $body  = [ordered]@{ ok = $true; draft = $state }
    $outcome = @{ StatusCode = 200; Body = $body }
    return $outcome
}


function Invoke-AzDevOpsDailyViewerDraftClear {
    # Discard the whole draft via az-Clear-AzDevOpsDraft -Force (the -Force skips
    # the terminal's confirm prompt). Returns { StatusCode; Body } with the now-
    # empty draft state.
    az-Clear-AzDevOpsDraft -Force

    $state = Get-AzDevOpsDailyViewerDraftState
    $body  = [ordered]@{ ok = $true; draft = $state }
    $outcome = @{ StatusCode = 200; Body = $body }
    return $outcome
}


function New-AzDevOpsDailyViewerDraftPublishResult {
    # Publish every drafted item to Azure DevOps in one parents-first pass and
    # collect a per-item result the browser renders (created rows carry the new id /
    # url; failed or skipped rows carry the reason). This mirrors az-Publish-
    # AzDevOpsDraft's loop but reuses only its non-interactive building blocks —
    # Sort-AzDevOpsDraftForPublish, Build-AzDevOpsDraftCreateArgs, the create/link
    # core, and Update-AzDevOpsDraftAfterPublish — because the terminal command's
    # picker prompt and console progress bar don't belong in an HTTP handler (the
    # same split New-AzDevOpsDailyViewerWorkItem makes versus az-New-*).
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Draft,
        [Parameter(Mandatory)] [string] $Area,
        [Parameter(Mandatory)] [string] $Iteration,
        [switch] $KeepDraft
    )

    $refSet  = Get-AzDevOpsDraftRefSet -Draft $Draft
    $ordered = Sort-AzDevOpsDraftForPublish -Draft $Draft

    $refToId   = @{}
    $published = New-Object System.Collections.Generic.List[object]
    $failed    = New-Object System.Collections.Generic.List[object]

    foreach ($item in $ordered) {
        $itemRef = [int]$item.Ref

        $resolution = Resolve-AzDevOpsDraftPublishParentId -Item $item -RefSet $refSet -RefToId $refToId
        $parentId   = $resolution.ParentId

        if ($resolution.Unresolved) {
            $failed.Add([ordered]@{
                ref    = $itemRef
                type   = [string]$item.Type
                title  = [string]$item.Title
                reason = 'parent create failed'
            })
            continue
        }

        $createArgs   = Build-AzDevOpsDraftCreateArgs -Item $item -DefaultIteration $Iteration -DefaultArea $Area
        $createResult = Invoke-AzDevOpsWorkItemCreate @createArgs

        if (-not $createResult.Ok) {
            $failed.Add([ordered]@{
                ref    = $itemRef
                type   = [string]$item.Type
                title  = [string]$item.Title
                reason = [string]$createResult.Error
            })
            continue
        }

        $newId = [int]$createResult.Id
        $refToId[$itemRef] = $newId

        $linkedParentId = 0
        $linkError      = ''
        if ($parentId -gt 0) {
            $linkResult = Invoke-AzDevOpsParentLink -Id $newId -ParentId $parentId
            if ($linkResult.Ok) {
                $linkedParentId = $parentId
            } else {
                $linkError = [string]$linkResult.Error
            }
        }

        Add-AzDevOpsHierarchyCacheItem `
            -Id        $newId `
            -Type      ([string]$item.Type) `
            -Title     ([string]$item.Title) `
            -Iteration $createArgs.Iteration `
            -AreaPath  $createArgs.Area `
            -ParentId  $linkedParentId

        $row = [ordered]@{
            ref      = $itemRef
            type     = [string]$item.Type
            title    = [string]$item.Title
            id       = $newId
            url      = [string]$createResult.Url
            linked   = ($linkedParentId -gt 0)
            parentId = $linkedParentId
        }
        if ($linkError) {
            $row.linkError = $linkError
        }

        $published.Add($row)
    }

    Update-AzDevOpsDraftAfterPublish -Draft $Draft -RefToId $refToId -KeepDraft:$KeepDraft

    $result = [ordered]@{
        published = $published
        failed    = $failed
    }
    return $result
}


function Invoke-AzDevOpsDailyViewerDraftPublish {
    # Validate + auth-gate a publish, then create the whole draft. Area / iteration
    # come from the payload (the same picker data create uses), so nothing prompts.
    # Returns { StatusCode; Body } with the per-item results and the refreshed draft
    # state — leftovers after a partial run, empty after a clean one.
    param([Parameter(Mandatory)] [AllowNull()] $Payload)

    if ($null -eq $Payload) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message 'Request body must be JSON.'
        return $failure
    }

    $area      = [string]$Payload.area
    $iteration = [string]$Payload.iteration
    if (-not $area -or -not $iteration) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message 'Area and iteration are required to publish.'
        return $failure
    }

    $draft = @(Read-AzDevOpsDraft)
    if ($draft.Count -eq 0) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message 'Draft is empty — add items before publishing.'
        return $failure
    }

    if (-not (Test-AzDevOpsCreateGate -CommandName 'daily-viewer draft publish')) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 200 -Message 'Not signed in to Azure DevOps (az login), or $env:AZ_USER_EMAIL is unset. See the server console.'
        return $failure
    }

    $keepDraft = ($Payload.keepDraft -eq $true)
    $results = New-AzDevOpsDailyViewerDraftPublishResult -Draft $draft -Area $area -Iteration $iteration -KeepDraft:$keepDraft

    $state = Get-AzDevOpsDailyViewerDraftState

    $publishedCount = $results.published.Count
    $failedCount    = $results.failed.Count

    $body = [ordered]@{
        ok             = ($failedCount -eq 0)
        published      = $results.published
        failed         = $results.failed
        publishedCount = $publishedCount
        failedCount    = $failedCount
        draft          = $state
    }
    $outcome = @{ StatusCode = 200; Body = $body }
    return $outcome
}


function Invoke-AzDevOpsDailyViewerDraftRequest {
    # Handle an /api/draft/<action> request (Epic #228 sub-issue C). `state` is a
    # read-only GET; add / set / remove / clear / publish mutate the local draft and
    # require POST + application/json (a JSON content-type forces a preflight this
    # loopback server never answers, so a cross-origin simple-request forgery can't
    # reach a write). Only publish touches `az`.
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerContext] $Context,
        [Parameter(Mandatory)] [PSCustomObject] $Route
    )

    $request  = $Context.Request
    $response = $Context.Response

    $action        = $Route.Action
    $stateAction   = 'state'
    $addAction     = 'add'
    $setAction     = 'set'
    $removeAction  = 'remove'
    $clearAction   = 'clear'
    $publishAction = 'publish'

    if (-not (Test-AzDevOpsDailyViewerActionMethod -Request $request -Response $response -Action $action -ReadOnlyAction $stateAction -WriteLabel 'Draft actions')) {
        return
    }

    switch ($action) {
        $stateAction {
            $state = Get-AzDevOpsDailyViewerDraftState
            Write-AzDevOpsDailyViewerJson -Response $response -StatusCode 200 -Object $state
            return
        }

        $addAction {
            $payload = Read-AzDevOpsDailyViewerRequestJson -Request $request -MaxBytes $script:AzDevOpsDailyViewerMaxCreateBytes
            $outcome = Invoke-AzDevOpsDailyViewerDraftAdd -Payload $payload
            Write-AzDevOpsDailyViewerJson -Response $response -StatusCode $outcome.StatusCode -Object $outcome.Body
            return
        }

        $setAction {
            $payload = Read-AzDevOpsDailyViewerRequestJson -Request $request -MaxBytes $script:AzDevOpsDailyViewerMaxCreateBytes
            $outcome = Invoke-AzDevOpsDailyViewerDraftSet -Payload $payload
            Write-AzDevOpsDailyViewerJson -Response $response -StatusCode $outcome.StatusCode -Object $outcome.Body
            return
        }

        $removeAction {
            $payload = Read-AzDevOpsDailyViewerRequestJson -Request $request -MaxBytes $script:AzDevOpsDailyViewerMaxCreateBytes
            $outcome = Invoke-AzDevOpsDailyViewerDraftRemove -Payload $payload
            Write-AzDevOpsDailyViewerJson -Response $response -StatusCode $outcome.StatusCode -Object $outcome.Body
            return
        }

        $clearAction {
            $outcome = Invoke-AzDevOpsDailyViewerDraftClear
            Write-AzDevOpsDailyViewerJson -Response $response -StatusCode $outcome.StatusCode -Object $outcome.Body
            return
        }

        $publishAction {
            $payload = Read-AzDevOpsDailyViewerRequestJson -Request $request -MaxBytes $script:AzDevOpsDailyViewerMaxCreateBytes
            $outcome = Invoke-AzDevOpsDailyViewerDraftPublish -Payload $payload
            Write-AzDevOpsDailyViewerJson -Response $response -StatusCode $outcome.StatusCode -Object $outcome.Body
            return
        }

        default {
            Write-AzDevOpsDailyViewerError -Response $response -StatusCode 404 -Message "Unknown draft action '$action'."
            return
        }
    }
}


# ---------------------------------------------------------------------------
# Timer surface — the browser focus-session (Epic #228 sub-issue D, #232). The
# page runs the countdown and collects the debrief; composing and posting the
# comment stay server-side in pow_timer.ps1's helpers, so the terminal
# (az-Start-TimerSession) and the browser share one debrief format and one
# posting path. pow_timer.ps1 is dot-sourced alongside this file, so
# $script:TimerIntegrations and Format-TimerCommentBody are already in scope.
# ---------------------------------------------------------------------------

function Get-AzDevOpsDailyViewerTimerRoute {
    # Parse an /api/timer/<action> path into { Action } or $null. `options` reads the
    # registered integrations + their cached items (GET); `post` composes + posts a
    # debrief (POST + JSON only, enforced by the handler). Single-segment actions.
    param([Parameter(Mandatory)] [string] $Path)

    $route = Get-AzDevOpsDailyViewerActionRoute -Path $Path -Prefix '/api/timer/'
    return $route
}


function Get-AzDevOpsDailyViewerTimerSeconds {
    # Parse a client-reported second count (elapsed / total) to a non-negative int,
    # falling back when it's absent or unparseable so a malformed field can't derail
    # the debrief header math. Capped at a day so a bogus value stays sane.
    param(
        [AllowNull()] $Value,
        [Parameter(Mandatory)] [int] $Fallback
    )

    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed) -and $parsed -ge 0) {
        $capped = [math]::Min($parsed, $script:AzDevOpsDailyViewerTimerMaxSeconds)
        return $capped
    }

    return $Fallback
}


function Get-AzDevOpsDailyViewerTimerOptions {
    # Timer picker data, cache-backed like the create options — never a live az call,
    # since this answers a GET: the registered timer integrations
    # ($script:TimerIntegrations) projected to the fields the browser needs, each
    # with its FetchItems rows (an assigned-cache read, no live az) so the panel can
    # pick an integration + item without a round-trip. `canResolve` mirrors whether
    # the integration supplies a CloseItem, so the debrief only offers "resolve" when
    # the terminal path would. Empty caches / no integrations yield empty lists.
    $integrations = @($script:TimerIntegrations)

    $projected = New-Object System.Collections.Generic.List[object]
    foreach ($integration in $integrations) {
        $rows = @(& $integration.FetchItems)

        $items = New-Object System.Collections.Generic.List[object]
        foreach ($row in $rows) {
            $items.Add([ordered]@{
                id        = $row.Id
                type      = $row.Type
                state     = $row.State
                title     = $row.Title
                priority  = $row.Priority
                iteration = $row.Iteration
            })
        }

        $projected.Add([ordered]@{
            name             = $integration.Name
            description      = $integration.Description
            supportsMentions = [bool]$integration.SupportsMentions
            canResolve       = ($null -ne $integration.CloseItem)
            items            = $items
        })
    }

    $options = [ordered]@{
        integrations   = $projected
        defaultMinutes = $script:TimerDefaultMinutes
    }
    return $options
}


function Get-AzDevOpsDailyViewerTimerIntegration {
    # Resolve a registered timer integration by the name the browser picked from
    # /api/timer/options. Returns $null when the name is empty or unmatched, so the
    # caller turns it into a 400 the panel surfaces.
    param([Parameter(Mandatory)] [AllowNull()] [string] $Name)

    if (-not $Name) {
        return $null
    }

    $match = @($script:TimerIntegrations | Where-Object { $_.Name -eq $Name })
    if ($match.Count -eq 0) {
        return $null
    }

    $integration = $match[0]
    return $integration
}


function Get-AzDevOpsDailyViewerTimerErrorMessage {
    # Pull the .Error text off a timer AddComment / CloseItem envelope
    # ({ Json; Error; ExitCode }), or fall back to a generic exit-coded message when
    # the envelope carries none — the post arm and the resolve arm of
    # Invoke-AzDevOpsDailyViewerTimerPost both need this, so it lives here once.
    param(
        [Parameter(Mandatory)] [AllowNull()] $Result,
        [Parameter(Mandatory)] [string] $Fallback
    )

    if ($Result -and $Result.Error) {
        $message = $Result.Error
        return $message
    }

    return $Fallback
}


function Invoke-AzDevOpsDailyViewerTimerPost {
    # Post a timer-session debrief from the browser, reusing the exact terminal
    # helpers: Format-TimerCommentBody composes the <br/>-joined HTML body, the
    # picked integration's AddComment posts it, and — when the user ticked resolve
    # and the integration supplies a CloseItem — CloseItem transitions the item. The
    # browser owns only the countdown + form; nothing about composing or posting is
    # duplicated client-side. Returns { StatusCode; Body }: 400 for a malformed
    # payload, 200 with ok:$false for an auth / az failure the form surfaces, so
    # nothing 500s silently.
    param([Parameter(Mandatory)] [AllowNull()] $Payload)

    if ($null -eq $Payload) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message 'Request body must be JSON.'
        return $failure
    }

    $integration = Get-AzDevOpsDailyViewerTimerIntegration -Name ([string]$Payload.integration)
    if ($null -eq $integration) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message 'Unknown or missing timer integration.'
        return $failure
    }

    $id = 0
    if (-not [int]::TryParse([string]$Payload.id, [ref]$id) -or $id -le 0) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message 'A work-item id is required.'
        return $failure
    }

    $debrief = [string]$Payload.debrief
    $next    = [string]$Payload.next
    if (-not $debrief.Trim() -and -not $next.Trim()) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message 'Enter a debrief or a next step before posting.'
        return $failure
    }

    $totalSeconds   = Get-AzDevOpsDailyViewerTimerSeconds -Value $Payload.totalSeconds -Fallback ($script:TimerDefaultMinutes * 60)
    $elapsedSeconds = Get-AzDevOpsDailyViewerTimerSeconds -Value $Payload.elapsedSeconds -Fallback $totalSeconds
    $interrupted    = ($Payload.interrupted -eq $true)

    if (-not (Test-AzDevOpsCreateGate -CommandName 'daily-viewer timer')) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 200 -Message 'Not signed in to Azure DevOps (az login), or $env:AZ_USER_EMAIL is unset. See the server console.'
        return $failure
    }

    $body = Format-TimerCommentBody `
        -Interrupted $interrupted `
        -ElapsedSeconds $elapsedSeconds `
        -TotalSeconds $totalSeconds `
        -Debrief $debrief `
        -Next $next `
        -Mentions @()

    $postResult = & $integration.AddComment -Id $id -Body $body
    $postExit   = Get-TimerResultExitCode -Result $postResult

    if ($postExit -ne 0) {
        $postError = Get-AzDevOpsDailyViewerTimerErrorMessage -Result $postResult -Fallback "Comment post failed (exit=$postExit)."

        $failure = New-AzDevOpsDailyViewerCreateError -Code 200 -Message $postError
        return $failure
    }

    $result = [ordered]@{
        ok       = $true
        id       = $id
        posted   = $true
        resolved = $false
    }

    $resolveRequested = ($Payload.resolve -eq $true)
    if ($resolveRequested -and $null -ne $integration.CloseItem) {
        $closeResult = & $integration.CloseItem -Id $id
        $closeExit   = Get-TimerResultExitCode -Result $closeResult

        if ($closeExit -eq 0) {
            $result.resolved = $true
        } else {
            $result.resolveError = Get-AzDevOpsDailyViewerTimerErrorMessage -Result $closeResult -Fallback "Resolve failed (exit=$closeExit). Comment was posted; state unchanged."
        }
    }

    $outcome = @{ StatusCode = 200; Body = $result }
    return $outcome
}


function Invoke-AzDevOpsDailyViewerTimerRequest {
    # Handle an /api/timer/<action> request (Epic #228 sub-issue D). `options` is a
    # read-only GET; `post` composes + posts a debrief and requires POST +
    # application/json (a JSON content-type forces a preflight this loopback server
    # never answers, so a cross-origin simple-request forgery can't reach the post).
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerContext] $Context,
        [Parameter(Mandatory)] [PSCustomObject] $Route
    )

    $request  = $Context.Request
    $response = $Context.Response

    $action        = $Route.Action
    $optionsAction = 'options'
    $postAction    = 'post'

    if (-not (Test-AzDevOpsDailyViewerActionMethod -Request $request -Response $response -Action $action -ReadOnlyAction $optionsAction -WriteLabel 'Timer actions')) {
        return
    }

    switch ($action) {
        $optionsAction {
            $options = Get-AzDevOpsDailyViewerTimerOptions
            Write-AzDevOpsDailyViewerJson -Response $response -StatusCode 200 -Object $options
            return
        }

        $postAction {
            $payload = Read-AzDevOpsDailyViewerRequestJson -Request $request -MaxBytes $script:AzDevOpsDailyViewerMaxCreateBytes
            $outcome = Invoke-AzDevOpsDailyViewerTimerPost -Payload $payload
            Write-AzDevOpsDailyViewerJson -Response $response -StatusCode $outcome.StatusCode -Object $outcome.Body
            return
        }

        default {
            Write-AzDevOpsDailyViewerError -Response $response -StatusCode 404 -Message "Unknown timer action '$action'."
            return
        }
    }
}


# Unplanned-work surface — the browser firefight capture (Epic #228 sub-issue E,
# #233). The page collects the firefight title, the captured interruptions, and
# the debrief; resolving the daily story, creating the Task, composing the item
# log / debrief, and recording the ledger all stay server-side in
# azdevops_unplanned.ps1's helpers, so the terminal (az-Start-UnplannedWork) and
# the browser share one story-resolution, one item format, and one posting path.
# azdevops_unplanned.ps1 is dot-sourced alongside this file, so those helpers are
# already in scope. The WPF stopwatch overlay stays terminal-only (out of scope);
# the browser reports the minutes spent instead of running a live clock.
# ---------------------------------------------------------------------------

function Get-AzDevOpsDailyViewerUnplannedRoute {
    # Parse an /api/unplanned/<action> path into { Action } or $null. `options` reads
    # today's story + parent-Feature candidates (GET); `firefight` files one captured
    # firefight and `rollup` posts the day's roll-up (POST + JSON only, enforced by the
    # handler). Single-segment actions.
    param([Parameter(Mandatory)] [string] $Path)

    $route = Get-AzDevOpsDailyViewerActionRoute -Path $Path -Prefix '/api/unplanned/'
    return $route
}


function Get-AzDevOpsDailyViewerUnplannedOptions {
    # Unplanned-work picker data, cache-backed like the create / timer options — a GET,
    # so never a live az call. Surfaces today's daily-story title and its cached id
    # (Get-UnplannedCachedStoryId, 0 when the story hasn't been created yet) so the
    # panel can show "today's story" without a round-trip, plus the parent-Feature
    # candidates from hierarchy.json — the same data source Read-UnplannedParentFeature
    # picks from — so the browser offers a real Feature (cache-driven pick, not free
    # text) for the day's first firefight. Empty caches yield an empty feature list.
    $cachedStoryId = Get-UnplannedCachedStoryId
    $storyTitle    = Get-UnplannedWorkDailyStoryTitle

    $hierarchy = Read-AzDevOpsHierarchyCache
    $features  = Get-AzDevOpsDailyViewerParentCandidates -Hierarchy $hierarchy -Type $script:AzDevOpsDailyViewerFeatureType

    $options = [ordered]@{
        storyTitle     = $storyTitle
        cachedStoryId  = $cachedStoryId
        features       = @($features)
        defaultMinutes = $script:AzDevOpsDailyViewerUnplannedDefaultMinutes
        area           = $env:AZ_AREA
        iteration      = $env:AZ_ITERATION
    }
    return $options
}


function Get-AzDevOpsDailyViewerUnplannedMinutes {
    # Parse the client-reported firefight minutes to an int in [1, max], falling back to
    # the panel default when it's absent or unparseable so a bogus value can't skew the
    # debrief header or the ledger total.
    param([AllowNull()] $Value)

    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed) -and $parsed -ge 1) {
        $capped = [math]::Min($parsed, $script:AzDevOpsDailyViewerUnplannedMaxMinutes)
        return $capped
    }

    return $script:AzDevOpsDailyViewerUnplannedDefaultMinutes
}


function Get-AzDevOpsDailyViewerUnplannedParentId {
    # Resolve the parent Feature the day's first firefight links its daily story to: a
    # positive id when the panel picked a Feature, else 0 (parentless). Never -1 — the
    # headless path must not fall back to New-UnplannedWorkStory's interactive
    # Read-UnplannedParentFeature pick, which would block this HTTP handler. When the
    # story already exists for today the id is ignored (the cached / existing story is
    # reused without re-parenting).
    param([AllowNull()] $Value)

    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed) -and $parsed -gt 0) {
        return $parsed
    }
    return 0
}


function Get-AzDevOpsDailyViewerUnplannedItems {
    # Normalize the client-captured interruption list into the { Time; Text } records
    # Format-UnplannedItemsDescription expects. Blank-text rows are dropped, the list is
    # capped so a runaway payload can't blow up the Task description, and a missing time
    # falls back to now — the browser stamps HH:mm when the user adds a row, but the
    # server never trusts it to be present.
    param([AllowNull()] $Value)

    $records = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Value) {
        return $records
    }

    $nowStamp = (Get-Date).ToString('HH:mm')

    foreach ($raw in @($Value)) {
        if ($records.Count -ge $script:AzDevOpsDailyViewerUnplannedMaxItems) {
            break
        }

        $text = ([string]$raw.text).Trim()
        if (-not $text) {
            continue
        }

        $time = ([string]$raw.time).Trim()
        if (-not $time) {
            $time = $nowStamp
        }

        $records.Add([PSCustomObject]@{
            Time = $time
            Text = $text
        })
    }

    return $records
}


function Invoke-AzDevOpsDailyViewerUnplannedFirefight {
    # File one browser-captured firefight against today's daily Unplanned Work story,
    # reusing the exact terminal helpers so nothing about resolving the story, creating
    # the Task, composing the item log / debrief, or recording the ledger is duplicated
    # client-side:
    #   Get-UnplannedWorkDailyStory - find-or-create today's story (cached-id reuse via
    #                                 Get-UnplannedCachedStoryId), headless: the chosen
    #                                 parent Feature + env classification are passed so
    #                                 it never prompts.
    #   New-UnplannedWorkTask       - create + link the firefight Task.
    #   Save-UnplannedItemsToTask   - flush the captured items to the Task description
    #                                 (via Format-UnplannedItemsDescription).
    #   Format-UnplannedDebriefComment + Add-AzDevOpsDiscussionComment - post the debrief.
    #   Add-UnplannedLedgerEntry    - record the session in the day's ledger so the
    #                                 roll-up can total it.
    # Returns { StatusCode; Body }: 400 for a malformed payload, 200 with ok:$false for a
    # missing classification / auth / az failure the form surfaces, so nothing 500s.
    param([Parameter(Mandatory)] [AllowNull()] $Payload)

    if ($null -eq $Payload) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message 'Request body must be JSON.'
        return $failure
    }

    $title = ([string]$Payload.title).Trim()
    if (-not $title) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 400 -Message 'A firefight title is required.'
        return $failure
    }
    if ($title.Length -gt $script:AzDevOpsDailyViewerUnplannedMaxTitle) {
        $title = $title.Substring(0, $script:AzDevOpsDailyViewerUnplannedMaxTitle)
    }

    $minutes = Get-AzDevOpsDailyViewerUnplannedMinutes -Value $Payload.minutes
    # Normalize to an array so .Count is safe and correct whether the client sent
    # zero, one, or many interruptions (a returned List unrolls to a scalar / $null
    # on assignment); nothing .Add()s to it after this, so @() is the right tool.
    $items   = @(Get-AzDevOpsDailyViewerUnplannedItems -Value $Payload.items)
    $debrief = [string]$Payload.debrief
    $future  = [string]$Payload.future

    $parentFeatureId = Get-AzDevOpsDailyViewerUnplannedParentId -Value $Payload.parentFeatureId

    if (-not (Test-AzDevOpsCreateGate -CommandName 'daily-viewer unplanned')) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 200 -Message 'Not signed in to Azure DevOps (az login), or $env:AZ_USER_EMAIL is unset. See the server console.'
        return $failure
    }

    $area      = $env:AZ_AREA
    $iteration = $env:AZ_ITERATION
    if (-not $area -or -not $iteration) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 200 -Message 'Set $env:AZ_AREA and $env:AZ_ITERATION (run az-Connect-AzDevOps) before capturing unplanned work from the browser.'
        return $failure
    }

    $storyId = Get-UnplannedWorkDailyStory -ParentFeatureId $parentFeatureId -Area $area -Iteration $iteration
    if ($storyId -le 0) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 200 -Message 'Could not resolve or create today''s Unplanned Work story. See the server console.'
        return $failure
    }

    $taskId = New-UnplannedWorkTask -Title $title -StoryId $storyId
    if ($taskId -le 0) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 200 -Message 'Could not create the firefight Task. See the server console.'
        return $failure
    }

    Save-UnplannedItemsToTask -TaskId $taskId -Title $title -Items $items

    $commentBody = Format-UnplannedDebriefComment `
        -ElapsedMinutes $minutes `
        -ItemCount      $items.Count `
        -Debrief        $debrief `
        -FutureFeature  $future `
        -Mentions       @()

    $postResult = Add-AzDevOpsDiscussionComment -Id $taskId -Body $commentBody
    $postExit   = Get-TimerResultExitCode -Result $postResult

    Add-UnplannedLedgerEntry -StoryId $storyId -TaskId $taskId -Title $title -Minutes $minutes -ItemCount $items.Count

    $result = [ordered]@{
        ok        = $true
        storyId   = $storyId
        taskId    = $taskId
        title     = $title
        minutes   = $minutes
        itemCount = $items.Count
        posted    = ($postExit -eq 0)
    }

    if ($postExit -ne 0) {
        $result.postError = Get-AzDevOpsDailyViewerTimerErrorMessage -Result $postResult -Fallback "Debrief comment failed (exit=$postExit). The Task and its item log were saved."
    }

    $outcome = @{ StatusCode = 200; Body = $result }
    return $outcome
}


function Invoke-AzDevOpsDailyViewerUnplannedRollup {
    # Post the end-of-day roll-up on today's daily Unplanned Work story, reusing the
    # terminal New-UnplannedWorkDebrief's exact pieces: read the day's ledger
    # (Get-UnplannedLedgerPath), total the minutes across firefights, and compose the
    # comment with Format-UnplannedDailyDebrief before posting via
    # Add-AzDevOpsDiscussionComment. No mentions from the browser — the terminal's tag
    # picker is interactive. Returns { StatusCode; Body }: 200 with ok:$false when the
    # ledger is empty or a post fails, so the panel surfaces it.
    param([Parameter(Mandatory)] [AllowNull()] $Payload)

    if (-not (Test-AzDevOpsCreateGate -CommandName 'daily-viewer unplanned rollup')) {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 200 -Message 'Not signed in to Azure DevOps (az login), or $env:AZ_USER_EMAIL is unset. See the server console.'
        return $failure
    }

    $ledger = Read-UnplannedLedgerTotals
    if ($ledger.Reason -eq 'missing') {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 200 -Message 'No unplanned-work ledger for today yet - file a firefight first.'
        return $failure
    }
    if ($ledger.Reason -eq 'empty') {
        $failure = New-AzDevOpsDailyViewerCreateError -Code 200 -Message 'Today''s unplanned-work ledger is empty - file a firefight first.'
        return $failure
    }

    $entries      = $ledger.Entries
    $totalMinutes = $ledger.TotalMinutes
    $storyId      = $ledger.StoryId

    $body       = Format-UnplannedDailyDebrief -Entries $entries -TotalMinutes $totalMinutes -Mentions @()
    $postResult = Add-AzDevOpsDiscussionComment -Id $storyId -Body $body
    $postExit   = Get-TimerResultExitCode -Result $postResult

    if ($postExit -ne 0) {
        $postError = Get-AzDevOpsDailyViewerTimerErrorMessage -Result $postResult -Fallback "Roll-up comment failed (exit=$postExit)."
        $failure   = New-AzDevOpsDailyViewerCreateError -Code 200 -Message $postError
        return $failure
    }

    $result = [ordered]@{
        ok           = $true
        storyId      = $storyId
        count        = $entries.Count
        totalMinutes = $totalMinutes
    }

    $outcome = @{ StatusCode = 200; Body = $result }
    return $outcome
}


function Invoke-AzDevOpsDailyViewerUnplannedRequest {
    # Handle an /api/unplanned/<action> request (Epic #228 sub-issue E). `options` is a
    # read-only GET; `firefight` files one captured firefight and `rollup` posts the
    # day's roll-up — both require POST + application/json (a JSON content-type forces a
    # preflight this loopback server never answers, so a cross-origin simple-request
    # forgery can't reach the writes).
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerContext] $Context,
        [Parameter(Mandatory)] [PSCustomObject] $Route
    )

    $request  = $Context.Request
    $response = $Context.Response

    $action          = $Route.Action
    $optionsAction   = 'options'
    $firefightAction = 'firefight'
    $rollupAction    = 'rollup'

    if (-not (Test-AzDevOpsDailyViewerActionMethod -Request $request -Response $response -Action $action -ReadOnlyAction $optionsAction -WriteLabel 'Unplanned-work actions')) {
        return
    }

    switch ($action) {
        $optionsAction {
            $options = Get-AzDevOpsDailyViewerUnplannedOptions
            Write-AzDevOpsDailyViewerJson -Response $response -StatusCode 200 -Object $options
            return
        }

        $firefightAction {
            $payload = Read-AzDevOpsDailyViewerRequestJson -Request $request -MaxBytes $script:AzDevOpsDailyViewerMaxCreateBytes
            $outcome = Invoke-AzDevOpsDailyViewerUnplannedFirefight -Payload $payload
            Write-AzDevOpsDailyViewerJson -Response $response -StatusCode $outcome.StatusCode -Object $outcome.Body
            return
        }

        $rollupAction {
            $payload = Read-AzDevOpsDailyViewerRequestJson -Request $request -MaxBytes $script:AzDevOpsDailyViewerMaxCreateBytes
            $outcome = Invoke-AzDevOpsDailyViewerUnplannedRollup -Payload $payload
            Write-AzDevOpsDailyViewerJson -Response $response -StatusCode $outcome.StatusCode -Object $outcome.Body
            return
        }

        default {
            Write-AzDevOpsDailyViewerError -Response $response -StatusCode 404 -Message "Unknown unplanned-work action '$action'."
            return
        }
    }
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

    if ($Route.IsPrepMarker) {
        if ($method -ne 'POST') {
            Write-AzDevOpsDailyViewerError -Response $response -StatusCode 405 -Message 'Prep marker requires POST.'
            return
        }

        $payload = Read-AzDevOpsDailyViewerRequestJson -Request $request

        $id     = [string]$payload.id
        $marker = [string]$payload.marker

        $isKnownMarker = ($marker -eq $script:AzDevOpsDailyViewerMarkerSet -or $marker -eq $script:AzDevOpsDailyViewerMarkerNeeded)

        if (-not $id -or -not $isKnownMarker) {
            Write-AzDevOpsDailyViewerError -Response $response -StatusCode 400 -Message 'Prep marker needs an id and a marker of "set" or "needed".'
            return
        }

        $stored = Set-AzDevOpsDailyViewerPrepMarker -Id $id -Marker $marker

        $ack = [ordered]@{ id = $id; marker = $stored }
        Write-AzDevOpsDailyViewerJson -Response $response -StatusCode 200 -Object $ack
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
    # Front door: /api/tiles/* goes to the tile handler (cheap GET / expensive
    # POST), /api/create/* + /api/draft/* + /api/timer/* + /api/unplanned/* to the
    # creation-mode handlers, everything else is treated as a static-asset GET. Any
    # handler failure is turned into a 500 so one bad request can never kill the loop.
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerContext] $Context,
        [Parameter(Mandatory)] [string] $StaticRoot
    )

    $response = $Context.Response

    try {
        $path = $Context.Request.Url.AbsolutePath

        $tileRoute = Get-AzDevOpsDailyViewerTileRoute -Path $path
        if ($null -ne $tileRoute) {
            Invoke-AzDevOpsDailyViewerApiRequest -Context $Context -Route $tileRoute
            return
        }

        $createRoute = Get-AzDevOpsDailyViewerCreateRoute -Path $path
        if ($null -ne $createRoute) {
            Invoke-AzDevOpsDailyViewerCreateRequest -Context $Context -Route $createRoute
            return
        }

        $draftRoute = Get-AzDevOpsDailyViewerDraftRoute -Path $path
        if ($null -ne $draftRoute) {
            Invoke-AzDevOpsDailyViewerDraftRequest -Context $Context -Route $draftRoute
            return
        }

        $timerRoute = Get-AzDevOpsDailyViewerTimerRoute -Path $path
        if ($null -ne $timerRoute) {
            Invoke-AzDevOpsDailyViewerTimerRequest -Context $Context -Route $timerRoute
            return
        }

        $unplannedRoute = Get-AzDevOpsDailyViewerUnplannedRoute -Path $path
        if ($null -ne $unplannedRoute) {
            Invoke-AzDevOpsDailyViewerUnplannedRequest -Context $Context -Route $unplannedRoute
            return
        }

        Invoke-AzDevOpsDailyViewerStaticRequest -Context $Context -StaticRoot $StaticRoot
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
