extends SceneTree
## Headless evidence for the Warehouse park (THPS1 Warehouse homage), on the real main
## scene and the real level / skater code:
##  * every specified feature exists, measured at real-world scale from collision raycasts
##    and mesh geometry (not just the JSON constants): hall, start deck + steep drop-in,
##    halfpipe, quarterpipes, kickers, funbox, rails / ledges, wall pipe, rafters, high
##    catwalks, steel beams (trusses + columns), crates, graffiti, skylights, windows,
##    coping on the ramps and the hidden room behind the breakable wall
##  * lightmap UVs: every lightmapped surface has UV2 inside [0,1] and its material samples
##    the baked lightmap on UV2
##  * usable ramps: the transitions are wood collision with real curvature, and the real
##    skater rides them (drop-in, halfpipe both walls, quarters, kicker, funbox)
##  * grind surfaces: every grind line sits on real geometry and the real skater snaps into
##    GRIND on each one with the grind button; the rafter is reachable off the catwalk kicker
##  * breakables: each of the 5 windows breaks from a vert air in front of it (gameplay
##    path: main -> level.check_windows), a wall-pipe grind breaks all 5, reset_run restores
##    them; the boarded wall blocks the secret room until the skater rolls into it, then
##    the doorway is clear, the skater gets into the room and collects the tape
##   godot --headless --path . --fixed-fps 60 -s tests/test_park.gd   -> tests/results/park.txt

var main: Node
var lv: Node
var park: Node3D
var sk: Node
var space: PhysicsDirectSpaceState3D
var out: PackedStringArray = []
var passed := 0
var failed := 0
var bails: Array = []
var broken_log: Array = []
var wall_signal := 0
var tape_signal := 0


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


func ray(a: Vector3, b: Vector3, mask := 1) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(a, b, mask)
	return space.intersect_ray(q)


func down(x: float, z: float, from_y := 20.0) -> Dictionary:
	return ray(Vector3(x, from_y, z), Vector3(x, -1.0, z))


func surf(hit: Dictionary) -> String:
	return lv.surface_of(hit["collider"]) if not hit.is_empty() else "none"


func slope_deg(hit: Dictionary) -> float:
	return rad_to_deg(Vector3.UP.angle_to(hit["normal"])) if not hit.is_empty() else -1.0


func mesh(nm: String) -> MeshInstance3D:
	return park.find_child(nm, true, false) as MeshInstance3D


func glass_broken(node) -> bool:
	## A broken window keeps its glass node: the shader knocks jagged holes in the panes.
	var m = node.material_override if node else null
	return m is ShaderMaterial and m.get_shader_parameter("broken") != null and float(m.get_shader_parameter("broken")) > 0.5


func waabb(mi: MeshInstance3D) -> AABB:
	return mi.global_transform * mi.get_aabb()


func tris(mi: MeshInstance3D) -> PackedVector3Array:
	var f: PackedVector3Array = mi.mesh.get_faces()
	var xf := mi.global_transform
	for i in f.size():
		f[i] = xf * f[i]
	return f


## Centres of the rectangles a triangulated mesh is made of: both halves of a rectangle
## share the diagonal, whose midpoint is the rectangle's centre. pred filters triangles.
func rect_centres(f: PackedVector3Array, pred: Callable) -> Array:
	var cs: Array = []
	for i in range(0, f.size(), 3):
		var a := f[i]
		var b := f[i + 1]
		var c := f[i + 2]
		var n := (b - a).cross(c - a)
		if n.length() < 1e-9:
			continue
		n = n.normalized()
		if not pred.call(a, b, c, n):
			continue
		var e := [[a, b], [b, c], [c, a]]
		var best: Array = e[0]
		for x in e:
			if (x[1] - x[0]).length() > (best[1] - best[0]).length():
				best = x
		var m: Vector3 = (best[0] + best[1]) * 0.5
		var dup := false
		for o in cs:
			if o["c"].distance_to(m) < 0.05:
				dup = true
				o["n"] = n
				break
		if not dup:
			cs.append({"c": m, "n": n, "diag": (best[1] - best[0]).length(), "tri": [a, b, c]})
	return cs


func in_tri_xz(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> bool:
	var d1 := (p.x - b.x) * (a.z - b.z) - (a.x - b.x) * (p.z - b.z)
	var d2 := (p.x - c.x) * (b.z - c.z) - (b.x - c.x) * (p.z - c.z)
	var d3 := (p.x - a.x) * (c.z - a.z) - (c.x - a.x) * (p.z - a.z)
	var neg := d1 < 0 or d2 < 0 or d3 < 0
	var pos := d1 > 0 or d2 > 0 or d3 > 0
	return not (neg and pos)


## Down-ray samples along a straight line on the ground plan.
func profile(a: Vector2, b: Vector2, n: int, from_y := 20.0) -> Array:
	var res: Array = []
	for i in n + 1:
		var p := a.lerp(b, float(i) / n)
		var h := down(p.x, p.y, from_y)
		res.append({"x": p.x, "z": p.y, "hit": h, "y": (h["position"].y if not h.is_empty() else -99.0),
				"s": surf(h), "ang": slope_deg(h), "n": (h["normal"] if not h.is_empty() else Vector3.ZERO)})
	return res


## Transition radius estimated from a sample on the curve: height = R (1 - cos(slope)).
func radius_est(samples: Array, floor_y := 0.0) -> float:
	var ests: Array = []
	for s in samples:
		if s["s"] == "wood" and s["ang"] > 12.0 and s["ang"] < 70.0:
			ests.append((s["y"] - floor_y) / (1.0 - cos(deg_to_rad(s["ang"]))))
	if ests.is_empty():
		return -1.0
	ests.sort()
	return ests[ests.size() / 2]


func top_up() -> void:
	main.time_left = main.RUN_TIME


func goal_done(id: String) -> bool:
	for g in main.goals:
		if g["id"] == id:
			return g["done"]
	return false


func v3(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])


func fmt(v: float) -> String:
	return "%.2f" % v


# ------------------------------------------------------------------ main

func _run() -> void:
	await frames(5)
	lv = main.level
	park = lv.park
	sk = main.skater
	space = lv.get_world_3d().direct_space_state
	sk.bailed.connect(func(r): bails.append(r))
	lv.window_broken.connect(func(i, n): broken_log.append([i, n]))
	lv.wall_broken.connect(func(): wall_signal += 1)
	lv.tape_collected.connect(func(): tape_signal += 1)
	await physics(3)
	hall_scale()
	entry_room()
	halfpipe()
	quarterpipes()
	kickers_funbox()
	catwalks_rafters()
	steel_crates_graffiti_skylights()
	windows_static()
	secret_room_static()
	lightmaps()
	grind_lines()
	# start the run through the real start screen
	await frames(30)
	await tap_key(KEY_ENTER)
	await frames(3)
	check(main.running and not paused, "run started from the start screen (Enter)")
	await rides()
	await grind_snaps()
	await rafter_from_catwalk()
	await windows_gameplay()
	await wall_and_room_gameplay()
	var report := "Pro Skater park (Warehouse) tests  %s\n%s\n%d passed, %d failed\n" % [
			Time.get_datetime_string_from_system(), "\n".join(out), passed, failed]
	print(report)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/results"))
	var f := FileAccess.open("res://tests/results/park.txt", FileAccess.WRITE)
	f.store_string(report)
	f.close()
	quit(1 if failed > 0 else 0)


# ------------------------------------------------------------------ scale

func hall_scale() -> void:
	var c := Vector3(0, 8, -17)
	var e := ray(c, c + Vector3(40, 0, 0))
	var w := ray(c, c - Vector3(40, 0, 0))
	var n := ray(c, c - Vector3(0, 0, 60))
	var s := ray(c, c + Vector3(0, 0, 60))
	var ok := not (e.is_empty() or w.is_empty() or n.is_empty() or s.is_empty())
	var width: float = (e["position"].x - w["position"].x) if ok else -1.0
	var length: float = (s["position"].z - n["position"].z) if ok else -1.0
	check(ok and absf(width - 40.0) < 0.5 and absf(length - 66.0) < 0.5 and surf(e) == "wall" and surf(n) == "wall",
			"main hall footprint is ~40 x 66 m (wall collision raycasts from the centre)", "%s x %s m" % [fmt(width), fmt(length)])
	# wall height: highest horizontal ray that still hits the east wall collision
	var top := -1.0
	var y := 9.0
	while y < 14.0:
		var h := ray(Vector3(0, y, -17), Vector3(30, y, -17))
		if not h.is_empty() and h["position"].x > 19.5:
			top = y
		y += 0.05
	var roof := mesh("Park_roof")
	var corr := mesh("Park_corrugated")
	var roof_top := waabb(roof).end.y if roof else -1.0
	check(absf(top - 11.5) < 0.3 and absf(roof_top - 11.5) < 0.3, "hall is ~11.5 m to the roof (wall collision top and roof mesh)",
			"walls %s m, roof %s m" % [fmt(top), fmt(roof_top)])
	var wa := waabb(corr) if corr else AABB()
	check(corr != null and absf(wa.size.x - 40.0) < 0.3 and absf(wa.size.z - 66.0) < 0.3 and absf(wa.size.y - 11.5) < 0.3,
			"brick / corrugated wall meshes span 40 x 66 x 11.5 m", str(wa.size.snapped(Vector3.ONE * 0.01)))
	var fl := down(0.0, -28.0)
	check(not fl.is_empty() and absf(fl["position"].y) < 0.02 and surf(fl) == "concrete", "concrete floor at y = 0",
			"%s %s" % [fmt(fl["position"].y) if not fl.is_empty() else "none", surf(fl)])


func entry_room() -> void:
	var sp: Vector3 = lv.spawn_pos
	var d := down(sp.x, sp.z)
	check(not d.is_empty() and absf(d["position"].y - 5.0) < 0.15 and surf(d) == "wood" and absf(sp.y - d["position"].y) < 0.1,
			"start deck in the entry room is ~5 m up (spawn on a wooden deck)", "deck %s m, %s" % [fmt(d["position"].y) if not d.is_empty() else "none", surf(d)])
	# deck extent: flat 5 m surface from the lip (z=7) back to the south wall
	var flat := 0
	for s in profile(Vector2(0, 7.1), Vector2(0, 15.9), 20):
		if absf(s["y"] - 5.0) < 0.05 and s["ang"] < 2.0:
			flat += 1
	check(flat == 21, "start deck is ~9 m deep (flat at 5 m from the lip to the south wall)", "%d/21 samples" % flat)
	# the drop-in: the ramp below the lip
	var prof := profile(Vector2(0, 6.98), Vector2(0, -1.5), 60)
	var lip: Dictionary = prof[0]
	var all_wood := true
	var mono := true
	var prev := 99.0
	var bottom_z := 99.0
	for s in prof:
		if s["y"] > 0.02:
			all_wood = all_wood and s["s"] == "wood"
			mono = mono and s["y"] <= prev + 0.01
			prev = s["y"]
		elif bottom_z == 99.0:
			bottom_z = s["z"]
	var r := radius_est(prof)
	check(all_wood and mono and lip["ang"] > 55.0 and lip["y"] > 4.7 and lip["n"].z < 0.0,
			"steep drop-in off the start deck: wooden roll-in, steep at the lip, falls 5 m to the floor",
			"lip %s deg at %s m, bottom at z=%s, radius %s m" % [fmt(lip["ang"]), fmt(lip["y"]), fmt(bottom_z), fmt(r)])
	check(r > 7.5 and r < 10.5, "drop-in transition radius ~9 m (measured from slope vs height)", fmt(r))
	# the big ramp's width: wooden slope across the entry room at mid-height
	var xmin := 99.0
	var xmax := -99.0
	for s in profile(Vector2(-10.0, 4.0), Vector2(10.0, 4.0), 80):
		if s["s"] == "wood" and s["y"] > 0.5 and s["n"].z < -0.1:
			xmin = minf(xmin, s["x"])
			xmax = maxf(xmax, s["x"])
	check(xmax - xmin > 15.0, "the big entry ramp (drop-in) is ~16 m wide", "%s m (x %s..%s)" % [fmt(xmax - xmin), fmt(xmin), fmt(xmax)])


func halfpipe() -> void:
	var hp: Dictionary = lv.data["halfpipe"]
	var cz: float = hp["center"][2]
	var prof := profile(Vector2(-7.0, cz), Vector2(7.0, cz), 112)
	var west: Array = []
	var east: Array = []
	var flat_ok := true
	for s in prof:
		if absf(s["x"]) < 2.4:
			flat_ok = flat_ok and s["y"] < 0.05 and s["s"] == "wood"
		elif s["x"] < -2.9 and s["x"] > -5.6:
			west.append(s)
		elif s["x"] > 2.9 and s["x"] < 5.6:
			east.append(s)
	var w_ok := west.size() > 0
	for s in west:
		w_ok = w_ok and s["s"] == "wood" and s["n"].x > 0.05
	var e_ok := east.size() > 0
	for s in east:
		e_ok = e_ok and s["s"] == "wood" and s["n"].x < -0.05
	check(flat_ok, "halfpipe has a wooden flat bottom (~5 m)")
	check(w_ok and e_ok, "halfpipe has two opposing wooden transitions (west faces east, east faces west)",
			"%d west / %d east samples" % [west.size(), east.size()])
	var dw := down(-6.5, cz)
	var de := down(6.5, cz)
	var hw: float = dw["position"].y if not dw.is_empty() else -1.0
	var he: float = de["position"].y if not de.is_empty() else -1.0
	check(absf(hw - 3.7) < 0.15 and absf(he - 3.7) < 0.15 and surf(dw) == "wood" and surf(de) == "wood",
			"halfpipe is ~3.7 m high (both decks measured)", "west %s m, east %s m" % [fmt(hw), fmt(he)])
	var rw := radius_est(west)
	var re := radius_est(east)
	check(absf(rw - 3.2) < 0.5 and absf(re - 3.2) < 0.5, "halfpipe transitions ~3.2 m radius", "%s / %s m" % [fmt(rw), fmt(re)])
	# vert: a horizontal ray just below the coping hits a vertical wooden wall on both sides
	var vr := ray(Vector3(0, 3.45, cz), Vector3(9, 3.45, cz))
	var vl := ray(Vector3(0, 3.45, cz), Vector3(-9, 3.45, cz))
	check(not vr.is_empty() and not vl.is_empty() and absf(vr["normal"].x + 1.0) < 0.05 and absf(vl["normal"].x - 1.0) < 0.05
			and surf(vr) == "wood" and surf(vl) == "wood", "halfpipe has vert at the top of both walls",
			"walls %s apart" % (fmt(vr["position"].x - vl["position"].x) if not vr.is_empty() and not vl.is_empty() else "?"))
	var along := profile(Vector2(4.0, cz + 7.0), Vector2(4.0, cz - 7.0), 56)
	var zmin := 99.0
	var zmax := -99.0
	for s in along:
		if s["s"] == "wood" and s["y"] > 0.3:
			zmin = minf(zmin, s["z"])
			zmax = maxf(zmax, s["z"])
	check(absf((zmax - zmin) - 12.0) < 0.6, "halfpipe is ~12 m wide", fmt(zmax - zmin))


func quarterpipes() -> void:
	# east wall quarter: the whole length of the east wall, under the windows
	var prof := profile(Vector2(16.0, -20.0), Vector2(19.9, -20.0), 39)
	var tr: Array = []
	for s in prof:
		if s["x"] > 16.5 and s["x"] < 19.1:
			tr.append(s)
	var ok := tr.size() > 0
	for s in tr:
		ok = ok and s["s"] == "wood" and s["n"].x < -0.05
	var deck := down(19.6, -20.0)
	var r := radius_est(tr)
	check(ok and not deck.is_empty() and absf(deck["position"].y - 3.2) < 0.15,
			"east wall quarterpipe: wooden transition facing into the hall, 3.2 m deck",
			"deck %s m, radius %s m" % [fmt(deck["position"].y) if not deck.is_empty() else "none", fmt(r)])
	var along := profile(Vector2(18.0, 16.0), Vector2(18.0, -49.0), 130)
	var zmin := 99.0
	var zmax := -99.0
	for s in along:
		if s["s"] == "wood" and s["y"] > 0.5 and s["n"].x < -0.05:
			zmin = minf(zmin, s["z"])
			zmax = maxf(zmax, s["z"])
	check(zmax - zmin > 55.0, "east quarterpipe runs along the east wall", "%s m long (z %s..%s)" % [fmt(zmax - zmin), fmt(zmin), fmt(zmax)])
	# south-east corner quarter
	var se := profile(Vector2(11.0, 12.0), Vector2(11.0, 15.9), 39)
	var se_tr: Array = []
	for s in se:
		if s["z"] > 12.9 and s["z"] < 15.1:
			se_tr.append(s)
	var se_ok := se_tr.size() > 0
	for s in se_tr:
		se_ok = se_ok and s["s"] == "wood" and s["n"].z < -0.05
	var se_deck := down(11.0, 15.6)
	check(se_ok and not se_deck.is_empty() and absf(se_deck["position"].y - 2.4) < 0.15,
			"south-east corner quarterpipe: wooden transition facing north, 2.4 m deck",
			"deck %s m, radius %s m" % [fmt(se_deck["position"].y) if not se_deck.is_empty() else "none", fmt(radius_est(se_tr))])
	# coping on the ramps: a coping pipe mesh runs the whole lip of every coping line,
	# directly above the ramp's deck
	var cop := mesh("Park_coping")
	var cop_f := tris(cop) if cop else PackedVector3Array()
	for r2 in lv.rails:
		if r2.tag != "coping":
			continue
		var cov := line_coverage(r2, [cop_f])
		var mid: Vector3 = r2.point_at(r2.length * 0.5)
		var dk := ray(mid + Vector3.UP * 0.3, mid - Vector3.UP * 0.3)
		check(cov >= 0.99 and not dk.is_empty() and absf(dk["position"].y - mid.y) < 0.06 and surf(dk) == "wood",
				"coping pipe along the lip of %s (on a wooden deck edge)" % r2.name,
				"%.0f%% of %s m covered, deck at %s" % [cov * 100.0, fmt(r2.length), fmt(dk["position"].y) if not dk.is_empty() else "none"])


func kickers_funbox() -> void:
	var ks := [["street kicker", Vector2(0, -4.8), Vector2(0, -7.0), 0.7, 0.0, "z"],
			["north kicker", Vector2(-9, -28.8), Vector2(-9, -30.8), 0.6, 0.0, "z"],
			["catwalk kicker", Vector2(-18.8, -22.2), Vector2(-18.8, -24.2), 0.45, 5.0, "z"],
			["secret-room kicker", Vector2(-23.3, -37), Vector2(-25.2, -37), 0.6, 0.0, "x"]]
	for k in ks:
		var prof := profile(k[1], k[2], 30, 8.0 if k[4] > 1.0 else 3.0)
		var top := -99.0
		var sloped := 0
		var wood := true
		for s in prof:
			if s["y"] > k[4] + 0.02:
				wood = wood and s["s"] == "wood"
				top = maxf(top, s["y"])
				if s["ang"] > 5.0 and (s["n"].z > 0.02 if k[5] == "z" else s["n"].x > 0.02):
					sloped += 1
		var h: float = top - k[4]
		check(wood and sloped >= 10 and absf(h - k[3]) < 0.1, "%s: wooden launch ramp facing the run-up" % k[0],
				"%s m high, %d sloped samples" % [fmt(h), sloped])
	# funbox: flat 4 x 3 m top at 0.9 m, banks on all four sides, top rail
	var tops := 0
	for s in profile(Vector2(1.0, -14.9), Vector2(1.0, -18.1), 32):
		if absf(s["y"] - 0.9) < 0.03 and s["ang"] < 1.0 and s["s"] == "wood":
			tops += 1
	var topx := 0
	for s in profile(Vector2(-2.1, -16.0), Vector2(2.1, -16.0), 42):
		if absf(s["y"] - 0.9) < 0.03 and s["ang"] < 1.0 and s["s"] == "wood":
			topx += 1
	var banks := {"south": down(1.0, -13.8), "north": down(1.0, -19.2), "west": down(-3.2, -16.5), "east": down(3.2, -16.5)}
	var want := {"south": Vector3(0, 0, 1), "north": Vector3(0, 0, -1), "west": Vector3(-1, 0, 0), "east": Vector3(1, 0, 0)}
	var bank_ok := true
	var angs: Array = []
	for b in banks:
		var h: Dictionary = banks[b]
		bank_ok = bank_ok and not h.is_empty() and surf(h) == "wood" and h["normal"].dot(want[b]) > 0.2
		angs.append(int(slope_deg(h)))
	check(tops >= 28 and topx >= 36 and bank_ok, "funbox: 4 x 3 m wooden top at 0.9 m with banks on all four sides",
			"top samples %d/33 along z, %d/43 along x (rail excluded), banks %s deg" % [tops, topx, str(angs)])


func catwalks_rafters() -> void:
	var cw_w := profile(Vector2(-18.8, 15.5), Vector2(-18.8, -21.5), 37, 9.0)
	var cw_s := profile(Vector2(-8.3, 14.6), Vector2(-17.3, 14.6), 9, 9.0)
	var n_ok := 0
	var ymin := 99.0
	for s in cw_w + cw_s:
		if s["s"] == "metal" and s["y"] >= 4.99:
			n_ok += 1
			ymin = minf(ymin, s["y"])
	check(n_ok == cw_w.size() + cw_s.size() and ymin >= 4.99, "high catwalks (south + west walls) are metal decks >= 5 m up",
			"%d/%d samples, lowest %s m, west run %s m" % [n_ok, cw_w.size() + cw_s.size(), fmt(ymin), fmt(37.0)])
	var hr = rail_named("catwalk_handrail")
	check(hr != null and hr.points[0].y > 5.8 and hr.length > 30.0, "catwalk handrail is a grind line",
			"%s m long at %s m" % [fmt(hr.length), fmt(hr.points[0].y)] if hr else "missing")
	var rafters: Array = []
	for r in lv.rails:
		if r.tag == "rafter":
			rafters.append(r)
	check(rafters.size() >= 1, "rafter grind lines exist (rails tagged 'rafter')", str(rafters.map(func(r): return r.name)))
	for r in rafters:
		var mid: Vector3 = r.point_at(r.length * 0.5)
		var h := ray(mid + Vector3.UP * 1.5, mid - Vector3.UP * 1.5)
		var ok: bool = not h.is_empty() and absf(h["position"].y - mid.y) < 0.05 and surf(h) == "metal"
		check(ok and mid.y > 5.0 and r.length > 10.0, "%s: steel rafter beam up in the roof, solid under the grind line" % r.name,
				"%s m long at %s m, beam top %s" % [fmt(r.length), fmt(mid.y), fmt(h["position"].y) if not h.is_empty() else "none"])
	var rm := mesh("Park_rafter")
	check(rm != null and waabb(rm).size.y > 0.3, "rafter beams are I-beams (Park_rafter mesh)", str(waabb(rm).size.snapped(Vector3.ONE * 0.01)) if rm else "missing")


func steel_crates_graffiti_skylights() -> void:
	# roof trusses: steel I-beam bottom chords at 9.5 m spanning the hall
	var sp := mesh("Park_steel_paint")
	var trusses := {}
	if sp:
		var f := tris(sp)
		for p in f:
			if p.y > 9.1 and p.y < 9.6:
				var k := int(round(p.z))
				if not trusses.has(k):
					trusses[k] = [99.0, -99.0]
				trusses[k][0] = minf(trusses[k][0], p.x)
				trusses[k][1] = maxf(trusses[k][1], p.x)
	var spans := 0
	for k in trusses:
		if trusses[k][1] - trusses[k][0] > 38.0:
			spans += 1
	check(spans >= 6, "steel roof trusses span the 40 m hall", "%d trusses at z %s" % [spans, str(trusses.keys())])
	# steel columns along both long walls
	var cols := 0
	var tries := 0
	for side in [-1.0, 1.0]:
		for i in 8:
			var z := 12.0 - i * 8.0
			if side < 0.0 and z > -39.0 and z < -34.0:
				continue        # no column in the boarded-up doorway to the secret room
			tries += 1
			var h := ray(Vector3(side * 10.0, 8.0, z), Vector3(side * 25.0, 8.0, z))
			if not h.is_empty() and absf(absf(h["position"].x) - 19.65) < 0.1:
				cols += 1
	var between := ray(Vector3(-10.0, 8.0, 8.0), Vector3(-25.0, 8.0, 8.0))
	# the doorway itself is clear down to the breakable boards at x = -20
	var door := ray(Vector3(-10.0, 1.0, -36.0), Vector3(-25.0, 1.0, -36.0))
	var door_ok: bool = not door.is_empty() and door["collider"].has_meta("breakable")
	check(cols == tries and tries == 15 and not between.is_empty() and absf(between["position"].x + 20.0) < 0.05 and door_ok,
			"steel columns stand along both long walls (solid, 30 cm, every 8 m; none in the secret doorway)",
			"%d/%d columns hit; a ray through the doorway meets %s" % [cols, tries, door["collider"].name if not door.is_empty() else "nothing"])
	# crates: count the lids, then check each visible lid is solid collision
	var cr := mesh("Park_crate")
	var lids: Array = []
	if cr:
		lids = rect_centres(tris(cr), func(a, b, c, n): return absf(n.y) > 0.99 and a.y > 0.8)
	var solid := 0
	for L in lids:
		var c: Vector3 = L["c"]
		var h := down(c.x, c.z, c.y + 0.02)
		if not h.is_empty() and absf(h["position"].y - c.y) < 0.05:
			solid += 1
	var cab := waabb(cr) if cr else AABB()
	check(lids.size() >= 16 and solid == lids.size(), "crates: stacks of real-size wooden crates you can land on",
			"%d crate lids (%s..%s m high), %d solid" % [lids.size(), fmt(lids.map(func(l): return l["c"].y).min() if lids.size() else 0.0),
			fmt(cab.end.y), solid])
	# graffiti decals: quads on real walls / ramps, drawn with the decal shader from an atlas
	var gr := mesh("Park_graffiti")
	var decals: Array = []
	if gr:
		decals = rect_centres(tris(gr), func(a, b, c, n): return true)
	var on_surface := 0
	for d in decals:
		var c: Vector3 = d["c"]
		var n: Vector3 = d["n"]
		var h1 := ray(c + n * 0.25, c - n * 0.25)
		var h2 := ray(c - n * 0.25, c + n * 0.25)
		if (not h1.is_empty() and h1["position"].distance_to(c) < 0.06) or (not h2.is_empty() and h2["position"].distance_to(c) < 0.06):
			on_surface += 1
	var gm = gr.mesh.surface_get_material(0) if gr else null
	var tex_ok: bool = gm is ShaderMaterial and gm.get_shader_parameter("albedo_tex") is Texture2D \
			and gm.get_shader_parameter("albedo_tex").get_width() >= 512
	check(decals.size() >= 8 and on_surface == decals.size() and tex_ok, "graffiti decals painted on real park surfaces",
			"%d decals, %d within 6 cm of collision, atlas %s" % [decals.size(), on_surface,
			str(gm.get_shader_parameter("albedo_tex").get_size()) if tex_ok else "missing"])
	var sign := mesh("BreakWall_sign")
	check(sign != null and sign.visible, "graffiti stencil on the boarded-up wall (BreakWall_sign)")
	# skylights: glazing rectangles in openings of the roof
	var sky := mesh("Park_skylight")
	var lights: Array = []
	if sky:
		lights = rect_centres(tris(sky), func(a, b, c, n): return absf(n.y) > 0.99)
	var roof_f := tris(mesh("Park_roof"))
	var open := 0
	for L in lights:
		var c: Vector3 = L["c"]
		var covered := false
		for i in range(0, roof_f.size(), 3):
			if absf(roof_f[i].y - 11.5) < 0.05 and in_tri_xz(c, roof_f[i], roof_f[i + 1], roof_f[i + 2]):
				covered = true
				break
		if not covered and c.y > 11.4:
			open += 1
	var diag: float = lights[0]["diag"] if lights.size() else 0.0
	var skm = sky.mesh.surface_get_material(0) if sky else null
	check(lights.size() == 10 and open == 10 and absf(diag - sqrt(4.0 * 4.0 + 6.0 * 6.0)) < 0.1,
			"10 skylights (4 x 6 m glazing) set in openings in the roof", "%d skylights, %d over roof openings, at %s m" % [
			lights.size(), open, fmt(lights[0]["c"].y) if lights.size() else "?"])
	check(skm is StandardMaterial3D and skm.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED, "skylights glow (unshaded daylight material)")


func windows_static() -> void:
	var wd: Array = lv.data.get("windows", [])
	check(wd.size() == 5 and lv.windows.size() == 5, "5 breakable windows in the park data and level", "%d / %d" % [wd.size(), lv.windows.size()])
	var n_ok := 0
	var det: Array = []
	for i in lv.windows.size():
		var w: Dictionary = lv.windows[i]
		var node = w["node"]
		if node == null:
			det.append("Window_%d missing" % i)
			continue
		var ab := waabb(node)
		var c: Vector3 = w["center"]
		var through := ray(Vector3(15.0, c.y, c.z), Vector3(26.0, c.y, c.z))
		var beside := ray(Vector3(15.0, c.y, c.z + 2.6), Vector3(26.0, c.y, c.z + 2.6))
		var ok: bool = absf(ab.size.z - 2.8) < 0.1 and absf(ab.size.y - 2.0) < 0.1 and absf(ab.position.x - 19.95) < 0.1 \
				and ab.position.y > 4.06 and through.is_empty() and not beside.is_empty() and absf(beside["position"].x - 20.0) < 0.05 \
				and node.visible
		if ok:
			n_ok += 1
		det.append("%d:%sx%s@%s%s" % [i, fmt(ab.size.z), fmt(ab.size.y), fmt(ab.position.y), "" if through.is_empty() else " blocked"])
	check(n_ok == 5, "each window is a 2.8 x 2.0 m glass pane in an opening of the east wall, above the quarter and pipe", ", ".join(det))


func secret_room_static() -> void:
	var sr: Dictionary = lv.data["secret_room"]
	var mn := v3(sr["min"])
	var mx := v3(sr["max"])
	var ctr := Vector3(-25.0, 1.2, -37.0)
	# west: above the room's mini quarter (2 m) so the ray reaches the far wall
	var wx := ray(ctr + Vector3(0, 1.4, 0), ctr + Vector3(-10, 1.4, 0))
	var ex := ray(ctr + Vector3(0, 1.0, 0), ctr + Vector3(10, 1.0, 0))
	var nz := ray(ctr, ctr + Vector3(0, 0, -10))
	var sz := ray(ctr, ctr + Vector3(0, 0, 10))
	var fl := down(-25.0, -40.0, 3.0)
	var ok := not (wx.is_empty() or ex.is_empty() or nz.is_empty() or sz.is_empty() or fl.is_empty())
	var cin := mesh("Park_cinder")
	var ceil: float = waabb(cin).end.y if cin else -1.0
	var meas := AABB()
	if ok:
		meas = AABB(Vector3(wx["position"].x, fl["position"].y, nz["position"].z),
				Vector3(ex["position"].x - wx["position"].x, ceil - fl["position"].y, sz["position"].z - nz["position"].z))
	check(ok and absf(meas.position.x - mn.x) < 0.3 and absf(meas.end.x - mx.x) < 0.4 and absf(meas.position.z - mn.z) < 0.3
			and absf(meas.end.z - mx.z) < 0.3 and absf(ceil - 5.0) < 0.2,
			"hidden room behind the west wall measured from inside: ~10 x 12 m, 5 m high",
			"x %s..%s, z %s..%s, h %s" % [fmt(meas.position.x), fmt(meas.end.x), fmt(meas.position.z), fmt(meas.end.z), fmt(ceil)])
	var tp: Vector3 = lv.tape.global_position
	check(meas.grow(-0.2).has_point(tp) and v3(lv.data["tape"]).distance_to(tp) < 0.01 and lv.tape.visible and not lv.tape_taken,
			"the secret tape pickup is inside the hidden room", str(tp))
	# sealed: every ray from inside the room toward the hall stops at the west wall
	var sealed := 0
	var tries := 0
	for z in [-32.0, -34.3, -36.5, -38.7, -42.0]:
		for y in [0.4, 1.6, 3.0]:
			tries += 1
			var h := ray(Vector3(-24.0, y, z), Vector3(-10.0, y, z))
			if not h.is_empty() and h["position"].x < -19.8:
				sealed += 1
	check(sealed == tries, "the hidden room is sealed from the hall before the wall breaks", "%d/%d rays stopped at the wall" % [sealed, tries])
	var nodes_ok: bool = lv.wall_nodes.size() == lv.data["break_wall"]["nodes"].size()
	for n in lv.wall_nodes:
		nodes_ok = nodes_ok and n.visible
	check(nodes_ok and lv.wall_body != null and lv.wall_body.get_meta("breakable", false), "boarded-up breakable wall: plywood panels + battens + a breakable collision body",
			"%d panels" % lv.wall_nodes.size())


func lightmaps() -> void:
	var names: Array = lv.data.get("lightmapped", [])
	var img := Image.load_from_file(ProjectSettings.globalize_path("res://assets/park_lightmap.png"))
	var lm = lv.LIGHTMAP
	check(lm != null and lm.get_width() >= 1024 and img != null and not img.is_empty(), "baked lightmap texture loads",
			str(lm.get_size()) if lm else "missing")
	var shader_src: String = lv.PARK_SHADER.code
	var decal_src: String = lv.DECAL_SHADER.code
	check("texture(lightmap_tex, UV2)" in shader_src and "texture(lightmap_tex, UV2)" in decal_src,
			"the park and decal shaders sample lightmap_tex on UV2")
	var bad: Array = []
	var total_area := 0.0
	var dark: Array = []
	var lit_means: Array = []
	var n_surf := 0
	for nm in names:
		var mi := mesh(nm)
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
			# the baked light where this surface's UV2 lands
			# (sampled at triangle centroids in UV2, i.e. inside each lightmap island)
			var lum := 0.0
			var lmax := 0.0
			var black := 0
			var cnt := 0
			var tstep := maxi(1, idx.size() / 3 / 600) * 3
			for i in range(0, idx.size(), tstep):
				var u: Vector2 = (uv2[idx[i]] + uv2[idx[i + 1]] + uv2[idx[i + 2]]) / 3.0
				var l := img.get_pixel(clampi(int(u.x * img.get_width()), 0, img.get_width() - 1),
						clampi(int(u.y * img.get_height()), 0, img.get_height() - 1)).get_luminance()
				lum += l
				lmax = maxf(lmax, l)
				if l < 0.002:
					black += 1
				cnt += 1
			lum /= maxf(1.0, cnt)
			lit_means.append(lum)
			if lum < 0.01:
				dark.append("%s: mean %.3f, max %.3f, %d%% of %d sampled triangles black" % [nm, lum, lmax, 100 * black / maxi(1, cnt), cnt])
			var mat = mi.mesh.surface_get_material(s)
			if not (mat is ShaderMaterial):
				bad.append("%s: material %s" % [nm, mat.get_class() if mat else "null"])
				continue
			var sh = mat.shader
			if not (sh == lv.PARK_SHADER or sh == lv.DECAL_SHADER):
				bad.append("%s: shader %s" % [nm, sh.resource_path if sh else "null"])
			if mat.get_shader_parameter("lightmap_tex") != lm:
				bad.append("%s: lightmap_tex not bound" % nm)
			var use = mat.get_shader_parameter("use_lightmap")
			var energy = mat.get_shader_parameter("lightmap_energy")
			if (use != null and use == false) or energy == null or float(energy) <= 0.0:
				bad.append("%s: lightmap disabled" % nm)
	check(names.size() >= 20 and bad.is_empty(), "every lightmapped surface has UV2 in [0,1] and a material sampling the baked lightmap",
			("%d meshes / %d surfaces" % [names.size(), n_surf]) if bad.is_empty() else "; ".join(bad.slice(0, 8)))
	check(total_area > 0.25 and total_area < 1.02, "lightmap UV islands fit the atlas without gross overlap (total UV2 area)", "%.3f of the 0..1 square" % total_area)
	lit_means.sort()
	var med: float = lit_means[lit_means.size() / 2] if lit_means.size() else 0.0
	check(dark.is_empty(), "the baked lightmap has light where every lightmapped surface samples it",
			("; ".join(dark) + "; median mesh mean %.3f" % med) if dark.size() else "all lit, median mesh mean %.3f" % med)
	# the only meshes without the lightmap are emissive / glass ones
	var others: Array = []
	for mi in lv._meshes(park):
		if not (String(mi.name) in names):
			others.append(String(mi.name))
	var allowed := ["Park_lamp", "Park_skylight", "Park_exit_sign", "Park_yard"]
	var extra := others.filter(func(n): return not (n in allowed or n.begins_with("Window_")))
	check(extra.is_empty(), "every other park mesh is lightmapped (only lamps, skylights, exit sign, yard backdrop, glass are not)",
			", ".join(others) if extra.is_empty() else "unlightmapped: " + ", ".join(extra))


# ------------------------------------------------------------------ grind lines

func rail_named(nm: String):
	for r in lv.rails:
		if r.name == nm:
			return r
	return null


## Fraction of sample points along the rail with a visual triangle right at the grind line
## (a short vertical ray through the line, nudged off the tube's crease, hits a triangle
## within 6 cm of the line).
func line_coverage(r, meshes_f: Array, n := 20) -> float:
	var hits := 0
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
	for k in n:
		var s: float = r.length * (0.02 + 0.96 * k / float(n - 1))
		var p: Vector3 = r.point_at(s)
		var side: Vector3 = r.dir_at(s).cross(Vector3.UP).normalized() * 0.004
		var a := p + side + Vector3.UP * 0.2
		var found := false
		for t in cand:
			var h = Geometry3D.ray_intersects_triangle(a, Vector3.DOWN, t[0], t[1], t[2])
			if h != null and absf(h.y - p.y) < 0.06:
				found = true
				break
		if found:
			hits += 1
	return hits / float(n)


func grind_lines() -> void:
	var by_tag := {}
	for r in lv.rails:
		by_tag[r.tag] = by_tag.get(r.tag, 0) + 1
	var want := {"rail": 4, "ledge": 8, "coping": 5, "pipe": 1, "rafter": 2, "catwalk": 1}
	var ok := true
	for t in want:
		ok = ok and by_tag.get(t, 0) >= want[t]
	check(ok, "grind lines for rails, ledges, copings, the wall pipe, rafters and the catwalk", str(by_tag))
	var lengths := {"long_rail": [17.5, 18.5], "diag_rail": [9.0, 9.5], "funbox_rail": [2.4, 2.8], "wall_pipe": [50.0, 60.0],
			"east_qp_coping": [55.0, 62.0], "hp_coping_w": [11.5, 12.5], "hp_coping_e": [11.5, 12.5], "dropin_coping": [15.0, 17.0],
			"se_qp_coping": [7.0, 8.0], "ledge_a": [9.5, 10.5], "ledge_b": [4.5, 5.5], "rafter_west": [18.0, 21.0],
			"rafter_east": [13.0, 15.0], "secret_rail": [5.0, 6.0], "catwalk_handrail": [30.0, 36.0]}
	var bad: Array = []
	for r in lv.rails:
		if lengths.has(r.name):
			var lr: Array = lengths[r.name]
			if r.length < lr[0] or r.length > lr[1]:
				bad.append("%s %s m" % [r.name, fmt(r.length)])
		elif r.tag == "ledge" and (r.length < 2.5 or r.length > 5.0):
			bad.append("%s %s m" % [r.name, fmt(r.length)])
	check(bad.is_empty(), "grind lines have real-world lengths (18 m flat rail, 56 m wall pipe, 10 m ledge, ...)",
			"; ".join(bad) if bad.size() else "long_rail %s, wall_pipe %s, ledge_a %s, rafter_west %s" % [
			fmt(rail_named("long_rail").length), fmt(rail_named("wall_pipe").length), fmt(rail_named("ledge_a").length),
			fmt(rail_named("rafter_west").length)])
	# heights of the street pieces
	var lr_ = rail_named("long_rail")
	var lb = rail_named("ledge_b")
	var la = rail_named("ledge_a")
	check(lr_ and absf(lr_.points[0].y - 0.524) < 0.05 and la and absf(la.points[0].y - 0.5) < 0.05 and lb and absf(lb.points[0].y - 0.42) < 0.05,
			"street rail / ledges at real heights (flat rail ~0.5 m, ledges 0.42-0.5 m)")
	var fs: Array = []
	for nm in ["Park_rail", "Park_coping", "Park_steel", "Park_rafter"]:
		var mi := mesh(nm)
		if mi:
			fs.append(tris(mi))
	var weak: Array = []
	var cov_sum := 0.0
	for r in lv.rails:
		var cov := line_coverage(r, fs)
		cov_sum += cov
		if cov < 0.95:
			weak.append("%s %.0f%%" % [r.name, cov * 100.0])
	check(weak.is_empty(), "every grind line runs along real geometry (rail / coping / pipe / beam mesh under 20 samples each)",
			"; ".join(weak) if weak.size() else "%d lines, mean coverage %.0f%%" % [lv.rails.size(), cov_sum / lv.rails.size() * 100.0])
	# the wall pipe really is a pipe: it is the steel tube just above the east quarter's deck
	var wp = rail_named("wall_pipe")
	check(wp and wp.tag == "pipe" and wp.points[0].y > 3.2 + 0.5 and wp.points[0].y < lv.windows[0]["bottom"] and absf(wp.points[0].x - 19.55) < 0.2,
			"wall pipe runs above the east quarterpipe's deck, below the windows", "%s m up" % fmt(wp.points[0].y) if wp else "missing")


# ------------------------------------------------------------------ rides (real skater)

## Spawns the real skater and records its motion for n physics frames.
func ride(pos: Vector3, dir: Vector3, speed: float, n: int, hold: Array = []) -> Dictionary:
	top_up()
	var b0 := bails.size()
	sk.spawn(pos, dir, speed)
	for k in hold:
		key(k, true)
	var rec := {"max_y": -99.0, "min_y": 99.0, "air": false, "air_max_y": -99.0, "wood_y": -99.0, "steep": 0.0,
			"max_x": -99.0, "min_x": 99.0, "max_z": -99.0, "min_z": 99.0, "states": {}, "end": Vector3.ZERO, "speed": 0.0,
			"wood_top_flat": false, "rev": false}
	for i in n:
		await physics_frame
		var p: Vector3 = sk.global_position
		rec["max_y"] = maxf(rec["max_y"], p.y)
		rec["min_y"] = minf(rec["min_y"], p.y)
		rec["max_x"] = maxf(rec["max_x"], p.x)
		rec["min_x"] = minf(rec["min_x"], p.x)
		rec["max_z"] = maxf(rec["max_z"], p.z)
		rec["min_z"] = minf(rec["min_z"], p.z)
		rec["states"][sk.state] = true
		if sk.state == sk.AIR:
			rec["air"] = true
			rec["air_max_y"] = maxf(rec["air_max_y"], p.y)
		if sk.state == sk.GROUND and sk.surface == "wood":
			rec["wood_y"] = maxf(rec["wood_y"], p.y)
			rec["steep"] = maxf(rec["steep"], rad_to_deg(sk.up.angle_to(Vector3.UP)))
			if absf(p.y - 0.9) < 0.05 and sk.up.y > 0.999:
				rec["wood_top_flat"] = true
		if sk.vel.dot(dir) < -0.5:
			rec["rev"] = true
	for k in hold:
		key(k, false)
	rec["end"] = sk.global_position
	rec["speed"] = sk.vel.length()
	rec["bails"] = bails.slice(b0)
	return rec


func rides() -> void:
	# drop-in from the start deck: hold W (push) from the spawn point
	var r := await ride(lv.spawn_pos, lv.spawn_forward, 0.0, 240, [KEY_W])
	check(r["bails"].is_empty() and r["min_y"] < 0.1 and r["steep"] > 50.0 and r["max_y"] > 4.9,
			"skater pushes off the 5 m deck and rolls down the steep drop-in to the floor",
			"from %s m to %s m, steepest %s deg on wood, speed %s m/s, bails %s" % [fmt(r["max_y"]), fmt(r["min_y"]), fmt(r["steep"]),
			fmt(r["speed"]), str(r["bails"])])
	# halfpipe: across the flat, up the east wall, back down and up the west wall
	var hz: float = lv.data["halfpipe"]["center"][2]
	r = await ride(Vector3(0, 0.02, hz), Vector3(1, 0, 0), 7.5, 300)
	check(r["bails"].is_empty() and r["max_x"] > 4.5 and r["min_x"] < -4.5 and r["wood_y"] > 2.0 and r["rev"],
			"skater rides the halfpipe wall to wall (up the east transition, back, up the west one)",
			"x %s..%s, highest on wood %s m, steepest %s deg, bails %s" % [fmt(r["min_x"]), fmt(r["max_x"]), fmt(r["wood_y"]),
			fmt(r["steep"]), str(r["bails"])])
	# east wall quarter
	r = await ride(Vector3(12.0, 0.02, -38.0), Vector3(1, 0, 0), 7.0, 210)
	check(r["bails"].is_empty() and r["wood_y"] > 1.5 and r["rev"] and r["end"].x < 16.0,
			"skater rides up the east quarterpipe and back down", "up to %s m, steepest %s deg, bails %s" % [
			fmt(r["wood_y"]), fmt(r["steep"]), str(r["bails"])])
	# south-east quarter
	r = await ride(Vector3(11.0, 0.02, 6.0), Vector3(0, 0, 1), 6.5, 200)
	check(r["bails"].is_empty() and r["wood_y"] > 1.2 and r["rev"] and r["end"].z < 12.8,
			"skater rides up the south-east quarterpipe and back down", "up to %s m, steepest %s deg, end %s, states %s, bails %s" % [
			fmt(r["wood_y"]), fmt(r["steep"]), str(r["end"].snapped(Vector3.ONE * 0.01)), str(r["states"].keys()), str(r["bails"])])
	# street kicker launches into the air
	r = await ride(Vector3(0.0, 0.02, -1.0), Vector3(0, 0, -1), 8.5, 120)
	check(r["bails"].is_empty() and r["air"] and r["air_max_y"] > 1.0 and r["wood_y"] > 0.4,
			"street kicker launches the skater into the air", "air up to %s m, bails %s" % [fmt(r["air_max_y"]), str(r["bails"])])
	# funbox: up the bank, across the flat top, down the far bank
	r = await ride(Vector3(1.0, 0.02, -10.5), Vector3(0, 0, -1), 5.5, 240)
	check(r["bails"].is_empty() and r["wood_top_flat"] and r["min_z"] < -20.0,
			"skater rolls up the funbox bank, across the 0.9 m top and down the far side",
			"top reached %s, reached z %s, end %s speed %s, states %s, bails %s" % [str(r["wood_top_flat"]), fmt(r["min_z"]),
			str(r["end"].snapped(Vector3.ONE * 0.01)), fmt(r["speed"]), str(r["states"].keys()), str(r["bails"])])
	sk.spawn(Vector3(0, 0.02, -28), Vector3(0, 0, -1), 0.0)
	await physics(10)


# ------------------------------------------------------------------ grinds (real skater)

func balance_keys() -> void:
	## Player-style balance: tap the stick against the lean (Left/Right keys).
	if sk.state != sk.GRIND:
		key(KEY_A, false)
		key(KEY_D, false)
		return
	var b: float = sk.grind_bal + sk.grind_bal_v * 0.25
	key(KEY_D, b > 0.03)
	key(KEY_A, b < -0.03)


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
		await physics(2)     # the grind step then moves the skater onto the line
	var res := {"got": got and sk.state == sk.GRIND, "rail": rail_at_snap, "frames": n, "state": sk.state,
			"trick": String(sk.grind_info.get("name", "")) if got else "", "pos": sk.global_position}
	key(KEY_L, false)
	return res


func grind_snaps() -> void:
	for r in lv.rails:
		var res := await snap_on(r, 0.3)
		var same: bool = res["got"] and res["rail"] == r
		var dist: float = r.closest(res["pos"])["dist"] if res["got"] else -1.0
		check(same and dist < 0.02, "grind button snaps the skater into GRIND on %s (%s)" % [r.name, r.tag],
				("%s after %d frames" % [res["trick"], res["frames"]]) if same else "state=%d rail=%s" % [res["state"],
				res["rail"].name if res["rail"] else "none"])
		# end the grind on the floor and let the re-grind cooldown pass
		sk.spawn(Vector3(0, 0.02, -28), Vector3(0, 0, -1), 0.0)
		await physics(24)


func rafter_from_catwalk() -> void:
	## The "Grind the Rafters" goal the THPS way: along the west catwalk, off its kicker,
	## grind button in the air onto the rafter.
	check(not goal_done("rafters"), "rafter goal not yet done before the rafter grind")
	var got := ""
	var t_grind := 0
	var b0 := bails.size()
	top_up()
	sk.spawn(Vector3(-18.8, 5.02, -12.0), Vector3(0, 0, -1), 9.0)
	for i in 360:
		await physics_frame
		if sk.state == sk.AIR:
			key(KEY_L, true)
		if sk.state == sk.GRIND:
			if got == "":
				got = sk.grind_rail.name
			t_grind += 1
			key(KEY_L, false)
			balance_keys()
		elif got != "":
			break
	key(KEY_L, false)
	key(KEY_A, false)
	key(KEY_D, false)
	check(got == "rafter_west", "the rafter is reachable: off the catwalk kicker, grind button, onto the rafter",
			"grind on '%s' for %.2f s, bails %s" % [got, t_grind / 60.0, str(bails.slice(b0))])
	check(goal_done("rafters"), "grinding the rafter completes 'Grind the Rafters'")
	sk.spawn(Vector3(0, 0.02, -28), Vector3(0, 0, -1), 0.0)
	await physics(24)


# ------------------------------------------------------------------ windows

func windows_gameplay() -> void:
	lv.reset_run()
	await physics(2)
	var all_vis := true
	for w in lv.windows:
		all_vis = all_vis and w["node"].visible and not glass_broken(w["node"]) and not w["broken"]
	check(all_vis and lv.windows_broken() == 0, "windows intact at the start (after reset_run)")
	# negative controls: rolling on the ground under a window / airborne mid-hall do not break
	lv.check_windows(Vector3(19.2, 3.2, -9.0), false)
	lv.check_windows(Vector3(5.0, 4.0, -9.0), true)
	check(lv.windows_broken() == 0, "a window does not break from the ground or from mid-hall airs")
	broken_log.clear()
	var per: Array = []
	for i in lv.windows.size():
		var c: Vector3 = lv.windows[i]["center"]
		var before: int = lv.windows_broken()
		var r := await ride(Vector3(11.5, 0.02, c.z), Vector3(1, 0, 0), 11.0, 150)
		var node = lv.windows[i]["node"]
		var ok: bool = lv.windows[i]["broken"] and glass_broken(node) and lv.windows_broken() == before + 1 and r["bails"].is_empty()
		per.append(ok)
		check(ok, "window %d breaks when the skater launches a vert air off the east quarter in front of it" % i,
				"air up to %s m, broken now %d, glass broken %s, bails %s" % [fmt(r["air_max_y"]), lv.windows_broken(), str(glass_broken(node)), str(r["bails"])])
	var idx := broken_log.map(func(e): return e[0])
	check(lv.windows_broken() == 5 and idx == [0, 1, 2, 3, 4] and broken_log.size() == 5 and broken_log[4][1] == 5,
			"all 5 windows broken, each once (window_broken signal 1/5 .. 5/5)", str(broken_log))
	check(goal_done("windows"), "breaking the 5 windows completes 'Break the 5 Windows'")
	lv.reset_run()
	await physics(2)
	all_vis = true
	for w in lv.windows:
		all_vis = all_vis and w["node"].visible and not glass_broken(w["node"]) and not w["broken"]
	check(all_vis and lv.windows_broken() == 0, "reset_run restores all 5 windows")
	# grinding the wall pipe right under the glass breaks them all too
	broken_log.clear()
	var wp = rail_named("wall_pipe")
	var res := await snap_on(wp, 0.25, 9.0)
	var b0 := bails.size()
	var end_z := 0.0
	if res["got"]:
		for i in 420:
			await physics_frame
			balance_keys()
			if sk.state != sk.GRIND:
				break
			end_z = sk.global_position.z
	key(KEY_A, false)
	key(KEY_D, false)
	check(res["got"] and lv.windows_broken() == 5, "a grind along the wall pipe breaks all 5 windows above it",
			"grind from z %s to %s, broken %d, bails %s" % [fmt(res["pos"].z), fmt(end_z), lv.windows_broken(), str(bails.slice(b0))])
	# every broken window threw its glass: shards that land on the park below it (the east
	# quarterpipe) within 3 s, inside the hall, and lie flat on what they hit
	var n_burst := 0
	var n_sh := 0
	var n_landed := 0
	var n_in_hall := 0
	for w in lv.windows:
		var b = w["burst"]
		if not is_instance_valid(b):
			continue
		n_burst += 1
		for sh in b._shards:
			n_sh += 1
			var lp: Vector3 = sh["land_p"]
			if float(sh["t_land"]) < 3.0:
				n_landed += 1
				if lp.x < 20.0 and lp.x > 12.0 and lp.y > -0.01 and lp.y < 4.5:
					n_in_hall += 1
	check(n_burst == 5 and n_sh >= 5 * 40 and n_landed == n_sh and n_in_hall == n_sh,
			"each broken window throws glass shards that land on the park below it (the east quarterpipe) and stay in the hall",
			"%d bursts, %d shards, %d landed, %d inside the hall below the windows" % [n_burst, n_sh, n_landed, n_in_hall])
	lv.reset_run()
	await physics(2)
	var left := 0
	for w in lv.windows:
		if is_instance_valid(w["burst"]):
			left += 1
	check(lv.windows_broken() == 0 and left == 0 and lv.windows.all(func(w): return not glass_broken(w["node"])),
			"reset_run restores them again (whole glass, the shards cleared)", "%d bursts left" % left)
	sk.spawn(Vector3(0, 0.02, -28), Vector3(0, 0, -1), 0.0)
	await physics(10)


# ------------------------------------------------------------------ wall + room

func doorway_rays() -> Dictionary:
	var through := 0
	var tries := 0
	for z in [-34.3, -36.5, -38.7]:
		for y in [0.4, 1.6, 3.0]:
			tries += 1
			var h := ray(Vector3(-15.0, y, z), Vector3(-35.0, y, z))
			if h.is_empty() or h["position"].x < -20.5:
				through += 1
	var above := ray(Vector3(-15.0, 3.5, -36.5), Vector3(-35.0, 3.5, -36.5))
	var side_n := ray(Vector3(-15.0, 1.6, -33.6), Vector3(-35.0, 1.6, -33.6))
	var side_s := ray(Vector3(-15.0, 1.6, -39.4), Vector3(-35.0, 1.6, -39.4))
	var frame := 0
	for h in [above, side_n, side_s]:
		if not h.is_empty() and h["position"].x > -20.3:
			frame += 1
	var q := PhysicsShapeQueryParameters3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 0.3
	q.shape = sph
	q.transform = Transform3D(Basis.IDENTITY, Vector3(-16.0, 1.0, -36.5))
	q.motion = Vector3(-7.0, 0, 0)
	q.collision_mask = 1
	var cm := space.cast_motion(q)
	var first := ray(Vector3(-15.0, 1.6, -36.5), Vector3(-35.0, 1.6, -36.5))
	return {"through": through, "tries": tries, "frame": frame, "sphere": cm[0],
			"first": first["collider"].name if not first.is_empty() else "none",
			"first_x": first["position"].x if not first.is_empty() else -99.0}


func wall_and_room_gameplay() -> void:
	lv.reset_run()
	await physics(3)
	var d0 := doorway_rays()
	check(d0["through"] == 0 and d0["sphere"] < 0.6 and d0["first"] == "BreakWallBody",
			"before: rays and a skater-sized sphere cast from the hall into the secret room are blocked by the boarded wall",
			"%d/%d rays through, sphere free %.0f%%, first hit %s at x=%s" % [d0["through"], d0["tries"], d0["sphere"] * 100.0, d0["first"], fmt(d0["first_x"])])
	check(not goal_done("tape") and not lv.tape_taken, "tape not yet collected")
	# roll into the boarded wall at speed: it breaks, the skater rolls on into the room,
	# over the room's kicker and through the tape
	var b0 := bails.size()
	wall_signal = 0
	tape_signal = 0
	top_up()
	sk.spawn(Vector3(-12.0, 0.02, -36.8), Vector3(-1, 0, 0), 8.0)
	var min_x := 99.0
	var inside_frames := 0
	var room := AABB(v3(lv.data["secret_room"]["min"]), v3(lv.data["secret_room"]["max"]) - v3(lv.data["secret_room"]["min"]))
	var broke_at := Vector3.ZERO
	for i in 240:
		await physics_frame
		var p: Vector3 = sk.global_position
		min_x = minf(min_x, p.x)
		if room.has_point(p + Vector3.UP * 0.1):
			inside_frames += 1
		if wall_signal > 0 and broke_at == Vector3.ZERO:
			broke_at = p
	var body_gone: bool = not is_instance_valid(lv.wall_body) or lv.wall_body.is_queued_for_deletion()
	check(wall_signal == 1 and lv.wall_broken_flag and body_gone,
			"rolling into the boarded wall breaks it (wall_broken, collision body removed)", "broke with the skater at %s" % str(broke_at.snapped(Vector3.ONE * 0.01)))
	var vis := false
	for n in lv.wall_nodes:
		vis = vis or n.visible
	check(not vis, "the boarded wall's panels, battens and sign are gone")
	check(inside_frames > 20 and min_x < -23.0 and bails.slice(b0).is_empty(), "the skater rolls through the doorway into the hidden room",
			"%.2f s inside, reached x=%s, bails %s" % [inside_frames / 60.0, fmt(min_x), str(bails.slice(b0))])
	check(tape_signal == 1 and lv.tape_taken and not lv.tape.visible, "the secret tape is collected in the room (off the room's kicker)",
			"tape signals %d" % tape_signal)
	check(goal_done("tape"), "collecting the tape completes 'Find the Secret Tape'")
	await physics(3)
	var d1 := doorway_rays()
	check(d1["through"] == d1["tries"] and d1["sphere"] >= 0.999 and d1["frame"] == 3,
			"after: the doorway into the room is open (~5 m wide, 3.2 m high) and a skater-sized sphere passes",
			"%d/%d rays through, sphere free %.0f%%, frame blocked %d/3, first hit %s at x=%s" % [d1["through"], d1["tries"],
			d1["sphere"] * 100.0, d1["frame"], d1["first"], fmt(d1["first_x"])])
	lv.reset_run()
	await physics(3)
	var d2 := doorway_rays()
	var vis2 := true
	for n in lv.wall_nodes:
		vis2 = vis2 and n.visible
	check(d2["through"] == 0 and d2["first"] == "BreakWallBody" and vis2 and not lv.wall_broken_flag and lv.tape.visible and not lv.tape_taken,
			"reset_run rebuilds the wall (blocked again) and puts the tape back", "%d rays through, first hit %s" % [d2["through"], d2["first"]])
