extends AnimatedCharacterClass

## This player's controls, bound to their own device. Every state asks this
## rather than the global Input, because Input.is_action_pressed answers for any
## device — with four pads connected, one player's Attack would swing all four
## katanas.
var input: PlayerInput = null
## Which player this is. Slot 0 is player one; the maze sets this when it spawns
## her, and it decides the device, the colour scheme and the marker underfoot.
var slot: int = 0

## Reviving a fallen team-mate: stand over them and drop into a sneak.
##
## It costs the whole sneak meter and drains fast — a few seconds crouched over
## the body, not a chore, but it spends the thing that keeps you hidden, so
## picking someone up in front of a monster is a real decision.
@export var revive_drain: float = 42.0
## Ground reach to a fallen body, measured unsquashed like every other distance
## in an isometric room.
##
## Generous on purpose. "Standing over" someone never means sharing their exact
## position — she is about 66 across, so two characters pressed together already
## sit over a hundred units apart once the isometric squash is undone. At 110 a
## player who looked like they were on the body was measured at 132 and the
## revive silently never started.
@export var revive_reach: float = 190.0
## Share of their health a revived player comes back with.
@export var revive_health: float = 0.5

## The dance is a party heal with a deliberate four-use budget. Both resources
## are charged from their maximum values, so upgrades do not make the fourth
## attempt fail by a fraction and day/night cost modifiers do not distort it.
@export_range(0.0, 1.0, 0.01) var dance_resource_fraction: float = 0.25
@export_range(0.0, 1.0, 0.01) var dance_heal_fraction: float = 0.10

@onready var timerTimeOut : bool = false
@onready var actionBlockInput : bool = false

## Her six scroll slots. Read by the HUD, filled by scroll pickups.
var scrolls: ScrollInventory = ScrollInventory.new()
var _scroll_input_frame: int = -1

## What the blade is currently over. Resolved once — the attack code used to
## re-look this up by string path on every swing.
@onready var action_area: Area2D = $CollisionChecker/RayCast2D/ActionArea

## Every light she carries, hooded while she sneaks: one that stays at full
## brightness makes a nonsense of hiding, and it is the clearest read on the
## stance she is in that does not involve looking at the HUD.
##
## Gathered lazily rather than with @onready, because the bright one is not in
## her scene at all — MazeDemo adds a "Lantern" child at runtime, after her
## _ready has already run. Hooding only the scene's own PointLight2D dimmed a
## light contributing almost nothing next to it, so nothing appeared to happen.
var _lights: Array[PointLight2D] = []
var _light_base: Array[Vector3] = []
## What the lantern drops to while hidden. Dimmer and tighter, not out — going
## dark would just make the floor unreadable and sneaking unplayable.
@export var sneak_light_energy: float = 0.6
@export var sneak_light_size: float = 0.7
## Eased rather than switched, so it hoods and opens rather than popping.
@export var light_fade_speed: float = 6.0

## Things a katana swing is allowed to damage. Ordinary body contact is not a
## hit, so this is only ever consulted on an attack's hit frame.
const HITTABLE_GROUPS: PackedStringArray = ["enemy", "breakable"]

func _ready() -> void:
	health = max_health
	## Falls back to the keyboard when nothing has claimed a slot, so running the
	## maze scene directly still gives a playable character.
	if input == null:
		input = Roster.gameplay_input_for(slot) if Roster.count() > slot else PlayerInput.new()
	input.bind_body(self)
	if NetworkManager.is_client:
		var machine := get_node_or_null("FiniteStateMachine")
		if machine != null:
			machine.process_mode = Node.PROCESS_MODE_DISABLED
	## Rebuilt whenever this slot's device changes. A PlayerInput binds to one
	## device index at construction, and a slot can be adopted by a different pad
	## when the original is unplugged — so without this a reconnected player
	## holds an input pointed at a controller that is no longer there and simply
	## cannot move. That is not a cable fault; it happens every time the
	## replacement pad has a different index.
	if not Roster.device_regained.is_connected(_rebind):
		Roster.device_regained.connect(_rebind)
	Roster.party_control_changed.connect(_on_party_control_changed)
	## Repaint into this player's chosen aspect. Only the sheets behind each
	## frame change, so every animation, region and timing is untouched. The
	## index is per-player now: four players wear four different colours, and
	## their own hair/skin tone besides.
	var sprite := get_node_or_null("AnimationManager/AnimatedSprite2D")
	if sprite != null:
		var has_slot := Roster.count() > slot
		PowerState.apply_to(
			sprite,
			Roster.scheme_of(slot) if has_slot else -1,
			Roster.hair_of(slot) if has_slot else -1,
			Roster.skin_of(slot) if has_slot else -1
		)
	var hitbox = $CollisionChecker/PlayerHitBox
	hitbox.body_entered.connect(_on_player_hit_box_body_entered)


## Everything inside the blade right now that can take a hit.
##
## The single answer to "what am I aiming at". Targeting used to be resolved
## two different ways — a cached enemyBody kept in sync by Area2D signals, and
## a separate live overlap query inside playerAttack — which could disagree,
## and the cache only ever held one body.
func blade_targets() -> Array[Node2D]:
	var found: Array[Node2D] = []
	if not is_instance_valid(action_area):
		return found
	for body in action_area.get_overlapping_bodies():
		if not is_instance_valid(body) or not body.has_method("take_damage"):
			continue
		for group in HITTABLE_GROUPS:
			if body.is_in_group(group):
				found.append(body)
				break
	## Enemies also carry a HitBox — a tight capsule over the torso, separate
	## from the wide walking collision — so a swing can land through that too,
	## not only through the body shape a monster uses to not wedge into walls.
	for area in action_area.get_overlapping_areas():
		if not is_instance_valid(area):
			continue
		var owner_body: Node2D = Breakable.hit_target(area)
		if not is_instance_valid(owner_body) or not owner_body.has_method("take_damage"):
			continue
		if found.has(owner_body):
			continue
		for group in HITTABLE_GROUPS:
			if owner_body.is_in_group(group):
				found.append(owner_body)
				break
	return found


func can_slash_target(target: Node2D, facing: String, from: Vector2 = Vector2.INF) -> bool:
	var shape := action_area.get_node("CollisionShape2D") as CollisionShape2D
	var tween := get_node("CollisionChecker/WeaponTween") as AnimationPlayer
	var sprite := get_node("AnimationManager/AnimatedSprite2D") as AnimatedSprite2D
	var clip := "katanaSlashMid"
	var animation_name := "%s_%s" % [clip, facing]
	if not tween.has_animation(animation_name) or not sprite.sprite_frames.has_animation(animation_name):
		push_error("Player: missing slash reach animation %s" % animation_name)
		return false
	var frames := sprite.sprite_frames
	var hit_time: float = 0.0
	for i in 3:
		hit_time += frames.get_frame_duration(animation_name, i)
	hit_time /= frames.get_animation_speed(animation_name)
	var animation := tween.get_animation(animation_name)
	var reach: Vector2 = shape.position
	for track in animation.get_track_count():
		if animation.track_get_type(track) == Animation.TYPE_VALUE \
				and String(animation.track_get_path(track)).ends_with("ActionArea/CollisionShape2D:position"):
			var value: Variant = animation.value_track_interpolate(track, hit_time)
			if value is Vector2:
				reach = value
	var query := PhysicsShapeQueryParameters2D.new()
	# Require overlap depth, not tangency: sprite and physics hit frames can
	# differ by a tick. The real weapon shape is never modified.
	var probe := shape.shape.duplicate() as Shape2D
	if probe is CircleShape2D:
		probe.radius = maxf(probe.radius - 4.0, 1.0)
	query.shape = probe
	query.transform = shape.global_transform
	query.transform.origin = action_area.to_global(reach)
	if from != Vector2.INF:
		query.transform.origin += from - global_position
	query.collision_mask = action_area.collision_mask
	query.collide_with_areas = true
	query.exclude = [get_rid()]
	for hit in get_world_2d().direct_space_state.intersect_shape(query, 32):
		if hit["collider"] == target or Breakable.hit_target(hit["collider"]) == target:
			return true
	return false



func _on_death() -> void:
	$FiniteStateMachine.change_state("death")
	_refresh_party_control()


func revive(fraction: float = 0.5) -> void:
	super.revive(fraction)
	_refresh_party_control()


## A dance must be paid for up front. If the dancer is interrupted the spent
## stamina and stealth stay spent, but the party receives no heal.
func can_dance_heal() -> bool:
	if is_dead or max_stamina <= 0.0 or max_sneak <= 0.0:
		return false
	return stamina + 0.001 >= max_stamina * dance_resource_fraction \
			and sneak + 0.001 >= max_sneak * dance_resource_fraction


func begin_dance_heal() -> bool:
	if not can_dance_heal():
		return false
	stamina = maxf(stamina - max_stamina * dance_resource_fraction, 0.0)
	sneak = maxf(sneak - max_sneak * dance_resource_fraction, 0.0)
	_stamina_rested_for = 0.0
	_sneak_used_this_frame = true
	return true


## The animation itself is exertion, not rest. Called for every physics frame
## of a live dance so neither bar refills before its completion or interruption.
func hold_dance_resources() -> void:
	_stamina_rested_for = 0.0
	_sneak_used_this_frame = true


## Used by Passive AI so it does not dance at full party health.
func party_needs_dance_heal() -> bool:
	if not is_inside_tree():
		return false
	for member in Roster.bodies(get_tree()):
		var current: Variant = member.get("health")
		var maximum: Variant = member.get("max_health")
		if typeof(current) not in [TYPE_INT, TYPE_FLOAT] \
				or typeof(maximum) not in [TYPE_INT, TYPE_FLOAT]:
			continue
		if float(current) < float(maximum) - 0.001:
			return true
	return false


## Completes the skill. Fallen players remain fallen; reviving is still the
## Passive companion's first responsibility and the dedicated revive mechanic
## keeps its own cost and risk.
func complete_dance_heal() -> int:
	if is_dead or not is_inside_tree():
		return 0
	var healed: int = 0
	for member in Roster.bodies(get_tree()):
		var maximum_value: Variant = member.get("max_health")
		var health_value: Variant = member.get("health")
		if typeof(maximum_value) not in [TYPE_INT, TYPE_FLOAT] \
				or typeof(health_value) not in [TYPE_INT, TYPE_FLOAT]:
			continue
		var maximum: float = float(maximum_value)
		var before: float = float(health_value)
		var after: float = minf(before + maximum * dance_heal_fraction, maximum)
		if after <= before:
			continue
		member.set("health", after)
		healed += 1
	if healed > 0:
		AudioManager.play_for("sfx_pickup_health", self)
	return healed


func _refresh_party_control() -> void:
	var world := get_parent()
	if world != null and world.has_method("refresh_party_control"):
		world.refresh_party_control()
		
func InputHandler():
	##movement based on this player's own device, not on any device at all
	direction = input.vector()
	return round(direction)

func _physics_process(_delta):
	if NetworkManager.is_client:
		return
	var world := get_parent()
	if world.has_method("bot_controls_active") and not world.bot_controls_active():
		input.prime()
		velocity = Vector2.ZERO
		return
	input.update(_delta)
	update_buffs()
	update_scroll_look()
	_read_scroll_input()
	## Unconditional: the running states call drain_stamina, which resets the rest
	## timer, so spending and recovering cannot both apply in the same frame.
	recover_stamina(_delta)
	recover_sneak(_delta)
	_try_revive(_delta)
	_hood_lantern(_delta)
	## Sampled once per frame: InputHandler() was previously called three times
	## per physics tick, and the state scripts call it twice more per frame.
	var input_dir: Vector2 = InputHandler()
	var aim: Vector2 = input.aim_vector()
	if aim != Vector2.ZERO and not actionBlockInput:
		facing_dir = directionState(round(aim.normalized()))
		updateRayCast2D(facing_dir)
	if input_dir != Vector2.ZERO and not actionBlockInput:
		if aim == Vector2.ZERO:
			facing_dir = directionState(input_dir)
			updateRayCast2D(facing_dir)
		## No delta here: move_and_slide() already integrates velocity over the
		## physics step. Multiplying by delta as well made displacement scale
		## with delta squared, so the character moved twice as fast at 30fps.
		velocity = input_dir * speed
		velocity.y = velocity.y / 2
	else:
		velocity = Vector2.ZERO
	move_and_slide()


func _notification(what: int) -> void:
	if what == NOTIFICATION_UNPAUSED and input != null:
		input.prime()


## Selection never spends a scroll. Activation requires a separate fresh press.
func _read_scroll_input() -> void:
	var frame := Engine.get_process_frames()
	if _scroll_input_frame == frame or input == null:
		return
	_scroll_input_frame = frame
	if is_dead:
		input.prime()
		return
	var previous: bool = input.pressed("ScrollPrevious")
	var next: bool = input.pressed("ScrollNext")
	if previous or next:
		if previous != next:
			var action := "ScrollPrevious" if previous else "ScrollNext"
			if input.just_pressed(action):
				scrolls.cycle(-1 if previous else 1)
				AudioManager.play("ui_scroll_select", -5.0)
		return
	for i in ScrollInventory.SLOTS:
		if input.just_pressed("Scroll%d" % (i + 1)):
			scrolls.selected = i if scrolls.kind_at(i) != -1 else scrolls.selected
			read_scroll(i)
			return
	if input.just_pressed("ScrollUse"):
		read_scroll(scrolls.selected)


## Uses one scroll from a slot. Kept, not spent, when it would do nothing,
## and never spent at all by Karmageisha, whose stacks are bottomless.
func read_scroll(index: int) -> bool:
	var kind: int = scrolls.kind_at(index)
	if kind == -1:
		AudioManager.play("ui_error", -4.0)
		return false
	if not use_scroll(kind):
		AudioManager.play("ui_error", -4.0)
		return false
	AudioManager.play_for("sfx_scroll_activate", self)
	if not CheatManager.karmageisha_active:
		scrolls.take(index)
	return true
## Brings her lights towards where the current stance wants them.
func _hood_lantern(delta: float) -> void:
	_gather_lights()
	var hidden: bool = stealthed or crouched
	var t: float = clampf(delta * light_fade_speed, 0.0, 1.0)
	for i in _lights.size():
		var light: PointLight2D = _lights[i]
		if not is_instance_valid(light):
			continue
		## Each light keeps its own starting energy and scale, so the hooded
		## values stay relative to however bright it was set to be.
		var base: Vector3 = _light_base[i]
		var factor_energy: float = sneak_light_energy if hidden else 1.0
		var factor_size: float = sneak_light_size if hidden else 1.0
		light.energy = lerpf(light.energy, base.x * factor_energy, t)
		light.scale = light.scale.lerp(
				Vector2(base.y, base.z) * factor_size, t)


## Picks up any light she is carrying, including ones added after _ready. Cheap
## enough to re-check: the loop stops at the first frame where the count matches.
func _gather_lights() -> void:
	var found: Array[PointLight2D] = []
	for node in find_children("*", "PointLight2D", true, false):
		found.append(node)
	if found.size() == _lights.size():
		return
	for light in found:
		if light in _lights:
			continue
		_lights.append(light)
		## Captured the first time it is seen, before anything has dimmed it.
		_light_base.append(Vector3(light.energy, light.scale.x, light.scale.y))


## Spends the sneak meter to bring a fallen team-mate back.
##
## Draining rather than a button press, so the cost is visible on the eye's ring
## as it happens and can be abandoned by standing up.
func _try_revive(delta: float) -> void:
	if is_dead or not (stealthed or crouched):
		return
	var fallen := _fallen_underfoot()
	if fallen == null:
		return
	drain_sneak(revive_drain, delta)
	if sneak <= 0.0:
		fallen.revive(revive_health)


## The nearest downed player within reach, or null.
func _fallen_underfoot() -> Node:
	var best: Node = null
	var best_distance: float = INF
	for node in get_tree().get_nodes_in_group("player"):
		if node == self or not (node is CharacterBody2D):
			continue
		if not (node.get("is_dead") == true):
			continue
		## Unsquashed: the map is drawn 2:1, so a body the same distance away up
		## the screen would otherwise read as twice as close as one to the side.
		var offset: Vector2 = (node as Node2D).global_position - global_position
		offset.y /= 0.5
		var distance: float = offset.length()
		if distance <= revive_reach and distance < best_distance and _revive_visible(node):
			best_distance = distance
			best = node
	return best


func _revive_visible(fallen: Node2D) -> bool:
	var ray := PhysicsRayQueryParameters2D.create(global_position, fallen.global_position,
			collision_mask)
	ray.exclude = [get_rid()]
	for player in get_tree().get_nodes_in_group("player"):
		if player is CollisionObject2D:
			ray.exclude.append(player.get_rid())
	return get_world_2d().direct_space_state.intersect_ray(ray).is_empty()


## Points this player's controls at whatever device now owns their slot.
func _rebind(for_slot: int) -> void:
	if for_slot != Roster.controller_slot(slot):
		return
	_bind_gameplay_input()


func _on_party_control_changed(previous: int, controlled: int) -> void:
	if slot == 0 or slot == previous or slot == controlled:
		_bind_gameplay_input()
		if not (input is BotInput):
			input.suppress_held_actions()
	elif input is BotInput:
		input.reset()


func _bind_gameplay_input() -> void:
	input = Roster.gameplay_input_for(slot)
	input.bind_body(self)
	## Primed, or the button that reconnected the pad reads as a fresh press on
	## the first frame back.
	input.prime()


func _on_action_timer_timeout():
	timerTimeOut = true

func _on_player_hit_box_body_entered(body):
	## Deliberately does nothing now. Monsters damage Akane from the hit frame of
	## their attack animation (EnemyBase.strike), which is telegraphed and can be
	## read and dodged. Contact damage predates that AI and meant simply brushing
	## past a monster — or walking into one still taunting — cost 10 health with
	## no wind-up to react to.
	pass
