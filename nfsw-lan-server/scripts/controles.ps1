<#
.SYNOPSIS
    Interruptores para aislar por que el coche no responde a los controles.

.DESCRIPTION
    Dos cosas pueden romper el manejo del coche sin tocar los menus: el mod de
    mandos (NFS_XtendedInput.asi, que se mete entre el juego y el teclado/mando)
    y los ficheros de fisicas modificados (GLOBAL\*.bin). Este script apaga y
    enciende cada uno por separado para probarlos en un minuto.

    Prueba recomendada, en este orden:
      1. .\controles.ps1 -SinMandos      -> arranca el juego, ¿se puede conducir?
         Si SI: el culpable es XtendedInput.  .\controles.ps1 -ConMandos lo devuelve.
      2. .\controles.ps1 -BinsOriginales -> ¿se puede conducir?
         Si SI: el culpable esta en los mods de VltEd.  .\controles.ps1 -BinsMods los devuelve.

.PARAMETER Juego
    Carpeta del juego sobre la que actuar. Por defecto usa la carpeta MAESTRA del
    proyecto (..\Juego), que NO es desde donde se juega. La instalacion real del
    launcher esta en D:\NfS World Lan\Cliente, asi que para probar de verdad hay
    que pasarsela:
        .\controles.ps1 -Juego 'D:\NfS World Lan\Cliente' -Estado

.PARAMETER Estado
    Muestra que hay activo ahora mismo.
#>
[CmdletBinding()]
param(
    [string] $Juego,
    [switch] $SinMandos,
    [switch] $ConMandos,
    [switch] $BinsOriginales,
    [switch] $BinsMods,
    [switch] $Estado
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_comun.ps1')

if ($Juego) {
    $juego = $Juego
} else {
    $juego = Join-Path $RAIZ '..\Juego'
    if (-not (Test-Path (Join-Path $juego 'nfsw.exe'))) { $juego = Join-Path $DIR_GAMEFILES '' }
}
$juego = (Resolve-Path $juego).Path
Write-Host "    Carpeta: $juego" -ForegroundColor DarkGray
$asi     = Join-Path $juego 'scripts\NFS_XtendedInput.asi'
$asiOff  = "$asi.apagado"
$global  = Join-Path $juego 'GLOBAL'
$orig    = Join-Path $RAIZ '..\_build\vlt-original'
$mods    = Join-Path $RAIZ '..\_build\vlt-sesion\variante-A'
$bins    = 'attributes.bin', 'commerce.bin', 'FE_ATTRIB.bin'

function Estado-Actual {
    $mandos = if (Test-Path $asi) { 'ACTIVO' } elseif (Test-Path $asiOff) { 'apagado' } else { 'no instalado' }
    $h = (Get-FileHash (Join-Path $global 'attributes.bin') -Algorithm SHA1).Hash
    $ho = (Get-FileHash (Join-Path $orig 'attributes.bin') -Algorithm SHA1).Hash
    $binsEstado = if ($h -eq $ho) { 'ORIGINALES' } else { 'con mods' }
    Write-Host "    Mod de mandos (XtendedInput): $mandos" -ForegroundColor DarkGray
    Write-Host "    Ficheros GLOBAL:              $binsEstado" -ForegroundColor DarkGray
    Write-Host ''
}

Write-Titulo 'Controles del coche'
if (Get-Process -Name nfsw -ErrorAction SilentlyContinue) {
    Write-Aviso 'El juego esta abierto: cierralo antes de cambiar nada.'
}

if ($SinMandos) {
    if (Test-Path $asi) { Rename-Item $asi (Split-Path $asiOff -Leaf); Write-Ok 'XtendedInput apagado (renombrado a .apagado).' }
    else { Write-Aviso 'XtendedInput ya estaba apagado.' }
}
if ($ConMandos) {
    if (Test-Path $asiOff) { Rename-Item $asiOff (Split-Path $asi -Leaf); Write-Ok 'XtendedInput encendido.' }
    else { Write-Aviso 'XtendedInput ya estaba encendido.' }
}
if ($BinsOriginales) {
    foreach ($b in $bins) {
        $src = Join-Path $orig $b; if (-not (Test-Path $src)) { $src = Join-Path $orig $b.ToLower() }
        Copy-Item $src (Join-Path $global $b) -Force
    }
    Write-Ok 'GLOBAL con los ficheros ORIGINALES del juego.'
}
if ($BinsMods) {
    foreach ($b in $bins) { Copy-Item (Join-Path $mods $b) (Join-Path $global $b) -Force }
    Write-Ok 'GLOBAL con los mods (variante A).'
}
Estado-Actual
if (-not ($SinMandos -or $ConMandos -or $BinsOriginales -or $BinsMods)) {
    Write-Host '    Uso: .\controles.ps1 -SinMandos | -ConMandos | -BinsOriginales | -BinsMods' -ForegroundColor DarkGray
    Write-Host ''
}
