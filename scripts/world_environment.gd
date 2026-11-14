
extends WorldEnvironment
@export var world_environment: WorldEnvironment
@export var velocidad_grados: float = 2.0 

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.

func _process(delta: float) -> void:
	if environment:
		# Rota constantemente en el eje Y (horizontal)
		environment.sky_rotation.z += deg_to_rad(velocidad_grados) * delta
		
		# Evita que el número crezca infinitamente tras horas de juego
		environment.sky_rotation.z = wrapf(environment.sky_rotation.z, 0.0, TAU)
