# Openfire para el servidor LAN de NFS World

Servidor XMPP que da **chat y eventos in-game** a Need for Speed World.
Compilado desde el fork **SoapboxRaceWorld/openfire** (rama `master`, commit `028873a1`),
version base **Openfire 4.5.0-SNAPSHOT**.

Esta distribucion **ya viene configurada y probada**: no hay que pasar por el
asistente web de instalacion.

---

## 1. Por que el fork y no el Openfire oficial

El cliente de NFSW autentica con **XMPP Non-SASL (XEP-0078)**, un metodo obsoleto.
Para que caiga en el, el servidor tiene que **no anunciar ningun mecanismo SASL**.
Eso no se puede hacer con un plugin: el fork parchea el **nucleo**
(`SASLAuthentication.getSASLMechanisms`, `LocalClientSession`, `LocalSession`) para
devolver una lista vacia de mecanismos... salvo cuando el `from` del stream contiene
`.engine.engine`, que es el bot del core (libreria Smack) y si necesita SASL normal.

Ademas, Openfire 4.5.0 **eliminito del nucleo** el manejador XEP-0078, asi que hace
falta el plugin `nonSaslAuthentication` para reponerlo.

**Conclusion: el fork es imprescindible.** Un Openfire oficial no vale.

## 2. Puertos

| Puerto | Protocolo | Para que | Exponer en LAN |
|---|---|---|---|
| **5222** | TCP | XMPP cliente (el juego) | **SI** |
| 5223 | TCP | XMPP cliente sobre TLS antiguo | no |
| 7070 | TCP | BOSH / HTTP-bind | no |
| **9090** | TCP | Consola de administracion (HTTP) | solo local |
| 9091 | TCP | Consola de administracion (HTTPS) - **inactivo**, ver nota | solo local |

Solo **5222** tiene que estar abierto en el firewall para los jugadores.

> **Nota sobre 9091:** el almacen de certificados de la consola viene vacio, asi que
> Openfire arranca con la consola solo en **HTTP (9090)** y registra
> `Admin console: Identity store does not have any certificates. HTTPS will be unavailable.`
> No afecta a nada: la consola es de uso local y el cliente del juego no usa TLS
> (autentica en claro por XEP-0078). Si alguna vez quereis 9091, se generan los
> certificados con un clic en la consola: *Server > TLS/SSL Certificates > Generate Self-Signed Certificates*.

## 3. Que lleva instalado

`plugins\`:

| Plugin | Version | Para que |
|---|---|---|
| `restAPI.jar` | 1.4.0 (+ parches SBRW) | El core controla Openfire por REST (`OPENFIRE_TOKEN`) |
| `nonSaslAuthentication.jar` | 1.0.2 | Repone XEP-0078, que el cliente del juego necesita |
| `search.jar` | 1.7.2 | Viene de serie en la distribucion; inofensivo |
| `admin\` | — | Consola de administracion |

### Parches propios sobre restAPI 1.4.0

El plugin oficial **no trae** dos endpoints que `soapbox-race-core` usa. Se han
portado desde `SoapboxRaceWorld/openfire-restAPI-plugin` (commit `1cf1bcb`, escrito
para Openfire 4.7.4) a la API de 4.5.0:

- `GET  /plugins/restapi/v1/chatrooms/forUser?userName=&domain=&resource=`
  → salas MUC que ocupa un usuario. Lo usa `OpenFireRestApiCli.getAllPersonaByGroup`,
  que a su vez alimenta las **partidas privadas de grupo/crew** (`LobbyBO.createPrivateLobby`).
  Sin esto, las carreras privadas con el grupo fallan (las publicas no se ven afectadas).
- `POST /plugins/restapi/v1/messages/game` (body `text/plain`)
  → anuncio de sistema in-game. Lo usa `sendChatAnnouncement` (endpoint de admin).

Fuentes modificadas en `_build\openfire\sbrw-openfire\plugins\restAPI\`.

## 4. Configuracion actual (ya aplicada)

- **Base de datos:** HSQLDB **embebida**, en `embedded-db\`. Sin dependencias externas.
- **Asistente de instalacion:** desactivado (`<setup>true</setup>` en `conf\openfire.xml`).
- **Dominio XMPP:** `127.0.0.1`  ← **hay que cambiarlo**, ver seccion 5.
- **Consola de admin:** usuario `admin`, contrasena `admin`.
- **REST API:** activada, autenticacion por **secreto compartido**.
  - Token actual: **`nfsw-lan-openfire-token`**
  - Cabecera: `Authorization: <token>`
  - URL base: `http://127.0.0.1:9090/plugins/restapi/v1`

### Lo que hay que casar con la base de datos SOAPBOX (tabla `PARAMETER`)

| PARAMETER | Valor |
|---|---|
| `OPENFIRE_ADDRESS` | `http://127.0.0.1:9090/plugins/restapi/v1` |
| `OPENFIRE_TOKEN` | `nfsw-lan-openfire-token` (el mismo de arriba) |
| `XMPP_IP` | la IP LAN del servidor, **igual** que `<xmpp><domain>` |

`OPENFIRE_TOKEN` se usa **dos veces**: como secreto del REST y como **contrasena del
usuario XMPP `sbrw.engine.engine`** que el core crea al arrancar. Si lo cambias,
cambialo en los dos sitios (`plugin.restapi.secret` y el `PARAMETER`).

## 5. PENDIENTE / a automatizar en `start.ps1`

1. **El dominio XMPP tiene que ser la IP LAN del evento.** En `conf\openfire.xml`:
   ```xml
   <xmpp><domain>192.168.1.50</domain></xmpp>
   ```
   Debe coincidir **exactamente** con el `PARAMETER XMPP_IP`. Si la IP cambia de un
   evento a otro, `start.ps1` tiene que reescribir las dos cosas. Ahora mismo
   esta en `127.0.0.1`, que solo sirve para pruebas en la propia maquina.
2. **Orden de arranque:** Openfire **antes** que el core. El core, al arrancar, crea
   por REST el usuario `sbrw.engine.engine` y las salas de chat; si Openfire no
   responde todavia, esa inicializacion se pierde.
3. **Cambiar el token** por uno propio si no os vale el de fabrica.
4. **Firewall:** abrir TCP 5222.
5. **Contrasena de admin**: sigue siendo `admin/admin`. Cambiarla desde la consola
   si os molesta (en una LAN cerrada es asumible).

## 6. Como arrancarlo

```bat
REM Con la JRE portable del bundle (runtime\jre) o JAVA_HOME:
bin\openfire-portable.bat

REM Clasico, exige JAVA_HOME:
bin\openfire.bat
```

**Java 8 u 11.** Con Java 17 **no** funciona.

Comprobacion rapida:

```powershell
# la consola debe responder
curl.exe -s -o NUL -w "%{http_code}`n" http://127.0.0.1:9090/

# la REST API debe devolver XML de sesiones
curl.exe -H "Authorization: nfsw-lan-openfire-token" `
  http://127.0.0.1:9090/plugins/restapi/v1/system/statistics/sessions
```

## 7. Cambiar a MySQL

Si preferis el esquema `openfire` en MySQL (como decia el plan original) en vez de
la HSQLDB embebida, teneis la plantilla y los pasos en
`conf\openfire-mysql.xml.ejemplo`. Ojo: hay que **copiar el driver JDBC de MySQL a
`lib\`** (no viene incluido) y **volver a fijar las propiedades del plugin REST**,
porque viven en la base de datos.

Para una LAN party la HSQLDB embebida es mas simple y ya esta probada; MySQL solo
aporta si quereis un unico motor para todo.

## 8. Lo que se ha verificado de verdad

- Compilacion completa del fork + los 3 plugins con **JDK 11 + Maven 3.9.16**.
- Los metodos parcheados estan en el jar compilado (`isForceStandardSASL`,
  `getSASLMechanisms(LocalSession, XmlPullParser)`).
- Arranque en frio sin asistente y **sin errores** en `logs/error.log`; escuchan 5222, 5223, 7070 y 9090 (9091 no, ver nota de la seccion 2).
- Los **9 endpoints REST** que usa `soapbox-race-core` responden 200/201.
- Sin token, la REST API devuelve **401**.
- **Anuncio de mecanismos SASL** (la clave del fork):
  - stream con `from=sbrw.123@...` → **sin** `<mechanisms>`, con `<auth xmlns="http://jabber.org/features/iq-auth"/>`
  - stream con `from=sbrw.engine.engine@...` → **con** `<mechanisms>` (PLAIN, SCRAM-SHA-1, CRAM-MD5, DIGEST-MD5)
- **Login real Non-SASL (XEP-0078)** de un usuario `sbrw.123`:
  `<iq type="result" id="auth2" to="sbrw.123@127.0.0.1/EA-Chat"/>`

### Prueba de integracion real (no planificada, pero concluyente)

Durante la ultima verificacion, el **`core.jar` de SBRW que se estaba compilando en
paralelo se conecto solo** a este Openfire:

- Volvio a crear por REST el usuario `sbrw.engine.engine` (yo lo habia borrado al
  limpiar), lo que demuestra que su `OPENFIRE_TOKEN` es aceptado por la REST API.
- Inicio sesion XMPP con la libreria **Smack** (`<identity name="Smack"/>`), es decir,
  **por SASL estandar**, exactamente por la excepcion `.engine.engine` del parche.
- `system/statistics/sessions` paso a devolver `localSessions=1`.

O sea: el camino core → REST → Openfire → sesion XMPP funciona de verdad, no solo en
las pruebas sinteticas.

### Un error benigno en el log

Tras conectarse el core aparece **una** traza en `logs\error.log`:

```
org.jivesoftware.openfire.handler.IQHandler - Error interno en el servidor
java.lang.IllegalArgumentException: IQ must be of type 'set' or 'get'.
  Original IQ: <iq ... type="result" from="sbrw.engine.engine@.../EA_Chat">
               <query xmlns="http://jabber.org/protocol/disco#info"> ...
```

Es una rareza conocida de Openfire 4.5: `IQDiscoInfoHandler` intenta construir una
respuesta a partir de un `<iq type="result">` que Smack le envia. **Es ruido, no un
fallo**: la sesion sigue viva. No hay que hacer nada.

### Lo unico sin probar

El **cliente NFSW real** conectandose, porque hace falta el juego y la base
`SOAPBOX` con sus `PARAMETER` en marcha. Todo lo que hay por debajo (Non-SASL,
supresion de SASL, REST) si esta verificado.

## 9. Cambiar el token REST desde un script

Las propiedades del plugin REST viven **en la base de datos**, no en un fichero, asi
que `setup.ps1` / `start.ps1` no pueden cambiarlas con un simple reemplazo de texto.
Se incluye `bin\extra\OfProp.java` para hacerlo (Java 11 ejecuta el fuente directamente).
**Openfire tiene que estar parado.**

```powershell
$of  = "$PSScriptRoot\openfire"
$jre = "$PSScriptRoot\..\runtime\jre"   # o $env:JAVA_HOME
& "$jre\bin\java.exe" -cp "$of\lib\hsqldb-2.4.1.jar" "$of\bin\extra\OfProp.java" `
    "$of\embedded-db" `
    'plugin.restapi.enabled' 'true' `
    'plugin.restapi.httpAuth' 'secret' `
    'plugin.restapi.secret'  '<NUEVO_TOKEN>'
```

Acepta pares `clave valor` y hace `SHUTDOWN` de la base al terminar, de modo que
queda en un estado consistente. Recuerda actualizar tambien el `PARAMETER
OPENFIRE_TOKEN` de la base `SOAPBOX` con el mismo valor.

## 10. Donde esta el codigo fuente

Todo el arbol de compilacion queda en
`_build\openfire\` (fuera del bundle que se lleva a la LAN):

- `sbrw-openfire\` — fork clonado + los 2 cambios necesarios para compilar hoy:
  - `xmppserver/pom.xml`: las 3 dependencias con `<version>LATEST</version>`
    (jaxb-api, jaxb-runtime, activation) fijadas a 2.3.1 / 2.3.1 / 1.1.1, porque
    **Maven 3.9 elimino el soporte de `LATEST`** y el build fallaba de entrada.
  - `plugins/` y `distribution/`: se han anadido `restAPI` y `nonSaslAuthentication`
    como modulos del reactor para que salgan ya dentro de la distribucion.
- `sbrw-restapi\`, `sbrw-nonsasl\` — los forks de SBRW (referencia; apuntan a Openfire 4.7.4).
- `restapi-src\` — restAPI 1.4.0 tal cual sale del repo, antes de parchear.
- `build.log` — log completo de compilacion.

Comando exacto que funciona (Maven usa `JAVA_HOME`, y el del sistema apunta a JDK 17,
que **no** sirve):

```powershell
$env:JAVA_HOME='C:\Program Files\Eclipse Adoptium\jdk-11.0.32.9-hotspot'
cd '...\_build\openfire\sbrw-openfire'
& 'C:\Tools\apache-maven-3.9.16\bin\mvn.cmd' '-B' '-DskipTests' '-Denforcer.skip=true' 'package'
```

`-Denforcer.skip=true` es necesario porque la regla `enforce-no-snapshots` rechaza que
un plugin dependa del padre `4.5.0-SNAPSHOT`. El resultado queda en
`distribution\target\distribution-base\`.
