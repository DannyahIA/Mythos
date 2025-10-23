extends Node2D

@export var color: Color = Color(0.9,0.2,0.2)
@export var size: Vector2 = Vector2(48,48)
var dragging = false
var offset = Vector2.ZERO
var _snap_timer := 0.0
const SNAP_FEEDBACK_TIME := 0.6

func _ready():
	# draw the token directly as Node2D
	set_process_input(true)
	set_process(true)
	call_deferred("update")

func _process(_delta: float) -> void:
	if _snap_timer > 0.0:
		_snap_timer = max(0.0, _snap_timer - _delta)
	call_deferred("update")

func _draw() -> void:
	# draw a centered rectangle representing the token
	var rect = Rect2(-size * 0.5, size)
	draw_rect(rect, color)
	# draw snap feedback ring
	if _snap_timer > 0.0:
		var t = _snap_timer / SNAP_FEEDBACK_TIME
		var alpha = t
		var ring_color = Color(1.0, 1.0, 1.0, alpha)
		var radius = max(size.x, size.y) * 0.7
		draw_circle(Vector2.ZERO, radius, ring_color)

func _input(event):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and get_global_mouse_position().distance_to(global_position) < max(size.x, size.y) * 0.6:
				dragging = true
				offset = global_position - get_global_mouse_position()
			elif not event.pressed:
				dragging = false
				# snap to grid on mouse release
				if not dragging:
					snap_to_grid(get_parent())
	elif event is InputEventMouseMotion and dragging:
		global_position = get_global_mouse_position() + offset

func snap_to_grid(grid_node: Node):
	if not grid_node:
		return
	var center = grid_node.snap_pixel_to_hex_center(global_position)
	global_position = center
	# trigger visual feedback
	_snap_timer = SNAP_FEEDBACK_TIME
	call_deferred("update")

