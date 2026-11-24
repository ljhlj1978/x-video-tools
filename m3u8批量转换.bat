@echo off
if not exist "%~dp0m3u8批量转换.vbs" goto missing
wscript.exe "%~dp0m3u8批量转换.vbs" %*
exit /b
:missing
echo 启动失败：请把 .vbs 与 .ps1 放在同一文件夹，或直接双击 .vbs 使用。
pause
