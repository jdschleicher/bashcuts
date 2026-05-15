# ============================================================================
# Azure DevOps — Paths & query files
# ============================================================================
# Filesystem layout under $HOME/.bashcuts-az-devops-app/ (cache/, config/,
# schema/) and the WIQL query defaults seeded into config/queries/. Pure
# plumbing — no public az-* functions live here.
#
# Loaded by powcuts_home.ps1. See azdevops_auth.ps1 for the master docstring.

# ---------------------------------------------------------------------------
# Single hidden parent folder under $HOME that contains every AzDevOps state
# subdirectory (cache/, config/, schema/). Consolidates what used to be three
# separate top-level dotfolders (.bashcuts-cache, .bashcuts-config, .bashcuts)
# into one easy-to-find location.
# ---------------------------------------------------------------------------

function Get-AzDevOpsAppRoot {
    $root = Join-Path $HOME '.bashcuts-az-devops-app'
    return $root
}


# ---------------------------------------------------------------------------
# Local cache + scheduled refresh
#
# Cache directory: $HOME/.bashcuts-az-devops-app/cache/
#   assigned.json   - items where [System.AssignedTo] = @Me
#   mentions.json   - items where the user's email (or '@') appears in
#                     [System.History] (best-effort - WIQL has no first-class
#                     "@-mention" predicate)
#   hierarchy.json  - WorkItemLinks tree of Epic/Feature/User Story rows
#                     in the configured project (parent->child Hierarchy-Forward)
#   last-sync.json  - { Timestamp (round-trip), Counts: {dataset: rows} }
#   sync.log        - append-only, rotated to sync.log.1 at ~1 MB
#
# Public functions:
#   az-Sync-AzDevOpsCache              - one-shot refresh of all three datasets
#   az-Get-AzDevOpsCacheStatus         - prints freshness vs 6h threshold
#   az-Register-AzDevOpsSyncSchedule   - Task Scheduler (Windows) or crontab
#                                      (macOS/Linux) entry, every 5 hours
#   az-Unregister-AzDevOpsSyncSchedule - removes the schedule on either OS
# ---------------------------------------------------------------------------

function Get-AzDevOpsCachePathsForSlug {
    # Path-building primitive: hands back the cache file set for the given
    # project slug. When $Slug is empty/null, returns the legacy unsegmented
    # layout so single-project users (no $global:AzDevOpsProjectMap) keep
    # their existing on-disk layout.
    param([string] $Slug)

    $rootDir = Join-Path (Get-AzDevOpsAppRoot) 'cache'

    $cacheDir = if ($Slug) {
        Join-Path $rootDir $Slug
    } else {
        $rootDir
    }

    return [PSCustomObject]@{
        Dir        = $cacheDir
        Assigned   = Join-Path $cacheDir 'assigned.json'
        Mentions   = Join-Path $cacheDir 'mentions.json'
        Hierarchy  = Join-Path $cacheDir 'hierarchy.json'
        Iterations = Join-Path $cacheDir 'iterations.json'
        Areas      = Join-Path $cacheDir 'areas.json'
        LastSync   = Join-Path $cacheDir 'last-sync.json'
        Log        = Join-Path $cacheDir 'sync.log'
    }
}


function New-AzDevOpsDirectoryIfMissing {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}


function Get-AzDevOpsCachePaths {
    # Cache directory is segmented by active project slug when one is set, so
    # az-Use-AzDevOpsProject can flip boards without contaminating cached
    # hierarchy / assigned / mentions data across projects. Falls back to the
    # legacy unsegmented layout when no project map is active, which keeps
    # single-project users unaffected (no migration needed for them).
    $slug = $null
    if (Get-Command Get-AzDevOpsActiveProjectSlug -ErrorAction SilentlyContinue) {
        $slug = Get-AzDevOpsActiveProjectSlug
    }

    $paths = Get-AzDevOpsCachePathsForSlug -Slug $slug
    return $paths
}


function Initialize-AzDevOpsCacheDir {
    $paths = Get-AzDevOpsCachePaths
    New-AzDevOpsDirectoryIfMissing -Path $paths.Dir
    return $paths
}


# ---------------------------------------------------------------------------
# User-machine config (queries)
#
# Config directory: $HOME/.bashcuts-az-devops-app/config/queries/
#   epics.wiql         - WIQL for the Epic tier of the hierarchy. Filtered by
#                        [System.AreaPath] UNDER '{{AZ_AREA}}' and category
#                        group 'Microsoft.EpicCategory'.
#   features.wiql      - WIQL for the Feature tier. Same area filter, category
#                        group 'Microsoft.FeatureCategory'.
#   user-stories.wiql  - WIQL for the User Story tier. Same area filter,
#                        category group 'Microsoft.RequirementCategory'
#                        (covers User Story / Product Backlog Item /
#                        Requirement / Issue across process templates).
#
# The three files together drive the 'hierarchy' dataset in
# Get-AzDevOpsSyncDatasets: az-Sync-AzDevOpsCache fires one WIQL per tier and
# merges the results into hierarchy.json. Splitting per-tier dodges the
# combined-IN-GROUP query's partial-result behavior under large projects and
# lets users tune each tier's filter independently.
#
# Placeholder tokens (substituted at read time by Get-AzDevOpsWiql):
#   {{AZ_AREA}}  - $env:AZ_AREA. Keeps the files portable across machines /
#                  projects without forcing users to hard-code their own area.
# ---------------------------------------------------------------------------

$script:AzDevOpsAreaToken      = '{{AZ_AREA}}'
$script:AzDevOpsUserEmailToken = '{{AZ_USER_EMAIL}}'

$script:AzDevOpsDefaultEpicsWiql = @"
Select [System.Id], [System.Title], [System.WorkItemType], [System.State], [System.IterationPath], [System.AreaPath], [System.Parent] From WorkItems Where [System.AreaPath] UNDER '{{AZ_AREA}}' AND [System.WorkItemType] IN GROUP 'Microsoft.EpicCategory'
"@

$script:AzDevOpsDefaultFeaturesWiql = @"
Select [System.Id], [System.Title], [System.WorkItemType], [System.State], [System.IterationPath], [System.AreaPath], [System.Parent] From WorkItems Where [System.AreaPath] UNDER '{{AZ_AREA}}' AND [System.WorkItemType] IN GROUP 'Microsoft.FeatureCategory'
"@

$script:AzDevOpsDefaultUserStoriesWiql = @"
Select [System.Id], [System.Title], [System.WorkItemType], [System.State], [System.IterationPath], [System.AreaPath], [System.Parent] From WorkItems Where [System.AreaPath] UNDER '{{AZ_AREA}}' AND [System.WorkItemType] IN GROUP 'Microsoft.RequirementCategory'
"@

$script:AzDevOpsDefaultAssignedWiql = @"
Select [System.Id], [System.Title], [System.WorkItemType], [System.State], [System.IterationPath], [System.ChangedDate], [Microsoft.VSTS.Common.Priority] From WorkItems Where [System.AssignedTo] = @Me
"@

$script:AzDevOpsDefaultMentionsWiql = @"
Select [System.Id], [System.Title], [System.WorkItemType], [System.State], [System.ChangedBy], [System.AreaPath], [System.ChangedDate] From WorkItems Where [System.History] Contains '{{AZ_USER_EMAIL}}'
"@


function Get-AzDevOpsConfigPaths {
    $configDir  = Join-Path (Get-AzDevOpsAppRoot) 'config'
    $queriesDir = Join-Path $configDir 'queries'

    return [PSCustomObject]@{
        Dir              = $configDir
        QueriesDir       = $queriesDir
        EpicsQuery       = Join-Path $queriesDir 'epics.wiql'
        FeaturesQuery    = Join-Path $queriesDir 'features.wiql'
        UserStoriesQuery = Join-Path $queriesDir 'user-stories.wiql'
        AssignedQuery    = Join-Path $queriesDir 'assigned.wiql'
        MentionsQuery    = Join-Path $queriesDir 'mentions.wiql'
    }
}


function Get-AzDevOpsQueryDefaults {
    # Single source of truth for all WIQL files: their logical name (also the
    # -Name parameter for Get-AzDevOpsWiql), their on-disk path, and the
    # default WIQL seeded on first run. Initialize, read, sync, and the
    # user-facing open shortcut all iterate this list, so adding a new query
    # later is a one-place edit.
    $paths = Get-AzDevOpsConfigPaths

    $defaults = @(
        [PSCustomObject]@{
            Name    = 'epics'
            Path    = $paths.EpicsQuery
            Default = $script:AzDevOpsDefaultEpicsWiql
        },
        [PSCustomObject]@{
            Name    = 'features'
            Path    = $paths.FeaturesQuery
            Default = $script:AzDevOpsDefaultFeaturesWiql
        },
        [PSCustomObject]@{
            Name    = 'user-stories'
            Path    = $paths.UserStoriesQuery
            Default = $script:AzDevOpsDefaultUserStoriesWiql
        },
        [PSCustomObject]@{
            Name    = 'assigned'
            Path    = $paths.AssignedQuery
            Default = $script:AzDevOpsDefaultAssignedWiql
        },
        [PSCustomObject]@{
            Name    = 'mentions'
            Path    = $paths.MentionsQuery
            Default = $script:AzDevOpsDefaultMentionsWiql
        }
    )

    return $defaults
}


function Initialize-AzDevOpsQueryFiles {
    # Idempotent: creates the queries directory if absent and seeds each
    # default .wiql file only when the file does not already exist. Returns
    # the resolved paths plus per-file Seeded flags so callers (the
    # az-Connect-AzDevOps step and az-Open-AzDevOpsHierarchyWiqls) can print
    # consistent status lines.
    $paths = Get-AzDevOpsConfigPaths
    New-AzDevOpsDirectoryIfMissing -Path $paths.QueriesDir

    $defaults = Get-AzDevOpsQueryDefaults
    $seeded = New-Object System.Collections.Generic.List[PSCustomObject]

    foreach ($entry in $defaults) {
        $wasSeeded = $false
        if (-not (Test-Path -LiteralPath $entry.Path)) {
            Set-Content -LiteralPath $entry.Path -Value $entry.Default -Encoding UTF8
            $wasSeeded = $true
        }

        $seeded.Add([PSCustomObject]@{
            Name   = $entry.Name
            Path   = $entry.Path
            Seeded = $wasSeeded
        })
    }

    return [PSCustomObject]@{
        Paths  = $paths
        Seeded = @($seeded)
    }
}


function Get-AzDevOpsHierarchyQueryNames {
    $hierarchyNames = @('epics', 'features', 'user-stories')
    return $hierarchyNames
}


function Get-AzDevOpsWiql {
    # Reads a named WIQL file from the user-machine config dir, substituting
    # known placeholder tokens. Defensively seeds defaults so callers don't
    # need to remember to call Initialize-AzDevOpsQueryFiles first.
    #
    # Tokens substituted at read time:
    #   {{AZ_AREA}}       - $env:AZ_AREA (throws if missing for area-filtered queries)
    #   {{AZ_USER_EMAIL}} - "@$env:AZ_USER_EMAIL" when set, otherwise "@" fallback
    param(
        [Parameter(Mandatory)]
        [ValidateSet('epics', 'features', 'user-stories', 'assigned', 'mentions')]
        [string] $Name
    )

    $init  = Initialize-AzDevOpsQueryFiles
    $entry = $init.Seeded | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    $path  = $entry.Path

    $rawContent = Get-Content -LiteralPath $path -Raw
    $wiql       = $rawContent.Trim()

    if ($wiql -match [regex]::Escape($script:AzDevOpsAreaToken)) {
        if ([string]::IsNullOrWhiteSpace($env:AZ_AREA)) {
            throw "Get-AzDevOpsWiql: `$env:AZ_AREA must be set to substitute $script:AzDevOpsAreaToken in $path."
        }

        # Escape single quotes — area paths with apostrophes would otherwise
        # break out of the [System.AreaPath] UNDER '...' WIQL literal.
        $areaEscaped = $env:AZ_AREA.Replace("'", "''")
        $wiql        = $wiql.Replace($script:AzDevOpsAreaToken, $areaEscaped)
    }

    if ($wiql -match [regex]::Escape($script:AzDevOpsUserEmailToken)) {
        $emailRaw   = if ($env:AZ_USER_EMAIL) {
            "@$env:AZ_USER_EMAIL"
        } else {
            '@'
        }
        # Escape single quotes for WIQL string-literal safety — same rationale
        # as $areaEscaped above.
        $emailValue = $emailRaw.Replace("'", "''")
        $wiql       = $wiql.Replace($script:AzDevOpsUserEmailToken, $emailValue)
    }

    return $wiql
}


function Invoke-AzDevOpsHierarchyQueries {
    # Runs the three per-tier hierarchy WIQLs (epics, features, user-stories)
    # sequentially, each filtered by [System.AreaPath] UNDER '{{AZ_AREA}}',
    # and returns the merged work-item array in the same { Json, Error,
    # ExitCode } envelope that Invoke-AzDevOpsBoardsQuery emits. Splitting the
    # prior single-query hierarchy into three category-scoped calls dodges the
    # combined IN-GROUP query's partial-result behavior under larger projects
    # and lets each tier's filter be tuned independently.
    #
    # On the first failing tier we short-circuit and return the underlying
    # exit code + stderr (prefixed with the tier name) so Invoke-AzDevOpsAzDataset
    # treats the dataset as failed and skips the cache write.

    $names = Get-AzDevOpsHierarchyQueryNames
    $merged = New-Object System.Collections.Generic.List[object]

    foreach ($name in $names) {
        $wiql = Get-AzDevOpsWiql -Name $name
        $result = Invoke-AzDevOpsBoardsQuery -Wiql $wiql

        if ($result.ExitCode -ne 0) {
            $errEnvelope = [PSCustomObject]@{
                Json     = ''
                Error    = "[$name] $($result.Error)"
                ExitCode = $result.ExitCode
            }
            return $errEnvelope
        }

        try {
            $parsed = $result.Json | ConvertFrom-Json
        }
        catch {
            $parseErrEnvelope = [PSCustomObject]@{
                Json     = ''
                Error    = "[$name] parse failed: $($_.Exception.Message)"
                ExitCode = 1
            }
            return $parseErrEnvelope
        }

        foreach ($item in @($parsed)) {
            if ($null -ne $item) {
                $merged.Add($item)
            }
        }
    }

    # Invoke-AzDevOpsAzDataset re-parses + re-serializes Json before writing
    # the cache, and it applies its own -AsArray when the descriptor sets
    # AsArray=$true (the hierarchy descriptor does). The -Depth 10 here is
    # only for the in-flight envelope passed back to that helper; downstream
    # depth is governed by the descriptor's JsonDepth.
    $mergedJson = ConvertTo-Json -InputObject @($merged) -Depth 10 -AsArray

    $envelope = [PSCustomObject]@{
        Json     = $mergedJson
        Error    = ''
        ExitCode = 0
    }
    return $envelope
}


function Write-AzDevOpsCacheFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Content
    )
    $tmp = "$Path.tmp"
    Set-Content -LiteralPath $tmp -Value $Content -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}


function Write-AzDevOpsSyncLog {
    param([Parameter(Mandatory)] [string] $Message)
    $paths = Get-AzDevOpsCachePaths
    if (-not (Test-Path -LiteralPath $paths.Dir)) { return }

    if (Test-Path -LiteralPath $paths.Log) {
        $size = (Get-Item -LiteralPath $paths.Log).Length
        if ($size -gt 1MB) {
            Move-Item -LiteralPath $paths.Log -Destination "$($paths.Log).1" -Force
        }
    }
    $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    Add-Content -LiteralPath $paths.Log -Value "$stamp $Message"
}
