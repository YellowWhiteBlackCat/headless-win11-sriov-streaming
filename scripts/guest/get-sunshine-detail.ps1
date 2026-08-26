$ErrorActionPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

Write-Output '--- SUNSHINE CONF ---'
Get-Content 'C:\ProgramData\Sunshine\config\sunshine.conf'

Write-Output '--- SUNSHINE PROCESS ---'
Get-CimInstance Win32_Process -Filter "Name='Sunshine.exe'" |
    Select-Object ProcessId, ParentProcessId, ExecutablePath, CommandLine, @{n='Started'; e={$_.CreationDate}} |
    Format-List

Write-Output '--- SUNSHINE TASK ---'
schtasks /query /tn SunshineUser /fo LIST /v | Select-String -Pattern 'TaskName|Status|Last Run Time|Last Result|Run As User|Logon Mode'

Write-Output '--- ANY RECENT SUNSHINE FILES ---'
Get-ChildItem 'C:\Program Files\Sunshine' -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-2) } |
    Select-Object -First 60 FullName, Length, LastWriteTime | Format-Table -AutoSize

Write-Output '--- END ---'
