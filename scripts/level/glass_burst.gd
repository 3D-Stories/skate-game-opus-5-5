class_name GlassBurst
extends MultiMeshInstance3D
## The shards of one broken window: thin triangles of glass that tumble out into the hall,
## land on whatever is below (the east quarterpipe) and lie there glinting, then fade.
## Each shard's landing is found once, when the window breaks, by following its flight
## with a few ray segments; after that the flight is pure arithmetic per frame.

const GRAVITY := 12.0
const LIE_TIME := 7.0          # seconds a shard lies on the ramp before fading
const FADE_TIME := 1.0

static var _mesh: ArrayMesh
static var _mat: StandardMaterial3D

var _shards: Array = []        # per shard: {p0, v0, axis, spin, size, t_land, land_p, land_b, basis0}
var _t := 0.0


static func _shard_mesh() -> ArrayMesh:
	if _mesh == null:
		# one thin sliver of glass; every shard is this triangle, scaled and turned its own way
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_normal(Vector3.FORWARD)
		for v in [Vector3(-0.5, -0.4, 0), Vector3(0.55, -0.25, 0), Vector3(0.05, 0.6, 0)]:
			st.add_vertex(v)
		_mesh = st.commit()
		_mat = StandardMaterial3D.new()
		_mat.albedo_color = Color(0.55, 0.66, 0.66, 0.7)
		_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_mat.roughness = 0.03
		_mat.metallic_specular = 1.0
		_mat.emission_enabled = true
		_mat.emission = Color(0.45, 0.55, 0.55)
		_mat.emission_energy_multiplier = 0.35
		_mesh.surface_set_material(0, _mat)
	return _mesh


func burst(space: PhysicsDirectSpaceState3D, center: Vector3, half: Vector2, into: Vector3, carry: Vector3, count := 48, seed := 0) -> void:
	## center/half: the window (Godot axes, half width along z, half height); into: the
	## direction into the hall; carry: the skater's velocity (the glass goes his way too).
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([seed, center])
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = _shard_mesh()
	multimesh.instance_count = count
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for i in count:
		var p0 := center + Vector3(0.0, rng.randf_range(-half.y, half.y) * 0.8, rng.randf_range(-half.x, half.x) * 0.85)
		var v0 := into * rng.randf_range(1.2, 4.2) + Vector3.UP * rng.randf_range(-0.5, 1.8) \
				+ Vector3(0, 0, rng.randf_range(-1.2, 1.2)) + carry * rng.randf_range(0.15, 0.45)
		var size := rng.randf_range(0.04, 0.16)
		var b0 := Basis.from_euler(Vector3(rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU)).scaled(
				Vector3(size, size * rng.randf_range(0.5, 1.4), size))
		var sh := {"p0": p0, "v0": v0, "axis": Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized(),
				"spin": rng.randf_range(8.0, 24.0), "b0": b0, "t_land": 3.0, "land_p": Vector3.ZERO, "land_b": Basis.IDENTITY}
		# where it lands: step along the parabola until a segment hits the park
		var prev := p0
		var t := 0.0
		while t < 3.0:
			t += 1.0 / 30.0
			var p := p0 + v0 * t + Vector3.DOWN * 0.5 * GRAVITY * t * t
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(prev, p, 1))
			if not hit.is_empty():
				var n: Vector3 = hit["normal"]
				sh["t_land"] = t - 1.0 / 30.0 + prev.distance_to(hit["position"]) / maxf(prev.distance_to(p), 1e-4) / 30.0
				sh["land_p"] = (hit["position"] as Vector3) + n * 0.004
				# lying flat on the surface (the triangle's normal along the surface normal)
				var x := n.cross(Vector3(rng.randf_range(-1, 1), 0.3, rng.randf_range(-1, 1))).normalized()
				# (the mesh lies in its local XY plane: its z axis goes along the normal)
				sh["land_b"] = Basis(x, n.cross(x), n).orthonormalized().scaled(Vector3(size, size, size))
				break
			prev = p
		_shards.append(sh)
	_update()


func _process(delta: float) -> void:
	_t += delta
	_update()
	if _t > LIE_TIME + FADE_TIME + 3.0:
		queue_free()


func _update() -> void:
	for i in _shards.size():
		var sh: Dictionary = _shards[i]
		var tl: float = sh["t_land"]
		var xf: Transform3D
		if _t < tl:
			var p: Vector3 = sh["p0"] + sh["v0"] * _t + Vector3.DOWN * 0.5 * GRAVITY * _t * _t
			xf = Transform3D(Basis(sh["axis"], sh["spin"] * _t) * sh["b0"], p)
		else:
			var fade := clampf((_t - tl - LIE_TIME) / FADE_TIME, 0.0, 1.0)
			var b: Basis = sh["land_b"]
			xf = Transform3D(b.scaled(Vector3.ONE * maxf(1.0 - fade, 0.001)), sh["land_p"])
		multimesh.set_instance_transform(i, xf)
