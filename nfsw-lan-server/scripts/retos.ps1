<#
.SYNOPSIS
    Retos de la noche: los logros del juego recortados a escala de 4 horas
    y con premios gordos (dinero, Diamond Pack y un coche por reto).

.DESCRIPTION
    NFS World trae 68 logros pensados para meses de juego (240 victorias,
    25.000 millas, 60 victorias seguidas...). En una LAN de una noche nadie
    ve ni el primer rango. Este script coge OCHO logros que ya existen y les
    cambia solo dos cosas: los umbrales (1 / 3 / 5 / 10 y un quinto rango de
    leyenda) y los premios (100.000 -> 250.000 -> 500.000 -> Diamond Pack ->
    un coche distinto por reto). No crea logros ni textos nuevos: el cliente
    sigue mostrando los nombres, iconos y descripciones de siempre, asi que
    no hay ningun texto que pueda salir en blanco ni ningun badge que falte.

    Los ocho retos (nombre de fabrica -> lo que cuenta):
      ACH_PLAY_EVENTS       MARATONISTA   carreras disputadas         1/3/5/10/20
      ACH_WIN_RACES_STREAK  RACHA         victorias seguidas          1/3/5/10/15
      ACH_WIN_DRAG          DRAGSTER      drags ganados               1/3/5/10/20
      ACH_PURSUIT           FUGITIVO      persecuciones escapadas     1/3/5/10/15
      ACH_INCUR_COSTTOSTATE ENEMIGO PUBL. dano al estado (dolares)    100k/300k/500k/1M/2M
      ACH_CLOCKED_AIRTIME   VOLADOR       tiempo en el aire           30s/1/2/3/5 min
      ACH_DRIVE_MILES       KILOMETROS    distancia en carrera        10/30/50/100/200 km
      ACH_COPSDISABLED_TE   DEMOLEDOR     policias reventados (T.E.)  5/15/25/50/100

    Todo es reversible: antes de tocar nada se guarda una copia de los
    valores de fabrica en la tabla `crazy_retos_backup` y -Revertir la usa
    para dejarlo todo como estaba.

    CACHE Y REINICIOS (verificado en el core):
      - AchievementBO es un @Singleton que carga `achievement` (con sus
        `achievement_rank`) en memoria al arrancar (@PostConstruct loadData) y
        ya no vuelve a leerlos. Cambiarlos en la base de datos NO se nota...
        hasta llamar a POST /Engine.svc/ReloadAchievements (adminAuth), que
        ejecuta ese mismo loadData(). Este script lo llama al aplicar y al
        revertir: NO hace falta reiniciar el core. Si el core esta parado,
        los cargara solo al arrancar.
      - `achievement_reward` (los scripts de premio) se lee de la base de
        datos en cada canje (AchievementRewardDAO.findByDescription, sin
        cache), pero aqui no se toca: se reutilizan filas que ya existen.
      - persistence.xml enciende la cache de segundo nivel de Hibernate, pero
        ninguna entidad lleva @Cacheable ni @Cache y ningun DAO usa la pista
        org.hibernate.cacheable: no hay nada mas cacheado que lo de arriba.
      - Lo que cachea el CLIENTE: la pestana de logros se pide en
        /achievements/loadall al iniciar sesion. Quien ya este dentro ve los
        umbrales viejos en pantalla hasta que salga y vuelva a entrar, pero
        el SERVIDOR ya cuenta con los nuevos desde la recarga: el aviso de
        "logro conseguido" y el premio le llegan igual.

.PARAMETER Aplicar
    Recorta los ocho logros y pone los premios gordos. Guarda antes la copia
    de fabrica. Se puede repetir sin miedo: la copia no se sobreescribe.

.PARAMETER ContarPrivadas
    Solo con -Aplicar. De fabrica, las carreras en sala privada (invitar a un
    amigo a un evento concreto) NO cuentan para los logros de carreras. En una
    LAN eso deja fuera a media sala. Con este modificador se quita esa
    condicion de los tres logros de carreras afectados (MARATONISTA, RACHA y
    DRAGSTER). -Revertir tambien la restaura.

.PARAMETER Revertir
    Devuelve umbrales, premios y condiciones a los valores de fabrica desde
    la copia guardada, y borra la copia.

.PARAMETER Listar
    (Por defecto.) Muestra si los retos estan activos, la escalera de cada
    uno tal y como esta AHORA en la base de datos, y quien va ganando.

.PARAMETER Simular
    Con -Aplicar o -Revertir: imprime el SQL exacto que se ejecutaria y no
    toca nada (ni base de datos, ni recarga, ni megafono).

.EXAMPLE
    .\retos.ps1                          # como estan las cosas y quien lidera
    .\retos.ps1 -Aplicar                 # antes de abrir las puertas
    .\retos.ps1 -Aplicar -ContarPrivadas # idem, contando tambien salas privadas
    .\retos.ps1 -Aplicar -Simular        # ver el SQL sin ejecutarlo
    .\retos.ps1 -Revertir                # al terminar la fiesta

.NOTES
    Por que no hay reto de velocidad punta ni de drift: no existen como
    logros en este servidor (el juego los calculaba en cliente y la base de
    datos de la comunidad no los trae). Solo se recorta lo que existe.

    Por que estos premios y no otros: el cliente pinta el premio a partir de
    la clave de texto que va en achievement_rank.reward_description y el core
    busca esa MISMA clave en achievement_reward.internal_reward_description
    con getSingleResult(): una clave inventada saldria sin texto en pantalla
    y reventaria al canjear. Por eso todos los premios son claves que ya
    existen en las dos tablas (verificado con SELECT).

    El dinero de los logros NO pasa por CASH_REWARD_MULTIPLIER (eso solo
    multiplica lo que pagan las carreras): 100.000 son 100.000.
#>

[CmdletBinding(DefaultParameterSetName = 'Listar')]
param(
    [Parameter(ParameterSetName = 'Aplicar')]  [switch] $Aplicar,
    [Parameter(ParameterSetName = 'Aplicar')]  [switch] $ContarPrivadas,
    [Parameter(ParameterSetName = 'Revertir')] [switch] $Revertir,
    [Parameter(ParameterSetName = 'Listar')]   [switch] $Listar,
    [Parameter(ParameterSetName = 'Aplicar')]
    [Parameter(ParameterSetName = 'Revertir')] [switch] $Simular
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_comun.ps1')

# Los pone party-setup.sql en la tabla parameter. Se leen de ahi; esto es
# solo el respaldo por si la consulta falla.
$TOKEN_ADMIN_FALLBACK  = 'CrazyAdmin2026'
$TOKEN_AVISOS_FALLBACK = 'CrazyMega2026'

# Tabla propia (fuera del esquema del juego) donde se guardan los valores de
# fabrica. Su mera existencia con filas significa "retos activos".
$TABLA_COPIA = 'crazy_retos_backup'

# La condicion de fabrica que excluye las salas privadas de los logros de
# carreras. Se quita con REPLACE() de esta cadena EXACTA (con el espacio y
# el && delante), que es como aparece en los tres triggers afectados.
$CLAUSULA_PRIVADAS = ' && !eventSession.getLobby().getIsPrivate()'


# =====================================================================
#  DEFINICION DE LOS RETOS
# =====================================================================
# Cada reto es un logro EXISTENTE (columna achievement.name) con sus cinco
# rangos. Solo se cambian umbral y premio de cada rango; puntos, textos,
# iconos y disparadores se dejan como estan.
#
# Unidad: como se muestran los valores en pantalla.
#   n    = contador simple           cash = dolares (dano al estado)
#   ms   = milisegundos (el cliente los pasa a minutos)
#   m    = metros (el cliente los pasa a km o millas)
#
# Coche = premio del rango 5 (el gordo). Son coches "Achievement Edition" que
# el juego ya regalaba en los rangos altos: existen en `product` y su clave
# de texto existe en `achievement_reward`.
$RETOS = @(
    @{ Logro = 'achievement_ACH_PLAY_EVENTS';       Titulo = 'MARATONISTA';     Que = 'carreras disputadas (circuito y sprint)'
       Umbrales = @(1, 3, 5, 10, 20);                Unidad = 'n'
       Coche = 'GM_ACHIEVEMENT_000001A5';           NombreCoche = 'Nissan 240ZG Achievement Edition' }

    @{ Logro = 'achievement_ACH_WIN_RACES_STREAK';  Titulo = 'RACHA';           Que = 'victorias seguidas (se corta al perder)'
       Umbrales = @(1, 3, 5, 10, 15);                Unidad = 'n'
       Coche = 'GM_ACHIEVEMENT_0000017C';           NombreCoche = 'Bugatti Veyron 16.4' }

    @{ Logro = 'achievement_ACH_WIN_DRAG';          Titulo = 'DRAGSTER';        Que = 'drags ganados'
       Umbrales = @(1, 3, 5, 10, 20);                Unidad = 'n'
       Coche = 'GM_CATALOG_000049C6';               NombreCoche = 'Pagani Zonda Cinque Sleigh Runner' }

    @{ Logro = 'achievement_ACH_PURSUIT';           Titulo = 'FUGITIVO';        Que = 'persecuciones escapadas'
       Umbrales = @(1, 3, 5, 10, 15);                Unidad = 'n'
       Coche = 'GM_ACHIEVEMENT_0000018E';           NombreCoche = 'Koenigsegg CCX Achievement Edition' }

    @{ Logro = 'achievement_ACH_INCUR_COSTTOSTATE'; Titulo = 'ENEMIGO PUBLICO'; Que = 'dano al estado en persecuciones'
       Umbrales = @(100000, 300000, 500000, 1000000, 2000000); Unidad = 'cash'
       Coche = 'GM_ACHIEVEMENT_000001A7';           NombreCoche = 'Lamborghini Gallardo LP 550-2 Achievement Edition' }

    @{ Logro = 'achievement_ACH_CLOCKED_AIRTIME';   Titulo = 'VOLADOR';         Que = 'tiempo total en el aire (saltos en carrera)'
       Umbrales = @(30000, 60000, 120000, 180000, 300000); Unidad = 'ms'
       Coche = 'GM_ACHIEVEMENT_0000018C';           NombreCoche = 'BMW M3 E92 Achievement Edition' }

    @{ Logro = 'achievement_ACH_DRIVE_MILES';       Titulo = 'KILOMETROS';      Que = 'distancia recorrida en carrera'
       Umbrales = @(10000, 30000, 50000, 100000, 200000); Unidad = 'm'
       Coche = 'GM_ACHIEVEMENT_00000187';           NombreCoche = 'Ford Focus RS Achievement Edition' }

    @{ Logro = 'achievement_ACH_COPSDISABLED_TE';   Titulo = 'DEMOLEDOR';       Que = 'policias reventados en Team Escape'
       Umbrales = @(5, 15, 25, 50, 100);             Unidad = 'n'
       Coche = 'GM_ACHIEVEMENT_00000193';           NombreCoche = 'Car Prize Pack (sobre con coche)' }
)

# Escalera de premios comun a los rangos 1-4. Cada fila copia EXACTAMENTE el
# trio (clave, reward_type, reward_visual_style) con el que el juego ya usa
# esa clave en otros logros, para que el cliente la pinte igual que siempre.
$ESCALERA = @(
    @{ Rango = 1; Clave = 'GM_ACHIEVEMENT_0000016B'; Tipo = 'cash';     Estilo = 'achievements_rewards' }   # $100,000
    @{ Rango = 2; Clave = 'GM_ACHIEVEMENT_00000183'; Tipo = 'cash';     Estilo = 'achievements_rewards' }   # $250,000
    @{ Rango = 3; Clave = 'GM_ACHIEVEMENT_00000284'; Tipo = 'cash';     Estilo = 'achievements_rewards' }   # 500,000 Cash
    @{ Rango = 4; Clave = 'TXT_CARDPACK_DIAMOND';    Tipo = 'cardpack'; Estilo = 'blackdiamond' }           # Diamond Pack
)
# El rango 5 es el coche de cada reto. El Car Prize Pack del DEMOLEDOR no es
# un coche sino un sobre: lleva su propio tipo y estilo.
$ESTILO_RANGO5 = @{
    'GM_ACHIEVEMENT_00000193' = @{ Tipo = 'cardpack'; Estilo = 'cardpack_carprize' }
}
function Get-EstiloRango5 {
    param([string] $Clave)
    if ($ESTILO_RANGO5.ContainsKey($Clave)) { return $ESTILO_RANGO5[$Clave] }
    return @{ Tipo = 'car'; Estilo = 'achievements_rewards' }
}

# Logros cuyo disparador excluye las salas privadas: los tres de carreras.
# (Persecucion, dano al estado, saltos, distancia y Team Escape no llevan esa
# condicion: cuentan siempre.)
$LOGROS_CON_PRIVADAS = @(
    'achievement_ACH_PLAY_EVENTS', 'achievement_ACH_WIN_RACES_STREAK', 'achievement_ACH_WIN_DRAG'
)


# =====================================================================
#  UTILIDADES
# =====================================================================
function Invoke-Sql {
    <#
        Envoltorio de Invoke-Mysql que convierte los "ERROR nnnn" del cliente
        mysql en excepciones. En PowerShell 5.1 con ErrorActionPreference=Stop
        ya saltan solos; en 7 llegan como texto y pasarian desapercibidos.
    #>
    param([Parameter(Mandatory)][string] $Sql, [switch] $Escritura)
    $salida = @(Invoke-Mysql -Sql $Sql -ComoRoot:$Escritura)
    $fallo = $salida | Where-Object { "$_" -match '^ERROR \d+' } | Select-Object -First 1
    if ($fallo) { throw "MySQL: $fallo" }
    return $salida
}

function Get-ListaSqlNombres {
    <# 'a','b','c' para meter en un IN (...). #>
    return (($RETOS | ForEach-Object { "'" + $_.Logro + "'" }) -join ', ')
}

function Get-Parametro {
    param([string] $Nombre, [string] $Respaldo)
    try {
        $v = (Invoke-Sql -Sql "SELECT value FROM parameter WHERE name='$Nombre';") -join ''
        if ($v.Trim()) { return $v.Trim() }
    } catch { }
    return $Respaldo
}

function Format-Miles {
    param([long] $Valor)
    return [string]::Format([Globalization.CultureInfo]::GetCultureInfo('es-ES'), '{0:N0}', $Valor)
}

function Format-Valor {
    <# Pinta un umbral o un progreso en la unidad del reto. #>
    param([long] $Valor, [string] $Unidad)
    switch ($Unidad) {
        'cash' { return '$' + (Format-Miles $Valor) }
        'ms'   {
            if ($Valor -ge 60000) {
                $min = [math]::Round($Valor / 60000.0, 1)
                return ('{0} min' -f $min)
            }
            return ('{0} s' -f [math]::Round($Valor / 1000.0))
        }
        'm'    { return ('{0} km' -f [math]::Round($Valor / 1000.0, 1)) }
        default { return "$Valor" }
    }
}

function Test-RetosActivos {
    <# Hay copia de fabrica con filas = los retos estan aplicados. #>
    $n = (Invoke-Sql -Sql @"
SELECT COUNT(*) FROM information_schema.tables
 WHERE table_schema = DATABASE() AND table_name = '$TABLA_COPIA';
"@) -join ''
    if ([int]($n -replace '\D', '') -eq 0) { return $false }
    $filas = (Invoke-Sql -Sql "SELECT COUNT(*) FROM $TABLA_COPIA;") -join ''
    return ([int]($filas -replace '\D', '') -gt 0)
}

function Invoke-RecargaLogros {
    <#
        POST /Engine.svc/ReloadAchievements: el core vuelve a leer achievement
        y achievement_rank (AchievementBO.loadData). Sin esto, sigue jugando
        con los umbrales viejos que tiene en memoria.
    #>
    $token = Get-Parametro 'ADMIN_AUTH' $TOKEN_ADMIN_FALLBACK
    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$PUERTO_CORE/Engine.svc/ReloadAchievements" `
                -Method Post -TimeoutSec 20 -Body @{ adminAuth = $token }
        if ("$r" -match 'SUCCESS') { Write-Ok 'Logros recargados en el core (sin reiniciar).'; return $true }
        Write-Fallo "El core rechazo la recarga: $r"
        return $false
    } catch {
        Write-Aviso "El core no responde ($($_.Exception.Message))."
        Write-Host '       No pasa nada: los cargara solo al arrancar. Si YA esta arrancado,' -ForegroundColor Yellow
        Write-Host '       vuelve a ejecutar este script o reinicialo.' -ForegroundColor Yellow
        return $false
    }
}

function Send-Aviso {
    param([Parameter(Mandatory)][string] $Texto)
    $token = Get-Parametro 'ANNOUNCEMENT_AUTH' $TOKEN_AVISOS_FALLBACK
    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$PUERTO_CORE/Engine.svc/SendAnnouncement" `
                -Method Post -TimeoutSec 20 -Body @{ announcementAuth = $token; message = $Texto }
        return ("$r" -match 'SUCCESS')
    } catch { return $false }
}

function Show-Sql {
    param([string] $Sql)
    Write-Host ''
    Write-Host '  --- SQL que se ejecutaria (no se ejecuta nada) ---' -ForegroundColor DarkGray
    $Sql -split "`r?`n" | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    Write-Host '  --- fin del SQL ---' -ForegroundColor DarkGray
    Write-Host ''
}


# =====================================================================
#  APLICAR
# =====================================================================
if ($Aplicar) {
    Write-Titulo 'Retos de la noche - aplicar'

    # --- Prevuelo: que exista todo lo que vamos a tocar --------------
    # Si un logro no tiene sus 5 rangos o falta una clave de premio, se para
    # ANTES de escribir nada. Un premio con clave inexistente no falla al
    # aplicar: falla al canjear, delante del jugador, con una excepcion.
    Write-Paso 'Comprobando logros y premios en la base de datos...'
    $nombres = Get-ListaSqlNombres
    $filas = Invoke-Sql -Sql @"
SELECT a.name, COUNT(r.ID)
  FROM achievement a LEFT JOIN achievement_rank r ON r.achievement_id = a.ID
 WHERE a.name IN ($nombres)
 GROUP BY a.name;
"@
    $rangosPorLogro = @{}
    foreach ($f in $filas) { $c = "$f" -split "`t"; if ($c.Count -ge 2) { $rangosPorLogro[$c[0]] = [int]$c[1] } }
    $problemas = 0
    foreach ($reto in $RETOS) {
        if (-not $rangosPorLogro.ContainsKey($reto.Logro)) {
            Write-Fallo "No existe el logro $($reto.Logro)."; $problemas++
        } elseif ($rangosPorLogro[$reto.Logro] -ne 5) {
            Write-Fallo "$($reto.Logro) tiene $($rangosPorLogro[$reto.Logro]) rangos y se esperaban 5."; $problemas++
        }
    }

    $claves = @($ESCALERA | ForEach-Object { $_.Clave }) + @($RETOS | ForEach-Object { $_.Coche }) | Select-Object -Unique
    $listaClaves = ($claves | ForEach-Object { "'$_'" }) -join ', '
    $filas = Invoke-Sql -Sql @"
SELECT internal_reward_description, COUNT(*)
  FROM achievement_reward
 WHERE internal_reward_description IN ($listaClaves)
 GROUP BY internal_reward_description;
"@
    $encontradas = @{}
    foreach ($f in $filas) { $c = "$f" -split "`t"; if ($c.Count -ge 2) { $encontradas[$c[0]] = [int]$c[1] } }
    foreach ($k in $claves) {
        if (-not $encontradas.ContainsKey($k)) {
            Write-Fallo "Falta la clave de premio $k en achievement_reward."; $problemas++
        } elseif ($encontradas[$k] -ne 1) {
            # getSingleResult() revienta si hay dos filas con la misma clave.
            Write-Fallo "La clave de premio $k esta repetida ($($encontradas[$k]) filas)."; $problemas++
        }
    }
    if ($problemas -gt 0) {
        Write-Host ''
        Write-Fallo "$problemas problema(s). No se ha tocado nada."
        Write-Host ''
        exit 1
    }
    Write-Ok "$($RETOS.Count) logros con 5 rangos y $($claves.Count) claves de premio: todo existe."

    $yaActivos = Test-RetosActivos

    # --- Construir el SQL ----------------------------------------------
    # Todo en una transaccion: o se aplica entero o no se aplica. El CREATE
    # TABLE va fuera porque en MySQL el DDL hace commit implicito.
    $sql = New-Object System.Text.StringBuilder
    [void]$sql.AppendLine(@"
-- retos.ps1 -Aplicar  ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))
CREATE TABLE IF NOT EXISTS $TABLA_COPIA (
  rank_id             BIGINT       NOT NULL PRIMARY KEY,
  achievement_id      BIGINT       NOT NULL,
  achievement_name    VARCHAR(255) NOT NULL,
  threshold_value     INT,
  reward_type         VARCHAR(255),
  reward_description  VARCHAR(255),
  reward_visual_style VARCHAR(255),
  update_trigger      TEXT,
  guardado_en         DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

START TRANSACTION;

-- Copia de fabrica. INSERT IGNORE: si ya hay copia (segunda ejecucion),
-- NO se pisa con los valores ya recortados.
INSERT IGNORE INTO $TABLA_COPIA
       (rank_id, achievement_id, achievement_name, threshold_value,
        reward_type, reward_description, reward_visual_style, update_trigger)
SELECT r.ID, a.ID, a.name, r.threshold_value,
       r.reward_type, r.reward_description, r.reward_visual_style, a.update_trigger
  FROM achievement_rank r JOIN achievement a ON a.ID = r.achievement_id
 WHERE a.name IN ($nombres);
"@)

    foreach ($reto in $RETOS) {
        [void]$sql.AppendLine("-- $($reto.Titulo): $($reto.Que)")
        for ($i = 0; $i -lt 5; $i++) {
            $rango = $i + 1
            if ($rango -le 4) {
                $premio = $ESCALERA[$i]
                $clave = $premio.Clave; $tipo = $premio.Tipo; $estilo = $premio.Estilo
            } else {
                $e = Get-EstiloRango5 $reto.Coche
                $clave = $reto.Coche; $tipo = $e.Tipo; $estilo = $e.Estilo
            }
            # `rank` es palabra reservada en MySQL 8: va entre acentos graves,
            # igual que en la entidad del core (@Column(name = "`rank`")).
            # Los valores van en un array aparte: dentro de los parentesis de
            # un metodo (.AppendLine) las comas separan ARGUMENTOS del metodo,
            # no elementos, y -f se quedaria con un solo valor.
            $plantilla = 'UPDATE achievement_rank r JOIN achievement a ON a.ID = r.achievement_id' +
                         '   SET r.threshold_value = {0}, r.reward_type = ''{1}'', r.reward_description = ''{2}'', r.reward_visual_style = ''{3}''' +
                         ' WHERE a.name = ''{4}'' AND r.`rank` = {5};'
            $valores = @($reto.Umbrales[$i], $tipo, $clave, $estilo, $reto.Logro, $rango)
            [void]$sql.AppendLine(($plantilla -f $valores))
        }
    }

    if ($ContarPrivadas) {
        $listaPriv = ($LOGROS_CON_PRIVADAS | ForEach-Object { "'$_'" }) -join ', '
        [void]$sql.AppendLine(@"
-- -ContarPrivadas: que las carreras en sala privada tambien cuenten.
-- REPLACE de una cadena ausente no hace nada: repetirlo es seguro.
UPDATE achievement SET update_trigger = REPLACE(update_trigger, '$CLAUSULA_PRIVADAS', '')
 WHERE name IN ($listaPriv);
"@)
    }
    [void]$sql.AppendLine('COMMIT;')

    if ($Simular) {
        Show-Sql $sql.ToString()
        Write-Aviso 'Simulacion: no se ha tocado nada.'
        Write-Host ''
        return
    }

    Write-Paso $(if ($yaActivos) { 'Los retos ya estaban activos: se reaplican (la copia de fabrica se conserva).' } else { 'Guardando copia de fabrica y recortando...' })
    Invoke-Sql -Sql $sql.ToString() -Escritura | Out-Null
    Write-Ok "$($RETOS.Count) retos aplicados."
    if ($ContarPrivadas) { Write-Ok 'Las salas privadas tambien cuentan.' }

    Write-Host ''
    foreach ($reto in $RETOS) {
        $escalera = @()
        for ($i = 0; $i -lt 4; $i++) { $escalera += Format-Valor $reto.Umbrales[$i] $reto.Unidad }
        Write-Host ('    {0,-16} {1}' -f $reto.Titulo, $reto.Que) -ForegroundColor White
        Write-Host ('    {0,-16} {1}  ->  ...  {2} -> {3}' -f '', ($escalera -join ' / '), (Format-Valor $reto.Umbrales[4] $reto.Unidad), $reto.NombreCoche) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '    Rangos 1-4: 100.000 / 250.000 / 500.000 / Diamond Pack. Rango 5: el coche.' -ForegroundColor DarkGray
    Write-Host ''

    Invoke-RecargaLogros | Out-Null

    if (Send-Aviso 'RETOS DE LA NOCHE: los logros estan recortados a escala de fiesta. Cada rango paga, y el ultimo de cada reto es un coche. Mirad la pestana de logros.') {
        Write-Ok 'Anunciado por el megafono.'
    } else {
        Write-Aviso 'No pude anunciarlo (el core no responde). Los retos si estan aplicados.'
    }

    Write-Host ''
    Write-Host '    Quien ya este dentro ve los umbrales nuevos al volver a entrar; el servidor' -ForegroundColor DarkGray
    Write-Host '    ya cuenta con ellos desde ahora. Para ver quien lidera:  .\retos.ps1' -ForegroundColor DarkGray
    Write-Host ''
    Write-Registro ("retos.ps1 - aplicados $($RETOS.Count) retos" + $(if ($ContarPrivadas) { ' (salas privadas cuentan)' } else { '' }))
    return
}


# =====================================================================
#  REVERTIR
# =====================================================================
if ($Revertir) {
    Write-Titulo 'Retos de la noche - volver a fabrica'

    # Con -Simular se ensena el SQL aunque no haya nada aplicado, para poder
    # revisarlo antes de la fiesta.
    if (-not $Simular -and -not (Test-RetosActivos)) {
        Write-Host ''
        Write-Aviso 'No hay copia de fabrica: los retos no estan aplicados. Nada que revertir.'
        Write-Host ''
        return
    }

    # Se restaura cada rango por su ID (no por posicion) y el disparador de
    # cada logro. La copia tiene el mismo trigger repetido en sus 5 filas:
    # se coge con MIN() para que el UPDATE sea determinista.
    #
    # can_progress: el core lo pone a 0 cuando un piloto alcanza el umbral
    # maximo (updateAchievement: canProgress = newVal < maxVal) y despues ya
    # no vuelve a mirar ese logro. Quien haya hecho tope con la escala corta
    # se quedaria clavado para siempre con la larga. Se reabre a todos: el
    # core lo recalcula solo en el siguiente evento y no paga nada dos veces
    # (los rangos ya Completed/RewardWaiting se saltan).
    $sql = @"
-- retos.ps1 -Revertir  ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))
START TRANSACTION;
UPDATE achievement_rank r JOIN $TABLA_COPIA b ON b.rank_id = r.ID
   SET r.threshold_value     = b.threshold_value,
       r.reward_type         = b.reward_type,
       r.reward_description  = b.reward_description,
       r.reward_visual_style = b.reward_visual_style;
UPDATE achievement a
  JOIN (SELECT achievement_id, MIN(update_trigger) AS update_trigger
          FROM $TABLA_COPIA GROUP BY achievement_id) b ON b.achievement_id = a.ID
   SET a.update_trigger = b.update_trigger;
UPDATE persona_achievement SET can_progress = b'1'
 WHERE achievement_id IN (SELECT DISTINCT achievement_id FROM $TABLA_COPIA);
COMMIT;
DROP TABLE $TABLA_COPIA;
"@

    if ($Simular) {
        Show-Sql $sql
        Write-Aviso 'Simulacion: no se ha tocado nada.'
        Write-Host ''
        return
    }

    Write-Paso 'Restaurando umbrales, premios y condiciones de fabrica...'
    Invoke-Sql -Sql $sql -Escritura | Out-Null
    Write-Ok 'Logros de fabrica restaurados y copia borrada.'
    Write-Host ''
    Invoke-RecargaLogros | Out-Null
    Write-Host ''
    Write-Host '    Los premios ya cobrados se quedan: eran de verdad.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Registro 'retos.ps1 - revertidos a fabrica'
    return
}


# =====================================================================
#  LISTAR (por defecto)
# =====================================================================
Write-Titulo 'Retos de la noche - como estan'

$activos = Test-RetosActivos
Write-Host ''
if ($activos) {
    $desde = (Invoke-Sql -Sql "SELECT MIN(guardado_en) FROM $TABLA_COPIA;") -join ''
    Write-Host "    Estado: ACTIVOS desde $desde (copia de fabrica guardada)" -ForegroundColor Green
} else {
    Write-Host '    Estado: de fabrica (sin aplicar).  Para activarlos:  .\retos.ps1 -Aplicar' -ForegroundColor Yellow
}

$nombres = Get-ListaSqlNombres

# Escalera tal y como esta AHORA en la base de datos (no lo que dice este
# script): si alguien la toco a mano, aqui se ve.
$filasRangos = Invoke-Sql -Sql @"
SELECT a.name, r.``rank``, r.threshold_value, IFNULL(w.reward_description, r.reward_description),
       IF(a.update_trigger LIKE '%getIsPrivate()%', 'solo publicas', 'tambien privadas')
  FROM achievement_rank r
  JOIN achievement a ON a.ID = r.achievement_id
  LEFT JOIN achievement_reward w ON w.internal_reward_description = r.reward_description
 WHERE a.name IN ($nombres)
 ORDER BY a.ID, r.``rank``;
"@

# Quien va ganando: progreso por piloto y rangos ya conseguidos.
$filasProgreso = Invoke-Sql -Sql @"
SELECT a.name, p.name, pa.current_value,
       (SELECT COUNT(*) FROM persona_achievement_rank par
         WHERE par.persona_achievement_id = pa.ID
           AND par.state IN ('Completed', 'RewardWaiting'))
  FROM persona_achievement pa
  JOIN persona p ON p.ID = pa.persona_id
  JOIN achievement a ON a.ID = pa.achievement_id
 WHERE a.name IN ($nombres)
 ORDER BY a.ID, pa.current_value DESC, p.name;
"@

$rangos = @{}; $salas = @{}
foreach ($f in $filasRangos) {
    $c = "$f" -split "`t"
    if ($c.Count -lt 5) { continue }
    if (-not $rangos.ContainsKey($c[0])) { $rangos[$c[0]] = @() }
    $rangos[$c[0]] += [pscustomobject]@{ Rango = [int]$c[1]; Umbral = [long]$c[2]; Premio = $c[3] }
    $salas[$c[0]] = $c[4]
}
$progreso = @{}
foreach ($f in $filasProgreso) {
    $c = "$f" -split "`t"
    if ($c.Count -lt 4) { continue }
    if (-not $progreso.ContainsKey($c[0])) { $progreso[$c[0]] = @() }
    $progreso[$c[0]] += [pscustomobject]@{ Piloto = $c[1]; Valor = [long]$c[2]; Rangos = [int]$c[3] }
}

foreach ($reto in $RETOS) {
    Write-Host ''
    $sala = if ($salas.ContainsKey($reto.Logro) -and $LOGROS_CON_PRIVADAS -contains $reto.Logro) { "  [$($salas[$reto.Logro])]" } else { '' }
    Write-Host ('    {0,-16} {1}{2}' -f $reto.Titulo, $reto.Que, $sala) -ForegroundColor White

    if (-not $rangos.ContainsKey($reto.Logro)) {
        Write-Fallo "      No existe el logro $($reto.Logro) en la base de datos."
        continue
    }
    foreach ($r in ($rangos[$reto.Logro] | Sort-Object Rango)) {
        Write-Host ('      {0}. {1,-12} -> {2}' -f $r.Rango, (Format-Valor $r.Umbral $reto.Unidad), $r.Premio) -ForegroundColor DarkGray
    }

    if ($progreso.ContainsKey($reto.Logro)) {
        $top = @($progreso[$reto.Logro] | Where-Object { $_.Valor -gt 0 } | Select-Object -First 3)
        if ($top.Count -gt 0) {
            $linea = ($top | ForEach-Object { '{0} ({1}, {2} rangos)' -f $_.Piloto, (Format-Valor $_.Valor $reto.Unidad), $_.Rangos }) -join '   '
            Write-Host "      lideran: $linea" -ForegroundColor Cyan
        }
    }
}

Write-Host ''
Write-Host '    Aplicar: .\retos.ps1 -Aplicar      Volver a fabrica: .\retos.ps1 -Revertir' -ForegroundColor DarkGray
Write-Host ''
