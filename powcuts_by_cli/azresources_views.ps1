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
#   az-Show-AzRoleAssignments     - RBAC roles I hold (directly or via a group)
#   az-Show-AzGroupMemberships    - Entra groups I'm a member / owner of
#   az-Show-AzAppRegistrations    - apps + service principals I own, with creds
#   az-Show-AzExpiringCredentials - secrets / certs on those apps that have
#                                   expired or expire within -WithinDays
#   az-Show-AzManagedIdentities   - managed identities and the roles they hold
#
# Each row type registers a short default display set (<= 4 columns, so the
# console renders a table); every other field stays on the object for
# `Select-Object *` or the pipeline.
#
# Which tenant: the one az is logged into (`az account show` reads the local
# az profile, no network); when az has no account, the most recently synced
# tenant cache is used instead, and the status says which tenant that is.
# The cache is per tenant, so each tile records the account that synced it;
# when az is signed in as a different account in the same tenant, the views
# say whose rows they are showing.
#
# Depends on azresources_data.ps1 and localhost_viewer.ps1; loaded by
# powcuts_home.ps1 after both.

$script:AzResourcesViewStaleSeconds = 86400   # a day: past this the status line nudges a re-sync
$script:AzResourcesViewSyncHint     = "Run 'az-Sync-AzResources' to refresh."
$script:AzResourcesViewMiddot       = "$([char]0x00B7)"   # middle dot — "12 rows · cached 3m ago"
$script:AzResourcesViewRoleJoin     = ', '
$script:AzResourcesViewRoleScopeSep = ' @ '                 # "Reader @ rg-payments"
$script:AzResourcesViewScopeRoot    = '/'

$script:AzResourcesRoleTitle     = 'Role assignments'
$script:AzResourcesGroupTitle    = 'Group memberships'
$script:AzResourcesAppTitle      = 'App registrations'
$script:AzResourcesIdentityTitle = 'Managed identities'

$script:AzResourcesRoleRowType     = 'Bashcuts.AzResources.RoleAssignment'
$script:AzResourcesGroupRowType    = 'Bashcuts.AzResources.GroupMembership'
$script:AzResourcesAppRowType      = 'Bashcuts.AzResources.AppRegistration'
$script:AzResourcesIdentityRowType = 'Bashcuts.AzResources.ManagedIdentity'

$script:AzResourcesRoleDisplay     = @('Role', 'Principal', 'ScopeType', 'ScopeName')
$script:AzResourcesGroupDisplay    = @('Name', 'Relationship', 'GroupType', 'Mail')
$script:AzResourcesAppDisplay      = @('Name', 'Kind', 'CredentialCount', 'NextExpiry')
$script:AzResourcesIdentityDisplay = @('Name', 'Type', 'ResourceGroup', 'RoleCount')

# Credential expiry. The warning window is mirrored by EXPIRY_WARN_DAYS in
# azure-viewer/app.js so the dashboard and the terminal flag the same rows.
$script:AzResourcesExpiryWarnDays     = 30
$script:AzResourcesExpiryExpired      = 'expired'
$script:AzResourcesExpiryExpiring     = 'expiring'
$script:AzResourcesExpiryOk           = 'ok'
$script:AzResourcesExpiringRowType    = 'Bashcuts.AzResources.ExpiringCredential'
$script:AzResourcesExpiringDisplay    = @('App', 'Credential', 'EndDate', 'DaysRemaining')
$script:AzResourcesCredentialKindSep  = ': '                  # "secret: ci-deploy"
$script:AzResourcesHintEllipsis       = "$([char]0x2026)"     # "abc…" — a secret's 3-char hint
$script:AzResourcesKeyIdPrefixLength  = 8                     # unnamed, hint-less credential: "keyId 1a2b3c4d"


# ---------------------------------------------------------------------------
# Cache read + status line (shared by every view)
# ---------------------------------------------------------------------------

function Get-AzResourcesViewAccount {
    # The tenant + account to show, as { TenantId; UserName; IdentityInfo;
    # IsFallback }: the one az is logged into (Get-AzResourcesLocalAccount, no
    # network); else the most recently synced tenant folder (IsFallback, no
    # account); else a blank TenantId.
    $tenantId = ''
    $userName = ''
    $identityInfo = ''

    $localAccount = Get-AzResourcesLocalAccount
    if ($null -ne $localAccount) {
        $tenantId = $localAccount.TenantId
        $userName = $localAccount.UserName
        $identityInfo = $localAccount.IdentityInfo
    }

    $isFallback = -not $tenantId

    if ($isFallback) {
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

    $viewAccount = [PSCustomObject]@{
        TenantId     = $tenantId
        UserName     = $userName
        IdentityInfo = $identityInfo
        IsFallback   = $isFallback
    }

    return $viewAccount
}


function Get-AzResourcesViewTenantId {
    # Just the tenant id Get-AzResourcesViewAccount picks — what the Resource
    # Viewer serves.
    $viewAccount = Get-AzResourcesViewAccount
    $tenantId = $viewAccount.TenantId
    return $tenantId
}


function Write-AzResourcesViewOwnerNotice {
    # Say whose rows these are when they may not be the current sign-in's: two
    # accounts in one tenant (alice / alice-adm) share the tenant's cache
    # folder, so without this the second would see the first's rows as "me".
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [PSCustomObject] $Account,
        [AllowNull()] $SyncedAs
    )

    $syncedName = if ($SyncedAs) {
        [string]$SyncedAs.userName
    } else {
        ''
    }

    $syncedIdentity = if ($SyncedAs) {
        [string]$SyncedAs.identityInfo
    } else {
        ''
    }

    if ($Account.IsFallback) {
        $who = if ($syncedName) {
            ", synced as $syncedName"
        } else {
            ''
        }

        Write-Host "${Title}: az isn't signed in - showing the cache for tenant $($Account.TenantId)$who." -ForegroundColor Yellow
        return
    }

    if (-not $SyncedAs) {
        Write-Host "${Title}: synced before account tracking - $($script:AzResourcesViewSyncHint)" -ForegroundColor DarkGray
        return
    }

    # Every managed identity reports the same placeholder user.name, so two
    # identities are told apart by assignedIdentityInfo when both sides have it.
    $isOtherName = $syncedName -and $Account.UserName -and ($syncedName -ne $Account.UserName)
    $isOtherIdentity = $syncedIdentity -and $Account.IdentityInfo -and ($syncedIdentity -ne $Account.IdentityInfo)

    if ($isOtherName -or $isOtherIdentity) {
        $self = $script:AzResourcesSelfPrincipal
        Write-Host "${Title}: cached for $syncedName $syncedIdentity, but az is signed in as $($Account.UserName) $($Account.IdentityInfo) - '$self' rows are theirs. $($script:AzResourcesViewSyncHint)" -ForegroundColor Yellow
    }
}


function Read-AzResourcesTileModel {
    # One tile's cache model ({ tile, writtenAt, ageSeconds, stale, items }) for
    # -TenantId, or $null when the file doesn't exist. Shared by the terminal
    # views and the Resource Viewer server.
    param(
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [string] $Tile
    )

    $path = Get-AzResourcesTilePath -TenantId $TenantId -Tile $Tile
    $model = Read-LocalViewerTileCache -Path $path -Tile $Tile -StaleSeconds $script:AzResourcesViewStaleSeconds
    return $model
}


function Write-AzResourcesViewMissing {
    # The "nothing to show yet" hint. -TenantId names the tenant that was
    # looked up, so "az is on tenant A but only B was synced" is obvious;
    # -Unreadable distinguishes a corrupt file from one never written.
    param(
        [Parameter(Mandatory)] [string] $Title,
        [string] $TenantId = '',
        [switch] $Unreadable
    )

    $what = if ($Unreadable) {
        'no readable cached data'
    } else {
        'no cached data yet'
    }

    $forTenant = if ($TenantId) {
        " for tenant $TenantId"
    } else {
        ''
    }

    Write-Host "${Title}: $what$forTenant. $($script:AzResourcesViewSyncHint)" -ForegroundColor Yellow
}


function Resolve-AzResourcesViewTenant {
    # -Account's tenant id, GUID-validated, or '' (after printing the
    # missing-cache hint) when there's no tenant or its id isn't a GUID.
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [PSCustomObject] $Account
    )

    $tenantId = $Account.TenantId
    if (-not $tenantId) {
        Write-AzResourcesViewMissing -Title $Title
        return ''
    }

    if (-not (Test-AzResourcesTenantId -TenantId $tenantId)) {
        Write-AzResourcesViewMissing -Title $Title -TenantId $tenantId
        return ''
    }

    return $tenantId
}


function Write-AzResourcesViewStatus {
    # "<title>: N · cached 12m ago", yellow with a re-sync nudge once stale,
    # plus any partial-permission message the sync recorded.
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [int] $Count,
        [Parameter(Mandatory)] [string] $AgeLabel,
        [Parameter(Mandatory)] [bool] $IsStale,
        [AllowEmptyString()] [string] $Message = ''
    )

    $dot = $script:AzResourcesViewMiddot
    $status = "${Title}: $Count $dot $AgeLabel"

    if ($IsStale) {
        $status = "$status $dot $($script:AzResourcesViewSyncHint)"
        $statusColor = 'Yellow'
    } else {
        $statusColor = 'DarkGray'
    }

    Write-Host $status -ForegroundColor $statusColor

    if ($Message) {
        Write-Host "  $Message" -ForegroundColor Yellow
    }
}


function Read-AzResourcesViewTile {
    # Load one tile from the cache and print its status line. Returns the
    # tile's records (possibly none). Prints a hint and returns nothing when the
    # cache is missing or unreadable, and a one-line notice when the tile is
    # notPermitted.
    param(
        [Parameter(Mandatory)] [string] $Tile,
        [Parameter(Mandatory)] [string] $Title
    )

    $account = Get-AzResourcesViewAccount

    $tenantId = Resolve-AzResourcesViewTenant -Title $Title -Account $account
    if (-not $tenantId) {
        return
    }

    $model = Read-AzResourcesTileModel -TenantId $tenantId -Tile $Tile
    if ($null -eq $model) {
        Write-AzResourcesViewMissing -Title $Title
        return
    }

    if ($null -eq $model.items) {
        Write-AzResourcesViewMissing -Title $Title -Unreadable
        return
    }

    $cachedAt = (Get-Date).AddSeconds(-$model.ageSeconds)
    $relative = Get-LocalViewerRelativeTime -When $cachedAt
    $ageLabel = "cached $relative"
    $items = $model.items

    Write-AzResourcesViewOwnerNotice -Title $Title -Account $account -SyncedAs $items.syncedAs

    if ($items.state -eq $script:AzResourcesStateNotPermitted) {
        Write-Host "${Title}: not permitted $($script:AzResourcesViewMiddot) $($items.message) ($ageLabel)" -ForegroundColor Yellow
        return
    }

    $records = @($items.records | Where-Object { $null -ne $_ })

    Write-AzResourcesViewStatus -Title $Title -Count $records.Count -AgeLabel $ageLabel `
        -IsStale ([bool]$model.stale) -Message ([string]$items.message)

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


function Get-AzResourcesCredentialExpiry {
    # { NextExpiry; ExpiredCount } across an app's credentials. NextExpiry is the
    # earliest end date still in the future ($null when none), so an old,
    # already-expired secret left on the app doesn't mask the one about to lapse;
    # those are counted in ExpiredCount instead.
    param([AllowNull()] $Credentials)

    $now = [datetimeoffset]::UtcNow
    $soonest = $null
    $expiredCount = 0

    foreach ($credential in $Credentials) {
        $end = ConvertTo-AzResourcesDateTimeOffset -Value $credential.endDateTime

        if ($null -eq $end) {
            continue
        }

        if ($end -lt $now) {
            $expiredCount++
        } elseif ($null -eq $soonest -or $end -lt $soonest) {
            $soonest = $end
        }
    }

    $expiry = [PSCustomObject]@{
        NextExpiry   = $soonest
        ExpiredCount = $expiredCount
    }

    return $expiry
}


function Get-AzResourcesCredentialStatus {
    # 'expired' once -End has passed, 'expiring' when it falls within
    # -WithinDays of -Now, else 'ok'. A credential with no end date never
    # lapses, so it is 'ok' rather than an error.
    param(
        [AllowNull()] $End,
        [Parameter(Mandatory)] [int] $WithinDays,
        [Parameter(Mandatory)] [datetimeoffset] $Now
    )

    if ($null -eq $End) {
        return $script:AzResourcesExpiryOk
    }

    if ($End -lt $Now) {
        return $script:AzResourcesExpiryExpired
    }

    if ($End -le $Now.AddDays($WithinDays)) {
        return $script:AzResourcesExpiryExpiring
    }

    return $script:AzResourcesExpiryOk
}


function Get-AzResourcesCredentialLabel {
    # A human label for one credential: its display name, else the secret's
    # hint ("abc…"), else a short keyId prefix — never blank.
    param([Parameter(Mandatory)] $Credential)

    $name = [string]$Credential.name
    if ($name) {
        return $name
    }

    $hint = [string]$Credential.hint
    if ($hint) {
        $hinted = "$hint$($script:AzResourcesHintEllipsis)"
        return $hinted
    }

    $keyId = [string]$Credential.keyId
    $prefixLength = [math]::Min($script:AzResourcesKeyIdPrefixLength, $keyId.Length)
    $keyLabel = "keyId $($keyId.Substring(0, $prefixLength))"
    return $keyLabel
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
    $records = Read-AzResourcesViewTile -Tile $script:AzResourcesTileRoles -Title $script:AzResourcesRoleTitle
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
    $records = Read-AzResourcesViewTile -Tile $script:AzResourcesTileGroups -Title $script:AzResourcesGroupTitle
    Set-AzResourcesViewDisplay -TypeName $script:AzResourcesGroupRowType -Properties $script:AzResourcesGroupDisplay

    $rows = foreach ($record in $records) {
        [PSCustomObject]@{
            PSTypeName   = $script:AzResourcesGroupRowType
            Name         = [string]$record.displayName
            Relationship = [string]$record.relationship
            GroupType    = [string]$record.groupType
            Mail         = [string]$record.mail
            IsDynamic    = [bool]$record.isDynamic
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
        NextExpiry is the soonest secret / certificate end date still in the
        future, as a [datetimeoffset] ($null when none); ExpiredCount counts
        credentials already past their end date. The full list (with start
        date, and usage / key type for certificates) is on each row's
        CredentialList.

    .EXAMPLE
        az-Show-AzAppRegistrations | Sort-Object NextExpiry
    #>
    $records = Read-AzResourcesViewTile -Tile $script:AzResourcesTileApps -Title $script:AzResourcesAppTitle
    Set-AzResourcesViewDisplay -TypeName $script:AzResourcesAppRowType -Properties $script:AzResourcesAppDisplay

    $rows = foreach ($record in $records) {
        $credentialList = @($record.credentials | Where-Object { $null -ne $_ })
        $expiry = Get-AzResourcesCredentialExpiry -Credentials $credentialList

        [PSCustomObject]@{
            PSTypeName      = $script:AzResourcesAppRowType
            Name            = [string]$record.displayName
            Kind            = [string]$record.kind
            CredentialCount = $credentialList.Count
            NextExpiry      = $expiry.NextExpiry
            ExpiredCount    = $expiry.ExpiredCount
            AppId           = [string]$record.appId
            ObjectId        = [string]$record.objectId
            CredentialList  = $credentialList
            PortalUrl       = [string]$record.portalUrl
        }
    }

    $sorted = $rows | Sort-Object Name, Kind
    return $sorted
}


function az-Show-AzExpiringCredentials {
    <#
    .SYNOPSIS
        List expired and soon-to-expire secrets / certificates on apps you own, from the local cache.

    .DESCRIPTION
        Reads the apps tile written by az-Sync-AzResources (no network call)
        and emits one row per credential that has already expired or expires
        within -WithinDays (default 30), soonest first — so expired ones lead.
        DaysRemaining is negative once a credential has expired. Credentials
        with no end date never expire and are never listed.

    .PARAMETER WithinDays
        Warning window in days. 0 lists only credentials already expired.

    .EXAMPLE
        az-Show-AzExpiringCredentials

    .EXAMPLE
        az-Show-AzExpiringCredentials -WithinDays 90 | Where-Object CredentialKind -eq 'certificate'
    #>
    param(
        [ValidateRange(0, 3650)]   # attribute args must be literals; 3650 = ten years
        [int] $WithinDays = $script:AzResourcesExpiryWarnDays
    )

    $records = Read-AzResourcesViewTile -Tile $script:AzResourcesTileApps -Title $script:AzResourcesAppTitle
    Set-AzResourcesViewDisplay -TypeName $script:AzResourcesExpiringRowType -Properties $script:AzResourcesExpiringDisplay

    $now = [datetimeoffset]::UtcNow
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($record in $records) {
        $credentialList = @($record.credentials | Where-Object { $null -ne $_ })

        foreach ($credential in $credentialList) {
            $end = ConvertTo-AzResourcesDateTimeOffset -Value $credential.endDateTime
            $status = Get-AzResourcesCredentialStatus -End $end -WithinDays $WithinDays -Now $now

            if ($status -eq $script:AzResourcesExpiryOk) {
                continue
            }

            $kind = [string]$credential.kind
            $label = Get-AzResourcesCredentialLabel -Credential $credential
            $daysRemaining = [int][math]::Floor(($end - $now).TotalDays)

            $rows.Add([PSCustomObject]@{
                PSTypeName     = $script:AzResourcesExpiringRowType
                App            = [string]$record.displayName
                Credential     = "$kind$($script:AzResourcesCredentialKindSep)$label"
                EndDate        = $end
                DaysRemaining  = $daysRemaining
                Status         = $status
                CredentialKind = $kind
                CredentialName = [string]$credential.name
                Hint           = [string]$credential.hint
                KeyId          = [string]$credential.keyId
                AppKind        = [string]$record.kind
                AppId          = [string]$record.appId
                PortalUrl      = [string]$record.portalUrl
            })
        }
    }

    $sorted = $rows | Sort-Object EndDate, App
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
    $records = Read-AzResourcesViewTile -Tile $script:AzResourcesTileIdentities -Title $script:AzResourcesIdentityTitle
    Set-AzResourcesViewDisplay -TypeName $script:AzResourcesIdentityRowType -Properties $script:AzResourcesIdentityDisplay

    $rows = foreach ($record in $records) {
        $roleList = @($record.roles | Where-Object { $null -ne $_ })

        $roleLabels = foreach ($role in $roleList) {
            $scopeName = Get-AzResourcesScopeDisplayName -Scope ([string]$role.scope)
            "$($role.roleName)$($script:AzResourcesViewRoleScopeSep)$scopeName"
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
