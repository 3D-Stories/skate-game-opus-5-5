extends SceneTree
## Which of the Blender-authored clips does the REAL game play? Three sources:
##  1. the autopilot test run (scripted two-minute run through the real skater code; runs as
##     a child process: --fixed-fps 60 -- --autopilot=test, main prints "[run] clips played")
##  2. tests/test_flow.gd (run as a child process through tests/flow_clips.gd, which is the
##     same test plus a print of the model's clip bookkeeping at exit)
##  3. this script: the real main scene driven only by injected keyboard / gamepad events
##     (Input.parse_input_event), one scenario per clip; a clip counts when the game itself
##     started it (skater_model.gd 'played' count went up) and the AnimationPlayer had it as
##     its current, playing clip for at least 3 frames.
## A required clip PASSes if at least one of these real game paths played it.
##   godot --headless --path . --fixed-fps 60 -s tests/test_clips_in_game.gd
##       -> tests/results/clips_in_game.txt

const REQUIRED := ["idle", "push", "ride", "crouch", "ollie", "kickflip", "heelflip", "shoveit", "treflip",
		"indy", "melon", "nosegrab", "tailgrab", "grind_5050", "boardslide", "manual", "nose_manual",
		"vert_air", "air", "land", "bail", "special", "ride_fakie", "getup"]
const MIN_FRAMES := 3
const FLAT := Vector3(0, 0, -24)          # open floor north of the funbox (test_flow uses it too)
const NORTH := Vector3(0, 0, -1)

var main: Node
var sk
var out: PackedStringArray = []
var passed := 0
var failed := 0
var seen := {}             # clip -> frames it was the AnimationPlayer's current clip (this scenario)
var tricks_seen: Array = []
var bails_seen: Array = []
var _p0 := {}
var inj := {}              # clip -> {"how", "frames", "tricks"}
var tried := {}            # clip -> what happened when we tried (for FAIL details)
var _axes := {JOY_AXIS_LEFT_X: 0.0, JOY_AXIS_LEFT_Y: 0.0}


func check(ok: bool, what: String, detail := "") -> void:
	if ok:
		passed += 1
		out.append("PASS  " + what)
	else:
		failed += 1
		out.append("FAIL  " + what + ("  (" + detail + ")" if detail != "" else ""))


func _initialize() -> void:
	_run.call_deferred()


# ------------------------------------------------------------------ input helpers

func step(n := 1) -> void:
	for i in n:
		await process_frame
		_sample()


func until(cond: Callable, max_frames: int) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await step(1)
	return cond.call()


func _sample() -> void:
	if sk == null:
		return
	var anim: AnimationPlayer = sk.model.anim
	if anim.is_playing():
		var a := String(anim.current_animation)
		seen[a] = int(seen.get(a, 0)) + 1


func key(k: int, down: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = k
	e.physical_keycode = k
	e.pressed = down
	Input.parse_input_event(e)


func tap(k: int, hold_frames := 2) -> void:
	key(k, true)
	await step(hold_frames)
	key(k, false)
	await step(2)


func stick(v: Vector2) -> void:
	## Left analog stick (x right, y up), only sent when it changes.
	var want := {JOY_AXIS_LEFT_X: clampf(v.x, -1.0, 1.0), JOY_AXIS_LEFT_Y: clampf(-v.y, -1.0, 1.0)}
	for a in want:
		if absf(float(want[a]) - float(_axes[a])) > 0.01:
			var e := InputEventJoypadMotion.new()
			e.device = 0
			e.axis = a
			e.axis_value = want[a]
			Input.parse_input_event(e)
			_axes[a] = want[a]


func release_all() -> void:
	for k in [KEY_W, KEY_A, KEY_S, KEY_D, KEY_SPACE, KEY_J, KEY_K, KEY_L, KEY_Q, KEY_E]:
		key(k, false)
	stick(Vector2.ZERO)


# ------------------------------------------------------------------ scenario bookkeeping

func place(pos: Vector3, fwd: Vector3, speed: float) -> void:
	release_all()
	sk.spawn(pos, fwd, speed)          # the game's own respawn
	await step(4)


func begin() -> void:
	seen = {}
	tricks_seen = []
	bails_seen = []
	_p0 = sk.model.played.duplicate()


func credit(clip: String, how: String, expect_trick := "") -> void:
	## The game started `clip` during this scenario (model 'played' count went up), it was the
	## AnimationPlayer's playing clip for MIN_FRAMES+ frames, and (for tricks) the skater
	## announced the expected trick name.
	var started := int(sk.model.played.get(clip, 0)) > int(_p0.get(clip, 0))
	var n := int(seen.get(clip, 0))
	var named := expect_trick == "" or expect_trick in tricks_seen
	var ok := started and n >= MIN_FRAMES and named
	if not inj.has(clip) and ok:
		inj[clip] = {"how": how, "frames": n, "tricks": ("game announced '%s'" % expect_trick) if expect_trick != "" else ""}
	if not inj.has(clip):
		tried[clip] = "%s: started=%s, on screen %d frames, expected trick '%s', tricks=[%s], bails=[%s], state=%d" % [
				how, str(started), n, expect_trick, ", ".join(PackedStringArray(tricks_seen)), ", ".join(PackedStringArray(bails_seen)), sk.state]


func grounded() -> bool:
	return sk.state == sk.GROUND


func airborne() -> bool:
	return sk.state == sk.AIR


# ------------------------------------------------------------------ child runs

func _child(args: PackedStringArray, marker: String) -> Dictionary:
	var output := []
	var code := OS.execute(OS.get_executable_path(), args, output, true)
	var text := "\n".join(PackedStringArray(output))
	var played := {}
	var found := false
	for line in text.split("\n"):
		var i := line.find(marker)
		if i >= 0:
			var parsed = JSON.parse_string(line.substr(i + marker.length()).strip_edges())
			if parsed is Dictionary:
				found = true
				for k in parsed:
					played[String(k)] = int(parsed[k])
	return {"exit": code, "played": played, "found": found, "text": text}


func _grep(text: String, needle: String) -> String:
	for line in text.split("\n"):
		if line.contains(needle):
			return line.strip_edges()
	return ""


# ------------------------------------------------------------------ scenarios

func sc_push_ride_idle() -> void:
	await place(FLAT, NORTH, 0.0)
	begin()
	key(KEY_W, true)
	await step(40)
	credit("push", "hold Up (W) from a standstill")
	key(KEY_W, false)
	await step(25)
	credit("ride", "let go of Up while rolling")
	key(KEY_S, true)
	await until(func(): return sk.vel.length() < 0.3, 150)
	await step(10)
	key(KEY_S, false)
	credit("idle", "hold Down (S) to brake to a stop")


func sc_crouch_ollie_land() -> void:
	await place(FLAT, NORTH, 5.0)
	begin()
	key(KEY_SPACE, true)
	await step(20)
	credit("crouch", "hold Jump (Space) while rolling")
	key(KEY_SPACE, false)
	await until(airborne, 10)
	await until(grounded, 120)
	credit("ollie", "release Jump")
	await step(12)
	credit("land", "clean landing of the ollie")


func _charged_ollie() -> void:
	key(KEY_SPACE, true)
	await step(30)
	key(KEY_SPACE, false)
	await until(airborne, 10)
	await step(2)


func sc_flip(clip: String, dir: int, how: String, trick_name: String) -> void:
	await place(FLAT, NORTH, 5.0)
	begin()
	await _charged_ollie()
	if dir != KEY_NONE:
		key(dir, true)
		await step(1)
	key(KEY_J, true)
	await step(3)
	key(KEY_J, false)
	if dir != KEY_NONE:
		key(dir, false)
	await until(func(): return not airborne(), 120)
	credit(clip, how, trick_name)
	if clip == "kickflip":
		credit("air", "flip finished before touchdown -> the game goes back to the air pose")
		await step(12)
		credit("land", "clean landing after the kickflip")
	await step(10)


func sc_grab(clip: String, dir: int, how: String, trick_name: String) -> void:
	await place(FLAT, NORTH, 5.0)
	begin()
	await _charged_ollie()
	if dir != KEY_NONE:
		key(dir, true)
		await step(1)
	key(KEY_K, true)
	await step(3)
	if dir != KEY_NONE:
		key(dir, false)
	await step(20)
	key(KEY_K, false)
	await until(func(): return not airborne(), 120)
	credit(clip, how, trick_name)
	await step(10)


func sc_manual(clip: String, first: int, second: int, how: String, trick_name: String) -> void:
	await place(FLAT, NORTH, 5.0)
	await step(10)
	begin()
	await tap(first)
	await tap(second)
	await step(20)
	credit(clip, how, trick_name)
	release_all()


func sc_grind(clip: String, dir: int, how: String, trick_name: String) -> void:
	# the long rail, as in test_flow: roll north beside it, ollie, hold Grind
	await place(Vector3(-12.0, 0.0, 4.0), NORTH, 7.0)
	await step(24)
	begin()
	await tap(KEY_SPACE)
	if dir != KEY_NONE:
		key(dir, true)
	key(KEY_L, true)
	await until(func(): return sk.state == sk.GRIND, 45)
	if dir != KEY_NONE:
		key(dir, false)          # let go at once: the stick also tips the grind balance
	await step(12)
	credit(clip, how, trick_name)
	key(KEY_L, false)
	await tap(KEY_SPACE)         # hop off
	await until(func(): return not airborne(), 120)
	await step(10)


func sc_bail() -> void:
	await place(FLAT, NORTH, 5.0)
	await step(5)
	begin()
	await tap(KEY_SPACE)         # a small ollie ...
	await until(airborne, 10)
	await step(26)
	await tap(KEY_J)             # ... and a kickflip far too late to finish before touchdown
	await until(func(): return sk.state == sk.BAIL, 60)
	await step(20)
	if "mid-trick" in bails_seen:
		credit("bail", "late kickflip on a small ollie, landed mid-flip -> bail (reason '%s')" % ", ".join(PackedStringArray(bails_seen)))
	else:
		tried["bail"] = "late kickflip on a small ollie: bails=[%s], state=%d" % [", ".join(PackedStringArray(bails_seen)), sk.state]
	# lying on the floor, the skater gets up with the board (the getup clip) and rides again
	await until(func(): return sk.model.current.begins_with("getup"), 420)
	await step(MIN_FRAMES + 4)
	# which getup plays depends on how the ragdoll came to rest (back: 'getup', front:
	# 'getup_front'); either one satisfies the getup requirement here, and test_ragdoll.gd
	# checks that both are used
	var gclip: String = sk.model.current
	credit(gclip, "after that bail the ragdoll settles, then the matching getup ('%s': %s) brings the skater back onto the board" % [
			gclip, "from the back" if gclip == "getup" else "from face down"])
	if gclip == "getup_front" and inj.has("getup_front") and not inj.has("getup"):
		inj["getup"] = (inj["getup_front"] as Dictionary).duplicate()
		inj["getup"]["how"] += " [the face-down variant 'getup_front' played this time]"
	await until(grounded, 200)
	await step(10)


func sc_fakie() -> void:
	await place(FLAT, NORTH, 6.0)
	await step(5)
	begin()
	await tap(KEY_SPACE)         # an ollie with a half turn (hold E) lands fakie
	await until(airborne, 10)
	key(KEY_E, true)
	await step(26)
	key(KEY_E, false)
	await until(grounded, 90)
	await step(30)               # coasting fakie: looks back over the shoulder
	credit("ride_fakie", "ollie with a 180 (E held), landed fakie and coasting (fakie=%s)" % str(sk.fakie))
	key(KEY_W, true)             # pushing turns the skater round first, then pushes regular
	await step(40)
	key(KEY_W, false)
	if sk.fakie:
		tried["ride_fakie"] = "pushing while fakie did not turn the skater round (still fakie)"
	await step(10)


## Halfpipe: vert airs with tricks until the special meter is full, then the special
## (Left, Right + Flip), all from injected input. Stick = left analog stick, buttons = keys.
## Trick plans per air: [keys, stick, start s after takeoff, hold s] (the autopilot's patterns).
const HP_Z := -43.0
var PLANS := [
	[[[KEY_J], Vector2.ZERO, 0.06, 0.06], [[KEY_K], Vector2(1, 0), 0.5, 0.05], [[KEY_K], Vector2.ZERO, 0.55, 0.3],
			[[KEY_Q], Vector2.ZERO, 0.3, 0.55]],
	[[[KEY_J], Vector2(0, 1), 0.06, 0.05], [[KEY_K], Vector2(0, -1), 0.6, 0.05], [[KEY_K], Vector2.ZERO, 0.65, 0.25]],
	[[[KEY_J], Vector2(1, 0), 0.06, 0.05], [[KEY_K], Vector2(0, 1), 0.52, 0.05], [[KEY_K], Vector2.ZERO, 0.57, 0.3],
			[[KEY_E], Vector2.ZERO, 0.3, 0.55]],
]
var SPECIAL_PLAN := [[[], Vector2(-1, 0), 0.04, 0.05], [[], Vector2(1, 0), 0.1, 0.05], [[KEY_J], Vector2(1, 0), 0.12, 0.05],
		[[KEY_K], Vector2(-1, 0), 1.0, 0.05]]


func sc_halfpipe() -> Dictionary:
	await place(Vector3(0.0, 0.0, HP_Z), Vector3(-1, 0, 0), 11.0)
	begin()
	var res := {"airs": 0, "vert_airs": 0, "specials": 0, "bails": 0, "meter_full_at_air": -1}
	var held := {}
	var in_air := false
	var t_air := 0
	var plan: Array = []
	for frame in 60 * 100:
		var want := {}
		var st := Vector2.ZERO
		if sk.state == sk.AIR:
			if not in_air:
				in_air = true
				t_air = 0
				var air_time: float = 2.0 * maxf(sk.vel.y, 0.0) / sk.G
				if not sk.vert_air or air_time < 0.95:
					plan = [[[KEY_K], Vector2.ZERO, 0.08, maxf(0.05, air_time - 0.35)]] if air_time > 0.6 else []
				elif main.score.special_ready:
					plan = SPECIAL_PLAN
				else:
					plan = PLANS[res["airs"] % PLANS.size()]
				if sk.vert_air:
					res["vert_airs"] += 1
			var dt := t_air / 60.0
			for e in plan:
				if dt >= float(e[2]) and dt < float(e[2]) + float(e[3]):
					for k in e[0]:
						want[k] = true
					st = e[1]
			t_air += 1
		elif sk.state == sk.GROUND:
			if in_air:
				in_air = false
				res["airs"] += 1
				if main.score.special_ready and res["meter_full_at_air"] < 0:
					res["meter_full_at_air"] = res["airs"]
			if sk.up.y > 0.93:
				# aim across the flat bottom, correcting drift along the halfpipe
				var side := signf(sk.vel.x) if absf(sk.vel.x) > 0.5 else -1.0
				var target := Vector3(side * 6.0, 0.0, HP_Z + (HP_Z - sk.global_position.z) * 2.0)
				var to: Vector3 = target - sk.global_position
				to.y = 0.0
				var h: Vector3 = sk.heading
				h.y = 0.0
				if h.length() > 0.1 and to.length() > 0.05:
					var a := atan2(h.normalized().cross(to.normalized()).y, h.normalized().dot(to.normalized()))
					st = Vector2(clampf(-a * 2.5, -1.0, 1.0), 1.0 if absf(a) < 0.9 else 0.0)
				else:
					st = Vector2(0, 1)
			else:
				st = Vector2(0, 1)       # pump the transitions
		elif sk.state == sk.BAIL:
			in_air = false
		for k in [KEY_J, KEY_K, KEY_Q, KEY_E]:
			var w := bool(want.get(k, false))
			if w != bool(held.get(k, false)):
				key(k, w)
				held[k] = w
		stick(st)
		await step(1)
		res["specials"] = int(sk.model.played.get("special", 0)) - int(_p0.get("special", 0))
		if res["specials"] > 0 and sk.state == sk.GROUND and not in_air:
			await step(20)
			break
		if main.time_left < 3.0:
			break
	res["bails"] = bails_seen.size()
	credit("vert_air", "roll across the halfpipe and up the walls past the coping (%d vert airs)" % res["vert_airs"])
	credit("special", "halfpipe vert airs with tricks until the special meter is full (after %d airs), then Left, Right + Flip" % res["meter_full_at_air"],
			"Tiger Claw Tre")
	release_all()
	return res


# ------------------------------------------------------------------ main

func _run() -> void:
	var proj := ProjectSettings.globalize_path("res://")
	# 1. the autopilot run
	var ap := _child(PackedStringArray(["--headless", "--path", proj, "--fixed-fps", "60", "--", "--autopilot=test"]),
			"[run] clips played: ")
	var fin := _grep(ap["text"], "[run] finished")
	check(ap["exit"] == 0 and ap["found"] and fin.contains("[\"windows\", true]") and not fin.contains("false"),
			"autopilot test run finished and reported its clips: %s" % fin.replace("[run] finished ", ""),
			"exit %d, clip report found=%s" % [ap["exit"], str(ap["found"])])
	# 2. the flow test
	var fl := _child(PackedStringArray(["--headless", "--path", proj, "--fixed-fps", "60", "-s", "res://tests/flow_clips.gd"]),
			"[flow] clips played: ")
	var fsum := ""
	for line in fl["text"].split("\n"):
		if line.contains(" passed, ") and line.contains(" failed"):
			fsum = line.strip_edges()
	check(fl["exit"] == 0 and fl["found"], "tests/test_flow.gd ran (%s) and reported its clips" % fsum,
			"exit %d, clip report found=%s" % [fl["exit"], str(fl["found"])])
	# 3. the real main scene, injected input only
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await step(5)
	sk = main.skater
	sk.trick.connect(func(n): tricks_seen.append(n))
	sk.bailed.connect(func(r): bails_seen.append(r))
	await step(30)                 # menus ignore input right after opening
	await tap(KEY_ENTER)
	await step(3)
	check(main.running and not paused, "Enter on the start screen starts the run (injected-input part)")
	var hp := await sc_halfpipe()
	# fresh run (restart key) for the flat-ground scenarios
	await tap(KEY_R)
	await step(5)
	await sc_push_ride_idle()
	await sc_crouch_ollie_land()
	await sc_flip("kickflip", KEY_NONE, "Flip (J) in the air, no direction", "Kickflip")
	await sc_flip("heelflip", KEY_D, "Flip (J) + Right (D) in the air", "Heelflip")
	await sc_flip("shoveit", KEY_S, "Flip (J) + Down (S) in the air", "Pop Shove-It")
	await sc_flip("treflip", KEY_W, "Flip (J) + Up (W) in the air", "360 Flip")
	await sc_grab("indy", KEY_NONE, "Grab (K) in the air, no direction", "Indy")
	await sc_grab("melon", KEY_A, "Grab (K) + Left (A) in the air", "Melon")
	await sc_grab("nosegrab", KEY_W, "Grab (K) + Up (W) in the air", "Nosegrab")
	await sc_grab("tailgrab", KEY_S, "Grab (K) + Down (S) in the air", "Tailgrab")
	await sc_grind("grind_5050", KEY_NONE, "ollie beside the long rail + hold Grind (L)", "50-50")
	await sc_grind("boardslide", KEY_A, "ollie beside the long rail + Grind (L) + Left (A)", "Boardslide")
	await sc_manual("manual", KEY_W, KEY_S, "tap Up, Down (W, S) while rolling", "Manual")
	await sc_manual("nose_manual", KEY_S, KEY_W, "tap Down, Up (S, W) while rolling", "Nose Manual")
	await sc_bail()
	await sc_fakie()
	# ---- per clip
	var ap_p: Dictionary = ap["played"]
	var fl_p: Dictionary = fl["played"]
	var n_inj := 0
	for c in REQUIRED:
		var paths: PackedStringArray = []
		var incl := " (count includes the idle at load / respawn)" if c == "idle" else ""
		if int(ap_p.get(c, 0)) > 0:
			paths.append("autopilot run x%d%s" % [int(ap_p[c]), incl])
		if int(fl_p.get(c, 0)) > 0:
			paths.append("test_flow x%d%s" % [int(fl_p[c]), incl])
		if inj.has(c):
			n_inj += 1
			var t: String = inj[c]["tricks"]
			paths.append("injected input: %s (%d frames on screen%s)" % [inj[c]["how"], inj[c]["frames"],
					(", " + t) if t != "" else ""])
		check(paths.size() > 0, "%-11s plays in real gameplay - %s" % [c, "; ".join(paths) if paths.size() > 0 else "none"],
				tried.get(c, "no path played it"))
	var notes: PackedStringArray = []
	notes.append("halfpipe (injected input): %d airs, %d vert airs, bails %d, special meter full after air %d, specials %d" % [
			hp["airs"], hp["vert_airs"], hp["bails"], hp["meter_full_at_air"], hp["specials"]])
	var missed: PackedStringArray = []
	for c in REQUIRED:
		if not inj.has(c):
			missed.append("%s (%s)" % [c, tried.get(c, "not attempted")])
	check(missed.is_empty(), "every required clip also played from injected keyboard / gamepad input alone (%d/%d)" % [n_inj, REQUIRED.size()],
			"; ".join(missed))
	var report := "Pro Skater clips in real gameplay  %s\n%s\n%d passed, %d failed\n" % [
			Time.get_datetime_string_from_system(), "\n".join(out), passed, failed]
	print(report)
	print("[clips] " + "\n[clips] ".join(notes))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/results"))
	var fh := FileAccess.open("res://tests/results/clips_in_game.txt", FileAccess.WRITE)
	fh.store_string(report)
	fh.close()
	quit(1 if failed > 0 else 0)
