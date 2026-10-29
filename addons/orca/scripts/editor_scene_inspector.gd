@tool
extends RefCounted

const SCOPES := ["selection", "scene", "subtree"]
const MAX_NODES := 120
const MAX_DEPTH := 16
const MAX_SELECTION := 20
const MAX_VISITED_NODES := 240
const MAX_ANCESTORS := 64
const MAX_PROPERTIES_PER_NODE := 32
const MAX_TOTAL_PROPERTIES := 512
const MAX_GROUPS := 32
const MAX_PATH_CHARS := 512
const MAX_STRING_CHARS := 256
const MAX_OUTPUT_BYTES := 64 * 1024
const INSPECTION_TIMEOUT_MS := 50

# Fixed native properties, never an enumeration of project exports. Indexed
# Control reads use typed native binds in _native_property, not generic get().
const PROPERTY_FAMILIES := {
	"Control": ["layout_mode", "anchors_preset", "anchor_left", "anchor_top", "anchor_right", "anchor_bottom", "offset_left", "offset_top", "offset_right", "offset_bottom", "position", "size", "custom_minimum_size", "size_flags_horizontal", "size_flags_vertical", "size_flags_stretch_ratio", "grow_horizontal", "grow_vertical", "pivot_offset", "rotation", "scale", "mouse_filter", "focus_mode", "clip_contents"],
	"Node2D": ["position", "rotation", "scale", "skew"],
	"Node3D": ["position", "rotation", "scale", "visible", "top_level"],
	"CanvasItem": ["visible", "modulate", "self_modulate", "z_index"],
	"BoxContainer": ["alignment"],
	"GridContainer": ["columns"],
	"Node": ["process_mode", "process_priority", "process_physics_priority"]
}
const RESOURCE_FAMILIES := {
	"Control": ["theme"],
	"Sprite2D": ["texture"],
	"MeshInstance3D": ["mesh"],
	"CollisionShape2D": ["shape"],
	"CollisionShape3D": ["shape"]
}


static func inspect(arguments: Dictionary, path_validator: Callable) -> Dictionary:
	var error := validate_arguments(arguments)
	if not error.is_empty():
		return _error(error)
	if not Engine.is_editor_hint():
		return _error("Live scene inspection is available only inside the Godot editor.")
	if OS.get_thread_caller_id() != OS.get_main_thread_id():
		return _error("Live scene inspection must run on the editor main thread.")
	var root: Node = EditorInterface.get_edited_scene_root()
	var scene_path := str(ClassDB.class_get_property(root, "scene_file_path")) if is_instance_valid(root) else ""
	var unsaved := scene_path.is_empty() or scene_path in EditorInterface.get_unsaved_scenes()
	return snapshot(root, EditorInterface.get_selection().get_selected_nodes(), arguments, unsaved, path_validator)


# Separates extraction from editor acquisition for deterministic fixtures. The
# model dispatcher exposes only inspect(), never a caller-provided Node.
static func snapshot(root: Node, selection: Array, arguments: Dictionary, unsaved: bool, path_validator: Callable) -> Dictionary:
	var error := validate_arguments(arguments)
	if not error.is_empty():
		return _error(error)
	if not path_validator.is_valid():
		return _error("The project path policy is unavailable.")
	if not is_instance_valid(root) or root.is_queued_for_deletion():
		return _error("No current edited scene is available. Open or create a scene first.")
	var deadline := Time.get_ticks_msec() + INSPECTION_TIMEOUT_MS
	var scene_path := str(ClassDB.class_get_property(root, "scene_file_path"))
	if not scene_path.is_empty():
		error = _path_error(scene_path, path_validator)
		if not error.is_empty():
			return _error("The edited scene is outside the allowed project boundary.")
		scene_path = _canonical_path(scene_path)
	if arguments.has("scene_path"):
		var expected_path: String = arguments["scene_path"]
		if not _path_error(expected_path, path_validator).is_empty() or _canonical_path(expected_path) != scene_path:
			return _error("The current edited scene does not match scene_path. Refresh editor context and inspect again.")
	if not _node_accessible(root, path_validator):
		return _error("The edited scene root is outside the supported native/project boundary.")

	var reasons := PackedStringArray()
	var selected_ids := {}
	var selected_nodes: Array[Node] = []
	var selected_paths: Array[String] = []
	for candidate in selection.slice(0, MAX_SELECTION):
		if typeof(candidate) != TYPE_OBJECT or not is_instance_valid(candidate) or not candidate is Node:
			continue
		var selected_node := candidate as Node
		if selected_node.is_queued_for_deletion():
			continue
		var path := _relative_path(root, selected_node)
		if path.is_empty() or not _branch_accessible(root, selected_node, path_validator):
			_add_reason(reasons, "selection_boundary")
			continue
		if not selected_ids.has(selected_node.get_instance_id()):
			selected_ids[selected_node.get_instance_id()] = true
			selected_nodes.append(selected_node)
			selected_paths.append(path)
	if selection.size() > MAX_SELECTION:
		_add_reason(reasons, "selection_limit")
	var scope := str(arguments.get("scope", "selection"))
	var roots: Array[Node] = []
	if scope == "selection":
		if selected_nodes.is_empty():
			return _error("No supported nodes are selected in the current scene. Select a node or use scope scene.")
		roots = selected_nodes
	elif scope == "scene":
		roots.append(root)
	else:
		var target: Node = root.get_node_or_null(NodePath(str(arguments["node_path"])))
		if not is_instance_valid(target) or _relative_path(root, target).is_empty() or not _branch_accessible(root, target, path_validator):
			return _error("node_path does not identify an accessible node in the current edited scene.")
		roots.append(target)

	var root_paths: Array[String] = []
	var queue: Array[Dictionary] = []
	for target in roots:
		root_paths.append(_relative_path(root, target))
		queue.append({"node": target, "depth": 0})
	var report := {
		"source": "editor_scene",
		"scene_path": scene_path,
		"scene_name": _label(str(ClassDB.class_get_property(root, "name")), reasons),
		"unsaved_changes": unsaved or scene_path.is_empty(),
		"scene_has_path": not scene_path.is_empty(),
		"scope": scope,
		"scope_roots": root_paths,
		"selected_paths": selected_paths,
		"returned_node_count": 0,
		"returned_property_count": 0,
		"nodes": [],
		"truncation": {"truncated": false, "reasons": []},
		"note": "Live editor snapshot, including unsaved changes and allowlisted native defaults. This is not saved-file or running-game state and provides no patch base hash. Container layout may still be settling; custom exports, effective minimum-size callbacks, internal nodes, and signal/debugger state are not inspected."
	}
	var nodes: Array[Dictionary] = []
	var node_limit := int(arguments.get("max_nodes", 60))
	var depth_limit := int(arguments.get("max_depth", 4))
	var property_limit := int(arguments.get("max_properties_per_node", MAX_PROPERTIES_PER_NODE))
	var include_properties := bool(arguments.get("include_properties", true))
	var property_count := 0
	var output_bytes := JSON.stringify(report, "  ").to_utf8_buffer().size() + 2048
	var visited := 0
	var cursor := 0
	while cursor < queue.size() and nodes.size() < node_limit:
		if Time.get_ticks_msec() >= deadline:
			_add_reason(reasons, "time_limit")
			break
		var entry: Dictionary = queue[cursor]
		cursor += 1
		visited += 1
		var node: Node = entry["node"]
		if not is_instance_valid(node) or node.is_queued_for_deletion():
			_add_reason(reasons, "node_unavailable")
			continue
		if not _node_accessible(node, path_validator):
			_add_reason(reasons, "node_boundary")
			continue
		var path := _relative_path(root, node)
		if path.is_empty():
			_add_reason(reasons, "path_limit")
			continue
		var record := _node_record(root, node, path, selected_ids, include_properties, mini(property_limit, maxi(0, MAX_TOTAL_PROPERTIES - property_count)), path_validator, reasons)
		var serialized_record := JSON.stringify(record, "  ")
		var record_bytes := serialized_record.to_utf8_buffer().size() + serialized_record.count("\n") * 4 + 32
		if output_bytes + record_bytes > MAX_OUTPUT_BYTES:
			_add_reason(reasons, "output_limit")
			break
		nodes.append(record)
		property_count += record.get("properties", []).size()
		output_bytes += record_bytes
		if scope == "selection":
			continue
		var child_count := node.get_child_count(false)
		if int(entry["depth"]) >= depth_limit:
			if child_count > 0:
				_add_reason(reasons, "depth_limit")
			continue
		var available := MAX_VISITED_NODES - queue.size()
		for child_index in range(mini(child_count, available)):
			queue.append({"node": node.get_child(child_index, false), "depth": int(entry["depth"]) + 1})
		if child_count > available:
			_add_reason(reasons, "visit_limit")
	if cursor < queue.size() and nodes.size() >= node_limit:
		_add_reason(reasons, "node_limit")
	report["nodes"] = nodes
	report["visited_node_count"] = visited
	report["returned_node_count"] = nodes.size()
	report["returned_property_count"] = property_count
	report["truncation"] = {"truncated": not reasons.is_empty(), "reasons": Array(reasons)}
	var content := JSON.stringify(report, "  ")
	if content.to_utf8_buffer().size() > MAX_OUTPUT_BYTES:
		return _error("The live snapshot could not fit within its output limit.")
	return {"success": true, "content": content, "report": report}


static func validate_arguments(arguments: Dictionary) -> String:
	for key in arguments:
		if str(key) not in ["scope", "node_path", "scene_path", "max_nodes", "max_depth", "include_properties", "max_properties_per_node"]:
			return "Unknown live scene inspection argument."
	var scope = arguments.get("scope", "selection")
	if typeof(scope) != TYPE_STRING or scope not in SCOPES:
		return "scope must be selection, scene, or subtree."
	if scope == "subtree":
		if typeof(arguments.get("node_path")) != TYPE_STRING or not _valid_node_path(arguments["node_path"]):
			return "subtree requires a bounded scene-relative node_path such as '.' or 'Menu/Panel'; absolute paths, parent traversal, unique-name lookup, and property subnames are not accepted."
	elif arguments.has("node_path"):
		return "node_path is accepted only with scope subtree."
	if arguments.has("scene_path") and (typeof(arguments["scene_path"]) != TYPE_STRING or str(arguments["scene_path"]).is_empty() or str(arguments["scene_path"]).length() > MAX_PATH_CHARS):
		return "Optional scene_path must be a nonempty project path of at most 512 characters."
	for bounds in [["max_nodes", 1, MAX_NODES], ["max_depth", 0, MAX_DEPTH], ["max_properties_per_node", 0, MAX_PROPERTIES_PER_NODE]]:
		if arguments.has(bounds[0]):
			var value = arguments[bounds[0]]
			# Godot JSON decodes integer literals as floats. Accept only finite
			# mathematical integers in range, never strings, booleans, or fractions.
			if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(value)) or float(value) != floorf(float(value)) or float(value) < bounds[1] or float(value) > bounds[2]:
				return "%s must be an integer between %d and %d." % bounds
	if arguments.has("include_properties") and typeof(arguments["include_properties"]) != TYPE_BOOL:
		return "include_properties must be a boolean."
	return ""


static func _valid_node_path(path: String) -> bool:
	if path.is_empty() or path.length() > MAX_PATH_CHARS or path.begins_with("/") or path.contains(":") or path.contains("%") or path.contains("\\") or path.contains("\n") or path.contains("\r") or path.contains("\t") or 0 in path.to_utf8_buffer():
		return false
	if path == ".":
		return true
	var parts := path.trim_prefix("./").split("/", true)
	if parts.size() > MAX_DEPTH:
		return false
	for part in parts:
		if part.is_empty() or part in [".", ".."]:
			return false
	return true


static func _relative_path(root: Node, node: Node) -> String:
	var parts := PackedStringArray()
	var current := node
	var path_chars := 0
	for _index in range(MAX_ANCESTORS):
		if current == root:
			var path := "/".join(parts)
			return ("." if path.is_empty() else path) if path.length() <= MAX_PATH_CHARS else ""
		var parent := current.get_parent()
		if parent == null:
			return ""
		# Internal-front children precede the contiguous public child interval;
		# internal-back children follow it. get_index(false) logs on internals,
		# so identify that interval using public indexed reads instead.
		var public_count := parent.get_child_count(false)
		if public_count == 0:
			return ""
		var first_public := parent.get_child(0, false).get_index(true)
		var index := current.get_index(true) - first_public
		if index < 0 or index >= public_count or parent.get_child(index, false) != current:
			return ""
		var name := str(ClassDB.class_get_property(current, "name"))
		path_chars += name.length() + (0 if parts.is_empty() else 1)
		if path_chars > MAX_PATH_CHARS:
			return ""
		parts.insert(0, name)
		current = parent
	return ""


static func _branch_accessible(root: Node, node: Node, path_validator: Callable) -> bool:
	var current := node
	for _index in range(MAX_ANCESTORS):
		if not _node_accessible(current, path_validator):
			return false
		if current == root:
			return true
		current = current.get_parent()
		if current == null:
			return false
	return false


static func _node_accessible(node: Node, path_validator: Callable) -> bool:
	if ClassDB.class_get_api_type(node.get_class()) != ClassDB.API_CORE:
		return false
	var scene_path := str(ClassDB.class_get_property(node, "scene_file_path"))
	if not scene_path.is_empty() and not _path_error(scene_path, path_validator).is_empty():
		return false
	var script := node.get_script() as Script
	return script == null or _resource_reference(script, path_validator).get("available", false)


static func _node_record(root: Node, node: Node, path: String, selected_ids: Dictionary, include_properties: bool, property_limit: int, path_validator: Callable, reasons: PackedStringArray) -> Dictionary:
	var parent := node.get_parent() if node != root else null
	var owner: Node = ClassDB.class_get_property(node, "owner")
	var instance_path := str(ClassDB.class_get_property(node, "scene_file_path"))
	var record := {
		"path": path,
		"name": _label(str(ClassDB.class_get_property(node, "name")), reasons),
		"type": node.get_class(),
		"parent_path": _relative_path(root, parent) if parent != null else "",
		"parent_type": parent.get_class() if parent != null else "",
		"owner_path": _relative_path(root, owner) if is_instance_valid(owner) else "",
		"selected": selected_ids.has(node.get_instance_id()),
		"child_count": node.get_child_count(false),
		"instance_scene": _canonical_path(instance_path) if not instance_path.is_empty() else "",
		"script": _resource_reference(node.get_script() as Script, path_validator),
		"resources": []
	}
	var groups := node.get_groups()
	var group_names: Array[String] = []
	for group in groups.slice(0, MAX_GROUPS):
		if not str(group).begins_with("_"):
			group_names.append(_label(str(group), reasons))
	if groups.size() > MAX_GROUPS:
		_add_reason(reasons, "group_limit")
	record["groups"] = group_names
	if include_properties:
		var properties: Array[Dictionary] = []
		var eligible_count := 0
		for family in PROPERTY_FAMILIES:
			if not ClassDB.is_parent_class(node.get_class(), family):
				continue
			for property in PROPERTY_FAMILIES[family]:
				eligible_count += 1
				if properties.size() < property_limit:
					var value = _native_property(node, property)
					properties.append({"name": property, "type": type_string(typeof(value)), "value": _scalar_value(value)})
		if properties.size() < eligible_count:
			_add_reason(reasons, "property_limit")
		record["properties"] = properties
		if node is Control and parent is Control and ClassDB.class_get_api_type(parent.get_class()) == ClassDB.API_CORE:
			record["layout_context"] = {"parent_is_container": parent is Container, "parent_size": _scalar_value(ClassDB.class_get_property(parent, "size")), "note": "A Container parent manages child layout using size flags and minimum sizes." if parent is Container else "Anchors and offsets are relative to the parent Control."}
		var references: Array[Dictionary] = []
		for family in RESOURCE_FAMILIES:
			if ClassDB.is_parent_class(node.get_class(), family):
				for property in RESOURCE_FAMILIES[family]:
					var reference := _resource_reference(ClassDB.class_get_property(node, property) as Resource, path_validator)
					if reference.get("storage") == "blocked_reference":
						_add_reason(reasons, "reference_boundary")
					reference["property"] = property
					references.append(reference)
		record["resources"] = references
	return record


static func _native_property(node: Node, property: String):
	# Statically typed calls compile to native method binds. Generic ClassDB
	# indexed reads can invoke a script's get_anchor/get_offset override.
	if property.begins_with("anchor_") or property.begins_with("offset_"):
		var control := node as Control
		var side := ["left", "top", "right", "bottom"].find(property.get_slice("_", 1))
		return control.get_anchor(side) if property.begins_with("anchor_") else control.get_offset(side)
	return ClassDB.class_get_property(node, property)


static func _resource_reference(resource: Resource, path_validator: Callable) -> Dictionary:
	if resource == null:
		return {"available": false, "storage": "none"}
	if ClassDB.class_get_api_type(resource.get_class()) != ClassDB.API_CORE:
		return {"available": false, "storage": "unsupported_native_extension"}
	var path := str(ClassDB.class_get_property(resource, "resource_path"))
	if path.is_empty():
		return {"available": true, "class": resource.get_class(), "storage": "built_in", "path": ""}
	var base_path := path.get_slice("::", 0)
	if path.length() > MAX_PATH_CHARS or 0 in path.to_utf8_buffer() or not _path_error(base_path, path_validator).is_empty():
		return {"available": false, "storage": "blocked_reference"}
	var canonical := _canonical_path(base_path)
	var suffix := path.trim_prefix(base_path)
	return {"available": true, "class": resource.get_class(), "storage": "subresource" if not suffix.is_empty() else "project_file", "path": canonical + suffix}


static func _scalar_value(value):
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT:
			return value
		TYPE_FLOAT:
			return value if is_finite(value) else str(value)
		TYPE_VECTOR2:
			return [_scalar_value(value.x), _scalar_value(value.y)]
		TYPE_VECTOR3:
			return [_scalar_value(value.x), _scalar_value(value.y), _scalar_value(value.z)]
		TYPE_COLOR:
			return [_scalar_value(value.r), _scalar_value(value.g), _scalar_value(value.b), _scalar_value(value.a)]
		TYPE_STRING, TYPE_STRING_NAME:
			return str(value).left(MAX_STRING_CHARS)
	return {"unavailable_type": type_string(typeof(value))}


static func _path_error(path: String, path_validator: Callable) -> String:
	if path.length() > MAX_PATH_CHARS or 0 in path.to_utf8_buffer() or path.contains("::"):
		return "Invalid project reference."
	return str(path_validator.call(path, false))


static func _canonical_path(path: String) -> String:
	return ProjectSettings.localize_path(ProjectSettings.globalize_path(path).simplify_path())


static func _add_reason(reasons: PackedStringArray, reason: String) -> void:
	if reason not in reasons:
		reasons.append(reason)


static func _label(value: String, reasons: PackedStringArray) -> String:
	if value.length() > MAX_STRING_CHARS:
		_add_reason(reasons, "string_limit")
	return value.left(MAX_STRING_CHARS)


static func _error(message: String) -> Dictionary:
	return {"success": false, "error": message}
