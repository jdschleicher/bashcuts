# ============================================================================
# Azure DevOps Multi-Project Support (Phase A)
# ============================================================================
#
# Opt-in switcher + per-type defaults resolver layer that sits in front of
# every az-New-AzDevOps* creator and the cache layer in azdevops_workitems.ps1.
#
# When $global:AzDevOpsProjectMap is undefined, every function in this file is
# a no-op (Resolve-* helpers return $null / empty, the cache slug is empty,
# the switcher's auto-hydrate block does nothing). All existing single-project
# users see zero behavior change.
#
# Map shape (set in $profile):
#
#   $global:AzDevOpsProjectMap = @{
#       ProjectABC = @{
#           Org       = 'https://dev.azure.com/contoso'
#           Project   = 'Project ABC'
#           Email     = 'me@contoso.com'
#           Area      = 'Project ABC\Portfolio'
#           Iteration = 'Project ABC\Sprint 42'
#           Tags      = @('abc-team')
#           Types     = @{
#               EPIC = @{
#                   Area        = 'Project ABC\Portfolio'
#                   ParentScope = @{ AreaPaths = @('Project ABC\Portfolio') }
#               }
#               FEATURE = @{
#                   Area            = 'Project ABC\Portfolio\R&D'
#                   DefaultPriority = 2
#                   ParentScope     = @{ AreaPaths = @('Project ABC\Portfolio') }
#               }
#               USER_STORY = @{
#                   Area               = 'Project ABC\Teams\Platform'
#                   DefaultPriority    = 3
#                   DefaultStoryPoints = 3
#                   Tags               = @('platform')
#                   RequiredFields     = @{ 'Custom.ChangeReason' = 'prompt' }
#                   ParentScope        = @{ AreaPaths = @('Project ABC\Portfolio\R&D') }
#               }
#           }
#       }
#
#       ProjectXYZ = @{ Org = '...'; Project = 'Project XYZ'; ... }
#   }
#
#   $global:AzDevOpsDefaultProject = 'ProjectABC'   # optional auto-hydrate
#
# Type keys are normalized; 'EPIC' / 'Epic' / 'epic' / 'USER_STORY' /
# 'UserStory' / 'User Story' / 'FEATURE' / 'Feature' all refer to the same
# entry. Use whichever you prefer when building the map.
#
# Public functions:
#   az-Use-AzDevOpsProject   - activate a project; hydrates $env:AZ_* and (by
#                              default) runs `az devops configure --defaults`
#   az-Show-AzDevOpsProject  - print the currently active project + hydrated
#                              env vars (no I/O when no map is defined)
#   az-Get-AzDevOpsProjects  - return the project keys from the map
#
# Internal resolver layer consumed by Phase B creators:
#   Resolve-AzDevOpsTypeArea
#   Resolve-AzDevOpsTypeIteration
#   Resolve-AzDevOpsTypeTags
#   Resolve-AzDevOpsTypeDefaultPriority
#   Resolve-AzDevOpsTypeDefaultStoryPoints
#   Resolve-AzDevOpsTypeRequiredFields
#   Resolve-AzDevOpsTypeParentScope
#
# Cache namespacing:
#   Get-AzDevOpsProjectCacheSlug - returns '' when no project is active so
#                                  the legacy cache path stays put; otherwise
#                                  returns a filesystem-safe slug used as a
#                                  subdirectory under ~/.bashcuts-cache/
#                                  azure-devops/<slug>/.
# ============================================================================


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

function Get-AzDevOpsProjectTypeKey {
    # Normalizes the many spellings of a work-item type into one of the
    # three canonical map keys: 'EPIC', 'FEATURE', 'USER_STORY'. Returns
    # the input unchanged when it doesn't match a known synonym so the
    # caller can still look up exotic types verbatim (BUG, TASK, etc.).
    param([string] $Type)

    if (-not $Type) {
        return ''
    }

    $normalized = ($Type -replace '\s+', '').ToUpperInvariant()

    switch ($normalized) {
        'EPIC' {
            return 'EPIC'
        }

        'FEATURE' {
            return 'FEATURE'
        }

        'USERSTORY' {
            return 'USER_STORY'
        }

        'USER_STORY' {
            return 'USER_STORY'
        }

        default {
            return $Type
        }
    }
}


function Get-AzDevOpsActiveProject {
    # Returns the active project entry (hashtable) from $global:AzDevOpsProjectMap,
    # keyed by $global:AzDevOpsActiveProject. Returns $null when no map is
    # defined or no project is currently active - callers treat $null as
    # "fall through to env-var / prompt behavior".
    if (-not $global:AzDevOpsProjectMap) {
        return $null
    }
    if (-not $global:AzDevOpsActiveProject) {
        return $null
    }

    $entry = $global:AzDevOpsProjectMap[$global:AzDevOpsActiveProject]
    return $entry
}


function Get-AzDevOpsActiveTypeEntry {
    # Returns the Types.<TYPE> hashtable for the active project, or $null
    # when no map is defined, no project is active, the active project has
    # no Types block, or the requested type isn't in it.
    param([string] $Type)

    $project = Get-AzDevOpsActiveProject
    if ($null -eq $project) {
        return $null
    }
    if (-not $project.Types) {
        return $null
    }

    $key   = Get-AzDevOpsProjectTypeKey -Type $Type
    $entry = $project.Types[$key]
    return $entry
}


function Get-AzDevOpsProjectCacheSlug {
    # Returns a filesystem-safe slug for the active project so the cache
    # layer can namespace assigned.json / mentions.json / hierarchy.json
    # under ~/.bashcuts-cache/azure-devops/<slug>/. Returns '' when no
    # project is active so the legacy single-project cache path stays put.
    #
    # The regex strips dots so a hostile project name like '..' cannot
    # escape the cache root via Join-Path; an entirely-stripped name
    # collapses to '' which also falls back to the legacy path rather
    # than the silently-attacker-controlled one.
    if (-not $global:AzDevOpsActiveProject) {
        return ''
    }

    $raw  = "$global:AzDevOpsActiveProject"
    $safe = ($raw -replace '[^A-Za-z0-9_-]+', '-').Trim('-')
    return $safe
}


# ---------------------------------------------------------------------------
# Per-type defaults resolvers (consumed by Phase B creators)
# ---------------------------------------------------------------------------

function Get-AzDevOpsTypeStringProperty {
    # Shared "type override -> project default -> null" walk used by every
    # per-type Resolve-AzDevOpsType<X> helper that returns a string (Area,
    # Iteration). Extracted so the public Resolve-* layer stays one-liners
    # and the lookup chain lives in one place (CLAUDE.md extract-repeated
    # -branches rule).
    param(
        [Parameter(Mandatory)] [string] $Type,
        [Parameter(Mandatory)] [string] $Property
    )

    $entry = Get-AzDevOpsActiveTypeEntry -Type $Type
    if ($entry -and $entry.$Property) {
        $typeValue = [string]$entry.$Property
        return $typeValue
    }

    $project = Get-AzDevOpsActiveProject
    if ($project -and $project.$Property) {
        $projectValue = [string]$project.$Property
        return $projectValue
    }

    return $null
}


function Get-AzDevOpsTypeIntegerDefault {
    # Shared "TryParse + range-clamp -> sentinel -1" walk used by every
    # integer-default resolver (DefaultPriority, DefaultStoryPoints). The
    # caller picks the valid range; out-of-range values collapse to -1
    # so the consumer treats them as "no override; fall through to prompt".
    param(
        [Parameter(Mandatory)] [string] $Type,
        [Parameter(Mandatory)] [string] $Property,
        [int] $Min = 0,
        [int] $Max = [int]::MaxValue
    )

    $entry = Get-AzDevOpsActiveTypeEntry -Type $Type
    if ($null -eq $entry) {
        return -1
    }
    if ($null -eq $entry.$Property) {
        return -1
    }

    $value = 0
    if (-not [int]::TryParse("$($entry.$Property)", [ref]$value)) {
        return -1
    }
    if ($value -lt $Min -or $value -gt $Max) {
        return -1
    }

    return $value
}


function Resolve-AzDevOpsTypeArea {
    # Returns Types.<TYPE>.Area when configured, falling back to the
    # project-level Area, then $null. Phase B's Resolve-AzDevOpsIterationArea
    # treats $null as "no map override; keep current env-var + prompt flow".
    param([string] $Type)

    $value = Get-AzDevOpsTypeStringProperty -Type $Type -Property 'Area'
    return $value
}


function Resolve-AzDevOpsTypeIteration {
    # Mirror of Resolve-AzDevOpsTypeArea for the iteration path.
    param([string] $Type)

    $value = Get-AzDevOpsTypeStringProperty -Type $Type -Property 'Iteration'
    return $value
}


function Resolve-AzDevOpsTypeTags {
    # Merges project-level Tags with Types.<TYPE>.Tags, deduplicating
    # case-insensitively. Returns a [string[]] (possibly empty) so callers
    # can `if ($tags.Count -gt 0)` without null guards.
    param([string] $Type)

    $merged = New-Object System.Collections.Generic.List[string]
    $seen   = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

    $project = Get-AzDevOpsActiveProject
    if ($project -and $project.Tags) {
        foreach ($tag in @($project.Tags)) {
            if ($tag -and $seen.Add($tag)) {
                $merged.Add($tag)
            }
        }
    }

    $entry = Get-AzDevOpsActiveTypeEntry -Type $Type
    if ($entry -and $entry.Tags) {
        foreach ($tag in @($entry.Tags)) {
            if ($tag -and $seen.Add($tag)) {
                $merged.Add($tag)
            }
        }
    }

    $tags = [string[]]$merged.ToArray()
    return ,$tags
}


function Resolve-AzDevOpsTypeDefaultPriority {
    # Returns the configured default 1-4 priority for the given type, or -1
    # when no map / no override / out-of-range. Callers interpret -1 as
    # "fall through to Read-AzDevOpsPriority".
    param([string] $Type)

    $value = Get-AzDevOpsTypeIntegerDefault -Type $Type -Property 'DefaultPriority' -Min 1 -Max 4
    return $value
}


function Resolve-AzDevOpsTypeDefaultStoryPoints {
    # Returns the configured default non-negative story-points for the type,
    # or -1 when no map / no override. Callers interpret -1 as "fall through
    # to Read-AzDevOpsStoryPoints".
    param([string] $Type)

    $value = Get-AzDevOpsTypeIntegerDefault -Type $Type -Property 'DefaultStoryPoints' -Min 0
    return $value
}


function Resolve-AzDevOpsTypeRequiredFields {
    # Returns the Types.<TYPE>.RequiredFields hashtable (RefName -> value or
    # the literal string 'prompt'). Always returns a hashtable so callers can
    # iterate without null guards; empty when no override / no map.
    param([string] $Type)

    $entry = Get-AzDevOpsActiveTypeEntry -Type $Type
    if ($null -eq $entry) {
        return @{}
    }
    if ($null -eq $entry.RequiredFields) {
        return @{}
    }

    $fields = @{}
    foreach ($key in $entry.RequiredFields.Keys) {
        $fields[$key] = $entry.RequiredFields[$key]
    }
    return $fields
}


function Resolve-AzDevOpsTypeParentScope {
    # Returns Types.<TYPE>.ParentScope or $null. Phase B's Feature/Epic
    # pickers read .AreaPaths off the returned hashtable to filter the
    # candidate list to the correct area.
    param([string] $Type)

    $entry = Get-AzDevOpsActiveTypeEntry -Type $Type
    if ($null -eq $entry) {
        return $null
    }
    if ($null -eq $entry.ParentScope) {
        return $null
    }

    return $entry.ParentScope
}


# ---------------------------------------------------------------------------
# Public switcher commands
# ---------------------------------------------------------------------------

function az-Get-AzDevOpsProjects {
    # Returns the project keys from $global:AzDevOpsProjectMap as [string[]],
    # alphabetized. Returns an empty array when no map is defined so callers
    # can `foreach` without guards.
    if (-not $global:AzDevOpsProjectMap) {
        $empty = [string[]]@()
        return ,$empty
    }

    $names = @($global:AzDevOpsProjectMap.Keys | Sort-Object)
    $arr   = [string[]]$names
    return ,$arr
}


function az-Show-AzDevOpsProject {
    # Prints the currently active project plus the hydrated $env:AZ_* vars.
    # When no map is defined, prints '(none)' and the existing env vars so
    # the command stays useful in single-project setups.
    Write-Host ''
    Write-Host 'Azure DevOps - active project' -ForegroundColor Cyan
    Write-Host '-----------------------------' -ForegroundColor Cyan

    if (-not $global:AzDevOpsProjectMap) {
        Write-Host '  $global:AzDevOpsProjectMap : (none - single-project mode)' -ForegroundColor Yellow
    } else {
        $name = if ($global:AzDevOpsActiveProject) {
            $global:AzDevOpsActiveProject
        } else {
            '(none)'
        }
        Write-Host "  Active project : $name"
    }

    Write-Host "  AZ_DEVOPS_ORG  : $env:AZ_DEVOPS_ORG"
    Write-Host "  AZ_PROJECT     : $env:AZ_PROJECT"
    Write-Host "  AZ_USER_EMAIL  : $env:AZ_USER_EMAIL"
    Write-Host "  AZ_AREA        : $env:AZ_AREA"
    Write-Host "  AZ_ITERATION   : $env:AZ_ITERATION"
}


function az-Use-AzDevOpsProject {
    # Switches the active project. Reads $global:AzDevOpsProjectMap[$Name],
    # hydrates $env:AZ_DEVOPS_ORG / AZ_PROJECT / AZ_USER_EMAIL / AZ_AREA /
    # AZ_ITERATION from the entry's flat keys (each is optional - missing
    # ones leave the existing env var alone), sets $global:AzDevOpsActiveProject,
    # and (unless -Quiet) runs `az devops configure --defaults` so the CLI
    # tracks the new project.
    #
    # -Quiet suppresses both the Write-Host status line and the
    # `az devops configure` side effect; used by the auto-hydrate block
    # below so opening a new terminal stays silent.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [switch] $Quiet
    )

    if (-not $global:AzDevOpsProjectMap) {
        Write-Host "az-Use-AzDevOpsProject aborted - `$global:AzDevOpsProjectMap is not defined." -ForegroundColor Red
        return
    }

    if (-not $global:AzDevOpsProjectMap.ContainsKey($Name)) {
        $known = (az-Get-AzDevOpsProjects) -join ', '
        Write-Host "az-Use-AzDevOpsProject aborted - '$Name' not in map. Known projects: $known" -ForegroundColor Red
        return
    }

    $entry = $global:AzDevOpsProjectMap[$Name]

    if ($entry.Org)       { $env:AZ_DEVOPS_ORG = [string]$entry.Org }
    if ($entry.Project)   { $env:AZ_PROJECT    = [string]$entry.Project }
    if ($entry.Email)     { $env:AZ_USER_EMAIL = [string]$entry.Email }
    if ($entry.Area)      { $env:AZ_AREA       = [string]$entry.Area }
    if ($entry.Iteration) { $env:AZ_ITERATION  = [string]$entry.Iteration }

    $global:AzDevOpsActiveProject = $Name

    if (-not $Quiet) {
        $configureFailed = $false
        if ($env:AZ_DEVOPS_ORG -and $env:AZ_PROJECT) {
            $configureOutput = az devops configure --defaults "organization=$env:AZ_DEVOPS_ORG" "project=$env:AZ_PROJECT" 2>&1
            if ($LASTEXITCODE -ne 0) {
                $configureFailed = $true
                Write-Host "az devops configure --defaults failed for project '$Name'" -ForegroundColor Red
                Write-Host "  $configureOutput" -ForegroundColor Red
            }
        }

        if (-not $configureFailed) {
            Write-Host "Active Azure DevOps project: $Name (org=$env:AZ_DEVOPS_ORG project=$env:AZ_PROJECT)" -ForegroundColor Green
        }
    }
}


# ---------------------------------------------------------------------------
# Auto-hydrate at shell startup
# ---------------------------------------------------------------------------
# Silent by design - profile sourcing should not print noise. Users who want
# explicit feedback can run `az-Show-AzDevOpsProject` after.
if ($global:AzDevOpsProjectMap -and $global:AzDevOpsDefaultProject -and -not $global:AzDevOpsActiveProject) {
    if ($global:AzDevOpsProjectMap.ContainsKey($global:AzDevOpsDefaultProject)) {
        az-Use-AzDevOpsProject -Name $global:AzDevOpsDefaultProject -Quiet
    }
}
