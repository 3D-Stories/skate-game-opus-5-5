extends SceneTree
## Stills of a level in the real game: the skater is placed at each of the level's test
## shots (levels/<id>/level.json "test": "shots", Blender coordinates) and the chase camera
## frames the skater as in play; one PNG per shot. Needs a display (not --headless).
##
##   godot --path . --resolution 1920x1080 -s tests/level_shots.gd -- --level=baths [--out=evidence/baths_shots] [--only=pool,bank] [--hud]

var main: Node
var out := "/tmp/skate-work/shots"
var only: Array = []
var hud := false


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.get_slice("=", 1)
		elif a.begins_with("--only="):
			only = a.get_slice("=", 1).split(",")
		elif a == "--hud":
			hud = true
	DirAccess.make_dir_recursive_absolute(out)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


static func b2g(p: Array) -> Vector3:
	return Vector3(p[0], p[2] if p.size() > 2 else 0.0, -p[1])


func _run() -> void:
	for i in 20:
		await process_frame
	main.start_run()
	main.hud.visible = hud
	var shots: Array = LevelRegistry.def(main.level.level_id).get("test", {}).get("shots", [])
	for s in shots:
		if not only.is_empty() and not (s["name"] in only):
			continue
		main.time_left = main.RUN_TIME
		var d := b2g(s["dir"])
		main.skater.spawn(b2g(s["at"]), d.normalized(), float(s.get("speed", 0.0)))
		main.cam.snap()
		for i in int(s.get("frames", 45)):
			await physics_frame
		await process_frame
		await process_frame
		var img := root.get_viewport().get_texture().get_image()
		var path := out.path_join("%s_%s.png" % [main.level.level_id, s["name"]])
		img.save_png(path)
		print("[shots] ", path)
	quit()
