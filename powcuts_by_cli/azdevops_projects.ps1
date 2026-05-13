# ============================================================================
# Azure DevOps Multi-Project Map
# ============================================================================
#
# Lets the user define a hashtable in their `$profile` describing every Azure
# DevOps project board they touch, then switch the active board with a single
# command. Existing az-* functions don't change shape - the switcher hydrates
# the same flat $env:AZ_DEVOPS_ORG / AZ_PROJECT / AZ_AREA / AZ_ITERATION env
# vars they already read.
#
# Profile shape (set in $profile, AFTER bashcuts is sourced):
#
#   $global:AzDevOpsProjectMap = @{
#       ProjectABC = @{
#           Org       = 'https://dev.azure.com/myorg'
#           Project   = 'Project ABC'
#           Area      = 'Project ABC\Team Phoenix'
#           Iteration = 'Project ABC\Sprint 42'
#           Tags      = @('team-phoenix')
#           Types = @{
#               EPIC = @{
#                   Area      = 'Project ABC\Portfolio'
#                   Iteration = 'Project ABC'
#                   Tags      = @('portfolio')
#                   DefaultPriority = 2
#                   RequiredFields  = @{ 'Custom.BusinessValue' = 'prompt' }
#                   ParentScope     = $null
#               }
#               FEATURE = @{
#                   Area      = 'Project ABC\Team Phoenix'
#                   Iteration = 'Project ABC\Sprint 42'
#                   ParentScope = @{
#                       Type      = 'EPIC'
#                       AreaPaths = @('Project ABC\Portfolio')
#                   }
#               }
#               USER_STORY = @{
#                   Area      = 'Project ABC\Team Phoenix\Backend'
#                   Iteration = 'Project ABC\Sprint 42'
#                   ParentScope = @{
#                       Type      = 'FEATURE'
#                       AreaPaths = @('Project ABC\Team Phoenix')
#                   }
#               }
#           }
#       }
#       Project123 = @{ ... }
#   }
#
#   $global:AzDevOpsDefaultProject = 'ProjectABC'
#
# User-facing functions:
#   az-Use-AzDevOpsProject   - switch the active project board (hydrates env
#                              vars + runs `az devops configure --defaults`)
#   az-Show-AzDevOpsProject  - print the active project + resolved env vars
#   az-Get-AzDevOpsProjects  - list every project name in the map, marking
#                              the active one
#   az-Find-AzDevOpsProject  - Out-ConsoleGridView picker over the map; emits
#                              the picked name (-Use also switches projects)
#
# Type-key normalization: lookups uppercase the type and replace spaces with
# underscores, so `'User Story'`, `'user story'`, and `'USER_STORY'` all hit
# the same map entry. Author your map keys in any of those forms.
# ============================================================================


# ---------------------------------------------------------------------------
# Private helpers (no `az-` prefix; callable from azdevops_workitems.ps1)
# ---------------------------------------------------------------------------

function Test-AzDevOpsProjectMapDefined {
    if ($null -eq $global:AzDevOpsProjectMap) {
        return $false
    }

    if ($global:AzDevOpsProjectMap -isnot [hashtable]) {
        return $false
    }

    if ($global:AzDevOpsProjectMap.Count -eq 0) {
        return $false
    }

    return $true
}


function ConvertTo-AzDevOpsTypeKey {
    param([Parameter(Mandatory)] [string] $Type)

    $upper = $Type.ToUpper()
    $key   = $upper -replace '\s+', '_'
    return $key
}


function Get-AzDevOpsActiveProjectName {
    if ($script:ActiveAzDevOpsProject) {
        return $script:ActiveAzDevOpsProject
    }

    if ($global:AzDevOpsDefaultProject) {
        return $global:AzDevOpsDefaultProject
    }

    return $null
}


function Get-AzDevOpsActiveProjectConfig {
    if (-not (Test-AzDevOpsProjectMapDefined)) {
        return $null
    }

    $name = Get-AzDevOpsActiveProjectName
    if (-not $name) {
        return $null
    }

    if (-not $global:AzDevOpsProjectMap.ContainsKey($name)) {
        return $null
    }

    $config = $global:AzDevOpsProjectMap[$name]
    return $config
}


function Get-AzDevOpsTypeConfig {
    param([Parameter(Mandatory)] [string] $Type)

    $project = Get-AzDevOpsActiveProjectConfig
    if ($null -eq $project) {
        return $null
    }

    if (-not $project.ContainsKey('Types')) {
        return $null
    }

    $types = $project['Types']
    if ($null -eq $types -or $types -isnot [hashtable]) {
        return $null
    }

    $key = ConvertTo-AzDevOpsTypeKey -Type $Type
    if (-not $types.ContainsKey($key)) {
        return $null
    }

    $entry = $types[$key]
    return $entry
}


function Get-AzDevOpsActiveProjectSlug {
    # Per-project cache key - lowercased, alnum-and-dash only. Mirrors
    # Get-AzDevOpsSchemaOrgSlug's shape so cache and schema slugs read alike.
    # Returns $null when no active project is set, which keeps
    # Get-AzDevOpsCachePaths backward-compatible with single-project use.
    $name = Get-AzDevOpsActiveProjectName
    if (-not $name) {
        return $null
    }

    $slug = ($name.ToLower() -replace '[^a-z0-9-]', '-').Trim('-')
    if (-not $slug) {
        return $null
    }

    return $slug
}


function Resolve-AzDevOpsTypeArea {
    # Type override -> board default -> $env:AZ_AREA -> $null.
    param([Parameter(Mandatory)] [string] $Type)

    $typeConfig = Get-AzDevOpsTypeConfig -Type $Type
    if ($null -ne $typeConfig -and $typeConfig.ContainsKey('Area') -and $typeConfig['Area']) {
        $area = [string]$typeConfig['Area']
        return $area
    }

    $project = Get-AzDevOpsActiveProjectConfig
    if ($null -ne $project -and $project.ContainsKey('Area') -and $project['Area']) {
        $area = [string]$project['Area']
        return $area
    }

    if ($env:AZ_AREA) {
        return $env:AZ_AREA
    }

    return $null
}


function Resolve-AzDevOpsTypeIteration {
    param([Parameter(Mandatory)] [string] $Type)

    $typeConfig = Get-AzDevOpsTypeConfig -Type $Type
    if ($null -ne $typeConfig -and $typeConfig.ContainsKey('Iteration') -and $typeConfig['Iteration']) {
        $iteration = [string]$typeConfig['Iteration']
        return $iteration
    }

    $project = Get-AzDevOpsActiveProjectConfig
    if ($null -ne $project -and $project.ContainsKey('Iteration') -and $project['Iteration']) {
        $iteration = [string]$project['Iteration']
        return $iteration
    }

    if ($env:AZ_ITERATION) {
        return $env:AZ_ITERATION
    }

    return $null
}


function Resolve-AzDevOpsTypeTags {
    # Concatenates board-level Tags with type-level Tags, dedupes, returns a
    # string[] (possibly empty). Always returns an array so callers can feed
    # it to `--fields System.Tags=...` after a `-join ';'` without nullguarding.
    param([Parameter(Mandatory)] [string] $Type)

    $combined = New-Object System.Collections.Generic.List[string]

    $project = Get-AzDevOpsActiveProjectConfig
    if ($null -ne $project -and $project.ContainsKey('Tags')) {
        foreach ($tag in @($project['Tags'])) {
            if ($tag) {
                [void]$combined.Add([string]$tag)
            }
        }
    }

    $typeConfig = Get-AzDevOpsTypeConfig -Type $Type
    if ($null -ne $typeConfig -and $typeConfig.ContainsKey('Tags')) {
        foreach ($tag in @($typeConfig['Tags'])) {
            if ($tag) {
                [void]$combined.Add([string]$tag)
            }
        }
    }

    $deduped = $combined | Select-Object -Unique
    $tags    = @($deduped)
    return $tags
}


function Resolve-AzDevOpsTypeRequiredFields {
    # Returns a hashtable of <RefName> = <value or 'prompt'> for the given
    # type, or an empty hashtable. Callers walk the entries and, for each
    # 'prompt' value, Read-Host for input; literal values pass through to
    # `az boards work-item create --fields ...`.
    param([Parameter(Mandatory)] [string] $Type)

    $typeConfig = Get-AzDevOpsTypeConfig -Type $Type
    if ($null -eq $typeConfig) {
        return @{}
    }

    if (-not $typeConfig.ContainsKey('RequiredFields')) {
        return @{}
    }

    $fields = $typeConfig['RequiredFields']
    if ($null -eq $fields -or $fields -isnot [hashtable]) {
        return @{}
    }

    return $fields
}


function Resolve-AzDevOpsTypeDefaultPriority {
    # Returns a 1-4 int when configured, $null otherwise. Callers use $null
    # to mean "fall through to the existing Read-AzDevOpsPriority prompt".
    param([Parameter(Mandatory)] [string] $Type)

    $typeConfig = Get-AzDevOpsTypeConfig -Type $Type
    if ($null -eq $typeConfig) {
        return $null
    }

    if (-not $typeConfig.ContainsKey('DefaultPriority')) {
        return $null
    }

    $value = $typeConfig['DefaultPriority']
    if ($null -eq $value) {
        return $null
    }

    $parsed = 0
    if (-not [int]::TryParse([string]$value, [ref]$parsed)) {
        return $null
    }

    if ($parsed -lt 1 -or $parsed -gt 4) {
        return $null
    }

    return $parsed
}


function Resolve-AzDevOpsTypeDefaultStoryPoints {
    # Returns a non-negative int when configured, $null otherwise. Only
    # meaningful for USER_STORY in default Agile / Scrum templates.
    param([Parameter(Mandatory)] [string] $Type)

    $typeConfig = Get-AzDevOpsTypeConfig -Type $Type
    if ($null -eq $typeConfig) {
        return $null
    }

    if (-not $typeConfig.ContainsKey('DefaultStoryPoints')) {
        return $null
    }

    $value = $typeConfig['DefaultStoryPoints']
    if ($null -eq $value) {
        return $null
    }

    $parsed = 0
    if (-not [int]::TryParse([string]$value, [ref]$parsed)) {
        return $null
    }

    if ($parsed -lt 0) {
        return $null
    }

    return $parsed
}


function Resolve-AzDevOpsTypeParentScope {
    # Normalizes ParentScope to [PSCustomObject]@{ Type = '...'; AreaPaths = @('...', ...) }.
    # Accepts AreaPath as either a single string or a list; always emits
    # AreaPaths as a string[]. Returns $null when no scope is configured.
    param([Parameter(Mandatory)] [string] $Type)

    $typeConfig = Get-AzDevOpsTypeConfig -Type $Type
    if ($null -eq $typeConfig) {
        return $null
    }

    if (-not $typeConfig.ContainsKey('ParentScope')) {
        return $null
    }

    $scope = $typeConfig['ParentScope']
    if ($null -eq $scope -or $scope -isnot [hashtable]) {
        return $null
    }

    $parentType = if ($scope.ContainsKey('Type')) {
        [string]$scope['Type']
    } else {
        ''
    }

    $rawPaths = $null
    if ($scope.ContainsKey('AreaPaths')) {
        $rawPaths = $scope['AreaPaths']
    } elseif ($scope.ContainsKey('AreaPath')) {
        $rawPaths = $scope['AreaPath']
    }

    $paths = @()
    if ($null -ne $rawPaths) {
        $paths = @($rawPaths) | Where-Object { $_ } | ForEach-Object { [string]$_ }
    }

    $normalized = [PSCustomObject]@{
        Type      = $parentType
        AreaPaths = @($paths)
    }
    return $normalized
}


function Set-AzDevOpsActiveProjectEnv {
    # Hydrates the flat env vars from a project config hashtable. Only sets
    # vars whose keys are present in the config - missing keys leave the
    # current $env:AZ_* value alone so partial configs don't blow away an
    # existing setup.
    param([Parameter(Mandatory)] [hashtable] $Config)

    if ($Config.ContainsKey('Org') -and $Config['Org']) {
        $env:AZ_DEVOPS_ORG = [string]$Config['Org']
    }

    if ($Config.ContainsKey('Project') -and $Config['Project']) {
        $env:AZ_PROJECT = [string]$Config['Project']
    }

    if ($Config.ContainsKey('Area') -and $Config['Area']) {
        $env:AZ_AREA = [string]$Config['Area']
    }

    if ($Config.ContainsKey('Iteration') -and $Config['Iteration']) {
        $env:AZ_ITERATION = [string]$Config['Iteration']
    }
}


# ---------------------------------------------------------------------------
# User-facing project-switch commands
# ---------------------------------------------------------------------------

function az-Get-AzDevOpsProjects {
    # Lists every project name in $global:AzDevOpsProjectMap with an active
    # marker. Returns [PSCustomObject]s so callers can pipe into Format-Table
    # / Where-Object / etc.
    if (-not (Test-AzDevOpsProjectMapDefined)) {
        Write-Host "(`$global:AzDevOpsProjectMap is not defined - see azdevops_projects.ps1 header for shape)" -ForegroundColor Yellow
        return
    }

    $active = Get-AzDevOpsActiveProjectName

    $rows = foreach ($name in ($global:AzDevOpsProjectMap.Keys | Sort-Object)) {
        $entry      = $global:AzDevOpsProjectMap[$name]
        $org        = if ($entry.ContainsKey('Org'))     { [string]$entry['Org'] }     else { '' }
        $project    = if ($entry.ContainsKey('Project')) { [string]$entry['Project'] } else { '' }
        $isActive   = ($active -and $name -eq $active)

        [PSCustomObject]@{
            Active  = $isActive
            Name    = $name
            Project = $project
            Org     = $org
        }
    }

    return $rows
}


function az-Show-AzDevOpsProject {
    # Prints the active project name and the four flat env vars it controls.
    # Cheap alternative to az-Connect-AzDevOps when you just want to confirm
    # which board your next az-* command will hit.
    $name = Get-AzDevOpsActiveProjectName

    Write-Host ""
    Write-Host "Active Azure DevOps project" -ForegroundColor Cyan
    Write-Host "===========================" -ForegroundColor Cyan

    if (-not $name) {
        Write-Host "  (none - `$global:AzDevOpsDefaultProject unset and az-Use-AzDevOpsProject not called)" -ForegroundColor Yellow
    } else {
        Write-Host "  Name : $name" -ForegroundColor Green
    }

    Write-Host "  AZ_DEVOPS_ORG = $env:AZ_DEVOPS_ORG"
    Write-Host "  AZ_PROJECT    = $env:AZ_PROJECT"
    Write-Host "  AZ_AREA       = $env:AZ_AREA"
    Write-Host "  AZ_ITERATION  = $env:AZ_ITERATION"
}


function az-Use-AzDevOpsProject {
    # Switches the active project board. Hydrates the four flat env vars from
    # the map entry, records the new active name in $script:ActiveAzDevOpsProject,
    # then runs `az devops configure --defaults` (skip with -SkipConfigure when
    # you only want the env vars and no `az` round-trip - useful for shell
    # startup auto-hydrate).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Name,
        [switch] $Quiet,
        [switch] $SkipConfigure
    )

    if (-not (Test-AzDevOpsProjectMapDefined)) {
        Write-Host "`$global:AzDevOpsProjectMap is not defined - set it in `$profile (see azdevops_projects.ps1 header)." -ForegroundColor Red
        return
    }

    if (-not $global:AzDevOpsProjectMap.ContainsKey($Name)) {
        $available = ($global:AzDevOpsProjectMap.Keys | Sort-Object) -join ', '
        Write-Host "Project '$Name' not in `$global:AzDevOpsProjectMap. Available: $available" -ForegroundColor Red
        return
    }

    $config = $global:AzDevOpsProjectMap[$Name]
    if ($null -eq $config -or $config -isnot [hashtable]) {
        Write-Host "`$global:AzDevOpsProjectMap['$Name'] is not a hashtable." -ForegroundColor Red
        return
    }

    Set-AzDevOpsActiveProjectEnv -Config $config
    $script:ActiveAzDevOpsProject = $Name

    if (-not $SkipConfigure) {
        if (Get-Command az -ErrorAction SilentlyContinue) {
            $configureOutput = az devops configure --defaults "organization=$env:AZ_DEVOPS_ORG" "project=$env:AZ_PROJECT" 2>&1
            if ($LASTEXITCODE -ne 0 -and -not $Quiet) {
                Write-Host "  !  az devops configure failed (env vars still set):" -ForegroundColor Yellow
                Write-Host "     $configureOutput" -ForegroundColor Yellow
            }
        } elseif (-not $Quiet) {
            Write-Host "  !  az CLI not on PATH - env vars set but `az devops configure` skipped." -ForegroundColor Yellow
        }
    }

    if (-not $Quiet) {
        Write-Host ""
        Write-Host "Switched to Azure DevOps project '$Name'" -ForegroundColor Green
        Write-Host "  AZ_DEVOPS_ORG = $env:AZ_DEVOPS_ORG"
        Write-Host "  AZ_PROJECT    = $env:AZ_PROJECT"
        Write-Host "  AZ_AREA       = $env:AZ_AREA"
        Write-Host "  AZ_ITERATION  = $env:AZ_ITERATION"
    }
}


function az-Find-AzDevOpsProject {
    # Out-ConsoleGridView picker over $global:AzDevOpsProjectMap. Grid columns
    # match the az-Get-AzDevOpsProjects row shape (Active / Name / Project /
    # Org) so users see the same surface in both views. Emits the picked
    # project name on the pipeline; -Use also calls az-Use-AzDevOpsProject so
    # one Find call switches and prints the active-project summary.
    [CmdletBinding()]
    param(
        [switch] $Use
    )

    if (-not (Test-AzDevOpsProjectMapDefined)) {
        Write-Host "(`$global:AzDevOpsProjectMap is not defined - see azdevops_projects.ps1 header for shape)" -ForegroundColor Yellow
        return
    }

    if (-not (Test-AzDevOpsGridAvailable)) {
        Write-AzDevOpsGridUnavailable -CommandName 'az-Find-AzDevOpsProject'
        return
    }

    $rows = az-Get-AzDevOpsProjects
    if ($null -eq $rows -or @($rows).Count -eq 0) {
        Write-Host '(no projects defined in $global:AzDevOpsProjectMap)' -ForegroundColor Yellow
        return
    }

    $picked = Read-AzDevOpsGridPick -Rows $rows -Title 'Pick Azure DevOps project'
    if ($null -eq $picked) {
        return $null
    }

    $pickedName = [string]$picked.Name

    if ($Use) {
        az-Use-AzDevOpsProject -Name $pickedName
        return
    }

    return $pickedName
}


# ---------------------------------------------------------------------------
# Auto-hydrate on shell startup. Runs once when this file is dot-sourced from
# powcuts_home.ps1. Silent + no `az devops configure` round-trip (-Quiet
# -SkipConfigure) so a fresh terminal stays fast and quiet; users who want
# `az boards` defaults pinned for the current shell run az-Use-AzDevOpsProject
# (or az-Connect-AzDevOps) explicitly.
# ---------------------------------------------------------------------------

if ((Test-AzDevOpsProjectMapDefined) -and $global:AzDevOpsDefaultProject) {
    if ($global:AzDevOpsProjectMap.ContainsKey($global:AzDevOpsDefaultProject)) {
        az-Use-AzDevOpsProject -Name $global:AzDevOpsDefaultProject -Quiet -SkipConfigure
    }
}
