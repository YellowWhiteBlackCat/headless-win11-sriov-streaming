param(
    [string]$DriverExe = 'C:\Admin\drivers\IntelArcDriver\gfx_win_101.8991.exe',
    [switch]$NoReboot,
    [switch]$PostReboot,
    [int]$InstallTimeoutSeconds = 1800
)

# Upgrade the Intel Arc graphics driver in the guest, following the VDD
# project's own guidance: disable the virtual display first, install, reboot,
# then recreate/re-enable VDD and bring Sunshine back.
#
# Usage (on the guest, as an administrator):
#   powershell -ExecutionPolicy Bypass -File upgrade-intel-driver.ps1
#   powershell -ExecutionPolicy Bypass -File upgrade-intel-driver.ps1 -NoReboot

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

$logDir = 'C:\Admin\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'upgrade-intel-driver.log'

function Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $line
    Add-Content -Path $logFile -Value $line -Encoding utf8
}

$vddInstance = 'ROOT\DISPLAY\0000'
$devcon = 'C:\Admin\VDD\devcon.exe'
$vddInf = 'C:\Admin\VDD\MttVDD.inf'
$self = 'C:\Admin\scripts\upgrade-intel-driver.ps1'

function Get-GpuDriverVersion {
    $vc = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -like '*Arc*' } | Select-Object -First 1
    if ($vc) { return $vc.DriverVersion }
    return '<none>'
}

function Repair-VddDevice {
    # After an Intel driver upgrade Windows can leave the VDD root device
    # disabled (CM_PROB_DISABLED) or drop it entirely; enable-device alone
    # is not enough. Recreating the root device with devcon is deterministic.
    $vdd = Get-PnpDevice -InstanceId $vddInstance -ErrorAction SilentlyContinue
    if (-not $vdd) {
        Log 'VDD device missing; recreating with devcon'
        & $devcon install $vddInf Root\MttVDD 2>&1 | ForEach-Object { Log "  $_" }
        Start-Sleep -Seconds 5
        $vdd = Get-PnpDevice -InstanceId $vddInstance -ErrorAction SilentlyContinue
    }
    if ($vdd -and $vdd.Status -eq 'Error') {
        Log 'VDD device present but in error state; removing and recreating'
        & $devcon remove $vddInstance 2>&1 | ForEach-Object { Log "  $_" }
        Start-Sleep -Seconds 3
        & $devcon install $vddInf Root\MttVDD 2>&1 | ForEach-Object { Log "  $_" }
        Start-Sleep -Seconds 5
        $vdd = Get-PnpDevice -InstanceId $vddInstance -ErrorAction SilentlyContinue
    }
    if ($vdd -and $vdd.Status -ne 'OK') {
        Log "Enabling VDD device (current status: $($vdd.Status))"
        Enable-PnpDevice -InstanceId $vddInstance -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
    }
    $vdd = Get-PnpDevice -InstanceId $vddInstance -ErrorAction SilentlyContinue
    if (-not $vdd -or $vdd.Status -ne 'OK') {
        Log "ERROR: VDD is still not OK (status: $(if ($vdd) { $vdd.Status } else { 'missing' }))"
        return $false
    }
    Log "VDD OK: $($vdd.FriendlyName)"
    return $true
}

if (-not $PostReboot) {
    if (-not (Test-Path -LiteralPath $DriverExe)) {
        throw "Driver package not found: $DriverExe"
    }

    Log "Current Intel driver version: $(Get-GpuDriverVersion)"

    # Stop Sunshine first so it cannot hold the display/encoder open.
    Stop-ScheduledTask -TaskName SunshineUser -ErrorAction SilentlyContinue
    Get-Process -Name sunshine -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Service -Name SunshineService -ErrorAction SilentlyContinue | Stop-Service -Force
    Log 'Stopped Sunshine (task, process + service)'

    # Disable the VDD display device before the driver re-enumerates adapters.
    $vdd = Get-PnpDevice -InstanceId $vddInstance -ErrorAction SilentlyContinue
    if ($vdd -and $vdd.Status -ne 'Error') {
        Disable-PnpDevice -InstanceId $vddInstance -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        Log 'Disabled VDD device'
    } else {
        Log 'VDD device not present or already disabled'
    }

    Log "Installing $DriverExe silently (-s)"
    $proc = Start-Process -FilePath $DriverExe -ArgumentList '-s' -PassThru -Wait
    Log "Installer exit code: $($proc.ExitCode)"

    if (-not $NoReboot) {
        # Continue automatically after reboot: recreate VDD, fix topology, start Sunshine.
        $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -PostReboot"
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' `
            -Name 'UpgradeIntelDriverPostReboot' -Value $cmd
        Log 'Registered post-reboot continuation in RunOnce'
        Log 'Rebooting the guest to activate the new driver'
        & shutdown.exe /r /t 5 /f
        exit 0
    }

    Log "Driver version after install (pre-reboot): $(Get-GpuDriverVersion)"
    Write-Output "Reboot the guest, then run: $self -PostReboot"
    exit 0
}

# --- Post-reboot phase -----------------------------------------------------
Log "Post-reboot phase; driver version: $(Get-GpuDriverVersion)"

if (Repair-VddDevice) {
    $topology = 'C:\Admin\scripts\fix-display-topology.ps1'
    if (Test-Path -LiteralPath $topology) {
        Log 'Fixing display topology'
        & $topology | Out-Null
    }
    Log 'Starting Sunshine user task'
    Start-ScheduledTask -TaskName SunshineUser
} else {
    Log 'ERROR: VDD repair failed; Sunshine was not started. Check C:\Admin\logs\upgrade-intel-driver.log'
}

Log 'Post-reboot upgrade phase finished'
