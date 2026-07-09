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

    $closedStates = Get-AzDevOpsClosedStates
    $visibleItems = if ($IncludeClosed) {
        $items
    }
    else {
        $items | Where-Object { $_.State -notin $closedStates }
    }

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
