# ============================================================================
# Azure DevOps — File / folder openers
# ============================================================================
# Direct openers for every folder and file under
# $HOME/.bashcuts-az-devops-app/. Every public function below resolves its
# path through the existing Get-AzDevOps* helpers so cache openers auto-follow
# the active project slice and the schema opener auto-follows $env:AZ_DEVOPS_ORG.
#
# Discovery: tab-tab on `az-Open-` in any pwsh session.
#
# Loaded by powcuts_home.ps1. See azdevops_auth.ps1 for the master docstring.

function o-az-devops-openers {
	Start-Process "$path_to_bashcuts\powcuts_by_cli\azdevops_openers.ps1"
} 	


function Open-AzDevOpsPathIfExists {
    # Private helper used by every public az-Open-* function in this
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

function az-Open-AppRoot {
    $root = Get-AzDevOpsAppRoot
    Open-AzDevOpsPathIfExists -Path $root `
        -HintMessage "Run az-Connect-AzDevOps to scaffold the app root."
}


function az-Open-CacheDir {
    $paths = Get-AzDevOpsCachePaths
    Open-AzDevOpsPathIfExists -Path $paths.Dir `
        -HintMessage "Run az-Sync-AzDevOpsCache to populate the active project's cache slice."
}


function o-az-devops-queries-config-dir {
    $paths = Get-AzDevOpsConfigPaths
    Open-AzDevOpsPathIfExists -Path $paths.QueriesDir `
        -HintMessage "Run az-Connect-AzDevOps (or az-Open-HierarchyWiqls) to seed the default WIQL files."
}


function o-az-devops-schema-dir {
    $paths = Get-AzDevOpsSchemaPaths
    Open-AzDevOpsPathIfExists -Path $paths.Dir `
        -HintMessage "Run az-Initialize-AzDevOpsSchema (or az-Edit-AzDevOpsSchema) to create the schema directory."
}


# --- Cache file openers (7) ------------------------------------------------

function az-Open-AssignedCache {
    $paths = Get-AzDevOpsCachePaths
    Open-AzDevOpsPathIfExists -Path $paths.Assigned `
        -HintMessage "Run az-Sync-AzDevOpsCache to populate assigned.json."
}


function az-Open-MentionsCache {
    $paths = Get-AzDevOpsCachePaths
    Open-AzDevOpsPathIfExists -Path $paths.Mentions `
        -HintMessage "Run az-Sync-AzDevOpsCache to populate mentions.json."
}


function az-Open-HierarchyCache {
    $paths = Get-AzDevOpsCachePaths
    Open-AzDevOpsPathIfExists -Path $paths.Hierarchy `
        -HintMessage "Run az-Sync-AzDevOpsCache to populate hierarchy.json."
}


function az-Open-IterationsCache {
    $paths = Get-AzDevOpsCachePaths
    Open-AzDevOpsPathIfExists -Path $paths.Iterations `
        -HintMessage "Run az-Sync-AzDevOpsCache to populate iterations.json."
}


function az-Open-AreasCache {
    $paths = Get-AzDevOpsCachePaths
    Open-AzDevOpsPathIfExists -Path $paths.Areas `
        -HintMessage "Run az-Sync-AzDevOpsCache to populate areas.json."
}


function az-Open-LastSync {
    $paths = Get-AzDevOpsCachePaths
    Open-AzDevOpsPathIfExists -Path $paths.LastSync `
        -HintMessage "Run az-Sync-AzDevOpsCache to write the first last-sync.json."
}


function az-Open-SyncLog {
    $paths = Get-AzDevOpsCachePaths
    Open-AzDevOpsPathIfExists -Path $paths.Log `
        -HintMessage "Run az-Sync-AzDevOpsCache - the log is appended only when a sync runs."
}


# --- Config file openers (3) -----------------------------------------------

function az-Open-EpicsWiql {
    $paths = Get-AzDevOpsConfigPaths
    Open-AzDevOpsPathIfExists -Path $paths.EpicsQuery `
        -HintMessage "Run az-Open-HierarchyWiqls (or az-Connect-AzDevOps) to seed epics.wiql with the default."
}


function az-Open-FeaturesWiql {
    $paths = Get-AzDevOpsConfigPaths
    Open-AzDevOpsPathIfExists -Path $paths.FeaturesQuery `
        -HintMessage "Run az-Open-HierarchyWiqls (or az-Connect-AzDevOps) to seed features.wiql with the default."
}


function az-Open-UserStoriesWiql {
    $paths = Get-AzDevOpsConfigPaths
    Open-AzDevOpsPathIfExists -Path $paths.UserStoriesQuery `
        -HintMessage "Run az-Open-HierarchyWiqls (or az-Connect-AzDevOps) to seed user-stories.wiql with the default."
}


function az-Open-FieldTemplates {
    # Opens the per-type extra-fields config (field-templates.json). Defensively
    # seeds field-templates.json (empty {}) and field-templates.example.json (the
    # swimlane example) via Initialize-AzDevOpsFieldTemplates - mirrors how
    # az-Open-HierarchyWiqls seeds - so a fresh machine can discover and edit the
    # config in one step. The example is opened alongside so the shape is visible.
    $init = Initialize-AzDevOpsFieldTemplates

    foreach ($entry in $init.Seeded) {
        if ($entry.Seeded) {
            Write-Host "Wrote default $($entry.Name) to $($entry.Path) - opening for editing" -ForegroundColor Green
        } else {
            Write-Host "Opening $($entry.Path)" -ForegroundColor DarkGray
        }

        Start-Process $entry.Path
    }
}


# --- Schema file opener (1) ------------------------------------------------

function az-Open-Schema {
    $paths = Get-AzDevOpsSchemaPaths
    Open-AzDevOpsPathIfExists -Path $paths.File `
        -HintMessage "Run az-Initialize-AzDevOpsSchema to introspect your org, or az-Edit-AzDevOpsSchema to scaffold a stub."
}
