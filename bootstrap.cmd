@echo off
if not exist C:\Windows\Setup\Scripts mkdir C:\Windows\Setup\Scripts
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap.ps1" *> C:\Windows\Setup\Scripts\bootstrap-console.log
exit /b 0
