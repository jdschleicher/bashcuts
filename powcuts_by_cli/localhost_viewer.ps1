# ============================================================================
# Localhost viewer — shared server plumbing for the browser dashboards
# ============================================================================
# The generic half of a cache-first localhost viewer, shared by the Azure
# DevOps Daily Viewer (daily_viewer.ps1) and the Azure Resource Viewer
# (Epic #265) so both run on one hardened implementation instead of two copies:
#
#   - loopback listener start / serve loop / stop (127.0.0.1 only, by design)
#   - security headers, with each viewer passing its own Content-Security-Policy
#   - MIME lookup + static asset resolution (path-traversal guarded)
#   - byte / JSON / error response writers
#   - bounded JSON request-body read
#   - per-tile JSON cache write + mtime-based staleness read
#
# Nothing here knows about a specific viewer: the static root, cache path, CSP,
# JSON depth, port, and stale threshold are all parameters. Viewer-specific
# routes, tiles, and constants stay in the viewer's own file.
#
# SECURITY: Get-LocalViewerPrefix always builds a 127.0.0.1 prefix and takes
# only a port, so no caller can bind 0.0.0.0 / a public interface through it.
#
# Depends on Test-WpfIsWindows from pow_common.ps1 (Open-LocalViewerBrowser).
# Loaded by powcuts_home.ps1 after pow_common.ps1 and BEFORE any viewer file
# that calls these helpers.

$script:LocalViewerLoopbackAddress  = '127.0.0.1'
$script:LocalViewerFallbackMimeType = 'application/octet-stream'
$script:LocalViewerJsonContentType  = 'application/json; charset=utf-8'
$script:LocalViewerIndexFile        = 'index.html'
$script:LocalViewerJsonMediaType    = 'application/json'
$script:LocalViewerMediaTypeSep     = ';'
$script:LocalViewerFetchSiteHeader  = 'Sec-Fetch-Site'
$script:LocalViewerOriginHeader     = 'Origin'
$script:LocalViewerSameOriginSites  = @('same-origin', 'none')   # Sec-Fetch-Site values a same-page fetch / typed URL send
$script:LocalViewerInternalError    = 'Internal server error.'
$script:LocalViewerDefaultHttpPort        = 80    # a browser's Origin omits the port when it's the default
$script:LocalViewerStatusForbidden        = 403
$script:LocalViewerStatusUnsupportedMedia = 415

# Strict Content-Security-Policy shared by every viewer. Pages load styles.css +
# app.js as same-origin assets and fetch /api/* same-origin; there are no inline
# handlers/styles, CDN scripts, or webfonts, so 'self' with no 'unsafe-inline'
# loads clean. Inline <svg> uses presentation attributes (fill/stroke), which CSP
# does not gate. base-uri/object/frame/form are locked down so an injected
# <base>/<object>/framing can't reroute the page.
$script:LocalViewerStrictContentSecurityPolicy = @(
    "default-src 'self'"
    "base-uri 'none'"
    "object-src 'none'"
    "frame-ancestors 'none'"
    "form-action 'self'"
    "img-src 'self' data:"
) -join '; '

# Relative-age buckets — mirror formatAge in daily-viewer/app.js.
$script:LocalViewerJustNowSeconds    = 45
$script:LocalViewerSecondsPerMinute  = 60
$script:LocalViewerMinutesPerHour    = 60
$script:LocalViewerHoursPerDay       = 24

$script:LocalViewerMimeTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'text/javascript; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.svg'  = 'image/svg+xml'
    '.ico'  = 'image/x-icon'
    '.png'  = 'image/png'
    '.woff2'= 'font/woff2'
}


# ---------------------------------------------------------------------------
# Server lifecycle
# ---------------------------------------------------------------------------

function Get-LocalViewerPrefix {
    param([Parameter(Mandatory)] [int] $Port)

    $prefix = "http://$($script:LocalViewerLoopbackAddress):$Port/"
    return $prefix
}


function Start-LocalViewerListener {
    # Bind an HttpListener to the loopback prefix for -Port. Returns the started
    # listener, or $null (after printing the fix-it hint) when the bind fails —
    # typically a port already in use or a missing Windows URL reservation.
    param([Parameter(Mandatory)] [int] $Port)

    $prefix = Get-LocalViewerPrefix -Port $Port
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($prefix)

    try {
        $listener.Start()
    }
    catch [System.Net.HttpListenerException] {
        Write-Host "Could not bind $prefix - $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'On Windows a one-time URL reservation may be needed:' -ForegroundColor Yellow
        Write-Host "  netsh http add urlacl url=$prefix user=$env:USERNAME" -ForegroundColor Yellow
        Write-Host 'Or pass a different -Port.' -ForegroundColor Yellow
        return $null
    }

    return $listener
}


function Stop-LocalViewerListener {
    param([Parameter(Mandatory)] [System.Net.HttpListener] $Listener)

    if ($Listener.IsListening) {
        $Listener.Stop()
    }

    $Listener.Close()
}


function Invoke-LocalViewerListenLoop {
    # Serve requests one at a time until the listener stops (Ctrl+C / disposal),
    # handing each HttpListenerContext plus -HandlerState to -RequestHandler.
    # State travels explicitly as the handler's second argument rather than via
    # dynamic scoping, so a local in this function can never shadow it. The
    # handler owns its own try/catch so one bad request never kills the loop;
    # the finally here guarantees the listener is released however it exits.
    param(
        [Parameter(Mandatory)] [System.Net.HttpListener] $Listener,
        [Parameter(Mandatory)] [scriptblock] $RequestHandler,
        [Parameter(Mandatory)] [string] $DisplayName,
        [AllowNull()] $HandlerState = $null
    )

    try {
        while ($Listener.IsListening) {
            $context = $Listener.GetContext()
            & $RequestHandler $context $HandlerState
        }
    }
    catch {
        # GetContext throws when the listener is stopped (Ctrl+C / disposal) —
        # fall through to the finally so shutdown stays clean.
    }
    finally {
        Stop-LocalViewerListener -Listener $Listener
        Write-Host "$DisplayName stopped." -ForegroundColor DarkGray
    }
}


function Start-LocalViewerServer {
    # The whole serving lifecycle every viewer shares: bind loopback, print the
    # serving banner (+ any -InfoLines), open the browser, then run the request
    # loop until Ctrl+C. Returns without serving when the bind fails (the
    # listener helper has already printed the fix-it hint).
    param(
        [Parameter(Mandatory)] [int] $Port,
        [Parameter(Mandatory)] [string] $DisplayName,
        [Parameter(Mandatory)] [scriptblock] $RequestHandler,
        [AllowNull()] $HandlerState = $null,
        [string[]] $InfoLines = @(),
        [switch] $NoBrowser
    )

    $listener = Start-LocalViewerListener -Port $Port
    if ($null -eq $listener) {
        return
    }

    $prefix = Get-LocalViewerPrefix -Port $Port
    Write-Host "$DisplayName serving at $prefix (Ctrl+C to stop)" -ForegroundColor Green

    foreach ($line in $InfoLines) {
        Write-Host "  $line" -ForegroundColor DarkGray
    }

    if (-not $NoBrowser) {
        Open-LocalViewerBrowser -Url $prefix
    }

    Invoke-LocalViewerListenLoop -Listener $listener -RequestHandler $RequestHandler `
        -DisplayName $DisplayName -HandlerState $HandlerState
}


function Write-LocalViewerUnhandledError {
    # A viewer front door's catch-all: keep the exception detail (which can name
    # filesystem paths or az output) in the server console and hand the browser
    # a generic 500. Swallows a second failure — the response may already be
    # closed or the client gone — so one bad request never stops the loop.
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerResponse] $Response,
        [Parameter(Mandatory)] [string] $DisplayName,
        [Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord,
        [Parameter(Mandatory)] [string] $ContentSecurityPolicy,
        [Parameter(Mandatory)] [int] $JsonDepth
    )

    Write-Host "$DisplayName request error: $($ErrorRecord.Exception.Message)" -ForegroundColor Red

    try {
        Write-LocalViewerError -Response $Response -StatusCode 500 -Message $script:LocalViewerInternalError `
            -ContentSecurityPolicy $ContentSecurityPolicy -JsonDepth $JsonDepth
    }
    catch {
        # response already closed / client gone — nothing more we can do
    }
}


function ConvertTo-LocalViewerRoundedHalfUp {
    # JavaScript's Math.round (half rounds up) for non-negative values;
    # [math]::Round defaults to banker's rounding, which would drift from the
    # browser at every .5 boundary.
    param([Parameter(Mandatory)] [double] $Value)

    $rounded = [int][math]::Floor($Value + 0.5)
    return $rounded
}


function Get-LocalViewerRelativeTime {
    # Compact "how long ago" label ("just now", "12m ago", "3h ago", "2d ago").
    # Same thresholds and rounding as formatAge in daily-viewer/app.js (each
    # unit is rounded from the previous rounded unit), so the browser and the
    # terminal print the same label for the same age.
    param([Parameter(Mandatory)] [datetime] $When)

    $seconds = ((Get-Date) - $When).TotalSeconds

    if ($seconds -lt $script:LocalViewerJustNowSeconds) {
        return 'just now'
    }

    $mins = ConvertTo-LocalViewerRoundedHalfUp -Value ($seconds / $script:LocalViewerSecondsPerMinute)
    if ($mins -lt $script:LocalViewerMinutesPerHour) {
        return "${mins}m ago"
    }

    $hours = ConvertTo-LocalViewerRoundedHalfUp -Value ($mins / $script:LocalViewerMinutesPerHour)
    if ($hours -lt $script:LocalViewerHoursPerDay) {
        return "${hours}h ago"
    }

    $days = ConvertTo-LocalViewerRoundedHalfUp -Value ($hours / $script:LocalViewerHoursPerDay)
    return "${days}d ago"
}


function Open-LocalViewerBrowser {
    param([Parameter(Mandatory)] [string] $Url)

    try {
        if (Test-WpfIsWindows) {
            Start-Process $Url
        } elseif ($IsMacOS) {
            & open $Url
        } else {
            & xdg-open $Url
        }
    }
    catch {
        Write-Host "Open $Url in your browser." -ForegroundColor Yellow
    }
}


# ---------------------------------------------------------------------------
# Static asset serving
# ---------------------------------------------------------------------------

function Get-LocalViewerContentType {
    param([Parameter(Mandatory)] [string] $Path)

    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()

    $type = if ($script:LocalViewerMimeTypes.ContainsKey($ext)) {
        $script:LocalViewerMimeTypes[$ext]
    } else {
        $script:LocalViewerFallbackMimeType
    }

    return $type
}


function Resolve-LocalViewerAssetPath {
    # Map a request path to a file inside the static root, refusing anything that
    # escapes the root (path traversal). Returns $null when the target is outside
    # the root or does not exist, so the router answers 404.
    param(
        [Parameter(Mandatory)] [string] $RequestPath,
        [Parameter(Mandatory)] [string] $Root
    )

    $relative = $RequestPath.TrimStart('/')
    if (-not $relative) {
        $relative = $script:LocalViewerIndexFile
    }

    $candidate = Join-Path $Root $relative
    $fullCandidate = [System.IO.Path]::GetFullPath($candidate)
    $fullRoot = [System.IO.Path]::GetFullPath($Root)

    $rootPrefix = $fullRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullCandidate.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $fullCandidate -PathType Leaf)) {
        return $null
    }

    return $fullCandidate
}


function Invoke-LocalViewerStaticRequest {
    # GET-only static file handler: resolve the request inside -StaticRoot and
    # stream it back with its MIME type, or answer 405 / 404 as JSON.
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerContext] $Context,
        [Parameter(Mandatory)] [string] $StaticRoot,
        [Parameter(Mandatory)] [string] $ContentSecurityPolicy,
        [Parameter(Mandatory)] [int]    $JsonDepth
    )

    $request  = $Context.Request
    $response = $Context.Response

    if ($request.HttpMethod -ne 'GET') {
        Write-LocalViewerError -Response $response -StatusCode 405 -Message 'Static assets are GET only.' `
            -ContentSecurityPolicy $ContentSecurityPolicy -JsonDepth $JsonDepth
        return
    }

    $assetPath = Resolve-LocalViewerAssetPath -RequestPath $request.Url.AbsolutePath -Root $StaticRoot
    if (-not $assetPath) {
        Write-LocalViewerError -Response $response -StatusCode 404 -Message 'Not found.' `
            -ContentSecurityPolicy $ContentSecurityPolicy -JsonDepth $JsonDepth
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes($assetPath)
    $contentType = Get-LocalViewerContentType -Path $assetPath

    Write-LocalViewerBytes -Response $response -StatusCode 200 -ContentType $contentType -Body $bytes `
        -ContentSecurityPolicy $ContentSecurityPolicy
}


# ---------------------------------------------------------------------------
# HTTP response writers
# ---------------------------------------------------------------------------

function Add-LocalViewerSecurityHeaders {
    # Stamp the hardening headers on every response — HTML, static asset, JSON,
    # and error alike — since all of them funnel through the byte writer below.
    # A strict same-origin CSP is the anchor; nosniff stops MIME-confusion,
    # no-referrer keeps local URLs off the wire, and DENY refuses any framing.
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerResponse] $Response,
        [Parameter(Mandatory)] [string] $ContentSecurityPolicy
    )

    $Response.Headers['Content-Security-Policy'] = $ContentSecurityPolicy
    $Response.Headers['X-Content-Type-Options']  = 'nosniff'
    $Response.Headers['Referrer-Policy']         = 'no-referrer'
    $Response.Headers['X-Frame-Options']         = 'DENY'
}


function Write-LocalViewerBytes {
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerResponse] $Response,
        [Parameter(Mandatory)] [int]    $StatusCode,
        [Parameter(Mandatory)] [string] $ContentType,
        [Parameter(Mandatory)] [string] $ContentSecurityPolicy,
        [byte[]] $Body = @()
    )

    Add-LocalViewerSecurityHeaders -Response $Response -ContentSecurityPolicy $ContentSecurityPolicy

    $Response.StatusCode  = $StatusCode
    $Response.ContentType = $ContentType
    $Response.ContentLength64 = $Body.Length

    if ($Body.Length -gt 0) {
        $Response.OutputStream.Write($Body, 0, $Body.Length)
    }

    $Response.OutputStream.Close()
    $Response.Close()
}


function Write-LocalViewerJson {
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerResponse] $Response,
        [Parameter(Mandatory)] [int] $StatusCode,
        [Parameter(Mandatory)] [AllowNull()] $Object,
        [Parameter(Mandatory)] [string] $ContentSecurityPolicy,
        [Parameter(Mandatory)] [int] $JsonDepth
    )

    $json = $Object | ConvertTo-Json -Depth $JsonDepth
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    Write-LocalViewerBytes -Response $Response -StatusCode $StatusCode `
        -ContentType $script:LocalViewerJsonContentType -Body $bytes `
        -ContentSecurityPolicy $ContentSecurityPolicy
}


function Write-LocalViewerError {
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerResponse] $Response,
        [Parameter(Mandatory)] [int]    $StatusCode,
        [Parameter(Mandatory)] [string] $Message,
        [Parameter(Mandatory)] [string] $ContentSecurityPolicy,
        [Parameter(Mandatory)] [int]    $JsonDepth
    )

    $payload = [ordered]@{ error = $Message }
    Write-LocalViewerJson -Response $Response -StatusCode $StatusCode -Object $payload `
        -ContentSecurityPolicy $ContentSecurityPolicy -JsonDepth $JsonDepth
}


# ---------------------------------------------------------------------------
# Request parsing
# ---------------------------------------------------------------------------

function Test-LocalViewerJsonContentType {
    # True only when the media type itself (the part before any ';' parameters)
    # is application/json. Browsers decide whether a request needs a CORS
    # preflight from that media type alone, so a substring test would wave
    # through `text/plain; x=application/json` — a preflight-free cross-site POST.
    param([Parameter(Mandatory)] [System.Net.HttpListenerRequest] $Request)

    $mediaType = ([string]$Request.ContentType -split $script:LocalViewerMediaTypeSep, 2)[0].Trim()
    $isJson = $mediaType -ieq $script:LocalViewerJsonMediaType
    return $isJson
}


function Test-LocalViewerSameOriginRequest {
    # Reject anything the browser itself marks as coming from another site —
    # Sec-Fetch-Site other than same-origin / none, or an Origin header that
    # isn't this server. Another localhost port counts as another origin, so the
    # daily viewer's page can't drive the resource viewer (or vice versa).
    # Non-browser clients (curl, scripts) send neither header and pass.
    param([Parameter(Mandatory)] [System.Net.HttpListenerRequest] $Request)

    $fetchSite = [string]$Request.Headers[$script:LocalViewerFetchSiteHeader]
    if ($fetchSite -and $script:LocalViewerSameOriginSites -notcontains $fetchSite) {
        return $false
    }

    # Own origin from the fixed loopback address + the socket's local port —
    # never from the client-supplied Host header — so this check holds on its
    # own even if HttpListener's Host matching ever let a rebinding name in.
    $origin = [string]$Request.Headers[$script:LocalViewerOriginHeader]
    $port = $Request.LocalEndPoint.Port

    $ownOrigin = if ($port -eq $script:LocalViewerDefaultHttpPort) {
        "http://$($script:LocalViewerLoopbackAddress)"
    } else {
        "http://$($script:LocalViewerLoopbackAddress):$port"
    }

    if ($origin -and $origin -ne $ownOrigin) {
        return $false
    }

    return $true
}


function Get-LocalViewerStateChangeRejection {
    # Why a state-changing request (a write, an expensive refresh) must be
    # refused, or $null when it may proceed: { StatusCode, Message } with 415
    # for a non-JSON media type (JSON forces a preflight this server never
    # answers) and 403 for a request the browser marks as cross-site. Message
    # completes a sentence the caller starts ("Refresh requires …").
    param([Parameter(Mandatory)] [System.Net.HttpListenerRequest] $Request)

    if (-not (Test-LocalViewerJsonContentType -Request $Request)) {
        $unsupported = [PSCustomObject]@{
            StatusCode = $script:LocalViewerStatusUnsupportedMedia
            Message    = 'requires Content-Type: application/json.'
        }

        return $unsupported
    }

    if (-not (Test-LocalViewerSameOriginRequest -Request $Request)) {
        $forbidden = [PSCustomObject]@{
            StatusCode = $script:LocalViewerStatusForbidden
            Message    = 'refused: cross-site requests are not allowed.'
        }

        return $forbidden
    }

    return $null
}


function Test-LocalViewerStateChangeAllowed {
    param([Parameter(Mandatory)] [System.Net.HttpListenerRequest] $Request)

    $rejection = Get-LocalViewerStateChangeRejection -Request $Request
    $isAllowed = ($null -eq $rejection)
    return $isAllowed
}


function Read-LocalViewerRequestJson {
    # Parse a small JSON request body, bounded so a runaway/oversized POST can't
    # exhaust memory. Returns the parsed object, or $null when the body is too
    # large, empty, or not valid JSON — the caller answers 400 on $null. Each
    # viewer passes its own -MaxBytes cap per route.
    param(
        [Parameter(Mandatory)] [System.Net.HttpListenerRequest] $Request,
        [Parameter(Mandatory)] [int] $MaxBytes
    )

    # A chunked / unknown-length body reports ContentLength64 -1 and would skip
    # the size guard (ReadToEnd would buffer it all first), so reject it up front
    # along with anything over the cap.
    if ($Request.ContentLength64 -lt 0 -or $Request.ContentLength64 -gt $MaxBytes) {
        return $null
    }

    if (-not (Test-LocalViewerStateChangeAllowed -Request $Request)) {
        return $null
    }

    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    try {
        $text = $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }

    if (-not $text -or $text.Length -gt $MaxBytes) {
        return $null
    }

    try {
        $parsed = $text | ConvertFrom-Json
    }
    catch {
        return $null
    }

    return $parsed
}


function Split-LocalViewerApiPath {
    # Shared scaffolding for /api/* route parsers: require a known prefix, trim
    # the surrounding slashes, and split what's left into path segments. Returns
    # $null when the path doesn't carry the prefix or is empty after it, so each
    # parser keeps only its own segment-shape rules. The unary-comma return keeps
    # a single-segment result an array — PowerShell would otherwise unroll it to
    # a scalar and break the callers' .Count checks.
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Prefix
    )

    if (-not $Path.StartsWith($Prefix)) {
        return $null
    }

    $rest = $Path.Substring($Prefix.Length).Trim('/')
    if (-not $rest) {
        return $null
    }

    $segments = $rest -split '/'
    return ,$segments
}


# ---------------------------------------------------------------------------
# Per-tile cache — cheap read, expensive write kept in separate helpers
#
# One JSON file per tile: { tile, writtenAt, items }. Staleness is the file's
# mtime age, surfaced to the client so the page can render "cached Nm ago"
# without a second source of truth. Each viewer decides WHERE the file lives
# (per-project slice, per-tenant folder) and passes the full path in.
# ---------------------------------------------------------------------------

function Write-LocalViewerTileCache {
    # Persist a tile's already-built payload with a written-at stamp. The write
    # goes to a sibling .tmp file then moves over the target, so a concurrent
    # cheap read never sees a half-written file.
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Tile,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyCollection()] $Items,
        [Parameter(Mandatory)] [int] $JsonDepth
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $record = [ordered]@{
        tile      = $Tile
        writtenAt = (Get-Date).ToString('o')
        items     = $Items
    }

    $json = $record | ConvertTo-Json -Depth $JsonDepth

    $tmp = "$Path.tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}


function Read-LocalViewerTileCache {
    # Read one tile's cache file and derive its staleness from the file's mtime.
    # Returns $null when the tile has never been written, so the caller can
    # answer 404 rather than fabricate empty data. A corrupt file still returns
    # a model (items = $null, writtenAt = mtime) so the tile renders empty.
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Tile,
        [Parameter(Mandatory)] [int] $StaleSeconds
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $file = Get-Item -LiteralPath $Path
    $ageSeconds = [int]((Get-Date) - $file.LastWriteTime).TotalSeconds
    $isStale = ($ageSeconds -ge $StaleSeconds)

    $raw = Get-Content -LiteralPath $Path -Raw

    $record = $null
    try {
        $record = $raw | ConvertFrom-Json
    }
    catch {
        $record = $null
    }

    $writtenAt = if ($record -and $record.writtenAt) {
        $record.writtenAt
    } else {
        $file.LastWriteTime.ToString('o')
    }

    $items = if ($record) {
        $record.items
    } else {
        $null
    }

    $model = [ordered]@{
        tile       = $Tile
        writtenAt  = $writtenAt
        ageSeconds = $ageSeconds
        stale      = $isStale
        items      = $items
    }

    return $model
}
