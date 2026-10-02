<#
.SYNOPSIS
    Muestra de un vistazo si el servidor esta listo y que hay que dar a los jugadores.

.DESCRIPTION
    Es el script que mas se usa durante un evento. Responde a tres preguntas:
      1. Esta todo arrancado?
      2. Que URL les doy a los jugadores?
      3. Hay archivos del juego para descargar?

    No modifica nada: se puede ejecutar sin miedo y sin ser administrador.

.PARAMETER Detalle
    Ademas del resumen, muestra los PID, las reglas de firewall y el estado
    de la base de datos. Util cuando algo no funciona.

.EXAMPLE
    .\status.ps1
.EXAMPLE
    .\status.ps1 -Detalle
#>

[CmdletBinding()]
param([switch] $Detalle)

. (Join-Path $PSScriptRoot '_comun.ps1')

$ip = Get-IpLan

Write-Titulo 'NFS World - Estado del servidor LAN'

# --- Servicios ---------------------------------------------------------
Write-Host ''
Write-Host '  SERVICIOS' -ForegroundColor White
Write-Host ''

$arrancados = 0
foreach ($s in $SERVICIOS) {
    $vivo = Test-PuertoEscuchando -Puerto $s.Puerto -Protocolo $s.Protocolo
    if ($vivo) { $arrancados++ }

    $marca  = if ($vivo) { '  ACTIVO ' } else { ' parado  ' }
    $color  = if ($vivo) { 'Green' }     else { 'DarkGray' }
    $puerto = '{0}/{1}' -f $s.Puerto, $s.Protocolo.ToLower()

    Write-Host ('    {0,-24} ' -f $s.Etiqueta) -NoNewline
    Write-Host $marca -ForegroundColor $color -NoNewline
    Write-Host ('  {0,-10}' -f $puerto) -NoNewline -ForegroundColor DarkGray

    if ($Detalle -and $vivo) {
        $procId = Get-PidEnPuerto -Puerto $s.Puerto -Protocolo $s.Protocolo
        if ($procId) {
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            $nombre = if ($proc) { $proc.ProcessName } else { '?' }
            Write-Host ("  pid $procId ($nombre)") -NoNewline -ForegroundColor DarkGray
        }
    }
    Write-Host ''
}

$total = $SERVICIOS.Count
Write-Host ''
if ($arrancados -eq $total) {
    Write-Ok "Los $total servicios estan arrancados."
} elseif ($arrancados -eq 0) {
    Write-Aviso 'El servidor esta parado. Arrancalo con:  .\start.ps1'
} else {
    Write-Aviso "Solo $arrancados de $total servicios activos - el servidor NO esta listo."
    Write-Host '       Mira los logs en la carpeta logs\ para ver cual fallo.' -ForegroundColor Yellow
}

# --- Lo que hay que dar a los jugadores --------------------------------
Write-Host ''
Write-Host '  PARA LOS JUGADORES' -ForegroundColor White
Write-Host ''

if (-not $ip) {
    Write-Fallo 'No detecto ninguna IP de LAN. Comprueba el cable o el wifi.'
} else {
    Write-Host '    Servidor del juego   ' -NoNewline
    Write-Host "http://${ip}:$PUERTO_CORE/Engine.svc" -ForegroundColor Yellow
    Write-Host '      (esto es lo que se pone en el launcher, en "+ Anadir servidor")' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '    Registro y descargas ' -NoNewline
    Write-Host "http://${ip}:$PUERTO_WEB" -ForegroundColor Yellow
    Write-Host '      (esta la abren los jugadores en el navegador)' -ForegroundColor DarkGray
}

# --- Archivos del juego ------------------------------------------------
Write-Host ''
Write-Host '  ARCHIVOS DEL JUEGO' -ForegroundColor White
Write-Host ''

$n = Get-NumeroGamefiles
$version = Get-VersionGamefiles

if ($n -eq 0) {
    Write-Aviso 'La carpeta gamefiles\ esta vacia: no hay nada que descargar.'
    Write-Host '       Copia ahi el cliente del juego antes del evento.' -ForegroundColor Yellow
} else {
    Write-Host "    $n archivos disponibles para descarga" -ForegroundColor Green
    # version.txt lleva instrucciones completas para el jugador; aqui solo
    # interesa la primera linea, que es la que identifica la version.
    if ($version) {
        $titulo = ($version -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        Write-Host "    Version: $titulo" -ForegroundColor DarkGray
    }
}

# --- Detalle opcional --------------------------------------------------
if ($Detalle) {
    Write-Host ''
    Write-Host '  FIREWALL' -ForegroundColor White
    Write-Host ''
    $reglas = Get-NetFirewallRule -DisplayName 'NFSW LAN*' -ErrorAction SilentlyContinue
    if (-not $reglas) {
        Write-Aviso 'No hay reglas de firewall creadas. Ejecuta setup.ps1 como administrador.'
    } else {
        foreach ($r in $reglas) {
            $activa = if ($r.Enabled -eq 'True') { 'activa ' } else { 'DESACTIVADA' }
            $color  = if ($r.Enabled -eq 'True') { 'Green' } else { 'Red' }
            Write-Host ('    {0,-42} ' -f $r.DisplayName) -NoNewline
            Write-Host $activa -ForegroundColor $color
        }
    }

    Write-Host ''
    Write-Host '  BASE DE DATOS' -ForegroundColor White
    Write-Host ''
    if (-not (Test-PuertoEscuchando -Puerto $DB_PORT -Protocolo 'TCP')) {
        Write-Host '    (parada)' -ForegroundColor DarkGray
    } else {
        try {
            $cuentas  = (Invoke-Mysql -Sql 'SELECT COUNT(*) FROM user;')   -join ''
            $pilotos  = (Invoke-Mysql -Sql 'SELECT COUNT(*) FROM persona;') -join ''
            $eventos  = (Invoke-Mysql -Sql "SELECT COUNT(*) FROM event WHERE isEnabled = b'1';") -join ''
            Write-Host "    Cuentas registradas   $cuentas"
            Write-Host "    Pilotos creados       $pilotos"
            Write-Host "    Circuitos activos     $eventos"
        } catch {
            Write-Aviso "No pude consultar la base de datos: $($_.Exception.Message)"
        }
    }

    Write-Host ''
    Write-Host '  IP DETECTADA' -ForegroundColor White
    Write-Host ''
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notmatch '^127\.' } |
        ForEach-Object {
            $marca = if ($_.IPAddress -eq $ip) { ' <- la que se reparte' } else { '' }
            Write-Host ('    {0,-16} {1}{2}' -f $_.IPAddress, $_.InterfaceAlias, $marca) -ForegroundColor DarkGray
        }
}

Write-Host ''
