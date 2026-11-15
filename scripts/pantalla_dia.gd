extends CanvasLayer
## Tarjeta de la jornada diaria: al empezar (lista de misiones) y al terminar
## (resumen + bono). La crea jornada.gd. Va en su propia capa, debajo del ranking.

signal cerrada

const COLOR_FONDO := Color(0.05, 0.08, 0.13, 0.92)
const COLOR_BORDE := Color(0.30, 0.65, 0.90, 0.80)
const COLOR_TEXTO := Color(0.85, 0.92, 1.0)
const COLOR_SUAVE := Color(0.62, 0.78, 0.92)
const COLOR_BIEN := Color(0.40, 1.0, 0.60)
const COLOR_MAL := Color(1.0, 0.45, 0.40)
const COLOR_AMBAR := Color(1.0, 0.82, 0.30)

var _panel: PanelContainer
var _titulo: Label
var _subtitulo: Label
var _lista: VBoxContainer
var _bono: Label
var _pie: Label
var _cerrar_en := 0.0
var _tween: Tween


func _ready() -> void:
	layer = 19
	process_mode = Node.PROCESS_MODE_ALWAYS
	_construir()
	_panel.visible = false


func _process(delta: float) -> void:
	if _cerrar_en > 0.0:
		_cerrar_en -= delta
		if _cerrar_en <= 0.0:
			ocultar()


func ocupada() -> bool:
	return _panel.visible


func mostrar_inicio(fecha: String, misiones: Array, segundos_primera: float) -> void:
	_limpiar()
	_titulo.text = "JORNADA DEL %s" % _fecha_corta(fecha)
	_subtitulo.text = "%d misiones · clima espacial real de la NASA" % misiones.size()
	_subtitulo.add_theme_color_override("font_color", COLOR_SUAVE)
	for i in misiones.size():
		var m: Dictionary = misiones[i]
		_lista.add_child(_label("%d.  %s" % [i + 1, m.get("titulo", "")], COLOR_TEXTO, 18))
	_bono.visible = false
	_pie.text = "Primera misión en %d s · toma el soplete" % int(segundos_primera)
	_mostrar(9.0)


func mostrar_fin(r: Dictionary) -> void:
	_limpiar()
	var n := int(r.get("misiones", 0))
	var ok := int(r.get("superadas", 0))
	_titulo.text = "JORNADA TERMINADA"
	_subtitulo.text = "%d de %d misiones superadas" % [ok, n]
	_subtitulo.add_theme_color_override("font_color", COLOR_BIEN if ok == n else COLOR_AMBAR)
	for d in r.get("detalle", []):
		if not (d is Dictionary):
			continue
		var res := str(d.get("resultado", ""))
		var marca := "OK" if res == "superado" else "X"
		var color := COLOR_BIEN if res == "superado" else COLOR_MAL
		_lista.add_child(_label("%s   %s" % [marca, d.get("titulo", "")], color, 17))
	var seg := int(r.get("tiempo_seg", 0))
	_lista.add_child(_label("Daño total %d%%  ·  Tiempo %d:%02d" % [
		int(r.get("dano_total_pct", 0)), seg / 60, seg % 60], COLOR_SUAVE, 16))
	_bono.visible = true
	_bono.text = "Calculando bono…"
	_bono.add_theme_color_override("font_color", COLOR_SUAVE)
	_pie.text = "El ranking aparece en unos segundos"
	_mostrar(10.0)


func poner_bono(bono, repetida: bool) -> void:
	_bono.visible = true
	if repetida:
		_bono.text = "Ya habías completado la jornada de hoy: esta no suma puntos"
		_bono.add_theme_color_override("font_color", COLOR_AMBAR)
	elif bono == null:
		_bono.text = "Sin conexión: la jornada no se guardó"
		_bono.add_theme_color_override("font_color", COLOR_MAL)
	else:
		_bono.text = "+%d pts de bono de jornada" % int(bono)
		_bono.add_theme_color_override("font_color", COLOR_BIEN)


func mostrar_aviso(titulo: String, texto: String) -> void:
	_limpiar()
	_titulo.text = titulo
	_subtitulo.text = texto
	_subtitulo.add_theme_color_override("font_color", COLOR_SUAVE)
	_bono.visible = false
	_pie.text = ""
	_mostrar(6.0)


func ocultar() -> void:
	_cerrar_en = 0.0
	if not _panel.visible:
		return
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_panel, "modulate:a", 0.0, 0.3)
	_tween.tween_callback(func():
		_panel.hide()
		cerrada.emit())


# ---------------------------------------------------------------- interno

func _mostrar(segundos: float) -> void:
	_cerrar_en = segundos
	if _tween:
		_tween.kill()
	if not _panel.visible:
		_panel.modulate.a = 0.0
		_panel.visible = true
	_tween = create_tween()
	_tween.tween_property(_panel, "modulate:a", 1.0, 0.3)


func _limpiar() -> void:
	for hijo in _lista.get_children():
		_lista.remove_child(hijo)
		hijo.queue_free()


func _fecha_corta(fecha: String) -> String:
	var partes := fecha.split("-")
	if partes.size() == 3:
		return "%s/%s" % [partes[2], partes[1]]
	return fecha


func _construir() -> void:
	var raiz := Control.new()
	raiz.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(raiz)
	raiz.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.custom_minimum_size = Vector2(520, 0)
	var estilo := StyleBoxFlat.new()
	estilo.bg_color = COLOR_FONDO
	estilo.border_color = COLOR_BORDE
	estilo.set_border_width_all(2)
	estilo.set_corner_radius_all(14)
	estilo.set_content_margin_all(18)
	_panel.add_theme_stylebox_override("panel", estilo)

	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 8)
	_panel.add_child(vb)

	_titulo = _label("", COLOR_TEXTO, 26, HORIZONTAL_ALIGNMENT_CENTER)
	vb.add_child(_titulo)
	_subtitulo = _label("", COLOR_SUAVE, 19, HORIZONTAL_ALIGNMENT_CENTER)
	vb.add_child(_subtitulo)
	_lista = VBoxContainer.new()
	_lista.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lista.add_theme_constant_override("separation", 4)
	vb.add_child(_lista)
	_bono = _label("", COLOR_BIEN, 22, HORIZONTAL_ALIGNMENT_CENTER)
	vb.add_child(_bono)
	_pie = _label("", COLOR_SUAVE, 15, HORIZONTAL_ALIGNMENT_CENTER)
	vb.add_child(_pie)

	raiz.add_child(_panel)
	# Arriba al centro, debajo de los mensajes del HUD
	_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.position.y = 110


func _label(texto: String, color: Color, tamano: int,
		alineado: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = texto
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.horizontal_alignment = alineado
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(480, 0)
	l.add_theme_font_size_override("font_size", tamano)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("outline_size", 4)
	return l
