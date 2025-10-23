extends Node2D

# Hex grid drawing and snapping helper
@export var hex_size: float = 64.0 # radius from center to corner
@export var grid_radius: int = 6 # how many hexes from center
@export var line_color: Color = Color(0.6,0.6,0.6,0.7)

func _ready():
	set_process_input(true)
	# schedule initial draw; use call_deferred to avoid static lookup issues
	call_deferred("update")

func _draw():
	# draw axial hex grid centered at origin
	for q in range(-grid_radius, grid_radius+1):
		for r in range(-grid_radius, grid_radius+1):
			if abs(q + r) <= grid_radius:
				var pos = axial_to_pixel(Vector2(q, r))
				# draw hex outline
				draw_polyline(hex_corners(pos), line_color, 2.0)

func hex_corners(center: Vector2) -> PackedVector2Array:
	var corners := PackedVector2Array()
	for i in range(6):
		var angle = PI/180.0 * (60 * i - 30)
		var x = center.x + hex_size * cos(angle)
		var y = center.y + hex_size * sin(angle)
		corners.push_back(Vector2(x, y))
	# close the loop by adding the first point again for polyline
	corners.push_back(corners[0])
	return corners

func axial_to_pixel(ax: Vector2) -> Vector2:
	# pointy-top axial to pixel
	var x = hex_size * sqrt(3) * (ax.x + ax.y/2.0)
	var y = hex_size * 3.0/2.0 * ax.y
	return Vector2(x,y)

func pixel_to_axial(p: Vector2) -> Vector2:
	var q = (sqrt(3)/3 * p.x - 1.0/3 * p.y) / hex_size
	var r = (2.0/3 * p.y) / hex_size
	# round to nearest hex
	return cube_round(axial_to_cube(Vector2(q,r)))

func axial_to_cube(a: Vector2) -> Vector3:
	var x = a.x
	var z = a.y
	var y = -x - z
	return Vector3(x,y,z)

func cube_round(c: Vector3) -> Vector2:
	var rx = round(c.x)
	var ry = round(c.y)
	var rz = round(c.z)
	var x_diff = abs(rx - c.x)
	var y_diff = abs(ry - c.y)
	var z_diff = abs(rz - c.z)
	if x_diff > y_diff and x_diff > z_diff:
		rx = -ry - rz
	elif y_diff > z_diff:
		ry = -rx - rz
	else:
		rz = -rx - ry
	return Vector2(rx, rz)

func snap_pixel_to_hex_center(p: Vector2) -> Vector2:
	var ax = pixel_to_axial(p)
	return axial_to_pixel(ax)
