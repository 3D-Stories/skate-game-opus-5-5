extends RefCounted
## The two-minute demo route through Eastside Baths (Godot coordinates, -Z = north; the
## level definition's Blender (x, y, z) is Godot (x, z, -y)). Played through the normal
## input interface by scripts/game/autopilot.gd; it collects S-K-A-T-E and the tape, knocks
## down the five signs, takes the high dive, grinds the deep end's coping and scores in the
## deep end until the buzzer.

const R := preload("res://scripts/game/autopilot_route.gd")


static func pos(ap) -> Vector3:
	return ap.skater.global_position


static func route() -> Array:
	var r: Array = []
	# --- the bleacher concourse (sign), the high-dive gantry (A) and the high dive (E)
	r.append(R.go(Vector3(-14.8, 4.2, -6.0), "north along the concourse (sign)", {"max_speed": 5.0, "radius": 1.0}))
	r.append(R.go(Vector3(-14.9, 4.2, -11.4), "to the gantry", {"max_speed": 3.6, "radius": 0.8}))
	r.append(R.go(Vector3(-12.4, 4.2, -13.0), "onto the gantry", {"max_speed": 3.6, "radius": 0.6}))
	r.append(R.go(Vector3(-4.8, 4.2, -13.0), "along the gantry (A)", {"radius": 0.8, "timeout": 6.0, "max_speed": 5.4}))
	r.append(R.until(R.in_air, "off the high board", {"steer": Vector3(6.0, 4.2, -13.0), "push": false, "max_speed": 5.4, "timeout": 3.0}))
	r.append(R.tap(["flip"], "kickflip the high dive", {"tap_stick": Vector2(-1, 0), "tap_time": 0.05}))
	r.append(R.until(R.on_ground, "splash down in the deep end (E)", {"timeout": 3.0}))
	# --- deep end airs across the pool (T above the west coping)
	var kick_indy := [["flip", Vector2.ZERO, 0.06, 0.06], ["grab", Vector2(1, 0), 0.5, 0.05], ["grab", Vector2.ZERO, 0.55, 0.3]]
	var tre_tail := [["flip", Vector2(0, 1), 0.06, 0.05], ["grab", Vector2(0, -1), 0.6, 0.05], ["grab", Vector2.ZERO, 0.65, 0.25]]
	var heel_melon_180 := [["flip", Vector2(1, 0), 0.06, 0.05], ["grab", Vector2(-1, 0), 0.52, 0.05], ["grab", Vector2.ZERO, 0.57, 0.3],
			["spin_right", Vector2.ZERO, 0.3, 0.55]]
	var shove_nose := [["flip", Vector2(0, -1), 0.06, 0.05], ["grab", Vector2(0, 1), 0.5, 0.05], ["grab", Vector2.ZERO, 0.55, 0.3]]
	var special := [["left", Vector2(-1, 0), 0.04, 0.05], ["right", Vector2(1, 0), 0.1, 0.05], ["flip", Vector2(1, 0), 0.12, 0.05],
			["grab", Vector2(-1, 0), 1.0, 0.05]]
	r.append({"do": "halfpipe", "note": "deep end airs (T)", "z": -9.0, "timeout": 20.0, "count": 4,
			"airs": [kick_indy, tre_tail, heel_melon_180, shove_nose], "special": special, "fallback": shove_nose})
	# --- out at the mellow shallow end: transfer over the east deck (K) onto the quarter
	r.append(R.go(Vector3(0.6, 0.0, 0.8), "south into the shallow end", {"radius": 1.6, "max_speed": 9.0, "timeout": 6.0}))
	r.append(R.until(R.in_air, "charge the shallow east wall", {"steer": Vector3(14.0, 0.0, 2.2), "hold": ["up"], "timeout": 4.0}))
	r.append(R.tap(["grab"], "melon over the deck (K)", {"tap_stick": Vector2(-1, 0), "tap_time": 0.05}))
	r.append(R.until(R.on_ground, "land by the east quarter", {"hold": ["grab"], "timeout": 3.0}))
	r.append(R.until(func(ap): return R.on_ground(ap) and ap.skater.up.y > 0.95 and ap.skater.vel.x < 0.0, "back down the quarter", {"timeout": 5.0}))
	# --- south along the east deck (two signs), the flat rail, west to the kicker (sign, S)
	r.append(R.go(Vector3(11.3, 0.0, 5.3), "south along the east deck (sign)", {"radius": 1.0, "max_speed": 6.0, "timeout": 5.0}))
	r.append(R.until(R.grinding, "onto the flat rail (sign)", {"steer": Vector3(11.5, 0.0, 20.0), "max_speed": 6.5, "timeout": 4.0,
			"input": func(ap): if pos(ap).z > 8.2: ap.hold("grind")}))
	r.append(R.until(func(ap): return not R.grinding(ap), "grind the flat rail", {"timeout": 4.0}))
	r.append(R.until(R.on_ground, "land", {"timeout": 2.0}))
	r.append(R.go(Vector3(8.6, 0.0, 17.8), "round the footbath", {"radius": 1.2, "max_speed": 6.0, "timeout": 4.0}))
	r.append(R.go(Vector3(5.6, 0.0, 16.9), "west along the south deck", {"radius": 1.6, "max_speed": 6.0, "timeout": 4.0}))
	r.append(R.go(Vector3(4.6, 0.0, 14.4), "turn up to the kicker (sign)", {"radius": 0.9, "max_speed": 6.0, "timeout": 4.0}))
	r.append(R.until(R.in_air, "kicker (S)", {"steer": Vector3(4.5, 0.0, 0.0), "timeout": 4.0}))
	r.append(R.tap(["flip"], "heelflip the pool hop", {"tap_stick": Vector2(1, 0), "tap_time": 0.05}))
	r.append(R.until(R.on_ground, "land in the shallow end", {"timeout": 3.0}))
	# --- the deep end: up the north wall and lip-grind the coping, out onto the north deck
	r.append(R.go(Vector3(2.5, 0.0, -7.5), "north into the deep end", {"radius": 1.5, "timeout": 6.0}))
	r.append(R.go(Vector3(2.5, 0.0, -11.0), "line up on the deep end wall", {"radius": 1.0, "timeout": 4.0}))
	r.append(R.until(R.in_air, "up the deep end wall", {"steer": Vector3(2.5, 0.0, -20.0), "hold": ["up"], "timeout": 4.0}))
	r.append(R.until(R.grinding, "lip grind the deep end coping", {"hold": ["grind"], "timeout": 2.0}))
	r.append(R.until(func(ap): return ap.skater.grind_t > 1.4 or not R.grinding(ap), "grind it", {"timeout": 3.0}))
	r.append(R.tap(["jump"], "hop off onto the deck", {"tap_time": 0.08,
			"input": func(ap): if ap.skater.grind_rail: ap._stick = Vector2(-0.45 * signf((ap.skater.grind_rail.dir_at(ap.skater.grind_s) * ap.skater.grind_sign).x), 0)}))
	r.append(R.until(R.on_ground, "land on the north deck", {"timeout": 3.0}))
	# --- east along the north deck (sign), through the grille into the boiler room (tape)
	r.append(R.go(Vector3(9.0, 0.0, -17.8), "east along the north deck", {"radius": 1.5, "max_speed": 7.0, "timeout": 6.0}))
	r.append(R.go(Vector3(13.0, 0.0, -18.9), "sign by the boiler room", {"radius": 1.0, "timeout": 4.0, "max_speed": 7.5}))
	r.append(R.until(R.in_air, "smash the grille, the boiler room kicker", {"steer": Vector3(28.0, 0.0, -19.0), "max_speed": 7.5, "timeout": 4.0}))
	r.append(R.tap(["grab"], "grab to the tape", {"tap_stick": Vector2(0, 1), "tap_time": 0.05}))
	r.append(R.until(R.on_ground, "land in the boiler room", {"hold": ["grab"], "timeout": 3.0}))
	r.append(R.until(func(ap): return R.on_ground(ap) and ap.skater.vel.x < -1.0 and ap.skater.up.y > 0.95, "back off the room's quarter", {"timeout": 5.0}))
	r.append(R.go(Vector3(21.2, 0.0, -20.65), "round the kicker", {"radius": 0.6, "max_speed": 5.0, "timeout": 4.0}))
	r.append(R.go(Vector3(17.4, 0.0, -20.5), "past the boilers", {"radius": 0.6, "max_speed": 5.0, "timeout": 4.0}))
	r.append(R.go(Vector3(13.0, 0.0, -19.0), "out of the boiler room", {"radius": 1.2, "max_speed": 6.0, "timeout": 4.0}))
	# --- back into the deep end: airs to the buzzer
	r.append(R.go(Vector3(3.5, 0.0, -17.6), "west along the north deck", {"radius": 1.2, "max_speed": 5.0, "timeout": 5.0}))
	r.append(R.until(func(ap): return pos(ap).y < -1.0, "drop in over the deep end coping", {"steer": Vector3(3.0, 0.0, -8.0), "max_speed": 4.0, "timeout": 4.0}))
	r.append({"do": "halfpipe", "note": "deep end airs to the buzzer", "z": -9.0, "timeout": 90.0, "count": 60,
			"airs": [kick_indy, tre_tail, heel_melon_180, special, shove_nose], "special": special, "fallback": shove_nose})
	return r
