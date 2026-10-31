extends Node

## Headless checks for AI teammate behaviour modes: the Roster store, the
## damage memory that modes read, BotTactics' target rules, the pause-menu
## switcher and the live bot reacting to each mode.
##
## godot --headless --path . --scene res://tools/validate_ai_modes.tscn

class ModeProbe extends CharacterBody2D:
	var slot: int = 0
	var is_dead: bool = false
	var katana_drawn: bool = false
	var actionBlockInput: bool = false
	var stealthed: bool = false
	var health: float = 100.0
	var max_health: float = 100.0
	var sneak: float = 100.0
	var flair_sneak_cost: float = 35.0
	var last_hurt_by: WeakRef = null
	var last_hurt_at_ms: int = -1
	var input: PlayerInput
	var speed: float = 120.0

	func winded() -> bool:
		return false

	## Mirrors AnimatedCharacterClass, which the checks below also exercise
	## directly; a bare probe keeps the scenario free of sprites and timers.
	func hurt_recently_by(enemy: Node, window_ms: int = 4000) -> bool:
		return last_hurt_by != null and last_hurt_by.get_ref() == enemy \
				and Time.get_ticks_msec() - last_hurt_at_ms <= window_ms

	func attacker_recent(window_ms: int = 4000) -> Node2D:
		if last_hurt_by == null or Time.get_ticks_msec() - last_hurt_at_ms > window_ms:
			return null
		return last_hurt_by.get_ref() as Node2D

	func hurt_by(enemy: Node) -> void:
		last_hurt_by = weakref(enemy)
		last_hurt_at_ms = Time.get_ticks_msec()

	func _physics_process(delta: float) -> void:
		if input == null:
			return
		input.update(delta)
		## Just enough of the player state machine for the bot to see its own
		## presses land: the blade toggles and sneaking toggles.
		if input.just_pressed("Katana"):
			katana_drawn = not katana_drawn
		if input.just_pressed("Stealth") and not katana_drawn:
			stealthed = not stealthed
		var move := input.vector().round()
		velocity = Vector2(move.x, move.y * 0.5) * 120.0
		move_and_slide()


class EnemyProbe extends CharacterBody2D:
	var is_dead: bool = false
	var _last_hit_by: int = -1
	var _last_hit_at_ms: int = -1
	var machine: FiniteStateMachine
	var hits: int = 0

	func _init() -> void:
		machine = FiniteStateMachine.new()
		machine.name = "FiniteStateMachine"
		add_child(machine)
		for state_name in ["idle", "walk"]:
			var state := StateMachineState.new()
			state.name = state_name
			machine.add_child(state)
		machine.current_state = machine.get_node("idle")

	func aware(on: bool) -> void:
		machine.current_state = machine.get_node("walk" if on else "idle")

	func struck_by(slot: int) -> void:
		_last_hit_by = slot
		_last_hit_at_ms = Time.get_ticks_msec()

	func last_hit_slot(window_ms: int = 4000) -> int:
		if _last_hit_at_ms < 0 or Time.get_ticks_msec() - _last_hit_at_ms > window_ms:
			return -1
		return _last_hit_by

	func take_damage(_amount: float, _from: Vector2 = Vector2.INF, _g: bool = true) -> void:
		hits += 1


class TestWorld extends Node2D:
	func bot_controls_active() -> bool:
		return true


var _checks: int = 0
var _failed: int = 0
var _world: TestWorld


func _ready() -> void:
	call_deferred("_run")


func _check(ok: bool, description: String) -> void:
	_checks += 1
	if not ok:
		_failed += 1
		push_error(description)


func _shape(body: CollisionObject2D, size: Vector2) -> void:
	var collision := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = size
	collision.shape = rect
	body.add_child(collision)


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


func _roster_checks() -> void:
	Roster.clear()
	Roster.join(PlayerInput.KEYBOARD)
	var bot := Roster.add_bot()
	_check(Roster.mode_of(bot) == Roster.BotMode.DEFENSIVE, "new bots default to Defensive")
	_check(Roster.BOT_MODE_NAMES.size() == 4 and Roster.BOT_MODE_TAGS.size() == 4 \
			and Roster.BOT_MODE_HINTS.size() == 4, "every mode has a name, tag and hint")
	var changed := [0]
	var count_change := func() -> void: changed[0] += 1
	Roster.roster_changed.connect(count_change)
	Roster.set_mode(bot, Roster.BotMode.STEALTH)
	_check(Roster.mode_of(bot) == Roster.BotMode.STEALTH and changed[0] == 1,
			"set_mode stores and announces the change")
	_check(Roster.cycle_mode(bot) == Roster.BotMode.PASSIVE, "cycle steps forward")
	_check(Roster.cycle_mode(bot) == Roster.BotMode.AGGRESSIVE, "cycle wraps to the first mode")
	_check(Roster.cycle_mode(bot, -1) == Roster.BotMode.PASSIVE, "cycle steps back and wraps")
	Roster.set_mode(0, Roster.BotMode.AGGRESSIVE)
	_check(not Roster.players[0].has("mode") and Roster.mode_of(0) == Roster.DEFAULT_BOT_MODE,
			"humans never carry a bot mode")
	Roster.roster_changed.disconnect(count_change)
	Roster.drop_last()
	_check(Roster.mode_of(Roster.add_bot()) == Roster.BotMode.DEFENSIVE,
			"a re-added bot starts on the default again")


func _memory_checks() -> void:
	## The real classes, not the probes: these are what a live run reads.
	var player := AnimatedCharacterClass.new()
	var enemy := Node2D.new()
	_check(not player.hurt_recently_by(enemy) and player.attacker_recent() == null,
			"an unhurt player remembers no attacker")
	player.last_hurt_by = weakref(enemy)
	player.last_hurt_at_ms = Time.get_ticks_msec()
	_check(player.hurt_recently_by(enemy), "a fresh blow is remembered")
	_check(player.attacker_recent() == enemy, "the attacker is reported back")
	player.last_hurt_at_ms = Time.get_ticks_msec() - 5000
	_check(not player.hurt_recently_by(enemy) and player.attacker_recent() == null,
			"a stale blow is forgotten")
	enemy.free()
	player.last_hurt_at_ms = Time.get_ticks_msec()
	_check(player.attacker_recent() == null, "a freed attacker is not reported")
	player.free()

	var monster := EnemyBase.new()
	_check(monster.last_hit_slot() == -1 and not monster.hit_recently_by(0),
			"an untouched monster has no striker")
	monster._last_hit_by = 2
	monster._last_hit_at_ms = Time.get_ticks_msec()
	_check(monster.last_hit_slot() == 2 and monster.hit_recently_by(2)
			and not monster.hit_recently_by(0), "a monster remembers who struck it")
	monster._last_hit_at_ms = Time.get_ticks_msec() - 5000
	_check(monster.last_hit_slot() == -1, "an old strike is forgotten")
	monster.free()


func _tactics_checks() -> void:
	Roster.clear()
	Roster.join(PlayerInput.KEYBOARD)
	Roster.add_bot()
	var world := Node2D.new()
	add_child(world)
	var human := ModeProbe.new()
	human.slot = 0
	human.add_to_group("player")
	world.add_child(human)
	var bot := ModeProbe.new()
	bot.slot = 1
	bot.add_to_group("player")
	world.add_child(bot)
	var enemy := EnemyProbe.new()
	world.add_child(enemy)
	var M := Roster.BotMode

	for mode in [M.DEFENSIVE, M.STEALTH, M.PASSIVE]:
		_check(not BotTactics.provokes(mode, bot, human, enemy),
				"%s ignores an unprovoked monster" % Roster.BOT_MODE_NAMES[mode])
	_check(BotTactics.provokes(M.AGGRESSIVE, bot, human, enemy),
			"Aggressive takes any monster")

	enemy.struck_by(0)
	_check(BotTactics.provokes(M.DEFENSIVE, bot, human, enemy),
			"Defensive joins a fight a human started")
	_check(not BotTactics.provokes(M.PASSIVE, bot, human, enemy),
			"Passive does not join a fight a human started")
	enemy.struck_by(1)
	_check(not BotTactics.provokes(M.DEFENSIVE, bot, human, enemy),
			"Defensive does not count its own strikes as provocation")
	enemy._last_hit_at_ms = -1

	human.hurt_by(enemy)
	for mode in [M.DEFENSIVE, M.STEALTH]:
		_check(BotTactics.provokes(mode, bot, human, enemy),
				"%s defends a hurt human" % Roster.BOT_MODE_NAMES[mode])
	_check(not BotTactics.provokes(M.PASSIVE, bot, human, enemy),
			"Passive leaves party combat to its protection specialists")
	human.last_hurt_by = null

	bot.hurt_by(enemy)
	_check(BotTactics.provokes(M.PASSIVE, bot, human, enemy), "Passive answers its own attacker")
	_check(not BotTactics.provokes(M.DEFENSIVE, bot, human, enemy),
			"Defensive only joins the human player's fights")
	_check(BotTactics.provokes(M.STEALTH, bot, human, enemy),
			"Stealth still defends itself when discovered")
	bot.last_hurt_by = null

	human.stealthed = true
	_check(BotTactics.sneaking_with(M.STEALTH, bot, human), "Stealth sneaks with a sneaking human")
	_check(not BotTactics.sneaking_with(M.DEFENSIVE, bot, human), "other modes never sneak")
	_check(not BotTactics.wants_blade(M.STEALTH, bot, human, true),
			"a sneaking bot keeps the blade sheathed")
	_check(BotTactics.provokes(M.STEALTH, bot, human, enemy),
			"a sneaking bot stalks an unaware monster")
	enemy.aware(true)
	_check(not BotTactics.provokes(M.STEALTH, bot, human, enemy),
			"a sneaking bot leaves an alert monster alone")
	enemy.aware(false)
	bot.sneak = 10.0
	_check(not BotTactics.provokes(M.STEALTH, bot, human, enemy),
			"no stealth strike without the meter for it")
	bot.sneak = 100.0
	bot.hurt_by(enemy)
	_check(not BotTactics.sneaking_with(M.STEALTH, bot, human),
			"a bot under attack stops sneaking")
	bot.last_hurt_by = null
	human.stealthed = false
	_check(not BotTactics.sneaking_with(M.STEALTH, bot, human)
			and not BotTactics.provokes(M.STEALTH, bot, human, enemy),
			"Stealth falls back to Defensive when the human stops sneaking")

	_check(not BotTactics.wants_blade(M.PASSIVE, bot, human, false)
			and BotTactics.wants_blade(M.PASSIVE, bot, human, true),
			"Passive draws only when there is a fight")
	_check(BotTactics.wants_blade(M.DEFENSIVE, bot, human, false),
			"Defensive keeps the blade ready")
	_check(BotTactics.follow_reach(M.PASSIVE, 155.0) < 155.0
			and BotTactics.follow_reach(M.AGGRESSIVE, 155.0) == 155.0,
			"Passive follows closer")
	world.queue_free()
	await _frames(2)


func _pause_checks() -> void:
	Roster.clear()
	Roster.join(PlayerInput.KEYBOARD)
	var menu: CanvasLayer = load("res://scenes/menuscreens/pauseMenu.tscn").instantiate()
	add_child(menu)
	await _frames(1)
	var button: Button = menu.get_node("Center/Panel/Margin/MainMenu/Teammates")
	menu._show_main_menu()
	_check(not button.visible, "no AI TEAMMATES entry without bots")
	Roster.add_bot()
	Roster.add_bot()
	menu._show_main_menu()
	_check(button.visible, "AI TEAMMATES entry appears with bots")
	menu._on_teammates_pressed()
	var rows: Node = menu.get_node("Center/Panel/Margin/TeammatesMenu/Rows")
	_check(rows.get_child_count() == 2, "one row per bot")
	var first := rows.get_child(0) as Button
	_check(first.text == "AI2: DEFENSIVE", "row names the bot and its mode")
	first.pressed.emit()
	_check(Roster.mode_of(1) == Roster.BotMode.STEALTH and first.text == "AI2: STEALTH",
			"pressing a row cycles that bot's mode")
	_check(Roster.mode_of(2) == Roster.BotMode.DEFENSIVE, "other bots are untouched")
	menu._on_teammates_pressed()
	_check(rows.get_child_count() == 2, "reopening does not duplicate rows")
	menu._on_teammates_back_pressed()
	_check(menu.main_menu.visible and not menu.teammates_menu.visible, "back returns to main menu")

	# With no roster the menu deliberately reads project defaults, which keeps
	# this independent of the developer's saved remapping profile.
	Roster.clear()
	menu._rebuild_pausers()
	# Drive the menu explicitly below so test-node scheduling cannot make the
	# synthetic event land just before or just after the menu's own _process.
	menu.set_process(false)
	for key in [KEY_ESCAPE, KEY_BACKSPACE, KEY_Q]:
		_key(key, true)
		await get_tree().process_frame
		menu._process_standalone()
		_check(get_tree().paused and menu.visible,
				"%s opens pause and freezes solo simulation" % OS.get_keycode_string(key))
		_check(menu.process_mode == Node.PROCESS_MODE_ALWAYS,
				"pause menu remains interactive while the tree is paused")
		_key(key, false)
		await get_tree().process_frame
		menu._process_standalone()
		_key(key, true)
		await get_tree().process_frame
		menu._process_standalone()
		_check(not get_tree().paused and not menu.visible,
				"%s closes pause and resumes solo simulation" % OS.get_keycode_string(key))
		_key(key, false)
		await get_tree().process_frame
		menu._process_standalone()

	# A network client owns only a local overlay. Pausing its SceneTree would
	# freeze interpolation, cameras, weather and all remote actors while the
	# authoritative server continued the match underneath it.
	NetworkManager.is_client = true
	NetworkManager.set_physics_process(false)
	_key(KEY_ESCAPE, true)
	await get_tree().process_frame
	menu._process_standalone()
	_check(menu.visible and not get_tree().paused,
			"online pause opens locally without freezing client simulation")
	_key(KEY_ESCAPE, false)
	await get_tree().process_frame
	menu._process_standalone()
	menu._on_resume_pressed()
	_check(not menu.visible and not get_tree().paused, "online Resume closes the local overlay")
	NetworkManager.is_client = false
	NetworkManager.set_physics_process(true)
	menu.queue_free()
	await _frames(2)


func _run_frames(count: int, each: Callable = Callable()) -> void:
	for _i in count:
		if each.is_valid():
			each.call()
		await get_tree().physics_frame


## The real player scene as the bot, a probe human and a kappa-sized dummy, so
## every mode is seen to work through the actual state machine.
func _live_checks() -> void:
	Roster.clear()
	Roster.join(PlayerInput.KEYBOARD)
	Roster.add_bot()
	_world = TestWorld.new()
	add_child(_world)
	var human := ModeProbe.new()
	human.slot = 0
	human.position = Vector2(-200, 0)
	human.add_to_group("player")
	_shape(human, Vector2(64, 32))
	_world.add_child(human)
	var bot = load("res://scenes/characters/Kitsune.tscn").instantiate()
	bot.slot = 1
	_world.add_child(bot)
	bot.add_collision_exception_with(human)
	human.add_collision_exception_with(bot)
	var enemy := EnemyProbe.new()
	enemy.position = Vector2(95, 0)
	enemy.collision_layer = 3
	enemy.add_to_group("enemy")
	var body_shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 36.0
	body_shape.shape = circle
	enemy.add_child(body_shape)
	var hitbox := Area2D.new()
	hitbox.collision_layer = 2
	hitbox.collision_mask = 0
	var torso := CollisionShape2D.new()
	var capsule := CapsuleShape2D.new()
	capsule.radius = 35.0
	capsule.height = 184.0
	torso.position = Vector2(0, -54)
	torso.shape = capsule
	hitbox.add_child(torso)
	enemy.add_child(hitbox)
	_world.add_child(enemy)
	var input := bot.input as BotInput
	_check(input != null, "real player scene binds bot input")
	var machine: FiniteStateMachine = bot.get_node("FiniteStateMachine")

	await _run_frames(240)
	_check(enemy.hits == 0 and input._living(input._target) == null,
			"Defensive leaves an unprovoked monster alone")
	_check(bot.katana_drawn, "Defensive keeps the blade ready")

	await _run_frames(300, func() -> void: human.hurt_by(enemy))
	_check(enemy.hits > 0, "Defensive strikes the monster that hurt its human")
	human.last_hurt_by = null

	Roster.set_mode(1, Roster.BotMode.PASSIVE)
	input._engaged_until_ms = 0
	## A swing already in the air when the mode changes still lands.
	await _run_frames(60)
	enemy.hits = 0
	await _run_frames(300, func() -> void: enemy.struck_by(0))
	_check(enemy.hits == 0, "Passive stays out of a fight its human started")
	_check(not bot.katana_drawn, "Passive sheathes when there is nothing to protect")
	enemy._last_hit_at_ms = -1

	## An injured teammate makes Passive complete its real dance and heal. Stop
	## on the first completion so a still-injured party does not start a second.
	human.health = 50.0
	var dance_started := false
	for _i in 600:
		await get_tree().physics_frame
		dance_started = dance_started or machine.current_state.name == &"seductiveDance"
		if human.health > 50.0:
			break
	_check(dance_started and is_equal_approx(human.health, 60.0),
			"Passive completes the dance to heal an injured teammate by ten percent")
	_check(bot.stamina <= bot.max_stamina * 0.751 and bot.sneak <= bot.max_sneak * 0.751,
			"Passive dance pays one quarter of stamina and stealth")
	human.health = human.max_health

	Roster.set_mode(1, Roster.BotMode.STEALTH)
	human.stealthed = true
	enemy.aware(true)
	enemy.hits = 0
	var hid := [false]
	await _run_frames(240, func() -> void: hid[0] = hid[0] or bot.stealthed)
	if not hid[0]:
		print("Stealth diagnostic: state=", machine.current_state.name, " position=", bot.position,
				" drawn=", bot.katana_drawn, " cooldown=", input._draw_left,
				" actionBlocked=", bot.actionBlockInput, " sneak=", bot.sneak)
	_check(hid[0] and not bot.katana_drawn, "Stealth sneaks with its sneaking human")
	_check(enemy.hits == 0, "Stealth leaves an alert monster alone")
	enemy.aware(false)
	var struck := [false]
	await _run_frames(300, func() -> void:
		struck[0] = struck[0] or machine.current_state.name == &"flair")
	_check(struck[0] and enemy.hits > 0, "Stealth strikes an unaware monster from cover")
	human.stealthed = false
	await _run_frames(120)
	_check(not bot.stealthed, "Stealth leaves cover when its human does")

	Roster.set_mode(1, Roster.BotMode.AGGRESSIVE)
	enemy.hits = 0
	await _run_frames(300)
	_check(enemy.hits > 0, "Aggressive attacks unprovoked")
	enemy.is_dead = true
	var distant := EnemyProbe.new()
	distant.position = Vector2(1600, 0)
	distant.add_to_group("enemy")
	_world.add_child(distant)
	input._target = null
	input._choose_target(bot)
	_check(input._living(input._target) == distant,
			"Aggressive hunts a living enemy beyond sight and the party leash")
	distant.position = Vector2(2400, 0)
	input._choose_target(bot)
	_check(input._living(input._target) == distant,
			"Aggressive keeps hunting its target until that enemy dies")
	_world.queue_free()
	await _frames(2)


func _run() -> void:
	for path in ["res://scripts/system/CharacterSelect.gd", "res://scripts/system/HUD.gd",
			"res://scripts/system/PauseMenu.gd", "res://scripts/system/BotTactics.gd",
			"res://scripts/system/BotInput.gd"]:
		_check(load(path) != null, "script loads: " + path)
	_roster_checks()
	_memory_checks()
	await _tactics_checks()
	await _pause_checks()
	await _live_checks()
	Roster.clear()
	print("AI modes: %d checks, %d failures" % [_checks, _failed])
	get_tree().quit(1 if _failed else 0)
