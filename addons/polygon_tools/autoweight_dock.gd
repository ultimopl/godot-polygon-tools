@tool
extends Control

## Dock UI for the AutoWeight 2D plugin. Built entirely in code (no .tscn needed)
## so the layout stays in one place.

var _editor_interface: EditorInterface
var _undo_redo: EditorUndoRedoManager

var _target: Polygon2D = null
var _skeleton: Node = null # Skeleton2D (or any node holding Bone2D children)

var _target_label: Label
var _skeleton_label: Label
var _radius_spin: SpinBox
var _max_bones_spin: SpinBox
var _visibility_check: CheckBox
var _debug_check: CheckButton
var _softness_slider: HSlider
var _softness_value: Label
var _last_joints: Array = []
var _last_envelopes: Array = []
var _smooth_slider: HSlider
var _smooth_value: Label
var _calc_button: Button
var _smooth_button: Button
var _recalc_button: Button
var _subdivide_button: Button
var _status_label: RichTextLabel


func setup(editor_interface: EditorInterface, undo_redo: EditorUndoRedoManager) -> void:
	_editor_interface = editor_interface
	_undo_redo = undo_redo


func _ready() -> void:
	name = "Polygon Tools"
	custom_minimum_size = Vector2(280, 300)
	_build_ui()
	_refresh_selection()


func _build_ui() -> void:
	# ScrollContainer fills the dock; its content scrolls vertically when the
	# dock is shorter than the controls.
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	# Expand to the ScrollContainer's width so children wrap instead of scrolling
	# sideways; height stays content-driven so the vertical scrollbar appears.
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(vb)

	var title := Label.new()
	title.text = "Polygon Tools"
	title.add_theme_font_size_override("font_size", 16)
	vb.add_child(title)

	_target_label = Label.new()
	_target_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(_target_label)

	_skeleton_label = Label.new()
	_skeleton_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(_skeleton_label)

	vb.add_child(HSeparator.new())

	_radius_spin = _add_spin(vb, "Envelope radius", 0.1, 3.0, 0.05, 1.0)
	_radius_spin.tooltip_text = "Scale on each bone's capsule. Each bone is auto-sized to its own flesh region; 1.0 = exact fit, higher reaches into neighbours."
	_max_bones_spin = _add_spin(vb, "Max bones / vertex", 1, 8, 1, 4)

	_visibility_check = CheckBox.new()
	_visibility_check.text = "Use visibility test"
	_visibility_check.tooltip_text = "Ignore a bone for a vertex when the straight line to it leaves the polygon (stops cross-bend bleed)."
	_visibility_check.button_pressed = true
	vb.add_child(_visibility_check)

	_debug_check = CheckButton.new()
	_debug_check.text = "Debug mode"
	_debug_check.tooltip_text = "Draw a marker (Area2D) at each detected joint area after calculating weights."
	_debug_check.toggled.connect(_on_debug_toggled)
	vb.add_child(_debug_check)

	# Blend softness: width of the transition band where two envelopes overlap.
	var jhb := HBoxContainer.new()
	var jlabel := Label.new()
	jlabel.text = "Blend softness"
	jlabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	jhb.add_child(jlabel)
	_softness_value = Label.new()
	_softness_value.custom_minimum_size = Vector2(32, 0)
	jhb.add_child(_softness_value)
	vb.add_child(jhb)

	_softness_slider = HSlider.new()
	_softness_slider.min_value = 0.0
	_softness_slider.max_value = 1.0
	_softness_slider.step = 0.01
	_softness_slider.value = 0.3
	_softness_slider.tooltip_text = "How soft the capsule edge is: 0 = hard, crisp single-bone regions; 1 = wide smooth blend at the joints. Re-run Calculate Weights to apply."
	_softness_slider.value_changed.connect(_on_softness_changed)
	vb.add_child(_softness_slider)
	_softness_value.text = "%.2f" % _softness_slider.value

	vb.add_child(HSeparator.new())

	_calc_button = Button.new()
	_calc_button.text = "Calculate Weights"
	_calc_button.pressed.connect(_on_calculate_pressed)
	vb.add_child(_calc_button)

	# Smooth: Laplacian-relax the current weights. Strength slider + button; each
	# press applies one smoothing pass (click again to smooth further).
	var shb := HBoxContainer.new()
	var slabel := Label.new()
	slabel.text = "Smooth strength"
	slabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	shb.add_child(slabel)
	_smooth_value = Label.new()
	_smooth_value.custom_minimum_size = Vector2(32, 0)
	shb.add_child(_smooth_value)
	vb.add_child(shb)

	_smooth_slider = HSlider.new()
	_smooth_slider.min_value = 0.0
	_smooth_slider.max_value = 1.0
	_smooth_slider.step = 0.01
	_smooth_slider.value = 0.5
	_smooth_slider.tooltip_text = "How hard each Smooth pass pulls every vertex's weights toward its mesh neighbours' average."
	_smooth_slider.value_changed.connect(_on_smooth_changed)
	vb.add_child(_smooth_slider)
	_smooth_value.text = "%.2f" % _smooth_slider.value

	_smooth_button = Button.new()
	_smooth_button.text = "Smooth Weights"
	_smooth_button.tooltip_text = "Relax the polygon's current bone weights over the mesh (blends each vertex toward its neighbours). Click repeatedly for more."
	_smooth_button.pressed.connect(_on_smooth_pressed)
	vb.add_child(_smooth_button)

	_recalc_button = Button.new()
	_recalc_button.text = "Recalculate Polygons"
	_recalc_button.tooltip_text = "Re-triangulate the Polygon2D from its existing points (points unchanged)."
	_recalc_button.pressed.connect(_on_recalculate_pressed)
	vb.add_child(_recalc_button)

	_subdivide_button = Button.new()
	_subdivide_button.text = "Subdivide Mesh"
	_subdivide_button.tooltip_text = "Split every triangle edge at its midpoint (denser mesh). New vertices inherit averaged UV and bone weights, so the rig is preserved."
	_subdivide_button.pressed.connect(_on_subdivide_pressed)
	vb.add_child(_subdivide_button)

	_status_label = RichTextLabel.new()
	_status_label.fit_content = true
	_status_label.bbcode_enabled = true
	_status_label.custom_minimum_size = Vector2(0, 60)
	vb.add_child(_status_label)


func _add_spin(parent: Node, label_text: String, min_v: float, max_v: float, step: float, value: float) -> SpinBox:
	var hb := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = min_v
	spin.max_value = max_v
	spin.step = step
	spin.value = value
	hb.add_child(spin)
	parent.add_child(hb)
	return spin


func on_selection_changed() -> void:
	_refresh_selection()


func _refresh_selection() -> void:
	if _editor_interface == null:
		return
	var selected := _editor_interface.get_selection().get_selected_nodes()
	_target = null
	_skeleton = null
	for node in selected:
		if node is Polygon2D:
			_target = node
			break

	if _target == null:
		_target_label.text = "Target: (select a Polygon2D)"
		_skeleton_label.text = ""
		_calc_button.disabled = true
		_smooth_button.disabled = true
		_recalc_button.disabled = true
		_subdivide_button.disabled = true
		return

	_target_label.text = "Target: %s (%d verts)" % [_target.name, _target.polygon.size()]
	_recalc_button.disabled = _target.polygon.size() < 3
	_subdivide_button.disabled = _target.polygon.size() < 3
	_smooth_button.disabled = _target.get_bone_count() == 0

	# Resolve skeleton from Polygon2D.skeleton NodePath.
	var skel_path := _target.skeleton
	if not skel_path.is_empty():
		_skeleton = _target.get_node_or_null(skel_path)
	if _skeleton == null:
		_skeleton_label.text = "Skeleton: (Polygon2D.skeleton not set)"
		_calc_button.disabled = true
	else:
		var bones := AutoWeightBoneHeatSolver.collect_bones(_skeleton)
		_skeleton_label.text = "Skeleton: %s (%d bones)" % [_skeleton.name, bones.size()]
		_calc_button.disabled = bones.is_empty()


func _on_calculate_pressed() -> void:
	if _target == null or _skeleton == null:
		_set_status("[color=orange]No valid Polygon2D / Skeleton2D selected.[/color]")
		return

	var params := {
		"radius_scale": _radius_spin.value,
		"softness": _softness_slider.value,
		"max_bones_per_vertex": int(_max_bones_spin.value),
		"use_visibility": _visibility_check.button_pressed,
	}
	var result := AutoWeightEnvelopeSolver.compute(_target, _skeleton, params)
	if not result.ok:
		_set_status("[color=red]Failed:[/color] " + " ".join(result.warnings))
		return

	# Snapshot current bones for undo.
	var prev_bones := _snapshot_bones(_target)
	var new_bones := _weights_to_bone_array(result.weights)

	_undo_redo.create_action("AutoWeight: Calculate Weights")
	_undo_redo.add_do_method(self, "_apply_bones", _target, new_bones)
	_undo_redo.add_undo_method(self, "_apply_bones", _target, prev_bones)
	_undo_redo.commit_action()

	_last_joints = result.joints
	_last_envelopes = result.envelopes
	if _debug_check.button_pressed:
		_refresh_debug_markers()

	var msg := "[color=green]Done.[/color] %d verts, %d bones." % [result.vertex_count, result.bone_count]
	if _debug_check.button_pressed:
		msg += " %d joints." % _last_joints.size()
	if not result.warnings.is_empty():
		msg += "\n[color=orange]" + "\n".join(result.warnings) + "[/color]"
	_set_status(msg)


func _on_debug_toggled(pressed: bool) -> void:
	if pressed:
		_refresh_debug_markers()
	else:
		_clear_debug_markers()


func _on_softness_changed(value: float) -> void:
	_softness_value.text = "%.2f" % value


func _on_smooth_changed(value: float) -> void:
	_smooth_value.text = "%.2f" % value


func _on_smooth_pressed() -> void:
	if _target == null:
		_set_status("[color=orange]No Polygon2D selected.[/color]")
		return
	if _target.get_bone_count() == 0:
		_set_status("[color=orange]No weights to smooth — Calculate Weights first.[/color]")
		return

	var new_weights := AutoWeightEnvelopeSolver.smooth_polygon_weights(_target, _smooth_slider.value, 2)
	if new_weights.is_empty():
		_set_status("[color=orange]Nothing to smooth.[/color]")
		return

	var prev_bones := _snapshot_bones(_target)
	var new_bones := _weights_to_bone_array(new_weights)

	_undo_redo.create_action("Polygon Tools: Smooth Weights")
	_undo_redo.add_do_method(self, "_apply_bones", _target, new_bones)
	_undo_redo.add_undo_method(self, "_apply_bones", _target, prev_bones)
	_undo_redo.commit_action()

	if _debug_check.button_pressed:
		_refresh_debug_markers()
	_set_status("[color=green]Smoothed.[/color] strength %.2f" % _smooth_slider.value)


## Marker node name prefixes so previously-created debug markers can be found and
## cleared even across editor sessions.
const _JOINT_MARKER_PREFIX := "JointDebug_"
const _ENVELOPE_MARKER_PREFIX := "EnvelopeDebug_"


func _refresh_debug_markers() -> void:
	_clear_debug_markers()
	if _skeleton == null or _editor_interface == null:
		return
	var root := _editor_interface.get_edited_scene_root()
	if root == null:
		return
	_refresh_envelope_markers(root)
	_refresh_joint_markers(root)


## Draw each bone's capsule (the envelope) as an Area2D + CapsuleShape2D at the
## bind-pose segment. Parented under the skeleton (static) so the shapes show the
## regions the weights were computed from.
func _refresh_envelope_markers(root: Node) -> void:
	for e in _last_envelopes:
		var a: Vector2 = e["a_world"]
		var b: Vector2 = e["b_world"]
		var radius: float = maxf(e["radius"], 1.0)
		var seg_len := a.distance_to(b)
		var area := Area2D.new()
		area.name = _ENVELOPE_MARKER_PREFIX + String(e["bone"]).replace("/", "_")
		area.modulate = Color(0.1, 0.8, 1.0, 0.25)
		var shape := CollisionShape2D.new()
		var cap := CapsuleShape2D.new()
		cap.radius = radius
		cap.height = seg_len + 2.0 * radius # total height includes the two caps
		shape.shape = cap
		area.add_child(shape)
		_skeleton.add_child(area)
		area.owner = root
		shape.owner = root
		# Capsule long axis is local Y; align it with the segment.
		area.global_position = (a + b) * 0.5
		area.global_rotation = (b - a).angle() + PI * 0.5


func _refresh_joint_markers(root: Node) -> void:
	for j in _last_joints:
		var bone: Node = _skeleton.get_node_or_null(j["bone"])
		if bone == null or not bone is Node2D:
			continue
		var area := Area2D.new()
		area.name = _JOINT_MARKER_PREFIX + String(bone.name)
		area.modulate = Color(1.0, 0.4, 0.1, 0.5)
		var shape := CollisionShape2D.new()
		var circ := CircleShape2D.new()
		circ.radius = maxf(j["radius"], 1.0)
		shape.shape = circ
		area.add_child(shape)
		# Parent under the joint's bone so the marker tracks it through IK.
		bone.add_child(area)
		area.owner = root
		shape.owner = root
		area.global_position = j["center_world"]


func _clear_debug_markers() -> void:
	if _skeleton == null:
		return
	for m in _find_debug_markers(_skeleton):
		m.free()


## Recursively collect existing debug marker nodes (joints + envelopes) under `node`.
func _find_debug_markers(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		var nm := String(child.name)
		if child is Area2D and (nm.begins_with(_JOINT_MARKER_PREFIX) or nm.begins_with(_ENVELOPE_MARKER_PREFIX)):
			out.append(child)
		out.append_array(_find_debug_markers(child))
	return out


func _on_recalculate_pressed() -> void:
	if _target == null:
		_set_status("[color=orange]No Polygon2D selected.[/color]")
		return

	var pts := _target.polygon
	if pts.size() < 3:
		_set_status("[color=orange]Polygon needs at least 3 points.[/color]")
		return

	# The outline is the boundary points; any internal vertices are appended
	# at the end of `polygon` and counted by internal_vertex_count.
	var outline := pts.slice(0, pts.size() - _target.get_internal_vertex_count())

	# Delaunay considers the actual point positions (not just boundary order)
	# and includes internal vertices. It triangulates the convex hull, so drop
	# any triangle whose centroid lies outside the (possibly concave) outline.
	var tris := Geometry2D.triangulate_delaunay(pts)
	if tris.is_empty():
		_set_status("[color=red]Triangulation failed[/color] (degenerate/collinear points).")
		return

	var new_polys: Array = []
	var t := 0
	while t + 2 < tris.size():
		var ia := tris[t]
		var ib := tris[t + 1]
		var ic := tris[t + 2]
		var centroid := (pts[ia] + pts[ib] + pts[ic]) / 3.0
		if outline.size() < 3 or Geometry2D.is_point_in_polygon(centroid, outline):
			new_polys.append(PackedInt32Array([ia, ib, ic]))
		t += 3

	if new_polys.is_empty():
		_set_status("[color=red]No triangles inside the outline.[/color]")
		return

	var prev_polys := _target.polygons.duplicate(true)

	_undo_redo.create_action("Polygon Tools: Recalculate Polygons")
	_undo_redo.add_do_property(_target, "polygons", new_polys)
	_undo_redo.add_undo_property(_target, "polygons", prev_polys)
	_undo_redo.commit_action()

	_set_status("[color=green]Done.[/color] %d triangles from %d points." % [new_polys.size(), pts.size()])


func _on_subdivide_pressed() -> void:
	if _target == null:
		_set_status("[color=orange]No Polygon2D selected.[/color]")
		return

	var n := _target.polygon.size()
	var res := AutoWeightMeshSubdivide.subdivide(_target)
	if not res.ok:
		_set_status("[color=red]Subdivide failed:[/color] " + res.warning)
		return

	var new_bones_flat: Array = []
	for bi in res.bone_paths.size():
		new_bones_flat.append(res.bone_paths[bi])
		new_bones_flat.append(res.bone_weights[bi])

	# Snapshot for undo.
	var old_bones_flat := _snapshot_bones(_target)
	var old_pts := _target.polygon
	var old_uv := _target.uv
	var old_polys: Array = _target.polygons.duplicate(true)
	var old_internal := _target.get_internal_vertex_count()

	_undo_redo.create_action("Polygon Tools: Subdivide Mesh")
	_undo_redo.add_do_method(self, "_apply_mesh", _target, res.points, res.uv, res.internal_count, res.polygons, new_bones_flat)
	_undo_redo.add_undo_method(self, "_apply_mesh", _target, old_pts, old_uv, old_internal, old_polys, old_bones_flat)
	_undo_redo.commit_action()

	_refresh_selection()
	_set_status("[color=green]Done.[/color] %d -> %d verts, %d triangles." % [n, res.points.size(), res.polygons.size()])


## Rebuild the whole Polygon2D mesh atomically. Order matters: clear bones and
## polygons before resizing `polygon` so no stale index ever references a vertex
## beyond the current point count (which hangs/crashes Godot's mesh build).
func _apply_mesh(poly: Polygon2D, pts: PackedVector2Array, uv: PackedVector2Array, internal_count: int, polys: Array, bones_flat: Array) -> void:
	poly.clear_bones()
	poly.polygons = []
	poly.internal_vertex_count = 0
	poly.polygon = pts
	poly.uv = uv
	poly.internal_vertex_count = internal_count
	poly.polygons = polys
	var i := 0
	while i + 1 < bones_flat.size():
		poly.add_bone(bones_flat[i], bones_flat[i + 1])
		i += 2


## Convert weights dict to a flat [path, PackedFloat32Array, path, ...] array
## so it survives being passed through UndoRedo method binds.
func _weights_to_bone_array(weights: Dictionary) -> Array:
	var out := []
	for path in weights.keys():
		out.append(path)
		out.append(weights[path])
	return out


func _snapshot_bones(poly: Polygon2D) -> Array:
	var out := []
	for i in poly.get_bone_count():
		out.append(poly.get_bone_path(i))
		out.append(poly.get_bone_weights(i))
	return out


## do/undo target. Rebuilds the Polygon2D bone list from a flat array.
func _apply_bones(poly: Polygon2D, flat: Array) -> void:
	poly.clear_bones()
	var i := 0
	while i + 1 < flat.size():
		poly.add_bone(flat[i], flat[i + 1])
		i += 2


func _set_status(bbcode: String) -> void:
	_status_label.text = bbcode
