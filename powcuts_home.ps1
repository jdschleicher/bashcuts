  Write-Host "powershell starting"

$pow_sfdxcli = Get-Content "$path_to_bashcuts\powcuts_by_cli\sfdx_cli.ps1"
if ($pow_sfdxcli -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\sfdx_cli.ps1"
} else {
    Write-Host "no sfdx cli"
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

$azdevops_auth = Get-Content "$path_to_bashcuts\powcuts_by_cli\azdevops_auth.ps1"
if ($azdevops_auth -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\azdevops_auth.ps1"
} else {
    Write-Host "no azdevops_auth.ps1"
}

$azdevops_paths = Get-Content "$path_to_bashcuts\powcuts_by_cli\azdevops_paths.ps1"
if ($azdevops_paths -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\azdevops_paths.ps1"
} else {
    Write-Host "no azdevops_paths.ps1"
}

$azdevops_sync = Get-Content "$path_to_bashcuts\powcuts_by_cli\azdevops_sync.ps1"
if ($azdevops_sync -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\azdevops_sync.ps1"
} else {
    Write-Host "no azdevops_sync.ps1"
}

$azdevops_views = Get-Content "$path_to_bashcuts\powcuts_by_cli\azdevops_views.ps1"
if ($azdevops_views -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\azdevops_views.ps1"
} else {
    Write-Host "no azdevops_views.ps1"
}

$azdevops_find = Get-Content "$path_to_bashcuts\powcuts_by_cli\azdevops_find.ps1"
if ($azdevops_find -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\azdevops_find.ps1"
} else {
    Write-Host "no azdevops_find.ps1"
}

$azdevops_classification = Get-Content "$path_to_bashcuts\powcuts_by_cli\azdevops_classification.ps1"
if ($azdevops_classification -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\azdevops_classification.ps1"
} else {
    Write-Host "no azdevops_classification.ps1"
}

$azdevops_create_pickers = Get-Content "$path_to_bashcuts\powcuts_by_cli\azdevops_create_pickers.ps1"
if ($azdevops_create_pickers -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\azdevops_create_pickers.ps1"
} else {
    Write-Host "no azdevops_create_pickers.ps1"
}

$azdevops_create = Get-Content "$path_to_bashcuts\powcuts_by_cli\azdevops_create.ps1"
if ($azdevops_create -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\azdevops_create.ps1"
} else {
    Write-Host "no azdevops_create.ps1"
}

$azdevops_schema = Get-Content "$path_to_bashcuts\powcuts_by_cli\azdevops_schema.ps1"
if ($azdevops_schema -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\azdevops_schema.ps1"
} else {
    Write-Host "no azdevops_schema.ps1"
}

$azdevops_openers = Get-Content "$path_to_bashcuts\powcuts_by_cli\azdevops_openers.ps1"
if ($azdevops_openers -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\azdevops_openers.ps1"
} else {
    Write-Host "no azdevops_openers.ps1"
}

$azdevops_projects = Get-Content "$path_to_bashcuts\powcuts_by_cli\azdevops_projects.ps1"
if ($azdevops_projects -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\azdevops_projects.ps1"
} else {
    Write-Host "no azdevops_projects.ps1"
}

$azdevops_help = Get-Content "$path_to_bashcuts\powcuts_by_cli\azdevops_help.ps1"
if ($azdevops_help -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\azdevops_help.ps1"
} else {
    Write-Host "no azdevops_help.ps1"
}

$pow_timer = Get-Content "$path_to_bashcuts\powcuts_by_cli\pow_timer.ps1"
if ($pow_timer -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\pow_timer.ps1"
} else {
    Write-Host "no pow_timer.ps1"
}
