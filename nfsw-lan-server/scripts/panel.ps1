<#
.SYNOPSIS
    Panel de control de Crazy Server. La puerta de entrada para el organizador.

.DESCRIPTION
    Una ventana con lo justo: si esta arrancado o no, los botones de arrancar
    y parar, las dos direcciones que hay que dictar a los jugadores, y accesos
    a las cosas de la fiesta.

    Pensado para que alguien que no ha visto esto en su vida pueda montar el
    servidor sin leer nada. Todo lo que hace por debajo son los mismos scripts
    que se pueden ejecutar a mano.

.NOTES
    Se abre con "Crazy Server.bat" en la raiz de la carpeta.
    Necesita ser administrador solo la primera vez (para el firewall).
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# El panel se abre sin consola detras, asi que un error aqui seria invisible.
# Con esto, al menos, sale una ventana diciendo que ha pasado.
trap {
    [System.Windows.Forms.MessageBox]::Show(
        "El panel no pudo arrancar.`n`n$_`n`nPrueba a ejecutar scripts\status.ps1 " +
        "desde PowerShell para ver el detalle.",
        'Crazy Server', 'OK', 'Error') | Out-Null
    exit 1
}

. (Join-Path $PSScriptRoot '_comun.ps1')

# --- Paleta: la misma que la web, para que todo parezca una sola cosa ---
$cFondo   = [System.Drawing.Color]::FromArgb(14, 17, 22)
$cPanel   = [System.Drawing.Color]::FromArgb(22, 27, 34)
$cLinea   = [System.Drawing.Color]::FromArgb(37, 44, 54)
$cTexto   = [System.Drawing.Color]::FromArgb(230, 237, 243)
$cSuave   = [System.Drawing.Color]::FromArgb(139, 152, 165)
$cAcento  = [System.Drawing.Color]::FromArgb(255, 107, 26)
$cVerde   = [System.Drawing.Color]::FromArgb(63, 185, 80)
$cRojo    = [System.Drawing.Color]::FromArgb(229, 83, 75)

function Nueva-Fuente { param([single]$t, [int]$e = 0)
    New-Object System.Drawing.Font('Segoe UI', $t, [System.Drawing.FontStyle]$e) }

$ventana = New-Object System.Windows.Forms.Form -Property @{
    Text            = 'Crazy Server'
    ClientSize      = New-Object System.Drawing.Size(560, 690)
    BackColor       = $cFondo
    ForeColor       = $cTexto
    Font            = (Nueva-Fuente 9.5)
    FormBorderStyle = 'FixedSingle'
    MaximizeBox     = $false
    StartPosition   = 'CenterScreen'
}

function Add-Etiqueta {
    param($padre, $texto, $x, $y, $ancho, $fuente, $color, [int]$alto = 22)
    $l = New-Object System.Windows.Forms.Label -Property @{
        Text = $texto; Location = New-Object System.Drawing.Point($x, $y)
        Size = New-Object System.Drawing.Size($ancho, $alto)
        Font = $fuente; ForeColor = $color; BackColor = [System.Drawing.Color]::Transparent
    }
    $padre.Controls.Add($l); return $l
}

function Add-Caja {
    param($padre, $x, $y, $ancho, $alto)
    $p = New-Object System.Windows.Forms.Panel -Property @{
        Location = New-Object System.Drawing.Point($x, $y)
        Size = New-Object System.Drawing.Size($ancho, $alto)
        BackColor = $cPanel
    }
    $padre.Controls.Add($p); return $p
}

function Add-Boton {
    param($padre, $texto, $x, $y, $ancho, $alto, $fondo, $frente, [single]$t = 9.5, [int]$estilo = 0)
    $b = New-Object System.Windows.Forms.Button -Property @{
        Text = $texto; Location = New-Object System.Drawing.Point($x, $y)
        Size = New-Object System.Drawing.Size($ancho, $alto)
        BackColor = $fondo; ForeColor = $frente
        Font = (Nueva-Fuente $t $estilo); FlatStyle = 'Flat'; Cursor = 'Hand'
    }
    $b.FlatAppearance.BorderColor = $cLinea
    $b.FlatAppearance.BorderSize = 1
    $padre.Controls.Add($b); return $b
}

# =====================================================================
#  CABECERA
# =====================================================================
Add-Etiqueta $ventana 'CRAZY SERVER' 26 22 300 (Nueva-Fuente 20 1) $cTexto 34 | Out-Null
Add-Etiqueta $ventana 'Need for Speed World  ·  servidor de LAN party' 28 56 380 (Nueva-Fuente 9.5) $cSuave | Out-Null

$luzGrande = New-Object System.Windows.Forms.Label -Property @{
    Text = ''; Location = New-Object System.Drawing.Point(386, 30)
    Size = New-Object System.Drawing.Size(144, 24); Font = (Nueva-Fuente 9.5 1)
    ForeColor = $cSuave; TextAlign = 'MiddleRight'; BackColor = [System.Drawing.Color]::Transparent
}
$ventana.Controls.Add($luzGrande)

# =====================================================================
#  ESTADO DE LOS SERVICIOS
# =====================================================================
$cajaEstado = Add-Caja $ventana 24 92 512 122
Add-Etiqueta $cajaEstado 'ESTADO' 18 12 200 (Nueva-Fuente 8.5 1) $cSuave 18 | Out-Null

$luces = @{}
$fila = 0
foreach ($s in $SERVICIOS) {
    $col = $fila % 2
    $x = 18 + ($col * 250)
    $y = 38 + ([math]::Floor($fila / 2) * 26)

    $punto = Add-Etiqueta $cajaEstado ([char]0x25CF) $x $y 16 (Nueva-Fuente 11) $cSuave 20
    Add-Etiqueta $cajaEstado $s.Etiqueta ($x + 20) ($y + 1) 210 (Nueva-Fuente 9.5) $cTexto 20 | Out-Null
    $luces[$s.Nombre] = $punto
    $fila++
}

# =====================================================================
#  BOTONES GRANDES
# =====================================================================
$btnArrancar = Add-Boton $ventana 'ARRANCAR' 24 232 250 52 $cAcento ([System.Drawing.Color]::White) 12 1
$btnParar    = Add-Boton $ventana 'PARAR'   286 232 250 52 $cPanel $cTexto 12 1

$lblProgreso = Add-Etiqueta $ventana '' 26 292 510 (Nueva-Fuente 9) $cSuave 20

# =====================================================================
#  LO QUE SE DICTA A LOS JUGADORES
# =====================================================================
$cajaUrls = Add-Caja $ventana 24 318 512 118
Add-Etiqueta $cajaUrls 'PARA LOS JUGADORES' 18 12 300 (Nueva-Fuente 8.5 1) $cSuave 18 | Out-Null

Add-Etiqueta $cajaUrls 'Servidor' 18 42 70 (Nueva-Fuente 9) $cSuave 20 | Out-Null
$lblServidor = Add-Etiqueta $cajaUrls '...' 96 42 320 (New-Object System.Drawing.Font('Consolas', 10)) $cAcento 20

Add-Etiqueta $cajaUrls 'Web' 18 70 70 (Nueva-Fuente 9) $cSuave 20 | Out-Null
$lblWeb = Add-Etiqueta $cajaUrls '...' 96 70 320 (New-Object System.Drawing.Font('Consolas', 10)) $cAcento 20

$btnCopiar = Add-Boton $cajaUrls 'Copiar' 416 44 78 44 $cFondo $cTexto 9

# =====================================================================
#  ATAJOS
# =====================================================================
Add-Etiqueta $ventana 'ABRIR' 26 452 200 (Nueva-Fuente 8.5 1) $cSuave 18 | Out-Null
$btnWeb     = Add-Boton $ventana 'Web'            24 474 122 36 $cPanel $cTexto
$btnRadio   = Add-Boton $ventana 'Radio'         154 474 122 36 $cPanel $cTexto
$btnMapa    = Add-Boton $ventana 'Mapa en vivo'  284 474 122 36 $cPanel $cTexto
$btnBuscados= Add-Boton $ventana 'Mas buscados'  414 474 122 36 $cPanel $cTexto

Add-Etiqueta $ventana 'HERRAMIENTAS' 26 522 200 (Nueva-Fuente 8.5 1) $cSuave 18 | Out-Null
$btnMega    = Add-Boton $ventana 'Megafono'       24 544 122 36 $cPanel $cTexto
$btnTesoro  = Add-Boton $ventana 'Tesoro'        154 544 122 36 $cPanel $cTexto
$btnCuentas = Add-Boton $ventana 'Cuentas'       284 544 122 36 $cPanel $cTexto
$btnPrep    = Add-Boton $ventana 'Preparar PC'   414 544 122 36 $cPanel $cTexto

Add-Etiqueta $ventana 'FIESTA' 26 590 200 (Nueva-Fuente 8.5 1) $cSuave 18 | Out-Null
$btnDecorado = Add-Boton $ventana 'Decorado'          24 612 122 36 $cPanel $cTexto
$btnRegalo   = Add-Boton $ventana 'Regalar'          154 612 122 36 $cPanel $cTexto
$btnEstrella = Add-Boton $ventana 'Carrera estrella' 284 612 122 36 $cPanel $cTexto
$btnMandos   = Add-Boton $ventana 'Controles'        414 612 122 36 $cPanel $cTexto

# (28-sep) Si ARRANCAR falla en un PC ajeno, esto es lo que se le pide al que
# esta delante: un clic y un fichero que mandar. Y los logs a un clic.
$btnDiag = Add-Boton $ventana 'Diagnostico'   24 652 122 30 $cPanel $cTexto
$btnLogs = Add-Boton $ventana 'Ver logs'     154 652 122 30 $cPanel $cTexto
Add-Etiqueta $ventana 'Si algo falla: Diagnostico y manda el fichero al organizador. Cierra esta ventana y el servidor sigue.' 284 650 262 (Nueva-Fuente 7.5) $cSuave 36 | Out-Null

# =====================================================================
#  LOGICA
# =====================================================================
$script:ipCache    = $null
$script:ticks      = 0
$script:trabajo    = $null        # proceso de start/stop/setup que este en curso
$script:fase       = 'ninguna'    # 'arrancando' | 'parando' | 'ninguna'
$script:faseHasta  = $null        # hasta cuando se da por buena la espera
$script:aviso      = $null        # mensaje puntual, se borra solo
$script:avisoColor = $null
$script:avisoHasta = $null

# El chat (Openfire) es OPCIONAL: start.ps1 sigue adelante sin el y el juego
# funciona igual, solo que sin chat ni invitaciones. Si el panel lo contara como
# imprescindible se quedaria en "5 de 6" naranja para siempre, y el organizador
# reiniciaria el servidor una y otra vez echando a los jugadores sin necesidad.
$script:OPCIONALES = @('openfire')

function Get-PuertosAbiertos {
    <#
    .SYNOPSIS
        Todos los puertos que estan escuchando, como "TCP:8080" / "UDP:9999".
    .DESCRIPTION
        POR QUE NO SE USA Test-PuertoEscuchando AQUI: esa funcion tira de
        Get-NetTCPConnection / Get-NetUDPEndpoint, que consultan WMI y tardan unos
        700 ms POR LLAMADA. Con seis servicios son ~4,7 segundos, mas de lo que
        tarda el temporizador en volver a dispararse: la ventana se quedaba
        permanentemente ocupada y no respondia a los clics.

        Esto es .NET puro y devuelve TODOS los puertos de una vez en ~8 ms.
        Para los demas scripts, que hacen una comprobacion y salen, la funcion
        lenta sigue valiendo perfectamente.
    #>
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    $p = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    foreach ($e in $p.GetActiveTcpListeners()) { [void]$set.Add("TCP:$($e.Port)") }
    foreach ($e in $p.GetActiveUdpListeners()) { [void]$set.Add("UDP:$($e.Port)") }
    return $set
}

function Set-Aviso {
    <#
    Mensaje puntual que se borra solo a los pocos segundos. Antes estos textos
    se quedaban fijos para siempre: el panel seguia diciendo "Arrancando..."
    horas despues, con todo en verde. Un cartel permanentemente falso es peor
    que no tener cartel.
    #>
    param([string]$Texto, $Color, [int]$Segundos = 8)
    $script:aviso      = $Texto
    $script:avisoColor = $Color
    $script:avisoHasta = (Get-Date).AddSeconds($Segundos)
    $lblProgreso.Text      = $Texto
    $lblProgreso.ForeColor = $Color
}

function Actualizar-Estado {
    # Todo va dentro de un try: un fallo puntual aqui (la red que se cae a
    # media consulta) haria saltar el 'trap' de arriba, que abre un dialogo
    # modal y deja el panel muerto. Mejor saltarse una pasada y seguir.
    try {
        $abiertos = Get-PuertosAbiertos
        $vivos = 0
        $faltanNecesarios = 0
        foreach ($s in $SERVICIOS) {
            $ok = $abiertos.Contains("$($s.Protocolo):$($s.Puerto)")
            $luces[$s.Nombre].ForeColor = if ($ok) { $cVerde } else { $cSuave }
            if ($ok) { $vivos++ }
            elseif ($script:OPCIONALES -notcontains $s.Nombre) { $faltanNecesarios++ }
        }

        # La IP se recalcula solo de vez en cuando: enumerar los adaptadores
        # cuesta bastante mas que mirar los puertos, y la IP casi nunca cambia
        # a media fiesta.
        if ($null -eq $script:ipCache -or ($script:ticks % 8) -eq 0) {
            $script:ipCache = Get-IpLan
        }
        $script:ticks++
        $ip = $script:ipCache

        if ($ip) {
            $lblServidor.Text      = "http://${ip}:$PUERTO_CORE/Engine.svc"
            $lblWeb.Text           = "http://${ip}:$PUERTO_WEB"
            $lblServidor.ForeColor = $cAcento
            $lblWeb.ForeColor      = $cAcento
        } else {
            # En rojo, no en el naranja de siempre: sin red no hay fiesta, y
            # tiene que cantar a la vista.
            $lblServidor.Text      = 'sin red'
            $lblWeb.Text           = 'sin red'
            $lblServidor.ForeColor = $cRojo
            $lblWeb.ForeColor      = $cRojo
        }

        # --- ¿hay un start/stop/setup en marcha? ---
        $ocupado = $false
        if ($script:trabajo) {
            if (-not $script:trabajo.HasExited) {
                $ocupado = $true
            } else {
                # Acaba de terminar. Se le da un margen para que los puertos
                # terminen de abrir antes de cantar fallo.
                $script:trabajo = $null
                if ($script:fase -eq 'arrancando') {
                    $script:faseHasta = (Get-Date).AddSeconds(45)
                } else {
                    $script:fase = 'ninguna'
                }
            }
        }
        # Mientras se arranca o se para, esos botones no se pueden tocar: dos
        # start.ps1 a la vez pelean por el mismo MySQL y por el mismo ZIP.
        $btnArrancar.Enabled = -not $ocupado
        $btnParar.Enabled    = -not $ocupado
        $btnPrep.Enabled     = -not $ocupado

        # --- estado general ---
        $total = $SERVICIOS.Count
        $ahora = Get-Date

        # (28-sep) Los puertos no bastan: el 8080 lo abre la consola interna del
        # servidor del juego aunque el despliegue haya muerto. start.ps1 deja la
        # verdad en logs\estado.json; stop.ps1 lo borra.
        $coreCaido = $false
        $fEstado = Join-Path $DIR_LOGS 'estado.json'
        if (Test-Path $fEstado) { try { $coreCaido = ((Get-Content $fEstado -Raw | ConvertFrom-Json).core -eq 'fallo') } catch { } }
        if ($coreCaido -and $luces.ContainsKey('core')) { try { $luces['core'].ForeColor = $cRojo } catch { } }

        if ($faltanNecesarios -eq 0 -and $vivos -eq $total -and -not $coreCaido) {
            $script:fase = 'ninguna'
            $luzGrande.Text = 'EN MARCHA'; $luzGrande.ForeColor = $cVerde
            $txt = 'Todo listo. Dicta las dos direcciones de arriba.'; $col = $cVerde
        }
        elseif ($coreCaido -and -not $ocupado) {
            $script:fase = 'ninguna'
            $luzGrande.Text = 'HA FALLADO'; $luzGrande.ForeColor = $cRojo
            $txt = 'El servidor del juego no desplego. Mira la ventana negra o pulsa Diagnostico; luego PARAR y ARRANCAR.'
            $col = $cRojo
        }
        elseif ($faltanNecesarios -eq 0) {
            # Solo falta algo opcional (el chat). El juego funciona.
            $script:fase = 'ninguna'
            $luzGrande.Text = 'EN MARCHA'; $luzGrande.ForeColor = $cVerde
            $txt = 'Listo, pero sin chat. Se puede jugar igual: no hace falta reiniciar.'
            $col = $cAcento
        }
        elseif ($ocupado -and $script:fase -eq 'parando') {
            $luzGrande.Text = 'PARANDO'; $luzGrande.ForeColor = $cAcento
            $txt = 'Parando el servidor...'; $col = $cSuave
        }
        elseif ($ocupado -or ($script:fase -eq 'arrancando' -and $ahora -lt $script:faseHasta)) {
            $luzGrande.Text = "ARRANCANDO $vivos/$total"; $luzGrande.ForeColor = $cAcento
            $txt = 'Arrancando... tarda uno o dos minutos. El detalle va en la ventana negra.'
            $col = $cAcento
        }
        elseif ($script:fase -eq 'arrancando') {
            # Termino start.ps1, paso el margen, y sigue sin levantar.
            $script:fase = 'ninguna'
            $luzGrande.Text = 'HA FALLADO'; $luzGrande.ForeColor = $cRojo
            $txt = 'El arranque no ha terminado bien. Mira la ventana negra: ahi pone por que. Luego pulsa Diagnostico.'
            $col = $cRojo
        }
        elseif ($vivos -eq 0) {
            $luzGrande.Text = 'PARADO'; $luzGrande.ForeColor = $cSuave
            $txt = 'Servidor parado. Pulsa ARRANCAR cuando quieras empezar.'; $col = $cSuave
        }
        else {
            $luzGrande.Text = "$vivos de $total"; $luzGrande.ForeColor = $cAcento
            $txt = 'Falta algo por levantar. Prueba a parar y arrancar otra vez.'; $col = $cAcento
        }

        # Un aviso puntual manda por encima del estado, pero solo unos segundos.
        if ($script:aviso -and $ahora -lt $script:avisoHasta) {
            $lblProgreso.Text = $script:aviso; $lblProgreso.ForeColor = $script:avisoColor
        } else {
            $script:aviso = $null
            $lblProgreso.Text = $txt; $lblProgreso.ForeColor = $col
        }
    }
    catch {
        $lblProgreso.Text = "No pude leer el estado: $($_.Exception.Message)"
        $lblProgreso.ForeColor = $cRojo
    }
}

function Ejecutar-Script {
    <#
    .SYNOPSIS
        Lanza uno de los scripts en su propia ventana y devuelve el proceso.
    .DESCRIPTION
        Se ve la salida en la consola: si algo falla, el mensaje esta a la vista
        en vez de escondido detras de una barra de progreso.

        OJO CON EL NOMBRE DEL PARAMETRO: no puede llamarse $Args. $Args es una
        variable automatica de PowerShell, asi que dentro de la funcion siempre
        vale vacio por mucho que se le pase algo, SIN dar ningun error. Por eso
        el boton del tesoro lanzaba tesoro.ps1 sin '-Lanzar' y en vez de repartir
        la caza solo imprimia "nadie tiene caza activa".

        Y se pasa como lista, no como cadena troceada por espacios: asi un
        argumento con espacios no se parte en dos.
    #>
    param([string]$Nombre, [string[]]$Argumentos = @(), [switch]$Admin)

    $ruta = Join-Path $PSScriptRoot $Nombre
    if (-not (Test-Path $ruta)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Falta el fichero $Nombre.`n`nDeberia estar en:`n$ruta",
            'Crazy Server', 'OK', 'Error') | Out-Null
        return $null
    }

    $lista = @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$ruta`"")
    if ($Argumentos) { $lista += $Argumentos }

    $opciones = @{ FilePath = 'powershell.exe'; ArgumentList = $lista; PassThru = $true }
    if ($Admin) { $opciones['Verb'] = 'RunAs' }
    try {
        return (Start-Process @opciones)
    } catch {
        # Aqui cae tambien cuando el usuario dice que NO al aviso de
        # administrador de Windows: sin este mensaje no se enteraria de nada.
        Set-Aviso "No se pudo lanzar $Nombre ($($_.Exception.Message))" $cRojo 10
        return $null
    }
}

function Abrir-Url {
    param([string]$Ruta)
    $ip = $script:ipCache
    if (-not $ip) { $ip = Get-IpLan; $script:ipCache = $ip }
    if (-not $ip) {
        # Sin esto el boton no hacia absolutamente nada y sin decir nada: no hay
        # consola detras donde se vea el error.
        Set-Aviso 'Sin red. Conecta el cable o el wifi y espera unos segundos.' $cRojo 10
        return
    }
    Start-Process "http://${ip}:$PUERTO_WEB$Ruta"
}

$btnArrancar.Add_Click({
    # Se bloquean YA, sin esperar al siguiente refresco: si no, da tiempo de
    # sobra a pulsar dos veces y salen dos start.ps1 peleandose por el mismo
    # MySQL y el mismo ZIP del launcher.
    $btnArrancar.Enabled = $false
    $btnParar.Enabled    = $false
    $btnPrep.Enabled     = $false
    $script:fase      = 'arrancando'
    $script:faseHasta = (Get-Date).AddSeconds(300)
    $script:aviso     = $null
    $script:trabajo   = Ejecutar-Script 'start.ps1'
    if (-not $script:trabajo) { $script:fase = 'ninguna' }
    Actualizar-Estado
})

$btnParar.Add_Click({
    $btnArrancar.Enabled = $false
    $btnParar.Enabled    = $false
    $btnPrep.Enabled     = $false
    $script:fase    = 'parando'
    $script:aviso   = $null
    $script:trabajo = Ejecutar-Script 'stop.ps1'
    if (-not $script:trabajo) { $script:fase = 'ninguna' }
    Actualizar-Estado
})

$btnCopiar.Add_Click({
    if (-not $script:ipCache) {
        Set-Aviso 'Sin red todavia: no hay direcciones que copiar.' $cRojo 10
        return
    }
    $texto = "Servidor del juego:  $($lblServidor.Text)`r`n" +
             "Registro y descargas: $($lblWeb.Text)"
    try {
        Set-Clipboard -Value $texto
        Set-Aviso 'Direcciones copiadas. Pegalas donde las vean todos.' $cVerde
    } catch {
        Set-Aviso 'No pude copiar al portapapeles.' $cRojo
    }
})

$btnWeb.Add_Click({      Abrir-Url '/' })
$btnRadio.Add_Click({    Abrir-Url '/radio' })
$btnMapa.Add_Click({     Abrir-Url '/mapa' })
$btnBuscados.Add_Click({ Abrir-Url '/masbuscados' })

$btnMega.Add_Click({   [void](Ejecutar-Script 'megafono.ps1') })
$btnTesoro.Add_Click({ [void](Ejecutar-Script 'tesoro.ps1' @('-Lanzar')) })

# Fiesta: cada uno abre su consola con el menu o la ayuda del script. Regalar y
# Carrera estrella necesitan datos (a quien, que): la consola los pide o los explica.
$btnDecorado.Add_Click({ [void](Ejecutar-Script 'decorado.ps1') })
$btnRegalo.Add_Click({   [void](Ejecutar-Script 'regalo.ps1') })
$btnEstrella.Add_Click({ [void](Ejecutar-Script 'carrera-estrella.ps1' @('-Estado')) })
$btnMandos.Add_Click({   [void](Ejecutar-Script 'controles.ps1' @('-Estado')) })
$btnDiag.Add_Click({     [void](Ejecutar-Script 'diagnostico.ps1') })
$btnLogs.Add_Click({     if (Test-Path $DIR_LOGS) { Start-Process explorer.exe $DIR_LOGS } else { Set-Aviso 'Aun no hay carpeta logs: no se ha arrancado nunca.' $cAcento 6 } })

$btnCuentas.Add_Click({
    # Dos usos: VER quien esta registrado y conectado (web /pilotos) o CREAR las
    # 50 cuentas de fiesta. Con -Aplicar: sin el, crear-cuentas.ps1 genera las
    # tarjetas pero NO crea las cuentas en la base de datos y fallaria el login
    # de todo el mundo a la vez.
    $r = [System.Windows.Forms.MessageBox]::Show(
        "SI  = ver los pilotos registrados y quien esta dentro del juego ahora (web).`r`n`r`n" +
        "NO = crear las 50 cuentas de fiesta con sus tarjetas para repartir.",
        'Cuentas', 'YesNoCancel', 'Question')
    if ($r -eq 'Yes') { Abrir-Url '/pilotos' }
    elseif ($r -eq 'No') { [void](Ejecutar-Script 'crear-cuentas.ps1' @('-Aplicar')) }
})

$btnPrep.Add_Click({
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Prepara este equipo para servir la fiesta: abre los puertos en el " +
        "firewall y deja la base de datos lista.`n`n" +
        "Solo hace falta la primera vez en cada maquina.`n`n" +
        "Windows va a pedir permisos de administrador.",
        'Preparar equipo', 'OKCancel', 'Information')
    if ($r -eq 'OK') {
        $btnArrancar.Enabled = $false
        $btnParar.Enabled    = $false
        $btnPrep.Enabled     = $false
        $script:fase    = 'ninguna'
        $script:trabajo = Ejecutar-Script 'setup.ps1' -Admin
        Actualizar-Estado
    }
})

# Refresco continuo: el panel refleja la realidad aunque el servidor se
# arranque o se pare desde fuera.
$reloj = New-Object System.Windows.Forms.Timer
$reloj.Interval = 2500
$reloj.Add_Tick({ Actualizar-Estado })
$reloj.Start()

Actualizar-Estado
[void]$ventana.ShowDialog()
$reloj.Stop()
