<#
.SYNOPSIS
    Da de alta un coche NUEVO en el catalogo del servidor (coche "addon").

.DESCRIPTION
    Este script hace SOLO la mitad de servidor. Un coche addon tiene dos mitades
    y las dos son obligatorias:

      1. EN EL CLIENTE (la carpeta del juego de TODOS los jugadores):
           CARS\<NOMBRE>\GEOMETRY.BIN y TEXTURES.BIN   (modelo y texturas)
           CARS\GlobalC.lzc                            (con el hueco del coche)
           GLOBAL\attributes.bin                       (con el nodo pvehicle)
           scripts\NFSWorldUnlimiter.asi               (para que quepan mas coches)
         Eso se prepara con NFS-CarToolkit, Aaron y NFS-VltEd, y viaja dentro del
         ZIP del cliente. Si un jugador no lo tiene y otro conduce el coche, al
         primero le puede fallar el juego.

      2. EN EL SERVIDOR (esto):
           una fila en `product`           -> el coche existe y se puede comprar
           una fila en `basketdefinition`  -> que te dan exactamente al comprarlo

    Los tres numeros magicos salen de los nombres, no se inventan (verificado
    con el Corolla de serie y con el coche de pruebas TRAFPIZZA):

      BaseCar            = BinHash(NOMBRE EN MAYUSCULAS)   <- carpeta CARS\NOMBRE
      product.hash       = BinHash(ETIQUETA EN MAYUSCULAS) <- entitlementTag
      PhysicsProfileHash = VltHash(nodo pvehicle en minusculas)

    Los calcula lzc-tool.exe, que usa el mismo codigo que la herramienta Aaron.

.PARAMETER Nombre
    Nombre interno del coche = nombre de la carpeta dentro de CARS.
    Por ejemplo TRAFPIZZA. En mayusculas, sin espacios ni acentos.

.PARAMETER Nodo
    Nombre del nodo pvehicle que creaste en VltEd, en minusculas.
    Suele ser el mismo que -Nombre pero en minusculas.

.PARAMETER Titulo
    Como se ve en el juego. Por ejemplo "TOYOTA SUPRA MK4".

.PARAMETER Etiqueta
    Identificador para regalarlo con regalo.ps1. Por convencion, el nombre y
    _BIC al final: SUPRA_BIC.

.PARAMETER Precio
    Lo que cuesta en el concesionario. Por defecto 1.000.000.

.PARAMETER Nivel
    Nivel de piloto necesario para comprarlo. Por defecto 1.

.PARAMETER Plantilla
    Etiqueta de un coche YA existente del que copiar la ficha (pinturas, piezas,
    vinilos, clase y valoracion). Por defecto COROLLA_BIC. Elige uno parecido en
    prestaciones al que anades.

.PARAMETER Oculto
    Lo crea apagado: no sale en la tienda y solo se puede dar con regalo.ps1.
    Recomendado hasta que lo hayas probado dentro del juego.

.PARAMETER Aplicar
    Sin esto solo ESCRIBE el .sql y te lo ensena. Con esto, ademas lo ejecuta.

.EXAMPLE
    .\coche-nuevo.ps1 -Nombre TRAFPIZZA -Nodo trafpizza -Titulo "FURGONETA PIZZA" -Etiqueta TRAFPIZZA_BIC -Oculto
    Prepara el alta y la deja en un .sql para revisarla.

.EXAMPLE
    .\coche-nuevo.ps1 -Nombre SUPRAMK4 -Nodo supramk4 -Titulo "TOYOTA SUPRA MK4" -Etiqueta SUPRAMK4_BIC -Precio 2500000 -Plantilla RX7_BIC -Aplicar

.NOTES
    Para deshacerlo:
        .\coche-nuevo.ps1 -Nombre SUPRAMK4 -Quitar -Aplicar
#>

[CmdletBinding(DefaultParameterSetName = 'Alta')]
param(
    [Parameter(Mandatory, Position = 0)] [string] $Nombre,
    [Parameter(ParameterSetName = 'Alta', Mandatory)] [string] $Nodo,
    [Parameter(ParameterSetName = 'Alta', Mandatory)] [string] $Titulo,
    [Parameter(ParameterSetName = 'Alta', Mandatory)] [string] $Etiqueta,
    [Parameter(ParameterSetName = 'Alta')] [long]   $Precio    = 1000000,
    [Parameter(ParameterSetName = 'Alta')] [int]    $Nivel     = 1,
    [Parameter(ParameterSetName = 'Alta')] [string] $Plantilla = 'COROLLA_BIC',
    [Parameter(ParameterSetName = 'Alta')] [switch] $Oculto,
    [Parameter(ParameterSetName = 'Quitar', Mandatory)] [switch] $Quitar,
    [switch] $Aplicar
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_comun.ps1')

$LZC = Join-Path $PSScriptRoot '..\..\_build\herramientas-coches\lzc-tool\bin\Release\net9.0\lzc-tool.exe'
$SALIDA = Join-Path $PSScriptRoot '..\logs\coches'

function Get-Hashes {
    <# Devuelve BinHash y VltHash de una cadena, con la herramienta que usa el
       mismo codigo que Aaron. Reimplementarlo aqui seria pedir un fallo: el
       VltHash es un Jenkins con semilla 0xABCDEF00, no el Jenkins de manual. #>
    param([Parameter(Mandatory)][string] $Texto)
    if (-not (Test-Path -LiteralPath $LZC)) {
        throw "No encuentro lzc-tool.exe en $LZC. Compilalo con: dotnet build -c Release en _build\herramientas-coches\lzc-tool"
    }
    $linea = & $LZC hash $Texto | Select-Object -First 1
    $m = [regex]::Match($linea, 'BinHash\(UPPER\)=\s*(-?\d+)\s+PhysicsProfileHash=VltHash=\s*(-?\d+)')
    if (-not $m.Success) { throw "No entiendo la salida de lzc-tool: $linea" }
    return [pscustomobject]@{ Bin = [int]$m.Groups[1].Value; Vlt = [int]$m.Groups[2].Value }
}

function Escapar { param([string] $T) return $T.Replace('\', '\\').Replace("'", "''") }

# ---------------------------------------------------------------------
#  QUITAR
# ---------------------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'Quitar') {
    Write-Titulo "Quitando el coche $Nombre del catalogo"
    $h = Get-Hashes -Texto $Nombre
    $sql = @"
-- Quita el coche $Nombre del catalogo y de los garajes.
DELETE FROM car WHERE baseCar = $($h.Bin);
DELETE b FROM basketdefinition b JOIN product p ON p.productId = b.productId
 WHERE p.productType = 'PRESETCAR' AND p.longDescription = 'ADDON_$Nombre';
DELETE FROM product WHERE productType = 'PRESETCAR' AND longDescription = 'ADDON_$Nombre';
"@
    Write-Host $sql -ForegroundColor DarkGray
    if ($Aplicar) {
        Invoke-Mysql -Sql $sql -ComoRoot | Out-Null
        Write-Ok "Quitado. Los jugadores que lo tuvieran ya no lo veran."
    } else {
        Write-Aviso 'Simulacion. Anade -Aplicar para ejecutarlo de verdad.'
    }
    Write-Host ''
    return
}

# ---------------------------------------------------------------------
#  ALTA
# ---------------------------------------------------------------------
Write-Titulo "Alta del coche $Titulo"

$Nombre   = $Nombre.ToUpperInvariant()
$Etiqueta = $Etiqueta.ToUpperInvariant()
$Nodo     = $Nodo.ToLowerInvariant()

$hNombre   = Get-Hashes -Texto $Nombre
$hEtiqueta = Get-Hashes -Texto $Etiqueta
$hNodo     = Get-Hashes -Texto $Nodo

$baseCar = $hNombre.Bin      # carpeta CARS\<NOMBRE>
$hashProd = $hEtiqueta.Bin   # product.hash
$physics = $hNodo.Vlt        # nodo pvehicle

Write-Host "    Carpeta del cliente : CARS\$Nombre" -ForegroundColor DarkGray
Write-Host "    Nodo de VltEd       : pvehicle $Nodo" -ForegroundColor DarkGray
Write-Host "    BaseCar             : $baseCar" -ForegroundColor DarkGray
Write-Host "    PhysicsProfileHash  : $physics" -ForegroundColor DarkGray
Write-Host "    product.hash        : $hashProd" -ForegroundColor DarkGray
Write-Host ''

# Aviso si el cliente de este equipo no tiene la mitad que le toca.
$juegoCars = Join-Path $PSScriptRoot '..\..\Juego\CARS'
if (Test-Path -LiteralPath $juegoCars) {
    if (-not (Test-Path -LiteralPath (Join-Path $juegoCars $Nombre))) {
        Write-Aviso "En el cliente de este equipo NO existe CARS\$Nombre."
        Write-Host '       El coche saldra en la tienda pero no se podra ver ni conducir' -ForegroundColor Yellow
        Write-Host '       hasta que el modelo este en la carpeta del juego de todos.' -ForegroundColor Yellow
        Write-Host ''
    }
}

# Ficha de la que copiamos pinturas, piezas y vinilos.
$filas = Invoke-Mysql -Sql @"
SELECT p.productId, b.ownedCarTrans
  FROM product p JOIN basketdefinition b ON b.productId = p.productId
 WHERE p.entitlementTag = '$(Escapar $Plantilla)' AND p.productType = 'PRESETCAR';
"@
if (-not $filas -or $filas.Count -eq 0) { throw "No encuentro el coche plantilla '$Plantilla' en el catalogo." }
$partes = ($filas | Select-Object -First 1) -split "`t", 2
$xml = $partes[1]
if (-not $xml) { throw "El coche plantilla '$Plantilla' no tiene ficha de compra." }

# Se le cambia la identidad: el resto (pinturas, piezas, vinilos) se hereda.
$xml = [regex]::Replace($xml, '<BaseCar>-?\d+</BaseCar>', "<BaseCar>$baseCar</BaseCar>")
$xml = [regex]::Replace($xml, '<PhysicsProfileHash>-?\d+</PhysicsProfileHash>', "<PhysicsProfileHash>$physics</PhysicsProfileHash>")
$xml = [regex]::Replace($xml, '<Name>[^<]*</Name>', "<Name>$Nodo</Name>")
$xmlSql = Escapar $xml

# Si el coche ya estaba dado de alta, no hay nada que hacer. Sin esta comprobacion,
# volver a lanzar el script reservaba un numero nuevo, el INSERT del producto no
# entraba (la etiqueta es unica) y la fila del carrito se quedaba apuntando a un
# producto inexistente: 19 errores de clave ajena seguidos (2026-09-07).
$yaEsta = (Invoke-Mysql -Sql "SELECT productId FROM product WHERE entitlementTag = '$(Escapar $Etiqueta)';") -join ''
if ($yaEsta.Trim()) {
    Write-Ok "$Nombre ya estaba dado de alta como $($yaEsta.Trim()). No se toca nada."
    Write-Host "    Para cambiarlo, quitalo antes:  .\coche-nuevo.ps1 -Nombre $Nombre -Quitar -Aplicar" -ForegroundColor DarkGray
    return
}

# Un productId libre en el rango que ya usa el servidor.
$max = [int]((Invoke-Mysql -Sql "SELECT COALESCE(MAX(CAST(SUBSTRING(productId,8) AS UNSIGNED)),0) FROM product WHERE productId LIKE 'SRV-CAR%';") -join '' -replace '\D', '')
$productId = 'SRV-CAR{0}' -f ($max + 1)
$activo = if ($Oculto) { "b'0'" } else { "b'1'" }

$sql = @"
-- Coche addon: $Titulo  ($Nombre)
-- Ficha heredada de $Plantilla. La mitad del cliente (CARS\$Nombre, GlobalC.lzc,
-- attributes.bin) tiene que estar en el juego de TODOS los jugadores.
INSERT INTO product (accel, brand, categoryId, categoryName, currency, description, dropWeight, durationMinute,
    enabled, entitlementTag, handling, hash, icon, isDropable, level, longDescription, minLevel, premium, price,
    priority, productId, productTitle, productType, rarity, resalePrice, secondaryIcon, skillValue, subType,
    topSpeed, useCount, visualStyle, webIcon, webLocation, parentProductId, bundleItems, rewardTitle, isGift)
SELECT NULL, '', '', 'NFSW_NA_EP_PRESET_RIDES_ALL_Category', 'CASH', NULL, 0, 0,
    $activo, '$(Escapar $Etiqueta)', NULL, $hashProd, 'ArtDirector_64x64', b'0', $Nivel, 'ADDON_$Nombre', 0, b'0', $Precio,
    1, '$productId', '$(Escapar $Titulo)', 'PRESETCAR', 11, $([math]::Round($Precio / 2)), '', NULL, 'car_bestinclass',
    NULL, 1, '', '', '', NULL, '', NULL, 0
WHERE NOT EXISTS (SELECT 1 FROM product WHERE entitlementTag = '$(Escapar $Etiqueta)');

REPLACE INTO basketdefinition (productId, ownedCarTrans) VALUES ('$productId', '$xmlSql');
"@

if (-not (Test-Path -LiteralPath $SALIDA)) { New-Item -ItemType Directory -Path $SALIDA -Force | Out-Null }
$ruta = Join-Path $SALIDA "$Nombre.sql"
[System.IO.File]::WriteAllText($ruta, $sql, (New-Object System.Text.UTF8Encoding $false))
Write-Ok "SQL escrito en $ruta"

if ($Aplicar) {
    Invoke-Mysql -Sql $sql -ComoRoot | Out-Null
    $comp = Invoke-Mysql -Sql "SELECT productId, productTitle, enabled+0 FROM product WHERE entitlementTag = '$(Escapar $Etiqueta)';"
    Write-Ok "Dado de alta: $($comp -join '  ')"
    Write-Host ''
    Write-Host "    Para probarlo:  .\regalo.ps1 -Jugador TUPILOTO -Coche $Etiqueta" -ForegroundColor DarkGray
    if ($Oculto) { Write-Host '    Esta OCULTO en la tienda. Cuando funcione, quitale el -Oculto.' -ForegroundColor DarkGray }
} else {
    Write-Aviso 'No se ha tocado la base de datos. Anade -Aplicar para darlo de alta.'
}
Write-Host ''
Write-Registro "coche-nuevo.ps1 - $Nombre ($Etiqueta) baseCar=$baseCar physics=$physics aplicar=$Aplicar"
