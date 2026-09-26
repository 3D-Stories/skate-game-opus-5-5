extends SceneTree
## Ragdoll bails on the real main scene: a bail hands the skater's current pose to a
## PhysicalBone3D ragdoll (skater_model.gd), which tumbles along the skater's velocity, comes
## to rest on whatever it lands on, rolls onto its back if it ends face down, and hands over
## to the Blender 'getup' clip; then the skater rides on. Checked on the flat at three speeds,
## halfway up the east quarterpipe and from a vert air, frame by frame: every tracked bone
## stays above the surface under it, nothing goes NaN, the body really is simulated (the
## pelvis travels and turns), it settles and gets up within BAIL_MAX + GETUP_TIME, and the
## skater ends upright on the floor with the board back under the feet.
##   godot --headless --path . --fixed-fps 60 -s tests/test_ragdoll.gd
##   -> tests/results/ragdoll.txt   (add `-- verbose` for per-frame telemetry)

const FPS := 60.0
const LANE := Vector3(-11.0, 0.0, 13.0)
const BONES := ["pelvis", "spine_03", "head", "hand_l", "hand_r", "foot_l", "foot_r", "calf_l", "calf_r"]

var main: Node
var sk
var out: PackedStringArray = []
var passed := 0
var failed := 0
var used := {}              # getup clip -> times used
var verbose := false


func check(ok: bool, what: String, detail := "") -> void:
	if ok:
		passed += 1
	else:
		failed += 1
	out.append(("PASS  " if ok else "FAIL  ") + what + ("  (" + detail + ")" if detail != "" else ""))
	print(out[out.size() - 1])


func _initialize() -> void:
	verbose = "verbose" in OS.get_cmdline_user_args()
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func frames(n: int) -> void:
	for i in n:
		await process_frame


func key(k: Key, down: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = k
	e.physical_keycode = k
	e.pressed = down
	Input.parse_input_event(e)


func _run() -> void:
	await frames(5)
	sk = main.get("skater")
	if sk == null:
		print("RAGDOLL harness: the main scene did not load (script error above)")
		quit(1)
		return
	await frames(30)
	key(KEY_ENTER, true)
	await frames(2)
	key(KEY_ENTER, false)
	await frames(3)
	check(main.running, "harness: Enter starts the run")
	check(sk.model.rag.size() >= 14, "the skater has a ragdoll: capsules on the main bones",
			"%d physical bones: %s" % [sk.model.rag.size(), ", ".join(sk.model.rag.keys())])
	for sp in [2.0, 7.0, 11.0]:
		await _scenario("flat bail at %.0f m/s" % sp, LANE, Vector3(0, 0, -1), sp, 0.0)
	# thrown backwards (heels first): these tend to end face down, for the other getup
	sk.bail_tumble = -1.0
	for sp in [4.0, 8.0]:
		await _scenario("flat bail at %.0f m/s, thrown backwards" % sp, LANE, Vector3(0, 0, -1), sp, 0.0)
	sk.bail_tumble = 1.0
	for k in 3:
		await _scenario("bail halfway up the east quarterpipe (%d)" % (k + 1), Vector3(13.0, 0.0, -20.0), Vector3(1, 0, 0), 7.0, 1.2)
	await _scenario("bail out of a vert air (halfpipe)", Vector3(0.0, 0.0, -43.0), Vector3(-1, 0, 0), 11.5, -3.0)
	check(used.has("getup") and used.has("getup_front"),
			"both getups are used: from the back ('getup') and from face down ('getup_front')", "used: %s" % str(used))
	var f := FileAccess.open("res://tests/results/ragdoll.txt", FileAccess.WRITE)
	f.store_string("ragdoll bails: %d passed, %d failed\n\n%s\n" % [passed, failed, "\n".join(out)])
	f.close()
	print("RAGDOLL %d passed %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _scenario(label: String, pos: Vector3, fwd: Vector3, speed: float, trigger_y: float) -> void:
	## trigger_y > 0: bail once riding above that height; < 0: bail in the air once above
	## -trigger_y; 0: bail after 0.3 s of rolling.
	main.time_left = main.RUN_TIME
	sk.spawn(pos, fwd, speed)
	await frames(1)
	for i in 400:
		await frames(1)
		if trigger_y == 0.0 and i >= 18:
			break
		if trigger_y > 0.0 and sk.state == sk.GROUND and sk.global_position.y > trigger_y:
			break
		if trigger_y < 0.0 and sk.state == sk.AIR and sk.global_position.y > -trigger_y:
			break
	var v0: float = sk.vel.length()
	var y0: float = sk.global_position.y
	main.level.clear_blood()
	sk._bail("test: " + label)
	var skel: Skeleton3D = sk.model.skeleton
	var space: PhysicsDirectSpaceState3D = sk.get_world_3d().direct_space_state
	var p_start: Vector3 = sk.model.rag_pos("pelvis")
	var q_start: Basis = (sk.model.rag["pelvis"] as PhysicalBone3D).global_transform.basis
	# bone positions are sampled when the skeleton has applied its modifiers (the ragdoll):
	# read any other time, a bone pose is the animation's, not what is drawn
	_worst = 0.0
	_worst_at = "none"
	_t = 0.0
	_an = {"bend_lo": 0.0, "bend_hi": 0.0, "off": 0.0, "cone": 0.0, "inside": 0.0, "at": {}}
	skel.skeleton_updated.connect(_sample_bones.bind(skel, space))
	skel.skeleton_updated.connect(_anatomy_drawn)
	var nan := false
	var max_turn := 0.0
	var travel := 0.0
	var rest_at := -1.0
	var getup_at := -1.0
	var ground_at := -1.0
	var t := 0.0
	var getup_face := 0.0
	var gclip := ""
	var max_frames := int((sk.BAIL_MAX + sk.GETUP_TIME + 1.5) * FPS)
	for i in max_frames:
		await frames(1)
		t += 1.0 / FPS
		_t = t
		var pp: Vector3 = sk.model.rag_pos("pelvis")
		travel = maxf(travel, pp.distance_to(p_start))
		var qb: Basis = (sk.model.rag["pelvis"] as PhysicalBone3D).global_transform.basis
		max_turn = maxf(max_turn, rad_to_deg(q_start.get_rotation_quaternion().angle_to(qb.get_rotation_quaternion())))
		if not pp.is_finite():
			nan = true
			break
		if sk.model.ragdoll_on and sk.getup_t < 0.0 and sk.model.sim.influence > 0.99:
			_arms_in_torso()
		if verbose and getup_at < 0.0:
			for kb in sk.model.rag:
				var bb: PhysicalBone3D = sk.model.rag[kb]
				if bb.linear_velocity.length() > 12.0 or (bb.linear_velocity.length() > 5.0 and t > 1.0 and t < 1.3):
					print("    fast %s pos=%s v=%s w=%.1f" % [kb, str(bb.global_position.snapped(Vector3.ONE * 0.01)), str(bb.linear_velocity.snapped(Vector3.ONE * 0.1)), bb.angular_velocity.length()])
		if getup_at < 0.0 and sk.getup_t >= 0.0:
			getup_at = t
			getup_face = sk.model.rag_chest_up()
			used[sk.getup_clip] = int(used.get(sk.getup_clip, 0)) + 1
			gclip = sk.getup_clip
		if verbose and i % 6 == 0:
			print("  t=%.2f st=%d pelvis=%s rag_v=%.2f chest_up=%.2f getup_t=%.2f" % [t, sk.state,
					str(pp.snapped(Vector3.ONE * 0.01)), sk.model.rag_speed(), sk.model.rag_chest_up(), sk.getup_t])
		if sk.state == sk.GROUND:
			ground_at = t
			break
	skel.skeleton_updated.disconnect(_sample_bones)
	skel.skeleton_updated.disconnect(_anatomy_drawn)
	var worst := _worst
	var worst_at := _worst_at
	var splats: int = main.level._blood.size()
	var p_end: Vector3 = sk.global_position
	var g := space.intersect_ray(PhysicsRayQueryParameters3D.create(p_end + Vector3.UP * 0.5, p_end + Vector3.DOWN * 1.0, 1))
	var gap: float = absf(p_end.y - (g["position"] as Vector3).y) if not g.is_empty() else 99.0
	var head_y: float = (skel.global_transform * skel.get_bone_global_pose(skel.find_bone("head")).origin).y - p_end.y
	check(not nan and travel > 0.25 and max_turn > 25.0,
			label + ": the ragdoll takes over (the body is simulated, not keyframed)",
			"bail at %.2f m/s, y %.2f; pelvis travelled up to %.2f m and turned up to %.0f deg" % [v0, y0, travel, max_turn])
	check(worst < 0.07, label + ": no bone goes inside the floor or a ramp", "deepest: " + worst_at)
	check(_an["bend_lo"] > -2.0 and _an["bend_hi"] < 140.0 and _an["off"] < 2.0,
			label + ": elbows and knees bend one way only, within their range, never sideways",
			"bend %.0f..%.0f deg (allowed -2..140), off-axis up to %.1f deg (allowed 2) %s" % [_an["bend_lo"], _an["bend_hi"], _an["off"], str(_an["at"])])
	check(_an["cone"] < 6.0, label + ": shoulders, hips, spine and neck stay inside their swing limits",
			"worst overshoot %.1f deg" % _an["cone"])
	check(_an["inside"] < 0.035, label + ": no arm passes into the chest, belly or hips",
			"deepest arm point inside the torso: %.1f cm %s" % [_an["inside"] * 100.0, _an["at"].get("inside", "")])
	var need := 0 if v0 < 3.5 else (10 if v0 > 7.5 else 2)
	check(splats >= need, label + ": the bail leaves blood where the body hits and slides",
			"%d splats/smears at %.1f m/s bail speed (need >= %d); %s" % [splats, v0, need, str(sk.bail_stats)])
	check(getup_at > 0.0 and getup_at <= sk.BAIL_MAX + 0.05 and getup_face > 0.0,
			label + ": the body comes to rest and the getup that starts the way it lies begins",
			"'%s' at %.2f s, facing agreement %.2f (1 = lying exactly as the clip's first frame)" % [gclip, getup_at, getup_face])
	check(ground_at > 0.0 and gap < 0.08 and head_y > 1.3 and not sk.model.board_detached and not sk.model.ragdoll_on,
			label + ": the skater stands up on the floor with the board under the feet",
			"riding again at %.2f s at %s, %.3f m off the surface, head %.2f m above the feet, board attached=%s, ragdoll off=%s" % [
			ground_at, str(p_end.snapped(Vector3.ONE * 0.01)), gap, head_y, not sk.model.board_detached, not sk.model.ragdoll_on])


var _worst := 0.0
var _worst_at := ""
var _t := 0.0


func _sample_bones(skel: Skeleton3D, space: PhysicsDirectSpaceState3D) -> void:
	## How deep inside the park's solids the drawn pose puts each tracked bone.
	for bn in BONES:
		var bi := skel.find_bone(bn)
		var p: Vector3 = skel.global_transform * skel.get_bone_global_pose(bi).origin
		var d := depth_inside(space, p)
		if d["depth"] > _worst:
			_worst = d["depth"]
			_worst_at = "%s %.2f m inside %s at t=%.2f s" % [bn, d["depth"], d["what"], _t]
			if verbose and d["depth"] > 0.07:
				print("    INSIDE %s p=%s depth=%.2f in %s infl=%.2f getup_t=%.2f" % [bn, str(p.snapped(Vector3.ONE * 0.01)), d["depth"], d["what"],
						float(sk.model.sim.influence), sk.getup_t])


const DIRS := [Vector3.UP, Vector3.DOWN, Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]


static func depth_inside(space: PhysicsDirectSpaceState3D, p: Vector3, reach := 1.5) -> Dictionary:
	## A point is inside a solid when the nearest surface in every direction is seen from
	## behind (a ray from inside leaves through a back face). Depth = distance to the
	## nearest way out. Points in the open, or resting against a surface, give 0.
	# under a floor or ramp top (open meshes: seen from below through its back face)
	var qu := PhysicsRayQueryParameters3D.create(p, p + Vector3.UP * reach, 1)
	qu.hit_back_faces = true
	qu.hit_from_inside = true
	var ru := space.intersect_ray(qu)
	var under := 0.0
	var under_what := ""
	if not ru.is_empty():
		var nu: Vector3 = ru["normal"]
		if nu.y > 0.3:
			under = ((ru["position"] as Vector3) - p).dot(nu)
			under_what = "under " + str(ru["collider"].name)
	var exits := []
	for dir in DIRS:
		var q := PhysicsRayQueryParameters3D.create(p, p + dir * reach, 1)
		q.hit_back_faces = true
		q.hit_from_inside = true
		var r := space.intersect_ray(q)
		if r.is_empty():
			return {"depth": under, "what": under_what}          # open in this direction
		var n: Vector3 = r["normal"]
		if n.dot(dir) <= 0.0:
			return {"depth": under, "what": under_what}          # a front face first: outside
		exits.append([p.distance_to(r["position"]), r["collider"].name])
	exits.sort_custom(func(a, b): return a[0] < b[0])
	if under > exits[0][0]:
		return {"depth": under, "what": under_what}
	return {"depth": exits[0][0], "what": "inside " + str(exits[0][1])}


var _an := {}


func _anatomy_drawn() -> void:
	## The drawn pose (sampled after the skeleton's modifiers: ragdoll, then the clamp), while
	## the ragdoll alone drives it: elbows and knees as a bend about their axis (signed,
	## + = bending) plus any off-axis turn; shoulders and hips as the swing of the bone away
	## from its joint cone's axis, beyond the cone's limit.
	var m = sk.model
	if not (m.ragdoll_on and sk.getup_t < 0.0 and m.sim.influence > 0.99):
		return
	var skel: Skeleton3D = m.skeleton
	var hinge := {"lowerarm_l": "elbow_l", "lowerarm_r": "elbow_r", "calf_l": "knee_l", "calf_r": "knee_r"}
	for k in hinge:
		var bi := skel.find_bone(k)
		var pi := skel.get_bone_parent(bi)
		var rel := (skel.get_bone_global_pose(pi).basis.orthonormalized().inverse() * skel.get_bone_global_pose(bi).basis.orthonormalized())
		var rel0 := (skel.get_bone_global_rest(pi).basis.orthonormalized().inverse() * skel.get_bone_global_rest(bi).basis.orthonormalized())
		var q := (rel * rel0.inverse()).get_rotation_quaternion()
		if q.w < 0.0:
			q = -q
		var f: Vector3 = (skel.get_bone_global_rest(pi).basis.orthonormalized().inverse() * (m.flex_axes[hinge[k]] as Vector3)).normalized()
		var v := Vector3(q.x, q.y, q.z)
		var bend := rad_to_deg(2.0 * atan2(v.dot(f), q.w))
		var tw := Quaternion(f.x * v.dot(f), f.y * v.dot(f), f.z * v.dot(f), q.w).normalized()
		var off := rad_to_deg((q * tw.inverse()).normalized().get_angle())
		if bend < _an["bend_lo"]:
			_an["bend_lo"] = bend
			_an["at"]["lo"] = "%s %.0f at %.2fs" % [k, bend, _t]
		if bend > _an["bend_hi"]:
			_an["bend_hi"] = bend
			_an["at"]["hi"] = "%s %.0f at %.2fs" % [k, bend, _t]
		if off > _an["off"]:
			_an["off"] = off
			_an["at"]["off"] = "%s %.1f at %.2fs" % [k, off, _t]
	for k in ["upperarm_l", "upperarm_r", "thigh_l", "thigh_r"]:
		var bi := skel.find_bone(k)
		var pi := skel.get_bone_parent(bi)
		var y := skel.get_bone_global_pose(bi).basis.orthonormalized().y.normalized()
		var c: Vector3 = skel.get_bone_global_pose(pi).basis.orthonormalized() * (skel.get_bone_global_rest(pi).basis.orthonormalized().inverse() * (m.cone_axes[k] as Vector3))
		var lim: float = m._spec(k)["cone"][0]
		_an["cone"] = maxf(_an["cone"], rad_to_deg(y.angle_to(c.normalized())) - lim)


func _arms_in_torso() -> void:
	## Arm points (the physics capsules) inside the torso boxes, shrunk by the arm's radius.
	var m = sk.model
	for arm in ["upperarm_l", "upperarm_r", "lowerarm_l", "lowerarm_r"]:
		var ab: PhysicalBone3D = m.rag[arm]
		var cap := (ab.get_child(0) as CollisionShape3D).shape as CapsuleShape3D
		for s in 5:
			var p := ab.global_transform * Vector3(0.0, (float(s) / 4.0 - 0.5) * (cap.height - 2.0 * cap.radius), 0.0)
			for tb in ["pelvis", "spine_02", "spine_03"]:
				var bb: PhysicalBone3D = m.rag[tb]
				var box := (bb.get_child(0) as CollisionShape3D).shape as BoxShape3D
				var lp := bb.global_transform.affine_inverse() * p
				var h := box.size * 0.5 + Vector3.ONE * cap.radius
				var dx := h.x - absf(lp.x)
				var dy := h.y - absf(lp.y)
				var dz := h.z - absf(lp.z)
				if dx > 0.0 and dy > 0.0 and dz > 0.0 and minf(dx, minf(dy, dz)) > _an["inside"]:
					_an["inside"] = minf(dx, minf(dy, dz))
					_an["at"]["inside"] = "%s in %s" % [arm, tb]
