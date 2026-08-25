$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

# Second NIC is the one with MAC 52:54:00:40:CB:92 (Sunshine private network).
$nic = Get-NetAdapter -Physical | Where-Object { $_.MacAddress -eq '52-54-00-40-CB-92' }
if (-not $nic) {
    throw 'Second NIC not found by MAC 52:54:00:40:CB:92'
}

$existing = Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -ne '169.254.29.216' }

if ($existing) {
    Remove-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
}

New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress '192.168.200.2' -PrefixLength 24 -ErrorAction Stop | Out-Null

Write-Output "Configured $($nic.Name) [$($nic.MacAddress)] -> 192.168.200.2/24"
Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 |
    Format-Table InterfaceAlias, IPAddress, PrefixLength -AutoSize |
    Out-String | Write-Output
