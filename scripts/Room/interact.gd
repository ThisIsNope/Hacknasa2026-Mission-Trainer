extends CSGBox3D

@onready var hallway_1: CSGBox3D = $"../../../../Hallway1"
@onready var gen_1: CSGBox3D = $"../../GEN1"

const CHECK_DISTANCE := 50.0
const RAY_OFFSET := 0.5
const GIRO := 0.0   # GEN2: PI | GEN3: -PI / 2

var is_open := false


func interact(_player: Node3D) -> void:
	if is_open:
		return

	if ray_blocked(gen_1, GIRO):
		get_parent().queue_free()
		return

	is_open = true

	var nueva_caja = hallway_1.duplicate()
	hallway_1.get_parent().add_child(nueva_caja)

	var gns_1: Node3D = nueva_caja.get_node("GNS1")
	gns_1.position = Vector3(nueva_caja.size.x / 2.0, 0, 0)

	var giro := Transform3D(Basis(Vector3.UP, GIRO), Vector3.ZERO)
	nueva_caja.global_transform = gen_1.global_transform * giro * gns_1.transform.affine_inverse()

	await get_tree().physics_frame
	await get_tree().physics_frame

	if is_instance_valid(nueva_caja):
		check_copy(nueva_caja)


func check_copy(copia: Node) -> void:
	for interact_node in copia.find_children("Interact", "", true, false):
		var scr = interact_node.get_script()
		if scr == null:
			continue

		# Usa el GEN y el giro reales de ese Interact, no una tabla
		var gen = interact_node.get("gen_1")
		var consts = scr.get_script_constant_map()
		if gen == null or not consts.has("GIRO"):
			continue

		if ray_blocked(gen, consts["GIRO"]):
			interact_node.get_parent().queue_free()


func ray_blocked(gen: Node3D, giro: float) -> bool:
	var dir := (gen.global_basis * Basis(Vector3.UP, giro) * Vector3(-1, 0, 0)).normalized()
	var from := gen.global_position + dir * RAY_OFFSET
	var to := gen.global_position + dir * CHECK_DISTANCE

	var query := PhysicsRayQueryParameters3D.create(from, to)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return not hit.is_empty()
