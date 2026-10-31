extends Node

## Runtime audio library for the mastered Katana Kitsune sound set.
## Event families are inferred from numbered filenames, so adding another
## variation to the folder automatically makes it eligible for playback.

const AUDIO_ROOT := "res://assets/audio/generated/final"
const MUSIC_FADE := 0.8
const AMBIENCE_FADE := 1.2
const POSITIONAL_MAX_DISTANCE := 1300.0
const SETTINGS_PATH := "user://audio.cfg"
const DEFAULT_OUTPUT_DEVICE := "Default"
const BUS_MASTER := &"Master"
const BUS_MUSIC := &"Music"
const BUS_VOICE := &"Voice"
const BUS_SFX := &"SFX"
const VOLUME_KEYS: Array[StringName] = [BUS_MASTER, BUS_MUSIC, BUS_VOICE, BUS_SFX]
## Preserve the mix users already hear until they choose a quieter setting.
const DEFAULT_VOLUME := 1.0

var _families: Dictionary = {}
var _exact: Dictionary = {}
var _music: AudioStreamPlayer
var _ambience: AudioStreamPlayer
var _status_loop: AudioStreamPlayer
var _ui_players: Array[AudioStreamPlayer] = []
var _last_frames: Dictionary = {}
var _step_cooldown: Dictionary = {}
var _voice_cooldown: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _web_audio_unlocked: bool = false
var _requested_music: Dictionary = {}
var _requested_ambience: Dictionary = {}
var _preferred_output_device: String = DEFAULT_OUTPUT_DEVICE


func _ready() -> void:
	_rng.randomize()
	_ensure_buses()
	_load_settings()
	_index_library()
	_music = _loop_player("Music", BUS_MUSIC)
	_ambience = _loop_player("Ambience", BUS_MUSIC)
	_status_loop = _loop_player("StatusLoop", BUS_SFX)
	for i in 8:
		var player := AudioStreamPlayer.new()
		player.name = "UI_%02d" % i
		player.bus = BUS_SFX
		add_child(player)
		_ui_players.append(player)
	get_tree().node_added.connect(_on_node_added)
	get_tree().scene_changed.connect(_on_scene_changed)
	call_deferred("_wire_tree", get_tree().root)
	call_deferred("_on_scene_changed")
	if OS.get_name() != "Web":
		_web_audio_unlocked = true


func _input(event: InputEvent) -> void:
	## Browsers suspend WebAudio until a real key/pointer gesture. Music is
	## requested while the title scene is still loading, so retry the active
	## loops just after the first gesture instead of leaving a silent session.
	if _web_audio_unlocked or not (event is InputEventKey \
			or event is InputEventMouseButton \
			or event is InputEventJoypadButton \
			or event is InputEventScreenTouch):
		return
	if not event.is_pressed():
		return
	_web_audio_unlocked = true
	get_tree().create_timer(0.1, true, false, true).timeout.connect(_restart_web_audio)


func _process(delta: float) -> void:
	for id in _step_cooldown.keys():
		_step_cooldown[id] = maxf(float(_step_cooldown[id]) - delta, 0.0)
	for id in _voice_cooldown.keys():
		_voice_cooldown[id] = maxf(float(_voice_cooldown[id]) - delta, 0.0)
	_track_footsteps("player")
	_track_footsteps("enemy")
	_update_status_loop()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		play("ui_nav_back", -3.0)


func _index_library() -> void:
	# ResourceLoader normalizes imported `.remap` entries in exported PCKs,
	# unlike a raw DirAccess scan, while returning the same filenames in-editor.
	for filename in ResourceLoader.list_directory(AUDIO_ROOT):
		if not filename.get_extension().to_lower() in ["wav", "ogg"]:
			continue
		var stem := filename.get_basename()
		var path := AUDIO_ROOT.path_join(filename)
		_exact[stem] = path
		var family := stem
		var suffix := RegEx.create_from_string("_[0-9]+$").search(stem)
		if suffix != null:
			family = stem.left(suffix.get_start())
		if not _families.has(family):
			_families[family] = []
		_families[family].append(path)


func has_event(event: String) -> bool:
	return _exact.has(event) or _families.has(event)


func play(event: String, volume_db: float = 0.0, pitch_variance: float = 0.04) -> void:
	var path := _pick(event)
	if path.is_empty():
		return
	var player := _free_ui_player()
	player.stream = load(path)
	player.bus = _bus_for(event)
	player.volume_db = volume_db
	player.pitch_scale = _rng.randf_range(1.0 - pitch_variance, 1.0 + pitch_variance)
	player.play()


func play_at(event: String, position: Vector2, volume_db: float = 0.0,
		pitch_variance: float = 0.05) -> void:
	var path := _pick(event)
	if path.is_empty():
		return
	var player := AudioStreamPlayer2D.new()
	player.stream = load(path)
	player.bus = _bus_for(event)
	player.global_position = position
	player.volume_db = volume_db
	player.pitch_scale = _rng.randf_range(1.0 - pitch_variance, 1.0 + pitch_variance)
	player.max_distance = POSITIONAL_MAX_DISTANCE
	player.attenuation = 1.2
	get_tree().current_scene.add_child(player)
	player.finished.connect(player.queue_free)
	player.play()


func play_for(event: String, source: Node, volume_db: float = 0.0) -> void:
	if source is Node2D:
		play_at(event, (source as Node2D).global_position, volume_db)
	else:
		play(event, volume_db)


func play_music(event: String, volume_db: float = -5.0) -> void:
	_requested_music = {"event": event, "volume_db": volume_db}
	_crossfade_loop(_music, event, volume_db, MUSIC_FADE)


func play_ambience(event: String, volume_db: float = -9.0) -> void:
	_requested_ambience = {"event": event, "volume_db": volume_db}
	_crossfade_loop(_ambience, event, volume_db, AMBIENCE_FADE)


func stop_ambience() -> void:
	_requested_ambience.clear()
	_fade_out(_ambience, AMBIENCE_FADE)


func _restart_web_audio() -> void:
	_restart_requested_loop(_music, _requested_music)
	_restart_requested_loop(_ambience, _requested_ambience)


func _restart_requested_loop(player: AudioStreamPlayer, request: Dictionary) -> void:
	if request.is_empty():
		return
	player.stop()
	player.stream = null
	_crossfade_loop(player, String(request["event"]), float(request["volume_db"]), 0.15)


func _update_status_loop() -> void:
	var low_health := false
	for body in get_tree().get_nodes_in_group("player"):
		if body.get("is_dead") == true:
			continue
		var health = body.get("health")
		var maximum = body.get("max_health")
		if health != null and maximum != null and float(maximum) > 0.0 \
				and float(health) / float(maximum) <= 0.25:
			low_health = true
			break
	if low_health and not _status_loop.playing:
		_crossfade_loop(_status_loop, "ui_low_health_loop", -13.0, 0.25)
	elif not low_health and _status_loop.playing:
		_fade_out(_status_loop, 0.35)


func enemy_event(enemy: Node, action: String) -> void:
	var source := enemy.scene_file_path.to_lower()
	var code := ""
	for entry in [
		["jorogumo", "jor"], ["kappa", "kap"], ["karasu", "kar"],
		["kasha", "kas"], ["ninja", "nin"], ["oni", "oni"],
		["tengu", "ten"], ["yokai", "yok"], ["yuki", "yuk"]]:
		if source.contains(entry[0]):
			code = entry[1]
			break
	if code.is_empty():
		play_for("sfx_enemy_defeat" if action == "death" else "sfx_enemy_" + action, enemy)
		return
	var family := "sfx_enemy_%s_%s" % [code, "hurtdeath" if action in ["hurt", "death"] else action]
	play_for(family, enemy)


func _pick(event: String) -> String:
	if _exact.has(event):
		return _exact[event]
	var choices: Array = _families.get(event, [])
	if choices.is_empty():
		push_warning("Unknown audio event: %s" % event)
		return ""
	return choices[_rng.randi_range(0, choices.size() - 1)]


func _free_ui_player() -> AudioStreamPlayer:
	for player in _ui_players:
		if not player.playing:
			return player
	return _ui_players[_rng.randi_range(0, _ui_players.size() - 1)]


func _loop_player(player_name: String, bus: StringName) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.name = player_name
	player.bus = bus
	add_child(player)
	return player


func _bus_for(event: String) -> StringName:
	return BUS_VOICE if event.begins_with("vox_") else BUS_SFX


## User-facing 0..1 volume values. Buses keep the preference independent from
## each event's authored relative dB level and update sounds already playing.
func volume(bus: StringName) -> float:
	var index := AudioServer.get_bus_index(bus)
	if index < 0:
		return DEFAULT_VOLUME
	return 0.0 if AudioServer.is_bus_mute(index) else db_to_linear(AudioServer.get_bus_volume_db(index))


func set_volume(bus: StringName, value: float, save: bool = true) -> void:
	if not bus in VOLUME_KEYS:
		return
	var index := AudioServer.get_bus_index(bus)
	if index < 0:
		return
	var level := clampf(value, 0.0, 1.0)
	AudioServer.set_bus_mute(index, level <= 0.001)
	AudioServer.set_bus_volume_db(index, linear_to_db(maxf(level, 0.001)))
	if save:
		_save_settings()


## Desktop builds may offer an explicit device override. "Default" deliberately
## remains the recommended choice because it follows headset/speaker changes
## made in the operating system. Web builds generally expose only that route.
func output_devices() -> PackedStringArray:
	var devices := AudioServer.get_output_device_list()
	if DEFAULT_OUTPUT_DEVICE not in devices:
		devices.insert(0, DEFAULT_OUTPUT_DEVICE)
	return devices


func preferred_output_device() -> String:
	return _preferred_output_device


func refresh_output_device() -> PackedStringArray:
	var devices := output_devices()
	var available := _preferred_output_device in devices
	var target := _preferred_output_device if available else DEFAULT_OUTPUT_DEVICE
	if AudioServer.output_device != target:
		AudioServer.output_device = target
	return devices


func set_output_device(device: String, save: bool = true) -> void:
	_preferred_output_device = device if device in output_devices() else DEFAULT_OUTPUT_DEVICE
	refresh_output_device()
	if save:
		_save_settings()


func reset_audio_settings() -> void:
	for bus in VOLUME_KEYS:
		set_volume(bus, DEFAULT_VOLUME, false)
	_preferred_output_device = DEFAULT_OUTPUT_DEVICE
	refresh_output_device()
	_save_settings()


func play_test_sound() -> void:
	var path := _pick("sfx_katana_draw")
	if path.is_empty():
		return
	var player := _free_ui_player()
	player.stream = load(path)
	player.bus = BUS_MASTER
	player.volume_db = -2.0
	player.pitch_scale = 1.0
	player.play()


func _ensure_buses() -> void:
	for bus in VOLUME_KEYS:
		if AudioServer.get_bus_index(bus) >= 0:
			continue
		AudioServer.add_bus()
		var index := AudioServer.get_bus_count() - 1
		AudioServer.set_bus_name(index, bus)
		AudioServer.set_bus_send(index, &"Master")


func _load_settings() -> void:
	var config := ConfigFile.new()
	var loaded := config.load(SETTINGS_PATH) == OK
	for bus in VOLUME_KEYS:
		var value := float(config.get_value("volume", String(bus).to_lower(), DEFAULT_VOLUME)) \
				if loaded else DEFAULT_VOLUME
		set_volume(bus, value, false)
	_preferred_output_device = str(config.get_value(
			"output", "device", DEFAULT_OUTPUT_DEVICE)) if loaded else DEFAULT_OUTPUT_DEVICE
	refresh_output_device()


func _save_settings() -> void:
	var config := ConfigFile.new()
	for bus in VOLUME_KEYS:
		config.set_value("volume", String(bus).to_lower(), volume(bus))
	config.set_value("output", "device", _preferred_output_device)
	config.save(SETTINGS_PATH)


func _crossfade_loop(player: AudioStreamPlayer, event: String, target_db: float,
		duration: float) -> void:
	var path := _pick(event)
	if path.is_empty() or (player.stream != null and player.stream.resource_path == path and player.playing):
		return
	var change := func() -> void:
		player.stream = load(path)
		if player.stream is AudioStreamOggVorbis:
			(player.stream as AudioStreamOggVorbis).loop = true
		player.volume_db = -45.0
		player.play()
		create_tween().tween_property(player, "volume_db", target_db, duration)
	if player.playing:
		var fade := create_tween()
		fade.tween_property(player, "volume_db", -45.0, duration * 0.5)
		fade.tween_callback(change)
	else:
		change.call()


func _fade_out(player: AudioStreamPlayer, duration: float) -> void:
	if not player.playing:
		return
	var fade := create_tween()
	fade.tween_property(player, "volume_db", -45.0, duration)
	fade.tween_callback(player.stop)


func _on_scene_changed() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var path := scene.scene_file_path.to_lower()
	if path.contains("title"):
		play_music("music_main_theme")
		stop_ambience()
	elif path.contains("characterselect"):
		play_music("music_character_select")
	elif path.contains("onlinelobby"):
		play_music("music_online_lobby")
	elif path.contains("maze") or path.contains("game"):
		play_music("music_exploration")
		play_ambience("amb_sakura_gardens")


func _on_node_added(node: Node) -> void:
	call_deferred("_wire_tree", node)


func _wire_tree(root: Variant) -> void:
	# node_added is deferred so the node can finish entering the tree. On the
	# slower web runtime it may also be freed before this call is delivered;
	# keeping the argument untyped lets us reject that stale Object safely.
	if not is_instance_valid(root) or not (root is Node):
		return
	if root is BaseButton:
		var button := root as BaseButton
		if not button.has_meta("audio_wired"):
			button.set_meta("audio_wired", true)
			button.focus_entered.connect(play.bind("ui_nav_move", -5.0, 0.03))
			button.mouse_entered.connect(play.bind("ui_nav_move", -7.0, 0.03))
			button.pressed.connect(play.bind("ui_nav_confirm", -3.0, 0.02))
	elif root is LineEdit:
		var line := root as LineEdit
		if not line.has_meta("audio_wired"):
			line.set_meta("audio_wired", true)
			line.text_changed.connect(func(_text: String) -> void: play("ui_dialogue_type", -9.0, 0.08))
	for child in root.get_children():
		_wire_tree(child)


func _track_footsteps(group: String) -> void:
	for body in get_tree().get_nodes_in_group(group):
		if not (body is Node2D) or body.get("is_dead") == true:
			continue
		var sprite := body.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
		if sprite == null or not sprite.is_playing():
			continue
		var animation := String(sprite.animation).to_lower()
		if not (animation.contains("walk") or animation.contains("run")):
			continue
		var id := body.get_instance_id()
		var marker := "%s:%d" % [sprite.animation, sprite.frame]
		if _last_frames.get(id, "") == marker:
			continue
		_last_frames[id] = marker
		if float(_step_cooldown.get(id, 0.0)) > 0.0 or sprite.frame % 3 != 1:
			continue
		_step_cooldown[id] = 0.18 if animation.contains("run") else 0.3
		if group == "enemy":
			var heavy: bool = (body as Node2D).scale.x > 1.25 \
					or body.scene_file_path.to_lower().contains("oni")
			play_for("sfx_enemy_step_heavy" if heavy else "sfx_enemy_step_light", body, -7.0)
		elif animation.contains("stealth") or animation.contains("ninja"):
			play_for("sfx_player_stealth_step", body, -9.0)
		elif animation.contains("run"):
			play_for("sfx_player_step_run", body, -5.0)
		else:
			var event := "sfx_player_step_hard_walk"
			var scene := get_tree().current_scene
			var theme = scene.get("_level_theme") if scene != null else null
			if theme != null and theme.id == LevelTheme.Id.FROZEN_PASS:
				event = "sfx_player_step_snow_walk"
			elif scene != null and scene.get("_ext") != null:
				event = "sfx_player_step_earth_walk"
			play_for(event, body, -7.0)
		if body.has_method("winded") and body.winded() and float(_voice_cooldown.get(id, 0.0)) <= 0.0:
			_voice_cooldown[id] = 4.0
			play_for("vox_kitsune_exhausted", body, -8.0)
