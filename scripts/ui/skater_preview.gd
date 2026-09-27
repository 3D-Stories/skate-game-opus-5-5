class_name SkaterPreview
extends SubViewportContainer
## A lit 3D turntable of a skater (a SkaterModel built from a character-builder choice) in
## its own small world: warm key light with shadows, cool fill, a rim light from behind, a
## floor disc that fades into the backdrop. Used by the Skater screen (skater_builder.gd)
## and the end-of-run screen.

signal rebuilt

const FRAMES := {
	# slot -> [look-at height, camera distance]: the view leans towards what is being changed
	"body": [0.95, 4.3], "top": [1.15, 3.6], "bottom": [0.7, 3.7], "shoes": [0.35, 3.3], "hat": [1.55, 2.6],
}
# ... and follows that part of the body as it turns (in the stance the head, chest and feet
# stand well off the turntable's axis); the hat view centres on the head itself
const FOCUS_BONES := {"body": ["pelvis"], "top": ["spine_03"], "bottom": ["pelvis", "calf_l", "calf_r"], "shoes": ["foot_l", "foot_r"], "hat": ["head"]}

var viewport: SubViewport
var model: SkaterModel
var turntable: Node3D
var cam: Camera3D
var choice: Dictionary = {}
var auto_rotate := 0.35          # rad/s while nobody turns it by hand
var angle := 0.35
var clip := "idle"
var focus := "body"
var _look := Vector2(0.95, 4.3)
var _target := Vector3(0.0, 0.95, 0.0)


func _init(size_px := Vector2i(720, 900)) -> void:
	stretch = true
	custom_minimum_size = Vector2(size_px)
	viewport = SubViewport.new()
	viewport.size = size_px
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	add_child(viewport)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = BACKDROP
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.42, 0.46, 0.54)
	e.ambient_light_energy = 0.55
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	e.tonemap_exposure = 1.05
	# the floor melts into the backdrop: no horizon line behind the skater
	e.fog_enabled = true
	e.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	e.fog_light_color = BACKDROP
	e.fog_density = 0.09
	e.fog_sky_affect = 0.0
	env.environment = e
	viewport.add_child(env)
	var key := DirectionalLight3D.new()
	key.light_energy = 2.1
	key.light_color = Color(1, 0.93, 0.84)
	key.shadow_enabled = true
	key.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	key.directional_shadow_max_distance = 8.0
	viewport.add_child(key)
	key.look_at_from_position(Vector3(-2.2, 3.4, 2.6), Vector3.ZERO, Vector3.UP)
	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.55
	fill.light_color = Color(0.78, 0.86, 1.0)
	viewport.add_child(fill)
	fill.look_at_from_position(Vector3(3.0, 1.4, 1.5), Vector3.ZERO, Vector3.UP)
	var rim := DirectionalLight3D.new()
	rim.light_energy = 1.3
	rim.light_color = Color(0.9, 0.95, 1.0)
	viewport.add_child(rim)
	rim.look_at_from_position(Vector3(0.6, 2.2, -3.0), Vector3(0, 1, 0), Vector3.UP)
	# floor: lit in the middle, fading into the backdrop further out
	var floor_mi := MeshInstance3D.new()
	var disc := PlaneMesh.new()
	disc.size = Vector2(60, 60)
	floor_mi.mesh = disc
	var fm := ShaderMaterial.new()
	fm.shader = _floor_shader()
	floor_mi.material_override = fm
	viewport.add_child(floor_mi)
	turntable = Node3D.new()
	turntable.name = "Turntable"
	viewport.add_child(turntable)
	cam = Camera3D.new()
	cam.fov = 30.0
	cam.near = 0.05
	viewport.add_child(cam)
	cam.current = true


const BACKDROP := Color(0.05, 0.053, 0.065)


static func _floor_shader() -> Shader:
	var s := Shader.new()
	s.code = """
shader_type spatial;
varying vec3 wpos;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	float spot = 1.0 - smoothstep(0.7, 3.2, length(wpos.xz));
	ALBEDO = mix(vec3(0.02, 0.021, 0.026), vec3(0.30, 0.30, 0.31), spot);
	ROUGHNESS = 0.9;
	SPECULAR = 0.2;
}
"""
	return s


func set_choice(c: Dictionary) -> void:
	## Show this body and outfit (rebuilds the model only when something changed).
	c = SkaterOutfit.normalized(c)
	if model and c == choice:
		return
	choice = c
	if model == null:
		model = SkaterModel.new()
		model.outfit = c
		turntable.add_child(model)
	else:
		model.rebuild(c)
	# the preview is a mannequin: no ragdoll physics in its little world
	for pb in model.rag.values():
		(pb as PhysicalBone3D).collision_layer = 0
		(pb as PhysicalBone3D).collision_mask = 0
	model.play(clip, 0.0)
	# turn about the middle of the stance (the idle pose stands off the model's origin)
	model.anim.seek(0.0, true)
	var sk := model.skeleton
	var mid := (sk.get_bone_global_pose(sk.find_bone("foot_l")).origin + sk.get_bone_global_pose(sk.find_bone("foot_r")).origin) * 0.5
	mid = (model.global_transform.affine_inverse() * sk.global_transform) * mid
	model.position = -Vector3(mid.x, 0.0, mid.z)
	rebuilt.emit()


func set_clip(name: String) -> void:
	clip = name
	if model:
		model.restart(name, 0.0)


func turn(amount: float) -> void:
	angle += amount


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	angle += auto_rotate * delta
	turntable.rotation.y = angle
	var f: Array = FRAMES.get(focus, FRAMES["body"])
	var want := Vector2(f[0], f[1])
	var k := clampf(delta * 5.0, 0.0, 1.0)
	_look = _look.lerp(want, k)
	_target = _target.lerp(_focus_point(f[0]), k)
	cam.global_position = _target + Vector3(0, 0.1 + 0.06 * _look.y, _look.y)
	cam.look_at(_target)


func _focus_point(height: float) -> Vector3:
	var names: Array = FOCUS_BONES.get(focus, [])
	if model == null or names.is_empty():
		return Vector3(0.0, height, 0.0)
	var sk := model.skeleton
	var sum := Vector3.ZERO
	for n in names:
		sum += sk.global_transform * sk.get_bone_global_pose(sk.find_bone(n)).origin
	sum /= names.size()
	# (the head bone sits at the top of the neck: the middle of the head is a little higher)
	return Vector3(sum.x, sum.y + 0.07 if focus == "hat" else height, sum.z)
