extends RefCounted
## Fingerprint of a skater model as the game shows it: for every material, the multiset of
## visible triangles (positions to 0.01 mm, UVs, skin bones and weights, winding kept), the
## vertex normals, the textures' source bytes; the skeleton's rest pose; every animation
## track's keys. Two fingerprints are equal only if the game draws and animates the same
## skater. Used by tests/skater_fingerprint.gd (writes the baseline of the original skater)
## and tests/test_builder.gd (the default selection must match it).

const POS_Q := 1e-5
const UV_Q := 1e-4
const W_Q := 1e-3
const N_Q := 2e-3


static func _q(x: float, q: float) -> String:
	return str(int(round(x / q)))


static func _vkey(p: Vector3, uv: Vector2, bones: PackedStringArray, w: PackedFloat32Array, weights := true) -> String:
	var s := "%s,%s,%s|%s,%s" % [_q(p.x, POS_Q), _q(p.y, POS_Q), _q(p.z, POS_Q), _q(uv.x, UV_Q), _q(uv.y, UV_Q)]
	if not weights:
		return s
	var pairs: Array = []
	for i in bones.size():
		if w[i] > 0.0005:
			pairs.append("%s:%s" % [bones[i], _q(w[i], W_Q)])
	pairs.sort()
	return s + "|" + ";".join(PackedStringArray(pairs))


static func meshes(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


## hidden: Callable(mi: MeshInstance3D, surface: int, arrays: Array, tri: [a,b,c]) -> bool
## (triangles the model does not draw), or an invalid Callable when every triangle is drawn.
## weightless: material names whose vertex keys leave out the skin weights (their shape,
## UVs and normals are still compared).
static func fingerprint(model: Node, hidden := Callable(), weightless: Array = []) -> Dictionary:
	var sk: Skeleton3D = model.skeleton
	var per_mat := {}
	for mi: MeshInstance3D in meshes(model.character):
		if not mi.is_visible_in_tree() or mi.mesh == null:
			continue
		var skin: Skin = mi.skin
		for s in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(s)
			var mat: Material = mi.get_surface_override_material(s)
			if mat == null:
				mat = mi.mesh.surface_get_material(s)
			var mname := _mat_name(mat)
			var V: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var N: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
			var UV: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV] if arr[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
			var UV2: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV2] if arr[Mesh.ARRAY_TEX_UV2] != null else PackedVector2Array()
			var B = arr[Mesh.ARRAY_BONES]
			var W = arr[Mesh.ARRAY_WEIGHTS]
			var I: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			if I.is_empty():
				for k in V.size():
					I.append(k)
			var per := 4
			if B != null and V.size() > 0:
				per = (B as Array).size() / V.size() if B is Array else (B as PackedInt32Array).size() / V.size()
			# model-space positions (the mesh node's transform relative to the character root)
			var xf: Transform3D = (model.character as Node3D).global_transform.affine_inverse() * mi.global_transform
			var keys := PackedStringArray()
			keys.resize(V.size())
			var nkeys := PackedStringArray()
			nkeys.resize(V.size())
			for v in V.size():
				var bn := PackedStringArray()
				var ww := PackedFloat32Array()
				if B != null and skin != null:
					for j in per:
						var bi: int = B[v * per + j]
						var name := String(skin.get_bind_name(bi)) if bi < skin.get_bind_count() else "?"
						if name == "" and bi < skin.get_bind_count():
							name = sk.get_bone_name(skin.get_bind_bone(bi))
						bn.append(name)
						ww.append(W[v * per + j])
				var uv := UV[v] if v < UV.size() else Vector2.ZERO
				keys[v] = _vkey(xf * V[v], uv, bn, ww, not (mname in weightless))
				var nn: Vector3 = (xf.basis * N[v]).normalized() if v < N.size() else Vector3.ZERO
				nkeys[v] = keys[v] + "#" + _q(nn.x, N_Q) + "," + _q(nn.y, N_Q) + "," + _q(nn.z, N_Q)
			if not per_mat.has(mname):
				per_mat[mname] = {"tris": PackedStringArray(), "normals": PackedStringArray(), "tex": _mat_tex(mat)}
			var tl: PackedStringArray = per_mat[mname]["tris"]
			var nl: PackedStringArray = per_mat[mname]["normals"]
			for t in range(0, I.size(), 3):
				var tri := [I[t], I[t + 1], I[t + 2]]
				if hidden.is_valid() and hidden.call(mi, s, arr, tri):
					continue
				var a: String = keys[tri[0]]
				var b: String = keys[tri[1]]
				var c: String = keys[tri[2]]
				# canonical rotation (winding kept): the smallest key first
				if b < a and b < c:
					tl.append(b + "/" + c + "/" + a)
				elif c < a and c < b:
					tl.append(c + "/" + a + "/" + b)
				else:
					tl.append(a + "/" + b + "/" + c)
				for k in tri:
					nl.append(nkeys[k])
			per_mat[mname]["tris"] = tl
			per_mat[mname]["normals"] = nl
	var mats := {}
	for m in per_mat:
		var tl: PackedStringArray = per_mat[m]["tris"]
		tl.sort()
		var nl: PackedStringArray = per_mat[m]["normals"]
		# one entry per distinct (vertex, normal)
		var seen := {}
		for k in nl:
			seen[k] = true
		var nu := PackedStringArray(seen.keys())
		nu.sort()
		mats[m] = {"triangles": tl.size(), "tri_hash": "\n".join(tl).sha256_text(),
				"normal_hash": "\n".join(nu).sha256_text(), "textures": per_mat[m]["tex"]}
	var bones := []
	for b in sk.get_bone_count():
		var r := sk.get_bone_rest(b)
		bones.append("%s<%s:%s,%s,%s|%s" % [sk.get_bone_name(b), sk.get_bone_name(sk.get_bone_parent(b)) if sk.get_bone_parent(b) >= 0 else "",
				_q(r.origin.x, POS_Q), _q(r.origin.y, POS_Q), _q(r.origin.z, POS_Q),
				",".join(PackedStringArray([_q(r.basis.x.x, 1e-4), _q(r.basis.x.y, 1e-4), _q(r.basis.x.z, 1e-4), _q(r.basis.y.x, 1e-4), _q(r.basis.y.y, 1e-4), _q(r.basis.y.z, 1e-4)]))])
	var anims := {}
	var ap: AnimationPlayer = model.anim
	for a_name in ap.get_animation_list():
		var a := ap.get_animation(a_name)
		var tracks := []
		for t in a.get_track_count():
			var ks := PackedStringArray()
			for k in a.track_get_key_count(t):
				var v = a.track_get_key_value(t, k)
				var s := ""
				if v is Quaternion:
					var q: Quaternion = v
					if q.w < 0.0:
						q = -q
					s = "%s,%s,%s,%s" % [_q(q.x, 1e-5), _q(q.y, 1e-5), _q(q.z, 1e-5), _q(q.w, 1e-5)]
				elif v is Vector3:
					s = "%s,%s,%s" % [_q(v.x, 1e-5), _q(v.y, 1e-5), _q(v.z, 1e-5)]
				else:
					s = str(v)
				ks.append("%s=%s" % [_q(a.track_get_key_time(t, k), 1e-4), s])
			tracks.append("%s#%d:%s" % [String(a.track_get_path(t)).get_slice(":", 1), a.track_get_type(t), "\n".join(ks).sha256_text().substr(0, 16)])
		tracks.sort()
		anims[a_name] = {"length": snappedf(a.length, 1e-4), "tracks": a.get_track_count(), "hash": "\n".join(PackedStringArray(tracks)).sha256_text()}
	return {"materials": mats, "skeleton": "\n".join(PackedStringArray(bones)).sha256_text(), "bone_count": sk.get_bone_count(),
			"animations": anims}


static func _mat_name(m: Material) -> String:
	if m == null:
		return "<none>"
	if m is ShaderMaterial:
		var sm := m as ShaderMaterial
		var src = sm.get_shader_parameter("albedo_tex")
		return "shader:" + sm.shader.resource_path.get_file() + ":" + (src.resource_path.get_file().get_basename().trim_prefix("skater_") if src else "")
	return m.resource_name


static func _tex_digest(t: Texture2D) -> String:
	if t == null:
		return ""
	var p := t.resource_path
	if p == "" or not FileAccess.file_exists(p):
		return "?"
	return FileAccess.get_md5(p).substr(0, 12)


static func _mat_tex(m: Material) -> Dictionary:
	var out := {}
	if m is StandardMaterial3D:
		var s := m as StandardMaterial3D
		out["albedo"] = _tex_digest(s.albedo_texture)
		out["normal"] = _tex_digest(s.normal_texture)
		out["rough"] = _tex_digest(s.roughness_texture)
		out["params"] = "%s|%s|%s|%s|%s" % [s.albedo_color.to_html(), snappedf(s.roughness, 0.001), snappedf(s.metallic, 0.001),
				snappedf(s.normal_scale, 0.001), str(s.rim_enabled) + str(snappedf(s.rim, 0.01)) + str(s.clearcoat_enabled)]
	elif m is ShaderMaterial:
		for p in ["albedo_tex", "normal_tex", "rough_tex"]:
			var t = (m as ShaderMaterial).get_shader_parameter(p)
			if t is Texture2D:
				out[p] = _tex_digest(t)
	return out


## Differences between two fingerprints, as readable lines ("" = none).
static func diff(a: Dictionary, b: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for m in a["materials"]:
		if not b["materials"].has(m):
			out.append("material %s missing" % m)
			continue
		var x: Dictionary = a["materials"][m]
		var y: Dictionary = b["materials"][m]
		for k in ["triangles", "tri_hash", "normal_hash"]:
			if x[k] != y[k]:
				out.append("material %s: %s %s vs %s" % [m, k, str(x[k]).substr(0, 16), str(y[k]).substr(0, 16)])
		if JSON.stringify(x["textures"]) != JSON.stringify(y["textures"]):
			out.append("material %s: textures/params %s vs %s" % [m, JSON.stringify(x["textures"]), JSON.stringify(y["textures"])])
	for m in b["materials"]:
		if not a["materials"].has(m):
			out.append("extra material %s" % m)
	for k in ["skeleton", "bone_count"]:
		if a[k] != b[k]:
			out.append("%s differs" % k)
	for c in a["animations"]:
		if not b["animations"].has(c):
			out.append("animation %s missing" % c)
		elif JSON.stringify(a["animations"][c]) != JSON.stringify(b["animations"][c]):
			out.append("animation %s differs" % c)
	return out
