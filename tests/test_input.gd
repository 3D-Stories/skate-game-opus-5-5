extends SceneTree
## Headless input tests on the real main scene: every mapped action is performed through
## injected Godot input events (Input.parse_input_event), once with keyboard events only
## and once with gamepad events only (InputEventJoypadButton + InputEventJoypadMotion on
## the left stick, D-pad buttons), and the start screen's controls table is read back
## from its actual Label nodes and compared with the input map.
##   godot --headless --path . --fixed-fps 60 -s tests/test_input.gd   -> tests/results/input.txt
##
## The bindings pressed here are the documented THPS-style layout (start-screen CONTROLS)
## written out by hand, so an input map that drifts from the documentation fails.
## Air tricks are done in real vert airs off the halfpipe wall (about 1.2 s of air), spins
## in real standing ollies, grinds on the long rail. The test never moves the skater during
## a check: it only picks a starting spot with sk.spawn(), as the game's own respawn does.

const RUN_TIME := 120.0
const FLAT_POS := Vector3(0, 0, -24)          # open flat floor north of the halfpipe
const FLAT_FWD := Vector3(0, 0, -1)
const HP_POS := Vector3(0, 0, -43)            # halfpipe flat bottom
const HP_FWD := Vector3(-1, 0, 0)             # rolling toward the west wall
const HP_SPEED := 11.0
const RAIL_POS := Vector3(-12, 0, 4)          # lined up with the end of long_rail
const SPECIAL_NAME := "Tiger Claw Tre"

const ACTIONS := ["left", "right", "up", "down", "jump", "flip", "grab", "grind", "spin_left", "spin_right",
		"pause", "confirm", "restart"]
const PLAY_ACTIONS := ["left", "right", "up", "down", "jump", "flip", "grab", "grind", "spin_left", "spin_right"]

## Documented keyboard layout (menus.gd CONTROLS): action -> keys, primary first.
const KB := {
	"up": [KEY_W, KEY_UP], "down": [KEY_S, KEY_DOWN], "left": [KEY_A, KEY_LEFT], "right": [KEY_D, KEY_RIGHT],
	"jump": [KEY_SPACE], "flip": [KEY_J], "grab": [KEY_K], "grind": [KEY_L],
	"spin_left": [KEY_Q], "spin_right": [KEY_E],
	"pause": [KEY_ESCAPE, KEY_P], "confirm": [KEY_ENTER, KEY_SPACE], "restart": [KEY_R],
}
## Documented gamepad layout: [kind, index, axis value, label], primary first.
const PAD := {
	"up": [["axis", JOY_AXIS_LEFT_Y, -1.0, "left stick up"], ["button", JOY_BUTTON_DPAD_UP, 1.0, "D-pad up"]],
	"down": [["axis", JOY_AXIS_LEFT_Y, 1.0, "left stick down"], ["button", JOY_BUTTON_DPAD_DOWN, 1.0, "D-pad down"]],
	"left": [["axis", JOY_AXIS_LEFT_X, -1.0, "left stick left"], ["button", JOY_BUTTON_DPAD_LEFT, 1.0, "D-pad left"]],
	"right": [["axis", JOY_AXIS_LEFT_X, 1.0, "left stick right"], ["button", JOY_BUTTON_DPAD_RIGHT, 1.0, "D-pad right"]],
	"jump": [["button", JOY_BUTTON_A, 1.0, "A"]], "flip": [["button", JOY_BUTTON_X, 1.0, "X"]],
	"grab": [["button", JOY_BUTTON_B, 1.0, "B"]], "grind": [["button", JOY_BUTTON_Y, 1.0, "Y"]],
	"spin_left": [["button", JOY_BUTTON_LEFT_SHOULDER, 1.0, "LB"]], "spin_right": [["button", JOY_BUTTON_RIGHT_SHOULDER, 1.0, "RB"]],
	"pause": [["button", JOY_BUTTON_START, 1.0, "Start"]],
	"confirm": [["button", JOY_BUTTON_A, 1.0, "A"], ["button", JOY_BUTTON_START, 1.0, "Start"]],
	"restart": [["button", JOY_BUTTON_BACK, 1.0, "Back"]],
}
## Names a player reads on the start screen for joypad bindings (Xbox layout).
const PAD_BUTTON_NAMES := {JOY_BUTTON_A: "A", JOY_BUTTON_B: "B", JOY_BUTTON_X: "X", JOY_BUTTON_Y: "Y",
		JOY_BUTTON_BACK: "Back", JOY_BUTTON_START: "Start", JOY_BUTTON_LEFT_SHOULDER: "LB",
		JOY_BUTTON_RIGHT_SHOULDER: "RB", JOY_BUTTON_DPAD_UP: "D-pad", JOY_BUTTON_DPAD_DOWN: "D-pad",
		JOY_BUTTON_DPAD_LEFT: "D-pad", JOY_BUTTON_DPAD_RIGHT: "D-pad"}
const PAD_AXIS_NAMES := {JOY_AXIS_LEFT_X: "Left stick", JOY_AXIS_LEFT_Y: "Left stick"}
## Start-screen rows (by the start of their first-column text) -> actions whose bindings the
## row must name, plus literal input sequences it must name.
const ROWS := [
	["Steer", ["left", "right", "up", "down"], []],
	["Ollie", ["jump"], []],
	["Flip", ["flip"], []],
	["Grab", ["grab"], []],
	["Grind", ["grind"], []],
	["Spin", ["spin_left", "spin_right"], []],
	["Manual", [], ["Up, Down", "Down, Up"]],
	["Special", ["flip"], ["Left, Right"]],
	["Pause", ["pause", "restart"], []],
]
## THPS layout expected from button + direction: [direction, trick, clip].
const FLIPS := [["", "Kickflip", "kickflip"], ["left", "Kickflip", "kickflip"], ["right", "Heelflip", "heelflip"],
		["down", "Pop Shove-It", "shoveit"], ["up", "360 Flip", "treflip"]]
const GRABS := [["", "Indy", "indy"], ["right", "Indy", "indy"], ["left", "Melon", "melon"],
		["up", "Nosegrab", "nosegrab"], ["down", "Tailgrab", "tailgrab"]]

var main: Node
var sk                      # the Skater (untyped: game classes are not loaded yet at compile time)
var TR                      # tricks.gd, for the game's own spin naming
var dev := "kb"
var out: PackedStringArray = []
var passed := 0
var failed := 0
var clock_topups := 0


func check(ok: bool, what: String, detail := "") -> void:
	if ok:
		passed += 1
		out.append("PASS  " + what)
	else:
		failed += 1
		out.append("FAIL  " + what + ("  (" + detail + ")" if detail != "" else ""))
		print("FAIL  " + what + "  (" + detail + ")")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	TR = load("res://scripts/game/tricks.gd")
	# input timing below is counted in frames: it needs --fixed-fps 60 (delta exactly 1/60)
	var fixed := true
	for i in 5:
		await process_frame
		fixed = fixed and absf(root.get_process_delta_time() - 1.0 / 60.0) < 1e-5
	if not fixed:
		check(false, "harness: run with --fixed-fps 60 (input timing is counted in frames)",
				"process delta %.5f s instead of 1/60 s; no game checks were run" % root.get_process_delta_time())
		finish()
		return
	await boot()
	await start_screen()
	for d in ["kb", "pad"]:
		dev = d
		if d == "pad":
			await boot()           # a fresh game: the gamepad run starts from the start screen too
		await device_run()
	release_all()
	finish()


func finish() -> void:
	var report := "Pro Skater input tests (keyboard + gamepad)  %s\n%s\n%d passed, %d failed\n" % [
			Time.get_datetime_string_from_system(), "\n".join(out), passed, failed]
	print(report)
	if clock_topups > 0:
		print("(run clock topped up %d time(s) so the two-minute run did not end mid-test)" % clock_topups)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/results"))
	var f := FileAccess.open("res://tests/results/input.txt", FileAccess.WRITE)
	f.store_string(report)
	f.close()
	quit(1 if failed > 0 else 0)


func boot() -> void:
	if main:
		dev = "kb"
		release_all()
		dev = "pad"
		release_all()
		main.queue_free()
		await frames(3)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await frames(5)
	sk = main.skater


# ------------------------------------------------------------------ input helpers

func frames(n: int) -> void:
	for i in n:
		await process_frame


func wait_until(cond: Callable, max_frames: int) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await process_frame
	return cond.call()


func DEV() -> String:
	return "[keyboard]" if dev == "kb" else "[gamepad]"


func binds(action: String) -> Array:
	return KB[action] if dev == "kb" else PAD[action]


func bind_name(action: String, alt := 0) -> String:
	if dev == "kb":
		return OS.get_keycode_string(KB[action][alt])
	return String(PAD[action][alt][3])


func press(action: String, down: bool, alt := 0) -> void:
	## Sends the physical event for binding `alt` of `action` on the current device.
	if dev == "kb":
		var k: int = KB[action][alt]
		var e := InputEventKey.new()
		e.keycode = k
		e.physical_keycode = k
		e.pressed = down
		Input.parse_input_event(e)
		return
	var b: Array = PAD[action][alt]
	if b[0] == "axis":
		var m := InputEventJoypadMotion.new()
		m.device = 0
		m.axis = b[1]
		m.axis_value = float(b[2]) if down else 0.0
		Input.parse_input_event(m)
	else:
		var jb := InputEventJoypadButton.new()
		jb.device = 0
		jb.button_index = b[1]
		jb.pressed = down
		Input.parse_input_event(jb)


func tap(action: String, alt := 0, hold := 2, after := 2) -> void:
	press(action, true, alt)
	await frames(hold)
	press(action, false, alt)
	await frames(after)


func release_all() -> void:
	for a in ACTIONS:
		for i in binds(a).size():
			press(a, false, i)


func last_trick() -> String:
	var t: Array = main.score.tricks
	return String(t[t.size() - 1]["name"]) if t.size() > 0 else ""


func clip() -> String:
	return String(sk.model.current)


func playing() -> String:
	return String(sk.model.anim.current_animation) if sk.model.anim.is_playing() else ""


func settle() -> void:
	## Let a bail finish and a pending combo bank before the next attempt.
	release_all()
	await frames(1)
	if sk.state == sk.BAIL:
		await wait_until(func(): return sk.state != sk.BAIL, 240)
	if sk.state == sk.AIR or sk.state == sk.GRIND:
		await wait_until(func(): return sk.state == sk.GROUND or sk.state == sk.BAIL, 240)
		if sk.state == sk.BAIL:
			await wait_until(func(): return sk.state != sk.BAIL, 240)
	if main.score.in_combo:
		await wait_until(func(): return not main.score.in_combo, 60)
	await frames(2)


func keep_clock() -> void:
	## The run is two minutes; the checks below take a while of game time. Topping the clock
	## up keeps the run from ending mid-test (the clock itself is covered by test_flow).
	if main.running and main.time_left < 45.0:
		main.time_left = RUN_TIME
		clock_topups += 1


# ------------------------------------------------------------------ start screen

func norm(s: String) -> String:
	var t := s.to_upper()
	for ch in ["/", ",", "+", "(", ")", ":"]:
		t = t.replace(ch, " ")
	return " " + " ".join(t.split(" ", false)) + " "


func has_word(text: String, name: String) -> bool:
	return norm(text).contains(norm(name))


func key_name(k: int) -> String:
	match k:
		KEY_ESCAPE:
			return "Esc"
		KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT:
			return "arrow keys"
	return OS.get_keycode_string(k)


func map_key_names(action: String) -> Array:
	var names := []
	for e in InputMap.action_get_events(action):
		if e is InputEventKey:
			var n := key_name(e.keycode if e.keycode != 0 else e.physical_keycode)
			if not n in names:
				names.append(n)
	return names


func map_pad_names(action: String) -> Array:
	var names := []
	for e in InputMap.action_get_events(action):
		var n := ""
		if e is InputEventJoypadButton:
			n = PAD_BUTTON_NAMES.get(e.button_index, "button %d" % e.button_index)
		elif e is InputEventJoypadMotion:
			n = PAD_AXIS_NAMES.get(e.axis, "axis %d" % e.axis)
		if n != "" and not n in names:
			names.append(n)
	return names


func start_screen() -> void:
	var m = main.menus
	check(paused and m.mode == m.START and m.panel.visible, "the game boots paused on the start screen")
	var cells: Array = []
	for c in m.grid.get_children():
		if c is Label and not c.is_queued_for_deletion():
			cells.append(c)
	var rows: int = m.CONTROLS.size()
	check(m.grid.is_visible_in_tree() and m.grid.columns == 3 and cells.size() == rows * 3,
			"start screen shows the controls table as visible Labels (%d rows x 3 columns)" % rows,
			"visible=%s columns=%d labels=%d" % [m.grid.is_visible_in_tree(), m.grid.columns, cells.size()])
	if cells.size() < 3:
		return
	check(cells[1].text.strip_edges() == "KEYBOARD" and cells[2].text.strip_edges() == "GAMEPAD",
			"controls table has a KEYBOARD and a GAMEPAD column", "%s | %s" % [cells[1].text, cells[2].text])
	var covered := {}
	for r in range(1, cells.size() / 3):
		var what: String = cells[r * 3].text
		var kb_txt: String = cells[r * 3 + 1].text
		var pad_txt: String = cells[r * 3 + 2].text
		var spec = null
		for s in ROWS:
			if what.begins_with(s[0]):
				spec = s
				break
		if spec == null:
			check(false, "start screen row '%s' describes a known action" % what)
			continue
		var want_k := []
		var want_p := []
		for a in spec[1]:
			covered[a] = true
			for n in map_key_names(a):
				if not n in want_k:
					want_k.append(n)
			for n in map_pad_names(a):
				if not n in want_p:
					want_p.append(n)
		var miss := []
		for n in want_k + spec[2]:
			if not has_word(kb_txt, n):
				miss.append("keyboard '%s'" % n)
		for n in want_p + spec[2]:
			if not has_word(pad_txt, n):
				miss.append("gamepad '%s'" % n)
		var named := ", ".join(want_k + want_p + spec[2])
		check(miss.is_empty(), "start screen row '%s': '%s' | '%s' names %s" % [what.strip_edges(), kb_txt, pad_txt, named],
				"missing " + ", ".join(miss))
	# confirm is on the hint line under the table
	var hint: String = m.hint.text
	var shown_k := map_key_names("confirm").filter(func(n): return has_word(hint, n))
	var shown_p := map_pad_names("confirm").filter(func(n): return has_word(hint, n))
	check(m.hint.is_visible_in_tree() and shown_k.size() > 0 and shown_p.size() > 0,
			"start screen hint '%s' names a bound confirm key (%s) and button (%s)" % [hint, ", ".join(shown_k), ", ".join(shown_p)],
			"confirm is bound to %s / %s" % [str(map_key_names("confirm")), str(map_pad_names("confirm"))])
	covered["confirm"] = true
	var uncovered := ACTIONS.filter(func(a): return not covered.has(a))
	check(uncovered.is_empty(), "every input-map action is shown on the start screen", "not shown: " + str(uncovered))


# ------------------------------------------------------------------ one device run

func device_run() -> void:
	var m = main.menus
	check(paused and m.mode == m.START, "%s fresh game on the start screen" % DEV())
	await frames(35)                     # menus ignore input for a moment after opening
	await tap("confirm")
	await frames(2)
	check(main.running and not paused and m.mode == m.NONE,
			"%s %s (confirm) on the start screen starts the run" % [DEV(), bind_name("confirm")])
	mapping()
	await sweep()
	await movement()
	await jump_check()
	keep_clock()
	for f in FLIPS:
		await air_trick("flip", f[0], f[1], f[2])
	keep_clock()
	for g in GRABS:
		await air_trick("grab", g[0], g[1], g[2])
	keep_clock()
	await spin_check("spin_left", 1.0)
	await spin_check("spin_right", -1.0)
	await spin_check("left", 1.0)
	await spin_check("right", -1.0)
	keep_clock()
	await grind_check("", "50-50", "grind_5050")
	await grind_check("left", "Boardslide", "boardslide")
	await grind_check("right", "Boardslide", "boardslide")
	await manual_check("up", "down", "manual", "Manual", "manual")
	await manual_check("down", "up", "nose", "Nose Manual", "nose_manual")
	keep_clock()
	await special_check()
	keep_clock()
	await menus_flow()


func mapping() -> void:
	for a in ACTIONS:
		var names := []
		if InputMap.has_action(a):
			for e in InputMap.action_get_events(a):
				if dev == "kb" and e is InputEventKey:
					names.append(OS.get_keycode_string(e.keycode if e.keycode != 0 else e.physical_keycode))
				elif dev == "pad" and e is InputEventJoypadButton:
					names.append("button %d (%s)" % [e.button_index, PAD_BUTTON_NAMES.get(e.button_index, "?")])
				elif dev == "pad" and e is InputEventJoypadMotion:
					names.append("axis %d %s" % [e.axis, "-" if e.axis_value < 0 else "+"])
		check(names.size() > 0, "%s input map: '%s' has a %s binding (%s)" % [DEV(), a, "key" if dev == "kb" else "joypad", ", ".join(names)],
				"no binding")


func sweep() -> void:
	## Each documented binding fires its action (and only that gameplay action) through
	## Godot's Input. The skater ignores input meanwhile (its own controls_enabled flag).
	sk.controls_enabled = false
	for a in PLAY_ACTIONS:
		var ok := true
		var names := []
		var detail := ""
		for i in binds(a).size():
			names.append(bind_name(a, i))
			press(a, true, i)
			await frames(1)
			var on := []
			for b in PLAY_ACTIONS:
				if Input.is_action_pressed(b):
					on.append(b)
			press(a, false, i)
			await frames(1)
			var stuck: bool = Input.is_action_pressed(a)
			if on != [a] or stuck:
				ok = false
				detail += "%s -> %s%s; " % [bind_name(a, i), str(on), " stuck" if stuck else ""]
		check(ok, "%s %s fire(s) '%s' through Godot Input" % [DEV(), " / ".join(names), a], detail)
	sk.controls_enabled = true


func movement() -> void:
	for i in binds("up").size():
		await settle()
		sk.spawn(FLAT_POS, FLAT_FWD, 0.0)
		await frames(5)
		var v0: float = sk.vel.length()
		press("up", true, i)
		await frames(45)
		var c := clip()
		var v1: float = sk.vel.length()
		press("up", false, i)
		check(v1 > v0 + 1.5 and c == "push", "%s holding %s (up) pushes and builds speed from a standstill" % [DEV(), bind_name("up", i)],
				"%.2f -> %.2f m/s, clip %s" % [v0, v1, c])
	for i in binds("down").size():
		await settle()
		sk.spawn(FLAT_POS, FLAT_FWD, 8.0)
		await frames(3)
		var a0: float = sk.vel.length()
		await frames(30)
		var coast: float = a0 - sk.vel.length()
		sk.spawn(FLAT_POS, FLAT_FWD, 8.0)
		await frames(3)
		var b0: float = sk.vel.length()
		press("down", true, i)
		await frames(30)
		var braked: float = b0 - sk.vel.length()
		press("down", false, i)
		check(braked > coast + 1.5, "%s holding %s (down) brakes" % [DEV(), bind_name("down", i)],
				"speed lost in 0.5 s: coasting %.2f, braking %.2f m/s" % [coast, braked])
	for d in [["left", 1.0], ["right", -1.0]]:
		for i in binds(d[0]).size():
			await settle()
			sk.spawn(FLAT_POS, FLAT_FWD, 6.0)
			await frames(3)
			var h0: Vector3 = sk.heading
			press(d[0], true, i)
			await frames(30)
			press(d[0], false, i)
			var ang: float = h0.signed_angle_to(sk.heading, Vector3.UP)
			check(ang * float(d[1]) > 0.5, "%s holding %s (%s) turns the heading %s" % [DEV(), bind_name(d[0], i), d[0], d[0]],
					"turned %.2f rad (+ = left)" % ang)


func jump_check() -> void:
	await settle()
	sk.spawn(FLAT_POS, FLAT_FWD, 4.0)
	await frames(5)
	press("jump", true)
	await frames(12)
	var c := clip()
	var crouch: bool = Input.is_action_pressed("jump") and sk.crouch_t > 0.0 and sk.state == sk.GROUND and c == "crouch"
	check(crouch, "%s holding %s (jump) crouches to charge the ollie" % [DEV(), bind_name("jump")],
			"crouch_t=%.2f state=%d clip=%s" % [sk.crouch_t, sk.state, c])
	press("jump", false)
	var air: bool = await wait_until(func(): return sk.state == sk.AIR, 6)
	c = clip()
	check(air and sk.vel.y > 2.0 and c == "ollie", "%s releasing %s pops an ollie into AIR" % [DEV(), bind_name("jump")],
			"state=%d vy=%.2f clip=%s" % [sk.state, sk.vel.y, c])
	await settle()


func air_trick(button: String, dir: String, want: String, want_clip: String) -> void:
	## A real vert air off the halfpipe's west wall; button (+ direction) pressed on the way up.
	await settle()
	var label := "%s %s (%s)%s in the air" % [DEV(), bind_name(button), button,
			(" + %s (%s)" % [bind_name(dir), dir]) if dir != "" else " with no direction"]
	sk.spawn(HP_POS, HP_FWD, HP_SPEED)
	var air: bool = await wait_until(func(): return sk.state == sk.AIR, 150)
	if not air:
		check(false, label + " gives " + want, "never got airborne off the halfpipe wall (state=%d pos=%s)" % [sk.state, str(sk.global_position)])
		return
	await frames(3)
	var names := []
	var cb := func(n): names.append(n)
	sk.trick.connect(cb)
	if dir != "":
		press(dir, true)
		await frames(2)
	press(button, true)
	await frames(2)
	var got := last_trick()
	var c := clip()
	var p := playing()
	if dir != "":
		press(dir, false)          # a held left/right would keep spinning the skater
	var pts0: int = int(main.score.tricks[main.score.tricks.size() - 1]["points"]) if main.score.tricks.size() > 0 else 0
	if button == "grab":
		await frames(15)           # hold the grab
	var pts1: int = int(main.score.tricks[main.score.tricks.size() - 1]["points"]) if main.score.tricks.size() > 0 else 0
	press(button, false)
	await wait_until(func(): return sk.state != sk.AIR, 150)
	var st: int = sk.state
	await frames(25)
	sk.trick.disconnect(cb)
	var banked := Array(main.score.last_combo)
	var extra := ""
	if button == "grab":
		extra = ", grab points %d -> %d while held" % [pts0, pts1]
	check(names.size() > 0 and names[0] == want and got == want and c == want_clip and p == want_clip,
			"%s gives %s in the combo and plays the '%s' clip" % [label, want, want_clip],
			"trick signals %s, combo last %s, clip %s / playing %s%s" % [str(names), got, c, p, extra])
	check(st == sk.GROUND and banked.has(want), "%s: the %s lands clean and the combo banks" % [label, want],
			"state after air=%d, banked combo %s" % [st, str(banked)])


func spin_check(action: String, sign_want: float) -> void:
	## A standing ollie (full crouch) with a spin input held for half a second in the air.
	await settle()
	var label := "%s %s (%s) in the air" % [DEV(), bind_name(action), action]
	sk.spawn(FLAT_POS, FLAT_FWD, 0.0)
	await frames(5)
	press("jump", true)
	await frames(30)
	press("jump", false)
	var air: bool = await wait_until(func(): return sk.state == sk.AIR, 10)
	var f0: Vector3 = sk.face_fwd
	press(action, true)
	await frames(15)
	var mid: float = f0.signed_angle_to(sk.face_fwd, Vector3.UP)
	await frames(15)
	press(action, false)
	await wait_until(func(): return sk.state != sk.AIR, 90)
	var st: int = sk.state
	var deg: float = sk.spin_deg
	var want: String = TR.spin_name(deg)
	var got := last_trick()
	await frames(25)
	var banked := Array(main.score.last_combo)
	check(air and signf(mid) == sign_want and signf(deg) == sign_want and absf(deg) >= 155.0,
			"%s spins the skater %s" % [label, "left (counter-clockwise)" if sign_want > 0 else "right (clockwise)"],
			"after 0.25 s %.0f deg, whole air %.0f deg" % [rad_to_deg(mid), deg])
	check(st == sk.GROUND and want != "" and got == want and banked.has(want), "%s scores the spin (%s)" % [label, want],
			"state=%d combo last '%s' banked %s" % [st, got, str(banked)])


func grind_check(dir: String, want: String, want_clip: String) -> void:
	await settle()
	var label := "%s %s (grind)%s near the rail" % [DEV(), bind_name("grind"),
			(" + %s (%s)" % [bind_name(dir), dir]) if dir != "" else ""]
	sk.spawn(RAIL_POS, FLAT_FWD, 7.0)
	await frames(24)
	await tap("jump")
	if dir != "":
		press(dir, true)
	press("grind", true)
	var ok: bool = await wait_until(func(): return sk.state == sk.GRIND, 45)
	if dir != "":
		press(dir, false)
	var rail: String = sk.grind_rail.name if ok and sk.grind_rail else ""
	var got: String = String(sk.grind_info.get("name", "")) if ok else ""
	var last := last_trick()
	var c := clip()
	var p := playing()
	press("grind", false)
	check(ok and rail == "long_rail" and got == want and last == want, "%s snaps into GRIND as a %s" % [label, want],
			"state=%d rail=%s grind=%s combo last=%s" % [sk.state, rail, got, last])
	check(ok and c == want_clip and p == want_clip, "%s plays the '%s' clip" % [label, want_clip], "clip %s / playing %s" % [c, p])
	await frames(8)
	await tap("jump")                  # hop off the rail
	await settle()


func manual_check(first: String, second: String, kind: String, want: String, want_clip: String) -> void:
	await settle()
	var label := "%s tapping %s then %s (%s, %s)" % [DEV(), bind_name(first), bind_name(second), first, second]
	sk.spawn(FLAT_POS, FLAT_FWD, 5.0)
	await frames(10)
	await tap(first)
	press(second, true)
	await frames(2)
	press(second, false)
	await frames(1)
	var m: String = sk.manual
	var last := last_trick()
	var c := clip()
	check(sk.state == sk.GROUND and m == kind and last == want and c == want_clip,
			"%s starts a %s (clip '%s')" % [label, want, want_clip],
			"state=%d manual='%s' combo last '%s' clip %s" % [sk.state, m, last, c])
	await tap("jump")                  # ollie out of the manual (keeps the combo) and land it
	await settle()


func special_attempt() -> Dictionary:
	## Left, Right + Flip early in a vert air off the halfpipe wall.
	sk.spawn(HP_POS, HP_FWD, HP_SPEED)
	var r := {}
	r["air"] = await wait_until(func(): return sk.state == sk.AIR, 150)
	var names := []
	var cb := func(n): names.append(n)
	sk.trick.connect(cb)
	await frames(2)
	await tap("left", 0, 2, 1)
	await tap("right", 0, 2, 1)
	press("flip", true)
	await frames(2)
	r["last"] = last_trick()
	r["clip"] = clip()
	r["playing"] = playing()
	press("flip", false)
	await wait_until(func(): return sk.state != sk.AIR, 150)
	r["state"] = sk.state
	await frames(25)
	r["banked"] = Array(main.score.last_combo)
	sk.trick.disconnect(cb)
	r["names"] = names
	return r


func special_check() -> void:
	var seq := "%s, %s + %s" % [bind_name("left"), bind_name("right"), bind_name("flip")]
	await settle()
	var empty_ready: bool = main.score.special_ready
	var r0 := await special_attempt()
	check(not empty_ready and r0["air"] and r0["names"].size() > 0 and not r0["names"].has(SPECIAL_NAME),
			"%s with the special meter not full, %s is a regular flip (%s)" % [DEV(), seq, ", ".join(r0["names"])],
			"special_ready=%s names=%s" % [empty_ready, str(r0["names"])])
	await settle()
	# fill the meter through the scoring rules (landed combos fill it; test_scoring covers the rates)
	var n := 0
	while not main.score.special_ready and n < 30:
		main.score.begin_trick("meter fill", 4500)
		main.score.land()
		n += 1
	var ready: bool = main.score.special_ready
	var r := await special_attempt()
	check(ready and r["air"] and r["names"].has(SPECIAL_NAME) and r["last"] == SPECIAL_NAME and r["clip"] == "special" and r["playing"] == "special",
			"%s with the special meter full, %s (left, right + flip) performs the special '%s' and plays the 'special' clip" % [DEV(), seq, SPECIAL_NAME],
			"ready=%s names=%s combo last=%s clip=%s playing=%s" % [ready, str(r["names"]), r["last"], r["clip"], r["playing"]])
	check(r["state"] == sk.GROUND and r["banked"].has(SPECIAL_NAME), "%s the special lands clean and the combo banks" % DEV(),
			"state=%d banked=%s" % [r["state"], str(r["banked"])])
	await settle()


func quick_trick() -> void:
	## A standing ollie + flip with this device, to have points on the board.
	await settle()
	sk.spawn(FLAT_POS, FLAT_FWD, 0.0)
	await frames(5)
	press("jump", true)
	await frames(30)
	press("jump", false)
	await frames(3)
	await tap("flip")
	await settle()


func menus_flow() -> void:
	var m = main.menus
	await settle()
	sk.spawn(FLAT_POS, FLAT_FWD, 5.0)
	await frames(10)
	var np: int = binds("pause").size()
	var nc: int = binds("confirm").size()
	for i in maxi(np, nc):
		var pi := i % np
		var ci := i % nc
		await tap("pause", pi)
		var p_ok: bool = paused and m.mode == m.PAUSE
		var pos: Vector3 = sk.global_position
		var tl: float = main.time_left
		await frames(20)
		var frozen: bool = sk.global_position == pos and main.time_left == tl
		check(p_ok and frozen, "%s %s (pause) pauses the tree and opens the pause menu (skater and clock frozen)" % [DEV(), bind_name("pause", pi)],
				"paused=%s mode=%d moved=%.3f dt=%.3f" % [paused, m.mode, (sk.global_position - pos).length(), tl - main.time_left])
		await frames(15)
		await tap("confirm", ci)
		var r_ok: bool = not paused and m.mode == m.NONE
		var tl2: float = main.time_left
		await frames(20)
		check(r_ok and main.time_left < tl2, "%s %s (confirm) resumes from the pause menu" % [DEV(), bind_name("confirm", ci)],
				"paused=%s mode=%d clock %.2f -> %.2f" % [paused, m.mode, tl2, main.time_left])
		await settle()
	# pause again inside the pause menu resumes
	await tap("pause")
	var p1: bool = paused and m.mode == m.PAUSE
	await frames(30)
	await tap("pause")
	check(p1 and not paused and m.mode == m.NONE, "%s %s (pause) again in the pause menu resumes" % [DEV(), bind_name("pause")],
			"first press paused=%s, after second paused=%s mode=%d" % [p1, paused, m.mode])
	# restart during the run
	await settle()
	if main.score.total == 0:
		await quick_trick()
	await frames(30)
	var s0: int = main.score.total
	var t0: float = main.time_left
	await tap("restart")
	var dist: float = sk.global_position.distance_to(main.level.spawn_pos)
	check(s0 > 0 and t0 < RUN_TIME - 0.4 and main.running and not paused and main.score.total == 0 and main.time_left > RUN_TIME - 0.2 and dist < 1.0,
			"%s %s (restart) during the run restarts it: score, timer and position reset" % [DEV(), bind_name("restart")],
			"score %d -> %d, clock %.2f -> %.2f, %.2f m from spawn" % [s0, main.score.total, t0, main.time_left, dist])
	# restart from the pause menu
	await quick_trick()
	await frames(30)
	s0 = main.score.total
	t0 = main.time_left
	await tap("pause")
	var p2: bool = paused and m.mode == m.PAUSE
	await frames(30)
	await tap("restart")
	check(p2 and s0 > 0 and not paused and m.mode == m.NONE and main.running and main.score.total == 0 and main.time_left > RUN_TIME - 0.2,
			"%s %s (restart) in the pause menu restarts the run: score and timer reset" % [DEV(), bind_name("restart")],
			"paused first=%s, score %d -> %d, clock %.2f -> %.2f, mode %d" % [p2, s0, main.score.total, t0, main.time_left, m.mode])
	# end of the run: confirm on the end screen starts a new one
	await settle()
	main.time_left = 0.3
	var ended: bool = await wait_until(func(): return m.mode == m.END and paused, 240)
	await frames(70)
	await tap("confirm")
	check(ended and main.running and not paused and m.mode == m.NONE and main.time_left > RUN_TIME - 0.2,
			"%s %s (confirm) on the end-of-run screen starts a new run" % [DEV(), bind_name("confirm")],
			"end screen=%s running=%s paused=%s clock %.2f" % [ended, main.running, paused, main.time_left])
