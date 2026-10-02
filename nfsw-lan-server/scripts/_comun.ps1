<#
    _comun.ps1 - configuracion y utilidades compartidas por todos los scripts.

    No se ejecuta suelto: los demas scripts lo cargan con dot-sourcing:
        . (Join-Path $PSScriptRoot '_comun.ps1')

    Aqui vive TODO lo que se configura una sola vez. Si hay que cambiar un
    puerto o una contrasena, se cambia aqui y en credenciales.txt, y punto.
#>

# =====================================================================
#  CONFIGURACION
# =====================================================================

# --- Rutas (todo relativo a la carpeta del proyecto: es portable) -----
$script:RAIZ      = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:DIR_SERVER    = Join-Path $RAIZ 'server'
$script:DIR_RUNTIME   = Join-Path $RAIZ 'runtime'
$script:DIR_DB        = Join-Path $RAIZ 'db'
$script:DIR_WEB       = Join-Path $RAIZ 'webregister'
$script:DIR_GAMEFILES = Join-Path $RAIZ 'gamefiles'
$script:DIR_BACKUP    = Join-Path $RAIZ 'gamefiles-backup'
$script:DIR_LAUNCHER  = Join-Path $RAIZ 'launcher'
$script:DIR_MODS      = Join-Path $RAIZ 'mods'
$script:DIR_LOGS      = Join-Path $RAIZ 'logs'

# --- Base de datos ----------------------------------------------------
# Credenciales fijas y simples: esto es una LAN cerrada de evento, no
# produccion. Estan tambien en credenciales.txt, en texto plano y a
# proposito, para que cualquiera pueda operar el servidor.
$script:DB_HOST   = '127.0.0.1'
$script:DB_PORT   = 3306
$script:DB_NOMBRE = 'SOAPBOX'
$script:DB_XMPP   = 'openfire'
$script:DB_USER   = 'nfsw_user'
$script:DB_PASS   = 'LanParty2026!'
$script:DB_ROOT   = 'root'
$script:DB_ROOTPW = 'LanParty2026!'

# --- Puertos ----------------------------------------------------------
# De cara a los jugadores (hay que abrirlos en el firewall):
$script:PUERTO_CORE     = 8080   # TCP  API del juego  /Engine.svc
$script:PUERTO_XMPP     = 5222   # TCP  chat y eventos in-game
$script:PUERTO_FREEROAM = 9999   # UDP  mundo abierto
$script:PUERTO_RACE     = 9998   # UDP  sincronizacion de carreras
$script:PUERTO_WEB      = 5000   # TCP  registro y descargas
$script:PUERTO_MAPA     = 6996   # TCP  websocket del mapa en vivo
                                 #      OJO: la pagina /mapa se conecta a este
                                 #      puerto desde el navegador de CADA equipo,
                                 #      no desde el servidor. Si no esta abierto
                                 #      en el firewall, el mapa sale en blanco
                                 #      sin ningun error a la vista.
# Solo locales al servidor (NO se abren al exterior):
$script:PUERTO_OF_ADMIN = 9090   # consola de administracion de Openfire

# --- Procesos ---------------------------------------------------------
# Nombre logico -> como se arranca y como se reconoce. El orden importa:
# se arranca de arriba abajo y se para de abajo arriba.
$script:SERVICIOS = @(
    @{ Nombre='mysql';    Etiqueta='Base de datos';          Puerto=$DB_PORT;         Protocolo='TCP' }
    @{ Nombre='openfire'; Etiqueta='Chat XMPP';              Puerto=$PUERTO_XMPP;     Protocolo='TCP' }
    @{ Nombre='core';     Etiqueta='Servidor del juego';     Puerto=$PUERTO_CORE;     Protocolo='TCP' }
    @{ Nombre='freeroam'; Etiqueta='Mundo abierto';          Puerto=$PUERTO_FREEROAM; Protocolo='UDP' }
    @{ Nombre='race';     Etiqueta='Carreras';               Puerto=$PUERTO_RACE;     Protocolo='UDP' }
    @{ Nombre='web';      Etiqueta='Registro y descargas';   Puerto=$PUERTO_WEB;      Protocolo='TCP' }
)

# Fichero donde start.ps1 apunta los PID, para que stop.ps1 sepa a quien matar.
$script:FICHERO_PIDS = Join-Path $DIR_LOGS 'procesos.json'


# =====================================================================
#  UTILIDADES
# =====================================================================

function Write-Titulo {
    param([Parameter(Mandatory)][string] $Texto)
    Write-Host ''
    Write-Host "  $Texto" -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * $Texto.Length)) -ForegroundColor DarkCyan
}

function Write-Paso {
    param([Parameter(Mandatory)][string] $Texto)
    Write-Host "  ... $Texto" -ForegroundColor DarkGray
}

function Write-Ok {
    param([Parameter(Mandatory)][string] $Texto)
    Write-Host "  [ok] $Texto" -ForegroundColor Green
}

function Write-Aviso {
    param([Parameter(Mandatory)][string] $Texto)
    Write-Host "  [!]  $Texto" -ForegroundColor Yellow
    # (28-sep) Los avisos y fallos quedan tambien en logs\servidor.log: hasta hoy
    # solo vivian en la ventana negra, y "me da un error" no se podia depurar.
    try { Write-Registro "[!] $Texto" } catch { }
}

function Write-Fallo {
    param([Parameter(Mandatory)][string] $Texto)
    Write-Host "  [X]  $Texto" -ForegroundColor Red
    try { Write-Registro "[X] $Texto" } catch { }
}

function Invoke-Nativo {
    <#
    .SYNOPSIS
        Ejecuta un programa nativo y devuelve su salida y su codigo, sin que
        stderr aborte el script.
    .DESCRIPTION
        (28-sep) En Windows PowerShell 5.1, con $ErrorActionPreference = 'Stop',
        CUALQUIER linea que un programa escriba por stderr (un simple aviso de
        mysql o de net) se convierte en excepcion terminante y mata el script;
        en PowerShell 7 no pasa. Reproducido: setup.ps1 moria en el PC ajeno
        al crear los esquemas. Aqui la preferencia se pone en 'Continue' solo
        dentro de la funcion.
    #>
    param(
        [Parameter(Mandatory)][string]   $Exe,
        [string[]] $Argumentos = @()
    )
    $ErrorActionPreference = 'Continue'
    $sal = & $Exe @Argumentos 2>&1
    [pscustomobject]@{
        Salida = (@($sal | ForEach-Object { "$_" }) -join "`n")
        Codigo = $LASTEXITCODE
    }
}

function Test-EsAdministrador {
    <# Devuelve $true si la sesion actual tiene privilegios de administrador. #>
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrador {
    <#
    .SYNOPSIS
        Corta la ejecucion si no somos administrador, explicando por que hace falta.
    #>
    param([string] $Motivo = 'este script necesita privilegios de administrador')
    if (-not (Test-EsAdministrador)) {
        Write-Host ''
        Write-Fallo "Faltan privilegios: $Motivo."
        Write-Host '       Cierra esta ventana y abre PowerShell como administrador' -ForegroundColor Red
        Write-Host '       (clic derecho -> Ejecutar como administrador).' -ForegroundColor Red
        Write-Host ''
        exit 1
    }
}

function Get-IpLan {
    <#
    .SYNOPSIS
        Devuelve la IP de la LAN de esta maquina (la que hay que dar a los clientes).
    .DESCRIPTION
        Descarta loopback, APIPA (169.254.x) y adaptadores virtuales de Hyper-V,
        WSL, VirtualBox y VMware, que son la causa clasica de repartir una IP
        por la que nadie puede conectar. Si quedan varias, gana la que tenga
        puerta de enlace configurada.
    #>
    $candidatas = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and
            $_.PrefixOrigin -ne 'WellKnown'
        }

    # Tambien las VPN de malla (ZeroTier, Tailscale, Radmin, Hamachi...): dan una
    # IP 10.x/100.x que parece de LAN pero por la que solo llegan los que estan
    # en esa misma VPN. En el primer equipo ajeno salio 10.243.x.x (ZeroTier) y
    # habria dejado fuera a todos los del cable.
    $virtuales = 'vEthernet|WSL|Loopback|VirtualBox|VMware|Hyper-V|Bluetooth|TAP|TUN|' +
                 'ZeroTier|Tailscale|Radmin|Hamachi|OpenVPN|WireGuard|Npcap|Docker|Mullvad|NordLynx'
    $fisicas = $candidatas | Where-Object {
        $alias = $_.InterfaceAlias
        $desc  = (Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue).InterfaceDescription
        $alias -notmatch $virtuales -and "$desc" -notmatch $virtuales
    }
    if (-not $fisicas) { $fisicas = $candidatas }

    # Preferimos la interfaz con puerta de enlace y, si hay varias, la de menor
    # metrica: es la que Windows usa de verdad para salir a la red.
    $conGateway = @($fisicas | ForEach-Object {
        $ruta = Get-NetRoute -InterfaceIndex $_.InterfaceIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                Sort-Object RouteMetric | Select-Object -First 1
        if ($ruta) { [pscustomobject]@{ Ip = $_.IPAddress; Metrica = [int]$ruta.RouteMetric + [int]$ruta.InterfaceMetric } }
    } | Sort-Object Metrica)

    if ($conGateway.Count -gt 0) { return $conGateway[0].Ip }
    $primera = $fisicas | Select-Object -First 1
    if (-not $primera) { return $null }
    return $primera.IPAddress
}

function Test-PuertoEscuchando {
    <#
    .SYNOPSIS
        Comprueba si algo esta escuchando en un puerto local.
    .PARAMETER Protocolo
        'TCP' o 'UDP'. En UDP no existe el concepto de "escucha" como en TCP,
        asi que se mira si hay un endpoint abierto (que es lo equivalente).
    #>
    param(
        [Parameter(Mandatory)][int]    $Puerto,
        [ValidateSet('TCP','UDP')][string] $Protocolo = 'TCP'
    )
    if ($Protocolo -eq 'TCP') {
        return [bool](Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue)
    }
    return [bool](Get-NetUDPEndpoint -LocalPort $Puerto -ErrorAction SilentlyContinue)
}

function Get-PidEnPuerto {
    <# Devuelve el PID del proceso que ocupa un puerto, o $null. #>
    param(
        [Parameter(Mandatory)][int]    $Puerto,
        [ValidateSet('TCP','UDP')][string] $Protocolo = 'TCP'
    )
    if ($Protocolo -eq 'TCP') {
        $c = Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    } else {
        $c = Get-NetUDPEndpoint -LocalPort $Puerto -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($c) { return $c.OwningProcess }
    return $null
}

function Get-RutaMysql {
    <# Localiza mysql.exe / mysqld.exe: primero el portable de runtime\, luego el del sistema. #>
    param([ValidateSet('mysql','mysqld','mysqldump','mysqladmin')][string] $Programa = 'mysql')
    $portable = Join-Path $DIR_RUNTIME "mysql\bin\$Programa.exe"
    if (Test-Path $portable) { return $portable }
    $enPath = Get-Command "$Programa.exe" -ErrorAction SilentlyContinue
    if ($enPath) { return $enPath.Source }
    return $null
}

function Get-RutaJava {
    <#
    .SYNOPSIS
        Localiza un java.exe que SIRVA para arrancar el servidor del juego.
    .DESCRIPTION
        Ojo: no vale cualquier Java. El servidor usa Thorntail, que es de la
        epoca de Java 8-11 y NO arranca con Java 17 o superior. Como en casi
        cualquier equipo moderno el Java del sistema es 17 o mas nuevo, aqui
        se busca en este orden:

          1. runtime\jre\      el JRE que viaja con la carpeta (lo ideal:
                               asi la carpeta no depende de la maquina)
          2. Un JDK 11 o 8 instalado en el sistema
          3. JAVA_HOME o el del PATH, avisando si es demasiado moderno
    #>
    $portable = Join-Path $DIR_RUNTIME 'jre\bin\java.exe'
    if (Test-Path $portable) { return $portable }

    # Buscamos un JDK compatible entre los instalados.
    $carpetas = @(
        'C:\Program Files\Eclipse Adoptium',
        'C:\Program Files\Java',
        'C:\Program Files\Microsoft',
        'C:\Program Files\Zulu'
    )
    foreach ($version in @('11', '8', '1.8', '10')) {
        foreach ($base in $carpetas) {
            if (-not (Test-Path $base)) { continue }
            $encontrado = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match "jdk-?$([regex]::Escape($version))\b" -or
                               $_.Name -match "jdk-?$([regex]::Escape($version))\." } |
                Select-Object -First 1
            if ($encontrado) {
                $exe = Join-Path $encontrado.FullName 'bin\java.exe'
                if (Test-Path $exe) { return $exe }
            }
        }
    }

    # Ultimo recurso: lo que haya. Puede que no arranque.
    $fallback = $null
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\java.exe'))) {
        $fallback = Join-Path $env:JAVA_HOME 'bin\java.exe'
    } else {
        $enPath = Get-Command 'java.exe' -ErrorAction SilentlyContinue
        if ($enPath) { $fallback = $enPath.Source }
    }
    if ($fallback) {
        Write-Aviso 'No encuentro un Java 8 ni 11. Uso el del sistema, pero si es'
        Write-Host '       Java 17 o superior el servidor del juego NO arrancara.' -ForegroundColor Yellow
        Write-Host '       Solucion: copia un JRE 11 en runtime\jre\' -ForegroundColor Yellow
    }
    return $fallback
}

function Invoke-Mysql {
    <#
    .SYNOPSIS
        Ejecuta SQL contra la base de datos y devuelve la salida.
    .PARAMETER Sql
        Sentencia a ejecutar.
    .PARAMETER ComoRoot
        Usa el usuario root en vez del usuario de la aplicacion.
    .PARAMETER BaseDatos
        Base de datos contra la que ejecutar. Por defecto SOAPBOX.
    #>
    param(
        [Parameter(Mandatory)][string] $Sql,
        [switch] $ComoRoot,
        [string] $BaseDatos = $DB_NOMBRE
    )
    $exe = Get-RutaMysql -Programa 'mysql'
    if (-not $exe) { throw 'No encuentro mysql.exe (ni portable ni en el PATH).' }

    $usuario = if ($ComoRoot) { $DB_ROOT }   else { $DB_USER }
    $clave   = if ($ComoRoot) { $DB_ROOTPW } else { $DB_PASS }

    # La contrasena viaja por MYSQL_PWD, no por --password: evita el aviso que
    # MySQL imprime por stderr (que con ErrorActionPreference='Stop' aborta
    # scripts enteros) y ademas no queda visible en la lista de procesos.
    $env:MYSQL_PWD = $clave
    $argumentos = @(
        "--host=$DB_HOST", "--port=$DB_PORT",
        "--user=$usuario",
        '--silent', '--skip-column-names'
    )
    if ($BaseDatos) { $argumentos += $BaseDatos }
    $argumentos += @('-e', $Sql)

    # MySQL escupe por stderr un aviso sobre poner la contrasena en la linea de
    # comandos. Es correcto pero aqui es ruido: la contrasena esta en
    # credenciales.txt a proposito. Se filtra para que la salida sea usable,
    # pero se dejan pasar los errores de verdad.
    try {
        $r = Invoke-Nativo -Exe $exe -Argumentos $argumentos
    } finally { $env:MYSQL_PWD = $null }

    # (28-sep) Antes no se miraba el codigo: bajo PowerShell 7 un error de mysql
    # pasaba como texto y start.ps1 decia "[ok] Direcciones actualizadas" con la
    # IP sin escribir.
    if ($r.Codigo -ne 0) { throw ('mysql devolvio {0}: {1}' -f $r.Codigo, $r.Salida) }
    $salida = @($r.Salida -split "`n")
    return ($salida | Where-Object {
        $_ -notmatch 'Using a password on the command line interface can be insecure' -and $_ -ne ''
    })
}

function Get-NumeroGamefiles {
    <# Cuenta los ficheros disponibles para descarga (recursivo). #>
    if (-not (Test-Path $DIR_GAMEFILES)) { return 0 }
    # version.txt no cuenta: la web lo ensena aparte, no como descarga (27-sep).
    return @(Get-ChildItem $DIR_GAMEFILES -Recurse -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -notin '.gitkeep', 'version.txt' }).Count
}

function Get-VersionGamefiles {
    <# Lee gamefiles\version.txt si existe. #>
    $f = Join-Path $DIR_GAMEFILES 'version.txt'
    if (Test-Path $f) { return (Get-Content $f -Raw).Trim() }
    return $null
}

function Format-Arg {
    <#
    .SYNOPSIS
        Entrecomilla el valor de un argumento del tipo --clave=valor.
    .DESCRIPTION
        Sin esto, cualquier ruta con un espacio se parte por la mitad. Es un
        fallo real y desconcertante: MySQL, al recibir --datadir=C:\NFS World\db,
        se queda con "C:\NFS" y aborta diciendo que el directorio no existe.

        Como la carpeta de este proyecto puede acabar en cualquier sitio
        ("Archivos de programa", "NFS World", el escritorio de alguien...),
        TODO argumento que lleve una ruta tiene que pasar por aqui.
    .EXAMPLE
        Format-Arg '--datadir' $ruta     ->  --datadir="C:\NFS World\db\data"
    #>
    param(
        [Parameter(Mandatory)][string] $Clave,
        [Parameter(Mandatory)][string] $Valor
    )
    return '{0}="{1}"' -f $Clave, $Valor
}

function Write-Registro {
    <#
    .SYNOPSIS
        Escribe una linea con marca de tiempo en un log de la carpeta logs\.
    #>
    param(
        [Parameter(Mandatory)][string] $Mensaje,
        [string] $Fichero = 'servidor.log'
    )
    if (-not (Test-Path $DIR_LOGS)) { New-Item -ItemType Directory -Path $DIR_LOGS -Force | Out-Null }
    $linea = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Mensaje
    Add-Content -Path (Join-Path $DIR_LOGS $Fichero) -Value $linea -Encoding UTF8
}
