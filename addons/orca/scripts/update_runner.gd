extends SceneTree

# Executed using the current Godot binary in a private minimal project. The
# updater copies this trusted installer and update_package.gd before handoff.
# It has no addon/editor/account dependencies and never executes staged code.
var package


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	package = load(get_script().resource_path.get_base_dir().path_join("update_package.gd"))
	var arguments := OS.get_cmdline_user_args()
	var manual := arguments.size() == 2 and arguments[0] == "--recover"
	var intent = {"project": arguments[1], "parent_pid": 0, "headless": false, "operation": "recover", "old_hash": "", "new_hash": ""} if manual else JSON.parse_string(OS.read_string_from_stdin())
	if typeof(intent) != TYPE_DICTIONARY or intent.size() != 6 or typeof(intent.get("project")) != TYPE_STRING or intent["project"].length() > 4096 or typeof(intent.get("parent_pid")) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(intent["parent_pid"])) or (intent["parent_pid"] <= 0 and not manual) or intent["parent_pid"] != floorf(intent["parent_pid"]) or typeof(intent.get("headless")) != TYPE_BOOL or intent.get("operation") not in ["install", "recover"] or typeof(intent.get("old_hash")) != TYPE_STRING or typeof(intent.get("new_hash")) != TYPE_STRING:
		quit(1)
		return
	var project: String = intent["project"]
	var owned: Dictionary = package.owned_workspace(project)
	if not owned.get("success", false):
		quit(1)
		return
	var root: String = owned["root"]
	if manual:
		var locked: Dictionary = package.acquire_lock(project, OS.get_process_id())
		if not locked.get("success", false):
			quit(1)
			return
	elif package.read_json(root.path_join("lock/owner.json"), 4096) != {"pid": intent["parent_pid"]}:
		quit(1)
		return
	var ready := true
	if intent["operation"] == "install":
		ready = package.inspect_tree(project.path_join("addons/orca"), intent["old_hash"]).get("success", false) and package.inspect_tree(root.path_join("staged"), intent["new_hash"]).get("success", false)
	else:
		var transaction: Dictionary = package.read_json(root.path_join("transaction.json"), 4096)
		ready = transaction.get("format") == package.FORMAT and (package.inspect_tree(root.path_join("backup"), str(transaction.get("old_hash", "invalid"))).get("success", false) or package.inspect_tree(project.path_join("addons/orca"), str(transaction.get("old_hash", "invalid"))).get("success", false))
	if not ready or not package.write_json(root.path_join("worker.json"), {"pid": OS.get_process_id(), "state": "waiting"}):
		quit(1)
		return
	if not package.write_json(root.path_join("lock/owner.json"), {"pid": OS.get_process_id()}):
		quit(1)
		return
	print("READY")
	# From this point stdout can close with the owner editor. Use the bounded
	# local result record instead of writing to a disconnected private pipe.
	var deadline := Time.get_ticks_msec() + 60000
	while package.process_alive(int(intent["parent_pid"])):
		if Time.get_ticks_msec() > deadline:
			package.write_json(root.path_join("worker.json"), {"pid": 0, "state": "cancelled"})
			package.release_lock(root, OS.get_process_id())
			quit(1)
			return
		await create_timer(0.25).timeout
	var result: Dictionary = package.install(project, intent["old_hash"], intent["new_hash"]) if intent["operation"] == "install" else package.recover(project)
	if not result.get("success", false):
		# A crash/IO failure between directory moves may still have a recoverable
		# original. Recovery refuses unknown/modified current or backup bytes.
		var restored: Dictionary = package.recover(project)
		if restored.get("success", false):
			result["restored"] = true
	package.write_json(root.path_join("result.json"), result)
	package.write_json(root.path_join("worker.json"), {"pid": 0, "state": "finished"})
	package.release_lock(root, OS.get_process_id())
	if DirAccess.dir_exists_absolute(project.path_join("addons/orca")):
		var args := PackedStringArray(["--editor", "--path", project])
		if intent["headless"]:
			args.append("--headless")
		var pid := 0
		if OS.get_name() in ["Linux", "macOS"]:
			# The reopened editor must not inherit the installer's closed private
			# stdout/stderr pipes. This fixed shell program does no payload eval;
			# executable/project are separate quoted positional arguments.
			var command := "exec \"$1\" --editor --path \"$2\" </dev/null >/dev/null 2>&1"
			if intent["headless"]:
				command = "exec \"$1\" --headless --editor --path \"$2\" </dev/null >/dev/null 2>&1"
			pid = OS.create_process("/bin/sh", PackedStringArray(["-c", command, "orca-reopen", OS.get_executable_path(), project]))
		else:
			pid = OS.create_process(OS.get_executable_path(), args)
		if pid <= 0:
			package.write_json(root.path_join("result.json"), package.failure("Update completed, but Godot could not reopen the project. Reopen it manually."))
	quit(0 if result.get("success", false) else 1)
