$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

$logDir = 'C:\Admin\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'install-winget.log'

function Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $line
    Add-Content -Path $logFile -Value $line -Encoding utf8
}

$winget = Get-Command winget.exe -ErrorAction SilentlyContinue
if (-not $winget) {
    $userWinget = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path $userWinget) {
        $winget = Get-Item $userWinget
    }
}

if ($winget) {
    Log "winget already available: $($winget.Source)"
    & $winget.Source --version 2>&1 | Out-String | Write-Output
    exit 0
}

Log 'winget not found, installing App Installer from local bundle'

$src = 'C:\Admin\apps\winget'
$bundle = Get-ChildItem $src -Filter '*.msixbundle' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $bundle) {
    Log 'ERROR: no .msixbundle found in C:\Admin\apps\winget'
    exit 1
}

$depsZip = Get-ChildItem $src -Filter '*Dependencies*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
$depPath = Join-Path $src 'deps'
if ($depsZip) {
    New-Item -ItemType Directory -Force -Path $depPath | Out-Null
    Expand-Archive -Path $depsZip.FullName -DestinationPath $depPath -Force
    Log "Extracted dependencies to $depPath"
}

$dependencies = Get-ChildItem $depPath -Recurse -Include '*.msix','*.appx' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\' } |
    Select-Object -ExpandProperty FullName

Log "Adding package: $($bundle.FullName)"
if ($dependencies) {
    $addOut = Add-AppxPackage -Path $bundle.FullName -DependencyPath $dependencies -ForceApplicationShutdown -ErrorAction Continue 2>&1 | Out-String
} else {
    $addOut = Add-AppxPackage -Path $bundle.FullName -ForceApplicationShutdown -ErrorAction Continue 2>&1 | Out-String
}
Log "Add-AppxPackage output: $addOut"

Start-Sleep -Seconds 5

$newWinget = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
if (Test-Path $newWinget) {
    Log "winget installed: $newWinget"
    & $newWinget --version 2>&1 | Out-String | Write-Output
} else {
    Log 'ERROR: winget still not found after Add-AppxPackage'
    Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
        Format-List Name, Version, InstallLocation | Out-String | Write-Output
}
