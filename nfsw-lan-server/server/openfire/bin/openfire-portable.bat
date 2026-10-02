@echo off
REM ---------------------------------------------------------------------------
REM  Openfire portable (fork SoapboxRaceWorld) - NFS World LAN server
REM
REM  A diferencia de openfire.bat, este lanzador NO depende de un JAVA_HOME
REM  global: busca primero una JRE portable dentro del bundle y solo usa
REM  JAVA_HOME como ultimo recurso.
REM
REM  Orden de busqueda de Java:
REM    1) %OPENFIRE_HOME%\..\..\runtime\jre\bin\java.exe   (JRE portable del bundle)
REM    2) %OPENFIRE_HOME%\jre\bin\java.exe                 (JRE dentro de openfire\)
REM    3) %JAVA_HOME%\bin\java.exe
REM  Requiere Java 8 u 11. Java 17 NO sirve.
REM ---------------------------------------------------------------------------

SETLOCAL
set "OPENFIRE_HOME=%~dp0.."

set JAVA_BIN=
if exist "%OPENFIRE_HOME%\..\..\runtime\jre\bin\java.exe" set "JAVA_BIN=%OPENFIRE_HOME%\..\..\runtime\jre\bin\java.exe"
if "%JAVA_BIN%"=="" if exist "%OPENFIRE_HOME%\jre\bin\java.exe" set "JAVA_BIN=%OPENFIRE_HOME%\jre\bin\java.exe"
if "%JAVA_BIN%"=="" if not "%JAVA_HOME%"=="" if exist "%JAVA_HOME%\bin\java.exe" set "JAVA_BIN=%JAVA_HOME%\bin\java.exe"

if "%JAVA_BIN%"=="" goto javaerror

SET debug=
if "%1" == "-debug" SET debug=-Xdebug -Xint -Xnoagent -Xrunjdwp:transport=dt_socket,server=y,suspend=n,address=8000

"%JAVA_BIN%" %debug% -server -DopenfireHome="%OPENFIRE_HOME%" -Dlog4j.configurationFile="%OPENFIRE_HOME%\lib\log4j2.xml" -Dopenfire.lib.dir="%OPENFIRE_HOME%\lib" -jar "%OPENFIRE_HOME%\lib\startup.jar"
goto end

:javaerror
echo.
echo Error: no se ha encontrado ninguna JRE (ni portable ni JAVA_HOME). Openfire no arranca.
echo Coloca una JRE 8 u 11 en runtime\jre o define JAVA_HOME.
echo.

:end
ENDLOCAL
