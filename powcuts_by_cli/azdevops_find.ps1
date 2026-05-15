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
# az-Show-AzDevOpsTree consumes; never calls `az` directly. Modeled on the
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
                Open-AzDevOpsWorkItemUrl -Id $currentEpic.Id
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
                Open-AzDevOpsWorkItemUrl -Id $currentFeature.Id
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

            Open-AzDevOpsWorkItemUrl -Id $currentStory.Id
            Write-Output $currentStory.Id

            $tier = 1
            continue
        }
    }
}

