<#
.SYNOPSIS
    Arranca el servidor completo de NFS World para la LAN party.

.DESCRIPTION
    Levanta los seis servicios en el orden correcto y, sobre todo, hace LO MAS
    IMPORTANTE para que la carpeta sea de verdad portable: detecta la IP de
    esta maquina y la escribe en la base de datos.

    Por que esto ultimo es imprescindible: el protocolo del juego no le dice al
    cliente "conecta a quien te sirvio esto". El servidor reparte a los clientes
    las direcciones que tiene guardadas en su tabla `parameter`. Si esas
    direcciones son las del evento anterior, los jugadores entran al juego,
    ven el menu... y no se ven entre si. Es el fallo mas desconcertante posible,
    porque todo parece funcionar. Por eso se reescriben en CADA arranque.

    Ademas regenera launcher\Servers-Custom.json con la IP actual, para poder
    repartir el launcher ya configurado.

    Orden de arranque (importa): base de datos -> chat -> servidor del juego
    -> mundo abierto y carreras -> web. El servidor del juego espera a estar
    respondiendo antes de dar por bueno el arranque.

.PARAMETER SinEsperar
    No espera a que el servidor del juego responda. Mas rapido, pero no
    garantiza que este listo.

.PARAMETER Ip
    Fuerza una IP concreta en vez de detectarla. Solo para casos raros
    (varias tarjetas de red y quieres elegir).

.EXAMPLE
    .\start.ps1
.EXAMPLE
    .\start.ps1 -Ip 192.168.1.50
#>

[CmdletBinding()]
param(
    [switch] $SinEsperar,
    [string] $Ip
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_comun.ps1')

# (28-sep) Todo lo que se imprime queda en logs\arranque.txt: es lo que hay que
# pedir cuando en otro PC "da un error" y nadie apunto cual.
if (-not (Test-Path $DIR_LOGS)) { New-Item -ItemType Directory -Path $DIR_LOGS -Force | Out-Null }
try { Start-Transcript -Path (Join-Path $DIR_LOGS 'arranque.txt') -Append -Force | Out-Null } catch { }
Write-Registro "start.ps1 - inicio (PS $($PSVersionTable.PSVersion), admin=$(Test-EsAdministrador))"
# Las sondas a 127.0.0.1 no pasan por ningun proxy (PAC/VPN corporativa).
[System.Net.WebRequest]::DefaultWebProxy = $null

Write-Titulo 'NFS World LAN - Arrancando servidor'

# --- IP ----------------------------------------------------------------
if (-not $Ip) { $Ip = Get-IpLan }
if (-not $Ip) {
    Write-Fallo 'No detecto ninguna IP de LAN. Conecta el cable o el wifi.'
    exit 1
}
Write-Ok "IP de esta maquina: $Ip"

if (-not (Test-Path $DIR_LOGS)) { New-Item -ItemType Directory -Path $DIR_LOGS -Force | Out-Null }
$pids = @{}

# =====================================================================
#  0. COMPROBACIONES PREVIAS (28-sep)
#
#  Anadidas despues de que el servidor fallara al arrancar en el PC de un
#  colega sin que el mensaje dijera por que. Cada una es una causa real de
#  "en mi PC va y en el otro no", y todas se pueden explicar en una linea.
# =====================================================================

# Java hereda esta variable. En el PC donde se desarrollo estaba puesta como
# variable de usuario (IPv4 y UTF-8) y en un PC ajeno no: se fija aqui para
# que Openfire y el servidor del juego arranquen igual en cualquier maquina.
$env:JAVA_TOOL_OPTIONS = '-Djava.net.preferIPv4Stack=true -Dfile.encoding=UTF-8'

# Carpeta sincronizada (OneDrive, Drive, Dropbox): el sincronizador bloquea los
# ficheros de MySQL mientras los sube y la base de datos no arranca o se corrompe.
$sincronizada = ($env:OneDrive -and $RAIZ.StartsWith($env:OneDrive, [System.StringComparison]::OrdinalIgnoreCase)) -or
                ($RAIZ -match '\\(OneDrive|Google Drive|Dropbox|iCloudDrive)\\')
if ($sincronizada) {
    Write-Fallo "Esta carpeta esta dentro de una carpeta sincronizada (OneDrive o similar): $RAIZ"
    Write-Host '       MySQL no puede trabajar ahi. Mueve nfsw-lan-server a C:\CrazyServer y vuelve a ARRANCAR.' -ForegroundColor Red
    exit 1
}
# Caracteres que rompen los lanzadores .bat y las rutas de PowerShell.
if ($RAIZ -match '[&^%!\[\]]') {
    Write-Fallo "La ruta de la carpeta lleva un caracter que rompe los lanzadores (& ^ % ! [ ]): $RAIZ"
    Write-Host '       Mueve nfsw-lan-server a C:\CrazyServer y vuelve a ARRANCAR.' -ForegroundColor Red
    exit 1
}
# Hay que poder escribir donde escriben MySQL, Openfire y los logs. En Archivos
# de programa (o una carpeta de solo lectura) los servicios arrancan y mueren
# sin dejar ni un log: Start-Process no avisa si no puede abrir el fichero.
foreach ($carpeta in @((Join-Path $DIR_DB 'data'), $DIR_LOGS, (Join-Path $DIR_SERVER 'openfire\embedded-db'))) {
    if (-not (Test-Path -LiteralPath $carpeta)) { continue }
    $prueba = Join-Path $carpeta ('.escritura-{0}' -f $PID)
    try { [System.IO.File]::WriteAllText($prueba, 'x'); [System.IO.File]::Delete($prueba) }
    catch {
        Write-Fallo "No puedo escribir en $carpeta ($($_.Exception.Message))"
        Write-Host '       Mueve nfsw-lan-server a C:\CrazyServer (fuera de Archivos de programa) y vuelve a ARRANCAR.' -ForegroundColor Red
        exit 1
    }
}
# Puertos a vigilar: los seis servicios y la consola de Openfire (9090), que el
# servidor del juego usa para crear las salas de chat.
$puertosVigilados = @($SERVICIOS | ForEach-Object { @{ Nombre = $_.Nombre; Etiqueta = $_.Etiqueta; Puerto = $_.Puerto; Protocolo = $_.Protocolo } }) +
                    @(@{ Nombre = 'ofadmin'; Etiqueta = 'Consola de Openfire'; Puerto = $PUERTO_OF_ADMIN; Protocolo = 'TCP' })

# Puertos reservados por Windows. Hyper-V, WSL y Docker reservan rangos de
# puertos AL AZAR en cada arranque de Windows; si uno de los nuestros cae
# dentro, ese servicio no puede abrirlo y falla sin explicar nada.
$reservados = @()
try {
    foreach ($linea in (& netsh interface ipv4 show excludedportrange protocol=tcp 2>&1)) {
        if ($linea -match '^\s*(\d+)\s+(\d+)') { $reservados += [pscustomobject]@{ De = [int]$matches[1]; A = [int]$matches[2] } }
    }
} catch { }
$chocan = @(); $chocaWeb = $false
foreach ($s in $puertosVigilados | Where-Object { $_.Protocolo -eq 'TCP' }) {
    foreach ($r in $reservados) {
        if ($s.Puerto -ge $r.De -and $s.Puerto -le $r.A) {
            if ($s.Puerto -eq $PUERTO_WEB) { $chocaWeb = $true } else { $chocan += ('{0} ({1}, reservado {2}-{3})' -f $s.Etiqueta, $s.Puerto, $r.De, $r.A) }
        }
    }
}
if ($chocan.Count -gt 0) {
    Write-Fallo ('Windows tiene reservados puertos que necesita el servidor: ' + ($chocan -join '; '))
    Write-Host '       Arreglo (PowerShell como administrador):  net stop winnat ; net start winnat' -ForegroundColor Red
    Write-Host '       Si sigue igual, reinicia Windows y prueba otra vez. Es cosa de Hyper-V/WSL/Docker.' -ForegroundColor Red
    exit 1
}
if ($chocaWeb) { Write-Aviso "Windows tiene reservado el puerto ${PUERTO_WEB}: la web de registro no arrancara (el juego si). net stop winnat ; net start winnat lo libera." }

# Puertos ocupados por OTRO programa (un MySQL instalado, otro servidor web...).
# Antes se daba por "ya arrancado" y se seguia con el servicio ajeno: el fallo
# aparecia dos pasos mas tarde con un mensaje que no tenia nada que ver.
# OJO: desde una sesion normal no se puede leer la ruta (.Path) de un proceso
# elevado (por ejemplo el MySQL que "Preparar PC" arranca como administrador),
# asi que cuando no hay ruta se decide por el nombre del proceso.
$nuestros = @('mysqld', 'java', 'freeroamd', 'race', 'python', 'cmd')
$ajenos = @(); $ajenoWeb = $null
foreach ($s in $puertosVigilados) {
    if (-not (Test-PuertoEscuchando -Puerto $s.Puerto -Protocolo $s.Protocolo)) { continue }
    $procId = Get-PidEnPuerto -Puerto $s.Puerto -Protocolo $s.Protocolo
    $proc   = if ($procId) { Get-Process -Id $procId -ErrorAction SilentlyContinue } else { $null }
    $ruta   = if ($proc) { $proc.Path } else { $null }
    if ($ruta) { $esAjeno = -not $ruta.StartsWith($RAIZ, [System.StringComparison]::OrdinalIgnoreCase) }
    else       { $esAjeno = -not ($proc -and ($nuestros -contains $proc.ProcessName)) }
    if ($esAjeno) {
        $quien = if ($proc) { "$($proc.ProcessName) (pid $procId)" } elseif ($procId) { "pid $procId" } else { 'un proceso desconocido' }
        $texto = ('{0} {1}/{2} lo usa {3}' -f $s.Etiqueta, $s.Puerto, $s.Protocolo.ToLower(), $quien)
        if ($s.Puerto -eq $PUERTO_WEB) { $ajenoWeb = $texto } else { $ajenos += $texto }
    } elseif (-not $ruta -and $proc) {
        Write-Aviso ('{0} ({1}/{2}): ya hay un {3} (pid {4}) arrancado como administrador; se reutiliza.' -f $s.Etiqueta, $s.Puerto, $s.Protocolo.ToLower(), $proc.ProcessName, $procId)
        Write-Host '       Si falla: PowerShell como administrador, .\scripts\stop.ps1 -Forzar y ARRANCAR.' -ForegroundColor Yellow
    }
}
if ($ajenos.Count -gt 0) {
    Write-Fallo ('Hay puertos del servidor ocupados por otro programa: ' + ($ajenos -join '; '))
    Write-Host '       Cierra ese programa (o desinstala ese servicio) y vuelve a ARRANCAR.' -ForegroundColor Red
    Write-Host '       Si es un mysqld o un java sin ruta, puede ser un resto de "Preparar PC": cierralo desde un PowerShell de administrador (.\scripts\stop.ps1 -Forzar) o reinicia el PC.' -ForegroundColor Red
    exit 1
}
if ($ajenoWeb) { Write-Aviso "$ajenoWeb : la web de registro no arrancara (el juego si)." }

# Memoria: el servidor del juego pide 2 GB de heap; en un PC con poca RAM la
# JVM no arranca ("Could not reserve enough space") y muere en silencio.
$XmxCore = '2g'
try {
    $ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    if ($ramGb -lt 4)      { $XmxCore = '768m'; Write-Aviso "Solo hay $ramGb GB de RAM: el servidor del juego arranca con 768 MB. Ira justo." }
    elseif ($ramGb -lt 8)  { $XmxCore = '1g';   Write-Ok "RAM: $ramGb GB (servidor del juego con 1 GB de heap)." }
} catch { }

function Test-OpenfireListo {
    <#
    .SYNOPSIS
        Openfire ha cargado sus plugins (entre ellos el del API y el de login
        sin SASL que usa el juego). Abrir el 5222 no basta: el servidor del
        juego se conecta nada mas verlo abierto y, si los plugins aun cargan,
        Openfire le responde "not-authorized" y el despliegue entero se cae.
        Paso exactamente asi el 27-09 con el disco ocupado.
    #>
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$PUERTO_OF_ADMIN/plugins/restapi/v1/system/properties" -TimeoutSec 4 -UseBasicParsing
        if ($r.StatusCode -eq 200) { return $true }
    } catch {
        $resp = $_.Exception.Response
        if ($resp -and ([int]$resp.StatusCode -eq 401 -or [int]$resp.StatusCode -eq 403)) { return $true }  # el plugin responde: listo
    }
    # Openfire escribe esa marca por stdout (log4j2 -> consola), es decir, en
    # logs\openfire.log, que Start-Servicio vacia en cada arranque.
    $log = Join-Path $DIR_LOGS 'openfire.log'
    if ((Test-Path $log) -and (Select-String -Path $log -Pattern 'Finished processing all plugins' -Quiet -ErrorAction SilentlyContinue)) { return $true }
    return $false
}

function Start-Servicio {
    <# Arranca un proceso en segundo plano redirigiendo su salida a logs\. #>
    param(
        [Parameter(Mandatory)][string] $Nombre,
        [Parameter(Mandatory)][string] $Ejecutable,
        [string[]] $Argumentos = @(),
        [string]   $Directorio = $DIR_SERVER
    )
    $log = Join-Path $DIR_LOGS "$Nombre.log"
    $err = Join-Path $DIR_LOGS "$Nombre.err.log"

    # Entrecomillamos TODO argumento que lleve espacios. Sin esto, cualquier
    # ruta con un espacio ("...\NFS World\...") se parte por la mitad y el
    # programa recibe media ruta. Nos paso con MySQL y con Python: es sistematico.
    $seguros = @($Argumentos | ForEach-Object {
        if ($_ -match '\s' -and $_ -notmatch '^".*"$' -and $_ -notmatch '="') { '"{0}"' -f $_ } else { $_ }
    })

    # -ArgumentList SOLO si hay argumentos. Con la lista vacia PowerShell 7 lo
    # tolera, pero Windows PowerShell 5.1 (el que trae Windows de fabrica) se
    # niega: "El argumento es null o esta vacio". Openfire, freeroam y race
    # arrancan sin argumentos, asi que en un PC sin PowerShell 7 fallaban los
    # tres. Salio en el primer equipo ajeno donde se probo: aqui nunca, porque
    # el desarrollo se hizo con PowerShell 7.
    $opciones = @{
        FilePath               = $Ejecutable
        WorkingDirectory       = $Directorio
        PassThru               = $true
        WindowStyle            = 'Hidden'
        RedirectStandardOutput = $log
        RedirectStandardError  = $err
    }
    if ($seguros.Count -gt 0) { $opciones['ArgumentList'] = $seguros }

    $p = Start-Process @opciones
    $script:pids[$Nombre] = $p.Id
    return $p
}

function Wait-Api {
    <#
    .SYNOPSIS
        Espera a que la API del juego devuelva 200 de verdad.
    .DESCRIPTION
        Distinto de esperar al puerto: el 8080 lo abre la consola interna del
        servidor mucho antes de que el juego este desplegado. Solo una respuesta
        200 de GetServerInformation significa "listo para jugar".
    #>
    param(
        [Parameter(Mandatory)][string] $Url,
        [int] $Segundos = 120
    )
    $limite = (Get-Date).AddSeconds($Segundos)
    while ((Get-Date) -lt $limite) {
        try {
            $r = Invoke-WebRequest -Uri $Url -TimeoutSec 5 -UseBasicParsing
            if ($r.StatusCode -eq 200) { return $true }
        } catch { }
        Start-Sleep -Seconds 3
    }
    return $false
}

function Wait-Puerto {
    param(
        [Parameter(Mandatory)][int] $Puerto,
        [ValidateSet('TCP','UDP')][string] $Protocolo = 'TCP',
        [int] $Segundos = 60,
        [string] $Que = 'el servicio',
        # (28-sep) Si el proceso muere al instante (JVM sin memoria, jar que no
        # esta, mysqld con el datadir bloqueado), no tiene sentido esperar los
        # minutos enteros: se devuelve fallo en cuanto se ve que ya no existe.
        [System.Diagnostics.Process] $Proceso
    )
    $limite = (Get-Date).AddSeconds($Segundos)
    while ((Get-Date) -lt $limite) {
        if (Test-PuertoEscuchando -Puerto $Puerto -Protocolo $Protocolo) { return $true }
        if ($Proceso) { try { $Proceso.Refresh() } catch { }; if ($Proceso.HasExited) { return $false } }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Show-FalloCore {
    <# Ensena en pantalla por que murio el servidor del juego, sin abrir logs. #>
    $logCore = Join-Path $DIR_LOGS 'core.log'
    $causa = $null
    if (Test-Path $logCore) { $causa = Select-String -Path $logCore -Pattern 'Caused by' -ErrorAction SilentlyContinue | Select-Object -Last 1 }
    if ($causa) { Write-Host ('       ' + ($causa.Line -replace '^.*Caused by', 'Caused by').Trim()) -ForegroundColor Red }
    $errCore = Join-Path $DIR_LOGS 'core.err.log'
    if (Test-Path $errCore) {
        if (Select-String -Path $errCore -Pattern 'Could not reserve enough space|Could not create the Java Virtual Machine|Error occurred during initialization' -Quiet -ErrorAction SilentlyContinue) {
            Write-Host '       Java no consigue la memoria que pide: cierra programas o anade RAM a este PC.' -ForegroundColor Red
        }
        Get-Content $errCore -Tail 3 -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch 'Picked up JAVA_TOOL_OPTIONS|illegal' } | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }
    }
    Write-Host '       Mira logs\core.log y busca la primera linea "Caused by".' -ForegroundColor Red
    Write-Host '       Para mandar el detalle al organizador: .\scripts\diagnostico.ps1 (o el boton Diagnostico del panel).' -ForegroundColor Red
}

# =====================================================================
#  1. BASE DE DATOS
# =====================================================================
Write-Host ''
Write-Host '  1. BASE DE DATOS' -ForegroundColor White

if (Test-PuertoEscuchando -Puerto $DB_PORT) {
    Write-Ok 'Ya estaba arrancada.'
} else {
    $mysqld = Get-RutaMysql -Programa 'mysqld'
    if (-not $mysqld) { Write-Fallo 'No encuentro mysqld.exe. Ejecuta setup.ps1 primero.'; exit 1 }

    $datos = Join-Path $DIR_DB 'data'
    if (-not (Test-Path (Join-Path $datos 'mysql'))) {
        Write-Fallo 'La base de datos no esta inicializada. Ejecuta setup.ps1 primero.'
        exit 1
    }

    Write-Paso 'Arrancando MySQL...'
    $pMysql = Start-Servicio -Nombre 'mysql' -Ejecutable $mysqld `
        -Argumentos @((Format-Arg '--datadir' $datos), "--port=$DB_PORT", '--console', '--no-monitor')
    # --no-monitor (28-sep): MySQL 8 en Windows arranca un proceso "monitor" que
    # lanza al servidor real; sin el, el PID que se guarda es el que escucha y
    # stop.ps1 lo para de verdad.

    # 120 s y no 60: con el disco ocupado (antivirus recien descomprimido el
    # paquete, disco lento) MySQL ha tardado 83 s en un PC rapido.
    if (-not (Wait-Puerto -Puerto $DB_PORT -Segundos 120 -Proceso $pMysql)) {
        Write-Fallo 'MySQL no arranco en 2 min. Mira logs\mysql.err.log'
        $errMysql = Join-Path $DIR_LOGS 'mysql.err.log'
        if (Test-Path $errMysql) { Get-Content $errMysql -Tail 5 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray } }
        Write-Host '       Para mandar el detalle al organizador: .\scripts\diagnostico.ps1 (o el boton Diagnostico del panel).' -ForegroundColor Red
        exit 1
    }
    Write-Ok "MySQL escuchando en $DB_PORT."
}

# =====================================================================
#  2. LA IP EN LA BASE DE DATOS  (el paso critico)
# =====================================================================
Write-Host ''
Write-Host '  2. DIRECCIONES PARA LOS CLIENTES' -ForegroundColor White

try {
    $sql = @"
INSERT INTO parameter (name, value) VALUES
  ('SERVER_ADDRESS',  'http://${Ip}:$PUERTO_CORE'),
  ('UDP_FREEROAM_IP', '$Ip'),
  ('UDP_RACE_IP',     '$Ip'),
  ('XMPP_IP',         '$Ip'),
  ('MODDING_ENABLED',   'true'),
  ('MODDING_BASE_PATH', 'http://${Ip}:$PUERTO_WEB/modnet'),
  ('MODDING_SERVER_ID', 'crazy-server'),
  ('MODDING_FEATURES',  '')
ON DUPLICATE KEY UPDATE value = VALUES(value);
"@
    Invoke-Mysql -Sql $sql | Out-Null
    Write-Ok "Direcciones actualizadas a $Ip (juego, mundo abierto, carreras y chat)."

    # Limpieza de sesiones fantasma.
    #
    # Si el servidor se cerro a lo bruto (corte de luz, stop.ps1 -Forzar, cerrar
    # la ventana), quedan filas de la sesion anterior en online_users. Al
    # arrancar, el servidor intenta registrarse otra vez y choca contra su
    # propia fila huerfana:
    #
    #   Duplicate entry '1788395782' for key 'online_users.PRIMARY'
    #
    # ...y ABORTA EL DESPLIEGUE ENTERO. El puerto 8080 llega a abrirse (es la
    # consola interna), asi que parece medio arrancado y el error real queda
    # sepultado en el log. Vaciarlo aqui cuesta nada: nadie puede estar
    # conectado todavia, porque el servidor aun no ha arrancado.
    try {
        Invoke-Mysql -Sql 'DELETE FROM online_users;' | Out-Null
        Write-Ok 'Sesiones de la vez anterior limpiadas.'
    } catch {
        # Si la tabla no existe en este esquema, no pasa nada.
    }
} catch {
    Write-Aviso "No pude actualizar las direcciones: $($_.Exception.Message)"
    Write-Host '       Si el esquema aun no esta importado esto es normal la primera vez.' -ForegroundColor Yellow
    Write-Host '       Pero si el servidor ya funcionaba, PARA: los jugadores no se veran.' -ForegroundColor Yellow
}

# =====================================================================
#  3. CHAT XMPP
# =====================================================================
Write-Host ''
Write-Host '  3. CHAT XMPP' -ForegroundColor White

# Se prefiere el lanzador portable: busca una JRE dentro de la carpeta antes
# que el Java del sistema (que suele ser 17 y con ese Openfire no arranca).
$openfire = Join-Path $DIR_SERVER 'openfire\bin\openfire-portable.bat'
if (-not (Test-Path $openfire)) { $openfire = Join-Path $DIR_SERVER 'openfire\bin\openfire.bat' }

# ---------------------------------------------------------------------
#  DOMINIO XMPP = IP DE HOY (obligatorio para que el chat funcione)
#
#  Openfire anuncia un dominio propio. El juego recibe el parametro XMPP_IP y
#  busca la sala de chat en "conference.<XMPP_IP>". Si el dominio de Openfire
#  es otro (por ejemplo 127.0.0.1), trata ese nombre como un servidor REMOTO,
#  intenta federarse con el y falla: el servidor arranca sin quejarse, pero
#  nadie entra en la sala, y ni el chat ni los avisos del megafono llegan al
#  juego. Se ve en openfire\logs\warn.log como "Unable to create a socket
#  connection to XMPP domain 'conference.192.168.1.235'".
#  (Durante el desarrollo se creyo que no hacia falta que coincidieran porque
#  el servidor del juego desplegaba igual. Era falso: desplegar si, chat no.)
#
#  El dominio NO esta en openfire.xml. Vive como propiedad `xmpp.domain` en
#  la base HSQLDB embebida (embedded-db\openfire.script, texto plano) y, si
#  hubo cambios desde el ultimo cierre limpio, tambien en su redo-log
#  (embedded-db\openfire.log). Se reescribe en los dos, byte a byte (Latin-1,
#  sin tocar nada mas), con Openfire PARADO y justo antes de arrancarlo. Asi
#  el chat funciona en cualquier PC y con cualquier IP sin configurar nada.
function Get-DominioXmpp {
    $fichero = Join-Path $DIR_SERVER 'openfire\embedded-db\openfire.script'
    if (-not (Test-Path $fichero)) { return $null }
    $m = [regex]::Match([System.IO.File]::ReadAllText($fichero, [System.Text.Encoding]::GetEncoding(28591)),
                        "'xmpp\.domain','([^']*)'")
    if ($m.Success) { return $m.Groups[1].Value } else { return $null }
}

function Set-DominioXmpp {
    param([string] $Dominio)
    $latin1  = [System.Text.Encoding]::GetEncoding(28591)
    $patron  = "('xmpp\.domain',')([^']*)(')"
    $cambios = 0
    foreach ($nombre in @('openfire.script', 'openfire.log')) {
        $fichero = Join-Path $DIR_SERVER "openfire\embedded-db\$nombre"
        if (-not (Test-Path $fichero)) { continue }
        $texto = [System.IO.File]::ReadAllText($fichero, $latin1)
        if (-not [regex]::IsMatch($texto, $patron)) { continue }
        $nuevo = [regex]::Replace($texto, $patron, ('${1}' + $Dominio + '${3}'))
        if ($nuevo -ne $texto) {
            Copy-Item -LiteralPath $fichero -Destination "$fichero.anterior" -Force
            [System.IO.File]::WriteAllText($fichero, $nuevo, $latin1)
            $cambios++
        }
    }
    return $cambios
}

if (Test-PuertoEscuchando -Puerto $PUERTO_XMPP) {
    Write-Ok 'Ya estaba arrancado.'
    $dominio = Get-DominioXmpp
    if ($dominio -and $dominio -ne $Ip) {
        Write-Aviso "Openfire lleva el dominio $dominio y la IP de hoy es ${Ip}: el chat NO funcionara."
        Write-Host '       Pulsa PARAR y luego ARRANCAR para que se ajuste solo.' -ForegroundColor Yellow
    }
} elseif (Test-Path $openfire) {
    try {
        $dominio = Get-DominioXmpp
        if ($dominio -eq $Ip) {
            Write-Ok "Dominio XMPP: $Ip (coincide con la IP de hoy)."
        } elseif ((Set-DominioXmpp -Dominio $Ip) -gt 0) {
            Write-Ok "Dominio XMPP ajustado: $dominio -> $Ip."
        } else {
            Write-Aviso 'No encontre la propiedad xmpp.domain en la base de Openfire; el chat puede no funcionar.'
        }
    } catch {
        Write-Aviso "No pude ajustar el dominio XMPP: $($_.Exception.Message). El chat puede no funcionar."
    }
    Write-Paso 'Arrancando Openfire...'
    $pOf = Start-Servicio -Nombre 'openfire' -Ejecutable $openfire `
        -Directorio (Join-Path $DIR_SERVER 'openfire')
    if (Wait-Puerto -Puerto $PUERTO_XMPP -Segundos 150 -Proceso $pOf) {
        Write-Ok "Openfire escuchando en $PUERTO_XMPP."
        # El PID apuntado es el cmd del .bat; se apunta el java real (su hijo)
        # para que stop.ps1 lo pare a la primera.
        try {
            $hijo = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($pOf.Id) and Name='java.exe'" -ErrorAction Stop | Select-Object -First 1
            if ($hijo) { $script:pids['openfire'] = [int]$hijo.ProcessId }
        } catch { }
        $limiteOf = (Get-Date).AddSeconds(120)
        while (-not (Test-OpenfireListo) -and (Get-Date) -lt $limiteOf) { Start-Sleep -Seconds 3 }
        if (Test-OpenfireListo) { Write-Ok 'Openfire listo (plugins cargados).' }
        else { Write-Aviso 'Openfire abrio el puerto pero no confirma sus plugins en 2 min; se sigue, con reintento si el juego no engancha.' }
    } else {
        # Se creia que sin chat se jugaba igual. Falso: el servidor del juego se
        # conecta a Openfire al desplegar y sin el muere (28-sep).
        Write-Fallo 'Openfire no arranco en 150 s, y sin el el servidor del juego no puede desplegar.'
        Write-Host '       Mira logs\openfire.log y logs\openfire.err.log (y server\openfire\logs\error.log).' -ForegroundColor Red
        Write-Host '       Para mandar el detalle al organizador: .\scripts\diagnostico.ps1 (o el boton Diagnostico del panel).' -ForegroundColor Red
        exit 1
    }
} else {
    Write-Fallo 'Falta server\openfire\: el servidor del juego no arranca sin el. Copia la carpeta entera otra vez.'
    exit 1
}

# =====================================================================
#  4. SERVIDOR DEL JUEGO
# =====================================================================
Write-Host ''
Write-Host '  4. SERVIDOR DEL JUEGO' -ForegroundColor White

if (Test-PuertoEscuchando -Puerto $PUERTO_CORE) {
    Write-Ok 'Ya estaba arrancado.'
} else {
    $java = Get-RutaJava
    if (-not $java) { Write-Fallo 'No encuentro Java. Ejecuta setup.ps1 primero.'; exit 1 }

    $jar = Join-Path $DIR_SERVER 'core.jar'
    if (-not (Test-Path $jar)) { Write-Fallo "No encuentro $jar"; exit 1 }

    # La conexion a la base de datos se pasa por propiedades del sistema en vez
    # de editar el YAML: asi la misma carpeta vale en cualquier maquina y no
    # hay que tocar ficheros de configuracion al copiarla.
    $ds = 'thorntail.datasources.data-sources.SoapBoxDS'
    $argumentos = @(
        '-Xms512m', "-Xmx$XmxCore",
        "-D$ds.connection-url=jdbc:mysql://${DB_HOST}:$DB_PORT/$DB_NOMBRE`?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=Europe/Madrid",
        "-D$ds.user-name=$DB_USER",
        "-D$ds.password=$DB_PASS",
        "-Dthorntail.http.port=$PUERTO_CORE",
        "-Dthorntail.bind.address=0.0.0.0",
        '-jar', ('"{0}"' -f $jar)
    )

    Write-Paso 'Arrancando el servidor del juego (tarda entre 30 s y 2 min)...'
    $pCore = Start-Servicio -Nombre 'core' -Ejecutable $java -Argumentos $argumentos

    if ($SinEsperar) {
        Write-Aviso 'No se espera confirmacion (-SinEsperar). Comprueba con status.ps1.'
    } else {
        if (-not (Wait-Puerto -Puerto $PUERTO_CORE -Segundos 180 -Proceso $pCore)) {
            if ($pCore -and $pCore.HasExited) { Write-Fallo 'El servidor del juego murio nada mas arrancar.' }
            else { Write-Fallo 'El servidor del juego no abrio el puerto en 3 minutos.' }
            Show-FalloCore
            exit 1
        }

        # El puerto abierto no basta: el 8080 lo abre la consola interna mucho
        # antes de que el juego este desplegado. Hay que ver que la API responde.
        $url = "http://127.0.0.1:$PUERTO_CORE/Engine.svc/GetServerInformation"
        $ok  = Wait-Api -Url $url -Segundos 120

        # Reintento por la carrera de 'online_users'.
        #
        # El servidor guarda estadisticas en una tabla cuya clave es la marca de
        # tiempo EN SEGUNDOS. Si dos escrituras caen en el mismo segundo, la
        # segunda choca ("Duplicate entry ... for key 'online_users.PRIMARY'") y,
        # por ocurrir dentro de la transaccion de despliegue, TUMBA EL ARRANQUE
        # ENTERO. El puerto queda abierto (consola interna), asi que parece a
        # medias y el error real queda enterrado en el log.
        #
        # Es intermitente y depende de decimas de segundo. Un reintento lo
        # resuelve en la practica, porque la segunda vez caen en segundos
        # distintos.
        #
        # Y (28-sep) la carrera con Openfire: si el chat aun cargaba plugins
        # cuando el juego se conecto, el despliegue muere con "Failed to
        # connect to Openfire server ... not-authorized". Mismo remedio:
        # esperar a Openfire y relanzar una vez.
        $logCore = Join-Path $DIR_LOGS 'core.log'
        $motivo = $null
        if (-not $ok -and (Test-Path $logCore)) {
            if (Select-String -Path $logCore -Pattern 'online_users' -Quiet -ErrorAction SilentlyContinue) { $motivo = 'online_users' }
            elseif (Select-String -Path $logCore -Pattern 'Failed to connect to Openfire|not-authorized' -Quiet -ErrorAction SilentlyContinue) { $motivo = 'openfire' }
        }
        if (-not $ok -and $motivo) {
            if ($motivo -eq 'online_users') { Write-Aviso 'Choque de estadisticas al arrancar (fallo conocido e intermitente).' }
            else { Write-Aviso 'El servidor del juego se conecto al chat antes de que estuviera listo (fallo conocido).' }
            Write-Paso 'Limpiando y reintentando una vez...'

            $viejo = $pids['core']
            if ($viejo) { Stop-Process -Id $viejo -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 3
            if ($motivo -eq 'online_users') { try { Invoke-Mysql -Sql 'DELETE FROM online_users;' | Out-Null } catch { } }
            else {
                $limiteOf = (Get-Date).AddSeconds(120)
                while (-not (Test-OpenfireListo) -and (Get-Date) -lt $limiteOf) { Start-Sleep -Seconds 3 }
            }

            $pCore = Start-Servicio -Nombre 'core' -Ejecutable $java -Argumentos $argumentos
            if (Wait-Puerto -Puerto $PUERTO_CORE -Segundos 180 -Proceso $pCore) {
                $ok = Wait-Api -Url $url -Segundos 120
            }
        }

        if ($ok) { Write-Ok "Servidor del juego respondiendo en $PUERTO_CORE." }
        else {
            Write-Fallo 'El servidor del juego no llego a responder.'
            Show-FalloCore
            # Sin esto el resumen final decia "Servidor arrancado" con el juego caido,
            # y el panel y el organizador se lo creian.
            $script:huboFallo = $true
        }
    }
}

# =====================================================================
#  5. MUNDO ABIERTO Y CARRERAS
# =====================================================================
Write-Host ''
Write-Host '  5. MUNDO ABIERTO Y CARRERAS' -ForegroundColor White

$freeroam = Join-Path $DIR_SERVER 'freeroamd.exe'

# ---------------------------------------------------------------------
#  El mapa en vivo: origen del navegador.
#
#  El emisor de posiciones (FMS) del freeroam original comprueba la cabecera
#  Origin del navegador comparando TEXTO EXACTO con AllowedOrigin. Si el
#  organizador abre el mapa desde localhost, desde otra IP o con el nombre
#  del equipo, no coincide y el websocket se rechaza con un 403 SIN NINGUN
#  ERROR VISIBLE: el mapa se queda vacio y no hay pista de por que. Asi
#  paso en las pruebas del colega.
#
#  Por eso server\freeroamd.exe lleva un parche de tres lineas (fuente en
#  _build\freeroam, fms\fms.go): con AllowedOrigin = "*" acepta cualquier
#  origen. En una LAN privada no hay nada que proteger ahi. Aqui se deja
#  siempre en "*" antes de arrancarlo (lee el fichero al iniciarse).
# ---------------------------------------------------------------------
$configFreeroam = Join-Path $DIR_SERVER 'config.toml'
if (Test-Path $configFreeroam) {
    try {
        $toml   = Get-Content $configFreeroam -Raw
        $nuevo  = $toml `
            -replace 'ListenAddress\s*=\s*"127\.0\.0\.1:6996"', 'ListenAddress = "0.0.0.0:6996"' `
            -replace 'AllowedOrigin\s*=\s*"[^"]*"', 'AllowedOrigin = "*"'

        if ($nuevo -ne $toml) {
            [System.IO.File]::WriteAllText($configFreeroam, $nuevo, (New-Object System.Text.UTF8Encoding $false))
            Write-Ok 'Mapa en vivo: acepta el navegador desde cualquier direccion.'
        }
    } catch {
        Write-Aviso "No pude configurar el mapa en vivo: $($_.Exception.Message)"
    }
}

if (Test-PuertoEscuchando -Puerto $PUERTO_FREEROAM -Protocolo 'UDP') {
    Write-Ok 'Mundo abierto ya estaba arrancado.'
} elseif (Test-Path $freeroam) {
    Start-Servicio -Nombre 'freeroam' -Ejecutable $freeroam | Out-Null
    Start-Sleep -Seconds 2
    if (Test-PuertoEscuchando -Puerto $PUERTO_FREEROAM -Protocolo 'UDP') {
        Write-Ok "Mundo abierto escuchando en $PUERTO_FREEROAM/udp."
    } else {
        Write-Fallo 'El mundo abierto no abrio su puerto. Mira logs\freeroam.err.log'
        $script:huboFallo = $true
    }
} else { Write-Fallo "No encuentro $freeroam"; $script:huboFallo = $true }

$race = Join-Path $DIR_SERVER 'race.exe'
if (Test-PuertoEscuchando -Puerto $PUERTO_RACE -Protocolo 'UDP') {
    Write-Ok 'Carreras ya estaba arrancado.'
} elseif (Test-Path $race) {
    Start-Servicio -Nombre 'race' -Ejecutable $race | Out-Null
    Start-Sleep -Seconds 2
    if (Test-PuertoEscuchando -Puerto $PUERTO_RACE -Protocolo 'UDP') {
        Write-Ok "Carreras escuchando en $PUERTO_RACE/udp."
    } else {
        # Sin carreras no hay fiesta: cuenta como fallo, no como aviso (28-sep).
        Write-Fallo 'El servidor de carreras no abrio su puerto. Mira logs\race.err.log'
        $script:huboFallo = $true
    }
} else { Write-Fallo "No encuentro $race"; $script:huboFallo = $true }

# =====================================================================
#  6. WEB DE REGISTRO
# =====================================================================
Write-Host ''
Write-Host '  6. REGISTRO Y DESCARGAS' -ForegroundColor White

$app = Join-Path $DIR_WEB 'app.py'
if (Test-PuertoEscuchando -Puerto $PUERTO_WEB) {
    Write-Ok 'Ya estaba arrancada.'
} elseif (Test-Path $app) {
    $python = Join-Path $DIR_RUNTIME 'python\python.exe'
    if (-not (Test-Path $python)) {
        $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
        $python = if ($cmd) { $cmd.Source } else { $null }
    }
    if ($python) {
        Start-Servicio -Nombre 'web' -Ejecutable $python -Argumentos @($app) -Directorio $DIR_WEB | Out-Null
        if (Wait-Puerto -Puerto $PUERTO_WEB -Segundos 30) {
            Write-Ok "Web escuchando en $PUERTO_WEB."
        } else {
            Write-Aviso 'La web no arranco. Mira logs\web.err.log'
        }
    } else { Write-Aviso 'No encuentro Python: la web no arranca.' }
} else {
    Write-Aviso 'Aun no existe webregister\app.py. Se arranca sin web de registro.'
}

# =====================================================================
#  7. LAUNCHER PRECONFIGURADO
# =====================================================================
Write-Host ''
Write-Host '  7. LAUNCHER' -ForegroundColor White

if (-not (Test-Path $DIR_LAUNCHER)) { New-Item -ItemType Directory -Path $DIR_LAUNCHER -Force | Out-Null }

# Formato exacto que espera el launcher: un array JSON con name / ip_address /
# category. ip_address es la URL COMPLETA terminada en /Engine.svc, sin barra
# final: el launcher le concatena las rutas directamente.
# category: se usa 'CUSTOM', que es EXACTAMENTE lo que el propio launcher
# escribe cuando anades un servidor a mano. El campo es texto libre y admite
# cualquier cosa, pero las categorias que el launcher conoce son solo
# SBRW, DEV, CUSTOM, OFFLINE y DEBUG. Poner 'LAN' funcionaba, pero por
# casualidad, no por estar soportado: no merece la pena el riesgo el dia del evento.
$servidores = @(
    @{
        name       = 'Crazy Server'
        ip_address = "http://${Ip}:$PUERTO_CORE/Engine.svc"
        category   = 'CUSTOM'
    }
)
$json = ConvertTo-Json -InputObject $servidores -Depth 4
[System.IO.File]::WriteAllText(
    (Join-Path $DIR_LAUNCHER 'Servers-Custom.json'),
    $json,
    (New-Object System.Text.UTF8Encoding $false))

# ---------------------------------------------------------------------
#  OJO: el launcher NO lee este fichero de su propia carpeta.
#
#  Comprobado en la maquina real con la version 2.2.4: la lista de servidores
#  vive en
#      %APPDATA%\Soapbox Race World\Launcher\Servers-Custom.json
#
#  Dejarlo junto al .exe no sirve de nada: el launcher lo ignora y el servidor
#  de la LAN no aparece en el desplegable. Por eso se genera tambien un .bat
#  que lo instala en el sitio correcto de un doble clic. Con 50 maquinas, la
#  alternativa es que 50 personas lo anadan a mano con el boton "+".
# ---------------------------------------------------------------------
$bat = @"
@echo off
chcp 65001 >nul
title Anadir Crazy Server al launcher

echo.
echo   Anadiendo Crazy Server al launcher...
echo.

set "DESTINO=%APPDATA%\Soapbox Race World\Launcher"
if not exist "%DESTINO%" mkdir "%DESTINO%"

rem Copia de seguridad de la lista anterior, por si tenias otros servidores.
if exist "%DESTINO%\Servers-Custom.json" (
    copy /Y "%DESTINO%\Servers-Custom.json" "%DESTINO%\Servers-Custom.json.bak" >nul
)

copy /Y "%~dp0Servers-Custom.json" "%DESTINO%\Servers-Custom.json" >nul

if errorlevel 1 (
    echo   [X] No se pudo. Anade el servidor a mano con el boton "+" del launcher:
    echo       http://${Ip}:$PUERTO_CORE/Engine.svc
) else (
    echo   [OK] Listo. Abre el launcher y elige "Crazy Server" en el desplegable de arriba.
)
echo.
pause
"@
[System.IO.File]::WriteAllText(
    (Join-Path $DIR_LAUNCHER 'Anadir-servidor-LAN.bat'),
    $bat,
    (New-Object System.Text.UTF8Encoding $false))

Write-Ok "Servidor apuntando a $Ip (con instalador para el launcher)."

# Se reempaqueta el launcher en gamefiles\ para que los jugadores se lo bajen
# de la web YA configurado con la IP de hoy. Son 7 MB: reempaquetarlo en cada
# arranque cuesta un segundo y evita el error clasico de repartir un launcher
# que apunta a la IP del evento anterior.
if (Test-Path (Join-Path $DIR_LAUNCHER 'SBRW.Launcher.exe')) {
    try {
        $zipLauncher = Join-Path $DIR_GAMEFILES 'Launcher-LAN.zip'
        if (Test-Path $zipLauncher) { Remove-Item $zipLauncher -Force }

        # SOLO el launcher, nunca el juego. Si alguien apunta este launcher a una
        # carpeta dentro de su propia carpeta, el launcher se descarga ahi el juego
        # entero y aparece un GameFiles\ de 3 GB junto al .exe: sin este filtro, el
        # "launcher" que se reparte pasaba a pesar 2,2 GB (ocurrio el 2026-09-06).
        #
        # Settings.ini tampoco viaja: lleva la ruta de instalacion de ESTE equipo.
        # Sin el, el launcher le pregunta al jugador donde tiene el juego, que es
        # exactamente lo que queremos que pase en su maquina.
        $fuera  = @('GameFiles', 'Settings.ini', 'Settings.ini.anterior', '.data', 'MODS', '.links')
        $piezas = @(Get-ChildItem -LiteralPath $DIR_LAUNCHER -Force |
                    Where-Object { $fuera -notcontains $_.Name })
        if ($piezas.Count -eq 0) { throw 'la carpeta del launcher esta vacia' }

        Compress-Archive -Path $piezas.FullName `
                         -DestinationPath $zipLauncher -CompressionLevel Fastest
        $mb = [math]::Round((Get-Item $zipLauncher).Length / 1MB, 1)
        Write-Ok "Launcher-LAN.zip actualizado ($mb MB, listo para descargar desde la web)."
    } catch {
        Write-Aviso "No pude reempaquetar el launcher: $($_.Exception.Message)"
    }
}

# =====================================================================
#  GUARDAR PIDS Y RESUMEN
# =====================================================================
$pids | ConvertTo-Json | Set-Content -Path $FICHERO_PIDS -Encoding UTF8
# (28-sep) El panel solo mira puertos, y el 8080 lo abre la consola interna del
# servidor del juego aunque el despliegue haya muerto: con esto sabe la verdad.
$estado = @{ core = $(if ($script:huboFallo) { 'fallo' } else { 'ok' }); ip = $Ip; fecha = (Get-Date -Format 's') }
try { $estado | ConvertTo-Json | Set-Content -Path (Join-Path $DIR_LOGS 'estado.json') -Encoding UTF8 } catch { }
Write-Registro "start.ps1 - servidor arrancado en $Ip"

Write-Host ''
if ($script:huboFallo) {
    Write-Titulo 'Servidor arrancado CON FALLOS'
    Write-Host ''
    Write-Host '    El SERVIDOR DEL JUEGO no ha levantado: nadie podra entrar.' -ForegroundColor Red
    Write-Host '    Prueba: .\stop.ps1, espera diez segundos y .\start.ps1 otra vez.' -ForegroundColor Red
    Write-Host '    Si se repite, mira logs\core.log (primera linea "Caused by").' -ForegroundColor Red
    Write-Host ''
    Write-Registro "start.ps1 - ARRANQUE CON FALLOS en $Ip (core caido)"
    exit 1
}
Write-Titulo 'Servidor arrancado'
Write-Host ''
Write-Host '    Da esto a los jugadores:' -ForegroundColor White
Write-Host ''
Write-Host '      Servidor  ' -NoNewline
Write-Host "http://${Ip}:$PUERTO_CORE/Engine.svc" -ForegroundColor Yellow
Write-Host '      Registro  ' -NoNewline
Write-Host "http://${Ip}:$PUERTO_WEB" -ForegroundColor Yellow
Write-Host ''
Write-Host '    Comprobar estado:  .\status.ps1' -ForegroundColor DarkGray
Write-Host '    Parar el servidor: .\stop.ps1' -ForegroundColor DarkGray
Write-Host ''
