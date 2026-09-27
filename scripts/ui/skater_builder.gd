class_name SkaterBuilder
extends CanvasLayer
## The "Skater" screen (character builder), opened from the start screen: pick the body and
## each clothing slot and watch the change live on a lit turntable (SkaterPreview). Keyboard
## and gamepad; the controls are listed on screen. "Done" saves the choice (user://, see
## SkaterOutfit) and the run, the replay and the end screen use it; "Back" leaves without
## saving. Built in code like menus.gd; scenes/ui/skater_builder.tscn is its scene.

signal closed(saved: bool, choice: Dictionary)

const CONTROLS := [
	["", "KEYBOARD", "GAMEPAD"],
	["Choose a slot", "W / S  or  Up / Down", "D-pad  or  left stick up / down"],
	["Change it", "A / D  or  Left / Right", "D-pad  or  left stick left / right"],
	["Turn the skater", "Q / E", "LB / RB  or  right stick"],
	["Back to the default skater", "R", "Back"],
	["Done: save and skate as this skater", "Enter", "A  /  Cross"],
	["Leave without saving", "Esc", "B  /  Circle"],
]

var choice: Dictionary = {}
var original: Dictionary = {}
var slot := 0
var preview: SkaterPreview
var rows: Array = []            # per slot: [HBoxContainer, slot Label, value Label, count Label]
var hint: Label
var font: FontVariation
var font_plain: FontVariation
var _blink := 0.0
var _cooldown := 0.25
var _open := true


func start(c: Dictionary) -> void:
	## The choice to begin from (the one the skater wears now).
	original = SkaterOutfit.normalized(c)
	choice = original.duplicate()
	print("[skater] screen open: %s" % SkaterOutfit.to_arg(choice))


func _ready() -> void:
	layer = 11
	process_mode = Node.PROCESS_MODE_ALWAYS
	SkaterOutfit.ensure_actions()
	if choice.is_empty():
		start(SkaterOutfit.current())
	font = FontVariation.new()
	font.base_font = ThemeDB.fallback_font
	font.variation_embolden = 1.2
	font.variation_transform = Transform2D(Vector2(1, 0), Vector2(-0.22, 1), Vector2.ZERO)
	font_plain = FontVariation.new()
	font_plain.base_font = ThemeDB.fallback_font
	font_plain.variation_embolden = 0.4
	var bg := ColorRect.new()
	bg.name = "Backdrop"
	bg.color = Color(0.02, 0.02, 0.03, 0.94)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.add_child(center)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 56)
	center.add_child(hb)
	preview = SkaterPreview.new(Vector2i(640, 900))
	preview.name = "Preview"
	hb.add_child(preview)
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(1020, 0)
	col.add_theme_constant_override("separation", 12)
	hb.add_child(col)
	var title := _label(font, 92, Color(1, 0.82, 0.12), 16)
	title.text = "SKATER"
	col.add_child(title)
	var sub := _label(font_plain, 26, Color(0.8, 0.8, 0.82), 6)
	sub.text = "Pick your skater and clothes. The skater on the left changes as you go."
	col.add_child(sub)
	col.add_child(_spacer(10))
	for s in SkaterOutfit.SLOTS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 18)
		var name_l := _label(font, 32, Color(0.85, 0.85, 0.85), 6)
		name_l.custom_minimum_size = Vector2(250, 0)
		name_l.text = SkaterOutfit.SLOT_LABELS[s]
		row.add_child(name_l)
		var val := _label(font_plain, 34, Color(1, 1, 1), 6)
		val.custom_minimum_size = Vector2(600, 0)
		row.add_child(val)
		var cnt := _label(font_plain, 26, Color(0.6, 0.6, 0.65), 6)
		row.add_child(cnt)
		col.add_child(row)
		rows.append([row, name_l, val, cnt])
	col.add_child(_spacer(18))
	var grid := GridContainer.new()
	grid.name = "Controls"
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 40)
	grid.add_theme_constant_override("v_separation", 4)
	col.add_child(grid)
	for r in CONTROLS.size():
		for c in 3:
			var l := _label(font if r == 0 else font_plain, 28 if r == 0 else 24,
					Color(1, 0.82, 0.12) if r == 0 else (Color(0.85, 0.85, 0.85) if c == 0 else Color(1, 1, 1)), 6)
			l.text = CONTROLS[r][c]
			grid.add_child(l)
	col.add_child(_spacer(12))
	hint = _label(font, 38, Color(1, 1, 1), 10)
	hint.text = "ENTER / A  DONE        ESC / B  BACK"
	col.add_child(hint)
	preview.set_choice(choice)
	_refresh()


func _label(f: Font, size: int, color: Color, outline: int) -> Label:
	var l := Label.new()
	l.add_theme_font_override("font", f)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	l.add_theme_constant_override("outline_size", outline)
	return l


func _spacer(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


func _refresh() -> void:
	for i in rows.size():
		var s: String = SkaterOutfit.SLOTS[i]
		var r: Array = rows[i]
		var opts := SkaterOutfit.options(s)
		var sel := i == slot
		(r[1] as Label).add_theme_color_override("font_color", Color(1, 0.82, 0.12) if sel else Color(0.85, 0.85, 0.85))
		(r[2] as Label).text = ("<  %s  >" if sel else "   %s") % SkaterOutfit.label(s, choice[s])
		(r[2] as Label).add_theme_color_override("font_color", Color(1, 0.82, 0.12) if sel else Color(1, 1, 1))
		(r[3] as Label).text = "%d / %d" % [opts.find(choice[s]) + 1, opts.size()]
	preview.focus = SkaterOutfit.SLOTS[slot]


## The current value of a slot and the row labels, for tests and the report.
func slot_text(i: int) -> String:
	return (rows[i][2] as Label).text.strip_edges()


func move_slot(d: int) -> void:
	slot = wrapi(slot + d, 0, SkaterOutfit.SLOTS.size())
	Sfx.play("ui_move")
	_refresh()


func change(d: int) -> void:
	var s: String = SkaterOutfit.SLOTS[slot]
	var opts := SkaterOutfit.options(s)
	choice[s] = opts[wrapi(opts.find(choice[s]) + d, 0, opts.size())]
	Sfx.play("ui_move")
	preview.set_choice(choice)
	print("[skater] preview %s" % SkaterOutfit.to_arg(choice))
	_refresh()


func reset_default() -> void:
	choice = SkaterOutfit.default_choice()
	Sfx.play("ui_move")
	preview.set_choice(choice)
	_refresh()


func finish(save: bool) -> void:
	if not _open:
		return
	_open = false
	Sfx.play("ui_select")
	if save:
		SkaterOutfit.save(choice)
	print("[skater] %s" % ("saved " + SkaterOutfit.to_arg(choice) if save else "left without saving"))
	closed.emit(save, choice.duplicate() if save else original.duplicate())
	queue_free()


func _process(delta: float) -> void:
	_blink += delta
	hint.modulate.a = 0.55 + 0.45 * sin(_blink * 5.0)
	# turning: Q/E or LB/RB held, or the right stick
	var t := Input.get_action_strength("spin_right") - Input.get_action_strength("spin_left")
	for d in Input.get_connected_joypads():
		var ax := Input.get_joy_axis(d, JOY_AXIS_RIGHT_X)
		if absf(ax) > 0.2:
			t += ax
	if absf(t) > 0.01:
		preview.turn(t * 2.4 * delta)
		preview.auto_rotate = 0.0
	if _cooldown > 0.0:
		_cooldown -= delta
		return
	if Input.is_action_just_pressed("up"):
		move_slot(-1)
	elif Input.is_action_just_pressed("down"):
		move_slot(1)
	elif Input.is_action_just_pressed("left"):
		change(-1)
	elif Input.is_action_just_pressed("right"):
		change(1)
	elif Input.is_action_just_pressed("restart"):
		reset_default()
	elif Input.is_action_just_pressed("confirm"):
		finish(true)
	elif Input.is_action_just_pressed("skater_back"):
		finish(false)
