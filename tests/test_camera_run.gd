extends SceneTree
## Chase-camera metrics over the complete two-minute autopilot run (start deck drop-in,
## catwalk, rafter grind, secret room, east quarterpipe vert airs, wall-pipe grind under
## the windows, street section, halfpipe airs), plus vert-air drills next to the park's
## walls. The real main scene, the real skater and the real ChaseCamera run unmodified;
## this script only observes them (the drills only spawn the skater and hold the push /
## pump input, as a player would).
##
##   timeout 1200 godot --headless --path . --fixed-fps 60 -s tests/test_camera_run.gd -- --autopilot=test
##   -> tests/results/camera.txt   (exit code 0 only if every check passes)
##
## The run mode also starts a second headless process of this same script (user arg
## --camera-drills, log tests/results/camera_drills.log) that rides vert airs at every vert
## wall standing next to a wall or a ceiling: the east quarterpipe under the windows (8
## lanes incl. both ends and the one under rafter_east, 2 angled airs), the south-east
## corner quarter, the secret room's mini quarter under its 5 m ceiling and the halfpipe
## next to the north wall / at its open end. It measures every frame the same way and
## hands its checks back through tests/results/camera_drills.json (the parent deletes the
## old file first and waits for the process; a missing result is a FAIL line).
##
## Pass criteria (all stated in the result lines): 0 clipping frames and 0 near-clip volume
## cuts (collision and rendered), 0 frames inside a solid, 0 frames outside the hall,
## occluded < 2 % overall / during vert air / during grinds (collision and rendered), the
## skater never completely hidden, closer than 0.9 m in < 1 %, body centre always on screen
## and head / feet off screen < 1 %; the same per wall spot for the vert-air drills.
## The game has a little unseeded randomness (grind / manual balance wobble, camera shake),
## so single counts can differ by a frame between runs.
##
## Every physics frame (measured right after the physics step, before the frame is drawn)
## is checked against two sets of geometry:
##   collision - the park collision (layer 1, park bodies only - the loose board after a
##               bail is not park); this is what the camera's own spring arm avoids
##   rendered  - trimesh copies of every park mesh that is drawn (incl. the parts without
##               collision: steel hanger rods and trusses, lamps, window glass, decals),
##               kept in a private physics space so the game's world is untouched; a mesh
##               that is hidden (a broken window, the smashed wall) is ignored
## Measured:
##   - line of sight: ray camera -> skater position + 1.2 m up (opaque geometry: the 28 %
##     alpha window glass does not hide the skater), and 9 points over the body (feet,
##     knees, hips, chest, head, shoulders) for "completely hidden"
##   - clipping: geometry inside a sphere of radius cam.near * 1.5 around the camera, and
##     inside the near-clip pyramid (apex -> near plane) of the widest display considered
##   - inside a solid: in most of 14 directions the first surface seen from the camera is
##     a back face (in open space every direction sees front faces)
##   - camera inside the hall (park collision AABB) or the secret room (park data)
##   - distance from the camera to the skater's body (feet -> head axis), < 0.9 m = too close
##   - framing: body centre, head and feet inside the camera frustum
## The same numbers are kept for vert airs (per spot), grinds (per rail) and each area.

const RESULTS := "res://tests/results/camera.txt"
const DRILL_JSON := "res://tests/results/camera_drills.json"
const DRILL_LOG := "res://tests/results/camera_drills.log"
const LOS_HEIGHT := 1.2          # upper body: skater position + 1.2 m up
const BODY_LEN := 1.7            # feet -> head along the skater's up axis
const TOO_CLOSE := 0.9
const MAX_OCCLUDED := 0.02       # < 2 % of frames
const MAX_TOO_CLOSE := 0.01      # < 1 % of frames
const MAX_EDGE_OFF := 0.01       # head or feet off screen: < 1 % of frames
const WIDE_ASPECT := 21.0 / 9.0  # widest display considered for the near plane (keep-height fov)
const NARROW_ASPECT := 4.0 / 3.0 # narrowest display considered for framing
const INSIDE_RANGE := 60.0
const WATCHDOG_FRAMES := 60 * 240  # the run is 120 s plus the last combo; give up after 240 s
const PROGRESS_EVERY := 60 * 15  # write an interim (incomplete) report every 15 s of run
const DRILL_TIMEOUT_S := 600     # hard limit for the drill process (it needs about 90 s of game time)
const DRILL_WATCHDOG_FRAMES := 60 * 200
## body sample points: [height along the skater's up axis, offset along its right axis]
const BODY_PTS := [[0.1, 0.0], [0.45, 0.0], [0.9, 0.0], [1.2, 0.0], [1.6, 0.0], [0.9, -0.22], [0.9, 0.22],
		[1.35, -0.22], [1.35, 0.22]]
const FLAGS := ["col_occ", "vis_occ", "col_clip", "col_nv", "vis_clip", "vis_nv", "col_in", "vis_in", "outside",
		"close", "col15", "col30", "vis15", "vis30", "hidden", "off_mid", "off_edge"]
const EVENT_TITLES := {
	"col_clip": "clipping frames, park collision within the clip sphere (first 25):",
	"col_nv": "near-clip volume frames, park collision (first 25):",
	"vis_clip": "clipping frames, rendered geometry within the clip sphere (first 25):",
	"vis_nv": "near-clip volume frames, rendered geometry (first 25):",
	"col_in": "camera inside a solid, park collision (first 25):",
	"vis_in": "camera inside a solid / behind a surface, rendered geometry (first 25):",
	"outside": "frames outside the hall (first 25):",
	"close": "too-close frames (first 25):",
	"off_mid": "frames with the skater's body centre off screen (first 25):",
	"hidden": "frames with the skater completely hidden (first 25):",
}
const LABELS := {"col_clip": "clip (collision)", "col_nv": "near-clip volume (collision)", "vis_clip": "clip (rendered)",
		"vis_nv": "near-clip volume (rendered)", "col_in": "inside a solid (collision)", "vis_in": "inside a solid (rendered)",
		"outside": "outside the hall", "off_mid": "body centre off screen", "hidden": "completely hidden"}
const AREAS := ["start deck / drop-in", "catwalk", "west rafter", "secret room", "east quarterpipe / wall pipe",
		"street / floor", "halfpipe"]
const G_EAST := "east quarterpipe (window wall)"
const G_SE := "south-east corner quarter"
const G_ROOM := "secret room quarter (5 m ceiling)"
const G_HP := "halfpipe by the north wall / open end"
const DRILL_GROUPS := [G_EAST, G_SE, G_ROOM, G_HP]

var drill_mode := false
var main
var cam
var sk
var ap
var hall := AABB()
var room := AABB()
var clip_r := 0.075
var cam_near := 0.05
var cam_fov := 68.0
var aspect_view := 1.0
var aspect_frame := 1.0
var aspect_near := WIDE_ASPECT
var vp_size := Vector2.ZERO
var sphere_q: PhysicsShapeQueryParameters3D
var margin_q: PhysicsShapeQueryParameters3D
var margin_shape := SphereShape3D.new()
var frustum_q: PhysicsShapeQueryParameters3D
var vis_world: World3D
var vis_info: Dictionary = {}    # private body RID -> {name, node, clear}
var vis_bodies: Array = []
var vis_shapes: Array = []
var vsphere_q: PhysicsShapeQueryParameters3D
var vmargin_q: PhysicsShapeQueryParameters3D
var vmargin_shape := SphereShape3D.new()
var vfrustum_q: PhysicsShapeQueryParameters3D
var dirs: Array[Vector3] = []

var rows: Dictionary = {}        # row name -> stats
var prev_keys: Array = []
var selftest: Array = []         # [ok, what]
var frames_measured := 0
var frames_skipped := 0          # physics frames of the run that were not measured
var last_phys := -1
var run_started := false
var run_frame0 := 0
var pf_init := 0
var setup_done := false
var first_measured_phys := -1
var stretch: Dictionary = {"col": {}, "vis": {}}
var stretches: Dictionary = {"col": [], "vis": []}
var events: Dictionary = {}
var mesh_hits: Dictionary = {}   # "what: mesh" -> frames
var vert_airs := 0
var grinds := 0
var episodes: Array = []         # every vert air and grind: {kind, t0, t1, frames, ...}
var cur_ep: Dictionary = {}
var model_hidden := 0
var min_dist := INF
var min_dist_info := ""
var cur_tag := ""
var vis_late_done := false

var final_snapshot: Dictionary = {}
var finished_written := false

# drills (child process) / drill results (parent)
var drill_pid := -1
var drill_t0 := 0
var drill_list: Array = []
var di := 0
var d_spawned := false
var d_frame := 0
var d_airs := 0
var d_vert_frames := 0
var d_top := -INF
var d_last_land := -1
var d_was_vert := false
var d_bails := 0
var d_windows0 := 0
var d_summaries: Array = []
var drill_result: Dictionary = {}


func _initialize() -> void:
	drill_mode = OS.get_cmdline_user_args().has("--camera-drills")
	pf_init = Engine.get_physics_frames()
	for k in EVENT_TITLES:
		events[k] = []
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	main.tree_exiting.connect(_snapshot_end)
	if not drill_mode:
		_launch_drills()


func _q(s: String) -> String:
	return "'" + s.replace("'", "'\\''") + "'"


## The drills need a game that is not on autopilot, so they run in a second process of
## this script (started now, in parallel with the run; collected at the end).
func _launch_drills() -> void:
	var json_abs := ProjectSettings.globalize_path(DRILL_JSON)
	DirAccess.make_dir_recursive_absolute(json_abs.get_base_dir())
	if FileAccess.file_exists(DRILL_JSON):
		DirAccess.remove_absolute(json_abs)
	var cmd := "exec timeout %d %s --headless --path %s --fixed-fps 60 -s res://tests/test_camera_run.gd -- --camera-drills > %s 2>&1" % [
			DRILL_TIMEOUT_S, _q(OS.get_executable_path()), _q(ProjectSettings.globalize_path("res://")),
			_q(ProjectSettings.globalize_path(DRILL_LOG))]
	drill_pid = OS.create_process("/bin/sh", ["-c", cmd])
	drill_t0 = Time.get_ticks_msec()


func _setup() -> void:
	setup_done = true
	cam = main.cam
	sk = main.skater
	ap = main.get_node_or_null("Autopilot")
	# hall bounds from the park itself: the AABB of every park collision face. The secret
	# room sticks out of the west wall (park data "secret_room"), so the hall part of the
	# AABB starts at the room's east edge and the room is its own box.
	var bb := AABB()
	var first := true
	for body in main.level.park.find_children("*", "StaticBody3D", true, false):
		for c in body.get_children():
			if c is CollisionShape3D and c.shape is ConcavePolygonShape3D:
				var xf: Transform3D = c.global_transform
				for v in c.shape.get_faces():
					var w: Vector3 = xf * v
					if first:
						bb = AABB(w, Vector3.ZERO)
						first = false
					else:
						bb = bb.expand(w)
	var sr: Dictionary = main.level.data["secret_room"]
	var rmin := Vector3(sr["min"][0], sr["min"][1], sr["min"][2])
	var rmax := Vector3(sr["max"][0], sr["max"][1], sr["max"][2])
	room = AABB(rmin, rmax - rmin)
	var hmin := bb.position
	hmin.x = maxf(hmin.x, rmax.x)
	hall = AABB(hmin, bb.end - hmin)
	# the display: the camera keeps its (vertical) fov, so a wider screen shows more at the
	# sides - the near plane is widest on the widest screen, framing tightest on the narrowest
	vp_size = root.get_visible_rect().size
	aspect_view = vp_size.x / maxf(1.0, vp_size.y)
	aspect_near = maxf(aspect_view, WIDE_ASPECT)
	aspect_frame = minf(aspect_view, NARROW_ASPECT)
	cam_near = cam.near
	cam_fov = cam.fov
	clip_r = cam_near * 1.5
	var hh: float = cam.near * tan(deg_to_rad(cam.fov) * 0.5)
	var hw: float = hh * aspect_near
	var pts := PackedVector3Array([Vector3.ZERO, Vector3(-hw, -hh, -cam.near), Vector3(hw, -hh, -cam.near),
			Vector3(hw, hh, -cam.near), Vector3(-hw, hh, -cam.near)])
	# park collision queries (the game's own world)
	var sph := SphereShape3D.new()
	sph.radius = clip_r
	sphere_q = _shape_q(sph, 1)
	margin_q = _shape_q(margin_shape, 1)
	var pyr := ConvexPolygonShape3D.new()
	pyr.points = pts
	frustum_q = _shape_q(pyr, 1)
	# rendered geometry: a private physics space with a trimesh of every park mesh
	vis_world = World3D.new()
	for mi in main.level.park.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		var sh = mi.mesh.create_trimesh_shape()
		if sh == null:
			continue
		sh.backface_collision = true      # rays report back faces only when asked (hit_back_faces)
		vis_shapes.append(sh)
		var b := PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(b, PhysicsServer3D.BODY_MODE_STATIC)
		PhysicsServer3D.body_add_shape(b, sh.get_rid())
		PhysicsServer3D.body_set_collision_layer(b, 1)
		PhysicsServer3D.body_set_collision_mask(b, 0)
		PhysicsServer3D.body_set_space(b, vis_world.space)
		PhysicsServer3D.body_set_state(b, PhysicsServer3D.BODY_STATE_TRANSFORM, mi.global_transform)
		vis_info[b] = {"name": String(mi.name), "node": mi, "clear": String(mi.name).begins_with("Window_")}
		vis_bodies.append(b)
	var vsph := SphereShape3D.new()
	vsph.radius = clip_r
	vsphere_q = _shape_q(vsph, 1)
	vmargin_q = _shape_q(vmargin_shape, 1)
	var vpyr := ConvexPolygonShape3D.new()
	vpyr.points = pts
	vfrustum_q = _shape_q(vpyr, 1)
	# 6 axes + 8 diagonals for the inside-a-solid probe
	for d in [Vector3.UP, Vector3.DOWN, Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]:
		dirs.append(d)
	for x in [-1.0, 1.0]:
		for y in [-1.0, 1.0]:
			for z in [-1.0, 1.0]:
				dirs.append(Vector3(x, y, z).normalized())
	_self_test()


func _shape_q(shape: Shape3D, mask: int) -> PhysicsShapeQueryParameters3D:
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.collision_mask = mask
	return q


## The probes must be able to fail: check them against known spots of the park first.
func _self_test() -> void:
	var ex := _non_park_rids()
	var floor_pt := Vector3(0.0, 0.02, -20.5)      # open floor between the funbox and ledge B
	var air_pt := Vector3(0.0, 3.0, -20.5)         # 3 m above it, nothing near
	var down := Transform3D(Basis.IDENTITY, floor_pt + Vector3.UP * 0.01).looking_at(floor_pt + Vector3.DOWN * 2.0, Vector3.FORWARD)
	var fwd := Transform3D(Basis.IDENTITY, air_pt).looking_at(air_pt + Vector3.FORWARD * 2.0, Vector3.UP)
	# a rafter hanger rod (Park_steel, 3 cm radius, no collision) hangs at x -18.8, z -28
	var rod_pt := Vector3(-18.8 + 0.07, 8.0, -28.0)                       # 4 cm from its surface
	var rod_cam := Transform3D(Basis.IDENTITY, Vector3(-18.8, 8.0, -27.955)).looking_at(Vector3(-18.8, 8.0, -30.0), Vector3.UP)
	var funbox_pt := Vector3(0.0, 0.45, -16.5)                             # inside the funbox
	var deck_pt := Vector3(0.0, 2.5, 12.0)                                  # inside the start deck block
	var ci_f := _inside(funbox_pt, false, ex)
	var vi_f := _inside(funbox_pt, true, ex)
	var ci_d := _inside(deck_pt, false, ex)
	var vi_d := _inside(deck_pt, true, ex)
	var ci_o := _inside(air_pt, false, ex)
	var vi_o := _inside(air_pt, true, ex)
	var glass := _vray(Vector3(15.0, 4.8, -20.2), Vector3(25.0, 4.8, -20.2), false, true)
	var glass_opaque := _vray(Vector3(15.0, 4.8, -20.2), Vector3(25.0, 4.8, -20.2), true, true)
	selftest = [
		[_overlaps(sphere_q, Transform3D(Basis.IDENTITY, floor_pt), ex) != null, "clip sphere 2 cm above the floor touches the collision"],
		[_overlaps(sphere_q, Transform3D(Basis.IDENTITY, air_pt), ex) == null, "clip sphere in open air is clear"],
		[_overlaps(frustum_q, down, ex) != null, "near-clip volume looking into the floor cuts the collision"],
		[_overlaps(frustum_q, fwd, ex) == null, "near-clip volume in open air is clear"],
		[not _ray(air_pt, Vector3(30.0, 3.0, -20.5), ex, true).is_empty(), "collision ray through the east wall is occluded"],
		[_ray(air_pt, air_pt + Vector3(0.0, 0.0, -3.0), ex, true).is_empty(), "collision ray through open air is clear"],
		[_vshape(vsphere_q, Transform3D(Basis.IDENTITY, rod_pt)).has("Park_steel")
				and _overlaps(sphere_q, Transform3D(Basis.IDENTITY, rod_pt), ex) == null,
				"clip sphere 4 cm from a rafter hanger rod touches the rendered rod (which has no collision)"],
		[_vshape(vsphere_q, Transform3D(Basis.IDENTITY, air_pt)).is_empty(), "rendered clip sphere in open air is clear"],
		[_vshape(vfrustum_q, rod_cam).has("Park_steel") and _vshape(vfrustum_q, fwd).is_empty(),
				"near-clip volume 1.5 cm in front of a hanger rod cuts it; in open air it is clear"],
		[_vray(Vector3(-18.8, 8.0, -27.0), Vector3(-18.8, 8.0, -29.0), true, true).get("name", "") == "Park_steel"
				and _ray(Vector3(-18.8, 8.0, -27.0), Vector3(-18.8, 8.0, -29.0), ex, true).is_empty(),
				"rendered ray along the rafter line is blocked by a hanger rod (the collision ray is not)"],
		[String(glass.get("name", "")).begins_with("Window_") and not String(glass_opaque.get("name", "")).begins_with("Window_"),
				"window glass is rendered geometry for clipping but does not hide the skater (%s / %s)" % [
				glass.get("name", "-"), glass_opaque.get("name", "-")]],
		[ci_f[0] * 2 > ci_f[1] and vi_f[0] * 2 > vi_f[1] and ci_d[0] * 2 > ci_d[1] and vi_d[0] * 2 > vi_d[1],
				"inside-a-solid probe flags points inside the funbox (%d/%d, %d/%d back faces) and the start deck block (%d/%d, %d/%d)" % [
				ci_f[0], ci_f[1], vi_f[0], vi_f[1], ci_d[0], ci_d[1], vi_d[0], vi_d[1]]],
		[ci_o[0] == 0 and vi_o[0] == 0 and ci_o[1] >= 8 and vi_o[1] >= 10,
				"inside-a-solid probe sees only front faces in open air (%d/%d, %d/%d)" % [ci_o[0], ci_o[1], vi_o[0], vi_o[1]]],
		[_in_box(Vector3(0, 3, 0), hall) and _in_box(Vector3(-25, 2, -37), room), "hall / secret room contain known points"],
		[not (_in_box(Vector3(25, 3, 0), hall) or _in_box(Vector3(-25, 2, -20), room) or _in_box(Vector3(-25, 2, -20), hall)
				or _in_box(Vector3(0, 12, 0), hall) or _in_box(Vector3(-25, 5.5, -37), room)),
				"points outside the walls / above the roof / above the secret room ceiling are outside"],
		[hall.position.is_equal_approx(Vector3(-20, 0, -50)) and hall.end.is_equal_approx(Vector3(20, 11.5, 16)),
				"hall bounds match the 40 x 66 x 11.5 m hall"],
		[cam.keep_aspect == Camera3D.KEEP_HEIGHT, "the camera keeps height (fov is vertical), as the aspect handling assumes"],
		[vis_bodies.size() >= 30, "rendered geometry: %d park meshes copied" % vis_bodies.size()],
	]


## Once the camera has placed itself: the frustum maths used for framing must agree with
## the engine's own frustum test at the real viewport.
func _framing_self_test() -> void:
	var disagree := 0
	var inside := 0
	var n := 0
	var xf: Transform3D = cam.global_transform
	var tv := tan(deg_to_rad(cam.fov) * 0.5)
	for iy in range(-6, 7):
		for ix in range(-9, 10):
			for dz in [0.5, 3.0, 12.0]:
				var lp := Vector3(ix / 6.0 * tv * aspect_view * dz * 1.2, iy / 6.0 * tv * dz * 1.2, -dz)
				# skip points within 2 % of an edge (rounding)
				if absf(absf(lp.x) - tv * aspect_view * dz) < 0.02 * dz or absf(absf(lp.y) - tv * dz) < 0.02 * dz:
					continue
				var p: Vector3 = xf * lp
				n += 1
				var mine := _on_screen(p, aspect_view)
				inside += int(mine)
				if mine != cam.is_position_in_frustum(p):
					disagree += 1
	var behind: bool = not _on_screen(xf * Vector3(0, 0, 2.0), aspect_frame) and not cam.is_position_in_frustum(xf * Vector3(0, 0, 2.0))
	selftest.append([disagree == 0 and inside > 50 and inside < n and behind,
			"framing maths agrees with the engine's frustum at the real %dx%d viewport (%d points, %d on screen, %d disagree; behind the camera is off screen)" % [
			vp_size.x, vp_size.y, n, inside, disagree]])


## After the run / the drills: hidden meshes must drop out of the rendered geometry - rays
## through every broken window pass its glass and hit it at every whole one, and the ray
## through the doorway hits the boarded wall only while it stands.
func _visibility_self_test() -> void:
	var ok := true
	var n_b := 0
	var n_u := 0
	for w in main.level.windows:
		var c: Vector3 = w["center"] + Vector3(0.0, -0.6, -0.8)       # beside the mullion
		var r := _vray(Vector3(15.0, c.y, c.z), Vector3(25.0, c.y, c.z), false, true)
		var hit_glass: bool = w["node"] != null and String(r.get("name", "")) == String(w["node"].name)
		if w["broken"]:
			n_b += 1
			ok = ok and not hit_glass
		else:
			n_u += 1
			ok = ok and hit_glass
	var rw := _vray(Vector3(-17.0, 1.0, -36.5), Vector3(-23.0, 1.0, -36.5), false, true)
	var wall_hit := String(rw.get("name", "")).begins_with("BreakWall")
	var down: bool = main.level.wall_broken_flag
	ok = ok and wall_hit != down
	selftest.append([ok, "hidden meshes drop out of the rendered geometry (%d broken windows passed, %d whole ones hit; boarded wall %s, doorway ray hit %s)" % [
			n_b, n_u, "down" if down else "standing", rw.get("name", "nothing")]])


func _row(name: String) -> Dictionary:
	if not rows.has(name):
		var r := {"frames": 0, "visits": 0, "min_dist": INF, "blocked_pts": 0}
		for f in FLAGS:
			r[f] = 0
		rows[name] = r
	return rows[name]


# ------------------------------------------------------------------ per-frame sampling

## MainLoop._process runs after this iteration's physics step and before any node's
## _process (so before main.gd can end the run and quit) - i.e. it sees exactly the
## camera and skater of the frame about to be drawn, including the very last one.
func _process(_delta: float) -> bool:
	if main == null or not is_instance_valid(main) or not main.is_node_ready():
		return false
	if not setup_done:
		_setup()
	if drill_mode:
		_drill_tick()
		return false
	var pf := Engine.get_physics_frames()
	# the camera places itself in its first physics step: nothing to measure before that
	var active: bool = main.running and not paused and pf > pf_init
	if active and not run_started:
		run_started = true
		run_frame0 = pf - 1
		last_phys = pf - 1
		first_measured_phys = pf - int(main.run_start_phys)      # 1 = the run's very first physics step
	if active and pf != last_phys:
		frames_skipped += maxi(0, pf - last_phys - 1)
		last_phys = pf
		if frames_measured == 0:
			_framing_self_test()
			_visibility_self_test()       # every window whole, the wall standing
		var t := float(last_phys - run_frame0) / float(Engine.physics_ticks_per_second)
		var s := _measure(t)
		_run_keys(s)
		if not vis_late_done and main.level.windows_broken() == main.level.windows.size() and main.level.wall_broken_flag:
			vis_late_done = true
			_visibility_self_test()       # once the run has broken them all
		if frames_measured % PROGRESS_EVERY == 0:
			_write_report(false)
	if run_started and pf - run_frame0 > WATCHDOG_FRAMES and not finished_written:
		_snapshot_end()
		_finish_report()
	return false


func _park_body(o: Object) -> bool:
	return o != null and is_instance_valid(o) and o is Node and main.level.is_ancestor_of(o)


func _non_park_rids() -> Array[RID]:
	var ex: Array[RID] = [sk.hitbox.get_rid()]
	for n in main.get_children():
		if n is CollisionObject3D:
			ex.append(n.get_rid())
	return ex


func _overlaps(q: PhysicsShapeQueryParameters3D, xf: Transform3D, ex: Array[RID]) -> Object:
	q.transform = xf
	q.exclude = ex
	for r in root.get_world_3d().direct_space_state.intersect_shape(q, 8):
		if _park_body(r["collider"]):
			return r["collider"]
	return null


## Ray against the park collision (the game's world). back = also hit back faces.
func _ray(from: Vector3, to: Vector3, ex: Array[RID], back: bool) -> Dictionary:
	var space := root.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to, 1, ex)
	q.hit_back_faces = back
	for i in 6:
		var r := space.intersect_ray(q)
		if r.is_empty():
			return {}
		if _park_body(r["collider"]):
			r["name"] = String(r["collider"].name)
			return r
		var e := q.exclude
		e.append(r["rid"])
		q.exclude = e
	return {}


func _vshown(rid: RID) -> Dictionary:
	var info = vis_info.get(rid)
	if info == null or not is_instance_valid(info["node"]) or not info["node"].is_visible_in_tree():
		return {}
	return info


## Ray against the rendered park geometry (private space). opaque = skip the window glass.
func _vray(from: Vector3, to: Vector3, opaque: bool, back: bool) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to, 1)
	q.hit_back_faces = back
	var ex: Array[RID] = []
	for i in 12:
		q.exclude = ex
		var r := vis_world.direct_space_state.intersect_ray(q)
		if r.is_empty():
			return {}
		var info := _vshown(r["rid"])
		if not info.is_empty() and not (opaque and info["clear"]):
			r["name"] = info["name"]
			return r
		ex.append(r["rid"])
	return {}


## Names of the drawn park meshes that touch the query shape.
func _vshape(q: PhysicsShapeQueryParameters3D, xf: Transform3D) -> Array:
	q.transform = xf
	var out := []
	for r in vis_world.direct_space_state.intersect_shape(q, 32):
		var info := _vshown(r["rid"])
		if not info.is_empty() and not out.has(info["name"]):
			out.append(info["name"])
	return out


## [back-face directions, directions that hit anything, first back face seen]: in open
## space the first surface in every direction is a front face; inside a closed body (a
## ramp, the deck block) or behind a one-sided wall the first surface is a back face.
func _inside(p: Vector3, rendered: bool, ex: Array[RID]) -> Array:
	var back := 0
	var hits := 0
	var what := ""
	for d in dirs:
		var to := p + d * INSIDE_RANGE
		var a := _vray(p, to, false, true) if rendered else _ray(p, to, ex, true)
		if a.is_empty():
			continue
		hits += 1
		var f := _vray(p, to, false, false) if rendered else _ray(p, to, ex, false)
		var da := p.distance_to(a["position"])
		var df := INF if f.is_empty() else p.distance_to(f["position"])
		if da < df - 0.002:
			back += 1
			if what == "":
				what = "%s@%s" % [a["name"], _v(a["position"])]
	return [back, hits, what]


func _on_screen(p: Vector3, aspect: float) -> bool:
	var lp: Vector3 = cam.global_transform.affine_inverse() * p
	var depth := -lp.z
	if depth <= cam.near or depth >= cam.far:
		return false
	var tv := tan(deg_to_rad(cam.fov) * 0.5)
	return absf(lp.y) <= depth * tv and absf(lp.x) <= depth * tv * aspect


func _area(p: Vector3) -> String:
	if _in_box(p, room):
		return "secret room"
	if main.level.in_halfpipe(p):
		return "halfpipe"
	if p.z > 6.0 and p.y > 3.0 and absf(p.x) < 9.0:
		return "start deck / drop-in"
	if p.y > 4.0 and p.z > -25.5 and (p.x < -16.5 or (p.z > 13.0 and p.x < -7.5)):
		return "catwalk"
	if p.y > 4.5 and p.z <= -25.5 and p.x < -16.0:
		return "west rafter"
	if p.x > 13.5:
		return "east quarterpipe / wall pipe"
	return "street / floor"


## Which vert wall a vert air is on.
func _vert_loc(p: Vector3) -> String:
	if _in_box(p, room.grow(0.5)):
		return "secret room quarter"
	if main.level.in_halfpipe(p):
		return "halfpipe"
	if p.x > 16.0:
		return "east quarterpipe"
	if p.z > 11.0 and p.x > 8.0:
		return "south-east quarter"
	return "elsewhere"


func _in_box(p: Vector3, b: AABB) -> bool:
	var e := b.end
	return p.x >= b.position.x and p.x <= e.x and p.y >= b.position.y and p.y <= e.y and p.z >= b.position.z and p.z <= e.z


func _measure(t: float) -> Dictionary:
	frames_measured += 1
	var cp: Vector3 = cam.global_position
	var sp: Vector3 = sk.global_position
	var ex := _non_park_rids()
	var mb: Basis = sk.model.global_transform.basis
	var bup := mb.y.normalized()
	var bright := mb.x.normalized()
	var upper := sp + Vector3.UP * LOS_HEIGHT
	var at_cam := Transform3D(Basis.IDENTITY, cp)
	var s := {"t": t, "sp": sp, "cp": cp}
	# line of sight
	var ch := _ray(cp, upper, ex, true)
	var vh := _vray(cp, upper, true, true)
	s["col_occ"] = not ch.is_empty()
	s["vis_occ"] = not vh.is_empty()
	var blocked := 0
	for bp in BODY_PTS:
		if not _vray(cp, sp + bup * float(bp[0]) + bright * float(bp[1]), true, true).is_empty():
			blocked += 1
	s["blocked_pts"] = blocked
	s["hidden"] = blocked == BODY_PTS.size()
	# clipping
	var cc = _overlaps(sphere_q, at_cam, ex)
	var cn = _overlaps(frustum_q, cam.global_transform, ex)
	var vc := _vshape(vsphere_q, at_cam)
	var vn := _vshape(vfrustum_q, cam.global_transform)
	s["col_clip"] = cc != null
	s["col_nv"] = cn != null
	s["vis_clip"] = not vc.is_empty()
	s["vis_nv"] = not vn.is_empty()
	margin_shape.radius = 0.15
	s["col15"] = _overlaps(margin_q, at_cam, ex) != null
	margin_shape.radius = 0.30
	s["col30"] = s["col15"] or _overlaps(margin_q, at_cam, ex) != null
	vmargin_shape.radius = 0.15
	var v15 := _vshape(vmargin_q, at_cam)
	vmargin_shape.radius = 0.30
	var v30 := v15 if not v15.is_empty() else _vshape(vmargin_q, at_cam)
	s["vis15"] = not v15.is_empty()
	s["vis30"] = not v30.is_empty()
	# inside a solid / outside the hall
	var ci := _inside(cp, false, ex)
	var vi := _inside(cp, true, ex)
	s["col_in"] = ci[0] * 2 > ci[1]
	s["vis_in"] = vi[0] * 2 > vi[1]
	s["outside"] = not (_in_box(cp, hall) or _in_box(cp, room))
	# distance and framing
	var body_pt := Geometry3D.get_closest_point_to_segment(cp, sp, sp + bup * BODY_LEN)
	var dist := cp.distance_to(body_pt)
	s["dist"] = dist
	s["close"] = dist < TOO_CLOSE
	s["off_mid"] = not _on_screen(sp + bup * 0.9, aspect_frame)
	s["off_edge"] = not (_on_screen(sp + bup * 0.1, aspect_frame) and _on_screen(sp + bup * BODY_LEN, aspect_frame))
	if not sk.model.visible:
		model_hidden += 1
	# skater state
	var st: int = sk.state
	var vert: bool = st == sk.AIR and sk.vert_air
	var grind: bool = st == sk.GRIND
	s["st"] = st
	s["vert"] = vert
	s["grind"] = grind
	s["rail"] = (String(sk.grind_rail.name) if sk.grind_rail else "?") if grind else ""
	s["area"] = _area(sp)
	s["vloc"] = _vert_loc(sp) if vert else ""
	for nm in vc:
		_bump("clip sphere: " + nm)
	for nm in vn:
		_bump("near-clip volume: " + nm)
	if s["vis_occ"]:
		_bump("line of sight: " + vh["name"])
	var what := "%s%s @ %s cam %s  %s%s" % [cur_tag + "  " if cur_tag != "" else "", _state_name(st, vert), _v(sp), _v(cp),
			s["area"], _ap_step()]
	s["what"] = what
	if dist < min_dist:
		min_dist = dist
		min_dist_info = "t=%.2f s  %s" % [t, what]
	if cc:
		_event("col_clip", t, "%s touches the camera sphere  %s" % [cc.name, what])
	if cn:
		_event("col_nv", t, "%s inside the near-clip volume  %s" % [cn.name, what])
	if not vc.is_empty():
		_event("vis_clip", t, "%s within %.3f m of the camera  %s" % [", ".join(vc), clip_r, what])
	if not vn.is_empty():
		_event("vis_nv", t, "%s inside the near-clip volume  %s" % [", ".join(vn), what])
	if s["col_in"]:
		_event("col_in", t, "%d of %d directions see a back face first (%s)  %s" % [ci[0], ci[1], ci[2], what])
	if s["vis_in"]:
		_event("vis_in", t, "%d of %d directions see a back face first (%s)  %s" % [vi[0], vi[1], vi[2], what])
	if s["outside"]:
		_event("outside", t, what)
	if s["close"]:
		_event("close", t, "%.2f m  %s" % [dist, what])
	if s["off_mid"]:
		_event("off_mid", t, what)
	if s["hidden"]:
		_event("hidden", t, "%s" % what)
	_stretch("col", s["col_occ"], t, ch, what, _state_name(st, vert))
	_stretch("vis", s["vis_occ"], t, vh, what, _state_name(st, vert))
	_episode(s, t)
	return s


func _bump(k: String) -> void:
	mesh_hits[k] = int(mesh_hits.get(k, 0)) + 1


func _stretch(kind: String, occ: bool, t: float, hit: Dictionary, what: String, st_name: String) -> void:
	var cur: Dictionary = stretch[kind]
	if occ:
		if cur.is_empty():
			cur = {"t0": t, "t1": t, "frames": 0, "clock": main.time_left, "what": what, "blockers": {}, "states": {}}
			stretch[kind] = cur
		cur["t1"] = t
		cur["frames"] += 1
		cur["blockers"][String(hit["name"])] = "%s@%s" % [hit["name"], _v(hit["position"])]
		cur["states"][st_name] = true
	elif not cur.is_empty():
		stretches[kind].append(cur)
		stretch[kind] = {}


func _close_stretches() -> void:
	for kind in ["col", "vis"]:
		if not stretch[kind].is_empty():
			stretches[kind].append(stretch[kind])
			stretch[kind] = {}


func _episode(s: Dictionary, t: float) -> void:
	var ep_kind := ""
	if s["vert"]:
		ep_kind = "vert air"
	elif s["grind"]:
		ep_kind = "grind " + s["rail"]
	if not cur_ep.is_empty() and cur_ep["kind"] != ep_kind:
		episodes.append(cur_ep)
		cur_ep = {}
	if ep_kind != "" and cur_ep.is_empty():
		if s["vert"]:
			vert_airs += 1
		else:
			grinds += 1
		cur_ep = {"kind": ep_kind, "t0": t, "t1": t, "frames": 0, "col_occ": 0, "vis_occ": 0, "clip": 0, "inside": 0,
				"outside": 0, "close": 0, "min_dist": INF, "max_y": -INF, "where": s["vloc"] if s["vert"] else s["area"],
				"pos": s["sp"], "tag": cur_tag}
	if not cur_ep.is_empty():
		cur_ep["t1"] = t
		cur_ep["frames"] += 1
		cur_ep["col_occ"] += int(s["col_occ"])
		cur_ep["vis_occ"] += int(s["vis_occ"])
		cur_ep["clip"] += int(s["col_clip"] or s["col_nv"] or s["vis_clip"] or s["vis_nv"])
		cur_ep["inside"] += int(s["col_in"] or s["vis_in"])
		cur_ep["outside"] += int(s["outside"])
		cur_ep["close"] += int(s["close"])
		cur_ep["min_dist"] = minf(cur_ep["min_dist"], s["dist"])
		cur_ep["max_y"] = maxf(cur_ep["max_y"], s["sp"].y)


func _close_episode() -> void:
	if not cur_ep.is_empty():
		episodes.append(cur_ep)
		cur_ep = {}


func _accumulate(keys: Array, s: Dictionary) -> void:
	for k in keys:
		var r := _row(k)
		r["frames"] += 1
		r["visits"] += int(not prev_keys.has(k))
		for f in FLAGS:
			r[f] += int(s[f])
		r["blocked_pts"] += int(s["blocked_pts"])
		r["min_dist"] = minf(r["min_dist"], s["dist"])
	prev_keys = keys


func _run_keys(s: Dictionary) -> void:
	var keys: Array = ["all", "area: " + s["area"]]
	if s["vert"]:
		keys.append("vert air")
		keys.append("  vert air: " + s["vloc"])
	if s["grind"]:
		keys.append("grind")
		keys.append("  grind: " + s["rail"])
	_accumulate(keys, s)


func _event(kind: String, t: float, msg: String) -> void:
	var a: Array = events[kind]
	if a.size() < 25:
		a.append("t=%.2f s  %s" % [t, msg])


func _state_name(st: int, vert: bool) -> String:
	if st == sk.GROUND:
		return "MANUAL" if sk.manual != "" else "GROUND"
	if st == sk.AIR:
		return "VERT AIR" if vert else "AIR"
	if st == sk.GRIND:
		return "GRIND " + (String(sk.grind_rail.name) if sk.grind_rail else "")
	if st == sk.BAIL:
		return "BAIL"
	return str(st)


func _ap_step() -> String:
	if ap == null or ap.step >= ap.route.size():
		return ""
	return "  [route step %d: %s]" % [ap.step, String(ap.route[ap.step].get("note", ""))]


func _v(p: Vector3) -> String:
	return "(%.1f, %.1f, %.1f)" % [p.x, p.y, p.z]


# ------------------------------------------------------------------ criteria

func _pct(n: int, d: int) -> String:
	return "%.2f%%" % (100.0 * n / maxf(1.0, d))


func _frac(r: Dictionary, f: String) -> float:
	return float(r[f]) / maxf(1.0, float(r["frames"]))


## All camera criteria for one group of frames (everything) and its vert-air frames:
## [ok, summary, failed parts].
func _crit(all_r: Dictionary, vert_r: Dictionary) -> Array:
	var bad: PackedStringArray = []
	for f in ["col_clip", "col_nv", "vis_clip", "vis_nv", "col_in", "vis_in", "outside", "off_mid", "hidden"]:
		if all_r[f] > 0:
			bad.append("%s %d" % [LABELS[f], all_r[f]])
	if _frac(all_r, "close") >= MAX_TOO_CLOSE:
		bad.append("<0.9m %s" % _pct(all_r["close"], all_r["frames"]))
	if _frac(all_r, "off_edge") >= MAX_EDGE_OFF:
		bad.append("head/feet off screen %s" % _pct(all_r["off_edge"], all_r["frames"]))
	if vert_r["frames"] == 0:
		bad.append("no vert-air frames")
	if _frac(vert_r, "col_occ") >= MAX_OCCLUDED:
		bad.append("vert air occluded (collision) %s" % _pct(vert_r["col_occ"], vert_r["frames"]))
	if _frac(vert_r, "vis_occ") >= MAX_OCCLUDED:
		bad.append("vert air occluded (rendered) %s" % _pct(vert_r["vis_occ"], vert_r["frames"]))
	var txt := "%d frames (%d in vert air): clip col/rend %d/%d, near-clip volume %d/%d, inside a solid %d/%d, outside %d, completely hidden %d, body centre off screen %d (all must be 0); vert air occluded col %s / rend %s (< 2%%); <0.9m %s (< 1%%); head/feet off screen %s (< 1%%); closest %.2f m" % [
			all_r["frames"], vert_r["frames"], all_r["col_clip"], all_r["vis_clip"], all_r["col_nv"], all_r["vis_nv"],
			all_r["col_in"], all_r["vis_in"], all_r["outside"], all_r["hidden"], all_r["off_mid"],
			_pct(vert_r["col_occ"], vert_r["frames"]), _pct(vert_r["vis_occ"], vert_r["frames"]),
			_pct(all_r["close"], all_r["frames"]), _pct(all_r["off_edge"], all_r["frames"]), all_r["min_dist"]]
	return [bad.is_empty() and all_r["frames"] > 0, txt, ", ".join(bad)]


func _table(order: Array) -> PackedStringArray:
	var tab: PackedStringArray = []
	tab.append("%-44s %6s %6s %5s %6s %5s %6s %9s %9s %9s %7s %6s %7s %9s %9s %6s %9s %8s" % ["frames by category", "visits",
			"frames", "occ c", "occ c%", "occ r", "occ r%", "clip c/r", "nvol c/r", "in c/r", "outside", "<0.9m",
			"closest", "rend<.15m", "rend<.30m", "hidden", "off c/edge", "body blk"])
	for k in order:
		if not rows.has(k) or rows[k]["frames"] == 0:
			tab.append("%-44s %6d %6d" % [k, 0, 0])
			continue
		var r: Dictionary = rows[k]
		tab.append("%-44s %6d %6d %5d %6s %5d %6s %9s %9s %9s %7d %6d %6.2fm %9d %9d %6d %9s %8s" % [k, r["visits"], r["frames"],
				r["col_occ"], _pct(r["col_occ"], r["frames"]), r["vis_occ"], _pct(r["vis_occ"], r["frames"]),
				"%d/%d" % [r["col_clip"], r["vis_clip"]], "%d/%d" % [r["col_nv"], r["vis_nv"]], "%d/%d" % [r["col_in"], r["vis_in"]],
				r["outside"], r["close"], r["min_dist"], r["vis15"], r["vis30"], r["hidden"],
				"%d/%d" % [r["off_mid"], r["off_edge"]],
				"%.1f%%" % (100.0 * r["blocked_pts"] / maxf(1.0, r["frames"] * BODY_PTS.size()))])
	tab.append("(occ c / occ r = ray camera -> skater + %.1f m blocked by park collision / by rendered opaque geometry; clip = geometry within %.3f m of the camera;" % [LOS_HEIGHT, clip_r])
	tab.append(" nvol = geometry inside the near-clip pyramid; in = camera inside a solid (most directions see a back face first); c/r = collision/rendered;")
	tab.append(" <0.9m = camera closer than 0.9 m to the skater's feet-to-head axis; rend<.15m/.30m = rendered geometry within 15/30 cm (margin, info);")
	tab.append(" hidden = all %d body points blocked; off c/edge = body centre / head or feet outside the frustum; body blk = share of body points blocked, info)" % BODY_PTS.size())
	return tab


func _stretch_lines(kind: String, label: String, n_occ: int) -> PackedStringArray:
	var out: PackedStringArray = []
	var st: Array = stretches[kind].duplicate()
	if not stretch[kind].is_empty():
		st.append(stretch[kind])
	st.sort_custom(func(a, b): return a["frames"] > b["frames"])
	out.append("worst occlusion stretches, %s (%d stretches, %d occluded frames; t = %s):" % [label, st.size(), n_occ,
			"drill time" if drill_mode else "run time from the drop-in, clock = time left"])
	if st.is_empty():
		out.append("  none")
	for i in mini(12, st.size()):
		var s: Dictionary = st[i]
		out.append("  %2d. t=%6.2f-%6.2f s  %3d fr  %s%s  blocked by %s  at start: %s" % [i + 1, s["t0"], s["t1"], s["frames"],
				"" if drill_mode else "clock %s  " % _clock(s["clock"]), "/".join(s["states"].keys()),
				", ".join(s["blockers"].values()), s["what"]])
	return out


func _episode_lines() -> PackedStringArray:
	var out: PackedStringArray = []
	var eps := episodes.duplicate()
	if not cur_ep.is_empty():
		eps.append(cur_ep)
	for e in eps:
		out.append("  t=%6.2f-%6.2f s  %s%-22s %-34s %3d fr  top y %5.2f  occluded col %d / rend %d  clip %d  inside %d  outside %d  <0.9m %d  closest %.2f m" % [
				e["t0"], e["t1"], e["tag"] + "  " if e["tag"] != "" else "", e["kind"], e["where"] + " " + _v(e["pos"]),
				e["frames"], e["max_y"], e["col_occ"], e["vis_occ"], e["clip"], e["inside"], e["outside"], e["close"],
				e["min_dist"]])
	return out


func _event_lines() -> PackedStringArray:
	var out: PackedStringArray = []
	for kind in EVENT_TITLES:
		var ev: Array = events[kind]
		if ev.is_empty():
			continue
		out.append("")
		out.append(EVENT_TITLES[kind])
		for e in ev:
			out.append("  " + e)
	return out


func _mesh_hit_line() -> String:
	var ks := mesh_hits.keys()
	ks.sort()
	var parts: PackedStringArray = []
	for k in ks:
		parts.append("%s %d" % [k, mesh_hits[k]])
	return "rendered park meshes involved (frames): " + ("none" if parts.is_empty() else ", ".join(parts))


func _geometry_lines() -> PackedStringArray:
	var out: PackedStringArray = []
	out.append("hall bounds (park collision AABB, west edge = secret room east edge): %s - %s; secret room (park data): %s - %s" % [
			_v(hall.position), _v(hall.end), _v(room.position), _v(room.end)])
	out.append("clip sphere radius %.3f m (cam.near %.2f x 1.5); near-clip pyramid %.3f m deep, fov %.0f deg (vertical), aspect %.2f (widest of the real %dx%d viewport and 21:9); framing at aspect %.2f (narrowest of the real viewport and 4:3)" % [
			clip_r, cam_near, cam_near, cam_fov, aspect_near, vp_size.x, vp_size.y, aspect_frame])
	out.append("rendered geometry: %d park meshes as trimesh copies in a private physics space (window glass counts for clipping, not for line of sight; pickups and debris are not park geometry)" % vis_bodies.size())
	out.append("closest camera-to-body distance %.2f m at %s" % [min_dist, min_dist_info])
	out.append("frames with the skater model hidden by the camera's too-close failsafe: %d" % model_hidden)
	out.append(_mesh_hit_line())
	return out


# ------------------------------------------------------------------ drills (child process)

func _drill_defs() -> Array:
	var d: Array = []
	# east quarterpipe: rises toward +x from x 16.4, coping x 19.2 at 3.2 m, window wall x 20
	# (glass 4.4..6.4 m), wall pipe at 4 m; lanes clear of the barrels, rail, ledge and pallets
	# (speeds 12 .. 14 m/s give airs from the coping up into the glass)
	for lane in [[-45.6, 12.3, 12.5, "north-east corner (4 m from the north wall)"], [-42.6, 11.5, 13.5, "under rafter_east"],
			[-29.8, 11.5, 12.0, "window 4"], [-24.6, 10.0, 13.0, "window 3"], [-19.4, 11.5, 14.0, "window 2"],
			[-9.0, 10.0, 12.0, "window 0"], [2.0, 10.0, 13.0, "south of the windows"], [10.0, 10.5, 12.5, "south-east end"]]:
		d.append({"name": "east QP z=%.1f %s" % [lane[0], lane[3]], "group": G_EAST, "pos": Vector3(lane[1], 0.0, lane[0]),
				"fwd": Vector3(1, 0, 0), "speed": lane[2], "airs": 1, "max_s": 5.0, "pump": false})
	d.append({"name": "east QP angled north (27 deg)", "group": G_EAST, "pos": Vector3(10.5, 0.0, -14.0),
			"fwd": Vector3(1, 0, -0.5), "speed": 12.5, "airs": 1, "max_s": 5.0, "pump": false})
	d.append({"name": "east QP angled south (27 deg)", "group": G_EAST, "pos": Vector3(10.5, 0.0, -6.0),
			"fwd": Vector3(1, 0, 0.5), "speed": 13.5, "airs": 1, "max_s": 5.0, "pump": false})
	# south-east corner quarter: rises toward +z from z 12.8, coping z 15.2 at 2.4 m, south wall z 16
	for x in [9.6, 12.2]:
		d.append({"name": "SE quarter x=%.1f" % x, "group": G_SE, "pos": Vector3(x, 0.0, 1.0), "fwd": Vector3(0, 0, 1),
				"speed": 10.5, "airs": 1, "max_s": 5.0, "pump": false})
	# secret room: through the boarded doorway (the first run smashes it) to the 2 m mini
	# quarter on the far wall (lip x -29.4) under the room's 5 m ceiling
	for z in [-38.6, -35.2]:
		d.append({"name": "secret room quarter z=%.1f" % z, "group": G_ROOM, "pos": Vector3(-12.0, 0.0, z),
				"fwd": Vector3(-1, 0, 0), "speed": 10.0, "airs": 1, "max_s": 6.0, "pump": false})
	# halfpipe: pumping airs along its north edge (1 m from the north wall) and its open end
	for z in [-48.2, -37.8]:
		d.append({"name": "halfpipe z=%.1f" % z, "group": G_HP, "pos": Vector3(0.0, 0.0, z), "fwd": Vector3(-1, 0, 0),
				"speed": 10.0, "airs": 0, "max_s": 10.0, "pump": true})
	return d


func _release_all() -> void:
	for a in ["up", "down", "left", "right", "jump", "flip", "grab", "grind"]:
		Input.action_release(a)


func _drill_tick() -> void:
	var pf := Engine.get_physics_frames()
	if pf == last_phys:
		return
	last_phys = pf
	if pf - pf_init > DRILL_WATCHDOG_FRAMES and not finished_written:
		var f := FileAccess.open(DRILL_JSON, FileAccess.WRITE)
		f.store_string(JSON.stringify({"finished": false, "error": "drill watchdog: still at drill %d of %d after %d frames" % [
				di + 1, drill_list.size(), pf - pf_init]}))
		f.close()
		finished_written = true
		quit(1)
		return
	if drill_list.is_empty():
		drill_list = _drill_defs()
		main.start_run()
		sk.bailed.connect(func(_r): d_bails += 1)
		return
	if d_spawned:
		var d: Dictionary = drill_list[di]
		if frames_measured == 0:
			_framing_self_test()
		d_frame += 1
		var s := _measure(d_frame / 60.0)
		var keys: Array = ["drills (all frames)", d["group"], "    " + d["name"]]
		if s["vert"]:
			keys.append("drills vert air")
			keys.append("  vert air: " + d["group"])
			keys.append("~vert " + d["name"])      # per drill, for the failure details only
			d_vert_frames += 1
			d_top = maxf(d_top, s["sp"].y)
		_accumulate(keys, s)
		if s["vert"] and not d_was_vert:
			d_airs += 1
		if d_was_vert and not s["vert"]:
			d_last_land = d_frame
		d_was_vert = s["vert"]
		var done: bool = d_frame >= int(d["max_s"] * 60.0)
		if d["airs"] > 0 and d_airs >= d["airs"] and d_last_land > 0 and d_frame - d_last_land >= 60:
			done = true
		if done:
			_close_stretches()
			_close_episode()
			var r: Dictionary = rows["    " + d["name"]]
			d_summaries.append({"name": d["name"], "group": d["group"], "frames": d_frame, "airs": d_airs,
					"vert_frames": d_vert_frames, "top": d_top, "bails": d_bails,
					"windows": main.level.windows_broken() - d_windows0, "wall": main.level.wall_broken_flag, "row": r.duplicate()})
			di += 1
			d_spawned = false
	if not d_spawned:
		_release_all()
		if di >= drill_list.size():
			_finish_drills()
			return
		var nd: Dictionary = drill_list[di]
		cur_tag = "[%s]" % nd["name"]
		main.time_left = main.RUN_TIME
		sk.spawn(nd["pos"], nd["fwd"].normalized(), nd["speed"])
		cam.snap()
		d_spawned = true
		d_frame = 0
		d_airs = 0
		d_vert_frames = 0
		d_top = -INF
		d_last_land = -1
		d_was_vert = false
		d_bails = 0
		d_windows0 = main.level.windows_broken()
		prev_keys = []
	# inputs for the coming physics step: push until the first vert air, or pump the halfpipe
	var cd: Dictionary = drill_list[di]
	var push: bool
	if cd["pump"]:
		push = sk.state == sk.GROUND and sk.up.y < 0.8
	else:
		push = d_airs == 0 and sk.state == sk.GROUND
	if push:
		Input.action_press("up")
	else:
		Input.action_release("up")


func _finish_drills() -> void:
	_visibility_self_test()
	var checks: Array = []
	var no_air := d_summaries.filter(func(x): return x["airs"] == 0).map(func(x): return x["name"])
	var bad := selftest.filter(func(x): return not x[0]).map(func(x): return x[1])
	var airs := 0
	for x in d_summaries:
		airs += int(x["airs"])
	checks.append([no_air.is_empty() and d_summaries.size() == drill_list.size() and bad.is_empty(),
			"wall vert-air drills: all %d drills rode a vert air (%d airs, %d vert-air frames, %d frames; probe self-test %d/%d)" % [
			d_summaries.size(), airs, _row("drills vert air")["frames"], _row("drills (all frames)")["frames"],
			selftest.size() - bad.size(), selftest.size()],
			("no vert air: " + ", ".join(no_air) if not no_air.is_empty() else "") + ("; self-test failed: " + "; ".join(bad) if not bad.is_empty() else "")])
	for g in DRILL_GROUPS:
		var n := d_summaries.filter(func(x): return x["group"] == g)
		var ga := 0
		var top := -INF
		for x in n:
			ga += int(x["airs"])
			top = maxf(top, x["top"])
		var c := _crit(_row(g), _row("  vert air: " + g))
		var which: PackedStringArray = []
		for x in n:
			var cx := _crit(_row("    " + x["name"]), _row("~vert " + x["name"]))
			if not cx[0]:
				which.append("%s: %s" % [x["name"], cx[2]])
		checks.append([c[0] and ga > 0, "vert air next to a wall, drills at the %s: %d drills, %d airs up to y %.2f m; %s" % [
				g, n.size(), ga, top, c[1]], (c[2] if c[2] != "" else ("no vert air" if ga == 0 else "")) +
				("; failing drills - " + " | ".join(which) if not which.is_empty() else "")])
	var tab: PackedStringArray = []
	var order: Array = ["drills (all frames)", "drills vert air"]
	for g in DRILL_GROUPS:
		order.append(g)
		order.append("  vert air: " + g)
		for x in d_summaries:
			if x["group"] == g:
				order.append("    " + x["name"])
	tab.append_array(_table(order))
	tab.append("")
	tab.append("every drill (spawned on the floor, holding push until the first vert air; halfpipe drills pump for 10 s):")
	for x in d_summaries:
		var r: Dictionary = x["row"]
		tab.append("  %-48s %3d fr  %d vert airs (%3d fr, top y %5.2f)  bails %d  windows broken %d%s  occ col/rend %d/%d  clip %d/%d  nvol %d/%d  inside %d/%d  outside %d  <0.9m %d  closest %.2f m" % [
				x["name"], x["frames"], x["airs"], x["vert_frames"], x["top"], x["bails"], x["windows"],
				"  wall down" if x["wall"] and x["group"] == G_ROOM else "", r["col_occ"], r["vis_occ"], r["col_clip"], r["vis_clip"],
				r["col_nv"], r["vis_nv"], r["col_in"], r["vis_in"], r["outside"], r["close"], r["min_dist"]])
	tab.append("")
	tab.append_array(_geometry_lines())
	tab.append("")
	tab.append_array(_stretch_lines("vis", "rendered geometry", _row("drills (all frames)")["vis_occ"]))
	tab.append_array(_stretch_lines("col", "park collision", _row("drills (all frames)")["col_occ"]))
	tab.append("")
	tab.append("every vert air of the drills:")
	tab.append_array(_episode_lines())
	tab.append_array(_event_lines())
	var out := {"finished": true, "frames": frames_measured, "drills": d_summaries.size(), "checks": checks, "table": Array(tab)}
	var f := FileAccess.open(DRILL_JSON, FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()
	for c in checks:
		print(("PASS  " if c[0] else "FAIL  ") + c[1] + ("" if c[0] else "  (" + c[2] + ")"))
	print("\n".join(tab))
	finished_written = true
	quit(0)


## Wait for the drill process (started at boot) and read its checks.
func _collect_drills() -> void:
	if drill_pid <= 0:
		drill_result = {"error": "could not start the drill process"}
		return
	var deadline := drill_t0 + (DRILL_TIMEOUT_S + 30) * 1000
	while OS.is_process_running(drill_pid) and Time.get_ticks_msec() < deadline:
		OS.delay_msec(500)
	if OS.is_process_running(drill_pid):
		OS.kill(drill_pid)
	var txt := FileAccess.get_file_as_string(DRILL_JSON) if FileAccess.file_exists(DRILL_JSON) else ""
	var parsed = JSON.parse_string(txt) if txt != "" else null
	if parsed is Dictionary and parsed.get("finished", false):
		drill_result = parsed
	elif parsed is Dictionary and parsed.has("error"):
		drill_result = {"error": String(parsed["error"])}
	else:
		var log_txt := FileAccess.get_file_as_string(DRILL_LOG) if FileAccess.file_exists(DRILL_LOG) else ""
		var tail := log_txt.split("\n").slice(-6)
		drill_result = {"error": "no drill results (exit code %d); log tail: %s" % [OS.get_process_exit_code(drill_pid), " | ".join(tail)]}


# ------------------------------------------------------------------ end of the run

## main.gd quits the tree right after it prints "[run] finished ..."; the scene is torn
## down in SceneTree.finalize, so the result of the run is read while main exits the tree.
func _snapshot_end() -> void:
	if drill_mode or not final_snapshot.is_empty() or main == null or not is_instance_valid(main):
		return
	final_snapshot = {
		"finished": not main.running and main.menus.mode == main.menus.END,
		"score": main.score.total,
		"goals": main.goals.map(func(g): return [g["id"], g["done"]]),
		"all_done": main.goals.all(func(g): return g["done"]),
		"n_goals": main.goals.size(),
		"time_left": main.time_left,
		"phys": Engine.get_physics_frames(),
	}


func _finish_report() -> void:
	# the run's own numbers are on disk before the wait for the drills
	_write_report(false, "waiting for the drill process")
	_collect_drills()
	var failed := _write_report(true)
	quit(1 if failed > 0 else 0)


func _finalize() -> void:
	if drill_mode:
		for b in vis_bodies:
			PhysicsServer3D.free_rid(b)
		return
	_snapshot_end()
	if not finished_written:
		_finish_report()
	for b in vis_bodies:
		PhysicsServer3D.free_rid(b)


func _clock(sec: float) -> String:
	var c := ceili(sec)
	return "%d:%02d" % [c / 60, c % 60]


func _write_report(final: bool, note := "run in progress") -> int:
	if final:
		_close_stretches()
	var out: PackedStringArray = []
	var passed := 0
	var failed := 0
	var checks: Array = []   # [ok, what, detail]
	var A: Dictionary = _row("all")
	var V: Dictionary = _row("vert air")
	var G: Dictionary = _row("grind")
	var n: int = A["frames"]
	# 1. the run itself
	var snap := final_snapshot
	if not snap.is_empty():
		var line := "[run] finished score=%d goals=%s" % [snap["score"], str(snap["goals"])]
		checks.append([snap["finished"] and snap["all_done"] and snap["n_goals"] == 5 and snap["time_left"] <= 0.0,
				"the autopilot run plays the full 2:00 and completes all five goals: %s" % line,
				"finished=%s all_done=%s time_left=%.2f" % [snap["finished"], snap["all_done"], snap["time_left"]]])
	else:
		checks.append([false, "the autopilot run plays the full 2:00 and completes all five goals",
				"run not finished yet (%d frames so far)" % n])
	checks.append([frames_skipped == 0 and first_measured_phys == 1 and n > 60 * 110,
			"every physics frame of the run was measured (%d frames = %.1f s from the run's physics frame %d, %d skipped)" % [
				n, n / 60.0, first_measured_phys, frames_skipped],
			"need >= %d frames from the run's first physics frame, 0 skipped" % (60 * 110)])
	var vlocs := rows.keys().filter(func(k): return String(k).begins_with("  vert air: "))
	vlocs.sort()
	var vl: PackedStringArray = []
	for k in vlocs:
		vl.append("%s %d fr" % [String(k).trim_prefix("  vert air: "), rows[k]["frames"]])
	checks.append([V["frames"] > 0 and G["frames"] > 0,
			"the run contains vert airs (%d airs, %d frames: %s) and grinds (%d grinds, %d frames)" % [vert_airs, V["frames"],
			", ".join(vl), grinds, G["frames"]]])
	var missing := AREAS.filter(func(a): return not rows.has("area: " + a))
	checks.append([missing.is_empty(), "the run covers every area of the park (%s)" % ", ".join(AREAS), "missing: " + ", ".join(missing)])
	var st_all := selftest.duplicate()
	if not vis_late_done:
		st_all.append([false, "hidden meshes drop out of the rendered geometry once the run has broken every window and the wall (not reached)"])
	var bad := st_all.filter(func(x): return not x[0]).map(func(x): return x[1])
	checks.append([st_all.size() > 0 and bad.is_empty(),
			"the probes can fail: self-test against known spots of the park (%d of %d: collision and rendered clip sphere / near-clip volume / rays incl. a hanger rod that has no collision, window glass, inside-a-solid in the funbox and the deck block, hall bounds, framing vs the engine frustum, broken windows and the smashed wall drop out)" % [
				st_all.size() - bad.size(), st_all.size()],
			"failed: " + "; ".join(bad) if st_all.size() > 0 else "self-test did not run"])
	# 2. clipping - against the collision the spring arm avoids, and against what is drawn
	checks.append([A["col_clip"] == 0,
			"no near-plane clipping into the park collision: collision within %.3f m (cam.near %.2f x 1.5) of the camera in %d of %d frames (vert air %d, grind %d; must be 0)" % [
				clip_r, cam_near, A["col_clip"], n, V["col_clip"], G["col_clip"]], "must be 0"])
	checks.append([A["col_nv"] == 0,
			"the near-clip volume (camera -> near plane at aspect %.2f) never cuts the park collision: %d of %d frames (vert air %d, grind %d; must be 0)" % [
				aspect_near, A["col_nv"], n, V["col_nv"], G["col_nv"]], "must be 0"])
	checks.append([A["vis_clip"] == 0,
			"no near-plane clipping into rendered park geometry (every drawn mesh incl. parts without collision): within %.3f m of the camera in %d of %d frames (vert air %d, grind %d; must be 0)" % [
				clip_r, A["vis_clip"], n, V["vis_clip"], G["vis_clip"]], "must be 0; " + _mesh_hit_line()])
	checks.append([A["vis_nv"] == 0,
			"the near-clip volume never cuts rendered park geometry: %d of %d frames (vert air %d, grind %d; must be 0)" % [
				A["vis_nv"], n, V["vis_nv"], G["vis_nv"]], "must be 0; first: " + " | ".join(events["vis_nv"].slice(0, 3))])
	checks.append([A["col_in"] == 0 and A["vis_in"] == 0,
			"the camera is never inside a solid or behind a surface (most of 14 directions see a back face first): collision %d, rendered %d of %d frames (must be 0)" % [
				A["col_in"], A["vis_in"], n], "must be 0; first: " + " | ".join((events["col_in"] + events["vis_in"]).slice(0, 3))])
	checks.append([A["outside"] == 0,
			"camera stays inside the hall %s-%s or the secret room: %d of %d frames outside (vert air %d, grind %d; must be 0)" % [
				_v(hall.position), _v(hall.end), A["outside"], n, V["outside"], G["outside"]], "must be 0"])
	# 3. line of sight
	for spec in [["col_occ", "the park collision"], ["vis_occ", "rendered opaque geometry"]]:
		var f: String = spec[0]
		checks.append([n > 0 and _frac(A, f) < MAX_OCCLUDED,
				"line of sight camera -> upper body (+%.1f m) against %s: occluded %d of %d frames = %s overall (limit < 2%%)" % [
					LOS_HEIGHT, spec[1], A[f], n, _pct(A[f], n)], "%s >= 2%%" % _pct(A[f], n)])
		checks.append([V["frames"] > 0 and _frac(V, f) < MAX_OCCLUDED,
				"line of sight during vert air against %s: occluded %d of %d frames = %s (limit < 2%%)" % [spec[1], V[f], V["frames"],
					_pct(V[f], V["frames"])], "%s >= 2%%" % _pct(V[f], V["frames"])])
		var per_rail: PackedStringArray = []
		for k in rows:
			if String(k).begins_with("  grind: "):
				per_rail.append("%s %d/%d" % [String(k).trim_prefix("  grind: "), rows[k][f], rows[k]["frames"]])
		checks.append([G["frames"] > 0 and _frac(G, f) < MAX_OCCLUDED,
				"line of sight during grinds against %s: occluded %d of %d frames = %s (limit < 2%%; %s)" % [spec[1], G[f],
					G["frames"], _pct(G[f], G["frames"]), ", ".join(per_rail)], "%s >= 2%%" % _pct(G[f], G["frames"])])
	checks.append([A["hidden"] == 0,
			"the skater is never completely hidden: all %d body points blocked by rendered geometry in %d of %d frames (must be 0; on average %.1f%% of the points blocked)" % [
				BODY_PTS.size(), A["hidden"], n, 100.0 * A["blocked_pts"] / maxf(1.0, n * BODY_PTS.size())],
			"must be 0; first: " + " | ".join(events["hidden"].slice(0, 2))])
	# 4. distance and framing
	checks.append([n > 0 and _frac(A, "close") < MAX_TOO_CLOSE,
			"camera never collapses onto the skater: closer than %.1f m to the body in %d of %d frames = %s (limit < 1%%), closest %.2f m" % [
				TOO_CLOSE, A["close"], n, _pct(A["close"], n), min_dist], "%s >= 1%%" % _pct(A["close"], n)])
	checks.append([n > 0 and A["off_mid"] == 0 and _frac(A, "off_edge") < MAX_EDGE_OFF,
			"the skater stays framed (aspect %.2f): body centre off screen in %d of %d frames (must be 0), head or feet off screen in %d = %s (limit < 1%%)" % [
				aspect_frame, A["off_mid"], n, A["off_edge"], _pct(A["off_edge"], n)], "centre %d, head/feet %s" % [A["off_mid"], _pct(A["off_edge"], n)]])
	# 5. vert air next to a wall: the run's own airs off the east quarterpipe, then the drills
	var eq := "  vert air: east quarterpipe"
	var c := _crit(_row(eq), _row(eq))
	checks.append([c[0], "vert air next to a wall in the run (east quarterpipe below the windows): %s" % c[1], c[2]])
	if drill_result.has("checks"):
		for dc in drill_result["checks"]:
			checks.append([bool(dc[0]), String(dc[1]), String(dc[2])])
	else:
		checks.append([false, "wall vert-air drills (second process, tests/results/camera_drills.log)",
				String(drill_result.get("error", "drill results not collected yet (%s)" % note))])
	for ck in checks:
		if ck[0]:
			passed += 1
			out.append("PASS  " + ck[1])
		else:
			failed += 1
			out.append("FAIL  " + ck[1] + ("  (" + ck[2] + ")" if ck.size() > 2 and ck[2] != "" else ""))
	# detail tables
	var order: Array = ["all", "vert air"]
	var subs: Array = rows.keys().filter(func(k): return String(k).begins_with("  vert air"))
	subs.sort()
	order.append_array(subs)
	order.append("grind")
	subs = rows.keys().filter(func(k): return String(k).begins_with("  grind"))
	subs.sort()
	order.append_array(subs)
	for a in AREAS:
		order.append("area: " + a)
	var tab := _table(order)
	tab.append("")
	tab.append_array(_geometry_lines())
	tab.append("")
	tab.append_array(_stretch_lines("vis", "rendered geometry", A["vis_occ"]))
	tab.append_array(_stretch_lines("col", "park collision", A["col_occ"]))
	tab.append("")
	tab.append("every vert air and grind of the run (camera numbers per episode):")
	tab.append_array(_episode_lines())
	tab.append_array(_event_lines())
	if drill_result.has("table"):
		tab.append("")
		tab.append("==== wall vert-air drills (second process: godot --headless --path . --fixed-fps 60 -s tests/test_camera_run.gd -- --camera-drills) ====")
		for l in drill_result["table"]:
			tab.append(String(l))
	var title := "Pro Skater chase-camera run metrics  %s%s" % [Time.get_datetime_string_from_system(),
			"" if final else "  (INTERIM - %s)" % note]
	var report := "%s\n%s\n\n%s\n%d passed, %d failed\n" % [title, "\n".join(out), "\n".join(tab), passed, failed]
	if final:
		print(report)
		finished_written = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/results"))
	var fh := FileAccess.open(RESULTS, FileAccess.WRITE)
	fh.store_string(report)
	fh.close()
	return failed
