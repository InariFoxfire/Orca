extends SceneTree

const ApiClient = preload("res://addons/orca/scripts/api_client.gd")
const Probe = preload("res://addons/orca/scripts/agent_compatibility_probe.gd")
const Images = preload("res://addons/orca/scripts/image_attachments.gd")
const ImageCapability = preload("res://addons/orca/scripts/image_capability.gd")
var _failures := PackedStringArray()
var _serial := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var messages := [{"role": "system", "content": "Synthetic context"}, {"role": "user", "content": "Synthetic request"}]
	var tools := [{"type": "function", "function": {"name": "read_file", "parameters": {"type": "object", "properties": {}}}}]
	var chat := _config("chat", "chat_completions")
	chat["reasoning_effort"] = "default"
	var rejected := await _request(messages, tools, chat)
	_expect(rejected.get("kind") == "failed" and rejected.get("error", {}).get("http_status") == 400, "default-reasoning Chat should reproduce the Azure restriction")
	for model in ["gpt-6-luna", "gpt-6.1-sol"]:
		chat["model"] = model
		chat["reasoning_effort"] = "none"
		var accepted := await _request(messages, tools, chat)
		_expect(accepted.get("kind") == "completed", "explicit None should reach the wire for " + model)

	var probe := Probe.new()
	get_root().add_child(probe)
	var probe_result := {}
	probe.probe_passed.connect(func(bound: Dictionary): probe_result.merge({"kind": "passed", "binding": bound}, true))
	probe.probe_failed.connect(func(_bound: Dictionary, error: String): probe_result.merge({"kind": "failed", "error": error}, true))
	probe.start_probe(_config("probe"))
	var deadline := Time.get_ticks_msec() + 15000
	while probe_result.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	_expect(probe_result.get("kind") == "passed" and probe_result.get("binding", {}).get("api_mode") == "responses", "the real two-request Responses probe should retain reasoning and exact tool acknowledgement: " + str(probe_result))
	probe.queue_free()
	await process_frame

	var image := Image.create(4, 4, false, Image.FORMAT_RGB8)
	image.fill(Color.CORNFLOWER_BLUE)
	var record: Dictionary = Images.prepare_image(image)["image"]
	var vision := _config("multi")
	vision["image_input_override"] = {"binding": ImageCapability.binding(vision), "enabled": true}
	var multimodal := [{"role": "system", "content": "Synthetic context"}, {"role": "user", "content": "Inspect synthetic image", "images": [record]}]
	tools.append({"type": "function", "function": {"name": "search_files", "parameters": {"type": "object", "properties": {}}}})
	var initial := await _request(multimodal, tools, vision)
	_expect(initial.get("kind") == "completed", "multimodal Responses tool batch should complete: " + str(initial))
	if initial.get("kind") == "completed":
		var assistant: Dictionary = initial["response"]["choices"][0]["message"]
		_expect(assistant.get("tool_calls", []).size() == 2, "two function calls should normalize for controller batch preflight")
		multimodal.append(assistant)
		multimodal.append({"role": "tool", "tool_call_id": "read-call", "content": "read done"})
		multimodal.append({"role": "tool", "tool_call_id": "search-call", "content": "search done"})
		multimodal.append({"role": "system", "content": "Finalize without tools"})
		var final := await _request(multimodal, [], vision)
		_expect(final.get("kind") == "completed" and final.get("text") == "foundry Ω ok", "no-tools finalization must retain image, encrypted reasoning, phase, and exact results")
		_expect(final.get("response", {}).get("usage", {}).get("cached_tokens") == 12, "Responses cached-token counters should normalize")
	var json_result := await _request(messages, [], _config("json"))
	_expect(json_result.get("kind") == "completed", "nonstreaming JSON fallback should normalize Responses output")
	for case in ["incomplete", "error", "disconnect"]:
		var failed := await _request(messages, [], _config(case))
		_expect(failed.get("kind") == "failed" and failed.get("error", {}).get("partial_response") == true and failed.get("cleaned") == true, "partial " + case + " must fail once and clear buffers")
	var cancelled := await _request(messages, [], _config("cancel"), true)
	_expect(cancelled.get("kind") == "cancelled" and cancelled.get("cleaned") == true, "Stop must cancel Responses without completing or retaining buffers")
	await create_timer(0.6).timeout

	var ds := _config("deepseek", "chat_completions")
	ds["model"] = "DeepSeek-V4-Pro"
	ds["reasoning_effort"] = "default"
	ds["continuation_style"] = "deepseek"
	var first := await _request(messages, tools, ds)
	_expect(first.get("kind") == "completed", "Azure DeepSeek should return its synthetic tool call")
	if first.get("kind") == "completed":
		messages.append(first["response"]["choices"][0]["message"])
		messages.append({"role": "tool", "tool_call_id": "ds-call", "content": "result"})
		var ds_final := await _request(messages, tools, ds)
		_expect(ds_final.get("kind") == "completed", "DeepSeek Chat must preserve reasoning_content on the actual wire")
		ds["continuation_style"] = "standard"
		var ds_negative := await _request(messages, tools, ds)
		_expect(ds_negative.get("kind") == "failed", "standard continuation negative control must demonstrate the missing reasoning field")
	_finish()


func _config(case: String, mode: String = "responses") -> Dictionary:
	return {"provider": "azure", "api_key": "synthetic-foundry-key", "base_url": "http://127.0.0.1:18473/foundry/" + case, "api_mode": mode, "model": "gpt-6.1-sol", "reasoning_effort": "high", "continuation_style": "standard"}


func _request(messages: Array, tools: Array, config: Dictionary, cancel_on_delta: bool = false) -> Dictionary:
	var client := ApiClient.new()
	get_root().add_child(client)
	var result := {}
	var terminal_count := [0]
	_serial += 1
	var request_id := _serial
	client.request_completed.connect(func(id: int, response: Dictionary):
		terminal_count[0] += 1
		_expect(id == request_id, "completion must retain lifecycle identity")
		result.merge({"kind": "completed", "response": response, "text": response.get("choices", [{}])[0].get("message", {}).get("content")}, true))
	client.request_failed.connect(func(id: int, error: Dictionary):
		terminal_count[0] += 1
		_expect(id == request_id, "failure must retain lifecycle identity")
		result.merge({"kind": "failed", "error": error}, true))
	client.request_cancelled.connect(func(id: int):
		terminal_count[0] += 1
		_expect(id == request_id, "cancellation must retain lifecycle identity")
		result.merge({"kind": "cancelled"}, true))
	if cancel_on_delta:
		client.stream_delta.connect(func(_id: int, _text: String): client.cancel_request())
	client.send_chat_completion(messages, tools, config, {ApiClient.LIFECYCLE_REQUEST_ID_OPTION: request_id, "allow_stream_options_retry": false})
	var deadline := Time.get_ticks_msec() + 15000
	while result.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	_expect(terminal_count[0] == 1, "each request must emit exactly one terminal")
	result["cleaned"] = not client.is_requesting() and client._responses_reply.is_empty() and client._responses_arguments.is_empty() and client._request_config_snapshot.is_empty()
	client.queue_free()
	await process_frame
	return result


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("responses_integration_test: PASS")
		quit(0)
	else:
		for failure in _failures:
			printerr("responses_integration_test: ", failure)
		quit(1)
