<#
.SYNOPSIS
    Actualiza los archivos del juego que se reparten a los jugadores.

.DESCRIPTION
    Script MANUAL: se ejecuta a mano antes de un evento, nunca solo. Reemplaza
    el contenido de gamefiles\ por una version nueva, guardando la anterior.

    Nunca destruye antes de verificar. El orden es siempre el mismo:
      1. Trae la version nueva a una carpeta temporal.
      2. Comprueba que ha llegado entera (tamano, y checksum si se le da uno).
      3. Guarda la version actual en gamefiles-backup\ con la fecha.
      4. Solo entonces reemplaza gamefiles\.
      5. Escribe version.txt y deja constancia en el log.

    Si algo falla en los pasos 1 o 2, no se toca nada de lo que ya funcionaba.

.PARAMETER Origen
    De donde sacar la version nueva. Admite:
      - Una carpeta local:  D:\NFSW\cliente
      - Un fichero .zip:    D:\NFSW\cliente.zip
      - Una URL http/https a un .zip
    Si no se indica, se usa $ORIGEN_POR_DEFECTO (editable justo abajo).

.PARAMETER Version
    Texto que se escribe en gamefiles\version.txt. Por defecto, la fecha.

.PARAMETER Sha256
    Checksum esperado del .zip descargado. Si se indica y no coincide,
    se aborta sin tocar nada. Muy recomendable con origenes remotos.

.PARAMETER SinConfirmar
    No pregunta antes de descargar ni de reemplazar. Para automatizar.

.EXAMPLE
    .\update-gamefiles.ps1 -Origen D:\NFSW\cliente
.EXAMPLE
    .\update-gamefiles.ps1 -Origen https://ejemplo/cliente.zip -Sha256 A1B2C3...
#>

[CmdletBinding()]
param(
    [string] $Origen,
    [string] $Version,
    [string] $Sha256,
    [switch] $SinConfirmar
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_comun.ps1')

# ---------------------------------------------------------------------
#  Origen por defecto: editar aqui si siempre se saca del mismo sitio.
# ---------------------------------------------------------------------
$ORIGEN_POR_DEFECTO = ''

Write-Titulo 'Actualizar los archivos del juego'

if (-not $Origen) { $Origen = $ORIGEN_POR_DEFECTO }
if (-not $Origen) {
    Write-Fallo 'No has indicado de donde sacar la version nueva.'
    Write-Host '       Usa:  .\update-gamefiles.ps1 -Origen <carpeta, .zip o URL>' -ForegroundColor Red
    Write-Host '       O edita $ORIGEN_POR_DEFECTO al principio de este script.' -ForegroundColor Red
    exit 1
}

$esUrl = $Origen -match '^https?://'

# --- Confirmacion explicita antes de tocar la red o el disco -----------
Write-Host ''
Write-Host '  Origen: ' -NoNewline
Write-Host $Origen -ForegroundColor Yellow
if ($esUrl) {
    Write-Host '  Esto va a DESCARGAR de internet.' -ForegroundColor Yellow
    if (-not $Sha256) {
        Write-Aviso 'Sin -Sha256 no se puede verificar que el fichero sea el correcto.'
    }
}
Write-Host ''

if (-not $SinConfirmar) {
    $r = Read-Host '  Continuar? (s/N)'
    if ($r -notmatch '^[sS]') {
        Write-Host '  Cancelado. No se ha tocado nada.' -ForegroundColor DarkGray
        exit 0
    }
}

$marca = Get-Date -Format 'yyyy-MM-dd_HHmm'
$temporal = Join-Path $env:TEMP "nfsw-gamefiles-$marca"
if (Test-Path $temporal) { Remove-Item $temporal -Recurse -Force }
New-Item -ItemType Directory -Path $temporal -Force | Out-Null

try {
    # =================================================================
    #  1. TRAER LA VERSION NUEVA
    # =================================================================
    Write-Host '  1. OBTENIENDO LA VERSION NUEVA' -ForegroundColor White
    Write-Host ''

    $carpetaNueva = $null

    if ($esUrl) {
        $zip = Join-Path $temporal 'cliente.zip'
        Write-Paso 'Descargando (puede tardar bastante)...'
        $progresoAnterior = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'   # sin esto Invoke-WebRequest va lentisimo
        try {
            Invoke-WebRequest -Uri $Origen -OutFile $zip -UseBasicParsing -TimeoutSec 7200
        } finally { $ProgressPreference = $progresoAnterior }

        if (-not (Test-Path $zip)) { throw 'La descarga no genero ningun fichero.' }
        $tam = (Get-Item $zip).Length
        if ($tam -lt 1MB) { throw "El fichero descargado pesa solo $tam bytes: la descarga no se completo." }
        Write-Ok ('Descargado: {0:N0} MB' -f ($tam / 1MB))

        if ($Sha256) {
            Write-Paso 'Verificando el checksum...'
            $real = (Get-FileHash -Path $zip -Algorithm SHA256).Hash
            if ($real -ne $Sha256.ToUpper().Replace('-','')) {
                throw "El checksum NO coincide.`n       Esperado: $Sha256`n       Obtenido: $real"
            }
            Write-Ok 'Checksum correcto.'
        }

        Write-Paso 'Descomprimiendo...'
        $extraido = Join-Path $temporal 'extraido'
        Expand-Archive -Path $zip -DestinationPath $extraido -Force
        $carpetaNueva = $extraido
    }
    elseif ($Origen -match '\.zip$') {
        if (-not (Test-Path $Origen)) { throw "No encuentro el fichero $Origen" }
        Write-Paso 'Descomprimiendo...'
        $extraido = Join-Path $temporal 'extraido'
        Expand-Archive -Path $Origen -DestinationPath $extraido -Force
        $carpetaNueva = $extraido
    }
    else {
        if (-not (Test-Path $Origen)) { throw "No encuentro la carpeta $Origen" }
        Write-Paso 'Copiando desde la carpeta de origen...'
        $copia = Join-Path $temporal 'copia'
        Copy-Item -Path $Origen -Destination $copia -Recurse -Force
        $carpetaNueva = $copia
    }

    # Si el zip traia todo dentro de una unica carpeta, se entra en ella.
    $hijos = @(Get-ChildItem $carpetaNueva)
    if ($hijos.Count -eq 1 -and $hijos[0].PSIsContainer) { $carpetaNueva = $hijos[0].FullName }

    # =================================================================
    #  2. COMPROBAR QUE ES UN CLIENTE DE VERDAD
    # =================================================================
    Write-Host ''
    Write-Host '  2. VERIFICANDO' -ForegroundColor White
    Write-Host ''

    $ficheros = @(Get-ChildItem $carpetaNueva -Recurse -File)
    $bytes    = ($ficheros | Measure-Object -Property Length -Sum).Sum

    if ($ficheros.Count -eq 0) { throw 'La version nueva no contiene ningun fichero.' }
    Write-Ok ('{0:N0} ficheros, {1:N1} GB' -f $ficheros.Count, ($bytes / 1GB))

    # Aviso, no error: puede que se reparta solo un parche y no el cliente entero.
    if (-not (Test-Path (Join-Path $carpetaNueva 'nfsw.exe'))) {
        Write-Aviso 'No hay nfsw.exe en la raiz: esto no parece el cliente completo.'
        if (-not $SinConfirmar) {
            $r = Read-Host '  Seguir igualmente? (s/N)'
            if ($r -notmatch '^[sS]') { throw 'Cancelado por el usuario.' }
        }
    } else {
        Write-Ok 'nfsw.exe encontrado.'
    }

    # =================================================================
    #  3. GUARDAR LA VERSION ACTUAL
    # =================================================================
    Write-Host ''
    Write-Host '  3. GUARDANDO LA VERSION ACTUAL' -ForegroundColor White
    Write-Host ''

    $actuales = Get-NumeroGamefiles
    if ($actuales -gt 0) {
        if (-not (Test-Path $DIR_BACKUP)) { New-Item -ItemType Directory -Path $DIR_BACKUP -Force | Out-Null }
        $destinoBackup = Join-Path $DIR_BACKUP $marca
        Write-Paso "Copiando $actuales ficheros a gamefiles-backup\$marca ..."
        Move-Item -Path $DIR_GAMEFILES -Destination $destinoBackup -Force
        New-Item -ItemType Directory -Path $DIR_GAMEFILES -Force | Out-Null
        Write-Ok "Version anterior guardada en gamefiles-backup\$marca"
    } else {
        Write-Host '    (gamefiles\ estaba vacia: no hay nada que guardar)' -ForegroundColor DarkGray
    }

    # =================================================================
    #  4. INSTALAR
    # =================================================================
    Write-Host ''
    Write-Host '  4. INSTALANDO' -ForegroundColor White
    Write-Host ''

    Get-ChildItem $carpetaNueva | ForEach-Object {
        Move-Item -Path $_.FullName -Destination $DIR_GAMEFILES -Force
    }

    if (-not $Version) { $Version = Get-Date -Format 'yyyy-MM-dd' }
    $texto = @"
$Version
Actualizado: $(Get-Date -Format 'yyyy-MM-dd HH:mm')
Origen: $Origen
Ficheros: $($ficheros.Count)
Tamano: $('{0:N1} GB' -f ($bytes / 1GB))
"@
    Set-Content -Path (Join-Path $DIR_GAMEFILES 'version.txt') -Value $texto -Encoding UTF8

    $finales = Get-NumeroGamefiles
    Write-Ok "$finales ficheros instalados en gamefiles\"
    Write-Ok "version.txt actualizado a: $Version"

    Write-Registro "update-gamefiles.ps1 - actualizado a '$Version' desde $Origen ($finales ficheros, $('{0:N1} GB' -f ($bytes/1GB)))" -Fichero 'gamefiles.log'

    Write-Host ''
    Write-Titulo 'Actualizacion completada'
    Write-Host ''
    Write-Host '    Los jugadores ya pueden descargarlos desde la web de registro.' -ForegroundColor DarkGray
    Write-Host ''
}
catch {
    Write-Host ''
    Write-Fallo "Actualizacion abortada: $($_.Exception.Message)"
    Write-Host ''
    if ((Get-NumeroGamefiles) -eq 0 -and (Test-Path (Join-Path $DIR_BACKUP $marca))) {
        Write-Aviso 'La version anterior esta en gamefiles-backup\' + $marca
        Write-Host '       Para recuperarla, mueve su contenido de vuelta a gamefiles\' -ForegroundColor Yellow
    } else {
        Write-Host '       No se ha tocado gamefiles\: sigue como estaba.' -ForegroundColor DarkGray
    }
    Write-Registro "update-gamefiles.ps1 - FALLO: $($_.Exception.Message)" -Fichero 'gamefiles.log'
    exit 1
}
finally {
    if (Test-Path $temporal) { Remove-Item $temporal -Recurse -Force -ErrorAction SilentlyContinue }
}
