@tool
class_name AutoWeightSkeletonTemplates
extends RefCounted

## Skeleton2D + Bone2D template builder. Each template is declarative data — a
## list of bones {name, parent, pos} in a natural template space (y-down, Godot
## convention). build() scales that to a target bounds and instantiates a real
## Skeleton2D hierarchy. Pure construction (no editor deps) so it is testable
## headless; the dock assigns owners + wraps it in undo/redo.

const DEFAULT_SIZE := 200.0


static func template_ids() -> PackedStringArray:
	return PackedStringArray(["humanoid", "quadruped", "snake", "tentacle"])


## Build a Skeleton2D for `id`. If target_bounds has a non-zero size the rig is
## scaled uniformly to fit (centered on it); otherwise a fixed default size is
## used. `segments` only affects the snake/tentacle chains. Caller owns the node.
static func build(id: String, target_bounds: Rect2, segments: int = 8) -> Skeleton2D:
	var defs := _definitions(id, segments)
	if defs.is_empty():
		return null

	# Natural bbox of the template.
	var mn: Vector2 = defs[0].pos
	var mx: Vector2 = defs[0].pos
	for d in defs:
		mn = mn.min(d.pos)
		mx = mx.max(d.pos)
	var natural_size := mx - mn
	var natural_center := (mn + mx) * 0.5

	# Uniform scale + placement.
	var scale := 1.0
	var center := Vector2.ZERO
	if target_bounds.size.x > 0.0 and target_bounds.size.y > 0.0 \
			and natural_size.x > 0.0 and natural_size.y > 0.0:
		scale = minf(target_bounds.size.x / natural_size.x, target_bounds.size.y / natural_size.y)
		center = target_bounds.position + target_bounds.size * 0.5
	else:
		var m := maxf(natural_size.x, natural_size.y)
		if m > 0.0:
			scale = DEFAULT_SIZE / m

	# Offsets relative to the skeleton origin, in world scale.
	var offsets := PackedVector2Array()
	offsets.resize(defs.size())
	for i in defs.size():
		offsets[i] = (defs[i].pos - natural_center) * scale

	var skeleton := Skeleton2D.new()
	skeleton.name = id.capitalize() + "Skeleton"
	skeleton.position = center

	var nodes: Array = []  # Array[Bone2D], index-aligned with defs
	nodes.resize(defs.size())
	for i in defs.size():
		var bone := Bone2D.new()
		bone.name = defs[i].name
		var parent_i: int = defs[i].parent
		var parent_offset := offsets[parent_i] if parent_i >= 0 else Vector2.ZERO
		bone.position = offsets[i] - parent_offset
		bone.rotation = 0.0
		nodes[i] = bone
		if parent_i >= 0:
			nodes[parent_i].add_child(bone)
		else:
			skeleton.add_child(bone)

	# Length + angle from each bone to its first child (visual direction). Leaves
	# continue their parent's direction. auto_calculate_length_and_angle=false so
	# the envelope solver's _child_segment sees a real length on leaves too.
	for i in defs.size():
		var child_i := _first_child(defs, i)
		var seg: Vector2
		if child_i >= 0:
			seg = offsets[child_i] - offsets[i]
		else:
			var parent_i: int = defs[i].parent
			seg = offsets[i] - offsets[parent_i] if parent_i >= 0 else Vector2(DEFAULT_SIZE * scale, 0)
		if seg.length() < 0.001:
			seg = Vector2(DEFAULT_SIZE * scale, 0)
		nodes[i].set_autocalculate_length_and_angle(false)
		nodes[i].set_length(seg.length())
		nodes[i].set_bone_angle(seg.angle())

	# Bind pose = the pose we just built.
	for bone in nodes:
		bone.rest = bone.transform

	return skeleton


static func _first_child(defs: Array, i: int) -> int:
	for j in defs.size():
		if defs[j].parent == i:
			return j
	return -1


## Declarative bone lists. pos is absolute in template space (y-down, up = -y).
static func _definitions(id: String, segments: int) -> Array:
	match id:
		"humanoid":
			return _humanoid()
		"quadruped":
			return _quadruped()
		"snake":
			return _chain(maxi(2, segments), Vector2(20, 0))
		"tentacle":
			return _chain(maxi(2, segments), Vector2(0, 20))
		_:
			return []


static func _bone(name: String, parent: int, pos: Vector2) -> Dictionary:
	return {"name": name, "parent": parent, "pos": pos}


static func _chain(count: int, step: Vector2) -> Array:
	var out: Array = []
	for i in count:
		out.append(_bone("Segment%d" % (i + 1), i - 1, step * i))
	return out


static func _humanoid() -> Array:
	# Spine up the center, arms hanging, legs down. Indices referenced by parent.
	return [
		_bone("Pelvis", -1, Vector2(0, 0)),        # 0
		_bone("Spine", 0, Vector2(0, -30)),         # 1
		_bone("Chest", 1, Vector2(0, -60)),         # 2
		_bone("Neck", 2, Vector2(0, -80)),          # 3
		_bone("Head", 3, Vector2(0, -95)),          # 4
		_bone("UpperArmL", 2, Vector2(-18, -62)),   # 5
		_bone("ForearmL", 5, Vector2(-24, -38)),    # 6
		_bone("HandL", 6, Vector2(-28, -16)),       # 7
		_bone("UpperArmR", 2, Vector2(18, -62)),    # 8
		_bone("ForearmR", 8, Vector2(24, -38)),     # 9
		_bone("HandR", 9, Vector2(28, -16)),        # 10
		_bone("ThighL", 0, Vector2(-10, 0)),        # 11
		_bone("ShinL", 11, Vector2(-12, 35)),       # 12
		_bone("FootL", 12, Vector2(-12, 68)),       # 13
		_bone("ThighR", 0, Vector2(10, 0)),         # 14
		_bone("ShinR", 14, Vector2(12, 35)),        # 15
		_bone("FootR", 15, Vector2(12, 68)),        # 16
	]


static func _quadruped() -> Array:
	# Side view, facing +x. Spine horizontal, legs down, tail back, neck/head up.
	return [
		_bone("Hip", -1, Vector2(0, 0)),            # 0
		_bone("Spine1", 0, Vector2(30, 0)),          # 1
		_bone("Spine2", 1, Vector2(60, 0)),          # 2
		_bone("Neck", 2, Vector2(78, -10)),          # 3
		_bone("Head", 3, Vector2(94, -18)),          # 4
		_bone("Tail1", 0, Vector2(-22, 4)),          # 5
		_bone("Tail2", 5, Vector2(-44, 10)),         # 6
		_bone("FrontUpper", 2, Vector2(58, 22)),     # 7
		_bone("FrontLower", 7, Vector2(58, 48)),     # 8
		_bone("FrontPaw", 8, Vector2(58, 66)),       # 9
		_bone("BackUpper", 0, Vector2(4, 22)),       # 10
		_bone("BackLower", 10, Vector2(4, 48)),      # 11
		_bone("BackPaw", 11, Vector2(4, 66)),        # 12
	]
