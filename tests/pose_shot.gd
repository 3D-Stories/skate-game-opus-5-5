extends SceneTree
## Close-up GPU renders of one skater pose, for looking at a clip frame by frame (clothing,
## deformation): the model built from --skater, posed at --clip / --t (several times with
## --t=0.1,0.2,... or --tf=0,0.5,1 as fractions of the clip; --clip=rest: the bind pose, --clip=all: every clip),
## framed on --bone from --views azimuths (degrees), studio-lit like
## tests/skater_snapshot.gd. Needs a real renderer (no --headless):
##   godot --path . --resolution 900x900 -s tests/pose_shot.gd -- --skater=female,tee,cargo,hitop,cap
##       --clip=shoveit --t=0.6 --bone=thigh_l --dist=1.2 --views=0,90,180,270 --out=/tmp/shots

var out := "/tmp/pose_shot"
var skater_arg := ""
var clip := "idle"
var times: PackedFloat32Array = [0.0]
var fracs: PackedFloat32Array = []   # --tf=0,0.25,...: times as fractions of each clip's length
var bone := "pelvis"
var dist := 1.4
var views: PackedFloat32Array = [0.0, 90.0, 180.0, 270.0]
var model: Node3D
var no_nmap := false               # (--no-normal-maps: garments without their normal maps, for comparison)
var cam: Camera3D


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var k := a.get_slice("=", 0)
		var v := a.get_slice("=", 1)
		match k:
			"--out": out = v
			"--skater": skater_arg = v
			"--clip": clip = v
			"--no-normal-maps": no_nmap = true
			"--bone": bone = v
			"--dist": dist = float(v)
			"--t":
				times = PackedFloat32Array(Array(v.split(",")).map(func(x): return float(x)))
			"--tf":
				fracs = PackedFloat32Array(Array(v.split(",")).map(func(x): return float(x)))
			"--views":
				views = PackedFloat32Array(Array(v.split(",")).map(func(x): return float(x)))
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
	key.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	key.directional_shadow_max_distance = 6.0      # close-ups: a fine shadow map
	world.add_child(key)
	key.look_at_from_position(Vector3(-2, 3, 3), Vector3.ZERO, Vector3.UP)
	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.6
	fill.light_color = Color(0.8, 0.88, 1.0)
	world.add_child(fill)
	fill.look_at_from_position(Vector3(3, 1.5, -2), Vector3.ZERO, Vector3.UP)
	cam = Camera3D.new()
	cam.fov = 30.0
	cam.near = 0.02
	world.add_child(cam)
	cam.current = true
	model = load("res://scripts/skater/skater_model.gd").new()
	if skater_arg != "":
		model.set("outfit", SkaterOutfit.parse(skater_arg))
	world.add_child(model)
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame
	var anim: AnimationPlayer = model.anim
	var sk: Skeleton3D = model.skeleton
	if no_nmap:
		for mi in model.find_children("*", "MeshInstance3D", true, false):
			for s in mi.mesh.get_surface_count():
				var m = mi.get_surface_override_material(s)
				if m == null:
					m = mi.mesh.surface_get_material(s)
				if m is StandardMaterial3D:
					m = m.duplicate()
					m.normal_enabled = false
					mi.set_surface_override_material(s, m)
	var clips: Array = [clip]
	if clip == "all":              # (--clip=all: every clip, one after another)
		clips = Array(anim.get_animation_list())
		clips.erase("RESET")
	for c in clips:
		await shoot(anim, sk, c)
	quit()


func shoot(anim: AnimationPlayer, sk: Skeleton3D, c: String) -> void:
	if c != "rest":                # (--clip=rest: the bind pose, no clip)
		anim.play(c)
	var ts := times
	if not fracs.is_empty() and c != "rest":
		ts = PackedFloat32Array()
		for f in fracs:
			ts.append(f * anim.get_animation(c).length)
	for t in ts:
		if c == "rest":
			sk.reset_bone_poses()
		else:
			anim.seek(t, true)
			anim.pause()
		await process_frame
		var target: Vector3 = sk.global_transform * sk.get_bone_global_pose(sk.find_bone(bone)).origin
		for v in views:
			var a := deg_to_rad(v)
			cam.global_position = target + Vector3(sin(a), 0.15, cos(a)) * dist
			cam.look_at(target)
			for i in 3:
				await process_frame
			await RenderingServer.frame_post_draw
			var img := root.get_viewport().get_texture().get_image()
			var name := "%s_%s_%.2f_%s_%03d.png" % [skater_arg.replace(",", "-") if skater_arg != "" else "default", c, t, bone, int(v)]
			img.save_png(out.path_join(name))
			print("[pose_shot] ", out.path_join(name))
