<#
.SYNOPSIS
    Deja el servidor limpio para el siguiente evento.

.DESCRIPTION
    Borra las cuentas, los pilotos, los coches y los logs del evento anterior,
    y deja la base de datos como recien montada.

    LO QUE NO TOCA NUNCA:
      gamefiles\          los archivos del juego (pesan 3 GB, se gestionan aparte)
      gamefiles-backup\   sus versiones anteriores
      mods\               los mods preparados
      server\             los binarios del servidor

    Pide confirmacion escrita antes de borrar nada, porque esto no se deshace.

.PARAMETER SinConfirmar
    No pregunta. Solo para automatizar; usalo sabiendo lo que haces.

.PARAMETER ConservarCuentas
    Borra pilotos, coches y progreso, pero deja las cuentas creadas.
    Util si repites evento con la misma gente y no quieres reimprimir tarjetas.

.EXAMPLE
    .\reset.ps1
.EXAMPLE
    .\reset.ps1 -ConservarCuentas
#>

[CmdletBinding()]
param(
    [switch] $SinConfirmar,
    [switch] $ConservarCuentas
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_comun.ps1')

Write-Titulo 'Reiniciar el servidor para el siguiente evento'

# --- Que se va a borrar exactamente ------------------------------------
Write-Host ''
Write-Host '  SE VA A BORRAR:' -ForegroundColor Yellow
if (-not $ConservarCuentas) {
    Write-Host '    - Todas las cuentas de jugador' -ForegroundColor Yellow
}
Write-Host '    - Todos los pilotos, coches y progreso' -ForegroundColor Yellow
Write-Host '    - Los logs del evento anterior' -ForegroundColor Yellow
Write-Host ''
Write-Host '  NO se toca:' -ForegroundColor Green
Write-Host '    - gamefiles\ ni gamefiles-backup\ (los archivos del juego)' -ForegroundColor Green
Write-Host '    - mods\ ni server\' -ForegroundColor Green
Write-Host '    - Las copias de seguridad en logs\backups\' -ForegroundColor Green

if (-not $SinConfirmar) {
    Write-Host ''
    $r = Read-Host '  Escribe BORRAR para continuar (cualquier otra cosa cancela)'
    if ($r -ne 'BORRAR') {
        Write-Host ''
        Write-Host '  Cancelado. No se ha tocado nada.' -ForegroundColor DarkGray
        Write-Host ''
        exit 0
    }
}

if (-not (Test-PuertoEscuchando -Puerto $DB_PORT)) {
    Write-Fallo 'La base de datos esta parada. Arrancala primero con start.ps1'
    exit 1
}

# --- Copia de seguridad automatica antes de destruir -------------------
Write-Host ''
Write-Paso 'Guardando una copia de seguridad antes de borrar (por si acaso)...'
$marca = Get-Date -Format 'yyyy-MM-dd_HHmm'
try {
    & (Join-Path $PSScriptRoot 'backup-db.ps1') -Etiqueta "antes-de-reset-$marca" | Out-Null
    Write-Ok "Copia guardada como antes-de-reset-$marca"
} catch {
    Write-Aviso "No pude hacer la copia previa: $($_.Exception.Message)"
    if (-not $SinConfirmar) {
        $r2 = Read-Host '  Seguir de todas formas? (s/N)'
        if ($r2 -notmatch '^[sS]') { Write-Host '  Cancelado.' -ForegroundColor DarkGray; exit 0 }
    }
}

# --- Borrado -----------------------------------------------------------
Write-Host ''
Write-Host '  LIMPIANDO' -ForegroundColor White
Write-Host ''

# El orden importa por las claves ajenas: primero lo que depende de persona,
# luego persona, y al final user. Se desactivan las comprobaciones igualmente
# para no depender del orden exacto entre versiones del esquema.
$tablasPersona = @(
    'car', 'ownedcartrans', 'performancepart', 'visualpart', 'paint', 'vinyl',
    'inventoryitem', 'inventory', 'achievementpersona', 'achievementrank',
    'friendlist', 'personaachievementrank', 'eventdata', 'eventsession',
    'lobbyentrant', 'lobby', 'treasurehunt', 'persona'
)

$sql = New-Object System.Text.StringBuilder
[void]$sql.AppendLine('SET FOREIGN_KEY_CHECKS = 0;')
foreach ($t in $tablasPersona) {
    # DELETE en vez de TRUNCATE: TRUNCATE falla si hay claves ajenas apuntando,
    # y ademas queremos que la tabla siga existiendo aunque este vacia.
    [void]$sql.AppendLine("DELETE FROM ``$t``;")
}
if (-not $ConservarCuentas) {
    [void]$sql.AppendLine('DELETE FROM `user`;')
}
[void]$sql.AppendLine('SET FOREIGN_KEY_CHECKS = 1;')

try {
    Invoke-Mysql -Sql $sql.ToString() -ComoRoot | Out-Null
    if ($ConservarCuentas) {
        Write-Ok 'Pilotos, coches y progreso borrados (las cuentas se conservan).'
    } else {
        Write-Ok 'Cuentas, pilotos, coches y progreso borrados.'
    }
} catch {
    # Es normal que alguna tabla no exista segun la version del esquema:
    # se avisa pero no se aborta.
    Write-Aviso "Algunas tablas no se pudieron limpiar: $($_.Exception.Message)"
    Write-Host '       Suele ser porque esa tabla no existe en este esquema. Revisa el recuento final.' -ForegroundColor Yellow
}

# --- Logs --------------------------------------------------------------
$borrados = 0
Get-ChildItem $DIR_LOGS -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in '.log', '.json' } |
    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue; $borrados++ }
Remove-Item (Join-Path $DIR_LOGS 'cuentas') -Recurse -Force -ErrorAction SilentlyContinue
Write-Ok "$borrados ficheros de log borrados (las copias de seguridad se conservan)."

# --- Comprobacion final ------------------------------------------------
Write-Host ''
Write-Host '  ESTADO FINAL' -ForegroundColor White
Write-Host ''
try {
    $cuentas = (Invoke-Mysql -Sql 'SELECT COUNT(*) FROM user;')    -join ''
    $pilotos = (Invoke-Mysql -Sql 'SELECT COUNT(*) FROM persona;') -join ''
    Write-Host "    Cuentas: $cuentas       Pilotos: $pilotos"
} catch {
    Write-Aviso 'No pude leer el recuento final.'
}

Write-Registro 'reset.ps1 - servidor limpiado para el siguiente evento'

Write-Host ''
Write-Ok 'Listo para el siguiente evento.'
Write-Host ''
Write-Host '    Recuerda:' -ForegroundColor DarkGray
Write-Host '      - Reinicia el servidor (stop.ps1 y start.ps1) para vaciar la cache.' -ForegroundColor DarkGray
Write-Host '      - Vuelve a crear las cuentas con crear-cuentas.ps1 -Aplicar' -ForegroundColor DarkGray
Write-Host ''
