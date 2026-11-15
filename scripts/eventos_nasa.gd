extends Node
## Eventos de clima espacial de la NASA (DONKI) convertidos en mecánicas del juego.
## Está registrado como Autoload con el nombre "EventosNasa".
##
## Se lanza con  EventosNasa.lanzar({"tipo": "FLR", "intensidad": "M2.5", ...}).
## Normalmente lo lanza Claude a través de ConexionMCP (comando "evento_nasa"),
## con un evento real de la tabla `eventos` de Supabase.
##
## Mecánicas (los problemas y dificultades son los de las tablas de Supabase):
##   FLR  Fulguración solar     -> cuenta regresiva y estallido de radiación: hay que protegerse.
##   CME  Eyección de masa      -> sacudida y aparecen ventilas/paneles dañados que hay que soldar a tiempo.
##   GST  Tormenta geomagnética -> fallas eléctricas (HUD y luces parpadean, soplete más débil) + reparaciones.
##   SEP  Partículas solares    -> radiación sostenida: el oxígeno baja más rápido si no estás protegido.
##   IPS  Choque interplanetario-> sacudida fuerte que empuja los objetos sueltos; aviso de posible CME.
##
## Protección contra radiación (en este orden):
##   - Sostener un objeto del grupo "escudo" (mecánica "Escudo").
##   - Estar dentro de un Area3D del grupo "refugio" (la sala blindada).
##   - Si la escena no tiene ningún "refugio", agacharse (tecla de agacharse) cuenta como cubrirse.
## Las reparaciones aparecen en los Marker3D del grupo "punto_dano". Si no hay, se buscan
## lugares válidos alrededor del jugador (con suelo, preferentemente dentro de un cuarto,
## pegadas a una pared o al suelo; ver _buscar_lugar). Si una escena tiene Area3D en el
## grupo "zona_reparacion", solo aparecen dentro de esas zonas.

signal evento_iniciado(resumen: Dictionary)
signal evento_terminado(resumen: Dictionary)

const SOLDABLE := preload("res://scripts/soldable.gd")
const OXIGENO_MAX := 125.0          # mismo valor inicial que Global.oxigen
const AVISO_FLR := 10.0             # segundos de aviso antes del estallido de una fulguración
const ALCANCE_REPARACION := 2.0     # m máximos desde el jugador a una reparación (el soplete llega a 2.5)
const RADIO_MIN := 3.0              # m: distancia mínima del jugador a la que aparecen reparaciones
const RADIO_MAX := 12.0             # m: distancia máxima
const SEPARACION_MIN := 1.5         # m entre reparaciones
const DANO_MAX_POR_EVENTO := 50.0   # % de oxígeno máximo que puede quitar un solo evento

const NOMBRES := {
	"FLR": "Fulguración solar",
	"CME": "Eyección de masa coronal",
	"GST": "Tormenta geomagnética",
	"SEP": "Partículas solares energéticas",
	"IPS": "Choque interplanetario",
}

# Copia de la tabla "dificultades" de Supabase
const DIFICULTADES := {
	"facil":   {"nombre": "Fácil",   "tiempo_limite_seg": 120.0, "multiplicador_dano": 1.0, "num_problemas": 1},
	"normal":  {"nombre": "Normal",  "tiempo_limite_seg": 90.0,  "multiplicador_dano": 1.5, "num_problemas": 2},
	"dificil": {"nombre": "Difícil", "tiempo_limite_seg": 60.0,  "multiplicador_dano": 2.0, "num_problemas": 3},
	"extremo": {"nombre": "Extremo", "tiempo_limite_seg": 45.0,  "multiplicador_dano": 3.0, "num_problemas": 4},
}

# Copia de las tablas "problemas" y "tipo_evento_problema" de Supabase
const PROBLEMAS := {
	1: {"nombre": "Ventila rota",           "mecanica": "Soplete",       "dano_base": 10.0},
	2: {"nombre": "Panel solar suelto",     "mecanica": "Llave inglesa", "dano_base": 8.0},
	3: {"nombre": "Radiación en la cabina", "mecanica": "Escudo",        "dano_base": 15.0},
}
const PROBLEMAS_POR_TIPO := {
	"FLR": [3],
	"CME": [1, 2],
	"GST": [2, 1],
	"SEP": [3],
	"IPS": [],
}

const COLOR_ALERTA := Color(1.0, 0.45, 0.3)
const COLOR_AVISO := Color(1.0, 0.85, 0.3)
const COLOR_BIEN := Color(0.4, 1.0, 0.5)

var activo: Dictionary = {}        # evento en curso ({} si no hay ninguno)

var _tiempo := 0.0                 # segundos que le quedan al evento
var _mult := 1.0                   # multiplicador de daño (dificultad x severidad)
var _dano_total := 0.0             # % de oxígeno perdido por el evento
var _reparaciones: Array = []      # soldables creados por el evento
var _rad_continua := 0.0           # % de oxígeno por segundo mientras no estés protegido (SEP)
var _rad_estallido := 0.0          # % de oxígeno de golpe al estallar (FLR)
var _aviso := 0.0                  # segundos para el estallido (FLR)
var _ultimo_aviso := -1
var _falla := 0.0                  # 0 = sin falla eléctrica, 1 = falla máxima (GST)
var _potencias := {}               # soplete -> potencia original
var _luces := {}                   # luz -> energía original
var _parpadeo := 0.0
var _temblor := 0.0                # segundos de temblor
var _fuerza_temblor := 0.0
var _recordatorio := 0.0


# ================================================================ API

## Lanza un evento. Devuelve el resumen, o {"error": "..."} si los datos no sirven.
## datos: tipo (FLR, CME, GST, SEP, IPS), intensidad ("M2.5", "Kp 7", "624 km/s"),
##        fecha, mensaje (texto de la IA), dificultad (Fácil/Normal/Difícil/Extremo),
##        severidad (1 a 5, opcional: si no se da se calcula con la intensidad).
func lanzar(datos: Dictionary) -> Dictionary:
	var tipo := str(datos.get("tipo", "")).strip_edges().to_upper()
	if not NOMBRES.has(tipo):
		return {"error": "Tipo de evento desconocido: '%s'. Usa FLR, CME, GST, SEP o IPS." % tipo}
	if not activo.is_empty():
		terminar("reemplazado")

	var intensidad := _texto(datos.get("intensidad"))
	var severidad := int(datos.get("severidad", 0)) if datos.get("severidad") != null else 0
	if severidad < 1 or severidad > 5:
		severidad = calcular_severidad(tipo, intensidad)
	var dif: Dictionary = _dificultad(_texto(datos.get("dificultad")))

	_limpiar_estado()
	_mult = float(dif["multiplicador_dano"]) * (0.6 + 0.2 * severidad)   # sev 1 = x0.8 ... sev 5 = x1.6
	_tiempo = float(dif["tiempo_limite_seg"])

	activo = {
		"tipo": tipo,
		"nombre": NOMBRES[tipo],
		"intensidad": intensidad,
		"severidad": severidad,
		"fecha": _texto(datos.get("fecha")),
		"dificultad": dif["nombre"],
		"mensaje": _texto(datos.get("mensaje")),
		"problemas": [],
	}

	match tipo:
		"FLR":
			_tiempo = AVISO_FLR + 3.0
			_aviso = AVISO_FLR
			_rad_estallido = PROBLEMAS[3]["dano_base"] * _mult
			activo["problemas"].append(PROBLEMAS[3]["nombre"])
		"SEP":
			_tiempo = minf(_tiempo, 20.0 + 5.0 * severidad)
			_rad_continua = PROBLEMAS[3]["dano_base"] * _mult / 20.0
			activo["problemas"].append(PROBLEMAS[3]["nombre"])
		"CME":
			_sacudir(1.5 + 0.3 * severidad, 0.04 + 0.02 * severidad, false)
			_crear_reparaciones(tipo, int(dif["num_problemas"]) + int((severidad - 1) / 2))
		"GST":
			_falla = clampf(0.15 * severidad + 0.1, 0.0, 0.85)
			_iniciar_falla_electrica()
			_crear_reparaciones(tipo, int(dif["num_problemas"]) + int((severidad - 1) / 3))
		"IPS":
			_tiempo = 3.0 + severidad
			_sacudir(_tiempo, 0.05 + 0.03 * severidad, true)

	activo["duracion_seg"] = snappedf(_tiempo, 0.1)
	_anunciar_inicio()
	var resumen := resumen_actual()
	evento_iniciado.emit(resumen)
	return resumen


## Termina el evento en curso. resultado: "superado", "fallado", "con_danos", "cancelado"...
func terminar(resultado: String) -> void:
	if activo.is_empty():
		return
	var resumen := resumen_actual()
	resumen["resultado"] = resultado
	var dano := _dano_total
	resumen["dano_recibido_pct"] = snappedf(dano, 0.1)
	resumen.erase("tiempo_restante_seg")
	resumen.erase("estallido_en_seg")
	_restaurar_efectos()
	activo = {}
	# Las reparaciones que quedaron se quitan después de unos segundos
	var restos := _reparaciones.duplicate()
	_reparaciones.clear()
	get_tree().create_timer(4.0).timeout.connect(func():
		for r in restos:
			if is_instance_valid(r):
				r.queue_free())
	match resultado:
		"superado":
			_hud("Evento superado: %s" % resumen["nombre"], COLOR_BIEN, 4.0)
		"fallado", "con_danos":
			_hud("%s: perdiste %d%% de oxígeno" % [resumen["nombre"], int(dano)], COLOR_ALERTA, 4.0)
		"cancelado":
			_hud("Evento cancelado", Color.WHITE, 2.0)
	evento_terminado.emit(resumen)


## Estado del evento en curso para ConexionMCP ({} si no hay ninguno).
func resumen_actual() -> Dictionary:
	if activo.is_empty():
		return {}
	var r := activo.duplicate(true)
	r["tiempo_restante_seg"] = snappedf(maxf(_tiempo, 0.0), 0.1)
	r["dano_recibido_pct"] = snappedf(_dano_total, 0.1)
	r["protegido"] = _protegido()
	var pendientes := []
	for rep in _reparaciones:
		if is_instance_valid(rep) and not rep.terminado:
			pendientes.append({"nombre": rep.nombre, "progreso_pct": snappedf(rep.progreso, 0.1)})
	r["reparaciones_pendientes"] = pendientes
	if _aviso > 0.0:
		r["estallido_en_seg"] = snappedf(_aviso, 0.1)
	return r


## Severidad de 1 a 5 a partir de la intensidad que guarda el listener en Supabase.
static func calcular_severidad(tipo: String, intensidad: String) -> int:
	var t := intensidad.strip_edges().to_upper()
	match tipo:
		"FLR":   # clase de la fulguración: A/B/C/M/X + número
			if t.is_empty():
				return 2
			var numero := t.substr(1).to_float()
			match t[0]:
				"X":
					return 5
				"M":
					return 4 if numero >= 5.0 else 3
				"C":
					return 2 if numero >= 5.0 else 1
			return 1
		"GST":   # índice Kp: 5 = tormenta menor ... 9 = extrema
			var kp := t.replace("KP", "").strip_edges().to_float()
			return 2 if kp <= 0.0 else clampi(int(kp) - 4, 1, 5)
		"CME":   # velocidad en km/s
			var v := t.replace("KM/S", "").strip_edges().to_float()
			if v <= 0.0:
				return 2
			if v < 500.0:
				return 1
			if v < 800.0:
				return 2
			if v < 1200.0:
				return 3
			if v < 2000.0:
				return 4
			return 5
		"SEP":
			return 3
	return 2


# ================================================================ ciclo

func _process(delta: float) -> void:
	_actualizar_temblor(delta)
	if activo.is_empty():
		return
	_tiempo -= delta
	var protegido := _protegido()

	# --- Fulguración: cuenta regresiva y estallido
	if _aviso > 0.0:
		_aviso -= delta
		var seg := int(ceil(_aviso))
		if seg != _ultimo_aviso and seg <= 7 and seg > 0:
			_ultimo_aviso = seg
			_hud("¡RADIACIÓN EN %d s! %s" % [seg, _como_protegerse()], COLOR_ALERTA, 1.2)
		if _aviso <= 0.0:
			_sacudir(0.6, 0.06, false)
			if protegido:
				_hud("Estallido de radiación: estás protegido", COLOR_BIEN, 3.0)
			else:
				_danar(_rad_estallido)
				_hud("¡Estallido de radiación! -%d%% oxígeno" % int(_rad_estallido), COLOR_ALERTA, 3.0)

	# --- Partículas solares: radiación sostenida
	if _rad_continua > 0.0 and not protegido:
		_danar(_rad_continua * delta)

	# --- Tormenta geomagnética: parpadeos
	if _falla > 0.0:
		_actualizar_falla(delta)

	# --- Reparaciones
	var pendientes := 0
	for rep in _reparaciones:
		if is_instance_valid(rep) and not rep.terminado:
			pendientes += 1
	if not _reparaciones.is_empty() and pendientes == 0:
		terminar("superado")
		return

	_recordatorio -= delta
	if _recordatorio <= 0.0 and _aviso <= 0.0:
		_recordatorio = 15.0
		if pendientes > 0:
			_hud("Reparaciones pendientes: %d  |  %d s" % [pendientes, int(_tiempo)], COLOR_AVISO, 3.0)
		elif _rad_continua > 0.0 and not protegido:
			_hud("Radiación: %s  |  %d s" % [_como_protegerse(), int(_tiempo)], COLOR_AVISO, 3.0)

	# --- Se acabó el tiempo
	if _tiempo <= 0.0:
		if pendientes > 0:
			for rep in _reparaciones:
				if is_instance_valid(rep) and not rep.terminado:
					_danar(float(rep.get_meta("dano_base", 8.0)) * _mult)
			terminar("fallado")
		else:
			terminar("superado" if _dano_total < 0.05 else "con_danos")


# ================================================================ mecánicas

func _crear_reparaciones(tipo: String, cantidad: int) -> void:
	var ids: Array = PROBLEMAS_POR_TIPO[tipo]
	cantidad = clampi(cantidad, 1, 6)
	var marcadores := get_tree().get_nodes_in_group("punto_dano")
	marcadores.shuffle()
	var usados: Array[Vector3] = []
	for i in cantidad:
		var problema: Dictionary = PROBLEMAS[ids[i % ids.size()]]
		var nombre: String = problema["nombre"]
		if cantidad > ids.size():
			nombre += " %d" % (i + 1)
		# Se busca el lugar antes de crear la pieza, para que no estorbe a los rayos
		var lugar := {} if i < marcadores.size() else _buscar_lugar(usados)
		var rep := _crear_soldable(nombre, problema)
		if rep == null:
			return
		if i < marcadores.size():
			var m: Node3D = marcadores[i]
			rep.global_transform = m.global_transform
		elif not lugar.is_empty():
			rep.global_transform = lugar["transform"]
			usados.append(lugar["pie"])
		else:
			_colocar_en_pared(rep, i, cantidad)
		_reparaciones.append(rep)
		activo["problemas"].append(nombre)


func _crear_soldable(nombre: String, problema: Dictionary) -> Node3D:
	var escena := get_tree().current_scene
	if escena == null:
		return null
	var caja := CSGBox3D.new()
	caja.set_script(SOLDABLE)
	caja.name = nombre.validate_node_name()
	caja.size = Vector3(0.6, 0.5, 0.08) * _escala_jugador()
	caja.use_collision = true
	caja.set("nombre", nombre)
	caja.set_meta("dano_base", problema["dano_base"])
	caja.set_meta("mecanica", problema["mecanica"])
	escena.add_child(caja)
	# El HUD solo conecta los soldables que existían al empezar: conectamos los nuevos
	var hud := get_tree().get_first_node_in_group("hud")
	if hud:
		if hud.has_method("_on_soldado"):
			caja.connect("soldado", Callable(hud, "_on_soldado").bind(caja))
		if hud.has_method("_on_progreso"):
			caja.connect("progreso_cambiado", Callable(hud, "_on_progreso"))
	return caja


## Busca al azar un lugar válido para una reparación, entre RADIO_MIN y RADIO_MAX del jugador:
##  - tiene suelo debajo (se puede llegar caminando) y no está dentro de una estructura;
##  - si hay zonas en el grupo "zona_reparacion" (Area3D), debe estar dentro de una;
##  - se prefieren los interiores (techo y paredes alrededor);
##  - la pieza se pega a la pared más cercana a la altura del pecho, o al suelo si no hay pared;
##  - queda a más de SEPARACION_MIN de las otras reparaciones.
## Devuelve {"transform": Transform3D, "pie": Vector3, "interior": bool} o {} si no encontró.
func _buscar_lugar(usados: Array[Vector3]) -> Dictionary:
	var jugador := _jugador()
	if jugador == null:
		return {}
	var espacio := jugador.get_world_3d().direct_space_state
	var excluir := _cuerpos_dinamicos(jugador)
	var zonas := get_tree().get_nodes_in_group("zona_reparacion")
	var s := _escala_jugador()
	# Suelo bajo el jugador y altura de sus ojos (en level.tscn el jugador mide ~4.5 m)
	var cabeza := jugador.get_node_or_null("head") as Node3D
	var ojos := cabeza.global_position if cabeza else jugador.global_position + Vector3.UP * s
	var bajo := _rayo(espacio, jugador.global_position, jugador.global_position + Vector3.DOWN * 30.0, excluir)
	var suelo_y: float = bajo.position.y if not bajo.is_empty() else jugador.global_position.y - s
	var altura := maxf(ojos.y - suelo_y, 1.0)
	var alto_pieza := altura * 0.75                      # un poco abajo de los ojos
	var alcance := _alcance_soplete() * s
	var piso_ok := altura < alcance * 0.85               # ¿alcanza el soplete algo en el suelo?
	var mejor := {}
	for intento in 80:
		var angulo := randf() * TAU
		var distancia := randf_range(RADIO_MIN, RADIO_MAX) * s
		var pecho := Vector3(jugador.global_position.x, suelo_y, jugador.global_position.z) \
			+ Vector3(cos(angulo), 0, sin(angulo)) * distancia + Vector3.UP * alto_pieza
		# Libre (no dentro de una pared o caja)
		if _choca_punto(espacio, pecho, excluir) or _choca_punto(espacio, pecho + Vector3.DOWN * alto_pieza * 0.6, excluir):
			continue
		# Suelo debajo
		var suelo := _rayo(espacio, pecho, pecho + Vector3.DOWN * (alto_pieza + 2.0 * s), excluir)
		if suelo.is_empty() or suelo.normal.y < 0.7:
			continue
		var pie: Vector3 = suelo.position
		pecho = pie + Vector3.UP * alto_pieza
		if not zonas.is_empty() and not _dentro_de_zona(espacio, pecho, zonas):
			continue
		var lejos := true
		for u in usados:
			if u.distance_to(pie) < SEPARACION_MIN * s:
				lejos = false
				break
		if not lejos:
			continue
		# ¿Interior? techo arriba y paredes en al menos 3 de 4 direcciones
		var techo := _rayo(espacio, pecho, pecho + Vector3.UP * 8.0 * s, excluir)
		var paredes := 0
		var pared_cercana := {}
		for k in 8:
			var dir := Vector3.FORWARD.rotated(Vector3.UP, k * TAU / 8.0)
			var hit := _rayo(espacio, pecho, pecho + dir * 10.0 * s, excluir)
			if hit.is_empty() or absf(hit.normal.y) > 0.7:
				continue
			if k % 2 == 0:
				paredes += 1
			var d := pecho.distance_to(hit.position)
			if d <= 1.5 * s and (pared_cercana.is_empty() or d < pared_cercana["d"]):
				pared_cercana = {"d": d, "pos": hit.position, "normal": hit.normal}
		var interior := not techo.is_empty() and paredes >= 3
		var t: Transform3D
		if not pared_cercana.is_empty():
			var n: Vector3 = pared_cercana["normal"]
			t = Transform3D(Basis.looking_at(-n, Vector3.UP), pared_cercana["pos"] + n * 0.06 * s)
		elif piso_ok:   # en el suelo, acostada
			t = Transform3D(Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), pie + Vector3.UP * 0.06 * s)
		else:
			continue    # el soplete no llegaría al suelo desde la altura del jugador
		var lugar := {"transform": t, "pie": pie, "interior": interior}
		if interior and not pared_cercana.is_empty():
			return lugar          # el mejor caso: en la pared de un cuarto
		if mejor.is_empty() or (interior and not mejor["interior"]):
			mejor = lugar
	return mejor


## Tamaño del jugador respecto a lo normal (en level.tscn está escalado x2.61).
func _escala_jugador() -> float:
	var jugador := _jugador()
	if jugador == null:
		return 1.0
	return clampf(jugador.global_basis.get_scale().y, 0.5, 5.0)


func _alcance_soplete() -> float:
	var sop := get_tree().get_first_node_in_group("soplete")
	return float(sop.alcance) if sop and "alcance" in sop else 2.5


func _rayo(espacio: PhysicsDirectSpaceState3D, desde: Vector3, hasta: Vector3, excluir: Array[RID]) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(desde, hasta)
	q.exclude = excluir
	return espacio.intersect_ray(q)


func _choca_punto(espacio: PhysicsDirectSpaceState3D, punto: Vector3, excluir: Array[RID]) -> bool:
	var q := PhysicsPointQueryParameters3D.new()
	q.position = punto
	q.exclude = excluir
	return not espacio.intersect_point(q, 1).is_empty()


func _dentro_de_zona(espacio: PhysicsDirectSpaceState3D, punto: Vector3, zonas: Array) -> bool:
	var q := PhysicsPointQueryParameters3D.new()
	q.position = punto
	q.collide_with_areas = true
	q.collide_with_bodies = false
	for r in espacio.intersect_point(q, 16):
		if r.collider in zonas:
			return true
	return false


## El jugador, los objetos sueltos y las reparaciones no cuentan como suelo ni pared.
func _cuerpos_dinamicos(jugador: Node3D) -> Array[RID]:
	var rids: Array[RID] = [jugador.get_rid()]
	var escena := get_tree().current_scene
	if escena:
		for n in escena.find_children("*", "RigidBody3D", true, false):
			rids.append((n as RigidBody3D).get_rid())
	return rids


## Plan B: pone la reparación al alcance del soplete (que llega a 2.5 m): en la pared que tengas
## enfrente si está a menos de ALCANCE_REPARACION, o flotando frente a ti si no.
## Varias reparaciones se reparten en abanico a la altura del pecho.
func _colocar_en_pared(rep: Node3D, i: int, total: int) -> void:
	var jugador := _jugador()
	var origen := Vector3(0, 1, 0)
	var adelante := Vector3.FORWARD
	var excluir: Array[RID] = []
	if jugador:
		var cabeza := jugador.get_node_or_null("head") as Node3D
		origen = cabeza.global_position if cabeza else jugador.global_position + Vector3.UP
		adelante = -jugador.global_basis.z
		excluir.append(jugador.get_rid())
		var en_mano = jugador.get("held_object")
		if en_mano is CollisionObject3D:
			excluir.append((en_mano as CollisionObject3D).get_rid())
	var s := _escala_jugador()
	origen += Vector3.DOWN * 0.3 * s      # a la altura del pecho
	adelante.y = 0.0
	if adelante.length() < 0.01:
		adelante = Vector3.FORWARD
	# ~28 grados entre reparaciones (no se enciman) y alturas alternadas
	var mitad := minf(14.0 * (total - 1), 70.0)
	var abanico := 0.0 if total <= 1 else lerpf(-mitad, mitad, float(i) / float(total - 1))
	origen += Vector3.UP * (0.2 if i % 2 == 1 else -0.1) * s
	var dir := adelante.normalized().rotated(Vector3.UP, deg_to_rad(abanico))

	var query := PhysicsRayQueryParameters3D.create(origen, origen + dir * ALCANCE_REPARACION * s)
	query.exclude = excluir
	var hit := rep.get_world_3d().direct_space_state.intersect_ray(query)

	var pos := origen + dir * 1.6 * s       # sin pared cerca: flota frente al jugador
	var normal := -dir
	if not hit.is_empty() and hit.collider != rep and absf(hit.normal.y) < 0.7:
		normal = hit.normal
		pos = hit.position + normal * 0.06 * s
	var arriba := Vector3.UP if absf(normal.dot(Vector3.UP)) < 0.9 else Vector3.FORWARD
	rep.global_transform = Transform3D(Basis.looking_at(-normal, arriba), pos)


func _sacudir(segundos: float, fuerza: float, empujar: bool) -> void:
	_temblor = maxf(_temblor, segundos)
	_fuerza_temblor = maxf(_fuerza_temblor, fuerza)
	if not empujar:
		return
	var escena := get_tree().current_scene
	if escena == null:
		return
	var jugador := _jugador()
	var en_mano = jugador.get("held_object") if jugador else null
	var sev := float(activo.get("severidad", 2))
	for n in escena.find_children("*", "RigidBody3D", true, false):
		var cuerpo := n as RigidBody3D
		if cuerpo == en_mano or cuerpo.freeze:
			continue
		var dir := Vector3(randf_range(-1, 1), randf_range(0.2, 1.0), randf_range(-1, 1)).normalized()
		cuerpo.apply_central_impulse(dir * cuerpo.mass * (1.0 + sev))


func _actualizar_temblor(delta: float) -> void:
	var camara := get_viewport().get_camera_3d()
	if _temblor <= 0.0:
		if camara and (camara.h_offset != 0.0 or camara.v_offset != 0.0):
			camara.h_offset = 0.0
			camara.v_offset = 0.0
		_fuerza_temblor = 0.0
		return
	_temblor -= delta
	if camara:
		camara.h_offset = randf_range(-1.0, 1.0) * _fuerza_temblor
		camara.v_offset = randf_range(-1.0, 1.0) * _fuerza_temblor


func _iniciar_falla_electrica() -> void:
	for sop in get_tree().get_nodes_in_group("soplete"):
		if not _potencias.has(sop):
			_potencias[sop] = sop.potencia
		sop.potencia = _potencias[sop] * (1.0 - _falla * 0.6)
	var escena := get_tree().current_scene
	if escena:
		for n in escena.find_children("*", "Light3D", true, false):
			if _es_del_soplete(n):
				continue
			_luces[n] = (n as Light3D).light_energy


func _actualizar_falla(delta: float) -> void:
	_parpadeo -= delta
	if _parpadeo > 0.0:
		return
	_parpadeo = randf_range(0.05, 0.25)
	var apagon := randf() < _falla * 0.5
	var hud := get_tree().get_first_node_in_group("hud")
	if hud is CanvasLayer:
		hud.visible = not apagon
	for luz in _luces:
		if is_instance_valid(luz):
			luz.light_energy = _luces[luz] * (0.05 if apagon else randf_range(1.0 - _falla, 1.0))


func _restaurar_efectos() -> void:
	for sop in _potencias:
		if is_instance_valid(sop):
			sop.potencia = _potencias[sop]
	for luz in _luces:
		if is_instance_valid(luz):
			luz.light_energy = _luces[luz]
	var hud := get_tree().get_first_node_in_group("hud")
	if hud is CanvasLayer:
		hud.visible = true
	_limpiar_estado()


func _limpiar_estado() -> void:
	_potencias.clear()
	_luces.clear()
	_falla = 0.0
	_rad_continua = 0.0
	_rad_estallido = 0.0
	_aviso = 0.0
	_ultimo_aviso = -1
	_dano_total = 0.0
	_recordatorio = 8.0


func _anunciar_inicio() -> void:
	var texto: String = activo["mensaje"]
	if texto.is_empty():
		texto = "ALERTA: %s" % activo["nombre"]
		if not str(activo["intensidad"]).is_empty():
			texto += " (%s)" % activo["intensidad"]
	var fecha := str(activo["fecha"]).left(10)
	if not fecha.is_empty():
		texto += "  [NASA %s]" % fecha
	_hud(texto, COLOR_ALERTA, 5.0)


# ================================================================ utilidades

func _protegido() -> bool:
	var jugador := _jugador()
	if jugador == null:
		return false
	var en_mano = jugador.get("held_object")
	if en_mano is Node and is_instance_valid(en_mano) and en_mano.is_in_group("escudo"):
		return true
	var refugios := get_tree().get_nodes_in_group("refugio")
	for r in refugios:
		if r is Area3D and r.overlaps_body(jugador):
			return true
	if refugios.is_empty():
		return Input.is_action_pressed("crouch")
	return false


func _como_protegerse() -> String:
	if get_tree().get_nodes_in_group("refugio").is_empty():
		return "¡Agáchate para cubrirte!"
	return "¡Ve a la sala blindada!"


func _danar(pct: float) -> void:
	pct = minf(pct, maxf(DANO_MAX_POR_EVENTO - _dano_total, 0.0))
	if pct <= 0.0:
		return
	var g := get_node_or_null("/root/Global")
	if g:
		g.oxigen = maxf(0.0, g.oxigen - OXIGENO_MAX * pct / 100.0)
	_dano_total += pct


func _hud(texto: String, color: Color, segundos: float) -> void:
	var hud := get_tree().get_first_node_in_group("hud")
	if hud and hud.has_method("mostrar_mensaje"):
		hud.mostrar_mensaje(texto, color, segundos)


func _jugador() -> Node3D:
	var escena := get_tree().current_scene
	if escena == null:
		return null
	for n in escena.find_children("*", "CharacterBody3D", true, false):
		if "held_object" in n:
			return n
	return null


func _es_del_soplete(nodo: Node) -> bool:
	var p := nodo.get_parent()
	while p:
		if p.is_in_group("soplete"):
			return true
		p = p.get_parent()
	return false


func _dificultad(nombre: String) -> Dictionary:
	var clave := nombre.strip_edges().to_lower().replace("á", "a").replace("í", "i")
	return DIFICULTADES.get(clave, DIFICULTADES["normal"])


func _texto(valor) -> String:
	return "" if valor == null else str(valor).strip_edges()
