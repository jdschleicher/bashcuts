
function jira_new_story {

    $base_url = $bashcuts_jira_config.instance_url
    Write-Host "base url : $base_url"

    $project_key = $bashcuts_jira_config.project_key
    Write-Host "project_key: $project_key"

    # Jira API URL for creating an issue
    $apiUrl = "$base_url/rest/api/2/issue/"

    Write-Host "Enter Customer Story details:"
    $customer_story_title = Read-Host "Customer Story Title?"

    $customer_story_details = @{
        "As a" = ""
        "I want" = ""
        "So that" = ""
    }

    foreach ($key in $customer_story_details.Keys) {
        $customer_story_details[$key] = Read-Host "Enter $key"
    }

    # Initialize an array to store acceptance criteria
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

h3. Customer Story Details

* *As a:* $($customer_story_details["As a"]),

* *I want:* $($customer_story_details["I want"]),

* *So that:* $($customer_story_details["So that"])

h3. Acceptance Criteria

* $($acceptanceCriteria -join "`r`n* ")*

h2. Additional Details

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