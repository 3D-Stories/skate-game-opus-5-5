class_name Replay
extends Node
## Instant replay of the run's last seconds, shown from the end-of-run screen (V / X).
## While a run is on, every rendered frame stores the skater's final pose (after the
## animation, the head turn and the ragdoll: read in Skeleton3D.skeleton_updated), the
## board and the camera. Playback builds a second skater from the character-builder
## choice that skated the run (SkaterOutfit), drives its skeleton with those poses and the
## camera along the recorded view, with the live skater hidden; the paused park stays as
## the run left it.

signal finished

const SECONDS := 15.0
const MAX_FRAMES := 1200              # the ring buffer's size (15 s at 80 fps)

var main: Node
var frames: Array = []                # ring buffer of [game time, bone poses, skeleton xf, board xf, cam xf, fov, model visible, wheel angle]
var head := 0
var count := 0
var _clock := 0.0                     # game time of the run (process time while it is on)
var choice: Dictionary = {}
var playing := false
var ghost: SkaterModel
var _skel: Skeleton3D
var _t := 0.0
var _grace := 0.0                     # (the press that started the replay must not also end it)
var _i0 := 0
var _cam_saved: Transform3D
var _fov_saved := 68.0
var _label: CanvasLayer


static func ensure_actions() -> void:
	## V / gamepad X on the end screen (added at run time: no project.godot change).
	if InputMap.has_action("replay"):
		return
	InputMap.add_action("replay", 0.5)
	var k := InputEventKey.new()
	k.keycode = KEY_V
	InputMap.action_add_event("replay", k)
	var j := InputEventJoypadButton.new()
	j.button_index = JOY_BUTTON_X
	InputMap.action_add_event("replay", j)


func setup(m: Node) -> void:
	main = m
	ensure_actions()
	process_mode = Node.PROCESS_MODE_ALWAYS
	frames.resize(MAX_FRAMES)


func clear() -> void:
	head = 0
	count = 0


func available() -> bool:
	return count > 10


func _process(delta: float) -> void:
	if playing:
		_advance(delta)
		return
	if main.running and not main.get_tree().paused:
		_clock += delta
	var model: SkaterModel = main.skater.model
	if model.skeleton != _skel:
		# a new skeleton (the Skater screen rebuilt the skater): listen to its final pose
		if _skel and is_instance_valid(_skel) and _skel.skeleton_updated.is_connected(_record):
			_skel.skeleton_updated.disconnect(_record)
		_skel = model.skeleton
		_skel.skeleton_updated.connect(_record)


func _record() -> void:
	if playing or not main.running or main.get_tree().paused:
		return
	var model: SkaterModel = main.skater.model
	var sk := model.skeleton
	if count == 0:
		choice = model.choice.duplicate()
	var n := sk.get_bone_count()
	var p := PackedFloat32Array()
	p.resize(n * 7)
	for b in n:
		var xf := sk.get_bone_pose(b)
		var q := xf.basis.get_rotation_quaternion()
		p[b * 7] = xf.origin.x
		p[b * 7 + 1] = xf.origin.y
		p[b * 7 + 2] = xf.origin.z
		p[b * 7 + 3] = q.x
		p[b * 7 + 4] = q.y
		p[b * 7 + 5] = q.z
		p[b * 7 + 6] = q.w
	var cam: Camera3D = main.cam
	frames[head] = [_clock, p, sk.global_transform, model.board.global_transform,
			cam.global_transform, cam.fov, model.visible, model.wheel_angle()]
	head = (head + 1) % MAX_FRAMES
	count = mini(count + 1, MAX_FRAMES)


func _frame(k: int) -> Array:
	## k-th stored frame, oldest first.
	return frames[(head - count + k + MAX_FRAMES) % MAX_FRAMES]


func play() -> void:
	## From the end screen: the last SECONDS of the run, once, then back.
	if playing or not available():
		return
	var last: float = _frame(count - 1)[0]
	_i0 = 0
	while _i0 < count - 1 and last - float(_frame(_i0)[0]) > SECONDS:
		_i0 += 1
	playing = true
	_grace = 0.3
	print("[replay] %d frames of %s" % [count - _i0, SkaterOutfit.to_arg(choice)])
	_t = float(_frame(_i0)[0])
	ghost = SkaterModel.new()
	ghost.name = "ReplaySkater"
	ghost.outfit = choice
	ghost.process_mode = Node.PROCESS_MODE_ALWAYS
	main.add_child(ghost)
	ghost.anim.stop()
	ghost.anim.active = false
	ghost.head_look.active = false
	ghost.board.top_level = true
	main.skater.model.visible = false
	var cam: Camera3D = main.cam
	_cam_saved = cam.global_transform
	_fov_saved = cam.fov
	_show_label(true)
	_apply(_i0)


func stop() -> void:
	if not playing:
		return
	playing = false
	if ghost:
		ghost.queue_free()
		ghost = null
	main.skater.model.visible = true
	var cam: Camera3D = main.cam
	cam.global_transform = _cam_saved
	cam.fov = _fov_saved
	_show_label(false)
	finished.emit()


func _advance(delta: float) -> void:
	_t += delta
	var k := _i0
	while k < count - 1 and float(_frame(k + 1)[0]) <= _t:
		k += 1
	_apply(k)
	_grace -= delta
	var skip := _grace <= 0.0 and (Input.is_action_just_pressed("confirm") or Input.is_action_just_pressed("ui_cancel")
			or Input.is_action_just_pressed("replay"))
	if k >= count - 1 or skip:
		stop()


func _apply(k: int) -> void:
	var f: Array = _frame(k)
	var p: PackedFloat32Array = f[1]
	var sk := ghost.skeleton
	for b in mini(sk.get_bone_count(), p.size() / 7):
		sk.set_bone_pose_position(b, Vector3(p[b * 7], p[b * 7 + 1], p[b * 7 + 2]))
		sk.set_bone_pose_rotation(b, Quaternion(p[b * 7 + 3], p[b * 7 + 4], p[b * 7 + 5], p[b * 7 + 6]))
	sk.global_transform = f[2]
	ghost.board.global_transform = f[3]
	var cam: Camera3D = main.cam
	cam.global_transform = f[4]
	cam.fov = f[5]
	ghost.visible = f[6]
	ghost.set_wheel_angle(f[7])


func _show_label(on: bool) -> void:
	if not on:
		if _label:
			_label.queue_free()
			_label = null
		return
	_label = CanvasLayer.new()
	_label.layer = 12
	add_child(_label)
	var l := Label.new()
	l.text = "REPLAY"
	l.add_theme_font_size_override("font_size", 56)
	l.add_theme_color_override("font_color", Color(1, 0.82, 0.12))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	l.add_theme_constant_override("outline_size", 12)
	l.position = Vector2(60, 40)
	_label.add_child(l)
	var h := Label.new()
	h.text = "ENTER / A  BACK"
	h.add_theme_font_size_override("font_size", 30)
	h.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	h.add_theme_constant_override("outline_size", 8)
	h.position = Vector2(64, 110)
	_label.add_child(h)
