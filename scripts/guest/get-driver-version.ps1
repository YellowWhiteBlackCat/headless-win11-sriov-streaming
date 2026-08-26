$ErrorActionPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

$vc = Get-CimInstance Win32_VideoController |
    Where-Object { $_.Name -like '*Arc*' } |
    Select-Object -First 1

if ($vc) {
    Write-Output $vc.DriverVersion
} else {
    Write-Output '<none>'
}
