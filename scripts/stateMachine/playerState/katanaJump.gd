extends PlayerClass

## A hop with the blade out. Short, and it clears nothing — repositioning, not traversal.
##
## Lasts exactly as long as its clip; a hardcoded timer used to end it early.
## The arc is the point — without lifting her off the floor this read as a slide.
const RATE: float = 2.0
const HOP_SPEED: float = 210.0
const PEAK: float = 30.0

var _heading: Vector2 = Vector2.ZERO
var _length: float = 0.0
var _rest_offset: Vector2 = Vector2.ZERO

func on_enter():
	AudioManager.play_for("sfx_player_jump_takeoff", pc)
	AudioManager.play_for("vox_kitsune_movement", pc, -7.0)
	pc.actionBlockInput = true
	var input: Vector2 = pc.InputHandler()
	_heading = input if input != Vector2.ZERO else pc.stateDirection(pc.facing_dir)
	_rest_offset = animated_sprite.offset
	_length = play_oneshot("katanaJump", RATE)
	action_timer.wait_time = _length
	action_timer.start()

func on_physics_process(_delta):
	var t: float = 1.0 - clampf(action_timer.time_left / _length, 0.0, 1.0)
	## Parabola: on the floor at both ends, highest halfway through.
	animated_sprite.offset = _rest_offset + Vector2(0.0, -PEAK * 4.0 * t * (1.0 - t))
	## Eases out so the landing is not a hard stop.
	pc.velocity = _heading.normalized() * HOP_SPEED * (1.0 - t * 0.5)
	pc.velocity.y *= 0.5
	pc.move_and_slide()
	if action_timer.is_stopped():
		AudioManager.play_for("sfx_player_land", pc, -4.0)
		change_state("katanaIdle")

func on_exit():
	animated_sprite.offset = _rest_offset
	animated_sprite.speed_scale = 1.0
	pc.actionBlockInput = false
	action_timer.stop()
