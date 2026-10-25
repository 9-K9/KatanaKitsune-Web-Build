extends PlayerClass

## Dodge roll. Carries her a fixed distance and cannot be cancelled, so spending
## it is a commitment; she is untouchable for most of it.
##
## Runs for exactly as long as the clip does. It used to stop on a 0.55s timer
## against 1.6s of art, which cut it off mid-tumble. The art is drawn at 5fps,
## too slow to read as evasive, so it plays at double rate instead.
const RATE: float = 2.0
const ROLL_SPEED: float = 260.0

var _heading: Vector2 = Vector2.ZERO
var _length: float = 0.0

func on_enter():
	AudioManager.play_for("sfx_player_roll", pc)
	AudioManager.play_for("vox_kitsune_movement", pc, -7.0)
	pc.actionBlockInput = true
	## Rolls the way she is facing if she is standing still.
	var input: Vector2 = pc.InputHandler()
	_heading = input if input != Vector2.ZERO else pc.stateDirection(pc.facing_dir)
	pc.is_invincible = true
	_length = play_oneshot("forwardRoll", RATE)
	action_timer.wait_time = _length
	action_timer.start()

func on_physics_process(_delta):
	## Sheds speed across the roll so she settles rather than stopping dead.
	var t: float = 1.0 - clampf(action_timer.time_left / _length, 0.0, 1.0)
	pc.velocity = _heading.normalized() * ROLL_SPEED * (1.0 - t * 0.7)
	pc.velocity.y *= 0.5
	pc.move_and_slide()
	if action_timer.is_stopped():
		change_state("katanaIdle" if pc.katana_drawn else "idle")

func on_exit():
	pc.is_invincible = false
	pc.actionBlockInput = false
	animated_sprite.speed_scale = 1.0
	action_timer.stop()
