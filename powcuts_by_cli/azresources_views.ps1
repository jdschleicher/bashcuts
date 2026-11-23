# ============================================================================
# Azure Resources — terminal views over the tile cache (Epic #265 — C)
# ============================================================================
# Console views of the cached Azure / Entra footprint written by
# az-Sync-AzResources (azresources_data.ps1). Every view reads the cache only —
# no network call — and prints a one-line status ("cached 12m ago") before
# emitting rows as objects, so they pipe into Where-Object / Sort-Object /
# Format-Table / Export-Csv like any other cmdlet output.
#
# Public functions:
#   az-Show-AzRoleAssignments    - RBAC roles I hold (directly or via a group)
#   az-Show-AzGroupMemberships   - Entra groups I'm a member / owner of
#   az-Show-AzAppRegistrations   - apps + service principals I own, with creds
#   az-Show-AzManagedIdentities  - managed identities and the roles they hold
#
# Each row type registers a short default display set (<= 4 columns, so the
# console renders a table); every other field stays on the object for
# `Select-Object *` or the pipeline.
#
# Which tenant: the one az is logged into (`az account show` reads the local
# az profile, no network); when az has no account, the most recently synced
# tenant cache is used instead.
#
# Depends on azresources_data.ps1 and localhost_viewer.ps1; loaded by
# powcuts_home.ps1 after both.

$script:AzResourcesViewStaleSeconds = 86400   # a day: past this the status line nudges a re-sync
$script:AzResourcesViewSyncHint     = "Run 'az-Sync-AzResources' to refresh."
$script:AzResourcesViewDateFormat   = 'yyyy-MM-dd'
$script:AzResourcesViewMiddot       = "$([char]0x00B7)"   # middle dot — "12 rows · cached 3m ago"
$script:AzResourcesViewRoleJoin     = ', '
$script:AzResourcesViewScopeRoot    = '/'

$script:AzResourcesRoleRowType     = 'Bashcuts.AzResources.RoleAssignment'
$script:AzResourcesGroupRowType    = 'Bashcuts.AzResources.GroupMembership'
$script:AzResourcesAppRowType      = 'Bashcuts.AzResources.AppRegistration'
$script:AzResourcesIdentityRowType = 'Bashcuts.AzResources.ManagedIdentity'

$script:AzResourcesRoleDisplay     = @('Role', 'Principal', 'ScopeType', 'ScopeName')
$script:AzResourcesGroupDisplay    = @('Name', 'Relationship', 'GroupType', 'Mail')
$script:AzResourcesAppDisplay      = @('Name', 'Kind', 'Credentials', 'NextExpiry')
$script:AzResourcesIdentityDisplay = @('Name', 'Type', 'ResourceGroup', 'RoleCount')


# ---------------------------------------------------------------------------
# Cache read + status line (shared by every view)
# ---------------------------------------------------------------------------

function Get-AzResourcesViewTenantId {
    # The tenant az is logged into, read from the local az profile (no network);
    # else the most recently synced tenant folder; else ''.
    $tenantId = ''

    if (Get-Command az -ErrorAction SilentlyContinue) {
        $azTenant = az account show --query tenantId --output tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $azTenant) {
            $tenantId = ([string]$azTenant).Trim()
        }
    }

    if (-not $tenantId) {
        $cacheRoot = Get-AzResourcesCacheRoot

        if (Test-Path -LiteralPath $cacheRoot) {
            $newest = Get-ChildItem -LiteralPath $cacheRoot -Directory |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1

            if ($newest) {
                $tenantId = $newest.Name
            }
        }
    }

    return $tenantId
}


function Write-AzResourcesViewMissing {
    param([Parameter(Mandatory)] [string] $Title)

    Write-Host "${Title}: no cached data yet. $($script:AzResourcesViewSyncHint)" -ForegroundColor Yellow
}


function Read-AzResourcesViewTile {
    # Load one tile from the cache and print its status line. Returns the
    # tile's records (possibly none). Prints a hint and returns nothing when the
    # cache is missing, and a one-line notice when the tile is notPermitted.
    param(
        [Parameter(Mandatory)] [string] $Tile,
        [Parameter(Mandatory)] [string] $Title
    )

    $tenantId = Get-AzResourcesViewTenantId
    if (-not $tenantId) {
        Write-AzResourcesViewMissing -Title $Title
        return
    }

    try {
        $path = Get-AzResourcesTilePath -TenantId $tenantId -Tile $Tile
    }
    catch {
        Write-AzResourcesViewMissing -Title $Title
        return
    }

    $model = Read-LocalViewerTileCache -Path $path -Tile $Tile -StaleSeconds $script:AzResourcesViewStaleSeconds
    if ($null -eq $model -or $null -eq $model.items) {
        Write-AzResourcesViewMissing -Title $Title
        return
    }

    $cachedAt = (Get-Date).AddSeconds(-$model.ageSeconds)
    $ageLabel = "cached $(Get-LocalViewerRelativeTime -When $cachedAt)"
    $items = $model.items

    if ($items.state -eq $script:AzResourcesStateNotPermitted) {
        Write-Host "${Title}: not permitted $($script:AzResourcesViewMiddot) $($items.message) ($ageLabel)" -ForegroundColor Yellow
        return
    }

    $records = @($items.records | Where-Object { $null -ne $_ })

    $statusColor = if ($model.stale) {
        'Yellow'
    } else {
        'DarkGray'
    }

    $status = "${Title}: $($records.Count) $($script:AzResourcesViewMiddot) $ageLabel"
    if ($model.stale) {
        $status = "$status $($script:AzResourcesViewMiddot) $($script:AzResourcesViewSyncHint)"
    }

    Write-Host $status -ForegroundColor $statusColor

    if ($items.message) {
        Write-Host "  $($items.message)" -ForegroundColor Yellow
    }

    return $records
}


function Set-AzResourcesViewDisplay {
    # Register a row type's default columns. Kept to <= 4 so the console picks
    # table layout; the full object is still emitted. Called per view (cheap,
    # idempotent with -Force) rather than at dot-source time.
    param(
        [Parameter(Mandatory)] [string] $TypeName,
        [Parameter(Mandatory)] [string[]] $Properties
    )

    Update-TypeData -TypeName $TypeName -DefaultDisplayPropertySet $Properties -Force
}


# ---------------------------------------------------------------------------
# Field helpers
# ---------------------------------------------------------------------------

function ConvertTo-AzResourcesDateTimeOffset {
    # A cached date back to [datetimeoffset], or $null. The cache stores ISO
    # strings, but PowerShell 6+ ConvertFrom-Json hands them back as [datetime].
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


function Get-AzResourcesScopeDisplayName {
    # Last segment of an ARM scope ("rg-payments", the subscription GUID, a
    # resource name); the tenant root stays "/".
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Scope)

    $segments = @($Scope.Trim('/') -split '/' | Where-Object { $_ })

    $name = if ($segments.Count -gt 0) {
        $segments[-1]
    } else {
        $script:AzResourcesViewScopeRoot
    }

    return $name
}


function Get-AzResourcesSoonestExpiry {
    # Earliest end date across an app's credentials, or $null when none have one.
    param([AllowNull()] $Credentials)

    $soonest = $null

    foreach ($credential in $Credentials) {
        $end = ConvertTo-AzResourcesDateTimeOffset -Value $credential.endDateTime

        if ($null -ne $end -and ($null -eq $soonest -or $end -lt $soonest)) {
            $soonest = $end
        }
    }

    return $soonest
}


# ---------------------------------------------------------------------------
# Public views
# ---------------------------------------------------------------------------

function az-Show-AzRoleAssignments {
    <#
    .SYNOPSIS
        List the Azure RBAC role assignments you hold, from the local cache.

    .DESCRIPTION
        Reads the roles tile written by az-Sync-AzResources (no network call).
        Principal is "me" for direct assignments, or the group the role comes
        through. Rows are objects: pipe to Where-Object, Format-Table, etc.

    .EXAMPLE
        az-Show-AzRoleAssignments | Where-Object ScopeType -eq 'subscription'
    #>
    $records = Read-AzResourcesViewTile -Tile 'roles' -Title 'Role assignments'
    Set-AzResourcesViewDisplay -TypeName $script:AzResourcesRoleRowType -Properties $script:AzResourcesRoleDisplay

    $rows = foreach ($record in $records) {
        [PSCustomObject]@{
            PSTypeName       = $script:AzResourcesRoleRowType
            Role             = [string]$record.roleName
            Principal        = [string]$record.principal
            PrincipalType    = [string]$record.principalType
            ScopeType        = [string]$record.scopeType
            ScopeName        = Get-AzResourcesScopeDisplayName -Scope ([string]$record.scope)
            Scope            = [string]$record.scope
            SubscriptionName = [string]$record.subscriptionName
            SubscriptionId   = [string]$record.subscriptionId
            PortalUrl        = [string]$record.portalUrl
        }
    }

    $sorted = $rows | Sort-Object Principal, Role, Scope
    return $sorted
}


function az-Show-AzGroupMemberships {
    <#
    .SYNOPSIS
        List the Entra groups you're a member or owner of, from the local cache.

    .DESCRIPTION
        Reads the groups tile written by az-Sync-AzResources (no network call).
        Membership is transitive (nested groups count). Rows are objects.

    .EXAMPLE
        az-Show-AzGroupMemberships | Where-Object Relationship -eq 'owner'
    #>
    $records = Read-AzResourcesViewTile -Tile 'groups' -Title 'Group memberships'
    Set-AzResourcesViewDisplay -TypeName $script:AzResourcesGroupRowType -Properties $script:AzResourcesGroupDisplay

    $rows = foreach ($record in $records) {
        [PSCustomObject]@{
            PSTypeName   = $script:AzResourcesGroupRowType
            Name         = [string]$record.displayName
            Relationship = [string]$record.relationship
            GroupType    = [string]$record.groupType
            Mail         = [string]$record.mail
            Id           = [string]$record.id
            PortalUrl    = [string]$record.portalUrl
        }
    }

    $sorted = $rows | Sort-Object Relationship, Name
    return $sorted
}


function az-Show-AzAppRegistrations {
    <#
    .SYNOPSIS
        List the app registrations and service principals you own, from the local cache.

    .DESCRIPTION
        Reads the apps tile written by az-Sync-AzResources (no network call).
        NextExpiry is the soonest secret / certificate end date (blank when no
        credential has one); the full list is on each row's CredentialList.
        For expiry warnings use az-Show-AzExpiringCredentials.

    .EXAMPLE
        az-Show-AzAppRegistrations | Sort-Object NextExpiry
    #>
    $records = Read-AzResourcesViewTile -Tile 'apps' -Title 'App registrations'
    Set-AzResourcesViewDisplay -TypeName $script:AzResourcesAppRowType -Properties $script:AzResourcesAppDisplay

    $rows = foreach ($record in $records) {
        $credentialList = @($record.credentials | Where-Object { $null -ne $_ })
        $soonest = Get-AzResourcesSoonestExpiry -Credentials $credentialList

        $nextExpiry = if ($null -ne $soonest) {
            $soonest.UtcDateTime.ToString($script:AzResourcesViewDateFormat)
        } else {
            ''
        }

        [PSCustomObject]@{
            PSTypeName     = $script:AzResourcesAppRowType
            Name           = [string]$record.displayName
            Kind           = [string]$record.kind
            Credentials    = $credentialList.Count
            NextExpiry     = $nextExpiry
            AppId          = [string]$record.appId
            ObjectId       = [string]$record.objectId
            CredentialList = $credentialList
            PortalUrl      = [string]$record.portalUrl
        }
    }

    $sorted = $rows | Sort-Object Name, Kind
    return $sorted
}


function az-Show-AzManagedIdentities {
    <#
    .SYNOPSIS
        List managed identities in subscriptions you can read, with their roles, from the local cache.

    .DESCRIPTION
        Reads the identities tile written by az-Sync-AzResources (no network
        call). RoleCount / Roles cover assignments anywhere in the tenant.

    .EXAMPLE
        az-Show-AzManagedIdentities | Where-Object RoleCount -eq 0
    #>
    $records = Read-AzResourcesViewTile -Tile 'identities' -Title 'Managed identities'
    Set-AzResourcesViewDisplay -TypeName $script:AzResourcesIdentityRowType -Properties $script:AzResourcesIdentityDisplay

    $rows = foreach ($record in $records) {
        $roleList = @($record.roles | Where-Object { $null -ne $_ })

        $roleLabels = foreach ($role in $roleList) {
            "$($role.roleName) @ $(Get-AzResourcesScopeDisplayName -Scope ([string]$role.scope))"
        }

        [PSCustomObject]@{
            PSTypeName       = $script:AzResourcesIdentityRowType
            Name             = [string]$record.name
            Type             = [string]$record.type
            ResourceGroup    = [string]$record.resourceGroup
            RoleCount        = $roleList.Count
            Roles            = (@($roleLabels) -join $script:AzResourcesViewRoleJoin)
            SubscriptionName = [string]$record.subscriptionName
            SubscriptionId   = [string]$record.subscriptionId
            PrincipalId      = [string]$record.principalId
            ResourceId       = [string]$record.resourceId
            PortalUrl        = [string]$record.portalUrl
        }
    }

    $sorted = $rows | Sort-Object SubscriptionName, ResourceGroup, Name
    return $sorted
}
