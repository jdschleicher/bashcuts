  Write-Host "powershell starting"

$pow_sfdxcli = Get-Content "$path_to_bashcuts\powcuts_by_cli\sfdx_cli.ps1"
if ($pow_sfdxcli -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\sfdx_cli.ps1"
} else {
    Write-Host "no sfdx cli"
}

$pow_azcli = Get-Content "$path_to_bashcuts\powcuts_by_cli\pow_az_cli.ps1"
if ($pow_azcli -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\pow_az_cli.ps1"
} else {
    Write-Host "no az cli"
}

$pow_common = Get-Content "$path_to_bashcuts\powcuts_by_cli\pow_common.ps1"
if ($pow_common -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\pow_common.ps1"
} else {
    Write-Host "no powcli"
}

$pow_open = Get-Content "$path_to_bashcuts\powcuts_by_cli\pow_open.ps1"
if ($pow_open -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\pow_open.ps1"
} else {
    Write-Host "no pow_open"
}

$pester = Get-Content "$path_to_bashcuts\powcuts_by_cli\pester.ps1"
if ($pester -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\pester.ps1"
} else {
    Write-Host "no pester"
}

$git_common = Get-Content "$path_to_bashcuts\bashcuts_by_cli\.gitcli_bashcuts"
if ($git_common -ne $NULL) {
    . "$path_to_bashcuts\powcuts_by_cli\git_common.ps1"
} else {
    Write-Host "no pester"
}

$jira_setup = Get-Content "$path_to_bashcuts\powcuts_by_cli\jira_automations.ps1"
if ($jira_setup -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\jira_automations.ps1"
} else {
    Write-Host "no jira_automations.ps1"
}

$azdevops_db = Get-Content "$path_to_bashcuts\powcuts_by_cli\azdevops_db.ps1"
if ($azdevops_db -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\azdevops_db.ps1"
} else {
    Write-Host "no azdevops_db.ps1"
}

$azdevops_workitems = Get-Content "$path_to_bashcuts\powcuts_by_cli\azdevops_workitems.ps1"
if ($azdevops_workitems -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\azdevops_workitems.ps1"
} else {
    Write-Host "no azdevops_workitems.ps1"
}

$azdevops_projects = Get-Content "$path_to_bashcuts\powcuts_by_cli\azdevops_projects.ps1"
if ($azdevops_projects -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\azdevops_projects.ps1"
} else {
    Write-Host "no azdevops_projects.ps1"
}

$pow_timer = Get-Content "$path_to_bashcuts\powcuts_by_cli\pow_timer.ps1"
if ($pow_timer -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\pow_timer.ps1"
} else {
    Write-Host "no pow_timer.ps1"
}
