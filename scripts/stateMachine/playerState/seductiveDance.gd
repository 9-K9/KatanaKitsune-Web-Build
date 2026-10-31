extends PlayerClass

## A risky party heal. It costs a quarter of both stamina and stealth up front,
## alerts nearby monsters, and heals only if the entire dance completes.
const TAUNT_RANGE: float = 340.0
const ALERT_SECONDS: float = 8.0

var _started: bool = false

func on_enter():
	_started = pc.begin_dance_heal()
	if not _started:
		change_state("idle")
		return
	pc.speed = 0.0
	action_timer.wait_time = play_oneshot("seductiveDance", 0.5)
	action_timer.start()
	_alert_enemies()

func on_process(_delta):
	if pc.InputHandler() != Vector2.ZERO or pc.input.just_pressed("Attack"):
		change_state("idle")

func on_physics_process(_delta):
	if not _started:
		return
	pc.hold_dance_resources()
	if action_timer.is_stopped():
		_started = false
		pc.complete_dance_heal()
		change_state("idle")

## Anything in earshot locks onto the dancer rather than merely playing its
## dialogue taunt. That target persists long enough to punish a completed heal.
func _alert_enemies() -> void:
	for enemy in pc.get_tree().get_nodes_in_group("enemy"):
		if enemy is Node2D and pc.global_position.distance_to(enemy.global_position) <= TAUNT_RANGE:
			if enemy.has_method("alert_to_player"):
				enemy.alert_to_player(pc, ALERT_SECONDS)

func on_exit():
	_started = false
	animated_sprite.speed_scale = 1.0
	action_timer.stop()
