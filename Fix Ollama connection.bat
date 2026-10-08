@echo off
title Halo Lab - Fix Ollama connection
echo Allowing Halo Lab to talk to Ollama...
setx OLLAMA_ORIGINS "*" >nul
echo Restarting Ollama...
taskkill /f /im "ollama app.exe" >nul 2>&1
taskkill /f /im ollama.exe >nul 2>&1
timeout /t 2 >nul
if exist "%LOCALAPPDATA%\Programs\Ollama\ollama app.exe" (
  start "" "%LOCALAPPDATA%\Programs\Ollama\ollama app.exe"
  echo Done. Ollama is starting again. Reload Halo Lab in a few seconds.
) else (
  echo Done. Please start Ollama from the Start menu, then reload Halo Lab.
)
pause
