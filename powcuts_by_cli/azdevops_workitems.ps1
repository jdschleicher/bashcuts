# ============================================================================
# Azure DevOps Work-Item Shortcuts
# ============================================================================
#
# Foundation file for Azure DevOps work-item navigation shortcuts.
#
# User-facing functions:
#   Connect-AzDevOps   - interactive first-run auth + setup helper (run once
#                        on a fresh machine, or any time auth feels stale)
#   Test-AzDevOpsAuth  - silent yes/no auth assertion intended for callers
#                        in later AzDevOps commands; returns $true / $false
#
# Step functions invoked by Connect-AzDevOps (also exposed for direct use,
# e.g. to debug a single failing step). Each returns a [PSCustomObject]
# with Ok (bool) and FailMessage (string or $null) properties, and prints
# its own status:
#   Confirm-AzDevOpsCli              - step 1 (CLI on PATH + version echo)
#   Confirm-AzDevOpsExtension        - step 2 (azure-devops extension; offers install)
#   Confirm-AzDevOpsEnvVars          - step 3 (required $profile env vars set)
#   Confirm-AzDevOpsLogin            - step 4 (az login session; offers login)
#   Set-AzDevOpsDefaults             - step 5 (az devops configure --defaults)
#   Confirm-AzDevOpsSmokeQuery       - step 6 (az boards query smoke test)
#
# Silent diagnostic helpers (pure checks, no I/O — used by Test-AzDevOpsAuth):
#   Test-AzDevOpsCliPresent          - is the `az` CLI on PATH?
#   Test-AzDevOpsExtensionInstalled  - is the `azure-devops` extension installed?
#   Get-AzDevOpsMissingEnvVars       - returns array of required env vars not set
#   Test-AzDevOpsLoggedIn            - does `az account show` succeed?
#   Invoke-AzDevOpsSmokeQuery        - runs WIQL "items assigned to me",
#                                       returns count or $null on failure
#
# Expected $profile environment variables (set these once in your $profile):
#
#   $env:AZ_DEVOPS_ORG = 'https://dev.azure.com/myorg'   # full org URL
#   $env:AZ_PROJECT    = 'My Project'                    # project name
#   $env:AZ_USER_EMAIL = 'user@example.com'              # your AAD email
#   $env:AZ_AREA       = 'My Project\My Team'            # default area path
#   $env:AZ_ITERATION  = 'My Project\Sprint 42'          # default iteration
#
# Prereqs:
#   - Azure CLI        : https://aka.ms/installazurecli
#   - azure-devops ext : az extension add --name azure-devops
#
# First-run:
#   PS> Connect-AzDevOps
# ============================================================================


# ---------------------------------------------------------------------------
# Silent diagnostic helpers (no I/O; safe for Test-AzDevOpsAuth callers)
# ---------------------------------------------------------------------------

function Test-AzDevOpsCliPresent {
    return [bool](Get-Command az -ErrorAction SilentlyContinue)
}


function Test-AzDevOpsExtensionInstalled {
    $name = az extension list --query "[?name=='azure-devops'].name" -o tsv 2>$null
    return ($LASTEXITCODE -eq 0 -and $name -eq 'azure-devops')
}


function Get-AzDevOpsMissingEnvVars {
    $missing = @()
    if (-not $env:AZ_DEVOPS_ORG) { $missing += 'AZ_DEVOPS_ORG' }
    if (-not $env:AZ_PROJECT)    { $missing += 'AZ_PROJECT' }
    return ,$missing
}


function Test-AzDevOpsLoggedIn {
    $null = az account show 2>$null
    return ($LASTEXITCODE -eq 0)
}


function Invoke-AzDevOpsSmokeQuery {
    $wiql = 'Select [System.Id] From WorkItems Where [System.AssignedTo] = @Me'
    $json = az boards query --wiql $wiql --output json 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    try {
        $items = $json | ConvertFrom-Json
        return @($items).Count
    } catch {
        return $null
    }
}


function Test-AzDevOpsAuth {
    if (-not (Test-AzDevOpsCliPresent))                { return $false }
    if ((Get-AzDevOpsMissingEnvVars).Count -gt 0)      { return $false }
    if ($null -eq (Invoke-AzDevOpsSmokeQuery))         { return $false }
    return $true
}


# ---------------------------------------------------------------------------
# Step functions invoked by Connect-AzDevOps. Each owns its print + I/O for
# one step and returns a [PSCustomObject] with Ok (bool) and FailMessage
# (string or $null) properties.
# ---------------------------------------------------------------------------

function Confirm-AzDevOpsCli {
    if (-not (Test-AzDevOpsCliPresent)) {
        Write-Host "  X az CLI not on PATH" -ForegroundColor Red
        if ($IsWindows) {
            Write-Host "    Install via: winget install Microsoft.AzureCLI"
            Write-Host "    Or see: https://aka.ms/installazurecli"
        } elseif ($IsMacOS) {
            Write-Host "    Install via: brew install azure-cli"
            Write-Host "    Or see: https://aka.ms/installazurecli-mac"
        } else {
            Write-Host "    See: https://learn.microsoft.com/cli/azure/install-azure-cli-linux"
        }
        return [PSCustomObject]@{ Ok = $false; FailMessage = 'az CLI missing' }
    }
    $azVersion = (az version --output json 2>$null | ConvertFrom-Json).'azure-cli'
    Write-Host "  OK  az CLI present (v$azVersion)" -ForegroundColor Green
    return [PSCustomObject]@{ Ok = $true; FailMessage = $null }
}


function Confirm-AzDevOpsExtension {
    if (-not (Test-AzDevOpsExtensionInstalled)) {
        Write-Host "  !  azure-devops extension not installed" -ForegroundColor Yellow
        $resp = Read-Host "    Install now? [Y/n]"
        if ($resp -match '^(n|no)$') {
            Write-Host "    Hint: az extension add --name azure-devops"
            return [PSCustomObject]@{ Ok = $false; FailMessage = 'extension missing' }
        }
        az extension add --name azure-devops 2>&1 | Out-Host
        if (-not (Test-AzDevOpsExtensionInstalled)) {
            return [PSCustomObject]@{ Ok = $false; FailMessage = 'extension install failed' }
        }
    }
    Write-Host "  OK  azure-devops extension installed" -ForegroundColor Green
    return [PSCustomObject]@{ Ok = $true; FailMessage = $null }
}


function Confirm-AzDevOpsEnvVars {
    $missing = Get-AzDevOpsMissingEnvVars
    if ($missing.Count -gt 0) {
        Write-Host "  X Missing env vars: $($missing -join ', ')" -ForegroundColor Red
        Write-Host ""
        Write-Host "    Add this block to your `$profile and reload (open a new terminal):" -ForegroundColor Yellow
        Write-Host "    ---------------------------------------------------------------"
        Write-Host "    `$env:AZ_DEVOPS_ORG = 'https://dev.azure.com/myorg'"
        Write-Host "    `$env:AZ_PROJECT    = 'My Project'"
        Write-Host "    `$env:AZ_USER_EMAIL = 'user@example.com'"
        Write-Host "    `$env:AZ_AREA       = 'My Project\My Team'"
        Write-Host "    `$env:AZ_ITERATION  = 'My Project\Sprint 42'"
        Write-Host "    ---------------------------------------------------------------"
        Write-Host "    See README section 'Azure DevOps work-item shortcuts' for details."
        return [PSCustomObject]@{ Ok = $false; FailMessage = 'env vars missing' }
    }
    Write-Host "  OK  AZ_DEVOPS_ORG = $env:AZ_DEVOPS_ORG" -ForegroundColor Green
    Write-Host "  OK  AZ_PROJECT    = $env:AZ_PROJECT" -ForegroundColor Green
    return [PSCustomObject]@{ Ok = $true; FailMessage = $null }
}


function Confirm-AzDevOpsLogin {
    if (-not (Test-AzDevOpsLoggedIn)) {
        Write-Host "  !  No active az login session" -ForegroundColor Yellow
        $resp = Read-Host "    Run 'az login' now? [Y/n]"
        if ($resp -match '^(n|no)$') {
            Write-Host "    Hint: az login"
            return [PSCustomObject]@{ Ok = $false; FailMessage = 'not logged in' }
        }
        az login | Out-Host
        if (-not (Test-AzDevOpsLoggedIn)) {
            return [PSCustomObject]@{ Ok = $false; FailMessage = 'az login failed' }
        }
    }
    $account = az account show --output json 2>$null | ConvertFrom-Json
    Write-Host "  OK  Logged in as $($account.user.name) (sub: $($account.name))" -ForegroundColor Green
    return [PSCustomObject]@{ Ok = $true; FailMessage = $null }
}


function Set-AzDevOpsDefaults {
    $configOutput = az devops configure --defaults "organization=$env:AZ_DEVOPS_ORG" "project=$env:AZ_PROJECT" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  X az devops configure failed" -ForegroundColor Red
        Write-Host "    $configOutput"
        return [PSCustomObject]@{ Ok = $false; FailMessage = 'configure failed' }
    }
    Write-Host "  OK  Defaults set: org=$env:AZ_DEVOPS_ORG project=$env:AZ_PROJECT" -ForegroundColor Green
    return [PSCustomObject]@{ Ok = $true; FailMessage = $null }
}


function Confirm-AzDevOpsSmokeQuery {
    $count = Invoke-AzDevOpsSmokeQuery
    if ($null -eq $count) {
        Write-Host "  X Smoke query failed" -ForegroundColor Red
        Write-Host "    Try: az boards query --wiql 'Select [System.Id] From WorkItems Where [System.AssignedTo] = @Me'"
        return [PSCustomObject]@{ Ok = $false; FailMessage = 'smoke query failed' }
    }
    Write-Host "  OK  Smoke test passed ($count items assigned to you)" -ForegroundColor Green
    return [PSCustomObject]@{ Ok = $true; FailMessage = $null }
}


# ---------------------------------------------------------------------------
# Connect-AzDevOps — thin orchestrator that runs each step in order and
# bails on the first failure with a clear NOT READY verdict.
# ---------------------------------------------------------------------------

function Connect-AzDevOps {

    Write-Host ""
    Write-Host "Connect-AzDevOps" -ForegroundColor Cyan
    Write-Host "================" -ForegroundColor Cyan

    # $steps is a closed internal array of step descriptors. Each Action is a
    # hardcoded scriptblock invoking a known function; nothing here accepts
    # untrusted input, so & $step.Action below has no injection surface.
    $steps = @(
        @{ Num = 1; Name = 'Azure CLI';                     Action = { Confirm-AzDevOpsCli } },
        @{ Num = 2; Name = 'azure-devops extension';        Action = { Confirm-AzDevOpsExtension } },
        @{ Num = 3; Name = 'Profile environment variables'; Action = { Confirm-AzDevOpsEnvVars } },
        @{ Num = 4; Name = 'Azure login session';           Action = { Confirm-AzDevOpsLogin } },
        @{ Num = 5; Name = 'Configure az devops defaults';  Action = { Set-AzDevOpsDefaults } },
        @{ Num = 6; Name = 'Smoke test (az boards query)';  Action = { Confirm-AzDevOpsSmokeQuery } }
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
    Write-Host "READY - Azure DevOps connection verified for project=$env:AZ_PROJECT in org=$env:AZ_DEVOPS_ORG" -ForegroundColor Green
}
