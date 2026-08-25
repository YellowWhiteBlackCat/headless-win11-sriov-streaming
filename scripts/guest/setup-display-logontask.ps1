param(
    [string]$UserName = 'vmadmin'
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

# Prefer the deterministic MultiMonitorTool fix (keeps VirtIO + VDD active
# without DisplaySwitch races). Fall back to the legacy DisplaySwitch script
# when the tool has not been copied to C:\Admin\tools yet.
$fixScript = 'C:\Admin\scripts\fix-display-topology.ps1'
$fallbackScript = 'C:\Admin\scripts\set-display-extend.ps1'
$mmt = 'C:\Admin\tools\MultiMonitorTool.exe'
if ((Test-Path -LiteralPath $fixScript) -and (Test-Path -LiteralPath $mmt)) {
    $scriptToRun = $fixScript
} elseif (Test-Path -LiteralPath $fallbackScript) {
    $scriptToRun = $fallbackScript
} else {
    throw 'Neither fix-display-topology.ps1 nor set-display-extend.ps1 is available'
}

$action = New-ScheduledTaskAction `
    -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $scriptToRun"

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserName
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
$principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Interactive -RunLevel Highest

Register-ScheduledTask `
    -TaskName 'FixDisplayTopology' `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Force | Out-Null

Write-Output "FixDisplayTopology registered for $UserName at logon -> $scriptToRun"
