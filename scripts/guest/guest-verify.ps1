$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

Write-Output '===== DISPLAYS ====='
Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Output ("DISPLAY {0}`t{1}" -f $_.Status, $_.FriendlyName) }

Write-Output '===== SERVICES ====='
foreach ($name in 'QEMU-GA','sshd','SunshineService') {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Output ("SERVICE {0}`t{1}`t{2}" -f $svc.Status, $svc.StartType, $svc.Name)
    } else {
        Write-Output ("SERVICE MISSING`t{0}" -f $name)
    }
}

Write-Output '===== QSV ====='
$log = Get-Content -Path 'C:\Program Files\Sunshine\config\sunshine.log' -Tail 100 -Encoding UTF8 -ErrorAction SilentlyContinue
foreach ($enc in 'h264_qsv','hevc_qsv','av1_qsv') {
    if ($log -match $enc) {
        Write-Output ("QSV OK {0}" -f $enc)
    } else {
        Write-Output ("QSV MISSING {0}" -f $enc)
    }
}

Write-Output '===== UTF8 ====='
$cp = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -ErrorAction SilentlyContinue
if ($cp) {
    Write-Output ("CODEPAGE ACP={0} OEMCP={1} MACCP={2}" -f $cp.ACP, $cp.OEMCP, $cp.MACCP)
    if ($cp.ACP -eq '65001' -and $cp.OEMCP -eq '65001') {
        Write-Output 'UTF8 OK system-wide'
    } else {
        Write-Output 'UTF8 OFF'
    }
} else {
    Write-Output 'UTF8 MISSING CodePage key'
}
