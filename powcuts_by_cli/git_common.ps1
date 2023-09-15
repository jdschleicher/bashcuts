
function g-log-graph {
    git log --graph --full-history --all --color --decorate=short
}

function g-log {
    git log --graph --name-status --pretty=format:'%h - %an, %ar : %s'
}

function g-log-one-line {
    git log --pretty=oneline --graph --name-status
}

function o-gcl {
    git config --local -e
}

function o-gcg {
    git config --global -e
}

function g-stash-apply {
    git stash apply stash@{0}
}

function g-reset-commitandfiles {
    git reset --hard HEAD~1
}

function g-reset-commit {
    git reset --soft HEAD^1
}

function g-reset-head {
    git reset --hard HEAD
}

function g-reset-file-by-commit {
    $FILE_TO_RESET = Read-Host "What file would you like to reset?"
    $COMMIT_HASH = Read-Host "What commit hash would you like to reset the file to?"
    git checkout $COMMIT_HASH -- $FILE_TO_RESET
    Write-Host "git checkout $COMMIT_HASH -- $FILE_TO_RESET"
}

# git functions
function gc {
    param (
        [string]$message
    )
    git commit -m $message
}

function gbp {
    Write-Host "inheres"
    $current_branch = git branch --show-current
    Write-Host $current_branch
    git push origin $current_branch
}

function gca {
    param (
        [string]$message
    )

    git commit -am $message
}

function g-rename-current-branch {
    $NEW_BRANCH_NAME = Read-Host "What is the new name of the branch?"
    git branch -m $NEW_BRANCH_NAME
}

function g-search-string {
    $search_string = Read-Host "Enter the search string"
    git log -S $search_string
}

function g-search-file-updates {
    $FILENAME = Read-Host "What is the file with filepath to search?"
    Write-Host "Searching Updates"
    git log --all --source -- $FILENAME | Select-String -Pattern "refs/heads/.*" | ForEach-Object {
        $branch = $_.Matches[0].Value
        $commit = git log --pretty=oneline --graph -1 --format='%aI %S' $branch -- $FILENAME
        "$branch : $commit"
    } | Sort-Object -Descending
}

function g-file-history {
    $FILENAME = Read-Host "What is the file with filepath to search?"
    Write-Host "Searching Updates"
    git log --all --source -- $FILENAME | Select-String -Pattern "refs/heads/.*" | ForEach-Object {
        $branch = $_.Matches[0].Value
        $commit = git log -1 --format='%aI %S' $branch -- $FILENAME
        "$branch : $commit"
    } | Sort-Object -Descending
}

function g-set-tracking-upstream-remote {
    $BRANCH_NAME = Read-Host "What is the branch to set tracking remote?"
    Write-Host "git branch --set-upstream-to=origin/$BRANCH_NAME $BRANCH_NAME"
    git branch --set-upstream-to=origin/$BRANCH_NAME $BRANCH_NAME
}
function g-ignore-filereset {
    git rm --cached -r $args[0]
}
function g-reset-staged {
    git reset HEAD $args[0]
}

function g-discard-by-file {
    $FILE_PATH_TO_DISCARD = Read-Host "What file would you like to discard the updates for?"
    Write-Host "git checkout -- $FILE_PATH_TO_DISCARD"
    git checkout -- $FILE_PATH_TO_DISCARD
}

function g-restore-by-file {
    $FILE_PATH_TO_RESTORE = Read-Host "What file would you like to restore from staged?"
    Write-Host "git restore --staged $FILE_PATH_TO_RESTORE"
    git restore --staged $FILE_PATH_TO_RESTORE
}

function g-reset-last-commit-to-staged {
    Write-Host "git reset --soft HEAD~1"
    git reset --soft HEAD~1
}

function g-search-all-by-commit {
    $COMMIT_ID = Read-Host "What commit ID would you like to search for?"
    Write-Host "git branch -a --contains '$COMMIT_ID'"
    git branch -a --contains "$COMMIT_ID"
}

function g-search-all-commits-by-file {
    $FILE_TO_SEARCH = Read-Host "What file would you like to search for?"
    Write-Host "git log --all '$FILE_TO_SEARCH'"
    git log --all "$FILE_TO_SEARCH"
}

function g-delete-current {
    $BRANCH_TO_CHECKOUT = Read-Host "What branch would you like to checkout?"
    Write-Host $BRANCH_TO_CHECKOUT
    $currentBranchToDelete = git branch --show-current
    Write-Host "current branch: $currentBranchToDelete"
    Write-Host "git checkout $BRANCH_TO_CHECKOUT"
    git checkout $BRANCH_TO_CHECKOUT
    Write-Host "Locally deleting: $currentBranchToDelete"
    git branch -D $currentBranchToDelete
}

function g-delete-current-from-remote-and-local {
    $BRANCH_TO_CHECKOUT = Read-Host "What branch would you like to checkout?"
    Write-Host $BRANCH_TO_CHECKOUT
    $currentBranchToDelete = git branch --show-current
    Write-Host "current branch: $currentBranchToDelete"
    Write-Host "git checkout $BRANCH_TO_CHECKOUT"
    git checkout $BRANCH_TO_CHECKOUT
    Write-Host "Locally deleting: $currentBranchToDelete"
    git branch -D $currentBranchToDelete
    Write-Host "deleting branch from origin"
    Write-Host "git push -d origin '$currentBranchToDelete'"
    git push -d origin "$currentBranchToDelete"
}

function g-update-remote {
    $newRemote = Read-Host "What is the new remote?"
    git remote rm origin
    git remote add origin $newRemote
    git config master.remote origin
    git config master.merge refs/heads/master
}

function g-quick-commit-push {
    git add .
    git commit -am $args[0]
    gbp
}

function g-show-branches-local {
    git branch
}


function g-show-latest-commits-local-and-remote {
    git for-each-ref --sort=-committerdate refs/heads refs/remotes --format='%(authordate:short) %(color:red)%(objectname:short) %(color:yellow)%(refname:short)%(color:reset) (%(color:green)%(committerdate:relative)%(color:reset)) %(authorname)'
}



function gs {
    git status
}
