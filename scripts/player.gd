extends CharacterBody3D

@onready var head: Node3D = $head
@onready var ray_cast_3d: RayCast3D = $head/RayCast3D
@onready var hold_point: Marker3D = $head/Marker3D

const WALK_SPEED = 8
const SPRINT_SPEED = 15
const CROUCH_SPEED = 3.0
const JUMP_VELOCITY = 7.0
const MOUSE_SENS = 0.1
const GRAVITY = 9.8
const COYOTE_TIME = 0.20
const JUMP_BUFFER_TIME = 0.20
const OXYGEN_BASE = 0.05

const PULL_FORCE = 20.0
const MAX_SPEED = 15.0
const RESET_DISTANCE = 1.5
const RESET_TIME = 1.25
const ROTATION_FOLLOW = 15.0

var speed = 5.0
var oxigen_cons = 0
var coyote_timer: float = 0.0
var jump_buffer_timer: float = 0.0

var held_object: Grabbable = null
var grab_basis := Basis.IDENTITY
var is_resetting := false
var hold_rotation_offset := Vector3.ZERO


func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			return

	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		rotate_y(deg_to_rad(-event.relative.x * MOUSE_SENS))
		head.rotate_x(deg_to_rad(-event.relative.y * MOUSE_SENS))
		head.rotation.x = clamp(head.rotation.x, deg_to_rad(-79), deg_to_rad(79))

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if held_object and held_object.has_method("usar") and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			held_object.usar(event.pressed, self)


func _physics_process(delta: float) -> void:
	oxigen_cons = OXYGEN_BASE
	speed = WALK_SPEED

	if Input.is_action_pressed("crouch"):
		speed = CROUCH_SPEED
		head.position.y = 0.5
	else:
		head.position.y = 1.0
		if Input.is_action_pressed("sprint"):
			speed = SPRINT_SPEED
			oxigen_cons = 0.1
		else:
			speed = WALK_SPEED

	if is_on_floor():
		coyote_timer = COYOTE_TIME
	else:
		coyote_timer -= delta
		velocity.y -= GRAVITY * delta

	if Input.is_action_just_pressed("ui_accept"):
		jump_buffer_timer = JUMP_BUFFER_TIME
	else:
		jump_buffer_timer -= delta

	if jump_buffer_timer > 0.0 and coyote_timer > 0.0:
		velocity.y = JUMP_VELOCITY
		jump_buffer_timer = 0.0
		coyote_timer = 0.0

	var input_dir := Input.get_vector("left", "right", "forward", "backward")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
		Global.oxygen_decay = oxigen_cons
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)
		Global.oxygen_decay = 0.05

	if Input.is_action_just_pressed("interact"):
		if held_object:
			drop_object()
		elif ray_cast_3d.is_colliding():
			var obj = ray_cast_3d.get_collider()
			var target: Node = obj
			while target and not (target is Grabbable) and not target.has_method("interact"):
				target = target.get_parent()
			if target is Grabbable:
				pick_object(target)
			elif target:
				target.interact(self)

	if held_object:
		update_held_object(delta)

		if held_object and Input.is_action_just_pressed("use") and held_object.has_method("use"):
			held_object.use(self)

	move_and_slide()


func pick_object(obj: Grabbable) -> void:
	held_object = obj
	held_object.gravity_scale = 0.0
	held_object.lock_rotation = true
	var mat = PhysicsMaterial.new()
	mat.friction = 0.0
	held_object.physics_material_override = mat
	held_object.add_collision_exception_with(self)
	grab_basis = Basis.from_euler(Vector3(
		deg_to_rad(hold_rotation_offset.x),
		deg_to_rad(hold_rotation_offset.y),
		deg_to_rad(hold_rotation_offset.z)
	))
	if held_object.has_method("on_grab"):
		held_object.on_grab(self)


func drop_object() -> void:
	if held_object == null:
		return
	if held_object.has_method("usar"):
		held_object.usar(false, self)
	if held_object.has_method("on_drop"):
		held_object.on_drop(self)
	held_object.freeze = false
	held_object.gravity_scale = 1.0
	held_object.lock_rotation = false
	held_object.physics_material_override = null
	held_object.remove_collision_exception_with(self)
	held_object = null
	is_resetting = false


func get_hold_target() -> Vector3:
	var from = head.global_position
	var to = hold_point.global_position

	var shape_node: CollisionShape3D = null
	for child in held_object.get_children():
		if child is CollisionShape3D:
			shape_node = child
			break
	if shape_node == null:
		return to

	var query = PhysicsShapeQueryParameters3D.new()
	query.shape = shape_node.shape
	query.transform = Transform3D(held_object.global_basis.orthonormalized(), from)
	query.motion = to - from
	query.exclude = [get_rid(), held_object.get_rid()]

	var result = get_world_3d().direct_space_state.cast_motion(query)
	return from + (to - from) * result[0]


func update_held_object(delta: float) -> void:
	if is_resetting:
		return

	var target = get_hold_target()
	var to_target = target - held_object.global_position

	if to_target.length() > RESET_DISTANCE:
		reset_held_object()
		return

	held_object.linear_velocity = (to_target * PULL_FORCE).limit_length(MAX_SPEED)
	held_object.angular_velocity = Vector3.ZERO

	var target_quat = (head.global_basis * grab_basis).get_rotation_quaternion()
	var current_quat = held_object.global_basis.get_rotation_quaternion()
	var obj_scale = held_object.global_basis.get_scale()
	held_object.global_basis = Basis(current_quat.slerp(target_quat, ROTATION_FOLLOW * delta)).scaled(obj_scale)


func reset_held_object() -> void:
	is_resetting = true
	var obj = held_object

	obj.freeze = true
	obj.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	var old_layer = obj.collision_layer
	var old_mask = obj.collision_mask
	obj.collision_layer = 0
	obj.collision_mask = 0

	var start_pos = obj.global_position
	var start_quat = obj.global_basis.get_rotation_quaternion()
	var obj_scale = obj.global_basis.get_scale()

	var tween = create_tween()
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_method(func(t: float):
		if not is_instance_valid(obj) or held_object != obj:
			return
		var target_quat = (head.global_basis * grab_basis).get_rotation_quaternion()
		obj.global_position = start_pos.lerp(get_hold_target(), t)
		obj.global_basis = Basis(start_quat.slerp(target_quat, t)).scaled(obj_scale)
	, 0.0, 1.0, RESET_TIME)

	await tween.finished

	if is_instance_valid(obj):
		obj.collision_layer = old_layer
		obj.collision_mask = old_mask
		obj.freeze = false
		obj.linear_velocity = Vector3.ZERO
		obj.angular_velocity = Vector3.ZERO
	is_resetting = false
