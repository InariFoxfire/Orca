extends SceneTree

const Config = preload("res://addons/orca/scripts/config.gd")
const EndpointPolicy = preload("res://addons/orca/scripts/endpoint_policy.gd")
const Probe = preload("res://addons/orca/scripts/agent_compatibility_probe.gd")
const SettingsView = preload("res://addons/orca/scripts/settings_view.gd")

class FakeProbe extends Node:
	signal probe_step_changed(step: int)
	signal probe_passed(binding: Dictionary)
	signal probe_failed(binding: Dictionary, message: String)
	signal probe_cancelled
	var running := false
	var starts := 0
	var reject_start := false
	var binding: Dictionary = {}

	func start_probe(config: Dictionary) -> bool:
		starts += 1
		if reject_start:
			return false
		running = true
		binding = Probe.create_binding(config).get("binding", {}).duplicate(true)
		probe_step_changed.emit(1)
		return true

	func is_running() -> bool:
		return running

	func cancel() -> void:
		running = false
		probe_cancelled.emit()

	func pass_check() -> void:
		running = false
		probe_passed.emit(binding.duplicate(true))

	func fail_check() -> void:
		running = false
		probe_failed.emit(binding.duplicate(true), "synthetic check failure")

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_expect(Engine.is_editor_hint(), "this test must run with --editor")
	var settings := EditorInterface.get_editor_settings()
	var keys := PackedStringArray([Config.SETTING_PROVIDER, Config.SETTING_PROVIDER_MODEL_CACHE])
	for provider_id in ["ollama", "lmstudio", "local_openai", "custom", "azure"]:
		for field in ["api_key", "model", "reasoning_effort", "base_url", "confirmed_origin", "agent_compatibility", "api_mode", "continuation_style"]:
			keys.append(Config._provider_setting(provider_id, field))
	var original := {}
	for key in keys:
		original[key] = settings.get_setting(key) if settings.has_setting(key) else null

	Config.save_provider_profile("ollama", "", "qwen-fixture", "default", "http://127.0.0.1:11434/v1")
	Config.save_provider_profile("lmstudio", "lm-secret", "llama-fixture", "low", "http://127.0.0.1:1234/v1")
	Config.save_provider_profile("local_openai", "", "custom-fixture", "default", "http://127.0.0.1:18080/v1")
	var ollama := Config.get_provider_config("ollama")
	_expect(Config.save_provider_profile("azure", "synthetic-key", "custom-gpt-deployment", "high", "http://127.0.0.1:18473/foundry", "responses"), "Azure Responses profile should save")
	var azure := Config.get_provider_config("azure")
	_expect(azure.get("api_mode") == "responses" and azure.get("model") == "custom-gpt-deployment" and azure.get("reasoning_effort") == "high", "Azure API and exact deployment options should persist independently")
	_expect(not Config.save_provider_profile("azure", "replacement", "wrong", "none", "http://127.0.0.1:18473/foundry", "invalid"), "invalid transport must reject the whole settings update")
	_expect(Config.get_provider_config("azure") == azure, "invalid transport must not overwrite credential or deployment settings")
	_expect(Config.save_provider_profile("azure", "synthetic-key", "DeepSeek-V4-Pro", "default", "http://127.0.0.1:18473/foundry", "chat_completions", "deepseek"), "Azure DeepSeek continuation style should save")
	_expect(Config.get_provider_config("azure").get("continuation_style") == "deepseek", "Azure DeepSeek continuation style should restore")
	var lmstudio := Config.get_provider_config("lmstudio")
	var local := Config.get_provider_config("local_openai")
	_expect(ollama.get("api_key") == "" and ollama.get("model") == "qwen-fixture" and ollama.get("base_url") == "http://127.0.0.1:11434/v1", "Ollama should persist an isolated keyless profile")
	_expect(lmstudio.get("api_key") == "lm-secret" and lmstudio.get("model") == "llama-fixture" and lmstudio.get("base_url") == "http://127.0.0.1:1234/v1", "LM Studio should persist an isolated optionally authenticated profile")
	_expect(local.get("model") == "custom-fixture" and local.get("base_url") == "http://127.0.0.1:18080/v1", "generic local settings should persist an independent editable endpoint")
	Config.set_confirmed_origin("ollama", "http://192.168.1.20:11434")
	_expect(Config.get_confirmed_origin("ollama") == "http://192.168.1.20:11434" and Config.get_confirmed_origin("lmstudio") != "http://192.168.1.20:11434", "endpoint trust should persist per provider")
	_expect(EndpointPolicy.authorize_profile("ollama", {"base_url": "http://192.168.1.20:11434/v1", "confirmed_origin": Config.get_confirmed_origin("ollama")}).get("success", false), "persisted exact-origin trust should authorize that provider")
	_expect(not EndpointPolicy.authorize_profile("ollama", {"base_url": "http://192.168.1.20:11435/v1", "confirmed_origin": Config.get_confirmed_origin("ollama")}).get("success", true), "changing the trusted port should require confirmation again")
	var before_invalid := Config.get_provider_config("ollama")
	_expect(not Config.save_provider_profile("ollama", "replacement-secret", "replacement-model", "high", "not a URL"), "invalid endpoint drafts should fail atomically")
	_expect(Config.get_provider_config("ollama") == before_invalid, "invalid endpoint drafts must not pair new credentials with the previous endpoint")
	var binding_result := preload("res://addons/orca/scripts/agent_compatibility_probe.gd").create_binding(Config.get_provider_config("ollama"))
	_expect(binding_result.get("success", false) and Config.record_agent_probe_pass(binding_result.get("binding", {})), "a successful probe binding should persist")
	var disabled_status := Config.agent_compatibility_status("ollama", Config.get_provider_config("ollama"))
	_expect(disabled_status.get("passed", false) and not disabled_status.get("enabled", true), "recording a pass alone must remain disabled without user enablement intent")
	_expect(Config.set_agent_enabled("ollama", Config.get_provider_config("ollama"), true), "explicit opt-in should enable an exact passed binding")
	_expect(Config.agent_compatibility_status("ollama", Config.get_provider_config("ollama")).get("enabled", false), "matching enabled state should be returned to request snapshots")
	var changed_model := Config.get_provider_config("ollama")
	changed_model["model"] = "different-case-sensitive-model"
	_expect(not Config.agent_compatibility_status("ollama", changed_model).get("enabled", true), "model changes should invalidate persisted Agent compatibility")
	var cache_key := Config._provider_model_cache_key("ollama", "http://127.0.0.1:11434/api/tags", "empty")
	var oversized_models := []
	for index in range(Config.MAX_CACHED_PROVIDER_MODELS + 20):
		oversized_models.append({"id": "model-%d" % index})
	settings.set_setting(Config.SETTING_PROVIDER_MODEL_CACHE, {cache_key: {"fetched_at": "invalid", "models": oversized_models, "oversized_extra": "x".repeat(10000)}})
	var bounded_cache := Config.get_cached_provider_models("ollama", "http://127.0.0.1:11434/api/tags", "empty")
	_expect(bounded_cache.keys().size() == 2 and bounded_cache.get("fetched_at") == 0.0 and bounded_cache.get("models", []).size() == Config.MAX_CACHED_PROVIDER_MODELS, "provider cache envelopes should retain only bounded models and a type-checked timestamp")
	await _test_one_click_enablement()

	for key in keys:
		settings.set_setting(key, original[key])
	_finish()


func _test_one_click_enablement() -> void:
	var view := SettingsView.new()
	get_root().add_child(view)
	await process_frame
	view._agent_probe.queue_free()
	var fake := FakeProbe.new()
	view._agent_probe = fake
	view.add_child(fake)
	fake.probe_step_changed.connect(view._on_probe_step_changed)
	fake.probe_passed.connect(view._on_probe_passed)
	fake.probe_failed.connect(view._on_probe_failed)
	fake.probe_cancelled.connect(view._on_probe_cancelled)
	for provider_id in ["ollama", "lmstudio", "local_openai", "custom", "azure"]:
		Config.save_provider_profile(provider_id, "synthetic-key", "synthetic-model", "default", "http://127.0.0.1:18473/v1")
		Config.clear_agent_compatibility(provider_id)
		view._load_provider(provider_id)
		view.agent_probe_button.pressed.emit()
		_expect(fake.running and not view.agent_enable_toggle.button_pressed and view.agent_enable_toggle.disabled, "tools should stay off while checking " + provider_id)
		fake.pass_check()
		var passed_binding := fake.binding.duplicate(true)
		_expect(view.agent_enable_toggle.button_pressed and not view.agent_enable_toggle.disabled and Config.agent_compatibility_status(provider_id, Config.get_provider_config(provider_id)).get("enabled", false), "one click and an exact pass should enable and persist tools for " + provider_id)
		_expect(view._agent_enable_intent.is_empty(), "success must consume the memory-only enablement intent")
		view._on_agent_enable_toggled(false)
		view._load_provider(provider_id)
		fake.probe_passed.emit(passed_binding)
		_expect(not view.agent_enable_toggle.button_pressed and not Config.agent_compatibility_status(provider_id, Config.get_provider_config(provider_id)).get("enabled", true), "reopening or duplicate success must preserve manual opt-out")
		view.agent_probe_button.pressed.emit()
		fake.fail_check()
		_expect(not view.agent_enable_toggle.button_pressed and view.agent_enable_toggle.disabled and view._agent_enable_intent.is_empty(), "failure must not enable tools")
		view.agent_probe_button.pressed.emit()
		fake.cancel()
		fake.probe_passed.emit(fake.binding)
		_expect(not view.agent_enable_toggle.button_pressed and view._agent_enable_intent.is_empty(), "cancellation and late success must not enable tools")
		view.agent_probe_button.pressed.emit()
		var stale := fake.binding.duplicate(true)
		view.custom_model_input.text = "changed-model"
		view.custom_model_input.text_changed.emit("changed-model")
		fake.probe_passed.emit(stale)
		_expect(not view.agent_enable_toggle.button_pressed and Config.get_agent_compatibility(provider_id).is_empty(), "model drift must invalidate automatic enablement")

	view._load_provider("azure")
	fake.reject_start = true
	view.agent_probe_button.pressed.emit()
	_expect(view._agent_enable_intent.is_empty() and not view.agent_enable_toggle.button_pressed and not view.done_button.disabled, "a rejected start must discard intent and restore controls")
	fake.reject_start = false
	view.agent_probe_button.pressed.emit()
	var mismatched := fake.binding.duplicate(true)
	mismatched["model"] = "wrong-result-model"
	fake.running = false
	fake.probe_passed.emit(mismatched)
	_expect(Config.get_agent_compatibility("azure").is_empty() and not view.agent_enable_toggle.button_pressed, "an unmatched returned binding must not authorize tools even while intent is pending")
	view.agent_probe_button.pressed.emit()
	var stale := fake.binding.duplicate(true)
	view.api_key_input.text = "changed-synthetic-key"
	view.api_key_input.text_changed.emit("changed-synthetic-key")
	fake.probe_passed.emit(stale)
	_expect(not view.agent_enable_toggle.button_pressed and Config.get_agent_compatibility("azure").is_empty(), "credential changes must cancel enablement intent")
	view.agent_probe_button.pressed.emit()
	stale = fake.binding.duplicate(true)
	view._on_api_mode_selected(1)
	fake.probe_passed.emit(stale)
	_expect(not view.agent_enable_toggle.button_pressed, "API changes must not accept a prior pass")
	view.agent_probe_button.pressed.emit()
	stale = fake.binding.duplicate(true)
	view._on_continuation_selected(1)
	fake.probe_passed.emit(stale)
	_expect(not view.agent_enable_toggle.button_pressed, "continuation-style changes must not accept a prior pass")
	view.agent_probe_button.pressed.emit()
	fake.pass_check()
	view._save_current_profile()
	view._load_provider("custom")
	view._load_provider("azure")
	_expect(view._selected_api_mode == "chat_completions" and view._continuation_style == "deepseek" and view.agent_enable_toggle.button_pressed, "switching providers must retain the exact enabled Azure API/style profile")

	view.custom_url_input.text = "http://192.0.2.1:18473/v1"
	view.custom_url_input.text_changed.emit(view.custom_url_input.text)
	Config.set_confirmed_origin("azure", "")
	var starts := fake.starts
	view.agent_probe_button.pressed.emit()
	_expect(view._trust_dialog.visible and fake.starts == starts, "origin confirmation must precede the check and enablement")
	view.custom_model_input.text = "changed-while-confirming"
	view.custom_model_input.text_changed.emit("changed-while-confirming")
	view._trust_dialog.hide()
	view._on_endpoint_trust_confirmed()
	_expect(fake.starts == starts and not view.agent_enable_toggle.button_pressed, "profile edits during origin confirmation must discard enablement intent")
	Config.set_confirmed_origin("azure", "")
	view.agent_probe_button.pressed.emit()
	view._trust_dialog.hide()
	view._on_endpoint_trust_cancelled()
	_expect(view._agent_enable_intent.is_empty() and fake.starts == starts, "cancelled origin confirmation must discard enablement intent")
	view.agent_probe_button.pressed.emit()
	view._trust_dialog.hide()
	view._on_endpoint_trust_confirmed()
	fake.pass_check()
	_expect(fake.starts == starts + 1 and view.agent_enable_toggle.button_pressed, "unchanged explicit intent should survive origin confirmation and enable only on pass")
	view.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("provider_settings_editor_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("provider_settings_editor_test: ", failure)
	quit(1)
