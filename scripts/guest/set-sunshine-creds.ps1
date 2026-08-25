param(
    [string]$Username = 'sunshine',
    [string]$Password = '',
    [switch]$NoReboot
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

# Resolve the Web UI password: -Password -> $env:SUNSHINE_WEB_PASSWORD ->
# C:\Admin\config\local-secrets.json (sunshineWebPassword) -> fail.
if (-not $Password) { $Password = $env:SUNSHINE_WEB_PASSWORD }
if (-not $Password) {
    $localSecrets = 'C:\Admin\config\local-secrets.json'
    if (Test-Path -LiteralPath $localSecrets) {
        $Password = (Get-Content -LiteralPath $localSecrets -Raw -Encoding UTF8 | ConvertFrom-Json).sunshineWebPassword
    }
}
if (-not $Password) {
    throw 'No Sunshine Web UI password provided. Use -Password, set $env:SUNSHINE_WEB_PASSWORD, or add sunshineWebPassword to C:\Admin\config\local-secrets.json'
}

$sunshine = 'C:\Program Files\Sunshine\sunshine.exe'
if (-not (Test-Path -LiteralPath $sunshine)) {
    throw "Sunshine executable not found at $sunshine"
}

& $sunshine --creds $Username $Password
if ($LASTEXITCODE -ne 0) {
    throw "sunshine --creds failed with exit code $LASTEXITCODE"
}

# Keep the guest-side secret store in sync so later helper runs (and this
# script's own fallback) still resolve the current password.
$localSecrets = 'C:\Admin\config\local-secrets.json'
if (Test-Path -LiteralPath $localSecrets) {
    $secrets = Get-Content -LiteralPath $localSecrets -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    $secrets = [PSCustomObject]@{}
}
$secrets | Add-Member -NotePropertyName sunshineWebPassword -NotePropertyValue $Password -Force
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $localSecrets) | Out-Null
$secrets | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $localSecrets -Encoding utf8

Write-Output "Sunshine Web UI credentials updated for user '$Username'"
Write-Output "Saved the new password to $localSecrets"
Write-Output 'REMINDER: also update SUNSHINE_WEB_PASSWORD in secrets.local.env on the Linux host'
Write-Output 'A reboot applies the new credentials and restarts Sunshine with the VDD display active.'

if (-not $NoReboot) {
    Write-Output 'Rebooting now...'
    Restart-Computer -Force
} else {
    Write-Output 'Skipped reboot (-NoReboot). Reboot later, or restart SunshineService while the VDD display is active.'
}
