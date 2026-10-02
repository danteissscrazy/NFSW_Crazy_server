<#
.SYNOPSIS
    El panel de control del organizador durante la fiesta.

.DESCRIPTION
    Manda avisos a los 50 jugadores a la vez y cambia reglas del servidor sin
    reiniciar nada. Es lo que convierte una tarde de caos en un evento con
    ritmo: anuncias la manga, la gente va a la parrilla, y sigues.

    Los mensajes salen por el chat del juego, asi que los ve todo el que este
    conectado, este donde este.

.PARAMETER Mensaje
    Lo que se anuncia. Si no pones nada, abre el modo interactivo.

.PARAMETER HoraFeliz
    Multiplica por 10 el dinero y la reputacion durante el resto de la noche,
    y lo anuncia. Para la ultima media hora.

.PARAMETER Normal
    Devuelve las recompensas a su valor de fiesta (x10 -> x10). Deshace
    -HoraFeliz si te has pasado de generoso.

.PARAMETER Forajidos
    Modo "noche de forajidos": embestir policia y reventar controles pasa a
    pagar una barbaridad. La gente cambia de comportamiento al instante.

.PARAMETER Recargar
    Relee la tabla de parametros sin reiniciar el servidor. Util si has
    tocado algo a mano en la base de datos.

.EXAMPLE
    .\megafono.ps1 "Manga 3 en 2 minutos. A la parrilla."

.EXAMPLE
    .\megafono.ps1
    Modo interactivo: escribes y se manda, hasta que pones "salir".

.EXAMPLE
    .\megafono.ps1 -HoraFeliz

.NOTES
    OJO: los cambios de recompensas se aplican en caliente porque viven en la
    tabla `parameter`. Lo que NO se recarga solo son los eventos y los
    productos: eso sigue necesitando reiniciar el servidor.
#>

[CmdletBinding(DefaultParameterSetName = 'Aviso')]
param(
    [Parameter(ParameterSetName = 'Aviso', Position = 0)]
    [string] $Mensaje,

    [Parameter(ParameterSetName = 'HoraFeliz')] [switch] $HoraFeliz,
    [Parameter(ParameterSetName = 'Normal')]    [switch] $Normal,
    [Parameter(ParameterSetName = 'Forajidos')] [switch] $Forajidos,
    [Parameter(ParameterSetName = 'Recargar')]  [switch] $Recargar
)

. (Join-Path $PSScriptRoot '_comun.ps1')

# Estos dos tokens los pone party-setup.sql. Si los cambias alli, cambialos aqui.
$TOKEN_AVISOS = 'CrazyMega2026'
$TOKEN_ADMIN  = 'CrazyAdmin2026'

$BASE = "http://127.0.0.1:$PUERTO_CORE/Engine.svc"


function Send-Aviso {
    param([Parameter(Mandatory)][string] $Texto)
    try {
        $r = Invoke-RestMethod -Uri "$BASE/SendAnnouncement" -Method Post -TimeoutSec 20 `
                -Body @{ announcementAuth = $TOKEN_AVISOS; message = $Texto }
        if ("$r" -match 'SUCCESS') {
            Write-Host "  [enviado] " -ForegroundColor Green -NoNewline
            Write-Host $Texto
            return $true
        }
        Write-Fallo "El servidor lo rechazo: $r"
        return $false
    } catch {
        Write-Fallo "No pude contactar con el servidor: $($_.Exception.Message)"
        Write-Host '       Comprueba que esta arrancado con .\status.ps1' -ForegroundColor Red
        return $false
    }
}

function Invoke-Recarga {
    <# Relee la tabla parameter sin reiniciar el servidor. #>
    try {
        $r = Invoke-RestMethod -Uri "$BASE/ReloadParameters" -Method Post -TimeoutSec 20 `
                -Body @{ adminAuth = $TOKEN_ADMIN; message = 'recarga' }
        if ("$r" -match 'SUCCESS') { Write-Ok 'Parametros recargados (sin reiniciar).'; return $true }
        Write-Fallo "Recarga rechazada: $r"
        return $false
    } catch {
        Write-Fallo "No pude recargar: $($_.Exception.Message)"
        return $false
    }
}

function Set-Parametros {
    <# Escribe parametros en la base de datos y los aplica en caliente. #>
    param([Parameter(Mandatory)][hashtable] $Valores)

    $filas = ($Valores.GetEnumerator() | ForEach-Object {
        "('{0}','{1}')" -f $_.Key, ($_.Value -replace "'", "''")
    }) -join ",`n  "

    Invoke-Mysql -Sql @"
INSERT INTO parameter (name, value) VALUES
  $filas
ON DUPLICATE KEY UPDATE value = VALUES(value);
"@ | Out-Null

    return (Invoke-Recarga)
}


# =====================================================================
switch ($PSCmdlet.ParameterSetName) {

    'Recargar' {
        Write-Titulo 'Recargando parametros'
        Invoke-Recarga | Out-Null
        Write-Host ''
    }

    'HoraFeliz' {
        Write-Titulo 'HORA FELIZ'
        Write-Paso 'Subiendo recompensas x10...'
        if (Set-Parametros @{ CASH_REWARD_MULTIPLIER = '100.0'; REP_REWARD_MULTIPLIER = '100.0' }) {
            Send-Aviso 'HORA FELIZ: recompensas por las nubes durante el resto de la noche. A correr.' | Out-Null
            Write-Host ''
            Write-Ok 'Activada. Para volver atras:  .\megafono.ps1 -Normal'
        }
        Write-Host ''
    }

    'Normal' {
        Write-Titulo 'Recompensas a la normalidad'
        if (Set-Parametros @{ CASH_REWARD_MULTIPLIER = '10.0'; REP_REWARD_MULTIPLIER = '10.0' }) {
            Send-Aviso 'Se acabo la hora feliz. Recompensas normales.' | Out-Null
        }
        Write-Host ''
    }

    'Forajidos' {
        Write-Titulo 'NOCHE DE FORAJIDOS'
        Write-Paso 'Haciendo que meterse con la policia sea rentable...'
        # Estos parametros NO cambian la dificultad de la policia: multiplican
        # lo que PAGA cada cosa que haces durante una persecucion. Subirlos
        # mucho hace que la gente deje de correr y se dedique a provocar.
        $ok = Set-Parametros @{
            'PURSUIT_COP_CARS_RAMMED_CASH_MULTIPLIER'     = '8.0'
            'PURSUIT_COP_CARS_RAMMED_REP_MULTIPLIER'      = '8.0'
            'PURSUIT_ROADBLOCKS_DODGED_CASH_MULTIPLIER'   = '10.0'
            'PURSUIT_ROADBLOCKS_DODGED_REP_MULTIPLIER'    = '10.0'
            'PURSUIT_SPIKE_STRIPS_DODGED_CASH_MULTIPLIER' = '10.0'
            'PURSUIT_SPIKE_STRIPS_DODGED_REP_MULTIPLIER'  = '10.0'
            'PURSUIT_HEAT_LEVEL_CASH_MULTIPLIER'          = '5.0'
            'PURSUIT_HEAT_LEVEL_REP_MULTIPLIER'           = '5.0'
        }
        if ($ok) {
            Send-Aviso 'NOCHE DE FORAJIDOS: embestir a la policia y reventar controles paga como nunca.' | Out-Null
            Write-Host ''
            Write-Ok 'Activado.'
        }
        Write-Host ''
    }

    'Aviso' {
        if ($Mensaje) {
            Write-Host ''
            Send-Aviso $Mensaje | Out-Null
            Write-Host ''
            break
        }

        # --- Modo interactivo ---
        Write-Titulo 'Megafono - Crazy Server'
        Write-Host ''
        Write-Host '  Escribe y pulsa Enter para anunciarlo a todos.' -ForegroundColor DarkGray
        Write-Host '  Numero 1-6 para un aviso preparado. "salir" para terminar.' -ForegroundColor DarkGray
        Write-Host ''

        $preparados = @(
            'Manga siguiente en 2 minutos. A la parrilla.',
            'Ultima vuelta de inscripcion. El que no este, se queda fuera.',
            'Descanso de 10 minutos. Aprovechad para tunear el coche.',
            'Cambio de circuito. Mirad el chat para el nombre.',
            'Quedan 30 minutos de fiesta. A darlo todo.',
            'Se acabo. Gracias por venir, bestias.'
        )
        for ($i = 0; $i -lt $preparados.Count; $i++) {
            Write-Host ('   {0}) {1}' -f ($i + 1), $preparados[$i]) -ForegroundColor DarkGray
        }
        Write-Host ''

        while ($true) {
            $entrada = Read-Host '  megafono'
            if ([string]::IsNullOrWhiteSpace($entrada)) { continue }
            if ($entrada -in 'salir', 'exit', 'q') { break }

            if ($entrada -match '^[1-6]$') {
                Send-Aviso $preparados[[int]$entrada - 1] | Out-Null
            } else {
                Send-Aviso $entrada | Out-Null
            }
        }
        Write-Host ''
        Write-Host '  Megafono cerrado.' -ForegroundColor DarkGray
        Write-Host ''
    }
}
