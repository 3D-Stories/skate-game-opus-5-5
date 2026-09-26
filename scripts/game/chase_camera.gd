class_name ChaseCamera
extends Camera3D
## THPS-style third-person camera: trails behind the direction of travel, looks ahead at
## speed, holds the ramp-facing view through vert airs (no spinning with the skater), and
## a sphere-cast spring arm keeps it out of walls, ramps and the roof.

@export var distance := 4.3
@export var height := 1.75
@export var look_height := 1.05
@export var follow_rate := 6.0
@export var yaw_rate := 3.2

var skater: Skater
var _yaw_dir := Vector3.FORWARD
var _pos := Vector3.ZERO
var _look := Vector3.ZERO
var _shape := SphereShape3D.new()
var _vert_hold := Vector3.ZERO
var _init := false
var shake := 0.0
var _swing := 0.0          # degrees the arm is swung round an obstacle (smoothed)
var _swing_lift := 0.0
var _last_good := Vector3.ZERO
var _side_amt := 0.0
var _thin := false         # a thin obstacle crosses the arm this frame (camera holds its distance)
var _turn_pref := 0.0      # way round (+1 / -1) of a big camera turn, latched while it lasts
var _fresh := true          # first frame after a snap: take the free swing at once
var _arm_free := true      # the arm was at its full length last frame (nothing in the way)
var _arm_len := -1.0        # the arm's eased length (-1: take the cast as it is)
var _rod_side := {}          # hanger rod id -> side (+1/-1) the camera passes it on
var _pivot := Vector3.ZERO  # the arm's start, offset from the head towards the open hall on grinds
## what the camera decided this frame (read by tests/frames.gd; cheap, always kept)
var dbg := {}
var _dbg_hit := ""
var record_hits := false   # also name what blocks the arm (one extra query per blocked cast)

const SWING_ANGLES := [0.0, 30.0, -30.0, 55.0, -55.0, 85.0, -85.0]
const HALL_CENTRE := Vector3(0.0, 3.0, -17.0)     # middle of the Warehouse floor (Godot axes)
const MIN_ARM := 1.5


func _ready() -> void:
	_shape.radius = 0.3
	fov = 68.0
	near = 0.05
	far = 400.0


func snap() -> void:
	## Place the camera at once (spawn, restart): no smoothing carried over from before.
	_init = false
	_arm_len = -1.0
	_fresh = true
	_swing = 0.0
	_swing_lift = 0.0
	_pivot = Vector3.ZERO
	_turn_pref = 0.0
	_rod_side.clear()


func _physics_process(delta: float) -> void:
	if skater == null:
		return
	var sp := skater.global_position
	var vel := skater.vel
	var hv := Vector3(vel.x, 0, vel.z)
	var desired_dir := _yaw_dir
	if skater.state == Skater.AIR and skater.vert_air:
		# look at the ramp from the room side, as THPS does, until we land
		if _vert_hold == Vector3.ZERO:
			_vert_hold = -skater.vert_normal
		desired_dir = _vert_hold
	else:
		_vert_hold = Vector3.ZERO
		if skater.state == Skater.GRIND or hv.length() > 1.2:
			desired_dir = hv.normalized() if hv.length() > 0.2 else _yaw_dir
		elif skater.state == Skater.GROUND:
			var h := skater.heading
			h.y = 0
			if h.length() > 0.2:
				desired_dir = h.normalized()
	if not _init:
		_yaw_dir = desired_dir if desired_dir.length() > 0.1 else Vector3.FORWARD
		_pos = sp - _yaw_dir * distance + Vector3.UP * height
		_look = sp + Vector3.UP * look_height
		_last_good = _pos
		_init = true
	var rate := yaw_rate * (0.6 if skater.state == Skater.AIR else 1.0)
	if skater.state == Skater.BAIL and skater.getup_t < 0.0:
		# the slam, then a rattle while the body slides
		if skater.bail_t < delta * 1.5:
			shake = maxf(shake, 0.35)
		elif skater.impact_t >= 0.0 and skater.bail_t - skater.impact_t < delta * 1.5:
			shake = maxf(shake, 0.85)
		elif skater.bail_grounded:
			shake = maxf(shake, clampf(skater.vel.length() * 0.05, 0.0, 0.35))
	if skater.state == Skater.BAIL:
		rate = 0.5
	# never swing round into a wall: when the skater turns away from a wall he is up
	# against (a wall bounce, dropping off the end of a rafter into a corner), the spot
	# behind him in the new direction is inside that wall. Keep the room-side view until
	# there is space behind him, then turn round through the more open side.
	var head_p := sp + Vector3.UP * 1.3
	var turn := absf(Vector2(_yaw_dir.x, _yaw_dir.z).angle_to(Vector2(desired_dir.x, desired_dir.z)))
	if turn > deg_to_rad(60.0) and skater.state != Skater.BAIL and not (skater.state == Skater.AIR and skater.vert_air):
		# (the whole arm to the new spot: a low box or rail behind him is no reason to wait)
		var behind := sp - desired_dir * distance + Vector3.UP * height
		if _cast(head_p, behind).distance_to(head_p) < head_p.distance_to(behind) * 0.45:
			desired_dir = _yaw_dir
			turn = 0.0
	if turn < deg_to_rad(90.0):
		_turn_pref = 0.0
	elif _turn_pref == 0.0:
		# latched for the whole turn: the side the camera passes at its halfway point
		var a := Vector2(_yaw_dir.x, _yaw_dir.z)
		var mp := -a.rotated(PI * 0.5)
		var mm := -a.rotated(-PI * 0.5)
		_turn_pref = 1.0 if _free_along(head_p, Vector3(mp.x, 0, mp.y), 3.0) >= _free_along(head_p, Vector3(mm.x, 0, mm.y), 3.0) else -1.0
	# (at most 240 deg/s: turning round on the spot or after a revert swings, never whips)
	_yaw_dir = _slerp_flat(_yaw_dir, desired_dir, clampf(delta * rate, 0.0, 1.0), _turn_pref, deg_to_rad(240.0) * delta)
	var speed_k := clampf(hv.length() / 14.0, 0.0, 1.0)
	var dist := distance + speed_k * 1.2
	var lift := height + speed_k * 0.3
	if skater.state == Skater.AIR and skater.vert_air:
		dist += 1.2
		lift += 0.6
	# grinds: ease off the rail line towards the open hall (a THPS 3/4 grind view) so the
	# camera never trails through the hanger rods above rafters or along a wall
	var want_side := 0.0
	if skater.state == Skater.GRIND:
		want_side = 1.6 if (skater.grind_rail and skater.grind_rail.tag == Tricks.RAFTER_TAG) else 0.7
		if skater.grind_rail and skater.grind_rail.tag == Tricks.RAFTER_TAG:
			lift += 0.6
	_side_amt = lerpf(_side_amt, want_side, clampf(delta * 2.5, 0.0, 1.0))
	var side := Vector3(-_yaw_dir.z, 0.0, _yaw_dir.x)
	if side.dot(HALL_CENTRE - sp) < 0.0:
		side = -side
	var target := sp - _yaw_dir * dist + Vector3.UP * lift + side * _side_amt
	var look_at_p := sp + Vector3.UP * look_height + Vector3(vel.x, vel.y * 0.25, vel.z) * 0.12
	# follow smoothly; vertically a bit softer so ollies don't jerk the view
	var k := clampf(delta * follow_rate, 0.0, 1.0)
	_pos = Vector3(lerpf(_pos.x, target.x, k), lerpf(_pos.y, target.y, k * 0.7), lerpf(_pos.z, target.z, k))
	_look = _look.lerp(look_at_p, clampf(delta * 10.0, 0.0, 1.0))
	# spring arm: never end up inside geometry. When the arm is blocked (a grind along a
	# wall, a corner), swing it round towards open space and up instead of collapsing
	# onto the skater; the swing is smoothed so the view never pops.
	# on a grind the skater's head is on the line of whatever the rail runs along (wall
	# pilasters and window frames beside the wall pipe, hanger rods standing on a rafter):
	# pivot the arm from a point out towards the open hall, so the obstacles the skater
	# has just passed do not cut across the start of the arm (that collapsed it, and the
	# anti-collapse cut then popped the view once per pilaster or rod)
	# (it takes effect at once: with the arm clear that moves nothing on screen; after the
	# grind it eases back to the head)
	if skater.state == Skater.GRIND:
		_pivot = side * _free_along(sp + Vector3.UP * 1.3, side, minf(want_side, 0.75))
	elif _pivot != Vector3.ZERO:
		var pl := _pivot.length() * maxf(0.0, 1.0 - delta * 5.0)
		_pivot = _pivot.normalized() * _free_along(sp + Vector3.UP * 1.3, _pivot.normalized(), pl) if pl > 0.02 else Vector3.ZERO
	var head := _origin(sp, _pos, _pivot)
	if head == Vector3.INF:
		# the skater is pressed into a wall or ramp: hold the last good view for a moment
		global_position = _last_good
		if global_position.distance_to(_look) > 0.05:
			look_at(_look, Vector3.UP)
		return
	var off := _pos - head
	var want := off.length()
	var best_ang := 0.0
	var best_lift := 0.0
	var best_d := _cast(head, _pos).distance_to(head)
	var first_hit := _dbg_hit
	if best_d < want * 0.8:
		for ang: float in SWING_ANGLES:
			for up: float in [0.0, 1.1, 2.2]:
				var o: Vector3 = off.rotated(Vector3.UP, deg_to_rad(ang)) + Vector3.UP * up
				var d := _cast(head, head + o).distance_to(head) - absf(ang) * 0.006 - up * 0.3
				if d > best_d + 0.25:
					best_d = d
					best_ang = ang
					best_lift = up
	# (quicker while a thin beam or rod is in the way, see below)
	var sk := clampf(delta * (9.0 if _thin else 3.5), 0.0, 1.0)
	if _fresh:
		sk = 1.0
		_fresh = false
	_swing = lerpf(_swing, best_ang, sk)
	_swing_lift = lerpf(_swing_lift, best_lift, sk)
	var arm := off.rotated(Vector3.UP, deg_to_rad(_swing)) + Vector3.UP * _swing_lift
	var final := _cast(head, head + arm)
	# a thin beam or rod crossing the arm (the skater dropping past the end of a rafter)
	# hides only part of him: pulling the camera in front of it would jump the view in and,
	# a moment later, back out. Stay put while the swing takes the camera round it.
	_thin = final.distance_to(head + arm) > 0.3 and _thin_block(head, head + arm, sp)
	if _thin:
		final = head + arm
	var cut := false
	if final.distance_to(head) < MIN_ARM and best_d > final.distance_to(head) + 0.3:
		cut = true
		# about to collapse onto the skater: cut straight to the free angle instead
		_swing = best_ang
		_swing_lift = best_lift
		arm = off.rotated(Vector3.UP, deg_to_rad(_swing)) + Vector3.UP * _swing_lift
		final = _cast(head, head + arm)
	# ease the arm's length: the 0.3 m sphere meeting a crate corner or a window frame
	# used to jump the camera in (and later out) in one frame. It now slides in at up to
	# 12 m/s and back out at 6 m/s, never past a hard 8 cm clearance cast.
	var arm_dir := (final - head).normalized() if final.distance_to(head) > 0.01 else arm.normalized()
	var soft_len := final.distance_to(head)
	# (while nothing is in the way the camera just follows its smoothed spot; the easing
	# is only for coming back out after being pushed in)
	if _arm_len < 0.0 or cut:
		_arm_len = soft_len
	elif soft_len < _arm_len:
		var hard_len := _cast_hard(head, head + arm_dir * _arm_len).distance_to(head)
		_arm_len = minf(maxf(soft_len, _arm_len - 12.0 * delta), hard_len)
	elif _arm_free:
		_arm_len = soft_len
	else:
		_arm_len = minf(soft_len, _arm_len + 6.0 * delta)
	_arm_free = _arm_len >= arm.length() - 0.05
	final = head + arm_dir * _arm_len
	final = _clear_rods(final, sp + skater.up * 1.0)
	_last_good = final
	dbg = {"origin": snappedf((head - sp).y, 0.01), "origin_back": snappedf(Vector2(head.x - sp.x, head.z - sp.z).length(), 0.01),
			"want": snappedf(want, 0.01), "free": snappedf(best_d, 0.01), "blocked_by": first_hit, "best_ang": best_ang,
			"best_lift": best_lift, "swing": snappedf(_swing, 0.1), "arm": snappedf(final.distance_to(head), 0.01), "cut": cut,
			"side": snappedf(_side_amt, 0.01), "pivot": snappedf(_pivot.length(), 0.01), "turn_pref": _turn_pref, "thin": _thin, "arm_len": snappedf(_arm_len, 0.01)}
	# failsafe: never look out through the skater's own clothes
	if skater.model:
		skater.model.visible = final.distance_to(head) > 0.75
	if shake > 0.0:
		shake = maxf(0.0, shake - delta * 2.5)
		final += Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * shake * 0.12
	global_position = final
	if global_position.distance_to(_look) > 0.05:
		look_at(_look, Vector3.UP)


func _free_along(from: Vector3, dir: Vector3, want: float) -> float:
	## How far (up to `want`) a point can move from `from` along `dir` and keep the arm's
	## 0.3 m sphere clear of what is there.
	if want <= 0.0:
		return 0.0
	var ray := PhysicsRayQueryParameters3D.create(from, from + dir * (want + 0.35), 1 | Level.CAMERA_BLOCK_LAYER)
	var r := get_world_3d().direct_space_state.intersect_ray(ray)
	if r.is_empty():
		return want
	return clampf(from.distance_to(r["position"]) - 0.35, 0.0, want)


func _origin(sp: Vector3, cam: Vector3, pivot := Vector3.ZERO) -> Vector3:
	## Where the spring arm starts: the skater's head (moved by `pivot`), or, if that is
	## inside geometry (up against a wall on a vert air, a pipe grind hugging the wall), a
	## nearby free point.
	var space := get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	_shape.radius = 0.07
	q.shape = _shape
	q.collision_mask = 1 | Level.CAMERA_BLOCK_LAYER
	var back := cam - sp
	back.y = 0.0
	back = back.normalized() if back.length() > 0.01 else Vector3.ZERO
	var body := sp + Vector3.UP * 0.8
	for o in [Vector3.UP * 1.3 + pivot, Vector3.UP * 1.3, Vector3.UP * 0.95, Vector3.UP * 1.3 + back * 0.45, Vector3.UP * 0.7 + back * 0.6, Vector3.UP * 1.8,
			Vector3.UP * 0.45, Vector3.UP * 0.45 + back * 0.8, Vector3.UP * 0.2 + back * 1.0]:
		q.transform = Transform3D(Basis.IDENTITY, sp + o)
		if not space.intersect_shape(q, 1).is_empty():
			continue
		# and on the skater's side of any ceiling or wall (a point just past a thin roof
		# is free space too, but the view from there is outside the room)
		var ray := PhysicsRayQueryParameters3D.create(body, sp + o, 1 | Level.CAMERA_BLOCK_LAYER)
		if space.intersect_ray(ray).is_empty():
			return sp + o
	return Vector3.INF


func _clear_rods(p: Vector3, target: Vector3) -> Vector3:
	## The thin hanger rods do not stop the arm, but a rod right in front of the lens would
	## fill the screen, or hide a standing skater top to bottom (both are vertical). For each
	## rod near the camera, shift the camera sideways just enough to keep the rod off the
	## line of sight to the skater (and 0.2 m clear of the lens). The side a rod passes on
	## is kept while it is near, so the shift grows and shrinks smoothly and never flips.
	var space := get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	_shape.radius = 2.0
	q.shape = _shape
	q.collision_mask = Level.CAMERA_ROD_LAYER
	q.transform = Transform3D(Basis.IDENTITY, p)
	var near := {}
	var out := p
	for hit in space.intersect_shape(q, 8):
		var rod := hit["collider"] as Node3D
		var c := Vector2(rod.global_position.x, rod.global_position.z)
		var cam2 := Vector2(out.x, out.z)
		var tgt2 := Vector2(target.x, target.z)
		var line := tgt2 - cam2
		var L := line.length()
		if L < 0.5:
			continue
		var dir := line / L
		var rel := c - cam2
		var along := rel.dot(dir)
		var lat := dir.orthogonal().dot(rel)
		var id := rod.get_instance_id()
		near[id] = true
		if not _rod_side.has(id):
			_rod_side[id] = -1.0 if lat >= 0.0 else 1.0       # the camera goes the other way
		var side: float = _rod_side[id]
		var shift := 0.0
		var d := rel.length()
		if along > 0.0 and along < L - 0.3:
			# keep the rod (3 cm) and a body's width off the sight line at the rod's distance;
			# from nothing at 2 m (a rod that far hides a sliver) to all of it within 1.2 m
			var need := (0.08 + 0.35 * along / L) * smoothstep(2.0, 1.2, d)
			var have := -lat * side                           # how far the rod already is on the far side
			if have < need:
				shift = (need - have) * L / (L - along)
		# and the lens 0.2 m clear of the rod itself
		if d < 0.2:
			shift = maxf(shift, 0.2 - d)
		if shift > 0.0:
			var o := dir.orthogonal() * side * minf(shift, 0.5)
			out += Vector3(o.x, 0.0, o.y)
	# the lens 0.2 m clear of every rod (a rod just behind the camera is not moved off
	# the sight line by the sideways shift)
	for hit in space.intersect_shape(q, 8):
		var c: Vector3 = (hit["collider"] as Node3D).global_position
		var rd := Vector2(out.x - c.x, out.z - c.z)
		if rd.length() < 0.2:
			var n := rd.normalized() if rd.length() > 0.001 else Vector2(1, 0)
			out += Vector3(n.x, 0.0, n.y) * (0.2 - rd.length())
	for id in _rod_side.keys():
		if not near.has(id):
			_rod_side.erase(id)
	if out != p:
		# never into a wall doing it
		var r := space.intersect_ray(PhysicsRayQueryParameters3D.create(p, out, 1 | Level.CAMERA_BLOCK_LAYER))
		if not r.is_empty():
			return p
	return out


func _thin_block(head: Vector3, end: Vector3, sp: Vector3) -> bool:
	## True when what blocks the arm is a thin beam, rod or pipe rather than a wall: the
	## camera's own spot is free, the obstacle is under 0.6 m thick along the arm, and most
	## of the skater's body is still in plain view from the camera.
	var space := get_world_3d().direct_space_state
	var mask := 1 | Level.CAMERA_BLOCK_LAYER
	var q := PhysicsShapeQueryParameters3D.new()
	_shape.radius = 0.2
	q.shape = _shape
	q.collision_mask = mask
	q.transform = Transform3D(Basis.IDENTITY, end)
	if not space.intersect_shape(q, 1).is_empty():
		return false
	var fwd := space.intersect_ray(PhysicsRayQueryParameters3D.create(head, end, mask))
	var back := space.intersect_ray(PhysicsRayQueryParameters3D.create(end, head, mask))
	if not fwd.is_empty() and not back.is_empty():
		var thick := head.distance_to(end) - head.distance_to(fwd["position"]) - end.distance_to(back["position"])
		if thick > 0.6:
			return false
	var up_s: Vector3 = skater.up
	var lat := up_s.cross(end - sp).normalized() * 0.3
	var clear := 0
	for p in [sp + up_s * 0.2, sp + up_s * 0.7, sp + up_s * 1.5, sp + up_s * 1.1 + lat, sp + up_s * 1.1 - lat]:
		if space.intersect_ray(PhysicsRayQueryParameters3D.create(end, p, mask)).is_empty():
			clear += 1
	return clear >= 3


func _cast_hard(from: Vector3, to: Vector3) -> Vector3:
	## The limit the eased arm may never pass: an 8 cm sphere (the near plane is 5 cm).
	var space := get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	_shape.radius = 0.08
	q.shape = _shape
	q.transform = Transform3D(Basis.IDENTITY, from)
	q.motion = to - from
	q.collision_mask = 1 | Level.CAMERA_BLOCK_LAYER
	if not space.intersect_shape(q, 1).is_empty():
		return from
	var t: float = space.cast_motion(q)[0]
	return to if t >= 1.0 else from + (to - from) * maxf(0.0, t - 0.01)


func _cast(from: Vector3, to: Vector3) -> Vector3:
	## Sphere-cast from the skater's head to `to`. Next to a wall the head sphere may
	## already overlap it (cast_motion then reports 0), so it shrinks until it starts free.
	var space := get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = _shape
	q.transform = Transform3D(Basis.IDENTITY, from)
	q.motion = to - from
	q.collision_mask = 1 | Level.CAMERA_BLOCK_LAYER
	for rad in [0.3, 0.16, 0.07]:
		_shape.radius = rad
		if space.intersect_shape(q, 1).is_empty():
			var r := space.cast_motion(q)
			var t: float = r[0]
			if t >= 1.0:
				_dbg_hit = ""
				return to
			if record_hits:
				q.transform = Transform3D(Basis.IDENTITY, from + (to - from) * r[1])
				q.motion = Vector3.ZERO
				var info := space.get_rest_info(q)
				_dbg_hit = str(instance_from_id(info["collider_id"]).name) if info.has("collider_id") else "?"
			return from + (to - from) * maxf(0.0, t - 0.02)
	return from


func _slerp_flat(a: Vector3, b: Vector3, t: float, pref := 0.0, max_step := INF) -> Vector3:
	## Turn a towards b in the ground plane; pref (+1 / -1) picks the way round for turns
	## over 120 deg (the camera then passes the more open side of the skater).
	var aa := Vector2(a.x, a.z)
	var bb := Vector2(b.x, b.z)
	if aa.length() < 0.01:
		return b
	if bb.length() < 0.01:
		return a
	var ang := aa.angle_to(bb)
	if pref != 0.0 and absf(ang) > deg_to_rad(120.0) and signf(ang) != pref:
		ang -= signf(ang) * TAU
	var r := aa.rotated(clampf(ang * t, -max_step, max_step)).normalized()
	return Vector3(r.x, 0, r.y)
