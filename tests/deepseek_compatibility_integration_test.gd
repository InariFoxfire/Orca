extends SceneTree

const Probe = preload("res://addons/orca/scripts/agent_compatibility_probe.gd")
var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	for mode in ["chat_completions", "responses"]:
		for case in ["deepseek-probe-sse", "deepseek-probe-json"]:
			var result := await _probe(mode, case, "deepseek")
			_expect(result.get("kind") == "passed", "observed leading delimiter should pass after scoped " + mode + " normalization: " + str(result))
			_expect(result.get("binding", {}).get("deepseek_format_version") == 1 and result.get("binding", {}).get("continuation_style") == "deepseek", "passes must bind the new exact DeepSeek format contract")
			_expect(not result.get("streamed", "").contains("</think>") and not result.get("streamed", "").contains("PRIVATE_DEEPSEEK"), "streamed probe text must contain neither protocol delimiter nor private reasoning")
	var standard_responses := await _probe("responses", "deepseek-probe-sse", "standard")
	_expect(standard_responses.get("kind") == "failed", "plain DeepSeek reasoning must require the explicit compatible profile")
	var wrong := await _probe("responses", "deepseek-probe-wrong", "deepseek")
	_expect(wrong.get("kind") == "failed" and str(wrong.get("message", "")).contains("acknowledgement"), "a wrong nonce must remain denied after delimiter normalization")
	var standard_chat := await _probe("chat_completions", "deepseek-probe-standard", "standard")
	_expect(standard_chat.get("kind") == "failed" and str(standard_chat.get("message", "")).contains("extra formatting"), "standard profiles must preserve the exact original probe gate and literal delimiter")
	if _failures.is_empty():
		print("deepseek_compatibility_integration_test: PASS")
		quit(0)
	else:
		for failure in _failures:
			printerr("deepseek_compatibility_integration_test: ", failure)
		quit(1)


func _probe(mode: String, case: String, style: String) -> Dictionary:
	var probe := Probe.new()
	get_root().add_child(probe)
	var result := {}
	var streamed := PackedStringArray()
	probe._api_client.stream_delta.connect(func(_id: int, text: String): streamed.append(text))
	probe.probe_passed.connect(func(binding: Dictionary): result.merge({"kind": "passed", "binding": binding}, true))
	probe.probe_failed.connect(func(_binding: Dictionary, message: String): result.merge({"kind": "failed", "message": message}, true))
	probe.start_probe({"provider": "azure", "base_url": "http://127.0.0.1:18473/foundry/" + case, "api_key": "synthetic-foundry-key", "model": "DeepSeek-V4-Pro", "api_mode": mode, "continuation_style": style, "reasoning_effort": "default"})
	var deadline := Time.get_ticks_msec() + 15000
	while result.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	_expect(not result.is_empty(), "every synthetic probe must reach a bounded terminal")
	_expect(probe._messages.is_empty() and probe._provider_config.is_empty() and probe._api_client._deepseek_prefix_filter == null, "terminal paths must clear private reasoning, request state, and prefix buffers")
	result["streamed"] = "".join(streamed)
	probe.queue_free()
	await process_frame
	return result


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
