# ============================================================================
# Azure Resources — data layer + tenant-keyed tile cache (Epic #265 — B)
# ============================================================================
# Fetches "my Azure / Entra footprint" from the az CLI into one JSON file per
# tile, so the terminal views (az-Show-Az*) and the localhost Resource Viewer
# read instantly from disk instead of fanning out across subscriptions.
#
#   roles      - RBAC assignments I hold, directly or through a group
#   groups     - Entra groups I'm a (transitive) member or owner of
#   apps       - app registrations + service principals I own, with creds
#   identities - user- and system-assigned managed identities in every
#                subscription I can read, plus the roles each one holds
#                anywhere in the tenant
#
# Cache layout (tenant-scoped, NOT keyed by the AzDevOps project slug):
#   $HOME/.bashcuts-az-resources-app/cache/<tenantId>/<tile>.json
#
# Each file is the shared localhost-viewer tile record (Write-LocalViewerTileCache):
#   { tile, writtenAt, items: { state, message, records[] } }
# state is 'ok' or 'notPermitted' (the tenant blocked the call for this user).
# A tile that fails for any other reason keeps its previous cache file.
# Dates are normalized to round-trip ISO 8601 UTC strings, whichever
# PowerShell edition ran the sync.
#
# SECURITY: records are built from explicit field allow-lists — never by
# copying raw az output — so no secret text, token, or key material can reach
# the cache. az's own login stays in the az CLI's token store. Graph paging
# links are only followed to https://graph.microsoft.com.
#
# Public functions:
#   az-Sync-AzResources [-Tile <name>]  - refresh every tile, or just one
#
# Depends on Invoke-AzDevOpsAzJson (azdevops_db.ps1) and
# Write-LocalViewerTileCache (localhost_viewer.ps1); loaded by powcuts_home.ps1
# after both.

$script:AzResourcesAppDirName  = '.bashcuts-az-resources-app'
$script:AzResourcesCacheSubdir = 'cache'
$script:AzResourcesJsonDepth   = 10

# Keep in sync with az-Sync-AzResources' [ValidateSet] (attribute arguments
# must be literals, and ValidateSet is what gives -Tile tab completion).
$script:AzResourcesTileNames         = @('roles', 'groups', 'apps', 'identities')
$script:AzResourcesSubscriptionTiles = @('roles', 'identities')

$script:AzResourcesStateOk           = 'ok'
$script:AzResourcesStateNotPermitted = 'notPermitted'

# stderr markers az / ARM / Graph emit when the signed-in user lacks rights.
$script:AzResourcesPermissionPattern = 'AuthorizationFailed|Authorization_RequestDenied|Insufficient privileges|Forbidden|\b403\b'
$script:AzResourcesErrorLinePattern  = '^\s*ERROR:'

$script:AzResourcesSelfPrincipal   = 'me'
$script:AzResourcesUserAccountType = 'user'
$script:AzResourcesEnabledSubState = 'Enabled'
$script:AzResourcesIsoDateFormat   = 'o'

$script:AzResourcesGraphBaseUrl     = 'https://graph.microsoft.com/v1.0'
$script:AzResourcesGraphHost        = 'graph.microsoft.com'
$script:AzResourcesGraphPageSize    = 999
$script:AzResourcesGraphGroupType   = '#microsoft.graph.group'
$script:AzResourcesGraphGroupSelect = 'id,displayName,mail,groupTypes,securityEnabled,mailEnabled'
$script:AzResourcesGraphNextLinkKey = '@odata.nextLink'
$script:AzResourcesGraphTypeKey     = '@odata.type'

$script:AzResourcesRelationshipMember = 'member'
$script:AzResourcesRelationshipOwner  = 'owner'

$script:AzResourcesGroupTypeUnified       = 'Unified'
$script:AzResourcesGroupLabelM365         = 'Microsoft 365'
$script:AzResourcesGroupLabelMailSecurity = 'Mail-enabled security'
$script:AzResourcesGroupLabelSecurity     = 'Security'
$script:AzResourcesGroupLabelDistribution = 'Distribution'
$script:AzResourcesGroupLabelOther        = 'Other'

$script:AzResourcesKindAppRegistration   = 'appRegistration'
$script:AzResourcesKindServicePrincipal  = 'servicePrincipal'
$script:AzResourcesCredentialSecret      = 'secret'
$script:AzResourcesCredentialCertificate = 'certificate'

$script:AzResourcesIdentityUserAssigned   = 'userAssigned'
$script:AzResourcesIdentitySystemAssigned = 'systemAssigned'
$script:AzResourcesSystemAssignedMarker   = 'SystemAssigned'

$script:AzResourcesScopeManagementGroup        = 'managementGroup'
$script:AzResourcesScopeRoot                   = 'root'
$script:AzResourcesScopeSubscription           = 'subscription'
$script:AzResourcesScopeResourceGroup          = 'resourceGroup'
$script:AzResourcesScopeResource               = 'resource'
$script:AzResourcesManagementGroupScopePattern = '^/providers/Microsoft\.Management/managementGroups/'
$script:AzResourcesResourceGroupSegment        = 'resourceGroups'

# Portal deep links. Every link is tenant-pinned (#@<tenantId>/...) so it opens
# in the right directory. 'resource' covers subscriptions, resource groups,
# resources, and management groups (the portal resolves any ARM id under
# /resource); the tenant-root scope '/' has no blade of its own, so it lands on
# the tenant's portal home. Entra objects use their dedicated blades.
$script:AzResourcesPortalBaseUrl         = 'https://portal.azure.com/#@'
$script:AzResourcesPortalHomePath        = '/home'
$script:AzResourcesPortalResourcePath    = '/resource'
$script:AzResourcesPortalGroupBlade      = '/view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Overview/groupId/'
$script:AzResourcesPortalAppBlade        = '/view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Overview/appId/'
$script:AzResourcesPortalEnterpriseBlade = '/view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Overview/objectId/'
$script:AzResourcesPortalAppIdSegment    = '/appId/'


# ---------------------------------------------------------------------------
# Cache layout
# ---------------------------------------------------------------------------

function Get-AzResourcesCacheDir {
    # The tenant id becomes a path segment, so it must be a GUID — never a
    # value that could climb out of the cache root.
    param([Parameter(Mandatory)] [string] $TenantId)

    $parsedTenant = [guid]::Empty
    if (-not [guid]::TryParse($TenantId, [ref]$parsedTenant)) {
        throw "Tenant id '$TenantId' is not a GUID."
    }

    $appRoot = Join-Path $HOME $script:AzResourcesAppDirName
    $cacheRoot = Join-Path $appRoot $script:AzResourcesCacheSubdir
    $dir = Join-Path $cacheRoot $parsedTenant.ToString()
    return $dir
}


function Get-AzResourcesTilePath {
    param(
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [string] $Tile
    )

    $dir = Get-AzResourcesCacheDir -TenantId $TenantId
    $path = Join-Path $dir "$Tile.json"
    return $path
}


function Test-AzResourcesTileNeedsSubscriptions {
    param([Parameter(Mandatory)] [string] $Tile)

    $needsSubscriptions = $script:AzResourcesSubscriptionTiles -contains $Tile
    return $needsSubscriptions
}


# ---------------------------------------------------------------------------
# az plumbing
# ---------------------------------------------------------------------------

function Get-AzResourcesErrorSummary {
    # One line for the console: the first `ERROR:` line az printed (warnings
    # often come first), else the first non-blank line.
    param([AllowNull()] [AllowEmptyString()] [string] $ErrorText)

    $lines = @(([string]$ErrorText) -split "`r?`n" | Where-Object { $_.Trim() })
    $errorLines = @($lines | Where-Object { $_ -match $script:AzResourcesErrorLinePattern })

    $summary = if ($errorLines.Count -gt 0) {
        $errorLines[0].Trim()
    } elseif ($lines.Count -gt 0) {
        $lines[0].Trim()
    } else {
        'az returned a non-zero exit code with no error text.'
    }

    return $summary
}


function Invoke-AzResourcesAz {
    # Run one az call through the shared Invoke-AzDevOpsAzJson envelope (spinner,
    # separate stderr, exit code) and parse its JSON. Never throws: a bad exit
    # or unparseable output comes back as Ok = $false. NotPermitted is true when
    # the failure is an authorization / insufficient-privileges error.
    param([Parameter(Mandatory)] [string[]] $ArgList)

    $envelope = Invoke-AzDevOpsAzJson -ArgList $ArgList

    $isOk = ($envelope.ExitCode -eq 0)
    $isNotPermitted = (-not $isOk) -and ([string]$envelope.Error -match $script:AzResourcesPermissionPattern)
    $errorSummary = Get-AzResourcesErrorSummary -ErrorText $envelope.Error

    $data = $null
    if ($isOk -and $envelope.Json) {
        try {
            $data = ($envelope.Json -join "`n") | ConvertFrom-Json
        }
        catch {
            $isOk = $false
            $errorSummary = "could not parse az JSON output: $($_.Exception.Message)"
        }
    }

    $result = [PSCustomObject]@{
        Ok           = $isOk
        NotPermitted = $isNotPermitted
        Data         = $data
        Error        = $errorSummary
    }

    return $result
}


function Invoke-AzResourcesAzChecked {
    # Invoke-AzResourcesAz plus the fetchers' failure gate in one step, so no
    # fetcher can forget it: a permission denial is returned for the caller to
    # tally; any other failure throws and fails this tile.
    param(
        [Parameter(Mandatory)] [string[]] $ArgList,
        [Parameter(Mandatory)] [string] $What
    )

    $result = Invoke-AzResourcesAz -ArgList $ArgList

    if (-not $result.Ok -and -not $result.NotPermitted) {
        throw "$What failed: $($result.Error)"
    }

    return $result
}


function New-AzResourcesCallTally {
    $tally = [PSCustomObject]@{
        Allowed = 0
        Denied  = 0
    }

    return $tally
}


function Test-AzResourcesCallPermitted {
    # Count one call against -Tally and say whether its data is usable. The
    # single home of the "denied -> skip, allowed -> use" branch every fetcher
    # needs.
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Result,
        [Parameter(Mandatory)] [PSCustomObject] $Tally
    )

    if ($Result.NotPermitted) {
        $Tally.Denied++
        return $false
    }

    $Tally.Allowed++
    return $true
}


function Get-AzResourcesAccountContext {
    # Who am I, in which tenant? Returns $null when az isn't logged in so the
    # caller can print one clear message before touching the cache. ObjectId
    # is best-effort (some tenants block directory reads); role matching falls
    # back to the sign-in name when it's missing.
    $account = Invoke-AzResourcesAz -ArgList @('account', 'show')
    if (-not $account.Ok -or -not $account.Data.tenantId) {
        return $null
    }

    $userName = [string]$account.Data.user.name
    $isUser = ([string]$account.Data.user.type -eq $script:AzResourcesUserAccountType)

    $objectArgs = if ($isUser) {
        @('ad', 'signed-in-user', 'show')
    } else {
        @('ad', 'sp', 'show', '--id', $userName)
    }

    $principal = Invoke-AzResourcesAz -ArgList $objectArgs

    $objectId = if ($principal.Ok) {
        [string]$principal.Data.id
    } else {
        ''
    }

    $assignee = if ($objectId) {
        $objectId
    } else {
        $userName
    }

    $context = [PSCustomObject]@{
        TenantId = [string]$account.Data.tenantId
        UserName = $userName
        IsUser   = $isUser
        ObjectId = $objectId
        Assignee = $assignee
    }

    return $context
}


function Get-AzResourcesSubscriptions {
    # Enabled subscriptions in the CURRENT tenant only — v1 is the tenant az is
    # logged into, not a multi-tenant aggregate.
    param([Parameter(Mandatory)] [string] $TenantId)

    $result = Invoke-AzResourcesAz -ArgList @('account', 'list')
    if (-not $result.Ok) {
        throw "az account list failed: $($result.Error)"
    }

    $subscriptions = New-Object System.Collections.Generic.List[object]

    foreach ($raw in $result.Data) {
        $isInTenant = ($null -ne $raw) -and ($raw.tenantId -eq $TenantId)
        $isEnabled  = ($null -ne $raw) -and ($raw.state -eq $script:AzResourcesEnabledSubState)

        if ($isInTenant -and $isEnabled) {
            $subscriptions.Add([PSCustomObject]@{
                Id   = [string]$raw.id
                Name = [string]$raw.name
            })
        }
    }

    # Unary comma: keep the List intact through the pipeline (an empty or
    # single-item List would otherwise unroll to $null / a bare object).
    return ,$subscriptions
}


function ConvertFrom-AzResourcesGraphNextLink {
    # Split a Graph @odata.nextLink into a base URL + --url-parameters list.
    # Query options travel via --url-parameters (never an '&' inside --url)
    # because az.cmd on Windows hands the URL to cmd.exe, which splits at '&'.
    # Only https links to Graph itself are followed: az rest attaches a token
    # chosen from the URL's host, so an unexpected host is refused outright.
    param([Parameter(Mandatory)] [string] $NextLink)

    $uri = $null
    $isWellFormed = [uri]::TryCreate($NextLink, [System.UriKind]::Absolute, [ref]$uri)
    $isGraph = $isWellFormed -and ($uri.Scheme -eq 'https') -and ($uri.Host -ieq $script:AzResourcesGraphHost)

    if (-not $isGraph) {
        throw "refusing to follow a Graph nextLink to an unexpected host: $NextLink"
    }

    $urlParameters = New-Object System.Collections.Generic.List[string]
    $query = $uri.Query.TrimStart('?')

    if ($query) {
        foreach ($pair in ($query -split '&')) {
            $keyValue = $pair -split '=', 2
            $key = [uri]::UnescapeDataString($keyValue[0])

            $value = ''
            if ($keyValue.Count -gt 1) {
                $value = [uri]::UnescapeDataString($keyValue[1])
            }

            $urlParameters.Add("$key=$value")
        }
    }

    $page = [PSCustomObject]@{
        Url           = $uri.GetLeftPart([System.UriPartial]::Path)
        UrlParameters = $urlParameters
    }

    return $page
}


function Get-AzResourcesGraphCollection {
    # GET a Graph collection through `az rest`, following @odata.nextLink.
    # Returns { NotPermitted, Items }.
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Select
    )

    $items = New-Object System.Collections.Generic.List[object]
    $isNotPermitted = $false

    $url = "$($script:AzResourcesGraphBaseUrl)/$Path"
    $urlParameters = @("`$select=$Select", "`$top=$($script:AzResourcesGraphPageSize)")

    while ($url) {
        $argList = @('rest', '--method', 'get', '--url', $url)
        if ($urlParameters.Count -gt 0) {
            $argList += '--url-parameters'
            $argList += $urlParameters
        }

        $result = Invoke-AzResourcesAzChecked -ArgList $argList -What "Graph GET $Path"

        if ($result.NotPermitted) {
            $isNotPermitted = $true
            break
        }

        foreach ($raw in $result.Data.value) {
            if ($null -ne $raw) {
                $items.Add($raw)
            }
        }

        $nextLink = [string]$result.Data.$($script:AzResourcesGraphNextLinkKey)
        $url = $null

        if ($nextLink) {
            $page = ConvertFrom-AzResourcesGraphNextLink -NextLink $nextLink
            $url = $page.Url
            $urlParameters = $page.UrlParameters
        }
    }

    $collection = [PSCustomObject]@{
        NotPermitted = $isNotPermitted
        Items        = $items
    }

    return $collection
}


# ---------------------------------------------------------------------------
# Record helpers
# ---------------------------------------------------------------------------

function New-AzResourcesTileResult {
    # The `items` payload every tile writes: a state, an optional message for
    # the views to show, and the normalized records.
    param(
        [Parameter(Mandatory)] [string] $State,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]] $Records,
        [string] $Message = ''
    )

    $tileResult = [ordered]@{
        state   = $State
        message = $Message
        records = $Records
    }

    return $tileResult
}


function Get-AzResourcesTallyTileResult {
    # Turn a fetcher's call tally into its tile result: every call denied means
    # the whole tile is notPermitted; some denied means keep what we got and
    # say so. -Notes appends extra caveats (e.g. roles that couldn't be read).
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]] $Records,
        [Parameter(Mandatory)] [PSCustomObject] $Tally,
        [Parameter(Mandatory)] [string] $Label,
        [string[]] $Notes = @()
    )

    $state = $script:AzResourcesStateOk
    $messages = New-Object System.Collections.Generic.List[string]

    if ($Tally.Denied -gt 0 -and $Tally.Allowed -eq 0) {
        $state = $script:AzResourcesStateNotPermitted
        $messages.Add("Your account is not permitted to read $Label in this tenant.")
    } elseif ($Tally.Denied -gt 0) {
        $messages.Add("Partial: $($Tally.Denied) of $($Tally.Allowed + $Tally.Denied) $Label call(s) were not permitted.")
    }

    foreach ($note in $Notes) {
        $messages.Add($note)
    }

    $tileResult = New-AzResourcesTileResult -State $state -Records $Records -Message ($messages -join ' ')
    return $tileResult
}


function Get-AzResourcesUserOnlyTileResult {
    # Graph `me/...` and `--show-mine` only make sense for a user sign-in; for a
    # service-principal / managed-identity login the tile is notPermitted
    # rather than a hard failure.
    param([Parameter(Mandatory)] [string] $Label)

    $empty = New-Object System.Collections.Generic.List[object]
    $message = "$Label need a user sign-in; az is signed in as a service principal or managed identity."

    $tileResult = New-AzResourcesTileResult -State $script:AzResourcesStateNotPermitted -Records $empty -Message $message
    return $tileResult
}


function ConvertTo-AzResourcesUrlPath {
    # Percent-encode each segment of an id / ARM path, keeping the '/'
    # separators, so a name with '#', '%', or a space can't break the link.
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Path)

    $segments = foreach ($segment in ($Path -split '/')) {
        [uri]::EscapeDataString($segment)
    }

    $encoded = $segments -join '/'
    return $encoded
}


function Get-AzResourcesPortalUrl {
    # The ONE deep-link builder every tile uses, so a portal URL shape changes in
    # one place. Scheme + host are fixed constants; data only ever lands in the
    # encoded fragment.
    param(
        [Parameter(Mandatory)]
        [ValidateSet('resource', 'group', 'appRegistration', 'servicePrincipal')]
        [string] $Kind,

        [Parameter(Mandatory)] [string] $TenantId,
        [string] $ResourceId = '',
        [string] $ObjectId = '',
        [string] $AppId = ''
    )

    $tenantRoot = "$($script:AzResourcesPortalBaseUrl)$(ConvertTo-AzResourcesUrlPath -Path $TenantId)"
    $objectSegment = ConvertTo-AzResourcesUrlPath -Path $ObjectId
    $appSegment = ConvertTo-AzResourcesUrlPath -Path $AppId

    switch ($Kind) {
        'resource' {
            $isTenantRoot = -not $ResourceId.Trim('/')

            $url = if ($isTenantRoot) {
                "$tenantRoot$($script:AzResourcesPortalHomePath)"
            } else {
                "$tenantRoot$($script:AzResourcesPortalResourcePath)$(ConvertTo-AzResourcesUrlPath -Path $ResourceId)"
            }
        }

        'group' {
            $url = "$tenantRoot$($script:AzResourcesPortalGroupBlade)$objectSegment"
        }

        'appRegistration' {
            $url = "$tenantRoot$($script:AzResourcesPortalAppBlade)$appSegment"
        }

        'servicePrincipal' {
            $url = "$tenantRoot$($script:AzResourcesPortalEnterpriseBlade)$objectSegment$($script:AzResourcesPortalAppIdSegment)$appSegment"
        }
    }

    return $url
}


function Get-AzResourcesScopeType {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Scope)

    $segments = @($Scope.Trim('/') -split '/' | Where-Object { $_ })

    $scopeType = if ($Scope -match $script:AzResourcesManagementGroupScopePattern) {
        $script:AzResourcesScopeManagementGroup
    } elseif ($segments.Count -eq 0) {
        $script:AzResourcesScopeRoot
    } elseif ($segments.Count -eq 2) {
        $script:AzResourcesScopeSubscription
    } elseif ($segments.Count -eq 4 -and $segments[2] -ieq $script:AzResourcesResourceGroupSegment) {
        $script:AzResourcesScopeResourceGroup
    } else {
        $script:AzResourcesScopeResource
    }

    return $scopeType
}


function Get-AzResourcesGroupType {
    param([Parameter(Mandatory)] $Group)

    $isUnified = @($Group.groupTypes) -contains $script:AzResourcesGroupTypeUnified

    $groupType = if ($isUnified) {
        $script:AzResourcesGroupLabelM365
    } elseif ($Group.securityEnabled -and $Group.mailEnabled) {
        $script:AzResourcesGroupLabelMailSecurity
    } elseif ($Group.securityEnabled) {
        $script:AzResourcesGroupLabelSecurity
    } elseif ($Group.mailEnabled) {
        $script:AzResourcesGroupLabelDistribution
    } else {
        $script:AzResourcesGroupLabelOther
    }

    return $groupType
}


function ConvertTo-AzResourcesIsoDate {
    # PowerShell 6+ ConvertFrom-Json turns ISO date strings into [datetime],
    # and [string] on that gives a culture-formatted, zone-less value; 5.1
    # leaves the original string. Normalize both to round-trip ISO 8601 UTC so
    # the cache is identical whichever edition synced it.
    param([AllowNull()] $Value)

    $isoDate = if ($null -eq $Value) {
        ''
    } elseif ($Value -is [datetime] -or $Value -is [datetimeoffset]) {
        $Value.ToUniversalTime().ToString($script:AzResourcesIsoDateFormat)
    } else {
        [string]$Value
    }

    return $isoDate
}


function ConvertTo-AzResourcesCredentials {
    # Secrets + certificates reduced to name / id / kind / expiry. Only these
    # fields are copied, so secretText or key material can never reach the
    # cache even if az starts returning it. Older az builds name the expiry
    # endDate; Graph-based builds use endDateTime.
    param([Parameter(Mandatory)] $Raw)

    $credentials = New-Object System.Collections.Generic.List[object]

    $sources = @(
        @{ Kind = $script:AzResourcesCredentialSecret;      Items = $Raw.passwordCredentials }
        @{ Kind = $script:AzResourcesCredentialCertificate; Items = $Raw.keyCredentials }
    )

    foreach ($source in $sources) {
        foreach ($cred in $source.Items) {
            if ($null -eq $cred) {
                continue
            }

            $rawEnd = if ($null -ne $cred.endDateTime) {
                $cred.endDateTime
            } else {
                $cred.endDate
            }

            $credentials.Add([ordered]@{
                kind        = $source.Kind
                name        = [string]$cred.displayName
                keyId       = [string]$cred.keyId
                endDateTime = ConvertTo-AzResourcesIsoDate -Value $rawEnd
            })
        }
    }

    # Unary comma so 0 or 1 credentials still serialize as a JSON array.
    return ,$credentials
}


function ConvertTo-AzResourcesRoleRecord {
    param(
        [Parameter(Mandatory)] $Raw,
        [Parameter(Mandatory)] [PSCustomObject] $Context,
        [Parameter(Mandatory)] [PSCustomObject] $Subscription
    )

    $isMine = if ($Context.ObjectId) {
        $Raw.principalId -eq $Context.ObjectId
    } else {
        $Raw.principalName -eq $Context.UserName
    }

    $principal = if ($isMine) {
        $script:AzResourcesSelfPrincipal
    } else {
        [string]$Raw.principalName
    }

    $scope = [string]$Raw.scope

    $record = [ordered]@{
        id               = [string]$Raw.id
        roleName         = [string]$Raw.roleDefinitionName
        scope            = $scope
        scopeType        = Get-AzResourcesScopeType -Scope $scope
        principal        = $principal
        principalType    = [string]$Raw.principalType
        subscriptionId   = $Subscription.Id
        subscriptionName = $Subscription.Name
        portalUrl        = Get-AzResourcesPortalUrl -Kind 'resource' -TenantId $Context.TenantId -ResourceId $scope
    }

    return $record
}


function New-AzResourcesAssignmentIdSet {
    # ARM ids are case-insensitive; de-duplicate them that way.
    $idSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    return ,$idSet
}


# ---------------------------------------------------------------------------
# Per-tile fetchers — the EXPENSIVE seam (one az call or a per-subscription fan-out)
# ---------------------------------------------------------------------------

function Get-AzResourcesRoleTile {
    # RBAC assignments I hold directly or through any group, per subscription.
    # --all also surfaces assignments inherited from management groups / root,
    # which repeat in every subscription — de-duplicated by assignment id.
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Context,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]] $Subscriptions
    )

    $records = New-Object System.Collections.Generic.List[object]
    $seenIds = New-AzResourcesAssignmentIdSet
    $tally = New-AzResourcesCallTally

    foreach ($sub in $Subscriptions) {
        $argList = @(
            'role', 'assignment', 'list',
            '--assignee', $Context.Assignee,
            '--include-groups', '--all',
            '--subscription', $sub.Id
        )

        $result = Invoke-AzResourcesAzChecked -ArgList $argList -What "role assignment list ($($sub.Name))"
        if (-not (Test-AzResourcesCallPermitted -Result $result -Tally $tally)) {
            continue
        }

        foreach ($raw in $result.Data) {
            if ($null -eq $raw -or -not $seenIds.Add([string]$raw.id)) {
                continue
            }

            $records.Add((ConvertTo-AzResourcesRoleRecord -Raw $raw -Context $Context -Subscription $sub))
        }
    }

    $tileResult = Get-AzResourcesTallyTileResult -Records $records -Tally $tally -Label 'role assignments'
    return $tileResult
}


function Get-AzResourcesGroupTile {
    # Groups I belong to (transitively — nested membership is what grants roles)
    # plus groups I own. The collections are directory objects of mixed types,
    # so non-groups are filtered by @odata.type rather than an OData cast, which
    # some tenants only allow with advanced-query headers.
    param([Parameter(Mandatory)] [PSCustomObject] $Context)

    if (-not $Context.IsUser) {
        $userOnly = Get-AzResourcesUserOnlyTileResult -Label 'Group memberships'
        return $userOnly
    }

    $records = New-Object System.Collections.Generic.List[object]
    $tally = New-AzResourcesCallTally

    $sources = @(
        @{ Path = 'me/transitiveMemberOf'; Relationship = $script:AzResourcesRelationshipMember }
        @{ Path = 'me/ownedObjects';       Relationship = $script:AzResourcesRelationshipOwner }
    )

    foreach ($source in $sources) {
        $collection = Get-AzResourcesGraphCollection -Path $source.Path -Select $script:AzResourcesGraphGroupSelect
        if (-not (Test-AzResourcesCallPermitted -Result $collection -Tally $tally)) {
            continue
        }

        foreach ($raw in $collection.Items) {
            if ($raw.$($script:AzResourcesGraphTypeKey) -ne $script:AzResourcesGraphGroupType) {
                continue
            }

            $groupId = [string]$raw.id

            $records.Add([ordered]@{
                displayName  = [string]$raw.displayName
                id           = $groupId
                relationship = $source.Relationship
                mail         = [string]$raw.mail
                groupType    = Get-AzResourcesGroupType -Group $raw
                portalUrl    = Get-AzResourcesPortalUrl -Kind 'group' -TenantId $Context.TenantId -ObjectId $groupId
            })
        }
    }

    $tileResult = Get-AzResourcesTallyTileResult -Records $records -Tally $tally -Label 'group memberships'
    return $tileResult
}


function Get-AzResourcesAppTile {
    # App registrations and service principals (enterprise apps) I own, each
    # with its secrets / certificates and their expiry dates.
    param([Parameter(Mandatory)] [PSCustomObject] $Context)

    if (-not $Context.IsUser) {
        $userOnly = Get-AzResourcesUserOnlyTileResult -Label 'Owned applications'
        return $userOnly
    }

    $records = New-Object System.Collections.Generic.List[object]
    $tally = New-AzResourcesCallTally

    $sources = @(
        @{ ArgList = @('ad', 'app', 'list', '--show-mine'); Kind = $script:AzResourcesKindAppRegistration }
        @{ ArgList = @('ad', 'sp', 'list', '--show-mine');  Kind = $script:AzResourcesKindServicePrincipal }
    )

    foreach ($source in $sources) {
        $result = Invoke-AzResourcesAzChecked -ArgList $source.ArgList -What ($source.ArgList -join ' ')
        if (-not (Test-AzResourcesCallPermitted -Result $result -Tally $tally)) {
            continue
        }

        foreach ($raw in $result.Data) {
            if ($null -eq $raw) {
                continue
            }

            $appId = [string]$raw.appId
            $objectId = [string]$raw.id

            $records.Add([ordered]@{
                displayName = [string]$raw.displayName
                appId       = $appId
                objectId    = $objectId
                kind        = $source.Kind
                credentials = ConvertTo-AzResourcesCredentials -Raw $raw
                portalUrl   = Get-AzResourcesPortalUrl -Kind $source.Kind -TenantId $Context.TenantId -ObjectId $objectId -AppId $appId
            })
        }
    }

    $tileResult = Get-AzResourcesTallyTileResult -Records $records -Tally $tally -Label 'owned applications'
    return $tileResult
}


function Get-AzResourcesTenantRoleIndex {
    # principalId -> every role that principal holds in ANY readable
    # subscription, so an identity in subscription A with a role on B shows
    # both. One `role assignment list --all` per subscription (principal-name
    # lookup off — the index never uses it), merged and de-duplicated by
    # assignment id. Denied reads are counted on -Tally.
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]] $Subscriptions,
        [Parameter(Mandatory)] [PSCustomObject] $Tally
    )

    $index = @{}
    $seenIds = New-AzResourcesAssignmentIdSet

    foreach ($sub in $Subscriptions) {
        $argList = @('role', 'assignment', 'list', '--all', '--fill-principal-name', 'false', '--subscription', $sub.Id)

        $result = Invoke-AzResourcesAzChecked -ArgList $argList -What "role assignment list --all ($($sub.Name))"
        if (-not (Test-AzResourcesCallPermitted -Result $result -Tally $Tally)) {
            continue
        }

        foreach ($raw in $result.Data) {
            $isUsable = ($null -ne $raw) -and $raw.principalId -and $seenIds.Add([string]$raw.id)
            if (-not $isUsable) {
                continue
            }

            $principalId = [string]$raw.principalId
            if (-not $index.ContainsKey($principalId)) {
                $index[$principalId] = New-Object System.Collections.Generic.List[object]
            }

            $index[$principalId].Add([ordered]@{
                roleName = [string]$raw.roleDefinitionName
                scope    = [string]$raw.scope
            })
        }
    }

    return $index
}


function Get-AzResourcesIdentitySources {
    # The two places a managed identity shows up, as one table so the identity
    # tile walks them with a single loop: user-assigned identities are their
    # own resources; system-assigned ones are an identity block on any resource.
    param([Parameter(Mandatory)] [PSCustomObject] $Subscription)

    $sources = @(
        @{
            ArgList      = @('identity', 'list', '--subscription', $Subscription.Id)
            What         = "identity list ($($Subscription.Name))"
            IdentityType = $script:AzResourcesIdentityUserAssigned
        }

        @{
            ArgList      = @('resource', 'list', '--subscription', $Subscription.Id)
            What         = "resource list ($($Subscription.Name))"
            IdentityType = $script:AzResourcesIdentitySystemAssigned
        }
    )

    return $sources
}


function Get-AzResourcesIdentityPrincipalId {
    # The identity's principalId, or '' when -Raw doesn't carry this kind of
    # identity (a resource with no system-assigned identity is skipped).
    param(
        [Parameter(Mandatory)] [AllowNull()] $Raw,
        [Parameter(Mandatory)] [string] $IdentityType
    )

    if ($null -eq $Raw) {
        return ''
    }

    $principalId = ''

    if ($IdentityType -eq $script:AzResourcesIdentityUserAssigned) {
        $principalId = [string]$Raw.principalId
    } elseif ([string]$Raw.identity.type -match $script:AzResourcesSystemAssignedMarker) {
        $principalId = [string]$Raw.identity.principalId
    }

    return $principalId
}


function ConvertTo-AzResourcesIdentityRecord {
    param(
        [Parameter(Mandatory)] $Raw,
        [Parameter(Mandatory)] [string] $IdentityType,
        [Parameter(Mandatory)] [string] $PrincipalId,
        [Parameter(Mandatory)] [PSCustomObject] $Subscription,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [hashtable] $RoleIndex,
        [Parameter(Mandatory)] [string] $TenantId
    )

    # Plain assignments, not `$roles = if (...) { ... }` — an if-expression
    # unrolls the List, so 0 or 1 roles would stop serializing as an array.
    $roles = New-Object System.Collections.Generic.List[object]

    if ($RoleIndex.ContainsKey($PrincipalId)) {
        $roles = $RoleIndex[$PrincipalId]
    }

    $resourceId = [string]$Raw.id

    $record = [ordered]@{
        name             = [string]$Raw.name
        type             = $IdentityType
        resourceId       = $resourceId
        resourceGroup    = [string]$Raw.resourceGroup
        subscriptionId   = $Subscription.Id
        subscriptionName = $Subscription.Name
        principalId      = $PrincipalId
        roles            = $roles
        portalUrl        = Get-AzResourcesPortalUrl -Kind 'resource' -TenantId $TenantId -ResourceId $resourceId
    }

    return $record
}


function Get-AzResourcesIdentityTile {
    # Every managed identity in every subscription I can read, joined to the
    # roles it holds anywhere in the tenant.
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Context,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]] $Subscriptions
    )

    $records = New-Object System.Collections.Generic.List[object]
    $tally = New-AzResourcesCallTally
    $roleTally = New-AzResourcesCallTally

    $roleIndex = Get-AzResourcesTenantRoleIndex -Subscriptions $Subscriptions -Tally $roleTally

    foreach ($sub in $Subscriptions) {
        $recordArgs = @{
            Subscription = $sub
            RoleIndex    = $roleIndex
            TenantId     = $Context.TenantId
        }

        foreach ($source in (Get-AzResourcesIdentitySources -Subscription $sub)) {
            $result = Invoke-AzResourcesAzChecked -ArgList $source.ArgList -What $source.What
            if (-not (Test-AzResourcesCallPermitted -Result $result -Tally $tally)) {
                continue
            }

            foreach ($raw in $result.Data) {
                $principalId = Get-AzResourcesIdentityPrincipalId -Raw $raw -IdentityType $source.IdentityType
                if (-not $principalId) {
                    continue
                }

                $records.Add((ConvertTo-AzResourcesIdentityRecord -Raw $raw -IdentityType $source.IdentityType -PrincipalId $principalId @recordArgs))
            }
        }
    }

    $notes = @()
    if ($roleTally.Denied -gt 0) {
        $notes += "Roles could not be read in $($roleTally.Denied) subscription(s); identities there may show fewer roles than they hold."
    }

    $tileResult = Get-AzResourcesTallyTileResult -Records $records -Tally $tally -Label 'managed identities' -Notes $notes
    return $tileResult
}


function Invoke-AzResourcesTileFetch {
    param(
        [Parameter(Mandatory)] [string] $Tile,
        [Parameter(Mandatory)] [PSCustomObject] $Context,
        [AllowNull()] [System.Collections.Generic.List[object]] $Subscriptions
    )

    if ((Test-AzResourcesTileNeedsSubscriptions -Tile $Tile) -and $null -eq $Subscriptions) {
        throw 'subscription list unavailable (az account list failed).'
    }

    switch ($Tile) {
        'roles' {
            $tileResult = Get-AzResourcesRoleTile -Context $Context -Subscriptions $Subscriptions
        }

        'groups' {
            $tileResult = Get-AzResourcesGroupTile -Context $Context
        }

        'apps' {
            $tileResult = Get-AzResourcesAppTile -Context $Context
        }

        'identities' {
            $tileResult = Get-AzResourcesIdentityTile -Context $Context -Subscriptions $Subscriptions
        }

        default {
            throw "Unknown Azure resources tile '$Tile'."
        }
    }

    return $tileResult
}


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

function az-Sync-AzResources {
    <#
    .SYNOPSIS
        Refresh the local cache of your Azure / Entra footprint.

    .DESCRIPTION
        Uses your existing `az login` to fetch role assignments, Entra groups,
        owned app registrations / service principals, and managed identities
        for the tenant az is logged into, writing one JSON file per tile under
        $HOME/.bashcuts-az-resources-app/cache/<tenantId>/.

        A tile the tenant won't let you read is cached as "notPermitted"; a tile
        that fails for any other reason keeps its previous cache, and the other
        tiles still sync. Nothing is written when az isn't logged in.

    .PARAMETER Tile
        Refresh only this tile: roles, groups, apps, or identities.

    .EXAMPLE
        az-Sync-AzResources

    .EXAMPLE
        az-Sync-AzResources -Tile groups
    #>
    param(
        # Keep in sync with $script:AzResourcesTileNames.
        [ValidateSet('roles', 'groups', 'apps', 'identities')]
        [string] $Tile
    )

    $context = Get-AzResourcesAccountContext
    if ($null -eq $context) {
        Write-Host "Not logged in to Azure. Run 'az login' and try again." -ForegroundColor Yellow
        return
    }

    # Typed so a single -Tile stays an array (an if-expression would unroll it).
    [string[]] $tiles = $script:AzResourcesTileNames
    if ($Tile) {
        $tiles = @($Tile)
    }

    $subscriptions = $null
    $needsSubscriptions = @($tiles | Where-Object { Test-AzResourcesTileNeedsSubscriptions -Tile $_ }).Count -gt 0

    if ($needsSubscriptions) {
        try {
            $subscriptions = Get-AzResourcesSubscriptions -TenantId $context.TenantId
        }
        catch {
            Write-Host "Could not list subscriptions: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    $failed = 0

    foreach ($name in $tiles) {
        try {
            $tileResult = Invoke-AzResourcesTileFetch -Tile $name -Context $context -Subscriptions $subscriptions
            $path = Get-AzResourcesTilePath -TenantId $context.TenantId -Tile $name

            Write-LocalViewerTileCache -Path $path -Tile $name -Items $tileResult -JsonDepth $script:AzResourcesJsonDepth

            $color = if ($tileResult.state -eq $script:AzResourcesStateOk) {
                'Green'
            } else {
                'Yellow'
            }

            Write-Host "  ${name}: $($tileResult.state) ($($tileResult.records.Count) records) $($tileResult.message)" -ForegroundColor $color
        }
        catch {
            $failed++
            Write-Host "  ${name}: failed, previous cache kept - $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    $cacheDir = Get-AzResourcesCacheDir -TenantId $context.TenantId

    Write-Host ''
    Write-Host "Cache: $cacheDir" -ForegroundColor Cyan

    if ($failed -gt 0) {
        Write-Host "Partial sync - $failed of $($tiles.Count) tile(s) failed." -ForegroundColor Yellow
    }
}
