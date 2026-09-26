extends SceneTree
## Headless audio tests. Evidence that every sound is synthesised in GDScript (no sample
## files, no music, no AudioStreamGenerator), that the buffers are real 16-bit PCM (non-silent,
## loops flagged and seamless), and - on the real main scene with injected input - that the
## right sounds start on the right events and that rolling follows speed and the material
## under the wheels (concrete floor, plywood deck / drop-in ramp, diamond-plate catwalk).
##   godot --headless --path . --fixed-fps 60 -s tests/test_audio.gd   -> tests/results/audio.txt
## (waits count physics ticks, so it also runs the same without --fixed-fps, in real time)
## Event sounds are detected by watching the Sfx autoload's player pool: every Sfx.play()
## takes the next AudioStreamPlayer in the pool, so each physics tick the players between the
## last seen pool index and the current one are the sounds that just started; their stream
## and playing flag are logged right then.

const AUDIO_EXT := ["wav", "ogg", "mp3", "opus", "flac", "aiff", "aif"]
## What Godot's importer turns audio files into inside .godot/imported
const IMPORTED_AUDIO_EXT := ["sample", "oggvorbisstr", "mp3str"]
const AUDIO_IMPORTERS := ["wav", "oggvorbisstr", "mp3"]
const LOOPS := ["roll_concrete", "roll_wood", "roll_metal", "grind_metal", "grind_wood", "grind_concrete", "wind"]
const REQUIRED := [
	["roll_concrete", "rolling on concrete"], ["roll_wood", "rolling on wood"], ["roll_metal", "rolling on metal"],
	["pop", "ollie pop"], ["land", "landing"], ["land_hard", "hard landing"],
	["grind_metal", "metal grind loop"], ["grind_wood", "wood grind loop"], ["grind_concrete", "concrete grind loop"],
	["bail", "bail"], ["clatter", "board clatter"], ["catch", "flip catch"], ["glass", "window glass"],
	["wall", "wall break"], ["wind", "air wind loop"],
]
const CODE_BANNED := ["AudioStreamGenerator", "AudioStreamOggVorbis", "AudioStreamMP3", "AudioStreamPlaylist",
		"AudioStreamInteractive", "AudioStreamSynchronized", "load_from_file", "load_from_buffer"]

var main: Node
var sk
var sfx: Node
var out: PackedStringArray = []
var passed := 0
var failed := 0
var frame_no := 0
var play_log: Array = []        # {f, name, playing, vol, pitch}
var _seen_i := 0
var names := {}                  # AudioStreamWAV -> Sfx name
var files: Array = []            # every file under res:// (.git skipped)


func check(ok: bool, what: String, detail := "") -> void:
	if ok:
		passed += 1
		out.append("PASS  " + what + ("  [" + detail + "]" if detail != "" else ""))
	else:
		failed += 1
		out.append("FAIL  " + what + ("  (" + detail + ")" if detail != "" else ""))


func _initialize() -> void:
	physics_frame.connect(_poll)
	_run.call_deferred()


## Waits count physics ticks (the skater and its sounds update in _physics_process), so the
## timing is the same with or without --fixed-fps.
func frames(n: int) -> void:
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
	await frames(1)


## Log every sound the Sfx pool started since the last physics tick.
func _poll() -> void:
	frame_no += 1
	if sfx == null or not sfx.ready_flag:
		return
	var pool: Array = sfx._pool
	var cur: int = sfx._pool_i
	while _seen_i != cur:
		var p: AudioStreamPlayer = pool[_seen_i]
		play_log.append({"f": frame_no, "name": sname(p.stream), "playing": p.playing, "vol": p.volume_db,
				"pitch": p.pitch_scale, "player": p})
		_seen_i = (_seen_i + 1) % pool.size()


func sname(s) -> String:
	if s == null:
		return "<none>"
	return names.get(s, "<not an Sfx stream>")


func started_since(f0: int, what := "") -> Array:
	var r := []
	for e in play_log:
		if e["f"] >= f0 and (what == "" or e["name"] == what):
			r.append(e)
	return r


func names_since(f0: int) -> String:
	var r := []
	for e in started_since(f0):
		r.append("%s@%d%s" % [e["name"], e["f"] - f0, "" if e["playing"] else "(not playing)"])
	return ", ".join(r) if r.size() > 0 else "nothing"


func _run() -> void:
	sfx = root.get_node_or_null("Sfx")
	if sfx == null:
		check(false, "Sfx autoload exists")
		_finish()
		return
	for n in sfx.streams:
		names[sfx.streams[n]] = n
	_seen_i = sfx._pool_i
	walk("res://", files)
	scan_files()
	scan_code()
	scan_scenes()
	check_streams()
	await check_rebuild()
	await game_checks()
	_finish()


func _finish() -> void:
	var report := "Pro Skater audio tests  %s\n%s\n%d passed, %d failed\n" % [
			Time.get_datetime_string_from_system(), "\n".join(out), passed, failed]
	print(report)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/results"))
	var f := FileAccess.open("res://tests/results/audio.txt", FileAccess.WRITE)
	f.store_string(report)
	f.close()
	quit(1 if failed > 0 else 0)


# ------------------------------------------------------------------ static evidence

func walk(dir: String, acc: Array) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.include_hidden = true
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if f != "." and f != "..":
			var p := dir.path_join(f)
			if d.current_is_dir():
				if f != ".git":          # VCS metadata (its hooks/*.sample are shell scripts)
					walk(p, acc)
			else:
				acc.append(p)
		f = d.get_next()
	d.list_dir_end()


func scan_files() -> void:
	var found := []
	var imported := []
	var importers := []
	for p in files:
		var ext: String = p.get_extension().to_lower()
		if ext in AUDIO_EXT:
			found.append(p)
		if p.begins_with("res://.godot/imported/") and ext in IMPORTED_AUDIO_EXT:
			imported.append(p)
		if ext == "import":
			var t := FileAccess.get_file_as_string(p)
			for imp in AUDIO_IMPORTERS:
				if t.contains('importer="%s"' % imp):
					importers.append(p)
	check(found.is_empty() and files.size() > 100,
			"no audio files (.wav .ogg .mp3 .opus .flac .aiff) anywhere under res://",
			"%d files scanned recursively with DirAccess incl. hidden .godot/ and the .gdignore'd build/ evidence/ renders/ blender/; .git/ skipped" % files.size()
			if found.is_empty() else ", ".join(found))
	check(imported.is_empty() and importers.is_empty(),
			"no imported audio in the Godot import cache and no .import file uses an audio importer",
			"no .godot/imported/*.sample|*.oggvorbisstr|*.mp3str, no importer=wav|oggvorbisstr|mp3"
			if imported.is_empty() and importers.is_empty() else ", ".join(imported + importers))


## GDScript source with comments removed (string literals kept, '#' inside strings kept).
func strip_comments(src: String) -> PackedStringArray:
	var lines := src.split("\n")
	var res := PackedStringArray()
	for line in lines:
		var o := ""
		var q := ""
		var i := 0
		while i < line.length():
			var c := line[i]
			if q != "":
				o += c
				if c == "\\" and i + 1 < line.length():
					o += line[i + 1]
					i += 1
				elif c == q:
					q = ""
			elif c == "\"" or c == "'":
				q = c
				o += c
			elif c == "#":
				break
			else:
				o += c
			i += 1
		res.append(o)
	return res


func scan_code() -> void:
	var gd := []
	for p in files:
		if p.get_extension() == "gd" and not p.begins_with("res://tests/") and not p.begins_with("res://.godot/"):
			gd.append(p)
	var gen_hits := []
	var gen_comments := []
	var load_hits := []
	var audio_lit := RegEx.create_from_string("[\"'][^\"']*\\.(wav|ogg|mp3|opus|flac|aiff?)[\"']")
	var in_scripts := 0
	for p in gd:
		if p.begins_with("res://scripts/"):
			in_scripts += 1
		var src := FileAccess.get_file_as_string(p)
		var raw := src.split("\n")
		var code := strip_comments(src)
		for i in code.size():
			var ln: String = code[i]
			for b in CODE_BANNED:
				if ln.contains(b):
					(gen_hits if b == "AudioStreamGenerator" else load_hits).append("%s:%d %s" % [p.trim_prefix("res://"), i + 1, b])
			if audio_lit.search(ln.to_lower()):
				load_hits.append("%s:%d audio path literal" % [p.trim_prefix("res://"), i + 1])
			if raw[i].contains("AudioStreamGenerator") and not ln.contains("AudioStreamGenerator"):
				gen_comments.append("%s:%d" % [p.trim_prefix("res://"), i + 1])
	check(gen_hits.is_empty() and in_scripts >= 10, "no GDScript uses AudioStreamGenerator (does not work in the web build's sample playback)",
			"%d .gd files scanned (%d under scripts/, plus addons/), comments excluded; the word appears only in comment(s) at %s" % [
			gd.size(), in_scripts, ", ".join(gen_comments) if gen_comments.size() > 0 else "-"]
			if gen_hits.is_empty() else ", ".join(gen_hits))
	check(load_hits.is_empty(), "no GDScript loads an audio file or builds a decoded / music stream",
			"no load()/preload() of audio paths or audio-file string literals, no load_from_file/load_from_buffer, no Ogg/MP3/Playlist/Interactive/Synchronized streams"
			if load_hits.is_empty() else ", ".join(load_hits))
	# positive evidence: the Sfx script builds the buffers itself
	var sfx_src := "\n".join(strip_comments(FileAccess.get_file_as_string("res://scripts/audio/sfx.gd")))
	check(sfx_src.contains("AudioStreamWAV.new()") and sfx_src.contains("encode_s16") and sfx_src.contains(".data = "),
			"scripts/audio/sfx.gd writes the PCM itself (AudioStreamWAV.new(), encode_s16 into a PackedByteArray, .data = bytes)")


func scan_scenes() -> void:
	var scanned := 0
	var players := 0
	var hits := []
	var audio_path := RegEx.create_from_string("path=\"[^\"]*\\.(wav|ogg|mp3|opus|flac|aiff?)\"")
	for p in files:
		var ext: String = p.get_extension()
		if not (ext in ["tscn", "tres"]) or p.begins_with("res://.godot/") or p.begins_with("res://tests/"):
			continue
		scanned += 1
		var lines := FileAccess.get_file_as_string(p).split("\n")
		for i in lines.size():
			var ln := lines[i]
			if ln.begins_with("[node") and ln.contains("type=\"AudioStreamPlayer"):
				players += 1
			if (ln.begins_with("[ext_resource") or ln.begins_with("[sub_resource")) and ln.contains("type=\"AudioStream"):
				hits.append("%s:%d %s" % [p.trim_prefix("res://"), i + 1, ln])
			if ln.begins_with("stream =") or ln.begins_with("stream=") or audio_path.search(ln.to_lower()) \
					or ln.contains("AudioStreamGenerator"):
				hits.append("%s:%d %s" % [p.trim_prefix("res://"), i + 1, ln])
	check(hits.is_empty() and scanned > 0, "no scene or resource file embeds or references an audio stream",
			"%d .tscn/.tres scanned; %d AudioStreamPlayer node(s), none with a stream assigned in the scene" % [scanned, players]
			if hits.is_empty() else ", ".join(hits))


# ------------------------------------------------------------------ the buffers

func pcm(w: AudioStreamWAV) -> PackedFloat32Array:
	var d := w.data
	var n := d.size() / 2
	var a := PackedFloat32Array()
	a.resize(n)
	for i in n:
		a[i] = d.decode_s16(i * 2) / 32768.0
	return a


func rms(a: PackedFloat32Array) -> float:
	var s := 0.0
	for x in a:
		s += x * x
	return sqrt(s / maxf(1.0, a.size()))


## RMS of the signal through a band-pass (RBJ biquad), relative to the full signal.
func band(a: PackedFloat32Array, hz: float, rate: float, q := 4.0) -> float:
	var w0 := TAU * hz / rate
	var alpha := sin(w0) / (2.0 * q)
	var a0 := 1.0 + alpha
	var b0 := alpha / a0
	var b2 := -alpha / a0
	var a1 := -2.0 * cos(w0) / a0
	var a2 := (1.0 - alpha) / a0
	var x1 := 0.0
	var x2 := 0.0
	var y1 := 0.0
	var y2 := 0.0
	var s := 0.0
	for x in a:
		var y := b0 * x + b2 * x2 - a1 * y1 - a2 * y2
		x2 = x1
		x1 = x
		y2 = y1
		y1 = y
		s += y * y
	return sqrt(s / a.size()) / maxf(1e-6, rms(a))


## Sharp transients (knocks / clicks): 2 ms frames of the first difference whose level
## jumps above 3x the previous 20 ms, at least 30 ms apart.
func onsets(a: PackedFloat32Array, rate: float, from_s: float) -> Array:
	var hop := int(rate * 0.002)
	var env := []
	var prev := 0.0
	var i := 0
	while i + hop <= a.size():
		var e := 0.0
		for k in hop:
			var d := a[i + k] - prev
			prev = a[i + k]
			e += d * d
		env.append(sqrt(e / hop))
		i += hop
	var peak := 0.0
	for v in env:
		peak = maxf(peak, v)
	var res := []
	var last := -1000
	for j in range(10, env.size()):
		if j * 0.002 < from_s:
			continue
		var m := 0.0
		for k in range(j - 10, j):
			m += env[k]
		m /= 10.0
		if env[j] > 3.0 * m and env[j] > peak * 0.05 and j - last > 15:
			res.append(snappedf(j * 0.002, 0.001))
			last = j
	return res


func check_streams() -> void:
	var missing := []
	for r in REQUIRED:
		if not sfx.streams.has(r[0]) or not (sfx.streams[r[0]] is AudioStreamWAV):
			missing.append(r[0])
	var req_names := []
	for r in REQUIRED:
		req_names.append("%s (%s)" % [r[0], r[1]])
	check(missing.is_empty(), "the required sounds exist in the Sfx autoload",
			", ".join(req_names) + "; %d streams in total" % sfx.streams.size() if missing.is_empty() else "missing: " + ", ".join(missing))
	var longest := ""
	var longest_s := 0.0
	var clipped := []
	for n in sfx.streams:
		var w = sfx.streams[n]
		if not (w is AudioStreamWAV):
			check(false, "stream '%s' is an AudioStreamWAV" % n, str(w))
			continue
		var a := pcm(w)
		var dur: float = a.size() / float(w.mix_rate)
		if dur > longest_s:
			longest_s = dur
			longest = n
		var r := rms(a)
		var pk := 0.0
		var clip := 0
		for x in a:
			pk = maxf(pk, absf(x))
			if absf(x) >= 32767.0 / 32768.0:
				clip += 1
		if clip > 0:
			clipped.append("%s: %d samples at full scale" % [n, clip])
		var ok: bool = w.resource_path == "" and w.format == AudioStreamWAV.FORMAT_16_BITS and not w.stereo \
				and dur >= 0.05 and r >= 0.01 and pk >= 0.1
		var info := "AudioStreamWAV built in code (resource_path empty), 16-bit %s %d Hz, %.2f s, RMS %.3f (%.1f dBFS), peak %.2f" % [
				"stereo" if w.stereo else "mono", w.mix_rate, dur, r, linear_to_db(r), pk]
		if n in LOOPS:
			var frames_n := a.size()
			var diffs := PackedFloat32Array()
			diffs.resize(frames_n - 1)
			for i in range(1, frames_n):
				diffs[i - 1] = absf(a[i] - a[i - 1])
			diffs.sort()
			var p999: float = diffs[int(diffs.size() * 0.999)]
			var wrap := absf(a[0] - a[frames_n - 1])
			var loop_ok: bool = w.loop_mode == AudioStreamWAV.LOOP_FORWARD and w.loop_begin == 0 and w.loop_end == frames_n
			ok = ok and loop_ok and wrap <= p999
			info += ", LOOP_FORWARD %d..%d of %d frames, wrap step %.4f <= 99.9th pct step %.4f (no click)" % [
					w.loop_begin, w.loop_end, frames_n, wrap, p999]
		else:
			ok = ok and w.loop_mode == AudioStreamWAV.LOOP_DISABLED
			info += ", one-shot (loop disabled)" if w.loop_mode == AudioStreamWAV.LOOP_DISABLED else ", UNEXPECTED loop mode %d" % w.loop_mode
		check(ok, "stream '%s': synthesised, non-silent%s" % [n, ", flagged as a seamless loop" if n in LOOPS else ""], info)
	check(longest_s < 3.0, "no music: every buffer is a short effect or loop", "longest is '%s' at %.2f s; no streaming / music stream types in code" % [longest, longest_s])
	check(clipped.is_empty(), "no buffer is hard-clipped (samples pinned at full scale)",
			"all peaks below full scale" if clipped.is_empty() else ", ".join(clipped) + " - _clatter() output is mixed without _normalize() before _wav()")
	# material character of the three rolling loops: wood darkest, metal brightest
	var tb := {}
	for m in ["wood", "concrete", "metal"]:
		var a := pcm(sfx.streams["roll_" + m])
		tb[m] = band(a, 1720.0, 22050.0) / maxf(1e-6, band(a, 190.0, 22050.0))
	var distinct: bool = sfx.streams["roll_wood"].data != sfx.streams["roll_metal"].data \
			and sfx.streams["roll_wood"].data != sfx.streams["roll_concrete"].data \
			and sfx.streams["roll_metal"].data != sfx.streams["roll_concrete"].data
	check(distinct and tb["wood"] * 1.5 < tb["concrete"] and tb["concrete"] * 1.5 < tb["metal"],
			"the three rolling loops are different materials (wood low and hollow, metal bright and ringing)",
			"1.7 kHz / 190 Hz band ratio: wood %.2f < concrete %.2f < metal %.2f; buffers distinct" % [tb["wood"], tb["concrete"], tb["metal"]])
	# the bail sound has the board clatter mixed into it (a string of knocks after the thud)
	var bail_on := onsets(pcm(sfx.streams["bail"]), 22050.0, 0.05)
	var land_on := onsets(pcm(sfx.streams["land"]), 22050.0, 0.05)
	check(bail_on.size() >= 4 and land_on.size() <= 1,
			"the bail sound has board clatter mixed in (a run of knock transients after the impact)",
			"%d knocks in 'bail' at %s s; control: 'land' has %d" % [bail_on.size(), str(bail_on), land_on.size()])


## A fresh instance of the Sfx script rebuilds every buffer byte-for-byte from its seed:
## the sounds come from the code, not from anything loaded.
func check_rebuild() -> void:
	var t0 := Time.get_ticks_msec()
	var s2: Node = load("res://scripts/audio/sfx.gd").new()
	root.add_child(s2)
	var ms := Time.get_ticks_msec() - t0
	var same := 0
	var diff := []
	for n in sfx.streams:
		var b = s2.streams.get(n)
		if b and b.data == sfx.streams[n].data and b != sfx.streams[n]:
			same += 1
		else:
			diff.append(n)
	check(diff.is_empty() and same == sfx.streams.size(),
			"a fresh instance of scripts/audio/sfx.gd re-synthesises byte-identical buffers from its seed",
			"%d/%d buffers identical (new objects), generated in %d ms" % [same, sfx.streams.size(), ms]
			if diff.is_empty() else "differ: " + ", ".join(diff))
	s2.queue_free()
	await frames(2)


# ------------------------------------------------------------------ the real game

func col_name() -> String:
	if sk.ground_collider and is_instance_valid(sk.ground_collider):
		return String(sk.ground_collider.name)
	return "-"


func roll_state() -> Dictionary:
	var rp: AudioStreamPlayer = sk.roll_player
	return {"v": sk.vel.length(), "db": rp.volume_db, "pitch": rp.pitch_scale, "surface": sk.surface,
			"col": col_name(), "stream": sname(rp.stream), "playing": rp.playing, "state": sk.state,
			"pos": sk.global_position, "upy": sk.up.y, "pp": rp.get_playback_position()}


func ride(n: int) -> Array:
	var rec := []
	for i in n:
		await frames(1)
		var s := roll_state()
		s["i"] = i
		rec.append(s)
	return rec


func ray_down(p: Vector3) -> String:
	var space: PhysicsDirectSpaceState3D = main.level.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.3, p + Vector3.DOWN * 8.0, 1)
	var r := space.intersect_ray(q)
	return "none" if r.is_empty() else "%s y=%.2f" % [r["collider"].name, r["position"].y]


func game_checks() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await frames(5)
	sk = main.skater
	await frames(30)                # menus ignore input for a moment after opening
	var f0 := frame_no
	await tap_key(KEY_ENTER)
	await frames(3)
	check(main.running and not paused, "Enter on the start screen starts the run (gameplay not paused)")
	var sel := started_since(f0, "ui_select")
	check(sel.size() == 1 and sel[0]["playing"], "confirming the start menu plays the ui_select blip once",
			"started: %s%s" % [names_since(f0), " - played by menus.gd on confirm and again by main.gd start_run()"
			if sel.size() == 2 and sel[0]["f"] == sel[1]["f"] else ""])
	# the skater's three loops come from Sfx and run all the time (volume does the gating)
	var loops_ok := true
	var li := []
	for p in [sk.roll_player, sk.grind_player, sk.wind_player]:
		loops_ok = loops_ok and p is AudioStreamPlayer and p.playing and names.has(p.stream) and p.stream.loop_mode == AudioStreamWAV.LOOP_FORWARD
		li.append("%s=%s%s" % [p.name, sname(p.stream), "" if p.playing else "(stopped)"])
	check(loops_ok, "the skater's loop players run Sfx loop buffers", ", ".join(li))
	await rolling_speed()
	await rolling_surfaces()
	await ollie_and_landing()
	await flip_catch_combo()
	await hard_landing()
	await grinds()
	await bail_test()
	await level_events()
	# nothing in the running game plays anything that is not an Sfx buffer
	var players := 0
	var bad := []
	var st: Array = [root]
	while st.size() > 0:
		var n: Node = st.pop_back()
		st.append_array(n.get_children())
		if n is AudioStreamPlayer or n is AudioStreamPlayer2D or n is AudioStreamPlayer3D:
			players += 1
			if n.stream != null and not names.has(n.stream):
				bad.append("%s: %s" % [n.get_path(), n.stream])
			if n.autoplay:
				bad.append("%s autoplay" % n.get_path())
	check(bad.is_empty() and players > 0, "every audio player in the running game uses only Sfx buffers (no other audio source, no autoplay music)",
			"%d players in the tree (Sfx pool %d + skater loops 3)" % [players, sfx._pool.size()] if bad.is_empty() else ", ".join(bad))
	var uniq := {}
	for e in play_log:
		uniq[e["name"]] = true
	check(not uniq.has("<not an Sfx stream>") and not uniq.has("<none>"), "every sound started during the run was an Sfx buffer",
			"%d plays, distinct: %s" % [play_log.size(), ", ".join(uniq.keys())])


func rolling_speed() -> void:
	var pos := Vector3(0, 0, -24)
	var ground := ray_down(pos) + " .. " + ray_down(pos + Vector3(0, 0, -7))
	var samples := {}
	var pp0 := 0.0
	var pp1 := 0.0
	var waited := 0
	for v in [3.0, 9.0, 6.0, 0.0]:
		sk.spawn(pos, Vector3(0, 0, -1), v)
		await frames(40)             # smoothing: 12/s lerp at 60 fps settles in ~20 frames
		samples[v] = roll_state()
		if v == 9.0:
			# while rolling fast: the (dummy) headless mixer runs in real time in ~90 ms
			# chunks, so block the main thread (the game does not step) and watch the position
			pp0 = sk.roll_player.get_playback_position()
			pp1 = pp0
			var t0 := Time.get_ticks_msec()
			while Time.get_ticks_msec() - t0 < 1000 and pp1 == pp0:
				OS.delay_msec(20)
				pp1 = sk.roll_player.get_playback_position()
			waited = Time.get_ticks_msec() - t0
	var lo: Dictionary = samples[3.0]
	var mid: Dictionary = samples[6.0]
	var hi: Dictionary = samples[9.0]
	var still: Dictionary = samples[0.0]
	var on_concrete := true
	for v in [3.0, 6.0, 9.0]:
		var s: Dictionary = samples[v]
		on_concrete = on_concrete and s["state"] == sk.GROUND and s["surface"] == "concrete" and s["col"] == "COL_concrete" \
				and s["stream"] == "roll_concrete" and s["playing"] and s["upy"] > 0.99
	var fmt := func(s: Dictionary) -> String:
		return "%.1f m/s: %.1f dB, pitch %.2f" % [s["v"], s["db"], s["pitch"]]
	check(on_concrete, "rolling samples taken on the flat concrete floor with the roll_concrete loop playing",
			"floor below: %s; %s" % [ground, ", ".join([lo["col"], mid["col"], hi["col"]])])
	check(lo["db"] < mid["db"] and mid["db"] < hi["db"] and hi["db"] - lo["db"] >= 6.0,
			"rolling volume rises with speed", "%s | %s | %s" % [fmt.call(lo), fmt.call(mid), fmt.call(hi)])
	check(lo["pitch"] < mid["pitch"] and mid["pitch"] < hi["pitch"] and hi["pitch"] - lo["pitch"] >= 0.2,
			"rolling pitch_scale rises with speed", "%.2f < %.2f < %.2f" % [lo["pitch"], mid["pitch"], hi["pitch"]])
	check(still["db"] <= -50.0 and still["state"] == sk.GROUND, "rolling is silent when standing still",
			"%.2f m/s: %.1f dB" % [still["v"], still["db"]])
	check(pp1 > pp0 and hi["playing"], "the roll loop is really being mixed by the AudioServer (playback position advances while rolling)",
			"%.1f m/s: %.3f s -> %.3f s after %d ms of real time" % [hi["v"], pp0, pp1, waited])


func first_index(rec: Array, pred: Callable) -> int:
	for i in rec.size():
		if pred.call(rec[i]):
			return i
	return -1


func rolling_surfaces() -> void:
	# 1) plywood start deck (wood) onto the diamond-plate catwalk (metal) in one ride
	sk.spawn(Vector3(-4.0, 5.0, 14.6), Vector3(-1, 0, 0), 4.0)
	var rec := await ride(100)
	var on_wood: Array = rec.filter(func(s): return s["col"] == "COL_wood" and s["state"] == sk.GROUND)
	var on_metal: Array = rec.filter(func(s): return s["col"] == "COL_metal" and s["state"] == sk.GROUND)
	var w_ok: bool = on_wood.size() > 5 and on_wood.all(func(s): return s["surface"] == "wood" and s["stream"] == "roll_wood" and s["playing"])
	check(w_ok, "on the plywood start deck the roll loop is roll_wood",
			"%d frames on COL_wood (y=%.2f), stream %s, %.1f dB" % [on_wood.size(), on_wood[0]["pos"].y if on_wood.size() else 0.0,
			on_wood[-1]["stream"] if on_wood.size() else "-", on_wood[-1]["db"] if on_wood.size() else -99.0])
	var fm := first_index(rec, func(s): return s["col"] == "COL_metal")
	var m_ok: bool = fm > 0 and on_metal.size() > 5 and on_metal.all(func(s): return s["surface"] == "metal" and s["stream"] == "roll_metal" and s["playing"]) \
			and rec[fm]["stream"] == "roll_metal" and rec.slice(fm).all(func(s): return s["state"] == sk.GROUND)
	check(m_ok, "rolling off the deck onto the diamond-plate catwalk switches the loop to roll_metal",
			"COL_metal from frame %d at x=%.2f (stream there: %s), %d frames on metal, last %s %.1f dB" % [fm,
			rec[fm]["pos"].x if fm >= 0 else 0.0, rec[fm]["stream"] if fm >= 0 else "-", on_metal.size(),
			rec[-1]["stream"], rec[-1]["db"]])
	# 2) drop in from the deck: wood ramp face, then the concrete floor
	sk.spawn(Vector3(0.0, 5.0, 10.5), Vector3(0, 0, -1), 3.0)
	rec = await ride(220)
	var ramp: Array = rec.filter(func(s): return s["state"] == sk.GROUND and s["col"] == "COL_wood" and s["upy"] < 0.95)
	var r_ok: bool = ramp.size() >= 3 and ramp.all(func(s): return s["stream"] == "roll_wood" and s["surface"] == "wood" and s["playing"])
	check(r_ok, "rolling down the plywood drop-in ramp the loop stays roll_wood",
			"%d frames on the ramp face (up.y %.2f..%.2f), streams %s" % [ramp.size(),
			ramp.map(func(s): return s["upy"]).min() if ramp.size() else 0.0, ramp.map(func(s): return s["upy"]).max() if ramp.size() else 0.0,
			str(ramp.map(func(s): return s["stream"]).reduce(func(acc, x): return acc if x in acc else acc + [x], [])) if ramp.size() else "-"])
	var fc := first_index(rec, func(s): return s["state"] == sk.GROUND and s["col"] == "COL_concrete")
	var conc: Array = rec.filter(func(s): return s["state"] == sk.GROUND and s["col"] == "COL_concrete")
	var c_ok: bool = fc > 0 and rec[fc]["stream"] == "roll_concrete" and conc.all(func(s): return s["stream"] == "roll_concrete" and s["playing"]) \
			and conc.size() >= 3 and rec[fc - 1]["stream"] == "roll_wood"
	check(c_ok, "reaching the concrete floor at the bottom of the ramp switches the loop to roll_concrete",
			"COL_concrete from frame %d at z=%.2f, %.1f m/s (stream before: %s, from then: %s), %d frames on concrete" % [fc,
			rec[fc]["pos"].z if fc >= 0 else 0.0, rec[fc]["v"] if fc >= 0 else 0.0, rec[fc - 1]["stream"] if fc > 0 else "-",
			rec[fc]["stream"] if fc >= 0 else "-", conc.size()])
	# 3) a respawn from the catwalk onto the concrete floor switches back
	sk.spawn(Vector3(-18.8, 5.0, 8.0), Vector3(0, 0, -1), 4.0)
	await frames(20)
	var m := roll_state()
	sk.spawn(Vector3(0, 0, -24), Vector3(0, 0, -1), 4.0)
	await frames(20)
	var c := roll_state()
	check(m["stream"] == "roll_metal" and m["col"] == "COL_metal" and c["stream"] == "roll_concrete" and c["col"] == "COL_concrete" and c["playing"],
			"respawn from the catwalk onto the concrete floor: roll_metal then roll_concrete", "%s on %s, then %s on %s (%.1f dB)" % [
			m["stream"], m["col"], c["stream"], c["col"], c["db"]])


func ollie_and_landing() -> void:
	sk.spawn(Vector3(0, 0, -24), Vector3(0, 0, -1), 5.0)
	await frames(20)
	var f0 := frame_no
	key(KEY_SPACE, true)
	await frames(2)
	key(KEY_SPACE, false)
	for i in 6:
		await frames(1)
		if sk.state == sk.AIR:
			break
	var pops := started_since(f0, "pop")
	check(sk.state == sk.AIR and pops.size() == 1 and pops[0]["playing"], "ollie (Space released) -> pop starts on an Sfx player",
			"state=%d; started: %s; pitch %.2f" % [sk.state, names_since(f0), pops[0]["pitch"] if pops.size() else 0.0])
	var f_air := frame_no
	var min_db := 0.0
	var fl := -1
	for i in 120:
		await frames(1)
		min_db = minf(min_db, sk.roll_player.volume_db)
		if sk.state == sk.GROUND:
			fl = frame_no
			break
	var lands := started_since(f_air, "land")
	check(fl > 0 and lands.size() == 1 and lands[0]["playing"] and absi(lands[0]["f"] - fl) <= 1,
			"landing -> land starts", "landed at +%d frames; started: %s" % [fl - f_air, names_since(f_air)])
	await frames(30)
	check(min_db <= -40.0 and sk.roll_player.volume_db > -20.0 and sk.roll_player.playing,
			"rolling cuts out in the air and comes back after the landing",
			"lowest in the air %.1f dB, 30 frames after landing %.1f dB" % [min_db, sk.roll_player.volume_db])


func flip_catch_combo() -> void:
	sk.spawn(Vector3(0, 0, -24), Vector3(0, 0, -1), 5.0)
	await frames(20)
	var f0 := frame_no
	await tap_key(KEY_SPACE)
	await frames(1)
	await tap_key(KEY_J)             # kickflip right after the pop: done before touchdown
	var clean := false
	for i in 120:
		await frames(1)
		if sk.state == sk.GROUND:
			clean = true
			break
		if sk.state == sk.BAIL:
			break
	await frames(40)                  # the combo banks 0.28 s after a clean landing
	var catches := started_since(f0, "catch")
	var combos := started_since(f0, "combo")
	check(clean and catches.size() == 1 and catches[0]["playing"], "flip trick -> catch sound when the board is caught",
			"started: %s" % names_since(f0))
	check(clean and combos.size() == 1, "banking the landed combo -> combo chime", "last combo %s; started: %s" % [str(main.score.last_combo), names_since(f0)])


func hard_landing() -> void:
	var at := Vector3(4.0, 5.0, -26.0)
	var below := ray_down(at + Vector3.DOWN * 0.5)
	sk.spawn(at, Vector3(0, 0, -1), 0.0)      # nothing under the wheels: it falls 5 m
	var f0 := frame_no
	var landed := -1
	var impact := 0.0
	for i in 120:
		var vy: float = sk.vel.y
		await frames(1)
		if sk.state == sk.GROUND and i > 2:
			landed = i
			impact = -vy
			break
	var hard := started_since(f0, "land_hard")
	check(landed > 0 and hard.size() >= 1 and hard[0]["playing"] and started_since(f0, "land").is_empty(),
			"a 5 m drop onto the concrete floor -> land_hard (not the light land)",
			"floor: %s; landed after %d frames at %.1f m/s; started: %s" % [below, landed, impact, names_since(f0)])


func grind_on(label: String, pos: Vector3, fwd: Vector3, speed: float, want_rail: String, want_kind: String) -> void:
	sk.spawn(pos, fwd, speed)
	await frames(12)
	await tap_key(KEY_SPACE)
	key(KEY_L, true)
	var f_start := -1
	for i in 40:
		await frames(1)
		if sk.state == sk.GRIND:
			f_start = frame_no
			break
	key(KEY_L, false)
	var rail: String = sk.grind_rail.name if sk.grind_rail else "-"
	var kind: String = sk.grind_rail.kind if sk.grind_rail else "-"
	await frames(10)
	var gp: AudioStreamPlayer = sk.grind_player
	var during := {"state": sk.state, "db": gp.volume_db, "pitch": gp.pitch_scale, "stream": sname(gp.stream), "playing": gp.playing}
	var ok: bool = f_start > 0 and rail == want_rail and kind == want_kind and during["state"] == sk.GRIND \
			and during["stream"] == "grind_" + want_kind and during["playing"] and during["db"] > -12.0
	check(ok, "grinding the %s -> grind_%s loop audible" % [label, want_kind],
			"rail %s (%s), state=%d, grind player %s %s at %.1f dB pitch %.2f; started at snap: %s" % [rail, kind, during["state"],
			during["stream"], "playing" if during["playing"] else "stopped", during["db"], during["pitch"],
			names_since(f_start) if f_start > 0 else "-"])
	# hop off (Space) or let it run out, then the loop must be silent
	var f_off := frame_no
	if sk.state == sk.GRIND:
		await tap_key(KEY_SPACE)
	for i in 120:
		if sk.state != sk.GRIND:
			break
		await frames(1)
	await frames(2)
	check(sk.state != sk.GRIND and gp.volume_db <= -59.0, "after the %s grind the grind loop is silent" % label,
			"state=%d, grind player %.1f dB; started on exit: %s" % [sk.state, gp.volume_db, names_since(f_off)])
	await frames(90)


func grinds() -> void:
	await grind_on("long metal rail", Vector3(-12.0, 0.0, 4.0), Vector3(0, 0, -1), 7.0, "long_rail", "metal")
	await grind_on("funbox's wooden edge", Vector3(-1.6, 0.9, -15.6), Vector3(0, 0, -1), 4.0, "funbox_edge_2", "wood")
	await grind_on("concrete ledge", Vector3(-8.5, 0.0, -22.2), Vector3(1, 0, 0), 6.0, "ledge_b", "concrete")


func bail_test() -> void:
	var bails := []
	sk.bailed.connect(func(r): bails.append(r))
	sk.spawn(Vector3(0, 0, -24), Vector3(0, 0, -1), 5.0)
	await frames(20)
	await tap_key(KEY_SPACE)
	for i in 60:                      # a kickflip started late in the air is still spinning at touchdown
		await frames(1)
		if sk.state == sk.AIR and sk.air_time > 0.30:
			break
	var f0 := frame_no
	await tap_key(KEY_J)
	var fb := -1
	for i in 90:
		if sk.state == sk.BAIL:
			fb = frame_no
			break
		await frames(1)
	var loose := false
	for n in main.get_children():
		if n is RigidBody3D and String(n.name).begins_with("LooseBoard"):
			loose = true
	var b := started_since(f0, "bail")
	var bv := started_since(f0, "bail_voice")
	check(fb > 0 and bails.size() == 1 and b.size() == 1 and b[0]["playing"] and bv.size() == 1,
			"bail -> bail sound (thud + slide + clatter) and the bail grunt start",
			"reason %s; started: %s" % [str(bails), names_since(f0)])
	# the board comes off as a rigid body; its clatter should be heard while it tumbles
	var f_b := frame_no
	var min_roll := 0.0
	for i in int(sk.RESPAWN_TIME * 60.0) + 20:
		await frames(1)
		min_roll = minf(min_roll, sk.roll_player.volume_db)
		if sk.state == sk.GROUND:
			break
	var clat := started_since(fb if fb > 0 else f_b, "clatter")
	var callers := []
	for p in ["res://scripts/skater/skater.gd", "res://scripts/skater/skater_model.gd", "res://scripts/level/level.gd", "res://scripts/game/main.gd"]:
		if "\n".join(strip_comments(FileAccess.get_file_as_string(p))).contains("\"clatter\""):
			callers.append(p.get_file())
	check(loose and clat.size() >= 1 and clat[0]["playing"], "bail -> the loose board's own clatter sound (the 'clatter' buffer) plays while it tumbles",
			"loose board %s; started from the bail to the respawn: %s; game code referencing \"clatter\": %s" % [
			"spawned" if loose else "missing", names_since(fb if fb > 0 else f_b), ", ".join(callers) if callers.size() else
			"none - the 'clatter' buffer is synthesised but never played; only the clatter mixed into 'bail' is heard"])
	check(min_roll <= -50.0, "rolling is silent during the bail", "lowest %.1f dB" % min_roll)


func level_events() -> void:
	# wall: skate into the breakable wall of the secret room (the real collision path)
	var f0 := frame_no
	sk.spawn(Vector3(-14.0, 0.0, -36.5), Vector3(-1, 0, 0), 6.0)
	for i in 90:
		await frames(1)
		if main.level.wall_broken_flag:
			break
	await frames(1)
	var w := started_since(f0, "wall")
	check(main.level.wall_broken_flag and w.size() == 1 and w[0]["playing"], "skating into the breakable wall -> wall-break sound",
			"broken=%s; started: %s" % [str(main.level.wall_broken_flag), names_since(f0)])
	# letter: drop the skater into a floating letter not yet taken (the pickup's Area3D sees
	# the skater's hitbox); earlier rides may already have collected some (the drop-in's kicker
	# launches through the S)
	var entry: Dictionary = {}
	var taken := []
	for L in main.level.letters:
		if L["taken"]:
			taken.append(L["letter"])
		elif entry.is_empty():
			entry = L
	if entry.is_empty():
		main.level.reset_run()
		entry = main.level.letters[0]
	f0 = frame_no
	sk.spawn(entry["node"].global_position + Vector3(0.0, -0.9, 0.0), Vector3(0, 0, -1), 0.0)
	for i in 60:
		await frames(1)
		if entry["taken"]:
			break
	await frames(1)
	var l := started_since(f0, "letter")
	check(entry["taken"] and l.size() == 1 and l[0]["playing"], "collecting a letter -> letter chime",
			"letter %s; started: %s (already taken earlier in the run: %s)" % [entry["letter"], names_since(f0),
			", ".join(taken) if taken.size() else "none"])
	# window: Level.break_window() is what the vert air into the window calls (called directly here)
	f0 = frame_no
	main.level.break_window(0)
	await frames(1)
	var g := started_since(f0, "glass")
	check(g.size() == 1 and g[0]["playing"], "breaking a window (Level.break_window, called directly) -> glass sound",
			"started: %s at %.1f dB (distance-attenuated from the listener)" % [names_since(f0), g[0]["vol"] if g.size() else 0.0])
