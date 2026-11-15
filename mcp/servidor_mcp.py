"""
Servidor MCP para Hacknasa 2026 - Mission Trainer.

Hace de puente entre un cliente MCP (por ejemplo Claude Desktop) y el juego:

    Claude  <-- MCP (stdio) -->  servidor_mcp.py  <-- WebSocket -->  Juego (Godot)

El juego se conecta de una de dos formas (autoload res://scripts/conexion_mcp.gd):

- Local: a ws://localhost:9080 (en Godot, o en el navegador con ?mcp=1).
- Por internet, desde cualquier dispositivo: el juego y este servidor entran a
  la misma "sala" de un relay en la nube (relay/servidor_relay.py del repo web).
  En el navegador se abre con ?sala=CODIGO, y aquí se elige la sala con la
  herramienta conectar_sala o con la variable de entorno MISSION_SALA.

Variables de entorno opcionales:
    MISSION_SALA   código de sala al que conectarse al iniciar
    MISSION_RELAY  dirección del relay (por defecto RELAY_POR_DEFECTO)

Instalar:  pip install "mcp[cli]" websockets      (Python 3.10 o superior)
"""
import asyncio
import itertools
import json
import os
import re
import sys
from urllib.parse import quote

from websockets.asyncio.client import connect
from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed, InvalidHandshake

try:  # mcp 2.x
    from mcp.server.mcpserver import MCPServer
    from mcp.server.mcpserver.exceptions import ToolError
except ImportError:  # mcp 1.x
    from mcp.server.fastmcp import FastMCP as MCPServer
    from mcp.server.fastmcp.exceptions import ToolError

PUERTO = 9080
TIEMPO_ESPERA = 5.0  # segundos que esperamos la respuesta del juego
TIEMPO_ESPERA_NUBE = 8.0  # por internet damos un poco más de margen

RELAY_POR_DEFECTO = "wss://mission-trainer-relay.onrender.com"
RELAY = os.environ.get("MISSION_RELAY", RELAY_POR_DEFECTO).strip().rstrip("/")
SALA_VALIDA = re.compile(r"[A-Za-z0-9_-]{3,40}")

COLORES = {
    "blanco": "#ffffff",
    "verde": "#66ff80",
    "rojo": "#ff6650",
    "amarillo": "#ffd84d",
    "azul": "#66b3ff",
    "naranja": "#ff9933",
}

mcp = MCPServer(
    "mission-trainer",
    instructions=(
        "Controla el simulador de entrenamiento espacial Mission Trainer. "
        "El jugador es un astronauta que tiene oxígeno limitado y repara paneles "
        "con un soplete que gasta combustible. Usa obtener_estado para ver cómo va "
        "la misión, leer_eventos para saber qué pasó, y mostrar_mensaje para "
        "darle instrucciones al jugador en pantalla. Si el jugador abrió el juego "
        "en otro dispositivo con ?sala=CODIGO, usa conectar_sala con ese código. "
        "Con lanzar_evento_nasa provocas en el juego un evento real de clima espacial "
        "de la NASA (DONKI); si tienes acceso a la base de datos de Supabase, toma el "
        "evento de la tabla eventos (y su texto de mensajes_ia)."
    ),
)

juegos: list = []                      # conexiones de juego (la última es la activa)
relays: set = set()                    # otras copias de este servidor conectadas a esta
relay_ws = None                        # si esta copia es secundaria: conexión a la principal
pendientes: dict[str, asyncio.Future] = {}
eventos: list[dict] = []
_ids = itertools.count(1)
_prefijo_id = f"{os.getpid()}-"        # ids únicos aunque haya varias copias en la misma sala

# Conexión por internet (relay en la nube)
sala_actual = ""                       # código de sala ("" = sin sala)
nube_ws = None                         # conexión abierta con el relay
nube_juego = False                     # ¿hay un juego en la sala?
nube_error = ""                        # último problema al conectar con el relay
_tarea_nube: asyncio.Task | None = None
# La sala se guarda en un archivo para que todas las copias de este servidor
# (Claude puede abrir varias) usen la misma sin tener que repetir conectar_sala.
ARCHIVO_SALA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sala_actual.txt")

# Claude Desktop puede iniciar varias copias de este servidor. Solo una puede
# abrir el puerto: esa es la "principal" y es a la que se conecta el juego.
# Las demás se conectan a la principal en /relay y le pasan sus comandos.


def log(*args) -> None:
    # stdout está reservado para MCP: todo lo demás va a stderr.
    print(*args, file=sys.stderr, flush=True)


def procesar(raw) -> dict | None:
    """Respuestas -> resuelven el comando pendiente; eventos -> se guardan."""
    try:
        datos = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(datos, dict):
        return None
    if "id" in datos:
        fut = pendientes.pop(str(datos["id"]), None)
        if fut and not fut.done():
            fut.set_result(datos)
    elif datos.get("tipo") == "evento":
        eventos.append(datos)
        del eventos[:-100]  # guarda solo los últimos 100
    return datos


async def manejar_conexion(ws) -> None:
    if ws.request.path.startswith("/relay"):
        await atender_relay(ws)
    else:
        await manejar_juego(ws)


async def manejar_juego(ws) -> None:
    juegos.append(ws)
    log("Juego conectado")
    try:
        async for raw in ws:
            datos = procesar(raw)
            if datos and datos.get("tipo") == "evento":
                for r in list(relays):  # las otras copias también se enteran
                    try:
                        await r.send(raw)
                    except Exception:
                        relays.discard(r)
    except ConnectionClosed:
        pass  # el juego se cerró sin despedirse (normal al cerrar la pestaña)
    finally:
        if ws in juegos:
            juegos.remove(ws)
        log("Juego desconectado")


async def atender_relay(ws) -> None:
    relays.add(ws)
    try:
        async for raw in ws:
            try:
                datos = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if isinstance(datos, dict) and "id" in datos:
                asyncio.create_task(reenviar(ws, datos))
    except ConnectionClosed:
        pass
    finally:
        relays.discard(ws)


async def reenviar(ws, datos: dict) -> None:
    """Ejecuta en el juego un comando que llegó de otra copia y le devuelve el resultado."""
    try:
        args = datos.get("args") if isinstance(datos.get("args"), dict) else {}
        res = {"id": datos["id"], "ok": True, "datos": await pedir(str(datos.get("cmd")), **args)}
    except ToolError as e:
        res = {"id": datos["id"], "ok": False, "error": str(e)}
    try:
        await ws.send(json.dumps(res, ensure_ascii=False))
    except ConnectionClosed:
        pass


async def ser_secundaria() -> None:
    """Se conecta a la copia principal y espera ahí hasta que se cierre."""
    global relay_ws
    async with connect(f"ws://localhost:{PUERTO}/relay") as ws:
        relay_ws = ws
        log("Conectado a la copia principal del servidor")
        try:
            async for raw in ws:
                procesar(raw)
        except ConnectionClosed:
            pass
        finally:
            relay_ws = None


async def pedir(cmd: str, **args):
    """Manda un comando al juego (directo o a través de la copia principal)."""
    if juegos:
        destino, espera = juegos[-1], TIEMPO_ESPERA
    elif nube_ws is not None and nube_juego:
        destino, espera = nube_ws, TIEMPO_ESPERA_NUBE
    elif relay_ws is not None:
        destino, espera = relay_ws, TIEMPO_ESPERA_NUBE + 1.0
    else:
        raise ToolError(sin_juego())
    id_ = _prefijo_id + str(next(_ids))
    fut = asyncio.get_running_loop().create_future()
    pendientes[id_] = fut
    try:
        await destino.send(json.dumps({"id": id_, "cmd": cmd, "args": args}, ensure_ascii=False))
        respuesta = await asyncio.wait_for(fut, espera)
    except asyncio.TimeoutError:
        raise ToolError(
            "El juego no respondió a tiempo. Si está en el navegador, revisa "
            "que su pestaña esté visible (en segundo plano se congela)."
        )
    except ConnectionClosed:
        raise ToolError("Se perdió la conexión con el juego. Inténtalo de nuevo.")
    finally:
        pendientes.pop(id_, None)
    if not respuesta.get("ok"):
        raise ToolError(respuesta.get("error", "Error desconocido en el juego"))
    return respuesta.get("datos")


def sin_juego() -> str:
    """Mensaje de error cuando no hay ningún juego al que mandar comandos."""
    if not sala_actual:
        return (
            "No hay ningún juego conectado. Abre el juego en Godot, o en el "
            "navegador agregando ?mcp=1 al final de la dirección (misma PC). "
            "Si está en otro dispositivo, ábrelo con ?sala=CODIGO y usa "
            "conectar_sala con ese código."
        )
    if nube_ws is None:
        detalle = f" ({nube_error})" if nube_error else ""
        return (
            f"Todavía no hay conexión con el relay para la sala '{sala_actual}'{detalle}. "
            "Si es la primera conexión en un rato, el servidor gratuito puede tardar "
            "hasta un minuto en despertar; inténtalo de nuevo en unos segundos."
        )
    return (
        f"Conectado a la sala '{sala_actual}', pero no hay ningún juego en ella. "
        f"Abre el juego agregando ?sala={sala_actual} al final de la dirección, "
        "y deja su pestaña visible."
    )


async def mantener_nube(codigo: str) -> None:
    """Mantiene la conexión con el relay en la sala indicada, reconectando si se cae."""
    global nube_ws, nube_juego, nube_error
    url = f"{RELAY}/mcp?sala={quote(codigo)}"
    espera = 1.0
    while True:
        try:
            # open_timeout largo: el plan gratuito de Render tarda en despertar.
            async with connect(url, open_timeout=90, max_size=2**20) as ws:
                nube_ws, nube_error, espera = ws, "", 1.0
                log(f"Conectado al relay, sala {codigo}")
                async for raw in ws:
                    datos = procesar(raw)
                    if datos and datos.get("tipo") == "sistema":
                        nube_juego = bool(datos.get("juego_conectado"))
                        log("Juego en la sala:", nube_juego)
        except asyncio.CancelledError:
            raise
        except Exception as e:  # sin internet, relay dormido, sala inválida...
            nube_error = str(e) or type(e).__name__
            log("Relay:", nube_error)
        finally:
            nube_ws, nube_juego = None, False
        await asyncio.sleep(espera)
        espera = min(espera * 2.0, 30.0)


def leer_sala_guardada() -> str:
    try:
        with open(ARCHIVO_SALA, encoding="utf-8") as f:
            codigo = f.read().strip()
    except OSError:
        return ""
    return codigo if SALA_VALIDA.fullmatch(codigo) else ""


def guardar_sala(codigo: str) -> None:
    try:
        with open(ARCHIVO_SALA, "w", encoding="utf-8") as f:
            f.write(codigo)
    except OSError as e:
        log("No se pudo guardar la sala:", e)


async def seguir_sala_guardada() -> None:
    """Si otra copia cambia la sala, esta copia también se cambia."""
    while True:
        await asyncio.sleep(2)
        codigo = leer_sala_guardada()
        if codigo != sala_actual:
            cambiar_sala(codigo)


def cambiar_sala(codigo: str) -> None:
    global sala_actual, nube_error, _tarea_nube
    if _tarea_nube is not None:
        _tarea_nube.cancel()
        _tarea_nube = None
    sala_actual, nube_error = codigo, ""
    if codigo:
        _tarea_nube = asyncio.create_task(mantener_nube(codigo))


@mcp.tool()
async def conectar_sala(codigo: str) -> str:
    """Conecta con un juego abierto en otro dispositivo (celular, otra PC) por internet.

    El jugador abre el juego con ?sala=CODIGO al final de la dirección y aquí se
    usa el mismo código (3 a 40 letras, números, - o _). Usa un código vacío ("")
    para desconectarse de la sala.
    """
    codigo = codigo.strip()
    if codigo and not SALA_VALIDA.fullmatch(codigo):
        raise ToolError("Código de sala inválido: usa de 3 a 40 letras, números, - o _.")
    cambiar_sala(codigo)
    guardar_sala(codigo)
    if not codigo:
        return "Desconectado de la sala."
    # Esperamos un poco a que se conecte para dar una respuesta útil.
    for _ in range(40):  # hasta ~20 s
        if nube_ws is not None and nube_juego:
            return f"Conectado a la sala '{codigo}' y el juego está en línea."
        await asyncio.sleep(0.5)
    if nube_ws is not None:
        return (
            f"Conectado a la sala '{codigo}'. Todavía no hay juego en ella: ábrelo "
            f"con ?sala={codigo} al final de la dirección."
        )
    return (
        f"Conectando a la sala '{codigo}'… el relay aún no responde (el servidor "
        "gratuito puede tardar hasta un minuto en despertar). Sigo intentando en "
        "segundo plano."
    )


@mcp.tool()
async def estado_conexion() -> str:
    """Dice cómo está conectado el juego: localmente, por una sala en internet, o nada."""
    partes = [f"Juego local (localhost:{PUERTO}): {'conectado' if juegos else 'no'}"]
    if sala_actual:
        if nube_ws is None:
            relay = "conectando" + (f" ({nube_error})" if nube_error else "")
        else:
            relay = "conectado, juego " + ("en línea" if nube_juego else "sin conectar")
        partes.append(f"Sala '{sala_actual}' en {RELAY}: {relay}")
    else:
        partes.append("Sala en internet: ninguna (usa conectar_sala)")
    return "\n".join(partes)


@mcp.tool()
async def mostrar_mensaje(texto: str, color: str = "blanco", segundos: float = 3.0) -> str:
    """Muestra un mensaje grande arriba al centro de la pantalla del jugador.

    color: blanco, verde, rojo, amarillo, azul, naranja, o un código como #ff8800.
    segundos: cuánto tiempo se queda visible antes de desvanecerse.
    """
    codigo = COLORES.get(color.lower().strip(), color)
    await pedir("mensaje", texto=texto, color=codigo, segundos=segundos)
    return f"Mensaje mostrado: {texto}"


@mcp.tool()
async def obtener_estado() -> str:
    """Devuelve el estado actual de la misión: oxígeno, combustible del soplete,
    progreso de cada panel por soldar y posición del jugador."""
    datos = await pedir("estado")
    return json.dumps(datos, ensure_ascii=False, indent=2)


@mcp.tool()
async def recargar_oxigeno(porcentaje: float = 100.0) -> str:
    """Agrega oxígeno al tanque del jugador (porcentaje del tanque, 0 a 100)."""
    datos = await pedir("recargar_oxigeno", porcentaje=porcentaje)
    return f"Oxígeno ahora: {datos['oxigeno_pct']}%"


@mcp.tool()
async def recargar_combustible(porcentaje: float = 100.0) -> str:
    """Agrega combustible al soplete (porcentaje del tanque, 0 a 100)."""
    datos = await pedir("recargar_combustible", porcentaje=porcentaje)
    return f"Combustible ahora: {datos['combustible_pct']}%"


@mcp.tool()
async def lanzar_evento_nasa(
    tipo: str,
    intensidad: str = "",
    fecha: str = "",
    mensaje: str = "",
    dificultad: str = "Normal",
    severidad: int = 0,
    evento_id: int = 0,
) -> str:
    """Lanza en el juego un evento de clima espacial de la NASA (DONKI) con su mecánica.

    tipo:
      FLR fulguración solar: cuenta regresiva de 10 s y estallido de radiación; el jugador
          debe protegerse (sala blindada, escudo, o agacharse si no hay sala).
      CME eyección de masa coronal: sacudida y aparecen ventilas/paneles dañados que hay
          que soldar antes del tiempo límite.
      GST tormenta geomagnética: fallas eléctricas (HUD y luces parpadean, soplete más
          débil) más reparaciones.
      SEP partículas solares: radiación sostenida que gasta oxígeno si no se protege.
      IPS choque interplanetario: sacudida fuerte que empuja objetos sueltos.
    intensidad: tal como viene en la tabla eventos de Supabase ("M2.5", "Kp 7", "624 km/s").
    fecha: fecha real del evento (inicio en la tabla eventos), se muestra en pantalla.
    mensaje: alerta corta para el jugador (mensajes_ia.mensaje si existe), sin emojis.
    dificultad: Fácil, Normal, Difícil o Extremo (tabla dificultades: tiempo límite,
                multiplicador de daño y número de problemas).
    severidad: 1 a 5 para forzarla; 0 = calcularla con la intensidad.
    evento_id: id del evento en la tabla eventos de Supabase (0 si no viene de ahí);
               se guarda con el resultado para el ranking.
    """
    datos = await pedir(
        "evento_nasa", tipo=tipo, intensidad=intensidad, fecha=fecha,
        mensaje=mensaje, dificultad=dificultad, severidad=severidad, evento_id=evento_id,
    )
    return json.dumps(datos, ensure_ascii=False, indent=2)


@mcp.tool()
async def cancelar_evento_nasa() -> str:
    """Cancela el evento de la NASA que esté en curso y quita sus efectos."""
    await pedir("cancelar_evento")
    return "Evento cancelado."


@mcp.tool()
async def leer_eventos() -> str:
    """Devuelve lo que pasó en el juego desde la última lectura: paneles soldados,
    soplete sin combustible, oxígeno bajo u oxígeno agotado, y el inicio y fin de los
    eventos de la NASA (evento_nasa_inicio / evento_nasa_fin, con su resultado)."""
    if not eventos:
        return "No hay eventos nuevos."
    texto = json.dumps(eventos, ensure_ascii=False, indent=2)
    eventos.clear()
    return texto


async def mantener_websocket() -> None:
    """Intenta ser la copia principal; si el puerto ya está tomado por otra
    copia, se conecta a ella como secundaria. Si la principal se cierra, vuelve
    a intentar ser la principal."""
    while True:
        try:
            async with serve(manejar_conexion, "localhost", PUERTO):
                log(f"Esperando al juego en ws://localhost:{PUERTO}")
                await asyncio.Future()  # corre para siempre
        except OSError:
            pass  # puerto ocupado: otra copia es la principal
        try:
            await ser_secundaria()
        except (OSError, InvalidHandshake, ConnectionClosed):
            pass
        await asyncio.sleep(2)


async def main() -> None:
    tarea = asyncio.create_task(mantener_websocket())
    sala_inicial = os.environ.get("MISSION_SALA", "").strip()
    if SALA_VALIDA.fullmatch(sala_inicial):
        guardar_sala(sala_inicial)
    cambiar_sala(leer_sala_guardada())
    seguidor = asyncio.create_task(seguir_sala_guardada())
    try:
        await mcp.run_stdio_async()
    finally:
        tarea.cancel()
        seguidor.cancel()
        cambiar_sala("")


if __name__ == "__main__":
    asyncio.run(main())
