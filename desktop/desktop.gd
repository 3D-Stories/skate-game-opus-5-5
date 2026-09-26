extends Node
## Desktop layer of the native Windows build: window mode and sizing, the fullscreen toggle,
## quitting from the menus, pausing when the window loses focus, and the files that the web
## build's URL options turn into on the desktop (bench report, frame times, screenshots, a
## settings and system report).
##
## It is an autoload in the Windows build only (desktop/project_windows.cfg, merged in by
## desktop/build_windows.sh); the web export does not contain it. It changes nothing in the
## game's own scripts: it reads the Main scene's state, presses the game's own "pause" action,
## and picks the bench report up from the game's log line ("[bench] {json}").
##
## Command line: Godot user arguments, after "--". The game's own options work as on the web
## (main.gd, bench.gd): --autopilot (the scripted two-minute run), --bench (frame-time report),
## --fps, --quality=full and the bench A/B switches (--nossao, --noglow, --nomsaa, ...).
## Desktop additions:
##   --bench-out=<file>       where the bench report goes, as JSON
##                            (default: <user dir>/bench/bench_<date>_<time>.json). bench.gd
##                            reads its switches from the whole command line, so no path
##                            given here may contain a switch word such as "nossao".
##   --frametimes-out=<file>  every frame of the run as CSV (run seconds, frame ms[, GPU ms])
##   --gpu-time               also measure the GPU time of every frame (for --frametimes-out)
##   --info-out=<file>        settings and system report as JSON: renderer, driver, GPU,
##                            window, vsync, audio output and levels, joypads, input counts
##                            (written 2 s after start, then again at the end screen or on quit)
##   --shots=<dir>            screenshots: the start screen, the run every --shot-every=<s>
##                            (default 15) run seconds, the end screen, and 1 s after each
##                            fullscreen / window switch
##   --input-log              print every key and joypad button, the skater's state changes and
##                            tricks, and its speed once a second of the run
##   --quit-at-end            quit once the run is over and the files above are written
##   --window=fullscreen|windowed   start mode (otherwise the last one used; fullscreen at first).
##                            windowed keeps the window the engine opened, so Godot's own
##                            --resolution and --position apply to it
## Engine options (before "--") such as --fullscreen, --resolution, --position, --screen,
## --rendering-driver and --disable-vsync work as usual. Godot keeps its own options from the
## game, so a window placed with --resolution or --position needs --window=windowed as well.

const PREFS := "user://desktop.cfg"
const BASE := Vector2i(1920, 1080)         # the game's design resolution (project.godot)
const QUIT_CONFIRM_S := 3.0

var main: Node = null                      # the Main scene (scripts/game/main.gd) once it is up
var opts := {}                             # user args: --key=value -> "key": "value", --flag -> "flag": ""
var hint_layer: CanvasLayer
var hint: Label
var _quit_armed := 0.0
var window_toggles := 0
var quit_game := func(): get_tree().quit()   # the tests swap this out
var _tap: LogTap
var _bench_written := false
var _bench_path := ""
var _frames: PackedFloat32Array = []       # --frametimes-out: frame ms
var _frame_t: PackedFloat32Array = []      # run seconds of each frame
var _gpu: PackedFloat32Array = []
var _last_draw_us := 0
var _shot_next := 0.0
var _shots_taken: Array[String] = []
var _start_shot_done := false
var _end_t := -1.0                         # wall time the end screen came up
var _end_done := false
var _quit_deadline := -1.0                 # --quit-at-end: when to stop waiting for the bench report
var _info_started := false
var _audio := {"frames": 0, "frames_with_sound": 0, "max_peak_db": -200.0, "sounds_played": {}}
var _input_counts := {"keys": {}, "pad_buttons": {}, "pad_axes": {}}
var _last_state := -1
var _last_speed_s := -1
var _was_riding := false
var _t0 := 0


## Keeps the lines the game prints that the desktop layer turns into files. Loggers can be
## called from any thread, so the lines go through a mutex and are handled in _process.
class LogTap extends Logger:
	var _lines: Array[String] = []
	var _m := Mutex.new()

	func _log_message(message: String, _error: bool) -> void:
		if message.begins_with("[bench] "):
			_m.lock()
			_lines.append(message.strip_edges())
			_m.unlock()

	func take() -> Array[String]:
		_m.lock()
		var out := _lines.duplicate()
		_lines.clear()
		_m.unlock()
		return out


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = -1000               # before Main, so a pause pressed here is seen this frame
	_t0 = Time.get_ticks_msec()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			opts[kv[0]] = kv[1] if kv.size() > 1 else ""
	_tap = LogTap.new()
	OS.add_logger(_tap)
	if opts.has("bench") or opts.has("bench-out"):   # main.gd starts the bench on any --bench*
		_bench_path = opts.get("bench-out", "")
		if _bench_path == "":
			_bench_path = "user://bench/bench_%s.json" % Time.get_datetime_string_from_system().replace(":", "").replace("T", "_")
	if opts.has("gpu-time"):
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	RenderingServer.frame_post_draw.connect(_on_post_draw)
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	DisplayServer.window_set_min_size(Vector2i(960, 540))
	_make_hint()
	_start_window()
	print("[desktop] %s | %s | %s | window %s %s on screen %d" % [RenderingServer.get_current_rendering_driver_name(),
			RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_api_version(),
			_mode_name(), str(DisplayServer.window_get_size()), DisplayServer.window_get_current_screen()])


## Engine singletons outlive this node: a lambda left connected to Input.joy_connection_changed
## crashed the game on exit (access violation, Godot 4.7.2), so every hook is undone here.
func _exit_tree() -> void:
	OS.remove_logger(_tap)
	Input.joy_connection_changed.disconnect(_on_joy_connection_changed)
	RenderingServer.frame_post_draw.disconnect(_on_post_draw)


func _on_trick(trick_name: String) -> void:
	print("[desktop] trick: " + trick_name)


func _on_joy_connection_changed(dev: int, on: bool) -> void:
	print("[desktop] joypad %d %s: %s" % [dev, "connected" if on else "disconnected", Input.get_joy_name(dev)])


# --- window -----------------------------------------------------------------------------

func _start_window() -> void:
	var want: String = opts.get("window", "")
	if want == "windowed":
		return                             # the window as the engine made it (--resolution, --position)
	if want == "" and is_fullscreen():
		return                             # the engine's --fullscreen
	if want == "":
		var cf := ConfigFile.new()
		want = cf.get_value("window", "mode", "fullscreen") if cf.load(PREFS) == OK else "fullscreen"
	if want == "windowed":
		set_windowed()
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)


func is_fullscreen() -> bool:
	return DisplayServer.window_get_mode() in [DisplayServer.WINDOW_MODE_FULLSCREEN, DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN]


func _mode_name() -> String:
	return "fullscreen" if is_fullscreen() else "windowed"


## A 1920x1080 window, or the largest 16:9 window that fits a smaller screen (title bar and
## taskbar included), centred on the screen the game is on.
func set_windowed() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	await get_tree().process_frame         # decorations are only known once the mode applied
	var usable := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
	var deco := DisplayServer.window_get_size_with_decorations() - DisplayServer.window_get_size()
	if deco.x <= 0 or deco.y <= 0:
		deco = Vector2i(16, 39)            # Windows 11 border + title bar at 100 % scale
	var size := windowed_size(usable.size, deco)
	DisplayServer.window_set_size(size)
	DisplayServer.window_set_position(usable.position + (usable.size - size - deco) / 2 + Vector2i(deco.x / 2, deco.y - deco.x / 2))


static func windowed_size(usable: Vector2i, deco: Vector2i) -> Vector2i:
	var room := usable - deco
	if room.x >= BASE.x and room.y >= BASE.y:
		return BASE
	var k := minf(float(room.x) / BASE.x, float(room.y) / BASE.y)
	return Vector2i(int(BASE.x * k) / 2 * 2, int(BASE.y * k) / 2 * 2)


func toggle_fullscreen() -> void:
	window_toggles += 1
	if is_fullscreen():
		await set_windowed()
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	var cf := ConfigFile.new()
	cf.load(PREFS)
	cf.set_value("window", "mode", _mode_name())
	cf.save(PREFS)
	print("[desktop] window %s %s" % [_mode_name(), str(DisplayServer.window_get_size())])
	if opts.has("shots"):                  # the game's own frame at the new size
		await get_tree().create_timer(1.0).timeout
		_shot("toggle%d_%s" % [window_toggles, _mode_name()])


# --- menus: quit, hint ------------------------------------------------------------------

func _make_hint() -> void:
	hint_layer = CanvasLayer.new()
	hint_layer.layer = 11                  # above the menus (10)
	add_child(hint_layer)
	hint = Label.new()
	hint.add_theme_font_size_override("font_size", 24)
	hint.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	hint.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	hint.add_theme_constant_override("outline_size", 6)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		hint.set_anchor(side, 1.0)         # bottom-right corner of the screen
	hint.offset_left = -1024
	hint.offset_top = -52
	hint.offset_right = -24
	hint.offset_bottom = -18
	hint.visible = false
	hint_layer.add_child(hint)


func in_menu() -> bool:
	return main != null and main.menus.mode != main.menus.NONE


func _input(event: InputEvent) -> void:
	_count_input(event)
	if event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		if k.keycode == KEY_F11 or (k.alt_pressed and k.keycode in [KEY_ENTER, KEY_KP_ENTER]):
			if k.keycode != KEY_F11 and main != null:
				# Enter is also the menus' "confirm" and the key has already set that action
				# (Input.action_release() cannot clear a key's own press), so the menus skip
				# this frame: Alt+Enter must not also start or resume the run
				main.menus._cooldown = maxf(main.menus._cooldown, 0.1)
			get_viewport().set_input_as_handled()
			toggle_fullscreen()
			return
	if not in_menu():
		return
	var quit_press: bool = (event is InputEventKey and event.pressed and not event.echo and (event as InputEventKey).keycode == KEY_Q) \
			or (event is InputEventJoypadButton and event.pressed and (event as InputEventJoypadButton).button_index == JOY_BUTTON_B)
	if not quit_press:
		return
	get_viewport().set_input_as_handled()
	if _quit_armed > 0.0:
		var screen: String = ["", "start", "pause", "end"][main.menus.mode]
		print("[desktop] quit from the %s screen" % screen)
		if opts.has("info-out"):
			_write_info("quit from the %s screen" % screen)
		quit_game.call()
	else:
		_quit_armed = QUIT_CONFIRM_S
		Sfx.play("ui_select")


func _count_input(event: InputEvent) -> void:
	var log_it := opts.has("input-log")
	if event is InputEventKey and not event.echo:
		var k := event as InputEventKey
		var name := OS.get_keycode_string(k.keycode)
		if k.pressed:
			_input_counts["keys"][name] = _input_counts["keys"].get(name, 0) + 1
		if log_it:
			print("[desktop] key %s %s  actions: %s" % [name, "down" if k.pressed else "up", _actions(event)])
	elif event is InputEventJoypadButton:
		var b := event as InputEventJoypadButton
		if b.pressed:
			var key := "%d:%d" % [b.device, b.button_index]
			_input_counts["pad_buttons"][key] = _input_counts["pad_buttons"].get(key, 0) + 1
		if log_it:
			print("[desktop] pad %d button %d %s  actions: %s" % [b.device, b.button_index, "down" if b.pressed else "up", _actions(event)])
	elif event is InputEventJoypadMotion and absf((event as InputEventJoypadMotion).axis_value) > 0.5:
		var m := event as InputEventJoypadMotion
		var key := "%d:%d" % [m.device, m.axis]
		_input_counts["pad_axes"][key] = _input_counts["pad_axes"].get(key, 0) + 1


static func _actions(event: InputEvent) -> String:
	var out: Array[String] = []
	for a in InputMap.get_actions():
		if not String(a).begins_with("ui_") and InputMap.event_is_action(event, a):
			out.append(String(a))
	return ",".join(out)


# --- pause when the window loses focus ------------------------------------------------

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		pause_game()
	elif what == NOTIFICATION_WM_CLOSE_REQUEST and opts.has("info-out") and main != null:
		_write_info("window closed")


## Pauses a run in progress the way the player does: by pressing the game's "pause" action.
func pause_game() -> void:
	if main == null or not main.running or get_tree().paused or main.autopilot_mode != "":
		return
	var down := InputEventAction.new()
	down.action = &"pause"
	down.pressed = true
	Input.parse_input_event(down)
	print("[desktop] window lost focus: pausing")
	await get_tree().process_frame
	await get_tree().process_frame
	var up := InputEventAction.new()
	up.action = &"pause"
	up.pressed = false
	Input.parse_input_event(up)


# --- per frame ------------------------------------------------------------------------

func _process(delta: float) -> void:
	if main == null:
		var cs := get_tree().current_scene if get_tree().current_scene else get_tree().root.get_node_or_null("Main")
		if cs and cs.name == "Main" and cs.is_node_ready():
			main = cs
			if opts.has("input-log"):
				main.skater.trick.connect(_on_trick)
		else:
			return
	var menu := in_menu()
	if _quit_armed > 0.0:
		_quit_armed -= delta
	hint.visible = menu
	if menu:
		hint.text = "PRESS  Q / B  AGAIN TO QUIT" if _quit_armed > 0.0 else "Q / B  QUIT        F11 / ALT+ENTER  FULLSCREEN"
		hint.modulate = Color(1, 0.82, 0.12) if _quit_armed > 0.0 else Color(1, 1, 1, 0.8)
	var riding: bool = main.running and not get_tree().paused
	if riding != _was_riding:
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN if riding else Input.MOUSE_MODE_VISIBLE
		_was_riding = riding
	if opts.has("input-log") and main.skater.state != _last_state:
		_last_state = main.skater.state
		print("[desktop] skater %s  speed %.1f m/s" % [["GROUND", "AIR", "GRIND", "BAIL"][_last_state], main.skater.vel.length()])
	if riding and opts.has("info-out"):     # only the settings report uses it: keep benchmarks lean
		_sample_audio()
	if opts.has("input-log") and riding and int(main.RUN_TIME - main.time_left) != _last_speed_s:
		_last_speed_s = int(main.RUN_TIME - main.time_left)
		print("[desktop] run %d s: speed %.1f m/s" % [_last_speed_s, main.skater.vel.length()])
	for line in _tap.take():
		_write_bench(line)
	var run_t: float = main.RUN_TIME - main.time_left
	if opts.has("shots"):
		if not _start_shot_done and main.menus.mode == main.menus.START and Time.get_ticks_msec() - _t0 > 2500:
			_start_shot_done = true
			_shot("start_screen")
		if riding and run_t >= _shot_next:
			_shot("run_%03ds" % int(run_t))
			_shot_next = run_t + float(opts.get("shot-every", "15"))
	if opts.has("info-out") and not _info_started and Time.get_ticks_msec() - _t0 > 2000:
		_info_started = true
		_write_info("start")
	if _quit_deadline > 0.0 and (_bench_written or _bench_path == "" or Time.get_ticks_msec() / 1000.0 > _quit_deadline):
		if _bench_path != "" and not _bench_written:
			print("[desktop] no bench report came (no frames were rendered): quitting without one")
		print("[desktop] run over: quitting")
		_quit_deadline = -1.0
		quit_game.call()
	if main.menus.mode == main.menus.END and not _end_done:
		if _end_t < 0.0:
			_end_t = Time.get_ticks_msec() / 1000.0
		elif Time.get_ticks_msec() / 1000.0 - _end_t > 1.5:
			_end_done = true
			_at_end()


func _on_post_draw() -> void:
	if not opts.has("frametimes-out") or main == null:
		return
	var now := Time.get_ticks_usec()
	if not main.running or get_tree().paused:
		_last_draw_us = 0
		return
	if _last_draw_us > 0:
		_frames.append((now - _last_draw_us) / 1000.0)
		_frame_t.append(main.RUN_TIME - main.time_left)
		if opts.has("gpu-time"):
			_gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid()))
	_last_draw_us = now


func _sample_audio() -> void:
	var peak := maxf(AudioServer.get_bus_peak_volume_left_db(0, 0), AudioServer.get_bus_peak_volume_right_db(0, 0))
	_audio["frames"] += 1
	if peak > -60.0:
		_audio["frames_with_sound"] += 1
	_audio["max_peak_db"] = maxf(_audio["max_peak_db"], peak)
	for p in Sfx.get_children():
		if p is AudioStreamPlayer and p.playing and p.stream:
			var n = Sfx.streams.find_key(p.stream)
			_audio["sounds_played"][str(n) if n != null else "?"] = true


func _at_end() -> void:
	if opts.has("shots"):
		_shot("end_screen")
	if opts.has("frametimes-out"):
		_write_frametimes()
	if opts.has("info-out"):
		_write_info("end")
	if opts.has("quit-at-end"):
		# bench.gd reports as the end screen opens; a run without rendered frames (headless)
		# has nothing to report, so wait for it at most 10 s
		_quit_deadline = Time.get_ticks_msec() / 1000.0 + 10.0


# --- files ----------------------------------------------------------------------------

static func _open_for_write(path: String) -> FileAccess:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("[desktop] cannot write %s (%s)" % [path, error_string(FileAccess.get_open_error())])
	return f


func _write_bench(line: String) -> void:
	if _bench_path == "" or _bench_written:
		return
	var rep = JSON.parse_string(line.substr("[bench] ".length()))
	if not rep is Dictionary:
		return
	rep["desktop"] = system_info()
	var f := _open_for_write(_bench_path)
	if f:
		f.store_string(JSON.stringify(rep, "  ") + "\n")
		f.close()
		_bench_written = true
		print("[desktop] bench report -> " + ProjectSettings.globalize_path(_bench_path))


func _write_frametimes() -> void:
	var f := _open_for_write(opts["frametimes-out"])
	if f == null:
		return
	f.store_line("run_s,frame_ms" + (",gpu_ms" if opts.has("gpu-time") else ""))
	for i in _frames.size():
		var row := "%.3f,%.3f" % [_frame_t[i], _frames[i]]
		if opts.has("gpu-time"):
			row += ",%.3f" % _gpu[i]
		f.store_line(row)
	f.close()
	print("[desktop] %d frame times -> %s" % [_frames.size(), ProjectSettings.globalize_path(opts["frametimes-out"])])


func _write_info(when: String) -> void:
	var info := system_info()
	info["when"] = when
	info["input"] = _input_counts
	var au := _audio.duplicate(true)
	au["sounds_played"] = au["sounds_played"].keys()
	info["audio"]["run_levels"] = au
	if when != "start" and main:
		info["run"] = {"score": main.score.total, "goals": main.goals.map(func(g): return {g["id"]: g["done"]})}
	info["screenshots"] = _shots_taken
	var f := _open_for_write(opts["info-out"])
	if f:
		f.store_string(JSON.stringify(info, "  ") + "\n")
		f.close()
		print("[desktop] info (%s) -> %s" % [when, ProjectSettings.globalize_path(opts["info-out"])])


func _shot(name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var path: String = opts["shots"].path_join(name + ".png")
	DirAccess.make_dir_recursive_absolute(opts["shots"])
	if img and img.save_png(path) == OK:
		_shots_taken.append(path.get_file())
		print("[desktop] screenshot -> " + path)


## What the game runs with, read back from the engine: the report's settings half.
func system_info() -> Dictionary:
	var vp := get_viewport()
	var screen := DisplayServer.window_get_current_screen()
	var joypads := []
	for d in Input.get_connected_joypads():
		joypads.append({"device": d, "name": Input.get_joy_name(d), "guid": Input.get_joy_guid(d), "info": Input.get_joy_info(d)})
	var devices := AudioServer.get_output_device_list()
	return {
		"engine": Engine.get_version_info()["string"],
		"os": "%s %s" % [OS.get_name(), OS.get_version()],
		"cpu": "%s (%d threads)" % [OS.get_processor_name(), OS.get_processor_count()],
		"executable": OS.get_executable_path(),
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"rendering_driver": RenderingServer.get_current_rendering_driver_name(),
		"adapter": RenderingServer.get_video_adapter_name(),
		"adapter_vendor": RenderingServer.get_video_adapter_vendor(),
		"api_version": RenderingServer.get_video_adapter_api_version(),
		"window_mode": _mode_name(),
		"window_size": "%dx%d" % [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
		"render_size": "%dx%d" % [vp.get_visible_rect().size.x, vp.get_visible_rect().size.y],
		"screen": screen,
		"screen_size": "%dx%d" % [DisplayServer.screen_get_size(screen).x, DisplayServer.screen_get_size(screen).y],
		"screen_refresh_hz": snappedf(DisplayServer.screen_get_refresh_rate(screen), 0.01),
		"vsync": ["disabled", "enabled", "adaptive", "mailbox"][DisplayServer.window_get_vsync_mode()],
		"max_fps": Engine.max_fps,
		"physics_ticks": Engine.physics_ticks_per_second,
		"msaa_3d": ["off", "2x", "4x", "8x"][vp.msaa_3d],
		"scale_3d": vp.scaling_3d_scale,
		"environment": _env_info(),
		"audio": {"driver": AudioServer.get_driver_name(), "output_device": AudioServer.get_output_device(),
				"devices": devices.size(), "mix_rate": AudioServer.get_mix_rate(),
				"output_latency_ms": snappedf(AudioServer.get_output_latency() * 1000.0, 0.1),
				"speaker_mode": ["stereo", "surround 3.1", "surround 5.1", "surround 7.1"][AudioServer.get_speaker_mode()]},
		"joypads": joypads,
		"user_dir": OS.get_user_data_dir(),
	}


func _env_info() -> Dictionary:
	if main == null:
		return {}
	var env: Environment = main.env.environment
	return {"tonemap": ["linear", "reinhard", "filmic", "aces", "agx"][env.tonemap_mode], "ssao": env.ssao_enabled,
			"glow": env.glow_enabled, "fog": env.fog_enabled, "sun_shadows": main.sun.shadow_enabled,
			"adaptive_quality_step": main.QUALITY_STEPS[main.quality]}
