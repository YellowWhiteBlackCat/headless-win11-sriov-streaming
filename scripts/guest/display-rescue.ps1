$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

$logDir = 'C:\Admin\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'display-rescue.log'

function Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $logFile -Value $line -Encoding utf8
}

Log 'Display rescue invoked'

$targets = Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object {
        $_.InstanceId -like 'ROOT\DISPLAY*' -or
        $_.FriendlyName -match 'Virtual Display Driver|VDD'
    }

if (-not $targets) {
    Log 'No VDD display device found; nothing to disable'
    exit 0
}

foreach ($device in $targets) {
    Log ("Disabling {0} [{1}]" -f $device.FriendlyName, $device.InstanceId)
    try {
        Disable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false -ErrorAction Stop | Out-Null
    } catch {
        Log ("Disable failed: {0}" -f $_.Exception.Message)
    }
}

Start-Sleep -Seconds 2
Log 'Rebooting system now'
& "$env:SystemRoot\System32\shutdown.exe" /r /t 0 /f
