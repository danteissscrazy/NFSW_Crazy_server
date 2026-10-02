@echo off
chcp 65001 >nul
title Anadir Crazy Server al launcher

echo.
echo   Anadiendo Crazy Server al launcher...
echo.

set "DESTINO=%APPDATA%\Soapbox Race World\Launcher"
if not exist "%DESTINO%" mkdir "%DESTINO%"

rem Copia de seguridad de la lista anterior, por si tenias otros servidores.
if exist "%DESTINO%\Servers-Custom.json" (
    copy /Y "%DESTINO%\Servers-Custom.json" "%DESTINO%\Servers-Custom.json.bak" >nul
)

copy /Y "%~dp0Servers-Custom.json" "%DESTINO%\Servers-Custom.json" >nul

if errorlevel 1 (
    echo   [X] No se pudo. Anade el servidor a mano con el boton "+" del launcher:
    echo       http://192.168.100.29:8080/Engine.svc
) else (
    echo   [OK] Listo. Abre el launcher y elige "Crazy Server" en el desplegable de arriba.
)
echo.
pause