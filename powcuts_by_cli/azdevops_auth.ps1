# ============================================================================
# Azure DevOps Work-Item Shortcuts
# ============================================================================
#
# Foundation file for Azure DevOps work-item navigation shortcuts.
#
# User-facing functions:
#   az-Connect-AzDevOps            - interactive first-run auth + setup helper
#                                    (run once on a fresh machine, or any time
#                                    auth feels stale)
#   az-Test-AzDevOpsAuth           - silent yes/no auth assertion intended for
#                                    callers in later AzDevOps commands;
#                                    returns $true / $false
#   az-Open-AzDevOpsHierarchyWiqls - open each ~/.bashcuts-az-devops-app/config/
#                                    queries/{epics,features,user-stories}.wiql
#                                    in the default editor (seeds the defaults
#                                    on first run)
#
# Step functions invoked by az-Connect-AzDevOps (also exposed for direct use,
# e.g. to debug a single failing step). Each returns a [PSCustomObject]
# with Ok (bool) and FailMessage (string or $null) properties, and prints
# its own status:
#   az-Confirm-AzDevOpsCli              - step 1 (CLI on PATH + version echo)
#   az-Confirm-AzDevOpsExtension        - step 2 (azure-devops extension; offers install)
#   az-Confirm-AzDevOpsEnvVars          - step 3 (required $profile env vars set)
#   az-Confirm-AzDevOpsLogin            - step 4 (az login session; offers login)
#   az-Set-AzDevOpsDefaults             - step 5 (az devops configure --defaults)
#   az-Confirm-AzDevOpsQueryFiles       - step 6 (seed ~/.bashcuts-az-devops-app/config WIQL files)
#   az-Confirm-AzDevOpsSmokeQuery       - step 7 (az boards query smoke test)
#
# Silent diagnostic helpers (pure checks, no I/O — used by az-Test-AzDevOpsAuth):
#   Test-AzDevOpsCliPresent          - is the `az` CLI on PATH?
#   Test-AzDevOpsExtensionInstalled  - is the `azure-devops` extension installed?
#   Get-AzDevOpsMissingEnvVars       - returns array of required env vars not set
#   Test-AzDevOpsLoggedIn            - does `az account show` succeed?
#   Invoke-AzDevOpsSmokeQuery        - runs WIQL "items assigned to me",
#                                       returns count or $null on failure
#
# Required setup (run once):
#   az devops configure --defaults organization=https://dev.azure.com/myorg project="My Project"
#   (or run az-Connect-AzDevOps which walks you through this interactively)
#
# Optional $profile environment variables:
#
#   $env:AZ_USER_EMAIL = 'user@example.com'              # your AAD email (mentions WIQL)
#   $env:AZ_AREA       = 'My Project\My Team'            # default area path (hierarchy WIQL)
#   $env:AZ_ITERATION  = 'My Project\Sprint 42'          # default iteration (work item creation)
#
# Prereqs:
#   - Azure CLI        : https://aka.ms/installazurecli
#   - azure-devops ext : az extension add --name azure-devops
#
# First-run:
#   PS> az-Connect-AzDevOps
#
# ----------------------------------------------------------------------------
# Verb coverage matrix (az-Get- / az-Show- / az-Find- across nouns)
#
# Verb contracts:
#   az-Get-*   - returns [PSCustomObject] rows for the pipeline; may also open
#                Show-AzDevOpsRows -PassThru so the same call doubles as an
#                interactive grid (Assigned / Mentions).
#   az-Show-*  - writes a human-readable view (tree / board / table); no
#                pipeline data.
#   az-Find-*  - interactive drill-down via Out-ConsoleGridView; emits the
#                picked value(s) on the pipeline. Prints an install hint and
#                returns when Microsoft.PowerShell.ConsoleGuiTools is missing.
#
# Coverage:
#                          Get-                  Show-                Find-
#   Project                Projects              Project              Project
#   Work Item (hierarchy)  --                    Tree, Board          WorkItem
#   Work Item (assigned)   Assigned [pickable]   --                   --
#   Work Item (mentions)   Mentions [pickable]   --                   --
#   Area                   Areas                 Areas                Area
#   Iteration              Iterations            Iterations           Iteration
#   Cache                  CacheStatus           --                   --
#   Schema                 Schema                --                   --
#
# Deliberately-empty cells:
#   Assigned / Mentions Show-: az-Get-* already grid-renders; Show- would dupe.
#   Cache / Schema Show- / Find-: no tree to drill, no pick semantics.
#   Hierarchy Get-: Tree and Board cover the listing surface; Find- emits IDs.
# ============================================================================


# ---------------------------------------------------------------------------
# Silent diagnostic helpers (no I/O; safe for az-Test-AzDevOpsAuth callers)
# ---------------------------------------------------------------------------

function Test-AzDevOpsCliPresent {
    return [bool](Get-Command az -ErrorAction SilentlyContinue)
}


function Test-AzDevOpsExtensionInstalled {
    $name = az extension list --query "[?name=='azure-devops'].name" -o tsv 2>$null
    return ($LASTEXITCODE -eq 0 -and $name -eq 'azure-devops')
}


function Test-AzDevOpsLoggedIn {
    $null = az account show 2>$null
    return ($LASTEXITCODE -eq 0)
}


function Invoke-AzDevOpsSmokeQuery {
    $wiql = 'Select [System.Id] From WorkItems Where [System.AssignedTo] = @Me'
    $result = Invoke-AzDevOpsBoardsQuery -Wiql $wiql
    if ($result.ExitCode -ne 0) {
        return $null
    }

    try {
        $items = $result.Json | ConvertFrom-Json
        return @($items).Count
    }
    catch {
        return $null
    }
}


function az-Test-AzDevOpsAuth {
    if (-not (Test-AzDevOpsCliPresent)) {
        return $false
    }
    if ($null -eq (Invoke-AzDevOpsSmokeQuery)) {
        return $false
    }

    return $true
}


function Assert-AzDevOpsAuthOrAbort {
    # Standard auth-test-and-abort prologue used by every command that calls
    # az on the user's behalf (az-Sync-AzDevOpsCache, az-New-AzDevOpsUserStory,
    # az-Initialize-AzDevOpsSchema, az-Test-AzDevOpsSchema). Returns $true when
    # auth is good. On failure, prints the standard "<command> aborted -
    # az-Test-AzDevOpsAuth returned false. Run az-Connect-AzDevOps." line and
    # returns $false so callers `if (-not (Assert-...)) { return }`.
    param([Parameter(Mandatory)] [string] $CommandName)

    if (az-Test-AzDevOpsAuth) {
        return $true
    }

    Write-Host "$CommandName aborted - az-Test-AzDevOpsAuth returned false. Run az-Connect-AzDevOps." -ForegroundColor Red
    return $false
}


# ---------------------------------------------------------------------------
# Step functions invoked by az-Connect-AzDevOps. Each owns its print + I/O for
# one step and returns a [PSCustomObject] with Ok (bool) and FailMessage
# (string or $null) properties.
# ---------------------------------------------------------------------------

function New-AzDevOpsStepResult {
    param(
        [Parameter(Mandatory)] [bool] $Ok,
        $FailMessage = $null
    )
    return [PSCustomObject]@{ Ok = $Ok; FailMessage = $FailMessage }
}


function Read-AzDevOpsYesNo {
    # Default-yes Y/n prompt used by Confirm-* steps that offer a remediation
    # action. Returns $true when the user accepts (empty input or anything
    # other than n/no), $false on explicit refusal.
    param([Parameter(Mandatory)] [string] $Prompt)
    $resp = Read-Host "    $Prompt [Y/n]"
    return -not ($resp -match '^(n|no)$')
}


function az-Confirm-AzDevOpsCli {
    if (-not (Test-AzDevOpsCliPresent)) {
        Write-Host "  X az CLI not on PATH" -ForegroundColor Red
        if ($IsWindows) {
            Write-Host "    Install via: winget install Microsoft.AzureCLI"
            Write-Host "    Or see: https://aka.ms/installazurecli"
        }
        elseif ($IsMacOS) {
            Write-Host "    Install via: brew install azure-cli"
            Write-Host "    Or see: https://aka.ms/installazurecli-mac"
        }
        else {
            Write-Host "    See: https://learn.microsoft.com/cli/azure/install-azure-cli-linux"
        }
        return New-AzDevOpsStepResult -Ok $false -FailMessage 'az CLI missing'
    }
    $azVersion = (az version --output json 2>$null | ConvertFrom-Json).'azure-cli'
    Write-Host "  OK  az CLI present (v$azVersion)" -ForegroundColor Green
    return New-AzDevOpsStepResult -Ok $true
}


function az-Confirm-AzDevOpsExtension {
    if (-not (Test-AzDevOpsExtensionInstalled)) {
        Write-Host "  !  azure-devops extension not installed" -ForegroundColor Yellow
        if (-not (Read-AzDevOpsYesNo -Prompt 'Install now?')) {
            Write-Host "    Hint: az extension add --name azure-devops"
            return New-AzDevOpsStepResult -Ok $false -FailMessage 'extension missing'
        }
        az extension add --name azure-devops 2>&1 | Out-Host
        if (-not (Test-AzDevOpsExtensionInstalled)) {
            return New-AzDevOpsStepResult -Ok $false -FailMessage 'extension install failed'
        }
    }
    Write-Host "  OK  azure-devops extension installed" -ForegroundColor Green
    return New-AzDevOpsStepResult -Ok $true
}


function az-Confirm-AzDevOpsEnvVars {
    # Org and project come from `az devops configure --defaults` (the user's
    # Microsoft profile). AZ_USER_EMAIL and AZ_AREA are optional but improve
    # the mentions WIQL and hierarchy query respectively.
    if ($env:AZ_USER_EMAIL) {
        Write-Host "  OK  AZ_USER_EMAIL = $env:AZ_USER_EMAIL" -ForegroundColor Green
    } else {
        Write-Host "  --  AZ_USER_EMAIL not set (mentions WIQL will use '@' fallback)" -ForegroundColor DarkYellow
        Write-Host "      Add to `$profile: `$env:AZ_USER_EMAIL = 'you@example.com'"
    }

    if ($env:AZ_AREA) {
        Write-Host "  OK  AZ_AREA = $env:AZ_AREA" -ForegroundColor Green
    } else {
        Write-Host "  --  AZ_AREA not set (hierarchy WIQL token {{AZ_AREA}} will need manual edit)" -ForegroundColor DarkYellow
        Write-Host "      Add to `$profile: `$env:AZ_AREA = 'My Project\My Team'"
    }

    return New-AzDevOpsStepResult -Ok $true
}


function az-Confirm-AzDevOpsProjectMap {
    # Validates `$global:AzDevOpsProjectMap` when it's defined; silently passes
    # when it isn't (multi-project mode is opt-in). When the map is defined but
    # `$global:AzDevOpsDefaultProject` is unset, prompts the user with a numbered
    # menu of project names and calls az-Use-AzDevOpsProject -Quiet on the
    # choice. When the active project is missing required keys (Org / Project),
    # returns Ok=$false with a clear FailMessage so the orchestrator bails.
    if (-not (Get-Command Test-AzDevOpsProjectMapDefined -ErrorAction SilentlyContinue)) {
        Write-Host "  -- Skipped (multi-project resolver layer not loaded)" -ForegroundColor DarkGray
        return New-AzDevOpsStepResult -Ok $true
    }

    if (-not (Test-AzDevOpsProjectMapDefined)) {
        Write-Host "  -- Skipped (`$global:AzDevOpsProjectMap not defined - single-project mode)" -ForegroundColor DarkGray
        return New-AzDevOpsStepResult -Ok $true
    }

    $activeName = Get-AzDevOpsActiveProjectName
    if (-not $activeName) {
        Write-Host "  !  `$global:AzDevOpsProjectMap defined but no active project chosen" -ForegroundColor Yellow

        $names = @($global:AzDevOpsProjectMap.Keys | Sort-Object)
        Write-Host ""
        Write-Host "    Available projects:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $names.Count; $i++) {
            Write-Host ("      {0}. {1}" -f ($i + 1), $names[$i])
        }

        $idx = 0
        while ($true) {
            $resp = Read-Host "    Pick a project (1..$($names.Count))"
            if ([int]::TryParse($resp, [ref]$idx) -and $idx -ge 1 -and $idx -le $names.Count) {
                break
            }
            Write-Host "      Please enter 1..$($names.Count)." -ForegroundColor Yellow
        }

        $activeName = $names[$idx - 1]
        az-Use-AzDevOpsProject -Name $activeName -Quiet
    }

    $config = Get-AzDevOpsActiveProjectConfig
    if ($null -eq $config) {
        return New-AzDevOpsStepResult -Ok $false -FailMessage "active project '$activeName' missing from `$global:AzDevOpsProjectMap"
    }

    foreach ($requiredKey in @('Org', 'Project')) {
        if (-not $config.ContainsKey($requiredKey) -or -not $config[$requiredKey]) {
            return New-AzDevOpsStepResult -Ok $false -FailMessage "project '$activeName' missing required key '$requiredKey' in `$global:AzDevOpsProjectMap"
        }
    }

    Write-Host "  OK  Active project: $activeName" -ForegroundColor Green
    return New-AzDevOpsStepResult -Ok $true
}


function az-Confirm-AzDevOpsLogin {
    if (-not (Test-AzDevOpsLoggedIn)) {
        Write-Host "  !  No active az login session" -ForegroundColor Yellow
        if (-not (Read-AzDevOpsYesNo -Prompt "Run 'az login' now?")) {
            Write-Host "    Hint: az login"
            return New-AzDevOpsStepResult -Ok $false -FailMessage 'not logged in'
        }
        az login | Out-Host
        if (-not (Test-AzDevOpsLoggedIn)) {
            return New-AzDevOpsStepResult -Ok $false -FailMessage 'az login failed'
        }
    }
    $account = az account show --output json 2>$null | ConvertFrom-Json
    Write-Host "  OK  Logged in as $($account.user.name) (sub: $($account.name))" -ForegroundColor Green
    return New-AzDevOpsStepResult -Ok $true
}


function az-Set-AzDevOpsDefaults {
    # Shows the currently-configured az devops defaults (stored in the user's
    # Microsoft profile via `az devops configure --defaults`). Guides the user
    # to set them if either is missing; the smoke query in the next step will
    # surface auth/scope failures if defaults aren't pointing at a valid org.
    $defaults = Get-AzDevOpsConfiguredDefaults

    if ($defaults.Org) {
        Write-Host "  OK  organization = $($defaults.Org)" -ForegroundColor Green
    } else {
        Write-Host "  !   organization not configured" -ForegroundColor Yellow
        Write-Host "      Run: az devops configure --defaults organization=https://dev.azure.com/myorg"
    }

    if ($defaults.Project) {
        Write-Host "  OK  project = $($defaults.Project)" -ForegroundColor Green
    } else {
        Write-Host "  !   project not configured" -ForegroundColor Yellow
        Write-Host "      Run: az devops configure --defaults project=`"My Project`""
    }

    return New-AzDevOpsStepResult -Ok $true
}


function az-Confirm-AzDevOpsQueryFiles {
    $init = Initialize-AzDevOpsQueryFiles

    $newlySeeded = @($init.Seeded | Where-Object { $_.Seeded })

    if ($newlySeeded.Count -gt 0) {
        foreach ($entry in $newlySeeded) {
            Write-Host "  OK  Wrote default $($entry.Name).wiql to $($entry.Path)" -ForegroundColor Green
        }
        Write-Host "      Edit these files to customize what az-Sync-AzDevOpsCache fetches." -ForegroundColor DarkGray
    } else {
        Write-Host "  OK  Query files at $($init.Paths.QueriesDir)" -ForegroundColor Green
    }

    $stepResult = New-AzDevOpsStepResult -Ok $true
    return $stepResult
}


function az-Open-AzDevOpsHierarchyWiqls {
    # Opens all user-machine WIQL files (epics, features, user-stories,
    # assigned, mentions) in the OS default editor. Defensively seeds the
    # defaults via Initialize-AzDevOpsQueryFiles so a fresh machine that
    # skipped az-Connect-AzDevOps can still discover and customize the
    # queries in one step (no "file not found" detour).
    $init = Initialize-AzDevOpsQueryFiles

    foreach ($entry in $init.Seeded) {
        if ($entry.Seeded) {
            Write-Host "Wrote default $($entry.Name).wiql to $($entry.Path) - opening for editing" -ForegroundColor Green
        } else {
            Write-Host "Opening $($entry.Path)" -ForegroundColor DarkGray
        }

        Start-Process $entry.Path
    }
}


function az-Confirm-AzDevOpsSmokeQuery {
    $count = Invoke-AzDevOpsSmokeQuery
    if ($null -eq $count) {
        Write-Host "  X Smoke query failed" -ForegroundColor Red
        Write-Host "    Try: az boards query --wiql 'Select [System.Id] From WorkItems Where [System.AssignedTo] = @Me'"
        return New-AzDevOpsStepResult -Ok $false -FailMessage 'smoke query failed'
    }
    Write-Host "  OK  Smoke test passed ($count items assigned to you)" -ForegroundColor Green
    return New-AzDevOpsStepResult -Ok $true
}


# ---------------------------------------------------------------------------
# az-Connect-AzDevOps — thin orchestrator that runs each step in order and
# bails on the first failure with a clear NOT READY verdict.
# ---------------------------------------------------------------------------

function az-Connect-AzDevOps {

    Write-Host ""
    Write-Host "az-Connect-AzDevOps" -ForegroundColor Cyan
    Write-Host "================" -ForegroundColor Cyan

    # $steps is a closed internal array of step descriptors. Each Action is a
    # hardcoded scriptblock invoking a known function; nothing here accepts
    # untrusted input, so & $step.Action below has no injection surface.
    $steps = @(
        @{ Num = 1; Name = 'Azure CLI'; Action = { az-Confirm-AzDevOpsCli } },
        @{ Num = 2; Name = 'azure-devops extension'; Action = { az-Confirm-AzDevOpsExtension } },
        @{ Num = 3; Name = 'Optional profile env vars (AZ_USER_EMAIL, AZ_AREA)'; Action = { az-Confirm-AzDevOpsEnvVars } },
        @{ Num = 4; Name = 'Project map (multi-project)'; Action = { az-Confirm-AzDevOpsProjectMap } },
        @{ Num = 5; Name = 'Azure login session'; Action = { az-Confirm-AzDevOpsLogin } },
        @{ Num = 6; Name = 'Configure az devops defaults'; Action = { az-Set-AzDevOpsDefaults } },
        @{ Num = 7; Name = 'User-machine query files'; Action = { az-Confirm-AzDevOpsQueryFiles } },
        @{ Num = 8; Name = 'Smoke test (az boards query)'; Action = { az-Confirm-AzDevOpsSmokeQuery } }
    )

    foreach ($step in $steps) {
        Write-Host ""
        Write-Host "Step $($step.Num) of $($steps.Count) - $($step.Name)" -ForegroundColor White
        $result = & $step.Action
        if (-not $result.Ok) {
            Write-Host ""
            Write-Host "NOT READY - blocked at step $($step.Num): $($result.FailMessage)" -ForegroundColor Red
            return
        }
    }

    Write-Host ""
    $defaults = Get-AzDevOpsConfiguredDefaults
    Write-Host "READY - Azure DevOps connection verified (org=$($defaults.Org) project=$($defaults.Project))" -ForegroundColor Green
}

