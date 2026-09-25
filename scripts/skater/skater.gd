class_name Skater
extends Node3D
## THPS-style skateboard physics and trick input.
##
## The skater is a point on the board's contact patch that sticks to surfaces with ray
## probes against the park's collision. On the ground gravity is projected on the surface
## so transitions carry momentum (pumping works), steering carves around the surface
## normal, and convex edges / lips launch into the air. Leaving a vertical ramp is a "vert
## air": the skater goes straight up, turns 180 and comes back into the transition.
## Grinds snap to the nearest rail with a balance meter; manuals balance on one truck.

signal trick(name: String)
signal landed_clean
signal bailed(reason: String)
signal state_changed(state: int)
signal rafter_grind
signal balance_changed(kind: String, value: float, active: bool)

enum { GROUND, AIR, GRIND, BAIL }

const G := 13.5                # gravity in the air (snappy)
const G_GROUND := 10.5         # gravity along ramps: carries more speed up the transitions
const JUMP := 5.3
const MAX_SPEED := 17.0
const PUSH_MAX := 10.0
const PUSH_ACCEL := 6.0
const ROLL_FRICTION := 0.35
const DRAG := 0.0022
const BRAKE := 5.0
const TURN_RATE := 2.6
const SPIN_RATE := 7.2
const GRIND_RADIUS := 1.05
const GRIND_FRICTION := 0.35
const LAUNCH_ANGLE := 19.0
const PROBE_UP := 0.55
const BODY_RADIUS := 0.22
const RESPAWN_TIME := 2.2
const PUMP := 7.0              # extra acceleration dropping into a transition (holding Up)

var level: Level
var score: ScoreKeeper
var controls_enabled := true
var autopilot: Node = null     # optional input source (demo/recording)

var state := GROUND
var vel := Vector3.ZERO
var up := Vector3.UP
var heading := Vector3.FORWARD          # direction of travel on the surface
var fakie := false                       # board nose points against travel
var face_up := Vector3.UP                # visual up in the air
var face_fwd := Vector3.FORWARD          # visual board direction in the air
var surface := "concrete"
var ground_collider: Object = null
var air_time := 0.0
var spin_deg := 0.0
var vert_air := false
var vert_normal := Vector3.ZERO
var vert_spin_target := 0.0
var vert_spin_done := 0.0
var vert_takeoff_fwd := Vector3.ZERO
var vert_total_time := 1.0
var vert_rot := PI                       # automatic rotation that lines the board up for the landing
var launch_up := Vector3.UP
var crouch_t := 0.0
var land_t := 0.0
var bank_t := -1.0
var push_t := 0.0
var bail_t := 0.0
var respawn_pos := Vector3.ZERO

# tricks
var trick_busy := 0.0          # >0 while a flip animation is in progress (landing = bail)
var trick_anim := ""
var grab_idx := -1
var grab_info: Dictionary = {}
var special_busy := false
var air_tricks_done := 0
var buf := {"jump_rel": -1.0, "flip": -1.0, "grab": -1.0, "grind": -1.0}
var dir_hist: Array = []       # [dir, time]
var manual := ""
var manual_idx := -1
var manual_bal := 0.0
var manual_bal_v := 0.0
var manual_t := 0.0
var grind_rail: Rail = null
var grind_s := 0.0
var grind_sign := 1.0
var grind_speed := 0.0
var grind_idx := -1
var grind_info: Dictionary = {}
var grind_bal := 0.0
var grind_bal_v := 0.0
var grind_t := 0.0
var grind_cool := 0.0
var rafter_time := 0.0
var last_rail_name := ""
var hitbox: AnimatableBody3D
var _shape := SphereShape3D.new()
var _rng := RandomNumberGenerator.new()
var _now := 0.0
var input_vec := Vector2.ZERO
var loose_board: RigidBody3D
var last_safe := Vector3.ZERO

@onready var model: SkaterModel = $Model
@onready var roll_player: AudioStreamPlayer = $RollSound
@onready var grind_player: AudioStreamPlayer = $GrindSound
@onready var wind_player: AudioStreamPlayer = $WindSound


func _ready() -> void:
	_shape.radius = BODY_RADIUS
	hitbox = AnimatableBody3D.new()
	hitbox.name = "Hitbox"
	hitbox.collision_layer = 2
	hitbox.collision_mask = 0
	hitbox.sync_to_physics = false
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.3
	cap.height = 1.3
	cs.shape = cap
	cs.position = Vector3(0, 0.8, 0)
	hitbox.add_child(cs)
	add_child(hitbox)
	hitbox.top_level = true
	_rng.randomize()


func setup(lvl: Level, sk: ScoreKeeper) -> void:
	level = lvl
	score = sk
	roll_player.stream = Sfx.stream("roll_concrete")
	grind_player.stream = Sfx.stream("grind_metal")
	wind_player.stream = Sfx.stream("wind")
	for p in [roll_player, grind_player, wind_player]:
		p.volume_db = -60.0
		p.play()


func spawn(pos: Vector3, forward: Vector3, speed := 0.0) -> void:
	global_position = pos
	respawn_pos = pos
	last_safe = pos
	heading = forward.normalized()
	vel = heading * speed
	up = Vector3.UP
	face_up = up
	face_fwd = heading
	fakie = false
	state = GROUND
	_reset_tricks()
	model.reattach_board()
	if loose_board:
		loose_board = null
	model.restart("ride" if speed > 0.5 else "idle", 0.0)
	_place_model(1.0)


func _reset_tricks() -> void:
	trick_busy = 0.0
	trick_anim = ""
	grab_idx = -1
	special_busy = false
	manual = ""
	grind_rail = null
	spin_deg = 0.0
	vert_air = false
	air_tricks_done = 0
	bank_t = -1.0


# ------------------------------------------------------------------ input

func _action(name: String) -> bool:
	if autopilot:
		return autopilot.pressed(name)
	return controls_enabled and Input.is_action_pressed(name)


func _just(name: String) -> bool:
	if autopilot:
		return autopilot.just_pressed(name)
	return controls_enabled and Input.is_action_just_pressed(name)


func _released(name: String) -> bool:
	if autopilot:
		return autopilot.just_released(name)
	return controls_enabled and Input.is_action_just_released(name)


func _read_input() -> void:
	var v := Vector2.ZERO
	if autopilot:
		v = autopilot.stick()
	elif controls_enabled:
		v = Input.get_vector("left", "right", "down", "up")
	input_vec = v
	for d in ["up", "down", "left", "right"]:
		if _just(d):
			dir_hist.append([d, _now])
	while dir_hist.size() > 6:
		dir_hist.pop_front()
	for k in ["flip", "grab", "grind"]:
		if _just(k):
			buf[k] = _now
	if _released("jump"):
		buf["jump_rel"] = _now


func _dir() -> String:
	var v := input_vec
	if v.length() < 0.45:
		return ""
	if absf(v.x) > absf(v.y):
		return "right" if v.x > 0 else "left"
	return "up" if v.y > 0 else "down"


func _buffered(k: String, window := 0.18) -> bool:
	if buf[k] >= 0.0 and _now - buf[k] <= window:
		buf[k] = -1.0
		return true
	return false


func _seq(a: String, b: String, window := 0.35) -> bool:
	## True if direction a then b were tapped within the window (THPS manual input).
	var n := dir_hist.size()
	if n < 2:
		return false
	var last: Array = dir_hist[n - 1]
	var prev: Array = dir_hist[n - 2]
	if last[0] == b and prev[0] == a and _now - float(prev[1]) <= window and _now - float(last[1]) < 0.2:
		dir_hist.clear()
		return true
	return false


# ------------------------------------------------------------------ main loop

func _physics_process(delta: float) -> void:
	_now += delta
	if level == null:
		return
	_read_input()
	grind_cool = maxf(0.0, grind_cool - delta)
	var steps := 1 if vel.length() < 7.0 else 2
	var h := delta / steps
	for i in steps:
		match state:
			GROUND:
				_ground(h)
			AIR:
				_air(h)
			GRIND:
				_grind(h)
			BAIL:
				_bail_update(h)
	_trick_timers(delta)
	_place_model(delta)
	_sounds(delta)
	hitbox.global_position = global_position
	if score:
		score.tick(delta)


# ------------------------------------------------------------------ ground

func _ground(h: float) -> void:
	up = up.normalized()
	heading = heading.normalized()
	var speed := vel.length()
	# jump / crouch
	if _action("jump"):
		crouch_t += h
	var jumped := false
	if _buffered("jump_rel", 0.12):
		jumped = true
	# grind from the ground: auto-pop onto a nearby ledge/rail
	if not jumped and buf["grind"] >= 0.0 and _now - buf["grind"] < 0.05:
		var near := level.find_rail(global_position + Vector3.UP * 0.5, 1.2)
		if near.size() > 0 and near["point"].y - global_position.y < 1.1 and near["point"].y > global_position.y - 0.2:
			jumped = true
	if jumped:
		_ollie()
		return
	# manual input
	if manual == "":
		if _seq("up", "down"):
			_start_manual("manual")
		elif _seq("down", "up"):
			_start_manual("nose")
	# forces: gravity along the surface
	var g := Vector3(0, -G_GROUND, 0)
	vel += (g - up * g.dot(up)) * h
	# pumping: dropping down a transition builds speed, more so while holding Up
	if up.y < 0.97 and up.y > 0.05 and vel.y < -0.3 and manual == "":
		var pump := PUMP * (1.0 if input_vec.y > 0.5 else 0.4)
		vel += vel.normalized() * pump * (1.0 - up.y) * h
	# pushing and braking
	var pushing := false
	if manual == "" and crouch_t <= 0.0 and input_vec.y > 0.5 and up.y > 0.8:
		pushing = true
		push_t += h
		if speed < PUSH_MAX:
			vel += heading * PUSH_ACCEL * h * (0.6 + 0.8 * clampf(sin(push_t * TAU / 1.2) * 0.5 + 0.5, 0.0, 1.0))
	else:
		push_t = 0.0
	if manual == "" and input_vec.y < -0.5 and crouch_t <= 0.0 and up.y > 0.8:
		vel = vel.move_toward(Vector3.ZERO, BRAKE * h)
	# rolling resistance + drag (less on smooth wood)
	var fr := ROLL_FRICTION * (0.7 if surface == "wood" else 1.0)
	speed = vel.length()
	vel = vel.move_toward(Vector3.ZERO, (fr + DRAG * speed * speed) * h)
	# steering: carve around the surface normal
	var turn := -input_vec.x * TURN_RATE * (1.0 if manual == "" else 0.6) * lerpf(1.2, 0.75, clampf(speed / 12.0, 0.0, 1.0))
	if absf(turn) > 0.0:
		vel = vel.rotated(up, turn * h)
		heading = heading.rotated(up, turn * h).normalized()
	if vel.length() > MAX_SPEED:
		vel = vel.normalized() * MAX_SPEED
	# travel direction / fakie tracking
	if vel.length() > 0.25:
		var vdir := vel.normalized()
		if vdir.dot(heading) < -0.2:
			fakie = not fakie
		heading = vdir
	# move with wall collision
	var motion := vel * h
	var from := global_position + up * (BODY_RADIUS + 0.25)
	var col := _sweep(from, motion)
	if col.size() > 0:
		var n: Vector3 = col["normal"]
		if col.has("collider") and col["collider"] and col["collider"].has_meta("breakable") and vel.length() > 3.5:
			level.break_wall()
			global_position += motion
		elif n.dot(up) < 0.55:
			var into := -vel.dot(n)
			global_position += motion * col["safe"]
			if into > 4.5:
				Sfx.play("land_hard", null, -4.0, 0.8)
			# head-on into a wall: bounce back a little; glancing: slide along it
			vel -= n * vel.dot(n) * (1.25 if vel.normalized().dot(-n) > 0.8 else 1.0)
			vel *= 0.8
			heading = (vel.normalized() if vel.length() > 0.3 else heading)
		else:
			global_position += motion
	else:
		global_position += motion
	# stick to the ground
	var probe_down := 0.12 + vel.length() * h * 1.6
	var hit := _probe(global_position, up, PROBE_UP, probe_down)
	var rolled_over := false
	if hit.is_empty() and vel.length() < 14.0 and vel.y < 0.6 and manual == "":
		# over a convex lip that falls away (drop-in, funbox top, bank): roll over it
		var hit2 := _probe(global_position, up, PROBE_UP, 0.7)
		if not hit2.is_empty() and rad_to_deg(up.angle_to(hit2["normal"])) < 72.0 and hit2["normal"].dot(vel) > 0.0 \
				and (global_position - hit2["position"]).dot(up) < 0.45:
			hit = hit2
			rolled_over = true
	if hit.is_empty() and up.y > 0.9 and vel.y < 0.5 and manual == "" and _drop_in():
		return
	if hit.is_empty():
		_leave_ground()
		return
	var hn: Vector3 = (hit["normal"] as Vector3).normalized()
	var ang := rad_to_deg(up.angle_to(hn))
	if not rolled_over and ang > LAUNCH_ANGLE and hn.dot(vel) > 0.3 and vel.length() > 7.5 and vel.y > 0.3:
		# convex edge crossed while rising (bank top, kicker lip): pop off it
		_leave_ground()
		return
	if ang > 75.0 or (hn.y < 0.5 and level.surface_of(hit["collider"]) == "wall"):
		_leave_ground()
		return
	global_position = hit["position"]
	ground_collider = hit["collider"]
	if hn.y > 0.9:
		last_safe = global_position
	surface = level.surface_of(ground_collider)
	var sp := vel.length()
	up = _slerp(up, hn, clampf(h * 22.0, 0.0, 1.0)).normalized()
	vel -= up * vel.dot(up)
	if vel.length() > 0.001:
		vel = vel.normalized() * sp
	heading = (heading - up * heading.dot(up)).normalized()
	crouch_t = crouch_t if _action("jump") else 0.0
	if manual != "":
		_manual_update(h)
	elif bank_t >= 0.0:
		bank_t += h
		if bank_t > 0.28:
			_bank()


func _drop_in() -> bool:
	## Rolling slowly off a deck over the coping: tip over onto the ramp face below
	## (a drop-in) instead of free-falling off the lip.
	var hd := Vector3(heading.x, 0, heading.z)
	if hd.length() < 0.5:
		return false
	hd = hd.normalized()
	var space := get_world_3d().direct_space_state
	var a := global_position - Vector3.UP * 0.35 + hd * 0.35
	var q := PhysicsRayQueryParameters3D.create(a, a - hd * 0.8, 1)
	var r := space.intersect_ray(q)
	if r.is_empty():
		return false
	var n: Vector3 = r["normal"]
	if n.dot(hd) < 0.6 or n.y > 0.5 or level.surface_of(r["collider"]) != "wood":
		return false
	var sp := maxf(vel.length(), 1.5)
	up = n.normalized()
	global_position = r["position"]
	var down := Vector3.DOWN - up * Vector3.DOWN.dot(up)
	vel = down.normalized() * sp
	heading = vel.normalized()
	fakie = false
	return true


func _leave_ground() -> void:
	# steep surface moving up past the lip: vert air
	var steep := up.y < 0.35
	if steep and vel.y > 0.5:
		_start_vert_air()
	else:
		_start_air(false)


func _ollie() -> void:
	var charge := clampf(crouch_t / 0.5, 0.0, 1.0)
	crouch_t = 0.0
	var jdir := (up * 0.65 + Vector3.UP * 0.35).normalized()
	if up.y < 0.35:
		# ollie off the lip of a vert wall: pop straight up for extra height
		jdir = Vector3.UP if vel.y > 0.0 else up
	vel += jdir * JUMP * (0.85 + 0.25 * charge) * (0.7 if up.y < 0.35 and vel.y > 0.0 else 1.0)
	global_position += jdir * 0.05
	Sfx.play("pop", null, -2.0, _rng.randf_range(0.95, 1.08))
	if manual != "":
		_end_manual(true)
	if up.y < 0.35 and vel.y > 0.5:
		_start_vert_air()
	else:
		_start_air(true)


func _start_air(from_ollie: bool) -> void:
	state = AIR
	air_time = 0.0
	spin_deg = 0.0
	vert_air = false
	air_tricks_done = 0
	launch_up = up
	face_up = up
	face_fwd = _board_dir()
	bank_t = -1.0
	if manual != "":
		# rolling off an edge in a manual keeps the combo going
		_end_manual(true)
	model.restart("ollie" if from_ollie else "air", 0.08)
	state_changed.emit(state)


func _start_vert_air() -> void:
	state = AIR
	air_time = 0.0
	spin_deg = 0.0
	air_tricks_done = 0
	vert_air = true
	bank_t = -1.0
	vert_normal = Vector3(up.x, 0, up.z).normalized()
	if vert_normal.length() < 0.5:
		vert_normal = -Vector3(vel.x, 0, vel.z).normalized()
	# straight up and back down into the transition (a touch of drift toward the room)
	var along := vel - vert_normal * vel.dot(vert_normal)
	if level.in_halfpipe(global_position):
		# THPS-style auto-align: halfpipe airs come straight back down into the ramp
		var drift := Vector3(along.x, 0.0, along.z)
		along -= drift * 0.75
	var push_in := 0.35
	vel = along + vert_normal * push_in
	vert_total_time = maxf(0.2, 2.0 * vel.y / G)
	vert_takeoff_fwd = _board_dir()
	vert_takeoff_fwd = (vert_takeoff_fwd - vert_normal * vert_takeoff_fwd.dot(vert_normal)).normalized()
	# the skater comes back down along the mirror of the takeoff line (vertical part
	# reversed), so turn the board onto that: 180 straight up, less for angled airs
	var wall_up := (Vector3.UP - vert_normal * vert_normal.y).normalized()
	var vdir := (vel - vert_normal * vel.dot(vert_normal)).normalized()
	var land_dir := (vdir - wall_up * 2.0 * vdir.dot(wall_up)).normalized()
	if vert_takeoff_fwd.dot(vdir) < 0.0:
		land_dir = -land_dir
	vert_rot = atan2(vert_normal.dot(vert_takeoff_fwd.cross(land_dir)), vert_takeoff_fwd.dot(land_dir))
	if absf(vert_rot) > PI - 0.05:
		vert_rot = PI
	vert_spin_done = 0.0
	face_up = up
	face_fwd = vert_takeoff_fwd
	if manual != "":
		_end_manual(true)
	model.restart("vert_air", 0.12)
	state_changed.emit(state)


# ------------------------------------------------------------------ air

func _air(h: float) -> void:
	air_time += h
	vel += Vector3(0, -G, 0) * h
	vel *= (1.0 - 0.02 * h)
	# spins and air steering
	var spin_in := input_vec.x
	if _action("spin_left"):
		spin_in = -1.0
	elif _action("spin_right"):
		spin_in = 1.0
	if grab_idx >= 0 or trick_busy > 0.0:
		spin_in *= 0.8
	var d_spin := -spin_in * SPIN_RATE * h
	if vert_air:
		# automatic 180 about the ramp normal (finished just before touching back down)
		# plus any extra player spin, computed from the takeoff direction so it cannot drift
		var u := clampf(air_time / (vert_total_time * 0.85), 0.0, 1.0)
		vert_spin_done += d_spin
		spin_deg += rad_to_deg(d_spin)
		var rot := vert_rot * smoothstep(0.0, 1.0, u) + vert_spin_done
		face_fwd = vert_takeoff_fwd.rotated(vert_normal, rot).normalized()
		var tilt := 0.62 * sin(PI * u)
		face_up = _slerp(vert_normal, Vector3.UP, tilt).normalized()
	else:
		face_up = _slerp(face_up, Vector3.UP, clampf(h * 3.5, 0.0, 1.0)).normalized()
		face_fwd = face_fwd.rotated(face_up.normalized(), d_spin).normalized()
		spin_deg += rad_to_deg(d_spin)
	face_fwd = (face_fwd - face_up * face_fwd.dot(face_up)).normalized()
	_air_tricks()
	# grind snap
	if grind_cool <= 0.0 and (buf["grind"] >= 0.0 and _now - buf["grind"] < 0.35 or _action("grind")):
		if _try_grind():
			return
	# move / collide (body sphere, plus a ray along the feet's own path)
	var motion := vel * h
	var from := global_position + face_up * (BODY_RADIUS + 0.05)
	var col := _sweep(from, motion)
	if col.is_empty():
		col = _feet_ray(motion)
	if col.size() > 0:
		var n: Vector3 = col["normal"]
		var c: Object = col.get("collider")
		if c and c.has_meta("breakable") and vel.length() > 3.0:
			level.break_wall()
			global_position += motion
			return
		var into := -vel.normalized().dot(n)
		var ramp := level.surface_of(c) == "wood"
		var landable := n.y > 0.5 or (vert_air and ramp and absf(n.y) < 0.9 and vel.y < 0.0 and n.dot(vert_normal) > 0.5)
		if n.y > 0.2 and into > 0.05 and not vert_air:
			landable = true
		if landable and vel.dot(n) < 0.0:
			global_position += motion * col["safe"]
			_land(n, c)
			return
		elif n.y < -0.4:
			# ceiling
			global_position += motion * col["safe"]
			vel.y = minf(vel.y, 0.0)
		else:
			# wall: bounce off
			global_position += motion * col["safe"]
			vel -= n * vel.dot(n) * 1.3
			vel *= 0.8
	else:
		global_position += motion
	# ground check just below (for landings the sweep missed)
	if vel.y <= 0.0:
		var hit := _probe(global_position, Vector3.UP, 0.25, 0.05)
		if not hit.is_empty() and hit["normal"].y > 0.3:
			global_position = hit["position"]
			_land(hit["normal"], hit["collider"])
			return
	if global_position.y < -5.0:
		global_position = last_safe
		_bail("fell")


func _air_tricks() -> void:
	var d := _dir()
	# special: Left, Right + Flip with a full meter
	if score and score.special_ready and not special_busy and trick_busy <= 0.0 and grab_idx < 0:
		if buf["flip"] >= 0.0 and _now - buf["flip"] < 0.1 and _recent_seq("left", "right", 0.6):
			buf["flip"] = -1.0
			_do_special()
			return
	if trick_busy <= 0.0 and grab_idx < 0 and not special_busy and _buffered("flip", 0.15):
		var f: Dictionary = Tricks.FLIPS[d]
		_do_flip(f)
	elif trick_busy <= 0.0 and grab_idx < 0 and not special_busy and (_buffered("grab", 0.15)):
		var gi: Dictionary = Tricks.GRABS[d]
		grab_info = gi
		grab_idx = score.begin_trick(gi["name"], gi["points"])
		model.restart(gi["anim"], 0.1, 1.4)
		trick.emit(gi["name"])
		air_tricks_done += 1
	if grab_idx >= 0:
		if _action("grab"):
			score.add_hold(grab_idx, Tricks.GRAB_HOLD_RATE * get_physics_process_delta_time())
		else:
			grab_idx = -1
			model.play("vert_air" if vert_air else "air", 0.15)


func _recent_seq(a: String, b: String, window: float) -> bool:
	var n := dir_hist.size()
	for i in range(n - 1):
		if dir_hist[i][0] == a and dir_hist[i + 1][0] == b and _now - float(dir_hist[i][1]) <= window:
			return true
	return false


func _do_flip(f: Dictionary) -> void:
	var anim: String = f["anim"]
	var length := model.clip_length(anim)
	var dur := 0.48 if anim != "treflip" else 0.55
	trick_busy = dur * 0.84
	trick_anim = anim
	model.restart(anim, 0.05, length / dur)
	score.begin_trick(f["name"], f["points"])
	trick.emit(f["name"])
	air_tricks_done += 1


func _do_special() -> void:
	special_busy = true
	var length := model.clip_length("special")
	var dur := 1.0
	trick_busy = dur * 0.8
	trick_anim = "special"
	model.restart("special", 0.05, length / dur)
	score.begin_trick(Tricks.SPECIAL["name"], Tricks.SPECIAL["points"])
	trick.emit(Tricks.SPECIAL["name"])
	Sfx.play("special")
	air_tricks_done += 1


func _trick_timers(delta: float) -> void:
	if trick_busy > 0.0:
		trick_busy -= delta
		if trick_busy <= 0.0:
			trick_busy = 0.0
			if trick_anim != "":
				Sfx.play("catch", null, -6.0)
			trick_anim = ""
			special_busy = false
			if state == AIR and grab_idx < 0:
				model.play("vert_air" if vert_air else "air", 0.12)
	if land_t > 0.0:
		land_t -= delta


func _land(n: Vector3, collider: Object) -> void:
	var board := face_fwd
	var bp := (board - n * board.dot(n)).normalized()
	var vp := vel - n * vel.dot(n)
	var ok_up := face_up.dot(n)
	var reason := ""
	if trick_busy > 0.06:
		reason = "mid-trick"
	elif ok_up < 0.35:
		reason = "upside down"
	elif vp.length() > 1.5:
		var a := rad_to_deg(bp.angle_to(vp.normalized()))
		if a > 50.0 and a < 130.0:
			reason = "sideways"
	if grab_idx >= 0:
		grab_idx = -1
	if reason != "":
		up = n.normalized()
		heading = vp.normalized() if vp.length() > 0.2 else heading
		_bail(reason)
		return
	# clean landing: keep the speed along the surface (landing in a transition keeps flow)
	var impact := -vel.dot(n)
	vel = vp
	up = n.normalized()
	surface = level.surface_of(collider)
	if vp.length() > 0.2:
		var vdir := vp.normalized()
		fakie = bp.dot(vdir) < 0.0
		heading = vdir
	else:
		heading = bp
	# spin bonus for this air
	if not vert_air or absf(spin_deg) > 150.0:
		var sp := Tricks.spin_points(spin_deg)
		if sp > 0 and score.in_combo or sp > 0:
			score.begin_trick(Tricks.spin_name(spin_deg), sp)
	vert_air = false
	state = GROUND
	land_t = 0.35
	crouch_t = 0.0
	Sfx.play("land_hard" if impact > 8.0 else "land", null, -1.0, _rng.randf_range(0.95, 1.05))
	model.restart("land", 0.06, 1.3)
	landed_clean.emit()
	state_changed.emit(state)
	bank_t = 0.0 if score.in_combo else -1.0
	# a manual typed just before touching down
	if _seq("up", "down", 0.45):
		_start_manual("manual")
	elif _seq("down", "up", 0.45):
		_start_manual("nose")


func _bank() -> void:
	bank_t = -1.0
	if score.in_combo:
		var pts := score.land()
		if pts > 0:
			Sfx.play("combo", null, -8.0)


# ------------------------------------------------------------------ manuals

func _start_manual(kind: String) -> void:
	var info: Dictionary = Tricks.MANUAL if kind == "manual" else Tricks.NOSE_MANUAL
	manual = kind
	manual_idx = score.begin_trick(info["name"], info["points"])
	manual_bal = _rng.randf_range(-0.15, 0.15)
	manual_bal_v = 0.0
	manual_t = 0.0
	bank_t = -1.0
	model.restart(info["anim"], 0.12)
	trick.emit(info["name"])


func _manual_update(h: float) -> void:
	manual_t += h
	var info: Dictionary = Tricks.MANUAL if manual == "manual" else Tricks.NOSE_MANUAL
	score.add_hold(manual_idx, float(info["rate"]) * h)
	var diff := 1.0 + manual_t * 0.22
	var correct := input_vec.y if manual == "manual" else -input_vec.y
	manual_bal_v += (manual_bal * 2.4 + _rng.randf_range(-1.0, 1.0) * 1.9 * diff) * h - correct * 6.0 * h
	if autopilot and autopilot.has_method("balance_assist"):
		manual_bal_v += autopilot.balance_assist(manual_bal, manual_bal_v) * h
	manual_bal_v *= (1.0 - 1.8 * h)
	manual_bal += manual_bal_v * h
	balance_changed.emit("manual", manual_bal, true)
	if absf(manual_bal) > 1.0:
		_bail("manual")


func _end_manual(keep_combo: bool) -> void:
	manual = ""
	manual_idx = -1
	balance_changed.emit("manual", 0.0, false)


# ------------------------------------------------------------------ grinds

func _try_grind() -> bool:
	var probe := global_position + Vector3.UP * 0.1
	var best := level.find_rail(probe, GRIND_RADIUS)
	if best.is_empty():
		return false
	var p: Vector3 = best["point"]
	if p.y > global_position.y + 0.55:
		return false
	var dir: Vector3 = best["dir"]
	var along := vel.dot(dir)
	var hv := Vector3(vel.x, 0, vel.z)
	if absf(along) < 1.2 and hv.length() > 2.0:
		return false
	var rail: Rail = best["rail"]
	if rail.name == last_rail_name and grind_cool > 0.0:
		return false
	var d := _dir()
	var info: Dictionary = Tricks.GRINDS[d]
	if rail.tag == "coping" and d == "":
		info = Tricks.GRINDS[""]
	grind_rail = rail
	grind_s = best["s"]
	grind_sign = 1.0 if along >= 0.0 else -1.0
	grind_speed = maxf(2.5, absf(along) + hv.length() * 0.15)
	grind_info = info
	grind_idx = score.begin_trick(info["name"], info["points"])
	grind_bal = _rng.randf_range(-0.2, 0.2)
	grind_bal_v = 0.0
	grind_t = 0.0
	rafter_time = 0.0
	trick_busy = 0.0
	trick_anim = ""
	if grab_idx >= 0:
		grab_idx = -1
	state = GRIND
	vert_air = false
	buf["grind"] = -1.0
	last_rail_name = rail.name
	grind_player.stream = Sfx.stream("grind_" + ("metal" if rail.kind == "metal" else ("wood" if rail.kind == "wood" else "concrete")))
	grind_player.play()
	Sfx.play("land", null, -6.0, 1.4)
	model.restart(info["anim"], 0.08)
	trick.emit(info["name"])
	state_changed.emit(state)
	return true


func _grind(h: float) -> void:
	grind_t += h
	var dir := grind_rail.dir_at(grind_s) * grind_sign
	grind_speed -= G_GROUND * dir.y * h
	grind_speed -= GRIND_FRICTION * h
	grind_s += grind_sign * grind_speed * h
	score.add_hold(grind_idx, float(grind_info["rate"]) * h)
	if grind_rail.tag == Tricks.RAFTER_TAG:
		rafter_time += h
		if rafter_time > 0.6 and rafter_time - h <= 0.6:
			rafter_grind.emit()
	# balance
	var diff := 1.0 + grind_t * 0.2
	grind_bal_v += (grind_bal * 2.2 + _rng.randf_range(-1.0, 1.0) * 1.7 * diff) * h - input_vec.x * 6.0 * h
	if autopilot and autopilot.has_method("balance_assist"):
		grind_bal_v += autopilot.balance_assist(grind_bal, grind_bal_v) * h
	grind_bal_v *= (1.0 - 1.8 * h)
	grind_bal += grind_bal_v * h
	balance_changed.emit("grind", grind_bal, true)
	var p := grind_rail.point_at(grind_s)
	global_position = p
	heading = dir
	up = Vector3.UP
	vel = dir * grind_speed
	if absf(grind_bal) > 1.0:
		_end_grind()
		_bail("grind")
		return
	if _buffered("jump_rel", 0.15) or _just("jump"):
		_end_grind()
		# hop off to the side the stick points at (THPS-style directional exit)
		var side := dir.cross(Vector3.UP).normalized() * input_vec.x * 2.6
		vel = dir * grind_speed + Vector3.UP * JUMP * 0.9 + side
		global_position += Vector3.UP * 0.08
		Sfx.play("pop", null, -2.0)
		_start_air(true)
		return
	if grind_s <= 0.0 or grind_s >= grind_rail.length or grind_speed < 0.4:
		_end_grind()
		vel = dir * maxf(grind_speed, 1.0) + Vector3.UP * 1.2
		global_position += Vector3.UP * 0.05
		_start_air(false)


func _end_grind() -> void:
	grind_rail = null
	grind_idx = -1
	grind_cool = 0.35
	state = AIR
	grind_player.volume_db = -60.0
	balance_changed.emit("grind", 0.0, false)


# ------------------------------------------------------------------ bails

func _bail(reason: String) -> void:
	if state == BAIL:
		return
	state = BAIL
	bail_t = 0.0
	score.bail()
	_reset_tricks()
	manual = ""
	balance_changed.emit("manual", 0.0, false)
	balance_changed.emit("grind", 0.0, false)
	loose_board = model.detach_board(get_parent(), vel * 0.8 + Vector3.UP * 2.5)
	model.restart("bail", 0.05)
	Sfx.play("bail")
	Sfx.play("bail_voice", null, -6.0, _rng.randf_range(0.9, 1.1))
	# settle on the ground below
	var hit := _probe(global_position, Vector3.UP, 1.0, 30.0)
	if not hit.is_empty():
		respawn_pos = hit["position"]
		up = hit["normal"] if hit["normal"].y > 0.7 else Vector3.UP
	bailed.emit(reason)
	state_changed.emit(state)


func _bail_update(h: float) -> void:
	bail_t += h
	# slide to a stop along the floor
	var hit := _probe(global_position, Vector3.UP, 0.6, 3.0)
	vel += Vector3(0, -G, 0) * h
	if not hit.is_empty() and global_position.y - hit["position"].y < 0.05 + absf(vel.y) * h:
		global_position.y = hit["position"].y
		vel.y = 0.0
		vel = vel.move_toward(Vector3.ZERO, 7.0 * h)
	var motion := vel * h
	var col := _sweep(global_position + Vector3.UP * 0.4, motion)
	if col.size() > 0:
		global_position += motion * col["safe"]
		vel = Vector3.ZERO
	else:
		global_position += motion
	face_up = _slerp(face_up, Vector3.UP, h * 4.0).normalized()
	if bail_t > RESPAWN_TIME:
		var fwd := heading
		fwd.y = 0.0
		if fwd.length() < 0.1:
			fwd = Vector3.FORWARD
		var at := global_position
		var g := _probe(at, Vector3.UP, 1.0, 30.0)
		if not g.is_empty() and g["normal"].y > 0.8:
			at = g["position"]
		else:
			at = last_safe if last_safe != Vector3.ZERO else level.spawn_pos
		loose_board = null
		spawn(at, fwd.normalized(), 0.0)


# ------------------------------------------------------------------ visuals & sound

func _slerp(a: Vector3, b: Vector3, w: float) -> Vector3:
	## Vector3.slerp for unit vectors that tolerates (nearly) parallel inputs.
	if a.dot(b) > 0.99999:
		return b.normalized()
	return a.slerp(b, w).normalized()


func _board_dir() -> Vector3:
	return -heading if fakie else heading


func _place_model(delta: float) -> void:
	var u := up
	var f := _board_dir()
	if state == AIR:
		u = face_up
		f = face_fwd
	elif state == BAIL:
		u = face_up
	f = (f - u * f.dot(u))
	if f.length() < 0.01:
		f = u.cross(Vector3.RIGHT)
	f = f.normalized()
	var b := Basis(f, u, f.cross(u))
	if state == GRIND:
		var lean := grind_bal * 0.45
		b = b.rotated(f, lean)
		if grind_info.get("anim", "") == "boardslide":
			b = b.rotated(u, PI * 0.5)
	elif state == GROUND and manual == "":
		var lean := -input_vec.x * clampf(vel.length() / 8.0, 0.0, 1.0) * 0.22
		b = b.rotated(f, lean)
	elif manual != "":
		b = b.rotated(f, manual_bal * 0.25)
	model.global_transform = Transform3D(b.orthonormalized(), global_position)
	# animation choice on the ground
	if state == GROUND:
		if land_t > 0.0:
			pass
		elif manual != "":
			pass
		elif crouch_t > 0.0:
			model.play("crouch", 0.1)
		elif input_vec.y > 0.5 and up.y > 0.8 and vel.length() < PUSH_MAX + 0.5:
			model.play("push", 0.15)
		elif vel.length() < 0.35:
			model.play("idle", 0.3)
		else:
			model.play("ride", 0.2)
	if state != AIR and state != BAIL:
		model.spin_wheels(vel.length() * delta)


func _sounds(delta: float) -> void:
	Sfx.listener_pos = global_position
	var sp := vel.length()
	var rolling := state == GROUND and sp > 0.3
	var target_roll := linear_to_db(clampf(sp / 9.0, 0.0, 1.0) * 0.9) if rolling else -60.0
	roll_player.volume_db = lerpf(roll_player.volume_db, target_roll, clampf(delta * 12.0, 0.0, 1.0))
	roll_player.pitch_scale = clampf(0.65 + sp * 0.055, 0.5, 1.8)
	var want := "roll_" + ("wood" if surface == "wood" else ("metal" if surface == "metal" else "concrete"))
	if rolling and roll_player.stream != Sfx.stream(want):
		roll_player.stream = Sfx.stream(want)
		roll_player.play()
	if state == GRIND:
		grind_player.volume_db = lerpf(grind_player.volume_db, linear_to_db(clampf(0.4 + grind_speed / 12.0, 0.0, 1.0)), clampf(delta * 15.0, 0.0, 1.0))
		grind_player.pitch_scale = clampf(0.8 + grind_speed * 0.04, 0.6, 1.5)
	else:
		grind_player.volume_db = -60.0
	var wind := clampf((sp - 5.0) / 10.0, 0.0, 1.0) * (1.0 if state == AIR else 0.4)
	wind_player.volume_db = lerpf(wind_player.volume_db, linear_to_db(maxf(0.001, wind * 0.6)), clampf(delta * 6.0, 0.0, 1.0))


# ------------------------------------------------------------------ physics queries

func _feet_ray(motion: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var a := global_position + Vector3.UP * 0.05
	var q := PhysicsRayQueryParameters3D.create(a, a + motion * 1.05, 1)
	var r := space.intersect_ray(q)
	if r.is_empty():
		return {}
	var f := clampf((r["position"] - a).length() / maxf(motion.length(), 1e-5) - 0.02, 0.0, 1.0)
	return {"safe": f, "normal": r["normal"], "collider": r["collider"], "point": r["position"]}


func _probe(pos: Vector3, dir_up: Vector3, up_len: float, down_len: float) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(pos + dir_up * up_len, pos - dir_up * down_len, 1)
	q.hit_back_faces = false
	var r := space.intersect_ray(q)
	return r


func _sweep(from: Vector3, motion: Vector3) -> Dictionary:
	if motion.length() < 1e-5:
		return {}
	var space := get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = _shape
	q.transform = Transform3D(Basis.IDENTITY, from)
	q.motion = motion
	q.collision_mask = 1
	# cast_motion ignores contacts that already touch at the start, so a step that ended
	# flush against a thin wall would pass through it on the next one: check that first
	var start := space.get_rest_info(q)
	if not start.is_empty() and Vector3(start["normal"]).dot(motion) < 0.0:
		return {"safe": 0.0, "normal": Vector3(start["normal"]).normalized(),
				"collider": instance_from_id(start["collider_id"]), "point": start["point"]}
	var res := space.cast_motion(q)
	if res[0] >= 1.0:
		return {}
	var safe: float = res[0]
	q.transform = Transform3D(Basis.IDENTITY, from + motion * res[1])
	var info := space.get_rest_info(q)
	if info.is_empty():
		# contact too shallow for rest info: fall back to a ray along the motion
		var rq := PhysicsRayQueryParameters3D.create(from, from + motion.normalized() * (motion.length() + BODY_RADIUS + 0.1), 1)
		var r := space.intersect_ray(rq)
		if r.is_empty():
			return {"safe": safe, "normal": -motion.normalized(), "collider": null, "point": from + motion * safe}
		return {"safe": safe, "normal": r["normal"], "collider": r["collider"], "point": r["position"]}
	var nrm: Vector3 = info["normal"]
	return {"safe": safe, "normal": nrm.normalized(), "collider": instance_from_id(info["collider_id"]), "point": info["point"]}
