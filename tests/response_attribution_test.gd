extends SceneTree

const Attribution = preload("res://addons/orca/scripts/response_attribution.gd")


func _init() -> void:
	var errors := PackedStringArray()
	var record := {"model": "openai/full-model-name", "mode": 0, "provider": "must-not-persist", "reasoning": "must-not-persist", "api_key": "must-not-persist"}
	if Attribution.sanitize(record) != {"model": "openai/full-model-name", "mode": 0}:
		errors.append("attribution must retain only model and response mode")
	if Attribution.sanitize(JSON.parse_string(JSON.stringify(record))) != {"model": "openai/full-model-name", "mode": 0}:
		errors.append("integer mode semantics must survive JSON storage")
	for invalid in [null, [], {}, {"model": 42, "mode": 0}, {"model": "", "mode": 0}, {"model": " padded ", "mode": 0}, {"model": "a\nb", "mode": 0}, {"model": "a\tb", "mode": 0}, {"model": "x".repeat(513), "mode": 1}, {"model": "valid", "mode": true}, {"model": "valid", "mode": 0.5}, {"model": "valid", "mode": 2}]:
		if not Attribution.sanitize(invalid).is_empty():
			errors.append("malformed/unknown attribution must be omitted without inventing identity")
	if not Attribution.sanitize({"model": "x".repeat(512), "mode": 1}).has("model"):
		errors.append("bounded full model IDs must be retained exactly")
	if errors.is_empty():
		print("response_attribution_test: PASS")
		quit(0)
	else:
		for error in errors:
			printerr("response_attribution_test: ", error)
		quit(1)
