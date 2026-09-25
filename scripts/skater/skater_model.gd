class_name SkaterModel
extends Node3D
## The visual skater: the Blender-built character (skater.glb) with its animation clips, and
## the separate board (board.glb) riding on the skeleton's "board" bone. Swaps the imported
## materials for the game shaders (skin, hair) and exposes a small play/blend API.

const SKATER_SCENE := preload("res://assets/skater.glb")
const BOARD_SCENE := preload("res://assets/board.glb")
const SKIN_SHADER := preload("res://shaders/skin.gdshader")
const HAIR_SHADER := preload("res://shaders/hair.gdshader")

const LOOPING := ["idle", "ride", "crouch", "push", "air", "grind_5050", "boardslide",
		"manual", "nose_manual", "vert_air"]

var character: Node3D
var skeleton: Skeleton3D
var anim: AnimationPlayer
var board: Node3D
var board_attach: BoneAttachment3D
var wheels: Array[Node3D] = []
var _wheel_rest: Array[Basis] = []
var _wheel_angle := 0.0
var current := ""
var board_detached := false
var _board_offset := Transform3D.IDENTITY


func _ready() -> void:
	character = SKATER_SCENE.instantiate()
	add_child(character)
	skeleton = _find(character, "Skeleton3D") as Skeleton3D
	anim = _find(character, "AnimationPlayer") as AnimationPlayer
	for a_name in anim.get_animation_list():
		var a := anim.get_animation(a_name)
		a.loop_mode = Animation.LOOP_LINEAR if a_name in LOOPING else Animation.LOOP_NONE
	_setup_materials(character)
	board = BOARD_SCENE.instantiate()
	board_attach = BoneAttachment3D.new()
	board_attach.name = "BoardAttach"
	skeleton.add_child(board_attach)
	board_attach.bone_name = "board"
	var idx := skeleton.find_bone("board")
	var rest := skeleton.get_bone_global_rest(idx)
	# at rest the board sits unrotated at the bone head: keep that relation while animating
	_board_offset = rest.affine_inverse() * Transform3D(Basis.IDENTITY, rest.origin)
	board_attach.add_child(board)
	board.transform = _board_offset
	for n in ["Wheel_FL", "Wheel_FR", "Wheel_BL", "Wheel_BR"]:
		var w := board.find_child(n, true, false) as Node3D
		if w:
			wheels.append(w)
			_wheel_rest.append(w.basis)
	for m in _all_meshes(board):
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	play("idle", 0.0)


func play(clip: String, blend := 0.12, speed := 1.0) -> void:
	if not anim.has_animation(clip):
		return
	if clip == current and anim.is_playing():
		anim.speed_scale = speed
		return
	current = clip
	anim.play(clip, blend)
	anim.speed_scale = speed


func restart(clip: String, blend := 0.08, speed := 1.0) -> void:
	current = ""
	anim.stop(true)
	play(clip, blend, speed)


func clip_length(clip: String) -> float:
	return anim.get_animation(clip).length if anim.has_animation(clip) else 0.0


func clip_progress() -> float:
	if current == "" or not anim.has_animation(current):
		return 1.0
	var l := anim.get_animation(current).length
	return clamp(anim.current_animation_position / max(0.001, l), 0.0, 1.0)


func spin_wheels(dist: float) -> void:
	_wheel_angle = fmod(_wheel_angle - dist / 0.0265, TAU)
	for i in wheels.size():
		wheels[i].basis = _wheel_rest[i] * Basis(Vector3.BACK, _wheel_angle)


## Throws the board off during a bail: it becomes a free rigid body in the level.
func detach_board(parent: Node3D, velocity: Vector3) -> RigidBody3D:
	if board_detached:
		return null
	board_detached = true
	var xf := board.global_transform
	var body := RigidBody3D.new()
	body.name = "LooseBoard"
	body.mass = 2.2
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.8, 0.1, 0.2)
	shape.shape = box
	body.add_child(shape)
	parent.add_child(body)
	body.global_transform = xf
	board.get_parent().remove_child(board)
	body.add_child(board)
	board.transform = Transform3D.IDENTITY
	body.linear_velocity = velocity
	body.angular_velocity = Vector3(randf_range(-9, 9), randf_range(-6, 6), randf_range(-9, 9))
	return body


func reattach_board() -> void:
	if not board_detached:
		return
	var holder := board.get_parent()
	holder.remove_child(board)
	board_attach.add_child(board)
	board.transform = _board_offset
	holder.queue_free()
	board_detached = false


func _setup_materials(root: Node) -> void:
	for mi in _all_meshes(root):
		var mesh := mi.mesh
		if mesh == null:
			continue
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		for s in mesh.get_surface_count():
			var m := mesh.surface_get_material(s) as StandardMaterial3D
			if m == null:
				continue
			var n := m.resource_name
			var nm: Material = null
			if n == "Skin":
				var sm := ShaderMaterial.new()
				sm.shader = SKIN_SHADER
				sm.set_shader_parameter("albedo_tex", m.albedo_texture)
				sm.set_shader_parameter("normal_tex", m.normal_texture)
				sm.set_shader_parameter("rough_tex", m.roughness_texture)
				nm = sm
			elif n == "Hair" or n.begins_with("Lashes") or n == "Eyebrows":
				var hm := ShaderMaterial.new()
				hm.shader = HAIR_SHADER
				hm.set_shader_parameter("albedo_tex", m.albedo_texture)
				hm.set_shader_parameter("alpha_cut", 0.3 if n == "Hair" else 0.25)
				nm = hm
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if n == "Hair" else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			elif n == "Cornea":
				var c := StandardMaterial3D.new()
				c.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				c.albedo_color = Color(1, 1, 1, 0.06)
				c.roughness = 0.02
				c.metallic_specular = 1.0
				nm = c
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			elif n == "Eye":
				m.roughness = 0.25
				m.clearcoat_enabled = true
				m.clearcoat = 1.0
				m.clearcoat_roughness = 0.05
			else:
				# fabrics: a touch of rim sheen reads as fleece/denim fibres
				if n in ["Hoodie", "Jeans"] or n.begins_with("Hood_"):
					m.rim_enabled = true
					m.rim = 0.25
					m.rim_tint = 0.6
			if nm:
				mesh.surface_set_material(s, nm)


func _all_meshes(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var stack: Array[Node] = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


func _find(root: Node, cls: String) -> Node:
	if root.get_class() == cls:
		return root
	for c in root.get_children():
		var r := _find(c, cls)
		if r:
			return r
	return null
