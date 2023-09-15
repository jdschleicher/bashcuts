



Set-Alias -Name nfp -Value c:\windows\notepad.exe

function reinit {
    Invoke-Command { & "pwsh.exe" } -NoNewScope 
}

function new-list($new_list_variable) {
    Set-Variable -Name "$new_list_variable" -Value ([system.collections.generic.list[string]]::new()) -Scope global
}

function robot-debug() {
    $env:ROBOT_DEBUG = "TRUE"; robot --rpa -d output .
}

function last-command() {
    $id_of_last_command = $(Get-History -Count 1).Id
    $result_of_last_command = Invoke-History $id_of_last_command
    $result_of_last_command
}

function decode-base64() {
    param($base_encoded_64)

    $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($base_encoded_64))  
    $decoded

}

function encode-base64() {
    param($to_encode)

    $bytes = [System.Text.Encoding]::Unicode.GetBytes("$to_encode")
    $encoded =[Convert]::ToBase64String($bytes)
    
    $encoded
}

function encode-base64-utf8() {
    param($to_encode)

    $enc = [System.Text.Encoding]::UTF8
    $enc_utf8_org = $enc.GetBytes($to_encode)
    $base64_utf8_encoded =[Convert]::ToBase64String($enc_utf8_org)

    $base64_utf8_encoded

}

function kill-by-port() {
    param ($port)
    # https://dzhavat.github.io/2020/04/09/powershell-script-to-kill-a-process-on-windows.html

    $foundProcesses = netstat -ano | findstr :$port
    $activePortPattern = ":$port\s.+LISTENING\s+\d+$"
    $pidNumberPattern = "\d+$"

    IF ($foundProcesses | Select-String -Pattern $activePortPattern -Quiet) {
        $matches = $foundProcesses | Select-String -Pattern $activePortPattern
        $firstMatch = $matches.Matches.Get(0).Value

        $pidNumber = [regex]::match($firstMatch, $pidNumberPattern).Value

        taskkill /pid $pidNumber /f
    }
}

function pow_remove_property_from_field {
    param( 
        [Parameter(Mandatory=$true)]
        $property,
        [Parameter(Mandatory=$true)]
        $object
    )

    $object.PSObject.properties.remove("$property")

    $object

}
