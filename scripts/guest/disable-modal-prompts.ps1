param(
    [switch]$Reboot
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

$logDir = 'C:\Admin\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'disable-modal-prompts.log'

function Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $line
    Add-Content -Path $logFile -Value $line -Encoding utf8
}

# 1. UAC: auto-elevate admin processes without a consent dialog, and never
#    switch to the secure desktop (which a headless stream cannot see or click).
$uac = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Set-ItemProperty -Path $uac -Name 'ConsentPromptBehaviorAdmin' -Value 0 -Type DWord
Set-ItemProperty -Path $uac -Name 'PromptOnSecureDesktop' -Value 0 -Type DWord
Set-ItemProperty -Path $uac -Name 'EnableLUA' -Value 1 -Type DWord
Log 'UAC: ConsentPromptBehaviorAdmin=0, PromptOnSecureDesktop=0, EnableLUA=1'

# 2. Windows Defender SmartScreen / "Windows protected your PC" prompts.
$polSystem = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
New-Item -Path $polSystem -Force | Out-Null
Set-ItemProperty -Path $polSystem -Name 'EnableSmartScreen' -Value 0 -Type DWord
$explorer = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'
Set-ItemProperty -Path $explorer -Name 'SmartScreenEnabled' -Value 'Off' -Type String
$appHost = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AppHost'
New-Item -Path $appHost -Force | Out-Null
Set-ItemProperty -Path $appHost -Name 'EnableWebContentEvaluation' -Value 0 -Type DWord
Log 'SmartScreen disabled (policy + Explorer + WebContentEvaluation)'

# 3. Windows Firewall "Allow access" notifications (first-run modal dialogs).
foreach ($profile in @('DomainProfile', 'StandardProfile', 'PublicProfile')) {
    $path = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\$profile"
    New-Item -Path $path -Force | Out-Null
    Set-ItemProperty -Path $path -Name 'DisableNotifications' -Value 1 -Type DWord
}
Log 'Firewall notifications disabled (Domain/Standard/Public)'

Log 'All modal permission prompts are disabled on this headless VM.'
if ($Reboot) {
    Log 'Rebooting now...'
    Restart-Computer -Force
}
