class_name Tricks
extends RefCounted
## The trick list (THPS-style button + direction mapping) and point values.
## Directions: "" (none), "up", "down", "left", "right".

const FLIPS := {
	"": {"name": "Kickflip", "points": 100, "anim": "kickflip"},
	"left": {"name": "Kickflip", "points": 100, "anim": "kickflip"},
	"right": {"name": "Heelflip", "points": 100, "anim": "heelflip"},
	"down": {"name": "Pop Shove-It", "points": 100, "anim": "shoveit"},
	"up": {"name": "360 Flip", "points": 500, "anim": "treflip"},
}
const GRABS := {
	"": {"name": "Indy", "points": 200, "anim": "indy"},
	"right": {"name": "Indy", "points": 200, "anim": "indy"},
	"left": {"name": "Melon", "points": 200, "anim": "melon"},
	"up": {"name": "Nosegrab", "points": 250, "anim": "nosegrab"},
	"down": {"name": "Tailgrab", "points": 250, "anim": "tailgrab"},
}
const GRAB_HOLD_RATE := 120.0          # extra points per second while holding a grab
const GRINDS := {
	"": {"name": "50-50", "points": 100, "anim": "grind_5050", "rate": 150.0},
	"up": {"name": "50-50", "points": 100, "anim": "grind_5050", "rate": 150.0},
	"down": {"name": "50-50", "points": 100, "anim": "grind_5050", "rate": 150.0},
	"left": {"name": "Boardslide", "points": 150, "anim": "boardslide", "rate": 150.0},
	"right": {"name": "Boardslide", "points": 150, "anim": "boardslide", "rate": 150.0},
}
const MANUAL := {"name": "Manual", "points": 100, "anim": "manual", "rate": 120.0}
const NOSE_MANUAL := {"name": "Nose Manual", "points": 150, "anim": "nose_manual", "rate": 120.0}
const SPECIAL := {"name": "Tiger Claw Tre", "points": 3000, "anim": "special"}
## Spin bonuses, counted per air in 180 degree steps.
const SPINS := {180: 100, 360: 250, 540: 500, 720: 800, 900: 1200, 1080: 1600}
## Repeats of the same trick inside one combo are worth less (THPS degradation).
const REPEAT_FACTORS := [1.0, 0.75, 0.5, 0.25, 0.1]
const RAFTER_TAG := "rafter"


static func spin_points(deg: float) -> int:
	var steps := int(floor((absf(deg) + 25.0) / 180.0))
	if steps <= 0:
		return 0
	var key := mini(steps * 180, 1080)
	return SPINS[key]


static func spin_name(deg: float) -> String:
	var steps := int(floor((absf(deg) + 25.0) / 180.0))
	if steps <= 0:
		return ""
	return ("FS " if deg > 0.0 else "BS ") + str(steps * 180)


static func category(trick_name: String) -> String:
	## "flip", "grab", "grind", "manual", "spin" or "special" for a trick name.
	for d in [FLIPS, GRABS, GRINDS]:
		for k in d:
			if d[k]["name"] == trick_name:
				return "flip" if d == FLIPS else ("grab" if d == GRABS else "grind")
	if trick_name == MANUAL["name"] or trick_name == NOSE_MANUAL["name"]:
		return "manual"
	if trick_name == SPECIAL["name"]:
		return "special"
	return "spin" if trick_name.begins_with("FS ") or trick_name.begins_with("BS ") else ""


static func all_tricks() -> Array:
	## Rows for the README / start screen: [name, points, input].
	return [
		["Kickflip", 100, "Flip + Left (or no direction)"],
		["Heelflip", 100, "Flip + Right"],
		["Pop Shove-It", 100, "Flip + Down"],
		["360 Flip", 500, "Flip + Up"],
		["Indy", "200 + 120/s held", "Grab + Right (or no direction)"],
		["Melon", "200 + 120/s held", "Grab + Left"],
		["Nosegrab", "250 + 120/s held", "Grab + Up"],
		["Tailgrab", "250 + 120/s held", "Grab + Down"],
		["50-50", "100 + 150/s", "Grind near a rail/ledge/coping"],
		["Boardslide", "150 + 150/s", "Grind + Left/Right"],
		["Manual", "100 + 120/s", "Up, Down"],
		["Nose Manual", "150 + 120/s", "Down, Up"],
		["Spins", "180: 100, 360: 250, 540: 500, 720: 800", "Left/Right or spin buttons in the air"],
		["Tiger Claw Tre (special)", 3000, "Special meter full: Left, Right + Flip"],
	]
