# ============================================================================
# Azure DevOps — Cached-data views
# ============================================================================
# Read-only commands that surface the cached work-item JSON: assigned/mentions
# (pickable Out-ConsoleGridView grids via az-Get-*), tree/board/features
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
#   az-Open-AzDevOpsAssigned  - open a single assigned item in the browser
#   az-Get-AzDevOpsMentions   - table of work items where I've been @-mentioned
#   az-Open-AzDevOpsMention   - open a single mentioned item in the browser
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
    }
    catch {
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
#   - newest-first sort with $null dates pushed to the bottom
#                                  - Sort-AzDevOpsByDateDesc
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


function Get-AzDevOpsWorkItemUrlPrefix {
    # Quiet URL-prefix builder. Returns "$org/$projectEnc/_workitems/edit/" when
    # az devops defaults are configured; returns '' when either is missing.
    # Designed for callers that build URLs for many ids in a loop (e.g.
    # Out-ConsoleGridView row projections in Get-AzDevOpsTreeRows) so the prefix
    # is computed once instead of per row, and so per-row use does not pollute
    # $LASTEXITCODE.
    $defaults = Get-AzDevOpsConfiguredDefaults
    if (-not $defaults.Org -or -not $defaults.Project) {
        return ''
    }

    $org        = $defaults.Org.TrimEnd('/')
    $projectEnc = [uri]::EscapeDataString($defaults.Project)
    $prefix     = "$org/$projectEnc/_workitems/edit/"
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


function Open-AzDevOpsWorkItemUrl {
    # env-var guard + URL build + Start-Process. Sets $LASTEXITCODE = 1 and
    # returns when env-vars are missing; otherwise launches the OS browser.
    param([Parameter(Mandatory)] [int] $Id)

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
# Public functions:
#   az-Show-AzDevOpsTree   - prints the project's Epic/Feature/requirement-tier
#                          tree from the cached hierarchy.json (no `az` calls)
#   az-Show-AzDevOpsBoard  - cached items grouped by State (board-style view);
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
        Show-AzDevOpsRows -Rows $rows -Title "Azure DevOps hierarchy - $(@($rows).Count) items"
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
#   az-Show-AzDevOpsBoard  - column-grouped board-style view of the cached
#                            hierarchy. Pipes through Show-AzDevOpsRows -PassThru
#                            so Out-ConsoleGridView's built-in group-by-State
#                            handles the kanban affordance interactively.
#
# Reuses the same $HOME/.bashcuts-az-devops-app/cache/hierarchy.json that
# az-Show-AzDevOpsTree consumes; never calls `az` directly. Default -Type list
# matches what the hierarchy WIQL pulls (Epic / Feature / requirement-tier).
# Default -State filter excludes closed states via Select-AzDevOpsActiveItems;
# pass -State Closed,Resolved to flip to the archive view.
# ---------------------------------------------------------------------------

function az-Show-AzDevOpsBoard {
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

    $title = "Board - $($rows.Count) items"

    $selected = Show-AzDevOpsRows -Rows $rows -Title $title -PassThru
    return $selected
}


# ---------------------------------------------------------------------------
# Multi-project features view
#
# Public function:
#   az-Show-AzDevOpsFeatures - flat grid of Features across every registered
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
    # Resolves which projects az-Show-AzDevOpsFeatures should enumerate.
    # -Project narrows to a single board; otherwise the full project map
    # wins; otherwise the active project's cache; otherwise $null to fall
    # through to the legacy unsegmented cache (single-project users).
    param([string] $Project)

    if ($Project) {
        return @($Project)
    }

    if (Test-AzDevOpsProjectMapDefined) {
        $names = @($global:AzDevOpsProjectMap.Keys | Sort-Object)
        return $names
    }

    $active = Get-AzDevOpsActiveProjectName
    if ($active) {
        return @($active)
    }

    return @($null)
}


function az-Show-AzDevOpsFeatures {
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
        $items = if ($name) {
            Read-AzDevOpsHierarchyCacheForProject -ProjectName $name -Quiet
        } else {
            Read-AzDevOpsHierarchyCache
        }

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

    $title = "Features - $($rows.Count) items"

    $selected = Show-AzDevOpsRows -Rows $rows -Title $title -PassThru
    return $selected
}
