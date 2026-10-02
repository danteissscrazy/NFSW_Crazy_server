<#
.SYNOPSIS
    Comprime la carpeta entera del servidor en un ZIP para llevarlo a otro PC.

.DESCRIPTION
    El servidor es portable: esta carpeta, tal cual, arranca en cualquier
    Windows. Este script la mete en un ZIP con dos precauciones que no hay
    que olvidar nunca:

      1. SOLO con el servidor parado. En db\data\ hay datos vivos de MySQL:
         una copia en caliente sale corrupta y el servidor destino no arranca.
         Si algo escucha en los puertos, se niega a empaquetar.
      2. Deja fuera lo que es de este equipo: logs\procesos.json (los PID),
         el Settings.ini del launcher (ruta de instalacion de ESTE equipo) y
         la carpeta GameFiles\ que a veces crea el launcher.

    Los logs viajan: son pequenos y ayudan a diagnosticar en el otro PC.
    gamefiles\ tambien viaja entero (el cliente de 2 GB): asi la web del
    otro PC ya reparte el juego sin copiar nada mas.

.PARAMETER Destino
    Ruta del ZIP a crear. Por defecto, en el Escritorio con la fecha.

.PARAMETER Rapido
    Comprime menos (el contenido ya va comprimido casi todo). Es lo normal.

.EXAMPLE
    .\empaquetar-servidor.ps1
.EXAMPLE
    .\empaquetar-servidor.ps1 -Destino D:\Crazy-Server.zip
#>

[CmdletBinding()]
param(
    [string] $Destino = (Join-Path ([Environment]::GetFolderPath('Desktop')) ('Crazy-Server-{0:yyyy-MM-dd}.zip' -f (Get-Date))),
    [switch] $Rapido = $true
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_comun.ps1')

$z7 = 'C:\Program Files\7-Zip\7z.exe'
if (-not (Test-Path -LiteralPath $z7)) { throw "Necesito 7-Zip en $z7" }

Write-Titulo 'Empaquetando el servidor entero'

# 1. Nada puede estar arrancado.
$vivos = @($SERVICIOS | Where-Object { Test-PuertoEscuchando -Puerto $_.Puerto -Protocolo $_.Protocolo })
if ($vivos.Count -gt 0) {
    Write-Fallo ('Hay servicios arrancados: {0}. Para el servidor con .\stop.ps1 y vuelve.' -f (($vivos | ForEach-Object { $_.Etiqueta }) -join ', '))
    exit 1
}
if (Get-Process mysqld -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$RAIZ*" }) {
    Write-Fallo 'Queda un mysqld de esta carpeta vivo sin puerto. Ciérralo (stop.ps1 -Forzar) y vuelve.'
    exit 1
}
Write-Ok 'Servidor parado: db\data se puede copiar sin riesgo.'

# 2. Comprimir a un temporal y comprobar antes de dar el ZIP por bueno.
$temporal = "$Destino.nuevo"
if (Test-Path -LiteralPath $temporal) { Remove-Item -LiteralPath $temporal -Force }
$nivel = if ($Rapido) { '-mx=1' } else { '-mx=5' }
$nombre = Split-Path -Leaf $RAIZ
Write-Paso "Comprimiendo $nombre (varios GB: entre dos y cinco minutos)..."
$t0 = Get-Date
$argumentos = @(
    'a', '-tzip', $nivel, $temporal, $nombre,
    "-x!$nombre\logs\procesos.json", "-x!$nombre\logs\estado.json",
    # Los logs de ESTE equipo no viajan (28-sep): en el otro PC confundirian el
    # diagnostico con arranques que no son suyos. logs\coches y logs\backups si.
    "-x!$nombre\logs\*.log", "-x!$nombre\logs\*.txt",
    "-x!$nombre\launcher\Settings.ini", "-x!$nombre\launcher\Settings.ini.anterior",
    "-xr!$nombre\launcher\GameFiles", "-xr!$nombre\launcher\.data", "-xr!$nombre\launcher\.links",
    '-xr!__pycache__', '-xr!*.pyc',
    '-bso0', '-bsp0'
)
Push-Location (Split-Path -Parent $RAIZ)
try { & $z7 @argumentos | Out-Null } finally { Pop-Location }
if ($LASTEXITCODE -ne 0) { throw "7-Zip fallo con codigo $LASTEXITCODE" }

Write-Paso 'Comprobando que el ZIP no salga corrupto...'
$prueba = & $z7 t $temporal
if (($prueba | Select-String 'Everything is Ok').Count -eq 0) {
    Remove-Item -LiteralPath $temporal -Force
    throw 'El ZIP no ha pasado la comprobacion de integridad.'
}
if (Test-Path -LiteralPath $Destino) { Remove-Item -LiteralPath $Destino -Force }
Move-Item -LiteralPath $temporal -Destination $Destino

$mb = (Get-Item -LiteralPath $Destino).Length / 1MB
$seg = ((Get-Date) - $t0).TotalSeconds
Write-Ok ('Servidor empaquetado: {0:N0} MB en {1:N0} s -> {2}' -f $mb, $seg, $Destino)
Write-Host ''
Write-Host '    En el otro PC: descomprimir donde sea (fuera de Archivos de programa),' -ForegroundColor DarkGray
Write-Host '    doble clic en "Crazy Server.bat", "Preparar PC" la primera vez y ARRANCAR.' -ForegroundColor DarkGray
Write-Host ''
Write-Registro ('empaquetar-servidor.ps1 - {0:N0} MB -> {1}' -f $mb, $Destino)
