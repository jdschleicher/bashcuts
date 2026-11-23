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
#
# Cache layout (tenant-scoped, NOT keyed by the AzDevOps project slug):
#   $HOME/.bashcuts-az-resources-app/cache/<tenantId>/<tile>.json
#
# Each file is the shared localhost-viewer tile record (Write-LocalViewerTileCache):
#   { tile, writtenAt, items: { state, message, records[] } }
# state is 'ok' or 'notPermitted' (the tenant blocked the call for this user).
# A tile that fails for any other reason keeps its previous cache file.
#
# SECURITY: records are built from explicit field allow-lists — never by
# copying raw az output — so no secret text, token, or key material can reach
# the cache. az's own login stays in the az CLI's token store.
#
# Public functions:
#   az-Sync-AzResources [-Tile <name>]  - refresh every tile, or just one
#
# Depends on Invoke-AzDevOpsAzJson (azdevops_db.ps1) and
# Write-LocalViewerTileCache (localhost_viewer.ps1); loaded by powcuts_home.ps1
# after both.

$script:AzResourcesAppDirName  = '.bashcuts-az-resources-app'
$script:AzResourcesCacheSubdir = 'cache'
$script:AzResourcesTileNames   = @('roles', 'groups', 'apps', 'identities')
$script:AzResourcesJsonDepth   = 10

$script:AzResourcesStateOk           = 'ok'
$script:AzResourcesStateNotPermitted = 'notPermitted'

# stderr markers az / ARM / Graph emit when the signed-in user lacks rights.
$script:AzResourcesPermissionPattern = 'AuthorizationFailed|Authorization_RequestDenied|Insufficient privileges|Forbidden|\b403\b'

$script:AzResourcesSelfPrincipal     = 'me'
$script:AzResourcesUserAccountType   = 'user'
$script:AzResourcesEnabledSubState   = 'Enabled'

$script:AzResourcesGraphBaseUrl      = 'https://graph.microsoft.com/v1.0'
$script:AzResourcesGraphPageSize     = 999
$script:AzResourcesGraphGroupType    = '#microsoft.graph.group'
$script:AzResourcesGraphGroupSelect  = 'id,displayName,mail,groupTypes,securityEnabled,mailEnabled'
$script:AzResourcesGraphNextLinkKey  = '@odata.nextLink'
$script:AzResourcesGraphTypeKey      = '@odata.type'

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

$script:AzResourcesScopeManagementGroup = 'managementGroup'
$script:AzResourcesScopeRoot            = 'root'
$script:AzResourcesScopeSubscription    = 'subscription'
$script:AzResourcesScopeResourceGroup   = 'resourceGroup'
$script:AzResourcesScopeResource        = 'resource'
$script:AzResourcesManagementGroupScopePattern = '^/providers/Microsoft\.Management/managementGroups/'
$script:AzResourcesResourceGroupSegment = 'resourceGroups'

# Portal deep links. 'resource' covers subscriptions, resource groups, and
# resources (the portal resolves any ARM id under /resource); the Entra
# objects use their dedicated blades.
$script:AzResourcesPortalBaseUrl          = 'https://portal.azure.com/#'
$script:AzResourcesPortalGroupBlade       = 'view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Overview/groupId/'
$script:AzResourcesPortalAppBlade         = 'view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Overview/appId/'
$script:AzResourcesPortalEnterpriseBlade  = 'view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Overview/objectId/'


# ---------------------------------------------------------------------------
# Cache layout
# ---------------------------------------------------------------------------

function Get-AzResourcesCacheDir {
    param([Parameter(Mandatory)] [string] $TenantId)

    $appRoot = Join-Path $HOME $script:AzResourcesAppDirName
    $cacheRoot = Join-Path $appRoot $script:AzResourcesCacheSubdir
    $dir = Join-Path $cacheRoot $TenantId
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


# ---------------------------------------------------------------------------
# az plumbing
# ---------------------------------------------------------------------------

function Get-AzResourcesErrorSummary {
    # First non-blank stderr line — az errors are often multi-line tracebacks,
    # and the console summary only needs the headline.
    param([AllowNull()] [AllowEmptyString()] [string] $ErrorText)

    $lines = @(([string]$ErrorText) -split "`r?`n" | Where-Object { $_.Trim() })

    $summary = if ($lines.Count -gt 0) {
        $lines[0].Trim()
    } else {
        'az returned a non-zero exit code with no error text.'
    }

    return $summary
}


function Invoke-AzResourcesAz {
    # Run one az call through the shared Invoke-AzDevOpsAzJson envelope (spinner,
    # separate stderr, exit code) and parse its JSON. NotPermitted is true when
    # the call failed with an authorization / insufficient-privileges error, so
    # fetchers can degrade that tile instead of failing it.
    param([Parameter(Mandatory)] [string[]] $ArgList)

    $envelope = Invoke-AzDevOpsAzJson -ArgList $ArgList

    $isOk = ($envelope.ExitCode -eq 0)
    $isNotPermitted = (-not $isOk) -and ([string]$envelope.Error -match $script:AzResourcesPermissionPattern)

    $data = $null
    if ($isOk -and $envelope.Json) {
        $data = ($envelope.Json -join "`n") | ConvertFrom-Json
    }

    $result = [PSCustomObject]@{
        Ok           = $isOk
        NotPermitted = $isNotPermitted
        Data         = $data
        Error        = Get-AzResourcesErrorSummary -ErrorText $envelope.Error
    }

    return $result
}


function Assert-AzResourcesCallOk {
    # Shared failure gate for fetchers: a permission denial is left to the
    # caller (it counts it), anything else is a hard failure for this tile.
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Result,
        [Parameter(Mandatory)] [string] $What
    )

    if (-not $Result.Ok -and -not $Result.NotPermitted) {
        throw "$What failed: $($Result.Error)"
    }
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
    $userType = [string]$account.Data.user.type

    $objectArgs = if ($userType -eq $script:AzResourcesUserAccountType) {
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


function Get-AzResourcesGraphCollection {
    # GET a Graph collection through `az rest`, following @odata.nextLink. Query
    # options travel via --url-parameters (never an '&' inside --url) because
    # az.cmd on Windows hands the URL to cmd.exe, which would split it at '&'.
    # Returns { NotPermitted, Items }.
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Select
    )

    $items = New-Object System.Collections.Generic.List[object]

    $url = "$($script:AzResourcesGraphBaseUrl)/$Path"
    $urlParameters = @("`$select=$Select", "`$top=$($script:AzResourcesGraphPageSize)")

    while ($url) {
        $argList = @('rest', '--method', 'get', '--url', $url)
        if ($urlParameters.Count -gt 0) {
            $argList += '--url-parameters'
            $argList += $urlParameters
        }

        $result = Invoke-AzResourcesAz -ArgList $argList
        Assert-AzResourcesCallOk -Result $result -What "Graph GET $Path"

        if ($result.NotPermitted) {
            $denied = [PSCustomObject]@{ NotPermitted = $true; Items = $items }
            return $denied
        }

        foreach ($raw in $result.Data.value) {
            if ($null -ne $raw) {
                $items.Add($raw)
            }
        }

        $nextLink = [string]$result.Data.$($script:AzResourcesGraphNextLinkKey)

        if ($nextLink) {
            $parts = $nextLink -split '\?', 2
            $url = $parts[0]

            $urlParameters = @()
            if ($parts.Count -gt 1) {
                foreach ($pair in ($parts[1] -split '&')) {
                    $keyValue = $pair -split '=', 2
                    $key   = [uri]::UnescapeDataString($keyValue[0])
                    $value = if ($keyValue.Count -gt 1) {
                        [uri]::UnescapeDataString($keyValue[1])
                    } else {
                        ''
                    }

                    $urlParameters += "$key=$value"
                }
            }
        } else {
            $url = $null
        }
    }

    $collection = [PSCustomObject]@{ NotPermitted = $false; Items = $items }
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


function Get-AzResourcesDeniedTileResult {
    # Shared "how did the calls go" verdict for multi-call tiles: if every call
    # was denied the whole tile is notPermitted; if only some were, keep what we
    # got and say so in the message.
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]] $Records,
        [Parameter(Mandatory)] [int] $AllowedCalls,
        [Parameter(Mandatory)] [int] $DeniedCalls,
        [Parameter(Mandatory)] [string] $DeniedLabel
    )

    $state = $script:AzResourcesStateOk
    $message = ''

    if ($DeniedCalls -gt 0 -and $AllowedCalls -eq 0) {
        $state = $script:AzResourcesStateNotPermitted
        $message = "Your account is not permitted to read $DeniedLabel in this tenant."
    } elseif ($DeniedCalls -gt 0) {
        $message = "Partial: $DeniedCalls of $($AllowedCalls + $DeniedCalls) $DeniedLabel call(s) were not permitted."
    }

    $tileResult = New-AzResourcesTileResult -State $state -Records $Records -Message $message
    return $tileResult
}


function Get-AzResourcesPortalUrl {
    # The ONE deep-link builder every tile uses, so a portal URL shape changes in
    # one place.
    param(
        [Parameter(Mandatory)]
        [ValidateSet('resource', 'group', 'appRegistration', 'servicePrincipal')]
        [string] $Kind,

        [Parameter(Mandatory)] [string] $TenantId,
        [string] $ResourceId = '',
        [string] $ObjectId = '',
        [string] $AppId = ''
    )

    $base = $script:AzResourcesPortalBaseUrl

    switch ($Kind) {
        'resource' {
            $url = "$($base)@$TenantId/resource$ResourceId"
        }

        'group' {
            $url = "$base$($script:AzResourcesPortalGroupBlade)$ObjectId"
        }

        'appRegistration' {
            $url = "$base$($script:AzResourcesPortalAppBlade)$AppId"
        }

        'servicePrincipal' {
            $url = "$base$($script:AzResourcesPortalEnterpriseBlade)$ObjectId/appId/$AppId"
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

            $endDateTime = if ($cred.endDateTime) {
                [string]$cred.endDateTime
            } else {
                [string]$cred.endDate
            }

            $credentials.Add([ordered]@{
                kind        = $source.Kind
                name        = [string]$cred.displayName
                keyId       = [string]$cred.keyId
                endDateTime = $endDateTime
            })
        }
    }

    # Unary comma so 0 or 1 credentials still serialize as a JSON array.
    return ,$credentials
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
    $seenIds = New-Object System.Collections.Generic.HashSet[string]
    $allowed = 0
    $denied = 0

    foreach ($sub in $Subscriptions) {
        $argList = @(
            'role', 'assignment', 'list',
            '--assignee', $Context.Assignee,
            '--include-groups', '--all',
            '--subscription', $sub.Id
        )

        $result = Invoke-AzResourcesAz -ArgList $argList
        Assert-AzResourcesCallOk -Result $result -What "role assignment list ($($sub.Name))"

        if ($result.NotPermitted) {
            $denied++
            continue
        }

        $allowed++

        foreach ($raw in $result.Data) {
            if ($null -eq $raw -or -not $seenIds.Add([string]$raw.id)) {
                continue
            }

            $isMine = if ($Context.ObjectId) {
                $raw.principalId -eq $Context.ObjectId
            } else {
                $raw.principalName -eq $Context.UserName
            }

            $principal = if ($isMine) {
                $script:AzResourcesSelfPrincipal
            } else {
                [string]$raw.principalName
            }

            $scope = [string]$raw.scope

            $records.Add([ordered]@{
                id               = [string]$raw.id
                roleName         = [string]$raw.roleDefinitionName
                scope            = $scope
                scopeType        = Get-AzResourcesScopeType -Scope $scope
                principal        = $principal
                principalType    = [string]$raw.principalType
                subscriptionId   = $sub.Id
                subscriptionName = $sub.Name
                portalUrl        = Get-AzResourcesPortalUrl -Kind 'resource' -TenantId $Context.TenantId -ResourceId $scope
            })
        }
    }

    $tileResult = Get-AzResourcesDeniedTileResult -Records $records -AllowedCalls $allowed -DeniedCalls $denied -DeniedLabel 'role assignments'
    return $tileResult
}


function Get-AzResourcesGroupTile {
    # Groups I belong to (transitively — nested membership is what grants roles)
    # plus groups I own. The collections are directory objects of mixed types,
    # so non-groups are filtered by @odata.type rather than an OData cast, which
    # some tenants only allow with advanced-query headers.
    param([Parameter(Mandatory)] [PSCustomObject] $Context)

    $records = New-Object System.Collections.Generic.List[object]
    $allowed = 0
    $denied = 0

    $sources = @(
        @{ Path = 'me/transitiveMemberOf'; Relationship = $script:AzResourcesRelationshipMember }
        @{ Path = 'me/ownedObjects';       Relationship = $script:AzResourcesRelationshipOwner }
    )

    foreach ($source in $sources) {
        $collection = Get-AzResourcesGraphCollection -Path $source.Path -Select $script:AzResourcesGraphGroupSelect

        if ($collection.NotPermitted) {
            $denied++
            continue
        }

        $allowed++

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

    $tileResult = Get-AzResourcesDeniedTileResult -Records $records -AllowedCalls $allowed -DeniedCalls $denied -DeniedLabel 'group memberships'
    return $tileResult
}


function Get-AzResourcesAppTile {
    # App registrations and service principals (enterprise apps) I own, each
    # with its secrets / certificates and their expiry dates.
    param([Parameter(Mandatory)] [PSCustomObject] $Context)

    $records = New-Object System.Collections.Generic.List[object]
    $allowed = 0
    $denied = 0

    $sources = @(
        @{ ArgList = @('ad', 'app', 'list', '--show-mine'); Kind = $script:AzResourcesKindAppRegistration }
        @{ ArgList = @('ad', 'sp', 'list', '--show-mine');  Kind = $script:AzResourcesKindServicePrincipal }
    )

    foreach ($source in $sources) {
        $result = Invoke-AzResourcesAz -ArgList $source.ArgList
        Assert-AzResourcesCallOk -Result $result -What ($source.ArgList -join ' ')

        if ($result.NotPermitted) {
            $denied++
            continue
        }

        $allowed++

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

    $tileResult = Get-AzResourcesDeniedTileResult -Records $records -AllowedCalls $allowed -DeniedCalls $denied -DeniedLabel 'owned applications'
    return $tileResult
}


function Get-AzResourcesRoleIndex {
    # principalId -> roles that principal holds in one subscription, from a
    # single `role assignment list --all` instead of one call per identity.
    # Returns $null when the read is denied (identities still list, roleless).
    param([Parameter(Mandatory)] [PSCustomObject] $Subscription)

    $argList = @('role', 'assignment', 'list', '--all', '--subscription', $Subscription.Id)

    $result = Invoke-AzResourcesAz -ArgList $argList
    Assert-AzResourcesCallOk -Result $result -What "role assignment list --all ($($Subscription.Name))"

    if ($result.NotPermitted) {
        return $null
    }

    $index = @{}

    foreach ($raw in $result.Data) {
        if ($null -eq $raw -or -not $raw.principalId) {
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

    return $index
}


function New-AzResourcesIdentityRecord {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $IdentityType,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $ResourceId,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $ResourceGroup,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $PrincipalId,
        [Parameter(Mandatory)] [PSCustomObject] $Subscription,
        [Parameter(Mandatory)] [AllowNull()] [hashtable] $RoleIndex,
        [Parameter(Mandatory)] [string] $TenantId
    )

    # Plain assignments, not `$roles = if (...) { ... }` — an if-expression
    # unrolls the List, so 0 or 1 roles would stop serializing as an array.
    $roles = New-Object System.Collections.Generic.List[object]

    if ($null -ne $RoleIndex -and $PrincipalId -and $RoleIndex.ContainsKey($PrincipalId)) {
        $roles = $RoleIndex[$PrincipalId]
    }

    $record = [ordered]@{
        name             = $Name
        type             = $IdentityType
        resourceId       = $ResourceId
        resourceGroup    = $ResourceGroup
        subscriptionId   = $Subscription.Id
        subscriptionName = $Subscription.Name
        principalId      = $PrincipalId
        roles            = $roles
        portalUrl        = Get-AzResourcesPortalUrl -Kind 'resource' -TenantId $TenantId -ResourceId $ResourceId
    }

    return $record
}


function Get-AzResourcesIdentityTile {
    # Every managed identity in every subscription I can read: user-assigned
    # from `az identity list`, system-assigned from the identity block on each
    # resource in `az resource list`. Roles come from one per-subscription
    # role index rather than a call per identity.
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Context,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]] $Subscriptions
    )

    $records = New-Object System.Collections.Generic.List[object]
    $allowed = 0
    $denied = 0

    foreach ($sub in $Subscriptions) {
        $roleIndex = Get-AzResourcesRoleIndex -Subscription $sub

        $userAssigned = Invoke-AzResourcesAz -ArgList @('identity', 'list', '--subscription', $sub.Id)
        Assert-AzResourcesCallOk -Result $userAssigned -What "identity list ($($sub.Name))"

        if ($userAssigned.NotPermitted) {
            $denied++
        } else {
            $allowed++

            foreach ($raw in $userAssigned.Data) {
                if ($null -eq $raw) {
                    continue
                }

                $records.Add((New-AzResourcesIdentityRecord -Name ([string]$raw.name) `
                    -IdentityType $script:AzResourcesIdentityUserAssigned -ResourceId ([string]$raw.id) `
                    -ResourceGroup ([string]$raw.resourceGroup) -PrincipalId ([string]$raw.principalId) `
                    -Subscription $sub -RoleIndex $roleIndex -TenantId $Context.TenantId))
            }
        }

        $resources = Invoke-AzResourcesAz -ArgList @('resource', 'list', '--subscription', $sub.Id)
        Assert-AzResourcesCallOk -Result $resources -What "resource list ($($sub.Name))"

        if ($resources.NotPermitted) {
            $denied++
        } else {
            $allowed++

            foreach ($raw in $resources.Data) {
                $hasSystemIdentity = ($null -ne $raw) -and ([string]$raw.identity.type -match $script:AzResourcesSystemAssignedMarker)
                if (-not $hasSystemIdentity) {
                    continue
                }

                $records.Add((New-AzResourcesIdentityRecord -Name ([string]$raw.name) `
                    -IdentityType $script:AzResourcesIdentitySystemAssigned -ResourceId ([string]$raw.id) `
                    -ResourceGroup ([string]$raw.resourceGroup) -PrincipalId ([string]$raw.identity.principalId) `
                    -Subscription $sub -RoleIndex $roleIndex -TenantId $Context.TenantId))
            }
        }
    }

    $tileResult = Get-AzResourcesDeniedTileResult -Records $records -AllowedCalls $allowed -DeniedCalls $denied -DeniedLabel 'managed identities'
    return $tileResult
}


function Invoke-AzResourcesTileFetch {
    param(
        [Parameter(Mandatory)] [string] $Tile,
        [Parameter(Mandatory)] [PSCustomObject] $Context,
        [AllowNull()] [System.Collections.Generic.List[object]] $Subscriptions
    )

    $needsSubscriptions = ($Tile -eq 'roles' -or $Tile -eq 'identities')
    if ($needsSubscriptions -and $null -eq $Subscriptions) {
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
        [ValidateSet('roles', 'groups', 'apps', 'identities')]
        [string] $Tile
    )

    $context = Get-AzResourcesAccountContext
    if ($null -eq $context) {
        Write-Host "Not logged in to Azure. Run 'az login' and try again." -ForegroundColor Yellow
        return
    }

    $tiles = if ($Tile) {
        @($Tile)
    } else {
        $script:AzResourcesTileNames
    }

    $subscriptions = $null
    $needsSubscriptions = ($tiles -contains 'roles') -or ($tiles -contains 'identities')

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
