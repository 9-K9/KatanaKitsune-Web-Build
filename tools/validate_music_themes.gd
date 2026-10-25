extends SceneTree

func _init() -> void:
	var expected := [
		[LevelTheme.Id.SAKURA_GARDENS, "sakura"],
		[LevelTheme.Id.BAMBOO_WOODLAND, "bamboo"],
		[LevelTheme.Id.ABANDONED_SHRINES, "abandoned"],
		[LevelTheme.Id.DESERT_RUINS, "desert"],
		[LevelTheme.Id.FROZEN_PASS, "snow"],
	]
	var failures: Array[String] = []
	for entry in expected:
		for danger in [false, true]:
			var event := "music_%s_%s" % [
				LevelTheme.music_key(entry[0]), "danger" if danger else "calm"]
			var wanted := "music_%s_%s" % [entry[1], "danger" if danger else "calm"]
			if event != wanted:
				failures.append("theme %s mapped to %s, expected %s" % [entry[0], event, wanted])
			var path := "res://assets/audio/generated/final/%s.ogg" % event
			if not ResourceLoader.exists(path):
				failures.append("missing imported stream: %s" % path)
			elif load(path) == null:
				failures.append("failed to load stream: %s" % path)
	if failures.is_empty():
		print("MUSIC THEME VALIDATION: 10/10 mappings and streams passed")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)
