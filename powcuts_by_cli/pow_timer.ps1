# ---------------------------------------------------------------------------
# Timer sessions — integration-agnostic Pomodoro timer with auto-debrief
#
# Public surface:
#   Start-TimerSession         - pick integration -> pick item -> run timer ->
#                                collect debrief -> post comment. On Windows the
#                                countdown morphs into a themed WPF debrief form
#                                (Show-WpfTimerDebrief) that posts under a spinner
#                                and loops back to a fresh timer; elsewhere the
#                                debrief is collected via terminal Read-Host with
#                                a console posting indicator. Press Esc during the
#                                countdown to end early and still post a debrief.
#   Register-TimerIntegration  - add an integration (Name, Description,
#                                FetchItems, AddComment, optional ViewHint,
#                                optional CloseItem). Registering with an
#                                existing Name replaces it.
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
#                               (e.g. "View discussion: az-Open-WorkItemById 1234")
#   CloseItem   [scriptblock] - optional; param([int]$Id); transitions the work
#                               item to its done state. Azure DevOps maps this
#                               to System.State=$script:TimerCloseState (default
#                               'Resolved'). When provided, the debrief surfaces
#                               a "Work complete — resolve this story" checkbox
#                               (WPF) / "Resolve this item now? [y/N]" prompt
#                               (terminal) that fires only after a successful
#                               AddComment.
#
# Azure DevOps integration is registered at the bottom of this file; reads
# $HOME/.bashcuts-cache/azure-devops/assigned.json (populated by
# az-Sync-AzDevOpsCache) and posts via Add-AzDevOpsDiscussionComment.
# ---------------------------------------------------------------------------

$script:TimerIconSnakeHead  = [char]::ConvertFromUtf32(0x1F40D)
$script:TimerIconSnakeBody  = [char]::ConvertFromUtf32(0x1F7E9)
$script:TimerIconApple      = [char]::ConvertFromUtf32(0x1F34E)
$script:TimerIconClock      = [char]::ConvertFromUtf32(0x23F0)
$script:TimerIconCheck      = [char]::ConvertFromUtf32(0x2705)
$script:TimerIconWarn       = "$([char]::ConvertFromUtf32(0x26A0))$([char]::ConvertFromUtf32(0xFE0F))"
$script:TimerIconMemo       = [char]::ConvertFromUtf32(0x1F4DD)
$script:TimerIconRocket     = [char]::ConvertFromUtf32(0x1F680)
$script:TimerIconWave       = [char]::ConvertFromUtf32(0x1F44B)
$script:TimerIconFinish     = [char]::ConvertFromUtf32(0x1F3C1)

$script:TimerMaxSnakeLength = 15
$script:TimerDefaultMinutes = 25
$script:TimerPollIntervalMs = 100
$script:TimerPollsPerSecond = 10

$script:TimerIntegrations = @()

$script:TimerCloseState = 'Resolved'

$script:WpfColorBackground = '#2D2D30'
$script:WpfColorStroke     = '#444444'
$script:WpfColorProgress   = '#007ACC'
$script:WpfColorButton     = '#3E3E42'
$script:WpfColorHint       = '#888888'

$script:WpfWindowSize   = 260
$script:WpfCircleCenter = 130
$script:WpfCircleRadius = 124
$script:WpfArcStartX    = 130
$script:WpfArcStartY    = 6

$script:WpfColorProgressUnplanned = '#D97706'
$script:WpfStopwatchMaxSeconds    = 3600


function Test-TimerEscPressed {
    # Non-blocking probe for an Esc keypress. Guarded so the timer still
    # runs in hosts that don't expose [Console]::KeyAvailable / ReadKey
    # (some VS Code integrated-terminal configs, pwsh -NonInteractive,
    # redirected stdin) — in those hosts the Esc-to-debrief affordance is
    # silently disabled and the timer runs to completion.
    try {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Escape) {
                return $true
            }
        }
    } catch {
        # Host does not expose console keyboard — treat as no key pressed.
    }

    return $false
}


function Format-TimerElapsed {
    param([Parameter(Mandatory)] [int] $Seconds)

    $minutes = [math]::Floor($Seconds / 60)
    $rem = $Seconds % 60
    $display = '{0:00}:{1:00}' -f $minutes, $rem
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


function Read-TimerNextAction {
    # Console counterpart to the WPF debrief's restart buttons. Offers the same
    # three-way choice and returns the shared action token: 'SameItem' reuses
    # the work item just debriefed, 'NewItem' returns to the picker, 'Done'
    # (also the blank/unrecognized default) ends the loop.
    param(
        [Parameter(Mandatory)] [string] $ItemLabel
    )

    Write-Host ""
    Write-Host "Start another session?" -ForegroundColor Cyan
    Write-Host "  [s] Same item — $ItemLabel"
    Write-Host "  [p] Pick another item"
    Write-Host "  [d] Done"

    $raw = Read-Host "Choose [s/p/D]"
    if (-not $raw) {
        return 'Done'
    }

    $normalized = $raw.Trim().ToLowerInvariant()
    switch ($normalized) {
        's' {
            return 'SameItem'
        }

        'same' {
            return 'SameItem'
        }

        'p' {
            return 'NewItem'
        }

        'pick' {
            return 'NewItem'
        }

        default {
            return 'Done'
        }
    }
}


function Resolve-TimerNextAction {
    # Maps a debrief next-action token ('Done' / 'SameItem' / 'NewItem') to the
    # restart-loop flags shared by the WPF and console paths, so both decide
    # "restart? reuse the item?" through one branch instead of duplicating it.
    param(
        [Parameter(Mandatory)] [string] $Action
    )

    $shouldRestart = ($Action -eq 'SameItem' -or $Action -eq 'NewItem')
    $reuseItem     = ($Action -eq 'SameItem')

    $result = [PSCustomObject]@{
        ShouldRestart = $shouldRestart
        ReuseItem     = $reuseItem
    }
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


function Read-TimerPick {
    # Centralizes the grid-vs-fallback decision used by both picker
    # functions. Returns the selected row (PSCustomObject) or $null on
    # cancel / empty list.
    param(
        [Parameter(Mandatory)] $Items,
        [Parameter(Mandatory)] [string] $DisplayProperty,
        [Parameter(Mandatory)] [string] $Title
    )

    $rows = @($Items)
    if ($rows.Count -eq 0) {
        return $null
    }

    if (Test-ConsoleGridAvailable) {
        $picked = $rows | Out-ConsoleGridView -Title $Title -OutputMode Single
        return $picked
    }

    $fallback = Read-TimerNumberedPick -Items $rows -DisplayProperty $DisplayProperty -Title $Title
    return $fallback
}


function az-Register-TimerIntegration {
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
        [scriptblock] $ViewHint,
        [scriptblock] $CloseItem
    )

    $entry = [PSCustomObject]@{
        Name        = $Name
        Description = $Description
        FetchItems  = $FetchItems
        AddComment  = $AddComment
        ViewHint    = $ViewHint
        CloseItem   = $CloseItem
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

    $picked = Read-TimerPick -Items $rows -DisplayProperty 'Name' -Title $title
    if (-not $picked) {
        return $null
    }

    $match = $integrations | Where-Object { $_.Name -eq $picked.Name } | Select-Object -First 1
    return $match
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
    $picked = Read-TimerPick -Items $rows -DisplayProperty 'Title' -Title $title
    return $picked
}


function Show-TimerCountdown {
    # Delegates to the WPF circular overlay on Windows; falls back to the
    # snake-animation on macOS / Linux. Returns the same outcome shape in
    # both paths so the orchestrator (az-Start-TimerSession) is unchanged.
    param([Parameter(Mandatory)] [int] $Seconds)

    $onWindows = Test-WpfIsWindows

    if ($onWindows) {
        $result = Show-WpfTimerCountdown -Seconds $Seconds
        return $result
    }

    # ---- Snake-animation fallback (macOS / Linux) ----

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
            if (Test-TimerEscPressed) {
                $interrupted = $true
                break
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


function Show-WpfTimerCountdown {
    # WPF circular overlay countdown for Windows. Returns the same result shape
    # as Show-TimerCountdown so az-Start-TimerSession needs no changes.
    # If "Capture Story" is clicked the overlay closes, az-New-AzDevOpsUserStory
    # runs in the terminal, then the overlay reopens with the remaining time.
    param([Parameter(Mandatory)] [int] $Seconds)

    Add-Type -AssemblyName PresentationFramework, WindowsBase, PresentationCore

    $flashMaxTicks  = 15
    $defaultSeconds = $Seconds

    $Script:WpfTimeRemaining = [double]$Seconds
    $Script:WpfTotalSeconds  = [double]$Seconds
    $Script:WpfOutcome       = 'Complete'

    $brushes = New-WpfBrushSet -ProgressColor $script:WpfColorProgress

    do {
        $Script:WpfOutcome    = 'Complete'
        $Script:WpfIsFlashing = $false
        $Script:WpfFlashCount = 0

        # ---- Build window ----

        $circleRes  = New-WpfCircleResources -Title 'Timer Session' -Brushes $brushes
        $mainWin    = $circleRes.Window
        $circleGrid = $circleRes.Grid
        $mainCircle = $circleRes.MainCircle
        $arcSegment = $circleRes.ArcSegment

        $vbox = New-Object System.Windows.Controls.StackPanel -Property @{
            VerticalAlignment   = 'Center'
            HorizontalAlignment = 'Center'
        }

        $clockText = New-Object System.Windows.Controls.TextBlock -Property @{
            Text                = '00:00.0'
            FontSize            = 34
            FontFamily          = 'Consolas'
            Foreground          = $brushes.White
            HorizontalAlignment = 'Center'
            Margin              = '0,0,0,8'
            Cursor              = [System.Windows.Input.Cursors]::Hand
        }
        $vbox.Children.Add($clockText) | Out-Null

        $adjustRow = New-Object System.Windows.Controls.StackPanel -Property @{
            Orientation         = 'Horizontal'
            HorizontalAlignment = 'Center'
            Margin              = '0,0,0,5'
        }
        $btnPlus5 = New-Object System.Windows.Controls.Button -Property @{
            Content    = '+5 Min'
            Width      = 55
            Height     = 22
            Background = $brushes.Button
            Foreground = $brushes.White
            Margin     = 2
        }
        $btnPlus10 = New-Object System.Windows.Controls.Button -Property @{
            Content    = '+10 Min'
            Width      = 55
            Height     = 22
            Background = $brushes.Button
            Foreground = $brushes.White
            Margin     = 2
        }
        $adjustRow.Children.Add($btnPlus5)  | Out-Null
        $adjustRow.Children.Add($btnPlus10) | Out-Null
        $vbox.Children.Add($adjustRow) | Out-Null

        $pomoRow = New-Object System.Windows.Controls.StackPanel -Property @{
            Orientation         = 'Horizontal'
            HorizontalAlignment = 'Center'
            Margin              = '0,0,0,5'
        }
        $btnNewPomo = New-Object System.Windows.Controls.Button -Property @{
            Content    = 'New Pomodoro'
            Width      = 120
            Height     = 24
            Background = $brushes.Button
            Foreground = $brushes.White
        }
        $pomoRow.Children.Add($btnNewPomo) | Out-Null
        $vbox.Children.Add($pomoRow) | Out-Null

        $actionRow = New-Object System.Windows.Controls.StackPanel -Property @{
            Orientation         = 'Horizontal'
            HorizontalAlignment = 'Center'
            Margin              = '0,0,0,5'
        }
        $btnCapture = New-Object System.Windows.Controls.Button -Property @{
            Content    = 'Create New Story'
            Width      = 92
            Height     = 22
            Background = $brushes.Button
            Foreground = $brushes.White
            Margin     = 2
        }
        $btnComplete = New-Object System.Windows.Controls.Button -Property @{
            Content    = 'Mark Complete'
            Width      = 92
            Height     = 22
            Background = $brushes.Button
            Foreground = $brushes.White
            Margin     = 2
        }
        $actionRow.Children.Add($btnCapture)  | Out-Null
        $actionRow.Children.Add($btnComplete) | Out-Null
        $vbox.Children.Add($actionRow) | Out-Null

        $exitHint = New-Object System.Windows.Controls.TextBlock -Property @{
            Text                = 'Click time to pause  ·  Right-click to exit'
            FontSize            = 9
            Foreground          = $brushes.Hint
            HorizontalAlignment = 'Center'
            Margin              = '0,8,0,0'
        }
        $vbox.Children.Add($exitHint) | Out-Null

        $circleGrid.Children.Add($vbox) | Out-Null

        # ---- Timer state and UI update helper ----

        $updateUi = {
            if ($Script:WpfTimeRemaining -le 0) {
                $Script:WpfTimeRemaining = 0
            }

            $ts = [TimeSpan]::FromSeconds($Script:WpfTimeRemaining)
            $clockText.Text = $ts.ToString('mm\:ss\.f')

            if ($Script:WpfTotalSeconds -gt 0) {
                $pct = $Script:WpfTimeRemaining / $Script:WpfTotalSeconds
                Set-WpfArcPoint -Pct $pct -ArcSegment $arcSegment
            }
        }

        $clockTick = New-Object System.Windows.Threading.DispatcherTimer -Property @{
            Interval = [TimeSpan]::FromMilliseconds(100)
        }

        $flashTick = New-Object System.Windows.Threading.DispatcherTimer -Property @{
            Interval = [TimeSpan]::FromMilliseconds(300)
        }

        # ---- Event handlers ----

        $mainWin.Add_MouseLeftButtonDown({ $mainWin.DragMove() })

        $mainWin.Add_MouseRightButtonDown({
            $clockTick.Stop()
            $flashTick.Stop()
            $Script:WpfOutcome = 'Interrupted'
            $mainWin.Close()
        })

        $clockText.Add_MouseLeftButtonDown({
            if ($Script:WpfTimeRemaining -le 0) {
                return
            }

            $flashTick.Stop()
            $mainCircle.Fill = $brushes.Bg

            if ($clockTick.IsEnabled) {
                $clockTick.Stop()
            } else {
                $clockTick.Start()
            }

            $args[1].Handled = $true
        })

        $clockTick.Add_Tick({
            $Script:WpfTimeRemaining -= 0.1
            & $updateUi

            if ($Script:WpfTimeRemaining -le 0) {
                $clockTick.Stop()
                $Script:WpfFlashCount = 0
                $flashTick.Start()
            }
        })

        $flashTick.Add_Tick({
            $Script:WpfFlashCount++

            if ($Script:WpfFlashCount -ge $flashMaxTicks) {
                $flashTick.Stop()
                $mainCircle.Fill = $brushes.Bg
                $mainWin.Close()
                return
            }

            if ($Script:WpfIsFlashing) {
                $mainCircle.Fill      = $brushes.Bg
                $Script:WpfIsFlashing = $false
            } else {
                $mainCircle.Fill      = $brushes.DarkRed
                $Script:WpfIsFlashing = $true
            }
        })

        $btnPlus5.Add_Click({
            $wasExpired = ($Script:WpfTimeRemaining -le 0)

            $Script:WpfTotalSeconds   += 300
            $Script:WpfTimeRemaining  += 300
            & $updateUi

            if ($wasExpired) {
                $flashTick.Stop()
                $mainCircle.Fill = $brushes.Bg
                $clockTick.Start()
            }
        })

        $btnPlus10.Add_Click({
            $wasExpired = ($Script:WpfTimeRemaining -le 0)

            $Script:WpfTotalSeconds   += 600
            $Script:WpfTimeRemaining  += 600
            & $updateUi

            if ($wasExpired) {
                $flashTick.Stop()
                $mainCircle.Fill = $brushes.Bg
                $clockTick.Start()
            }
        })

        $btnNewPomo.Add_Click({
            $flashTick.Stop()
            $mainCircle.Fill         = $brushes.Bg
            $Script:WpfTotalSeconds  = [double]$defaultSeconds
            $Script:WpfTimeRemaining = $Script:WpfTotalSeconds
            & $updateUi

            $clockTick.Start()
        })

        $btnCapture.Add_Click({
            $clockTick.Stop()
            $flashTick.Stop()
            $Script:WpfOutcome = 'CaptureStory'
            $mainWin.Close()
        })

        $btnComplete.Add_Click({
            $confirmMsg    = 'End this session early and go to debrief?'
            $confirmTitle  = 'Mark Complete Early'
            $confirmResult = [System.Windows.MessageBox]::Show(
                $confirmMsg,
                $confirmTitle,
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Question
            )

            if ($confirmResult -eq [System.Windows.MessageBoxResult]::Yes) {
                $clockTick.Stop()
                $flashTick.Stop()
                $Script:WpfOutcome = 'Interrupted'
                $mainWin.Close()
            }
        })

        # ---- Show ----

        & $updateUi
        $clockTick.Start()
        $mainWin.ShowDialog() | Out-Null

        if ($Script:WpfOutcome -eq 'CaptureStory') {
            az-New-AzDevOpsUserStory
        }

    } while ($Script:WpfOutcome -eq 'CaptureStory')

    $elapsed     = [int]($Seconds - $Script:WpfTimeRemaining)
    $interrupted = ($Script:WpfOutcome -eq 'Interrupted')

    $result = [PSCustomObject]@{
        ElapsedSeconds = $elapsed
        TotalSeconds   = $Seconds
        Interrupted    = $interrupted
    }
    return $result
}


function Format-TimerCommentBody {
    # Compose the discussion-comment text. Header reflects outcome; body has
    # labeled Debrief and Next sections; a trailing attribution line lets a
    # reader trace the comment back to this command.
    #
    # The body is a SINGLE physical line with HTML <br/> separators. On
    # Windows, PowerShell launches az.cmd via cmd.exe /c, which truncates the
    # `--discussion` value at the first CRLF — so a `"`r`n"`-joined body
    # arrived at Azure DevOps as only the header line. The AzDO Discussion
    # field stores HTML, so <br/> renders as a visible line break in the UI
    # and keeps the entire body intact through the shell hand-off. Italic
    # accents use <em> for the same reason — Markdown `_..._` would render
    # as literal underscores in an HTML field.
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
        "<em>$timestamp</em>",
        '',
        "$iconMemo Debrief:",
        $Debrief,
        '',
        "$iconRocket Next:",
        $Next,
        '',
        '<em>via bashcuts Start-TimerSession</em>'
    )

    $body = $lines -join '<br/>'
    return $body
}


function Get-TimerResultExitCode {
    # Names the "missing ExitCode means success (0)" contract for an AddComment
    # envelope ({ Json, Error, ExitCode }) in one place, so both the console
    # verdict and the WPF post-gate read the outcome the same way.
    param([Parameter(Mandatory)] $Result)

    $exitCode = if ($Result -and $Result.PSObject.Properties['ExitCode']) {
        $Result.ExitCode
    } else {
        0
    }

    return $exitCode
}


function Write-TimerPostVerdict {
    # Prints the post-comment verdict shared by both the WPF and terminal
    # debrief paths: a green check + optional ViewHint on success, a red warning
    # + error text on failure. $Result is the integration's AddComment envelope
    # ({ Json, Error, ExitCode }); a missing ExitCode is treated as success (0).
    param(
        [Parameter(Mandatory)] $Result,
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)] $Integration
    )

    $exitCode = Get-TimerResultExitCode -Result $Result

    $checkIcon = $script:TimerIconCheck
    $warnIcon  = $script:TimerIconWarn

    if ($exitCode -eq 0) {
        Write-Host "$checkIcon Comment posted on item $($Item.Id)." -ForegroundColor Green

        if ($Integration.ViewHint) {
            $hint = & $Integration.ViewHint -Id $Item.Id
            if ($hint) {
                Write-Host "   $hint" -ForegroundColor DarkGray
            }
        }

    } else {

        Write-Host "$warnIcon Comment post failed (exit=$exitCode)." -ForegroundColor Red
        if ($Result -and $Result.Error) {
            Write-Host "   $($Result.Error)" -ForegroundColor Red
        }
    }
}


function Write-TimerResolveVerdict {
    # Prints the resolve-item verdict shared by both the WPF and terminal
    # debrief paths after a successful comment post: a green check naming the
    # target state on success, a red warning + error text on failure. $Result
    # is the integration's CloseItem envelope ({ Json, Error, ExitCode }); a
    # missing ExitCode is treated as success (0).
    param(
        [Parameter(Mandatory)] $Result,
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)] [string] $CloseState
    )

    $exitCode = Get-TimerResultExitCode -Result $Result

    $checkIcon = $script:TimerIconCheck
    $warnIcon  = $script:TimerIconWarn

    if ($exitCode -eq 0) {
        Write-Host "$checkIcon Item $($Item.Id) resolved (State=$CloseState)." -ForegroundColor Green

    } else {

        Write-Host "$warnIcon Resolve failed (exit=$exitCode). Comment was posted; state unchanged." -ForegroundColor Red
        if ($Result -and $Result.Error) {
            Write-Host "   $($Result.Error)" -ForegroundColor Red
        }
    }
}


function New-TimerCloseScript {
    # Builds the closure that invokes the chosen integration's CloseItem against
    # the picked item's Id. Both orchestrator branches (WPF debrief CloseAction +
    # terminal Invoke-WithSpinner) need the same { & $chosen.CloseItem -Id
    # $pickedItem.Id; return $closed }.GetNewClosure() shape, so they share this
    # helper instead of inlining it twice.
    param(
        [Parameter(Mandatory)] $Integration,
        [Parameter(Mandatory)] $Item
    )

    $closeScript = {
        $closed = & $Integration.CloseItem -Id $Item.Id
        return $closed
    }.GetNewClosure()

    return $closeScript
}


function Show-WpfTimerDebrief {
    # Windows-only themed debrief form the countdown overlay morphs into. Two
    # multiline fields (Debrief + Next) share the timer's dark/blue theme. On
    # Post the form disables the button, shows a spinner, and runs -SubmitAction
    # (which composes + posts the comment and returns the { Json, Error,
    # ExitCode } envelope). The "Start another session?" choice is revealed ONLY
    # after a successful post (ExitCode 0); a failed post keeps the form open
    # with the error so the user can retry. The "Start another?" choice offers
    # "Same item" (reuse the work item just debriefed), "Pick another" (return
    # to the picker), and "Done". When -CloseAction is supplied, a "Work
    # complete — resolve this story" checkbox renders above the Post button;
    # when ticked, a successful comment post is followed by an invocation of
    # CloseAction and its outcome is reflected in the status line. Returns
    # { Cancelled; NextAction; PostResult; CloseRequested; CloseResult } for the
    # orchestrator, where NextAction is 'Done' / 'SameItem' / 'NewItem'.
    #
    # The az post is synchronous on the dispatcher thread, so the spinner can't
    # truly animate during the call. The form forces a Render-priority dispatch
    # before posting so the "Posting..." overlay paints, then blocks briefly on
    # the call — feedback without spinning up a worker runspace.
    param(
        [Parameter(Mandatory)] [bool]        $Interrupted,
        [Parameter(Mandatory)] [scriptblock] $SubmitAction,
        [scriptblock] $CloseAction
    )

    Add-Type -AssemblyName PresentationFramework, WindowsBase, PresentationCore

    $formWidth = 360

    $Script:WpfDebriefOutcome        = 'Cancelled'
    $Script:WpfDebriefNextAction     = 'Done'
    $Script:WpfDebriefPostResult     = $null
    $Script:WpfDebriefCloseRequested = $false
    $Script:WpfDebriefCloseResult    = $null

    $closeEnabled  = ($null -ne $CloseAction)
    $checkboxLabel = "Work complete — resolve this story (sets State=$script:TimerCloseState)"

    $brushes = New-WpfBrushSet -ProgressColor $script:WpfColorProgress

    # ---- Window + container ----

    $mainWin = New-Object System.Windows.Window -Property @{
        Title                 = 'Timer Debrief'
        SizeToContent         = 'WidthAndHeight'
        WindowStyle           = 'None'
        AllowsTransparency    = $true
        Background            = $brushes.Clear
        Topmost               = $true
        WindowStartupLocation = 'CenterScreen'
    }

    $border = New-Object System.Windows.Controls.Border -Property @{
        Background      = $brushes.Bg
        BorderBrush     = $brushes.Stroke
        BorderThickness = 2
        CornerRadius    = 10
        Padding         = '16'
        Width           = $formWidth
    }

    $vbox = New-Object System.Windows.Controls.StackPanel

    # ---- Title (drag handle) ----

    $headerText = if ($Interrupted) {
        'Session interrupted — debrief'
    } else {
        'Session complete — debrief'
    }

    $titleLabel = New-Object System.Windows.Controls.TextBlock -Property @{
        Text                = $headerText
        FontSize            = 15
        FontWeight          = 'Bold'
        Foreground          = $brushes.White
        HorizontalAlignment = 'Center'
        Margin              = '0,0,0,12'
        Cursor              = [System.Windows.Input.Cursors]::SizeAll
    }
    $vbox.Children.Add($titleLabel) | Out-Null

    # ---- Debrief field ----

    $debriefLabel = New-Object System.Windows.Controls.TextBlock -Property @{
        Text       = 'Debrief — what did you accomplish?'
        FontSize   = 11
        Foreground = $brushes.Hint
        Margin     = '0,0,0,3'
    }
    $vbox.Children.Add($debriefLabel) | Out-Null

    $debriefBox = New-Object System.Windows.Controls.TextBox -Property @{
        AcceptsReturn               = $true
        TextWrapping                = 'Wrap'
        Height                      = 64
        Background                  = $brushes.Button
        Foreground                  = $brushes.White
        BorderBrush                 = $brushes.Stroke
        Padding                     = '4'
        VerticalScrollBarVisibility = 'Auto'
        Margin                      = '0,0,0,10'
    }
    $vbox.Children.Add($debriefBox) | Out-Null

    # ---- Next field ----

    $nextLabel = New-Object System.Windows.Controls.TextBlock -Property @{
        Text       = 'Next — what''s the next step?'
        FontSize   = 11
        Foreground = $brushes.Hint
        Margin     = '0,0,0,3'
    }
    $vbox.Children.Add($nextLabel) | Out-Null

    $nextBox = New-Object System.Windows.Controls.TextBox -Property @{
        AcceptsReturn               = $true
        TextWrapping                = 'Wrap'
        Height                      = 64
        Background                  = $brushes.Button
        Foreground                  = $brushes.White
        BorderBrush                 = $brushes.Stroke
        Padding                     = '4'
        VerticalScrollBarVisibility = 'Auto'
        Margin                      = '0,0,0,12'
    }
    $vbox.Children.Add($nextBox) | Out-Null

    # ---- Resolve checkbox (only when integration supplies a CloseAction) ----

    $chkResolve = New-Object System.Windows.Controls.CheckBox -Property @{
        Content    = $checkboxLabel
        Foreground = $brushes.White
        Background = $brushes.Bg
        FontSize   = 11
        Margin     = '0,0,0,10'
        IsChecked  = $false
        Visibility = [System.Windows.Visibility]::Collapsed
    }

    if ($closeEnabled) {
        $chkResolve.Visibility = [System.Windows.Visibility]::Visible
    }

    $vbox.Children.Add($chkResolve) | Out-Null

    # ---- Post button row ----

    $postPanel = New-Object System.Windows.Controls.StackPanel -Property @{
        HorizontalAlignment = 'Center'
    }
    $btnPost = New-Object System.Windows.Controls.Button -Property @{
        Content    = 'Post Debrief'
        Width      = 120
        Height     = 28
        Background = $brushes.Button
        Foreground = $brushes.White
    }
    $postPanel.Children.Add($btnPost) | Out-Null
    $vbox.Children.Add($postPanel) | Out-Null

    # ---- Spinner + status (hidden until Post) ----

    $statusPanel = New-Object System.Windows.Controls.StackPanel -Property @{
        Orientation         = 'Horizontal'
        HorizontalAlignment = 'Center'
        Margin              = '0,10,0,0'
        Visibility          = [System.Windows.Visibility]::Collapsed
    }
    $spinner = New-WpfSpinnerControl -Brushes $brushes -FontSize 18
    $spinner.Text.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
    $statusPanel.Children.Add($spinner.Text) | Out-Null

    $statusText = New-Object System.Windows.Controls.TextBlock -Property @{
        Text              = ''
        FontSize          = 12
        Foreground        = $brushes.White
        VerticalAlignment = 'Center'
        TextWrapping      = 'Wrap'
        MaxWidth          = 280
    }
    $statusPanel.Children.Add($statusText) | Out-Null
    $vbox.Children.Add($statusPanel) | Out-Null

    # ---- Start-another choice (hidden until a successful post) ----

    $askPanel = New-Object System.Windows.Controls.StackPanel -Property @{
        Orientation         = 'Horizontal'
        HorizontalAlignment = 'Center'
        Margin              = '0,12,0,0'
        Visibility          = [System.Windows.Visibility]::Collapsed
    }
    $btnSameItem = New-Object System.Windows.Controls.Button -Property @{
        Content    = 'Same item'
        Width      = 90
        Height     = 26
        Background = $brushes.Button
        Foreground = $brushes.White
        Margin     = 3
    }
    $btnNewItem = New-Object System.Windows.Controls.Button -Property @{
        Content    = 'Pick another'
        Width      = 100
        Height     = 26
        Background = $brushes.Button
        Foreground = $brushes.White
        Margin     = 3
    }
    $btnDone = New-Object System.Windows.Controls.Button -Property @{
        Content    = 'Done'
        Width      = 70
        Height     = 26
        Background = $brushes.Button
        Foreground = $brushes.White
        Margin     = 3
    }
    $askPanel.Children.Add($btnSameItem) | Out-Null
    $askPanel.Children.Add($btnNewItem)  | Out-Null
    $askPanel.Children.Add($btnDone)     | Out-Null
    $vbox.Children.Add($askPanel) | Out-Null

    # ---- Exit hint ----

    $exitHint = New-Object System.Windows.Controls.TextBlock -Property @{
        Text                = 'Right-click to cancel without posting'
        FontSize            = 9
        Foreground          = $brushes.Hint
        HorizontalAlignment = 'Center'
        Margin              = '0,12,0,0'
    }
    $vbox.Children.Add($exitHint) | Out-Null

    $border.Child    = $vbox
    $mainWin.Content = $border

    # ---- Event handlers ----

    $titleLabel.Add_MouseLeftButtonDown({ $mainWin.DragMove() })

    $mainWin.Add_MouseRightButtonDown({
        if ($Script:WpfDebriefOutcome -ne 'Posted') {
            $Script:WpfDebriefOutcome = 'Cancelled'
        }
        $mainWin.Close()
    })

    $btnPost.Add_Click({
        $debriefText = $debriefBox.Text
        $nextText    = $nextBox.Text

        $btnPost.IsEnabled      = $false
        $statusText.Foreground  = $brushes.White
        $statusText.Text        = 'Posting debrief...'
        $statusPanel.Visibility = [System.Windows.Visibility]::Visible
        $spinner.Timer.Start()

        # Flush the dispatcher to Render priority so the "Posting..." overlay
        # paints before the synchronous az call blocks this (UI) thread.
        $mainWin.Dispatcher.Invoke(
            [action]{},
            [System.Windows.Threading.DispatcherPriority]::Render
        )

        $postResult = & $SubmitAction $debriefText $nextText

        $spinner.Timer.Stop()
        $spinner.Text.Visibility = [System.Windows.Visibility]::Collapsed

        $exitCode = Get-TimerResultExitCode -Result $postResult

        if ($exitCode -eq 0) {
            $Script:WpfDebriefPostResult = $postResult
            $Script:WpfDebriefOutcome    = 'Posted'

            # Notes are now committed to the item — lock them so they can't be
            # edited, but keep them readable and selectable (IsReadOnly, not IsEnabled).
            $debriefBox.IsReadOnly = $true
            $nextBox.IsReadOnly    = $true

            $wantsResolve = ($closeEnabled -and ($chkResolve.IsChecked -eq $true))

            if ($wantsResolve) {
                $Script:WpfDebriefCloseRequested = $true

                $statusText.Text = 'Resolving item...'
                $spinner.Text.Visibility = [System.Windows.Visibility]::Visible
                $spinner.Timer.Start()

                $mainWin.Dispatcher.Invoke(
                    [action]{},
                    [System.Windows.Threading.DispatcherPriority]::Render
                )

                $closeResult = & $CloseAction

                $spinner.Timer.Stop()
                $spinner.Text.Visibility = [System.Windows.Visibility]::Collapsed

                $Script:WpfDebriefCloseResult = $closeResult

                $closeExit = Get-TimerResultExitCode -Result $closeResult
                if ($closeExit -eq 0) {
                    $statusText.Text = "Posted + Resolved (State=$script:TimerCloseState). Start another session?"
                } else {
                    $statusText.Foreground = $brushes.DarkRed
                    $statusText.Text       = "Posted; resolve failed. Start another session?"
                }
            } else {
                $statusText.Text = 'Posted. Start another session?'
            }

            $postPanel.Visibility = [System.Windows.Visibility]::Collapsed
            $chkResolve.Visibility = [System.Windows.Visibility]::Collapsed
            $askPanel.Visibility  = [System.Windows.Visibility]::Visible
        } else {
            $errText = if ($postResult -and $postResult.Error) {
                $postResult.Error
            } else {
                "exit $exitCode"
            }

            $statusText.Foreground = $brushes.DarkRed
            $statusText.Text       = "Post failed: $errText"
            $btnPost.IsEnabled     = $true
        }
    })

    $btnSameItem.Add_Click({
        $Script:WpfDebriefNextAction = 'SameItem'
        $mainWin.Close()
    })

    $btnNewItem.Add_Click({
        $Script:WpfDebriefNextAction = 'NewItem'
        $mainWin.Close()
    })

    $btnDone.Add_Click({
        $Script:WpfDebriefNextAction = 'Done'
        $mainWin.Close()
    })

    # ---- Show ----

    $debriefBox.Focus() | Out-Null
    $mainWin.ShowDialog() | Out-Null

    $cancelled = ($Script:WpfDebriefOutcome -ne 'Posted')

    $result = [PSCustomObject]@{
        Cancelled      = $cancelled
        NextAction     = $Script:WpfDebriefNextAction
        PostResult     = $Script:WpfDebriefPostResult
        CloseRequested = $Script:WpfDebriefCloseRequested
        CloseResult    = $Script:WpfDebriefCloseResult
    }
    return $result
}


function az-Start-TimerSession {
    # Orchestrator. Pick an integration (or use -Integration to skip),
    # fetch + pick an item, run the countdown (WPF overlay on Windows, snake
    # animation elsewhere), then collect the debrief and post the composed
    # comment via the chosen integration's AddComment. On Windows the countdown
    # morphs into a themed WPF debrief form (Show-WpfTimerDebrief) that posts
    # under a spinner and, after a successful post, offers "Same item" (reuse
    # the work item just debriefed), "Pick another", and "Done"; elsewhere the
    # debrief is collected via terminal Read-Host with a console posting
    # indicator and the same three-way choice via Read-TimerNextAction. A
    # "Same item" choice loops back straight to the countdown, skipping both
    # the integration and item pickers. When the chosen integration supplies
    # a CloseItem, the WPF form shows a resolve checkbox and the terminal path
    # prompts "Resolve this item now?" after a successful comment post; either
    # path fires the state transition only when explicitly requested.
    #
    # UTF-8 encoding is applied so emoji glyphs render in terminals that
    # default to a non-UTF-8 codepage; restored on exit (including Ctrl-C).
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

    $previousEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    try {
        $shouldRestart = $false
        $reuseItem     = $false
        do {
            $shouldRestart = $false

            if (-not $reuseItem) {
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
            }

            $reuseItem = $false

            Write-Host ""
            Write-Host "Starting $Minutes-minute session on item $($pickedItem.Id): $($pickedItem.Title)" -ForegroundColor Green
            Start-Sleep -Seconds 2

            $seconds         = $Minutes * 60
            $countdownResult = Show-TimerCountdown -Seconds $seconds

            $onWindows = Test-WpfIsWindows

            if ($onWindows) {

                $submitAction = {
                    param(
                        [string] $DebriefText,
                        [string] $NextText
                    )

                    $composed = Format-TimerCommentBody `
                        -Interrupted    $countdownResult.Interrupted `
                        -ElapsedSeconds $countdownResult.ElapsedSeconds `
                        -TotalSeconds   $countdownResult.TotalSeconds `
                        -Debrief        $DebriefText `
                        -Next           $NextText

                    $posted = & $chosen.AddComment -Id $pickedItem.Id -Body $composed
                    return $posted
                }.GetNewClosure()

                $closeAction = $null
                if ($null -ne $chosen.CloseItem) {
                    $closeAction = New-TimerCloseScript -Integration $chosen -Item $pickedItem
                }

                $debriefResult = Show-WpfTimerDebrief `
                    -Interrupted  $countdownResult.Interrupted `
                    -SubmitAction $submitAction `
                    -CloseAction  $closeAction

                if (-not $debriefResult.PostResult) {
                    $waveIcon = $script:TimerIconWave
                    Write-Host "No debrief posted - goodbye $waveIcon" -ForegroundColor DarkGray
                    return
                }

                Write-TimerPostVerdict -Result $debriefResult.PostResult -Item $pickedItem -Integration $chosen

                if ($debriefResult.CloseRequested) {
                    Write-TimerResolveVerdict `
                        -Result     $debriefResult.CloseResult `
                        -Item       $pickedItem `
                        -CloseState $script:TimerCloseState
                }

                $nextAction = $debriefResult.NextAction

            } else {

                Clear-Host
                $finishIcon = $script:TimerIconFinish
                Write-Host "$finishIcon SESSION COMPLETE! $finishIcon" -ForegroundColor Green
                Write-Host ""

                $iconMemo = $script:TimerIconMemo
                $debrief  = Read-Host "$iconMemo Debrief — what did you accomplish?"
                $next     = Read-Host "$iconMemo Next — what's the next step?"

                $body = Format-TimerCommentBody `
                    -Interrupted    $countdownResult.Interrupted `
                    -ElapsedSeconds $countdownResult.ElapsedSeconds `
                    -TotalSeconds   $countdownResult.TotalSeconds `
                    -Debrief        $debrief `
                    -Next           $next

                Write-Host ""
                $postScript = {
                    $posted = & $chosen.AddComment -Id $pickedItem.Id -Body $body
                    return $posted
                }.GetNewClosure()

                $commentResult = Invoke-WithSpinner `
                    -Message "Posting debrief to item $($pickedItem.Id)" `
                    -ScriptBlock $postScript

                Write-TimerPostVerdict -Result $commentResult -Item $pickedItem -Integration $chosen

                $postExitCode = Get-TimerResultExitCode -Result $commentResult
                if ($postExitCode -eq 0 -and $null -ne $chosen.CloseItem) {
                    $wantsResolve = Read-TimerYesNo -Prompt "Resolve this item now? (sets State=$script:TimerCloseState)"
                    if ($wantsResolve) {
                        $closeScript = New-TimerCloseScript -Integration $chosen -Item $pickedItem

                        $closeResult = Invoke-WithSpinner `
                            -Message "Resolving item $($pickedItem.Id)" `
                            -ScriptBlock $closeScript

                        Write-TimerResolveVerdict `
                            -Result     $closeResult `
                            -Item       $pickedItem `
                            -CloseState $script:TimerCloseState
                    }
                }

                $itemLabel  = "$($pickedItem.Id): $($pickedItem.Title)"
                $nextAction = Read-TimerNextAction -ItemLabel $itemLabel
            }

            $resolved      = Resolve-TimerNextAction -Action $nextAction
            $shouldRestart = $resolved.ShouldRestart
            $reuseItem     = $resolved.ReuseItem

            if ($shouldRestart -and -not $reuseItem) {
                $Integration = $null
            } elseif (-not $shouldRestart) {
                $waveIcon = $script:TimerIconWave
                Write-Host "Goodbye $waveIcon" -ForegroundColor DarkGray
            }

        } while ($shouldRestart)
    }
    finally {
        [Console]::OutputEncoding = $previousEncoding
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

az-Register-TimerIntegration `
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
        $hint = "View discussion: az-Open-WorkItemById $Id"
        return $hint
    } `
    -CloseItem   {
        param([Parameter(Mandatory)] [int] $Id)
        $result = Set-AzDevOpsWorkItemField -Id $Id -Fields @("System.State=$script:TimerCloseState")
        return $result
    }
