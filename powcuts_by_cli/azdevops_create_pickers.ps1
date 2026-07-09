# ============================================================================
# Azure DevOps — Field prompts & create-flow pickers
# ============================================================================
# The interactive prompts shared by the work-item creators in
# azdevops_create.ps1: priority/story-points/acceptance-criteria readers, and
# the parent / feature / epic / classification (area + iteration) / kind
# Out-ConsoleGridView pickers. All read-only — no `az` writes happen here.
#
# Loaded by powcuts_home.ps1. See azdevops_auth.ps1 for the master docstring.

# Azure DevOps caps System.Title at 255 characters across the stock Agile /
# Scrum / CMMI / Basic process templates. Read-AzDevOpsTitle enforces this cap
# at entry so an over-length title is caught before the `az boards work-item
# create` round-trip rather than after it. The warn threshold nudges the user
# as they approach the limit.
$script:AzDevOpsTitleMaxLength  = 255
$script:AzDevOpsTitleWarnLength = 230


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
    # Reads acceptance criteria one per line: prompt repeatedly and capture
    # every non-empty entry as its own AC, stopping on the first blank line.
    # This replaces an earlier 'More AC? (Y/N)' gate that discarded any reply
    # which wasn't 'y'/'yes' - so typing a real criterion at that prompt (a
    # natural thing to do, and one that usually contains a '/', which is just
    # literal text to Read-Host) ended the loop and silently dropped the entry.
    # A blank-to-finish loop can never lose an entered criterion. Each collected
    # AC renders on its own line prefixed with a ballot-box glyph so the
    # AcceptanceCriteria field (which stores HTML) shows a checklist in the AzDO
    # work-item UI rather than plain dashes. A leading glyph is used instead of a
    # raw <input type="checkbox"> because the field's HTML sanitizer strips form
    # elements.
    $uncheckedBox = "$([char]0x2610)"   # ballot box (empty checkbox)
    $break = '<br/>'

    $criteria = [System.Collections.Generic.List[string]]::new()

    $index = 1
    while ($true) {
        $prompt = if ($index -eq 1) {
            'Acceptance criterion #1'
        } else {
            "Acceptance criterion #$index (blank to finish)"
        }

        $entry = Read-Host $prompt
        if (-not $entry) {
            break
        }

        $criteria.Add($entry)
        $index++
    }

    $checklist = ($criteria | ForEach-Object { "$uncheckedBox $_" }) -join $break
    return $checklist
}


function Read-AzDevOpsUserStoryDescription {
    # Builds the User Story description from the canonical three-clause
    # template. Each clause is required - re-prompts until a non-empty value
    # is entered - then joins them with HTML line breaks so each clause
    # renders on its own line in the AzDO Description field (which stores
    # HTML): "As a <persona>" / "I want <outcome>" / "So that <benefit>".
    $persona = ''
    while (-not $persona) {
        $persona = (Read-Host 'As a ...').Trim()
    }

    $outcome = ''
    while (-not $outcome) {
        $outcome = (Read-Host 'I want ...').Trim()
    }

    $benefit = ''
    while (-not $benefit) {
        $benefit = (Read-Host 'So that ...').Trim()
    }

    $clauseBreak = '<br/><br/>'

    $clauses = @(
        "As a $persona"
        "I want $outcome"
        "So that $benefit"
    )

    $description = $clauses -join $clauseBreak

    return $description
}


function Read-AzDevOpsFeatureDescription {
    # Builds the Feature description from two required clauses - Summary and
    # Business Value - each under a bold HTML heading so they render as bold
    # headings in the AzDO Description field (which stores HTML). Mirrors
    # Read-AzDevOpsUserStoryDescription: each clause is required (re-prompts
    # until non-empty). Within a section the heading sits on its own line above
    # its text (joined with '<br/>'), and the two sections are separated by a
    # blank line ('<br/><br/>'), so the Description renders as:
    #   "<b>Summary</b>" / "<text>" / "" / "<b>Business Value</b>" / "<text>".
    $summaryHeading       = '<b>Summary</b>'
    $businessValueHeading = '<b>Business Value</b>'

    $summary = ''
    while (-not $summary) {
        $summary = (Read-Host 'Summary').Trim()
    }

    $businessValue = ''
    while (-not $businessValue) {
        $businessValue = (Read-Host 'Business Value').Trim()
    }

    $headingBreak = '<br/>'
    $clauseBreak  = '<br/><br/>'

    $clauses = @(
        "$summaryHeading$headingBreak$summary"
        "$businessValueHeading$headingBreak$businessValue"
    )

    $description = $clauses -join $clauseBreak

    return $description
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
        [Parameter(Mandatory)] [ValidateSet('Feature', 'Epic', 'User Story')] [string] $ParentType,
        [Parameter(Mandatory)] $Hierarchy,
        [string]   $ChildLabel = 'item',
        [string[]] $AreaPaths
    )

    $closedStates = Get-AzDevOpsClosedStates

    $orphanLabel = "(no parent - orphan $ChildLabel)"

    # Distinguish "cache is entirely empty" from "cache is populated but
    # no matching ${ParentType}s" - the former almost always means the
    # WIQL queries returned 0 rows (wrong AZ_AREA, custom process
    # template, edited WIQL) and the user needs an actionable hint
    # rather than a silent orphan path.
    $hierarchyCount = @($Hierarchy).Count
    if ($hierarchyCount -eq 0) {
        Write-Host "hierarchy.json is empty (0 rows total) - the WIQL queries returned no work items." -ForegroundColor Yellow
        Write-Host "  Check `$env:AZ_AREA = '$env:AZ_AREA'" -ForegroundColor Yellow
        Write-Host "  Edit WIQLs:    az-Open-AzDevOpsHierarchyWiqls" -ForegroundColor Yellow
        Write-Host "  Re-sync cache: az-Sync-AzDevOpsCache" -ForegroundColor Yellow
        Write-Host "  $ChildLabel will be created as an orphan." -ForegroundColor Yellow
        return 0
    }

    # 'User Story' parents (Task creation) match every requirement-tier type so
    # Scrum / CMMI / Basic projects still surface their leaf items; Epic and
    # Feature stay exact-match.
    $candidates = if ($ParentType -eq 'User Story') {
        @($Hierarchy |
            Where-Object { $_.Type -in $script:AzDevOpsRequirementTypes -and $_.State -notin $closedStates } |
            Sort-Object Id)
    } else {
        @($Hierarchy |
            Where-Object { $_.Type -eq $ParentType -and $_.State -notin $closedStates } |
            Sort-Object Id)
    }

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


function Read-AzDevOpsStoryPick {
    # Task -> User Story parent picker. Thin wrapper over Read-AzDevOpsParentPick
    # used by az-New-Task. -ChildType drives the ParentScope.AreaPaths lookup;
    # defaults to TASK.
    param(
        [Parameter(Mandatory)] $Hierarchy,
        [string] $ChildType = 'TASK'
    )

    $areaPaths = Get-AzDevOpsParentScopeAreaPaths -ChildType $ChildType
    $storyId = Read-AzDevOpsParentPick -ParentType 'User Story' -Hierarchy $Hierarchy -ChildLabel 'task' -AreaPaths $areaPaths
    return $storyId
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


function Read-AzDevOpsTitle {
    # Length-capped replacement for the raw `Read-Host '...title...'` every
    # creator used to run. Rejects titles over $script:AzDevOpsTitleMaxLength
    # and re-prompts, showing the running count and an "over by N" delta, and
    # offers to auto-truncate to the cap with a preview of the result. A title
    # within a warn band of the limit gets a heads-up but is accepted. Empty
    # input returns '' unchanged so callers keep their existing semantics:
    # az-New-AzDevOps* abort on an empty title, and the batch loop treats it as
    # "finish". -PromptText carries the caller's exact wording so the UX reads
    # identically to before.
    param([string] $PromptText = 'What is the title?')

    $max        = $script:AzDevOpsTitleMaxLength
    $warnAt     = $script:AzDevOpsTitleWarnLength
    $previewLen = 60
    $ellipsis   = '...'

    while ($true) {
        $resp = Read-Host $PromptText
        if (-not $resp) {
            return ''
        }

        $length = $resp.Length
        if ($length -le $max) {
            if ($length -ge $warnAt) {
                Write-Host ("  Heads up: title is {0}/{1} characters." -f $length, $max) -ForegroundColor Yellow
            }

            return $resp
        }

        $over = $length - $max
        Write-Host ("  Title is {0}/{1} characters - over by {2}." -f $length, $max, $over) -ForegroundColor Yellow

        $truncated = $resp.Substring(0, $max)
        $preview = if ($truncated.Length -gt $previewLen) {
            $truncated.Substring(0, $previewLen) + $ellipsis
        } else {
            $truncated
        }

        if (Read-AzDevOpsYesNo -Prompt "Truncate to $max chars? Result starts: '$preview'" -DefaultNo) {
            return $truncated
        }
    }
}


function Test-AzDevOpsTitleLengthError {
    # True when an `az boards work-item create` error text reads like a title
    # length-limit rejection, so Read-AzDevOpsCreateFieldEdit can route straight
    # to a title re-prompt. Azure DevOps phrases this several ways
    # ("...Title... exceeds the maximum length", "LengthExceeded", etc.), so the
    # test looks for a title mention alongside any length / exceed wording.
    param([string] $ErrorText)

    if (-not $ErrorText) {
        return $false
    }

    $text = $ErrorText.ToLower()
    $mentionsTitle  = $text -match 'title'
    $mentionsLength = $text -match 'length|exceed|too long|maxlength|max length'

    $isTitleLength = $mentionsTitle -and $mentionsLength
    return $isTitleLength
}


function Get-AzDevOpsEditableFields {
    # Returns the subset of the create-flow catalog whose keys are actually
    # present in $CreateArgs, in a stable display order. Iteration / Area / Type
    # / ExtraFields are intentionally excluded - they're picker- or
    # schema-driven, not free-text fields the user re-enters to clear a create
    # rejection.
    param([Parameter(Mandatory)] [hashtable] $CreateArgs)

    $catalog = @(
        [PSCustomObject]@{ Key = 'Title';              Label = 'Title' }
        [PSCustomObject]@{ Key = 'Priority';           Label = 'Priority' }
        [PSCustomObject]@{ Key = 'StoryPoints';        Label = 'Story Points' }
        [PSCustomObject]@{ Key = 'AcceptanceCriteria'; Label = 'Acceptance Criteria' }
        [PSCustomObject]@{ Key = 'Description';        Label = 'Description' }
        [PSCustomObject]@{ Key = 'Tags';               Label = 'Tags' }
    )

    $present = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $catalog) {
        if ($CreateArgs.ContainsKey($entry.Key)) {
            $present.Add($entry)
        }
    }

    return $present
}


function Format-AzDevOpsFieldPreview {
    # Renders a create-arg value for the edit menu: joins a tag array, collapses
    # an empty / null value to '(none)', and truncates long text via the shared
    # 80-char title truncator so the menu stays one line per field.
    param([object] $Value)

    if ($null -eq $Value) {
        return '(none)'
    }

    $text = if ($Value -is [array]) {
        ($Value | Where-Object { $_ } | ForEach-Object { [string]$_ }) -join '; '
    } else {
        [string]$Value
    }

    if (-not $text) {
        return '(none)'
    }

    $preview = Format-AzDevOpsTruncatedTitle -Title $text
    return $preview
}


function Invoke-AzDevOpsFieldEditor {
    # Re-prompts a single create field, reusing the same reader the creator used
    # originally so validation stays identical. Empty input keeps the current
    # value for the free-text fields (Title / Description / Tags); Priority and
    # Story Points flow the current value through -Previous so Enter reuses it.
    param(
        [Parameter(Mandatory)] [string] $Key,
        [object] $Current
    )

    switch ($Key) {
        'Title' {
            $entered = Read-AzDevOpsTitle -PromptText 'New title (Enter to keep current)'
            $value = if ($entered) {
                $entered
            } else {
                $Current
            }

            return $value
        }

        'Priority' {
            $value = Read-AzDevOpsPriority -Previous ([int]$Current)
            return $value
        }

        'StoryPoints' {
            $value = Read-AzDevOpsStoryPoints -Previous ([int]$Current)
            return $value
        }

        'AcceptanceCriteria' {
            $value = Read-AzDevOpsAcceptanceCriteria
            return $value
        }

        'Description' {
            $entered = Read-Host 'New description (Enter to keep current)'
            $value = if ($entered) {
                $entered
            } else {
                $Current
            }

            return $value
        }

        'Tags' {
            $entered = Read-Host 'New tags (semicolon-separated, Enter to keep current)'
            $value = if ($entered) {
                $parts = $entered -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
                ,$parts
            } else {
                $Current
            }

            return $value
        }

        default {
            return $Current
        }
    }
}


function Read-AzDevOpsCreateFieldEdit {
    # Failure-recovery menu for Invoke-AzDevOpsCreateAndLink. Given the
    # CreateArgs of a create that just failed, lets the user fix one or more
    # fields and resubmit with everything else preserved verbatim, or cancel.
    # Works on a copy of CreateArgs so a cancel leaves the caller's hashtable
    # untouched. When the error reads like a title-length rejection the title
    # reader runs once up front (the targeted path for the common case); the
    # menu then still offers further edits, resubmit, or cancel.
    #
    # Returns { Retry = <bool>; CreateArgs = <hashtable> }: on Retry the caller
    # re-runs the create with the returned args; on cancel the caller returns
    # its standard failure result exactly as before this recovery step existed.
    param(
        [Parameter(Mandatory)] [hashtable] $CreateArgs,
        [string] $ErrorText
    )

    $edited = @{}
    foreach ($key in $CreateArgs.Keys) {
        $edited[$key] = $CreateArgs[$key]
    }

    if (Test-AzDevOpsTitleLengthError -ErrorText $ErrorText) {
        Write-Host ""
        Write-Host "That title exceeds Azure DevOps' $($script:AzDevOpsTitleMaxLength)-character limit." -ForegroundColor Yellow
        $fixedTitle = Read-AzDevOpsTitle -PromptText 'New title'
        if ($fixedTitle) {
            $edited['Title'] = $fixedTitle
        }
    }

    $fields = Get-AzDevOpsEditableFields -CreateArgs $edited

    while ($true) {
        Write-Host ""
        Write-Host "Edit a field and resubmit, or cancel:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $fields.Count; $i++) {
            $field   = $fields[$i]
            $preview = Format-AzDevOpsFieldPreview -Value $edited[$field.Key]
            Write-Host ("  {0}. {1,-20}: {2}" -f ($i + 1), $field.Label, $preview)
        }
        Write-Host "  r. Resubmit with the values above"
        Write-Host "  c. Cancel (abort create)"

        $resp    = Read-Host 'Choose'
        $trimmed = "$resp".Trim().ToLower()

        if ($trimmed -eq 'c') {
            return [PSCustomObject]@{ Retry = $false; CreateArgs = $edited }
        }

        if ($trimmed -eq 'r') {
            return [PSCustomObject]@{ Retry = $true; CreateArgs = $edited }
        }

        $idx = 0
        if (-not [int]::TryParse($trimmed, [ref]$idx) -or $idx -lt 1 -or $idx -gt $fields.Count) {
            Write-Host "  Enter a field number, 'r' to resubmit, or 'c' to cancel." -ForegroundColor Yellow
            continue
        }

        $chosen   = $fields[$idx - 1]
        $newValue = Invoke-AzDevOpsFieldEditor -Key $chosen.Key -Current $edited[$chosen.Key]
        $edited[$chosen.Key] = $newValue
    }
}
