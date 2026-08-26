param(
    [string]$UserName = 'vmadmin',
    [string]$SunshineDir = 'C:\Program Files\Sunshine',
    [switch]$DirectExe
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

$exe = Join-Path $SunshineDir 'Sunshine.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    throw "Sunshine executable not found: $exe"
}

# Sunshine resolves assets/shaders/directx/*.hlsl relative to its working
# directory. Without a WorkingDirectory, Task Scheduler defaults to
# C:\Windows\System32 and every shader compile fails with 0x80070003, then
# Sunshine crashes on the null shader blob during display init. Fail loudly
# here so this cannot silently regress.
$shaderDir = Join-Path $SunshineDir 'assets\shaders\directx'
if (-not (Test-Path -LiteralPath $shaderDir)) {
    throw "Sunshine shader directory not found: $shaderDir"
}
$requiredShader = Join-Path $shaderDir 'cursor_vs.hlsl'
if (-not (Test-Path -LiteralPath $requiredShader)) {
    throw "Required shader missing: $requiredShader"
}

if ($DirectExe) {
    $action = New-ScheduledTaskAction `
        -Execute $exe `
        -WorkingDirectory $SunshineDir
} else {
    # The wrapper waits for VDD + Arc VF, enforces the rescue topology and
    # then starts Sunshine with the correct working directory. This makes
    # boot ordering deterministic instead of relying on task-scheduler order.
    $wrapper = 'C:\Admin\scripts\start-sunshine.ps1'
    if (-not (Test-Path -LiteralPath $wrapper)) {
        throw "Start wrapper not found: $wrapper"
    }
    $action = New-ScheduledTaskAction `
        -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $wrapper" `
        -WorkingDirectory 'C:\Admin\scripts'
}

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserName
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries
$principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Interactive -RunLevel Highest

Register-ScheduledTask `
    -TaskName 'SunshineUser' `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description 'Sunshine game streaming host (interactive session, correct WorkingDirectory)' `
    -Force | Out-Null

$task = Get-ScheduledTask -TaskName 'SunshineUser'
Write-Output "SunshineUser registered:"
Write-Output ("  Execute: {0}" -f $task.Actions[0].Execute)
if ($task.Actions[0].Arguments) {
    Write-Output ("  Arguments: {0}" -f $task.Actions[0].Arguments)
}
if ($task.Actions[0].WorkingDirectory) {
    Write-Output ("  WorkingDirectory: {0}" -f $task.Actions[0].WorkingDirectory)
}
Write-Output ("  State: {0}" -f $task.State)
