@echo off
rem csvpn: "laggy right now" - move the running tunnel to another path without restarting it (asks for admin rights)
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0reroll.ps1\"'"
