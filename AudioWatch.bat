@echo off
title Audio watch
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0AudioWatch.ps1" %*
pause
