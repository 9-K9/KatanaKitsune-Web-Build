extends PlayerClass

## Left alone this long beside a chair she sits down, and sitting mends her — so
## resting is a real option between fights rather than something only potions can
## do. Only a chair: the sit-on-the-floor clip does not hold up, and requiring
## furniture gives chairs a reason to exist beyond decoration.
const REST_AFTER: float = 3.0

var _still_for: float = 0.0

func on_enter():
	pc.speed = 0.0
	_still_for = 0.0

# Called every frame when this state is active.
func on_process(delta):
	stateAnimation("idle")
	var input: Vector2 = pc.InputHandler()
	if 	input != Vector2.ZERO and pc.input.pressed("Run"):
		change_state("slowRun" if winded() else "run")
		return
	elif input != Vector2.ZERO:
		change_state("walk")
		return

	if pc.input.just_pressed("Katana"):
		change_state("katanaDraw")
	if pc.input.just_pressed("Attack"):
		change_state("midKick")
	if pc.input.just_pressed("Stealth"):
		if pc.can_sneak():
			change_state("stealthIdle")
			return
	if pc.input.just_pressed("Dodge"):
		change_state("forwardRoll")
	if pc.input.just_pressed("Jump"):
		change_state("runningJump")
	## Unarmed, Defend begins the risky party-healing dance.
	if pc.input.just_pressed("Defend"):
		if pc.can_dance_heal():
			change_state("seductiveDance")
		else:
			AudioManager.play("ui_error", -4.0)
		return

	_still_for += delta
	if _still_for >= REST_AFTER and chair_underfoot() != null:
		change_state("sittingChair")

func on_physics_process(delta):
	pass

func on_exit():
	pass
