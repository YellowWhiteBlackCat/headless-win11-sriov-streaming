$ErrorActionPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

Write-Output '--- SESSIONS ---'
quser 2>&1
query session 2>&1

Write-Output '--- SUNSHINE FILES ---'
Get-ChildItem 'C:\ProgramData\Sunshine' -Recurse -File -ErrorAction SilentlyContinue |
    Select-Object FullName, Length, LastWriteTime | Format-Table -AutoSize
Get-ChildItem 'C:\Users\vmadmin\AppData\Local\Sunshine' -Recurse -File -ErrorAction SilentlyContinue |
    Select-Object -First 40 FullName, Length, LastWriteTime | Format-Table -AutoSize

Write-Output '--- SUNSHINE LOG TAIL (all found) ---'
Get-ChildItem 'C:\ProgramData\Sunshine','C:\Users\vmadmin\AppData\Local\Sunshine' -Recurse -File -Filter '*.log' -ErrorAction SilentlyContinue |
    ForEach-Object {
        Write-Output "== $($_.FullName)"
        Get-Content -LiteralPath $_.FullName -Tail 150 -ErrorAction SilentlyContinue
    }

Write-Output '--- END ---'
