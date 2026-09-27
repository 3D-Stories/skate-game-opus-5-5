extends SceneTree
## Headless tests of the desktop layer (desktop/desktop.gd) on the real main scene, in the
## staged Windows project where it is an autoload (desktop/test_desktop.sh runs this):
## the start screen hint, quitting from the menus (keyboard Q and gamepad B, each confirmed by
## a second press), Alt+Enter and F11 (fullscreen toggle, saved, and Alt+Enter not also
## starting the run), pausing when the window loses focus (not during the scripted run), the
## mouse cursor, the windowed size on large and small screens, the bench report picked up from
## the game's log line, and the settings report. Levels: Eastside Baths is embedded (no pack to
## download), the level select opens from the start screen, Q / B do not quit from it (B goes
## back), and switching to the Baths brings back the start screen with the quit hint.
##   godot --headless --path <stage> --fixed-fps 60 -s res://desktop/test_desktop.gd <out file>

var main: Node
var desk: Node
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
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func frames(n: int) -> void:
	for i in n:
		await process_frame


func key(k: Key, down: bool, alt := false) -> void:
	var e := InputEventKey.new()
	e.keycode = k
	e.physical_keycode = k
	e.alt_pressed = alt
	e.pressed = down
	Input.parse_input_event(e)


func tap_key(k: Key, alt := false) -> void:
	key(k, true, alt)
	await frames(2)
	key(k, false, alt)
	await frames(2)


func tap_pad(b: JoyButton) -> void:
	for down in [true, false]:
		var e := InputEventJoypadButton.new()
		e.device = 0
		e.button_index = b
		e.pressed = down
		Input.parse_input_event(e)
		await frames(2)


func level_screen() -> Node:
	for n in main.get_children():
		if n.get_script() and n.get_script().resource_path == "res://scripts/ui/level_select.gd":
			return n
	return null


func pref_mode() -> String:
	var cf := ConfigFile.new()
	return cf.get_value("window", "mode", "") if cf.load("user://desktop.cfg") == OK else "(no file)"


func _run() -> void:
	desk = root.get_node_or_null("Desktop")
	check(desk != null and desk.get_script().resource_path == "res://desktop/desktop.gd", "the Desktop autoload is loaded")
	if desk == null:
		_finish()
		return
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://desktop.cfg"))
	await frames(10)
	check(desk.main == main, "it finds the Main scene")
	var quits := [0]
	desk.quit_game = func(): quits[0] += 1

	# --- start screen
	check(paused and main.menus.mode == main.menus.START and desk.in_menu(), "start screen: the game waits in a menu")
	check(desk.hint.visible and "QUIT" in desk.hint.text and "F11" in desk.hint.text, "start screen: the quit / fullscreen hint shows", desk.hint.text)
	await frames(30)                       # the menus ignore input right after they open
	await tap_key(KEY_ENTER, true)
	await frames(3)
	check(main.menus.mode == main.menus.START and not main.running, "Alt+Enter does not also start the run")
	# (the headless display server has no real window: it stays windowed, so what is checked is
	# that the toggle ran and saved the mode; the native runs switch a real window)
	check(desk.window_toggles == 1 and pref_mode() != "(no file)", "Alt+Enter toggles the window mode and saves it", pref_mode())
	await tap_key(KEY_F11)
	await frames(3)
	check(desk.window_toggles == 2 and main.menus.mode == main.menus.START, "F11 toggles the window mode too")
	await tap_key(KEY_ENTER, true)
	await tap_key(KEY_F11)
	await frames(3)

	# --- quitting from a menu: the first press arms, a second press within 3 s quits
	await tap_key(KEY_Q)
	check(quits[0] == 0 and desk._quit_armed > 0.0 and "AGAIN" in desk.hint.text, "Q once: asks to press again, does not quit", desk.hint.text)
	await frames(200)                      # 3.3 s at 60 fps
	check(desk._quit_armed <= 0.0 and "AGAIN" not in desk.hint.text, "the quit prompt goes away after 3 s")
	await tap_key(KEY_Q)
	await tap_key(KEY_Q)
	check(quits[0] == 1, "Q twice quits", "quit calls: %d" % quits[0])
	await frames(200)
	await tap_pad(JOY_BUTTON_B)
	await tap_pad(JOY_BUTTON_B)
	check(quits[0] == 2, "gamepad B twice quits", "quit calls: %d" % quits[0])
	await frames(200)

	# --- levels: Eastside Baths is embedded in the desktop build; the level select (Tab / Select
	# on the start screen) is a screen of its own, where Q and B are not "quit" (B goes back)
	check("baths" in LevelRegistry.ids() and LevelRegistry.available("baths") and LevelRegistry.pack_url("baths") == "",
			"Eastside Baths is in the build itself: available without a download, no pack URL on desktop")
	await tap_key(KEY_TAB)
	await frames(20)
	var ls := level_screen()
	check(ls != null and not desk.in_menu() and not desk.hint.visible, "Tab opens the level select; the quit hint is hidden there")
	var tags := ""
	if ls:
		for c in ls.cards:
			tags += "%s: %s; " % [String(c.get_meta("id")), (c.get_meta("tag") as Label).text]
	check(ls != null and "DOWNLOAD" not in tags, "the level select offers no download on desktop", tags)
	await tap_key(KEY_Q)
	await frames(12)
	await tap_pad(JOY_BUTTON_B)
	await frames(20)
	check(quits[0] == 2 and desk._quit_armed <= 0.0 and level_screen() == null and main.menus.mode == main.menus.START,
			"Q and B in the level select do not quit; B goes back to the start screen")
	await frames(30)
	await tap_key(KEY_TAB)
	await frames(20)
	await tap_key(KEY_RIGHT)
	await frames(12)
	await tap_key(KEY_ENTER)
	var loaded := false
	for i in 900:
		await process_frame
		if main.level.level_id == "baths" and not main.switching and level_screen() == null:
			loaded = true
			break
	await frames(5)
	check(loaded and main.goals.size() == 6 and main.menus.mode == main.menus.START and desk.in_menu() and desk.hint.visible,
			"Right + Enter loads Eastside Baths: its six goals, then the start screen with the quit hint",
			"%s, %d goals" % [main.level.level_id, main.goals.size()])
	await frames(30)

	# --- the run (on Eastside Baths from here on)
	await tap_key(KEY_ENTER)
	await frames(30)
	check(main.running and not paused and not desk.in_menu(), "Enter starts the run")
	check(not desk.hint.visible, "the hint is hidden while riding")
	# (headless has no cursor, so Input.mouse_mode reads back VISIBLE; _was_riding is what set it)
	check(desk._was_riding, "the mouse cursor is hidden while riding (requested)")
	await tap_key(KEY_Q)                   # Q is spin-left on the ground: never quits mid-run
	await tap_key(KEY_Q)
	check(quits[0] == 2 and main.running, "Q during the run does not quit")

	# --- losing focus pauses the run, the way Esc does
	var t0: float = main.time_left
	desk.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	await frames(4)
	check(paused and main.menus.mode == main.menus.PAUSE, "losing window focus pauses the run")
	check(not desk._was_riding, "the mouse cursor shows again in the pause menu (requested)")
	await frames(60)
	check(main.time_left == t0 or absf(main.time_left - t0) < 0.1, "the clock stops while paused", "%.2f" % (t0 - main.time_left))
	check(desk.hint.visible, "the hint shows in the pause menu")
	desk.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	await frames(4)
	check(paused and main.menus.mode == main.menus.PAUSE, "a second focus loss keeps it paused (does not toggle back)")
	await tap_key(KEY_ENTER)
	await frames(30)
	check(main.running and not paused, "Enter resumes")
	main.autopilot_mode = "run"            # the scripted run never pauses
	desk.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	await frames(4)
	check(not paused, "losing focus does not pause the scripted run (--autopilot)")
	main.autopilot_mode = ""

	# --- windowed size: 1920x1080 when it fits, the largest 16:9 window otherwise
	var deco := Vector2i(16, 39)
	check(desk.windowed_size(Vector2i(3440, 1392), deco) == Vector2i(1920, 1080), "windowed: 1920x1080 on a 3440x1440 screen")
	check(desk.windowed_size(Vector2i(2560, 1392), deco) == Vector2i(1920, 1080), "windowed: 1920x1080 on a 2560x1440 screen")
	var s1080: Vector2i = desk.windowed_size(Vector2i(1920, 1032), deco)
	check(s1080.y + deco.y <= 1032 and s1080.x + deco.x <= 1920 and absf(float(s1080.x) / s1080.y - 16.0 / 9.0) < 0.01,
			"windowed: fits a 1920x1080 screen with its taskbar, 16:9", str(s1080))
	var s768: Vector2i = desk.windowed_size(Vector2i(1366, 728), deco)
	check(s768.y + deco.y <= 728 and s768.x + deco.x <= 1366, "windowed: fits a 1366x768 laptop screen", str(s768))

	# --- the bench report: picked up from the game's "[bench] {json}" log line
	var bench_file := "user://desktop_test/bench.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(bench_file))
	desk._bench_path = bench_file
	desk._bench_written = false
	print("[bench] " + JSON.stringify({"frames": 7, "avg_fps": 60.0, "msaa": "4x"}))
	await frames(3)
	var rep = JSON.parse_string(FileAccess.get_file_as_string(bench_file)) if FileAccess.file_exists(bench_file) else null
	check(rep is Dictionary and rep.get("frames") == 7.0 and rep.has("desktop"), "the bench report is written to its file, with the desktop settings added",
			ProjectSettings.globalize_path(bench_file))
	var info: Dictionary = desk.system_info()
	for k in ["rendering_method", "rendering_driver", "adapter", "window_mode", "render_size", "vsync", "msaa_3d", "audio", "joypads", "environment"]:
		check(info.has(k), "settings report has " + k, str(info.get(k)))
	check(info["msaa_3d"] == "4x" and info["environment"]["ssao"] and info["environment"]["glow"] and info["environment"]["tonemap"] == "agx"
			and info["environment"]["sun_shadows"], "settings report: 4x MSAA, SSAO, glow, AgX tone mapping, sun shadows", str(info["environment"]))
	_finish()


func _finish() -> void:
	var report := "desktop layer (desktop/desktop.gd), headless: %d passed, %d failed\n" % [passed, failed] + "\n".join(out) + "\n"
	print(report)
	var args := OS.get_cmdline_user_args()
	var path: String = args[0] if args.size() > 0 else "user://desktop_test/desktop.txt"
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(report)
	f.close()
	quit(0 if failed == 0 else 1)
