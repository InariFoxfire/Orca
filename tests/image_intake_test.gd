extends SceneTree

const ChatScene = preload("res://addons/orca/scenes/chat_window.tscn")
const Attachments = preload("res://addons/orca/scripts/image_attachments.gd")
const ComposerInput = preload("res://addons/orca/scripts/composer_input.gd")

class FakeChat extends "res://addons/orca/scripts/chat_window.gd":
	var capability := "supported"
	var has_clipboard_image := false
	var clipboard_image: Image
	var clipboard_reads := 0
	var file_reads := 0
	var errors: Array[String] = []
	func _selected_image_capability() -> String:
		return capability
	func _clipboard_has_image() -> bool:
		return has_clipboard_image
	func _clipboard_image() -> Image:
		clipboard_reads += 1
		return clipboard_image
	func _show_image_intake_error(message: String) -> void:
		errors.append(message)
	func _prepare_image_file(path: String) -> Dictionary:
		file_reads += 1
		return super._prepare_image_file(path)

class FakeInput extends "res://addons/orca/scripts/composer_input.gd":
	var clipboard_text := ""
	func _clipboard_text() -> String:
		return clipboard_text

var _failures: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	get_root().size = Vector2i(300, 800)
	var view = ChatScene.instantiate()
	view.set_script(FakeChat)
	get_root().add_child(view)
	await process_frame
	view._setup_image_attachments()
	for frame in range(4):
		await process_frame
	var image := Image.create(32, 24, false, Image.FORMAT_RGBA8)
	image.fill(Color.RED)
	view.clipboard_image = image
	view.has_clipboard_image = true
	view.prompt_input.text = "Keep my text"
	view.prompt_input.select_all()
	var input := FakeInput.new()
	get_root().add_child(input)
	input.image_paste_handler = view._try_paste_image
	input.text = "selected text"
	input.select_all()
	var conversation_rect: Rect2 = view.chat_scroll.get_global_rect()
	input.paste()
	_expect(view._draft_images.size() == 1 and view.clipboard_reads == 1, "explicit Paste must prepare clipboard pixels once")
	_expect(input.text == "selected text" and input.has_selection(), "image paste must preserve selected text and caret")
	_expect(view.prompt_input.text == "Keep my text", "image paste must preserve composer draft")
	input.menu_option(TextEdit.MENU_PASTE)
	_expect(view._draft_images.size() == 2 and view.clipboard_reads == 2, "native context-menu Paste must share image intake")
	view._remove_draft_image(1)
	view.has_clipboard_image = false
	input.clipboard_text = "pasted\r\ntext"
	input.paste()
	_expect(input.text == "pasted\ntext", "ordinary text Paste must replace selection and normalize newlines")
	input.undo()
	_expect(input.text == "selected text", "text paste must retain undo")
	view.has_clipboard_image = true
	view.capability = "unsupported"
	var count: int = view._draft_images.size()
	view._sync_model_ui()
	_expect(view.image_button.disabled and view.image_icon_view.self_modulate.a < 0.6 and view.image_button.mouse_default_cursor_shape == Control.CURSOR_ARROW, "switching to a text-only model must disable and dim image action immediately")
	view._on_image_button_pressed()
	_expect(not view._image_attachment_window.visible and view.image_button.tooltip_text.contains("does not support"), "text-only model action must not open attachment window")
	input.paste()
	_expect(view._draft_images.size() == count and view.clipboard_reads == 2 and not view.errors.is_empty(), "unsupported profile must reject image before clipboard decoding")
	view.capability = "supported"
	view._sync_model_ui()
	_expect(not view.image_button.disabled and view.image_icon_view.self_modulate.a == 1.0, "switching back to a vision model must restore the image action")
	view._session_resumable = false
	input.paste()
	_expect(view.clipboard_reads == 2, "view-only session must reject image paste")
	view.has_clipboard_image = false
	view.capability = "unsupported"
	input.clipboard_text = "Text still works"
	input.select_all()
	input.paste()
	_expect(input.text == "Text still works", "text paste must remain available on text-only models")
	input.editable = false
	input.clipboard_text = "Blocked"
	input.paste()
	_expect(input.text == "Text still works", "read-only input must retain text")
	input.editable = true
	view.has_clipboard_image = true
	view.capability = "supported"
	view._session_resumable = true
	view._set_request_active(true)
	input.paste()
	_expect(view._draft_images.size() == 2, "busy turn should accept next-message image draft")
	view._set_request_active(false)
	view.clipboard_image = Image.new()
	input.paste()
	_expect(view._draft_images.size() == 2, "invalid clipboard image must preserve accepted draft")
	var path := "user://orca_image_intake_%d.png" % Time.get_ticks_usec()
	_expect(image.save_png(path) == OK, "test image should save")
	var absolute := ProjectSettings.globalize_path(path)
	var data := {"type": "files", "files": PackedStringArray([absolute])}
	_expect(view._can_drop_image_data(Vector2.ZERO, data, view.prompt_input), "image file payload should be accepted without decoding")
	_expect(view.file_reads == 0, "hover must never read image files")
	_expect(view._image_drop_cue.visible, "accepted internal drag should show temporary cue")
	view._drop_image_data(Vector2.ZERO, data, view.prompt_input)
	_expect(view._draft_images.size() == 3 and not view._image_drop_cue.visible, "drop must add to shared floating tray and clear cue")
	_expect(not view._can_drop_image_data(Vector2.ZERO, {"type": "files", "files": [absolute, "/invalid.pdf"]}, view.prompt_input), "mixed image/document drag must reject atomically")
	_expect(not view._can_drop_image_data(Vector2.ZERO, {"type": "resource", "resource": image}, view.prompt_input), "resource objects must not be loaded as file attachments")
	_expect(not view._can_drop_image_data(Vector2.ZERO, "ordinary dragged text", view.prompt_input), "text drags must stay on native TextEdit path")
	view._attach_image_files(PackedStringArray([absolute, absolute]))
	_expect(view._draft_images.size() == 3 and view.file_reads == 1, "count overflow must preserve prior draft before reading files")
	view._attach_image_files(PackedStringArray([absolute, "/invalid.pdf"]))
	_expect(view._draft_images.size() == 3 and view.file_reads == 1, "invalid selection must not partially add images or read files")
	view._drop_image_data(Vector2.ZERO, data, view.prompt_input)
	_expect(view._draft_images.size() == 4, "fourth image should fit")
	view.clipboard_image = image
	var reads: int = view.clipboard_reads
	input.paste()
	_expect(view._draft_images.size() == 4 and view.clipboard_reads == reads, "full tray must reject paste before decoding")
	view._remove_draft_image(3)
	view._can_drop_image_data(Vector2.ZERO, data, view.prompt_input)
	view._notification(Control.NOTIFICATION_DRAG_END)
	_expect(not view._image_drop_cue.visible, "cancelled drag must clear cue")
	var window: Window = view.get_window()
	var editor_connections := window.files_dropped.get_connections().size()
	view._session = {"id": "session_intake_fixture", "events": []}
	view._image_attachment_session_id = "session_intake_fixture"
	view._image_attachment_window.popup_centered()
	_expect(view._image_attachment_window.force_native, "desktop drop target must request a separate native Window")
	_expect(view._image_picker.get_parent() == view._image_attachment_window, "Browse dialog must be owned by attachment window")
	view._image_attachment_window.files_dropped.emit(PackedStringArray([absolute]))
	_expect(view._draft_images.size() == 4, "owned Window drop signal should attach an image")
	view._remove_draft_image(3)
	view.capability = "unsupported"
	var file_reads: int = view.file_reads
	view._image_attachment_window.files_dropped.emit(PackedStringArray([absolute]))
	_expect(view.file_reads == file_reads and view._draft_images.size() == 3, "unsupported native drop must fail before reading files")
	view.capability = "supported"
	view._session["id"] = "session_other"
	view._image_attachment_window.files_dropped.emit(PackedStringArray([absolute]))
	_expect(view._draft_images.size() == 3, "stale attachment window must not add images to a different session")
	view._session["id"] = "session_intake_fixture"
	view._image_attachment_window.hide()
	view._image_attachment_window.files_dropped.emit(PackedStringArray([absolute]))
	_expect(view._draft_images.size() == 3 and view._image_attachment_session_id.is_empty(), "closing attachment window must invalidate pending intake without losing draft")
	view._image_attachment_session_id = "session_intake_fixture"
	view._image_attachment_window.popup_centered()
	view.main_content.hide()
	_expect(not view._image_attachment_window.visible and not view._attachment_window_accepts_intake(), "hidden settings/history view must close attachment window")
	view.main_content.show()
	view.capability = "unsupported"
	view._drop_image_data(Vector2.ZERO, data, view.prompt_input)
	_expect(view._draft_images.size() == 3, "profile changed after hover must deny drop")
	view.capability = "supported"
	view._image_picker.popup_centered(Vector2i(200, 200))
	view._image_attachment_window.files_dropped.emit(PackedStringArray([absolute]))
	_expect(view._draft_images.size() == 3, "visible picker must deny native window drop")
	view._image_picker.hide()
	view._image_attachment_session_id = "session_intake_fixture"
	view._image_attachment_window.popup_centered()
	view._image_picker.popup_centered(Vector2i(200, 200))
	view._image_picker.files_selected.emit(PackedStringArray([absolute]))
	_expect(view._draft_images.size() == 4, "Browse selection should use same owned-window intake")
	_expect(not view._image_picker.visible, "Browse selection must release exclusive picker before intake")
	view._remove_draft_image(3)
	view._close_image_attachment_window()
	view._on_images_selected(PackedStringArray([absolute]))
	_expect(view._draft_images.size() == 3, "late picker selection after close must be ignored")
	for frame in range(4):
		await process_frame
	_expect(view.chat_scroll.get_global_rect().is_equal_approx(conversation_rect), "paste/drop/cue must never reserve conversation space")
	_expect(window.files_dropped.get_connections().size() == editor_connections, "Orca must never add or remove main-editor desktop drop listeners")
	var attachment_window: Window = view._image_attachment_window
	# Native GUI routing: force an internal file drag, then release over TextEdit.
	view._draft_images.clear()
	view._refresh_attachment_tray()
	var drag_source := Control.new()
	drag_source.position = Vector2(0, 0)
	drag_source.size = Vector2(10, 10)
	get_root().add_child(drag_source)
	var move := InputEventMouseMotion.new()
	move.position = view.prompt_input.global_position + view.prompt_input.size / 2
	get_root().push_input(move)
	drag_source.force_drag(data, null)
	get_root().push_input(move)
	await process_frame
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = move.position
	get_root().push_input(release)
	await process_frame
	_expect(view._draft_images.size() == 1 and view.prompt_input.text == "Keep my text", "real Control drag routing over TextEdit must attach image without inserting paths")
	drag_source.force_drag("dragged text", null)
	get_root().push_input(move)
	await process_frame
	get_root().push_input(release)
	await process_frame
	_expect(view.prompt_input.text.contains("dragged text") and view._draft_images.size() == 1, "normal native text drag must still insert text without image intake")
	view._attach_image_files(PackedStringArray([absolute, absolute + "missing.png"]))
	_expect(view._draft_images.size() == 1, "second-file decoding failure must not accept first prepared image")
	drag_source.queue_free()
	view.queue_free()
	input.queue_free()
	DirAccess.remove_absolute(absolute)
	await process_frame
	_expect(not is_instance_valid(attachment_window), "plugin teardown must free owned attachment window")
	_expect(window.files_dropped.get_connections().size() == editor_connections, "teardown must preserve main editor listeners")
	if _failures.is_empty():
		print("image_intake_test: PASS")
		quit(0)
	else:
		for failure in _failures:
			printerr("image_intake_test: ", failure)
		quit(1)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
