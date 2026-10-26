extends Node

const TITLE := preload("res://scenes/title_screen.tscn")
var _output := "/tmp/katana-title-effects"


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-dir="):
			_output = arg.trim_prefix("--capture-dir=")
	DirAccess.make_dir_recursive_absolute(_output)
	call_deferred("_run")


func _run() -> void:
	var was_karma := CheatManager.karmageisha_active
	CheatManager.set_karmageisha(false)
	var title := TITLE.instantiate()
	add_child(title)
	await get_tree().create_timer(1.0).timeout
	await _capture("kitsune-leaves")
	var effects := title.get_node("UI/TitleArtEffects") as TitleArtEffects
	effects._set_blink_amount(1.0)
	await _capture("kitsune-blink")
	effects._set_blink_amount(0.0)
	CheatManager.set_karmageisha(true)
	var cover := title.get_node("UI/Background") as TextureRect
	cover.texture = load(PowerState.cover_path())
	await get_tree().process_frame
	await _capture("karma-geisha-leaves")
	effects._set_blink_amount(1.0)
	await _capture("karma-geisha-blink")
	CheatManager.set_karmageisha(was_karma)
	get_tree().quit()


func _capture(name: String) -> void:
	for frame in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := _output.path_join(name + ".png")
	var error := get_viewport().get_texture().get_image().save_png(path)
	if error != OK:
		push_error("Could not save %s: %s" % [path, error])
	else:
		print("CAPTURE ", path)
