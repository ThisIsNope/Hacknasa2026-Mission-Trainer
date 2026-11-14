extends CanvasLayer

@onready var mensaje: Label = $MensajeSoldado     # "¡Panel soldado!" arriba al centro
@onready var info: Label = $InfoSoldadura         # "Soldando: 45%" debajo de la mira

var ox = 100
var tiempo_info := 0.0
var tween_mensaje: Tween


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	ox = 100
	mensaje.visible = false
	info.visible = false
	# Se conecta al final del frame para que todos los soldables ya existan
	_conectar_senales.call_deferred()


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	$Label.text = str(int((Global.oxigen / 125.0) * 100)) + "%"

	# Oculta el progreso si dejaste de soldar
	if tiempo_info > 0.0:
		tiempo_info -= delta
		if tiempo_info <= 0.0:
			info.visible = false


func _conectar_senales() -> void:
	for s in get_tree().get_nodes_in_group("soldable"):
		s.soldado.connect(_on_soldado.bind(s))
		s.progreso_cambiado.connect(_on_progreso)
	for sop in get_tree().get_nodes_in_group("soplete"):
		sop.sin_combustible.connect(_on_sin_combustible)


func _on_progreso(valor: float) -> void:
	var texto := "Soldando: %d%%" % int(valor)
	var sop = get_tree().get_first_node_in_group("soplete")
	if sop:
		texto += "   |   Combustible: %d%%" % int(sop.combustible / sop.combustible_max * 100.0)
	info.text = texto
	info.visible = true
	tiempo_info = 0.3


func _on_soldado(objeto: Node) -> void:
	info.visible = false
	tiempo_info = 0.0
	mostrar_mensaje("¡%s soldado!" % objeto.nombre, Color(0.4, 1.0, 0.5))


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
