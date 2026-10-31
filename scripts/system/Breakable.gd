class_name Breakable
extends StaticBody2D

## A destructible dungeon prop: urns, crates, chests, statues.
##
## Takes katana hits like an enemy does (the player's attack code only needs a
## take_damage method), flashes, then shatters into whatever it was holding —
## a pickup, or something unpleasant that was nesting inside it.

## What comes out when it breaks. Weights are relative, not percentages.
@export var loot_scene: PackedScene = null
## Alternatives for the loot slot, chosen between at random when the prop
## breaks. A table holds a meal, and a meal is food or drink — without this a
## breakable could only ever drop one thing, and the second would have to be
## smuggled into spawn_scene, which means "something unpleasant was nesting in
## here" and would read as a bug to the next person.
@export var loot_scenes: Array[PackedScene] = []
## Lay the drop out on top of the prop instead of hiding it inside. A meal on a
## table should be visible before you smash the table — you break it *because*
## you can see the food, rather than smashing furniture on spec.
@export var display_loot: bool = false
## How far above this prop's base its surface is. The drop is drawn there, but
## parked at the base, so it sorts with the furniture instead of behind it.
@export var loot_display_lift: float = 46.0
@export var loot_weight: float = 6.0
@export var spawn_scene: PackedScene = null
@export var spawn_weight: float = 2.0
## Chance of dropping nothing at all.
@export var empty_weight: float = 3.0

@export var max_health: float = 25.0
## Chests are meant to feel worth hitting, so they always drop.
@export var always_drops: bool = false
## Chance a power-up scroll falls out as well, on top of whatever the prop was
## holding. Kept apart from the weighted loot roll so every breakable in the
## game can carry one without each scene's table being rebalanced.
@export_range(0.0, 1.0, 0.01) var scroll_chance: float = 0.12
const SCROLL_SCENE: PackedScene = preload("res://scenes/props/world_objects/scroll/scroll_dir1.tscn")
var _scroll_rolled: bool = false
@export var break_texture: Texture2D
@export var break_sprite_position: Vector2 = Vector2.INF
@export_range(1, 8, 1) var break_frames: int = 4
@export_range(0.03, 0.3, 0.01) var break_frame_time: float = 0.09
## Frames in the intact sprite, cycled while the prop is whole. 0 leaves it
## static, which is every crate and urn. A torch sets this to the length of its
## flame loop, so the fire moves without needing an AnimatedSprite2D — which
## would mean a second prop class purely because one sprite animates, and would
## not survive _break swapping the texture out from under it.
@export_range(0, 16, 1) var lit_frames: int = 0
@export_range(2.0, 24.0, 1.0) var lit_fps: float = 9.0
## Keep the final broken sprite instead of fading and freeing the prop.
@export var persist_broken: bool = false

const HIT_FLASH_SHADER := """
shader_type canvas_item;
uniform float flash_amount : hint_range(0.0, 1.0) = 0.0;
void fragment() {
	vec4 source = texture(TEXTURE, UV) * COLOR;
	COLOR = vec4(mix(source.rgb, vec3(1.0), flash_amount), source.a);
}
"""

@onready var sprite: Sprite2D = $Sprite2D

var health: float = 0.0
var _broken: bool = false
var _flash_tween: Tween = null
var _flash_material: ShaderMaterial
var _drop_spawned: bool = false


## The drop, chosen and instanced up front when it is displayed, so the item you
## can see on the table is the exact one that falls off it.
var _displayed: Node2D = null


static func hit_target(collider: Node2D) -> Node2D:
	if collider is Area2D:
		if collider.is_in_group("breakable"):
			return collider
		if collider.is_in_group("breakable_hitbox") or collider.is_in_group("enemy_hitbox"):
			return collider.get_parent() as Node2D
		return null
	return collider


var _rng: RandomNumberGenerator = null


func _ready() -> void:
	health = max_health
	add_to_group("breakable")
	if display_loot:
		_lay_out_loot()
	## Nudge each prop off the exact tile centre so a room full of urns does not
	## read as a grid.
	sprite.rotation = 0.0
	var shader := Shader.new()
	shader.code = HIT_FLASH_SHADER
	_flash_material = ShaderMaterial.new()
	_flash_material.shader = shader
	sprite.material = _flash_material
	if lit_frames > 1:
		sprite.hframes = lit_frames
		## Staggered, or every torch on the floor flickers in lockstep and the
		## room pulses as one light instead of several.
		_lit_at = randf() * float(lit_frames)
	else:
		set_process(false)


var _lit_at: float = 0.0


func _process(delta: float) -> void:
	if _broken or lit_frames <= 1:
		return
	_lit_at = fmod(_lit_at + delta * lit_fps, float(lit_frames))
	sprite.frame = int(_lit_at)


## `from` is where the blow came from. Unused here — a crate has no facing to
## guard with and does not bleed — but it has to be accepted: everything a swing
## can hit is called through one path, and callers pass the source so characters
## can work out guard angles and throw blood the right way. Without it, every
## hit on a breakable threw "Expected 1 argument" and the crate never took the
## damage.
func take_damage(amount: float, _from: Vector2 = Vector2.INF,
		_guardable: bool = true) -> void:
	if _broken:
		return
	## Online, the server decides when a crate goes; clients get told.
	if NetworkManager.is_client:
		return
	health -= amount
	_flash()
	if health <= 0.0:
		_break()


## A client's crate: the server broke its copy, so break this one the same way.
func network_break() -> void:
	if _broken:
		return
	health = 0.0
	_break()


## Loot rolls used to use the global RNG, which no two machines share. Seeding
## from the floor and the prop's spot makes every machine roll the same drop
## for the same crate, so a client sees the same scroll the server spawned.
func _loot_rng() -> RandomNumberGenerator:
	if _rng == null:
		_rng = RandomNumberGenerator.new()
		var world := get_tree().current_scene
		var floor_seed: int = int(world.get("maze_seed")) if world != null \
				and world.get("maze_seed") != null else 0
		_rng.seed = hash([floor_seed, Vector2i(global_position.round())])
	return _rng


func _flash() -> void:
	if is_instance_valid(_flash_tween):
		_flash_tween.kill()
	_flash_material.set_shader_parameter("flash_amount", 1.0)
	_flash_tween = create_tween()
	_flash_tween.tween_method(_set_flash_amount, 1.0, 0.0, 0.16)


func _set_flash_amount(amount: float) -> void:
	if is_instance_valid(_flash_material):
		_flash_material.set_shader_parameter("flash_amount", amount)


func _break() -> void:
	_broken = true
	var break_event := "sfx_break_wood"
	var texture_name := sprite.texture.resource_path.to_lower() if sprite.texture != null else ""
	if texture_name.contains("urn") or texture_name.contains("ceramic") or texture_name.contains("pot"):
		break_event = "sfx_break_ceramic"
	elif texture_name.contains("stone") or texture_name.contains("statue"):
		break_event = "sfx_break_stone"
	AudioManager.play_for(break_event, self)
	NetworkManager.announce_world_event("break", self)
	LootDrops.breakable(self)
	remove_from_group("breakable")
	set_process(false)
	## Drop out of collision immediately so the player is not left shoving an
	## invisible crate around while the shards fade.
	set_deferred("collision_layer", 0)
	set_deferred("collision_mask", 0)
	for child in get_children():
		if child is LightOccluder2D:
			child.visible = false
		elif child is Area2D and child.is_in_group("breakable_hitbox"):
			child.set_deferred("collision_layer", 0)
			child.set_deferred("monitorable", false)
	_douse()

	if is_instance_valid(_flash_tween):
		_flash_tween.kill()
	_set_flash_amount(0.0)

	var shattered: Texture2D = break_texture
	if shattered != null:
		sprite.texture = shattered
		if break_sprite_position != Vector2.INF:
			sprite.position = break_sprite_position
		sprite.hframes = break_frames
		sprite.frame = 0
		## A tween bound to this prop, not an await on a tree timer, so a prop
		## freed mid-break (floor change, quit to title) simply stops instead of
		## resuming on a dead instance.
		var frames := create_tween()
		for frame_index in break_frames:
			frames.tween_callback(_show_break_frame.bind(frame_index))
			frames.tween_interval(break_frame_time)
		frames.tween_callback(_finish_break)
	else:
		_finish_break()


func _show_break_frame(frame_index: int) -> void:
	sprite.frame = frame_index
	if frame_index == mini(2, break_frames - 1):
		_drop_once()


func _finish_break() -> void:
	_drop_once()
	if persist_broken:
		sprite.frame = break_frames - 1
		return
	var fade := create_tween()
	fade.set_parallel(true)
	fade.tween_property(sprite, "modulate:a", 0.0, 0.32)
	fade.tween_property(sprite, "position:y", sprite.position.y - 3.0, 0.32)
	fade.chain().tween_callback(queue_free)


## Puts out any flame this prop was carrying.
##
## A lantern that keeps burning after it is shattered is the obvious tell, and
## for a prop with persist_broken the light would otherwise hang over the rubble
## for the rest of the run. Guttering it over a fifth of a second rather than
## cutting it reads as the flame dying rather than as the light being switched
## off, and it lands while the break frames are still playing.
##
## Written generically, in the base class, because any prop may carry a light
## and none of them should keep it: a brazier, a lantern, a candle on a table.
func _douse() -> void:
	for child in get_children():
		if child is PointLight2D:
			var light := child as PointLight2D
			var gutter := create_tween()
			gutter.tween_property(light, "energy", 0.0, 0.22)
			gutter.tween_callback(func() -> void:
				if is_instance_valid(light):
					light.enabled = false)


## Puts the chosen drop on top of the prop, dormant.
func _lay_out_loot() -> void:
	var picked: PackedScene = _roll()
	if picked == null:
		return
	var thing = WorldObjects.loot(picked).instantiate()
	if not ("armed" in thing):
		return
	thing.armed = false
	## Centred on the prop before it enters the tree: Pickup's _ready() biases
	## its own position for Y-sort the moment it is added (see Pickup._raise),
	## and _ready runs synchronously inside add_child. Setting position after
	## add_child would stomp that bias right back to zero.
	(thing as Node2D).position = Vector2(0, -loot_display_lift)
	if "display_lift" in thing:
		thing.display_lift = loot_display_lift
	add_child(thing)
	_displayed = thing
	## Already decided, so _break must not roll a second time.
	_drop_spawned = true


func _drop_once() -> void:
	_drop_scroll()
	if _drop_spawned:
		## A displayed drop is already in the world; it just needs releasing.
		_release_displayed()
		return
	_drop_spawned = true
	_drop()


## Tips the displayed item onto the floor and makes it takeable.
func _release_displayed() -> void:
	if not is_instance_valid(_displayed):
		return
	var item := _displayed
	_displayed = null
	var landing: Vector2 = global_position
	## Reparented to the map, or it would be freed with the prop moments later.
	var keep := get_parent()
	item.reparent(keep)
	if item.has_method("arm"):
		item.arm(landing)


func _drop() -> void:
	var picked: PackedScene = _roll()
	if picked == null:
		return
	var thing = WorldObjects.loot(picked).instantiate()
	## Parent to the map rather than to self, or it would be freed along with
	## the prop a quarter of a second later.
	get_parent().add_child(thing)
	thing.global_position = global_position


## Rolls once for a scroll and, if it comes up, sets one down beside the prop.
## Offset to the side so it does not land under whatever the main drop was.
func _drop_scroll() -> void:
	if _scroll_rolled:
		return
	_scroll_rolled = true
	if _loot_rng().randf() >= scroll_chance or get_parent() == null:
		return
	var scroll := WorldObjects.loot(SCROLL_SCENE).instantiate()
	get_parent().add_child(scroll)
	scroll.global_position = global_position + Vector2(22.0, 8.0)


func _roll() -> PackedScene:
	var choices: Array[PackedScene] = []
	var weights: Array[float] = []
	var loot: PackedScene = loot_scene
	if not loot_scenes.is_empty():
		loot = loot_scenes[_loot_rng().randi() % loot_scenes.size()]
	if loot != null:
		choices.append(loot)
		weights.append(loot_weight)
	if spawn_scene != null:
		choices.append(spawn_scene)
		weights.append(spawn_weight)
	if not always_drops:
		choices.append(null)
		weights.append(empty_weight)
	if choices.is_empty():
		return null

	var total: float = 0.0
	for w in weights:
		total += w
	var roll: float = _loot_rng().randf() * total
	for i in choices.size():
		roll -= weights[i]
		if roll <= 0.0:
			return choices[i]
	return choices[-1]
