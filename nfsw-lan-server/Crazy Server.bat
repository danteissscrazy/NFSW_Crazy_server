@echo off
REM ===================================================================
REM  CRAZY SERVER - abre el panel de control
REM
REM  Doble clic aqui y ya. No hay que instalar nada ni saber PowerShell.
REM  %~dp0 es la carpeta de este .bat, asi que funciona este donde este.
REM ===================================================================
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0scripts\panel.ps1"
