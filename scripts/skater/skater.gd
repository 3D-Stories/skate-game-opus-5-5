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
const PUSH_ACCEL := 4.5         # mean over a push stride (the kick itself peaks ~3x)
const ROLL_FRICTION := 0.35
const DRAG := 0.0022
const BRAKE := 5.0
const TURN_RATE := 2.6
const SPIN_RATE := 7.2
const GRIND_RADIUS := 1.05
const GRIND_FRICTION := 0.35
const LAUNCH_ANGLE := 19.0
const PROBE_UP := 0.55
const HEAD_HEIGHT := 1.78       # top of the head above the feet (for ceilings and beams)
const BODY_RADIUS := 0.22
const RESPAWN_TIME := 2.2       # (fallback) respawn when a bail never comes to rest
const BAIL_REST := 0.5         # the ragdoll lies still this long before getting up
const BAIL_MAX := 5.0          # ... or gets up after this long regardless
const GETUP_TIME := 2.1        # longest hand-over + getup: 0.3 s + getup_front (54 frames)
const REVERT_TIME := 0.32      # pushing while fakie turns the skater around first
const PUMP := 3.6              # acceleration from pumping a transition (holding Up)
const PUMP_VMAX := 12.2        # pumping stops adding once the ride is worth this at the bottom
const PUMP_R := 3.2            # typical transition radius (estimates the height up the curve)

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
var bail_up := Vector3.UP                # surface under the fallen body
var getup_t := -1.0                      # >= 0 while getting up after a bail
var revert_t := 0.0                      # > 0 while turning round from fakie
var bail_grounded := false               # the ragdoll's hips are on the ground
var impact_t := -1.0                     # bail time of the latest hard impact (camera shake)
var _impacts := 0
var _rest_t := 0.0
var _rag_broken := false
var getup_clip := "getup"                # which getup the current bail ends with
const BLOOD_BONES := ["head", "spine_03", "spine_02", "pelvis", "upperarm_l", "upperarm_r", "thigh_l", "thigh_r"]
var _prev_v: Dictionary = {}              # ragdoll bone -> its velocity last step (impact speed)
var _head_slam := false
var bail_stats := {}                      # per bail: impacts, smear stamps, drips, pool (for the tests)
var _drips := 0
var _drip_budget := 0
var _drip_t := 0.0
var _bail_speed := 0.0
var _pooled := false
var bail_tumble := 1.0                   # tumble direction/strength of a bail (tests flip it)
var _spin_sign := 0.0                    # the way the player is spinning this air step (-1, 0, 1)
var head_fakie := 0.0                    # 0: regular look (towards the nose) .. 1: fakie look (towards the tail)
const HEAD_LEAD := deg_to_rad(60.0)      # in a spin the head is this far ahead of the board
var _last_pelvis := Vector3.ZERO
var _last_head := Vector3.ZERO
var _smear_left := 0.0                   # blood streak still to lay along the slide, m
var _smear_step := 0.0
var _dust_t := 0.0
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
	model.stop_ragdoll_now()
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
	# pumping: holding Up through the curve of a transition (down into it and back up the
	# other side) builds speed; without it the ramps only trade height for speed, minus
	# friction. It fades out once the ride is worth PUMP_VMAX at the bottom of the curve.
	if up.y < 0.97 and up.y > 0.08 and manual == "" and input_vec.y > 0.5 and vel.length() > 0.5:
		var worth := vel.length_squared() + 2.0 * G_GROUND * PUMP_R * (1.0 - up.y)
		vel += vel.normalized() * PUMP * clampf((PUMP_VMAX * PUMP_VMAX - worth) / 12.0, 0.0, 1.0) * h
	# pushing and braking (pushing while fakie first turns the skater round, like a revert)
	if fakie and manual == "" and crouch_t <= 0.0 and input_vec.y > 0.5 and up.y > 0.8 and revert_t <= 0.0:
		fakie = false
		revert_t = REVERT_TIME
		Sfx.play("land", null, -14.0, 1.4)
	var pushing := false
	if manual == "" and crouch_t <= 0.0 and input_vec.y > 0.5 and up.y > 0.8 and revert_t <= 0.0:
		pushing = true
		push_t += h
		if speed < PUSH_MAX:
			# one kick per 1.2 s push-clip cycle: the back foot drives on the ground over
			# phase 0.15-0.65, then the board glides (the mean equals PUSH_ACCEL)
			var ph := fmod(push_t / 1.2, 1.0)
			var kick := sin((ph - 0.15) / 0.5 * PI) if ph > 0.15 and ph < 0.65 else 0.0
			vel += heading * PUSH_ACCEL * h * (0.1 + 2.83 * kick)
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
	# the probe lifts the skater back onto a concave ramp (the step went along the tangent,
	# into the ramp): pay for that height out of the speed, or ramps would create energy
	var snap_dy: float = (hit["position"] as Vector3).y - global_position.y
	global_position = hit["position"]
	ground_collider = hit["collider"]
	if hn.y > 0.9:
		last_safe = global_position
	surface = level.surface_of(ground_collider)
	var sp := sqrt(maxf(0.0, vel.length_squared() - 2.0 * G_GROUND * snap_dy))
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
	# a touch of drift toward the room (~0.28 m over the whole air, however high it goes)
	var t_air := 2.0 * maxf(along.y, 0.0) / G
	var push_in := clampf(0.28 / maxf(t_air, 0.4), 0.12, 0.4)
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
	_spin_sign = signf(d_spin)
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
		if vel.y < 0.0:
			# coming back down into the same transition: settle the board onto its angle
			var reach := vel * 0.3
			var q := PhysicsRayQueryParameters3D.create(global_position, global_position + reach, 1)
			var lh := get_world_3d().direct_space_state.intersect_ray(q)
			if not lh.is_empty() and level.surface_of(lh["collider"]) == "wood":
				var ln: Vector3 = lh["normal"]
				if ln.dot(vert_normal) > 0.3 and ln.y > 0.05:
					var k := clampf(1.0 - (lh["position"] - global_position).length() / maxf(reach.length(), 0.01), 0.0, 1.0)
					face_up = _slerp(face_up, ln, k).normalized()
	else:
		face_up = _slerp(face_up, Vector3.UP, clampf(h * 3.5, 0.0, 1.0)).normalized()
		face_fwd = face_fwd.rotated(face_up.normalized(), d_spin).normalized()
		spin_deg += rad_to_deg(d_spin)
	face_fwd = (face_fwd - face_up * face_fwd.dot(face_up)).normalized()
	_air_tricks()
	# grind snap (a rafter just over the head wins over rails around the feet)
	if grind_cool <= 0.0 and (buf["grind"] >= 0.0 and _now - buf["grind"] < 0.35 or _action("grind")):
		var over := _head_hit(HEAD_HEIGHT + 0.5) if vel.y > -2.0 else {}
		if not over.is_empty() and _grind_from_below(over["position"]):
			return
		if _try_grind():
			return
	# head clearance: the body sweep below only covers the feet, so a low ceiling or a beam
	# overhead would pass through the skater's head. Bonk off it - or, holding grind under a
	# grindable rafter (the east one hangs above the quarter), get up onto it.
	if vel.y > 0.0:
		var hh := _head_hit(HEAD_HEIGHT + vel.y * h)
		if not hh.is_empty():
			if grind_cool <= 0.0 and (buf["grind"] >= 0.0 and _now - buf["grind"] < 0.35 or _action("grind")) \
					and _grind_from_below(hh["position"]):
				return
			vel.y = -0.5
			Sfx.play("wall", null, -8.0, 1.3)
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
	revert_t = maxf(0.0, revert_t - delta)
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
	if reason == "" and grab_idx >= 0 and _action("grab"):
		reason = "grab"          # still holding the grab at touchdown (THPS: let go before landing)
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

func _head_hit(reach: float) -> Dictionary:
	## Anything overhead within reach of the feet: five vertical rays across the shoulders
	## (a single one slips past the edge of a beam that the body still overlaps).
	## In a vert air the skater is right against the wall, so no ray starts on the wall's side
	## (it would begin inside the ramp and find the deck above); back faces never count.
	var space := get_world_3d().direct_space_state
	var offs := [Vector3.ZERO, Vector3(0.2, 0, 0), Vector3(-0.2, 0, 0), Vector3(0, 0, 0.2), Vector3(0, 0, -0.2)]
	if vert_air:
		var out := Vector3(vert_normal.x, 0.0, vert_normal.z).normalized()
		var along := out.cross(Vector3.UP).normalized()
		offs = [Vector3.ZERO, along * 0.2, -along * 0.2, out * 0.2]
	for o in offs:
		var q := PhysicsRayQueryParameters3D.create(global_position + o + Vector3.UP * 0.6, global_position + o + Vector3.UP * reach, 1)
		q.hit_back_faces = false
		var r := space.intersect_ray(q)
		if not r.is_empty() and (r["normal"] as Vector3).y < -0.3:
			return r
	return {}


func _grind_from_below(hit: Vector3) -> bool:
	## The head met the underside of a beam: if it is a grindable rafter, snap onto its top.
	var best := level.find_rail(hit, 0.7)
	if best.is_empty() or (best["rail"] as Rail).tag != Tricks.RAFTER_TAG:
		return false
	var keep := global_position
	global_position = (best["point"] as Vector3) - Vector3.UP * 0.05
	if _try_grind():
		return true
	global_position = keep
	return false


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
	# keep the speed along the rail, plus a little of the rest of the approach (never more
	# than the approach speed itself)
	grind_speed = maxf(2.5, lerpf(absf(along), vel.length(), 0.25))
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
	## A bail throws the skater into a ragdoll (the current pose, flung along the skater's
	## velocity with a forward tumble); the board flies off as a rigid body of its own.
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
	getup_t = -1.0
	revert_t = 0.0
	impact_t = -1.0
	_impacts = 0
	_prev_v.clear()
	_head_slam = false
	_pooled = false
	bail_stats = {"impacts": 0, "smears": 0, "slide_frames": 0, "drips": 0, "pool": false}
	_bail_speed = vel.length()
	_drips = 0
	_drip_t = 0.0
	_drip_budget = int(clampf((_bail_speed - 3.0) * 2.5, 0.0, 22.0))
	_rag_broken = false
	_last_pelvis = global_position
	_last_head = global_position + Vector3.UP
	_rest_t = 0.0
	_smear_left = clampf(vel.length() * 0.6, 1.2, 5.0)
	_smear_step = 0.0
	if fakie:
		heading = -heading
		fakie = false
	var v := vel.limit_length(9.0)
	# on (or just above) a surface the fall starts along it: the part of the velocity going
	# into the ramp or floor turns into a small bounce, so the body skids off the transition
	var under := _probe(global_position + Vector3.UP * 0.3, Vector3.UP, 0.3, 1.2)
	if not under.is_empty():
		var un: Vector3 = (under["normal"] as Vector3).normalized()
		var into := v.dot(un)
		if into < 0.0:
			v -= un * into * 1.15
	var fwd := Vector3(v.x, 0.0, v.z)
	fwd = fwd.normalized() if fwd.length() > 0.5 else Vector3(heading.x, 0.0, heading.z).normalized()
	var spin := Vector3.UP.cross(fwd) * clampf(v.length() * 0.8, 1.5, 6.5) * bail_tumble + Vector3.UP * _rng.randf_range(-1.5, 1.5)
	model.restart("bail", 0.05)
	model.start_ragdoll(v + Vector3.UP * 0.8, spin)
	Sfx.play("bail")
	Sfx.play("bail_voice", null, -6.0, _rng.randf_range(0.9, 1.1))
	var hit := _probe(global_position, Vector3.UP, 1.0, 30.0)
	if not hit.is_empty():
		respawn_pos = hit["position"]
	bailed.emit(reason)
	state_changed.emit(state)


func _bail_update(h: float) -> void:
	## Follow the ragdoll (the skater node sits on the ground under its hips, for the camera
	## and the sounds); blood where the head, chest or hips slam into the ground, a smeared
	## streak and scrape dust while the body slides; once it lies still, get up.
	bail_t += h
	if getup_t >= 0.0:
		_getup_update(h)
		return
	var P := model.rag_pos("pelvis")
	var pv: Vector3 = (model.rag["pelvis"] as PhysicalBone3D).linear_velocity
	var g := _probe(P, Vector3.UP, 0.3, 3.0)
	bail_grounded = false
	if not g.is_empty():
		global_position = g["position"]
		surface = level.surface_of(g["collider"])
		bail_up = (g["normal"] as Vector3).normalized()
		bail_grounded = P.distance_to(g["position"]) < 0.35
	else:
		global_position = P
	vel = pv
	# impacts come from the ragdoll's own contacts, so a slam registers on any surface angle
	# (the floor, a transition, a wall): blood where the head, chest, hips or a limb hits hard
	var sliding := false
	var slide_n := Vector3.UP
	var slide_p := Vector3.ZERO
	var slide_v := Vector3.ZERO
	for k in BLOOD_BONES:
		var pb: PhysicalBone3D = model.rag[k]
		var st := PhysicsServer3D.body_get_direct_state(pb.get_rid())
		var prev: Vector3 = _prev_v.get(k, pb.linear_velocity)
		_prev_v[k] = pb.linear_velocity
		if st == null:
			continue
		for i in st.get_contact_count():
			if st.get_contact_collider_object(i) is PhysicalBone3D:
				continue                  # the ragdoll touching itself (an arm on the chest): no impact
			var cp := st.get_contact_local_position(i)
			var n := st.get_contact_local_normal(i).normalized()
			if n.dot(pb.global_position - cp) < 0.0:
				n = -n                                      # from the surface towards the body
			var slam := -prev.dot(n)
			var heavy: bool = k in ["head", "spine_03", "spine_02", "pelvis"]
			if slam > (1.2 if heavy else 2.0) and bail_t - impact_t > 0.1:
				impact_t = bail_t
				_impacts += 1
				bail_stats["impacts"] = _impacts
				Sfx.play("land_hard", cp, -1.0, _rng.randf_range(0.7, 0.85))
				if _impacts <= 10:
					level.blood_splat(cp + n * 0.004, n, clampf(0.35 + slam * 0.1, 0.4, 1.0) * (1.0 if heavy else 0.7), prev)
					# spatter around it on the same surface, thrown mostly ahead along the travel
					# and to the sides - so some shows beside the body, not only under it
					var along := prev - n * prev.dot(n)
					var fwd := along.normalized() if along.length() > 0.3 else n.cross(Vector3.RIGHT).normalized()
					var side := n.cross(fwd).normalized()
					for sat in (2 if slam > 2.0 else 1):
						var off := fwd * _rng.randf_range(0.25, 0.7) + side * _rng.randf_range(-0.45, 0.45)
						level.blood_splat(cp + off + n * 0.004, n, _rng.randf_range(0.2, 0.45), prev)
				if _impacts <= 3 or k == "head":
					level.blood_burst(cp + n * 0.05, n * 0.7 + prev.normalized() * 0.5)
				if k == "head" and slam > 2.5:
					_head_slam = true
			if heavy:
				var along := pb.linear_velocity - n * pb.linear_velocity.dot(n)
				if along.length() > slide_v.length():
					sliding = true
					slide_n = n
					slide_p = cp
					slide_v = along
	bail_grounded = bail_grounded or sliding
	# once it has hit, blood drips from the head and chest while the body tumbles on: each
	# drop stains whatever is below it (floor or ramp) - a trail along the path, in view
	if _impacts > 0 and _drips < _drip_budget:
		_drip_t -= h
		var src: PhysicalBone3D = model.rag["head" if _rng.randf() < 0.5 else "spine_03"]
		if _drip_t <= 0.0 and src.linear_velocity.length() > 1.5:
			_drip_t = _rng.randf_range(0.04, 0.09)
			var below := get_world_3d().direct_space_state.intersect_ray(
					PhysicsRayQueryParameters3D.create(src.global_position, src.global_position + Vector3.DOWN * 3.0, 1))
			if not below.is_empty():
				_drips += 1
				bail_stats["drips"] = _drips
				var jit := Vector3(_rng.randf_range(-0.15, 0.15), 0.0, _rng.randf_range(-0.15, 0.15))
				level.blood_splat((below["position"] as Vector3) + jit, below["normal"], _rng.randf_range(0.08, 0.2), src.linear_velocity)
	if sliding and slide_v.length() > 0.7:
		bail_stats["slide_frames"] = int(bail_stats.get("slide_frames", 0)) + 1
		# the slide: a smeared streak along the surface (a ramp too) for the first metres
		if _smear_left > 0.0 and _impacts > 0:
			_smear_step += slide_v.length() * h
			if _smear_step > 0.2:
				_smear_step = 0.0
				_smear_left -= 0.2
				bail_stats["smears"] = int(bail_stats.get("smears", 0)) + 1
				level.blood_splat(slide_p + slide_n * 0.004, slide_n, _rng.randf_range(0.24, 0.36), slide_v, true)
		_dust_t -= h
		if _dust_t <= 0.0 and slide_v.length() > 2.0:
			_dust_t = 0.09
			level.dust(slide_p + slide_n * 0.1, slide_v)
	_rest_t = _rest_t + h if model.rag_speed() < 0.35 else 0.0
	# a broken simulation (a capsule caught behind a surface and flung) never shows: keep
	# the body at its last sane place and get up there
	if model.rag_speed() > 22.0 or not P.is_finite():
		model.stop_ragdoll_now()
		_rag_broken = true
		_start_getup()
		return
	model.rag_clamp(16.0)
	_last_pelvis = P
	_last_head = model.rag_pos("head")
	if _rest_t > 0.2 and not _pooled and (_head_slam or _impacts >= 3 or _bail_speed > 3.5):
		# it hurt: a pool spreads under the head where the body came to rest
		_pooled = true
		bail_stats["pool"] = true
		var hp := model.rag_pos("head")
		var gh := _probe(hp, Vector3.UP, 0.4, 1.0)
		if not gh.is_empty():
			level.blood_splat((gh["position"] as Vector3) + (gh["normal"] as Vector3) * 0.005, gh["normal"], _rng.randf_range(0.7, 0.95))
	if P.y < -5.0:
		_respawn_safe()
	elif (_rest_t > BAIL_REST and bail_t > 1.0) or bail_t > BAIL_MAX:
		_start_getup()


func _start_getup() -> void:
	## Hand the settled ragdoll over to the getup clip that starts the way it lies (on its
	## back or its front): turn and place the model so the clip's first pose lies where the
	## body is, steer the ragdoll into that pose, fade it out into the clip, and bring the
	## board back.
	getup_t = 0.0
	vel = Vector3.ZERO
	getup_clip = model.getup_for_rest() if not _rag_broken else "getup"
	var lie: Dictionary = model.lie.get(getup_clip, {})
	var P := model.rag_pos("pelvis") if not _rag_broken else _last_pelvis
	var ax := (model.rag_pos("head") if not _rag_broken else _last_head) - P
	ax.y = 0.0
	ax = ax.normalized() if ax.length() > 0.05 else Vector3(heading.x, 0.0, heading.z).normalized()
	var g := _probe(P, Vector3.UP, 0.5, 3.0)
	var n := Vector3.UP
	var ground := Vector3(P.x, global_position.y, P.z)
	if not g.is_empty():
		n = (g["normal"] as Vector3).normalized()
		ground = g["position"]
	if n.y < 0.5:
		n = Vector3.UP
	bail_up = n
	up = n
	face_up = n
	# the model's forward f such that basis * clip axis == ax (the clip axis is in model space)
	var lie_axis: Vector3 = lie.get("axis", Vector3.RIGHT)
	var lie_pelvis: Vector3 = lie.get("pelvis", Vector3.ZERO)
	var beta := Vector3.RIGHT.signed_angle_to(lie_axis, Vector3.UP)
	var f := (ax - n * ax.dot(n)).normalized().rotated(n, -beta)
	heading = f
	var b := Basis(f, n, f.cross(n))
	global_position = ground - b * Vector3(lie_pelvis.x, 0.0, lie_pelvis.z)
	model.global_transform = Transform3D(b, global_position)
	model.restart(getup_clip, 0.0)
	if model.ragdoll_on:
		model.begin_handover()
	model.recall_board(model.HANDOVER_HOLD + 0.4)
	loose_board = null


func _getup_update(h: float) -> void:
	getup_t += h
	vel = Vector3.ZERO
	face_up = _slerp(face_up, bail_up, clampf(h * 6.0, 0.0, 1.0))
	if getup_t < model.HANDOVER_HOLD + model.clip_length(getup_clip):
		return
	getup_t = -1.0
	state = GROUND
	up = bail_up
	face_up = up
	heading = (heading - up * heading.dot(up)).normalized()
	face_fwd = heading
	fakie = false
	_reset_tricks()
	model.play("idle", 0.2)
	state_changed.emit(state)


func _respawn_safe() -> void:
	## Fell somewhere the body cannot come to rest (off the park): start again at the last
	## safe spot on the flat.
	var fwd := heading
	fwd.y = 0.0
	if fwd.length() < 0.1:
		fwd = Vector3.FORWARD
	var at := global_position
	var g := _probe(at, Vector3.UP, 1.0, 30.0)
	if not g.is_empty() and g["normal"].y > 0.8 and at.y > -5.0:
		at = g["position"]
	else:
		at = last_safe if last_safe != Vector3.ZERO else level.spawn_pos
	loose_board = null
	getup_t = -1.0
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
	if revert_t > 0.0:
		# turning round from fakie: the body and board swing the last half-turn into place
		b = b.rotated(u, PI * smoothstep(0.0, 1.0, revert_t / REVERT_TIME))
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
	var at := global_position
	if state == BAIL:
		# the ragdoll places the bones itself; the model stays where the bail (or the
		# hand-over to the getup) put it
		pass
	else:
		model.global_transform = Transform3D(b.orthonormalized(), at)
	# the head spots the landing. In the air it tracks the direction of travel relative to
	# the chest (the chest faces the model's +Z; the nose is at +90 deg, where the authored
	# regular look turns the head 45 deg), leading into a spin: frontside it swings through
	# the travel direction, backside it whips early over the leading shoulder, up to the
	# neck's range. head_fakie 0 = the regular look, 1 = the fakie look (ride_fakie).
	var want_look := head_fakie
	var rate := 6.0
	if state == AIR and not vert_air:
		var vh := Vector3(vel.x, 0.0, vel.z)
		var chest := face_fwd.cross(face_up)
		chest.y = 0.0
		if vh.length() > 1.0 and chest.length() > 0.1:
			var psi := rad_to_deg(chest.normalized().signed_angle_to(vh.normalized(), Vector3.UP))
			# spinning, the travel direction moves round the chest the other way (sigma):
			# look ahead to where it is going, and once it is about to pass behind the back
			# turn straight to the shoulder it will come round on (no swing the wrong way first)
			var sigma := -_spin_sign
			if sigma != 0.0:
				psi = wrapf(psi + rad_to_deg(HEAD_LEAD) * sigma, -180.0, 180.0)
				if sigma > 0.0 and psi > 90.0:
					psi -= 360.0
				elif sigma < 0.0 and psi < -90.0:
					psi += 360.0
			var yaw := psi * 0.5 if absf(psi) <= 90.0 else signf(psi) * minf(45.0 + (absf(psi) - 90.0), 100.0)
			want_look = (45.0 - yaw) / 95.0
			rate = 12.0
	elif state == GROUND or state == GRIND:
		want_look = 1.0 if fakie and revert_t <= 0.0 and model.current != "ride_fakie" else 0.0
	else:
		want_look = 0.0
	_spin_sign = 0.0 if state != AIR else _spin_sign
	head_fakie = move_toward(head_fakie, want_look, delta * rate)
	if model.head_look:
		model.head_look.amount = head_fakie
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
			model.play("ride_fakie" if fakie and revert_t <= 0.0 else "ride", 0.2)
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
	if state == BAIL and getup_t < 0.0 and bail_grounded and Vector3(vel.x, 0, vel.z).length() > 0.8:
		var scrape := Sfx.stream("grind_" + ("wood" if surface == "wood" else "concrete"))
		if grind_player.stream != scrape or not grind_player.playing:
			grind_player.stream = scrape
			grind_player.play()
		grind_player.volume_db = linear_to_db(clampf(sp / 7.0, 0.05, 0.8))
		grind_player.pitch_scale = clampf(0.45 + sp * 0.05, 0.4, 0.9)
	elif state == GRIND:
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
