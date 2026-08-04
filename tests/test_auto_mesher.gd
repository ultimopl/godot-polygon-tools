@tool
extends McpTestSuite

## Headless verification of the auto-mesher (Image -> Polygon2D parts).

const Mesher := preload("res://addons/polygon_tools/auto_mesher.gd")


func suite_name() -> String:
	return "auto_mesher"


## Build a 64x32 RGBA image with two separate opaque squares on a transparent bg.
func _two_squares() -> Image:
	var img := Image.create(64, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	_fill_rect(img, Rect2i(4, 4, 20, 20), Color.WHITE)   # big square
	_fill_rect(img, Rect2i(40, 10, 10, 10), Color.RED)   # small square
	return img


func _fill_rect(img: Image, r: Rect2i, col: Color) -> void:
	for y in range(r.position.y, r.position.y + r.size.y):
		for x in range(r.position.x, r.position.x + r.size.x):
			img.set_pixel(x, y, col)


func test_split_parts_finds_two_regions() -> void:
	var img := _two_squares()
	var parts: Array = Mesher.generate(img, {
		"alpha_threshold": 0.5, "simplify_epsilon": 1.0, "min_area": 16.0, "split_parts": true,
	})
	assert_eq(parts.size(), 2, "expected two disjoint parts")
	for part in parts:
		assert_gt(part.points.size(), 2, "outline needs >= 3 points")
		assert_eq(part.uv.size(), part.points.size(), "uv 1:1 with points")
		assert_false(part.polygons.is_empty(), "part has triangles")


func test_no_split_keeps_largest() -> void:
	var img := _two_squares()
	var parts: Array = Mesher.generate(img, {
		"alpha_threshold": 0.5, "simplify_epsilon": 1.0, "min_area": 16.0, "split_parts": false,
	})
	assert_eq(parts.size(), 1, "no-split keeps a single part")
	# Big square (20x20=400) must win over the small one (10x10=100).
	assert_gt(parts[0].area, 200.0, "largest region kept")


func test_uv_equals_points() -> void:
	# Polygon2D uv is in texture pixel space, so the mesher copies points -> uv
	# (equivalent to the editor's "Copy Polygon to UV").
	var img := _two_squares()
	var parts: Array = Mesher.generate(img, {
		"alpha_threshold": 0.5, "simplify_epsilon": 1.0, "min_area": 16.0, "split_parts": true,
	})
	for part in parts:
		assert_eq(part.uv.size(), part.points.size(), "uv 1:1 with points")
		for i in part.points.size():
			assert_true(part.uv[i].is_equal_approx(part.points[i]), "uv == point")


func test_min_area_filters_small_parts() -> void:
	var img := _two_squares()
	# Small square area ~100; set min_area above it so only the big one survives.
	var parts: Array = Mesher.generate(img, {
		"alpha_threshold": 0.5, "simplify_epsilon": 1.0, "min_area": 150.0, "split_parts": true,
	})
	assert_eq(parts.size(), 1, "min_area drops the small square")
