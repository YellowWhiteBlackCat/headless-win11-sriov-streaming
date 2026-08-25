$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

# Reports WHERE each credential lives and whether it is set. It never prints
# the values themselves, so it is safe to run over SSH or in CI.

function Status {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    $mark = if ($Ok) { 'OK ' } else { 'MISS' }
    Write-Output ("CRED {0} {1} {2}" -f $mark, $Name, $Detail)
}

# 1. Windows admin account
$admin = Get-LocalUser -Name 'vmadmin' -ErrorAction SilentlyContinue
Status 'local-user-vmadmin' ([bool]$admin) $admin.SID
$isAdmin = $false
if ($admin) {
    $adminGroup = Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue
    if ($adminGroup) {
        $isAdmin = [bool](Get-LocalGroupMember -Group $adminGroup.Name -ErrorAction SilentlyContinue |
            Where-Object { $_.SID.Value -eq $admin.SID.Value })
    }
}
Status 'vmadmin-in-administrators' $isAdmin

# 2. Guest secret store (schema only; never dump values)
$localSecrets = 'C:\Admin\config\local-secrets.json'
$secrets = $null
if (Test-Path -LiteralPath $localSecrets) {
    $secrets = Get-Content -LiteralPath $localSecrets -Raw -Encoding UTF8 | ConvertFrom-Json
}
Status 'guest-local-secrets-file' ($null -ne $secrets) $localSecrets
Status 'secret-adminPassword' ($null -ne $secrets -and [bool]$secrets.adminPassword) 'C:\Admin\config\local-secrets.json'
Status 'secret-secondNicMac' ($null -ne $secrets -and [bool]$secrets.secondNicMac) 'C:\Admin\config\local-secrets.json'
Status 'secret-sunshineWebPassword' ($null -ne $secrets -and [bool]$secrets.sunshineWebPassword) 'C:\Admin\config\local-secrets.json'

# 3. AutoLogon (stores the admin password in the LSA winlogon key)
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$autoUser = (Get-ItemProperty -Path $winlogon -ErrorAction SilentlyContinue).DefaultUserName
$autoPass = (Get-ItemProperty -Path $winlogon -ErrorAction SilentlyContinue).DefaultPassword
Status 'autologon-username' ([bool]$autoUser -and $autoUser -eq 'vmadmin') "DefaultUserName=$autoUser"
Status 'autologon-password-stored' ([bool]$autoPass) 'HKLM\...\Winlogon\DefaultPassword'

# 4. OpenSSH authorized keys
$authKeys = 'C:\ProgramData\ssh\administrators_authorized_keys'
$keyOk = Test-Path -LiteralPath $authKeys
if ($keyOk) {
    $acl = icacls.exe $authKeys | Out-String
    $keyOk = (($acl -match 'Administrators') -and ($acl -match 'SYSTEM'))
}
Status 'ssh-authorized-keys' $keyOk $authKeys

# 5. Sunshine Web UI credential store
$state = 'C:\Program Files\Sunshine\config\sunshine_state.json'
$sunState = $null
if (Test-Path -LiteralPath $state) {
    $sunState = Get-Content -LiteralPath $state -Raw -Encoding UTF8 | ConvertFrom-Json
}
Status 'sunshine-state-file' ($null -ne $sunState) $state
$saltOk = $false
$hashOk = $false
if ($sunState) {
    $saltOk = [bool]$sunState.salt
    $hashOk = [bool]$sunState.password
}
Status 'sunshine-credential-salt' $saltOk 'inside sunshine_state.json'
Status 'sunshine-credential-hash' $hashOk 'inside sunshine_state.json'

# 6. Sunshine service state (the Web UI only works when this is running)
$svc = Get-Service -Name SunshineService -ErrorAction SilentlyContinue
Status 'sunshine-service-running' ($null -ne $svc -and $svc.Status -eq 'Running') ($(if ($svc) { $svc.Status.ToString() } else { 'missing' }))

Write-Output 'CRED DONE'
