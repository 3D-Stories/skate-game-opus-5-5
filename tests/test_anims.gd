extends SceneTree
## Headless checks of the Blender-authored clips inside the game (skater.glb):
##  * every clip the game needs exists and is non-empty
##  * feet stay on the board: for each clip, sampled every frame, the ankle bones sit on
##    the deck in the board bone's frame (the clips place the ankle 7.25 cm above the
##    shoe sole, the sole on the deck top). Flip clips are checked at pop and catch, and
##    their mid-flip hover is reported. The push clip's pushing foot and the bail are
##    reported but not required to be on the deck.
##  * the same for every body of the character builder (the female skater plays the shared
##    clips with her re-solved legs and arms: her ankle sits at her own height over the sole)
##  * and with every pair of shoes on every body (the garment that decides the contact):
##    the shoe soles themselves, skinned on the CPU exactly as the GPU does, rest on the deck
##    top in the same frames, and never sink into the deck
##   godot --headless --path . -s tests/test_anims.gd   -> tests/results/animations.txt

const REQUIRED := ["idle", "push", "ride", "crouch", "ollie", "kickflip", "heelflip", "shoveit", "treflip",
		"indy", "melon", "nosegrab", "tailgrab", "grind_5050", "boardslide", "manual", "nose_manual",
		"vert_air", "air", "land", "bail", "special", "ride_fakie", "getup", "getup_front"]
const FLIPS := ["kickflip", "heelflip", "shoveit", "treflip", "special"]
const DECK_TOP := 0.009
const ANKLE_ON_DECK := 0.0815    # deck top (0.009) + ankle above the sole (0.0725) - the male
const TOL := 0.02
const SOLE_SINK := 0.006         # deepest a sole may press into the deck (grip tape + a soft sole)

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
	var tables: PackedStringArray = []
	for body in SkaterOutfit.BODIES:
		var c := SkaterOutfit.default_choice()
		c["body"] = body
		var model: Node3D = load("res://scripts/skater/skater_model.gd").new()
		model.outfit = c
		root.add_child(model)
		await process_frame
		var ankle: float = DECK_TOP + SkaterOutfit.ankle_height(body) if body != "male" else ANKLE_ON_DECK
		tables.append(body_checks(model, body, ankle))
		model.queue_free()
		await process_frame
	var soles: PackedStringArray = []
	soles.append("%-7s %-11s %-12s %8s %8s %8s   %s" % ["body", "shoes", "clip", "L err", "R err", "sink", "(sole bottom vs deck top in the contact frames, cm)"])
	for body in SkaterOutfit.BODIES:
		for shoe in SkaterOutfit.options("shoes"):
			var c := SkaterOutfit.default_choice()
			c["body"] = body
			c["shoes"] = shoe
			var model: Node3D = load("res://scripts/skater/skater_model.gd").new()
			model.outfit = c
			root.add_child(model)
			await process_frame
			soles.append_array(sole_checks(model, body, shoe))
			model.queue_free()
			await process_frame
	var report := "Pro Skater animation tests  %s\n%s\n\n%s\n\nShoe soles on the deck, every body and pair of shoes\n%s\n%d passed, %d failed\n" % [
			Time.get_datetime_string_from_system(), "\n".join(out), "\n\n".join(tables), "\n".join(soles), passed, failed]
	print(report)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/results"))
	var fh := FileAccess.open("res://tests/results/animations.txt", FileAccess.WRITE)
	fh.store_string(report)
	fh.close()
	quit(1 if failed > 0 else 0)


func contact(c: String, u: float) -> bool:
	## The frames in which both feet belong on the deck (as the ankle checks below).
	if c in FLIPS:
		return u < 0.06 or u > 0.9
	if c.begins_with("getup"):
		return u >= (0.9 if c == "getup" else 0.94)
	return c != "bail"


func sole_checks(model: Node3D, body: String, shoe: String) -> PackedStringArray:
	## The lowest vertices of each sole (the tread), skinned per frame like the GPU does
	## (bone pose x inverse bind, weighted), measured in the board bone's frame.
	var rows: PackedStringArray = []
	var sk: Skeleton3D = model.skeleton
	var anim: AnimationPlayer = model.anim
	var bi := sk.find_bone("board")
	var n_local: Vector3 = (sk.get_bone_global_rest(bi).basis.inverse() * Vector3.UP).normalized()
	var info := SkaterOutfit.garment(shoe)
	var base := String(info.get("base", shoe))
	var feet := {}
	for mi: MeshInstance3D in model.garments.get(shoe, []):
		var n := String(mi.name)
		if not "Sole" in n:
			continue
		feet["l" if n.ends_with("_L") else "r"] = tread(mi, sk)
	check(feet.size() == 2 and feet["l"].size() > 10 and feet["r"].size() > 10,
			"%s / %s: both soles found (%s)" % [body, shoe, ", ".join(feet.keys().map(func(k): return "%s %d tread verts" % [k, feet[k].size()]))])
	if feet.size() != 2:
		return rows
	var worst_all := 0.0
	var sink_all := 0.0
	for c in REQUIRED:
		if not anim.has_animation(c) or c == "bail":
			continue
		anim.play(c)
		var length := anim.get_animation(c).length
		var frames := int(round(length * 30.0))
		var err := {"l": 0.0, "r": 0.0}
		var sink := 0.0
		for k in frames + 1:
			var u := float(k) / maxf(1.0, frames)
			if not contact(c, u):
				continue
			anim.seek(length * u, true)
			var Binv := sk.get_bone_global_pose(bi).affine_inverse()
			var poses := []
			for b in sk.get_bone_count():
				poses.append(sk.get_bone_global_pose(b))
			for f in ["l", "r"]:
				if c == "push" and f == "r":
					continue          # the pushing foot (checked: the front foot stays planted)
				var lo := 9.0
				for v in feet[f]:
					var p := Vector3.ZERO
					for j in v[1].size():
						p += (poses[v[1][j]] as Transform3D) * v[3][j] * v[0] * v[2][j]
					lo = minf(lo, (Binv * p).dot(n_local) - DECK_TOP)
				err[f] = maxf(err[f], absf(lo))
				sink = maxf(sink, -lo)
		worst_all = maxf(worst_all, maxf(err["l"], err["r"]))
		sink_all = maxf(sink_all, sink)
		rows.append("%-7s %-11s %-12s %8.1f %8.1f %8.1f" % [body, shoe, c, err["l"] * 100, err["r"] * 100, sink * 100])
	check(worst_all < TOL and sink_all < SOLE_SINK, "%s / %s: soles on the deck in every clip (max error %.1f cm, deepest into the deck %.1f cm)" % [body, shoe, worst_all * 100, sink_all * 100])
	return rows


func tread(mi: MeshInstance3D, sk: Skeleton3D) -> Array:
	## [rest position, bone indices, weights, bone pose -> inverse bind] for the sole's
	## vertices within 4 mm of its lowest point at rest.
	var arr := mi.mesh.surface_get_arrays(0)
	var V: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var B = arr[Mesh.ARRAY_BONES]
	var W = arr[Mesh.ARRAY_WEIGHTS]
	var per: int = (B as PackedInt32Array).size() / V.size()
	var skin: Skin = mi.skin
	var bind_bone := []
	for i in skin.get_bind_count():
		var b := skin.get_bind_bone(i)
		if b < 0:
			b = sk.find_bone(skin.get_bind_name(i))
		bind_bone.append(b)
	var zmin := 9.0
	for v in V:
		zmin = minf(zmin, v.y)
	var out: Array = []
	for i in V.size():
		if V[i].y > zmin + 0.004:
			continue
		var bones := PackedInt32Array()
		var ws := PackedFloat32Array()
		var binds: Array = []
		for j in per:
			var w: float = W[i * per + j]
			if w <= 0.0:
				continue
			var bix: int = B[i * per + j]
			bones.append(bind_bone[bix])
			ws.append(w)
			binds.append(skin.get_bind_pose(bix))
		out.append([V[i], bones, ws, binds])
	return out


func body_checks(model: Node3D, body: String, ankle_on_deck: float) -> String:
	var pre := "" if body == "male" else body + ": "
	var anim: AnimationPlayer = model.anim
	var sk: Skeleton3D = model.skeleton
	for c in REQUIRED:
		var ok: bool = anim.has_animation(c) and anim.get_animation(c).length > 0.1 and anim.get_animation(c).get_track_count() > 10
		check(ok, pre + "clip '%s' exported (%.2fs, %d tracks)" % [c, anim.get_animation(c).length if anim.has_animation(c) else 0.0,
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
	table.append("%s skater (ankle %.2f cm over the deck top)" % [body.capitalize(), (ankle_on_deck - DECK_TOP) * 100.0])
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
				var err := absf(rel.dot(n_local) - ankle_on_deck)
				var u := float(k) / maxf(1.0, frames)
				var contact_phase := true
				if c in FLIPS:
					contact_phase = u < 0.06 or u > 0.9
					if not contact_phase:
						hover = maxf(hover, rel.dot(n_local) - ankle_on_deck)
				elif c.begins_with("getup"):
					# up from the floor: both feet are on the deck from the step-on to the end
					# (getup: the 0.86 key, getup_front: the 0.94 key)
					contact_phase = u >= (0.9 if c == "getup" else 0.94)
					# and never inside the board on the way (ankle over the deck but below it)
					var hgt := rel.dot(n_local)
					if absf(rel.dot(a_local)) < 0.40 and absf(rel.dot(w_local)) < 0.10 and hgt < ankle_on_deck - 0.02:
						inside = maxf(inside, ankle_on_deck - hgt)
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
			check(inside < 0.005, pre + "%s: no foot passes through the board while stepping on (deepest %.1f cm)" % [c, inside * 100.0])
			check(floor_low > -0.01, pre + "%s: no joint goes below the floor while getting up (lowest %.1f cm: %s)" % [c, floor_low * 100.0, floor_at])
		if c == "bail":
			continue
		if c == "push":
			check(minf(worst[0], worst[1]) < TOL, pre + "push: front foot planted on the deck")
		else:
			check(worst[0] < TOL and worst[1] < TOL, pre + "%s: both feet on the deck (max error %.1f / %.1f cm)" % [c, worst[0] * 100, worst[1] * 100])
	anim.stop()
	return "\n".join(table)
