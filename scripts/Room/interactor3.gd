extends CSGBox3D

@onready var hallway_1: CSGBox3D = $"../../../../Hallway1"
@onready var gen_1: CSGBox3D = $"../../GEN2"
const GIRO := PI

const CHECK_DISTANCE := 50.0
const RAY_OFFSET := 0.5


# Config de los 3 puntos de cada copia: nombre del StaticBody3D -> [nombre del GEN, giro]
const PUNTOS := {
	"StaticBody3D": ["GEN1", 0.0],
	"StaticBody3D2": ["GEN2", PI],
	"StaticBody3D3": ["GEN3", -PI / 2],
}

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

	# Espera a que la copia registre su colisión
	await get_tree().physics_frame
	await get_tree().physics_frame

	if is_instance_valid(nueva_caja):
		check_copy(nueva_caja)
	get_parent().queue_free()

func check_copy(copia: Node) -> void:
	for interact_node in copia.find_children("Interact", "", true, false):
		var body := interact_node.get_parent()
		if not PUNTOS.has(body.name):
			continue
		var datos = PUNTOS[body.name]
		var gen := interact_node.get_node_or_null("../../" + datos[0]) as Node3D
		if gen == null:
			continue
		if ray_blocked(gen, datos[1]):
			body.queue_free()


func ray_blocked(gen: Node3D, giro: float) -> bool:
	var dir := (gen.global_basis * Basis(Vector3.UP, giro) * Vector3(-1, 0, 0)).normalized()
	var from := gen.global_position + dir * RAY_OFFSET
	var to := gen.global_position + dir * CHECK_DISTANCE

	var query := PhysicsRayQueryParameters3D.create(from, to)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return not hit.is_empty()
