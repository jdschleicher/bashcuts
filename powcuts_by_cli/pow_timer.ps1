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

function Show-ModernMultiLinePrompt {
    param (
        [string]$PromptText,
        [string]$WindowTitle = "Prompt"
    )

    # 1. LAZY LOAD TYPES: Ensure UI assemblies are ready
    if (-not ([System.Management.Automation.PSTypeName]'System.Windows.Forms.Form').Type) {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        [System.Windows.Forms.Application]::EnableVisualStyles()
    }

    # 2. NESTED HELPER FUNCTION: Creates and fires the OS balloon notification
    function Show-BalloonNotification {
        param (
            [string]$Title = "Action Required",
            [string]$Message = "Please complete your notes to proceed."
        )
        $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
        # Extracts the native PowerShell engine icon to use in the system tray
        $notifyIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon((Get-Process -Id $PID).Path)
        $notifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
        $notifyIcon.BalloonTipTitle = $Title
        $notifyIcon.BalloonTipText = $Message
        $notifyIcon.Visible = $true
        
        # Flash balloon for 3 seconds, then clean up memory immediately
        $notifyIcon.ShowBalloonTip(3000)
        Start-Sleep -Milliseconds 100
        $notifyIcon.Dispose()
    }

    # 3. Modern Window Layout Canvas
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $WindowTitle
    $form.Size = New-Object System.Drawing.Size(420, 300)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(245, 246, 248)
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 10)

    # 4. Clean Typography Label
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $PromptText
    $label.Location = New-Object System.Drawing.Point(20, 15)
    $label.Size = New-Object System.Drawing.Size(365, 25)
    $label.ForeColor = [System.Drawing.Color]::FromArgb(33, 37, 41)
    $form.Controls.Add($label)

    # 5. Modern Multi-Line TextBox
    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Multiline = $true
    $textBox.ScrollBars = "Vertical"
    $textBox.Location = New-Object System.Drawing.Point(20, 45)
    $textBox.Size = New-Object System.Drawing.Size(365, 130)
    $textBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $textBox.BackColor = [System.Drawing.Color]::White
    $textBox.AcceptsReturn = $true 
    $form.Controls.Add($textBox)

    # 6. IN-FORM ALERT LABEL: Red error warning block
    $errorLabel = New-Object System.Windows.Forms.Label
    $errorLabel.Text = "⚠️ Field cannot be empty! Please provide notes."
    $errorLabel.Location = New-Object System.Drawing.Point(20, 185)
    $errorLabel.Size = New-Object System.Drawing.Size(250, 25)
    $errorLabel.ForeColor = [System.Drawing.Color]::Red
    $errorLabel.Visible = $false
    $form.Controls.Add($errorLabel)

    # 7. Styled Button Control
    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "Submit"
    $okButton.Location = New-Object System.Drawing.Point(285, 185)
    $okButton.Size = New-Object System.Drawing.Size(100, 32)
    $okButton.FlatStyle = [System.Windows.Forms.FlatStyle]::System
    $form.Controls.Add($okButton)

    # 8. VALIDATION LOGIC: Check form fields on Submit click
    $okButton.add_Click({
        if ([string]::IsNullOrWhiteSpace($textBox.Text)) {
            $errorLabel.Visible = $true
            [System.Media.SystemSounds]::Hand.Play()
            # Fire the balloon notification on a bad submit attempt
            Show-BalloonNotification -Title "Submission Blocked" -Message "You must enter details for '$WindowTitle' before submitting."
        } else {
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        }
    })

    # Clear red warning block instantly when user resumes typing
    $textBox.add_TextChanged({
        if ($errorLabel.Visible -and -not [string]::IsNullOrWhiteSpace($textBox.Text)) {
            $errorLabel.Visible = $false
        }
    })

    # Keyboard Shortcut Integration (Ctrl + Enter)
    $textBox.add_KeyDown({
        param($sender, $e)
        if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $e.SuppressKeyPress = $true 
            $okButton.PerformClick()
        }
    })

    # 9. BACKGROUND TIMER: Fires every 5 seconds if form remains empty
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 5000 
    
    $timer.add_Tick({
        if ([string]::IsNullOrWhiteSpace($textBox.Text)) {
            [System.Media.SystemSounds]::Asterisk.Play()
            $errorLabel.Visible = $true
            # Fire system notification loop reminder
            Show-BalloonNotification -Title "Friendly Reminder" -Message "Don't forget to fill out your '$WindowTitle' prompt!"
        }
    })

    $form.add_Load({ 
        $timer.Start()
        $textBox.Focus()
    })
    $form.add_FormClosing({ $timer.Stop(); $timer.Dispose() })

    # 10. Persistent Window Execution Execution Loop
    while ($true) {
        $result = $form.ShowDialog()
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            return $textBox.Text
        }
        # If user clicks the application exit 'X' icon:
        [System.Media.SystemSounds]::Hand.Play()
        Show-BalloonNotification -Title "Form Closed Prematurely" -Message "Data entry is required. The form has restarted."
    }
}


function az-Start-TimerSession {
    # Orchestrator. Pick an integration (or use -Integration to skip),
    # fetch + pick an item, run the snake countdown (Esc to end early),
    # prompt for debrief notes, post the composed comment via the chosen
    # integration's AddComment. On an Esc-interrupted session also prompt
    # whether to start another session — same -Minutes, fresh integration
    # / item pick so the user can pivot to a different story.
    #
    # UTF-8 encoding is applied around the snake animation so the emoji
    # glyphs render in terminals that default to a non-UTF-8 codepage; the
    # previous encoding is restored on exit (including Ctrl-C) so we don't
    # leak a process-wide mutation back to the shell.
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
        do {
            $shouldRestart = $false

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

            if (-not ([System.Management.Automation.PSTypeName]'System.Windows.Forms.NotifyIcon').Type) {
                Add-Type -AssemblyName System.Windows.Forms, System.Drawing
            }

            # Instantiate the objects cleanly
            $Balloon = New-Object System.Windows.Forms.NotifyIcon
            $Balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon((Get-Process -Id $PID).Path)

            # Configure the alert elements
            $Balloon.BalloonTipIcon  = [System.Windows.Forms.ToolTipIcon]::Warning
            $Balloon.BalloonTipTitle = "🚨 POMODORO TASK EXPIRED! 🚨"
            $Balloon.BalloonTipText  = "⏰ Time's up! Please provide debrief and next steps. 🛑"
            $Balloon.Visible = $true

            # Fire balloon simultaneously
            $Balloon.ShowBalloonTip(0)

            Clear-Host
            $finishIcon = $script:TimerIconFinish
            Write-Host "$finishIcon SESSION COMPLETE! $finishIcon" -ForegroundColor Green

            # --- Execution ---
            $debrief = Show-ModernMultiLinePrompt -PromptText "Enter your debrief notes (Ctrl+Enter to submit):" -WindowTitle "Debrief"
            $next    = Show-ModernMultiLinePrompt -PromptText "What's Next? (Ctrl+Enter to submit):" -WindowTitle "Next Steps"

            Write-Host "`n--- SAVED DATA ---" -ForegroundColor Green
            Write-Host "Debrief Note:`n$debrief"
            Write-Host "`nNext Note:`n$next"

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
                    $shouldRestart = $true
                    $Integration = $null
                } else {
                    $waveIcon = $script:TimerIconWave
                    Write-Host "Goodbye $waveIcon" -ForegroundColor DarkGray
                }
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
        $hint = "View discussion: az-Open-AzDevOpsAssigned $Id"
        return $hint
    }
