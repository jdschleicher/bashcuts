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
# Diagnostic helpers (also exposed for direct use):
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


function Connect-AzDevOps {

    Write-Host ""
    Write-Host "Connect-AzDevOps" -ForegroundColor Cyan
    Write-Host "================" -ForegroundColor Cyan

    # Step 1 of 6 - az CLI on PATH
    Write-Host ""
    Write-Host "Step 1 of 6 - Azure CLI" -ForegroundColor White
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
        Write-Host ""
        Write-Host "NOT READY - blocked at step 1: az CLI missing" -ForegroundColor Red
        return
    }
    $azVersion = (az version --output json 2>$null | ConvertFrom-Json).'azure-cli'
    Write-Host "  OK  az CLI present (v$azVersion)" -ForegroundColor Green

    # Step 2 of 6 - azure-devops extension
    Write-Host ""
    Write-Host "Step 2 of 6 - azure-devops extension" -ForegroundColor White
    if (-not (Test-AzDevOpsExtensionInstalled)) {
        Write-Host "  !  azure-devops extension not installed" -ForegroundColor Yellow
        $resp = Read-Host "    Install now? [Y/n]"
        if ($resp -match '^(n|no)$') {
            Write-Host "    Hint: az extension add --name azure-devops"
            Write-Host ""
            Write-Host "NOT READY - blocked at step 2: extension missing" -ForegroundColor Red
            return
        }
        az extension add --name azure-devops 2>&1 | Out-Host
        if (-not (Test-AzDevOpsExtensionInstalled)) {
            Write-Host ""
            Write-Host "NOT READY - blocked at step 2: extension install failed" -ForegroundColor Red
            return
        }
    }
    Write-Host "  OK  azure-devops extension installed" -ForegroundColor Green

    # Step 3 of 6 - profile env vars
    Write-Host ""
    Write-Host "Step 3 of 6 - Profile environment variables" -ForegroundColor White
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
        Write-Host ""
        Write-Host "NOT READY - blocked at step 3: env vars missing" -ForegroundColor Red
        return
    }
    Write-Host "  OK  AZ_DEVOPS_ORG = $env:AZ_DEVOPS_ORG" -ForegroundColor Green
    Write-Host "  OK  AZ_PROJECT    = $env:AZ_PROJECT" -ForegroundColor Green

    # Step 4 of 6 - az login session
    Write-Host ""
    Write-Host "Step 4 of 6 - Azure login session" -ForegroundColor White
    if (-not (Test-AzDevOpsLoggedIn)) {
        Write-Host "  !  No active az login session" -ForegroundColor Yellow
        $resp = Read-Host "    Run 'az login' now? [Y/n]"
        if ($resp -match '^(n|no)$') {
            Write-Host "    Hint: az login"
            Write-Host ""
            Write-Host "NOT READY - blocked at step 4: not logged in" -ForegroundColor Red
            return
        }
        az login | Out-Host
        if (-not (Test-AzDevOpsLoggedIn)) {
            Write-Host ""
            Write-Host "NOT READY - blocked at step 4: az login failed" -ForegroundColor Red
            return
        }
    }
    $account = az account show --output json 2>$null | ConvertFrom-Json
    Write-Host "  OK  Logged in as $($account.user.name) (sub: $($account.name))" -ForegroundColor Green

    # Step 5 of 6 - configure az devops defaults
    Write-Host ""
    Write-Host "Step 5 of 6 - Configure az devops defaults" -ForegroundColor White
    $configOutput = az devops configure --defaults "organization=$env:AZ_DEVOPS_ORG" "project=$env:AZ_PROJECT" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  X az devops configure failed" -ForegroundColor Red
        Write-Host "    $configOutput"
        Write-Host ""
        Write-Host "NOT READY - blocked at step 5: configure failed" -ForegroundColor Red
        return
    }
    Write-Host "  OK  Defaults set: org=$env:AZ_DEVOPS_ORG project=$env:AZ_PROJECT" -ForegroundColor Green

    # Step 6 of 6 - smoke test boards query
    Write-Host ""
    Write-Host "Step 6 of 6 - Smoke test (az boards query)" -ForegroundColor White
    $count = Invoke-AzDevOpsSmokeQuery
    if ($null -eq $count) {
        Write-Host "  X Smoke query failed" -ForegroundColor Red
        Write-Host "    Try: az boards query --wiql 'Select [System.Id] From WorkItems Where [System.AssignedTo] = @Me'"
        Write-Host ""
        Write-Host "NOT READY - blocked at step 6: smoke query failed" -ForegroundColor Red
        return
    }
    Write-Host "  OK  Smoke test passed ($count items assigned to you)" -ForegroundColor Green

    # Final verdict
    Write-Host ""
    Write-Host "READY - Azure DevOps connection verified for project=$env:AZ_PROJECT in org=$env:AZ_DEVOPS_ORG" -ForegroundColor Green
}
