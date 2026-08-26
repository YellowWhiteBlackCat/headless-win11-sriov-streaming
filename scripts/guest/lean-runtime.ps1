#requires -Version 5.1
<#
.SYNOPSIS
    Reduce avoidable Windows runtime services for the video-only VM profile.

.DESCRIPTION
    This script changes selected service startup modes and, only when explicitly
    requested, removes unused vendor/consumer startup entries, disables
    telemetry/consumer tasks and stops their processes. With
    -RemoveConsumerAppx it also removes an explicit allowlist of consumer AppX
    packages; that part is not automatically reversible.
    It never removes WebView2 Runtime, Windows management components, drivers,
    or the QEMU/Sunshine control path.

    Apply is fail-closed for the runtime profile: memory compression must remain
    enabled, QEMU-GA and sshd must remain running, the three display adapters
    must remain present, and Sunshine must have an interactive process listening
    on both its web/control and streaming TCP ports.

    The default profile targets services that are not used by this repository:
    local search, printing, Bluetooth, consumer/Xbox services, UPnP, Maps,
    phone integration and Internet Connection Sharing. The aggressive profile
    additionally targets cache/telemetry/notification services and per-user
    consumer services; use it only after measuring real memory pressure.

    Audit is the default. Apply writes a JSON backup before changing anything;
    Rollback restores the saved startup modes and running/stopped state.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\lean-runtime.ps1 -Mode Audit

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\lean-runtime.ps1 -Mode Apply

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\lean-runtime.ps1 -Mode Apply -DisableVendorStartup

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\lean-runtime.ps1 -Mode Apply -IncludeAggressive -DisableConsumerStartup -RemoveConsumerAppx

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\lean-runtime.ps1 -Mode Rollback
##>

[CmdletBinding()]
param(
    [ValidateSet('Audit', 'Apply', 'Rollback')]
    [string]$Mode = 'Audit',

    [switch]$IncludeAggressive,

    [switch]$DisableUnusedRemote,

    [switch]$DisableVendorStartup,

    [switch]$DisableConsumerStartup,

    [switch]$RemoveConsumerAppx,

    [ValidateRange(5, 120)]
    [int]$SunshineReadyTimeoutSeconds = 30,

    [string]$BackupPath = 'C:\Admin\config\lean-runtime-services.json',

    [string]$LogPath = 'C:\Admin\logs\lean-runtime.log'
)

$ErrorActionPreference = 'Stop'

# These services are part of the repository's recovery, management, driver,
# display, audio or networking paths. A policy must never match one of them.
$ProtectedServices = @(
    'QEMU-GA', 'sshd', 'SunshineService',
    'RpcSs', 'RpcEptMapper', 'DcomLaunch', 'Winmgmt', 'Schedule', 'EventLog',
    'PlugPlay', 'ProfSvc', 'CryptSvc', 'BFE', 'MpsSvc', 'Dhcp', 'Dnscache',
    'NlaSvc', 'Audiosrv', 'AudioEndpointBuilder', 'AppXSvc', 'StateRepository',
    'BITS', 'wuauserv', 'TrustedInstaller', 'msiserver',
    'IGSDSserviceIntegrated', 'IntelDisplayUMService', 'GraphicsPerfSvc'
)

# Conservative policy: these services have no role in the current VM use case.
# Missing services are silently reported as absent because Windows builds vary.
$ConservativePolicies = @(
    @{ Pattern = 'WSearch';       StartupType = 'Disabled'; Reason = 'No local file search; prevents SearchIndexer/SearchHost background work' },
    @{ Pattern = 'Spooler';       StartupType = 'Disabled'; Reason = 'No printer or print queue' },
    @{ Pattern = 'Fax';           StartupType = 'Disabled'; Reason = 'No fax device' },
    @{ Pattern = 'bthserv';       StartupType = 'Disabled'; Reason = 'No Bluetooth hardware' },
    @{ Pattern = 'RemoteRegistry';StartupType = 'Disabled'; Reason = 'No remote registry administration' },
    @{ Pattern = 'MapsBroker';    StartupType = 'Disabled'; Reason = 'No Windows Maps integration' },
    @{ Pattern = 'PhoneSvc';      StartupType = 'Disabled'; Reason = 'No phone integration' },
    @{ Pattern = 'WMPNetworkSvc'; StartupType = 'Disabled'; Reason = 'No media library sharing' },
    @{ Pattern = 'RetailDemo';    StartupType = 'Disabled'; Reason = 'Not a retail/demo device' },
    @{ Pattern = 'SSDPSRV';       StartupType = 'Disabled'; Reason = 'UPnP discovery is disabled in Sunshine configuration' },
    @{ Pattern = 'upnphost';      StartupType = 'Disabled'; Reason = 'UPnP device hosting is not used' },
    @{ Pattern = 'SharedAccess';  StartupType = 'Disabled'; Reason = 'No Internet Connection Sharing' },
    @{ Pattern = 'XboxGipSvc*';   StartupType = 'Disabled'; Reason = 'No Xbox controller integration' },
    @{ Pattern = 'XblAuthManager*';StartupType = 'Disabled'; Reason = 'No Xbox authentication' },
    @{ Pattern = 'XblGameSave*';  StartupType = 'Disabled'; Reason = 'No Xbox game saves' },
    @{ Pattern = 'XboxNetApiSvc*';StartupType = 'Disabled'; Reason = 'No Xbox networking' },
    @{ Pattern = 'DSAService';    StartupType = 'Disabled'; Reason = 'Intel Driver & Support Assistant is not part of the ordered driver workflow' },
    @{ Pattern = 'DSAUpdateService'; StartupType = 'Disabled'; Reason = 'Intel Driver & Support Assistant updater is not required' },
    @{ Pattern = 'IntelGraphicsSoftwareService'; StartupType = 'Disabled'; Reason = 'Intel graphics control/overlay service is not required by Arc VF, VDD or QuickSync' }
)

# These are deliberately opt-in. They can reduce background activity, but the
# memory benefit is workload/build dependent and the trade-offs are larger.
$AggressivePolicies = @(
    @{ Pattern = 'SysMain';       StartupType = 'Disabled'; Reason = 'Disable Superfetch only after measuring real memory pressure' },
    @{ Pattern = 'DiagTrack';     StartupType = 'Disabled'; Reason = 'No telemetry collection required for this isolated VM' },
    @{ Pattern = 'WpnService';    StartupType = 'Disabled'; Reason = 'No Windows push notifications' },
    @{ Pattern = 'WpnUserService_*';       StartupType = 'Disabled'; Reason = 'No per-user push notifications' },
    @{ Pattern = 'DoSvc';         StartupType = 'Manual';   Reason = 'Delivery Optimization only on demand; keep Windows Update available' },
    @{ Pattern = 'OneSyncSvc_*';  StartupType = 'Disabled'; Reason = 'No Mail/Calendar/contacts synchronization' },
    @{ Pattern = 'CDPUserSvc_*';  StartupType = 'Disabled'; Reason = 'No consumer device/cross-device integration' },
    @{ Pattern = 'PimIndexMaintenanceSvc_*'; StartupType = 'Disabled'; Reason = 'No consumer personal-information indexing' },
    @{ Pattern = 'MessagingService_*';      StartupType = 'Disabled'; Reason = 'No consumer messaging integration' },
    @{ Pattern = 'UserDataSvc_*';            StartupType = 'Disabled'; Reason = 'No consumer user-data sync' },
    @{ Pattern = 'UnistoreSvc_*';            StartupType = 'Disabled'; Reason = 'No consumer store-data sync' },
    @{ Pattern = 'BcastDVRUserService_*';    StartupType = 'Disabled'; Reason = 'No Xbox Game DVR/capture' },
    @{ Pattern = 'dmwappushservice';         StartupType = 'Disabled'; Reason = 'Legacy WAP push/telemetry service is not used' },
    @{ Pattern = 'ClickToRunSvc';            StartupType = 'Disabled'; Reason = 'No Microsoft Office or Outlook workload in the video-only VM' }
)

# RDP/WinRM are not used by this repository, but they may be a user's fallback
# channel. Keep them untouched unless the caller explicitly opts in.
$UnusedRemotePolicies = @(
    @{ Pattern = 'TermService'; StartupType = 'Disabled'; Reason = 'SSH + QGA are the supported management paths; no RDP' },
    @{ Pattern = 'UmRdpService';StartupType = 'Disabled'; Reason = 'No RDP user-mode port redirector' },
    @{ Pattern = 'WinRM';       StartupType = 'Disabled'; Reason = 'No WinRM/PowerShell Remoting' }
)

# Intel Graphics Software is a user-facing control/overlay application. The
# display driver and QuickSync stack remain installed; only this startup entry
# and its helper processes are disabled when the caller explicitly opts in.
$VendorStartupPolicies = @(
    @{ Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Pattern = 'Intel.*Graphics.*Software'; Reason = 'No Intel control-center tray/overlay in a headless VM' }
)

$ConsumerStartupPolicies = @(
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Pattern = '^(OneDrive|Outlook|Microsoft Teams|Teams)$'; Reason = 'No OneDrive, Outlook or Teams background startup' },
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; Pattern = '^(OneDrive|Outlook|Microsoft Teams|Teams|Microsoft Office|Office)$'; Reason = 'No Office/consumer background startup' },
    @{ Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Pattern = '^(OneDrive|Outlook|Microsoft Teams|Teams|Microsoft Office|Office)$'; Reason = 'No Office/consumer background startup' }
)

$VendorProcessNames = @(
    'IntelGraphicsSoftware',
    'IntelGraphicsSoftware.Overlay',
    'PresentMonService'
)

$ConsumerProcessNames = @(
    'OneDrive',
    'OUTLOOK',
    'olk',
    'Teams',
    'ms-teams',
    'msteams',
    'Widgets'
)

# Scheduled tasks are disabled only in -IncludeAggressive mode. Paths and names
# are matched separately because task names vary slightly between Windows
# builds and language packs.
$TelemetryTaskPolicies = @(
    @{ TaskPath = '\Microsoft\Windows\Application Experience\'; TaskName = 'Microsoft Compatibility Appraiser*'; Reason = 'Microsoft compatibility telemetry is not required' },
    @{ TaskPath = '\Microsoft\Windows\Application Experience\'; TaskName = 'ProgramDataUpdater'; Reason = 'Application compatibility inventory is not required' },
    @{ TaskPath = '\Microsoft\Windows\Application Experience\'; TaskName = 'StartupAppTask'; Reason = 'Startup application inventory is not required' },
    @{ TaskPath = '\Microsoft\Windows\Application Experience\'; TaskName = 'PcaPatchDbTask'; Reason = 'Compatibility assistant inventory is not required' },
    @{ TaskPath = '\Microsoft\Windows\Customer Experience Improvement Program\'; TaskName = 'Consolidator'; Reason = 'Customer Experience Improvement telemetry is not required' },
    @{ TaskPath = '\Microsoft\Windows\Customer Experience Improvement Program\'; TaskName = 'UsbCeip'; Reason = 'USB Customer Experience Improvement telemetry is not required' },
    @{ TaskPath = '\Microsoft\Windows\Customer Experience Improvement Program\'; TaskName = 'KernelCeipTask'; Reason = 'Kernel Customer Experience Improvement telemetry is not required' },
    @{ TaskPath = '\Microsoft\Windows\Feedback\Siuf\'; TaskName = 'DmClient*'; Reason = 'Windows feedback telemetry is not required' },
    @{ TaskPath = '\Microsoft\Windows\PI\'; TaskName = 'Sqm-Tasks'; Reason = 'Software Quality Metrics telemetry is not required' },
    @{ TaskPath = '\Microsoft\Windows\Windows Error Reporting\'; TaskName = 'QueueReporting'; Reason = 'Automatic remote error-report upload is not required' },
    @{ TaskPath = '\Microsoft\Windows\Sustainability\'; TaskName = '*Telemetry*'; Reason = 'Sustainability telemetry is not required' }
)

$ConsumerTaskPolicies = @(
    @{ TaskPath = '\'; TaskName = 'OneDrive*'; Reason = 'No OneDrive synchronization or reporting' },
    @{ TaskPath = '\Microsoft\Office\'; TaskName = '*'; Reason = 'No Office/Outlook background tasks' }
)

# These are ad-hoc display test tasks found on the reference guest. They can
# race with the Sunshine connect/disconnect transition and leave the rescue
# adapter disabled. They are disabled (not deleted) by the aggressive profile;
# the supported logon task FixDisplayTopology remains untouched.
$DisplayConflictTaskPolicies = @(
    @{ TaskPath = '\'; TaskName = 'FixDisplayTopologyMMT'; Reason = 'Do not race Sunshine display prep at a scheduled time' },
    @{ TaskPath = '\'; TaskName = 'MMDis3'; Reason = 'Ad-hoc task can disable a display path' },
    @{ TaskPath = '\'; TaskName = 'MMList'; Reason = 'Ad-hoc monitor enumeration task is not needed at runtime' },
    @{ TaskPath = '\'; TaskName = 'MMList2'; Reason = 'Ad-hoc monitor enumeration task is not needed at runtime' },
    @{ TaskPath = '\'; TaskName = 'MMOnly'; Reason = 'Ad-hoc OnlyVdd task must not run outside a Sunshine session' },
    @{ TaskPath = '\'; TaskName = 'MMSet'; Reason = 'Ad-hoc monitor layout task can race Sunshine display prep' },
    @{ TaskPath = '\'; TaskName = 'MMSetRes'; Reason = 'Ad-hoc monitor layout task can race Sunshine display prep' },
    @{ TaskPath = '\'; TaskName = 'VddTryExtend'; Reason = 'Ad-hoc DisplaySwitch task can race Sunshine display prep' },
    @{ TaskPath = '\'; TaskName = 'VddTryExternal'; Reason = 'Ad-hoc DisplaySwitch task can race Sunshine display prep' }
)

$SunshineControlPorts = @(47989, 47984)

# These are consumer packages, not runtimes. WebView2, App Installer, UI.Xaml,
# VCLibs, Windows shell, Defender and Windows Update packages are intentionally
# absent from this list.
$ConsumerAppxPatterns = @(
    '^MicrosoftWindows\.Client\.WebExperience$',
    '^Microsoft\.BingWeather$',
    '^Microsoft\.BingNews$',
    '^Microsoft\.Clipchamp$',
    '^Clipchamp\.Clipchamp$',
    '^Microsoft\.Xbox',
    '^Microsoft\.GamingApp$',
    '^Microsoft\.Teams$',
    '^MSTeams$',
    '^Microsoft\.WindowsCommunicationsApps$',
    '^Microsoft\.MicrosoftOfficeHub$',
    '^Microsoft\.Office\.OneNote$',
    '^Microsoft\.Outlook',
    '^Microsoft\.People$',
    '^Microsoft\.Windows\.PeopleExperienceHost$',
    '^Microsoft\.WindowsMaps$',
    '^Microsoft\.Zune',
    '^Microsoft\.MicrosoftSolitaireCollection$',
    '^Microsoft\.GetHelp$',
    '^Microsoft\.WindowsFeedbackHub$',
    '^Microsoft\.YourPhone$',
    '^Microsoft\.3DViewer$',
    '^Microsoft\.MixedReality\.Portal$',
    '^Microsoft\.WindowsAlarms$',
    '^Microsoft\.WindowsCamera$',
    '^Microsoft\.WindowsSoundRecorder$'
)

function Write-Log {
    param([string]$Message)

    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $line
    try {
        $logDir = Split-Path -Parent $LogPath
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch {
        # Logging must never prevent a rollback or an audit.
    }
}

function Ensure-ParentDirectory {
    param([string]$Path)

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-ControlPath {
    $requiredServices = @('QEMU-GA', 'sshd')
    foreach ($name in $requiredServices) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $service -or $service.Status -ne 'Running') {
            throw "Control path is not healthy: $name is missing or not running"
        }
    }

    $sunshineTask = Get-ScheduledTask -TaskName 'SunshineUser' -ErrorAction SilentlyContinue
    if (-not $sunshineTask) {
        throw 'Control path is not healthy: SunshineUser scheduled task is missing'
    }

    $deadline = (Get-Date).AddSeconds($SunshineReadyTimeoutSeconds)
    $sunshineProcess = @()
    $listeners = @()
    while ((Get-Date) -lt $deadline) {
        $sunshineProcess = @(Get-Process -Name 'Sunshine' -ErrorAction SilentlyContinue)
        try {
            $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop |
                Where-Object { $SunshineControlPorts -contains [int]$_.LocalPort })
        } catch {
            throw "Control path is not healthy: cannot inspect Sunshine listeners: $($_.Exception.Message)"
        }

        $readyPorts = @($listeners | Select-Object -ExpandProperty LocalPort -Unique)
        if ($sunshineProcess.Count -gt 0 -and
            (@($SunshineControlPorts | Where-Object { $readyPorts -contains $_ }).Count -eq $SunshineControlPorts.Count)) {
            break
        }
        Start-Sleep -Seconds 1
    }

    if ($sunshineProcess.Count -eq 0) {
        throw 'Control path is not healthy: Sunshine interactive process is not running'
    }
    $readyPorts = @($listeners | Select-Object -ExpandProperty LocalPort -Unique)
    $missingPorts = @($SunshineControlPorts | Where-Object { $readyPorts -notcontains $_ })
    if ($missingPorts.Count -gt 0) {
        throw "Control path is not healthy: Sunshine listener(s) missing: $($missingPorts -join ',')"
    }

    $displays = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue)
    foreach ($pattern in @('Virtual Display Driver|VDD', 'Intel.*Arc', 'VirtIO|Red Hat')) {
        if (-not ($displays | Where-Object {
                $_.Status -eq 'OK' -and $_.FriendlyName -match $pattern
            })) {
            throw "Control path is not healthy: working display adapter matching '$pattern' is missing"
        }
    }
}

function Ensure-MemoryCompression {
    try {
        $agent = Get-MMAgent -ErrorAction Stop
    } catch {
        throw "Memory compression state is unavailable: $($_.Exception.Message)"
    }

    if (-not [bool]$agent.MemoryCompression) {
        Write-Log 'MemoryCompression was disabled; restoring it before continuing'
        try {
            Enable-MMAgent -MemoryCompression -ErrorAction Stop
        } catch {
            throw "Could not enable MemoryCompression: $($_.Exception.Message)"
        }
    }

    $verified = Get-MMAgent -ErrorAction Stop
    if (-not [bool]$verified.MemoryCompression) {
        throw 'MemoryCompression is still disabled after the restore attempt'
    }
    Write-Log 'MemoryCompression=True (required for the 6 GiB runtime profile)'
}

function Test-ProtectedService {
    param([string]$Name)

    foreach ($protected in $ProtectedServices) {
        if ($Name -ieq $protected) {
            return $true
        }
    }
    return $false
}

function Resolve-Policies {
    param([object[]]$Policies)

    $resolved = @{}
    foreach ($policy in $Policies) {
        $matches = @(Get-Service | Where-Object { $_.Name -like $policy.Pattern })
        foreach ($service in $matches) {
            if (Test-ProtectedService -Name $service.Name) {
                Write-Log "PROTECT $($service.Name) matched $($policy.Pattern)" | Out-Null
                continue
            }

            $key = $service.Name.ToLowerInvariant()
            if (-not $resolved.ContainsKey($key)) {
                $resolved[$key] = [pscustomobject]@{
                    Name = $service.Name
                    DisplayName = $service.DisplayName
                    StartupType = $policy.StartupType
                    Reason = $policy.Reason
                    Pattern = $policy.Pattern
                }
            }
        }
    }

    return @($resolved.Values | Sort-Object Name)
}

function Resolve-StartupEntries {
    param([object[]]$Policies)

    $resolved = @()
    foreach ($policy in $Policies) {
        if (-not (Test-Path -LiteralPath $policy.Path)) {
            continue
        }

        try {
            $properties = Get-ItemProperty -LiteralPath $policy.Path -ErrorAction Stop
            foreach ($property in $properties.PSObject.Properties) {
                if ($property.Name -like 'PS*' -or $property.Name -notmatch $policy.Pattern) {
                    continue
                }
                if ($null -eq $property.Value -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                    continue
                }
                $resolved += [pscustomobject]@{
                    Path = $policy.Path
                    Name = $property.Name
                    Value = [string]$property.Value
                    Reason = $policy.Reason
                }
            }
        } catch {
            Write-Log "WARN could not inspect startup path $($policy.Path): $($_.Exception.Message)" | Out-Null
        }
    }

    return @($resolved)
}

function Resolve-ScheduledTasks {
    param([object[]]$Policies)

    $resolved = @{}
    try {
        $tasks = @(Get-ScheduledTask -ErrorAction Stop)
    } catch {
        Write-Log "WARN could not enumerate scheduled tasks: $($_.Exception.Message)" | Out-Null
        return @()
    }

    foreach ($policy in $Policies) {
        foreach ($task in $tasks) {
            $pathMatches = ($policy.TaskPath -eq '*') -or ($task.TaskPath -eq $policy.TaskPath) -or ($task.TaskPath -like $policy.TaskPath)
            if (-not $pathMatches -or $task.TaskName -notlike $policy.TaskName) {
                continue
            }

            $key = '{0}|{1}' -f $task.TaskPath.ToLowerInvariant(), $task.TaskName.ToLowerInvariant()
            if (-not $resolved.ContainsKey($key)) {
                $resolved[$key] = [pscustomobject]@{
                    TaskPath = $task.TaskPath
                    TaskName = $task.TaskName
                    State = $task.State.ToString()
                    Reason = $policy.Reason
                }
            }
        }
    }

    return @($resolved.Values | Sort-Object TaskPath, TaskName)
}

function Test-ConsumerAppxName {
    param([string]$Name)

    foreach ($pattern in $ConsumerAppxPatterns) {
        if ($Name -match $pattern) {
            return $true
        }
    }
    return $false
}

function Resolve-ConsumerAppx {
    $resolved = @{}

    try {
        foreach ($package in @(Get-AppxPackage -AllUsers -ErrorAction Stop)) {
            if (-not (Test-ConsumerAppxName -Name $package.Name)) {
                continue
            }
            $key = 'installed|{0}' -f $package.PackageFullName.ToLowerInvariant()
            $resolved[$key] = [pscustomobject]@{
                Type = 'Installed'
                Name = $package.Name
                DisplayName = $package.Name
                PackageFullName = $package.PackageFullName
                PackageName = ''
                InstallLocation = [string]$package.InstallLocation
            }
        }
    } catch {
        Write-Log "WARN could not enumerate installed AppX packages: $($_.Exception.Message)" | Out-Null
    }

    try {
        foreach ($package in @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)) {
            if (-not (Test-ConsumerAppxName -Name $package.DisplayName)) {
                continue
            }
            $key = 'provisioned|{0}' -f $package.PackageName.ToLowerInvariant()
            $resolved[$key] = [pscustomobject]@{
                Type = 'Provisioned'
                Name = $package.DisplayName
                DisplayName = $package.DisplayName
                PackageFullName = ''
                PackageName = $package.PackageName
                InstallLocation = [string]$package.InstallLocation
            }
        }
    } catch {
        Write-Log "WARN could not enumerate provisioned AppX packages: $($_.Exception.Message)" | Out-Null
    }

    return @($resolved.Values | Sort-Object Type, Name, PackageFullName, PackageName)
}

function Get-ServiceSnapshot {
    param([string]$Name)

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) {
        return $null
    }

    $escapedName = $Name.Replace("'", "''")
    $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$escapedName'" -ErrorAction SilentlyContinue
    if (-not $cim) {
        return [pscustomobject]@{
            Name = $service.Name
            DisplayName = $service.DisplayName
            StartMode = $service.StartType.ToString()
            State = $service.Status.ToString()
            DelayedAutoStart = $false
        }
    }

    return [pscustomobject]@{
        Name = $cim.Name
        DisplayName = $cim.DisplayName
        StartMode = $cim.StartMode
        State = $cim.State
        DelayedAutoStart = [bool]$cim.DelayedAutoStart
    }
}

function Convert-StartMode {
    param([string]$StartMode)

    switch ($StartMode) {
        'Auto' { return 'Automatic' }
        'Automatic' { return 'Automatic' }
        'Manual' { return 'Manual' }
        'Disabled' { return 'Disabled' }
        default { return 'Manual' }
    }
}

function Read-Backup {
    if (-not (Test-Path -LiteralPath $BackupPath)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $BackupPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Could not parse backup file $BackupPath : $($_.Exception.Message)"
    }
}

function Save-Backup {
    param(
        [object[]]$Snapshots,
        [object[]]$StartupEntries,
        [object[]]$ScheduledTasks,
        [object[]]$AppxPackages
    )

    Ensure-ParentDirectory -Path $BackupPath
    $existing = Read-Backup
    $byName = @{}
    $byStartup = @{}
    $byTask = @{}
    $byAppx = @{}

    if ($existing -and $existing.Services) {
        foreach ($entry in @($existing.Services)) {
            $byName[$entry.Name.ToLowerInvariant()] = $entry
        }
    }
    if ($existing -and $existing.StartupEntries) {
        foreach ($entry in @($existing.StartupEntries)) {
            $key = '{0}|{1}' -f $entry.Path.ToLowerInvariant(), $entry.Name.ToLowerInvariant()
            $byStartup[$key] = $entry
        }
    }
    if ($existing -and $existing.ScheduledTasks) {
        foreach ($entry in @($existing.ScheduledTasks)) {
            $key = '{0}|{1}' -f $entry.TaskPath.ToLowerInvariant(), $entry.TaskName.ToLowerInvariant()
            $byTask[$key] = $entry
        }
    }
    if ($existing -and $existing.AppxPackages) {
        foreach ($entry in @($existing.AppxPackages)) {
            $identity = if ($entry.PackageFullName) { $entry.PackageFullName } else { $entry.PackageName }
            $key = '{0}|{1}' -f $entry.Type.ToLowerInvariant(), $identity.ToLowerInvariant()
            $byAppx[$key] = $entry
        }
    }
    foreach ($snapshot in @($Snapshots)) {
        if ($snapshot) {
            $key = $snapshot.Name.ToLowerInvariant()
            if (-not $byName.ContainsKey($key)) {
                $byName[$key] = $snapshot
            }
        }
    }
    foreach ($entry in @($StartupEntries)) {
        if ($entry) {
            $key = '{0}|{1}' -f $entry.Path.ToLowerInvariant(), $entry.Name.ToLowerInvariant()
            if (-not $byStartup.ContainsKey($key)) {
                $byStartup[$key] = $entry
            }
        }
    }
    foreach ($entry in @($ScheduledTasks)) {
        if ($entry) {
            $key = '{0}|{1}' -f $entry.TaskPath.ToLowerInvariant(), $entry.TaskName.ToLowerInvariant()
            if (-not $byTask.ContainsKey($key)) {
                $byTask[$key] = $entry
            }
        }
    }
    foreach ($entry in @($AppxPackages)) {
        if ($entry) {
            $identity = if ($entry.PackageFullName) { $entry.PackageFullName } else { $entry.PackageName }
            $key = '{0}|{1}' -f $entry.Type.ToLowerInvariant(), $identity.ToLowerInvariant()
            if (-not $byAppx.ContainsKey($key)) {
                $byAppx[$key] = $entry
            }
        }
    }

    $document = [pscustomobject]@{
        SchemaVersion = 1
        ComputerName = $env:COMPUTERNAME
        CreatedAt = if ($existing) { $existing.CreatedAt } else { (Get-Date).ToString('o') }
        UpdatedAt = (Get-Date).ToString('o')
        Services = @($byName.Values | Sort-Object Name)
        StartupEntries = @($byStartup.Values | Sort-Object Path, Name)
        ScheduledTasks = @($byTask.Values | Sort-Object TaskPath, TaskName)
        AppxPackages = @($byAppx.Values | Sort-Object Type, Name, PackageFullName, PackageName)
    }
    $document | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $BackupPath -Encoding UTF8
    Write-Log "BACKUP saved: $BackupPath ($($document.Services.Count) services, $($document.StartupEntries.Count) startup entries, $($document.ScheduledTasks.Count) tasks, $($document.AppxPackages.Count) AppX records)"
}

function Get-MemoryAudit {
    Write-Log '===== MEMORY AUDIT ====='
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $freeMb = [math]::Round($os.FreePhysicalMemory / 1024, 0)
    $totalMb = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
    Write-Log "RAM total=${totalMb}MB free=${freeMb}MB"

    try {
        $agent = Get-MMAgent -ErrorAction Stop
        Write-Log "MemoryCompression=$($agent.MemoryCompression)"
    } catch {
        Write-Log 'MemoryCompression status unavailable'
    }

    $top = @(Get-Process -ErrorAction SilentlyContinue |
        Sort-Object PrivateMemorySize64 -Descending |
        Select-Object -First 15 Name, Id,
            @{Name = 'PrivateMB'; Expression = { [math]::Round($_.PrivateMemorySize64 / 1MB) } },
            @{Name = 'WorkingSetMB'; Expression = { [math]::Round($_.WorkingSet64 / 1MB) } })
    if ($top.Count -gt 0) {
        Write-Output ($top | Format-Table -AutoSize | Out-String -Width 180)
    }

    $sunshine = @(Get-Process -Name 'Sunshine' -ErrorAction SilentlyContinue)
    Write-Log "Sunshine process count=$($sunshine.Count) (expected one interactive process)"
}

function Show-TargetAudit {
    param([object[]]$Targets)

    Write-Log '===== TARGET SERVICES ====='
    if (-not $Targets -or $Targets.Count -eq 0) {
        Write-Log 'No matching candidate services were found on this Windows build'
        return
    }

    $rows = foreach ($target in $Targets) {
        $service = Get-Service -Name $target.Name -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Name = $target.Name
            Status = if ($service) { $service.Status } else { 'Missing' }
            CurrentStart = if ($service) { $service.StartType } else { 'Missing' }
            DesiredStart = $target.StartupType
            Reason = $target.Reason
        }
    }
    Write-Output ($rows | Format-Table -Wrap -AutoSize | Out-String -Width 220)
}

function Show-StartupAudit {
    param([object[]]$Entries)

    Write-Log '===== STARTUP ENTRIES ====='
    if (-not $Entries -or $Entries.Count -eq 0) {
        Write-Log 'No matching vendor startup entries were found'
        return
    }

    $rows = foreach ($entry in $Entries) {
        [pscustomobject]@{
            Name = $entry.Name
            Path = $entry.Path
            Value = $entry.Value
            Reason = $entry.Reason
        }
    }
    Write-Output ($rows | Format-Table -Wrap -AutoSize | Out-String -Width 220)
}

function Show-TaskAudit {
    param([object[]]$Entries)

    Write-Log '===== TARGETED BACKGROUND TASKS ====='
    if (-not $Entries -or $Entries.Count -eq 0) {
        Write-Log 'No matching telemetry or consumer tasks were found'
        return
    }

    $rows = foreach ($entry in $Entries) {
        [pscustomobject]@{
            TaskPath = $entry.TaskPath
            TaskName = $entry.TaskName
            State = $entry.State
            Reason = $entry.Reason
        }
    }
    Write-Output ($rows | Format-Table -Wrap -AutoSize | Out-String -Width 220)
}

function Show-AppxAudit {
    param([object[]]$Entries)

    Write-Log '===== CONSUMER APPX ====='
    if (-not $Entries -or $Entries.Count -eq 0) {
        Write-Log 'No matching consumer AppX packages were found'
        return
    }

    $rows = foreach ($entry in $Entries) {
        [pscustomobject]@{
            Type = $entry.Type
            Name = $entry.Name
            Package = if ($entry.PackageFullName) { $entry.PackageFullName } else { $entry.PackageName }
        }
    }
    Write-Output ($rows | Format-Table -Wrap -AutoSize | Out-String -Width 220)
}

function Apply-ServicePolicy {
    param(
        [object[]]$Targets
    )

    foreach ($target in $Targets) {
        $service = Get-Service -Name $target.Name -ErrorAction SilentlyContinue
        if (-not $service) {
            continue
        }

        try {
            Set-Service -Name $target.Name -StartupType $target.StartupType -ErrorAction Stop
            Write-Log "SET $($target.Name) startup=$($target.StartupType) [$($target.Reason)]"

            if ($target.StartupType -eq 'Disabled' -and $service.Status -eq 'Running') {
                Stop-Service -Name $target.Name -ErrorAction Stop
                Write-Log "STOPPED $($target.Name)"
            }
        } catch {
            Write-Log "WARN $($target.Name) was not fully changed: $($_.Exception.Message)"
        }
    }
}

function Disable-StartupEntries {
    param(
        [object[]]$Entries,
        [string[]]$ProcessNames
    )

    foreach ($entry in $Entries) {
        try {
            Remove-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -ErrorAction Stop
            Write-Log "REMOVED startup $($entry.Name) from $($entry.Path) [$($entry.Reason)]"
        } catch {
            Write-Log "WARN could not remove startup $($entry.Name): $($_.Exception.Message)"
        }
    }

    $managedPathPattern = '\\Intel Graphics Software\\|\\Microsoft OneDrive\\|\\Microsoft\\OneDrive\\|\\Microsoft Office\\|\\Microsoft\\Teams\\|\\WindowsApps\\(Microsoft\.(Outlook|Teams)|MSTeams)|\\SystemApps\\MicrosoftWindows\.Client\.WebExperience'
    foreach ($processName in $ProcessNames) {
        $processes = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
        foreach ($process in $processes) {
            try {
                $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)" -ErrorAction SilentlyContinue
                if ($cim -and $cim.ExecutablePath -and
                    $cim.ExecutablePath -match $managedPathPattern) {
                    Stop-Process -Id $process.Id -Force -ErrorAction Stop
                    Write-Log "STOPPED managed process $($process.ProcessName) PID=$($process.Id)"
                } else {
                    Write-Log "SKIP process $($process.ProcessName) PID=$($process.Id); path was not a managed vendor/consumer path"
                }
            } catch {
                Write-Log "WARN could not stop managed process $($process.ProcessName) PID=$($process.Id): $($_.Exception.Message)"
            }
        }
    }
}

function Disable-ScheduledTaskEntries {
    param([object[]]$Entries)

    foreach ($entry in $Entries) {
        try {
            Disable-ScheduledTask -TaskPath $entry.TaskPath -TaskName $entry.TaskName -ErrorAction Stop | Out-Null
            if ($entry.State -eq 'Running') {
                Stop-ScheduledTask -TaskPath $entry.TaskPath -TaskName $entry.TaskName -ErrorAction SilentlyContinue
            }
            Write-Log "DISABLED task $($entry.TaskPath)$($entry.TaskName) [$($entry.Reason)]"
        } catch {
            Write-Log "WARN could not disable task $($entry.TaskPath)$($entry.TaskName): $($_.Exception.Message)"
        }
    }
}

function Remove-ConsumerAppxPackages {
    param([object[]]$Entries)

    foreach ($entry in @($Entries | Where-Object { $_.Type -eq 'Installed' })) {
        $isSystemApp = ($entry.InstallLocation -and
            $entry.InstallLocation.TrimEnd('\') -like "$env:windir\SystemApps*") -or
            $entry.Name -match '^(Microsoft\.Windows\.PeopleExperienceHost|Microsoft\.XboxGameCallableUI)$'
        if ($isSystemApp) {
            Write-Log "SKIP system-owned AppX $($entry.PackageFullName); SystemApps are part of Windows shell/runtime"
            continue
        }
        try {
            Remove-AppxPackage -Package $entry.PackageFullName -AllUsers -ErrorAction Stop
            Write-Log "REMOVED installed AppX $($entry.PackageFullName)"
        } catch {
            Write-Log "WARN could not remove installed AppX $($entry.PackageFullName): $($_.Exception.Message)"
        }
    }

    foreach ($entry in @($Entries | Where-Object { $_.Type -eq 'Provisioned' })) {
        $isSystemApp = ($entry.InstallLocation -and
            $entry.InstallLocation.TrimEnd('\') -like "$env:windir\SystemApps*") -or
            $entry.Name -match '^(Microsoft\.Windows\.PeopleExperienceHost|Microsoft\.XboxGameCallableUI)$'
        if ($isSystemApp) {
            Write-Log "SKIP system-owned provisioned AppX $($entry.PackageName); SystemApps are part of Windows shell/runtime"
            continue
        }
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $entry.PackageName -ErrorAction Stop | Out-Null
            Write-Log "REMOVED provisioned AppX $($entry.PackageName)"
        } catch {
            Write-Log "WARN could not remove provisioned AppX $($entry.PackageName): $($_.Exception.Message)"
        }
    }
}

function Restore-ScheduledTaskState {
    param([object]$Entry)

    try {
        if ($Entry.State -eq 'Disabled') {
            Disable-ScheduledTask -TaskPath $Entry.TaskPath -TaskName $Entry.TaskName -ErrorAction Stop | Out-Null
        } else {
            Enable-ScheduledTask -TaskPath $Entry.TaskPath -TaskName $Entry.TaskName -ErrorAction Stop | Out-Null
        }
        Write-Log "RESTORED task $($Entry.TaskPath)$($Entry.TaskName) state=$($Entry.State)"
    } catch {
        Write-Log "WARN rollback failed for task $($Entry.TaskPath)$($Entry.TaskName): $($_.Exception.Message)"
    }
}

function Restore-StartupEntry {
    param([object]$Entry)

    try {
        if (-not (Test-Path -LiteralPath $Entry.Path)) {
            New-Item -Path $Entry.Path -Force | Out-Null
        }
        New-ItemProperty -LiteralPath $Entry.Path -Name $Entry.Name -Value $Entry.Value -PropertyType String -Force | Out-Null
        Write-Log "RESTORED startup $($Entry.Name) in $($Entry.Path)"
    } catch {
        Write-Log "WARN rollback failed for startup $($Entry.Name): $($_.Exception.Message)"
    }
}

function Restore-ServiceState {
    param([object]$Entry)

    $service = Get-Service -Name $Entry.Name -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Log "SKIP rollback; service missing: $($Entry.Name)"
        return
    }

    try {
        $startupType = Convert-StartMode -StartMode $Entry.StartMode
        Set-Service -Name $Entry.Name -StartupType $startupType -ErrorAction Stop

        if ($startupType -eq 'Automatic') {
            if ([bool]$Entry.DelayedAutoStart) {
                & sc.exe config $Entry.Name start= delayed-auto | Out-Null
            } else {
                & sc.exe config $Entry.Name start= auto | Out-Null
            }
        }

        if ($Entry.State -eq 'Running' -and $service.Status -ne 'Running') {
            Start-Service -Name $Entry.Name -ErrorAction Stop
        } elseif ($Entry.State -eq 'Stopped' -and $service.Status -eq 'Running') {
            Stop-Service -Name $Entry.Name -ErrorAction Stop
        }
        Write-Log "RESTORED $($Entry.Name) startup=$startupType state=$($Entry.State)"
    } catch {
        Write-Log "WARN rollback failed for $($Entry.Name): $($_.Exception.Message)"
    }
}

Write-Log "===== lean-runtime.ps1 mode=$Mode aggressive=$IncludeAggressive remoteOff=$DisableUnusedRemote vendorStartup=$DisableVendorStartup consumerStartup=$DisableConsumerStartup appx=$RemoveConsumerAppx ====="

if ($Mode -ne 'Audit' -and -not (Test-IsAdministrator)) {
    throw 'Apply and Rollback must run from an elevated Administrator PowerShell session'
}

if ($RemoveConsumerAppx -and $Mode -eq 'Rollback') {
    Write-Log 'NOTE: AppX removal is not reversible by Rollback; reinstall from a Windows source if needed'
}

if ($Mode -eq 'Rollback') {
    $backup = Read-Backup
    if (-not $backup -or -not $backup.Services) {
        throw "No usable backup found at $BackupPath"
    }
    foreach ($entry in @($backup.Services)) {
        Restore-ServiceState -Entry $entry
    }
    if ($backup.StartupEntries) {
        foreach ($entry in @($backup.StartupEntries)) {
            Restore-StartupEntry -Entry $entry
        }
    }
    if ($backup.ScheduledTasks) {
        foreach ($entry in @($backup.ScheduledTasks)) {
            Restore-ScheduledTaskState -Entry $entry
        }
    }
    if ($backup.AppxPackages) {
        Write-Log "NOTE: $(@($backup.AppxPackages).Count) AppX records are documented in the backup but are not automatically restored"
    }
    Assert-ControlPath
    Get-MemoryAudit
    Write-Log 'Rollback finished'
    exit 0
}

$policies = @($ConservativePolicies)
if ($IncludeAggressive) {
    $policies += $AggressivePolicies
}
if ($DisableUnusedRemote) {
    $policies += $UnusedRemotePolicies
}

$targets = @(Resolve-Policies -Policies $policies)

$useVendorStartup = $DisableVendorStartup -or $IncludeAggressive
$useConsumerStartup = $DisableConsumerStartup -or $IncludeAggressive -or $RemoveConsumerAppx
$startupEntries = @()
$startupPolicies = @()
if ($useVendorStartup) {
    $startupPolicies += $VendorStartupPolicies
}
if ($useConsumerStartup) {
    $startupPolicies += $ConsumerStartupPolicies
}
if ($startupPolicies.Count -gt 0) {
    $startupEntries = @(Resolve-StartupEntries -Policies $startupPolicies)
}

$taskEntries = @()
if ($IncludeAggressive) {
    $taskEntries = @(Resolve-ScheduledTasks -Policies (@($TelemetryTaskPolicies) + @($ConsumerTaskPolicies) + @($DisplayConflictTaskPolicies)))
}

$appxEntries = @()
if ($IncludeAggressive -or $RemoveConsumerAppx) {
    $appxEntries = @(Resolve-ConsumerAppx)
}
Get-MemoryAudit
Show-TargetAudit -Targets $targets
if ($startupPolicies.Count -gt 0) {
    Show-StartupAudit -Entries $startupEntries
}
if ($IncludeAggressive) {
    Show-TaskAudit -Entries $taskEntries
}
if ($IncludeAggressive -or $RemoveConsumerAppx) {
    Show-AppxAudit -Entries $appxEntries
}

if ($Mode -eq 'Apply') {
    Assert-ControlPath
    Ensure-MemoryCompression
    $serviceSnapshots = @($targets | ForEach-Object { Get-ServiceSnapshot -Name $_.Name })
    Save-Backup -Snapshots $serviceSnapshots -StartupEntries $startupEntries -ScheduledTasks $taskEntries -AppxPackages $appxEntries
    Apply-ServicePolicy -Targets $targets
    if ($startupEntries.Count -gt 0) {
        $processNames = @()
        if ($useVendorStartup) {
            $processNames += $VendorProcessNames
        }
        if ($useConsumerStartup) {
            $processNames += $ConsumerProcessNames
        }
        Disable-StartupEntries -Entries $startupEntries -ProcessNames $processNames
    }
    if ($taskEntries.Count -gt 0) {
        Disable-ScheduledTaskEntries -Entries $taskEntries
    }
    if ($RemoveConsumerAppx -and $appxEntries.Count -gt 0) {
        Remove-ConsumerAppxPackages -Entries $appxEntries
    }
    Ensure-MemoryCompression
    Assert-ControlPath
    Write-Log 'Apply finished; reboot recommended before judging idle memory'
    Get-MemoryAudit
} else {
    Write-Log 'Audit only; no service state was changed'
}
