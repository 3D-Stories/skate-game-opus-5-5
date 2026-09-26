extends SceneTree
## The level select (start screen), with the keyboard and a gamepad, on the real main scene:
##  * the game starts on the default level (the Warehouse) and the start screen names it and
##    offers the level select
##  * Tab opens it: one card per registered level with that level's goals; the current and
##    the default level are tagged
##  * Right + Enter switches to Eastside Baths: it loads (the Warehouse is freed), the start
##    screen names it, the HUD has its goals, Enter starts a run at its spawn
##  * the gamepad's Select opens it again; the left stick and the D-pad move the selection;
##    B and Esc close it without a change; D-pad left + A switch back to the Warehouse, which
##    loads exactly as at startup (data, grind lines, windows, spawn, goals)
##   godot --headless --path . --fixed-fps 60 -s tests/test_level_select.gd   -> tests/results/level_select.txt

const LS_SCRIPT := "res://scripts/ui/level_select.gd"

var main: Node
var out: PackedStringArray = []
var passed := 0
var failed := 0


func check(ok: bool, what: String, detail := "") -> void:
	if ok:
		passed += 1
		out.append("PASS  " + what + ("  [" + detail + "]" if detail != "" else ""))
	else:
		failed += 1
		out.append("FAIL  " + what + ("  (" + detail + ")" if detail != "" else ""))


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
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


func stick_x(v: float) -> void:
	var m := InputEventJoypadMotion.new()
	m.device = 0
	m.axis = JOY_AXIS_LEFT_X
	m.axis_value = v
	Input.parse_input_event(m)


func screen() -> Node:
	for n in main.get_children():
		if n.get_script() and n.get_script().resource_path == LS_SCRIPT:
			return n
	return null


func menu_text() -> String:
	var t := ""
	for l in main.menus.find_children("*", "", true, false):
		if l is Label and l.is_visible_in_tree():
			t += (l as Label).text + "\n"
		elif l is RichTextLabel and l.is_visible_in_tree():
			t += (l as RichTextLabel).get_parsed_text() + "\n"
	return t


func level_state() -> Dictionary:
	var lv = main.level
	return {"id": lv.level_id, "data": JSON.stringify(lv.data).hash(), "rails": lv.rails.map(func(r): return r.name),
			"windows": lv.windows.size(), "spawn": lv.spawn_pos, "goals": main.goals.map(func(g): return g["id"]),
			"meshes": lv._meshes(lv.park).size()}


func wait_loaded(id: String, n := 600) -> bool:
	for i in n:
		await process_frame
		if main.level.level_id == id and not main.switching and screen() == null:
			return true
	return false


func _run() -> void:
	await frames(20)
	var ids := LevelRegistry.ids()
	check(ids.size() >= 2 and ids[0] == "warehouse" and LevelRegistry.default_id() == "warehouse",
			"levels come from levels/registry.json; the Warehouse is the default", str(ids))
	var wh := level_state()
	check(wh["id"] == "warehouse" and main.menus.mode == main.menus.START, "the game starts on the Warehouse, at the start screen",
			"%d grind lines, %d windows, goals %s" % [wh["rails"].size(), wh["windows"], str(wh["goals"])])
	var t := menu_text()
	check("WAREHOUSE" in t.to_upper() and "LEVEL" in t.to_upper(), "the start screen names the level and offers the level select",
			t.replace("\n", " | ").substr(0, 90) + " ... " + t.replace("\n", " | ").right(110))
	# --- keyboard: Tab opens it
	await tap_key(KEY_TAB)
	await frames(10)
	var ls := screen()
	check(ls != null and ls.cards.size() == ids.size() and ls.idx == 0, "keyboard: Tab opens the level select, one card per level, on the current one",
			"%d cards, selected %s" % [ls.cards.size() if ls else 0, ls.ids[ls.idx] if ls else "-"])
	if ls == null:
		_finish()
		return
	var missing: Array = []
	for i in ls.cards.size():
		var txt := ""
		for n in (ls.cards[i] as Node).find_children("*", "RichTextLabel", true, false):
			txt += n.text
		for gd in LevelRegistry.game(String(ls.ids[i])).get("goals", []):
			if not (ls.goal_title(gd) in txt):
				missing.append("%s: %s" % [ls.ids[i], ls.goal_title(gd)])
	check(missing.is_empty(), "every card lists its level's goals", "all listed" if missing.is_empty() else str(missing))
	var tag0: String = (ls.cards[0].get_meta("tag") as Label).text
	check("PLAYING NOW" in tag0 and "DEFAULT" in tag0, "the current level's card is tagged PLAYING NOW and DEFAULT", tag0)
	await frames(20)
	await tap_key(KEY_RIGHT)
	check(ls.idx == 1 and ls.ids[1] == "baths", "keyboard: Right selects the next card (Eastside Baths)", "selected %s" % ls.ids[ls.idx])
	await tap_key(KEY_LEFT)
	check(ls.idx == 0, "keyboard: Left goes back", "selected %s" % ls.ids[ls.idx])
	await tap_key(KEY_RIGHT)
	await frames(10)
	await tap_key(KEY_ENTER)
	var ok := await wait_loaded("baths")
	var bs := level_state()
	check(ok and bs["id"] == "baths" and bs["goals"].size() == LevelRegistry.game("baths")["goals"].size(),
			"keyboard: Enter loads Eastside Baths (its goals on the HUD, the Warehouse freed)",
			"goals %s, %d grind lines, %d meshes (Warehouse %d)" % [str(bs["goals"]), bs["rails"].size(), bs["meshes"], wh["meshes"]])
	await frames(10)
	t = menu_text()
	check(main.menus.mode == main.menus.START and "EASTSIDE BATHS" in t.to_upper(), "back at the start screen, which names Eastside Baths",
			t.replace("\n", " | ").substr(0, 120))
	await frames(20)
	await tap_key(KEY_ENTER)
	await frames(10)
	check(main.running and main.skater.global_position.distance_to(main.level.spawn_pos) < 1.0,
			"Enter starts a run on Eastside Baths at its spawn", str(main.skater.global_position.snapped(Vector3.ONE * 0.01)))
	# back to the start screen: pause, restart would keep the run; the end screen's restart too.
	# The run is ended the way the clock does it.
	main.time_left = 0.05
	for i in 240:
		await process_frame
		if not main.running:
			break
	check(not main.running and main.menus.mode == main.menus.END, "the run ends at the buzzer (end screen)")
	await frames(90)
	await tap_key(KEY_ENTER)          # restart from the end screen: a new run on the same level
	await frames(10)
	check(main.running and main.level.level_id == "baths", "Enter on the end screen restarts on the same level")
	main.running = false
	main.get_tree().paused = true
	main._show_start()
	await frames(30)
	# --- gamepad: Select opens it, stick and D-pad move, B closes, A picks
	await tap_pad(JOY_BUTTON_BACK)
	await frames(10)
	ls = screen()
	check(ls != null and ls.ids[ls.idx] == "baths", "gamepad: Select opens the level select (on the current level)",
			ls.ids[ls.idx] if ls else "not open")
	if ls == null:
		_finish()
		return
	await frames(20)
	stick_x(-1.0)
	await frames(4)
	stick_x(0.0)
	await frames(12)
	check(ls.idx == 0, "gamepad: the left stick moves the selection", "selected %s" % ls.ids[ls.idx])
	await tap_pad(JOY_BUTTON_DPAD_RIGHT)
	check(ls.idx == 1, "gamepad: the D-pad moves the selection", "selected %s" % ls.ids[ls.idx])
	await tap_pad(JOY_BUTTON_B)
	await frames(10)
	check(screen() == null and main.level.level_id == "baths" and main.menus.mode == main.menus.START,
			"gamepad: B closes it without a change (still on Eastside Baths, start screen)")
	await frames(20)
	await tap_key(KEY_TAB)
	await frames(10)
	var opened := screen() != null
	await frames(20)
	await tap_key(KEY_ESCAPE)
	await frames(10)
	check(opened and screen() == null and main.level.level_id == "baths" and main.menus.mode == main.menus.START,
			"keyboard: Tab opens it again, Esc closes it without a change",
			"opened %s, open after Esc %s, level %s" % [str(opened), str(screen() != null), main.level.level_id])
	await frames(20)
	await tap_pad(JOY_BUTTON_BACK)
	await frames(30)
	ls = screen()
	if ls:
		await tap_pad(JOY_BUTTON_DPAD_LEFT)
		await frames(10)
		await tap_pad(JOY_BUTTON_A)
	ok = await wait_loaded("warehouse")
	var wh2 := level_state()
	check(ok and wh2 == wh, "gamepad: D-pad left + A switch back; the Warehouse loads exactly as at startup",
			"data, %d grind lines, %d windows, spawn, goals %s" % [wh2["rails"].size(), wh2["windows"], str(wh2["goals"])] if wh2 == wh else
			"differs: %s vs %s" % [str(wh2).substr(0, 200), str(wh).substr(0, 200)])
	_finish()


func _finish() -> void:
	var report := "Pro Skater level select tests  %s\n%s\n%d passed, %d failed\n" % [
			Time.get_datetime_string_from_system(), "\n".join(out), passed, failed]
	print(report)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/results"))
	var f := FileAccess.open("res://tests/results/level_select.txt", FileAccess.WRITE)
	f.store_string(report)
	f.close()
	quit(1 if failed > 0 else 0)
