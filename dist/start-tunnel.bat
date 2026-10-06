@echo off
rem csvpn (beta branch): start the tunnel; -NoSelfUpdate keeps this beta copy from being replaced by master
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0start-tunnel.ps1\" -NoSelfUpdate'"
