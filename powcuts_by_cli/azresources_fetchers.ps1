# ============================================================================
# Azure Resources — Per-tile fetchers (the EXPENSIVE seam)
# ============================================================================
# One fetcher per tile. Each runs its az calls through Invoke-AzResourcesAzQuery
# and returns a New-AzResourcesTileResult whose Items are normalized records
# (a fixed whitelist of fields — never the raw az payload) that each carry a
# portalUrl from Get-AzResourcesPortalUrl.
#
# Failure handling per az call:
#   - 403 / insufficient privileges -> counted as "denied"
#   - any other failure             -> counted as "errored"
# A tile is 'ok' when at least one of its calls succeeded (skipped pieces are
# listed in Warnings), 'notPermitted' when every failing call was a denial, and
# 'error' otherwise — az-Sync-AzResources leaves an errored tile's previous
# cache file untouched.
#
# Loaded by powcuts_home.ps1. See azresources_paths.ps1 for the cache layout.

$script:AzResourcesGraphBase = 'https://graph.microsoft.com/v1.0'
$script:AzResourcesGraphPageSize = 999   # Graph's max $top for memberOf / ownedObjects
$script:AzResourcesGraphGroupType = '#microsoft.graph.group'
$script:AzResourcesGroupSelect = 'id,displayName,mail,groupTypes,securityEnabled,mailEnabled'
$script:AzResourcesUnifiedGroupMarker = 'Unified'
$script:AzResourcesSystemAssignedMarker = 'SystemAssigned'
$script:AzResourcesUserAccountType = 'user'
$script:AzResourcesSubscriptionEnabled = 'Enabled'

$script:AzResourcesPermissionDeniedPattern = 'Authorization_RequestDenied|Insufficient privileges|AuthorizationFailed|Forbidden|\b403\b'


function Test-AzResourcesPermissionDenied {
    param([string] $Stderr)

    if (-not $Stderr) {
        return $false
    }

    $isDenied = $Stderr -match $script:AzResourcesPermissionDeniedPattern
    return $isDenied
}


function Invoke-AzResourcesAzQuery {
    # Runs one az call through the shared Invoke-AzDevOpsAzJson wrapper (stderr
    # capture, spinner, command echo) and classifies the outcome. Returns
    # { State = ok|notPermitted|error; Data = parsed JSON; Message }.
    param([Parameter(Mandatory)] [string[]] $ArgList)

    $result = Invoke-AzDevOpsAzJson -ArgList $ArgList

    if ($result.ExitCode -ne 0) {
        $firstLine = Get-AzDevOpsFirstStderrLine -Stderr $result.Error

        if (-not $firstLine) {
            $firstLine = "az exited with code $($result.ExitCode)"
        }

        $state = if (Test-AzResourcesPermissionDenied -Stderr $result.Error) {
            $script:AzResourcesStateNotPermitted
        } else {
            $script:AzResourcesStateError
        }

        $failed = [PSCustomObject]@{
            State   = $state
            Data    = $null
            Message = $firstLine
        }

        return $failed
    }

    $text = $result.Json -join "`n"

    try {
        $parsed = if ($text.Trim()) {
            $text | ConvertFrom-Json
        } else {
            $null
        }
    }
    catch {
        $parseFailed = [PSCustomObject]@{
            State   = $script:AzResourcesStateError
            Data    = $null
            Message = "parse failed: $($_.Exception.Message)"
        }

        return $parseFailed
    }

    $ok = [PSCustomObject]@{
        State   = $script:AzResourcesStateOk
        Data    = $parsed
        Message = ''
    }

    return $ok
}


function New-AzResourcesCallTally {
    # Running count of a tile's az call outcomes, folded into the tile's final
    # state by Resolve-AzResourcesTileResult.
    $tally = [PSCustomObject]@{
        Succeeded    = 0
        Denied       = 0
        Errored      = 0
        FirstMessage = ''
        Warnings     = New-Object System.Collections.Generic.List[string]
    }

    return $tally
}


function Add-AzResourcesCallOutcome {
    # Record one az call's outcome. Returns $true when the call succeeded, so
    # the caller can `if (Add-AzResourcesCallOutcome ...) { use $query.Data }`.
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Tally,
        [Parameter(Mandatory)] [PSCustomObject] $Query,
        [Parameter(Mandatory)] [string]         $What
    )

    if ($Query.State -eq $script:AzResourcesStateOk) {
        $Tally.Succeeded++
        return $true
    }

    if ($Query.State -eq $script:AzResourcesStateNotPermitted) {
        $Tally.Denied++
        $Tally.Warnings.Add("$What - not permitted")
    } else {
        $Tally.Errored++
        $Tally.Warnings.Add("$What - $($Query.Message)")
    }

    if (-not $Tally.FirstMessage) {
        $Tally.FirstMessage = "$What - $($Query.Message)"
    }

    return $false
}


function Resolve-AzResourcesTileResult {
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Tally,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Items
    )

    $anyFailed = ($Tally.Denied + $Tally.Errored) -gt 0

    $state = if ($Tally.Succeeded -gt 0 -or -not $anyFailed) {
        $script:AzResourcesStateOk
    } elseif ($Tally.Errored -eq 0) {
        $script:AzResourcesStateNotPermitted
    } else {
        $script:AzResourcesStateError
    }

    $message = if ($state -eq $script:AzResourcesStateOk) {
        ''
    } else {
        $Tally.FirstMessage
    }

    $result = New-AzResourcesTileResult -State $state -Items $Items -Warnings $Tally.Warnings -Message $message
    return $result
}


# ---------------------------------------------------------------------------
# Sign-in context — fetched once per sync and handed to every fetcher
# ---------------------------------------------------------------------------

function Get-AzResourcesContext {
    # Returns { TenantId, UserName, UserType, ObjectId, Subscriptions,
    # SubscriptionsQuery }, or $null
    # after printing one clear `az login` message when az isn't on PATH or no
    # account is signed in. `az account show` is a session call, so (like
    # azdevops_auth.ps1) it runs directly rather than through the data wrapper.
    param([Parameter(Mandatory)] [string] $CommandName)

    $loginHint = "$CommandName aborted - not logged in to Azure. Run 'az login', then retry."

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Host "$CommandName aborted - az CLI not found on PATH. Install it, run 'az login', then retry." -ForegroundColor Red
        return $null
    }

    $accountJson = & az account show --output json 2>$null

    if ($LASTEXITCODE -ne 0 -or -not $accountJson) {
        Write-Host $loginHint -ForegroundColor Red
        return $null
    }

    try {
        $account = ($accountJson -join "`n") | ConvertFrom-Json
    }
    catch {
        Write-Host $loginHint -ForegroundColor Red
        return $null
    }

    $tenantId = [string]$account.tenantId

    if ($tenantId -notmatch $script:AzResourcesGuidPattern) {
        Write-Host $loginHint -ForegroundColor Red
        return $null
    }

    $subscriptions = New-Object System.Collections.Generic.List[object]
    $subsQuery = Invoke-AzResourcesAzQuery -ArgList @('account', 'list')

    if ($subsQuery.State -eq $script:AzResourcesStateOk) {
        foreach ($sub in @($subsQuery.Data)) {
            $inTenant = $sub.tenantId -eq $tenantId
            $enabled  = $sub.state -eq $script:AzResourcesSubscriptionEnabled

            if ($inTenant -and $enabled) {
                $subscriptions.Add([PSCustomObject]@{
                    Id   = [string]$sub.id
                    Name = [string]$sub.name
                })
            }
        }
    }

    $userType = [string]$account.user.type
    $objectId = $null

    if ($userType -eq $script:AzResourcesUserAccountType) {
        $meQuery = Invoke-AzResourcesAzQuery -ArgList @('ad', 'signed-in-user', 'show')

        if ($meQuery.State -eq $script:AzResourcesStateOk) {
            $objectId = [string]$meQuery.Data.id
        }
    }

    $context = [PSCustomObject]@{
        TenantId      = $tenantId
        UserName           = [string]$account.user.name
        UserType           = $userType
        ObjectId           = $objectId
        Subscriptions      = $subscriptions
        SubscriptionsQuery = $subsQuery
    }

    return $context
}


# ---------------------------------------------------------------------------
# roles — RBAC role assignments I hold, directly or through a group
# ---------------------------------------------------------------------------

function Get-AzResourcesScopeType {
    param([Parameter(Mandatory)] [string] $Scope)

    $scopeType = switch -Regex ($Scope) {
        '^/$' {
            'root'
        }

        '^/providers/Microsoft\.Management/managementGroups/[^/]+$' {
            'managementGroup'
        }

        '^/subscriptions/[^/]+$' {
            'subscription'
        }

        '^/subscriptions/[^/]+/resourceGroups/[^/]+$' {
            'resourceGroup'
        }

        default {
            'resource'
        }
    }

    return $scopeType
}


function New-AzResourcesSubscriptionTally {
    # Tally for a tile that fans out across subscriptions. A failed
    # `az account list` is folded in up front, so an empty subscription list
    # reads as that failure rather than as "nothing found".
    param([Parameter(Mandatory)] [PSCustomObject] $Context)

    $tally = New-AzResourcesCallTally
    $query = $Context.SubscriptionsQuery

    if ($query.State -ne $script:AzResourcesStateOk) {
        $null = Add-AzResourcesCallOutcome -Tally $tally -Query $query -What 'az account list'
    }

    return $tally
}


function Test-AzResourcesIsMe {
    # Whether a role assignment's principal is the signed-in account itself
    # (as opposed to a group the role comes through).
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Context,
        [PSCustomObject] $Assignment
    )

    if ($Context.ObjectId) {
        $isMe = $Assignment.principalId -eq $Context.ObjectId
        return $isMe
    }

    $isMeByName = $Assignment.principalName -eq $Context.UserName
    return $isMeByName
}


function Get-AzResourcesRoleItems {
    param([Parameter(Mandatory)] [PSCustomObject] $Context)

    $assignee = if ($Context.ObjectId) {
        $Context.ObjectId
    } else {
        $Context.UserName
    }

    $tally   = New-AzResourcesSubscriptionTally -Context $Context
    $records = New-Object System.Collections.Generic.List[object]
    $seenIds = New-Object System.Collections.Generic.HashSet[string]

    foreach ($sub in $Context.Subscriptions) {
        $argList = @('role', 'assignment', 'list', '--assignee', $assignee, '--include-groups', '--all', '--subscription', $sub.Id)
        $query = Invoke-AzResourcesAzQuery -ArgList $argList

        if (-not (Add-AzResourcesCallOutcome -Tally $tally -Query $query -What "subscription '$($sub.Name)'")) {
            continue
        }

        foreach ($assignment in @($query.Data)) {
            # Management-group / root assignments surface under every subscription.
            if (-not $seenIds.Add([string]$assignment.id)) {
                continue
            }

            $principal = if (Test-AzResourcesIsMe -Context $Context -Assignment $assignment) {
                'me'
            } else {
                [string]$assignment.principalName
            }

            $records.Add([PSCustomObject]@{
                id               = [string]$assignment.id
                scope            = [string]$assignment.scope
                scopeType        = Get-AzResourcesScopeType -Scope ([string]$assignment.scope)
                roleName         = [string]$assignment.roleDefinitionName
                principal        = $principal
                principalType    = [string]$assignment.principalType
                subscriptionId   = $sub.Id
                subscriptionName = $sub.Name
                portalUrl        = Get-AzResourcesPortalUrl -Kind 'Resource' -Id ([string]$assignment.scope) -TenantId $Context.TenantId
            })
        }
    }

    $result = Resolve-AzResourcesTileResult -Tally $tally -Items $records
    return $result
}


# ---------------------------------------------------------------------------
# groups — Entra groups I'm a member of, plus groups I own
# ---------------------------------------------------------------------------

function Get-AzResourcesGroupType {
    param([Parameter(Mandatory)] [PSCustomObject] $Group)

    $isUnified = @($Group.groupTypes) -contains $script:AzResourcesUnifiedGroupMarker

    $groupType = if ($isUnified) {
        'microsoft365'
    } elseif ($Group.securityEnabled -and $Group.mailEnabled) {
        'mailEnabledSecurity'
    } elseif ($Group.securityEnabled) {
        'security'
    } else {
        'distribution'
    }

    return $groupType
}


function Get-AzResourcesGraphGroups {
    # One Graph `me/<Relation>` read via `az rest`, filtered to groups (memberOf
    # also returns directory roles). Query options go through --uri-parameters
    # rather than the URL so no '&' reaches az.cmd's command line on Windows.
    # One page of $top=999 covers nearly every user; a further page is reported
    # as a warning rather than silently dropped.
    param(
        [Parameter(Mandatory)] [ValidateSet('memberOf', 'ownedObjects')] [string] $Relation,
        [Parameter(Mandatory)] [PSCustomObject] $Tally
    )

    $groups = New-Object System.Collections.Generic.List[object]

    $argList = @(
        'rest', '--method', 'get',
        '--url', "$($script:AzResourcesGraphBase)/me/$Relation",
        '--uri-parameters', "`$top=$($script:AzResourcesGraphPageSize)", "`$select=$($script:AzResourcesGroupSelect)"
    )
    $query = Invoke-AzResourcesAzQuery -ArgList $argList

    if (-not (Add-AzResourcesCallOutcome -Tally $Tally -Query $query -What "Graph me/$Relation")) {
        return $groups
    }

    foreach ($entry in @($query.Data.value)) {
        if ($entry.'@odata.type' -eq $script:AzResourcesGraphGroupType) {
            $groups.Add($entry)
        }
    }

    if ($query.Data.'@odata.nextLink') {
        $Tally.Warnings.Add("Graph me/$Relation - more than $($script:AzResourcesGraphPageSize) entries; list truncated")
    }

    return $groups
}


function Get-AzResourcesGroupItems {
    param([Parameter(Mandatory)] [PSCustomObject] $Context)

    if ($Context.UserType -ne $script:AzResourcesUserAccountType) {
        $notUser = New-AzResourcesTileResult -State $script:AzResourcesStateNotPermitted -Message "signed in as a $($Context.UserType), not a user - group membership needs a user sign-in"
        return $notUser
    }

    $tally   = New-AzResourcesCallTally
    $records = New-Object System.Collections.Generic.List[object]

    $relations = [ordered]@{
        member = 'memberOf'
        owner  = 'ownedObjects'
    }

    foreach ($relationship in $relations.Keys) {
        $groups = Get-AzResourcesGraphGroups -Relation $relations[$relationship] -Tally $tally

        foreach ($group in $groups) {
            $records.Add([PSCustomObject]@{
                displayName  = [string]$group.displayName
                id           = [string]$group.id
                relationship = $relationship
                mail         = [string]$group.mail
                groupType    = Get-AzResourcesGroupType -Group $group
                portalUrl    = Get-AzResourcesPortalUrl -Kind 'Group' -Id ([string]$group.id)
            })
        }
    }

    $result = Resolve-AzResourcesTileResult -Tally $tally -Items $records
    return $result
}


# ---------------------------------------------------------------------------
# apps — app registrations + service principals I own, with credential dates
# ---------------------------------------------------------------------------

function ConvertTo-AzResourcesCredentials {
    # Only metadata (name, key id, end date) — `az ad app/sp list` never returns
    # a secret's value, and nothing else is copied across.
    param($PasswordCredentials, $KeyCredentials)

    $credentials = New-Object System.Collections.Generic.List[object]

    $sets = [ordered]@{
        secret      = $PasswordCredentials
        certificate = $KeyCredentials
    }

    foreach ($credentialType in $sets.Keys) {
        foreach ($cred in @($sets[$credentialType])) {
            if ($null -eq $cred) {
                continue
            }

            $credentials.Add([PSCustomObject]@{
                type        = $credentialType
                displayName = [string]$cred.displayName
                keyId       = [string]$cred.keyId
                endDateTime = [string]$cred.endDateTime
            })
        }
    }

    return ,$credentials
}


function Get-AzResourcesAppItems {
    param([Parameter(Mandatory)] [PSCustomObject] $Context)

    $tally   = New-AzResourcesCallTally
    $records = New-Object System.Collections.Generic.List[object]

    $kinds = [ordered]@{
        appRegistration  = 'app'
        servicePrincipal = 'sp'
    }

    foreach ($kind in $kinds.Keys) {
        $noun = $kinds[$kind]
        $query = Invoke-AzResourcesAzQuery -ArgList @('ad', $noun, 'list', '--show-mine')

        if (-not (Add-AzResourcesCallOutcome -Tally $tally -Query $query -What "az ad $noun list --show-mine")) {
            continue
        }

        foreach ($app in @($query.Data)) {
            if ($null -eq $app) {
                continue
            }

            $objectId = [string]$app.id
            $appId    = [string]$app.appId

            $portalUrl = if ($kind -eq 'appRegistration') {
                Get-AzResourcesPortalUrl -Kind 'AppRegistration' -Id $appId
            } else {
                Get-AzResourcesPortalUrl -Kind 'ServicePrincipal' -Id $objectId -AppId $appId
            }

            $records.Add([PSCustomObject]@{
                displayName = [string]$app.displayName
                appId       = $appId
                objectId    = $objectId
                kind        = $kind
                credentials = ConvertTo-AzResourcesCredentials -PasswordCredentials $app.passwordCredentials -KeyCredentials $app.keyCredentials
                portalUrl   = $portalUrl
            })
        }
    }

    $result = Resolve-AzResourcesTileResult -Tally $tally -Items $records
    return $result
}


# ---------------------------------------------------------------------------
# identities — user- and system-assigned managed identities in every
# subscription I can read, each with the roles it holds
# ---------------------------------------------------------------------------

function Get-AzResourcesRolesByPrincipal {
    # principalId -> list of { roleName, scope } for one subscription. A denied
    # read leaves the map empty (identities still list, without their roles).
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Subscription,
        [Parameter(Mandatory)] [PSCustomObject] $Tally
    )

    $map = @{}

    $query = Invoke-AzResourcesAzQuery -ArgList @('role', 'assignment', 'list', '--all', '--subscription', $Subscription.Id)

    if ($query.State -ne $script:AzResourcesStateOk) {
        $Tally.Warnings.Add("role assignments in '$($Subscription.Name)' - $($query.Message); identity roles omitted")
        return $map
    }

    foreach ($assignment in @($query.Data)) {
        $principalId = [string]$assignment.principalId

        if (-not $map.ContainsKey($principalId)) {
            $map[$principalId] = New-Object System.Collections.Generic.List[object]
        }

        $map[$principalId].Add([PSCustomObject]@{
            roleName = [string]$assignment.roleDefinitionName
            scope    = [string]$assignment.scope
        })
    }

    return $map
}


function New-AzResourcesIdentityRecord {
    param(
        [Parameter(Mandatory)] [string]         $Name,
        [Parameter(Mandatory)] [string]         $IdentityType,
        [Parameter(Mandatory)] [string]         $ResourceId,
        [string]                                $ResourceGroup,
        [string]                                $PrincipalId,
        [string]                                $HostResourceType,
        [Parameter(Mandatory)] [PSCustomObject] $Subscription,
        [Parameter(Mandatory)] [hashtable]      $RolesByPrincipal,
        [Parameter(Mandatory)] [string]         $TenantId
    )

    $roles = if ($PrincipalId -and $RolesByPrincipal.ContainsKey($PrincipalId)) {
        $RolesByPrincipal[$PrincipalId]
    } else {
        @()
    }

    $record = [PSCustomObject]@{
        name             = $Name
        type             = $IdentityType
        resourceGroup    = $ResourceGroup
        subscriptionId   = $Subscription.Id
        subscriptionName = $Subscription.Name
        principalId      = $PrincipalId
        roles            = @($roles)
        resourceId       = $ResourceId
        hostResourceType = $HostResourceType
        portalUrl        = Get-AzResourcesPortalUrl -Kind 'Resource' -Id $ResourceId -TenantId $TenantId
    }

    return $record
}


function Get-AzResourcesIdentityItems {
    param([Parameter(Mandatory)] [PSCustomObject] $Context)

    $tally   = New-AzResourcesSubscriptionTally -Context $Context
    $records = New-Object System.Collections.Generic.List[object]

    foreach ($sub in $Context.Subscriptions) {
        $userQuery = Invoke-AzResourcesAzQuery -ArgList @('identity', 'list', '--subscription', $sub.Id)
        $userOk = Add-AzResourcesCallOutcome -Tally $tally -Query $userQuery -What "user-assigned identities in '$($sub.Name)'"

        # Filtered client-side: a JMESPath --query would carry '&&' and quotes
        # through az.cmd's command line on Windows.
        $resourceQuery = Invoke-AzResourcesAzQuery -ArgList @('resource', 'list', '--subscription', $sub.Id)
        $resourceOk = Add-AzResourcesCallOutcome -Tally $tally -Query $resourceQuery -What "system-assigned identities in '$($sub.Name)'"

        if (-not $userOk -and -not $resourceOk) {
            continue
        }

        $rolesByPrincipal = Get-AzResourcesRolesByPrincipal -Subscription $sub -Tally $tally

        $common = @{
            Subscription     = $sub
            RolesByPrincipal = $rolesByPrincipal
            TenantId         = $Context.TenantId
        }

        if ($userOk) {
            foreach ($identity in @($userQuery.Data)) {
                if ($null -eq $identity) {
                    continue
                }

                $records.Add((New-AzResourcesIdentityRecord @common `
                    -Name ([string]$identity.name) `
                    -IdentityType 'userAssigned' `
                    -ResourceId ([string]$identity.id) `
                    -ResourceGroup ([string]$identity.resourceGroup) `
                    -PrincipalId ([string]$identity.principalId)))
            }
        }

        if ($resourceOk) {
            foreach ($resource in @($resourceQuery.Data)) {
                $identityType = [string]$resource.identity.type

                if ($identityType -notmatch $script:AzResourcesSystemAssignedMarker) {
                    continue
                }

                $records.Add((New-AzResourcesIdentityRecord @common `
                    -Name ([string]$resource.name) `
                    -IdentityType 'systemAssigned' `
                    -ResourceId ([string]$resource.id) `
                    -ResourceGroup ([string]$resource.resourceGroup) `
                    -PrincipalId ([string]$resource.identity.principalId) `
                    -HostResourceType ([string]$resource.type)))
            }
        }
    }

    $result = Resolve-AzResourcesTileResult -Tally $tally -Items $records
    return $result
}
