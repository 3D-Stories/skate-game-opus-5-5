class_name ScoreKeeper
extends RefCounted
## THPS scoring rules, independent of the physics so it can be unit-tested headless.
##   combo score = (sum of trick points) x (number of tricks in the combo)
##   repeating a trick inside a combo degrades it (100%, 75%, 50%, 25%, 10%)
##   landing banks the combo; bailing loses it and empties the special meter
##   landed tricks fill the special meter; when full the special trick unlocks

signal combo_changed
signal combo_landed(points: int)
signal combo_lost
signal special_full

var total := 0
var best_combo := 0
var tricks: Array = []          # [{name, points, base, held, repeat}]
var counts: Dictionary = {}
var special := 0.0              # 0..100
var special_ready := false
var in_combo := false
var last_land := 0


func begin_trick(name: String, base_points: int) -> int:
	## Adds a trick to the current combo (starting one if needed). Returns its index.
	in_combo = true
	var n: int = counts.get(name, 0)
	counts[name] = n + 1
	var f: float = Tricks.REPEAT_FACTORS[mini(n, Tricks.REPEAT_FACTORS.size() - 1)]
	tricks.append({"name": name, "base": base_points, "held": 0.0, "factor": f,
			"points": int(round(base_points * f))})
	combo_changed.emit()
	return tricks.size() - 1


func add_hold(index: int, extra: float) -> void:
	## Held tricks (grinds, manuals, grabs) keep earning points while held.
	if index < 0 or index >= tricks.size():
		return
	var t: Dictionary = tricks[index]
	t["held"] = float(t["held"]) + extra
	t["points"] = int(round((float(t["base"]) + float(t["held"])) * float(t["factor"])))
	combo_changed.emit()


func rename(index: int, name: String) -> void:
	if index >= 0 and index < tricks.size():
		tricks[index]["name"] = name
		combo_changed.emit()


func base_sum() -> int:
	var s := 0
	for t in tricks:
		s += int(t["points"])
	return s


func multiplier() -> int:
	return tricks.size()


func combo_score() -> int:
	return base_sum() * multiplier()


func combo_text() -> String:
	var names: PackedStringArray = []
	for t in tricks:
		names.append(String(t["name"]))
	return " + ".join(names)


func land() -> int:
	## Bank the combo. Returns the points awarded.
	if not in_combo:
		return 0
	var pts := combo_score()
	total += pts
	best_combo = maxi(best_combo, pts)
	last_land = pts
	var was_ready := special_ready
	special = minf(100.0, special + clampf(pts / 90.0, 4.0, 45.0))
	if special >= 100.0:
		special_ready = true
		if not was_ready:
			special_full.emit()
	_clear()
	combo_landed.emit(pts)
	return pts


func bail() -> void:
	_clear()
	special = 0.0
	special_ready = false
	combo_lost.emit()


func tick(dt: float) -> void:
	## The meter drains slowly unless it is full.
	if not special_ready and special > 0.0 and not in_combo:
		special = maxf(0.0, special - 2.0 * dt)


func use_special() -> bool:
	if not special_ready:
		return false
	return true


func reset() -> void:
	total = 0
	best_combo = 0
	special = 0.0
	special_ready = false
	_clear()


func _clear() -> void:
	tricks.clear()
	counts.clear()
	in_combo = false
	combo_changed.emit()


static func format_points(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out
