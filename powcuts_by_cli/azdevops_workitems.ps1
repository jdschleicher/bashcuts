# ============================================================================
# Azure DevOps — Startup activity digest
# ============================================================================
# az-Show-AzDevOpsDigest: a compact, non-blocking summary of recent Azure
# DevOps activity, printed on shell open (see the guarded call at the tail of
# powcuts_home.ps1) so a fresh terminal shows what's moved since the cache last
# refreshed — without the user running any command.
#
# Cache-only: reads the active project's hierarchy.json directly (raw JSON) so
# it can reach System.CommentCount / System.ChangedDate / System.CreatedDate,
# which the tree/board converted shape (ConvertFrom-AzDevOpsHierarchyItem in
# azdevops_views.ps1) drops. No `az` calls, no new sync. Silent no-op when the
# cache is absent so first-run and not-configured shells print nothing.
#
# Loaded by powcuts_home.ps1. See azdevops_auth.ps1 for the master docstring.

# Requirement-tier types whose open, commented items surface in the "open
# stories with comments" section. Superset of $script:AzDevOpsRequirementTypes
# (adds 'Bug', which some process templates track on the backlog) per the
# issue spec's "User Story / PBI / Bug". Types absent from a given project's
# hierarchy cache simply match nothing, so the extra entries are harmless.
$script:AzDevOpsDigestStoryTypes = @(
    'User Story',
    'Product Backlog Item',
    'Requirement',
    'Issue',
    'Bug'
)


function ConvertTo-AzDevOpsNullableDate {
    # az serializes System.*Date fields as ISO-8601 UTC strings (or omits them
    # entirely). Cast a present value to [datetime] (local); pass $null / empty
    # straight through so the date-window filters treat a missing timestamp as
    # "no activity" rather than throwing on the cast.
    param($Value)

    if ($Value) {
        $date = [datetime]$Value
        return $date
    }

    return $null
}


function ConvertFrom-AzDevOpsDigestItem {
    # Projects one raw hierarchy.json row into the fields the digest windows on.
    # Reaches System.CommentCount / System.CreatedDate / System.ChangedDate,
    # which the tree/board shape drops. A missing CommentCount reads as 0; a
    # missing date reads as $null (never surfaced by the date-window filters).
    param([Parameter(Mandatory)] $Raw)

    $f = $Raw.fields

    $id = if ($f.'System.Id') {
        [int]$f.'System.Id'
    }
    else {
        [int]$Raw.id
    }

    $commentCount = if ($null -ne $f.'System.CommentCount') {
        [int]$f.'System.CommentCount'
    }
    else {
        0
    }

    $changedAt = ConvertTo-AzDevOpsNullableDate -Value $f.'System.ChangedDate'
    $createdAt = ConvertTo-AzDevOpsNullableDate -Value $f.'System.CreatedDate'

    return [PSCustomObject]@{
        Id           = $id
        Type         = $f.'System.WorkItemType'
        State        = $f.'System.State'
        Title        = $f.'System.Title'
        CommentCount = $commentCount
        ChangedDate  = $changedAt
        CreatedDate  = $createdAt
    }
}


function Read-AzDevOpsDigestRows {
    # Reads the active project's hierarchy.json directly (raw JSON) and projects
    # each row through ConvertFrom-AzDevOpsDigestItem. Returns $null when the
    # cache file is absent (first run / not configured) so the digest stays
    # silent; returns @() for a present-but-empty cache.
    #
    # Bypasses the shared Read-AzDevOpsJsonCache memo on purpose: that memo keys
    # only on path + mtime, so the tree view's converted shape (which lacks the
    # comment/created/changed fields) would otherwise be served here for the
    # very same hierarchy.json.
    $paths = Get-AzDevOpsCachePaths
    if (-not $paths -or -not $paths.Hierarchy) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $paths.Hierarchy)) {
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $paths.Hierarchy -Raw | ConvertFrom-Json
    }
    catch {
        return $null
    }

    if ($null -eq $raw) {
        return @()
    }

    $rows = @($raw | ForEach-Object { ConvertFrom-AzDevOpsDigestItem -Raw $_ })
    return $rows
}


function Get-AzDevOpsWeekStart {
    # Midnight on Monday of $From's week (ISO week, Monday-first). DayOfWeek is
    # Sunday=0..Saturday=6; (dow + 6) % 7 gives days since Monday (Mon->0,
    # Sun->6) so subtracting it lands on this week's Monday at 00:00.
    param([Parameter(Mandatory)] [datetime] $From)

    $daysSinceMonday = ([int]$From.DayOfWeek + 6) % 7
    $weekStart = $From.Date.AddDays(-$daysSinceMonday)
    return $weekStart
}


function Format-AzDevOpsDigestRow {
    # One digest line: '  #1234  User Story  Fix the widget [Active]'. Title is
    # truncated to the shared 80-char cap so long titles don't wrap on startup.
    param([Parameter(Mandatory)] $Row)

    $title = Format-AzDevOpsTruncatedTitle -Title $Row.Title
    $line = "  #$($Row.Id)  $($Row.Type)  $title [$($Row.State)]"
    return $line
}


function Write-AzDevOpsDigestSection {
    # Prints a section header + one line per row, only when $Rows is non-empty.
    # A zero-row section prints nothing at all (no header, no blank line) per the
    # issue spec. Write-Host is correct here — this is on-screen status, not
    # pipeable data.
    param(
        [Parameter(Mandatory)] [string] $Header,
        [Parameter(Mandatory)] [AllowEmptyCollection()] $Rows
    )

    $rows = @($Rows)
    if ($rows.Count -eq 0) {
        return
    }

    Write-Host ""
    Write-Host "$Header ($($rows.Count))" -ForegroundColor Cyan

    foreach ($row in $rows) {
        $line = Format-AzDevOpsDigestRow -Row $row
        Write-Host $line
    }
}


function az-Show-AzDevOpsDigest {
    # Compact, non-blocking summary of recent Azure DevOps activity from the
    # cached hierarchy (no `az` calls). Four sections — new comments since
    # yesterday, new items this week, new comments this week, and open stories
    # with comments — each omitted entirely when it has no rows. Silent no-op
    # when the hierarchy cache doesn't exist yet or holds zero rows. Printed
    # automatically on shell open (unless $env:AZ_DEVOPS_NO_DIGEST is set) and
    # runnable on demand.
    [CmdletBinding()]
    param()

    $items = Read-AzDevOpsDigestRows
    if ($null -eq $items) {
        return
    }

    $items = @($items)
    if ($items.Count -eq 0) {
        return
    }

    $now            = Get-Date
    $yesterdayStart = $now.Date.AddDays(-1)
    $weekStart      = Get-AzDevOpsWeekStart -From $now

    $closedStates = Get-AzDevOpsClosedStates
    $storyTypes   = $script:AzDevOpsDigestStoryTypes

    $newCommentsYesterday = @(
        $items | Where-Object {
            $_.CommentCount -gt 0 -and $_.ChangedDate -and $_.ChangedDate -ge $yesterdayStart
        }
    )

    $newItemsThisWeek = @(
        $items | Where-Object {
            $_.CreatedDate -and $_.CreatedDate -ge $weekStart
        }
    )

    $newCommentsThisWeek = @(
        $items | Where-Object {
            $_.CommentCount -gt 0 -and $_.ChangedDate -and $_.ChangedDate -ge $weekStart
        }
    )

    $openStoriesWithComments = @(
        $items | Where-Object {
            $_.CommentCount -gt 0 -and $_.Type -in $storyTypes -and $_.State -notin $closedStates
        }
    )

    $total = $newCommentsYesterday.Count + $newItemsThisWeek.Count +
             $newCommentsThisWeek.Count + $openStoriesWithComments.Count
    if ($total -eq 0) {
        return
    }

    $bannerIcon = "$([char]0x1F4C8)"   # chart increasing
    Write-Host ""
    Write-Host "$bannerIcon Azure DevOps activity digest" -ForegroundColor DarkCyan

    $commentsYesterdaySorted = Sort-AzDevOpsByDateDesc -Items $newCommentsYesterday    -Field 'ChangedDate'
    $itemsThisWeekSorted     = Sort-AzDevOpsByDateDesc -Items $newItemsThisWeek        -Field 'CreatedDate'
    $commentsThisWeekSorted  = Sort-AzDevOpsByDateDesc -Items $newCommentsThisWeek     -Field 'ChangedDate'
    $openStoriesSorted       = Sort-AzDevOpsByDateDesc -Items $openStoriesWithComments -Field 'ChangedDate'

    Write-AzDevOpsDigestSection -Header 'New comments since yesterday' -Rows $commentsYesterdaySorted
    Write-AzDevOpsDigestSection -Header 'New items this week'          -Rows $itemsThisWeekSorted
    Write-AzDevOpsDigestSection -Header 'New comments this week'       -Rows $commentsThisWeekSorted
    Write-AzDevOpsDigestSection -Header 'Open stories with comments'   -Rows $openStoriesSorted
}


function Invoke-AzDevOpsStartupDigest {
    # On-open entry point for the digest. Honors the $env:AZ_DEVOPS_NO_DIGEST
    # opt-out (the manual az-Show-AzDevOpsDigest always renders, opt-out or not)
    # and swallows any error so a digest failure can never break profile load.
    if ($env:AZ_DEVOPS_NO_DIGEST) {
        return
    }

    try {
        az-Show-AzDevOpsDigest
    }
    catch {
        # swallow — the on-open digest is best-effort and must not break the shell
    }
}
