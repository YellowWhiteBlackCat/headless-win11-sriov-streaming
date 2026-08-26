$ErrorActionPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

Write-Output '--- RECENT FILES (last 90 min, log-ish dirs) ---'
$roots = @(
    'C:\Windows\System32\LogFiles',
    'C:\Windows\Temp',
    'C:\Windows\System32\WDI',
    'C:\ProgramData'
)
$since = (Get-Date).AddMinutes(-90)
foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt $since -and $_.Length -gt 0 } |
        Select-Object -First 80 FullName, Length, LastWriteTime
}

Write-Output '--- MTTVDD IN TEXT FILES (recent) ---'
foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt $since -and $_.Length -lt 4MB } |
        Select-String -Pattern 'MttVDD|mttvdd|Virtual Display' -List -ErrorAction SilentlyContinue |
        Select-Object -First 40 Path
}

Write-Output '--- EVENT LOG CHANNELS ---'
wevtutil el | Select-String -Pattern 'wdf|driver|display|user-mode|UMDF' | Select-Object -First 40

Write-Output '--- WDF/DRIVER EVENTS ---'
$channels = wevtutil el | Select-String -Pattern 'WDF|UserModeDriver|Kernel-PnP|Kernel-Display' | ForEach-Object { $_.ToString().Trim() }
foreach ($ch in $channels) {
    Write-Output "== $ch"
    Get-WinEvent -LogName $ch -MaxEvents 60 -ErrorAction SilentlyContinue |
        Where-Object { $_.TimeCreated -gt $since } |
        Select-Object -First 20 TimeCreated, Id, LevelDisplayName, ProviderName, @{n='Msg'; e={$_.Message -replace '\s+',' '}} |
        Format-List
}

Write-Output '--- END ---'
