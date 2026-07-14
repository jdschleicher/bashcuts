# ============================================================================
# Azure DevOps — Draft (deferred) work-item hierarchy builder
# ============================================================================
# A "brain-dump" buffer for building an Epic -> Feature -> User Story -> Task
# hierarchy locally with ZERO `az` calls, then publishing the whole tree at
# once. Nothing hits Azure until az-Publish-AzDevOpsDraft runs: adding, editing,
# re-parenting, and reviewing items are all local JSON edits, so there is no
# per-item CLI round-trip friction while the shape of the backlog is still in
# flux.
#
# Relationships are carried by a local reference id (Ref) on each draft item -
# a child points at its parent's Ref, not at a real Azure id that doesn't exist
# yet. At publish time the tree is walked parents-first, each Ref is mapped to
# the real created id, and the parent link is added in the same pass. A live
# progress bar reports how far the publish has landed ("percentage finished").
#
# Public surface:
#   az-New-AzDevOpsDraft         - guided brain-dump loop, then optional publish
#   az-Add-AzDevOpsDraftItem     - quick add one item (params-driven)
#   az-Set-AzDevOpsDraftItem     - fill in / edit an existing draft item's fields
#   az-Remove-AzDevOpsDraftItem  - drop one item (children reparent to grandparent)
#   az-Show-AzDevOpsDraft        - render the draft tree + per-item completeness %
#   az-Publish-AzDevOpsDraft     - create every item in Azure + wire links (progress)
#   az-Clear-AzDevOpsDraft       - discard the whole draft
#
# The draft persists at <cache>/draft.json (project-segmented like the rest of
# the cache), so a brain dump survives across shells until it's published or
# cleared. Loaded by powcuts_home.ps1. See azdevops_auth.ps1 for the master
# docstring.

$script:AzDevOpsDraftFileName = 'draft.json'

# Canonical work-item type strings the draft stores, ordered top-of-tree first.
# Each carries the type it nests under; '' marks a root tier (Epic). Task's
# parent is 'User Story' - matched against the requirement-type set at pick time
# so Scrum / CMMI / Basic leaf types resolve too.
$script:AzDevOpsDraftEpicType    = 'Epic'
$script:AzDevOpsDraftFeatureType = 'Feature'
$script:AzDevOpsDraftStoryType   = 'User Story'
$script:AzDevOpsDraftTaskType    = 'Task'

# Azure DevOps' stock default priority (Medium) - applied to a drafted item that
# was published without a priority ever being set, so the create never sends an
# out-of-range value. Min/Max bound the valid 1-4 range shared by the field-
# fill check, the publish create-args builder, and the az-Set editor.
$script:AzDevOpsDraftDefaultPriority = 2
$script:AzDevOpsDraftMinPriority     = 1
$script:AzDevOpsDraftMaxPriority     = 4


function Test-AzDevOpsDraftPriorityValid {
    # True when $Priority is inside Azure DevOps' 1-4 priority range. Single
    # source of the bound so the field-fill check, the create-args builder, and
    # the az-Set editor can't drift.
    param([Parameter(Mandatory)] [int] $Priority)

    $valid = ($Priority -ge $script:AzDevOpsDraftMinPriority -and $Priority -le $script:AzDevOpsDraftMaxPriority)
    return $valid
}


function Get-AzDevOpsDraftTierOrder {
    # Ordered tier descriptors: canonical Type + the parent Type it nests under.
    # Single source of truth for tier order (publish sort tie-break, type picker,
    # parent-tier lookup) so a template change is a one-place edit.
    $tiers = @(
        [PSCustomObject]@{ Type = $script:AzDevOpsDraftEpicType;    ParentType = '' }
        [PSCustomObject]@{ Type = $script:AzDevOpsDraftFeatureType; ParentType = $script:AzDevOpsDraftEpicType }
        [PSCustomObject]@{ Type = $script:AzDevOpsDraftStoryType;   ParentType = $script:AzDevOpsDraftFeatureType }
        [PSCustomObject]@{ Type = $script:AzDevOpsDraftTaskType;    ParentType = $script:AzDevOpsDraftStoryType }
    )

    return $tiers
}


function Get-AzDevOpsDraftParentType {
    # Returns the Type a given child Type nests under, or '' for a root tier.
    param([Parameter(Mandatory)] [string] $Type)

    $tier = Get-AzDevOpsDraftTierOrder | Where-Object { $_.Type -eq $Type } | Select-Object -First 1

    $parentType = if ($tier) {
        $tier.ParentType
    } else {
        ''
    }

    return $parentType
}


function Test-AzDevOpsDraftTypeMatchesTier {
    # True when $CandidateType can serve as a parent of tier $ParentType. Exact
    # match for Epic / Feature; for the 'User Story' tier any requirement-type
    # (User Story / PBI / Requirement / Issue) qualifies, mirroring the create-
    # flow parent pickers.
    param(
        [Parameter(Mandatory)] [string] $CandidateType,
        [Parameter(Mandatory)] [string] $ParentType
    )

    if ($ParentType -eq $script:AzDevOpsDraftStoryType) {
        $isMatch = $CandidateType -in $script:AzDevOpsRequirementTypes
        return $isMatch
    }

    $isMatch = $CandidateType -eq $ParentType
    return $isMatch
}


# ---------------------------------------------------------------------------
# Storage — load / save the local draft
# ---------------------------------------------------------------------------

function Get-AzDevOpsDraftPath {
    # Resolve <cacheDir>/draft.json under the active (project-segmented) cache
    # layout, or $null when no cache dir is available.
    $path = Get-AzDevOpsCacheFilePath -FileName $script:AzDevOpsDraftFileName
    return $path
}


function Read-AzDevOpsDraft {
    # Load the draft as an array of item records (empty array when absent /
    # unparseable). Never calls `az`. ExtraFields round-trips back as a
    # PSCustomObject; Build-AzDevOpsDraftCreateArgs normalizes it at publish.
    $path = Get-AzDevOpsDraftPath
    if (-not $path) {
        return @()
    }

    $items = Read-AzDevOpsJsonArrayCache -Path $path
    return $items
}


function Save-AzDevOpsDraft {
    # Persist the draft item array. Accepts an empty collection so a fully-
    # published or cleared draft writes an empty list rather than deleting the
    # file. Returns $true on write, $false when no cache dir is available.
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Items)

    $path = Get-AzDevOpsDraftPath
    if (-not $path) {
        Write-Host "No cache directory available - cannot save the draft. Run az-Connect-AzDevOps first." -ForegroundColor Red
        return $false
    }

    Save-AzDevOpsJsonArrayCache -Path $path -Items $Items
    return $true
}


function Get-AzDevOpsNextDraftRef {
    # Next local reference id: max existing Ref + 1, or 1 for an empty draft.
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Draft)

    $maxRef = 0
    foreach ($item in $Draft) {
        $ref = [int]$item.Ref
        if ($ref -gt $maxRef) {
            $maxRef = $ref
        }
    }

    $next = $maxRef + 1
    return $next
}


function Get-AzDevOpsDraftItemByRef {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Draft,
        [Parameter(Mandatory)] [int] $Ref
    )

    $item = $Draft | Where-Object { [int]$_.Ref -eq $Ref } | Select-Object -First 1
    return $item
}


function Get-AzDevOpsDraftRefSet {
    # Hashtable of every draft item's Ref -> $true, for O(1) "does this Ref
    # exist" tests (dangling-parent detection in the tree render, the publish
    # sort, and publish parent resolution all need it).
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Draft)

    $refSet = @{}
    foreach ($item in $Draft) {
        $refSet[[int]$item.Ref] = $true
    }

    return $refSet
}


function Get-AzDevOpsDraftChildMap {
    # Hashtable of ParentRef -> List[child records] for the draft. Only parents
    # that actually have children get a key, so callers MUST guard the lookup
    # with .ContainsKey (or a $null check) before iterating - `@($map[$absent])`
    # is `@($null)`, a one-element array holding $null, which would iterate once
    # on a bogus $null child.
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Draft)

    $childMap = @{}
    foreach ($item in $Draft) {
        $parentRef = [int]$item.ParentRef
        if ($parentRef -gt 0) {
            if (-not $childMap.ContainsKey($parentRef)) {
                $childMap[$parentRef] = [System.Collections.Generic.List[object]]::new()
            }
            $childMap[$parentRef].Add($item)
        }
    }

    return $childMap
}


function New-AzDevOpsDraftItemRecord {
    # Build a draft item record. Only Ref + Type + Title are conceptually
    # required; every other field is optional so a title-only brain-dump entry
    # is valid and its completeness score reflects what's still missing.
    param(
        [Parameter(Mandatory)] [int]    $Ref,
        [Parameter(Mandatory)] [string] $Type,
        [Parameter(Mandatory)] [string] $Title,
        [string]    $Description = '',
        [int]       $Priority = -1,
        [int]       $StoryPoints = -1,
        [string]    $AcceptanceCriteria = '',
        [string[]]  $Tags = @(),
        [string]    $Iteration = '',
        [string]    $Area = '',
        [hashtable] $ExtraFields = @{},
        [int]       $ParentRef = 0,
        [int]       $ParentId = 0
    )

    $record = [PSCustomObject]@{
        Ref                = $Ref
        Type               = $Type
        Title              = $Title
        Description        = $Description
        Priority           = $Priority
        StoryPoints        = $StoryPoints
        AcceptanceCriteria = $AcceptanceCriteria
        Tags               = $Tags
        Iteration          = $Iteration
        Area               = $Area
        ExtraFields        = $ExtraFields
        ParentRef          = $ParentRef
        ParentId           = $ParentId
    }

    return $record
}


# ---------------------------------------------------------------------------
# Completeness — how "finished" a drafted item is
# ---------------------------------------------------------------------------

function Get-AzDevOpsDraftExpectedFields {
    # The fields that count toward a type's completeness score, in display
    # order. User Stories carry the richest spec (points + acceptance criteria);
    # every non-root tier also expects a parent link.
    param([Parameter(Mandatory)] [string] $Type)

    $fields = [System.Collections.Generic.List[object]]::new()

    $fields.Add([PSCustomObject]@{ Key = 'Title';       Label = 'Title' })
    $fields.Add([PSCustomObject]@{ Key = 'Description'; Label = 'Description' })
    $fields.Add([PSCustomObject]@{ Key = 'Priority';    Label = 'Priority' })

    if ($Type -eq $script:AzDevOpsDraftStoryType) {
        $fields.Add([PSCustomObject]@{ Key = 'StoryPoints';        Label = 'Story Points' })
        $fields.Add([PSCustomObject]@{ Key = 'AcceptanceCriteria'; Label = 'Acceptance Criteria' })
    }

    if ((Get-AzDevOpsDraftParentType -Type $Type) -ne '') {
        $fields.Add([PSCustomObject]@{ Key = 'Parent'; Label = 'Parent' })
    }

    return $fields
}


function Test-AzDevOpsDraftFieldFilled {
    # True when the given expected-field key holds a usable value on the item.
    param(
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)] [string] $Key
    )

    switch ($Key) {
        'Priority' {
            $filled = Test-AzDevOpsDraftPriorityValid -Priority ([int]$Item.Priority)
            return $filled
        }

        'StoryPoints' {
            $filled = ([int]$Item.StoryPoints -ge 0)
            return $filled
        }

        'Parent' {
            $filled = ([int]$Item.ParentRef -gt 0 -or [int]$Item.ParentId -gt 0)
            return $filled
        }

        default {
            $value  = [string]$Item.$Key
            $filled = -not [string]::IsNullOrWhiteSpace($value)
            return $filled
        }
    }
}


function Get-AzDevOpsDraftCompleteness {
    # Percentage of a type's expected fields that are filled, plus the raw
    # counts. An item with no expected fields (never happens today) scores 100
    # so it can't drag the average into a divide-by-zero.
    param([Parameter(Mandatory)] $Item)

    $expected = Get-AzDevOpsDraftExpectedFields -Type ([string]$Item.Type)
    $total    = @($expected).Count

    if ($total -eq 0) {
        return [PSCustomObject]@{ Filled = 0; Total = 0; Percent = 100 }
    }

    $filled = 0
    foreach ($field in $expected) {
        if (Test-AzDevOpsDraftFieldFilled -Item $Item -Key $field.Key) {
            $filled++
        }
    }

    $percent = [int][math]::Round(($filled / $total) * 100)

    $result = [PSCustomObject]@{ Filled = $filled; Total = $total; Percent = $percent }
    return $result
}


function Get-AzDevOpsDraftMissingLabels {
    # Labels of the expected fields an item still has blank, for the "[missing:
    # ...]" hint in the tree. Empty array when the item is fully filled.
    param([Parameter(Mandatory)] $Item)

    $expected = Get-AzDevOpsDraftExpectedFields -Type ([string]$Item.Type)

    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($field in $expected) {
        if (-not (Test-AzDevOpsDraftFieldFilled -Item $Item -Key $field.Key)) {
            $missing.Add($field.Label)
        }
    }

    return $missing
}


# ---------------------------------------------------------------------------
# Interactive pickers (local only — no `az`)
# ---------------------------------------------------------------------------

function Read-AzDevOpsDraftTypePick {
    # Fixed four-tier type menu. Blank / 0 returns '' so the guided loop reads it
    # as "finish". Kept a Read-Host menu (not a grid) because the four choices
    # are static and ordering is meaningful.
    $tiers = Get-AzDevOpsDraftTierOrder

    Write-Host ""
    Write-Host "What do you want to add?" -ForegroundColor Cyan
    for ($i = 0; $i -lt $tiers.Count; $i++) {
        Write-Host ("  {0}. {1}" -f ($i + 1), $tiers[$i].Type)
    }
    Write-Host "  0. (finish)"

    $idx = 0
    while ($true) {
        $resp = Read-Host 'Type'
        if (-not $resp -or $resp -eq '0') {
            return ''
        }

        if ([int]::TryParse($resp, [ref]$idx) -and $idx -ge 1 -and $idx -le $tiers.Count) {
            $type = $tiers[$idx - 1].Type
            return $type
        }

        Write-Host "  Please enter 1..$($tiers.Count), or 0 to finish." -ForegroundColor Yellow
    }
}


function Get-AzDevOpsDraftParentCandidateRows {
    # Builds the candidate list for a child of tier $ChildType: matching draft
    # items (referenced by local Ref) followed by matching active items already
    # in the hierarchy cache (referenced by real Id). Each row carries a Source
    # so the caller can hand back the right link shape.
    param(
        [Parameter(Mandatory)] [string] $ChildType,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Draft,
        [AllowEmptyCollection()] [object[]] $Hierarchy = @()
    )

    $parentType = Get-AzDevOpsDraftParentType -Type $ChildType

    $rows = [System.Collections.Generic.List[object]]::new()
    if ($parentType -eq '') {
        return $rows
    }

    foreach ($item in $Draft) {
        if (Test-AzDevOpsDraftTypeMatchesTier -CandidateType ([string]$item.Type) -ParentType $parentType) {
            $title = Format-AzDevOpsTruncatedTitle -Title ([string]$item.Title)
            $rows.Add([PSCustomObject]@{
                Source = 'draft'
                Ref    = [int]$item.Ref
                Id     = 0
                Kind   = "draft #$([int]$item.Ref)"
                Type   = [string]$item.Type
                Title  = $title
            })
        }
    }

    $closedStates = Get-AzDevOpsClosedStates
    foreach ($row in $Hierarchy) {
        if ($row.State -in $closedStates) {
            continue
        }
        if (Test-AzDevOpsDraftTypeMatchesTier -CandidateType ([string]$row.Type) -ParentType $parentType) {
            $title = Format-AzDevOpsTruncatedTitle -Title ([string]$row.Title)
            $rows.Add([PSCustomObject]@{
                Source = 'existing'
                Ref    = 0
                Id     = [int]$row.Id
                Kind   = "azure #$([int]$row.Id)"
                Type   = [string]$row.Type
                Title  = $title
            })
        }
    }

    return $rows
}


function Get-AzDevOpsDraftHierarchy {
    # Read the hierarchy cache for parent candidates WITHOUT the two-line
    # "No hierarchy cache" hint the shared reader prints when the cache is
    # absent. The brain dump must stay quiet and works fine with zero existing
    # items, so a missing cache is a silent empty list, not a nag on every add.
    $paths = Get-AzDevOpsCachePaths

    if (-not $paths.Hierarchy -or -not (Test-Path -LiteralPath $paths.Hierarchy)) {
        return @()
    }

    $items = @(Read-AzDevOpsHierarchyCache | Where-Object { $null -ne $_ })
    return $items
}


function Read-AzDevOpsDraftParentPick {
    # Pick a parent for a child of tier $ChildType from draft items + existing
    # hierarchy items, or orphan. Returns { ParentRef; ParentId } with at most
    # one non-zero. Epics (no parent tier) return a zeroed result without
    # prompting. Grid TUI when available, Read-Host numbered menu otherwise.
    param(
        [Parameter(Mandatory)] [string] $ChildType,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Draft,
        [AllowEmptyCollection()] [object[]] $Hierarchy = @()
    )

    $orphanResult = [PSCustomObject]@{ ParentRef = 0; ParentId = 0 }

    $parentType = Get-AzDevOpsDraftParentType -Type $ChildType
    if ($parentType -eq '') {
        return $orphanResult
    }

    $rows = Get-AzDevOpsDraftParentCandidateRows -ChildType $ChildType -Draft $Draft -Hierarchy $Hierarchy
    if (@($rows).Count -eq 0) {
        Write-Host "  (no $parentType candidates yet - adding as orphan; set a parent later with az-Set-AzDevOpsDraftItem)" -ForegroundColor Yellow
        return $orphanResult
    }

    if (Test-AzDevOpsGridAvailable) {
        $picked = Read-AzDevOpsGridPick -Rows $rows -Title "Pick a parent $parentType for this $ChildType (Esc = orphan)"

        if ($null -eq $picked) {
            return $orphanResult
        }

        $result = [PSCustomObject]@{ ParentRef = [int]$picked.Ref; ParentId = [int]$picked.Id }
        return $result
    }

    Write-Host ""
    Write-Host "Pick a parent $parentType" -ForegroundColor Cyan
    Write-Host "  0. (no parent - orphan)"
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $row = $rows[$i]
        Write-Host ("  {0}. [{1}] {2} - {3}" -f ($i + 1), $row.Kind, $row.Type, $row.Title)
    }

    $idx = 0
    while ($true) {
        $resp = Read-Host "Parent (0 for orphan)"
        if (-not [int]::TryParse($resp, [ref]$idx)) {
            Write-Host "  Please enter a number." -ForegroundColor Yellow
            continue
        }

        if ($idx -eq 0) {
            return $orphanResult
        }

        if ($idx -ge 1 -and $idx -le $rows.Count) {
            $row = $rows[$idx - 1]
            $result = [PSCustomObject]@{ ParentRef = [int]$row.Ref; ParentId = [int]$row.Id }
            return $result
        }

        Write-Host "  Please enter 0..$($rows.Count)." -ForegroundColor Yellow
    }
}


function Read-AzDevOpsDraftDetails {
    # Capture the per-type detail fields using the SAME readers the single-shot
    # az-New-AzDevOps* creators use, so the drafted values match what a live
    # create would have produced. Returns a hashtable of the fields it captured
    # (only the keys relevant to the type), ready to splat onto a record.
    param([Parameter(Mandatory)] [string] $Type)

    $details = @{}

    $details.Description = switch ($Type) {
        $script:AzDevOpsDraftStoryType {
            Read-AzDevOpsUserStoryDescription
        }

        $script:AzDevOpsDraftFeatureType {
            Read-AzDevOpsFeatureDescription
        }

        default {
            Read-Host 'What is the description?'
        }
    }

    $details.Priority = Read-AzDevOpsPriority

    if ($Type -eq $script:AzDevOpsDraftStoryType) {
        $details.StoryPoints        = Read-AzDevOpsStoryPoints
        $details.AcceptanceCriteria = Read-AzDevOpsAcceptanceCriteria
    }

    return $details
}


# ---------------------------------------------------------------------------
# Tree rendering
# ---------------------------------------------------------------------------

function Get-AzDevOpsDraftCompletenessColor {
    param([Parameter(Mandatory)] [int] $Percent)

    $color = if ($Percent -ge 100) {
        'Green'
    } elseif ($Percent -ge 50) {
        'Cyan'
    } else {
        'Yellow'
    }

    return $color
}


function Show-AzDevOpsDraftTreeNode {
    # Recursively prints one node and its draft children. $ChildMap keys draft
    # Ref -> child records; roots are printed by the caller at depth 0.
    param(
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)] [hashtable] $ChildMap,
        [int] $Depth = 0
    )

    $indent = Get-AzDevOpsTreeIndent -Depth $Depth
    $icon   = Get-AzDevOpsTreeIcon -Type ([string]$Item.Type)
    $title  = Format-AzDevOpsTruncatedTitle -Title ([string]$Item.Title)

    $completeness = Get-AzDevOpsDraftCompleteness -Item $Item
    $color        = Get-AzDevOpsDraftCompletenessColor -Percent $completeness.Percent

    $existingNote = if ([int]$Item.ParentId -gt 0) {
        " (under azure #$([int]$Item.ParentId))"
    } else {
        ''
    }

    $line = "{0}{1} [#{2}] {3}{4}  - {5}% complete" -f `
        $indent, $icon, [int]$Item.Ref, $title, $existingNote, $completeness.Percent

    Write-Host $line -ForegroundColor $color

    $missing = Get-AzDevOpsDraftMissingLabels -Item $Item
    if (@($missing).Count -gt 0) {
        $missingIndent = Get-AzDevOpsTreeIndent -Depth ($Depth + 1)
        Write-Host ("{0}missing: {1}" -f $missingIndent, ($missing -join ', ')) -ForegroundColor DarkYellow
    }

    $itemRef = [int]$Item.Ref
    if ($ChildMap.ContainsKey($itemRef)) {
        foreach ($child in $ChildMap[$itemRef]) {
            Show-AzDevOpsDraftTreeNode -Item $child -ChildMap $ChildMap -Depth ($Depth + 1)
        }
    }
}


function Show-AzDevOpsDraftTree {
    # Renders the whole draft as an indented tree with per-item completeness and
    # a summary footer. Roots are items with no draft parent (top-tier items and
    # items attached under an existing Azure id).
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Draft)

    if (@($Draft).Count -eq 0) {
        Write-Host "(draft is empty)" -ForegroundColor Yellow
        return
    }

    $childMap = Get-AzDevOpsDraftChildMap -Draft $Draft
    $refSet   = Get-AzDevOpsDraftRefSet -Draft $Draft

    $roots = $Draft | Where-Object {
        [int]$_.ParentRef -le 0 -or -not $refSet.ContainsKey([int]$_.ParentRef)
    } | Sort-Object { [int]$_.Ref }

    foreach ($root in $roots) {
        Show-AzDevOpsDraftTreeNode -Item $root -ChildMap $childMap -Depth 0
    }

    $totalPercent = 0
    $fullyComplete = 0
    foreach ($item in $Draft) {
        $completeness = Get-AzDevOpsDraftCompleteness -Item $item
        $totalPercent += $completeness.Percent
        if ($completeness.Percent -ge 100) {
            $fullyComplete++
        }
    }

    $count       = @($Draft).Count
    $avgPercent  = [int][math]::Round($totalPercent / $count)

    Write-Host ""
    Write-Host ("Draft: {0} item(s), {1}% complete on average, {2} ready to publish." -f $count, $avgPercent, $fullyComplete) -ForegroundColor Cyan
}


# ---------------------------------------------------------------------------
# Publish plumbing
# ---------------------------------------------------------------------------

function ConvertTo-AzDevOpsDraftHashtable {
    # Normalize a draft item's ExtraFields (a hashtable in-session, a
    # PSCustomObject after a JSON round-trip) into a plain hashtable for
    # Invoke-AzDevOpsWorkItemCreate -ExtraFields. Null / empty yields @{}.
    param([object] $Value)

    if ($null -eq $Value) {
        return @{}
    }

    if ($Value -is [hashtable]) {
        return $Value
    }

    $table = @{}
    foreach ($prop in $Value.PSObject.Properties) {
        $table[$prop.Name] = $prop.Value
    }

    return $table
}


function Build-AzDevOpsDraftCreateArgs {
    # Turn a draft item + the resolved iteration/area into the splat
    # Invoke-AzDevOpsWorkItemCreate expects. Unset priority falls back to the
    # stock Medium default so the mandatory field is always valid; unset story
    # points stay -1 (the wrapper omits the field). Item-level iteration/area
    # win over the batch default when present.
    param(
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)] [string] $DefaultIteration,
        [Parameter(Mandatory)] [string] $DefaultArea
    )

    $priority = if (Test-AzDevOpsDraftPriorityValid -Priority ([int]$Item.Priority)) {
        [int]$Item.Priority
    } else {
        $script:AzDevOpsDraftDefaultPriority
    }

    $iteration = if (-not [string]::IsNullOrWhiteSpace([string]$Item.Iteration)) {
        [string]$Item.Iteration
    } else {
        $DefaultIteration
    }

    $area = if (-not [string]::IsNullOrWhiteSpace([string]$Item.Area)) {
        [string]$Item.Area
    } else {
        $DefaultArea
    }

    $tags = @($Item.Tags | Where-Object { $_ } | ForEach-Object { [string]$_ })

    $createArgs = @{
        Type        = [string]$Item.Type
        Title       = [string]$Item.Title
        Description = [string]$Item.Description
        Priority    = $priority
        StoryPoints = [int]$Item.StoryPoints
        Iteration   = $iteration
        Area        = $area
        Tags        = $tags
        ExtraFields = ConvertTo-AzDevOpsDraftHashtable -Value $Item.ExtraFields
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Item.AcceptanceCriteria)) {
        $createArgs.AcceptanceCriteria = [string]$Item.AcceptanceCriteria
    }

    return $createArgs
}


function Sort-AzDevOpsDraftForPublish {
    # Order the draft so every item is published after its draft parent. Items
    # with no draft parent (roots, or items attached to an existing Azure id)
    # come first; a child follows once its parent Ref has been emitted. A
    # dangling ParentRef (parent removed) is treated as a root. Returns the
    # ordered array; a genuine cycle (should be impossible via the pickers)
    # falls back to appending the stragglers so nothing is silently dropped.
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Draft)

    $refSet = Get-AzDevOpsDraftRefSet -Draft $Draft

    $ordered   = [System.Collections.Generic.List[object]]::new()
    $emitted   = @{}
    $remaining = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $Draft) {
        $remaining.Add($item)
    }

    while ($remaining.Count -gt 0) {
        $progressed = $false
        $still      = [System.Collections.Generic.List[object]]::new()

        foreach ($item in $remaining) {
            $parentRef = [int]$item.ParentRef

            $ready = ($parentRef -le 0) -or `
                     (-not $refSet.ContainsKey($parentRef)) -or `
                     ($emitted.ContainsKey($parentRef))

            if ($ready) {
                $ordered.Add($item)
                $emitted[[int]$item.Ref] = $true
                $progressed = $true
            } else {
                $still.Add($item)
            }
        }

        $remaining = $still

        if (-not $progressed) {
            foreach ($item in $remaining) {
                $ordered.Add($item)
            }
            break
        }
    }

    return $ordered
}


function Write-AzDevOpsDraftProgress {
    # One-line textual progress bar for the publish pass: [####------] 40% (4/10)
    # <label>. Emitted per item so the run reads as a log rather than an
    # in-place redraw (keeps it copy/paste-able and terminal-agnostic).
    param(
        [Parameter(Mandatory)] [int]    $Current,
        [Parameter(Mandatory)] [int]    $Total,
        [Parameter(Mandatory)] [string] $Label
    )

    $barWidth = 20

    $percent = if ($Total -gt 0) {
        [int][math]::Round(($Current / $Total) * 100)
    } else {
        100
    }

    $filledCells = if ($Total -gt 0) {
        [int][math]::Round(($Current / $Total) * $barWidth)
    } else {
        $barWidth
    }

    $emptyCells = $barWidth - $filledCells

    $bar = ('#' * $filledCells) + ('-' * $emptyCells)

    $line = "[{0}] {1,3}% ({2}/{3}) {4}" -f $bar, $percent, $Current, $Total, $Label
    Write-Host $line -ForegroundColor Cyan
}


# ---------------------------------------------------------------------------
# Public surface
# ---------------------------------------------------------------------------

function az-Add-AzDevOpsDraftItem {
    # Quick, params-driven add of one item to the local draft - NO `az` call.
    # Prompts only for what's missing to identify the item: Type (picker) and
    # Title. Everything else is optional; unset fields simply lower the item's
    # completeness score and can be filled later with az-Set-AzDevOpsDraftItem.
    #
    # Parent: pass -ParentRef (another draft item) or -ParentId (an existing
    # Azure work item). With neither, and without -Orphan, the parent picker
    # runs interactively (draft items + existing hierarchy). -Orphan forces a
    # top-level item with no prompt. Returns the new item's local [int] Ref.
    [CmdletBinding()]
    param(
        [ValidateSet('Epic', 'Feature', 'User Story', 'Task')]
        [string]   $Type,
        [string]   $Title,
        [string]   $Description = '',
        [int]      $Priority = -1,
        [int]      $StoryPoints = -1,
        [string]   $AcceptanceCriteria = '',
        [string[]] $Tags = @(),
        [string]   $Iteration = '',
        [string]   $Area = '',
        [int]      $ParentRef = 0,
        [int]      $ParentId = 0,
        [switch]   $Orphan
    )

    $draft = @(Read-AzDevOpsDraft)

    if (-not $Type) {
        $Type = Read-AzDevOpsDraftTypePick
    }
    if (-not $Type) {
        Write-Host "No type chosen - nothing added." -ForegroundColor Yellow
        return
    }

    if (-not $Title) {
        $Title = Read-AzDevOpsTitle -PromptText "Title of the $Type"
    }
    if (-not $Title) {
        Write-Host "Title is required - nothing added." -ForegroundColor Red
        return
    }

    if ($ParentRef -le 0 -and $ParentId -le 0 -and -not $Orphan) {
        $hierarchy = Get-AzDevOpsDraftHierarchy
        $pick = Read-AzDevOpsDraftParentPick -ChildType $Type -Draft $draft -Hierarchy $hierarchy
        $ParentRef = $pick.ParentRef
        $ParentId  = $pick.ParentId
    }

    $ref = Get-AzDevOpsNextDraftRef -Draft $draft

    $record = New-AzDevOpsDraftItemRecord `
        -Ref                $ref `
        -Type               $Type `
        -Title              $Title `
        -Description        $Description `
        -Priority           $Priority `
        -StoryPoints        $StoryPoints `
        -AcceptanceCriteria $AcceptanceCriteria `
        -Tags               $Tags `
        -Iteration          $Iteration `
        -Area               $Area `
        -ParentRef          $ParentRef `
        -ParentId           $ParentId

    $updated = @($draft) + $record
    if (-not (Save-AzDevOpsDraft -Items $updated)) {
        return
    }

    $completeness = Get-AzDevOpsDraftCompleteness -Item $record
    Write-Host ("Added [#{0}] {1}: {2} ({3}% complete)" -f $ref, $Type, $Title, $completeness.Percent) -ForegroundColor Green

    return $ref
}


function az-Set-AzDevOpsDraftItem {
    # Fill in or edit an existing draft item - the "add details later" half of
    # the brain-dump flow, still with NO `az` call. Any field passed as a param
    # is written directly; with -Details it re-runs the interactive per-type
    # readers (description / priority / points / acceptance criteria). -ParentRef
    # / -ParentId / -Orphan re-parent the item. Returns the item's [int] Ref.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $Ref,
        [string]   $Title,
        [string]   $Description,
        [int]      $Priority = -1,
        [int]      $StoryPoints = -1,
        [string]   $AcceptanceCriteria,
        [string[]] $Tags,
        [string]   $Iteration,
        [string]   $Area,
        [int]      $ParentRef = -1,
        [int]      $ParentId = -1,
        [switch]   $Orphan,
        [switch]   $Details
    )

    $draft = @(Read-AzDevOpsDraft)

    $item = Get-AzDevOpsDraftItemByRef -Draft $draft -Ref $Ref
    if ($null -eq $item) {
        Write-Host "No draft item with Ref #$Ref. Run az-Show-AzDevOpsDraft to list them." -ForegroundColor Red
        return
    }

    if ($PSBoundParameters.ContainsKey('Title') -and $Title) {
        $item.Title = $Title
    }

    if ($PSBoundParameters.ContainsKey('Description')) {
        $item.Description = $Description
    }

    if ($PSBoundParameters.ContainsKey('Priority') -and (Test-AzDevOpsDraftPriorityValid -Priority $Priority)) {
        $item.Priority = $Priority
    }

    if ($PSBoundParameters.ContainsKey('StoryPoints') -and $StoryPoints -ge 0) {
        $item.StoryPoints = $StoryPoints
    }

    if ($PSBoundParameters.ContainsKey('AcceptanceCriteria')) {
        $item.AcceptanceCriteria = $AcceptanceCriteria
    }

    if ($PSBoundParameters.ContainsKey('Tags')) {
        $item.Tags = $Tags
    }

    if ($PSBoundParameters.ContainsKey('Iteration')) {
        $item.Iteration = $Iteration
    }

    if ($PSBoundParameters.ContainsKey('Area')) {
        $item.Area = $Area
    }

    if ($Orphan) {
        $item.ParentRef = 0
        $item.ParentId  = 0
    } else {
        if ($ParentRef -ge 0 -and $PSBoundParameters.ContainsKey('ParentRef')) {
            $item.ParentRef = $ParentRef
            $item.ParentId  = 0
        }
        if ($ParentId -ge 0 -and $PSBoundParameters.ContainsKey('ParentId')) {
            $item.ParentId  = $ParentId
            $item.ParentRef = 0
        }
    }

    if ($Details) {
        $captured = Read-AzDevOpsDraftDetails -Type ([string]$item.Type)
        foreach ($key in $captured.Keys) {
            $item.$key = $captured[$key]
        }
    }

    if (-not (Save-AzDevOpsDraft -Items $draft)) {
        return
    }

    $completeness = Get-AzDevOpsDraftCompleteness -Item $item
    Write-Host ("Updated [#{0}] {1} ({2}% complete)" -f $Ref, [string]$item.Title, $completeness.Percent) -ForegroundColor Green

    return $Ref
}


function az-Remove-AzDevOpsDraftItem {
    # Remove one draft item. Its draft children are reparented to the removed
    # item's own parent (grandparent) so the sub-tree survives; pass -Recurse to
    # delete the whole sub-tree instead. NO `az` call - the draft is local.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $Ref,
        [switch] $Recurse
    )

    $draft = @(Read-AzDevOpsDraft)

    $item = Get-AzDevOpsDraftItemByRef -Draft $draft -Ref $Ref
    if ($null -eq $item) {
        Write-Host "No draft item with Ref #$Ref." -ForegroundColor Red
        return
    }

    $toRemove = [System.Collections.Generic.List[int]]::new()
    $toRemove.Add($Ref)

    if ($Recurse) {
        $childMap = Get-AzDevOpsDraftChildMap -Draft $draft

        $stack = [System.Collections.Generic.Stack[int]]::new()
        $stack.Push($Ref)
        while ($stack.Count -gt 0) {
            $current = $stack.Pop()

            if (-not $childMap.ContainsKey($current)) {
                continue
            }

            foreach ($child in $childMap[$current]) {
                $childRef = [int]$child.Ref
                $toRemove.Add($childRef)
                $stack.Push($childRef)
            }
        }
    } else {
        $grandParentRef = [int]$item.ParentRef
        $grandParentId  = [int]$item.ParentId
        foreach ($d in $draft) {
            if ([int]$d.ParentRef -eq $Ref) {
                $d.ParentRef = $grandParentRef
                $d.ParentId  = $grandParentId
            }
        }
    }

    $kept = @($draft | Where-Object { [int]$_.Ref -notin $toRemove })

    if (-not (Save-AzDevOpsDraft -Items $kept)) {
        return
    }

    $removedCount = $toRemove.Count
    Write-Host ("Removed {0} item(s) from the draft." -f $removedCount) -ForegroundColor Green
}


function az-Show-AzDevOpsDraft {
    # Render the local draft as a tree with per-item completeness and a summary.
    # Read-only, NO `az` call - safe to run any time during the brain dump.
    [CmdletBinding()]
    param()

    $draft = @(Read-AzDevOpsDraft)

    Write-Host ""
    Write-Host 'Local Azure DevOps draft (unpublished - no az calls yet)' -ForegroundColor Cyan

    Show-AzDevOpsDraftTree -Draft $draft

    if (@($draft).Count -gt 0) {
        Write-Host ""
        Write-Host "Publish with az-Publish-AzDevOpsDraft, or keep adding with az-Add-AzDevOpsDraftItem / az-New-AzDevOpsDraft." -ForegroundColor DarkGray
    }
}


function az-Clear-AzDevOpsDraft {
    # Discard the entire local draft. Prompts for confirmation unless -Force.
    [CmdletBinding()]
    param([switch] $Force)

    $draft = @(Read-AzDevOpsDraft)
    $count = @($draft).Count

    if ($count -eq 0) {
        Write-Host "Draft is already empty." -ForegroundColor Yellow
        return
    }

    if (-not $Force) {
        if (-not (Read-AzDevOpsYesNo -Prompt "Discard all $count draft item(s)? This cannot be undone." -DefaultNo)) {
            Write-Host "Kept the draft." -ForegroundColor Yellow
            return
        }
    }

    if (-not (Save-AzDevOpsDraft -Items @())) {
        return
    }

    Write-Host ("Cleared {0} draft item(s)." -f $count) -ForegroundColor Green
}


function az-New-AzDevOpsDraft {
    # Guided brain-dump loop: repeatedly add items (type -> title -> optional
    # details -> parent) with ZERO `az` calls, review the growing tree after
    # each, then optionally publish everything at the end. This is the low-
    # friction entry point - build the whole hierarchy, hand-wave the details you
    # don't have yet (completeness % shows what's missing), and only touch Azure
    # when you say so.
    [CmdletBinding()]
    param()

    Write-Host ""
    Write-Host "Azure DevOps brain dump - building a local draft (nothing hits Azure until you publish)." -ForegroundColor Cyan
    Write-Host "  Pick a type, give a title, optionally add details, choose a parent. Blank type finishes." -ForegroundColor DarkGray

    while ($true) {
        $draft = @(Read-AzDevOpsDraft)

        $type = Read-AzDevOpsDraftTypePick
        if (-not $type) {
            break
        }

        $title = Read-AzDevOpsTitle -PromptText "Title of the $type (blank to cancel this item)"
        if (-not $title) {
            continue
        }

        $details = @{}
        if (Read-AzDevOpsYesNo -Prompt 'Capture details now (description, priority, etc.)?' -DefaultNo) {
            $details = Read-AzDevOpsDraftDetails -Type $type
        }

        $hierarchy = Get-AzDevOpsDraftHierarchy
        $pick = Read-AzDevOpsDraftParentPick -ChildType $type -Draft $draft -Hierarchy $hierarchy

        $ref = Get-AzDevOpsNextDraftRef -Draft $draft

        $record = New-AzDevOpsDraftItemRecord `
            -Ref       $ref `
            -Type      $type `
            -Title     $title `
            -ParentRef $pick.ParentRef `
            -ParentId  $pick.ParentId

        foreach ($key in $details.Keys) {
            $record.$key = $details[$key]
        }

        $updated = @($draft) + $record
        if (-not (Save-AzDevOpsDraft -Items $updated)) {
            return
        }

        Write-Host ""
        Show-AzDevOpsDraftTree -Draft $updated
    }

    $finalDraft = @(Read-AzDevOpsDraft)
    if (@($finalDraft).Count -eq 0) {
        Write-Host ""
        Write-Host "Nothing drafted - exiting." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    if (Read-AzDevOpsYesNo -Prompt 'Publish this draft to Azure now?' -DefaultNo) {
        $ids = az-Publish-AzDevOpsDraft
        return $ids
    }

    Write-Host ""
    Write-Host "Draft saved. Review it with az-Show-AzDevOpsDraft; publish with az-Publish-AzDevOpsDraft when ready." -ForegroundColor Cyan
}


function az-Publish-AzDevOpsDraft {
    # Create every drafted item in Azure and wire the parent/child links in one
    # parents-first pass, reporting live progress. This is the ONLY draft command
    # that calls `az`. Iteration / Area are resolved once up front (picker / env
    # fallback) and applied to any item that didn't set its own.
    #
    # A create that fails is recorded and its descendants are skipped (their
    # parent never got an id); everything else still publishes. On a fully clean
    # run the draft is cleared. On a partial run the published items are removed
    # and the leftovers are kept - with any child of a now-published parent
    # rewritten to point at the real Azure id - so a re-run only creates what's
    # left. -KeepDraft leaves the draft untouched either way.
    [CmdletBinding()]
    param(
        [string] $Iteration,
        [string] $Area,
        [switch] $KeepDraft
    )

    if (-not (Test-AzDevOpsCreateGate -CommandName 'az-Publish-AzDevOpsDraft')) {
        return
    }

    $draft = @(Read-AzDevOpsDraft)
    if (@($draft).Count -eq 0) {
        Write-Host "Draft is empty - nothing to publish. Add items with az-New-AzDevOpsDraft or az-Add-AzDevOpsDraftItem." -ForegroundColor Yellow
        return
    }

    $resolved = Resolve-AzDevOpsIterationArea -Iteration $Iteration -Area $Area
    if (-not $resolved.Ok) {
        return
    }
    $defaultIteration = $resolved.Iteration
    $defaultArea      = $resolved.Area

    $refSet = Get-AzDevOpsDraftRefSet -Draft $draft

    $ordered = Sort-AzDevOpsDraftForPublish -Draft $draft
    $total   = @($ordered).Count

    Write-Host ""
    Write-Host ("Publishing {0} draft item(s) to Azure DevOps..." -f $total) -ForegroundColor Cyan
    Write-Host "  Area      : $defaultArea"
    Write-Host "  Iteration : $defaultIteration"

    $refToId    = @{}
    $failedRefs = @{}
    $created    = [System.Collections.Generic.List[object]]::new()
    $failed     = [System.Collections.Generic.List[object]]::new()

    $index = 0
    foreach ($item in $ordered) {
        $index++

        $itemRef   = [int]$item.Ref
        $itemTitle = Format-AzDevOpsTruncatedTitle -Title ([string]$item.Title)
        $label     = "$([string]$item.Type): $itemTitle"

        # Resolve the real parent id. An existing Azure parent is used verbatim;
        # a draft parent must have published already. A draft parent that failed
        # (or whose id never materialized) means this child can't be linked, so
        # it's skipped rather than orphaned silently.
        $parentId         = 0
        $parentUnresolved = $false

        if ([int]$item.ParentId -gt 0) {
            $parentId = [int]$item.ParentId
        }
        elseif ([int]$item.ParentRef -gt 0 -and $refSet.ContainsKey([int]$item.ParentRef)) {
            $parentRef = [int]$item.ParentRef
            if ($refToId.ContainsKey($parentRef)) {
                $parentId = $refToId[$parentRef]
            } else {
                $parentUnresolved = $true
            }
        }

        if ($parentUnresolved) {
            Write-AzDevOpsDraftProgress -Current $index -Total $total -Label "SKIP (parent failed) $label"
            $failedRefs[$itemRef] = $true
            $failed.Add([PSCustomObject]@{ Ref = $itemRef; Title = [string]$item.Title; Reason = 'parent create failed' })
            continue
        }

        Write-AzDevOpsDraftProgress -Current $index -Total $total -Label $label

        $createArgs = Build-AzDevOpsDraftCreateArgs -Item $item -DefaultIteration $defaultIteration -DefaultArea $defaultArea
        $createResult = Invoke-AzDevOpsWorkItemCreate @createArgs

        if (-not $createResult.Ok) {
            Write-Host "  X create failed: $($createResult.Error)" -ForegroundColor Red
            $failedRefs[$itemRef] = $true
            $failed.Add([PSCustomObject]@{ Ref = $itemRef; Title = [string]$item.Title; Reason = $createResult.Error })
            continue
        }

        $newId = [int]$createResult.Id
        $refToId[$itemRef] = $newId

        $linkedParentId = 0
        if ($parentId -gt 0) {
            $linkResult = Invoke-AzDevOpsParentLink -Id $newId -ParentId $parentId
            if ($linkResult.Ok) {
                $linkedParentId = $parentId
                Write-Host "  OK #$newId linked to parent #$parentId" -ForegroundColor Green
            } else {
                Write-Host "  ! #$newId created but link to #$parentId failed: $($linkResult.Error)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  OK #$newId created (no parent)" -ForegroundColor Green
        }

        Add-AzDevOpsHierarchyCacheItem `
            -Id        $newId `
            -Type      ([string]$item.Type) `
            -Title     ([string]$item.Title) `
            -Iteration $createArgs.Iteration `
            -AreaPath  $createArgs.Area `
            -ParentId  $linkedParentId

        $created.Add([PSCustomObject]@{ Ref = $itemRef; Id = $newId; Url = $createResult.Url })
    }

    Write-AzDevOpsDraftProgress -Current $total -Total $total -Label 'done'

    $createdCount = $created.Count
    $failedCount  = $failed.Count

    Write-Host ""
    if ($failedCount -eq 0) {
        Write-Host ("Published all {0} item(s)." -f $createdCount) -ForegroundColor Green
    } else {
        Write-Host ("Published {0}, failed/skipped {1}." -f $createdCount, $failedCount) -ForegroundColor Yellow
        foreach ($f in $failed) {
            Write-Host ("  X [#{0}] {1} - {2}" -f $f.Ref, $f.Title, $f.Reason) -ForegroundColor Yellow
        }
    }

    foreach ($c in $created) {
        if ($c.Url) {
            Write-Host "  $($c.Url)" -ForegroundColor Cyan
        }
    }

    Update-AzDevOpsDraftAfterPublish -Draft $draft -RefToId $refToId -KeepDraft:$KeepDraft

    [int[]] $createdIds = @($created | ForEach-Object { [int]$_.Id })
    return $createdIds
}


function Update-AzDevOpsDraftAfterPublish {
    # Reconcile the draft after a publish pass. -KeepDraft leaves it untouched.
    # Otherwise items that were successfully created are dropped; any surviving
    # item whose draft parent published is rewritten to point at the real Azure
    # id (ParentRef -> ParentId) so a re-run links it without recreating the
    # parent. A fully clean run leaves an empty draft.
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Draft,
        [Parameter(Mandatory)] [hashtable] $RefToId,
        [switch] $KeepDraft
    )

    if ($KeepDraft) {
        Write-Host ""
        Write-Host "Draft kept (-KeepDraft)." -ForegroundColor DarkGray
        return
    }

    $remaining = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $Draft) {
        if ($RefToId.ContainsKey([int]$item.Ref)) {
            continue
        }

        $parentRef = [int]$item.ParentRef
        if ($parentRef -gt 0 -and $RefToId.ContainsKey($parentRef)) {
            $item.ParentId  = [int]$RefToId[$parentRef]
            $item.ParentRef = 0
        }

        $remaining.Add($item)
    }

    Save-AzDevOpsDraft -Items $remaining | Out-Null

    if ($remaining.Count -eq 0) {
        Write-Host ""
        Write-Host "Draft cleared." -ForegroundColor DarkGray
    } else {
        Write-Host ""
        Write-Host ("{0} item(s) left in the draft (retry with az-Publish-AzDevOpsDraft)." -f $remaining.Count) -ForegroundColor DarkGray
    }
}
