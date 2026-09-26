class_name LevelRegistry
extends RefCounted
## The levels the game knows, read from data: res://levels/registry.json lists the level ids
## (the first "default" one is where the game starts), and each res://levels/<id>/level.json
## holds the level's name, blurb, goals, environment and asset paths ("game" section; the
## "build" section is for the Blender level kit). Adding a level = adding its folder and
## its id to the registry (tools: blender/levelkit/scaffold.py).
##
## A level's assets may live in a separate resource pack (web build: "pack" in level.json,
## fetched next to index.html the first time the level is chosen, see fetch_pack()).

const REGISTRY := "res://levels/registry.json"

static var _reg: Dictionary = {}
static var _defs: Dictionary = {}
static var _packs_loaded: Dictionary = {}


static func registry() -> Dictionary:
	if _reg.is_empty():
		_reg = JSON.parse_string(FileAccess.get_file_as_string(REGISTRY))
	return _reg


static func ids() -> Array:
	return registry().get("levels", [])


static func default_id() -> String:
	return String(registry().get("default", ids()[0]))


static func def(id: String) -> Dictionary:
	if not _defs.has(id):
		var d = JSON.parse_string(FileAccess.get_file_as_string("res://levels/%s/level.json" % id))
		_defs[id] = d if d is Dictionary else {}
	return _defs[id]


static func game(id: String) -> Dictionary:
	return def(id).get("game", {})


static func has(id: String) -> bool:
	return id in ids()


static func startup_id() -> String:
	## --level=<id> on the command line, ?level=<id> in the web page's URL, else the default.
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--level="):
			var id := a.get_slice("=", 1)
			if has(id):
				return id
	if OS.has_feature("web"):
		var q = JavaScriptBridge.eval("new URLSearchParams(window.location.search).get('level') || ''", true)
		if q is String and has(q):
			return q
	return default_id()


static func available(id: String) -> bool:
	## The level's assets can be loaded now (in the project, the desktop build, or its pack
	## has been fetched already).
	var a: Dictionary = game(id).get("assets", {})
	return ResourceLoader.exists(String(a.get("glb", ""))) and FileAccess.file_exists(String(a.get("data", "")))


static func pack_url(id: String) -> String:
	var p := String(game(id).get("pack", ""))
	if p == "" or not OS.has_feature("web"):
		return ""
	var u = JavaScriptBridge.eval("new URL('%s', window.location.href).href" % p, true)
	return String(u) if u is String else p


static func fetch_pack(id: String, host: Node, progress: Callable = Callable()) -> bool:
	## Download the level's resource pack (web build) and mount it. Returns true when the
	## level's assets are available afterwards.
	if available(id):
		return true
	var url := pack_url(id)
	if url == "":
		return false
	var dest := "user://levels/%s.pck" % id
	DirAccess.make_dir_recursive_absolute("user://levels")
	# (the body is kept in memory and written out here: the web build's HTTPRequest does
	# not write download_file)
	var http := HTTPRequest.new()
	http.use_threads = false
	http.download_chunk_size = 1 << 22      # (the default 64 KB a frame makes a big pack crawl)
	host.add_child(http)
	var done := [false, 0, PackedByteArray()]
	http.request_completed.connect(func(result, code, _h, b):
		done[0] = true
		done[1] = code if result == HTTPRequest.RESULT_SUCCESS else -1
		done[2] = b)
	var err := http.request(url)
	if err != OK:
		http.queue_free()
		return false
	while not done[0]:
		if progress.is_valid():
			progress.call(http.get_downloaded_bytes(), http.get_body_size())
		await host.get_tree().process_frame
	http.queue_free()
	var body: PackedByteArray = done[2]
	print("[level] pack %s: HTTP %d, %d bytes" % [url.get_file(), int(done[1]), body.size()])
	if int(done[1]) != 200 or body.size() < 16:
		push_warning("level pack %s: HTTP %s" % [url, str(done[1])])
		return false
	var f := FileAccess.open(dest, FileAccess.WRITE)
	if f == null:
		push_warning("level pack %s: cannot write %s" % [url, dest])
		return false
	f.store_buffer(body)
	f.close()
	if not ProjectSettings.load_resource_pack(dest, false):
		push_warning("level pack %s: could not be mounted" % dest)
		return false
	_register_uids(String(game(id).get("assets", {}).get("glb", "")).get_base_dir())
	_packs_loaded[id] = true
	return available(id)


static func _register_uids(dir: String) -> void:
	## A mounted pack's resources are not in the main pack's UID cache: add each one's UID
	## (from its .import file) so references by UID resolve without falling back to paths.
	for f in DirAccess.get_files_at(dir):
		if not f.ends_with(".import"):
			continue
		var cf := ConfigFile.new()
		if cf.load(dir.path_join(f)) != OK:
			continue
		var uid := String(cf.get_value("remap", "uid", ""))
		if uid == "":
			continue
		var n := ResourceUID.text_to_id(uid)
		var src := dir.path_join(f.trim_suffix(".import"))
		if ResourceUID.has_id(n):
			ResourceUID.set_id(n, src)
		else:
			ResourceUID.add_id(n, src)
