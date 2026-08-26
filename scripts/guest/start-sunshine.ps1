param(
    [string]$UserName = 'vmadmin',
    [string]$SunshineDir = 'C:\Program Files\Sunshine',
    [int]$ReadyTimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

$logDir = 'C:\Admin\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir 'sunshine-start.log'

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $log -Value $line -Encoding utf8
    Write-Output $line
}

function Invoke-TopologyFixWithTimeout {
    param(
        [string]$Path,
        [int]$TimeoutSeconds = 30
    )

    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    try {
        $child = Start-Process -FilePath $powershell `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Path) `
            -WorkingDirectory 'C:\Admin\scripts' `
            -WindowStyle Hidden `
            -PassThru
        if ($child.WaitForExit($TimeoutSeconds * 1000)) {
            if ($child.ExitCode -eq 0) {
                Write-Log 'Display topology fix completed'
            } else {
                Write-Log "Display topology fix exited with code $($child.ExitCode); continuing"
            }
        } else {
            & "$env:SystemRoot\System32\taskkill.exe" /PID $child.Id /T /F 2>$null | Out-Null
            Write-Log "Display topology fix timed out after ${TimeoutSeconds}s; terminated its process tree"
        }
    } catch {
        Write-Log "Display topology fix failed (continuing): $($_.Exception.Message)"
    }
}

$exe = Join-Path $SunshineDir 'Sunshine.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    throw "Sunshine executable not found: $exe"
}

$shaderDir = Join-Path $SunshineDir 'assets\shaders\directx'
if (-not (Test-Path -LiteralPath $shaderDir)) {
    throw "Sunshine shader directory not found: $shaderDir"
}

Write-Log "Starting Sunshine boot sequence (PID watcher, cwd=$SunshineDir)"

# --- Ordered prerequisites -------------------------------------------------
# 1. VDD root display device must be present and working. After an Intel
#    driver upgrade it can be left disabled (CM_PROB_DISABLED); recreate it
#    with devcon if it never appears.
$vddReady = $false
$deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    $vdd = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'ROOT\DISPLAY\*' } |
        Select-Object -First 1
    if ($vdd -and $vdd.Status -eq 'OK') {
        $vddReady = $true
        Write-Log "VDD ready: $($vdd.InstanceId) ($($vdd.FriendlyName))"
        break
    }
    Start-Sleep -Seconds 3
}
if (-not $vddReady) {
    Write-Log "VDD not ready within ${ReadyTimeoutSeconds}s. Last state: $($vdd.InstanceId) / $($vdd.Status)"
    Write-Log 'Recovery hint: devcon.exe install C:\Admin\VDD\install\driver\mttvdd.inf Root\MttVDD'
    exit 1
}

# 2. Intel Arc VF must be visible to Windows. Without it QSV has no encoder
#    and Sunshine cannot do hardware capture on the right adapter.
$arcReady = $false
$deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    $arc = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match 'PCI\\VEN_8086' -or $_.FriendlyName -match 'Arc' } |
        Where-Object { $_.Status -eq 'OK' } |
        Select-Object -First 1
    if ($arc) {
        $arcReady = $true
        Write-Log "Arc VF ready: $($arc.FriendlyName) ($($arc.InstanceId))"
        break
    }
    Start-Sleep -Seconds 3
}
if (-not $arcReady) {
    Write-Log "Intel Arc VF not ready within ${ReadyTimeoutSeconds}s"
    exit 1
}

# 3. A reboot or a stale display-mode test must never leave the rescue display
#    disabled. The no-client baseline is always VirtIO + VDD; the streaming
#    prep command temporarily disables VirtIO only after a client connects.
$virtio = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -like 'PCI\VEN_1AF4*' } |
    Select-Object -First 1
if (-not $virtio) {
    Write-Log 'VirtIO GPU not found; refusing to start Sunshine without the rescue display'
    exit 1
}
if ($virtio.Status -ne 'OK') {
    try {
        Enable-PnpDevice -InstanceId $virtio.InstanceId -Confirm:$false -ErrorAction Stop | Out-Null
        Write-Log "VirtIO GPU re-enabled for no-client rescue mode: $($virtio.InstanceId)"
        Start-Sleep -Seconds 5
        $virtio = Get-PnpDevice -InstanceId $virtio.InstanceId -ErrorAction SilentlyContinue
    } catch {
        Write-Log "Could not re-enable VirtIO rescue GPU: $($_.Exception.Message)"
        exit 1
    }
}
if (-not $virtio -or $virtio.Status -ne 'OK') {
    Write-Log 'VirtIO rescue GPU is not working after the restore attempt'
    exit 1
}

$fixScript = 'C:\Admin\scripts\fix-display-topology.ps1'
if (Test-Path -LiteralPath $fixScript) {
    Invoke-TopologyFixWithTimeout -Path $fixScript -TimeoutSeconds 30
} else {
    Write-Log "fix-display-topology.ps1 missing: $fixScript"
}

# 4. Remove stale instances before starting.
Get-Service SunshineService -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -eq 'Running' } |
    Stop-Service -Force -ErrorAction SilentlyContinue
Get-Process Sunshine -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

# 5. Start Sunshine with the correct working directory. The shader compiler
#    resolves assets/shaders/directx/*.hlsl relative to the cwd; a wrong cwd
#    used to make every shader compile fail (0x80070003) and Sunshine crash.
$proc = Start-Process -FilePath $exe -WorkingDirectory $SunshineDir -PassThru
Write-Log "Sunshine started PID=$($proc.Id)"

Start-Sleep -Seconds 5
$alive = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
if (-not $alive) {
    Write-Log 'Sunshine exited within 15s; last log lines:'
    $sunshineLog = Join-Path $SunshineDir 'config\sunshine.log'
    if (Test-Path -LiteralPath $sunshineLog) {
        Get-Content -LiteralPath $sunshineLog -Tail 40 | ForEach-Object { Write-Log "  $_" }
    }
    exit 1
}

$requiredPorts = @(47989, 47984)
$deadline = (Get-Date).AddSeconds(30)
$listeners = @()
while ((Get-Date) -lt $deadline) {
    try {
        $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop |
            Where-Object { $requiredPorts -contains [int]$_.LocalPort })
    } catch {
        Write-Log "Could not inspect Sunshine listeners: $($_.Exception.Message)"
        exit 1
    }
    $readyPorts = @($listeners | Select-Object -ExpandProperty LocalPort -Unique)
    if (@($requiredPorts | Where-Object { $readyPorts -contains $_ }).Count -eq $requiredPorts.Count) {
        break
    }
    Start-Sleep -Seconds 1
}
$readyPorts = @($listeners | Select-Object -ExpandProperty LocalPort -Unique)
$missingPorts = @($requiredPorts | Where-Object { $readyPorts -notcontains $_ })
if ($missingPorts.Count -gt 0) {
    Write-Log "Sunshine process is alive but listeners are missing: $($missingPorts -join ',')"
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    exit 1
}

Write-Log "Sunshine is running (PID=$($proc.Id)); listeners=$($requiredPorts -join ',')"
