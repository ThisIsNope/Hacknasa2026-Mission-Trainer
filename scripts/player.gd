extends CharacterBody3D
@onready var head: Node3D = $head

var speed = 5.0

const WALK_SPEED = 5.0
const SPRINT_SPEED = 8.0
const CROUCH_SPEED = 3.0
const JUMP_VELOCITY = 7.0
const MOUSE_SENS = 0.1

# --- NUEVO: Tiempos de gracia para el salto (en segundos) ---
const COYOTE_TIME = 0.15      # Tiempo extra para saltar tras salir de un borde
const JUMP_BUFFER_TIME = 0.15 # Tiempo que recuerda el botón antes de tocar el suelo

var coyote_timer: float = 0.0
var jump_buffer_timer: float = 0.0
# -----------------------------------------------------------

func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		rotate_y(deg_to_rad(-event.relative.x * MOUSE_SENS))
		head.rotate_x(deg_to_rad(-event.relative.y * MOUSE_SENS))
		head.rotation.x = clamp(head.rotation.x, deg_to_rad(-79), deg_to_rad(79))

func _physics_process(delta: float) -> void:
	if Input.is_action_pressed("crouch"):
		speed = CROUCH_SPEED
		head.position.y = 0.5
	else:
		head.position.y = 1.0
		if Input.is_action_pressed("sprint"):
			speed = SPRINT_SPEED
		else:
			speed = WALK_SPEED
		
	# Gravedad y control del Coyote Time
	if is_on_floor():
		coyote_timer = COYOTE_TIME
	else:
		coyote_timer -= delta
		velocity += get_gravity() * delta

	# Control del Jump Buffer
	if Input.is_action_just_pressed("ui_accept"):
		jump_buffer_timer = JUMP_BUFFER_TIME
	else:
		jump_buffer_timer -= delta

	# Ejecutar salto si ambos temporizadores tienen tiempo disponible
	if jump_buffer_timer > 0.0 and coyote_timer > 0.0:
		velocity.y = JUMP_VELOCITY
		jump_buffer_timer = 0.0 # Reinicia para evitar doble salto
		coyote_timer = 0.0      # Reinicia para gastar el margen

	# Movimiento horizontal
	var input_dir := Input.get_vector("left", "right", "forward", "backward")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)

	move_and_slide()
