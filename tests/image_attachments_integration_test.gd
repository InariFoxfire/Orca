extends SceneTree

const Client = preload("res://addons/orca/scripts/api_client.gd")
const Attachments = preload("res://addons/orca/scripts/image_attachments.gd")
const Capability = preload("res://addons/orca/scripts/image_capability.gd")
const ScriptReferences = preload("res://addons/orca/scripts/script_references.gd")
var _client
var _response: Dictionary = {}
var _error: Dictionary = {}
var _terminal := false

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	_client = Client.new()
	get_root().add_child(_client)
	_client.request_completed.connect(func(_id: int, response: Dictionary):
		_response = response
		_terminal = true
	)
	_client.request_failed.connect(func(_id: int, error: Dictionary):
		_error = error
		_terminal = true
	)
	var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color.RED)
	var record: Dictionary = Attachments.prepare_image(image)["image"]
	var config := {"provider": "custom", "base_url": "http://127.0.0.1:18473/image-input", "model": "vision-fixture", "api_key": "local-test-key"}
	config["image_input_override"] = {"binding": Capability.binding(config), "enabled": true}
	var messages: Array = [{"role": "user", "content": "Inspect image", "images": [record]}]
	messages[0]["script_references"] = [ScriptReferences.from_source("res://scripts/reference_fixture.gd", "extends Node\n# SYNTHETIC_REFERENCE_CONTEXT")]
	var tools: Array = [{"type": "function", "function": {"name": "read_file", "parameters": {"type": "object", "properties": {}}}}]
	_client.send_chat_completion(messages, tools, config)
	await _wait()
	if not _error.is_empty() or _response.is_empty():
		_fail("Initial image request failed: " + str(_error.get("message", "No response")))
		return
	var assistant: Dictionary = _response["choices"][0]["message"]
	if assistant.get("tool_calls", []).size() != 1:
		_fail("Expected one image tool call")
		return
	messages.append(assistant)
	messages.append({"role": "tool", "tool_call_id": "image_tool", "content": "Read completed"})
	_terminal = false
	_response.clear()
	_client.send_chat_completion(messages, tools, config)
	await _wait()
	if not _error.is_empty() or _response.is_empty() or _response["choices"][0]["message"].get("content") != "image continuation ok":
		_fail("Image context did not survive real transport continuation")
		return
	# This active image turn cannot lose vision support during continuation.
	_terminal = false
	config["image_input_override"] = {}
	_client.send_chat_completion(messages, tools, config)
	if not _terminal or _error.get("category") != "configuration":
		_fail("Unknown vision profile was not rejected before transport")
		return
	if not await _test_model_switching():
		return
	_client.queue_free()
	await process_frame
	print("image_attachments_integration_test: PASS")
	quit(0)


func _test_model_switching() -> bool:
	var base := "http://127.0.0.1:18473/image-switch"
	var text_config := {"provider": "custom", "base_url": base, "model": "text-fixture", "api_key": "local-test-key"}
	var vision_config := {"provider": "custom", "base_url": base, "model": "vision-fixture", "api_key": "local-test-key"}
	vision_config["image_input_override"] = {"binding": Capability.binding(vision_config), "enabled": true}
	var messages: Array = [{"role": "user", "content": "Start text"}]
	var tools := [{"type": "function", "function": {"name": "read_file", "parameters": {"type": "object", "properties": {}}}}]
	var assistant := await _exchange(messages, [], text_config)
	if assistant.is_empty():
		return false
	messages.append(assistant)
	var image := Image.create(32, 24, false, Image.FORMAT_RGBA8)
	image.fill(Color.PURPLE)
	var original: Dictionary = Attachments.prepare_image(image)["image"]
	messages.append({"role": "user", "content": "", "images": [original]})
	assistant = await _exchange(messages, tools, vision_config)
	if assistant.is_empty():
		return false
	messages.append(assistant)
	messages.append({"role": "tool", "tool_call_id": "switch_vision_tool", "content": "Read completed"})
	assistant = await _exchange(messages, tools, vision_config)
	if assistant.is_empty():
		return false
	messages.append(assistant)
	messages.append({"role": "user", "content": "Continue text"})
	assistant = await _exchange(messages, tools, text_config, {Client.INCLUDE_HISTORY_IMAGES_OPTION: false})
	if assistant.is_empty():
		return false
	messages.append(assistant)
	messages.append({"role": "tool", "tool_call_id": "switch_text_tool", "content": "Read completed"})
	# Simulate supported metadata arriving mid-turn: the private text-only policy
	# must still win without changing endpoint/model or transmitting old pixels.
	text_config["image_input_override"] = {"binding": Capability.binding(text_config), "enabled": true}
	assistant = await _exchange(messages, tools, text_config, {Client.INCLUDE_HISTORY_IMAGES_OPTION: false})
	if assistant.is_empty():
		return false
	messages.append(assistant)
	image.fill(Color.GREEN)
	var second: Dictionary = Attachments.prepare_image(image)["image"]
	messages.append({"role": "user", "content": "", "images": [second]})
	assistant = await _exchange(messages, [], vision_config)
	if assistant.is_empty():
		return false
	messages.append(assistant)
	messages.append({"role": "user", "content": "Text again"})
	text_config["image_input_override"] = {}
	assistant = await _exchange(messages, [], text_config)
	if assistant.is_empty():
		return false
	messages.append(assistant)
	var blocked := messages.duplicate(true)
	blocked.append({"role": "user", "content": "New draft", "images": [second]})
	_terminal = false
	_error.clear()
	_client.send_chat_completion(blocked, [], text_config)
	if not _terminal or _error.get("category") != "configuration":
		_fail("New image draft reached a text-only endpoint")
		return false
	messages.append({"role": "user", "content": "Final vision"})
	assistant = await _exchange(messages, [], vision_config)
	if assistant.get("content") != "final vision ok" or messages[2]["images"][0] != original or messages[10]["images"][0] != second:
		_fail("Repeated model switching changed canonical attachments")
		return false
	return true


func _exchange(messages: Array, tools: Array, config: Dictionary, options: Dictionary = {}) -> Dictionary:
	_terminal = false
	_error.clear()
	_response.clear()
	_client.send_chat_completion(messages, tools, config, options)
	await _wait()
	if not _terminal or not _error.is_empty() or _response.is_empty():
		_fail("Model-switch transport failed: " + str(_error.get("message", "No response")))
		return {}
	return _response["choices"][0]["message"]

func _wait() -> void:
	var deadline := Time.get_ticks_msec() + 10000
	while not _terminal and Time.get_ticks_msec() < deadline:
		await process_frame

func _fail(message: String) -> void:
	printerr(message)
	quit(1)
