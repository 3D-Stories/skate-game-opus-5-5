extends Node3D
## Animation gallery (evidence recording): the game's own skater model (skater_model.gd:
## skater.glb with its Blender clips, board.glb on the skeleton's "board" bone, the game's
## skin / hair shaders) on a plain lit stage. Plays every required clip from t = 0 at its
## authored speed (clips shorter than SHORT seconds twice), then a chain of in-game
## transitions using the exact play()/restart() calls, blend times and speeds from
## scripts/skater/skater.gd, then quits.
## An on-screen label names the clip; a readout shows how far each ankle sits from its
## on-deck position (same measure as tests/test_anims.gd).
## Record (real display, not headless):
##   godot --path . --write-movie /tmp/gallery/gallery.avi --fixed-fps 30 --resolution 1280x720 res://scenes/dev/anim_gallery.tscn
## Writes <movie dir>/gallery_timeline.json: one entry per rendered frame (for the contact sheet).

const REQUIRED := ["idle", "push", "ride", "crouch", "ollie", "kickflip", "heelflip", "shoveit", "treflip",
		"indy", "melon", "nosegrab", "tailgrab", "grind_5050", "boardslide", "manual", "nose_manual",
		"vert_air", "air", "land", "bail", "special"]
const SHORT := 1.2
const ANKLE_ON_DECK := 0.0815     # deck top + ankle above the shoe sole (tests/test_anims.gd)
const CAM_AZ := 38.0        # 3/4 side view: degrees from the skater's front (+Z) toward the board's nose (+X)
const CAM_EL := 10.0
const FIT_X := 0.9          # framing: normalised half-width used by the skater
const FIT_TOP := 0.5        # keep the top quarter clear for the labels
const FIT_BOTTOM := -0.88   # and the footer line
const INTRO := 2.0
const OUTRO := 1.5
const NOTES := {
	"push": "one foot pushes on the ground by design",
	"bail": "authored clip, board on its bone; in game the board is thrown off (see the transitions part)",
	"boardslide": "in game the whole model is turned 90 deg across the rail",
	"special": "original special trick: Tiger Claw Tre",
	"kickflip": "feet leave the deck only while the board flips", "heelflip": "feet leave the deck only while the board flips",
	"shoveit": "feet leave the deck only while the board spins", "treflip": "feet leave the deck only while the board flips",
}

@onready var model = $SkaterModel
@onready var cam: Camera3D = $Camera3D
@onready var title: Label = $HUD/Title
@onready var info: Label = $HUD/Info
@onready var foot: Label = $HUD/Footer
@onready var floor_mesh: MeshInstance3D = $Floor/Mesh

var segs: Array = []        # {kind, clip, rep, reps, len, label, note, ...}
var seg_i := -1
var seg_t := 0.0
var frame := -1
var timeline: Array = []
var _sk: Skeleton3D
var _bi := -1
var _feet := []
var _n_local := Vector3.UP
var _dt := 0.0
var _deck: MeshInstance3D
var _deck_rel := Transform3D.IDENTITY     # board bone -> deck mesh (local chain, never a frame late)
var _fits := {}
var _cam_next = null       # camera for the segment that starts next frame (switches with the pose)
var _bbox := Rect2()        # screen box of the skater + board this frame (0..1 of the picture)
var _out_frames := 0
var _out_clips := {}


func _ready() -> void:
	process_priority = 1000        # after the AnimationPlayer: labels describe the pose being drawn
	_sk = model.skeleton
	_bi = _sk.find_bone("board")
	_feet = [_sk.find_bone("foot_l"), _sk.find_bone("foot_r")]
	_n_local = (_sk.get_bone_global_rest(_bi).basis.inverse() * Vector3.UP).normalized()
	_floor_texture()
	for m in model.board.find_children("*", "MeshInstance3D", true, false):
		if m.name == "Deck":
			_deck = m
	var n: Node3D = _deck
	while n and n != model.board_attach:
		_deck_rel = n.transform * _deck_rel
		n = n.get_parent() as Node3D
	# framing: one fixed 3/4 view angle; per clip the camera distance / centre is fitted so the
	# whole skater and board stay in the picture for the entire clip (sampled up front)
	var pts := {}
	for c in REQUIRED:
		pts[c] = _clip_points(c)
		_fits[c] = _fit(pts[c])
	model.anim.stop()
	model.current = ""
	var chain_pts: Array[Vector3] = []
	for c in REQUIRED:
		if c != "bail":
			chain_pts.append_array(pts[c])
	_fits["_chain"] = _fit(chain_pts)
	var bail_pts: Array[Vector3] = pts["bail"].duplicate()
	bail_pts.append_array(pts["idle"])
	_fits["_bail"] = _fit(bail_pts)
	# the clip list
	segs.append({"kind": "intro", "clip": "idle", "len": INTRO})
	for c in REQUIRED:
		var l: float = model.clip_length(c)
		var reps := 2 if l < SHORT else 1
		for r in reps:
			segs.append({"kind": "clip", "clip": c, "rep": r + 1, "reps": reps, "len": l,
					"loop": c in model.LOOPING, "note": NOTES.get(c, "")})
	# in-game transitions: [what, method, clip, blend, speed, seconds]  (values from skater.gd)
	var kf: float = model.clip_length("kickflip") / 0.48
	var hf: float = model.clip_length("heelflip") / 0.48
	var tf: float = model.clip_length("treflip") / 0.55
	var sp: float = model.clip_length("special") / 1.0
	var chain := [
		["rolling", "play", "ride", 0.2, 1.0, 0.9],
		["push (hold Up)", "play", "push", 0.15, 1.0, 1.23],
		["ride", "play", "ride", 0.2, 1.0, 0.6],
		["crouch (hold Jump)", "play", "crouch", 0.1, 1.0, 0.45],
		["ollie", "restart", "ollie", 0.08, 1.0, 0.1],
		["kickflip", "restart", "kickflip", 0.05, kf, 0.40],
		["air", "play", "air", 0.12, 1.0, 0.25],
		["land", "restart", "land", 0.06, 1.3, 0.35],
		["ride", "play", "ride", 0.2, 1.0, 0.5],
		["manual (Up, Down)", "restart", "manual", 0.12, 1.0, 1.0],
		["ollie out", "restart", "ollie", 0.08, 1.0, 0.12],
		["50-50 grind", "restart", "grind_5050", 0.08, 1.0, 1.0],
		["hop off", "restart", "ollie", 0.08, 1.0, 0.1],
		["heelflip", "restart", "heelflip", 0.05, hf, 0.40],
		["air", "play", "air", 0.12, 1.0, 0.1],
		["melon grab", "restart", "melon", 0.1, 1.4, 0.5],
		["let go of the grab", "play", "air", 0.15, 1.0, 0.2],
		["land", "restart", "land", 0.06, 1.3, 0.35],
		["ride", "play", "ride", 0.2, 1.0, 0.4],
		["nose manual (Down, Up)", "restart", "nose_manual", 0.12, 1.0, 0.9],
		["boardslide", "restart", "boardslide", 0.08, 1.0, 0.9],
		["hop off", "restart", "ollie", 0.08, 1.0, 0.1],
		["360 flip", "restart", "treflip", 0.05, tf, 0.46],
		["air", "play", "air", 0.12, 1.0, 0.2],
		["land", "restart", "land", 0.06, 1.3, 0.35],
		["vert air", "restart", "vert_air", 0.12, 1.0, 0.35],
		["special: Tiger Claw Tre", "restart", "special", 0.05, sp, 0.8],
		["vert air", "play", "vert_air", 0.12, 1.0, 0.25],
		["tailgrab", "restart", "tailgrab", 0.1, 1.4, 0.5],
		["vert air", "play", "vert_air", 0.15, 1.0, 0.2],
		["land", "restart", "land", 0.06, 1.3, 0.35],
		["ride", "play", "ride", 0.2, 1.0, 0.4],
		["ollie", "restart", "ollie", 0.08, 1.0, 0.1],
		["pop shove-it, landed mid-trick", "restart", "shoveit", 0.05, kf, 0.3],
		["bail: board thrown off (as in game)", "restart", "bail", 0.05, 1.0, 2.2],
		["respawn", "restart", "idle", 0.0, 1.0, 1.2],
	]
	var prev := ""
	for c in chain:
		segs.append({"kind": "chain", "what": c[0], "method": c[1], "clip": c[2], "blend": c[3], "speed": c[4],
				"len": c[5], "from": prev})
		prev = c[2]
	segs.append({"kind": "outro", "clip": "", "len": OUTRO})
	_next()


func _floor_texture() -> void:
	var img := Image.create(64, 64, false, Image.FORMAT_RGB8)
	for y in 64:
		for x in 64:
			var c := 0.46 if ((x / 32) + (y / 32)) % 2 == 0 else 0.40
			img.set_pixel(x, y, Color(c, c, c * 1.02))
	var tex := ImageTexture.create_from_image(img)
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.uv1_scale = Vector3(20, 20, 1)      # 1 m checker on the 40 m floor
	m.roughness = 0.85
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	floor_mesh.material_override = m


func _next() -> void:
	seg_i += 1
	seg_t = 0.0
	if seg_i >= segs.size():
		_write_timeline()
		get_tree().quit()
		return
	var s: Dictionary = segs[seg_i]
	# the new clip's pose appears next frame (restart() takes effect in the AnimationPlayer's
	# next update), so the camera switches then too, not on this frame's old pose
	match s["kind"]:
		"intro", "outro":
			_cam_next = _fits["idle"]
		"clip":
			_cam_next = _fits[s["clip"]]
		"chain":
			_cam_next = _fits["_bail"] if s["clip"] == "bail" or s["what"] == "respawn" else _fits["_chain"]
	if seg_i == 0:
		cam.global_transform = _cam_next
		_cam_next = null
	match s["kind"]:
		"intro":
			model.restart("idle", 0.0)
		"clip":
			model.restart(s["clip"], 0.0, 1.0)
		"chain":
			if s["clip"] == "bail":
				model.detach_board(self, Vector3(1.5, 2.5, 0.8))
			elif model.board_detached:
				model.reattach_board()
			if s["method"] == "restart":
				model.restart(s["clip"], s["blend"], s["speed"])
			else:
				model.play(s["clip"], s["blend"], s["speed"])
		"outro":
			pass


func _ankles() -> Array:
	var B := _sk.get_bone_global_pose(_bi)
	var r := []
	for f in _feet:
		var rel := B.affine_inverse() * _sk.get_bone_global_pose(f).origin
		r.append((rel.dot(_n_local) - ANKLE_ON_DECK) * 100.0)
	return r


func _process(delta: float) -> void:
	frame += 1
	_dt = delta
	if _cam_next != null:
		cam.global_transform = _cam_next
		_cam_next = null
	var s: Dictionary = segs[seg_i]
	var anim: AnimationPlayer = model.anim
	var playing := anim.is_playing()
	var cur: String = String(anim.current_animation) if playing else String(model.current)
	var pos: float = anim.current_animation_position if playing else model.clip_length(cur)
	var a := _ankles()
	var feet_txt := "ankle vs. deck contact:  L %+.1f cm   R %+.1f cm" % [a[0], a[1]]
	if model.board_detached:
		feet_txt = "board detached (rigid body), as in the game's bail"
	match s["kind"]:
		"intro":
			title.text = "Animation gallery"
			info.text = "The game's skater model (skater_model.gd: skater.glb + board.glb on the \"board\" bone)\n" + \
					"22 Blender-authored clips at authored speed from t = 0 (clips under %.1f s twice),\nthen in-game transitions with the game's blend times" % SHORT
		"clip":
			title.text = "%s%s" % [s["clip"], ("   %d/%d" % [s["rep"], s["reps"]]) if s["reps"] > 1 else ""]
			info.text = "t = %.2f / %.2f s   %s\n%s%s" % [pos, s["len"], "looping" if s["loop"] else "one-shot", feet_txt,
					("\n" + s["note"]) if s["note"] != "" else ""]
		"chain":
			title.text = "in game: " + s["what"]
			var tr := "%s  (%s, blend %.2f s, speed %.2fx)" % [s["clip"], s["method"], s["blend"], s["speed"]]
			if s["from"] != "":
				tr = "%s -> %s" % [s["from"], tr]
			info.text = "transition %s\nnow playing: %s  t = %.2f s\n%s" % [tr, cur if cur != "" else "-", pos, feet_txt]
		"outro":
			title.text = "end of gallery"
			info.text = ""
	foot.text = "Godot %s  |  frame %d  |  %s" % [Engine.get_version_info()["string"], frame, "clip %d/%d" % [
			_clip_no(), REQUIRED.size()] if s["kind"] == "clip" else s["kind"]]
	var framed := _in_view()
	if not framed:
		_out_frames += 1
		_out_clips[cur] = true
	timeline.append({"framed": framed, "bbox": [snappedf(_bbox.position.x, 0.0001), snappedf(_bbox.position.y, 0.0001),
			snappedf(_bbox.end.x, 0.0001), snappedf(_bbox.end.y, 0.0001)], "frame": frame, "seg": seg_i, "kind": s["kind"], "clip": s.get("clip", ""), "rep": s.get("rep", 0),
			"reps": s.get("reps", 0), "len": s.get("len", 0.0), "pos": snappedf(pos, 0.0001), "playing": cur,
			"what": s.get("what", ""), "ankle_l_cm": snappedf(a[0], 0.01), "ankle_r_cm": snappedf(a[1], 0.01)})
	# advance: a one-shot shows its final pose (t = len), a loop stops one frame short of wrapping
	seg_t += delta
	var end: float = s["len"]
	var done := seg_t > end + 0.001 if (s["kind"] == "clip" and not s["loop"]) else seg_t >= end - 0.001
	if done:
		_next()


func _points() -> Array[Vector3]:
	## The current pose: every bone, a point above the head (hair), the deck's 8 corners.
	var pts: Array[Vector3] = []
	var sx := _sk.global_transform
	for b in _sk.get_bone_count():
		pts.append(sx * _sk.get_bone_global_pose(b).origin)
	var head := _sk.find_bone("head")
	if head >= 0:
		var hx := sx * _sk.get_bone_global_pose(head)
		pts.append(hx.origin + hx.basis.y.normalized() * 0.22)
	if _deck and not model.board_detached:
		var dx := sx * _sk.get_bone_global_pose(_bi) * _deck_rel
		var ab := _deck.get_aabb()
		for i in 8:
			pts.append(dx * ab.get_endpoint(i))
	return pts


func _clip_points(c: String) -> Array[Vector3]:
	var anim: AnimationPlayer = model.anim
	var l: float = model.clip_length(c)
	var pts: Array[Vector3] = []
	anim.play(c)
	for k in 25:
		anim.seek(l * k / 24.0, true)
		pts.append_array(_points())
	return pts


func _fit(pts: Array[Vector3]) -> Transform3D:
	## Closest camera (fixed 3/4 angle) that keeps every point inside the free part of the picture.
	var az := deg_to_rad(CAM_AZ)
	var el := deg_to_rad(CAM_EL)
	var dir := Vector3(sin(az) * cos(el), sin(el), cos(az) * cos(el))
	var basis := Basis.looking_at(-dir, Vector3.UP)
	var inv := basis.inverse()
	var vp := get_viewport().get_visible_rect().size
	var tv := tan(deg_to_rad(cam.fov) * 0.5)
	var th := tv * vp.x / vp.y
	var q: Array[Vector3] = []
	var mn := Vector3.INF
	var mx := -Vector3.INF
	for p in pts:
		var v := inv * p
		q.append(v)
		mn = mn.min(v)
		mx = mx.max(v)
	var c := (mn + mx) * 0.5
	var band := (FIT_TOP + FIT_BOTTOM) * 0.5
	for i in 300:
		var d := 1.5 + i * 0.03
		var cb := Vector3(c.x, c.y - band * d * tv, c.z + d)
		var ok := true
		for v in q:
			var depth := cb.z - v.z
			if depth < 0.3:
				ok = false
				break
			var nx := (v.x - cb.x) / (depth * th)
			var ny := (v.y - cb.y) / (depth * tv)
			if absf(nx) > FIT_X or ny > FIT_TOP or ny < FIT_BOTTOM:
				ok = false
				break
		if ok:
			return Transform3D(basis, basis * cb)
	return Transform3D(basis, basis * Vector3(c.x, c.y, c.z + 10.0))


func _in_view() -> bool:
	## Every bone (plus a head-top margin) and the deck's corners project inside the picture.
	var vp := get_viewport().get_visible_rect().size
	var ok := true
	var mn := Vector2.INF
	var mx := -Vector2.INF
	for p in _points():
		if cam.is_position_behind(p):
			ok = false
			continue
		var q := cam.unproject_position(p) / vp
		mn = mn.min(q)
		mx = mx.max(q)
		if q.x < 0.02 or q.x > 0.98 or q.y < 0.02 or q.y > 0.98:
			ok = false
	_bbox = Rect2(mn, mx - mn)
	return ok


func _clip_no() -> int:
	var s: Dictionary = segs[seg_i]
	return REQUIRED.find(s["clip"]) + 1


func _write_timeline() -> void:
	var movie := Engine.get_write_movie_path()
	var path := (movie.get_base_dir().path_join("gallery_timeline.json")) if movie != "" else "user://gallery_timeline.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"fps": (1.0 / _dt) if _dt > 0.0 else 0.0, "frames": timeline}))
		f.close()
		print("[gallery] timeline -> ", path, "  (", timeline.size(), " frames)")
	print("[gallery] frames with part of the skater or board outside the picture: %d %s" % [_out_frames, str(_out_clips.keys())])
