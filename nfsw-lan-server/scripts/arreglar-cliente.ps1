<#
    Pone una instalacion del cliente al dia con la carpeta maestra del juego.

    Nacio porque el 8 de septiembre se descubrio que D:\NfS World Lan\Cliente venia de
    un NFSW-Cliente.zip anterior a casi todo el trabajo: le faltaban los 11 coches
    sustituidos, las ediciones de VLT, la radio, el soporte de mando (scripts\), el
    cargador de mods (dinput8.dll + ModLoader.asi + global.ini + MODS\) y TRAFPIZZA.

    Copia de Maestro a Cliente todo fichero que falte o que tenga distinto tamano.
    Es idempotente: pasarlo dos veces no hace nada la segunda.

    HAY QUE EJECUTARLO COMO ADMINISTRADOR si el juego esta abierto, porque nfsw.exe
    arranca elevado y si no no se puede cerrar ni sobrescribir lo que tenga abierto.

        .\arreglar-cliente.ps1                 # ver que haria, sin tocar nada
        .\arreglar-cliente.ps1 -Aplicar        # hacerlo de verdad
#>
param(
    [string]$Maestro = 'E:\Multimedia\Programación\Proyectos\NFS World\Juego',
    [string]$Cliente = 'D:\NfS World Lan\Cliente',
    [string]$GlobalC = '',   # vacio = el GlobalC.lzc viene de la maestra con el resto; pasa una ruta solo para forzar otro
    [switch]$Aplicar
)
$ErrorActionPreference = 'Continue'

# Cosas que NO se copian: registros del juego, volcados de fallo, el propio ZIP y el
# fichero .links, que es estado en marcha del cargador de mods y esta OCULTO en la
# carpeta maestra. Si se copia, el juego se niega a arrancar diciendo
# ".links file should not exist upon start".
$Excluir = '(SBRCrashDump|NFSWO_COMMUNICATION_LOG\.txt$|\.zip$|\.links$)'

foreach ($d in $Maestro, $Cliente) {
    if (-not (Test-Path -LiteralPath $d)) { Write-Host "no existe: $d" -ForegroundColor Red; exit 1 }
}

if (Get-Process nfsw -ErrorAction SilentlyContinue) {
    if ($Aplicar) {
        Write-Host 'el juego esta abierto, lo cierro'
        try { Get-Process nfsw -EA Stop | Stop-Process -Force -EA Stop; Start-Sleep -Seconds 3 }
        catch { Write-Host '  NO he podido cerrarlo (corre elevado). Ejecuta ESTE script como administrador.' -ForegroundColor Yellow }
    } else {
        Write-Host 'aviso: el juego esta abierto; para aplicar hay que cerrarlo (script como administrador)'
    }
}

Write-Host 'leyendo la carpeta maestra...'
$m = @{}
Get-ChildItem -LiteralPath $Maestro -Recurse -File -Force | ForEach-Object {
    $rel = $_.FullName.Substring($Maestro.Length).TrimStart('\')
    if ($rel -notmatch $Excluir) { $m[$rel] = $_.Length }
}
Write-Host "  $($m.Count) ficheros"

Write-Host 'comparando con el cliente...'
$copiar = New-Object System.Collections.ArrayList
foreach ($rel in $m.Keys) {
    $destino = Join-Path $Cliente $rel
    if (-not (Test-Path -LiteralPath $destino)) { [void]$copiar.Add(@{ Rel = $rel; Motivo = 'falta' }) }
    elseif ((Get-Item -LiteralPath $destino).Length -ne $m[$rel]) { [void]$copiar.Add(@{ Rel = $rel; Motivo = 'distinto' }) }
}
$faltan   = ($copiar | Where-Object { $_.Motivo -eq 'falta' }).Count
$distintos = ($copiar | Where-Object { $_.Motivo -eq 'distinto' }).Count
Write-Host "  $faltan faltan, $distintos con distinto tamano, $($copiar.Count) a copiar"

if (-not $Aplicar) {
    $copiar | Sort-Object { $_.Rel } | ForEach-Object { '   [{0,-8}] {1}' -f $_.Motivo, $_.Rel }
    Write-Host ''
    Write-Host 'esto ha sido solo un ensayo. Vuelve a lanzarlo con -Aplicar para hacerlo.' -ForegroundColor Cyan
    exit 0
}

$ok = 0; $fallos = New-Object System.Collections.ArrayList
foreach ($c in $copiar) {
    $origen  = Join-Path $Maestro $c.Rel
    $destino = Join-Path $Cliente $c.Rel
    $carpeta = Split-Path $destino -Parent
    # A un temporal y luego mover: si falla a mitad, el fichero bueno del cliente
    # sigue intacto en vez de quedarse a medio escribir.
    $tmp = "$destino.copiando"
    try {
        if (-not (Test-Path -LiteralPath $carpeta)) { New-Item -ItemType Directory -Path $carpeta -Force | Out-Null }
        Copy-Item -LiteralPath $origen -Destination $tmp -Force -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $destino -Force -ErrorAction Stop
        $ok++
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        [void]$fallos.Add($c.Rel)
    }
}
Write-Host "copiados $ok de $($copiar.Count)"
if ($fallos.Count) {
    Write-Host "NO se pudieron copiar $($fallos.Count) (el juego los tiene abiertos, o hace falta administrador):" -ForegroundColor Yellow
    $fallos | ForEach-Object { "   $_" }
}

# Las carpetas vacias que el juego exige (MODS\<hash>) no salen en el recorrido de ficheros.
Get-ChildItem -LiteralPath $Maestro -Recurse -Directory -Force |
    Where-Object { $_.FullName -notmatch $Excluir } |
    ForEach-Object {
        $rel = $_.FullName.Substring($Maestro.Length).TrimStart('\')
        $d = Join-Path $Cliente $rel
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null; "   carpeta creada: $rel" }
    }

# El fichero .links no puede existir al arrancar
Get-ChildItem -LiteralPath $Cliente -Filter '*.links' -File -EA SilentlyContinue | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Force; "   borrado $($_.Name) (el juego se niega a arrancar si existe)"
}

if ($GlobalC -and (Test-Path -LiteralPath $GlobalC)) {
    $dst = Join-Path $Cliente 'CARS\GlobalC.lzc'
    $bak = Join-Path $Cliente 'CARS\GlobalC.lzc.de-serie'
    if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $dst -Destination $bak -Force }
    try {
        Copy-Item -LiteralPath $GlobalC -Destination $dst -Force -ErrorAction Stop
        "GlobalC.lzc puesto: $((Get-Item $dst).Length) bytes  (respaldo de serie en GlobalC.lzc.de-serie)"
    } catch { Write-Host "  NO he podido poner el GlobalC: $($_.Exception.Message)" -ForegroundColor Yellow }
}
Write-Host 'listo.'
