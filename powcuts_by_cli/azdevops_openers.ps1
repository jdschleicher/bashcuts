# ============================================================================
# Azure DevOps — File / folder openers
# ============================================================================
# Direct openers for every folder and file under
# $HOME/.bashcuts-az-devops-app/. Every public function below resolves its
# path through the existing Get-AzDevOps* helpers so cache openers auto-follow
# the active project slice and the schema opener auto-follows $env:AZ_DEVOPS_ORG.
#
# Discovery: tab-tab on `az-Open-AzDevOps` in any pwsh session.
#
# Loaded by powcuts_home.ps1. See azdevops_auth.ps1 for the master docstring.

function Open-AzDevOpsPathIfExists {
    # Private helper used by every public az-Open-AzDevOps* function in this
    # section. Centralizes the "exists? -> Start-Process, missing? -> yellow
    # hint + return" branch so the 15 public openers stay one-liners. Uses an
    # unapproved verb on purpose - it isn't user-facing, so it doesn't need to
    # pass Get-Verb.
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $HintMessage
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "Not found: $Path" -ForegroundColor Yellow
        Write-Host "  $HintMessage" -ForegroundColor Yellow
        return
    }

    Write-Host "Opening $Path" -ForegroundColor DarkGray
    Start-Process $Path
}


# --- Folder openers (4) ----------------------------------------------------

function az-Open-AzDevOpsAppRoot {
    $root = Get-AzDevOpsAppRoot
    Open-AzDevOpsPathIfExists -Path $root `
        -HintMessage "Run az-Connect-AzDevOps to scaffold the app root."
}


function az-Open-AzDevOpsCacheDir {
    $paths = Get-AzDevOpsCachePaths
    Open-AzDevOpsPathIfExists -Path $paths.Dir `
        -HintMessage "Run az-Sync-AzDevOpsCache to populate the active project's cache slice."
}


function az-Open-AzDevOpsConfigDir {
    $paths = Get-AzDevOpsConfigPaths
    Open-AzDevOpsPathIfExists -Path $paths.QueriesDir `
        -HintMessage "Run az-Connect-AzDevOps (or az-Open-AzDevOpsHierarchyWiqls) to seed the default WIQL files."
}


function az-Open-AzDevOpsSchemaDir {
    $paths = Get-AzDevOpsSchemaPaths
    Open-AzDevOpsPathIfExists -Path $paths.Dir `
        -HintMessage "Run az-Initialize-AzDevOpsSchema (or az-Edit-AzDevOpsSchema) to create the schema directory."
}


# --- Cache file openers (7) ------------------------------------------------

function az-Open-AzDevOpsAssignedCache {
    $paths = Get-AzDevOpsCachePaths
    Open-AzDevOpsPathIfExists -Path $paths.Assigned `
        -HintMessage "Run az-Sync-AzDevOpsCache to populate assigned.json."
}


function az-Open-AzDevOpsMentionsCache {
    $paths = Get-AzDevOpsCachePaths
    Open-AzDevOpsPathIfExists -Path $paths.Mentions `
        -HintMessage "Run az-Sync-AzDevOpsCache to populate mentions.json."
}


function az-Open-AzDevOpsHierarchyCache {
    $paths = Get-AzDevOpsCachePaths
    Open-AzDevOpsPathIfExists -Path $paths.Hierarchy `
        -HintMessage "Run az-Sync-AzDevOpsCache to populate hierarchy.json."
}


function az-Open-AzDevOpsIterationsCache {
    $paths = Get-AzDevOpsCachePaths
    Open-AzDevOpsPathIfExists -Path $paths.Iterations `
        -HintMessage "Run az-Sync-AzDevOpsCache to populate iterations.json."
}


function az-Open-AzDevOpsAreasCache {
    $paths = Get-AzDevOpsCachePaths
    Open-AzDevOpsPathIfExists -Path $paths.Areas `
        -HintMessage "Run az-Sync-AzDevOpsCache to populate areas.json."
}


function az-Open-AzDevOpsLastSync {
    $paths = Get-AzDevOpsCachePaths
    Open-AzDevOpsPathIfExists -Path $paths.LastSync `
        -HintMessage "Run az-Sync-AzDevOpsCache to write the first last-sync.json."
}


function az-Open-AzDevOpsSyncLog {
    $paths = Get-AzDevOpsCachePaths
    Open-AzDevOpsPathIfExists -Path $paths.Log `
        -HintMessage "Run az-Sync-AzDevOpsCache - the log is appended only when a sync runs."
}


# --- Config file openers (3) -----------------------------------------------

function az-Open-AzDevOpsEpicsWiql {
    $paths = Get-AzDevOpsConfigPaths
    Open-AzDevOpsPathIfExists -Path $paths.EpicsQuery `
        -HintMessage "Run az-Open-AzDevOpsHierarchyWiqls (or az-Connect-AzDevOps) to seed epics.wiql with the default."
}


function az-Open-AzDevOpsFeaturesWiql {
    $paths = Get-AzDevOpsConfigPaths
    Open-AzDevOpsPathIfExists -Path $paths.FeaturesQuery `
        -HintMessage "Run az-Open-AzDevOpsHierarchyWiqls (or az-Connect-AzDevOps) to seed features.wiql with the default."
}


function az-Open-AzDevOpsUserStoriesWiql {
    $paths = Get-AzDevOpsConfigPaths
    Open-AzDevOpsPathIfExists -Path $paths.UserStoriesQuery `
        -HintMessage "Run az-Open-AzDevOpsHierarchyWiqls (or az-Connect-AzDevOps) to seed user-stories.wiql with the default."
}


# --- Schema file opener (1) ------------------------------------------------

function az-Open-AzDevOpsSchema {
    $paths = Get-AzDevOpsSchemaPaths
    Open-AzDevOpsPathIfExists -Path $paths.File `
        -HintMessage "Run az-Initialize-AzDevOpsSchema to introspect your org, or az-Edit-AzDevOpsSchema to scaffold a stub."
}
