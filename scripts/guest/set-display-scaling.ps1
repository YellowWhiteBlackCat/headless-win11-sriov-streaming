param(
    [int]$ScalingPercent = 200,
    [switch]$Reboot
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

$logDir = 'C:\Admin\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'display-scaling.log'

function Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $line
    Add-Content -Path $logFile -Value $line -Encoding utf8
}

if ($ScalingPercent -lt 100 -or $ScalingPercent -gt 500 -or $ScalingPercent % 25 -ne 0) {
    throw "ScalingPercent must be a multiple of 25 between 100 and 500"
}

$logPixels = [int](96 * $ScalingPercent / 100)
$dpiValue  = [int]((($ScalingPercent - 100) / 25) * 0x1E)

Log "Setting desktop scaling to $ScalingPercent% (LogPixels=$logPixels, DpiValue=0x$($dpiValue.ToString('X')))"

# System-wide legacy DPI setting (all monitors). Applied at next sign-in/reboot.
Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'LogPixels' -Value $logPixels -Type DWord
Log "HKCU\Control Panel\Desktop\LogPixels = $logPixels"

# Per-monitor DPI settings: Windows 10/11 keeps per-display overrides here.
# DpiValue: 0x00=100%, 0x1E=125%, 0x3C=150%, 0x5A=175%, 0x78=200%, 0xFFFFFFFF=default.
$perMonitorRoot = 'HKCU:\Control Panel\Desktop\PerMonitorSettings'
if (-not (Test-Path $perMonitorRoot)) {
    New-Item -Path $perMonitorRoot -Force | Out-Null
}
$monitorKeys = @(Get-ChildItem $perMonitorRoot -ErrorAction SilentlyContinue)
if ($monitorKeys.Count -eq 0) {
    Log 'No PerMonitorSettings keys yet; Windows will create them at next sign-in. LogPixels remains the active mechanism.'
} else {
    foreach ($key in $monitorKeys) {
        Set-ItemProperty -Path $key.PSPath -Name 'DpiValue' -Value $dpiValue -Type DWord
        Log "$($key.PSChildName): DpiValue=0x$($dpiValue.ToString('X'))"
    }
}

Log 'Scaling registry updated. Reboot or sign out/in for it to take effect.'
if ($Reboot) {
    Log 'Rebooting now...'
    Restart-Computer -Force
}
