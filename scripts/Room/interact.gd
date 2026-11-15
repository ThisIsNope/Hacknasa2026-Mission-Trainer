extends CSGBox3D

@onready var hallway_1: CSGBox3D = $"../../../../Hallway1"
@onready var gen_1: CSGBox3D = $"../../GEN1"

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

	nueva_caja.global_transform = gen_1.global_transform * gns_1.transform.affine_inverse()


func has_obstacle() -> bool:
	var from = gen_1.global_position
	var dir = -gen_1.global_basis.x  # hacia donde se extiende el pasillo
	var to = from + dir * CHECK_DISTANCE

	var query = PhysicsRayQueryParameters3D.create(from, to)
	var hit = get_world_3d().direct_space_state.intersect_ray(query)
	return not hit.is_empty()
