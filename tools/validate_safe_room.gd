extends Node

const MAZE := preload("res://scenes/world/mazeDemo.tscn")
var checks := 0
var failures := 0


func _ready() -> void:
	call_deferred("_run")


func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)


func _exercise(outdoors: bool, seed: int) -> void:
	Roster.clear()
	Roster.join(PlayerInput.KEYBOARD, 0)
	var maze = MAZE.instantiate()
	maze.grid = Vector2i(3, 3)
	maze.maze_seed = seed
	maze.exteriors = outdoors
	maze.enemy_scene_paths.clear()
	maze.prop_scenes.clear()
	maze.torch_scenes.clear()
	maze.animal_scenes.clear()
	maze.table_scenes.clear()
	maze.extra_chairs = 0
	maze.stream_world = false
	add_child(maze)
	while maze._building:
		await get_tree().process_frame

	var start: Vector2i = maze._start_cell
	var room: Node = maze._rooms.get(start)
	check(room != null, "safe room exists")
	check(maze._room_monster.get(start) == null, "safe room has no monster assignment")
	if outdoors:
		check(maze._ext != null and maze._ext.is_building(start),
				"outdoor start is converted into a roofed room")

	var doors := room.find_children("Door_*", "SlidingDoor", true, false)
	check(doors.size() >= 1, "safe-room exit has a door")
	var chairs := get_tree().get_nodes_in_group("chair").filter(
			func(chair): return chair.has_meta("safe_room_chair"))
	check(chairs.size() == 1, "safe room retains exactly one guaranteed healing chair")
	check(maze.safe_room_contains(maze._room_centre(start)), "safe-room centre is protected")

	var outside_cell: Vector2i = start
	var farthest := -1.0
	for cell in maze._rooms:
		var distance: float = Vector2(cell).distance_squared_to(Vector2(start))
		if cell != start and distance > farthest \
				and not maze.safe_room_contains(maze._room_centre(cell)):
			farthest = distance
			outside_cell = cell
	check(outside_cell != start, "validation found floor outside the safe room")
	var intruder := CharacterBody2D.new()
	intruder.add_to_group("enemy")
	maze.add_child(intruder)
	maze._clearing = false
	var outside: Vector2 = maze._room_centre(outside_cell)
	intruder.global_position = outside
	maze._enforce_safe_room()
	intruder.global_position = maze._room_centre(start)
	maze._enforce_safe_room()
	check(intruder.global_position == outside, "enemy crossing into safe room is rejected")

	maze.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


func _run() -> void:
	for seed in [41041, 52711, 68449]:
		await _exercise(false, seed)
	for seed in [91091, 102203, 118127]:
		await _exercise(true, seed)
	print("SAFE ROOM VALIDATION: %d checks, %d failures" % [checks, failures])
	get_tree().quit(1 if failures else 0)
