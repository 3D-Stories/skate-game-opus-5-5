extends SceneTree
## Builds a level's web resource pack: every asset under res://assets/levels/<id>/ as the
## exported game needs it (each .import remap plus its .godot/imported/ artefacts, and plain
## files such as the level's data JSON). The web build fetches it the first time the level is
## chosen (LevelRegistry.fetch_pack); the Web export preset excludes assets/levels/*, so
## these bytes are not in index.pck.
##
##   godot --headless --path . --script res://tools/pack_level.gd -- --level=baths --out=build/web/levels/baths.pck
##
## tools/export_web.sh runs the web export and then this for every level that has a "pack".
## Run after `godot --headless --path . --import` so the imported artefacts are current.


func _init() -> void:
	var id := ""
	var out := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--level="):
			id = a.get_slice("=", 1)
		elif a.begins_with("--out="):
			out = a.get_slice("=", 1)
	if id == "" or out == "":
		printerr("usage: --script res://tools/pack_level.gd -- --level=<id> --out=<file.pck>")
		quit(2)
		return
	quit(pack(id, out))


func pack(id: String, out: String) -> int:
	var dir := "res://assets/levels/%s" % id
	if not DirAccess.dir_exists_absolute(dir):
		printerr("[pack] no ", dir)
		return 1
	if not out.is_absolute_path():
		out = OS.get_environment("PWD").path_join(out)
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	var files := Array(DirAccess.get_files_at(dir))
	files.sort()
	var entries: Array = []   # [path in the pack, source file]
	for f in files:
		var p := dir.path_join(f)
		if f.ends_with(".import"):
			var cf := ConfigFile.new()
			if cf.load(p) != OK:
				printerr("[pack] cannot read ", p)
				return 1
			entries.append([p, p])
			for d in cf.get_value("deps", "dest_files", []):
				if not FileAccess.file_exists(d):
					printerr("[pack] missing import artefact ", d, " (run godot --headless --path . --import)")
					return 1
				entries.append([d, d])
		elif FileAccess.file_exists(p + ".import") or f.ends_with(".uid"):
			continue   # the import source; the game loads its imported artefact instead
		else:
			entries.append([p, p])
	var pk := PCKPacker.new()
	if pk.pck_start(out) != OK:
		printerr("[pack] cannot write ", out)
		return 1
	var total := 0
	for e in entries:
		if pk.add_file(e[0], ProjectSettings.globalize_path(e[1])) != OK:
			printerr("[pack] add_file failed ", e[0])
			return 1
		total += FileAccess.get_file_as_bytes(e[1]).size()
	if pk.flush(false) != OK:
		printerr("[pack] flush failed")
		return 1
	var size := FileAccess.get_file_as_bytes(out).size()
	print("[pack] %s: %d files, %.1f MB of content -> %s (%.1f MB)" % [id, entries.size(), total / 1048576.0, out, size / 1048576.0])
	return 0
