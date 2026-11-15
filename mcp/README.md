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

## Juego
- En el editor de Godot se conecta solo.
- En la versión web, agrega ?mcp=1 a la dirección, por ejemplo:
  https://xicotencatl22.github.io/Hacknasa2026-Mission-Trainer-Web/?mcp=1
