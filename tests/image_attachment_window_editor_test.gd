@tool
extends SceneTree

# Run through native_image_drop_test.py on Linux/X11. Uses synthetic images,
# never provider credentials, model requests, or a user's editor buffers.
const ChatScene = preload("res://addons/orca/scenes/chat_window.tscn")
const Attachments = preload("res://addons/orca/scripts/image_attachments.gd")

class FixtureChat extends "res://addons/orca/scripts/chat_window.gd":
	var capability := "supported"
	func _ready() -> void:
		_setup_image_attachments()
	func _selected_image_capability() -> String:
		return capability
	func _show_image_intake_error(message: String) -> void:
		_image_attachment_window.set_state(_draft_images.size(), message)

var _directory := ""
var _view
var _source := ""

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	_directory = OS.get_environment("ORCA_IMAGE_DROP_TEST_DIR")
	if _directory.is_empty() or DisplayServer.get_name() != "X11" or not Engine.is_editor_hint():
		printerr("Requires native_image_drop_test.py on an X11 editor display.")
		quit(1)
		return
	_view = ChatScene.instantiate()
	_view.set_script(FixtureChat)
	get_root().add_child(_view)
	# Let editor initialization settle before showing a native transient window.
	for frame in range(60):
		await process_frame
	var editor_filesystem := EditorInterface.get_resource_filesystem()
	while editor_filesystem.is_scanning():
		await process_frame
	await create_timer(1.0).timeout
	_view._session = {"id": "session_native_drop_fixture", "events": []}
	_source = _directory.path_join("orca_native_drop_%d.png" % OS.get_process_id())
	var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.1, 0.5, 0.8))
	if image.save_png(_source) != OK:
		_fail("Could not create native drop fixture.")
		return
	_view._image_attachment_session_id = "session_native_drop_fixture"
	_view._image_attachment_window.title = "Orca Native Drop Fixture %d" % OS.get_process_id()
	var root_connections := get_root().files_dropped.get_connections().size()
	if root_connections == 0:
		_fail("Editor native-drop handler is absent; isolation would not be proven.")
		return
	_view._image_attachment_window.popup_centered()
	for frame in range(8):
		await process_frame
	if _view._image_attachment_window.is_embedded() or _view._image_attachment_window.get_window_id() == get_root().get_window_id():
		_fail("Attachment window is not a separate native window.")
		return
	_write_json("ready.json", {"title": _view._image_attachment_window.title, "source": _source})
	var deadline := Time.get_ticks_msec() + 20000
	while _view._draft_images.size() != 1 and Time.get_ticks_msec() < deadline:
		await process_frame
	if _view._draft_images.size() != 1:
		_fail("Native desktop drop did not arrive in attachment window.")
		return
	if not Attachments.valid_record(_view._draft_images[0]) or get_root().files_dropped.get_connections().size() != root_connections:
		_fail("Native image intake or main-editor listener isolation failed.")
		return
	# Rejected native drops must not read/write project files either.
	_view.capability = "unsupported"
	_write_json("reject_ready.json", {"title": _view._image_attachment_window.title, "source": _source})
	deadline = Time.get_ticks_msec() + 10000
	while not _view._image_attachment_window.status_label.text.contains("does not support") and Time.get_ticks_msec() < deadline:
		await process_frame
	if _view._draft_images.size() != 1 or not _view._image_attachment_window.status_label.text.contains("does not support"):
		_fail("Unsupported native drop was not rejected.")
		return
	_view.capability = "supported"
	await create_timer(0.25).timeout
	_view._close_image_attachment_window()
	_view._image_attachment_window.files_dropped.emit(PackedStringArray([_source]))
	_view._on_images_selected(PackedStringArray([_source]))
	if _view._draft_images.size() != 1:
		_fail("Cancelled window accepted late intake.")
		return
	for frame in range(8):
		await process_frame
	_write_json("result.json", {"success": true})
	_view.queue_free()
	await create_timer(1.0).timeout
	while editor_filesystem.is_scanning():
		await process_frame
	print("image_attachment_window_editor_test: PASS (native X11 desktop drop)")
	quit(0)

func _write_json(name: String, data: Dictionary) -> void:
	var file := FileAccess.open(_directory.path_join(name), FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()

func _fail(message: String) -> void:
	_write_json("result.json", {"success": false, "error": message})
	printerr(message)
	quit(1)
