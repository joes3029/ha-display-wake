@echo off
:: ha-display-wake launcher for Windows
:: Double-click this file to run or set up ha-display-wake.
:: Pass --setup to reconfigure: ha-display-wake.bat --setup

powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0ha-display-wake.ps1" %*
