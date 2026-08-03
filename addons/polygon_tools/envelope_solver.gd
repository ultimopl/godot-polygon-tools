@tool
class_name AutoWeightEnvelopeSolver
extends RefCounted

## Bone-envelope (capsule) weight solver for Polygon2D + Skeleton2D.
##
## Each bone owns a capsule: a vertex's weight for a bone is a smooth falloff of
## its distance to that bone's world segment. Overlapping capsules blend naturally
## at the joints, giving crisp single-bone limb regions with a smooth transition
## band only where two envelopes meet. No mesh Laplacian, no triangulation — fully
## deterministic and directly tunable. Not mesh-shape-aware, so a sharply folded
## limb can bleed across the bend; the optional visibility test mitigates that.
##
## Reuses the shared geometry statics on `AutoWeightBoneHeatSolver`
## (collect_bones, bone_segment, _dist_point_to_segment, _segment_inside_polygon).

const Geo := preload("res://addons/polygon_tools/bone_heat_solver.gd")
const EPS := 1e-6

## Result of a compute() call. Same shape the dock's Calculate/marker code reads.
class Result:
	var weights: Dictionary = {} # NodePath (relative to skeleton) -> PackedFloat32Array
	var vertex_count := 0
	var bone_count := 0
	var warnings: PackedStringArray = PackedStringArray()
	var joints: Array = [] # Array of { bone, parent, center_world, radius }
	var envelopes: Array = [] # Array of { bone, a_world, b_world, radius } for debug
	var ok := false


## Compute bone weights.
## params keys: radius_scale (float), softness (float 0..1),
##   max_bones_per_vertex (int), use_visibility (bool).
static func compute(polygon: Polygon2D, skeleton: Node, params: Dictionary) -> Result:
	var res := Result.new()
	var radius_scale: float = params.get("radius_scale", 0.8)
	var softness: float = clampf(params.get("softness", 0.3), 0.0, 1.0)
	var max_bones: int = params.get("max_bones_per_vertex", 4)
	var use_visibility: bool = params.get("use_visibility", true)

	var local_pts := polygon.polygon
	var n := local_pts.size()
	res.vertex_count = n
	if n < 3:
		res.warnings.append("Polygon has fewer than 3 vertices.")
		return res

	var bones := Geo.collect_bones(skeleton)
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

	# Boundary outline only (internal vertices are appended at the end of `polygon`
	# and would corrupt is_point_in_polygon if included). Used by the visibility
	# test — passing the full point list wrongly flags interior vertices as hidden.
	var outline_world := world_pts.slice(0, n - polygon.get_internal_vertex_count())

	# World-space bone segments running from each bone toward its CHILD bone (the
	# way Godot draws a bone). Using Bone2D.global_rotation + get_length is wrong
	# when auto_calculate_length_and_angle is on: the rotation is 0 and the segment
	# comes out perpendicular to the limb. A leaf bone (no child) extends along the
	# direction from its parent. Bind uses the current on-screen pose, so reset any
	# live IK bend before calculating.
	var segs: Array = []
	for bi in bones.size():
		segs.append(_child_segment(bones[bi], bones))

	# Distance from every vertex to every bone segment (reused below), plus the
	# nearest bone per vertex for the coverage fallback.
	var dists: Array = [] # Array[PackedFloat32Array], one per bone
	for bi in bones.size():
		var d := PackedFloat32Array()
		d.resize(n)
		dists.append(d)
	var nearest := PackedInt32Array()
	nearest.resize(n)
	var nearest_d := PackedFloat32Array()
	nearest_d.resize(n)
	for i in n:
		var best := 0
		var best_d := INF
		for bi in bones.size():
			var d: float = Geo._dist_point_to_segment(world_pts[i], segs[bi][0], segs[bi][1])
			dists[bi][i] = d
			if d < best_d:
				best_d = d
				best = bi
		nearest[i] = best
		nearest_d[i] = best_d

	# Per-bone envelope radius = how far that bone's OWN flesh reaches. A vertex is
	# "owned" by its nearest bone; the bone's radius is the farthest owned vertex.
	# So the thigh bone (wide flesh) gets a big capsule and the foot a small one —
	# one global radius can't do both (cover wide flesh AND stay crisp). Falls back
	# to half the bone length when a bone owns nothing.
	var owned_max := PackedFloat32Array()
	owned_max.resize(bones.size())
	for i in n:
		var o := nearest[i]
		owned_max[o] = maxf(owned_max[o], nearest_d[i])

	var radii := PackedFloat32Array()
	radii.resize(bones.size())
	for bi in bones.size():
		var base: float = owned_max[bi]
		if base < EPS:
			base = 0.5 * segs[bi][0].distance_to(segs[bi][1])
		radii[bi] = radius_scale * maxf(base, EPS)
		res.envelopes.append({
			"bone": skeleton.get_path_to(bones[bi]),
			"a_world": segs[bi][0],
			"b_world": segs[bi][1],
			"radius": radii[bi],
		})

	# Envelope weight from RELATIVE distance d/radius, so every bone is scored on
	# its own scale — a vertex goes to whichever bone it is nearest relative to that
	# bone's region, not just the bone with the smallest capsule. w = 1 inside the
	# region (rd < 1-softness), 0 beyond (rd > 1+softness), smooth band between.
	var lo := 1.0 - softness
	var hi := 1.0 + softness
	var per_bone := [] # Array[PackedFloat32Array]
	for bi in bones.size():
		var arr := PackedFloat32Array()
		arr.resize(n)
		per_bone.append(arr)
	for i in n:
		for bi in bones.size():
			var rd: float = dists[bi][i] / maxf(radii[bi], EPS)
			var w := 1.0 - smoothstep(lo, hi, rd)
			# Never visibility-zero a vertex's OWN nearest bone — its own flesh can't
			# be occluded from the bone it is closest to. Visibility only prunes the
			# OTHER bones (a far bone reaching across a fold). Testing the nearest bone
			# just produces isolated false negatives where the sampled line grazes a
			# concave part of the outline.
			if w > 0.0 and use_visibility and bi != nearest[i]:
				var target := Geometry2D.get_closest_point_to_segment(world_pts[i], segs[bi][0], segs[bi][1])
				if not Geo._segment_inside_polygon(world_pts[i], target, outline_world):
					w = 0.0
			per_bone[bi][i] = w

	# Keep top-N, normalize; empty vertices fall back to their nearest bone.
	for i in n:
		if max_bones > 0 and max_bones < bones.size():
			var idx := []
			for bi in bones.size():
				idx.append(bi)
			idx.sort_custom(func(a, b): return per_bone[a][i] > per_bone[b][i])
			for k in range(max_bones, bones.size()):
				per_bone[idx[k]][i] = 0.0
		var total := 0.0
		for bi in bones.size():
			total += per_bone[bi][i]
		if total > EPS:
			for bi in bones.size():
				per_bone[bi][i] = per_bone[bi][i] / total
		else:
			for bi in bones.size():
				per_bone[bi][i] = 0.0
			per_bone[nearest[i]][i] = 1.0

	# Emit weights keyed by skeleton-relative NodePath.
	for bi in bones.size():
		var f32 := PackedFloat32Array()
		f32.resize(n)
		for i in n:
			f32[i] = per_bone[bi][i]
		res.weights[skeleton.get_path_to(bones[bi])] = f32

	res.joints = _detect_joints(bones, segs, world_pts, per_bone, skeleton)
	res.ok = true
	return res


## Laplacian-smooth a Polygon2D's existing bone weights over the mesh. Each pass
## moves every vertex's per-bone weight toward the average of its mesh neighbours
## by `strength` (0 = no change, 1 = full average), then renormalizes per vertex so
## the weights still sum to 1. Mesh adjacency comes from `polygon.polygons` (falls
## back to a Delaunay triangulation of the points). Returns a weights dict
## { bone_path : PackedFloat32Array }, or empty if the polygon has no bone weights.
static func smooth_polygon_weights(polygon: Polygon2D, strength: float, iterations: int = 1) -> Dictionary:
	var n := polygon.polygon.size()
	if n == 0:
		return {}
	var paths: Array = []
	var weights: Array = [] # Array[PackedFloat32Array]
	for bi in polygon.get_bone_count():
		var w := polygon.get_bone_weights(bi)
		if w.size() == n:
			paths.append(polygon.get_bone_path(bi))
			weights.append(w.duplicate())
	if paths.is_empty():
		return {}

	# Vertex adjacency from the mesh faces (or Delaunay if none are set).
	var neighbors: Array = []
	neighbors.resize(n)
	for v in n:
		neighbors[v] = {}
	var faces := polygon.polygons
	if faces.is_empty():
		var tris := Geometry2D.triangulate_delaunay(polygon.polygon)
		var t := 0
		while t + 2 < tris.size():
			_link(neighbors, tris[t], tris[t + 1], n)
			_link(neighbors, tris[t + 1], tris[t + 2], n)
			_link(neighbors, tris[t + 2], tris[t], n)
			t += 3
	else:
		for face in faces:
			var m: int = face.size()
			for k in m:
				_link(neighbors, face[k], face[(k + 1) % m], n)

	var s := clampf(strength, 0.0, 1.0)
	for _it in maxi(iterations, 1):
		var next: Array = []
		for bi in weights.size():
			next.append((weights[bi] as PackedFloat32Array).duplicate())
		for v in n:
			var nb: Array = neighbors[v].keys()
			if nb.is_empty():
				continue
			for bi in weights.size():
				var acc := 0.0
				for u in nb:
					acc += weights[bi][u]
				next[bi][v] = lerpf(weights[bi][v], acc / nb.size(), s)
		# Renormalize per vertex.
		for v in n:
			var total := 0.0
			for bi in weights.size():
				total += next[bi][v]
			if total > EPS:
				for bi in weights.size():
					next[bi][v] = next[bi][v] / total
		weights = next

	var out := {}
	for bi in paths.size():
		out[paths[bi]] = weights[bi]
	return out


static func _link(neighbors: Array, a: int, b: int, n: int) -> void:
	if a >= 0 and a < n and b >= 0 and b < n and a != b:
		neighbors[a][b] = true
		neighbors[b][a] = true


## World (start, end) segment for a bone, pointing toward its child bone (the
## visual bone direction). Leaf bones extend along their parent's direction, using
## get_length() or, if that is ~0, the parent-bone spacing as a fallback.
static func _child_segment(bone: Bone2D, bones: Array) -> Array:
	var start: Vector2 = bone.global_position
	# First child that is itself a bone.
	for child in bone.get_children():
		if child is Bone2D:
			return [start, (child as Bone2D).global_position]
	# Leaf bone: continue along the direction from the parent bone.
	var parent := bone.get_parent()
	var dir := Vector2.RIGHT.rotated(bone.global_rotation)
	var fallback_len := 0.0
	if parent is Bone2D:
		var to_here: Vector2 = start - (parent as Bone2D).global_position
		if to_here.length() > EPS:
			dir = to_here.normalized()
			fallback_len = to_here.length()
	var length := bone.get_length()
	if length < EPS:
		length = fallback_len if fallback_len > EPS else 1.0
	return [start, start + dir * length]


## Smoothstep: 0 for x<=edge0, 1 for x>=edge1, cubic in between.
static func smoothstep(edge0: float, edge1: float, x: float) -> float:
	if edge1 <= edge0:
		return 0.0 if x < edge1 else 1.0
	var t := clampf((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## Joint descriptors for the debug markers. A joint sits at the origin of every
## bone that has a parent Bone2D; radius = the actual overlap band (max distance,
## from the joint, of vertices the two adjacent envelopes both weight > 0.1) with a
## small fallback. Same dict shape the dock's marker code reads.
static func _detect_joints(bones: Array, segs: Array, world_pts: PackedVector2Array, per_bone: Array, skeleton: Node) -> Array:
	var out: Array = []
	var n := world_pts.size()
	for bi in bones.size():
		var child: Bone2D = bones[bi]
		var parent := child.get_parent()
		var pi := bones.find(parent)
		if pi == -1:
			continue
		var joint_world: Vector2 = segs[bi][0] # rest-pose joint origin
		var radius := 0.0
		var count := 0
		for v in n:
			if per_bone[pi][v] > 0.1 and per_bone[bi][v] > 0.1:
				radius = maxf(radius, world_pts[v].distance_to(joint_world))
				count += 1
		if count == 0:
			radius = 4.0
		out.append({
			"bone": skeleton.get_path_to(child),
			"parent": skeleton.get_path_to(parent),
			"center_world": joint_world,
			"radius": radius,
		})
	return out
