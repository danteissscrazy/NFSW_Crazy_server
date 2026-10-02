<#
.SYNOPSIS
    Rehace el ZIP del cliente que descargan los jugadores, desde la carpeta del juego.

.DESCRIPTION
    Cada vez que se toca el cliente (un coche nuevo, un mod visual, el mapeo de
    mandos) hay que rehacer este ZIP, porque TODOS los jugadores tienen que tener
    EXACTAMENTE los mismos ficheros. Si uno conduce un coche que otro no tiene
    instalado, al segundo se le puede caer el juego.

    Deja fuera lo que es de este equipo y no debe viajar:
      NFSWO_COMMUNICATION_LOG.txt   el log del juego, llega a pesar 50 MB
      dinput8.dll.cliente-original  copia de seguridad del cargador
      .links                        lo crea el juego al arrancar y lo borra el
                                    launcher; si viaja, el juego se niega a
                                    arrancar con ".links file should not exist"
      Logs\, *.dmp, *.anterior      restos de pruebas

    SI incluye MODS\<hash>\ (vacia): es la carpeta que ModLoader exige y que
    normalmente crea el launcher. Yendo dentro, el juego arranca a la primera.

.PARAMETER Juego
    Carpeta del juego de la que partir. Por defecto ..\..\Juego

.PARAMETER Rapido
    Comprime menos y tarda la mitad. El ZIP crece un 3 por ciento.

.EXAMPLE
    .\empaquetar-cliente.ps1
#>

[CmdletBinding()]
param(
    [string] $Juego = (Join-Path $PSScriptRoot '..\..\Juego'),
    [switch] $Rapido
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_comun.ps1')

$z7 = 'C:\Program Files\7-Zip\7z.exe'
if (-not (Test-Path -LiteralPath $z7)) { throw "Necesito 7-Zip en $z7" }
if (-not (Test-Path -LiteralPath (Join-Path $Juego 'nfsw.exe'))) { throw "En $Juego no hay ningun nfsw.exe" }

$destino = Join-Path $PSScriptRoot '..\gamefiles\NFSW-Cliente.zip'
$temporal = "$destino.nuevo"

Write-Titulo 'Empaquetando el cliente para los jugadores'

# Aviso si falta algo importante: mejor enterarse antes de repartir 2 GB.
$obligatorios = @(
    @{ R = 'nfsw.exe';                          Q = 'el juego' },
    @{ R = 'ModLoader.asi';                     Q = 'mundo abierto y habilidades (ModNet)' },
    @{ R = 'dinput8.dll';                       Q = 'cargador de mods' },
    @{ R = 'global.ini';                        Q = 'ajustes del cargador' },
    @{ R = 'scripts\NFS_XtendedInput.asi';      Q = 'mandos' },
    @{ R = 'scripts\NFS_XtendedInput.ini';      Q = 'mapeo de teclas y mando' },
    # NFSWorldUnlimiter.asi vuelve a ser requisito (12-sep): sin el, el escaparate del
    # concesionario crashea al dibujar cualquier coche addon. Lo exigen los propios mods.
    @{ R = 'scripts\NFSWorldUnlimiter.asi';     Q = 'coches addon (obligatorio)' },
    @{ R = 'GLOBAL\attributes.bin';             Q = 'mods visuales' },
    @{ R = 'CARS\GlobalC.lzc';                  Q = 'fichas de los coches' },
    # Tandas 15 y 20 (27-sep): las matriculas propias del T-Sport y del 306 son
    # ficheros nuevos; sin ellos el coche sale sin matricula o cierra el juego.
    @{ R = 'GLOBAL\LicensePlates\134BA3EA.stp'; Q = 'matricula del T-Sport (tanda 15)' },
    @{ R = 'GLOBAL\LicensePlates\952CE55F.stp'; Q = 'matricula de Tux del 306 (tanda 20)' },
    @{ R = 'MANDOS - LEEME.txt';                Q = 'instrucciones de mandos para los jugadores' }
)
# Tanda 22 (27-sep): el mod de mandos va parcheado para que el clic derecho gire el
# coche en el garaje. Si el SHA no es este, se esta repartiendo el .asi del autor.
$asiParcheado = 'FB09E333D84DEE50095440752E78A518C7524A6443CAC54B5C876ADF9427C7F8'
$asi = Join-Path $Juego 'scripts\NFS_XtendedInput.asi'
if ((Test-Path -LiteralPath $asi) -and (Get-FileHash -LiteralPath $asi).Hash -ne $asiParcheado) {
    Write-Aviso 'scripts\NFS_XtendedInput.asi NO es el parcheado de la tanda 22 (sin giro con el raton).'
}
$faltan = @()
foreach ($o in $obligatorios) {
    if (-not (Test-Path -LiteralPath (Join-Path $Juego $o.R))) { $faltan += "$($o.R)  ($($o.Q))" }
}
if ($faltan.Count -gt 0) {
    Write-Aviso 'Faltan piezas en la carpeta del juego:'
    $faltan | ForEach-Object { Write-Host "       $_" -ForegroundColor Yellow }
    Write-Host ''
}

# La carpeta que ModLoader exige. El nombre es el MD5 de MODDING_SERVER_ID.
$idServidor = (Invoke-Mysql -Sql "SELECT value FROM parameter WHERE name = 'MODDING_SERVER_ID';") -join ''
if ($idServidor) {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $hash = (($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($idServidor.Trim())) |
                  ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $md5.Dispose() }
    $carpeta = Join-Path $Juego "MODS\$hash"
    if (-not (Test-Path -LiteralPath $carpeta)) { New-Item -ItemType Directory -Path $carpeta -Force | Out-Null }
    Write-Ok "Carpeta de ModNet lista: MODS\$hash  (servidor '$($idServidor.Trim())')"
}

# El .links no debe viajar NUNCA.
$links = Join-Path $Juego '.links'
if (Test-Path -LiteralPath $links) { Remove-Item -LiteralPath $links -Force; Write-Ok '.links quitado de la carpeta del juego.' }

if (Test-Path -LiteralPath $temporal) { Remove-Item -LiteralPath $temporal -Force }

$nivel = if ($Rapido) { '-mx=1' } else { '-mx=3' }
Write-Paso 'Comprimiendo (tarda entre uno y tres minutos)...'
$t0 = Get-Date
$argumentos = @(
    'a', '-tzip', $nivel, $temporal, '*',
    '-x!NFSWO_COMMUNICATION_LOG.txt', '-x!dinput8.dll.cliente-original',
    # Un ZIP del cliente dentro de la carpeta del cliente (pasa al descargarlo
    # ahi mismo) y los .asi apagados a mano con .off no deben viajar.
    '-x!NFSW-Cliente.zip', '-xr!*.off', '-xr!*.tanda7',
    '-xr!*.recortado-*', '-xr!*.v1-autor-*', '-xr!*.dmp', '-xr!*.anterior',
    '-xr!Logs', '-xr!.data', '-xr!.links',
    # Los volcados de fallo se colaron en el ZIP del 7 de septiembre: los .dmp
    # ya se excluian, pero los .txt que los acompanan no.
    '-xr!SBRCrashDump_*.txt',
    # Respaldos que se dejan al lado del fichero bueno mientras se depura, y
    # los .asi apagados a proposito (renombrados a .apagado por controles.ps1).
    '-xr!*.antes-*', '-xr!*.plantilla-autor-*', '-xr!*.escritor-viejo', '-xr!*.de-serie',
    '-xr!*.apagado', '-xr!*.mio-limpio', '-xr!*.autor-intacto', '-xr!*.roto-*', '-xr!*.prueba-mando',
    '-xr!*.HUECO-*', '-xr!*.sano-*', '-xr!*.respaldo-prueba', '-xr!*.antes-arranque-B',
    # Copias de seguridad de los coches sustituidos y de la musica original: no se cargan.
    '-xr!*.bak', '-xr!Music-original',
    '-bso0', '-bsp0'
)
Push-Location $Juego
try { & $z7 @argumentos | Out-Null } finally { Pop-Location }
if ($LASTEXITCODE -ne 0) { throw "7-Zip fallo con codigo $LASTEXITCODE" }

Write-Paso 'Comprobando que el ZIP no salga corrupto...'
$prueba = & $z7 t $temporal
if (($prueba | Select-String 'Everything is Ok').Count -eq 0) {
    Remove-Item -LiteralPath $temporal -Force
    throw 'El ZIP no ha pasado la comprobacion de integridad. No se sustituye el bueno.'
}

if (Test-Path -LiteralPath $destino) { Remove-Item -LiteralPath $destino -Force }
Move-Item -LiteralPath $temporal -Destination $destino

$mb = (Get-Item -LiteralPath $destino).Length / 1MB
$seg = ((Get-Date) - $t0).TotalSeconds
Write-Ok ('Cliente empaquetado: {0:N0} MB en {1:N0} s' -f $mb, $seg)
Write-Host ''
Write-Host '    Los jugadores tienen que volver a descargarlo de la web y' -ForegroundColor DarkGray
Write-Host '    descomprimirlo ENCIMA de su carpeta del juego, sobrescribiendo.' -ForegroundColor DarkGray
Write-Host ''
Write-Registro ('empaquetar-cliente.ps1 - {0:N0} MB desde {1}' -f $mb, $Juego)
