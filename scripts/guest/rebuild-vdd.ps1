param(
    [string]$DevCon = 'C:\Admin\VDD\devcon.exe',
    [string]$VddInf = 'C:\Admin\VDD\MttVDD.inf',
    [string]$SettingsFile = 'C:\VirtualDisplayDriver\vdd_settings.xml',
    [string]$LogDir = 'C:\Admin\logs',
    [switch]$NoSunshine
)

# Deterministic VDD rebuild. An Intel driver upgrade can leave one or more
# ROOT\DISPLAY\* nodes present but without a working IddCx output. pnputil
# removal is more reliable than devcon remove for disabled/error nodes, so
# remove every VDD instance, recreate exactly one, and only then start
# Sunshine again.
$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$logFile = Join-Path $LogDir 'rebuild-vdd.log'

function Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $line
    Add-Content -Path $logFile -Value $line -Encoding utf8
}

function Get-VddDevices {
    Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'ROOT\DISPLAY\*' }
}

Log 'Stopping Sunshine before VDD rebuild'
Stop-ScheduledTask -TaskName SunshineUser -ErrorAction SilentlyContinue
Get-Process -Name sunshine -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Service -Name SunshineService -ErrorAction SilentlyContinue | Stop-Service -Force
Start-Sleep -Seconds 2

$pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
$removed = @()
foreach ($vdd in Get-VddDevices) {
    Log "Removing VDD node $($vdd.InstanceId) (status=$($vdd.Status))"
    & $pnputil /remove-device $vdd.InstanceId 2>&1 | ForEach-Object { Log "  $_" }
    $removed += $vdd.InstanceId
    Start-Sleep -Seconds 2
}

$left = Get-VddDevices
if ($left) {
    throw "VDD nodes still present after removal: $($left.InstanceId -join ', ')"
}
Log "All VDD nodes removed: $($removed -join ', ')"

if (-not (Test-Path -LiteralPath $DevCon)) { throw "devcon not found: $DevCon" }
if (-not (Test-Path -LiteralPath $VddInf)) { throw "VDD INF not found: $VddInf" }

Log "Creating a single VDD node from $VddInf"
& $DevCon install $VddInf Root\MttVDD 2>&1 | ForEach-Object { Log "  $_" }
Start-Sleep -Seconds 8

$vddList = @(Get-VddDevices)
if ($vddList.Count -ne 1) {
    throw "Expected exactly one VDD node, found $($vddList.Count): $($vddList.InstanceId -join ', ')"
}
$vdd = $vddList[0]
if ($vdd.Status -ne 'OK') {
    Log "WARNING: VDD node $($vdd.InstanceId) status is $($vdd.Status); trying Enable-PnpDevice"
    Enable-PnpDevice -InstanceId $vdd.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    $vdd = Get-PnpDevice -InstanceId $vdd.InstanceId -ErrorAction SilentlyContinue
}
if (-not $vdd -or $vdd.Status -ne 'OK') {
    throw "VDD node is not OK after rebuild (status=$(if ($vdd) { $vdd.Status } else { 'missing' }))"
}
Log "VDD OK: $($vdd.InstanceId) ($($vdd.FriendlyName))"

$mmt = 'C:\Admin\tools\MultiMonitorTool.exe'
if (Test-Path -LiteralPath $mmt) {
    Start-Sleep -Seconds 5
    $csv = Join-Path $LogDir 'rebuild-vdd-monitors.csv'
    & $mmt /display /scomma $csv | Out-Null
    Start-Sleep -Seconds 2
    if (Test-Path -LiteralPath $csv) {
        $monitors = Import-Csv -Path $csv
        $active = $monitors | Where-Object { $_.Active -eq 'Yes' }
        Log "Active monitors after rebuild: $($active.Count)"
        if ($active.Count -eq 0) {
            Log 'WARNING: no active monitor after rebuild; the display stack may need a reboot'
        } else {
            $active | ForEach-Object { Log "  monitor: $($_.Name) $($_.Resolution) primary=$($_.Primary)" }
        }
    }
}

if (-not $NoSunshine) {
    # Sunshine must run inside the interactive console session (it queries
    # display paths/modes through the session's display stack). Launching the
    # .exe from an SSH/service context yields ERROR_ACCESS_DENIED and no
    # outputs. The SunshineUser task is configured Interactive-only and runs
    # as vmadmin, so it is the correct launcher even when this script is
    # invoked over SSH.
    $task = Get-ScheduledTask -TaskName SunshineUser -ErrorAction SilentlyContinue
    if ($task) {
        Log 'Starting Sunshine via SunshineUser scheduled task (interactive session)'
        Start-ScheduledTask -TaskName SunshineUser
    } else {
        Log 'WARNING: SunshineUser task not found; Sunshine was not started'
    }
}

Log 'VDD rebuild finished'
