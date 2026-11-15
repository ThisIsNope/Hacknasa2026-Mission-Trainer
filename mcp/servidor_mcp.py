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

from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed

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

juegos: list = []                      # conexiones abiertas (la última es la activa)
pendientes: dict[str, asyncio.Future] = {}
eventos: list[dict] = []
_ids = itertools.count(1)
escuchando = False                     # True si esta copia tiene el puerto


def log(*args) -> None:
    # stdout está reservado para MCP: todo lo demás va a stderr.
    print(*args, file=sys.stderr, flush=True)


async def manejar_juego(ws) -> None:
    juegos.append(ws)
    log("Juego conectado")
    try:
        async for raw in ws:
            try:
                datos = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if not isinstance(datos, dict):
                continue
            if "id" in datos:  # respuesta a un comando
                fut = pendientes.pop(str(datos["id"]), None)
                if fut and not fut.done():
                    fut.set_result(datos)
            elif datos.get("tipo") == "evento":
                eventos.append(datos)
                del eventos[:-100]  # guarda solo los últimos 100
    except ConnectionClosed:
        pass  # el juego se cerró sin despedirse (normal al cerrar la pestaña)
    finally:
        if ws in juegos:
            juegos.remove(ws)
        log("Juego desconectado")


async def pedir(cmd: str, **args):
    """Manda un comando al juego y espera su respuesta."""
    if not juegos and not escuchando:
        raise ToolError(
            f"Otra copia de este servidor está usando el puerto {PUERTO}, así que el "
            "juego está conectado a ella. Usa el juego desde el mismo tipo de chat "
            "(o cierra la otra copia) e inténtalo de nuevo."
        )
    if not juegos:
        raise ToolError(
            "No hay ningún juego conectado. Abre el juego en Godot, o en el "
            "navegador agregando ?mcp=1 al final de la dirección."
        )
    ws = juegos[-1]
    id_ = str(next(_ids))
    fut = asyncio.get_running_loop().create_future()
    pendientes[id_] = fut
    try:
        await ws.send(json.dumps({"id": id_, "cmd": cmd, "args": args}, ensure_ascii=False))
        respuesta = await asyncio.wait_for(fut, TIEMPO_ESPERA)
    except asyncio.TimeoutError:
        raise ToolError(
            "El juego no respondió a tiempo. Si está en el navegador, revisa "
            "que su pestaña esté visible (en segundo plano se congela)."
        )
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
    """Abre el puerto para el juego. Si otra copia del servidor ya lo tiene
    (Claude Desktop a veces inicia más de una), sigue funcionando y reintenta."""
    global escuchando
    avisado = False
    while True:
        try:
            async with serve(manejar_juego, "localhost", PUERTO):
                escuchando = True
                log(f"Esperando al juego en ws://localhost:{PUERTO}")
                await asyncio.Future()  # corre para siempre
        except OSError:
            escuchando = False
            if not avisado:
                log(f"El puerto {PUERTO} está ocupado (¿otra copia del servidor?). Reintentando...")
                avisado = True
            await asyncio.sleep(5)


async def main() -> None:
    tarea = asyncio.create_task(mantener_websocket())
    try:
        await mcp.run_stdio_async()
    finally:
        tarea.cancel()


if __name__ == "__main__":
    asyncio.run(main())
