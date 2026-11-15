extends CSGBox3D

@onready var hallway_1: CSGBox3D = $"../../../../Hallway1"
@onready var gen_2: CSGBox3D = $"../../GEN2"

const CHECK_DISTANCE := 50.0

var is_open := false

func interact(_player: Node3D) -> void:
	if is_open:
		return

	if has_obstacle():
		queue_free()
		return

	is_open = true

	var nueva_caja = hallway_1.duplicate()
	hallway_1.get_parent().add_child(nueva_caja)

	var gns_1: Node3D = nueva_caja.get_node("GNS1")
	gns_1.position = Vector3(nueva_caja.size.x / 2.0, 0, 0)

	var giro := Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
	nueva_caja.global_transform = gen_2.global_transform * giro * gns_1.transform.affine_inverse()


func has_obstacle() -> bool:
	var from = gen_2.global_position
	var dir = gen_2.global_basis.x  # con el giro de 180° el pasillo se extiende hacia +X de GEN2
	var to = from + dir * CHECK_DISTANCE

	var query = PhysicsRayQueryParameters3D.create(from, to)
	var hit = get_world_3d().direct_space_state.intersect_ray(query)
	return not hit.is_empty()
