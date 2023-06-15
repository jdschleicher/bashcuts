


function o-profile {
	# code $profile #Microsoft.Powershell_profile.ps1
	code "C:\Program Files\PowerShell\7\Microsoft.PowerShell_profile.ps1"
} 	

function o-pow-common {
	code "$path_to_bashcuts\powcuts_by_cli\pow_common.ps1"
}

function o-pow-az-ci {
	code "$path_to_bashcuts\powcuts_by_cli\pow_az_cli.ps1"
}

function o-pester {
	code "$path_to_bashcuts\powcuts_by_cli\pester.ps1"
}

function o-pow-sfdx {
	code "$path_to_bashcuts\powcuts_by_cli\sfdx_cli.ps1"
}

Set-Alias -Name nfp -Value c:\windows\notepad.exe

function reinit {
    Invoke-Command { & "pwsh.exe" } -NoNewScope 
}

function new-list($new_list_variable) {
    Set-Variable -Name "$new_list_variable" -Value ([system.collections.generic.list[string]]::new()) -Scope global
}
