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

- lanzar_evento_nasa(tipo, intensidad, fecha, mensaje, dificultad, severidad)
- cancelar_evento_nasa()
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

## Eventos de la NASA (scripts/eventos_nasa.gd, autoload EventosNasa)
Claude toma un evento real de la tabla `eventos` de Supabase y lo lanza con
lanzar_evento_nasa. Los problemas y dificultades son copia de las tablas
`problemas`, `tipo_evento_problema` y `dificultades`.

| Tipo | Mecánica |
|------|----------|
| FLR  | Cuenta regresiva de 10 s y estallido de radiación: hay que protegerse. |
| CME  | Sacudida + ventilas/paneles dañados que hay que soldar antes del tiempo límite. |
| GST  | Fallas eléctricas (HUD y luces parpadean, soplete más débil) + reparaciones. |
| SEP  | Radiación sostenida: el oxígeno baja más rápido si no te proteges. |
| IPS  | Sacudida fuerte que empuja los objetos sueltos. |

La severidad (1 a 5) sale de la intensidad: clase de la fulguración (C/M/X),
índice Kp o velocidad de la CME. Un evento quita como máximo 50 % de oxígeno.

Para el nivel (opcional, desde el editor):
- Area3D en el grupo `refugio` = sala blindada. Si no hay ninguna, agacharse protege.
- Objeto en el grupo `escudo` = escudo portátil (protege mientras lo sostienes).
- Marker3D en el grupo `punto_dano` = lugares fijos para las reparaciones.
- Si no hay marcadores, se buscan lugares al azar entre 3 y 12 m del jugador que
  tengan suelo y no estén dentro de una estructura; se prefieren los cuartos (techo y
  paredes) y la pieza se pega a la pared o al suelo. Si no encuentra ninguno, aparece
  frente al jugador.
- Area3D en el grupo `zona_reparacion` = si existe alguna, las reparaciones solo
  aparecen dentro de esas zonas (útil para evitar cuartos cerrados sin entrada).
