



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
    $x        = $center + $radius * [Math]::Cos($angleRad)
    $y        = $center + $radius * [Math]::Sin($angleRad)

    $ArcSegment.IsLargeArc = ($angle -gt 180)
    $ArcSegment.Point      = New-Object System.Windows.Point($x, $y)
}
