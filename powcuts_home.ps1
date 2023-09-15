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
if ($pow_open -ne $NULL) {
 . "$path_to_bashcuts\powcuts_by_cli\pester.ps1"
} else {
    Write-Host "no pester"
}