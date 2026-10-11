@echo off
chcp 936 >nul 2>nul
title Proxy Repair Tool - fix-proxy
cd /d "%~dp0"

echo.
echo  Proxy Repair Tool
echo  -----------------
echo  Starting, please wait...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix-proxy.ps1"

if errorlevel 1 (
  echo.
  echo  The script exited with an error.
  echo  Please send a screenshot of this window to the author.
  echo.
  pause
)
