# Crazy Server — NFS World para LAN party

Carpeta autocontenida para montar un servidor privado de NFS World en una LAN party.
Se copia a cualquier Windows, se arranca con dos comandos y a correr.

**No necesita internet en el evento.** No hace falta instalar Java, MySQL ni Python:
todo viaja dentro de la carpeta.

---

## Arranque rápido

**Doble clic en `Crazy Server.bat`.** Se abre el panel de control: seis luces de
estado, un botón grande de arrancar, y las dos direcciones que hay que dictar a
los jugadores con un botón para copiarlas.

La primera vez en cada máquina, pulsa antes **Preparar PC** (pide administrador:
es para abrir los puertos en el firewall).

Si prefieres la consola, el panel no hace nada que no puedas hacer a mano. Abre
**PowerShell como administrador** en esta carpeta:

```powershell
.\scripts\setup.ps1     # solo la primera vez en cada máquina
.\scripts\start.ps1     # cada vez que quieras levantar el servidor
.\scripts\status.ps1    # comprueba que todo está en verde
```

`status.ps1` te dirá las dos direcciones que hay que dar a los jugadores. Apúntalas
en una pizarra y listo.

Para parar: `.\scripts\stop.ps1`

> El panel se puede cerrar sin miedo: el servidor sigue funcionando. Es un mando a
> distancia, no el servidor en sí.

---

## Qué le dices a los jugadores

Dos cosas, y la IP la saca `status.ps1` (cambia en cada evento):

| | |
|---|---|
| **Servidor** (se pega en el launcher) | `http://<IP>:8080/Engine.svc` |
| **Descargas y registro** (se abre en el navegador) | `http://<IP>:5000` |

Y estos cuatro pasos, que caben en un papel:

1. Descarga el juego y el launcher desde `http://<IP>:5000`.
2. Descomprime el juego en una carpeta cualquiera — **menos** en Escritorio,
   Documentos, Descargas, Archivos de programa o la raíz del disco. El launcher
   rechaza esas rutas.
3. En la carpeta del launcher, doble clic en **`Anadir-servidor-LAN.bat`**. Añade
   nuestro servidor a su lista (una vez por máquina y listo).
4. Abre el launcher. **Si avisa de que no hay internet, pulsa «No»** para continuar.
5. **Arriba a la derecha, en el desplegable, elige «Crazy Server».** Si te dejas puesto
   «WorldUnited OFFICIAL» estarás intentando entrar en el servidor público de internet,
   donde tu cuenta no existe. Es el error número uno.
6. Regístrate en `http://<IP>:5000`, entra, y elige tu nombre de piloto.

> **El nombre de piloto solo admite MAYÚSCULAS y NÚMEROS, de 3 a 15 caracteres.**
> Ni minúsculas, ni espacios, ni acentos, ni guiones. `DANTE`, `RX7`, `SPEED99` valen.
> Esto es lo que más atasca a la gente en el primer arranque: dilo antes de que pregunten.

### Consejo: no repartas el juego por la red

El cliente son 3 GB. Con 50 personas descargándolo a la vez son 150 GB por la red, y
media hora larga de espera colectiva mirando barras de progreso.

**Lleva el juego en dos o tres pendrives** y que se lo vayan pasando mientras se
sientan. La descarga web déjala como plan B para el que llegue tarde. Lo que sí
conviene que todos cojan de la web es el **launcher** (7 MB), porque viene con la
dirección del servidor ya puesta.

---

## Antes del evento

- [ ] `setup.ps1` ejecutado en la máquina servidor (abre los puertos del firewall).
- [ ] `start.ps1` y `status.ps1` en verde, con los 6 servicios activos.
- [ ] La carpeta `gamefiles\` tiene el cliente del juego para descargar.
- [ ] Modo fiesta aplicado (ver abajo) — si no, la mitad de los circuitos están apagados.
- [ ] Cuentas creadas y tarjetas impresas, si vas a repartirlas:
      `.\scripts\crear-cuentas.ps1 -Cantidad 50 -Aplicar`
- [ ] Probado con **dos** ordenadores: que se vean en el mundo abierto y que puedan
      correr una carrera juntos. Es la única prueba que vale.

---

## Modo fiesta

La base de datos que trae el juego viene pensada para un servidor público con progresión
de meses. Para una tarde eso no vale. El modo fiesta abre todo:

```powershell
.\runtime\mysql\bin\mysql.exe -u root -pLanParty2026! SOAPBOX < .\db\party-setup.sql
.\scripts\stop.ps1
.\scripts\start.ps1
```

Qué cambia:

- **165 circuitos jugables** en vez de 81 — la mitad venían desactivados.
- Cualquier coche en cualquier carrera (venían atados a su clase).
- Los 3712 productos de la tienda desbloqueados, coches incluidos.
- Se empieza a nivel máximo y con dinero de sobra.
- Potenciadores infinitos y sin daño en los coches.
- Un solo canal de chat, para que los 50 se vean entre sí.

> **Hay que reiniciar el servidor después.** El juego guarda estos datos en memoria
> y no los relee solo.

---

## Los scripts

| Script | Para qué |
|---|---|
| **`panel.ps1`** | **El panel de control.** Se abre con `Crazy Server.bat`. Hace todo lo de abajo, con botones. |
| `setup.ps1` | Preparar la máquina: firewall y base de datos. Una vez por equipo. |
| `start.ps1` | Arrancar los 6 servicios. Detecta la IP y la reparte a los clientes. |
| `stop.ps1` | Parar todo ordenadamente. |
| `status.ps1` | ¿Está listo? ¿Qué IP doy? Añade `-Detalle` si algo falla. |
| `crear-cuentas.ps1` | Genera cuentas y **tarjetas imprimibles** para repartir. |
| `backup-db.ps1` | Guarda una copia de los perfiles y coches. |
| `reset.ps1` | Borra todo y deja el servidor listo para el siguiente evento. |
| `update-gamefiles.ps1` | Cambiar la versión del juego que se reparte. |
| **`megafono.ps1`** | **Hablar a los 50 a la vez** y cambiar reglas sin reiniciar. |
| **`tesoro.ps1`** | **Búsqueda del tesoro** con premios de verdad. |
| **`decorado.ps1`** | **Decorado festivo de la ciudad** (Halloween, Navidad, Año Nuevo, Oktoberfest) para todos, en caliente. |
| **`regalo.ps1`** | **Regalar** a un piloto un coche del catálogo, dinero o un objeto. Con `-Simular` para ensayar y `-Quitar` para deshacer. |
| **`carrera-estrella.ps1`** | **La final de la noche**: premio garantizado al ganador de un evento (coche o millones), 2.º y 3.º, anuncio y `-Revertir`. |
| `controles.ps1` | Aislar problemas de mandos en un minuto: apaga/enciende el mod de mandos y pone los ficheros originales o los mods. |

Todos se pueden ejecutar varias veces sin romper nada.

---

## Durante la fiesta

### El megáfono

Manda un aviso a todos los que estén conectados, aparezca donde aparezca cada uno:

```powershell
.\scripts\megafono.ps1 "Manga 3 en 2 minutos. A la parrilla."
.\scripts\megafono.ps1                # modo interactivo, con avisos preparados
```

Y cambia reglas **sin reiniciar el servidor**:

```powershell
.\scripts\megafono.ps1 -HoraFeliz     # recompensas por las nubes
.\scripts\megafono.ps1 -Forajidos     # embestir a la policía paga como nunca
.\scripts\megafono.ps1 -Normal        # volver a la normalidad
```

### La búsqueda del tesoro

Quince monedas escondidas por la ciudad. Lo bueno: por defecto cada jugador
tiene las suyas en sitios distintos —así que no compiten—, y esto pone **las
mismas para todos**.

```powershell
.\scripts\tesoro.ps1 -Premios     # una sola vez, al montar el servidor
.\scripts\tesoro.ps1 -Lanzar      # cada ronda: monedas nuevas para todos
.\scripts\tesoro.ps1 -Estado      # quién va ganando
```

Completarla da 250.000 fijos más un premio: dinero a espuertas, imanes de
tráfico o, con suerte, **un coche**. Proyecta el mapa en vivo mientras tanto y
verás a cincuenta coches convergiendo al mismo punto.

*Los pilotos tienen que haber entrado al juego al menos una vez antes de lanzar
la primera ronda.*

### La banda sonora

Se puede poner **la música que quieras**: Underground 2, Most Wanted, eurobeat
de Initial D, lo que sea. El juego guarda la música en un formato propio de EA,
y el script la convierte y la coloca sola.

```powershell
.\scripts\musica.ps1 -Origen "D:
uta	us\mp3"
.\scripts\musica.ps1 -Origen "D:\eurobeat" -Pistas todas
.\scripts\musica.ps1 -Restaurar
```

Hace copia de la música original la primera vez, así que siempre se puede
volver atrás. Por defecto cambia las 8 pistas que más se oyen; con
`-Pistas todas` cambia las 17.

> **Para que la oigan los 50** hay que repartirla: o rehaces el ZIP del cliente
> con la música ya dentro, o la empaquetas como mod. Cambiarla aquí solo afecta
> a esta copia del juego.

> Algún MP3 suelto puede fallar en la conversión; el script lo dice y sigue con
> los demás. Suele ser cosa del fichero, no del juego.

### La radio

Cuatro emisoras, y **todos los que sintonizan la misma oyen lo mismo a la vez**:

```
http://<IP>:5000/radio
```

Underground 2, Most Wanted, las dos mezcladas, y **«La del bar»**, donde los
jugadores suben sus propias canciones desde la misma página.

**Por qué va por fuera del juego y no dentro:** NFS World no tiene emisoras —
son 17 pistas fijas en orden aleatorio y no hay forma de elegir. Añadir un
selector de verdad exigiría programar contra el motor del juego. Yendo por el
navegador se cambia de emisora al instante, cada uno pone la suya, y las
canciones que suba la gente entran tal cual sin convertir nada.

**Dile a los jugadores** que bajen a cero la música dentro del juego
(Opciones › Audio). Son dos controles distintos: se puede dejar viva la de las
carreras y quitar solo la del mundo abierto. Los motores y los efectos no se
tocan.

> Añadir emisoras es crear carpetas en `webregister\staticadio\` con MP3
> dentro, y añadirlas a la lista `EMISORAS` de `app.py`.

### Mandos

**El cliente ya lleva soporte de mandos modernos.** Va dentro del ZIP que
descargan los jugadores, sin instalar nada ni pedir permisos de administrador.

- **Mandos de Xbox** (360, One, Series): enchufar y jugar.
- **Mandos de PlayStation** (DS4, DualSense): por USB-C Windows los reconoce
  solo. Si alguno da problemas, la salida rápida es añadir el juego a Steam
  como juego ajeno y activar el soporte de PlayStation en Steam Input — sin
  instalar drivers.

> **Pide cable.** Por Bluetooth la latencia se duplica y algún modelo de mando
> de Xbox provoca tirones. Con 50 personas en una sala, el 2,4 GHz es un caos.

> El juego, de fábrica, es de 2010 y solo entendía mandos de aquella época: por
> eso hace falta esta capa. Y ojo — **los menús siguen necesitando ratón**; el
> mando sirve para conducir.

### Los más buscados

Un marcador que **no premia al más rápido, sino al que más daño hace**:

```
http://<IP>:5000/masbuscados
```

Se llena solo con cada persecución y cada Team Escape. Puntúa dejar coches de
policía fuera de combate, esquivar pinchos, reventar controles, el nivel de
heat alcanzado y los daños causados — y resta si te arrestan.

Es lo más parecido a Most Wanted que permite el juego, porque **NFS World no
tiene policía en mundo abierto**: EA la quitó en 2011 y no se puede recuperar
(la inteligencia policial es código del motor, no datos). Lo que sí hay son
7 eventos de persecución individual y 8 pistas de Team Escape cooperativo
—una de ellas se llama, literalmente, «Most Wanted»—.

Proyectado junto al mapa en vivo, es media pared de pantalla bien aprovechada.

### El mapa en vivo

Para la pantalla grande:

```
http://<IP>:5000/mapa
```

Todos los coches en tiempo real, sin el límite de 14 que tiene el juego.
Arrastra para mover, rueda para el zoom, `R` para reencuadrar y `M` para
quitar el fondo. Lo que ajustes se queda guardado en ese navegador.

> La primera vez habrá que cuadrar el mapa de fondo con los coches a mano: la
> correspondencia entre las coordenadas del juego y la imagen no está
> documentada en ninguna parte. Con dos personas dentro se cuadra en un minuto.

---

## Si algo falla

**Entran al juego pero no se ven entre ellos.**
Casi siempre es el firewall bloqueando UDP. Ejecuta `.\scripts\status.ps1 -Detalle`
y mira la sección de firewall: tienen que estar las 5 reglas. Si faltan, `setup.ps1`
como administrador.

**Nadie puede conectar.**
Comprueba que la IP que estás dando es la buena: `status.ps1` la muestra y descarta
las tarjetas virtuales (VirtualBox, WSL, Hyper-V) y las VPN de malla (ZeroTier,
Tailscale, Radmin, Hamachi), que es el error clásico. Si aun así elige mal, fuérzala:

```powershell
.\scripts\start.ps1 -Ip 192.168.1.50
```

**Funciona en mi PC y en otro no.**
El primer sospechoso es la versión de PowerShell: el servidor está probado con el
**Windows PowerShell 5.1** que trae Windows de fábrica, que es el que usa el panel.
Si el otro PC da errores raros de "argumento null o vacío" o acentos rotos en la
consola, abre PowerShell en la carpeta y lanza `.\scripts\status.ps1 -Detalle`: la
salida dice qué falta. El segundo sospechoso es el firewall: `setup.ps1` como
administrador crea las seis reglas.

**El launcher se queda esperando al arrancar, o no arranca el juego.**
Ese PC necesita **internet**. Desde el 6 de septiembre de 2026 el servidor tiene
ModNet activado (`MODDING_ENABLED`), y con ModNet el launcher comprueba sus módulos
en `cdn.soapboxrace.world` cada vez que se pulsa jugar: unos 5 MB la primera vez y
nada las siguientes, pero si no llega, **no lanza el juego**.

Vale la pena, porque esos módulos (`ModLoader.asi`) son los que hacen que el mundo
abierto funcione — sin ellos el juego rechaza los paquetes del servidor, cada uno
juega solo y las habilidades no responden.

Si el sitio no va a tener internet, hay que recompilar el launcher apuntando a este
servidor. Los ficheros ya están guardados y verificados en
`_build\modnet-mirror\launcher-modules\`.

**El juego no ve el mando, pero Windows sí.**
Casi siempre hay dos carpetas del juego en ese PC y el launcher arranca la que no
tiene los mods. Mira `Settings.ini` junto al launcher, línea `InstallationDirectory`,
y comprueba que en esa carpeta existe `scripts\NFS_XtendedInput.asi`. El launcher y
el juego son **dos carpetas separadas**; el launcher nunca va dentro del juego.

**«Your NFSW.exe is Modified».**
El cliente está modificado o incompleto. Que lo vuelva a descargar de
`http://<IP>:5000` y lo descomprima entero.

**El servidor del juego no arranca.**
Mira `logs\core.log`. Las dos causas habituales: la base de datos no está levantada,
o el chat (Openfire) no responde — el servidor del juego lo necesita para arrancar.
Desde el 28-09 `start.ps1` espera a que Openfire tenga los plugins cargados antes de
lanzar el juego y lo reintenta una vez si aun así se conectó demasiado pronto.

**Falla en un PC que no es el mío y no sé por qué.**
`.\scripts\diagnostico.ps1` (o el botón **Diagnóstico** del panel) deja en `logs\` un
`diagnostico-<fecha>.txt` con Windows, PowerShell, RAM, la IP, qué ocupa cada puerto,
los rangos de puertos que Windows tiene reservados, si faltan DLL o hay ficheros
bloqueados por "descargado de internet", y el final de cada log con el `Caused by`.
Es lo que hay que pedir. `start.ps1` ya se niega a arrancar, con el motivo en una
línea, si la carpeta está dentro de OneDrive, si Windows tiene reservado un puerto
del servidor (Hyper-V/WSL: `net stop winnat` y `net start winnat` como administrador)
o si otro programa está usando uno de los puertos; y baja la memoria del servidor
del juego en equipos con menos de 8 GB.

**Cambié algo en la base de datos y no se nota.**
Reinicia el servidor. Los datos se cachean en memoria.

---

## Después del evento

```powershell
.\scripts\backup-db.ps1          # guarda los perfiles, por si acaso
.\scripts\reset.ps1              # deja todo limpio para la próxima
```

`reset.ps1` pide confirmación escrita y hace una copia de seguridad automática antes
de borrar. **No toca los archivos del juego**, que son los que pesan.

---

## Qué hay dentro

```
runtime\        Java, MySQL y Python. Por esto no hay que instalar nada.
server\         El servidor del juego, el chat, el mundo abierto y las carreras.
db\             Base de datos y el SQL del modo fiesta.
webregister\    La web de registro y descargas (puerto 5000).
gamefiles\      El cliente del juego que descargan los jugadores.
launcher\       El launcher, ya configurado con la dirección del servidor.
mods\           Preparado para mods (aún sin usar).
scripts\        Los scripts de arriba, y el panel de control.
logs\           Registros. Mira aquí cuando algo falle.

Crazy Server.bat   Doble clic: abre el panel de control. La puerta de entrada.
LEEME PRIMERO.txt  Una hoja con lo mínimo para arrancar, para quien no lea esto.
credenciales.txt   Contraseñas y puertos, en texto plano y a propósito.
```

### Puertos

De cara a los jugadores: **8080** (juego), **5222** (chat), **9999/udp** (mundo abierto),
**9998/udp** (carreras), **5000** (web).
Solo del servidor: 3306 (base de datos), 9090 (administración del chat).

Los dos UDP son los importantes: sin ellos se entra al juego pero no se ve a nadie.

---

## Aviso

Esto es una LAN cerrada de evento, no un servidor de internet. Las contraseñas van en
texto plano y el juego usa cifrado antiguo. **Que nadie use una contraseña que use de
verdad en otro sitio.** Si algún día esto se expone fuera de la LAN, hay que cambiarlo
todo primero.

El cliente del juego es contenido original de EA, que cerró NFS World en 2015. La
comunidad lo preserva desde entonces. Aquí se usa en privado, entre amigos, y no se
descarga nada de fuera durante el evento.
