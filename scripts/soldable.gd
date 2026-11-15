extends Node3D
## Algo que se puede soldar con el soplete (una grieta, un panel, una tubería...).
## Ponlo en un CSGBox3D con use_collision, o en un nodo con colisión.
## El progreso sube mientras le apuntas con el soplete encendido.

signal soldado                         # se emite una vez al llegar al 100 %
signal progreso_cambiado(valor: float) # se emite mientras lo sueldas (0 a 100)

@export var nombre: String = "Panel"    # se usa en el mensaje del HUD: "¡Panel soldado!"
@export var tarea_id: String = ""
@export_enum("pistola", "llave", "rachet") var herramienta_requerida: String = "pistola"

@export var color_roto: Color = Color(0.35, 0.1, 0.05)
@export var color_soldado: Color = Color(0.75, 0.75, 0.8)
@export var enfriamiento: float = 1.5      # segundos que tarda en apagarse el brillo

var progreso := 0.0      # 0 a 100
var calor := 0.0         # 0 a 1, solo visual
var terminado := false
var material: StandardMaterial3D


func _ready() -> void:
	add_to_group("soldable")   # el HUD encuentra los soldables por este grupo
	material = StandardMaterial3D.new()
	material.albedo_color = color_roto
	material.metallic = 0.6
	material.roughness = 0.4
	material.emission_enabled = true
	material.emission = Color(1.0, 0.45, 0.1)
	material.emission_energy_multiplier = 0.0
	var nodo: Node = self
	if "material" in nodo:          # CSGBox3D, CSGCylinder3D, etc.
		nodo.set("material", material)
	elif nodo is GeometryInstance3D:
		(nodo as GeometryInstance3D).material_override = material


func recibir_soldadura(cantidad: float) -> void:
	recibir_herramienta("pistola", cantidad)


func recibir_herramienta(id: String, cantidad: float) -> bool:
	if terminado or id != herramienta_requerida or cantidad <= 0.0:
		return false
	calor = 1.0
	progreso = minf(progreso + cantidad, 100.0)
	material.albedo_color = color_roto.lerp(color_soldado, progreso / 100.0)
	progreso_cambiado.emit(progreso)
	if progreso >= 100.0:
		terminado = true
		soldado.emit()
	return true


func texto_interaccion() -> String:
	if terminado:
		return nombre + " · Reparado"
	var herramientas := {"pistola": "soplete", "llave": "llave inglesa", "rachet": "rachet"}
	return "%s · Equipa %s y mantén clic" % [nombre, herramientas[herramienta_requerida]]


func _process(delta: float) -> void:
	calor = maxf(calor - delta / enfriamiento, 0.0)
	material.emission_energy_multiplier = calor * 2.5
