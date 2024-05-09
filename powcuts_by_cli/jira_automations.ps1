<#
- NEXT
 
- add time to story
- jira views

#>

function choose_from_list {
    param (
        $options_to_choose,
        [Parameter(Mandatory=$true)]
        $dot_notation_field_to_show
    )
    
    for ($option_index = 0; $option_index -lt $options_to_choose.Length; $option_index++) {

        $current_option = $options_to_choose[$option_index]

        if ( $null -ne $dot_notation_field_to_show) {

            $dot_notation_steps = $dot_notation_field_to_show -split "\."
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

            Write-Host -ForegroundColor Green -Backgroundcolor White "$($option_index+1).) $($dot_notation_field_to_show)"

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
        choose_from_list -options_to_choose $options_to_choose -dot_notation_field_to_show $dot_notation_field_to_show
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
    $parent_epic = choose_from_list -options_to_choose $bashcuts_jira_config.epics -dot_notation_field_to_show "fields.summary"


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

function jira_add_time_by_story_key {

    $base_url = $bashcuts_jira_config.instance_url
    Write-Host "base url : $base_url"

    $time_spent = Read-Host "How much time was spent? ( e.g. '2d' , '.25h' )"
    $comment = Read-Host "What comments or notes for the work log (press enter if blank)?"

    $story_issue_key = $null
    $enter_issue_key_manually = Read-Host "Press 'y' or 'yes' for manual issue entry. Press 'enter' for Current Sprint selection"

    if ( $enter_issue_key_manually.toLower() -eq "yes" -or $enter_issue_key_manually.toLower() -eq "y" ) {

        $story_issue_key = Read-Host "What is the Story Key to log time against? ( e.g. 'VPRD-1148')"

    } else {

        $project_key = $bashcuts_jira_config.project_key
        $active_sprint_issues_jql = "project = $project_key AND issuetype = Story AND Sprint IN openSprints() ORDER BY status DESC, priority DESC, updated DESC"
        $csv_fields_to_return = "key,summary"

        $story_issues = jira_run_jql_query -jql_query $active_sprint_issues_jql -csv_fields_to_return $csv_fields_to_return
        $chosen_story_issue = choose_from_list -options_to_choose $story_issues -dot_notation_field_to_show "fields.summary"
        $story_issue_key = $chosen_story_issue.key
    }

    $is_previous_date = Read-Host "Is this time log for a Previous date? (yes or y)"
    $current_date_time_jira_format = $null
    if ( $is_previous_date.toLower() -eq "yes" -or $is_previous_date.toLower() -eq "y" ) {

        $previous_date = Read-Host "What is previous date to log time? ( Must be in dd/mm or dd-mm format)"
        $split_previous_date = $previous_date -split '[/-]'
        $day_split = $split_previous_date[1]
        $month_split = $split_previous_date[0]
    
        $current_year = Get-Date -Format "yyyy"
        $current_get_date = Get-Date -Year $current_year -Month $month_split -Day $day_split
        $current_date_time_jira_format = $current_get_date.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffzz00")
        Write-Output $current_date_time_jira_format

    } else {

        $current_get_date = Get-Date 
        $current_date_time_jira_format = $current_get_date.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffzz00")
        Write-Output $current_date_time_jira_format
    
    }

    $body = [PSCustomObject]@{
        timeSpent = $time_spent
        comment = $comment
        started = $current_date_time_jira_format
    }

    $body_json = $body | ConvertTo-Json -Depth 12

    $jira_token = $bashcuts_jira_config.token
    $headers = @{
        Authorization = "Bearer $jira_token"
        ContentType = "application/json"
    }

    $api_url = "$base_url/rest/api/2/issue/$story_issue_key/worklog"
    Write-Host "endpoint url : $api_url"
    
    $response = Invoke-RestMethod -Uri $api_url -Method Post -Headers $headers -Body $body_json -ContentType "application/json"
    Write-Output $response

}

function jira_run_jql_query {
	param(
        [Parameter(Mandatory=$true)]
		$jql_query,
        [Parameter(Mandatory=$true)]
        $csv_fields_to_return
	)

    $base_url = $bashcuts_jira_config.instance_url
    Write-Host "base url : $base_url"

	$jql_search_endpoint = "$base_url/rest/api/2/search"

	# $ojql_query = "project = VPRD AND issuetype = Epic AND status in (Done, 'In Progress', New) AND resolution = Unresolved ORDER BY status ASC, summary ASC, updated DESC"
	$jql_query_uri = "$($jql_search_endpoint)?jql=$jql_query&fields=$csv_fields_to_return"

	Write-Host "jql_query_uri : $jql_query_uri"

    $jira_token = $bashcuts_jira_config.token
    $jira_username = $bashcuts_jira_config.username
	$base64Credentials = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${jira_username}:${jira_token}"))

	$response = Invoke-RestMethod -Uri $jql_query_uri -Method Get -Headers @{ 
		"Content-Type" = "application/json"
		Authorization = "Basic $base64Credentials"
	}

	$response.issues 

}

function jira_new_epic_with_intiative {

    $base_url = $bashcuts_jira_config.instance_url
    Write-Host "base url : $base_url"

    $project_key = $bashcuts_jira_config.project_key
    Write-Host "project_key: $project_key"

    # Jira API URL for creating an issue
    $apiUrl = "$base_url/rest/api/2/issue/"

    Write-Host -ForegroundColor Green -BackgroundColor White "CHOOSE INITIATIVE"
    $parent_initiative = choose_from_list -options_to_choose $bashcuts_jira_config.initiatives -dot_notation_field_to_show "fields.summary"

    $customer_story_title = Read-Host "Epic Title?"

    $details = Read-Host "Enter Epic Details"

    # Generate the formatted acceptance criteria for Jira
    $formattedCriteria = @"

h3. Epic Details:

$details

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
                name = "Epic"
            }
            components = @(
                [PSCustomObject]@{
                    id = $bashcuts_jira_config.pie_component.id
                }
            )
            
            customfield_10003 = $parent_initiative.key

            customfield_11703 = $parent_initiative.key
            
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

function jira_get_issue_by_key {

    $jira_username = $bashcuts_jira_config.username
    $jira_token = $bashcuts_jira_config.token
    $base64Credentials = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${jira_username}:${jira_token}"))

    $issue_key = Read-Host "What is the issue key to retrieve? (e.g. 'VPRD-1164')"

    
    $base_url = $bashcuts_jira_config.instance_url
    Write-Host "base url : $base_url"

    $apiUrl = "$($base_url)/rest/api/2/issue/$issue_key"
    Write-Host "api url : $apiUrl"

    $response = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers @{
        Authorization = "Basic $base64Credentials"
    } -ContentType "application/json"

    Write-Output $response

}