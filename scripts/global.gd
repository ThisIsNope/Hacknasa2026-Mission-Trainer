extends Node

var oxigen = 125

var oxygen_decay = 0.05
var oxygen_timer = 0

func _process(delta: float) -> void:
	oxygen_timer += delta

	if oxygen_timer >= 1:
		oxigen = maxf(0, oxigen - oxygen_decay)
		oxygen_timer -= 1
