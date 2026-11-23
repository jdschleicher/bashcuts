# ============================================================================
# Azure Resources — az-Sync-AzResources
# ============================================================================
# Refreshes the tenant-keyed tile cache (see azresources_paths.ps1) from the
# signed-in `az` account:
#
#   az-Sync-AzResources              - all four tiles
#   az-Sync-AzResources -Tile roles  - one tile (tab-completes the tile names)
#
# Each tile syncs independently: a tile the tenant blocks writes a
# 'notPermitted' state, a tile that otherwise fails keeps its previous cache
# file, and neither stops the remaining tiles. When `az account show` fails the
# sync prints one `az login` hint and writes nothing.
#
# Loaded by powcuts_home.ps1.

function Invoke-AzResourcesTileFetch {
    param(
        [Parameter(Mandatory)] [string]         $Tile,
        [Parameter(Mandatory)] [PSCustomObject] $Context
    )

    $result = switch ($Tile) {
        $script:AzResourcesTileRoles {
            Get-AzResourcesRoleItems -Context $Context
        }

        $script:AzResourcesTileGroups {
            Get-AzResourcesGroupItems -Context $Context
        }

        $script:AzResourcesTileApps {
            Get-AzResourcesAppItems -Context $Context
        }

        $script:AzResourcesTileIdentities {
            Get-AzResourcesIdentityItems -Context $Context
        }

        default {
            throw "Invoke-AzResourcesTileFetch: unknown tile '$Tile'."
        }
    }

    return $result
}


function Sync-AzResourcesTile {
    # Fetch + persist one tile and print its outcome line. Returns the tile's
    # state so the orchestrator can summarize.
    param(
        [Parameter(Mandatory)] [string]         $Tile,
        [Parameter(Mandatory)] [PSCustomObject] $Context
    )

    Write-Host "-> Syncing $Tile..." -ForegroundColor Cyan

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $result = Invoke-AzResourcesTileFetch -Tile $Tile -Context $Context
    }
    catch {
        $result = New-AzResourcesTileResult -State $script:AzResourcesStateError -Message $_.Exception.Message
    }

    $sw.Stop()
    $elapsed = '{0:N1}s' -f $sw.Elapsed.TotalSeconds

    if ($result.State -eq $script:AzResourcesStateError) {
        Write-Host "  X  $Tile - $($result.Message) (in $elapsed; previous cache kept)" -ForegroundColor Red
        return $result.State
    }

    $null = Write-AzResourcesTile -TenantId $Context.TenantId -Tile $Tile -Result $result

    if ($result.State -eq $script:AzResourcesStateNotPermitted) {
        Write-Host "  --  $Tile - not permitted: $($result.Message) (in $elapsed)" -ForegroundColor Yellow
    } else {
        Write-Host "  OK  $Tile - $(@($result.Items).Count) item(s) in $elapsed" -ForegroundColor Green
    }

    foreach ($warning in $result.Warnings) {
        Write-Host "      ! $warning" -ForegroundColor DarkYellow
    }

    return $result.State
}


function az-Sync-AzResources {
    param(
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete)
            Get-AzResourcesTileNames | Where-Object { $_ -like "$wordToComplete*" }
        })]
        [string] $Tile
    )

    $commandName = 'az-Sync-AzResources'

    if ($Tile -and -not (Test-AzResourcesTileName -Name $Tile)) {
        $known = (Get-AzResourcesTileNames) -join ', '
        Write-Host "$commandName - unknown tile '$Tile'. Choose one of: $known" -ForegroundColor Red
        return
    }

    $context = Get-AzResourcesContext -CommandName $commandName

    if (-not $context) {
        return
    }

    $tiles = if ($Tile) {
        @($Tile)
    } else {
        Get-AzResourcesTileNames
    }

    Write-Host "Tenant $($context.TenantId) - $($context.UserName) - $($context.Subscriptions.Count) subscription(s)" -ForegroundColor Cyan

    $errored = 0

    foreach ($name in $tiles) {
        $state = Sync-AzResourcesTile -Tile $name -Context $context

        if ($state -eq $script:AzResourcesStateError) {
            $errored++
        }
    }

    Write-Host ""
    Write-Host "Cache: $(Get-AzResourcesTenantCacheDir -TenantId $context.TenantId)" -ForegroundColor Cyan

    if ($errored -gt 0) {
        Write-Host "Partial sync - $errored of $(@($tiles).Count) tile(s) failed." -ForegroundColor Yellow
    }
}
