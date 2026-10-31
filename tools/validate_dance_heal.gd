extends Node

## Focused headless validation for the healing dance contract.
##
## godot --headless --path . --scene res://tools/validate_dance_heal.tscn

class TestWorld extends Node2D:
	func bot_controls_active() -> bool:
		return true


var _checks: int = 0
var _failed: int = 0


func _ready() -> void:
	call_deferred("_run")


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failed += 1
		push_error(message)


func _player(world: Node2D, slot: int, at: Vector2) -> CharacterBody2D:
	var body = load("res://scenes/characters/Kitsune.tscn").instantiate()
	body.slot = slot
	body.position = at
	world.add_child(body)
	body.set_physics_process(false)
	body.get_node("FiniteStateMachine").process_mode = Node.PROCESS_MODE_DISABLED
	return body


func _run() -> void:
	Roster.clear()
	Roster.join(PlayerInput.KEYBOARD)
	Roster.add_bot()
	var world := TestWorld.new()
	add_child(world)
	var dancer := _player(world, 0, Vector2.ZERO)
	var teammate := _player(world, 1, Vector2(120, 0))
	var enemy := load("res://scenes/monsters/kappa.tscn").instantiate() as EnemyBase
	enemy.position = Vector2(180, 0)
	world.add_child(enemy)
	enemy.set_physics_process(false)
	enemy.state_machine.process_mode = Node.PROCESS_MODE_DISABLED

	var machine := dancer.get_node("FiniteStateMachine") as FiniteStateMachine
	var dance := machine.get_node("seductiveDance") as PlayerClass
	dancer.health = 50.0
	teammate.health = 40.0
	dancer.stamina = dancer.max_stamina
	dancer.sneak = dancer.max_sneak
	machine.change_state("seductiveDance")
	_check(is_equal_approx(dancer.stamina, dancer.max_stamina * 0.75)
			and is_equal_approx(dancer.sneak, dancer.max_sneak * 0.75),
			"dance charges 25 percent of both resources when it starts")
	_check(enemy.player() == dancer and enemy.sees_player(),
			"a nearby monster locks onto the noisy dancer")
	machine.change_state("idle")
	_check(is_equal_approx(dancer.health, 50.0) and is_equal_approx(teammate.health, 40.0),
			"an interrupted dance heals nobody")

	dancer.stamina = dancer.max_stamina
	dancer.sneak = dancer.max_sneak
	machine.change_state("seductiveDance")
	dance.action_timer.stop()
	dance.on_physics_process(0.0)
	_check(is_equal_approx(dancer.health, 60.0) and is_equal_approx(teammate.health, 50.0),
			"finishing the full dance heals every living party member by 10 percent")

	teammate.is_dead = true
	teammate.health = 0.0
	var healed: int = dancer.complete_dance_heal()
	_check(healed == 1 and is_equal_approx(dancer.health, 70.0)
			and is_equal_approx(teammate.health, 0.0),
			"dance healing does not revive a fallen party member")
	teammate.is_dead = false

	dancer.stamina = dancer.max_stamina
	dancer.sneak = dancer.max_sneak
	var four_paid: bool = true
	for _attempt in 4:
		four_paid = four_paid and dancer.begin_dance_heal()
	_check(four_paid and is_zero_approx(dancer.stamina) and is_zero_approx(dancer.sneak),
			"four consecutive dances exhaust both full resource bars exactly")
	_check(not dancer.begin_dance_heal(), "a fifth dance waits for resources to recover")

	world.queue_free()
	await get_tree().process_frame
	Roster.clear()
	print("Dance heal: %d checks, %d failures" % [_checks, _failed])
	get_tree().quit(1 if _failed else 0)
