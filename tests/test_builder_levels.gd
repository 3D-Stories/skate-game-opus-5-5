extends SceneTree
## The Skater screen (character builder) and the level select together, headless, on the
## real main scene with injected keyboard and gamepad events:
##  * the start screen offers both: Tab / Select for the level select, C / Y for the Skater screen
##  * neither screen's keys reach the other (Tab, or Select / Back = "default skater", inside
##    the Skater screen do not open the level select)
##  * the saved skater survives a level switch and stands at the new level's spawn; the Skater
##    screen works on Eastside Baths and rebuilds the skater there
##  * a run on Eastside Baths is skated by the chosen skater; its end screen and replay show her
##  * the next launch starts on the Warehouse with the saved skater
##   godot --headless --path . --fixed-fps 60 -s tests/test_builder_levels.gd   -> tests/results/builder_levels.txt

const CFG := "user://test_builder_levels.cfg"
const LS_SCRIPT := "res://scripts/ui/level_select.gd"

var main: Node
var out: PackedStringArray = []
var passed := 0
var failed := 0


func check(ok: bool, what: String, detail := "") -> void:
	if ok:
		passed += 1
		out.append("PASS  " + what + ("  (" + detail + ")" if detail != "" else ""))
	else:
		failed += 1
		out.append("FAIL  " + what + ("  (" + detail + ")" if detail != "" else ""))


func _initialize() -> void:
	SkaterOutfit.save_path = CFG
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CFG))
	SkaterOutfit.use_saved_in_tests = true
	_run.call_deferred()


func item_text(id: String) -> String:
	## A start screen choice's name, the line under it and its shortcut.
	for it in main.menus.items:
		if it["id"] == id:
			var t := ""
			for l in (it["node"] as Node).find_children("*", "Label", true, false):
				t += (l as Label).text + " | "
			return t
	return ""

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
	await frames(3)
	key(k, false)
	await frames(12)      # (the level select ignores a new move for 0.12 s)


func tap_pad(b: JoyButton) -> void:
	var e := InputEventJoypadButton.new()
	e.device = 0
	e.button_index = b
	e.pressed = true
	Input.parse_input_event(e)
	await frames(3)
	e = InputEventJoypadButton.new()
	e.device = 0
	e.button_index = b
	e.pressed = false
	Input.parse_input_event(e)
	await frames(12)


func builder() -> Node:
	return main.get_node_or_null("SkaterBuilder") if main else null


func level_select() -> Node:
	for n in main.get_children():
		if n.get_script() and n.get_script().resource_path == LS_SCRIPT:
			return n
	return null


func arg(c: Dictionary) -> String:
	return SkaterOutfit.to_arg(c)


func wait_loaded(id: String, n := 600) -> bool:
	for i in n:
		await process_frame
		if main.level.level_id == id and not main.switching and level_select() == null:
			return true
	return false


func at_spawn() -> float:
	return main.skater.global_position.distance_to(main.level.spawn_pos)


func launch() -> void:
	if main:
		main.queue_free()
		await frames(2)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await frames(40)


func _run() -> void:
	await launch()
	var m = main.menus
	var lv_item := item_text("level")
	var sk_item := item_text("skater")
	check(m.mode == m.START and lv_item.contains("LEVEL SELECT") and lv_item.contains("TAB / SELECT") and sk_item.contains("CUSTOMIZE CHARACTER") and sk_item.contains("C / Y"),
			"the start screen's menu offers both the level select (Tab / Select) and the character builder (C / Y)",
			"%s%s" % [lv_item, sk_item])
	# --- the Skater screen on the Warehouse (keyboard); Tab inside it is not the level select
	await tap_key(KEY_C)
	await frames(20)
	var b := builder()
	check(b != null and m.mode == m.NONE, "keyboard: C opens the Skater screen")
	if b == null:
		_finish()
		return
	await tap_key(KEY_TAB)
	await frames(5)
	check(level_select() == null and builder() != null, "Tab inside the Skater screen does not open the level select")
	var want := {"body": "female", "top": "tee", "bottom": "cargo", "shoes": "suede", "hat": "none"}
	await tap_key(KEY_RIGHT)                      # body: female
	await tap_key(KEY_DOWN)
	await tap_key(KEY_RIGHT)                      # tee
	await tap_key(KEY_DOWN)
	await tap_key(KEY_RIGHT)                      # cargo
	await tap_key(KEY_ENTER)
	await frames(10)
	check(builder() == null and arg(main.skater.model.choice) == arg(want) and arg(SkaterOutfit.load_saved()) == arg(want),
			"Enter saves her and rebuilds the skater on the Warehouse", arg(main.skater.model.choice))
	# --- the level select: Eastside Baths
	await frames(30)
	await tap_key(KEY_TAB)
	await frames(10)
	var ls := level_select()
	check(ls != null and builder() == null, "Tab on the start screen opens the level select (not the Skater screen)")
	if ls == null:
		_finish()
		return
	await frames(20)
	await tap_key(KEY_RIGHT)
	await frames(10)
	await tap_key(KEY_ENTER)
	var ok := await wait_loaded("baths")
	await frames(10)
	check(ok and main.level.level_id == "baths", "Enter loads Eastside Baths")
	check(arg(main.skater.model.choice) == arg(want) and main.skater.model.garments.has("tee") and main.skater.model.garments.has("cargo"),
			"the saved skater survives the level switch", arg(main.skater.model.choice))
	check(at_spawn() < 1.0, "she stands at the Baths' spawn", "%.2f m from it" % at_spawn())
	check(m.mode == m.START and m.side.get_parsed_text().contains("EASTSIDE BATHS") and item_text("skater").contains("CUSTOMIZE CHARACTER"),
			"the Baths' start screen names the level and still offers the character builder", "%s | %s" % [m.side.get_parsed_text().get_slice("\n", 0), item_text("skater")])
	# --- the Skater screen on the Baths (gamepad); Select / Back inside it is "default skater"
	await frames(30)
	await tap_pad(JOY_BUTTON_Y)
	await frames(20)
	b = builder()
	check(b != null and level_select() == null, "gamepad: Y on the Baths' start screen opens the Skater screen")
	if b == null:
		_finish()
		return
	await tap_pad(JOY_BUTTON_BACK)
	await frames(5)
	check(builder() != null and level_select() == null and arg(b.choice) == arg(SkaterOutfit.default_choice()),
			"Select / Back inside the Skater screen resets to today's skater and does not open the level select", arg(b.choice))
	await tap_pad(JOY_BUTTON_B)
	await frames(10)
	check(builder() == null and arg(main.skater.model.choice) == arg(want) and arg(SkaterOutfit.load_saved()) == arg(want),
			"B leaves without saving: still her tee and cargo", arg(main.skater.model.choice))
	await frames(30)
	await tap_pad(JOY_BUTTON_Y)
	await frames(20)
	b = builder()
	if b == null:
		check(false, "gamepad: Y opens the Skater screen again")
		_finish()
		return
	for i in 4:
		await tap_pad(JOY_BUTTON_DPAD_DOWN)      # to the headwear row
	await tap_pad(JOY_BUTTON_DPAD_LEFT)          # none -> (wraps) cap
	await tap_pad(JOY_BUTTON_A)
	await frames(10)
	want["hat"] = "cap"
	check(builder() == null and arg(main.skater.model.choice) == arg(want) and main.skater.model.garments.has("cap"),
			"A saves her cap on the Baths and the skater is rebuilt", arg(main.skater.model.choice))
	check(main.level.level_id == "baths" and at_spawn() < 1.0, "rebuilt at the Baths' spawn, the level unchanged", "%.2f m" % at_spawn())
	# --- a run on the Baths, its end screen and replay
	await frames(30)
	await tap_key(KEY_ENTER)
	await frames(5)
	var sk = main.skater
	var p0: Vector3 = sk.global_position
	key(KEY_W, true)
	await frames(150)
	key(KEY_W, false)
	await tap_key(KEY_SPACE)
	await frames(90)
	var moved: float = sk.global_position.distance_to(p0)
	check(main.running and arg(sk.model.choice) == arg(want) and moved > 2.0 and sk.model.played.size() >= 2,
			"the Baths run is skated by her (%s)" % arg(want), "pushed %.1f m, clips %s" % [moved, str(sk.model.played.keys())])
	main.time_left = 0.3
	await frames(60)
	check(m.mode == m.END and m.end_skater != null and m.end_skater.visible and arg(m.end_skater.choice) == arg(want),
			"the Baths' end screen shows her on the turntable", m.end_skater_label.text.replace("\n", ", ") if m.end_skater_label else "")
	var rp = main.replay
	await frames(70)
	await tap_key(KEY_V)
	await frames(3)
	check(rp.playing and rp.ghost != null and arg(rp.ghost.choice) == arg(want), "V replays the Baths run with her")
	await frames(20)
	await tap_pad(JOY_BUTTON_A)
	await frames(5)
	check(not rp.playing and m.mode == m.END, "A ends the replay, back on the Baths' end screen")
	# --- the next launch: the Warehouse (the default level), with the saved skater
	await launch()
	check(main.level.level_id == "warehouse" and arg(main.skater.model.choice) == arg(want),
			"the next launch starts on the Warehouse with the saved skater", "%s, %s" % [main.level.level_id, arg(main.skater.model.choice)])
	_finish()


func _finish() -> void:
	if main:
		main.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CFG))
	var report := "Pro Skater: the Skater screen and the level select together  %s\n%s\n%d passed, %d failed\n" % [
			Time.get_datetime_string_from_system(), "\n".join(out), passed, failed]
	print(report)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/results"))
	var f := FileAccess.open("res://tests/results/builder_levels.txt", FileAccess.WRITE)
	f.store_string(report)
	f.close()
	quit(1 if failed > 0 else 0)
