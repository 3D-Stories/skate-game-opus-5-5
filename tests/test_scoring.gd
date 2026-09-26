extends SceneTree
## Headless tests for the THPS scoring rules, the special meter and the HUD totals.
##   godot --headless --path . -s tests/test_scoring.gd
## Writes tests/results/scoring.txt and exits non-zero on any failure.

var passed := 0
var failed := 0
var out: PackedStringArray = []


func check(ok: bool, what: String, detail := "") -> void:
	if ok:
		passed += 1
		out.append("PASS  " + what)
	else:
		failed += 1
		out.append("FAIL  " + what + ("  (" + detail + ")" if detail != "" else ""))


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	combo_multiplier()
	repeats_degrade()
	held_tricks()
	landing_and_bail()
	special_meter()
	spins_and_names()
	await hud_totals()
	var report := "Pro Skater scoring tests  %s\n%s\n%d passed, %d failed\n" % [
			Time.get_datetime_string_from_system(), "\n".join(out), passed, failed]
	print(report)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/results"))
	var f := FileAccess.open("res://tests/results/scoring.txt", FileAccess.WRITE)
	f.store_string(report)
	f.close()
	quit(1 if failed > 0 else 0)


func combo_multiplier() -> void:
	var s := ScoreKeeper.new()
	s.begin_trick("Kickflip", 100)
	s.begin_trick("Indy", 200)
	check(s.base_sum() == 300 and s.multiplier() == 2, "combo sum and multiplier (100 + 200) x 2")
	check(s.combo_score() == 600, "combo score = base sum x number of tricks", str(s.combo_score()))
	var got := s.land()
	check(got == 600 and s.total == 600, "landing banks the combo", "%d %d" % [got, s.total])
	check(not s.in_combo and s.tricks.is_empty(), "combo cleared after landing")
	check(Array(s.last_combo) == ["Kickflip", "Indy"], "landed combo keeps its trick list", str(s.last_combo))
	s.begin_trick("Kickflip", 100)
	s.begin_trick("50-50", 100)
	s.begin_trick("Manual", 100)
	s.begin_trick("Melon", 200)
	check(s.combo_score() == 500 * 4, "flip + grind + manual + grab chain into one x4 combo", str(s.combo_score()))


func repeats_degrade() -> void:
	var s := ScoreKeeper.new()
	for i in 5:
		s.begin_trick("Kickflip", 100)
	# 100% 75% 50% 25% 10%
	check(s.base_sum() == 100 + 75 + 50 + 25 + 10, "repeated trick loses value 100/75/50/25/10%", str(s.base_sum()))
	check(s.combo_score() == 260 * 5, "degraded repeats still count toward the multiplier", str(s.combo_score()))
	s.land()
	s.begin_trick("Kickflip", 100)
	check(s.base_sum() == 100, "repeat penalty resets in a new combo", str(s.base_sum()))


func held_tricks() -> void:
	var s := ScoreKeeper.new()
	var i := s.begin_trick("50-50", 100)
	s.add_hold(i, 150.0 * 2.0)     # two seconds of grinding
	check(s.base_sum() == 400, "grind earns its per-second value while held", str(s.base_sum()))
	s.begin_trick("50-50", 100)
	var j := s.tricks.size() - 1
	s.add_hold(j, 100.0)
	check(int(s.tricks[j]["points"]) == 150, "held value is degraded on a repeat too (75%)", str(s.tricks[j]["points"]))


func landing_and_bail() -> void:
	var s := ScoreKeeper.new()
	s.begin_trick("Heelflip", 100)
	s.land()
	var before := s.total
	var lost := [false]
	s.combo_lost.connect(func(): lost[0] = true)
	s.begin_trick("Kickflip", 100)
	s.begin_trick("Tailgrab", 250)
	s.bail()
	check(s.total == before and lost[0], "bailing loses the combo (no points)", "%d" % s.total)
	check(s.special == 0.0 and not s.special_ready, "bailing empties the special meter")
	check(s.land() == 0, "landing with no combo scores nothing")


func special_meter() -> void:
	var s := ScoreKeeper.new()
	var fired := [0]
	s.special_full.connect(func(): fired[0] += 1)
	var n := 0
	while not s.special_ready and n < 50:
		s.begin_trick("Indy", 200)
		s.begin_trick("Kickflip", 100)
		s.land()
		n += 1
	check(s.special_ready and fired[0] == 1, "landing tricks fills the special meter and unlocks the special", "combos=%d" % n)
	check(n == 15, "each landed combo adds points/90 to the meter (fifteen 600-point combos fill it)", str(n))
	var big := ScoreKeeper.new()
	var m := 0
	while not big.special_ready and m < 50:
		big.begin_trick("Indy", 2000)
		big.begin_trick("50-50", 2000)
		big.land()
		m += 1
	check(m == 3, "big combos fill it faster (capped at 45% per combo)", str(m))
	s.tick(10.0)
	check(s.special_ready, "a full meter does not drain")
	var t := ScoreKeeper.new()
	t.begin_trick("Indy", 200)
	t.land()
	var partial := t.special
	t.tick(1.0)
	check(t.special < partial, "a partial meter drains slowly between combos")
	s.begin_trick(Tricks.SPECIAL["name"], Tricks.SPECIAL["points"])
	check(s.combo_score() == 3000, "the special trick is worth 3000")
	check(Tricks.category(Tricks.SPECIAL["name"]) == "special", "special is categorised")


func spins_and_names() -> void:
	check(Tricks.spin_points(180.0) == 100 and Tricks.spin_points(360.0) == 250 and Tricks.spin_points(540.0) == 500,
			"spin bonuses 180/360/540")
	check(Tricks.spin_points(160.0) == 100, "a slightly short 180 still counts (25 deg tolerance)")
	check(Tricks.spin_points(120.0) == 0, "an under-rotated spin scores nothing")
	check(Tricks.spin_name(-190.0) == "BS 180" and Tricks.spin_name(370.0) == "FS 360", "spin names", Tricks.spin_name(-190.0))
	check(ScoreKeeper.format_points(1234567) == "1,234,567", "score formatting with thousands separators")
	for k in ["Kickflip", "Indy", "50-50", "Manual", "Nose Manual", "Boardslide", "360 Flip", "Pop Shove-It"]:
		check(Tricks.category(k) != "", "trick category for " + k, Tricks.category(k))


func hud_totals() -> void:
	var hud: CanvasLayer = load("res://scripts/ui/hud.gd").new()
	root.add_child(hud)
	await process_frame
	var s := ScoreKeeper.new()
	hud.bind(s)
	s.begin_trick("Kickflip", 100)
	s.begin_trick("Indy", 200)
	await process_frame
	await process_frame
	check(hud.combo_label.text == "Kickflip + Indy", "HUD shows the combo string", hud.combo_label.text)
	check(hud.combo_points.text.replace(" ", "") == "300X2", "HUD shows base points X multiplier", hud.combo_points.text)
	s.land()
	await process_frame
	await process_frame
	check(hud.score_label.text == "600", "HUD total updates when the combo lands", hud.score_label.text)
	check(hud.landed_label.text == "+600", "HUD shows the landed combo value", hud.landed_label.text)
	s.begin_trick("Heelflip", 100)
	s.bail()
	await process_frame
	check(hud.landed_label.text == "BAIL!" and hud.score_label.text == "600", "HUD shows BAIL and keeps the total")
	hud.set_time(83.2)
	check(hud.timer_label.text == "1:24", "HUD timer shows m:ss", hud.timer_label.text)
	hud.queue_free()
