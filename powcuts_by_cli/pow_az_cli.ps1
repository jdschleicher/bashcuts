function az-create-userstory() {

    $STORY_TITLE = Read-Host "What is the title of the User Story?"
    $DESCRIPTION = Read-Host "What is the description?"
    $PRIORITY = Read-Host "What is the priority? 1=LOW,2=MEDIUM,3=HIGH,4=SUPER-HIGH"
    $STORY_POINTS = Read-Host "What is the story point amount?"

    $ACCEPTANCE_CRITERIA = Read-Host 'What is the Acceptance Criteria'
    $DASH = "-"
    $FORMATTED_AC = "${DASH} ${ACCEPTANCE_CRITERIA}"
    $UPDATED_AC = $FORMATTED_AC
    $ADDITIONAL_AC_PROMPT = "More AC (Y/N)?"

    do {
        $ADDITIONAL_AC_RESPONSE = Read-Host -Prompt $ADDITIONAL_AC_PROMPT

        if ($ADDITIONAL_AC_RESPONSE -eq 'y') {
            $ADDITIONAL_AC = Read-Host "Enter additional AC: "
            $LINEBREAK = "<br/><br/>"
            $UPDATED_AC = "$UPDATED_AC $LINEBREAK $DASH $ADDITIONAL_AC"
        }
    } until ($ADDITIONAL_AC_RESPONSE -eq 'n')

    Write-Host $UPDATED_AC

    $fields = @(
        "Microsoft.VSTS.Scheduling.StoryPoints=$STORY_POINTS",
        "Microsoft.VSTS.Common.Priority=$PRIORITY",
        "Microsoft.VSTS.Common.AcceptanceCriteria=$UPDATED_AC"
    )

    $result = New-AzDevOpsWorkItem `
        -Type        'user story' `
        -Title       $STORY_TITLE `
        -Description $DESCRIPTION `
        -AssignedTo  $env:AZ_USER_EMAIL `
        -Project     $env:AZ_PROJECT `
        -Area        $env:AZ_AREA `
        -Iteration   $env:AZ_ITERATION `
        -Fields      $fields `
        -Open

    if ($result.ExitCode -ne 0) {
        Write-Host "az boards work-item create failed: $($result.Error)" -ForegroundColor Red
        return
    }

    return $result.Json
}
