@echo off
:: BreakTime - Smart Break Reminder
:: Launches BreakTime.ps1 in STA mode with hidden console
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0BreakTime.ps1"
