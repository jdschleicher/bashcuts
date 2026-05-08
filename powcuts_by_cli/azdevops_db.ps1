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
#
# Diagnostic echoes:
#   - Every call through Invoke-AzDevOpsAzJson echoes the assembled `az`
#     command line before invoking and the elapsed-time / exit-code summary
#     after the call returns. WIQL queries additionally echo the WIQL string
#     as its own labeled line via Invoke-AzDevOpsBoardsQuery so the SQL-ish
#     text isn't buried inside the `--wiql` arg of the command echo.
#   - All echoes go through Write-Host (host stream only) so the canonical
#     { Json, Error, ExitCode } envelope is unaffected for callers that
#     consume the function's return value.
# ---------------------------------------------------------------------------


function Write-AzDevOpsQueryEcho {
    # Private helper - emits a single status line for query echoes (the WIQL
    # string, the assembled `az` command, and the post-call elapsed/exit
    # summary). Lifts the indent and arrow glyph into one place so the
    # visual style stays consistent across callers and a future tweak
    # (different glyph, different indent, different default color) is a
    # one-line edit. Uses an unapproved-verb-free name (Write-* is approved)
    # but is treated as private to azdevops_db.ps1 / azdevops_workitems.ps1.
    param(
        [Parameter(Mandatory)] [string] $Message,
        [string] $Color = 'DarkCyan'
    )

    $indent    = '  '
    $arrowChar = "$([char]0x21B3)"   # downwards arrow with tip rightwards
    $line      = "$indent$arrowChar $Message"

    Write-Host $line -ForegroundColor $Color
}


function Format-AzDevOpsCommandDisplay {
    # Private helper - renders an `az` ArgList into a human-readable single
    # line for echo output. Args containing whitespace or quotes get wrapped
    # in double quotes (with embedded quotes escaped); plain args stay
    # unquoted. Appends `--output json` to match what Invoke-AzDevOpsAzJson
    # actually runs so a copy-pasted line reproduces the call faithfully.
    param([Parameter(Mandatory)] [string[]] $ArgList)

    $displayParts = @()
    foreach ($a in $ArgList) {
        $needsQuote = $a -match '\s|"'
        if ($needsQuote) {
            $escaped = $a -replace '"', '\"'
            $displayParts += "`"$escaped`""
        } else {
            $displayParts += $a
        }
    }

    $command = "az $($displayParts -join ' ') --output json"
    return $command
}


function Get-AzDevOpsCommandHeadline {
    # Private helper - extracts a short subcommand-only headline from an `az`
    # ArgList by joining tokens up to (but not including) the first `--flag`
    # arg. Used for the post-call elapsed/exit summary line so the trailing
    # echo stays compact (e.g. `az boards query (0.8s, exit=0)`) instead of
    # repeating the full command which is already on the line above.
    param([Parameter(Mandatory)] [string[]] $ArgList)

    $parts = @('az')
    foreach ($a in $ArgList) {
        if ($a -like '--*') {
            break
        }
        $parts += $a
    }

    $headline = $parts -join ' '
    return $headline
}


function Invoke-AzDevOpsAzJson {
    # Generic wrapper around `az ... --output json` that captures stdout JSON
    # and stderr text separately. The canonical JSON+error path used by every
    # other data-plane wrapper in this file. Emits diagnostic before/after
    # echoes so every query is visible in the terminal alongside its elapsed
    # time and exit code.
    #
    # When $env:AZ_DEVOPS_ORG / $env:AZ_PROJECT are set and the caller has not
    # already supplied --organization / --project, we inject them so every
    # wrapper auto-scopes to the bashcuts env-var contract instead of relying
    # on `az devops configure --defaults`. Explicit caller flags always win
    # (e.g. New-AzDevOpsWorkItem passes its own --project). The echo prints
    # the post-injection command so the user sees the actual flags being
    # sent to az, not the pre-scoped ArgList from the caller.
    param([Parameter(Mandatory)] [string[]] $ArgList)

    $scopedArgs = @($ArgList)

    if ($env:AZ_DEVOPS_ORG -and ($scopedArgs -notcontains '--organization')) {
        $scopedArgs += @('--organization', $env:AZ_DEVOPS_ORG)
    }

    if ($env:AZ_PROJECT -and ($scopedArgs -notcontains '--project')) {
        $scopedArgs += @('--project', $env:AZ_PROJECT)
    }

    $commandDisplay = Format-AzDevOpsCommandDisplay -ArgList $scopedArgs
    Write-AzDevOpsQueryEcho -Message $commandDisplay -Color 'DarkCyan'

    $stderrFile = [System.IO.Path]::GetTempFileName()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $json = & az @scopedArgs --output json 2>$stderrFile
        $exit = $LASTEXITCODE
        $stderr = if (Test-Path -LiteralPath $stderrFile) {
            (Get-Content -LiteralPath $stderrFile -Raw)
        } else {
            ''
        }
    } finally {
        Remove-Item -LiteralPath $stderrFile -ErrorAction SilentlyContinue
    }
    $sw.Stop()

    $elapsed  = '{0:N1}s' -f $sw.Elapsed.TotalSeconds
    $headline = Get-AzDevOpsCommandHeadline -ArgList $scopedArgs

    if ($exit -eq 0) {
        $summary = "$headline ($elapsed, exit=0)"
        Write-AzDevOpsQueryEcho -Message $summary -Color 'DarkGreen'
    } else {
        $summary = "$headline ($elapsed, exit=$exit)"
        Write-AzDevOpsQueryEcho -Message $summary -Color 'Red'
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
    # canonical { Json, Error, ExitCode } envelope. Echoes the WIQL string
    # to the terminal before delegating so the query is visible as its own
    # labeled line, separate from the `--wiql` arg embedded in the command
    # echo emitted by Invoke-AzDevOpsAzJson.
    param([Parameter(Mandatory)] [string] $Wiql)

    Write-AzDevOpsQueryEcho -Message "WIQL: $Wiql" -Color 'DarkCyan'

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
