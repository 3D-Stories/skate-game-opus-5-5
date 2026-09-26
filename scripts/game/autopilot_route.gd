extends RefCounted
## The two-minute demo route through the Warehouse (Godot coordinates, -Z = north).
## Each step steers / holds / taps inputs until its condition is met. The run collects
## every letter, the tape, grinds the rafters, breaks the windows and chains combos.


static func go(p: Vector3, note: String, extra := {}) -> Dictionary:
	var d := {"steer": p, "note": note}
	d.merge(extra, true)
	return d


static func until(cond: Callable, note: String, extra := {}) -> Dictionary:
	var d := {"until": cond, "note": note}
	d.merge(extra, true)
	return d


static func tap(actions: Array, note: String, extra := {}) -> Dictionary:
	var d := {"tap": actions, "time": 0.1, "note": note}
	d.merge(extra, true)
	return d


static func in_air(ap) -> bool:
	return ap.skater.state == Skater.AIR


static func on_ground(ap) -> bool:
	return ap.skater.state == Skater.GROUND


static func grinding(ap) -> bool:
	return ap.skater.state == Skater.GRIND


static func route() -> Array:
	var r: Array = []
	# --- the catwalk: A, then the kicker onto the rafter beam
	r.append(go(Vector3(-7.0, 5.0, 14.4), "deck to the catwalk", {"max_speed": 6.0, "radius": 1.2}))
	r.append(go(Vector3(-16.4, 5.0, 14.4), "south catwalk", {"max_speed": 6.5, "radius": 1.0}))
	r.append(go(Vector3(-18.8, 5.0, 11.0), "corner", {"push": false, "max_speed": 5.0, "radius": 1.0}))
	r.append(go(Vector3(-18.8, 5.0, -8.0), "west catwalk (A)", {"radius": 1.0}))
	r.append(until(in_air, "catwalk kicker", {"steer": Vector3(-18.8, 5.0, -30.0), "timeout": 6.0}))
	r.append(until(grinding, "boardslide the rafter", {"hold": ["grind"], "stick": Vector2(-1, 0), "timeout": 2.5}))
	r.append(until(func(ap): return not grinding(ap), "grind the whole rafter", {"timeout": 5.0}))
	r.append(tap(["flip"], "kickflip off the end"))
	r.append(until(on_ground, "land by the north wall", {"timeout": 3.0}))
	# --- the boarded-up wall and the secret tape
	r.append(go(Vector3(-12.0, 0.0, -48.4), "east along the north wall (past the crates)", {"radius": 1.5, "timeout": 5.0}))
	r.append(go(Vector3(-11.5, 0.0, -38.5), "line up on the doorway", {"radius": 1.2, "timeout": 5.0}))
	r.append(go(Vector3(-22.5, 0.0, -36.7), "smash the boarded wall", {"radius": 0.8, "timeout": 6.0}))
	r.append(until(in_air, "secret kicker", {"steer": Vector3(-27.0, 0.0, -37.0), "timeout": 3.0}))
	r.append(tap(["grab"], "melon to the tape", {"tap_stick": Vector2(-1, 0), "tap_time": 0.05}))
	r.append(until(on_ground, "land in the secret room", {"hold": ["grab"], "timeout": 3.0}))
	r.append(until(func(ap): return ap.skater.vel.x > 1.0 and on_ground(ap) and ap.skater.up.y > 0.9, "back off the mini quarter", {"timeout": 5.0}))
	r.append(go(Vector3(-26.8, 0.0, -34.2), "wide of the secret kicker", {"radius": 1.0, "timeout": 5.0, "max_speed": 6.0}))
	r.append(go(Vector3(-17.0, 0.0, -35.2), "out of the secret room", {"radius": 1.2}))
	# --- the wall pipe under the windows: ollie off the east coping, grind south (K)
	r.append(go(Vector3(8.5, 0.0, -35.3), "east, south of the halfpipe", {"radius": 1.5, "timeout": 5.0}))
	r.append(until(func(ap): return ap.skater.global_position.x > 16.3, "charge the east quarter",
			{"steer": Vector3(19.2, 0.0, -31.0), "timeout": 4.0}))
	r.append(until(in_air, "crouch, ollie at the lip", {"hold": ["jump"],
			"input": func(ap): if ap.skater.up.y < 0.3: ap._cur.erase("jump"), "timeout": 3.0}))
	r.append(until(grinding, "indy, then snap onto the wall pipe", {"tap": ["grab"],
			"input": func(ap): if ap.skater.global_position.y > 4.1: ap.hold("grind"), "timeout": 2.5}))
	r.append(until(func(ap): return ap.skater.global_position.z > -6.0 or not grinding(ap), "grind past the windows", {"timeout": 9.0}))
	r.append(tap(["jump"], "hop off into the quarter", {"tap_stick": Vector2(1, 0), "tap_time": 0.08}))
	r.append(tap(["flip"], "kickflip"))
	r.append(until(func(ap): return ap.skater.vel.y < -1.0 and ap.skater.global_position.y < 1.6 and ap.skater.trick_busy <= 0.0,
			"about to touch down", {"timeout": 2.5}))
	r.append(tap(["up"], "manual: up"))
	r.append(tap(["down"], "manual: down"))
	r.append(until(on_ground, "land in a manual", {"timeout": 3.0}))
	r.append(until(func(ap): return ap.skater.up.y > 0.95, "manual down the quarter", {"timeout": 3.0}))
	r.append({"time": 0.5, "note": "manual out", "steer": Vector3(3.0, 0.0, -0.5), "push": false})
	r.append(tap(["jump"], "ollie out of the manual"))
	r.append(until(on_ground, "land", {"timeout": 2.0}))
	# --- S over the kicker, then the funbox rail and E off the north kicker
	r.append(go(Vector3(3.0, 0.0, -0.5), "roll out west", {"radius": 1.5, "timeout": 8.0}))
	r.append(until(func(ap): return ap.skater.vel.z < -0.5, "up the drop-in and roll back fakie",
			{"steer": Vector3(0.3, 0.0, 6.0), "push": false, "timeout": 5.0}))
	r.append(until(in_air, "kicker (S)", {"steer": Vector3(0.0, 0.0, -20.0), "timeout": 4.0}))
	r.append(tap(["flip"], "heelflip", {"tap_stick": Vector2(1, 0), "tap_time": 0.05}))
	r.append(until(func(ap): return ap.skater.vel.y < -1.5, "falling", {"timeout": 2.0}))
	r.append(tap(["down"], "nose manual: down"))
	r.append(tap(["up"], "nose manual: up"))
	r.append(until(on_ground, "land in a nose manual", {"timeout": 2.0}))
	r.append(until(func(ap): return ap.skater.global_position.z < -13.9, "nose manual up to the funbox", {"steer": Vector3(0.0, 0.0, -20.0), "timeout": 3.0}))
	r.append(until(grinding, "pop onto the funbox rail", {"tap": ["grind"], "steer": Vector3(0.0, 0.0, -20.0), "timeout": 1.0}))
	r.append(until(func(ap): return not grinding(ap), "grind it out", {"timeout": 3.0}))
	r.append(until(on_ground, "land off the funbox", {"timeout": 2.0}))
	r.append(go(Vector3(-7.8, 0.0, -21.5), "west of ledge B", {"radius": 1.5, "timeout": 5.0, "max_speed": 8.5}))
	r.append(go(Vector3(-9.0, 0.0, -26.0), "line up on the north kicker", {"radius": 1.3, "timeout": 4.0, "max_speed": 8.5}))
	r.append(until(in_air, "north kicker (E)", {"steer": Vector3(-9.0, 0.0, -40.0), "timeout": 3.0}))
	r.append(tap(["grab"], "melon", {"tap_stick": Vector2(-1, 0), "tap_time": 0.05}))
	r.append(until(on_ground, "land", {"hold": ["grab"], "timeout": 3.0}))
	# --- the halfpipe to the end of the run: vert airs (T above the west coping)
	r.append(until(func(ap): return ap.skater.vel.length() < 4.5, "brake", {"stick": Vector2(0, -1), "timeout": 2.0}))
	r.append(go(Vector3(-12.0, 0.0, -37.5), "turn back west of the halfpipe", {"radius": 1.2, "max_speed": 4.5, "timeout": 5.0}))
	r.append(go(Vector3(-10.0, 0.0, -33.5), "head south", {"radius": 1.2, "max_speed": 6.0, "timeout": 5.0}))
	r.append(go(Vector3(-3.0, 0.0, -34.5), "to the halfpipe mouth", {"radius": 1.2, "timeout": 5.0}))
	r.append(go(Vector3(0.0, 0.0, -41.5), "into the halfpipe", {"radius": 1.2, "max_speed": 5.0}))
	r.append(until(func(ap): return absf(ap.skater.heading.x) > 0.97, "turn across the flat at the T",
			{"steer": Vector3(-6.0, 0.0, -43.0), "push": false, "max_speed": 4.0, "timeout": 3.0}))
	# trick patterns per air: [action, stick, start (s after takeoff), hold time]
	var kick_indy_180 := [["flip", Vector2.ZERO, 0.06, 0.06], ["grab", Vector2(1, 0), 0.5, 0.05], ["grab", Vector2.ZERO, 0.55, 0.3],
			["spin_left", Vector2.ZERO, 0.3, 0.55]]
	var tre_tail := [["flip", Vector2(0, 1), 0.06, 0.05], ["grab", Vector2(0, -1), 0.6, 0.05], ["grab", Vector2.ZERO, 0.65, 0.25]]
	var heel_nose_180 := [["flip", Vector2(1, 0), 0.06, 0.05], ["grab", Vector2(0, 1), 0.52, 0.05], ["grab", Vector2.ZERO, 0.57, 0.3],
			["spin_right", Vector2.ZERO, 0.3, 0.55]]
	var special := [["left", Vector2(-1, 0), 0.04, 0.05], ["right", Vector2(1, 0), 0.1, 0.05], ["flip", Vector2(1, 0), 0.12, 0.05],
			["grab", Vector2(-1, 0), 1.0, 0.05]]
	var shove_melon := [["flip", Vector2(0, -1), 0.06, 0.05], ["grab", Vector2(-1, 0), 0.5, 0.05], ["grab", Vector2.ZERO, 0.55, 0.3]]
	r.append({"do": "halfpipe", "note": "halfpipe airs to the buzzer", "z": -43.0, "timeout": 90.0, "count": 60,
			"airs": [kick_indy_180, tre_tail, heel_nose_180, special], "special": special, "fallback": shove_melon})
	return r
