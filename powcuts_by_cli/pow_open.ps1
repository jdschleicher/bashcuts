


function o-profile-pshome {
	Start-Process $PSHOME\Microsoft.PowerShell_profile.ps1
} 	

function o-profile {
	Start-Process $PROFILE
}

function o-pow-common {
	Start-Process "$path_to_bashcuts\powcuts_by_cli\pow_common.ps1"
}

function o-pow-az-ci {
	Start-Process "$path_to_bashcuts\powcuts_by_cli\pow_az_cli.ps1"
}

function o-pester {
	Start-Process "$path_to_bashcuts\powcuts_by_cli\pester.ps1"
}

function o-pow-sfdx {
	Start-Process "$path_to_bashcuts\powcuts_by_cli\sfdx_cli.ps1"
}

function o-pow-open {
	Start-Process "$path_to_bashcuts\powcuts_by_cli\pow_open.ps1"
} 	

