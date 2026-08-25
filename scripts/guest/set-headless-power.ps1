$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

# A headless VM must never turn off its rescue display or sleep.
& "$env:SystemRoot\System32\powercfg.exe" /change monitor-timeout-ac 0
& "$env:SystemRoot\System32\powercfg.exe" /change monitor-timeout-dc 0
& "$env:SystemRoot\System32\powercfg.exe" /change standby-timeout-ac 0
& "$env:SystemRoot\System32\powercfg.exe" /change standby-timeout-dc 0
& "$env:SystemRoot\System32\powercfg.exe" /change hibernate-timeout-ac 0
& "$env:SystemRoot\System32\powercfg.exe" /change hibernate-timeout-dc 0

Write-Output 'Headless power policy applied: monitor/sleep/hibernate timeouts disabled'
