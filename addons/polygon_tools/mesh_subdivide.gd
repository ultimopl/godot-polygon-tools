@tool
class_name AutoWeightMeshSubdivide
extends RefCounted

## Mesh subdivision for Polygon2D. Splits every triangle edge at its midpoint,
## producing a denser mesh. New vertices inherit the average UV and bone weight
## of their two endpoints so an existing rig is preserved. Pure logic (only
## Polygon2D reads + Geometry2D) so it is unit-testable headless.

## Result of subdivide().
class Result:
	var points := PackedVector2Array()
	var uv := PackedVector2Array()
	var internal_count := 0
	var polygons: Array = []            # Array[PackedInt32Array]
	var bone_paths: Array = []          # Array[NodePath]
	var bone_weights: Array = []        # Array[PackedFloat32Array], 1:1 with bone_paths
	var ok := false
	var warning := ""


## Subdivide `polygon`'s mesh one level. Does not mutate the node.
static func subdivide(polygon: Polygon2D) -> Result:
	var res := Result.new()
	var pts := polygon.polygon
	var n := pts.size()
	if n < 3:
		res.warning = "Polygon needs at least 3 points."
		return res

	var uv := polygon.uv
	var has_uv := uv.size() == n
	var internal_count := polygon.get_internal_vertex_count()
	var outline_count := n - internal_count
	if outline_count < 3:
		res.warning = "Outline has fewer than 3 points."
		return res

	var bone_paths: Array = []
	var bone_weights: Array = []
	for bi in polygon.get_bone_count():
		var w := polygon.get_bone_weights(bi)
		if w.size() == n:
			bone_paths.append(polygon.get_bone_path(bi))
			bone_weights.append(w)

	var outline_pts := pts.slice(0, outline_count)
	var tris := _gather_triangles(polygon, pts, outline_pts)
	if tris.is_empty():
		res.warning = "No triangles to subdivide (degenerate points)."
		return res

	# Descriptors: original vertices keep their value; midpoints reference two
	# original indices. Outline first (edge midpoints interleaved to keep the
	# boundary loop valid), then internals + interior-edge midpoints.
	var descriptors: Array = []
	for i in outline_count:
		var b := (i + 1) % outline_count
		descriptors.append({"orig": i})
		descriptors.append({"mid": [i, b]})
	var new_outline_count := descriptors.size()

	for i in range(outline_count, n):
		descriptors.append({"orig": i})

	var seen := {}
	for tri in tris:
		var m: int = tri.size()
		for k in m:
			var a: int = tri[k]
			var b: int = tri[(k + 1) % m]
			var lo := mini(a, b)
			var hi := maxi(a, b)
			if _is_outline_edge(lo, hi, outline_count):
				continue
			var key := "%d_%d" % [lo, hi]
			if seen.has(key):
				continue
			seen[key] = true
			var mid := (pts[a] + pts[b]) * 0.5
			# Skip chords whose midpoint falls outside a concave outline.
			if Geometry2D.is_point_in_polygon(mid, outline_pts):
				descriptors.append({"mid": [a, b]})

	var new_pts := PackedVector2Array()
	var new_uv := PackedVector2Array()
	var new_weights: Array = []
	for _bi in bone_paths.size():
		new_weights.append(PackedFloat32Array())
	for d in descriptors:
		if d.has("orig"):
			var i: int = d["orig"]
			new_pts.append(pts[i])
			if has_uv:
				new_uv.append(uv[i])
			for bi in bone_paths.size():
				new_weights[bi].append(bone_weights[bi][i])
		else:
			var a: int = d["mid"][0]
			var b: int = d["mid"][1]
			new_pts.append((pts[a] + pts[b]) * 0.5)
			if has_uv:
				new_uv.append((uv[a] + uv[b]) * 0.5)
			for bi in bone_paths.size():
				new_weights[bi].append((bone_weights[bi][a] + bone_weights[bi][b]) * 0.5)

	var new_outline := new_pts.slice(0, new_outline_count)
	var new_polys := _delaunay_cull(new_pts, new_outline)
	if new_polys.is_empty():
		res.warning = "Subdivision produced no triangles."
		return res

	res.points = new_pts
	res.uv = new_uv
	res.internal_count = new_pts.size() - new_outline_count
	res.polygons = new_polys
	res.bone_paths = bone_paths
	res.bone_weights = new_weights
	res.ok = true
	return res


static func _is_outline_edge(lo: int, hi: int, outline_count: int) -> bool:
	if lo >= outline_count or hi >= outline_count:
		return false
	return hi == lo + 1 or (lo == 0 and hi == outline_count - 1)


static func _gather_triangles(polygon: Polygon2D, pts: PackedVector2Array, outline: PackedVector2Array) -> Array:
	var out: Array = []
	for sub in polygon.polygons:
		if sub.size() >= 3:
			out.append(sub)
	if not out.is_empty():
		return out
	return _delaunay_cull(pts, outline)


static func _delaunay_cull(pts: PackedVector2Array, outline: PackedVector2Array) -> Array:
	var raw := Geometry2D.triangulate_delaunay(pts)
	var out: Array = []
	var t := 0
	while t + 2 < raw.size():
		var ia := raw[t]
		var ib := raw[t + 1]
		var ic := raw[t + 2]
		t += 3
		var centroid := (pts[ia] + pts[ib] + pts[ic]) / 3.0
		if outline.size() < 3 or Geometry2D.is_point_in_polygon(centroid, outline):
			out.append(PackedInt32Array([ia, ib, ic]))
	return out
