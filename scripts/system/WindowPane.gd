class_name WindowPane
extends StaticBody2D

## The breakable glass of a window set into a maze wall. The window art itself
## is a tile in the wall layer; this body only exists so a blade can find it.
## Once smashed the tile is swapped for its broken variant, whose collision sits
## on a physics layer that blocks walking but not sight or slash projectiles,
## and the light occluder for that cell is removed so light spills through.

@export var max_health: float = 12.0
## Set by MazeDemo before the pane is added.
var layer: TileMapLayer = null
var cell: Vector2i = Vector2i.ZERO
var broken_source: int = -1

var health: float = 0.0
var _broken: bool = false


func _ready() -> void:
	health = max_health
	add_to_group("breakable")
	collision_layer = 2
	collision_mask = 0


func take_damage(amount: float, _from: Vector2 = Vector2.INF,
		_guardable: bool = true) -> void:
	if _broken:
		return
	health -= amount
	if layer != null:
		var tween := create_tween()
		layer.modulate = Color(1.6, 1.6, 1.6)
		tween.tween_property(layer, "modulate", Color.WHITE, 0.12)
	if health <= 0.0:
		_break()


func _break() -> void:
	if _broken:
		return
	_broken = true
	LootDrops.breakable(self)
	NetworkManager.announce_world_event("break", self)
	remove_from_group("breakable")
	if layer != null and broken_source >= 0:
		layer.set_cell(cell, broken_source, Vector2i.ZERO)
		var here: Vector2 = layer.map_to_local(cell)
		for child in layer.get_children():
			if child is LightOccluder2D and (child as Node2D).position.is_equal_approx(here):
				child.queue_free()
	queue_free()


func network_break() -> void:
	if _broken:
		return
	health = 0.0
	_break()
