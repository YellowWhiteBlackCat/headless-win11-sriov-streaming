param(
    [string]$VbDir = 'C:\Admin\VBCABLE',
    [switch]$Reboot
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()
$logDir = 'C:\Admin\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'install-vb-cable.log'

function Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $line
    Add-Content -Path $logFile -Value $line -Encoding utf8
}

Log "Starting VB-CABLE install from $VbDir"

$inf = Join-Path $VbDir 'vbMmeCable64_win10.inf'
$sys = Join-Path $VbDir 'vbaudio_cable64_win10.sys'
$cat = Join-Path $VbDir 'vbaudio_cable64_win10.cat'
foreach ($f in @($inf, $sys, $cat)) {
    if (-not (Test-Path -LiteralPath $f)) {
        throw "Missing file: $f (copy the contents of VBCABLE_Driver_Pack45.zip there)"
    }
}

$devcon = 'C:\Admin\tools\devcon.exe'
if (-not (Test-Path -LiteralPath $devcon)) {
    throw "devcon.exe not found at $devcon (copy it from VDD.Control Dependencies)"
}

# Clean any previous VB-CABLE root device / driver package.
& $devcon remove VBAudioVACWDM 2>&1 | Out-String | Write-Output
$existing = pnputil /enum-drivers | Out-String
if ($existing -match 'vbMmeCable64_win10\.inf') {
    $lines = $existing -split "`r?`n"
    $pub = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'vbMmeCable64_win10\.inf') {
            for ($j = $i - 1; $j -ge 0; $j--) {
                if ($lines[$j] -match 'Published Name:\s*(\S+)') {
                    $pub = $Matches[1]
                    break
                }
            }
            break
        }
    }
    if ($pub) {
        Log "Removing old package $pub"
        pnputil /delete-driver $pub /force /uninstall | Out-String | Write-Output
    }
}

Log 'Adding driver package'
pnputil /add-driver $inf /install 2>&1 | Out-String | Write-Output
Start-Sleep -Seconds 3

Log 'Creating root device VBAudioVACWDM'
& $devcon install $inf 'VBAudioVACWDM' 2>&1 | Out-String | Write-Output
Start-Sleep -Seconds 5

Get-PnpDevice -Class MEDIA -PresentOnly -ErrorAction SilentlyContinue |
    Format-Table Status, FriendlyName, InstanceId -AutoSize |
    Out-String -Width 220 | Write-Output
Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue |
    Format-Table Name, Status -AutoSize |
    Out-String -Width 140 | Write-Output

Log 'VB-CABLE install finished'
if ($Reboot) {
    Write-Output 'Rebooting now...'
    Restart-Computer -Force
}
