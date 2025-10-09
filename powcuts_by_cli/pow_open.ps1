


function o-profile-pshome {
	Start-Process $PSHOME\Microsoft.PowerShell_profile.ps1
} 	

function o-profile-userprofile {
	Start-Process $env:USERPROFILE\Documents\PowerShell\Microsoft.PowerShell_profile.ps1
} 	

function o-profile {
	Start-Process $PROFILE
}

function o-pow-common {
	Start-Process "$path_to_bashcuts\powcuts_by_cli\pow_common.ps1"
}

function o-pow-az-cli {
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

function o-pow-git {
	Start-Process "$path_to_bashcuts\powcuts_by_cli\git_common.ps1"
}


function o-pow-jir {
	Start-Process "$path_to_bashcuts\powcuts_by_cli\jira_automations.ps1"
}

function o-bashcuts {
	code "$path_to_bashcuts/bashcuts"
}
