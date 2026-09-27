extends SceneTree
## The start screen menu and the saved game, on the real main scene, with the keyboard, a
## gamepad and the mouse (on a save file of the test's own, never a player's):
##  * with no save: Resume game is greyed out and skipped, Start new game is picked; the
##    menu lists Resume game, Start new game, Level select, Customize character, Controls
##    (no Quit outside the Windows build); the side shows the level and its goals
##  * Controls opens the keyboard / gamepad table and Esc comes back; the mouse points at and
##    clicks a choice; Level select and Customize character open their screens and come back
##    to the start screen on the play choice; Tab and C still work as shortcuts
##  * Start new game starts a run and the save exists; a goal done in a run is saved at once;
##    the pause menu's Main menu leaves the run; Resume game is then picked, names the goals
##    done, and its run has that goal ticked; the end screen's Main menu comes back too and
##    the run's score is the level's best
##  * Start new game with a save asks first: No keeps it, Yes clears it and starts a run
##  * after a relaunch the save is read back: Resume game is picked, the goals are ticked,
##    the game opens on the level played last; the level select's cards tick the saved goals
##  * scripted runs and plain test scripts never use the save
##   godot --headless --path . --fixed-fps 60 -s tests/test_menu.gd   -> tests/results/menu.txt

const SAVE := "user://test_menu_progress.cfg"
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
	Progress.save_path = SAVE
	check(not Progress.enabled(""), "a plain test script does not use the save (Progress.enabled is false)")
	Progress.use_in_tests = true
	check(Progress.enabled("") and not Progress.enabled("run") and not Progress.enabled("test"),
			"a scripted run (--autopilot / ?autopilot) never uses the save")
	Progress.clear()
	_run.call_deferred()


func launch() -> void:
	if main:
		main.free()
		await frames(2)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await frames(30)


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
	await frames(20)


func tap_pad(b: JoyButton) -> void:
	for down in [true, false]:
		var e := InputEventJoypadButton.new()
		e.device = 0
		e.button_index = b
		e.pressed = down
		Input.parse_input_event(e)
		await frames(3)
	await frames(17)


func ids() -> Array:
	return main.menus.items.map(func(it): return it["id"])


func enabled(id: String) -> bool:
	for it in main.menus.items:
		if it["id"] == id:
			return it["enabled"]
	return false


func item_text(id: String) -> String:
	## Everything the choice shows (its name, the line under it, its shortcut).
	for it in main.menus.items:
		if it["id"] == id:
			var t := ""
			for l in (it["node"] as Node).find_children("*", "Label", true, false):
				t += (l as Label).text + " | "
			return t
	return ""


func screen(path: String) -> Node:
	for n in main.get_children():
		if n.get_script() and n.get_script().resource_path == path:
			return n
	return null


func click(id: String) -> void:
	## Points the mouse at a choice (it gets picked) and clicks it.
	for it in main.menus.items:
		if it["id"] != id:
			continue
		var c: Control = it["node"]
		# window pixels (headless, the window is 64x64 and the 1920x1080 UI is scaled into it)
		var p: Vector2 = root.get_final_transform() * c.get_global_rect().get_center()
		var mv := InputEventMouseMotion.new()
		mv.position = p
		mv.global_position = p
		root.push_input(mv)                # (headless: the viewport's GUI gets mouse events this way)
		await frames(4)
		for down in [true, false]:
			var b := InputEventMouseButton.new()
			b.button_index = MOUSE_BUTTON_LEFT
			b.pressed = down
			b.position = p
			b.global_position = p
			root.push_input(b)
			await frames(2)
		await frames(15)


func _run() -> void:
	await launch()
	var m = main.menus
	# --- no save
	check(m.mode == m.START and m.title.text == "PRO SKATER", "the game opens on the start screen, titled PRO SKATER", m.title.text)
	check(ids() == ["resume_game", "new_game", "level", "skater", "controls"],
			"the menu: Resume game, Start new game, Level select, Customize character, Controls (no Quit outside the Windows build)", str(ids()))
	var names: Array = main.menus.items.map(func(it): return it["text"])
	check(names == ["RESUME GAME", "START NEW GAME", "LEVEL SELECT", "CUSTOMIZE CHARACTER", "CONTROLS"], "the choices' names", str(names))
	check(not enabled("resume_game") and m.selected_id() == "new_game" and "No saved game" in item_text("resume_game"),
			"no save: Resume game is greyed out and Start new game is picked", item_text("resume_game"))
	var side: String = m.side.get_parsed_text()
	check("THE WAREHOUSE" in side and "Find the Secret Tape" in side and "LEVEL SELECT" in item_text("level") and "The Warehouse" in item_text("level"),
			"beside the menu: the level and its goals; Level select names the level", side.replace("\n", " | ").substr(0, 110))
	check("TAB" in item_text("level") and "C / Y" in item_text("skater") and "Male skater" in item_text("skater"),
			"Level select and Customize character show their shortcuts; the character line names the skater", item_text("skater"))
	check("ENTER / A" in m.hint.text, "the hint names Enter / A", m.hint.text)
	await tap_key(KEY_UP)
	check(m.selected_id() == "controls", "Up from Start new game skips the greyed-out Resume game (to Controls)", m.selected_id())
	await tap_key(KEY_DOWN)
	await tap_key(KEY_S)
	check(m.selected_id() == "level", "Down and S move down (Start new game, Level select)", m.selected_id())
	# --- Controls
	await tap_key(KEY_DOWN)
	await tap_key(KEY_DOWN)
	await tap_key(KEY_ENTER)
	check(m.mode == m.CONTROLS_SCREEN and m.grid.is_visible_in_tree() and m.grid.get_child_count() == m.CONTROLS.size() * 3,
			"Controls opens the keyboard / gamepad table", "mode %d, %d cells" % [m.mode, m.grid.get_child_count()])
	await tap_key(KEY_ESCAPE)
	check(m.mode == m.START and m.selected_id() == "controls", "Esc goes back to the start screen, on Controls", m.selected_id())
	# --- the mouse
	await click("level")
	var ls := screen(LS_SCRIPT)
	check(ls != null and m.mode == m.NONE, "the mouse: a click on Level select opens it")
	await tap_key(KEY_ESCAPE)
	await frames(10)
	check(screen(LS_SCRIPT) == null and m.mode == m.START and m.selected_id() == "new_game",
			"leaving the level select comes back on the play choice (Enter skates the level)", m.selected_id())
	# --- gamepad: D-pad down to Customize character, A opens it, B leaves it
	await tap_pad(JOY_BUTTON_DPAD_DOWN)
	await tap_pad(JOY_BUTTON_DPAD_DOWN)
	check(m.selected_id() == "skater", "the gamepad's D-pad moves the selection", m.selected_id())
	await tap_pad(JOY_BUTTON_A)
	var b := screen("res://scripts/ui/skater_builder.gd")
	check(b != null and m.mode == m.NONE, "A on Customize character opens the character builder")
	await tap_pad(JOY_BUTTON_B)
	await frames(10)
	check(screen("res://scripts/ui/skater_builder.gd") == null and m.mode == m.START and m.selected_id() == "new_game",
			"B leaves the builder, back on the play choice", m.selected_id())
	# --- the shortcuts
	await tap_key(KEY_TAB)
	check(screen(LS_SCRIPT) != null, "Tab still opens the level select")
	await tap_key(KEY_ESCAPE)
	await frames(10)
	await tap_key(KEY_C)
	check(screen("res://scripts/ui/skater_builder.gd") != null, "C still opens the character builder")
	await tap_key(KEY_ESCAPE)
	await frames(10)
	# --- Start new game, a goal, Main menu from the pause menu, Resume game
	main._show_start()                         # (the default choice again)
	await frames(20)
	check(m.selected_id() == "new_game", "back on the start screen, Start new game is picked", m.selected_id())
	await tap_key(KEY_ENTER)
	check(main.running and not tree_paused() and m.mode == m.NONE and Progress.exists() and Progress.last_level() == "warehouse",
			"Enter on Start new game starts a run, and the save exists (last level: the Warehouse)", Progress.last_level())
	main.level.tape_collected.emit()
	await frames(5)
	check("tape" in Progress.done_goals("warehouse"), "a goal done in a run is saved at once", str(Progress.done_goals("warehouse")))
	await tap_key(KEY_ESCAPE)
	check(m.mode == m.PAUSE and ids() == ["resume_run", "restart", "main_menu"], "the pause menu: Resume, Restart run, Main menu", str(ids()))
	await tap_key(KEY_RIGHT)
	await tap_key(KEY_RIGHT)
	await tap_key(KEY_ENTER)
	check(m.mode == m.START and not main.running and not main.hud.visible, "Main menu leaves the run for the start screen")
	check(enabled("resume_game") and m.selected_id() == "resume_game" and "1 / 5 goals" in item_text("resume_game"),
			"with a save, Resume game is picked and names the goals done", item_text("resume_game"))
	check("[X]  Find the Secret Tape" in m.side.get_parsed_text() and "Starts over" in item_text("new_game"),
			"the side ticks the saved goal; Start new game says it starts over")
	await tap_key(KEY_ENTER)
	var tape: Dictionary = main._goal("tape")
	var others: Array = main.goals.filter(func(g): return g["id"] != "tape" and g["done"])
	check(main.running and tape.get("done", false) and others.is_empty() and main.score.total == 0,
			"Resume game: a new run with the saved goal ticked (and only that one)", str(main.goals.map(func(g): return [g["id"], g["done"]])))
	# --- the end screen
	main.score.total = 12345
	main.time_left = 0.2
	await frames(60)
	check(m.mode == m.END and ids().has("again") and ids().has("main_menu"), "the end screen: Skate again (and Replay), Main menu", str(ids()))
	check(Progress.best_score("warehouse") == 12345, "the run's score is saved as the level's best", str(Progress.best_score("warehouse")))
	await frames(40)
	await click("main_menu")
	check(m.mode == m.START and "12,345" in m.side.get_parsed_text(), "the end screen's Main menu (clicked) comes back; the side shows the best score")
	# --- Start new game with a save asks first
	await tap_key(KEY_DOWN)
	await tap_key(KEY_ENTER)
	check(m.mode == m.CONFIRM and m.selected_id() == "no_keep" and "1 goal done on 1 level" in m.body.get_parsed_text(),
			"with a save, Start new game asks first (No is picked)", m.body.get_parsed_text().strip_edges())
	await tap_key(KEY_ENTER)
	check(m.mode == m.START and "tape" in Progress.done_goals("warehouse") and m.selected_id() == "new_game", "No keeps the save")
	await tap_key(KEY_ENTER)
	await tap_key(KEY_RIGHT)
	await tap_key(KEY_ENTER)
	check(main.running and Progress.done_goals("warehouse").is_empty() and Progress.best_score("warehouse") == 0
			and main.goals.filter(func(g): return g["done"]).is_empty(), "Yes clears the save and starts a fresh run")
	# --- a relaunch reads the save back, on the level played last
	main.level.tape_collected.emit()
	await frames(5)
	var ok: bool = await main.switch_level("baths")
	main.restart()
	await frames(10)
	check(ok and Progress.last_level() == "baths", "a run on Eastside Baths makes it the level played last", Progress.last_level())
	await launch()
	m = main.menus
	check(main.level.level_id == "baths" and m.mode == m.START and m.selected_id() == "resume_game",
			"after a relaunch the game opens on the level played last, with Resume game picked", main.level.level_id)
	await tap_key(KEY_TAB)
	await frames(10)
	ls = screen(LS_SCRIPT)
	var cards := ""
	if ls:
		for c in ls.cards:
			for r in (c as Node).find_children("*", "RichTextLabel", true, false):
				cards += (r as RichTextLabel).get_parsed_text()
	check("[X]  Find the Secret Tape" in cards, "the level select's cards tick the saved goals", cards.replace("\n", " | ").substr(0, 90))
	await tap_key(KEY_ESCAPE)
	await frames(10)
	_finish()


func tree_paused() -> bool:
	return main.get_tree().paused


func _finish() -> void:
	Progress.clear()
	var report := "Pro Skater start screen menu and saved game tests  %s\n%s\n%d passed, %d failed\n" % [
			Time.get_datetime_string_from_system(), "\n".join(out), passed, failed]
	print(report)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/results"))
	var f := FileAccess.open("res://tests/results/menu.txt", FileAccess.WRITE)
	f.store_string(report)
	f.close()
	quit(1 if failed > 0 else 0)
