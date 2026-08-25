$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

$apps = @(
    @{ Name = 'Google Chrome'; Path = 'C:\Program Files\Google\Chrome\Application\chrome.exe' },
    @{ Name = '7-Zip'; Path = 'C:\Program Files\7-Zip\7z.exe' },
    @{ Name = 'Notepad++'; Path = 'C:\Program Files\Notepad++\notepad++.exe' },
    @{ Name = 'Git'; Path = 'C:\Program Files\Git\cmd\git.exe' }
)

foreach ($app in $apps) {
    if (Test-Path $app.Path) {
        Write-Output ("APP OK {0}`t{1}" -f $app.Name, $app.Path)
    } else {
        Write-Output ("APP MISSING {0}`t{1}" -f $app.Name, $app.Path)
    }
}

$winget = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
if (Test-Path $winget) {
    Write-Output ("APP OK winget`t{0}" -f $winget)
    & $winget --version 2>&1 | ForEach-Object { Write-Output ("WINGET {0}" -f $_) }
} else {
    Write-Output 'APP MISSING winget'
}
