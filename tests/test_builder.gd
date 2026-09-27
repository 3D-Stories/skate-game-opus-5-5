extends SceneTree
## Character builder, headless, on the real main scene with injected keyboard and gamepad
## events:
##  * the default choice is today's skater: the same fingerprint (tests/lib/skater_fp.gd)
##    as the original game's (tests/data/skater_baseline.json, recorded before any builder
##    change) - every visible triangle, UV, normal, texture, the skeleton and all 25 clips -
##    except the skin weights of the four garment pieces the fit pass re-weights (hoodie,
##    hood roll, hood back, jeans), whose shape, UVs and normals are still compared
##    (tests/data/skater_baseline_weightless.json, recorded on the same original commit)
##  * every body x top x bottom x shoes x headwear combination builds
##  * the choice saves to and loads from user:// (a file of its own here), bad values fall back
##  * keyboard: C opens the Skater screen, the arrows change the body and every slot live,
##    Enter saves and the skater is rebuilt; gamepad: Y, the D-pad and the left stick, B leaves
##    without saving, Back resets to the default, A saves
##  * the saved choice skates the run, shows on the end screen and in the replay, and comes
##    back on the next launch
##   godot --headless --path . --fixed-fps 60 -s tests/test_builder.gd   -> tests/results/builder.txt

const FP := preload("res://tests/lib/skater_fp.gd")
const REFIT := ["Hoodie", "Hood_hood_back", "Hood_hood_roll", "Jeans"]
const CFG := "user://test_builder_skater.cfg"

var main: Node
var out: PackedStringArray = []
var passed := 0
var failed := 0


func check(ok: bool, what: String, detail := "") -> void:
	if ok:
		passed += 1
		out.append("PASS  " + what)
	else:
		failed += 1
		out.append("FAIL  " + what + ("  (" + detail + ")" if detail != "" else ""))


func _initialize() -> void:
	SkaterOutfit.save_path = CFG
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CFG))
	_run.call_deferred()


func frames(n: int) -> void:
	for i in n:
		await process_frame


func key(k: Key, down: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = k
	e.physical_keycode = k
	e.pressed = down
	Input.parse_input_event(e)


func tap_key(k: Key) -> void:
	key(k, true)
	await frames(2)
	key(k, false)
	await frames(3)


func pad(b: JoyButton, down: bool) -> void:
	var e := InputEventJoypadButton.new()
	e.device = 0
	e.button_index = b
	e.pressed = down
	Input.parse_input_event(e)


func tap_pad(b: JoyButton) -> void:
	pad(b, true)
	await frames(2)
	pad(b, false)
	await frames(3)


func stick(axis: JoyAxis, v: float) -> void:
	var e := InputEventJoypadMotion.new()
	e.device = 0
	e.axis = axis
	e.axis_value = v
	Input.parse_input_event(e)
	await frames(2)
	e = e.duplicate()
	e.axis_value = 0.0
	Input.parse_input_event(e)
	await frames(3)


func builder() -> Node:
	# (by name: naming the class here would compile it before the autoloads exist)
	return main.get_node_or_null("SkaterBuilder") if main else null


func arg(c: Dictionary) -> String:
	return SkaterOutfit.to_arg(c)


func launch() -> void:
	if main:
		main.queue_free()
		await frames(2)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await frames(40)


func _run() -> void:
	await default_is_today()
	await every_combination()
	persistence()
	SkaterOutfit.use_saved_in_tests = true
	await launch()
	check(main.menus.mode == main.menus.START and arg(main.skater.model.choice) == arg(SkaterOutfit.default_choice()),
			"first launch (nothing saved): the start screen, with today's skater", arg(main.skater.model.choice))
	check(main.menus.hint.text.contains("SKATER") and main.menus.hint.text.contains("C") and main.menus.hint.text.contains("Y"),
			"the start screen names the Skater screen's key and button", main.menus.hint.text)
	await keyboard_path()
	await gamepad_path()
	await run_end_replay()
	# the next launch starts from the saved choice
	var saved := SkaterOutfit.load_saved()
	await launch()
	check(arg(main.skater.model.choice) == arg(saved) and saved["body"] == "female",
			"the next launch restores the saved skater (%s)" % arg(saved), arg(main.skater.model.choice))
	main.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CFG))
	var report := "Pro Skater character builder tests  %s\n%s\n%d passed, %d failed\n" % [
			Time.get_datetime_string_from_system(), "\n".join(out), passed, failed]
	print(report)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/results"))
	var f := FileAccess.open("res://tests/results/builder.txt", FileAccess.WRITE)
	f.store_string(report)
	f.close()
	quit(1 if failed > 0 else 0)


# ------------------------------------------------------------------ the default is today's skater

func fingerprint_default(weightless: Array) -> Dictionary:
	## The default skater's fingerprint made exactly as the baseline was (the same tool, in
	## its own process, no fixed fps: the board rides an animated bone, so the first frame's
	## time step moves it).
	var path := "user://test_builder_fp.json"
	var args := ["--headless", "--path", ProjectSettings.globalize_path("res://"), "-s", "res://tests/skater_fingerprint.gd", "--",
			"--out=" + ProjectSettings.globalize_path(path)]
	if not weightless.is_empty():
		args.append("--weightless=" + ",".join(PackedStringArray(weightless)))
	var log: Array = []
	OS.execute(OS.get_executable_path(), args, log, true)
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	return d if d is Dictionary else {}


func default_is_today() -> void:
	var model: Node3D = load("res://scripts/skater/skater_model.gd").new()
	root.add_child(model)
	await frames(1)
	check(arg(model.choice) == "male,hoodie,jeans,suede,none" and SkaterOutfit.is_default(model.choice),
			"with nothing chosen the game builds the default: male, red hoodie, blue jeans, grey suede low-tops, no hat", arg(model.choice))
	model.queue_free()
	await frames(2)
	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/data/skater_baseline.json"))
	var base_w: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/data/skater_baseline_weightless.json"))
	var now := fingerprint_default([])
	var now_w := fingerprint_default(REFIT)
	if now.is_empty() or now_w.is_empty():
		check(false, "default = today's skater: fingerprint made (tests/skater_fingerprint.gd)")
		return
	var tris := 0
	for m in now["materials"]:
		tris += int(now["materials"][m]["triangles"])
	var d_all := FP.diff(base, now)
	var d_other := Array(d_all).filter(func(l): return not REFIT.any(func(r): return l.begins_with("material %s:" % r)))
	check(d_other.is_empty(), "default = today's skater: every other material (skin, face, eyes, hair, shoes, cords, board) identical triangle for triangle - positions, UVs, weights, normals, textures (%d visible triangles, %d materials)" % [tris, now["materials"].size()],
			"; ".join(PackedStringArray(d_other.slice(0, 5))))
	var d_w := Array(FP.diff(base_w, now_w)).filter(func(l): return REFIT.any(func(r): return l.begins_with("material %s:" % r)))
	check(d_w.is_empty(), "default = today's skater: hoodie, hood and jeans identical in shape, UVs, normals and textures (their skin weights are re-fitted, see README)",
			"; ".join(PackedStringArray(d_w.slice(0, 5))))
	var refit_changed := Array(d_all).filter(func(l): return REFIT.any(func(r): return l.begins_with("material %s:" % r)))
	out.append("INFO  re-fitted weights: %s" % ("; ".join(PackedStringArray(refit_changed)) if not refit_changed.is_empty() else "unchanged"))
	check(now["skeleton"] == base["skeleton"] and now["bone_count"] == base["bone_count"], "default = today's skater: the same skeleton (%d bones, rest pose)" % now["bone_count"])
	var same_clips := 0
	for c in base["animations"]:
		if now["animations"].has(c) and JSON.stringify(now["animations"][c]) == JSON.stringify(base["animations"][c]):
			same_clips += 1
	check(same_clips == base["animations"].size() and now["animations"].size() == base["animations"].size(),
			"default = today's skater: all %d clips key for key (%d identical)" % [base["animations"].size(), same_clips])


# ------------------------------------------------------------------ every combination builds

func every_combination() -> void:
	var n := 0
	var bad: PackedStringArray = []
	var slow := 0.0
	for body in SkaterOutfit.options("body"):
		for top in SkaterOutfit.options("top"):
			for bottom in SkaterOutfit.options("bottom"):
				for shoes in SkaterOutfit.options("shoes"):
					for hat in SkaterOutfit.options("hat"):
						var c := {"body": body, "top": top, "bottom": bottom, "shoes": shoes, "hat": hat}
						var t := Time.get_ticks_usec()
						var model: Node3D = load("res://scripts/skater/skater_model.gd").new()
						model.outfit = c
						root.add_child(model)
						slow = maxf(slow, (Time.get_ticks_usec() - t) / 1000.0)
						var why := combo_problems(model, c)
						if why != "":
							bad.append(arg(c) + ": " + why)
						n += 1
						model.free()
	check(bad.is_empty() and n == 162, "every body x top x bottom x shoes x headwear combination builds: its garments on the body's skeleton, textured, skin and hair hidden under them, 25 clips, the ragdoll (%d combinations, slowest %.0f ms)" % [n, slow],
			"; ".join(bad.slice(0, 6)))
	check(SkaterOutfit.options("top").size() >= 3 and SkaterOutfit.options("bottom").size() >= 3 and SkaterOutfit.options("shoes").size() >= 3
			and SkaterOutfit.options("hat").size() >= 2 and "none" in SkaterOutfit.options("hat"),
			"the wardrobe: %d tops, %d bottoms, %d shoes, headwear %s" % [SkaterOutfit.options("top").size(), SkaterOutfit.options("bottom").size(),
			SkaterOutfit.options("shoes").size(), str(SkaterOutfit.options("hat"))])


func combo_problems(model, c: Dictionary) -> String:
	var p: PackedStringArray = []
	if model.choice != SkaterOutfit.normalized(c):
		p.append("built %s" % arg(model.choice))
	for g in SkaterOutfit.worn_garments(c):
		var list: Array = model.garments.get(g, [])
		if list.is_empty():
			p.append("no meshes for " + g)
		for mi: MeshInstance3D in list:
			if mi.skin == null or mi.get_node_or_null(mi.skeleton) != model.skeleton:
				p.append("%s/%s not skinned to the skeleton" % [g, mi.name])
			for s in mi.mesh.get_surface_count():
				var m := mi.get_surface_override_material(s)
				if m == null:
					m = mi.mesh.surface_get_material(s)
				if m == null:
					p.append("%s/%s surface %d has no material" % [g, mi.name, s])
				elif m is StandardMaterial3D and String(m.resource_name) in model.FABRICS and (m as StandardMaterial3D).albedo_texture == null:
					p.append("%s/%s: %s has no texture" % [g, mi.name, m.resource_name])
	if model.skin_materials.is_empty() or int(model.skin_materials[0].get_shader_parameter("hidden_mask")) != SkaterOutfit.body_mask(c):
		p.append("skin mask")
	if model.hair_materials.is_empty() or int(model.hair_materials[0].get_shader_parameter("hidden_mask")) != SkaterOutfit.hat_mask(c):
		p.append("hair mask")
	if model.anim.get_animation_list().size() != 25:
		p.append("%d clips" % model.anim.get_animation_list().size())
	if model.rag.size() != 14:
		p.append("%d ragdoll bodies" % model.rag.size())
	return ", ".join(p)


# ------------------------------------------------------------------ saving

func persistence() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CFG))
	check(arg(SkaterOutfit.load_saved()) == arg(SkaterOutfit.default_choice()), "nothing saved: the default skater")
	var c := {"body": "female", "top": "flannel", "bottom": "cargo", "shoes": "suede_navy", "hat": "cap"}
	SkaterOutfit.save(c)
	var cf := ConfigFile.new()
	var ok := cf.load(CFG) == OK
	check(ok and cf.get_value("skater", "body", "") == "female" and cf.get_value("skater", "hat", "") == "cap",
			"the choice is written to user:// (%s)" % ProjectSettings.globalize_path(CFG))
	check(arg(SkaterOutfit.load_saved()) == arg(c), "and read back", arg(SkaterOutfit.load_saved()))
	cf.set_value("skater", "top", "tuxedo")
	cf.set_value("skater", "body", 42)
	cf.save(CFG)
	var l := SkaterOutfit.load_saved()
	check(l["top"] == "hoodie" and l["body"] == "male" and l["bottom"] == "cargo",
			"unknown saved values fall back to the default for that slot only", arg(l))
	var f := FileAccess.open(CFG, FileAccess.WRITE)
	f.store_string("not a config file [[[")
	f.close()
	check(arg(SkaterOutfit.load_saved()) == arg(SkaterOutfit.default_choice()), "a broken file gives the default skater")
	check(arg(SkaterOutfit.parse("female,tee,,hitop")) == "female,tee,jeans,hitop,none" and arg(SkaterOutfit.parse("default")) == arg(SkaterOutfit.default_choice()),
			"--skater= / ?skater= parse (missing slots default)", arg(SkaterOutfit.parse("female,tee,,hitop")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CFG))


# ------------------------------------------------------------------ the Skater screen by keyboard

func keyboard_path() -> void:
	await tap_key(KEY_C)
	await frames(20)                              # (a new screen ignores input for a moment)
	var b := builder()
	check(b != null and main.menus.mode == main.menus.NONE and b.get_node("Backdrop").visible,
			"keyboard: C on the start screen opens the Skater screen")
	if b == null:
		return
	var grid: GridContainer = b.find_child("Controls", true, false)
	var txt := ""
	for l in grid.get_children():
		txt += (l as Label).text + " | "
	check(txt.contains("KEYBOARD") and txt.contains("GAMEPAD") and txt.contains("Enter") and txt.contains("Esc") and txt.contains("D-pad"),
			"the Skater screen lists its keyboard and gamepad controls", txt.substr(0, 200))
	check(b.preview.model != null and arg(b.preview.model.choice) == arg(SkaterOutfit.default_choice()), "its turntable shows the current skater")
	var want := {"body": "female", "top": "tee", "bottom": "shorts", "shoes": "hitop", "hat": "beanie"}
	await tap_key(KEY_RIGHT)                      # body: female
	await frames(3)
	check(b.choice["body"] == "female" and b.preview.model.choice["body"] == "female" and b.slot_text(0).contains("Female"),
			"Right changes the body, and the turntable shows her at once", b.slot_text(0))
	await tap_key(KEY_S)                          # top (WASD works too)
	await tap_key(KEY_D)                          # tee
	await tap_key(KEY_DOWN)                       # bottom
	await tap_key(KEY_RIGHT)
	await tap_key(KEY_RIGHT)                      # shorts
	await tap_key(KEY_DOWN)                       # shoes
	await tap_key(KEY_LEFT)                       # suede -> (wraps) hitop
	await tap_key(KEY_DOWN)                       # hat
	await tap_key(KEY_RIGHT)                      # beanie
	await frames(3)
	check(arg(b.choice) == arg(want) and arg(b.preview.model.choice) == arg(want),
			"W/A/S/D and the arrows pick every slot, live on the turntable (%s)" % arg(want), arg(b.choice))
	var shorts_socks: bool = b.preview.model.garments.has("socks_high")
	check(shorts_socks, "shorts with hi-tops show the socks made for hi-tops")
	var angle0: float = b.preview.angle
	key(KEY_E, true)
	await frames(20)
	key(KEY_E, false)
	await frames(2)
	check(absf(b.preview.angle - angle0) > 0.5, "E turns the turntable", "%.2f -> %.2f" % [angle0, b.preview.angle])
	await tap_key(KEY_ENTER)
	await frames(8)
	check(builder() == null and main.menus.mode == main.menus.START, "Enter closes the Skater screen, back on the start screen")
	check(arg(SkaterOutfit.load_saved()) == arg(want), "Enter saved the choice to user://", arg(SkaterOutfit.load_saved()))
	check(arg(main.skater.model.choice) == arg(want) and main.skater.model.garments.has("beanie") and main.skater.model.garments.has("tee"),
			"and the skater on the start line is rebuilt as her", arg(main.skater.model.choice))


# ------------------------------------------------------------------ ... and by gamepad

func gamepad_path() -> void:
	var before := arg(main.skater.model.choice)
	await frames(30)
	await tap_pad(JOY_BUTTON_Y)
	await frames(20)
	var b := builder()
	check(b != null, "gamepad: Y on the start screen opens the Skater screen")
	if b == null:
		return
	await tap_pad(JOY_BUTTON_DPAD_RIGHT)          # body: male
	await tap_pad(JOY_BUTTON_DPAD_DOWN)
	await stick(JOY_AXIS_LEFT_X, 1.0)             # top: flannel (left stick)
	await frames(3)
	check(b.choice["body"] == "male" and b.choice["top"] == "flannel" and b.preview.model.choice["top"] == "flannel",
			"the D-pad and the left stick change slots live", arg(b.choice))
	var ang: float = b.preview.angle
	pad(JOY_BUTTON_RIGHT_SHOULDER, true)
	await frames(20)
	pad(JOY_BUTTON_RIGHT_SHOULDER, false)
	await frames(2)
	check(absf(b.preview.angle - ang) > 0.5, "RB turns the turntable")
	await tap_pad(JOY_BUTTON_B)
	await frames(8)
	check(builder() == null and arg(main.skater.model.choice) == before and arg(SkaterOutfit.load_saved()) == before,
			"B leaves without saving: the skater and the saved choice are as they were", arg(main.skater.model.choice))
	await frames(30)
	await tap_pad(JOY_BUTTON_Y)
	await frames(20)
	b = builder()
	await tap_pad(JOY_BUTTON_BACK)
	await frames(3)
	check(b != null and arg(b.choice) == arg(SkaterOutfit.default_choice()), "Back resets every slot to today's skater", arg(b.choice) if b else "")
	await tap_pad(JOY_BUTTON_A)
	await frames(8)
	check(arg(main.skater.model.choice) == arg(SkaterOutfit.default_choice()) and arg(SkaterOutfit.load_saved()) == arg(SkaterOutfit.default_choice()),
			"A saves it: today's skater again", arg(main.skater.model.choice))
	# the female skater for the run
	await frames(30)
	await tap_pad(JOY_BUTTON_Y)
	await frames(20)
	await tap_pad(JOY_BUTTON_DPAD_RIGHT)          # female
	await tap_pad(JOY_BUTTON_DPAD_DOWN)
	await tap_pad(JOY_BUTTON_DPAD_RIGHT)          # tee
	await tap_pad(JOY_BUTTON_DPAD_DOWN)
	await tap_pad(JOY_BUTTON_DPAD_RIGHT)          # cargo
	await tap_pad(JOY_BUTTON_DPAD_DOWN)
	await tap_pad(JOY_BUTTON_DPAD_RIGHT)          # navy suede
	await tap_pad(JOY_BUTTON_DPAD_DOWN)
	await tap_pad(JOY_BUTTON_DPAD_LEFT)           # cap
	await tap_pad(JOY_BUTTON_A)
	await frames(8)
	check(arg(main.skater.model.choice) == "female,tee,cargo,suede_navy,cap", "the gamepad picks her outfit and saves it", arg(main.skater.model.choice))


# ------------------------------------------------------------------ the run, the end screen, the replay

func run_end_replay() -> void:
	var want := arg(main.skater.model.choice)
	await frames(30)
	await tap_key(KEY_ENTER)
	await frames(5)
	check(main.running and not paused, "Enter starts the run")
	var sk = main.skater
	var p0: Vector3 = sk.global_position
	key(KEY_W, true)
	await frames(150)
	key(KEY_W, false)
	await tap_key(KEY_SPACE)
	await frames(90)
	var moved: float = sk.global_position.distance_to(p0)
	check(arg(sk.model.choice) == want and sk.model.anim.is_playing() and moved > 2.0 and sk.model.played.size() >= 2,
			"the run is skated by the chosen skater (%s): pushed %.1f m, clips %s" % [want, moved, str(sk.model.played.keys())])
	main.time_left = 0.3
	await frames(60)
	var m = main.menus
	check(paused and m.mode == m.END, "the run ends on the end-of-run screen")
	check(m.end_skater != null and m.end_skater.visible and arg(m.end_skater.choice) == want and m.end_skater_label.text.contains("FEMALE"),
			"the end screen shows the run's skater on a turntable: %s" % (m.end_skater_label.text.replace("\n", ", ") if m.end_skater_label else ""))
	check(m.hint.text.contains("REPLAY"), "the end screen offers the replay", m.hint.text)
	var rp = main.replay
	check(rp.count > 200, "the replay recorded the run (%d frames)" % rp.count)
	await frames(70)
	await tap_key(KEY_V)
	await frames(3)
	check(rp.playing and rp.ghost != null and arg(rp.ghost.choice) == want and not sk.model.visible and m.mode == m.NONE,
			"V plays the replay with the same skater (%s)" % (arg(rp.ghost.choice) if rp.ghost else "none"))
	if rp.ghost:
		var hb: int = rp.ghost.skeleton.find_bone("hand_l")
		var h0: Vector3 = rp.ghost.skeleton.get_bone_global_pose(hb).origin
		var g0: Vector3 = rp.ghost.skeleton.global_position
		await frames(60)
		var h1: Vector3 = rp.ghost.skeleton.get_bone_global_pose(hb).origin if rp.ghost else h0
		var g1: Vector3 = rp.ghost.skeleton.global_position if rp.ghost else g0
		check(h0.distance_to(h1) > 0.01 or g0.distance_to(g1) > 0.3, "the replayed skater moves as recorded (hand %.2f m, body %.2f m in a second)" % [h0.distance_to(h1), g0.distance_to(g1)])
	await tap_pad(JOY_BUTTON_A)
	await frames(5)
	check(not rp.playing and rp.ghost == null and sk.model.visible and m.mode == m.END, "A ends the replay, back on the end screen")
	await frames(70)
	await tap_pad(JOY_BUTTON_X)
	await frames(3)
	check(rp.playing, "gamepad X plays the replay too")
	await frames(int((rp.SECONDS + 1.0) * 60))
	check(not rp.playing and m.mode == m.END, "the replay runs its %d seconds and returns to the end screen" % int(rp.SECONDS))
