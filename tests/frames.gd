extends SceneTree
## Frame-by-frame capture of the autopilot run, for looking at (and testing) any stretch of it
## without recording the whole two minutes. At a fixed 60 fps the run repeats nearly frame
## for frame (grind balance wobble and camera shake are unseeded), so a named segment is
## always the same moment. Every frame in the stretch is measured (one line of telemetry
## each in frames.jsonl, incl. the camera's own decisions); its image is saved every
## `--every` frames and whenever a detector flags it; report.json lists the flags.
##
##   godot --path . --fixed-fps 60 --resolution 1920x1080 -s tests/frames.gd -- --autopilot=run --segment=windows
##   ... -- --level=baths --autopilot=run --segment=boiler   (another level: its test.segments)
##   ... -- --autopilot=run --from=22 --to=31 [--every=2] [--out=/tmp/skate-work/frames/x]
##   ... -- --autopilot=run --segment=all --every=6          (the whole run, 10 images a second)
##   python3 tests/frames_sheet.py /tmp/skate-work/frames/windows [--flagged | --from 24 --to 26]
##
## Detectors (per frame, see _detect): the camera jumping (a pop), inside or right up against
## geometry (near-plane clipping), outside the level (a kit level's hall and rooms: past a
## wall or a roof), the skater hidden by the camera's failsafe or out of view behind
## something for 8+ frames. The whole run measured, one image in six: about 4 minutes.

const RAG_T := preload("res://tests/test_ragdoll.gd")      # depth_inside()
## autopilot run time (s) of each named stretch
const SEGMENTS := {
	"start": [0.0, 7.0],
	"rafter": [6.0, 11.5],
	"wall_tape": [13.5, 18.0],
	"windows": [21.5, 31.0],
	"funbox": [36.0, 47.0],
	"halfpipe": [50.0, 70.0],
	"end": [110.0, 121.0],
	"all": [0.0, 121.0],
}

var main: Node
var cam: Camera3D
var sk
var t_from := 0.0
var t_to := 0.0
var every := 1
var out := ""
var seg_name := ""
var frame := 0
var saved := 0
var measured := 0
var tele: FileAccess
var flags: Array = []
var _last_cam: Transform3D
var _have_last := false
var _hidden_run := 0
var _vol: Dictionary = {}    # where the camera may be (a kit level: its hall, vault, pool and rooms)
var _vol_set := false
var _blocked_run := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	seg_name = "custom"
	for a in args:
		if a.begins_with("--segment="):
			seg_name = a.get_slice("=", 1)
		elif a.begins_with("--from="):
			t_from = float(a.get_slice("=", 1))
		elif a.begins_with("--to="):
			t_to = float(a.get_slice("=", 1))
		elif a.begins_with("--every="):
			every = maxi(1, int(a.get_slice("=", 1)))
		elif a.begins_with("--out="):
			out = a.get_slice("=", 1)
	# the Warehouse's stretches are above; any other level names its own in
	# levels/<id>/level.json "test": "segments" (run times of its autopilot route)
	var segs: Dictionary = SEGMENTS
	var lid := LevelRegistry.startup_id()
	if lid != "warehouse":
		segs = LevelRegistry.def(lid).get("test", {}).get("segments", {}).duplicate()
		segs["all"] = [0.0, 121.0]
	if segs.has(seg_name):
		t_from = segs[seg_name][0]
		t_to = segs[seg_name][1]
		if lid != "warehouse":
			seg_name = lid + "_" + seg_name
	if out == "":
		out = "/tmp/skate-work/frames/" + seg_name
	DirAccess.make_dir_recursive_absolute(out)
	for f in DirAccess.get_files_at(out):
		DirAccess.remove_absolute(out.path_join(f))
	tele = FileAccess.open(out.path_join("frames.jsonl"), FileAccess.WRITE)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	RenderingServer.frame_post_draw.connect(_after_draw)
	print("[frames] segment %s: %.1f-%.1f s, every %d frame(s) -> %s" % [seg_name, t_from, t_to, every, out])


func _run_t() -> float:
	return float(main.RUN_TIME) - float(main.time_left) if main.running else -1.0


func _after_draw() -> void:
	## Called once the frame is on screen: grab it and measure what it shows.
	frame += 1
	if main == null or not main.is_node_ready() or not main.running:
		return
	if sk == null:
		sk = main.skater
		cam = main.cam
		cam.record_hits = true
	var t := _run_t()
	if t > t_to or (main.ending if "ending" in main else false):
		_finish()
		return
	if t < t_from:
		_have_last = false
		return
	# every frame in the stretch is measured; its image is saved every `every` frames and
	# whenever a detector flags it
	var rec := _measure(t)
	if frame % every == 0 or rec.has("flags"):
		var name := "f%05d_t%06.2f.jpg" % [frame, t]
		rec["img"] = name
		root.get_viewport().get_texture().get_image().save_jpg(out.path_join(name), 0.85)
		saved += 1
	tele.store_line(JSON.stringify(rec))
	measured += 1


func _measure(t: float) -> Dictionary:
	var space: PhysicsDirectSpaceState3D = sk.get_world_3d().direct_space_state
	var cp := cam.global_position
	var head: Vector3 = sk.global_position + sk.up * 1.5
	var torso: Vector3 = sk.global_position + sk.up * 1.0
	# nearest surface around the camera (six rays), and inside geometry at all
	var near_d := 9.0
	var near_what := ""
	for d in [Vector3.UP, Vector3.DOWN, Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]:
		var r := space.intersect_ray(PhysicsRayQueryParameters3D.create(cp, cp + d * 1.0, 1))
		if not r.is_empty():
			var dd := cp.distance_to(r["position"])
			if dd < near_d:
				near_d = dd
				near_what = str(r["collider"].name)
	var inside: Dictionary = RAG_T.depth_inside(space, cp)
	# line of sight to the torso through the park (camera blockers are not visible)
	var los := space.intersect_ray(PhysicsRayQueryParameters3D.create(cp, torso, 1))
	var dpos := 0.0
	var drot := 0.0
	if _have_last:
		dpos = cp.distance_to(_last_cam.origin)
		drot = rad_to_deg(cam.global_basis.get_rotation_quaternion().angle_to(_last_cam.basis.get_rotation_quaternion()))
	_last_cam = cam.global_transform
	_have_last = true
	if not _vol_set:
		_vol_set = true
		_vol = level_volume(main.level.data)
	var outside := not _vol.is_empty() and not inside_level(_vol, cp)
	var rec := {
		"frame": frame, "t": snappedf(t, 0.001), "outside": outside, "state": sk.state, "rail": (str(sk.grind_rail.name) if sk.grind_rail else ""),
		"sk": _v(sk.global_position), "vel": snappedf(sk.vel.length(), 0.01), "cam": _v(cp), "cam_fwd": _v(-cam.global_basis.z),
		"cam_head": snappedf(cp.distance_to(head), 0.01), "model_visible": sk.model.visible,
		"near_surface": snappedf(near_d, 0.001), "near_what": near_what, "cam_inside": snappedf(inside["depth"], 0.001),
		"los_blocked": (str(los["collider"].name) if not los.is_empty() else ""),
		"dpos": snappedf(dpos, 0.001), "drot": snappedf(drot, 0.01), "windows": main.level.windows_broken(),
		"camdbg": cam.dbg.duplicate(),
	}
	_detect(rec)
	return rec


func _detect(rec: Dictionary) -> void:
	var why := []
	# a pop: the view jumps (the follow camera moves ~0.1-0.25 m and a few deg per frame)
	if rec["dpos"] > 0.4 or rec["drot"] > 12.0:
		why.append("camera pop (%.2f m, %.1f deg)" % [rec["dpos"], rec["drot"]])
	if rec["cam_inside"] > 0.0:
		why.append("camera inside geometry (%.2f m)" % rec["cam_inside"])
	if rec["outside"]:
		why.append("camera outside the level (%s)" % str(rec["cam"]))
	if rec["near_surface"] < 0.12:
		why.append("camera %.3f m from %s (near-plane clipping)" % [rec["near_surface"], rec["near_what"]])
	_hidden_run = _hidden_run + 1 if not rec["model_visible"] else 0
	if _hidden_run > 0:
		why.append("skater hidden by the camera failsafe (%d frames)" % _hidden_run)
	_blocked_run = _blocked_run + 1 if rec["los_blocked"] != "" else 0
	if _blocked_run >= 8:
		why.append("skater behind %s for %d frames" % [rec["los_blocked"], _blocked_run])
	if not why.is_empty():
		rec["flags"] = why
		flags.append({"frame": rec["frame"], "t": rec["t"], "why": why})


static func level_volume(d: Dictionary) -> Dictionary:
	## A kit-built level's open volume from its data: the hall box (to the spring of its
	## vault, whose arc is followed above that), the pools below the deck and the hidden
	## rooms. The Warehouse's data has no "hall" (test_camera_run.gd checks its bounds).
	if not d.has("hall"):
		return {}
	var lo := Vector3(d["hall"]["min"][0], d["hall"]["min"][1], d["hall"]["min"][2])
	var hi := Vector3(d["hall"]["max"][0], d["hall"]["max"][1], d["hall"]["max"][2])
	var v := {"hall": AABB(lo, hi - lo), "vault": d.get("vault", {}), "pools": [], "rooms": []}
	for bw in d.get("bowls", []):
		var a := Vector3(bw["rect"][0][0], 0.0, bw["rect"][0][2])
		var b := Vector3(bw["rect"][1][0], 0.0, bw["rect"][1][2])
		var deep := 0.0
		for k in bw["depth"]:
			deep = maxf(deep, float(k[1]))
		v["pools"].append(AABB(Vector3(minf(a.x, b.x), -deep, minf(a.z, b.z)), Vector3(absf(b.x - a.x), deep, absf(b.z - a.z))))
	for ha in d.get("hidden_areas", []):
		var a := Vector3(ha["min"][0], ha["min"][1], ha["min"][2])
		var b := Vector3(ha["max"][0], ha["max"][1], ha["max"][2])
		v["rooms"].append(AABB(a.min(b), (b - a).abs()))
	return v


static func inside_level(v: Dictionary, p: Vector3) -> bool:
	for r in v["rooms"]:
		if (r as AABB).grow(0.02).has_point(p):
			return true
	var h: AABB = v["hall"]
	if p.x < h.position.x - 0.02 or p.x > h.end.x + 0.02 or p.z < h.position.z - 0.02 or p.z > h.end.z + 0.02:
		return false
	if p.y < h.position.y:
		return v["pools"].any(func(b: AABB): return b.grow(0.02).has_point(p))
	if p.y <= h.end.y:
		return true
	var vt: Dictionary = v["vault"]
	if vt.is_empty():
		return false
	# the barrel vault spans the hall's width (x) from its spring to the crown (rise)
	var sp := h.size.x * 0.5
	var rise := float(vt["rise"])
	var R := (sp * sp + rise * rise) / (2.0 * rise)
	var yc := float(vt["spring"]) + rise - R
	var dx := p.x - (h.position.x + sp)
	return p.y <= yc + sqrt(maxf(0.0, R * R - dx * dx)) + 0.02


func _v(v: Vector3) -> Array:
	return [snappedf(v.x, 0.01), snappedf(v.y, 0.01), snappedf(v.z, 0.01)]


func _finish() -> void:
	if tele == null:
		return
	tele.close()
	tele = null
	var rep := {"segment": seg_name, "from": t_from, "to": t_to, "every": every, "measured_frames": measured, "saved_frames": saved,
			"flagged_frames": flags.size(), "flags": flags}
	var f := FileAccess.open(out.path_join("report.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(rep, " "))
	f.close()
	print("[frames] measured %d frames, saved %d images, %d flagged -> %s" % [measured, saved, flags.size(), out])
	quit()
