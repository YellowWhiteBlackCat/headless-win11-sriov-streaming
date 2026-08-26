param(
    [string]$SourceDir = 'C:\Admin\FFmpeg',
    [string]$ToolDir = 'C:\Admin\tools\ffmpeg'
)

# Deploy a standalone Windows FFmpeg build (BtbN win64-gpl, fully static) and
# verify the Intel QuickSync encoders it exposes. This gives the guest a
# direct way to test QSV outside Sunshine.
#
# Usage (on the guest):
#   1. Copy the extracted bin/ contents to C:\Admin\FFmpeg\ (or keep the zip
#      and use -SourceDir with the extracted folder).
#   2. Run: powershell -ExecutionPolicy Bypass -File install-ffmpeg.ps1

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

$logDir = 'C:\Admin\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'install-ffmpeg.log'

function Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $line
    Add-Content -Path $logFile -Value $line -Encoding utf8
}

if (-not (Test-Path -LiteralPath $SourceDir)) {
    throw "Source directory not found: $SourceDir (put the extracted BtbN win64-gpl bin/ contents there)"
}

New-Item -ItemType Directory -Force -Path $ToolDir | Out-Null

$exes = @('ffmpeg.exe', 'ffprobe.exe', 'ffplay.exe')
foreach ($exe in $exes) {
    $src = Join-Path $SourceDir $exe
    if (-not (Test-Path -LiteralPath $src)) {
        Write-Warning "Missing $exe in $SourceDir (ffplay is optional; ffmpeg/ffprobe are required)"
        if ($exe -ne 'ffplay.exe') {
            throw "Missing required $exe in $SourceDir"
        }
        continue
    }
    Copy-Item -Force $src (Join-Path $ToolDir $exe)
    Log "Copied $exe -> $ToolDir"
}

# Put ffmpeg on the machine PATH so diagnostics are trivial.
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($machinePath -notlike "*$ToolDir*") {
    [Environment]::SetEnvironmentVariable('Path', $machinePath.TrimEnd(';') + ';' + $ToolDir, 'Machine')
    Log "Added $ToolDir to machine PATH"
}
$env:Path += ';' + $ToolDir

$ff = Join-Path $ToolDir 'ffmpeg.exe'
& $ff -hide_banner -version 2>&1 | Select-Object -First 2

Write-Output '=== QSV encoders ==='
& $ff -hide_banner -encoders 2>&1 | Select-String -Pattern 'qsv' | ForEach-Object { $_.Line }

Write-Output '=== QSV smoke test (qsv=hw auto selection) ==='
& $ff -hide_banner -loglevel error -init_hw_device qsv=hw `
    -f lavfi -i 'testsrc2=size=640x360:rate=30:duration=1' `
    -c:v h264_qsv -f null - 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning "qsv=hw auto selection failed (exit $LASTEXITCODE); retrying with child_device=1"
    & $ff -hide_banner -loglevel error -init_hw_device qsv=hw,child_device=1 `
        -f lavfi -i 'testsrc2=size=640x360:rate=30:duration=1' `
        -c:v h264_qsv -f null - 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "QSV smoke test failed with exit code $LASTEXITCODE"
    }
}
Log 'QSV smoke test passed'
Write-Output 'FFmpeg install finished.'
