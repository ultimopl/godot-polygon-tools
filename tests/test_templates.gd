@tool
extends McpTestSuite

## Headless verification of the skeleton template builder.

const Templates := preload("res://addons/polygon_tools/skeleton_templates.gd")
const Geo := preload("res://addons/polygon_tools/bone_heat_solver.gd")


func suite_name() -> String:
	return "templates"


func test_all_ids_build() -> void:
	for id in Templates.template_ids():
		var skel = Templates.build(id, Rect2(), 8)
		assert_ne(skel, null, "build failed for '%s'" % id)
		track(skel)
		assert_true(skel is Skeleton2D, "root is Skeleton2D for '%s'" % id)
		var bones: Array = Geo.collect_bones(skel)
		assert_gt(bones.size(), 0, "no bones for '%s'" % id)
		for b in bones:
			assert_true(b is Bone2D, "non-Bone2D child in '%s'" % id)


func test_humanoid_bone_count() -> void:
	var skel = Templates.build("humanoid", Rect2(), 8)
	track(skel)
	var bones: Array = Geo.collect_bones(skel)
	assert_eq(bones.size(), 17, "humanoid bone count")


func test_snake_is_chain_of_segments() -> void:
	var skel = Templates.build("snake", Rect2(), 6)
	track(skel)
	var bones: Array = Geo.collect_bones(skel)
	assert_eq(bones.size(), 6, "snake segment count follows param")
	# Each segment (past the first) is parented to the previous Bone2D.
	for i in range(1, bones.size()):
		assert_true(bones[i].get_parent() is Bone2D, "segment %d parented to a bone" % i)


func test_scales_to_target_bounds() -> void:
	var skel = Templates.build("humanoid", Rect2(0, 0, 100, 100), 8)
	track(skel)
	var bones: Array = Geo.collect_bones(skel)
	# Global bone positions must fit inside roughly the 100x100 target box.
	var mn := Vector2(1e9, 1e9)
	var mx := Vector2(-1e9, -1e9)
	for b in bones:
		var p: Vector2 = b.global_position
		mn = mn.min(p)
		mx = mx.max(p)
	var size := mx - mn
	assert_true(size.x <= 101.0 and size.y <= 101.0, "rig fits target bounds (got %s)" % size)
