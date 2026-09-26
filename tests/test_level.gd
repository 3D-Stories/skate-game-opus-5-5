extends SceneTree
## Park test suite for any registered level (the level kit's test template), on the real main
## scene, level and skater code. What it checks comes from the level's own data:
##
## every level (from assets/levels/<id>/<id>_data.json and levels/<id>/level.json "game"):
##  * the level loads through LevelRegistry, and the level select lists it with its goals
##    (a high score plus at least two goals of the level's own)
##  * real-world scale: rails / ledges at real heights above the ground under them, doorways
##    the 1.8 m skater fits through
##  * lightmap UVs: every lightmapped surface has UV2 inside [0,1], its material samples the
##    baked lightmap on UV2 and the bake has light where it samples
##  * grind surfaces: every grind line runs along real geometry and the real skater snaps
##    into GRIND on each one with the grind button
##  * breakables: each one breaks when the real skater rolls into it; reset_run restores it
##  * hidden areas: closed off while their breakable stands, then the real skater rolls in
##  * pickups: each letter and the tape sits in open space above solid ground, and the
##    level's own autopilot route collects every one and completes every goal in one
##    two-minute run
##
## the level's own (levels/<id>/level.json "test", Blender coordinates: x east, y north, z up):
##  * "scale": raycast measurements against the design (floors, depths, widths, heights)
##  * "rides": the transitions ridden by the real skater (airs out and back in, carves)
##  * "pump": pumping a transition back and forth builds height; not pumping loses it
##
##   godot --headless --path . --fixed-fps 60 -s tests/test_level.gd -- --level=<id>
##       -> tests/results/level_<id>.txt (the autopilot's log: tests/results/level_<id>_route.txt)

var main: Node
var lv: Node
var park: Node3D
var sk: Node
var space: PhysicsDirectSpaceState3D
var id := ""
var spec: Dictionary = {}
var out: PackedStringArray = []
var passed := 0
var failed := 0
var bails: Array = []


func check(ok: bool, what: String, detail := "") -> void:
	if ok:
		passed += 1
		out.append("PASS  " + what + ("  [" + detail + "]" if detail != "" else ""))
	else:
		failed += 1
		out.append("FAIL  " + what + ("  (" + detail + ")" if detail != "" else ""))


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


# ------------------------------------------------------------------ helpers

func frames(n: int) -> void:
	for i in n:
		await process_frame


func physics(n: int) -> void:
	for i in n:
		await physics_frame


func key(k: Key, down: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = k
	e.physical_keycode = k
	e.pressed = down
	Input.parse_input_event(e)


func tap_key(k: Key) -> void:
	key(k, true)
	await frames(2)
	key(k, false)
	await frames(2)


func ray(a: Vector3, b: Vector3, mask := 1, exclude: Array = []) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(a, b, mask, exclude)
	return space.intersect_ray(q)


func down(p: Vector3, depth := 30.0) -> Dictionary:
	return ray(p, p + Vector3.DOWN * depth)


func surf(hit: Dictionary) -> String:
	return lv.surface_of(hit["collider"]) if not hit.is_empty() else "none"


static func b2g(p: Array) -> Vector3:
	## Blender (x east, y north, z up) -> Godot (x, z up, -y)
	return Vector3(p[0], p[2] if p.size() > 2 else 0.0, -p[1])


func v3(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])


func fmt(v: float) -> String:
	return "%.2f" % v


func top_up() -> void:
	main.time_left = main.RUN_TIME


func park_skater() -> void:
	## Somewhere calm between checks: the spawn point, standing still.
	sk.spawn(lv.spawn_pos, lv.spawn_forward, 0.0)
	await physics(20)


func release_all() -> void:
	for k in [KEY_W, KEY_S, KEY_A, KEY_D, KEY_L, KEY_SPACE, KEY_K, KEY_J]:
		key(k, false)


func tris(mi: MeshInstance3D) -> PackedVector3Array:
	var f: PackedVector3Array = mi.mesh.get_faces()
	var xf := mi.global_transform
	for i in f.size():
		f[i] = xf * f[i]
	return f


# ------------------------------------------------------------------ main

func _run() -> void:
	await frames(5)
	lv = main.level
	park = lv.park
	sk = main.skater
	id = lv.level_id
	spec = LevelRegistry.def(id).get("test", {})
	space = lv.get_world_3d().direct_space_state
	sk.bailed.connect(func(r): bails.append(r))
	await physics(3)
	registry_and_select()
	scale_checks()
	lightmaps()
	grind_lines()
	pickups_static()
	await frames(30)
	await tap_key(KEY_ENTER)
	await frames(3)
	check(main.running and not paused, "run started from the start screen (Enter)")
	await grind_snaps()
	await rides()
	await pumping()
	await breakables()
	await hidden_areas()
	await autopilot_run()
	var report := "Pro Skater level tests: %s (%s)  %s\n%s\n%d passed, %d failed\n" % [
			String(lv.game.get("name", id)), id, Time.get_datetime_string_from_system(), "\n".join(out), passed, failed]
	print(report)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/results"))
	var f := FileAccess.open("res://tests/results/level_%s.txt" % id, FileAccess.WRITE)
	f.store_string(report)
	f.close()
	quit(1 if failed > 0 else 0)


# ------------------------------------------------------------------ registry + level select

func registry_and_select() -> void:
	var want := LevelRegistry.startup_id()
	check(LevelRegistry.has(id) and id == want and not lv.data.is_empty() and park != null,
			"the level loads through LevelRegistry (levels/registry.json -> levels/%s/level.json)" % id,
			"%s, %d grind lines, %d breakables" % [String(lv.game.get("name", "")), lv.rails.size(), lv.items.size()])
	var goals: Array = lv.game.get("goals", [])
	var own := goals.filter(func(g): return not (String(g.get("type", "")) in ["score", "letters", "tape"]))
	var has_score := goals.any(func(g): return String(g.get("type", "")) == "score" and int(g.get("target", 0)) > 0)
	check(has_score and own.size() >= 2 and int(lv.game.get("run_time", 0)) == 120,
			"a high-score goal plus at least two goals of the level's own, on one two-minute run",
			", ".join(goals.map(func(g): return String(g["id"]))))
	check(main.goals.size() == goals.size(), "the run's goal list is built from the level's data", "%d goals" % main.goals.size())
	var ls = load("res://scenes/level_select.tscn").instantiate()
	root.add_child(ls)
	ls.open(id)
	var card = null
	for c in ls.cards:
		if String(c.get_meta("id")) == id:
			card = c
	var text := ""
	if card:
		for n in card.find_children("*", "RichTextLabel", true, false):
			text += n.text
	var missing := goals.filter(func(g): return not (ls.goal_title(g) in text))
	check(ls.cards.size() == LevelRegistry.ids().size() and card != null and missing.is_empty(),
			"the level select shows a card for every registered level; this level's card lists its goals",
			"%d cards; %s" % [ls.cards.size(), "all goals listed" if missing.is_empty() else "missing " + str(missing)])
	ls.free()


# ------------------------------------------------------------------ scale

func scale_checks() -> void:
	## The level's own measurements ("test": "scale"), then generic real-world sanity.
	for m in spec.get("scale", []):
		var what := String(m["what"])
		var lo_hi: Array = m.get("expect", [0, 0])
		var val := NAN
		var extra := ""
		if m.has("down"):
			var p := b2g(m["down"])
			p.y = float(m.get("from", 20.0))
			var h := down(p)
			if not h.is_empty():
				val = h["position"].y
				extra = "surface " + surf(h)
				if m.has("surface") and surf(h) != String(m["surface"]):
					val = NAN
		elif m.has("mesh_top"):
			# a height from the mesh itself (for what has no collision: a roof out of reach)
			var mi := park.find_child(String(m["mesh_top"]), true, false) as MeshInstance3D
			if mi:
				val = (mi.global_transform * mi.get_aabb()).end.y
		elif m.has("up"):
			var p := b2g(m["up"])
			var h := ray(p, p + Vector3.UP * 40.0)
			if not h.is_empty():
				val = h["position"].y
		elif m.has("width"):
			# distance between the first surfaces hit either way along an axis
			var p := b2g(m["width"])
			var ax := b2g(m["axis"]).normalized()
			var h1 := ray(p, p + ax * 80.0)
			var h2 := ray(p, p - ax * 80.0)
			if not h1.is_empty() and not h2.is_empty():
				val = (h1["position"] - h2["position"]).length()
		elif m.has("steps"):
			# riser heights along a line: the heights of the treads above one another
			var a := b2g(m["steps"]["from"])
			var b := b2g(m["steps"]["to"])
			var n := int(m["steps"]["n"])
			var hs: Array = []
			for i in n:
				var p := a.lerp(b, (i + 0.5) / n)
				p.y = 20.0
				var h := down(p)
				hs.append(h["position"].y if not h.is_empty() else -99.0)
			var rises: Array = []
			for i in range(1, hs.size()):
				if absf(hs[i] - hs[i - 1]) > 0.05:      # (samples on the same tread / the floor / the landing)
					rises.append(snappedf(hs[i] - hs[i - 1], 0.01))
			val = rises.min() if rises.size() else NAN
			if rises.size() and rises.max() > float(lo_hi[1]):
				val = rises.max()
			if m["steps"].has("count") and rises.size() != int(m["steps"]["count"]):
				val = NAN
			extra = "%d risers, treads %s" % [rises.size(), str(hs.map(func(x): return snappedf(x, 0.01)))]
		var ok: bool = not is_nan(val) and val >= float(lo_hi[0]) and val <= float(lo_hi[1])
		check(ok, "scale: " + what, ("%s m (design %s..%s)" % [fmt(val), str(lo_hi[0]), str(lo_hi[1])]) + (", " + extra if extra != "" else ""))
	# rails stand at real heights above the ground right under them; ledges are the edges
	# of something solid, with a drop of at least 20 cm on one side
	var bad: Array = []
	var n := 0
	for r in lv.rails:
		if not (r.tag in ["rail", "ledge"]):
			continue
		n += 1
		for frac in [0.25, 0.5, 0.75]:
			var p: Vector3 = r.point_at(r.length * frac)
			var side: Vector3 = r.dir_at(r.length * frac).cross(Vector3.UP).normalized()
			if r.tag == "rail":
				var g := down(p + Vector3.DOWN * 0.08, 6.0)
				var hgt: float = p.y - (g["position"].y if not g.is_empty() else -99.0)
				if hgt < 0.25 or hgt > 1.25:
					bad.append("%s %.2f m up" % [r.name, hgt])
					break
			else:
				var drop := 0.0
				for sd in [side, -side]:
					var g := down(p + sd * 0.8 + Vector3.UP * 0.05, 12.0)
					drop = maxf(drop, p.y - (g["position"].y if not g.is_empty() else p.y - 12.0))
				if drop < 0.2:
					bad.append("%s drop %.2f m" % [r.name, drop])
					break
	check(bad.is_empty(), "scale: every rail is 0.25-1.25 m above the ground under it, every ledge an edge with a drop beside it",
			("%d rails / ledges" % n) if bad.is_empty() else "; ".join(bad))
	# doorways: the skater (1.8 m) rides through standing up
	var doors: Array = []
	for ha in lv.data.get("hidden_areas", []):
		if ha.has("door"):
			doors.append("%s %.1f x %.1f m" % [ha["name"], float(ha["door"]["width"]), float(ha["door"]["height"])])
			check(float(ha["door"]["width"]) >= 1.5 and float(ha["door"]["height"]) >= 2.2,
					"scale: the %s doorway fits a skater riding through (>= 1.5 m wide, >= 2.2 m high)" % ha["name"], doors[-1])


# ------------------------------------------------------------------ lightmaps

func lightmaps() -> void:
	var names: Array = lv.data.get("lightmapped", [])
	var lm_path := String(lv.game.get("assets", {}).get("lightmap", ""))
	var img := Image.load_from_file(ProjectSettings.globalize_path(lm_path))
	var lm = lv.LIGHTMAP
	check(lm != null and lm.get_width() >= 1024 and img != null and not img.is_empty(), "the level's baked lightmap texture loads",
			"%s %s" % [lm_path, str(lm.get_size()) if lm else "missing"])
	var bad: Array = []
	var dark: Array = []
	var total_area := 0.0
	var n_surf := 0
	var lit_means: Array = []
	for nm in names:
		var mi := park.find_child(nm, true, false) as MeshInstance3D
		if mi == null:
			bad.append(nm + " missing")
			continue
		for s in mi.mesh.get_surface_count():
			n_surf += 1
			var arr: Array = mi.mesh.surface_get_arrays(s)
			var uv2 = arr[Mesh.ARRAY_TEX_UV2]
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			if uv2 == null or uv2.size() == 0 or uv2.size() != verts.size():
				bad.append("%s: no UV2" % nm)
				continue
			var lo := Vector2(INF, INF)
			var hi := Vector2(-INF, -INF)
			for u in uv2:
				lo = lo.min(u)
				hi = hi.max(u)
			if lo.x < -1e-4 or lo.y < -1e-4 or hi.x > 1.0001 or hi.y > 1.0001:
				bad.append("%s: UV2 %s..%s" % [nm, str(lo), str(hi)])
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var area := 0.0
			for i in range(0, idx.size(), 3):
				var a: Vector2 = uv2[idx[i]]
				var b: Vector2 = uv2[idx[i + 1]]
				var c: Vector2 = uv2[idx[i + 2]]
				area += absf((b - a).cross(c - a)) * 0.5
			total_area += area
			if area <= 0.0:
				bad.append("%s: zero UV2 area" % nm)
			var lum := 0.0
			var cnt := 0
			var tstep := maxi(1, idx.size() / 3 / 600) * 3
			for i in range(0, idx.size(), tstep):
				var u: Vector2 = (uv2[idx[i]] + uv2[idx[i + 1]] + uv2[idx[i + 2]]) / 3.0
				lum += img.get_pixel(clampi(int(u.x * img.get_width()), 0, img.get_width() - 1),
						clampi(int(u.y * img.get_height()), 0, img.get_height() - 1)).get_luminance()
				cnt += 1
			lum /= maxf(1.0, cnt)
			lit_means.append(lum)
			if lum < 0.01:
				dark.append("%s: mean %.3f" % [nm, lum])
			var mat = mi.mesh.surface_get_material(s)
			if mi.material_override is ShaderMaterial:
				mat = mi.material_override
			if not (mat is ShaderMaterial):
				bad.append("%s: material %s" % [nm, mat.get_class() if mat else "null"])
				continue
			if not (mat.shader == lv.PARK_SHADER or mat.shader == lv.DECAL_SHADER):
				bad.append("%s: shader %s" % [nm, mat.shader.resource_path if mat.shader else "null"])
			if mat.get_shader_parameter("lightmap_tex") != lm:
				bad.append("%s: lightmap_tex not bound" % nm)
			var energy = mat.get_shader_parameter("lightmap_energy")
			if energy == null or float(energy) <= 0.0:
				bad.append("%s: lightmap disabled" % nm)
	check(names.size() >= 10 and bad.is_empty(), "every lightmapped surface has UV2 in [0,1] and a material sampling the baked lightmap on UV2",
			("%d meshes / %d surfaces" % [names.size(), n_surf]) if bad.is_empty() else "; ".join(bad.slice(0, 8)))
	check(total_area > 0.25 and total_area < 1.02, "lightmap UV islands fit the atlas without gross overlap (total UV2 area)",
			"%.3f of the 0..1 square" % total_area)
	lit_means.sort()
	check(dark.is_empty(), "the bake has light where every lightmapped surface samples it",
			("; ".join(dark.slice(0, 6))) if dark.size() else "median mesh mean %.3f" % (lit_means[lit_means.size() / 2] if lit_means.size() else 0.0))
	# the only meshes without the lightmap are the emissive / glass ones
	var unshaded: Array = lv.data.get("unshaded", {}).keys()
	var others: Array = []
	var extra: Array = []
	for mi in lv._meshes(park):
		var nm := String(mi.name)
		if nm in names:
			continue
		others.append(nm)
		var ok := nm.begins_with("Window_") or unshaded.any(func(k): return nm.ends_with("_" + k))
		var mat = mi.mesh.surface_get_material(0) if mi.mesh and mi.mesh.get_surface_count() else null
		if mi.material_override:
			mat = mi.material_override
		if not ok and not (mat is ShaderMaterial and mat.shader == lv.WINDOW_SHADER):
			extra.append(nm)
	check(extra.is_empty(), "every other mesh is an emissive or glass one (lamps, skylights, glazing)",
			", ".join(others) if extra.is_empty() else "unlightmapped: " + ", ".join(extra))


# ------------------------------------------------------------------ grind lines

func line_coverage(r, meshes_f: Array, n := 20) -> float:
	## Fraction of samples along the line with a triangle right at it (a short vertical ray
	## through the line, nudged off the tube's crease, hits a triangle within 6 cm).
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for p in r.points:
		lo = lo.min(p)
		hi = hi.max(p)
	var box := AABB(lo, hi - lo).grow(0.3)
	var cand: Array = []
	for f in meshes_f:
		for i in range(0, f.size(), 3):
			var tb := AABB(f[i], Vector3.ZERO).expand(f[i + 1]).expand(f[i + 2])
			if tb.intersects(box):
				cand.append([f[i], f[i + 1], f[i + 2]])
	var hits := 0
	for k in n:
		var s: float = r.length * (0.02 + 0.96 * k / float(n - 1))
		var p: Vector3 = r.point_at(s)
		var side: Vector3 = r.dir_at(s).cross(Vector3.UP).normalized() * 0.004
		var a := p + side + Vector3.UP * 0.2
		for t in cand:
			var h = Geometry3D.ray_intersects_triangle(a, Vector3.DOWN, t[0], t[1], t[2])
			if h != null and absf(h.y - p.y) < 0.06:
				hits += 1
				break
	return hits / float(n)


func grind_lines() -> void:
	var by_tag := {}
	for r in lv.rails:
		by_tag[r.tag] = by_tag.get(r.tag, 0) + 1
	check(by_tag.get("rail", 0) >= 1 and by_tag.get("ledge", 0) >= 1 and by_tag.get("coping", 0) >= 1,
			"grind lines for rails, ledges and copings", str(by_tag))
	var fs: Array = []
	for mi in lv._meshes(park):
		if mi.mesh and not String(mi.name).begins_with("Window_"):
			fs.append(tris(mi))
	var weak: Array = []
	var cov_sum := 0.0
	for r in lv.rails:
		var cov := line_coverage(r, fs)
		cov_sum += cov
		if cov < 0.95:
			weak.append("%s %.0f%%" % [r.name, cov * 100.0])
	check(weak.is_empty(), "every grind line runs along real geometry (a mesh under 20 samples each)",
			"; ".join(weak) if weak.size() else "%d lines, mean coverage %.0f%%" % [lv.rails.size(), cov_sum / maxi(1, lv.rails.size()) * 100.0])


func snap_on(r, frac: float, speed := 6.0) -> Dictionary:
	## Put the skater 30 cm above the grind line, airborne and moving along it, press grind.
	top_up()
	var s: float = r.length * frac
	var p: Vector3 = r.point_at(s)
	var d: Vector3 = r.dir_at(s)
	sk.spawn(p + Vector3.UP * 0.3, d, speed)
	sk.state = sk.AIR
	sk.air_time = 0.0
	sk.vel = d * speed + Vector3(0, -0.5, 0)
	key(KEY_L, true)
	var got := false
	var n := 0
	for i in 12:
		await physics_frame
		n += 1
		if sk.state == sk.GRIND:
			got = true
			break
	var rail_at_snap = sk.grind_rail
	if got:
		await physics(2)
	var res := {"got": got and sk.state == sk.GRIND, "rail": rail_at_snap, "frames": n, "state": sk.state,
			"trick": String(sk.grind_info.get("name", "")) if got else "", "pos": sk.global_position}
	key(KEY_L, false)
	return res


func grind_snaps() -> void:
	var fails: Array = []
	var tricks := {}
	for r in lv.rails:
		var res := await snap_on(r, 0.3 if r.length > 1.5 else 0.5)
		var same: bool = res["got"] and res["rail"] == r
		var dist: float = r.closest(res["pos"])["dist"] if res["got"] else -1.0
		if same and dist < 0.02:
			tricks[res["trick"]] = tricks.get(res["trick"], 0) + 1
		else:
			fails.append("%s: state=%d rail=%s" % [r.name, res["state"], res["rail"].name if res["rail"] else "none"])
		await park_skater()
	check(fails.is_empty(), "every grind line is grindable: the grind button snaps the real skater into GRIND on each of the %d" % lv.rails.size(),
			str(tricks) if fails.is_empty() else "; ".join(fails))


# ------------------------------------------------------------------ rides (real skater)

func ride(pos: Vector3, dir: Vector3, speed: float, n: int, hold: Array = []) -> Dictionary:
	top_up()
	var b0 := bails.size()
	sk.spawn(pos, dir, speed)
	var rec := {"max_y": -99.0, "min_y": 99.0, "air": false, "air_max_y": -99.0, "wood_y": -99.0, "steep": 0.0,
			"lo": pos, "hi": pos, "surfaces": {}, "rev": false, "far": 0.0, "end": pos, "path": []}
	for i in n:
		for k in hold:
			key(k, sk.state == sk.GROUND and sk.up.y < 0.97)
		await physics_frame
		var p: Vector3 = sk.global_position
		rec["max_y"] = maxf(rec["max_y"], p.y)
		rec["min_y"] = minf(rec["min_y"], p.y)
		rec["lo"] = (rec["lo"] as Vector3).min(p)
		rec["hi"] = (rec["hi"] as Vector3).max(p)
		rec["far"] = maxf(rec["far"], (p - pos).dot(dir))
		if sk.state == sk.AIR:
			rec["air"] = true
			rec["air_max_y"] = maxf(rec["air_max_y"], p.y)
		if sk.state == sk.GROUND:
			rec["surfaces"][sk.surface] = true
			rec["steep"] = maxf(rec["steep"], rad_to_deg(sk.up.angle_to(Vector3.UP)))
			if sk.surface == "wood":
				rec["wood_y"] = maxf(rec["wood_y"], p.y)
		if sk.vel.dot(dir) < -0.5:
			rec["rev"] = true
		if i % 30 == 0:
			rec["path"].append(p.snapped(Vector3.ONE * 0.1))
	for k in hold:
		key(k, false)
	rec["end"] = sk.global_position
	rec["end_state"] = sk.state
	rec["bails"] = bails.slice(b0)
	return rec


func rides() -> void:
	## "rides": [{what, at, dir, speed, frames, hold?, expect: {...}}]; every expectation
	## key is optional: air, rev, no_bail (default true), air_above (m, Blender z), top_above,
	## wood_above, below (lowest point under), end_below / end_above, end_in (Blender box),
	## far (m travelled along dir), steep (deg on the ground), surface.
	var keymap := {"up": KEY_W, "down": KEY_S, "grab": KEY_K}
	for rd in spec.get("rides", []):
		var e: Dictionary = rd.get("expect", {})
		var dir := b2g(rd["dir"]).normalized()
		var hold: Array = rd.get("hold", []).map(func(k): return keymap[k])
		var r := await ride(b2g(rd["at"]) + Vector3.UP * 0.02, dir, float(rd["speed"]), int(rd.get("frames", 240)), hold)
		var why: Array = []
		if bool(e.get("no_bail", true)) and r["bails"].size() > 0:
			why.append("bailed " + str(r["bails"]))
		if e.has("air") and bool(e["air"]) != r["air"]:
			why.append("air %s" % str(r["air"]))
		if e.has("rev") and bool(e["rev"]) != r["rev"]:
			why.append("never came back" if e["rev"] else "came back")
		if e.has("air_above") and r["air_max_y"] < float(e["air_above"]):
			why.append("air peak %s m" % fmt(r["air_max_y"]))
		if e.has("top_above") and r["max_y"] < float(e["top_above"]):
			why.append("top %s m" % fmt(r["max_y"]))
		if e.has("wood_above") and r["wood_y"] < float(e["wood_above"]):
			why.append("highest on wood %s m" % fmt(r["wood_y"]))
		if e.has("below") and r["min_y"] > float(e["below"]):
			why.append("lowest %s m" % fmt(r["min_y"]))
		if e.has("end_below") and r["end"].y > float(e["end_below"]):
			why.append("ended at %s m" % fmt(r["end"].y))
		if e.has("end_above") and r["end"].y < float(e["end_above"]):
			why.append("ended at %s m" % fmt(r["end"].y))
		if e.has("far") and r["far"] < float(e["far"]):
			why.append("went %s m" % fmt(r["far"]))
		if e.has("steep") and r["steep"] < float(e["steep"]):
			why.append("steepest %s deg" % fmt(r["steep"]))
		if e.has("surface") and not r["surfaces"].has(String(e["surface"])):
			why.append("surfaces %s" % str(r["surfaces"].keys()))
		if e.has("end_in"):
			var bx: Array = e["end_in"]
			var a := b2g(bx[0])
			var b := b2g(bx[1])
			if not AABB(a.min(b), (b - a).abs()).grow(0.01).has_point(r["end"]):
				why.append("ended at %s" % str(r["end"].snapped(Vector3.ONE * 0.1)))
		var summary := "air peak %s m, top %s m, low %s m, steepest %s deg, went %s m, end %s, surfaces %s" % [
				fmt(r["air_max_y"]) if r["air"] else "-", fmt(r["max_y"]), fmt(r["min_y"]), fmt(r["steep"]), fmt(r["far"]),
				str(r["end"].snapped(Vector3.ONE * 0.1)), str(r["surfaces"].keys())]
		check(why.is_empty(), "ride: " + String(rd["what"]), summary if why.is_empty() else "; ".join(why) + " | " + summary)
		await park_skater()


func _passes(c: Vector3, axis: Vector3, speed: float, seconds: float, pump: bool) -> Dictionary:
	## Ride back and forth across a transition pair from its flat bottom; with pump, Up is
	## held only on the steep part of a wall (no pushing on the flat). Records the peak of
	## each wall pass and the speed at each bottom crossing.
	top_up()
	sk.spawn(c + Vector3.UP * 0.02, axis, speed)
	await physics(1)
	var peaks: Array = []
	var bottoms: Array = []
	var cur := -99.0
	var last_side := 0.0
	var b0 := bails.size()
	for i in int(seconds * 60.0):
		key(KEY_W, pump and sk.state == sk.GROUND and sk.up.y < 0.8)
		await physics_frame
		var x: float = (sk.global_position - c).dot(axis)
		cur = maxf(cur, sk.global_position.y)
		if absf(x) > 1.0:
			last_side = signf(x)
		if last_side != 0.0 and absf(x) < 0.25 and cur > c.y + 0.3:
			peaks.append(snappedf(cur - c.y, 0.01))
			bottoms.append(snappedf(sk.vel.length(), 0.01))
			cur = -99.0
			last_side = 0.0
	key(KEY_W, false)
	return {"peaks": peaks, "bottoms": bottoms, "bails": bails.size() - b0}


func pumping() -> void:
	var pm: Dictionary = spec.get("pump", {})
	if pm.is_empty():
		return
	var c := b2g(pm["at"])
	var axis := b2g(pm["axis"]).normalized()
	var p := await _passes(c, axis, float(pm["speed"]), float(pm.get("seconds", 20.0)), true)
	await park_skater()
	var q := await _passes(c, axis, float(pm["speed"]), float(pm.get("seconds", 20.0)), false)
	await park_skater()
	var pk: Array = p["peaks"]
	var nk: Array = q["peaks"]
	var grow: bool = pk.size() >= 5 and p["bails"] == 0
	for i in range(1, mini(5, pk.size())):
		grow = grow and pk[i] > pk[i - 1] - 0.02
	check(grow and pk.size() >= 5 and pk[4] > pk[0] + 0.3, "pump: pumping the %s raises the peak pass after pass" % String(pm["what"]),
			"peaks above the bottom %s m, bottom speeds %s m/s" % [str(pk.slice(0, 8)), str(p["bottoms"].slice(0, 8))])
	var lose: bool = nk.size() >= 3 and q["bails"] == 0 and nk[nk.size() - 1] < nk[0]
	check(lose, "pump: without pumping the same ride loses height (friction, no input)", "peaks %s m" % str(nk.slice(0, 8)))
	check(pk.size() >= 4 and nk.size() >= 4 and pk[3] > nk[3] + 0.2, "pump: pumping beats not pumping by the 4th pass",
			"4th pass %s m vs %s m" % [str(pk[3]) if pk.size() >= 4 else "-", str(nk[3]) if nk.size() >= 4 else "-"])


# ------------------------------------------------------------------ breakables + hidden areas

func item_approach(it: Dictionary) -> Dictionary:
	## A straight run-up at the breakable over open, level ground: tries each horizontal
	## direction (thin side first for impact ones) and keeps the first whose 3.5 m run-up is
	## clear and on the same floor as the breakable's foot.
	var d: Dictionary = it["def"]
	var c := v3(d["center"])
	var sz: Vector3 = v3(d["size"]) if d.has("size") else Vector3.ONE
	var foot := down(c + Vector3.UP * 0.5, 6.0)
	var fy: float = foot["position"].y if not foot.is_empty() else c.y - sz.y * 0.5
	if it["kind"] == "impact":
		fy = c.y - sz.y * 0.5
	var dirs: Array = [Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD]
	if it["kind"] == "impact" and sz.z < sz.x:
		dirs = [Vector3.BACK, Vector3.FORWARD, Vector3.RIGHT, Vector3.LEFT]
	var ex: Array = []
	if it["body"]:
		ex.append(it["body"].get_rid())
	for dv in dirs:
		var start: Vector3 = Vector3(c.x, fy, c.z) - dv * 3.5
		var g := down(start + Vector3.UP * 1.0, 3.0)
		if g.is_empty() or absf(g["position"].y - fy) > 0.08 or g["normal"].y < 0.98:
			continue
		var clear := true
		for hgt in [0.4, 1.2]:
			if not ray(start + Vector3.UP * hgt, Vector3(c.x, fy + hgt, c.z) + dv * 1.5, 1, ex).is_empty():
				clear = false
		if clear:
			return {"start": Vector3(start.x, g["position"].y + 0.02, start.z), "dir": dv}
	return {}


func breakables() -> void:
	var groups := {}
	for it in lv.items:
		groups[it["group"]] = groups.get(it["group"], 0) + 1
	check(lv.items.size() >= 1, "the level has breakables", str(groups))
	var fails: Array = []
	var done: Array = []
	for it in lv.items:
		var ap := item_approach(it)
		if ap.is_empty():
			fails.append("%s: no clear run-up" % it["id"])
			continue
		var b0 := bails.size()
		top_up()
		sk.spawn(ap["start"], ap["dir"], 6.5 if it["kind"] == "impact" else 5.0)
		var t := 0
		for i in 100:
			await physics_frame
			t += 1
			if it["broken"]:
				break
		if not it["broken"]:
			fails.append("%s (%s): not broken, skater at %s" % [it["id"], it["kind"], str(sk.global_position.snapped(Vector3.ONE * 0.1))])
		else:
			done.append("%s %.2fs" % [it["id"], t / 60.0])
		if it["kind"] == "impact" and it["broken"]:
			await physics(2)
			var c := v3(it["def"]["center"])
			var dv: Vector3 = ap["dir"]
			var h := ray(c - dv * 1.0, c + dv * 1.0)
			if not h.is_empty() and h["collider"].has_meta("item"):
				fails.append("%s: still blocks after breaking" % it["id"])
		await park_skater()
	check(fails.is_empty(), "every breakable breaks when the real skater rolls into it", ", ".join(done) if fails.is_empty() else "; ".join(fails))
	var groups_done := {}
	for g in groups:
		groups_done[g] = lv.items_broken(g)
	lv.reset_run()
	await physics(3)
	var restored: bool = lv.items.all(func(it): return not it["broken"] and (it["kind"] != "impact" or is_instance_valid(it["body"])))
	check(restored, "reset_run stands every breakable back up (and its collision)", "broken before reset %s" % str(groups_done))


func hidden_areas() -> void:
	var has: Array = lv.data.get("hidden_areas", [])
	check(has.size() >= 1, "the level has a hidden area", ", ".join(has.map(func(h): return String(h["name"]))))
	var tape_in := false
	for ha in has:
		var box := AABB(v3(ha["min"]), v3(ha["max"]) - v3(ha["min"]))
		if lv.data.has("tape") and box.grow(0.05).has_point(v3(lv.data["tape"])):
			tape_in = true
		if not ha.has("door"):
			check(false, "%s: has a doorway in its data" % ha["name"])
			continue
		var dc := v3(ha["door"]["center"])
		var inward := v3(ha["door"]["inward"])
		var foot := dc.y - float(ha["door"]["height"]) * 0.5
		var a := Vector3(dc.x, foot + 1.0, dc.z) - inward * 1.2
		var b := Vector3(dc.x, foot + 1.0, dc.z) + inward * 1.2
		var h := ray(a, b)
		var blocker := String(h["collider"].get_meta("item", "")) if not h.is_empty() and h["collider"].has_meta("item") else ""
		check(blocker != "", "%s is closed off while its breakable stands (the doorway ray hits it)" % ha["name"],
				"blocked by '%s'" % blocker if blocker != "" else "hit %s" % (h["collider"].name if not h.is_empty() else "nothing"))
		# roll in through the doorway
		var b0 := bails.size()
		top_up()
		var start := Vector3(dc.x, foot + 0.02, dc.z) - inward * 4.0
		sk.spawn(start, inward, 7.0)
		var inside := false
		var t_in := 0.0
		for i in 180:
			await physics_frame
			if box.has_point(sk.global_position + Vector3.UP * 0.1):
				inside = true
				t_in = i / 60.0
				break
		var got: bool = blocker == "" or lv.items.any(func(it): return it["id"] == blocker and it["broken"])
		check(inside and got and bails.size() == b0, "%s is reachable: the real skater smashes the %s and rides in" % [ha["name"], blocker],
				"inside after %.2f s, bails %s" % [t_in, str(bails.slice(b0))])
		await physics(2)
		var h2 := ray(a, b)
		check(h2.is_empty() or not h2["collider"].has_meta("item"), "%s: the doorway is open once the breakable is down" % ha["name"])
		await park_skater()
		lv.reset_run()
		await physics(3)
	check(tape_in, "the secret tape is in a hidden area")


# ------------------------------------------------------------------ pickups

func pickups_static() -> void:
	var pts: Array = []
	for L in lv.data.get("letters", []):
		pts.append([String(L["letter"]), v3(L["pos"])])
	if lv.data.has("tape"):
		pts.append(["tape", v3(lv.data["tape"])])
	var bad: Array = []
	var info: Array = []
	for pk in pts:
		var p: Vector3 = pk[1]
		var q := PhysicsShapeQueryParameters3D.new()
		var sh := SphereShape3D.new()
		sh.radius = 0.3
		q.shape = sh
		q.transform = Transform3D(Basis(), p)
		q.collision_mask = 1
		var hits := space.intersect_shape(q, 4)
		var g := down(p, 12.0)
		var above: float = p.y - (g["position"].y if not g.is_empty() else -99.0)
		if hits.size() > 0:
			bad.append("%s inside %s" % [pk[0], hits[0]["collider"].name])
		elif g.is_empty() or above > 7.0:
			bad.append("%s %.1f m above anything" % [pk[0], above])
		else:
			info.append("%s %.1f m up" % [pk[0], above])
	check(pts.size() == 6 and bad.is_empty(), "S-K-A-T-E and the tape each sit in open space above solid ground",
			", ".join(info) if bad.is_empty() else "; ".join(bad))


func autopilot_run() -> void:
	## Every pickup is reachable and every goal completable in one two-minute run: the
	## level's own autopilot route plays through the normal input interface.
	release_all()
	var got := {}
	var t0 := Engine.get_physics_frames()
	var on_letter := func(l): got[l] = (Engine.get_physics_frames() - t0) / 60.0
	var on_tape := func(): got["tape"] = (Engine.get_physics_frames() - t0) / 60.0
	lv.letter_collected.connect(on_letter)
	lv.tape_collected.connect(on_tape)
	main.autopilot_mode = "run"
	main.restart()
	var ap: Node = load("res://scripts/game/autopilot.gd").new()
	ap.name = "Autopilot"
	main.add_child(ap)
	ap.setup(main)
	sk.autopilot = ap
	main.level.item_broken.connect(func(iid, grp, n, tot): ap.note("broke %s (%s %d/%d)" % [iid, grp, n, tot]))
	main.level.gap_hit.connect(func(_g, nm, pts): ap.note("GAP %s (+%d)" % [nm, pts]))
	sk.bailed.connect(func(r): ap.note("BAIL (%s) at %s" % [r, str(sk.global_position.snapped(Vector3.ONE * 0.1))]))
	var n := 0
	while main.running and n < 60 * 135:
		await physics_frame
		n += 1
	var names: Array = lv.data.get("letters", []).map(func(L): return String(L["letter"]))
	var all_letters := names.all(func(l): return got.has(l))
	check(all_letters and got.has("tape"), "every pickup is reachable: the autopilot route collects S-K-A-T-E and the tape",
			", ".join(got.keys().map(func(k): return "%s %.1fs" % [k, got[k]])))
	var goal_s: Array = main.goals.map(func(g): return "%s %s" % [g["id"], "done" if g["done"] else "NOT done"])
	check(main.goals.all(func(g): return g["done"]), "the autopilot two-minute run completes every goal of the level",
			"%s; score %d in %.1f s" % [", ".join(goal_s), main.score.total, n / 60.0])
	var f := FileAccess.open("res://tests/results/level_%s_route.txt" % id, FileAccess.WRITE)
	f.store_string("\n".join(ap.log_lines) + "\n[run] finished score=%d goals=%s\n" % [main.score.total,
			str(main.goals.map(func(g): return [g["id"], g["done"]]))])
	f.close()
	lv.letter_collected.disconnect(on_letter)
	lv.tape_collected.disconnect(on_tape)
	sk.autopilot = null
	ap.queue_free()
	main.autopilot_mode = ""
