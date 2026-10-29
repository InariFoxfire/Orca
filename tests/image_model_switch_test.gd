extends SceneTree

const Attachments = preload("res://addons/orca/scripts/image_attachments.gd")
const Capability = preload("res://addons/orca/scripts/image_capability.gd")
const Controller = preload("res://addons/orca/scripts/agent_controller.gd")
const APIClient = preload("res://addons/orca/scripts/api_client.gd")
const Budget = preload("res://addons/orca/scripts/context_budget.gd")
const Store = preload("res://addons/orca/scripts/session_store.gd")
const ChatScene = preload("res://addons/orca/scenes/chat_window.tscn")

class SwitchingController extends "res://addons/orca/scripts/agent_controller.gd":
	var profile: Dictionary = {}
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
		request_failed.emit(int(requests.back()["options"]["lifecycle_request_id"]), {"category": "connection", "message": "Synthetic model-switch failure"})

class CapturingClient extends "res://addons/orca/scripts/api_client.gd":
	var bodies: Array[Dictionary] = []
	func _perform_request(_id: int, _endpoint: Dictionary, _headers: PackedStringArray, body: Dictionary, _allow_retry: bool, _retries: int) -> void:
		bodies.append(body.duplicate(true))
		_is_requesting = false

class SwitchingChat extends "res://addons/orca/scripts/chat_window.gd":
	var capability := "unsupported"
	func _selected_image_capability() -> String:
		return capability

var _failures := PackedStringArray()
var _record: Dictionary = {}
const VISION := {"provider": "openai", "base_url": "https://api.openai.com/v1", "model": "gpt-4o", "api_key": "synthetic-only"}
const TEXT := {"provider": "deepseek", "base_url": "https://api.deepseek.com", "model": "deepseek-v4-pro", "api_key": "synthetic-only"}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var image := Image.create(32, 24, false, Image.FORMAT_RGBA8)
	image.fill(Color.PURPLE)
	_record = Attachments.prepare_image(image)["image"]
	_test_projection_and_budget()
	_test_transport_boundaries()
	await _test_switching_and_restoration()
	await _test_nonblocking_ui()
	_finish()


func _history() -> Array:
	return [{"role": "system", "content": "system"}, {"role": "user", "content": "", "images": [_record]}, {"role": "assistant", "content": "Earlier vision description: purple rectangle."}, {"role": "user", "content": "Continue with text"}]


func _test_projection_and_budget() -> void:
	var history := _history()
	var original := history.duplicate(true)
	var projected := Attachments.project_messages(history, false)
	_expect(projected[1]["content"] == Attachments.HISTORY_IMAGE_PLACEHOLDER % 1 and not projected[1].has("images"), "image-only historical turns must become explicit text placeholders")
	_expect(projected[2] == history[2] and projected[3] == history[3], "prior descriptions and current user text must remain exact")
	_expect(history == original and Attachments.project_messages(projected, false) == projected, "projection must be non-mutating and idempotent")
	_expect(Attachments.request_messages(history, true)[1]["content"][1]["image_url"]["url"] == Attachments.PNG_PREFIX + _record["data"], "switching back must recover exact original image bytes")
	var text_estimate := Budget.estimate_tokens(history, [], false)
	_expect(text_estimate == Budget.estimate_tokens(projected, []), "text-only budgeting must count the actual placeholders without image reserves")
	_expect(Budget.estimate_tokens(history, [], true) > text_estimate, "vision budgeting must retain conservative image reserves")
	var text_budget := Budget.prepare(history, [], 4096, false)
	_expect(text_budget.get("success", false) and not text_budget.get("compacted", true) and text_budget.get("messages") == history, "a fitting text-only request must not compact merely because canonical history retains an image")
	var vision_budget := Budget.prepare(history, [], 4096, true)
	_expect(vision_budget.get("success", false) and vision_budget.get("compacted", false) and not Attachments.has_images(vision_budget.get("messages", [])), "vision pressure must still compact only a complete old turn when needed")
	var canonical := _history()
	canonical.insert(1, {"role": "user", "content": "very old " + "x".repeat(12000)})
	canonical.insert(2, {"role": "assistant", "content": "very old answer"})
	var compacted := Budget.prepare(canonical, [], 4096, false)
	_expect(compacted.get("success", false) and compacted.get("compacted", false) and Attachments.has_images(compacted.get("messages", [])), "compaction must preserve original images in any retained canonical turns")
	var calls := [{"id": "projection_read", "type": "function", "function": {"name": "get_editor_context", "arguments": "{}"}, "extra_content": {"opaque": "signature"}}]
	history.append({"role": "assistant", "content": "", "tool_calls": calls, "reasoning_content": "private continuation"})
	history.append({"role": "tool", "tool_call_id": "projection_read", "content": "result"})
	projected = Attachments.project_messages(history, false)
	_expect(projected[-2] == history[-2] and projected[-1] == history[-1] and projected.size() == history.size(), "tool IDs, results, opaque/reasoning fields, and request context indices must remain intact")
	history.append({"role": "user", "content": "New picture", "images": [_record]})
	projected = Attachments.project_messages(history, false)
	_expect(projected.back().get("images") == [_record], "current user attachments must never be silently projected away")
	_expect(Budget.estimate_tokens(history, [], false) >= Attachments.image_token_reserve(_record), "a current attachment must retain its reserve even under historical text projection")


func _test_transport_boundaries() -> void:
	var client := CapturingClient.new()
	get_root().add_child(client)
	var errors: Array[Dictionary] = []
	client.request_failed.connect(func(_id: int, error: Dictionary): errors.append(error))
	var history := _history()
	client.send_chat_completion(history, [], TEXT)
	_expect(client.bodies.size() == 1 and errors.is_empty(), "text-only transport must accept valid historical images")
	if not client.bodies.is_empty():
		var payload: Dictionary = client.bodies.back()
		_expect(typeof(payload["messages"][1]["content"]) == TYPE_STRING and not JSON.stringify(payload).contains(Attachments.PNG_PREFIX) and not JSON.stringify(payload).contains(_record["data"]), "text-only requests must contain no inline image bytes or image_url parts")
		_expect(not payload.has(APIClient.INCLUDE_HISTORY_IMAGES_OPTION), "private policy must not be serialized to the provider")
	var unknown := {"provider": "custom", "base_url": "http://127.0.0.1:18473/v1", "model": "unknown", "api_key": "synthetic-only"}
	client.send_chat_completion(history, [], unknown)
	_expect(client.bodies.size() == 2, "unknown image capability must still allow text-only historical continuation")
	unknown["image_input_override"] = {"binding": Capability.binding(unknown), "enabled": true}
	client.send_chat_completion(history, [], unknown, {APIClient.INCLUDE_HISTORY_IMAGES_OPTION: false})
	_expect(client.bodies.size() == 3 and typeof(client.bodies.back()["messages"][1]["content"]) == TYPE_STRING, "a turn's text-only policy must remain stable if capability metadata becomes supported")
	client.send_chat_completion(history, [], VISION)
	_expect(client.bodies.size() == 4 and client.bodies.back()["messages"][1]["content"][1]["image_url"]["url"] == Attachments.PNG_PREFIX + _record["data"], "vision transport must rematerialize retained original images")
	client.send_chat_completion(history, [], TEXT, {APIClient.INCLUDE_HISTORY_IMAGES_OPTION: true})
	_expect(client.bodies.size() == 4 and errors.back().get("category") == "configuration", "lost vision support in an image-inclusive turn must fail before transport")
	var current := history.duplicate(true)
	current.back()["images"] = [_record]
	client.send_chat_completion(current, [], TEXT)
	_expect(client.bodies.size() == 4 and errors.back().get("category") == "configuration", "new text-only attachments must be rejected before transport")
	client.send_chat_completion(current, [], VISION, {APIClient.INCLUDE_HISTORY_IMAGES_OPTION: false})
	_expect(client.bodies.size() == 4, "even supported profiles must not silently discard a current attachment under a text-only policy")
	var invalid := history.duplicate(true)
	invalid[1]["images"][0]["id"] = "f".repeat(64)
	client.send_chat_completion(invalid, [], TEXT)
	_expect(client.bodies.size() == 4 and errors.back().get("category") == "configuration", "corrupt historical records must fail validation even when pixels would be omitted")
	invalid = history.duplicate(true)
	invalid[1]["content"] = [{"type": "image_url", "image_url": {"url": Attachments.PNG_PREFIX + _record["data"]}}]
	client.send_chat_completion(invalid, [], TEXT)
	_expect(client.bodies.size() == 4, "malformed image-bearing content must never be stringified into a text payload")
	var repeated := history.duplicate(true)
	repeated.insert(2, {"role": "user", "content": "Repeated", "images": [_record.duplicate(true)]})
	repeated[2]["images"][0]["width"] = 1
	client.send_chat_completion(repeated, [], TEXT)
	_expect(client.bodies.size() == 4, "validation caching must not trust a repeated ID with forged dimensions")
	repeated[2]["images"][0] = _record.duplicate(true)
	repeated[2]["images"][0]["name"] = "Another display name"
	client.send_chat_completion(repeated, [], TEXT)
	_expect(client.bodies.size() == 5, "repeated valid pixels with different display metadata must remain usable")
	var excessive: Array = []
	var source := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	for index in range(Attachments.MAX_SESSION_IMAGES + 1):
		source.fill(Color(float(index) / 33.0, 0, 0))
		excessive.append({"role": "user", "content": "Prior image", "images": [Attachments.prepare_image(source)["image"]]})
	excessive.append({"role": "user", "content": "Continue"})
	client.send_chat_completion(excessive, [], TEXT)
	_expect(client.bodies.size() == 5 and errors.back().get("category") == "configuration", "text-only projection must not admit unbounded unique historical image records")
	_expect(history == _history(), "transport projection must never mutate canonical input")
	client.queue_free()


func _test_switching_and_restoration() -> void:
	var controller := SwitchingController.new()
	get_root().add_child(controller)
	var client := FakeClient.new()
	controller.set_api_client_for_testing(client)
	controller.set_mode(Controller.AgentMode.PLAN)
	controller.profile = TEXT.duplicate(true)
	_expect(controller.send_user_message("Start text"), "a session may start with a text-only model")
	client.complete({"role": "assistant", "content": "Text start ok"})
	controller.profile = VISION.duplicate(true)
	_expect(controller.send_user_message("", [_record]), "a text-started session may switch to vision and submit an image-only message")
	_expect(client.requests.back()["options"][APIClient.INCLUDE_HISTORY_IMAGES_OPTION] == true, "vision turns must snapshot inclusive image policy")
	client.complete({"role": "assistant", "content": "Earlier vision description: purple rectangle."})
	controller.profile = TEXT.duplicate(true)
	_expect(controller.submission_error().is_empty(), "historical images must not block text-only submissions")
	var old_history := controller.message_history.duplicate(true)
	_expect(not controller.submission_error([_record]).is_empty() and not controller.send_user_message("New draft", [_record]) and controller.message_history == old_history, "unsupported new images must preserve session state and remain a draft rejection")
	_expect(controller.send_user_message("Continue text"), "vision-started sessions must allow a text-only continuation")
	var request: Dictionary = client.requests.back()
	_expect(request["options"][APIClient.INCLUDE_HISTORY_IMAGES_OPTION] == false and Attachments.has_images(request["messages"]), "text-only turns must keep canonical images while passing a private projection policy")
	var projected := Attachments.project_messages(request["messages"], false)
	_expect(not Attachments.has_images(projected) and JSON.stringify(projected).contains("purple rectangle"), "text-only requests must retain the actual prior vision description")
	controller.profile = VISION.duplicate(true)
	var calls := [{"id": "switch_read", "type": "function", "function": {"name": "get_editor_context", "arguments": "{}"}}]
	var previous_requests := client.requests.size()
	client.complete({"role": "assistant", "content": "", "tool_calls": calls})
	for _frame in range(8):
		if client.requests.size() > previous_requests:
			break
		await process_frame
	request = client.requests.back()
	_expect(client.requests.size() == previous_requests + 1 and request["config"]["model"] == TEXT["model"] and request["options"][APIClient.INCLUDE_HISTORY_IMAGES_OPTION] == false, "settings/model changes must apply only to the next turn, not a tool follow-up")
	_expect(request["messages"].back().get("tool_call_id") == "switch_read", "text-only continuation must retain a matching tool result")
	client.complete({"role": "assistant", "content": "Text continuation ok"})
	_expect(controller.send_user_message("Look again"), "switching back to vision must continue the same session")
	request = client.requests.back()
	_expect(request["config"]["model"] == VISION["model"] and request["options"][APIClient.INCLUDE_HISTORY_IMAGES_OPTION] == true and Attachments.has_images(request["messages"]), "a later vision turn must regain retained original images")
	client.complete({"role": "assistant", "content": "Vision again ok"})
	var snapshot := controller.snapshot_session_state()
	_expect(not JSON.stringify(snapshot).contains(APIClient.INCLUDE_HISTORY_IMAGES_OPTION), "turn image policy must not leak into stored continuation")
	_expect(not JSON.stringify(snapshot).contains("Earlier attachment:"), "temporary placeholders must never replace original stored messages")
	var storage_root := "user://orca_image_switch_test_%d" % Time.get_ticks_usec()
	var store := Store.new(storage_root)
	var session := store.create_session(Controller.AgentMode.PLAN, "openai", "gpt-4o")
	session["continuation"] = snapshot["continuation"]
	session["events"] = [{"type": "message", "kind": "user", "sender": "User", "text": "", "images": [_record]}]
	_expect(store.save_session(session).get("success", false), "mixed-model conversation should persist with its original image")
	var loaded := store.load_session(session["id"])
	_expect(loaded["events"][0]["images"][0] == _record and Attachments.has_images(loaded["continuation"]), "restoration must retain exact image records and previews")
	var restored := SwitchingController.new()
	get_root().add_child(restored)
	var restored_client := FakeClient.new()
	restored.set_api_client_for_testing(restored_client)
	restored.profile = TEXT.duplicate(true)
	_expect(restored.restore_session_state(Controller.AgentMode.PLAN, loaded["continuation"], {}), "mixed-model session should restore as resumable")
	_expect(restored.submission_error().is_empty() and restored.send_user_message("Continue after restart"), "a restored image conversation must accept a text-only model")
	restored.cancel_current_request()
	_expect(not restored.is_busy() and Attachments.has_images(restored.message_history), "cancellation must leave earlier original images intact")
	_expect(restored.send_user_message("Retry as a new turn"), "a fresh text turn may follow cancellation without replaying tools")
	restored_client.fail()
	_expect(not restored.is_busy() and Attachments.has_images(restored.message_history), "provider failure must preserve earlier images and reset active policy")
	store.delete_all_sessions()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(storage_root).path_join("index.json"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(storage_root))
	controller.queue_free()
	restored.queue_free()
	await process_frame


func _test_nonblocking_ui() -> void:
	get_root().size = Vector2i(300, 800)
	var view = ChatScene.instantiate()
	view.set_script(SwitchingChat)
	get_root().add_child(view)
	await process_frame
	view.agent_controller = SwitchingController.new()
	view.add_child(view.agent_controller)
	view.agent_controller.profile = TEXT.duplicate(true)
	view.agent_controller.message_history = _history()
	view._setup_image_attachments()
	view.prompt_input.text = "Continue text"
	var feed_count: int = view.chat_feed.get_child_count()
	view._sync_send_availability()
	_expect(not view.send_button.disabled and view.image_button.disabled, "text Send must remain enabled while new image intake is disabled")
	_expect(view.image_button.tooltip_text.contains("preserved") and view.image_button.tooltip_text.contains("placeholders") and view.chat_feed.get_child_count() == feed_count, "model-switch feedback must be non-blocking without adding error cards")
	view._draft_images = [_record]
	view._refresh_attachment_tray()
	view._on_send_button_pressed()
	_expect(view.prompt_input.text == "Continue text" and view._draft_images == [_record], "unsupported new attachments must preserve text and image drafts in the composer")
	view.capability = "supported"
	view._sync_send_availability()
	_expect(not view.image_button.disabled and not view.image_button.tooltip_text.contains("placeholders"), "switching back must restore image intake and remove text-only feedback")
	view._session_resumable = false
	view._sync_send_availability()
	_expect(view.send_button.disabled and view.image_button.disabled, "model switching must not make a view-only session writable")
	view.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("image_model_switch_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("image_model_switch_test: ", failure)
	quit(1)
