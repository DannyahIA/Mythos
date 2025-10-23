extends Camera2D

# Camera controller: pan with middle mouse, WASD/arrow, zoom with wheel
@export var pan_speed := 400.0
@export var accel := 8.0
@export var zoom_step := 0.1
@export var min_zoom := 0.3
@export var max_zoom := 3.0
@export var tilt_enabled := false
@export var tilt_angle := 18.0 # degrees for a 2.5D tilt effect

var _target_pos := Vector2.ZERO
var _vel := Vector2.ZERO

func _ready():
	set_process(true)
	set_process_input(true)
	_target_pos = global_position

func _input(event):
	# mouse wheel zoom
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
		_set_zoom(get_zoom_scalar() - zoom_step)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
		_set_zoom(get_zoom_scalar() + zoom_step)

	# middle mouse dragging
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_MIDDLE:
		if event.pressed:
			set_process_input(false) # let _unhandled_input handle motion
		else:
			set_process_input(true)

func _unhandled_input(event):
	# pan with middle mouse
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
		_target_pos -= event.relative * get_zoom_scalar()

func _process(delta):
	# keyboard pan
	var dir = Vector2.ZERO
	if Input.is_action_pressed("ui_right") or Input.is_key_pressed(KEY_D):
		dir.x += 1
	if Input.is_action_pressed("ui_left") or Input.is_key_pressed(KEY_A):
		dir.x -= 1
	if Input.is_action_pressed("ui_up") or Input.is_key_pressed(KEY_W):
		dir.y -= 1
	if Input.is_action_pressed("ui_down") or Input.is_key_pressed(KEY_S):
		dir.y += 1
	if dir != Vector2.ZERO:
		dir = dir.normalized() * pan_speed * delta * get_zoom_scalar()
		_target_pos += dir

	# smooth move
	global_position = global_position.lerp(_target_pos, clamp(accel * delta, 0, 1))

	# apply tilt if enabled
	if tilt_enabled:
		rotation_degrees = tilt_angle
	else:
		rotation_degrees = 0

func _set_zoom(z: float):
	z = clamp(z, min_zoom, max_zoom)
	zoom = Vector2(z, z)

func get_zoom_scalar() -> float:
	# Return scalar zoom to avoid overriding Camera2D.get_zoom() which returns a Vector2
	return zoom.x
