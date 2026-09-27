class_name Progress
extends RefCounted
## The saved game behind the start screen's "Resume game": each level's completed goals and
## best score, and the level played last. A goal stays done once it is done, as in THPS's
## career mode, so every run works on the goals still open. "Start new game" clears it.
## Saved in user://progress.cfg (in the browser, user:// is kept in IndexedDB).
## Scripted runs (--autopilot, ?autopilot, benchmarks), headless test scripts and
## --no-progress neither read nor write it, so they never touch a player's save.

const SAVE_PATH := "user://progress.cfg"
## Where the game is saved (tests point this at their own file).
static var save_path := SAVE_PATH
## Tests of the saved game itself set this: then a test script reads and writes save_path.
static var use_in_tests := false


static func enabled(autopilot_mode := "") -> bool:
	if autopilot_mode != "" or "--no-progress" in OS.get_cmdline_user_args():
		return false
	return use_in_tests or not SkaterOutfit.running_test()


static func _load() -> ConfigFile:
	var cf := ConfigFile.new()
	cf.load(save_path)
	return cf


static func _section(level_id: String) -> String:
	return "level:" + level_id


static func exists() -> bool:
	return FileAccess.file_exists(save_path)


static func last_level() -> String:
	return String(_load().get_value("game", "last_level", ""))


static func done_goals(level_id: String) -> Array:
	return Array(_load().get_value(_section(level_id), "goals", []))


static func best_score(level_id: String) -> int:
	return int(_load().get_value(_section(level_id), "best", 0))


static func summary() -> Dictionary:
	## How much the save holds: completed goals over all levels, and the levels played.
	var cf := _load()
	var goals := 0
	var levels := 0
	for s in cf.get_sections():
		if String(s).begins_with("level:"):
			levels += 1
			goals += Array(cf.get_value(s, "goals", [])).size()
	return {"goals": goals, "levels": levels}


static func started(level_id: String) -> void:
	## A run began: this is the level "Resume game" returns to (and the save now exists).
	var cf := _load()
	cf.set_value("game", "last_level", level_id)
	if not cf.has_section_key(_section(level_id), "goals"):
		cf.set_value(_section(level_id), "goals", [])
	cf.save(save_path)


static func mark_done(level_id: String, goal_id: String) -> void:
	var cf := _load()
	var g := Array(cf.get_value(_section(level_id), "goals", []))
	if goal_id in g:
		return
	g.append(goal_id)
	cf.set_value(_section(level_id), "goals", g)
	cf.save(save_path)


static func record_score(level_id: String, points: int) -> void:
	var cf := _load()
	if points > int(cf.get_value(_section(level_id), "best", 0)):
		cf.set_value(_section(level_id), "best", points)
		cf.save(save_path)


static func clear() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))
