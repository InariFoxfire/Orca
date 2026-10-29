@tool
extends Node

signal changed
signal install_requested(operation: String)
signal _network_reply(reply: Array)

const Package = preload("res://addons/orca/scripts/update_package.gd")
const RELEASE_API := "https://api.github.com/repos/cold-atom/Orca/releases/latest"
const RELEASES := "https://github.com/cold-atom/Orca/releases"
const DOWNLOAD_ROOT := "https://github.com/cold-atom/Orca/releases/download/"
const AUTO_SETTING := "orca/updates/automatic_checks"
const CHECK_SETTING := "orca/updates/last_check"
const DISMISS_SETTING := "orca/updates/dismissed_version"
const CACHE_SETTING := "orca/updates/latest_release"
const CHECK_INTERVAL := 86400

var state := "idle"
var status := "Updates come from official Orca GitHub Releases."
var installed_version := ""
var release := {}
var downloaded_bytes := 0
var _request: HTTPRequest
var _generation := 0
var _closed := false
var _thread: Thread
var _installer := {}
var _handed_off := false
var _progress_tick := 0
var _auto_timer: Timer
var _lock_root := ""
var _lock_pid := 0


func _ready() -> void:
	var config := ConfigFile.new()
	if config.load("res://addons/orca/plugin.cfg") == OK:
		installed_version = str(config.get_value("plugin", "version", ""))
	set_process(false)
	if Engine.is_editor_hint():
		var cached = _setting(CACHE_SETTING, {})
		if typeof(cached) == TYPE_DICTIONARY and cached.size() == 5 and typeof(cached.get("version")) == TYPE_STRING and cached["version"].length() <= 32 and typeof(cached.get("sha256")) == TYPE_STRING and cached["sha256"].length() == 64:
			var restored := normalize_release({"draft": false, "prerelease": false, "tag_name": "v" + cached["version"], "assets": [{"name": "orca-v" + cached["version"] + ".zip", "browser_download_url": cached.get("url", ""), "size": cached.get("size", 0), "digest": "sha256:" + cached["sha256"]}]}, installed_version)
			if restored.get("success", false) and not restored.get("release", {}).is_empty():
				release = restored["release"]
				state = "available"
				status = "Orca " + release["version"] + " is available."
		_auto_timer = Timer.new()
		_auto_timer.wait_time = 3600
		_auto_timer.timeout.connect(_automatic_check)
		add_child(_auto_timer)
		_auto_timer.start()
		call_deferred("_automatic_check")
		var result := Package.read_json(ProjectSettings.globalize_path("res://").path_join(Package.WORKSPACE).path_join("result.json"), 4096)
		if not result.is_empty():
			status = "Update installed. Your previous addon is retained for rollback." if result.get("success", false) and not result.get("rolled_back", false) else "The previous addon was restored." if result.get("rolled_back", false) else str(result.get("error", "The previous update stopped."))


func _exit_tree() -> void:
	_closed = true
	cancel()
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	close_installer(not _handed_off)
	if not _handed_off:
		_release_lock()


func _process(_delta: float) -> void:
	if _request != null and state == "downloading" and Time.get_ticks_msec() - _progress_tick > 200:
		_progress_tick = Time.get_ticks_msec()
		downloaded_bytes = _request.get_downloaded_bytes()
		changed.emit()


func automatic_checks() -> bool:
	return bool(_setting(AUTO_SETTING, true))


func set_automatic_checks(enabled: bool) -> void:
	_save_setting(AUTO_SETTING, enabled)
	changed.emit()


func dismissed() -> bool:
	return not release.is_empty() and _setting(DISMISS_SETTING, "") == release.get("version")


func dismiss() -> void:
	if not release.is_empty():
		_save_setting(DISMISS_SETTING, release["version"])
	changed.emit()


func busy() -> bool:
	return state in ["checking", "downloading", "preparing", "restarting"] or _thread != null or _request != null or not _installer.is_empty()


func _automatic_check() -> void:
	if _closed or OS.get_environment("ORCA_DISABLE_UPDATE_CHECKS") == "1" or not automatic_checks() or busy():
		return
	var now := Time.get_unix_time_from_system()
	var last = _setting(CHECK_SETTING, 0)
	if typeof(last) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(last)) or now < float(last) or now - float(last) >= CHECK_INTERVAL:
		check_for_updates()


func check_for_updates() -> void:
	if busy() or _closed:
		return
	_generation += 1
	var generation := _generation
	_save_setting(CHECK_SETTING, Time.get_unix_time_from_system())
	_set_state("checking", "Checking GitHub Releases…")
	var reply := await _fetch(RELEASE_API, 128 * 1024)
	if generation != _generation or _closed:
		return
	if not reply.get("success", false):
		_set_state("error", str(reply.get("error", "Could not check for updates.")))
		return
	var text: String = reply["bytes"].get_string_from_utf8()
	var value = JSON.parse_string(text) if text.to_utf8_buffer() == reply["bytes"] else null
	var normalized := normalize_release(value, installed_version)
	if not normalized.get("success", false):
		_set_state("error", str(normalized.get("error", "Unsupported release metadata.")))
		return
	release = normalized.get("release", {})
	_save_setting(CACHE_SETTING, release)
	_set_state("available" if not release.is_empty() else "up_to_date", "Orca " + str(release.get("version", "")) + " is available." if not release.is_empty() else "You have the latest stable Orca release.")


static func normalize_release(value, current: String) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY or value.get("draft") != false or value.get("prerelease") != false or typeof(value.get("tag_name")) != TYPE_STRING or not value["tag_name"].begins_with("v") or typeof(value.get("assets")) != TYPE_ARRAY or value["assets"].size() > 32:
		return Package.failure("GitHub returned unsupported release metadata.")
	var version: String = value["tag_name"].trim_prefix("v")
	var comparison := Package.compare_versions(version, current)
	if comparison == -2:
		return Package.failure("Installed/release versions must use stable major.minor.patch numbers.")
	if comparison <= 0:
		return {"success": true, "release": {}}
	var name := "orca-v" + version + ".zip"
	var expected := DOWNLOAD_ROOT + "v" + version + "/" + name
	var found := {}
	for asset in value["assets"]:
		if typeof(asset) != TYPE_DICTIONARY or asset.get("name") != name:
			continue
		var size = asset.get("size")
		var digest = asset.get("digest")
		if not found.is_empty() or asset.get("browser_download_url") != expected or typeof(size) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(size)) or size != floorf(size) or size < 22 or size > Package.MAX_ARCHIVE or typeof(digest) != TYPE_STRING or not digest.begins_with("sha256:") or digest.length() != 71 or not digest.substr(7).is_valid_hex_number(false):
			return Package.failure("The official release asset has invalid size, checksum, or URL metadata.")
		found = {"version": version, "url": expected, "size": int(size), "sha256": digest.substr(7).to_lower(), "page": RELEASES + "/tag/v" + version}
	if found.is_empty():
		return Package.failure("This release has no supported Orca update ZIP. Open GitHub Releases to download it.")
	return {"success": true, "release": found}


static func allowed_download_url(url: String, initial: String) -> bool:
	if url == initial:
		return url.begins_with(DOWNLOAD_ROOT)
	if url.length() > 8192 or not url.begins_with("https://release-assets.githubusercontent.com/") or url.contains("\r") or url.contains("\n") or url.contains("\\") or url.contains("#") or url.contains("@"):
		return false
	return true


func request_install(operation: String = "install") -> void:
	if operation in ["install", "recover"] and not busy() and (operation == "recover" or not release.is_empty()):
		install_requested.emit(operation)


func prepare_update() -> Dictionary:
	if release.is_empty() or busy() or _closed:
		return Package.failure("No update is ready to download.")
	_generation += 1
	var generation := _generation
	var chosen := release.duplicate(true)
	_set_state("preparing", "Checking installed addon files…")
	var project := _project_root()
	var old := await _job(func(): return Package.inspect_tree(project.path_join("addons/orca")))
	if generation != _generation or not old.get("success", false):
		return _preparation_failed(old, generation)
	var workspace := Package.acquire_lock(project, OS.get_process_id())
	if not workspace.get("success", false):
		return _preparation_failed(workspace, generation)
	var root: String = workspace["root"]
	_lock_root = root
	_lock_pid = OS.get_process_id()
	var worker := Package.read_json(root.path_join("worker.json"), 4096)
	if int(worker.get("pid", 0)) > 0 and Package.process_alive(int(worker["pid"])):
		return _preparation_failed(Package.failure("Another editor is already updating this project."), generation)
	var transaction := Package.read_json(root.path_join("transaction.json"), 4096)
	for pair in [["backup", "old_hash"], ["staged", "new_hash"]]:
		var path: String = root.path_join(pair[0])
		if DirAccess.dir_exists_absolute(path):
			var safe_previous: bool = transaction.get("state") in ["installed", "rolled_back"] or (transaction.get("state") == "prepared" and Package.inspect_tree(project.path_join("addons/orca"), str(transaction.get("old_hash", "invalid"))).get("success", false))
			if not safe_previous or not Package.inspect_tree(path, str(transaction.get(pair[1], "invalid"))).get("success", false) or (pair[0] != "backup" and not Package.remove_tree(path)):
				return _preparation_failed(Package.failure("A prior update needs recovery or contains changed files. Restore it before updating."), generation)
	var archive := root.path_join("download.zip")
	if not Package.no_links(archive):
		return _preparation_failed(Package.failure("The download path is a symbolic link."), generation)
	downloaded_bytes = 0
	_set_state("downloading", "Downloading Orca " + chosen["version"] + "…")
	var reply := await _fetch(chosen["url"], chosen["size"], archive, true)
	if generation != _generation or not reply.get("success", false):
		return _preparation_failed(reply, generation)
	_set_state("preparing", "Verifying and staging the release…")
	var engine := Engine.get_version_info()
	var engine_version := "%d.%d.%d" % [engine["major"], engine["minor"], engine["patch"]]
	var stage := root.path_join("staged")
	var prepared := await _job(func(): return Package.extract_archive(archive, stage, chosen["version"], chosen["sha256"], engine_version))
	if generation != _generation or not prepared.get("success", false):
		# Only the stage created by this operation is eligible for scratch cleanup.
		Package.remove_tree(stage)
		return _preparation_failed(prepared, generation)
	DirAccess.remove_absolute(archive)
	if DirAccess.dir_exists_absolute(root.path_join("backup")) and (not Package.inspect_tree(root.path_join("backup"), str(transaction.get("old_hash", "invalid"))).get("success", false) or not Package.remove_tree(root.path_join("backup"))):
		return _preparation_failed(Package.failure("The previous rollback copy changed; it was preserved."), generation)
	if not Package.write_json(root.path_join("transaction.json"), {"format": Package.FORMAT, "old_hash": old["hash"], "new_hash": prepared["hash"], "state": "prepared"}):
		return _preparation_failed(Package.failure("Could not record the prepared update."), generation)
	_set_state("ready", "Verified. Preparing the editor restart…")
	return {"success": true, "project": project, "old_hash": old["hash"], "new_hash": prepared["hash"]}


func launch_installer(prepared: Dictionary, operation: String = "install") -> Dictionary:
	var project: String = prepared.get("project", _project_root())
	var workspace := Package.owned_workspace(project)
	if not workspace.get("success", false):
		return workspace
	if operation == "recover":
		workspace = Package.acquire_lock(project, OS.get_process_id())
		if not workspace.get("success", false):
			return workspace
		_lock_root = workspace["root"]
		_lock_pid = OS.get_process_id()
	var runner_root := _runner_root(project)
	if not Package.no_links(runner_root) or DirAccess.make_dir_recursive_absolute(runner_root) != OK:
		return Package.failure("Could not prepare the independent updater.")
	for name in ["update_runner.gd", "update_package.gd"]:
		var target := runner_root.path_join(name)
		if not Package.no_links(target) or DirAccess.copy_absolute(ProjectSettings.globalize_path("res://addons/orca/scripts/" + name), target) != OK:
			return Package.failure("Could not copy the trusted updater scripts.")
	if not Package.no_links(runner_root.path_join("project.godot")):
		return Package.failure("The private updater project path is a symbolic link.")
	var config := FileAccess.open(runner_root.path_join("project.godot"), FileAccess.WRITE)
	if config == null:
		return Package.failure("Could not prepare the updater's private project.")
	config.store_string("config_version=5\n[application]\nconfig/name=\"Orca Update Installer\"\n")
	config.close()
	_installer = OS.execute_with_pipe(OS.get_executable_path(), PackedStringArray(["--headless", "--path", runner_root, "--script", runner_root.path_join("update_runner.gd")]), false)
	if _installer.is_empty():
		return Package.failure("Godot could not start the independent updater.")
	var intent := {"project": project, "parent_pid": OS.get_process_id(), "old_hash": str(prepared.get("old_hash", "")), "new_hash": str(prepared.get("new_hash", "")), "operation": operation, "headless": "--headless" in OS.get_cmdline_args()}
	_installer["stdio"].store_string(JSON.stringify(intent) + "\n")
	var output := PackedByteArray()
	var deadline := Time.get_ticks_msec() + 30000
	while not _closed and Time.get_ticks_msec() < deadline and OS.is_process_running(int(_installer.get("pid", 0))):
		output.append_array(_installer["stdio"].get_buffer(4096))
		if output.size() > 16384:
			break
		if "READY\n" in output.get_string_from_utf8():
			_lock_pid = int(_installer["pid"])
			return {"success": true}
		await get_tree().process_frame
	close_installer(true)
	_release_lock()
	return Package.failure("The independent updater could not verify its handoff. The editor remains open.")


func hand_off() -> void:
	_handed_off = true
	_set_state("restarting", "Closing Godot; the verified updater will reopen this project.")
	close_installer(false)


func close_installer(stop: bool) -> void:
	if _installer.is_empty():
		return
	var pid := int(_installer.get("pid", 0))
	if stop and pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)
	for key in ["stdio", "stderr"]:
		var pipe = _installer.get(key)
		if pipe != null and pipe.is_open():
			pipe.close()
	_installer.clear()
	if stop and _thread == null:
		_release_lock()


func cancel() -> void:
	if state == "restarting":
		return
	_generation += 1
	if _request != null:
		_request.cancel_request()
		_network_reply.emit([HTTPRequest.RESULT_REQUEST_FAILED, 0, PackedStringArray(), PackedByteArray()])
	close_installer(true)
	_set_state("available" if not release.is_empty() else "idle", "Update cancelled.")


func show_error(message: String) -> void:
	if _thread == null and _request == null:
		close_installer(true)
		_release_lock()
	_set_state("error", message)


func _preparation_failed(result: Dictionary, generation: int) -> Dictionary:
	_release_lock()
	if generation == _generation and not _closed:
		show_error(str(result.get("error", "Update preparation failed.")))
	return Package.failure(str(result.get("error", "Update cancelled.")))


func _release_lock() -> void:
	if not _lock_root.is_empty():
		Package.release_lock(_lock_root, _lock_pid)
		_lock_root = ""
		_lock_pid = 0


func _job(work: Callable) -> Dictionary:
	_thread = Thread.new()
	if _thread.start(work) != OK:
		_thread = null
		return Package.failure("Could not start bounded update preparation.")
	while _thread.is_alive():
		await get_tree().process_frame
		if _closed:
			return Package.failure("Updater closed.")
	var result: Dictionary = _thread.wait_to_finish()
	_thread = null
	changed.emit()
	return result


func _fetch(url: String, limit: int, destination: String = "", downloads: bool = false) -> Dictionary:
	var initial := url
	for hop in 4:
		if _closed or (downloads and not allowed_download_url(url, initial)) or (not downloads and url != RELEASE_API):
			return Package.failure("Update request changed to an unsupported origin.")
		var request := HTTPRequest.new()
		request.timeout = 30.0 if destination.is_empty() else 120.0
		request.body_size_limit = limit
		request.accept_gzip = false
		request.max_redirects = 0
		request.download_file = destination
		add_child(request)
		_request = request
		request.request_completed.connect(func(result, code, headers, body): _network_reply.emit([result, code, headers, body]), CONNECT_ONE_SHOT)
		var headers := PackedStringArray(["Accept: application/vnd.github+json", "User-Agent: Orca-Godot-Updater", "Accept-Encoding: identity"])
		var error := request.request(_transport_url(url), headers)
		if error != OK:
			_request = null
			request.queue_free()
			return Package.failure("The update request could not start.")
		set_process(true)
		var reply: Array = await _network_reply
		if _closed:
			return Package.failure("Updater closed.")
		await get_tree().process_frame
		if _closed:
			return Package.failure("Updater closed.")
		_request = null
		request.queue_free()
		set_process(false)
		changed.emit()
		if reply[0] != HTTPRequest.RESULT_SUCCESS and not (downloads and reply[0] == HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED and reply[1] in [301, 302, 303, 307, 308]):
			return Package.failure("Could not reach GitHub or the update exceeded its download limit. Try again later.")
		if downloads and reply[1] in [301, 302, 303, 307, 308]:
			var location := ""
			for header in reply[2]:
				if str(header).to_lower().begins_with("location:"):
					if not location.is_empty():
						return Package.failure("Duplicate update redirect headers.")
					location = str(header).substr(9).strip_edges()
			url = location
			continue
		if reply[1] != 200:
			return Package.failure("GitHub returned HTTP %d. Try again later or open Releases." % reply[1])
		return {"success": true, "bytes": reply[3]}
	return Package.failure("The update download redirected too many times.")


func _project_root() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/")


func _runner_root(project: String) -> String:
	return project.path_join(Package.WORKSPACE).path_join("runner")


func _transport_url(url: String) -> String:
	return url


func _setting(key: String, fallback):
	if Engine.is_editor_hint():
		var settings := EditorInterface.get_editor_settings()
		if settings.has_setting(key):
			return settings.get_setting(key)
	return fallback


func _save_setting(key: String, value) -> void:
	if Engine.is_editor_hint():
		EditorInterface.get_editor_settings().set_setting(key, value)


func _set_state(next: String, message: String) -> void:
	state = next
	status = message
	changed.emit()
