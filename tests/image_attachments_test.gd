extends SceneTree

const Attachments = preload("res://addons/orca/scripts/image_attachments.gd")
const Capability = preload("res://addons/orca/scripts/image_capability.gd")
const Budget = preload("res://addons/orca/scripts/context_budget.gd")
const Store = preload("res://addons/orca/scripts/session_store.gd")
const Metadata = preload("res://addons/orca/scripts/model_metadata.gd")
const ProviderBase = preload("res://addons/orca/scripts/providers/provider_base.gd")
const LocalProvider = preload("res://addons/orca/scripts/providers/local_openai_provider.gd")
const ChatScene = preload("res://addons/orca/scenes/chat_window.tscn")
const APIClient = preload("res://addons/orca/scripts/api_client.gd")
const Controller = preload("res://addons/orca/scripts/agent_controller.gd")
var _failures: Array[String] = []

class ImageController extends "res://addons/orca/scripts/agent_controller.gd":
	func _capture_provider_config() -> Dictionary:
		return {"provider": "openai", "base_url": "https://api.openai.com/v1", "model": "gpt-4o", "api_key": "synthetic-image-key"}

class FakeClient extends Node:
	signal stream_started(request_id: int)
	signal stream_delta(request_id: int, content: String)
	signal request_completed(request_id: int, response: Dictionary)
	signal request_failed(request_id: int, error: Dictionary)
	signal request_cancelled(request_id: int)
	var requests: Array = []
	func send_chat_completion(messages: Array, _tools: Array = [], config: Dictionary = {}, options: Dictionary = {}) -> void:
		requests.append({"messages": messages.duplicate(true), "config": config, "options": options})
	func is_requesting() -> bool:
		return false
	func cancel_request() -> void:
		pass

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var source := Image.create(2560, 64, false, Image.FORMAT_RGBA8)
	source.fill(Color(0.4, 0.2, 0.7, 0.8))
	var result := Attachments.prepare_image(source, "/private/path/reference.png")
	_expect(result.get("success", false), "valid image should prepare")
	var record: Dictionary = result["image"]
	_expect(record["width"] == 2048 and record["resized"] and record["name"] == "reference.png", "resize must preserve aspect and exclude absolute path")
	_expect(Attachments.valid_record(record), "prepared data must validate")
	var corrupted := record.duplicate(true)
	corrupted["width"] = 20
	_expect(not Attachments.valid_record(corrupted), "forged dimensions must fail")
	corrupted = record.duplicate(true)
	corrupted["id"] = "f".repeat(64)
	_expect(not Attachments.valid_record(corrupted), "hash mismatch must fail")
	_expect(not Attachments.validate_images([record, record, record, record, record]).is_empty(), "image count must be bounded")
	_expect(not Attachments.prepare_file("/does/not/exist.pdf")["success"], "documents must not be decoded as images")
	var png := source.save_png_to_buffer()
	var jpeg := source.save_jpg_to_buffer()
	var webp := source.save_webp_to_buffer()
	_expect(Attachments._source_dimensions(png) == source.get_size() and Attachments._source_dimensions(jpeg) == source.get_size() and Attachments._source_dimensions(webp) == source.get_size(), "PNG JPEG WebP headers must yield dimensions before decode")
	var message := {"role": "user", "content": "Inspect this screenshot", "images": [record]}
	var wire := Attachments.request_messages([message])
	_expect(wire[0]["content"][1]["image_url"]["url"].begins_with(Attachments.PNG_PREFIX) and not wire[0].has("images"), "wire message must use inline image_url without internal records")
	_expect(typeof(message["content"]) == TYPE_STRING and message.has("images"), "wire materialization must not mutate history")
	var estimate := Budget.estimate_tokens([message], [])
	_expect(estimate == Budget.estimate_tokens([{"role": "user", "content": message["content"]}], []) + Attachments.image_token_reserve(record), "base64 must not count as text tokens")
	var hosted := {"provider": "openai", "base_url": "https://api.openai.com/v1", "model": "gpt-4o", "api_key": ""}
	_expect(Capability.resolve(hosted) == "supported", "known canonical vision model must enable images")
	var custom := {"provider": "custom", "base_url": "https://example.invalid/v1", "model": "gpt-4o"}
	_expect(Capability.resolve(custom) == "unknown", "aliases on arbitrary endpoints must not inherit hosted capability")
	custom["image_input_override"] = {"binding": Capability.binding(custom), "enabled": true}
	_expect(Capability.resolve(custom) == "supported", "explicit exact-profile override enables unknown input")
	custom["model"] = "different-model"
	_expect(Capability.resolve(custom) == "unknown", "model drift invalidates override")
	_expect(Capability.resolve({"provider": "deepseek", "base_url": "https://api.deepseek.com", "model": "deepseek-chat"}) == "unsupported", "known text-only model must disable images")
	var deepseek := {"provider": "deepseek", "base_url": "https://api.deepseek.com", "model": "deepseek-flash"}
	_expect(Capability.resolve(deepseek) == "supported", "current canonical DeepSeek Flash must retain documented image support")
	deepseek["model"] = "deepseek-v4-pro"
	deepseek["image_input_override"] = {"binding": Capability.binding(deepseek), "enabled": true}
	_expect(Capability.resolve(deepseek) == "unsupported", "text-only DeepSeek Pro must remain denied despite an override")
	deepseek["model"] = "deepseek-reasoner"
	_expect(Capability.resolve(deepseek) == "unsupported", "legacy DeepSeek Reasoner must remain text-only")
	deepseek["model"] = "unlisted-deepseek-model"
	_expect(Capability.resolve(deepseek) == "unknown", "unlisted DeepSeek models must not inherit Flash image support")
	deepseek["model"] = "deepseek-flash"
	deepseek["base_url"] = "http://127.0.0.1:8080/v1"
	_expect(Capability.resolve(deepseek) == "unknown", "DeepSeek name on another endpoint must not inherit canonical vision")
	var metadata := Metadata.metadata_from_catalog({"openai": {"models": {"fixture": {"modalities": {"input": ["text", "image"]}}}}}, "openai", "fixture")
	_expect(metadata.get("image_input") == true, "public catalog must retain input modalities")
	var models := ProviderBase.new().normalize_models({"data": [{"id": "fixture", "architecture": {"input_modalities": ["text", "image"]}}]})
	_expect(models[0].get("image_input") == true, "provider discovery must retain image modality")
	models = LocalProvider.new("ollama").normalize_models({"models": [{"model": "fixture", "capabilities": ["completion", "vision"]}]})
	_expect(models[0].get("image_input") == true, "local native vision capability should be retained")
	var store := Store.new("user://orca_image_test_%d" % Time.get_ticks_usec())
	var session := store.create_session(1, "openai", "gpt-4o")
	session["events"] = [{"type": "message", "kind": "user", "sender": "User", "text": "Screenshot", "images": [record]}]
	session["continuation"] = [message]
	_expect(store.save_session(session).get("success", false), "images should save atomically with session")
	var raw := store._read_json_file(store._session_path(session["id"]), Store.MAX_SESSION_BYTES)
	_expect(raw.get("image_records", {}).size() == 1 and not raw["continuation"][0].has("images"), "disk images must be deduplicated across transcript and history")
	var loaded := store.load_session(session["id"])
	_expect(loaded["continuation"][0]["images"][0]["data"] == record["data"] and loaded["events"][0]["images"][0]["id"] == record["id"], "restoration must retain exact image context and preview")
	raw["image_records"].clear()
	_expect(store._unpack_images(raw).get("truncated", false), "missing images must make restored session view-only")
	var invalid_session := session.duplicate(true)
	invalid_session["continuation"][0]["images"] = [corrupted]
	_expect(not store.save_session(invalid_session).get("success", false), "invalid image must not overwrite saved session")
	_expect(store.delete_session(session["id"]).get("cleanup_complete", false), "deletion must remove image data with conversation")
	_expect(not FileAccess.file_exists(store._session_path(session["id"])), "no attachment sidecar may survive deletion")
	store.delete_all_sessions()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(store.storage_root()).path_join("index.json"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(store.storage_root()))
	var controller := ImageController.new()
	get_root().add_child(controller)
	var fake := FakeClient.new()
	get_root().add_child(fake)
	controller.set_api_client_for_testing(fake)
	_expect(controller.send_user_message("Screenshot", [record]), "controller should accept a bounded image submission")
	_expect(fake.requests.size() == 1 and fake.requests[0]["messages"].back()["images"][0]["id"] == record["id"], "initial request should retain exact images")
	controller._send_current_request()
	_expect(fake.requests.size() == 2 and fake.requests[1]["messages"].back()["images"][0]["id"] == record["id"], "follow-up must retain original visual context")
	_expect(controller.snapshot_session_state()["continuation"][0]["images"][0]["id"] == record["id"], "controller checkpoint should preserve user images")
	controller.cancel_current_request()
	controller.queue_free()
	fake.queue_free()
	var view = ChatScene.instantiate()
	get_root().size = Vector2i(300, 800)
	get_root().add_child(view)
	await process_frame
	view.agent_controller = Controller.new()
	view.add_child(view.agent_controller)
	view._session = {"events": []}
	view._setup_image_attachments()
	for frame in range(4):
		await process_frame
	var conversation_rect: Rect2 = view.chat_scroll.get_global_rect()
	view._draft_images = [record]
	view._refresh_attachment_tray()
	for frame in range(8):
		await process_frame
	_expect(view._attachment_tray.visible and view.chat_scroll.get_global_rect().is_equal_approx(conversation_rect), "draft thumbnails must float without reserving feed space")
	_expect(view._attachment_tray.global_position.y < view.composer.global_position.y and view._attachment_tray.size.x <= 300, "tray should anchor above composer at narrow width")
	_expect(view._attachment_tray.size.y <= 76 and view._attachment_tray.get_global_rect().end.y <= view.composer.global_position.y, "tray must stay a bounded strip after container sorts")
	view._set_request_active(true)
	view._set_request_active(false)
	_expect(view._draft_images.size() == 1, "busy transitions must not discard follow-up attachments")
	var label = view._add_message("User", "Screenshot", Color.WHITE, "user")
	view._add_message_images(label, [record])
	_expect(label.get_parent().get_child_count() == 2, "sent message should contain thumbnail tray")
	view._remove_draft_image(0)
	_expect(not view._attachment_tray.visible, "removing last image must hide the overlay")
	view._submitted_image_draft = {"text": "Retry screenshot", "images": [record]}
	view._on_agent_error_occurred("Synthetic image rejection")
	_expect(view.prompt_input.text == "Retry screenshot" and view._draft_images.size() == 1, "provider rejection before tools should restore submitted image draft")
	view._submitted_image_draft = {"text": "Old draft", "images": [record]}
	view.prompt_input.text = "New draft"
	view._on_agent_error_occurred("Synthetic image rejection")
	_expect(view.prompt_input.text == "New draft" and view._draft_images.size() == 1, "provider failure must preserve newer draft")
	view._show_image_preview(record)
	_expect(view._image_preview.visible and view._preview_texture.texture != null, "thumbnail preview should open exact prepared image")
	view._image_preview.hide()
	_expect(view._preview_texture.texture == null, "closing preview should release retained texture")
	view.queue_free()
	await process_frame
	if _failures.is_empty():
		print("image_attachments_test: PASS")
		quit(0)
	else:
		for failure in _failures:
			printerr(failure)
		quit(1)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
