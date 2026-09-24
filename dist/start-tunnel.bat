@echo off
rem csvpn: start the WireGuard tunnel on a fast path (asks for admin rights)
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0start-tunnel.ps1\"'"
