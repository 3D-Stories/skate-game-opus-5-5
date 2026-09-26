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
	var http := HTTPRequest.new()
	http.download_file = dest
	http.use_threads = false
	host.add_child(http)
	var err := http.request(url)
	if err != OK:
		http.queue_free()
		return false
	var done := [false, 0]
	http.request_completed.connect(func(result, code, _h, _b): done[0] = true; done[1] = code if result == HTTPRequest.RESULT_SUCCESS else -1)
	while not done[0]:
		if progress.is_valid():
			progress.call(http.get_downloaded_bytes(), http.get_body_size())
		await host.get_tree().process_frame
	http.queue_free()
	if int(done[1]) != 200:
		push_warning("level pack %s: HTTP %s" % [url, str(done[1])])
		return false
	if not ProjectSettings.load_resource_pack(dest, false):
		push_warning("level pack %s: could not be mounted" % dest)
		return false
	_packs_loaded[id] = true
	return available(id)
