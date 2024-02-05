<#
- NEXT
 
- add time to story
- jira views

#>

function choose_from_list {
    param (
        $options_to_choose,
        $field_to_show
    )
    
    for ($option_index = 0; $option_index -lt $options_to_choose.Length; $option_index++) {

        $current_option = $options_to_choose[$option_index]

        if ( $null -ne $field_to_show) {

            $dot_notation_steps = $field_to_show -split "\."
            $final_result_to_display = $null
            for ($dot_notation_index = 0; $dot_notation_index -lt $dot_notation_steps.Length; $dot_notation_index++) {
    
                $dot_notation_to_dive_into = $dot_notation_steps[$dot_notation_index]

                if ( $null -eq $final_result_to_display ) {

                    $final_result_to_display = $current_option.$dot_notation_to_dive_into

                } else {

                    $final_result_to_display = $final_result_to_display.$dot_notation_to_dive_into

                }
    
            }

            Write-Host -ForegroundColor Green -Backgroundcolor White "$($option_index+1).) $($final_result_to_display)"

        } else {

            Write-Host -ForegroundColor Green -Backgroundcolor White "$($option_index+1).) $($field_to_show)"

        }

    }

    $index_choice_as_string = Read-Host "Enter the number of your choice"

    $index_choice = [int32]$index_choice_as_string
    if ($index_choice -ge 1 -and $index_choice -le $options_to_choose.Length) {

        $choice = $options_to_choose[$index_choice - 1]
        Write-Host "You chose: $index_choice"
        return $choice

    } else {
        Write-Host "Invalid choice. Please enter a valid number."
        choose_from_list -options_to_choose $options_to_choose -field_to_show $field_to_show
    }

}

function jira_new_story_with_epic {

    $base_url = $bashcuts_jira_config.instance_url
    Write-Host "base url : $base_url"

    $project_key = $bashcuts_jira_config.project_key
    Write-Host "project_key: $project_key"

    # Jira API URL for creating an issue
    $apiUrl = "$base_url/rest/api/2/issue/"

    Write-Host -ForegroundColor Green -BackgroundColor White "CHOOSE EPIC"
    $parent_epic = choose_from_list -options_to_choose $bashcuts_jira_config.epics -field_to_show "fields.summary"


    Write-Host "Enter Customer Story details:"
    $customer_story_title = Read-Host "Customer Story Title?"

    $story_detail_as_a = Read-Host "Provide input for after the 'As a...'"

    $story_detail_i_want = Read-Host "Provide intput for after the 'I want...'"

    $story_detail_so_that = Read-Host "Provide input for after the 'So that...'"


    $acceptanceCriteria = @()
    # Prompt for acceptance criteria until the user decides to stop
    do {

        $criteria = Read-Host "Enter acceptance criteria"
        $acceptanceCriteria += $criteria

        $moreCriteria = Read-Host "Do you have more acceptance criteria? (yes/no)"

    } while ($moreCriteria.toLower() -eq "yes" -or $moreCriteria.toLower() -eq "y")

    $additional_details = Read-Host "Enter additional story details"

    # Generate the formatted acceptance criteria for Jira
    $formattedCriteria = @"

h3. Customer Story Details:

* *As a:* $story_detail_as_a,

* *I want:* $story_detail_i_want,

* *So that:* $story_detail_so_that

h3. Acceptance Criteria:

* $($acceptanceCriteria -join "`r`n* ")*

h3. Additional Details:

$additional_details

"@

    # Output the formatted acceptance criteria
    Write-Output $formattedCriteria

    # User story data
    $customer_story_data = @{
        fields = @{
            project = @{
                key = $project_key
            }
            summary = "$customer_story_title"
            description = "$formattedCriteria"
            issuetype = @{
                name = "Story"
            }
            components = @(
                [PSCustomObject]@{
                    id = $bashcuts_jira_config.pie_component.id
                }
            )
            
            customfield_10001 = $parent_epic.key
            
        }
    }

    # Convert data to JSON
    $customer_story_data_json = $customer_story_data | ConvertTo-Json -Depth 12

    # Base64 encode credentials
    $jira_username = $bashcuts_jira_config.username
    $jira_token = $bashcuts_jira_config.token
    $base64Credentials = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${jira_username}:${jira_token}"))

    # Make the API request
    $jira_creation_response = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers @{
        Authorization = "Basic $base64Credentials"
    } -Body $customer_story_data_json -ContentType "application/json"

    # Print the response
    Write-Output $jira_creation_response
    Write-Host "Opening Customer Story in browser..."
    start "$base_url/browse/$($jira_creation_response.key)"

}
