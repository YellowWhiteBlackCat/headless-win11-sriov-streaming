$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

$confDir = 'C:\VirtualDisplayDriver'
$settingsFile = Join-Path $confDir 'vdd_settings.xml'
$instanceId = 'ROOT\DISPLAY\0000'

# Make sure the driver uses this exact config directory.
New-Item -Path 'HKLM:\SOFTWARE\MikeTheTech\VirtualDisplayDriver' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\MikeTheTech\VirtualDisplayDriver' `
    -Name 'VDDPATH' -PropertyType String -Value $confDir -Force | Out-Null

# Turn on driver logging (leave debug logging off).
$xml = Get-Content -Raw -Path $settingsFile -Encoding UTF8
$xml = $xml -replace '(?m)<logging>false</logging>', '<logging>true</logging>'
[System.IO.File]::WriteAllText($settingsFile, $xml, (New-Object System.Text.UTF8Encoding($false)))
Write-Output 'Logging enabled in vdd_settings.xml'

Write-Output 'Restarting VDD device'
Disable-PnpDevice -InstanceId $instanceId -Confirm:$false -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
Enable-PnpDevice -InstanceId $instanceId -Confirm:$false -ErrorAction SilentlyContinue
Start-Sleep -Seconds 10

Write-Output 'VDD device state:'
Get-PnpDevice -InstanceId $instanceId -ErrorAction SilentlyContinue |
    Format-Table Status, Class, FriendlyName, InstanceId -AutoSize |
    Out-String -Width 220 | Write-Output

Write-Output 'VDD logs:'
Get-ChildItem (Join-Path $confDir 'Logs') -Recurse -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 10 FullName, Length, LastWriteTime |
    Format-Table -AutoSize |
    Out-String -Width 220 | Write-Output

foreach ($log in (Get-ChildItem (Join-Path $confDir 'Logs') -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3)) {
    Write-Output "===== $($log.FullName) ====="
    Get-Content -Path $log.FullName -Tail 120 -Encoding UTF8 | Write-Output
}
