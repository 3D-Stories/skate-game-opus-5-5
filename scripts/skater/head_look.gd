extends SkeletonModifier3D
## Turns the upper spine, neck and head from the regular look (over the front shoulder,
## towards the nose) to the fakie look (over the back shoulder, towards the tail) by
## `amount`, on top of whatever clip is playing: 0 = regular, 1 = fakie, and a little past
## either end (-0.6 .. 1.6) to look further over a shoulder in a spin. The turn is measured from the
## authored clips ('ride' vs 'ride_fakie'), so at amount 1 the upper body already matches
## ride_fakie and the hand-over to that clip does not pop. Driven by skater.gd: in a spin the
## head leads the body towards the stance it will land in.

var amount := 0.0
var deltas: Array = []       # [bone index, Quaternion: fakie look relative to regular, in the parent's frame]


func measure(anim: AnimationPlayer, skel: Skeleton3D) -> void:
	if not (anim.has_animation("ride") and anim.has_animation("ride_fakie")):
		return
	var bones := ["spine_01", "spine_02", "spine_03", "neck_01", "head"]
	var reg := {}
	anim.play("ride")
	anim.seek(0.0, true)
	for b in bones:
		reg[b] = skel.get_bone_pose_rotation(skel.find_bone(b))
	anim.play("ride_fakie")
	anim.seek(0.0, true)
	for b in bones:
		var bi := skel.find_bone(b)
		var q: Quaternion = (skel.get_bone_pose_rotation(bi) * (reg[b] as Quaternion).inverse()).normalized()
		if q.get_angle() > 0.01:
			deltas.append([bi, q])
	anim.stop()


func _process_modification_with_delta(_delta: float) -> void:
	var skel := get_skeleton()
	var a := clampf(amount, -0.6, 1.6)
	if absf(a) < 0.001:
		return
	for d in deltas:
		var bi: int = d[0]
		var dq: Quaternion = d[1]
		var q := Quaternion(dq.get_axis(), dq.get_angle() * a)
		skel.set_bone_pose_rotation(bi, (q * skel.get_bone_pose_rotation(bi)).normalized())
