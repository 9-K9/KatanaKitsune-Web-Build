extends AI_Class
class_name EnemyBase

signal died

## Base class for the roaming monsters.
## Owns the stats, health and hit reactions; the behaviour itself lives in the
## states under scripts/stateMachine/enemyState/, driven by the monster's
## FiniteStateMachine child the same way the player's states are.

## Which rung of the bestiary this monster is, 1 to 6. Drives what it is worth
## and, later, which behaviours it is allowed.
@export var tier: int = 1
## The scene's tier before the spawner rolls one; -1 until apply_tier runs.
var base_tier: int = -1

## What makes this monster itself, as opposed to how far up the ladder it is.
## Merged over the tier's traits in apply_tier, so it survives any rung the
## generator rolls. Set on the scene.
##
##   shell — damage multiplier for blows landing behind it (0.1 = a tenth
##           through). Kappa's carapace; the inverse of the boss's blind spot.
##   phases — sees and walks through walls. Yuki Onna's, and only hers.
@export var species_traits: Dictionary = {}
## What this tier can do, read once on ready. Looked up rather than duplicated
## onto every monster scene, so retuning a rung is one table edit.
var traits: Dictionary = {}
## True only while a duellist is actually holding its guard up. The tier's
## passive soak applies whenever it is facing a blow; this is the deeper
## reduction for a block it deliberately raised.
var guarding: bool = false
## Latched after the draw animation finishes; a fresh instance resets it.
var blade_drawn: bool = false

@export_group("Stats")
@export var max_health: float = 100.0
@export var move_speed: float = 55.0
## Ground speed while running her down, in the same units as the player's
## runSpeed (183) and walkSpeed (83). Per species rather than per tier, so the
## nimble ones close fast and the heavy ones lumber whatever rung they roll.
## 0 falls back to move_speed scaled by the tier's chase pace.
@export var run_speed: float = 0.0
@export var attack_damage: float = 12.0

@export_group("Ranges")
## All three are ground distances, not screen distances — see ground_distance_to.
## Starts chasing once the player is this close.
@export var detection_range: float = 420.0
## Stops and swings once the player is this close. Has to clear the player's own
## collision polygon, which is a tile-sized 128x64, or the monster can never get
## near enough to trigger a swing.
@export var attack_range: float = 110.0

@export_group("Timing")
## Seconds between swings.
@export var attack_cooldown: float = 0.9
## Minimum seconds spent staggered, so fast katana hits cannot stun-lock forever.
@export var hurt_lock: float = 0.3

## The map is drawn 2:1, so a step down the screen covers half the ground a step
## sideways does. Same convention as the player's movement code.
const ISO_Y_SCALE: float = 0.5

var health: float = 0.0
var is_dead: bool = false
var network_id: int = -1

@onready var health_bar: ProgressBar = get_node_or_null("HealthBar")
@onready var state_machine: FiniteStateMachine = get_node_or_null("FiniteStateMachine")
## Optional. A monster without one simply never taunts and fights on sight.
@onready var taunt: TauntComponent = get_node_or_null("TauntComponent")
## The blade's actual target — a tight capsule over the torso, separate from
## the walking CollisionShape2D so the two can be shaped for what they each
## do: one keeps the monster out of walls, the other says where a swing lands.
@onready var hit_box: Area2D = get_node_or_null("HitBox")
## Optional. Present only on monsters whose dodge/leap art visibly displaces
## the sprite within its own frame (a hop, a spin) — the engine's real
## movement never accounts for that, so CollisionShape2D/HitBox would
## otherwise sit at the sprite's resting spot while it's drawn somewhere
## else entirely. When this player has an animation sharing the AnimatedSprite2D
## clip's exact name, play_once/play_loop start it in lockstep so the shapes
## tween along with the sprite instead of trailing behind it.
@onready var collision_tween: AnimationPlayer = get_node_or_null("CollisionTween")

var _player: CharacterBody2D = null
var _flash_tween: Tween = null
var _attack_ready_at_ms: int = 0
var _nav_checked: bool = false
var _nav_usable: bool = false

## Real knockback from the last hit, decaying toward zero as enemyHurt
## consumes it. Separate from `velocity` so entering hurt can still zero out
## whatever the monster was doing (chasing, etc.) without erasing this.
var knockback_velocity: Vector2 = Vector2.ZERO


func apply_tier(to: int, wave: int = 1) -> void:
	## The scene's own rung, kept for experience before the roll replaces it.
	if base_tier < 0:
		base_tier = tier
	tier = to
	## Duplicated, not referenced. EnemyTier.of returns the shared row out of
	## its table, so trimming it in place would strip the skill from every
	## monster of that rung for the rest of the run.
	traits = EnemyTier.of(to).duplicate()
	## Species traits go on top of the rung's. A tier says how dangerous a
	## monster is; this says what kind of monster it is, and that does not change
	## when the generator hands it a different rung. Kappa keeps his shell at
	## tier 1 and at tier 6.
	traits.merge(species_traits, true)
	_drop_skills_without_states()
	## Scaled by the rung and then by how deep the run has gone, capped so a
	## long run does not become arithmetic rather than a fight.
	var deep: float = minf(1.0 + float(wave - 1) * 0.06, WAVE_CAP)
	max_health *= traits["health"] * deep
	health = max_health
	attack_damage *= traits["damage"] * deep
	if traits["phases"]:
		## Walls are not cover from this one, and it walks through them.
		set_deferred("collision_mask", 0)


## Takes away any skill this monster has no state node to perform.
##
## The generator picks the art uniformly and rolls the rung separately, so any
## scene can be handed any tier — a shambler can come up tier 6. Only the four
## duellist scenes carry block, draw and charge, and asking for a state that is
## not there logs an error and leaves current_state untouched, so the monster
## retries the same transition every frame: an error flood and a body that
## stands still instead of fighting.
##
## Trimming the traits is better than guarding each call site, because the
## traits are what every behaviour reads. One monster quietly fights a rung
## below its skill ceiling; nothing errors and nothing freezes.
func _drop_skills_without_states() -> void:
	if not is_instance_valid(state_machine):
		return
	if traits.get("duellist", false) and not state_machine.has_node("draw"):
		traits["duellist"] = false
	if traits.get("guards", false) and not state_machine.has_node("block"):
		traits["guards"] = false


## How far the wave scaling can push a monster. Past this the numbers stop
## meaning anything and a fight becomes a stalemate.
const WAVE_CAP: float = 2.5


func _ready() -> void:
	health = max_health
	if NetworkManager.is_client and is_instance_valid(state_machine):
		state_machine.process_mode = Node.PROCESS_MODE_DISABLED
	_refresh_health_bar()
	_scale_ranges_to_sprite()
	_position_collision_shape()
	_position_health_bar()
	_position_hit_box()
	_apply_random_cosmetics()
	_cache_collision_tween_deltas()


## A fresh clothing colour per spawn, so a wave of four Kasha does not read as
## one sprite copy-pasted four times. Hair and skin keep their painted colours.
## Plain randi(), not the maze's seeded RNG — this is pure cosmetics with no
## bearing on anything deterministic, the same reasoning that already applies
## to the hit-flash tween.
func _apply_random_cosmetics() -> void:
	if not is_instance_valid(animated_sprite):
		return
	var monster := scene_file_path.get_file().get_basename()
	PowerState.apply_to_enemy(animated_sprite, monster, float(randi() % 360))


## Stretches the ground ranges to match how big the monster actually reads on
## screen.
##
## AnimatedSprite2D carries a per-species scale — gashadokuro is 2.6, kamaitachi
## 0.7 — set once in the scene to make a tier read as the size it is meant to be
## (see build_enemy_scene.py's HEIGHT table and its own comment: the collision
## body is deliberately left alone, or a gashadokuro three times the size would
## wedge itself in the corridors it has to come down). That was the right call
## for the body a player's blade has to land on, but attack_range, aware_radius
## and detection_range are not a hitbox — they are how far this monster reaches
## and how far it notices, and those numbers were tuned once against a sprite
## that was not wearing a scale at all. Left alone, a gashadokuro swings from
## the same 110 units as a kamaitachi a third its visual size: a hugely telegraphed
## axe that connects from a distance that still reads as a miss, and an
## apparently cautious weasel that is already in your face. Scaling the three
## ranges by the same factor the sprite itself was scaled by keeps the mismatch
## that was fixed, fixed, instead of fixing it for everything that looks at the
## sprite and leaving everything that measures from the body still wrong.
func _scale_ranges_to_sprite() -> void:
	if not is_instance_valid(animated_sprite):
		return
	var sprite_scale: float = animated_sprite.scale.x
	## No custom scale, or a degenerate one from a scene not built this way —
	## leave the exported numbers exactly as tuned.
	if is_zero_approx(sprite_scale) or is_equal_approx(sprite_scale, 1.0):
		return
	attack_range *= sprite_scale
	detection_range *= sprite_scale
	aware_radius *= sprite_scale


## Clear air between the top of the sprite and the bar, in screen pixels.
## Small on purpose: the bar should read as sitting on the monster's head, not
## floating somewhere above the room.
const HEALTH_BAR_GAP: float = 14.0

## Fraction of the sprite's own measured content height the hit-box capsule's
## radius gets. Calibrated against mummy's idle crop (a 158px-tall, 78px-wide
## silhouette): a tight torso reads at roughly three tenths of its own
## content height, wide pose or narrow, template or boss.
const HIT_BOX_RADIUS_RATIO: float = 0.30


## Measures where the sprite's own opaque pixels actually sit, in the same
## parent-local space AnimatedSprite2D itself draws in.
##
## The monster roster was built under two incompatible conventions: templates
## from build_enemy_scene.py push the whole sprite up via a negative
## AnimatedSprite2D.position (offset left at zero), while several hand-placed
## scenes (kappa, jorogumo, karasuShinobi, tengu, oni, yukiOnna) instead leave
## position at zero and use a positive AnimatedSprite2D.offset. A fixed
## "bottom margin" constant measured off the first group reads as correct
## there and wrong everywhere else, because offset was never being read at
## all — the same silent gap that kept landing the collision circle, hit box,
## and health bar in the wrong place for exactly those six species.
##
## Reading the frame's actual opaque pixels via Image.get_used_rect() sidesteps
## guessing either a margin or a shared "content height" entirely: whichever
## convention a given scene uses, this always finds the real silhouette.
## Image.get_image() reads texture bytes directly rather than rendering, so it
## works in headless/editor contexts the same as in a full game window.
func _measure_sprite_content() -> Dictionary:
	if not is_instance_valid(animated_sprite):
		return {}
	var frames: SpriteFrames = animated_sprite.sprite_frames
	if frames == null:
		return {}
	var clip: String = animated_sprite.animation
	if not frames.has_animation(clip):
		var names: PackedStringArray = frames.get_animation_names()
		if names.is_empty():
			return {}
		clip = names[0]
	if frames.get_frame_count(clip) == 0:
		return {}
	var texture: Texture2D = frames.get_frame_texture(clip, 0)
	if texture == null:
		return {}
	var image: Image = texture.get_image()
	if image == null:
		return {}
	var used: Rect2i = image.get_used_rect()
	if used.size == Vector2i.ZERO:
		return {}
	var scale_y: float = animated_sprite.scale.y
	## AnimatedSprite2D centres the frame on `offset` before drawing (see its
	## _get_rect(): ofs = offset - size/2), so the frame's local top is offset
	## minus half the texture height, and the used rect locates the real
	## silhouette inside that frame from there.
	var local_top: float = animated_sprite.offset.y - texture.get_height() * 0.5 \
			+ used.position.y
	var local_bottom: float = local_top + used.size.y
	return {
		"top": animated_sprite.position.y + local_top * scale_y,
		"bottom": animated_sprite.position.y + local_bottom * scale_y,
	}


## Puts the walking CollisionShape2D at the sprite's own feet instead of
## trusting the scene's static position, which the node was left at (0, 0) —
## the origin, not the floor — back when it was still the shared octagon.
func _position_collision_shape() -> void:
	var shape_node: CollisionShape2D = get_node_or_null("CollisionShape2D")
	if shape_node == null or not (shape_node.shape is CircleShape2D):
		return
	var content: Dictionary = _measure_sprite_content()
	if content.is_empty():
		return
	shape_node.position = Vector2(0, content["bottom"])


## Puts the health bar just above whatever is actually on screen, instead of
## trusting the offset baked into the scene.
##
## build_enemy_scene.py measures each character's own art and writes a bar
## position to match, but that only happened for the monsters it has actually
## rebuilt since — the rest kept whatever the template shipped with, which is
## a flat 194px regardless of how tall that monster draws. Reading the sprite
## at runtime fixes every monster at once, is immune to a scene nobody has
## re-run the tool on, and costs nothing since it only runs once on spawn.
func _position_health_bar() -> void:
	if not is_instance_valid(health_bar):
		return
	var content: Dictionary = _measure_sprite_content()
	if content.is_empty():
		return
	## Keep the bar's own height, just relocate the pair of offsets together.
	var bar_height: float = health_bar.offset_bottom - health_bar.offset_top
	health_bar.offset_top = content["top"] - HEALTH_BAR_GAP
	health_bar.offset_bottom = health_bar.offset_top + bar_height


## Sizes and places the hit box the same way _position_health_bar reads the
## bar: from the live sprite, at runtime, so a scaled-up boss and an unscaled
## template both get a capsule that actually fits what is on screen, rather
## than one static size nobody has retuned per monster.
##
## This capsule is deliberately separate from the walking CollisionShape2D.
## That shape stays a uniform circle on purpose (see _scale_ranges_to_sprite's
## note on why the body is left alone) so a gashadokuro three times the size
## does not wedge itself in a corridor a kamaitachi fits down — but the same
## uniform circle is a terrible stand-in for "where a blade actually lands",
## which is what this hit box is for instead.
func _position_hit_box() -> void:
	if not is_instance_valid(hit_box):
		return
	var shape_node: CollisionShape2D = hit_box.get_node_or_null("CollisionShape2D")
	if shape_node == null or not (shape_node.shape is CapsuleShape2D):
		return
	var content: Dictionary = _measure_sprite_content()
	if content.is_empty():
		return
	var top: float = content["top"]
	var bottom: float = content["bottom"]
	var content_height: float = bottom - top
	var capsule: CapsuleShape2D = shape_node.shape as CapsuleShape2D
	capsule.radius = content_height * HIT_BOX_RADIUS_RATIO
	capsule.height = content_height
	shape_node.position = Vector2(0, (top + bottom) * 0.5)


## The player's body. Resolved lazily because the monster is spawned from code
## and may enter the tree before the player does.
func player() -> CharacterBody2D:
	## The nearest living player, re-resolved each time rather than cached.
	##
	## It used to latch onto the first body in the group and keep it forever,
	## which with four players meant every monster on the floor hunted player one
	## and walked straight past the other three.
	var best: CharacterBody2D = null
	var best_distance: float = INF
	for node in get_tree().get_nodes_in_group("player"):
		## Her hitbox Area2D is in the group too; only the body can be chased.
		if not (node is CharacterBody2D):
			continue
		if node.get("is_dead") == true:
			continue
		## Under the Invisibility scroll she is simply not there to be found.
		if node.has_method("is_invisible") and node.is_invisible():
			continue
		var world := get_parent()
		if world != null and world.has_method("safe_room_contains") \
				and world.safe_room_contains((node as Node2D).global_position):
			continue
		var distance: float = global_position.distance_squared_to(
				(node as Node2D).global_position)
		if distance < best_distance:
			best_distance = distance
			best = node
	_player = best
	return best


## Distance along the ground rather than across the screen. The map is drawn
## 2:1, so without undoing the squash the same gap measures half as far when it
## is vertical and the monster would happily swing from a screen away.
func ground_distance_to(target_position: Vector2) -> float:
	var delta: Vector2 = target_position - global_position
	delta.y /= ISO_Y_SCALE
	return delta.length()


func distance_to_player() -> float:
	var target := player()
	if target == null:
		return INF
	return ground_distance_to(target.global_position)


## Stone blocks sight. Walls sit on physics layer 1, and the ray runs between
## the two feet positions, which after the y-sort fix are both on the ground —
## so it crosses the same floor the characters walk on.
const WALL_MASK: int = 1
## How long a monster keeps hunting after losing sight of her.
@export var memory_seconds: float = 3.0
## How wide a monster's view is, in degrees. Vision is a cone rather than a
## circle so that getting behind one is worth doing — which is the whole point
## of a stealth system.
## 130° read on the radar as a half-circle rather than a cone pointed
## somewhere — this is the angle a forward-facing wedge actually looks like one
## at a glance.
@export var vision_arc_degrees: float = 100.0
## Inside this it notices her regardless of which way it is looking. Without it
## she could stand on a monster's toes unseen, which reads as broken rather than
## as stealthy.
@export var aware_radius: float = 95.0

var _last_seen_ms: int = -100000
var _sight_checked_ms: int = -100000
var _sight_cached: bool = false
var _sight_phase: int = -1
## Where she was standing when last seen, so a monster can press on to it.
var last_known: Vector2 = Vector2.ZERO


## Can this monster actually see her? Range first because it is cheap, then a
## ray, and the answer is held briefly so a crowd of monsters does not each cast
## every frame.
func sees_player() -> bool:
	var cycle := DayNightCycle.for_node(self)
	var phase: int = int(cycle.is_night()) if cycle != null else -1
	if phase != _sight_phase:
		_sight_phase = phase
		_sight_checked_ms = -100000
	var now: int = Time.get_ticks_msec()
	if now - _sight_checked_ms < 120:
		return _sight_cached
	_sight_checked_ms = now
	_sight_cached = _look_for_player()
	if _sight_cached:
		_last_seen_ms = now
		var target := player()
		if target != null:
			last_known = target.global_position
	return _sight_cached


func _look_for_player() -> bool:
	var target := player()
	if target == null or is_dead or is_petrified():
		return false
	## effective_detection already scales with how hidden she is — crouched is
	## 0.3 of the range, katana drawn is 1.5.
	var distance: float = ground_distance_to(target.global_position)
	if distance > effective_detection():
		return false
	## Outside the close-range awareness she has to be in front of it.
	if distance > aware_radius and not _within_arc(target.global_position):
		return false
	var space := get_world_2d().direct_space_state
	var query := PhysicsRayQueryParameters2D.create(
			global_position, target.global_position, WALL_MASK)
	## Without excluding these two the ray stops on whoever cast it. Other
	## monsters are left in deliberately: one standing in a doorway blocks the
	## view through it, which is the same rule the walls follow.
	query.exclude = [get_rid(), target.get_rid()]
	## A phasing monster has no line of sight to break — stone is not cover from
	## something that walks through it.
	if traits.get("phases", false):
		return true
	return space.intersect_ray(query).is_empty()


## Is `point` inside the cone this monster is looking down?
func _within_arc(point: Vector2) -> bool:
	var facing: Vector2 = stateDirection(facing_dir)
	if facing == Vector2.ZERO:
		return true
	## Both vectors get the squash undone, or the cone would be far wider
	## looking up and down the screen than across it.
	var to_target: Vector2 = point - global_position
	to_target.y /= ISO_Y_SCALE
	facing.y /= ISO_Y_SCALE
	if to_target.length_squared() < 1.0:
		return true
	## angle_to is signed, so the magnitude is what matters — a target 90 degrees
	## to the left is as visible as one 90 degrees to the right.
	var half: float = deg_to_rad(vision_arc_degrees) * 0.5
	return absf(to_target.normalized().angle_to(facing.normalized())) <= half


## Seconds since she was last actually seen.
func seconds_since_seen() -> float:
	return float(Time.get_ticks_msec() - _last_seen_ms) / 1000.0


## detection_range scaled by how well hidden she is, so crouching, sneaking and
## drawing the katana each change the range a monster wakes up at.
func effective_detection() -> float:
	var cycle := DayNightCycle.for_node(self)
	var reach: float = detection_range * (cycle.sight_factor() if cycle != null else 1.0)
	var target := player()
	if target != null and target.has_method("stealth_ratio"):
		return reach * target.stealth_ratio()
	return reach


func effective_attack_damage() -> float:
	var cycle := DayNightCycle.for_node(self)
	return attack_damage * (cycle.hostile_damage_factor() if cycle != null and is_in_group("enemy") else 1.0)


## Unit vector pointing at the player on screen, or ZERO when there is none.
## This is the straight line, used for facing and for aiming a swing.
func direction_to_player() -> Vector2:
	var target := player()
	if target == null:
		return Vector2.ZERO
	return (target.global_position - global_position).normalized()


## The direction to actually walk in. Follows a navigated path where the map
## has one, so the monster rounds corners instead of grinding along a wall.
##
## Falls back to the straight line when there is no baked navigation — the
## hand-built maps have none, and this same scene is used in both.
func chase_direction() -> Vector2:
	var target := player()
	if target == null:
		return Vector2.ZERO
	var direct: Vector2 = (target.global_position - global_position).normalized()
	if not _navigation_available():
		return direct

	nav.target_position = target.global_position
	if nav.is_navigation_finished():
		return direct
	var step: Vector2 = nav.get_next_path_position() - global_position
	## Standing almost exactly on the next waypoint makes the normalised
	## direction meaningless; keep walking the straight line for a frame.
	if step.length() < 1.0:
		return direct
	return step.normalized()


## Cached because it only changes when a map is loaded, and the answer is a
## server round-trip.
func _navigation_available() -> bool:
	if _nav_checked:
		return _nav_usable
	_nav_checked = true
	if not is_instance_valid(nav):
		_nav_usable = false
		return false
	var map: RID = nav.get_navigation_map()
	_nav_usable = map.is_valid() and NavigationServer2D.map_get_regions(map).size() > 0
	return _nav_usable


## Points the sprite along `dir`. Facing is taken from the unforeshortened
## vector so the monster looks where the player actually is on screen.
## Close enough to swing. Used by the duellist states to decide whether to
## answer a guard with a strike or close the distance first.
func in_attack_range() -> bool:
	var target := player()
	if target == null:
		return false
	return within_reach(target)


## Screen pixels of clear air between the two bodies that still count as
## pressed up against her.
const CONTACT_SLACK: float = 10.0

## True when `target` is inside attack_range * `multiplier` on the ground, or
## when the two collision bodies are (all but) touching.
##
## Range is measured between node origins on the ground, where a vertical gap
## counts double, but bodies collide as screen-space circles — and a monster's
## circle sits down at its feet, well below its origin. Straight north or south
## of her, a monster pressed against her body was still ~135-190 ground units
## "away", past every attack_range on the roster, so it kept walking into her
## without ever swinging. Being blocked by her body now always counts as reach.
func within_reach(target: Node2D, multiplier: float = 1.0) -> bool:
	if ground_distance_to(target.global_position) <= attack_range * multiplier:
		return true
	return body_gap_to(target) <= CONTACT_SLACK * maxf(multiplier, 1.0)


## Screen-space clearance between this monster's body circle and `target`'s.
## INF when either has no circular body to measure.
func body_gap_to(target: Node2D) -> float:
	var mine := _body_shape(self)
	var theirs := _body_shape(target)
	if mine == null or theirs == null:
		return INF
	var touch: float = (mine.shape as CircleShape2D).radius * absf(mine.global_scale.x) \
			+ (theirs.shape as CircleShape2D).radius * absf(theirs.global_scale.x)
	return mine.global_position.distance_to(theirs.global_position) - touch


## A body's own circular collision shape (direct children only, so hit boxes
## and sensors are ignored).
static func _body_shape(body: Node) -> CollisionShape2D:
	if not body is CollisionObject2D:
		return null
	for child in body.get_children():
		if child is CollisionShape2D and not child.disabled and child.shape is CircleShape2D:
			return child
	return null


func face(dir: Vector2) -> void:
	if dir == Vector2.ZERO:
		return
	var named: String = directionState(round(dir))
	if named != "":
		facing_dir = named


func move_towards(dir: Vector2, speed: float) -> void:
	velocity = dir * speed
	velocity.y *= ISO_Y_SCALE
	move_and_slide()


func stop() -> void:
	velocity = Vector2.ZERO
	move_and_slide()


## Sets a real knockback impulse along `direction` (already isometric-squashed,
## same convention as the `away` vector below — not re-scaled here). Covers
## RECOIL_PIXELS over RECOIL_TIME, decelerating to zero.
func apply_knockback(direction: Vector2) -> void:
	if direction == Vector2.ZERO:
		return
	var speed: float = 2.0 * RECOIL_PIXELS / RECOIL_TIME
	knockback_velocity = direction.normalized() * speed


## Moves the body along any pending knockback instead of standing still, so a
## stagger is an actual position change — wherever `move_and_slide` lets it
## travel before colliding — rather than a sprite trick that snaps back once
## the hurt animation ends. Call this instead of stop() while staggered.
func consume_knockback(delta: float) -> void:
	var decel: float = (2.0 * RECOIL_PIXELS / RECOIL_TIME) / RECOIL_TIME
	velocity = knockback_velocity
	knockback_velocity = knockback_velocity.move_toward(Vector2.ZERO, decel * delta)
	move_and_slide()


## Loops a clip in the current facing. Restarts only when the clip or the
## direction actually changed — calling play() every frame would pin the
## animation to frame 0 forever.
func play_loop(state_name: String) -> void:
	var clip: String = "%s_%s" % [state_name, facing_dir]
	animated_sprite.speed_scale = 0.5 if state_name == "idle" else 1.0
	if animated_sprite.animation != clip or not animated_sprite.is_playing():
		animated_sprite.play(clip)
		_sync_collision_tween(clip)


## Slowest a chase may be, as a multiple of move_speed, once it is a run.
## A run clip played much under this reads as running on the spot. Every
## hunter runs; walking is for idling and wandering.
const RUN_PACE: float = 1.8

## Ground speed while hunting her or heading to where she was last seen.
func chase_speed() -> float:
	if run_speed > 0.0:
		return run_speed
	return move_speed * maxf(traits.get("chase", 1.0), RUN_PACE)


## The chase loop: the run clip where this monster has one. Without one the
## walk clip is played faster to match the run, so the feet keep up with the
## ground instead of skating across it.
func play_chase() -> void:
	var run_clip: String = "run_%s" % facing_dir
	if animated_sprite.sprite_frames.has_animation(run_clip):
		play_loop("run")
		return
	play_loop("walk")
	if move_speed > 0.0:
		animated_sprite.speed_scale = clampf(chase_speed() / move_speed, 1.0, 3.0)


## Plays a one-shot clip from the top. Only call this from a state's on_enter.
func play_once(state_name: String, rate: float = 1.0) -> void:
	var clip: String = "%s_%s" % [state_name, facing_dir]
	animated_sprite.speed_scale = rate
	if state_name.contains("attack") or state_name in ["charge", "cast", "shoot", "lunge"]:
		AudioManager.enemy_event(self, "attack")
	elif state_name.contains("alert"):
		AudioManager.enemy_event(self, "alert")
	elif state_name.contains("dodge") or state_name.contains("evade"):
		AudioManager.play_for("sfx_enemy_dodge", self)
	## A monster without this clip would keep looping its last one and leave the
	## state waiting forever. Stopping reads as finished, so the state moves on.
	if not animated_sprite.sprite_frames.has_animation(clip):
		push_warning("%s has no clip %s" % [name, clip])
		animated_sprite.stop()
		return
	animated_sprite.play(clip)
	_sync_collision_tween(clip)


## Starts the collision tween that shares this clip's exact name, so it plays
## in lockstep with the sprite that just started. A monster with no
## CollisionTween node, or a clip with no matching animation on it (most of
## them — only one-shot leaps/lunges need this), simply does nothing here.
## Otherwise the shapes are re-measured from the new clip's own frame right
## away: a tween clip's displacement is only ever meant to last as long as
## that one clip is playing, and by the time a later clip starts the earlier
## tween has usually already finished on its own (same duration as the sprite
## clip it rode along with), so waiting on is_playing() would almost never
## fire and the shapes would be left stranded at the last clip's displaced
## end position instead of snapping back to wherever this new clip belongs.
func _sync_collision_tween(clip: String) -> void:
	if collision_tween == null:
		return
	_commit_collision_tween_motion()
	if collision_tween.has_animation(clip):
		_rebase_collision_tween(clip)
		collision_tween.speed_scale = animated_sprite.speed_scale
		collision_tween.play(clip)
		return
	collision_tween.stop()
	_position_collision_shape()
	_position_hit_box()


## clip name -> {"body": Vector2, "hitbox": Vector2}: how far each shape is
## meant to drift across the clip, captured once from the authored keys
## before _rebase_collision_tween starts overwriting them in place.
var _collision_tween_deltas: Dictionary = {}


## _position_collision_shape()/_position_hit_box() compute the actual resting
## spot once at spawn from whichever sprite animation happens to be playing
## at that instant — which, depending on state-machine startup order, is not
## guaranteed to be the same frame the CollisionTween's keys were authored
## against. Caching the *displacement* each clip's keys represent (rather
## than trusting their absolute values) keeps the tween correct regardless of
## where the shapes actually ended up resting.
func _cache_collision_tween_deltas() -> void:
	if collision_tween == null:
		return
	for clip in collision_tween.get_animation_list():
		var anim: Animation = collision_tween.get_animation(clip)
		if anim.get_track_count() < 2:
			continue
		_collision_tween_deltas[clip] = {
			"body": anim.track_get_key_value(0, 1) - anim.track_get_key_value(0, 0),
			"hitbox": anim.track_get_key_value(1, 1) - anim.track_get_key_value(1, 0),
		}


## Re-anchors a clip's two keys to wherever the shapes actually sit right
## now, so playing it always tweens from the shape's real current position
## (no snap) out to that same current position plus the clip's own baked
## displacement — instead of a fixed absolute spot that may not match
## whatever this monster's own idle frame happened to rest at.
func _rebase_collision_tween(clip: String) -> void:
	var anim: Animation = collision_tween.get_animation(clip)
	var deltas: Dictionary = _collision_tween_deltas.get(clip, {})
	if anim == null or deltas.is_empty():
		return
	var shape_node: CollisionShape2D = get_node_or_null("CollisionShape2D")
	if shape_node != null:
		_tween_origin_body = shape_node.position
		anim.track_set_key_value(0, 0, shape_node.position)
		anim.track_set_key_value(0, 1, shape_node.position + deltas["body"])
	var hitbox_shape: CollisionShape2D = _hit_box_shape()
	if hitbox_shape != null:
		_tween_origin_hitbox = hitbox_shape.position
		anim.track_set_key_value(1, 0, hitbox_shape.position)
		anim.track_set_key_value(1, 1, hitbox_shape.position + deltas["hitbox"])
	_tween_motion_pending = true


## Where the shapes sat when the current tween clip started, so the distance
## they have drifted since can be handed over to the body afterwards.
var _tween_origin_body: Vector2 = Vector2.ZERO
var _tween_origin_hitbox: Vector2 = Vector2.ZERO
var _tween_motion_pending: bool = false


func _hit_box_shape() -> CollisionShape2D:
	if not is_instance_valid(hit_box):
		return null
	return hit_box.get_node_or_null("CollisionShape2D")


## Root motion: the clip's art has drawn the monster somewhere else inside its
## own frame, and the tween carried the shapes along with it. Once that clip
## is over (or cut short), the body itself moves to where the shapes ended up
## and the shapes return to their resting offsets, so the next clip — drawn
## back at the frame's centre — starts exactly where the last one left off
## instead of snapping back to where the dodge began.
##
## Done on the next clip change rather than on the tween's own
## animation_finished: the sprite holds its last displaced frame until the
## state machine moves on, and moving the body before then would show that
## frame offset twice for a tick.
##
## move_and_collide rather than a raw position write, so a dodge drawn into a
## wall stops at the wall instead of committing the body inside it.
func _commit_collision_tween_motion() -> void:
	if not _tween_motion_pending:
		return
	_tween_motion_pending = false
	## Read before stop(): stopping rewinds the tween and puts the shapes
	## back on key 0, which would lose the distance travelled.
	var offset: Vector2 = Vector2.ZERO
	var shape_node: CollisionShape2D = get_node_or_null("CollisionShape2D")
	if shape_node != null:
		offset = shape_node.position - _tween_origin_body
	collision_tween.stop()
	if shape_node != null:
		shape_node.position = _tween_origin_body
	var hitbox_shape: CollisionShape2D = _hit_box_shape()
	if hitbox_shape != null:
		hitbox_shape.position = _tween_origin_hitbox
	if offset != Vector2.ZERO:
		move_and_collide(offset)



func animation_finished() -> bool:
	return not animated_sprite.is_playing()


func attack_off_cooldown() -> bool:
	return Time.get_ticks_msec() >= _attack_ready_at_ms


func start_attack_cooldown() -> void:
	_attack_ready_at_ms = Time.get_ticks_msec() + int(attack_cooldown * 1000.0)


## Lands a claw hit if the player is still inside the swing. `reach` is a
## multiplier on attack_range, so a player backing off mid-swing can still be
## clipped by the follow-through. `arc_cos` is how narrow the forward arc the
## swing must land within is, in cosine terms; pass STRIKE_ARC_OMNI for an
## attack (like Oni's stomp) that is meant to hit all around rather than along
## a facing.
func strike(reach: float = 1.35, damage_multiplier: float = 1.0, arc_cos: float = STRIKE_ARC_COS) -> void:
	if is_dead:
		return
	var target := player()
	if target == null:
		return
	if not within_reach(target, reach):
		return
	if not _in_strike_arc(target.global_position, arc_cos):
		return
	if target.has_method("take_damage"):
		## Tells her guard where the blow came from.
		target.take_damage(effective_attack_damage() * damage_multiplier, global_position)
	_strike_breakables(reach, damage_multiplier, arc_cos)


## How wide, in cosine terms, a swing's forward arc is. 0.3 is roughly 70°
## either side of facing — wide enough that a target strafing mid-swing is
## still caught by the follow-through, but no longer hittable from directly
## behind or beside the monster, which a distance-only check could not tell
## apart from a target standing right in front of the claws.
const STRIKE_ARC_COS: float = 0.3
## Every direction counts — for a shockwave/AoE strike with no "front".
const STRIKE_ARC_OMNI: float = -1.0

## True when `target_position` sits within the forward arc the swing is aimed
## along. Facing is snapped once at the swing's start (on_enter), so this asks
## where the attack actually reaches rather than trusting a bare radius around
## the monster's own centre, which read as hits landing from any direction at
## all as long as something was merely nearby.
func _in_strike_arc(target_position: Vector2, arc_cos: float = STRIKE_ARC_COS) -> bool:
	var facing: Vector2 = stateDirection(facing_dir)
	if facing == Vector2.ZERO:
		return true
	var to_target: Vector2 = target_position - global_position
	to_target.y /= ISO_Y_SCALE
	if to_target.length() < 0.01:
		return true
	return facing.normalized().dot(to_target.normalized()) >= arc_cos


## Enemy swings may smash props caught in the same attack radius. This query
## runs only on the attack animation's hit frame; walking into a prop cannot
## damage it.
func _strike_breakables(reach: float, damage_multiplier: float = 1.0, arc_cos: float = STRIKE_ARC_COS) -> void:
	var shape := CircleShape2D.new()
	shape.radius = attack_range * reach
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = shape
	query.transform = Transform2D(0.0, global_position)
	query.collision_mask = 2
	query.exclude = [get_rid()]
	query.collide_with_bodies = true
	query.collide_with_areas = true
	var struck: Dictionary = {}
	for hit in get_world_2d().direct_space_state.intersect_shape(query, 32):
		var body := Breakable.hit_target(hit.get("collider") as Node2D)
		if not is_instance_valid(body) or not body.is_in_group("breakable") or not body.has_method("take_damage"):
			continue
		if struck.has(body.get_instance_id()):
			continue
		if not _in_strike_arc(body.global_position, arc_cos):
			continue
		struck[body.get_instance_id()] = true
		body.take_damage(effective_attack_damage() * damage_multiplier, global_position)


## Called when the player interacts with this monster — an Action press or the
## start of a swing. Returns true if that provocation started a taunt, so the
## caller knows the monster is now busy talking.
##
## Safe to call every frame; the component latches after the first success.
func provoke() -> bool:
	if is_dead or not is_instance_valid(taunt):
		return false
	if not taunt.provoke():
		return false
	_change_state("taunt")
	return true




## Who struck the killing blow, so the score goes to the right player.
var _last_hit_by: int = -1
var _last_hit_at_ms: int = -1


## True when the given slot struck this monster within the window. AI
## teammates use it to join a fight a human started.
func hit_recently_by(slot: int, window_ms: int = 4000) -> bool:
	return _last_hit_by == slot and _last_hit_at_ms >= 0 \
			and Time.get_ticks_msec() - _last_hit_at_ms <= window_ms


func last_hit_slot(window_ms: int = 4000) -> int:
	if _last_hit_at_ms < 0 or Time.get_ticks_msec() - _last_hit_at_ms > window_ms:
		return -1
	return _last_hit_by


func take_damage(amount: float, from: Vector2 = Vector2.INF,
		_guardable: bool = true) -> void:
	if NetworkManager.is_client:
		return
	set_dormant(false)
	## Credited by proximity to the source of the blow, which is the player's
	## own position for a swing and the arc's for a thrown one.
	if from != Vector2.INF:
		var striker := Roster.nearest_to(get_tree(), from)
		if striker != null and "slot" in striker:
			_last_hit_by = striker.slot
			_last_hit_at_ms = Time.get_ticks_msec()
	if is_dead:
		return
	AudioManager.enemy_event(self, "hurt")
	## Stone has no guard, no shell and no footing: the blow shatters it, for
	## far more than a cut to flesh would do, and it comes back to life
	## reeling from it.
	var stone: bool = is_petrified()
	if stone:
		_unpetrify(false)
		amount *= shatter_multiplier
	## Where the blade came through, so the spray throws the right way and the
	## arc points along the blow rather than at a fixed angle.
	var origin: Vector2 = from
	if origin == Vector2.INF:
		var target := player()
		origin = target.global_position if target != null else global_position
	HitEffects.slash(get_parent(), global_position + Vector2(0, -40),
			global_position - origin, 1.0 + amount / 120.0)
	## A warden meets blows it is facing. A flat frontal soak rather than the
	## player's arc — a monster parrying that precisely would be unreadable in a
	## crowd.
	if traits.get("guards", false) and from != Vector2.INF and not stone:
		var facing: Vector2 = stateDirection(facing_dir)
		if facing != Vector2.ZERO:
			var toward: Vector2 = from - global_position
			toward.y /= 0.5
			facing.y /= 0.5
			if absf(toward.normalized().angle_to(facing.normalized())) < deg_to_rad(70.0):
				## A guard it chose to raise stops far more than merely facing
				## the right way does.
				amount *= 0.15 if guarding else 0.45
	## Kappa's shell, and the exact inverse of the boss's blind spot: a blow from
	## behind glances off the carapace, so he has to be met head on rather than
	## circled. Set as a damage multiplier — 0.1 leaves a tenth of the hit.
	var shell: float = traits.get("shell", 1.0)
	if shell < 1.0 and from != Vector2.INF and not stone:
		var carapace: Vector2 = stateDirection(facing_dir)
		if carapace != Vector2.ZERO:
			var incoming: Vector2 = from - global_position
			incoming.y /= 0.5
			carapace.y /= 0.5
			if absf(incoming.normalized().angle_to(carapace.normalized())) > deg_to_rad(110.0):
				amount *= shell
	## Flat on his back the armour points at the ceiling, so the shell is worth
	## nothing and the opening is real. Set by enemyStumble while he is down.
	if has_meta("exposed"):
		amount *= float(get_meta("exposed"))
	## The boss never learned to watch its own back. This is the only way in.
	var weak: float = traits.get("stealth_weak", 1.0)
	if weak > 1.0 and _last_hit_by >= 0:
		var striker := _player_in_slot(_last_hit_by)
		if striker != null and (striker.get("stealthed") == true
				or striker.get("crouched") == true):
			amount *= weak
	if amount > 0.0:
		HitEffects.blood(get_parent(), global_position + Vector2(0, -40), origin, amount,
				global_position - origin)
	health = maxf(health - amount, 0.0)
	_refresh_health_bar()
	## The killing blow gets the longer hold, so a one-shot does not look like
	## the monster was never hit at all.
	_flash(health <= 0.0)
	if health <= 0.0:
		_change_state("death")
		return
	_change_state("hurt")


## Stone scroll. A petrified monster is frozen mid-pose — its state machine,
## animation and collision tween all stopped — and goes grey. It reverts on its
## own after the scroll's time, or at once when struck (see take_damage).
@export var shatter_multiplier: float = 3.0
const STONE_SHADER: Shader = preload("res://shaders/stone.gdshader")
var _petrified: bool = false
var _material_before_stone: Material = null
var _stone_timer: Timer = null


func is_petrified() -> bool:
	return _petrified


func can_petrify() -> bool:
	return not is_dead and not _petrified


## Asleep while nobody is near the screen. MazeDemo switches this a few times a
## second: a wandering monster across the floor costs a state machine, a
## move_and_slide and an animation every frame for something nobody can see.
## Only an idle monster sleeps, so a chase is never frozen mid-stride.
var dormant: bool = false


func set_dormant(on: bool) -> void:
	if on == dormant:
		return
	if on:
		if is_dead or _petrified or not is_instance_valid(state_machine):
			return
		var current: Node = state_machine.current_state
		if current == null or current.name != &"idle":
			return
	dormant = on
	velocity = Vector2.ZERO
	visible = not on
	if is_instance_valid(state_machine) and not _petrified:
		state_machine.process_mode = Node.PROCESS_MODE_DISABLED if on \
				else Node.PROCESS_MODE_INHERIT
	if is_instance_valid(animated_sprite):
		if on:
			animated_sprite.pause()
		else:
			animated_sprite.play()
	if is_instance_valid(collision_tween):
		if on:
			collision_tween.pause()
		elif collision_tween.assigned_animation != &"":
			collision_tween.play()


func petrify(seconds: float) -> void:
	if not can_petrify():
		return
	set_dormant(false)
	_petrified = true
	velocity = Vector2.ZERO
	knockback_velocity = Vector2.ZERO
	guarding = false
	_sight_cached = false
	if is_instance_valid(state_machine):
		state_machine.process_mode = Node.PROCESS_MODE_DISABLED
	if is_instance_valid(collision_tween):
		collision_tween.pause()
	if is_instance_valid(_flash_tween):
		_flash_tween.kill()
	if is_instance_valid(animated_sprite):
		animated_sprite.pause()
		animated_sprite.modulate = Color.WHITE
		_material_before_stone = animated_sprite.material
		var stone := ShaderMaterial.new()
		stone.shader = STONE_SHADER
		animated_sprite.material = stone
	if _stone_timer == null:
		_stone_timer = Timer.new()
		_stone_timer.one_shot = true
		_stone_timer.timeout.connect(_unpetrify)
		add_child(_stone_timer)
	_stone_timer.start(seconds)


## Back to flesh. `settle` sends it to idle to get its bearings; a shattering
## blow passes false because the hit itself decides what state comes next.
func _unpetrify(settle: bool = true) -> void:
	if not _petrified:
		return
	_petrified = false
	if _stone_timer != null:
		_stone_timer.stop()
	if is_instance_valid(animated_sprite):
		animated_sprite.material = _material_before_stone
		animated_sprite.play()
	_material_before_stone = null
	if is_instance_valid(state_machine):
		state_machine.process_mode = Node.PROCESS_MODE_INHERIT
	if settle and is_instance_valid(state_machine) and state_machine.has_node("idle"):
		_change_state("idle")


## Called on every monster when a player reads the Invisibility scroll: whatever
## it was hunting, it has lost, and drops back to wandering.
func forget_player(_who: Node = null) -> void:
	_last_seen_ms = -100000
	_sight_checked_ms = -100000
	_sight_cached = false
	last_known = Vector2.ZERO


## Drops the corpse out of collision immediately so it stops blocking movement
## and the player's ActionArea releases it as a target.
func begin_death() -> void:
	if is_dead:
		return
	is_dead = true
	AudioManager.enemy_event(self, "death")
	AudioManager.play_for("sfx_enemy_defeat", self, -4.0)
	died.emit()
	## Scored here rather than in the death state, so it lands the instant the
	## monster is out of the fight — the streak window has to open now, not when
	## the collapse animation finishes.
	if _last_hit_by >= 0:
		var killer := _player_in_slot(_last_hit_by)
		var unseen: bool = killer != null and (killer.get("stealthed") == true
				or killer.get("crouched") == true)
		Score.killed(_last_hit_by, tier, unseen)
		Progression.killed(_last_hit_by, scene_file_path.get_file().get_basename(),
				base_tier if base_tier >= 0 else tier, tier)
	velocity = Vector2.ZERO
	set_deferred("collision_layer", 0)
	set_deferred("collision_mask", 0)
	if is_instance_valid(health_bar):
		health_bar.visible = false


## A client's copy of a monster the server has just killed. The state machine
## is switched off on clients, so nothing here would otherwise ever reach
## finish_death(): the corpse plays its collapse and fades on a timer instead.
func network_death() -> void:
	if is_dead:
		return
	is_dead = true
	velocity = Vector2.ZERO
	set_deferred("collision_layer", 0)
	set_deferred("collision_mask", 0)
	if is_instance_valid(health_bar):
		health_bar.visible = false
	if is_instance_valid(animated_sprite):
		play_once("death")
	get_tree().create_timer(2.0, false).timeout.connect(finish_death)


## The body in a given slot, or null.
func _player_in_slot(slot: int) -> Node:
	for body in Roster.bodies(get_tree()):
		if body.get("slot") == slot:
			return body
	return null


## Called by the death state once the animation has played out.
func finish_death() -> void:
	var fade: Tween = create_tween()
	fade.tween_interval(1.0)
	fade.tween_property(animated_sprite, "modulate:a", 0.0, 0.8)
	fade.tween_callback(queue_free)


func _change_state(state_name: String) -> void:
	if is_instance_valid(state_machine):
		state_machine.change_state(state_name)


## Reaction to being hit: a blown-out flash, a real knockback away from the
## blade, and a squash that springs back.
##
## A tint fading over 0.18s was all there used to be, which on a dark sprite in a
## dark dungeon is close to invisible — and a killing blow swapped straight to
## the death clip in the same frame, so a one-shot backstab read as the monster
## blinking out of existence. The knockback moves the body itself via
## move_and_slide (see apply_knockback/consume_knockback), so a wall still
## stops it rather than it clipping through — it just no longer snaps back to
## its pre-hit spot once the stagger ends.
const RECOIL_PIXELS: float = 22.0
const RECOIL_TIME: float = 0.13
## Well above white, so a hit reads even against lantern light.
const HIT_BLOWOUT: Color = Color(2.6, 1.5, 1.5, 1.0)


func _flash(fatal: bool = false) -> void:
	if is_instance_valid(_flash_tween):
		_flash_tween.kill()
	if not is_instance_valid(animated_sprite):
		return

	var rest_scale: Vector2 = animated_sprite.scale

	## Away from whoever is swinging, with the isometric squash applied so the
	## kick travels along the floor rather than straight across the screen.
	var away := Vector2(0.0, -1.0)
	var target := player()
	if target != null:
		var d: Vector2 = global_position - target.global_position
		if d.length_squared() > 0.001:
			away = d.normalized()
	away.y *= 0.5

	animated_sprite.modulate = HIT_BLOWOUT
	apply_knockback(away)
	animated_sprite.scale = rest_scale * Vector2(1.18, 0.86)

	_flash_tween = create_tween()
	_flash_tween.set_parallel(true)
	## A kill holds the white longer; the death clip takes over from there, and
	## the hold is what sells the moment.
	_flash_tween.tween_property(animated_sprite, "modulate", Color.WHITE,
			0.34 if fatal else 0.2)
	_flash_tween.tween_property(animated_sprite, "scale", rest_scale, RECOIL_TIME) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _refresh_health_bar() -> void:
	if is_instance_valid(health_bar):
		health_bar.max_value = max_health
		health_bar.value = health
