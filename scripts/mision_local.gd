extends Node
## Misión autónoma. Las sesiones --mcp / ?mcp=1 / ?sala= conservan su director remoto.
const UI := preload("res://scripts/mision_ui.gd")
const REPARABLE := preload("res://scripts/soldable.gd")
const DURACION := 180.0
const OBJETIVOS := [
	{"id": "fuga", "nombre": "Fuga de oxígeno", "herramienta": "pistola", "texto": "Sellar fuga · Soplete", "pos": Vector3(-7, 8, -5.6)},
	{"id": "reactor", "nombre": "Reactor", "herramienta": "llave", "texto": "Ajustar reactor · Llave inglesa", "pos": Vector3(-1, 8, -5.6)},
	{"id": "comunicaciones", "nombre": "Comunicaciones", "herramienta": "rachet", "texto": "Fijar antena · Rachet", "pos": Vector3(4, 8, -5.6)},
]

var hud: Node
var jugador: CharacterBody3D
var ui: CanvasLayer
var decoracion: Node3D
var reparables: Array[Node3D] = []
var tiempo := DURACION
var fase := "herramientas"
var finalizada := false


func _ready() -> void:
	Global.reiniciar()
	if ConexionMCP.modo_remoto:
		set_process(false)
		_preparar_remoto.call_deferred()
		return
	if OS.has_feature("web"):
		Global.en_curso = bool(JavaScriptBridge.eval("window.nasaspStarted !== false", true))
	add_to_group("mision_local")
	_iniciar.call_deferred()


## Con sala (jornada diaria) no hay entrenamiento, pero sí la misma mesa con las
## 3 herramientas (soplete, llave inglesa y rachet) y los letreros del refugio.
func _preparar_remoto() -> void:
	hud = get_tree().get_first_node_in_group("hud")
	var escena := get_tree().current_scene
	if hud == null or escena == null:
		return
	decoracion = Node3D.new()
	decoracion.name = "Equipo"
	escena.add_child(decoracion)
	_preparar_mesa()
	var refugio := get_tree().get_first_node_in_group("refugio") as Node3D
	if refugio:
		_rotulo(refugio, "REFUGIO · SALA DE OXÍGENO", Vector3(0, 3, 0), Color(0.3, 1, 0.75))
	_rotulo(decoracion, "← REFUGIO / SALA DE OXÍGENO", Vector3(-8, 9, -1), Color(0.3, 1, 0.75))


func _iniciar() -> void:
	var escena := get_tree().current_scene
	hud = get_tree().get_first_node_in_group("hud")
	jugador = escena.get_node("player") as CharacterBody3D
	ui = UI.new()
	add_child(ui)
	ui.reiniciar.connect(_reiniciar)
	decoracion = Node3D.new()
	decoracion.name = "Entrenamiento"
	escena.add_child(decoracion)
	hud.agregar_tarea("equipo", "Recoger las tres herramientas")
	for objetivo in OBJETIVOS:
		hud.agregar_tarea(objetivo["id"], objetivo["texto"])
		_crear_reparacion(objetivo)
	hud.agregar_tarea("refugio", "Resguardarse de la fulguración")
	hud.inventario_cambiado.connect(_revisar_objetivos)
	hud.tarea_completada.connect(_on_tarea)
	EventosNasa.evento_terminado.connect(_on_evento_terminado)
	_preparar_mesa()
	var refugio := get_tree().get_first_node_in_group("refugio") as Node3D
	if refugio:
		_rotulo(refugio, "REFUGIO · SALA DE OXÍGENO", Vector3(0, 3, 0), Color(0.3, 1, 0.75))
	_rotulo(decoracion, "← REFUGIO / SALA DE OXÍGENO", Vector3(-8, 9, -1), Color(0.3, 1, 0.75))
	print("[MISION] Entrenamiento listo: 3 herramientas, 3 reparaciones, refugio; 180 s.")


func _process(delta: float) -> void:
	if ui == null or finalizada:
		return
	if not Global.en_curso:
		Global.en_curso = bool(JavaScriptBridge.eval("window.nasaspStarted !== false", true))
		return
	tiempo = maxf(tiempo - delta, 0.0)
	if Global.oxigen <= 0.0:
		_finalizar(false, "Se agotó el oxígeno.")
		return
	if tiempo <= 0.0:
		_finalizar(false, "Se terminó el tiempo de entrenamiento.")
		return
	var segundos := int(ceil(tiempo))
	var titulo := "ENTRENAMIENTO · %02d:%02d" % [segundos / 60, segundos % 60]
	var objetivo := "Recoge las tres herramientas de la mesa con E."
	if fase == "reparaciones":
		objetivo = "Gira hacia los paneles señalados. Equipa la herramienta indicada y mantén clic."
	elif fase == "refugio":
		var refugio := get_tree().get_first_node_in_group("refugio") as Node3D
		var distancia := jugador.global_position.distance_to(refugio.global_position) if refugio else 0.0
		var evento: Dictionary = EventosNasa.resumen_actual()
		var protegido := bool(evento.get("protegido", false))
		objetivo = "Estás en el refugio. Permanece aquí hasta que termine la alerta." if protegido else "Ve al REFUGIO por la salida oeste (←). Distancia: %d m." % int(distancia)
		if evento.has("estallido_en_seg"):
			titulo = "RADIACIÓN EN %02d s · %02d:%02d" % [int(ceil(evento["estallido_en_seg"])), segundos / 60, segundos % 60]
	ui.actualizar(titulo, objetivo)


func _revisar_objetivos() -> void:
	if finalizada:
		return
	if hud.tiene_objeto("pistola") and hud.tiene_objeto("llave") and hud.tiene_objeto("rachet"):
		hud.completar_tarea("equipo")
		if fase == "herramientas":
			fase = "reparaciones"
			hud.mostrar_mensaje("Equipo listo. Repara los tres paneles señalados.", Color(0.4, 1, 0.75), 4)


func _on_tarea(_id: String) -> void:
	if finalizada or fase == "refugio":
		return
	for id in ["equipo", "fuga", "reactor", "comunicaciones"]:
		if not hud.tareas[id]["hecha"]:
			return
	fase = "refugio"
	# Ejemplo educativo fijo: se anuncia como simulación, sin atribuir datos en vivo.
	EventosNasa.lanzar({"tipo": "FLR", "intensidad": "M2.5", "dificultad": "normal", "mensaje": "SIMULACIÓN · Fulguración solar: ve al refugio por la salida oeste."})


func _on_evento_terminado(resumen: Dictionary) -> void:
	if finalizada or fase != "refugio" or resumen.get("tipo") != "FLR":
		return
	if resumen.get("resultado") == "superado":
		hud.completar_tarea("refugio")
		_finalizar(true, "Reparaste los tres sistemas y te protegiste de la radiación.")
	else:
		_finalizar(false, "La radiación te alcanzó. Entra al refugio antes del estallido y permanece allí.")


func _finalizar(exito: bool, motivo: String) -> void:
	if finalizada:
		return
	finalizada = true
	Global.partida_terminada = true
	for sop in get_tree().get_nodes_in_group("soplete"):
		sop.usar(false)
	if not EventosNasa.activo.is_empty():
		EventosNasa.terminar("cancelado")
	jugador.velocity = Vector3.ZERO
	hud.mostrar_contexto("")
	var restantes := int(ceil(tiempo))
	ui.resultado(exito, "%s\nTiempo restante: %02d:%02d · Oxígeno: %d%%" % [motivo, restantes / 60, restantes % 60, int(Global.oxigen / Global.OXIGENO_MAX * 100)])
	get_tree().paused = true
	print("[MISION] Resultado: ", "completada" if exito else "fallida", " · ", motivo)


func _reiniciar() -> void:
	jugador._vaciar_mano()
	for item in hud.objetos:
		var nodo = item.get("nodo")
		if is_instance_valid(nodo) and nodo.get_parent() == null:
			nodo.free()
	get_tree().paused = false
	Global.reiniciar()
	get_tree().reload_current_scene()


func _preparar_mesa() -> void:
	_caja(Vector3(-1.2, 6.9, 4.8), Vector3(4.3, 0.22, 1.4), Color(0.07, 0.15, 0.22))
	_caja(Vector3(-1.2, 5.3, 4.8), Vector3(0.35, 3.0, 0.7), Color(0.07, 0.15, 0.22))
	_caja(Vector3(-1.2, 7.03, 5.4), Vector3(4.3, 0.05, 0.05), Color(0.15, 0.85, 1))
	_rotulo(decoracion, "E · EQUIPO", Vector3(-1.2, 8.45, 4.9), Color(0.5, 0.9, 1))
	var sop := get_tree().get_first_node_in_group("soplete") as RigidBody3D
	if sop:
		sop.freeze = true
		sop.global_transform = Transform3D(Basis.IDENTITY, Vector3(-1.2, 7.4, 4.8))
		var anterior := sop.get_node_or_null("pistola") as Node3D
		if anterior:
			anterior.hide()
		var col := sop.get_node("CollisionShape3D") as CollisionShape3D
		col.transform = Transform3D.IDENTITY
		var forma := BoxShape3D.new()
		forma.size = Vector3(0.5, 0.65, 0.85)
		col.shape = forma
		var modelo: Node3D = hud.crear_modelo("pistola", 0.85, true)
		if modelo:
			sop.add_child(modelo)
		_rotulo(decoracion, "SOPLETE", Vector3(-1.2, 7.95, 4.8), Color(1, 0.8, 0.4))
	for i in 2:
		var id := "llave" if i == 0 else "rachet"
		var pos := Vector3(-2.55 if i == 0 else 0.15, 7.4, 4.8)
		var herramienta: RigidBody3D = hud.aparecer_herramienta(id, pos, 2.5)
		if herramienta:
			herramienta.freeze = true
		_rotulo(decoracion, "LLAVE INGLESA" if i == 0 else "RACHET", pos + Vector3(0, 0.6, 0), Color(1, 0.8, 0.4))
	var luz := OmniLight3D.new()
	luz.position = Vector3(-1.2, 9, 3.8)
	luz.light_color = Color(0.6, 0.85, 1)
	luz.light_energy = 2
	luz.omni_range = 7
	decoracion.add_child(luz)


func _crear_reparacion(datos: Dictionary) -> void:
	var panel := MeshInstance3D.new()
	var malla := BoxMesh.new()
	malla.size = Vector3(1.8, 1.3, 0.2)
	panel.mesh = malla
	panel.set_script(REPARABLE)
	panel.set("nombre", datos["nombre"])
	panel.set("tarea_id", datos["id"])
	panel.set("herramienta_requerida", datos["herramienta"])
	var cuerpo := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var forma := BoxShape3D.new()
	forma.size = malla.size
	col.shape = forma
	cuerpo.add_child(col)
	panel.add_child(cuerpo)
	decoracion.add_child(panel)
	panel.global_position = datos["pos"]
	hud.conectar_reparable(panel)
	reparables.append(panel)
	_rotulo(panel, datos["texto"], Vector3(0, 1.05, 0), Color(1, 0.8, 0.4))


func _caja(pos: Vector3, tamano: Vector3, color: Color) -> void:
	var caja := CSGBox3D.new()
	caja.position = pos
	caja.size = tamano
	caja.use_collision = true
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = 0.6
	caja.material = material
	decoracion.add_child(caja)


func _rotulo(padre: Node3D, texto: String, pos: Vector3, color: Color) -> void:
	var label := Label3D.new()
	label.text = texto
	label.font_size = 28
	label.pixel_size = 0.003
	label.outline_size = 4
	label.modulate = color
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = pos
	padre.add_child(label)
