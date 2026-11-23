# ============================================================================
# Azure Resources — Resource Viewer local server (Epic #265 — D)
# ============================================================================
# Serves azure-viewer/ on 127.0.0.1 over the tenant-keyed tile cache written by
# az-Sync-AzResources, on the shared localhost-viewer plumbing
# (localhost_viewer.ps1). Two strictly separate paths:
#
#   GET  /api/context              -> { tenantId } the page is showing (cheap)
#   GET  /api/tiles/<name>         -> that tile's cached JSON (cheap read)
#   POST /api/tiles/<name>/refresh -> re-run that tile's az calls, rewrite only
#                                     its cache file, return fresh JSON (expensive)
#   GET  /*                        -> the page + static assets
#
# SECURITY: the listener binds to 127.0.0.1 only (Get-LocalViewerPrefix takes a
# port, never a host), and HttpListener rejects requests whose Host header
# doesn't match that prefix, which blunts DNS-rebinding reads. The az login stays
# in the az CLI's token store — responses carry only the cached records (field
# allow-lists, no secrets). Every response ships the shared strict CSP. Refresh
# requires an application/json POST, so a cross-site simple-request can't
# trigger the expensive path.
#
# Public functions:
#   az-Start-AzResourceViewer [-Port] [-NoBrowser]
#
# Loaded by powcuts_home.ps1 after localhost_viewer.ps1, azresources_data.ps1,
# and azresources_views.ps1.

$script:AzResourcesViewerDefaultPort  = 8771      # the daily viewer owns 8770
$script:AzResourcesViewerStaticSubdir = 'azure-viewer'
$script:AzResourcesViewerDisplayName  = 'Azure Resource Viewer'
$script:AzResourcesViewerTilesPrefix  = '/api/tiles/'
$script:AzResourcesViewerContextPath  = '/api/context'
$script:AzResourcesViewerRefreshVerb  = 'refresh'
$script:AzResourcesViewerRefreshSegments = 2     # /api/tiles/<name>/refresh

# The az account context the refresh path needs (tenant + my object id). Resolved
# on the first refresh — not at startup — so opening the dashboard never waits
# on a directory lookup. Only the object-id lookup is memoized: every refresh
# re-reads the live az account (local, no network) and drops this when the
# tenant or signed-in user changed underneath the running server.
$script:AzResourcesViewerAccountContext = $null


# ---------------------------------------------------------------------------
# Layout + response helpers
# ---------------------------------------------------------------------------

function Get-AzResourcesViewerStaticRoot {
    # azure-viewer/ lives at the repo root, one level up from powcuts_by_cli/.
    $root = Join-Path (Split-Path -Parent $PSScriptRoot) $script:AzResourcesViewerStaticSubdir
    return $root
}


function Write-AzResourcesViewerJson {
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerResponse] $Response,
        [Parameter(Mandatory)] [int] $StatusCode,
        [Parameter(Mandatory)] [AllowNull()] $Object
    )

    Write-LocalViewerJson -Response $Response -StatusCode $StatusCode -Object $Object `
        -ContentSecurityPolicy $script:LocalViewerStrictContentSecurityPolicy `
        -JsonDepth $script:AzResourcesJsonDepth
}


function Write-AzResourcesViewerError {
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerResponse] $Response,
        [Parameter(Mandatory)] [int]    $StatusCode,
        [Parameter(Mandatory)] [string] $Message
    )

    Write-LocalViewerError -Response $Response -StatusCode $StatusCode -Message $Message `
        -ContentSecurityPolicy $script:LocalViewerStrictContentSecurityPolicy `
        -JsonDepth $script:AzResourcesJsonDepth
}


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

function Get-AzResourcesViewerTileRoute {
    # /api/tiles/<name> or /api/tiles/<name>/refresh -> { Tile, IsRefresh }, or
    # $null for anything else (including an unknown extra segment).
    param([Parameter(Mandatory)] [string] $Path)

    $segments = Split-LocalViewerApiPath -Path $Path -Prefix $script:AzResourcesViewerTilesPrefix
    if ($null -eq $segments -or $segments.Count -gt $script:AzResourcesViewerRefreshSegments) {
        return $null
    }

    $isRefresh = ($segments.Count -eq $script:AzResourcesViewerRefreshSegments)
    if ($isRefresh -and $segments[1] -ne $script:AzResourcesViewerRefreshVerb) {
        return $null
    }

    $route = [PSCustomObject]@{
        Tile      = $segments[0]
        IsRefresh = $isRefresh
    }

    return $route
}


function Get-AzResourcesViewerRefreshContext {
    # The az account context for a refresh, or $null when az isn't logged in or
    # is now logged into a different tenant than the one this server shows
    # (refreshing would write the other tenant's data into this tenant's cache).
    # The live account is re-read on EVERY call — only the slow object-id
    # lookup is reused, and only while the tenant and user are unchanged.
    param([Parameter(Mandatory)] [string] $TenantId)

    $live = Get-AzResourcesLocalAccount

    if ($null -eq $live -or $live.TenantId -ne $TenantId) {
        $script:AzResourcesViewerAccountContext = $null
        return $null
    }

    $cached = $script:AzResourcesViewerAccountContext
    $isCacheValid = ($null -ne $cached) -and ($cached.TenantId -eq $live.TenantId) -and ($cached.UserName -eq $live.UserName)

    if ($isCacheValid) {
        return $cached
    }

    $context = Get-AzResourcesAccountContext

    if ($null -eq $context -or $context.TenantId -ne $TenantId) {
        $script:AzResourcesViewerAccountContext = $null
        return $null
    }

    $script:AzResourcesViewerAccountContext = $context
    return $context
}


function Invoke-AzResourcesViewerRefresh {
    # EXPENSIVE path for one tile: re-run only its az calls through the same
    # Update-AzResourcesTile az-Sync-AzResources uses, then answer with the
    # re-read cache model so GET and POST share one response shape.
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerResponse] $Response,
        [Parameter(Mandatory)] [string] $Tile,
        [Parameter(Mandatory)] [string] $TenantId
    )

    $context = Get-AzResourcesViewerRefreshContext -TenantId $TenantId
    if ($null -eq $context) {
        Write-AzResourcesViewerError -Response $Response -StatusCode 409 `
            -Message "Can't refresh: az isn't logged into this tenant. Run 'az login' (and pick this tenant), then try again."
        return
    }

    try {
        $subscriptions = $null
        if (Test-AzResourcesTileNeedsSubscriptions -Tile $Tile) {
            $subscriptions = Get-AzResourcesSubscriptions -TenantId $TenantId
        }

        $null = Update-AzResourcesTile -Tile $Tile -Context $context -Subscriptions $subscriptions
    }
    catch {
        # Keep az's error text (which can name subscriptions / paths) in the
        # console; the browser gets a generic message and the old cache stays.
        Write-Host "$($script:AzResourcesViewerDisplayName): refresh of '$Tile' failed - $($_.Exception.Message)" -ForegroundColor Red
        Write-AzResourcesViewerError -Response $Response -StatusCode 502 -Message 'Refresh failed; the previous cache was kept. See the server console.'
        return
    }

    $model = Read-AzResourcesTileModel -TenantId $TenantId -Tile $Tile
    if ($null -eq $model) {
        Write-AzResourcesViewerError -Response $Response -StatusCode 500 -Message 'Refresh ran, but the tile cache could not be read back.'
        return
    }

    Write-AzResourcesViewerJson -Response $Response -StatusCode 200 -Object $model
}


function Invoke-AzResourcesViewerTileRequest {
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerContext] $Context,
        [Parameter(Mandatory)] [PSCustomObject] $Route,
        [Parameter(Mandatory)] [string] $TenantId
    )

    $request  = $Context.Request
    $response = $Context.Response
    $method   = $request.HttpMethod

    if ($script:AzResourcesTileNames -notcontains $Route.Tile) {
        Write-AzResourcesViewerError -Response $response -StatusCode 404 -Message "Unknown tile '$($Route.Tile)'."
        return
    }

    if ($Route.IsRefresh) {
        if ($method -ne 'POST') {
            Write-AzResourcesViewerError -Response $response -StatusCode 405 -Message 'Refresh requires POST.'
            return
        }

        if (-not (Test-LocalViewerStateChangeAllowed -Request $request)) {
            Write-AzResourcesViewerError -Response $response -StatusCode 415 -Message 'Refresh requires a same-origin application/json request.'
            return
        }

        Invoke-AzResourcesViewerRefresh -Response $response -Tile $Route.Tile -TenantId $TenantId
        return
    }

    if ($method -ne 'GET') {
        Write-AzResourcesViewerError -Response $response -StatusCode 405 -Message 'Tile read requires GET.'
        return
    }

    $model = Read-AzResourcesTileModel -TenantId $TenantId -Tile $Route.Tile

    if ($null -eq $model) {
        Write-AzResourcesViewerError -Response $response -StatusCode 404 -Message "Tile '$($Route.Tile)' has no cache yet. Run az-Sync-AzResources or refresh this tile."
        return
    }

    Write-AzResourcesViewerJson -Response $response -StatusCode 200 -Object $model
}


function Invoke-AzResourcesViewerRequest {
    # Front door: /api/context, /api/tiles/*, else a static-asset GET. Any
    # handler failure becomes a generic 500 so one bad request can never kill the
    # serving loop or leak exception detail to the browser.
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerContext] $Context,
        [Parameter(Mandatory)] [PSCustomObject] $State
    )

    $response = $Context.Response

    try {
        $path = $Context.Request.Url.AbsolutePath

        if ($path -eq $script:AzResourcesViewerContextPath) {
            if ($Context.Request.HttpMethod -ne 'GET') {
                Write-AzResourcesViewerError -Response $response -StatusCode 405 -Message 'Context is GET only.'
                return
            }

            $payload = [ordered]@{ tenantId = $State.TenantId }
            Write-AzResourcesViewerJson -Response $response -StatusCode 200 -Object $payload
            return
        }

        $tileRoute = Get-AzResourcesViewerTileRoute -Path $path
        if ($null -ne $tileRoute) {
            Invoke-AzResourcesViewerTileRequest -Context $Context -Route $tileRoute -TenantId $State.TenantId
            return
        }

        Invoke-LocalViewerStaticRequest -Context $Context -StaticRoot $State.StaticRoot `
            -ContentSecurityPolicy $script:LocalViewerStrictContentSecurityPolicy `
            -JsonDepth $script:AzResourcesJsonDepth
    }
    catch {
        Write-LocalViewerUnhandledError -Response $response -DisplayName $script:AzResourcesViewerDisplayName `
            -ErrorRecord $_ -ContentSecurityPolicy $script:LocalViewerStrictContentSecurityPolicy `
            -JsonDepth $script:AzResourcesJsonDepth
    }
}


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

function az-Start-AzResourceViewer {
    <#
    .SYNOPSIS
        Serve the Azure Resource Viewer dashboard on 127.0.0.1.

    .DESCRIPTION
        Binds to loopback only and serves azure-viewer/ over the tile cache
        written by az-Sync-AzResources: GET /api/tiles/<name> is a cheap cache
        read; POST /api/tiles/<name>/refresh re-runs just that tile's az calls
        and rewrites just its cache file. The tenant is the one az is logged
        into (from the local az profile), else the most recently synced one.
        The az login never leaves the az CLI. Press Ctrl+C to stop.

    .PARAMETER Port
        Loopback TCP port to listen on. Defaults to 8771 (the daily viewer uses 8770).

    .PARAMETER NoBrowser
        Skip auto-opening the default browser (useful for scripted / curl checks).

    .EXAMPLE
        az-Start-AzResourceViewer

    .EXAMPLE
        az-Start-AzResourceViewer -Port 8790 -NoBrowser
    #>
    param(
        [int]    $Port = $script:AzResourcesViewerDefaultPort,
        [switch] $NoBrowser
    )

    $staticRoot = Get-AzResourcesViewerStaticRoot
    if (-not (Test-Path -LiteralPath $staticRoot)) {
        Write-Host "$($script:AzResourcesViewerDisplayName) assets not found at $staticRoot" -ForegroundColor Red
        return
    }

    $tenantId = Get-AzResourcesViewTenantId
    if (-not $tenantId) {
        Write-Host "No Azure tenant found. Run 'az login', then az-Sync-AzResources, and try again." -ForegroundColor Yellow
        return
    }

    try {
        $cacheDir = Get-AzResourcesCacheDir -TenantId $tenantId
    }
    catch {
        Write-Host "Cannot serve tenant '$tenantId': $($_.Exception.Message)" -ForegroundColor Red
        return
    }

    if (-not (Test-Path -LiteralPath $cacheDir)) {
        Write-Host "No cache yet for tenant $tenantId - tiles will be empty until you run az-Sync-AzResources or refresh them." -ForegroundColor Yellow
    }

    $state = [PSCustomObject]@{
        TenantId   = $tenantId
        StaticRoot = $staticRoot
    }

    $requestHandler = {
        param(
            [System.Net.HttpListenerContext] $Context,
            [PSCustomObject] $HandlerState
        )

        Invoke-AzResourcesViewerRequest -Context $Context -State $HandlerState
    }

    Start-LocalViewerServer -Port $Port -DisplayName $script:AzResourcesViewerDisplayName `
        -RequestHandler $requestHandler -HandlerState $state `
        -InfoLines @("tenant: $tenantId", "cache:  $cacheDir") -NoBrowser:$NoBrowser
}
