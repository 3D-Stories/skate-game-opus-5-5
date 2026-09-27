class_name Menus
extends CanvasLayer
## The start screen, a menu: Resume game (the saved game, scripts/game/progress.gd), Start new
## game, Level select, Customize character, Controls, and Quit in the Windows build. Beside it
## the current level, its goals (done ones ticked) and its best score. Also the Controls
## screen, the "start a new game?" question, the pause menu and the end-of-run screen.
## Every menu works with the keyboard (Up / Down or W / S, Enter), a gamepad (D-pad or left
## stick, A) and the mouse (point and click). The start screen's shortcuts stay: Tab / Select
## opens the level select, C / Y the character builder. Runs while the tree is paused.

signal start_pressed         # Start new game (after "start a new game?" when a game is saved)
signal continue_pressed      # Resume game: carry on with the saved game
signal resume_pressed        # pause menu: back to the run
signal restart_pressed
signal main_menu_pressed     # pause menu and end screen: back to the start screen
signal quit_pressed          # the Windows build only
signal level_select_pressed      # also Tab / gamepad Select on the start screen
signal skater_pressed      # the character builder (scripts/ui/skater_builder.gd); also C / Y
signal replay_pressed      # the instant replay (scripts/game/replay.gd)

enum { NONE, START, PAUSE, END, CONTROLS_SCREEN, CONFIRM }

const YELLOW := Color(1, 0.82, 0.12)
const GREY := Color(0.5, 0.5, 0.52)

var mode := NONE
var font: FontVariation
var font_plain: FontVariation
var panel: Control
var title: Label
var body: RichTextLabel
var hint: Label
var grid: GridContainer
var start_row: HBoxContainer     # the start screen: the menu and, beside it, the level
var menu_col: VBoxContainer
var side: RichTextLabel
var items_row: HBoxContainer     # the other screens: their choices in a row
## The choices on screen: {id, text, enabled, node, label, style}; `sel` is the one picked.
var items: Array = []
var sel := 0
var _start_args: Array = []      # show_start's arguments, to come back from Controls
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
	title = _mk_label(font, 92, YELLOW, 16)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title)
	grid = GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 60)
	grid.add_theme_constant_override("v_separation", 4)
	col.add_child(grid)
	body = _mk_rich(26, 32, 1560)
	col.add_child(body)
	start_row = HBoxContainer.new()
	start_row.add_theme_constant_override("separation", 70)
	start_row.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(start_row)
	menu_col = VBoxContainer.new()
	menu_col.add_theme_constant_override("separation", 10)
	start_row.add_child(menu_col)
	side = _mk_rich(25, 30, 700)
	start_row.add_child(side)
	items_row = HBoxContainer.new()
	items_row.add_theme_constant_override("separation", 28)
	items_row.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(items_row)
	hint = _mk_label(font, 34, Color(1, 1, 1), 10)
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


func _mk_rich(size: int, bold_size: int, width: float) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.scroll_active = false
	r.fit_content = true
	r.add_theme_font_override("normal_font", font_plain)
	r.add_theme_font_override("bold_font", font)
	r.add_theme_font_size_override("normal_font_size", size)
	r.add_theme_font_size_override("bold_font_size", bold_size)
	r.add_theme_constant_override("outline_size", 6)
	r.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	r.custom_minimum_size = Vector2(width, 0)
	return r


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
			var l := _mk_label(font if r == 0 else font_plain, 30 if r == 0 else 26,
					YELLOW if r == 0 else (Color(0.85, 0.85, 0.85) if c == 0 else Color(1, 1, 1)), 6)
			l.text = CONTROLS[r][c]
			grid.add_child(l)


# ------------------------------------------------------------------ the choices

func _set_items(box: BoxContainer, defs: Array, pick: String, big: bool) -> void:
	## Builds the choices (big: the start screen's column, with a line under each) and picks
	## `pick`, or the first one that can be chosen.
	for b in [menu_col, items_row]:
		for c in b.get_children():
			b.remove_child(c)
			c.queue_free()
	items = []
	for d in defs:
		var sb := StyleBoxFlat.new()
		sb.set_border_width_all(3)
		sb.set_corner_radius_all(8)
		sb.content_margin_left = 26
		sb.content_margin_right = 26
		sb.content_margin_top = 8 if big else 6
		sb.content_margin_bottom = 8 if big else 6
		var p := PanelContainer.new()
		p.add_theme_stylebox_override("panel", sb)
		p.mouse_filter = Control.MOUSE_FILTER_STOP
		p.name = "Item_" + String(d["id"])
		if big:
			p.custom_minimum_size = Vector2(760, 0)
		var row := HBoxContainer.new()
		p.add_child(row)
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 0)
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(v)
		var l := _mk_label(font, 44 if big else 34, Color.WHITE, 10)
		l.text = String(d["text"])
		v.add_child(l)
		if big and String(d.get("sub", "")) != "":
			var s := _mk_label(font_plain, 22, Color(0.8, 0.8, 0.8), 4)
			s.text = String(d["sub"])
			v.add_child(s)
		if String(d.get("key", "")) != "":
			var k := _mk_label(font_plain, 22, Color(0.75, 0.75, 0.75), 4)
			k.text = String(d["key"])
			k.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(k)
		box.add_child(p)
		var i := items.size()
		p.mouse_entered.connect(func():
			if mode != NONE and items.size() > i and items[i]["enabled"] and sel != i:
				sel = i
				_style_items())
		p.gui_input.connect(func(ev: InputEvent): _item_input(i, ev))
		items.append({"id": String(d["id"]), "text": String(d["text"]), "enabled": bool(d.get("enabled", true)),
				"node": p, "label": l, "style": sb})
	sel = 0
	for i in items.size():
		if items[i]["id"] == pick and items[i]["enabled"]:
			sel = i
			break
	if not items.is_empty() and not items[sel]["enabled"]:
		_move(1)
	_style_items()
	_log_items()


func _log_items() -> void:
	## One log line with each choice and its centre as a fraction of the screen, once the
	## layout has settled (tests/web_menu_check.py clicks them in the browser from it).
	var shown := items.duplicate()
	await get_tree().process_frame
	if items != shown or mode == NONE:
		return
	var vs := get_viewport().get_visible_rect().size
	var parts := PackedStringArray()
	for it in items:
		var c: Vector2 = (it["node"] as Control).get_global_rect().get_center() / vs
		parts.append("%s%s@%.3f,%.3f" % [it["id"], "" if it["enabled"] else "(off)", c.x, c.y])
	print("[menu] %s: %s  picked %s" % [["", "start", "pause", "end", "controls", "confirm"][mode], " ".join(parts), selected_id()])


func _style_items() -> void:
	for i in items.size():
		var it: Dictionary = items[i]
		var on: bool = i == sel
		var sb: StyleBoxFlat = it["style"]
		sb.bg_color = Color(1, 0.82, 0.12, 0.16) if on else Color(1, 1, 1, 0.04)
		sb.border_color = YELLOW if on else Color(1, 1, 1, 0.12)
		var l: Label = it["label"]
		l.add_theme_color_override("font_color", GREY if not it["enabled"] else (YELLOW if on else Color.WHITE))
		l.text = ("> " if on else "") + String(it["text"])


func selected_id() -> String:
	return String(items[sel]["id"]) if sel < items.size() else ""


func _move(d: int) -> void:
	if items.is_empty():
		return
	for n in items.size():
		sel = posmod(sel + d, items.size())
		if items[sel]["enabled"]:
			break
	_style_items()


func _item_input(i: int, ev: InputEvent) -> void:
	var mb := ev as InputEventMouseButton
	if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and mode != NONE and _cooldown <= 0.0:
		choose(i)


func choose(i: int) -> void:
	## Picks choice i (Enter / A on the selected one, or a click).
	if i < 0 or i >= items.size():
		return
	if not items[i]["enabled"]:
		Sfx.play("ui_move")
		return
	sel = i
	_style_items()
	Sfx.play("ui_select")
	_cooldown = 0.2
	var id := String(items[i]["id"])
	print("[menu] %s" % id)
	match id:
		"resume_game":
			continue_pressed.emit()
		"new_game":
			if bool(_info().get("saved", false)):
				show_confirm()
			else:
				start_pressed.emit()
		"level":
			level_select_pressed.emit()
		"skater":
			skater_pressed.emit()
		"controls":
			show_controls()
		"quit":
			quit_pressed.emit()
		"resume_run":
			resume_pressed.emit()
		"restart", "again":
			restart_pressed.emit()
		"replay":
			replay_pressed.emit()
		"main_menu":
			main_menu_pressed.emit()
		"yes_new":
			start_pressed.emit()
		"no_keep":
			_back_to_start("new_game")
		"back":
			_back_to_start("controls")


func _info() -> Dictionary:
	return _start_args[2] if _start_args.size() > 2 else {}


func _back_to_start(pick: String) -> void:
	if _start_args.is_empty():
		return
	var info: Dictionary = _info().duplicate()
	info["select"] = pick
	show_start(_start_args[0], _start_args[1], info)


# ------------------------------------------------------------------ the screens

func _layout(m: int, title_text: String) -> void:
	mode = m
	panel.visible = true
	title.text = title_text
	start_row.visible = m == START
	items_row.visible = m != START
	body.visible = m != START
	_show_end_skater({})


func show_start(goals: Array, level_name := "The Warehouse", info := {}) -> void:
	## info: saved (a saved game exists), goals_done / goals_total (this level, saved ones
	## ticked), best (score), blurb, skater (who skates), quit (the Windows build), select
	## (the choice to start on; otherwise Resume game when there is a save).
	_start_args = [goals, level_name, info]
	_layout(START, "PRO SKATER")
	_fill_controls(false)
	var saved := bool(info.get("saved", false))
	var done := int(info.get("goals_done", 0))
	var total := int(info.get("goals_total", goals.size()))
	var defs := [
		{"id": "resume_game", "text": "RESUME GAME", "enabled": saved,
			"sub": ("Carry on: %d / %d goals done in %s" % [done, total, level_name]) if saved else "No saved game yet"},
		{"id": "new_game", "text": "START NEW GAME",
			"sub": "Starts over: clears your saved game" if saved else "A two-minute run; goals you finish are saved"},
		{"id": "level", "text": "LEVEL SELECT", "sub": level_name, "key": "TAB / SELECT"},
		{"id": "skater", "text": "CUSTOMIZE CHARACTER", "sub": String(info.get("skater", "")), "key": "C / Y"},
		{"id": "controls", "text": "CONTROLS", "sub": "Keyboard and gamepad"},
	]
	if bool(info.get("quit", false)):
		defs.append({"id": "quit", "text": "QUIT", "sub": "Close the game"})
	_set_items(menu_col, defs, String(info.get("select", "resume_game" if saved else "new_game")), true)
	var s := "[b]LEVEL[/b]   [color=#ffd23a]%s[/color]\n" % level_name.to_upper()
	if String(info.get("blurb", "")) != "":
		s += "[color=#cfcfcf]%s[/color]\n" % String(info["blurb"])
	s += "\n[b]GOALS[/b]   %s\n" % (("%d / %d done" % [done, total]) if saved else "2:00 RUN")
	for g in goals:
		var d: bool = g.get("done", false)
		s += ("  [color=#6dff6d][X][/color]  " if d else "  [  ]  ") + String(g["title"]) + "\n"
	if int(info.get("best", 0)) > 0:
		s += "\n[b]BEST SCORE[/b]   [color=#ffd23a]%s[/color]" % ScoreKeeper.format_points(int(info["best"]))
	side.text = s
	body.text = ""
	hint.text = "UP / DOWN  CHOOSE        ENTER / A  SELECT"
	SkaterOutfit.ensure_actions()
	_cooldown = 0.3


func show_controls() -> void:
	_layout(CONTROLS_SCREEN, "CONTROLS")
	_fill_controls(true)
	var t := "\n[b]MENUS[/b]   Up / Down (W / S, D-pad, left stick) choose,  Enter / A select,  Esc / B back,  or point and click\n"
	t += "[b]START SCREEN[/b]   Tab / Select  level select,   C / Y  customize character\n"
	if bool(_info().get("quit", false)):
		t += "[b]WINDOWS[/b]   F11 or Alt+Enter  fullscreen / window,   Q or B twice in a menu  quit\n"
	body.text = t
	_set_items(items_row, [{"id": "back", "text": "BACK"}], "back", false)
	hint.text = "ENTER / A  OR  ESC / B  BACK"
	_cooldown = 0.25


func show_confirm() -> void:
	## "Start a new game?" when a saved game exists; No is picked first.
	var sm := Progress.summary()
	_layout(CONFIRM, "START A NEW GAME?")
	_fill_controls(false)
	body.text = "\n[center]Your saved game will be cleared: %d goal%s done on %d level%s.[/center]\n" % [
			sm["goals"], "" if sm["goals"] == 1 else "s", sm["levels"], "" if sm["levels"] == 1 else "s"]
	_set_items(items_row, [{"id": "no_keep", "text": "NO, KEEP MY GAME"}, {"id": "yes_new", "text": "YES, START OVER"}], "no_keep", false)
	hint.text = "LEFT / RIGHT  CHOOSE        ENTER / A  SELECT        ESC / B  BACK"
	_cooldown = 0.25


func show_pause(goals: Array, sk: ScoreKeeper) -> void:
	_layout(PAUSE, "PAUSED")
	var g := "[b]GOALS[/b]\n"
	for x in goals:
		g += ("  [color=#6dff6d][X][/color] " if x["done"] else "  [  ] ") + String(x["title"]) + "  " + String(x.get("progress", "")) + "\n"
	_fill_controls(true)
	body.text = g + "\nScore: [color=#ffd23a]%s[/color]" % ScoreKeeper.format_points(sk.total)
	_set_items(items_row, [{"id": "resume_run", "text": "RESUME"}, {"id": "restart", "text": "RESTART RUN"},
			{"id": "main_menu", "text": "MAIN MENU"}], "resume_run", false)
	hint.text = "ENTER / A  SELECT        ESC  RESUME        R / SELECT  RESTART"
	_cooldown = 0.25


func show_end(goals: Array, sk: ScoreKeeper, stats: Dictionary, cleared := "Warehouse cleared", skater := {}, replay := false) -> void:
	_layout(END, "RUN OVER")
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
	var defs := [{"id": "again", "text": "SKATE AGAIN"}]
	if replay:
		defs.append({"id": "replay", "text": "REPLAY"})
	defs.append({"id": "main_menu", "text": "MAIN MENU"})
	_set_items(items_row, defs, "again", false)
	hint.text = "ENTER / A  SELECT" + ("        V / X  REPLAY" if replay else "")
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
	if Input.is_action_just_pressed("up") or Input.is_action_just_pressed("left"):
		Sfx.play("ui_move")
		_move(-1)
	elif Input.is_action_just_pressed("down") or Input.is_action_just_pressed("right"):
		Sfx.play("ui_move")
		_move(1)
	elif Input.is_action_just_pressed("confirm"):
		choose(sel)
	elif mode == START and (Input.is_key_pressed(KEY_TAB) or Input.is_joy_button_pressed(0, JOY_BUTTON_BACK)):
		Sfx.play("ui_move")
		print("[menu] level (shortcut)")
		level_select_pressed.emit()
	elif mode == START and InputMap.has_action("skater_menu") and Input.is_action_just_pressed("skater_menu"):
		Sfx.play("ui_select")
		print("[menu] skater (shortcut)")
		skater_pressed.emit()
	elif mode == END and InputMap.has_action("replay") and Input.is_action_just_pressed("replay"):
		Sfx.play("ui_select")
		replay_pressed.emit()
	elif mode == PAUSE and Input.is_action_just_pressed("pause"):
		resume_pressed.emit()
	elif mode == PAUSE and Input.is_action_just_pressed("restart"):
		Sfx.play("ui_select")
		restart_pressed.emit()
	elif mode in [CONTROLS_SCREEN, CONFIRM] and (Input.is_action_just_pressed("pause") or Input.is_joy_button_pressed(0, JOY_BUTTON_B)):
		Sfx.play("ui_move")
		_back_to_start("controls" if mode == CONTROLS_SCREEN else "new_game")
