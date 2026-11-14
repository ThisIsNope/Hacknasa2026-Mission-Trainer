extends StaticBody3D
@onready var gen_1: CSGBox3D = $"../GEN1"

var is_open := false

func interact(_player: Node3D) -> void:
	is_open = not is_open
	if is_open:
		gen_1
