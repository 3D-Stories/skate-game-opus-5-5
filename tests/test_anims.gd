extends SceneTree
## Headless checks of the Blender-authored clips inside the game (skater.glb):
##  * every clip the game needs exists and is non-empty
##  * feet stay on the board: for each clip, sampled every frame, the ankle bones sit on
##    the deck in the board bone's frame (the clips place the ankle 7.25 cm above the
##    shoe sole, the sole on the deck top). Flip clips are checked at pop and catch, and
##    their mid-flip hover is reported. The push clip's pushing foot and the bail are
##    reported but not required to be on the deck.
##   godot --headless --path . -s tests/test_anims.gd   -> tests/results/animations.txt

const REQUIRED := ["idle", "push", "ride", "crouch", "ollie", "kickflip", "heelflip", "shoveit", "treflip",
		"indy", "melon", "nosegrab", "tailgrab", "grind_5050", "boardslide", "manual", "nose_manual",
		"vert_air", "air", "land", "bail", "special", "ride_fakie", "getup", "getup_front"]
const FLIPS := ["kickflip", "heelflip", "shoveit", "treflip", "special"]
const ANKLE_ON_DECK := 0.0815    # deck top (0.009) + ankle above the sole (0.0725)
const TOL := 0.02

var out: PackedStringArray = []
var failed := 0
var passed := 0


func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
		out.append("PASS  " + what)
	else:
		failed += 1
		out.append("FAIL  " + what)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var model: Node3D = load("res://scripts/skater/skater_model.gd").new()
	root.add_child(model)
	await process_frame
	var anim: AnimationPlayer = model.anim
	var sk: Skeleton3D = model.skeleton
	for c in REQUIRED:
		var ok: bool = anim.has_animation(c) and anim.get_animation(c).length > 0.1 and anim.get_animation(c).get_track_count() > 10
		check(ok, "clip '%s' exported (%.2fs, %d tracks)" % [c, anim.get_animation(c).length if anim.has_animation(c) else 0.0,
				anim.get_animation(c).get_track_count() if anim.has_animation(c) else 0])
	var bi := sk.find_bone("board")
	var feet := [sk.find_bone("foot_l"), sk.find_bone("foot_r")]
	var n_local: Vector3 = (sk.get_bone_global_rest(bi).basis.inverse() * Vector3.UP).normalized()
	# the board's long axis in the board bone's frame: from the back foot to the front foot
	# in the riding pose (for the "no foot inside the deck" check on getting up)
	anim.play("ride")
	anim.seek(0.0, true)
	var Br := sk.get_bone_global_pose(bi)
	var a_local: Vector3 = Br.affine_inverse() * sk.get_bone_global_pose(feet[0]).origin - Br.affine_inverse() * sk.get_bone_global_pose(feet[1]).origin
	a_local = (a_local - n_local * a_local.dot(n_local)).normalized()
	var w_local := n_local.cross(a_local).normalized()
	var table: PackedStringArray = []
	table.append("%-12s %8s %8s %8s %8s   %s" % ["clip", "L max", "R max", "L end", "R end", "note (ankle height error vs. deck, cm)"])
	for c in REQUIRED:
		if not anim.has_animation(c):
			continue
		anim.play(c)
		var length := anim.get_animation(c).length
		var frames := int(round(length * 30.0))
		var worst := [0.0, 0.0]
		var ends := [0.0, 0.0]
		var hover := 0.0
		var inside := 0.0           # getup: deepest an ankle gets inside the deck volume
		var floor_low := 9.0        # getups: lowest joint above the floor (the clip root is on it)
		var floor_at := ""
		for k in frames + 1:
			anim.seek(length * k / maxf(1.0, frames), true)
			var B := sk.get_bone_global_pose(bi)
			for f in 2:
				var rel := B.affine_inverse() * sk.get_bone_global_pose(feet[f]).origin
				var err := absf(rel.dot(n_local) - ANKLE_ON_DECK)
				var u := float(k) / maxf(1.0, frames)
				var contact_phase := true
				if c in FLIPS:
					contact_phase = u < 0.06 or u > 0.9
					if not contact_phase:
						hover = maxf(hover, rel.dot(n_local) - ANKLE_ON_DECK)
				elif c.begins_with("getup"):
					# up from the floor: both feet are on the deck from the step-on to the end
					# (getup: the 0.86 key, getup_front: the 0.94 key)
					contact_phase = u >= (0.9 if c == "getup" else 0.94)
					# and never inside the board on the way (ankle over the deck but below it)
					var hgt := rel.dot(n_local)
					if absf(rel.dot(a_local)) < 0.40 and absf(rel.dot(w_local)) < 0.10 and hgt < ANKLE_ON_DECK - 0.02:
						inside = maxf(inside, ANKLE_ON_DECK - hgt)
				if contact_phase:
					worst[f] = maxf(worst[f], err)
				if k == 0 or k == frames:
					ends[f] = maxf(ends[f], err)
			if c.begins_with("getup"):
				for j in sk.get_bone_count():
					var jn := sk.get_bone_name(j)
					if jn == "board" or jn == "Root" or jn.begins_with("ik_") or jn.begins_with("pole"):
						continue
					var hj: float = (sk.global_transform * sk.get_bone_global_pose(j).origin).y - sk.global_position.y
					if hj < floor_low:
						floor_low = hj
						floor_at = "%s at %.0f%%" % [jn, 100.0 * float(k) / maxf(1.0, frames)]
		var note := ""
		if c in FLIPS:
			note = "flip: checked at pop + catch; feet hover up to %.1f cm over the spinning board" % (hover * 100.0)
		elif c == "push":
			note = "one foot pushes on the ground by design"
		elif c == "bail":
			note = "falls off the board by design"
		elif c.begins_with("getup"):
			note = "gets up from the floor (%s): feet checked once back on the deck (last 10%%)" % ("on the back" if c == "getup" else "face down")
		table.append("%-12s %8.1f %8.1f %8.1f %8.1f   %s" % [c, worst[0] * 100, worst[1] * 100, ends[0] * 100, ends[1] * 100, note])
		if c.begins_with("getup"):
			check(inside < 0.005, "%s: no foot passes through the board while stepping on (deepest %.1f cm)" % [c, inside * 100.0])
			check(floor_low > -0.01, "%s: no joint goes below the floor while getting up (lowest %.1f cm: %s)" % [c, floor_low * 100.0, floor_at])
		if c == "bail":
			continue
		if c == "push":
			check(minf(worst[0], worst[1]) < TOL, "push: front foot planted on the deck")
		else:
			check(worst[0] < TOL and worst[1] < TOL, "%s: both feet on the deck (max error %.1f / %.1f cm)" % [c, worst[0] * 100, worst[1] * 100])
	var report := "Pro Skater animation tests  %s\n%s\n\n%s\n%d passed, %d failed\n" % [
			Time.get_datetime_string_from_system(), "\n".join(out), "\n".join(table), passed, failed]
	print(report)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/results"))
	var fh := FileAccess.open("res://tests/results/animations.txt", FileAccess.WRITE)
	fh.store_string(report)
	fh.close()
	quit(1 if failed > 0 else 0)
