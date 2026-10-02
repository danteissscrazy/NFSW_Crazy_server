<#
.SYNOPSIS
    Regala a un piloto un coche del catalogo, dinero o un objeto. Conectado o no.

.DESCRIPTION
    El organizador premia a quien quiera desde PowerShell: el coche del sorteo,
    un pellizco de dinero al que se ha quedado sin nada, o piezas y powerups.
    No hace falta que el jugador este conectado: si lo esta, lo ve al volver al
    garaje (coche/objetos) o tras la siguiente carrera (dinero); si no, lo
    tiene esperando al entrar.

    COMO LLEGA DE VERDAD UN PREMIO AL JUGADOR (verificado en el core):
      - Un sorteo (lucky draw), una tabla de premios o un logro acaban en
        ItemRewardBO.handleReward(), que hace tres cosas y solo tres:
          coche   -> BasketBO.addCar(): lee el XML de `basketdefinition` del
                     producto PRESETCAR y lo vuelca en `car` + `paint` +
                     `performancepart` + `skillmodpart` + `vinyl` + `visualpart`.
          dinero  -> DriverPersonaBO.updateCash(): `persona.cash`, con tope
                     MAX_PLAYER_CASH_FREE/PREMIUM y suelo 0.
          objeto  -> InventoryBO.addInventoryItem() / addStackedInventoryItem():
                     fila en `inventory_item` (los powerups se apilan) y contador
                     de huecos usados en `inventory`.
      - No hay ninguna API de administracion para regalar: los unicos POST con
        adminAuth son ReloadParameters, ReloadAchievements y
        ReloadLoginAnnouncements. Los comandos de chat de admin (AdminBO) solo
        saben /ban, /kick y /unban.
      Asi que este script escribe EXACTAMENTE lo que escribiria el servidor,
      en las mismas tablas y con los mismos valores, en una sola transaccion.

    CACHE Y REINICIOS (verificado en el core):
      - persistence.xml enciende la cache de segundo nivel de Hibernate, pero
        NINGUNA entidad lleva @Cacheable ni @Cache, y ningun DAO usa la pista
        org.hibernate.cacheable. Con el modo por defecto (ENABLE_SELECTIVE) eso
        significa que `persona`, `car`, `inventory` e `inventory_item` se leen
        de la base de datos en cada peticion. Este script NO necesita reiniciar
        nada ni recargar nada.
      - Lo que SI vive en memoria del core: `parameter` (ParameterBO, se
        recarga con /ReloadParameters), logros (AchievementBO,
        /ReloadAchievements), anuncios de login (/ReloadLoginAnnouncements) y
        las sesiones de juego (TokenSessionBO: solo memoria, no hay tabla).
      - Lo que cachea el CLIENTE (esto es el juego, no el core): el garaje lo
        pide en /personas/{id}/carslots al entrar al garaje y al iniciar
        sesion; el inventario y el dinero, al iniciar sesion y con cada
        resultado de compra o carrera. De ahi los avisos de "que pase por el
        garaje"; salir y volver a entrar lo garantiza siempre.

.PARAMETER Jugador
    Nombre del piloto (tal como sale en el juego, MAYUSCULAS), el correo de la
    cuenta, o el numero de persona. Solo con esto, muestra su ficha.

.PARAMETER Coche
    Etiqueta del coche del catalogo (columna entitlementTag de un producto
    PRESETCAR), por ejemplo COROLLA_BIC o MR2_BIC. Vale tambien el productId
    (SRV-CAR324). Busca etiquetas con -Listar.

.PARAMETER Dinero
    Cantidad a regalar. En negativo, la retira. El servidor pone tope
    (MAX_PLAYER_CASH_*) y suelo 0, y aqui se respetan.

.PARAMETER Objeto
    Etiqueta (entitlementTag) o productId de un powerup, pieza de rendimiento,
    skill mod, pieza visual o amplificador. Por ejemplo trafficmagnet.

.PARAMETER Cantidad
    Unidades del objeto. Por defecto, las que trae el producto (15 en los
    powerups, 1 en las piezas).

.PARAMETER Quitar
    Con -Coche o -Objeto: deshace el regalo (borra el ultimo coche de ese
    modelo, o resta las unidades). Para el dinero basta con -Dinero negativo.

.PARAMETER Anunciar
    Ademas, lo canta por el megafono del juego para que se entere todo el mundo.

.PARAMETER Simular
    Hace todas las comprobaciones y ENSENA el SQL que ejecutaria, pero no toca
    la base de datos. Para probar sin miedo.

.PARAMETER Listar
    Lista el catalogo de coches regalables. Con un texto detras, filtra por
    etiqueta, modelo o titulo y busca tambien objetos.

.EXAMPLE
    .\regalo.ps1 -Listar corolla
    .\regalo.ps1 PRUEBAMODS
    .\regalo.ps1 -Jugador PRUEBAMODS -Coche COROLLA_BIC -Anunciar
    .\regalo.ps1 -Jugador pruebamods@crazy.party -Dinero 2000000
    .\regalo.ps1 -Jugador PRUEBAMODS -Objeto trafficmagnet -Cantidad 10
    .\regalo.ps1 -Jugador PRUEBAMODS -Coche COROLLA_BIC -Quitar

.NOTES
    - Todo queda apuntado en logs\regalos.log con el id de cada coche, por si
      hay que deshacer algo a mano.
    - El coche se inserta con la clase y el rating que trae su definicion (los
      mismos que muestra el catalogo). No se pisa el coche que el jugador esta
      usando: se anade al final del garaje y curCarIndex no se toca.
    - Los powerups no se gastan en este servidor (ENABLE_POWERUP_DECREASE =
      false), asi que regalarlos es mas simbolico que otra cosa. Las piezas y
      los amplificadores si se notan.
    - "Conectado" se mira preguntando a Openfire (el chat) por la sesion
      sbrw.<personaId>, que es el usuario XMPP que el core crea por piloto.
      Si el chat no esta arrancado, se dice "no lo se" y se sigue.
#>

[CmdletBinding(DefaultParameterSetName = 'Ver')]
param(
    [Parameter(ParameterSetName = 'Ver', Position = 0)]
    [Parameter(ParameterSetName = 'Coche',  Mandatory)]
    [Parameter(ParameterSetName = 'Dinero', Mandatory)]
    [Parameter(ParameterSetName = 'Objeto', Mandatory)]
    [Parameter(ParameterSetName = 'Creditos', Mandatory)]
    [string] $Jugador,

    [Parameter(ParameterSetName = 'Coche',  Mandatory)] [string] $Coche,
    [Parameter(ParameterSetName = 'Dinero', Mandatory)] [long]   $Dinero,
    [Parameter(ParameterSetName = 'Creditos', Mandatory)] [long] $Creditos,
    [Parameter(ParameterSetName = 'Objeto', Mandatory)] [string] $Objeto,
    [Parameter(ParameterSetName = 'Objeto')] [ValidateRange(0, 10000)] [int] $Cantidad = 0,

    [Parameter(ParameterSetName = 'Coche')]
    [Parameter(ParameterSetName = 'Objeto')]
    [switch] $Quitar,

    [Parameter(ParameterSetName = 'Coche')]
    [Parameter(ParameterSetName = 'Dinero')]
    [Parameter(ParameterSetName = 'Objeto')]
    [Parameter(ParameterSetName = 'Creditos')]
    [switch] $Anunciar,

    [Parameter(ParameterSetName = 'Coche')]
    [Parameter(ParameterSetName = 'Dinero')]
    [Parameter(ParameterSetName = 'Objeto')]
    [Parameter(ParameterSetName = 'Creditos')]
    [switch] $Simular,

    [Parameter(ParameterSetName = 'Listar', Mandatory)] [switch] $Listar,
    [Parameter(ParameterSetName = 'Listar', Position = 0)] [string] $Filtro
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_comun.ps1')

# Mismo token que megafono.ps1 (lo pone party-setup.sql en la tabla parameter).
$TOKEN_AVISOS = 'CrazyMega2026'
$LOG_REGALOS  = 'regalos.log'

# Tipos de producto que el servidor sabe meter en un inventario (InventoryBO).
# AMPLIFIER no lo reparte ItemRewardBO, pero BasketBO.addAmplifier lo mete con
# addInventoryItem igual que una pieza, asi que aqui se admite.
$TIPOS_OBJETO = @('POWERUP', 'PERFORMANCEPART', 'SKILLMODPART', 'VISUALPART', 'AMPLIFIER')


# =====================================================================
#  UTILIDADES
# =====================================================================

function Invoke-Sql {
    <#
        Invoke-Mysql con deteccion de errores. mysql.exe escribe los errores por
        stderr y sigue devolviendo codigo 0 en algunos casos, asi que ademas de
        la excepcion se mira si alguna linea empieza por "ERROR".
        Se usa el usuario de la aplicacion (nfsw_user): es el mismo con el que
        escribe el core, asi que si el core puede, esto puede.
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
    <#
        Ejecuta SQL que MODIFICA datos. Con -Simular solo lo ensena por
        pantalla y devuelve vacio, para poder ensayar sin tocar nada.
    #>
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

function Get-Parametro {
    <# Lee un valor de la tabla parameter, con valor por defecto. #>
    param([Parameter(Mandatory)][string] $Nombre, [string] $Defecto = '')
    $f = Get-Filas -Sql "SELECT value FROM parameter WHERE name = '$(Format-Texto $Nombre)';"
    if ($f.Count -eq 0 -or [string]::IsNullOrWhiteSpace($f[0][0]) -or $f[0][0] -eq 'NULL') { return $Defecto }
    return $f[0][0]
}

function Find-Piloto {
    <#
        Localiza al piloto por nombre, por correo de la cuenta o por id.
        Devuelve un objeto con todo lo que hace falta despues.
    #>
    param([Parameter(Mandatory)][string] $Quien)
    $q = Format-Texto $Quien.Trim()
    if ($Quien -match '^\d+$') {
        $donde = "p.ID = $Quien"
    } elseif ($Quien -like '*@*') {
        $donde = "u.EMAIL = '$q'"
    } else {
        $donde = "p.name = '$q'"
    }
    $filas = Get-Filas -Sql @"
SELECT p.ID, p.name, p.cash, p.level, p.curCarIndex, u.ID, u.EMAIL, CAST(u.premium AS UNSIGNED)
  FROM persona p JOIN user u ON u.ID = p.USERID
 WHERE $donde
 ORDER BY p.ID;
"@
    if ($filas.Count -eq 0) {
        if ($Quien -like '*@*') {
            $cuenta = Get-Filas -Sql "SELECT ID FROM user WHERE EMAIL = '$q';"
            if ($cuenta.Count -gt 0) {
                throw "La cuenta $Quien existe pero todavia no tiene piloto. Que entre al juego y cree uno; luego repite."
            }
        }
        throw "No encuentro ningun piloto ni cuenta que se llame '$Quien'. Mira que este bien escrito (los pilotos van en MAYUSCULAS)."
    }
    if ($filas.Count -gt 1) {
        Write-Aviso "Esa cuenta tiene $($filas.Count) pilotos. Dime cual con -Jugador <nombre>:"
        foreach ($f in $filas) { Write-Host "       $($f[1])  (id $($f[0]))" -ForegroundColor Yellow }
        throw 'Piloto ambiguo.'
    }
    $f = $filas[0]
    return [pscustomobject]@{
        Id          = [long]$f[0]
        Nombre      = $f[1]
        Cash        = [double]$f[2]
        Nivel       = [int]$f[3]
        CurCarIndex = [int]$f[4]
        UserId      = [long]$f[5]
        Email       = $f[6]
        Premium     = ($f[7] -eq '1')
    }
}

function Test-Conectado {
    <#
        Pregunta a Openfire si el piloto tiene sesion de chat abierta. El core
        crea un usuario XMPP "sbrw.<personaId>" por piloto y el juego se
        conecta con el nada mas elegir piloto, asi que es un buen chivato.
        Devuelve $true, $false o $null (chat apagado o sin respuesta).
    #>
    param([Parameter(Mandatory)][long] $PersonaId)
    $base  = Get-Parametro 'OPENFIRE_ADDRESS'
    $token = Get-Parametro 'OPENFIRE_TOKEN'
    if (-not $base -or -not $token) { return $null }
    try {
        $r = Invoke-WebRequest -Uri "$($base.TrimEnd('/'))/sessions/sbrw.$PersonaId" -TimeoutSec 5 -UseBasicParsing `
                -Headers @{ Authorization = $token; Accept = 'application/xml' }
        $x = [xml]$r.Content
        return (@($x.SelectNodes('//session')).Count -gt 0)
    } catch {
        return $null
    }
}

function Write-Conexion {
    param([Parameter(Mandatory)][long] $PersonaId)
    $c = Test-Conectado -PersonaId $PersonaId
    if ($c -eq $true)      { Write-Host '    Estado: CONECTADO ahora mismo' -ForegroundColor Green }
    elseif ($c -eq $false) { Write-Host '    Estado: desconectado' -ForegroundColor DarkGray }
    else                   { Write-Host '    Estado: no lo se (el chat no responde)' -ForegroundColor DarkGray }
    return $c
}

function Send-Aviso {
    param([Parameter(Mandatory)][string] $Texto)
    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$PUERTO_CORE/Engine.svc/SendAnnouncement" `
                -Method Post -TimeoutSec 20 -Body @{ announcementAuth = $TOKEN_AVISOS; message = $Texto }
        if ("$r" -match 'SUCCESS') { Write-Ok 'Anunciado por el megafono.'; return }
        Write-Aviso "El megafono lo rechazo: $r"
    } catch {
        Write-Aviso 'No pude anunciarlo (el servidor del juego no responde). El regalo si esta dado.'
    }
}

function Get-Producto {
    <# Busca un producto por etiqueta o productId, limitado a unos tipos. #>
    param(
        [Parameter(Mandatory)][string]   $Etiqueta,
        [Parameter(Mandatory)][string[]] $Tipos
    )
    $q = Format-Texto $Etiqueta.Trim()
    $lista = ($Tipos | ForEach-Object { "'$_'" }) -join ','
    $f = Get-Filas -Sql @"
SELECT productId, entitlementTag, productTitle, productType, useCount, resalePrice, durationMinute, hash
  FROM product
 WHERE productType IN ($lista) AND (entitlementTag = '$q' OR productId = '$q')
 ORDER BY productId LIMIT 1;
"@
    if ($f.Count -eq 0) { return $null }
    $p = $f[0]
    return [pscustomobject]@{
        ProductId  = $p[0]
        Etiqueta   = $p[1]
        Titulo     = $p[2]
        Tipo       = $p[3].ToUpper()
        UseCount   = [int]$p[4]
        Resale     = [double]$p[5]
        Minutos    = [int]$p[6]
        Hash       = $p[7]
    }
}

function Get-NombreModelo {
    <# Nombre "bonito" del modelo (car_classes.full_name) a partir del physicsProfileHash. #>
    param([Parameter(Mandatory)][string] $PhysicsHash, [string] $Defecto)
    $f = Get-Filas -Sql "SELECT full_name FROM car_classes WHERE hash = $PhysicsHash LIMIT 1;"
    if ($f.Count -gt 0 -and $f[0][0]) { return $f[0][0] }
    return $Defecto
}

function Get-Nodo {
    <# Texto de un hijo del XML, o el valor por defecto si no existe. #>
    param($Padre, [string] $Nombre, [string] $Defecto = '0')
    $n = $Padre.SelectSingleNode($Nombre)
    if ($null -eq $n -or [string]::IsNullOrWhiteSpace($n.InnerText)) { return $Defecto }
    return $n.InnerText.Trim()
}

function Get-Numero {
    param($Padre, [string] $Nombre, [long] $Defecto = 0)
    return [long](Get-Nodo $Padre $Nombre "$Defecto")
}

function Get-Bit {
    <# true/false del XML -> literal b'1'/b'0' de MySQL. #>
    param($Padre, [string] $Nombre)
    if ((Get-Nodo $Padre $Nombre 'false') -eq 'true') { return "b'1'" }
    return "b'0'"
}


# =====================================================================
#  LISTAR CATALOGO
# =====================================================================
if ($PSCmdlet.ParameterSetName -eq 'Listar') {
    Write-Titulo 'Catalogo regalable'

    $tiposLista = "'PRESETCAR'"
    $condicion  = ''
    if ($Filtro) {
        # Con filtro se buscan tambien objetos; sin filtro solo coches, que ya
        # son casi 400 lineas.
        $tiposLista = "'PRESETCAR'," + (($TIPOS_OBJETO | ForEach-Object { "'$_'" }) -join ',')
        $q = Format-Texto $Filtro
        $condicion = @"
   AND (p.entitlementTag LIKE '%$q%' OR p.productTitle LIKE '%$q%'
        OR ExtractValue(b.ownedCarTrans, '//CustomCar/Name') LIKE '%$q%'
        OR cc.full_name LIKE '%$q%')
"@
    }

    # El titulo de un PRESETCAR es solo el color o la variante ("C-SPEC",
    # "RED"); el modelo de verdad esta en car_classes.full_name, enganchado
    # por el physicsProfileHash que va dentro del XML de basketdefinition.
    $filas = Get-Filas -Sql @"
SELECT p.productType, p.entitlementTag,
       COALESCE(cc.full_name, ''), p.productTitle, p.level, p.price
  FROM product p
  LEFT JOIN basketdefinition b ON b.productId = p.productId
  LEFT JOIN car_classes cc ON cc.hash = CAST(ExtractValue(b.ownedCarTrans, '//CustomCar/PhysicsProfileHash') AS SIGNED)
 WHERE p.productType IN ($tiposLista) AND p.enabled = b'1'
   $condicion
 ORDER BY p.productType, cc.full_name, p.entitlementTag;
"@

    Write-Host ''
    if ($filas.Count -eq 0) {
        Write-Aviso "Nada que encaje con '$Filtro'."
        Write-Host ''
        return
    }
    Write-Host ('    {0,-14} {1,-32} {2,-30} {3,-16} {4,5} {5,12}' -f 'TIPO', 'ETIQUETA', 'MODELO', 'TITULO', 'NIVEL', 'PRECIO') -ForegroundColor DarkGray
    foreach ($f in $filas) {
        $color = if ($f[0] -eq 'PRESETCAR') { 'White' } else { 'Gray' }
        Write-Host ('    {0,-14} {1,-32} {2,-30} {3,-16} {4,5} {5,12}' -f $f[0], $f[1], $f[2], $f[3], $f[4], (Format-Dinero $f[5])) -ForegroundColor $color
    }
    Write-Host ''
    Write-Host "    $($filas.Count) productos. Se regala con la ETIQUETA:  .\regalo.ps1 -Jugador PILOTO -Coche ETIQUETA" -ForegroundColor DarkGray
    if (-not $Filtro) { Write-Host '    Filtra con:  .\regalo.ps1 -Listar corolla   (busca tambien objetos)' -ForegroundColor DarkGray }
    Write-Host ''
    return
}


# =====================================================================
#  LOCALIZAR AL PILOTO (comun a todo lo demas)
# =====================================================================
if (-not $Jugador) {
    Write-Titulo 'Regalos'
    Write-Host ''
    Write-Host '    .\regalo.ps1 -Listar [texto]                       catalogo' -ForegroundColor DarkGray
    Write-Host '    .\regalo.ps1 PILOTO                                ficha del piloto' -ForegroundColor DarkGray
    Write-Host '    .\regalo.ps1 -Jugador PILOTO -Coche ETIQUETA        regala un coche' -ForegroundColor DarkGray
    Write-Host '    .\regalo.ps1 -Jugador PILOTO -Dinero 1000000        regala dinero (negativo: lo quita)' -ForegroundColor DarkGray
    Write-Host '    .\regalo.ps1 -Jugador PILOTO -Creditos 500000       regala creditos / SpeedBoost' -ForegroundColor DarkGray
    Write-Host '    .\regalo.ps1 -Jugador PILOTO -Objeto ETIQUETA       regala un objeto' -ForegroundColor DarkGray
    Write-Host '    ... -Quitar   deshace     ... -Anunciar   lo canta por el megafono' -ForegroundColor DarkGray
    Write-Host ''
    return
}

try {
    $piloto = Find-Piloto -Quien $Jugador
} catch {
    Write-Titulo 'Regalo'
    Write-Fallo $_.Exception.Message
    Write-Host ''
    exit 1
}


# =====================================================================
#  VER FICHA
# =====================================================================
if ($PSCmdlet.ParameterSetName -eq 'Ver') {
    Write-Titulo "Piloto $($piloto.Nombre)"
    Write-Host "    Cuenta: $($piloto.Email)   (persona $($piloto.Id))" -ForegroundColor DarkGray
    Write-Conexion -PersonaId $piloto.Id | Out-Null
    Write-Host "    Dinero: $(Format-Dinero $piloto.Cash)     Nivel: $($piloto.Nivel)"
    Write-Host ''

    $coches = Get-Filas -Sql @"
SELECT c.id, c.name, COALESCE(cc.full_name, c.name), c.rating, c.ownershipType, COALESCE(c.expirationDate, '')
  FROM car c LEFT JOIN car_classes cc ON cc.hash = c.physicsProfileHash
 WHERE c.personaId = $($piloto.Id)
 ORDER BY c.id;
"@
    $limite = if ($piloto.Premium) { Get-Parametro 'MAX_CAR_SLOTS_PREMIUM' '200' } else { Get-Parametro 'MAX_CAR_SLOTS_FREE' '200' }
    Write-Host "    Garaje: $($coches.Count) de $limite coches (en uso: #$($piloto.CurCarIndex))" -ForegroundColor DarkGray
    $i = 0
    foreach ($c in $coches) {
        $marca = if ($i -eq $piloto.CurCarIndex) { '>' } else { ' ' }
        $extra = if ($c[4] -eq 'RentalCar') { "  alquiler hasta $($c[5])" } else { '' }
        Write-Host ('    {0} #{1,-3} id {2,-5} {3,-32} rating {4,4}{5}' -f $marca, $i, $c[0], $c[2], $c[3], $extra)
        $i++
    }

    $inv = Get-Filas -Sql @"
SELECT i.id, i.performancePartsUsedSlotCount, i.performancePartsCapacity,
       i.skillModPartsUsedSlotCount, i.skillModPartsCapacity,
       i.visualPartsUsedSlotCount, i.visualPartsCapacity,
       (SELECT COUNT(*) FROM inventory_item it WHERE it.inventoryEntity_id = i.id)
  FROM inventory i WHERE i.personaId = $($piloto.Id);
"@
    Write-Host ''
    if ($inv.Count -eq 0) {
        Write-Host '    Inventario: todavia no existe (se crea en su primera entrada al juego).' -ForegroundColor DarkGray
    } else {
        $v = $inv[0]
        Write-Host "    Inventario: $($v[7]) objetos. Huecos: rendimiento $($v[1])/$($v[2]), skill $($v[3])/$($v[4]), visual $($v[5])/$($v[6])" -ForegroundColor DarkGray
        $items = Get-Filas -Sql @"
SELECT p.productType, p.entitlementTag, p.productTitle, it.remainingUseCount, COALESCE(it.expirationDate, '')
  FROM inventory_item it JOIN product p ON p.productId = it.productId
 WHERE it.inventoryEntity_id = $($v[0])
 ORDER BY p.productType, p.entitlementTag;
"@
        foreach ($it in $items) {
            $exp = if ($it[4]) { "  caduca $($it[4])" } else { '' }
            Write-Host ('      {0,-15} {1,-34} x{2,-4}{3}' -f $it[0], $it[1], $it[3], $exp) -ForegroundColor Gray
        }
    }
    Write-Host ''
    return
}


# =====================================================================
#  DINERO
# =====================================================================
if ($PSCmdlet.ParameterSetName -eq 'Dinero') {
    Write-Titulo "Dinero para $($piloto.Nombre)"
    if ($Dinero -eq 0) { Write-Aviso 'Cero no es un regalo.'; Write-Host ''; return }

    # Mismo tope y suelo que DriverPersonaBO.updateCash():
    #   max(0, min(getMaxCash(user), cash + N)) con MAX_PLAYER_CASH_* (9.999.999 por defecto).
    $tope = if ($piloto.Premium) { Get-Parametro 'MAX_PLAYER_CASH_PREMIUM' '9999999' } else { Get-Parametro 'MAX_PLAYER_CASH_FREE' '9999999' }
    # -Simular tiene que decidirse ANTES de escribir. Hasta el 2026-09-06 el UPDATE
    # iba primero y luego el script decia "no se ha tocado nada": mentia, ya lo habia
    # tocado. Cualquier ensayo con -Simular cambiaba el dinero de verdad.
    if ($Simular) {
        $nuevo = [math]::Max(0, [math]::Min([double]$tope, $piloto.Cash + $Dinero))
        Write-Aviso "Simulado: se quedaria con $(Format-Dinero $nuevo). No se ha tocado nada."
        Write-Host ''
        return
    }

    Invoke-Escritura -Sql @"
UPDATE persona SET cash = GREATEST(0, LEAST($tope, cash + ($Dinero))) WHERE ID = $($piloto.Id);
"@ | Out-Null
    $nuevo = [double](Get-Filas -Sql "SELECT cash FROM persona WHERE ID = $($piloto.Id);")[0][0]

    $verbo = if ($Dinero -gt 0) { 'Regalados' } else { 'Retirados' }
    Write-Ok "$verbo $(Format-Dinero ([math]::Abs($Dinero))). Ahora tiene $(Format-Dinero $nuevo) (antes $(Format-Dinero $piloto.Cash))."
    if ($nuevo -ne ($piloto.Cash + $Dinero)) {
        Write-Aviso "Ha chocado con el tope ($(Format-Dinero ([double]$tope))) o con el suelo (0): es lo mismo que haria el servidor."
    }
    $conectado = Write-Conexion -PersonaId $piloto.Id
    if ($conectado -ne $false) {
        Write-Host '    Si esta dentro, el marcador se le actualiza al acabar la siguiente carrera o compra.' -ForegroundColor DarkGray
    }
    if ($Anunciar -and $Dinero -gt 0) {
        Send-Aviso "REGALO: $($piloto.Nombre) se lleva $(Format-Dinero $Dinero) en efectivo. Enhorabuena."
    }
    Write-Registro -Fichero $LOG_REGALOS -Mensaje "regalo.ps1 - dinero $Dinero a $($piloto.Nombre) (persona $($piloto.Id)) -> cash $nuevo"
    Write-Host ''
    return
}


# =====================================================================
#  CREDITOS (SpeedBoost)
#
#  La segunda moneda del juego: la del rayo en el marcador de arriba. En
#  el servidor es `persona.boost`, y el core la entrega tal cual al entrar
#  (DriverPersonaBO -> ProfileData.setBoost). No existe un parametro de
#  tope como con el dinero, asi que se usa el mismo techo que el efectivo
#  para no meter una cifra que el marcador del juego no sepa dibujar.
#
#  Se ve al ENTRAR: si el piloto ya esta dentro, tiene que salir y volver.
# =====================================================================
if ($PSCmdlet.ParameterSetName -eq 'Creditos') {
    Write-Titulo "Creditos para $($piloto.Nombre)"
    if ($Creditos -eq 0) { Write-Aviso 'Cero no es un regalo.'; Write-Host ''; return }

    $antes = [double](Get-Filas -Sql "SELECT boost FROM persona WHERE ID = $($piloto.Id);")[0][0]
    $tope  = 100000000

    if ($Simular) {
        $previsto = [math]::Max(0, [math]::Min([double]$tope, $antes + $Creditos))
        Write-Aviso "Simulado: se quedaria con $(Format-Dinero $previsto) creditos. No se ha tocado nada."
        Write-Host ''
        return
    }

    Invoke-Escritura -Sql @"
UPDATE persona SET boost = GREATEST(0, LEAST($tope, boost + ($Creditos))) WHERE ID = $($piloto.Id);
"@ | Out-Null
    $nuevo = [double](Get-Filas -Sql "SELECT boost FROM persona WHERE ID = $($piloto.Id);")[0][0]

    $verbo = if ($Creditos -gt 0) { 'Regalados' } else { 'Retirados' }
    Write-Ok "$verbo $(Format-Dinero ([math]::Abs($Creditos))) creditos. Ahora tiene $(Format-Dinero $nuevo) (antes $(Format-Dinero $antes))."
    if ($nuevo -ne ($antes + $Creditos)) {
        Write-Aviso "Ha chocado con el tope ($(Format-Dinero ([double]$tope))) o con el suelo (0)."
    }
    $conectado = Write-Conexion -PersonaId $piloto.Id
    if ($conectado -eq $true) {
        Write-Host '    Esta dentro: tiene que salir del juego y volver a entrar para verlo.' -ForegroundColor Yellow
    }
    if ($Anunciar -and $Creditos -gt 0) {
        Send-Aviso "REGALO: $($piloto.Nombre) se lleva $(Format-Dinero $Creditos) creditos."
    }
    Write-Registro -Fichero $LOG_REGALOS -Mensaje "regalo.ps1 - creditos $Creditos a $($piloto.Nombre) (persona $($piloto.Id)) -> boost $nuevo"
    Write-Host ''
    return
}


# =====================================================================
#  COCHE
# =====================================================================
if ($PSCmdlet.ParameterSetName -eq 'Coche') {
    $producto = Get-Producto -Etiqueta $Coche -Tipos @('PRESETCAR')
    if (-not $producto) {
        Write-Titulo 'Coche'
        Write-Fallo "No hay ningun coche con la etiqueta '$Coche'. Busca con:  .\regalo.ps1 -Listar $Coche"
        Write-Host ''
        exit 1
    }

    # La definicion del coche (XML OwnedCarTrans) vive en basketdefinition,
    # una por productId. Es exactamente lo que BasketBO.getCar() deserializa
    # cuando alguien lo compra o lo gana en un sorteo.
    $def = Get-Filas -Sql "SELECT ownedCarTrans FROM basketdefinition WHERE productId = '$(Format-Texto $producto.ProductId)';"
    if ($def.Count -eq 0 -or -not $def[0][0]) {
        Write-Titulo 'Coche'
        Write-Fallo "El producto $($producto.ProductId) ($($producto.Etiqueta)) no tiene definicion en basketdefinition: el servidor tampoco podria venderlo."
        Write-Host ''
        exit 1
    }
    $xml = [xml]$def[0][0]
    $cc  = $xml.OwnedCarTrans.CustomCar
    if (-not $cc) { Write-Fallo 'La definicion no trae CustomCar.'; exit 1 }

    $nombreCorto = Get-Nodo $cc 'Name' $producto.Etiqueta
    $physics     = Get-Nodo $cc 'PhysicsProfileHash' '0'
    $modelo      = Get-NombreModelo -PhysicsHash $physics -Defecto $nombreCorto
    $esAlquiler  = $producto.Minutos -gt 0

    # ---------------------------------------------------------------
    #  QUITAR: borrar el ultimo coche de ese modelo
    # ---------------------------------------------------------------
    if ($Quitar) {
        Write-Titulo "Quitar $modelo a $($piloto.Nombre)"
        $victima = Get-Filas -Sql @"
SELECT id, ownershipType, (SELECT COUNT(*) FROM car c2 WHERE c2.personaId = c.personaId AND c2.id < c.id)
  FROM car c
 WHERE personaId = $($piloto.Id) AND name = '$(Format-Texto $nombreCorto)' AND physicsProfileHash = $physics
 ORDER BY id DESC LIMIT 1;
"@
        if ($victima.Count -eq 0) {
            Write-Aviso "$($piloto.Nombre) no tiene ningun $modelo."
            Write-Host ''
            return
        }
        $carId  = [long]$victima[0][0]
        $indice = [int]$victima[0][2]

        # Misma regla que BasketBO.removeCar(): nunca dejar al piloto sin un
        # coche propio (los alquileres no cuentan).
        $propios = [int](Get-Filas -Sql "SELECT COUNT(*) FROM car WHERE personaId = $($piloto.Id) AND expirationDate IS NULL;")[0][0]
        if ($victima[0][1] -ne 'RentalCar' -and $propios -le 1) {
            Write-Fallo 'Es su unico coche propio. El servidor tampoco dejaria venderlo. No se toca.'
            Write-Host ''
            exit 1
        }

        $conectado = Write-Conexion -PersonaId $piloto.Id
        if ($conectado -eq $true -and $indice -eq $piloto.CurCarIndex) {
            Write-Fallo 'Esta CONECTADO y es justo el coche que tiene puesto. Quitarselo ahora lo deja sin coche en pista. Que cambie de coche o que salga, y repite.'
            Write-Host ''
            exit 1
        }

        # paint/vinyl/... caen solos por ON DELETE CASCADE. curCarIndex es la
        # posicion del coche en la lista ordenada por id: si el borrado iba
        # antes del que usa, todo lo de detras baja un puesto.
        Invoke-Escritura -Sql @"
START TRANSACTION;
DELETE FROM car WHERE id = $carId AND personaId = $($piloto.Id);
UPDATE persona
   SET curCarIndex = CASE WHEN curCarIndex > $indice THEN curCarIndex - 1 ELSE curCarIndex END
 WHERE ID = $($piloto.Id);
UPDATE persona
   SET curCarIndex = GREATEST(0, LEAST(curCarIndex, (SELECT COUNT(*) FROM car WHERE personaId = $($piloto.Id)) - 1))
 WHERE ID = $($piloto.Id);
COMMIT;
"@ | Out-Null
        if ($Simular) { Write-Aviso "Simulado: se borraria el coche id $carId. No se ha tocado nada."; Write-Host ''; return }
        Write-Ok "Borrado el $modelo (coche id $carId) del garaje de $($piloto.Nombre)."
        Write-Registro -Fichero $LOG_REGALOS -Mensaje "regalo.ps1 - QUITADO coche id $carId ($($producto.Etiqueta)) a $($piloto.Nombre) (persona $($piloto.Id))"
        Write-Host ''
        return
    }

    # ---------------------------------------------------------------
    #  REGALAR
    # ---------------------------------------------------------------
    Write-Titulo "$modelo para $($piloto.Nombre)"
    Write-Host "    Producto: $($producto.Etiqueta) ($($producto.ProductId), '$($producto.Titulo)')" -ForegroundColor DarkGray

    # Mismas comprobaciones que BasketBO.buyCar()/addCar():
    #  - hueco en el garaje (MAX_CAR_SLOTS_*)
    #  - un alquiler solo si ya tiene un coche propio
    $numCoches = [int](Get-Filas -Sql "SELECT COUNT(*) FROM car WHERE personaId = $($piloto.Id);")[0][0]
    $limite = [int]$(if ($piloto.Premium) { Get-Parametro 'MAX_CAR_SLOTS_PREMIUM' '200' } else { Get-Parametro 'MAX_CAR_SLOTS_FREE' '200' })
    if ($numCoches -ge $limite) {
        Write-Fallo "Garaje lleno ($numCoches de $limite). Que venda algo primero."
        Write-Host ''
        exit 1
    }
    if ($esAlquiler) {
        $propios = [int](Get-Filas -Sql "SELECT COUNT(*) FROM car WHERE personaId = $($piloto.Id) AND expirationDate IS NULL;")[0][0]
        if ($propios -eq 0) {
            Write-Fallo 'Es un coche de alquiler y el piloto no tiene ningun coche propio: el servidor lo rechazaria.'
            Write-Host ''
            exit 1
        }
    }

    # --- Traducir el XML a filas, con las MISMAS reglas que el servidor ---
    #  BasketBO.getCar():  heat = 1, durability = 100, resalePrice = la del producto
    #  addCar():           ownershipType queda "CustomizedCar" (el "PresetCar" del
    #                      XML no se copia: trans2Entity lo pisa con el valor por
    #                      defecto de la entidad); alquiler -> "RentalCar" + caducidad.
    #  trans2Entity():     el resto de campos, tal cual vienen en <CustomCar>.
    if ($esAlquiler) {
        $ownership  = 'RentalCar'
        $expiracion = "DATE_ADD(NOW(), INTERVAL $($producto.Minutos) MINUTE)"
    } else {
        $ownership  = 'CustomizedCar'
        $expiracion = 'NULL'
    }

    $sql = New-Object System.Text.StringBuilder
    [void]$sql.AppendLine('START TRANSACTION;')
    [void]$sql.AppendLine(@"
INSERT INTO car (durability, expirationDate, heat, ownershipType, personaId, baseCar, carClassHash, isPreset,
                 level, name, physicsProfileHash, rating, resalePrice, rideHeightDrop, skillModSlotCount, version)
VALUES (100, $expiracion, 1, '$ownership', $($piloto.Id), $(Get-Numero $cc 'BaseCar'), $(Get-Numero $cc 'CarClassHash'), $(Get-Bit $cc 'IsPreset'),
        $(Get-Numero $cc 'Level'), '$(Format-Texto $nombreCorto)', $physics, $(Get-Numero $cc 'Rating'), $($producto.Resale),
        $(Get-Nodo $cc 'RideHeightDrop' '0'), $(Get-Numero $cc 'SkillModSlotCount'), $(Get-Numero $cc 'Version'));
SET @car := LAST_INSERT_ID();
"@)

    # Cada lista del XML va a su tabla. Si la lista viene vacia no se emite
    # el INSERT (un INSERT sin VALUES es un error de sintaxis).
    $paints = @($cc.SelectNodes('Paints/CustomPaintTrans'))
    if ($paints.Count -gt 0) {
        $v = ($paints | ForEach-Object {
            '({0}, {1}, {2}, {3}, {4}, @car)' -f (Get-Numero $_ 'Group'), (Get-Numero $_ 'Hue'), (Get-Numero $_ 'Sat'), (Get-Numero $_ 'Slot'), (Get-Numero $_ 'Var')
        }) -join ",`n"
        [void]$sql.AppendLine("INSERT INTO paint (paintGroup, hue, sat, slot, paintVar, carId) VALUES`n$v;")
    }

    $perf = @($cc.SelectNodes('PerformanceParts/PerformancePartTrans'))
    if ($perf.Count -gt 0) {
        $v = ($perf | ForEach-Object { '({0}, @car)' -f (Get-Numero $_ 'PerformancePartAttribHash') }) -join ",`n"
        [void]$sql.AppendLine("INSERT INTO performancepart (performancePartAttribHash, carId) VALUES`n$v;")
    }

    $skill = @($cc.SelectNodes('SkillModParts/SkillModPartTrans'))
    if ($skill.Count -gt 0) {
        $v = ($skill | ForEach-Object { '({0}, {1}, @car)' -f (Get-Bit $_ 'IsFixed'), (Get-Numero $_ 'SkillModPartAttribHash') }) -join ",`n"
        [void]$sql.AppendLine("INSERT INTO skillmodpart (isFixed, skillModPartAttribHash, carId) VALUES`n$v;")
    }

    $vinilos = @($cc.SelectNodes('Vinyls/CustomVinylTrans'))
    if ($vinilos.Count -gt 0) {
        $v = ($vinilos | ForEach-Object {
            '({0}, {1}, {2}, {3}, {4}, {5}, {6}, {7}, {8}, {9}, {10}, {11}, {12}, {13}, {14}, {15}, {16}, {17}, {18}, {19}, {20}, @car)' -f `
                (Get-Numero $_ 'Hash'), (Get-Numero $_ 'Hue1'), (Get-Numero $_ 'Hue2'), (Get-Numero $_ 'Hue3'), (Get-Numero $_ 'Hue4'),
                (Get-Numero $_ 'Layer'), (Get-Bit $_ 'Mir'), (Get-Numero $_ 'Rot'),
                (Get-Numero $_ 'Sat1'), (Get-Numero $_ 'Sat2'), (Get-Numero $_ 'Sat3'), (Get-Numero $_ 'Sat4'),
                (Get-Numero $_ 'ScaleX'), (Get-Numero $_ 'ScaleY'), (Get-Numero $_ 'Shear'),
                (Get-Numero $_ 'TranX'), (Get-Numero $_ 'TranY'),
                (Get-Numero $_ 'Var1'), (Get-Numero $_ 'Var2'), (Get-Numero $_ 'Var3'), (Get-Numero $_ 'Var4')
        }) -join ",`n"
        [void]$sql.AppendLine("INSERT INTO vinyl (hash, hue1, hue2, hue3, hue4, layer, mir, rot, sat1, sat2, sat3, sat4, scalex, scaley, shear, tranx, trany, var1, var2, var3, var4, carId) VALUES`n$v;")
    }

    $visual = @($cc.SelectNodes('VisualParts/VisualPartTrans'))
    if ($visual.Count -gt 0) {
        $v = ($visual | ForEach-Object { '({0}, {1}, @car)' -f (Get-Numero $_ 'PartHash'), (Get-Numero $_ 'SlotHash') }) -join ",`n"
        [void]$sql.AppendLine("INSERT INTO visualpart (partHash, slotHash, carId) VALUES`n$v;")
    }

    [void]$sql.AppendLine('COMMIT;')
    [void]$sql.AppendLine('SELECT @car;')

    # Todo o nada: si cualquier INSERT falla, mysql.exe aborta y la conexion se
    # cierra sin COMMIT, asi que no queda un coche a medias en el garaje.
    Write-Paso "Insertando coche ($($paints.Count) pinturas, $($perf.Count) piezas, $($skill.Count) skill mods, $($vinilos.Count) vinilos, $($visual.Count) visuales)..."
    $salida = Invoke-Escritura -Sql $sql.ToString()
    if ($Simular) { Write-Aviso 'Simulado: no se ha tocado nada.'; Write-Host ''; return }
    $carId  = ($salida | Where-Object { $_ -match '^\d+$' } | Select-Object -Last 1)
    if (-not $carId) { throw 'El INSERT no devolvio el id del coche. Revisa logs y la tabla car.' }

    Write-Ok "$modelo en el garaje de $($piloto.Nombre) (coche id $carId, hueco #$numCoches)."
    if ($esAlquiler) { Write-Host "    Es un alquiler: caduca en $($producto.Minutos) minutos y el servidor lo borra solo." -ForegroundColor DarkGray }
    $conectado = Write-Conexion -PersonaId $piloto.Id
    if ($conectado -eq $false) {
        Write-Host '    Lo vera en el garaje al entrar.' -ForegroundColor DarkGray
    } else {
        Write-Host '    Si esta dentro: que pase por el garaje (safehouse). Si no le sale, que salga y entre.' -ForegroundColor DarkGray
    }
    if ($Anunciar) {
        Send-Aviso "REGALO: $($piloto.Nombre) se lleva un $modelo. Que pase por el garaje a estrenarlo."
    }
    Write-Registro -Fichero $LOG_REGALOS -Mensaje "regalo.ps1 - coche id $carId ($($producto.Etiqueta), $modelo) a $($piloto.Nombre) (persona $($piloto.Id))"
    Write-Host ''
    return
}


# =====================================================================
#  OBJETO (powerup, pieza, amplificador)
# =====================================================================
if ($PSCmdlet.ParameterSetName -eq 'Objeto') {
    $producto = Get-Producto -Etiqueta $Objeto -Tipos $TIPOS_OBJETO
    if (-not $producto) {
        Write-Titulo 'Objeto'
        Write-Fallo "No hay ningun objeto regalable con la etiqueta '$Objeto'. Busca con:  .\regalo.ps1 -Listar $Objeto"
        Write-Host ''
        exit 1
    }
    $titulo = if ($producto.Titulo) { $producto.Titulo } else { $producto.Etiqueta }

    # El inventario lo crea el servidor en la primera entrada del piloto, y en
    # ese momento mete los powerups de inicio (STARTING_INVENTORY_ITEMS). Si lo
    # creasemos aqui, el servidor ya no lo haria y el piloto entraria sin ellos.
    $inv = Get-Filas -Sql "SELECT id FROM inventory WHERE personaId = $($piloto.Id) ORDER BY id LIMIT 1;"
    if ($inv.Count -eq 0) {
        Write-Titulo 'Objeto'
        Write-Fallo "$($piloto.Nombre) todavia no tiene inventario: no ha entrado nunca al juego. Que entre una vez y repite."
        Write-Host ''
        exit 1
    }
    $invId = [long]$inv[0][0]
    $prodId   = Format-Texto $producto.ProductId

    # Cantidad por defecto: la del producto, igual que addInventoryItem() con
    # quantity = -1 (15 usos en los powerups, 1 en las piezas).
    $unidades = if ($Cantidad -gt 0) { $Cantidad } else { [math]::Max(1, $producto.UseCount) }
    $esPowerup = $producto.Tipo -eq 'POWERUP'

    # Columna de huecos usados que toca esta pieza (InventoryBO.updateInventorySlots).
    $columnaHuecos = switch ($producto.Tipo) {
        'PERFORMANCEPART' { 'performancePartsUsedSlotCount' }
        'SKILLMODPART'    { 'skillModPartsUsedSlotCount' }
        'VISUALPART'      { 'visualPartsUsedSlotCount' }
        default           { $null }
    }

    # ---------------------------------------------------------------
    #  QUITAR
    # ---------------------------------------------------------------
    if ($Quitar) {
        Write-Titulo "Quitar $titulo a $($piloto.Nombre)"
        $sql = New-Object System.Text.StringBuilder
        [void]$sql.AppendLine('START TRANSACTION;')
        if ($esPowerup) {
            # Los powerups son una sola fila apilada: se resta y, si llega a
            # cero, se borra (InventoryBO.decreaseItemCount hace lo mismo).
            [void]$sql.AppendLine("UPDATE inventory_item SET remainingUseCount = remainingUseCount - $unidades WHERE inventoryEntity_id = $invId AND productId = '$prodId';")
            [void]$sql.AppendLine("DELETE FROM inventory_item WHERE inventoryEntity_id = $invId AND productId = '$prodId' AND remainingUseCount <= 0;")
        } else {
            # Piezas y amplificadores: una fila por unidad. Se borran las mas
            # recientes y se devuelven los huecos.
            [void]$sql.AppendLine("SET @n := (SELECT COUNT(*) FROM inventory_item WHERE inventoryEntity_id = $invId AND productId = '$prodId');")
            [void]$sql.AppendLine("DELETE FROM inventory_item WHERE inventoryEntity_id = $invId AND productId = '$prodId' ORDER BY id DESC LIMIT $unidades;")
            if ($columnaHuecos) {
                [void]$sql.AppendLine("UPDATE inventory SET $columnaHuecos = GREATEST(0, $columnaHuecos - LEAST(@n, $unidades)) WHERE id = $invId;")
            }
        }
        [void]$sql.AppendLine('COMMIT;')
        Invoke-Escritura -Sql $sql.ToString() | Out-Null
        if ($Simular) { Write-Aviso 'Simulado: no se ha tocado nada.'; Write-Host ''; return }
        Write-Ok "Retiradas $unidades unidades de $titulo ($($producto.Etiqueta))."
        Write-Registro -Fichero $LOG_REGALOS -Mensaje "regalo.ps1 - QUITADO objeto $($producto.Etiqueta) x$unidades a $($piloto.Nombre) (persona $($piloto.Id))"
        Write-Host ''
        return
    }

    # ---------------------------------------------------------------
    #  REGALAR
    # ---------------------------------------------------------------
    Write-Titulo "$titulo para $($piloto.Nombre)"
    Write-Host "    Producto: $($producto.Etiqueta) ($($producto.ProductId), $($producto.Tipo)) x$unidades" -ForegroundColor DarkGray

    # Mismos valores que InventoryBO.addInventoryItem():
    #   resellPrice    = round(resalePrice * INVENTORY_ITEM_RESALE_MULTIPLIER)
    #   expirationDate = ahora + durationMinute, solo si el producto caduca
    #   status         = 'ACTIVE'
    # Los premios se dan con ignoreLimits = true, asi que aqui tampoco se
    # bloquea por capacidad; solo se avisa.
    $multi  = [double](Get-Parametro 'INVENTORY_ITEM_RESALE_MULTIPLIER' '1.0')
    $resell = [int][math]::Round($producto.Resale * $multi)
    $expira = if ($producto.Minutos -ne 0) { "DATE_ADD(NOW(), INTERVAL $($producto.Minutos) MINUTE)" } else { 'NULL' }

    $sql = New-Object System.Text.StringBuilder
    [void]$sql.AppendLine('START TRANSACTION;')
    if ($esPowerup) {
        # addStackedInventoryItem(): si ya tiene la pila, se suma; si no, fila nueva.
        [void]$sql.AppendLine(@"
INSERT INTO inventory_item (expirationDate, remainingUseCount, resellPrice, status, inventoryEntity_id, productId)
SELECT $expira, 0, $resell, 'ACTIVE', $invId, '$prodId' FROM DUAL
 WHERE NOT EXISTS (SELECT 1 FROM inventory_item WHERE inventoryEntity_id = $invId AND productId = '$prodId');
UPDATE inventory_item SET remainingUseCount = remainingUseCount + $unidades
 WHERE inventoryEntity_id = $invId AND productId = '$prodId';
"@)
    } else {
        # addInventoryItem(): una fila por unidad, con los usos del producto.
        for ($i = 0; $i -lt $unidades; $i++) {
            [void]$sql.AppendLine("INSERT INTO inventory_item (expirationDate, remainingUseCount, resellPrice, status, inventoryEntity_id, productId) VALUES ($expira, $([math]::Max(1, $producto.UseCount)), $resell, 'ACTIVE', $invId, '$prodId');")
        }
        if ($columnaHuecos) {
            [void]$sql.AppendLine("UPDATE inventory SET $columnaHuecos = $columnaHuecos + $unidades WHERE id = $invId;")
        }
    }
    [void]$sql.AppendLine('COMMIT;')
    Invoke-Escritura -Sql $sql.ToString() | Out-Null
    if ($Simular) { Write-Aviso 'Simulado: no se ha tocado nada.'; Write-Host ''; return }

    Write-Ok "$titulo x$unidades en el inventario de $($piloto.Nombre)."
    if ($columnaHuecos) {
        $h = Get-Filas -Sql "SELECT $columnaHuecos, $($columnaHuecos -replace 'UsedSlotCount', 'Capacity') FROM inventory WHERE id = $invId;"
        if ($h.Count -gt 0 -and [int]$h[0][0] -gt [int]$h[0][1]) {
            Write-Aviso "Inventario por encima de su capacidad ($($h[0][0])/$($h[0][1])). El juego lo muestra igual, pero no podra comprar mas de ese tipo hasta vender."
        }
    }
    if ($producto.Tipo -eq 'AMPLIFIER' -and $producto.Etiqueta -eq 'INSURANCE_AMPLIFIER') {
        Write-Host '    Ojo: el seguro que vende el juego repara ademas todos los coches al comprarlo; este regalo no repara nada.' -ForegroundColor DarkGray
    }
    $conectado = Write-Conexion -PersonaId $piloto.Id
    if ($conectado -ne $false) {
        Write-Host '    Si esta dentro, el inventario se le refresca al salir y entrar (o tras la siguiente compra).' -ForegroundColor DarkGray
    }
    if ($Anunciar) {
        Send-Aviso "REGALO: $($piloto.Nombre) se lleva $titulo x$unidades."
    }
    Write-Registro -Fichero $LOG_REGALOS -Mensaje "regalo.ps1 - objeto $($producto.Etiqueta) x$unidades a $($piloto.Nombre) (persona $($piloto.Id))"
    Write-Host ''
    return
}
