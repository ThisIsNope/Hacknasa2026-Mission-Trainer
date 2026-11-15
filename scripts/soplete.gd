extends Grabbable
## Soplete para soldar.
## Se agarra con E (sistema del jugador) y se usa manteniendo clic izquierdo.
## Suelda cualquier objeto que tenga la función recibir_soldadura() (ver soldable.gd).

signal sin_combustible

@export var alcance: float = 2.5           # distancia máxima para soldar (metros)
@export var potencia: float = 35.0         # % de soldadura por segundo
@export var combustible_max: float = 100.0
@export var gasto: float = 4.0             # combustible por segundo mientras está encendido
## Punta del soplete, relativa al soplete (de aquí sale la llama).
## Para ajustarla a ojo: agrega un Marker3D hijo llamado "Boquilla" y muévelo a la punta.
@export var boquilla_local: Vector3 = Vector3(0, 0.68, -0.5)

var combustible: float
var activo := false
var usuario: Node3D = null                 # jugador que lo sostiene

var llama: CPUParticles3D
var chispas: CPUParticles3D
var luz: OmniLight3D


func _ready() -> void:
	add_to_group("soplete")
	combustible = combustible_max
	_crear_efectos()
	_set_activo(false)


## El jugador llama esto al presionar (true) o soltar (false) el clic.
func usar(presionado: bool, quien: Node3D = null) -> void:
	if quien:
		usuario = quien
	_set_activo(presionado and combustible > 0.0 and usuario != null)


# Compatibilidad con Grabbable: al soltarlo se apaga
func on_drop(_player: Node3D) -> void:
	usar(false)


func recargar(cantidad: float = INF) -> void:
	combustible = minf(combustible + cantidad, combustible_max)


func _set_activo(valor: bool) -> void:
	activo = valor
	llama.emitting = valor
	luz.visible = valor
	if not valor:
		chispas.emitting = false


func _physics_process(delta: float) -> void:
	if not activo:
		return

	combustible = maxf(combustible - gasto * delta, 0.0)
	if combustible <= 0.0:
		_set_activo(false)
		sin_combustible.emit()
		return

	# Rayo desde la vista del jugador: suelda lo que esté en la mira
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var desde := cam.global_position
	# normalized(): en escenas donde la cabeza está escalada, global_basis.z no mide 1.
	# El alcance crece con el tamaño del jugador (en level.tscn el jugador está escalado).
	var escala := clampf(usuario.global_basis.get_scale().y, 0.5, 5.0)
	var hacia := desde - cam.global_basis.z.normalized() * alcance * escala
	var query := PhysicsRayQueryParameters3D.create(desde, hacia)
	query.exclude = [usuario.get_rid(), get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)

	var punto := hacia
	if not hit.is_empty():
		punto = hit.position
		var obj: Node = hit.collider
		if obj and not obj.has_method("recibir_soldadura"):
			obj = obj.get_parent()
		if obj and obj.has_method("recibir_soldadura"):
			obj.recibir_soldadura(potencia * delta)

	# La llama sale del soplete hacia el punto que miras
	var boquilla := posicion_boquilla()
	llama.global_position = boquilla
	var dir := punto - boquilla
	if dir.length() > 0.05 and absf(dir.normalized().dot(Vector3.UP)) < 0.99:
		llama.look_at(punto, Vector3.UP)

	# Chispas y luz solo donde toca algo
	chispas.emitting = not hit.is_empty()
	chispas.global_position = punto
	luz.global_position = punto - dir.normalized() * 0.15
	luz.light_energy = randf_range(1.5, 3.0)


## Posición global de la punta: el Marker3D "Boquilla" si existe, si no boquilla_local.
func posicion_boquilla() -> Vector3:
	var marcador := get_node_or_null("Boquilla")
	if marcador is Node3D:
		return (marcador as Node3D).global_position
	return to_global(boquilla_local)


func _crear_efectos() -> void:
	# --- Llama azul-naranja ---
	var mat_llama := StandardMaterial3D.new()
	mat_llama.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat_llama.vertex_color_use_as_albedo = true
	mat_llama.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat_llama.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat_llama.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	var quad := QuadMesh.new()
	quad.size = Vector2(0.06, 0.06)
	quad.material = mat_llama

	var grad := Gradient.new()
	grad.set_color(0, Color(0.7, 0.85, 1.0, 1.0))
	grad.set_color(1, Color(1.0, 0.5, 0.1, 0.0))
	grad.add_point(0.4, Color(0.3, 0.5, 1.0, 0.9))

	llama = CPUParticles3D.new()
	llama.top_level = true
	llama.mesh = quad
	llama.amount = 40
	llama.lifetime = 0.15
	llama.direction = Vector3(0, 0, -1)
	llama.spread = 6.0
	llama.gravity = Vector3.ZERO
	llama.initial_velocity_min = 2.0
	llama.initial_velocity_max = 3.0
	llama.scale_amount_min = 0.6
	llama.scale_amount_max = 1.2
	llama.color_ramp = grad
	add_child(llama)

	# --- Chispas que caen ---
	var mat_chispa := StandardMaterial3D.new()
	mat_chispa.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat_chispa.albedo_color = Color(1.0, 0.8, 0.4)
	mat_chispa.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	var quad2 := QuadMesh.new()
	quad2.size = Vector2(0.015, 0.015)
	quad2.material = mat_chispa

	chispas = CPUParticles3D.new()
	chispas.top_level = true
	chispas.mesh = quad2
	chispas.amount = 30
	chispas.lifetime = 0.5
	chispas.direction = Vector3.UP
	chispas.spread = 70.0
	chispas.initial_velocity_min = 1.0
	chispas.initial_velocity_max = 3.0
	chispas.gravity = Vector3(0, -9.8, 0)
	add_child(chispas)

	# --- Luz de soldadura (sin sombras: más barata en la web) ---
	luz = OmniLight3D.new()
	luz.top_level = true
	luz.light_color = Color(0.6, 0.75, 1.0)
	luz.omni_range = 3.0
	luz.shadow_enabled = false
	add_child(luz)
