extends SceneTree
## Headless game-flow tests on the real main scene, driven by injected input events:
## timer, pause (freezes gameplay and the clock), end-of-run screen, restart, keyboard +
## gamepad (joypad) actions, grind snapping, sideways / off-balance bails with the board
## flying off, and the goals list.
##   godot --headless --path . --fixed-fps 60 -s tests/test_flow.gd   -> tests/results/flow.txt

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
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func frames(n: int) -> void:
	for i in n:
		await process_frame


func key(action_key: Key, down: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = action_key
	e.physical_keycode = action_key
	e.pressed = down
	Input.parse_input_event(e)


func tap_key(k: Key) -> void:
	key(k, true)
	await frames(2)
	key(k, false)
	await frames(2)


func pad_button(b: JoyButton, down: bool) -> void:
	var e := InputEventJoypadButton.new()
	e.device = 0
	e.button_index = b
	e.pressed = down
	Input.parse_input_event(e)


func pad_axis(a: JoyAxis, v: float) -> void:
	var e := InputEventJoypadMotion.new()
	e.device = 0
	e.axis = a
	e.axis_value = v
	Input.parse_input_event(e)


func _run() -> void:
	await frames(5)
	var sk = main.skater
	# --- start screen
	check(paused and main.menus.mode == main.menus.START, "game opens paused on the start screen")
	await frames(30)      # menus ignore input for a moment after opening (no accidental skips)
	await tap_key(KEY_ENTER)
	await frames(3)
	check(main.running and not paused and main.menus.mode == main.menus.NONE, "Enter starts the run")
	# --- timer
	var t0: float = main.time_left
	await frames(60)
	check(absf((t0 - main.time_left) - 1.0) < 0.1, "timer counts down in real time", "%.2f" % (t0 - main.time_left))
	# --- keyboard push: W accelerates the skater from a standstill
	var v0: float = sk.vel.length()
	key(KEY_W, true)
	await frames(45)
	key(KEY_W, false)
	check(sk.vel.length() > v0 + 1.5, "keyboard: holding W pushes and builds speed", "%.1f -> %.1f" % [v0, sk.vel.length()])
	# --- pause freezes gameplay and time
	await tap_key(KEY_ESCAPE)
	await frames(2)
	var tp: float = main.time_left
	var pp: Vector3 = sk.global_position
	await frames(90)
	check(paused and main.menus.mode == main.menus.PAUSE, "Esc opens the pause menu")
	check(main.time_left == tp and sk.global_position == pp, "pause freezes the clock and the skater",
			"dt=%.3f dp=%.3f" % [tp - main.time_left, (sk.global_position - pp).length()])
	await frames(30)
	await tap_key(KEY_ESCAPE)
	await frames(30)
	check(not paused and main.time_left < tp, "Esc resumes and the clock runs again")
	# --- gamepad: A (button 0) is jump/ollie, left stick steers
	sk.spawn(Vector3(0, 0, -24), Vector3(0, 0, -1), 6.0)
	await frames(5)
	pad_button(JOY_BUTTON_A, true)
	await frames(12)
	check(Input.is_action_pressed("jump") and sk.crouch_t > 0.0, "gamepad: holding A crouches (charges the ollie)")
	pad_button(JOY_BUTTON_A, false)
	await frames(6)
	check(sk.state == sk.AIR, "gamepad: releasing A pops an ollie", "state=%d" % sk.state)
	await frames(60)
	var h0: Vector3 = sk.heading
	pad_axis(JOY_AXIS_LEFT_X, 1.0)
	await frames(30)
	pad_axis(JOY_AXIS_LEFT_X, 0.0)
	check(h0.angle_to(sk.heading) > 0.5, "gamepad: left stick steers", "%.2f rad" % h0.angle_to(sk.heading))
	for b in [JOY_BUTTON_X, JOY_BUTTON_B, JOY_BUTTON_Y]:
		pad_button(b, true)
		await frames(1)
		var acts := {JOY_BUTTON_X: "flip", JOY_BUTTON_B: "grab", JOY_BUTTON_Y: "grind"}
		check(Input.is_action_pressed(acts[b]), "gamepad button %d maps to %s" % [b, acts[b]])
		pad_button(b, false)
		await frames(1)
	# --- grind snap: an ollie next to the long rail with grind held snaps onto it
	sk.spawn(Vector3(-12.0, 0.0, 4.0), Vector3(0, 0, -1), 7.0)
	await frames(24)
	await tap_key(KEY_SPACE)
	key(KEY_L, true)
	await frames(30)
	check(sk.state == sk.GRIND and sk.grind_rail and sk.grind_rail.name == "long_rail", "grind button snaps onto the rail",
			"state=%d" % sk.state)
	key(KEY_L, false)
	check(main.score.in_combo and main.score.combo_text().contains("50-50"), "the grind is in the combo", main.score.combo_text())
	await frames(30)
	# --- sideways landing bails; the board flies off as a rigid body
	var bails := []
	sk.bailed.connect(func(r): bails.append(r))
	sk.spawn(Vector3(0, 0, -24), Vector3(0, 0, -1), 6.0)
	await frames(3)
	sk.state = sk.AIR
	sk.vel = Vector3(0, -3, -6)
	sk.face_up = Vector3.UP
	sk.face_fwd = Vector3.RIGHT          # board across the direction of travel
	sk.trick_busy = 0.0
	sk._land(Vector3.UP, null)
	await frames(2)
	check(bails.size() == 1 and bails[0] == "sideways" and sk.state == sk.BAIL, "landing sideways bails", str(bails))
	var loose := false
	for n in main.get_children():
		if n is RigidBody3D and n.name.begins_with("LooseBoard"):
			loose = true
	check(loose, "the board comes off and tumbles as a rigid body")
	check(not main.score.in_combo, "the bail loses the combo")
	await frames(int((sk.BAIL_MAX + sk.GETUP_TIME + 1.0) * 60))   # tumble, lie, get up
	check(sk.state == sk.GROUND, "the skater gets back up after the bail")
	# --- off-balance manual bails
	sk.spawn(Vector3(0, 0, -24), Vector3(0, 0, -1), 5.0)
	await frames(3)
	sk._start_manual("manual")
	sk.manual_bal = 1.05
	await frames(3)
	check(bails.size() == 2 and bails[1] == "manual", "losing the manual balance bails", str(bails))
	await frames(int((sk.BAIL_MAX + sk.GETUP_TIME + 1.0) * 60))   # tumble, lie, get up
	# --- goals list + end of run + restart
	check(main.goals.size() == 5, "five goals in the goals list")
	main.time_left = 0.3
	await frames(40)
	check(paused and main.menus.mode == main.menus.END, "the run ends at 0:00 on the end-of-run screen")
	var end_text: String = main.menus.body.get_parsed_text() if main.menus.body else ""
	check(end_text.contains("Score") or end_text.contains("SCORE") or end_text.contains("score"), "end screen shows the score",
			end_text.substr(0, 80))
	await frames(70)
	await tap_key(KEY_ENTER)
	await frames(5)
	check(main.running and main.time_left > 119.0 and main.score.total == 0 and not paused, "Enter on the end screen restarts the run")
	var report := "Pro Skater game-flow tests  %s\n%s\n%d passed, %d failed\n" % [
			Time.get_datetime_string_from_system(), "\n".join(out), passed, failed]
	print(report)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/results"))
	var f := FileAccess.open("res://tests/results/flow.txt", FileAccess.WRITE)
	f.store_string(report)
	f.close()
	quit(1 if failed > 0 else 0)
