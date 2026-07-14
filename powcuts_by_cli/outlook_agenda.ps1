# ============================================================================
# Outlook — Day agenda + tasks (desktop COM)
# ============================================================================
# Terminal-native "what does today look like?" for Windows desktop Outlook.
# Reads the default Calendar and Tasks folders through Outlook COM automation
# (New-Object -ComObject Outlook.Application) — no cloud / Graph auth.
#
# Public surface (tab-tab on `ol-`):
#   ol-Get-OutlookAgenda   -> today's meetings as objects
#   ol-Show-OutlookAgenda  -> today's meetings as a table
#   ol-Get-OutlookTasks    -> today's / overdue open tasks as objects
#   ol-Show-OutlookTasks   -> today's / overdue open tasks as a table
#   ol-Show-OutlookDay     -> composed day view (agenda + tasks); alias `ol-day`
#
# Windows + desktop Outlook only. On any other platform (or when the COM
# object can't be created) every function fails soft with a yellow hint and
# never throws. `-Date` is today by default but flows through the Get
# functions so a future date/range surface is a non-breaking add.
#
# Loaded by powcuts_home.ps1.

# --- Constants --------------------------------------------------------------
# Outlook default-folder ids (OlDefaultFolders enum).
$script:OutlookFolderCalendar = 9
$script:OutlookFolderTasks    = 13

# Date format Outlook's Items.Restrict filter expects for [Start] / [DueDate].
$script:OutlookRestrictDateFormat = 'MM/dd/yyyy hh:mm tt'

# MAPI is the messaging namespace every Outlook default folder hangs off.
$script:OutlookMapiNamespace = 'MAPI'

# Outlook stores "no due date" as a sentinel far in the future; anything at or
# beyond this year is treated as unset.
$script:OutlookNoDateYear = 4000

$script:OutlookIconCalendar = [char]::ConvertFromUtf32(0x1F4C5)   # calendar
$script:OutlookIconTasks    = [char]::ConvertFromUtf32(0x1F5D2)   # spiral notepad
$script:OutlookIconParty    = [char]::ConvertFromUtf32(0x1F389)   # party popper
$script:OutlookIconCheck    = [char]::ConvertFromUtf32(0x2705)    # check mark


function Get-OutlookComApplication {
    # Private. Single point that enforces the Windows + desktop-Outlook
    # requirement and hands back a live Outlook.Application COM object.
    # Returns $null (after a one-line yellow hint) when the platform is wrong
    # or Outlook can't be reached, so every caller shares one guard instead of
    # repeating the platform branch. Unapproved verb is fine — not user-facing.
    $isWindows = ($IsWindows -or ($env:OS -eq 'Windows_NT'))

    if (-not $isWindows) {
        Write-Host "Outlook COM automation requires Windows desktop Outlook." -ForegroundColor Yellow
        return $null
    }

    try {
        $application = New-Object -ComObject Outlook.Application
        return $application
    }
    catch {
        Write-Host "Could not reach Outlook. Is the desktop client installed?" -ForegroundColor Yellow
        return $null
    }
}


function Get-OutlookDefaultFolder {
    # Private. Resolves an Outlook default folder (Calendar, Tasks, ...) through
    # the shared platform guard, wrapping the COM navigation so a transient
    # fault (Outlook busy, a MAPI security prompt) fails soft as $null instead
    # of throwing. Centralizes the acquire -> namespace -> folder sequence the
    # ol-Get- functions would otherwise repeat.
    param(
        [Parameter(Mandatory)] [int] $FolderId
    )

    $application = Get-OutlookComApplication
    if ($null -eq $application) {
        return $null
    }

    try {
        $namespace = $application.GetNamespace($script:OutlookMapiNamespace)
        $folder = $namespace.GetDefaultFolder($FolderId)
        return $folder
    }
    catch {
        Write-Host "Could not read the Outlook folder. Is Outlook busy or blocked by a dialog?" -ForegroundColor Yellow
        return $null
    }
}


function ConvertFrom-OutlookResponseStatus {
    # Private. Maps an OlResponseStatus int to a readable string.
    param([int] $Status)

    switch ($Status) {
        1 {
            return 'Organizer'
        }

        2 {
            return 'Tentative'
        }

        3 {
            return 'Accepted'
        }

        4 {
            return 'Declined'
        }

        5 {
            return 'NotResponded'
        }

        default {
            return 'None'
        }
    }
}


function ConvertFrom-OutlookTaskStatus {
    # Private. Maps an OlTaskStatus int to a readable string.
    param([int] $Status)

    switch ($Status) {
        1 {
            return 'InProgress'
        }

        2 {
            return 'Complete'
        }

        3 {
            return 'Waiting'
        }

        4 {
            return 'Deferred'
        }

        default {
            return 'NotStarted'
        }
    }
}


function ConvertFrom-OutlookImportance {
    # Private. Maps an OlImportance int to a readable string.
    param([int] $Importance)

    switch ($Importance) {
        2 {
            return 'High'
        }

        0 {
            return 'Low'
        }

        default {
            return 'Normal'
        }
    }
}


function ol-Get-OutlookAgenda {
    # Today's calendar events (recurrences expanded) as objects. Emits data
    # only — formatting lives in ol-Show-OutlookAgenda.
    [CmdletBinding()]
    param(
        [datetime] $Date = (Get-Date)
    )

    $calendar = Get-OutlookDefaultFolder -FolderId $script:OutlookFolderCalendar
    if ($null -eq $calendar) {
        return $null
    }

    $items = $calendar.Items
    $items.IncludeRecurrences = $true
    $items.Sort('[Start]')

    $dayStart = $Date.Date
    $dayEnd = $Date.Date.AddDays(1).AddSeconds(-1)

    $startText = $dayStart.ToString($script:OutlookRestrictDateFormat)
    $endText = $dayEnd.ToString($script:OutlookRestrictDateFormat)

    # Bound the window on [Start], not [End]: with IncludeRecurrences the
    # supported day-range pattern filters on Start, and an all-day event ends at
    # next-day midnight — an [End] bound would silently drop it.
    $filter = "[Start] >= '$startText' AND [Start] <= '$endText'"

    $restricted = $items.Restrict($filter)

    $events = New-Object System.Collections.Generic.List[object]

    foreach ($appointment in $restricted) {
        $responseText = ConvertFrom-OutlookResponseStatus -Status ([int]$appointment.ResponseStatus)

        $row = [PSCustomObject]@{
            Start          = $appointment.Start
            End            = $appointment.End
            Subject        = $appointment.Subject
            Location       = $appointment.Location
            Organizer      = $appointment.Organizer
            IsAllDay       = [bool]$appointment.AllDayEvent
            ResponseStatus = $responseText
        }

        $events.Add($row)
    }

    # Comma-wrap so an empty list survives the return as an empty collection
    # (a bare `return $events` enumerates to $null, hiding the empty-day path).
    return ,$events
}


function ol-Show-OutlookAgenda {
    # Renders today's meetings as a time-sorted table.
    [CmdletBinding()]
    param(
        [datetime] $Date = (Get-Date)
    )

    $events = ol-Get-OutlookAgenda -Date $Date

    if ($null -eq $events) {
        return
    }

    if ($events.Count -eq 0) {
        Write-Host "No meetings today $script:OutlookIconParty"
        return
    }

    $events |
        Sort-Object Start |
        Select-Object `
            @{ Name = 'Time';     Expression = { $_.Start.ToString('HH:mm') } },
            @{ Name = 'End';      Expression = { $_.End.ToString('HH:mm') } },
            Subject,
            Location,
            Organizer,
            ResponseStatus |
        Format-Table -AutoSize |
        Out-Host
}


function ol-Get-OutlookTasks {
    # Open tasks that are due today or overdue (the "expected to work on"
    # items). Completed tasks are excluded. Emits data only.
    [CmdletBinding()]
    param(
        [datetime] $Date = (Get-Date)
    )

    $taskFolder = Get-OutlookDefaultFolder -FolderId $script:OutlookFolderTasks
    if ($null -eq $taskFolder) {
        return $null
    }

    $dayEnd = $Date.Date

    $tasks = New-Object System.Collections.Generic.List[object]

    foreach ($task in $taskFolder.Items) {
        if ([bool]$task.Complete) {
            continue
        }

        $dueDate = $task.DueDate
        if ($dueDate.Year -ge $script:OutlookNoDateYear) {
            continue
        }

        if ($dueDate.Date -gt $dayEnd) {
            continue
        }

        $statusText = ConvertFrom-OutlookTaskStatus -Status ([int]$task.Status)
        $importanceText = ConvertFrom-OutlookImportance -Importance ([int]$task.Importance)

        $row = [PSCustomObject]@{
            Subject         = $task.Subject
            DueDate         = $dueDate
            Status          = $statusText
            Importance      = $importanceText
            PercentComplete = [int]$task.PercentComplete
        }

        $tasks.Add($row)
    }

    # Comma-wrap so an empty list survives the return (see ol-Get-OutlookAgenda).
    return ,$tasks
}


function ol-Show-OutlookTasks {
    # Renders today's / overdue open tasks as a table.
    [CmdletBinding()]
    param(
        [datetime] $Date = (Get-Date)
    )

    $tasks = ol-Get-OutlookTasks -Date $Date

    if ($null -eq $tasks) {
        return
    }

    if ($tasks.Count -eq 0) {
        Write-Host "No tasks due today $script:OutlookIconCheck"
        return
    }

    $tasks |
        Sort-Object DueDate |
        Select-Object `
            Subject,
            @{ Name = 'Due'; Expression = { $_.DueDate.ToString('MM/dd') } },
            Status,
            Importance,
            PercentComplete |
        Format-Table -AutoSize |
        Out-Host
}


function ol-Show-OutlookDay {
    # Composed day view: today's meetings, then the tasks to work on. Both
    # sections delegate to their own ol-Get-/ol-Show- pair.
    [CmdletBinding()]
    param(
        [datetime] $Date = (Get-Date)
    )

    $application = Get-OutlookComApplication
    if ($null -eq $application) {
        return
    }

    $header = $Date.ToString('dddd, MMMM d')
    Write-Host ""
    Write-Host "$script:OutlookIconCalendar $header" -ForegroundColor Cyan

    ol-Show-OutlookAgenda -Date $Date

    Write-Host ""
    Write-Host "$script:OutlookIconTasks To work on today" -ForegroundColor Cyan

    ol-Show-OutlookTasks -Date $Date
}


Set-Alias -Name ol-day -Value ol-Show-OutlookDay
