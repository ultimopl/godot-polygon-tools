@tool
extends EditorPlugin

const PanelScript := preload("res://addons/polygon_tools/autoweight_dock.gd")

var _panel: Control = null


func _enter_tree() -> void:
	_panel = PanelScript.new()
	_panel.setup(get_editor_interface(), get_undo_redo())
	# Persistent editor dock tab (sits alongside Inspector / Node / etc.).
	# The Control's `name` ("Polygon Tools") becomes the tab title.
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _panel)

	get_editor_interface().get_selection().selection_changed.connect(_on_selection_changed)
	_on_selection_changed()


func _exit_tree() -> void:
	if get_editor_interface().get_selection().selection_changed.is_connected(_on_selection_changed):
		get_editor_interface().get_selection().selection_changed.disconnect(_on_selection_changed)
	if _panel != null:
		remove_control_from_docks(_panel)
		_panel.queue_free()
		_panel = null


func _on_selection_changed() -> void:
	if _panel != null and _panel.has_method("on_selection_changed"):
		_panel.on_selection_changed()
