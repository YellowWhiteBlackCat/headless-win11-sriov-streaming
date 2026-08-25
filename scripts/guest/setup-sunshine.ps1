param(
    [string]$AdapterName = 'Intel(R) Arc(TM) B390 GPU',
    [string]$OutputName = '',
    [string]$DdOption = 'ensure_active'
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

$srcRoot = 'C:\Admin\Sunshine'
$destRoot = 'C:\Program Files\Sunshine'
$configDir = 'C:\ProgramData\Sunshine\config'
$logDir = 'C:\Admin\logs'
New-Item -ItemType Directory -Force -Path $logDir, $configDir | Out-Null
$logFile = Join-Path $logDir 'setup-sunshine.log'

function Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $line
    Add-Content -Path $logFile -Value $line -Encoding utf8
}

Log 'Stopping/removing old Sunshine service if present'
& "$env:SystemRoot\System32\sc.exe" stop SunshineService 2>&1 | Out-Null
& "$env:SystemRoot\System32\sc.exe" delete SunshineService 2>&1 | Out-Null

Log "Copying Sunshine from $srcRoot to $destRoot"
New-Item -ItemType Directory -Force -Path $destRoot | Out-Null
Copy-Item -Path (Join-Path $srcRoot '*') -Destination $destRoot -Recurse -Force
Copy-Item -Force (Join-Path $srcRoot 'config\sunshine.conf') (Join-Path $destRoot 'config\sunshine.conf')
Copy-Item -Force (Join-Path $srcRoot 'config\sunshine.conf') (Join-Path $configDir 'sunshine.conf')

function Set-ConfValue {
    param(
        [string]$Path,
        [string]$Key,
        [string]$Value
    )
    $text = Get-Content -Raw -Path $Path -Encoding UTF8
    if ($text -match "(?m)^\s*$([regex]::Escape($Key))\s*=.*$") {
        $text = $text -replace "(?m)^\s*$([regex]::Escape($Key))\s*=.*$", ("{0} = {1}" -f $Key, $Value)
    } else {
        $text = $text.TrimEnd() + "`n" + ("{0} = {1}" -f $Key, $Value) + "`n"
    }
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

foreach ($conf in @((Join-Path $destRoot 'config\sunshine.conf'), (Join-Path $configDir 'sunshine.conf'))) {
    Set-ConfValue -Path $conf -Key 'capture' -Value 'ddx'
    Set-ConfValue -Path $conf -Key 'encoder' -Value 'quicksync'
    Set-ConfValue -Path $conf -Key 'adapter_name' -Value $AdapterName
    if ($OutputName) {
        Set-ConfValue -Path $conf -Key 'output_name' -Value $OutputName
    }
    Set-ConfValue -Path $conf -Key 'dd_configuration_option' -Value $DdOption
    Set-ConfValue -Path $conf -Key 'dd_resolution_option' -Value 'auto'
    Set-ConfValue -Path $conf -Key 'dd_refresh_rate_option' -Value 'auto'
    Set-ConfValue -Path $conf -Key 'dd_config_revert_on_disconnect' -Value 'enabled'
    Set-ConfValue -Path $conf -Key 'dd_config_revert_delay' -Value '1500'
    Set-ConfValue -Path $conf -Key 'bind_address' -Value '0.0.0.0'
    Set-ConfValue -Path $conf -Key 'upnp' -Value 'disabled'
    Set-ConfValue -Path $conf -Key 'address_family' -Value 'ipv4'
    Log "Configured $conf"
}

Log 'Creating SunshineService'
$binPath = '"' + (Join-Path $destRoot 'tools\sunshinesvc.exe') + '"'
$create = & "$env:SystemRoot\System32\sc.exe" create SunshineService binPath= $binPath start= auto DisplayName= 'Sunshine Service' 2>&1 | Out-String
Log "sc create: $create"
& "$env:SystemRoot\System32\sc.exe" description SunshineService 'Sunshine is a self-hosted game stream host for Moonlight.' 2>&1 | Out-Null

Log 'Adding firewall rules'
New-NetFirewallRule -DisplayName 'Sunshine HTTP/S' -Direction Inbound -Action Allow -Protocol TCP -LocalPort '47984-48010' -ErrorAction SilentlyContinue | Out-Null
New-NetFirewallRule -DisplayName 'Sunshine Streaming UDP' -Direction Inbound -Action Allow -Protocol UDP -LocalPort '47998-48010' -ErrorAction SilentlyContinue | Out-Null

Log 'Starting SunshineService'
Start-Service -Name 'SunshineService' -ErrorAction Continue
Start-Sleep -Seconds 5
Get-Service -Name 'SunshineService' -ErrorAction SilentlyContinue | Format-List Status, StartType, Name, DisplayName | Out-String | Write-Output

Log 'Sunshine setup finished'
