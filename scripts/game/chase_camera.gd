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

const SWING_ANGLES := [0.0, 30.0, -30.0, 55.0, -55.0, 85.0, -85.0]
const HALL_CENTRE := Vector3(0.0, 3.0, -17.0)     # middle of the Warehouse floor (Godot axes)
const MIN_ARM := 1.5


func _ready() -> void:
	_shape.radius = 0.3
	fov = 68.0
	near = 0.05
	far = 400.0


func snap() -> void:
	_init = false


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
	_yaw_dir = _slerp_flat(_yaw_dir, desired_dir, clampf(delta * rate, 0.0, 1.0))
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
	var head := _origin(sp, _pos)
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
	if best_d < want * 0.8:
		for ang: float in SWING_ANGLES:
			for up: float in [0.0, 1.1, 2.2]:
				var o: Vector3 = off.rotated(Vector3.UP, deg_to_rad(ang)) + Vector3.UP * up
				var d := _cast(head, head + o).distance_to(head) - absf(ang) * 0.006 - up * 0.3
				if d > best_d + 0.25:
					best_d = d
					best_ang = ang
					best_lift = up
	var sk := clampf(delta * 3.5, 0.0, 1.0)
	_swing = lerpf(_swing, best_ang, sk)
	_swing_lift = lerpf(_swing_lift, best_lift, sk)
	var arm := off.rotated(Vector3.UP, deg_to_rad(_swing)) + Vector3.UP * _swing_lift
	var final := _cast(head, head + arm)
	if final.distance_to(head) < MIN_ARM and best_d > final.distance_to(head) + 0.3:
		# about to collapse onto the skater: cut straight to the free angle instead
		_swing = best_ang
		_swing_lift = best_lift
		arm = off.rotated(Vector3.UP, deg_to_rad(_swing)) + Vector3.UP * _swing_lift
		final = _cast(head, head + arm)
	_last_good = final
	# failsafe: never look out through the skater's own clothes
	if skater.model:
		skater.model.visible = final.distance_to(head) > 0.75
	if shake > 0.0:
		shake = maxf(0.0, shake - delta * 2.5)
		final += Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * shake * 0.12
	global_position = final
	if global_position.distance_to(_look) > 0.05:
		look_at(_look, Vector3.UP)


func _origin(sp: Vector3, cam: Vector3) -> Vector3:
	## Where the spring arm starts: the skater's head, or, if that is inside geometry (up
	## against a wall on a vert air, a pipe grind hugging the wall), a nearby free point.
	var space := get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	_shape.radius = 0.07
	q.shape = _shape
	q.collision_mask = 1 | Level.CAMERA_BLOCK_LAYER
	var back := cam - sp
	back.y = 0.0
	back = back.normalized() if back.length() > 0.01 else Vector3.ZERO
	var body := sp + Vector3.UP * 0.8
	for o in [Vector3.UP * 1.3, Vector3.UP * 0.95, Vector3.UP * 1.3 + back * 0.45, Vector3.UP * 0.7 + back * 0.6, Vector3.UP * 1.8,
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
				return to
			return from + (to - from) * maxf(0.0, t - 0.02)
	return from


func _slerp_flat(a: Vector3, b: Vector3, t: float) -> Vector3:
	var aa := Vector2(a.x, a.z)
	var bb := Vector2(b.x, b.z)
	if aa.length() < 0.01:
		return b
	if bb.length() < 0.01:
		return a
	var ang := aa.angle_to(bb)
	var r := aa.rotated(ang * t).normalized()
	return Vector3(r.x, 0, r.y)
