extends SceneTree

const ApiClient = preload("res://addons/orca/scripts/api_client.gd")
const TEST_BASE_URL := "http://127.0.0.1:18473/leading-system/"
const TOOLS := [{"type": "function", "function": {"name": "read_file", "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}}]

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# The unchanged custom adapter is a negative control: this fixture really
	# rejects Orca's original multiple/later-system layout with the reported 500.
	var rejected := await _request("custom", [
		{"role": "system", "content": "Primary instructions"},
		{"role": "user", "content": "hi"},
		{"role": "assistant", "content": "hello"},
		{"role": "system", "content": "Current editor context: second"},
		{"role": "user", "content": "test"}
	])
	_expect(rejected.get("kind") == "failed" and rejected.get("error", {}).get("http_status") == 500, "strict template should reject an unnormalized request")
	_expect(str(rejected.get("error", {}).get("message", "")).contains("System message must be at the beginning"), "negative control should expose the reported template error")
	for provider_id in ["lmstudio", "ollama", "local_openai"]:
		await _test_local_conversation(provider_id)
	_finish()


func _test_local_conversation(provider_id: String) -> void:
	var messages := _initial_messages()
	var first := await _request(provider_id, messages)
	_expect(_content(first) == "hello", provider_id + " should combine initial context for a strict template")
	if first.get("kind") != "completed":
		return
	_remove_fresh_context(messages)
	messages.append(first["response"]["choices"][0]["message"])
	messages.append({"role": "system", "content": "Current editor context: second"})
	messages.append({"role": "system", "content": "Tasks: pending"})
	messages.append({"role": "user", "content": "test"})
	var second := await _request(provider_id, messages)
	_expect(_content(second) == "second ok", provider_id + " should accept a second turn with refreshed context after history")
	if second.get("kind") != "completed":
		return
	_remove_fresh_context(messages)
	messages.append(second["response"]["choices"][0]["message"])
	messages.append({"role": "system", "content": "Current editor context: third"})
	messages.append({"role": "system", "content": "Tasks: in_progress"})
	messages.append({"role": "user", "content": "Inspect fixture"})
	var tool_response := await _request(provider_id, messages, TOOLS)
	var assistant: Dictionary = tool_response.get("response", {}).get("choices", [{}])[0].get("message", {})
	_expect(assistant.get("tool_calls", []).size() == 1, provider_id + " should reconstruct a real streamed tool call")
	if assistant.get("tool_calls", []).size() != 1:
		return
	messages.append(assistant)
	messages.append({"role": "tool", "tool_call_id": "layout-read-call", "content": "Read completed"})
	messages.append({"role": "system", "content": "Runtime observation"})
	messages.append({"role": "system", "content": "Correction and action budget"})
	var continuation := await _request(provider_id, messages, TOOLS)
	_expect(_content(continuation) == "tool complete", provider_id + " should preserve call/result ordering and later runtime context")
	if continuation.get("kind") != "completed":
		return
	messages.append(continuation["response"]["choices"][0]["message"])
	messages.append({"role": "system", "content": "Controller cleanup"})
	messages.append({"role": "system", "content": "Finalize without tools"})
	var final := await _request(provider_id, messages)
	_expect(_content(final) == "final ok", provider_id + " should retain cleanup/finalization context without exposing tools")


func _initial_messages() -> Array:
	return [
		{"role": "system", "content": "Primary instructions"},
		{"role": "system", "content": "Current editor context: first"},
		{"role": "system", "content": "Tasks: pending"},
		{"role": "user", "content": "hi"}
	]


func _remove_fresh_context(messages: Array) -> void:
	for index in range(messages.size() - 1, 0, -1):
		if messages[index].get("role") == "system":
			messages.remove_at(index)


func _request(provider_id: String, messages: Array, tools: Array = []) -> Dictionary:
	var client := ApiClient.new()
	get_root().add_child(client)
	var result: Dictionary = {}
	client.request_completed.connect(func(_id: int, response: Dictionary): result.merge({"kind": "completed", "response": response}, true))
	client.request_failed.connect(func(_id: int, error: Dictionary): result.merge({"kind": "failed", "error": error}, true))
	var base_url := TEST_BASE_URL + provider_id
	if provider_id == "local_openai":
		base_url += "/v1"
	var config := {"provider": provider_id, "base_url": base_url, "model": "local-layout-fixture", "api_key": "", "reasoning_effort": "default"}
	if provider_id == "custom":
		config["api_key"] = "local-test-key"
	var original := messages.duplicate(true)
	client.send_chat_completion(messages, tools, config, {"allow_stream_options_retry": false})
	var deadline := Time.get_ticks_msec() + 10000
	while result.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	_expect(not result.is_empty(), provider_id + " transport should finish within the fixture deadline")
	_expect(messages == original, provider_id + " transport normalization must not modify controller-owned context or history")
	client.queue_free()
	await process_frame
	return result


func _content(result: Dictionary) -> String:
	return str(result.get("response", {}).get("choices", [{}])[0].get("message", {}).get("content", ""))


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("local_provider_integration_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("local_provider_integration_test: ", failure)
	quit(1)
