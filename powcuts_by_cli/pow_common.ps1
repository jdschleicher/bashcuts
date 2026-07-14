



Set-Alias -Name nfp -Value c:\windows\notepad.exe

function reinit {
    Invoke-Command { & "pwsh.exe" } -NoNewScope 
}

function new-list($new_list_variable) {
    Set-Variable -Name "$new_list_variable" -Value ([system.collections.generic.list[string]]::new()) -Scope global
}

function robot-debug() {
    $env:ROBOT_DEBUG = "TRUE"; robot --rpa -d output .
}

function last-command() {
    $id_of_last_command = $(Get-History -Count 1).Id
    $result_of_last_command = Invoke-History $id_of_last_command
    $result_of_last_command
}

function decode-base64() {
    param($base_encoded_64)

    $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($base_encoded_64))  
    $decoded

}

function encode-base64() {
    param($to_encode)

    $bytes = [System.Text.Encoding]::Unicode.GetBytes("$to_encode")
    $encoded =[Convert]::ToBase64String($bytes)
    
    $encoded
}

function encode-base64-utf8() {
    param($to_encode)

    $enc = [System.Text.Encoding]::UTF8
    $enc_utf8_org = $enc.GetBytes($to_encode)
    $base64_utf8_encoded =[Convert]::ToBase64String($enc_utf8_org)

    $base64_utf8_encoded

}

function kill-by-port() {
    param ($port)
    # https://dzhavat.github.io/2020/04/09/powershell-script-to-kill-a-process-on-windows.html

    $foundProcesses = netstat -ano | findstr :$port
    $activePortPattern = ":$port\s.+LISTENING\s+\d+$"
    $pidNumberPattern = "\d+$"

    IF ($foundProcesses | Select-String -Pattern $activePortPattern -Quiet) {
        $matches = $foundProcesses | Select-String -Pattern $activePortPattern
        $firstMatch = $matches.Matches.Get(0).Value

        $pidNumber = [regex]::match($firstMatch, $pidNumberPattern).Value

        taskkill /pid $pidNumber /f
    }
}

function pow_remove_property_from_field {
    param(
        [Parameter(Mandatory=$true)]
        $property,
        [Parameter(Mandatory=$true)]
        $object
    )

    $object.PSObject.properties.remove("$property")

    $object

}


$script:AzDevOpsHtmlLineBreak = '<br/>'


function ConvertTo-AzDevOpsHtmlLineBreak {
    # Normalize any embedded newline (CRLF / CR / LF) in a free-text field to
    # the Azure DevOps discussion field's HTML <br/> break. Multi-line debrief
    # text captured from the WPF form's AcceptsReturn boxes would otherwise
    # reach `az boards ... --discussion` with raw CRLFs, and cmd.exe /c
    # truncates the argument at the first CRLF - silently dropping everything
    # the user typed after their first page-return. Converting to <br/> keeps
    # the whole body on one physical line so it survives the shell hand-off,
    # and renders as a visible line break in the AzDO UI. Trailing newlines are
    # trimmed so a field that ends on Enter doesn't leave a dangling <br/>.
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

    $break     = $script:AzDevOpsHtmlLineBreak
    $trimmed   = $Text -replace '[\r\n]+$', ''
    $converted = $trimmed -replace '\r\n?|\n', $break

    return $converted
}


function Test-ConsoleGridAvailable {
    # $true iff Out-ConsoleGridView (from Microsoft.PowerShell.ConsoleGuiTools)
    # is loaded. Used by every cross-platform interactive picker - the TUI
    # grid is much friendlier than a numbered Read-Host menu, but it only
    # exists when the user has installed the module. Callers check this and
    # fall back to their own numbered prompt when it's missing.
    $cmd = Get-Command Out-ConsoleGridView -ErrorAction SilentlyContinue
    $available = ($null -ne $cmd)
    return $available
}


function Test-WpfIsWindows {
    $result = ($IsWindows -or ($env:OS -eq 'Windows_NT'))
    return $result
}


function New-WpfBrushSet {
    # Creates a named brush bundle from the shared WPF color constants
    # (defined in pow_timer.ps1). -ProgressColor overrides the arc color so
    # the Pomodoro (blue) and unplanned-work stopwatch (amber) share one helper.
    param([Parameter(Mandatory)] [string] $ProgressColor)

    $converter = [System.Windows.Media.BrushConverter]::new()
    $result = [PSCustomObject]@{
        Bg       = $converter.ConvertFromString($script:WpfColorBackground)
        Stroke   = $converter.ConvertFromString($script:WpfColorStroke)
        Progress = $converter.ConvertFromString($ProgressColor)
        Button   = $converter.ConvertFromString($script:WpfColorButton)
        Hint     = $converter.ConvertFromString($script:WpfColorHint)
        White    = [System.Windows.Media.Brushes]::White
        DarkRed  = [System.Windows.Media.Brushes]::DarkRed
        Clear    = [System.Windows.Media.Brushes]::Transparent
    }
    return $result
}


function New-WpfCircleResources {
    # Builds the shared WPF infrastructure: transparent Window, fixed-size Grid,
    # dark Ellipse background, and progress-ring arc Path. Returns a PSCustomObject
    # with Window, Grid, MainCircle, and ArcSegment so callers can add their own
    # controls to the Grid and wire event handlers. -ArcStartsFull $true (default)
    # sets the initial arc to full-circle (countdown drain); $false starts empty
    # (stopwatch fill).
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] $Brushes,
        [bool] $ArcStartsFull = $true
    )

    $windowSize = $script:WpfWindowSize
    $arcStartX  = $script:WpfArcStartX
    $arcStartY  = $script:WpfArcStartY
    $radius     = $script:WpfCircleRadius

    $mainWin = New-Object System.Windows.Window -Property @{
        Title                 = $Title
        SizeToContent         = 'WidthAndHeight'
        WindowStyle           = 'None'
        AllowsTransparency    = $true
        Background            = $Brushes.Clear
        Topmost               = $true
        WindowStartupLocation = 'CenterScreen'
    }

    $circleGrid = New-Object System.Windows.Controls.Grid -Property @{
        Width  = $windowSize
        Height = $windowSize
    }

    $mainCircle = New-Object System.Windows.Shapes.Ellipse -Property @{
        Fill            = $Brushes.Bg
        Stroke          = $Brushes.Stroke
        StrokeThickness = 2
    }
    $circleGrid.Children.Add($mainCircle) | Out-Null

    $pathGeometry = New-Object System.Windows.Media.PathGeometry
    $pathFigure   = New-Object System.Windows.Media.PathFigure -Property @{
        StartPoint = "$arcStartX,$arcStartY"
        IsClosed   = $false
    }
    $arcSegment = New-Object System.Windows.Media.ArcSegment -Property @{
        Size           = "$radius,$radius"
        SweepDirection = 'Clockwise'
        IsLargeArc     = $ArcStartsFull
    }
    $pathFigure.Segments.Add($arcSegment) | Out-Null
    $pathGeometry.Figures.Add($pathFigure) | Out-Null

    $progressRing = New-Object System.Windows.Shapes.Path -Property @{
        Stroke             = $Brushes.Progress
        StrokeThickness    = 6
        StrokeStartLineCap = 'Round'
        StrokeEndLineCap   = 'Round'
        Data               = $pathGeometry
    }
    $circleGrid.Children.Add($progressRing) | Out-Null

    $mainWin.Content = $circleGrid

    $result = [PSCustomObject]@{
        Window     = $mainWin
        Grid       = $circleGrid
        MainCircle = $mainCircle
        ArcSegment = $arcSegment
    }
    return $result
}


function Set-WpfArcPoint {
    # Updates the arc endpoint for a progress ring. $Pct is clamped to
    # (0.0001, 0.9999) so the arc is always a genuine arc (never a full circle,
    # which renders as nothing in WPF path geometry).
    param(
        [Parameter(Mandatory)] [double] $Pct,
        [Parameter(Mandatory)] $ArcSegment
    )

    $center = $script:WpfCircleCenter
    $radius = $script:WpfCircleRadius

    if ($Pct -ge 0.9999) {
        $Pct = 0.9999
    }

    if ($Pct -le 0.0001) {
        $Pct = 0.0001
    }

    $angle    = $Pct * 360
    $angleRad = [Math]::PI * ($angle - 90) / 180
    $x        = [double]($center + $radius * [Math]::Cos($angleRad))
    $y        = [double]($center + $radius * [Math]::Sin($angleRad))

    $ArcSegment.IsLargeArc = ($angle -gt 180)
    $ArcSegment.Point      = [System.Windows.Point]::new($x, $y)
}


$script:CommonSpinnerFrames     = @('|', '/', '-', '\')
$script:CommonSpinnerIntervalMs = 120
$script:CommonSpinnerClearPad   = 8


function Test-CommonSpinnerEnabled {
    # Private guard - the console spinner is only safe to draw on an
    # interactive terminal whose stdout isn't redirected. When output is piped
    # or captured to a file (CI, `pwsh script.ps1 > out.txt`, `... | cmd`) the
    # raw [Console]::Write frames would land in the redirected stream, so the
    # spinner is suppressed and the caller runs the work silently — the
    # { Json, Error, ExitCode } envelope a wrapper returns is never affected.
    # BASHCUTS_NO_SPINNER is an explicit opt-out for users who want it off
    # regardless of context. Unapproved-verb-free name (Test-* is approved);
    # treated as private to pow_common.ps1.
    if (-not [string]::IsNullOrEmpty($env:BASHCUTS_NO_SPINNER)) {
        return $false
    }

    if ([Console]::IsOutputRedirected) {
        return $false
    }

    return $true
}


function Start-CommonConsoleSpinner {
    # Private helper - opens a background runspace that redraws the spinner
    # frame in place on a "`r<frame> <Message>..." line every
    # CommonSpinnerIntervalMs. The wrapped work runs synchronously on the
    # calling thread, so the animation has to live on its own thread to keep
    # ticking while a slow az call blocks. Shared state travels through a
    # synchronized hashtable so the main thread can flip .Active to false;
    # pair this with Stop-CommonConsoleSpinner to join the runspace and clear
    # the line.
    param([string] $Message = 'Working')

    $frames     = $script:CommonSpinnerFrames
    $intervalMs = $script:CommonSpinnerIntervalMs

    $state = [hashtable]::Synchronized(@{
        Active = $true
    })

    $runspace = $null
    $worker   = $null

    try {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $runspace.SessionStateProxy.SetVariable('State', $state)
        $runspace.SessionStateProxy.SetVariable('Frames', $frames)
        $runspace.SessionStateProxy.SetVariable('Message', $Message)
        $runspace.SessionStateProxy.SetVariable('IntervalMs', $intervalMs)

        $worker = [powershell]::Create()
        $worker.Runspace = $runspace
        $worker.AddScript({
            $index = 0
            while ($State.Active) {
                $frame = $Frames[$index % $Frames.Count]
                [Console]::Write("`r$frame $Message...")
                $index++
                Start-Sleep -Milliseconds $IntervalMs
            }
        }) | Out-Null

        $handle = $worker.BeginInvoke()
    } catch {
        # A spinner that fails to start must never break the wrapped call. Tear
        # down whatever was created and return $null so the caller runs the work
        # without a spinner (Stop-CommonConsoleSpinner treats $null as a no-op).
        if ($null -ne $worker) {
            $worker.Dispose()
        }

        if ($null -ne $runspace) {
            $runspace.Dispose()
        }

        return $null
    }

    $result = [PSCustomObject]@{
        State    = $state
        Worker   = $worker
        Handle   = $handle
        Runspace = $runspace
        Width    = ($Message.Length + $script:CommonSpinnerClearPad)
    }
    return $result
}


function Stop-CommonConsoleSpinner {
    # Private helper - signals the spinner runspace to stop, waits for the
    # in-flight frame to finish drawing, disposes the runspace, then blanks the
    # spinner line so no glyph survives into whatever prints next. A $null
    # spinner (Start- failed to launch one) is a no-op. The whole teardown is
    # best-effort: it runs from Invoke-WithSpinner's finally, so a worker that
    # threw on an invalid console handle must not let EndInvoke resurface that
    # exception and mask the wrapped call's real result. Width is the
    # spinner-line length captured at start, padded so the longest frame is
    # fully overwritten.
    param($Spinner)

    if ($null -eq $Spinner) {
        return
    }

    $Spinner.State.Active = $false

    try {
        $Spinner.Worker.EndInvoke($Spinner.Handle)
    } catch {
        # Cosmetic draw failure - swallow so it never masks the az outcome.
    }

    $Spinner.Worker.Dispose()
    $Spinner.Runspace.Close()
    $Spinner.Runspace.Dispose()

    $blank = ' ' * $Spinner.Width
    [Console]::Write("`r$blank`r")
}


function Invoke-WithSpinner {
    # Runs $ScriptBlock while animating a single-line console spinner, then
    # clears that line and returns whatever the scriptblock returned. The work
    # runs synchronously on the calling thread — a wrapped az call blocks until
    # it returns — so the animation is driven from a background runspace that
    # redraws the frame in place; the main thread stops the runspace and blanks
    # the line once the call completes, leaving no stray glyph behind. This is
    # the shared seam the repo-wide az spinner wraps (Invoke-AzDevOpsAzJson).
    # When stdout is redirected or BASHCUTS_NO_SPINNER is set the spinner is
    # skipped and the work runs silently so captured/piped output is never
    # corrupted.
    param(
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [string] $Message = 'Working'
    )

    if (-not (Test-CommonSpinnerEnabled)) {
        $result = & $ScriptBlock
        return $result
    }

    $spinner = $null
    try {
        $spinner = Start-CommonConsoleSpinner -Message $Message
        $result  = & $ScriptBlock
    } finally {
        Stop-CommonConsoleSpinner -Spinner $spinner
    }

    return $result
}


function New-WpfSpinnerControl {
    # Reusable WPF spinner: a TextBlock whose text cycles through the shared
    # spinner frames on a DispatcherTimer tick. Caller adds .Text to its layout
    # and starts/stops .Timer. Frames advance only while the dispatcher is free,
    # so a long synchronous call on the UI thread stalls the animation until it
    # returns — acceptable for the brief az posts this wraps. Returns the
    # TextBlock + Timer so callers own placement and start/stop timing.
    param(
        [Parameter(Mandatory)] $Brushes,
        [int] $FontSize = 22
    )

    $frames = $script:CommonSpinnerFrames

    $textBlock = New-Object System.Windows.Controls.TextBlock -Property @{
        Text                = $frames[0]
        FontSize            = $FontSize
        FontFamily          = 'Consolas'
        Foreground          = $Brushes.White
        HorizontalAlignment = 'Center'
    }

    $timer = New-Object System.Windows.Threading.DispatcherTimer -Property @{
        Interval = [TimeSpan]::FromMilliseconds(120)
    }

    $frameIndex = [ref] 0
    $timer.Add_Tick({
        $frameIndex.Value = ($frameIndex.Value + 1) % $frames.Count
        $textBlock.Text   = $frames[$frameIndex.Value]
    }.GetNewClosure())

    $result = [PSCustomObject]@{
        Text  = $textBlock
        Timer = $timer
    }
    return $result
}


function New-WpfProgressController {
    # Private - the no-op controller returned off Windows / when WPF can't load
    # / when a caller asks for a disabled progress window. Every member is a
    # do-nothing scriptblock so call sites drive the real and stub controllers
    # identically; the feature's own Write-Host lines stay the non-Windows
    # feedback. Unapproved-verb-free (New is approved); treated as private.
    $result = [PSCustomObject]@{
        SetStatus = { param([string] $Text) }
        Suspend   = { }
        Resume    = { }
        Stop      = { }
    }
    return $result
}


function New-WpfProgressWindow {
    # Lightweight non-modal WPF progress window: a spinner glyph beside a status
    # line, themed to match the timer / unplanned forms. Built for a synchronous
    # script that runs a chain of slow calls and wants to show which step it's on
    # - the az-boards chain az-Start-UnplannedWork runs at session stop. Returns
    # a controller object whose scriptblock members drive it:
    #   SetStatus <text> - repaint the status line. Forces a Render-priority
    #                      dispatch so the new text paints before the next
    #                      synchronous call blocks the UI thread (same trick the
    #                      debrief form's "Posting..." overlay uses - the window
    #                      is non-modal so there's no message pump to animate the
    #                      spinner during a blocking call; the changing status
    #                      text is the real progress signal).
    #   Suspend / Resume - hide / re-show the window around an interactive
    #                      terminal prompt, so a topmost window doesn't sit over a
    #                      console picker (mirrors the stopwatch's hide/show-
    #                      around-"Create New Story" pattern).
    #   Stop             - stop the spinner and close the window; idempotent, so
    #                      a caller can close early and a finally can close again.
    # Off Windows, when -Disabled is set, or when PresentationFramework can't be
    # loaded, returns the no-op controller so callers never branch on platform.
    param(
        [string] $Title         = 'Working',
        [string] $InitialStatus = 'Working...',
        [switch] $Disabled
    )

    if ($Disabled -or -not (Test-WpfIsWindows)) {
        $stub = New-WpfProgressController
        return $stub
    }

    try {
        Add-Type -AssemblyName PresentationFramework, WindowsBase, PresentationCore
    }
    catch {
        $stub = New-WpfProgressController
        return $stub
    }

    $brushes = New-WpfBrushSet -ProgressColor $script:WpfColorProgressUnplanned

    $win = New-Object System.Windows.Window -Property @{
        Title                 = $Title
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
        Padding         = '20,16'
    }

    $row = New-Object System.Windows.Controls.StackPanel -Property @{
        Orientation         = 'Horizontal'
        HorizontalAlignment = 'Center'
        VerticalAlignment   = 'Center'
    }

    $spinnerRightMargin = New-Object System.Windows.Thickness(0, 0, 10, 0)
    $spinner = New-WpfSpinnerControl -Brushes $brushes -FontSize 20
    $spinner.Text.Margin = $spinnerRightMargin
    $row.Children.Add($spinner.Text) | Out-Null

    $statusText = New-Object System.Windows.Controls.TextBlock -Property @{
        Text              = $InitialStatus
        FontSize          = 13
        Foreground        = $brushes.White
        VerticalAlignment = 'Center'
        TextWrapping      = 'Wrap'
        MaxWidth          = 300
    }
    $row.Children.Add($statusText) | Out-Null

    $border.Child = $row
    $win.Content  = $border

    # Flush the dispatcher to Render priority so a status change paints before the
    # next synchronous call blocks this (UI) thread - the window has no message
    # pump of its own (it's shown non-modally, not via ShowDialog).
    $forceRender = {
        $win.Dispatcher.Invoke(
            [action]{},
            [System.Windows.Threading.DispatcherPriority]::Render
        )
    }.GetNewClosure()

    $win.Show()
    $spinner.Timer.Start()
    & $forceRender

    $stopped = [ref] $false

    $controller = [PSCustomObject]@{
        SetStatus = {
            param([string] $Text)

            $statusText.Text = $Text
            & $forceRender
        }.GetNewClosure()

        Suspend = {
            $win.Hide()
        }.GetNewClosure()

        Resume = {
            $win.Show()
            & $forceRender
        }.GetNewClosure()

        Stop = {
            if ($stopped.Value) {
                return
            }

            $stopped.Value = $true
            $spinner.Timer.Stop()
            $win.Close()
        }.GetNewClosure()
    }

    return $controller
}
