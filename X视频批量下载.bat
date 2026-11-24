@echo off
if not exist "%~dp0X视频批量下载.vbs" goto missing
wscript.exe "%~dp0X视频批量下载.vbs" %*
exit /b
:missing
echo 启动失败：请把 .vbs 与 .ps1 放在同一文件夹，或直接双击 .vbs 使用。
pause
