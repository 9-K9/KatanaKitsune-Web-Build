class_name LevelTheme
extends Resource

enum Id { SAKURA_GARDENS, BAMBOO_WOODLAND, ABANDONED_SHRINES, DESERT_RUINS, FROZEN_PASS }

const NAMES: Array[String] = [
	"sakura_gardens", "bamboo_woodland", "abandoned_shrines", "desert_ruins", "frozen_pass",
]

@export var id: Id = Id.SAKURA_GARDENS
## Outdoor environment this theme dresses: ground, roofs and native weather.
@export var biome: ExteriorBiome.Id = ExteriorBiome.Id.SAKURA
@export var display_name: String = ""
@export_multiline var description: String = ""
@export_file("*.png") var icon_path: String = ""
@export var walls: Array[String] = []
@export var trees: Array[String] = []
@export var edge_trees: Array[String] = []
@export var small_props: Array[String] = ["garden_rocks"]
@export var weather: Array[int] = [ExteriorBiome.Weather.CALM, ExteriorBiome.Weather.RAIN]
@export var outdoor_animals: Array[String] = []
@export var indoor_animals: Array[String] = []
@export var pond_animals: Array[String] = ["frog", "turtle"]
@export var tree_density: float = 1.0
@export var grass_density: float = 1.0
@export var animal_density: float = 1.0
@export_range(0.0, 1.0) var road_earth_chance: float = 0.0
@export_range(0.0, 1.0) var road_weed_chance: float = 0.0
@export_range(0.0, 1.0) var courtyard_earth_chance: float = 0.0
@export_range(0.0, 1.0) var ornament_chance: float = 0.45
@export var moonlight := Color(0.55, 0.66, 0.95)


static func definition(which: int) -> LevelTheme:
	## Itch.io Web Edition: Sakura Gardens is the only shipped level. This
	## fallback also prevents stale saves or crafted calls from reaching assets
	## intentionally omitted from this edition.
	return load("res://resources/level_themes/sakura_gardens.tres") as LevelTheme


static func music_key(which: int) -> String:
	return "sakura"


func exterior_biome() -> ExteriorBiome:
	var result := ExteriorBiome.definition(biome).duplicate() as ExteriorBiome
	if not trees.is_empty():
		result.trees = trees.duplicate()
	if not edge_trees.is_empty():
		result.edge_trees = edge_trees.duplicate()
	result.compatible_weather = weather.duplicate()
	result.moonlight = moonlight
	return result
