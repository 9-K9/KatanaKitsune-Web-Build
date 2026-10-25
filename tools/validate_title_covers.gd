extends Node


func _ready() -> void:
	var failures: Array[String] = []
	for index in PowerState.count():
		var path := PowerState.cover_path(index)
		if not ResourceLoader.exists(path):
			failures.append("missing cover %d: %s" % [index, path])
			continue
		var texture := load(path) as Texture2D
		if texture == null:
			failures.append("failed to load cover %d: %s" % [index, path])
		elif texture.get_size() != Vector2(768, 432):
			failures.append("wrong cover size %d: %s" % [index, texture.get_size()])
	var fallback := load(PowerState.DEFAULT_COVER) as Texture2D
	if fallback == null or fallback.get_size() != Vector2(768, 432):
		failures.append("invalid fallback cover")
	if failures.is_empty():
		print("TITLE COVER VALIDATION: 12/12 variants and fallback passed")
		get_tree().quit(0)
	else:
		for failure in failures:
			push_error(failure)
		get_tree().quit(1)
