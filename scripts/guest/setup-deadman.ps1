param(
    [int]$DelayMinutes = 10
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

$action = New-ScheduledTaskAction `
    -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Admin\scripts\display-rescue.ps1'

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($DelayMinutes)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask `
    -TaskName 'DisplayDeadman' `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Force | Out-Null

Write-Output "DisplayDeadman scheduled to run in $DelayMinutes minutes"
