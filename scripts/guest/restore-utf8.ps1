param(
    [switch]$Reboot
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

$regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage'
$backupJson = 'C:\Admin\config\codepage-backup.json'
$backupReg = 'C:\Admin\config\codepage-backup.reg'

if (Test-Path -LiteralPath $backupJson) {
    $old = Get-Content -LiteralPath $backupJson -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($name in 'ACP', 'OEMCP', 'MACCP') {
        Set-ItemProperty -Path $regPath -Name $name -Value $old.$name -Type String -Force
    }
    Write-Output ("Restored ACP={0} OEMCP={1} MACCP={2}" -f $old.ACP, $old.OEMCP, $old.MACCP)
} elseif (Test-Path -LiteralPath $backupReg) {
    & "$env:SystemRoot\System32\reg.exe" import $backupReg | Out-Null
    Write-Output "No JSON backup found; imported $backupReg"
} else {
    throw "Backup not found: $backupJson / $backupReg"
}

Write-Output 'REBOOT REQUIRED to take effect.'
if ($Reboot) {
    Write-Output 'Restarting now...'
    Restart-Computer -Force
}
