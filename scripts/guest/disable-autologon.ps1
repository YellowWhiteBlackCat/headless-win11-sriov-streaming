$ErrorActionPreference = 'Stop'
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

New-ItemProperty -Path $winlogon -Name 'AutoAdminLogon' -PropertyType String -Value '0' -Force | Out-Null
Remove-ItemProperty -Path $winlogon -Name 'DefaultPassword' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $winlogon -Name 'AutoLogonCount' -ErrorAction SilentlyContinue

Write-Output 'AutoLogon disabled'
