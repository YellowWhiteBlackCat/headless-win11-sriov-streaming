param(
    [string]$Ffmpeg = 'C:\Admin\tools\ffmpeg\ffmpeg.exe',
    [string]$Size = '3200x2000',
    [int]$Rate = 165,
    [int]$Seconds = 6,
    [ValidateSet('h264_qsv', 'hevc_qsv', 'av1_qsv')]
    [string]$Codec = 'hevc_qsv',
    [string]$Preset = 'medium',
    [int]$AsyncDepth = 4,
    [string]$LowPower = 'auto'
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

if (-not (Test-Path -LiteralPath $Ffmpeg)) {
    throw "ffmpeg not found: $Ffmpeg"
}

Write-Output "Benchmark: $Codec $Preset ${Size}@${Rate} async=$AsyncDepth low_power=$LowPower for ${Seconds}s"
# ffmpeg writes progress to stderr; PowerShell turns that into error records.
# Keep the exit code meaningful without tripping over native stderr.
$ErrorActionPreference = 'Continue'
& $Ffmpeg -hide_banner -loglevel info `
    -f lavfi -i "testsrc2=size=${Size}:rate=${Rate}" `
    -c:v $Codec -preset $Preset -async_depth $AsyncDepth `
    $(if ($LowPower -ne 'auto') { @('-low_power', $LowPower) }) `
    -t $Seconds -f null NUL 2>&1 |
    Select-String -Pattern 'fps|speed|frame=' |
    Select-Object -Last 6

Write-Output ("EXIT={0}" -f $LASTEXITCODE)
