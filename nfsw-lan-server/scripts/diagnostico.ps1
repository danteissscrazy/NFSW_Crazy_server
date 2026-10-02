<#
.SYNOPSIS
    Recoge en un solo fichero todo lo que hace falta para saber por que no arranca el servidor en este PC.

.DESCRIPTION
    Para cuando el servidor falla en un equipo que no es el del organizador y no hay nadie
    delante que sepa mirar los logs. Se ejecuta (doble clic en "Diagnostico" del panel, o
    desde PowerShell) y deja logs\diagnostico-<fecha>.txt con:
      - version de Windows y de PowerShell, si es administrador, la ruta de la carpeta
      - la IP que elegiria el servidor y todas las candidatas
      - que puertos del servidor estan ocupados por otro programa y cuales estan
        RESERVADOS por Windows (Hyper-V / WSL reservan rangos al azar: es la causa
        clasica de "no abrio el puerto" en un PC ajeno)
      - si estan las DLL de Visual C++ junto a mysqld.exe y si Windows ha marcado los
        ejecutables como "descargados de internet" (SmartScreen los bloquea en silencio)
      - los procesos del servidor vivos y el final de cada log, con la primera linea
        "Caused by" del servidor del juego
    No cambia nada. Se puede ejecutar con el servidor arrancado o parado.

.EXAMPLE
    .\diagnostico.ps1
#>

[CmdletBinding()]
param([string] $Salida)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_comun.ps1')

if (-not $Salida) { $Salida = Join-Path $DIR_LOGS ('diagnostico-{0:yyyy-MM-dd_HH-mm}.txt' -f (Get-Date)) }
if (-not (Test-Path $DIR_LOGS)) { New-Item -ItemType Directory -Path $DIR_LOGS -Force | Out-Null }
$lineas = New-Object System.Collections.Generic.List[string]
function L { param([string] $t = '') $lineas.Add($t); Write-Host $t }
function Seccion { param([string] $t) L ''; L ('=' * 70); L "  $t"; L ('=' * 70) }

Write-Titulo 'Diagnostico del servidor en este PC'

Seccion 'EQUIPO'
L ("Fecha:            {0:yyyy-MM-dd HH:mm:ss}" -f (Get-Date))
L ("Equipo / usuario: {0} / {1}" -f $env:COMPUTERNAME, $env:USERNAME)
try { $os = Get-CimInstance Win32_OperatingSystem; L ("Windows:          {0} (build {1}) {2}" -f $os.Caption, $os.BuildNumber, $os.OSArchitecture) } catch { L 'Windows:          (no se pudo leer)' }
L ("PowerShell:       {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
L ("Administrador:    {0}" -f (Test-EsAdministrador))
L ("Carpeta:          {0}" -f $RAIZ)
$ascii = -not ($RAIZ -match '[^\x00-\x7F]')
L ("Ruta solo ASCII:  {0}   (con acentos o simbolos raros algunos programas fallan)" -f $ascii)
try { $disco = Get-PSDrive -Name ($RAIZ.Substring(0, 1)) -ErrorAction Stop; L ("Disco libre:      {0:N1} GB en {1}:" -f ($disco.Free / 1GB), $disco.Name) } catch { }
try { $cs = Get-CimInstance Win32_ComputerSystem; L ("RAM:              {0:N1} GB (el servidor del juego necesita 2 GB de heap; con menos de 8 GB arranca con 1 GB)" -f ($cs.TotalPhysicalMemory / 1GB)) } catch { }
$sincronizada = ($env:OneDrive -and $RAIZ.StartsWith($env:OneDrive, [System.StringComparison]::OrdinalIgnoreCase)) -or ($RAIZ -match '\\(OneDrive|Google Drive|Dropbox|iCloudDrive)\\')
L ("En OneDrive/sync: {0}   (si es True, MySQL no puede trabajar ahi: mover la carpeta a C:\CrazyServer)" -f $sincronizada)
try {
    $masLarga = Get-ChildItem -LiteralPath $RAIZ -Recurse -File -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending | Select-Object -First 1
    if ($masLarga) { L ("Ruta mas larga:   {0} caracteres (limite clasico de Windows: 260) {1}" -f $masLarga.FullName.Length, $(if ($masLarga.FullName.Length -gt 240) { '[X] demasiado larga: descomprimir en una ruta corta como C:\CrazyServer' } else { '' })) }
} catch { }

Seccion 'RED'
$ip = Get-IpLan
L ("IP elegida:       {0}" -f $(if ($ip) { $ip } else { '(ninguna: sin red?)' }))
L 'Todas las IPv4:'
Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object {
    $ad = Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue
    L ("   {0,-16} {1,-28} {2}" -f $_.IPAddress, $_.InterfaceAlias, $(if ($ad) { $ad.InterfaceDescription } else { '' }))
}

Seccion 'PUERTOS DEL SERVIDOR'
L 'Que escucha ahora en cada puerto (si el servidor esta parado, deberia estar todo libre):'
foreach ($s in $SERVICIOS) {
    $vivo = Test-PuertoEscuchando -Puerto $s.Puerto -Protocolo $s.Protocolo
    $quien = ''
    if ($vivo) {
        $procId = Get-PidEnPuerto -Puerto $s.Puerto -Protocolo $s.Protocolo
        if ($procId) { $p = Get-Process -Id $procId -ErrorAction SilentlyContinue; $quien = if ($p) { "pid $procId $($p.ProcessName) [$($p.Path)]" } else { "pid $procId" } }
    }
    L ("   {0,-24} {1,5}/{2,-4} {3,-8} {4}" -f $s.Etiqueta, $s.Puerto, $s.Protocolo.ToLower(), $(if ($vivo) { 'OCUPADO' } else { 'libre' }), $quien)
}
L ''
L 'Rangos de puertos RESERVADOS por Windows (Hyper-V, WSL, Docker). Si un puerto del servidor cae dentro, ese servicio NO puede abrirlo:'
try {
    $reservas = & netsh interface ipv4 show excludedportrange protocol=tcp 2>&1
    $rangos = @()
    foreach ($linea in $reservas) { if ($linea -match '^\s*(\d+)\s+(\d+)') { $rangos += [pscustomobject]@{ De = [int]$matches[1]; A = [int]$matches[2] } } }
    $chocan = @()
    foreach ($s in $SERVICIOS | Where-Object { $_.Protocolo -eq 'TCP' }) {
        foreach ($r in $rangos) { if ($s.Puerto -ge $r.De -and $s.Puerto -le $r.A) { $chocan += ('{0} ({1}) cae en el rango reservado {2}-{3}' -f $s.Etiqueta, $s.Puerto, $r.De, $r.A) } }
    }
    foreach ($extra in @(9090, 33060)) { foreach ($r in $rangos) { if ($extra -ge $r.De -and $extra -le $r.A) { $chocan += ('puerto {0} (Openfire admin / MySQL X) cae en {1}-{2}' -f $extra, $r.De, $r.A) } } }
    if ($chocan.Count) { foreach ($c in $chocan) { L "   [X] $c" }; L '   Solucion: netsh int ipv4 add excludedportrange protocol=tcp startport=<puerto> numberofports=1 (como administrador) y reiniciar, o cambiar el puerto.' }
    else { L ("   ninguno choca ({0} rangos reservados)" -f $rangos.Count) }
} catch { L "   (no se pudo consultar: $($_.Exception.Message))" }

Seccion 'FICHEROS Y DEPENDENCIAS'
$mysqld = Get-RutaMysql -Programa 'mysqld'
L ("mysqld.exe:       {0}" -f $(if ($mysqld) { $mysqld } else { 'NO ENCONTRADO' }))
if ($mysqld) {
    $binMysql = Split-Path $mysqld -Parent
    foreach ($dll in 'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll') {
        $junto = Test-Path (Join-Path $binMysql $dll); $sistema = Test-Path (Join-Path $env:SystemRoot "System32\$dll")
        L ("   {0,-20} junto al exe: {1,-5} en System32: {2}" -f $dll, $junto, $sistema)
    }
}
$java = Get-RutaJava
L ("java.exe:         {0}" -f $(if ($java) { $java } else { 'NO ENCONTRADO' }))
if ($java) { try { $v = & $java -version 2>&1 | Select-Object -First 1; L "   version: $v" } catch { L "   [X] no se pudo ejecutar java: $($_.Exception.Message)" } }
foreach ($rel in 'server\core.jar', 'server\freeroamd.exe', 'server\race.exe', 'server\openfire\lib\startup.jar', 'server\openfire\bin\openfire-portable.bat', 'webregister\app.py', 'runtime\python\python.exe', 'db\data\mysql', 'db\data\soapbox') {
    L ("   {0,-45} {1}" -f $rel, $(if (Test-Path (Join-Path $RAIZ $rel)) { 'ok' } else { 'FALTA' }))
}
L ''
L 'Marca "descargado de internet" (Zone.Identifier): si aparece en un .exe, Windows puede bloquearlo sin avisar. Se quita con Unblock-File.'
$marcados = @()
foreach ($f in @($mysqld, $java, (Join-Path $RAIZ 'server\freeroamd.exe'), (Join-Path $RAIZ 'server\race.exe'), (Join-Path $RAIZ 'server\core.jar'), (Join-Path $RAIZ 'runtime\python\python.exe')) | Where-Object { $_ -and (Test-Path $_) }) {
    $z = Get-Item -LiteralPath $f -Stream Zone.Identifier -ErrorAction SilentlyContinue
    if ($z) { $marcados += $f }
}
if ($marcados.Count) { foreach ($m in $marcados) { L "   [X] marcado: $m" }; L '   Solucion: Get-ChildItem <carpeta> -Recurse | Unblock-File   (setup.ps1 ya lo hace desde el 28-09)' } else { L '   ninguno marcado' }
try { $mp = Get-MpComputerStatus -ErrorAction Stop; L ("Defender:         tiempo real {0}" -f $mp.RealTimeProtectionEnabled) } catch { L 'Defender:         (no disponible)' }
try { $cfa = (Get-MpPreference -ErrorAction Stop).EnableControlledFolderAccess; L ("Acceso controlado a carpetas (Defender): {0}   (1 = activado: puede impedir escribir a mysqld/java)" -f $cfa) } catch { }
try {
    $avs = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop | ForEach-Object { $_.displayName }
    L ("Antivirus registrados: {0}" -f $(if ($avs) { $avs -join ', ' } else { 'ninguno (solo Defender o sin registro)' }))
    $fws = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName FirewallProduct -ErrorAction Stop | ForEach-Object { $_.displayName }
    if ($fws) { L ("Firewalls de terceros: {0}   (un firewall ajeno puede cerrar los puertos aunque setup.ps1 abriera el de Windows)" -f ($fws -join ', ')) }
} catch { }
try {
    $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
    L ("Proxy del sistema: activado={0} servidor={1} pac={2}" -f $ie.ProxyEnable, $ie.ProxyServer, $ie.AutoConfigURL)
} catch { }
try { $vol = Get-Volume -DriveLetter $RAIZ.Substring(0, 1) -ErrorAction Stop; L ("Disco de la carpeta: {0} {1}   (exFAT/FAT32 no valen para MySQL)" -f $vol.FileSystem, $vol.DriveType) } catch { }
try { $tmp = Get-PSDrive -Name ($env:TEMP.Substring(0, 1)) -ErrorAction Stop; L ("TEMP:             {0}  ({1:N1} GB libres; el servidor del juego descomprime ahi ~200 MB)" -f $env:TEMP, ($tmp.Free / 1GB)) } catch { }
try { $svc = Get-Service Winmgmt, MpsSvc, BFE, nsi, Dnscache -ErrorAction Stop | ForEach-Object { "$($_.Name)=$($_.Status)" }; L ("Servicios de Windows: {0}" -f ($svc -join ' ')) } catch { }

Seccion 'PROCESOS DEL SERVIDOR VIVOS'
$procs = Get-Process mysqld, java, freeroamd, race, python -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$RAIZ*" }
if ($procs) { foreach ($p in $procs) { L ("   pid {0,-6} {1,-10} desde {2:HH:mm:ss}  {3} MB" -f $p.Id, $p.ProcessName, $p.StartTime, [int]($p.WorkingSet64 / 1MB)) } } else { L '   ninguno de esta carpeta' }
if (Test-Path $FICHERO_PIDS) { L ("   procesos.json: {0}" -f ((Get-Content $FICHERO_PIDS -Raw) -replace '\s+', ' ')) }

Seccion 'LOGS (final de cada uno)'
foreach ($log in 'arranque.txt', 'servidor.log', 'mysql.err.log', 'mysql.log', 'mysql-setup.err.log', 'openfire.err.log', 'openfire.log', 'core.err.log', 'freeroam.err.log', 'race.err.log', 'web.err.log', 'mysql-init.log') {
    $f = Join-Path $DIR_LOGS $log
    if (-not (Test-Path $f)) { continue }
    $n = if ($log -eq 'arranque.txt') { 80 } elseif ($log -eq 'mysql.err.log' -or $log -eq 'core.err.log') { 25 } else { 12 }
    L ''; L ("--- {0} ({1:N0} bytes, {2:yyyy-MM-dd HH:mm}) ---" -f $log, (Get-Item $f).Length, (Get-Item $f).LastWriteTime)
    Get-Content $f -Tail $n -ErrorAction SilentlyContinue | ForEach-Object { L ("   " + $_) }
}
$core = Join-Path $DIR_LOGS 'core.log'
if (Test-Path $core) {
    L ''; L ("--- core.log ({0:N0} bytes): lineas 'Caused by' y errores de despliegue (ultimas 15) ---" -f (Get-Item $core).Length)
    Select-String -Path $core -Pattern 'Caused by|WFLYCTL0013|WFLYSRV0257|Failed to|Connection refused|Communications link failure|Access denied|not-authorized|Address already in use' -ErrorAction SilentlyContinue |
        Select-Object -Last 15 | ForEach-Object { L ("   L{0}: {1}" -f $_.LineNumber, $_.Line.Trim()) }
    L '--- core.log: ultimas 8 lineas ---'
    Get-Content $core -Tail 8 -ErrorAction SilentlyContinue | ForEach-Object { L ("   " + $_) }
}
$ofLog = Join-Path $DIR_SERVER 'openfire\logs\error.log'
if (Test-Path $ofLog) { L ''; L '--- openfire\logs\error.log (ultimas 10) ---'; Get-Content $ofLog -Tail 10 -ErrorAction SilentlyContinue | ForEach-Object { L ("   " + $_) } }

Seccion 'FIN'
[System.IO.File]::WriteAllLines($Salida, $lineas, (New-Object System.Text.UTF8Encoding $true))
Write-Host ''
Write-Ok "Diagnostico guardado en: $Salida"
Write-Host '    Manda ese fichero al organizador (o pegalo en el chat).' -ForegroundColor DarkGray
Write-Registro "diagnostico.ps1 - $Salida"
