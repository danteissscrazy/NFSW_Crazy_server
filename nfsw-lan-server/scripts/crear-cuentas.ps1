<#
.SYNOPSIS
    Genera cuentas de jugador para la LAN party y las tarjetas para repartir.

.DESCRIPTION
    Crea N cuentas listas para usar, para que nadie tenga que registrarse el
    dia del evento. Produce tres ficheros en la carpeta de salida:

      cuentas.sql   INSERTs para la base de datos (no pisa cuentas existentes)
      cuentas.csv   listado para el organizador
      tarjetas.html tarjetas imprimibles, una por jugador

    Como funciona la autenticacion de este servidor (verificado en su codigo):
    el launcher calcula el SHA-1 de la contrasena EN EL CLIENTE y envia el
    hash; el servidor solo compara cadenas. Por eso aqui se guarda el SHA-1
    en hexadecimal minusculas: es literalmente lo que el launcher va a mandar.

    OJO - esto no es seguridad, es comodidad de evento. SHA-1 sin sal y sobre
    HTTP plano en una LAN cerrada. Que nadie use una contrasena real suya.

.PARAMETER Cantidad
    Numero de cuentas a generar. Por defecto 50.

.PARAMETER Dominio
    Dominio de los correos generados. Por defecto crazy.party

    IMPORTANTE: tiene que acabar en un dominio de primer nivel REAL (.com,
    .es, .party, .gg...). El servidor valida el formato del correo contra una lista
    de dominios validos y RECHAZA inventados como ".sss" o ".lan".
    No hace falta que el correo exista: nadie va a mandar nada ahi.

.PARAMETER Prefijo
    Prefijo del usuario. Por defecto "piloto" -> piloto01@crazy.party

.PARAMETER Salida
    Carpeta donde dejar los ficheros. Por defecto ..\logs\cuentas

.PARAMETER Aplicar
    Ademas de generar los ficheros, aplica el SQL contra la base de datos.
    Requiere que MySQL este arrancado y mysql.exe accesible.

.EXAMPLE
    .\crear-cuentas.ps1
    Genera 50 cuentas y sus tarjetas, sin tocar la base de datos.

.EXAMPLE
    .\crear-cuentas.ps1 -Cantidad 20 -Prefijo corredor -Aplicar
    Genera 20 cuentas y las inserta directamente.

.NOTES
    NOMBRES DE PILOTO: el servidor solo acepta MAYUSCULAS Y NUMEROS, de 3 a
    15 caracteres. Nada de minusculas, espacios, acentos ni guiones. Va
    impreso en las tarjetas porque es la causa numero uno de atascos en el
    primer arranque.
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 500)]
    [int]    $Cantidad = 50,
    [string] $Dominio  = 'crazy.party',
    [string] $Prefijo  = 'piloto',
    [string] $Salida   = (Join-Path $PSScriptRoot '..\logs\cuentas'),
    [switch] $Aplicar
)

$ErrorActionPreference = 'Stop'

# --- Credenciales de la base de datos (mismas que credenciales.txt) --------
$DbUser = 'nfsw_user'
$DbPass = 'LanParty2026!'
$DbName = 'SOAPBOX'
$DbHost = '127.0.0.1'
$DbPort = 3306

# --- Utilidades ------------------------------------------------------------

function Get-Sha1Hex {
    param([Parameter(Mandatory)][string] $Texto)
    # El launcher hashea con SHA-1 y envia hex en minusculas. Replicamos eso.
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Texto))
        return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $sha.Dispose() }
}

function Get-ContrasenaLegible {
    param([Parameter(Mandatory)][int] $Indice)
    # Contrasenas que un humano puede teclear sin equivocarse y sin que el
    # de al lado se la adivine de un vistazo. Nada de caracteres ambiguos.
    $palabras = @(
        'turbo','nitro','derrape','asfalto','curva','motor','chasis','freno',
        'volante','pistón','escape','carrera','circuito','garaje','llanta','vuelta'
    )
    $palabra = $palabras[($Indice - 1) % $palabras.Count]
    $sufijo  = '{0:D3}' -f (($Indice * 37) % 1000)   # determinista: se puede regenerar
    return "$palabra-$sufijo"
}

function Escape-Sql {
    param([string] $Texto)
    return $Texto.Replace('\', '\\').Replace("'", "''")
}

# --- Generacion ------------------------------------------------------------

Write-Host ""
Write-Host "  Generando $Cantidad cuentas para la LAN party" -ForegroundColor Cyan
Write-Host "  ---------------------------------------------" -ForegroundColor Cyan

$cuentas = @(
    1..$Cantidad | ForEach-Object {
        $num   = '{0:D2}' -f $_
        $email = "$Prefijo$num@$Dominio"
        $pass  = Get-ContrasenaLegible -Indice $_
        [pscustomobject]@{
            Numero     = $_
            Email      = $email
            Contrasena = $pass
            Hash       = Get-Sha1Hex -Texto $pass
        }
    }
)

if (-not (Test-Path $Salida)) { New-Item -ItemType Directory -Path $Salida -Force | Out-Null }
$Salida = (Resolve-Path $Salida).Path

# --- 1. SQL ----------------------------------------------------------------

$sql = New-Object System.Text.StringBuilder
[void]$sql.AppendLine('-- Cuentas pre-creadas para la LAN party.')
[void]$sql.AppendLine('-- Generado por crear-cuentas.ps1 - regenerable, no editar a mano.')
[void]$sql.AppendLine('-- La contrasena se guarda como SHA-1 hex minusculas: es exactamente')
[void]$sql.AppendLine('-- lo que el launcher envia al hacer login.')
[void]$sql.AppendLine('')
[void]$sql.AppendLine("USE $DbName;")
[void]$sql.AppendLine('')

foreach ($c in $cuentas) {
    $e = Escape-Sql $c.Email
    # INSERT IGNORE: relanzar el script no duplica ni pisa cuentas ya creadas.
    # Los parentesis extra son obligatorios: sin ellos, PowerShell lee la coma
    # de "-f $e, $c.Hash" como separador de argumentos del metodo AppendLine.
    $linea = ("INSERT IGNORE INTO user (EMAIL, PASSWORD, premium, isAdmin, isLocked, created, lastLogin) " +
              "VALUES ('{0}', '{1}', b'1', b'0', b'0', NOW(), NOW());") -f $e, $c.Hash
    [void]$sql.AppendLine($linea)
}

[void]$sql.AppendLine('')
[void]$sql.AppendLine("SELECT COUNT(*) AS cuentas_en_el_servidor FROM user;")

$rutaSql = Join-Path $Salida 'cuentas.sql'
[System.IO.File]::WriteAllText($rutaSql, $sql.ToString(), (New-Object System.Text.UTF8Encoding $false))
Write-Host "  [ok] SQL          $rutaSql" -ForegroundColor Green

# --- 2. CSV para el organizador -------------------------------------------

$rutaCsv = Join-Path $Salida 'cuentas.csv'
$cuentas | Select-Object Numero, Email, Contrasena |
    Export-Csv -Path $rutaCsv -NoTypeInformation -Encoding UTF8
Write-Host "  [ok] CSV          $rutaCsv" -ForegroundColor Green

# --- 3. Tarjetas imprimibles ----------------------------------------------

$tarjetas = New-Object System.Text.StringBuilder
[void]$tarjetas.AppendLine(@'
<!doctype html>
<meta charset="utf-8">
<title>Tarjetas de acceso - NFS World LAN</title>
<style>
  @page { size: A4; margin: 12mm; }
  * { box-sizing: border-box; }
  body { font-family: "Segoe UI", system-ui, sans-serif; margin: 0; color: #111; }
  h1 { font-size: 15pt; margin: 0 0 3mm; }
  .aviso { font-size: 9pt; background: #fff4d6; border-left: 3px solid #d9a441;
           padding: 3mm 4mm; margin-bottom: 5mm; }
  .hoja { display: grid; grid-template-columns: 1fr 1fr; gap: 4mm; }
  .t { border: 1px dashed #999; border-radius: 2mm; padding: 4mm; page-break-inside: avoid; }
  .t .n { font-size: 8pt; color: #777; letter-spacing: .08em; text-transform: uppercase; }
  .t .campo { margin-top: 2.5mm; }
  .t .et { font-size: 8pt; color: #777; }
  .t .v { font-family: Consolas, monospace; font-size: 12pt; font-weight: 600; }
  .t .regla { margin-top: 3mm; font-size: 7.5pt; color: #444; border-top: 1px solid #eee;
              padding-top: 2mm; }
  @media print { .aviso { background: none; } }
</style>
<h1>Need for Speed World - LAN party</h1>
<div class="aviso">
  <b>Al entrar te pedira un nombre de piloto.</b> Solo admite MAYUSCULAS y NUMEROS,
  entre 3 y 15 caracteres. Nada de minusculas, espacios, acentos ni guiones.
  Ejemplos validos: <code>DANTE</code>, <code>RX7</code>, <code>SPEED99</code>.
</div>
<div class="hoja">
'@)

foreach ($c in $cuentas) {
    [void]$tarjetas.AppendLine(@"
  <div class="t">
    <div class="n">Jugador $('{0:D2}' -f $c.Numero)</div>
    <div class="campo"><div class="et">Correo</div><div class="v">$($c.Email)</div></div>
    <div class="campo"><div class="et">Contrasena</div><div class="v">$($c.Contrasena)</div></div>
    <div class="regla">Nombre de piloto: MAYUSCULAS y numeros, 3-15 caracteres.</div>
  </div>
"@)
}

[void]$tarjetas.AppendLine('</div>')

$rutaHtml = Join-Path $Salida 'tarjetas.html'
[System.IO.File]::WriteAllText($rutaHtml, $tarjetas.ToString(), (New-Object System.Text.UTF8Encoding $false))
Write-Host "  [ok] Tarjetas     $rutaHtml" -ForegroundColor Green

# --- 4. Aplicar (opcional) -------------------------------------------------

if ($Aplicar) {
    Write-Host ""
    Write-Host "  Aplicando contra la base de datos..." -ForegroundColor Yellow

    $mysql = Get-Command mysql.exe -ErrorAction SilentlyContinue
    if (-not $mysql) {
        $candidato = Join-Path $PSScriptRoot '..\runtime\mysql\bin\mysql.exe'
        if (Test-Path $candidato) { $mysql = $candidato }
        else {
            Write-Host "  [X] No encuentro mysql.exe. Arranca el servidor (start.ps1) o" -ForegroundColor Red
            Write-Host "      aplica a mano:  mysql -u $DbUser -p $DbName < `"$rutaSql`"" -ForegroundColor Red
            exit 1
        }
    }
    $exe = if ($mysql -is [string]) { $mysql } else { $mysql.Source }

    & $exe "--host=$DbHost" "--port=$DbPort" "--user=$DbUser" "--password=$DbPass" $DbName -e "source $rutaSql"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [X] MySQL devolvio error $LASTEXITCODE. Revisa que el servidor este arrancado." -ForegroundColor Red
        exit $LASTEXITCODE
    }
    Write-Host "  [ok] Cuentas insertadas." -ForegroundColor Green
}

# --- Resumen ---------------------------------------------------------------

Write-Host ""
Write-Host "  $Cantidad cuentas generadas. Ejemplo:" -ForegroundColor Cyan
$cuentas | Select-Object -First 3 | ForEach-Object {
    Write-Host ("    {0,-26} {1}" -f $_.Email, $_.Contrasena)
}
Write-Host "    ..."
Write-Host ""
if (-not $Aplicar) {
    Write-Host "  Para insertarlas en la base de datos, relanza con -Aplicar" -ForegroundColor DarkGray
    Write-Host "  (o ejecuta el SQL a mano cuando el servidor este arrancado)." -ForegroundColor DarkGray
}
Write-Host "  Imprime tarjetas.html y reparte." -ForegroundColor DarkGray
Write-Host ""
