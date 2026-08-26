param(
    [string]$LogDir = 'C:\Admin\logs',
    [string]$MultiMonitorTool = 'C:\Admin\tools\MultiMonitorTool.exe',
    [string]$DxgiInfo = 'C:\Program Files\Sunshine\tools\dxgi-info.exe'
)

# Capture the display state that matters after an Intel driver upgrade:
# PnP device status/location, active monitors, DXGI outputs, and Sunshine logs.
$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

Write-Output '--- PNP DISPLAY DEVICES ---'
Get-PnpDevice -Class Display | ForEach-Object {
    $loc = (Get-PnpDeviceProperty -InstanceId $_.InstanceId `
            -KeyName 'DEVPKEY_Device_LocationInfo' -ErrorAction SilentlyContinue).Data
    '{0} | status={1} problem={2} | loc={3}' -f $_.InstanceId, $_.Status, $_.Problem, $loc
}

Write-Output '--- MULTIMONITORTOOL ---'
$mmtCsv = Join-Path $LogDir 'display-state.csv'
if (Test-Path -LiteralPath $MultiMonitorTool) {
    & $MultiMonitorTool /display /scomma $mmtCsv | Out-Null
    if (Test-Path -LiteralPath $mmtCsv) {
        Get-Content -LiteralPath $mmtCsv
    } else {
        Write-Output 'MultiMonitorTool did not produce output'
    }
} else {
    Write-Output "MultiMonitorTool not found: $MultiMonitorTool"
}

Write-Output '--- DXGI OUTPUTS ---'
if (Test-Path -LiteralPath $DxgiInfo) {
    & $DxgiInfo
} else {
    Write-Output "dxgi-info not found: $DxgiInfo"
}

Write-Output '--- SUNSHINE LOG TAIL ---'
$sunshineLog = 'C:\ProgramData\Sunshine\sunshine.log'
if (Test-Path -LiteralPath $sunshineLog) {
    Get-Content -LiteralPath $sunshineLog -Tail 120
} else {
    Write-Output "no Sunshine log at $sunshineLog"
}

Write-Output '--- END ---'
