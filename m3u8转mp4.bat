@echo off
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0m3u8_to_mp4.ps1" %*
echo.
pause
