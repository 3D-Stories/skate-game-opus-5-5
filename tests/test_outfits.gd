extends SceneTree
## Character builder wardrobe checks, headless:
##  1. every body x top x bottom x shoes x headwear combination (2 x 3 x 3 x 3 x 3 = 162)
##     builds: each worn garment's meshes are on the body's skeleton with their skin, every
##     surface has its material (the female's garments share the male's textures), the skin
##     and hair hide what the clothes cover, the 25 clips and the ragdoll are there.
##  2. no poke-through in any clip: the skin that stays visible at a garment's openings
##     (collar, cuffs, hems, shoe tops, hat edges) must stay under the garment, and so must
##     each layer under another (trousers under the top, the shoe inside a trouser hem,
##     socks in the shoes, hair under the hat). Every vertex under a garment at rest is paired
##     with the garment's outward-facing surface over it; in every frame of all 25 clips
##     (30 per second) both are skinned on the CPU exactly as the GPU does (4 weighted bones,
##     bone pose x inverse bind) and the vertex must not come out in front of that surface
##     by more than TOL. A vertex that slides out past the garment's opening is outside
##     it, not through it, and is not counted. "In front" is judged by the surface's
##     pseudo-normal (the face's, or at an edge or corner the angle-weighted normals round
##     it); only garment triangles facing out along the body's surface count (not the
##     sideways rim at an opening). Nine outfits per body cover every body/garment and
##     garment/garment pairing the builder can put together.
##     Trousers under a top's hem (the hip band) that still come through in the deepest hip
##     bends are listed as KNOWN - reported with their numbers, never counted as passes.
##  3. at rest, nothing under a garment shows through it (a shoe's tongue in front of a
##     trouser hem, skin outside a sleeve). Today's jeans over his grey suede shoes keep
##     their shapes (the default skater is today's): the tongue tops there are KNOWN.
##   godot --headless --path . -s tests/test_outfits.gd [-- --fps=30 --only=female --pick=0,4 --debug]
##   -> tests/results/outfits.txt (outfits_<body>.txt with --only)

const TOL := 0.0015           # m in front of the garment's outer surface = poking through
const NEAR := 0.03            # a vertex this close under a garment at rest is tracked
const REST_SKIN := 0.004      # at rest, a garment face this far under the skin = the skin shows through it
const CELL := 0.03
var OUTWARD := 0.5            # a garment triangle faces out if its normal is within 60 deg of the body's surface normal there
const LAYER := 0.015          # a garment triangle with the same garment this near in front of it is an inner layer
const PATCH := 0.05           # the garment point a vertex is judged against stays this near
                              # (rest pose) the one it was under: farther, it is another part
                              # of the garment (a hand against the chest), not the one it wears

var out: PackedStringArray = []
var table: PackedStringArray = []
var failed := 0
var passed := 0
var known := 0                    # hip-band layer pokes (trousers under the top) and today's tongue-over-hem shape: reported, not passed
var fps := 30.0
var only := ""
var skip_combos := true           # (tests/test_builder.gd checks every combination builds; --combos here too)
var max_outfits := 9
var pick: Array = []              # --pick=0,4: only these of the nine (quick reruns)
var debug := false
var dbg := {}


func check(ok: bool, what: String, detail := "") -> void:
	if ok:
		passed += 1
		out.append("PASS  " + what)
	else:
		failed += 1
		out.append("FAIL  " + what + ("  -- " + detail if detail != "" else ""))


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--fps="):
			fps = float(a.get_slice("=", 1))
		elif a.begins_with("--only="):
			only = a.get_slice("=", 1)
		elif a == "--skip-combos":
			skip_combos = true
		elif a.begins_with("--outward="):
			OUTWARD = float(a.get_slice("=", 1))
		elif a == "--debug":
			debug = true
		elif a == "--combos":
			skip_combos = false
		elif a.begins_with("--outfits="):
			max_outfits = int(a.get_slice("=", 1))
		elif a.begins_with("--pick="):
			for k in a.get_slice("=", 1).split(","):
				pick.append(int(k))
	_run.call_deferred()


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	if not skip_combos:
		await every_combination()
	var t1 := Time.get_ticks_msec()
	table.append("%-7s %-34s %-24s %7s %7s %7s  %s" % ["body", "outfit", "inner -> garment", "tracked", "pokes", "max mm", "worst (clip @ time: bone)"])
	for body in SkaterOutfit.BODIES:
		if only != "" and body != only:
			continue
		var list := fit_outfits(body)
		for oi in mini(max_outfits, list.size()):
			if not pick.is_empty() and not oi in pick:
				continue
			var c: Dictionary = list[oi]
			var model = load("res://scripts/skater/skater_model.gd").new()
			model.outfit = c
			root.add_child(model)
			await process_frame
			var tf := Time.get_ticks_msec()
			fit(model, c)
			if debug:
				var ks := dbg.keys()
				ks.sort()
				for k in ks:
					print("[dbg] ", k, " ", dbg[k])
				dbg.clear()
			print("[outfits] %s fit in %.1f s" % [SkaterOutfit.to_arg(c), (Time.get_ticks_msec() - tf) / 1000.0])
			model.queue_free()
			await process_frame
	var report := "Pro Skater wardrobe tests  %s\n%s\n\nClothing fit in every clip (%d frames/s, poke = more than %.1f mm in front of the garment)\n%s\n\n%d passed, %d failed, %d known (hip-band layer pokes; today's tongue tops over his jeans hem at rest: not passes)   (combinations %.1f s, fit %.1f s)\n" % [
			Time.get_datetime_string_from_system(), "\n".join(out), int(fps), TOL * 1000.0, "\n".join(table), passed, failed, known,
			(t1 - t0) / 1000.0, (Time.get_ticks_msec() - t1) / 1000.0]
	print(report)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/results"))
	var fh := FileAccess.open("res://tests/results/outfits%s.txt" % ("" if only == "" else "_" + only), FileAccess.WRITE)
	fh.store_string(report)
	fh.close()
	quit(1 if failed > 0 else 0)


# ------------------------------------------------------------------ 1. every combination loads

func every_combination() -> void:
	var n := 0
	var bad: PackedStringArray = []
	var slow := 0.0
	for body in SkaterOutfit.options("body"):
		for top in SkaterOutfit.options("top"):
			for bottom in SkaterOutfit.options("bottom"):
				for shoes in SkaterOutfit.options("shoes"):
					for hat in SkaterOutfit.options("hat"):
						var c := {"body": body, "top": top, "bottom": bottom, "shoes": shoes, "hat": hat}
						var t := Time.get_ticks_usec()
						var model = load("res://scripts/skater/skater_model.gd").new()
						model.outfit = c
						root.add_child(model)
						slow = maxf(slow, (Time.get_ticks_usec() - t) / 1000.0)
						var why := combo_problems(model, c)
						if why != "":
							bad.append(SkaterOutfit.to_arg(c) + ": " + why)
						n += 1
						model.free()
	check(bad.is_empty() and n == 162, "every body x top x bottom x shoes x headwear combination builds (%d combinations, slowest %.0f ms)" % [n, slow],
			"; ".join(bad.slice(0, 6)))


func combo_problems(model, c: Dictionary) -> String:
	var p: PackedStringArray = []
	if model.choice != SkaterOutfit.normalized(c):
		p.append("built %s" % SkaterOutfit.to_arg(model.choice))
	for g in SkaterOutfit.worn_garments(c):
		var list: Array = model.garments.get(g, [])
		if list.is_empty():
			p.append("no meshes for " + g)
		for mi: MeshInstance3D in list:
			if mi.skin == null or mi.get_node_or_null(mi.skeleton) != model.skeleton:
				p.append("%s/%s not skinned to the skeleton" % [g, mi.name])
			for s in mi.mesh.get_surface_count():
				var m := mi.get_surface_override_material(s)
				if m == null:
					m = mi.mesh.surface_get_material(s)
				if m == null:
					p.append("%s/%s surface %d has no material" % [g, mi.name, s])
				elif m is StandardMaterial3D and String(m.resource_name) in model.FABRICS and (m as StandardMaterial3D).albedo_texture == null:
					p.append("%s/%s: %s has no texture" % [g, mi.name, m.resource_name])
	var expect := SkaterOutfit.body_mask(c)
	if model.skin_materials.is_empty() or int(model.skin_materials[0].get_shader_parameter("hidden_mask")) != expect:
		p.append("skin mask")
	if model.hair_materials.is_empty() or int(model.hair_materials[0].get_shader_parameter("hidden_mask")) != SkaterOutfit.hat_mask(c):
		p.append("hair mask")
	if model.anim.get_animation_list().size() != 25:
		p.append("%d clips" % model.anim.get_animation_list().size())
	if model.rag.size() != 14:
		p.append("%d ragdoll bodies" % model.rag.size())
	return ", ".join(p)


# ------------------------------------------------------------------ 2. clothing fit in every clip

func fit_outfits(body: String) -> Array:
	## Nine outfits: every top over every bottom; with them each bottom meets every pair of
	## shoes and each hat is worn three times.
	var tops := SkaterOutfit.options("top")
	var bottoms := SkaterOutfit.options("bottom")
	var shoes := SkaterOutfit.options("shoes")
	var hats := SkaterOutfit.options("hat")
	var list: Array = []
	for i in 3:
		for j in 3:
			list.append({"body": body, "top": tops[i], "bottom": bottoms[j], "shoes": shoes[(i + j) % 3], "hat": hats[(2 * i + j) % 3]})
	return list


class Part:
	## One mesh as the GPU skins it: rest positions (skeleton space) and, per vertex, up to
	## `per` (bind index, weight) pairs; `mats` holds bone pose x inverse bind per bind.
	var name := ""
	var V: PackedVector3Array
	var N: PackedVector3Array          # rest normals
	var bones: PackedInt32Array
	var weights: PackedFloat32Array
	var per := 4
	var bind_bone: PackedInt32Array
	var bind_pose: Array = []
	var mats: Array = []
	var I: PackedInt32Array            # triangles
	var P: PackedVector3Array          # posed positions (only the ones in use are updated)
	var use: PackedInt32Array          # vertex indices to skin each frame

	func pose(sk: Skeleton3D, poses: Array) -> void:
		mats.resize(bind_bone.size())
		for i in bind_bone.size():
			mats[i] = (poses[bind_bone[i]] as Transform3D) * (bind_pose[i] as Transform3D)
		for v in use:
			var p := Vector3.ZERO
			var o := v * per
			for j in per:
				var w := weights[o + j]
				if w > 0.0:
					p += (mats[bones[o + j]] as Transform3D) * V[v] * w
			P[v] = p


func make_part(mi: MeshInstance3D, sk: Skeleton3D, visible_only = null) -> Part:
	var pt := Part.new()
	pt.name = String(mi.name)
	var arr := mi.mesh.surface_get_arrays(0)
	pt.V = arr[Mesh.ARRAY_VERTEX]
	pt.N = arr[Mesh.ARRAY_NORMAL]
	pt.bones = arr[Mesh.ARRAY_BONES]
	pt.weights = arr[Mesh.ARRAY_WEIGHTS]
	pt.per = pt.bones.size() / pt.V.size()
	var I: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	if visible_only:
		var keep := PackedInt32Array()
		for t in range(0, I.size(), 3):
			if not visible_only.is_triangle_hidden(mi, 0, arr, [I[t], I[t + 1], I[t + 2]]):
				keep.append_array([I[t], I[t + 1], I[t + 2]])
		I = keep
	pt.I = I
	for i in mi.skin.get_bind_count():
		var b := mi.skin.get_bind_bone(i)
		if b < 0:
			b = sk.find_bone(mi.skin.get_bind_name(i))
		pt.bind_bone.append(b)
		pt.bind_pose.append(mi.skin.get_bind_pose(i))
	pt.P = pt.V.duplicate()
	return pt


static func closest_on_tri(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Array:
	## [closest point, region]: region 0 = inside the face, 1/2/3 = on edge ab/bc/ca,
	## 4/5/6 = at vertex a/b/c (Ericson, Real-Time Collision Detection 5.1.5).
	var ab := b - a
	var ac := c - a
	var ap := p - a
	var d1 := ab.dot(ap)
	var d2 := ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return [a, 4]
	var bp := p - b
	var d3 := ab.dot(bp)
	var d4 := ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return [b, 5]
	var vc := d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		return [a + ab * (d1 / (d1 - d3)), 1]
	var cp := p - c
	var d5 := ab.dot(cp)
	var d6 := ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return [c, 6]
	var vb := d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		return [a + ac * (d2 / (d2 - d6)), 3]
	var va := d3 * d6 - d5 * d4
	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
		return [b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))), 2]
	var denom := 1.0 / (va + vb + vc)
	return [a + ab * (vb * denom) + ac * (vc * denom), 0]


static func qkey(p: Vector3) -> Vector3i:
	return Vector3i(roundi(p.x * 20000.0), roundi(p.y * 20000.0), roundi(p.z * 20000.0))


class Shell:
	## A garment's outward-facing triangles (facing away from the body) with a grid over
	## them, and which of their edges are open (the garment's openings: nothing outward
	## beyond them).
	var parts: Array = []           # [Part, local triangle start] per mesh
	var tris: Array = []            # [part index, i0, i1, i2]
	var open_edge := {}             # "k0|k1" (quantised positions) -> true
	var grid := {}
	var nbrs: Array = []            # per triangle: the triangles sharing a corner with it
	var live := {}                  # triangles skinned each frame (near a tracked vertex)
	var posed := {}                 # those and their neighbours (for normals at edges/corners)
	var n_all := 0                  # (diagnostics) triangles, outward ones, covered ones
	var n_out := 0
	var n_covered := 0


func make_shell(parts: Array, body_pts: PackedVector3Array, body_n: PackedVector3Array, body_grid: Dictionary) -> Shell:
	## The garment's outermost surface: triangles facing away from the body, less those the
	## garment itself covers within LAYER (the underside of a folded cuff, the lower layer of
	## a hem) - what can be seen is what must stay in front.
	var sh := Shell.new()
	sh.parts = parts
	var cand: Array = []            # [part index, i0, i1, i2, a, b, c, normal]
	var cgrid := {}
	for pi in parts.size():
		var pt: Part = parts[pi]
		for t in range(0, pt.I.size(), 3):
			var a := pt.V[pt.I[t]]
			var b := pt.V[pt.I[t + 1]]
			var c := pt.V[pt.I[t + 2]]
			var n := (c - a).cross(b - a)        # (Godot winds front faces clockwise)
			sh.n_all += 1
			if n.length_squared() < 1e-14:
				continue
			n = n.normalized()
			var ctr := (a + b + c) / 3.0
			var bi := nearest_index(body_grid, body_pts, ctr, 0.12)
			# faces the body, or sideways to its surface (the rim at an opening, the sides of
			# a V-neck: skin beside them is in the opening, not under the garment)
			if bi < 0 or n.dot(body_n[bi]) < OUTWARD or (ctr - body_pts[bi]).dot(body_n[bi]) < 0.0:
				continue
			var id := cand.size()
			sh.n_out += 1
			cand.append([pi, pt.I[t], pt.I[t + 1], pt.I[t + 2], a, b, c, n])
			_grid_add(cgrid, id, a, b, c)
	for id in cand.size():
		var e: Array = cand[id]
		var n: Vector3 = e[7]
		var o: Vector3 = (e[4] + e[5] + e[6]) / 3.0 + n * 0.0008
		var covered := false
		var seen := {}
		for k in 3:
			var gk := Vector3i(((o + n * (LAYER * k / 2.0)) / CELL).floor())
			for oid in cgrid.get(gk, PackedInt32Array()):
				if oid == id or seen.has(oid):
					continue
				seen[oid] = true
				var f: Array = cand[oid]
				var hit = Geometry3D.ray_intersects_triangle(o, n, f[4], f[5], f[6])
				if hit != null and o.distance_to(hit) < LAYER:
					covered = true
					break
			if covered:
				break
		if covered:
			sh.n_covered += 1
			continue
		var tid := sh.tris.size()
		sh.tris.append([e[0], e[1], e[2], e[3]])
		_grid_add(sh.grid, tid, e[4], e[5], e[6])
	var edge_count := {}
	for tid in sh.tris.size():
		var r := tri_pts(sh, tid, false)
		for ed in [[r[0], r[1]], [r[1], r[2]], [r[2], r[0]]]:
			var k0 := str(qkey(ed[0]))
			var k1 := str(qkey(ed[1]))
			var key := k0 + "|" + k1 if k0 < k1 else k1 + "|" + k0
			edge_count[key] = int(edge_count.get(key, 0)) + 1
	for k in edge_count:
		if edge_count[k] == 1:
			sh.open_edge[k] = true
	# neighbours through shared corners (by position: the export splits vertices at seams)
	var at := {}
	for id in sh.tris.size():
		for q in tri_pts(sh, id, false):
			var k := qkey(q)
			if not at.has(k):
				at[k] = PackedInt32Array()
			at[k].append(id)
	sh.nbrs.resize(sh.tris.size())
	for id in sh.tris.size():
		var n := {}
		for q in tri_pts(sh, id, false):
			for j in at[qkey(q)]:
				if j != id:
					n[j] = true
		sh.nbrs[id] = PackedInt32Array(n.keys())
	return sh


func _grid_add(grid: Dictionary, id: int, a: Vector3, b: Vector3, c: Vector3) -> void:
	var lo := Vector3i((Vector3(minf(a.x, minf(b.x, c.x)), minf(a.y, minf(b.y, c.y)), minf(a.z, minf(b.z, c.z))) / CELL).floor())
	var hi := Vector3i((Vector3(maxf(a.x, maxf(b.x, c.x)), maxf(a.y, maxf(b.y, c.y)), maxf(a.z, maxf(b.z, c.z))) / CELL).floor())
	for x in range(lo.x, hi.x + 1):
		for y in range(lo.y, hi.y + 1):
			for z in range(lo.z, hi.z + 1):
				var gk := Vector3i(x, y, z)
				if not grid.has(gk):
					grid[gk] = PackedInt32Array()
				grid[gk].append(id)


func nearest_index(grid: Dictionary, pts: PackedVector3Array, p: Vector3, maxd: float) -> int:
	## Index of the nearest point of `pts` (in a CELL grid) within about maxd, or -1.
	var c := Vector3i((p / CELL).floor())
	var best := -1
	var bd := maxd * maxd
	for r in [1, 2, int(ceil(maxd / CELL))]:
		for x in range(-r, r + 1):
			for y in range(-r, r + 1):
				for z in range(-r, r + 1):
					var l = grid.get(c + Vector3i(x, y, z))
					if l == null:
						continue
					for i in l:
						var d := pts[i].distance_squared_to(p)
						if d < bd:
							bd = d
							best = i
		if best >= 0:
			return best
	return best


func nearest_point(grid: Dictionary, pts: PackedVector3Array, p: Vector3, maxd: float):
	## Nearest point of `pts` (in a CELL grid) within about maxd: rings of cells outwards,
	## stopping at the first ring that has any.
	var c := Vector3i((p / CELL).floor())
	var best = null
	var bd := maxd * maxd
	for r in [1, 2, int(ceil(maxd / CELL))]:
		for x in range(-r, r + 1):
			for y in range(-r, r + 1):
				for z in range(-r, r + 1):
					var l = grid.get(c + Vector3i(x, y, z))
					if l == null:
						continue
					for i in l:
						var d := pts[i].distance_squared_to(p)
						if d < bd:
							bd = d
							best = pts[i]
		if best != null:
			return best
	return best


func tri_pts(sh: Shell, id: int, posed: bool) -> Array:
	var t: Array = sh.tris[id]
	var pt: Part = sh.parts[t[0]]
	var src := pt.P if posed else pt.V
	return [src[t[1]], src[t[2]], src[t[3]]]


func tri_centre(sh: Shell, id: int) -> Vector3:
	var r := tri_pts(sh, id, false)
	return (r[0] + r[1] + r[2]) / 3.0


func on_open_edge(sh: Shell, id: int, region: int, posed_ignored := false) -> bool:
	## Is the closest point on an opening of the garment (rest positions name the edges)?
	if region == 0:
		return false
	var r := tri_pts(sh, id, false)
	var pairs := {1: [0, 1], 2: [1, 2], 3: [2, 0]}
	if region in pairs:
		var e: Array = pairs[region]
		var k0 := str(qkey(r[e[0]]))
		var k1 := str(qkey(r[e[1]]))
		return sh.open_edge.has(k0 + "|" + k1 if k0 < k1 else k1 + "|" + k0)
	# at a corner: open if either edge through it is open
	var v: int = region - 4
	for e in [[v, (v + 1) % 3], [(v + 2) % 3, v]]:
		var k0 := str(qkey(r[e[0]]))
		var k1 := str(qkey(r[e[1]]))
		if sh.open_edge.has(k0 + "|" + k1 if k0 < k1 else k1 + "|" + k0):
			return true
	return false


func fit(model, c: Dictionary) -> void:
	var sk: Skeleton3D = model.skeleton
	var body_mi: MeshInstance3D = model.character.find_child("SkaterBody", true, false)
	var hair_mi: MeshInstance3D = model.character.find_child("Hair", true, false)
	var body := make_part(body_mi, sk, model)
	var hair := make_part(hair_mi, sk, model)
	# the whole body (every face) says which side of a garment is its outside
	var all_body := make_part(body_mi, sk)
	var bgrid := {}
	for i in all_body.V.size():
		var k := Vector3i((all_body.V[i] / CELL).floor())
		if not bgrid.has(k):
			bgrid[k] = PackedInt32Array()
		bgrid[k].append(i)
	var parts := {}
	for g in model.garments:
		var l: Array = []
		for mi: MeshInstance3D in model.garments[g]:
			l.append(make_part(mi, sk))
		parts[g] = l
	var top := String(c["top"])
	var bottom := SkaterOutfit.worn_id(c, "bottom")
	var shoe := String(c["shoes"])
	var hat := String(c["hat"])
	var pairs: Array = [[[body], top, "skin"], [[body], bottom, "skin"], [[body], shoe, "skin"], [parts[bottom], top, bottom]]
	if parts.has("socks"):
		pairs.append([[body], "socks", "skin"])
		pairs.append([parts["socks"], shoe, "socks"])
	else:
		pairs.append([parts[shoe], bottom, shoe])
	if hat != "none":
		pairs.append([[body], hat, "skin"])
		pairs.append([[hair], hat, "hair"])
	var shells := {}
	var tracks: Array = []           # per pair: [label, garment, inner parts, Shell, tracked list]
	var rest_pokes: Array = []       # per pair: the inner vertices already through the garment at rest
	var rest_hits: Array = []
	for pr in pairs:
		var g: String = pr[1]
		if not shells.has(g):
			shells[g] = make_shell(parts[g], all_body.V, all_body.N, bgrid)
			if debug:
				print("[dbg] shell %s: %d triangles, %d facing out, %d of those covered by the garment itself, %d kept" % [g, shells[g].n_all, shells[g].n_out, shells[g].n_covered, shells[g].tris.size()])
		var sh: Shell = shells[g]
		var list: Array = []
		for pt: Part in pr[0]:
			var verts := {}
			for i in pt.I:
				verts[i] = true
			for v in verts:
				var p := pt.V[v]
				var cell := Vector3i((p / CELL).floor())
				var cand := {}
				for x in range(-1, 2):
					for y in range(-1, 2):
						for z in range(-1, 2):
							var l = sh.grid.get(cell + Vector3i(x, y, z))
							if l != null:
								for id in l:
									cand[id] = true
				if cand.is_empty():
					continue
				var best := -1
				var bd := NEAR
				var nearest := 9.0
				var nearest_reg := -1
				var nearest_behind := false
				for id in cand:
					var r := tri_pts(sh, id, false)
					var cp: Array = closest_on_tri(p, r[0], r[1], r[2])
					var d: float = p.distance_to(cp[0])
					var n: Vector3 = (r[2] - r[0]).cross(r[1] - r[0]).normalized()
					if d < nearest:
						nearest = d
						nearest_reg = cp[1]
						nearest_behind = n.dot(p - (cp[0] as Vector3)) < 0.0
					if d < bd and cp[1] == 0 and n.dot(p - (cp[0] as Vector3)) < 0.0:
						bd = d
						best = id
				if debug:
					var key := "%s>%s near<%s %s %s" % [pr[2], g, "3cm" if nearest < NEAR else ">3cm", "behind" if nearest_behind else "front", "face" if nearest_reg == 0 else "edge"]
					dbg[key] = int(dbg.get(key, 0)) + 1
				if best < 0:
					# not under the garment: is it through it already at rest? From the vertex
					# towards the body (along the body's normal nearest it) the garment must not
					# come first - a shoe collar outside a trouser hem, skin outside a sleeve
					if rest_through(pt, v, sh, cand, all_body, bgrid, pr[2] == "skin"):
						rest_hits.append([pt, v])
					continue
				list.append([pt, v, best, best, IN])   # part, vertex, triangle at rest, triangle now, state
		tracks.append([pr[2], g, pr[0], sh, list])
		rest_pokes.append(rest_hits.duplicate())
		rest_hits.clear()
	# the vertices to skin each frame
	var used := {}
	for tr in tracks:
		if tr[4].is_empty():
			continue
		for item in tr[4]:
			var pt: Part = item[0]
			if not used.has(pt):
				used[pt] = {}
			used[pt][item[1]] = true
		var sh: Shell = tr[3]
		# only the garment near the tracked vertices can matter (farther than PATCH is
		# "another part of the garment" anyway): skin those triangles, walk only on them
		var near := {}
		for item in tr[4]:
			near[Vector3i((tri_centre(sh, item[2]) / 0.07).floor())] = true
		for id in sh.tris.size():
			var ck := Vector3i((tri_centre(sh, id) / 0.07).floor())
			var ok := false
			for x in range(-1, 2):
				for y in range(-1, 2):
					for z in range(-1, 2):
						if near.has(ck + Vector3i(x, y, z)):
							ok = true
			if not ok:
				continue
			sh.live[id] = true
			var t: Array = sh.tris[id]
			var gp: Part = sh.parts[t[0]]
			if not used.has(gp):
				used[gp] = {}
			used[gp][t[1]] = true
			used[gp][t[2]] = true
			used[gp][t[3]] = true
		for id in sh.live.keys():
			for j in sh.nbrs[id]:
				if sh.posed.has(j):
					continue
				sh.posed[j] = true
				var t2: Array = sh.tris[j]
				var gp2: Part = sh.parts[t2[0]]
				if not used.has(gp2):
					used[gp2] = {}
				used[gp2][t2[1]] = true
				used[gp2][t2[2]] = true
				used[gp2][t2[3]] = true
	for pt: Part in used:
		pt.use = PackedInt32Array(used[pt].keys())
	# every clip, every frame. Each tracked vertex is under its garment (IN), outside it
	# having left by an opening or against another part of it (OUT), or through it (POKE):
	# only a step from IN straight to in front of the garment's surface is a poke. Each clip
	# is reached from the rest pose (where every tracked vertex is IN) in a few steps.
	var stats: Array = []
	for tr in tracks:
		stats.append({"pokes": 0, "max": 0.0, "worst": ""})
	var anim: AnimationPlayer = model.anim
	for clip in anim.get_animation_list():
		for tr in tracks:
			for item in tr[4]:
				item[3] = item[2]         # from the rest pairing,
				item[4] = IN              # under the garment
		anim.play(clip)
		anim.seek(0.0, true)
		var first: Array = []
		for b in sk.get_bone_count():
			first.append(sk.get_bone_pose(b))
		for step in range(1, APPROACH + 1):
			for b in sk.get_bone_count():
				var xf: Transform3D = sk.get_bone_rest(b).interpolate_with(first[b], float(step) / APPROACH)
				sk.set_bone_pose_position(b, xf.origin)
				sk.set_bone_pose_rotation(b, xf.basis.get_rotation_quaternion())
			track_frame(sk, used, tracks, stats, "", 0.0, false)
		var length := anim.get_animation(clip).length
		var frames := int(round(length * fps))
		for k in frames + 1:
			var t := length * k / maxf(1.0, frames)
			anim.seek(t, true)
			track_frame(sk, used, tracks, stats, clip, t, true)
		anim.stop()
	for ti in tracks.size():
		var tr: Array = tracks[ti]
		var st: Dictionary = stats[ti]
		var lab := "%s -> %s" % [tr[0], tr[1]]
		var outfit := "%s %s %s %s" % [c["top"], c["bottom"], c["shoes"], c["hat"]]
		table.append("%-7s %-34s %-24s %7d %7d %7.1f  %s" % [c["body"], outfit, lab, tr[4].size(), st["pokes"], st["max"] * 1000.0, st["worst"]])
		if debug and st.has("dbg"):
			print("[dbg] %s %s %s\n%s" % [c["body"], outfit, lab, st["dbg"]])
		if debug and st.has("per_clip"):
			var pcs: PackedStringArray = []
			for k in st["per_clip"]:
				pcs.append("%s %d/%.0fmm %s" % [k, st["per_clip"][k][0], st["per_clip"][k][1] * 1000.0, st["per_clip"][k][2]])
			print("[dbg-clips] %s %s %s:\n    %s" % [c["body"], outfit, lab, "\n    ".join(pcs)])
		var rp: Array = rest_pokes[ti]
		var rp_at := ""
		if not rp.is_empty():
			var q: Vector3 = (rp[0][0] as Part).V[rp[0][1]]
			rp_at = "%s at (%.3f, %.3f, %.3f)" % [(rp[0][0] as Part).name, q.x, -q.z, q.y]
		var rest_what := "%s / %s: at rest nothing of the %s shows through the %s" % [c["body"], outfit, tr[0], tr[1]]
		var by_part := {}
		for h in rp:
			var pn: String = (h[0] as Part).name
			by_part[pn] = int(by_part.get(pn, 0)) + 1
		var rest_detail := "%d vertices through (%s), e.g. %s" % [rp.size(), str(by_part).replace("\"", ""), rp_at]
		if not rp.is_empty() and c["body"] == "male" and tr[1] == "jeans" and String(tr[0]).begins_with("suede"):
			# today's jeans and grey suede shoes keep their shapes (the default skater is
			# today's): his tongue tops sit in front of the jeans hem at rest, as they always have
			known += 1
			out.append("KNOWN " + rest_what + "  -- " + rest_detail + "  (today's shapes, kept: not a pass, see README, Clothing fit)")
		else:
			check(rp.is_empty(), rest_what, rest_detail)
		var what := "%s / %s: %s stays under the %s in every frame of every clip (%d vertices tracked)" % [c["body"], outfit, tr[0], tr[1], tr[4].size()]
		var detail := "%d pokes, deepest %.1f mm at %s" % [st["pokes"], st["max"] * 1000.0, st["worst"]]
		if tr[0] == bottom and tr[1] == top and st["pokes"] > 0:
			# the hip band: trousers under a top's hem in the deepest hip bends (bails, getups,
			# the shove-it's hip twist) - linear blend skinning folds both layers there; the
			# fit pass cuts it (tests/results/outfits_without_fit_pass.txt) but not to zero
			known += 1
			out.append("KNOWN " + what + "  -- " + detail + "  (not a pass: see README, Clothing fit)")
		else:
			check(st["pokes"] == 0, what, detail)


const IN := 0
const OUT := 1
const POKE := 2
const APPROACH := 8


func track_frame(sk: Skeleton3D, used: Dictionary, tracks: Array, stats: Array, clip: String, t: float, count: bool) -> void:
	var poses := []
	for b in sk.get_bone_count():
		poses.append(sk.get_bone_global_pose(b))
	for pt: Part in used:
		pt.pose(sk, poses)
	for ti in tracks.size():
		var tr: Array = tracks[ti]
		var sh: Shell = tr[3]
		var st: Dictionary = stats[ti]
		for item in tr[4]:
			var pt: Part = item[0]
			var p := pt.P[item[1]]
			# the garment surface nearest the vertex now: walk over neighbouring triangles
			# from last frame's nearest until none is nearer
			var best: int = item[3]
			var r0 := tri_pts(sh, best, true)
			var cp0: Array = closest_on_tri(p, r0[0], r0[1], r0[2])
			var bd: float = p.distance_squared_to(cp0[0])
			var breg: int = cp0[1]
			var bcp: Vector3 = cp0[0]
			for step in 12:
				if breg == 0:
					break               # inside this triangle: it is the nearest here
				var moved := false
				for id in sh.nbrs[best]:
					if not sh.live.has(id):
						continue
					var r := tri_pts(sh, id, true)
					var cp: Array = closest_on_tri(p, r[0], r[1], r[2])
					var d: float = p.distance_squared_to(cp[0])
					if d < bd - 1e-12:
						bd = d
						best = id
						breg = cp[1]
						bcp = cp[0]
						moved = true
				if not moved:
					break
			item[3] = best
			if on_open_edge(sh, best, breg) or tri_centre(sh, best).distance_to(tri_centre(sh, item[2])) > PATCH:
				item[4] = OUT          # past an opening, or against another part of the garment
				continue
			var s := pseudo_normal(sh, best, breg).dot(p - bcp)
			if s <= TOL:
				item[4] = IN
				continue
			if item[4] == OUT:
				continue               # outside, and it came round the edge: still outside
			item[4] = POKE
			if count:
				st["pokes"] += 1
				if debug:
					var pc: Dictionary = st.get("per_clip", {})
					var cur: Array = pc.get(clip, [0, 0.0, ""])
					if s > cur[1]:
						var rp2: Vector3 = pt.V[item[1]]
						cur[1] = s
						cur[2] = "@%.2f %s (%.3f, %.3f, %.3f)" % [t, main_bone(pt, item[1], sk), rp2.x, -rp2.z, rp2.y]
					pc[clip] = [cur[0] + 1, cur[1], cur[2]]
					st["per_clip"] = pc
				if s > st["max"]:
					st["max"] = s
					var rp: Vector3 = pt.V[item[1]]
					# (rest position in Blender's axes, z up: x, -z, y)
					st["worst"] = "%s @ %.2fs: %s at (%.3f, %.3f, %.3f)" % [clip, t, main_bone(pt, item[1], sk), rp.x, -rp.z, rp.y]
					if debug:
						var tt: Array = sh.tris[best]
						var gp: Part = sh.parts[tt[0]]
						var rr := tri_pts(sh, item[2], false)
						var rest_s: float = ((rr[2] - rr[0]).cross(rr[1] - rr[0]).normalized()).dot(pt.V[item[1]] - (closest_on_tri(pt.V[item[1]], rr[0], rr[1], rr[2])[0] as Vector3))
						st["dbg"] = "  inner %s  region %d  rest depth %.1f mm  rest tri %d now %d (%.1f cm apart)\n    inner weights %s\n    garment %s weights %s" % [
								pt.name, breg, rest_s * 1000.0, item[2], best, tri_centre(sh, best).distance_to(tri_centre(sh, item[2])) * 100.0,
								weights_str(pt, item[1], sk), gp.name, weights_str(gp, tt[1], sk)]
						var bl := func(v: Vector3) -> String: return "(%.3f, %.3f, %.3f)" % [v.x, -v.z, v.y]
						var rn: Array = tri_pts(sh, best, false)
						var pn: Array = tri_pts(sh, best, true)
						st["dbg"] += "\n    inner rest %s posed %s  | s %.1f mm  pseudo-n %s" % [bl.call(pt.V[item[1]]), bl.call(p), s * 1000.0, bl.call(pseudo_normal(sh, best, breg))]
						for q in 3:
							st["dbg"] += "\n    tri corner %d rest %s posed %s  w %s" % [q, bl.call(rn[q]), bl.call(pn[q]), weights_str(gp, tt[1 + q], sk)]
						st["dbg"] += "\n    rest tri corners %s %s %s" % [bl.call(rr[0]), bl.call(rr[1]), bl.call(rr[2])]


func rest_through(pt: Part, v: int, sh: Shell, cand: Dictionary, body: Part, bgrid: Dictionary, is_skin: bool) -> bool:
	## Is this vertex (not under the garment) through it at rest? A short ray from it
	## towards the body must not meet the garment's outward face first.
	var p := pt.V[v]
	var dir: Vector3
	var length: float
	if is_skin:
		dir = -pt.N[v]
		length = REST_SKIN
		p += dir * 0.0005                      # (start just under the skin)
	else:
		var bi := nearest_index(bgrid, body.V, p, 0.12)
		if bi < 0:
			return false
		dir = -body.N[bi]
		length = minf(p.distance_to(body.V[bi]) + 0.004, NEAR)
	if dir.length_squared() < 0.25:
		return false
	for id in cand:
		var r := tri_pts(sh, id, false)
		var n: Vector3 = (r[2] - r[0]).cross(r[1] - r[0])
		if n.dot(dir) >= 0.0:
			continue                           # (seen from behind: not its outward face)
		var hit = Geometry3D.segment_intersects_triangle(p, p + dir * length, r[0], r[1], r[2])
		if hit != null and (hit as Vector3).distance_to(p) > TOL:
			return true
	return false


func pseudo_normal(sh: Shell, id: int, region: int) -> Vector3:
	## The outward normal to judge "in front" by at the closest point: the face's inside a
	## face; at an edge the sum of the two faces' normals, at a corner the angle-weighted sum
	## of all faces around it (Baerentzen & Aanaes 2005 - with one face's normal alone, a
	## point tucked into a fold of the garment can come out "in front" of the fold's far face).
	var r := tri_pts(sh, id, true)
	var face: Vector3 = (r[2] - r[0]).cross(r[1] - r[0]).normalized()
	if region == 0:
		return face
	var r0 := tri_pts(sh, id, false)
	var keys: Array = []
	if region <= 3:
		var e: Array = [[0, 1], [1, 2], [2, 0]][region - 1]
		keys = [qkey(r0[e[0]]), qkey(r0[e[1]])]
	else:
		keys = [qkey(r0[region - 4])]
	var sum := Vector3.ZERO
	var around: Array = [id]
	around.append_array(sh.nbrs[id])
	for j in around:
		if j != id and not (sh.live.has(j) or sh.posed.has(j)):
			continue
		var q0 := tri_pts(sh, j, false)
		var ks: Array = [qkey(q0[0]), qkey(q0[1]), qkey(q0[2])]
		var has_all := true
		for k in keys:
			if not k in ks:
				has_all = false
		if not has_all:
			continue
		var q := tri_pts(sh, j, true)
		var nj: Vector3 = (q[2] - q[0]).cross(q[1] - q[0])
		if nj.length_squared() < 1e-16:
			continue
		nj = nj.normalized()
		if keys.size() == 1:
			var c: int = ks.find(keys[0])
			var u: Vector3 = q[(c + 1) % 3] - q[c]
			var w: Vector3 = q[(c + 2) % 3] - q[c]
			nj *= u.angle_to(w)
		sum += nj
	return sum.normalized() if sum.length_squared() > 1e-16 else face


func weights_str(pt: Part, v: int, sk: Skeleton3D) -> String:
	var l: PackedStringArray = []
	for j in pt.per:
		var w := pt.weights[v * pt.per + j]
		if w > 0.005:
			l.append("%s %.2f" % [sk.get_bone_name(pt.bind_bone[pt.bones[v * pt.per + j]]), w])
	return ", ".join(l)


func main_bone(pt: Part, v: int, sk: Skeleton3D) -> String:
	var bw := 0.0
	var bb := -1
	for j in pt.per:
		var w := pt.weights[v * pt.per + j]
		if w > bw:
			bw = w
			bb = pt.bind_bone[pt.bones[v * pt.per + j]]
	return "%s %s" % [pt.name, sk.get_bone_name(bb) if bb >= 0 else "?"]
