class_name Hud
extends CanvasLayer
## THPS-style heads-up display: score + special meter (top left), run timer (top centre),
## goals and S-K-A-T-E letters (top right), the combo string with "points X multiplier"
## (bottom centre), grind/manual balance meters, and pop-up messages.

var score: ScoreKeeper
var font: FontVariation
var font_plain: FontVariation
var score_label: Label
var timer_label: Label
var special_bar: Control
var special_label: Label
var combo_label: Label
var combo_points: Label
var goals_box: VBoxContainer
var goal_labels: Dictionary = {}
var letters_label: RichTextLabel
var message: Label
var sub_message: Label
var landed_label: Label
var balance_h: Control
var balance_v: Control
var balance_kind := ""
var balance_value := 0.0
var _msg_t := 0.0
var _landed_t := 0.0
var _special_flash := 0.0
var _combo_scale := 1.0
var root: Control
var fps_label: Label


func _ready() -> void:
	layer = 5
	font = FontVariation.new()
	font.base_font = ThemeDB.fallback_font
	font.variation_embolden = 1.1
	font.variation_transform = Transform2D(Vector2(1, 0), Vector2(-0.22, 1), Vector2.ZERO)
	font_plain = FontVariation.new()
	font_plain.base_font = ThemeDB.fallback_font
	font_plain.variation_embolden = 0.6
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	score_label = _label(root, "0", 64, Color(1, 1, 1), Vector2(48, 30))
	special_bar = Control.new()
	special_bar.position = Vector2(52, 118)
	special_bar.size = Vector2(360, 26)
	special_bar.draw.connect(_draw_special)
	root.add_child(special_bar)
	special_label = _label(root, "", 26, Color(1, 0.85, 0.2), Vector2(422, 112))
	timer_label = _label(root, "2:00", 58, Color(1, 1, 1), Vector2(0, 26))
	timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_place(timer_label, Vector2(0.5, 0), Rect2(-150, 26, 300, 70))
	goals_box = VBoxContainer.new()
	_place(goals_box, Vector2(1, 0), Rect2(-470, 34, 440, 300))
	goals_box.add_theme_constant_override("separation", 2)
	root.add_child(goals_box)
	letters_label = RichTextLabel.new()
	letters_label.bbcode_enabled = true
	letters_label.fit_content = true
	letters_label.scroll_active = false
	letters_label.add_theme_font_override("normal_font", font)
	letters_label.add_theme_font_size_override("normal_font_size", 40)
	letters_label.add_theme_constant_override("outline_size", 10)
	letters_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	letters_label.custom_minimum_size = Vector2(440, 50)
	goals_box.add_child(letters_label)
	combo_label = _label(root, "", 38, Color(1, 1, 1), Vector2(0, 0))
	combo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	combo_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_place(combo_label, Vector2(0.5, 1), Rect2(-760, -250, 1520, 110))
	combo_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	combo_points = _label(root, "", 60, Color(1, 0.88, 0.2), Vector2(0, 0))
	combo_points.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_place(combo_points, Vector2(0.5, 1), Rect2(-500, -140, 1000, 80))
	landed_label = _label(root, "", 54, Color(0.4, 1, 0.45), Vector2(0, 0))
	landed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_place(landed_label, Vector2(0.5, 1), Rect2(-500, -150, 1000, 80))
	message = _label(root, "", 72, Color(1, 0.85, 0.15), Vector2(0, 0))
	message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_place(message, Vector2(0.5, 0.5), Rect2(-900, -260, 1800, 100))
	sub_message = _label(root, "", 40, Color(1, 1, 1), Vector2(0, 0))
	sub_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_place(sub_message, Vector2(0.5, 0.5), Rect2(-900, -170, 1800, 60))
	balance_h = Control.new()
	_place(balance_h, Vector2(0.5, 0.5), Rect2(-180, 60, 360, 40))
	balance_h.draw.connect(_draw_balance_h)
	root.add_child(balance_h)
	balance_v = Control.new()
	_place(balance_v, Vector2(0.5, 0.5), Rect2(130, -150, 40, 300))
	balance_v.draw.connect(_draw_balance_v)
	root.add_child(balance_v)
	fps_label = _label(root, "", 18, Color(0.8, 0.8, 0.8), Vector2(12, 0))
	_place(fps_label, Vector2(0, 1), Rect2(12, -34, 400, 30))
	fps_label.visible = false


func _place(c: Control, anchor: Vector2, r: Rect2) -> void:
	## Anchor a control to a point of the screen with an explicit offset rectangle.
	c.anchor_left = anchor.x
	c.anchor_right = anchor.x
	c.anchor_top = anchor.y
	c.anchor_bottom = anchor.y
	c.offset_left = r.position.x
	c.offset_top = r.position.y
	c.offset_right = r.position.x + r.size.x
	c.offset_bottom = r.position.y + r.size.y


func _label(parent: Control, text: String, size: int, color: Color, pos: Vector2) -> Label:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	l.add_theme_constant_override("outline_size", maxi(6, size / 6))
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.55))
	l.add_theme_constant_override("shadow_offset_x", 3)
	l.add_theme_constant_override("shadow_offset_y", 4)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


func bind(sk: ScoreKeeper) -> void:
	score = sk
	score.combo_landed.connect(_on_landed)
	score.combo_lost.connect(_on_lost)
	score.special_full.connect(func(): flash("SPECIAL!", "Left, Right + Flip for the Tiger Claw Tre"))


func set_goals(goals: Array) -> void:
	for c in goals_box.get_children():
		if c != letters_label:
			c.queue_free()
	goal_labels.clear()
	for g in goals:
		var l := Label.new()
		l.add_theme_font_override("font", font_plain)
		l.add_theme_font_size_override("font_size", 24)
		l.add_theme_color_override("font_outline_color", Color(0, 0, 0))
		l.add_theme_constant_override("outline_size", 7)
		goals_box.add_child(l)
		goal_labels[g["id"]] = l
	update_goals(goals)


func update_goals(goals: Array) -> void:
	for g in goals:
		var l: Label = goal_labels.get(g["id"])
		if l == null:
			continue
		var done: bool = g["done"]
		var extra: String = g.get("progress", "")
		l.text = ("[X] " if done else "[  ] ") + String(g["title"]) + ("" if extra == "" else "  " + extra)
		l.add_theme_color_override("font_color", Color(0.45, 1.0, 0.45) if done else Color(1, 1, 1))


func set_letters(have: Dictionary) -> void:
	var s := ""
	for ch in "SKATE":
		if have.get(ch, false):
			s += "[color=#ffd23a]" + ch + "[/color] "
		else:
			s += "[color=#555555]" + ch + "[/color] "
	letters_label.text = s


func set_time(t: float) -> void:
	var tt := maxi(0, int(ceil(t)))
	timer_label.text = "%d:%02d" % [tt / 60, tt % 60]
	timer_label.add_theme_color_override("font_color", Color(1, 0.3, 0.25) if t < 10.0 else Color(1, 1, 1))


func flash(text: String, sub := "", dur := 2.2) -> void:
	message.text = text
	sub_message.text = sub
	_msg_t = dur


func set_balance(kind: String, value: float, active: bool) -> void:
	balance_kind = kind if active else ""
	balance_value = value


func _on_landed(pts: int) -> void:
	landed_label.text = "+" + ScoreKeeper.format_points(pts)
	landed_label.add_theme_color_override("font_color", Color(0.4, 1, 0.45))
	_landed_t = 1.4


func _on_lost() -> void:
	landed_label.text = "BAIL!"
	landed_label.add_theme_color_override("font_color", Color(1, 0.3, 0.25))
	_landed_t = 1.2


func _process(delta: float) -> void:
	if score == null:
		return
	score_label.text = ScoreKeeper.format_points(score.total)
	if score.in_combo:
		combo_label.text = score.combo_text()
		combo_points.text = "%s  X  %d" % [ScoreKeeper.format_points(score.base_sum()), score.multiplier()]
		combo_points.visible = true
		landed_label.visible = false
	else:
		combo_label.text = ""
		combo_points.visible = false
		landed_label.visible = _landed_t > 0.0
	if _landed_t > 0.0:
		_landed_t -= delta
		landed_label.modulate.a = clampf(_landed_t / 0.4, 0.0, 1.0)
	if _msg_t > 0.0:
		_msg_t -= delta
		var a := clampf(_msg_t / 0.4, 0.0, 1.0)
		message.modulate.a = a
		sub_message.modulate.a = a
	else:
		message.text = ""
		sub_message.text = ""
	_special_flash += delta
	special_label.text = "SPECIAL" if score.special_ready else ""
	special_bar.queue_redraw()
	balance_h.visible = balance_kind == "grind"
	balance_v.visible = balance_kind == "manual"
	if balance_h.visible:
		balance_h.queue_redraw()
	if balance_v.visible:
		balance_v.queue_redraw()
	if fps_label.visible:
		fps_label.text = "%d FPS" % Engine.get_frames_per_second()


func _draw_special() -> void:
	var w := special_bar.size.x
	var h := special_bar.size.y
	special_bar.draw_rect(Rect2(Vector2(-3, -3), Vector2(w + 6, h + 6)), Color(0, 0, 0, 0.8))
	var f := (score.special / 100.0) if score else 0.0
	var c := Color(0.2, 0.55, 1.0).lerp(Color(1.0, 0.85, 0.15), f)
	if score and score.special_ready:
		c = Color(1.0, 0.85, 0.15).lerp(Color(1, 1, 1), 0.5 + 0.5 * sin(_special_flash * 12.0))
	special_bar.draw_rect(Rect2(Vector2.ZERO, Vector2(w * f, h)), c)
	for i in range(1, 10):
		special_bar.draw_line(Vector2(w * i / 10.0, 0), Vector2(w * i / 10.0, h), Color(0, 0, 0, 0.35), 2.0)


func _draw_balance_h() -> void:
	var w := balance_h.size.x
	var h := balance_h.size.y
	balance_h.draw_rect(Rect2(Vector2(-3, 10), Vector2(w + 6, h - 14)), Color(0, 0, 0, 0.7))
	balance_h.draw_rect(Rect2(Vector2(w * 0.35, 13), Vector2(w * 0.3, h - 20)), Color(0.3, 0.9, 0.35, 0.8))
	balance_h.draw_rect(Rect2(Vector2(0, 13), Vector2(w * 0.12, h - 20)), Color(0.95, 0.25, 0.2, 0.85))
	balance_h.draw_rect(Rect2(Vector2(w * 0.88, 13), Vector2(w * 0.12, h - 20)), Color(0.95, 0.25, 0.2, 0.85))
	var x := (clampf(balance_value, -1.0, 1.0) * 0.5 + 0.5) * w
	balance_h.draw_rect(Rect2(Vector2(x - 5, 0), Vector2(10, h)), Color(1, 1, 1))
	balance_h.draw_rect(Rect2(Vector2(x - 5, 0), Vector2(10, h)), Color(0, 0, 0), false, 2.0)


func _draw_balance_v() -> void:
	var w := balance_v.size.x
	var h := balance_v.size.y
	balance_v.draw_rect(Rect2(Vector2(10, -3), Vector2(w - 14, h + 6)), Color(0, 0, 0, 0.7))
	balance_v.draw_rect(Rect2(Vector2(13, h * 0.35), Vector2(w - 20, h * 0.3)), Color(0.3, 0.9, 0.35, 0.8))
	balance_v.draw_rect(Rect2(Vector2(13, 0), Vector2(w - 20, h * 0.12)), Color(0.95, 0.25, 0.2, 0.85))
	balance_v.draw_rect(Rect2(Vector2(13, h * 0.88), Vector2(w - 20, h * 0.12)), Color(0.95, 0.25, 0.2, 0.85))
	var y := (0.5 - clampf(balance_value, -1.0, 1.0) * 0.5) * h
	balance_v.draw_rect(Rect2(Vector2(0, y - 5), Vector2(w, 10)), Color(1, 1, 1))
	balance_v.draw_rect(Rect2(Vector2(0, y - 5), Vector2(w, 10)), Color(0, 0, 0), false, 2.0)
