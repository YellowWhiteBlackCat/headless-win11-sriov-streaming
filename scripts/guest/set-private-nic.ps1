param(
    [string]$SecondNicMac = ''
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

# Resolve the target NIC MAC: -SecondNicMac -> $env:SECOND_NIC_MAC ->
# C:\Admin\config\local-secrets.json (secondNicMac) -> fail with a NIC list.
if (-not $SecondNicMac) { $SecondNicMac = $env:SECOND_NIC_MAC }
if (-not $SecondNicMac) {
    $localSecrets = 'C:\Admin\config\local-secrets.json'
    if (Test-Path -LiteralPath $localSecrets) {
        $SecondNicMac = (Get-Content -LiteralPath $localSecrets -Raw -Encoding UTF8 | ConvertFrom-Json).secondNicMac
    }
}
if (-not $SecondNicMac) {
    Write-Output 'No -SecondNicMac provided. Detected adapters:'
    Get-NetAdapter -Physical | Format-Table Name, MacAddress, Status -AutoSize | Out-String | Write-Output
    throw 'Provide -SecondNicMac, set $env:SECOND_NIC_MAC, or add secondNicMac to C:\Admin\config\local-secrets.json'
}

$mac = $SecondNicMac -replace '-', ''
$nic = Get-NetAdapter -Physical | Where-Object { ($_.MacAddress -replace '-', '') -eq $mac }
if (-not $nic) {
    throw "Second NIC not found by MAC $SecondNicMac"
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
