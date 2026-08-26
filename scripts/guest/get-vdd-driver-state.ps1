param(
    [string]$LogDir = 'C:\Admin\logs'
)

# Inspect the VDD driver stack and recent display-related system events
# after an Intel driver upgrade. Used to decide whether a deterministic
# device rebuild is needed.
$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

Write-Output '--- VDD SERVICES/DRIVERS ---'
Get-Service | Where-Object { $_.Name -match 'vdd|mtt|display' -or $_.DisplayName -match 'virtual display' } |
    Select-Object Status, Name, DisplayName | Format-Table -AutoSize

Write-Output '--- VDD PNP DETAIL ---'
pnputil /enum-devices /class Display

Write-Output '--- RECENT DISPLAY EVENTS ---'
Get-WinEvent -LogName System -MaxEvents 500 -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -match 'Mtt|Display|igfx|Video|Kernel-PnP|Kernel-Power' } |
    Select-Object -First 40 TimeCreated, Id, LevelDisplayName, ProviderName, @{n='Msg'; e={$_.Message -replace '\s+',' '}} |
    Format-List

Write-Output '--- SETUPAPI MTTVDD ---'
$setupLog = "$env:SystemRoot\INF\setupapi.dev.log"
if (Test-Path -LiteralPath $setupLog) {
    Select-String -LiteralPath $setupLog -Pattern 'MttVDD|mttvdd' -Context 2,4 | Select-Object -Last 60 | ForEach-Object { $_.ToString() }
}

Write-Output '--- END ---'
