<#
.SYNOPSIS
    Para el servidor de forma limpia.

.DESCRIPTION
    Detiene los servicios en orden inverso al arranque: primero los que dan
    servicio a los jugadores, y la base de datos la ultima, para que nadie
    escriba mientras se cierra.

    Intenta siempre el cierre ordenado antes de matar el proceso. A MySQL se
    le pide el apagado por su propia herramienta (mysqladmin shutdown), que es
    la unica forma de garantizar que no queden tablas a medias.

.PARAMETER Forzar
    Mata los procesos directamente, sin esperar al cierre ordenado.
    Solo para cuando algo se ha quedado colgado.

.EXAMPLE
    .\stop.ps1
.EXAMPLE
    .\stop.ps1 -Forzar
#>

[CmdletBinding()]
param([switch] $Forzar)

. (Join-Path $PSScriptRoot '_comun.ps1')

# (28-sep) Lo que se imprime queda en logs\arranque.txt, y no se solapa con un
# arranque o preparacion en curso.
if (-not (Test-Path $DIR_LOGS)) { New-Item -ItemType Directory -Path $DIR_LOGS -Force | Out-Null }
try { Start-Transcript -Path (Join-Path $DIR_LOGS 'arranque.txt') -Append -Force | Out-Null } catch { }

Write-Titulo 'NFS World LAN - Parando servidor'

# (28-sep) Solo se paran procesos NUESTROS: los de esta carpeta o, si su ruta no
# se puede leer (proceso elevado), los que se llaman como los nuestros. Antes se
# mataba a quien ocupara el puerto, fuera quien fuera.
$esperado = @{ mysql = @('mysqld'); openfire = @('cmd', 'java'); core = @('java'); freeroam = @('freeroamd'); race = @('race'); web = @('python') }
function Test-EsNuestro {
    param($Proc, [string] $Nombre)
    if (-not $Proc) { return $false }
    if ($Proc.Path) { return $Proc.Path.StartsWith($RAIZ, [System.StringComparison]::OrdinalIgnoreCase) }
    $nombres = if ($esperado.ContainsKey($Nombre)) { $esperado[$Nombre] } else { @('mysqld', 'java', 'freeroamd', 'race', 'python', 'cmd') }
    return (@($nombres) -contains $Proc.ProcessName)
}

# Orden inverso al de arranque: los jugadores primero, la base de datos al final.
$orden = @('web', 'race', 'freeroam', 'core', 'openfire', 'mysql')

# PIDs que apunto start.ps1 (si existe el fichero).
$pidsGuardados = @{}
if (Test-Path $FICHERO_PIDS) {
    try {
        $obj = Get-Content $FICHERO_PIDS -Raw | ConvertFrom-Json
        $obj.PSObject.Properties | ForEach-Object { $pidsGuardados[$_.Name] = $_.Value }
    } catch {
        Write-Aviso 'El fichero de procesos esta corrupto; se buscara por puerto.'
    }
}

function Stop-Servicio {
    param(
        [Parameter(Mandatory)][string] $Nombre,
        [Parameter(Mandatory)][string] $Etiqueta,
        [Parameter(Mandatory)][int]    $Puerto,
        [string] $Protocolo = 'TCP'
    )

    # Se busca por PID guardado y, si no, por quien ocupa el puerto: asi
    # tambien para servicios arrancados a mano o por una sesion anterior.
    $procId = $null; $porPuerto = $false
    if ($pidsGuardados.ContainsKey($Nombre)) { $procId = $pidsGuardados[$Nombre] }
    if (-not $procId) { $procId = Get-PidEnPuerto -Puerto $Puerto -Protocolo $Protocolo; $porPuerto = $true }

    if (-not $procId) {
        Write-Host ('    {0,-24} ya estaba parado' -f $Etiqueta) -ForegroundColor DarkGray
        return
    }

    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if (-not $proc) {
        Write-Host ('    {0,-24} ya estaba parado' -f $Etiqueta) -ForegroundColor DarkGray
        return
    }
    # El PID apuntado por start.ps1 es nuestro por definicion (puede ser el cmd
    # del lanzador de Openfire); el filtro solo aplica a lo encontrado por puerto.
    if ($porPuerto -and -not (Test-EsNuestro $proc $Nombre)) {
        Write-Aviso "${Etiqueta}: en el puerto $Puerto hay $($proc.ProcessName) (pid $procId) y no es nuestro; no se toca."
        return
    }

    # MySQL merece un cierre ordenado de verdad.
    if ($Nombre -eq 'mysql' -and -not $Forzar) {
        $mysqladmin = Get-RutaMysql -Programa 'mysqladmin'
        if ($mysqladmin) {
            Write-Paso 'Pidiendo a MySQL que cierre ordenadamente...'
            & $mysqladmin "--host=$DB_HOST" "--port=$DB_PORT" "--user=$DB_ROOT" "--password=$DB_ROOTPW" shutdown 2>&1 | Out-Null
            $limite = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $limite -and -not $proc.HasExited) { Start-Sleep -Milliseconds 500 }
        }
    }

    if (-not $proc.HasExited -and -not $Forzar) {
        $proc.CloseMainWindow() | Out-Null
        $limite = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $limite -and -not $proc.HasExited) { Start-Sleep -Milliseconds 500 }
    }

    if (-not $proc.HasExited) {
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        Write-Ok "$Etiqueta detenido (forzado)"
    } else {
        Write-Ok "$Etiqueta detenido"
    }
}

Write-Host ''
foreach ($nombre in $orden) {
    $s = $SERVICIOS | Where-Object { $_.Nombre -eq $nombre } | Select-Object -First 1
    if ($s) {
        Stop-Servicio -Nombre $s.Nombre -Etiqueta $s.Etiqueta -Puerto $s.Puerto -Protocolo $s.Protocolo
    }
}

if (Test-Path $FICHERO_PIDS) { Remove-Item $FICHERO_PIDS -Force -ErrorAction SilentlyContinue }
Remove-Item (Join-Path $DIR_LOGS 'estado.json') -Force -ErrorAction SilentlyContinue
Write-Registro 'stop.ps1 - servidor parado'

# Comprobacion final: que no quede nada escuchando.
Write-Host ''
$restantes = @()
foreach ($s in $SERVICIOS) {
    if (Test-PuertoEscuchando -Puerto $s.Puerto -Protocolo $s.Protocolo) { $restantes += $s.Etiqueta }
}

if ($restantes.Count -gt 0) {
    # Segunda pasada. Openfire se lanza con un .bat que termina enseguida y
    # deja el proceso java suelto: el PID que apuntamos ya no existe, pero el
    # puerto sigue ocupado. Aqui se busca por puerto y se remata.
    Write-Paso 'Rematando lo que sigue escuchando...'
    foreach ($s in $SERVICIOS) {
        if (-not (Test-PuertoEscuchando -Puerto $s.Puerto -Protocolo $s.Protocolo)) { continue }
        $procId = Get-PidEnPuerto -Puerto $s.Puerto -Protocolo $s.Protocolo
        if ($procId) {
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if (-not (Test-EsNuestro $proc $s.Nombre)) { Write-Aviso "$($s.Etiqueta): en el puerto $($s.Puerto) hay $($proc.ProcessName) (pid $procId) y no es nuestro; no se toca."; continue }
            Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 800
            if (Test-PuertoEscuchando -Puerto $s.Puerto -Protocolo $s.Protocolo) { Write-Aviso "$($s.Etiqueta) sigue escuchando (pid $procId, no se pudo parar: puede correr como administrador)." }
            else { Write-Ok "$($s.Etiqueta) detenido (segunda pasada)" }
        }
    }

    $restantes = @()
    foreach ($s in $SERVICIOS) {
        if (Test-PuertoEscuchando -Puerto $s.Puerto -Protocolo $s.Protocolo) { $restantes += $s.Etiqueta }
    }
    Write-Host ''
}

if ($restantes.Count -eq 0) {
    Write-Ok 'Todo parado.'
} else {
    Write-Aviso "Sigue habiendo algo escuchando: $($restantes -join ', ')"
    Write-Host '       Cierra la sesion de PowerShell y vuelve a probar.' -ForegroundColor Yellow
}
Write-Host ''
