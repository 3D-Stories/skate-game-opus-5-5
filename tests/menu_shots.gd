extends SceneTree
## Stills of the menus in the real game: the start screen with no saved game and with one
## (on a test save of its own, never the player's), Controls, "start a new game?", pause and
## the end screen. Needs a display (not --headless).
##
##   godot --path . --resolution 1920x1080 -s tests/menu_shots.gd [-- --out=evidence/menus]

const SAVE := "user://test_menu_shots_progress.cfg"

var main: Node
var out := "/tmp/skate-work/menus"


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.get_slice("=", 1)
	DirAccess.make_dir_recursive_absolute(out)
	Progress.save_path = SAVE
	Progress.use_in_tests = true
	Progress.clear()
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func frames(n: int) -> void:
	for i in n:
		await process_frame


func shot(name: String) -> void:
	await frames(12)
	var img := root.get_texture().get_image()
	img.save_jpg(out.path_join(name + ".jpg"), 0.9)
	print("[shots] %s" % out.path_join(name + ".jpg"))


func _run() -> void:
	await frames(30)
	await shot("start_no_save")
	main.menus.show_controls()
	await shot("controls")
	# a saved game: three of the Warehouse's goals done and a best score
	for g in ["score", "skate", "tape"]:
		Progress.mark_done("warehouse", g)
	Progress.record_score("warehouse", 41250)
	Progress.started("warehouse")
	main._make_goals()
	main.hud.set_goals(main.goals)
	main._show_start()
	await shot("start_saved")
	main.menus.show_confirm()
	await shot("confirm_new_game")
	main.continue_game()
	await frames(30)
	main.get_tree().paused = true
	main.menus.show_pause(main.goals, main.score)
	await shot("pause")
	main.menus.hide_all()
	main.get_tree().paused = false
	main.time_left = 0.2
	await frames(90)
	await shot("end")
	Progress.clear()
	quit()
