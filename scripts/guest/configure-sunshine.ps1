param(
    [string]$OutputName = '',
    [string]$DdOption = 'ensure_only_display',
    [int]$Av1Mode = 0,
    [int]$HevcMode = 0,
    [string]$QsvPreset = 'medium',
    [int]$QsvAsyncDepth = 1
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

if (-not $OutputName) {
    throw 'Provide -OutputName with the display device_id GUID (see get-sunshine-outputs.ps1 or dxgi-info.exe)'
}

$configs = @(
    'C:\Program Files\Sunshine\config\sunshine.conf',
    'C:\ProgramData\Sunshine\config\sunshine.conf'
)

function Set-ConfValue {
    param(
        [string]$Path,
        [string]$Key,
        [string]$Value
    )
    $text = Get-Content -Raw -Path $Path -Encoding UTF8
    $pattern = "(?m)^\s*" + [regex]::Escape($Key) + "\s*=.*$"
    $replacement = "{0} = {1}" -f $Key, $Value
    if ($text -match $pattern) {
        $text = $text -replace $pattern, $replacement
    } else {
        $text = $text.TrimEnd() + "`n" + $replacement + "`n"
    }
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Output "Set $Key = $Value in $Path"
}

foreach ($config in $configs) {
    Set-ConfValue -Path $config -Key 'output_name' -Value $OutputName
    Set-ConfValue -Path $config -Key 'dd_configuration_option' -Value $DdOption
    Set-ConfValue -Path $config -Key 'dd_resolution_option' -Value 'auto'
    Set-ConfValue -Path $config -Key 'dd_refresh_rate_option' -Value 'auto'
    Set-ConfValue -Path $config -Key 'dd_config_revert_on_disconnect' -Value 'enabled'
    Set-ConfValue -Path $config -Key 'dd_config_revert_delay' -Value '1500'
    Set-ConfValue -Path $config -Key 'av1_mode' -Value $Av1Mode
    Set-ConfValue -Path $config -Key 'hevc_mode' -Value $HevcMode
    Set-ConfValue -Path $config -Key 'qsv_preset' -Value $QsvPreset
    Set-ConfValue -Path $config -Key 'qsv_async_depth' -Value $QsvAsyncDepth
}

# Prefer the interactive scheduled task (production path); fall back to the
# legacy service if the task is not registered.
$task = Get-ScheduledTask -TaskName 'SunshineUser' -ErrorAction SilentlyContinue
if ($task) {
    Write-Output 'Restarting SunshineUser scheduled task'
    Stop-ScheduledTask -TaskName 'SunshineUser' -ErrorAction SilentlyContinue
    Get-Process -Name sunshine -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 3
    Start-ScheduledTask -TaskName 'SunshineUser'
} else {
    Write-Output 'Restarting SunshineService (legacy path)'
    Restart-Service -Name 'SunshineService' -Force -ErrorAction Continue
}
