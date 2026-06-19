# ============================================================================
# Azure DevOps — Interactive hierarchy drill-down
# ============================================================================
# az-Find-AzDevOpsWorkItem walks Epic -> Feature -> requirement-tier in
# Out-ConsoleGridView grids with a "Go Back" affordance at each tier and an
# inline "Open in browser" action row.
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

