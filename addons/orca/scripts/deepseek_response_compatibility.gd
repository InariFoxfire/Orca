@tool
extends RefCounted

# Explicit Azure DeepSeek compatibility only. Consume one leading leaked closing
# delimiter, not arbitrary markup, inline reasoning, or acknowledgement text.
const FORMAT_VERSION := 1
const MARKER := "</think>"
const MAX_LEADING_WHITESPACE := 64
var _pending := ""
var _resolved := false


static func enabled(config: Dictionary) -> bool:
	return config.get("provider") == "azure" and config.get("continuation_style", "standard") == "deepseek"


static func prefix_start(text: String) -> int:
	var start := 0
	while start < text.length() and start < MAX_LEADING_WHITESPACE and text.substr(start, 1) in [" ", "\n", "\r", "\t"]:
		start += 1
	return start if text.substr(start, MARKER.length()) == MARKER else -1


static func normalize(text: String) -> String:
	var start := prefix_start(text)
	return text if start < 0 else text.left(start) + text.substr(start + MARKER.length())


func push(delta: String) -> String:
	if _resolved:
		return delta
	var consumed := 0
	var output := ""
	while consumed < delta.length() and not _resolved:
		_pending += delta.substr(consumed, 1)
		consumed += 1
		var start := 0
		while start < _pending.length() and start < MAX_LEADING_WHITESPACE and _pending.substr(start, 1) in [" ", "\n", "\r", "\t"]:
			start += 1
		var candidate := _pending.substr(start)
		if candidate == MARKER:
			output = _pending.left(start)
			_resolved = true
		elif not MARKER.begins_with(candidate):
			output = _pending
			_resolved = true
	if _resolved:
		_pending = ""
		return output + delta.substr(consumed)
	return ""


func finish() -> String:
	var text := _pending
	_pending = ""
	_resolved = true
	return text
