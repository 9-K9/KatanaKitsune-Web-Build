extends Node

class Probe extends CharacterBody2D:
	var slot: int = 0
	var is_dead: bool = false
	var actionBlockInput: bool = false
	var katana_drawn: bool = false
	var stealthed: bool = false
	var crouched: bool = false
	var speed: float = 600.0
	var input: BotInput
	var facing := Vector2.LEFT
	var drive := Vector2.ZERO
	var revivals: int = 0

	func winded() -> bool:
		return false

	func revive(_fraction: float = 0.5) -> void:
		is_dead = false
		collision_layer = 1
		revivals += 1

	func _physics_process(delta: float) -> void:
		var move := drive
		if input != null:
			input.update(delta)
			move = input.vector().round()
			if input.just_pressed("Katana"):
				katana_drawn = not katana_drawn
			if input.just_pressed("Stealth") and not katana_drawn:
				stealthed = true
		if move != Vector2.ZERO:
			facing = move
		velocity = Vector2(move.x, move.y * 0.5) * speed
		move_and_slide()


class World extends Node2D:
	var bounds := Rect2(-400, -1600, 6000, 3200)

	func bot_controls_active() -> bool:
		return true

	func bot_navigation_bounds() -> Rect2:
		return bounds

	func bot_navigation_contains(point: Vector2) -> bool:
		return bounds.has_point(point)


var _checks: int = 0
var _failed: int = 0
var _world: World


func _ready() -> void:
	call_deferred("_run")


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failed += 1
		push_error(message)


func _frames(count: int) -> void:
	for _i in count:
		await get_tree().physics_frame


func _shape(body: CollisionObject2D, size: Vector2) -> void:
	var collision := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = size
	collision.shape = rect
	body.add_child(collision)


func _probe(slot: int, point: Vector2, dead: bool = false) -> Probe:
	var body := Probe.new()
	body.slot = slot
	body.position = point
	body.is_dead = dead
	body.collision_layer = 0 if dead else 1
	body.add_to_group("player")
	_shape(body, Vector2(64, 32))
	_world.add_child(body)
	return body


func _wall(point: Vector2, size: Vector2) -> StaticBody2D:
	var wall := StaticBody2D.new()
	wall.position = point
	_shape(wall, size)
	_world.add_child(wall)
	return wall


func _setup() -> void:
	Roster.clear()
	Roster.join(PlayerInput.KEYBOARD)
	Roster.add_bot()
	_world = World.new()
	add_child(_world)


func _navigation_checks() -> void:
	_setup()
	var human := _probe(0, Vector2(4500, 0), true)
	var bot := _probe(1, Vector2.ZERO)
	bot.input = Roster.input_for(1)
	bot.input.bind_body(bot)
	_wall(Vector2(2200, 0), Vector2(80, 2200))
	_wall(Vector2(3600, 0), Vector2(100, 180))
	await _frames(2)
	var nav := BotNavigation.new()
	nav.bind_body(bot)
	nav.begin(bot.position, human.position, BotInput.REVIVE_DISTANCE)
	while nav.searching:
		nav.advance()
	_check(not nav.exhausted and not nav.path.is_empty(),
			"floor-wide path reaches a human beyond the old search radius")
	var from := bot.position
	var detour: float = 0.0
	for point in nav.path:
		_check(nav.safe_segment(from, point), "every path edge clears the body, wall and pillar")
		detour = maxf(detour, absf(point.y))
		from = point
	_check(detour > 1100, "rescue route goes around the far end of the room wall")
	_check(not nav.safe_segment(Vector2.ZERO, Vector2(-500, 0)),
			"navigation cannot leave the playable floor")
	var reached := false
	for _i in 2400:
		await get_tree().physics_frame
		if BotNavigation.ground(bot.position - human.position).length() <= BotInput.REVIVE_DISTANCE:
			reached = true
			break
	_check(reached, "live bot follows the floor-wide route through multiple rooms")
	await _frames(3)
	_check(bot.stealthed, "distant rescue ends in the normal revive stance")
	_world.queue_free()
	await _frames(2)


func _priority_checks() -> void:
	for mode in Roster.BotMode.values():
		_setup()
		Roster.set_mode(1, mode)
		var human := _probe(0, Vector2(500, 0), true)
		var bot := _probe(1, Vector2.ZERO)
		var enemy := CharacterBody2D.new()
		enemy.position = Vector2(-100, 0)
		_world.add_child(enemy)
		var machine := FiniteStateMachine.new()
		machine.name = "FiniteStateMachine"
		var attack := StateMachineState.new()
		attack.name = "Attack"
		machine.add_child(attack)
		enemy.add_child(machine)
		machine.current_state = attack
		bot.input = Roster.input_for(1)
		bot.input.bind_body(bot)
		bot.input._fallen = weakref(human)
		bot.input._target = weakref(enemy)
		bot.input._think_left = 100.0
		bot.input.update(1.0 / 60.0)
		var prioritises_rescue: bool = bot.input.vector().x > 0 \
				and not bot.input.pressed("Attack") and not bot.input.pressed("Defend")
		_check(prioritises_rescue == (mode == Roster.BotMode.PASSIVE),
				"only Passive overrides an immediate combat threat to rescue in mode %d" % mode)
		bot.input._think_left = 0.0
		var fallen_bot := _probe(2, Vector2(100, 0), true)
		Roster.add_bot()
		bot.input.update(1.0 / 60.0)
		_check(bot.input._dead(bot.input._fallen) == human,
				"fallen human takes priority over closer fallen bot in mode %d" % mode)
		var second_human := _probe(3, Vector2(20, 0), true)
		Roster.join(7)
		bot.input._choose_fallen(bot)
		_check(bot.input._dead(bot.input._fallen) == human,
				"detouring rescuer keeps its human target instead of changing rooms")
		second_human.queue_free()
		fallen_bot.queue_free()
		_world.queue_free()
		await _frames(2)


func _push_checks() -> void:
	for blocked in [false, true]:
		_setup()
		var human := _probe(0, Vector2(-78, 0))
		var bot := _probe(1, Vector2.ZERO)
		human.speed = 120.0
		bot.speed = 120.0
		human.drive = Vector2.RIGHT
		bot.input = Roster.input_for(1)
		bot.input.bind_body(bot)
		if blocked:
			_wall(Vector2(52, 0), Vector2(32, 300))
		await _frames(2)
		var before := bot.position
		var facings: Dictionary = {}
		var max_bot_x: float = bot.position.x
		for _i in 180:
			await get_tree().physics_frame
			facings[bot.facing] = true
			max_bot_x = maxf(max_bot_x, bot.position.x)
		_check(facings.size() <= 1, "pushed bot never alternates facing (blocked=%s)" % blocked)
		if blocked:
			_check(max_bot_x <= 4.5 and human.position.x <= bot.position.x - 63.0,
					"pinned bot blocks human without penetration into bot or wall")
			_check(bot.input.vector() == Vector2.ZERO, "pinned bot holds still")
		else:
			_check(bot.position.x > before.x + 100, "unblocked bot walks in push direction")
		_world.queue_free()
		await _frames(2)


func _door_checks() -> void:
	_setup()
	var human := _probe(0, Vector2(800, 0), true)
	var bot := _probe(1, Vector2.ZERO)
	bot.speed = 183.0
	_wall(Vector2(400, -350), Vector2(48, 500))
	_wall(Vector2(400, 350), Vector2(48, 500))
	var door := SlidingDoor.new()
	door.position = Vector2(400, 0)
	door.doorway = PackedVector2Array([Vector2(-24, -100), Vector2(24, -100),
			Vector2(24, 100), Vector2(-24, 100)])
	_world.add_child(door)
	await _frames(2)
	bot.input = Roster.input_for(1)
	bot.input.bind_body(bot)
	var nav := bot.input.navigation
	nav.begin(bot.position, human.position, BotInput.REVIVE_DISTANCE)
	_check(not nav.safe_segment(bot.position, human.position),
			"shut sliding door remains physically solid")
	_check(not nav.searching and not nav.path.is_empty(),
			"planner knows a shut sliding panel will open on approach")
	for _i in 600:
		await get_tree().physics_frame
		if bot.stealthed:
			break
	_check(bot.stealthed and bot.position.x > door.position.x
			and BotNavigation.ground(bot.position - human.position).length() <= BotInput.REVIVE_DISTANCE,
			"bot opens and walks through the door to rescue a human")
	_world.queue_free()
	await _frames(2)


func _hard_rescue_checks() -> void:
	_setup()
	var human := _probe(0, Vector2(700, 0))
	var bot := _probe(1, Vector2.ZERO)
	bot.input = Roster.input_for(1)
	bot.input.bind_body(bot)
	var visual := AnimatedSprite2D.new()
	visual.name = "AnimatedSprite2D"
	bot.add_child(visual)
	await _frames(2)
	var reserved: Array[Vector2] = []
	var landing := bot.input.rescue_position_near(human, reserved)
	_check(landing != Vector2.INF and bot.input.navigation.safe_segment(landing, landing),
			"hard rescue chooses floor that clears the bot's real collision shape")
	_check(bot.input.rescue_to(landing), "hard rescue accepts a safe landing")
	await _frames(30)
	_check(bot.position.is_equal_approx(landing), "hard rescue moves beside the human")
	_check(is_equal_approx(visual.modulate.a, 1.0), "hard rescue fades the sprite back in")
	_check(not bot.test_move(bot.global_transform, Vector2.ZERO, null, 0.5, true),
			"hard rescue does not finish overlapping another collision")

	var door := SlidingDoor.new()
	door.position = Vector2(1100, 0)
	door.slope = 0.0
	door.doorway = PackedVector2Array([Vector2(-60, -16), Vector2(60, -16),
			Vector2(60, 16), Vector2(-60, 16)])
	_world.add_child(door)
	await _frames(2)
	var crossings := [0]
	door.human_crossed.connect(func(_player): crossings[0] += 1)
	human.position = door.position + Vector2(0, -60)
	door._track_human_crossings()
	human.position = door.position + Vector2(0, 60)
	door._track_human_crossings()
	_check(crossings[0] == 1, "door emits one human crossing for the delayed rescue trigger")
	_world.queue_free()
	await _frames(2)


func _real_revive_checks() -> void:
	_setup()
	var human := _probe(0, Vector2(80, 0), true)
	var bot = load("res://scenes/characters/Kitsune.tscn").instantiate()
	bot.slot = 1
	_world.add_child(bot)
	bot.stealthed = true
	var wall := _wall(Vector2(40, 0), Vector2(16, 300))
	await _frames(2)
	_check(bot._fallen_underfoot() == null, "revival cannot drain through a wall or pillar")
	wall.queue_free()
	await _frames(2)
	for mode in Roster.BotMode.values():
		Roster.set_mode(1, mode)
		human.is_dead = true
		human.collision_layer = 0
		var direction := Vector2(BotNavigation.DIRECTIONS[mode * 2])
		human.position = Vector2(direction.x, direction.y * 0.5) * BotInput.REVIVE_DISTANCE
		bot.position = Vector2.ZERO
		bot.sneak = bot.max_sneak
		bot.input.reset()
		var before: int = human.revivals
		for _i in 480:
			await get_tree().physics_frame
			if human.revivals > before:
				break
		_check(human.revivals == before + 1, "real player state machine revives in mode %d" % mode)
		_check(bot.sneak <= 1.0, "revival spends the real sneak meter in mode %d" % mode)
		_check(not bot.test_move(bot.global_transform, Vector2.ZERO, null, 0.5, true),
				"restored human collision does not overlap rescuer in mode %d" % mode)
	human.is_dead = false
	human.collision_layer = 1
	human.speed = 120.0
	human.drive = Vector2.RIGHT
	Roster.set_mode(1, Roster.BotMode.PASSIVE)
	for blocked in [false, true]:
		bot.get_node("FiniteStateMachine").change_state("idle")
		bot.position = Vector2.ZERO
		bot.katana_drawn = false
		human.position = Vector2(-78, 0)
		bot.input.reset()
		wall = _wall(Vector2(52, 0), Vector2(32, 300)) if blocked else null
		await _frames(30)
		var facings: Dictionary = {}
		for _i in 180:
			await get_tree().physics_frame
			facings[bot.facing_dir] = true
		_check(facings.size() == 1, "real sprite facing stays stable while pushed (blocked=%s)" % blocked)
		if blocked:
			_check(bot.position.x < 1.0 and human.position.x <= bot.position.x - 66.0,
					"real pinned bot blocks the human without forced collision")
		else:
			_check(bot.position.x > 50.0, "real bot walks with a push through ordinary movement states")
		if wall != null:
			wall.queue_free()
			await _frames(2)
	_world.queue_free()
	await _frames(2)


func _maze_checks() -> void:
	for exterior in [false, true]:
		Roster.clear()
		Roster.join(PlayerInput.KEYBOARD)
		Roster.add_bot()
		var maze = load("res://scenes/world/mazeDemo.tscn").instantiate()
		maze.maze_seed = 101
		maze.grid = Vector2i(3, 3)
		maze.exteriors = exterior
		maze.outdoor_weather = 0
		maze.level_theme = 0
		maze.enemies_per_room = Vector2i.ZERO
		maze.party_enemy_bonus = 0.0
		maze.props_per_room = Vector2i.ZERO
		maze.trap_chance = 0.0
		maze.extra_chairs = 0
		maze.door_chance = 1.0
		maze.set_physics_process(false)
		add_child(maze)
		while maze._building or maze._player == null:
			await get_tree().process_frame
		for body in maze._players:
			body.set_physics_process(false)
			body.get_node("FiniteStateMachine").set_process(false)
		await _frames(2)
		var bot: CharacterBody2D = maze._players[1]
		var human: CharacterBody2D = maze._players[0]
		_check(PhysicsServer2D.body_get_space(bot.get_rid()).is_valid(),
				"maze probe retains a live physics body")
		_check(bot.get_collision_exceptions().has(human)
				and human.get_collision_exceptions().has(bot),
				"actual maze disables human/bot contact in both directions")
		var nav := BotNavigation.new()
		nav.bind_body(bot)
		var bounds: Rect2 = maze.bot_navigation_bounds()
		_check(bounds.has_area() and not maze.bot_navigation_contains(bounds.end + Vector2.ONE),
				"actual maze navigation is restricted to its floor")
		for cell in maze._rooms:
			var goal: Vector2 = maze._room_centre(cell)
			_check(maze.bot_navigation_contains(goal), "room centre belongs to actual floor")
			if not nav.safe_segment(goal, goal):
				var centre := goal
				var found := false
				for radius in [48.0, 96.0, 192.0, 384.0, 576.0]:
					for direction in BotNavigation.DIRECTIONS:
						var point: Vector2 = centre + Vector2(direction.x, direction.y * 0.5) * radius
						if nav.safe_segment(point, point):
							goal = point
							found = true
							break
					if found:
						break
				_check(found, "fixture selects a walkable rescue position, not furniture or water")
			nav.begin(bot.global_position, goal, BotInput.REVIVE_DISTANCE)
			while nav.searching:
				nav.advance()
			if nav.exhausted:
				print("Maze route diagnostic: cell=", cell, " exterior=", exterior,
						" goal=", goal, " origin=", bot.global_position, " path_end=",
						nav.path[-1] if not nav.path.is_empty() else Vector2.INF,
						" kind=", maze._ext.kind.get(cell) if maze._ext != null else -1)
			_check(not nav.exhausted, "actual maze route reaches room %s (exterior=%s, expanded=%d)" %
					[cell, exterior, nav.expansions])
		maze.queue_free()
		await _frames(3)


func _run() -> void:
	if "--hard-only" in OS.get_cmdline_user_args():
		await _hard_rescue_checks()
	elif "--maze-only" in OS.get_cmdline_user_args():
		await _maze_checks()
	else:
		await _navigation_checks()
		await _priority_checks()
		await _push_checks()
		await _door_checks()
		await _hard_rescue_checks()
		if "--movement-only" not in OS.get_cmdline_user_args():
			await _real_revive_checks()
	Roster.clear()
	print("AI rescue/push: %d checks, %d failures" % [_checks, _failed])
	get_tree().quit(1 if _failed else 0)
