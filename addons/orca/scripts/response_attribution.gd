@tool
extends RefCounted

const MAX_MODEL_CHARS := 512


static func sanitize(raw) -> Dictionary:
	# Attribution is display metadata, not provider payload or model history.
	# Do not fabricate identity from a session's last-used settings.
	if typeof(raw) != TYPE_DICTIONARY or typeof(raw.get("model")) != TYPE_STRING:
		return {}
	var model: String = raw["model"]
	if model.is_empty() or model.length() > MAX_MODEL_CHARS or model != model.strip_edges() or model.contains("\n") or model.contains("\r") or model.contains("\t") or 0 in model.to_utf8_buffer():
		return {}
	var mode = raw.get("mode")
	if typeof(mode) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(mode)) or (float(mode) != 0.0 and float(mode) != 1.0):
		return {}
	return {"model": model, "mode": int(mode)}
