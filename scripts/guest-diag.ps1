$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

Write-Output '===== PNP DEVICES (Display/System) ====='
Get-PnpDevice -PresentOnly |
    Where-Object {
        $_.Class -eq 'Display' -or
        $_.Class -eq 'System' -or
        $_.FriendlyName -match 'VirtIO|Virtio|Intel|VDD|Display'
    } |
    Sort-Object Class, Status, FriendlyName |
    Format-Table Status, Class, FriendlyName, InstanceId -AutoSize |
    Out-String -Width 260

Write-Output '===== VIDEO CONTROLLERS ====='
Get-CimInstance Win32_VideoController |
    Select-Object Name, Status, PNPDeviceID, DriverVersion, VideoModeDescription |
    Format-Table -AutoSize |
    Out-String -Width 260

Write-Output '===== DRIVER PACKAGES (matching) ====='
$pnputil = pnputil /enum-drivers | Out-String
$lines = $pnputil -split "`r?`n"
$hit = $false
foreach ($line in $lines) {
    if ($line -match '发布名称|Published Name|原始名称|Original Name') { $hit = $true }
    elseif ($line -match '^[^ ]' -and $line.Trim() -ne '') { $hit = $false }
    if ($hit -or $line -match 'Intel|VirtIO|Virtio|VDD|Mtt|Display') {
        Write-Output $line
    }
}

Write-Output '===== SERVICES ====='
Get-Service -Name 'QEMU-GA','sshd','SunshineService','IntelDisplayUMService','DVEnabler','DVServer*' -ErrorAction SilentlyContinue |
    Format-Table Status, StartType, Name, DisplayName -AutoSize |
    Out-String -Width 200

Write-Output '===== NETWORK ====='
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254*' } |
    Select-Object InterfaceAlias, IPAddress, PrefixLength |
    Format-Table -AutoSize |
    Out-String -Width 200

Write-Output '===== QGA ====='
Get-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue | Format-List *
