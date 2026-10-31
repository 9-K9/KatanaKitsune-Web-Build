extends Node

class Probe extends CharacterBody2D:
	var slot: int = 0
	var is_dead: bool = false


class TestWorld extends "res://scripts/system/MazeDemo.gd":
	func _ready() -> void:
		Roster.clear_party_control()
		Roster.party_control_changed.connect(_on_party_control_changed)

	func _physics_process(_delta: float) -> void:
		if bot_controls_active():
			refresh_party_control()

	func bot_navigation_contains(_point: Vector2) -> bool:
		return true

	func bot_navigation_bounds() -> Rect2:
		return Rect2(-2000, -2000, 4000, 4000)


var _checks: int = 0
var _failed: int = 0
var _world: TestWorld
var _scene: PackedScene


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


func _key(code: Key, down: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = down
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _axis(device: int, value: float) -> void:
	var event := InputEventJoypadMotion.new()
	event.device = device
	event.axis = JOY_AXIS_LEFT_X
	event.axis_value = value
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _setup(humans: int = 1) -> void:
	Roster.clear()
	Score.begin_run()
	Progression.begin_run()
	Roster.join(PlayerInput.KEYBOARD)
	for i in range(1, humans):
		Roster.join(i + 6)
	while Roster.count() < 4:
		Roster.add_bot()
	for slot in range(humans, 4):
		Roster.set_mode(slot, Roster.BotMode.PASSIVE)
	_world = TestWorld.new()
	add_child(_world)


func _probe(slot: int, point: Vector2) -> Probe:
	var body := Probe.new()
	body.slot = slot
	body.position = point
	body.add_to_group("player")
	_world._players.append(body)
	_world.add_child(body)
	return body


func _player(slot: int, point: Vector2) -> CharacterBody2D:
	var body = _scene.instantiate()
	body.slot = slot
	body.position = point
	_world._players.append(body)
	_world.add_child(body)
	var marker := Node2D.new()
	marker.set_script(load("res://scripts/system/SlotMarker.gd"))
	marker.name = "SlotMarker"
	body.add_child(marker)
	marker.setup(slot, Roster.colour_of(slot))
	return body


func _kill(body: CharacterBody2D) -> void:
	body.is_invincible = false
	body.take_damage(10000.0, Vector2.INF, false)


func _selection_checks() -> void:
	_setup(2)
	_world.set_physics_process(false)
	var first := _probe(0, Vector2.ZERO)
	var second := _probe(1, Vector2(1, 0))
	var near := _probe(2, Vector2(300, 0))
	var far := _probe(3, Vector2(0, 200))
	var permanent := Roster.players.duplicate(true)
	_world.refresh_party_control()
	_check(Roster.controlled_bot_slot == -1, "living player 1 never borrows an AI")
	second.is_dead = true
	_world.refresh_party_control()
	_check(Roster.controlled_bot_slot == -1, "player 2 cannot take over an AI")
	first.is_dead = true
	_world.refresh_party_control()
	_check(Roster.controlled_bot_slot == 2, "nearest AI uses unsquashed ground distance")
	_check(Roster.players == permanent and Roster.is_bot(2) and Roster.human_count() == 2,
			"temporary control leaves permanent roster and human count unchanged")
	_check(not Roster.is_ai_controlled(2) and Roster.controller_slot(2) == 0,
			"effective gameplay ownership identifies the temporary human")
	_check(Roster.input_for(2) is BotInput and Roster.gameplay_input_for(2).device == PlayerInput.KEYBOARD,
			"menu input stays AI while gameplay receives player 1's keyboard")
	_check(Roster.gameplay_input_for(0).vector() == Vector2.ZERO,
			"original corpse receives no gameplay movement")
	far.position = Vector2(1, 0)
	_world.refresh_party_control()
	_check(Roster.controlled_bot_slot == 2, "chosen body stays selected despite distance changes")
	near.is_dead = true
	_world.refresh_party_control()
	_check(Roster.controlled_bot_slot == 3, "death replaces the selected AI")
	far.is_dead = true
	_world.refresh_party_control()
	_check(Roster.controlled_bot_slot == -1, "no surviving AI removes takeover")
	far.is_dead = false
	_world.refresh_party_control()
	_check(Roster.controlled_bot_slot == 3, "newly revived AI can restore takeover")
	first.is_dead = false
	_world.refresh_party_control()
	_check(Roster.controlled_bot_slot == -1, "revival immediately releases temporary ownership")
	first.is_dead = true
	near.is_dead = false
	near.position = Vector2(100, 0)
	far.position = Vector2(-100, 0)
	_world._players.reverse()
	_world.refresh_party_control()
	_check(Roster.controlled_bot_slot == 2, "equal-distance tie selects lowest bot slot")
	Roster.players[0]["device"] = 9
	_check(Roster.gameplay_input_for(2).device == 9, "takeover uses player 1's controller binding")
	_check(Roster.gameplay_label_of(2) == "P1 (AI3)" and Roster.label_of(2) == "AI3",
			"gameplay labels distinguish control without changing menu identity")
	near.queue_free()
	_world.refresh_party_control()
	_check(Roster.controlled_bot_slot == 3, "queued bodies cannot remain selected")
	NetworkManager.is_client = true
	_world.refresh_party_control()
	Roster.update_party_control(_world._players)
	_check(Roster.controlled_bot_slot == -1, "network client never selects local ownership")
	NetworkManager.is_client = false
	_world.refresh_party_control()
	Roster.clear()
	_check(Roster.controlled_bot_slot == -1, "roster reset clears takeover")
	_world.queue_free()
	await _frames(2)
	_setup(4)
	var human := _probe(0, Vector2.ZERO)
	human.is_dead = true
	_probe(1, Vector2(10, 0))
	_world.refresh_party_control()
	_check(Roster.controlled_bot_slot == -1 and Roster.gameplay_input_for(1).device == 7,
			"all-human parties never borrow another human")
	_world.queue_free()
	await _frames(2)


func _live_checks() -> void:
	_setup(2)
	var first = _player(0, Vector2.ZERO)
	var second = _player(1, Vector2(-800, 0))
	var borrowed = _player(2, Vector2(500, 0))
	var follower = _player(3, Vector2(700, 0))
	_world._pass_through_each_other()
	await _frames(3)
	borrowed.health = 71.0
	first.scrolls.add(Scroll.Kind.SPEED)
	borrowed.scrolls.add(Scroll.Kind.SPEED)
	borrowed.scrolls.add(Scroll.Kind.SPEED)
	Score.points = [30, 40, 50, 60]
	var stats: Array = [borrowed.health, borrowed.stamina, borrowed.sneak,
			borrowed.scrolls.counts.duplicate(), borrowed.scrolls.kinds.duplicate()]
	var roster := Roster.players.duplicate(true)
	for key in [KEY_C, KEY_X, KEY_G, KEY_PAGEUP]:
		_key(key, true)
	_kill(first)
	_check(Roster.controlled_bot_slot == 2 and not (borrowed.input is BotInput),
			"real death immediately transfers to nearest bot's real input")
	_check(first.input.device == PlayerInput.BOT and first.input.vector() == Vector2.ZERO,
			"dead original body is input-inert during takeover")
	_check(second.input.device == 7 and not (second.input is BotInput),
			"player 2 remains on their own controller")
	_check(not borrowed.input.pressed("Attack") and not borrowed.input.just_pressed("Katana")
			and not borrowed.input.just_pressed("Stealth") and not borrowed.input.pressed("ScrollUse"),
			"held attacks, stances and scrolls cannot leak into borrowed body")
	_check(stats == [borrowed.health, borrowed.stamina, borrowed.sneak,
			borrowed.scrolls.counts, borrowed.scrolls.kinds] and Roster.players == roster,
			"handoff preserves body resources, inventory, modes and permanent slots")
	var follow_input := follower.input as BotInput
	follow_input._choose_anchor(follower)
	follow_input._choose_fallen(follower)
	_check(follow_input._living(follow_input._anchor) == borrowed and follow_input._fallen == null,
			"other bots prefer temporary leader and suspend independent rescue")
	second.position = follower.position + Vector2(20, 0)
	follow_input._choose_anchor(follower)
	_check(follow_input._living(follow_input._anchor) == borrowed,
			"temporary leader remains preferred over a nearer living human")
	second.position = Vector2(-800, 0)
	_check(borrowed.get_collision_exceptions().has(second)
			and borrowed.get_collision_exceptions().has(follower),
			"borrowed body passes through both humans and autonomous bots")
	var hud = load("res://scenes/menuscreens/hud.tscn").instantiate()
	_world.add_child(hud)
	await _frames(4)
	var cell: Dictionary = hud._cells[2]
	hud._update_cell(2, 0.0)
	_check(cell["tag"].text == "P1" and cell["mode"].text == "P1 CTRL"
			and cell["score"].text == "50", "HUD shows player 1 control while score stays with borrowed body")
	_check(hud._cells[0]["portrait"].modulate != Color.WHITE,
			"original fallen human remains visible and greyed out")
	for key in [KEY_C, KEY_X, KEY_G, KEY_PAGEUP]:
		_key(key, false)
	await _frames(3)
	var before: Vector2 = borrowed.position
	var corpse: Vector2 = first.position
	_key(KEY_D, true)
	await _frames(75)
	_key(KEY_D, false)
	await _frames(2)
	if borrowed.position.x <= before.x + 60.0 or first.position != corpse:
		print("Movement diagnostic: from=", before, " to=", borrowed.position,
				" corpse_before=", corpse, " corpse_after=", first.position,
				" state=", borrowed.get_node("FiniteStateMachine").current_state.name,
				" speed=", borrowed.speed, " control=", Roster.controlled_bot_slot)
	_check(borrowed.position.x > before.x + 60.0 and first.position == corpse,
			"keyboard moves the borrowed real body, never the corpse")
	var enemy := Probe.new()
	_world.add_child(enemy)
	borrowed.last_hurt_by = weakref(enemy)
	borrowed.last_hurt_at_ms = Time.get_ticks_msec()
	_check(not BotTactics.provokes(Roster.BotMode.PASSIVE, follower, borrowed, enemy),
			"passive follower stays focused on healing instead of joining another player's fight")
	borrowed.last_hurt_by = null
	enemy.queue_free()
	var old_input: PlayerInput = borrowed.input
	Roster.players[0]["device"] = 9
	Roster.device_regained.emit(0)
	_check(borrowed.input.device == 9 and borrowed.input != old_input
			and second.input.device == 7 and first.input.device == PlayerInput.BOT,
			"player 1 reconnect rebinds the borrowed body without changing player 2")
	borrowed.position = Vector2(500, 300)
	before = borrowed.position
	_axis(9, 1.0)
	await _frames(30)
	_axis(9, 0.0)
	_check(borrowed.position.x > before.x + 25.0,
			"player 1 controller axis drives the borrowed real body")
	Roster.players[0]["device"] = PlayerInput.KEYBOARD
	Roster.device_regained.emit(0)
	_world._building = true
	before = borrowed.position
	_key(KEY_D, true)
	_key(KEY_C, true)
	await _frames(12)
	_key(KEY_D, false)
	_check(borrowed.position == before and Roster.controlled_bot_slot == 2
			and not borrowed.input.pressed("Attack") and borrowed.input.vector() == Vector2.ZERO,
			"floor loading freezes temporary human controls without losing ownership")
	_key(KEY_C, false)
	_world._building = false
	get_tree().paused = true
	await get_tree().create_timer(0.05, true).timeout
	_check(Roster.controlled_bot_slot == 2, "pause retains temporary ownership")
	get_tree().paused = false
	await _frames(3)
	# Use the borrowed character's own sneak meter and real state machine.
	borrowed.position = Vector2(160, 0)
	borrowed.get_node("FiniteStateMachine").change_state("idle")
	borrowed.sneak = borrowed.max_sneak
	_key(KEY_G, true)
	await _frames(3)
	_key(KEY_G, false)
	for _i in 240:
		await get_tree().physics_frame
		if not first.is_dead:
			break
	_check(not first.is_dead and Roster.controlled_bot_slot == -1,
			"real sneak-to-revive returns control immediately to player 1")
	_check(first.input.device == PlayerInput.KEYBOARD and borrowed.input is BotInput
			and Roster.mode_of(2) == Roster.BotMode.PASSIVE,
			"revived human controls original body and borrowed AI retains saved mode")
	_check(borrowed.sneak <= 1.0 and first.health == first.max_health * first.revive_health,
			"revival uses original sneak cost and normal restored health")
	_check(first.scrolls.counts[0] == 1 and borrowed.scrolls.counts[0] == 2
			and Score.points == [30, 40, 50, 60],
			"revival does not swap inventories or scores")
	hud._update_cell(2, 0.0)
	_check(cell["tag"].text == "AI3" and cell["mode"].text == "PAS"
			and Roster.gameplay_label_of(2) == "AI3", "HUD and ground label restore AI identity")
	_check(borrowed.get_collision_exceptions().has(follower)
			and borrowed.get_collision_exceptions().has(second),
			"return preserves pass-through collision for every teammate")
	_kill(second)
	follow_input._choose_fallen(follower)
	_check(follow_input._dead(follow_input._fallen) == second,
			"autonomous rescue selection resumes once temporary control ends")
	second.revive(0.5)
	var original_input: PlayerInput = first.input
	_kill(first)
	_check(Roster.controlled_bot_slot == 2, "second death can initiate takeover again")
	_key(KEY_C, true)
	_kill(borrowed)
	_check(Roster.controlled_bot_slot == 3 and follower.input.device == PlayerInput.KEYBOARD
			and borrowed.input is BotInput, "borrowed real character death moves control to surviving AI")
	follower.revive(0.5)
	_check(Roster.controlled_bot_slot == 3, "reviving a living borrowed AI never returns the original human")
	first.revive(0.5)
	_check(Roster.controlled_bot_slot == -1 and not first.input.pressed("Attack")
			and first.input != original_input, "held attack is suppressed on return to original body")
	_key(KEY_C, false)
	await _frames(3)
	_key(KEY_C, true)
	await get_tree().process_frame
	if not first.input.just_pressed("Attack"):
		print("Attack diagnostic: pressed=", Input.is_key_pressed(KEY_C),
				" now=", first.input._now, " was=", first.input._was,
				" suppressed=", first.input._held_until_release)
	_check(first.input.just_pressed("Attack"), "fresh attack press works after the handoff release")
	_key(KEY_C, false)
	_kill(first)
	_kill(follower)
	_check(Roster.controlled_bot_slot == -1, "all bots down leaves no temporary character")
	var over = load("res://scenes/menuscreens/gameOver.tscn").instantiate()
	_world.add_child(over)
	over.set_process(false)
	_check(not over._is_dead(), "living player 2 prevents game over even with all AI down")
	_kill(second)
	_check(over._is_dead(), "every human and AI down ends the run")
	_world.queue_free()
	await _frames(3)
	_check(Roster.controlled_bot_slot == -1, "world teardown leaves no stale ownership")


func _maze_checks() -> void:
	_setup()
	_world.queue_free()
	await _frames(2)
	var maze = load("res://scenes/world/mazeDemo.tscn").instantiate()
	maze.maze_seed = 101
	maze.grid = Vector2i(2, 2)
	maze.outdoor_weather = 0
	maze.level_theme = 0
	maze.enemies_per_room = Vector2i.ZERO
	maze.party_enemy_bonus = 0.0
	maze.props_per_room = Vector2i.ZERO
	maze.trap_chance = 0.0
	maze.extra_chairs = 0
	add_child(maze)
	while maze._building or maze._player == null:
		await get_tree().process_frame
	maze._wave_live = false
	var first: CharacterBody2D = maze._players[0]
	_kill(first)
	var selected := Roster.controlled_bot_slot
	_check(selected > 0 and not (maze._players[selected].input is BotInput),
			"actual generated maze performs takeover on real death")
	var borrowed: CharacterBody2D = maze._players[selected]
	var before: float = borrowed.health
	var max_before: float = borrowed.max_health
	maze.descend()
	while maze._building:
		await get_tree().process_frame
	maze._wave_live = false
	_check(Roster.controlled_bot_slot == selected and borrowed.input.device == PlayerInput.KEYBOARD
			and borrowed.health == before + borrowed.max_health - max_before and first.is_dead,
			"actual floor rebuild retains borrowed body, resources and effective control")
	first.revive(0.5)
	_check(Roster.controlled_bot_slot == -1 and borrowed.input is BotInput,
			"reviving after descent restores normal ownership")
	_kill(first)
	_check(Roster.controlled_bot_slot >= 0, "takeover can resume on rebuilt floor")
	maze.queue_free()
	await _frames(3)
	_check(Roster.controlled_bot_slot == -1, "actual maze teardown clears active takeover")


func _party_collision_checks() -> void:
	_setup(2)
	_world.set_physics_process(false)
	for slot in 4:
		var body := _probe(slot, Vector2(slot * 100, 0))
		body.collision_layer = 3
		body.collision_mask = 3
		var shape := CollisionShape2D.new()
		var circle := CircleShape2D.new()
		circle.radius = 20
		shape.shape = circle
		body.add_child(shape)
	_world._pass_through_each_other()
	await _frames(2)
	for body: CharacterBody2D in _world._players:
		for other: CharacterBody2D in _world._players:
			if body == other:
				continue
			_check(body.get_collision_exceptions().has(other),
					"every party pair has a collision exception")
			_check(not body.test_move(
					Transform2D(0, other.position - Vector2(50, 0)), Vector2(100, 0)),
					"overlapping actor masks do not block teammate crossing")
	var obstacle := StaticBody2D.new()
	obstacle.position = Vector2(600, 0)
	obstacle.collision_layer = 3
	var shape := CollisionShape2D.new()
	var box := RectangleShape2D.new()
	box.size = Vector2(30, 100)
	shape.shape = box
	obstacle.add_child(shape)
	_world.add_child(obstacle)
	await _frames(2)
	for body: CharacterBody2D in _world._players:
		_check(body.test_move(Transform2D(0, Vector2(550, 0)), Vector2(100, 0)),
				"teammate exceptions preserve scenery collision")
	_world.queue_free()
	await _frames(2)
	Roster.clear()


func _run() -> void:
	_scene = load("res://scenes/characters/Kitsune.tscn")
	if "--maze-only" in OS.get_cmdline_user_args():
		await _maze_checks()
	else:
		await _party_collision_checks()
		await _selection_checks()
		await _live_checks()
	Roster.clear()
	Progression.begin_run()
	Score.begin_run()
	print("AI takeover: %d checks, %d failures" % [_checks, _failed])
	get_tree().quit(1 if _failed else 0)
