# ---------------------------------------------------------------------------
# Azure DevOps data-plane wrapper layer.
#
# Every `az boards ...` invocation in the bashcuts codebase routes through one
# of the wrappers in this file so higher-level functions in azdevops_workitems
# .ps1 stay decoupled from `az` argument shapes, JSON deserialization, and
# stderr handling. Future caching, retry, or alternative transport changes are
# a one-file edit.
#
# Conventions:
#   - Every wrapper returns the canonical { Json, Error, ExitCode } envelope
#     produced by Invoke-AzDevOpsAzJson, leaving ConvertFrom-Json to the
#     caller. This matches the existing helper shape and keeps wrappers thin.
#   - Session/admin calls (az login, az account show, az extension *,
#     az devops configure) are NOT wrapped here - they live in
#     azdevops_auth.ps1 alongside az-Connect-AzDevOps.
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
    # but is treated as private to azdevops_db.ps1 / azdevops_*.ps1 family.
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


function Get-AzDevOpsConfiguredDefaults {
    # Reads the current `az devops configure --defaults` values (org URL and
    # project name). Returns [PSCustomObject]@{ Org = '...'; Project = '...' }
    # with empty strings when not configured. Results are cached per-session so
    # the az invocation runs at most once per PowerShell session.
    if ($null -ne $global:AzDevOpsCachedConfiguredDefaults) {
        return $global:AzDevOpsCachedConfiguredDefaults
    }

    $lines = az devops configure --list 2>$null
    $org     = ''
    $project = ''

    if ($LASTEXITCODE -eq 0 -and $lines) {
        $orgLine     = @($lines) | Where-Object { $_ -match '^\s*organization\s*=' } | Select-Object -First 1
        $projectLine = @($lines) | Where-Object { $_ -match '^\s*project\s*='      } | Select-Object -First 1

        if ($orgLine) {
            $org = ($orgLine -split '=', 2)[1].Trim()
        }

        if ($projectLine) {
            $project = ($projectLine -split '=', 2)[1].Trim()
        }
    }

    $result = [PSCustomObject]@{ Org = $org; Project = $project }
    $global:AzDevOpsCachedConfiguredDefaults = $result
    return $result
}


function Invoke-AzDevOpsAzJson {
    # Generic wrapper around `az ... --output json` that captures stdout JSON
    # and stderr text separately. The canonical JSON+error path used by every
    # other data-plane wrapper in this file. Emits diagnostic before/after
    # echoes so every query is visible in the terminal alongside its elapsed
    # time and exit code.
    #
    # Org and project scoping rely on `az devops configure --defaults` set in
    # the user's Microsoft profile (via az-Connect-AzDevOps or manually). No
    # flags are auto-injected here; callers that need explicit scoping pass
    # --organization / --project themselves.
    param(
        [Parameter(Mandatory)] [string[]] $ArgList
    )

    $commandDisplay = Format-AzDevOpsCommandDisplay -ArgList $ArgList
    Write-AzDevOpsQueryEcho -Message $commandDisplay -Color 'DarkCyan'

    $stderrFile = [System.IO.Path]::GetTempFileName()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
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
    $sw.Stop()

    $elapsed  = '{0:N1}s' -f $sw.Elapsed.TotalSeconds
    $headline = Get-AzDevOpsCommandHeadline -ArgList $ArgList

    $summary      = "$headline ($elapsed, exit=$exit)"
    $summaryColor = if ($exit -eq 0) {
        'DarkGreen'
    } else {
        'Red'
    }

    Write-AzDevOpsQueryEcho -Message $summary -Color $summaryColor

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


function Add-AzDevOpsDiscussionComment {
    # `az boards work-item update --id <id> --discussion <body>` wrapper. Adds
    # a comment to the Discussion / History thread of a work item. Returns the
    # canonical { Json, Error, ExitCode } envelope; the parsed JSON is the
    # updated work-item shape (same as `az boards work-item update`). The
    # always-on echo from Invoke-AzDevOpsAzJson surfaces the assembled az
    # command so the user can see exactly what was posted.
    param(
        [Parameter(Mandatory)] [int]    $Id,
        [Parameter(Mandatory)] [string] $Body
    )

    $result = Invoke-AzDevOpsAzJson -ArgList @(
        'boards', 'work-item', 'update',
        '--id',         "$Id",
        '--discussion', $Body
    )
    return $result
}


function Get-AzDevOpsWorkItemTypeDefinition {
    # `az devops invoke --area wit --resource workitemtypes` wrapper. Returns
    # the type's field-instance definitions inside the canonical envelope so
    # callers can walk fieldInstances[] without re-doing the az + parse dance.
    #
    # The azure-devops extension does NOT expose a `boards work-item-type`
    # subgroup, so we go through `az devops invoke` (REST passthrough) against
    # the WIT workitemtypes endpoint. Project scope rides in --route-parameters
    # (the az devops invoke REST path) rather than the top-level --project flag.
    param([Parameter(Mandatory)] [string] $Type)

    $apiVersion = '7.1'
    $defaults   = Get-AzDevOpsConfiguredDefaults
    $project    = $defaults.Project

    $result = Invoke-AzDevOpsAzJson -ArgList @(
        'devops', 'invoke',
        '--area',             'wit',
        '--resource',         'workitemtypes',
        '--route-parameters', "project=$project", "type=$Type",
        '--api-version',      $apiVersion
    )
    return $result
}
