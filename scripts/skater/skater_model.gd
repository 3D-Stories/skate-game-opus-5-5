class_name SkaterModel
extends Node3D
## The visual skater: the Blender-built character (skater.glb) with its animation clips, and
## the separate board (board.glb) riding on the skeleton's "board" bone. Swaps the imported
## materials for the game shaders (skin, hair) and exposes a small play/blend API.

const SKATER_SCENE := preload("res://assets/skater.glb")
const BOARD_SCENE := preload("res://assets/board.glb")
const SKIN_SHADER := preload("res://shaders/skin.gdshader")
const HAIR_SHADER := preload("res://shaders/hair.gdshader")

const LOOPING := ["idle", "ride", "crouch", "push", "air", "grind_5050", "boardslide",
		"manual", "nose_manual", "vert_air"]

var character: Node3D
var skeleton: Skeleton3D
var anim: AnimationPlayer
var board: Node3D
var board_attach: BoneAttachment3D
var wheels: Array[Node3D] = []
var _wheel_rest: Array[Basis] = []
var _wheel_angle := 0.0
var current := ""
var board_detached := false
var _board_offset := Transform3D.IDENTITY


func _ready() -> void:
	character = SKATER_SCENE.instantiate()
	add_child(character)
	skeleton = _find(character, "Skeleton3D") as Skeleton3D
	anim = _find(character, "AnimationPlayer") as AnimationPlayer
	for a_name in anim.get_animation_list():
		var a := anim.get_animation(a_name)
		a.loop_mode = Animation.LOOP_LINEAR if a_name in LOOPING else Animation.LOOP_NONE
	_setup_materials(character)
	board = BOARD_SCENE.instantiate()
	board_attach = BoneAttachment3D.new()
	board_attach.name = "BoardAttach"
	skeleton.add_child(board_attach)
	board_attach.bone_name = "board"
	var idx := skeleton.find_bone("board")
	var rest := skeleton.get_bone_global_rest(idx)
	# at rest the board sits unrotated at the bone head: keep that relation while animating
	_board_offset = rest.affine_inverse() * Transform3D(Basis.IDENTITY, rest.origin)
	board_attach.add_child(board)
	board.transform = _board_offset
	for n in ["Wheel_FL", "Wheel_FR", "Wheel_BL", "Wheel_BR"]:
		var w := board.find_child(n, true, false) as Node3D
		if w:
			wheels.append(w)
			_wheel_rest.append(w.basis)
	for m in _all_meshes(board):
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	# the head look runs first (right after the animation), the ragdoll and its clamp after it
	head_look = preload("res://scripts/skater/head_look.gd").new()
	head_look.name = "HeadLook"
	skeleton.add_child(head_look)
	head_look.measure(anim, skeleton)
	skeleton.reset_bone_poses()
	_build_ragdoll()
	_build_clamp()
	_measure_lying_pose()
	play("idle", 0.0)


# ------------------------------------------------------------------ ragdoll (bails)

const RAG_LAYER := 16                 # physics layer 5: ragdoll bodies (the park and each other)
## One body per main bone: bone, the bone its shape reaches to ("" = along the bone for
## `leaf`), shape ("box" w x d, or "cap" radius), mass, joint to its simulated parent.
## Joints are anatomical and built once from the rest pose (so their limits mean the same
## thing whatever pose the bail starts from): elbows and knees are hinges about the bend
## axis measured from the authored clips, bending one way only; shoulders, hips, spine and
## neck are cones with twist limits (the hip cone tilted forward, legs swing forward far
## more than back).
const RAG := [
	{"bone": "pelvis", "to": "spine_01", "box": Vector2(0.33, 0.21), "len": 0.22, "mass": 11.0},
	{"bone": "spine_02", "to": "spine_03", "box": Vector2(0.3, 0.2), "mass": 9.0, "cone": [22.0, 12.0]},
	{"bone": "spine_03", "to": "neck_01", "box": Vector2(0.34, 0.21), "mass": 10.0, "cone": [22.0, 12.0]},
	{"bone": "head", "to": "", "cap": 0.1, "leaf": 0.24, "mass": 5.0, "cone": [38.0, 45.0]},
	# the upper arm's capsule starts clear of the shoulder, so it can collide with the chest
	{"bone": "upperarm_l", "to": "lowerarm_l", "cap": 0.05, "start": 0.07, "mass": 3.0, "cone": [85.0, 35.0], "hits_parent": true},
	{"bone": "upperarm_r", "to": "lowerarm_r", "cap": 0.05, "start": 0.07, "mass": 3.0, "cone": [85.0, 35.0], "hits_parent": true},
	{"bone": "lowerarm_l", "to": "hand_l", "cap": 0.042, "mass": 2.3, "hinge": [3.0, 132.0], "flex": "elbow_l"},
	{"bone": "lowerarm_r", "to": "hand_r", "cap": 0.042, "mass": 2.3, "hinge": [3.0, 132.0], "flex": "elbow_r"},
	{"bone": "thigh_l", "to": "calf_l", "cap": 0.075, "mass": 8.0, "cone": [62.0, 18.0], "tilt": "hip_l"},
	{"bone": "thigh_r", "to": "calf_r", "cap": 0.075, "mass": 8.0, "cone": [62.0, 18.0], "tilt": "hip_r"},
	{"bone": "calf_l", "to": "foot_l", "cap": 0.056, "mass": 4.0, "hinge": [3.0, 132.0], "flex": "knee_l"},
	{"bone": "calf_r", "to": "foot_r", "cap": 0.056, "mass": 4.0, "hinge": [3.0, 132.0], "flex": "knee_r"},
	{"bone": "foot_l", "to": "ball_l", "cap": 0.045, "mass": 1.2, "cone": [30.0, 6.0]},
	{"bone": "foot_r", "to": "ball_r", "cap": 0.045, "mass": 1.2, "cone": [30.0, 6.0]},
]
const HINGE_SIGN := 1.0              # hinge angle direction of the physics engine vs the bend axis
var sim: PhysicalBoneSimulator3D
var rag: Dictionary = {}             # bone name -> PhysicalBone3D
var rag_parent: Dictionary = {}      # bone name -> its simulated parent bone name
var flex_axes: Dictionary = {}       # "knee_l"... -> bend axis (skeleton space, rest), "hip_l"... -> thigh direction when bent
var cone_axes: Dictionary = {}       # bone -> its joint cone's axis (skeleton space, rest)
var clamp: SkeletonModifier3D        # keeps the drawn ragdoll pose anatomical (ragdoll_clamp.gd)
var head_look: SkeletonModifier3D    # turns the head/upper body between the regular and fakie looks (head_look.gd)
var ragdoll_on := false
var _rag_tween: Tween
var lie: Dictionary = {}              # getup clip -> its first pose: pelvis, body axis, chest facing (model space)


func _measure_flex_axes() -> void:
	## The bend axes of elbows and knees, straight from the authored animation: the rotation
	## of the lower bone relative to the upper one between the rest pose and a clip that
	## bends it (a positive turn about the axis = bending). And the thigh direction in the
	## crouch, which tilts the hip cone forward.
	var probe := {"knee": ["crouch", 0.5, "thigh", "calf"], "elbow": ["getup", 0.28, "upperarm", "lowerarm"]}
	for key in probe:
		var pr: Array = probe[key]
		if not anim.has_animation(pr[0]):
			continue
		anim.play(pr[0])
		anim.seek(anim.get_animation(pr[0]).length * float(pr[1]), true)
		for sd in ["l", "r"]:
			var up_i := skeleton.find_bone(pr[2] + "_" + sd)
			var lo_i := skeleton.find_bone(pr[3] + "_" + sd)
			var Rp := skeleton.get_bone_global_rest(up_i).basis.orthonormalized()
			var Rc := skeleton.get_bone_global_rest(lo_i).basis.orthonormalized()
			var Pp := skeleton.get_bone_global_pose(up_i).basis.orthonormalized()
			var Pc := skeleton.get_bone_global_pose(lo_i).basis.orthonormalized()
			var dq := ((Pp.inverse() * Pc) * (Rp.inverse() * Rc).inverse()).get_rotation_quaternion()
			if dq.w < 0.0:
				dq = -dq
			var ax := Vector3(dq.x, dq.y, dq.z)
			if ax.length() > 1e-4:
				flex_axes[key + "_" + sd] = (Rp * ax.normalized()).normalized()
			if key == "knee":
				var th_rest := (skeleton.get_bone_global_rest(lo_i).origin - skeleton.get_bone_global_rest(up_i).origin).normalized()
				var th_bent := (skeleton.get_bone_global_pose(lo_i).origin - skeleton.get_bone_global_pose(up_i).origin).normalized()
				flex_axes["hip_" + sd] = th_bent if th_bent.angle_to(th_rest) > 0.2 else th_rest
	anim.stop()
	skeleton.reset_bone_poses()


func _build_ragdoll() -> void:
	## Built once, in the rest pose; inactive until a bail. The simulator links each body to
	## its nearest simulated ancestor; bodies collide with the park and with each other
	## (except each joined pair), so an arm cannot pass through the chest.
	_measure_flex_axes()
	sim = PhysicalBoneSimulator3D.new()
	sim.name = "Ragdoll"
	skeleton.add_child(sim)
	for r in RAG:
		var bi := skeleton.find_bone(r["bone"])
		if bi < 0:
			continue
		var rest := skeleton.get_bone_global_rest(bi)
		var a := rest.origin
		var ci := skeleton.find_bone(r["to"]) if r["to"] != "" else -1
		var c := skeleton.get_bone_global_rest(ci).origin if ci >= 0 else a + rest.basis.y.normalized() * float(r.get("leaf", 0.1))
		var along := c - a
		var st := float(r.get("start", 0.0))
		var length := float(r.get("len", along.length())) - st
		var yb := along.normalized()
		var xb := yb.cross(Vector3.FORWARD if absf(yb.z) < 0.9 else Vector3.RIGHT).normalized()
		var body := Transform3D(Basis(xb, yb, xb.cross(yb)), a + yb * (st + length * 0.5))
		var pb := PhysicalBone3D.new()
		pb.name = "Rag_" + r["bone"]
		pb.set("bone_name", r["bone"])
		pb.body_offset = rest.affine_inverse() * body
		pb.mass = r["mass"]
		pb.friction = 0.9
		pb.bounce = 0.02
		pb.linear_damp = 0.1
		pb.angular_damp = 1.2 if r.has("box") else 3.0      # limbs: less rubbery flailing
		pb.collision_layer = RAG_LAYER
		pb.collision_mask = 1 | RAG_LAYER
		var jo := body.affine_inverse() * a                  # joint at the bone's head (body space)
		if r.has("cone"):
			var d := yb
			if r.has("tilt") and flex_axes.has(r["tilt"]):
				# centre the hip cone between hanging straight and the crouch (forward)
				var bent: Vector3 = flex_axes[r["tilt"]]
				d = yb.slerp(bent, clampf(deg_to_rad(40.0) / maxf(yb.angle_to(bent), 0.01), 0.0, 1.0)).normalized()
			pb.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
			pb.joint_offset = Transform3D(_frame_x(body.basis.inverse() * d), jo)   # X: the cone (twist) axis
			cone_axes[r["bone"]] = d
			pb.set("joint_constraints/swing_span", r["cone"][0])
			pb.set("joint_constraints/twist_span", r["cone"][1])
		elif r.has("hinge") and flex_axes.has(r["flex"]):
			var f: Vector3 = body.basis.inverse() * (flex_axes[r["flex"]] as Vector3)
			var z := f.normalized()
			var x := (Vector3.UP - z * z.dot(Vector3.UP)).normalized()      # the bone, square to the axis
			pb.joint_type = PhysicalBone3D.JOINT_TYPE_HINGE
			pb.joint_offset = Transform3D(Basis(x, z.cross(x), z), jo)       # Z: the hinge axis
			var lim: Array = r["hinge"]
			pb.set("joint_constraints/angular_limit_enabled", true)
			if HINGE_SIGN > 0.0:
				pb.set("joint_constraints/angular_limit_lower", -float(lim[1]))
				pb.set("joint_constraints/angular_limit_upper", -float(lim[0]))
			else:
				pb.set("joint_constraints/angular_limit_lower", float(lim[0]))
				pb.set("joint_constraints/angular_limit_upper", float(lim[1]))
		var cs := CollisionShape3D.new()
		if r.has("box"):
			var bx := BoxShape3D.new()
			bx.size = Vector3(r["box"].x, length, r["box"].y)
			cs.shape = bx
		else:
			var cap := CapsuleShape3D.new()
			cap.radius = r["cap"]
			cap.height = maxf(length + float(r["cap"]), float(r["cap"]) * 2.0 + 0.01)
			cs.shape = cap
		pb.add_child(cs)
		sim.add_child(pb)
		rag[r["bone"]] = pb
	# joined pairs overlap at the joint by design: they do not collide with each other
	for k in rag:
		var par := skeleton.get_bone_parent(skeleton.find_bone(k))
		while par >= 0 and not rag.has(skeleton.get_bone_name(par)):
			par = skeleton.get_bone_parent(par)
		if par >= 0:
			var pn := skeleton.get_bone_name(par)
			rag_parent[k] = pn
			if _spec(k).get("hits_parent", false):
				continue
			PhysicsServer3D.body_add_collision_exception((rag[k] as PhysicalBone3D).get_rid(), (rag[pn] as PhysicalBone3D).get_rid())
			PhysicsServer3D.body_add_collision_exception((rag[pn] as PhysicalBone3D).get_rid(), (rag[k] as PhysicalBone3D).get_rid())


func _build_clamp() -> void:
	## Same axes and limits as the joints (a few degrees of slack), applied to the drawn pose.
	clamp = preload("res://scripts/skater/ragdoll_clamp.gd").new()
	clamp.name = "RagdollClamp"
	skeleton.add_child(clamp)          # after the simulator: modifiers run in child order
	for r in RAG:
		if r.has("hinge") and flex_axes.has(r["flex"]):
			clamp.add_hinge(skeleton, r["bone"], flex_axes[r["flex"]], 0.0, float(r["hinge"][1]) + 4.0)
		elif r["bone"].begins_with("upperarm") or r["bone"].begins_with("thigh"):
			if cone_axes.has(r["bone"]):
				clamp.add_cone(skeleton, r["bone"], cone_axes[r["bone"]], float(r["cone"][0]) + 5.0)
	clamp.active = false


static func _spec(bone: String) -> Dictionary:
	for r in RAG:
		if r["bone"] == bone:
			return r
	return {}


static func _frame_x(x_axis: Vector3) -> Basis:
	var x := x_axis.normalized()
	var t := Vector3.UP if absf(x.y) < 0.9 else Vector3.RIGHT
	var z := x.cross(t).normalized()
	return Basis(x, z.cross(x), z)


func _measure_lying_pose() -> void:
	## Where each getup clip starts - pelvis, body axis (pelvis to head, flat) and which way
	## the chest faces - so a settled ragdoll can hand over to the matching one ('getup' from
	## the back, 'getup_front' from the front) from wherever and however the body came to rest.
	for clip in ["getup", "getup_front"]:
		if not anim.has_animation(clip):
			continue
		anim.play(clip)
		anim.seek(0.0, true)
		var P := skeleton.get_bone_global_pose(skeleton.find_bone("pelvis")).origin
		var H := skeleton.get_bone_global_pose(skeleton.find_bone("head")).origin
		var L := skeleton.get_bone_global_pose(skeleton.find_bone("upperarm_l")).origin
		var R := skeleton.get_bone_global_pose(skeleton.find_bone("upperarm_r")).origin
		var sx := global_transform.affine_inverse() * skeleton.global_transform
		var ax := sx.basis * (H - P)
		ax.y = 0.0
		lie[clip] = {"pelvis": sx * P, "axis": ax.normalized(), "face": (sx.basis * ((R - L).cross(H - P))).normalized()}
	anim.stop()


func rag_face() -> Vector3:
	## Which way the ragdoll's chest faces (world), by the same measure as the clips' poses.
	var L := rag_pos("upperarm_l")
	var R := rag_pos("upperarm_r")
	return (R - L).cross(rag_pos("head") - rag_pos("pelvis")).normalized()


func getup_for_rest() -> String:
	## The getup clip whose first pose lies the same way up as the ragdoll does now.
	if not lie.has("getup_front"):
		return "getup"
	var f := rag_face().y
	var back: float = (lie["getup"]["face"] as Vector3).y
	return "getup" if signf(f) == signf(back) else "getup_front"


func start_ragdoll(velocity: Vector3, spin: Vector3) -> void:
	## The current (animated) pose becomes the ragdoll (the joints keep their rest-pose
	## frames, so their limits stay anatomical), then every body takes the skater's velocity
	## plus a tumble.
	if ragdoll_on:
		return
	ragdoll_on = true
	# the authored 'bail' clip (the flinch, arms thrown out) shows first and hands over to
	# the physics within a quarter second
	if _rag_tween:
		_rag_tween.kill()
	sim.influence = 0.0
	_rag_tween = create_tween()
	_rag_tween.tween_property(sim, "influence", 1.0, 0.25).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	sim.physical_bones_start_simulation()
	_track = false
	for r in RAG:
		var pb: PhysicalBone3D = rag.get(r["bone"])
		if pb:
			# the heavy torso and head sweep (they must not tunnel into a ramp); limbs do not -
			# a swept limb is moved without its joints and can end up past their limits
			PhysicsServer3D.body_set_enable_continuous_collision_detection(pb.get_rid(), r.has("box") or r["bone"] == "head")
			# contacts are read back for the impacts (blood, thuds)
			PhysicsServer3D.body_set_max_contacts_reported(pb.get_rid(), 4)
			var arm: Vector3 = pb.global_position - (rag["pelvis"] as PhysicalBone3D).global_position
			pb.linear_velocity = velocity + spin.cross(arm)
			pb.angular_velocity = spin


func rag_pos(bone: String) -> Vector3:
	var pb: PhysicalBone3D = rag.get(bone)
	return pb.global_position if pb else global_position


func rag_speed() -> float:
	var m := 0.0
	for k in ["pelvis", "spine_03", "head"]:
		m = maxf(m, (rag[k] as PhysicalBone3D).linear_velocity.length())
	return m


func rag_chest_up() -> float:
	## +1: the body lies the same way up as the first pose of the getup it will use.
	var clip := getup_for_rest()
	return rag_face().y * signf((lie[clip]["face"] as Vector3).y) if lie.has(clip) else 0.0


# --- handing over to the getup clip: for HANDOVER_HOLD the physics bodies are steered to the
# clip's first pose (contacts stay live, so no limb is dragged through the floor), then the
# ragdoll's influence fades out while the clip plays on
const HANDOVER_HOLD := 0.3
const HANDOVER_FADE := 0.35
var _track := false


func begin_handover() -> void:
	_track = true
	anim.speed_scale = 0.0
	var tw := create_tween()
	tw.tween_interval(HANDOVER_HOLD)
	tw.tween_callback(func():
		anim.speed_scale = 1.0
		end_ragdoll(HANDOVER_FADE))


func _process(_delta: float) -> void:
	if clamp:
		clamp.active = ragdoll_on
		clamp.influence = sim.influence if ragdoll_on else 0.0


func _physics_process(_delta: float) -> void:
	if not _track or not ragdoll_on:
		_track = false
		return
	# targets: the animated pose (the skeleton's own pose outside its modifier pass)
	var sx := skeleton.global_transform
	for k in rag:
		var b: PhysicalBone3D = rag[k]
		var bi := skeleton.find_bone(k)
		var T: Transform3D = sx * skeleton.get_bone_global_pose(bi) * b.body_offset
		var v := ((T.origin - b.global_position) / 0.12).limit_length(3.0)
		var dq := (T.basis.get_rotation_quaternion() * b.global_transform.basis.get_rotation_quaternion().inverse()).normalized()
		if dq.w < 0.0:
			dq = -dq
		var ang := 2.0 * acos(clampf(dq.w, -1.0, 1.0))
		var w := Vector3.ZERO
		if ang > 0.001:
			w = (Vector3(dq.x, dq.y, dq.z).normalized() * ang / 0.12).limit_length(9.0)
		PhysicsServer3D.body_set_state(b.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, v)
		PhysicsServer3D.body_set_state(b.get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, w)


func end_ragdoll(dur: float) -> void:
	## Hand back to the animation: fade the ragdoll's influence out while the getup plays,
	## then stop simulating.
	if not ragdoll_on:
		return
	if _rag_tween:
		_rag_tween.kill()
	var tw := create_tween()
	_rag_tween = tw
	tw.tween_property(sim, "influence", 0.0, dur).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_callback(func():
		sim.physical_bones_stop_simulation()
		sim.influence = 1.0
		_track = false
		ragdoll_on = false)


func rag_clamp(max_speed: float) -> void:
	for pb in rag.values():
		var b := pb as PhysicalBone3D
		if b.linear_velocity.length() > max_speed:
			PhysicsServer3D.body_set_state(b.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, b.linear_velocity.limit_length(max_speed))


func stop_ragdoll_now() -> void:
	_track = false
	if _rag_tween:
		_rag_tween.kill()
		_rag_tween = null
	if ragdoll_on:
		sim.physical_bones_stop_simulation()
		sim.influence = 1.0
		ragdoll_on = false


var played: Dictionary = {}      # clip -> times started (for the run report)


func play(clip: String, blend := 0.12, speed := 1.0) -> void:
	if not anim.has_animation(clip):
		return
	if clip != current:
		played[clip] = int(played.get(clip, 0)) + 1
	if clip == current and anim.is_playing():
		anim.speed_scale = speed
		return
	current = clip
	anim.play(clip, blend)
	anim.speed_scale = speed


func restart(clip: String, blend := 0.08, speed := 1.0) -> void:
	current = ""
	anim.stop(true)
	play(clip, blend, speed)


func clip_length(clip: String) -> float:
	return anim.get_animation(clip).length if anim.has_animation(clip) else 0.0


func clip_progress() -> float:
	if current == "" or not anim.has_animation(current):
		return 1.0
	var l := anim.get_animation(current).length
	return clamp(anim.current_animation_position / max(0.001, l), 0.0, 1.0)


func spin_wheels(dist: float) -> void:
	_wheel_angle = fmod(_wheel_angle - dist / 0.0265, TAU)
	for i in wheels.size():
		wheels[i].basis = _wheel_rest[i] * Basis(Vector3.BACK, _wheel_angle)


## Throws the board off during a bail: it becomes a free rigid body in the level.
func detach_board(parent: Node3D, velocity: Vector3) -> RigidBody3D:
	if board_detached:
		return null
	board_detached = true
	var xf := board.global_transform
	var body := RigidBody3D.new()
	body.name = "LooseBoard"
	body.mass = 2.2
	body.collision_layer = 32          # layer 6: hits the park, not the ragdoll or the skater's probes
	body.collision_mask = 1
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.8, 0.1, 0.2)
	shape.shape = box
	body.add_child(shape)
	parent.add_child(body)
	body.global_transform = xf
	board.get_parent().remove_child(board)
	body.add_child(board)
	board.transform = Transform3D.IDENTITY
	body.linear_velocity = velocity
	body.angular_velocity = Vector3(randf_range(-9, 9), randf_range(-6, 6), randf_range(-9, 9))
	# the loose board clatters every time it hits the floor, a ramp or a wall
	body.contact_monitor = true
	body.max_contacts_reported = 4
	body.body_entered.connect(_on_board_hit.bind(body))
	_clatter_t = 0.0
	return body


func _on_board_hit(_other: Node, body: RigidBody3D) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var sp := body.linear_velocity.length() + body.angular_velocity.length() * 0.1
	if now - _clatter_t < 0.09 or sp < 0.4:
		return
	_clatter_t = now
	Sfx.play("clatter", body.global_position, linear_to_db(clampf(sp / 6.0, 0.15, 1.0)), randf_range(0.9, 1.12))


var _clatter_t := 0.0


func recall_board(dur: float) -> void:
	## Getting up after a bail: the loose board glides from where it came to rest back to
	## the board bone (the 'getup' clip pulls it in under the front foot), then follows it.
	if not board_detached:
		return
	var holder := board.get_parent()
	var xf := board.global_transform
	holder.remove_child(board)
	board_attach.add_child(board)
	board_detached = false
	board.global_transform = xf
	# glide in on an arc (up and over, never through the fallen body)
	var tw := create_tween()
	tw.tween_method(func(k: float):
		var e := k * k * (3.0 - 2.0 * k)
		var target := board_attach.global_transform * _board_offset
		var w := xf.interpolate_with(target, e)
		w.origin += Vector3.UP * 0.4 * sin(PI * e)
		board.global_transform = w, 0.0, 1.0, dur)
	tw.tween_callback(func(): board.transform = _board_offset)
	if holder is RigidBody3D:
		holder.queue_free()


func reattach_board() -> void:
	if not board_detached:
		return
	var holder := board.get_parent()
	holder.remove_child(board)
	board_attach.add_child(board)
	board.transform = _board_offset
	holder.queue_free()
	board_detached = false


func _setup_materials(root: Node) -> void:
	for mi in _all_meshes(root):
		var mesh := mi.mesh
		if mesh == null:
			continue
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		for s in mesh.get_surface_count():
			var m := mesh.surface_get_material(s) as StandardMaterial3D
			if m == null:
				continue
			var n := m.resource_name
			var nm: Material = null
			if n == "Skin":
				var sm := ShaderMaterial.new()
				sm.shader = SKIN_SHADER
				sm.set_shader_parameter("albedo_tex", m.albedo_texture)
				sm.set_shader_parameter("normal_tex", m.normal_texture)
				sm.set_shader_parameter("rough_tex", m.roughness_texture)
				nm = sm
			elif n == "Hair" or n.begins_with("Lashes") or n == "Eyebrows":
				var hm := ShaderMaterial.new()
				hm.shader = HAIR_SHADER
				hm.set_shader_parameter("albedo_tex", m.albedo_texture)
				hm.set_shader_parameter("alpha_cut", 0.3 if n == "Hair" else 0.25)
				nm = hm
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if n == "Hair" else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			elif n == "Cornea":
				var c := StandardMaterial3D.new()
				c.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				c.albedo_color = Color(1, 1, 1, 0.06)
				c.roughness = 0.02
				c.metallic_specular = 1.0
				nm = c
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			elif n == "Eye":
				m.roughness = 0.25
				m.clearcoat_enabled = true
				m.clearcoat = 1.0
				m.clearcoat_roughness = 0.05
			else:
				# fabrics: a touch of rim sheen reads as fleece/denim fibres
				if n in ["Hoodie", "Jeans"] or n.begins_with("Hood_"):
					m.rim_enabled = true
					m.rim = 0.25
					m.rim_tint = 0.6
			if nm:
				mesh.surface_set_material(s, nm)


func _all_meshes(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var stack: Array[Node] = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


func _find(root: Node, cls: String) -> Node:
	if root.get_class() == cls:
		return root
	for c in root.get_children():
		var r := _find(c, cls)
		if r:
			return r
	return null
