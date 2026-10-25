class_name MazeExterior
extends RefCounted

## The outdoor half of a floor. Turns MazeDemo's lattice of rooms into a shrine
## compound: a few separate buildings, each a cluster of rooms with walls and a
## roof, standing in open ground — an abandoned road running edge to edge,
## gardens, gravel courtyards and ponds — so the player walks in and out of the
## shrines rather than wandering one enormous interior.
##
## Every lattice cell is still a room prefab. An outdoor cell is just a room
## with its walls knocked out, its stone floor swapped for exterior tiles and
## its roof thrown away, so sorting, lighting and spawning keep working the way
## they always have. MazeDemo calls in at fixed points of _build; nothing here
## runs on its own.

enum Kind { BUILDING, ROAD, GARDEN, COURTYARD, POND }

## Mirrors MazeDemo's own lattice tables.
const SIDES: Array[String] = ["NE", "NW", "SE", "SW"]
const NEIGHBOUR := {
	"NE": Vector2i(0, -1),
	"SW": Vector2i(0, 1),
	"SE": Vector2i(1, 0),
	"NW": Vector2i(-1, 0),
}
const FACING_BACK := {"SE": "NW", "NW": "SE", "SW": "NE", "NE": "SW"}

const PROP_DIR := WorldObjects.SCENE_DIR
const WATER_SHADER := "res://shaders/water.gdshader"
## Each side of a cell's diamond as its two corners, in units of the half-size.
const SIDE_ENDS := {
	"NE": [Vector2(0, -1), Vector2(1, 0)],
	"SE": [Vector2(1, 0), Vector2(0, 1)],
	"SW": [Vector2(0, 1), Vector2(-1, 0)],
	"NW": [Vector2(-1, 0), Vector2(0, -1)],
}
## Cells that stand behind a building cell on screen — NW, NE and straight up.
## A player there is hidden by its roof, so the roof thins out for them.
const BEHIND: Array[Vector2i] = [Vector2i(-1, 0), Vector2i(0, -1), Vector2i(-1, -1)]
const ROOF_BEHIND_ALPHA: float = 0.35
const ROOF_FADE_SPEED: float = 4.0
## Half-width of the paved strip, in screen pixels along the road.
const ROAD_HALF_WIDTH: float = 150.0
## Nothing solid within this of a cell's middle: the spawn point, the chairs
## and the way across all go through there.
const CENTRE_CLEARANCE: float = 170.0
## Half the width of the tall trees' canopies, kept clear of building walls.
const TREE_CANOPY: float = 150.0
const TREE_HEIGHT: float = 420.0

## Exterior tile families, as the N in the tiles' `_each_N.png` file names.
const TUFTY: Array[int] = [0, 1]
const LAWN: Array[int] = [2, 3]
const EARTH: Array[int] = [4, 5, 6, 7]
const GRAVEL: Array[int] = [8, 9, 10, 11]
const PAVING: Array[int] = [12, 13, 14, 15]

var kind: Dictionary = {}          ## Vector2i -> Kind
var building_of: Dictionary = {}   ## Vector2i -> building index
var buildings: Array = []          ## Array of Array[Vector2i]
var entrances: Array = []          ## [Vector2i building cell, String side]
var road: Array[Vector2i] = []
var road_ends: Dictionary = {}     ## Vector2i -> Array of perimeter sides
var start_cell := Vector2i.ZERO
## Where the entrance doors ended up, so nothing is planted in front of one.
var door_points: Array[Vector2] = []

var _maze: Node2D = null
var _rng: RandomNumberGenerator = null
var _grid := Vector2i.ZERO
var _half := Vector2.ZERO          ## A room diamond's half-width and half-height.
var _centre := Vector2.ZERO        ## A diamond's middle, relative to its room.
var _ponds: Array = []             ## [Vector2 centre, Vector2 radii]
var _solid: Array = []             ## [Vector2 position, float radius]
var _tiles: Dictionary = {}        ## tile family number -> source id
var _noise := FastNoiseLite.new()
var _roofs: Array = []             ## per building: Array[CanvasItem]
var _roof_alpha: Array[float] = []
var _sky_lights: Array[PointLight2D] = []
var _scenes: Dictionary = {}
var biome: ExteriorBiome = null
var theme: LevelTheme = null
var _biome_tileset: TileSet = null
var _biome_tiles: Array[int] = []
var _biome_road: Array[int] = []
var _biome_court: Array[int] = []
var _tree_bounds: Dictionary = {}


func _init(maze: Node2D, rng: RandomNumberGenerator, grid: Vector2i,
		step: Vector2) -> void:
	_maze = maze
	_rng = rng
	_grid = grid
	_half = step * 0.5
	biome = ExteriorBiome.definition(ExteriorBiome.Id.SAKURA)


func is_building(cell: Vector2i) -> bool:
	return kind.get(cell, Kind.BUILDING) == Kind.BUILDING


func same_building(a: Vector2i, b: Vector2i) -> bool:
	return building_of.has(a) and building_of.get(a) == building_of.get(b, -1)


func is_pond(cell: Vector2i) -> bool:
	return kind.get(cell, -1) == Kind.POND


## Makes the selected spawn cell the compound's one invariant: a one-room
## refuge. Everything else remains seeded and procedural. Treating it as a
## building before room instantiation gives it walls, a roof and a guaranteed
## entrance through the same architecture path as every other shrine.
func make_safe_room(cell: Vector2i) -> void:
	for cells in buildings:
		if cells.has(cell):
			cells.erase(cell)
	road.erase(cell)
	road_ends.erase(cell)
	kind[cell] = Kind.BUILDING
	building_of[cell] = buildings.size()
	buildings.append([cell])


# --- Planning ----------------------------------------------------------------

## Decides what every cell is. Runs before a single room exists, so the monster
## draw can already skip the start cell.
func plan() -> void:
	kind.clear()
	building_of.clear()
	buildings.clear()
	road.clear()
	road_ends.clear()
	_plan_road()
	_plan_buildings()
	_plan_ponds()
	for iy in _grid.y:
		for ix in _grid.x:
			var cell := Vector2i(ix, iy)
			if kind.has(cell):
				continue
			var by_building := false
			for side in SIDES:
				if building_of.has(cell + NEIGHBOUR[side]):
					by_building = true
			kind[cell] = Kind.COURTYARD if by_building and _rng.randf() < 0.55 \
					else Kind.GARDEN
	## The road cell nearest the middle, so the camera opens on the compound
	## rather than on its edge.
	var middle := Vector2(_grid - Vector2i.ONE) * 0.5
	var best: float = INF
	for cell in road:
		var d: float = Vector2(cell).distance_squared_to(middle)
		if d < best:
			best = d
			start_cell = cell


## An abandoned road straight across the compound, edge to edge, jinking a lane
## sideways now and then so it does not read as a ruler line.
func _plan_road() -> void:
	var along_x: bool = _rng.randf() < 0.5
	var length: int = _grid.x if along_x else _grid.y
	var width: int = _grid.y if along_x else _grid.x
	var lane: int = _rng.randi_range(mini(1, width - 1), maxi(width - 2, 0))
	var a: int = 0
	var jinked := false
	road.append(_road_cell(along_x, a, lane))
	while a < length - 1:
		if not jinked and a > 0 and _rng.randf() < 0.3:
			var next_lane: int = lane + (1 if _rng.randf() < 0.5 else -1)
			if next_lane >= 0 and next_lane < width:
				lane = next_lane
				road.append(_road_cell(along_x, a, lane))
				jinked = true
				continue
		a += 1
		jinked = false
		road.append(_road_cell(along_x, a, lane))
	for cell in road:
		kind[cell] = Kind.ROAD
	## Where it leaves the compound: through the NW/SE edges running along x,
	## through NE/SW running along y.
	road_ends[road[0]] = ["NW" if along_x else "NE"]
	var last: Array = road_ends.get(road[-1], [])
	last.append("SE" if along_x else "SW")
	road_ends[road[-1]] = last


func _road_cell(along_x: bool, a: int, lane: int) -> Vector2i:
	return Vector2i(a, lane) if along_x else Vector2i(lane, a)


## Separate buildings, grown cell by cell. No two share a wall, so each one is
## a building on its own with open ground all the way round it.
func _plan_buildings() -> void:
	var wanted: int = _rng.randi_range(_maze.buildings_per_floor.x,
			_maze.buildings_per_floor.y)
	for _b in wanted:
		for _attempt in 40:
			var seed_cell := Vector2i(_rng.randi_range(0, _grid.x - 1),
					_rng.randi_range(0, _grid.y - 1))
			if not _free_for_building(seed_cell):
				continue
			var target: int = _rng.randi_range(_maze.building_size.x,
					_maze.building_size.y)
			var cells: Array[Vector2i] = [seed_cell]
			while cells.size() < target:
				var options: Array[Vector2i] = []
				for c in cells:
					for side in SIDES:
						var n: Vector2i = c + NEIGHBOUR[side]
						if not cells.has(n) and not options.has(n) \
								and _free_for_building(n):
							options.append(n)
				if options.is_empty():
					break
				cells.append(options[_rng.randi_range(0, options.size() - 1)])
			if cells.size() < 2:
				continue
			for c in cells:
				kind[c] = Kind.BUILDING
				building_of[c] = buildings.size()
			buildings.append(cells)
			break


func _free_for_building(cell: Vector2i) -> bool:
	if cell.x < 0 or cell.y < 0 or cell.x >= _grid.x or cell.y >= _grid.y:
		return false
	if kind.has(cell):
		return false
	for side in SIDES:
		if building_of.has(cell + NEIGHBOUR[side]):
			return false
	return true


func _plan_ponds() -> void:
	if not biome.ponds:
		return
	var spare: Array[Vector2i] = []
	for iy in _grid.y:
		for ix in _grid.x:
			var cell := Vector2i(ix, iy)
			if not kind.has(cell):
				spare.append(cell)
	var wanted: int = mini(_rng.randi_range(1, maxi(_maze.max_ponds, 1)), spare.size())
	if _maze.max_ponds <= 0:
		wanted = 0
	for _i in wanted:
		var pick: Vector2i = spare.pop_at(_rng.randi_range(0, spare.size() - 1))
		kind[pick] = Kind.POND


# --- Carving -------------------------------------------------------------------

## Fills in MazeDemo's wall table: open ground is open in every direction, each
## building is a small maze of its own, and the two only meet at entrances.
func carve(walls: Dictionary) -> void:
	for cell in kind:
		for side in SIDES:
			var other: Vector2i = cell + NEIGHBOUR[side]
			if not kind.has(other):
				## The compound's edge: open ground runs out to a tree line and an
				## invisible fence, while a building keeps its back wall.
				if not is_building(cell):
					walls[cell][side] = false
			elif not is_building(cell) and not is_building(other):
				walls[cell][side] = false

	for cells in buildings:
		var visited: Dictionary = {cells[0]: true}
		var stack: Array[Vector2i] = [cells[0]]
		while not stack.is_empty():
			var cell: Vector2i = stack[-1]
			var options: Array[String] = []
			for side in SIDES:
				var n: Vector2i = cell + NEIGHBOUR[side]
				if cells.has(n) and not visited.has(n):
					options.append(side)
			if options.is_empty():
				stack.pop_back()
				continue
			var side: String = options[_rng.randi_range(0, options.size() - 1)]
			_open(walls, cell, side)
			visited[cell + NEIGHBOUR[side]] = true
			stack.append(cell + NEIGHBOUR[side])
		for cell in cells:
			for side in SIDES:
				if cells.has(cell + NEIGHBOUR[side]) \
						and _rng.randf() < _maze.openness:
					_open(walls, cell, side)

	_choose_entrances()
	for entrance in entrances:
		_open(walls, entrance[0], entrance[1])


func _open(walls: Dictionary, cell: Vector2i, side: String) -> void:
	walls[cell][side] = false
	var other: Vector2i = cell + NEIGHBOUR[side]
	if walls.has(other):
		walls[other][FACING_BACK[side]] = false


## At least one way into every building from each separate patch of ground it
## touches — a building can wall a corner off from the rest, and that corner
## still has to be reachable — plus sometimes a second door for a shortcut.
func _choose_entrances() -> void:
	entrances.clear()
	var patch: Dictionary = {}
	var patches: int = 0
	for cell in kind:
		if is_building(cell) or patch.has(cell):
			continue
		var queue: Array[Vector2i] = [cell]
		patch[cell] = patches
		while not queue.is_empty():
			var at: Vector2i = queue.pop_back()
			for side in SIDES:
				var n: Vector2i = at + NEIGHBOUR[side]
				if kind.has(n) and not is_building(n) and not patch.has(n):
					patch[n] = patches
					queue.append(n)
		patches += 1

	for cells in buildings:
		var by_patch: Dictionary = {}
		var every: Array = []
		for cell in cells:
			for side in SIDES:
				var n: Vector2i = cell + NEIGHBOUR[side]
				if not patch.has(n):
					continue
				var option := [cell, side]
				## Not out into a pond.
				if is_pond(n) and _rng.randf() < 0.8:
					continue
				every.append(option)
				if not by_patch.has(patch[n]):
					by_patch[patch[n]] = []
				by_patch[patch[n]].append(option)
		## A patch reachable only past a pond still needs its door.
		for cell in cells:
			for side in SIDES:
				var n: Vector2i = cell + NEIGHBOUR[side]
				if patch.has(n) and not by_patch.has(patch[n]):
					by_patch[patch[n]] = [[cell, side]]
		var chosen: Array = []
		for key in by_patch:
			var options: Array = by_patch[key]
			chosen.append(options[_rng.randi_range(0, options.size() - 1)])
		if every.size() > chosen.size() and _rng.randf() < 0.5:
			for _try in 8:
				var extra: Array = every[_rng.randi_range(0, every.size() - 1)]
				if not chosen.has(extra):
					chosen.append(extra)
					break
		entrances.append_array(chosen)


# --- Dressing ------------------------------------------------------------------

## Measures where a room's diamond sits relative to the room node. Needs a room
## that is in the tree.
func measure(room: Node2D) -> void:
	var ground := room.get_node_or_null("TileMap/Ground") as TileMapLayer
	if ground == null:
		return
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for at in ground.get_used_cells():
		var p: Vector2 = ground.to_global(ground.map_to_local(at)) - room.global_position
		lo = lo.min(p)
		hi = hi.max(p)
	_centre = (lo + hi) * 0.5


func cell_centre(cell: Vector2i) -> Vector2:
	var room := _maze._rooms.get(cell) as Node2D
	if room == null:
		return Vector2.ZERO
	return room.global_position + _centre


## Which lattice cell a world position falls in, by undoing _lattice_position.
## The diamonds tile the plane exactly, so rounding in the rotated frame lands
## in the right one right up to the edges.
func cell_at(world: Vector2) -> Vector2i:
	var q: Vector2 = _maze.to_local(world) - _centre
	var a: float = q.x / _half.x
	var b: float = q.y / _half.y
	return Vector2i(roundi((a + b) * 0.5), roundi((b - a) * 0.5))


func weather_grid() -> Vector2i:
	return _grid


func weather_inverse_lattice() -> Vector4:
	var x: Vector2 = _maze.global_transform.basis_xform(Vector2(_half.x, _half.y))
	var y: Vector2 = _maze.global_transform.basis_xform(Vector2(-_half.x, _half.y))
	var inverse := Transform2D(x, y, Vector2.ZERO).affine_inverse()
	return Vector4(inverse.x.x, inverse.y.x, inverse.x.y, inverse.y.y)


func weather_mask() -> Texture2D:
	var image := Image.create(_grid.x, _grid.y, false, Image.FORMAT_R8)
	for cell: Vector2i in kind:
		image.set_pixel(cell.x, cell.y, Color.BLACK if is_building(cell) else Color.WHITE)
	return ImageTexture.create_from_image(image)


func _corner(cell: Vector2i, unit: Vector2) -> Vector2:
	return cell_centre(cell) + unit * _half


## Puts exterior tiles down on every outdoor cell. Runs after the floor has
## been themed, so it overrides whatever indoor floor the theme gave them.
func paint_ground() -> void:
	_noise.seed = _rng.randi()
	_noise.frequency = 0.004
	for cell in kind:
		if is_building(cell):
			continue
		var room: Node = _maze._rooms.get(cell)
		if room == null:
			continue
		var ground := room.get_node_or_null("TileMap/Ground") as TileMapLayer
		var outdoor := room.get_node_or_null("TileMap/Floor_JP_Exterior") as TileMapLayer
		if ground == null or outdoor == null or outdoor.tile_set == null:
			continue
		if not biome.ground_paths.is_empty():
			if _biome_tileset == null:
				_biome_tileset = outdoor.tile_set.duplicate() as TileSet
				_biome_tiles = _add_biome_sources(biome.ground_paths)
				_biome_road = _add_biome_sources(biome.road_paths)
				_biome_court = _add_biome_sources(biome.courtyard_paths)
			outdoor.tile_set = _biome_tileset
		if _tiles.is_empty():
			_index_tiles(outdoor.tile_set)
		var indoor := room.get_node_or_null("TileMap/Floor_JP_Indoor") as TileMapLayer
		if indoor != null:
			indoor.visible = false
			indoor.clear()
		ground.visible = false
		outdoor.clear()
		var what: Kind = kind[cell]
		for at in ground.get_used_cells():
			var world: Vector2 = ground.to_global(ground.map_to_local(at))
			outdoor.set_cell(at, _tile_for(what, cell, world), Vector2i.ZERO)
		outdoor.visible = true


func _add_biome_sources(paths: Array[String]) -> Array[int]:
	var ids: Array[int] = []
	for path in paths:
		var source := TileSetAtlasSource.new()
		source.texture = load(path) as Texture2D
		source.texture_region_size = Vector2i(48, 48)
		source.create_tile(Vector2i.ZERO)
		ids.append(_biome_tileset.add_source(source))
	return ids


func _index_tiles(tiles: TileSet) -> void:
	var number := RegEx.create_from_string("_each_(\\d+)\\.png$")
	for i in tiles.get_source_count():
		var id: int = tiles.get_source_id(i)
		var source := tiles.get_source(id) as TileSetAtlasSource
		if source == null or source.texture == null:
			continue
		var found := number.search(source.texture.resource_path)
		if found != null:
			_tiles[int(found.get_string(1))] = id


func _pick(family: Array[int]) -> int:
	var n: int = family[_rng.randi_range(0, family.size() - 1)]
	return _tiles.get(n, _tiles.values()[0])


func _tile_for(what: Kind, cell: Vector2i, world: Vector2) -> int:
	if not _biome_tiles.is_empty():
		if what == Kind.ROAD and _on_road(cell, world, ROAD_HALF_WIDTH):
			if not _biome_road.is_empty():
				return _biome_road[_rng.randi_range(0, _biome_road.size() - 1)]
			return _pick(PAVING)
		if what == Kind.COURTYARD:
			if not _biome_court.is_empty():
				return _biome_court[_rng.randi_range(0, _biome_court.size() - 1)]
			return _pick(GRAVEL)
		return _biome_tiles[_rng.randi_range(0, _biome_tiles.size() - 1)]
	if theme != null:
		if what == Kind.ROAD and _on_road(cell, world, ROAD_HALF_WIDTH):
			var roll := _rng.randf()
			if roll < theme.road_weed_chance:
				return _pick(TUFTY)
			if roll < theme.road_weed_chance + theme.road_earth_chance:
				return _pick(EARTH)
			return _pick(PAVING)
		if what == Kind.COURTYARD and _rng.randf() < theme.courtyard_earth_chance:
			return _pick(EARTH)
	## The y axis doubled, so patches come out round on the ground.
	var n: float = _noise.get_noise_2d(world.x, world.y * 2.0)
	var roll: float = _rng.randf()
	match what:
		Kind.ROAD:
			if _on_road(cell, world, ROAD_HALF_WIDTH):
				## Abandoned: stones lifted, earth and weeds in the gaps.
				if roll < 0.08:
					return _pick(TUFTY)
				if roll < 0.24 or n > 0.45:
					return _pick(EARTH)
				return _pick(PAVING)
			if _on_road(cell, world, ROAD_HALF_WIDTH + 60.0) and roll < 0.6:
				return _pick(EARTH)
		Kind.COURTYARD:
			if n > 0.5:
				return _pick(LAWN)
			if n > 0.38 and roll < 0.5:
				return _pick(TUFTY)
			return _pick(GRAVEL)
		Kind.POND:
			if _pond_distance(world) < 1.35:
				return _pick(EARTH) if roll < 0.7 else _pick(TUFTY)
	if n < -0.42:
		return _pick(EARTH)
	if n > 0.3 or roll < 0.12:
		return _pick(TUFTY)
	return _pick(LAWN)


## Is `world` on the paved strip through a road cell? The strip runs from the
## middle of the cell out to each side that carries the road on.
func _on_road(cell: Vector2i, world: Vector2, half_width: float) -> bool:
	var centre: Vector2 = cell_centre(cell)
	var flat := Vector2(world.x, world.y * 2.0)
	for side in _road_sides(cell):
		var ends: Array = SIDE_ENDS[side]
		var mid: Vector2 = centre + (ends[0] + ends[1]) * 0.5 * _half
		var a := Vector2(centre.x, centre.y * 2.0)
		var b := Vector2(mid.x, mid.y * 2.0)
		if Geometry2D.get_closest_point_to_segment(flat, a, b).distance_to(flat) < half_width:
			return true
	return false


func _road_sides(cell: Vector2i) -> Array:
	var sides: Array = road_ends.get(cell, []).duplicate()
	var at: int = road.find(cell)
	if at < 0:
		return sides
	for side in SIDES:
		var n: Vector2i = cell + NEIGHBOUR[side]
		var there: int = road.find(n)
		if there >= 0 and absi(there - at) == 1:
			sides.append(side)
	return sides


## The compound's outer edge: an invisible fence where open ground meets the
## void, behind two ragged rows of trees, with a torii where the road leaves.
func build_perimeter() -> void:
	for cell in kind:
		if is_building(cell):
			continue
		var centre: Vector2 = cell_centre(cell)
		for side in SIDES:
			if kind.has(cell + NEIGHBOUR[side]):
				continue
			var a: Vector2 = _corner(cell, SIDE_ENDS[side][0])
			var b: Vector2 = _corner(cell, SIDE_ENDS[side][1])
			var fence := StaticBody2D.new()
			fence.name = "Fence_%d_%d_%s" % [cell.x, cell.y, side]
			fence.collision_layer = 1
			fence.collision_mask = 0
			## A slab running out from the edge rather than a line along it: a body
			## shoved across a line lands on the far side and stays there, while
			## anything pushed into a slab is pushed back out the way it came.
			var outward: Vector2 = ((a + b) * 0.5 - centre).normalized() * 240.0
			var shape := CollisionPolygon2D.new()
			shape.polygon = PackedVector2Array([a, b, b + outward, a + outward])
			fence.add_child(shape)
			_maze.add_child(fence)

			var gate: bool = road_ends.get(cell, []).has(side)
			for row in 2:
				var count: int = 5 - row
				for i in count:
					var t: float = (float(i) + 0.5 + 0.5 * row) / float(count + row) \
							+ _rng.randf_range(-0.03, 0.03)
					if gate and absf(t - 0.5) < 0.24:
						continue
					var inset: float = [0.05, 0.14][row] + _rng.randf_range(-0.02, 0.02)
					var spot: Vector2 = a.lerp(b, t).lerp(centre, inset)
					var tree: String = biome.edge_trees[_rng.randi_range(0, biome.edge_trees.size() - 1)]
					var bounds := _bounds_for_tree(tree)
					if _crowded(spot, 90.0) or _clips_building(spot, bounds.x, bounds.y):
						continue
					_put(tree, spot, 90.0)
			if gate:
				var mid: Vector2 = a.lerp(b, 0.5).lerp(centre, 0.1)
				## The gate's crossbeam runs along +x, so it straddles a road
				## heading NE-SW as drawn and is mirrored for one heading NW-SE.
				_put("torii_gate", mid, 0.0, side == "NW" or side == "SE")
				var along: Vector2 = (b - a).normalized()
				for s in [-1.0, 1.0]:
					_put_lantern(mid + along * 170.0 * s + (centre - mid).normalized() * 40.0)


func build_ponds() -> void:
	_ponds.clear()
	var shader := load(WATER_SHADER) as Shader
	for cell in kind:
		if not is_pond(cell):
			continue
		var centre: Vector2 = cell_centre(cell) + Vector2(
				_rng.randf_range(-40.0, 40.0), _rng.randf_range(-20.0, 20.0))
		var size: float = _rng.randf_range(0.85, 1.0)
		var radii := Vector2(330.0, 165.0) * size
		_ponds.append([centre, radii])
		var outline := PackedVector2Array()
		var wobble := Vector4(_rng.randf() * TAU, _rng.randf() * TAU,
				_rng.randf_range(0.05, 0.1), _rng.randf_range(0.03, 0.06))
		for i in 32:
			var angle: float = TAU * float(i) / 32.0
			var r: float = 1.0 + wobble.z * sin(3.0 * angle + wobble.x) \
					+ wobble.w * sin(5.0 * angle + wobble.y)
			outline.append(Vector2(cos(angle) * radii.x, sin(angle) * radii.y) * r)

		## Sorted by its bottom edge and on the floor's own z level, so the
		## ground tiles it lies over are all drawn first.
		var pond := Node2D.new()
		pond.name = "Pond_%d_%d" % [cell.x, cell.y]
		pond.z_index = -1
		pond.z_as_relative = false
		_maze.add_child(pond)
		var bottom := Vector2(0.0, radii.y * 1.25 + 14.0)
		pond.global_position = centre + bottom

		var bank := Polygon2D.new()
		bank.color = Color(0.22, 0.19, 0.14)
		bank.polygon = _scaled(outline, 1.14, -bottom)
		pond.add_child(bank)
		var water := Polygon2D.new()
		water.polygon = _scaled(outline, 1.0, -bottom)
		var material := ShaderMaterial.new()
		material.shader = shader
		water.material = material
		pond.add_child(water)
		var rim := Line2D.new()
		rim.points = _scaled(outline, 1.04, -bottom)
		rim.closed = true
		rim.width = 6.0
		rim.default_color = Color(0.40, 0.40, 0.37)
		pond.add_child(rim)

		var body := StaticBody2D.new()
		body.collision_layer = 3
		body.collision_mask = 0
		var shape := CollisionPolygon2D.new()
		shape.polygon = _scaled(outline, 0.94, -bottom)
		body.add_child(shape)
		pond.add_child(body)


func _scaled(points: PackedVector2Array, by: float, offset: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		out.append(p * by + offset)
	return out


## How far `world` is from the nearest pond, in pond radii: below 1 is water.
func _pond_distance(world: Vector2) -> float:
	var best: float = INF
	for pond in _ponds:
		best = minf(best, ((world - pond[0]) / pond[1]).length())
	return best


## True where nothing new should go: in or right beside water, or on top of
## something solid already placed out here.
func blocked(world: Vector2, margin: float = 30.0) -> bool:
	for pond in _ponds:
		var radii: Vector2 = pond[1]
		if ((world - pond[0]) / radii).length() < 1.0 + (margin + 30.0) / radii.x:
			return true
	if _by_edge(world, margin + 50.0):
		return true
	return _crowded(world, margin)


## In or right at the edge of a pond, or out past the compound's edge.
func wet(world: Vector2) -> bool:
	return _pond_distance(world) < 1.3 or _by_edge(world, 60.0)


## Within `margin` of the compound's open edge, where there is only the fence
## behind and a body spawned there can be shoved straight into it.
func _by_edge(world: Vector2, margin: float) -> bool:
	var cell: Vector2i = cell_at(world)
	if not kind.has(cell):
		return true
	var q: Vector2 = _maze.to_local(world) - _centre
	var a: float = q.x / _half.x
	var b: float = q.y / _half.y
	var du: float = (a + b) * 0.5 - float(cell.x)
	var dv: float = (b - a) * 0.5 - float(cell.y)
	## One unit of u or v is one diamond side, about _half.length() long.
	var m: float = 0.5 - margin / _half.length()
	var near := {"NW": du < -m, "SE": du > m, "NE": dv < -m, "SW": dv > m}
	for side in near:
		if near[side] and not kind.has(cell + NEIGHBOUR[side]):
			return true
	return false


func _crowded(world: Vector2, radius: float) -> bool:
	for thing in _solid:
		if world.distance_to(thing[0]) < radius + thing[1]:
			return true
	return false


func _scene(prop: String) -> PackedScene:
	if not _scenes.has(prop):
		_scenes[prop] = WorldObjects.scene(prop)
	return _scenes[prop]


## One exterior prop at a ground position. Solid props block later placements
## within `radius`; grass and reeds pass zero and are left out.
func _put(prop: String, world: Vector2, radius: float, mirrored: bool = false) -> Node2D:
	var scene := _scene(prop)
	if scene == null:
		return null
	var fixed_direction := 0
	if prop == "torii_gate" or prop.begins_with("komainu_statue"):
		fixed_direction = 3 if mirrored else 1
	var thing := WorldObjects.choose(scene, _rng, fixed_direction).instantiate() as Node2D
	if thing is ExteriorProp:
		thing.collision_layer = 3 if thing.blocks_movement else 0
	elif thing is CollisionObject2D:
		## The props' layer, not the walls': chairs and spawns test against it.
		(thing as CollisionObject2D).collision_layer = 3
	_maze.add_child(thing)
	thing.global_position = world
	if radius > 0.0:
		_solid.append([world, radius])
	return thing


func _put_lantern(world: Vector2) -> void:
	for scene in _maze.torch_scenes:
		if WorldObjects.family_of(scene) == "stone_lantern_lit":
			var lantern := WorldObjects.choose(scene, _rng).instantiate() as Node2D
			_maze.add_child(lantern)
			lantern.global_position = world
			_solid.append([world, 35.0])
			return


## Flips a prop left to right, collision and shadows included.
func _mirror(thing: Node) -> void:
	for child in thing.get_children():
		if child is Sprite2D:
			child.flip_h = not child.flip_h
			child.offset.x = -child.offset.x
			child.position.x = -child.position.x
		elif child is CollisionPolygon2D:
			child.polygon = _flip(child.polygon)
		elif child is LightOccluder2D and child.occluder != null:
			var occluder := child.occluder.duplicate() as OccluderPolygon2D
			occluder.polygon = _flip(occluder.polygon)
			child.occluder = occluder
	if "fade_rect" in thing:
		var r: Rect2 = thing.fade_rect
		thing.fade_rect = Rect2(-r.position.x - r.size.x, r.position.y, r.size.x, r.size.y)


func _flip(points: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		out.append(Vector2(-p.x, p.y))
	return out


## A random spot in a cell, clear of water, of whatever is already standing
## there, of the cell's middle, of the doors and — unless asked — of the road.
func _spot(cell: Vector2i, radius: float, off_road: bool = true) -> Variant:
	var centre: Vector2 = cell_centre(cell)
	for _try in 24:
		var u: float = _rng.randf_range(-0.42, 0.42)
		var v: float = _rng.randf_range(-0.42, 0.42)
		var p: Vector2 = centre + Vector2((u - v) * _half.x, (u + v) * _half.y)
		if radius > 0.0 and p.distance_to(centre) < CENTRE_CLEARANCE + radius:
			continue
		if blocked(p, radius):
			continue
		if off_road and kind[cell] == Kind.ROAD and _on_road(cell, p, ROAD_HALF_WIDTH + radius):
			continue
		var by_door := false
		for door in door_points:
			if p.distance_to(door) < 200.0 + radius:
				by_door = true
				break
		if by_door:
			continue
		return p
	return null


func _scatter(cell: Vector2i, props: Array, count: int, radius: float,
		off_road: bool = true, canopy: float = 0.0) -> void:
	if theme != null:
		if canopy > 0.0:
			count = int(round(count * theme.tree_density))
		elif props == ["grass_tuft"]:
			count = int(round(count * theme.grass_density))
	for _i in count:
		var prop: String = ""
		var bounds := Vector2(canopy, TREE_HEIGHT)
		if canopy > 0.0 and biome.id != ExteriorBiome.Id.SAKURA:
			prop = props[_rng.randi_range(0, props.size() - 1)]
			bounds = _bounds_for_tree(prop)
		var p: Variant = _spot(cell, radius, off_road)
		if p != null and canopy > 0.0 and _clips_building(p, bounds.x, bounds.y):
			p = _spot(cell, radius, off_road)
			if p != null and _clips_building(p, bounds.x, bounds.y):
				p = null
		if p != null:
			if prop.is_empty():
				prop = props[_rng.randi_range(0, props.size() - 1)]
			_put(prop, p, radius)


func _bounds_for_tree(prop: String) -> Vector2:
	if _tree_bounds.has(prop):
		return _tree_bounds[prop]
	var bounds := Vector2(TREE_CANOPY, TREE_HEIGHT)
	for direction in range(1, 9):
		var instance := WorldObjects.scene(prop, direction).instantiate() as Node2D
		var sprite := instance.get_node_or_null("Sprite2D") as Sprite2D
		if sprite != null:
			var rect: Rect2 = sprite.transform * sprite.get_rect()
			bounds.x = maxf(bounds.x, maxf(absf(rect.position.x), absf(rect.end.x)))
			bounds.y = maxf(bounds.y, -rect.position.y)
		instance.free()
	_tree_bounds[prop] = bounds
	return bounds


## Whether a tall prop's canopy at `world` would overlap any wall's art.
## Each wall tile is one long slab y-sorted at a single point, so a canopy
## that crosses one is either cut by it or drawn over it out of order.
func _clips_building(world: Vector2, canopy: float, height: float = TREE_HEIGHT) -> bool:
	var crown := Rect2(world.x - canopy, world.y - height, canopy * 2.0, height - 60.0)
	var home: Vector2i = cell_at(world)
	for dx in range(-2, 3):
		for dy in range(-2, 3):
			var room := _maze._rooms.get(home + Vector2i(dx, dy)) as Node2D
			if room == null:
				continue
			for side in ["NW", "NE", "SW", "SE"]:
				var layer := room.get_node_or_null("TileMap/Walls_" + side) as TileMapLayer
				if layer == null or not layer.visible:
					continue
				for c in layer.get_used_cells():
					var source := layer.tile_set.get_source(layer.get_cell_source_id(c)) \
							as TileSetAtlasSource
					if source == null:
						continue
					var atlas: Vector2i = layer.get_cell_atlas_coords(c)
					var data: TileData = source.get_tile_data(atlas, layer.get_cell_alternative_tile(c))
					var size := Vector2(source.texture_region_size * source.get_tile_size_in_atlas(atlas))
					var middle: Vector2 = layer.map_to_local(c) - Vector2(data.texture_origin)
					var art := Rect2(layer.to_global(middle - size * 0.5), size * layer.global_scale)
					if art.intersects(crown):
						return true
	return false


func _lanterns(cell: Vector2i, count: int) -> void:
	for _i in count:
		var p: Variant = _spot(cell, 35.0)
		if p != null:
			_put_lantern(p)


## Guardian dogs either side of every way in, on the outside.
func guard_entrances() -> void:
	for i in mini(entrances.size(), door_points.size()):
		var cell: Vector2i = entrances[i][0]
		var side: String = entrances[i][1]
		var outside: Vector2i = cell + NEIGHBOUR[side]
		if is_pond(outside):
			continue
		var door: Vector2 = door_points[i]
		var ends: Array = SIDE_ENDS[side]
		var along: Vector2 = ((ends[1] - ends[0]) * _half).normalized()
		var out: Vector2 = (cell_centre(outside) - door).normalized()
		var guardian: String = "komainu_statue" if _rng.randf() < 0.5 else "komainu_statue_b"
		for s in [-1.0, 1.0]:
			var p: Vector2 = door + out * 120.0 + along * 130.0 * s
			if not blocked(p, 40.0):
				_put(guardian, p, 45.0, s > 0.0)


## Dresses one outdoor cell. Called from MazeDemo._populate before the
## monsters go in, so they are then kept off the trees and out of the ponds.
func populate(cell: Vector2i) -> void:
	if not biome.lush:
		_scatter(cell, biome.trees, _rng.randi_range(1, 3), 110.0, true, TREE_CANOPY)
		var dressing: Array[String] = biome.small_props
		if theme != null and not theme.small_props.is_empty():
			dressing = theme.small_props
		_scatter(cell, dressing, _rng.randi_range(1, 3), 40.0)
		_lanterns(cell, _rng.randi_range(1, 2))
		return
	var small: Array[String] = theme.small_props if theme != null else ["azalea_bush", "garden_rocks"]
	var grass: Array[String] = ["grass_tuft"]
	match kind[cell]:
		Kind.GARDEN:
			_scatter(cell, biome.trees, _rng.randi_range(2, 4), 110.0, true, TREE_CANOPY)
			_scatter(cell, small, _rng.randi_range(2, 3), 40.0)
			_lanterns(cell, _rng.randi_range(1, 2))
			_scatter(cell, grass, _rng.randi_range(8, 14), 0.0)
		Kind.COURTYARD:
			if _rng.randf() < (theme.ornament_chance if theme != null else 0.45):
				_scatter(cell, ["dragon_statue"], 1, 70.0)
			_lanterns(cell, 2)
			_scatter(cell, small, _rng.randi_range(1, 2), 40.0)
			_scatter(cell, biome.trees, _rng.randi_range(0, 1), 110.0, true, TREE_CANOPY)
			_scatter(cell, grass, _rng.randi_range(3, 6), 0.0)
		Kind.ROAD:
			_lanterns(cell, _rng.randi_range(1, 2))
			_scatter(cell, biome.trees, _rng.randi_range(1, 2), 110.0, true, TREE_CANOPY)
			_scatter(cell, ["garden_rocks"], _rng.randi_range(0, 1), 40.0)
			## Weeds straight through the paving: nobody has walked it in years.
			_scatter(cell, grass, _rng.randi_range(6, 10), 0.0, false)
		Kind.POND:
			for pond in _ponds:
				if cell_at(pond[0]) != cell:
					continue
				var reeds: int = _rng.randi_range(6, 10)
				for i in reeds:
					var angle: float = TAU * (float(i) + _rng.randf_range(-0.3, 0.3)) / float(reeds)
					var p: Vector2 = pond[0] + Vector2(cos(angle), sin(angle)) * pond[1] \
							* _rng.randf_range(1.0, 1.1)
					_put("pond_reeds", p, 0.0)
			_scatter(cell, biome.trees, _rng.randi_range(1, 2), 110.0, true, TREE_CANOPY)
			_scatter(cell, small, _rng.randi_range(1, 2), 40.0)
			_lanterns(cell, 1)


# --- Roofs and light -----------------------------------------------------------

## Themed runs get generated kawara roofs unless the biome keeps square ones.
func japanese_roofs() -> bool:
	return theme != null and not (biome != null and biome.castle_roofs)


## Roofs fade per whole building, whether authored square blocks or kawara.
func setup_roofs() -> void:
	_roofs.clear()
	_roof_alpha.clear()
	for cells in buildings:
		var layers: Array[CanvasItem] = []
		for cell in cells:
			var room: Node = _maze._rooms.get(cell)
			var roof := room.get_node_or_null("TileMap/Roofs") as TileMapLayer \
					if room != null else null
			if roof == null:
				continue
			## WallFade's own HIDE mode works per cell; this drives it instead.
			roof.set_process(false)
			roof.visible = not japanese_roofs()
			if japanese_roofs():
				roof.clear()
			else:
				layers.append(roof)
		if japanese_roofs():
			var japanese := JapaneseRoof.new()
			japanese.name = "JapaneseRoof_%d" % _roofs.size()
			_maze.add_child(japanese)
			japanese.style(biome)
			japanese.build(cells, _half, _centre)
			layers.append(japanese)
		_roofs.append(layers)
		_roof_alpha.append(1.0)


func update_roofs(delta: float, bodies: Array) -> void:
	for b in _roofs.size():
		var target: float = 1.0
		for body in bodies:
			if not is_instance_valid(body):
				continue
			var at: Vector2i = cell_at((body as Node2D).global_position)
			if building_of.get(at, -1) == b:
				target = 0.0
				break
			for offset in BEHIND:
				if building_of.get(at - offset, -1) == b:
					target = minf(target, ROOF_BEHIND_ALPHA)
		var alpha: float = move_toward(_roof_alpha[b], target, ROOF_FADE_SPEED * delta)
		if alpha == _roof_alpha[b]:
			continue
		_roof_alpha[b] = alpha
		for roof in _roofs[b]:
			if is_instance_valid(roof):
				roof.modulate.a = alpha
				roof.visible = alpha > 0.01


## Sky light is confined to each outdoor diamond, not a global directional
## light that would also illuminate roofed interiors.
func light() -> void:
	_sky_lights.clear()
	var image := Image.create(512, 256, false, Image.FORMAT_RGBA8)
	for y in image.get_height():
		for x in image.get_width():
			var radius: float = absf((x + 0.5 - 256.0) / 256.0) \
					+ absf((y + 0.5 - 128.0) / 128.0)
			var strength: float = 1.0 - smoothstep(0.85, 1.0, radius)
			image.set_pixel(x, y, Color(strength, strength, strength, 1.0))
	var sky := ImageTexture.create_from_image(image)
	for cell in kind:
		if is_building(cell):
			continue
		var moon := PointLight2D.new()
		moon.name = "Moon_%d_%d" % [cell.x, cell.y]
		moon.texture = sky
		moon.color = biome.moonlight
		moon.energy = 0.55
		moon.texture_scale = _half.x / 256.0
		_maze.add_child(moon)
		moon.global_position = cell_centre(cell)
		_sky_lights.append(moon)
	update_daylight(_maze.day_night.night_weight())


func update_daylight(night: float) -> void:
	for sky in _sky_lights:
		if is_instance_valid(sky):
			sky.color = Color(1.0, 0.96, 0.85).lerp(biome.moonlight, night)
			sky.energy = lerpf(0.38, 0.40, night)
	var tint := Color.WHITE.lerp(Color(0.48, 0.50, 0.62), night)
	for layers: Array in _roofs:
		for roof: CanvasItem in layers:
			if is_instance_valid(roof) and roof is JapaneseRoof:
				var alpha := roof.modulate.a
				roof.modulate = Color(tint, alpha)
