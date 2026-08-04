@tool
class_name AutoWeightAutoMesher
extends RefCounted

## Auto-mesher for Polygon2D. Given a texture Image, traces the outline of each
## opaque region and builds a triangulated mesh with UVs mapped back to the
## texture. Pure logic (Image + BitMap + Geometry2D only) so it is unit-testable
## headless. Outline tracing / part separation / simplification are delegated to
## Godot's BitMap.opaque_to_polygons; triangulation reuses the same Delaunay cull
## as the rest of the plugin (AutoWeightMeshSubdivide._delaunay_cull).

## One generated mesh part.
class Part:
	var points := PackedVector2Array()  # outline in texture pixel space
	var uv := PackedVector2Array()      # = points (Polygon2D uv is texture pixel space)
	var polygons: Array = []            # Array[PackedInt32Array], Delaunay triangles
	var area := 0.0                     # outline area in px^2


## Generate mesh parts from `image`. Does not touch any scene node.
## params: alpha_threshold (0..1), simplify_epsilon (px), min_area (px^2),
## split_parts (bool).
static func generate(image: Image, params: Dictionary) -> Array:
	var out: Array = []  # Array[Part]
	if image == null:
		return out

	var w := image.get_width()
	var h := image.get_height()
	if w <= 0 or h <= 0:
		return out

	var alpha_threshold: float = params.get("alpha_threshold", 0.5)
	var simplify_epsilon: float = params.get("simplify_epsilon", 2.0)
	var min_area: float = params.get("min_area", 64.0)
	var split_parts: bool = params.get("split_parts", true)

	# BitMap.opaque_to_polygons handles the alpha threshold mask, connected-region
	# separation, contour trace, and Douglas-Peucker simplification in one call.
	var bitmap := BitMap.new()
	bitmap.create_from_image_alpha(image, alpha_threshold)
	var contours: Array = bitmap.opaque_to_polygons(Rect2(0, 0, w, h), simplify_epsilon)

	var tex_size := Vector2(w, h)
	for contour in contours:
		var pts: PackedVector2Array = contour
		if pts.size() < 3:
			continue
		var area := _polygon_area(pts)
		if area < min_area:
			continue
		var part := _build_part(pts, tex_size, area)
		if part != null:
			out.append(part)

	# Keep only the largest part when the user does not want them split.
	if not split_parts and out.size() > 1:
		var largest: Part = out[0]
		for p in out:
			if p.area > largest.area:
				largest = p
		out = [largest]

	return out


static func _build_part(pts: PackedVector2Array, tex_size: Vector2, area: float) -> Part:
	var polys := AutoWeightMeshSubdivide._delaunay_cull(pts, pts)
	if polys.is_empty():
		return null
	# Polygon2D.uv is in texture pixel space, so uv == points (equivalent to the
	# editor's "Copy Polygon to UV"). tex_size is kept for the signature/callers.
	var part := Part.new()
	part.points = pts
	part.uv = pts.duplicate()
	part.polygons = polys
	part.area = area
	return part


## Shoelace area (absolute) of a simple polygon.
static func _polygon_area(pts: PackedVector2Array) -> float:
	var n := pts.size()
	if n < 3:
		return 0.0
	var acc := 0.0
	for i in n:
		var a := pts[i]
		var b := pts[(i + 1) % n]
		acc += a.x * b.y - b.x * a.y
	return absf(acc) * 0.5
