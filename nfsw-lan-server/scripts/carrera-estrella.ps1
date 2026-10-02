<#
.SYNOPSIS
    La final de la noche: UN evento con premio GARANTIZADO al ganador.

.DESCRIPTION
    Convierte un evento (por nombre o por id) en la carrera estrella: el que
    gana se lleva un premio fijo (N millones o un coche concreto), el 2o y el
    3o se llevan dinero, se anuncia por el megafono y se puede deshacer.

    COMO FUNCIONA (verificado en el core: RewardBO, RewardRouteBO, ItemRewardBO):
      - Cada evento apunta a UNA fila de event_reward ("<id>_generic", la misma
        para individual, multijugador y sala privada: comprobado en los 165
        eventos). Esa fila tiene rewardTable_rank1_id..rank8_id: la mesa de
        premios del sorteo (lucky draw) segun el puesto en que acabas.
      - Al terminar la carrera, si el piloto ha acabado (finishReason 22), la
        carrera es legitima y ENABLE_DROP_ITEM esta a true, el core coge la
        mesa de SU puesto, tira un dado ponderado entre sus filas
        (reward_table_item.dropWeight) y ejecuta el script de la elegida.
        Una mesa con UNA sola fila es un premio seguro: no hay otra cosa que
        elegir. Es exactamente lo que monta este script.
      - generator.cashReward(N) suma N a persona.cash en el acto (tope
        MAX_PLAYER_CASH_FREE, 100.000.000 en este servidor) y ensena la carta
        de dinero en el sorteo.

    POR QUE EL COCHE NO VA DENTRO DEL SORTEO:
      La mesa del sorteo de una carrera pasa por RewardBO.getLuckyDrawItem(),
      que mete el producto con InventoryBO.addInventoryItem(). Para un coche
      (PRESETCAR) eso crea una fila en inventory_item, NO un coche en el
      garaje: BasketBO.addCar() solo lo llama ItemRewardBO.handleReward(),
      que usan los logros y los packs de cartas, nunca el sorteo de carrera.
      Un coche puesto en reward_table_item se pierde por el camino (ojo:
      eso mismo le pasa al COROLLA_BIC de la mesa de tesoro.ps1).
      Solucion: con -Coche el sorteo da una propina en efectivo y el coche lo
      entrega este script con -Entregar, que localiza al que quedo 1o en la
      ultima carrera del evento (tabla event_data) y llama a regalo.ps1, que
      escribe el coche igual que lo haria el servidor.

    CACHE Y REINICIOS (verificado en el core):
      event, event_reward, reward_table y reward_table_item se leen de la base
      de datos en cada carrera: ninguna entidad lleva @Cacheable, ningun DAO
      usa la cache de consultas y la mesa se busca por nombre
      (RewardTableDAO.findByName) al terminar cada carrera. NO hace falta
      reiniciar ni recargar nada: basta con configurarlo antes de que TERMINE
      la carrera (lo prudente: antes de que empiece). Lo unico que vive en
      memoria es la tabla parameter (ENABLE_DROP_ITEM): si hay que tocarla,
      este script la recarga con megafono.ps1 -Recargar.

.PARAMETER Evento
    Nombre (o parte del nombre) o id del evento. Ejemplos: 10, "Bay Bridge",
    "Camden Tunnel (Circuit)". Si hay varios que encajan, los lista y para.

.PARAMETER Dinero
    Millones GARANTIZADOS para el ganador (1-90). El 2o y el 3o se llevan
    la mitad y la cuarta parte (redondeando hacia arriba), salvo que digas
    otra cosa con -Segundo y -Tercero.

.PARAMETER Coche
    Etiqueta del coche (entitlementTag de un producto PRESETCAR, por ejemplo
    COROLLA_BIC) o su productId (SRV-CAR324). Busca etiquetas con
    .\regalo.ps1 -Listar <texto>. El ganador ve en el sorteo una propina de
    1.000.000 y el coche se le entrega despues con -Entregar.

.PARAMETER NombreCoche
    Como llamar al coche en los anuncios ("Toyota Corolla AE86"). Sin esto se
    usa el modelo que trae la definicion del coche (COROLLA, MR2, ZONDA...).

.PARAMETER Segundo
    Millones para el 2o (1-90). Por defecto: la mitad del ganador con
    -Dinero, 2 con -Coche.

.PARAMETER Tercero
    Millones para el 3o (1-90). Por defecto: la cuarta parte del ganador
    con -Dinero, 1 con -Coche.

.PARAMETER Entregar
    Tras la carrera, entrega el coche al que quedo 1o en la ultima manga del
    evento. Solo tiene sentido con una final de -Coche. No entrega dos veces
    por la misma carrera.

.PARAMETER Revertir
    Devuelve el evento a sus mesas de premios originales. Sin -Evento,
    revierte TODAS las finales configuradas y deja la base de datos como
    estaba (borra las mesas propias y la tabla de copia).

.PARAMETER Anunciar
    Ademas, lo canta por el megafono del juego.

.PARAMETER Simular
    Hace todas las comprobaciones y ENSENA el SQL, pero no toca nada.

.PARAMETER Estado
    Como esta la cosa: finales configuradas, mesas, y ultimos resultados del
    evento si das -Evento. Es lo que hace sin parametros.

.EXAMPLE
    .\carrera-estrella.ps1 -Evento "Bay Bridge" -Dinero 5 -Anunciar
    .\carrera-estrella.ps1 -Evento 10 -Coche COROLLA_BIC -NombreCoche "Toyota Corolla AE86" -Anunciar
    .\carrera-estrella.ps1 -Evento 10 -Entregar -Anunciar
    .\carrera-estrella.ps1 -Evento 10 -Estado
    .\carrera-estrella.ps1 -Revertir -Anunciar

.NOTES
    - Solo circuitos, sprints y drags: son los unicos modos con UN ganador.
      En persecucion todo el que acaba es "rank 1" y se llevaria el premio.
    - El premio se paga a TODOS los que acaben 1o mientras la final este
      puesta. Si quieres que solo pague una vez, revierte nada mas acabar.
    - La copia de las mesas originales vive en la tabla propia
      crazy_carrera_estrella (fuera de las entidades del core; hbm2ddl
      validate solo mira las suyas). Las mesas propias usan los ids
      90101-90103, fuera del rango del juego (tesoro.ps1 usa el 90001).
    - Todo queda en logs\carrera-estrella.log.
#>

[CmdletBinding(DefaultParameterSetName = 'Estado')]
param(
    [Parameter(ParameterSetName = 'Dinero',   Mandatory)]
    [Parameter(ParameterSetName = 'Coche',    Mandatory)]
    [Parameter(ParameterSetName = 'Entregar', Mandatory)]
    [Parameter(ParameterSetName = 'Revertir')]
    [Parameter(ParameterSetName = 'Estado', Position = 0)]
    [string] $Evento,

    [Parameter(ParameterSetName = 'Dinero', Mandatory)] [ValidateRange(1, 90)] [int] $Dinero,

    [Parameter(ParameterSetName = 'Coche', Mandatory)] [string] $Coche,
    [Parameter(ParameterSetName = 'Coche')]            [string] $NombreCoche,

    [Parameter(ParameterSetName = 'Dinero')]
    [Parameter(ParameterSetName = 'Coche')]
    [ValidateRange(1, 90)] [int] $Segundo,

    [Parameter(ParameterSetName = 'Dinero')]
    [Parameter(ParameterSetName = 'Coche')]
    [ValidateRange(1, 90)] [int] $Tercero,

    [Parameter(ParameterSetName = 'Entregar', Mandatory)] [switch] $Entregar,
    [Parameter(ParameterSetName = 'Revertir', Mandatory)] [switch] $Revertir,
    [Parameter(ParameterSetName = 'Estado')]              [switch] $Estado,

    [Parameter(ParameterSetName = 'Dinero')]
    [Parameter(ParameterSetName = 'Coche')]
    [Parameter(ParameterSetName = 'Entregar')]
    [Parameter(ParameterSetName = 'Revertir')]
    [switch] $Anunciar,

    [Parameter(ParameterSetName = 'Dinero')]
    [Parameter(ParameterSetName = 'Coche')]
    [Parameter(ParameterSetName = 'Entregar')]
    [Parameter(ParameterSetName = 'Revertir')]
    [switch] $Simular
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_comun.ps1')

# Mismo token que megafono.ps1 (lo pone party-setup.sql en la tabla parameter).
$TOKEN_AVISOS = 'CrazyMega2026'
$LOG_FINAL    = 'carrera-estrella.log'

# Mesas de premios propias. Ids fuera del rango del juego (max 2208) y del
# de tesoro.ps1 (90001). El core busca la mesa por NOMBRE (findByName), asi
# que el nombre importa tanto como el id.
$MESAS = @(
    @{ Puesto = 1; Id = 90101; Nombre = 'crazy_estrella_rank1' }
    @{ Puesto = 2; Id = 90102; Nombre = 'crazy_estrella_rank2' }
    @{ Puesto = 3; Id = 90103; Nombre = 'crazy_estrella_rank3' }
)
$IDS_MESAS = ($MESAS | ForEach-Object { $_.Id }) -join ', '

# Tabla propia donde se guarda lo que tenia cada evento antes de tocarlo.
$TABLA_COPIA = 'crazy_carrera_estrella'

# Con -Coche, lo que ve el ganador en el sorteo (el coche llega con -Entregar).
$PROPINA_COCHE = 1000000

# Modos con un unico ganador (EventMode.java): CIRCUIT=4, SPRINT=9, DRAG=19.
$MODOS_CON_GANADOR = @{ 4 = 'Circuito'; 9 = 'Sprint'; 19 = 'Drag' }
$NOMBRES_MODO      = @{ 4 = 'Circuito'; 9 = 'Sprint'; 19 = 'Drag'; 12 = 'Persecucion'; 24 = 'Team Escape'; 22 = 'Punto de encuentro' }


# =====================================================================
#  UTILIDADES
# =====================================================================

function Invoke-Sql {
    <#
        Invoke-Mysql con deteccion de errores: mysql.exe escribe los errores por
        stderr y a veces devuelve 0, asi que se mira si alguna linea empieza por
        ERROR. Se usa nfsw_user: tiene todos los privilegios sobre SOAPBOX.
    #>
    param([Parameter(Mandatory)][string] $Sql)
    try {
        $salida = @(Invoke-Mysql -Sql $Sql | ForEach-Object { "$_" })
    } catch {
        throw "MySQL: $($_.Exception.Message)"
    }
    $fallo = $salida | Where-Object { $_ -match '^ERROR \d+' } | Select-Object -First 1
    if ($fallo) { throw "MySQL: $fallo" }
    return $salida
}

function Invoke-Escritura {
    <# SQL que MODIFICA datos. Con -Simular solo lo ensena. #>
    param([Parameter(Mandatory)][string] $Sql)
    if ($Simular) {
        Write-Host ''
        Write-Host '    --- SIMULACION: este SQL NO se ejecuta ---' -ForegroundColor Magenta
        foreach ($linea in ($Sql.TrimEnd() -split "`n")) { Write-Host "    $($linea.TrimEnd())" -ForegroundColor DarkGray }
        Write-Host '    --- fin de la simulacion ---' -ForegroundColor Magenta
        Write-Host ''
        return @()
    }
    return (Invoke-Sql -Sql $Sql)
}

function Get-Filas {
    <# Ejecuta un SELECT y devuelve cada fila como array de columnas. #>
    param([Parameter(Mandatory)][string] $Sql)
    $filas = @()
    foreach ($linea in (Invoke-Sql -Sql $Sql)) {
        if ([string]::IsNullOrWhiteSpace($linea)) { continue }
        $filas += , @($linea -split "`t")
    }
    return , $filas
}

function Format-Texto {
    <# Escapa un valor para meterlo entre comillas simples en SQL. #>
    param([string] $Valor)
    return ($Valor -replace '\\', '\\\\' -replace "'", "''")
}

function Format-Dinero {
    param([double] $Valor)
    return ('{0:N0}' -f $Valor)
}

function Format-Millones {
    param([int] $Millones)
    return (Format-Dinero ([double]$Millones * 1000000))
}

function Format-Nulo {
    <# Un valor leido de MySQL, listo para un SET: NULL o el numero. #>
    param([string] $Valor)
    if ([string]::IsNullOrWhiteSpace($Valor) -or $Valor -eq 'NULL') { return 'NULL' }
    return $Valor
}

function Get-Parametro {
    param([Parameter(Mandatory)][string] $Nombre, [string] $Defecto = '')
    $f = Get-Filas -Sql "SELECT value FROM parameter WHERE name = '$(Format-Texto $Nombre)';"
    if ($f.Count -eq 0 -or [string]::IsNullOrWhiteSpace($f[0][0]) -or $f[0][0] -eq 'NULL') { return $Defecto }
    return $f[0][0]
}

function Send-Aviso {
    param([Parameter(Mandatory)][string] $Texto)
    if ($Simular) { Write-Host "    [megafono, simulado] $Texto" -ForegroundColor Magenta; return }
    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$PUERTO_CORE/Engine.svc/SendAnnouncement" `
                -Method Post -TimeoutSec 20 -Body @{ announcementAuth = $TOKEN_AVISOS; message = $Texto }
        if ("$r" -match 'SUCCESS') { Write-Ok "Anunciado: $Texto"; return }
        Write-Aviso "El megafono lo rechazo: $r"
    } catch {
        Write-Aviso 'No pude anunciarlo (el servidor del juego no responde). El cambio si esta hecho.'
    }
}

function Test-TablaCopia {
    $f = Get-Filas -Sql "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '$TABLA_COPIA';"
    return ([int]$f[0][0] -gt 0)
}

function Find-Evento {
    <# Localiza el evento por id o por (parte del) nombre. #>
    param([Parameter(Mandatory)][string] $Quien)
    $q = $Quien.Trim()
    if ($q -match '^\d+$') {
        $donde = "e.ID = $q"
    } else {
        $donde = "TRIM(e.name) LIKE '%$(Format-Texto $q)%'"
    }
    $filas = Get-Filas -Sql @"
SELECT e.ID, TRIM(e.name), e.eventModeId, e.maxPlayers, CAST(e.isEnabled AS UNSIGNED),
       e.singleplayer_reward_config_id, e.multiplayer_reward_config_id, e.private_reward_config_id
  FROM event e
 WHERE $donde
 ORDER BY e.ID;
"@
    if ($filas.Count -eq 0) {
        throw "No hay ningun evento que se llame '$Quien'. Prueba con parte del nombre (por ejemplo Bay Bridge) o con el id."
    }
    if ($filas.Count -gt 1) {
        Write-Aviso "Hay $($filas.Count) eventos que encajan con '$Quien'. Dime cual (por id o nombre completo):"
        foreach ($f in $filas) {
            $modo = $NOMBRES_MODO[[int]$f[2]]
            if (-not $modo) { $modo = "modo $($f[2])" }
            Write-Host ('       {0,4}  {1}  [{2}]' -f $f[0], $f[1], $modo) -ForegroundColor Yellow
        }
        throw 'Evento ambiguo.'
    }
    $f = $filas[0]
    # Los tres configs son la misma fila en toda la base de datos, pero por si
    # acaso se guardan todos los distintos y se tocan todos.
    $configs = @($f[5], $f[6], $f[7] | Select-Object -Unique)
    return [pscustomobject]@{
        Id           = [int]$f[0]
        Nombre       = $f[1]
        Modo         = [int]$f[2]
        MaxJugadores = [int]$f[3]
        Activo       = ($f[4] -eq '1')
        Configs      = $configs
    }
}

function Get-Finales {
    <# Filas de la tabla de copia: las finales configuradas ahora mismo. #>
    param([int] $SoloEvento = 0)
    if (-not (Test-TablaCopia)) { return @() }
    $donde = ''
    if ($SoloEvento -gt 0) { $donde = "WHERE c.event_id = $SoloEvento" }
    $filas = Get-Filas -Sql @"
SELECT c.event_id, c.reward_id, c.rank1_original, c.rank2_original, c.rank3_original,
       c.premio, IFNULL(c.coche, ''), IFNULL(c.entregado_sesion, 0), c.creado, TRIM(IFNULL(e.name, '?'))
  FROM $TABLA_COPIA c LEFT JOIN event e ON e.ID = c.event_id
  $donde
 ORDER BY c.event_id, c.reward_id;
"@
    $lista = @()
    foreach ($f in $filas) {
        $lista += [pscustomobject]@{
            EventoId  = [int]$f[0]
            RewardId  = $f[1]
            Rank1     = $f[2]
            Rank2     = $f[3]
            Rank3     = $f[4]
            Premio    = $f[5]
            Coche     = $f[6]
            Entregado = [long]$f[7]
            Creado    = $f[8]
            Nombre    = $f[9]
        }
    }
    return $lista
}

function Assert-DropActivo {
    <#
        Sin ENABLE_DROP_ITEM=true el core no hace sorteo (RewardBO.getEventLuckyDraw
        devuelve vacio) y el premio no se paga. Vive en memoria: hay que recargar.
    #>
    $valor = Get-Parametro 'ENABLE_DROP_ITEM' 'false'
    if ($valor -eq 'true') { return }
    Write-Aviso 'ENABLE_DROP_ITEM estaba apagado: sin el, el sorteo no existe. Lo enciendo y recargo.'
    Invoke-Escritura -Sql "INSERT INTO parameter (name, value) VALUES ('ENABLE_DROP_ITEM', 'true') ON DUPLICATE KEY UPDATE value = 'true';" | Out-Null
    if (-not $Simular) { & (Join-Path $PSScriptRoot 'megafono.ps1') -Recargar }
}

function Get-Coche {
    <# Producto PRESETCAR por etiqueta o productId, con el modelo de su definicion. #>
    param([Parameter(Mandatory)][string] $Etiqueta)
    $q = Format-Texto $Etiqueta.Trim()
    $f = Get-Filas -Sql @"
SELECT p.productId, p.entitlementTag, p.productTitle,
       UPPER(EXTRACTVALUE(b.ownedCarTrans, '/OwnedCarTrans/CustomCar/Name'))
  FROM product p JOIN basketdefinition b ON b.productId = p.productId
 WHERE p.productType = 'PRESETCAR' AND (p.entitlementTag = '$q' OR p.productId = '$q')
 ORDER BY p.productId LIMIT 1;
"@
    if ($f.Count -eq 0) { return $null }
    return [pscustomobject]@{
        ProductId = $f[0][0]
        Etiqueta  = $f[0][1]
        Titulo    = $f[0][2]
        Modelo    = $f[0][3]
    }
}


# =====================================================================
#  CONFIGURAR LA FINAL  (-Dinero / -Coche)
# =====================================================================
if ($PSCmdlet.ParameterSetName -in 'Dinero', 'Coche') {
    Write-Titulo 'Final de la noche'

    $ev = Find-Evento -Quien $Evento
    $modo = $NOMBRES_MODO[$ev.Modo]
    if (-not $modo) { $modo = "modo $($ev.Modo)" }
    Write-Host "    Evento: $($ev.Nombre)  (id $($ev.Id), $modo, $($ev.MaxJugadores) plazas)" -ForegroundColor DarkGray

    if (-not $MODOS_CON_GANADOR.ContainsKey($ev.Modo)) {
        Write-Fallo "Ese evento es de tipo '$modo' y ahi no hay UN ganador: en persecucion todo el que acaba es 1o y cobraria el premio."
        Write-Host '       Elige un circuito, un sprint o un drag.' -ForegroundColor Red
        Write-Host ''
        exit 1
    }
    if (-not $ev.Activo) {
        Write-Aviso 'El evento esta desactivado (isEnabled=0): nadie podra correrlo hasta activarlo y reiniciar el core.'
    }

    # --- Que se lleva cada puesto ---
    $coche = $null
    if ($PSCmdlet.ParameterSetName -eq 'Coche') {
        $coche = Get-Coche -Etiqueta $Coche
        if (-not $coche) {
            Write-Fallo "No hay ningun coche con la etiqueta '$Coche'. Busca con:  .\regalo.ps1 -Listar $Coche"
            Write-Host ''
            exit 1
        }
        if (-not $NombreCoche) { $NombreCoche = "$($coche.Modelo) $($coche.Titulo)".Trim() }
        $premio1 = $PROPINA_COCHE
        $millones2 = 2
        $millones3 = 1
        $textoPremio = "UN $NombreCoche (+ $(Format-Dinero $PROPINA_COCHE) de propina)"
    } else {
        $premio1 = [long]$Dinero * 1000000
        $millones2 = [int][math]::Ceiling($Dinero / 2.0)
        $millones3 = [int][math]::Ceiling($Dinero / 4.0)
        $textoPremio = "$(Format-Millones $Dinero) GARANTIZADOS"
    }
    if ($PSBoundParameters.ContainsKey('Segundo')) { $millones2 = $Segundo }
    if ($PSBoundParameters.ContainsKey('Tercero')) { $millones3 = $Tercero }
    $premio2 = [long]$millones2 * 1000000
    $premio3 = [long]$millones3 * 1000000

    Write-Host ''
    Write-Host "    1o  $textoPremio" -ForegroundColor White
    Write-Host "    2o  $(Format-Dinero $premio2)" -ForegroundColor Gray
    Write-Host "    3o  $(Format-Dinero $premio3)" -ForegroundColor Gray
    Write-Host ''

    # Otras finales ya puestas: se avisa, porque comparten las mismas tres mesas
    # y con esto les cambia el premio.
    $otras = @(Get-Finales | Where-Object { $_.EventoId -ne $ev.Id })
    if ($otras.Count -gt 0) {
        Write-Aviso "Ya hay otra final puesta ($(($otras | ForEach-Object { $_.Nombre }) -join ', ')). Comparten mesas: pasara a dar estos mismos premios."
        Write-Host '       Si no es lo que quieres:  .\carrera-estrella.ps1 -Revertir' -ForegroundColor Yellow
    }

    Assert-DropActivo

    # --- El SQL, todo junto en una sola ejecucion ---
    $premioTexto = Format-Texto $textoPremio
    $cocheSql = 'NULL'
    if ($coche) { $cocheSql = "'$(Format-Texto $coche.Etiqueta)'" }

    $sql = New-Object System.Text.StringBuilder
    # 1. Tabla de copia: lo que tenia cada evento antes de tocarlo, para revertir.
    [void]$sql.AppendLine(@"
CREATE TABLE IF NOT EXISTS $TABLA_COPIA (
  event_id         INT          NOT NULL,
  reward_id        VARCHAR(255) NOT NULL,
  rank1_original   BIGINT       NULL,
  rank2_original   BIGINT       NULL,
  rank3_original   BIGINT       NULL,
  premio           VARCHAR(255) NOT NULL,
  coche            VARCHAR(255) NULL,
  entregado_sesion BIGINT       NULL,
  creado           DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (event_id, reward_id)
) ENGINE=InnoDB;
"@)
    # 2. Mesas propias: se recrean enteras (idempotente). Una fila por mesa con
    #    dropWeight 1 = premio seguro. Las filas viejas se van con el DELETE
    #    (y con el FK ON DELETE CASCADE si alguien borra la mesa).
    foreach ($m in $MESAS) {
        [void]$sql.AppendLine("INSERT INTO reward_table (ID, name) VALUES ($($m.Id), '$($m.Nombre)') ON DUPLICATE KEY UPDATE name = '$($m.Nombre)';")
    }
    [void]$sql.AppendLine("DELETE FROM reward_table_item WHERE rewardTableEntity_ID IN ($IDS_MESAS);")
    [void]$sql.AppendLine("INSERT INTO reward_table_item (dropWeight, script, rewardTableEntity_ID) VALUES (1, 'generator.cashReward($premio1)', $($MESAS[0].Id));")
    [void]$sql.AppendLine("INSERT INTO reward_table_item (dropWeight, script, rewardTableEntity_ID) VALUES (1, 'generator.cashReward($premio2)', $($MESAS[1].Id));")
    [void]$sql.AppendLine("INSERT INTO reward_table_item (dropWeight, script, rewardTableEntity_ID) VALUES (1, 'generator.cashReward($premio3)', $($MESAS[2].Id));")
    # 3. Copia de lo original (solo la primera vez: si ya apunta a nuestras
    #    mesas, no hay nada original que guardar) y enganche del evento.
    foreach ($cfg in $ev.Configs) {
        $cfgSql = Format-Texto $cfg
        [void]$sql.AppendLine(@"
INSERT IGNORE INTO $TABLA_COPIA (event_id, reward_id, rank1_original, rank2_original, rank3_original, premio, coche)
SELECT $($ev.Id), ID, rewardTable_rank1_id, rewardTable_rank2_id, rewardTable_rank3_id, '$premioTexto', $cocheSql
  FROM event_reward
 WHERE ID = '$cfgSql' AND IFNULL(rewardTable_rank1_id, 0) NOT IN ($IDS_MESAS);
UPDATE $TABLA_COPIA SET premio = '$premioTexto', coche = $cocheSql, entregado_sesion = NULL
 WHERE event_id = $($ev.Id) AND reward_id = '$cfgSql';
UPDATE event_reward
   SET rewardTable_rank1_id = $($MESAS[0].Id),
       rewardTable_rank2_id = $($MESAS[1].Id),
       rewardTable_rank3_id = $($MESAS[2].Id)
 WHERE ID = '$cfgSql';
"@)
    }

    Invoke-Escritura -Sql $sql.ToString() | Out-Null

    if (-not $Simular) {
        # Comprobacion de que el evento apunta de verdad a nuestras mesas.
        $chk = Get-Filas -Sql "SELECT COUNT(*) FROM event_reward WHERE ID IN ($(($ev.Configs | ForEach-Object { "'$(Format-Texto $_)'" }) -join ',')) AND rewardTable_rank1_id = $($MESAS[0].Id) AND rewardTable_rank2_id = $($MESAS[1].Id) AND rewardTable_rank3_id = $($MESAS[2].Id);"
        if ([int]$chk[0][0] -ne $ev.Configs.Count) {
            Write-Fallo 'El evento no ha quedado enganchado a las mesas. Revisa event_reward a mano.'
            Write-Host ''
            exit 1
        }
    }

    Write-Ok "$($ev.Nombre) es la final de la noche. Se aplica a la siguiente carrera que termine: sin reiniciar nada."
    Write-Host ''
    if ($Anunciar) {
        Send-Aviso "FINAL DE LA NOCHE: $($ev.Nombre). El ganador se lleva $textoPremio. 2o: $(Format-Dinero $premio2), 3o: $(Format-Dinero $premio3). A la parrilla."
        Write-Host ''
    }
    if ($coche) {
        Write-Host "    Cuando acabe la carrera, entrega el coche:  .\carrera-estrella.ps1 -Evento $($ev.Id) -Entregar -Anunciar" -ForegroundColor DarkGray
    }
    Write-Host "    Para deshacerlo:  .\carrera-estrella.ps1 -Evento $($ev.Id) -Revertir" -ForegroundColor DarkGray
    Write-Host ''
    if (-not $Simular) {
        Write-Registro -Fichero $LOG_FINAL -Mensaje "carrera-estrella.ps1 - final puesta en evento $($ev.Id) ($($ev.Nombre)): 1o $textoPremio, 2o $premio2, 3o $premio3"
    }
    return
}


# =====================================================================
#  ENTREGAR EL COCHE AL GANADOR  (-Entregar)
# =====================================================================
if ($PSCmdlet.ParameterSetName -eq 'Entregar') {
    Write-Titulo 'Entrega del coche de la final'

    $ev = Find-Evento -Quien $Evento
    $final = @(Get-Finales -SoloEvento $ev.Id)
    if ($final.Count -eq 0) {
        Write-Fallo "$($ev.Nombre) no esta configurado como final. Ponlo primero con -Coche."
        Write-Host ''
        exit 1
    }
    $final = $final[0]
    if (-not $final.Coche) {
        Write-Ok "La final de $($ev.Nombre) es de dinero ($($final.Premio)): el sorteo ya lo paga solo. No hay nada que entregar."
        Write-Host ''
        return
    }

    # El ganador: el ultimo que acabo 1o (finishReason 22 = ha cruzado la meta;
    # con DNF o abandono no hay rank 1 con 22). isLegit lo pone el core al
    # calcular premios; si es 0, el sorteo no se le pago y aqui se avisa.
    $g = Get-Filas -Sql @"
SELECT ed.ID, IFNULL(ed.eventSessionId, 0), ed.personaId, p.name, CAST(IFNULL(ed.isLegit, 0) AS UNSIGNED),
       ed.eventDurationInMilliseconds, FROM_UNIXTIME(ed.serverTimeEnded / 1000)
  FROM event_data ed JOIN persona p ON p.ID = ed.personaId
 WHERE ed.EVENTID = $($ev.Id) AND ed.rank = 1 AND ed.finishReason = 22
 ORDER BY ed.ID DESC LIMIT 1;
"@
    if ($g.Count -eq 0) {
        Write-Aviso "Nadie ha cruzado la meta en 1o en $($ev.Nombre) todavia. Espera a que termine la carrera y repite."
        Write-Host ''
        return
    }
    $w = $g[0]
    $sesion    = [long]$w[1]
    $personaId = [long]$w[2]
    $nombre    = $w[3]
    $legit     = ($w[4] -eq '1')
    $segundos  = [math]::Round([double]$w[5] / 1000, 1)

    Write-Host "    Ganador: $nombre (persona $personaId), $segundos s, carrera terminada el $($w[6]) (sesion $sesion)." -ForegroundColor DarkGray
    if (-not $legit) {
        Write-Aviso 'El core marco esa carrera como NO legitima (isLegit=0): no le pago el sorteo. Tu decides si el coche va igual.'
    }
    if ($final.Entregado -eq $sesion -and $sesion -ne 0) {
        Write-Aviso "El coche de esa carrera (sesion $sesion) ya se entrego. No lo doy dos veces."
        Write-Host "       Si de verdad quieres otro:  .\regalo.ps1 -Jugador $personaId -Coche $($final.Coche)" -ForegroundColor Yellow
        Write-Host ''
        return
    }

    # regalo.ps1 escribe el coche exactamente como BasketBO.addCar() (car + paint +
    # piezas + vinilos) y comprueba hueco en el garaje. Se le pasa el id de
    # persona, que es inequivoco.
    Write-Paso "Entregando $($final.Coche) a $nombre con regalo.ps1..."
    $argsRegalo = @('-Jugador', "$personaId", '-Coche', $final.Coche)
    if ($Simular) { $argsRegalo += '-Simular' }
    $global:LASTEXITCODE = 0
    try {
        & (Join-Path $PSScriptRoot 'regalo.ps1') @argsRegalo
    } catch {
        Write-Fallo "regalo.ps1 fallo: $($_.Exception.Message)"
        Write-Host ''
        exit 1
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Fallo 'regalo.ps1 no pudo entregar el coche (mira el mensaje de arriba). No se marca como entregado.'
        Write-Host ''
        exit 1
    }

    Invoke-Escritura -Sql "UPDATE $TABLA_COPIA SET entregado_sesion = $sesion WHERE event_id = $($ev.Id);" | Out-Null

    Write-Ok "$nombre tiene su $($final.Coche) en el garaje. Que pase por el garaje (o salga y entre) para verlo."
    Write-Host ''
    if ($Anunciar) {
        Send-Aviso "$nombre GANA LA FINAL de $($ev.Nombre) y se lleva el coche. Enhorabuena, bestia."
        Write-Host ''
    }
    Write-Host "    Si la final ya ha terminado, quitale el premio al evento:  .\carrera-estrella.ps1 -Evento $($ev.Id) -Revertir" -ForegroundColor DarkGray
    Write-Host ''
    if (-not $Simular) {
        Write-Registro -Fichero $LOG_FINAL -Mensaje "carrera-estrella.ps1 - coche $($final.Coche) entregado a $nombre (persona $personaId) por evento $($ev.Id), sesion $sesion"
    }
    return
}


# =====================================================================
#  REVERTIR  (-Revertir)
# =====================================================================
if ($PSCmdlet.ParameterSetName -eq 'Revertir') {
    Write-Titulo 'Deshaciendo la final'

    $soloEvento = 0
    if ($Evento) { $soloEvento = (Find-Evento -Quien $Evento).Id }
    $finales = @(Get-Finales -SoloEvento $soloEvento)
    if ($finales.Count -eq 0) {
        if ($soloEvento -gt 0) { Write-Ok 'Ese evento no tiene final puesta: no hay nada que deshacer.' }
        else                   { Write-Ok 'No hay ninguna final puesta: no hay nada que deshacer.' }
        Write-Host ''
        return
    }

    $sql = New-Object System.Text.StringBuilder
    foreach ($fn in $finales) {
        Write-Host "    $($fn.Nombre)  (id $($fn.EventoId))  <-  mesas originales $($fn.Rank1) / $($fn.Rank2) / $($fn.Rank3)" -ForegroundColor DarkGray
        [void]$sql.AppendLine(@"
UPDATE event_reward
   SET rewardTable_rank1_id = $(Format-Nulo $fn.Rank1),
       rewardTable_rank2_id = $(Format-Nulo $fn.Rank2),
       rewardTable_rank3_id = $(Format-Nulo $fn.Rank3)
 WHERE ID = '$(Format-Texto $fn.RewardId)';
DELETE FROM $TABLA_COPIA WHERE event_id = $($fn.EventoId) AND reward_id = '$(Format-Texto $fn.RewardId)';
"@)
    }
    Invoke-Escritura -Sql $sql.ToString() | Out-Null

    # Limpieza: si ya nadie usa las mesas propias, fuera (las filas se van por
    # el FK ON DELETE CASCADE) y, si la tabla de copia queda vacia, fuera tambien.
    if (-not $Simular) {
        $usos = [int](Get-Filas -Sql "SELECT COUNT(*) FROM event_reward WHERE rewardTable_rank1_id IN ($IDS_MESAS) OR rewardTable_rank2_id IN ($IDS_MESAS) OR rewardTable_rank3_id IN ($IDS_MESAS);")[0][0]
        $quedan = [int](Get-Filas -Sql "SELECT COUNT(*) FROM $TABLA_COPIA;")[0][0]
        $limpieza = New-Object System.Text.StringBuilder
        if ($usos -eq 0)   { [void]$limpieza.AppendLine("DELETE FROM reward_table WHERE ID IN ($IDS_MESAS);") }
        if ($quedan -eq 0) { [void]$limpieza.AppendLine("DROP TABLE IF EXISTS $TABLA_COPIA;") }
        if ($limpieza.Length -gt 0) { Invoke-Sql -Sql $limpieza.ToString() | Out-Null }
    } else {
        Write-Host "    (y si nadie mas usa las mesas $IDS_MESAS se borran, junto con $TABLA_COPIA si queda vacia)" -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Ok "Premios normales otra vez en $($finales.Count) evento(s). Se aplica a la siguiente carrera que termine."
    Write-Host ''
    if ($Anunciar) {
        Send-Aviso 'La final ha terminado. Premios normales a partir de ahora.'
        Write-Host ''
    }
    if (-not $Simular) {
        Write-Registro -Fichero $LOG_FINAL -Mensaje "carrera-estrella.ps1 - final revertida en: $(($finales | ForEach-Object { $_.EventoId }) -join ', ')"
    }
    return
}


# =====================================================================
#  ESTADO (por defecto)
# =====================================================================
Write-Titulo 'Final de la noche - como esta'

$drop = Get-Parametro 'ENABLE_DROP_ITEM' 'false'
if ($drop -eq 'true') { Write-Host '    Sorteo (ENABLE_DROP_ITEM): activo' -ForegroundColor DarkGray }
else { Write-Aviso 'ENABLE_DROP_ITEM esta apagado: sin el no hay sorteo ni premio. Se enciende solo al poner una final.' }

$finales = @(Get-Finales)
Write-Host ''
if ($finales.Count -eq 0) {
    Write-Host '    No hay ninguna final puesta.' -ForegroundColor DarkGray
} else {
    foreach ($fn in $finales) {
        $entrega = ''
        if ($fn.Coche) {
            if ($fn.Entregado -gt 0) { $entrega = " - coche $($fn.Coche) ENTREGADO (sesion $($fn.Entregado))" }
            else                     { $entrega = " - coche $($fn.Coche) pendiente de -Entregar" }
        }
        Write-Host "    FINAL: $($fn.Nombre) (id $($fn.EventoId))  ->  $($fn.Premio)$entrega" -ForegroundColor White
        Write-Host "           puesta el $($fn.Creado); originales rank1/2/3 = $($fn.Rank1)/$($fn.Rank2)/$($fn.Rank3)" -ForegroundColor DarkGray
    }
}

# Lo que dan ahora mismo las mesas propias (si existen).
$items = Get-Filas -Sql "SELECT rt.ID, rt.name, i.dropWeight, i.script FROM reward_table rt LEFT JOIN reward_table_item i ON i.rewardTableEntity_ID = rt.ID WHERE rt.ID IN ($IDS_MESAS) ORDER BY rt.ID, i.ID;"
if ($items.Count -gt 0) {
    Write-Host ''
    Write-Host '    Mesas propias:' -ForegroundColor DarkGray
    foreach ($i in $items) { Write-Host ('      {0}  {1,-22} peso {2,-5} {3}' -f $i[0], $i[1], $i[2], $i[3]) -ForegroundColor DarkGray }
}

if ($Evento) {
    $ev = Find-Evento -Quien $Evento
    $modo = $NOMBRES_MODO[$ev.Modo]
    if (-not $modo) { $modo = "modo $($ev.Modo)" }
    Write-Host ''
    Write-Host "    Evento: $($ev.Nombre)  (id $($ev.Id), $modo, $($ev.MaxJugadores) plazas, activo=$($ev.Activo))" -ForegroundColor White
    $cfgLista = ($ev.Configs | ForEach-Object { "'$(Format-Texto $_)'" }) -join ','
    $mesas = Get-Filas -Sql @"
SELECT er.ID, IFNULL(er.rewardTable_rank1_id, 'NULL'), IFNULL(r1.name, '-'),
       IFNULL(er.rewardTable_rank2_id, 'NULL'), IFNULL(r2.name, '-'),
       IFNULL(er.rewardTable_rank3_id, 'NULL'), IFNULL(r3.name, '-')
  FROM event_reward er
  LEFT JOIN reward_table r1 ON r1.ID = er.rewardTable_rank1_id
  LEFT JOIN reward_table r2 ON r2.ID = er.rewardTable_rank2_id
  LEFT JOIN reward_table r3 ON r3.ID = er.rewardTable_rank3_id
 WHERE er.ID IN ($cfgLista);
"@
    foreach ($m in $mesas) {
        Write-Host "      config $($m[0]):  1o -> $($m[1]) ($($m[2]))   2o -> $($m[3]) ($($m[4]))   3o -> $($m[5]) ($($m[6]))" -ForegroundColor DarkGray
    }

    # Ultima manga corrida de ese evento.
    $res = Get-Filas -Sql @"
SELECT ed.rank, p.name, ed.finishReason, CAST(IFNULL(ed.isLegit, 0) AS UNSIGNED), ed.eventDurationInMilliseconds, FROM_UNIXTIME(ed.serverTimeEnded / 1000)
  FROM event_data ed JOIN persona p ON p.ID = ed.personaId
 WHERE ed.EVENTID = $($ev.Id)
   AND ed.eventSessionId = (SELECT MAX(eventSessionId) FROM event_data WHERE EVENTID = $($ev.Id))
 ORDER BY ed.rank;
"@
    Write-Host ''
    if ($res.Count -eq 0) {
        Write-Host '      Nadie ha corrido este evento todavia.' -ForegroundColor DarkGray
    } else {
        Write-Host "      Ultima manga ($($res[0][5])):" -ForegroundColor DarkGray
        foreach ($r in $res) {
            $estado = 'acabo'
            if ($r[2] -ne '22') { $estado = "no acabo (finishReason $($r[2]))" }
            if ($r[3] -ne '1')  { $estado += ', NO legitima' }
            Write-Host ('        {0}o  {1,-18} {2,8:N1} s   {3}' -f $r[0], $r[1], ([double]$r[4] / 1000), $estado) -ForegroundColor DarkGray
        }
    }
}

Write-Host ''
Write-Host '    Poner una final:  .\carrera-estrella.ps1 -Evento "Bay Bridge" -Dinero 5 -Anunciar' -ForegroundColor DarkGray
Write-Host '                      .\carrera-estrella.ps1 -Evento 10 -Coche COROLLA_BIC -Anunciar' -ForegroundColor DarkGray
Write-Host '    Deshacerla:       .\carrera-estrella.ps1 -Revertir' -ForegroundColor DarkGray
Write-Host ''
