# ============================================================================
# Azure DevOps — Cached-data views
# ============================================================================
# Read-only commands that surface the cached work-item JSON: assigned/mentions
# (pickable Out-ConsoleGridView grids via az-Get-*), tree/board/features/orphans
# (human-readable views via az-Show-*). All grid + cache-consumer scaffolding
# (Show-AzDevOpsRows, Read-AzDevOpsJsonCache, formatters, URL builders) lives
# here and is shared across the views.
#
# Loaded by powcuts_home.ps1. See azdevops_auth.ps1 for the master docstring.

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
    $available = Test-ConsoleGridAvailable
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
#   az-Open-Assigned  - open a single assigned item in the browser
#   az-Get-AzDevOpsMentions   - table of work items where I've been @-mentioned
#   az-Open-Mention   - open a single mentioned item in the browser
#
# All four read $HOME/.bashcuts-az-devops-app/cache/{assigned,mentions}.json
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

    $id = if ($f.'System.Id') {
        [int]$f.'System.Id'
    } else {
        [int]$Raw.id
    }

    $assignedAt = if ($f.'System.ChangedDate') {
        [datetime]$f.'System.ChangedDate'
    } else {
        $null
    }

    $priority = if ($null -ne $f.'Microsoft.VSTS.Common.Priority') {
        [int]$f.'Microsoft.VSTS.Common.Priority'
    } else {
        $null
    }

    return [PSCustomObject]@{
        Id         = $id
        Type       = $f.'System.WorkItemType'
        State      = $f.'System.State'
        Title      = $f.'System.Title'
        Iteration  = $f.'System.IterationPath'
        Priority   = $priority
        AssignedAt = $assignedAt
    }
}


# In-session parse memo for cache files, keyed by absolute path + the file's
# last-write-time. Repeated reads of an unchanged file in one session skip the
# Get-Content + ConvertFrom-Json + per-row conversion (the cost felt when, say,
# creating several stories back-to-back re-parses hierarchy.json each time).
# Keying on mtime means the detached background sync - which rewrites cache
# files from a SEPARATE process - auto-invalidates the memo with no explicit
# clear, and keying on the (per-project) path means switching projects can't
# serve another project's rows. Failed parses are not memoized.
$script:AzDevOpsParseMemo = @{}


function Get-AzDevOpsMemoizedParse {
    # Private. Returns the memoized parse of $Path while the file is unchanged
    # since the last read (by LastWriteTimeUtc); otherwise runs $Parse, stores a
    # non-null result keyed by path + mtime, and returns it. $Parse takes no args
    # and must read $Path itself and return the finished object/array. Callers
    # must confirm $Path exists before calling.
    param(
        [Parameter(Mandatory)] [string]      $Path,
        [Parameter(Mandatory)] [scriptblock] $Parse
    )

    $mtime = (Get-Item -LiteralPath $Path).LastWriteTimeUtc

    $entry = $script:AzDevOpsParseMemo[$Path]
    if ($null -ne $entry -and $entry.Mtime -eq $mtime) {
        $cached = $entry.Value
        return $cached
    }

    $value = & $Parse

    if ($null -ne $value) {
        $script:AzDevOpsParseMemo[$Path] = @{ Mtime = $mtime; Value = $value }
    }

    return $value
}


function Read-AzDevOpsJsonCache {
    # Shared shape for every cache reader: missing-cache hint, ConvertFrom-Json
    # with try/catch, then map each row through a per-dataset converter. Each
    # caller supplies its own $Path, a short $Description for the hint line,
    # and a scriptblock that turns one parsed row into a typed PSCustomObject.
    # The parse is memoized per path+mtime so repeat reads in a session are free.
    param(
        [Parameter(Mandatory)] [string]      $Path,
        [Parameter(Mandatory)] [string]      $Description,
        [Parameter(Mandatory)] [scriptblock] $Converter
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "No $Description cache at $Path." -ForegroundColor Yellow
        Write-Host "  Run: az-Sync-AzDevOpsCache   # one-shot refresh (also runs silently on shell open when stale)" -ForegroundColor Yellow
        return $null
    }

    $items = Get-AzDevOpsMemoizedParse -Path $Path -Parse {
        try {
            $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        }
        catch {
            Write-Host "Could not parse ${Path}: $_" -ForegroundColor Red
            return $null
        }

        # When the cached JSON is an empty array [], ConvertFrom-Json's
        # array output unwraps through the pipeline to zero items and $raw
        # lands as $null. Without this guard, $null | ForEach-Object would
        # still invoke the converter once with $_ = $null and trip the
        # converter's [Parameter(Mandatory)] guard with a confusing
        # "Cannot bind argument to parameter 'Raw' because it is null"
        # error - surface a clean empty cache instead.
        if ($null -eq $raw) {
            return @()
        }

        $parsed = @($raw | ForEach-Object { & $Converter $_ })
        return $parsed
    }.GetNewClosure()

    # The cache file exists (missing returned $null above), so a $null here
    # means a present-but-empty cache: the parse closure's empty array
    # collapses to $null crossing the & invocation boundary in
    # Get-AzDevOpsMemoizedParse. Normalize to @() so callers can distinguish
    # "no cache yet" ($null) from "cache synced but zero rows" (@()) - the
    # latter drives the empty-state hints in the tree/find views and the
    # parent picker.
    if ($null -eq $items) {
        return @()
    }

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
#   - newest-first sort with $null dates pushed to the bottom
#                                  - Sort-AzDevOpsByDateDesc
#
# az-Open-WorkItemById (public: open any item by raw ID, no cache check) is the
# shared open primitive the Open-Assigned/Open-Mention pairs delegate to.
# ---------------------------------------------------------------------------

function Get-AzDevOpsClosedStates {
    return @('Closed', 'Removed', 'Resolved', 'Done', 'Completed')
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
    }
    else {
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
    @{ Expression = $Field; Descending = $true }

    return @($sorted)
}


function Format-AzDevOpsTruncatedTitle {
    param([string] $Title)

    $titleMaxLen = 80
    $ellipsis = '...'

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


function Get-AzDevOpsUrlBase {
    # "$org/$projectEnc" from the configured az devops defaults, or '' when org
    # or project is unset. Shared base for every project-scoped URL builder
    # (work-item edit prefix, Boards hub) so the org-trim + project-encode lives
    # in one place. Stays quiet (no $LASTEXITCODE / Write-Host) so per-row
    # callers can branch on '' without side effects.
    $defaults = Get-AzDevOpsConfiguredDefaults
    if (-not $defaults.Org -or -not $defaults.Project) {
        return ''
    }

    $org        = $defaults.Org.TrimEnd('/')
    $projectEnc = [uri]::EscapeDataString($defaults.Project)
    $base       = "$org/$projectEnc"
    return $base
}


function Get-AzDevOpsWorkItemUrlPrefix {
    # Quiet URL-prefix builder. Returns "$org/$projectEnc/_workitems/edit/" when
    # az devops defaults are configured; returns '' when either is missing.
    # Designed for callers that build URLs for many ids in a loop (e.g.
    # Out-ConsoleGridView row projections in Get-AzDevOpsTreeRows) so the prefix
    # is computed once instead of per row, and so per-row use does not pollute
    # $LASTEXITCODE.
    $base = Get-AzDevOpsUrlBase
    if (-not $base) {
        return ''
    }

    $prefix = "$base/_workitems/edit/"
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


function Get-AzDevOpsBoardsUrl {
    # Best-effort link to the project's Boards hub. Used by empty-state hints
    # and the classification (Areas / Iterations) open-in-browser action, whose
    # rows carry no work-item id. Returns '' when az devops defaults are unset.
    $base = Get-AzDevOpsUrlBase
    if (-not $base) {
        return ''
    }

    $url = "$base/_boards/board"
    return $url
}


function az-Open-WorkItemById {
    # Open any work item in the browser by raw ID - no assigned/mentions cache
    # membership check. Sets $LASTEXITCODE = 1 and returns when the az devops
    # defaults are missing; otherwise launches the OS browser.
    param([Parameter(Mandatory, Position = 0)] [int] $Id)

    $url = Get-AzDevOpsWorkItemUrl -Id $Id
    if ($null -eq $url) {
        Write-Host "az devops defaults not configured. Run: az devops configure --defaults organization=<url> project=<name>" -ForegroundColor Red
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
        -Converter { param($r) ConvertFrom-AzDevOpsAssignedItem -Raw $r }
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
    $sorted = Sort-AzDevOpsByDateDesc -Items $filtered -Field 'AssignedAt'

    $rows = @($sorted | Select-Object Id, Type, State, (Get-AzDevOpsTitleColumn), Iteration, AssignedAt)
    $title = "Assigned to me - $($rows.Count) items"

    $selected = Show-AzDevOpsRows -Rows $rows -Title $title -PassThru
    return $selected
}


function az-Open-Assigned {
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

    az-Open-WorkItemById -Id $Id
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
    }
    else {
        [int]$Raw.id
    }

    $mentionedAt = if ($f.'System.ChangedDate') {
        [datetime]$f.'System.ChangedDate'
    }
    else {
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
        -Converter { param($r) ConvertFrom-AzDevOpsMentionItem -Raw $r }
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
        }
        else {
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

    $rows = @($sorted | Select-Object Id, Type, State, (Get-AzDevOpsTitleColumn), MentionedBy, MentionedAt)
    $title = "Mentions - $($rows.Count) items"

    $selected = Show-AzDevOpsRows -Rows $rows -Title $title -PassThru
    return $selected
}


function az-Open-Mention {
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

    az-Open-WorkItemById -Id $Id
}


# ---------------------------------------------------------------------------
# Recent-activity view (posted-or-tagged union)
#
# Public function:
#   az-Show-RecentActivity - one selectable grid of the non-closed work items
#                            the user has touched lately: items they posted on
#                            (activity cache: System.ChangedBy = @Me) unioned
#                            with items they were @-tagged in (mentions cache:
#                            System.History contains their email). Rows are
#                            deduped by Id and tagged with a Reason column -
#                            'Posted', 'Tagged', or 'Both' - then sorted newest
#                            first by ChangedDate. Selection flows through the
#                            shared Invoke-AzDevOpsRowAction (open / create
#                            child) like the other az-Show-* views.
#
# Reads activity.json + mentions.json from cache only (no `az` calls). Both are
# rebuilt together by az-Sync-AzDevOpsCache, so in practice they exist or are
# absent as a pair; each reader prints its own missing-cache hint, and the view
# bails only when neither cache is present.
# ---------------------------------------------------------------------------

function ConvertFrom-AzDevOpsActivityItem {
    param([Parameter(Mandatory)] $Raw)

    $f = $Raw.fields

    $id = if ($f.'System.Id') {
        [int]$f.'System.Id'
    }
    else {
        [int]$Raw.id
    }

    $changedAt = if ($f.'System.ChangedDate') {
        [datetime]$f.'System.ChangedDate'
    }
    else {
        $null
    }

    return [PSCustomObject]@{
        Id          = $id
        Type        = $f.'System.WorkItemType'
        State       = $f.'System.State'
        Title       = $f.'System.Title'
        ChangedDate = $changedAt
    }
}


function Read-AzDevOpsActivityCache {
    $paths = Get-AzDevOpsCachePaths
    $items = Read-AzDevOpsJsonCache `
        -Path        $paths.Activity `
        -Description 'activity' `
        -Converter { param($r) ConvertFrom-AzDevOpsActivityItem -Raw $r }
    return $items
}


function Merge-AzDevOpsActivityRows {
    # Unions the activity ("I posted/touched it") and mentions ("I was tagged")
    # cache rows into one row per work-item Id, tagging each with why it
    # surfaced: 'Posted' (activity only), 'Tagged' (mentions only), or 'Both'.
    # Mentions rows carry their System.ChangedDate in MentionedAt; both sources
    # feed a single ChangedDate field so the caller sorts newest-first on one
    # key. $null rows (an absent cache reads back as $null) are skipped.
    #
    # Keyed by the integer work-item Id in a plain hashtable (key-based [object]
    # indexer) rather than [ordered] (whose [int] indexer is positional, not
    # key lookup); the caller re-sorts by ChangedDate, so insertion order is
    # irrelevant here.
    param(
        $Activity,
        $Mentions
    )

    $reasonPosted = 'Posted'
    $reasonTagged = 'Tagged'
    $reasonBoth   = 'Both'

    $byId = @{}

    foreach ($item in @($Activity | Where-Object { $null -ne $_ })) {
        $byId[$item.Id] = [PSCustomObject]@{
            Id          = $item.Id
            Type        = $item.Type
            State       = $item.State
            Title       = $item.Title
            Reason      = $reasonPosted
            ChangedDate = $item.ChangedDate
        }
    }

    foreach ($item in @($Mentions | Where-Object { $null -ne $_ })) {
        $existing = $byId[$item.Id]

        if ($null -ne $existing) {
            $existing.Reason = $reasonBoth
            continue
        }

        $byId[$item.Id] = [PSCustomObject]@{
            Id          = $item.Id
            Type        = $item.Type
            State       = $item.State
            Title       = $item.Title
            Reason      = $reasonTagged
            ChangedDate = $item.MentionedAt
        }
    }

    $merged = @($byId.Values)
    return $merged
}


function az-Show-RecentActivity {
    [CmdletBinding()]
    param(
        [string[]] $State
    )

    $activity = Read-AzDevOpsActivityCache
    $mentions = Read-AzDevOpsMentionsCache

    if ($null -eq $activity -and $null -eq $mentions) {
        return
    }

    Write-AzDevOpsStaleBanner

    $merged = Merge-AzDevOpsActivityRows -Activity $activity -Mentions $mentions

    $filtered = @(Select-AzDevOpsActiveItems -Items $merged -State $State)
    if ($filtered.Count -eq 0) {
        Write-Host "(no open posted-or-tagged activity in cache)" -ForegroundColor Yellow
        return
    }

    $sorted = Sort-AzDevOpsByDateDesc -Items $filtered -Field 'ChangedDate'

    $rows = @($sorted | Select-Object Id, Type, State, Reason, (Get-AzDevOpsTitleColumn), ChangedDate)

    $title = "Recent activity - $($rows.Count) items"

    $selected = Show-AzDevOpsRows -Rows $rows -Title $title -PassThru
    Invoke-AzDevOpsRowAction -Selected $selected
}


# ---------------------------------------------------------------------------
# Hierarchy tree view
#
# Public functions:
#   az-Show-Tree   - prints the project's Epic/Feature/requirement-tier
#                          tree from the cached hierarchy.json (no `az` calls)
#   az-Show-Board  - cached items grouped by State (board-style view);
#                          relies on Out-ConsoleGridView's column group-by.
#                          Defined further down in its own section.
#
# Reads $HOME/.bashcuts-az-devops-app/cache/hierarchy.json (built by
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
    }
    else {
        $null
    }

    $id = if ($f.'System.Id') {
        [int]$f.'System.Id'
    }
    else {
        [int]$Raw.id
    }

    $item = [PSCustomObject]@{
        Id        = $id
        Type      = $f.'System.WorkItemType'
        State     = $f.'System.State'
        Title     = $f.'System.Title'
        Iteration = $f.'System.IterationPath'
        AreaPath  = $f.'System.AreaPath'
        Parent    = $parent
    }
    return $item
}


function Read-AzDevOpsHierarchyCache {
    $paths = Get-AzDevOpsCachePaths
    $items = Read-AzDevOpsJsonCache `
        -Path        $paths.Hierarchy `
        -Description 'hierarchy' `
        -Converter { param($r) ConvertFrom-AzDevOpsHierarchyItem -Raw $r }
    return $items
}


function Read-AzDevOpsHierarchyCacheForProject {
    # Per-project variant - reads the hierarchy cache for the named project
    # without flipping active state. -Quiet swallows the missing-cache hint
    # so the multi-project features view can skip un-synced projects silently
    # and surface its own consolidated banner instead.
    param(
        [Parameter(Mandatory)] [string] $ProjectName,
        [switch] $Quiet
    )

    $slug = ConvertTo-AzDevOpsProjectSlug -Name $ProjectName
    if (-not $slug) {
        return $null
    }

    $paths = Get-AzDevOpsCachePathsForSlug -Slug $slug

    if ($Quiet -and -not (Test-Path -LiteralPath $paths.Hierarchy)) {
        return $null
    }

    $items = Read-AzDevOpsJsonCache `
        -Path        $paths.Hierarchy `
        -Description "hierarchy ($ProjectName)" `
        -Converter   { param($r) ConvertFrom-AzDevOpsHierarchyItem -Raw $r }
    return $items
}


function Get-AzDevOpsTreeIndent {
    param([Parameter(Mandatory)] [int] $Depth)

    $indentUnit = '    '   # 4 spaces per tree level
    $indent = $indentUnit * $Depth
    return $indent
}


function Get-AzDevOpsTreeIcon {
    param([Parameter(Mandatory)] [string] $Type)

    $iconEpic = "$([char]0x1F4E6)"   # package
    $iconFeature = "$([char]0x1F3AF)"   # bullseye
    $iconStory = "$([char]0x1F4DD)"   # memo
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

    $indent = Get-AzDevOpsTreeIndent -Depth $Depth
    $icon = Get-AzDevOpsTreeIcon -Type $Item.Type
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

    $rows = New-Object System.Collections.Generic.List[PSCustomObject]
    $epics = @($Items | Where-Object { $_.Type -eq 'Epic' } | Sort-Object Id)

    # Build the URL prefix once instead of resolving env vars + escaping the
    # project name per row. Empty string when env vars are unset - callers see
    # an empty Url column instead of a per-row $LASTEXITCODE flip.
    $urlPrefix = Get-AzDevOpsWorkItemUrlPrefix

    foreach ($epic in $epics) {
        $epicPath = "Epic $($epic.Id) / $($epic.Title)"
        $epicUrl = if ($urlPrefix) {
            "$urlPrefix$($epic.Id)"
        }
        else {
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
            $featureUrl = if ($urlPrefix) {
                "$urlPrefix$($feature.Id)"
            }
            else {
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
                $storyUrl = if ($urlPrefix) {
                    "$urlPrefix$($story.Id)"
                }
                else {
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

    $result = , @($rows)
    return $result
}


# ---------------------------------------------------------------------------
# Post-selection actions
#
# Every interactive az-Show-* work-item view (Tree / Board / Features) pipes
# its grid selection through Invoke-AzDevOpsRowAction. For each selected row
# the user is prompted to open it in the browser or create the
# hierarchically-appropriate child (Epic -> Feature -> requirement-tier ->
# Task), with the selected row pre-filled as the new item's parent.
# ---------------------------------------------------------------------------

function Get-AzDevOpsChildTypeFor {
    # Maps a selected parent row's work-item type to the child type its
    # "create child" action produces, following the Epic -> Feature ->
    # requirement-tier -> Task hierarchy. Returns $null for types with no
    # defined child (Tasks, classification nodes, unknown types) so the caller
    # offers open-only.
    param([Parameter(Mandatory)] [string] $Type)

    $childOfEpic    = 'Feature'
    $childOfFeature = 'User Story'
    $childOfStory   = 'Task'

    if ($Type -eq 'Epic') {
        return $childOfEpic
    }

    if ($Type -eq 'Feature') {
        return $childOfFeature
    }

    if ($Type -in $script:AzDevOpsRequirementTypes) {
        return $childOfStory
    }

    return $null
}


function New-AzDevOpsChildForRow {
    # Dispatches the "create child" action to the matching az-New-* creator
    # with the parent pre-filled so the creator skips its own parent picker.
    param(
        [Parameter(Mandatory)] [string] $ParentType,
        [Parameter(Mandatory)] [int]    $ParentId
    )

    if ($ParentType -eq 'Epic') {
        $newId = az-New-AzDevOpsFeature -ParentEpicId $ParentId
        return $newId
    }

    if ($ParentType -eq 'Feature') {
        $newId = az-New-AzDevOpsUserStory -FeatureId $ParentId
        return $newId
    }

    if ($ParentType -in $script:AzDevOpsRequirementTypes) {
        $newId = az-New-Task -ParentStoryId $ParentId
        return $newId
    }

    Write-Host "No child work-item type defined for '$ParentType'." -ForegroundColor Yellow
    return $null
}


function Resolve-AzDevOpsRowType {
    # Pulls the work-item type off a selected row, falling back to -DefaultType
    # for views whose rows omit a Type column (az-Show-Features rows are all
    # Features, so the view passes -DefaultType 'Feature').
    param(
        [Parameter(Mandatory)] $Row,
        [string] $DefaultType
    )

    if ($Row.PSObject.Properties.Match('Type').Count -gt 0 -and $Row.Type) {
        return [string]$Row.Type
    }

    return $DefaultType
}


function Read-AzDevOpsRowActionChoice {
    # Single-row post-selection prompt. Offers open-in-browser, create-child
    # (only when $ChildType is set), or skip. Returns 'open' / 'create' / 'skip'.
    param(
        [Parameter(Mandatory)] [string] $Label,
        [string] $ChildType
    )

    Write-Host ""
    Write-Host "Selected: $Label" -ForegroundColor Cyan

    $prompt = if ($ChildType) {
        "  [O]pen in browser / [C]reate child $ChildType / [Enter]=skip"
    } else {
        "  [O]pen in browser / [Enter]=skip"
    }

    $resp = Read-Host $prompt

    if ($resp -match '^(o|open)$') {
        return 'open'
    }

    if ($ChildType -and $resp -match '^(c|create)$') {
        return 'create'
    }

    return 'skip'
}


function Get-AzDevOpsRowId {
    # Returns the positive work-item id from a selected grid row, or 0 when the
    # row carries no usable Id column (classification nodes, header rows). Shared
    # by the bulk-open gate and the per-row dispatcher so the presence check
    # lives in one place.
    param([Parameter(Mandatory)] $Row)

    $hasId = $Row.PSObject.Properties.Match('Id').Count -gt 0 -and [int]$Row.Id -gt 0
    if (-not $hasId) {
        return 0
    }

    $id = [int]$Row.Id
    return $id
}


function Invoke-AzDevOpsOpenAllSelected {
    # Bulk-open gate for multi-row grid selections. Asks once whether to open
    # every selected row in the browser; on yes, opens each row that carries a
    # usable work-item id and returns $true. On no - a bare Enter is the safe
    # default via Read-AzDevOpsYesNo -DefaultNo - returns $false so the caller
    # drops to the per-row open/create prompt loop.
    param([Parameter(Mandatory)] $Rows)

    $rows  = @($Rows)
    $count = $rows.Count

    Write-Host ""
    $prompt  = "Open all $count selected items in the browser?"
    $openAll = Read-AzDevOpsYesNo -Prompt $prompt -DefaultNo

    if (-not $openAll) {
        return $false
    }

    foreach ($row in $rows) {
        $id = Get-AzDevOpsRowId -Row $row
        if ($id -le 0) {
            Write-Host "(selected row has no work-item id - nothing to open)" -ForegroundColor Yellow
            continue
        }

        az-Open-WorkItemById -Id $id
    }

    return $true
}


function Invoke-AzDevOpsRowAction {
    # Post-selection dispatcher shared by the interactive az-Show-* work-item
    # views. When more than one row is selected, first offers a single bulk-open
    # gate; declining (or a single-row selection) falls through to the per-row
    # loop, which prompts to open each row in the browser or create its
    # hierarchical child. Rows without a usable work-item id are skipped with a
    # hint. -DefaultType supplies the type for views whose rows omit a Type
    # column.
    param(
        $Selected,
        [string] $DefaultType
    )

    if ($null -eq $Selected) {
        return
    }

    $rows = @($Selected)

    if ($rows.Count -gt 1) {
        $openedAll = Invoke-AzDevOpsOpenAllSelected -Rows $rows
        if ($openedAll) {
            return
        }
    }

    foreach ($row in $rows) {
        $id = Get-AzDevOpsRowId -Row $row
        if ($id -le 0) {
            Write-Host "(selected row has no work-item id - nothing to open)" -ForegroundColor Yellow
            continue
        }

        $type = Resolve-AzDevOpsRowType -Row $row -DefaultType $DefaultType

        $childType = if ($type) {
            Get-AzDevOpsChildTypeFor -Type $type
        } else {
            $null
        }

        $titlePreview = Format-AzDevOpsTruncatedTitle -Title $row.Title
        $typeLabel = if ($type) {
            $type
        } else {
            'item'
        }
        $label = "$typeLabel $id - $titlePreview"

        $choice = Read-AzDevOpsRowActionChoice -Label $label -ChildType $childType

        if ($choice -eq 'open') {
            az-Open-WorkItemById -Id $id
        }
        elseif ($choice -eq 'create') {
            New-AzDevOpsChildForRow -ParentType $type -ParentId $id | Out-Null
        }
    }
}


function az-Show-Tree {
    [CmdletBinding()]
    param()

    $items = Read-AzDevOpsHierarchyCache
    if ($null -eq $items) { return }

    Write-AzDevOpsStaleBanner

    $byParent = @{}
    foreach ($item in $items) {
        $key = if ($null -ne $item.Parent) {
            $item.Parent
        }
        else {
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
        $selected = Show-AzDevOpsRows -Rows $rows -Title "Azure DevOps hierarchy - $(@($rows).Count) items" -PassThru
        Invoke-AzDevOpsRowAction -Selected $selected
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
#   az-Show-Board  - column-grouped board-style view of the cached
#                            hierarchy. Pipes through Show-AzDevOpsRows -PassThru
#                            so Out-ConsoleGridView's built-in group-by-State
#                            handles the kanban affordance interactively.
#
# Reuses the same $HOME/.bashcuts-az-devops-app/cache/hierarchy.json that
# az-Show-Tree consumes; never calls `az` directly. Default -Type list
# matches what the hierarchy WIQL pulls (Epic / Feature / requirement-tier).
# Default -State filter excludes closed states via Select-AzDevOpsActiveItems;
# pass -State Closed,Resolved to flip to the archive view.
# ---------------------------------------------------------------------------

function az-Show-Board {
    [CmdletBinding()]
    param(
        [string[]] $Type = @('Epic', 'Feature', 'User Story'),
        [string[]] $State
    )

    $items = Read-AzDevOpsHierarchyCache
    if ($null -eq $items) { return }

    Write-AzDevOpsStaleBanner

    $byType = @($items | Where-Object { $_.Type -in $Type })
    $byState = Select-AzDevOpsActiveItems -Items $byType -State $State

    $rows = @($byState | Sort-Object State, Type, Id | Select-Object State, Id, Type, (Get-AzDevOpsTitleColumn), Iteration)

    if ($rows.Count -eq 0) {
        Write-Host "(no items in hierarchy cache)" -ForegroundColor Yellow
        return
    }

    $title = "Board - $($rows.Count) items"

    $selected = Show-AzDevOpsRows -Rows $rows -Title $title -PassThru
    Invoke-AzDevOpsRowAction -Selected $selected
}


# ---------------------------------------------------------------------------
# Epics view (top-tier hierarchy roots)
#
# Public function:
#   az-Show-Epics - flat grid of Epics from the active project's hierarchy
#                   cache. Select a row to open it in the browser or create a
#                   child Feature (Epic -> Feature is the wired child mapping);
#                   tick several rows to open them all at once via the shared
#                   Invoke-AzDevOpsRowAction "open all" prompt.
#
# Reads the same hierarchy.json az-Show-Board / az-Show-Tree consume; never
# calls `az` directly. Single-project like Board/Tree (not multi-project like
# az-Show-Features). Default -State filter excludes closed states via
# Select-AzDevOpsActiveItems; pass -State Closed,Resolved for the archive view.
# ---------------------------------------------------------------------------

function az-Show-Epics {
    [CmdletBinding()]
    param(
        [string[]] $State
    )

    $items = Read-AzDevOpsHierarchyCache
    if ($null -eq $items) { return }

    Write-AzDevOpsStaleBanner

    $epics = @($items | Where-Object { $_.Type -eq 'Epic' })
    $active = Select-AzDevOpsActiveItems -Items $epics -State $State

    $rows = @($active | Sort-Object State, Id | Select-Object State, Id, (Get-AzDevOpsTitleColumn), Iteration)

    if ($rows.Count -eq 0) {
        Write-Host "(no epics in hierarchy cache)" -ForegroundColor Yellow
        return
    }

    $title = "Epics - $($rows.Count) items"

    $selected = Show-AzDevOpsRows -Rows $rows -Title $title -PassThru
    Invoke-AzDevOpsRowAction -Selected $selected -DefaultType 'Epic'
}


# ---------------------------------------------------------------------------
# Multi-project features view
#
# Public function:
#   az-Show-Features - flat grid of Features across every registered
#                              project in $global:AzDevOpsProjectMap, tagged
#                              with a Project column so the user can scan or
#                              group-by-Project in Out-ConsoleGridView. Pass
#                              -Project <name> to narrow to one board.
#
# Reads each project's $HOME/.bashcuts-cache/azure-devops/<slug>/hierarchy.json
# directly via Read-AzDevOpsHierarchyCacheForProject; never calls `az` and
# never flips $script:ActiveAzDevOpsProject. Projects with no cache yet are
# surfaced in a single trailing hint rather than per-project warnings.
# ---------------------------------------------------------------------------

function Get-AzDevOpsFeaturesProjectNames {
    # Resolves which projects az-Show-Features should enumerate.
    # -Project narrows to a single board; otherwise the full project map
    # wins; otherwise the active project's cache; otherwise $null to fall
    # through to the legacy unsegmented cache (single-project users).
    param([string] $Project)

    if ($Project) {
        return @($Project)
    }

    $active = Get-AzDevOpsActiveProjectName
    if ($active) {
        return @($active)
    }

    return @($null)
}


function Read-AzDevOpsFeaturesSource {
    # Resolves the hierarchy items for one features-view project name. Named
    # projects read their per-slug cache; the active project (and the legacy
    # unsegmented layout, $Name = $null) fall back to Read-AzDevOpsHierarchyCache
    # so users who sync into the legacy path still see Features instead of an
    # empty grid. Returns $null when nothing is cached for the name.
    param([string] $Name)

    if (-not $Name) {
        $legacy = Read-AzDevOpsHierarchyCache
        return $legacy
    }

    $items = Read-AzDevOpsHierarchyCacheForProject -ProjectName $Name -Quiet
    if ($null -ne $items) {
        return $items
    }

    $active = Get-AzDevOpsActiveProjectName
    if ($active -and $Name -eq $active) {
        $legacy = Read-AzDevOpsHierarchyCache
        return $legacy
    }

    return $null
}


function Write-AzDevOpsNoFeaturesHint {
    # Empty-state message for az-Show-Features: names the projects + area path
    # scanned and offers a Boards URL to verify in the browser, so an empty
    # result is actionable rather than silent.
    param([string[]] $Names)

    $named = @($Names | Where-Object { $_ })
    $projectLabel = if ($named.Count -gt 0) {
        $named -join ', '
    } else {
        '(active project)'
    }

    $areaLabel = if ($env:AZ_AREA) {
        $env:AZ_AREA
    } else {
        '(no area filter)'
    }

    Write-Host ""
    Write-Host "No Features found." -ForegroundColor Yellow
    Write-Host "  Projects checked : $projectLabel" -ForegroundColor Yellow
    Write-Host "  Area path        : $areaLabel" -ForegroundColor Yellow
    Write-Host "  Tip: run az-Sync-AzDevOpsCache to refresh the hierarchy cache." -ForegroundColor Yellow

    $boardsUrl = Get-AzDevOpsBoardsUrl
    if ($boardsUrl) {
        Write-Host "  Check in browser : $boardsUrl" -ForegroundColor Yellow
    }
}


function az-Show-Features {
    [CmdletBinding()]
    param(
        [string]   $Project,
        [string[]] $State
    )

    Write-AzDevOpsStaleBanner

    $featureType  = 'Feature'
    $legacyLabel  = '(active)'

    $names   = Get-AzDevOpsFeaturesProjectNames -Project $Project
    $missing = New-Object System.Collections.Generic.List[string]

    $rows = foreach ($name in $names) {
        $items = Read-AzDevOpsFeaturesSource -Name $name

        if ($null -eq $items) {
            if ($name) {
                $missing.Add($name) | Out-Null
            }
            continue
        }

        $features = @($items | Where-Object { $_.Type -eq $featureType })
        $active   = Select-AzDevOpsActiveItems -Items $features -State $State

        $label = if ($name) {
            $name
        } else {
            $legacyLabel
        }

        $active | Select-Object `
            @{ Name = 'Project'; Expression = { $label } }, `
            State, `
            Id, `
            (Get-AzDevOpsTitleColumn), `
            Iteration
    }

    $rows = @($rows | Sort-Object Project, State, Id)

    if ($missing.Count -gt 0) {
        $missingList = $missing -join ', '
        Write-Host "no hierarchy cache for: $missingList" -ForegroundColor Yellow
        Write-Host "  Run az-Use-AzDevOpsProject <name> then az-Sync-AzDevOpsCache to populate." -ForegroundColor Yellow
    }

    if ($rows.Count -eq 0) {
        Write-AzDevOpsNoFeaturesHint -Names $names
        return
    }

    $title = "Features - $($rows.Count) items"

    $selected = Show-AzDevOpsRows -Rows $rows -Title $title -PassThru
    Invoke-AzDevOpsRowAction -Selected $selected -DefaultType $featureType
}


# ---------------------------------------------------------------------------
# Orphans view (cached items with no parent)
#
# Public function:
#   az-Show-Orphans - lists Features and requirement-tier items (User Story /
#                     PBI / Requirement / Issue) in the hierarchy cache that
#                     have no parent, scoped to the active project area. Epics
#                     are excluded - a parentless Epic is a legitimate root,
#                     not an orphan. Select a row to open it or create a child,
#                     same post-selection action as the other az-Show-* views.
#
# Reads the same hierarchy.json az-Show-Tree / az-Show-Board consume; never
# calls `az`. -Area narrows to a sub-path of the cached area (sub-path match
# via Test-AzDevOpsAreaPathMatch) and defaults to $env:AZ_AREA. -State
# overrides the default active-only filter (pass -State Closed,Resolved to
# audit the archive).
#
# Tasks are intentionally absent: the hierarchy WIQL pulls only Epic / Feature
# / requirement-tier rows, so parentless Tasks are out of scope until a Tasks
# tier is added to the sync.
# ---------------------------------------------------------------------------

function az-Show-Orphans {
    [CmdletBinding()]
    param(
        [string]   $Area,
        [string[]] $State
    )

    $items = Read-AzDevOpsHierarchyCache
    if ($null -eq $items) { return }

    Write-AzDevOpsStaleBanner

    $orphanTypes = @('Feature') + $script:AzDevOpsRequirementTypes

    $parentless = @($items | Where-Object {
        $null -eq $_.Parent -and $_.Type -in $orphanTypes
    })

    $active = @(Select-AzDevOpsActiveItems -Items $parentless -State $State)

    $areaFilter = if ($PSBoundParameters.ContainsKey('Area')) {
        $Area
    } else {
        $env:AZ_AREA
    }

    $scoped = if ($areaFilter) {
        @($active | Where-Object {
            Test-AzDevOpsAreaPathMatch -CandidatePath $_.AreaPath -AllowedPaths @($areaFilter)
        })
    } else {
        $active
    }

    $areaLabel = if ($areaFilter) {
        $areaFilter
    } else {
        '(all areas)'
    }

    if ($scoped.Count -eq 0) {
        Write-Host "(no orphaned items under $areaLabel)" -ForegroundColor Yellow
        return
    }

    $rows = @($scoped |
        Sort-Object Type, Id |
        Select-Object Id, Type, State, (Get-AzDevOpsTitleColumn), AreaPath, Iteration)

    $title = "Orphans - $($rows.Count) items ($areaLabel)"

    $selected = Show-AzDevOpsRows -Rows $rows -Title $title -PassThru
    Invoke-AzDevOpsRowAction -Selected $selected
}


# ---------------------------------------------------------------------------
# Sprint views (cached items in one iteration)
#
# Public functions:
#   az-Show-ItemsBySprint - pick a sprint (same iteration picker the create
#                           flow uses), then list that sprint's items; pass
#                           -Iteration <path> to skip the picker.
#   az-Show-CurrentSprint - resolve the active sprint from the cached
#                           iteration dates (today within Start..Finish, the
#                           same rule `az boards iteration team list
#                           --timeframe current` applies) and list its items;
#                           falls back to $env:AZ_ITERATION when no dated
#                           iteration brackets today.
#
# Both pull the union of hierarchy.json + assigned.json (deduped by Id) so a
# Task or Bug assigned to you in the sprint shows alongside the Epic/Feature/
# Story hierarchy, filter to the chosen IterationPath, and sort open items
# first / closed items last (closed = Get-AzDevOpsClosedStates) so the work
# that still needs doing sits at the top of the grid. Selection is dispatched
# through the same Invoke-AzDevOpsRowAction the other az-Show-* views use.
# ---------------------------------------------------------------------------

function Sort-AzDevOpsByClosedLast {
    # Open items first, closed items last. The primary key is closed-state
    # membership: $false (open) sorts above $true (closed) on an ascending
    # Sort-Object, so closed rows sink to the bottom. Type then Id give a
    # stable, predictable order within each group. Mirrors the calculated-key
    # shape of Sort-AzDevOpsByDateDesc so the sort intent lives in one helper.
    param([Parameter(Mandatory)] $Items)

    $closedStates = Get-AzDevOpsClosedStates

    $sorted = $Items | Sort-Object `
        @{ Expression = { $_.State -in $closedStates } }, `
        @{ Expression = 'Type' }, `
        @{ Expression = 'Id' }

    return @($sorted)
}


function Get-AzDevOpsSprintItemPool {
    # Private. Builds the deduped item pool the sprint views filter by
    # iteration. The hierarchy cache is the primary source and the gate: when
    # it is missing, Read-AzDevOpsHierarchyCache prints the standard sync hint
    # and this returns $null so the caller aborts. Assigned-cache items are
    # additive and only contribute Ids not already present (an assigned Story
    # that is also in the hierarchy appears once); a missing assigned cache is
    # a silent no-op - it is checked with Test-Path so its own reader's
    # missing-cache hint never double-prints under the hierarchy one.
    $hierarchy = Read-AzDevOpsHierarchyCache
    if ($null -eq $hierarchy) {
        return $null
    }

    $byId = [ordered]@{}
    foreach ($item in $hierarchy) {
        $byId[[string]$item.Id] = [PSCustomObject]@{
            Id        = $item.Id
            Type      = $item.Type
            State     = $item.State
            Title     = $item.Title
            Iteration = $item.Iteration
        }
    }

    $paths = Get-AzDevOpsCachePaths
    if (Test-Path -LiteralPath $paths.Assigned) {
        $assigned = Read-AzDevOpsAssignedCache

        foreach ($item in @($assigned)) {
            $key = [string]$item.Id
            if (-not $byId.Contains($key)) {
                $byId[$key] = [PSCustomObject]@{
                    Id        = $item.Id
                    Type      = $item.Type
                    State     = $item.State
                    Title     = $item.Title
                    Iteration = $item.Iteration
                }
            }
        }
    }

    $pool = @($byId.Values)
    return $pool
}


function Resolve-AzDevOpsCurrentIteration {
    # Private. Returns the cached iteration row whose StartDate <= today <=
    # FinishDate - the same date-range test `az boards iteration team list
    # --timeframe current` applies (Azure DevOps stores no "is current" flag;
    # "current" is always derived from the sprint's start/finish dates). The
    # returned row carries Path / StartDate / FinishDate. Returns $null when no
    # dated iteration brackets today (e.g. a gap between sprints) so the caller
    # can fall back to $env:AZ_ITERATION.
    $rows = Read-AzDevOpsClassificationRows -Kind 'Iteration' -CommandName 'az-Show-CurrentSprint'
    if ($null -eq $rows -or @($rows).Count -eq 0) {
        return $null
    }

    $today = (Get-Date).Date

    $match = $rows | Where-Object {
        $_.StartDate -and $_.FinishDate -and
        $_.StartDate.Date -le $today -and $today -le $_.FinishDate.Date
    } | Select-Object -First 1

    if ($null -eq $match) {
        return $null
    }

    return $match
}


function Write-AzDevOpsCurrentSprintBanner {
    # Prints the one-line "which sprint am I looking at" banner for
    # az-Show-CurrentSprint. When the iteration was resolved from dated cache
    # rows, shows the sprint window; when it came from the $env:AZ_ITERATION
    # fallback ($Current is $null), says so.
    param(
        $Current,
        [Parameter(Mandatory)] [string] $IterationPath
    )

    $arrow = "$([char]0x2192)"   # rightwards arrow

    if ($null -ne $Current -and $Current.StartDate -and $Current.FinishDate) {
        $start  = Format-AzDevOpsClassificationDate -Date $Current.StartDate
        $finish = Format-AzDevOpsClassificationDate -Date $Current.FinishDate
        Write-Host "Current sprint: $IterationPath ($start $arrow $finish)" -ForegroundColor Cyan
        return
    }

    Write-Host "Current sprint: $IterationPath (from `$env:AZ_ITERATION)" -ForegroundColor Cyan
}


function Show-AzDevOpsSprintGrid {
    # Private. Shared body for az-Show-ItemsBySprint and az-Show-CurrentSprint:
    # pull the deduped pool, filter to $IterationPath (exact match - nested
    # child iterations are out of scope for v1, matching how the other views
    # treat iteration), sort open-first/closed-last, render via the shared
    # Show-AzDevOpsRows (Out-ConsoleGridView, Format-Table fallback), and
    # dispatch the selection through Invoke-AzDevOpsRowAction. $Label is the
    # sprint name shown in the grid title and the empty-state hint.
    param(
        [Parameter(Mandatory)] [string] $IterationPath,
        [Parameter(Mandatory)] [string] $Label
    )

    $pool = Get-AzDevOpsSprintItemPool
    if ($null -eq $pool) {
        return
    }

    $inSprint = @($pool | Where-Object { $_.Iteration -eq $IterationPath })

    if ($inSprint.Count -eq 0) {
        Write-Host "(no items in $Label)" -ForegroundColor Yellow
        return
    }

    $sorted = Sort-AzDevOpsByClosedLast -Items $inSprint

    $rows = @($sorted | Select-Object Id, Type, State, (Get-AzDevOpsTitleColumn), Iteration)
    $title = "Sprint $Label - $($rows.Count) items"

    $selected = Show-AzDevOpsRows -Rows $rows -Title $title -PassThru
    Invoke-AzDevOpsRowAction -Selected $selected
}


function az-Show-ItemsBySprint {
    [CmdletBinding()]
    param(
        [string] $Iteration
    )

    $iterationPath = if ($Iteration) {
        $Iteration
    } else {
        Read-AzDevOpsKindPick -Kind 'Iteration'
    }

    if (-not $iterationPath) {
        Write-Host "(no iteration selected - nothing to show)" -ForegroundColor Yellow
        return
    }

    # The iteration picker path (Get-AzDevOpsClassificationPaths) prints no
    # stale banner, so surface it here to match the other az-Show-* views.
    Write-AzDevOpsStaleBanner

    Show-AzDevOpsSprintGrid -IterationPath $iterationPath -Label $iterationPath
}


function az-Show-CurrentSprint {
    [CmdletBinding()]
    param()

    # Resolve-AzDevOpsCurrentIteration reads the iteration cache via
    # Read-AzDevOpsClassificationRows, which already emits the stale banner -
    # so this view does not print a second one.
    $current = Resolve-AzDevOpsCurrentIteration

    $iterationPath = if ($null -ne $current) {
        $current.Path
    } else {
        $env:AZ_ITERATION
    }

    if (-not $iterationPath) {
        Write-Host "No current sprint: no iteration brackets today and `$env:AZ_ITERATION is unset." -ForegroundColor Yellow
        Write-Host "  Run az-Sync-AzDevOpsCache to refresh iterations, or set `$env:AZ_ITERATION to a sprint path." -ForegroundColor Yellow
        return
    }

    Write-AzDevOpsCurrentSprintBanner -Current $current -IterationPath $iterationPath

    Show-AzDevOpsSprintGrid -IterationPath $iterationPath -Label $iterationPath
}
