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
		_init = true
	var rate := yaw_rate * (0.6 if skater.state == Skater.AIR else 1.0)
	if skater.state == Skater.BAIL:
		rate = 0.5
	_yaw_dir = _slerp_flat(_yaw_dir, desired_dir, clampf(delta * rate, 0.0, 1.0))
	var speed_k := clampf(hv.length() / 14.0, 0.0, 1.0)
	var dist := distance + speed_k * 1.2
	var lift := height + speed_k * 0.3
	if skater.state == Skater.AIR and skater.vert_air:
		dist += 1.2
		lift += 0.6
	var target := sp - _yaw_dir * dist + Vector3.UP * lift
	var look_at_p := sp + Vector3.UP * look_height + Vector3(vel.x, vel.y * 0.25, vel.z) * 0.12
	# follow smoothly; vertically a bit softer so ollies don't jerk the view
	var k := clampf(delta * follow_rate, 0.0, 1.0)
	_pos = Vector3(lerpf(_pos.x, target.x, k), lerpf(_pos.y, target.y, k * 0.7), lerpf(_pos.z, target.z, k))
	_look = _look.lerp(look_at_p, clampf(delta * 10.0, 0.0, 1.0))
	# spring arm: never end up inside geometry
	var head := sp + Vector3.UP * 1.3
	var safe := _cast(head, _pos)
	var final := safe
	if shake > 0.0:
		shake = maxf(0.0, shake - delta * 2.5)
		final += Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * shake * 0.12
	global_position = final
	if global_position.distance_to(_look) > 0.05:
		look_at(_look, Vector3.UP)


func _cast(from: Vector3, to: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = _shape
	q.transform = Transform3D(Basis.IDENTITY, from)
	q.motion = to - from
	q.collision_mask = 1
	var r := space.cast_motion(q)
	var t: float = r[0]
	if t >= 1.0:
		return to
	return from + (to - from) * maxf(0.0, t - 0.02)


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
