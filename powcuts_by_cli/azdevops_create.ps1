# ============================================================================
# Azure DevOps — Work-item creators
# ============================================================================
# Public entry points: az-New-AzDevOpsUserStory, az-New-AzDevOpsFeature,
# az-New-AzDevOpsFeatureStories (batch). Each composes the prompt readers and
# pickers from azdevops_create_pickers.ps1, then calls
# `az boards work-item create` and links the chosen parent.
#
# Loaded by powcuts_home.ps1. See azdevops_auth.ps1 for the master docstring.

function Invoke-AzDevOpsWorkItemCreate {
    # Wraps `az boards work-item create --type <Type> ...` so the orchestrator
    # can react to a non-zero exit cleanly. Returns a result object with
    # Ok / Error / Id / Url so the caller can decide whether to attempt the
    # parent-link step and what URL to echo / open.
    #
    # -Type defaults to 'User Story' so existing az-New-AzDevOpsUserStory
    # callers stay binary-compatible. -StoryPoints accepts -1 ("omit field")
    # so Feature creates can skip the story-points field cleanly - Features
    # don't carry story points in the default Agile / Scrum templates.
    param(
        [Parameter(Mandatory)] [string] $Title,
        [string] $Description,
        [Parameter(Mandatory)] [int]    $Priority,
        [int]    $StoryPoints = -1,
        [string] $AcceptanceCriteria,
        [string] $Iteration,
        [string] $Area = $env:AZ_AREA,
        [string] $Type = 'User Story',
        [string[]]  $Tags,
        [hashtable] $ExtraFields
    )

    $fields = @(
        "Microsoft.VSTS.Common.Priority=$Priority"
    )

    # Tasks have no AcceptanceCriteria field in the stock templates, so only
    # send it when the caller actually supplied one.
    if ($AcceptanceCriteria) {
        $fields += "Microsoft.VSTS.Common.AcceptanceCriteria=$AcceptanceCriteria"
    }

    if ($StoryPoints -ge 0) {
        $fields += "Microsoft.VSTS.Scheduling.StoryPoints=$StoryPoints"
    }

    if ($Tags -and $Tags.Count -gt 0) {
        $tagList = ($Tags | Where-Object { $_ } | ForEach-Object { [string]$_ }) -join '; '
        if ($tagList) {
            $fields += "System.Tags=$tagList"
        }
    }

    if ($ExtraFields -and $ExtraFields.Count -gt 0) {
        foreach ($key in $ExtraFields.Keys) {
            $value = $ExtraFields[$key]
            if ($null -eq $value) {
                continue
            }
            $fields += "$key=$value"
        }
    }

    $result = New-AzDevOpsWorkItem `
        -Type        $Type `
        -Title       $Title `
        -Description $Description `
        -AssignedTo  $env:AZ_USER_EMAIL `
        -Area        $Area `
        -Iteration   $Iteration `
        -Fields      $fields

    if ($result.ExitCode -ne 0) {
        return [PSCustomObject]@{
            Ok    = $false
            Error = $result.Error
            Id    = 0
            Url   = $null
        }
    }

    try {
        $created = $result.Json | ConvertFrom-Json
    }
    catch {
        return [PSCustomObject]@{
            Ok    = $false
            Error = "parse failed: $($_.Exception.Message)"
            Id    = 0
            Url   = $null
        }
    }

    $newId = [int]$created.id

    $urlPrefix = Get-AzDevOpsWorkItemUrlPrefix
    $url = if ($urlPrefix) {
        "$urlPrefix$newId"
    } else {
        $null
    }

    return [PSCustomObject]@{
        Ok    = $true
        Error = $null
        Id    = $newId
        Url   = $url
    }
}


function Invoke-AzDevOpsParentLink {
    # `az boards work-item relation add --relation-type parent --id <new>
    # --target-id <feature>` wrapper. Failure here doesn't undo the create -
    # the orchestrator surfaces both the orphaned new-id and the az error so
    # the user can re-link manually.
    param(
        [Parameter(Mandatory)] [int] $Id,
        [Parameter(Mandatory)] [int] $ParentId
    )

    $result = Add-AzDevOpsWorkItemRelation -Id $Id -TargetId $ParentId -RelationType 'parent'

    if ($result.ExitCode -ne 0) {
        return [PSCustomObject]@{ Ok = $false; Error = $result.Error }
    }

    return [PSCustomObject]@{ Ok = $true; Error = $null }
}


function Test-AzDevOpsCreateGate {
    # Auth + AZ_USER_EMAIL gate shared by every az-New-AzDevOps* creator.
    # Prints the abort message and returns $false on miss so callers can
    # short-circuit with a single `if (-not (Test-AzDevOpsCreateGate ...))`.
    #
    # Passes -SkipLiveProbe so the gate never fires the live `az boards query`
    # @Me smoke test: for a create command the `az boards work-item create`
    # call that follows is the authoritative auth check, so an upfront probe is
    # a redundant az round-trip. A valid auth memo still short-circuits; a stale
    # memo only re-confirms the az CLI is on PATH.
    param([Parameter(Mandatory)] [string] $CommandName)

    if (-not (Assert-AzDevOpsAuthOrAbort -CommandName $CommandName -SkipLiveProbe)) {
        return $false
    }

    if (-not $env:AZ_USER_EMAIL) {
        Write-Host "$CommandName aborted - `$env:AZ_USER_EMAIL is not set in your `$profile." -ForegroundColor Red
        return $false
    }

    return $true
}


function Read-AzDevOpsRequiredFields {
    # Walks Resolve-AzDevOpsTypeRequiredFields output for the given type and
    # returns a hashtable of <RefName> = <value> ready to feed
    # Invoke-AzDevOpsWorkItemCreate -ExtraFields. Entries whose value is the
    # literal 'prompt' (case-insensitive) trigger a Read-Host; any other value
    # passes through unchanged. Empty input on a 'prompt' entry skips that field
    # rather than sending an empty string to `az boards work-item create`.
    param([Parameter(Mandatory)] [string] $Type)

    $result = @{}
    if (-not (Get-Command Resolve-AzDevOpsTypeRequiredFields -ErrorAction SilentlyContinue)) {
        return $result
    }

    $required = Resolve-AzDevOpsTypeRequiredFields -Type $Type
    if ($null -eq $required -or $required.Count -eq 0) {
        return $result
    }

    foreach ($refName in $required.Keys) {
        $value = $required[$refName]
        if ("$value".Trim().ToLower() -eq 'prompt') {
            $answer = Read-Host "Enter $refName"
            if ($answer) {
                $result[$refName] = $answer
            }
        }
        else {
            $result[$refName] = $value
        }
    }

    return $result
}


function Resolve-AzDevOpsTypePriorityOrPrompt {
    # Type override -> Read-AzDevOpsPriority fallback. Used by az-New-AzDevOps*
    # creators to skip the prompt when the active project pins a DefaultPriority.
    # -Previous flows the batch-loop "Enter to reuse" hint through when applicable.
    param(
        [Parameter(Mandatory)] [string] $Type,
        [int] $Previous = -1
    )

    if (Get-Command Resolve-AzDevOpsTypeDefaultPriority -ErrorAction SilentlyContinue) {
        $default = Resolve-AzDevOpsTypeDefaultPriority -Type $Type
        if ($null -ne $default) {
            return [int]$default
        }
    }

    $priority = Read-AzDevOpsPriority -Previous $Previous
    return $priority
}


function Resolve-AzDevOpsTypeStoryPointsOrPrompt {
    # Type override -> Read-AzDevOpsStoryPoints fallback. Same shape as
    # Resolve-AzDevOpsTypePriorityOrPrompt; only meaningful for USER_STORY in
    # default Agile / Scrum templates.
    param(
        [Parameter(Mandatory)] [string] $Type,
        [int] $Previous = -1
    )

    if (Get-Command Resolve-AzDevOpsTypeDefaultStoryPoints -ErrorAction SilentlyContinue) {
        $default = Resolve-AzDevOpsTypeDefaultStoryPoints -Type $Type
        if ($null -ne $default) {
            return [int]$default
        }
    }

    $storyPoints = Read-AzDevOpsStoryPoints -Previous $Previous
    return $storyPoints
}


function Resolve-AzDevOpsTypeTagsOrEmpty {
    # Thin wrapper that hides the Get-Command guard so creators stay readable.
    # Always returns a string[] (possibly empty).
    param([Parameter(Mandatory)] [string] $Type)

    if (-not (Get-Command Resolve-AzDevOpsTypeTags -ErrorAction SilentlyContinue)) {
        return @()
    }

    $tags = @(Resolve-AzDevOpsTypeTags -Type $Type)
    return $tags
}


function Resolve-AzDevOpsIterationArea {
    # Picker + env-var fallback shared by every az-New-AzDevOps* creator. For
    # each kind: if the caller already passed a value, keep it; otherwise consult
    # the per-type project-map override (Resolve-AzDevOpsType{Area,Iteration})
    # when -Type is set; finally fall back to Read-AzDevOpsKindPick. Missing-
    # after-pick prints the standard "Set `$env:AZ_* or run az-Sync-AzDevOpsCache"
    # abort. Returns a result object with .Ok / .Iteration / .Area so callers
    # can short-circuit with a single `if (-not $resolved.Ok) { return }`.
    param(
        [string] $Iteration,
        [string] $Area,
        [string] $Type
    )

    if (-not $Iteration -and $Type) {
        if (Get-Command Resolve-AzDevOpsTypeIteration -ErrorAction SilentlyContinue) {
            $Iteration = Resolve-AzDevOpsTypeIteration -Type $Type
        }
    }
    if (-not $Iteration) {
        $Iteration = Read-AzDevOpsKindPick -Kind 'Iteration'
    }
    if (-not $Iteration) {
        Write-Host "Iteration is required - aborting. Set `$env:AZ_ITERATION or run az-Sync-AzDevOpsCache." -ForegroundColor Red
        return [PSCustomObject]@{ Ok = $false; Iteration = $null; Area = $null }
    }

    if (-not $Area -and $Type) {
        if (Get-Command Resolve-AzDevOpsTypeArea -ErrorAction SilentlyContinue) {
            $Area = Resolve-AzDevOpsTypeArea -Type $Type
        }
    }
    if (-not $Area) {
        $Area = Read-AzDevOpsKindPick -Kind 'Area'
    }
    if (-not $Area) {
        Write-Host "Area is required - aborting. Set `$env:AZ_AREA or run az-Sync-AzDevOpsCache." -ForegroundColor Red
        return [PSCustomObject]@{ Ok = $false; Iteration = $null; Area = $null }
    }

    $resolved = [PSCustomObject]@{ Ok = $true; Iteration = $Iteration; Area = $Area }
    return $resolved
}


function Add-AzDevOpsHierarchyCacheItem {
    # Append a freshly-created work item to the local hierarchy.json cache so
    # follow-on commands in the same session (Test-AzDevOpsParentIsFeature, the
    # Epic / Feature / Story parent pickers, az-Show-Tree) can see it without
    # waiting for the next az-Sync-AzDevOpsCache. The row is written in the same
    # raw `az boards query` shape the sync emits - a top-level `id` plus a
    # `fields` object - so ConvertFrom-AzDevOpsHierarchyItem reads it back
    # unchanged.
    #
    # Best-effort by design: a missing / empty / unparseable cache, or any write
    # failure, is swallowed (logged when the sync logger is loaded) so it never
    # aborts the create that just succeeded. The next full sync overwrites
    # hierarchy.json wholesale, so a transient skip here self-heals. Re-adding an
    # id that is already present is a no-op.
    #
    # State defaults to 'New' (the stock initial state across Agile / Scrum /
    # CMMI); Basic projects open as 'To Do' but no cache consumer nests on state,
    # so the next sync reconciles it harmlessly. ParentId of 0 writes a null
    # System.Parent - the parentless shape the sync emits for top-level Epics.
    param(
        [Parameter(Mandatory)] [int]    $Id,
        [Parameter(Mandatory)] [string] $Type,
        [Parameter(Mandatory)] [string] $Title,
        [string] $State = 'New',
        [string] $Iteration,
        [string] $AreaPath,
        [int]    $ParentId = 0
    )

    try {
        $paths = Get-AzDevOpsCachePaths
        $path  = $paths.Hierarchy

        $existing = @()
        if (Test-Path -LiteralPath $path) {
            $raw = Get-Content -LiteralPath $path -Raw
            if ($raw -and $raw.Trim()) {
                $parsed = $raw | ConvertFrom-Json
                if ($null -ne $parsed) {
                    $existing = @($parsed)
                }
            }
        }

        foreach ($row in $existing) {
            if ([int]$row.id -eq $Id) {
                return
            }
        }

        $parentValue = if ($ParentId -gt 0) {
            $ParentId
        } else {
            $null
        }

        $fields = [ordered]@{
            'System.Id'            = $Id
            'System.WorkItemType'  = $Type
            'System.State'         = $State
            'System.Title'         = $Title
            'System.IterationPath' = $Iteration
            'System.AreaPath'      = $AreaPath
            'System.Parent'        = $parentValue
        }

        $newRow = [PSCustomObject]@{
            id     = $Id
            fields = [PSCustomObject]$fields
        }

        $updated = @($existing) + $newRow

        # Match the hierarchy dataset's on-disk depth. Its descriptor in
        # Get-AzDevOpsSyncDatasets sets no JsonDepth, so the sync writes it at
        # Invoke-AzDevOpsAzDataset's default of 10; an appended row therefore
        # serializes identically to a synced one. The flat id+fields shape needs
        # far less, but aligning the value keeps the two writers from drifting.
        $hierarchyJsonDepth = 10
        $json = ConvertTo-Json -InputObject @($updated) -Depth $hierarchyJsonDepth -AsArray

        if (Get-Command New-AzDevOpsDirectoryIfMissing -ErrorAction SilentlyContinue) {
            New-AzDevOpsDirectoryIfMissing -Path $paths.Dir
        }

        Write-AzDevOpsCacheFile -Path $path -Content $json
    }
    catch {
        if (Get-Command Write-AzDevOpsSyncLog -ErrorAction SilentlyContinue) {
            Write-AzDevOpsSyncLog "hierarchy cache append skipped for $Id : $($_.Exception.Message)"
        }
    }
}


function Invoke-AzDevOpsCreateAndLink {
    # Wraps the create -> parent-link -> echo URL tail shared by every
    # az-New-AzDevOps* creator: az-New-AzDevOpsUserStory, az-New-AzDevOpsFeature,
    # and the per-iteration body of az-New-AzDevOpsFeatureStories. Returns a
    # result object with .Ok / .Id / .Url so the caller can short-circuit on
    # failure or hand the new id to a follow-up step (browser launch, hand-off
    # prompt, append to a batch summary).
    #
    # ChildLabel / ParentLabel feed the user-facing status lines ("Creating
    # User Story...", "Linking story 5001 to parent Feature 1240..."), so the
    # existing UX is preserved verbatim - the helper only consolidates the
    # control flow.
    #
    # On success the new item is appended to hierarchy.json via
    # Add-AzDevOpsHierarchyCacheItem so a chained child create (e.g. the Feature
    # -> "Add child stories now?" hand-off, or a standalone
    # az-New-AzDevOpsUserStory -FeatureId <newId>) finds the parent in the cache
    # instead of failing the hierarchy lookup. The recorded System.Parent
    # reflects the actual server link: the parent id only when the link
    # succeeded, null otherwise.
    param(
        [Parameter(Mandatory)] [string]    $ChildLabel,
        [Parameter(Mandatory)] [string]    $ParentLabel,
        [Parameter(Mandatory)] [hashtable] $CreateArgs,
        [int]    $ParentId = 0,
        [string] $OrphanLabel,
        [switch] $OpenInBrowser
    )

    if (-not $OrphanLabel) {
        $OrphanLabel = $ChildLabel
    }

    Write-Host ""
    Write-Host "Creating $ChildLabel..." -ForegroundColor Cyan
    $createResult = Invoke-AzDevOpsWorkItemCreate @CreateArgs

    if (-not $createResult.Ok) {
        Write-Host "STEP FAILED: az boards work-item create" -ForegroundColor Red
        Write-Host "  $($createResult.Error)" -ForegroundColor Red
        return [PSCustomObject]@{ Ok = $false; Id = 0; Url = $null }
    }

    $newId = $createResult.Id
    $newUrl = $createResult.Url
    Write-Host "OK Created $ChildLabel $newId" -ForegroundColor Green

    $linkedParentId = 0
    if ($ParentId -gt 0) {
        Write-Host "Linking $OrphanLabel $newId to parent $ParentLabel $ParentId..." -ForegroundColor Cyan
        $linkResult = Invoke-AzDevOpsParentLink -Id $newId -ParentId $ParentId
        if (-not $linkResult.Ok) {
            Write-Host "STEP FAILED: az boards work-item relation add ($OrphanLabel $newId is orphaned, fix manually)" -ForegroundColor Red
            Write-Host "  $($linkResult.Error)" -ForegroundColor Red
        }
        else {
            Write-Host "OK Linked $newId -> $ParentLabel $ParentId" -ForegroundColor Green
            $linkedParentId = $ParentId
        }
    }
    else {
        Write-Host "(no parent linked - orphan $OrphanLabel)" -ForegroundColor Yellow
    }

    $createdType = if ($CreateArgs.ContainsKey('Type')) {
        [string]$CreateArgs.Type
    } else {
        'User Story'
    }

    Add-AzDevOpsHierarchyCacheItem `
        -Id        $newId `
        -Type      $createdType `
        -Title     ([string]$CreateArgs.Title) `
        -Iteration ([string]$CreateArgs.Iteration) `
        -AreaPath  ([string]$CreateArgs.Area) `
        -ParentId  $linkedParentId

    if ($newUrl) {
        Write-Host "URL: $newUrl" -ForegroundColor Cyan
        if ($OpenInBrowser) {
            Start-Process $newUrl
        }
    }

    $outcome = [PSCustomObject]@{ Ok = $true; Id = $newId; Url = $newUrl }
    return $outcome
}


function Resolve-AzDevOpsOrphanParent {
    # Shared orphan -> create-parent branch for az-New-AzDevOpsUserStory and
    # az-New-AzDevOpsFeature. Call this only when the interactive parent picker
    # returned 0 (orphan). It offers to create the missing parent inline; on
    # yes it runs the supplied -CreateParent creator and returns the new parent
    # id, on no/Enter it returns 0 so the child stays an orphan exactly as
    # before. A creator that fails or returns no id also falls back to 0 with a
    # clear yellow note - the caller then takes its normal orphan path, with no
    # link attempt against a bogus id.
    #
    # -CreateParent is a scriptblock (not a function name) so the full
    # interactive creator runs verbatim - the spawned Feature runs its own Epic
    # picker, the spawned Epic runs its own prompts. The recursion terminates
    # naturally at az-New-AzDevOpsEpic, which has no parent.
    param(
        [Parameter(Mandatory)] [string]      $ParentLabel,
        [Parameter(Mandatory)] [scriptblock] $CreateParent
    )

    Write-Host ""
    if (-not (Read-AzDevOpsYesNo -Prompt "Create a new parent $ParentLabel now?" -DefaultNo)) {
        return 0
    }

    $created = & $CreateParent
    $candidate = $created | Select-Object -Last 1

    $parentId = 0
    if ($null -ne $candidate) {
        [int]::TryParse("$candidate", [ref]$parentId) | Out-Null
    }

    if ($parentId -le 0) {
        Write-Host "No parent $ParentLabel was created - continuing with an orphan." -ForegroundColor Yellow
        return 0
    }

    return $parentId
}


function az-New-AzDevOpsUserStory {
    [CmdletBinding()]
    param(
        [string] $Title,
        [string] $Description,
        [int]    $Priority = -1,
        [int]    $StoryPoints = -1,
        [string] $AcceptanceCriteria,
        [int]    $FeatureId = -1,
        [string] $Iteration,
        [string] $Area,
        [switch] $NoOpen
    )

    if (-not (Test-AzDevOpsCreateGate -CommandName 'az-New-AzDevOpsUserStory')) {
        return
    }

    $hierarchy = Read-AzDevOpsHierarchyCache
    if ($null -eq $hierarchy) {
        return
    }

    if (-not $Title) {
        $Title = Read-Host 'What is the title of the User Story?'
    }
    if (-not $Title) {
        Write-Host "Title is required - aborting." -ForegroundColor Red
        return
    }

    if (-not $PSBoundParameters.ContainsKey('Description')) {
        $Description = Read-AzDevOpsUserStoryDescription
    }

    if ($Priority -lt 1 -or $Priority -gt 4) {
        $Priority = Resolve-AzDevOpsTypePriorityOrPrompt -Type 'USER_STORY'
    }

    if ($StoryPoints -lt 0) {
        $StoryPoints = Resolve-AzDevOpsTypeStoryPointsOrPrompt -Type 'USER_STORY'
    }

    if (-not $PSBoundParameters.ContainsKey('AcceptanceCriteria')) {
        $AcceptanceCriteria = Read-AzDevOpsAcceptanceCriteria
    }

    if ($FeatureId -lt 0) {
        $FeatureId = Read-AzDevOpsFeaturePick -Hierarchy $hierarchy -ChildType 'USER_STORY'

        if ($FeatureId -eq 0) {
            $FeatureId = Resolve-AzDevOpsOrphanParent -ParentLabel 'Feature' -CreateParent {
                az-New-AzDevOpsFeature -NoChildStoriesPrompt -NoOpen
            }
        }
    }

    $resolved = Resolve-AzDevOpsIterationArea -Iteration $Iteration -Area $Area -Type 'USER_STORY'
    if (-not $resolved.Ok) {
        return
    }
    $Iteration = $resolved.Iteration
    $Area = $resolved.Area

    $tags = Resolve-AzDevOpsTypeTagsOrEmpty   -Type 'USER_STORY'
    $extraFields = Read-AzDevOpsRequiredFields       -Type 'USER_STORY'

    $createArgs = @{
        Title              = $Title
        Description        = $Description
        Priority           = $Priority
        StoryPoints        = $StoryPoints
        AcceptanceCriteria = $AcceptanceCriteria
        Iteration          = $Iteration
        Area               = $Area
        Tags               = $tags
        ExtraFields        = $extraFields
    }

    $outcome = Invoke-AzDevOpsCreateAndLink `
        -ChildLabel    'User Story' `
        -ParentLabel   'Feature' `
        -OrphanLabel   'story' `
        -CreateArgs    $createArgs `
        -ParentId      $FeatureId `
        -OpenInBrowser:(-not $NoOpen)

    if (-not $outcome.Ok) {
        return
    }

    $newId = $outcome.Id
    return $newId
}


function az-New-Task {
    # Interactive Task creator - one tier below az-New-AzDevOpsUserStory. Picks
    # a parent User Story from the cached hierarchy, fills title / description /
    # priority / area / iteration, creates the Task, and links it to the Story.
    # Tasks carry neither story points nor acceptance criteria in the stock
    # Agile / Scrum templates, so those prompts are skipped.
    #
    # -ParentStoryId pre-fills the parent (used by the az-Show-* post-selection
    # "create child" action) so the picker is skipped. Returns the new Task's
    # [int] id.
    [CmdletBinding()]
    param(
        [string] $Title,
        [string] $Description,
        [int]    $Priority = -1,
        [int]    $ParentStoryId = -1,
        [string] $Iteration,
        [string] $Area,
        [switch] $NoOpen
    )

    if (-not (Test-AzDevOpsCreateGate -CommandName 'az-New-Task')) {
        return
    }

    $hierarchy = Read-AzDevOpsHierarchyCache
    if ($null -eq $hierarchy) {
        return
    }

    if (-not $Title) {
        $Title = Read-Host 'What is the title of the Task?'
    }
    if (-not $Title) {
        Write-Host "Title is required - aborting." -ForegroundColor Red
        return
    }

    if (-not $PSBoundParameters.ContainsKey('Description')) {
        $Description = Read-Host 'What is the description?'
    }

    if ($Priority -lt 1 -or $Priority -gt 4) {
        $Priority = Resolve-AzDevOpsTypePriorityOrPrompt -Type 'TASK'
    }

    if ($ParentStoryId -lt 0) {
        $ParentStoryId = Read-AzDevOpsStoryPick -Hierarchy $hierarchy -ChildType 'TASK'
    }

    $resolved = Resolve-AzDevOpsIterationArea -Iteration $Iteration -Area $Area -Type 'TASK'
    if (-not $resolved.Ok) {
        return
    }
    $Iteration = $resolved.Iteration
    $Area = $resolved.Area

    $tags = Resolve-AzDevOpsTypeTagsOrEmpty -Type 'TASK'
    $extraFields = Read-AzDevOpsRequiredFields     -Type 'TASK'

    $createArgs = @{
        Type        = 'Task'
        Title       = $Title
        Description = $Description
        Priority    = $Priority
        Iteration   = $Iteration
        Area        = $Area
        Tags        = $tags
        ExtraFields = $extraFields
    }

    $outcome = Invoke-AzDevOpsCreateAndLink `
        -ChildLabel    'Task' `
        -ParentLabel   'User Story' `
        -OrphanLabel   'task' `
        -CreateArgs    $createArgs `
        -ParentId      $ParentStoryId `
        -OpenInBrowser:(-not $NoOpen)

    if (-not $outcome.Ok) {
        return
    }

    $newId = $outcome.Id
    return $newId
}


function az-New-AzDevOpsFeature {
    # Interactive Feature creator. Mirrors az-New-AzDevOpsUserStory's UX one
    # tier up the tree: pick a parent Epic from the cached hierarchy, fill
    # title / description / priority / area / iteration / acceptance criteria,
    # create the Feature, link it to the Epic. Story points are intentionally
    # skipped - Features don't carry story points in the default Agile / Scrum
    # templates.
    #
    # Ends with an "Add child stories now?" hand-off via Read-AzDevOpsYesNo;
    # on yes calls az-New-AzDevOpsFeatureStories -ParentId $newFeatureId with
    # the same area / iteration pre-seeded so the user doesn't re-pick them.
    #
    # Returns the new Feature's [int] id.
    [CmdletBinding()]
    param(
        [string] $Title,
        [string] $Description,
        [int]    $Priority = -1,
        [string] $AcceptanceCriteria,
        [int]    $ParentEpicId = -1,
        [string] $Iteration,
        [string] $Area,
        [switch] $NoOpen,
        [switch] $NoChildStoriesPrompt
    )

    if (-not (Test-AzDevOpsCreateGate -CommandName 'az-New-AzDevOpsFeature')) {
        return
    }

    $hierarchy = Read-AzDevOpsHierarchyCache
    if ($null -eq $hierarchy) {
        return
    }

    if (-not $Title) {
        $Title = Read-Host 'What is the title of the Feature?'
    }
    if (-not $Title) {
        Write-Host "Title is required - aborting." -ForegroundColor Red
        return
    }

    if (-not $PSBoundParameters.ContainsKey('Description')) {
        $Description = Read-Host 'What is the description?'
    }

    if ($Priority -lt 1 -or $Priority -gt 4) {
        $Priority = Resolve-AzDevOpsTypePriorityOrPrompt -Type 'FEATURE'
    }

    if (-not $PSBoundParameters.ContainsKey('AcceptanceCriteria')) {
        $AcceptanceCriteria = Read-AzDevOpsAcceptanceCriteria
    }

    if ($ParentEpicId -lt 0) {
        $ParentEpicId = Read-AzDevOpsEpicPick -Hierarchy $hierarchy -ChildType 'FEATURE'

        if ($ParentEpicId -eq 0) {
            $ParentEpicId = Resolve-AzDevOpsOrphanParent -ParentLabel 'Epic' -CreateParent {
                az-New-AzDevOpsEpic -NoOpen
            }
        }
    }

    $resolved = Resolve-AzDevOpsIterationArea -Iteration $Iteration -Area $Area -Type 'FEATURE'
    if (-not $resolved.Ok) {
        return
    }
    $Iteration = $resolved.Iteration
    $Area = $resolved.Area

    $tags = Resolve-AzDevOpsTypeTagsOrEmpty -Type 'FEATURE'
    $extraFields = Read-AzDevOpsRequiredFields     -Type 'FEATURE'

    $createArgs = @{
        Type               = 'Feature'
        Title              = $Title
        Description        = $Description
        Priority           = $Priority
        AcceptanceCriteria = $AcceptanceCriteria
        Iteration          = $Iteration
        Area               = $Area
        Tags               = $tags
        ExtraFields        = $extraFields
    }

    $outcome = Invoke-AzDevOpsCreateAndLink `
        -ChildLabel    'Feature' `
        -ParentLabel   'Epic' `
        -CreateArgs    $createArgs `
        -ParentId      $ParentEpicId `
        -OpenInBrowser:(-not $NoOpen)

    if (-not $outcome.Ok) {
        return
    }

    $newId = $outcome.Id

    if (-not $NoChildStoriesPrompt) {
        Write-Host ""
        if (Read-AzDevOpsYesNo -Prompt 'Add child stories now?') {
            az-New-AzDevOpsFeatureStories `
                -ParentId  $newId `
                -Iteration $Iteration `
                -Area      $Area | Out-Null
        }
    }

    return $newId
}


function az-New-AzDevOpsEpic {
    # Interactive Epic creator - the top tier of the Epic -> Feature -> Story
    # hierarchy, so there's no parent picker (Epics are root items). Mirrors
    # az-New-AzDevOpsFeature's UX otherwise: title / description / priority /
    # acceptance criteria / iteration / area / tags / required fields. Story
    # points and the child-stories hand-off are intentionally skipped - those
    # belong to the lower tiers.
    #
    # Used both stand-alone and as the chained parent target when
    # az-New-AzDevOpsFeature's orphan path offers to create a new Epic inline.
    # Returns the new Epic's [int] id.
    [CmdletBinding()]
    param(
        [string] $Title,
        [string] $Description,
        [int]    $Priority = -1,
        [string] $AcceptanceCriteria,
        [string] $Iteration,
        [string] $Area,
        [switch] $NoOpen
    )

    if (-not (Test-AzDevOpsCreateGate -CommandName 'az-New-AzDevOpsEpic')) {
        return
    }

    if (-not $Title) {
        $Title = Read-Host 'What is the title of the Epic?'
    }
    if (-not $Title) {
        Write-Host "Title is required - aborting." -ForegroundColor Red
        return
    }

    if (-not $PSBoundParameters.ContainsKey('Description')) {
        $Description = Read-Host 'What is the description?'
    }

    if ($Priority -lt 1 -or $Priority -gt 4) {
        $Priority = Resolve-AzDevOpsTypePriorityOrPrompt -Type 'EPIC'
    }

    if (-not $PSBoundParameters.ContainsKey('AcceptanceCriteria')) {
        $AcceptanceCriteria = Read-AzDevOpsAcceptanceCriteria
    }

    $resolved = Resolve-AzDevOpsIterationArea -Iteration $Iteration -Area $Area -Type 'EPIC'
    if (-not $resolved.Ok) {
        return
    }
    $Iteration = $resolved.Iteration
    $Area = $resolved.Area

    $tags = Resolve-AzDevOpsTypeTagsOrEmpty -Type 'EPIC'
    $extraFields = Read-AzDevOpsRequiredFields     -Type 'EPIC'

    $createArgs = @{
        Type               = 'Epic'
        Title              = $Title
        Description        = $Description
        Priority           = $Priority
        AcceptanceCriteria = $AcceptanceCriteria
        Iteration          = $Iteration
        Area               = $Area
        Tags               = $tags
        ExtraFields        = $extraFields
    }

    $outcome = Invoke-AzDevOpsCreateAndLink `
        -ChildLabel    'Epic' `
        -ParentLabel   'Epic' `
        -OrphanLabel   'Epic (top-level - no parent)' `
        -CreateArgs    $createArgs `
        -ParentId      0 `
        -OpenInBrowser:(-not $NoOpen)

    if (-not $outcome.Ok) {
        return
    }

    $newId = $outcome.Id
    return $newId
}


function Read-AzDevOpsBatchContinue {
    # Three-way batch-loop prompt used by az-New-AzDevOpsFeatureStories at the
    # end of each story. Mirrors Read-AzDevOpsYesNo's style but adds a third
    # 'c' option that flags "re-pick area / iteration before the next story".
    # Returns 'continue' / 'stop' / 'change'.
    $resp = Read-Host '    Add another story? (y/N/c=change area or iteration)'

    if ($resp -match '^(y|yes)$') {
        return 'continue'
    }

    if ($resp -match '^(c|change)$') {
        return 'change'
    }

    return 'stop'
}


function Test-AzDevOpsParentIsFeature {
    # Validates -ParentId resolves to a Feature row in the cached hierarchy
    # before az-New-AzDevOpsFeatureStories enters the loop. Emits a clear
    # Write-Host on either failure mode (id missing entirely, or id present
    # but not a Feature) so the caller can abort with the right hint.
    param(
        [Parameter(Mandatory)] [int] $ParentId,
        [Parameter(Mandatory)] $Hierarchy
    )

    $candidates = @($Hierarchy | Where-Object { $_.Id -eq $ParentId })

    if ($candidates.Count -eq 0) {
        Write-Host "ParentId $ParentId not found in hierarchy.json. Run az-Sync-AzDevOpsCache and retry." -ForegroundColor Red
        return $false
    }

    $found = $candidates[0]
    if ($found.Type -ne 'Feature') {
        Write-Host "ParentId $ParentId is a $($found.Type), not a Feature. Pick a Feature parent." -ForegroundColor Red
        return $false
    }

    return $true
}


function az-New-AzDevOpsFeatureStories {
    # Batch-create child User Stories under an existing Feature. Captures
    # parent / area / iteration ONCE up front; loops per-story prompts for
    # title, AC, priority (Enter to reuse last), story points (same). At the
    # end of each story prompts "Add another story? (y/N/c)" - 'c' re-picks
    # area / iteration without exiting the loop. Empty title at the top of
    # any iteration aborts the batch cleanly.
    #
    # Each child create runs through the same Invoke-AzDevOpsWorkItemCreate
    # + Invoke-AzDevOpsParentLink path the single-shot az-New-AzDevOpsUserStory
    # uses, so failure modes / exit codes / schema enforcement stay identical.
    # A failed create is logged and the loop continues; the user can retry the
    # one that failed via az-New-AzDevOpsUserStory -ParentId $ParentId.
    #
    # Designed to be invoked stand-alone, or chained off the end of
    # az-New-AzDevOpsFeature via its "Add child stories now?" hand-off prompt.
    # Returns [int[]] of successfully-created story ids.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]    $ParentId,
        [string] $Iteration,
        [string] $Area
    )

    [int[]] $createdIds = @()

    if (-not (Test-AzDevOpsCreateGate -CommandName 'az-New-AzDevOpsFeatureStories')) {
        return $createdIds
    }

    $hierarchy = Read-AzDevOpsHierarchyCache
    if ($null -eq $hierarchy) {
        return $createdIds
    }

    if (-not (Test-AzDevOpsParentIsFeature -ParentId $ParentId -Hierarchy $hierarchy)) {
        return $createdIds
    }

    $resolved = Resolve-AzDevOpsIterationArea -Iteration $Iteration -Area $Area -Type 'USER_STORY'
    if (-not $resolved.Ok) {
        return $createdIds
    }
    $Iteration = $resolved.Iteration
    $Area = $resolved.Area

    $tags = Resolve-AzDevOpsTypeTagsOrEmpty -Type 'USER_STORY'

    Write-Host ""
    Write-Host "Batch-creating child User Stories under Feature $ParentId" -ForegroundColor Cyan
    Write-Host "  Area      : $Area"
    Write-Host "  Iteration : $Iteration"
    Write-Host "  (empty title at the next prompt ends the batch cleanly)"

    $failedTitles = @()
    $createdUrls = @()
    $previousPriority = -1
    $previousStoryPoints = -1
    $iterationNumber = 1

    while ($true) {
        Write-Host ""
        Write-Host ("--- Story #{0} ---" -f $iterationNumber) -ForegroundColor Cyan

        $title = Read-Host 'Story title (Enter to finish batch)'
        if (-not $title) {
            break
        }

        $acceptanceCriteria = Read-AzDevOpsAcceptanceCriteria
        $priority = Resolve-AzDevOpsTypePriorityOrPrompt    -Type 'USER_STORY' -Previous $previousPriority
        $storyPoints = Resolve-AzDevOpsTypeStoryPointsOrPrompt -Type 'USER_STORY' -Previous $previousStoryPoints
        $extraFields = Read-AzDevOpsRequiredFields             -Type 'USER_STORY'

        $createArgs = @{
            Title              = $title
            Description        = ''
            Priority           = $priority
            StoryPoints        = $storyPoints
            AcceptanceCriteria = $acceptanceCriteria
            Iteration          = $Iteration
            Area               = $Area
            Tags               = $tags
            ExtraFields        = $extraFields
        }

        $outcome = Invoke-AzDevOpsCreateAndLink `
            -ChildLabel  'User Story' `
            -ParentLabel 'Feature' `
            -OrphanLabel 'story' `
            -CreateArgs  $createArgs `
            -ParentId    $ParentId

        if (-not $outcome.Ok) {
            $failedTitles += $title
        }
        else {
            if ($outcome.Url) {
                $createdUrls += $outcome.Url
            }
            $createdIds += $outcome.Id
            $previousPriority = $priority
            $previousStoryPoints = $storyPoints
        }

        $iterationNumber++

        $next = Read-AzDevOpsBatchContinue
        if ($next -eq 'stop') {
            break
        }

        if ($next -eq 'change') {
            $newIteration = Read-AzDevOpsKindPick -Kind 'Iteration'
            if ($newIteration) {
                $Iteration = $newIteration
            }

            $newArea = Read-AzDevOpsKindPick -Kind 'Area'
            if ($newArea) {
                $Area = $newArea
            }

            Write-Host "  Area      : $Area"
            Write-Host "  Iteration : $Iteration"
        }
    }

    Write-Host ""
    $createdCount = $createdIds.Count
    $failedCount = $failedTitles.Count
    $idsList = if ($createdCount -gt 0) {
        ($createdIds -join ', ')
    }
    else {
        '(none)'
    }

    if ($failedCount -gt 0) {
        Write-Host ("Created {0}, Failed {1} child stories under Feature #{2}: {3}" -f $createdCount, $failedCount, $ParentId, $idsList) -ForegroundColor Yellow
        Write-Host ("Failed titles: {0}" -f ($failedTitles -join ' | ')) -ForegroundColor Yellow
    }
    else {
        Write-Host ("Created {0} child stories under Feature #{1}: {2}" -f $createdCount, $ParentId, $idsList) -ForegroundColor Green
    }

    foreach ($url in $createdUrls) {
        Write-Host "  $url" -ForegroundColor Cyan
    }

    return $createdIds
}
