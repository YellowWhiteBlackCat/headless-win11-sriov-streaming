param(
    [string]$MsysRoot = 'C:\msys64',
    [string]$SourceDir = 'C:\Admin\build\sunshine-src',
    [string]$InstallDir = 'C:\Program Files\Sunshine'
)

# Builds the qsv_async_depth-patched Sunshine and swaps it into the
# production install directory (with a timestamped backup). Run as
# Administrator on the Windows guest.
$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

$logDir = 'C:\Admin\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$buildLog = Join-Path $logDir 'build-sunshine-orchestrator.log'

function Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $line
    Add-Content -Path $buildLog -Value $line -Encoding utf8
}

$bash = Join-Path $MsysRoot 'usr\bin\bash.exe'
if (-not (Test-Path -LiteralPath $bash)) {
    Log "MSYS2 not found at $MsysRoot; downloading base archive"
    $dlDir = 'C:\Admin\build'
    New-Item -ItemType Directory -Force -Path $dlDir | Out-Null
    $msysTar = Join-Path $dlDir 'msys2-base-x86_64-latest.tar.xz'
    if (-not (Test-Path -LiteralPath $msysTar)) {
        $url = 'https://github.com/msys2/msys2-installer/releases/download/nightly-x86_64/msys2-base-x86_64-latest.tar.xz'
        Log "Downloading $url"
        Invoke-WebRequest -Uri $url -OutFile $msysTar -UseBasicParsing
    }
    Log 'Extracting MSYS2 base'
    tar -xf $msysTar -C C:\
    if (-not (Test-Path -LiteralPath $bash)) {
        throw "MSYS2 extraction failed: $bash missing"
    }
}

Log 'Updating MSYS2 and installing dependencies (first run can take a while)'
# Native tools (bash/pacman) write progress to stderr; do not let that abort
# the orchestrator. Check exit codes explicitly instead.
$ErrorActionPreference = 'Continue'
& $bash -lc 'pacman-key --init && pacman-key --populate msys2' 2>&1 | Tee-Object -FilePath $buildLog -Append
if ($LASTEXITCODE -ne 0) {
    throw "pacman-key initialization failed (exit $LASTEXITCODE)"
}
& $bash -lc 'pacman -Syu --noconfirm' 2>&1 | Tee-Object -FilePath $buildLog -Append
if ($LASTEXITCODE -ne 0) {
    throw "pacman update failed (exit $LASTEXITCODE)"
}

$deps = @(
    'git',
    'mingw-w64-ucrt-x86_64-boost',
    'mingw-w64-ucrt-x86_64-cmake',
    'mingw-w64-ucrt-x86_64-cppwinrt',
    'mingw-w64-ucrt-x86_64-curl-winssl',
    'mingw-w64-ucrt-x86_64-doxygen',
    'mingw-w64-ucrt-x86_64-gcc',
    'mingw-w64-ucrt-x86_64-graphviz',
    'mingw-w64-ucrt-x86_64-miniupnpc',
    'mingw-w64-ucrt-x86_64-nlohmann-json',
    'mingw-w64-ucrt-x86_64-onevpl',
    'mingw-w64-ucrt-x86_64-openssl',
    'mingw-w64-ucrt-x86_64-opus',
    'mingw-w64-ucrt-x86_64-toolchain',
    'mingw-w64-ucrt-x86_64-qt6-static',
    'mingw-w64-ucrt-x86_64-MinHook',
    'mingw-w64-ucrt-x86_64-ninja',
    'mingw-w64-ucrt-x86_64-nodejs',
    'mingw-w64-ucrt-x86_64-pkgconf'
)
$depsList = $deps -join ' '
& $bash -lc "pacman -S --needed --noconfirm $depsList" 2>&1 | Tee-Object -FilePath $buildLog -Append
if ($LASTEXITCODE -ne 0) {
    throw "pacman dependency install failed (exit $LASTEXITCODE)"
}

Log 'Running patched build script inside MSYS2 UCRT64'
& $bash -lc '/c/Admin/scripts/build-sunshine-patched.sh' 2>&1 | Tee-Object -FilePath $buildLog -Append
if ($LASTEXITCODE -ne 0) {
    throw "Sunshine build failed (exit $LASTEXITCODE); see $buildLog"
}

$stage = 'C:\Admin\build\sunshine-stage'
$exe = Join-Path $stage 'Sunshine.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    throw "Staged Sunshine.exe not found at $exe"
}

Log "Stopping Sunshine before swap"
Stop-ScheduledTask -TaskName SunshineUser -ErrorAction SilentlyContinue
Get-Process Sunshine -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 3

$backup = Join-Path 'C:\Admin\backup' ('sunshine-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
Log "Backing up $InstallDir -> $backup"
Move-Item -LiteralPath $InstallDir -Destination $backup
Copy-Item -Recurse -LiteralPath $stage -Destination $InstallDir

# Preserve Web UI credentials, Moonlight pairing and the install-dir config
# copy from the previous install (the config under ProgramData is untouched).
$backupConfig = Join-Path $backup 'config'
$newConfig = Join-Path $InstallDir 'config'
foreach ($name in 'sunshine_state.json', 'sunshine.conf') {
    $src = Join-Path $backupConfig $name
    if (Test-Path -LiteralPath $src) {
        Copy-Item -Force -LiteralPath $src (Join-Path $newConfig $name)
        Log "Restored $name from backup"
    }
}

Log "Patched Sunshine installed; restarting task"
Start-ScheduledTask -TaskName SunshineUser
# The start wrapper waits for VDD/Arc, enforces topology (~15 s) and then
# verifies Sunshine stays alive for 15 s; give it enough time.
Start-Sleep -Seconds 75
$p = Get-Process Sunshine -ErrorAction SilentlyContinue
if (-not $p) {
    throw 'Patched Sunshine did not stay alive after restart; restore from backup if needed'
}

Log "Patched Sunshine running (PID $($p.Id -join ','))"
