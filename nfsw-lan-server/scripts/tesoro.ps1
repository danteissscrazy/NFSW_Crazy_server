<#
.SYNOPSIS
    Busqueda del tesoro: 15 monedas escondidas por la ciudad, todos a la vez.

.DESCRIPTION
    Es la mejor prueba de grupo del juego y casi nadie la usa asi. Por defecto
    cada jugador tiene las monedas en sitios distintos, asi que no compiten:
    cada cual va a su bola. Este script pone LA MISMA semilla a todo el mundo,
    de modo que los 50 buscan exactamente las mismas 15 monedas.

    Proyectado en el mapa en vivo, se ve a cincuenta coches convergiendo al
    mismo punto. Esa es la foto de la noche.

    Ademas monta una mesa de premios de verdad: quien la completa se lleva
    dinero a espuertas y, con suerte, un coche.

.PARAMETER Lanzar
    Reparte la misma caza a todos los pilotos conectados y lo anuncia.
    Se puede repetir tantas veces como quieras: cada vez, monedas nuevas.

.PARAMETER Premios
    Instala la mesa de premios gorda (dinero + posibilidad de coche).
    Solo hace falta ejecutarlo una vez.

.PARAMETER Estado
    Quien va ganando: monedas que lleva cada uno.

.PARAMETER Semilla
    Fuerza una semilla concreta. Sin esto se genera una nueva cada vez.
    Util si quieres repetir exactamente la misma caza en otra manga.

.EXAMPLE
    .\tesoro.ps1 -Premios      # una vez, al montar el servidor
    .\tesoro.ps1 -Lanzar       # cada vez que quieras una ronda
    .\tesoro.ps1 -Estado       # ver como va

.NOTES
    Los pilotos tienen que haber entrado al juego al menos una vez para que
    exista su ficha de caza. Lanzalo con la gente ya dentro, no antes.
#>

[CmdletBinding(DefaultParameterSetName = 'Estado')]
param(
    [Parameter(ParameterSetName = 'Lanzar')]  [switch] $Lanzar,
    [Parameter(ParameterSetName = 'Premios')] [switch] $Premios,
    [Parameter(ParameterSetName = 'Estado')]  [switch] $Estado,
    [Parameter(ParameterSetName = 'Lanzar')]  [int]    $Semilla = 0
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_comun.ps1')

$TOKEN_AVISOS = 'CrazyMega2026'
$ID_TABLA_PREMIOS = 90001   # ID propio, fuera del rango del juego (max 2208)

function Send-Aviso {
    param([string] $Texto)
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$PUERTO_CORE/Engine.svc/SendAnnouncement" `
            -Method Post -TimeoutSec 20 `
            -Body @{ announcementAuth = $TOKEN_AVISOS; message = $Texto } | Out-Null
        return $true
    } catch { return $false }
}


# =====================================================================
#  PREMIOS
# =====================================================================
if ($Premios) {
    Write-Titulo 'Mesa de premios de la busqueda del tesoro'

    # El juego usa un mini-lenguaje para los premios:
    #   generator.cashReward(N)                      -> dinero
    #   generator.rewardQuantityProduct('etiqueta',N) -> N unidades de un producto
    #   generator.weightedRandomTableItem('tabla')    -> tira de otra tabla
    # Los pesos (dropWeight) son relativos: no hace falta que sumen 1.
    #
    # COROLLA_BIC es el Toyota Corolla AE86 del juego base. Se regala aqui
    # como guino: es el unico Corolla de NFS World.
    $tablaPremios = @(
        @{ peso = 0.40; script = "generator.cashReward(500000)";                    que = 'Dinero: 500.000' }
        @{ peso = 0.25; script = "generator.cashReward(1500000)";                   que = 'Dinero: 1.500.000' }
        @{ peso = 0.15; script = "generator.rewardQuantityProduct('trafficmagnet', 25)"; que = '25 imanes de trafico' }
        @{ peso = 0.10; script = "generator.cashReward(5000000)";                   que = 'Dinero: 5.000.000' }
        @{ peso = 0.07; script = "generator.rewardQuantityProduct('COROLLA_BIC', 1)";    que = 'UN TOYOTA COROLLA AE86' }
        @{ peso = 0.03; script = "generator.rewardQuantityProduct('MR2_BIC', 1)";        que = 'UN TOYOTA MR2' }
    )

    $sql = New-Object System.Text.StringBuilder
    [void]$sql.AppendLine("DELETE FROM reward_table_item WHERE rewardTableEntity_ID = $ID_TABLA_PREMIOS;")
    [void]$sql.AppendLine("DELETE FROM reward_table WHERE ID = $ID_TABLA_PREMIOS;")
    [void]$sql.AppendLine("INSERT INTO reward_table (ID, name) VALUES ($ID_TABLA_PREMIOS, 'crazy_tesoro');")
    foreach ($p in $tablaPremios) {
        # Los scripts llevan comillas simples dentro (el nombre del producto),
        # asi que hay que duplicarlas o rompen la cadena SQL y el lote entero
        # se queda a medias sin avisar.
        $escapado = $p.script -replace "'", "''"
        [void]$sql.AppendLine(
            "INSERT INTO reward_table_item (dropWeight, script, rewardTableEntity_ID) VALUES ($($p.peso), '$escapado', $ID_TABLA_PREMIOS);")
    }
    # Se engancha a la configuracion del tesoro y se sube el dinero base.
    [void]$sql.AppendLine("UPDATE treasure_hunt_config SET reward_table_id = $ID_TABLA_PREMIOS, base_cash = 250000, base_rep = 50000;")

    Invoke-Mysql -Sql $sql.ToString() -ComoRoot | Out-Null

    Write-Host ''
    foreach ($p in $tablaPremios) {
        Write-Host ('    {0,5:P0}   {1}' -f $p.peso, $p.que) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Ok 'Mesa de premios instalada. Completar la caza da 250.000 fijos + un premio de la tabla.'
    Write-Host ''
    Write-Host '    Esto vive en la base de datos, asi que sobrevive a los reinicios.' -ForegroundColor DarkGray
    Write-Host '    Solo hay que ejecutarlo una vez.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Registro 'tesoro.ps1 - mesa de premios instalada'
    return
}


# =====================================================================
#  LANZAR UNA RONDA
# =====================================================================
if ($Lanzar) {
    Write-Titulo 'Lanzando busqueda del tesoro'

    $pilotos = [int]((Invoke-Mysql -Sql 'SELECT COUNT(*) FROM treasure_hunt;') -join '' -replace '\D', '')
    if ($pilotos -eq 0) {
        Write-Aviso 'Ningun piloto tiene ficha de caza todavia.'
        Write-Host '       Tienen que haber entrado al juego al menos una vez.' -ForegroundColor Yellow
        Write-Host '       Diles que entren y vuelve a lanzarlo.' -ForegroundColor Yellow
        Write-Host ''
        return
    }

    if ($Semilla -eq 0) {
        # Semilla nueva en cada ronda. Se evita el 0 porque el servidor lo
        # trata como "sin generar" y volveria a sortear una por jugador.
        $Semilla = Get-Random -Minimum 1000000 -Maximum 2000000000
    }

    # La clave de todo: MISMA semilla y MISMA fecha para todos. El servidor
    # solo regenera la caza si thDate no es hoy, asi que fijando hoy y
    # poniendo las monedas a cero, todos empiezan de nuevo en los mismos sitios.
    Invoke-Mysql -ComoRoot -Sql @"
UPDATE treasure_hunt
   SET seed           = $Semilla,
       thDate         = CURDATE(),
       coinsCollected = 0,
       isCompleted    = b'0',
       numCoins       = 15;
"@ | Out-Null

    Write-Ok "Caza repartida a $pilotos pilotos (semilla $Semilla)."
    Write-Host ''

    if (Send-Aviso 'BUSQUEDA DEL TESORO: 15 monedas escondidas por la ciudad, las MISMAS para todos. El primero que las junte se lleva el premio gordo. Si ya estabas dentro, sal y vuelve a entrar para verlas.') {
        Write-Ok 'Anunciado por el megafono (sale en el chat del juego).'
    } else {
        Write-Aviso 'No pude anunciarlo (el servidor del juego no responde). La caza si esta repartida.'
    }

    # El juego pide la caza UNA vez, al entrar (Events/gettreasurehunteventsession),
    # y no vuelve a preguntar. No hay ningun "evento" que salte en pantalla: son
    # las 15 monedas del mapa. Quien ya estaba dentro sigue con la caza vieja
    # hasta que salga y entre. Lo ideal: lanzarla ANTES de que entre la gente.
    Write-Host ''
    Write-Host '    OJO: los que ya estan dentro del juego siguen con la caza anterior' -ForegroundColor Yellow
    Write-Host '    hasta que salgan y vuelvan a entrar. Los que entren a partir de ahora' -ForegroundColor Yellow
    Write-Host '    ya la ven. No salta ningun aviso en pantalla: son las monedas del mapa.' -ForegroundColor Yellow

    Write-Host ''
    Write-Host '    Para ver como van:  .\tesoro.ps1 -Estado' -ForegroundColor DarkGray
    Write-Host '    Para otra ronda:    .\tesoro.ps1 -Lanzar' -ForegroundColor DarkGray
    Write-Host ''
    Write-Registro "tesoro.ps1 - ronda lanzada, semilla $Semilla, $pilotos pilotos"
    return
}


# =====================================================================
#  ESTADO (por defecto)
# =====================================================================
Write-Titulo 'Busqueda del tesoro - como van'

$filas = Invoke-Mysql -Sql @"
SELECT p.name, th.coinsCollected, th.seed, th.isCompleted
  FROM treasure_hunt th JOIN persona p ON p.ID = th.personaId
 ORDER BY th.coinsCollected DESC, p.name;
"@

if (-not $filas) {
    Write-Host ''
    Write-Aviso 'Nadie tiene caza activa. Lanzala con:  .\tesoro.ps1 -Lanzar'
    Write-Host ''
    return
}

Write-Host ''
Write-Host ('    {0,-18} {1,-10} {2}' -f 'PILOTO', 'MONEDAS', '') -ForegroundColor DarkGray
Write-Host ''

$semillas = @{}
foreach ($f in $filas) {
    $c = "$f" -split "`t"
    if ($c.Count -lt 3) { continue }
    $nombre = $c[0]
    # coinsCollected es una mascara de bits: cada moneda es un bit.
    # 32767 = 0b111111111111111 = las 15 cogidas.
    $mascara = [int]$c[1]
    $cuantas = [Convert]::ToString($mascara, 2).ToCharArray() | Where-Object { $_ -eq '1' } | Measure-Object | Select-Object -ExpandProperty Count
    $semillas[$c[2]] = $true

    $barra = ('#' * $cuantas).PadRight(15, '.')
    $color = if ($cuantas -ge 15) { 'Green' } elseif ($cuantas -gt 0) { 'Yellow' } else { 'DarkGray' }
    Write-Host ('    {0,-18} {1,2}/15    ' -f $nombre, $cuantas) -NoNewline
    Write-Host $barra -ForegroundColor $color
}

Write-Host ''
if ($semillas.Count -gt 1) {
    Write-Aviso "Hay $($semillas.Count) cazas distintas: no estan compitiendo por las mismas monedas."
    Write-Host '       Lanza una ronda para igualarlos:  .\tesoro.ps1 -Lanzar' -ForegroundColor Yellow
} else {
    Write-Ok 'Todos buscan las mismas 15 monedas.'
}
Write-Host ''
