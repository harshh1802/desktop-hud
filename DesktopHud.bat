@echo off
rem Launches Desktop HUD hidden in the background.
start "" powershell -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0DesktopHud.ps1"
