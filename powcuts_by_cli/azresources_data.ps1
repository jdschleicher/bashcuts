# ============================================================================
# Azure Resources — data layer + tenant-keyed tile cache (Epic #265 — B)
# ============================================================================
# Fetches "my Azure / Entra footprint" from the az CLI into one JSON file per
# tile, so the terminal views (az-Show-Az*) and the localhost Resource Viewer
# read instantly from disk instead of fanning out across subscriptions.
#
#   roles      - RBAC assignments I hold, directly or through a group
#   groups     - Entra groups I'm a (transitive) member or owner of
#   apps       - app registrations + service principals I own, with creds;
#                with -AllApps, every one in the tenant I can read (isOwner
#                marks mine; items.scope records which mode synced the tile)
#   identities - user- and system-assigned managed identities in every
#                subscription I can read, plus the roles each one holds
#                anywhere in the tenant
#
# Cache layout (tenant-scoped, NOT keyed by the AzDevOps project slug):
#   $HOME/.bashcuts-az-resources-app/cache/<tenantId>/<tile>.json
#
# Each file is the shared localhost-viewer tile record (Write-LocalViewerTileCache):
#   { tile, writtenAt, items: { state, message, records[], syncedAs } }
# state is 'ok' or 'notPermitted' (the tenant blocked the call for this user).
# syncedAs { userName, userType, identityInfo, objectId } names the account that synced the
# tile: the cache is per tenant, so two accounts in one tenant share a folder
# and the views use this to flag rows that belong to the other account.
# A tile that fails for any other reason keeps its previous cache file.
# Dates are normalized to one round-trip ISO 8601 UTC format
# (yyyy-MM-ddTHH:mm:ss.fffffffZ), whichever PowerShell edition ran the sync.
#
# SECURITY: records are built from explicit field allow-lists — never by
# copying raw az output — so no secret text, token, or key material can reach
# the cache. az's own login stays in the az CLI's token store. Graph paging
# links are only followed to https://graph.microsoft.com.
#
# Public functions:
#   az-Sync-AzResources [-Tile <name>] [-AllApps]  - refresh every tile, or just one
#
# Depends on Invoke-AzDevOpsAzJson (azdevops_db.ps1) and
# Write-LocalViewerTileCache (localhost_viewer.ps1); loaded by powcuts_home.ps1
# after both.

$script:AzResourcesAppDirName  = '.bashcuts-az-resources-app'
$script:AzResourcesCacheSubdir = 'cache'
$script:AzResourcesJsonDepth   = 10

# Keep in sync with az-Sync-AzResources' [ValidateSet] (attribute arguments
# must be literals, and ValidateSet is what gives -Tile tab completion).
$script:AzResourcesTileRoles         = 'roles'
$script:AzResourcesTileGroups        = 'groups'
$script:AzResourcesTileApps          = 'apps'
$script:AzResourcesTileIdentities    = 'identities'
$script:AzResourcesTileNames         = @($script:AzResourcesTileRoles, $script:AzResourcesTileGroups, $script:AzResourcesTileApps, $script:AzResourcesTileIdentities)
$script:AzResourcesSubscriptionTiles = @($script:AzResourcesTileRoles, $script:AzResourcesTileIdentities)

$script:AzResourcesStateOk           = 'ok'
$script:AzResourcesStateNotPermitted = 'notPermitted'

# stderr markers az / ARM / Graph emit when the signed-in user lacks rights.
$script:AzResourcesPermissionPattern = 'AuthorizationFailed|Authorization_RequestDenied|Insufficient privileges|Forbidden|\b403\b'
$script:AzResourcesErrorLinePattern  = '^\s*ERROR:'

# Sign-in problems az reports as AADSTS errors: re-running `az login` fixes
# them, so they get that hint instead of a generic failure. Only codes that end
# the whole login (expired / revoked refresh token, password changed or
# expired) stop the sync up front, since every later call would fail the same
# way — `az account show` still succeeds on an expired login. MFA / Conditional
# Access challenges can hit Graph alone, so those fail per tile instead. Consent
# errors aren't fixed by signing in again; they read as not permitted.
$script:AzResourcesReauthPattern       = 'AADSTS\d+|interaction_required|invalid_grant'
$script:AzResourcesExpiredLoginPattern = 'AADSTS(700082|50173|50132|50133)\b'
$script:AzResourcesConsentPattern      = 'AADSTS(65001|90094)\b'
$script:AzResourcesReauthHint          = "Your az sign-in needs refreshing - run 'az login' and try again (add --scope https://graph.microsoft.com//.default if only the Graph tiles fail)."
$script:AzResourcesConsoleIndent       = '    '

$script:AzResourcesSelfPrincipal   = 'me'
$script:AzResourcesUserAccountType = 'user'
$script:AzResourcesEnabledSubState = 'Enabled'

# `az login --identity` reports one of these as user.name, and the identity's
# id in user.assignedIdentityInfo as 'MSIObject-<objectId>' / 'MSIClient-<clientId>'
# (also 'MSIResource-<armId>' or bare 'MSI', which can't be resolved here).
$script:AzResourcesManagedIdentityNames = @('systemAssignedIdentity', 'userAssignedIdentity')
$script:AzResourcesMsiObjectIdPattern   = '^MSIObject-(.+)$'
$script:AzResourcesMsiClientIdPattern   = '^MSIClient-(.+)$'

$script:AzResourcesSubscriptionScopePattern  = '^/subscriptions/([^/]+)'
$script:AzResourcesUnresolvedPrincipalPrefix = '(unresolved) '
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
$script:AzResourcesGroupTypeDynamic       = 'DynamicMembership'
$script:AzResourcesGroupLabelM365         = 'Microsoft 365'
$script:AzResourcesGroupLabelMailSecurity = 'Mail-enabled security'
$script:AzResourcesGroupLabelSecurity     = 'Security'
$script:AzResourcesGroupLabelDistribution = 'Distribution'
$script:AzResourcesGroupLabelOther        = 'Other'

$script:AzResourcesKindResource          = 'resource'
$script:AzResourcesKindGroup             = 'group'
$script:AzResourcesKindAppRegistration   = 'appRegistration'
$script:AzResourcesKindServicePrincipal  = 'servicePrincipal'
$script:AzResourcesCredentialSecret      = 'secret'
$script:AzResourcesCredentialCertificate = 'certificate'

# Apps tile scope: 'owned' = --show-mine only (the default); 'all' = every app
# registration / service principal in the tenant the account can read.
$script:AzResourcesAppScopeOwned = 'owned'
$script:AzResourcesAppScopeAll   = 'all'
$script:AzResourcesAppScopes     = @($script:AzResourcesAppScopeOwned, $script:AzResourcesAppScopeAll)

$script:AzResourcesAppLabelOwned        = 'owned applications'
$script:AzResourcesAppLabelAll          = 'applications'
$script:AzResourcesAppUserOnlyLabelOwned = 'Owned applications'
$script:AzResourcesAppUserOnlyLabelAll   = 'Tenant-wide application lists'
$script:AzResourcesAppOwnerUnknownNote  = "Couldn't read which apps you own, so ownership is unknown on the tenant-wide rows; their credentials still count toward expiry warnings."
$script:AzResourcesAppTenantDeniedNote  = "Your account can't list every app in this tenant (guest accounts and tenants that restrict default user permissions block it), so only the apps you own are shown."

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
$script:AzResourcesSubscriptionSegment         = 'subscriptions'

# Portal deep links. Every link is tenant-pinned (#@<tenantId>/...) so it opens
# in the right directory. 'resource' covers subscriptions, resource groups and
# resources under /resource. Management groups have no /resource blade, so they
# open the management-group hierarchy; the tenant-root scope '/' has no blade of
# its own, so it lands on the tenant's portal home. Entra objects use their
# dedicated blades.
$script:AzResourcesPortalBaseUrl         = 'https://portal.azure.com/#@'
$script:AzResourcesPortalHomePath        = '/home'
$script:AzResourcesPortalMgmtGroupBlade  = '/view/Microsoft_Azure_ManagementGroups/HierarchyBlade'
$script:AzResourcesPortalResourcePath    = '/resource'
$script:AzResourcesPortalGroupBlade      = '/view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Overview/groupId/'
$script:AzResourcesPortalAppBlade        = '/view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Overview/appId/'
$script:AzResourcesPortalEnterpriseBlade = '/view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Overview/objectId/'
$script:AzResourcesPortalAppIdSegment    = '/appId/'


# ---------------------------------------------------------------------------
# Cache layout
# ---------------------------------------------------------------------------

function Get-AzResourcesCacheRoot {
    # Parent of every per-tenant cache folder.
    $appRoot = Join-Path $HOME $script:AzResourcesAppDirName
    $cacheRoot = Join-Path $appRoot $script:AzResourcesCacheSubdir
    return $cacheRoot
}


function Test-AzResourcesGuid {
    # Canonical 8-4-4-4-12 form only: TryParse would also accept '{...}' /
    # '(...)' forms, whose brackets cmd.exe can misread on az.cmd's command line.
    param([AllowNull()] [AllowEmptyString()] [string] $Value)

    $parsed = [guid]::Empty
    $isGuid = [guid]::TryParseExact($Value, 'D', [ref]$parsed)
    return $isGuid
}


function Test-AzResourcesTenantId {
    # The tenant id becomes a path segment, so it must be a GUID — never a
    # value that could climb out of the cache root.
    param([AllowNull()] [AllowEmptyString()] [string] $TenantId)

    $isGuid = Test-AzResourcesGuid -Value $TenantId
    return $isGuid
}


function Get-AzResourcesCacheDir {
    param([Parameter(Mandatory)] [string] $TenantId)

    if (-not (Test-AzResourcesTenantId -TenantId $TenantId)) {
        throw "Tenant id '$TenantId' is not a GUID."
    }

    $cacheRoot = Get-AzResourcesCacheRoot
    $dir = Join-Path $cacheRoot ([guid]$TenantId).ToString()
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
    # or unparseable output comes back as Ok = $false. NeedsLogin is true for an
    # AADSTS sign-in error (ExpiredLogin for the expired / revoked subset);
    # otherwise NotPermitted is true for an authorization / insufficient-
    # privileges / consent error.
    param([Parameter(Mandatory)] [string[]] $ArgList)

    $envelope = Invoke-AzDevOpsAzJson -ArgList $ArgList
    $errorText = [string]$envelope.Error

    $isOk = ($envelope.ExitCode -eq 0)
    $isConsent = (-not $isOk) -and ($errorText -match $script:AzResourcesConsentPattern)
    $isNeedsLogin = (-not $isOk) -and (-not $isConsent) -and ($errorText -match $script:AzResourcesReauthPattern)
    $isExpiredLogin = $isNeedsLogin -and ($errorText -match $script:AzResourcesExpiredLoginPattern)
    $isNotPermitted = $isConsent -or ((-not $isOk) -and (-not $isNeedsLogin) -and ($errorText -match $script:AzResourcesPermissionPattern))
    $errorSummary = Get-AzResourcesErrorSummary -ErrorText $errorText

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
        NeedsLogin   = $isNeedsLogin
        ExpiredLogin = $isExpiredLogin
        Data         = $data
        Error        = $errorSummary
    }

    return $result
}


function Format-AzResourcesCallError {
    # The one wording for a failed az call, used in throws and console notes.
    param(
        [Parameter(Mandatory)] [string] $What,
        [Parameter(Mandatory)] [PSCustomObject] $Result
    )

    $detail = if ($Result.NeedsLogin) {
        "$($script:AzResourcesReauthHint) ($($Result.Error))"
    } else {
        $Result.Error
    }

    $message = "$What failed: $detail"
    return $message
}


function Assert-AzResourcesSignedIn {
    # Throw on a sign-in error: every later call in the tile would fail the
    # same way, and throwing keeps the tile's previous cache.
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Result,
        [Parameter(Mandatory)] [string] $What
    )

    if ($Result.NeedsLogin) {
        throw (Format-AzResourcesCallError -What $What -Result $Result)
    }
}


function Invoke-AzResourcesAzChecked {
    # Invoke-AzResourcesAz plus the fetchers' failure gate in one step, for the
    # single-call tenant-wide tiles (groups, apps): a permission denial is
    # returned for the caller to tally; any other failure throws, so the tile
    # keeps its previous cache. The per-subscription tiles call
    # Invoke-AzResourcesAz directly and tally failures instead.
    param(
        [Parameter(Mandatory)] [string[]] $ArgList,
        [Parameter(Mandatory)] [string] $What
    )

    $result = Invoke-AzResourcesAz -ArgList $ArgList
    Assert-AzResourcesSignedIn -Result $result -What $What

    if (-not $result.Ok -and -not $result.NotPermitted) {
        throw (Format-AzResourcesCallError -What $What -Result $result)
    }

    return $result
}


function New-AzResourcesCallTally {
    $tally = [PSCustomObject]@{
        Allowed    = 0
        Denied     = 0
        Failed     = 0
        FirstError = ''
    }

    return $tally
}


function Test-AzResourcesCallPermitted {
    # Count one call against -Tally and say whether its data is usable. The
    # single home of the "denied / failed -> skip, allowed -> use" branch every
    # fetcher needs. A per-subscription failure (throttling, a 5xx, a
    # subscription cancelled mid-sync) is tallied rather than thrown, so one bad
    # subscription doesn't discard the others; Get-AzResourcesTallyTileResult
    # fails the tile only when nothing succeeded. A sign-in error throws: every
    # later call would fail the same way.
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Result,
        [Parameter(Mandatory)] [PSCustomObject] $Tally,
        [string] $What = 'az call'
    )

    Assert-AzResourcesSignedIn -Result $Result -What $What

    if ($Result.NotPermitted) {
        $Tally.Denied++
        return $false
    }

    if (-not $Result.Ok) {
        $Tally.Failed++

        if (-not $Tally.FirstError) {
            $Tally.FirstError = Format-AzResourcesCallError -What $What -Result $Result
        }

        return $false
    }

    $Tally.Allowed++
    return $true
}


function Get-AzResourcesObjectIdLookupArgs {
    # Where the signed-in principal's object id comes from, as
    # { ObjectId; LookupArgs; Error } — at most one is set:
    #   user              -> `az ad signed-in-user show`
    #   service principal -> `az ad sp show --id <appId>`
    #   managed identity  -> 'MSIObject-<id>' directly, or 'MSIClient-<id>' via
    #                        `az ad sp show`; other identity forms can't be
    #                        resolved and say why
    # Ids handed to az are GUID-checked first (they reach az.cmd's command line).
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $UserName,
        [Parameter(Mandatory)] [bool] $IsUser,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $IdentityInfo
    )

    $objectId = ''
    $lookupArgs = $null
    $reason = ''

    if ($IsUser) {
        $lookupArgs = @('ad', 'signed-in-user', 'show')
    } elseif ($script:AzResourcesManagedIdentityNames -contains $UserName) {
        $msiObjectId = ''
        $msiClientId = ''

        if ($IdentityInfo -match $script:AzResourcesMsiObjectIdPattern) {
            $msiObjectId = $Matches[1]
        } elseif ($IdentityInfo -match $script:AzResourcesMsiClientIdPattern) {
            $msiClientId = $Matches[1]
        }

        if ($msiObjectId) {
            $objectId = $msiObjectId
        } elseif (Test-AzResourcesGuid -Value $msiClientId) {
            $lookupArgs = @('ad', 'sp', 'show', '--id', $msiClientId)
        } else {
            $reason = "az is signed in as a managed identity ('$IdentityInfo') whose object id it does not report."
        }
    } elseif (Test-AzResourcesGuid -Value $UserName) {
        $lookupArgs = @('ad', 'sp', 'show', '--id', $UserName)
    } else {
        $reason = "az reports a sign-in name ('$UserName') that is not an app id."
    }

    $plan = [PSCustomObject]@{
        ObjectId   = $objectId
        LookupArgs = $lookupArgs
        Error      = $reason
    }

    return $plan
}


function Get-AzResourcesSignedInObjectId {
    # The signed-in principal's object id, used as --assignee and for "is this
    # role mine" matching. Returns { ObjectId; Error; Retryable; ExpiredLogin }. Retryable marks a lookup that failed for a reason a later
    # sync may not hit (throttling, a 5xx, an MFA / Conditional Access
    # challenge): the roles tile then fails and keeps its previous cache instead
    # of overwriting it with "not permitted".
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $UserName,
        [Parameter(Mandatory)] [bool] $IsUser,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $IdentityInfo
    )

    $plan = Get-AzResourcesObjectIdLookupArgs -UserName $UserName -IsUser $IsUser -IdentityInfo $IdentityInfo

    $objectId = $plan.ObjectId
    $lookupError = $plan.Error
    $isRetryable = $false
    $isExpiredLogin = $false

    if ($plan.LookupArgs) {
        $lookup = Invoke-AzResourcesAz -ArgList $plan.LookupArgs

        if ($lookup.Ok) {
            $objectId = [string]$lookup.Data.id
        } else {
            $lookupError = Format-AzResourcesCallError -What 'object id lookup' -Result $lookup
            $isRetryable = -not $lookup.NotPermitted
            $isExpiredLogin = $lookup.ExpiredLogin
        }
    }

    if ($objectId -and -not (Test-AzResourcesGuid -Value $objectId)) {
        $lookupError = "the object id az returned ('$objectId') is not a GUID."
        $objectId = ''
    }

    $signedIn = [PSCustomObject]@{
        ObjectId     = $objectId
        Error        = $lookupError
        Retryable    = $isRetryable
        ExpiredLogin = $isExpiredLogin
    }

    return $signedIn
}


function Get-AzResourcesLocalAccount {
    # { TenantId, UserName, UserType, IdentityInfo } az is logged into, read
    # from the local az profile (no network), or $null when az is missing or
    # signed out. IdentityInfo is user.assignedIdentityInfo — '' except for a
    # managed-identity login, whose user.name is a shared placeholder. The
    # single `az account show` reader — the sync, the terminal views, and the
    # viewer's per-refresh tenant check all go through it.
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        return $null
    }

    # try/catch: with $ErrorActionPreference = 'Stop' (or 7.3+'s
    # $PSNativeCommandUseErrorActionPreference) a signed-out az would throw.
    $raw = $null
    try {
        $raw = az account show --output json 2>$null
    }
    catch {
        $raw = $null
    }

    if ($LASTEXITCODE -ne 0 -or -not $raw) {
        return $null
    }

    $account = $null
    try {
        $account = ($raw -join "`n") | ConvertFrom-Json
    }
    catch {
        return $null
    }

    if (-not $account.tenantId) {
        return $null
    }

    $localAccount = [PSCustomObject]@{
        TenantId     = ([string]$account.tenantId).Trim()
        UserName     = [string]$account.user.name
        UserType     = [string]$account.user.type
        IdentityInfo = [string]$account.user.assignedIdentityInfo
    }

    return $localAccount
}


function Get-AzResourcesAccountContext {
    # Who am I, in which tenant? Returns $null when az isn't logged in so the
    # caller can print one clear message before touching the cache. ObjectId is
    # '' when it can't be resolved (ObjectIdError says why, ObjectIdRetryable
    # whether a later sync might succeed); ExpiredLogin means the sign-in itself
    # has lapsed and the sync should stop up front.
    $account = Get-AzResourcesLocalAccount
    if ($null -eq $account) {
        return $null
    }

    $userName = $account.UserName
    $userType = $account.UserType
    $identityInfo = $account.IdentityInfo
    $isUser = ($userType -eq $script:AzResourcesUserAccountType)

    $signedIn = Get-AzResourcesSignedInObjectId -UserName $userName -IsUser $isUser -IdentityInfo $identityInfo

    $context = [PSCustomObject]@{
        TenantId          = $account.TenantId
        UserName          = $userName
        UserType          = $userType
        IdentityInfo      = $identityInfo
        IsUser            = $isUser
        ObjectId          = $signedIn.ObjectId
        ObjectIdError     = $signedIn.Error
        ObjectIdRetryable = $signedIn.Retryable
        ExpiredLogin      = $signedIn.ExpiredLogin
    }

    return $context
}


function Get-AzResourcesSubscriptions {
    # Enabled subscriptions in the CURRENT tenant only — v1 is the tenant az is
    # logged into, not a multi-tenant aggregate. `az login --allow-no-subscriptions`
    # adds a tenant-level placeholder whose id IS the tenant id; it isn't a
    # subscription, so it is skipped.
    param([Parameter(Mandatory)] [string] $TenantId)

    $result = Invoke-AzResourcesAz -ArgList @('account', 'list')
    if (-not $result.Ok) {
        throw "az account list failed: $($result.Error)"
    }

    $subscriptions = New-Object System.Collections.Generic.List[object]

    foreach ($raw in $result.Data) {
        $isInTenant    = ($null -ne $raw) -and ($raw.tenantId -eq $TenantId)
        $isEnabled     = ($null -ne $raw) -and ($raw.state -eq $script:AzResourcesEnabledSubState)
        $isTenantLevel = ($null -ne $raw) -and ([string]$raw.id -eq $TenantId)

        if ($isInTenant -and $isEnabled -and -not $isTenantLevel) {
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
    # Returns { Ok, NotPermitted, NeedsLogin, Error, Items } — the same fields
    # Test-AzResourcesCallPermitted reads off a single az call.
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
        Ok           = -not $isNotPermitted
        NotPermitted = $isNotPermitted
        NeedsLogin   = $false
        Error        = ''
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
    # Turn a fetcher's call tally into its tile result: no call succeeded and
    # one failed means the tile fails (throws, so the previous cache is kept);
    # every call denied means notPermitted; some denied or failed means keep
    # what we got and say so. -Notes appends extra caveats (e.g. roles that
    # couldn't be read).
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]] $Records,
        [Parameter(Mandatory)] [PSCustomObject] $Tally,
        [Parameter(Mandatory)] [string] $Label,
        [string[]] $Notes = @()
    )

    $attempted = $Tally.Allowed + $Tally.Denied + $Tally.Failed

    if ($Tally.Failed -gt 0 -and $Tally.Allowed -eq 0) {
        throw "all $Label calls failed or were denied; first failure: $($Tally.FirstError)"
    }

    $state = $script:AzResourcesStateOk
    $messages = New-Object System.Collections.Generic.List[string]

    if ($Tally.Denied -gt 0 -and $Tally.Allowed -eq 0) {
        $state = $script:AzResourcesStateNotPermitted
        $messages.Add("Your account is not permitted to read $Label in this tenant.")
    } elseif ($Tally.Denied -gt 0) {
        $messages.Add("Partial: $($Tally.Denied) of $attempted $Label call(s) were not permitted.")
    }

    if ($Tally.Failed -gt 0) {
        # The cached message stays generic; the az error itself goes to the console only.
        $messages.Add("Partial: $($Tally.Failed) of $attempted $Label call(s) failed; run az-Sync-AzResources again to retry.")
        Write-Host "$($script:AzResourcesConsoleIndent)first failure: $($Tally.FirstError)" -ForegroundColor DarkYellow
    }

    foreach ($note in $Notes) {
        $messages.Add($note)
    }

    $tileResult = New-AzResourcesTileResult -State $state -Records $Records -Message ($messages -join ' ')
    return $tileResult
}


function New-AzResourcesNotPermittedResult {
    param([Parameter(Mandatory)] [string] $Message)

    $empty = New-Object System.Collections.Generic.List[object]

    $tileResult = New-AzResourcesTileResult -State $script:AzResourcesStateNotPermitted -Records $empty -Message $Message
    return $tileResult
}


function Get-AzResourcesUserOnlyTileResult {
    # Graph `me/...` and `--show-mine` only make sense for a user sign-in; for a
    # service-principal / managed-identity login the tile is notPermitted
    # rather than a hard failure.
    param([Parameter(Mandatory)] [string] $Label)

    $message = "$Label need a user sign-in; az is signed in as a service principal or managed identity."

    $tileResult = New-AzResourcesNotPermittedResult -Message $message
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
        # Keep in sync with the $script:AzResourcesKind* constants (attribute
        # arguments must be literals).
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
            $isManagementGroup = $ResourceId -match $script:AzResourcesManagementGroupScopePattern

            $url = if ($isTenantRoot) {
                "$tenantRoot$($script:AzResourcesPortalHomePath)"
            } elseif ($isManagementGroup) {
                "$tenantRoot$($script:AzResourcesPortalMgmtGroupBlade)"
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
    } elseif ($segments.Count -eq 2 -and $segments[0] -ieq $script:AzResourcesSubscriptionSegment) {
        $script:AzResourcesScopeSubscription
    } elseif ($segments.Count -eq 4 -and $segments[0] -ieq $script:AzResourcesSubscriptionSegment -and $segments[2] -ieq $script:AzResourcesResourceGroupSegment) {
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


function ConvertTo-AzResourcesDateTimeOffset {
    # Any date shape az / the cache hands back -> [datetimeoffset], or $null.
    # PowerShell 6+ ConvertFrom-Json turns ISO strings into [datetime]; 5.1
    # leaves the raw string (...Z or ...+00:00). Shared by the sync (writing
    # ISO) and the views (sorting / comparing expiry dates).
    param([AllowNull()] $Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    if ($Value -is [datetimeoffset]) {
        return $Value
    }

    if ($Value -is [datetime]) {
        $fromDate = [datetimeoffset]$Value.ToUniversalTime()
        return $fromDate
    }

    $parsed = [datetimeoffset]::MinValue

    $isParsed = [datetimeoffset]::TryParse(
        [string]$Value,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$parsed
    )

    if (-not $isParsed) {
        return $null
    }

    return $parsed
}


function ConvertTo-AzResourcesIsoDate {
    # Normalize a date to one round-trip ISO 8601 UTC string, so the cache is
    # byte-identical whichever PowerShell edition synced it. An unparseable
    # value is kept verbatim rather than dropped.
    param([AllowNull()] $Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return ''
    }

    $offset = ConvertTo-AzResourcesDateTimeOffset -Value $Value

    if ($null -eq $offset) {
        $raw = [string]$Value
        return $raw
    }

    $isoDate = $offset.UtcDateTime.ToString($script:AzResourcesIsoDateFormat)
    return $isoDate
}


function ConvertTo-AzResourcesCredentials {
    # Secrets + certificates reduced to name / id / kind / dates, plus a
    # secret's hint and a certificate's usage (Sign / Verify — a SAML signing
    # pair is two entries, not a duplicate) and key type. The hint is the first
    # three characters of the secret value, which Graph returns so the portal
    # can tell unnamed secrets apart; it is kept for the same reason (#270) and
    # is the only part of a secret value that is ever cached. customKeyIdentifier
    # (a certificate thumbprint, not secret) ties together the several entries
    # Graph stores for one SAML signing certificate. Only these fields
    # are copied, so secretText or key material can never reach the cache even
    # if az starts returning it. Older az builds name the dates startDate /
    # endDate; Graph-based builds use startDateTime / endDateTime.
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

            $rawStart = if ($null -ne $cred.startDateTime) {
                $cred.startDateTime
            } else {
                $cred.startDate
            }

            $rawEnd = if ($null -ne $cred.endDateTime) {
                $cred.endDateTime
            } else {
                $cred.endDate
            }

            $credentials.Add([ordered]@{
                kind          = $source.Kind
                name          = [string]$cred.displayName
                keyId         = [string]$cred.keyId
                hint          = [string]$cred.hint
                customKeyId   = [string]$cred.customKeyIdentifier
                startDateTime = ConvertTo-AzResourcesIsoDate -Value $rawStart
                endDateTime   = ConvertTo-AzResourcesIsoDate -Value $rawEnd
                usage         = [string]$cred.usage
                keyType       = [string]$cred.type
            })
        }
    }

    # Unary comma so 0 or 1 credentials still serialize as a JSON array.
    return ,$credentials
}


function Get-AzResourcesScopeSubscription {
    # The subscription a scope sits in, taken from the scope itself rather than
    # from whichever subscription's listing returned it: management-group and
    # root assignments sit above every subscription, so both fields are ''.
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Scope,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [hashtable] $SubscriptionNames
    )

    $subscriptionId = ''
    $subscriptionName = ''

    if ($Scope -match $script:AzResourcesSubscriptionScopePattern) {
        $subscriptionId = $Matches[1]

        if ($SubscriptionNames.ContainsKey($subscriptionId)) {
            $subscriptionName = $SubscriptionNames[$subscriptionId]
        }
    }

    $subscription = [PSCustomObject]@{
        Id   = $subscriptionId
        Name = $subscriptionName
    }

    return $subscription
}


function ConvertTo-AzResourcesRoleRecord {
    param(
        [Parameter(Mandatory)] $Raw,
        [Parameter(Mandatory)] [PSCustomObject] $Context,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [hashtable] $SubscriptionNames
    )

    # principalName is empty when az couldn't look the principal up (directory
    # reads blocked, or the principal was deleted) — show its id instead.
    $principal = if ($Raw.principalId -eq $Context.ObjectId) {
        $script:AzResourcesSelfPrincipal
    } elseif ($Raw.principalName) {
        [string]$Raw.principalName
    } else {
        "$($script:AzResourcesUnresolvedPrincipalPrefix)$($Raw.principalId)"
    }

    $scope = [string]$Raw.scope
    $subscription = Get-AzResourcesScopeSubscription -Scope $scope -SubscriptionNames $SubscriptionNames

    $record = [ordered]@{
        id               = [string]$Raw.id
        roleName         = [string]$Raw.roleDefinitionName
        scope            = $scope
        scopeType        = Get-AzResourcesScopeType -Scope $scope
        principal        = $principal
        principalType    = [string]$Raw.principalType
        subscriptionId   = $subscription.Id
        subscriptionName = $subscription.Name
        portalUrl        = Get-AzResourcesPortalUrl -Kind $script:AzResourcesKindResource -TenantId $Context.TenantId -ResourceId $scope
    }

    return $record
}


function Get-AzResourcesNoSubscriptionNotes {
    # Why a per-subscription tile is empty when the tenant has no enabled
    # subscriptions (e.g. `az login --allow-no-subscriptions`): without this the
    # tile reads as a clean "0 records". Management-group / root roles are only
    # found through a subscription today.
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]] $Subscriptions,
        [Parameter(Mandatory)] [string] $What
    )

    $notes = @()

    if ($Subscriptions.Count -eq 0) {
        $notes += "$What come from subscriptions, and az lists none you can use in this tenant; management-group and root assignments are not listed without one."
    }

    return $notes
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

    # Matching by sign-in name instead would misfire for guests (#EXT# UPNs)
    # and could hand az.cmd a name cmd.exe mangles, so with no object id the
    # tile says why rather than guessing.
    if (-not $Context.ObjectId -and $Context.ObjectIdRetryable) {
        throw $Context.ObjectIdError
    }

    if (-not $Context.ObjectId) {
        $unresolved = New-AzResourcesNotPermittedResult -Message 'Role assignments need your object id, which could not be looked up for this sign-in (see the az-Sync-AzResources output).'
        return $unresolved
    }

    $records = New-Object System.Collections.Generic.List[object]
    $seenIds = New-AzResourcesAssignmentIdSet
    $tally = New-AzResourcesCallTally
    $subscriptionNames = @{}

    foreach ($sub in $Subscriptions) {
        $subscriptionNames[$sub.Id] = $sub.Name
    }

    foreach ($sub in $Subscriptions) {
        $argList = @(
            'role', 'assignment', 'list',
            '--assignee', $Context.ObjectId,
            '--include-groups', '--all',
            '--subscription', $sub.Id
        )

        $result = Invoke-AzResourcesAz -ArgList $argList
        if (-not (Test-AzResourcesCallPermitted -Result $result -Tally $tally -What "role assignment list ($($sub.Name))")) {
            continue
        }

        foreach ($raw in $result.Data) {
            if ($null -eq $raw -or -not $seenIds.Add([string]$raw.id)) {
                continue
            }

            $record = ConvertTo-AzResourcesRoleRecord -Raw $raw -Context $Context -SubscriptionNames $subscriptionNames
            $records.Add($record)
        }
    }

    $notes = Get-AzResourcesNoSubscriptionNotes -Subscriptions $Subscriptions -What 'Role assignments'

    $tileResult = Get-AzResourcesTallyTileResult -Records $records -Tally $tally -Label 'role assignments' -Notes $notes
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
                isDynamic    = @($raw.groupTypes) -contains $script:AzResourcesGroupTypeDynamic
                portalUrl    = Get-AzResourcesPortalUrl -Kind $script:AzResourcesKindGroup -TenantId $Context.TenantId -ObjectId $groupId
            })
        }
    }

    $tileResult = Get-AzResourcesTallyTileResult -Records $records -Tally $tally -Label 'group memberships'
    return $tileResult
}


function New-AzResourcesAppSource {
    param(
        [Parameter(Mandatory)] [string[]] $ArgList,
        [Parameter(Mandatory)] [string] $Kind,
        [Parameter(Mandatory)] [bool] $IsOwned
    )

    $source = @{
        ArgList = $ArgList
        Kind    = $Kind
        IsOwned = $IsOwned
    }

    return $source
}


function Get-AzResourcesAppSources {
    # The az calls behind the apps tile. The owned lists (--show-mine) always
    # run: they are what isOwner is derived from. The 'all' scope adds the
    # tenant-wide lists; tenant-wide service principals are limited to apps
    # this tenant registered (appOwnerOrganizationId), which keeps out the
    # thousands of Microsoft first-party enterprise apps every tenant carries
    # (and other tenants' multi-tenant apps, unless you own them — the owned
    # list still brings those in). Owned sources come first so a record found
    # by both keeps isOwner. The tenant id is GUID-checked before it goes into
    # the OData filter on az.cmd's command line.
    param(
        [Parameter(Mandatory)] [string] $Scope,
        [Parameter(Mandatory)] [string] $TenantId
    )

    $appKind = $script:AzResourcesKindAppRegistration
    $spKind = $script:AzResourcesKindServicePrincipal

    $sources = New-Object System.Collections.Generic.List[object]

    $sources.Add((New-AzResourcesAppSource -ArgList @('ad', 'app', 'list', '--show-mine') -Kind $appKind -IsOwned $true))
    $sources.Add((New-AzResourcesAppSource -ArgList @('ad', 'sp', 'list', '--show-mine') -Kind $spKind -IsOwned $true))

    if ($Scope -eq $script:AzResourcesAppScopeAll) {
        if (-not (Test-AzResourcesGuid -Value $TenantId)) {
            throw "tenant id '$TenantId' is not a GUID; cannot build the service principal filter."
        }

        $tenantSpFilter = "appOwnerOrganizationId eq $TenantId"

        $sources.Add((New-AzResourcesAppSource -ArgList @('ad', 'app', 'list', '--all') -Kind $appKind -IsOwned $false))
        $sources.Add((New-AzResourcesAppSource -ArgList @('ad', 'sp', 'list', '--all', '--filter', $tenantSpFilter) -Kind $spKind -IsOwned $false))
    }

    return $sources
}


function Get-AzResourcesTenantAppOwner {
    # isOwner for a row that only a tenant-wide list returned: $false when
    # every owned list was read (so it really isn't yours), else $null —
    # unknown, which the views treat as owned so expiry warnings on apps you
    # do own never silently disappear.
    param([Parameter(Mandatory)] [bool] $OwnedListsComplete)

    if ($OwnedListsComplete) {
        return $false
    }

    return $null
}


function Get-AzResourcesAppTile {
    # App registrations and service principals (enterprise apps) I own — or,
    # with -Scope all, every one in the tenant I can read — each with its
    # secrets / certificates and their expiry dates. isOwner marks the ones
    # --show-mine returned; the result's scope says which mode ran, so the
    # views can label the data and a viewer refresh can repeat the same mode.
    # When every tenant-wide list is denied (guests, locked-down tenants) the
    # tile is recorded as 'owned', since that is all it holds.
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Context,
        # Keep in sync with $script:AzResourcesAppScopes.
        [ValidateSet('owned', 'all')]
        [string] $Scope = $script:AzResourcesAppScopeOwned
    )

    $isAllScope = ($Scope -eq $script:AzResourcesAppScopeAll)

    $label = if ($isAllScope) {
        $script:AzResourcesAppLabelAll
    } else {
        $script:AzResourcesAppLabelOwned
    }

    if (-not $Context.IsUser) {
        $userOnlyLabel = if ($isAllScope) {
            $script:AzResourcesAppUserOnlyLabelAll
        } else {
            $script:AzResourcesAppUserOnlyLabelOwned
        }

        $userOnly = Get-AzResourcesUserOnlyTileResult -Label $userOnlyLabel
        $userOnly.scope = $Scope
        return $userOnly
    }

    $records = New-Object System.Collections.Generic.List[object]
    $seenObjectIds = New-Object 'System.Collections.Generic.HashSet[string]'
    $tally = New-AzResourcesCallTally
    $ownedListsComplete = $true
    $tenantListsRead = 0

    $sources = Get-AzResourcesAppSources -Scope $Scope -TenantId $Context.TenantId

    foreach ($source in $sources) {
        $what = $source.ArgList -join ' '
        $result = Invoke-AzResourcesAzChecked -ArgList $source.ArgList -What $what
        $isPermitted = Test-AzResourcesCallPermitted -Result $result -Tally $tally -What $what

        if ($source.IsOwned -and -not $isPermitted) {
            $ownedListsComplete = $false
        }

        if (-not $isPermitted) {
            continue
        }

        if (-not $source.IsOwned) {
            $tenantListsRead++
        }

        $isOwner = if ($source.IsOwned) {
            $true
        } else {
            Get-AzResourcesTenantAppOwner -OwnedListsComplete $ownedListsComplete
        }

        foreach ($raw in $result.Data) {
            if ($null -eq $raw) {
                continue
            }

            $appId = [string]$raw.appId
            $objectId = [string]$raw.id

            if ($objectId -and -not $seenObjectIds.Add($objectId)) {
                continue
            }

            $credentials = ConvertTo-AzResourcesCredentials -Raw $raw

            # A secret's 3-character hint is only kept for apps that may be
            # yours: the views never show it for anyone else's.
            if ($isOwner -eq $false) {
                foreach ($credential in $credentials) {
                    $credential.hint = ''
                }
            }

            $records.Add([ordered]@{
                displayName = [string]$raw.displayName
                appId       = $appId
                objectId    = $objectId
                kind        = $source.Kind
                isOwner     = $isOwner
                credentials = $credentials
                portalUrl   = Get-AzResourcesPortalUrl -Kind $source.Kind -TenantId $Context.TenantId -ObjectId $objectId -AppId $appId
            })
        }
    }

    $notes = New-Object System.Collections.Generic.List[string]
    $recordedScope = $Scope

    if ($isAllScope -and $tenantListsRead -eq 0) {
        $recordedScope = $script:AzResourcesAppScopeOwned
        $notes.Add($script:AzResourcesAppTenantDeniedNote)
    } elseif ($isAllScope -and -not $ownedListsComplete) {
        $notes.Add($script:AzResourcesAppOwnerUnknownNote)
    }

    $tileResult = Get-AzResourcesTallyTileResult -Records $records -Tally $tally -Label $label -Notes $notes
    $tileResult.scope = $recordedScope
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

        $result = Invoke-AzResourcesAz -ArgList $argList
        if (-not (Test-AzResourcesCallPermitted -Result $result -Tally $Tally -What "role assignment list --all ($($sub.Name))")) {
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
        portalUrl        = Get-AzResourcesPortalUrl -Kind $script:AzResourcesKindResource -TenantId $TenantId -ResourceId $resourceId
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
            $result = Invoke-AzResourcesAz -ArgList $source.ArgList
            if (-not (Test-AzResourcesCallPermitted -Result $result -Tally $tally -What $source.What)) {
                continue
            }

            foreach ($raw in $result.Data) {
                $principalId = Get-AzResourcesIdentityPrincipalId -Raw $raw -IdentityType $source.IdentityType
                if (-not $principalId) {
                    continue
                }

                $record = ConvertTo-AzResourcesIdentityRecord -Raw $raw -IdentityType $source.IdentityType -PrincipalId $principalId @recordArgs
                $records.Add($record)
            }
        }
    }

    $roleGaps = $roleTally.Denied + $roleTally.Failed

    $notes = @(Get-AzResourcesNoSubscriptionNotes -Subscriptions $Subscriptions -What 'Managed identities')
    if ($roleGaps -gt 0) {
        $notes += "Roles could not be read in $roleGaps subscription(s); identities may show fewer roles than they hold."
    }

    $tileResult = Get-AzResourcesTallyTileResult -Records $records -Tally $tally -Label 'managed identities' -Notes $notes
    return $tileResult
}


function Invoke-AzResourcesTileFetch {
    param(
        [Parameter(Mandatory)] [string] $Tile,
        [Parameter(Mandatory)] [PSCustomObject] $Context,
        [AllowNull()] [System.Collections.Generic.List[object]] $Subscriptions,
        # Keep in sync with $script:AzResourcesAppScopes.
        [ValidateSet('owned', 'all')]
        [string] $AppScope = $script:AzResourcesAppScopeOwned
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
            $tileResult = Get-AzResourcesAppTile -Context $Context -Scope $AppScope
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


function Update-AzResourcesTile {
    # EXPENSIVE: fetch one tile and rewrite its cache file, stamped with the
    # account that fetched it (syncedAs). Throws on a hard failure (the
    # previous cache file is left untouched). Shared by az-Sync-AzResources and
    # the Resource Viewer's per-tile refresh. -AppScope only affects the apps
    # tile ('owned' or 'all').
    param(
        [Parameter(Mandatory)] [string] $Tile,
        [Parameter(Mandatory)] [PSCustomObject] $Context,
        [AllowNull()] [System.Collections.Generic.List[object]] $Subscriptions,
        # Keep in sync with $script:AzResourcesAppScopes.
        [ValidateSet('owned', 'all')]
        [string] $AppScope = $script:AzResourcesAppScopeOwned
    )

    $tileResult = Invoke-AzResourcesTileFetch -Tile $Tile -Context $Context -Subscriptions $Subscriptions -AppScope $AppScope
    $tileResult.syncedAs = New-AzResourcesSyncedAs -Context $Context
    $path = Get-AzResourcesTilePath -TenantId $Context.TenantId -Tile $Tile

    Write-LocalViewerTileCache -Path $path -Tile $Tile -Items $tileResult -JsonDepth $script:AzResourcesJsonDepth

    return $tileResult
}


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

function Test-AzResourcesSyncContext {
    # Print what the sign-in context means for this sync, and say whether to go
    # on: an expired / revoked login stops it up front; an unresolved object id
    # only skips (or, when retryable, fails) the roles tile.
    param([Parameter(Mandatory)] [PSCustomObject] $Context)

    if ($Context.ExpiredLogin) {
        Write-Host $Context.ObjectIdError -ForegroundColor Yellow
        return $false
    }

    if (-not $Context.ObjectId) {
        Write-Host "Could not resolve your object id, so role assignments are skipped: $($Context.ObjectIdError)" -ForegroundColor DarkYellow
    }

    return $true
}


function New-AzResourcesSyncedAs {
    # Who this sync ran as, stamped on every tile (see the file header). Every
    # managed identity reports the same placeholder user.name, so its
    # assignedIdentityInfo is kept too to tell two identities apart.
    param([Parameter(Mandatory)] [PSCustomObject] $Context)

    $syncedAs = [ordered]@{
        userName     = $Context.UserName
        userType     = $Context.UserType
        identityInfo = $Context.IdentityInfo
        objectId     = $Context.ObjectId
    }

    return $syncedAs
}


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

        The apps tile lists only app registrations / service principals that
        name you as an Owner in Entra (`az ad ... list --show-mine`). Apps an
        admin, a pipeline or a teammate created are missing unless you're
        added as an owner; use -AllApps to list every one you can read.

    .PARAMETER Tile
        Refresh only this tile: roles, groups, apps, or identities.

    .PARAMETER AllApps
        Sync the apps tile in "all in tenant" mode: every app registration you
        can read, plus every service principal for an app registered in this
        tenant, each marked with whether you own it. Service principals for
        apps registered in other tenants (Microsoft first-party, multi-tenant
        SaaS) are left out unless you own them. Guest accounts and tenants that
        restrict default user permissions can't list the whole tenant; the tile
        then says so and shows only the apps you own. This can be slow in a
        large tenant, and the local cache then holds credential names and end
        dates for every listed app (never secret values). The mode is
        recorded in the cache, so the Resource Viewer's per-tile refresh keeps
        it; a later sync without -AllApps goes back to owned-only. Credential
        expiry warnings still cover only the apps you own.

    .EXAMPLE
        az-Sync-AzResources

    .EXAMPLE
        az-Sync-AzResources -Tile groups

    .EXAMPLE
        az-Sync-AzResources -Tile apps -AllApps
    #>
    param(
        # Keep in sync with $script:AzResourcesTileNames.
        [ValidateSet('roles', 'groups', 'apps', 'identities')]
        [string] $Tile,

        [switch] $AllApps
    )

    $context = Get-AzResourcesAccountContext
    if ($null -eq $context) {
        Write-Host "Not logged in to Azure. Run 'az login' and try again." -ForegroundColor Yellow
        return
    }

    if (-not (Test-AzResourcesSyncContext -Context $context)) {
        return
    }

    # Resolve (and GUID-validate) the cache dir once, before any expensive
    # fetch, so a bad tenant id stops the sync with one clear message.
    try {
        $cacheDir = Get-AzResourcesCacheDir -TenantId $context.TenantId
    }
    catch {
        Write-Host "Cannot sync Azure resources: $($_.Exception.Message)" -ForegroundColor Red
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

    $appScope = if ($AllApps) {
        $script:AzResourcesAppScopeAll
    } else {
        $script:AzResourcesAppScopeOwned
    }

    if ($AllApps -and $tiles -notcontains $script:AzResourcesTileApps) {
        Write-Host "-AllApps only affects the apps tile; ignored for -Tile $Tile." -ForegroundColor DarkYellow
    }

    $failed = 0

    foreach ($name in $tiles) {
        try {
            $tileResult = Update-AzResourcesTile -Tile $name -Context $context -Subscriptions $subscriptions -AppScope $appScope

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

    Write-Host ''
    Write-Host "Cache: $cacheDir" -ForegroundColor Cyan

    if ($failed -gt 0) {
        Write-Host "Partial sync - $failed of $($tiles.Count) tile(s) failed." -ForegroundColor Yellow
    }
}
