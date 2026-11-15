# Servidor MCP de Mission Trainer

Puente entre Claude (u otro cliente MCP) y el juego:

    Claude  <-- MCP -->  servidor_mcp.py  <-- WebSocket (localhost:9080) -->  Juego

## Instalar
    pip install "mcp[cli]" websockets

## Conectar a Claude Desktop
Configuración -> Desarrollador -> Editar configuración, y agrega:

    {
      "mcpServers": {
        "mission-trainer": {
          "command": "python",
          "args": ["C:\\Users\\Xicotencatl\\OneDrive\\Documents\\GitHub\\Hacknasa2026-Mission-Trainer\\mcp\\servidor_mcp.py"]
        }
      }
    }

## Herramientas
- mostrar_mensaje(texto, color, segundos)
- obtener_estado()
- recargar_oxigeno(porcentaje)
- recargar_combustible(porcentaje)
- leer_eventos()   -> soldado, sin_combustible, oxigeno_bajo, oxigeno_agotado

- conectar_sala(codigo)  -> conecta con un juego abierto en otro dispositivo
- estado_conexion()

## Juego
- En el editor de Godot se conecta solo (a localhost).
- En la versión web, en la misma PC que Claude: agrega ?mcp=1 a la dirección:
  https://xicotencatl22.github.io/Hacknasa2026-Mission-Trainer-Web/?mcp=1
- Desde cualquier dispositivo (celular, otra PC): agrega ?sala=CODIGO, por ejemplo
  https://xicotencatl22.github.io/Hacknasa2026-Mission-Trainer-Web/?sala=nasa123
  y en Claude di "conéctate a la sala nasa123" (herramienta conectar_sala).
  El código puede ser cualquier palabra de 3 a 40 letras, números, - o _.
  Quien conozca el código puede controlar el juego, así que no uses uno obvio.

## Relay (conexión por internet)
El juego y este servidor se encuentran en un relay en la nube
(relay/servidor_relay.py en el repo Hacknasa2026-Mission-Trainer-Web, alojado en Render).
Si Render le da otra dirección al servicio, cámbiala en:
- scripts/conexion_mcp.gd  -> URL_RELAY
- este servidor            -> RELAY_POR_DEFECTO, o la variable de entorno MISSION_RELAY
  ("env": {"MISSION_RELAY": "wss://tu-servicio.onrender.com"} en la configuración de Claude)
Opcional: "env": {"MISSION_SALA": "nasa123"} conecta a esa sala al iniciar.

El plan gratuito de Render se duerme tras 15 minutos sin uso; la primera
conexión después de eso puede tardar hasta un minuto.
