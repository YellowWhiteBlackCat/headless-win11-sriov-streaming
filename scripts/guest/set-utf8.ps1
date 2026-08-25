param(
    [switch]$NoLog
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

$regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage'
$configDir = 'C:\Admin\config'
$logDir = 'C:\Admin\logs'
$backupJson = Join-Path $configDir 'codepage-backup.json'
$backupReg = Join-Path $configDir 'codepage-backup.reg'

New-Item -ItemType Directory -Force -Path $configDir | Out-Null
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$old = Get-ItemProperty -Path $regPath
$oldVals = @{
    ACP   = $old.ACP
    OEMCP = $old.OEMCP
    MACCP = $old.MACCP
}

# 只在没有可用备份（或备份本身已是 65001 而当前不是）时创建备份，避免覆盖最初的 936 现场
$backupCurrent = $null
if (Test-Path -LiteralPath $backupJson) {
    try {
        $backupCurrent = Get-Content -LiteralPath $backupJson -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        $backupCurrent = $null
    }
}

$needsBackup = $null -eq $backupCurrent -or
    ($backupCurrent.ACP -eq '65001' -and $oldVals.ACP -ne '65001')

if ($needsBackup) {
    & "$env:SystemRoot\System32\reg.exe" export `
        "HKLM\SYSTEM\CurrentControlSet\Control\Nls\CodePage" $backupReg /y | Out-Null
    $oldVals | ConvertTo-Json | Set-Content -LiteralPath $backupJson -Encoding UTF8
    Write-Output "Backup created: $backupJson"
} else {
    Write-Output "Existing backup kept: $backupJson"
}

foreach ($name in 'ACP', 'OEMCP', 'MACCP') {
    Set-ItemProperty -Path $regPath -Name $name -Value '65001' -Type String -Force
}

$new = Get-ItemProperty -Path $regPath
$line = ("[{0}] OLD ACP/OEMCP/MACCP={1}/{2}/{3} -> NEW={4}/{5}/{6}" -f
    (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
    $oldVals.ACP, $oldVals.OEMCP, $oldVals.MACCP,
    $new.ACP, $new.OEMCP, $new.MACCP)

if (-not $NoLog) {
    Add-Content -LiteralPath (Join-Path $logDir 'set-utf8.log') -Value $line -Encoding UTF8
}
Write-Output $line
Write-Output 'UTF-8 codepage applied. REBOOT REQUIRED to take effect.'
