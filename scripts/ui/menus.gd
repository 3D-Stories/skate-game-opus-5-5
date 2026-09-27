class_name Menus
extends CanvasLayer
## Start screen (controls for keyboard + gamepad, trick list, goals), pause menu and the
## end-of-run screen. Runs while the tree is paused.

signal start_pressed
signal resume_pressed
signal restart_pressed
signal level_select_pressed      # start screen: Tab / gamepad Select opens the level select
signal skater_pressed      # the Skater screen (character builder, scripts/ui/skater_builder.gd)
signal replay_pressed      # the instant replay (scripts/game/replay.gd)

enum { NONE, START, PAUSE, END }

var mode := NONE
var font: FontVariation
var font_plain: FontVariation
var panel: Control
var title: Label
var body: RichTextLabel
var hint: Label
var grid: GridContainer
var _blink := 0.0
var _cooldown := 0.0
var end_skater: SkaterPreview   # the end screen shows who skated the run
var end_skater_label: Label


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	font = FontVariation.new()
	font.base_font = ThemeDB.fallback_font
	font.variation_embolden = 1.2
	font.variation_transform = Transform2D(Vector2(1, 0), Vector2(-0.22, 1), Vector2.ZERO)
	font_plain = FontVariation.new()
	font_plain.base_font = ThemeDB.fallback_font
	font_plain.variation_embolden = 0.4
	panel = ColorRect.new()
	panel.color = Color(0.02, 0.02, 0.03, 0.8)
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(panel)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.add_child(center)
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(1560, 0)
	col.add_theme_constant_override("separation", 14)
	center.add_child(col)
	title = _mk_label(font, 92, Color(1, 0.82, 0.12), 16)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title)
	grid = GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 60)
	grid.add_theme_constant_override("v_separation", 4)
	col.add_child(grid)
	body = RichTextLabel.new()
	body.bbcode_enabled = true
	body.scroll_active = false
	body.fit_content = true
	body.add_theme_font_override("normal_font", font_plain)
	body.add_theme_font_override("bold_font", font)
	body.add_theme_font_size_override("normal_font_size", 26)
	body.add_theme_font_size_override("bold_font_size", 32)
	body.add_theme_constant_override("outline_size", 6)
	body.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	body.custom_minimum_size = Vector2(1560, 0)
	col.add_child(body)
	hint = _mk_label(font, 42, Color(1, 1, 1), 10)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(hint)
	hide_all()


func _mk_label(f: Font, size: int, color: Color, outline: int) -> Label:
	var l := Label.new()
	l.add_theme_font_override("font", f)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	l.add_theme_constant_override("outline_size", outline)
	return l


const CONTROLS := [
	["", "KEYBOARD", "GAMEPAD"],
	["Steer  /  push (Up)  /  brake (Down)", "W A S D  or  arrow keys", "Left stick  or  D-pad"],
	["Ollie (hold to crouch, release to pop)", "Space", "A  /  Cross"],
	["Flip trick  + direction", "J", "X  /  Square"],
	["Grab trick  + direction (hold)", "K", "B  /  Circle"],
	["Grind  (rail, ledge, coping, pipe, rafter)", "L", "Y  /  Triangle"],
	["Spin in the air", "Left / Right,  Q / E", "Left stick,  LB / RB"],
	["Manual  /  Nose manual", "Up, Down  /  Down, Up", "Up, Down  /  Down, Up"],
	["Special trick (special meter full)", "Left, Right + J", "Left, Right + X"],
	["Pause  /  Restart run", "Esc or P  /  R", "Start  /  Back"],
]


func _fill_controls(show: bool) -> void:
	for c in grid.get_children():
		c.queue_free()
	grid.visible = show
	if not show:
		return
	for r in CONTROLS.size():
		for c in 3:
			var hdr: bool = r == 0 or c == 0
			var l := _mk_label(font if r == 0 else font_plain, 30 if r == 0 else 26,
					Color(1, 0.82, 0.12) if r == 0 else (Color(0.85, 0.85, 0.85) if c == 0 else Color(1, 1, 1)), 6)
			l.text = CONTROLS[r][c]
			grid.add_child(l)


func show_start(goals: Array, level_name := "The Warehouse") -> void:
	mode = START
	panel.visible = true
	_show_end_skater({})
	title.text = "PRO SKATER: " + level_name.to_upper()
	var g := "\n[b]GOALS - 2:00 RUN[/b]\n"
	for x in goals:
		g += "  -  " + String(x["title"]) + "\n"
	var t := "\n[b]TRICKS[/b]\n"
	var rows := Tricks.all_tricks()
	for r in rows:
		t += "  %s  [color=#ffd23a]%s[/color]  -  %s\n" % [r[0], str(r[1]), r[2]]
	_fill_controls(true)
	body.text = g + "\n[b]LEVEL[/b]   %s   [color=#ffd23a](TAB / SELECT: choose a level)[/color]" % level_name.to_upper()
	hint.text = "PRESS ENTER / A TO SKATE        C / Y  SKATER"
	SkaterOutfit.ensure_actions()
	_cooldown = 0.3


func show_pause(goals: Array, sk: ScoreKeeper) -> void:
	mode = PAUSE
	panel.visible = true
	_show_end_skater({})
	title.text = "PAUSED"
	var g := "[b]GOALS[/b]\n"
	for x in goals:
		g += ("  [color=#6dff6d][X][/color] " if x["done"] else "  [  ] ") + String(x["title"]) + "  " + String(x.get("progress", "")) + "\n"
	_fill_controls(true)
	body.text = g + "\nScore: [color=#ffd23a]%s[/color]" % ScoreKeeper.format_points(sk.total)
	hint.text = "ENTER / A  RESUME        R / SELECT  RESTART"
	_cooldown = 0.25


func show_end(goals: Array, sk: ScoreKeeper, stats: Dictionary, cleared := "Warehouse cleared", skater := {}, replay := false) -> void:
	mode = END
	panel.visible = true
	title.text = "RUN OVER"
	var done := 0
	var g := ""
	for x in goals:
		if x["done"]:
			done += 1
		g += ("  [color=#6dff6d][X][/color] " if x["done"] else "  [color=#ff6d6d][  ][/color] ") + String(x["title"]) + "\n"
	var s := "[b]SCORE[/b]   [color=#ffd23a]%s[/color]\n" % ScoreKeeper.format_points(sk.total)
	s += "[b]BEST COMBO[/b]   [color=#ffd23a]%s[/color]\n" % ScoreKeeper.format_points(sk.best_combo)
	s += "Tricks landed: %d     Bails: %d     Longest grind: %.1fs\n\n" % [stats.get("tricks", 0), stats.get("bails", 0), stats.get("longest_grind", 0.0)]
	s += "[b]GOALS  %d / %d[/b]\n" % [done, goals.size()] + g
	if done == goals.size():
		s += "\n[color=#ffd23a][b]ALL GOALS COMPLETE - %s![/b][/color]" % cleared.to_upper()
	_fill_controls(false)
	body.text = s
	hint.text = "PRESS ENTER / A TO SKATE AGAIN" + ("        V / X  REPLAY" if replay else "")
	_show_end_skater(skater)
	_cooldown = 1.0


func _show_end_skater(c: Dictionary) -> void:
	## The skater of the run (the character-builder choice) on a turntable at the right.
	if end_skater == null:
		if c.is_empty():
			return
		end_skater = SkaterPreview.new(Vector2i(400, 560))
		end_skater.name = "EndSkater"
		end_skater.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
		end_skater.position = Vector2(1920 - 470, 1080 / 2 - 330)
		panel.add_child(end_skater)
		end_skater_label = _mk_label(font_plain, 22, Color(0.85, 0.85, 0.85), 6)
		end_skater_label.position = Vector2(1920 - 470, 1080 / 2 + 240)
		panel.add_child(end_skater_label)
	end_skater.visible = not c.is_empty()
	end_skater_label.visible = not c.is_empty()
	if c.is_empty():
		return
	end_skater.set_choice(c)
	var names := PackedStringArray()
	for slot in ["top", "bottom", "shoes", "hat"]:
		if c[slot] != "none":
			names.append(SkaterOutfit.label(slot, c[slot]))
	end_skater_label.text = SkaterOutfit.label("body", c["body"]).to_upper() + "\n" + "\n".join(names)


func hide_all() -> void:
	mode = NONE
	panel.visible = false
	_show_end_skater({})


func _process(delta: float) -> void:
	if mode == NONE:
		return
	_blink += delta
	hint.modulate.a = 0.55 + 0.45 * sin(_blink * 5.0)
	if _cooldown > 0.0:
		_cooldown -= delta
		return
	if Input.is_action_just_pressed("confirm"):
		Sfx.play("ui_select")
		match mode:
			START:
				start_pressed.emit()
			PAUSE:
				resume_pressed.emit()
			END:
				restart_pressed.emit()
	elif mode == START and (Input.is_key_pressed(KEY_TAB) or Input.is_joy_button_pressed(0, JOY_BUTTON_BACK)):
		Sfx.play("ui_move")
		level_select_pressed.emit()
	elif mode == END and InputMap.has_action("replay") and Input.is_action_just_pressed("replay"):
		Sfx.play("ui_select")
		replay_pressed.emit()
	elif mode == START and InputMap.has_action("skater_menu") and Input.is_action_just_pressed("skater_menu"):
		Sfx.play("ui_select")
		skater_pressed.emit()
	elif mode == PAUSE and Input.is_action_just_pressed("pause"):
		resume_pressed.emit()
	elif mode == PAUSE and Input.is_action_just_pressed("restart"):
		Sfx.play("ui_select")
		restart_pressed.emit()
