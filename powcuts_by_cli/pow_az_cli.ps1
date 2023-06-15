function az-create-userstory() {

    $STORY_TITLE = Read-Host "What is the title of the User Story?"
    $DESCRIPTION = Read-Host "What is the description?" 
    $PRIORITY = Read-Host "What is the priority? 1=LOW,2=MEDIUM,3=HIGH,4=SUPER-HIGH" 
    $STORY_POINTS = Read-Host "What is the story point amount?"

    $ACCEPTANCE_CRITERIA = Read-Host 'What is the Acceptance Criteria'
    $DASH="-"
    $FORMATTED_AC = "${DASH} ${ACCEPTANCE_CRITERIA}"
    $UPDATED_AC=$FORMATTED_AC
    $ADDITIONAL_AC_PROMPT = "More AC (Y/N)?"
    do {
        $ADDITIONAL_AC_RESPONSE = Read-Host -Prompt $ADDITIONAL_AC_PROMPT
        
        if ($ADDITIONAL_AC_RESPONSE -eq 'y') {

            $ADDITIONAL_AC = Read-Host "Enter additional AC: " 
            $LINEBREAK = "<br/><br/>"
            $UPDATED_AC="$UPDATED_AC $LINEBREAK $DASH $ADDITIONAL_AC" 

        }

    } until ($ADDITIONAL_AC_RESPONSE -eq 'n')

    Write-Host $UPDATED_AC

    Write-Host az boards work-item create --title "$STORY_TITLE" `
        --assigned-to "$env:AZ_USER_EMAIL" `
        --project "$env:AZ_PROJECT" `
        --area "$env:AZ_AREA" `
        --iteration "$env:AZ_ITERATION" `
        --fields `
            "Microsoft.VSTS.Scheduling.StoryPoints=$STORY_POINTS" `
            "Microsoft.VSTS.Common.Priority=$PRIORITY" `
            "Microsoft.VSTS.Common.AcceptanceCriteria=$UPDATED_AC"  `
        --type "user story"  `
        --description "$DESCRIPTION" `
        --open

    az boards work-item create --title "$STORY_TITLE" `
        --assigned-to "$env:AZ_USER_EMAIL" `
        --project "$env:AZ_PROJECT" `
        --area "$env:AZ_AREA" `
        --iteration "$env:AZ_ITERATION" `
        --fields `
            "Microsoft.VSTS.Scheduling.StoryPoints=$STORY_POINTS" `
            "Microsoft.VSTS.Common.Priority=$PRIORITY" `
            "Microsoft.VSTS.Common.AcceptanceCriteria=$UPDATED_AC"  `
        --type "user story"  `
        --description "$DESCRIPTION" `
        --open


}