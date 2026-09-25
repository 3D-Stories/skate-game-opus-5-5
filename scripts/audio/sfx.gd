extends Node
## Every sound in the game is synthesised here at startup - no sample files, no music.
## Buffers are AudioStreamWAV (16-bit PCM) so the web build can play them as samples
## (AudioStreamGenerator is not available in that mode). Loops are cross-faded to be
## seamless; pitch and volume are driven at runtime by the skater (speed, surface).

const RATE := 22050

var streams: Dictionary = {}
var _pool: Array[AudioStreamPlayer] = []
var _pool_i := 0
var _rng := RandomNumberGenerator.new()
var listener_pos := Vector3.ZERO
var ready_flag := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.seed = 1337
	for i in 14:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_pool.append(p)
	_build_all()
	ready_flag = true


func play(sound: String, at = null, volume_db := 0.0, pitch := 1.0) -> void:
	if not streams.has(sound):
		return
	var vol := volume_db
	if at is Vector3:
		var d: float = (at as Vector3).distance_to(listener_pos)
		vol -= clampf((d - 4.0) * 0.6, 0.0, 24.0)
	var p := _pool[_pool_i]
	_pool_i = (_pool_i + 1) % _pool.size()
	p.stream = streams[sound]
	p.volume_db = vol
	p.pitch_scale = pitch
	p.play()


func stream(sound: String) -> AudioStreamWAV:
	return streams.get(sound)


# ------------------------------------------------------------------ building blocks

func _noise(n: int) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(n)
	for i in n:
		a[i] = _rng.randf_range(-1.0, 1.0)
	return a


func _brown(n: int, leak := 0.995) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(n)
	var v := 0.0
	for i in n:
		v = v * leak + _rng.randf_range(-1.0, 1.0) * 0.12
		a[i] = v
	return a


func _lowpass(a: PackedFloat32Array, hz: float) -> PackedFloat32Array:
	var k := 1.0 - exp(-TAU * hz / RATE)
	var v := 0.0
	var o := PackedFloat32Array()
	o.resize(a.size())
	for i in a.size():
		v += (a[i] - v) * k
		o[i] = v
	return o


func _highpass(a: PackedFloat32Array, hz: float) -> PackedFloat32Array:
	var lp := _lowpass(a, hz)
	var o := PackedFloat32Array()
	o.resize(a.size())
	for i in a.size():
		o[i] = a[i] - lp[i]
	return o


## RBJ biquad band-pass (constant peak gain).
func _bandpass(a: PackedFloat32Array, hz: float, q: float) -> PackedFloat32Array:
	var w0 := TAU * hz / RATE
	var alpha := sin(w0) / (2.0 * q)
	var b0 := alpha
	var b2 := -alpha
	var a0 := 1.0 + alpha
	var a1 := -2.0 * cos(w0)
	var a2 := 1.0 - alpha
	var x1 := 0.0
	var x2 := 0.0
	var y1 := 0.0
	var y2 := 0.0
	var o := PackedFloat32Array()
	o.resize(a.size())
	for i in a.size():
		var x := a[i]
		var y := (b0 * x + b2 * x2 - a1 * y1 - a2 * y2) / a0
		x2 = x1
		x1 = x
		y2 = y1
		y1 = y
		o[i] = y
	return o


func _mix(dst: PackedFloat32Array, src: PackedFloat32Array, gain: float, offset := 0) -> void:
	for i in src.size():
		var j := i + offset
		if j >= 0 and j < dst.size():
			dst[j] += src[i] * gain


func _zeros(n: int) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(n)
	a.fill(0.0)
	return a


## Exponentially decaying sine with an optional downward pitch glide.
func _tone(hz: float, dur: float, decay: float, glide := 0.0, harm := 0.0) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var o := PackedFloat32Array()
	o.resize(n)
	var ph := 0.0
	for i in n:
		var t := float(i) / RATE
		var f := hz * (1.0 - glide * (1.0 - exp(-t * 18.0)))
		ph += TAU * f / RATE
		var s := sin(ph) + harm * sin(ph * 2.01) + harm * 0.5 * sin(ph * 3.03)
		o[i] = s * exp(-t / decay)
	return o


func _burst(dur: float, decay: float, lp := 8000.0, hp := 40.0) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var a := _noise(n)
	for i in n:
		a[i] *= exp(-(float(i) / RATE) / decay)
	a = _lowpass(a, lp)
	if hp > 0.0:
		a = _highpass(a, hp)
	return a


func _knock(hz: float, amp := 1.0) -> PackedFloat32Array:
	var k := _tone(hz, 0.12, 0.018, 0.25, 0.4)
	var c := _burst(0.03, 0.004, 6000.0, 800.0)
	_mix(k, c, 0.6)
	for i in k.size():
		k[i] *= amp
	return k


func _normalize(a: PackedFloat32Array, peak := 0.9) -> PackedFloat32Array:
	var m := 0.0001
	for v in a:
		m = maxf(m, absf(v))
	for i in a.size():
		a[i] = a[i] / m * peak
	return a


## Seamless loop: cross-fade the tail over the head.
func _loopify(a: PackedFloat32Array, fade_s := 0.15) -> PackedFloat32Array:
	var f := int(fade_s * RATE)
	var n := a.size() - f
	var o := PackedFloat32Array()
	o.resize(n)
	for i in n:
		o[i] = a[i]
	for i in f:
		var w := float(i) / f
		o[i] = a[i] * w + a[n + i] * (1.0 - w)
	return o


func _wav(a: PackedFloat32Array, loop := false) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(a.size() * 2)
	for i in a.size():
		var v := int(clampf(a[i], -1.0, 1.0) * 32767.0)
		bytes.encode_s16(i * 2, v)
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = bytes
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = a.size()
	return w


# ------------------------------------------------------------------ the sounds

func _build_all() -> void:
	streams["roll_concrete"] = _wav(_roll_concrete(), true)
	streams["roll_wood"] = _wav(_roll_wood(), true)
	streams["roll_metal"] = _wav(_roll_metal(), true)
	streams["grind_metal"] = _wav(_grind_metal(), true)
	streams["grind_wood"] = _wav(_grind_wood(), true)
	streams["grind_concrete"] = _wav(_grind_concrete(), true)
	streams["wind"] = _wav(_wind(), true)
	streams["pop"] = _wav(_pop())
	streams["land"] = _wav(_land())
	streams["land_hard"] = _wav(_land(true))
	streams["catch"] = _wav(_catch())
	streams["bail"] = _wav(_bail())
	streams["clatter"] = _wav(_clatter(0.9, 6))
	streams["glass"] = _wav(_glass())
	streams["wall"] = _wav(_wall())
	streams["letter"] = _wav(_chime([880.0, 1108.7, 1318.5], 0.07, 0.6))
	streams["tape"] = _wav(_chime([659.3, 830.6, 987.8, 1318.5, 1661.2], 0.08, 1.2))
	streams["goal"] = _wav(_fanfare())
	streams["combo"] = _wav(_chime([1567.98, 2093.0], 0.06, 0.35))
	streams["special"] = _wav(_whoosh(0.9, true))
	streams["whoosh"] = _wav(_whoosh(0.35, false))
	streams["ui_move"] = _wav(_tone(1200.0, 0.06, 0.02))
	streams["ui_select"] = _wav(_chime([900.0, 1350.0], 0.04, 0.2))
	streams["bail_voice"] = _wav(_grunt())


func _roll_concrete() -> PackedFloat32Array:
	var n := int(2.2 * RATE)
	var a := _brown(n, 0.99)
	a = _highpass(_lowpass(a, 1400.0), 55.0)
	var grit := _bandpass(_noise(n), 2600.0, 1.2)
	_mix(a, grit, 0.12)
	# expansion joints / cracks: small double clicks (front then back truck)
	var t := 0.18
	while t < 2.0:
		var c := _burst(0.02, 0.003, 3500.0, 200.0)
		_mix(a, c, _rng.randf_range(0.25, 0.6), int(t * RATE))
		_mix(a, c, _rng.randf_range(0.2, 0.45), int((t + 0.06) * RATE))
		t += _rng.randf_range(0.35, 0.6)
	return _normalize(_loopify(a), 0.7)


func _roll_wood() -> PackedFloat32Array:
	var n := int(2.2 * RATE)
	var src := _brown(n, 0.985)
	var a := _bandpass(src, 190.0, 2.5)
	_mix(a, _bandpass(src, 420.0, 4.0), 0.6)
	_mix(a, _lowpass(_noise(n), 900.0), 0.08)
	var t := 0.3
	while t < 2.0:
		_mix(a, _knock(_rng.randf_range(140.0, 220.0), 0.25), 1.0, int(t * RATE))
		t += _rng.randf_range(0.5, 0.9)
	return _normalize(_loopify(a), 0.75)


func _roll_metal() -> PackedFloat32Array:
	var n := int(1.8 * RATE)
	var src := _noise(n)
	var a := _bandpass(src, 950.0, 12.0)
	_mix(a, _bandpass(src, 1720.0, 16.0), 0.7)
	_mix(a, _bandpass(src, 2630.0, 18.0), 0.5)
	_mix(a, _lowpass(_brown(n), 600.0), 0.6)
	var t := 0.05
	while t < 1.6:
		_mix(a, _burst(0.015, 0.002, 7000.0, 1500.0), 0.3, int(t * RATE))
		t += _rng.randf_range(0.07, 0.14)
	return _normalize(_loopify(a), 0.6)


func _grind_metal() -> PackedFloat32Array:
	var n := int(1.4 * RATE)
	var a := _highpass(_noise(n), 1800.0)
	var jitter := _lowpass(_noise(n), 60.0)
	for i in n:
		a[i] *= 0.55 + 2.2 * absf(jitter[i])
	var ring := _zeros(n)
	for f in [1830.0, 2745.0, 4110.0, 5320.0]:
		var ph := 0.0
		for i in n:
			var t := float(i) / RATE
			ph += TAU * f * (1.0 + 0.004 * sin(t * 37.0)) / RATE
			ring[i] += sin(ph) * (0.3 if f < 3000.0 else 0.18)
	_mix(a, ring, 0.35)
	_mix(a, _bandpass(_noise(n), 600.0, 2.0), 0.4)
	return _normalize(_loopify(a, 0.1), 0.7)


func _grind_wood() -> PackedFloat32Array:
	var n := int(1.4 * RATE)
	var a := _bandpass(_noise(n), 750.0, 1.3)
	_mix(a, _bandpass(_brown(n), 240.0, 2.0), 0.8)
	var t := 0.02
	while t < 1.3:
		_mix(a, _burst(0.01, 0.002, 5000.0, 800.0), _rng.randf_range(0.2, 0.5), int(t * RATE))
		t += _rng.randf_range(0.02, 0.06)
	return _normalize(_loopify(a, 0.1), 0.7)


func _grind_concrete() -> PackedFloat32Array:
	var n := int(1.4 * RATE)
	var a := _bandpass(_noise(n), 1150.0, 1.1)
	var j := _lowpass(_noise(n), 30.0)
	for i in n:
		a[i] *= 0.6 + 1.5 * absf(j[i])
	_mix(a, _lowpass(_brown(n), 300.0), 0.5)
	return _normalize(_loopify(a, 0.1), 0.7)


func _wind() -> PackedFloat32Array:
	var n := int(2.5 * RATE)
	var a := _bandpass(_noise(n), 380.0, 0.8)
	var m := _lowpass(_noise(n), 1.5)
	for i in n:
		a[i] *= 0.5 + 3.0 * absf(m[i])
	return _normalize(_loopify(a, 0.3), 0.6)


func _pop() -> PackedFloat32Array:
	var a := _zeros(int(0.3 * RATE))
	_mix(a, _burst(0.012, 0.0015, 9000.0, 1200.0), 1.0)
	_mix(a, _tone(560.0, 0.12, 0.02, 0.2, 0.5), 0.7)
	_mix(a, _tone(185.0, 0.2, 0.045, 0.1, 0.3), 0.8)
	_mix(a, _burst(0.08, 0.02, 2500.0, 100.0), 0.3, int(0.01 * RATE))
	return _normalize(a, 0.95)


func _land(hard := false) -> PackedFloat32Array:
	var a := _zeros(int(0.5 * RATE))
	_mix(a, _tone(95.0, 0.3, 0.07 if not hard else 0.11, 0.45), 1.0)
	_mix(a, _knock(260.0, 0.8), 1.0)
	_mix(a, _knock(310.0, 0.6), 1.0, int(0.025 * RATE))
	_mix(a, _burst(0.15, 0.03, 1800.0, 60.0), 0.6)
	if hard:
		_mix(a, _burst(0.3, 0.08, 1200.0, 40.0), 0.5)
	return _normalize(a, 0.95)


func _catch() -> PackedFloat32Array:
	var a := _zeros(int(0.15 * RATE))
	_mix(a, _knock(420.0, 1.0), 1.0)
	_mix(a, _knock(380.0, 0.6), 1.0, int(0.018 * RATE))
	return _normalize(a, 0.7)


func _clatter(dur: float, hits: int) -> PackedFloat32Array:
	var a := _zeros(int(dur * RATE))
	var t := 0.0
	for i in hits:
		var amp := 1.0 - float(i) / (hits + 1)
		_mix(a, _knock(_rng.randf_range(280.0, 620.0), amp), 1.0, int(t * RATE))
		_mix(a, _burst(0.02, 0.004, 6000.0, 1500.0), 0.3 * amp, int(t * RATE))
		t += _rng.randf_range(0.06, 0.16) * (1.0 + i * 0.25)
		if t > dur - 0.12:
			break
	return a


func _bail() -> PackedFloat32Array:
	var a := _zeros(int(1.5 * RATE))
	_mix(a, _tone(70.0, 0.4, 0.09, 0.4), 1.0)
	_mix(a, _burst(0.25, 0.06, 900.0, 40.0), 0.8)
	var slide := _bandpass(_noise(int(0.9 * RATE)), 1300.0, 0.9)
	for i in slide.size():
		slide[i] *= exp(-float(i) / RATE / 0.35)
	_mix(a, slide, 0.35, int(0.12 * RATE))
	_mix(a, _clatter(1.2, 7), 0.9, int(0.1 * RATE))
	return _normalize(a, 0.95)


func _glass() -> PackedFloat32Array:
	var a := _zeros(int(1.4 * RATE))
	_mix(a, _burst(0.35, 0.07, 11000.0, 2500.0), 1.0)
	for i in 34:
		var t := _rng.randf_range(0.0, 1.0) * _rng.randf()
		_mix(a, _tone(_rng.randf_range(2800.0, 7200.0), 0.18, _rng.randf_range(0.02, 0.06)), _rng.randf_range(0.1, 0.35), int(t * RATE))
	return _normalize(a, 0.9)


func _wall() -> PackedFloat32Array:
	var a := _zeros(int(1.1 * RATE))
	_mix(a, _burst(0.25, 0.05, 1600.0, 60.0), 1.0)
	_mix(a, _tone(80.0, 0.35, 0.1, 0.3), 0.9)
	var t := 0.02
	while t < 0.8:
		_mix(a, _knock(_rng.randf_range(150.0, 400.0), 0.5 * (1.0 - t)), 1.0, int(t * RATE))
		t += _rng.randf_range(0.03, 0.09)
	return _normalize(a, 0.95)


func _chime(notes: Array, step: float, dur: float) -> PackedFloat32Array:
	var a := _zeros(int(dur * RATE))
	for i in notes.size():
		_mix(a, _tone(notes[i], dur, dur * 0.35, 0.0, 0.15), 0.6, int(i * step * RATE))
	return _normalize(a, 0.6)


func _fanfare() -> PackedFloat32Array:
	var a := _zeros(int(1.1 * RATE))
	var notes := [523.25, 659.25, 783.99, 1046.5]
	for i in notes.size():
		var n := int(0.5 * RATE)
		var s := PackedFloat32Array()
		s.resize(n)
		var ph := 0.0
		for k in n:
			var t := float(k) / RATE
			ph += TAU * notes[i] / RATE
			# soft band-limited square: odd harmonics
			var v := sin(ph) + sin(ph * 3.0) / 3.0 + sin(ph * 5.0) / 5.0
			s[k] = v * minf(1.0, t * 80.0) * exp(-t / (0.35 if i == 3 else 0.12))
		_mix(a, s, 0.4, int(i * 0.11 * RATE))
	return _normalize(a, 0.55)


func _whoosh(dur: float, rising: bool) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var src := _noise(n)
	var a := _zeros(n)
	var chunk := 512
	var i := 0
	while i < n:
		var t := float(i) / n
		var f := 300.0 + (2400.0 * t if rising else 1200.0 * (1.0 - t))
		var seg := src.slice(i, mini(n, i + chunk + 64))
		var bp := _bandpass(seg, f, 1.5)
		for k in range(mini(chunk, bp.size())):
			var env := sin(PI * float(i + k) / n)
			a[i + k] = bp[k] * env
		i += chunk
	return _normalize(a, 0.6)


func _grunt() -> PackedFloat32Array:
	var n := int(0.35 * RATE)
	var a := PackedFloat32Array()
	a.resize(n)
	var ph := 0.0
	for i in n:
		var t := float(i) / RATE
		var f := 140.0 - 50.0 * t
		ph += TAU * f / RATE
		var v := sin(ph) + 0.6 * sin(ph * 2.0) + 0.4 * sin(ph * 3.0) + 0.3 * sin(ph * 4.0)
		a[i] = v * minf(1.0, t * 40.0) * exp(-t / 0.15)
	a = _bandpass(a, 700.0, 1.2)
	return _normalize(a, 0.5)
