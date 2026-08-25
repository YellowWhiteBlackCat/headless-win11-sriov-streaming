$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

$logDir = 'C:\Admin\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'set-display-extend.log'

function Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $logFile -Value $line -Encoding utf8
    Write-Output $line
}

Log 'Waiting 12s for display devices to settle'
Start-Sleep -Seconds 12

Log 'Switching to internal (VirtIO) display'
& "$env:SystemRoot\System32\DisplaySwitch.exe" /internal 2>&1 | Out-String | Write-Output
Start-Sleep -Seconds 4

Log 'Switching to extended display mode'
& "$env:SystemRoot\System32\DisplaySwitch.exe" /extended 2>&1 | Out-String | Write-Output
Start-Sleep -Seconds 6

Get-CimInstance Win32_VideoController |
    Select-Object Name, Status, CurrentHorizontalResolution, CurrentVerticalResolution |
    Format-Table -AutoSize |
    Out-String -Width 200 | Write-Output

Log 'Display topology change attempted'
