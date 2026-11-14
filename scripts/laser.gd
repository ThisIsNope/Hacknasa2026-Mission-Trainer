extends Grabbable

@onready var light: SpotLight3D = $SpotLight3D

func use(_player: Node3D) -> void:
	light.visible = not light.visible

func on_drop(_player: Node3D) -> void:
	light.visible = false
