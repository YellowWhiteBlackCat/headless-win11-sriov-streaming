param(
    [ValidateSet('OnlyVdd', 'RestoreBoth')]
    [string]$Mode
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

$mmt = 'C:\Admin\tools\MultiMonitorTool.exe'
$rescueMonitor = 'RHT1234'   # VirtIO rescue display (Short Monitor ID)
$vddMonitor = 'MTT1337'      # Virtual Display Driver (Short Monitor ID)
$virtioInstance = 'PCI\VEN_1AF4&DEV_1050&SUBSYS_11001AF4&REV_01\3&11583659&0&08'
$logDir = 'C:\Admin\logs'
$stateDir = 'C:\Admin\state'
$streamingFlag = Join-Path $stateDir 'streaming-mode.flag'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'stream-display-mode.log'

function Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $line
    Add-Content -Path $logFile -Value $line -Encoding utf8
}

function Invoke-Mmt {
    param([string[]]$Arguments)
    $stdoutFile = Join-Path $logDir 'mm-stdout.txt'
    $stderrFile = Join-Path $logDir 'mm-stderr.txt'
    Remove-Item -Path $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath $mmt `
        -ArgumentList $Arguments `
        -WindowStyle Hidden `
        -Wait -PassThru `
        -RedirectStandardOutput $stdoutFile `
        -RedirectStandardError $stderrFile
    foreach ($file in @($stdoutFile, $stderrFile)) {
        if (Test-Path -LiteralPath $file) {
            Get-Content -LiteralPath $file | ForEach-Object { Log "MMT: $_" }
        }
    }
    Log "MMT exit=$($proc.ExitCode) args=$($Arguments -join ' ')"
    if ($proc.ExitCode -ne 0) {
        throw "MultiMonitorTool failed: $($Arguments -join ' ')"
    }
    Start-Sleep -Seconds 2
}

function Save-Snapshot {
    param([string]$Name)
    $file = Join-Path $logDir "mm-$Name.txt"
    & $mmt /stext $file 2>$null
    Start-Sleep -Milliseconds 500
    if (Test-Path $file) {
        Log "Snapshot $Name written: $file"
    }
}

function Get-MonitorText {
    param([string]$Name)
    $file = Join-Path $logDir "mm-$Name.txt"
    & $mmt /stext $file 2>$null
    Start-Sleep -Milliseconds 500
    if (Test-Path $file) { return Get-Content -LiteralPath $file -Raw }
    return ''
}

if (-not (Test-Path -LiteralPath $mmt)) {
    throw "MultiMonitorTool not found: $mmt"
}

Log "=== stream-display-mode: $Mode ==="

switch ($Mode) {
    'OnlyVdd' {
        # Sunshine must not run across the display-stack teardown.
        Get-Process Sunshine -ErrorAction SilentlyContinue | Stop-Process -Force
        Log 'Sunshine stopped before display switch'

        # 1. Disable the VirtIO GPU at PnP level. This also makes the VDD the
        #    primary display and un-breaks SetDisplayConfig (while the VirtIO
        #    GPU is active, the display API returns ERROR_GEN_FAILURE here).
        Disable-PnpDevice -InstanceId $virtioInstance -Confirm:$false -ErrorAction Stop
        Log "VirtIO GPU disabled (PnP): $virtioInstance"
        Start-Sleep -Seconds 4

        # 2. Disable every other ACTIVE monitor path (normally only the
        #    "Microsoft Basic Display Driver" fallback of the VirtIO VGA).
        $text = Get-MonitorText 'scan'
        $blocks = $text -split '(?m)^={10,}\s*$'
        foreach ($block in $blocks) {
            if ($block -match 'Active\s*:\s*Yes' -and $block -notmatch 'Virtual Display Driver') {
                if ($block -match 'Name\s*:\s*(\\\\.\\DISPLAY\d+)') {
                    $name = $Matches[1]
                    Log "Disabling extra active monitor: $name"
                    Invoke-Mmt @('/disable', $name)
                }
            }
        }

        # 3. 200% desktop scaling on the VDD.
        Invoke-Mmt @('/SetScale', $vddMonitor, '200')
        # 4. Remember streaming mode so the logon-time topology watchdog
        #    (fix-display-topology.ps1) does not re-enable the VirtIO GPU.
        New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
        Set-Content -LiteralPath $streamingFlag -Value 'OnlyVdd' -Encoding ascii
        Log "Streaming-mode flag written: $streamingFlag"
        Save-Snapshot 'during'

        # 5. Bring Sunshine back up in the VDD-only state.
        Start-ScheduledTask -TaskName 'SunshineUser' -ErrorAction SilentlyContinue
        Log 'SunshineUser task started after display switch'
    }
    'RestoreBoth' {
        # Clear the streaming-mode flag first so the topology watchdog can
        # take over rescue mode even if enabling VirtIO below fails.
        Remove-Item -LiteralPath $streamingFlag -ErrorAction SilentlyContinue
        Log "Streaming-mode flag cleared: $streamingFlag"

        Get-Process Sunshine -ErrorAction SilentlyContinue | Stop-Process -Force
        Log 'Sunshine stopped before display switch'

        # 1. Re-enable the VirtIO GPU; Windows brings the rescue display back
        #    and makes it primary again automatically.
        Enable-PnpDevice -InstanceId $virtioInstance -Confirm:$false -ErrorAction Stop
        Log "VirtIO GPU enabled (PnP): $virtioInstance"
        Start-Sleep -Seconds 5

        # 2. Restore 100% scaling on the rescue display.
        Invoke-Mmt @('/SetScale', $rescueMonitor, '100')
        Save-Snapshot 'after'

        # 3. Bring Sunshine back up in rescue mode.
        Start-ScheduledTask -TaskName 'SunshineUser' -ErrorAction SilentlyContinue
        Log 'SunshineUser task started after display switch'
    }
}

Log "=== stream-display-mode: $Mode done ==="
