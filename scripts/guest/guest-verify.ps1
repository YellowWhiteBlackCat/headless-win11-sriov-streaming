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

Write-Output '===== SUNSHINE LAUNCHER ====='
$task = Get-ScheduledTask -TaskName 'SunshineUser' -ErrorAction SilentlyContinue
if ($task) {
    $proc = Get-Process -Name sunshine -ErrorAction SilentlyContinue
    $info = Get-ScheduledTaskInfo -TaskName 'SunshineUser' -ErrorAction SilentlyContinue
    Write-Output ("TASK {0}`t{1}`tLastResult=0x{2:X}`tPID={3}" -f `
        $task.State, $task.Actions[0].WorkingDirectory, $info.LastTaskResult, `
        ($(if ($proc) { $proc.Id -join ',' } else { 'none' })))
} else {
    Write-Output 'TASK MISSING SunshineUser'
}

Write-Output '===== SUNSHINE LISTENERS ====='
$sunshineListeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)
foreach ($port in 47989, 47984) {
    if ($sunshineListeners | Where-Object { $_.LocalPort -eq $port }) {
        Write-Output ("LISTENER OK`t{0}" -f $port)
    } else {
        Write-Output ("LISTENER MISSING`t{0}" -f $port)
    }
}

Write-Output '===== QSV ====='
$logFile = 'C:\Program Files\Sunshine\config\sunshine.log'
foreach ($enc in 'h264_qsv','hevc_qsv','av1_qsv') {
    $found = $null
    if (Test-Path -LiteralPath $logFile) {
        $found = Select-String -LiteralPath $logFile -Pattern ("Found .* encoder: {0}" -f $enc) -SimpleMatch:$false -ErrorAction SilentlyContinue |
            Select-Object -Last 1
    }
    if ($found) {
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
