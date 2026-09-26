extends Node
## Frame-time benchmark for the two-minute run (?bench in the web build, --bench natively).
##
## Every frame is timed with the wall clock, not the engine's smoothed delta:
##   frame_ms   time between frames (what the player sees; capped by vsync unless the
##              browser runs with --disable-gpu-vsync --disable-frame-rate-limit)
##   cpu_ms     main-thread work for the frame: from its first physics step (or its
##              process step) until RenderingServer.frame_post_draw, split into
##              physics_ms (physics steps), script_ms (_process) and render_ms (culling +
##              draw-call submission). The GPU runs asynchronously after that.
## Also draw calls and primitives, and every figure per 10-second section of the run, so a
## slow spot in the park shows up.
##
## A/B switches (URL query or --flag): nossao, noglow, noshadow, nomsaa, msaa2x, nohair,
## noskater, nofog, scale=<0.25..2>, benchsecs=<n> (report after n seconds of run time).

var main: Node
var _last_us := 0
var _t0_us := 0
var _frame_start := 0
var _proc_start := 0
var _proc_end := 0
var _phys_us := 0
var _in_frame := false
var _frames: PackedFloat32Array = []      # time between frames, ms
var _cpu: PackedFloat32Array = []         # main-thread work per frame, ms
var _phys: PackedFloat32Array = []
var _script: PackedFloat32Array = []
var _render: PackedFloat32Array = []
var _draws: PackedInt32Array = []
var _prims: PackedInt32Array = []
var _section: PackedInt32Array = []
var _run_t: PackedFloat32Array = []      # run time of each frame, s
var _where: Dictionary = {}               # section -> skater position at its start
var opts: Dictionary = {}
var secs_limit := 0.0
var reported := false
var _query := ""


func _ready() -> void:
	process_priority = 1_000_000          # runs after every other _process: marks its end
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().physics_frame.connect(_on_physics_frame)
	get_tree().process_frame.connect(_on_process_frame)
	RenderingServer.frame_post_draw.connect(_on_post_draw)


func setup(query: String) -> void:
	_query = query
	for k in ["nossao", "noglow", "noshadow", "nomsaa", "msaa2x", "nohair", "noskater", "nofog"]:
		if k in query:
			opts[k] = true
	var m := RegEx.create_from_string("scale=([0-9.]+)").search(query)
	if m:
		opts["scale"] = float(m.get_string(1))
	m = RegEx.create_from_string("benchsecs=([0-9.]+)").search(query)
	if m:
		secs_limit = float(m.get_string(1))
	var env: Environment = main.env.environment
	if opts.has("nossao"):
		env.ssao_enabled = false
	if opts.has("noglow"):
		env.glow_enabled = false
	if opts.has("nofog"):
		env.fog_enabled = false
	if opts.has("noshadow"):
		main.sun.shadow_enabled = false
	if opts.has("nomsaa"):
		get_viewport().msaa_3d = Viewport.MSAA_DISABLED
	if opts.has("msaa2x"):
		get_viewport().msaa_3d = Viewport.MSAA_2X
	if opts.has("scale"):
		get_viewport().scaling_3d_scale = clampf(opts["scale"], 0.25, 2.0)
	m = RegEx.create_from_string("ssaoq=([0-4])").search(query)
	if m:
		opts["ssaoq"] = int(m.get_string(1))
	if "ssaofull" in query:
		opts["ssaofull"] = true
	if opts.has("ssaoq") or opts.has("ssaofull"):
		RenderingServer.environment_set_ssao_quality(opts.get("ssaoq", 2), not opts.has("ssaofull"), 0.5, 2, 50.0, 300.0)
	if opts.has("noskater"):
		main.skater.model.visible = false
	if opts.has("nohair"):
		for n in main.skater.model.find_children("Hair*", "MeshInstance3D", true, false):
			n.visible = false


func _on_physics_frame() -> void:
	var now := Time.get_ticks_usec()
	if not _in_frame:
		_in_frame = true
		_frame_start = now
		_phys_us = 0
	_proc_start = now                     # updated by each physics step; closed in process


func _on_process_frame() -> void:
	var now := Time.get_ticks_usec()
	if not _in_frame:
		_in_frame = true
		_frame_start = now
		_phys_us = 0
	else:
		_phys_us = now - _frame_start
	_proc_start = now


func _process(_delta: float) -> void:
	_proc_end = Time.get_ticks_usec()


func _on_post_draw() -> void:
	var now := Time.get_ticks_usec()
	var was := _in_frame
	_in_frame = false
	if not was or not main.running or get_tree().paused or reported:
		_last_us = 0
		return
	if _last_us == 0:
		_last_us = now
		_t0_us = now
		return
	var ms := (now - _last_us) / 1000.0
	_last_us = now
	var sec := int((main.RUN_TIME - main.time_left) / 10.0)
	if not _where.has(sec):
		_where[sec] = main.skater.global_position.snapped(Vector3.ONE * 0.5)
	_frames.append(ms)
	_cpu.append((now - _frame_start) / 1000.0)
	_phys.append(_phys_us / 1000.0)
	_script.append(maxi(0, _proc_end - _proc_start) / 1000.0)
	_render.append(maxi(0, now - _proc_end) / 1000.0)
	_draws.append(int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
	_prims.append(int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)))
	_section.append(sec)
	_run_t.append(main.RUN_TIME - main.time_left)
	# the limit is in run time (the same stretch of the route whatever the frame rate)
	if secs_limit > 0.0 and main.RUN_TIME - main.time_left >= secs_limit:
		report()


static func _pct(a: Array, p: float) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	return s[clampi(int(s.size() * p), 0, s.size() - 1)]


static func _mean(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var t := 0.0
	for v in a:
		t += v
	return t / a.size()


func _stats(idx: Array) -> Dictionary:
	var f := idx.map(func(i): return _frames[i])
	var total := 0.0
	for v in f:
		total += v
	var worst := f.duplicate()
	worst.sort()
	worst = worst.slice(int(worst.size() * 0.99))
	var cpu := idx.map(func(i): return _cpu[i])
	return {
		"frames": f.size(), "avg_fps": snappedf(f.size() / maxf(total / 1000.0, 0.001), 0.1),
		"median_ms": snappedf(_pct(f, 0.5), 0.01), "p95_ms": snappedf(_pct(f, 0.95), 0.01),
		"p95_fps": snappedf(1000.0 / maxf(_pct(f, 0.95), 0.001), 0.1),
		"p99_ms": snappedf(_pct(f, 0.99), 0.01), "max_ms": snappedf(_pct(f, 1.0), 0.01),
		"one_pct_low_fps": snappedf(1000.0 / maxf(_mean(worst), 0.001), 0.1),
		"frames_over_10ms": f.filter(func(v): return v > 10.0).size(), "frames_over_16_7ms": f.filter(func(v): return v > 16.7).size(),
		"cpu_ms_mean": snappedf(_mean(cpu), 0.01), "cpu_ms_p95": snappedf(_pct(cpu, 0.95), 0.01), "cpu_ms_max": snappedf(_pct(cpu, 1.0), 0.01),
		"physics_ms_mean": snappedf(_mean(idx.map(func(i): return _phys[i])), 0.01),
		"script_ms_mean": snappedf(_mean(idx.map(func(i): return _script[i])), 0.01),
		"render_submit_ms_mean": snappedf(_mean(idx.map(func(i): return _render[i])), 0.01),
		"render_submit_ms_p95": snappedf(_pct(idx.map(func(i): return _render[i]), 0.95), 0.01),
		"draw_calls_mean": int(_mean(idx.map(func(i): return _draws[i]))),
		"draw_calls_max": int(_pct(idx.map(func(i): return _draws[i]), 1.0)),
		"primitives_mean": int(_mean(idx.map(func(i): return _prims[i]))),
	}


func report() -> Dictionary:
	if reported or _frames.is_empty():
		return {}
	reported = true
	var all := range(_frames.size())
	var rep := _stats(all)
	var sections := []
	var keys := _where.keys()
	keys.sort()
	for s in keys:
		var idx := all.filter(func(i): return _section[i] == s)
		if idx.is_empty():
			continue
		var st := _stats(idx)
		sections.append({"t": "%d-%ds" % [s * 10, s * 10 + 10], "at": str(_where[s]), "p95_ms": st["p95_ms"], "median_ms": st["median_ms"],
				"max_ms": st["max_ms"], "cpu_ms": st["cpu_ms_mean"], "cpu_p95": st["cpu_ms_p95"], "render_submit_ms": st["render_submit_ms_mean"],
				"draws": st["draw_calls_mean"], "prims": st["primitives_mean"]})
	rep["sections"] = sections
	# the 12 slowest frames: when, and which phase took the time
	var order := all.duplicate()
	order.sort_custom(func(x, y): return _frames[x] > _frames[y])
	rep["slowest"] = order.slice(0, 12).map(func(i): return {"run_s": snappedf(_run_t[i], 0.01), "frame_ms": snappedf(_frames[i], 0.1),
			"cpu_ms": snappedf(_cpu[i], 0.1), "physics_ms": snappedf(_phys[i], 0.1), "script_ms": snappedf(_script[i], 0.1),
			"render_ms": snappedf(_render[i], 0.1), "draws": _draws[i]})
	var env: Environment = main.env.environment
	var vp := get_viewport()
	rep.merge({"seconds": snappedf((_last_us - _t0_us) / 1_000_000.0, 0.01), "viewport": "%dx%d" % [vp.get_visible_rect().size.x, vp.get_visible_rect().size.y],
		"scale_3d": vp.scaling_3d_scale, "msaa": ["off", "2x", "4x", "8x"][vp.msaa_3d], "ssao": env.ssao_enabled, "glow": env.glow_enabled,
		"tonemap": ["linear", "reinhard", "filmic", "aces", "agx"][env.tonemap_mode], "fog": env.fog_enabled, "sun_shadows": main.sun.shadow_enabled,
		"options": opts, "score": main.score.total, "renderer": RenderingServer.get_current_rendering_method(),
		"gpu": RenderingServer.get_video_adapter_name(), "api": RenderingServer.get_video_adapter_api_version()})
	if OS.has_feature("web"):
		rep["user_agent"] = str(JavaScriptBridge.eval("navigator.userAgent", true))
		rep["css_px"] = str(JavaScriptBridge.eval("innerWidth + 'x' + innerHeight + ' @' + devicePixelRatio", true))
		rep["webgl_renderer"] = str(JavaScriptBridge.eval(
				"(function(){try{var g=document.createElement('canvas').getContext('webgl2');var e=g.getExtension('WEBGL_debug_renderer_info');return e?g.getParameter(e.UNMASKED_RENDERER_WEBGL):g.getParameter(g.RENDERER)}catch(x){return ''}})()", true))
	print("[bench] " + JSON.stringify(rep))
	if OS.has_feature("web") and "benchreport" in _query:
		# hand the numbers to the serving host (only tests/bench_server.py takes them)
		JavaScriptBridge.eval("fetch('bench-result', {method: 'POST', body: %s}).catch(function(){})" % JSON.stringify(JSON.stringify(rep)))
	return rep
