extends CSGBox3D

@onready var hallway_1: CSGBox3D = $"../../../../Hallway1"
@onready var gen_1: CSGBox3D = $"../../GEN3"

const GIRO := -PI / 2  # GEN2: PI | GEN3: -PI / 2
const CHECK_DISTANCE := 50.0
const RAY_OFFSET := 0.5

var is_open := false


func interact(_player: Node3D) -> void:
	if is_open:
		return

	if ray_blocked(gen_1, GIRO):
		return

	is_open = true

	var nueva_caja = hallway_1.duplicate()
	hallway_1.get_parent().add_child(nueva_caja)
	nueva_caja.visible = true   # la plantilla está oculta; la copia se ve

	var gns_1: Node3D = nueva_caja.get_node("GNS1")
	gns_1.position = Vector3(nueva_caja.size.x / 2.0, 0, 0)

	var giro := Transform3D(Basis(Vector3.UP, GIRO), Vector3.ZERO)
	nueva_caja.global_transform = gen_1.global_transform * giro * gns_1.transform.affine_inverse()

	get_parent().queue_free()


func ray_blocked(gen: Node3D, giro: float) -> bool:
	var dir := (gen.global_basis * Basis(Vector3.UP, giro) * Vector3(-1, 0, 0)).normalized()
	var from := gen.global_position + dir * RAY_OFFSET
	var to := gen.global_position + dir * CHECK_DISTANCE
	var space := get_world_3d().direct_space_state
	var exclude: Array[RID] = []

	for i in 10:
		var query := PhysicsRayQueryParameters3D.create(from, to)
		query.hit_back_faces = false
		query.exclude = exclude
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			return false

		var col: Node = hit.collider
		var es_ignorable := col is StaticBody3D \
			or col == hallway_1 \
			or hallway_1.is_ancestor_of(col) \
			or col.name == "Interact"

		if not es_ignorable:
			return true

		if col is CollisionObject3D:
			exclude.append(col.get_rid())
		from = hit.position + dir * 0.05

	return false
