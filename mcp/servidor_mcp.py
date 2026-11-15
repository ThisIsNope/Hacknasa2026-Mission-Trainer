"""
Servidor MCP para Hacknasa 2026 - Mission Trainer.

Hace de puente entre un cliente MCP (por ejemplo Claude Desktop) y el juego:

    Claude  <-- MCP (stdio) -->  servidor_mcp.py  <-- WebSocket -->  Juego (Godot)

El juego se conecta solo a ws://localhost:9080 gracias al autoload
res://scripts/conexion_mcp.gd.

Instalar:  pip install "mcp[cli]" websockets      (Python 3.10 o superior)
"""
import asyncio
import itertools
import json
import sys

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
        "darle instrucciones al jugador en pantalla."
    ),
)

juegos: list = []                      # conexiones de juego (la última es la activa)
relays: set = set()                    # otras copias de este servidor conectadas a esta
relay_ws = None                        # si esta copia es secundaria: conexión a la principal
pendientes: dict[str, asyncio.Future] = {}
eventos: list[dict] = []
_ids = itertools.count(1)

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
    elif relay_ws is not None:
        destino, espera = relay_ws, TIEMPO_ESPERA + 1.0
    else:
        raise ToolError(
            "No hay ningún juego conectado. Abre el juego en Godot, o en el "
            "navegador agregando ?mcp=1 al final de la dirección."
        )
    id_ = str(next(_ids))
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
async def leer_eventos() -> str:
    """Devuelve lo que pasó en el juego desde la última lectura: paneles soldados,
    soplete sin combustible, oxígeno bajo u oxígeno agotado."""
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
    try:
        await mcp.run_stdio_async()
    finally:
        tarea.cancel()


if __name__ == "__main__":
    asyncio.run(main())
