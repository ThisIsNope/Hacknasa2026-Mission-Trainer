extends CanvasLayer
## Panel "RANKING DE SALAS" dentro de la partida.
## Lo crea ConexionMCP cuando el juego está en una sala (?sala=CODIGO). Los datos los
## manda el relay al terminar cada evento de la NASA ({"tipo": "ranking", ...}).
##  - Aparece solo unos segundos al llegar un ranking nuevo.
##  - Tab o el botón "RANKING" (arriba a la izquierda) lo abren o lo cierran cuando
##    quieras; siempre piden el ranking actualizado al relay.
## Va en su propio CanvasLayer, así que no depende de hud.tscn / hud.gd.

signal pedir_ranking

const SEGUNDOS_AUTO := 8.0
const COLOR_FONDO := Color(0.05, 0.08, 0.13, 0.90)
const COLOR_BORDE := Color(0.30, 0.65, 0.90, 0.80)
const COLOR_TEXTO := Color(0.85, 0.92, 1.0)
const COLOR_SUAVE := Color(0.62, 0.78, 0.92)
const COLOR_TU_SALA := Color(1.0, 0.82, 0.30)
const COLOR_PUNTOS := Color(0.40, 1.0, 0.60)

var _panel: PanelContainer
var _titulo: Label
var _subtitulo: Label
var _tabla: GridContainer
var _pie: Label
var _boton: Button
var _datos: Dictionary = {}
var _tween: Tween
var _cerrar_en := 0.0


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	_construir()
	_panel.visible = false


func _process(delta: float) -> void:
	if _cerrar_en > 0.0:
		_cerrar_en -= delta
		if _cerrar_en <= 0.0:
			ocultar()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and (event.physical_keycode == KEY_TAB or event.keycode == KEY_TAB):
		get_viewport().set_input_as_handled()
		alternar()


## Abre el panel pidiendo el ranking del momento, o lo cierra si ya está abierto.
func alternar() -> void:
	if _panel.visible:
		ocultar()
	else:
		pedir_ranking.emit()   # el relay contesta con el ranking actual de todas las salas
		mostrar(0.0)


## Llega un ranking del relay. Si trae puntos de un evento recién terminado, se muestra solo.
func actualizar(datos: Dictionary) -> void:
	_datos = datos
	_rellenar()
	if datos.get("puntos_ganados") != null:
		mostrar(SEGUNDOS_AUTO)
	elif _panel.visible:
		mostrar(_cerrar_en)


## segundos <= 0: queda abierto hasta que se presione Tab.
func mostrar(segundos: float) -> void:
	_rellenar()
	_cerrar_en = segundos
	if _panel.visible:
		return
	_panel.visible = true
	_panel.modulate.a = 0.0
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_panel, "modulate:a", 1.0, 0.25)


func ocultar() -> void:
	_cerrar_en = 0.0
	if not _panel.visible:
		return
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_panel, "modulate:a", 0.0, 0.25)
	_tween.tween_callback(_panel.hide)


# ---------------------------------------------------------------- contenido

func _rellenar() -> void:
	for hijo in _tabla.get_children():
		_tabla.remove_child(hijo)
		hijo.queue_free()

	if _datos.is_empty():
		_titulo.text = "RANKING DE SALAS"
		_subtitulo.text = "Cargando… (termina un evento de la NASA para aparecer)"
		_pie.text = "Tab para cerrar"
		return

	var tu_sala := str(_datos.get("tu_sala", ""))
	var propia = _datos.get("tu_posicion")
	var ganados = _datos.get("puntos_ganados")
	var total := int(_datos.get("total_salas", 0))

	_titulo.text = "RANKING DE SALAS"
	if ganados != null:
		_subtitulo.text = "+%d pts en este evento" % int(ganados)
		_subtitulo.add_theme_color_override("font_color", COLOR_PUNTOS)
	else:
		_subtitulo.text = "Sala %s" % tu_sala
		_subtitulo.add_theme_color_override("font_color", COLOR_SUAVE)

	for encabezado in ["#", "Sala", "Puntos", "Superados"]:
		var alineado := HORIZONTAL_ALIGNMENT_LEFT if encabezado == "Sala" else HORIZONTAL_ALIGNMENT_RIGHT
		_tabla.add_child(_celda(encabezado, COLOR_SUAVE, 15, alineado))

	var top: Array = _datos.get("top", [])
	var tu_en_top := false
	for fila in top:
		if not (fila is Dictionary):
			continue
		var es_tuya := str(fila.get("sala", "")) == tu_sala
		tu_en_top = tu_en_top or es_tuya
		_agregar_fila(fila, es_tuya)
	if propia is Dictionary and not tu_en_top:
		for i in 4:
			_tabla.add_child(_celda("…" if i == 0 else "", COLOR_SUAVE, 12))
		_agregar_fila(propia, true)
	if top.is_empty():
		_subtitulo.text = "Todavía no hay partidas en el ranking"

	if propia is Dictionary and total > 0:
		_pie.text = "Vas en %d.º de %d salas  ·  Tab para cerrar" % [int(propia.get("pos", 0)), total]
	else:
		_pie.text = "Tab para cerrar"


func _agregar_fila(fila: Dictionary, es_tuya: bool) -> void:
	var color := COLOR_TU_SALA if es_tuya else COLOR_TEXTO
	_tabla.add_child(_celda("%d" % int(fila.get("pos", 0)), color, 18))
	var nombre := str(fila.get("sala", ""))
	_tabla.add_child(_celda(nombre + ("  (tú)" if es_tuya else ""), color, 18, HORIZONTAL_ALIGNMENT_LEFT))
	_tabla.add_child(_celda("%d" % int(fila.get("puntos", 0)), COLOR_PUNTOS if es_tuya else color, 18))
	_tabla.add_child(_celda("%d" % int(fila.get("superados", 0)), color, 18))


# ---------------------------------------------------------------- construcción

func _construir() -> void:
	var raiz := Control.new()
	raiz.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(raiz)
	raiz.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.custom_minimum_size = Vector2(460, 0)
	var estilo := StyleBoxFlat.new()
	estilo.bg_color = COLOR_FONDO
	estilo.border_color = COLOR_BORDE
	estilo.set_border_width_all(2)
	estilo.set_corner_radius_all(14)
	estilo.set_content_margin_all(16)
	_panel.add_theme_stylebox_override("panel", estilo)

	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 6)
	_panel.add_child(vb)

	_titulo = _celda("RANKING DE SALAS", COLOR_TEXTO, 26, HORIZONTAL_ALIGNMENT_CENTER)
	vb.add_child(_titulo)
	_subtitulo = _celda("", COLOR_SUAVE, 20, HORIZONTAL_ALIGNMENT_CENTER)
	vb.add_child(_subtitulo)

	_tabla = GridContainer.new()
	_tabla.columns = 4
	_tabla.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tabla.add_theme_constant_override("h_separation", 22)
	_tabla.add_theme_constant_override("v_separation", 2)
	vb.add_child(_tabla)

	_pie = _celda("", COLOR_SUAVE, 15, HORIZONTAL_ALIGNMENT_CENTER)
	vb.add_child(_pie)

	raiz.add_child(_panel)
	_crear_boton(raiz)
	_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_panel.position.y -= 40   # un poco arriba para no tapar la barra de objetos


## Botón fijo arriba a la izquierda. Con el ratón capturado (jugando) no se puede
## hacer clic: se usa Tab, o Esc para soltar el ratón y luego clic en el botón.
func _crear_boton(raiz: Control) -> void:
	_boton = Button.new()
	_boton.text = "RANKING  [Tab]"
	_boton.focus_mode = Control.FOCUS_NONE   # que Espacio/Enter no lo activen al jugar
	_boton.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_boton.add_theme_font_size_override("font_size", 16)
	_boton.add_theme_color_override("font_color", COLOR_TEXTO)
	_boton.add_theme_color_override("font_hover_color", COLOR_TU_SALA)
	_boton.add_theme_color_override("font_pressed_color", COLOR_TU_SALA)
	for estado in ["normal", "hover", "pressed"]:
		var e := StyleBoxFlat.new()
		e.bg_color = COLOR_FONDO if estado == "normal" else Color(0.10, 0.20, 0.32, 0.95)
		e.border_color = COLOR_BORDE if estado == "normal" else COLOR_TU_SALA
		e.set_border_width_all(2)
		e.set_corner_radius_all(10)
		e.content_margin_left = 14
		e.content_margin_right = 14
		e.content_margin_top = 8
		e.content_margin_bottom = 8
		_boton.add_theme_stylebox_override(estado, e)
	_boton.pressed.connect(alternar)
	raiz.add_child(_boton)
	_boton.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT, Control.PRESET_MODE_MINSIZE, 20)


func _celda(texto: String, color: Color, tamano: int = 20,
		alineado: HorizontalAlignment = HORIZONTAL_ALIGNMENT_RIGHT) -> Label:
	var l := Label.new()
	l.text = texto
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.horizontal_alignment = alineado
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL if alineado == HORIZONTAL_ALIGNMENT_LEFT else Control.SIZE_FILL
	l.add_theme_font_size_override("font_size", tamano)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("outline_size", 4)
	return l
