param(
    [string]$UserName = 'vmadmin',
    [string]$Password = ''
)

$ErrorActionPreference = 'Stop'
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

if (-not $Password) { $Password = $env:ADMIN_PASSWORD }
if (-not $Password) {
    $localSecrets = 'C:\Admin\config\local-secrets.json'
    if (Test-Path -LiteralPath $localSecrets) {
        $Password = (Get-Content -LiteralPath $localSecrets -Raw -Encoding UTF8 | ConvertFrom-Json).adminPassword
    }
}
if (-not $Password) {
    throw 'No admin password provided. Use -Password, set $env:ADMIN_PASSWORD, or create C:\Admin\config\local-secrets.json'
}

New-ItemProperty -Path $winlogon -Name 'AutoAdminLogon' -PropertyType String -Value '1' -Force | Out-Null
New-ItemProperty -Path $winlogon -Name 'DefaultUserName' -PropertyType String -Value $UserName -Force | Out-Null
New-ItemProperty -Path $winlogon -Name 'DefaultPassword' -PropertyType String -Value $Password -Force | Out-Null
New-ItemProperty -Path $winlogon -Name 'AutoLogonCount' -PropertyType DWord -Value 3 -Force | Out-Null

Write-Output "AutoLogon enabled for $UserName (limited to 3 logons)"
