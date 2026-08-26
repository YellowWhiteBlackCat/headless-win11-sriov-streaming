param(
    [string]$ToolPath = 'C:\Admin\tools\MultiMonitorTool.exe',
    [switch]$EnumOnly
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

$logDir = 'C:\Admin\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$csv = Join-Path $logDir 'monitors.csv'
$log = Join-Path $logDir 'fix-display-topology.log'

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $log -Value $line -Encoding utf8
    Write-Output $line
}

# Streaming mode coordination: stream-display-mode.ps1 -Mode OnlyVdd writes
# this flag; while it exists, the logon-time topology fix must NOT re-enable
# the VirtIO rescue display (that would break the "VDD is the only display"
# contract and re-trigger the SetDisplayConfig ERROR_GEN_FAILURE issue).
$streamingFlag = 'C:\Admin\state\streaming-mode.flag'
if (Test-Path -LiteralPath $streamingFlag) {
    Write-Log "streaming-mode.flag present; skipping rescue topology enforcement"
    exit 0
}

if (-not (Test-Path -LiteralPath $ToolPath)) {
    throw "MultiMonitorTool.exe not found at $ToolPath (copy it from drivers/MultiMonitorTool/ to C:\Admin\tools\)"
}

function Invoke-Mmt {
    param([string[]]$Arguments)
    $p = Start-Process -FilePath $ToolPath -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) {
        Write-Log "MultiMonitorTool exit code: $($p.ExitCode) (args: $($Arguments -join ' '))"
    }
    return $p.ExitCode
}

Write-Log 'Enumerating monitors'
Invoke-Mmt @('/scomma', "`"$csv`"") | Out-Null
Start-Sleep -Seconds 3
if (-not (Test-Path -LiteralPath $csv)) {
    throw "MultiMonitorTool did not produce $csv"
}
$monitors = Import-Csv -Path $csv
$monitors | Format-Table -AutoSize | Out-String -Width 260 | Write-Output
Write-Log "Enumerated $($monitors.Count) monitors"

if ($EnumOnly) {
    return
}

# Identify the two displays we manage.
$vdd = $monitors | Where-Object {
    $_.'Monitor Name' -match 'VDD|MTT' -or $_.Name -match 'DISPLAY'
} | Where-Object { $_.Adapter -match 'Virtual Display Driver' -or $_.'Monitor Name' -match 'VDD' } | Select-Object -First 1
$qemu = $monitors | Where-Object {
    $_.'Monitor Name' -match 'QEMU|RHT|Red Hat' -or $_.Adapter -match 'VirtIO'
} | Select-Object -First 1

if (-not $vdd) { throw 'Could not find the VDD (MTT) monitor in the monitor list' }
if (-not $qemu) {
    Write-Log 'No QEMU/VirtIO monitor found: VDD-only headless mode, nothing to fix'
    return
}

$vddDevice = $vdd.Name
$qemuDevice = $qemu.Name
Write-Log "VDD device: $vddDevice"
Write-Log "QEMU device: $qemuDevice"

# Deterministic extended topology:
#   - enable both monitors
#   - put VDD to the right of the VirtIO rescue display
#   - keep the VirtIO display primary
Invoke-Mmt @('/enable', $vddDevice, $qemuDevice) | Out-Null
Start-Sleep -Seconds 2
Invoke-Mmt @('/EnableAtPosition', $vddDevice, '1280', '0') | Out-Null
Start-Sleep -Seconds 2
Invoke-Mmt @('/SetPrimary', $qemuDevice) | Out-Null
Start-Sleep -Seconds 2

# Windows 11 24H2 can leave a re-enabled VirtIO DOD adapter present but with
# no active scanout.  Apply both monitor records in one SetDisplayConfig call;
# unlike separate /enable and /SetPrimary calls this also recreates the
# VirtIO output that QEMU VNC needs.  Short monitor IDs remain stable across
# DISPLAY-number renumbering after a PnP transition.
$qemuConfig = 'Name={0} Primary=1 BitsPerPixel=32 Width=1280 Height=800 DisplayFlags=0 DisplayFrequency=60 DisplayOrientation=0 PositionX=0 PositionY=0' -f $qemu.'Short Monitor ID'
$vddConfig = 'Name={0} BitsPerPixel=32 Width=800 Height=600 DisplayFlags=0 DisplayFrequency=30 DisplayOrientation=0 PositionX=1280 PositionY=0' -f $vdd.'Short Monitor ID'
Invoke-Mmt @('/SetMonitors', "`"$qemuConfig`"", "`"$vddConfig`"") | Out-Null
Start-Sleep -Seconds 4

# Save the working topology so future boots can restore it deterministically.
$cfg = Join-Path $logDir 'monitors-topology.cfg'
Invoke-Mmt @('/SaveConfig', "`"$cfg`"") | Out-Null
Write-Log "Saved topology to $cfg"

# Re-enumerate and show the result.
Invoke-Mmt @('/scomma', "`"$csv`"") | Out-Null
Start-Sleep -Seconds 3
$finalMonitors = Import-Csv -Path $csv
$finalMonitors | Format-Table -AutoSize | Out-String -Width 260 | Write-Output
$finalQemu = $finalMonitors | Where-Object { $_.Adapter -match 'VirtIO' } | Select-Object -First 1
if (-not $finalQemu -or $finalQemu.Active -ne 'Yes' -or $finalQemu.Primary -ne 'Yes') {
    Write-Log "WARNING: VirtIO rescue output is still not active/primary (Active=$($finalQemu.Active) Primary=$($finalQemu.Primary))"
} else {
    Write-Log 'Verified VirtIO rescue output is active and primary'
}

Write-Log 'Display topology fix finished'
