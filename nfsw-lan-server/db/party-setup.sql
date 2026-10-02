-- =====================================================================
--  NFSW LAN Server - party-setup.sql
--  Fase 8: convertir el servidor en un servidor de LAN party.
--
--  QUE HACE: abre todo el contenido que la base de datos de la comunidad
--  trae bloqueado por defecto, y quita las fricciones de progresion.
--  Sin esto se juega, pero con la mitad de los circuitos y con los coches
--  atados a su clase.
--
--  IDEMPOTENTE: se puede ejecutar tantas veces como haga falta.
--
--  !! DESPUES DE EJECUTARLO HAY QUE REINICIAR EL CORE !!
--     El servidor cachea las entidades (Hibernate, cache de segundo nivel
--     sin invalidacion) y no vera estos cambios hasta reiniciarse.
--     Recargar parametros por la API NO basta: eso solo afecta a la
--     tabla `parameter`.
--
--  Uso:  mysql -u root SOAPBOX < party-setup.sql
-- =====================================================================

USE SOAPBOX;

-- ---------------------------------------------------------------------
-- 0. PREVUELO - comprobar que la estructura es la esperada.
--    Si algo aqui sale vacio, PARA y revisa antes de seguir.
-- ---------------------------------------------------------------------
SELECT '=== PREVUELO ===' AS paso;

SELECT COLUMN_NAME AS columnas_de_parameter
  FROM INFORMATION_SCHEMA.COLUMNS
 WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'parameter';

SELECT COUNT(*)                 AS eventos_totales,
       SUM(isEnabled = b'1')    AS activos_ahora,
       SUM(isEnabled = b'0')    AS apagados_a_activar
  FROM event;

SELECT COUNT(*)                 AS productos_totales,
       SUM(enabled = b'1')      AS activos_ahora,
       SUM(enabled = b'0')      AS apagados_a_activar
  FROM product;


-- ---------------------------------------------------------------------
-- 1. EVENTOS - abrir el mapa entero
--
--    La base de datos de la comunidad trae 84 de 165 eventos apagados
--    (Camden Tunnel, Waterfront, Heritage Heights, Bristol & Diamond...)
--    y 98 atados a una unica clase de coche. Esto lo abre todo.
--
--    carClassHash 607077938 = "clase libre": cualquier coche vale.
--    Sin esto el servidor rechaza la carrera con CarDataInvalid.
--
--    lobbyCountdownTime: NO bajar de 12000. El servidor rechaza a quien
--    acepta la invitacion con menos de 6 segundos restantes.
--
--    maxPlayers = 6 es el valor de fabrica y el probado. El techo real
--    del protocolo es 7 (el hueco de parrilla son 3 bits y el campo que
--    lleva el numero de jugadores no llega a 8). Probar 7 en la Fase 6;
--    si falla, quedarse en 6.
-- ---------------------------------------------------------------------
SELECT '=== 1. EVENTOS ===' AS paso;

UPDATE event
   SET isEnabled          = b'1',
       isLocked           = b'0',
       carClassHash       = 607077938,
       minLevel           = 0,
       maxLevel           = 2137,
       lobbyCountdownTime = 20000,
       dnfTimerTime       = 30000
 WHERE id <> 48;   -- 48 = tutorial del Barrio Viejo: se deja como esta
                   --      (minLevel=maxLevel=1, invisible a nivel 60)

-- Aforo por modo. Se separa del UPDATE anterior para poder ajustarlo
-- solo aqui tras las pruebas de la Fase 6.
UPDATE event SET maxPlayers = 6 WHERE eventModeId IN (4, 9, 12) AND id <> 48;  -- circuito, sprint, persecucion
UPDATE event SET maxPlayers = 6 WHERE eventModeId IN (19, 24);                 -- drag y Team Escape (venian a 4)
UPDATE event SET maxPlayers = 8 WHERE eventModeId = 22;                        -- punto de encuentro


-- ---------------------------------------------------------------------
-- 2. CATALOGO - desbloquear todo lo comprable
--
--    1066 de 3712 productos vienen desactivados (579 skill mods,
--    313 piezas de rendimiento, 106 packs, 58 visuales, 8 coches,
--    y hasta 2 potenciadores: iman de trafico y escudo).
--
--    minLevel gobierna la visibilidad en la tienda; premium reserva
--    productos a cuentas de pago. Se abren los tres.
--    (La columna `level` es otra cosa: solo afecta a los premios
--     aleatorios de fin de carrera. No se toca.)
-- ---------------------------------------------------------------------
SELECT '=== 2. CATALOGO ===' AS paso;

UPDATE product       SET enabled = b'1', minLevel = 0, premium = b'0';
UPDATE vinylproduct  SET enabled = b'1', minLevel = 0, premium = b'0';

-- Coches de inicio gratis: todo piloto nuevo debe comprarse uno antes de
-- poder conducir. A 0 el arranque es un clic en vez de una decision.
UPDATE product
   SET price = 0
 WHERE productType = 'PRESETCAR'
   AND categoryName = 'Starting_Cars';


-- ---------------------------------------------------------------------
-- 3. CANAL UNICO - que los 50 se vean entre si
--
--    Por defecto hay 2 canales de chat, y el servidor de freeroam
--    prioriza a los jugadores del mismo canal al repartir los huecos
--    de visibilidad. Con 2 canales, medio grupo deja de verse.
--    Un solo canal = todos en el mismo mundo social.
-- ---------------------------------------------------------------------
SELECT '=== 3. CANAL UNICO ===' AS paso;

UPDATE chat_room SET amount = 1;


-- ---------------------------------------------------------------------
-- 4. PARAMETROS DE FIESTA
--
--    Las columnas son (`name`, `value`) - CONFIRMADO contra el volcado real
--    de la comunidad el 2026-08-23. El prevuelo del paso 0 las vuelve a
--    imprimir en cada ejecucion por si cambian entre versiones del esquema.
--    El patron INSERT ... ON DUPLICATE KEY UPDATE hace que sea idempotente
--    y que valga tanto si la fila existe como si no.
--
--    NO BORRAR NUNCA estas filas (el servidor revienta al arrancar si
--    faltan, porque las lee sin valor por defecto):
--      SERVER_INFO_TIMEZONE, STARTING_CASH_AMOUNT, STARTING_LEVEL_NUMBER,
--      TH_CASH_MULTIPLIER, TH_REP_MULTIPLIER, UDP_FREEROAM_PORT,
--      UDP_RACE_PORT, XMPP_PORT, y las 18 filas PURSUIT_*.
-- ---------------------------------------------------------------------
SELECT '=== 4. PARAMETROS ===' AS paso;

INSERT INTO parameter (name, value) VALUES
    -- Sin dano: el coche no pierde rendimiento carrera tras carrera.
    -- (Con dano activo, a durabilidad 0 el coche pierde TODAS las
    --  prestaciones de sus piezas. En una fiesta eso es veneno.)
    ('ENABLE_CAR_DAMAGE',       'false'),

    -- Potenciadores infinitos: no se consumen al usarlos.
    ('ENABLE_POWERUP_DECREASE', 'false'),

    -- Sin tope de jugadores conectados (-1 = ilimitado).
    -- Si esta fila existe con un numero, al llegar al tope se rechazan
    -- los logins con un error criptico. Vale mas dejarlo explicito.
    ('MAX_ONLINE_PLAYERS',      '-1'),

    -- Dinero de salida. La DB de la comunidad ya trae 350000; se sube
    -- para que nadie se quede mirando el escaparate.
    ('STARTING_CASH_AMOUNT',    '5000000'),

    -- Nivel de salida. 60 es el maximo: se nace a tope y no hay grind.
    -- Si preferis que se note progresion durante la fiesta, poner 50
    -- aqui y subir REP_REWARD_MULTIPLIER: a nivel maximo el juego deja
    -- de dar reputacion y la pantalla de fin de carrera se queda sosa.
    ('STARTING_LEVEL_NUMBER',   '60'),

    -- Multiplicadores de recompensa (por defecto 1.0 si no existen).
    ('CASH_REWARD_MULTIPLIER',  '10.0'),
    ('REP_REWARD_MULTIPLIER',   '10.0'),

    -- Sesion de 24 h: que a nadie le caduque la sesion a mitad de evento.
    ('SESSION_LENGTH_MINUTES',  '1440')

ON DUPLICATE KEY UPDATE value = VALUES(value);


-- ---------------------------------------------------------------------
-- 4bis. LOS DOS POTENCIADORES QUE FALTABAN
--
--    El paso 2 activa los 3712 productos, incluidos el iman de trafico
--    (SRV-POWERUP1) y el escudo (SRV-POWERUP3), que venian apagados.
--    Pero activarlos en la tienda NO basta: el inventario con el que nace
--    cada piloto se define aparte, en STARTING_INVENTORY_ITEMS, y la lista
--    de la comunidad no los incluye. Sin esto, los jugadores tienen 10 de
--    los 12 potenciadores y nadie entiende por que.
--
--    El iman de trafico (le tiras un coche de trafico al que va delante) es
--    el mas divertido del juego en una sala llena de gente. Merece la pena
--    solo por eso.
--
--    Con ENABLE_POWERUP_DECREASE = false el "15" es simbolico: no se gastan.
-- ---------------------------------------------------------------------
SELECT '=== 4bis. POTENCIADORES COMPLETOS ===' AS paso;

UPDATE parameter
   SET value = CONCAT(value, ';SRV-POWERUP1|15;SRV-POWERUP3|15')
 WHERE name = 'STARTING_INVENTORY_ITEMS'
   AND value NOT LIKE '%SRV-POWERUP1|%';


-- ---------------------------------------------------------------------
-- 5. MONEDA PREMIUM (SpeedBoost)
--
--    El servidor NO tiene parametro para la moneda premium inicial:
--    la crea siempre a 0 y la escribe explicitamente, asi que un DEFAULT
--    en la columna no serviria de nada. Un trigger si.
--
--    Solo 46 productos se pagan con esta moneda (huecos de garaje,
--    amplificadores), asi que con 100.000 sobra de largo.
-- ---------------------------------------------------------------------
SELECT '=== 5. MONEDA PREMIUM ===' AS paso;

DROP TRIGGER IF EXISTS persona_party_boost;
CREATE TRIGGER persona_party_boost
BEFORE INSERT ON persona
FOR EACH ROW
    SET NEW.boost = 100000;


-- ---------------------------------------------------------------------
-- 4ter. DECORADO Y BIENVENIDA
--
--    El cliente lleva dentro cuatro decorados de temporada (luces y adornos
--    por toda la ciudad). El core solo reconoce estos nombres (SceneryUtil):
--    SCENERY_GROUP_NORMAL, _OKTOBERFEST, _HALLOWEEN, _CHRISTMAS, _NEWYEARS.
--    El "SCENERY_GROUP_NORMAL_DISABLE" que traia la base de la comunidad no
--    existe y se ignoraba en silencio. Para cambiarlo en caliente durante la
--    fiesta: scripts\decorado.ps1 -Navidad (o -Halloween, -Normal...).
--
--    SERVER_INFO_MESSAGE es el texto que el launcher ensena junto al servidor.
-- ---------------------------------------------------------------------
UPDATE parameter SET value = 'SCENERY_GROUP_HALLOWEEN' WHERE name = 'SERVER_INFO_ENABLED_SCENERY';
UPDATE parameter SET value = 'SCENERY_GROUP_NORMAL'    WHERE name = 'SERVER_INFO_DISABLED_SCENERY';
INSERT INTO parameter (name, value)
  VALUES ('SERVER_INFO_MESSAGE', 'Bienvenido a Crazy Server. Registro y descargas en la web de la LAN. Sin dano, potenciadores infinitos y todo el mapa abierto: a correr.')
  ON DUPLICATE KEY UPDATE value = VALUES(value);

-- ---------------------------------------------------------------------
-- 5bis. ADMINISTRADORES
--
--    Con isAdmin, el juego acepta comandos escritos en el dialogo de
--    DENUNCIAR jugador: se escribe "/comando" en la descripcion y el core
--    lo ejecuta contra el jugador denunciado (Social.petition -> AdminBO).
--    Un administrador puede expulsar y banear desde dentro del juego.
--
--    Va aqui, y no solo como UPDATE suelto, para que sobreviva a reset.ps1
--    y a cualquier rehecho de la base de datos. Idempotente: si la cuenta
--    no existe todavia, no hace nada y no falla.
--
--    Para anadir a otro organizador, se copia la linea con su correo.
-- ---------------------------------------------------------------------
UPDATE user SET isAdmin = b'1' WHERE email = 'danteiscrazy@crazy.party';
-- UPDATE user SET isAdmin = b'1' WHERE email = 'colega@crazy.party';

-- ---------------------------------------------------------------------
-- 6. RESUMEN
-- ---------------------------------------------------------------------
SELECT '=== RESULTADO ===' AS paso;

SELECT email AS administradores FROM user WHERE isAdmin = b'1';

SELECT COUNT(*)                            AS eventos_jugables,
       SUM(carClassHash = 607077938)       AS de_clase_libre
  FROM event WHERE isEnabled = b'1';

SELECT COUNT(*) AS productos_disponibles FROM product WHERE enabled = b'1';

SELECT COUNT(*) AS coches_comprables
  FROM product WHERE enabled = b'1' AND productType = 'PRESETCAR';

SELECT amount AS canales_de_chat FROM chat_room;

SELECT '>>> RECUERDA REINICIAR EL CORE PARA QUE ESTO SURTA EFECTO <<<' AS aviso;
