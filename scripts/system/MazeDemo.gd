extends Node2D

## Walkable demo: tiles room_A across the diamond lattice, knocks walls out to
## make a maze, and drops the player in with a camera that follows.
##
## Rooms sit on the isometric lattice, each neighbour half a room across and
## half a room down, so their diamonds interlock exactly — see
## _lattice_position. Openings are knocked through from both sides, which turns
## a run of rooms into one continuous space rather than a corridor.

@export var room_scene: PackedScene = null
@export var player_scene: PackedScene = null
## Paths rather than PackedScenes, loaded on demand and cached — see
## _monster_cache.
##
## As exported PackedScenes these were ext_resources on the scene, so all nine
## monster types were resident from the moment the dungeon opened whether or
## not a room used them. Their sheets only run 8-25 MB each on disk, so that
## was never the multi-gigabyte cost the original comment here assumed — but
## loading by path and caching still means a run that never sees, say, the
## yokai lord never pays to load her sheet.
@export var enemy_scene_paths: Array[String] = []
@export var prop_scenes: Array[PackedScene] = []
## Props drawn in the four isometric facings, one scene per facing so each has
## a collision polygon fitted to its own art. Scenes named <prop>_<facing>.tscn
## are grouped by prop and the group takes one slot in the prop pool, so a prop
## with four facings is no likelier to spawn than one with a single view.
@export var facing_prop_scenes: Array[PackedScene] = []
## Stood at the ends of every opening and spaced across it, so a knocked-out
## wall reads as a deliberate colonnade instead of a severed run of stone.
@export var pillar_scene: PackedScene = null
## One is always placed beside the spawn. Resting only happens at a chair, so
## leaving it to the random prop pool meant a floor could offer nowhere to rest.
@export var chair_scene: PackedScene = null
## A low table with chairs drawn up to it. Scattering furniture at random makes
## a storeroom; a table with seats around it makes a room somebody used.
## One scene per facing, each with a collision polygon fitted to its own art,
## so a table turned another way does not keep the first one's footprint.
@export var table_scenes: Array[PackedScene] = []
## How often a room gets one.
@export_range(0.0, 1.0, 0.05) var table_chance: float = 0.45
## How far the chairs sit from the table, along the floor axes. Wider than it
## was: the table renders 202px across, so seats at 96 stood on the tabletop.
## Just outside the tabletop, not a stride away. At 150 the seats sat about
## three tiles out — past the two tiles of clear floor the table's own placement
## guarantees — so most of them landed on no floor at all and were skipped.
@export var table_seat_gap: float = 110.0

## Start deeper than floor one. For testing a themed floor without walking down
## to it — the generator is identical, only the starting depth differs.
@export var start_depth: int = 1

## Every look a floor can wear, one per wall set the project ships.
##
## Each is a wall texture prefix, the floor layer to show, and the ground
## texture prefix. All sixty-four wall sets live in the same folder as eight
## directional PNGs on an identical 240x384 canvas with identical content
## bounds — they were rendered from one camera rig — so a theme is a string
## swap, not new geometry, collision or prefabs.
##
## The pairing is by name: anything reading as a Japanese or Chinese building
## gets the tatami layer, the open-air sets get grass, and the rest keep the
## checkered stone.
const THEMES: Array[Dictionary] = [
	{"wall": "aluminiumMetalicWall", "floor": "", "ground": "aluminiumMetalicFloor"},
	{"wall": "apartmentWall", "floor": "", "ground": "apartmentFloor"},
	{"wall": "arcadeGameWall", "floor": "", "ground": "arcadeGameFloor"},
	{"wall": "bathroomWall", "floor": "", "ground": "bathroomFloor"},
	{"wall": "blackAsylumnWall", "floor": "", "ground": "blackAsylumnFloor"},
	{"wall": "casinoWall", "floor": "", "ground": "casinoFloor"},
	{"wall": "casinoWall2", "floor": "", "ground": "casinoFloor"},
	{"wall": "cementBurntWall", "floor": "", "ground": "cementBurntFloor"},
	{"wall": "cementWall", "floor": "", "ground": "cementFloor"},
	{"wall": "cementWall2", "floor": "", "ground": "cementFloor"},
	{"wall": "chainMetalWall", "floor": "", "ground": "chainMetalFloor"},
	{"wall": "chainPrisonWall", "floor": "", "ground": "chainPrisonFloor"},
	{"wall": "chinaTownWall", "floor": "", "ground": "chinaTownFloor"},
	{"wall": "chineseWall", "floor": "", "ground": "chineseFloor"},
	{"wall": "chineseWall2", "floor": "", "ground": "chineseFloor"},
	{"wall": "computerScreenWall", "floor": "", "ground": "computerScreenFloor"},
	{"wall": "devilsWall", "floor": "", "ground": "devilsFloor"},
	{"wall": "glassWall", "floor": "", "ground": "glassFloor"},
	{"wall": "greenMetalicWall", "floor": "", "ground": "greenMetalicFloor"},
	{"wall": "greenWall", "floor": "", "ground": "greenFloor"},
	{"wall": "greenWall2", "floor": "", "ground": "greenFloor"},
	{"wall": "japaneseWall", "floor": "", "ground": "japaneseFloor"},
	{"wall": "japaneseWall2", "floor": "", "ground": "japaneseFloor"},
	{"wall": "japaneseWall3", "floor": "", "ground": "japaneseFloor"},
	{"wall": "metalicFenceWall", "floor": "", "ground": "metalicFenceFloor"},
	{"wall": "metalicFenceWall2", "floor": "", "ground": "metalicFenceFloor"},
	{"wall": "metalicGateWall", "floor": "", "ground": "metalicGateFloor"},
	{"wall": "metalicGateWall2", "floor": "", "ground": "metalicGateFloor"},
	{"wall": "metalicWall", "floor": "", "ground": "metalicFloor"},
	{"wall": "porcelinWhiteWall", "floor": "", "ground": "porcelinWhiteFloor"},
	{"wall": "rubixGameWall", "floor": "", "ground": "rubixGameFloor"},
	{"wall": "rustedMetalicWall", "floor": "", "ground": "rustedMetalicFloor"},
	{"wall": "rusticBrickWall", "floor": "", "ground": "rusticBrickFloor"},
	{"wall": "rusticBrickWall2", "floor": "", "ground": "rusticBrickFloor"},
	{"wall": "rusticBrickWall3", "floor": "", "ground": "rusticBrickFloor"},
	{"wall": "rusticBrickWall4", "floor": "", "ground": "rusticBrickFloor"},
	{"wall": "rusticWoodenWall", "floor": "", "ground": "rusticWoodenFloor"},
	{"wall": "schoolBrickWall", "floor": "", "ground": "schoolBrickFloor"},
	{"wall": "scifiBlackBlueDirtWall", "floor": "", "ground": "scifiBlackBlueFloor"},
	{"wall": "scifiBlackBlueWall", "floor": "", "ground": "scifiBlackBlueFloor"},
	{"wall": "scifiBlackBlueWall2", "floor": "", "ground": "scifiBlackBlueFloor"},
	{"wall": "scifiBlackWall", "floor": "", "ground": "scifiBlackFloor"},
	{"wall": "scifiBlackWall2", "floor": "", "ground": "scifiBlackFloor"},
	{"wall": "scifiBlackWall3", "floor": "", "ground": "scifiBlackFloor"},
	{"wall": "scifiBlackWall4", "floor": "", "ground": "scifiBlackFloor"},
	{"wall": "scifiBlackWall6", "floor": "", "ground": "scifiBlackFloor"},
	{"wall": "scifiBlackWall7", "floor": "", "ground": "scifiBlackFloor"},
	{"wall": "scifiBlueWall", "floor": "", "ground": "scifiBlueFloor"},
	{"wall": "scifiBlueWall2", "floor": "", "ground": "scifiBlueFloor"},
	{"wall": "scifiBlueWall3", "floor": "", "ground": "scifiBlueFloor"},
	{"wall": "scifiMetalWall", "floor": "", "ground": "scifiMetalFloor"},
	{"wall": "slumWall", "floor": "", "ground": "slumFloor"},
	{"wall": "snakeEdgeWall", "floor": "", "ground": "snakeEdgeFloor"},
	{"wall": "stainedMetalicWall", "floor": "", "ground": "stainedMetalicFloor"},
	{"wall": "supermarketWall", "floor": "", "ground": "supermarketFloor"},
	{"wall": "toiletWall", "floor": "", "ground": "toiletFloor"},
	{"wall": "whiteAsylumnWall", "floor": "", "ground": "whiteAsylumnFloor"},
	{"wall": "whiteMarbleWall", "floor": "", "ground": "whiteMarbleFloor"},
	{"wall": "whiteMetalicWall", "floor": "", "ground": "whiteMetalicFloor"},
	{"wall": "whiteWall", "floor": "", "ground": "whiteFloor"},
	{"wall": "wood&BlueWall", "floor": "", "ground": "wood&BlueFloor"},
	{"wall": "wood&BrickWall", "floor": "", "ground": "wood&BrickFloor"},
	{"wall": "woodenWall", "floor": "", "ground": "woodenFloor"},
	{"wall": "woodenWall2", "floor": "", "ground": "woodenFloor"},
]

## Floor spikes. Laid in short runs rather than scattered, because the trap
## carries a phase_offset for exactly that — a line of them stepping through the
## cycle rolls like a wave and can be timed, where one alone is just a tax.
@export var trap_scene: PackedScene = null
@export_range(0.0, 1.0, 0.05) var trap_chance: float = 0.35
@export var traps_per_run: Vector2i = Vector2i(3, 5)

## Extra monsters per room for each player past the first. Per *room*, so it
## multiplies by the sixteen of them — at 1.5 a four-player floor one came out
## at 92 monsters, which is a slog rather than a scaling.
@export var party_enemy_bonus: float = 0.7
## Puts everything away from the screen to sleep — rooms, props, torches,
## animals, monsters — and wakes it before it comes into view. See WorldStreamer.
@export var stream_world: bool = true
## How far past the screen edge things are already awake. Wider than a torch's
## glow, so a light just off screen is never missing from what is on it.
@export var stream_buffer: float = 512.0
## Extra distance before something awake goes back to sleep, so walking along
## the edge does not flick it on and off.
@export var stream_hysteresis: float = 256.0
## Anything this close to a player stays awake whatever the camera shows.
@export var wake_radius: float = 900.0

## Breathing room kept around the party when the camera pulls back to hold them.
@export var party_margin: float = 320.0
## How far the view is allowed to pull back. Below this the dungeon stops being
## readable, and players are better stopped from spreading than shown as ants.
@export_range(0.3, 1.0, 0.05) var camera_zoom_min: float = 0.55

## Chairs dropped on open floor beyond the one beside the spawn.
@export var extra_chairs: int = 3
## Clear floor a chair needs around it. She walks the last steps to a seat, so
## one wedged against a column is worse than no chair at all — she sets off and
## grinds into the stone.
##
## The question being asked is whether she can reach the seat, and she is about
## 66 across. This only tests props and columns now — walls are excluded, so the
## generous figure that used to compensate for the oversized wall silhouette is
## no longer needed and was costing real chairs.
@export var chair_clearance: float = 50.0
@export var grid: Vector2i = Vector2i(4, 4)
## Roofs make the layout unreadable while testing; off by default here.
@export var show_roofs: bool = false
@export var maze_seed: int = 0
## Chance an interior wall is knocked through. Higher is more open.
@export_range(0.0, 1.0) var openness: float = 0.35

@export_group("Exteriors")
## Builds each floor as a shrine compound — separate buildings standing in
## gardens, courtyards and ponds with a road running through — instead of one
## enclosed maze. See MazeExterior.
@export var exteriors: bool = true
@export var buildings_per_floor: Vector2i = Vector2i(2, 4)
## Rooms per building.
@export var building_size: Vector2i = Vector2i(2, 5)
@export var max_ponds: int = 2
## Run selection unless overridden for a direct editor launch.
@export_enum("Run selection:-1", "Sakura Gardens:0", "Bamboo Woodland:1", "Abandoned Shrines:2", "Desert Ruins:3", "Frozen Pass:4") var level_theme: int = -1
@export_range(0.0, 1.0, 0.05) var outdoor_enemy_chance: float = 0.6
@export_enum("Level theme:-1", "Sakura:0", "Desert:1", "Snow:2") var outdoor_biome: int = -1
@export_enum("Automatic:-1", "Calm:0", "Petals:1", "Rain:2", "Snowfall:3", "Sandstorm:4") var outdoor_weather: int = -1
@export_range(0.0, 1.0, 0.05) var weather_intensity: float = 1.0

@export_group("Population")
@export var enemies_per_room: Vector2i = Vector2i(0, 2)
@export var props_per_room: Vector2i = Vector2i(1, 3)
## Columns spaced between the two that flank each opening.
@export var pillars_per_opening: int = 3
## Nudges the columns along the wall's own footprint offset. 1.0 puts them on
## the centre of the stone; higher settles them further onto the wall line.
## Scaling rather than adding keeps the sideways part flipping per side, which a
## fixed nudge would not — the walls lean opposite ways on opposite sides.
@export_range(0.5, 2.5, 0.05) var pillar_wall_bias: float = 1.35
## How far a column sorts after the wall it stands against. Measured at only 4px
## without it, which is a coin flip — some columns landed behind the stone they
## were framing. The art does not move: the node drops by this much and the
## sprite rises by the same, so only the sort position changes.
@export var pillar_sort_bias: float = 26.0

@export_group("Atmosphere")
## Near-black, so the player's lantern and the braziers do the lighting.
@export var gloom: Color = Color(0.18, 0.17, 0.26)
@export var lantern_radius: float = 2.35
@export var lantern_colour: Color = Color(1.0, 0.82, 0.55)

## The standing lights that make a room readable without the player's lantern.
##
## Placed on their own rather than through the prop pool, because the pool is a
## uniform draw across eight scenes and a room could easily come up with none —
## which is the whole reason the floor was too dark to read. Light is not
## decoration, so it does not get left to chance.
@export var torch_scenes: Array[PackedScene] = []
@export var torches_per_room: Vector2i = Vector2i(1, 3)

## Harmless wildlife that wanders the rooms and scatters from anyone who comes
## close. Purely set dressing: no hitbox, never counted towards the wave.
@export var animal_scenes: Array[PackedScene] = []
@export var animals_per_room: Vector2i = Vector2i(0, 2)

## Shoji doors and windows set into the walls, as tiles in the wall layers so
## fading, sorting and light occlusion treat them exactly like the stone.
##
## A door goes into an opening the maze already carved, so it never changes the
## route — it closes one side of the gap with a doorway wall and slides open for
## whoever comes near. A window replaces a stretch of closed wall; smashed, it
## lets light, sight and slashes through but still not feet.
@export_range(0.0, 1.0) var door_chance: float = 0.3
@export_range(0.0, 1.0) var window_chance: float = 0.25

const SIDES: Array[String] = ["NE", "NW", "SE", "SW"]
## Which lattice step each side faces. This follows from the isometric transform
## rather than from looking at a render: +x moves right and down, which is SE,
## and +y moves left and down, which is SW.
const NEIGHBOUR := {
	"NE": Vector2i(0, -1),
	"SW": Vector2i(0, 1),
	"SE": Vector2i(1, 0),
	"NW": Vector2i(-1, 0),
}
## The side of the neighbouring room that faces back across the same wall.
const FACING_BACK := {"SE": "NW", "NW": "SE", "SW": "NE", "NE": "SW"}

const ARCH_DIR := "res://assets/pixellab/japanese_environment/architecture/"
## Runtime tile sources, offset from the wall direction they stand in for.
const DOOR_SOURCE: int = 100
const WINDOW_SOURCE: int = 110
const SMASHED_WINDOW_SOURCE: int = 120
## Physics bit for smashed windows: characters collide with it, but sight
## lines and slash projectiles test bit 1 alone, so they pass straight through.
const SMASHED_LAYER: int = 8
## Wall directions that have door and window art.
const ARCH_DIRS: Array[int] = [3, 5, 7]
## Each door's opening in its art, in texture pixels: left jamb x, right jamb
## x, and the gradient of the wall's ground line.
const DOORWAYS := {
	3: Vector3(56, 195, -0.5),
	5: Vector3(51, 173, 0.5),
	7: Vector3(68, 194, -0.5),
}

var _rng := RandomNumberGenerator.new()
## Which look this floor drew. Rolled rather than derived from depth: keyed to
## the depth, floor one was always aluminium and floor two always apartment, the
## same order every run. The roll comes off _rng, which is seeded from
## maze_seed, so a floor is still reproducible from its seed — it just is not
## the same floor for everybody.
var _theme_index: int = -1
## Set once this wave's monsters are standing. Without it the very first frame
## after a rebuild — before _populate has run — looks like a cleared room, and
## the next wave would start instantly and forever.
var _wave_live: bool = false
var _clearing: bool = false
const MUSIC_DANGER_RELEASE: float = 8.0
var _music_danger: bool = false
var _music_safe_time: float = 0.0
var _music_event: String = ""
## The level-up screen is open between floors.
var _upgrading: bool = false
## Set when a lost pad is what paused the floor, so reconnecting only lifts
## its own pause and never one owned by the pause menu or game over.
var _paused_for_reconnect: bool = false
## Per-floor kill progress shown on the HUD. Total counts only enemies that
## were successfully instantiated; killed increments from each enemy's death
## signal before its corpse starts the fade/free sequence.
var enemies_killed: int = 0
var enemies_total: int = 0
## When this wave began, for the speed bonus.
var _wave_started: float = 0.0
var _boss_placed: bool = false
var _streamer: WorldStreamer = null
## What the party was worth on wave one, so scaling is applied to the original
## numbers each wave rather than compounding on last wave's result.
var _party_base: Dictionary = {}
## Themes already used this run, so a short descent does not show the same
## walls twice before it has shown sixty-four other options.
var _themes_used: Array[int] = []
## Every player, in slot order. _player stays as player one for the HUD.
var _players: Array[Node2D] = []
var _rooms: Dictionary = {}
var _bot_floors: Array[TileMapLayer] = []
var _bot_floor_bounds: Array[Rect2] = []
## How deep the run has gone. HUD reads this; each floor adds monsters.
var depth: int = 1
var _player: Node2D = null
## Every monster scene seen so far this run, kept resident rather than swapped
## one at a time. The sheets are a few MB each on disk — nothing like the
## multi-gigabyte estimate the single-type design below was written against —
## so holding all nine once they have each been used costs a few hundred MB,
## not the eight-plus it would have taken to keep them as ext_resources from
## the start.
var _monster_cache: Dictionary = {}
## This floor's room-to-monster assignment, one draw per room rather than one
## for the whole floor — see _build, where it is filled.
var _room_monster: Dictionary = {}
## Guards the shuffle bag's reshuffle against repeating whatever the last draw
## handed out, whether that was the last room of this floor or the first one.
var _last_drawn_path: String = ""
## Shuffle bag for monster-type rotation: a shuffled copy of enemy_scene_paths
## that gets drawn from one at a time, so every type is seen once before any
## of them repeats, instead of a plain random roll that can land on the same
## monster floor after floor by chance.
var _wave_bag: Array[String] = []
## A build runs across several frames now, so it can be in progress when
## something else would start another. Guards the rebuild on the stairs against
## a wave that reports itself cleared mid-build.
var _building: bool = false
## "<room name>/<side>" for the open half of every doored gap, so no column is
## stood in the doorway.
var _door_skip: Dictionary = {}
## This floor's compound plan when `exteriors` is on, otherwise null.
var _ext: MazeExterior = null
var day_night := DayNightCycle.new()
@export_range(0.0, 600.0, 1.0) var day_night_start_seconds: float = 0.0
var _last_daylight_weight: float = -1.0
var _level_theme: LevelTheme = null
var _weather: OutdoorWeather = null
## Where the party arrives and the one room left free of monsters.
var _start_cell := Vector2i.ZERO


func _ready() -> void:
	Roster.clear_party_control()
	Roster.party_control_changed.connect(_on_party_control_changed)
	var pending_floor := NetworkManager.consume_pending_floor()
	if not pending_floor.is_empty():
		maze_seed = int(pending_floor.get("seed", maze_seed))
		level_theme = int(pending_floor.get("theme", level_theme))
	if NetworkManager.is_client:
		NetworkManager.server_lost.connect(_on_online_ended.bind("server_lost"))
		NetworkManager.match_ended.connect(_on_online_ended)
	day_night.elapsed = day_night_start_seconds
	if room_scene == null:
		push_warning("MazeDemo: no room_scene set.")
		return
	## Smashed windows still stop anyone walking through them, on a physics bit
	## of their own. Everything that collides with walls gets that bit as it
	## arrives, so players, monsters and summons need no per-scene setup.
	get_tree().node_added.connect(_on_node_added)
	for node in find_children("*", "", true, false):
		_on_node_added(node)
	## Zero means roll one. The scene used to carry maze_seed = 12345, so every
	## run of the game built the identical dungeon — same maze, same rooms, same
	## props, every launch. Set it to a fixed number again only to reproduce a
	## specific floor while debugging.
	if maze_seed == 0:
		maze_seed = randi()
	## Keeps the loading screen up through the build. A no-op when there is no
	## screen — running this scene straight from the editor still works, it just
	## builds without anything covering it.
	SceneLoader.hold()
	await _build()
	if not is_inside_tree():
		return
	SceneLoader.finish()


func _exit_tree() -> void:
	Roster.clear_party_control()


func refresh_party_control() -> void:
	if not _building and not NetworkManager.is_client:
		Roster.update_party_control(_players)


func _on_party_control_changed(_previous: int, _controlled: int) -> void:
	_pass_through_each_other()


## Next floor. Rebuilds around the player rather than reloading the scene, so
## she keeps her health, her buffs and her state machine across the descent —
## a reload would construct a fresh one and throw all of that away.
func descend() -> void:
	_descend_with(_rng.randi(), depth + 1)
	NetworkManager.announce_descend(maze_seed, depth)


## A client's descent. The server has already rolled the next floor's seed and
## sent it over; building from the same seed yields the same maze, so only the
## seed needs to cross the wire rather than the floor itself.
func descend_to(seed: int, new_depth: int) -> void:
	if _building:
		return
	_clearing = true
	_descend_with(seed, new_depth)


func _descend_with(seed: int, new_depth: int) -> void:
	_building = true
	if is_instance_valid(_weather):
		_weather.stop()
	_weather = null
	depth = new_depth
	maze_seed = seed
	## Everyone who is playing survives the descent, not just player one. This
	## used to spare `_player` alone, which with a party meant players two to
	## four were freed with the floor — and because queue_free is deferred,
	## _players still reported them as present, so _spawn_player did not replace
	## them either and the party simply vanished on the stairs.
	var keep: Array[Node] = []
	for body in _players:
		if is_instance_valid(body):
			keep.append(body)
	## The camera outlives a floor too. It is a plain Node2D child, so it used to
	## be freed with the level — and because queue_free is deferred, the rebuild
	## then found the doomed camera still in the tree, reused it, and lost it at
	## the end of the frame. The next floor had no camera at all and the view
	## stayed where the stairs had been.
	var lens := get_node_or_null("PartyCamera")
	for child in get_children():
		## The players, the camera, the gloom and the HUD layers outlive a floor.
		if child in keep or child == lens or child is CanvasLayer \
				or child is CanvasModulate:
			continue
		child.queue_free()
	## Dropped any that died and were freed, so the next floor spawns a fresh
	## body for their slot rather than counting a dangling reference.
	_players = []
	for body in keep:
		_players.append(body)
	_rooms.clear()
	_bot_floors.clear()
	_bot_floor_bounds.clear()
	_streamer = null
	_wave_live = false
	_clearing = false
	_music_event = ""
	_music_danger = false
	_music_safe_time = 0.0
	## One frame for the queue_free calls above to actually happen. They are
	## deferred, so until the frame ends every monster on the old floor is still
	## alive and still holding a reference to its sprite sheets — dropping the
	## PackedScene now would free nothing, and the next floor's type would load
	## on top of the last one's instead of in place of it.
	if not await _next_frame():
		return
	SceneLoader.begin("DESCENDING", "WAVE %d" % depth)
	await _build()
	if not is_inside_tree():
		return
	SceneLoader.finish()
	_announce_floor()


## A floor build spans many frames and can be cancelled when the last online
## peer disconnects. The SceneTree outlives this node, so waiting on the main
## loop is safe even after the current scene has been removed. Every caller
## checks the result before touching the detached MazeDemo again.
func _next_frame() -> bool:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null:
		return false
	await loop.process_frame
	return is_inside_tree()


## Picks this floor's look at random, avoiding anything already seen this run.
##
## Falls back to a plain roll once every theme has been used, rather than
## refusing to pick — sixty-four floors is deeper than anyone will go, but a
## generator that can run out is a generator that will.
func _roll_theme() -> void:
	if THEMES.is_empty():
		return
	var allowed: Array[int] = []
	for i in THEMES.size():
		if _level_theme == null or _level_theme.walls.has(THEMES[i]["wall"]):
			allowed.append(i)
	if allowed.is_empty():
		push_error("MazeDemo: selected level theme has no compatible architecture.")
		return
	var fresh: Array[int] = []
	for i in allowed:
		if not _themes_used.has(i):
			fresh.append(i)
	if fresh.is_empty():
		for i in allowed:
			_themes_used.erase(i)
		fresh = allowed
	var visual_rng := RandomNumberGenerator.new()
	visual_rng.seed = maze_seed ^ 0x5448454d
	_theme_index = fresh[visual_rng.randi_range(0, fresh.size() - 1)]
	_themes_used.append(_theme_index)


## Dresses every room in this depth's theme: walls, ground and floor layer.
##
## The cells for a themed floor layer are copied from the room's own Ground
## layer rather than authored into a second prefab, so a themed floor is exactly
## the shape of the dungeon one and no room has to be drawn twice.
func _theme_floor() -> void:
	## Dedicated exports replace texture atlases with placeholders. Collision is
	## authored on the room already; repainting it is visual-only.
	if OS.has_feature("dedicated_server"):
		return
	if THEMES.is_empty():
		return
	if _theme_index < 0:
		_roll_theme()
	var theme: Dictionary = THEMES[_theme_index]
	_theme_walls(theme["wall"])
	_theme_pillars(theme["wall"])
	_theme_roofs(theme["wall"])

	var layer_name: String = theme["floor"]
	if _level_theme != null and theme["wall"].begins_with("japanese"):
		layer_name = "Floor_JP_Indoor"
	for cell in _rooms:
		var room: Node = _rooms[cell]
		var ground := room.get_node_or_null("TileMap/Ground") as TileMapLayer
		if ground == null:
			continue
		if ground.tile_set != null:
			_repoint(ground.tile_set, theme["ground"])
		## Every themed layer off first, so moving between themes does not leave
		## the last one showing underneath.
		for other_name in ["Floor_JP_Indoor", "Floor_JP_Exterior"]:
			var other := room.get_node_or_null("TileMap/" + other_name) as TileMapLayer
			if other != null:
				other.visible = false
				other.clear()
		ground.visible = layer_name == ""
		if layer_name == "":
			continue
		var layer := room.get_node_or_null("TileMap/" + layer_name) as TileMapLayer
		if layer == null or layer.tile_set == null:
			ground.visible = true
			continue
		## A handful of materials for the whole floor rather than a different
		## tile per cell — sixteen variants scattered at random reads as
		## confetti, not as a room somebody laid.
		var palette: Array[int] = []
		var sources: int = layer.tile_set.get_source_count()
		if sources == 0:
			ground.visible = true
			continue
		for _i in mini(3, sources):
			palette.append(layer.tile_set.get_source_id(_rng.randi() % sources))
		for at in ground.get_used_cells():
			layer.set_cell(at, palette[_rng.randi() % palette.size()], Vector2i.ZERO)
		layer.visible = true
	## Open ground gets earth, grass, gravel and paving instead, whatever the
	## theme laid indoors.
	if _ext != null:
		_ext.paint_ground()


## Candidate material names for a wall set, most specific first.
func _pillar_names(wall_prefix: String) -> Array[String]:
	var out: Array[String] = []
	var bare: String = wall_prefix
	while bare.length() > 0 and bare[bare.length() - 1].is_valid_int():
		bare = bare.substr(0, bare.length() - 1)
	for candidate in [wall_prefix, bare, wall_prefix.trim_suffix("Wall"),
			bare.trim_suffix("Wall")]:
		if candidate != "" and not out.has(candidate):
			out.append(candidate)
	## Then by dropping trailing words: scifiBlackBlueDirt has no column of its
	## own but scifiBlackBlue does, and it is the same material with grime on it.
	var trimmed: String = bare.trim_suffix("Wall")
	while trimmed.length() > 1:
		var cut: int = -1
		for i in range(trimmed.length() - 1, 0, -1):
			if trimmed[i] == trimmed[i].to_upper() and trimmed[i] != trimmed[i].to_lower():
				cut = i
				break
		if cut <= 0:
			break
		trimmed = trimmed.substr(0, cut)
		if not out.has(trimmed):
			out.append(trimmed)
	return out


## Dresses the columns in the same material as the walls.
##
## Looks for pillar_<material>.png beside the default and leaves the stone one
## in place when there is none, so this does nothing until that art exists and
## then starts working with no further change. The material name is the wall
## prefix with its trailing "Wall" removed, which is how the wall sets are named.
func _theme_pillars(wall_prefix: String) -> void:
	if WorldObjects.family_of(pillar_scene) == "pillar":
		return
	## Tried from most specific to least: the set's own name, then with any
	## trailing number dropped, then with "Wall" trimmed. Twenty-four of the
	## sixty-four sets are numbered variants — casinoWall2, rusticBrickWall3 —
	## and they share their base material's column rather than going bare.
	var texture: Texture2D = null
	for material in _pillar_names(wall_prefix):
		var art: String = "res://assets/sprites/props/pillars/pillar_%s.png" % material
		if ResourceLoader.exists(art):
			texture = load(art) as Texture2D
			break
	if texture == null:
		return
	for node in get_children():
		if not node.name.begins_with("Pillar"):
			continue
		var sprite := node.get_node_or_null("Sprite2D") as Sprite2D
		if sprite != null:
			sprite.texture = texture


## Repoints the wall tiles at a different set of textures.
##
## Each atlas source is asked what it is currently showing and given the same
## direction from the new set, so this does not depend on the sources being in
## any particular order — it reads dirN out of the existing path and keeps it.
func _theme_walls(prefix: String) -> void:
	if prefix == "":
		return
	var done: Dictionary = {}
	for cell in _rooms:
		var room: Node = _rooms[cell]
		for side in ["NE", "NW", "SE", "SW"]:
			var layer := room.get_node_or_null("TileMap/Walls_" + side) as TileMapLayer
			if layer == null or layer.tile_set == null:
				continue
			## All four sides share one TileSet, and scene sub-resources are
			## shared between room instances, so without this the same swap runs
			## sixty-four times a floor.
			var id: int = layer.tile_set.get_instance_id()
			if done.has(id):
				continue
			done[id] = true
			_repoint(layer.tile_set, prefix)


const ROOF_SHADER: Shader = preload("res://shaders/roofWall.gdshader")
const WALL_ART: String = "res://assets/crocotile/isometrictiles/walls/%s_dir%d.png"
var _roof_material: ShaderMaterial


## Builds every roof from the same material as the walls under it.
##
## The roof art only comes in two materials, so rather than repointing it the
## roof layers share one shader that paints the wall set's face onto each side
## of the roof blocks.
func _theme_roofs(prefix: String) -> void:
	if _ext != null and _ext.japanese_roofs():
		return
	var right: String = WALL_ART % [prefix, 3]
	var left: String = WALL_ART % [prefix, 5]
	if prefix == "" or not ResourceLoader.exists(right) or not ResourceLoader.exists(left):
		return
	if _roof_material == null:
		_roof_material = ShaderMaterial.new()
		_roof_material.shader = ROOF_SHADER
	_roof_material.set_shader_parameter("wall_right", load(right))
	_roof_material.set_shader_parameter("wall_left", load(left))
	for cell in _rooms:
		var roofs := _rooms[cell].get_node_or_null("TileMap/Roofs") as TileMapLayer
		if roofs != null and not roofs.is_queued_for_deletion():
			roofs.material = _roof_material


func _repoint(tiles: TileSet, prefix: String) -> void:
	for i in tiles.get_source_count():
		var source := tiles.get_source(tiles.get_source_id(i)) as TileSetAtlasSource
		if source == null or source.texture == null:
			continue
		var was: String = source.texture.resource_path
		var dir: String = was.get_file().get_basename().split("_dir")[-1]
		if not dir.is_valid_int():
			continue
		## Built in the texture's own folder, which is what keeps this safe on the
		## ground tileset: that one holds blocks, slopes and stairs alongside the
		## flat floor, and they live in sibling folders. Asking for
		## blocks/grassTile_dir1.png finds nothing, so only the floor swaps and
		## the geometry pieces are left as they are.
		var wanted: String = "%s/%s_dir%s.png" % [was.get_base_dir(), prefix, dir]
		## Left alone when the set has no art for a direction, so a half-finished
		## wall set degrades to the old look rather than to blank tiles.
		if wanted != was and ResourceLoader.exists(wanted):
			source.texture = load(wanted)


## Says which floor she has arrived on, briefly, in the middle of the screen.
##
## The stairs used to drop you to a new floor with no acknowledgement at all —
## the only sign was the small FLOOR counter in the corner, so walking onto them
## read as being teleported by a glitch rather than as descending.
func _announce_floor(text: String = "") -> void:
	AudioManager.play("ui_floor_announce", -3.0)
	var layer := get_node_or_null("FloorLayer") as CanvasLayer
	if layer == null:
		layer = CanvasLayer.new()
		layer.name = "FloorLayer"
		layer.layer = 80
		add_child(layer)
		var note := Label.new()
		note.name = "Note"
		note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		note.set_anchors_preset(Control.PRESET_FULL_RECT)
		note.add_theme_font_size_override("font_size", 44)
		note.add_theme_color_override("font_color", Color(0.85, 0.72, 0.42))
		layer.add_child(note)
	var note := layer.get_node_or_null("Note") as Label
	if note == null:
		return
	note.text = text if text != "" else "WAVE %d" % depth
	note.modulate.a = 1.0
	## Holds, then fades. Long enough to read on arrival, short enough that it is
	## not in the way of the first room.
	var fade := create_tween()
	fade.tween_interval(1.4)
	fade.tween_property(note, "modulate:a", 0.0, 0.9)


## Builds the floor across several frames rather than all inside one.
##
## Sixteen rooms, their monsters, props, torches and columns used to be built in
## a single pass inside _ready, which meant the window was frozen from the moment
## the dungeon opened until it was finished. Yielding a frame between rooms costs
## nothing in total time and lets the loading screen draw, so the wait reads as a
## wait rather than as a hang.
func _build() -> void:
	_building = true
	depth = maxi(depth, start_depth)
	_rng.seed = maze_seed
	if _level_theme == null:
		_level_theme = LevelTheme.definition(level_theme if level_theme >= 0 else maxi(Roster.level_theme, 0))
	_roll_theme()
	var step := _lattice_step()
	_start_cell = Vector2i((grid.x - 1) / 2, (grid.y - 1) / 2)
	_ext = null
	if exteriors:
		_ext = MazeExterior.new(self, _rng, grid, step)
		_ext.theme = _level_theme
		_ext.biome = _level_theme.exterior_biome()
		var reason := _ext.biome.unavailable_reason()
		if outdoor_biome >= 0 and outdoor_biome != _ext.biome.id:
			_ext.biome = ExteriorBiome.select(outdoor_biome, maze_seed)
			if _ext.biome.id == ExteriorBiome.Id.SAKURA:
				_ext.biome = _level_theme.exterior_biome() \
						if _level_theme.biome == ExteriorBiome.Id.SAKURA \
						else LevelTheme.definition(LevelTheme.Id.SAKURA_GARDENS).exterior_biome()
			else:
				_ext.theme = null
		elif not reason.is_empty():
			push_warning("MazeDemo: %s biome unavailable (%s); using sakura." % [
					_level_theme.display_name, reason])
			_ext.biome = LevelTheme.definition(LevelTheme.Id.SAKURA_GARDENS).exterior_biome()
		_ext.plan()
		_start_cell = _ext.start_cell
		_ext.make_safe_room(_start_cell)
	await _load_floor_monsters(_start_cell)
	if not is_inside_tree():
		return

	var rooms_total: float = float(maxi(grid.x * grid.y, 1))
	var built: float = 0.0
	for iy in grid.y:
		for ix in grid.x:
			var cell := Vector2i(ix, iy)
			var room = room_scene.instantiate()
			room.name = "Room_%d_%d" % [ix, iy]
			add_child(room)
			room.position = _lattice_position(cell, step)
			## Every room carries a CanvasModulate; several stacked just fight.
			var light: Node = room.get_node_or_null("Lighting")
			if light:
				light.free()
			## Roofs only on buildings: open ground has no ceiling to lift.
			var roofed: bool = _ext.is_building(cell) if _ext != null else show_roofs
			if not roofed:
				var roofs: Node = room.get_node_or_null("TileMap/Roofs")
				if roofs:
					roofs.queue_free()
			_rooms[cell] = room
			if _ext != null and _rooms.size() == 1:
				_ext.measure(room)
			built += 1.0
			SceneLoader.step(0.25 + 0.35 * (built / rooms_total),
					"BUILDING ROOMS  %d/%d" % [int(built), int(rooms_total)])
			if not await _next_frame():
				return

	SceneLoader.step(0.62, "CARVING THE MAZE")
	_carve()
	_place_architecture()
	_build_wall_occluders()
	if _ext != null:
		_ext.setup_roofs()
		_ext.build_ponds()
		_ext.build_perimeter()
		_ext.guard_entrances()
	if not await _next_frame():
		return
	SceneLoader.step(0.68, "RAISING COLUMNS")
	_place_pillars()
	if not await _next_frame():
		return
	SceneLoader.step(0.74, "LIGHTING THE FLOOR")
	_spawn_player(step)
	if _level_theme != null:
		AudioManager.play_ambience("amb_%s" % LevelTheme.NAMES[_level_theme.id])
	## After _spawn_player, which is where the floor is themed: the windows are
	## painted onto whichever wall texture this floor ended up with.
	_paint_windows()
	_place_starting_chair()
	if not await _next_frame():
		return
	await _populate(step)
	if not is_inside_tree():
		return
	SceneLoader.step(0.98, "CLEARING THE WAY")
	await _clear_buried_chairs()
	## Armed only now: _populate has run, so an empty room from here really does
	## mean the wave was cleared rather than that it has not started.
	_wave_live = true
	_set_adaptive_music(false)
	_light()
	if _ext != null and not OS.has_feature("dedicated_server"):
		_weather = OutdoorWeather.new()
		_weather.name = "OutdoorWeather"
		add_child(_weather)
		_weather.setup(_ext, maze_seed, outdoor_weather, weather_intensity)
	if stream_world:
		_streamer = WorldStreamer.new()
		_streamer.name = "WorldStreamer"
		_streamer.buffer = stream_buffer
		_streamer.hysteresis = stream_hysteresis
		_streamer.player_reach = wake_radius
		add_child(_streamer)
		_streamer.setup(self, _rooms.values())
	_building = false


## Draws one monster type from the shuffle bag, refilling and reshuffling once
## it runs dry. Keeps the previous draw out of the reshuffle's last slot where
## possible, so a refill cannot hand back the same type twice in a row right as
## the bag turns over. Shuffled with _rng rather than the global RNG, so a
## seeded run reshuffles the same way every time.
func _next_wave_path() -> String:
	if _wave_bag.is_empty():
		_wave_bag = enemy_scene_paths.duplicate()
		for i in range(_wave_bag.size() - 1, 0, -1):
			var j: int = _rng.randi_range(0, i)
			var tmp: String = _wave_bag[i]
			_wave_bag[i] = _wave_bag[j]
			_wave_bag[j] = tmp
		## pop_back() draws from the END of the bag, not the front — this used
		## to check and swap index 0, which guarded the slot that would be
		## drawn LAST out of a fresh bag rather than the one about to be
		## handed out next, so a reshuffle could still repeat the previous
		## draw immediately.
		var last: int = _wave_bag.size() - 1
		if _wave_bag.size() > 1 and _wave_bag[last] == _last_drawn_path:
			var swap_with: int = _rng.randi() % last
			var tmp: String = _wave_bag[last]
			_wave_bag[last] = _wave_bag[swap_with]
			_wave_bag[swap_with] = tmp
	var drawn: String = _wave_bag.pop_back()
	_last_drawn_path = drawn
	return drawn


## Loads `path` if it is not already cached, threaded so the loading screen
## keeps drawing while the sheet comes off disk. Every type that has ever been
## drawn stays cached for the rest of the run — see _monster_cache for why
## that is cheap enough to afford.
func _ensure_monster_loaded(path: String) -> PackedScene:
	if _monster_cache.has(path):
		return _monster_cache[path]
	if not ResourceLoader.exists(path):
		push_error("MazeDemo: no monster scene at %s" % path)
		return null
	ResourceLoader.load_threaded_request(path, "", true)
	while true:
		var progress: Array = []
		var status := ResourceLoader.load_threaded_get_status(path, progress)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			var done: float = float(progress[0]) if not progress.is_empty() else 0.0
			SceneLoader.step(0.25 + done * 0.1,
					"SUMMONING %s" % path.get_file().get_basename().to_upper())
			if not await _next_frame():
				return null
			continue
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			var packed := ResourceLoader.load_threaded_get(path) as PackedScene
			_monster_cache[path] = packed
			return packed
		push_error("MazeDemo: failed to load %s" % path)
		return null
	return null


## Draws and loads this floor's room-to-monster assignment: one type per
## room-that-is-not-the-start, rather than one type for the whole floor, so a
## single descent shows a mix of monsters instead of nine copies of whichever
## type the floor rolled.
func _load_floor_monsters(start: Vector2i) -> void:
	_room_monster.clear()
	if enemy_scene_paths.is_empty():
		return
	for iy in grid.y:
		for ix in grid.x:
			var cell := Vector2i(ix, iy)
			if cell == start:
				continue
			var wanted: String = _next_wave_path()
			var packed: PackedScene = await _ensure_monster_loaded(wanted)
			if not is_inside_tree():
				return
			if packed != null:
				_room_monster[cell] = packed
	SceneLoader.step(0.25, "WAVE %d" % depth)


## Drops monsters and breakables into the rooms. The room the player starts in
## is left clear so she is not swung at before taking a step.
func _animal_palette(cell: Vector2i, outdoors: bool) -> Array[PackedScene]:
	if _level_theme == null:
		return animal_scenes
	var names: Array[String] = _level_theme.outdoor_animals.duplicate() if outdoors else _level_theme.indoor_animals.duplicate()
	if outdoors and _ext.is_pond(cell):
		names.append_array(_level_theme.pond_animals)
	var result: Array[PackedScene] = []
	for name in names:
		for scene in animal_scenes:
			if scene.resource_path.get_file().get_basename() == name:
				result.append(scene)
				break
	return result


func _populate(step: Vector2) -> void:
	_wave_started = Time.get_ticks_msec() * 0.001
	enemies_killed = 0
	enemies_total = 0
	Score.begin_floor()
	Progression.begin_floor()
	_boss_placed = false
	_scale_party()
	var start := _start_cell
	var rooms_total: float = float(maxi(_rooms.size(), 1))
	var filled: float = 0.0
	for cell in _rooms:
		var here: Node2D = _rooms[cell]
		## Open ground is dressed first, so the monsters below are then kept
		## off its trees and out of its ponds by _place.
		var outdoors: bool = _ext != null and not _ext.is_building(cell)
		if outdoors:
			_ext.populate(cell)
		var monster_scene: PackedScene = _room_monster.get(cell)
		if outdoors and _rng.randf() >= outdoor_enemy_chance:
			monster_scene = null
		if monster_scene != null and cell != start:
			## Scaled by the party. A floor built for one is a walkover for four,
			## and the extra bodies also have to be worth the extra katanas.
			var party: int = maxi(Roster.count(), 1)
			var n: int = _rng.randi_range(enemies_per_room.x, enemies_per_room.y) \
					+ depth - 1 + int(round(float(party - 1) * party_enemy_bonus))
			for i in n:
				var monster = _place(here, monster_scene)
				if monster is EnemyBase:
					monster.network_id = enemies_total
					enemies_total += 1
					monster.died.connect(_on_enemy_died)
				if monster != null and monster.has_method("apply_tier"):
					## Boss waves put one lord in the middle room's neighbour and
					## fill the rest from the pool, so a boss wave reads as a
					## boss wave rather than as six of them at once.
					var rung: int = EnemyTier.roll(depth, _rng)
					if EnemyTier.is_boss_wave(depth) and not _boss_placed:
						rung = 6
						_boss_placed = true
					monster.apply_tier(rung, depth)
		var prop_pool := _prop_pool()
		if cell != start and not prop_pool.is_empty() and not outdoors:
			var m: int = _rng.randi_range(props_per_room.x, props_per_room.y)
			for i in m:
				var family: Array = prop_pool[_rng.randi_range(0, prop_pool.size() - 1)]
				_place(here, family[0])
		## Guaranteed, not rolled. Every room lights itself rather than relying
		## on the lantern the player carries — a dark room is unreadable, and a
		## uniform draw from the prop pool would leave some rooms with none.
		if not torch_scenes.is_empty() and not outdoors:
			var lights: int = _rng.randi_range(torches_per_room.x, torches_per_room.y)
			for i in lights:
				_place(here, torch_scenes[_rng.randi_range(0, torch_scenes.size() - 1)])
		## Not in the start room, so nothing bolts from under the player's feet
		## the moment the floor appears.
		var wildlife := _animal_palette(cell, outdoors)
		if not wildlife.is_empty() and cell != start:
			var density: float = _level_theme.animal_density if _level_theme != null else 1.0
			var critters: int = int(round(_rng.randi_range(animals_per_room.x, animals_per_room.y) * density))
			for i in critters:
				_place(here, wildlife[_rng.randi_range(0, wildlife.size() - 1)])
		if cell != start and not table_scenes.is_empty() and not outdoors and _rng.randf() < table_chance:
			_place_dining_set(here)
		if trap_scene != null and cell != start and not outdoors and _rng.randf() < trap_chance:
			_place_trap_run(here)


func _on_enemy_died() -> void:
	enemies_killed = mini(enemies_killed + 1, enemies_total)


var _prop_pool_cache: Array = []


## Every spawnable prop as a list of interchangeable scenes: a single scene for
## one-view props, all four facings for the isometric ones.
func _prop_pool() -> Array:
	if not _prop_pool_cache.is_empty():
		return _prop_pool_cache
	for scene in prop_scenes:
		if scene != null:
			_prop_pool_cache.append([scene])
	var facing := RegEx.create_from_string("_(?:(south|north)(East|West)|dir[1-8])\\.tscn$")
	var groups := {}
	for scene in facing_prop_scenes:
		if scene == null:
			continue
		var key := facing.sub(scene.resource_path, "")
		if not groups.has(key):
			groups[key] = []
			_prop_pool_cache.append(groups[key])
		groups[key].append(scene)
	for family in WorldObjects.catalog()["families"]:
		if String(family).ends_with("_unlit"):
			_prop_pool_cache.append([WorldObjects.scene(family)])
	return _prop_pool_cache


## Puts one thing on a random floor tile of `room`, so nothing lands in a wall
## or out in the void.
func _place(room: Node2D, scene: PackedScene) -> Node:
	if scene == null:
		return null
	var ground := room.get_node_or_null("TileMap/Ground") as TileMapLayer
	if ground == null:
		return null
	var cells := ground.get_used_cells()
	if cells.is_empty():
		return null
	var thing = WorldObjects.choose(scene, _rng).instantiate()
	## Chairs also arrive through the prop pool, and want turning just the same.
	if thing.has_method("face_randomly"):
		thing.face_randomly(_rng)
	add_child(thing)
	var spot: Vector2 = ground.to_global(
		ground.map_to_local(cells[_rng.randi_range(0, cells.size() - 1)]))
	## Out of the ponds and off the trees on open ground. A crowded cell may have
	## no clear spot at all, so the last resort only insists on dry land.
	if _ext != null:
		var tries: int = 0
		while tries < 80 and (_ext.blocked(spot) if tries < 40 else _ext.wet(spot)):
			spot = ground.to_global(
				ground.map_to_local(cells[_rng.randi_range(0, cells.size() - 1)]))
			tries += 1
	var attempts := 0
	while not _party_clear(spot, 100.0) and attempts < 80:
		spot = ground.to_global(ground.map_to_local(cells[_rng.randi_range(0, cells.size() - 1)]))
		attempts += 1
	if not _party_clear(spot, 100.0) or (_ext != null and _ext.wet(spot)):
		thing.queue_free()
		return null
	thing.global_position = spot
	return thing


func _party_clear(where: Vector2, radius: float) -> bool:
	for body in _players:
		if is_instance_valid(body) and body.global_position.distance_to(where) < radius:
			return false
	return true


## Drops the whole floor into gloom and gives the player a lantern, so the maze
## is lit by what she carries rather than being evenly visible everywhere.
func _light() -> void:
	if OS.has_feature("dedicated_server"):
		return
	if not has_node("Gloom"):
		var tint := CanvasModulate.new()
		tint.name = "Gloom"
		tint.color = Color(0.48, 0.46, 0.42).lerp(gloom, day_night.night_weight())
		add_child(tint)
	if _ext != null:
		_ext.light()

	for carrier in _players:
		if not is_instance_valid(carrier):
			continue
		## The player must not shadow herself. Her occluder is useful only when
		## casting onto the world, but LightOccluder2D cannot exclude its parent
		## light's own sprite from that shadow — disable this occluder instead.
		for occluder_node in carrier.find_children("*", "LightOccluder2D", true, false):
			var player_occluder := occluder_node as LightOccluder2D
			player_occluder.occluder_light_mask = 0
		if carrier.has_node("Lantern"):
			continue
		var lamp := PointLight2D.new()
		lamp.name = "Lantern"
		lamp.texture = _glow()
		lamp.color = lantern_colour
		lamp.energy = 1.1
		lamp.texture_scale = lantern_radius
		lamp.shadow_enabled = true
		## Sits at her torso. Her origin is now her feet, so this is measured up
		## from the ground rather than out from the middle of her.
		lamp.position = Vector2(0, -40)
		carrier.add_child(lamp)
	_update_daylight(true)


func _update_daylight(force: bool = false) -> void:
	var weight := day_night.night_weight()
	if not force and is_equal_approx(weight, _last_daylight_weight):
		return
	_last_daylight_weight = weight
	var tint := get_node_or_null("Gloom") as CanvasModulate
	if tint != null:
		tint.color = Color(0.48, 0.46, 0.42).lerp(gloom, weight)
	if _ext != null:
		_ext.update_daylight(weight)


## Mirrors the authored collision geometry onto light occluders without
## changing the collision shapes. Wall tile collision polygons are the source
## of truth, so hand-edited wall shapes keep controlling both blocking and
## shadows.
func _build_wall_occluders() -> void:
	for room in _rooms.values():
		for side in ["NE", "NW", "SE", "SW"]:
			var layer := room.get_node_or_null("TileMap/Walls_" + side) as TileMapLayer
			if layer == null or not layer.enabled:
				continue
			for cell in layer.get_used_cells():
				var tile_data := layer.get_cell_tile_data(cell)
				if tile_data == null:
					continue
				var alternative: int = layer.get_cell_alternative_tile(cell)
				var points: PackedVector2Array
				for polygon_index in tile_data.get_collision_polygons_count(0):
					points = tile_data.get_collision_polygon_points(0, polygon_index)
					if points.size() < 3:
						continue
					points = _transform_tile_polygon(points, alternative)
					var polygon := OccluderPolygon2D.new()
					polygon.polygon = points
					var occluder := LightOccluder2D.new()
					occluder.occluder = polygon
					layer.add_child(occluder)
					occluder.position = layer.map_to_local(cell)


## Applies the same flip/transpose flags used by TileMapLayer to its collision
## polygon before that polygon is copied to a LightOccluder2D.
func _transform_tile_polygon(points: PackedVector2Array,
		alternative: int) -> PackedVector2Array:
	var transformed := points.duplicate()
	for i in transformed.size():
		var point := transformed[i]
		if (alternative & TileSetAtlasSource.TRANSFORM_TRANSPOSE) != 0:
			point = Vector2(point.y, point.x)
		if (alternative & TileSetAtlasSource.TRANSFORM_FLIP_H) != 0:
			point.x = -point.x
		if (alternative & TileSetAtlasSource.TRANSFORM_FLIP_V) != 0:
			point.y = -point.y
		transformed[i] = point
	return transformed


## A soft round falloff, built rather than shipped as an asset.
func _glow() -> GradientTexture2D:
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 1))
	ramp.set_color(1, Color(1, 1, 1, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = ramp
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 256
	tex.height = 256
	return tex




## Carves the maze. A randomised depth-first spanning tree first, so every room
## is reachable from every other, then extra walls knocked through on top to add
## loops and open the place up.
##
## Purely random walls left rooms sealed off with no way in, which read as a
## maze that was simply too tight.
func _carve() -> void:
	var walls: Dictionary = {}          ## Vector2i cell -> {side: closed}
	for cell in _rooms:
		walls[cell] = {}
		for side in SIDES:
			walls[cell][side] = true

	if _ext != null:
		_ext.carve(walls)
		for cell in _rooms:
			var room = _rooms[cell]
			if room.has_method("set_side"):
				for side in SIDES:
					room.set_side(side, walls[cell][side])
		return

	## Spanning tree.
	var visited: Dictionary = {Vector2i.ZERO: true}
	var stack: Array[Vector2i] = [Vector2i.ZERO]
	while stack.size() > 0:
		var cell: Vector2i = stack[-1]
		var options: Array[String] = []
		for side in SIDES:
			var other: Vector2i = cell + NEIGHBOUR[side]
			if _rooms.has(other) and not visited.has(other):
				options.append(side)
		if options.is_empty():
			stack.pop_back()
			continue
		var side: String = options[_rng.randi_range(0, options.size() - 1)]
		var next: Vector2i = cell + NEIGHBOUR[side]
		_open_pair(walls, cell, side)
		visited[next] = true
		stack.append(next)

	## Extra openings for loops, so it is not a pure tree with one route.
	for cell in _rooms:
		for side in SIDES:
			if not _rooms.has(cell + NEIGHBOUR[side]):
				continue
			if _rng.randf() < openness:
				_open_pair(walls, cell, side)

	for cell in _rooms:
		var room = _rooms[cell]
		if not room.has_method("set_side"):
			continue
		for side in SIDES:
			room.set_side(side, walls[cell][side])


## Opens a wall from both sides. A shared wall is two layers, one in each room,
## and leaving the other closed blocks the passage from one direction only.
func _open_pair(walls: Dictionary, cell: Vector2i, side: String) -> void:
	var other: Vector2i = cell + NEIGHBOUR[side]
	if not walls.has(other):
		return
	walls[cell][side] = false
	for back in SIDES:
		if other + NEIGHBOUR[back] == cell:
			walls[other][back] = false


const CHARACTER_LIGHT_MASK: int = 2


func _on_node_added(node: Node) -> void:
	if not is_ancestor_of(node):
		return
	var body := node as CharacterBody2D
	if body != null and (body.collision_mask & 1) != 0:
		body.collision_mask |= SMASHED_LAYER
	if node is Light2D:
		# Runtime lamps finish their setup after add_child().
		_configure_character_light.call_deferred(node)
	if node is Sprite2D or node is AnimatedSprite2D:
		var parent := node.get_parent()
		while parent != null and parent != self:
			if parent is AnimatedCharacterClass or parent is EnemyBase or parent is Animal:
				(node as CanvasItem).light_mask = CHARACTER_LIGHT_MASK
				break
			parent = parent.get_parent()


func _configure_character_light(light: Light2D) -> void:
	if not is_instance_valid(light) or light.is_queued_for_deletion():
		return
	light.range_item_cull_mask |= CHARACTER_LIGHT_MASK
	light.shadow_item_cull_mask &= ~CHARACTER_LIGHT_MASK


## Doors into some of the carved openings, windows into some of the closed
## walls. Runs after _carve, which decides which is which, and before the light
## occluders and columns, which both read the finished wall tiles.
func _place_architecture() -> void:
	_door_skip.clear()
	var tiles: TileSet = null
	for room in _rooms.values():
		var probe := room.get_node_or_null("TileMap/Walls_SE") as TileMapLayer
		if probe != null and probe.tile_set != null:
			tiles = probe.tile_set
			break
	if tiles == null:
		return
	_add_architecture_sources(tiles)

	## Entrances first, always on the building's half of the wall, so the door
	## frame belongs to the shrine and the open ground side stays clear.
	if _ext != null:
		_ext.door_points.clear()
		for entrance in _ext.entrances:
			_ext.door_points.append(_put_door(entrance[0], entrance[1]))
	else:
		_place_safe_room_door()

	## Doors. Each shared gap is visited once, from the room on its NW/NE side,
	## and either room's half of the pair may carry the door.
	for cell in _rooms:
		for side in ["SE", "SW"]:
			var other: Vector2i = cell + NEIGHBOUR[side]
			if not _rooms.has(other):
				continue
			## Only between rooms of one building; open ground has no doors.
			if _ext != null and not _ext.same_building(cell, other):
				continue
			var host: Node = _rooms[cell]
			var guest: Node = _rooms[other]
			var host_side: String = side
			var guest_side: String = FACING_BACK[side]
			if not host.has_method("open_sides") \
					or not host_side in host.open_sides() \
					or not guest_side in guest.open_sides():
				continue
			if _rng.randf() >= door_chance:
				continue
			if _rng.randf() < 0.5:
				_put_door(other, guest_side)
			else:
				_put_door(cell, host_side)

	## Windows, only in the wall of a pair that draws in front. The one behind
	## is lower on screen in its own room but hidden here, so it loses the
	## matching stretch of stone, or there would be nothing to see through.
	for cell in _rooms:
		var room: Node = _rooms[cell]
		for side in SIDES:
			if not room.get("wall_" + side.to_lower()):
				continue
			var layer := room.get_node_or_null("TileMap/Walls_" + side) as TileMapLayer
			if layer == null:
				continue
			var partner: TileMapLayer = null
			var other: Vector2i = cell + NEIGHBOUR[side]
			if _rooms.has(other):
				if side == "SE" or side == "NE":
					continue
				partner = _rooms[other].get_node_or_null(
						"TileMap/Walls_" + FACING_BACK[side]) as TileMapLayer
				if partner != null and not partner.enabled:
					partner = null
			if _rng.randf() >= window_chance:
				continue
			var cells := _architecture_cells(layer)
			if cells.is_empty():
				continue
			var window_cell: Vector2i = cells[_rng.randi_range(0, cells.size() - 1)]
			var dir: int = layer.get_cell_source_id(window_cell)
			layer.set_cell(window_cell, WINDOW_SOURCE + dir, Vector2i.ZERO)
			if partner != null:
				_erase_nearest(partner, layer.to_global(layer.map_to_local(window_cell)))
			_add_window(layer, window_cell, dir)


## Indoor mazes normally roll doors by chance. The start room alone gets one
## unconditionally, using an opening the spanning tree already carved so it can
## never be a decorative door into a dead wall.
func _place_safe_room_door() -> void:
	var room: Node = _rooms.get(_start_cell)
	if room == null or not room.has_method("open_sides"):
		return
	var exits: Array = room.open_sides()
	exits = exits.filter(func(side): return _rooms.has(_start_cell + NEIGHBOUR[side]))
	if exits.is_empty():
		push_error("MazeDemo: generated start room has no exit")
		return
	_put_door(_start_cell, exits[_rng.randi_range(0, exits.size() - 1)])


## Hangs a door in `cell`'s wall on `side`, leaving the neighbour's half of the
## wall open behind it. Returns where the door stands, or the middle of the
## wall if it has no plain stone to take one.
func _put_door(cell: Vector2i, side: String) -> Vector2:
	var host: Node = _rooms[cell]
	var guest: Node = _rooms.get(cell + NEIGHBOUR[side])
	var layer := host.get_node_or_null("TileMap/Walls_" + side) as TileMapLayer
	if layer == null or guest == null:
		return _room_centre(cell)
	var cells := _architecture_cells(layer)
	if cells.is_empty():
		return layer.to_global(layer.map_to_local(layer.get_used_rect().get_center()))
	host.set_side(side, true)
	var door_cell: Vector2i = cells[_rng.randi_range(0, cells.size() - 1)]
	var dir: int = layer.get_cell_source_id(door_cell)
	layer.set_cell(door_cell, DOOR_SOURCE + dir, Vector2i.ZERO)
	_add_door(layer, door_cell, dir)
	_door_skip["%s/%s" % [guest.name, FACING_BACK[side]]] = true
	return layer.to_global(layer.map_to_local(door_cell))


## Middle cells of a wall that still show plain stone, so a door or window
## never lands on a corner piece or on top of another.
func _architecture_cells(layer: TileMapLayer) -> Array[Vector2i]:
	var cells: Array[Vector2i] = layer.get_used_cells()
	cells.sort_custom(func(a, b): return a.x + a.y < b.x + b.y)
	var out: Array[Vector2i] = []
	for i in range(1, cells.size() - 1):
		if layer.get_cell_source_id(cells[i]) in ARCH_DIRS:
			out.append(cells[i])
	return out


func _erase_nearest(layer: TileMapLayer, world: Vector2) -> void:
	var best := Vector2i.ZERO
	var best_distance: float = INF
	for cell in layer.get_used_cells():
		var distance: float = layer.to_global(layer.map_to_local(cell)).distance_to(world)
		if distance < best_distance:
			best_distance = distance
			best = cell
	if best_distance < INF:
		layer.erase_cell(best)


## The door frame, window and smashed window tiles, added to the rooms' shared
## TileSet once. They copy everything but their art from the plain wall they
## replace, so they line up, sort and fade exactly like it.
func _add_architecture_sources(tiles: TileSet) -> void:
	if tiles.get_physics_layers_count() < 2:
		tiles.add_physics_layer()
		tiles.set_physics_layer_collision_layer(1, SMASHED_LAYER)
		tiles.set_physics_layer_collision_mask(1, 0)
	for dir in ARCH_DIRS:
		if not tiles.has_source(dir):
			continue
		var wall := tiles.get_source(dir) as TileSetAtlasSource
		var footprint := _wall_polygon(wall)
		if footprint.is_empty():
			continue
		var half_width: float = _wall_art_size(wall).x * 0.5
		var span: Vector3 = DOORWAYS[dir]
		if not tiles.has_source(DOOR_SOURCE + dir):
			## The jambs either side of the opening; the door fills the gap.
			var jambs: Array = Geometry2D.clip_polygons(footprint,
					_doorway_band(footprint, span, half_width))
			_add_wall_source(tiles, DOOR_SOURCE + dir,
					load(ARCH_DIR + "shoji_door_frame_dir%d.png" % dir), wall, jambs, 0)
		## Plain stone until _paint_windows has this floor's wall art to work on.
		if not tiles.has_source(WINDOW_SOURCE + dir):
			_add_wall_source(tiles, WINDOW_SOURCE + dir, wall.texture, wall, [footprint], 0)
		if not tiles.has_source(SMASHED_WINDOW_SOURCE + dir):
			_add_wall_source(tiles, SMASHED_WINDOW_SOURCE + dir, wall.texture, wall,
					[footprint], 1)


func _add_wall_source(tiles: TileSet, id: int, texture: Texture2D,
		like: TileSetAtlasSource, polygons: Array, physics_layer: int) -> void:
	var source := TileSetAtlasSource.new()
	source.texture = texture
	source.texture_region_size = like.texture_region_size
	tiles.add_source(source, id)
	source.create_tile(Vector2i.ZERO, like.get_tile_size_in_atlas(Vector2i.ZERO))
	var data := source.get_tile_data(Vector2i.ZERO, 0)
	var ref := like.get_tile_data(Vector2i.ZERO, 0)
	data.texture_origin = ref.texture_origin
	data.y_sort_origin = ref.y_sort_origin
	data.z_index = ref.z_index
	for polygon in polygons:
		if (polygon as PackedVector2Array).size() < 3:
			continue
		var index: int = data.get_collision_polygons_count(physics_layer)
		data.add_collision_polygon(physics_layer)
		data.set_collision_polygon_points(physics_layer, index, polygon)


func _wall_polygon(wall: TileSetAtlasSource) -> PackedVector2Array:
	var data := wall.get_tile_data(Vector2i.ZERO, 0)
	if data == null or data.get_collision_polygons_count(0) == 0:
		return PackedVector2Array()
	return data.get_collision_polygon_points(0, 0)


func _wall_art_size(wall: TileSetAtlasSource) -> Vector2:
	return Vector2(wall.texture_region_size * wall.get_tile_size_in_atlas(Vector2i.ZERO))


## The doorway's passage through a wall footprint: the strip between the two
## jambs, straight down the screen. The footprint is a slanted slab about 100px
## deep and overlaps the next cell along by 24px either side, so a cut along
## the other isometric axis would shear the opening into the neighbouring
## stone. A straight strip stays clear of it, and anyone walking diagonally
## into a jamb slides along it and through.
func _doorway_band(_footprint: PackedVector2Array, span: Vector3,
		half_width: float) -> PackedVector2Array:
	var left: float = span.x - half_width
	var right: float = span.y - half_width
	return PackedVector2Array([Vector2(left, -10000.0), Vector2(right, -10000.0),
			Vector2(right, 10000.0), Vector2(left, 10000.0)])


## The sliding panels for a door frame tile. They hang off the tile's own sort
## line, so they sort against characters exactly as the frame around them does.
func _add_door(layer: TileMapLayer, cell: Vector2i, dir: int) -> void:
	var wall := layer.tile_set.get_source(dir) as TileSetAtlasSource
	var ref := wall.get_tile_data(Vector2i.ZERO, 0)
	var sort := Vector2(0.0, float(ref.y_sort_origin))
	var half_width: float = _wall_art_size(wall).x * 0.5
	var span: Vector3 = DOORWAYS[dir]
	var opening := Geometry2D.intersect_polygons(_wall_polygon(wall),
			_doorway_band(_wall_polygon(wall), span, half_width))
	if opening.is_empty():
		return
	var doorway := PackedVector2Array()
	for p in opening[0]:
		doorway.append(p - sort)
	var door := SlidingDoor.new()
	door.name = "Door_%d_%d" % [cell.x, cell.y]
	door.panel_texture = load(ARCH_DIR + "shoji_door_panel_dir%d.png" % dir)
	door.broken_texture = load(ARCH_DIR + "shoji_door_broken_dir%d.png" % dir)
	door.split_x = (span.x + span.y) * 0.5
	door.half_width = (span.y - span.x) * 0.5
	door.slope = span.z
	## A tile's art is centred on its cell minus texture_origin.
	door.sprite_offset = -Vector2(ref.texture_origin) - sort
	door.doorway = doorway
	layer.add_child(door)
	door.position = layer.map_to_local(cell) + sort


## Something for a blade to hit. The glass itself is the tile.
func _add_window(layer: TileMapLayer, cell: Vector2i, dir: int) -> void:
	var wall := layer.tile_set.get_source(dir) as TileSetAtlasSource
	var pane := WindowPane.new()
	pane.name = "Window_%d_%d" % [cell.x, cell.y]
	pane.layer = layer
	pane.cell = cell
	pane.broken_source = SMASHED_WINDOW_SOURCE + dir
	var shape := CollisionPolygon2D.new()
	shape.polygon = _wall_polygon(wall)
	pane.add_child(shape)
	layer.add_child(pane)
	pane.position = layer.map_to_local(cell)


## Paints the window art over this floor's own wall texture, intact and
## smashed, so a window always sits in matching stone whatever the theme.
func _paint_windows() -> void:
	if OS.has_feature("dedicated_server"):
		return
	var tiles: TileSet = null
	for room in _rooms.values():
		var probe := room.get_node_or_null("TileMap/Walls_SE") as TileMapLayer
		if probe != null and probe.tile_set != null:
			tiles = probe.tile_set
			break
	if tiles == null:
		return
	for dir in ARCH_DIRS:
		if not tiles.has_source(dir) or not tiles.has_source(WINDOW_SOURCE + dir):
			continue
		var wall_image := (tiles.get_source(dir) as TileSetAtlasSource).texture.get_image()
		if wall_image == null:
			continue
		if wall_image.is_compressed():
			wall_image.decompress()
		wall_image.convert(Image.FORMAT_RGBA8)
		for pair in [[WINDOW_SOURCE, "window"], [SMASHED_WINDOW_SOURCE, "window_broken"]]:
			var overlay := (load(ARCH_DIR + "%s_dir%d.png" % [pair[1], dir]) as Texture2D).get_image()
			if overlay.is_compressed():
				overlay.decompress()
			overlay.convert(Image.FORMAT_RGBA8)
			var image := wall_image.duplicate() as Image
			image.blend_rect(overlay, Rect2i(Vector2i.ZERO, overlay.get_size()), Vector2i.ZERO)
			(tiles.get_source(pair[0] + dir) as TileSetAtlasSource).texture = \
					ImageTexture.create_from_image(image)


## Chairs to rest at: one beside the spawn, and a few more out on open floor so
## resting is something you can plan a route around rather than stumble onto.
## They go at room centres, which is the one spot guaranteed clear of the walls.
func _place_starting_chair() -> void:
	if chair_scene == null or _player == null:
		return
	## Beside the spawn, off to one side so she does not begin standing on it.
	var safe_chair := _add_chair(_player.global_position + Vector2(150.0, 75.0), "StartingChair")
	if safe_chair != null:
		safe_chair.set_meta("safe_room_chair", true)

	## And in a scattering of other rooms, skipping the one she starts in.
	var start := _start_cell
	var elsewhere: Array[Vector2i] = []
	for cell in _rooms:
		## Not in a pond, whose middle is water.
		if cell != start and not (_ext != null and _ext.is_pond(cell)):
			elsewhere.append(cell)
	elsewhere.shuffle()
	for i in mini(extra_chairs, elsewhere.size()):
		_add_chair(_room_centre(elsewhere[i]), "Chair_%d_%d" % [elsewhere[i].x, elsewhere[i].y])


## The four floor axes as screen vectors, and the facing that looks back along
## each. Built from the lattice step: +ix lands at (+24,+12) on screen, which is
## southEast, so a chair standing there faces northWest to see the table.
const SEATS := [
	{"offset": Vector2( 1.0,  0.5), "faces": "northWest"},
	{"offset": Vector2(-1.0,  0.5), "faces": "northEast"},
	{"offset": Vector2(-1.0, -0.5), "faces": "southEast"},
	{"offset": Vector2( 1.0, -0.5), "faces": "southWest"},
]


## A line of floor spikes stepping through the cycle.
##
## Never in the starting room: the first thing a new player meets should not be
## something that damages them before they have moved.
func _place_trap_run(room: Node2D) -> void:
	var ground := room.get_node_or_null("TileMap/Ground") as TileMapLayer
	if ground == null:
		return
	var cells := ground.get_used_cells()
	if cells.is_empty():
		return
	var floor_cells := {}
	for cell in cells:
		floor_cells[cell] = true

	## Along one of the two tile axes, so the run reads as a deliberate line in
	## the architecture rather than a diagonal scatter.
	var axis: Vector2i = [Vector2i(1, 0), Vector2i(0, 1)][_rng.randi() % 2]
	var wanted: int = _rng.randi_range(traps_per_run.x, traps_per_run.y)

	## A start cell with enough floor ahead of it to hold the whole run.
	var from: Vector2i = Vector2i.ZERO
	var found := false
	for _try in 20:
		var candidate: Vector2i = cells[_rng.randi_range(0, cells.size() - 1)]
		var fits := true
		for i in wanted:
			if not floor_cells.has(candidate + axis * i):
				fits = false
				break
		if fits:
			from = candidate
			found = true
			break
	if not found:
		return

	for i in wanted:
		var trap = trap_scene.instantiate()
		add_child(trap)
		(trap as Node2D).global_position = ground.to_global(
				ground.map_to_local(from + axis * i))
		## Spread evenly around the cycle so the run ripples instead of firing
		## as one slab, which would be a wall rather than a rhythm.
		if "phase_offset" in trap:
			trap.phase_offset = trap.period * float(i) / float(wanted)


## A table with two or three chairs turned in towards it.
func _place_dining_set(room: Node2D) -> void:
	var ground := room.get_node_or_null("TileMap/Ground") as TileMapLayer
	if ground == null:
		return
	var cells := ground.get_used_cells()
	if cells.is_empty():
		return
	## Placed where its own seats will actually fit, rather than merely on open
	## floor. The table is wide enough that its chairs sit three or four tiles
	## out, so a generic "two clear rings" test said yes in places where half the
	## seats still landed in stone — tables were coming out with one chair.
	## Scoring candidates by how many of their four seats are over floor asks the
	## question that matters directly. Checked against the tilemap, not physics,
	## because this runs during _ready where the physics server is still empty.
	var floor_cells := {}
	for cell in cells:
		floor_cells[cell] = true

	var pick: Vector2i = cells[_rng.randi_range(0, cells.size() - 1)]
	var best: int = -1
	## A sample rather than every tile: rooms have hundreds of cells and four
	## seat tests each would be thousands of lookups per table.
	for _try in 24:
		var candidate: Vector2i = cells[_rng.randi_range(0, cells.size() - 1)]
		var origin: Vector2 = ground.map_to_local(candidate)
		if not _party_clear(ground.to_global(origin), 140.0):
			continue
		var fits: int = 0
		for seat in SEATS:
			var at: Vector2 = origin + seat["offset"] * table_seat_gap
			if floor_cells.has(ground.local_to_map(at)):
				fits += 1
		if fits > best:
			best = fits
			pick = candidate
		if fits == SEATS.size():
			break
	if best < 0:
		return
	var centre: Vector2 = ground.to_global(ground.map_to_local(pick))

	## The facing is picked by scene rather than by swapping the sprite, since
	## each facing has its own footprint.
	var table := WorldObjects.choose(table_scenes[0], _rng,
			_rng.randi_range(0, 3) * 2 + 1).instantiate()
	table.name = "DiningTable"
	add_child(table)
	(table as Node2D).global_position = centre

	if chair_scene == null:
		return
	## A random subset of the four sides, so no two sets look alike and the
	## table is never boxed in on every side.
	var sides: Array = SEATS.duplicate()
	for i in range(sides.size() - 1, 0, -1):
		var j: int = _rng.randi_range(0, i)
		var swap = sides[i]
		sides[i] = sides[j]
		sides[j] = swap
	for i in _rng.randi_range(2, 3):
		var seat: Dictionary = sides[i]
		var where: Vector2 = centre + seat["offset"] * table_seat_gap
		## Belt and braces: the table was chosen for seats that fit, but if the
		## room could not offer a perfect spot one or two may still be in stone.
		if not floor_cells.has(ground.local_to_map(ground.to_local(where))):
			continue
		var chair := chair_scene.instantiate()
		chair.name = "DiningChair%d" % i
		if "facing" in chair:
			chair.facing = seat["faces"]
		## Its own table is the one thing it is *supposed* to be pressed up
		## against. The clearance cull would otherwise throw away every chair it
		## just seated: the chairs stand 96px out and the probe reaches 70, which
		## bites into a table half as wide again as that gap.
		chair.set_meta("dining_table", table)
		add_child(chair)
		(chair as Node2D).global_position = where


func _add_chair(where: Vector2, named: String) -> Node:
	var chair := WorldObjects.choose(chair_scene, _rng).instantiate()
	chair.name = named
	## Turned before it is added, so the setter has run by the time _ready picks
	## the art. Without this every chair on the floor faces the same way, which
	## reads as a waiting room rather than a ruin.
	if chair.has_method("face_randomly"):
		chair.face_randomly(_rng)
	add_child(chair)
	(chair as Node2D).global_position = where
	return chair


## Throws away any chair standing inside something solid.
##
## The prop pool drops chairs on any floor cell, including ones a column is
## already standing on. A buried chair still counts as somewhere to rest, so she
## would walk into a column and sit on a chair nobody can see — which is exactly
## what a chair under a column looked like.
func _clear_buried_chairs() -> void:
	## One physics frame late, and that is the whole reason this works. Walls,
	## columns and props are all added during _ready, and the physics server does
	## not know about a body's shapes until the next step — so querying here
	## immediately returned "nothing is there" for every chair, whatever it was
	## standing on.
	await get_tree().physics_frame
	var space := get_world_2d().direct_space_state
	var removed := 0
	for chair in get_tree().get_nodes_in_group("chair"):
		if not (chair is Node2D):
			continue
		## This is the floor's guaranteed heal point. Random furniture is culled
		## when buried; the safe-room chair is an invariant and its room is kept
		## free of random props above.
		if chair.has_meta("safe_room_chair"):
			continue
		## A shape rather than a point. Testing the exact centre only caught a
		## chair standing *inside* something; one tucked against a column passed,
		## and she would walk into the stone trying to reach it.
		var probe := PhysicsShapeQueryParameters2D.new()
		var clearance := CircleShape2D.new()
		clearance.radius = chair_clearance
		probe.shape = clearance
		probe.transform = Transform2D(0.0, (chair as Node2D).global_position)
		## Layer 2 only: props and columns, not walls. Props sit on layer 3, which
		## is bits 1 and 2; the walls are bit 1 alone. Probing bit 1 therefore hit
		## the walls too, and the wall collision is a deliberately oversized
		## silhouette, so chairs were being rejected from well across the room
		## from any stone — seventeen a floor. She can stand beside a wall
		## perfectly well; what she cannot do is stand inside a column.
		probe.collision_mask = 2
		## Everything except the table it was deliberately drawn up to. It is
		## still tested against walls, columns and every other prop.
		##
		## has_meta rather than a default, because passing null as the default
		## does not work: get_meta falls back only when the default differs from
		## nil, so an explicit null is indistinguishable from supplying none and
		## it takes the error path instead. Chairs from the prop pool have no
		## table and hit this every time one is placed.
		var table: Variant = chair.get_meta("dining_table") if chair.has_meta("dining_table") else null
		if is_instance_valid(table) and table is CollisionObject2D:
			probe.exclude = [table.get_rid()]
		if not space.intersect_shape(probe, 1).is_empty():
			chair.queue_free()
			removed += 1
	if removed > 0:
		print_verbose("MazeDemo: removed %d chair(s) without clear floor around them" % removed)


## The world position of the middle of a room's floor.
func _room_centre(cell: Vector2i) -> Vector2:
	var room := _rooms.get(cell) as Node2D
	if room == null:
		return Vector2.ZERO
	var ground := room.get_node_or_null("TileMap/Ground") as TileMapLayer
	if ground == null:
		return room.global_position
	var used := ground.get_used_rect()
	return ground.to_global(ground.map_to_local(used.position + used.size / 2))


func _spawn_player(step: Vector2) -> void:
	if player_scene == null:
		return
	var wanted: int = maxi(Roster.count(), 1)
	var centre: Vector2 = _room_centre(_start_cell)

	## Spawned once and carried down; later floors only move them. Which
	## heroine depends on the cheat: Karmageisha swaps every slot, human or
	## bot, for the old Katana Kitsune.
	var scene: PackedScene = player_scene
	if CheatManager.karmageisha_active:
		scene = load(CheatManager.player_scene_path())
	while _players.size() < wanted:
		var body = scene.instantiate()
		## Set before add_child so _ready picks the right device and colour —
		## afterwards would be too late, the character would already have bound
		## itself to the keyboard and repainted in somebody else's aspect.
		body.slot = _players.size()
		add_child(body)
		_players.append(body)
		## A god carries every scroll from the start, and never spends one.
		if "scrolls" in body:
			CheatManager.stock_scrolls(body.scrolls)
		## Only when there is a party to tell apart. One player needs no label
		## saying which one they are.
		if wanted > 1:
			var mark := Node2D.new()
			mark.name = "SlotMarker"
			mark.set_script(load("res://scripts/system/SlotMarker.gd"))
			body.add_child(mark)
			mark.setup(body.slot, Roster.colour_of(body.slot))
	## Kept for everything that still wants "the player" — the HUD, the radar
	## and the eye all speak for player one.
	_player = _players[0] if not _players.is_empty() else null

	for i in _players.size():
		if not is_instance_valid(_players[i]):
			continue
		## Fanned out around the middle of the room rather than stacked on one
		## point, or four bodies would spawn inside each other and shove apart.
		var angle: float = TAU * float(i) / float(maxi(_players.size(), 1))
		var ring := Vector2(cos(angle), sin(angle) * 0.5) * (0.0 if _players.size() == 1 else 90.0)
		(_players[i] as Node2D).global_position = centre + ring
		_players[i].input.reset()

	_theme_floor()
	Roster.update_party_control(_players)
	_pass_through_each_other()
	_fit_camera()
	if not Roster.device_lost.is_connected(_on_device_lost):
		Roster.device_lost.connect(_on_device_lost)
		Roster.device_regained.connect(_on_device_regained)


func bot_controls_active() -> bool:
	return not _building and not _clearing and not SceneLoader.is_active() \
			and not get_tree().paused


## Navigation uses the real floor extent, not a radius around the bot. Walls,
## doors, columns and props are still tested with the bot's collision shape.
func bot_navigation_bounds() -> Rect2:
	if _bot_floors.is_empty():
		for room in _rooms.values():
			var ground := room.get_node_or_null("TileMap/Ground") as TileMapLayer
			if ground == null or ground.tile_set == null:
				continue
			var used := ground.get_used_rect()
			var bounds := Rect2(ground.to_global(ground.map_to_local(used.position)), Vector2.ZERO)
			for corner in [used.position, Vector2i(used.end.x, used.position.y),
					Vector2i(used.position.x, used.end.y), used.end]:
				bounds = bounds.expand(ground.to_global(ground.map_to_local(corner)))
			_bot_floors.append(ground)
			_bot_floor_bounds.append(bounds.grow(float(ground.tile_set.tile_size.x)))
	var result := Rect2()
	for i in _bot_floor_bounds.size():
		result = _bot_floor_bounds[i] if i == 0 else result.merge(_bot_floor_bounds[i])
	return result


func bot_navigation_contains(point: Vector2) -> bool:
	if _bot_floors.is_empty():
		bot_navigation_bounds()
	for i in _bot_floors.size():
		if not _bot_floor_bounds[i].has_point(point):
			continue
		var ground := _bot_floors[i]
		if ground.get_cell_source_id(ground.local_to_map(ground.to_local(point))) != -1:
			return true
	return false


func _physics_process(delta: float) -> void:
	_enforce_safe_room()
	if bot_controls_active():
		refresh_party_control()
	if not get_tree().paused and not SceneLoader.is_active() \
			and not _building and not _clearing and is_instance_valid(_player):
		day_night.advance(delta)
		_update_daylight()
	_track_party(delta)
	_check_wave_cleared()
	_update_adaptive_music(delta)
	if _ext != null and not _building:
		_ext.update_roofs(delta, Roster.bodies(get_tree()))
		if is_instance_valid(_weather):
			var views: Array[Rect2] = []
			var camera := get_viewport().get_camera_2d()
			if camera != null:
				var size: Vector2 = get_viewport_rect().size / camera.zoom
				views.append(Rect2(camera.get_screen_center_position() - size * 0.5, size))
			_weather.update_weather(delta, views)


## True for the authored floor diamond of the start room. EnemyBase uses this
## to ignore protected players, and the server/solo authority below rejects any
## hostile body that reaches across the doorway because of knockback or a
## phasing movement trait.
func safe_room_contains(world: Vector2) -> bool:
	var room := _rooms.get(_start_cell) as Node2D
	if room == null:
		return false
	var ground := room.get_node_or_null("TileMap/Ground") as TileMapLayer
	return ground != null and ground.get_cell_source_id(
			ground.local_to_map(ground.to_local(world))) != -1


func _enforce_safe_room() -> void:
	if _building or _clearing or NetworkManager.is_client:
		return
	for enemy in get_tree().get_nodes_in_group("enemy"):
		if not (enemy is Node2D) or enemy.get("is_dead") == true:
			continue
		if safe_room_contains(enemy.global_position):
			var fallback: Variant = enemy.get_meta("safe_room_last_outside", null)
			if fallback is Vector2:
				enemy.global_position = fallback
			if enemy is CharacterBody2D:
				(enemy as CharacterBody2D).velocity = Vector2.ZERO
		else:
			enemy.set_meta("safe_room_last_outside", enemy.global_position)


func _update_adaptive_music(delta: float) -> void:
	if not _wave_live or _clearing or _building:
		return
	var danger := _party_is_hunted()
	if danger:
		_music_safe_time = 0.0
		_set_adaptive_music(true)
	elif _music_danger:
		_music_safe_time += delta
		if _music_safe_time >= MUSIC_DANGER_RELEASE:
			_set_adaptive_music(false)


func _party_is_hunted() -> bool:
	for node in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(node) or node.get("is_dead") == true:
			continue
		var machine = node.get("state_machine")
		if is_instance_valid(machine):
			var current = machine.get("current_state")
			if is_instance_valid(current) and String(current.name).to_lower() not in ["idle", "hurt", "death"]:
				return true
		var sprite := node.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
		if sprite == null:
			continue
		var animation := String(sprite.animation).to_lower()
		for marker in ["run", "alert", "attack", "charge", "cast", "shoot", "lunge", "stomp", "crit", "heavy"]:
			if animation.contains(marker):
				return true
	return false


func _set_adaptive_music(danger: bool) -> void:
	var event := music_event_for_theme(
			_level_theme.id if _level_theme != null else LevelTheme.Id.SAKURA_GARDENS,
			danger)
	if event == _music_event:
		return
	_music_event = event
	_music_danger = danger
	_music_safe_time = 0.0
	AudioManager.play_music(event, -7.0 if danger else -8.0)


static func music_event_for_theme(theme_id: int, danger: bool) -> String:
	var theme := LevelTheme.music_key(theme_id)
	return "music_%s_%s" % [theme, "danger" if danger else "calm"]


## Brings the party up with the monsters, on the same curve and the same cap.
## Without this the scaling is only ever a difficulty increase, and a long run
## turns into chipping at sponges.
func _scale_party() -> void:
	var deep: float = minf(1.0 + float(depth - 1) * 0.05, 2.0)
	for body in _players:
		if not is_instance_valid(body):
			continue
		var id: int = body.get_instance_id()
		if not _party_base.has(id):
			_party_base[id] = {"health": body.max_health, "damage": body.damage}
		var base: Dictionary = _party_base[id]
		var was: float = body.max_health
		var trained: float = Progression.health_factor(int(body.get("slot"))) \
				if "slot" in body else 1.0
		body.max_health = base["health"] * deep * trained
		## Healed by the increase rather than to full: surviving a wave should
		## still cost something going into the next.
		body.health = minf(body.health + (body.max_health - was), body.max_health)
		body.damage = base["damage"] * deep
		if body.has_method("apply_progression"):
			body.apply_progression()


## Clearing the enemy wave still controls progression; stairs never bypass it.
func _check_wave_cleared() -> void:
	if _clearing or not _wave_live:
		return
	## Clients only mirror what the server tells them; the server calls the floor.
	if NetworkManager.is_client:
		return
	for node in get_tree().get_nodes_in_group("enemy"):
		if is_instance_valid(node) and not (node.get("is_dead") == true):
			return
	_clearing = true
	_finish_wave()


func _finish_wave() -> void:
	AudioManager.play("sfx_wave_clear")
	AudioManager.play_music("music_wave_victory", -3.0)
	Score.wave_cleared(depth, Time.get_ticks_msec() * 0.001 - _wave_started)
	_show_clear_stairs()
	_announce_floor("AREA CLEAR")
	await get_tree().create_timer(2.1, false).timeout
	if not is_inside_tree():
		return
	var party: int = maxi(Roster.count(), 1)
	## Online, the upgrade screen would pause a server nobody can click on;
	## levels are applied without the pick for now.
	if Progression.levelled_this_floor(party) and not NetworkManager.is_networked():
		await _offer_upgrades(party)
	if is_inside_tree():
		descend()


func _show_clear_stairs() -> Exit:
	AudioManager.play("sfx_exit_reveal")
	var stairs := WorldObjects.scene("exit_stairs", 1).instantiate() as Exit
	stairs.name = "ClearedFloorStairs"
	# Visual cue only: retain automatic area-clear descent and the upgrade screen.
	stairs.monitoring = false
	add_child(stairs)
	stairs.global_position = _player.global_position + Vector2(100, 50) \
			if is_instance_valid(_player) else _room_centre(_start_cell)
	return stairs


## Between floors, while the clock is already frozen by _clearing.
func _offer_upgrades(party: int) -> void:
	_upgrading = true
	get_tree().paused = true
	var screen := LevelUpScreen.new()
	screen.party = party
	add_child(screen)
	await screen.finished
	screen.queue_free()
	_upgrading = false
	if Roster.any_lost():
		_paused_for_reconnect = true
	else:
		get_tree().paused = false


## Halts the floor while anyone's pad is unplugged, and says whose.
##
## The slot is held rather than freed: a cable pulled out by a foot should not
## cost that player their run. Any spare pad plugged in adopts the waiting slot,
## so a replacement controller rescues them without a trip to a menu.
func _on_device_lost(slot: int) -> void:
	## An online player who drops is removed by NetworkManager, not waited for.
	if Roster.is_network(slot):
		return
	if not get_tree().paused:
		_paused_for_reconnect = true
	get_tree().paused = true
	_show_reconnect("PLAYER %d — RECONNECT CONTROLLER" % (slot + 1))


## The server went away, or called the match. If everyone is already dead the
## game-over screen is up and handles its own exit; otherwise say why and go
## back to the title.
func _on_online_ended(reason: String) -> void:
	var game_over := get_node_or_null("GameOver")
	if game_over != null and game_over.get("_begin_started") == true:
		NetworkManager.stop()
		return
	NetworkManager.stop()
	get_tree().paused = true
	_show_reconnect("CONNECTION LOST" if reason == "server_lost" else "MATCH OVER")
	await get_tree().create_timer(2.5, true).timeout
	if not is_inside_tree():
		return
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/title_screen.tscn")


func _on_device_regained(_slot: int) -> void:
	if Roster.any_lost():
		return
	## The upgrade screen owns its pause; it unpauses once every player is ready.
	if _paused_for_reconnect and not _upgrading:
		get_tree().paused = false
	_paused_for_reconnect = false
	_show_reconnect("")


func _show_reconnect(text: String) -> void:
	var layer := get_node_or_null("ReconnectLayer") as CanvasLayer
	if layer == null:
		layer = CanvasLayer.new()
		layer.name = "ReconnectLayer"
		## Runs while the tree is paused, or the notice could never appear —
		## the thing it announces is the reason everything else stopped.
		layer.process_mode = Node.PROCESS_MODE_ALWAYS
		layer.layer = 90
		add_child(layer)
		var note := Label.new()
		note.name = "Note"
		note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		note.set_anchors_preset(Control.PRESET_FULL_RECT)
		note.add_theme_font_size_override("font_size", 28)
		note.add_theme_color_override("font_color", Color(1.0, 0.85, 0.45))
		layer.add_child(note)
	var note := layer.get_node_or_null("Note") as Label
	if note != null:
		note.text = text
		note.visible = text != ""


## Same-control pairs pass through; human/bot contact stays solid.
##
## Collision exceptions rather than layers: players sit on layer 1 alongside the
## walls, and everything that has to notice a player — pickups, spike traps,
## chair zones — masks that layer. Moving them off it to separate them from each
## other would quietly break all of those. An exception is per-pair and touches
## nothing else.
##
## All teammates pass through each other, regardless of who controls them.
func _pass_through_each_other() -> void:
	for a in _players:
		if not is_instance_valid(a):
			continue
		for b in _players:
			if b != a and is_instance_valid(b):
				(a as CharacterBody2D).add_collision_exception_with(b)


## One camera for the table, framing every living player.
##
## Shared rather than split: the HUD, radar, gloom and every lantern are single
## CanvasLayer things, and four viewports would mean four of each. The cost is
## that players cannot wander into separate rooms — the camera pulls back as
## they spread and stops them drifting off the edge of the world.
func _fit_camera() -> void:
	var cam := get_node_or_null("PartyCamera") as Camera2D
	if cam == null:
		cam = Camera2D.new()
		cam.name = "PartyCamera"
		add_child(cam)
		cam.position_smoothing_enabled = true
		cam.position_smoothing_speed = 6.0
		cam.make_current()
	## Any camera the player scene ships with would fight this one for the view.
	for body in _players:
		if is_instance_valid(body):
			var own := (body as Node).get_node_or_null("FollowCamera") as Camera2D
			if own != null:
				own.enabled = false


## Keeps the shared camera on the middle of the party and pulled back far enough
## to hold everyone. Runs in physics because that is when bodies move; sampling
## in _process reads a stale position on frames with no physics tick and the
## view jitters.
func _track_party(_delta: float) -> void:
	var cam := get_node_or_null("PartyCamera") as Camera2D
	if cam == null:
		return
	var alive: Array[Node2D] = []
	for body in _players:
		if is_instance_valid(body) and not (body.get("is_dead") == true):
			alive.append(body)
	if alive.is_empty():
		return

	var box := Rect2(alive[0].global_position, Vector2.ZERO)
	for body in alive:
		box = box.expand(body.global_position)
	cam.global_position = box.get_center()

	## Zoom out only once the party is wider than the view, and never past the
	## limit — a dungeon read at half size stops being readable.
	var view: Vector2 = get_viewport_rect().size
	var needed: Vector2 = (box.size + Vector2(party_margin, party_margin)) / view
	var out: float = maxf(maxf(needed.x, needed.y), 1.0)
	var target: float = clampf(1.0 / out, camera_zoom_min, 1.0)
	cam.zoom = cam.zoom.lerp(Vector2(target, target), clampf(_delta * 4.0, 0.0, 1.0))


## One whole room along each isometric axis, in pixels.
## Stands a pillar at each end of every opening, and spaces more across it.
##
## Knocking a wall out leaves the runs either side of it stopping in mid-air,
## showing their cut faces. Framing the gap with columns reads as architecture
## that was always meant to have an opening there, rather than a wall someone
## removed — and it costs a prop instead of a new tile set and door logic.
##
## The opening's own wall layer is disabled but still holds its tiles, so it
## describes exactly where the gap is; no geometry has to be inferred.
## Closest two columns may stand. Each footprint is 44 across and she is 66, so
## this leaves at least 106 of clear floor to walk through.
const MIN_GAP: float = 150.0
## How far a character's node origin sits above their feet. Props have to match
## it or the two sort against each other by different rules.
const SORT_LIFT: float = 100.0


## Where a wall tile's stone actually stands, relative to the cell it occupies.
##
## These tiles span five cells by sixteen and carry a texture origin, so the
## cell position lands near the top of the sprite rather than at its base —
## columns placed there stood about 56px off the wall line. The collision
## polygon is the honest footprint, and its centre differs per side because the
## walls lean, so this is read from the tile rather than typed in as a constant.
func _wall_footprint(layer: TileMapLayer, cell: Vector2i) -> Vector2:
	var ts: TileSet = layer.tile_set
	if ts == null:
		return Vector2.ZERO
	var src := ts.get_source(layer.get_cell_source_id(cell)) as TileSetAtlasSource
	if src == null:
		return Vector2.ZERO
	var data: TileData = src.get_tile_data(layer.get_cell_atlas_coords(cell),
			layer.get_cell_alternative_tile(cell))
	if data == null or data.get_collision_polygons_count(0) == 0:
		return Vector2.ZERO
	var points: PackedVector2Array = data.get_collision_polygon_points(0, 0)
	if points.is_empty():
		return Vector2.ZERO
	var sum := Vector2.ZERO
	for p in points:
		sum += p
	return sum / float(points.size())


func _place_pillars() -> void:
	if pillar_scene == null:
		return
	## Both rooms either side of an opening describe the same gap, so each would
	## otherwise stand its own column there. Spacing is enforced by distance and
	## not by snapping to a grid: a grid still lets two columns land a few pixels
	## apart, and anything tighter than MIN_GAP is a doorway she cannot fit
	## through — her collision diamond is 66 across and a column's is 44.
	var placed: Array[Vector2] = []
	for cell in _rooms:
		var room: Node2D = _rooms[cell]
		if not room.has_method("open_sides"):
			continue
		## Open ground has no ceiling for a column to hold up.
		if _ext != null and not _ext.is_building(cell):
			continue
		for side in room.open_sides():
			if _door_skip.has("%s/%s" % [room.name, side]):
				continue
			var layer := room.get_node_or_null("TileMap/Walls_" + side) as TileMapLayer
			if layer == null:
				continue
			var cells: Array[Vector2i] = layer.get_used_cells()
			if cells.is_empty():
				continue
			## Along the gap, so "first" and "last" are its two ends.
			cells.sort_custom(func(a, b): return a.x + a.y < b.x + b.y)
			var wanted: Array[int] = [0, cells.size() - 1]
			var stride: int = maxi(int(cells.size() / float(pillars_per_opening + 1)), 1)
			for i in range(stride, cells.size() - 1, stride):
				wanted.append(i)
			for i in wanted:
				var world: Vector2 = layer.to_global(layer.map_to_local(cells[i])
						+ _wall_footprint(layer, cells[i]) * pillar_wall_bias)
				var crowded := false
				for other in placed:
					if other.distance_to(world) < MIN_GAP:
						crowded = true
						break
				if crowded:
					continue
				placed.append(world)
				var pillar := WorldObjects.choose(pillar_scene, _rng).instantiate()
				pillar.name = "Pillar_%d_%d_%s_%d" % [cell.x, cell.y, side, i]
				## Its own occlusion check, so a player walking up the screen
				## behind a column does not simply vanish.
				var fade := Node.new()
				fade.name = "Fade"
				fade.set_script(load("res://scripts/system/PillarFade.gd"))
				pillar.add_child(fade)
				add_child(pillar)
				(pillar as Node2D).global_position = world


## Where a grid cell sits on screen.
##
## The isometric lattice, not a grid of half-steps. A room's footprint is a
## diamond, and diamonds only interlock when each neighbour sits half a width
## across AND half a height down — moving in one axis alone slides a room
## halfway over its neighbour, which is what used to happen here.
##
## In tile terms this is exactly one room per step: +ix advances the room's own
## cell block by its width, +iy by its height, so floors abut with no seam and
## no shared cells. That also derives NEIGHBOUR rather than leaving it read off
## a render — +ix goes right and down (SE), +iy goes left and down (SW), and
## their negatives are NW and NE.
func _lattice_position(cell: Vector2i, step: Vector2) -> Vector2:
	return Vector2(
		float(cell.x - cell.y) * step.x * 0.5,
		float(cell.x + cell.y) * step.y * 0.5)


func _lattice_step() -> Vector2:
	var probe = room_scene.instantiate()
	var ground := probe.get_node_or_null("TileMap/Ground") as TileMapLayer
	var step := Vector2.ZERO
	if ground != null:
		var umin := 1 << 30
		var umax := -(1 << 30)
		var vmin := 1 << 30
		var vmax := -(1 << 30)
		for c in ground.get_used_cells():
			umin = mini(umin, c.x - c.y)
			umax = maxi(umax, c.x - c.y)
			vmin = mini(vmin, c.x + c.y)
			vmax = maxi(vmax, c.x + c.y)
		## The diamond's full screen width and height: the span between the
		## outermost tile centres, plus the one whole tile hanging off each end.
		## This used to add a single tile rather than two, so every room was
		## measured one tile short and the lattice pulled itself inwards.
		step = Vector2(
			float(umax - umin + 2) * ground.tile_set.tile_size.x * 0.5,
			float(vmax - vmin + 2) * ground.tile_set.tile_size.y * 0.5)
	probe.free()
	return step
