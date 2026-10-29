extends SceneTree

const References = preload("res://addons/orca/scripts/script_references.gd")
const ChatScene = preload("res://addons/orca/scenes/chat_window.tscn")
const Controller = preload("res://addons/orca/scripts/agent_controller.gd")
const Client = preload("res://addons/orca/scripts/api_client.gd")
const Budget = preload("res://addons/orca/scripts/context_budget.gd")
const Store = preload("res://addons/orca/scripts/session_store.gd")
const Images = preload("res://addons/orca/scripts/image_attachments.gd")
const Tray = preload("res://addons/orca/scripts/script_reference_tray.gd")

class TestController extends "res://addons/orca/scripts/agent_controller.gd":
	var profile := {"provider": "local_openai", "base_url": "http://127.0.0.1:18473/v1", "model": "reference-model", "api_key": ""}
	func _capture_provider_config() -> Dictionary:
		return profile.duplicate(true)
	func _load_project_instructions() -> Dictionary:
		return {"success": true, "found": false}
	func _discover_project_skills() -> Dictionary:
		return {"success": true, "skills": []}

class FakeClient extends Node:
	signal stream_started(request_id: int)
	signal stream_delta(request_id: int, content: String)
	signal request_completed(request_id: int, response: Dictionary)
	signal request_failed(request_id: int, error: Dictionary)
	signal request_cancelled(request_id: int)
	var requests: Array[Dictionary] = []
	var requesting := false
	func send_chat_completion(messages: Array, tools: Array, config: Dictionary, options: Dictionary) -> void:
		requests.append({"messages": messages.duplicate(true), "tools": tools.duplicate(true), "config": config.duplicate(true), "options": options.duplicate(true)})
		requesting = true
	func is_requesting() -> bool:
		return requesting
	func last_request_may_have_usage() -> bool:
		return false
	func cancel_request() -> void:
		requesting = false
		request_cancelled.emit(int(requests.back()["options"]["lifecycle_request_id"]))
	func complete(message: Dictionary) -> void:
		requesting = false
		request_completed.emit(int(requests.back()["options"]["lifecycle_request_id"]), {"choices": [{"message": message}]})
	func fail() -> void:
		requesting = false
		request_failed.emit(int(requests.back()["options"]["lifecycle_request_id"]), {"message": "Synthetic reference failure", "category": "connection"})

class CaptureClient extends "res://addons/orca/scripts/api_client.gd":
	var bodies: Array[Dictionary] = []
	func _perform_request(_id: int, _endpoint: Dictionary, _headers: PackedStringArray, body: Dictionary, _retry: bool, _retries: int) -> void:
		bodies.append(body.duplicate(true))
		_is_requesting = false

class TestChat extends "res://addons/orca/scripts/chat_window.gd":
	var errors: Array[String] = []
	func _selected_image_capability() -> String:
		return "unsupported"
	func _show_image_intake_error(error: String) -> void:
		errors.append(error)

var _failures := PackedStringArray()
var _directory := ""
var _paths: Array = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_directory = "res://.orca_script_references_test_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_directory))
	for index in 5:
		var path := _directory.path_join("reference_%d.gd" % index)
		_paths.append(path)
		_write(path, "extends Node\n# saved source %d\n" % index)
	_test_preparation_and_validation()
	_test_transport_and_budget()
	await _test_controller_and_storage()
	await _test_composer_intake()
	var directory := DirAccess.open(_directory)
	for file in directory.get_files():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_directory.path_join(file)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_directory))
	_expect(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(_directory)), "owned script fixtures must be removed")
	if _failures.is_empty():
		print("script_references_test: PASS")
		quit(0)
	else:
		for error in _failures:
			printerr("script_references_test: ", error)
		quit(1)


func _test_preparation_and_validation() -> void:
	var prepared := References.prepare([_paths[0], _paths[0]])
	_expect(prepared.get("success", false) and prepared["references"].size() == 1, "preparation must deduplicate exact paths")
	_expect(prepared["references"][0]["content"].contains("saved source 0"), "saved scripts must be read as bounded source without loading resources")
	var binary := FileAccess.open(_paths[1], FileAccess.WRITE)
	binary.store_buffer(PackedByteArray([0, 97]))
	binary.close()
	_expect(not References.prepare([_paths[1]]).get("success", true), "NUL file data must be rejected before decoding")
	_write(_paths[1], "extends Node\n")
	for path in ["/tmp/outside.gd", "res://../outside.gd", "res://addons/orca/scripts/orca.gd", "res://missing.gd", "res://script.tscn", "res://scene.tscn::BuiltIn", "res://a\nfile.gd"]:
		_expect(not References.prepare([path]).get("success", true), "unsafe/missing/non-script reference must fail: " + path)
	_expect(not References.prepare(_paths).get("success", true), "more than four scripts must be rejected atomically")
	if OS.get_name() == "Linux":
		var link := _directory.path_join("linked.gd")
		_expect(OS.execute("ln", ["-s", ProjectSettings.globalize_path(_paths[0]), ProjectSettings.globalize_path(link)]) == 0, "owned symlink fixture should be created")
		_expect(not References.prepare([link]).get("success", true), "symbolic-link references must reject before source read")
		DirAccess.remove_absolute(ProjectSettings.globalize_path(link))
	var source := "# 日本語\n".repeat(500)
	var record := References.from_source(_paths[0], source, "editor")
	_expect(record["truncated"] and record["included_lines"] <= References.MAX_LINES and record["content"].to_utf8_buffer().size() <= References.MAX_CONTENT_BYTES, "large sources must carry bounded, explicit truncation")
	_expect(record["source_kind"] == "editor" and not record.has("sha256") and not record.has("disk_sha256"), "unsaved snapshots must never carry a disk patch hash")
	record = References.from_source(_paths[0], "日".repeat(References.MAX_CONTENT_BYTES), "disk")
	_expect(References.validate_references([record]).is_empty() and record["content"].to_utf8_buffer().size() <= References.MAX_CONTENT_BYTES, "byte truncation must retain valid UTF-8 even inside a long line")
	_expect(References.from_source(_paths[0], "x".repeat(References.MAX_SOURCE_BYTES + 1)).is_empty(), "oversized source must be rejected")
	var malformed := record.duplicate(true)
	malformed["included_lines"] = 1.5
	_expect(not References.validate_references([malformed]).is_empty(), "fractional metadata must be rejected")
	malformed = record.duplicate(true)
	malformed["content"] = "x".repeat(References.MAX_CONTENT_BYTES + 1)
	_expect(not References.validate_references([malformed]).is_empty(), "oversized snapshot content must be rejected")
	malformed = record.duplicate(true)
	malformed["secret"] = "discard me"
	_expect(not References.sanitize_record(malformed).has("secret"), "records must use an exact persistence allowlist")
	_expect(not References.validate_references([record, record]).is_empty(), "canonical message references must reject duplicates")
	_expect(not References.validate_messages([{"role": "assistant", "content": "", "script_references": [record]}]).is_empty(), "references belong only to user messages")


func _test_transport_and_budget() -> void:
	var record := References.from_source(_paths[0], "extends Node\n# transport reference")
	var messages := [{"role": "system", "content": "system"}, {"role": "user", "content": "Compare these scripts", "script_references": [record]}]
	var original := messages.duplicate(true)
	var materialized := References.request_messages(messages)
	_expect(materialized[1]["content"].contains(record["content"].replace("\n", "\\n")) and not materialized[1].has("script_references"), "wire copies must include bounded source as user context, removing attachment metadata")
	_expect(messages == original and References.request_messages(materialized) == materialized, "materialization must be non-mutating and idempotent")
	_expect(Budget.estimate_tokens(messages, []) == Budget.estimate_tokens(materialized, []) and Budget.estimate_tokens(messages, []) > Budget.estimate_tokens([{ "role": "user", "content": "Compare these scripts"}], []), "budgeting must count exactly the materialized source")
	var large := References.from_source(_paths[0], "x".repeat(References.MAX_CONTENT_BYTES))
	var history := [{"role": "system", "content": "system"}, {"role": "user", "content": "Earlier", "script_references": [large]}, {"role": "assistant", "content": "Done"}, {"role": "user", "content": "New turn"}]
	var compacted := Budget.prepare(history, [], 4096)
	_expect(compacted.get("success", false) and compacted.get("compacted", false) and not JSON.stringify(compacted["messages"]).contains("script_references"), "context pressure must remove complete historical reference turns atomically")
	_expect(not Budget.prepare(history.slice(0, 2), [], 4096).get("success", true), "oversized current source context must fail instead of silently omitting attachments")
	var client := CaptureClient.new()
	get_root().add_child(client)
	var profile := {"provider": "local_openai", "base_url": "http://127.0.0.1:18473/v1", "model": "reference-model", "api_key": ""}
	client.send_chat_completion(messages, [], profile)
	_expect(client.bodies.size() == 1 and not client.bodies[0].has("tools") and client.bodies[0]["messages"][1]["content"] == materialized[1]["content"], "Chat-only profiles must receive script source without enabling tools")
	var image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLUE)
	var pixels: Dictionary = Images.prepare_image(image)["image"]
	messages[1]["images"] = [pixels]
	profile = {"provider": "openai", "base_url": "https://api.openai.com/v1", "model": "gpt-4o", "api_key": "synthetic-only"}
	client.send_chat_completion(messages, [], profile)
	_expect(client.bodies.size() == 2 and client.bodies.back()["messages"][1]["content"][0]["text"].contains("transport reference") and client.bodies.back()["messages"][1]["content"][1]["type"] == "image_url", "script and image context must coexist in one multimodal user message")
	profile = {"provider": "azure", "base_url": "http://127.0.0.1:18473/openai/v1", "model": "reference-deployment", "api_key": "synthetic-only", "api_mode": "responses"}
	messages[1].erase("images")
	client.send_chat_completion(messages, [], profile)
	_expect(client.bodies.size() == 3 and client.bodies.back()["input"][1]["content"].contains("transport reference") and not JSON.stringify(client.bodies.back()).contains('"script_references"'), "Responses must include the same source without private metadata")
	var errors: Array = []
	client.request_failed.connect(func(_id: int, error: Dictionary): errors.append(error))
	messages[1]["script_references"][0]["source_kind"] = "unknown"
	client.send_chat_completion(messages, [], profile)
	_expect(client.bodies.size() == 3 and not errors.is_empty(), "malformed references must fail before transport")
	client.queue_free()


func _test_controller_and_storage() -> void:
	var controller := TestController.new()
	get_root().add_child(controller)
	var client := FakeClient.new()
	controller.set_api_client_for_testing(client)
	controller.set_mode(Controller.AgentMode.PLAN)
	var record := References.from_source(_paths[0], "extends Node\n# historical source")
	_expect(controller.send_user_message("Compare", [], [record]) and client.requests.back()["tools"].is_empty(), "Plan/Chat-only submission must accept references without project mutation/tools")
	record["content"] = "Changed caller copy"
	_expect(client.requests.back()["messages"].back()["script_references"][0]["content"].contains("historical source"), "active-turn snapshots must be isolated from caller mutation")
	client.complete({"role": "assistant", "content": "Compared"})
	controller.profile = {"provider": "openai", "base_url": "https://api.openai.com/v1", "model": "gpt-4o", "api_key": "synthetic-only"}
	var tool_record := References.from_source(_paths[1], "extends Node\n# tool-turn snapshot")
	_expect(controller.send_user_message("Read relevant context", [], [tool_record]), "Agent-enabled profiles must accept referenced turns")
	client.complete({"role": "assistant", "content": "Inspecting", "tool_calls": [{"id": "reference_read", "type": "function", "function": {"name": "read_file", "arguments": JSON.stringify({"filepath": _paths[1]})}}]})
	for frame in 4:
		await process_frame
	_expect(client.requests.back()["messages"].back().get("tool_call_id") == "reference_read" and JSON.stringify(client.requests.back()["messages"]).contains("tool-turn snapshot"), "matching tool continuations must retain the original immutable reference snapshot")
	client.complete({"role": "assistant", "content": "Read completed"})
	var snapshot := controller.snapshot_session_state()
	var store := Store.new("user://orca_script_reference_store_%d" % Time.get_ticks_usec())
	var session := store.create_session(0, "local", "reference-model")
	session["continuation"] = snapshot["continuation"]
	session["events"] = [{"type": "message", "kind": "user", "text": "Compare", "script_references": snapshot["continuation"][0]["script_references"]}]
	_expect(store.save_session(session).get("success", false), "script snapshots and visible references must persist")
	var loaded := store.load_session(session["id"])
	_expect(loaded["events"][0]["script_references"] == snapshot["continuation"][0]["script_references"] and loaded["continuation"] == snapshot["continuation"], "restoration must retain exact bounded source snapshots and references")
	_expect(controller.restore_session_state(0, loaded["continuation"], {}, []), "valid script history must remain resumable")
	_expect(controller.send_user_message("Follow up"), "a later message must continue a referenced conversation")
	_expect(client.requests.back()["messages"][-1].get("script_references", []).is_empty() and JSON.stringify(client.requests.back()["messages"]).contains("historical source"), "references must stay attached to their original message, not be recopied into later turns")
	client.complete({"role": "assistant", "content": "Followed up"})
	loaded["continuation"][0]["script_references"][0]["total_lines"] = -1
	_expect(not store.save_session(loaded).get("success", true) and store._sanitize_session(loaded)["truncated"], "invalid stored references must reject saving and mark restoration view-only")
	store.delete_all_sessions()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(store.storage_root() + "/index.json"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(store.storage_root()))
	controller.queue_free()
	await process_frame


func _test_composer_intake() -> void:
	get_root().size = Vector2i(300, 800)
	var view = ChatScene.instantiate()
	view.set_script(TestChat)
	get_root().add_child(view)
	await process_frame
	view._setup_image_attachments()
	view.agent_controller = TestController.new()
	view.add_child(view.agent_controller)
	var client := FakeClient.new()
	view.agent_controller.set_api_client_for_testing(client)
	view.agent_controller.request_state_changed.connect(view._on_turn_request_state_changed)
	view.agent_controller.message_received.connect(view._on_turn_message_received)
	view.agent_controller.error_occurred.connect(view._on_turn_error_occurred)
	view.agent_controller.request_cancelled.connect(view._on_turn_request_cancelled)
	var store := Store.new("user://orca_script_reference_ui_%d" % Time.get_ticks_usec())
	view.session_store = store
	view._session = {}
	view.prompt_input.text = "Compare another script"
	view.prompt_input.select_all()
	var data := {"type": "files", "files": PackedStringArray([_paths[0]])}
	for frame in 4:
		await process_frame
	var drag_source := Control.new()
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
	release.position = move.position
	get_root().push_input(release)
	await process_frame
	_expect(view._draft_script_paths == [_paths[0]] and view.prompt_input.text == "Compare another script", "real Control drag release over TextEdit must attach a script without inserting paths")
	drag_source.queue_free()
	_expect(view._can_drop_image_data(Vector2.ZERO, data, view.prompt_input), "text-only composer must accept internal script file drag")
	view._drop_image_data(Vector2.ZERO, data, view.prompt_input)
	view._drop_image_data(Vector2.ZERO, data, view.prompt_input)
	_expect(view._draft_script_paths == [_paths[0]] and view.prompt_input.text == "Compare another script" and view.prompt_input.has_selection(), "drops must deduplicate and preserve prompt/selection")
	_expect(not view._can_drop_image_data(Vector2.ZERO, {"type": "files", "files": [_paths[0], "res://unsupported.pdf"]}, view.prompt_input), "mixed unsupported batches must reject atomically")
	_expect(not view._can_drop_image_data(Vector2.ZERO, {"type": "script_list_element", "script_list_element": view.prompt_input}, view.prompt_input), "arbitrary editor-control drag references must be rejected")
	view._set_request_active(true)
	_expect(view._attach_script_paths([_paths[1]]), "busy turns must allow next-message reference drafts")
	view._set_request_active(false)
	view._remove_script_reference(1)
	_write(_paths[0], "extends Node\n# changed after drop\n")
	_expect(view._prepare_script_references()["references"][0]["content"].contains("changed after drop"), "source must be refreshed at Send rather than cached at drop")
	view._attach_script_paths(_paths.slice(1, 4))
	_expect(not view._attach_script_paths([_paths[4]]) and view._draft_script_paths.size() == 4, "reference count overflow must preserve accepted drafts")
	for frame in 6:
		await process_frame
	_expect(view._script_reference_tray.size.x <= view.composer.size.x and view._script_reference_tray.size.y < 180 and view.get_combined_minimum_size().x <= 300, "four reference chips must remain bounded at narrow dock widths")
	view._draft_script_paths = [_paths[0]]
	view._refresh_script_reference_tray()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_paths[0]))
	view._on_send_button_pressed()
	_expect(view._draft_script_paths == [_paths[0]] and view.prompt_input.text == "Compare another script" and client.requests.is_empty(), "missing-file preflight must preserve the complete draft and avoid transport")
	_write(_paths[0], "extends Node\n# changed after drop\n")
	view._on_send_button_pressed()
	_expect(view._draft_script_paths.is_empty() and client.requests.back()["messages"].back()["script_references"][0]["content"].contains("changed after drop"), "submission must send current snapshots and clear only submitted draft references")
	_expect(view.chat_feed.find_children("*", "PanelContainer", true, false).any(func(node): return node is Tray), "submitted messages must display script reference chips")
	var saved := store.load_session(view._session["id"])
	view._clear_chat_feed()
	view._render_session_event(saved["events"][0])
	_expect(view.chat_feed.find_children("*", "PanelContainer", true, false).any(func(node): return node is Tray), "restored user messages must display the same referenced scripts")
	view._attach_script_paths([_paths[1]])
	client.fail()
	_expect(view._draft_script_paths == [_paths[1]], "provider failure must preserve newer reference drafts")
	view._draft_script_paths.clear()
	view.prompt_input.text = "Retry reference"
	view._attach_script_paths([_paths[0]])
	view._on_send_button_pressed()
	client.fail()
	_expect(view._draft_script_paths == [_paths[0]] and view.prompt_input.text == "Retry reference", "pre-tool provider failure must restore the submitted reference draft if no newer draft exists")
	view._session_resumable = false
	_expect(not view._attach_script_paths([_paths[1]]), "view-only sessions must reject attachment intake")
	store.delete_all_sessions()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(store.storage_root() + "/index.json"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(store.storage_root()))
	view.queue_free()
	await process_frame


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
