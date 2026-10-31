extends Node

## Who is playing, on what device, wearing which colour.
##
## Autoloaded, so the character select fills it in and the maze reads it back
## without either knowing about the other — the same trick PowerState uses for
## the single-player choice.
##
## A "slot" is a player: slot 0 is player one. Slots are filled in order and
## never reordered, so player two stays player two even if player three's pad
## is pulled out.

signal roster_changed()
## A pad vanished mid-game. The maze listens and halts until it is back.
signal device_lost(slot: int)
signal device_regained(slot: int)
signal party_control_changed(previous_slot: int, controlled_slot: int)

const MAX_PLAYERS: int = 4

## Bright, clearly distinct, and in slot order. Used for the ring under each
## character and their HUD tint — the colour scheme is their own choice and
## cannot be relied on to tell players apart at a glance in a dark dungeon.
const SLOT_COLOURS: Array[Color] = [
	Color(0.35, 0.75, 1.00),	## blue
	Color(1.00, 0.45, 0.35),	## red
	Color(0.55, 0.95, 0.45),	## green
	Color(1.00, 0.85, 0.35),	## gold
]

## One entry per joined player:
## {"device": int, "scheme": int, "hair": int, "skin": int, "lost": bool, "bot": bool}
var players: Array[Dictionary] = []

## How an AI teammate picks its fights. Stored per bot slot; humans ignore it.
enum BotMode { AGGRESSIVE, DEFENSIVE, STEALTH, PASSIVE }
const BOT_MODE_NAMES: PackedStringArray = ["AGGRESSIVE", "DEFENSIVE", "STEALTH", "PASSIVE"]
const BOT_MODE_TAGS: PackedStringArray = ["AGG", "DEF", "STL", "PAS"]
const DEFAULT_BOT_MODE: int = BotMode.DEFENSIVE
const BOT_MODE_HINTS: PackedStringArray = [
	"HUNTS ENEMIES UNTIL THEY ARE DEFEATED",
	"FIGHTS ONLY WHAT YOU ATTACK OR WHAT ATTACKS YOU",
	"SNEAKS WITH YOU AND STRIKES UNAWARE MONSTERS",
	"REVIVES AND DANCES TO HEAL; FIGHTS ONLY IN SELF-DEFENCE",
]
var level_theme: int = -1
## Gameplay ownership only. Slots, inventories, scores and menu inputs stay put.
var controlled_bot_slot: int = -1


func _ready() -> void:
	Input.joy_connection_changed.connect(_on_joy_changed)


## Wipes the roster back to nobody. Called when the select screen opens, so
## backing out to the title and starting again does not stack players up.
func clear() -> void:
	clear_party_control()
	players.clear()
	level_theme = -1
	roster_changed.emit()


func count() -> int:
	return players.size()


## Adds a player on a device. Returns the slot, or -1 if the roster is full or
## that device is already playing. hair/skin default to -1, meaning "follow
## whatever PowerState's own picker is set to" — unlike scheme, hair and skin
## are not locked unique per player, so leaving them unset is a sensible
## default rather than something every caller must think about.
func join(device: int, scheme: int = -1, hair: int = -1, skin: int = -1) -> int:
	if device < PlayerInput.KEYBOARD or players.size() >= MAX_PLAYERS or has_device(device):
		return -1
	players.append({"device": device, "scheme": scheme, "hair": hair, "skin": skin,
			"lost": false, "bot": false})
	roster_changed.emit()
	return players.size() - 1


func add_bot() -> int:
	if players.size() >= MAX_PLAYERS or human_count() == 0:
		return -1
	var scheme: int = 0
	for i in PowerState.count():
		if not scheme_taken(i):
			scheme = i
			break
	players.append({"device": PlayerInput.BOT, "scheme": scheme, "hair": -1,
			"skin": -1, "lost": false, "bot": true, "mode": DEFAULT_BOT_MODE})
	roster_changed.emit()
	return players.size() - 1


func is_bot(slot: int) -> bool:
	return slot >= 0 and slot < players.size() and players[slot].get("bot", false)


func is_ai_controlled(slot: int) -> bool:
	return is_bot(slot) and slot != controlled_bot_slot


func controller_slot(slot: int) -> int:
	return 0 if slot == controlled_bot_slot and slot >= 0 else slot


func gameplay_label_of(slot: int) -> String:
	return "P1 (AI%d)" % (slot + 1) if slot == controlled_bot_slot and slot >= 0 else label_of(slot)


func gameplay_input_for(slot: int) -> PlayerInput:
	if controlled_bot_slot >= 0:
		if slot == 0:
			return PlayerInput.new(PlayerInput.BOT)
		if slot == controlled_bot_slot:
			return input_for(0)
	return input_for(slot)


func clear_party_control() -> void:
	_set_party_control(-1)


func update_party_control(crew: Array[Node2D]) -> void:
	var first: CharacterBody2D = null
	var selected: CharacterBody2D = null
	for candidate in crew:
		if not is_instance_valid(candidate) or candidate.is_queued_for_deletion() \
				or not (candidate is CharacterBody2D):
			continue
		var slot: int = int(candidate.get("slot"))
		if slot == 0:
			first = candidate
		if slot == controlled_bot_slot and candidate.get("is_dead") != true and is_bot(slot):
			selected = candidate
	# Network lobbies currently have no bot slots. Do not borrow a remote peer's
	# input or let a client select ownership independently of its server.
	if first == null or first.get("is_dead") != true or is_bot(0) or is_network(0) \
			or NetworkManager.is_client:
		clear_party_control()
		return
	if selected != null:
		return
	var best_slot: int = -1
	var distance: float = INF
	for candidate in crew:
		if not is_instance_valid(candidate) or candidate.is_queued_for_deletion() \
				or not (candidate is CharacterBody2D) or candidate.get("is_dead") == true:
			continue
		var slot: int = int(candidate.get("slot"))
		if not is_bot(slot):
			continue
		var reach: float = BotNavigation.ground(candidate.global_position - first.global_position).length_squared()
		if reach < distance or (reach == distance and (best_slot < 0 or slot < best_slot)):
			best_slot = slot
			distance = reach
	_set_party_control(best_slot)


func _set_party_control(slot: int) -> void:
	if slot == controlled_bot_slot:
		return
	var previous := controlled_bot_slot
	controlled_bot_slot = slot
	party_control_changed.emit(previous, slot)


## Seats a remote player connecting over the network. Reuses a slot already
## held open for a network player who dropped — same trick _on_joy_changed
## plays for a pad coming back — rather than always appending, since a
## WebSocketMultiplayerPeer hands out a fresh peer id on every connection and
## the old one can never literally reconnect.
func join_network(peer_id: int) -> int:
	for i in players.size():
		if players[i]["device"] == PlayerInput.NETWORK and players[i]["lost"]:
			players[i]["peer_id"] = peer_id
			players[i]["lost"] = false
			device_regained.emit(i)
			roster_changed.emit()
			return i
	if players.size() >= MAX_PLAYERS:
		return -1
	var scheme: int = 0
	for i in PowerState.count():
		if not scheme_taken(i):
			scheme = i
			break
	players.append({"device": PlayerInput.NETWORK, "peer_id": peer_id, "scheme": scheme,
			"hair": -1, "skin": -1, "lost": false, "bot": false})
	roster_changed.emit()
	return players.size() - 1


func is_network(slot: int) -> bool:
	return slot >= 0 and slot < players.size() \
			and players[slot]["device"] == PlayerInput.NETWORK


func peer_id_of(slot: int) -> int:
	if not is_network(slot):
		return 0
	return int(players[slot].get("peer_id", 0))


func slot_of_peer(peer_id: int) -> int:
	for i in players.size():
		if is_network(i) and int(players[i].get("peer_id", 0)) == peer_id:
			return i
	return -1


## A network peer dropped. Marked lost rather than removed, exactly like a
## pulled controller — the party pauses on that slot (MazeDemo already
## listens for device_lost) and join_network() above reseats whoever
## reconnects into the same slot instead of growing the roster.
func drop_peer(peer_id: int) -> void:
	var slot := slot_of_peer(peer_id)
	if slot == -1:
		return
	players[slot]["lost"] = true
	device_lost.emit(slot)
	roster_changed.emit()


func mode_of(slot: int) -> int:
	if not is_bot(slot):
		return DEFAULT_BOT_MODE
	return int(players[slot].get("mode", DEFAULT_BOT_MODE))


func set_mode(slot: int, mode: int) -> void:
	if not is_bot(slot):
		return
	players[slot]["mode"] = posmod(mode, BOT_MODE_NAMES.size())
	roster_changed.emit()


func cycle_mode(slot: int, step: int = 1) -> int:
	set_mode(slot, mode_of(slot) + step)
	return mode_of(slot)


func human_count() -> int:
	var total: int = 0
	for slot in players.size():
		if not is_bot(slot):
			total += 1
	return total


func label_of(slot: int) -> String:
	return "%s%d" % ["AI" if is_bot(slot) else "P", slot + 1]


## Removes the last player. The select screen backs out this way, so going back
## always returns control to the player before.
func drop_last() -> void:
	if players.is_empty():
		return
	players.pop_back()
	roster_changed.emit()


func has_device(device: int) -> bool:
	for p in players:
		if not p.get("bot", false) and p["device"] == device:
			return true
	return false


## Is this colour scheme already taken. The select screen locks a scheme once
## chosen so two players cannot wear the same one and become indistinguishable.
func scheme_taken(scheme: int, ignoring_slot: int = -1) -> bool:
	for i in players.size():
		if i != ignoring_slot and players[i]["scheme"] == scheme:
			return true
	return false


func set_scheme(slot: int, scheme: int) -> void:
	if slot < 0 or slot >= players.size():
		return
	players[slot]["scheme"] = scheme
	roster_changed.emit()


func scheme_of(slot: int) -> int:
	if slot < 0 or slot >= players.size():
		return PowerState.chosen
	var value: int = players[slot]["scheme"]
	return value if value >= 0 else PowerState.chosen


func set_hair(slot: int, hair: int) -> void:
	if slot < 0 or slot >= players.size():
		return
	players[slot]["hair"] = hair
	roster_changed.emit()


func hair_of(slot: int) -> int:
	if slot < 0 or slot >= players.size():
		return PowerState.chosen_hair
	var value: int = players[slot].get("hair", -1)
	return value if value >= 0 else PowerState.chosen_hair


func set_skin(slot: int, skin: int) -> void:
	if slot < 0 or slot >= players.size():
		return
	players[slot]["skin"] = skin
	roster_changed.emit()


func skin_of(slot: int) -> int:
	if slot < 0 or slot >= players.size():
		return PowerState.chosen_skin
	var value: int = players[slot].get("skin", -1)
	return value if value >= 0 else PowerState.chosen_skin


func device_of(slot: int) -> int:
	if slot < 0 or slot >= players.size():
		return PlayerInput.KEYBOARD
	return players[slot]["device"]


func colour_of(slot: int) -> Color:
	return SLOT_COLOURS[slot % SLOT_COLOURS.size()]


## A fresh input object for a slot, bound to that slot's device.
func input_for(slot: int) -> PlayerInput:
	if is_bot(slot):
		return BotInput.new()
	if is_network(slot):
		return NetworkInput.new(peer_id_of(slot))
	return PlayerInput.new(device_of(slot), slot)


## Reorders the party so devices tied to a slot in Settings sit in that slot:
## "P1 is the keyboard" holds whichever pad pressed first. Assigned players
## come first in slot order; everyone else — unassigned devices, bots, network
## players — keeps their relative order after them. Called once the select
## screen has the whole party, because the select flow itself is "last slot"
## based and would lose track if slots moved under it mid-claim.
func apply_device_assignments() -> void:
	var settings := get_node_or_null("/root/ControlSettings")
	if settings == null or players.size() < 2:
		return
	var keyed: Array = []
	for i in players.size():
		var p: Dictionary = players[i]
		var preferred: int = -1
		if not p.get("bot", false) and p["device"] >= PlayerInput.KEYBOARD:
			preferred = settings.slot_for_device(p["device"])
		keyed.append([preferred if preferred >= 0 else MAX_PLAYERS + i, p])
	keyed.sort_custom(func(a, b) -> bool: return a[0] < b[0])
	var reordered: Array[Dictionary] = []
	for pair in keyed:
		reordered.append(pair[1])
	if reordered != players:
		players = reordered
		roster_changed.emit()


## Every device with nobody on it yet: connected pads plus the keyboard. The
## select screen offers these to whoever presses next.
func free_devices() -> Array[int]:
	var free: Array[int] = []
	if not has_device(PlayerInput.KEYBOARD):
		free.append(PlayerInput.KEYBOARD)
	for id in Input.get_connected_joypads():
		if not has_device(id):
			free.append(id)
	return free


func any_lost() -> bool:
	for p in players:
		if p["lost"]:
			return true
	return false


## Every living player body in the scene.
##
## One place, because this lookup was copy-pasted into four files and three of
## them got it wrong the same way: they latched onto the first CharacterBody2D
## in the group and cached it forever, so the radar, the wall fade and the debug
## overlay all only ever followed player one. The monsters had the identical bug
## and were fixed; these were missed.
##
## Her PlayerHitBox is in the "player" group too, so the body test is not
## optional — the first node in the group is as likely to be that Area2D.
func bodies(tree: SceneTree) -> Array[CharacterBody2D]:
	var out: Array[CharacterBody2D] = []
	for node in tree.get_nodes_in_group("player"):
		if node is CharacterBody2D and not (node.get("is_dead") == true):
			out.append(node)
	return out


## The middle of the party, for anything that has to pick one point to speak
## for everybody — the radar's centre, for instance.
func centre_of_party(tree: SceneTree) -> Vector2:
	var all := bodies(tree)
	if all.is_empty():
		return Vector2.ZERO
	var sum := Vector2.ZERO
	for body in all:
		sum += body.global_position
	return sum / float(all.size())


## The living player closest to a point, or null.
func nearest_to(tree: SceneTree, point: Vector2) -> CharacterBody2D:
	var best: CharacterBody2D = null
	var best_distance: float = INF
	for body in bodies(tree):
		var distance: float = point.distance_squared_to(body.global_position)
		if distance < best_distance:
			best_distance = distance
			best = body
	return best


## A pad appeared or vanished. Mid-game a lost pad holds its slot rather than
## freeing it — a dropped cable should not cost a player their run — and the
## maze pauses until the same slot has a device again.
func _on_joy_changed(device: int, connected: bool) -> void:
	for i in players.size():
		if is_bot(i):
			continue
		if players[i]["device"] != device:
			continue
		players[i]["lost"] = not connected
		if connected:
			device_regained.emit(i)
		else:
			device_lost.emit(i)
		roster_changed.emit()
		return
	## Not one of ours. A pad plugged in while a slot is waiting for a
	## replacement adopts that slot, so any spare pad can rescue a player.
	if connected:
		for i in players.size():
			if not is_bot(i) and players[i]["lost"]:
				players[i]["device"] = device
				players[i]["lost"] = false
				device_regained.emit(i)
				roster_changed.emit()
				return
	roster_changed.emit()
