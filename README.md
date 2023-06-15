Tools used within these alias shortcuts
node - https://nodejs.org/en/download
in order to use powershell shortcuts -> Powershell 7 (and higher) - Installation instructions by operating system: https://github.com/powershell/powershell#get-powershell
GitHub CLI: https://cli.github.com/
CumulusCI: https://cumulusci.readthedocs.io/en/stable/
jQ: https://stedolan.github.io/jq/
sfdx plugins:
sfdx scanner: https://forcedotcom.github.io/sfdx-scanner/
sfdx texei: https://github.com/texei/texei-sfdx-plugin
sfdx shane-plugins: https://github.com/mshanemc/shane-sfdx-plugins
The bashcuts commands (for the majority of commands) have a convention of 'verb-noun' and meant to be auto-filled with tab-tab to avoid any typos or copy/paste mistakes
image

Press tab twice for auto-fill and available command options:
image

To See Where Shortcuts our Loaded and may be available
"o-" for "Open" --> "o-sfdx" will open the file containing all aliases and supporting logic for sfdx cli shortcuts. With the sfdx-bashcuts (or any bashcuts commands file) can be easily searched, modified, or new commands added and can be committed. When modifying files enter the command "reinit" when done to reload the current terminal instead of closing and repopening.
To see all possible aliases and associated functions, in bash terminal, type "o-" and then press tab twice to see options of each file of shortcuts
image

image

bashcuts setup
Shortcuts using bashrc or bash_profile files. Many of the shortcuts provide prompts to support populated necessary arguments/flags to make the functions work

You may not already have a .bashrc file on your system. To create one, open a bash terminal and copy and paste the below command in the terminal or create a new file in your user directory with the name .bashrc

touch ~/.bashrc

You can also use the .bash_profile file instead of the .bashrc.

To get started, add the below content and associated logic to the your .bashrc file and from there it will load up all the aliases and functions referenced from the .bcut_home file.

To open the .bashrc file that was created above type in the terminal: start ~/.bashrc

IMPORTANT clone the bashcuts directory into a folder directory structure without spaces or the source command won't be able to evaluate the path correctly (still working on setting it up correctly to not care about spaces)

	PATH_TO_BASHCUTS="/c/path/to/your-parent-directory-where-bashcuts-will-be-cloned-into/"  
	if [ -f $PATH_TO_BASHCUTS/bashcuts/.bcut_home ]; 
	then 
	    echo "bashrc loaded"
	    source $PATH_TO_BASHCUTS/bashcuts/.bcut_home
	else
	    echo "missing bashrc"
	fi
IMPORTANT FOR MAC USERS There are several use cases of the command "start" that allows files and websites to be opened from the terminal. This command needs to be replace with "open". This can be done by opening up bashcuts repository in VS Code and doing a global find and replace all for "start" and replace with "open"

