extends SceneTree
## Screenshots of the Skater screen (character builder) driven by real key events, from the
## start screen through a few changes. Needs a real renderer (no --headless):
##   godot --path . --resolution 1920x1080 -s tests/builder_shots.gd -- --out=evidence/builder
## Steps: start screen, the builder as opened, the female body, then her tee / cargo / hi-top /
## cap, and the start screen again after "Done".

var out := "res://evidence/builder"
var main: Node
var shots: Array = []


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.get_slice("=", 1)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out) if out.begins_with("res://") else out)
	SkaterOutfit.override = {}
	SkaterOutfit.save_path = "user://skater_builder_shots.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SkaterOutfit.save_path))
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func key(k: Key) -> void:
	var e := InputEventKey.new()
	e.keycode = k
	e.physical_keycode = k
	e.pressed = true
	Input.parse_input_event(e)
	await process_frame
	await process_frame
	var u := e.duplicate()
	u.pressed = false
	Input.parse_input_event(u)
	await process_frame


func wait(n: int) -> void:
	for i in n:
		await process_frame


func shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	var p := out.path_join(name + ".png")
	img.save_png(p)
	shots.append(p)
	print("[builder_shots] ", p)


func builder() -> Node:
	# (by name: naming the class here would compile it before the autoloads exist)
	return main.get_node_or_null("SkaterBuilder")


func _run() -> void:
	await wait(40)
	await shot("01_start_screen")
	await key(KEY_C)
	await wait(30)
	await shot("02_builder_open")
	await key(KEY_RIGHT)            # body: female
	await wait(40)
	await shot("03_female")
	for step in [["top", 1], ["bottom", 1], ["shoes", 2], ["hat", 2]]:
		await key(KEY_DOWN)
		for i in step[1]:
			await key(KEY_RIGHT)
		await wait(30)
		await shot("04_female_%s" % step[0])
	await key(KEY_E)
	for i in 40:
		Input.action_press("spin_right")
		await process_frame
	Input.action_release("spin_right")
	await wait(5)
	await shot("05_female_turned")
	await key(KEY_ENTER)
	await wait(30)
	await shot("06_start_after_done")
	print("[builder_shots] saved choice: ", SkaterOutfit.to_arg(SkaterOutfit.load_saved()), " live skater: ", SkaterOutfit.to_arg(main.skater.model.choice))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SkaterOutfit.save_path))
	quit()
