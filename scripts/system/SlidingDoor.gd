class_name SlidingDoor
extends StaticBody2D

signal human_crossed(player: CharacterBody2D)

## A shoji door set into a maze wall. It slides open when anyone comes near —
## a player or a monster — and shuts again once they have all gone. A katana
## (or a claw) can smash it, which leaves it torn and permanently open.
##
## The frame is a tile in the wall layer, so the wall's fade, light occluders
## and Y-sort all treat it as ordinary wall. This node is only the moving part:
## the paper panels, and the collision filling the doorway between the jambs.
## MazeDemo builds it and sets the exported fields before adding it as a child
## of that wall layer, positioned on the tile's sort line.

## Paper interior only; the shader slides it into the jambs.
@export var panel_texture: Texture2D
@export var broken_texture: Texture2D
## Doorway centre, half-width and wall gradient, in texture pixels.
@export var split_x: float = 120.0
@export var half_width: float = 60.0
@export var slope: float = 0.5
## Where the texture's centre sits relative to this node.
@export var sprite_offset: Vector2 = Vector2.ZERO
## The doorway's footprint in this node's space: the wall polygon clipped to
## the opening. It blocks walking and sight while the door is shut.
@export var doorway: PackedVector2Array = PackedVector2Array()

@export var max_health: float = 30.0
## How near anyone has to be, measured to the doorway's centre on the ground.
@export var open_radius: float = 150.0
@export var slide_speed: float = 3.2

const SHADER := preload("res://shaders/shojiSlide.gdshader")
const FADE_PARAMS: PackedStringArray = [
	"subjects", "subject_count", "extents", "rise", "softness", "min_alpha"]
const CROSS_SIDE_MARGIN: float = 18.0

var health: float = 0.0
var _open: float = 0.0
var _broken: bool = false
var _sprite: Sprite2D = null
var _material: ShaderMaterial = null
var _shape: CollisionPolygon2D = null
var _occluder: LightOccluder2D = null
var _centre: Vector2 = Vector2.ZERO
var _flash_tween: Tween = null
var _was_moving: bool = false
var _human_sides: Dictionary[int, int] = {}


func _ready() -> void:
	health = max_health
	add_to_group("breakable")
	add_to_group("bot_door")
	collision_layer = 3
	collision_mask = 0

	_material = ShaderMaterial.new()
	_material.shader = SHADER
	_material.set_shader_parameter("split_x", split_x)
	_material.set_shader_parameter("half_width", half_width)
	_material.set_shader_parameter("slope", slope)

	_sprite = Sprite2D.new()
	_sprite.name = "Sprite2D"
	_sprite.texture = panel_texture
	_sprite.offset = sprite_offset
	_sprite.material = _material
	add_child(_sprite)

	_shape = CollisionPolygon2D.new()
	_shape.polygon = doorway
	add_child(_shape)

	var occluder_polygon := OccluderPolygon2D.new()
	occluder_polygon.polygon = doorway
	_occluder = LightOccluder2D.new()
	_occluder.occluder = occluder_polygon
	add_child(_occluder)

	for p in doorway:
		_centre += p
	if not doorway.is_empty():
		_centre /= float(doorway.size())


func _physics_process(delta: float) -> void:
	_copy_fade()
	_track_human_crossings()
	if _broken:
		return
	var wanted: float = 1.0 if _anyone_near() else 0.0
	if is_equal_approx(_open, wanted):
		_was_moving = false
		return
	if not _was_moving:
		AudioManager.play_for("sfx_door_slide", self, -5.0)
	_was_moving = true
	_open = move_toward(_open, wanted, delta * slide_speed)
	_material.set_shader_parameter("open", _open)
	## Passable once it is mostly open, and solid again only once fully shut,
	## so nobody is trapped in a closing door's collision.
	var passable: bool = _open > 0.6 or (wanted > 0.5 and _open > 0.0)
	_set_solid(not passable or (wanted < 0.5 and _open <= 0.0))


func _anyone_near() -> bool:
	var here: Vector2 = to_global(_centre)
	for group in ["player", "enemy"]:
		for node in get_tree().get_nodes_in_group(group):
			if not (node is CharacterBody2D) or node.get("is_dead") == true:
				continue
			if (node as Node2D).global_position.distance_to(here) <= open_radius:
				return true
	return false


## Watches the stable side of the panel each human occupies. Crossing its
## centre line while still within the doorway span is a real traversal, not
## merely walking past one end of the wall.
func _track_human_crossings() -> void:
	var seen: Dictionary[int, bool] = {}
	var normal := Vector2(-slope, 1.0).normalized()
	var tangent := Vector2(1.0, slope).normalized()
	for node in get_tree().get_nodes_in_group("player"):
		if not (node is CharacterBody2D) or node.get("is_dead") == true:
			continue
		var player := node as CharacterBody2D
		var slot: int = int(player.get("slot"))
		if Roster.count() > slot and Roster.is_ai_controlled(slot):
			continue
		var relative := to_local(player.global_position) - _centre
		if relative.length() > open_radius * 1.4:
			continue
		var key := player.get_instance_id()
		seen[key] = true
		var across: float = relative.dot(normal)
		if absf(across) < CROSS_SIDE_MARGIN:
			continue
		var side: int = 1 if across > 0.0 else -1
		var previous: int = _human_sides.get(key, side)
		_human_sides[key] = side
		if previous != side and absf(relative.dot(tangent)) <= half_width * 1.8 + 48.0:
			human_crossed.emit(player)
	for key in _human_sides.keys():
		if not seen.has(key):
			_human_sides.erase(key)


func _set_solid(solid: bool) -> void:
	var layer: int = 3 if solid else 0
	if collision_layer != layer:
		set_deferred("collision_layer", layer)
	_occluder.visible = solid


## The wall layer works out who it is covering; the door just borrows that, so
## it fades in step with the stone around it.
func _copy_fade() -> void:
	var wall := get_parent() as CanvasItem
	var source := wall.material as ShaderMaterial if wall != null else null
	if source == null:
		return
	for param in FADE_PARAMS:
		_material.set_shader_parameter(param, source.get_shader_parameter(param))


func take_damage(amount: float, _from: Vector2 = Vector2.INF,
		_guardable: bool = true) -> void:
	if _broken:
		return
	health -= amount
	_flash()
	if health <= 0.0:
		_break()


func _flash() -> void:
	if is_instance_valid(_flash_tween):
		_flash_tween.kill()
	_flash_tween = create_tween()
	_flash_tween.tween_method(func(v: float) -> void:
		_material.set_shader_parameter("flash_amount", v), 1.0, 0.0, 0.16)


## Torn paper stays in the frame, but it no longer stops anyone.
func _break() -> void:
	_broken = true
	AudioManager.play_for("sfx_door_break", self)
	remove_from_group("breakable")
	_open = 0.0
	_material.set_shader_parameter("open", 0.0)
	if broken_texture != null:
		_sprite.texture = broken_texture
	_set_solid(false)
	LootDrops.breakable(self)
	NetworkManager.announce_world_event("break", self)


func network_break() -> void:
	if _broken:
		return
	health = 0.0
	_break()
