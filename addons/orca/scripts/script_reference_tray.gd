@tool
extends PanelContainer

signal remove_requested(index: int)
signal open_requested(path: String)
const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")
var _grid: GridContainer
var _count := 0


func configure(references: Array, removable: bool = true) -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_count = references.size()
	var style := StyleBoxEmpty.new()
	style.set_content_margin_all(UiMetrics.scaled(4))
	add_theme_stylebox_override("panel", style)
	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.add_theme_constant_override("h_separation", UiMetrics.scaled_int(6))
	_grid.add_theme_constant_override("v_separation", UiMetrics.scaled_int(6))
	add_child(_grid)
	for index in references.size():
		var reference: Dictionary = references[index]
		var path: String = reference["filepath"]
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_theme_constant_override("separation", 0)
		_grid.add_child(row)
		var button := Button.new()
		button.text = path.get_file()
		button.clip_text = true
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.custom_minimum_size.y = UiMetrics.scaled(26)
		button.tooltip_text = path
		if removable:
			button.tooltip_text += "\nSource is captured when you send."
		elif reference.get("source_kind") == "editor":
			button.tooltip_text += "\nUnsaved editor snapshot"
		else:
			button.tooltip_text += "\nSaved disk snapshot"
		if reference.get("truncated", false):
			button.tooltip_text += "\nPartial source: lines 1–%d of %d" % [reference["included_lines"], reference["total_lines"]]
		if Engine.is_editor_hint():
			button.icon = EditorInterface.get_editor_theme().get_icon("Script", "EditorIcons")
		button.expand_icon = true
		button.add_theme_constant_override("icon_max_width", UiMetrics.scaled_int(16))
		button.add_theme_font_size_override("font_size", maxi(11, get_theme_font_size("font_size", "Label") - 1))
		var chip := StyleBoxFlat.new()
		chip.bg_color = Color(0.115, 0.12, 0.13)
		chip.border_color = Color(0.3, 0.31, 0.33)
		chip.set_border_width_all(UiMetrics.scaled_int(1))
		chip.set_corner_radius_all(UiMetrics.scaled_int(6))
		chip.set_content_margin_all(UiMetrics.scaled(5))
		button.add_theme_stylebox_override("normal", chip)
		var hover := chip.duplicate() as StyleBoxFlat
		hover.border_color = Color(0.55, 0.57, 0.6)
		button.add_theme_stylebox_override("hover", hover)
		button.add_theme_stylebox_override("pressed", hover)
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button.pressed.connect(func(): open_requested.emit(path))
		row.add_child(button)
		if removable:
			var remove := Button.new()
			remove.text = "×"
			remove.tooltip_text = "Remove script reference"
			remove.add_theme_font_size_override("font_size", button.get_theme_font_size("font_size"))
			remove.custom_minimum_size.x = UiMetrics.scaled(20)
			remove.pressed.connect(func(): remove_requested.emit(index))
			row.add_child(remove)
	visible = not references.is_empty()
	if not resized.is_connected(_sync_columns):
		resized.connect(_sync_columns)
	_sync_columns()


func _sync_columns() -> void:
	if _grid != null:
		_grid.columns = 2 if size.x >= UiMetrics.scaled(240) else 1


func height_for_width(width: float) -> float:
	var columns := 2 if width >= UiMetrics.scaled(240) else 1
	var rows := ceili(float(_count) / columns)
	var row_height := UiMetrics.scaled(30)
	if _grid != null:
		for row in _grid.get_children():
			row_height = maxf(row_height, row.get_combined_minimum_size().y)
	return UiMetrics.scaled(8 + maxi(0, rows - 1) * 6) + rows * row_height
