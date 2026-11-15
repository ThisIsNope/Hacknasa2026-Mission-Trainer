extends CanvasLayer

## HUD: oxígeno (medidor circular), barra de objetos con tus modelos 3D
## y lista de tareas. Toda la UI nueva se construye por código; solo necesita
## los nodos que ya tienes: $MensajeSoldado e $InfoSoldadura.
## (El $Label viejo del oxígeno se oculta automáticamente.)

signal slot_seleccionado(indice: int, item: Dictionary)
signal tarea_completada(id: String)
signal todas_las_tareas_completadas
signal inventario_cambiado   # se agregó o quitó un objeto

const NUM_SLOTS := 6
const OXIGENO_MAX := 125.0
const ICONO_TAM := 160   # resolución de los iconos generados desde los modelos 3D

const COLOR_FONDO := Color(0.05, 0.08, 0.13, 0.85)
const COLOR_BORDE := Color(0.30, 0.65, 0.90, 0.80)
const COLOR_TEXTO_SUAVE := Color(0.62, 0.78, 0.92)
const COLOR_OK := Color(0.25, 0.90, 0.70)
const COLOR_AVISO := Color(1.0, 0.75, 0.25)
const COLOR_CRITICO := Color(1.0, 0.30, 0.25)
const COLOR_HECHO := Color(0.40, 1.0, 0.50)

## Objetos que se pueden llevar en el inventario.
## "nombre": lo que se ve en pantalla
## "escena": ruta del modelo (según tus archivos .import están en res://models/)
## "tamano": medida en metros del lado más largo del objeto (se escala a esto)
## "mano_rot": giro extra en grados al tenerlo en la mano (el objeto ya se orienta
##   solo con su lado más largo hacia el frente; si queda al revés, pon Vector3(0, 180, 0))
const CATALOGO := {
	"pistola": {"nombre": "Soplete", "escena": "res://models/pistola.blend", "tamano": 0.25, "mano_rot": Vector3(0, 180, 0)},
	"rachet": {"nombre": "Rachet", "escena": "res://models/rachet1.blend", "tamano": 0.28, "mano_rot": Vector3(0, 0, 0)},
	"llave": {"nombre": "Llave inglesa", "escena": "res://models/wrench.blend", "tamano": 0.35, "mano_rot": Vector3(0, 0, 0)},
}

## Tareas de ejemplo: "id": "texto". El id en minúsculas debe coincidir con
## el "nombre" del soldable si quieres que se complete sola al soldarlo.
const TAREAS_DEMO := {
	"panel": "Soldar el panel dañado",
	"reactor": "Reparar el reactor",
	"comunicaciones": "Reparar las comunicaciones",
}

## Pon esto en false cuando ya agregues objetos y tareas desde tu juego.
@export var cargar_demo := true

## Herramientas del CATALOGO que aparecen en el suelo al empezar el nivel, cerca del
## soplete (o delante del jugador si no hay soplete). Déjalo vacío [] para desactivarlo.
@export var herramientas_en_suelo: Array[String] = ["rachet", "llave"]

@onready var mensaje: Label = $MensajeSoldado     # "¡Panel soldado!" arriba al centro
@onready var info: Label = $InfoSoldadura         # "Soldando: 45%" debajo de la mira

var tiempo_info := 0.0
var tween_mensaje: Tween

# --- Oxígeno ---
var medidor: MedidorOxigeno
var label_alerta: Label
var oxigeno_visual := 100.0

# --- Barra de objetos ---
var objetos: Array[Dictionary] = []
var slot_actual := 0
var slot_paneles: Array[PanelContainer] = []
var slot_iconos: Array[TextureRect] = []
var slot_iniciales: Array[Label] = []
var slot_cantidades: Array[Label] = []
var label_item: Label
var label_contexto: Label
var estilo_slot: StyleBoxFlat
var estilo_slot_sel: StyleBoxFlat
var iconos_cache: Dictionary = {}
var iconos_en_proceso: Dictionary = {}

# --- Tareas ---
var tareas: Dictionary = {}
var lista_tareas: VBoxContainer
var barra_tareas: ProgressBar
var label_contador: Label


# =====================================================================
#  MEDIDOR CIRCULAR DE OXÍGENO (se dibuja por código)
# =====================================================================
class MedidorOxigeno extends Control:
	var valor := 100.0
	var color := Color(0.25, 0.90, 0.70)
	var texto := "100%"
	var pulso := 0.0   # 0..1, brillo extra cuando el nivel es crítico

	func _init() -> void:
		custom_minimum_size = Vector2(136, 136)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var centro := size / 2.0
		var radio := minf(size.x, size.y) / 2.0 - 14.0
		var inicio := -PI / 2.0
		var fin := inicio + TAU * clampf(valor / 100.0, 0.0, 1.0)
		var fuente := get_theme_default_font()

		# Disco de fondo con borde
		draw_circle(centro, radio + 12.0, Color(0.04, 0.07, 0.12, 0.88))
		draw_arc(centro, radio + 12.0, 0.0, TAU, 72, Color(0.30, 0.65, 0.90, 0.55), 2.0, true)

		# Marcas alrededor (cada 5%)
		for i in 20:
			var ang := inicio + TAU * float(i) / 20.0
			var d := Vector2.from_angle(ang)
			draw_line(centro + d * (radio - 12.0), centro + d * (radio - 17.0), Color(1, 1, 1, 0.20), 1.5, true)

		# Pista del anillo
		draw_arc(centro, radio, 0.0, TAU, 72, Color(1, 1, 1, 0.09), 10.0, true)

		# Progreso: resplandor + anillo + puntas redondeadas
		if valor > 0.5:
			draw_arc(centro, radio, inicio, fin, 72, Color(color, 0.22 + 0.22 * pulso), 18.0, true)
			draw_arc(centro, radio, inicio, fin, 72, color, 10.0, true)
			draw_circle(centro + Vector2.from_angle(inicio) * radio, 5.0, color)
			draw_circle(centro + Vector2.from_angle(fin) * radio, 5.0, color)

		# Texto central
		draw_string(fuente, Vector2(0, centro.y + 7.0), texto, HORIZONTAL_ALIGNMENT_CENTER, size.x, 28, Color.WHITE)
		draw_string(fuente, Vector2(0, centro.y + 26.0), "OXÍGENO", HORIZONTAL_ALIGNMENT_CENTER, size.x, 11, Color(0.62, 0.78, 0.92))


# =====================================================================
#  HERRAMIENTA EN EL MUNDO (lo que queda al tirarla; se vuelve a tomar con "interact")
# =====================================================================
class HerramientaMundo extends RigidBody3D:
	var id := ""

	## Lo llama el jugador al interactuar (misma tecla con la que agarra objetos).
	func interact(_jugador: Node) -> void:
		var hud = get_tree().get_first_node_in_group("hud")
		if hud and hud.recoger(id):
			queue_free()


# =====================================================================
#  CICLO DE VIDA
# =====================================================================

func _ready() -> void:
	add_to_group("hud")   # ConexionMCP lo usa para mostrar mensajes
	mensaje.visible = false
	info.visible = false
	# Oculta lo viejo del oxígeno de hud.tscn: el cuadro blanco ("Panel") y el
	# texto "100 %" ("Label"). Los reemplaza el nuevo medidor circular.
	for viejo in ["Panel", "Label"]:
		if has_node(viejo):
			get_node(viejo).visible = false

	for i in NUM_SLOTS:
		objetos.append({})

	_construir_ui()
	mensaje.anchor_left = 0.03
	mensaje.anchor_right = 0.65
	mensaje.offset_top = 125
	mensaje.offset_bottom = 195
	mensaje.add_theme_font_size_override("font_size", 20)
	mensaje.add_theme_constant_override("outline_size", 3)

	if cargar_demo:
		_cargar_demo()

	seleccionar_slot(0)
	# Se conecta al final del frame para que todos los soldables ya existan
	_conectar_senales.call_deferred()
	_colocar_herramientas.call_deferred()   # después de que el nivel esté listo


func _process(delta: float) -> void:
	_actualizar_oxigeno(delta)

	# Oculta el progreso si dejaste de soldar
	if tiempo_info > 0.0:
		tiempo_info -= delta
		if tiempo_info <= 0.0:
			info.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var n: int = event.keycode - KEY_1
		if n >= 0 and n < NUM_SLOTS:
			seleccionar_slot(n)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			seleccionar_slot(posmod(slot_actual - 1, NUM_SLOTS))
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			seleccionar_slot(posmod(slot_actual + 1, NUM_SLOTS))


# =====================================================================
#  CONSTRUCCIÓN DE LA UI
# =====================================================================

func _construir_ui() -> void:
	var raiz := Control.new()
	raiz.name = "UIRaiz"
	raiz.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(raiz)
	raiz.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	move_child(raiz, 0)   # los mensajes quedan por encima

	estilo_slot = _estilo(Color(0.05, 0.08, 0.13, 0.80), Color(0.30, 0.65, 0.90, 0.35), 2, 10)
	estilo_slot_sel = _estilo(Color(0.10, 0.20, 0.32, 0.95), Color(0.55, 0.90, 1.0), 3, 10)

	_crear_medidor_oxigeno(raiz)
	_crear_hotbar(raiz)
	_crear_panel_tareas(raiz)
	label_contexto = _crear_label("", 18)
	label_contexto.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label_contexto.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label_contexto.add_theme_color_override("font_outline_color", Color.BLACK)
	label_contexto.add_theme_constant_override("outline_size", 4)
	raiz.add_child(label_contexto)
	label_contexto.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	label_contexto.offset_left = -240
	label_contexto.offset_right = 240
	label_contexto.offset_top = 90
	label_contexto.offset_bottom = 150


func mostrar_contexto(texto: String) -> void:
	label_contexto.text = texto


func _crear_medidor_oxigeno(raiz: Control) -> void:
	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 2)

	medidor = MedidorOxigeno.new()
	vb.add_child(medidor)

	label_alerta = _crear_label("¡OXÍGENO BAJO!", 13, COLOR_CRITICO)
	label_alerta.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label_alerta.modulate.a = 0.0   # se muestra solo en nivel crítico
	vb.add_child(label_alerta)

	raiz.add_child(vb)
	vb.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 16)


func _crear_hotbar(raiz: Control) -> void:
	var contenedor := VBoxContainer.new()
	contenedor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	contenedor.add_theme_constant_override("separation", 6)

	label_item = _crear_label("", 16, COLOR_TEXTO_SUAVE)
	label_item.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	contenedor.add_child(label_item)

	var hotbar := HBoxContainer.new()
	hotbar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hotbar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	hotbar.add_theme_constant_override("separation", 8)
	contenedor.add_child(hotbar)

	for i in NUM_SLOTS:
		var slot := PanelContainer.new()
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.custom_minimum_size = Vector2(56, 56)
		slot.pivot_offset = Vector2(28, 28)
		slot.add_theme_stylebox_override("panel", estilo_slot)

		var contenido := Control.new()
		contenido.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(contenido)

		# Icono del objeto
		var icono := TextureRect.new()
		icono.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icono.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icono.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		contenido.add_child(icono)
		icono.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 6)

		# Iniciales (se muestran si el objeto aún no tiene icono)
		var iniciales := _crear_label("", 22)
		iniciales.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		iniciales.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		contenido.add_child(iniciales)
		iniciales.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

		# Número de tecla (esquina superior izquierda)
		var numero := _crear_label(str(i + 1), 12, Color(0.6, 0.75, 0.9, 0.8))
		numero.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		contenido.add_child(numero)
		numero.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		numero.offset_left = 3
		numero.offset_top = -1

		# Cantidad (esquina inferior derecha)
		var cantidad := _crear_label("", 13, Color(1, 1, 0.8))
		cantidad.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		cantidad.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		contenido.add_child(cantidad)
		cantidad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		cantidad.offset_right = -2
		cantidad.offset_bottom = 2

		hotbar.add_child(slot)
		slot_paneles.append(slot)
		slot_iconos.append(icono)
		slot_iniciales.append(iniciales)
		slot_cantidades.append(cantidad)

	raiz.add_child(contenedor)
	contenedor.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 20)


func _crear_panel_tareas(raiz: Control) -> void:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.custom_minimum_size = Vector2(290, 0)
	panel.add_theme_stylebox_override("panel", _estilo(COLOR_FONDO, COLOR_BORDE, 2, 12, 14))

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)

	var cabecera := HBoxContainer.new()
	vb.add_child(cabecera)

	var titulo := _crear_label("TAREAS", 14, COLOR_TEXTO_SUAVE)
	titulo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cabecera.add_child(titulo)

	label_contador = _crear_label("0/0", 14, COLOR_TEXTO_SUAVE)
	cabecera.add_child(label_contador)

	barra_tareas = ProgressBar.new()
	barra_tareas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	barra_tareas.show_percentage = false
	barra_tareas.min_value = 0.0
	barra_tareas.max_value = 1.0
	barra_tareas.custom_minimum_size = Vector2(0, 8)
	barra_tareas.add_theme_stylebox_override("fill", _estilo(COLOR_HECHO, Color.TRANSPARENT, 0, 4))
	barra_tareas.add_theme_stylebox_override("background", _estilo(Color(0, 0, 0, 0.55), Color(1, 1, 1, 0.08), 1, 4))
	vb.add_child(barra_tareas)

	lista_tareas = VBoxContainer.new()
	lista_tareas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lista_tareas.add_theme_constant_override("separation", 6)
	vb.add_child(lista_tareas)

	raiz.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 20)
	# Que crezca hacia abajo y hacia la izquierda al agregar tareas
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.grow_vertical = Control.GROW_DIRECTION_END


# =====================================================================
#  OXÍGENO
# =====================================================================

func _actualizar_oxigeno(delta: float) -> void:
	var objetivo := clampf(Global.oxigen / OXIGENO_MAX * 100.0, 0.0, 100.0)
	# Suaviza el movimiento del anillo
	oxigeno_visual = lerpf(oxigeno_visual, objetivo, 1.0 - exp(-8.0 * delta))

	# Cian/verde -> ámbar -> rojo según el nivel
	var color: Color
	if objetivo > 50.0:
		color = COLOR_AVISO.lerp(COLOR_OK, clampf(inverse_lerp(50.0, 100.0, objetivo), 0.0, 1.0))
	else:
		color = COLOR_CRITICO.lerp(COLOR_AVISO, clampf(inverse_lerp(15.0, 50.0, objetivo), 0.0, 1.0))

	var critico := objetivo < 25.0
	var parpadeo := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.012)

	medidor.valor = oxigeno_visual
	medidor.color = color
	medidor.texto = "%d%%" % roundi(objetivo)
	medidor.pulso = parpadeo if critico else 0.0
	medidor.queue_redraw()

	label_alerta.modulate.a = parpadeo if critico else 0.0


# =====================================================================
#  BARRA DE OBJETOS
# =====================================================================

## Recoge un objeto del CATALOGO (pistola, rachet, llave). El icono se genera
## solo a partir del modelo 3D la primera vez y queda en caché.
## Ejemplo: hud.recoger("llave")
func recoger(id: String, cantidad: int = 1) -> bool:
	if not CATALOGO.has(id):
		push_warning("HUD: '%s' no está en CATALOGO" % id)
		return false
	var datos: Dictionary = CATALOGO[id]
	var ok := agregar_objeto(id, datos["nombre"], iconos_cache.get(id), cantidad)
	if ok and not iconos_cache.has(id):
		_cargar_icono(id)
	return ok


## Agrega un objeto cualquiera (con icono propio opcional). Si ya existe, suma cantidad.
## Devuelve false si no hay espacio.
func agregar_objeto(id: String, nombre: String, icono: Texture2D = null, cantidad: int = 1) -> bool:
	for i in NUM_SLOTS:
		if objetos[i].get("id", "") == id and not objetos[i].has("nodo"):
			objetos[i]["cantidad"] += cantidad
			_refrescar_slot(i)
			return true
	for i in NUM_SLOTS:
		if objetos[i].is_empty():
			objetos[i] = {"id": id, "nombre": nombre, "icono": icono, "cantidad": cantidad}
			_refrescar_slot(i)
			_actualizar_nombre_item()
			inventario_cambiado.emit()
			return true
	mostrar_mensaje("Barra de objetos llena", COLOR_AVISO)
	return false


## Quita cantidad de un objeto; si llega a 0, el slot queda libre.
func quitar_objeto(id: String, cantidad: int = 1) -> bool:
	for i in NUM_SLOTS:
		if objetos[i].get("id", "") == id:
			objetos[i]["cantidad"] -= cantidad
			if objetos[i]["cantidad"] <= 0:
				objetos[i] = {}
			_refrescar_slot(i)
			_actualizar_nombre_item()
			inventario_cambiado.emit()
			return true
	return false


## Devuelve el primer slot libre, o -1 si la barra está llena.
func slot_libre() -> int:
	for i in NUM_SLOTS:
		if objetos[i].is_empty():
			return i
	return -1


## Guarda un objeto REAL del mundo (por ejemplo el Soplete) en el inventario, sin
## destruirlo: el jugador lo quita de la escena antes y aquí solo se guarda la
## referencia. Devuelve el slot usado, o -1 si no había espacio.
func agregar_nodo(id: String, nodo: Node3D) -> int:
	var i := slot_libre()
	if i < 0:
		mostrar_mensaje("Barra de objetos llena", COLOR_AVISO)
		return -1
	var nombre: String = CATALOGO[id]["nombre"] if CATALOGO.has(id) else id.capitalize()
	objetos[i] = {"id": id, "nombre": nombre, "icono": iconos_cache.get(id), "cantidad": 1, "nodo": nodo}
	_refrescar_slot(i)
	_actualizar_nombre_item()
	if CATALOGO.has(id) and not iconos_cache.has(id):
		_cargar_icono(id)
	inventario_cambiado.emit()
	return i


## Vacía un slot por su índice (no destruye el nodo que tuviera guardado).
func quitar_slot(i: int) -> void:
	objetos[i] = {}
	_refrescar_slot(i)
	_actualizar_nombre_item()
	inventario_cambiado.emit()


func tiene_objeto(id: String) -> bool:
	for item in objetos:
		if item.get("id", "") == id:
			return true
	return false


## Devuelve el diccionario del objeto seleccionado ({} si el slot está vacío).
## Su "id" es el del CATALOGO: "pistola", "rachet" o "llave".
func objeto_seleccionado() -> Dictionary:
	return objetos[slot_actual]


func seleccionar_slot(indice: int) -> void:
	slot_actual = clampi(indice, 0, NUM_SLOTS - 1)
	for i in NUM_SLOTS:
		_refrescar_slot(i)
		var escala := Vector2.ONE * (1.12 if i == slot_actual else 1.0)
		create_tween().tween_property(slot_paneles[i], "scale", escala, 0.12)
	_actualizar_nombre_item()
	slot_seleccionado.emit(slot_actual, objetos[slot_actual])


func _refrescar_slot(i: int) -> void:
	var item: Dictionary = objetos[i]
	var vacio := item.is_empty()
	var icono: Texture2D = null if vacio else item.get("icono")

	slot_iconos[i].texture = icono
	slot_iniciales[i].text = "" if (vacio or icono != null) else str(item["nombre"]).left(2).to_upper()
	slot_cantidades[i].text = "" if (vacio or item["cantidad"] <= 1) else "x%d" % item["cantidad"]
	slot_paneles[i].add_theme_stylebox_override("panel", estilo_slot_sel if i == slot_actual else estilo_slot)
	slot_paneles[i].modulate.a = 0.55 if (vacio and i != slot_actual) else 1.0


func _actualizar_nombre_item() -> void:
	var item: Dictionary = objetos[slot_actual]
	label_item.text = "" if item.is_empty() else str(item["nombre"])


# =====================================================================
#  ICONOS GENERADOS DESDE LOS MODELOS 3D (.blend)
# =====================================================================

func _cargar_icono(id: String) -> void:
	if iconos_en_proceso.has(id):
		return
	iconos_en_proceso[id] = true
	var tex: Texture2D = await _generar_icono(id)
	iconos_cache[id] = tex
	iconos_en_proceso.erase(id)
	for i in NUM_SLOTS:
		if objetos[i].get("id", "") == id:
			objetos[i]["icono"] = tex
			_refrescar_slot(i)


## Renderiza el modelo en un SubViewport transparente y devuelve la imagen.
## Si el modelo no carga, devuelve null y el slot muestra las iniciales.
func _generar_icono(id: String) -> Texture2D:
	var modelo := crear_modelo(id, 1.0)   # todos los iconos parten del mismo tamaño
	if modelo == null:
		return null

	var vp := SubViewport.new()
	vp.size = Vector2i(ICONO_TAM, ICONO_TAM)
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(vp)

	# Modelo con una rotación 3/4 para que se vea bien
	var pivote := Node3D.new()
	vp.add_child(pivote)
	pivote.add_child(modelo)
	pivote.rotation_degrees = Vector3(-20.0, -35.0, 0.0)

	# Caja que envuelve todas las mallas, para encuadrar la cámara
	var caja := AABB()
	var primera := true
	for nodo in pivote.find_children("*", "MeshInstance3D", true, false):
		var malla := nodo as MeshInstance3D
		var a: AABB = malla.global_transform * malla.get_aabb()
		caja = a if primera else caja.merge(a)
		primera = false
	if primera:
		push_warning("HUD: el modelo '%s' no tiene mallas" % id)
		vp.queue_free()
		return null

	var centro := caja.get_center()
	var radio := maxf(caja.size.length() * 0.5, 0.001)

	var cam := Camera3D.new()
	cam.fov = 30.0
	var dist := radio / sin(deg_to_rad(cam.fov * 0.5)) * 1.05
	cam.near = dist * 0.1
	cam.far = dist * 3.0
	var env := Environment.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.80, 0.86, 1.0)
	env.ambient_light_energy = 0.7
	cam.environment = env
	vp.add_child(cam)
	cam.look_at_from_position(centro + Vector3(0, 0, dist), centro, Vector3.UP)
	cam.current = true

	var luz := DirectionalLight3D.new()
	luz.rotation_degrees = Vector3(-40.0, -30.0, 0.0)
	luz.light_energy = 1.3
	vp.add_child(luz)

	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw

	var img := vp.get_texture().get_image()
	vp.queue_free()
	if img == null or img.is_invisible():
		# Salió vacío: mejor mostrar las iniciales que un icono invisible
		push_warning("HUD: el icono de '%s' salió vacío" % id)
		return null
	return ImageTexture.create_from_image(img)


# =====================================================================
#  MODELOS 3D ESCALADOS Y CENTRADOS
# =====================================================================

## Devuelve una instancia del modelo del CATALOGO, centrada en su origen y
## escalada para que su lado más largo mida `tamano` metros (si no lo das,
## usa el "tamano" del CATALOGO). Sirve para ponerla en la mano, soltarla, etc.
## Ejemplo: hold_point.add_child(hud.crear_modelo("llave"))
## Con orientar_al_frente = true, el lado más largo del objeto apunta hacia -Z (adelante).
func crear_modelo(id: String, tamano: float = -1.0, orientar_al_frente: bool = false) -> Node3D:
	if not CATALOGO.has(id):
		push_warning("HUD: '%s' no está en CATALOGO" % id)
		return null
	var ruta: String = CATALOGO[id]["escena"]
	var recurso = load(ruta)
	if not (recurso is PackedScene):
		push_warning("HUD: no se pudo cargar el modelo %s" % ruta)
		return null
	var modelo := (recurso as PackedScene).instantiate() as Node3D
	if modelo == null:
		push_warning("HUD: la raíz de %s no es un Node3D" % ruta)
		return null

	# Quita luces y cámaras que vienen dentro del .blend (alterarían el icono y la escena)
	for tipo in ["Light3D", "Camera3D"]:
		for nodo in modelo.find_children("*", tipo, true, false):
			if is_instance_valid(nodo) and nodo.get_parent() != null:
				nodo.get_parent().remove_child(nodo)
				nodo.free()

	var caja := _aabb_modelo(modelo)
	var maximo := maxf(caja.size.x, maxf(caja.size.y, caja.size.z))
	if maximo <= 0.0001:
		push_warning("HUD: el modelo '%s' no tiene mallas visibles" % id)
		return modelo

	var objetivo: float = tamano if tamano > 0.0 else float(CATALOGO[id].get("tamano", 0.3))
	var envoltorio := Node3D.new()
	envoltorio.name = "Modelo_" + id
	var orientador := Node3D.new()
	orientador.name = "Orientador"
	envoltorio.add_child(orientador)
	orientador.add_child(modelo)
	modelo.position -= caja.get_center()                  # centrado en el origen

	if orientar_al_frente:
		if caja.size.x >= caja.size.y and caja.size.x >= caja.size.z:
			orientador.basis = Basis(Vector3.UP, deg_to_rad(90.0))      # X -> -Z
		elif caja.size.y >= caja.size.z:
			orientador.basis = Basis(Vector3.RIGHT, deg_to_rad(-90.0))  # Y -> -Z

	envoltorio.scale = Vector3.ONE * (objetivo / maximo)  # tamaño real
	return envoltorio


## Modelo listo para ponerlo en la mano del jugador: escalado, orientado hacia
## el frente, con el giro extra "mano_rot" del CATALOGO y sin sombras.
## Ejemplo: mano.add_child(hud.crear_modelo_mano("llave"))
func crear_modelo_mano(id: String) -> Node3D:
	var m := crear_modelo(id, -1.0, true)
	if m == null:
		return null
	if CATALOGO.has(id):
		m.rotation_degrees = CATALOGO[id].get("mano_rot", Vector3.ZERO)
	for malla in m.find_children("*", "GeometryInstance3D", true, false):
		var g := malla as GeometryInstance3D
		g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Capa 2: la luz "LuzMano" del jugador solo ilumina esto, así el objeto se ve
		# aunque el nivel sea oscuro (en main.tscn la luz ambiente es 0).
		g.layers = 2
	return m


## Prepara un objeto REAL del mundo (el Soplete con su script) para llevarlo en la
## mano: lo congela (sin física ni colisión) y lo deja alineado con la cámara. Si
## `ocultar` es true, oculta sus mallas: lo que se VE en la mano es el modelo del
## CATALOGO (crear_modelo_mano), y el nodo real solo aporta su lógica (soldar, etc.).
## Guarda su escala, colisiones y mallas ocultas para restaurarlas al soltarlo.
func preparar_nodo_logico(nodo: Node3D, ocultar: bool = true) -> void:
	if not nodo.has_meta("inv_orig"):
		var orig := {"escala": nodo.scale}
		if nodo is CollisionObject3D:
			orig["layer"] = (nodo as CollisionObject3D).collision_layer
			orig["mask"] = (nodo as CollisionObject3D).collision_mask
		nodo.set_meta("inv_orig", orig)
	_congelar(nodo)
	nodo.transform = Transform3D.IDENTITY

	if ocultar:
		var ocultos: Array = nodo.get_meta("inv_ocultos", [])
		for malla in nodo.find_children("*", "MeshInstance3D", true, false):
			var m := malla as MeshInstance3D
			if m.visible:
				m.visible = false
				ocultos.append(m)
		nodo.set_meta("inv_ocultos", ocultos)


## Devuelve a un objeto real su escala, colisiones y física originales (para
## volver a ponerlo en el mundo). La posición la fija el jugador después.
func restaurar_nodo_mundo(nodo: Node3D) -> void:
	var orig: Dictionary = nodo.get_meta("inv_orig", {})
	nodo.transform = Transform3D(Basis.from_scale(orig.get("escala", Vector3.ONE)), Vector3.ZERO)
	if nodo is CollisionObject3D:
		(nodo as CollisionObject3D).collision_layer = orig.get("layer", 1)
		(nodo as CollisionObject3D).collision_mask = orig.get("mask", 1)
	if nodo is RigidBody3D:
		(nodo as RigidBody3D).freeze = false
	# Vuelve a mostrar las mallas que se ocultaron mientras estaba en la mano
	var ocultos: Array = nodo.get_meta("inv_ocultos", [])
	for m in ocultos:
		if is_instance_valid(m):
			(m as MeshInstance3D).visible = true
	nodo.remove_meta("inv_ocultos")


func _congelar(nodo: Node) -> void:
	if nodo is CollisionObject3D:
		(nodo as CollisionObject3D).collision_layer = 0
		(nodo as CollisionObject3D).collision_mask = 0
	if nodo is RigidBody3D:
		var rb := nodo as RigidBody3D
		rb.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		rb.freeze = true
		rb.linear_velocity = Vector3.ZERO
		rb.angular_velocity = Vector3.ZERO


## Crea la herramienta como objeto físico del mundo (RigidBody3D con colisión),
## lista para agregarla a la escena. Al interactuar con ella vuelve al inventario.
## Ejemplo: escena.add_child(hud.crear_herramienta("llave"))
## `factor` la agranda en niveles donde el jugador está escalado (p. ej. 2.82).
func crear_herramienta(id: String, factor: float = 1.0) -> RigidBody3D:
	var modelo := crear_modelo(id)
	if modelo == null:
		return null
	var caja := _aabb_modelo(modelo)
	caja.size *= factor
	modelo.scale = modelo.scale * factor

	var cuerpo := HerramientaMundo.new()
	cuerpo.id = id
	cuerpo.name = "Herramienta_" + id
	cuerpo.mass = 0.5
	cuerpo.continuous_cd = true   # evita que atraviese el piso por ser pequeña

	var forma := CollisionShape3D.new()
	var caja_forma := BoxShape3D.new()
	var minimo := 0.04 * factor
	caja_forma.size = Vector3(maxf(caja.size.x, minimo), maxf(caja.size.y, minimo), maxf(caja.size.z, minimo))
	forma.shape = caja_forma
	cuerpo.add_child(forma)
	cuerpo.add_child(modelo)
	return cuerpo


## Hace aparecer una herramienta del CATALOGO en el mundo (cae al piso por física).
## Ejemplo: hud.aparecer_herramienta("llave", Vector3(2, 1, -5))
func aparecer_herramienta(id: String, posicion: Vector3, factor: float = 1.0) -> RigidBody3D:
	var h := crear_herramienta(id, factor)
	if h == null:
		return null
	get_tree().current_scene.add_child(h)
	h.global_position = posicion
	return h


## Coloca las herramientas de `herramientas_en_suelo` cerca del soplete; si no hay
## soplete, delante del jugador. El tamaño se ajusta a la escala del jugador del nivel.
func _colocar_herramientas() -> void:
	if herramientas_en_suelo.is_empty():
		return
	var escena := get_tree().current_scene
	if escena == null:
		return
	var jugador := escena.get_node_or_null("player") as Node3D
	var factor := 1.0
	if jugador:
		factor = jugador.global_basis.get_scale().x

	var soplete := get_tree().get_first_node_in_group("soplete") as Node3D
	if soplete == null:
		soplete = escena.find_child("Soplete", true, false) as Node3D

	var base: Vector3
	if soplete:
		base = soplete.global_position + Vector3(0, 1.0 * factor, 1.0 * factor)
	elif jugador:
		base = jugador.global_position + (-jugador.global_basis.z) * 2.0 * factor + Vector3(0, 1.0 * factor, 0)
	else:
		return

	var n := herramientas_en_suelo.size()
	for i in n:
		var lado := (float(i) - (n - 1) / 2.0) * 1.2 * factor
		aparecer_herramienta(herramientas_en_suelo[i], base + Vector3(lado, 0, 0), factor)


## Igual que crear_modelo, pero del objeto que está seleccionado en la barra.
func crear_modelo_seleccionado() -> Node3D:
	var item: Dictionary = objetos[slot_actual]
	if item.is_empty() or not CATALOGO.has(item["id"]):
		return null
	return crear_modelo(item["id"])


func _aabb_modelo(modelo: Node3D) -> AABB:
	var cajas: Array[AABB] = []
	_recoger_aabb(modelo, Transform3D.IDENTITY, cajas)
	if cajas.is_empty():
		return AABB()
	var total := cajas[0]
	for c in cajas:
		total = total.merge(c)
	return total


func _recoger_aabb(nodo: Node, acumulada: Transform3D, cajas: Array[AABB]) -> void:
	var t := acumulada
	if nodo is Node3D:
		t = acumulada * (nodo as Node3D).transform
	if nodo is MeshInstance3D and (nodo as MeshInstance3D).visible:
		cajas.append(t * (nodo as MeshInstance3D).get_aabb())
	for hijo in nodo.get_children():
		_recoger_aabb(hijo, t, cajas)


# =====================================================================
#  TAREAS
# =====================================================================

## Agrega una tarea a la lista. Ejemplo: hud.agregar_tarea("reactor", "Reparar el reactor")
func agregar_tarea(id: String, texto: String) -> void:
	id = id.to_lower()
	if tareas.has(id):
		return

	var fila := HBoxContainer.new()
	fila.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fila.add_theme_constant_override("separation", 10)

	var caja := Panel.new()
	caja.mouse_filter = Control.MOUSE_FILTER_IGNORE
	caja.custom_minimum_size = Vector2(16, 16)
	caja.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	caja.add_theme_stylebox_override("panel", _estilo(Color(0, 0, 0, 0.35), COLOR_BORDE, 2, 4))
	fila.add_child(caja)

	var lbl := _crear_label(texto, 15)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size = Vector2(220, 0)
	fila.add_child(lbl)

	lista_tareas.add_child(fila)
	tareas[id] = {"hecha": false, "caja": caja, "label": lbl}
	_actualizar_progreso_tareas()


## Marca una tarea como completada.
func completar_tarea(id: String) -> void:
	id = id.to_lower()
	if not tareas.has(id):
		return
	var t: Dictionary = tareas[id]
	if t["hecha"]:
		return
	t["hecha"] = true
	t["caja"].add_theme_stylebox_override("panel", _estilo(COLOR_HECHO, COLOR_HECHO, 2, 4))
	t["label"].add_theme_color_override("font_color", Color(0.55, 0.65, 0.60))
	_actualizar_progreso_tareas()
	tarea_completada.emit(id)

	if _todas_las_tareas_hechas():
		mostrar_mensaje("¡Todas las tareas completadas!", COLOR_HECHO, 4.0)
		todas_las_tareas_completadas.emit()


func _todas_las_tareas_hechas() -> bool:
	if tareas.is_empty():
		return false
	for t in tareas.values():
		if not t["hecha"]:
			return false
	return true


func _actualizar_progreso_tareas() -> void:
	var hechas := 0
	for t in tareas.values():
		if t["hecha"]:
			hechas += 1
	label_contador.text = "%d/%d" % [hechas, tareas.size()]
	barra_tareas.max_value = maxi(tareas.size(), 1)
	create_tween().tween_property(barra_tareas, "value", float(hechas), 0.3)


# =====================================================================
#  SEÑALES Y MENSAJES (lo que ya tenías)
# =====================================================================

func _conectar_senales() -> void:
	for s in get_tree().get_nodes_in_group("soldable"):
		conectar_reparable(s)
	for sop in get_tree().get_nodes_in_group("soplete"):
		sop.sin_combustible.connect(_on_sin_combustible)


func conectar_reparable(objeto: Node) -> void:
	var terminado := Callable(self, "_on_soldado").bind(objeto)
	if not objeto.is_connected("soldado", terminado):
		objeto.connect("soldado", terminado)
	if not objeto.is_connected("progreso_cambiado", _on_progreso):
		objeto.connect("progreso_cambiado", _on_progreso)


func _on_progreso(valor: float) -> void:
	var es_soplete := str(objeto_seleccionado().get("id", "")) == "pistola"
	var texto := ("Soldando: %d%%" if es_soplete else "Reparando: %d%%") % int(valor)
	var sop = get_tree().get_first_node_in_group("soplete")
	if sop and es_soplete:
		texto += "   |   Combustible: %d%%" % int(sop.combustible / sop.combustible_max * 100.0)
	info.text = texto
	info.visible = true
	tiempo_info = 0.3


func _on_soldado(objeto: Node) -> void:
	info.visible = false
	tiempo_info = 0.0
	mostrar_mensaje("¡%s reparado!" % objeto.nombre, Color(0.4, 1.0, 0.5))
	# Si existe una tarea con el mismo id que el nombre del soldable, se completa sola
	var id: String = str(objeto.get("tarea_id"))
	completar_tarea(id if not id.is_empty() else str(objeto.nombre))


func _on_sin_combustible() -> void:
	mostrar_mensaje("Sin combustible", Color(1.0, 0.4, 0.3))


## Muestra un mensaje grande arriba al centro y lo desvanece.
func mostrar_mensaje(texto: String, color: Color = Color.WHITE, segundos: float = 3.0) -> void:
	mensaje.text = texto
	mensaje.add_theme_color_override("font_color", color)
	mensaje.modulate.a = 1.0
	mensaje.visible = true
	if tween_mensaje:
		tween_mensaje.kill()
	tween_mensaje = create_tween()
	tween_mensaje.tween_interval(segundos)
	tween_mensaje.tween_property(mensaje, "modulate:a", 0.0, 0.5)
	tween_mensaje.tween_callback(mensaje.hide)


# =====================================================================
#  UTILIDADES
# =====================================================================

func _cargar_demo() -> void:
	# Los objetos ya no se cargan aquí: la pistola es el Soplete real del nivel y
	# rachet y llave aparecen en el suelo (ver herramientas_en_suelo). Todo se toma
	# del suelo con la tecla de interactuar.
	for id in TAREAS_DEMO:
		agregar_tarea(id, TAREAS_DEMO[id])


func _estilo(bg: Color, borde: Color = Color.TRANSPARENT, grosor: int = 0, radio: int = 8, margen: int = 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = borde
	s.set_border_width_all(grosor)
	s.set_corner_radius_all(radio)
	s.set_content_margin_all(margen)
	return s


func _crear_label(texto: String, tamano: int = 16, color: Color = Color.WHITE) -> Label:
	var l := Label.new()
	l.text = texto
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", tamano)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	return l


# =====================================================================
#  JORNADA DIARIA (lo usa scripts/jornada.gd)
# =====================================================================

## Quita todas las tareas (las de ejemplo incluidas) para poner las de la jornada.
func limpiar_tareas() -> void:
	for t in tareas.values():
		var fila: Node = t["caja"].get_parent()
		if is_instance_valid(fila):
			fila.queue_free()
	tareas.clear()
	_actualizar_progreso_tareas()


## Marca una tarea como fallida (cuadro rojo y texto apagado). No cuenta como hecha.
func fallar_tarea(id: String) -> void:
	id = id.to_lower()
	if not tareas.has(id) or tareas[id]["hecha"]:
		return
	var t: Dictionary = tareas[id]
	t["caja"].add_theme_stylebox_override("panel", _estilo(COLOR_CRITICO, COLOR_CRITICO, 2, 4))
	t["label"].add_theme_color_override("font_color", Color(0.75, 0.50, 0.48))


## Quita una tarea del panel (las reparaciones de un evento al terminar).
func quitar_tarea(id: String) -> void:
	id = id.to_lower()
	if not tareas.has(id):
		return
	var fila: Node = tareas[id]["caja"].get_parent()
	if is_instance_valid(fila):
		fila.queue_free()
	tareas.erase(id)
	_actualizar_progreso_tareas()
