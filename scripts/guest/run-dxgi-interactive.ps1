$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()
& 'C:\Admin\Sunshine\tools\dxgi-info.exe' *> 'C:\Admin\logs\dxgi-interactive.txt'
Write-Output "Exit code: $LASTEXITCODE"
