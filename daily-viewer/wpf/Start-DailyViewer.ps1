#requires -Version 5.1

<#
.SYNOPSIS
    Launches the WPF prototype of the Azure DevOps daily viewer.

.DESCRIPTION
    Loads DailyViewer.xaml (the visual twin of daily-viewer/index.html) and wires
    the interactions: per-tile refresh, refresh-all, light/dark toggle, stat-strip
    jump-to-tile, and links that open in the default browser.

    Windows / WPF only — PresentationFramework is not available on macOS or Linux.
    Content is placeholder; the live build would populate tiles from a local cache
    written by `az boards query` and the Outlook PowerShell module.

.EXAMPLE
    pwsh -File .\Start-DailyViewer.ps1
#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase


# WPF ShowDialog requires an STA thread. Windows PowerShell 5.1 is STA by default;
# pwsh 7 defaults to MTA, so relaunch this script under Windows PowerShell there.
$apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()

if ($apartment -ne [System.Threading.ApartmentState]::STA) {
    $windowsPowerShell = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'

    if (Test-Path -LiteralPath $windowsPowerShell) {
        & $windowsPowerShell -Sta -ExecutionPolicy Bypass -File $PSCommandPath
    } else {
        Write-Warning 'This UI needs an STA thread; relaunch with Windows PowerShell (powershell.exe).'
    }

    return
}


$script:RefreshDelay = [TimeSpan]::FromMilliseconds(900)


function Get-DailyViewerPalette {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Dark', 'Light')]
        [string]$Theme
    )

    if ($Theme -eq 'Dark') {
        $palette = @{
            Bg           = '#0F131A'
            Surface      = '#171C25'
            Surface2     = '#1E2531'
            Border       = '#29313D'
            BorderStrong = '#38424F'
            Text         = '#E7ECF3'
            TextDim      = '#97A3B4'
            TextFaint    = '#6C7889'
            Accent       = '#4AA3F0'
            AccentWeak   = '#22345066'
        }
    } else {
        $palette = @{
            Bg           = '#EEF1F6'
            Surface      = '#FFFFFF'
            Surface2     = '#F5F7FA'
            Border       = '#DCE2EC'
            BorderStrong = '#C6CFDC'
            Text         = '#1B2430'
            TextDim      = '#5A6675'
            TextFaint    = '#8A94A3'
            Accent       = '#0E6FCE'
            AccentWeak   = '#1A0E6FCE'
        }
    }

    return $palette
}


function Set-DailyViewerTheme {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Window]$Window,

        [Parameter(Mandatory)]
        [ValidateSet('Dark', 'Light')]
        [string]$Theme
    )

    $palette = Get-DailyViewerPalette -Theme $Theme

    foreach ($key in $palette.Keys) {
        $brush = $Window.Resources[$key]

        if ($null -ne $brush) {
            $brush.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($palette[$key])
        }
    }
}


function Register-DailyViewerRefresh {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Controls.Button]$Button,

        [Parameter(Mandatory)]
        [System.Windows.Controls.TextBlock]$Stale
    )

    $handler = {
        if ($Button.IsEnabled -eq $false) {
            return
        }

        $Button.IsEnabled = $false
        $Stale.Text = 'refreshing…'

        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = $script:RefreshDelay

        $tick = {
            $Stale.Text = 'cached just now'
            $Button.IsEnabled = $true
            $timer.Stop()
        }.GetNewClosure()

        $timer.Add_Tick($tick)
        $timer.Start()
    }.GetNewClosure()

    $Button.Add_Click($handler)
}


function Start-DailyViewer {
    $xamlPath = Join-Path -Path $PSScriptRoot -ChildPath 'DailyViewer.xaml'

    if (-not (Test-Path -LiteralPath $xamlPath)) {
        throw "DailyViewer.xaml not found next to this script at '$xamlPath'."
    }

    $xaml = Get-Content -LiteralPath $xamlPath -Raw
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    # Links open in the default browser (routed Hyperlink event, handled once).
    $navHandler = [System.Windows.Navigation.RequestNavigateEventHandler] {
        param($sender, $e)

        Start-Process $e.Uri.AbsoluteUri
        $e.Handled = $true
    }
    $window.AddHandler([System.Windows.Documents.Hyperlink]::RequestNavigateEvent, $navHandler)

    # Per-tile refresh — the only expensive path in the real build.
    $tiles = @(
        @{ Button = 'RefreshAgenda';   Stale = 'StaleAgenda' }
        @{ Button = 'RefreshWeek';     Stale = 'StaleWeek' }
        @{ Button = 'RefreshActivity'; Stale = 'StaleActivity' }
        @{ Button = 'RefreshFocus';    Stale = 'StaleFocus' }
    )

    foreach ($tile in $tiles) {
        $button = $window.FindName($tile.Button)
        $stale = $window.FindName($tile.Stale)
        Register-DailyViewerRefresh -Button $button -Stale $stale
    }

    $refreshAll = $window.FindName('RefreshAllButton')
    $refreshAll.Add_Click({
        foreach ($tile in $tiles) {
            $button = $window.FindName($tile.Button)
            $button.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        }
    }.GetNewClosure())

    # Stat strip: open and scroll to the tile a stat summarizes.
    $stats = @('StatAgenda', 'StatWeek', 'StatActivity', 'StatFocus')

    foreach ($statName in $stats) {
        $stat = $window.FindName($statName)

        $statHandler = {
            $targetName = $this.Tag
            $target = $window.FindName($targetName)

            if ($null -ne $target) {
                $target.IsExpanded = $true
                $target.BringIntoView()
            }
        }.GetNewClosure()

        $stat.Add_Click($statHandler)
    }

    # Light / dark toggle.
    $script:currentTheme = 'Dark'
    $themeButton = $window.FindName('ThemeButton')

    $themeHandler = {
        if ($script:currentTheme -eq 'Dark') {
            $script:currentTheme = 'Light'
        } else {
            $script:currentTheme = 'Dark'
        }

        Set-DailyViewerTheme -Window $window -Theme $script:currentTheme
    }.GetNewClosure()

    $themeButton.Add_Click($themeHandler)

    $null = $window.ShowDialog()
}


Start-DailyViewer
