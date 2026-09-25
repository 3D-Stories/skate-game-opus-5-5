class_name Level
extends Node3D
## Loads the Blender-built Warehouse (park.glb + park_data.json + park_lightmap.png),
## puts the lightmap PBR shader on every surface, tags collision by surface type, builds
## the rails used for grinding, the breakable windows and wall, and the pickups.

signal window_broken(index: int, total: int)
signal wall_broken
signal letter_collected(letter: String)
signal tape_collected

const PARK := preload("res://assets/park.glb")
const PICKUPS := preload("res://assets/pickups.glb")
const LIGHTMAP := preload("res://assets/park_lightmap.png")
const PARK_SHADER := preload("res://shaders/park.gdshader")
const DECAL_SHADER := preload("res://shaders/park_decal.gdshader")
const DATA_PATH := "res://assets/park_data.json"

const METALLIC := {"coping": 0.85, "corrugated": 0.55, "roof": 0.45, "diamond": 0.7, "steel": 0.35,
		"steel_paint": 0.3, "rafter": 0.25, "rail": 0.45, "barrel": 0.35, "dumpster": 0.3}
## Overall strength of the baked light against the real-time sun (tuned in-game).
const LIGHTMAP_ENERGY := 0.6
const NORMAL_DEPTH := {"concrete_floor": 0.8, "brick": 1.4, "corrugated": 1.5, "roof": 1.2, "plywood": 0.6}

var data: Dictionary = {}
var rails: Array[Rail] = []
var park: Node3D
var windows: Array = []          # {node, area, broken, center}
var wall_nodes: Array[Node3D] = []
var wall_body: StaticBody3D
var wall_broken_flag := false
var letters: Array = []          # {letter, node, taken}
var tape: Node3D
var tape_taken := false
var spawn_pos := Vector3.ZERO
var spawn_forward := Vector3.FORWARD
var sun_dir := Vector3(0.4, -0.7, -0.5)
var lightmap_scale := 6.0
var _t := 0.0


func _ready() -> void:
	data = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
	park = PARK.instantiate()
	add_child(park)
	var light: Dictionary = data.get("lighting", {})
	if light.has("sun_dir"):
		var d: Array = light["sun_dir"]
		sun_dir = Vector3(d[0], d[1], d[2]).normalized()
	lightmap_scale = float(light.get("lightmap_scale", 6.0))
	_setup_visuals(park)
	_setup_collision(park)
	for r in data.get("rails", []):
		rails.append(Rail.from_dict(r))
	_setup_windows()
	_setup_wall()
	_setup_pickups()
	var sp: Dictionary = data["spawn"]
	spawn_pos = _v(sp["pos"])
	spawn_forward = _v(sp["forward"]).normalized()


func _v(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])


func _setup_visuals(root: Node) -> void:
	for mi in _meshes(root):
		var n := String(mi.name)
		if n.begins_with("Window_"):
			var g := StandardMaterial3D.new()
			g.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			g.albedo_color = Color(0.55, 0.65, 0.68, 0.28)
			g.roughness = 0.08
			g.metallic_specular = 0.9
			g.emission_enabled = true
			g.emission = Color(0.55, 0.62, 0.72)
			g.emission_energy_multiplier = 0.25
			mi.material_override = g
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			continue
		var mesh := mi.mesh
		var shadows := GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
		for s in mesh.get_surface_count():
			var m := mesh.surface_get_material(s) as StandardMaterial3D
			if m == null:
				continue
			var key := m.resource_name.trim_prefix("park_")
			if key == "graffiti":
				var dm := ShaderMaterial.new()
				dm.shader = DECAL_SHADER
				dm.set_shader_parameter("albedo_tex", m.albedo_texture)
				dm.set_shader_parameter("lightmap_tex", LIGHTMAP)
				dm.set_shader_parameter("lightmap_scale", lightmap_scale)
				dm.set_shader_parameter("lightmap_energy", LIGHTMAP_ENERGY)
				mesh.surface_set_material(s, dm)
				shadows = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				continue
			if key in ["lamp", "skylight", "exit_sign", "yard"]:
				var e := StandardMaterial3D.new()
				e.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				var c := m.emission if m.emission_enabled else Color(1, 1, 1)
				e.albedo_color = c * {"lamp": 2.2, "yard": 1.35}.get(key, 1.4)
				mesh.surface_set_material(s, e)
				shadows = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				continue
			var sm := ShaderMaterial.new()
			sm.shader = PARK_SHADER
			sm.set_shader_parameter("albedo_tex", m.albedo_texture)
			sm.set_shader_parameter("normal_tex", m.normal_texture)
			sm.set_shader_parameter("lightmap_tex", LIGHTMAP)
			sm.set_shader_parameter("lightmap_scale", lightmap_scale)
			sm.set_shader_parameter("lightmap_energy", LIGHTMAP_ENERGY)
			sm.set_shader_parameter("metallic", METALLIC.get(key, 0.0))
			sm.set_shader_parameter("normal_depth", NORMAL_DEPTH.get(key, 1.0))
			mesh.surface_set_material(s, sm)
		# the hall is single-sided geometry: cast from both faces so the roof shades the sun
		mi.cast_shadow = shadows


func _setup_collision(root: Node) -> void:
	for n in _all(root):
		if n is StaticBody3D:
			var nm := String(n.name)
			var surf := "concrete"
			if "wood" in nm:
				surf = "wood"
			elif "metal" in nm:
				surf = "metal"
			elif "wall" in nm:
				surf = "wall"
			n.set_meta("surface", surf)
			n.collision_layer = 1
			n.collision_mask = 0
			for c in n.get_children():
				if c is CollisionShape3D and c.shape is ConcavePolygonShape3D:
					c.shape.backface_collision = true


func _setup_windows() -> void:
	for w in data.get("windows", []):
		var node := park.find_child(w["name"], true, false) as Node3D
		var c := _v(w["center"])
		windows.append({"node": node, "broken": false, "center": c, "half": float(w["size"][0]) * 0.5,
				"bottom": c.y - float(w["size"][1]) * 0.5})


## A window breaks when the skater flies up into it (vert air off the east quarter) or
## grinds the wall pipe underneath it.
func check_windows(pos: Vector3, airborne: bool) -> void:
	if not airborne:
		return
	for i in windows.size():
		var w: Dictionary = windows[i]
		if w["broken"]:
			continue
		var c: Vector3 = w["center"]
		if pos.x > c.x - 2.2 and absf(pos.z - c.z) < w["half"] + 0.4 and pos.y + 1.3 > w["bottom"]:
			break_window(i)


func break_window(i: int) -> void:
	var w: Dictionary = windows[i]
	if w["broken"]:
		return
	w["broken"] = true
	if w["node"]:
		w["node"].visible = false
	_spawn_debris(w["center"], Color(0.7, 0.85, 0.9), 70, 0.08, Vector3(-3, 1, 0))
	Sfx.play("glass", w["center"])
	var n := 0
	for x in windows:
		if x["broken"]:
			n += 1
	window_broken.emit(i, n)


func windows_broken() -> int:
	var n := 0
	for x in windows:
		if x["broken"]:
			n += 1
	return n


func _setup_wall() -> void:
	var wd: Dictionary = data.get("break_wall", {})
	for nm in wd.get("nodes", []):
		var nd := park.find_child(nm, true, false) as Node3D
		if nd:
			wall_nodes.append(nd)
	wall_body = StaticBody3D.new()
	wall_body.name = "BreakWallBody"
	wall_body.set_meta("surface", "wall")
	wall_body.set_meta("breakable", true)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	var sz: Array = wd.get("size", [0.3, 3.2, 5.0])
	box.size = Vector3(sz[0], sz[1], sz[2])
	cs.shape = box
	wall_body.add_child(cs)
	add_child(wall_body)
	wall_body.global_position = _v(wd.get("center", [0, 0, 0]))


func break_wall() -> void:
	if wall_broken_flag:
		return
	wall_broken_flag = true
	for n in wall_nodes:
		n.visible = false
	wall_body.queue_free()
	_spawn_debris(wall_body.global_position, Color(0.55, 0.42, 0.3), 45, 0.25, Vector3(-4, 1.5, 0))
	Sfx.play("wall", wall_body.global_position)
	wall_broken.emit()


func _setup_pickups() -> void:
	var src := PICKUPS.instantiate()
	for L in data.get("letters", []):
		var letter: String = L["letter"]
		var proto := src.find_child("Letter_" + letter, true, false) as Node3D
		var holder := Node3D.new()
		holder.name = "Pickup_" + letter
		add_child(holder)
		holder.global_position = _v(L["pos"])
		if proto:
			var dup := proto.duplicate() as Node3D
			dup.transform = Transform3D.IDENTITY
			holder.add_child(dup)
			_glow_materials(dup, Color(1.0, 0.78, 0.15))
		var area := _pickup_area(holder, 0.9)
		var entry := {"letter": letter, "node": holder, "taken": false, "base_y": holder.position.y}
		area.body_entered.connect(func(_b): _take_letter(entry))
		letters.append(entry)
	var tape_proto := src.find_child("SecretTape", true, false) as Node3D
	tape = Node3D.new()
	tape.name = "Pickup_Tape"
	add_child(tape)
	tape.global_position = _v(data["tape"])
	if tape_proto:
		var t := tape_proto.duplicate() as Node3D
		t.transform = Transform3D.IDENTITY
		tape.add_child(t)
		_glow_materials(t, Color(0.3, 0.7, 1.0))
	var ta := _pickup_area(tape, 0.8)
	ta.body_entered.connect(func(_b): _take_tape())
	src.queue_free()


func _glow_materials(root: Node, glow: Color) -> void:
	for mi in _meshes(root):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		for s in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(s)
			if m is StandardMaterial3D:
				var mm := (m as StandardMaterial3D).duplicate() as StandardMaterial3D
				mm.emission_enabled = true
				mm.emission = glow
				mm.emission_energy_multiplier = 1.2
				mi.set_surface_override_material(s, mm)


func _pickup_area(holder: Node3D, radius: float) -> Area3D:
	var area := Area3D.new()
	area.collision_layer = 4
	area.collision_mask = 2
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = radius
	cs.shape = sph
	area.add_child(cs)
	holder.add_child(area)
	return area


func _take_letter(entry: Dictionary) -> void:
	if entry["taken"]:
		return
	entry["taken"] = true
	entry["node"].visible = false
	Sfx.play("letter", entry["node"].global_position)
	letter_collected.emit(entry["letter"])


func _take_tape() -> void:
	if tape_taken:
		return
	tape_taken = true
	tape.visible = false
	Sfx.play("tape", tape.global_position)
	tape_collected.emit()


func reset_run() -> void:
	for w in windows:
		w["broken"] = false
		if w["node"]:
			w["node"].visible = true
	for L in letters:
		L["taken"] = false
		L["node"].visible = true
	tape_taken = false
	tape.visible = true
	if wall_broken_flag:
		wall_broken_flag = false
		for n in wall_nodes:
			n.visible = true
		_setup_wall()


func _process(delta: float) -> void:
	_t += delta
	for L in letters:
		if not L["taken"]:
			L["node"].rotation.y = _t * 2.0
			L["node"].position.y = float(L["base_y"]) + sin(_t * 3.0) * 0.08
	if tape and not tape_taken:
		tape.rotation.y = _t * 1.6


func _spawn_debris(pos: Vector3, color: Color, amount: int, size: float, push: Vector3) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.emitting = true
	p.amount = amount
	p.lifetime = 1.6
	p.explosiveness = 0.95
	p.direction = push.normalized()
	p.spread = 70.0
	p.initial_velocity_min = 2.0
	p.initial_velocity_max = push.length() + 3.0
	p.gravity = Vector3(0, -12, 0)
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(0.1, 1.0, 1.2)
	var mesh := BoxMesh.new()
	mesh.size = Vector3(size, size * 0.2, size * 0.7)
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.3
	mesh.material = m
	p.mesh = mesh
	add_child(p)
	p.global_position = pos
	get_tree().create_timer(2.5).timeout.connect(p.queue_free)


## Nearest rail to p within radius. Returns {} or {rail, s, point, dir, dist}.
func find_rail(p: Vector3, radius: float) -> Dictionary:
	var best := {}
	var bd := radius
	for r in rails:
		var c := r.closest(p)
		if c["dist"] < bd:
			bd = c["dist"]
			best = c
			best["rail"] = r
	return best


func in_halfpipe(p: Vector3) -> bool:
	var hp: Dictionary = data.get("halfpipe", {})
	if hp.is_empty():
		return false
	var c := _v(hp["center"])
	return absf(p.x - c.x) < 8.0 and absf(p.z - c.z) < 6.5


func surface_of(collider: Object) -> String:
	if collider and collider.has_meta("surface"):
		return collider.get_meta("surface")
	return "concrete"


func _meshes(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for n in _all(root):
		if n is MeshInstance3D:
			out.append(n)
	return out


func _all(root: Node) -> Array[Node]:
	var out: Array[Node] = []
	var st: Array[Node] = [root]
	while st.size() > 0:
		var n: Node = st.pop_back()
		out.append(n)
		for c in n.get_children():
			st.append(c)
	return out
