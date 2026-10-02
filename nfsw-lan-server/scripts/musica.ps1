<#
.SYNOPSIS
    Cambia la banda sonora del juego por la que tu quieras.

.DESCRIPTION
    NFS World guarda la musica en un formato propio de EA (parejas .snr + .sns).
    Este script convierte tus MP3 a ese formato y los coloca con los nombres
    que el juego espera, asi que no hay que tocar nada por dentro: el juego
    sigue pidiendo "hero" y "race_01", y suena lo que tu hayas puesto ahi.

    Sirve para cualquier musica: la banda sonora de Underground 2, la de Most
    Wanted, eurobeat de Initial D o lo que se os ocurra.

    Las 17 pistas del juego, y cuando suena cada una:

      hero                  mundo abierto, la que entra cuando aceleras
      freeroam_04_loopable  mundo abierto, la de fondo
      safehouse             garaje y menus
      race_01 .. race_05    carreras
      dragrace_*            arrancones (6 pistas)
      postrace              pantalla de resultados
      meetingplacevalentinesday / racechristmas   variantes de temporada

.PARAMETER Origen
    Carpeta con tus MP3. Se reparten por orden alfabetico entre las pistas
    que elijas.

.PARAMETER Pistas
    Que pistas sustituir. Por defecto 'principales' (las 8 que mas se oyen).
    'todas' sustituye las 17. Tambien acepta nombres sueltos.

.PARAMETER Juego
    Carpeta del juego. Por defecto la que hay en gamefiles\ o la del proyecto.

.PARAMETER Restaurar
    Deja la musica original tal y como estaba.

.EXAMPLE
    .\musica.ps1 -Origen "E:\Multimedia\Musica\Need for speed underground 2"

.EXAMPLE
    .\musica.ps1 -Origen "D:\Eurobeat" -Pistas todas

.EXAMPLE
    .\musica.ps1 -Restaurar

.NOTES
    Hace copia de seguridad de la musica original la primera vez, asi que
    siempre se puede volver atras.

    GOTCHA IMPORTANTE que costo encontrar: el codificador es de 2010 y falla
    EN SILENCIO con los MP3 que llevan etiqueta ID3 (casi todos los
    descargados). Genera la cabecera pero deja el audio a 0 bytes, sin dar
    ningun error. Este script se la quita antes de convertir.
#>

[CmdletBinding(DefaultParameterSetName = 'Convertir')]
param(
    [Parameter(ParameterSetName = 'Convertir', Mandatory, Position = 0)]
    [string]   $Origen,
    [Parameter(ParameterSetName = 'Convertir')]
    [string[]] $Pistas = @('principales'),
    [string]   $Juego,
    [Parameter(ParameterSetName = 'Restaurar')]
    [switch]   $Restaurar
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_comun.ps1')

# Las 8 que de verdad se oyen en una partida normal.
$PRINCIPALES = @('hero', 'freeroam_04_loopable', 'safehouse',
                 'race_01', 'race_02', 'race_03', 'race_04', 'race_05')

$TODAS = $PRINCIPALES + @('dragrace_02_1', 'dragrace_02_2', 'dragrace_03',
                          'dragrace_05', 'dragrace_extreme', 'dragrace_headbanger',
                          'postrace', 'meetingplacevalentinesday', 'racechristmas')


function Get-CarpetaJuego {
    if ($Juego -and (Test-Path (Join-Path $Juego 'nfsw.exe'))) { return $Juego }
    foreach ($c in @((Join-Path $DIR_GAMEFILES 'nfsw.exe'),
                     (Join-Path $RAIZ '..\Juego\nfsw.exe'))) {
        if (Test-Path $c) { return (Split-Path $c -Parent) }
    }
    return $null
}

function Remove-EtiquetasMp3 {
    <#
    .SYNOPSIS
        Copia un MP3 quitandole las etiquetas ID3 del principio y del final.
    .DESCRIPTION
        Sin esto el codificador genera un fichero de audio VACIO y no avisa.
    #>
    param([Parameter(Mandatory)][string] $Entrada,
          [Parameter(Mandatory)][string] $Salida)

    $b = [System.IO.File]::ReadAllBytes($Entrada)
    $ini = 0
    if ($b.Length -gt 10 -and $b[0] -eq 0x49 -and $b[1] -eq 0x44 -and $b[2] -eq 0x33) {
        # El tamano de ID3v2 son 4 bytes de 7 bits (sincsafe).
        $ini = 10 + (($b[6] -band 0x7f) -shl 21) + (($b[7] -band 0x7f) -shl 14) +
                    (($b[8] -band 0x7f) -shl 7)  +  ($b[9] -band 0x7f)
    }
    $fin = $b.Length
    if ($fin -gt 128 -and $b[$fin-128] -eq 0x54 -and $b[$fin-127] -eq 0x41 -and $b[$fin-126] -eq 0x47) {
        $fin -= 128   # ID3v1 al final
    }
    if ($ini -ge $fin) { throw 'El MP3 parece vacio o corrupto.' }

    $ms = [System.IO.File]::OpenWrite($Salida)
    try { $ms.Write($b, $ini, $fin - $ini) } finally { $ms.Dispose() }
}


# =====================================================================
$carpetaJuego = Get-CarpetaJuego
if (-not $carpetaJuego) {
    Write-Fallo 'No encuentro la carpeta del juego (la que tiene nfsw.exe).'
    Write-Host '       Indicala con:  .\musica.ps1 -Juego "D:\ruta\al\juego" ...' -ForegroundColor Red
    exit 1
}
$dirMusica = Join-Path $carpetaJuego 'Sound\Music'
$dirCopia  = Join-Path $carpetaJuego 'Sound\Music-original'


# =====================================================================
#  RESTAURAR
# =====================================================================
if ($Restaurar) {
    Write-Titulo 'Restaurando la musica original'
    if (-not (Test-Path $dirCopia)) {
        Write-Aviso 'No hay copia de seguridad: la musica ya es la original.'
        Write-Host ''
        exit 0
    }
    Get-ChildItem $dirCopia -File | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $dirMusica $_.Name) -Force
    }
    Write-Ok 'Musica original restaurada.'
    Write-Registro 'musica.ps1 - restaurada la original'
    Write-Host ''
    exit 0
}


# =====================================================================
#  CONVERTIR
# =====================================================================
Write-Titulo 'Cambiando la banda sonora'

$codificador = Join-Path $RAIZ 'runtime\ealayer3\ealayer3.exe'
if (-not (Test-Path $codificador)) { $codificador = 'C:\Tools\ealayer3\ealayer3.exe' }
if (-not (Test-Path $codificador)) {
    Write-Fallo 'Falta el codificador (ealayer3.exe).'
    Write-Host '       Deberia estar en runtime\ealayer3\. Descargalo de:' -ForegroundColor Red
    Write-Host '       https://github.com/driftyz700/ealayer3-nfsw/releases' -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $Origen)) { Write-Fallo "No encuentro la carpeta $Origen"; exit 1 }

$mp3 = @(Get-ChildItem $Origen -Filter *.mp3 -File | Sort-Object Name)
if ($mp3.Count -eq 0) { Write-Fallo "No hay ningun MP3 en $Origen"; exit 1 }

# Que pistas tocamos
$objetivo = switch -Regex ($Pistas -join ',') {
    'todas'       { $TODAS }
    'principales' { $PRINCIPALES }
    default       { $Pistas }
}
$objetivo = @($objetivo | Where-Object { Test-Path (Join-Path $dirMusica "$_.snr") })

Write-Host ''
Write-Host "    Juego    $carpetaJuego" -ForegroundColor DarkGray
Write-Host "    Musica   $($mp3.Count) MP3 en $Origen" -ForegroundColor DarkGray
Write-Host "    Pistas   $($objetivo.Count) a sustituir" -ForegroundColor DarkGray
Write-Host ''

# Copia de seguridad, solo la primera vez.
if (-not (Test-Path $dirCopia)) {
    Write-Paso 'Guardando la musica original (solo se hace una vez)...'
    New-Item -ItemType Directory -Path $dirCopia -Force | Out-Null
    Get-ChildItem $dirMusica -File | ForEach-Object { Copy-Item $_.FullName $dirCopia -Force }
    Write-Ok "Original a salvo en Sound\Music-original"
} else {
    Write-Ok 'La musica original ya estaba guardada.'
}

$temporal = Join-Path $env:TEMP "nfsw-musica-$PID"
New-Item -ItemType Directory -Path $temporal -Force | Out-Null

$hechas = 0
try {
    for ($i = 0; $i -lt $objetivo.Count; $i++) {
        $pista   = $objetivo[$i]
        $cancion = $mp3[$i % $mp3.Count]

        Write-Host ('    {0,-26} <- {1}' -f $pista, $cancion.BaseName) -ForegroundColor DarkGray

        $limpio = Join-Path $temporal 'x.mp3'
        Remove-Item "$temporal\*" -Force -ErrorAction SilentlyContinue
        Remove-EtiquetasMp3 -Entrada $cancion.FullName -Salida $limpio

        # --two-files da el par cabecera + audio, que es justo lo que necesita
        # el juego. Sin --loop: el codificador no sabe escribir el punto de
        # retorno del bucle y la pista cortaria raro al repetirse.
        & $codificador -E $limpio --two-files 2>&1 | Out-Null

        # OJO: la herramienta REEMPLAZA la extension, no la anade.
        # "x.mp3" produce "x.ealayer3", no "x.mp3.ealayer3".
        $base     = Join-Path $temporal ([System.IO.Path]::GetFileNameWithoutExtension($limpio))
        $audio    = "$base.ealayer3"
        $cabecera = "$base.ealayer3.header"

        if (-not (Test-Path $audio) -or (Get-Item $audio).Length -eq 0) {
            Write-Aviso "  '$($cancion.BaseName)' no se pudo convertir. Se salta."
            continue
        }

        Copy-Item $audio    (Join-Path $dirMusica "$pista.sns") -Force
        Copy-Item $cabecera (Join-Path $dirMusica "$pista.snr") -Force
        $hechas++
    }
}
finally {
    Remove-Item $temporal -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($hechas -eq 0) {
    Write-Fallo 'No se convirtio ninguna pista.'
    exit 1
}
Write-Ok "$hechas pistas cambiadas."
Write-Registro "musica.ps1 - $hechas pistas cambiadas desde $Origen"

Write-Host ''
Write-Host '    Entra al juego y comprueba como suena.' -ForegroundColor DarkGray
Write-Host '    Para volver atras:  .\musica.ps1 -Restaurar' -ForegroundColor DarkGray
Write-Host ''
Write-Host '    OJO: esto cambia la musica de ESTA copia del juego. Para que la' -ForegroundColor Yellow
Write-Host '    oigan los 50, hay que repartirla: o rehaces el ZIP del cliente,' -ForegroundColor Yellow
Write-Host '    o la empaquetas como mod y la sirve el servidor.' -ForegroundColor Yellow
Write-Host ''
