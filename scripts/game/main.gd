extends Node3D
## Game flow for a THPS-style two-minute run: the start screen (a menu: resume the saved
## game, start a new one, level select, customize character, controls), the run (timer,
## goals, HUD), pause, end-of-run screen and restart. The level and its goals are data
## (LevelRegistry: res://levels/<id>/level.json); the Warehouse is the default. Goals a player
## finishes are saved (Progress, scripts/game/progress.gd) and stay done in later runs.

const RUN_TIME := 120.0
const HIGH_SCORE := 25000        # the Warehouse's (each level's is its "score" goal target)
const LEVEL_SELECT := preload("res://scenes/level_select.tscn")

@onready var level: Level = $Level
@onready var skater: Skater = $Skater
@onready var cam: ChaseCamera = $Camera
@onready var hud: Hud = $HUD
@onready var menus: Menus = $Menus
@onready var sun: DirectionalLight3D = $Sun
@onready var env: WorldEnvironment = $WorldEnvironment

var score := ScoreKeeper.new()
var time_left := RUN_TIME
var running := false
var ending := false
var letters := {}
var goals: Array = []
var stats := {"tricks": 0, "bails": 0, "longest_grind": 0.0}
var _grind_start := 0.0
var autopilot_mode := ""
var high_score := HIGH_SCORE
var switching := false           # a level is being loaded (level select)
var _env_default: Dictionary = {}
var _grind_goal_t := 0.0
var run_start_phys := 0          # Engine physics frame count when the current run started
var bench: Node = null        # scripts/game/bench.gd while benchmarking (?bench / --bench)
var replay: Replay            # the instant replay shown from the end screen
var career := false           # this launch reads and writes the saved game (Progress.enabled)
## Adaptive quality: a slower GPU (a laptop) steps down until frames fit in ~16.7 ms.
var quality := 0
var _q_window: PackedFloat32Array = []
var _q_auto := true
const QUALITY_STEPS := ["full", "no SSAO", "MSAA 2x + 85% scale", "70% scale"]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for n in [level, skater, cam]:
		n.process_mode = Node.PROCESS_MODE_PAUSABLE
	_env_default = _env_snapshot()
	_apply_level_look()
	skater.setup(level, score)
	cam.skater = skater
	hud.bind(score)
	_make_goals()
	hud.set_goals(goals)
	hud.set_letters(letters)
	level.letter_collected.connect(_on_letter)
	level.tape_collected.connect(_on_tape)
	level.window_broken.connect(_on_window)
	level.wall_broken.connect(func(): hud.flash("SECRET ROOM!", "The boarded wall is down"))
	level.item_broken.connect(_on_item_broken)
	level.gap_hit.connect(_on_gap)
	skater.rafter_grind.connect(_on_rafter)
	skater.trick.connect(func(_n): stats["tricks"] += 1)
	skater.bailed.connect(_on_bail)
	skater.balance_changed.connect(hud.set_balance)
	skater.state_changed.connect(_on_state)
	score.combo_landed.connect(func(_p): _check_score())
	menus.start_pressed.connect(new_game)
	menus.continue_pressed.connect(continue_game)
	menus.main_menu_pressed.connect(main_menu)
	menus.quit_pressed.connect(quit_game)
	menus.resume_pressed.connect(resume)
	menus.restart_pressed.connect(restart)
	menus.level_select_pressed.connect(open_level_select)
	menus.skater_pressed.connect(open_skater_screen)
	replay = Replay.new()
	replay.name = "Replay"
	add_child(replay)
	replay.setup(self)
	menus.replay_pressed.connect(func():
		menus.hide_all()
		replay.play())
	replay.finished.connect(func(): menus.show_end(goals, score, stats, String(level.game.get("cleared", "Warehouse cleared")), skater.model.choice, replay.available()))
	print("[skater] skating as %s" % SkaterOutfit.to_arg(skater.model.choice))
	skater.spawn(level.spawn_pos, level.spawn_forward)
	cam.snap()
	level.warm_up(cam.global_position, -cam.global_basis.z)
	hud.warm_glyphs()
	# fixed-step movie recording and headless runs have no real frame times to adapt to
	_q_auto = Engine.get_write_movie_path() == "" and DisplayServer.get_name() != "headless"
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--autopilot"):
			autopilot_mode = a.get_slice("=", 1) if "=" in a else "run"
		if a == "--fps":
			hud.fps_label.visible = true
		if a.begins_with("--bench"):
			_start_bench(" ".join(args))
		if a == "--quality=full":
			_q_auto = false
	career = Progress.enabled(autopilot_mode)
	if OS.has_feature("web"):
		var q = JavaScriptBridge.eval("window.location.search", true)
		if q is String and "autopilot" in q:
			autopilot_mode = "run"
		if q is String and "fps" in q:
			hud.fps_label.visible = true
		if q is String and "quality=full" in q:
			_q_auto = false
		if q is String and "bench" in q:
			_start_bench(q)
			if "benchreport" in q:
				# only the local benchmark server (tests/bench_server.py) takes these reports
				JavaScriptBridge.eval("fetch('bench-start?' + innerWidth + 'x' + innerHeight + '@' + devicePixelRatio).catch(function(){})")
	# a level asked for at startup whose assets are not here yet (a web pack): fetch it first.
	# Without one, the saved game opens on the level played last.
	var want := LevelRegistry.startup_id()
	if career and want == LevelRegistry.default_id() and LevelRegistry.has(Progress.last_level()):
		want = Progress.last_level()
	if career:
		_make_goals()                # with the goals the saved game has done
		hud.set_goals(goals)
	if want != level.level_id:
		get_tree().paused = true
		await switch_level(want)
	if autopilot_mode != "":
		# the scripted run skips the start screen, which is where shaders get compiled
		# for a player: give the first frames the same half second before the run starts
		await get_tree().create_timer(0.5).timeout
		skater.spawn(level.spawn_pos, level.spawn_forward)
		cam.snap()
		var ap := preload("res://scripts/game/autopilot.gd").new()
		ap.name = "Autopilot"
		add_child(ap)
		ap.setup(self)
		skater.autopilot = ap
		skater.bailed.connect(func(r): ap.note("BAIL (%s) at %s" % [r, str(skater.global_position.snapped(Vector3.ONE * 0.1))]))
		level.letter_collected.connect(func(l): ap.note("letter " + l))
		level.tape_collected.connect(func(): ap.note("secret tape"))
		level.window_broken.connect(func(i, n): ap.note("window %d (%d/5)" % [i, n]))
		level.item_broken.connect(func(id, grp, n, tot): ap.note("broke %s (%s %d/%d)" % [id, grp, n, tot]))
		level.gap_hit.connect(func(id, nm, pts): ap.note("GAP %s (+%d)" % [nm, pts]))
		level.wall_broken.connect(func(): ap.note("wall broken"))
		skater.rafter_grind.connect(func(): ap.note("rafter grind"))
		score.combo_landed.connect(func(p): ap.note("combo +%d  total %d  [%s]" % [p, score.total, " + ".join(score.last_combo)]))
		score.special_full.connect(func(): ap.note("special meter full"))
		start_run()
	else:
		get_tree().paused = true
		_compile_unpaused()
		hud.visible = false
		_show_start()


func _show_start(pick := "") -> void:
	var done := 0
	for g in goals:
		if g["done"]:
			done += 1
	var c: Dictionary = skater.model.choice
	var info := {
		"saved": career and Progress.exists(),
		"goals_done": done,
		"goals_total": goals.size(),
		"best": Progress.best_score(level.level_id) if career else 0,
		"blurb": String(level.game.get("blurb", "")),
		"skater": "%s,  %s" % [SkaterOutfit.label("body", c["body"]), SkaterOutfit.label("top", c["top"])],
		"quit": get_node_or_null("/root/Desktop") != null,
	}
	if pick != "":
		info["select"] = pick
	menus.show_start(goals, String(level.game.get("name", "The Warehouse")), info)


func new_game() -> void:
	## Start new game: the saved game is cleared (the menu has asked first), then a run.
	if career:
		Progress.clear()
	restart()


func continue_game() -> void:
	## Resume game: a run on this level, with the goals the saved game has done ticked.
	restart()


func main_menu() -> void:
	## From the pause menu or the end screen: the run is left (its finished goals are
	## already saved) and the start screen comes back over a fresh level.
	running = false
	ending = false
	get_tree().paused = true
	hud.visible = false
	replay.clear()
	_reset_run()
	print("[run] left for the main menu")
	_show_start()


func quit_game() -> void:
	## The start screen's Quit (only offered in the Windows build, desktop/desktop.gd).
	var d := get_node_or_null("/root/Desktop")
	if d:
		d.quit_game.call()
	else:
		get_tree().quit()


func _make_goals() -> void:
	## The goals of the current level (levels/<id>/level.json), in the THPS style: a high
	## score, S-K-A-T-E, the secret tape and the level's own (grind this, break those, hit
	## that gap).
	letters = {}
	for L in level.data.get("letters", []):
		letters[String(L["letter"])] = false
	goals = []
	var saved: Array = Progress.done_goals(level.level_id) if career else []
	for gd in level.game.get("goals", []):
		var t := String(gd.get("type", gd["id"]))
		var title := String(gd.get("title", ""))
		var prog := ""
		match t:
			"score":
				high_score = int(gd.get("target", HIGH_SCORE))
				if title == "":
					title = "High Score: %s" % ScoreKeeper.format_points(high_score)
			"letters":
				prog = "0/%d" % letters.size()
			"windows", "break":
				prog = "0/%d" % int(gd.get("count", 5))
		var done := String(gd["id"]) in saved
		goals.append({"id": String(gd["id"]), "type": t, "title": title, "done": done, "progress": "" if done else prog, "def": gd})


func _goal(id: String) -> Dictionary:
	for g in goals:
		if g["id"] == id:
			return g
	return {}


func _complete(id: String) -> void:
	var g := _goal(id)
	if g.is_empty() or g["done"]:
		return
	g["done"] = true
	if career:
		Progress.mark_done(level.level_id, id)
	hud.update_goals(goals)
	hud.flash("GOAL COMPLETE", String(g["title"]), 2.6)
	Sfx.play("goal")
	var all_done := true
	for x in goals:
		all_done = all_done and x["done"]
	if all_done:
		hud.flash("ALL GOALS COMPLETE!", String(level.game.get("cleared", "Warehouse cleared")), 3.0)


func start_run() -> void:
	menus.hide_all()
	hud.visible = true
	get_tree().paused = false
	running = true
	ending = false
	time_left = RUN_TIME
	run_start_phys = Engine.get_physics_frames()
	replay.clear()
	if career:
		Progress.started(level.level_id)
	print("[run] started")      # (the menu that started the run already played its confirm blip)


func open_skater_screen() -> void:
	## The character builder: the skater it saves is rebuilt on the spot and skates the run.
	var b: SkaterBuilder = preload("res://scenes/ui/skater_builder.tscn").instantiate()
	b.start(skater.model.choice)
	menus.hide_all()
	add_child(b)
	b.closed.connect(func(saved: bool, c: Dictionary):
		if saved and c != skater.model.choice:
			skater.model.rebuild(c)
			skater.spawn(level.spawn_pos, level.spawn_forward)
			cam.snap()
		_show_start())                   # back on the play choice


func resume() -> void:
	menus.hide_all()
	get_tree().paused = false
	print("[run] resumed at %.1f s left" % time_left)


func restart() -> void:
	_reset_run()
	start_run()


func _reset_run() -> void:
	## The level, score, goals and skater back to the start of a run.
	level.clear_blood()
	score.reset()
	level.reset_run()
	_make_goals()
	hud.set_goals(goals)
	hud.set_letters(letters)
	stats = {"tricks": 0, "bails": 0, "longest_grind": 0.0}
	skater.spawn(level.spawn_pos, level.spawn_forward)
	cam.snap()


func _process(delta: float) -> void:
	hud.set_time(time_left)
	if running and not get_tree().paused:
		_adapt_quality(delta)
	if not running or get_tree().paused:
		if running and menus.mode == Menus.NONE and Input.is_action_just_pressed("pause"):
			pass
		return
	if Input.is_action_just_pressed("pause") and autopilot_mode == "":
		get_tree().paused = true
		menus.show_pause(goals, score)
		print("[run] paused at %.1f s left" % time_left)
		return
	if Input.is_action_just_pressed("restart") and autopilot_mode == "":
		restart()
		return
	# vert airs off the east quarter, or a grind along the wall pipe right below the glass
	level.check_windows(skater.global_position, skater.state == Skater.AIR or skater.state == Skater.GRIND, skater.vel)
	level.check_items(skater.global_position, skater.vel)
	_check_grind_goals()
	if not ending:
		time_left -= delta
		if time_left <= 0.0:
			time_left = 0.0
			ending = true
			hud.flash("TIME'S UP", "Land it!", 1.8)
	else:
		# the run ends once the last combo is landed or lost
		if skater.state == Skater.GROUND and not score.in_combo or skater.state == Skater.BAIL:
			_finish()


func _finish() -> void:
	running = false
	ending = false
	if skater.state == Skater.GROUND and score.in_combo:
		score.land()
	_check_score()
	if career:
		Progress.record_score(level.level_id, score.total)
	get_tree().paused = true
	hud.visible = false
	menus.show_end(goals, score, stats, String(level.game.get("cleared", "Warehouse cleared")), skater.model.choice, replay.available())
	print("[run] finished score=%d goals=%s" % [score.total, str(goals.map(func(g): return [g["id"], g["done"]]))])
	if bench:
		bench.report()
	if autopilot_mode == "test":
		print("[run] frames: process=%d physics=%d" % [Engine.get_process_frames(), Engine.get_physics_frames()])
		print("[run] clips played: %s" % str(skater.model.played))
		get_tree().quit()


func _adapt_quality(delta: float) -> void:
	if not _q_auto or quality >= QUALITY_STEPS.size() - 1:
		return
	_q_window.append(delta * 1000.0)
	if _q_window.size() < 150:
		return
	var sorted := Array(_q_window)
	sorted.sort()
	var median: float = sorted[sorted.size() / 2]
	_q_window.clear()
	if median <= 18.0:
		return
	quality += 1
	match quality:
		1:
			env.environment.ssao_enabled = false
		2:
			get_viewport().msaa_3d = Viewport.MSAA_2X
			get_viewport().scaling_3d_scale = 0.85
		3:
			get_viewport().scaling_3d_scale = 0.7
	print("[quality] median frame %.1f ms -> %s" % [median, QUALITY_STEPS[quality]])


func _start_bench(query: String) -> void:
	if bench:
		return
	_q_auto = false            # measure one fixed quality level
	hud.fps_label.visible = true
	bench = preload("res://scripts/game/bench.gd").new()
	bench.name = "Bench"
	bench.main = self
	add_child(bench)
	bench.setup(query)


func _check_score() -> void:
	if score.total >= high_score:
		_complete("score")
	var g := _goal("score")
	g["progress"] = "" if g["done"] else ScoreKeeper.format_points(score.total)
	hud.update_goals(goals)


func _on_letter(l: String) -> void:
	letters[l] = true
	hud.set_letters(letters)
	var n := 0
	for k in letters:
		if letters[k]:
			n += 1
	var g := _goal("skate")
	g["progress"] = "%d/%d" % [n, letters.size()]
	hud.update_goals(goals)
	hud.flash(l, "", 0.9)
	if n == letters.size():
		_complete("skate")


func _on_tape() -> void:
	_complete("tape")


func _on_window(_i: int, total: int) -> void:
	var g := _goal("windows")
	g["progress"] = "%d/5" % total
	hud.update_goals(goals)
	cam.shake = 0.6
	if total >= 5:
		_complete("windows")


func _on_rafter() -> void:
	_complete("rafters")


func _on_bail(_reason: String) -> void:
	stats["bails"] += 1
	cam.shake = 0.8


func _on_state(st: int) -> void:
	# gaps: where the skater left the ground (or a rail) and where he came down
	if st == Skater.AIR:
		level.skater_took_off(skater.global_position)
	elif st == Skater.GROUND:
		level.skater_landed(skater.global_position)
	elif st == Skater.BAIL:
		level.skater_bailed()
	if st == Skater.GRIND:
		_grind_start = Time.get_ticks_msec() / 1000.0
	elif _grind_start > 0.0:
		stats["longest_grind"] = maxf(stats["longest_grind"], Time.get_ticks_msec() / 1000.0 - _grind_start)
		_grind_start = 0.0


# ------------------------------------------------------------------ level goals (any level)

func _on_item_broken(_id: String, group: String, n: int, total: int) -> void:
	for g in goals:
		if g["type"] == "break" and String(g["def"].get("group", "")) == group and not g["done"]:
			var need := int(g["def"].get("count", total))
			g["progress"] = "%d/%d" % [mini(n, need), need]
			hud.update_goals(goals)
			if n >= need:
				_complete(g["id"])
			else:
				hud.flash("%d / %d" % [n, need], String(g["title"]), 1.2)
	cam.shake = maxf(cam.shake, 0.25)


func _on_gap(id: String, gap_name: String, points: int) -> void:
	## THPS gaps: the gap's name and points join the combo that is landing.
	score.begin_trick(gap_name, points)
	hud.flash(gap_name.to_upper(), "+%d GAP" % points, 1.4)
	Sfx.play("combo", null, -4.0, 0.8)
	for g in goals:
		if g["type"] == "gap" and String(g["def"].get("gap", "")) == id:
			_complete(g["id"])


func _check_grind_goals() -> void:
	## "Grind the X": hold a grind on one of the goal's rails (by name or tag) long enough.
	if skater.state != Skater.GRIND or skater.grind_rail == null:
		return
	for g in goals:
		if g["type"] != "grind" or g["done"]:
			continue
		var d: Dictionary = g["def"]
		var r: Rail = skater.grind_rail
		if r.name in d.get("rails", []) or (d.has("tag") and r.tag == String(d["tag"])):
			if skater.grind_t >= float(d.get("time", 1.0)):
				_complete(g["id"])


# ------------------------------------------------------------------ level select / switching

func open_level_select() -> void:
	## The start screen's level select (its own scene: scenes/level_select.tscn).
	if switching:
		return
	var ls := LEVEL_SELECT.instantiate()
	add_child(ls)
	menus.hide_all()
	ls.open(level.level_id, career)
	var pick: String = await ls.closed
	if pick != "" and pick != level.level_id:
		await switch_level(pick, ls)
	ls.queue_free()
	_show_start()                    # back on the play choice: Enter skates the level picked


func switch_level(id: String, screen: Node = null) -> bool:
	## Frees the current level and loads `id` (fetching its web pack first if it has one).
	## Everything else (skater, camera, HUD, menus) stays as it is.
	if not LevelRegistry.has(id) or switching:
		return false
	switching = true
	if not LevelRegistry.available(id):
		var ok: bool = await LevelRegistry.fetch_pack(id, self, func(got, total):
			if is_instance_valid(screen) and screen.has_method("progress"):
				screen.progress(got, total))
		if not ok:
			switching = false
			hud.flash("COULD NOT LOAD", String(LevelRegistry.game(id).get("name", id)), 2.5)
			return false
	running = false
	ending = false
	score.reset()
	replay.clear()
	level.load_level(id)
	_apply_level_look()
	_make_goals()
	hud.set_goals(goals)
	hud.set_letters(letters)
	stats = {"tricks": 0, "bails": 0, "longest_grind": 0.0}
	time_left = RUN_TIME
	skater.spawn(level.spawn_pos, level.spawn_forward)
	cam.snap()
	level.warm_up(cam.global_position, -cam.global_basis.z)
	await _compile_unpaused()
	switching = false
	print("[level] %s loaded" % id)
	return true


func _compile_unpaused() -> void:
	## In Chrome on Windows (ANGLE on Direct3D 11), the first frames the game runs unpaused
	## build about 50 more shader executables than the paused start screen does: a 20 s
	## freeze on a first visit (before the browser has them cached), in the first frame of the
	## first run. Run a few frames unpaused behind the start or loading screen instead, with
	## the skater held at its spawn. (Measured: tests/results/bench_levels_1080p.jsonl.)
	if not OS.has_feature("web") or not get_tree().paused:
		return
	get_tree().paused = false
	for i in 3:
		await get_tree().process_frame
	if not running:
		get_tree().paused = true
		skater.spawn(level.spawn_pos, level.spawn_forward)
		cam.snap()


func _env_snapshot() -> Dictionary:
	var e: Environment = env.environment
	return {"ambient_color": e.ambient_light_color, "ambient_energy": e.ambient_light_energy, "fog_color": e.fog_light_color,
			"fog_density": e.fog_density, "exposure": e.tonemap_exposure, "background": e.background_color,
			"sun_color": sun.light_color, "sun_energy": sun.light_energy}


func _apply_level_look() -> void:
	## The sun matches the level's bake; the level can tune the ambient, fog, exposure and
	## sun (levels/<id>/level.json "environment"; the Warehouse keeps main.tscn's values).
	sun.look_at_from_position(Vector3.ZERO, level.sun_dir, Vector3.UP if absf(level.sun_dir.y) < 0.99 else Vector3.FORWARD)
	var o: Dictionary = level.game.get("environment", {})
	var e: Environment = env.environment
	var c := func(k: String) -> Color:
		var a: Array = o[k]
		return Color(a[0], a[1], a[2])
	e.ambient_light_color = c.call("ambient_color") if o.has("ambient_color") else _env_default["ambient_color"]
	e.ambient_light_energy = float(o.get("ambient_energy", _env_default["ambient_energy"]))
	e.fog_light_color = c.call("fog_color") if o.has("fog_color") else _env_default["fog_color"]
	e.fog_density = float(o.get("fog_density", _env_default["fog_density"]))
	e.tonemap_exposure = float(o.get("exposure", _env_default["exposure"]))
	e.background_color = c.call("background") if o.has("background") else _env_default["background"]
	sun.light_color = c.call("sun_color") if o.has("sun_color") else _env_default["sun_color"]
	sun.light_energy = float(o.get("sun_energy", _env_default["sun_energy"]))
