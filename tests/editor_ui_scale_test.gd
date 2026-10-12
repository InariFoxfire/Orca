extends SceneTree

const ChatWindowScene = preload("res://addons/orca/scenes/chat_window.tscn")
const ChatWindow = preload("res://addons/orca/scripts/chat_window.gd")
const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const ImageAttachments = preload("res://addons/orca/scripts/image_attachments.gd")

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_expect(Engine.is_editor_hint(), "this test must run with --editor")
	var scale := EditorInterface.get_editor_scale()
	get_root().size = Vector2i(UiMetrics.scaled_int(300), UiMetrics.scaled_int(800))
	_expect(is_equal_approx(UiMetrics.editor_scale(), scale), "UI metrics should use Godot's effective editor scale")
	var view = ChatWindowScene.instantiate()
	get_root().add_child(view)
	await process_frame
	await process_frame
	var margin := view.get_node("MarginContainer") as MarginContainer
	var logo := view.get_node("MarginContainer/VBoxContainer/ChatScroll/ChatFeed/EmptyState/Content/Logo") as TextureRect
	var mode := view.get_node("MarginContainer/VBoxContainer/Composer/ComposerContent/ComposerActions/ModeSelector") as Control
	_expect(margin.get_theme_constant("margin_left") == UiMetrics.scaled_int(10), "dock margins should follow the effective editor scale")
	_expect(logo.custom_minimum_size == UiMetrics.scaled_vector(Vector2(60, 60)), "empty-state logo geometry should follow the effective editor scale")
	var minimum_mode_size := UiMetrics.scaled_vector(Vector2(82, 24))
	_expect(mode.custom_minimum_size.x >= minimum_mode_size.x and mode.custom_minimum_size.y >= minimum_mode_size.y, "composer controls should preserve their scaled minimum target")
	view.prompt_input.text = ""
	view._sync_prompt_height()
	for frame in range(8):
		await process_frame
	var line_height: float = view.prompt_input.get_line_height()
	var style_height: float = view.prompt_input.get_theme_stylebox("normal").get_minimum_size().y
	_expect(view.prompt_input.custom_minimum_size.y == ceilf(ChatWindow.PROMPT_MIN_LINES * line_height + style_height), "composer height should derive from scaled editor font metrics")
	var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	var record: Dictionary = ImageAttachments.prepare_image(image)["image"]
	_expect(view.image_icon_view.size.is_equal_approx(UiMetrics.scaled_vector(Vector2(22, 22))) and view.send_icon_view.size.is_equal_approx(view.image_icon_view.size), "image and Send artwork must share 22 px editor-scaled geometry independently of action-row height")
	view._sync_image_button("unsupported")
	var disabled_tint: Color = view.image_icon_view.self_modulate
	_expect(view.image_button.disabled and disabled_tint.a < 1.0, "unsupported image input must be non-clickable with visibly dimmed artwork")
	view._sync_image_button("supported")
	_expect(not view.image_button.disabled and view.image_icon_view.self_modulate.r > disabled_tint.r, "supported input must restore available icon appearance")
	view._sync_image_button("unknown")
	_expect(view.image_button.disabled, "unconfirmed image input must remain disabled")
	var composer_position: Vector2 = view.composer.global_position
	var composer_size: Vector2 = view.composer.size
	var conversation_rect: Rect2 = view.chat_scroll.get_global_rect()
	var empty_state_rect: Rect2 = view.empty_state.get_global_rect()
	view._draft_images = [record]
	view._refresh_attachment_tray()
	# Allow MarginContainer and nested containers to complete their deferred sorts.
	for frame in range(8):
		await process_frame
	var tray_rect: Rect2 = view._attachment_tray.get_global_rect()
	_expect(tray_rect.size.y <= UiMetrics.scaled(90), "attachment tray must remain one thumbnail row after real editor container layout")
	_expect(tray_rect.position.y >= view.composer.global_position.y - UiMetrics.scaled(100) and tray_rect.end.y <= view.composer.global_position.y, "attachment tray must occupy only the strip above the composer, never the dock/header")
	_expect(view.composer.global_position.is_equal_approx(composer_position) and view.composer.size.is_equal_approx(composer_size), "attaching an image must not move or resize the composer: before %s / %s, after %s / %s" % [composer_position, composer_size, view.composer.global_position, view.composer.size])
	_expect(view.chat_scroll.get_global_rect().is_equal_approx(conversation_rect) and view.empty_state.get_global_rect().is_equal_approx(empty_state_rect), "attachment overlay must not shrink the conversation or recenter the empty state")
	_expect(tray_rect.size.x <= UiMetrics.scaled(64) and view._attachment_tray.get_theme_stylebox("panel") is StyleBoxEmpty, "single thumbnail must float without a full-width section background")
	var remove_button := view._attachment_tray._row.get_child(0).get_child(1) as Button
	_expect(remove_button.size.x <= UiMetrics.scaled(24) and remove_button.size.y <= UiMetrics.scaled(24), "thumbnail removal must stay compact with real editor font/theme: %s" % remove_button.size)
	view._session_resumable = false
	view._on_image_button_pressed()
	_expect(not view._image_picker.visible, "unavailable image action must not open the picker even on a manually emitted action")
	view._session_resumable = true
	view.task_list_panel.set_tasks([{"content": "Attachment layout check", "status": "in_progress"}])
	view._draft_images = [record, record, record, record]
	view._refresh_attachment_tray()
	for frame in range(8):
		await process_frame
	_expect(view._attachment_tray.size.y <= UiMetrics.scaled(90) and view.get_combined_minimum_size().x <= UiMetrics.scaled(300), "four thumbnails must retain one row without widening the narrow dock")
	_expect(not view._attachment_tray.get_global_rect().intersects(view.task_list_panel.get_global_rect()), "attachment strip must not cover a visible task checklist")
	view._draft_images.clear()
	view._refresh_attachment_tray()
	view._remove_draft_image(0)
	for frame in range(4):
		await process_frame
	_expect(not view._attachment_tray.visible, "removing attachments must hide the floating overlay")
	view.main_content.hide()
	view.settings_view.show()
	view.settings_view._show_section("about")
	var links: Array[Button] = []
	for link_name in ["AboutDocsLink", "AboutWebsiteLink", "AboutGitHubLink", "AboutIssuesLink", "AboutDiscussionsLink"]:
		links.append(view.settings_view.find_child(link_name, true, false) as Button)
	# Exercise actual editor typography and larger fonts after deferred layout.
	for font_multiplier in [1.0, 1.5, 2.0]:
		for link in links:
			for label in link.get_parent().find_children("*", "Label", true, false):
				if not label.has_meta("original_font_size"):
					label.set_meta("original_font_size", label.get_theme_font_size("font_size"))
				label.add_theme_font_size_override("font_size", roundi(label.get_meta("original_font_size") * font_multiplier))
		for frame in range(8):
			await process_frame
		for link in links:
			var frame_rect: Rect2 = link.get_global_rect().grow(0.5)
			for label in link.get_parent().find_children("*", "Label", true, false):
				_expect(frame_rect.encloses(label.get_global_rect()), "%s text must fit its clickable background at %.1fx font size" % [link.name, font_multiplier])
			var row: Control = link.get_parent()
			var next: Control = row.get_parent().get_child(row.get_index() + 1)
			_expect(row.get_global_rect().end.y <= next.get_global_rect().position.y, "%s must not overlap the following row or heading" % link.name)
		_expect(view.settings_view.get_combined_minimum_size().x <= UiMetrics.scaled(300), "About links with larger fonts must fit the narrow dock")
	view.queue_free()
	await process_frame
	if _failures.is_empty():
		print("editor_ui_scale_test: PASS (scale %.2f)" % scale)
		quit(0)
		return
	for failure in _failures:
		printerr("editor_ui_scale_test: ", failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
