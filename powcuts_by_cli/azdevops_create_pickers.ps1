# ============================================================================
# Azure DevOps — Field prompts & create-flow pickers
# ============================================================================
# The interactive prompts shared by the work-item creators in
# azdevops_create.ps1: priority/story-points/acceptance-criteria readers, and
# the parent / feature / epic / classification (area + iteration) / kind
# Out-ConsoleGridView pickers. All read-only — no `az` writes happen here.
#
# Loaded by powcuts_home.ps1. See azdevops_auth.ps1 for the master docstring.

function Get-AzDevOpsReuseHint {
    # Builds the " (Enter to reuse '<value>')" suffix used by batch-flow readers
    # that carry forward the prior loop's answer. Returns '' when Previous has
    # no usable value so the prompt collapses cleanly to its non-batch form.
    param([object] $Previous)

    if ($null -eq $Previous -or "$Previous" -eq '') {
        return ''
    }

    $hint = " (Enter to reuse '$Previous')"
    return $hint
}


function Read-AzDevOpsPriority {
    # -Previous lets batch flows (az-New-AzDevOpsFeatureStories) carry the
    # prior priority forward: empty input reuses Previous, any 1-4 digit
    # overrides. Single-shot callers omit -Previous and get the original
    # required-prompt behavior.
    param([int] $Previous = -1)

    $hasPrevious = $Previous -ge 1 -and $Previous -le 4
    $hint = if ($hasPrevious) {
        Get-AzDevOpsReuseHint -Previous $Previous
    }
    else {
        ''
    }

    while ($true) {
        $resp = Read-Host "Priority? 1=LOW, 2=MEDIUM, 3=HIGH, 4=SUPER-HIGH$hint"
        if (-not $resp -and $hasPrevious) {
            return $Previous
        }
        if ($resp -match '^[1-4]$') {
            $priority = [int]$resp
            return $priority
        }
        Write-Host "  Please enter 1, 2, 3, or 4." -ForegroundColor Yellow
    }
}


function Read-AzDevOpsStoryPoints {
    # -Previous mirrors Read-AzDevOpsPriority's reuse shorthand for batch flows.
    param([int] $Previous = -1)

    $hasPrevious = $Previous -ge 0
    $hint = if ($hasPrevious) {
        Get-AzDevOpsReuseHint -Previous $Previous
    }
    else {
        ''
    }

    $val = 0
    while ($true) {
        $resp = Read-Host "Story points? (integer)$hint"
        if (-not $resp -and $hasPrevious) {
            return $Previous
        }
        if ([int]::TryParse($resp, [ref]$val) -and $val -ge 0) {
            return $val
        }
        Write-Host "  Please enter a non-negative integer." -ForegroundColor Yellow
    }
}


function Read-AzDevOpsAcceptanceCriteria {
    # One initial AC, then loop on Y/N. Joins additional ACs with '<br/><br/>'
    # so they render as separate lines in the work-item editor. The existing
    # az-create-userstory used `until ($resp -eq 'n')` which loops forever on
    # any non-'n' reply (empty Enter, 'yes', 'q'); this version exits on
    # anything that isn't an affirmative yes/y.
    $first = Read-Host 'Acceptance criterion #1'
    $dash = '-'
    $break = '<br/><br/>'
    $ac = "$dash $first"

    while ($true) {
        $resp = Read-Host 'More AC? (Y/N)'
        if ($resp -notmatch '^(y|yes)$') {
            break
        }

        $next = Read-Host 'Enter additional AC'
        $ac = "$ac $break $dash $next"
    }

    return $ac
}


function Test-AzDevOpsAreaPathMatch {
    # Returns $true when $CandidatePath equals any element of $AllowedPaths
    # exactly OR is a sub-path of one (matches at backslash boundary). Path
    # comparison is case-insensitive to match Azure DevOps' own semantics:
    # 'Project ABC\Portfolio' matches both 'Project ABC\Portfolio' and
    # 'Project ABC\Portfolio\R&D'.
    param(
        [string]   $CandidatePath,
        [string[]] $AllowedPaths
    )

    if (-not $CandidatePath) {
        return $false
    }

    foreach ($allowed in $AllowedPaths) {
        if (-not $allowed) {
            continue
        }
        if ($CandidatePath -ieq $allowed) {
            return $true
        }
        $prefix = "$allowed\"
        if ($CandidatePath.Length -gt $prefix.Length -and
            $CandidatePath.Substring(0, $prefix.Length) -ieq $prefix) {
            return $true
        }
    }

    return $false
}


function Read-AzDevOpsParentPick {
    # Generic parent picker shared by Read-AzDevOpsFeaturePick (story -> Feature)
    # and Read-AzDevOpsEpicPick (Feature -> Epic). Lists active rows of the
    # requested ParentType from the hierarchy cache and returns the chosen Id,
    # or 0 when the user picks 'orphan' / cancels. Out-ConsoleGridView TUI when
    # available, Read-Host numbered menu otherwise.
    #
    # -AreaPaths narrows the candidate list to rows whose AreaPath equals or is
    # a sub-path of any provided value (sourced from
    # ParentScope.AreaPaths in the active project map). When the hierarchy rows
    # carry no AreaPath the filter is a silent no-op (logged once at -Verbose).
    #
    # Limitation: Basic-template projects skip the Feature tier entirely
    # (Epic -> Issue, no Feature). For -ParentType Feature this filter
    # returns zero rows on Basic projects and the caller falls through to
    # the orphan path - acceptable while the create flow stays Agile/Scrum/
    # CMMI-focused.
    param(
        [Parameter(Mandatory)] [ValidateSet('Feature', 'Epic')] [string] $ParentType,
        [Parameter(Mandatory)] $Hierarchy,
        [string]   $ChildLabel = 'item',
        [string[]] $AreaPaths
    )

    $closedStates = Get-AzDevOpsClosedStates
    $candidates = @($Hierarchy |
        Where-Object { $_.Type -eq $ParentType -and $_.State -notin $closedStates } |
        Sort-Object Id)

    $orphanLabel = "(no parent - orphan $ChildLabel)"

    if ($candidates.Count -eq 0) {
        Write-Host "(no active ${ParentType}s in hierarchy.json - $ChildLabel will be orphaned)" -ForegroundColor Yellow
        return 0
    }

    if ($AreaPaths -and $AreaPaths.Count -gt 0) {
        $hasAreaField = $false
        foreach ($row in $candidates) {
            if ($row.PSObject.Properties.Match('AreaPath').Count -gt 0 -and $row.AreaPath) {
                $hasAreaField = $true
                break
            }
        }

        if (-not $hasAreaField) {
            Write-Verbose "Read-AzDevOpsParentPick: hierarchy rows lack AreaPath; ParentScope.AreaPaths filter skipped. Run az-Sync-AzDevOpsCache to refresh."
        }
        else {
            $filtered = @($candidates |
                Where-Object { Test-AzDevOpsAreaPathMatch -CandidatePath $_.AreaPath -AllowedPaths $AreaPaths })

            if ($filtered.Count -eq 0) {
                Write-Host "(no ${ParentType}s match ParentScope.AreaPaths - $ChildLabel will be orphaned)" -ForegroundColor Yellow
                return 0
            }

            $candidates = $filtered
        }
    }

    if (Test-AzDevOpsGridAvailable) {
        $orphanRow = [PSCustomObject]@{
            Id    = 0
            Title = $orphanLabel
            State = ''
        }

        $candidateRows = $candidates | ForEach-Object {
            $title = Format-AzDevOpsTruncatedTitle -Title $_.Title
            [PSCustomObject]@{
                Id    = $_.Id
                Title = $title
                State = $_.State
            }
        }

        $gridRows = @($orphanRow) + @($candidateRows)
        $picked = Read-AzDevOpsGridPick -Rows $gridRows -Title "Pick a parent $ParentType (Esc = orphan $ChildLabel)"

        if ($null -eq $picked) {
            return 0
        }

        $parentId = [int]$picked.Id
        return $parentId
    }

    Write-Host ""
    Write-Host "Active ${ParentType}s:" -ForegroundColor Cyan
    Write-Host "  0. $orphanLabel"
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $c = $candidates[$i]
        $title = Format-AzDevOpsTruncatedTitle -Title $c.Title
        Write-Host ("  {0}. {1} - {2} [{3}]" -f ($i + 1), $c.Id, $title, $c.State)
    }

    $idx = 0
    while ($true) {
        $resp = Read-Host "Pick a parent $ParentType (0 for no parent)"
        if (-not [int]::TryParse($resp, [ref]$idx)) {
            Write-Host "  Please enter a number." -ForegroundColor Yellow
            continue
        }

        if ($idx -eq 0) {
            return 0
        }

        if ($idx -ge 1 -and $idx -le $candidates.Count) {
            $parentId = $candidates[$idx - 1].Id
            return $parentId
        }

        Write-Host "  Please enter 0..$($candidates.Count)." -ForegroundColor Yellow
    }
}


function Get-AzDevOpsParentScopeAreaPaths {
    # Looks up ParentScope.AreaPaths for the given child work-item type via the
    # Phase A resolver layer. Returns a (possibly empty) string[] - callers
    # forward straight to Read-AzDevOpsParentPick -AreaPaths and the filter is
    # a no-op on empty.
    param([Parameter(Mandatory)] [string] $ChildType)

    if (-not (Get-Command Resolve-AzDevOpsTypeParentScope -ErrorAction SilentlyContinue)) {
        return @()
    }

    $scope = Resolve-AzDevOpsTypeParentScope -Type $ChildType
    if ($null -eq $scope) {
        return @()
    }

    $paths = @($scope.AreaPaths)
    return $paths
}


function Read-AzDevOpsFeaturePick {
    # Story -> Feature parent picker. Thin wrapper over Read-AzDevOpsParentPick
    # so az-New-AzDevOpsUserStory keeps its current call site unchanged.
    # -ChildType drives the ParentScope.AreaPaths lookup; defaults to USER_STORY.
    param(
        [Parameter(Mandatory)] $Hierarchy,
        [string] $ChildType = 'USER_STORY'
    )

    $areaPaths = Get-AzDevOpsParentScopeAreaPaths -ChildType $ChildType
    $featureId = Read-AzDevOpsParentPick -ParentType 'Feature' -Hierarchy $Hierarchy -ChildLabel 'story' -AreaPaths $areaPaths
    return $featureId
}


function Read-AzDevOpsEpicPick {
    # Feature -> Epic parent picker. Thin wrapper over Read-AzDevOpsParentPick
    # used by az-New-AzDevOpsFeature. -ChildType drives the ParentScope.AreaPaths
    # lookup; defaults to FEATURE.
    param(
        [Parameter(Mandatory)] $Hierarchy,
        [string] $ChildType = 'FEATURE'
    )

    $areaPaths = Get-AzDevOpsParentScopeAreaPaths -ChildType $ChildType
    $epicId = Read-AzDevOpsParentPick -ParentType 'Epic' -Hierarchy $Hierarchy -ChildLabel 'Feature' -AreaPaths $areaPaths
    return $epicId
}


function Read-AzDevOpsClassificationPick {
    # Picker shared by iteration + area selection. When Out-ConsoleGridView
    # is available, renders a Path / IsDefault grid; Cancel returns the
    # supplied default (typically $env:AZ_ITERATION / $env:AZ_AREA).
    # Otherwise falls back to the Read-Host numbered menu where empty
    # input selects the default.
    param(
        [Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind,
        [Parameter(Mandatory)] [string[]] $Paths,
        [string] $Default
    )

    if (Test-AzDevOpsGridAvailable) {
        $gridRows = $Paths | ForEach-Object {
            [PSCustomObject]@{
                Path      = $_
                IsDefault = ($Default -and $_ -eq $Default)
            }
        }

        $title = if ($Default) {
            "Pick $Kind (Esc = use default '$Default')"
        }
        else {
            "Pick $Kind"
        }

        $picked = Read-AzDevOpsGridPick -Rows $gridRows -Title $title

        if ($null -eq $picked) {
            return $Default
        }

        $pickedPath = [string]$picked.Path
        return $pickedPath
    }

    Write-Host ""
    Write-Host "Available ${Kind}s:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Paths.Count; $i++) {
        $marker = if ($Default -and $Paths[$i] -eq $Default) {
            ' (default)'
        }
        else {
            ''
        }
        Write-Host ("  {0}. {1}{2}" -f ($i + 1), $Paths[$i], $marker)
    }

    $defaultPrompt = if ($Default) {
        " (Enter for default '$Default')"
    }
    else {
        ''
    }

    $idx = 0
    while ($true) {
        $resp = Read-Host "Pick $Kind$defaultPrompt"
        if (-not $resp -and $Default) {
            return $Default
        }

        if (-not [int]::TryParse($resp, [ref]$idx)) {
            Write-Host "  Please enter a number." -ForegroundColor Yellow
            continue
        }

        if ($idx -ge 1 -and $idx -le $Paths.Count) {
            $pickedPath = $Paths[$idx - 1]
            return $pickedPath
        }

        Write-Host "  Please enter 1..$($Paths.Count)." -ForegroundColor Yellow
    }
}


function Read-AzDevOpsKindPick {
    # Single iteration / area picker shared by both kinds. Reads the
    # cache (or falls back to live `az`), then either renders the numbered
    # menu or - if no paths are available - returns the matching $env:AZ_*
    # default. Returns $null if both the cache and the env-var default are
    # empty; callers must guard for that and abort cleanly.
    param([Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind)

    $envName = if ($Kind -eq 'Iteration') {
        'AZ_ITERATION'
    }
    else {
        'AZ_AREA'
    }

    $envFallback = if ($Kind -eq 'Iteration') {
        $env:AZ_ITERATION
    }
    else {
        $env:AZ_AREA
    }

    $paths = Get-AzDevOpsClassificationPaths -Kind $Kind
    if ($paths.Count -eq 0) {
        if (-not $envFallback) {
            Write-Host "(no ${Kind}s available and `$env:$envName is unset)" -ForegroundColor Red
            return $null
        }
        Write-Host "(no ${Kind}s available - falling back to `$env:$envName='$envFallback')" -ForegroundColor Yellow
        return $envFallback
    }

    $picked = Read-AzDevOpsClassificationPick -Kind $Kind -Paths $paths -Default $envFallback
    return $picked
}
