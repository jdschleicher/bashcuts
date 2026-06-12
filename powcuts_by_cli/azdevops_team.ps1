# ============================================================================
# Azure DevOps — Team roster & @-mention tagging
# ============================================================================
# Shared, work-type-agnostic team tagging used by every debrief that posts an
# Azure DevOps discussion comment: the Pomodoro timer (pow_timer.ps1) and the
# unplanned / firefighting debriefs (azdevops_unplanned.ps1). A roster of
# teammates is cached locally and resolved to identity GUIDs; a type-to-filter
# picker turns selections into real data-vss-mention anchors so the tagged
# teammates are actually notified.
#
# Roster sources (az-Sync-AzDevOpsTeam merges both, de-duped by identity id):
#   1. PRIMARY - the members of a project team, pulled in one call via
#      `az devops team list-member`. The returned identity sub-object already
#      carries name/email/GUID, so team-sourced members need no per-person
#      identities lookup.
#   2. SUPPLEMENT - $env:AZ_TEAM, an optional ';'- or ','-separated list of
#      emails/names for people outside the picked team, each resolved
#      individually via the identities API (Get-AzDevOpsIdentity).
#
# Public surface:
#   az-Sync-AzDevOpsTeam - pick a project team (or pass -Team), fetch its
#                          members, merge the $env:AZ_TEAM supplement, and cache
#                          the roster. Re-run after switching project/team or
#                          changing $env:AZ_TEAM.
#
# Internal entry points (called by the debriefs):
#   Select-AzDevOpsMention     - console tag field for the debriefs with no WPF
#                                form (non-Windows timer + unplanned). A blank
#                                Read-Host (type names/emails, blank = none) -
#                                no yes/no gate, no grid. The WPF timer form has
#                                its own in-form tag field (Show-WpfTimerDebrief).
#   ConvertFrom-AzDevOpsMentionInput - resolve a typed ';'/','-separated tag
#                                string to teammate records (roster match first,
#                                live identities lookup as fallback).
#   Format-AzDevOpsMentionLine - render the picked members as a single
#                                "Tagged: @a @b" line for a comment body.
#
# Identity resolution (Get-AzDevOpsIdentity) and the anchor shape
# (Format-AzDevOpsMentionAnchor) are the two places to revisit if a tagged
# teammate does not receive a notification.
#
# Loaded by powcuts_home.ps1. See azdevops_auth.ps1 for the master docstring.

$script:AzDevOpsTeamEnvVar     = 'AZ_TEAM'
$script:AzDevOpsTeamCacheFile  = 'team.json'
$script:AzDevOpsMentionVersion = 'version:2.0'
$script:AzDevOpsTeamIconPeople = [char]::ConvertFromUtf32(0x1F465)   # busts in silhouette
$script:AzDevOpsListSeparators = [char[]]@(';', ',')                 # roster / tag-field delimiters


function New-AzDevOpsTeamMemberRecord {
    # Single definition site for the teammate record shape consumed by the
    # mention picker and anchor builder. Both roster sources - team CLI rows
    # (ConvertFrom-AzDevOpsTeamMemberRow) and env-var identity lookups
    # (Resolve-AzDevOpsTeamMember) - funnel through here so the shape has one home.
    param(
        [string] $DisplayName,
        [string] $Email,
        [string] $Id
    )

    $record = [PSCustomObject]@{
        DisplayName = $DisplayName
        Email       = $Email
        Id          = $Id
    }
    return $record
}


function Get-AzDevOpsTeamCachePath {
    # Resolved-roster cache (display name + email + identity GUID) under the
    # AzDO cache dir, so debriefs build mention anchors without re-hitting the
    # CLI every session. Returns $null when the cache layout isn't available.
    $cacheFile = $script:AzDevOpsTeamCacheFile
    $path      = Get-AzDevOpsCacheFilePath -FileName $cacheFile
    return $path
}


function Read-AzDevOpsTeamCache {
    $path = Get-AzDevOpsTeamCachePath
    if (-not $path) {
        return @()
    }

    $members = Read-AzDevOpsJsonArrayCache -Path $path
    return $members
}


function Save-AzDevOpsTeamCache {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Members)

    $path = Get-AzDevOpsTeamCachePath
    if (-not $path) {
        return
    }

    Save-AzDevOpsJsonArrayCache -Path $path -Items $Members
}


function Get-AzDevOpsTeamEnvRoster {
    # Split $env:AZ_TEAM into a clean list of teammate identifiers (emails
    # and/or names). Accepts ';' or ',' separators, trims whitespace, and drops
    # blanks and case-insensitive duplicates. Returns an empty array when the
    # env var is unset - it is an optional supplement, not the primary source.
    $raw = [Environment]::GetEnvironmentVariable($script:AzDevOpsTeamEnvVar)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $separators = $script:AzDevOpsListSeparators
    $parts      = $raw.Split($separators, [StringSplitOptions]::RemoveEmptyEntries)

    $seen   = New-Object System.Collections.Generic.HashSet[string]
    $roster = New-Object System.Collections.Generic.List[string]
    foreach ($part in $parts) {
        $trimmed = $part.Trim()
        if ($trimmed -and $seen.Add($trimmed.ToLowerInvariant())) {
            $roster.Add($trimmed)
        }
    }

    $result = @($roster)
    return $result
}


function ConvertFrom-AzDevOpsTeamMemberRow {
    # Map one `az devops team list-member` row to the { DisplayName, Email, Id }
    # record the mention anchor needs. The identity sub-object already carries
    # the GUID and email, so a team-sourced member resolves without an extra
    # identities lookup. Returns $null for a row missing an identity GUID.
    param([Parameter(Mandatory)] [object] $Row)

    $identity = $Row.identity
    if (-not $identity -or -not $identity.id) {
        return $null
    }

    $displayName = if ($identity.displayName) {
        $identity.displayName
    } else {
        $identity.uniqueName
    }

    $record = New-AzDevOpsTeamMemberRecord -DisplayName $displayName -Email $identity.uniqueName -Id $identity.id
    return $record
}


function Resolve-AzDevOpsTeamMember {
    # Resolve one $env:AZ_TEAM entry (email or display name) to a { DisplayName,
    # Email, Id } record via the identities API. The Id is the identity GUID the
    # discussion control needs for a notifying @-mention. Returns $null when the
    # lookup fails or matches nobody, so Sync-AzDevOpsTeam can report the miss
    # and skip it rather than caching a half-resolved entry.
    param([Parameter(Mandatory)] [string] $Identifier)

    if (-not (Get-Command Get-AzDevOpsIdentity -ErrorAction SilentlyContinue)) {
        return $null
    }

    $result = Get-AzDevOpsIdentity -Query $Identifier
    if ($result.ExitCode -ne 0) {
        return $null
    }

    try {
        $parsed = $result.Json | ConvertFrom-Json
    }
    catch {
        return $null
    }

    $candidates = @($parsed.value)
    if ($candidates.Count -eq 0) {
        return $null
    }

    $identity = $candidates[0]

    $displayName = if ($identity.providerDisplayName) {
        $identity.providerDisplayName
    } else {
        $Identifier
    }

    $email = if ($identity.properties -and $identity.properties.Mail -and $identity.properties.Mail.'$value') {
        $identity.properties.Mail.'$value'
    } else {
        $Identifier
    }

    $record = New-AzDevOpsTeamMemberRecord -DisplayName $displayName -Email $email -Id $identity.id
    return $record
}


function Select-AzDevOpsTeamFromCli {
    # Pick which project team to pull members from. With -Team it's a
    # pass-through. With a single team in the project it auto-selects. Otherwise
    # an Out-ConsoleGridView (or numbered Read-Host fallback) over
    # `az devops team list`. Returns the team name, or $null on cancel / no teams.
    param([string] $Team)

    if ($Team) {
        return $Team
    }

    $listResult = Get-AzDevOpsTeamList
    if ($listResult.ExitCode -ne 0) {
        Write-Host "Could not list teams: $($listResult.Error)" -ForegroundColor Red
        return $null
    }

    try {
        $teams = @($listResult.Json | ConvertFrom-Json)
    }
    catch {
        $teams = @()
    }

    if ($teams.Count -eq 0) {
        Write-Host "No teams found in the default project." -ForegroundColor Yellow
        return $null
    }

    if ($teams.Count -eq 1) {
        $only = $teams[0].name
        return $only
    }

    if (Test-AzDevOpsGridAvailable) {
        $grid = $teams |
            Select-Object name, description |
            Out-ConsoleGridView -Title 'Pick a team to pull members from' -OutputMode Single

        $pickedName = if ($grid) {
            $grid.name
        } else {
            $null
        }
        return $pickedName
    }

    Write-Host ''
    Write-Host 'Teams:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $teams.Count; $i++) {
        Write-Host ("  {0}) {1}" -f ($i + 1), $teams[$i].name)
    }

    $raw   = Read-Host 'Team number (blank = cancel)'
    $index = 0
    if (-not [int]::TryParse($raw, [ref]$index)) {
        return $null
    }

    $zeroBased = $index - 1
    if ($zeroBased -lt 0 -or $zeroBased -ge $teams.Count) {
        return $null
    }

    $chosenName = $teams[$zeroBased].name
    return $chosenName
}


function Sync-AzDevOpsTeam {
    # Build the roster: pull the picked team's members from the CLI (primary),
    # merge the optional $env:AZ_TEAM supplement (resolved individually),
    # de-dupe by identity id, cache, and return the records. Misses on either
    # source are reported and skipped so one bad entry doesn't sink the roster.
    param([string] $Team)

    $records = New-Object System.Collections.Generic.List[object]
    $seenIds = New-Object System.Collections.Generic.HashSet[string]

    $teamName = Select-AzDevOpsTeamFromCli -Team $Team
    if ($teamName) {
        $memberResult = Get-AzDevOpsTeamMemberList -Team $teamName
        if ($memberResult.ExitCode -eq 0) {
            try {
                $rows = @($memberResult.Json | ConvertFrom-Json)
            }
            catch {
                $rows = @()
            }

            foreach ($row in $rows) {
                $member = ConvertFrom-AzDevOpsTeamMemberRow -Row $row
                if ($member -and $seenIds.Add($member.Id)) {
                    $records.Add($member)
                }
            }
        } else {
            Write-Host "  Could not list members of '$teamName': $($memberResult.Error)" -ForegroundColor Yellow
        }
    }

    $envRoster = Get-AzDevOpsTeamEnvRoster
    foreach ($identifier in $envRoster) {
        $member = Resolve-AzDevOpsTeamMember -Identifier $identifier
        if ($null -eq $member -or -not $member.Id) {
            $envVar = $script:AzDevOpsTeamEnvVar
            Write-Host "  Could not resolve '$identifier' (`$env:$envVar) - skipping." -ForegroundColor Yellow
            continue
        }

        if ($seenIds.Add($member.Id)) {
            $records.Add($member)
        }
    }

    $roster = @($records)
    Save-AzDevOpsTeamCache -Members $roster
    return $roster
}


function Get-AzDevOpsTeam {
    # Cached roster reader for the debriefs. Returns the cache as-is - empty when
    # no roster has been synced yet. The roster is populated explicitly via
    # az-Sync-AzDevOpsTeam (interactive: it prompts for a team), so we never
    # auto-launch that picker in the middle of a debrief.
    $cached = Read-AzDevOpsTeamCache
    return $cached
}


function Format-AzDevOpsMentionAnchor {
    # Build the Azure DevOps discussion @-mention anchor for one resolved
    # teammate. The data-vss-mention attribute carries the identity GUID; the
    # work-item discussion control turns this exact anchor shape into a real
    # notification on save, and the version token mirrors what the AzDO web
    # editor emits. If a tagged teammate is NOT notified, this anchor (and the
    # identity GUID feeding it) is what to revisit.
    param([Parameter(Mandatory)] [object] $Member)

    $mentionVersion = $script:AzDevOpsMentionVersion
    $atSign         = '@'
    $quote          = '"'

    # HTML-encode the visible label so a display name containing < > & can't
    # break (or inject into) the anchor posted to the discussion thread. The Id
    # is an identity GUID, so it needs no encoding.
    $label = [System.Net.WebUtility]::HtmlEncode($Member.DisplayName)

    $dataAttr = "data-vss-mention=$quote$mentionVersion,$($Member.Id)$quote"
    $anchor   = "<a href=$quote#$quote $dataAttr>$atSign$label</a>"
    return $anchor
}


function Format-AzDevOpsMentionLine {
    # Compose the single "Tagged: @a @b" line appended to a debrief comment.
    # Returns '' for an empty selection so callers can skip the line (and keep
    # posting exactly as before) when nobody is tagged.
    param([AllowEmptyCollection()] [object[]] $Members)

    # Drop $null / unresolved entries so an omitted -Mentions arg (which arrives
    # as @($null), a 1-element array) collapses to an empty line rather than a
    # broken anchor.
    $memberList = @($Members | Where-Object { $null -ne $_ -and $_.Id })
    if ($memberList.Count -eq 0) {
        return ''
    }

    $iconPeople = $script:AzDevOpsTeamIconPeople

    $anchors = New-Object System.Collections.Generic.List[string]
    foreach ($member in $memberList) {
        $anchor = Format-AzDevOpsMentionAnchor -Member $member
        $anchors.Add($anchor)
    }

    $line = "$iconPeople Tagged: " + ($anchors -join ' ')
    return $line
}


function Resolve-AzDevOpsMentionToken {
    # Resolve one typed token (a name or email) to a teammate record. Prefers a
    # match in the already-synced roster - exact email first, then a name/email
    # substring - so tagging is instant and offline. Falls back to a live
    # identities lookup when the roster has no match, so typing a teammate works
    # even before az-Sync-AzDevOpsTeam has run. Returns $null when nothing matches.
    param(
        [Parameter(Mandatory)] [string] $Token,
        [AllowEmptyCollection()] [object[]] $Roster
    )

    $needle = $Token.Trim()
    if (-not $needle) {
        return $null
    }

    $lower = $needle.ToLowerInvariant()

    $exact = @($Roster | Where-Object {
        $_.Email -and $_.Email.ToLowerInvariant() -eq $lower
    })
    if ($exact.Count -ge 1) {
        $hit = $exact[0]
        return $hit
    }

    $contains = @($Roster | Where-Object {
        ($_.DisplayName -and $_.DisplayName.ToLowerInvariant().Contains($lower)) -or
        ($_.Email -and $_.Email.ToLowerInvariant().Contains($lower))
    })
    if ($contains.Count -ge 1) {
        $hit = $contains[0]
        return $hit
    }

    $live = Resolve-AzDevOpsTeamMember -Identifier $needle
    return $live
}


function ConvertFrom-AzDevOpsMentionInput {
    # Turn a free-text tag field (';'- or ','-separated names/emails) into the
    # teammate records to mention. Each token resolves via Resolve-AzDevOpsMentionToken;
    # unresolved tokens are reported and skipped so one typo doesn't sink the rest.
    # De-dupes by identity id. Blank input returns an empty array.
    param(
        [AllowEmptyString()] [string] $Text,
        [AllowEmptyCollection()] [object[]] $Roster
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    $separators = $script:AzDevOpsListSeparators
    $tokens     = $Text.Split($separators, [StringSplitOptions]::RemoveEmptyEntries)

    $records = New-Object System.Collections.Generic.List[object]
    $seenIds = New-Object System.Collections.Generic.HashSet[string]
    foreach ($token in $tokens) {
        $member = Resolve-AzDevOpsMentionToken -Token $token -Roster $Roster
        if ($null -eq $member -or -not $member.Id) {
            Write-Host "  Could not match '$($token.Trim())' to a teammate - skipping." -ForegroundColor Yellow
            continue
        }

        if ($seenIds.Add($member.Id)) {
            $records.Add($member)
        }
    }

    $result = @($records)
    return $result
}


function Select-AzDevOpsMention {
    # Console teammate tagging for the debriefs that have no WPF form (the
    # non-Windows timer path and the unplanned-work debriefs). A single blank
    # field - no yes/no gate, no grid: type one or more teammates (';'/','-
    # separated names or emails), or leave it blank to tag nobody. Typed tokens
    # resolve against the cached roster first, then a live identities lookup, so
    # it works with or without a prior az-Sync-AzDevOpsTeam. Returns the matched
    # records (possibly empty). A user who has never run az-Sync-AzDevOpsTeam
    # has no roster, so the field is skipped silently rather than shown on every
    # debrief.
    $roster = @(Get-AzDevOpsTeam)
    if ($roster.Count -eq 0) {
        return @()
    }

    $raw = Read-Host 'Tag teammates (; or , separated names/emails, blank = none)'
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $members = ConvertFrom-AzDevOpsMentionInput -Text $raw -Roster $roster
    return $members
}


function az-Sync-AzDevOpsTeam {
    # Refresh the cached tagging roster so the next debrief's tag picker reflects
    # the current team. Pulls a project team's members (`az devops team
    # list-member`) and merges any $env:AZ_TEAM supplement. Run after switching
    # project/team or changing the env var. Uses the Azure DevOps CLI/identities
    # API, so it needs a configured org (same create gate as the write commands).
    [CmdletBinding()]
    param([string] $Team)

    if (-not (Test-AzDevOpsCreateGate -CommandName 'az-Sync-AzDevOpsTeam')) {
        return
    }

    $members = Sync-AzDevOpsTeam -Team $Team
    if ($members.Count -eq 0) {
        $envVar = $script:AzDevOpsTeamEnvVar
        Write-Host "No team members cached. Pick a team with members, or set `$env:$envVar (';'-separated emails)." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "Cached $($members.Count) teammate(s) for debrief tagging:" -ForegroundColor Green
    foreach ($member in $members) {
        Write-Host ("  {0}  <{1}>" -f $member.DisplayName, $member.Email)
    }
}
