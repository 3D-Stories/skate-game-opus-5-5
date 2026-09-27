class_name SkaterOutfit
extends RefCounted
## The character builder's choice: which body and which garment in each slot. The wardrobe
## itself (options, labels, meshes, what each garment covers) comes from the Blender build
## (res://assets/outfit/catalog.json). The choice is saved in user://skater.cfg and is
## what the run, the end screen and the scripted runs use.
##   --skater=female,tee,cargo,hitop,cap   (command line) / ?skater=... (web URL) overrides it.

const SAVE_PATH := "user://skater.cfg"
const CATALOG_PATH := "res://assets/outfit/catalog.json"
const BODIES := ["male", "female"]
const BODY_LABELS := {"male": "Male skater", "female": "Female skater"}
const SLOTS := ["body", "top", "bottom", "shoes", "hat"]
const SLOT_LABELS := {"body": "SKATER", "top": "TOP", "bottom": "BOTTOM", "shoes": "SHOES", "hat": "HEADWEAR"}
const BODY_GLB := {"male": "res://assets/skater.glb", "female": "res://assets/skater_female.glb"}

static var _catalog: Dictionary = {}
## Where the choice is saved (tests point this at their own file).
static var save_path := SAVE_PATH
## Set by tests (or anything else) to force a choice for every model built afterwards.
static var override: Dictionary = {}
## Tests of the save/restore path set this: then a test run also starts from the saved
## choice, as a real launch does.
static var use_saved_in_tests := false


static func catalog() -> Dictionary:
	if _catalog.is_empty():
		var f := FileAccess.open(CATALOG_PATH, FileAccess.READ)
		if f:
			_catalog = JSON.parse_string(f.get_as_text())
	return _catalog


static func default_choice() -> Dictionary:
	## Today's skater: the male in the red hoodie, blue jeans and grey suede low-tops.
	return {"body": "male", "top": "hoodie", "bottom": "jeans", "shoes": "suede", "hat": "none"}


static func options(slot: String) -> Array:
	if slot == "body":
		return BODIES.duplicate()
	var s: Dictionary = catalog().get("slots", {})
	return (s.get(slot, []) as Array).duplicate()


static func label(slot: String, id: String) -> String:
	if slot == "body":
		return BODY_LABELS.get(id, id)
	return String(catalog().get("labels", {}).get(id, id))


static func normalized(c: Dictionary) -> Dictionary:
	## Every slot present and valid (unknown values fall back to the default).
	var d := default_choice()
	var out := {}
	for slot in SLOTS:
		var v := str(c.get(slot, d[slot]))
		out[slot] = v if v in options(slot) else d[slot]
	return out


static func parse(s: String) -> Dictionary:
	## "female,tee,cargo,hitop,cap" (body, top, bottom, shoes, hat; missing = default) or
	## "default".
	var c := default_choice()
	if s == "" or s == "default":
		return c
	var parts := s.split(",")
	for i in mini(parts.size(), SLOTS.size()):
		if parts[i] != "":
			c[SLOTS[i]] = parts[i]
	return normalized(c)


static func to_arg(c: Dictionary) -> String:
	var p := PackedStringArray()
	for slot in SLOTS:
		p.append(String(c[slot]))
	return ",".join(p)


static func is_default(c: Dictionary) -> bool:
	return normalized(c) == default_choice()


static func load_saved() -> Dictionary:
	var cf := ConfigFile.new()
	if cf.load(save_path) != OK:
		return default_choice()
	var c := {}
	for slot in SLOTS:
		c[slot] = cf.get_value("skater", slot, default_choice()[slot])
	return normalized(c)


static func save(c: Dictionary) -> void:
	var cf := ConfigFile.new()
	var n := normalized(c)
	for slot in SLOTS:
		cf.set_value("skater", slot, n[slot])
	cf.save(save_path)


static func _arg_choice() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--skater="):
			return a.get_slice("=", 1)
	if OS.has_feature("web"):
		var q = JavaScriptBridge.eval("window.location.search", true)
		if q is String and "skater=" in q:
			return (q as String).get_slice("skater=", 1).get_slice("&", 0).uri_decode()
	return ""


static func running_test() -> bool:
	## Headless test scripts and the scripted test run use today's skater unless they ask
	## for another, whatever a player saved on this machine.
	var args := OS.get_cmdline_args()
	if "-s" in args or "--script" in args:
		return true
	for a in OS.get_cmdline_user_args():
		if a == "--autopilot=test":
			return true
	return false


static func current() -> Dictionary:
	if not override.is_empty():
		return normalized(override)
	var a := _arg_choice()
	if a != "":
		return parse(a)
	if running_test() and not use_saved_in_tests:
		return default_choice()
	return load_saved()


# ------------------------------------------------------------------ what a choice wears

static func garment(id: String) -> Dictionary:
	return catalog().get("garments", {}).get(id, {})


static func worn_garments(c: Dictionary) -> Array:
	## Garment ids whose meshes are shown (colourways resolve to their base meshes later).
	## Over hi-tops, long trousers are their "_high" weighting (the hem moves with the taller
	## shoe); socks show with shorts, the pair that moves with the shoes being worn.
	var out: Array = []
	var high: bool = "shoes_high" in garment(String(c["shoes"])).get("covers", [])
	for slot in ["top", "bottom", "shoes", "hat"]:
		var id := String(c[slot])
		if id == "none":
			continue
		if high and garment(id).has("with_high_shoes"):
			id = String(garment(id)["with_high_shoes"])
		out.append(id)
	if garment(String(c["bottom"])).get("shows_socks", false):
		out.append("socks_high" if high else "socks")
	return out


static func worn_id(c: Dictionary, slot: String) -> String:
	## The garment id worn for a slot (the "_high" weighting of long trousers over hi-tops).
	var id := String(c[slot])
	if slot == "bottom" and "shoes_high" in garment(String(c["shoes"])).get("covers", []) and garment(id).has("with_high_shoes"):
		return String(garment(id)["with_high_shoes"])
	return id


static func body_mask(c: Dictionary) -> int:
	## Body cells to hide: every coverage class the worn garments cover (socks always).
	var bits: Dictionary = catalog().get("cell_bits", {})
	var m := 1 << int(bits.get("socks", 8))
	for slot in ["top", "bottom", "shoes"]:
		for cls in garment(String(c[slot])).get("covers", []):
			m |= 1 << int(bits.get(cls, 0))
	return m


static func hat_mask(c: Dictionary) -> int:
	var h := String(c["hat"])
	if h == "none":
		return 0
	return 1 << int(garment(h).get("hat_bit", 0))


static func ankle_height(body: String) -> float:
	## The ankle bone's height over the shoe sole at rest (feet-on-deck tests).
	var b: Dictionary = catalog().get("bodies", {}).get(body, {})
	return float(b.get("ankle_h", 0.0725))


static func ensure_actions() -> void:
	## The builder's own input action (added at run time: no project.godot change).
	if InputMap.has_action("skater_menu"):
		return
	InputMap.add_action("skater_menu", 0.5)
	var k := InputEventKey.new()
	k.keycode = KEY_C
	InputMap.action_add_event("skater_menu", k)
	var t := InputEventKey.new()
	t.keycode = KEY_TAB
	InputMap.action_add_event("skater_menu", t)
	var j := InputEventJoypadButton.new()
	j.button_index = JOY_BUTTON_Y
	InputMap.action_add_event("skater_menu", j)
	# leaving the Skater screen without saving: Esc or B (the project's ui_cancel is Esc only)
	InputMap.add_action("skater_back", 0.5)
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	InputMap.action_add_event("skater_back", esc)
	var b := InputEventJoypadButton.new()
	b.button_index = JOY_BUTTON_B
	InputMap.action_add_event("skater_back", b)
