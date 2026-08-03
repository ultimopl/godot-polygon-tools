@tool
class_name AutoWeightBoneHeatSolver
extends RefCounted

## Bone-heat (geodesic diffusion) weight solver for Polygon2D + Skeleton2D.
## Pure logic: given a polygon and skeleton it returns per-bone weight arrays.
## No editor UI dependencies so it can be unit-tested headless.

const EPS := 1e-6 # joint detection uses Result.joints; joint_blend band = sum bone len

## Result of a compute() call.
class Result:
	var weights: Dictionary = {} # NodePath (relative to skeleton) -> PackedFloat32Array (len == vertex count)
	var vertex_count := 0
	var bone_count := 0
	var warnings: PackedStringArray = PackedStringArray()
	var joints: Array = [] # Array of { bone, parent, center_world, radius }
	var ok := false


## Recursively collect every Bone2D under `skeleton` (depth-first, stable order).
static func collect_bones(skeleton: Node) -> Array:
	var out := []
	_collect_bones_rec(skeleton, out)
	return out


static func _collect_bones_rec(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child is Bone2D:
			out.append(child)
		_collect_bones_rec(child, out)


## World-space (start, end) segment for a Bone2D.
static func bone_segment(bone: Bone2D) -> Array:
	var start := bone.global_position
	var length := bone.get_length()
	var end := start + Vector2.RIGHT.rotated(bone.global_rotation) * length
	return [start, end]


static func _dist_point_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var closest := Geometry2D.get_closest_point_to_segment(p, a, b)
	return p.distance_to(closest)


## Test whether the straight line from vertex to the nearest bone point stays
## inside the polygon (simple visibility). Returns true if visible.
## Samples interior points along the segment and requires them inside the
## polygon. Tolerant of segments that run along a boundary edge (a common case
## when a bone's closest point projects onto the outline), which a strict
## edge-crossing test would wrongly reject.
static func _segment_inside_polygon(p: Vector2, target: Vector2, poly: PackedVector2Array) -> bool:
	const SAMPLES := 6
	for s in range(1, SAMPLES):
		var t := float(s) / float(SAMPLES)
		var pt := p.lerp(target, t)
		if not Geometry2D.is_point_in_polygon(pt, poly):
			# Allow points that merely sit on the boundary (nudge inward toward
			# the polygon centroid and re-test).
			var nudged := pt.lerp(_polygon_centroid(poly), 1e-3)
			if not Geometry2D.is_point_in_polygon(nudged, poly):
				return false
	return true


## Average triangle-edge length of the mesh — a scale reference for the heat
## binding term.
static func _characteristic_length(points: PackedVector2Array, tris: PackedInt32Array) -> float:
	var total := 0.0
	var count := 0
	var t := 0
	while t + 2 < tris.size():
		var a := points[tris[t]]
		var b := points[tris[t + 1]]
		var c := points[tris[t + 2]]
		total += a.distance_to(b) + b.distance_to(c) + c.distance_to(a)
		count += 3
		t += 3
	if count == 0:
		return 1.0
	return total / float(count)


## For each bone, the set of bone indices adjacent in the hierarchy: itself,
## its parent bone, and its child bones. Returned as Array[Dictionary] used as
## an index set (keys = allowed bone indices).
static func _build_adjacency(bones: Array) -> Array:
	var adj := []
	adj.resize(bones.size())
	for bi in bones.size():
		adj[bi] = {bi: true}
	for bi in bones.size():
		var parent_idx := bones.find(bones[bi].get_parent())
		if parent_idx != -1:
			adj[bi][parent_idx] = true
			adj[parent_idx][bi] = true
	return adj


## Diagonal length of the axis-aligned bounding box of the points.
static func _bounds_diagonal(points: PackedVector2Array) -> float:
	if points.is_empty():
		return 1.0
	var mn := points[0]
	var mx := points[0]
	for p in points:
		mn = mn.min(p)
		mx = mx.max(p)
	return mn.distance_to(mx)


static func _polygon_centroid(poly: PackedVector2Array) -> Vector2:
	var c := Vector2.ZERO
	for v in poly:
		c += v
	return c / float(poly.size())


## Compute bone weights.
## polygon: Polygon2D whose `polygon` vertices get weighted.
## skeleton: Skeleton2D containing the Bone2D chain.
## params keys: heat_coeff (float), max_bones_per_vertex (int),
##   use_visibility (bool), locality (float, 0 = pure heat),
##   chain_adjacency (bool), joint_blend (float, 0 = off)
static func compute(polygon: Polygon2D, skeleton: Node, params: Dictionary) -> Result:
	var res := Result.new()
	var heat_coeff: float = params.get("heat_coeff", 1.0)
	var max_bones: int = params.get("max_bones_per_vertex", 4)
	var use_visibility: bool = params.get("use_visibility", true)
	var locality: float = params.get("locality", 2.0)
	var chain_adjacency: bool = params.get("chain_adjacency", false)
	var joint_blend: float = params.get("joint_blend", 0.0)

	var local_pts := polygon.polygon
	var n := local_pts.size()
	res.vertex_count = n
	if n < 3:
		res.warnings.append("Polygon has fewer than 3 vertices.")
		return res

	var bones := collect_bones(skeleton)
	res.bone_count = bones.size()
	if bones.is_empty():
		res.warnings.append("Skeleton has no Bone2D nodes.")
		return res

	# Vertices in global space.
	var xf := polygon.global_transform
	var world_pts := PackedVector2Array()
	world_pts.resize(n)
	for i in n:
		world_pts[i] = xf * local_pts[i]

	# Bone segments (global).
	var segs := []
	for bone in bones:
		segs.append(bone_segment(bone))

	# Nearest visible bone + distance per vertex.
	var nearest := PackedInt32Array()
	nearest.resize(n)
	var dist := PackedFloat64Array()
	dist.resize(n)
	for i in n:
		var best_bone := -1
		var best_d := INF
		var best_vis_bone := -1
		var best_vis_d := INF
		for bi in bones.size():
			var seg: Array = segs[bi]
			var d := _dist_point_to_segment(world_pts[i], seg[0], seg[1])
			if d < best_d:
				best_d = d
				best_bone = bi
			if use_visibility:
				var target := Geometry2D.get_closest_point_to_segment(world_pts[i], seg[0], seg[1])
				if _segment_inside_polygon(world_pts[i], target, world_pts):
					if d < best_vis_d:
						best_vis_d = d
						best_vis_bone = bi
		if use_visibility and best_vis_bone != -1:
			nearest[i] = best_vis_bone
			dist[i] = maxf(best_vis_d, EPS)
		else:
			nearest[i] = best_bone
			dist[i] = maxf(best_d, EPS)

	# Triangulate the mesh (indices into the vertex list). Delaunay respects the
	# actual point positions and includes internal vertices; ear-clipping fails
	# on concave outlines. Delaunay meshes the convex hull, so drop triangles
	# whose centroid lies outside the (possibly concave) boundary outline.
	var outline := local_pts.slice(0, n - polygon.get_internal_vertex_count())
	var outline_world := PackedVector2Array()
	outline_world.resize(outline.size())
	for i in outline.size():
		outline_world[i] = xf * outline[i]

	var raw := Geometry2D.triangulate_delaunay(world_pts)
	var tris := PackedInt32Array()
	var t := 0
	while t + 2 < raw.size():
		var ia := raw[t]
		var ib := raw[t + 1]
		var ic := raw[t + 2]
		t += 3
		var centroid := (world_pts[ia] + world_pts[ib] + world_pts[ic]) / 3.0
		if outline_world.size() < 3 or Geometry2D.is_point_in_polygon(centroid, outline_world):
			tris.append(ia)
			tris.append(ib)
			tris.append(ic)

	var degenerate := tris.is_empty()
	if degenerate:
		res.warnings.append("Triangulation failed (degenerate/collinear points); used inverse-distance fallback.")

	var per_bone_weights := [] # Array of PackedFloat32Array, one per bone, len n
	for bi in bones.size():
		var arr := PackedFloat32Array()
		arr.resize(n)
		per_bone_weights.append(arr)

	if degenerate:
		# Inverse-distance-squared fallback across all bones.
		for i in n:
			var total := 0.0
			var wv := PackedFloat64Array()
			wv.resize(bones.size())
			for bi in bones.size():
				var seg: Array = segs[bi]
				var d := maxf(_dist_point_to_segment(world_pts[i], seg[0], seg[1]), EPS)
				var w := 1.0 / (d * d)
				wv[bi] = w
				total += w
			for bi in bones.size():
				per_bone_weights[bi][i] = wv[bi] / total if total > 0.0 else 0.0
	else:
		# Bone-heat: solve (-L + H) w = H p per bone.
		var L := AutoWeightLinAlg.cotangent_laplacian(world_pts, tris)
		# H diagonal from binding distance. Distances are normalized by a
		# characteristic mesh length so the binding term stays comparable to the
		# (scale-invariant) cotangent Laplacian regardless of polygon size.
		var char_len := _characteristic_length(world_pts, tris)
		var char_sq := maxf(char_len * char_len, EPS)
		var H := PackedFloat64Array()
		H.resize(n)
		for i in n:
			H[i] = heat_coeff * char_sq / (dist[i] * dist[i])
		# System matrix A = -L + diag(H). L diagonal is negative, so -L makes it positive.
		var A := []
		A.resize(n)
		for i in n:
			var row := PackedFloat64Array()
			row.resize(n)
			var lrow: PackedFloat64Array = L[i]
			for j in n:
				row[j] = -lrow[j]
			row[i] += H[i]
			A[i] = row

		for bi in bones.size():
			var b := PackedFloat64Array()
			b.resize(n)
			for i in n:
				b[i] = H[i] if nearest[i] == bi else 0.0
			var x := AutoWeightLinAlg.solve(A, b)
			if x.is_empty():
				res.warnings.append("Solver singular for a bone; used indicator weights.")
				for i in n:
					per_bone_weights[bi][i] = 1.0 if nearest[i] == bi else 0.0
			else:
				for i in n:
					per_bone_weights[bi][i] = maxf(x[i], 0.0)

	# Distance-based locality: damp each bone's weight where the vertex is far
	# from that bone, relative to the bone's own length. Prevents heat from
	# leaking across the mesh to a distant bone. locality == 0 disables it.
	if locality > 0.0:
		# Mesh scale as a floor so zero-length bones still have a falloff radius.
		var mesh_scale := _bounds_diagonal(world_pts)
		for bi in bones.size():
			var seg: Array = segs[bi]
			var bone_len: float = seg[0].distance_to(seg[1])
			var radius := maxf(bone_len, mesh_scale * 0.15) + EPS
			for i in n:
				var d := _dist_point_to_segment(world_pts[i], seg[0], seg[1])
				var r := d / radius
				per_bone_weights[bi][i] *= exp(-locality * r * r)

	# Chain adjacency: restrict each vertex to its dominant bone plus the single
	# strongest hierarchy-neighbour (parent or child). The two kept bones are
	# always adjacent, so non-neighbouring bones (e.g. root and tip of a limb)
	# never share a vertex — matching hand-painted 2-bone joint blends.
	var adjacency := _build_adjacency(bones) if chain_adjacency else []
	if chain_adjacency:
		for i in n:
			var dom := 0
			var dom_w := -1.0
			for bi in bones.size():
				if per_bone_weights[bi][i] > dom_w:
					dom_w = per_bone_weights[bi][i]
					dom = bi
			var best_neighbor := -1
			var best_neighbor_w := -1.0
			for nb in adjacency[dom].keys():
				if nb == dom:
					continue
				if per_bone_weights[nb][i] > best_neighbor_w:
					best_neighbor_w = per_bone_weights[nb][i]
					best_neighbor = nb
			for bi in bones.size():
				if bi != dom and bi != best_neighbor:
					per_bone_weights[bi][i] = 0.0

	# Joint blend. The heat weights decide bone IDENTITY (they follow the flesh, so
	# a bulge of thigh that hangs past the knee stays thigh); the joint circles only
	# decide WHERE to smooth. Each limb segment becomes a solid single bone, with a
	# transition band only at the joints:
	#   * OUTSIDE every joint circle -> snap to the heat-dominant bone (weight 1).
	#     Crisp single-bone regions that respect the mesh shape.
	#   * INSIDE the nearest joint circle -> blend that joint's two incident bones
	#     by their heat ratio, faded from the dominant bone at the rim to the full
	#     ratio at the centre (smoothstep). No hard cut, no medial crease.
	# radius = joint_blend * 0.5*(len_parent+len_child): slider shrinks/grows the
	# band. Near 0 -> tiny circles -> everything crisp.
	if joint_blend > 0.0:
		var circles := _build_joint_circles(bones, segs, joint_blend)
		var heat: Array = []
		for bi in bones.size():
			heat.append(per_bone_weights[bi].duplicate())
		for i in n:
			var dom := 0
			var dom_w := -1.0
			for bi in bones.size():
				if heat[bi][i] > dom_w:
					dom_w = heat[bi][i]
					dom = bi
			# Nearest joint circle containing this vertex.
			var best := -1
			var best_ratio := INF
			for ci in circles.size():
				var c: Dictionary = circles[ci]
				var d: float = world_pts[i].distance_to(c["center"])
				if d < c["radius"]:
					var r := d / maxf(c["radius"], EPS)
					if r < best_ratio:
						best_ratio = r
						best = ci
			for bi in bones.size():
				per_bone_weights[bi][i] = 0.0
			if best == -1:
				per_bone_weights[dom][i] = 1.0
				continue
			var c: Dictionary = circles[best]
			var pi: int = c["parent_idx"]
			var bj: int = c["bone_idx"]
			# Blend the pair by SPATIAL distance ratio to the two bone segments (a
			# real gradient across the band even when heat is crisp), faded from the
			# nearer-segment bone at the rim to the full ratio at the centre.
			var d_par := _dist_point_to_segment(world_pts[i], segs[pi][0], segs[pi][1])
			var d_chi := _dist_point_to_segment(world_pts[i], segs[bj][0], segs[bj][1])
			var denom := d_par + d_chi
			var ratio_pi: float = 0.5 if denom < EPS else d_chi / denom # closer to parent -> more parent
			var dom_pi: float = 1.0 if d_par <= d_chi else 0.0 # nearer segment at the rim
			var prox := clampf(1.0 - best_ratio, 0.0, 1.0)
			prox = prox * prox * (3.0 - 2.0 * prox)
			var wp := lerpf(dom_pi, ratio_pi, prox)
			per_bone_weights[pi][i] = wp
			per_bone_weights[bj][i] = 1.0 - wp

	# Per-vertex: keep top-N bones, normalize.
	for i in n:
		# Gather (weight, bone) and keep the strongest max_bones.
		if max_bones > 0 and max_bones < bones.size():
			var idx := []
			for bi in bones.size():
				idx.append(bi)
			idx.sort_custom(func(a, b): return per_bone_weights[a][i] > per_bone_weights[b][i])
			for k in range(max_bones, bones.size()):
				per_bone_weights[idx[k]][i] = 0.0
		var total := 0.0
		for bi in bones.size():
			total += per_bone_weights[bi][i]
		if total > 0.0:
			for bi in bones.size():
				per_bone_weights[bi][i] = per_bone_weights[bi][i] / total
		else:
			# No influence at all: dump full weight on nearest.
			per_bone_weights[nearest[i]][i] = 1.0

	# Cast to float32 and key by skeleton-relative NodePath.
	for bi in bones.size():
		var bone: Bone2D = bones[bi]
		var path := skeleton.get_path_to(bone)
		var f32 := PackedFloat32Array()
		f32.resize(n)
		for i in n:
			f32[i] = per_bone_weights[bi][i]
		res.weights[path] = f32

	# Report the joint circles actually used (falls back to a small default when
	# joint_blend is 0 so the debug markers still show where the joints are).
	res.joints = _detect_joints(bones, segs, skeleton, maxf(joint_blend, 0.15))

	res.ok = true
	return res


## Joint circles used for weight assignment. A joint sits at the origin of every
## bone that has a parent Bone2D. Its circle radius scales with the two adjacent
## bone sizes and `joint_blend` (the slider), so a bigger slider = bigger joint.
## Returns Array of { parent_idx, bone_idx, center, radius }.
static func _build_joint_circles(bones: Array, segs: Array, joint_blend: float) -> Array:
	var out: Array = []
	for bi in bones.size():
		var pi := bones.find(bones[bi].get_parent())
		if pi == -1:
			continue
		var la: float = segs[pi][0].distance_to(segs[pi][1])
		var lb: float = segs[bi][0].distance_to(segs[bi][1])
		# Radius = slider * average adjacent bone length. Circle centred on the
		# joint; average keeps it in scale with the limb.
		var radius := joint_blend * maxf(0.5 * (la + lb), EPS)
		out.append({
			"parent_idx": pi,
			"bone_idx": bi,
			"center": bones[bi].global_position,
			"radius": radius,
		})
	return out


## Joint-area descriptors for the debug markers. Reuses the same circles as the
## weight solve so the drawn marker matches the real blend region. Returns Array
## of { bone, parent (skeleton-relative NodePath), center_world, radius }.
static func _detect_joints(bones: Array, segs: Array, skeleton: Node, joint_blend: float) -> Array:
	var out: Array = []
	for c in _build_joint_circles(bones, segs, joint_blend):
		var child: Bone2D = bones[c["bone_idx"]]
		out.append({
			"bone": skeleton.get_path_to(child),
			"parent": skeleton.get_path_to(bones[c["parent_idx"]]),
			"center_world": c["center"],
			"radius": c["radius"],
		})
	return out
