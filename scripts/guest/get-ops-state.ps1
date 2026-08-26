param(
    [string]$LogDir = 'C:\Admin\logs'
)

# One-shot operational state used by scripts/host/upgrade-intel-driver.sh:
# driver version, VDD node list, Arc status, Sunshine process/task state, and
# the tails of the Sunshine and upgrade logs. Output is plain "KEY=VALUE"
# lines plus log tails, so the host orchestrator can parse it without
# PowerShell quoting gymnastics.
$ErrorActionPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

$vc = Get-CimInstance Win32_VideoController |
    Where-Object { $_.Name -like '*Arc*' } |
    Select-Object -First 1
Write-Output "DRIVER=$(if ($vc) { $vc.DriverVersion } else { '<none>' })"

$vdds = @(Get-PnpDevice -Class Display | Where-Object { $_.InstanceId -like 'ROOT\DISPLAY\*' })
Write-Output "VDD_COUNT=$($vdds.Count)"
foreach ($v in $vdds) {
    Write-Output "VDD $($v.InstanceId) status=$($v.Status)"
}

$arc = Get-PnpDevice -Class Display |
    Where-Object { $_.InstanceId -like 'PCI\VEN_8086*' } |
    Select-Object -First 1
Write-Output "ARC_STATUS=$(if ($arc) { $arc.Status } else { 'missing' })"

$proc = Get-Process -Name sunshine -ErrorAction SilentlyContinue | Select-Object -First 1
if ($proc) {
    Write-Output "SUNSHINE_PID=$($proc.Id) START=$($proc.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
} else {
    Write-Output 'SUNSHINE_PID=none'
}

$task = Get-ScheduledTaskInfo -TaskName SunshineUser -ErrorAction SilentlyContinue
if ($task) {
    Write-Output "TASK_LAST_RESULT=$($task.LastTaskResult) TASK_LAST_RUN=$($task.LastRunTime)"
} else {
    Write-Output 'TASK_LAST_RESULT=none'
}

$sunshineLog = 'C:\Program Files\Sunshine\config\sunshine.log'
if (Test-Path -LiteralPath $sunshineLog) {
    $item = Get-Item -LiteralPath $sunshineLog
    Write-Output "SUNSHINE_LOG_MT=$($item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Output '---SUNSHINE-TAIL---'
    Get-Content -LiteralPath $sunshineLog -Tail 30
} else {
    Write-Output 'SUNSHINE_LOG=none'
}

$upgradeLog = Join-Path $LogDir 'upgrade-intel-driver.log'
if (Test-Path -LiteralPath $upgradeLog) {
    Write-Output '---UPGRADE-TAIL---'
    Get-Content -LiteralPath $upgradeLog -Tail 25
} else {
    Write-Output 'UPGRADE_LOG=none'
}

Write-Output '---END---'
