extends SceneTree
## Short scripted showcase for the evidence video (Movie Maker, real rendering):
## a fakie landing, coasting fakie (looking back toward travel), pushing (turns round),
## then ragdoll bails: halfway up the east quarterpipe (the body tumbles down the transition,
## comes to rest, gets up with the board and rides off), a fast one on the flat (slam, slide,
## blood) and one thrown backwards that ends face down (the push-up getup).
##
##   godot --path . --write-movie /tmp/show/f.png --fixed-fps 30 --resolution 1920x1080 -s tests/showcase.gd

var main: Node
var sk: Node


func _initialize() -> void:
	_run.call_deferred()


func step(n := 1) -> void:
	for i in n:
		await process_frame


func until(cond: Callable, max_frames: int) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await step(1)
	return cond.call()


func key(k: int, down: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = k
	e.physical_keycode = k
	e.pressed = down
	Input.parse_input_event(e)


func tap(k: int, hold_frames := 2) -> void:
	key(k, true)
	await step(hold_frames)
	key(k, false)
	await step(2)


func _run() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await step(20)
	await tap(KEY_ENTER)
	await step(3)
	sk = main.skater
	# 1. ollie 180 -> fakie, coast, push (turns round), ride on
	sk.spawn(Vector3(0, 0, -20), Vector3(0, 0, -1), 6.5)
	main.cam.snap()
	await step(20)
	await tap(KEY_SPACE)
	await until(func(): return sk.state == sk.AIR, 10)
	key(KEY_E, true)
	await step(13)            # a half turn at 30 fps
	key(KEY_E, false)
	await until(func(): return sk.state == sk.GROUND, 60)
	await step(45)
	key(KEY_W, true)
	await step(50)
	key(KEY_W, false)
	await step(20)
	# 2. bail halfway up the east quarterpipe, slide down, get up, ride off
	sk.spawn(Vector3(12.0, 0.0, -20.0), Vector3(1, 0, 0), 7.2)
	main.cam.snap()
	await until(func(): return sk.state == sk.GROUND and sk.global_position.y > 1.3, 90)
	sk._bail("showcase")
	await until(func(): return sk.getup_t >= 0.0, 300)
	print("[showcase] getup clip: ", sk.getup_clip)
	await until(func(): return sk.state == sk.GROUND, 300)
	await step(15)
	key(KEY_W, true)
	await step(45)
	key(KEY_W, false)
	await step(20)
	# 3. a fast bail on the flat (the clear lane on the west side): the slam, the slide and the blood
	main.level.clear_blood()
	sk.spawn(Vector3(-11.0, 0.0, 13.0), Vector3(0, 0, -1), 10.0)
	main.cam.snap()
	await step(12)
	sk._bail("showcase")
	await until(func(): return sk.state == sk.GROUND, 300)
	await step(30)
	# 4. thrown backwards: the body ends face down and gets up from a push-up
	main.level.clear_blood()
	sk.spawn(Vector3(-11.0, 0.0, 13.0), Vector3(0, 0, -1), 7.0)
	main.cam.snap()
	await step(12)
	sk.bail_tumble = -1.0
	sk._bail("showcase")
	sk.bail_tumble = 1.0
	print("[showcase] backwards bail")
	await until(func(): return sk.getup_t >= 0.0, 300)
	print("[showcase] getup clip: ", sk.getup_clip)
	await until(func(): return sk.state == sk.GROUND, 300)
	await step(30)
	quit()
