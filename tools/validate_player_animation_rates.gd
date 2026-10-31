extends Node

var _checks := 0
var _failed := 0


func _ready() -> void:
	call_deferred("_run")


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failed += 1
		push_error(message)


func _run() -> void:
	Roster.clear()
	Roster.join(PlayerInput.KEYBOARD)
	var body = load("res://scenes/characters/Kitsune.tscn").instantiate()
	get_tree().root.add_child(body)
	body.set_physics_process(false)
	var fsm := body.get_node("FiniteStateMachine") as FiniteStateMachine
	fsm.process_mode = Node.PROCESS_MODE_DISABLED
	var idle := fsm.get_node("idle") as PlayerClass
	var dance := fsm.get_node("seductiveDance") as PlayerClass
	var sprite := idle.animated_sprite
	for facing in WorldObjects.FACINGS:
		body.facing_dir = facing
		for clip in ["idle", "katanaIdle", "stealthIdle"]:
			idle.stateAnimation(clip)
			_check(sprite.animation == "%s_%s" % [clip, facing]
					and sprite.speed_scale == 0.5, clip + " runs at half speed: " + facing)
		var normal_duration := dance.clip_length("seductiveDance")
		body.stamina = body.max_stamina
		body.sneak = body.max_sneak
		dance.on_enter()
		_check(sprite.speed_scale == 0.5
				and is_equal_approx(dance.action_timer.wait_time, normal_duration * 2),
				"dance playback and state duration are doubled: " + facing)
		_check(is_equal_approx(body.stamina, body.max_stamina * 0.75)
				and is_equal_approx(body.sneak, body.max_sneak * 0.75),
				"dance spends one quarter of both resources: " + facing)
		dance.on_exit()
		_check(sprite.speed_scale == 1.0, "dance restores playback on exit")
		idle.stateAnimation("walk")
		_check(sprite.speed_scale == 1.0, "movement returns to normal playback")
		idle.stateAnimation("idle")
		var attack := fsm.get_node("katanaSlashStand") as PlayerClass
		var attack_duration := idle.clip_length("katanaSlashMid")
		attack.on_enter()
		_check(is_equal_approx(attack.action_timer.wait_time, attack_duration / 1.4)
				and is_equal_approx(sprite.speed_scale, 1.4),
				"attack timing remains unchanged: %s / %s at %s" % [
					attack.action_timer.wait_time, attack_duration / 1.4, sprite.speed_scale])
		attack.on_exit()
	body.queue_free()
	await get_tree().process_frame
	for species in ["jorogumo", "yukiOnna", "kappa"]:
		var enemy := load("res://scenes/monsters/%s.tscn" % species).instantiate() as EnemyBase
		get_tree().root.add_child(enemy)
		enemy.set_physics_process(false)
		enemy.state_machine.process_mode = Node.PROCESS_MODE_DISABLED
		for facing in WorldObjects.FACINGS:
			enemy.facing_dir = facing
			enemy.play_loop("idle")
			_check(enemy.animated_sprite.speed_scale == 0.5, species + " idle plays at half speed")
			enemy.play_loop("walk")
			_check(enemy.animated_sprite.speed_scale == 1.0, species + " walk speed unchanged")
			if species != "kappa":
				enemy.state_machine.get_node("weave").on_enter()
				_check(enemy.animated_sprite.speed_scale == 0.5,
						species + " bubble dance plays at half speed")
			else:
				enemy.play_once("taunt")
				_check(enemy.animated_sprite.speed_scale == 1.0,
						"kappa fall is not mistaken for a dance")
			enemy.play_once("attack")
			_check(enemy.animated_sprite.speed_scale == 1.0, species + " attack speed unchanged")
			if enemy.collision_tween != null and enemy.collision_tween.is_playing():
				_check(enemy.collision_tween.speed_scale == enemy.animated_sprite.speed_scale,
						"collision animation rate follows sprite playback")
		enemy.queue_free()
		await get_tree().process_frame
	Roster.clear()
	print("Character animation rates: %d checks, %d failures" % [_checks, _failed])
	get_tree().quit(1 if _failed else 0)
