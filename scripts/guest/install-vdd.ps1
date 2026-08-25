param(
    [string]$VddDir = 'C:\Admin\VDD'
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()
$logDir = 'C:\Admin\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'install-vdd.log'

function Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $line
    Add-Content -Path $logFile -Value $line -Encoding utf8
}

Log "Starting VDD install from $VddDir"

$inf = Get-ChildItem -Path $VddDir -Filter 'MttVDD.inf' -Recurse -File -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $inf) {
    throw "MttVDD.inf not found under $VddDir (look for the extracted VirtualDisplayDriver driver package)"
}
$infDir = $inf.DirectoryName
Log "Using driver package at $infDir"

$settingsDir = 'C:\VirtualDisplayDriver'
New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null
$settingsSrc = Join-Path $infDir 'vdd_settings.xml'
if (-not (Test-Path -LiteralPath $settingsSrc)) {
    $settingsSrc = Join-Path $VddDir 'vdd_settings.xml'
}
if (-not (Test-Path -LiteralPath $settingsSrc)) {
    throw "vdd_settings.xml not found next to MttVDD.inf or in $VddDir"
}
Copy-Item -Force $settingsSrc (Join-Path $settingsDir 'vdd_settings.xml')
Log "Copied vdd_settings.xml to $settingsDir"

$existing = pnputil /enum-drivers | Out-String
if ($existing -match 'MttVDD\.inf') {
    Log 'MttVDD.inf already in driver store; deleting and reinstalling cleanly'
    $storeLine = ($existing -split "`r?`n" | Where-Object { $_ -match 'MttVDD\.inf' } | Select-Object -First 1)
    # Published name is the line before "Original Name", so search backwards for Published Name.
    $lines = $existing -split "`r?`n"
    $pub = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'MttVDD\.inf') {
            for ($j = $i - 1; $j -ge 0; $j--) {
                if ($lines[$j] -match 'Published Name:\s*(\S+)') {
                    $pub = $Matches[1]
                    break
                }
            }
            break
        }
    }
    if ($pub) {
        Log "Removing old package $pub"
        pnputil /delete-driver $pub /force /uninstall | Out-String | Write-Output
    }
}

$installOut = pnputil /add-driver $inf.FullName /install 2>&1 | Out-String
Log "pnputil output: $installOut"

Start-Sleep -Seconds 8

$devices = Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object {
        $_.FriendlyName -match 'Virtual Display Driver|VDD' -or
        $_.InstanceId -like 'ROOT\DISPLAY*'
    }

if ($devices) {
    $devices | Format-Table Status, Class, FriendlyName, InstanceId -AutoSize | Out-String -Width 260 | Write-Output
    Log 'VDD device(s) found'
} else {
    Log 'WARNING: no VDD device found after install'
}

Log 'VDD install finished'
