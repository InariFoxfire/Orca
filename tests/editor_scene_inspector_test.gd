extends SceneTree

const Inspector = preload("res://addons/orca/scripts/editor_scene_inspector.gd")
const Tools = preload("res://addons/orca/scripts/tools.gd")
const GetterFixture = preload("res://tests/fixtures/editor_scene_getter_fixture.gd")

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_live_values_and_selection()
	_test_wire_arguments()
	_test_native_getter_isolation()
	_test_boundaries_and_arguments()
	_test_symlink_boundary()
	_test_bounds()
	_test_references()
	_finish()


func _snapshot(root: Node, selected: Array = [], arguments: Dictionary = {}) -> Dictionary:
	var result := Inspector.snapshot(root, selected, arguments, true, Tools._validate_path)
	_expect(result.get("success", false), "snapshot should succeed: " + str(result.get("error", "")))
	if not result.get("success", false):
		return {}
	var report = JSON.parse_string(str(result.get("content", "")))
	_expect(report is Dictionary, "the model-facing snapshot should be whole valid JSON")
	_expect(str(result.get("content", "")).to_utf8_buffer().size() <= Inspector.MAX_OUTPUT_BYTES, "snapshot must fit the whole-output limit")
	return report if report is Dictionary else {}


func _test_live_values_and_selection() -> void:
	var root := Control.new()
	root.name = "Menu"
	root.size = Vector2(800, 600)
	var panel := Control.new()
	panel.name = "Panel"
	root.add_child(panel)
	panel.owner = root
	panel.set_anchor(SIDE_RIGHT, 1.0)
	panel.set_offset(SIDE_LEFT, 24.0)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_to_group("menu_panels")
	var node_2d := Node2D.new()
	node_2d.name = "Player"
	node_2d.position = Vector2(12, 34)
	root.add_child(node_2d)
	var node_3d := Node3D.new()
	node_3d.name = "World"
	node_3d.position = Vector3(1, 2, 3)
	root.add_child(node_3d)
	var report := _snapshot(root, [panel, node_2d, node_3d])
	_expect(report.get("source") == "editor_scene" and report.get("unsaved_changes") == true and report.get("scene_has_path") == false, "unnamed live roots must be clearly identified as unsaved editor state")
	_expect(report.get("returned_node_count") == 3 and report.get("scope") == "selection", "default selection must read exactly the selected nodes, not their siblings or descendants")
	var panel_record := node_record(report, "Panel")
	_expect(panel_record.get("selected") == true and panel_record.get("owner_path") == ".", "selection and scene ownership should be retained")
	_expect("menu_panels" in panel_record.get("groups", []), "bounded public groups should be included")
	_expect(property_value(panel_record, "anchor_right") == 1.0 and property_value(panel_record, "offset_left") == 24.0, "anchors and offsets must use current native values")
	_expect(property_value(panel_record, "size_flags_horizontal") == Control.SIZE_EXPAND_FILL, "size flags must retain their native integer value")
	_expect(panel_record.get("layout_context", {}).get("parent_size") == [800.0, 600.0], "selected Controls should include bounded parent layout context")
	_expect(property_value(node_record(report, "Player"), "position") == [12.0, 34.0], "Node2D transforms should be JSON-safe numeric components")
	_expect(property_value(node_record(report, "World"), "position") == [1.0, 2.0, 3.0], "Node3D transforms should be JSON-safe numeric components")
	for record in report.get("nodes", []):
		for property in record.get("properties", []):
			_expect(property.get("value") != null, "allowlisted native property should exist: " + str(property.get("name", "")))
	var hierarchy := _snapshot(root, [panel], {"scope": "scene"})
	_expect(hierarchy.get("returned_node_count") == 4 and node_record(hierarchy, ".").get("selected") == false, "scene scope should return native hierarchy and retain selection markers")
	var subtree := _snapshot(root, [panel], {"scope": "subtree", "node_path": "./Panel"})
	_expect(subtree.get("scope_roots") == ["Panel"] and subtree.get("returned_node_count") == 1, "subtree should resolve a scene-relative path without leaving the scene")
	var structure := _snapshot(root, [], {"scope": "scene", "include_properties": false})
	_expect(not node_record(structure, "Panel").has("properties") and not node_record(structure, "Panel").has("layout_context"), "structure-only requests should omit property reads and layout details")
	_expect(not JSON.stringify(report).contains("sha256") and not report.has("base_hash"), "live editor snapshots must not provide disk patch hashes")
	root.free()


func _test_wire_arguments() -> void:
	var root := Node.new()
	root.add_child(Node.new())
	var json := JSON.new()
	_expect(json.parse('{"scope":"scene","max_nodes":2,"max_depth":1,"max_properties_per_node":1}') == OK, "wire argument JSON should parse")
	var report := _snapshot(root, [], json.get_data())
	_expect(report.get("returned_node_count") == 2 and report.get("returned_property_count") == 2, "integral JSON tool limits must survive the controller's actual JSON decoding representation")
	root.free()


func _test_native_getter_isolation() -> void:
	var root := Control.new()
	var scripted: Control = GetterFixture.new()
	scripted.name = "Scripted"
	root.add_child(scripted)
	scripted.set_anchor(SIDE_LEFT, 0.25)
	scripted.set_offset(SIDE_LEFT, 17.0)
	var before := int(scripted.get("inspection_calls"))
	var report := _snapshot(root, [scripted])
	_expect(int(scripted.get("inspection_calls")) == before, "inspection must not invoke _get, property-list/minimum-size callbacks, custom exports, or shadowed native getters")
	var record := node_record(report, "Scripted")
	_expect(property_value(record, "anchor_left") == 0.25 and property_value(record, "offset_left") == 17.0, "typed native indexed reads must bypass script overrides")
	_expect(record.get("child_count") == 0, "hierarchy reads must also bypass shadowed native methods")
	_expect(record.get("script", {}).get("path") == "res://tests/fixtures/editor_scene_getter_fixture.gd", "script identity should be reported without inspecting its code or exports")
	_expect(not JSON.stringify(report).contains("custom_secret") and not JSON.stringify(report).contains("must-not-be-inspected"), "project script values must not leak into native inspection")
	root.free()


func _test_boundaries_and_arguments() -> void:
	var root := Node.new()
	root.name = "Root"
	var internal := Node.new()
	internal.name = "Internal"
	root.add_child(internal, false, Node.INTERNAL_MODE_BACK)
	var internal_front := Node.new()
	internal_front.name = "InternalFront"
	root.add_child(internal_front, false, Node.INTERNAL_MODE_FRONT)
	var public_child := Node.new()
	public_child.name = "PublicChild"
	root.add_child(public_child)
	var blocked := Node.new()
	blocked.name = "ProtectedInstance"
	blocked.scene_file_path = "res://addons/orca/scenes/chat_window.tscn"
	root.add_child(blocked)
	var blocked_child := Node.new()
	blocked_child.name = "PrivateChild"
	blocked.add_child(blocked_child)
	var outside := Node.new()
	_expect(not Inspector.snapshot(null, [], {"scope": "scene"}, false, Tools._validate_path).get("success", true), "absence of an edited root must fail cleanly")
	_expect(not Inspector.snapshot(root, [null, 42, "invalid", outside], {}, false, Tools._validate_path).get("success", true), "malformed/foreign selection entries must not invoke object methods")
	var arguments_list := [
		{"scope": "runtime"}, {"scope": 3}, {"max_nodes": 1.5}, {"max_nodes": 0}, {"max_nodes": 121},
		{"max_depth": -1}, {"max_depth": 17}, {"max_properties_per_node": 33}, {"max_nodes": "2"}, {"max_nodes": true}, {"max_nodes": INF}, {"max_nodes": NAN}, {"include_properties": "yes"},
		{"node_path": "Internal"}, {"scope": "subtree"}, {"scope": "subtree", "node_path": "Missing"},
		{"scope": "subtree", "node_path": "Internal"}, {"scope": "subtree", "node_path": "ProtectedInstance/PrivateChild"},
		{"scope": "subtree", "node_path": "InternalFront"},
		{"scope": "scene", "scene_path": ""}, {"scope": "scene", "scene_path": "/tmp/outside.tscn"},
		{"scope": "scene", "root": "model-cannot-supply-a-node"}
	]
	for path in ["/root", "..", "../Other", "Panel/../Other", "Panel:position", "%Unique", "A//B", "A\\B", "", "x".repeat(513), "A\nB"]:
		arguments_list.append({"scope": "subtree", "node_path": path})
	for arguments in arguments_list:
		_expect(not Inspector.snapshot(root, [], arguments, true, Tools._validate_path).get("success", true), "invalid or inaccessible requests must fail for fields: " + str(arguments.keys()))
	_expect(not Inspector.snapshot(root, [internal, outside, blocked_child], {}, true, Tools._validate_path).get("success", true), "selection must remain inside non-internal accessible scene branches")
	var report := _snapshot(root, [], {"scope": "scene"})
	_expect(report.get("returned_node_count") == 2 and not node_record(report, "PublicChild").is_empty() and not JSON.stringify(report).contains("PrivateChild") and not JSON.stringify(report).contains("InternalFront"), "protected/internal branches must be excluded without excluding public siblings")
	_expect("node_boundary" in report.get("truncation", {}).get("reasons", []), "excluded branches must be disclosed as incomplete inspection")
	root.scene_file_path = "res://addons/orca/scenes/chat_window.tscn"
	_expect(not Inspector.snapshot(root, [], {"scope": "scene"}, true, Tools._validate_path).get("success", true), "Orca's own edited scenes must remain protected")
	root.scene_file_path = "/tmp/outside.tscn"
	_expect(not Inspector.snapshot(root, [], {"scope": "scene"}, true, Tools._validate_path).get("success", true), "outside-project edited scene identities must be rejected")
	root.scene_file_path = "res://tests/fixtures/inspect_scene_fixture.tscn"
	_expect(not Inspector.snapshot(root, [], {"scope": "scene", "scene_path": "res://tests/fixtures/inspect_scene_child.tscn"}, false, Tools._validate_path).get("success", true), "expected scene identity must reject a switched active scene")
	var matching := Inspector.snapshot(root, [], {"scope": "scene", "scene_path": "res://tests/fixtures/./inspect_scene_fixture.tscn"}, false, Tools._validate_path)
	_expect(matching.get("success", false) and matching.get("report", {}).get("unsaved_changes") == false, "normalized matching identities should work without inventing dirty state")
	_expect(not Inspector.snapshot(root, [], {"scope": "scene"}, false, Callable()).get("success", true), "inspection must fail closed if project path policy is unavailable")
	root.free()
	outside.free()
	if not Engine.is_editor_hint():
		var result := Tools.execute_tool("inspect_editor_scene", {"scope": "scene"})
		_expect(not result.get("success", true) and str(result.get("content", "")).contains("only inside"), "model-facing tool must deny non-editor acquisition")


func _test_symlink_boundary() -> void:
	if OS.get_name() not in ["Linux", "FreeBSD", "NetBSD", "OpenBSD", "macOS"]:
		return
	var directory := "res://.orca_editor_inspector_link_test_%d" % Time.get_ticks_usec()
	var absolute := ProjectSettings.globalize_path(directory)
	_expect(DirAccess.make_dir_recursive_absolute(absolute) == OK, "symlink fixture parent should exist")
	var link := absolute.path_join("linked")
	var result := OS.execute("ln", PackedStringArray(["-s", ProjectSettings.globalize_path("res://tests/fixtures"), link]))
	_expect(result == 0, "symlink fixture should be created")
	if result == 0:
		var root := Node.new()
		root.scene_file_path = directory.path_join("linked/inspect_scene_fixture.tscn")
		_expect(not Inspector.snapshot(root, [], {"scope": "scene"}, false, Tools._validate_path).get("success", true), "live scene identities must reject symbolic-link traversal")
		root.scene_file_path = ""
		var texture := GradientTexture2D.new()
		texture.resource_path = directory.path_join("linked/private.tres")
		_expect(Inspector._resource_reference(texture, Tools._validate_path).get("storage") == "blocked_reference", "live resource identities must share the symlink policy")
		root.free()
		DirAccess.remove_absolute(link)
	DirAccess.remove_absolute(absolute)
	_expect(not DirAccess.dir_exists_absolute(absolute), "symlink fixture must be removed without traversing its target")


func _test_bounds() -> void:
	var root := Node.new()
	for index in range(260):
		var child := Node.new()
		child.name = "Child%d" % index
		root.add_child(child)
	var limited := _snapshot(root, [], {"scope": "scene", "max_nodes": 2, "include_properties": false})
	_expect(limited.get("returned_node_count") == 2 and "node_limit" in limited.get("truncation", {}).get("reasons", []), "node cap must bound output and disclose truncation")
	_expect("visit_limit" in limited.get("truncation", {}).get("reasons", []) and limited.get("visited_node_count", 999) <= Inspector.MAX_VISITED_NODES, "wide scenes must not enqueue an unbounded child list")
	var shallow := _snapshot(root, [], {"scope": "scene", "max_depth": 0})
	_expect(shallow.get("returned_node_count") == 1 and "depth_limit" in shallow.get("truncation", {}).get("reasons", []), "depth zero must inspect only the root")
	var selections: Array = root.get_children().slice(0, 25)
	var selection := _snapshot(root, selections)
	_expect(selection.get("returned_node_count") == Inspector.MAX_SELECTION and "selection_limit" in selection.get("truncation", {}).get("reasons", []), "multiple selections must be bounded without returning arbitrary siblings")
	root.free()
	root = Node.new()
	for index in range(20):
		var control := Control.new()
		control.name = "Panel%d" % index
		root.add_child(control)
		for group_index in range(Inspector.MAX_GROUPS):
			control.add_to_group("g".repeat(256) + str(group_index))
	var output := _snapshot(root, [], {"scope": "scene", "max_nodes": 120})
	_expect("output_limit" in output.get("truncation", {}).get("reasons", []), "large records must truncate whole nodes before exceeding the JSON byte limit")
	_expect("string_limit" in output.get("truncation", {}).get("reasons", []), "bounded group labels must disclose their truncation")
	var properties := _snapshot(root, [root.get_child(0)], {"max_properties_per_node": 1})
	_expect(properties.get("returned_property_count") == 1 and "property_limit" in properties.get("truncation", {}).get("reasons", []), "per-node property caps must be disclosed")
	root.free()
	root = Node.new()
	root.scene_file_path = "res://tests/fixtures/inspect_scene_fixture.tscn"
	var slow_policy := func(_path: String, _writing: bool) -> String:
		OS.delay_msec(Inspector.INSPECTION_TIMEOUT_MS + 1)
		return ""
	var timed := Inspector.snapshot(root, [], {"scope": "scene"}, false, slow_policy)
	_expect(timed.get("success", false) and "time_limit" in timed.get("report", {}).get("truncation", {}).get("reasons", []), "elapsed inspection pressure must produce an honest bounded partial snapshot")
	root.free()


func _test_references() -> void:
	var root := Node.new()
	var sprite := Sprite2D.new()
	sprite.name = "Sprite"
	sprite.texture = GradientTexture2D.new()
	root.add_child(sprite)
	var report := _snapshot(root, [sprite])
	var references: Array = node_record(report, "Sprite").get("resources", [])
	_expect(references.size() == 1 and references[0].get("storage") == "built_in" and references[0].get("class") == "GradientTexture2D", "built-in resources should expose identity only, without recursive getters")
	var blocked_reference := Inspector._resource_reference(sprite.texture, func(_path: String, _writing: bool) -> String: return "blocked")
	_expect(blocked_reference.get("storage") == "built_in", "path policy should not read or load a built-in resource")
	sprite.texture.resource_path = "res://addons/orca/icons/private.png"
	report = _snapshot(root, [sprite])
	_expect(not JSON.stringify(report).contains("private.png") and "reference_boundary" in report.get("truncation", {}).get("reasons", []), "protected resource paths must be redacted and boundary omission disclosed")
	sprite.texture.resource_path = "res://tests/fixtures/inspect_scene_fixture.tscn::Texture_1"
	report = _snapshot(root, [sprite])
	references = node_record(report, "Sprite").get("resources", [])
	_expect(references[0].get("storage") == "subresource" and references[0].get("path") == sprite.texture.resource_path, "safe subresource identity should remain distinguishable from external files")
	root.free()


static func node_record(report: Dictionary, path: String) -> Dictionary:
	for node in report.get("nodes", []):
		if node.get("path") == path:
			return node
	return {}


static func property_value(record: Dictionary, name: String):
	for property in record.get("properties", []):
		if property.get("name") == name:
			return property.get("value")
	return null


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("editor_scene_inspector_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("editor_scene_inspector_test: ", failure)
	quit(1)
