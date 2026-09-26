extends SkeletonModifier3D
## Runs after the ragdoll (PhysicalBoneSimulator3D) and keeps the drawn pose anatomical: under
## a hard slam the physics joints give a little, so elbows and knees are projected back onto
## their bend axis and clamped to their range (they bend one way only, never sideways), and
## shoulders and hips are held inside their swing cones. Only the pose that is drawn changes;
## the physics bodies are left to the solver. Set up by skater_model.gd from the same axes
## and limits as the ragdoll's joints; active only while the ragdoll is.

var specs: Array = []        # {bone, kind "hinge"|"cone", rest (local rotation), axis (parent space), lo, hi | limit}


func add_hinge(skel: Skeleton3D, bone: String, axis_skel: Vector3, lo_deg: float, hi_deg: float) -> void:
	var bi := skel.find_bone(bone)
	var par := skel.get_bone_parent(bi)
	if bi < 0 or par < 0:
		return
	var pbasis := skel.get_bone_global_rest(par).basis.orthonormalized()
	specs.append({"bone": bi, "kind": "hinge", "rest": skel.get_bone_rest(bi).basis.get_rotation_quaternion(),
			"axis": (pbasis.inverse() * axis_skel).normalized(), "lo": deg_to_rad(lo_deg), "hi": deg_to_rad(hi_deg)})


func add_cone(skel: Skeleton3D, bone: String, axis_skel: Vector3, limit_deg: float) -> void:
	var bi := skel.find_bone(bone)
	var par := skel.get_bone_parent(bi)
	if bi < 0 or par < 0:
		return
	var pbasis := skel.get_bone_global_rest(par).basis.orthonormalized()
	specs.append({"bone": bi, "kind": "cone", "axis": (pbasis.inverse() * axis_skel).normalized(), "limit": deg_to_rad(limit_deg)})


func _process_modification_with_delta(_delta: float) -> void:
	var skel := get_skeleton()
	if skel == null:
		return
	for sp in specs:
		var bi: int = sp["bone"]
		var r := skel.get_bone_pose_rotation(bi).normalized()
		if sp["kind"] == "hinge":
			# the turn relative to rest, in the parent's frame: keep only the part about the
			# bend axis, clamped to the range
			var d := (r * (sp["rest"] as Quaternion).inverse()).normalized()
			if d.w < 0.0:
				d = -d
			var f: Vector3 = sp["axis"]
			var ang := 2.0 * atan2(Vector3(d.x, d.y, d.z).dot(f), d.w)
			ang = clampf(ang, sp["lo"], sp["hi"])
			skel.set_bone_pose_rotation(bi, (Quaternion(f, ang) * (sp["rest"] as Quaternion)).normalized())
		else:
			# the bone's direction (its Y) must stay within `limit` of the cone axis
			var y := r * Vector3.UP
			var c: Vector3 = sp["axis"]
			var over := y.angle_to(c) - float(sp["limit"])
			if over > 0.0:
				var ax := y.cross(c)
				if ax.length() > 1e-5:
					skel.set_bone_pose_rotation(bi, (Quaternion(ax.normalized(), over) * r).normalized())
