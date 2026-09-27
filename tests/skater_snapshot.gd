extends SceneTree
## GPU snapshots of the skater in fixed poses and views, lit by a fixed studio rig: for
## pixel comparisons (the builder's default selection against the original skater) and for
## looking at bodies/outfits pose by pose. Needs a real renderer (no --headless):
##   godot --path . --resolution 640x800 -s tests/skater_snapshot.gd -- --out=/tmp/snap [--skater=female,tee,cargo,hitop,cap]
## Writes <out>/<clip>_<t>_<view>.png and <out>/index.json.

const POSES := [["idle", 0.0], ["ride", 0.25], ["crouch", 0.5], ["kickflip", 0.42], ["indy", 0.8], ["grind_5050", 0.3],
		["boardslide", 0.5], ["manual", 0.5], ["vert_air", 0.5], ["bail", 0.3], ["getup_front", 0.45], ["special", 0.5]]
const VIEWS := [0.0, 90.0, 180.0, 270.0]

var out := "/tmp/skater_snapshot"
var skater_arg := ""
var model: Node3D
var cam: Camera3D
var index := []


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.get_slice("=", 1)
		elif a.begins_with("--skater="):
			skater_arg = a.get_slice("=", 1)
	DirAccess.make_dir_recursive_absolute(out)
	var world := Node3D.new()
	root.add_child(world)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.16, 0.165, 0.18)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.42, 0.46, 0.54)
	e.ambient_light_energy = 0.75
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.environment = e
	world.add_child(env)
	var key := DirectionalLight3D.new()
	key.light_energy = 2.0
	key.light_color = Color(1, 0.94, 0.86)
	key.shadow_enabled = true
	world.add_child(key)
	key.look_at_from_position(Vector3(-2, 3, 3), Vector3.ZERO, Vector3.UP)
	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.6
	fill.light_color = Color(0.8, 0.88, 1.0)
	world.add_child(fill)
	fill.look_at_from_position(Vector3(3, 1.5, -2), Vector3.ZERO, Vector3.UP)
	cam = Camera3D.new()
	cam.fov = 32.0
	world.add_child(cam)
	cam.current = true
	model = load("res://scripts/skater/skater_model.gd").new()
	if skater_arg != "" and "outfit" in model:
		model.set("outfit", load("res://scripts/skater/skater_outfit.gd").parse(skater_arg))
	world.add_child(model)
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame
	var anim: AnimationPlayer = model.anim
	for p in POSES:
		if not anim.has_animation(p[0]):
			continue
		anim.play(p[0])
		anim.seek(anim.get_animation(p[0]).length * float(p[1]), true)
		anim.pause()
		for v in VIEWS:
			var a := deg_to_rad(float(v))
			var target := Vector3(0, 0.95, 0)
			cam.global_position = target + Vector3(sin(a), 0.12, cos(a)) * 4.2
			cam.look_at(target)
			for i in 3:
				await process_frame
			await RenderingServer.frame_post_draw
			var img := root.get_viewport().get_texture().get_image()
			var name := "%s_%03d_%03d.png" % [p[0], int(round(float(p[1]) * 100)), int(v)]
			img.save_png(out.path_join(name))
			index.append(name)
	var f := FileAccess.open(out.path_join("index.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"skater": skater_arg, "images": index}, " "))
	f.close()
	print("[snapshot] %d images -> %s" % [index.size(), out])
	quit()
