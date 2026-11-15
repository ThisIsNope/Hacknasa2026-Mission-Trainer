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
const OXYGEN_BASE = 0.005     # consumo al caminar o estar quieto (antes 0.05)
const OXYGEN_SPRINT = 0.012   # consumo al correr (antes 0.1)

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

# --- Objeto en la mano (el que está seleccionado en la barra del HUD) ---
const MANO_POS := Vector3(0.28, -0.25, -0.55)   # derecha, abajo y adelante de la cámara
var mano: Node3D
var modelo_mano: Node3D
var giro_mano_y := 0.0   # giro extra de prueba (tecla R) para orientar la herramienta en la mano
var id_en_mano := ""
var hud: Node
const TIRAR_FUERZA := 4.0   # qué tan lejos sale la herramienta al tirarla

# --- Agacharse (tecla C) ---
const CROUCH_HEIGHT := 1.2        # altura de la cápsula agachado (la de pie es la original)
const CROUCH_TRANSITION := 10.0   # qué tan rápido baja / sube
var col: CollisionShape3D
var capsula: CapsuleShape3D
var altura_capsula := 2.0
var col_y_pie := 0.0
var head_y_pie := 0.0
var agachado := false
var agachado_t := 0.0             # 0 = de pie, 1 = agachado

# Objetos del mundo que se guardan en el inventario en vez de sostenerse con física.
# "grupo": "id del CATALOGO del HUD". El Soplete (grupo "soplete") es la pistola.
const GRUPOS_A_ID := {"soplete": "pistola"}

var herramienta_activa: Node = null   # objeto REAL equipado (p. ej. el Soplete)
var nodo_en_mano: Node3D = null


func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# Agacharse: cápsula propia para poder cambiar su altura sin tocar el recurso compartido
	head_y_pie = head.position.y
	col = get_node_or_null("CollisionShape3D")
	if col and col.shape is CapsuleShape3D:
		capsula = (col.shape as CapsuleShape3D).duplicate()
		col.shape = capsula
		altura_capsula = capsula.height
		col_y_pie = col.position.y
	_asegurar_tecla("crouch", KEY_C)

	# La mano NO cuelga de la cabeza: la cabeza está escalada (0.005) y la herramienta
	# quedaba diminuta y detrás de la cámara. Ahora sigue a la cámara en cada frame.
	mano = Node3D.new()
	mano.name = "Mano"
	mano.top_level = true
	add_child(mano)
	_registrar_accion_soltar()
	_conectar_hud.call_deferred()


## Coloca la mano delante de la cámara (abajo a la derecha), con el tamaño del jugador.
func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or mano == null:
		return
	var b := cam.global_transform.basis.orthonormalized()
	var factor := maxf(global_basis.get_scale().x, 0.0001)
	mano.global_transform = Transform3D(b.scaled(Vector3.ONE * factor), cam.global_position + b * (MANO_POS * factor))


func _conectar_hud() -> void:
	hud = get_tree().get_first_node_in_group("hud")
	if hud == null:
		push_warning("Jugador: no encontré el HUD (grupo 'hud')")
		return
	hud.slot_seleccionado.connect(_actualizar_mano)
	hud.inventario_cambiado.connect(_actualizar_mano)
	_actualizar_mano()


## Pone en la mano el modelo del objeto seleccionado (o lo quita si el slot está vacío).
func _actualizar_mano(_a = null, _b = null) -> void:
	if hud == null:
		return
	var item: Dictionary = hud.objeto_seleccionado()
	var id: String = item.get("id", "")
	var nodo = item.get("nodo")   # objeto real guardado (null si es solo un modelo)
	if nodo != null and not is_instance_valid(nodo):
		nodo = null
	if id == id_en_mano and nodo == nodo_en_mano:
		return

	_vaciar_mano()
	if id == "":
		return
	id_en_mano = id

	# Lo que se VE en la mano es siempre el modelo del catálogo (escalado y orientado)
	modelo_mano = hud.crear_modelo_mano(id)
	giro_mano_y = 0.0
	if modelo_mano:
		mano.add_child(modelo_mano)
	else:
		push_warning("Jugador: no se pudo crear el modelo de '%s' para la mano" % id)

	if nodo != null:
		# Objeto real (el Soplete con su script): va en la mano con sus mallas ocultas
		# (si el modelo del catálogo falló, se deja visible) y sigue funcionando.
		hud.preparar_nodo_logico(nodo, modelo_mano != null)
		mano.add_child(nodo)
		nodo_en_mano = nodo
		herramienta_activa = nodo
		if nodo.has_method("on_grab"):
			nodo.on_grab(self)


## Saca lo que haya en la mano. Si es el objeto REAL del suelo (el soplete), lo saca
## de la mano sin destruirlo: sigue guardado en el inventario.
func _vaciar_mano() -> void:
	if herramienta_activa and is_instance_valid(herramienta_activa):
		if herramienta_activa.has_method("usar"):
			herramienta_activa.usar(false, self)
		if herramienta_activa.has_method("on_drop"):
			herramienta_activa.on_drop(self)
	herramienta_activa = null
	if nodo_en_mano and is_instance_valid(nodo_en_mano) and nodo_en_mano.get_parent() != null:
		nodo_en_mano.get_parent().remove_child(nodo_en_mano)
	nodo_en_mano = null
	if modelo_mano and is_instance_valid(modelo_mano):
		modelo_mano.queue_free()
	modelo_mano = null
	id_en_mano = ""


## Devuelve el id del inventario si el objeto es una herramienta ("" si no lo es).
## También puedes marcar cualquier objeto con set_meta("id_inventario", "llave").
func _id_inventario(objeto: Node) -> String:
	if objeto.has_meta("id_inventario"):
		return str(objeto.get_meta("id_inventario"))
	for grupo in GRUPOS_A_ID:
		if objeto.is_in_group(grupo):
			return GRUPOS_A_ID[grupo]
	if objeto.name.to_lower().begins_with("soplete"):
		return "pistola"
	return ""


## Toma una herramienta del suelo y la guarda en el inventario (sin destruirla).
## Devuelve true si el objeto era una herramienta (aunque no haya espacio), para
## que no se sostenga con física.
func _guardar_en_inventario(objeto: Node) -> bool:
	if hud == null:
		return false
	var id := _id_inventario(objeto)
	var nodo := objeto as Node3D
	if id == "" or nodo == null or nodo.get_parent() == null:
		return false
	if hud.slot_libre() < 0:
		hud.mostrar_mensaje("Barra de objetos llena", Color(1.0, 0.75, 0.25))
		return true
	nodo.get_parent().remove_child(nodo)
	var slot: int = hud.agregar_nodo(id, nodo)
	hud.seleccionar_slot(slot)   # queda en la mano
	return true


## Tira el objeto REAL guardado en el slot seleccionado (el soplete) al mundo.
func _tirar_nodo(id: String, nodo: Node3D) -> void:
	var slot: int = hud.slot_actual
	_vaciar_mano()
	hud.quitar_slot(slot)
	hud.restaurar_nodo_mundo(nodo)

	var adelante := -head.global_basis.z
	get_tree().current_scene.add_child(nodo)
	nodo.global_transform = Transform3D(
		Basis.from_scale(nodo.scale),
		head.global_position + adelante * 0.8 + Vector3.DOWN * 0.2
	)
	if nodo is RigidBody3D:
		var rb := nodo as RigidBody3D
		rb.linear_velocity = adelante * TIRAR_FUERZA + velocity * 0.5
		rb.angular_velocity = Vector3(randf_range(-3.0, 3.0), randf_range(-3.0, 3.0), randf_range(-3.0, 3.0))
		rb.add_collision_exception_with(self)
		get_tree().create_timer(0.6).timeout.connect(func():
			if is_instance_valid(rb):
				rb.remove_collision_exception_with(self)
		)


## Crea la acción si no existe, o le agrega la tecla si no la tiene.
func _asegurar_tecla(accion: String, tecla: Key) -> void:
	if not InputMap.has_action(accion):
		InputMap.add_action(accion)
	for ev in InputMap.action_get_events(accion):
		if ev is InputEventKey and (ev as InputEventKey).physical_keycode == tecla:
			return
	var nuevo := InputEventKey.new()
	nuevo.physical_keycode = tecla
	InputMap.action_add_event(accion, nuevo)


## Agacharse con la tecla C: baja la cápsula y la cabeza; solo se levanta si hay espacio.
func _actualizar_agachado(delta: float) -> void:
	if Input.is_action_pressed("crouch"):
		agachado = true
	elif agachado and _puede_levantarse():
		agachado = false

	agachado_t = move_toward(agachado_t, 1.0 if agachado else 0.0, CROUCH_TRANSITION * delta)
	var t := smoothstep(0.0, 1.0, agachado_t)

	if capsula:
		var h := lerpf(altura_capsula, CROUCH_HEIGHT, t)
		capsula.height = h
		# Los pies se quedan en el suelo: la cápsula baja y la cabeza baja el doble
		var baja := (altura_capsula - h) * 0.5 * col.scale.y
		col.position.y = col_y_pie - baja
		head.position.y = head_y_pie - baja * 2.0
	else:
		head.position.y = head_y_pie - 0.5 * t


func _puede_levantarse() -> bool:
	if capsula == null:
		return true
	var extra := (altura_capsula - capsula.height) * col.global_basis.get_scale().y
	if extra <= 0.001:
		return true
	return not test_move(global_transform, Vector3.UP * extra)


## Crea la acción "soltar_herramienta" (tecla Q) si no existe en el Mapa de entrada.
## Si prefieres otra tecla, créala tú en Proyecto > Configuración > Mapa de entrada
## con ese mismo nombre y este código no la sobrescribe.
func _registrar_accion_soltar() -> void:
	if InputMap.has_action("soltar_herramienta"):
		return
	InputMap.add_action("soltar_herramienta")
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_Q
	InputMap.action_add_event("soltar_herramienta", ev)


## Tira la herramienta seleccionada hacia adelante. Para volver a tomarla, míra la
## y presiona la tecla de interactuar ("interact").
func tirar_herramienta() -> void:
	if hud == null:
		return
	var item: Dictionary = hud.objeto_seleccionado()
	var id: String = item.get("id", "")
	if id == "":
		return
	var nodo = item.get("nodo")   # objeto real guardado (el soplete), si lo hay
	if nodo != null and is_instance_valid(nodo):
		_tirar_nodo(id, nodo)
		return
	var herramienta: RigidBody3D = hud.crear_herramienta(id, global_basis.get_scale().x)
	if herramienta == null:
		return

	hud.quitar_objeto(id, 1)   # saca una unidad del inventario (actualiza la mano)

	var adelante := -head.global_basis.z
	get_tree().current_scene.add_child(herramienta)
	herramienta.global_position = head.global_position + adelante * 0.6 + Vector3.DOWN * 0.2
	herramienta.linear_velocity = adelante * TIRAR_FUERZA + velocity * 0.5
	herramienta.angular_velocity = Vector3(randf_range(-3.0, 3.0), randf_range(-3.0, 3.0), randf_range(-3.0, 3.0))

	# Por un momento no choca con el jugador para no empujarlo al salir
	herramienta.add_collision_exception_with(self)
	get_tree().create_timer(0.6).timeout.connect(func():
		if is_instance_valid(herramienta):
			herramienta.remove_collision_exception_with(self)
	)


func _input(event: InputEvent) -> void:
	# Tecla R: gira 90° la herramienta que llevas en la mano y muestra en la consola
	# el valor final para ponerlo en "mano_rot" del CATALOGO del HUD.
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_R:
		if modelo_mano and is_instance_valid(modelo_mano) and id_en_mano != "":
			var base: Vector3 = hud.CATALOGO.get(id_en_mano, {}).get("mano_rot", Vector3.ZERO)
			giro_mano_y = fposmod(giro_mano_y + 90.0, 360.0)
			modelo_mano.rotation_degrees = Vector3(base.x, base.y + giro_mano_y, base.z)
			print("mano_rot de '%s' -> Vector3(%s, %s, %s)" % [id_en_mano, base.x, fposmod(base.y + giro_mano_y, 360.0), base.z])

	if event is InputEventMouseButton and event.pressed:
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			return

	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		rotate_y(deg_to_rad(-event.relative.x * MOUSE_SENS))
		head.rotate_x(deg_to_rad(-event.relative.y * MOUSE_SENS))
		head.rotation.x = clamp(head.rotation.x, deg_to_rad(-79), deg_to_rad(79))

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var herramienta = held_object if held_object else herramienta_activa
		if herramienta and herramienta.has_method("usar") and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			herramienta.usar(event.pressed, self)


func _physics_process(delta: float) -> void:
	oxigen_cons = OXYGEN_BASE
	speed = WALK_SPEED

	_actualizar_agachado(delta)
	if agachado:
		speed = CROUCH_SPEED
	elif Input.is_action_pressed("sprint"):
		speed = SPRINT_SPEED
		oxigen_cons = OXYGEN_SPRINT

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
		Global.oxygen_decay = OXYGEN_BASE

	if Input.is_action_just_pressed("interact"):
		if held_object:
			drop_object()
		elif ray_cast_3d.is_colliding():
			var obj = ray_cast_3d.get_collider()
			var target: Node = obj
			while target and not (target is Grabbable) and not target.has_method("interact"):
				target = target.get_parent()
			if target is Grabbable:
				# Las herramientas (el soplete) se guardan en el inventario;
				# los demás objetos se sostienen con física como antes.
				if not _guardar_en_inventario(target):
					pick_object(target)
			elif target:
				target.interact(self)

	if herramienta_activa and held_object == null and Input.is_action_just_pressed("use") and herramienta_activa.has_method("use"):
		herramienta_activa.use(self)

	if Input.is_action_just_pressed("soltar_herramienta") and held_object == null:
		tirar_herramienta()

	if held_object:
		update_held_object(delta)

		if held_object and Input.is_action_just_pressed("use") and held_object.has_method("use"):
			held_object.use(self)

	move_and_slide()


func pick_object(obj: Grabbable) -> void:
	held_object = obj
	mano.visible = false   # no se ve la herramienta mientras sostienes otro objeto
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
	mano.visible = true
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
