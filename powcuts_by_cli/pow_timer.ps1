# ---------------------------------------------------------------------------
# Timer sessions — integration-agnostic Pomodoro timer with auto-debrief
#
# Public surface:
#   Start-TimerSession         - pick integration -> pick item -> run timer ->
#                                prompt for debrief -> post comment.
#                                Press Esc during the countdown to end early
#                                and still post a debrief.
#   Register-TimerIntegration  - add an integration (Name, Description,
#                                FetchItems, AddComment, optional ViewHint).
#                                Registering with an existing Name replaces it.
#
# Integration contract (each entry of $script:TimerIntegrations):
#   Name        [string]      - display name shown in the picker
#   Description [string]      - one-line subtitle
#   FetchItems  [scriptblock] - returns rows with at least Id, Type, State,
#                               Title; Priority/Iteration optional
#   AddComment  [scriptblock] - param([int]$Id, [string]$Body); posts the
#                               composed debrief comment on the chosen item
#   ViewHint    [scriptblock] - param([int]$Id); returns a one-line string
#                               printed after a successful comment post
#                               (e.g. "View discussion: az-Open-AzDevOpsAssigned 1234")
#
# Azure DevOps integration is registered at the bottom of this file; reads
# $HOME/.bashcuts-cache/azure-devops/assigned.json (populated by
# az-Sync-AzDevOpsCache) and posts via Add-AzDevOpsDiscussionComment.
# ---------------------------------------------------------------------------

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$script:TimerIconSnakeHead  = "$([char]0x1F40D)"
$script:TimerIconSnakeBody  = "$([char]0x1F7E9)"
$script:TimerIconApple      = "$([char]0x1F34E)"
$script:TimerIconClock      = "$([char]0x23F0)"
$script:TimerIconCheck      = "$([char]0x2705)"
$script:TimerIconWarn       = "$([char]0x26A0)$([char]0xFE0F)"
$script:TimerIconMemo       = "$([char]0x1F4DD)"
$script:TimerIconRocket     = "$([char]0x1F680)"
$script:TimerIconWave       = "$([char]0x1F44B)"
$script:TimerIconFinish     = "$([char]0x1F3C1)"

$script:TimerMaxSnakeLength = 15
$script:TimerDefaultMinutes = 25
$script:TimerPollIntervalMs = 100
$script:TimerPollsPerSecond = 10

$script:TimerIntegrations = @()


function Test-TimerGridAvailable {
    $cmd = Get-Command Out-ConsoleGridView -ErrorAction SilentlyContinue
    $available = ($null -ne $cmd)
    return $available
}


function Format-TimerElapsed {
    param([Parameter(Mandatory)] [int] $Seconds)

    $minutes = [math]::Floor($Seconds / 60)
    $rem = $Seconds % 60
    $display = '{0:D2}:{1:D2}' -f $minutes, $rem
    return $display
}


function Read-TimerYesNo {
    param(
        [Parameter(Mandatory)] [string] $Prompt,
        [switch] $DefaultYes
    )

    $suffix = if ($DefaultYes) {
        '[Y/n]'
    } else {
        '[y/N]'
    }

    $raw = Read-Host "$Prompt $suffix"
    if (-not $raw) {
        $result = [bool]$DefaultYes
        return $result
    }

    $normalized = $raw.Trim().ToLowerInvariant()
    $result = ($normalized -eq 'y' -or $normalized -eq 'yes')
    return $result
}


function Read-TimerNumberedPick {
    # Fallback picker for terminals without Out-ConsoleGridView. Blank input
    # cancels (returns $null); out-of-range / non-numeric input also cancels
    # with a hint.
    param(
        [Parameter(Mandatory)] $Items,
        [Parameter(Mandatory)] [string] $DisplayProperty,
        [Parameter(Mandatory)] [string] $Title
    )

    $list = @($Items)
    if ($list.Count -eq 0) {
        return $null
    }

    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    for ($i = 0; $i -lt $list.Count; $i++) {
        $n = $i + 1
        $label = $list[$i].$DisplayProperty
        Write-Host "  [$n] $label"
    }

    $raw = Read-Host "Enter a number (blank to cancel)"
    if (-not $raw) {
        return $null
    }

    $idx = 0
    if (-not [int]::TryParse($raw, [ref]$idx)) {
        Write-Host "Not a number — exiting." -ForegroundColor Yellow
        return $null
    }

    if ($idx -lt 1 -or $idx -gt $list.Count) {
        Write-Host "Out of range — exiting." -ForegroundColor Yellow
        return $null
    }

    $picked = $list[$idx - 1]
    return $picked
}


function Register-TimerIntegration {
    # Append (or replace by Name) an integration entry to
    # $script:TimerIntegrations. Replace-on-collision lets the user override
    # the built-in AzDO integration from their $profile without editing
    # tracked code.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]      $Name,
        [Parameter(Mandatory)] [string]      $Description,
        [Parameter(Mandatory)] [scriptblock] $FetchItems,
        [Parameter(Mandatory)] [scriptblock] $AddComment,
        [scriptblock] $ViewHint
    )

    $entry = [PSCustomObject]@{
        Name        = $Name
        Description = $Description
        FetchItems  = $FetchItems
        AddComment  = $AddComment
        ViewHint    = $ViewHint
    }

    $existing = @($script:TimerIntegrations | Where-Object { $_.Name -eq $Name })
    if ($existing.Count -gt 0) {
        Write-Host "Replacing existing timer integration '$Name'." -ForegroundColor Yellow
        $script:TimerIntegrations = @($script:TimerIntegrations | Where-Object { $_.Name -ne $Name })
    }

    $script:TimerIntegrations = @($script:TimerIntegrations) + $entry
}


function Get-TimerIntegrationPick {
    # When -Name is supplied, return the matching integration (or $null with
    # a hint listing the registered names). Otherwise show the picker; with
    # only one registered, return it without prompting.
    param([string] $Name)

    $integrations = @($script:TimerIntegrations)

    if ($Name) {
        $match = $integrations | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
        if (-not $match) {
            Write-Host "No registered integration named '$Name'. Available:" -ForegroundColor Yellow
            foreach ($i in $integrations) {
                Write-Host "  - $($i.Name)" -ForegroundColor DarkGray
            }
            return $null
        }
        return $match
    }

    if ($integrations.Count -eq 1) {
        return $integrations[0]
    }

    $rows = @($integrations | Select-Object Name, Description)
    $title = "Pick a timer integration ($($integrations.Count) registered)"

    if (Test-TimerGridAvailable) {
        $picked = $rows | Out-ConsoleGridView -Title $title -OutputMode Single
        if (-not $picked) {
            return $null
        }
        $match = $integrations | Where-Object { $_.Name -eq $picked.Name } | Select-Object -First 1
        return $match
    }

    $fallback = Read-TimerNumberedPick -Items $integrations -DisplayProperty 'Name' -Title $title
    return $fallback
}


function Get-TimerItemPick {
    param(
        [Parameter(Mandatory)] $Items,
        [Parameter(Mandatory)] [string] $IntegrationName
    )

    $rows = @($Items)
    if ($rows.Count -eq 0) {
        return $null
    }

    $title = "$IntegrationName — pick an item ($($rows.Count))"

    if (Test-TimerGridAvailable) {
        $picked = $rows | Out-ConsoleGridView -Title $title -OutputMode Single
        return $picked
    }

    $fallback = Read-TimerNumberedPick -Items $rows -DisplayProperty 'Title' -Title $title
    return $fallback
}


function Show-TimerCountdown {
    # Snake-animation countdown. Each elapsed second redraws the frame; the
    # per-second wait is split into ~100ms key polls so Esc interrupts feel
    # immediate without making the animation flicker. Returns the outcome so
    # the orchestrator can branch on Interrupted.
    param([Parameter(Mandatory)] [int] $Seconds)

    $iconSnakeHead = $script:TimerIconSnakeHead
    $iconSnakeBody = $script:TimerIconSnakeBody
    $iconApple     = $script:TimerIconApple
    $iconClock     = $script:TimerIconClock

    $maxSnakeLength = $script:TimerMaxSnakeLength
    $pollIntervalMs = $script:TimerPollIntervalMs
    $pollsPerSecond = $script:TimerPollsPerSecond

    $interrupted = $false
    $elapsed = 0

    while ($elapsed -le $Seconds) {
        $remaining = $Seconds - $elapsed
        $currentLength = [math]::Floor(($elapsed / $Seconds) * $maxSnakeLength)
        $snakeBody = $iconSnakeBody * $currentLength
        $spacer = '  ' * ($maxSnakeLength - $currentLength)

        Clear-Host
        Write-Host "`n`n      SNAKE FOCUS SESSION" -ForegroundColor Green
        Write-Host "      ┌────────────────────────────────────────┐"
        Write-Host "      │ " -NoNewline
        Write-Host "$snakeBody$iconSnakeHead" -NoNewline
        Write-Host "$spacer" -NoNewline
        Write-Host "$iconApple │"
        Write-Host "      └────────────────────────────────────────┘"

        $remainingDisplay = Format-TimerElapsed -Seconds $remaining
        Write-Host "`n      $iconClock TIME UNTIL DEBRIEF: $remainingDisplay" -ForegroundColor Yellow
        Write-Host "      (Press Esc to debrief early)" -ForegroundColor DarkGray

        if ($remaining -le 0) {
            break
        }

        for ($p = 0; $p -lt $pollsPerSecond; $p++) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::Escape) {
                    $interrupted = $true
                    break
                }
            }
            Start-Sleep -Milliseconds $pollIntervalMs
        }

        if ($interrupted) {
            break
        }

        $elapsed++
    }

    return [PSCustomObject]@{
        ElapsedSeconds = $elapsed
        TotalSeconds   = $Seconds
        Interrupted    = $interrupted
    }
}


function Format-TimerCommentBody {
    # Compose the discussion-comment text. Header reflects outcome; body has
    # labeled Debrief and Next sections; a trailing attribution line lets a
    # reader trace the comment back to this command.
    param(
        [Parameter(Mandatory)] [bool]   $Interrupted,
        [Parameter(Mandatory)] [int]    $ElapsedSeconds,
        [Parameter(Mandatory)] [int]    $TotalSeconds,
        [Parameter(Mandatory)] [string] $Debrief,
        [Parameter(Mandatory)] [string] $Next
    )

    $iconCheck  = $script:TimerIconCheck
    $iconWarn   = $script:TimerIconWarn
    $iconMemo   = $script:TimerIconMemo
    $iconRocket = $script:TimerIconRocket

    $elapsedDisplay = Format-TimerElapsed -Seconds $ElapsedSeconds
    $totalDisplay   = Format-TimerElapsed -Seconds $TotalSeconds
    $timestamp      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    $header = if ($Interrupted) {
        "$iconWarn Session interrupted at $elapsedDisplay of $totalDisplay"
    } else {
        "$iconCheck Pomodoro complete — $totalDisplay"
    }

    $lines = @(
        $header,
        "_$timestamp_",
        '',
        "$iconMemo Debrief:",
        $Debrief,
        '',
        "$iconRocket Next:",
        $Next,
        '',
        '_via bashcuts Start-TimerSession_'
    )

    $body = $lines -join "`r`n"
    return $body
}


function Start-TimerSession {
    # Orchestrator. Pick an integration (or use -Integration to skip),
    # fetch + pick an item, run the snake countdown (Esc to end early),
    # prompt for debrief notes, post the composed comment via the chosen
    # integration's AddComment. On an Esc-interrupted session also prompt
    # whether to start another session — same -Minutes, fresh integration
    # / item pick so the user can pivot to a different story.
    [CmdletBinding()]
    param(
        [ValidateRange(1, [int]::MaxValue)] [int] $Minutes = $script:TimerDefaultMinutes,
        [string] $Integration
    )

    $integrations = @($script:TimerIntegrations)
    if ($integrations.Count -eq 0) {
        Write-Host "No timer integrations registered. Add one via Register-TimerIntegration." -ForegroundColor Yellow
        return
    }

    $chosen = Get-TimerIntegrationPick -Name $Integration
    if (-not $chosen) {
        Write-Host "No integration selected — exiting." -ForegroundColor DarkGray
        return
    }

    Write-Host "Fetching items from '$($chosen.Name)'..." -ForegroundColor Cyan
    $items = & $chosen.FetchItems
    if (-not $items -or @($items).Count -eq 0) {
        Write-Host "No items returned from '$($chosen.Name)'." -ForegroundColor Yellow
        return
    }

    $pickedItem = Get-TimerItemPick -Items $items -IntegrationName $chosen.Name
    if (-not $pickedItem) {
        Write-Host "No item selected — exiting." -ForegroundColor DarkGray
        return
    }

    Write-Host ""
    Write-Host "Starting $Minutes-minute session on item $($pickedItem.Id): $($pickedItem.Title)" -ForegroundColor Green
    Start-Sleep -Seconds 2

    $seconds = $Minutes * 60
    $countdownResult = Show-TimerCountdown -Seconds $seconds

    Clear-Host
    $finishIcon = $script:TimerIconFinish
    Write-Host "$finishIcon SESSION COMPLETE! $finishIcon" -ForegroundColor Green

    $memoIcon = $script:TimerIconMemo
    $rocketIcon = $script:TimerIconRocket
    $debrief = Read-Host "$memoIcon Enter your debrief notes"
    $next    = Read-Host "$rocketIcon What's next"

    $body = Format-TimerCommentBody `
        -Interrupted    $countdownResult.Interrupted `
        -ElapsedSeconds $countdownResult.ElapsedSeconds `
        -TotalSeconds   $countdownResult.TotalSeconds `
        -Debrief        $debrief `
        -Next           $next

    Write-Host ""
    Write-Host "Posting debrief comment to item $($pickedItem.Id)..." -ForegroundColor Cyan
    $commentResult = & $chosen.AddComment -Id $pickedItem.Id -Body $body

    $exitCode = if ($commentResult -and $commentResult.PSObject.Properties['ExitCode']) {
        $commentResult.ExitCode
    } else {
        0
    }

    $checkIcon = $script:TimerIconCheck
    $warnIcon  = $script:TimerIconWarn

    if ($exitCode -eq 0) {
        Write-Host "$checkIcon Comment posted on item $($pickedItem.Id)." -ForegroundColor Green
        if ($chosen.ViewHint) {
            $hint = & $chosen.ViewHint -Id $pickedItem.Id
            if ($hint) {
                Write-Host "   $hint" -ForegroundColor DarkGray
            }
        }
    } else {
        Write-Host "$warnIcon Comment post failed (exit=$exitCode)." -ForegroundColor Red
        if ($commentResult -and $commentResult.Error) {
            Write-Host "   $($commentResult.Error)" -ForegroundColor Red
        }
    }

    if ($countdownResult.Interrupted) {
        $startAnother = Read-TimerYesNo -Prompt 'Start a new session?' -DefaultYes
        if ($startAnother) {
            Start-TimerSession -Minutes $Minutes
            return
        }
        $waveIcon = $script:TimerIconWave
        Write-Host "Goodbye $waveIcon" -ForegroundColor DarkGray
    }
}


# ---------------------------------------------------------------------------
# Default integration: Azure DevOps - User Stories
#
# Reads the existing assigned-items cache (populated by az-Sync-AzDevOpsCache),
# filters out closed states, sorts by State -> Priority asc -> AssignedAt desc
# (null priorities sort last via [int]::MaxValue substitution), and surfaces
# Id / Type / State / Priority / Title / Iteration in the picker. Posts the
# debrief through the Add-AzDevOpsDiscussionComment wrapper in azdevops_db.ps1.
# ---------------------------------------------------------------------------

Register-TimerIntegration `
    -Name        'Azure DevOps - User Stories' `
    -Description 'Pick from cached AzDO assigned work items, sorted by State + Priority' `
    -FetchItems  {
        $cache = Read-AzDevOpsAssignedCache
        if ($null -eq $cache) {
            return @()
        }

        $active = Select-AzDevOpsActiveItems -Items $cache

        $priorityExpr = {
            if ($null -eq $_.Priority) {
                [int]::MaxValue
            } else {
                $_.Priority
            }
        }

        $sorted = $active | Sort-Object `
            @{Expression = 'State'; Ascending = $true},
            @{Expression = $priorityExpr; Ascending = $true},
            @{Expression = 'AssignedAt'; Descending = $true}

        $rows = @($sorted | Select-Object Id, Type, State, Priority, Title, Iteration)
        return $rows
    } `
    -AddComment  {
        param(
            [Parameter(Mandatory)] [int]    $Id,
            [Parameter(Mandatory)] [string] $Body
        )
        $result = Add-AzDevOpsDiscussionComment -Id $Id -Body $Body
        return $result
    } `
    -ViewHint    {
        param([Parameter(Mandatory)] [int] $Id)
        $hint = "View discussion: az-Open-AzDevOpsAssigned $Id"
        return $hint
    }
