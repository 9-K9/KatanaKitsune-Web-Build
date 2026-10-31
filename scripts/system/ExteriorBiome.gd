class_name ExteriorBiome
extends Resource

enum Id { SAKURA, DESERT, SNOW }
enum Weather { CALM, PETALS, RAIN, SNOWFALL, SANDSTORM }

const PARTICLE_DIR := "res://assets/pixellab/japanese_environment/weather/"
const GROUND_DIR := "res://assets/pixellab/japanese_environment/biome_tiles/"
const PROP_DIR := WorldObjects.SCENE_DIR

@export var id: Id = Id.SAKURA
@export var art_approved: bool = false
@export var approved_weather: Array[int] = []
@export var compatible_weather: Array[int] = [Weather.CALM, Weather.PETALS, Weather.RAIN]
@export var trees: Array[String] = ["sakura_tree_c", "sakura_tree_c", "sakura_weeping",
		"black_pine", "bamboo_clump"]
@export var edge_trees: Array[String] = ["black_pine", "black_pine", "bamboo_clump",
		"bamboo_clump", "sakura_tree_c", "sakura_tree_c"]
@export var ground_paths: Array[String] = []
## Optional biome replacements for the Japanese paving and gravel families.
@export var road_paths: Array[String] = []
@export var courtyard_paths: Array[String] = []
## Ground dressing for non-lush biomes, scattered alongside the trees.
@export var small_props: Array[String] = ["garden_rocks"]
@export_file("*.png") var roof_tiles: String = "res://assets/pixellab/japanese_environment/roofs/kawara_tiles.png"
## Per-face tint of the roof tiles (south-west, south-east, north-east, north-west order as built).
@export var roof_light: Array[Color] = [
	Color(0.40, 0.43, 0.47), Color(0.56, 0.59, 0.64),
	Color(0.65, 0.67, 0.70), Color(0.48, 0.52, 0.57),
]
@export var roof_trim := Color("#40362d")
@export var roof_hip := Color("#76818c")
@export var roof_ridge := Color("#697783")
## Keeps the rooms' own square roof blocks, painted in the wall material, instead
## of generating Japanese kawara roofs. The roof_* tile settings are then unused.
@export var castle_roofs: bool = false
@export var lush: bool = true
@export var ponds: bool = true
@export var moonlight := Color(0.55, 0.66, 0.95)


static func definition(which: Id) -> ExteriorBiome:
	var names := ["sakura", "desert", "snow"]
	return load("res://resources/biomes/%s.tres" % names[which]) as ExteriorBiome


func unavailable_reason() -> String:
	if not art_approved:
		return "projection, pivots and tile seams have not been approved"
	for prop in trees + edge_trees + small_props:
		if not ResourceLoader.exists(PROP_DIR + prop + "/" + prop + "_dir1.tscn"):
			return "missing prop scene: " + prop
		var scene := WorldObjects.scene(prop)
		if scene == null or not scene.can_instantiate():
			return "invalid prop scene: " + prop
	if trees.is_empty() or edge_trees.is_empty():
		return "tree palettes must not be empty"
	if id != Id.SAKURA and ground_paths.is_empty():
		return "no biome ground textures configured"
	if not castle_roofs:
		if not ResourceLoader.exists(roof_tiles) or not load(roof_tiles) is Texture2D:
			return "missing roof texture: " + roof_tiles
		if roof_light.size() != 4:
			return "roof_light needs one tint per roof face"
	for path in ground_paths + road_paths + courtyard_paths:
		if not ResourceLoader.exists(path):
			return "missing ground texture: " + path
		var texture := load(path) as Texture2D
		if texture == null or texture.get_size() != Vector2(48, 48):
			return "ground texture must use a 48x48 canvas: " + path
	return ""


static func select(forced: int, seed_value: int) -> ExteriorBiome:
	var fallback := definition(Id.SAKURA)
	if forced >= 0:
		var requested := definition(clampi(forced, Id.SAKURA, Id.SNOW))
		var reason := requested.unavailable_reason()
		if reason.is_empty():
			return requested
		push_warning("ExteriorBiome: biome %d unavailable (%s); retaining sakura." % [forced, reason])
		return fallback
	var available: Array[ExteriorBiome] = []
	for which in [Id.SAKURA, Id.DESERT, Id.SNOW]:
		var candidate := definition(which)
		if candidate.unavailable_reason().is_empty():
			available.append(candidate)
	if available.is_empty():
		push_warning("ExteriorBiome: no approved biome available; retaining existing sakura.")
		return fallback
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value ^ 0x42494f4d
	return available[rng.randi_range(0, available.size() - 1)]


func weather_available(weather: int) -> bool:
	if weather == Weather.CALM:
		return true
	if not compatible_weather.has(weather) or not approved_weather.has(weather):
		return false
	var path := particle_path(weather)
	if path.is_empty() or not ResourceLoader.exists(path):
		return false
	return load(path) is Texture2D


static func particle_path(weather: int) -> String:
	match weather:
		Weather.PETALS:
			return PARTICLE_DIR + "sakura_petal.png"
		Weather.RAIN:
			return PARTICLE_DIR + "rain_drop.png"
		Weather.SNOWFALL:
			return PARTICLE_DIR + "snowflake.png"
		Weather.SANDSTORM:
			return PARTICLE_DIR + "sand_grain.png"
	return ""
