extends RefCounted
## The two-minute demo route through Eastside Baths (Godot coordinates, -Z = north).
## (Placeholder while the level is built: just rolls down the bleacher bank.)

const R := preload("res://scripts/game/autopilot_route.gd")


static func route() -> Array:
	var r: Array = []
	r.append(R.go(Vector3(-5.0, 0.0, 1.0), "down the bleacher bank", {"timeout": 8.0}))
	return r
