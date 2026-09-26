extends SceneTree
## THPS-style handling / game-feel tests on the real main scene, driven only by injected
## keyboard input (InputEventKey through Input.parse_input_event) and the real skater
## physics: pushing, coasting and braking; momentum through transitions and pumping; vert
## air out of the halfpipe; the flat ollie; rail and ledge snapping; grind and manual balance
## meters; sideways / off-balance / mid-trick / held-grab landings. Each scenario starts from
## a fresh spawn (Skater.spawn), every measured number is written into its result line.
##
## Energy bookkeeping: on the ground the only speed loss the game models is rolling
## friction + drag (skater.gd: ROLL_FRICTION, x0.7 on wood, + DRAG*v^2). The coasting check
## verifies that model on flat concrete; the transition checks then compare the measured
## height / speed with "entry energy minus that friction work" (E = v^2/2 + G_GROUND*y).
##
## Balance meters are random (skater.gd seeds its RNG at start-up), so balance checks run
## several grinds / manuals and assert on all of them - no best-of selection.
##   godot --headless --path . --fixed-fps 60 -s tests/test_handling.gd
##   -> tests/results/handling.txt   (add `-- verbose` for per-frame telemetry)

const FPS := 60.0
const RAG_T := preload("res://tests/test_ragdoll.gd")    # depth_inside(): how deep a point is inside the park
const TAP := 6                            # a typical quick button tap: 6 frames = 100 ms
const LANE := Vector3(-11.0, 0.0, 13.0)   # 60 m of clear flat concrete heading -Z
const NORTH := Vector3(0, 0, -1)
const HP_CENTER := Vector3(0.0, 0.0, -43.0)
const HP_Z_MIN := -49.0                   # the halfpipe spans z -49 .. -37 (12 m wide)
const LONG_RAIL_X := -12.0                # long_rail: (-12, 0.524, -2) -> (-12, 0.524, -20)
const LEDGE_X := 8.8                      # ledge_a east edge: (8.8, 0.5, -2) -> (8.8, 0.5, -12)

var main: Node
var sk
var out: PackedStringArray = []
var passed := 0
var failed := 0
var frame := 0
var verbose := false
var held := {}
var bails: Array = []          # [reason, frame]
var lands: Array = []          # frame of every landed_clean
var tricks: Array = []         # [name, frame]
var bal := {"grind": 0.0, "manual": 0.0}
var bal_active := {"grind": false, "manual": false}
var bal_log: Array = []        # [kind, value, active, frame]
var vert_speed := 0.0          # the fastest bottom speed pumping reached (set by _pumping)


func check(ok: bool, what: String, detail := "") -> void:
	if ok:
		passed += 1
		out.append("PASS  " + what + ("  (" + detail + ")" if detail != "" else ""))
	else:
		failed += 1
		out.append("FAIL  " + what + ("  (" + detail + ")" if detail != "" else ""))
	print(out[out.size() - 1])


func _initialize() -> void:
	verbose = "verbose" in OS.get_cmdline_user_args()
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


# ------------------------------------------------------------------ input + stepping

func frames(n: int) -> void:
	for i in n:
		await process_frame
		frame += 1


func key(k: Key, down: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = k
	e.physical_keycode = k
	e.pressed = down
	Input.parse_input_event(e)
	held[k] = down


func set_key(k: Key, down: bool) -> void:
	if held.get(k, false) != down:
		key(k, down)


func tap(k: Key, hold_frames := TAP) -> void:
	key(k, true)
	await frames(hold_frames)
	key(k, false)
	await frames(2)


func release_all() -> void:
	for k in held.keys():
		if held[k]:
			key(k, false)


func fresh(pos: Vector3, fwd: Vector3, speed: float) -> void:
	## New scenario: all keys up, input buffers expire, then a clean spawn.
	release_all()
	await frames(30)
	main.time_left = main.RUN_TIME
	sk.spawn(pos, fwd, speed)
	await frames(1)


func _on_bal(kind: String, value: float, active: bool) -> void:
	bal[kind] = value
	bal_active[kind] = active
	bal_log.append([kind, value, active, frame])


func hz(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


func tel(tag: String) -> void:
	if verbose:
		print("  [%s] f=%d pos=%s v=%.2f st=%d up.y=%.2f vert=%s" % [tag, frame,
				str(sk.global_position.snapped(Vector3.ONE * 0.01)), sk.vel.length(), sk.state, sk.up.y, sk.vert_air])


func wait_state(st: int, max_frames: int) -> bool:
	for i in max_frames:
		if sk.state == st:
			return true
		await frames(1)
	return sk.state == st


func last_bail(n_before: int) -> String:
	return bails[bails.size() - 1][0] if bails.size() > n_before else ""


func fric_work() -> float:
	## Friction + drag work per unit mass for the coming frame, from the game's own model.
	var v: float = sk.vel.length()
	var fr: float = sk.ROLL_FRICTION * (0.7 if sk.surface == "wood" else 1.0)
	return (fr + sk.DRAG * v * v) * v / FPS


func _fmt(a: Array, f := "%.2f") -> String:
	var s: PackedStringArray = []
	for x in a:
		s.append(f % x)
	return " ".join(s)


func _run() -> void:
	await frames(5)
	sk = main.skater
	sk.bailed.connect(func(r): bails.append([r, frame]))
	sk.landed_clean.connect(func(): lands.append(frame))
	sk.trick.connect(func(n): tricks.append([n, frame]))
	sk.balance_changed.connect(_on_bal)
	await frames(30)        # menus ignore input right after opening
	await tap(KEY_ENTER, 2)
	await frames(3)
	if not (main.running and not paused):
		# harness precondition, not a handling check: without a running game nothing below means anything
		check(false, "harness: Enter on the start screen starts the run", "running=%s paused=%s" % [main.running, paused])
		_write_report()
		quit(1)
		return
	await _acceleration()
	await _braking()
	await _quarterpipe()
	await _pumping()
	await _vert_air()
	await _vert_angled()
	await _rafter_pop()
	await _ramp_bail()
	await _ollie()
	await _rail_snap()
	await _grind_balance()
	await _manual_balance()
	await _bails()
	release_all()
	_write_report()
	quit(1 if failed > 0 else 0)


func _write_report() -> void:
	var report := "THPS handling / game-feel tests  %s\n%s\n%d passed, %d failed\n" % [
			Time.get_datetime_string_from_system(), "\n".join(out), passed, failed]
	print(report)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/results"))
	var f := FileAccess.open("res://tests/results/handling.txt", FileAccess.WRITE)
	f.store_string(report)
	f.close()


# ------------------------------------------------------------------ 1. acceleration

func _acceleration() -> void:
	await fresh(LANE, NORTH, 0.0)
	var v: Array = []
	var max_dx := 0.0
	key(KEY_W, true)
	for i in 240:                       # hold Up (push) for 4 s
		await frames(1)
		v.append(sk.vel.length())
		max_dx = maxf(max_dx, absf(sk.global_position.x - LANE.x))
	key(KEY_W, false)
	# coast 2 s with no input; predict the same 2 s from the game's friction model
	var coast: Array = []
	var v_model: float = sk.vel.length()
	var v_let_go: float = v_model
	for i in 120:
		var fr: float = sk.ROLL_FRICTION * (0.7 if sk.surface == "wood" else 1.0)
		v_model -= (fr + sk.DRAG * v_model * v_model) / FPS
		await frames(1)
		coast.append(sk.vel.length())
	# speed curve at 0.5 s intervals
	var curve: PackedStringArray = []
	for k in range(29, 240, 30):
		curve.append("%.1fs %.2f" % [(k + 1) / FPS, v[k]])
	var cap_i := v.size()
	for i in v.size():
		if v[i] >= sk.PUSH_MAX - 0.05:
			cap_i = i
			break
	# per-frame acceleration, smoothed over 5 frames, up to the cap
	var acc: Array = [0.0]
	for i in range(1, v.size()):
		acc.append((v[i] - v[i - 1]) * FPS)
	var sm: Array = []
	for i in v.size():
		var s := 0.0
		var n := 0
		for j in range(maxi(1, i - 2), mini(v.size(), i + 3)):
			s += acc[j]
			n += 1
		sm.append(s / maxf(n, 1))
	# kicks = maxima of the push acceleration, glides = the minima between them
	# (a kick is a real maximum: at least 40% of the strongest one, so the flat start
	# before the first kick does not count as a peak)
	var sm_max := 0.0
	for i in range(3, cap_i - 2):
		sm_max = maxf(sm_max, sm[i])
	var peaks: Array = []
	for i in range(3, cap_i - 2):
		if sm[i] >= sm[i - 1] and sm[i] > sm[i + 1] and sm[i] >= 0.4 * sm_max \
				and (peaks.is_empty() or i - peaks[peaks.size() - 1] > 30):
			peaks.append(i)
	var glide_min := INF
	var peak_acc := 0.0
	var spacing := 0.0
	var gains: PackedStringArray = []
	var min_gain := INF
	if peaks.size() >= 2:
		for j in range(peaks.size() - 1):
			for i in range(peaks[j], peaks[j + 1]):
				glide_min = minf(glide_min, sm[i])
		for p in peaks:
			peak_acc = maxf(peak_acc, sm[p])
		spacing = (peaks[1] - peaks[0]) / FPS
		# speed added by each kick: from one glide minimum to the next (or the cap)
		var cuts: Array = [0]
		for j in range(peaks.size() - 1):
			var lo: int = peaks[j]
			for i in range(peaks[j], peaks[j + 1]):
				if sm[i] < sm[lo]:
					lo = i
			cuts.append(lo)
		cuts.append(cap_i)
		for j in range(cuts.size() - 1):
			var g: float = v[cuts[j + 1]] - v[cuts[j]]
			min_gain = minf(min_gain, g)
			gains.append("+%.2f" % g)
	var t_cap := cap_i / FPS
	var ratio := glide_min / maxf(peak_acc, 0.001)
	check(peaks.size() >= 2 and spacing >= 1.0 and spacing <= 1.4 and ratio <= 0.5 and min_gain > 1.0,
			"each push kick adds a surge of speed, one per 1.2 s stride",
			"curve: %s | %d kicks before the cap at %.2f s, %.2f s apart, adding %s m/s; accel %.1f m/s^2 at a kick vs %.1f between kicks (%.0f%%)" % [
			", ".join(curve), peaks.size(), t_cap, spacing, " ".join(gains), peak_acc, glide_min, ratio * 100.0])
	check(peaks.size() >= 2 and ratio <= 1.0 / 3.0,
			"the speed rises in steps: it levels off between kicks",
			"between kicks the push still accelerates at %.1f m/s^2 = %.0f%% of the %.1f m/s^2 kick peak (a step needs <= 33%%); the curve is a wavy ramp, no plateau" % [
			glide_min, ratio * 100.0, peak_acc])
	var vmax := 0.0
	for x in v:
		vmax = maxf(vmax, x)
	var v_end: float = v[v.size() - 1]
	check(vmax <= sk.PUSH_MAX + 0.5 and v_end >= sk.PUSH_MAX - 0.6 and t_cap < 3.0,
			"push speed is capped near PUSH_MAX",
			"PUSH_MAX %.1f, reached %.2f at %.2f s, max %.2f, %.2f after 4 s of pushing, drift off line %.3f m" % [
			sk.PUSH_MAX, sk.PUSH_MAX - 0.05, t_cap, vmax, v_end, max_dx])
	var v_c: float = coast[coast.size() - 1]
	var decay: float = (v_let_go - v_c) / 2.0
	check(decay > 0.05 and decay < 1.0 and v_c > 0.8 * v_let_go and absf(v_c - v_model) < 0.05,
			"letting go coasts with a slow decay (rolling friction + drag only)",
			"%.2f -> %.2f m/s over 2 s = %.2f m/s^2; friction model predicts %.2f m/s (off by %.3f)" % [
			v_let_go, v_c, decay, v_model, v_c - v_model])
	set_meta("coast_decay", decay)


func _braking() -> void:
	await fresh(LANE, NORTH, 0.0)
	key(KEY_W, true)
	await frames(150)
	key(KEY_W, false)
	var v0: float = sk.vel.length()
	var z0: float = sk.global_position.z
	key(KEY_S, true)
	var n := 0
	while sk.vel.length() > 0.05 and n < 300:
		await frames(1)
		n += 1
	key(KEY_S, false)
	var t := n / FPS
	var dist := absf(sk.global_position.z - z0)
	var decel := v0 / maxf(t, 0.001)
	var coast_decay: float = get_meta("coast_decay", 0.5)
	check(t < 2.5 and decel > 3.0 and decel > 4.0 * coast_decay and sk.state == sk.GROUND,
			"holding Down brakes quickly",
			"%.2f m/s -> stop in %.2f s over %.2f m = %.2f m/s^2 (%.1fx the coasting decay)" % [
			v0, t, dist, decel, decel / maxf(coast_decay, 0.001)])


# ------------------------------------------------------------------ 2. transitions

func _quarterpipe() -> void:
	## Roll into the east quarterpipe with no input at all and come back down. The friction
	## work from the gate onwards is summed with the game's own friction model.
	await fresh(Vector3(6.0, 0.0, -18.0), Vector3(1, 0, 0), 7.0)
	var gate := 15.5                      # flat concrete in front of the ramp
	var v_in := -1.0
	var v_out := -1.0
	var peak := 0.0
	var v_at_peak := 0.0
	var air := false
	var t_in := 0
	var t_out := 0
	var w := 0.0
	var w_peak := 0.0
	var w_out := 0.0
	for i in 420:
		var dw := fric_work()
		await frames(1)
		tel("qp")
		if v_in > 0.0:
			w += dw
		var p: Vector3 = sk.global_position
		if sk.state != sk.GROUND:
			air = true
		if v_in < 0.0 and p.x >= gate:
			v_in = sk.vel.length()
			t_in = frame
		if v_in > 0.0 and p.y > peak:
			peak = p.y
			v_at_peak = sk.vel.length()
			w_peak = w
		if v_in > 0.0 and peak > 0.5 and sk.vel.x < 0.0 and p.x <= gate:
			v_out = sk.vel.length()
			t_out = frame
			w_out = w
			break
	var g: float = sk.G_GROUND
	var h_free: float = v_in * v_in / (2.0 * g)
	var h_pred: float = (0.5 * v_in * v_in - w_peak) / g
	check(not air and v_in > 0.0 and absf(peak - h_pred) <= 0.05 and v_at_peak < 1.0,
			"quarterpipe converts speed into height, minus friction (no input)",
			"entry %.2f m/s -> peak %.2f m; predicted %.2f m (v^2/2g %.2f m minus %.2f m of friction work) -> %+.2f m off (tolerance 0.05); %.2f m/s at the top, stayed on the ramp=%s" % [
			v_in, peak, h_pred, h_free, h_free - h_pred, peak - h_pred, v_at_peak, not air])
	var v_pred := sqrt(maxf(0.0, v_in * v_in - 2.0 * w_out))
	check(v_out > 0.0 and absf(v_out - v_pred) <= 0.03 * v_in,
			"coming back down returns the entry speed minus friction (no input)",
			"entry %.2f -> back at the bottom %.2f m/s (%+.1f%%) after %.2f s on the ramp; friction work predicts %.2f m/s (tolerance 3%%)" % [
			v_in, v_out, (v_out / maxf(v_in, 0.01) - 1.0) * 100.0, (t_out - t_in) / FPS, v_pred])


func _hp_passes(pump: bool) -> Dictionary:
	## Ride the halfpipe from the flat bottom for 20 s. With pump, Up is held only while on
	## the steep part of a transition wall (no pushing on the flat); peaks per wall pass
	## and the speed at each crossing of the bottom are recorded.
	await fresh(HP_CENTER, Vector3(-1, 0, 0), 6.0)
	var peaks: Array = []
	var bottoms: Array = []
	var cur := 0.0
	var last_side := 0.0
	var bail_n := bails.size()
	for i in 1200:
		set_key(KEY_W, pump and sk.state == sk.GROUND and sk.up.y < 0.8)
		await frames(1)
		tel("hp%s" % ("P" if pump else "-"))
		var x: float = sk.global_position.x - HP_CENTER.x
		cur = maxf(cur, sk.global_position.y)
		if absf(x) > 1.0:
			last_side = signf(x)          # out on a wall: arm the next bottom crossing
		if last_side != 0.0 and absf(x) < 0.25 and cur > 0.3:
			peaks.append(cur)
			bottoms.append(sk.vel.length())
			cur = 0.0
			last_side = 0.0
	set_key(KEY_W, false)
	return {"peaks": peaks, "bottoms": bottoms, "bails": bails.size() - bail_n}


func _pumping() -> void:
	var np: Dictionary = await _hp_passes(false)
	var pp: Dictionary = await _hp_passes(true)
	var pk: Array = pp["peaks"]
	var bt: Array = pp["bottoms"]
	var npk: Array = np["peaks"]
	var nbt: Array = np["bottoms"]
	for b in bt:
		vert_speed = maxf(vert_speed, b)
	var summary := "peaks m, pumping: %s | not pumping: %s ; bottom speed m/s, pumping: %s | not pumping: %s" % [
			_fmt(pk), _fmt(npk), _fmt(bt), _fmt(nbt)]
	# a) pass by pass: each of the first 5 pumped passes is higher and faster than the one before
	var grow_ok: bool = pk.size() >= 5 and bt.size() >= 5 and pp["bails"] == 0
	var steps: PackedStringArray = []
	if grow_ok:
		for k in range(1, 5):
			steps.append("%+.2f m/%+.2f m/s" % [pk[k] - pk[k - 1], bt[k] - bt[k - 1]])
			if pk[k] < pk[k - 1] + 0.1 or bt[k] <= bt[k - 1]:
				grow_ok = false
	check(grow_ok, "pumping the halfpipe transitions raises the peak and the speed on every pass",
			"passes 2-5 vs the pass before: %s | %s" % [", ".join(steps), summary])
	# b) against not pumping, at the 4th pass
	var n := mini(npk.size(), pk.size())
	var ok := n >= 4
	var dh := 0.0
	var dv := 0.0
	if ok:
		dh = pk[3] - npk[3]
		dv = bt[3] - nbt[3]
	check(ok and dh > 0.5 and dv > 0.8,
			"pumping beats not pumping by the 4th pass",
			"4th pass: peak %+.2f m, bottom speed %+.2f m/s vs the same ride without pumping" % [dh, dv])
	# c) the no-input baseline: friction must make an unpumped halfpipe die down
	var lose_ok := npk.size() >= 4
	var diffs: PackedStringArray = []
	for k in range(1, npk.size()):
		diffs.append("%+.2f" % (npk[k] - npk[k - 1]))
		if npk[k] >= npk[k - 1]:
			lose_ok = false
	check(lose_ok, "without pumping the halfpipe loses height pass by pass (friction, no input)",
			"unpumped peaks %s m (change per pass %s), bottom speeds %s m/s" % [_fmt(npk), " ".join(diffs), _fmt(nbt)])


# ------------------------------------------------------------------ 3. vert air

func _air_phase(p_take: Vector3) -> Dictionary:
	## Follow an air until touchdown; drift along the coping (z) and away from the wall (x).
	var peak := p_take.y
	var dx := 0.0
	var dz := 0.0
	var air_t := 0
	var fu: Vector3 = sk.face_up
	while sk.state == sk.AIR and air_t < 300:
		await frames(1)
		tel("air")
		air_t += 1
		peak = maxf(peak, sk.global_position.y)
		dx = maxf(dx, absf(sk.global_position.x - p_take.x))
		dz = maxf(dz, absf(sk.global_position.z - p_take.z))
		fu = sk.face_up
	return {"peak": peak, "dx": dx, "dz": dz, "t": air_t / FPS, "p_land": sk.global_position, "up_land": sk.up,
			"state": sk.state, "tilt": rad_to_deg(fu.angle_to(sk.up))}


func _vert_air() -> void:
	## Real input builds the speed: pump the halfpipe until the skater crosses the bottom at
	## vert speed, then let go of everything and ride the next wall with no input at all.
	var coping: float = float(main.level.data["halfpipe"]["height"])
	# enough for > 1 m above the coping: v^2 = 2*G_GROUND*coping + 2*G*1 m, plus twice the
	# friction + drag work over the climb (a quarter circle of the transition radius plus
	# the vert extension, on wood) at the speed it averages on the way up
	var hp: Dictionary = main.level.data["halfpipe"]
	var climb: float = PI / 2.0 * float(hp.get("radius", 3.2)) + maxf(0.0, coping - float(hp.get("radius", 3.2)))
	var v0: float = sqrt(2.0 * sk.G_GROUND * coping + 2.0 * sk.G * 1.0)
	var fw: float = (sk.ROLL_FRICTION * 0.7 + sk.DRAG * v0 * v0 * 0.6) * climb
	var v_need: float = sqrt(v0 * v0 + 2.0 * fw) + 0.1
	await fresh(HP_CENTER, Vector3(-1, 0, 0), 6.0)
	var last_side := 0.0
	var passes := 0
	var v_in := -1.0
	var v_last := 0.0
	var n_bail0 := bails.size()
	for i in 2400:
		set_key(KEY_W, sk.state == sk.GROUND and sk.up.y < 0.8)
		await frames(1)
		var x: float = sk.global_position.x - HP_CENTER.x
		if absf(x) > 1.0:
			last_side = signf(x)
		if last_side != 0.0 and absf(x) < 0.25:
			passes += 1
			last_side = 0.0
			# keep pumping like a player until it stops adding (the pump fades out near its cap)
			var vc: float = sk.vel.length()
			if vc >= v_need and vc - v_last < 0.15:
				v_in = vc
				break
			v_last = vc
	release_all()
	# energy per kg on the ramp, E = v^2/2 + G_GROUND*y, against the game's friction work
	var gg: float = sk.G_GROUND
	var e_in: float = 0.5 * sk.vel.length_squared() + gg * sk.global_position.y
	var w_up := 0.0
	var side := signf(sk.vel.x)           # the wall it is heading for (+1 east, -1 west)
	var took := false
	var v_pre := Vector3.ZERO
	var e_take := e_in
	for i in 240:
		v_pre = sk.vel
		e_take = 0.5 * sk.vel.length_squared() + gg * sk.global_position.y
		var dw := fric_work()
		await frames(1)
		tel("va")
		if sk.state == sk.AIR:
			took = true
			break
		w_up += dw
	var vert: bool = took and sk.vert_air
	var p0: Vector3 = sk.global_position
	var n_land := lands.size()
	var n_bail := bails.size()
	var a: Dictionary = await _air_phase(p0)
	var clean: bool = lands.size() > n_land and bails.size() == n_bail and a["state"] == sk.GROUND
	var e_land: float = 0.5 * sk.vel.length_squared() + gg * sk.global_position.y
	var e_out := e_land
	var w_down := 0.0
	var v_out := -1.0
	for i in 180:
		var dw := fric_work()
		await frames(1)
		w_down += dw
		if absf(sk.global_position.x - HP_CENTER.x) < 0.25:
			v_out = sk.vel.length()
			e_out = 0.5 * sk.vel.length_squared() + gg * sk.global_position.y
			break
	var ex_up := e_take - e_in + w_up        # energy gained going up the ramp beyond friction
	var ex_down := e_out - e_land + w_down   # ... and coming back down
	var p_land: Vector3 = a["p_land"]
	check(v_in > 0.0 and bails.size() == n_bail0 and vert and a["peak"] - coping > 1.0,
			"pumping up to vert speed launches a vert air out of the coping (no input on that wall)",
			"pumped %d passes to %.2f m/s at the bottom (vert speed %.2f), then no input: vert_air=%s, takeoff y %.2f (coping %.2f) at %.2f m/s, peak %.2f m = %.2f m above the coping, %.2f s air" % [
			passes, v_in, v_need, vert, p0.y, coping, v_pre.length(), a["peak"], a["peak"] - coping, a["t"]])
	var same_wall: bool = signf(p_land.x - HP_CENTER.x) == side and absf(p_land.x - HP_CENTER.x) > 3.0 and a["up_land"].y < 0.95
	var back: float = hz(p_land - p0).length()
	check(vert and clean and same_wall and back < 0.6,
			"the straight-on vert air comes back down into the same transition cleanly",
			"landed %.2f m from the takeoff (%.2f m in from the coping, %.2f m along it) at y %.2f on the %s wall, surface up.y %.2f, landed_clean=%s, bails=%d" % [
			back, a["dx"], a["dz"], p_land.y, "east" if side > 0 else "west", a["up_land"].y, lands.size() > n_land, bails.size() - n_bail])
	var r := v_out / maxf(v_in, 0.01)
	check(v_out > 0.0 and r >= 0.8 and r <= 1.0,
			"the vert air keeps most of its speed (80-100% of the entry speed, no input)",
			"%.2f m/s across the bottom before the wall -> %.2f m/s across it after the air (%.1f%%), no input on the whole pass; energy per kg: ramp up %+.2f and ramp down %+.2f J beyond the %.2f J of friction work, air + landing impact %+.2f J" % [
			v_in, v_out, r * 100.0, ex_up, ex_down, w_up + w_down, e_land - e_take])


func _ramp_bail() -> void:
	## Bail halfway up the east quarterpipe: the body must lie on the ramp (no bone below its
	## surface), slide down to the flat, get up with the board back under the feet and ride.
	await fresh(Vector3(13.0, 0.0, -20.0), Vector3(1, 0, 0), 7.0)
	for i in 120:
		await frames(1)
		if sk.state == sk.GROUND and sk.global_position.y > 1.2:
			break
	var y0: float = sk.global_position.y
	sk._bail("test: bail on the ramp")
	var skel: Skeleton3D = sk.model.find_children("*", "Skeleton3D", true, false)[0]
	var bones := ["pelvis", "spine_03", "head", "hand_l", "hand_r", "foot_l", "foot_r", "calf_l", "calf_r"]
	var space: PhysicsDirectSpaceState3D = sk.get_world_3d().direct_space_state
	# sampled when the skeleton has applied its modifiers (the ragdoll): read at any other
	# time a bone pose is the animation's, not the drawn one
	var deep := {"worst": 0.0, "at": "", "t": 0.0}
	var sampler := func():
		for bn in bones:
			var bi := skel.find_bone(bn)
			if bi < 0:
				continue
			var p: Vector3 = skel.global_transform * skel.get_bone_global_pose(bi).origin
			var d: Dictionary = RAG_T.depth_inside(space, p)
			if d["depth"] > deep["worst"]:
				deep["worst"] = d["depth"]
				deep["at"] = "%s at t=%.2f s (%.2f m %s)" % [bn, deep["t"], d["depth"], d["what"]]
	skel.skeleton_updated.connect(sampler)
	var got_up := false
	var getup_seen := false
	var t := 0.0
	for i in 600:
		await frames(1)
		t += 1.0 / FPS
		if sk.model.current.begins_with("getup"):
			getup_seen = true
		deep["t"] = t
		if sk.state == sk.GROUND and getup_seen:
			got_up = true
			break
	skel.skeleton_updated.disconnect(sampler)
	var worst: float = deep["worst"]
	var worst_at: String = deep["at"]
	var p_end: Vector3 = sk.global_position
	check(worst < 0.1, "a bail on a ramp lies on the ramp: no part of the body goes under its surface",
			"bail at y %.2f on the east quarter; deepest bone below the surface: %s" % [y0, worst_at if worst_at != "" else "none"])
	check(got_up and p_end.y < 0.35 and not sk.model.board_detached,
			"the bailed skater slides down to the foot of the ramp, gets up with the board under the feet and rides again",
			"getup clip played=%s, back to GROUND=%s after %.2f s at %s, board attached=%s" % [
			getup_seen, got_up, t, str(p_end.snapped(Vector3.ONE * 0.01)), not sk.model.board_detached])
	await frames(10)
	set_key(KEY_W, true)
	await frames(60)
	release_all()
	check(sk.state == sk.GROUND and sk.vel.length() > 1.5, "after getting up the skater pushes off again",
			"state %d, speed %.2f m/s after 1 s of push" % [sk.state, sk.vel.length()])


func _rafter_pop() -> void:
	## A big vert air off the east quarter under rafter_east: without grind the head bonks the
	## beam's underside (never passes through it); holding grind pops the skater onto it.
	var beam_bottom := 6.8 - 0.36
	var start := Vector3(11.5, 0.0, -42.6)
	await fresh(start, Vector3(1, 0, 0), 13.5)
	var peak := 0.0
	var aired := false
	for i in 300:
		await frames(1)
		if sk.state == sk.AIR:
			aired = true
			peak = maxf(peak, sk.global_position.y)
		elif aired:
			break
	check(aired and peak + sk.HEAD_HEIGHT <= beam_bottom + 0.08,
			"a vert air under the east rafter bonks its head on the beam (no grind held)",
			"feet peak %.2f m + head %.2f m vs beam underside %.2f m" % [peak, sk.HEAD_HEIGHT, beam_bottom])
	await fresh(start, Vector3(1, 0, 0), 13.5)
	var got := ""
	for i in 300:
		# press grind near the top of the air (pressed at the lip it grinds the coping)
		set_key(KEY_L, sk.state == sk.AIR and sk.global_position.y > 4.2)
		await frames(1)
		if sk.state == sk.GRIND and sk.grind_rail:
			got = sk.grind_rail.name
			break
	release_all()
	check(got == "rafter_east", "holding grind in that vert air pops the skater up onto the east rafter",
			"grinding %s at %s" % [got if got != "" else "nothing", str(sk.global_position.snapped(Vector3.ONE * 0.01))])


func _vert_angled_run(z0: float, deg: float) -> Dictionary:
	## Spawn on the halfpipe flat at the speed pumping reached, heading for the west wall
	## deg degrees off square (drifting north, -Z), no input.
	var d := Vector3(-cos(deg_to_rad(deg)), 0.0, -sin(deg_to_rad(deg)))
	await fresh(Vector3(HP_CENTER.x, 0.0, z0), d, vert_speed)
	var v_pre := Vector3.ZERO
	var took := false
	for i in 240:
		v_pre = sk.vel
		await frames(1)
		tel("ang")
		if sk.state == sk.AIR:
			took = true
			break
	var res := {"took": took, "vert": took and sk.vert_air, "v_pre": v_pre, "v_air": sk.vel, "p0": sk.global_position}
	var n_land := lands.size()
	var n_bail := bails.size()
	var a: Dictionary = await _air_phase(sk.global_position)
	await frames(2)
	res.merge(a)
	res["clean"] = lands.size() > n_land and bails.size() == n_bail
	res["reason"] = last_bail(n_bail)
	return res


func _vert_angled() -> void:
	# 15 deg off square: the halfpipe auto-align should send it straight back into the ramp
	var r: Dictionary = await _vert_angled_run(-40.5, 15.0)
	var vp: Vector3 = r["v_pre"]
	var va: Vector3 = r["v_air"]
	var ang_pre := rad_to_deg(atan2(absf(vp.z), maxf(vp.y, 0.01)))
	var ang_air := rad_to_deg(atan2(absf(va.z), maxf(va.y, 0.01)))
	var free_dz: float = absf(vp.z) * r["t"]
	var removed: float = 1.0 - r["dz"] / maxf(free_dz, 0.01)
	var pl: Vector3 = r["p_land"]
	var in_ramp: bool = pl.x < HP_CENTER.x - 3.0 and r["up_land"].y < 0.95 and pl.z > HP_Z_MIN
	check(r["vert"] and ang_air <= 10.0 and removed >= 0.6 and r["clean"] and in_ramp,
			"a vert air 15 deg off square is auto-aligned straight up and back into the ramp",
			"at %.2f m/s: %.2f m/s along the coping at takeoff would fly %.0f deg off vertical; the air leaves %.1f deg off vertical, drifts %.2f m along the coping in %.2f s (%.0f%% of the %.2f m it would drift unaligned removed), lands clean=%s in the transition at y %.2f" % [
			vert_speed, absf(vp.z), ang_pre, ang_air, r["dz"], r["t"], removed * 100.0, free_dz, r["clean"], pl.y])


# ------------------------------------------------------------------ 4. ollie

func _ollie_run(hold: int) -> Dictionary:
	await fresh(LANE, NORTH, 6.0)
	await frames(10)
	var ground_y: float = sk.global_position.y
	var n_land := lands.size()
	var n_bail := bails.size()
	key(KEY_SPACE, true)
	await frames(hold)
	key(KEY_SPACE, false)
	var took := await wait_state(sk.AIR, 10)
	var peak := 0.0
	var air := 0
	while sk.state == sk.AIR and air < 200:
		await frames(1)
		air += 1
		peak = maxf(peak, sk.global_position.y - ground_y)
	await frames(3)
	return {"took": took, "peak": peak, "air": air / FPS, "clean": took and lands.size() > n_land and bails.size() == n_bail,
			"state": sk.state}


func _ollie() -> void:
	var holds := [2, 4, TAP, 9]
	var runs: Array = []
	var in_range := true
	var all_clean := true
	var parts: PackedStringArray = []
	for hf in holds:
		var o: Dictionary = await _ollie_run(hf)
		runs.append(o)
		# upper bound 1.0 m: a THPS flat ollie is big, and a tapped ollie has to stay up
		# longer than a 0.6 s flip trick so a flip off flat ground can be landed
		in_range = in_range and o["took"] and o["peak"] >= 0.3 and o["peak"] <= 1.0
		all_clean = all_clean and o["clean"] and o["state"] == sk.GROUND
		parts.append("%d ms %.2f m" % [int(round(hf / FPS * 1000.0)), o["peak"]])
	check(in_range, "a quick jump tap (33-150 ms) pops a sensible 0.3-1.0 m ollie on flat",
			"pop height by press length at 6 m/s: %s" % ", ".join(parts))
	var tap_o: Dictionary = runs[2]
	check(all_clean, "the flat ollies land clean",
			"landed_clean on all %d, %.2f s air for the 100 ms tap" % [runs.size(), tap_o["air"]])
	var charged: Dictionary = await _ollie_run(30)
	check(charged["took"] and charged["clean"] and charged["peak"] > tap_o["peak"] + 0.1,
			"crouching longer (0.5 s) pops a higher ollie",
			"%.2f m vs %.2f m for a 100 ms tap, %.2f s air, clean=%s" % [charged["peak"], tap_o["peak"], charged["air"], charged["clean"]])


# ------------------------------------------------------------------ 5. rail snapping

func _rail_line(rail_name: String, near: Vector3):
	var best = null
	for r in main.level.rails:
		if r.name == rail_name and (best == null or r.closest(near)["dist"] < best.closest(near)["dist"]):
			best = r
	return best


func _lat(r, p: Vector3) -> float:
	## Horizontal distance from p to the rail's (infinite) line.
	var rd: Vector3 = (r.points[1] - r.points[0]).normalized()
	var rel: Vector3 = p - r.points[0]
	var l: Vector3 = rel - rd * rel.dot(rd)
	return Vector2(l.x, l.z).length()


func _snap_run(start: Vector3, fwd: Vector3, rail_name: String, pop_lat: float, press_lat: float,
		pop_z := -999.0, press_z := 999.0) -> Dictionary:
	## Ride toward a rail at 7 m/s; ollie (100 ms tap) when the lateral offset drops to
	## pop_lat (or z passes pop_z), then press and hold grind once airborne within
	## press_lat of the rail line (and past press_z).
	await fresh(start, fwd, 7.0)
	var r = _rail_line(rail_name, start + fwd * 6.0)
	var rd: Vector3 = (r.points[1] - r.points[0]).normalized()
	var popped := false
	var pressed := false
	var lat_press := -1.0
	var last_p := Vector3.ZERO
	var last_v := Vector3.ZERO
	var was_air := false
	var t := 0
	while t < 300 and sk.state != sk.GRIND:
		var p: Vector3 = sk.global_position
		var lat := _lat(r, p)
		if was_air and sk.state != sk.AIR:
			break                            # the ollie is over without a snap
		was_air = was_air or sk.state == sk.AIR
		if not popped and (lat <= pop_lat or p.z <= pop_z):
			popped = true
			key(KEY_SPACE, true)
			await frames(TAP)
			key(KEY_SPACE, false)
			t += TAP
			continue
		if popped and not pressed and sk.state == sk.AIR and lat <= press_lat and p.z <= press_z:
			pressed = true
			lat_press = lat
			key(KEY_L, true)
		if sk.state == sk.AIR:
			last_p = p
			last_v = sk.vel
		await frames(1)
		t += 1
	set_key(KEY_L, false)
	var got: bool = sk.state == sk.GRIND
	var res := {"got": got, "lat_press": lat_press, "state": sk.state, "pressed": pressed}
	if not got:
		return res
	res["rail"] = sk.grind_rail.name
	# the offset the snap removes: last airborne position -> nearest point of the rail (3D)
	res["snap_d"] = r.closest(last_p)["dist"]
	res["lat_before"] = _lat(r, last_p)
	var hv := hz(last_v)
	res["v_app"] = hv.length()
	res["along"] = absf(hv.dot(rd))
	var sense := signf(hv.dot(rd))
	await frames(2)                      # the first grind step sets the rail velocity
	res["v_grind"] = sk.vel.length()
	res["dir_dot"] = sk.vel.normalized().dot(rd) * sense   # 1 = along the rail, the way it was going
	var err := 0.0
	var n := 0
	while n < 20 and sk.state == sk.GRIND:
		var c: Dictionary = r.closest(sk.global_position)
		err = maxf(err, c["dist"])
		await frames(1)
		n += 1
	res["err"] = err
	res["held"] = n >= 20
	return res


func _rail_snap() -> void:
	var approaches: Array = []
	# parallel lines 0.3 / 0.6 m east of the long rail and 0.45 m west of it
	for d in [0.3, 0.6, -0.45]:
		approaches.append(["%.2f m %s of the long rail, parallel" % [absf(d), "east" if d > 0 else "west"],
				Vector3(LONG_RAIL_X + d, 0.0, 1.0), NORTH, "long_rail", -1.0, 99.0, -1.0, -2.6])
	# angled lines crossing toward the rail, pressed 0.55 m out: from the east (snap near z -9)
	# and from the west (snap near z -3.5, clear of the crates at z -5.3 .. -6.8)
	for deg in [15.0, 30.0]:
		var s := sin(deg_to_rad(deg))
		var c := cos(deg_to_rad(deg))
		approaches.append(["%d deg from the east onto the long rail" % int(deg),
				Vector3(LONG_RAIL_X + 0.55 + 7.0 * s, 0.0, -9.0 + 7.0 * c), Vector3(-s, 0, -c), "long_rail",
				0.55 + 7.0 * s * 0.4, 0.55, -999.0, 999.0])
		approaches.append(["%d deg from the west onto the long rail" % int(deg),
				Vector3(LONG_RAIL_X - 0.55 - 7.0 * s, 0.0, -3.5 + 7.0 * c), Vector3(s, 0, -c), "long_rail",
				0.55 + 7.0 * s * 0.4, 0.55, -999.0, 999.0])
	# the diagonal rail crossed heading north (49 deg to the rail), and the ledge edge
	approaches.append(["49 deg across the diagonal rail", Vector3(9.0, 0.0, -22.0), NORTH, "diag_rail",
			0.55 + 7.0 * 0.755 * 0.4, 0.55, -999.0, 999.0])
	approaches.append(["0.45 m beside ledge_a, parallel", Vector3(LEDGE_X + 0.45, 0.0, 1.0), NORTH, "ledge_a",
			-1.0, 99.0, -1.0, -2.6])
	var speed_parts: PackedStringArray = []
	var speed_ok := true
	var n_snapped := 0
	for ap in approaches:
		var r: Dictionary = await _snap_run(ap[1], ap[2], ap[3], ap[4], ap[5], ap[6], ap[7])
		if not r["got"]:
			check(false, "grind pressed %s snaps onto it" % ap[0],
					"no grind: pressed=%s at %.2f m off, state=%d" % [r["pressed"], r["lat_press"], r["state"]])
			speed_ok = false
			continue
		n_snapped += 1
		var ok: bool = r["rail"] == ap[3] and r["lat_press"] >= 0.25 and r["lat_press"] <= 0.65 \
				and r["err"] < 0.03 and r["dir_dot"] > 0.99 and r["held"]
		check(ok, "grind pressed %s snaps onto it" % ap[0],
				"pressed %.2f m off the rail line -> snapped %.2f m (3D) onto %s, then %.3f m from the rail line while grinding, velocity . rail (approach sense) %.3f, GRIND held 20 frames=%s" % [
				r["lat_press"], r["snap_d"], r["rail"], r["err"], r["dir_dot"], r["held"]])
		var lo: float = 0.95 * r["along"]
		var hi: float = 1.05 * r["v_app"]
		var this_ok: bool = r["v_grind"] >= lo and r["v_grind"] <= hi
		speed_ok = speed_ok and this_ok
		speed_parts.append("%s: %.2f -> %.2f m/s (x%.2f of the approach, along-rail part %.2f)%s" % [
				ap[0], r["v_app"], r["v_grind"], r["v_grind"] / maxf(r["v_app"], 0.01), r["along"], "" if this_ok else " OUT"])
	check(speed_ok and n_snapped == approaches.size(),
			"snapping keeps the speed along the rail (between the along-rail part of the approach and the full approach speed, +-5%)",
			"; ".join(speed_parts))
	var far: Dictionary = await _snap_run(Vector3(LONG_RAIL_X + 1.5, 0.0, 1.0), NORTH, "long_rail", -1.0, 99.0, -1.0, -2.6)
	check(not far["got"] and far["pressed"], "a rail 1.5 m to the side is out of snapping reach",
			"grind held from %.2f m off: grind=%s (radius %.2f m)" % [far["lat_press"], far["got"], sk.GRIND_RADIUS])


# ------------------------------------------------------------------ 6. grind balance

func _mount_long_rail() -> bool:
	await fresh(Vector3(LONG_RAIL_X + 0.45, 0.0, -3.0), NORTH, 3.5)
	await frames(3)
	bal_log.clear()
	key(KEY_SPACE, true)
	await frames(TAP)
	key(KEY_SPACE, false)
	key(KEY_L, true)
	var ok := await wait_state(sk.GRIND, 60)
	key(KEY_L, false)
	return ok


func _grind_vals() -> Array:
	var vals: Array = []
	for e in bal_log:
		if e[0] == "grind" and e[2]:
			vals.append(e[1])
	return vals


func _grind_balance() -> void:
	# a) 8 unsteered grinds: no input at all once on the rail
	var runs: Array = []
	for k in 8:
		if not await _mount_long_rail():
			runs.append({"mounted": false})
			continue
		var n_bail := bails.size()
		var t0 := frame
		var b15 := NAN
		while sk.state == sk.GRIND and frame - t0 < 600:
			await frames(1)
			if frame - t0 == 90:
				b15 = bal["grind"]
		var vals := _grind_vals()
		var deact := false
		for e in bal_log:
			if e[0] == "grind" and not e[2]:
				deact = true
		var mx := 0.0
		for i in range(vals.size() - 1):
			mx = maxf(mx, absf(vals[i]))
		var changes := 0
		for i in range(1, vals.size()):
			if absf(vals[i] - vals[i - 1]) > 1e-6:
				changes += 1
		runs.append({"mounted": true, "vals": vals.size(), "changes": changes, "b0": vals[0] if vals.size() > 0 else 0.0,
				"b15": b15, "bailed": bails.size() > n_bail, "reason": last_bail(n_bail), "t": (frame - t0) / FPS,
				"last": vals[vals.size() - 1] if vals.size() > 0 else 0.0, "max_before": mx, "deact": deact,
				"z": sk.global_position.z})
	var mounted := 0
	var drift_n := 0
	var sig := 0
	var chg := 0
	var drift_parts: PackedStringArray = []
	var edge_ok := true
	var n_bailed := 0
	var edge_parts: PackedStringArray = []
	for r in runs:
		if not r["mounted"]:
			edge_ok = false
			continue
		mounted += 1
		sig += r["vals"]
		chg += r["changes"]
		var grew: bool = not is_nan(r["b15"]) and absf(r["b15"]) > absf(r["b0"]) + 0.03
		if grew:
			drift_n += 1
		drift_parts.append("%+.2f->%+.2f" % [r["b0"], r["b15"]])
		if r["bailed"]:
			n_bailed += 1
			# a bail must be the grind meter going past the edge, on the first frame it does
			if r["reason"] != "grind" or absf(r["last"]) <= 1.0 or r["max_before"] > 1.0 or not r["deact"]:
				edge_ok = false
			edge_parts.append("bail '%s' %.2fs |b| %.3f" % [r["reason"], r["t"], absf(r["last"])])
		else:
			# no bail allowed only if the meter never reached the edge before the rail ran out
			if absf(r["last"]) > 1.0 or r["max_before"] > 1.0:
				edge_ok = false
			edge_parts.append("rail end at z %.1f, |b| %.2f" % [r["z"], absf(r["last"])])
	check(mounted == 8 and drift_n >= 5 and chg >= 0.95 * sig and sig > 8 * 60,
			"with no input the 'grind' balance meter drifts away from centre",
			"%d grinds, %d balance_changed('grind', v, true) signals, value changed on %d; meter start -> 1.5 s in (before any bail): %s; leaned further out in %d of %d" % [
			mounted, sig, chg, " ".join(drift_parts), drift_n, mounted])
	check(mounted == 8 and edge_ok and n_bailed >= 5,
			"letting the grind balance run to the edge bails",
			"all 8 unsteered grinds reported: %d bailed at the edge, %d reached the rail end first: %s" % [
			n_bailed, mounted - n_bailed, "; ".join(edge_parts)])
	# b) 4 steered grinds: a late-reacting player who steers against the meter once it leans past 0.4
	var s_ok := true
	var s_parts: PackedStringArray = []
	var total_rec := 0
	for k in 4:
		if not await _mount_long_rail():
			s_ok = false
			s_parts.append("no mount")
			continue
		var n_bail := bails.size()
		var t0 := frame
		var correcting := 0.0
		var worst := 0.0
		var recoveries := 0
		var excursion := false
		while sk.state == sk.GRIND and frame - t0 < 600:
			var b: float = bal["grind"]
			worst = maxf(worst, absf(b))
			if absf(b) > 0.4:
				correcting = signf(b)
				excursion = true
			elif absf(b) < 0.1 or signf(b) != correcting:
				if excursion and absf(b) < 0.15:
					recoveries += 1
					excursion = false
				correcting = 0.0
			set_key(KEY_D, correcting > 0.0)      # Right pushes the balance back to the left
			set_key(KEY_A, correcting < 0.0)
			await frames(1)
		set_key(KEY_D, false)
		set_key(KEY_A, false)
		var t := (frame - t0) / FPS
		var bailed := bails.size() > n_bail
		var z: float = sk.global_position.z
		total_rec += recoveries
		if bailed or worst >= 1.0 or not (t >= 3.0 or z < -19.5):
			s_ok = false
		s_parts.append("%.2f s to z %.1f, bail=%s, worst |%.2f|, %d recoveries" % [t, z, bailed, worst, recoveries])
	check(s_ok and total_rec >= 2,
			"steering against the grind balance recovers it",
			"4 steered grinds: %s (%d recoveries from past 0.4 back to centre in total)" % ["; ".join(s_parts), total_rec])


# ------------------------------------------------------------------ 7. manual balance

func _start_manual() -> bool:
	## Up, Down (two 100 ms taps) while rolling at 5 m/s.
	await fresh(LANE, NORTH, 5.0)
	await frames(5)
	bal_log.clear()
	await tap(KEY_W)
	key(KEY_S, true)
	await frames(TAP)
	key(KEY_S, false)
	await frames(1)
	return sk.manual == "manual" and sk.state == sk.GROUND


func _manual_balance() -> void:
	var ok := await _start_manual()
	var seen := false
	for e in bal_log:
		if e[0] == "manual" and e[2]:
			seen = true
	check(ok and seen, "Up, Down tap starts a manual with a 'manual' balance meter",
			"skater.manual='%s' (the game has no separate MANUAL state enum: a manual is state GROUND=%d with manual set; state=%d), balance_changed('manual', %+.2f, true) seen=%s" % [
			sk.manual, sk.GROUND, sk.state, bal["manual"], seen])
	# a) 4 manuals held with no correction
	var a_ok := true
	var a_parts: PackedStringArray = []
	for k in 4:
		if k > 0:
			ok = await _start_manual()
		if not ok:
			a_ok = false
			a_parts.append("no manual")
			continue
		var n_bail := bails.size()
		var t0 := frame
		var worst := 0.0
		while sk.manual != "" and sk.state == sk.GROUND and frame - t0 < 600:
			worst = maxf(worst, absf(bal["manual"]))
			await frames(1)
		var reason := last_bail(n_bail)
		if reason != "manual":
			a_ok = false
		a_parts.append("bail '%s' after %.2f s at |%.2f|" % [reason if reason != "" else "none", (frame - t0) / FPS, worst])
	check(a_ok, "holding the manual without correcting eventually bails", "4 manuals: " + "; ".join(a_parts))
	# b) 3 manuals corrected against the meter (Up tips a leaning-back manual forward again)
	var b_ok := true
	var b_parts: PackedStringArray = []
	var total_rec := 0
	var up_frames := 0
	var up_gain := 0
	for k in 3:
		ok = await _start_manual()
		if not ok:
			b_ok = false
			b_parts.append("no manual")
			continue
		var n_bail := bails.size()
		var t0 := frame
		var worst := 0.0
		var correcting := 0.0
		var recoveries := 0
		var excursion := false
		var v0: float = sk.vel.length()
		while sk.manual != "" and frame - t0 < 360:
			var b: float = bal["manual"]
			worst = maxf(worst, absf(b))
			if absf(b) > 0.4:
				correcting = signf(b)
				excursion = true
			elif absf(b) < 0.1 or signf(b) != correcting:
				if excursion and absf(b) < 0.15:
					recoveries += 1
					excursion = false
				correcting = 0.0
			set_key(KEY_W, correcting > 0.0)
			set_key(KEY_S, correcting < 0.0)
			var v_before: float = sk.vel.length()
			await frames(1)
			if held.get(KEY_W, false):
				up_frames += 1
				if sk.vel.length() > v_before + 0.001:
					up_gain += 1
		set_key(KEY_W, false)
		set_key(KEY_S, false)
		var t := (frame - t0) / FPS
		total_rec += recoveries
		if bails.size() != n_bail or sk.manual != "manual" or t < 5.99:
			b_ok = false
		b_parts.append("%.2f s, bail=%s, worst |%.2f|, %d recoveries, %.2f -> %.2f m/s" % [
				t, bails.size() != n_bail, worst, recoveries, v0, sk.vel.length()])
		await frames(2)
	check(b_ok and total_rec >= 2 and up_frames > 0 and up_gain == 0,
			"correcting the manual balance keeps the manual going (and Up balances instead of pushing)",
			"3 corrected 6 s manuals: %s; Up held on %d frames, speed rose on %d of them" % ["; ".join(b_parts), up_frames, up_gain])


# ------------------------------------------------------------------ 8. bails

func _air_run(on_air: Callable, max_air := 150) -> Dictionary:
	## Flat ollie (100 ms tap) at 6 m/s; on_air(air_frame) is called every airborne frame.
	await fresh(LANE, NORTH, 6.0)
	await frames(10)
	var n_land := lands.size()
	var n_bail := bails.size()
	key(KEY_SPACE, true)
	await frames(TAP)
	key(KEY_SPACE, false)
	await wait_state(sk.AIR, 10)
	var af := 0
	var yaw := 0.0
	var busy := 0.0
	var grab := -1
	while sk.state == sk.AIR and af < max_air:
		on_air.call(af)
		yaw = rad_to_deg(hz(sk.face_fwd).angle_to(hz(sk.vel)))
		busy = sk.trick_busy
		grab = sk.grab_idx
		await frames(1)
		af += 1
	release_all()
	await frames(2)
	return {"yaw": yaw, "busy": busy, "grab": grab, "air": af / FPS,
			"clean": lands.size() > n_land and bails.size() == n_bail,
			"reason": last_bail(n_bail), "fakie": sk.fakie}


func _bails() -> void:
	var quarter := int(round((PI / 2.0) / (sk.SPIN_RATE / FPS)))
	# sideways: spin a quarter turn in the air (hold spin-right) and land across the board
	var r: Dictionary = await _air_run(func(af): set_key(KEY_E, af >= 3 and af < 3 + quarter))
	check(r["reason"] == "sideways" and not r["clean"] and r["yaw"] > 60.0 and r["yaw"] < 120.0,
			"landing sideways (a 90 deg spin) bails",
			"board %.0f deg to the travel at touchdown, bail '%s'" % [r["yaw"], r["reason"]])
	# a half turn lands fakie: not a bail
	r = await _air_run(func(af): set_key(KEY_E, af >= 3 and af < 3 + quarter * 2))
	check(r["clean"] and r["reason"] == "" and r["yaw"] > 150.0 and r["fakie"],
			"a 180 lands fakie cleanly (only across-the-board landings bail)",
			"board %.0f deg to the travel, landed_clean=%s fakie=%s" % [r["yaw"], r["clean"], r["fakie"]])
	# a straight ollie with nothing going on lands clean
	r = await _air_run(func(_af): pass)
	check(r["clean"] and r["reason"] == "" and r["yaw"] < 10.0,
			"a straight landing does not bail", "board %.0f deg to the travel, landed_clean=%s" % [r["yaw"], r["clean"]])
	# kickflip too late: still flipping when the wheels touch
	var late := 26
	r = await _air_run(func(af): set_key(KEY_J, af >= late and af < late + 2))
	check(r["reason"] == "mid-trick" and not r["clean"] and r["busy"] > 0.06,
			"landing while still in a flip bails",
			"kickflip at %.2f s into a %.2f s ollie, %.2f s of flip left at touchdown, bail '%s'" % [
			late / FPS, r["air"], r["busy"], r["reason"]])
	# the same kickflip early enough is caught and lands clean
	r = await _air_run(func(af): set_key(KEY_J, af >= 2 and af < 4))
	check(r["clean"] and r["busy"] <= 0.06,
			"a kickflip finished before touchdown lands clean",
			"%.2f s of flip left at touchdown, landed_clean=%s" % [r["busy"], r["clean"]])
	# grab held all the way into the landing
	r = await _air_run(func(af): set_key(KEY_K, af >= 3))
	check(r["grab"] >= 0 and r["reason"] != "" and not r["clean"],
			"landing while still holding a grab bails",
			"grab held through touchdown (grab_idx %d on the last air frame), landed_clean=%s, bail '%s'" % [
			r["grab"], r["clean"], r["reason"]])
	# off-balance: a 30 deg vert air near the end of the halfpipe drifts off the ramp and comes
	# down on the flat floor beside it with the board still vertical
	var ob: Dictionary = await _vert_angled_run(-42.5, 30.0)
	var pl: Vector3 = ob["p_land"]
	check(ob["vert"] and ob["reason"] == "upside down" and not ob["clean"] and ob["tilt"] >= 60.0 and pl.z < HP_Z_MIN and pl.y < 0.5,
			"landing off-balance (board pitched ~90 deg to the ground) bails",
			"30 deg vert air at %.2f m/s taking off at z %.2f: drifted %.2f m along the coping past the ramp end (z %.2f), came down on the flat at y %.2f with the board %.0f deg off the ground normal, bail '%s'" % [
			vert_speed, ob["p0"].z, ob["dz"], pl.z, pl.y, ob["tilt"], ob["reason"]])
	# the same 30 deg vert air in the middle of the halfpipe comes back into the transition
	var ctl: Dictionary = await _vert_angled_run(-38.5, 30.0)
	check(ctl["vert"] and ctl["clean"] and ctl["tilt"] < 45.0,
			"the same 30 deg vert air inside the halfpipe lands balanced in the transition",
			"board %.0f deg off the ramp normal at touchdown (y %.2f, up.y %.2f), landed_clean=%s, bail '%s'" % [
			ctl["tilt"], ctl["p_land"].y, ctl["up_land"].y, ctl["clean"], ctl["reason"]])
	# vert air with an extra quarter spin comes back into the wall across the board
	await fresh(HP_CENTER, Vector3(-1, 0, 0), vert_speed)
	await wait_state(sk.AIR, 240)
	var vert: bool = sk.vert_air
	var n_land := lands.size()
	var n_bail := bails.size()
	var af := 0
	while sk.state == sk.AIR and af < 300:
		set_key(KEY_E, af >= 10 and af < 10 + quarter)
		await frames(1)
		af += 1
	set_key(KEY_E, false)
	await frames(2)
	var reason := last_bail(n_bail)
	check(vert and reason == "sideways" and lands.size() == n_land,
			"a vert air with an extra 90 deg spin lands sideways in the transition and bails",
			"vert_air=%s at %.2f m/s, %.2f s air, bail '%s'" % [vert, vert_speed, af / FPS, reason])
