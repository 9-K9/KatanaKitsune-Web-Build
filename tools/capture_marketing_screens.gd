extends Node

var _capture_dir := ""


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-dir="):
			_capture_dir = arg.trim_prefix("--capture-dir=")
	call_deferred("_run")


func _run() -> void:
	await _screen("res://scenes/title_screen.tscn", "title-screen")
	await _screen("res://scenes/menuscreens/characterSelect.tscn", "character-select")
	get_tree().quit()


func _screen(scene_path: String, capture_name: String) -> void:
	var screen := (load(scene_path) as PackedScene).instantiate()
	get_tree().root.add_child(screen)
	for frame in 12:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := _capture_dir.path_join(capture_name + ".png")
	var error := get_viewport().get_texture().get_image().save_png(path)
	if error != OK:
		push_error("Could not save capture %s: %s" % [path, error])
	else:
		print("CAPTURE ", path)
	screen.queue_free()
	await get_tree().process_frame
