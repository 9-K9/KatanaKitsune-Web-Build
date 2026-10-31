class_name LootDrops
extends RefCounted

## Guaranteed combat rewards shared by enemies and every kind of breakable.
##
## Enemy deaths lean toward healing, while smashed scenery leans toward
## scrolls. The roll is seeded from the floor and the source object, so an
## online client creates the same pickup when the authoritative death/break
## reaches it.

const ENEMY_HEALTH_CHANCE: float = 0.72
const BREAKABLE_HEALTH_CHANCE: float = 0.28
const BREAKABLE_OFFSET := Vector2(-24.0, 8.0)


static func enemy(source: Node2D) -> Node2D:
	return _spawn(source, ENEMY_HEALTH_CHANCE, Vector2.ZERO, "enemy")


static func breakable(source: Node2D) -> Node2D:
	return _spawn(source, BREAKABLE_HEALTH_CHANCE, BREAKABLE_OFFSET, "breakable")


static func _spawn(source: Node2D, health_chance: float, offset: Vector2,
		category: String) -> Node2D:
	if not is_instance_valid(source) or source.get_parent() == null:
		return null
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed_for(source, category)
	var family := "health_potion" if rng.randf() < health_chance else "scroll"
	var direction := WorldObjects.direction_from_roll(rng.randf(), rng.randi(), false)
	var packed := WorldObjects.scene(family, direction)
	var drop := packed.instantiate() as Node2D
	if drop == null:
		return null
	## Pickup chooses a random kind in _ready. Set it before add_child so every
	## peer shows and awards the same scroll.
	if family == "scroll" and "scroll_kind" in drop:
		drop.scroll_kind = rng.randi_range(0, Scroll.COUNT - 1)
	var parent := source.get_parent()
	var landing := source.global_position + offset
	if parent is Node2D:
		drop.position = (parent as Node2D).to_local(landing)
	parent.add_child(drop)
	if not (parent is Node2D):
		drop.global_position = landing
	return drop


static func _seed_for(source: Node2D, category: String) -> int:
	var world := source.get_tree().current_scene
	var floor_seed: int = int(world.get("maze_seed")) if world != null \
			and world.get("maze_seed") != null else 0
	if category == "enemy" and "network_id" in source and int(source.network_id) >= 0:
		return hash([floor_seed, category, int(source.network_id)])
	return hash([floor_seed, category, Vector2i(source.global_position.round()),
			String(source.name)])
