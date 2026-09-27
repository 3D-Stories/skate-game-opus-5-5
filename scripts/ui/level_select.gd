extends CanvasLayer
## Level select (opened from the start screen with Tab / gamepad Select): one card per level
## in LevelRegistry, with its blurb and goals (with a saved game: the ones done ticked, and the
## best score). Left / Right (keys, D-pad or stick) move,
## Enter / A picks, Esc / B / Tab / Select go back. Emits closed(id) ("" = no change).

signal closed(pick: String)

var ids: Array = []
var idx := 0
var current := ""
var cards: Array = []
var font: FontVariation
var font_plain: FontVariation
var status: Label
var hint: Label
var _cool := 0.3
var _busy := false
var _blink := 0.0
var show_saved := false          # the saved game's goals and best score on each card (Progress)


func _ready() -> void:
	layer = 12
	process_mode = Node.PROCESS_MODE_ALWAYS
	font = FontVariation.new()
	font.base_font = ThemeDB.fallback_font
	font.variation_embolden = 1.2
	font.variation_transform = Transform2D(Vector2(1, 0), Vector2(-0.22, 1), Vector2.ZERO)
	font_plain = FontVariation.new()
	font_plain.base_font = ThemeDB.fallback_font
	font_plain.variation_embolden = 0.4


func open(current_id: String, saved := false) -> void:
	current = current_id
	show_saved = saved
	ids = LevelRegistry.ids()
	idx = maxi(0, ids.find(current_id))
	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.02, 0.03, 0.86)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.add_child(center)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 26)
	center.add_child(col)
	var title := _label(font, 84, Color(1, 0.82, 0.12), 16)
	title.text = "CHOOSE A LEVEL"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 40)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(row)
	for id in ids:
		var card := _card(String(id))
		row.add_child(card)
		cards.append(card)
	status = _label(font_plain, 30, Color(0.85, 0.85, 0.85), 6)
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(status)
	hint = _label(font, 38, Color(1, 1, 1), 10)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.text = "< >  CHOOSE        ENTER / A  PICK        ESC / B  BACK"
	col.add_child(hint)
	_refresh()


func _label(f: Font, size: int, color: Color, outline: int) -> Label:
	var l := Label.new()
	l.add_theme_font_override("font", f)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	l.add_theme_constant_override("outline_size", outline)
	return l


func _card(id: String) -> PanelContainer:
	var g := LevelRegistry.game(id)
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(700, 560)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.08, 0.1, 0.95)
	sb.set_border_width_all(4)
	sb.border_color = Color(0.3, 0.3, 0.32)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 30
	sb.content_margin_right = 30
	sb.content_margin_top = 22
	sb.content_margin_bottom = 22
	p.add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	p.add_child(v)
	var name := _label(font, 54, Color(1, 1, 1), 10)
	name.text = String(g.get("name", id)).to_upper()
	v.add_child(name)
	var blurb := _label(font_plain, 24, Color(0.82, 0.82, 0.82), 4)
	blurb.text = String(g.get("blurb", ""))
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.custom_minimum_size = Vector2(640, 0)
	v.add_child(blurb)
	var goals := RichTextLabel.new()
	goals.bbcode_enabled = true
	goals.fit_content = true
	goals.scroll_active = false
	goals.custom_minimum_size = Vector2(640, 0)
	goals.add_theme_font_override("normal_font", font_plain)
	goals.add_theme_font_override("bold_font", font)
	goals.add_theme_font_size_override("normal_font_size", 25)
	goals.add_theme_font_size_override("bold_font_size", 28)
	var t := "[b]GOALS - %d:%02d RUN[/b]\n" % [int(g.get("run_time", 120)) / 60, int(g.get("run_time", 120)) % 60]
	var done: Array = Progress.done_goals(id) if show_saved else []
	for gd in g.get("goals", []):
		if show_saved:
			t += ("  [color=#6dff6d][X][/color]  " if String(gd.get("id", "")) in done else "  [  ]  ") + goal_title(gd) + "\n"
		else:
			t += "  -  " + goal_title(gd) + "\n"
	if show_saved and Progress.best_score(id) > 0:
		t += "\n[b]BEST SCORE[/b]   [color=#ffd23a]%s[/color]" % ScoreKeeper.format_points(Progress.best_score(id))
	goals.text = t
	v.add_child(goals)
	var tag := _label(font_plain, 22, Color(1, 0.82, 0.12), 4)
	tag.name = "Tag"
	v.add_child(tag)
	p.set_meta("style", sb)
	p.set_meta("tag", tag)
	p.set_meta("id", id)
	return p


static func goal_title(gd: Dictionary) -> String:
	if gd.has("title"):
		return String(gd["title"])
	if String(gd.get("type", "")) == "score":
		return "High Score: %s" % ScoreKeeper.format_points(int(gd.get("target", 0)))
	return String(gd.get("id", ""))


func _refresh() -> void:
	for i in cards.size():
		var c: PanelContainer = cards[i]
		var sb: StyleBoxFlat = c.get_meta("style")
		var on := i == idx
		sb.border_color = Color(1, 0.82, 0.12) if on else Color(0.3, 0.3, 0.32)
		sb.bg_color = Color(0.1, 0.1, 0.12, 0.97) if on else Color(0.06, 0.06, 0.08, 0.9)
		c.modulate = Color(1, 1, 1) if on else Color(0.62, 0.62, 0.62)
		var id := String(c.get_meta("id"))
		var tag: Label = c.get_meta("tag")
		var bits: Array = []
		if id == current:
			bits.append("PLAYING NOW")
		if id == LevelRegistry.default_id():
			bits.append("DEFAULT")
		if not LevelRegistry.available(id):
			bits.append("DOWNLOADS WHEN CHOSEN")
		tag.text = "  ".join(bits)
	status.text = ""


func progress(got: int, total: int) -> void:
	## Called while a level's web pack downloads.
	if total > 0:
		status.text = "DOWNLOADING %s   %d%%   (%.1f / %.1f MB)" % [String(LevelRegistry.game(ids[idx]).get("name", "")).to_upper(),
				int(100.0 * got / total), got / 1048576.0, total / 1048576.0]
	else:
		status.text = "DOWNLOADING ... %.1f MB" % (got / 1048576.0)


func _process(delta: float) -> void:
	if cards.is_empty() or _busy:
		return
	_blink += delta
	hint.modulate.a = 0.6 + 0.4 * sin(_blink * 5.0)
	if _cool > 0.0:
		_cool -= delta
		return
	var mv := 0
	if Input.is_action_just_pressed("right") or Input.is_action_just_pressed("down"):
		mv = 1
	elif Input.is_action_just_pressed("left") or Input.is_action_just_pressed("up"):
		mv = -1
	if mv != 0:
		idx = (idx + mv + ids.size()) % ids.size()
		Sfx.play("ui_move")
		_refresh()
		_cool = 0.12
	elif Input.is_action_just_pressed("confirm"):
		Sfx.play("ui_select")
		_busy = true
		status.text = "LOADING %s ..." % String(LevelRegistry.game(ids[idx]).get("name", "")).to_upper()
		# let the LOADING line draw before the level loads (it can take a moment)
		await get_tree().process_frame
		await get_tree().process_frame
		closed.emit(String(ids[idx]))
	elif Input.is_action_just_pressed("pause") or Input.is_joy_button_pressed(0, JOY_BUTTON_B) \
			or (_blink > 0.6 and (Input.is_key_pressed(KEY_TAB) or Input.is_joy_button_pressed(0, JOY_BUTTON_BACK))):
		Sfx.play("ui_move")
		_busy = true
		closed.emit("")
