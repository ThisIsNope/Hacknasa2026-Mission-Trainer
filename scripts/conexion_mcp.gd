extends Node
## Conecta el juego con el servidor MCP (mcp/servidor_mcp.py) por WebSocket.
## Está registrado como Autoload con el nombre "ConexionMCP".
##
## - En el editor o en la versión de escritorio se conecta siempre a localhost.
## - En la versión web:
##     ?mcp=1          -> se conecta al servidor MCP de esta misma PC (localhost).
##     ?sala=CODIGO    -> se conecta por internet al relay, en esa sala. Así
##                        funciona desde cualquier dispositivo (celular, otra PC);
##                        en Claude se usa conectar_sala con el mismo código.
##     (ninguno)       -> no se conecta, para que los jugadores normales no lo intenten.
## - En escritorio también se puede pasar una sala:  -- --sala=CODIGO

const URL_LOCAL := "ws://localhost:9080"
const URL_RELAY := "wss://mission-trainer-relay.onrender.com"   # relay/servidor_relay.py en Render
const OXIGENO_MAX := 125.0        # mismo valor inicial que Global.oxigen
const OXIGENO_BAJO_PCT := 25.0

var URL := URL_LOCAL              # se decide en _ready()
var _sala := ""
var _socket := WebSocketPeer.new()
var _conectado := false
var _espera := 1.0                # segundos entre reintentos (crece hasta 10)
var _reintento := 0.0
var _aviso_oxigeno_bajo := false
var _aviso_oxigeno_agotado := false
var _ranking_panel: CanvasLayer   # solo existe si el juego está en una sala
var _jornada: Node                # jornada diaria (scripts/jornada.gd)
var _dia_pedido := false          # ya se pidió la jornada de hoy al relay
var _repetir_dia := false         # Claude pidió jugar la jornada aunque ya esté hecha
var modo_remoto := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # responde aunque el juego esté en pausa
	_sala = _leer_sala()
	modo_remoto = not _sala.is_empty() or "--mcp" in OS.get_cmdline_user_args()
	if OS.has_feature("web"):
		modo_remoto = modo_remoto or bool(JavaScriptBridge.eval("new URLSearchParams(window.location.search).get('mcp') === '1'", true))
	if not modo_remoto:
		set_process(false)
		return
	if not _sala.is_empty():
		URL = URL_RELAY + "/juego?sala=" + _sala
	get_tree().node_added.connect(_on_nodo_agregado)
	_crear_jornada()
	if not _sala.is_empty():
		_crear_panel_ranking()
	_conectar_eventos_nasa.call_deferred()   # EventosNasa se carga después de este autoload
	_conectar()


## Código de sala de la dirección (?sala=) o de la línea de comandos (--sala=).
## Solo deja letras, números, - y _.
func _leer_sala() -> String:
	var sala := ""
	if OS.has_feature("web"):
		var valor = JavaScriptBridge.eval(
			"(new URLSearchParams(window.location.search).get('sala') || '')", true)
		if valor is String:
			sala = valor
	else:
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--sala="):
				sala = arg.trim_prefix("--sala=")
	var limpia := ""
	for c in sala:
		if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "-" or c == "_":
			limpia += c
	if limpia.length() < 3:
		return ""
	return limpia.left(40)


func _conectar() -> void:
	_socket = WebSocketPeer.new()
	_socket.connect_to_url(URL)


func _process(delta: float) -> void:
	_socket.poll()
	match _socket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _conectado:
				_conectado = true
				_espera = 1.0
				print("[MCP] Conectado a ", URL)
				if not _sala.is_empty():
					var hud := get_tree().get_first_node_in_group("hud")
					if hud:
						hud.mostrar_mensaje("Sala " + _sala + " conectada", Color("#66b3ff"), 3.0)
					# La primera vez que se conecta, pide la jornada de hoy
					if not _dia_pedido:
						_dia_pedido = true
						get_tree().create_timer(4.0).timeout.connect(_pedir_dia)
			while _socket.get_available_packet_count() > 0:
				_recibir(_socket.get_packet().get_string_from_utf8())
		WebSocketPeer.STATE_CLOSED:
			if _conectado:
				_conectado = false
				print("[MCP] Desconectado")
			_reintento += delta
			if _reintento >= _espera:
				_reintento = 0.0
				_espera = minf(_espera * 2.0, 10.0)
				_conectar()
	_revisar_oxigeno()


# ---------------------------------------------------------------- comandos

func _recibir(texto: String) -> void:
	var datos = JSON.parse_string(texto)
	# El relay manda el ranking (sin "id") al terminar cada evento de la NASA
	if datos is Dictionary and datos.get("tipo") == "ranking":
		if _ranking_panel:
			# Si está abierta la tarjeta de fin de jornada, el ranking sale al cerrarla
			if _jornada and _jornada.pantalla.ocupada():
				_jornada.pantalla.cerrada.connect(_ranking_panel.actualizar.bind(datos), CONNECT_ONE_SHOT)
			else:
				_ranking_panel.actualizar(datos)
		return
	if datos is Dictionary and datos.get("tipo") == "jornada":
		# Si la sala ya la completó hoy se juega igual como repaso (el relay no vuelve a dar bono)
		if not _jornada.activa:
			_jornada.iniciar(datos)
		_repetir_dia = false
		return
	if datos is Dictionary and datos.get("tipo") == "jornada_guardada":
		_jornada.poner_bono(datos)
		return
	if not (datos is Dictionary) or not datos.has("id"):
		return
	var args: Dictionary = datos.get("args", {}) if datos.get("args") is Dictionary else {}
	var resultado: Array = _ejecutar(str(datos.get("cmd", "")), args)
	var respuesta := {"id": datos["id"], "ok": resultado[0]}
	if resultado[0]:
		respuesta["datos"] = resultado[1]
	else:
		respuesta["error"] = resultado[1]
	_enviar(respuesta)


## Devuelve [true, datos] o [false, "mensaje de error"].
func _ejecutar(cmd: String, args: Dictionary) -> Array:
	match cmd:
		"mensaje":
			var hud := get_tree().get_first_node_in_group("hud")
			if hud == null:
				return [false, "No se encontró el HUD en la escena actual"]
			var color := Color.from_string(str(args.get("color", "#ffffff")), Color.WHITE)
			hud.mostrar_mensaje(str(args.get("texto", "")), color, float(args.get("segundos", 3.0)))
			return [true, {"mostrado": true}]

		"estado":
			return [true, _estado()]

		"evento_nasa":
			var eventos := get_node_or_null("/root/EventosNasa")
			if eventos == null:
				return [false, "El juego no tiene el autoload EventosNasa"]
			var resumen: Dictionary = eventos.lanzar(args)
			if resumen.has("error"):
				return [false, resumen["error"]]
			return [true, resumen]

		"cancelar_evento":
			var eventos := get_node_or_null("/root/EventosNasa")
			if eventos == null or eventos.activo.is_empty():
				return [false, "No hay ningún evento en curso"]
			eventos.terminar("cancelado")
			return [true, {"cancelado": true}]

		"iniciar_dia":
			# Con "misiones" se usa esa lista; si no, se pide la de hoy al relay.
			if args.get("misiones") is Array:
				if not _jornada.iniciar({"fecha": str(args.get("fecha", Time.get_date_string_from_system(true))),
						"misiones": args["misiones"]}):
					return [false, "La lista de misiones está vacía o no es válida"]
				return [true, _jornada.resumen()]
			if _sala.is_empty():
				return [false, "Sin sala no hay relay: pasa la lista de misiones en 'misiones'"]
			if _jornada.activa:
				return [false, "Ya hay una jornada en curso"]
			_repetir_dia = bool(args.get("repetir", false))
			_pedir_dia()
			return [true, {"pedido": true, "repetir": _repetir_dia}]

		"cancelar_dia":
			if not _jornada.activa:
				return [false, "No hay ninguna jornada en curso"]
			_jornada.cancelar()
			return [true, {"cancelada": true}]

		"recargar_oxigeno":
			var g := get_node_or_null("/root/Global")
			if g == null:
				return [false, "No se encontró el autoload Global"]
			var pct := clampf(float(args.get("porcentaje", 100.0)), 0.0, 100.0)
			g.oxigen = minf(g.oxigen + OXIGENO_MAX * pct / 100.0, OXIGENO_MAX)
			return [true, {"oxigeno_pct": _pct(g.oxigen, OXIGENO_MAX)}]

		"recargar_combustible":
			var sop := get_tree().get_first_node_in_group("soplete")
			if sop == null:
				return [false, "No hay soplete en la escena actual"]
			var pct := clampf(float(args.get("porcentaje", 100.0)), 0.0, 100.0)
			sop.recargar(sop.combustible_max * pct / 100.0)
			return [true, {"combustible_pct": _pct(sop.combustible, sop.combustible_max)}]

	return [false, "Comando desconocido: %s" % cmd]


func _estado() -> Dictionary:
	var estado := {}
	var escena := get_tree().current_scene
	estado["escena"] = str(escena.name) if escena else ""

	var g := get_node_or_null("/root/Global")
	if g:
		estado["oxigeno_pct"] = _pct(g.oxigen, OXIGENO_MAX)

	var sop := get_tree().get_first_node_in_group("soplete")
	if sop:
		estado["soplete"] = {
			"combustible_pct": _pct(sop.combustible, sop.combustible_max),
			"encendido": sop.activo,
		}

	var paneles := []
	for s in get_tree().get_nodes_in_group("soldable"):
		paneles.append({
			"nombre": s.nombre,
			"progreso_pct": snappedf(s.progreso, 0.1),
			"terminado": s.terminado,
		})
	estado["soldables"] = paneles

	var jugador := _buscar_jugador()
	if jugador:
		var p: Vector3 = jugador.global_position
		var en_mano = jugador.get("held_object")
		if not is_instance_valid(en_mano):
			en_mano = jugador.get("herramienta_activa")   # herramienta del inventario (soplete)
		estado["jugador"] = {
			"posicion": [snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)],
			"objeto_en_mano": str(en_mano.name) if is_instance_valid(en_mano) else null,
		}

	var eventos := get_node_or_null("/root/EventosNasa")
	if eventos and not eventos.activo.is_empty():
		estado["evento_nasa"] = eventos.resumen_actual()
	if _jornada:
		var j: Dictionary = _jornada.resumen()
		if not j.is_empty():
			estado["jornada"] = j
	return estado


# ---------------------------------------------------------------- ranking

func _crear_panel_ranking() -> void:
	_ranking_panel = load("res://scripts/ranking_panel.gd").new()
	_ranking_panel.name = "RankingPanel"
	add_child(_ranking_panel)
	_ranking_panel.pedir_ranking.connect(func(): _enviar({"tipo": "pedir_ranking"}))


func _crear_jornada() -> void:
	_jornada = load("res://scripts/jornada.gd").new()
	_jornada.name = "Jornada"
	add_child(_jornada)
	_jornada.terminada.connect(func(r: Dictionary): _evento("jornada_fin", {"datos": r}))


func _pedir_dia() -> void:
	if _jornada and not _jornada.activa:
		_enviar({"tipo": "iniciar_dia"})


# ---------------------------------------------------------------- eventos

func _conectar_eventos_nasa() -> void:
	var eventos := get_node_or_null("/root/EventosNasa")
	if eventos == null:
		return
	eventos.evento_iniciado.connect(func(r: Dictionary): _evento("evento_nasa_inicio", {"datos": r}))
	eventos.evento_terminado.connect(func(r: Dictionary): _evento("evento_nasa_fin", {"datos": r}))


func _on_nodo_agregado(nodo: Node) -> void:
	if nodo.has_signal("soldado"):
		nodo.connect("soldado", func(): _evento("soldado", {"nombre": str(nodo.get("nombre"))}))
	if nodo.has_signal("sin_combustible"):
		nodo.connect("sin_combustible", func(): _evento("sin_combustible"))


func _revisar_oxigeno() -> void:
	var g := get_node_or_null("/root/Global")
	if g == null:
		return
	var pct := _pct(g.oxigen, OXIGENO_MAX)
	if pct <= OXIGENO_BAJO_PCT and not _aviso_oxigeno_bajo:
		_aviso_oxigeno_bajo = true
		_evento("oxigeno_bajo", {"oxigeno_pct": pct})
	elif pct > OXIGENO_BAJO_PCT:
		_aviso_oxigeno_bajo = false
	if pct <= 0.0 and not _aviso_oxigeno_agotado:
		_aviso_oxigeno_agotado = true
		_evento("oxigeno_agotado")
	elif pct > 0.0:
		_aviso_oxigeno_agotado = false


func _evento(nombre: String, datos: Dictionary = {}) -> void:
	var paquete := {"tipo": "evento", "evento": nombre, "tiempo": Time.get_datetime_string_from_system()}
	paquete.merge(datos)
	_enviar(paquete)


# ---------------------------------------------------------------- utilidades

func _enviar(datos: Dictionary) -> void:
	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.send_text(JSON.stringify(datos))


func _buscar_jugador() -> Node3D:
	var escena := get_tree().current_scene
	if escena == null:
		return null
	for n in escena.find_children("*", "CharacterBody3D", true, false):
		if "held_object" in n:
			return n
	return null


func _pct(valor: float, maximo: float) -> float:
	return snappedf(valor / maximo * 100.0, 0.1)
