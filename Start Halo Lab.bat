@echo off
rem Starts the hardware monitor (CPU / GPU / NPU meters) in a minimized window, then opens Halo Lab.
start "Halo Lab hardware monitor" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0halo-monitor.ps1"
timeout /t 2 >nul
start "" "%~dp0Halo Lab.html"
