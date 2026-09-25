class_name Rail
extends RefCounted
## A grindable line from park_data.json (rails, ledges, copings, pipes, rafters).

var name := ""
var kind := "metal"      # metal | wood | concrete  (sound + sparks)
var tag := ""            # rail | ledge | coping | pipe | rafter | catwalk
var points := PackedVector3Array()
var cum := PackedFloat32Array()   # arc length at each point
var length := 0.0


static func from_dict(d: Dictionary) -> Rail:
	var r := Rail.new()
	r.name = d.get("name", "")
	r.kind = d.get("kind", "metal")
	r.tag = d.get("tag", "")
	for p in d["points"]:
		r.points.append(Vector3(p[0], p[1], p[2]))
	r._measure()
	return r


func _measure() -> void:
	cum.resize(points.size())
	var acc := 0.0
	cum[0] = 0.0
	for i in range(1, points.size()):
		acc += points[i].distance_to(points[i - 1])
		cum[i] = acc
	length = acc


## Closest point on the rail. Returns {s, point, dir, dist}.
func closest(p: Vector3) -> Dictionary:
	var best := {"dist": INF}
	for i in range(points.size() - 1):
		var a := points[i]
		var b := points[i + 1]
		var ab := b - a
		var l2 := ab.length_squared()
		var t := 0.0 if l2 < 1e-8 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
		var q := a + ab * t
		var d := p.distance_to(q)
		if d < best["dist"]:
			best = {"dist": d, "point": q, "dir": ab.normalized(), "s": cum[i] + sqrt(l2) * t, "seg": i}
	return best


func point_at(s: float) -> Vector3:
	s = clampf(s, 0.0, length)
	for i in range(points.size() - 1):
		if s <= cum[i + 1] or i == points.size() - 2:
			var seg_len := cum[i + 1] - cum[i]
			var t := 0.0 if seg_len < 1e-6 else (s - cum[i]) / seg_len
			return points[i].lerp(points[i + 1], clampf(t, 0.0, 1.0))
	return points[points.size() - 1]


func dir_at(s: float) -> Vector3:
	for i in range(points.size() - 1):
		if s <= cum[i + 1] or i == points.size() - 2:
			return (points[i + 1] - points[i]).normalized()
	return Vector3.FORWARD
