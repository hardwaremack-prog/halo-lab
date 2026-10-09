@echo off
rem Starts Halo Lab in the background (orange ring icon near the clock) and opens it in your browser.
rem The Halo Lab desktop icon does the same thing.
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0halo-start.ps1"
