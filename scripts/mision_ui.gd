extends CanvasLayer
## Presentación y pausa de la misión; no contiene reglas de reparación.
signal reiniciar

var estado: Label
var detalle: Label
var velo: ColorRect
var titulo_final: Label
var resumen_final: Label
var boton: Button
var finalizada := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 20
	var raiz := Control.new()
	raiz.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	raiz.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(raiz)
	var panel := PanelContainer.new()
	raiz.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	panel.anchor_right = 0.60
	panel.offset_left = 20
	panel.offset_right = 0
	panel.offset_top = 20
	var estilo := StyleBoxFlat.new()
	estilo.bg_color = Color(0.025, 0.055, 0.09, 0.93)
	estilo.border_color = Color(0.25, 0.7, 0.9)
	estilo.set_border_width_all(1)
	estilo.set_corner_radius_all(10)
	estilo.content_margin_left = 16
	estilo.content_margin_right = 16
	estilo.content_margin_top = 12
	estilo.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", estilo)
	var columna := VBoxContainer.new()
	panel.add_child(columna)
	estado = _label("ENTRENAMIENTO · 03:00", 19)
	columna.add_child(estado)
	detalle = _label("Recoge las tres herramientas de la mesa con E.", 16)
	columna.add_child(detalle)
	var controles := _label("WASD mover · Ratón/flechas mirar · E recoger · 1–6 equipar · Clic mantener · Q soltar · Esc pausa", 13)
	raiz.add_child(controles)
	controles.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	controles.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	controles.offset_left = 175
	controles.offset_right = -16
	controles.offset_top = -125
	controles.offset_bottom = -82
	velo = ColorRect.new()
	velo.color = Color(0.015, 0.03, 0.055, 0.94)
	raiz.add_child(velo)
	velo.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var centro := CenterContainer.new()
	velo.add_child(centro)
	centro.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var caja := VBoxContainer.new()
	caja.custom_minimum_size = Vector2(400, 0)
	caja.add_theme_constant_override("separation", 20)
	centro.add_child(caja)
	titulo_final = _label("MISIÓN EN PAUSA", 30)
	titulo_final.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caja.add_child(titulo_final)
	resumen_final = _label("Pulsa Esc o Continuar para volver.", 18)
	resumen_final.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caja.add_child(resumen_final)
	boton = Button.new()
	boton.text = "Continuar"
	boton.custom_minimum_size.y = 52
	boton.pressed.connect(_accion_boton)
	caja.add_child(boton)
	velo.hide()


func actualizar(encabezado: String, objetivo: String) -> void:
	estado.text = encabezado
	detalle.text = objetivo


func resultado(exito: bool, texto: String) -> void:
	finalizada = true
	titulo_final.text = "MISIÓN COMPLETADA" if exito else "MISIÓN FALLIDA"
	titulo_final.modulate = Color(0.35, 1.0, 0.75) if exito else Color(1.0, 0.48, 0.35)
	resumen_final.text = texto + "\nPulsa R o el botón para intentarlo de nuevo."
	boton.text = "Reiniciar misión"
	velo.show()
	boton.grab_focus()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if finalizada and event.physical_keycode == KEY_R:
			get_viewport().set_input_as_handled()
			reiniciar.emit()
		elif event.physical_keycode == KEY_ESCAPE and not finalizada:
			get_viewport().set_input_as_handled()
			_cambiar_pausa(not get_tree().paused)


func _cambiar_pausa(pausa: bool) -> void:
	# Apaga el soplete aunque se pause mientras el clic sigue presionado.
	for sop in get_tree().get_nodes_in_group("soplete"):
		sop.usar(false)
	get_tree().paused = pausa
	velo.visible = pausa
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE if pausa else Input.MOUSE_MODE_CAPTURED)
	if pausa:
		boton.grab_focus()


func _accion_boton() -> void:
	if finalizada:
		reiniciar.emit()
	else:
		_cambiar_pausa(false)


func _label(texto: String, tamano: int) -> Label:
	var label := Label.new()
	label.text = texto
	label.add_theme_font_size_override("font_size", tamano)
	label.add_theme_color_override("font_color", Color(0.87, 0.95, 1.0))
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label
