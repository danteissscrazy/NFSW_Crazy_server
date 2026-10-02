<#
.SYNOPSIS
    Guarda una copia de seguridad de la base de datos, con la fecha en el nombre.

.DESCRIPTION
    Vuelca los dos esquemas (el del juego y el del chat) a ficheros .sql dentro
    de logs\backups\. Sirve para dos cosas:

      - Guardar los perfiles y coches de una LAN party antes de resetear.
      - Tener el punto de restauracion "servidor recien montado" que usa
        reset.ps1 para dejarlo todo limpio para el siguiente evento.

    El servidor tiene que estar arrancado (la base de datos, al menos).

.PARAMETER Etiqueta
    Texto que se anade al nombre del fichero. Por defecto la fecha y hora.
    Usa -Etiqueta limpio para crear el punto de restauracion base.

.PARAMETER Comprimir
    Comprime el resultado en un .zip y borra los .sql sueltos.

.EXAMPLE
    .\backup-db.ps1
    Copia con marca de tiempo.

.EXAMPLE
    .\backup-db.ps1 -Etiqueta limpio
    Crea el punto de restauracion que usara reset.ps1.
#>

[CmdletBinding()]
param(
    [string] $Etiqueta,
    [switch] $Comprimir
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_comun.ps1')

Write-Titulo 'Copia de seguridad de la base de datos'

if (-not (Test-PuertoEscuchando -Puerto $DB_PORT)) {
    Write-Fallo 'La base de datos esta parada. Arrancala primero con start.ps1'
    exit 1
}

$mysqldump = Get-RutaMysql -Programa 'mysqldump'
if (-not $mysqldump) { Write-Fallo 'No encuentro mysqldump.exe'; exit 1 }

if (-not $Etiqueta) { $Etiqueta = Get-Date -Format 'yyyy-MM-dd_HHmm' }
# Nada de caracteres raros en el nombre del fichero.
$Etiqueta = $Etiqueta -replace '[^\w\-]', '_'

$destino = Join-Path $DIR_LOGS 'backups'
if (-not (Test-Path $destino)) { New-Item -ItemType Directory -Path $destino -Force | Out-Null }

$generados = @()

# Solo se vuelca el esquema del juego. El del chat existe en MySQL pero esta
# VACIO: Openfire usa su propia base de datos embebida (HSQLDB) dentro de
# server\openfire\embedded-db\. Volcar aqui el esquema 'openfire' daba un
# fichero de 1 KB que parecia una copia y no lo era. Los datos reales del chat
# se copian mas abajo, como ficheros.
foreach ($esquema in @($DB_NOMBRE)) {
    $fichero = Join-Path $destino "$esquema-$Etiqueta.sql"
    Write-Paso "Volcando $esquema..."

    # --single-transaction: copia coherente sin bloquear a los jugadores.
    # --routines y --triggers: si no, se pierde el trigger de la moneda premium.
    #
    # La contrasena va por MYSQL_PWD y no por --password: asi MySQL no imprime
    # su aviso por stderr. Con $ErrorActionPreference = 'Stop' ese aviso aborta
    # el script y deja el volcado a 0 bytes - una copia vacia que parece buena.
    # De paso, la contrasena deja de verse en la lista de procesos.
    $env:MYSQL_PWD = $DB_ROOTPW
    try {
        & $mysqldump `
            "--host=$DB_HOST" "--port=$DB_PORT" "--user=$DB_ROOT" `
            '--single-transaction' '--routines' '--triggers' '--events' `
            '--default-character-set=utf8mb4' `
            $esquema | Out-File -FilePath $fichero -Encoding UTF8
    } finally { $env:MYSQL_PWD = $null }

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $fichero)) {
        Write-Fallo "Fallo el volcado de $esquema (codigo $LASTEXITCODE)"
        continue
    }

    $tam = (Get-Item $fichero).Length
    if ($tam -lt 1024) {
        Write-Aviso "$esquema genero un fichero sospechosamente pequeno ($tam bytes). Revisalo."
    } else {
        Write-Ok ('{0,-12} {1,10:N0} KB   {2}' -f $esquema, ($tam / 1KB), (Split-Path $fichero -Leaf))
    }
    $generados += $fichero
}

if ($generados.Count -eq 0) {
    Write-Fallo 'No se genero ninguna copia.'
    exit 1
}

# --- Datos del chat (Openfire) -----------------------------------------
# Openfire guarda usuarios, salas y sus propiedades en una base HSQLDB
# embebida, que son ficheros. Perderlos significa reconfigurar el chat entero
# y, peor, que el servidor del juego no arranque (necesita conectarse a el).
$embebida = Join-Path $DIR_SERVER 'openfire\embedded-db'
if (Test-Path $embebida) {
    $zipChat = Join-Path $destino "openfire-$Etiqueta.zip"

    # Se excluyen .lck y .log: son el fichero de bloqueo y el diario de
    # transacciones en curso. Openfire los tiene abiertos mientras corre, asi
    # que intentar copiarlos suelta un error por cada uno; y no aportan nada,
    # porque los datos estan en openfire.script y openfire.properties.
    $aCopiar = Get-ChildItem $embebida -File |
               Where-Object { $_.Extension -notin '.lck', '.log' }

    if (-not $aCopiar) {
        Write-Aviso 'La base del chat esta vacia: no hay nada que copiar.'
    } else {
        try {
            Compress-Archive -Path $aCopiar.FullName -DestinationPath $zipChat -Force
            $kb = [int]((Get-Item $zipChat).Length / 1KB)
            Write-Ok ('{0,-12} {1,10:N0} KB   {2}' -f 'chat', $kb, (Split-Path $zipChat -Leaf))
        } catch {
            Write-Aviso "No pude copiar la base del chat: $($_.Exception.Message)"
        }
    }
}

if ($Comprimir) {
    $zip = Join-Path $destino "backup-$Etiqueta.zip"
    Compress-Archive -Path $generados -DestinationPath $zip -Force
    $generados | Remove-Item -Force
    Write-Ok "Comprimido en $(Split-Path $zip -Leaf)"
}

Write-Registro "backup-db.ps1 - copia '$Etiqueta' creada"

Write-Host ''
Write-Host "    Copias en: $destino" -ForegroundColor DarkGray
if ($Etiqueta -eq 'limpio') {
    Write-Host ''
    Write-Ok 'Punto de restauracion creado. reset.ps1 volvera a este estado.'
}
Write-Host ''
