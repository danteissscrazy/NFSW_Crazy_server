<#
.SYNOPSIS
    Prepara esta maquina para servir la LAN party. Se ejecuta UNA VEZ por equipo.

.DESCRIPTION
    Hace cuatro cosas, todas repetibles sin romper nada:

      1. Comprueba que estan los artefactos del servidor.
      2. Abre en el firewall de Windows los puertos que necesitan los jugadores.
      3. Inicializa la base de datos si es la primera vez (crea el directorio de
         datos, los esquemas y el usuario de la aplicacion).
      4. Prepara la web de registro.

    IDEMPOTENTE: se puede relanzar tantas veces como haga falta. Lo que ya
    este hecho se detecta y se salta.

    NECESITA ADMINISTRADOR (por las reglas del firewall).

.PARAMETER SaltarFirewall
    No toca el firewall. Util si lo gestionas por directiva de grupo o si ya
    sabes que esta abierto.

.PARAMETER SaltarBaseDatos
    No inicializa la base de datos.

.EXAMPLE
    .\setup.ps1
#>

[CmdletBinding()]
param(
    [switch] $SaltarFirewall,
    [switch] $SaltarBaseDatos
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_comun.ps1')

# (28-sep) Todo lo que se imprime queda en logs\arranque.txt: es lo que hay que
# pedir cuando en otro PC "da un error" y nadie apunto cual.
if (-not (Test-Path $DIR_LOGS)) { New-Item -ItemType Directory -Path $DIR_LOGS -Force | Out-Null }
try { Start-Transcript -Path (Join-Path $DIR_LOGS 'arranque.txt') -Append -Force | Out-Null } catch { }
Write-Registro "setup.ps1 - inicio (PS $($PSVersionTable.PSVersion), admin=$(Test-EsAdministrador))"

Write-Titulo 'NFS World LAN - Preparacion del servidor'

if (-not $SaltarFirewall) {
    Assert-Administrador -Motivo 'hay que crear reglas en el Firewall de Windows'
}

# =====================================================================
#  1. ARTEFACTOS
# =====================================================================
Write-Host ''
Write-Host '  1. ARTEFACTOS DEL SERVIDOR' -ForegroundColor White
Write-Host ''

# Los cuatro son imprescindibles. Openfire se creia opcional ("sin el se juega
# igual, solo sin chat"), pero es falso: el servidor del juego se conecta a
# Openfire al desplegar y sin el no arranca (28-sep, comprobado en su fuente).
$requeridos = @(
    @{ Ruta = Join-Path $DIR_SERVER 'core.jar';      Que = 'Servidor del juego'; Obligatorio = $true  }
    @{ Ruta = Join-Path $DIR_SERVER 'freeroamd.exe'; Que = 'Mundo abierto';      Obligatorio = $true  }
    @{ Ruta = Join-Path $DIR_SERVER 'race.exe';      Que = 'Carreras';           Obligatorio = $true  }
    @{ Ruta = Join-Path $DIR_SERVER 'openfire';      Que = 'Chat XMPP';          Obligatorio = $true  }
)

$faltan = @()
foreach ($r in $requeridos) {
    if (Test-Path $r.Ruta) {
        Write-Ok ('{0,-22} {1}' -f $r.Que, (Split-Path $r.Ruta -Leaf))
    } elseif ($r.Obligatorio) {
        Write-Fallo ('{0,-22} FALTA: {1}' -f $r.Que, $r.Ruta)
        $faltan += $r.Que
    } else {
        Write-Aviso ('{0,-22} no esta: se jugara SIN chat ni invitaciones.' -f $r.Que)
    }
}

if ($faltan.Count -gt 0) {
    Write-Host ''
    Write-Fallo "Faltan $($faltan.Count) artefactos imprescindibles. Esta carpeta esta incompleta."
    Write-Host '       Copiala otra vez desde el equipo donde se compilo.' -ForegroundColor Red
    exit 1
}

# (28-sep) Tres causas de "en el otro PC no arranca", comprobadas aqui porque es
# el unico paso que se ejecuta como administrador y el primero que se pulsa.

# Marca "descargado de internet": si el ZIP llego por el navegador, Telegram o
# Drive, Windows marca todo lo que sale de el y puede bloquear los .exe sin
# avisar. Quitar la marca es inofensivo y evita ese silencio.
try {
    $marcados = @(Get-ChildItem -LiteralPath $RAIZ -Recurse -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.Extension -in '.exe', '.dll', '.jar', '.bat', '.ps1', '.py', '.pyd' } |
                  Where-Object { Get-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue })
    if ($marcados.Count -gt 0) { $marcados | Unblock-File -ErrorAction SilentlyContinue; Write-Ok "Desbloqueados $($marcados.Count) ficheros marcados como descargados de internet." }
    else { Write-Ok 'Ningun fichero marcado como descargado de internet.' }
} catch { Write-Aviso "No pude revisar la marca de internet: $($_.Exception.Message)" }

# Carpeta sincronizada: MySQL no puede vivir dentro de OneDrive y similares.
$sincronizada = ($env:OneDrive -and $RAIZ.StartsWith($env:OneDrive, [System.StringComparison]::OrdinalIgnoreCase)) -or
                ($RAIZ -match '\\(OneDrive|Google Drive|Dropbox|iCloudDrive)\\')
if ($sincronizada) {
    Write-Fallo "Esta carpeta esta dentro de una carpeta sincronizada (OneDrive o similar): $RAIZ"
    Write-Host '       Mueve nfsw-lan-server a C:\CrazyServer (fuera de OneDrive) y vuelve a pulsar Preparar PC.' -ForegroundColor Red
    exit 1
}

# Puertos reservados por Windows (Hyper-V/WSL/Docker reservan rangos al azar).
try {
    $reservados = @()
    foreach ($linea in (& netsh interface ipv4 show excludedportrange protocol=tcp 2>&1)) {
        if ($linea -match '^\s*(\d+)\s+(\d+)') { $reservados += [pscustomobject]@{ De = [int]$matches[1]; A = [int]$matches[2] } }
    }
    $chocan = @()
    $puertosTcp = @($SERVICIOS | Where-Object { $_.Protocolo -eq 'TCP' } | ForEach-Object { @{ Etiqueta = $_.Etiqueta; Puerto = $_.Puerto } }) +
                  @(@{ Etiqueta = 'Consola de Openfire'; Puerto = $PUERTO_OF_ADMIN })
    foreach ($s in $puertosTcp) {
        foreach ($r in $reservados) { if ($s.Puerto -ge $r.De -and $s.Puerto -le $r.A) { $chocan += ('{0} ({1})' -f $s.Etiqueta, $s.Puerto) } }
    }
    if ($chocan.Count -gt 0) {
        Write-Aviso ('Windows tiene reservados puertos del servidor: ' + ($chocan -join ', ') + '. Se intenta liberar (net stop/start winnat)...')
        Invoke-Nativo -Exe 'net' -Argumentos @('stop', 'winnat') | Out-Null
        Invoke-Nativo -Exe 'net' -Argumentos @('start', 'winnat') | Out-Null
        Write-Host '       Si ARRANCAR sigue quejandose de puertos reservados, reinicia Windows.' -ForegroundColor Yellow
    } else { Write-Ok 'Ningun puerto del servidor reservado por Windows.' }
} catch { }

try {
    $ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    if ($ramGb -lt 4) { Write-Aviso "Este PC tiene $ramGb GB de RAM: el servidor arrancara con menos memoria y puede ir justo." }
    else { Write-Ok "RAM: $ramGb GB." }
} catch { }

# Runtime de Java (portable o del sistema)
$java = Get-RutaJava
if ($java) { Write-Ok "Java: $java" }
else {
    Write-Fallo 'No encuentro Java. Hace falta un JRE en runtime\jre\ o Java instalado.'
    exit 1
}

# =====================================================================
#  2. FIREWALL
# =====================================================================
Write-Host ''
Write-Host '  2. FIREWALL DE WINDOWS' -ForegroundColor White
Write-Host ''

if ($SaltarFirewall) {
    Write-Aviso 'Saltado por peticion (-SaltarFirewall).'
} else {
    # Estos seis son los que DEBEN estar abiertos. Si falta el UDP, los
    # jugadores entran al juego pero no se ven entre si: es el fallo mas
    # comun y el mas desconcertante, porque el login funciona.
    $puertos = @(
        @{ Nombre='Servidor del juego (HTTP)'; Puerto=$PUERTO_CORE;     Protocolo='TCP' }
        @{ Nombre='Chat XMPP';                 Puerto=$PUERTO_XMPP;     Protocolo='TCP' }
        @{ Nombre='Registro y descargas';      Puerto=$PUERTO_WEB;      Protocolo='TCP' }
        @{ Nombre='Mapa en vivo';              Puerto=$PUERTO_MAPA;     Protocolo='TCP' }
        @{ Nombre='Mundo abierto';             Puerto=$PUERTO_FREEROAM; Protocolo='UDP' }
        @{ Nombre='Carreras';                  Puerto=$PUERTO_RACE;     Protocolo='UDP' }
    )

    foreach ($p in $puertos) {
        $nombre = "NFSW LAN - $($p.Nombre) ($($p.Puerto)/$($p.Protocolo.ToLower()))"
        $existe = Get-NetFirewallRule -DisplayName $nombre -ErrorAction SilentlyContinue

        if ($existe) {
            if ($existe.Enabled -ne 'True') {
                Enable-NetFirewallRule -DisplayName $nombre
                Write-Ok "$nombre (reactivada)"
            } else {
                Write-Ok "$nombre (ya existia)"
            }
        } else {
            New-NetFirewallRule -DisplayName $nombre `
                -Direction Inbound -Action Allow `
                -Protocol $p.Protocolo -LocalPort $p.Puerto `
                -Profile Any -Enabled True | Out-Null
            Write-Ok "$nombre (creada)"
        }
    }
}

# =====================================================================
#  3. BASE DE DATOS
# =====================================================================
Write-Host ''
Write-Host '  3. BASE DE DATOS' -ForegroundColor White
Write-Host ''

if ($SaltarBaseDatos) {
    Write-Aviso 'Saltada por peticion (-SaltarBaseDatos).'
} else {
    $mysqld = Get-RutaMysql -Programa 'mysqld'
    if (-not $mysqld) {
        Write-Fallo 'No encuentro mysqld.exe. Deberia estar en runtime\mysql\bin\.'
        exit 1
    }

    # mysqld.exe necesita el runtime de Visual C++ (tres DLL). Van copiadas
    # junto al ejecutable para no depender de que el PC tenga instalado el
    # redistribuible. Si faltaran las dos copias, mysqld no arranca y Windows
    # lo cuenta con un dialogo modal que en un proceso oculto NO SE VE: se
    # esperaria 60 s y saldria un "no llego a arrancar" sin pista. Mejor
    # comprobarlo aqui y decirlo claro.
    $binMysql = Split-Path $mysqld -Parent
    $faltan = @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll') | Where-Object {
        -not (Test-Path (Join-Path $binMysql $_)) -and
        -not (Test-Path (Join-Path $env:SystemRoot "System32\$_"))
    }
    if ($faltan) {
        Write-Fallo ('Faltan DLL del runtime de Visual C++: ' + ($faltan -join ', '))
        Write-Host '       Instala "Microsoft Visual C++ 2015-2022 Redistributable (x64)"' -ForegroundColor Red
        Write-Host "       o copia esas DLL desde otro Windows a $binMysql" -ForegroundColor Red
        exit 1
    }

    $datos = Join-Path $DIR_DB 'data'

    if (Test-Path (Join-Path $datos 'mysql')) {
        Write-Ok 'La base de datos ya estaba inicializada (no se toca).'
    } else {
        Write-Paso 'Inicializando el directorio de datos (esto tarda un poco)...'
        if (-not (Test-Path $DIR_DB)) { New-Item -ItemType Directory -Path $DIR_DB -Force | Out-Null }
        if (Test-Path $datos) { Remove-Item $datos -Recurse -Force }

        # --initialize-insecure crea root sin contrasena; se le pone la
        # nuestra justo despues. Es el flujo recomendado para instalaciones
        # desatendidas y evita tener que rescatar la clave temporal del log.
        # mysqld escribe TODO su log por stderr: con Start-Process no se convierte
        # en excepcion bajo PowerShell 5.1 y ademas queda en logs\mysql-init.log.
        $init = Start-Process -FilePath $mysqld -ArgumentList '--initialize-insecure', (Format-Arg '--datadir' $datos), '--no-monitor' `
            -Wait -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $DIR_LOGS 'mysql-init.out.log') -RedirectStandardError (Join-Path $DIR_LOGS 'mysql-init.log')
        if ($init.ExitCode -ne 0) {
            Write-Fallo "mysqld --initialize fallo (codigo $($init.ExitCode)). Mira logs\mysql-init.log"
            exit 1
        }
        Write-Ok 'Directorio de datos creado.'
    }

    # Arranque temporal para crear esquemas y usuario.
    $yaCorria = Test-PuertoEscuchando -Puerto $DB_PORT -Protocolo 'TCP'
    $proceso  = $null

    if (-not $yaCorria) {
        Write-Paso 'Arrancando MySQL temporalmente...'
        # Con redireccion (CreateProcess) y no por ShellExecute: un .exe con la
        # marca de "descargado de internet" lanzado sin redireccion se queda
        # bloqueado en el dialogo de seguridad, que oculto no se ve (28-sep).
        # --no-monitor: un solo proceso mysqld, asi el PID que se guarda es el
        # servidor real y se puede parar de verdad.
        $proceso = Start-Process -FilePath $mysqld `
            -ArgumentList (Format-Arg '--datadir' $datos), "--port=$DB_PORT", '--console', '--no-monitor' `
            -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $DIR_LOGS 'mysql-setup.log') -RedirectStandardError (Join-Path $DIR_LOGS 'mysql-setup.err.log')

        $limite = (Get-Date).AddSeconds(120)
        while ((Get-Date) -lt $limite -and -not $proceso.HasExited -and -not (Test-PuertoEscuchando -Puerto $DB_PORT)) {
            Start-Sleep -Milliseconds 500
        }
        if (-not (Test-PuertoEscuchando -Puerto $DB_PORT)) {
            Write-Fallo 'MySQL no llego a arrancar en 2 minutos. Mira logs\mysql-setup.err.log'
            Get-Content (Join-Path $DIR_LOGS 'mysql-setup.err.log') -Tail 5 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }
            if ($proceso -and -not $proceso.HasExited) { Stop-Process -Id $proceso.Id -Force }
            exit 1
        }
        Write-Ok 'MySQL arrancado.'
    }

    try {
        $mysql = Get-RutaMysql -Programa 'mysql'

        # Se ejecuta como root SIN contrasena la primera vez; si ya tiene la
        # nuestra puesta, el primer intento falla y usamos la contrasena.
        $sqlInicial = @"
CREATE DATABASE IF NOT EXISTS $DB_NOMBRE CHARACTER SET utf8mb4;
CREATE DATABASE IF NOT EXISTS $DB_XMPP   CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NOMBRE.* TO '$DB_USER'@'%';
GRANT ALL PRIVILEGES ON $DB_XMPP.*   TO '$DB_USER'@'%';
ALTER USER '$DB_ROOT'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DB_ROOTPW';
FLUSH PRIVILEGES;
"@
        # (28-sep) El SQL va con -e y la contrasena por MYSQL_PWD, y se ejecuta
        # con Invoke-Nativo: bajo PowerShell 5.1 el "ERROR 1045" del primer
        # intento y el aviso de --password salian por stderr y, con
        # ErrorActionPreference = 'Stop', mataban el script aqui mismo (y en el
        # finally), dejando el MySQL temporal vivo. En PowerShell 7 no pasaba:
        # de ahi "en mi PC va y en el del colega no". El fichero temporal
        # tambien sobra (Set-Content -Encoding UTF8 le metia un BOM en 5.1).
        Write-Paso 'Creando esquemas y usuario...'
        $argsSql = @("--host=$DB_HOST", "--port=$DB_PORT", "--user=$DB_ROOT", '-e', $sqlInicial)
        # Primero con la contrasena (lo normal: la base de datos viaja ya
        # configurada); si falla, root todavia no tiene contrasena (primer setup).
        $env:MYSQL_PWD = $DB_ROOTPW
        $r = Invoke-Nativo -Exe $mysql -Argumentos $argsSql
        if ($r.Codigo -ne 0) {
            $env:MYSQL_PWD = $null
            $r = Invoke-Nativo -Exe $mysql -Argumentos $argsSql
        }
        $env:MYSQL_PWD = $null
        if ($r.Codigo -ne 0) {
            Write-Fallo "No pude crear los esquemas: $($r.Salida)"
            exit 1
        }
        Write-Ok "Esquemas '$DB_NOMBRE' y '$DB_XMPP' listos, usuario '$DB_USER' creado."

        # Aviso util: si SOAPBOX esta vacio, falta importar el volcado base.
        $tablas = (Invoke-Mysql -Sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NOMBRE';" -ComoRoot) -join ''
        if ([int]($tablas -replace '\D','') -lt 10) {
            Write-Host ''
            Write-Aviso "El esquema $DB_NOMBRE esta vacio: falta importar el volcado del juego."
            Write-Host '       Importalo antes de arrancar:' -ForegroundColor Yellow
            Write-Host "         mysql -u $DB_USER -p $DB_NOMBRE < db\esquema.sql" -ForegroundColor Yellow
            Write-Host "         mysql -u $DB_USER -p $DB_NOMBRE < db\datos.sql" -ForegroundColor Yellow
            Write-Host '       Y despues, para el modo fiesta:' -ForegroundColor Yellow
            Write-Host "         mysql -u $DB_USER -p $DB_NOMBRE < db\party-setup.sql" -ForegroundColor Yellow
        }
    }
    finally {
        if ($proceso -and -not $proceso.HasExited) {
            Write-Paso 'Parando el MySQL temporal...'
            $mysqladmin = Get-RutaMysql -Programa 'mysqladmin'
            if ($mysqladmin) {
                $env:MYSQL_PWD = $DB_ROOTPW
                Invoke-Nativo -Exe $mysqladmin -Argumentos @("--host=$DB_HOST", "--port=$DB_PORT", "--user=$DB_ROOT", 'shutdown') | Out-Null
                $env:MYSQL_PWD = $null
            }
            $limite = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $limite -and -not $proceso.HasExited) { Start-Sleep -Milliseconds 500 }
            if (-not $proceso.HasExited) { Stop-Process -Id $proceso.Id -Force -ErrorAction SilentlyContinue }
            Write-Ok 'MySQL temporal parado.'
        }
    }
}

# =====================================================================
#  4. WEB DE REGISTRO
# =====================================================================
Write-Host ''
Write-Host '  4. WEB DE REGISTRO' -ForegroundColor White
Write-Host ''

$python = $null
$portable = Join-Path $DIR_RUNTIME 'python\python.exe'
if (Test-Path $portable) { $python = $portable }
else {
    $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($cmd) { $python = $cmd.Source }
}

if (-not $python) {
    Write-Aviso 'No encuentro Python: la web de registro no podra arrancar.'
} else {
    Write-Ok "Python: $python"
    $tieneFlask = Invoke-Nativo -Exe $python -Argumentos @('-c', 'import flask')
    if ($tieneFlask.Codigo -ne 0) {
        Write-Paso 'Instalando Flask...'
        $pip = Invoke-Nativo -Exe $python -Argumentos @('-m', 'pip', 'install', '--quiet', 'flask')
        if ($pip.Codigo -eq 0) { Write-Ok 'Flask instalado.' }
        else { Write-Aviso 'No pude instalar Flask (sin internet?). La web no arrancara.' }
    } else {
        Write-Ok 'Flask disponible.'
    }
}

# =====================================================================
#  FIN
# =====================================================================
Write-Registro 'setup.ps1 ejecutado'

Write-Host ''
Write-Titulo 'Preparacion terminada'
Write-Host ''
Write-Host '    Siguiente paso:  .\start.ps1' -ForegroundColor Green
Write-Host '    Y para comprobar: .\status.ps1' -ForegroundColor Green
Write-Host ''
