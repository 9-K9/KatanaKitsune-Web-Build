extends Node

## Deterministic, low-memory coverage for every approved outdoor effect.
## It builds a 2x2 synthetic exterior instead of a procedural match.

var _checks := 0
var _failed := 0


class WeatherHost extends Node2D:
	var _rooms: Dictionary = {}


func _ready() -> void:
	call_deferred("_run")


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failed += 1
		push_error(message)


func _exterior(biome_id: int) -> MazeExterior:
	var host := WeatherHost.new()
	add_child(host)
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var exterior := MazeExterior.new(host, rng, Vector2i(2, 2), Vector2(128, 64))
	exterior.biome = ExteriorBiome.definition(biome_id)
	for y in 2:
		for x in 2:
			var cell := Vector2i(x, y)
			exterior.kind[cell] = MazeExterior.Kind.GARDEN
			var room := Node2D.new()
			room.position = Vector2((x - y) * 64, (x + y) * 32)
			host.add_child(room)
			host._rooms[cell] = room
	return exterior


func _exercise(biome_id: int, effect: int, label: String) -> void:
	var exterior := _exterior(biome_id)
	_check(exterior.biome.weather_available(effect), label + " asset is approved and loadable")
	var weather := OutdoorWeather.new()
	add_child(weather)
	weather.setup(exterior, 24680, effect, 0.75)
	_check(weather.process_mode == Node.PROCESS_MODE_PAUSABLE,
			label + " follows gameplay pause/resume")
	_check(weather._emitters.has(effect), label + " emitter is created")
	var view := Rect2(-256, -192, 512, 384)
	weather.update_weather(0.1, [view])
	weather.update_weather(6.0, [view])
	_check(weather.current == effect, label + " deterministic force selects effect")
	_check(is_equal_approx(weather.intensity, 0.75), label + " transition reaches configured strength")
	var emitter := weather._emitters.get(effect) as GPUParticles2D
	_check(emitter != null and emitter.emitting, label + " particles emit over a camera view")
	if emitter != null:
		var material := emitter.process_material as ShaderMaterial
		_check(is_equal_approx(float(material.get_shader_parameter("opacity")), 0.75),
				label + " shader receives transition opacity")
	weather.update_weather(0.1, [])
	_check(not emitter.emitting, label + " stops when no camera view is active")
	weather.stop()
	weather.queue_free()
	exterior._maze.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


func _run() -> void:
	await _exercise(ExteriorBiome.Id.SAKURA, ExteriorBiome.Weather.PETALS, "petals")
	await _exercise(ExteriorBiome.Id.SAKURA, ExteriorBiome.Weather.RAIN, "rain")
	await _exercise(ExteriorBiome.Id.SNOW, ExteriorBiome.Weather.SNOWFALL, "snow")
	await _exercise(ExteriorBiome.Id.DESERT, ExteriorBiome.Weather.SANDSTORM, "sandstorm")
	# Let RenderingServer release the four synthetic particle resources before
	# the process exits, keeping leak diagnostics meaningful.
	await get_tree().process_frame
	await get_tree().process_frame
	print("Weather: %d checks, %d failures" % [_checks, _failed])
	get_tree().quit(1 if _failed else 0)
