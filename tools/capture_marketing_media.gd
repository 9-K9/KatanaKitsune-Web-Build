extends Node2D

## Deterministic marketing capture runner. It builds one requested biome, takes
## two clean screenshots, drives the real player through a short combat loop,
## and exits. Pair it with Godot's --write-movie option for reproducible clips.

class CaptureInput extends PlayerInput:
	var elapsed := 0.0
	var _previous_phase := -1

	func update(delta: float) -> void:
		elapsed += delta

	func vector() -> Vector2:
		var phase := int(elapsed / 2.0) % 4
		return [Vector2(0.8, 0.35), Vector2(-0.2, 0.9),
				Vector2(-0.8, -0.25), Vector2(0.35, -0.9)][phase].normalized()

	func pressed(action: String) -> bool:
		if action == "Run":
			return int(elapsed) % 6 < 2
		if action == "Attack":
			return fmod(elapsed, 2.4) > 1.75 and fmod(elapsed, 2.4) < 2.05
		return false

	func just_pressed(action: String) -> bool:
		var phase := int(elapsed * 10.0)
		var changed := phase != _previous_phase
		_previous_phase = phase
		if not changed:
			return false
		if action == "Katana":
			return phase == 8
		if action == "Attack":
			return phase > 14 and phase % 24 == 18
		if action == "Dodge":
			return phase > 20 and phase % 55 == 27
		return false

	func just_released(_action: String) -> bool:
		return false


const BIOME_NAMES := [
	"sakura-gardens",
	"bamboo-woodland",
	"abandoned-shrines",
	"desert-ruins",
	"frozen-pass",
]

var _theme := 0
var _duration := 12.0
var _capture_dir := ""
var _maze: Node2D


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--theme="):
			_theme = clampi(int(arg.trim_prefix("--theme=")), 0, BIOME_NAMES.size() - 1)
		elif arg.begins_with("--duration="):
			_duration = maxf(float(arg.trim_prefix("--duration=")), 4.0)
		elif arg.begins_with("--capture-dir="):
			_capture_dir = arg.trim_prefix("--capture-dir=")
	call_deferred("_run")


func _run() -> void:
	Roster.clear()
	Roster.join(-1, 0)
	for companion in 3:
		Roster.add_bot()
	Score.begin_run()
	_maze = load("res://scenes/world/mazeDemo.tscn").instantiate()
	_maze.maze_seed = 9109 + _theme * 137
	_maze.level_theme = _theme
	_maze.outdoor_weather = -1
	_maze.weather_intensity = 0.65
	_maze.stream_world = false
	_maze.show_roofs = false
	get_tree().root.add_child(_maze)
	get_tree().current_scene = _maze
	while _maze._building or _maze._player == null:
		await get_tree().process_frame

	for overlay_name in ["FloorLayer", "ClearLayer"]:
		var layer := _maze.get_node_or_null(overlay_name) as CanvasLayer
		if layer != null:
			layer.visible = false
	var camera := get_viewport().get_camera_2d()
	if camera != null:
		camera.position_smoothing_enabled = true
		camera.position_smoothing_speed = 4.0
	_maze._player.input = CaptureInput.new()
	_maze._player.input.bind_body(_maze._player)
	_stage_encounter()

	await get_tree().create_timer(1.0).timeout
	await _capture("%s-overview" % BIOME_NAMES[_theme])
	await get_tree().create_timer(4.5).timeout
	await _capture("%s-action" % BIOME_NAMES[_theme])
	await get_tree().create_timer(1.25).timeout
	_stage_interior()
	await get_tree().create_timer(1.0).timeout
	await _capture("%s-interior" % BIOME_NAMES[_theme])
	_activate_powerups()
	await get_tree().create_timer(0.75).timeout
	await _capture("%s-powerups" % BIOME_NAMES[_theme])
	if _theme == 0:
		get_tree().paused = true
		await get_tree().create_timer(0.5, true).timeout
		await _capture("pause-menu")
		get_tree().paused = false
	await get_tree().create_timer(maxf(_duration - 9.0, 0.1)).timeout
	_maze.queue_free()
	await get_tree().process_frame
	Roster.clear()
	get_tree().quit()


func _stage_encounter() -> void:
	## The generated start room is deliberately safe. Pull a small sample of the
	## floor's real enemies into its open centre so short marketing clips show
	## the four-player combat loop instead of spending their runtime travelling.
	var offsets: Array[Vector2] = [
		Vector2(280.0, -80.0),
		Vector2(-260.0, 110.0),
		Vector2(120.0, 230.0),
		Vector2(-100.0, -240.0),
	]
	var enemies := get_tree().get_nodes_in_group("enemy")
	for i in mini(offsets.size(), enemies.size()):
		var enemy := enemies[i] as Node2D
		if enemy != null:
			enemy.global_position = _maze._player.global_position + offsets[i]


func _stage_interior() -> void:
	var centre := Vector2.ZERO
	var found := false
	for cell in _maze._rooms:
		if _maze._ext != null and _maze._ext.is_building(cell):
			centre = _maze._room_centre(cell)
			found = true
			break
	if not found:
		return
	for i in _maze._players.size():
		var angle := TAU * float(i) / float(maxi(_maze._players.size(), 1))
		_maze._players[i].global_position = centre + Vector2(cos(angle), sin(angle) * 0.55) * 70.0
	var enemies := get_tree().get_nodes_in_group("enemy")
	var offsets: Array[Vector2] = [Vector2(190, -40), Vector2(-180, 70), Vector2(60, 160)]
	for i in mini(offsets.size(), enemies.size()):
		var enemy := enemies[i] as Node2D
		if enemy != null:
			enemy.global_position = centre + offsets[i]


func _activate_powerups() -> void:
	## Layer two readable timed effects: the gold invincibility pulse and the
	## red Might icon/timer in each player's hotbar.
	for body in _maze._players:
		if body.has_method("use_scroll"):
			body.use_scroll(Scroll.Kind.INVINCIBLE)
			body.use_scroll(Scroll.Kind.ATTACK)


func _capture(name: String) -> void:
	if _capture_dir.is_empty():
		return
	for frame in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := _capture_dir.path_join(name + ".png")
	var error := get_viewport().get_texture().get_image().save_png(path)
	if error != OK:
		push_error("Could not save capture %s: %s" % [path, error])
	else:
		print("CAPTURE ", path)
