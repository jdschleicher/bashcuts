# ============================================================================
# Azure Resources — Paths, tile contract, portal links
# ============================================================================
# Filesystem layout + on-disk tile contract for the Azure Resource Viewer
# (epic #265). Every tile is tenant-scoped, so the cache is keyed by the tenant
# id `az account show` reports rather than by an Azure DevOps project slug:
#
#   $HOME/.bashcuts-az-resources-app/cache/<tenantId>/
#     roles.json       - RBAC role assignments I hold (directly or via a group)
#     groups.json      - Entra groups I'm a member or owner of
#     apps.json        - app registrations + service principals I own
#     identities.json  - managed identities in subscriptions I can read
#
# Each file is { tile, tenantId, writtenAt, state, message, warnings, items } —
# the same { tile, writtenAt, items } core the Daily Viewer's tile cache uses,
# plus a state ('ok' / 'notPermitted') so a tile the tenant blocks renders a
# "not permitted" state instead of an error. Staleness is the file's mtime.
#
# Pure plumbing — no public az-* functions live here. az-Sync-AzResources is in
# azresources_sync.ps1; the per-tile fetchers are in azresources_fetchers.ps1.
#
# Loaded by powcuts_home.ps1 (after the azdevops_*.ps1 files, whose generic
# Invoke-AzDevOpsAzJson / Write-AzDevOpsCacheFile / New-AzDevOpsDirectoryIfMissing
# / Get-AzDevOpsPlatform helpers this family reuses).

$script:AzResourcesTileRoles      = 'roles'
$script:AzResourcesTileGroups     = 'groups'
$script:AzResourcesTileApps       = 'apps'
$script:AzResourcesTileIdentities = 'identities'

$script:AzResourcesStateOk           = 'ok'
$script:AzResourcesStateNotPermitted = 'notPermitted'
$script:AzResourcesStateError        = 'error'

$script:AzResourcesJsonDepth   = 10
$script:AzResourcesGuidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'

$script:AzResourcesPosixPrivateDirMode = '700'   # owner-only: the cache maps who can do what in the tenant

$script:AzResourcesScopeRoot            = 'root'
$script:AzResourcesScopeManagementGroup = 'managementGroup'
$script:AzResourcesScopeSubscription    = 'subscription'
$script:AzResourcesScopeResourceGroup   = 'resourceGroup'
$script:AzResourcesScopeResource        = 'resource'

$script:AzResourcesPortalBase            = 'https://portal.azure.com'
$script:AzResourcesManagementGroupBlade  = 'Microsoft_Azure_ManagementGroups/HierarchyBlade'
$script:AzResourcesGroupBlade            = 'Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Overview/groupId'
$script:AzResourcesAppRegistrationBlade  = 'Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Overview/appId'
$script:AzResourcesServicePrincipalBlade = 'Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Overview/objectId'


function Get-AzResourcesAppRoot {
    $root = Join-Path $HOME '.bashcuts-az-resources-app'
    return $root
}


function Get-AzResourcesTileNames {
    $names = @(
        $script:AzResourcesTileRoles,
        $script:AzResourcesTileGroups,
        $script:AzResourcesTileApps,
        $script:AzResourcesTileIdentities
    )

    return $names
}


function Test-AzResourcesTileName {
    param([Parameter(Mandatory)] [string] $Name)

    $known = Get-AzResourcesTileNames
    $isKnown = $known -contains $Name
    return $isKnown
}


function Get-AzResourcesTenantCacheDir {
    # The tenant id becomes a path segment, so it must be a bare GUID — anything
    # else (an empty value, a '..' segment) is refused rather than joined.
    param([Parameter(Mandatory)] [string] $TenantId)

    if ($TenantId -notmatch $script:AzResourcesGuidPattern) {
        throw "Get-AzResourcesTenantCacheDir: '$TenantId' is not a tenant id (GUID)."
    }

    $dir = Join-Path (Join-Path (Get-AzResourcesAppRoot) 'cache') $TenantId.ToLower()
    return $dir
}


function Get-AzResourcesTilePath {
    param(
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [string] $Tile
    )

    $dir = Get-AzResourcesTenantCacheDir -TenantId $TenantId
    $path = Join-Path $dir "$Tile.json"
    return $path
}


function Get-AzResourcesScopeType {
    # Classify an ARM scope / resource id. -Regex matching is case-insensitive,
    # matching ARM's own case-insensitive ids.
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Scope)

    $scopeType = switch -Regex ($Scope) {
        '^/$' {
            $script:AzResourcesScopeRoot
        }

        '^/providers/Microsoft\.Management/managementGroups/[^/]+$' {
            $script:AzResourcesScopeManagementGroup
        }

        '^/subscriptions/[^/]+$' {
            $script:AzResourcesScopeSubscription
        }

        '^/subscriptions/[^/]+/resourceGroups/[^/]+$' {
            $script:AzResourcesScopeResourceGroup
        }

        default {
            $script:AzResourcesScopeResource
        }
    }

    return $scopeType
}


function Get-AzResourcesPortalUrl {
    # The one deep-link builder every tile's records go through. -Id is the ARM
    # scope / resource id for 'Resource', the group object id for 'Group', the
    # appId for 'AppRegistration', and the service principal object id for
    # 'ServicePrincipal' (which also takes -AppId). Root and management-group
    # scopes have no /resource blade, so they open the management-group
    # hierarchy instead.
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Resource', 'Group', 'AppRegistration', 'ServicePrincipal')]
        [string] $Kind,

        [Parameter(Mandatory)] [string] $Id,
        [string] $AppId,
        [string] $TenantId
    )

    $base = $script:AzResourcesPortalBase

    $scopeType = if ($Kind -eq 'Resource') {
        Get-AzResourcesScopeType -Scope $Id
    } else {
        ''
    }

    $isHierarchyScope = $scopeType -in @($script:AzResourcesScopeRoot, $script:AzResourcesScopeManagementGroup)

    $url = switch ($Kind) {
        'Resource' {
            if ($isHierarchyScope) {
                "$base/#@$TenantId/view/$($script:AzResourcesManagementGroupBlade)"
            } else {
                "$base/#@$TenantId/resource$Id"
            }
        }

        'Group' {
            "$base/#view/$($script:AzResourcesGroupBlade)/$Id"
        }

        'AppRegistration' {
            "$base/#view/$($script:AzResourcesAppRegistrationBlade)/$Id"
        }

        'ServicePrincipal' {
            "$base/#view/$($script:AzResourcesServicePrincipalBlade)/$Id/appId/$AppId"
        }
    }

    return $url
}


function New-AzResourcesTileResult {
    # The shape every fetcher returns and Write-AzResourcesTile persists.
    # ValidateSet needs literals: keep it in step with $script:AzResourcesState*.
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ok', 'notPermitted', 'error')]
        [string] $State,

        [AllowEmptyCollection()] [object[]] $Items = @(),
        [AllowEmptyCollection()] [string[]] $Warnings = @(),
        [string] $Message = ''
    )

    $result = [PSCustomObject]@{
        State    = $State
        Items    = $Items
        Warnings = $Warnings
        Message  = $Message
    }

    return $result
}


function Initialize-AzResourcesCacheDir {
    # Create the tenant cache dir. On Linux / macOS the app root is locked to
    # the owner (like ~/.azure): the tiles map who can do what in the tenant.
    param([Parameter(Mandatory)] [string] $TenantId)

    $dir = Get-AzResourcesTenantCacheDir -TenantId $TenantId
    New-AzDevOpsDirectoryIfMissing -Path $dir

    if ((Get-AzDevOpsPlatform) -eq 'Posix') {
        & chmod $script:AzResourcesPosixPrivateDirMode (Get-AzResourcesAppRoot) 2>$null
    }

    return $dir
}


function Write-AzResourcesTile {
    # Persist one tile's fetch result atomically. Only the normalized records the
    # fetchers built are written — never the raw az payload — so no access token
    # or secret value can reach the cache.
    param(
        [Parameter(Mandatory)] [string]         $TenantId,
        [Parameter(Mandatory)] [string]         $Tile,
        [Parameter(Mandatory)] [PSCustomObject] $Result
    )

    $null = Initialize-AzResourcesCacheDir -TenantId $TenantId
    $path = Get-AzResourcesTilePath -TenantId $TenantId -Tile $Tile

    $record = [ordered]@{
        tile      = $Tile
        tenantId  = $TenantId.ToLower()
        writtenAt = (Get-Date).ToString('o')
        state     = $Result.State
        message   = $Result.Message
        warnings  = @($Result.Warnings)
        items     = @($Result.Items)
    }

    $json = $record | ConvertTo-Json -Depth $script:AzResourcesJsonDepth
    Write-AzDevOpsCacheFile -Path $path -Content $json
}
