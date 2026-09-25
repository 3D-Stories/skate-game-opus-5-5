extends Node
## Demo / test driver: plays the two-minute run through the same input interface a
## player uses (pressed / just_pressed / stick), following the route in
## autopilot_route.gd. It never moves the skater directly - every jump, trick, grind and
## push goes through the skater's normal input handling and physics.
##
##   godot --headless --path . --fixed-fps 60 -- --autopilot=test   (prints a report, quits)
##   web build: index.html?autopilot                                  (watch it play)

var main: Node
var skater: Skater
var route: Array = []
var step := 0
var step_t := 0.0
var _prev: Dictionary = {}
var _cur: Dictionary = {}
var _stick := Vector2.ZERO
var log_lines: PackedStringArray = []
var t := 0.0
var verbose := false
var _slow_t := 0.0
var _unstick_t := 0.0


func setup(m: Node) -> void:
	main = m
	skater = m.skater
	route = preload("res://scripts/game/autopilot_route.gd").route()
	verbose = OS.get_cmdline_user_args().has("--verbose")


func pressed(a: String) -> bool:
	return _cur.get(a, false)


func just_pressed(a: String) -> bool:
	return _cur.get(a, false) and not _prev.get(a, false)


func just_released(a: String) -> bool:
	return _prev.get(a, false) and not _cur.get(a, false)


func stick() -> Vector2:
	return _stick


func balance_assist(bal: float, bal_v: float) -> float:
	## Counter-steer on grinds and manuals like a player watching the meter.
	return -(bal * 3.0 + bal_v * 1.2)


func note(msg: String) -> void:
	var line := "[ap %6.2f] %s" % [t, msg]
	log_lines.append(line)
	print(line)


func _physics_process(delta: float) -> void:
	t += delta
	_prev = _cur.duplicate()
	_cur = {}
	_stick = Vector2.ZERO
	if skater == null or step >= route.size():
		if skater and OS.get_cmdline_user_args().has("--partial"):
			note("route done: score %d  pos=%s" % [main.score.total, str(skater.global_position.snapped(Vector3.ONE * 0.1))])
			get_tree().quit()
		return
	step_t += delta
	var s: Dictionary = route[step]
	if step_t <= delta and verbose:
		note("step %d: %s  pos=%s v=%.1f st=%d" % [step, s.get("note", ""), str(skater.global_position.snapped(Vector3.ONE * 0.1)),
				skater.vel.length(), skater.state])
	var done := _run_step(s)
	if not done and step_t > float(s.get("timeout", 10.0)):
		note("step %d TIMEOUT (%s) pos=%s st=%d" % [step, s.get("note", ""), str(skater.global_position.snapped(Vector3.ONE * 0.1)), skater.state])
		done = true
		if s.has("skip_to"):
			_jump_to(String(s["skip_to"]))
			return
	if done:
		step += 1
		step_t = 0.0


func _jump_to(label: String) -> void:
	for i in route.size():
		if route[i].get("label", "") == label:
			step = i
			step_t = 0.0
			return
	step += 1
	step_t = 0.0


func grounded() -> bool:
	return skater.state == Skater.GROUND


func _steer_to(p: Vector3, push: bool) -> float:
	var sp := skater.global_position
	var to := p - sp
	to.y = 0.0
	var d := to.length()
	var h := skater.heading
	h.y = 0.0
	if h.length() < 0.1 or d < 0.05:
		_stick = Vector2(0, 1 if push else 0)
		return d
	var a := atan2(h.normalized().cross(to.normalized()).y, h.normalized().dot(to.normalized()))
	_stick = Vector2(clampf(-a * 2.5, -1.0, 1.0), 1.0 if push and absf(a) < 0.9 else 0.0)
	return d


func _run_step(s: Dictionary) -> bool:
	var d := INF
	# stuck against a prop: back off at an angle for a moment, like a player would
	if grounded() and skater.vel.length() < 0.6 and s.has("steer"):
		_slow_t += get_physics_process_delta_time()
	else:
		_slow_t = 0.0
	if _slow_t > 1.2:
		_slow_t = 0.0
		_unstick_t = 0.7
		note("unstick at %s" % str(skater.global_position.snapped(Vector3.ONE * 0.1)))
	if _unstick_t > 0.0:
		_unstick_t -= get_physics_process_delta_time()
		_stick = Vector2(1.0, 0.6)
		return false
	# steering only makes sense rolling on flat-ish ground
	if s.has("steer") and grounded() and skater.up.y > 0.8:
		d = _steer_to(s["steer"], s.get("push", true))
	elif s.has("steer"):
		var p: Vector3 = s["steer"]
		d = Vector2(p.x - skater.global_position.x, p.z - skater.global_position.z).length()
	if s.has("stick"):
		_stick = s["stick"]
	if s.has("max_speed") and grounded() and skater.vel.length() > float(s["max_speed"]):
		_stick.y = -0.7
	for a in s.get("hold", []):
		_cur[a] = true
	if step_t < float(s.get("tap_time", 0.07)):
		for a in s.get("tap", []):
			_cur[a] = true
		if s.has("tap_stick"):
			_stick = s["tap_stick"]
	if s.has("input"):
		(s["input"] as Callable).call(self)
	if s.get("do", "") == "halfpipe":
		return _halfpipe(s)
	if s.has("until"):
		return (s["until"] as Callable).call(self)
	if s.has("time"):
		return step_t >= float(s["time"])
	if s.has("steer"):
		return d < float(s.get("radius", 1.5))
	return true


func hold(action: String) -> void:
	_cur[action] = true


func _halfpipe(s: Dictionary) -> bool:
	## Back-and-forth vert airs: pump on the transitions (hold Up), line up on the flat
	## bottom, and play the scripted trick list in each air. Done after len(airs) airs.
	if not s.has("_i"):
		s["_i"] = 0
		s["_air"] = false
		s["_t0"] = 0.0
	var airs: Array = s["airs"]
	var sk := skater
	if sk.state == Skater.AIR:
		if not s["_air"]:
			s["_air"] = true
			s["_t0"] = t
			# only commit to the scripted trick if the air is long enough to land it
			var air := 2.0 * maxf(sk.vel.y, 0.0) / Skater.G
			var plan: Array = airs[int(s["_i"]) % airs.size()]
			if plan == s.get("special", []) and not main.score.special_ready:
				plan = s.get("fallback", [])
			s["_plan"] = plan if air > 0.95 else \
					([["grab", Vector2.ZERO, 0.08, maxf(0.05, air - 0.35)]] if air > 0.6 else [])
		var dt: float = t - float(s["_t0"])
		for e in s["_plan"]:
			# [action, stick, start, duration]
			if dt >= float(e[2]) and dt < float(e[2]) + float(e[3]):
				_cur[String(e[0])] = true
				_stick = e[1]
	elif sk.state == Skater.GROUND:
		if s["_air"]:
			s["_air"] = false
			s["_i"] = int(s["_i"]) + 1
			if int(s["_i"]) >= int(s.get("count", airs.size())):
				return true
		if sk.up.y > 0.93:
			# aim across the flat bottom, correcting any drift along the halfpipe
			var side := signf(sk.vel.x) if absf(sk.vel.x) > 0.5 else -1.0
			var zt := float(s["z"])
			_steer_to(Vector3(side * 6.0, 0.0, zt + (zt - sk.global_position.z) * 2.0), true)
		else:
			_stick = Vector2(0, 1)
	return false
