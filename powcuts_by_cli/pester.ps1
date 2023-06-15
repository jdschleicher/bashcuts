

function t-run-file {
    $test_file_path = Read-Host -Prompt 'Input the powershell full file path to be tested'
    Invoke-Pester -Output Detailed $test_file_path
}

function t-run-method {
    $test_file_path = Read-Host -Prompt 'Input the powershell full file path to be tested'
    $test_method = Read-Host -Prompt 'Input the method tested'
    Write-Host "Invoke-Pester $($test_file_path) '$test_method'"
    Invoke-Pester $test_file_path "$test_method"
}

