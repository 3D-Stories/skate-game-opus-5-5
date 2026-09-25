extends Node3D
## Development viewer: shows the skater with lighting and steps through every clip.
## Pass a clip name with the "clip" meta (or set CLIPS) to look at one animation.

@export var clips: PackedStringArray = ["idle", "ride", "push", "ollie", "kickflip", "heelflip", "shoveit",
		"indy", "melon", "nosegrab", "tailgrab", "vert_air", "grind_5050", "boardslide", "manual",
		"nose_manual", "land", "bail", "special"]
@export var orbit_speed := 0.25
@export var cam_distance := 3.2
@export var cam_height := 1.2
@export var hold_clip := ""

var _i := 0
var _t := 0.0
var _ang := 0.6

@onready var model: SkaterModel = $SkaterModel
@onready var cam: Camera3D = $Camera3D


func _ready() -> void:
	if hold_clip != "":
		model.play(hold_clip, 0.0)
	else:
		model.play(clips[0], 0.0)


func _process(delta: float) -> void:
	_ang += delta * orbit_speed
	var target := Vector3(0, 0.9, 0)
	cam.global_position = target + Vector3(sin(_ang), 0, cos(_ang)) * cam_distance + Vector3(0, cam_height - 0.9, 0)
	cam.look_at(target)
	if hold_clip != "":
		return
	_t += delta
	var l: float = max(1.2, model.clip_length(clips[_i]))
	if _t > l + 0.3:
		_t = 0.0
		_i = (_i + 1) % clips.size()
		model.restart(clips[_i], 0.15)
