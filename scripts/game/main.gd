extends Node3D
## Game flow for a THPS-style two-minute run in the Warehouse: start screen, the run
## (timer, goals, HUD), pause, end-of-run screen and restart.

const RUN_TIME := 120.0
const HIGH_SCORE := 25000

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
var run_start_phys := 0          # Engine physics frame count when the current run started
var bench: Node = null        # scripts/game/bench.gd while benchmarking (?bench / --bench)
## Adaptive quality: a slower GPU (a laptop) steps down until frames fit in ~16.7 ms.
var quality := 0
var _q_window: PackedFloat32Array = []
var _q_auto := true
const QUALITY_STEPS := ["full", "no SSAO", "MSAA 2x + 85% scale", "70% scale"]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for n in [level, skater, cam]:
		n.process_mode = Node.PROCESS_MODE_PAUSABLE
	# sun matches the Blender bake
	sun.look_at_from_position(Vector3.ZERO, level.sun_dir, Vector3.UP if absf(level.sun_dir.y) < 0.99 else Vector3.FORWARD)
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
	skater.rafter_grind.connect(_on_rafter)
	skater.trick.connect(func(_n): stats["tricks"] += 1)
	skater.bailed.connect(_on_bail)
	skater.balance_changed.connect(hud.set_balance)
	skater.state_changed.connect(_on_state)
	score.combo_landed.connect(func(_p): _check_score())
	menus.start_pressed.connect(start_run)
	menus.resume_pressed.connect(resume)
	menus.restart_pressed.connect(restart)
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
		level.wall_broken.connect(func(): ap.note("wall broken"))
		skater.rafter_grind.connect(func(): ap.note("rafter grind"))
		score.combo_landed.connect(func(p): ap.note("combo +%d  total %d  [%s]" % [p, score.total, " + ".join(score.last_combo)]))
		score.special_full.connect(func(): ap.note("special meter full"))
		start_run()
	else:
		get_tree().paused = true
		hud.visible = false
		menus.show_start(goals)


func _make_goals() -> void:
	letters = {"S": false, "K": false, "A": false, "T": false, "E": false}
	goals = [
		{"id": "score", "title": "High Score: %s" % ScoreKeeper.format_points(HIGH_SCORE), "done": false, "progress": ""},
		{"id": "skate", "title": "Collect S-K-A-T-E", "done": false, "progress": "0/5"},
		{"id": "tape", "title": "Find the Secret Tape", "done": false, "progress": ""},
		{"id": "rafters", "title": "Grind the Rafters", "done": false, "progress": ""},
		{"id": "windows", "title": "Break the 5 Windows", "done": false, "progress": "0/5"},
	]


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
	hud.update_goals(goals)
	hud.flash("GOAL COMPLETE", String(g["title"]), 2.6)
	Sfx.play("goal")
	var all_done := true
	for x in goals:
		all_done = all_done and x["done"]
	if all_done:
		hud.flash("ALL GOALS COMPLETE!", "Warehouse cleared", 3.0)


func start_run() -> void:
	menus.hide_all()
	hud.visible = true
	get_tree().paused = false
	running = true
	ending = false
	time_left = RUN_TIME
	run_start_phys = Engine.get_physics_frames()
	print("[run] started")      # (the menu that started the run already played its confirm blip)


func resume() -> void:
	menus.hide_all()
	get_tree().paused = false
	print("[run] resumed at %.1f s left" % time_left)


func restart() -> void:
	level.clear_blood()
	score.reset()
	level.reset_run()
	_make_goals()
	hud.set_goals(goals)
	hud.set_letters(letters)
	stats = {"tricks": 0, "bails": 0, "longest_grind": 0.0}
	skater.spawn(level.spawn_pos, level.spawn_forward)
	cam.snap()
	start_run()


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
	get_tree().paused = true
	hud.visible = false
	menus.show_end(goals, score, stats)
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
	if score.total >= HIGH_SCORE:
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
	g["progress"] = "%d/5" % n
	hud.update_goals(goals)
	hud.flash(l, "", 0.9)
	if n == 5:
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
	if st == Skater.GRIND:
		_grind_start = Time.get_ticks_msec() / 1000.0
	elif _grind_start > 0.0:
		stats["longest_grind"] = maxf(stats["longest_grind"], Time.get_ticks_msec() / 1000.0 - _grind_start)
		_grind_start = 0.0
