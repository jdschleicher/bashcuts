# ============================================================================
# Azure Resources — Per-tile fetchers (the EXPENSIVE seam)
# ============================================================================
# One fetcher per tile. Each runs its az calls through Invoke-AzResourcesAzQuery
# and returns a New-AzResourcesTileResult whose Items are normalized records
# (a fixed whitelist of fields — never the raw az payload) that each carry a
# portalUrl from Get-AzResourcesPortalUrl.
#
# Failure handling per az call:
#   - expired / interactive sign-in (AADSTS...) -> "errored", with an az login
#     hint, and the tile's remaining calls are skipped
#   - 403 / insufficient privileges             -> "denied"
#   - any other failure                         -> "errored"
# A tile is 'ok' when at least one of its calls succeeded (skipped pieces are
# listed in Warnings), 'notPermitted' when every failing call was a denial, and
# 'error' otherwise — az-Sync-AzResources leaves an errored tile's previous
# cache file untouched.
#
# Loaded by powcuts_home.ps1. See azresources_paths.ps1 for the cache layout.

$script:AzResourcesGraphBase      = 'https://graph.microsoft.com/v1.0'
$script:AzResourcesGraphPageSize  = 999   # Graph's max $top for transitiveMemberOf / ownedObjects
$script:AzResourcesGraphGroupType = '#microsoft.graph.group'
$script:AzResourcesGroupSelect    = 'id,displayName,mail,groupTypes,securityEnabled,mailEnabled'

$script:AzResourcesUnifiedGroupMarker   = 'Unified'
$script:AzResourcesDynamicGroupMarker   = 'DynamicMembership'
$script:AzResourcesSystemAssignedMarker = 'SystemAssigned'

$script:AzResourcesUserAccountType     = 'user'
$script:AzResourcesSubscriptionEnabled = 'Enabled'
$script:AzResourcesPrincipalMe         = 'me'

$script:AzResourcesKindAppRegistration  = 'appRegistration'
$script:AzResourcesKindServicePrincipal = 'servicePrincipal'
$script:AzResourcesIdentityUserAssigned   = 'userAssigned'
$script:AzResourcesIdentitySystemAssigned = 'systemAssigned'

# `az login --identity` reports one of these as user.name, and the identity's
# id in user.assignedIdentityInfo as 'MSIClient-<clientId>' / 'MSIObject-<objectId>'.
$script:AzResourcesManagedIdentityNames  = @('systemAssignedIdentity', 'userAssignedIdentity')
$script:AzResourcesMsiClientIdPattern    = '^MSIClient-(.+)$'
$script:AzResourcesMsiObjectIdPattern    = '^MSIObject-(.+)$'

# A UPN fallback is only passed to az when it can't be mangled by cmd.exe
# (az.cmd on Windows) — '^' is legal in a UPN and cmd strips it.
$script:AzResourcesSafeAssigneePattern = "^[A-Za-z0-9._@#'~!-]+$"

$script:AzResourcesReauthPattern           = 'AADSTS\d+|interaction_required|invalid_grant|az login'
$script:AzResourcesPermissionDeniedPattern = 'Authorization_RequestDenied|Insufficient privileges|AuthorizationFailed|Forbidden|\b403\b'
$script:AzResourcesStderrErrorLinePattern  = '^\s*ERROR'
$script:AzResourcesGraphErrorPattern       = '"code"\s*:\s*"([^"]+)".*?"message"\s*:\s*"([^"]+)"'
$script:AzResourcesMessageMaxChars         = 300   # cached messages are served to the viewer page — keep them short


# ---------------------------------------------------------------------------
# az call + outcome tally
# ---------------------------------------------------------------------------

function Get-AzResourcesErrorSummary {
    # A short, cache-safe summary of az stderr: the first ERROR line (az prints
    # WARNING lines first), reduced to "code: message" when it carries a Graph
    # / ARM error body, and length-capped so request ids and full JSON bodies
    # never land in a cache file the viewer serves.
    param(
        [string] $Stderr,
        [int]    $ExitCode
    )

    $lines = @($Stderr -split "`r?`n" | Where-Object { $_.Trim() })
    $errorLine = $lines | Where-Object { $_ -match $script:AzResourcesStderrErrorLinePattern } | Select-Object -First 1

    $summary = if ($errorLine) {
        $errorLine
    } elseif ($lines.Count -gt 0) {
        $lines[0]
    } else {
        "az exited with code $ExitCode"
    }

    if ($summary -match $script:AzResourcesGraphErrorPattern) {
        $summary = "$($Matches[1]): $($Matches[2])"
    }

    $summary = $summary.Trim()

    if ($summary.Length -gt $script:AzResourcesMessageMaxChars) {
        $summary = $summary.Substring(0, $script:AzResourcesMessageMaxChars)
    }

    return $summary
}


function New-AzResourcesQueryResult {
    param(
        [Parameter(Mandatory)] [string] $State,
        $Data = $null,
        [string] $Message = '',
        [switch] $NeedsLogin
    )

    $query = [PSCustomObject]@{
        State      = $State
        Data       = $Data
        Message    = $Message
        NeedsLogin = [bool]$NeedsLogin
    }

    return $query
}


function Invoke-AzResourcesAzQuery {
    # Runs one az call through the shared Invoke-AzDevOpsAzJson wrapper (stderr
    # capture, spinner, command echo) and classifies the outcome. Returns
    # { State = ok|notPermitted|error; Data = parsed JSON; Message; NeedsLogin }.
    # Data is $null for an empty JSON array (PowerShell 7 unrolls '[]' to
    # nothing), so callers skip $null entries when they enumerate it.
    param([Parameter(Mandatory)] [string[]] $ArgList)

    $result = Invoke-AzDevOpsAzJson -ArgList $ArgList

    if ($result.ExitCode -ne 0) {
        $summary = Get-AzResourcesErrorSummary -Stderr $result.Error -ExitCode $result.ExitCode

        if ($result.Error -match $script:AzResourcesReauthPattern) {
            $reauth = New-AzResourcesQueryResult -State $script:AzResourcesStateError -NeedsLogin `
                -Message "sign-in needs refreshing - run 'az login' and retry ($summary)"
            return $reauth
        }

        $state = if ($result.Error -match $script:AzResourcesPermissionDeniedPattern) {
            $script:AzResourcesStateNotPermitted
        } else {
            $script:AzResourcesStateError
        }

        $failed = New-AzResourcesQueryResult -State $state -Message $summary
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
        $parseFailed = New-AzResourcesQueryResult -State $script:AzResourcesStateError -Message "parse failed: $($_.Exception.Message)"
        return $parseFailed
    }

    $ok = New-AzResourcesQueryResult -State $script:AzResourcesStateOk -Data $parsed
    return $ok
}


function New-AzResourcesCallTally {
    # Running count of a tile's az call outcomes, folded into the tile's final
    # state by Resolve-AzResourcesTileResult.
    $tally = [PSCustomObject]@{
        Succeeded    = 0
        Denied       = 0
        Errored      = 0
        NeedsLogin   = $false
        FirstMessage = ''
        Warnings     = New-Object System.Collections.Generic.List[string]
    }

    return $tally
}


function Add-AzResourcesCallOutcome {
    # Record one az call's outcome. Returns $true when the call succeeded, so
    # the caller can `if (Add-AzResourcesCallOutcome ...) { use $query.Data }`.
    # A sign-in failure sets $Tally.NeedsLogin; loops stop on it, since every
    # later call would fail the same way.
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Tally,
        [Parameter(Mandatory)] [PSCustomObject] $Query,
        [Parameter(Mandatory)] [string]         $What
    )

    if ($Query.State -eq $script:AzResourcesStateOk) {
        $Tally.Succeeded++
        return $true
    }

    if ($Query.NeedsLogin) {
        $Tally.NeedsLogin = $true
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


function Get-AzResourcesUserOnlyResult {
    # Graph `me/...` reads (groups, `az ad app/sp list --show-mine`) only work for
    # a user sign-in. For a service principal / managed identity, returns the
    # tile's notPermitted result; for a user, returns $null so the tile runs.
    param([Parameter(Mandatory)] [PSCustomObject] $Context)

    if ($Context.IsUser) {
        return $null
    }

    $message = "signed in as a $($Context.UserType), not a user - this tile reads Graph 'me' data, which needs a user sign-in"
    $notUser = New-AzResourcesTileResult -State $script:AzResourcesStateNotPermitted -Message $message
    return $notUser
}


# ---------------------------------------------------------------------------
# Sign-in context — fetched once per sync and handed to every fetcher
# ---------------------------------------------------------------------------

function Read-AzResourcesAccount {
    # `az account show`, parsed, or $null when az has no usable sign-in. A
    # session call, so (like azdevops_auth.ps1) it runs directly rather than
    # through the data wrapper.
    $accountJson = & az account show --output json 2>$null

    if ($LASTEXITCODE -ne 0 -or -not $accountJson) {
        return $null
    }

    try {
        $account = ($accountJson -join "`n") | ConvertFrom-Json
    }
    catch {
        return $null
    }

    if ([string]$account.tenantId -notmatch $script:AzResourcesGuidPattern) {
        return $null
    }

    return $account
}


function Get-AzResourcesTenantSubscriptions {
    # Enabled subscriptions in the signed-in tenant. Returns { Query; List; Names }
    # — the Query is kept so a failed `az account list` can be reported by the
    # tiles that fan out across subscriptions. The list comes from az's local
    # profile: subscriptions added since `az login` need a fresh `az login`.
    param([Parameter(Mandatory)] [string] $TenantId)

    $list  = New-Object System.Collections.Generic.List[object]
    $names = @{}

    $query = Invoke-AzResourcesAzQuery -ArgList @('account', 'list')

    if ($query.State -eq $script:AzResourcesStateOk) {
        foreach ($sub in @($query.Data)) {
            if ($null -eq $sub) {
                continue
            }

            $inTenant = $sub.tenantId -eq $TenantId
            $enabled  = $sub.state -eq $script:AzResourcesSubscriptionEnabled

            if ($inTenant -and $enabled) {
                $list.Add([PSCustomObject]@{
                    Id   = [string]$sub.id
                    Name = [string]$sub.name
                })

                $names[([string]$sub.id).ToLower()] = [string]$sub.name
            }
        }
    }

    $subscriptions = [PSCustomObject]@{
        Query = $query
        List  = $list
        Names = $names
    }

    return $subscriptions
}


function Get-AzResourcesServicePrincipalObjectId {
    # Object id of the service principal for an appId / client id. The id must
    # be a GUID before it is handed to az (it reaches az.cmd's command line).
    param([string] $AppId)

    if ($AppId -notmatch $script:AzResourcesGuidPattern) {
        return $null
    }

    $query = Invoke-AzResourcesAzQuery -ArgList @('ad', 'sp', 'show', '--id', $AppId)

    if ($query.State -ne $script:AzResourcesStateOk) {
        return $null
    }

    $objectId = [string]$query.Data.id
    return $objectId
}


function Get-AzResourcesSignedInObjectId {
    # The signed-in principal's object id, used for `--assignee` and for "is
    # this role mine" matching (a UPN or appId is less reliable for both).
    # Returns { ObjectId; Warning }:
    #   user              -> `az ad signed-in-user show`
    #   service principal -> `az ad sp show --id <appId>`
    #   managed identity  -> 'MSIObject-<id>' directly, or 'MSIClient-<id>' via
    #                        `az ad sp show`; a bare system-assigned MI can't be
    #                        resolved without Graph and reports a warning
    param([Parameter(Mandatory)] [PSCustomObject] $Account)

    $userType = [string]$Account.user.type
    $userName = [string]$Account.user.name
    $identityInfo = [string]$Account.user.assignedIdentityInfo
    $objectId = $null

    if ($userType -eq $script:AzResourcesUserAccountType) {
        $query = Invoke-AzResourcesAzQuery -ArgList @('ad', 'signed-in-user', 'show')

        if ($query.State -eq $script:AzResourcesStateOk) {
            $objectId = [string]$query.Data.id
        }
    } elseif ($script:AzResourcesManagedIdentityNames -contains $userName) {
        if ($identityInfo -match $script:AzResourcesMsiObjectIdPattern) {
            $objectId = $Matches[1]
        } elseif ($identityInfo -match $script:AzResourcesMsiClientIdPattern) {
            $objectId = Get-AzResourcesServicePrincipalObjectId -AppId $Matches[1]
        }
    } else {
        $objectId = Get-AzResourcesServicePrincipalObjectId -AppId $userName
    }

    $isResolved = $objectId -match $script:AzResourcesGuidPattern

    $resolved = if ($isResolved) {
        [PSCustomObject]@{
            ObjectId = $objectId
            Warning  = ''
        }
    } else {
        [PSCustomObject]@{
            ObjectId = $null
            Warning  = "could not resolve the signed-in $userType's object id - 'me' detection falls back to the sign-in name"
        }
    }

    return $resolved
}


function Get-AzResourcesContext {
    # Returns { TenantId, UserName, UserType, IsUser, ObjectId, ObjectIdWarning,
    # Subscriptions, SubscriptionNames, SubscriptionsQuery }, or $null after
    # printing one clear `az login` message when az isn't on PATH or no account
    # is signed in.
    param([Parameter(Mandatory)] [string] $CommandName)

    if (-not (Test-AzDevOpsCliPresent)) {
        Write-Host "$CommandName aborted - az CLI not found on PATH. Install it, run 'az login', then retry." -ForegroundColor Red
        return $null
    }

    $account = Read-AzResourcesAccount

    if (-not $account) {
        Write-Host "$CommandName aborted - not logged in to Azure. Run 'az login', then retry." -ForegroundColor Red
        return $null
    }

    $tenantId      = [string]$account.tenantId
    $userType      = [string]$account.user.type
    $subscriptions = Get-AzResourcesTenantSubscriptions -TenantId $tenantId
    $signedIn      = Get-AzResourcesSignedInObjectId -Account $account

    $context = [PSCustomObject]@{
        TenantId           = $tenantId
        UserName           = [string]$account.user.name
        UserType           = $userType
        IsUser             = $userType -eq $script:AzResourcesUserAccountType
        ObjectId           = $signedIn.ObjectId
        ObjectIdWarning    = $signedIn.Warning
        Subscriptions      = $subscriptions.List
        SubscriptionNames  = $subscriptions.Names
        SubscriptionsQuery = $subscriptions.Query
    }

    return $context
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


# ---------------------------------------------------------------------------
# roles — RBAC role assignments I hold, directly or through a group
# ---------------------------------------------------------------------------

function Get-AzResourcesRoleAssignee {
    # The --assignee value: the object id when it resolved, else the sign-in
    # name for a user (only when it is cmd.exe-safe), else $null.
    param([Parameter(Mandatory)] [PSCustomObject] $Context)

    if ($Context.ObjectId) {
        return $Context.ObjectId
    }

    $nameIsSafe = $Context.UserName -match $script:AzResourcesSafeAssigneePattern

    if ($Context.IsUser -and $nameIsSafe) {
        return $Context.UserName
    }

    return $null
}


function Test-AzResourcesIsMe {
    # Whether a role assignment's principal is the signed-in account itself
    # (as opposed to a group the role comes through).
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Context,
        [Parameter(Mandatory)] [PSCustomObject] $Assignment
    )

    if ($Context.ObjectId) {
        $isMe = $Assignment.principalId -eq $Context.ObjectId
        return $isMe
    }

    $isMeByName = $Assignment.principalName -eq $Context.UserName
    return $isMeByName
}


function Get-AzResourcesScopeSubscription {
    # The subscription a scope sits in, as { Id; Name }. Management-group and
    # root scopes sit above every subscription, so both are empty there.
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Context,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Scope
    )

    $subscriptionId = ''

    if ($Scope -match '^/subscriptions/([^/]+)') {
        $subscriptionId = $Matches[1].ToLower()
    }

    $name = if ($subscriptionId -and $Context.SubscriptionNames.ContainsKey($subscriptionId)) {
        $Context.SubscriptionNames[$subscriptionId]
    } else {
        ''
    }

    $subscription = [PSCustomObject]@{
        Id   = $subscriptionId
        Name = $name
    }

    return $subscription
}


function New-AzResourcesRoleRecord {
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Context,
        [Parameter(Mandatory)] [PSCustomObject] $Assignment
    )

    $scope = [string]$Assignment.scope
    $subscription = Get-AzResourcesScopeSubscription -Context $Context -Scope $scope

    # principalName is empty for a deleted principal, or when az couldn't look it up.
    $principal = if (Test-AzResourcesIsMe -Context $Context -Assignment $Assignment) {
        $script:AzResourcesPrincipalMe
    } elseif ($Assignment.principalName) {
        [string]$Assignment.principalName
    } else {
        [string]$Assignment.principalId
    }

    $record = [PSCustomObject]@{
        id               = [string]$Assignment.id
        scope            = $scope
        scopeType        = Get-AzResourcesScopeType -Scope $scope
        roleName         = [string]$Assignment.roleDefinitionName
        principal        = $principal
        principalType    = [string]$Assignment.principalType
        subscriptionId   = $subscription.Id
        subscriptionName = $subscription.Name
        portalUrl        = Get-AzResourcesPortalUrl -Kind 'Resource' -Id $scope -TenantId $Context.TenantId
    }

    return $record
}


function Get-AzResourcesRoleItems {
    param([Parameter(Mandatory)] [PSCustomObject] $Context)

    $assignee = Get-AzResourcesRoleAssignee -Context $Context

    if (-not $assignee) {
        $message = "could not resolve the signed-in $($Context.UserType)'s object id, which role lookup needs for this sign-in"
        $unresolved = New-AzResourcesTileResult -State $script:AzResourcesStateNotPermitted -Message $message
        return $unresolved
    }

    $tally   = New-AzResourcesSubscriptionTally -Context $Context
    $records = New-Object System.Collections.Generic.List[object]
    $seenIds = New-Object System.Collections.Generic.HashSet[string]

    if ($Context.ObjectIdWarning) {
        $tally.Warnings.Add($Context.ObjectIdWarning)
    }

    foreach ($sub in $Context.Subscriptions) {
        $argList = @('role', 'assignment', 'list', '--assignee', $assignee, '--include-groups', '--all', '--subscription', $sub.Id)
        $query = Invoke-AzResourcesAzQuery -ArgList $argList

        if (-not (Add-AzResourcesCallOutcome -Tally $tally -Query $query -What "subscription '$($sub.Name)'")) {
            if ($tally.NeedsLogin) {
                break
            }

            continue
        }

        foreach ($assignment in @($query.Data)) {
            if ($null -eq $assignment) {
                continue
            }

            # Management-group / root assignments surface under every subscription.
            if (-not $seenIds.Add([string]$assignment.id)) {
                continue
            }

            $records.Add((New-AzResourcesRoleRecord -Context $Context -Assignment $assignment))
        }
    }

    $result = Resolve-AzResourcesTileResult -Tally $tally -Items $records
    return $result
}


# ---------------------------------------------------------------------------
# groups — Entra groups I'm a member of (incl. nested), plus groups I own
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
    # One Graph `me/<Relation>` read via `az rest`, filtered to groups (the
    # collection also holds directory roles / administrative units). Query
    # options go through --uri-parameters rather than the URL so no '&' reaches
    # az.cmd's command line on Windows. One page of $top=999 covers nearly every
    # user; a further page is reported as a warning rather than silently dropped.
    param(
        [Parameter(Mandatory)] [ValidateSet('transitiveMemberOf', 'ownedObjects')] [string] $Relation,
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
        if ($null -eq $entry) {
            continue
        }

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
    # Membership is transitive (nested groups included) so it lines up with the
    # roles tile, whose --include-groups also follows nested groups.
    param([Parameter(Mandatory)] [PSCustomObject] $Context)

    $notUser = Get-AzResourcesUserOnlyResult -Context $Context

    if ($notUser) {
        return $notUser
    }

    $tally   = New-AzResourcesCallTally
    $records = New-Object System.Collections.Generic.List[object]

    $relations = [ordered]@{
        member = 'transitiveMemberOf'
        owner  = 'ownedObjects'
    }

    foreach ($relationship in $relations.Keys) {
        $groups = Get-AzResourcesGraphGroups -Relation $relations[$relationship] -Tally $tally

        if ($tally.NeedsLogin) {
            break
        }

        foreach ($group in $groups) {
            $records.Add([PSCustomObject]@{
                displayName  = [string]$group.displayName
                id           = [string]$group.id
                relationship = $relationship
                mail         = [string]$group.mail
                groupType    = Get-AzResourcesGroupType -Group $group
                isDynamic    = @($group.groupTypes) -contains $script:AzResourcesDynamicGroupMarker
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

function ConvertTo-AzResourcesIsoDate {
    # Credential dates as UTC ISO-8601 on every PowerShell version: 7.x's
    # ConvertFrom-Json turns ISO strings into [datetime] (whose [string] form is
    # culture-local with no zone), while 5.1 keeps the original string.
    param($Value)

    if ($null -eq $Value) {
        return ''
    }

    if ($Value -is [datetime]) {
        $iso = $Value.ToUniversalTime().ToString('o')
        return $iso
    }

    $text = [string]$Value
    return $text
}


function ConvertTo-AzResourcesCredentials {
    # Only metadata — `az ad app/sp list` never returns a secret's value, and
    # nothing beyond these whitelisted fields is copied across. Certificates
    # keep usage (Sign / Verify) so a SAML signing pair doesn't read as a
    # duplicate.
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
                type          = $credentialType
                displayName   = [string]$cred.displayName
                keyId         = [string]$cred.keyId
                startDateTime = ConvertTo-AzResourcesIsoDate -Value $cred.startDateTime
                endDateTime   = ConvertTo-AzResourcesIsoDate -Value $cred.endDateTime
                usage         = [string]$cred.usage
                keyType       = [string]$cred.type
            })
        }
    }

    return ,$credentials
}


function Get-AzResourcesAppItems {
    param([Parameter(Mandatory)] [PSCustomObject] $Context)

    $notUser = Get-AzResourcesUserOnlyResult -Context $Context

    if ($notUser) {
        return $notUser
    }

    $tally   = New-AzResourcesCallTally
    $records = New-Object System.Collections.Generic.List[object]

    $kinds = [ordered]@{
        $script:AzResourcesKindAppRegistration  = 'app'
        $script:AzResourcesKindServicePrincipal = 'sp'
    }

    foreach ($kind in $kinds.Keys) {
        $noun = $kinds[$kind]
        $query = Invoke-AzResourcesAzQuery -ArgList @('ad', $noun, 'list', '--show-mine')

        if (-not (Add-AzResourcesCallOutcome -Tally $tally -Query $query -What "az ad $noun list --show-mine")) {
            if ($tally.NeedsLogin) {
                break
            }

            continue
        }

        foreach ($app in @($query.Data)) {
            if ($null -eq $app) {
                continue
            }

            $objectId = [string]$app.id
            $appId    = [string]$app.appId

            $portalUrl = if ($kind -eq $script:AzResourcesKindAppRegistration) {
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
# subscription I can read, each with the roles it holds anywhere in the tenant
# ---------------------------------------------------------------------------

function Add-AzResourcesAssignmentsToRoleMap {
    # Fold one subscription's role assignments into the tenant-wide
    # principalId -> roles map, de-duplicated by assignment id (management-group
    # assignments appear under every subscription). --fill-principal-name false
    # skips the Graph name lookup az would otherwise do for every principal.
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Subscription,
        [Parameter(Mandatory)] [PSCustomObject] $Tally,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [hashtable] $RoleMap,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.HashSet[string]] $SeenIds
    )

    $argList = @('role', 'assignment', 'list', '--all', '--fill-principal-name', 'false', '--subscription', $Subscription.Id)
    $query = Invoke-AzResourcesAzQuery -ArgList $argList

    if (-not (Add-AzResourcesCallOutcome -Tally $Tally -Query $query -What "role assignments in '$($Subscription.Name)' (identity roles there omitted)")) {
        return
    }

    foreach ($assignment in @($query.Data)) {
        if ($null -eq $assignment) {
            continue
        }

        if (-not $SeenIds.Add([string]$assignment.id)) {
            continue
        }

        $principalId = [string]$assignment.principalId

        if (-not $RoleMap.ContainsKey($principalId)) {
            $RoleMap[$principalId] = New-Object System.Collections.Generic.List[object]
        }

        $RoleMap[$principalId].Add([PSCustomObject]@{
            roleName = [string]$assignment.roleDefinitionName
            scope    = [string]$assignment.scope
        })
    }
}


function Get-AzResourcesSubscriptionIdentities {
    # The managed identities in one subscription as { Name, IdentityType,
    # ResourceId, ResourceGroup, PrincipalId, HostResourceType, Subscription }:
    # user-assigned from `az identity list`, system-assigned from the host
    # resources in `az resource list`. Filtered client-side: a JMESPath --query
    # would carry '&&' and quotes through az.cmd's command line on Windows.
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Subscription,
        [Parameter(Mandatory)] [PSCustomObject] $Tally
    )

    $found = New-Object System.Collections.Generic.List[object]

    $userQuery = Invoke-AzResourcesAzQuery -ArgList @('identity', 'list', '--subscription', $Subscription.Id)

    if (Add-AzResourcesCallOutcome -Tally $Tally -Query $userQuery -What "user-assigned identities in '$($Subscription.Name)'") {
        foreach ($identity in @($userQuery.Data)) {
            if ($null -eq $identity) {
                continue
            }

            $found.Add([PSCustomObject]@{
                Name             = [string]$identity.name
                IdentityType     = $script:AzResourcesIdentityUserAssigned
                ResourceId       = [string]$identity.id
                ResourceGroup    = [string]$identity.resourceGroup
                PrincipalId      = [string]$identity.principalId
                HostResourceType = ''
                Subscription     = $Subscription
            })
        }
    }

    if ($Tally.NeedsLogin) {
        return $found
    }

    $resourceQuery = Invoke-AzResourcesAzQuery -ArgList @('resource', 'list', '--subscription', $Subscription.Id)

    if (Add-AzResourcesCallOutcome -Tally $Tally -Query $resourceQuery -What "system-assigned identities in '$($Subscription.Name)'") {
        foreach ($resource in @($resourceQuery.Data)) {
            if ($null -eq $resource) {
                continue
            }

            if ([string]$resource.identity.type -notmatch $script:AzResourcesSystemAssignedMarker) {
                continue
            }

            $found.Add([PSCustomObject]@{
                Name             = [string]$resource.name
                IdentityType     = $script:AzResourcesIdentitySystemAssigned
                ResourceId       = [string]$resource.id
                ResourceGroup    = [string]$resource.resourceGroup
                PrincipalId      = [string]$resource.identity.principalId
                HostResourceType = [string]$resource.type
                Subscription     = $Subscription
            })
        }
    }

    return $found
}


function New-AzResourcesIdentityRecord {
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Identity,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [hashtable] $RoleMap,
        [Parameter(Mandatory)] [string]         $TenantId
    )

    $principalId = $Identity.PrincipalId

    # An if-expression unrolls the List, so @() below normalizes the result.
    $roles = if ($principalId -and $RoleMap.ContainsKey($principalId)) {
        $RoleMap[$principalId]
    } else {
        @()
    }

    $record = [PSCustomObject]@{
        name             = $Identity.Name
        type             = $Identity.IdentityType
        resourceGroup    = $Identity.ResourceGroup
        subscriptionId   = $Identity.Subscription.Id
        subscriptionName = $Identity.Subscription.Name
        principalId      = $principalId
        roles            = @($roles)
        resourceId       = $Identity.ResourceId
        hostResourceType = $Identity.HostResourceType
        portalUrl        = Get-AzResourcesPortalUrl -Kind 'Resource' -Id $Identity.ResourceId -TenantId $TenantId
    }

    return $record
}


function Get-AzResourcesIdentityItems {
    # Two passes: collect every subscription's identities and role assignments
    # first, then attach roles — so an identity in subscription A still shows
    # the role it holds in subscription B.
    param([Parameter(Mandatory)] [PSCustomObject] $Context)

    $tally      = New-AzResourcesSubscriptionTally -Context $Context
    $identities = New-Object System.Collections.Generic.List[object]
    $roleMap    = @{}
    $seenIds    = New-Object System.Collections.Generic.HashSet[string]

    foreach ($sub in $Context.Subscriptions) {
        $found = Get-AzResourcesSubscriptionIdentities -Subscription $sub -Tally $tally

        foreach ($identity in $found) {
            $identities.Add($identity)
        }

        if ($tally.NeedsLogin) {
            break
        }

        Add-AzResourcesAssignmentsToRoleMap -Subscription $sub -Tally $tally -RoleMap $roleMap -SeenIds $seenIds

        if ($tally.NeedsLogin) {
            break
        }
    }

    $records = New-Object System.Collections.Generic.List[object]

    foreach ($identity in $identities) {
        $records.Add((New-AzResourcesIdentityRecord -Identity $identity -RoleMap $roleMap -TenantId $Context.TenantId))
    }

    $result = Resolve-AzResourcesTileResult -Tally $tally -Items $records
    return $result
}
