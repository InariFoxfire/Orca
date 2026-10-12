extends SceneTree

const Client = preload("res://addons/orca/scripts/api_client.gd")
const Attachments = preload("res://addons/orca/scripts/image_attachments.gd")
const Capability = preload("res://addons/orca/scripts/image_capability.gd")
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
	# A text-only profile must be rejected before a third network request.
	_terminal = false
	config["image_input_override"] = {}
	_client.send_chat_completion(messages, tools, config)
	if not _terminal or _error.get("category") != "configuration":
		_fail("Unknown vision profile was not rejected before transport")
		return
	_client.queue_free()
	await process_frame
	print("image_attachments_integration_test: PASS")
	quit(0)

func _wait() -> void:
	var deadline := Time.get_ticks_msec() + 10000
	while not _terminal and Time.get_ticks_msec() < deadline:
		await process_frame

func _fail(message: String) -> void:
	printerr(message)
	quit(1)
