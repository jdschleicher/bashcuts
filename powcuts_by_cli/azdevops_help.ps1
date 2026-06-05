# ---------------------------------------------------------------------------
# az-help - interactive guided walkthrough of the az-AzDevOps shortcut surface
#
# Public function:
#   az-help - tiered Out-ConsoleGridView drill-down (phase -> function ->
#             detail block) that shows the order of operations across the
#             az-AzDevOps* family and links source / diagram / issues for
#             each function.
#
# The function name 'az-help' intentionally deviates from CLAUDE.md's
# Verb-Noun approved-verb mandate. Trade-off accepted (per issue #83):
# short, memorable, 'az-h<Tab>' lands directly on it. Dot-sourcing (which
# is how powcuts_home.ps1 loads these files) does NOT emit the approved-
# verb warning that Import-Module would, so there is no runtime warning
# to suppress. Do not "correct" the name back to az-Show-AzDevOpsHelp -
# that rename is explicitly rejected.
#
# Catalog rows are PSCustomObjects so they render natively in
# Out-ConsoleGridView. GitHub permalink line numbers resolve at runtime via
# (Get-Command $name).ScriptBlock.Ast.Extent.StartLineNumber so the catalog
# never drifts as source files grow - only the relative file path is stored.
# Falls back to a Format-Table dump when ConsoleGuiTools is unavailable.
# ---------------------------------------------------------------------------

$script:AzDevOpsHelpRepoBlobUrl    = 'https://github.com/jdschleicher/bashcuts/blob/main'
$script:AzDevOpsHelpDiagramPath    = 'docs/azure-devops-diagrams.md'
$script:AzDevOpsHelpIssueUrlPrefix = 'https://github.com/jdschleicher/bashcuts/issues'

$script:AzDevOpsHelpPhases = @(
    [PSCustomObject]@{
        Order       = 1
        Phase       = 'Onboarding'
        Description = 'First-run auth, defaults, and initial cache build'
    },

    [PSCustomObject]@{
        Order       = 2
        Phase       = 'DailyRead'
        Description = 'List / open assigned + mentioned; render tree / board / features'
    },

    [PSCustomObject]@{
        Order       = 3
        Phase       = 'Create'
        Description = 'Create User Story / Feature / batch child stories'
    },

    [PSCustomObject]@{
        Order       = 4
        Phase       = 'MultiProject'
        Description = 'Switch projects + manage background sync schedule'
    }
)

$script:AzDevOpsHelpCatalog = @(

    # --- Onboarding --------------------------------------------------------

    [PSCustomObject]@{
        Name          = 'az-Connect-AzDevOps'
        File          = 'powcuts_by_cli/azdevops_auth.ps1'
        Phase         = 'Onboarding'
        Order         = 1
        Purpose       = 'Interactive first-run auth + setup orchestrator (8 steps)'
        Args          = '(none)'
        Example       = 'az-Connect-AzDevOps'
        RunsBefore    = 'az-Set-AzDevOpsDefaults'
        RequiresSync  = 'No'
        DiagramAnchor = '#2-az-connect-azdevops--8-step-orchestrator'
        Issues        = @(7)
    },

    [PSCustomObject]@{
        Name          = 'az-Test-AzDevOpsAuth'
        File          = 'powcuts_by_cli/azdevops_auth.ps1'
        Phase         = 'Onboarding'
        Order         = 2
        Purpose       = 'Silent diagnostic chain - confirms CLI / extension / env / login OK'
        Args          = '(none)'
        Example       = 'az-Test-AzDevOpsAuth'
        RunsBefore    = 'az-Sync-AzDevOpsCache'
        RequiresSync  = 'No'
        DiagramAnchor = '#3-az-test-azdevopsauth--silent-diagnostic-chain'
        Issues        = @()
    },

    [PSCustomObject]@{
        Name          = 'az-Set-AzDevOpsDefaults'
        File          = 'powcuts_by_cli/azdevops_auth.ps1'
        Phase         = 'Onboarding'
        Order         = 3
        Purpose       = "Set 'az devops configure --defaults' org + project from env vars"
        Args          = '(none) - reads $env:AZ_DEVOPS_ORG / $env:AZ_PROJECT'
        Example       = 'az-Set-AzDevOpsDefaults'
        RunsBefore    = 'az-Sync-AzDevOpsCache'
        RequiresSync  = 'No'
        DiagramAnchor = ''
        Issues        = @(31)
    },

    [PSCustomObject]@{
        Name          = 'az-Sync-AzDevOpsCache'
        File          = 'powcuts_by_cli/azdevops_sync.ps1'
        Phase         = 'Onboarding'
        Order         = 4
        Purpose       = 'Build / refresh local JSON cache (assigned, mentions, hierarchy, areas, iterations); also runs silently on shell open when the cache is stale'
        Args          = '(none)'
        Example       = 'az-Sync-AzDevOpsCache'
        RunsBefore    = 'az-Show-Tree (or any DailyRead function)'
        RequiresSync  = 'No'
        DiagramAnchor = '#4-az-sync-azdevopscache--dataset-fan-out'
        Issues        = @(61, 65)
    },

    # --- DailyRead ---------------------------------------------------------

    [PSCustomObject]@{
        Name          = 'az-Get-AzDevOpsAssigned'
        File          = 'powcuts_by_cli/azdevops_views.ps1'
        Phase         = 'DailyRead'
        Order         = 1
        Purpose       = 'Grid of work items assigned to you (from cache)'
        Args          = '(none)'
        Example       = 'az-Get-AzDevOpsAssigned'
        RunsBefore    = 'az-Open-Assigned'
        RequiresSync  = 'Yes'
        DiagramAnchor = '#5-cache-consumers-az-get-azdevopsassignedmentions-and-az-open-assignedmention'
        Issues        = @()
    },

    [PSCustomObject]@{
        Name          = 'az-Open-Assigned'
        File          = 'powcuts_by_cli/azdevops_views.ps1'
        Phase         = 'DailyRead'
        Order         = 2
        Purpose       = 'Pick an assigned work item from the grid; open it in your browser'
        Args          = '(none)'
        Example       = 'az-Open-Assigned'
        RunsBefore    = ''
        RequiresSync  = 'Yes'
        DiagramAnchor = '#5-cache-consumers-az-get-azdevopsassignedmentions-and-az-open-assignedmention'
        Issues        = @()
    },

    [PSCustomObject]@{
        Name          = 'az-Get-AzDevOpsMentions'
        File          = 'powcuts_by_cli/azdevops_views.ps1'
        Phase         = 'DailyRead'
        Order         = 3
        Purpose       = 'Grid of work items where you have been @-mentioned in discussion'
        Args          = '(none) - reads $env:AZ_USER_EMAIL for the WIQL filter'
        Example       = 'az-Get-AzDevOpsMentions'
        RunsBefore    = 'az-Open-Mention'
        RequiresSync  = 'Yes'
        DiagramAnchor = '#5-cache-consumers-az-get-azdevopsassignedmentions-and-az-open-assignedmention'
        Issues        = @()
    },

    [PSCustomObject]@{
        Name          = 'az-Open-Mention'
        File          = 'powcuts_by_cli/azdevops_views.ps1'
        Phase         = 'DailyRead'
        Order         = 4
        Purpose       = 'Pick a mentioned work item from the grid; open it in your browser'
        Args          = '(none)'
        Example       = 'az-Open-Mention'
        RunsBefore    = ''
        RequiresSync  = 'Yes'
        DiagramAnchor = '#5-cache-consumers-az-get-azdevopsassignedmentions-and-az-open-assignedmention'
        Issues        = @()
    },

    [PSCustomObject]@{
        Name          = 'az-Open-WorkItemById'
        File          = 'powcuts_by_cli/azdevops_views.ps1'
        Phase         = 'DailyRead'
        Order         = 5
        Purpose       = 'Open any work item in the browser by raw ID - no cache lookup, works for items not assigned to or mentioning you'
        Args          = '<id>'
        Example       = 'az-Open-WorkItemById 12345'
        RunsBefore    = ''
        RequiresSync  = 'No'
        DiagramAnchor = ''
        Issues        = @()
    },

    [PSCustomObject]@{
        Name          = 'az-Show-Tree'
        File          = 'powcuts_by_cli/azdevops_views.ps1'
        Phase         = 'DailyRead'
        Order         = 6
        Purpose       = 'Epic -> Feature -> requirement-tier indented tree; select a row to open it or create a child work item'
        Args          = '[-IncludeClosed]'
        Example       = 'az-Show-Tree'
        RunsBefore    = ''
        RequiresSync  = 'Yes'
        DiagramAnchor = '#6-az-show-tree--epic--feature--requirement-tier-render'
        Issues        = @()
    },

    [PSCustomObject]@{
        Name          = 'az-Show-Board'
        File          = 'powcuts_by_cli/azdevops_views.ps1'
        Phase         = 'DailyRead'
        Order         = 7
        Purpose       = 'Group-by-State board view of the cached items; select a row to open it or create a child work item'
        Args          = '[-IncludeClosed]'
        Example       = 'az-Show-Board'
        RunsBefore    = ''
        RequiresSync  = 'Yes'
        DiagramAnchor = ''
        Issues        = @()
    },

    [PSCustomObject]@{
        Name          = 'az-Show-Epics'
        File          = 'powcuts_by_cli/azdevops_views.ps1'
        Phase         = 'DailyRead'
        Order         = 8
        Purpose       = 'Epics from the active project hierarchy cache; select a row to open it or create a child Feature, or tick several rows to open them all at once'
        Args          = '[-State <states>]'
        Example       = 'az-Show-Epics'
        RunsBefore    = ''
        RequiresSync  = 'Yes'
        DiagramAnchor = ''
        Issues        = @(130)
    },

    [PSCustomObject]@{
        Name          = 'az-Show-Features'
        File          = 'powcuts_by_cli/azdevops_views.ps1'
        Phase         = 'DailyRead'
        Order         = 9
        Purpose       = 'Features across the project map from the hierarchy cache; select a row to open it or create a child story'
        Args          = '[-Project <name>] [-State <states>]'
        Example       = 'az-Show-Features'
        RunsBefore    = ''
        RequiresSync  = 'Yes'
        DiagramAnchor = ''
        Issues        = @()
    },

    [PSCustomObject]@{
        Name          = 'az-Show-Orphans'
        File          = 'powcuts_by_cli/azdevops_views.ps1'
        Phase         = 'DailyRead'
        Order         = 10
        Purpose       = 'Lists parentless Features and stories under the active area so stray items can be re-parented; select a row to open it or create a child'
        Args          = '[-Area <path>] [-State <states>]'
        Example       = 'az-Show-Orphans'
        RunsBefore    = ''
        RequiresSync  = 'Yes'
        DiagramAnchor = ''
        Issues        = @(125)
    },

    # --- Create ------------------------------------------------------------

    [PSCustomObject]@{
        Name          = 'az-New-AzDevOpsUserStory'
        File          = 'powcuts_by_cli/azdevops_create.ps1'
        Phase         = 'Create'
        Order         = 1
        Purpose       = 'Interactive new User Story with parent-Feature / iteration / area pickers'
        Args          = '(none) - all values prompted interactively'
        Example       = 'az-New-AzDevOpsUserStory'
        RunsBefore    = ''
        RequiresSync  = 'Yes'
        DiagramAnchor = '#7-az-new-azdevopsuserstory--interactive-create-flow'
        Issues        = @()
    },

    [PSCustomObject]@{
        Name          = 'az-New-AzDevOpsFeature'
        File          = 'powcuts_by_cli/azdevops_create.ps1'
        Phase         = 'Create'
        Order         = 2
        Purpose       = 'Interactive new Feature with parent-Epic picker; hand-off prompt to spawn child stories'
        Args          = '(none) - all values prompted interactively'
        Example       = 'az-New-AzDevOpsFeature'
        RunsBefore    = 'az-New-AzDevOpsFeatureStories'
        RequiresSync  = 'Yes'
        DiagramAnchor = '#8-az-new-azdevopsfeature--interactive-feature-create--child-story-hand-off'
        Issues        = @()
    },

    [PSCustomObject]@{
        Name          = 'az-New-AzDevOpsFeatureStories'
        File          = 'powcuts_by_cli/azdevops_create.ps1'
        Phase         = 'Create'
        Order         = 3
        Purpose       = 'Batch-decompose a Feature into 3-7 child stories (shared area / iteration)'
        Args          = '(none) - parent Feature picked interactively'
        Example       = 'az-New-AzDevOpsFeatureStories'
        RunsBefore    = ''
        RequiresSync  = 'Yes'
        DiagramAnchor = '#9-az-new-azdevopsfeaturestories--batch-child-story-loop'
        Issues        = @()
    },

    [PSCustomObject]@{
        Name          = 'az-New-Task'
        File          = 'powcuts_by_cli/azdevops_create.ps1'
        Phase         = 'Create'
        Order         = 4
        Purpose       = 'Interactive new Task with parent-User-Story picker; also the child action when a Story is selected in az-Show-Tree / Board'
        Args          = '[-ParentStoryId <id>] (else parent Story picked interactively)'
        Example       = 'az-New-Task'
        RunsBefore    = ''
        RequiresSync  = 'Yes'
        DiagramAnchor = ''
        Issues        = @()
    },

    # --- MultiProject ------------------------------------------------------

    [PSCustomObject]@{
        Name          = 'az-Use-AzDevOpsProject'
        File          = 'powcuts_by_cli/azdevops_projects.ps1'
        Phase         = 'MultiProject'
        Order         = 1
        Purpose       = 'Switch the active project for subsequent az-AzDevOps* calls (per-project cache slice)'
        Args          = '[-Name <project>] (or interactive picker)'
        Example       = 'az-Use-AzDevOpsProject -Name "My Project"'
        RunsBefore    = 'az-Sync-AzDevOpsCache'
        RequiresSync  = 'No'
        DiagramAnchor = ''
        Issues        = @(57, 76)
    },

    [PSCustomObject]@{
        Name          = 'az-Find-AzDevOpsProject'
        File          = 'powcuts_by_cli/azdevops_projects.ps1'
        Phase         = 'MultiProject'
        Order         = 2
        Purpose       = 'Out-ConsoleGridView picker over the project map; emits the picked entry'
        Args          = '(none)'
        Example       = 'az-Find-AzDevOpsProject | az-Use-AzDevOpsProject'
        RunsBefore    = 'az-Use-AzDevOpsProject'
        RequiresSync  = 'No'
        DiagramAnchor = ''
        Issues        = @(57, 76)
    }
)


function Get-AzDevOpsHelpFunctionUrl {
    # Returns the GitHub permalink for the given catalog entry. Resolves the
    # current line number via Get-Command so the URL never drifts as source
    # files grow. Falls back to the file-level URL (no #L anchor) when the
    # function is not loaded in the current session.
    param([Parameter(Mandatory)] [PSCustomObject] $Entry)

    $baseUrl = "$script:AzDevOpsHelpRepoBlobUrl/$($Entry.File)"

    $cmd = Get-Command -Name $Entry.Name -ErrorAction SilentlyContinue
    if ($null -eq $cmd -or $null -eq $cmd.ScriptBlock -or $null -eq $cmd.ScriptBlock.Ast) {
        return $baseUrl
    }

    $line = $cmd.ScriptBlock.Ast.Extent.StartLineNumber
    $urlWithLine = "$baseUrl#L$line"
    return $urlWithLine
}


function Show-AzDevOpsHelpDetail {
    # Prints a labeled detail block for one catalog entry, including the
    # GitHub source permalink, the diagram anchor (if any), and any
    # originating-issue links. Write-Host is appropriate here - this is
    # user-facing status, not pipeable data.
    param([Parameter(Mandatory)] [PSCustomObject] $Entry)

    $url = Get-AzDevOpsHelpFunctionUrl -Entry $Entry

    Write-Host ''
    Write-Host $Entry.Name -ForegroundColor Cyan
    Write-Host ('-' * $Entry.Name.Length) -ForegroundColor Cyan
    Write-Host ''

    Write-Host 'Phase   : ' -NoNewline -ForegroundColor DarkGray
    Write-Host $Entry.Phase

    Write-Host 'Purpose : ' -NoNewline -ForegroundColor DarkGray
    Write-Host $Entry.Purpose

    Write-Host 'Args    : ' -NoNewline -ForegroundColor DarkGray
    Write-Host $Entry.Args

    Write-Host 'Example : ' -NoNewline -ForegroundColor DarkGray
    Write-Host $Entry.Example -ForegroundColor Yellow

    if ($Entry.RunsBefore) {
        Write-Host 'Next    : ' -NoNewline -ForegroundColor DarkGray
        Write-Host $Entry.RunsBefore
    }

    Write-Host 'Cache   : ' -NoNewline -ForegroundColor DarkGray
    Write-Host "requires az-Sync-AzDevOpsCache run? $($Entry.RequiresSync)"

    Write-Host ''
    Write-Host 'Links   :' -ForegroundColor DarkGray
    Write-Host "  source  -> $url"

    if ($Entry.DiagramAnchor) {
        $diagramUrl = "$script:AzDevOpsHelpRepoBlobUrl/$script:AzDevOpsHelpDiagramPath$($Entry.DiagramAnchor)"
        Write-Host "  diagram -> $diagramUrl"
    }

    if ($Entry.Issues -and $Entry.Issues.Count -gt 0) {
        $issueLinks = $Entry.Issues | ForEach-Object {
            "#$_  $script:AzDevOpsHelpIssueUrlPrefix/$_"
        }
        $issueLine = $issueLinks -join '   '
        Write-Host "  issues  -> $issueLine"
    }

    Write-Host ''
}


function Show-AzDevOpsHelpPlainDump {
    # Fallback for terminals without Microsoft.PowerShell.ConsoleGuiTools.
    # Prints every phase header + its functions as a Format-Table so the
    # user can still discover the surface and read the function names.
    Write-Host ''
    Write-Host 'az-help' -ForegroundColor Cyan
    Write-Host '(Out-ConsoleGridView unavailable - install Microsoft.PowerShell.ConsoleGuiTools for the interactive picker)' -ForegroundColor Yellow

    foreach ($phase in ($script:AzDevOpsHelpPhases | Sort-Object Order)) {
        Write-Host ''
        Write-Host "$($phase.Phase) - $($phase.Description)" -ForegroundColor Cyan

        $entries = @($script:AzDevOpsHelpCatalog | Where-Object { $_.Phase -eq $phase.Phase } | Sort-Object Order)
        $rows = $entries | Select-Object Order, Name, Purpose, RunsBefore, RequiresSync
        $rows | Format-Table -AutoSize | Out-Host
    }
}


function az-help {
    # Tiered Out-ConsoleGridView drill-down:
    #   Tier 1 - pick a workflow phase
    #   Tier 2 - pick a function within that phase; detail block prints;
    #            tier-2 grid re-opens so the user can keep drilling
    # 'EXIT' (tier 1) and '.. [Go Back]' (tier 2) are synthetic rows with
    # the same column shape as data rows so Out-ConsoleGridView doesn't
    # collapse columns. Modeled on az-Find-AzDevOpsWorkItem.
    [CmdletBinding()]
    param()

    if (-not (Test-AzDevOpsGridAvailable)) {
        Show-AzDevOpsHelpPlainDump
        return
    }

    $exitLabel = 'EXIT'
    $backLabel = '.. [Go Back]'

    $running      = $true
    $tier         = 1
    $currentPhase = $null

    while ($running) {

        if ($tier -eq 1) {
            $phaseRows = $script:AzDevOpsHelpPhases | Sort-Object Order | ForEach-Object {
                [PSCustomObject]@{
                    Order       = $_.Order
                    Phase       = $_.Phase
                    Description = $_.Description
                }
            }

            $exitRow = [PSCustomObject]@{
                Order       = 0
                Phase       = $exitLabel
                Description = ''
            }

            $rows = @($exitRow) + $phaseRows
            $title = "az-help - pick a workflow phase ('EXIT' or Esc to quit)"
            $picked = $rows | Out-ConsoleGridView -Title $title -OutputMode Single

            if ($null -eq $picked -or $picked.Phase -eq $exitLabel) {
                $running = $false
                continue
            }

            $currentPhase = $picked.Phase
            $tier = 2
            continue
        }

        if ($tier -eq 2) {
            $phaseEntries = @($script:AzDevOpsHelpCatalog | Where-Object { $_.Phase -eq $currentPhase } | Sort-Object Order)

            $functionRows = $phaseEntries | ForEach-Object {
                [PSCustomObject]@{
                    Order        = $_.Order
                    Function     = $_.Name
                    Purpose      = $_.Purpose
                    RunsBefore   = $_.RunsBefore
                    RequiresSync = $_.RequiresSync
                }
            }

            $backRow = [PSCustomObject]@{
                Order        = 0
                Function     = $backLabel
                Purpose      = ''
                RunsBefore   = ''
                RequiresSync = ''
            }

            $rows = @($backRow) + $functionRows
            $title = "$currentPhase - pick a function (or '.. [Go Back]')"
            $picked = $rows | Out-ConsoleGridView -Title $title -OutputMode Single

            if ($null -eq $picked -or $picked.Function -eq $backLabel) {
                $tier = 1
                continue
            }

            $entry = $script:AzDevOpsHelpCatalog | Where-Object { $_.Name -eq $picked.Function } | Select-Object -First 1
            if ($null -ne $entry) {
                Show-AzDevOpsHelpDetail -Entry $entry
            }

            continue
        }
    }
}
