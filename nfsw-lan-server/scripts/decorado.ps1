<#
.SYNOPSIS
    Cambia el decorado festivo de la ciudad para TODOS los jugadores, en caliente.

.DESCRIPTION
    NFS World lleva dentro cuatro decorados de temporada (luces y adornos por
    toda la ciudad) que el servidor activa con dos parametros. Este script los
    cambia y recarga los parametros del servidor sin reiniciar nada. Los
    jugadores lo ven al siguiente cambio de zona o al volver a entrar.

.PARAMETER Halloween
    Calabazas y luces naranjas. Ideal para una LAN de octubre.
.PARAMETER Navidad
    Arboles, luces y nieve en la ciudad. El mas espectacular.
.PARAMETER AnoNuevo
    Fuegos y luces de Nochevieja.
.PARAMETER Oktoberfest
    Decorado de la Oktoberfest.
.PARAMETER Normal
    Ciudad sin adornos (como viene de fabrica).

.EXAMPLE
    .\decorado.ps1 -Halloween
    .\decorado.ps1 -Navidad
    .\decorado.ps1 -Normal

.NOTES
    Los nombres exactos que reconoce el core (SceneryUtil.java): SCENERY_GROUP_NORMAL,
    _OKTOBERFEST, _HALLOWEEN, _CHRISTMAS y _NEWYEARS. Cualquier otro valor se ignora
    en silencio: por eso el "SCENERY_GROUP_NORMAL_DISABLE" que venia en la base de
    datos de la comunidad no hacia nada.
#>
[CmdletBinding()]
param(
    [switch] $Halloween,
    [switch] $Navidad,
    [switch] $AnoNuevo,
    [switch] $Oktoberfest,
    [switch] $Normal
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_comun.ps1')

$grupo = $null
if ($Halloween)   { $grupo = 'SCENERY_GROUP_HALLOWEEN';   $nombre = 'Halloween' }
if ($Navidad)     { $grupo = 'SCENERY_GROUP_CHRISTMAS';   $nombre = 'Navidad' }
if ($AnoNuevo)    { $grupo = 'SCENERY_GROUP_NEWYEARS';    $nombre = 'Ano Nuevo' }
if ($Oktoberfest) { $grupo = 'SCENERY_GROUP_OKTOBERFEST'; $nombre = 'Oktoberfest' }
if ($Normal)      { $grupo = 'SCENERY_GROUP_NORMAL';      $nombre = 'normal (sin adornos)' }

Write-Titulo 'Decorado de la ciudad'

if (-not $grupo) {
    # Sin parametro (por ejemplo desde el boton del panel): menu para elegir.
    $actual = Invoke-Mysql -Sql "SELECT value FROM parameter WHERE name='SERVER_INFO_ENABLED_SCENERY';" 2>$null
    Write-Host "    Ahora mismo: $actual" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '    1. Halloween      (calabazas y luces naranjas)'
    Write-Host '    2. Navidad        (arboles, luces y nieve: el mas vistoso)'
    Write-Host '    3. Ano Nuevo      (fuegos y luces de Nochevieja)'
    Write-Host '    4. Oktoberfest'
    Write-Host '    5. Normal         (ciudad sin adornos)'
    Write-Host ''
    $opcion = Read-Host '    Elige (1-5, Enter para salir)'
    switch ($opcion) {
        '1' { $grupo = 'SCENERY_GROUP_HALLOWEEN';   $nombre = 'Halloween' }
        '2' { $grupo = 'SCENERY_GROUP_CHRISTMAS';   $nombre = 'Navidad' }
        '3' { $grupo = 'SCENERY_GROUP_NEWYEARS';    $nombre = 'Ano Nuevo' }
        '4' { $grupo = 'SCENERY_GROUP_OKTOBERFEST'; $nombre = 'Oktoberfest' }
        '5' { $grupo = 'SCENERY_GROUP_NORMAL';      $nombre = 'normal (sin adornos)' }
        default { Write-Host ''; exit 0 }
    }
}

# El grupo "activado" manda; el "desactivado" es el que se apaga. Con NORMAL en
# los dos, la ciudad queda como de fabrica.
$desactivado = if ($grupo -eq 'SCENERY_GROUP_NORMAL') { 'SCENERY_GROUP_HALLOWEEN' } else { 'SCENERY_GROUP_NORMAL' }
Invoke-Mysql -Sql "UPDATE parameter SET value='$grupo' WHERE name='SERVER_INFO_ENABLED_SCENERY'; UPDATE parameter SET value='$desactivado' WHERE name='SERVER_INFO_DISABLED_SCENERY';" | Out-Null
Write-Ok "Decorado puesto a $nombre."

# Recarga en caliente por la API de administracion (misma que usa megafono.ps1).
& (Join-Path $PSScriptRoot 'megafono.ps1') -Recargar
Write-Registro "decorado.ps1 - $nombre"
Write-Host ''
Write-Host '    Los que ya estan dentro lo ven al cambiar de zona o al volver a entrar.' -ForegroundColor DarkGray
Write-Host ''
