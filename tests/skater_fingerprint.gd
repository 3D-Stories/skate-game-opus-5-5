extends SceneTree
## Writes the fingerprint (tests/lib/skater_fp.gd) of the skater the game builds by default.
## Run once on the original game (before the character builder) to record the baseline that
## tests/test_builder.gd compares the builder's default selection with:
##   godot --headless --path . -s tests/skater_fingerprint.gd -- --out=tests/data/skater_baseline.json
## With --weightless=Hoodie,Jeans,... those materials' vertices are compared without their
## skin weights (tests/data/skater_baseline_weightless.json, recorded the same way on the
## original commit: the character builder re-fits those garments' weights, see README).

const FP := preload("res://tests/lib/skater_fp.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var out := "res://tests/data/skater_fingerprint.json"
	var weightless: Array = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.get_slice("=", 1)
		elif a.begins_with("--weightless="):
			weightless = Array(a.get_slice("=", 1).split(","))
	var model: Node3D = load("res://scripts/skater/skater_model.gd").new()
	root.add_child(model)
	await process_frame
	var hidden := Callable()
	if model.has_method("is_triangle_hidden"):
		hidden = Callable(model, "is_triangle_hidden")
	var fp := FP.fingerprint(model, hidden, weightless)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out.get_base_dir()) if out.begins_with("res://") else out.get_base_dir())
	var f := FileAccess.open(out, FileAccess.WRITE)
	f.store_string(JSON.stringify(fp, " ", true))
	f.close()
	var tris := 0
	for m in fp["materials"]:
		tris += int(fp["materials"][m]["triangles"])
	print("[fingerprint] %d materials, %d visible triangles, %d bones, %d clips -> %s" % [fp["materials"].size(), tris, fp["bone_count"], fp["animations"].size(), out])
	quit()
