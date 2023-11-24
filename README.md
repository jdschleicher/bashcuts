# Table of Contents

* [Tools used within these alias shortcuts and require installation ahead of time](#tools-used)
* [System Setup for bash and PowerShell Profiles](#system-setup)
* [How to use bashcuts](#how-to)

<br>

***

<br>

# <a name="tools-used"></a>Tools used within these alias shortcuts and require installation ahead of time

- node - https://nodejs.org/en/download
- in order to use powershell shortcuts -> Powershell 7 (and higher) - Installation instructions by operating system: https://github.com/powershell/powershell#get-powershell
- GitHub CLI: https://cli.github.com/
- CumulusCI: https://cumulusci.readthedocs.io/en/stable/
- jQ: https://stedolan.github.io/jq/
- sfdx plugins:
  - sfdx scanner: https://forcedotcom.github.io/sfdx-scanner/
  - sfdx texei: https://github.com/texei/texei-sfdx-plugin
  - sfdx shane-plugins: https://github.com/mshanemc/shane-sfdx-plugins
  - sfdx data move utility sfdmu: https://github.com/forcedotcom/SFDX-Data-Move-Utility
 
<br>

***

<br>

# <a name="system-setup"></a> System Setup for bash and PowerShell Profiles

<br>

**IMPORTANT FOR MAC USERS** There are several use cases of the command "start" that allows files and websites to be opened from the terminal. This command needs to be replace with "open". This can be done by opening up bashcuts repository in VS Code and doing a global find and replace all for "start" and replace with "open"

<br>

## SETUP FOR BASH TERMINAL:

Shortcuts using bashrc or bash_profile files. Many of the shortcuts provide prompts to support populated necessary arguments/flags to make the functions work

You may not already have a .bashrc file on your system. To create one, open a bash terminal and copy and paste the below command in the terminal or create a new file in your user directory with the name **.bashrc**

**touch ~/.bashrc**

You can also use the .bash_profile file instead of the .bashrc.

To get started, add the below content and associated logic to the your .bashrc file and from there it will load up all the aliases and functions referenced from the .bcut_home file.

To open the .bashrc file that was created above type in the terminal: start ~/.bashrc

**IMPORTANT** -- clone the bashcuts directory into a folder directory structure without spaces or the source command won't be able to evaluate the path correctly (still working on setting it up correctly to not care about spaces). Also note you will have to provide that path to the variable below:

```
PATH_TO_BASHCUTS="/c/path/to/your-parent-directory-where-bashcuts-will-be-cloned-into/"  
if [ -f $PATH_TO_BASHCUTS/bashcuts/.bcut_home ]; 
then 
    echo "bashrc loaded"
    source $PATH_TO_BASHCUTS/bashcuts/.bcut_home
else
    echo "missing bashrc"
fi
	
```

<br>

## SETUP FOR PowerShell Terminal AND PowerShell Debugger Terminal in VS Code:

Once PowerShell Core has been installed on your machine you can open up a new PowerShell terminal in VS Code or a standalone PowerShell Terminal.

With the terminal open enter "$profile" into the terminal to see where the terminal's expecting a profile file to exist. This file may not exist so we may need to create it. 

To create the file enter the below powershell command to create an empty file at the expected profile path:

```
New-Item -ItemType File -Path $profile
```

To edit the profile select, enter the below command:

```
start $profile
```

This will open up the PowerShell profile and may prompt for which application to open the file in. Choose VSCode and select the checkbox to use VSCode for all ps1 files. This gives us syntax highlighting and other features that can be leveraged within the VS Code IDE.

With the PowerShell Profile open add the following code snippet AND **IMPORTANT** replace the path directories to point to where the bashcuts directory was cloned to.

We will know if its working as expected if the terminal prompts out "powershell starting" on initialization/opening:

```

$path_to_bashcuts_parent_directory = 'C:\git'
$bashcuts_git_directory = "bashcuts"
if ("$path_to_bashcuts_parent_directory\$bashcuts_git_directory" -ne $NULL) {
    $path_to_bashcuts = "$path_to_bashcuts_parent_directory\$bashcuts_git_directory"
    Write-Host "PowerShell bashcuts exists"
	. "$path_to_bashcuts\powcuts_home.ps1"
} else {
	Write-Host "Cannot find bashcuts"
    Write-Host "pow_home not setup"
}

```

For the PowerShell terminal from the VS Code PowerShell extension, we can use the same steps as above. It more than likely will be a different profile to update.

Here's a screen shot of the commands to the empty profile being opened in VS Code:

![image](https://github.com/jdschleicher/bashcuts/assets/3968818/c76f2eb0-6091-496a-bfe5-d1dafe557b27)

Here's a side-by-side view of a regular PowerShell core terminal and the PowerShell VS Code extension terminal:

![image](https://github.com/jdschleicher/bashcuts/assets/3968818/f52313f0-a877-4971-828a-954fead5c25d)

***

<br>

# <a name="how-to"></a>How to use bashcuts

<br>

### The bashcuts commands (for the majority of commands) have a convention of 'verb-noun' and meant to be auto-filled with tab-tab to avoid any typos or copy/paste mistakes
![image](https://github.com/jdschleicher/bashcuts/assets/3968818/6eeb578a-e6f1-4e3e-89f2-efd4e09872dc)


### Press tab twice for auto-fill and available command options:
![image](https://github.com/jdschleicher/bashcuts/assets/3968818/3e4b7f16-831e-4134-a5a5-3998f5e6032e)


### To See Where Shortcuts our Loaded and may be available
- "o-" for "Open" --> "o-sfdx" will open the file containing all aliases and supporting logic for sfdx cli shortcuts. With the sfdx-bashcuts (or any bashcuts commands file) can be easily searched, modified, or new commands added and can be committed. When modifying files enter the command "reinit" when done to reload the current terminal instead of closing and repopening.
- To see all possible aliases and associated functions, in bash terminal, type "o-" and then press tab twice to see options of each file of shortcuts
![image](https://github.com/jdschleicher/bashcuts/assets/3968818/cc4af98b-2e74-4d30-b64e-1637c7fd0823)

![image](https://github.com/jdschleicher/bashcuts/assets/3968818/87f2fefe-f81f-42a8-b6fc-100e2292703b)

