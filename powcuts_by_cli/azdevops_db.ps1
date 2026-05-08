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
#     azdevops_workitems.ps1 alongside az-Connect-AzDevOps.
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


function Get-AzDevOpsClassificationList {
    # `az boards <iteration|area> project list --depth <N>` wrapper. Replaces
    # the prior Iteration/Area twin pair so callers express the kind via -Kind
    # rather than choosing between two near-identical functions (CLAUDE.md
    # extract-repeated-branches rule for parallel function pairs).
    param(
        [Parameter(Mandatory)] [ValidateSet('Iteration', 'Area')] [string] $Kind,
        [int] $Depth = 5
    )

    $subcommand = $Kind.ToLower()
    $result = Invoke-AzDevOpsAzJson -ArgList @('boards', $subcommand, 'project', 'list', '--depth', "$Depth")
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

    # Reject `--`-prefixed or otherwise malformed field tokens so a stray
    # value cannot escape the variadic --fields slot and be reinterpreted
    # by az's argparse as a new flag (defense in depth — callers are
    # interactive and self-trusted but the class of bug is worth killing).
    foreach ($f in $Fields) {
        if ($f -notmatch '^[A-Za-z][A-Za-z0-9_.]*=') {
            throw "Invalid field assignment '$f' (expected 'Field.Name=value')."
        }
    }

    $argList = @(
        'boards', 'work-item', 'create',
        '--type',  $Type,
        '--title', $Title
    )

    $optionalFlags = [ordered]@{
        '--description' = $Description
        '--assigned-to' = $AssignedTo
        '--project'     = $Project
        '--area'        = $Area
        '--iteration'   = $Iteration
    }

    foreach ($kv in $optionalFlags.GetEnumerator()) {
        if ($kv.Value) {
            $argList += @($kv.Key, $kv.Value)
        }
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
