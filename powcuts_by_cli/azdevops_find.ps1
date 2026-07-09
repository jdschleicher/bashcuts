# ============================================================================
# Azure DevOps — Interactive hierarchy drill-down + flat fuzzy search
# ============================================================================
# az-Find-AzDevOpsWorkItem walks Epic -> Feature -> requirement-tier in
# Out-ConsoleGridView grids with a "Go Back" affordance at each tier and an
# inline "Open in browser" action row.
#
# az-Find-AzDevOpsItem is the flat companion: it fuzzy-matches a typed query
# against every cached work item (Epic, Feature, and requirement-tier alike -
# no Epic-first drill-down), ranks the hits, and pipes them into the same
# grid picker + post-selection dispatcher the az-Show-* views use.
#
# Loaded by powcuts_home.ps1. See azdevops_auth.ps1 for the master docstring.

# ---------------------------------------------------------------------------
# Interactive hierarchy drill-down
#
# Public function:
#   az-Find-AzDevOpsWorkItem - drills Epic -> Feature -> requirement-tier
#                              in Out-ConsoleGridView grids with a "Go Back"
#                              affordance at each tier and an inline "Open
#                              in browser" action. Loops on the outer Epic
#                              grid so the user can navigate multiple
#                              branches in one session and emits picked
#                              work-item ids on the pipeline.
#
# Reads the same $HOME/.bashcuts-az-devops-app/cache/hierarchy.json that
# az-Show-Tree consumes; never calls `az` directly. Modeled on the
# while ($running) { ... } + ".. [Go Back]" pattern from issue #39.
# ---------------------------------------------------------------------------

function New-AzDevOpsActionRow {
    # Synthetic grid row for EXIT / Go Back / Open shortcuts. Same column
    # shape as a hierarchy item so Out-ConsoleGridView columns don't collapse;
    # Type='Action' is the marker the drill-down loop dispatches on.
    param([Parameter(Mandatory)] [string] $Title)

    $row = [PSCustomObject]@{
        Type   = 'Action'
        Id     = 0
        Title  = $Title
        State  = ''
        Parent = $null
    }

    return $row
}


# ---------------------------------------------------------------------------
# Free-text fuzzy filter over the cached hierarchy
#
# Public function:
#   az-Find-AzDevOpsText - filters the cached Epic/Feature/requirement-tier
#                          rows by a free-text query over Title + Description
#                          and hands the hits to Out-ConsoleGridView, whose own
#                          live-filter box then narrows further. Selecting a row
#                          opens it or creates its hierarchical child via the
#                          shared Invoke-AzDevOpsRowAction dispatcher.
#
# Reads the same $HOME/.bashcuts-az-devops-app/cache/hierarchy.json that
# az-Show-Tree / az-Find-AzDevOpsWorkItem consume; never calls `az` directly.
# Description search needs [System.Description] in the hierarchy WIQLs - it's
# in the seeded defaults, but users with older seeded *.wiql files get a
# one-line tip to add it (Title-only search still works meanwhile).
# ---------------------------------------------------------------------------

function Get-AzDevOpsVisibleItems {
    # Shared -IncludeClosed gate for the az-Find-* hierarchy views: drops items
    # in a closed state unless the switch is set, in which case everything passes
    # through. Extracted so az-Find-AzDevOpsText and az-Find-AzDevOpsWorkItem
    # share one copy of the filter rather than each inlining the same if/else
    # (CLAUDE.md extract-repeated-branches rule).
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] $Items,
        [switch] $IncludeClosed
    )

    if ($IncludeClosed) {
        return @($Items)
    }

    $closedStates = Get-AzDevOpsClosedStates
    $visible = @($Items | Where-Object { $_.State -notin $closedStates })
    return $visible
}


function Select-AzDevOpsTextMatches {
    # Filters hierarchy items by a free-text query over Title + Description.
    # The query is split on whitespace into tokens; an item matches when EVERY
    # token appears (case-insensitive substring) in its combined "Title
    # Description" haystack - an AND-of-substrings filter that behaves like the
    # grid's live filter box but runs first so a large cache narrows to the hits
    # before rendering. An empty/whitespace query returns every item unchanged
    # so the caller can hand the full set to the grid's own live filter.
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] $Items,
        [string] $Query
    )

    if ([string]::IsNullOrWhiteSpace($Query)) {
        return @($Items)
    }

    $tokens = @($Query -split '\s+' | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })

    $matched = foreach ($item in $Items) {
        $haystack = "$($item.Title) $($item.Description)".ToLowerInvariant()

        $allPresent = $true
        foreach ($token in $tokens) {
            if (-not $haystack.Contains($token)) {
                $allPresent = $false
                break
            }
        }

        if ($allPresent) {
            $item
        }
    }

    return @($matched)
}


function Format-AzDevOpsTextSnippet {
    # Collapses a (possibly multi-line, HTML-stripped) description into a single
    # line and truncates it to a grid-friendly length so the Description column
    # stays scannable. The -Query pre-filter still searches the full text; this
    # only shapes what the grid renders (and what the grid's live filter sees).
    param([string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $snippetMaxLen = 200
    $ellipsis      = '...'

    $collapsed = ($Text -replace '\s+', ' ').Trim()

    if ($collapsed.Length -gt $snippetMaxLen) {
        $truncated = $collapsed.Substring(0, $snippetMaxLen - $ellipsis.Length) + $ellipsis
        return $truncated
    }

    return $collapsed
}


function Write-AzDevOpsNoDescriptionTip {
    # One-line hint shown when the hierarchy cache carries no descriptions at
    # all - usually means the user's seeded WIQL files predate the
    # [System.Description] addition. Keeps the search useful (Title-only) while
    # pointing at the one edit that unlocks description search.
    param([Parameter(Mandatory)] $Items)

    $hasAnyDescription = @($Items | Where-Object { $_.Description }).Count -gt 0
    if ($hasAnyDescription) {
        return
    }

    Write-Host "Tip: no descriptions cached - add [System.Description] to your hierarchy WIQLs (az-Open-HierarchyWiqls), then re-run az-Sync-AzDevOpsCache to search descriptions too." -ForegroundColor DarkGray
}


function az-Find-AzDevOpsText {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] [string] $Query,
        [switch] $IncludeClosed
    )

    $items = Read-AzDevOpsHierarchyCache
    if ($null -eq $items) { return }

    Write-AzDevOpsStaleBanner
    Write-AzDevOpsNoDescriptionTip -Items $items

    $visibleItems = Get-AzDevOpsVisibleItems -Items $items -IncludeClosed:$IncludeClosed

    $hits = @(Select-AzDevOpsTextMatches -Items $visibleItems -Query $Query)

    if ($hits.Count -eq 0) {
        $scopeLabel = if ($Query) {
            "matching '$Query'"
        }
        else {
            'in the hierarchy cache'
        }
        Write-Host "(no work items $scopeLabel)" -ForegroundColor Yellow
        return
    }

    $urlPrefix = Get-AzDevOpsWorkItemUrlPrefix

    $rows = @($hits |
        Sort-Object Type, Id |
        Select-Object `
            Id, `
            Type, `
            State, `
            (Get-AzDevOpsTitleColumn), `
            @{
                Name       = 'Description'
                Expression = { Format-AzDevOpsTextSnippet -Text $_.Description }
            }, `
            Iteration, `
            @{
                Name       = 'Url'
                Expression = {
                    if ($urlPrefix) {
                        "$urlPrefix$($_.Id)"
                    }
                    else {
                        ''
                    }
                }
            })

    $titleScope = if ($Query) {
        " matching '$Query'"
    }
    else {
        ''
    }
    $title = "Find work items$titleScope - $($rows.Count) items (type to filter Title + Description)"

    $selected = Show-AzDevOpsRows -Rows $rows -Title $title -PassThru
    Invoke-AzDevOpsRowAction -Selected $selected
}


function az-Find-AzDevOpsWorkItem {
    [CmdletBinding()]
    param(
        [switch] $IncludeClosed
    )

    if (-not (Test-AzDevOpsGridAvailable)) {
        Write-AzDevOpsGridUnavailable -CommandName 'az-Find-AzDevOpsWorkItem'
        return
    }

    $items = Read-AzDevOpsHierarchyCache
    if ($null -eq $items) { return }

    Write-AzDevOpsStaleBanner

    $visibleItems = Get-AzDevOpsVisibleItems -Items $items -IncludeClosed:$IncludeClosed

    $byParent = @{}
    foreach ($item in $visibleItems) {
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

    $epics = @($visibleItems | Where-Object { $_.Type -eq 'Epic' } | Sort-Object Id)
    if ($epics.Count -eq 0) {
        Write-Host "(no epics in hierarchy cache)" -ForegroundColor Yellow
        return
    }

    $exitLabel = 'EXIT'
    $backLabel = '.. [Go Back]'
    $openEpicLabel = '.. [Open this Epic]'
    $openFeatureLabel = '.. [Open this Feature]'
    $openStoryLabel = '.. [Open this Story]'

    $running = $true
    $tier = 1
    $currentEpic = $null
    $currentFeature = $null
    $currentStory = $null

    while ($running) {

        if ($tier -eq 1) {
            $rows = @(New-AzDevOpsActionRow -Title $exitLabel) + $epics
            $title = "ALM Browser - pick an Epic ('EXIT' or Esc to quit)"
            $picked = $rows | Out-ConsoleGridView -Title $title -OutputMode Single

            if ($null -eq $picked -or $picked.Title -eq $exitLabel) {
                $running = $false
                continue
            }

            $currentEpic = $picked
            $tier = 2
            continue
        }

        if ($tier -eq 2) {
            $features = @($byParent[$currentEpic.Id] | Where-Object { $_.Type -eq 'Feature' } | Sort-Object Id)
            $rows = @(New-AzDevOpsActionRow -Title $backLabel) + $features + @(New-AzDevOpsActionRow -Title $openEpicLabel)

            $title = "Epic $($currentEpic.Id) - $($currentEpic.Title) - pick a Feature"
            $picked = $rows | Out-ConsoleGridView -Title $title -OutputMode Single

            if ($null -eq $picked -or $picked.Title -eq $backLabel) {
                $tier = 1
                continue
            }

            if ($picked.Title -eq $openEpicLabel) {
                az-Open-WorkItemById -Id $currentEpic.Id
                Write-Output $currentEpic.Id
                continue
            }

            $currentFeature = $picked
            $tier = 3
            continue
        }

        if ($tier -eq 3) {
            $stories = @($byParent[$currentFeature.Id] | Where-Object { $_.Type -in $script:AzDevOpsRequirementTypes } | Sort-Object Id)
            $rows = @(New-AzDevOpsActionRow -Title $backLabel) + $stories + @(New-AzDevOpsActionRow -Title $openFeatureLabel)

            $title = "Feature $($currentFeature.Id) - $($currentFeature.Title) - pick a Story"
            $picked = $rows | Out-ConsoleGridView -Title $title -OutputMode Single

            if ($null -eq $picked -or $picked.Title -eq $backLabel) {
                $tier = 2
                continue
            }

            if ($picked.Title -eq $openFeatureLabel) {
                az-Open-WorkItemById -Id $currentFeature.Id
                Write-Output $currentFeature.Id
                continue
            }

            $currentStory = $picked
            $tier = 4
            continue
        }

        if ($tier -eq 4) {
            $rows = @(
                New-AzDevOpsActionRow -Title $backLabel
                New-AzDevOpsActionRow -Title $openStoryLabel
            )

            $title = "Story $($currentStory.Id) - $($currentStory.Title) - choose action"
            $picked = $rows | Out-ConsoleGridView -Title $title -OutputMode Single

            if ($null -eq $picked -or $picked.Title -eq $backLabel) {
                $tier = 3
                continue
            }

            az-Open-WorkItemById -Id $currentStory.Id
            Write-Output $currentStory.Id

            $tier = 1
            continue
        }
    }
}


# ---------------------------------------------------------------------------
# Flat fuzzy search across every cached work item
#
# Public function:
#   az-Find-AzDevOpsItem - fuzzy-match a query against all cached items (no
#                          Epic-first drill-down), rank the hits, and pipe
#                          them into the shared grid picker + post-selection
#                          dispatcher (open in browser / create a child).
#
# Reads the same hierarchy.json cache az-Show-Tree / az-Find-AzDevOpsWorkItem
# consume; never calls `az` directly. Match uses an fzf-style subsequence
# scorer so "uslogin" finds "User Story: Login flow".
# ---------------------------------------------------------------------------

function Get-AzDevOpsFuzzyScore {
    # Subsequence fuzzy match (fzf-style). Returns an integer rank score when
    # every character of $Query appears in $Text in order (case-insensitive),
    # rewarding contiguous runs, word-boundary starts, and early first matches
    # (a late single-char hit can score negative - that still counts as a match;
    # the score only orders results). Returns $null when $Text is not a
    # supersequence of $Query. Whitespace in $Query is ignored so "us login"
    # still matches "User Story: login flow".
    param(
        [Parameter(Mandatory)] [string] $Query,
        [Parameter(Mandatory)] [string] $Text
    )

    $needle = ($Query -replace '\s', '').ToLowerInvariant()
    if ($needle.Length -eq 0) {
        return 0
    }

    $haystack = $Text.ToLowerInvariant()

    $matchBaseScore   = 4
    $contiguousBonus  = 8
    $wordStartBonus   = 6
    $leadingPenalty   = 1
    $maxLeadingOffset = 12
    $wordBoundaryChars = @(' ', '-', '_', '.', '/', '\', ':', '[', ']', '(', ')')

    $score     = 0
    $textIndex = 0
    $prevMatch = -2

    foreach ($ch in $needle.ToCharArray()) {

        $found = -1
        for ($i = $textIndex; $i -lt $haystack.Length; $i++) {
            if ($haystack[$i] -eq $ch) {
                $found = $i
                break
            }
        }

        if ($found -lt 0) {
            return $null
        }

        $score += $matchBaseScore

        if ($found -eq ($prevMatch + 1)) {
            $score += $contiguousBonus
        }

        $atWordStart = $found -eq 0 -or ($haystack[$found - 1] -in $wordBoundaryChars)
        if ($atWordStart) {
            $score += $wordStartBonus
        }

        if ($prevMatch -lt 0) {
            $score -= [Math]::Min($found, $maxLeadingOffset) * $leadingPenalty
        }

        $prevMatch = $found
        $textIndex = $found + 1
    }

    return $score
}


function Get-AzDevOpsFuzzyMatches {
    # Scores every item in $Pool against $Query and returns the matching items
    # ranked best-first (ties broken by newest id). Items whose "Id Type Title"
    # is not a supersequence of the query are dropped. Returns an empty array
    # when nothing matches.
    param(
        [Parameter(Mandatory)] $Pool,
        [Parameter(Mandatory)] [string] $Query
    )

    $scored = foreach ($item in $Pool) {
        $searchText = "$($item.Id) $($item.Type) $($item.Title)"
        $score = Get-AzDevOpsFuzzyScore -Query $Query -Text $searchText

        if ($null -ne $score) {
            [PSCustomObject]@{
                Item  = $item
                Score = $score
            }
        }
    }

    $ranked = $scored | Sort-Object `
    @{ Expression = 'Score'; Descending = $true }, `
    @{ Expression = { $_.Item.Id }; Descending = $true }

    $matches = @($ranked | ForEach-Object { $_.Item })
    return $matches
}


function az-Find-AzDevOpsItem {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] [string] $Query,
        [string[]] $Type,
        [switch] $IncludeClosed
    )

    $items = Read-AzDevOpsHierarchyCache
    if ($null -eq $items) { return }

    Write-AzDevOpsStaleBanner

    $pool = if ($IncludeClosed) {
        $items
    }
    else {
        Select-AzDevOpsActiveItems -Items $items
    }

    if ($Type) {
        $pool = $pool | Where-Object { $_.Type -in $Type }
    }

    $pool = @($pool)
    if ($pool.Count -eq 0) {
        Write-Host "(no work items in the hierarchy cache match the current filter)" -ForegroundColor Yellow
        return
    }

    if (-not $PSBoundParameters.ContainsKey('Query') -or [string]::IsNullOrWhiteSpace($Query)) {
        $Query = Read-Host "Fuzzy search work items (blank = list all)"
    }

    $trimmedQuery = if ($null -ne $Query) {
        $Query.Trim()
    }
    else {
        ''
    }

    if ($trimmedQuery.Length -gt 0) {
        $matched = Get-AzDevOpsFuzzyMatches -Pool $pool -Query $trimmedQuery

        if ($matched.Count -eq 0) {
            Write-Host "No work items fuzzy-match '$trimmedQuery'. Try fewer / different characters, or -IncludeClosed." -ForegroundColor Yellow
            return
        }
    }
    else {
        $matched = @($pool | Sort-Object Type, Id)
    }

    $maxResults = 100
    if ($matched.Count -gt $maxResults) {
        Write-Host "Showing top $maxResults of $($matched.Count) matches - narrow your query to see fewer." -ForegroundColor DarkGray
        $matched = $matched[0..($maxResults - 1)]
    }

    $rows = @($matched | Select-Object Id, Type, State, (Get-AzDevOpsTitleColumn), Iteration, AreaPath)

    $titleBar = if ($trimmedQuery.Length -gt 0) {
        "Fuzzy find '$trimmedQuery' - $($rows.Count) match(es)"
    }
    else {
        "All work items - $($rows.Count)"
    }

    if (-not (Test-AzDevOpsGridAvailable)) {
        $rows | Format-Table -AutoSize | Out-Host
        return
    }

    $selected = Show-AzDevOpsRows -Rows $rows -Title $titleBar -PassThru
    Invoke-AzDevOpsRowAction -Selected $selected
}
