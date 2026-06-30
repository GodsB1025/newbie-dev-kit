@echo off
REM Dev environment setup launcher.
REM Double-click this file to run the PowerShell setup script as administrator.
title Dev Environment Setup
echo Starting dev environment setup...
echo (A UAC prompt will appear - click "Yes")
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-DevEnv.ps1"
