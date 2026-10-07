@echo off
rem csvpn: show the start-tunnel / monitor screens with fake data (no admin, touches nothing)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-tunnel.ps1" -Preview
