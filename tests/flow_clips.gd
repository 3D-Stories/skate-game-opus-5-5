extends "res://tests/test_flow.gd"
## tests/test_flow.gd unchanged (same checks, same tests/results/flow.txt), plus one line
## at exit with the skater model's clip bookkeeping for the whole flow run:
##   [flow] clips played: { "idle": 2, ... }
## Used by tests/test_clips_in_game.gd to learn which clips the flow test's real game
## code paths played (it bails, grinds, manuals...).
##   godot --headless --path . -s tests/flow_clips.gd

var _played = null     # the model's own 'played' Dictionary (shared reference, outlives the node)


func _initialize() -> void:
	super._initialize()
	_grab_played.call_deferred()


func _grab_played() -> void:
	_played = main.skater.model.played


func _finalize() -> void:
	print("[flow] clips played: %s" % JSON.stringify(_played if _played != null else {}))
