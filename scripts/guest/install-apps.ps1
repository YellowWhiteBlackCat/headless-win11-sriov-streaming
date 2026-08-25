param(
    [switch]$All,
    [string]$ManifestPath = 'C:\Admin\apps\manifest.json'
)

$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

$logDir = 'C:\Admin\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'install-apps.log'

function Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $line
    Add-Content -Path $logFile -Value $line -Encoding utf8
}

Log "Starting app installs (All=$All)"

# Ensure winget exists first.
& 'C:\Admin\scripts\install-winget.ps1' | Out-String | Write-Output

$winget = Get-Command winget.exe -ErrorAction SilentlyContinue
if (-not $winget) {
    $userWinget = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path $userWinget) { $winget = Get-Item $userWinget }
}
if (-not $winget) {
    Log 'ERROR: winget unavailable; cannot install apps'
    exit 1
}

if (-not (Test-Path $ManifestPath)) {
    Log "ERROR: manifest not found: $ManifestPath"
    exit 1
}

$manifest = Get-Content -Raw -Path $ManifestPath -Encoding UTF8 | ConvertFrom-Json
$apps = @($manifest.applications | Where-Object { $_.required -or $All })

foreach ($app in $apps) {
    Log "Installing $($app.name) [$($app.id)]"
    $install = & $winget.Source install --id $app.id --exact --silent `
        --accept-package-agreements --accept-source-agreements `
        --disable-interactivity 2>&1 | Out-String
    Log $install
    if ($LASTEXITCODE -ne 0) {
        Log "WARNING: $($app.id) exit code $LASTEXITCODE"
    }
}

Log 'App installs finished'

$chrome = @(
    'C:\Program Files\Google\Chrome\Application\chrome.exe',
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($chrome) {
    Write-Output "Chrome installed: $chrome"
} else {
    Write-Output 'Chrome not detected after install'
}
