extends SceneTree
## Headless physics harness: runs the real main scene with a scripted input timeline and
## prints telemetry. Usage:
##   godot --headless --path . -s tests/sim.gd -- scenario=dropin
## Scenarios are lists of [time, action, pressed] plus optional "stick" entries.

var main: Node
var t := 0.0
var events: Array = []
var ei := 0
var duration := 8.0
var log_every := 0.25
var next_log := 0.0
var scenario := "dropin"
var start_pos = null
var start_fwd = null
var start_speed := 0.0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("scenario="):
			scenario = a.get_slice("=", 1)
	var scn: PackedScene = load("res://scenes/main.tscn")
	main = scn.instantiate()
	root.add_child(main)
	_setup_scenario()


func _setup_scenario() -> void:
	match scenario:
		"dropin":
			events = [[0.0, "up", true], [6.0, "up", false]]
			duration = 9.0
		"ollie":
			start_pos = Vector3(0, 0.0, -2.0)
			start_fwd = Vector3(0, 0, -1)
			start_speed = 6.0
			events = [[0.3, "jump", true], [0.6, "jump", false], [0.75, "flip", true], [0.8, "flip", false]]
			duration = 3.0
		"eastqp":
			start_pos = Vector3(4.0, 0.0, -18.0)
			start_fwd = Vector3(1, 0, 0)
			start_speed = 12.0
			events = [[0.0, "up", true], [1.25, "jump", true], [1.45, "jump", false]]
			duration = 4.0
			log_every = 0.1
		"halfpipe":
			start_pos = Vector3(0.0, 0.0, -43.0)
			start_fwd = Vector3(-1, 0, 0)
			start_speed = 9.5
			events = [[0.0, "up", true]]
			for k in 12:
				events.append([4.0 + k * 0.8, "grab", true])
				events.append([4.3 + k * 0.8, "grab", false])
			duration = 14.0
			log_every = 0.2
		"eastwall":
			start_pos = Vector3(19.5, 3.2, -43.0)
			start_fwd = Vector3(1, 0, 0)
			start_speed = 0.5
			events = [[0.0, "up", true]]
			duration = 2.0
			log_every = 0.05
		"wall":
			start_pos = Vector3(-15.0, 0.0, -36.6)
			start_fwd = Vector3(-1, 0, 0)
			start_speed = 7.0
			events = []
			duration = 2.0
			log_every = 0.1
		"letter_e":
			start_pos = Vector3(-9.0, 0.0, -23.0)
			start_fwd = Vector3(0, 0, -1)
			start_speed = 9.0
			events = []
			duration = 2.5
			log_every = 0.1
		"letter_s":
			start_pos = Vector3(0.0, 0.0, 1.0)
			start_fwd = Vector3(0, 0, -1)
			start_speed = 9.5
			events = []
			duration = 2.0
			log_every = 0.1
		"rail":
			start_pos = Vector3(-12.0, 0.0, 4.0)
			start_fwd = Vector3(0, 0, -1)
			start_speed = 7.0
			events = [[0.4, "jump", true], [0.6, "jump", false], [0.75, "grind", true], [0.85, "grind", false]]
			duration = 4.0
		"manual":
			start_pos = Vector3(0.0, 0.0, -2.0)
			start_fwd = Vector3(0, 0, -1)
			start_speed = 6.0
			events = [[0.3, "up", true], [0.35, "up", false], [0.4, "down", true], [0.45, "down", false]]
			duration = 3.0
		"catwalk":
			start_pos = Vector3(-18.8, 5.0, 2.0)
			start_fwd = Vector3(0, 0, -1)
			start_speed = 8.5
			events = [[0.0, "up", true], [2.4, "up", false], [3.3, "grind", true], [4.5, "grind", false]]
			duration = 7.0


func _process(delta: float) -> bool:
	if t == 0.0:
		main.start_run()
		if start_pos != null:
			main.skater.spawn(start_pos, start_fwd, start_speed)
		main.skater.bailed.connect(func(r): print("  BAIL: ", r, " at ", main.skater.global_position))
		main.skater.trick.connect(func(n): print("  TRICK: ", n, " t=", snappedf(t, 0.01)))
		main.score.combo_landed.connect(func(p): print("  LANDED COMBO +", p))
		main.level.window_broken.connect(func(i, n): print("  WINDOW ", i, " (", n, ")"))
		main.skater.rafter_grind.connect(func(): print("  RAFTER GRIND"))
		main.level.wall_broken.connect(func(): print("  WALL BROKEN"))
		main.level.letter_collected.connect(func(l): print("  LETTER ", l))
		main.level.tape_collected.connect(func(): print("  TAPE"))
	t += delta
	while ei < events.size() and events[ei][0] <= t:
		var e: Array = events[ei]
		if e[2]:
			Input.action_press(e[1])
		else:
			Input.action_release(e[1])
		ei += 1
	if t >= next_log:
		next_log += log_every
		var s = main.skater
		var st: String = ["GROUND", "AIR", "GRIND", "BAIL"][s.state]
		print("t=%5.2f pos=(%6.2f %5.2f %6.2f) v=%5.2f %s up.y=%.2f surf=%s score=%d combo=%s" % [
			t, s.global_position.x, s.global_position.y, s.global_position.z, s.vel.length(), st, s.up.y, s.surface,
			main.score.total, main.score.combo_text()])
	return t >= duration
