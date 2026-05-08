# ---------------------------------------------------------------------------
# Azure DevOps data-plane wrapper layer.
#
# Every `az boards ...` invocation in the bashcuts codebase routes through one
# of the wrappers in this file so higher-level functions in azdevops_workitems
# .ps1 / pow_az_cli.ps1 stay decoupled from `az` argument shapes, JSON
# deserialization, and stderr handling. Future caching, retry, or alternative
# transport changes are a one-file edit.
#
# Conventions:
#   - Every wrapper returns the canonical { Json, Error, ExitCode } envelope
#     produced by Invoke-AzDevOpsAzJson, leaving ConvertFrom-Json to the
#     caller. This matches the existing helper shape and keeps wrappers thin.
#   - Session/admin calls (az login, az account show, az extension *,
#     az devops configure) are NOT wrapped here - they live in
#     azdevops_workitems.ps1 alongside Connect-AzDevOps.
# ---------------------------------------------------------------------------


function Invoke-AzDevOpsAzJson {
    # Generic wrapper around `az ... --output json` that captures stdout JSON
    # and stderr text separately. The canonical JSON+error path used by every
    # other data-plane wrapper in this file.
    param([Parameter(Mandatory)] [string[]] $ArgList)

    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $json = & az @ArgList --output json 2>$stderrFile
        $exit = $LASTEXITCODE
        $stderr = if (Test-Path -LiteralPath $stderrFile) {
            (Get-Content -LiteralPath $stderrFile -Raw)
        } else {
            ''
        }
    } finally {
        Remove-Item -LiteralPath $stderrFile -ErrorAction SilentlyContinue
    }

    if ($null -eq $stderr) {
        $stderr = ''
    }

    return [PSCustomObject]@{
        Json     = $json
        Error    = $stderr
        ExitCode = $exit
    }
}


function Invoke-AzDevOpsBoardsQuery {
    # Runs a WIQL query via `az boards query --wiql <Wiql>`. Returns the
    # canonical { Json, Error, ExitCode } envelope.
    param([Parameter(Mandatory)] [string] $Wiql)

    $result = Invoke-AzDevOpsAzJson -ArgList @('boards', 'query', '--wiql', $Wiql)
    return $result
}


function Get-AzDevOpsIterationList {
    # `az boards iteration project list --depth <N>` wrapper.
    param([int] $Depth = 5)

    $result = Invoke-AzDevOpsAzJson -ArgList @('boards', 'iteration', 'project', 'list', '--depth', "$Depth")
    return $result
}


function Get-AzDevOpsAreaList {
    # `az boards area project list --depth <N>` wrapper.
    param([int] $Depth = 5)

    $result = Invoke-AzDevOpsAzJson -ArgList @('boards', 'area', 'project', 'list', '--depth', "$Depth")
    return $result
}


function New-AzDevOpsWorkItem {
    # `az boards work-item create` wrapper. Title and Type are required; every
    # other parameter is optional so callers can populate only what they have.
    # Pass field overrides as -Fields @('Microsoft.VSTS.Common.Priority=2', ...).
    # Returns the canonical { Json, Error, ExitCode } envelope; the caller
    # ConvertFrom-Json's the created work-item shape.
    param(
        [Parameter(Mandatory)] [string]   $Type,
        [Parameter(Mandatory)] [string]   $Title,
        [string]   $Description,
        [string]   $AssignedTo,
        [string]   $Project,
        [string]   $Area,
        [string]   $Iteration,
        [string[]] $Fields,
        [switch]   $Open
    )

    $argList = @(
        'boards', 'work-item', 'create',
        '--type',  $Type,
        '--title', $Title
    )

    if ($Description) {
        $argList += @('--description', $Description)
    }

    if ($AssignedTo) {
        $argList += @('--assigned-to', $AssignedTo)
    }

    if ($Project) {
        $argList += @('--project', $Project)
    }

    if ($Area) {
        $argList += @('--area', $Area)
    }

    if ($Iteration) {
        $argList += @('--iteration', $Iteration)
    }

    if ($Fields -and $Fields.Count -gt 0) {
        $argList += '--fields'
        $argList += $Fields
    }

    if ($Open) {
        $argList += '--open'
    }

    $result = Invoke-AzDevOpsAzJson -ArgList $argList
    return $result
}


function Add-AzDevOpsWorkItemRelation {
    # `az boards work-item relation add` wrapper. RelationType is the literal
    # az string ('parent', 'child', 'related', etc.).
    param(
        [Parameter(Mandatory)] [int]    $Id,
        [Parameter(Mandatory)] [int]    $TargetId,
        [Parameter(Mandatory)] [string] $RelationType
    )

    $result = Invoke-AzDevOpsAzJson -ArgList @(
        'boards', 'work-item', 'relation', 'add',
        '--id',            "$Id",
        '--relation-type', $RelationType,
        '--target-id',     "$TargetId"
    )
    return $result
}


function Get-AzDevOpsWorkItemTypeDefinition {
    # `az boards work-item-type show --type <T>` wrapper. Returns the type's
    # field-instance definitions inside the canonical envelope so callers can
    # walk fieldInstances[] without re-doing the az + parse dance.
    param([Parameter(Mandatory)] [string] $Type)

    $result = Invoke-AzDevOpsAzJson -ArgList @('boards', 'work-item-type', 'show', '--type', $Type)
    return $result
}
