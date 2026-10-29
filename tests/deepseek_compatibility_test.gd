extends SceneTree

const Compatibility = preload("res://addons/orca/scripts/deepseek_response_compatibility.gd")
const Protocol = preload("res://addons/orca/scripts/responses_protocol.gd")
const ApiClient = preload("res://addons/orca/scripts/api_client.gd")
const Probe = preload("res://addons/orca/scripts/agent_compatibility_probe.gd")
const Budget = preload("res://addons/orca/scripts/context_budget.gd")
var _failures := PackedStringArray()
var _config := {"provider": "azure", "base_url": "http://127.0.0.1:18473/v1", "model": "custom-deepseek-deployment", "api_mode": "responses", "continuation_style": "deepseek", "reasoning_effort": "default"}


func _init() -> void:
	_test_prefix_contract()
	_test_responses_continuation()
	_test_streaming_and_json()
	_test_strict_probe_and_binding()
	if _failures.is_empty():
		print("deepseek_compatibility_test: PASS")
		quit(0)
	else:
		for failure in _failures:
			printerr("deepseek_compatibility_test: ", failure)
		quit(1)


func _test_prefix_contract() -> void:
	var cases := {
		"</think>ORCA_AGENT_PROBE_OK nonce": "ORCA_AGENT_PROBE_OK nonce",
		" \n</think>  hello Ω": " \n  hello Ω",
		"</think>": "",
		"</think></think>answer": "</think>answer",
		"Here is </think> literal markup": "Here is </think> literal markup",
		"```xml\n</think>\n```": "```xml\n</think>\n```",
		"</thi": "</thi",
		"<think>literal</think>": "<think>literal</think>",
		"</THINK>literal": "</THINK>literal",
		" ".repeat(65) + "</think>text": " ".repeat(65) + "</think>text"
	}
	for text in cases:
		_expect(Compatibility.normalize(text) == cases[text], "only one exact bounded leading delimiter may be consumed")
		for split in range(text.length() + 1):
			var filter := Compatibility.new()
			var result := filter.push(text.left(split)) + filter.push(text.substr(split)) + filter.finish()
			_expect(result == cases[text], "fragmented prefix normalization must equal completed normalization")
	var filter := Compatibility.new()
	var output := ""
	for character in "</think>你好":
		output += filter.push(character)
		_expect(filter._pending.length() <= Compatibility.MAX_LEADING_WHITESPACE + Compatibility.MARKER.length(), "prefix buffering must remain bounded")
	_expect(output + filter.finish() == "你好", "fragmented tags must not appear in visible text")


func _reply(text: String = "</think>answer") -> Dictionary:
	return {"status": "completed", "output": [
		{"id": "reason", "type": "reasoning", "content": [{"type": "reasoning_text", "text": "PRIVATE_REASONING"}]},
		{"id": "message", "type": "message", "role": "assistant", "phase": "commentary", "content": [{"type": "output_text", "text": text.left(4)}, {"type": "output_text", "text": text.substr(4)}]},
		{"id": "item-call", "type": "function_call", "call_id": "call-id", "name": "read_file", "arguments": "{}"}
	]}


func _test_responses_continuation() -> void:
	var converted := Protocol.completion(_reply(), _config)
	_expect(converted.get("success", false), "DeepSeek Responses reasoning content should normalize")
	var message: Dictionary = converted["response"]["choices"][0]["message"]
	_expect(message["content"] == "answer" and converted["raw_content"] == "</think>answer", "raw parity and visible content must remain separate")
	_expect(message["tool_calls"][0]["id"] == "call-id", "normalization must preserve exact function-call IDs")
	var messages := [{"role": "user", "content": "read"}, message, {"role": "tool", "tool_call_id": "call-id", "content": "result"}]
	var body := Protocol.request_body(messages, [], _config)
	_expect(body.get("success", false) and body["body"]["input"][1]["content"] == [{"type": "reasoning_text", "text": "PRIVATE_REASONING"}], "private plain reasoning must replay only in the exact DeepSeek profile")
	_expect(not JSON.stringify(body["body"]["input"][2]).contains("</think>"), "normalized assistant parts must match canonical text during replay")
	var standard := _config.duplicate(true)
	standard["continuation_style"] = "standard"
	_expect(not Protocol.completion(_reply(), standard).get("success", true), "standard Responses must not silently discard unsupported plain reasoning")
	_expect(not JSON.stringify(Protocol.request_body(messages, [], standard)).contains("PRIVATE_REASONING"), "private reasoning must not cross continuation styles")
	var wrong_profile := _config.duplicate(true)
	wrong_profile["model"] = "another-model"
	_expect(not JSON.stringify(Protocol.request_body(messages, [], wrong_profile)).contains("PRIVATE_REASONING"), "private reasoning must not cross model bindings")
	var oversized := _reply()
	oversized["output"][0]["content"][0]["text"] = "x".repeat(Protocol.MAX_REASONING_BYTES + 1)
	_expect(not Protocol.completion(oversized, _config).get("success", true), "plain reasoning must remain bounded")
	for invalid in ["incomplete", "bad-part"]:
		var malformed := _reply()
		if invalid == "incomplete":
			malformed["output"][0]["status"] = "in_progress"
		else:
			malformed["output"][0]["content"][0]["type"] = "output_text"
		_expect(not Protocol.completion(malformed, _config).get("success", true), "incomplete or malformed reasoning must not enter continuation")
	message[Protocol.PRIVATE_FIELD]["items"][0]["content"][0]["text"] = "x".repeat(4096)
	_expect(Budget.estimate_tokens([message], []) > 1000, "plain continuation bytes must enter context estimates")
	var repeated: Dictionary = Protocol.completion(_reply("</think></think>answer"), _config)["response"]["choices"][0]["message"]
	_expect(repeated["content"] == "</think>answer" and Protocol.request_body([repeated], [], _config).get("success", false), "replay validation must not strip a second delimiter")


func _test_streaming_and_json() -> void:
	for mode in ["chat_completions", "responses"]:
		var client := ApiClient.new()
		client._configured_api_mode = mode
		client._request_config_snapshot = _config.duplicate(true)
		client._request_config_snapshot["api_mode"] = mode
		client._is_requesting = true
		client._request_serial = 1
		var visible := PackedStringArray()
		var result := {}
		client.stream_delta.connect(func(_id: int, text: String): visible.append(text))
		client.request_completed.connect(func(_id: int, response: Dictionary): result.merge(response, true))
		for text in ["</", "thi", "nk>", "answer"]:
			var event := {"choices": [{"delta": {"content": text}}]} if mode == "chat_completions" else {"type": "response.output_text.delta", "delta": text}
			client._consume_sse_bytes(("data: " + JSON.stringify(event) + "\n\n").to_utf8_buffer())
		if mode == "responses":
			client._consume_responses_event({"type": "response.reasoning_text.delta", "delta": "PRIVATE_REASONING"})
			client._consume_responses_event({"type": "response.completed", "response": _reply()})
		else:
			client._finish_reason = "stop"
		client._complete_stream(1)
		_expect("".join(visible) == "answer" and result.get("choices", [{}])[0].get("message", {}).get("content") == "answer", "Chat/Responses streaming and completion must agree without tags or private reasoning")
		client.free()
	var client := ApiClient.new()
	client._request_config_snapshot = _config.duplicate(true)
	client._is_requesting = true
	client._request_serial = 1
	client._raw_response = JSON.stringify({"choices": [{"message": {"content": "</think>answer", "reasoning_content": "PRIVATE_REASONING"}, "finish_reason": "stop"}]}).to_utf8_buffer()
	var result := {}
	client.request_completed.connect(func(_id: int, response: Dictionary): result.merge(response, true))
	client._complete_json_response(1)
	_expect(result["choices"][0]["message"]["content"] == "answer" and result["choices"][0]["message"]["reasoning_content"] == "PRIVATE_REASONING", "Chat JSON should clean the prefix without changing private reasoning")
	client.free()
	client = ApiClient.new()
	client._request_config_snapshot = _config.duplicate(true)
	client._is_requesting = true
	client._request_serial = 1
	var failed := {}
	client.request_failed.connect(func(_id: int, error: Dictionary): failed.merge(error, true))
	client._assistant_content = "</think>"
	client._finish_reason = "stop"
	client._complete_stream(1)
	_expect(failed.get("category") == "malformed_response", "a delimiter alone must not count as a meaningful answer")
	client.free()
	client = ApiClient.new()
	var unchanged := PackedStringArray()
	client.stream_delta.connect(func(_id: int, text: String): unchanged.append(text))
	client._emit_visible_delta("</think>ordinary markup")
	_expect("".join(unchanged) == "</think>ordinary markup", "other profiles must preserve literal markup")
	client.free()
	client = ApiClient.new()
	client._configured_api_mode = "responses"
	client._request_config_snapshot = _config.duplicate(true)
	client._consume_responses_event({"type": "response.output_text.delta", "delta": "</think>answer"})
	client._consume_responses_event({"type": "response.completed", "response": _reply("answer")})
	_expect(client._responses_reply.is_empty() and client._stream_error.contains("did not match"), "normalized parity must not conceal contradictory raw streamed text")
	client.free()
	client = ApiClient.new()
	client._request_config_snapshot = _config.duplicate(true)
	client._request_serial = 1
	client._is_requesting = true
	var terminals := [0]
	client.stream_delta.connect(func(_id: int, _text: String): client.cancel_request())
	client.request_completed.connect(func(_id: int, _response: Dictionary): terminals[0] += 1)
	client._assistant_content = "</thi"
	client._emit_visible_delta("</thi")
	client._finish_reason = "stop"
	client._complete_stream(1)
	_expect(terminals[0] == 0 and client._deepseek_prefix_filter == null and client._request_config_snapshot.is_empty(), "Stop from EOF prefix flushing must not complete or retain the ended request")
	client.free()


func _test_strict_probe_and_binding() -> void:
	var probe := Probe.new()
	probe._challenge = "nonce"
	for text in ["</think></think>ORCA_AGENT_PROBE_OK nonce", "</think>ORCA_AGENT_PROBE_OK wrong", "</think>ORCA_AGENT_PROBE_OK nonce extra", "`ORCA_AGENT_PROBE_OK nonce`"]:
		_expect(not probe._validate_final_response({"choices": [{"message": {"content": Compatibility.normalize(text)}}]}).is_empty(), "the exact acknowledgement gate must still reject repeated tags, wrong nonce, and extra text")
	_expect(probe._validate_final_response({"choices": [{"message": {"content": Compatibility.normalize("</think>ORCA_AGENT_PROBE_OK nonce")}}]}).is_empty(), "the observed correct acknowledgement should pass after scoped normalization")
	var binding: Dictionary = Probe.create_binding(_config)["binding"]
	var old := binding.duplicate(true)
	old.erase("deepseek_format_version")
	_expect(not Probe.record_matches_binding(old, binding), "older DeepSeek passes must require the updated format check")
	var standard := _config.duplicate(true)
	standard["continuation_style"] = "standard"
	binding = Probe.create_binding(standard)["binding"]
	old = binding.duplicate(true)
	old.erase("deepseek_format_version")
	_expect(Probe.record_matches_binding(old, binding), "standard/GPT passes must retain their existing binding semantics")
	probe.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
