#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
Web de registro y descargas para la LAN party de NFS World.

Hace dos cosas:

  /            Alta de jugadores. El registro NO se inventa nada: llama al
               endpoint real del servidor del juego (createUser), calculando
               antes el SHA-1 de la contrasena igual que hace el launcher.
               Asi el formato es, por definicion, el que el servidor espera,
               y los duplicados los rechaza el propio servidor.

  /descargas   Lista lo que haya en gamefiles\ y lo sirve por HTTP, con la
               opcion de bajarlo todo en un zip.

Se arranca sola con start.ps1. A mano:  python app.py
"""

import hashlib
import io
import os
import re
import socket
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

from flask import (Flask, Response, redirect, render_template_string, request,
                   send_from_directory, url_for)

# ---------------------------------------------------------------------
#  Configuracion
# ---------------------------------------------------------------------

RAIZ = Path(__file__).resolve().parent.parent
DIR_GAMEFILES = RAIZ / "gamefiles"
DIR_LAUNCHER = RAIZ / "launcher"

PUERTO_WEB = 5000
PUERTO_CORE = 8080
CORE = f"http://127.0.0.1:{PUERTO_CORE}/Engine.svc"

# El launcher exige entre 3 y 15 caracteres, solo mayusculas y numeros.
# Se valida aqui tambien para avisar antes y no despues.
RE_EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

app = Flask(__name__)


# ---------------------------------------------------------------------
#  Utilidades
# ---------------------------------------------------------------------

def ip_lan() -> str:
    """IP de esta maquina en la LAN (la que ven los jugadores)."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def sha1_hex(texto: str) -> str:
    """SHA-1 en hexadecimal minusculas: exactamente lo que envia el launcher."""
    return hashlib.sha1(texto.encode("utf-8")).hexdigest()


def tamano_legible(n: int) -> str:
    for unidad in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unidad == "TB":
            return f"{n:.0f} {unidad}" if unidad == "B" else f"{n:.1f} {unidad}"
        n /= 1024.0
    return f"{n:.1f} TB"


def listar_gamefiles():
    """Devuelve (lista_de_ficheros, bytes_totales). Cada item: nombre, ruta relativa, tamano."""
    if not DIR_GAMEFILES.is_dir():
        return [], 0
    items, total = [], 0
    # version.txt no es una descarga: se enseña aparte, en el panel "Version".
    for p in sorted(DIR_GAMEFILES.rglob("*")):
        if p.is_file() and p.name not in (".gitkeep", "version.txt"):
            rel = p.relative_to(DIR_GAMEFILES)
            tam = p.stat().st_size
            items.append({"nombre": p.name,
                          "rel": str(rel).replace("\\", "/"),
                          "tamano": tamano_legible(tam)})
            total += tam
    return items, total


def version_gamefiles():
    f = DIR_GAMEFILES / "version.txt"
    if f.is_file():
        try:
            return f.read_text(encoding="utf-8", errors="replace").strip()
        except OSError:
            return None
    return None


def registrar_en_servidor(email: str, password: str):
    """
    Da de alta al jugador llamando al servidor del juego.

    Devuelve (ok, mensaje). No inventamos el formato de la cuenta: se lo
    pedimos al propio servidor, que es quien manda.
    """
    url = (f"{CORE}/User/createUser?"
           + urllib.parse.urlencode({"email": email, "password": sha1_hex(password)}))
    try:
        with urllib.request.urlopen(url, timeout=15) as r:
            cuerpo = r.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        cuerpo = e.read().decode("utf-8", errors="replace")
    except urllib.error.URLError:
        return False, ("No hay contacto con el servidor del juego. "
                       "Avisa al organizador: puede que aun no este arrancado.")
    except Exception as e:                                   # noqa: BLE001
        return False, f"Error inesperado hablando con el servidor: {e}"

    # El servidor responde XML. Un login correcto trae un token de sesion;
    # un fallo trae una descripcion del error.
    try:
        raiz = ET.fromstring(cuerpo)
    except ET.ParseError:
        # Ante una respuesta que no sabemos leer, damos error. Decir "cuenta
        # creada" sin estar seguros es el peor resultado posible: el jugador
        # se marcha convencido y falla al entrar, cuando ya nadie mira la web.
        return False, "El servidor respondio algo que no entiendo. Avisa al organizador."

    # OJO: el servidor devuelve SIEMPRE la misma estructura, tambien al fallar
    # (con UserId=0, LoginToken vacio y el motivo en Description). Comprobar
    # solo que "existe el campo UserId" da por bueno cualquier error - y eso
    # es peor que fallar, porque el jugador se va convencido de tener cuenta.
    # El exito real es: UserId distinto de 0 Y un token no vacio.
    def _texto(etiqueta):
        n = raiz.find(f".//{etiqueta}")
        return (n.text or "").strip() if n is not None else ""

    user_id = _texto("UserId")
    token   = _texto("LoginToken")
    motivo  = _texto("Description")

    if user_id and user_id != "0" and token:
        return True, "Cuenta creada."

    bajo = motivo.lower()
    if "email format" in bajo or "invalid email" in bajo:
        return False, ("Ese correo no lo acepta el servidor. Tiene que acabar en un dominio "
                       "real. Prueba con algo como tunombre@crazy.party")
    # "Registration limit reached for email" es como el servidor dice, con poca
    # gracia, que ese correo ya tiene cuenta. Se traduce a algo accionable.
    if ("exist" in bajo or "duplicate" in bajo or "already" in bajo
            or "taken" in bajo or "limit reached" in bajo):
        return False, ("Ese correo ya tiene cuenta. Entra en el juego con el que ya tienes, "
                       "o registra otro distinto.")
    if "ticket" in bajo:
        return False, ("El servidor esta pidiendo invitacion. "
                       "Avisa al organizador para que abra el registro.")
    if motivo:
        return False, f"El servidor rechazo el registro: {motivo[:200]}"
    return False, "El servidor rechazo el registro sin dar motivo."


def servidor_vivo() -> bool:
    try:
        with urllib.request.urlopen(f"{CORE}/GetServerInformation", timeout=3) as r:
            return r.status == 200
    except Exception:                                        # noqa: BLE001
        return False


# ---------------------------------------------------------------------
#  Plantilla
# ---------------------------------------------------------------------

BASE = """<!doctype html>
<html lang="es">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{ titulo }} · Crazy Server</title>
<style>
  :root {
    --fondo:#0e1116; --panel:#161b22; --linea:#252c36;
    --texto:#e6edf3; --suave:#8b98a5;
    --acento:#ff6b1a; --ok:#2ea043; --mal:#e5534b;
  }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--fondo); color:var(--texto);
         font-family:"Segoe UI",system-ui,sans-serif; line-height:1.6; }
  .barra { border-bottom:1px solid var(--linea); background:var(--panel); }
  .barra .interior { max-width:820px; margin:0 auto; padding:14px 20px;
         display:flex; align-items:center; gap:22px; flex-wrap:wrap; }
  .marca { font-weight:700; letter-spacing:.02em; }
  .marca span { color:var(--acento); }
  .barra a { color:var(--suave); text-decoration:none; font-size:15px; }
  .barra a:hover, .barra a.activo { color:var(--texto); }
  main { max-width:820px; margin:0 auto; padding:32px 20px 64px; }
  h1 { font-size:26px; margin:0 0 6px; }
  .sub { color:var(--suave); margin:0 0 28px; }
  .panel { background:var(--panel); border:1px solid var(--linea);
           border-radius:10px; padding:22px 24px; margin-bottom:20px; }
  label { display:block; font-size:14px; color:var(--suave); margin-bottom:6px; }
  input[type=text], input[type=email], input[type=password] {
      width:100%; padding:11px 13px; margin-bottom:18px; font-size:15px;
      background:#0d1117; color:var(--texto);
      border:1px solid var(--linea); border-radius:7px; }
  input:focus { outline:2px solid var(--acento); outline-offset:1px; border-color:transparent; }
  button { background:var(--acento); color:#fff; border:0; border-radius:7px;
           padding:12px 26px; font-size:15px; font-weight:600; cursor:pointer; }
  button:hover { filter:brightness(1.12); }
  .aviso { border-radius:7px; padding:13px 16px; margin-bottom:22px; font-size:15px; }
  .aviso.ok  { background:rgba(46,160,67,.14);  border:1px solid var(--ok);  }
  .aviso.mal { background:rgba(229,83,75,.14);  border:1px solid var(--mal); }
  .aviso.nota{ background:rgba(255,107,26,.10); border:1px solid var(--acento); }
  table { width:100%; border-collapse:collapse; font-size:15px; }
  th { text-align:left; font-size:12px; text-transform:uppercase; letter-spacing:.08em;
       color:var(--suave); border-bottom:1px solid var(--linea); padding:8px 10px; }
  td { padding:9px 10px; border-bottom:1px solid var(--linea); }
  td.num { text-align:right; color:var(--suave); font-variant-numeric:tabular-nums; }
  tr:last-child td { border-bottom:0; }
  a.fichero { color:var(--acento); text-decoration:none; }
  a.fichero:hover { text-decoration:underline; }
  code { background:#0d1117; padding:2px 7px; border-radius:4px;
         font-family:Consolas,monospace; font-size:14px; color:var(--acento); }
  .pie { color:var(--suave); font-size:13px; margin-top:34px;
         border-top:1px solid var(--linea); padding-top:16px; }
  ol { padding-left:20px; } li { margin:7px 0; }
</style>
<div class="barra"><div class="interior">
  <div class="marca">Crazy <span>Server</span></div>
  <a href="/" class="{{ 'activo' if seccion=='alta' else '' }}">Crear cuenta</a>
  <a href="/descargas" class="{{ 'activo' if seccion=='descargas' else '' }}">Descargas</a>
  <a href="/radio" class="{{ 'activo' if seccion=='radio' else '' }}">Radio</a>
  <a href="/masbuscados" class="{{ 'activo' if seccion=='buscados' else '' }}">Los mas buscados</a>
  <a href="/pilotos" class="{{ 'activo' if seccion=='pilotos' else '' }}">Pilotos</a>
  <a href="/mapa">Mapa en vivo</a>
</div></div>
<main>{{ contenido|safe }}
  <div class="pie">Servidor del juego: <code>http://{{ ip }}:8080/Engine.svc</code></div>
</main>
</html>"""


def pagina(titulo, seccion, contenido):
    return render_template_string(BASE, titulo=titulo, seccion=seccion,
                                  contenido=contenido, ip=ip_lan())


# ---------------------------------------------------------------------
#  Rutas
# ---------------------------------------------------------------------

@app.route("/", methods=["GET", "POST"])
def alta():
    aviso = ""

    if request.method == "POST":
        email = (request.form.get("email") or "").strip()
        clave = request.form.get("password") or ""
        clave2 = request.form.get("password2") or ""

        if not RE_EMAIL.match(email):
            aviso = '<div class="aviso mal">Ese correo no tiene buena pinta. Revisalo.</div>'
        elif len(clave) < 4:
            aviso = '<div class="aviso mal">La contrasena debe tener al menos 4 caracteres.</div>'
        elif clave != clave2:
            aviso = '<div class="aviso mal">Las dos contrasenas no coinciden.</div>'
        else:
            ok, mensaje = registrar_en_servidor(email, clave)
            if ok:
                aviso = (f'<div class="aviso ok"><b>Listo, {email} ya puede jugar.</b><br>'
                         'Abre el launcher, entra con ese correo y tu contrasena, '
                         'y elige tu nombre de piloto.</div>')
            else:
                aviso = f'<div class="aviso mal">{mensaje}</div>'

    if not servidor_vivo():
        aviso = ('<div class="aviso mal">El servidor del juego no responde ahora mismo. '
                 'Puedes mirar las descargas, pero el registro no funcionara hasta '
                 'que el organizador lo arranque.</div>') + aviso

    contenido = f"""
      <h1>Crea tu cuenta</h1>
      <p class="sub">Un minuto y estas dentro. No hace falta correo de verdad.</p>
      {aviso}
      <div class="panel">
        <form method="post">
          <label for="email">Correo</label>
          <input id="email" name="email" type="email" required
                 placeholder="tunombre@crazy.party" autocomplete="off">

          <label for="password">Contrasena</label>
          <input id="password" name="password" type="password" required
                 autocomplete="new-password">

          <label for="password2">Repite la contrasena</label>
          <input id="password2" name="password2" type="password" required
                 autocomplete="new-password">

          <button type="submit">Crear cuenta</button>
        </form>
      </div>

      <div class="aviso nota">
        <b>Dos cosas que conviene saber antes de entrar:</b>
        <ol>
          <li>Tu <b>nombre de piloto</b> (el que se elige dentro del juego) solo admite
              MAYUSCULAS y numeros, de 3 a 15 caracteres. Nada de minusculas, espacios
              ni acentos. Por ejemplo: <code>DANTE</code>, <code>RX7</code>.</li>
          <li>El correo tiene que acabar en un dominio real (<code>.com</code>,
              <code>.es</code>, <code>.party</code>...). No hace falta que exista de verdad:
              <code>tunombre@crazy.party</code> vale perfectamente.</li>
          <li>La contrasena viaja sin cifrar por la red local: <b>no uses una que
              uses de verdad</b> en otro sitio.</li>
        </ol>
      </div>

      <div class="panel">
        <b>Como conectar el launcher</b>
        <ol>
          <li>Si no tienes el juego, bajalo desde <a href="/descargas" class="fichero">Descargas</a>.</li>
          <li>Abre el launcher. Si avisa de que no hay internet, pulsa <b>No</b> para continuar.</li>
          <li>Pulsa <b>+</b> para anadir servidor y pega esta direccion:<br>
              <code>http://{ip_lan()}:8080/Engine.svc</code></li>
          <li>Entra con el correo y la contrasena que acabas de crear.</li>
        </ol>
      </div>
    """
    return pagina("Crear cuenta", "alta", contenido)


@app.route("/descargas")
def descargas():
    ficheros, total = listar_gamefiles()
    version = version_gamefiles()

    if not ficheros:
        cuerpo = """
          <div class="aviso nota">
            <b>No hay archivos del juego disponibles todavia.</b><br>
            El organizador aun no los ha puesto. Vuelve a mirar en un rato.
          </div>"""
    else:
        filas = "".join(
            f'<tr><td><a class="fichero" href="/descargar/{urllib.parse.quote(f["rel"])}">'
            f'{f["nombre"]}</a></td><td class="num">{f["tamano"]}</td></tr>'
            for f in ficheros)
        cuerpo = f"""
          <div class="panel">
            <p style="margin-top:0">
              <b>{len(ficheros)} archivos</b> &middot; {tamano_legible(total)} en total
            </p>
            <table>
              <tr><th>Archivo</th><th style="text-align:right">Tamano</th></tr>
              {filas}
            </table>
          </div>"""

    if version:
        cuerpo += f'<div class="panel"><b>Version</b><br><code>{version}</code></div>'

    if (DIR_LAUNCHER / "Servers-Custom.json").exists():
        cuerpo += """
          <div class="aviso nota">
            <b>Atajo:</b> en la carpeta del launcher hay un <code>Servers-Custom.json</code>
            ya configurado con la direccion de este servidor. Copialo junto al launcher
            y te aparecera solo, sin tener que anadirlo a mano.
          </div>"""

    return pagina("Descargas", "descargas", f"""
      <h1>Archivos del juego</h1>
      <p class="sub">Copialos a una carpeta que NO sea el Escritorio, Documentos,
         Descargas ni Archivos de programa: el launcher los rechaza ahi.</p>
      {cuerpo}""")


MAPA = """<!doctype html>
<html lang="es">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Mapa en vivo · Crazy Server</title>
<style>
  html,body { margin:0; height:100%; background:#07090c; color:#e6edf3;
              font-family:"Segoe UI",system-ui,sans-serif; overflow:hidden; }
  #lienzo { display:block; width:100vw; height:100vh; cursor:grab; }
  #lienzo.arrastrando { cursor:grabbing; }
  .panel { position:fixed; top:16px; left:16px; background:rgba(14,17,22,.86);
           border:1px solid #262e38; border-radius:10px; padding:14px 18px;
           backdrop-filter:blur(6px); min-width:210px; }
  .panel h1 { margin:0 0 2px; font-size:17px; letter-spacing:.02em; }
  .panel h1 span { color:#ff6b1a; }
  .cifra { font-size:38px; font-weight:700; line-height:1; margin:8px 0 2px;
           font-variant-numeric:tabular-nums; }
  .et { font-size:12px; color:#8b98a5; text-transform:uppercase; letter-spacing:.1em; }
  .estado { margin-top:10px; font-size:13px; display:flex; align-items:center; gap:7px; }
  .punto { width:8px; height:8px; border-radius:50%; background:#3fb950; flex:none; }
  .punto.mal { background:#e5534b; }
  .ayuda { position:fixed; bottom:16px; left:16px; font-size:12.5px; color:#8b98a5;
           background:rgba(14,17,22,.86); border:1px solid #262e38;
           border-radius:8px; padding:9px 14px; line-height:1.7; }
  kbd { background:#1c232c; border:1px solid #333c47; border-radius:4px;
        padding:1px 6px; font-family:Consolas,monospace; font-size:11.5px; }
  .lista { position:fixed; top:16px; right:16px; background:rgba(14,17,22,.86);
           border:1px solid #262e38; border-radius:10px; padding:12px 16px;
           max-height:80vh; overflow-y:auto; font-size:13.5px; min-width:150px; }
  .lista div { padding:2px 0; color:#c9d4de; }
  .nota { margin-top:10px; font-size:12px; color:#8b98a5; line-height:1.5; max-width:230px; }
  .salir { display:inline-block; margin-top:12px; padding:7px 14px; border-radius:7px;
           background:#ff6b1a; color:#0b0d10; font-weight:600; font-size:13px;
           text-decoration:none; }
  .salir:hover { background:#ff8442; }
</style>

<canvas id="lienzo"></canvas>

<div class="panel">
  <h1>Crazy <span>Server</span></h1>
  <div class="et">Conduciendo ahora</div>
  <div class="cifra" id="cuantos">0</div>
  <div class="estado"><span class="punto" id="luz"></span><span id="conexion">conectando…</span></div>
  <div class="nota">Solo salen los que están conduciendo por la ciudad: en el garaje o en los menús no se ven.</div>
  <a class="salir" href="/">&larr; Salir del mapa</a>
</div>

<div class="lista" id="lista"></div>

<div class="ayuda">
  <kbd>arrastrar</kbd> mover mapa &nbsp; <kbd>rueda</kbd> zoom &nbsp;
  <kbd>R</kbd> reencuadrar &nbsp; <kbd>M</kbd> fondo &nbsp; <kbd>Esc</kbd> salir
</div>

<script>
const WS = "ws://" + location.hostname + ":6996/ws";
const cv = document.getElementById("lienzo"), cx = cv.getContext("2d");

// Calibracion mundo -> imagen, tomada del livemap de NightRiderz (bundle
// SBRW-COMPILED, livemap/index.php). Nuestro mapa.png es ese mismo render
// (2048x1125) sobre un lienzo de 2048x2048. El mundo del juego mide 11.155
// unidades de ancho por 6.128 de alto y su Y crece hacia el norte (arriba).
// Antes se asumia que la imagen cubria +-2048 unidades y los coches caian
// fuera del lienzo (2026-09-06).
const IMG_W = 2048, IMG_H = 1125;
const MUNDO = { x0: 54.650002, ancho: 11155.66, y0: -1916.74, alto: 6127.9878, dy: 6 };
const aImagen = j => ({
  ix: (j.x - MUNDO.x0) / MUNDO.ancho * IMG_W,
  iy: (1 - (j.y - MUNDO.y0) / MUNDO.alto) * IMG_H + MUNDO.dy
});

// La vista es un encuadre sobre la IMAGEN (pixeles de imagen -> pixeles de
// lienzo). Por defecto se ve el mapa entero; rueda y arrastre hacen zoom y R lo
// reencuadra. Lo ajustado se guarda en el navegador (clave nueva: la antigua
// guardaba encuadres hechos con la calibracion equivocada).
let vista = { x:0, y:0, escala:1, auto:true, fondo:true };
try { Object.assign(vista, JSON.parse(localStorage.getItem("vistaMapa2") || "{}")); } catch(e){}

const guardar = () => { try { localStorage.setItem("vistaMapa2", JSON.stringify(vista)); } catch(e){} };

const fondo = new Image();
fondo.src = "/static/mapa.png";
let hayFondo = false;
fondo.onload = () => { hayFondo = true; };

let jugadores = [];
const colorDe = n => "hsl(" + ([...n].reduce((a,c)=>a+c.charCodeAt(0),0) * 47 % 360) + " 85% 62%)";

function medidas() {
  cv.width = cv.clientWidth * devicePixelRatio;
  cv.height = cv.clientHeight * devicePixelRatio;
}
addEventListener("resize", medidas); medidas();

function encuadrar() {
  // El mapa entero, centrado, con un pequeno margen.
  vista.escala = Math.min(cv.width / IMG_W, cv.height / IMG_H) * 0.96;
  vista.x = (cv.width - IMG_W * vista.escala) / 2;
  vista.y = (cv.height - IMG_H * vista.escala) / 2;
}

function pintar() {
  cx.fillStyle = "#07090c";
  cx.fillRect(0, 0, cv.width, cv.height);

  if (vista.auto) encuadrar();

  if (hayFondo && vista.fondo) {
    // Solo la franja util del PNG (2048x1125); el resto del lienzo es blanco.
    cx.globalAlpha = 0.9;
    cx.drawImage(fondo, 0, 0, IMG_W, IMG_H,
                 vista.x, vista.y, IMG_W * vista.escala, IMG_H * vista.escala);
    cx.globalAlpha = 1;
  }

  const dpr = devicePixelRatio;
  for (const j of jugadores) {
    const { ix, iy } = aImagen(j);
    const px = vista.x + ix * vista.escala;
    const py = vista.y + iy * vista.escala;
    const c = colorDe(j.name || "?");

    cx.beginPath();
    cx.arc(px, py, 14 * dpr, 0, 7);
    cx.fillStyle = c + "33";
    cx.fill();

    // Flecha con el rumbo, misma convencion que el livemap de referencia
    // (rotate(-(rotation-90)) sobre una flecha que apunta hacia arriba).
    const ang = -((((j.rotation || 0) - 90) % 360 + 360) % 360) * Math.PI / 180;
    cx.save();
    cx.translate(px, py);
    cx.rotate(ang);
    cx.beginPath();
    cx.moveTo(0, -9 * dpr); cx.lineTo(6 * dpr, 7 * dpr); cx.lineTo(0, 4 * dpr);
    cx.lineTo(-6 * dpr, 7 * dpr); cx.closePath();
    cx.fillStyle = c; cx.fill();
    cx.lineWidth = 1.2 * dpr; cx.strokeStyle = "#07090c"; cx.stroke();
    cx.restore();

    cx.font = "600 " + (12.5 * dpr) + "px 'Segoe UI',sans-serif";
    cx.fillStyle = "#e6edf3";
    cx.textAlign = "center";
    cx.fillText(j.name || "?", px, py - 15 * dpr);
  }
  requestAnimationFrame(pintar);
}
requestAnimationFrame(pintar);

// --- arrastrar y zoom -------------------------------------------------
let arrastrando = false, ax = 0, ay = 0;
cv.addEventListener("pointerdown", e => {
  arrastrando = true; vista.auto = false; ax = e.clientX; ay = e.clientY;
  cv.classList.add("arrastrando"); cv.setPointerCapture(e.pointerId);
});
cv.addEventListener("pointermove", e => {
  if (!arrastrando) return;
  vista.x += (e.clientX - ax) * devicePixelRatio;
  vista.y += (e.clientY - ay) * devicePixelRatio;
  ax = e.clientX; ay = e.clientY;
});
cv.addEventListener("pointerup", e => {
  arrastrando = false; cv.classList.remove("arrastrando"); guardar();
});
cv.addEventListener("wheel", e => {
  e.preventDefault();
  vista.auto = false;
  const f = e.deltaY < 0 ? 1.12 : 1 / 1.12;
  const mx = e.clientX * devicePixelRatio, my = e.clientY * devicePixelRatio;
  vista.x = mx - (mx - vista.x) * f;
  vista.y = my - (my - vista.y) * f;
  vista.escala *= f;
  guardar();
}, { passive: false });

addEventListener("keydown", e => {
  const k = e.key.toLowerCase();
  if (k === "r") { vista.auto = true; guardar(); }
  if (k === "m") { vista.fondo = !vista.fondo; guardar(); }
});

// --- websocket --------------------------------------------------------
const luz = document.getElementById("luz");
const conexion = document.getElementById("conexion");
const cuantos = document.getElementById("cuantos");
const lista = document.getElementById("lista");

function conectar() {
  const ws = new WebSocket(WS);

  ws.onopen = () => {
    luz.classList.remove("mal");
    conexion.textContent = "en directo";
  };

  ws.onmessage = ev => {
    try {
      const d = JSON.parse(ev.data);
      jugadores = Array.isArray(d) ? d : (d.players || d.Players || []);
      cuantos.textContent = jugadores.length;
      lista.innerHTML = jugadores
        .map(j => '<div><span style="color:' + colorDe(j.name || "?") + '">&#9679;</span> ' +
                  (j.name || "?") + "</div>")
        .join("") || '<div style="color:#5c6873">nadie conduciendo</div>';
    } catch (e) {}
  };

  ws.onclose = () => {
    luz.classList.add("mal");
    conexion.textContent = "sin conexión con el mundo abierto (puerto 6996), reintentando…";
    jugadores = []; cuantos.textContent = "0";
    setTimeout(conectar, 3000);
  };

  ws.onerror = () => ws.close();
}
conectar();
addEventListener("keydown", e => { if (e.key === "Escape") location.href = "/"; });
</script>
</html>"""


# =====================================================================
#  LA RADIO
#
#  NFS World no tiene emisoras: su musica son 17 pistas fijas que suenan en
#  orden aleatorio, y no hay forma de elegir desde el juego. Añadir un
#  selector de verdad exigiria escribir codigo en C++ contra el motor.
#
#  Asi que la radio va POR FUERA: el jugador baja el volumen de la musica en
#  las opciones del juego (son dos sliders separados; se puede matar la del
#  mundo abierto y dejar viva la de las carreras) y abre esta pagina.
#
#  Ventajas sobre cambiar los ficheros del juego: se cambia de emisora al
#  instante sin reiniciar, cada uno elige la suya, y las canciones que suban
#  los jugadores entran tal cual, sin convertir nada.
# =====================================================================

DIR_RADIO = RAIZ / "webregister" / "static" / "radio"

EMISORAS = [
    {"id": "eurobeat",     "nombre": "Eurobeat",      "lema": "Las 50 mejores, por orden"},
    {"id": "underground2", "nombre": "Underground 2", "lema": "La del garaje y el neon"},
    {"id": "mostwanted",   "nombre": "Most Wanted",   "lema": "Para huir de la poli"},
    {"id": "mezcla",       "nombre": "Todo mezclado", "lema": "Las dos, a lo loco"},
    {"id": "comunidad",    "nombre": "La del bar",    "lema": "Lo que suba la gente"},
]

# Momento en que arranca la emisora. Todos los que sintonizan calculan su
# posicion a partir de aqui, asi que oyen lo mismo a la vez: es una emisora
# de verdad, no cada uno su reproductor.
ARRANQUE_RADIO = time.time()


def duracion_mp3(ruta):
    """
    Duracion aproximada de un MP3, leyendo la cabecera del primer frame.

    Suficiente para sincronizar una emisora: si una cancion se desvia un
    segundo entre dos PC, nadie lo nota. Evita meter una libreria entera
    de audio en el Python empaquetado.
    """
    try:
        with open(ruta, "rb") as f:
            cab = f.read(4096)
        tam = os.path.getsize(ruta)

        ini = 0
        if cab[:3] == b"ID3":
            ini = 10 + ((cab[6] & 0x7F) << 21 | (cab[7] & 0x7F) << 14 |
                        (cab[8] & 0x7F) << 7 | (cab[9] & 0x7F))

        i = cab.find(b"\xff", ini)
        if i < 0 or i + 4 > len(cab):
            return 210.0
        h = cab[i:i + 4]
        tasas = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
        kbps = tasas[(h[2] >> 4) & 0xF]
        if kbps == 0:
            return 210.0
        return max(5.0, (tam - ini) * 8 / (kbps * 1000))
    except Exception:                                        # noqa: BLE001
        return 210.0


def canciones_de(emisora):
    """Lista de canciones de una emisora, con su duracion. 'mezcla' junta las otras."""
    if emisora == "mezcla":
        salida = []
        for e in ("underground2", "mostwanted"):
            salida += canciones_de(e)
        # Se barajan de forma estable (por nombre) para que el orden sea el
        # mismo en todos los navegadores: si no, cada uno oiria otra cosa.
        return sorted(salida, key=lambda c: c["url"][::-1])

    carpeta = DIR_RADIO / emisora
    if not carpeta.is_dir():
        return []
    salida = []
    for p in sorted(carpeta.glob("*.mp3")):
        # Las emisoras con orden propio llevan el puesto delante del nombre
        # ("01 - Artista - Titulo.mp3") para que el orden alfabetico sea el
        # ranking. Se quita al mostrarlo: el numero es de intendencia, el
        # jugador solo quiere ver el nombre de la cancion.
        titulo = re.sub(r"^\d{1,3}\s*[-.]\s*", "", p.stem)
        salida.append({
            "titulo": titulo[:70],
            "url": f"/static/radio/{emisora}/{urllib.parse.quote(p.name)}",
            "seg": round(duracion_mp3(p), 1),
        })
    return salida


@app.route("/radio/lista/<emisora>")
def radio_lista(emisora):
    """Lo que suena y desde cuando, para que todos vayan sincronizados."""
    if emisora not in [e["id"] for e in EMISORAS]:
        return {"error": "no existe esa emisora"}, 404
    return {"canciones": canciones_de(emisora), "arranque": ARRANQUE_RADIO,
            "ahora": time.time()}


@app.route("/radio/subir", methods=["POST"])
def radio_subir():
    """Un jugador sube una cancion a la emisora de la comunidad."""
    f = request.files.get("cancion")
    if not f or not f.filename:
        return redirect("/radio?error=vacio")
    if not f.filename.lower().endswith(".mp3"):
        return redirect("/radio?error=formato")

    # Nombre saneado: nada de rutas ni caracteres raros.
    limpio = re.sub(r"[^\w\s.\-]", "", os.path.basename(f.filename)).strip()
    if not limpio.lower().endswith(".mp3"):
        limpio += ".mp3"
    limpio = limpio[:80]

    destino = DIR_RADIO / "comunidad"
    destino.mkdir(parents=True, exist_ok=True)
    ruta = destino / limpio
    n = 1
    while ruta.exists():
        ruta = destino / f"{limpio[:-4]}_{n}.mp3"
        n += 1

    try:
        f.save(str(ruta))
        if ruta.stat().st_size > 25 * 1024 * 1024:   # 25 MB por cancion
            ruta.unlink()
            return redirect("/radio?error=grande")
    except Exception:                                        # noqa: BLE001
        return redirect("/radio?error=fallo")

    return redirect("/radio?emisora=comunidad&ok=1")


def consultar_mysql(sql):
    """
    Lanza una consulta contra la base de datos usando el cliente de linea de
    comandos que ya viaja en la carpeta. Se hace asi para no meter un driver
    de MySQL en el Python empaquetado: una dependencia menos que instalar en
    la maquina del evento.
    """
    import subprocess
    exe = RAIZ / "runtime" / "mysql" / "bin" / "mysql.exe"
    if not exe.is_file():
        return []
    entorno = dict(os.environ, MYSQL_PWD="LanParty2026!")
    try:
        r = subprocess.run(
            [str(exe), "--host=127.0.0.1", "--port=3306", "--user=root",
             "--silent", "--skip-column-names", "SOAPBOX", "-e", sql],
            capture_output=True, text=True, timeout=20, env=entorno,
            encoding="utf-8", errors="replace")
    except Exception:                                        # noqa: BLE001
        return []
    if r.returncode != 0:
        return []
    return [l.split("\t") for l in r.stdout.splitlines() if l.strip()]


# Como se puntua el destrozo. Son las estadisticas que el juego manda al
# servidor al acabar cada persecucion, asi que esto no inventa nada: solo
# decide cuanto vale cada gamberrada.
SQL_BUSCADOS = """
SELECT p.name,
       COUNT(*)                       AS persecuciones,
       COALESCE(MAX(d.heat),0)        AS heat_max,
       COALESCE(SUM(d.copsDisabled),0)     AS polis_fuera,
       COALESCE(SUM(d.copsRammed),0)       AS embestidas,
       COALESCE(SUM(d.roadBlocksDodged),0) AS controles,
       COALESCE(SUM(d.spikeStripsDodged),0)AS pinchos,
       COALESCE(SUM(d.costToState),0)      AS coste,
       COALESCE(SUM(d.bustedCount),0)      AS arrestos,
       (COALESCE(SUM(d.copsDisabled),0)      * 150
      + COALESCE(SUM(d.copsRammed),0)        *  25
      + COALESCE(SUM(d.roadBlocksDodged),0)  *  80
      + COALESCE(SUM(d.spikeStripsDodged),0) * 120
      + COALESCE(SUM(d.costToState),0)       / 1000
      + COALESCE(MAX(d.heat),0)              * 400
      - COALESCE(SUM(d.bustedCount),0)       * 200) AS puntos
  FROM event_data d JOIN persona p ON p.ID = d.personaId
 WHERE d.eventModeId IN (12, 24)
 GROUP BY p.name
 ORDER BY puntos DESC
 LIMIT 30;
"""


@app.route("/masbuscados")
def masbuscados():
    """
    La lista de los mas buscados: no quien corre mas, sino quien hace mas dano.

    NFS World no permite persecuciones en mundo abierto (EA las quito en 2011),
    asi que lo mas parecido a Most Wanted que se puede montar es esto: puntuar
    la agresividad en los eventos de persecucion y proyectarlo en una pantalla.
    """
    filas = consultar_mysql(SQL_BUSCADOS)

    if not filas:
        cuerpo = """
          <div class="aviso nota">
            <b>Todavia no hay expedientes.</b><br>
            La lista se llena sola en cuanto alguien corra una persecucion
            (Pursuit Outrun) o un Team Escape.
          </div>"""
    else:
        medallas = ["①", "②", "③"]
        filas_html = []
        for i, f in enumerate(filas):
            if len(f) < 10:
                continue
            (nombre, pers, heat, polis, emb, ctrl, pinchos,
             coste, arrestos, puntos) = f[:10]
            destacado = ' class="lider"' if i == 0 else ""
            puesto = medallas[i] if i < 3 else str(i + 1)
            try:
                coste_txt = f"{int(float(coste)):,}".replace(",", ".")
                puntos_txt = f"{int(float(puntos)):,}".replace(",", ".")
            except ValueError:
                coste_txt, puntos_txt = coste, puntos
            filas_html.append(
                f"<tr{destacado}>"
                f'<td class="puesto">{puesto}</td>'
                f"<td><b>{nombre}</b></td>"
                f'<td class="num">{puntos_txt}</td>'
                f'<td class="num">{heat}</td>'
                f'<td class="num">{polis}</td>'
                f'<td class="num">{ctrl}</td>'
                f'<td class="num">{pinchos}</td>'
                f'<td class="num">{coste_txt}</td>'
                f'<td class="num">{arrestos}</td>'
                f"</tr>")

        cuerpo = f"""
          <div class="panel">
            <table>
              <tr>
                <th></th><th>Piloto</th><th style="text-align:right">Puntos</th>
                <th style="text-align:right">Heat</th>
                <th style="text-align:right">Polis</th>
                <th style="text-align:right">Controles</th>
                <th style="text-align:right">Pinchos</th>
                <th style="text-align:right">Danos</th>
                <th style="text-align:right">Arrestos</th>
              </tr>
              {''.join(filas_html)}
            </table>
          </div>"""

    extra = """
      <style>
        tr.lider td { background:rgba(255,107,26,.10); }
        tr.lider td b { color:var(--acento); }
        td.puesto { color:var(--suave); width:34px; font-variant-numeric:tabular-nums; }
        table { font-variant-numeric:tabular-nums; }
      </style>"""

    return pagina("Los mas buscados", "buscados", extra + f"""
      <h1>Los mas buscados</h1>
      <p class="sub">Aqui no gana el que corre mas rapido, sino el que hace mas dano.
         Se llena solo con cada persecucion y cada Team Escape.</p>
      {cuerpo}
      <div class="panel">
        <b>Como se puntua</b>
        <ul>
          <li>Dejar un coche de policia fuera de combate &mdash; <b>150</b></li>
          <li>Esquivar una banda de pinchos &mdash; <b>120</b></li>
          <li>Reventar un control de carretera &mdash; <b>80</b></li>
          <li>Embestir a un coche de policia &mdash; <b>25</b></li>
          <li>Cada nivel de heat alcanzado &mdash; <b>400</b></li>
          <li>Danos causados &mdash; <b>1 punto por cada 1.000</b></li>
          <li>Que te arresten &mdash; <b>&minus;200</b></li>
        </ul>
      </div>""")


@app.route("/radio")
def radio():
    avisos = {
        "vacio":   "No elegiste ningun fichero.",
        "formato": "Solo valen MP3.",
        "grande":  "Esa cancion pesa demasiado (maximo 25 MB).",
        "fallo":   "No se pudo guardar. Prueba otra vez.",
    }
    err = request.args.get("error")
    inicial = request.args.get("emisora", "underground2")
    aviso = ""
    if err in avisos:
        aviso = f'<div class="aviso mal">{avisos[err]}</div>'
    elif request.args.get("ok"):
        aviso = '<div class="aviso ok">Cancion subida. Ya suena en La del bar.</div>'

    tarjetas = "".join(
        f'<button class="emisora" data-id="{e["id"]}">'
        f'<span class="nom">{e["nombre"]}</span>'
        f'<span class="lema">{e["lema"]}</span>'
        f'<span class="cuenta" id="n-{e["id"]}"></span></button>'
        for e in EMISORAS)

    return pagina("Radio", "radio", f"""
      <style>
        .emisoras {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(180px,1fr));
                     gap:12px; margin:22px 0; }}
        .emisora {{ background:var(--panel); border:1px solid var(--linea); color:var(--texto);
                    border-radius:10px; padding:15px 17px; cursor:pointer; text-align:left;
                    font:inherit; display:flex; flex-direction:column; gap:3px;
                    transition:border-color .15s, background .15s; }}
        .emisora:hover {{ border-color:var(--acento); }}
        .emisora.puesta {{ border-color:var(--acento); background:rgba(255,107,26,.10); }}
        .emisora .nom {{ font-weight:600; font-size:16.5px; }}
        .emisora .lema {{ color:var(--suave); font-size:13.5px; }}
        .emisora .cuenta {{ color:var(--suave); font-size:12px; margin-top:4px;
                            font-variant-numeric:tabular-nums; }}
        .dial {{ background:var(--panel); border:1px solid var(--linea); border-radius:10px;
                 padding:20px 24px; margin-bottom:20px; }}
        .sonando {{ font-size:19px; font-weight:600; margin:0 0 4px; }}
        .info {{ color:var(--suave); font-size:14px; margin:0 0 14px; }}
        audio {{ width:100%; }}
        .subir {{ display:flex; gap:10px; flex-wrap:wrap; align-items:center; margin-top:12px; }}
        input[type=file] {{ flex:1; min-width:200px; padding:9px; background:#0d1117;
                            border:1px solid var(--linea); border-radius:7px; color:var(--texto); }}
      </style>

      <h1>Radio</h1>
      <p class="sub"><b>Suena en esta pestana del navegador, no dentro del juego</b> (el juego no
         admite emisoras: baja su musica en Opciones y deja esta pagina abierta al lado).<br>
         Cuatro emisoras. Todos los que sintonizan la misma oyen lo mismo
         a la vez, como una radio de verdad.</p>
      {aviso}

      <div class="dial">
        <p class="sonando" id="sonando">Elige una emisora</p>
        <p class="info" id="info">&nbsp;</p>
        <audio id="reproductor" controls></audio>
      </div>

      <div class="emisoras">{tarjetas}</div>

      <div class="panel">
        <b>Sube tu cancion a «La del bar»</b>
        <p style="margin:6px 0 0;color:var(--suave);font-size:14.5px">
          Un MP3, maximo 25 MB. Sonara para todo el que tenga esa emisora puesta.
          Con cabeza, que lo va a oir la sala entera.</p>
        <form class="subir" method="post" action="/radio/subir" enctype="multipart/form-data">
          <input type="file" name="cancion" accept="audio/mpeg,.mp3" required>
          <button type="submit">Subir</button>
        </form>
      </div>

      <div class="aviso nota">
        <b>Para que se oiga bien:</b> baja a cero la musica dentro del juego
        (Opciones &rsaquo; Audio). Son dos controles distintos, asi que puedes
        dejar viva la de las carreras y quitar solo la del mundo abierto.
        Los efectos y los motores no se tocan.
      </div>

      <script>
      const audio = document.getElementById("reproductor");
      const tituloEl = document.getElementById("sonando");
      const infoEl = document.getElementById("info");
      let emisora = null, lista = [], arranque = 0, desfase = 0, indice = -1;

      // Cada emisora lleva sonando desde que arranco el servidor. Al
      // sintonizar, se calcula en que punto va y se salta ahi: por eso todos
      // oyen lo mismo, en vez de empezar cada uno por el principio.
      function situar() {{
        if (!lista.length) return;
        const total = lista.reduce((a, c) => a + c.seg, 0);
        if (total <= 0) return;
        let t = ((Date.now() / 1000 + desfase) - arranque) % total;
        let i = 0;
        while (t >= lista[i].seg) {{ t -= lista[i].seg; i = (i + 1) % lista.length; }}
        if (i !== indice) {{
          indice = i;
          audio.src = lista[i].url;
          tituloEl.textContent = lista[i].titulo;
        }}
        audio.currentTime = Math.max(0, t);
        audio.play().catch(() => {{
          infoEl.textContent = "Pulsa play (el navegador no deja arrancar solo)";
        }});
      }}

      async function sintonizar(id) {{
        emisora = id; indice = -1;
        document.querySelectorAll(".emisora").forEach(b =>
          b.classList.toggle("puesta", b.dataset.id === id));
        try {{
          const r = await fetch("/radio/lista/" + id);
          const d = await r.json();
          lista = d.canciones || [];
          arranque = d.arranque;
          desfase = d.ahora - Date.now() / 1000;   // reloj del servidor
          if (!lista.length) {{
            tituloEl.textContent = "Esta emisora esta vacia";
            infoEl.textContent = "Sube una cancion ahi abajo y empieza tu.";
            audio.removeAttribute("src");
            return;
          }}
          const mins = Math.round(lista.reduce((a, c) => a + c.seg, 0) / 60);
          infoEl.textContent = lista.length + " canciones \\u00b7 " + mins + " min";
          situar();
        }} catch (e) {{
          tituloEl.textContent = "No pude cargar la emisora";
        }}
      }}

      audio.addEventListener("ended", () => {{
        indice = (indice + 1) % lista.length;
        audio.src = lista[indice].url;
        tituloEl.textContent = lista[indice].titulo;
        audio.play().catch(() => {{}});
      }});

      document.querySelectorAll(".emisora").forEach(b =>
        b.addEventListener("click", () => sintonizar(b.dataset.id)));

      // Cuantas canciones tiene cada una, para verlo antes de elegir.
      for (const b of document.querySelectorAll(".emisora")) {{
        fetch("/radio/lista/" + b.dataset.id)
          .then(r => r.json())
          .then(d => {{
            const n = (d.canciones || []).length;
            document.getElementById("n-" + b.dataset.id).textContent =
              n ? n + " canciones" : "vacia";
          }}).catch(() => {{}});
      }}

      sintonizar({inicial!r});
      </script>""")


@app.route("/mapa")
def mapa():
    """Mapa en vivo para proyectar. No usa la plantilla comun: va a pantalla completa."""
    return MAPA


# ---------------------------------------------------------------------
#  MODNET (catalogo de mods del servidor para el launcher de SBRW)
#
#  El launcher pregunta al core /Modding/GetModInfo; si responde (parametros
#  MODDING_* en la tabla parameter), descarga <MODDING_BASE_PATH>/index.json y,
#  SOLO ENTONCES, arranca el juego con sus parches de red y de habilidades
#  (es lo que sustituyo a los viejos modulos udpcrc/udpcrypt). Sin ModNet el
#  cliente corre "de serie": el mundo abierto nunca engancha (repite el hello
#  cada 5 s) y los power-ups no funcionan. Descubierto el 2026-09-05 tras
#  pelearse con el freeroam durante horas: la guia de SBRW-COMPILED lo dice
#  textualmente ("this will enable powerups and multiplayer ingame").
#
#  El catalogo va vacio a proposito: nuestros mods viajan dentro del ZIP del
#  cliente. cars.json y events.json son opcionales para el launcher (404 vale).
# ---------------------------------------------------------------------
@app.route("/modnet/index.json")
def modnet_index():
    return Response('{"built_at": "2026-09-05T00:00:00Z", "entries": []}',
                    mimetype="application/json")


# ---------------------------------------------------------------------
#  PILOTOS: quien esta registrado y quien esta dentro del juego ahora.
#
#  "Conectado" se mira preguntando al chat (Openfire): el juego abre una
#  sesion XMPP sbrw.<personaId> al entrar y la cierra al salir, asi que es
#  la senal mas fiable que hay sin tocar el servidor del juego.
# ---------------------------------------------------------------------
SQL_PILOTOS = """
SELECT u.ID, u.EMAIL, u.isAdmin + 0,
       COALESCE(GROUP_CONCAT(CONCAT(p.ID, ':', p.name, ':', p.level, ':', COALESCE(p.cash, 0))
                             ORDER BY p.ID SEPARATOR '|'), ''),
       COALESCE(DATE_FORMAT(MAX(p.last_login), '%d/%m %H:%i'), '-')
  FROM user u LEFT JOIN persona p ON p.USERID = u.ID
 GROUP BY u.ID, u.EMAIL, u.isAdmin
 ORDER BY MAX(p.last_login) DESC, u.ID;
"""


def personas_conectadas():
    """Ids de persona con sesion XMPP abierta ahora mismo (o vacio si no se puede saber)."""
    import re
    import urllib.request
    filas = consultar_mysql("SELECT value FROM parameter WHERE name = 'OPENFIRE_TOKEN';")
    token = filas[0][0].strip() if filas and filas[0] else ""
    if not token:
        return set()
    try:
        peticion = urllib.request.Request(
            "http://127.0.0.1:9090/plugins/restapi/v1/sessions",
            headers={"Authorization": token, "Accept": "application/xml"})
        with urllib.request.urlopen(peticion, timeout=5) as r:
            xml = r.read().decode("utf-8", "replace")
    except Exception:                                            # noqa: BLE001
        return set()
    return set(re.findall(r"<username>sbrw\.(\d+)</username>", xml))


def correo_discreto(email):
    """danteiscrazy@crazy.party -> dan***@crazy.party (la web la ve toda la sala)."""
    if "@" not in email:
        return email
    local, dominio = email.split("@", 1)
    return (local[:3] + "***" if len(local) > 3 else local) + "@" + dominio


@app.route("/pilotos")
def pilotos():
    filas = consultar_mysql(SQL_PILOTOS)
    dentro = personas_conectadas()
    tarjetas = []
    conectados = 0
    for f in filas:
        if len(f) < 5:
            continue
        uid, email, admin, personas, ultimo = f[:5]
        chips = []
        for p in (x for x in personas.split("|") if x):
            partes = p.split(":")
            if len(partes) < 4:
                continue
            pid, nombre, nivel, cash = partes[:4]
            online = pid in dentro
            conectados += 1 if online else 0
            try:
                cash_txt = f"{int(float(cash)):,}".replace(",", ".")
            except ValueError:
                cash_txt = cash
            chips.append(
                f'<span class="piloto {"online" if online else ""}">'
                f'<b>{nombre}</b> <small>nivel {nivel} &middot; {cash_txt} $</small>'
                f'{" &middot; <em>EN EL JUEGO</em>" if online else ""}</span>')
        tarjetas.append(
            f"<tr><td>{''.join(chips) or '<span class=\"suave\">sin piloto todavia</span>'}</td>"
            f"<td>{correo_discreto(email)}{' <span class=\"admin\">ADMIN</span>' if admin == '1' else ''}</td>"
            f'<td class="num">{ultimo}</td></tr>')

    cuerpo = ("""<div class="aviso nota"><b>Todavia no hay nadie registrado.</b></div>"""
              if not tarjetas else f"""
        <div class="panel">
          <table>
            <tr><th>Piloto</th><th>Cuenta</th><th style="text-align:right">Ultima entrada</th></tr>
            {''.join(tarjetas)}
          </table>
        </div>""")

    extra = """
      <meta http-equiv="refresh" content="30">
      <style>
        .piloto { display:inline-block; margin:2px 6px 2px 0; padding:4px 10px; border-radius:8px;
                  background:rgba(255,255,255,.05); border:1px solid #2a323c; }
        .piloto.online { border-color:var(--acento); background:rgba(255,107,26,.12); }
        .piloto em { color:var(--acento); font-style:normal; font-weight:700; letter-spacing:.04em; }
        .piloto small { color:var(--suave); }
        .admin { font-size:11px; color:var(--acento); border:1px solid var(--acento); border-radius:4px;
                 padding:1px 5px; margin-left:6px; vertical-align:middle; }
        .suave { color:var(--suave); }
        .cifra-grande { font-size:42px; font-weight:800; line-height:1; color:var(--acento); }
      </style>"""

    return pagina("Pilotos", "pilotos", extra + f"""
      <h1>Pilotos</h1>
      <p class="sub">Quien esta registrado y quien esta dentro del juego ahora mismo.
         Se actualiza solo cada 30 segundos.</p>
      <div class="panel" style="display:flex;gap:28px;align-items:center">
        <div><div class="cifra-grande">{conectados}</div><div class="suave">en el juego ahora</div></div>
        <div><div class="cifra-grande" style="color:var(--texto)">{len(tarjetas)}</div><div class="suave">cuentas registradas</div></div>
      </div>
      {cuerpo}
      <div class="panel suave">
        Para crear las 50 cuentas de fiesta con sus tarjetas, usa el boton <b>Cuentas</b> del panel del servidor.
      </div>""")


@app.route("/descargar/<path:rel>")
def descargar(rel):
    # send_from_directory ya impide salir de la carpeta con ../
    return send_from_directory(DIR_GAMEFILES, rel, as_attachment=True)


@app.route("/descargar-todo")
def descargar_todo():
    # Retirado el 2026-09-27: montaba en memoria un ZIP con el cliente de 2 GB
    # dentro. Con tres descargas sueltas no aporta nada; se deja la ruta por si
    # alguien tiene el enlace guardado.
    return redirect(url_for("descargas"))
    ficheros, _ = listar_gamefiles()
    if not ficheros:
        return redirect(url_for("descargas"))

    memoria = io.BytesIO()
    # Sin compresion: son ficheros de juego ya comprimidos, y comprimir otra vez
    # solo gastaria CPU del servidor con 50 personas descargando a la vez.
    with zipfile.ZipFile(memoria, "w", zipfile.ZIP_STORED) as z:
        for f in ficheros:
            z.write(DIR_GAMEFILES / f["rel"], f["rel"])
    memoria.seek(0)
    return Response(memoria.read(), mimetype="application/zip",
                    headers={"Content-Disposition": "attachment; filename=nfsw-cliente.zip"})


if __name__ == "__main__":
    ip = ip_lan()
    print()
    print("  Web de registro y descargas")
    print(f"    Para los jugadores:  http://{ip}:{PUERTO_WEB}")
    print(f"    Servidor del juego:  {CORE}")
    print()
    # threaded: 50 personas descargando a la vez sin bloquear el registro.
    app.run(host="0.0.0.0", port=PUERTO_WEB, threaded=True)
