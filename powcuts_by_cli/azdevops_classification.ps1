# ============================================================================
# Azure DevOps — Areas & iterations (classification trees)
# ============================================================================
# Get/Show/Find for the area-path and iteration-path classification trees:
# az-Get-AzDevOpsAreas / az-Get-AzDevOpsIterations (pipeline-friendly rows),
# az-Show-AzDevOpsAreas / az-Show-AzDevOpsIterations (human-readable trees),
# az-Find-AzDevOpsArea / az-Find-AzDevOpsIteration (interactive pickers).
# Backed by ~/.bashcuts-az-devops-app/cache/{areas,iterations}.json with a
# live `az boards iteration/area` fallback when the cache is missing.
#
# Loaded by powcuts_home.ps1. See azdevops_auth.ps1 for the master docstring.

function Read-AzDevOpsClassificationCache {
    # Reads iterations.json or areas.json from the cache. Returns the parsed
    # tree root, or $null when the cache file is missing / unparseable so
    # callers can fall back to a live `az` fetch.
    param([Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind)

    $paths = Get-AzDevOpsCachePaths
    $cachePath = if ($Kind -eq 'Iteration') {
        $paths.Iterations
    }
    else {
        $paths.Areas
    }

    if (-not (Test-Path -LiteralPath $cachePath)) {
        return $null
    }

    try {
        $tree = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
        return $tree
    }
    catch {
        return $null
    }
}


function Invoke-AzDevOpsClassificationLive {
    # Fetches the iteration / area tree directly from `az` when the cache
    # doesn't have it yet. Used as a fallback so the new-story flow keeps
    # working before the user runs az-Sync-AzDevOpsCache after this update.
    param([Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind)

    $result = Get-AzDevOpsClassificationList -Kind $Kind -Depth 5
    if ($result.ExitCode -ne 0) {
        return $null
    }

    try {
        $tree = $result.Json | ConvertFrom-Json
        return $tree
    }
    catch {
        return $null
    }
}


function ConvertTo-AzDevOpsWorkItemPath {
    # Converts an `az boards iteration/area project list` API path to the
    # IterationPath / AreaPath form used by WIQL and `az boards work-item
    # create`. The API returns paths like '\MyProject\Iteration\Sprint 42'
    # whereas work-items want 'MyProject\Sprint 42' (and 'MyProject\TeamA\
    # Backend' for areas). The classification root node ('\MyProject\Iteration')
    # has no work-item-path equivalent, so we return $null for it - callers
    # filter $null out of the picker list.
    param(
        [Parameter(Mandatory)] [string] $ApiPath,
        [Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind
    )

    $pattern = "^\\([^\\]+)\\$Kind\\"
    if ($ApiPath -match $pattern) {
        $converted = $ApiPath -replace $pattern, '$1\'
        return $converted
    }

    return $null
}


function ConvertTo-AzDevOpsClassificationPaths {
    # Flattens the tree returned by Read-AzDevOpsClassificationCache /
    # Invoke-AzDevOpsClassificationLive into a sorted, deduplicated array of
    # IterationPath / AreaPath strings ready for the picker.
    param(
        [Parameter(Mandatory)] $Root,
        [Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind
    )

    if ($null -eq $Root) {
        return @()
    }

    $collected = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)

    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        if ($null -eq $node) { continue }

        if ($node.path) {
            $converted = ConvertTo-AzDevOpsWorkItemPath -ApiPath $node.path -Kind $Kind
            if ($converted) {
                $collected.Add($converted)
            }
        }

        if ($node.children) {
            foreach ($child in $node.children) {
                $stack.Push($child)
            }
        }
    }

    $unique = $collected | Sort-Object -Unique
    $uniqueList = , @($unique)
    return $uniqueList
}


function Get-AzDevOpsClassificationPaths {
    # Single entry point for picker consumers: read from cache first, fall
    # back to live `az` with a one-line "(run az-Sync-AzDevOpsCache to make this
    # instant)" notice so the function stays usable before the user re-syncs.
    param([Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind)

    $tree = Read-AzDevOpsClassificationCache -Kind $Kind
    if ($null -eq $tree) {
        $azKind = $Kind.ToLower()
        Write-Host "(fetching ${azKind}s live - run az-Sync-AzDevOpsCache to make this instant)" -ForegroundColor Yellow
        $tree = Invoke-AzDevOpsClassificationLive -Kind $Kind
    }

    $paths = ConvertTo-AzDevOpsClassificationPaths -Root $tree -Kind $Kind
    return $paths
}


# ---------------------------------------------------------------------------
# Classification tree views
#
# Public functions:
#   az-Show-AzDevOpsAreas       - prints the project's area-path tree
#   az-Show-AzDevOpsIterations  - prints the project's iteration-path tree
#                                 (with start/finish dates per node)
#
# Both read from the cache first (areas.json / iterations.json built by
# az-Sync-AzDevOpsCache) and fall back to a live `az boards <kind> project
# list` call when the cache is missing - same pattern as the picker's
# Get-AzDevOpsClassificationPaths. Renders to Out-ConsoleGridView when
# available, falls back to an indented text tree otherwise.
# ---------------------------------------------------------------------------

function ConvertFrom-AzDevOpsClassificationTree {
    # Walks the classification tree (depth-first, children in declaration
    # order) and emits one PSCustomObject per node. Skips the synthetic root
    # node (whose path is the bare '\<Project>\<Kind>' shell with no work-
    # item-path equivalent) so consumers only see pickable entries.
    #
    # Row shape:
    #   Areas:      Depth, Name, Path, HasChildren
    #   Iterations: Depth, Name, Path, HasChildren, StartDate, FinishDate
    #
    # StartDate / FinishDate are [datetime]? so pipeline callers can use
    # `Where-Object { $_.StartDate -ge (Get-Date) }`. Display callers
    # (az-Show-AzDevOps*) format them to ISO yyyy-MM-dd strings just before
    # rendering.
    param(
        [Parameter(Mandatory)] $Tree,
        [Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind
    )

    $rows = New-Object System.Collections.Generic.List[PSCustomObject]
    if ($null -eq $Tree) {
        $empty = , @($rows)
        return $empty
    }

    $walk = {
        param($Node, $Depth)

        if ($null -eq $Node) { return }

        # Only emit the synthetic root's children onward - the root itself
        # is the bare project/kind shell that ConvertTo-AzDevOpsWorkItemPath
        # filters out (returns $null for it). Emit Path in work-item-path
        # form ('MyProject\TeamA\Backend') so pipeline callers can drop it
        # straight into WIQL or `az boards work-item create`.
        if ($Depth -gt 0) {
            $workItemPath = ConvertTo-AzDevOpsWorkItemPath -ApiPath $Node.path -Kind $Kind

            if ($workItemPath) {
                $hasChildren = [bool]($Node.children -and @($Node.children).Count -gt 0)

                $row = if ($Kind -eq 'Iteration') {
                    $startDate = if ($Node.attributes -and $Node.attributes.startDate) {
                        $Node.attributes.startDate -as [datetime]
                    }
                    else {
                        $null
                    }

                    $finishDate = if ($Node.attributes -and $Node.attributes.finishDate) {
                        $Node.attributes.finishDate -as [datetime]
                    }
                    else {
                        $null
                    }

                    [PSCustomObject]@{
                        Depth       = $Depth
                        Name        = $Node.name
                        Path        = $workItemPath
                        HasChildren = $hasChildren
                        StartDate   = $startDate
                        FinishDate  = $finishDate
                    }
                }
                else {
                    [PSCustomObject]@{
                        Depth       = $Depth
                        Name        = $Node.name
                        Path        = $workItemPath
                        HasChildren = $hasChildren
                    }
                }

                $rows.Add($row)
            }
        }

        if ($Node.children) {
            foreach ($child in $Node.children) {
                & $walk $child ($Depth + 1)
            }
        }
    }

    & $walk $Tree 0

    $result = , @($rows)
    return $result
}


function Format-AzDevOpsClassificationDate {
    # Renders a [datetime]? as ISO yyyy-MM-dd, or '' when $null. Single
    # source of truth for the date formatting used by the Show- display
    # projection and Format-AzDevOpsClassificationNode's text fallback.
    param([datetime] $Date)

    if ($null -eq $Date) {
        return ''
    }

    $iso = $Date.ToString('yyyy-MM-dd')
    return $iso
}


function ConvertTo-AzDevOpsClassificationDisplayRows {
    # Projects the typed rows from ConvertFrom-AzDevOpsClassificationTree
    # into the display-shaped rows az-Show-AzDevOpsAreas /
    # az-Show-AzDevOpsIterations render in the grid: dates become ISO
    # strings, HasChildren is dropped (display noise).
    param(
        [Parameter(Mandatory)] $Rows,
        [Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind
    )

    if ($null -eq $Rows -or @($Rows).Count -eq 0) {
        $empty = , @()
        return $empty
    }

    $displayRows = if ($Kind -eq 'Iteration') {
        @($Rows | ForEach-Object {
            $startIso  = Format-AzDevOpsClassificationDate -Date $_.StartDate
            $finishIso = Format-AzDevOpsClassificationDate -Date $_.FinishDate

            [PSCustomObject]@{
                Depth      = $_.Depth
                Name       = $_.Name
                Path       = $_.Path
                StartDate  = $startIso
                FinishDate = $finishIso
            }
        })
    }
    else {
        @($Rows | Select-Object Depth, Name, Path)
    }

    $result = , $displayRows
    return $result
}


function Format-AzDevOpsClassificationNode {
    # Text-fallback per-node line. '<indent><name>' for areas; for iterations
    # appends '<tab><start> -> <finish>' when both dates are present (omits
    # the date suffix when either is blank). The tab separator keeps the
    # dates copy-paste-able into a spreadsheet. Accepts the typed rows from
    # ConvertFrom-AzDevOpsClassificationTree (dates as [datetime]?).
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Row,
        [Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind
    )

    $indent = Get-AzDevOpsTreeIndent -Depth ($Row.Depth - 1)
    $arrowGlyph = "$([char]0x2192)"   # rightwards arrow
    $line = "$indent$($Row.Name)"

    if ($Kind -eq 'Iteration' -and $Row.StartDate -and $Row.FinishDate) {
        $startIso  = Format-AzDevOpsClassificationDate -Date $Row.StartDate
        $finishIso = Format-AzDevOpsClassificationDate -Date $Row.FinishDate
        $line = "$line`t$startIso $arrowGlyph $finishIso"
    }

    return $line
}


function Read-AzDevOpsClassificationRows {
    # Cache-first + live-fallback read + flatten. Emits the stale banner and
    # the live-fetch notice as Write-Host side effects (metadata, not data).
    # Returns the typed rows from ConvertFrom-AzDevOpsClassificationTree, or
    # $null when neither the cache nor a live fetch yields a tree (e.g. the
    # user cancels the auth gate). Shared by az-Show-AzDevOps* /
    # az-Get-AzDevOps* / az-Find-AzDevOps* for the classification trees.
    param(
        [Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind,
        [Parameter(Mandatory)] [string] $CommandName
    )

    $azKind = $Kind.ToLower()
    $kindLabelLow = "${azKind}s"

    $tree = Read-AzDevOpsClassificationCache -Kind $Kind
    $cameFromCache = $true

    if ($null -eq $tree) {
        if (-not (Assert-AzDevOpsAuthOrAbort -CommandName $CommandName)) {
            return $null
        }

        Write-Host "(fetching $kindLabelLow live - run az-Sync-AzDevOpsCache to make this instant)" -ForegroundColor Yellow
        $tree = Invoke-AzDevOpsClassificationLive -Kind $Kind
        $cameFromCache = $false
    }

    if ($null -eq $tree) {
        return $null
    }

    if ($cameFromCache) {
        Write-AzDevOpsStaleBanner
    }

    $rows = ConvertFrom-AzDevOpsClassificationTree -Tree $tree -Kind $Kind
    return $rows
}


function Show-AzDevOpsClassification {
    # Orchestrator for az-Show-AzDevOpsAreas / az-Show-AzDevOpsIterations.
    # Reads + flattens via Read-AzDevOpsClassificationRows, projects typed
    # rows to display rows, then renders to Out-ConsoleGridView when
    # available or to an indented text tree via Format-AzDevOpsClassificationNode
    # otherwise. Mirrors the az-Show-AzDevOpsTree post-#36 shape so the Show-
    # family stays uniform.
    param([Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind)

    $azKind = $Kind.ToLower()
    $kindLabelLow = "${azKind}s"
    $publicCommand = "az-Show-AzDevOps$($Kind)s"

    $rows = Read-AzDevOpsClassificationRows -Kind $Kind -CommandName $publicCommand
    if ($null -eq $rows) {
        return
    }

    if (@($rows).Count -eq 0) {
        Write-Host "(no $kindLabelLow defined)" -ForegroundColor Yellow
        return
    }

    if (Test-AzDevOpsGridAvailable) {
        $displayRows = ConvertTo-AzDevOpsClassificationDisplayRows -Rows $rows -Kind $Kind
        $title = "Azure DevOps $kindLabelLow - $(@($rows).Count) nodes"
        Show-AzDevOpsRows -Rows $displayRows -Title $title
        return
    }

    foreach ($row in $rows) {
        Write-Output (Format-AzDevOpsClassificationNode -Row $row -Kind $Kind)
    }
}


function az-Show-AzDevOpsAreas {
    [CmdletBinding()]
    param()

    Show-AzDevOpsClassification -Kind 'Area'
}


function az-Show-AzDevOpsIterations {
    [CmdletBinding()]
    param()

    Show-AzDevOpsClassification -Kind 'Iteration'
}


# ---------------------------------------------------------------------------
# Classification rows for pipeline consumers
#
# Public functions:
#   az-Get-AzDevOpsAreas       - pipeable rows for the area-path tree
#                                (Depth / Name / Path / HasChildren)
#   az-Get-AzDevOpsIterations  - pipeable rows for the iteration tree
#                                (adds StartDate / FinishDate as [datetime]?)
#
# Both wrap Read-AzDevOpsClassificationRows so the cache-first / live-fallback
# behavior matches az-Show-AzDevOps*. Path is the work-item-path form
# ('MyProject\TeamA\Backend') so callers can pipe straight into WIQL or
# `az boards work-item create --area-path ...`.
# ---------------------------------------------------------------------------

function az-Get-AzDevOpsAreas {
    [CmdletBinding()]
    param()

    $rows = Read-AzDevOpsClassificationRows -Kind 'Area' -CommandName 'az-Get-AzDevOpsAreas'
    return $rows
}


function az-Get-AzDevOpsIterations {
    [CmdletBinding()]
    param()

    $rows = Read-AzDevOpsClassificationRows -Kind 'Iteration' -CommandName 'az-Get-AzDevOpsIterations'
    return $rows
}


# ---------------------------------------------------------------------------
# Classification pickers (interactive drill-down for the classification trees)
#
# Public functions:
#   az-Find-AzDevOpsArea       - Out-ConsoleGridView picker over the area tree;
#                                emits the picked Path (work-item-path form)
#                                or $null when the user cancels.
#   az-Find-AzDevOpsIteration  - same shape, plus StartDate / FinishDate grid
#                                columns so the user can pick by sprint dates.
#
# Both require Microsoft.PowerShell.ConsoleGuiTools - they print the install
# hint and return when the cmdlet is missing. Neither function has side
# effects (does not set $env:AZ_AREA / $env:AZ_ITERATION); callers that want
# that behavior can pipe the result into Set-Item env:AZ_AREA.
# ---------------------------------------------------------------------------

$script:AzDevOpsConsoleGuiToolsInstallHint = 'Install with: Install-Module Microsoft.PowerShell.ConsoleGuiTools -Scope CurrentUser'


function Write-AzDevOpsGridUnavailable {
    # Single source of truth for the "Out-ConsoleGridView is required for X"
    # message shape so every az-Find-AzDevOps* uses the same wording.
    param([Parameter(Mandatory)] [string] $CommandName)

    Write-Host "Out-ConsoleGridView is required for $CommandName." -ForegroundColor Yellow
    Write-Host "  $script:AzDevOpsConsoleGuiToolsInstallHint" -ForegroundColor Yellow
}


function az-Find-AzDevOpsArea {
    [CmdletBinding()]
    param()

    if (-not (Test-AzDevOpsGridAvailable)) {
        Write-AzDevOpsGridUnavailable -CommandName 'az-Find-AzDevOpsArea'
        return
    }

    $rows = Read-AzDevOpsClassificationRows -Kind 'Area' -CommandName 'az-Find-AzDevOpsArea'
    if ($null -eq $rows -or @($rows).Count -eq 0) {
        Write-Host '(no areas available)' -ForegroundColor Yellow
        return
    }

    $paths = @($rows | ForEach-Object { $_.Path } | Where-Object { $_ })
    if ($paths.Count -eq 0) {
        Write-Host '(no pickable area paths)' -ForegroundColor Yellow
        return
    }

    # Read-AzDevOpsClassificationPick returns its $Default param on cancel,
    # which falls back to '' (empty string) when no default is supplied here.
    # Normalize that to $null so this function and az-Find-AzDevOpsIteration
    # share the same "cancelled" signal on the pipeline.
    $picked = Read-AzDevOpsClassificationPick -Kind 'Area' -Paths $paths
    if (-not $picked) {
        return $null
    }

    return $picked
}


function az-Find-AzDevOpsIteration {
    [CmdletBinding()]
    param()

    if (-not (Test-AzDevOpsGridAvailable)) {
        Write-AzDevOpsGridUnavailable -CommandName 'az-Find-AzDevOpsIteration'
        return
    }

    $rows = Read-AzDevOpsClassificationRows -Kind 'Iteration' -CommandName 'az-Find-AzDevOpsIteration'
    if ($null -eq $rows -or @($rows).Count -eq 0) {
        Write-Host '(no iterations available)' -ForegroundColor Yellow
        return
    }

    $displayRows = ConvertTo-AzDevOpsClassificationDisplayRows -Rows $rows -Kind 'Iteration'
    $pickRows = @($displayRows | Select-Object Path, StartDate, FinishDate)

    $picked = Read-AzDevOpsGridPick -Rows $pickRows -Title 'Pick iteration'
    if ($null -eq $picked) {
        return $null
    }

    $pickedPath = [string]$picked.Path
    return $pickedPath
}
