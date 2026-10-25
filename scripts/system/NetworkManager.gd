extends Node

## WebSocket hosting/joining, remote input snapshots and peer<->Roster-slot
## bookkeeping for dedicated-server online play. Character authority and
## replicated game state are still staged separately; see NETWORKING.md.

signal hosting_started(port: int)
signal host_failed(reason: String)
signal joined_server()
signal join_failed(reason: String)
signal server_lost()
signal lobby_updated(player_count: int, is_leader: bool)
signal session_started()
## The server ended the match (everyone died, or the room emptied). Clients
## use it to leave the floor cleanly rather than sit in a frozen world.
signal match_ended(reason: String)

## A scene with nothing in it, for the dedicated server to sit in between
## matches. Loading the title screen would only pull textures into memory on
## a machine with no screen.
const IDLE_SCENE := "res://scenes/world/serverIdle.tscn"
const MATCH_SCENE := "res://scenes/world/mazeDemo.tscn"

const DEFAULT_PORT: int = 8910
const ACTOR_SNAPSHOT_INTERVAL: float = 0.05
const NETWORK_ACTIONS: PackedStringArray = [
	"Left", "Right", "Up", "Down", "Run", "Katana", "Attack", "Defend",
	"Dodge", "Action", "Jump", "Stealth", "Scroll1", "Scroll2", "Scroll3",
	"Scroll4", "Scroll5", "Scroll6", "ScrollUse", "ScrollPrevious", "ScrollNext",
]

var is_server: bool = false
var is_client: bool = false
var _client_input: PlayerInput
var _room_leader_peer: int = 0
var _session_started: bool = false
var _pending_seed: int = 0
var _pending_theme: int = 0
var _snapshot_left: float = 0.0
## Which local device drives this client's character online. Picked on the
## lobby screen by whoever presses a button first; keyboard until then.
var client_device: int = PlayerInput.KEYBOARD


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	## Keeps snapshots flowing while a client sits in its pause menu — the
	## server never pauses for one player, so the client must keep listening.
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_client_device(PlayerInput.KEYBOARD)
	_maybe_launch_dedicated_server()


## Slot 0's bindings profile: online, the local human is always "player one"
## on their own machine whatever seat the server gave them.
func set_client_device(device: int) -> void:
	client_device = device
	_client_input = PlayerInput.new(device, 0)


func _physics_process(_delta: float) -> void:
	if is_server and _session_started:
		_snapshot_left -= _delta
		if _snapshot_left <= 0.0:
			_snapshot_left = ACTOR_SNAPSHOT_INTERVAL
			_broadcast_actor_snapshot()
	if not is_client or multiplayer.multiplayer_peer == null \
			or multiplayer.multiplayer_peer.get_connection_status() \
			!= MultiplayerPeer.CONNECTION_CONNECTED:
		return
	var actions: Dictionary = {}
	for action in NETWORK_ACTIONS:
		actions[action] = _client_input.pressed(action)
	rpc_id(1, "receive_input_snapshot", actions,
			_client_input.vector(), _client_input.aim_vector())


func is_networked() -> bool:
	return is_server or is_client


## Starts listening for players. All platforms, including the web export,
## speak WebSocket rather than raw ENet/UDP, so a browser client and a
## desktop client use the exact same transport and the server only has one
## listener to run.
func host(port: int = DEFAULT_PORT) -> Error:
	var peer := WebSocketMultiplayerPeer.new()
	var tls: TLSOptions = null
	var certificate_path := OS.get_environment("KK_TLS_CERT_FILE")
	var key_path := OS.get_environment("KK_TLS_KEY_FILE")
	if certificate_path.is_empty() != key_path.is_empty():
		push_error("NetworkManager: set both KK_TLS_CERT_FILE and KK_TLS_KEY_FILE")
		host_failed.emit("tls_configuration_incomplete")
		return ERR_INVALID_PARAMETER
	if not certificate_path.is_empty():
		var certificate := X509Certificate.new()
		var key := CryptoKey.new()
		var cert_error: Error = certificate.load(certificate_path)
		var key_error: Error = key.load(key_path)
		if cert_error != OK or key_error != OK:
			var reason := "TLS certificate/key load failed (%s, %s)" % [
				error_string(cert_error), error_string(key_error)]
			push_error("NetworkManager: " + reason)
			host_failed.emit(reason)
			return ERR_FILE_CANT_READ
		tls = TLSOptions.server(key, certificate)
	var err: Error = peer.create_server(port, "*", tls)
	if err != OK:
		push_error("NetworkManager: failed to host on port %d (%s)" % [port, error_string(err)])
		host_failed.emit(error_string(err))
		return err
	multiplayer.multiplayer_peer = peer
	is_server = true
	is_client = false
	hosting_started.emit(port)
	print("NetworkManager: hosting on port %d" % port)
	return OK


## Connects to someone else's dedicated server as a client.
func join(address: String, port: int = DEFAULT_PORT, secure: bool = true) -> Error:
	var peer := WebSocketMultiplayerPeer.new()
	var slash: int = address.find("/")
	var host: String = address.substr(0, slash) if slash >= 0 else address
	var path: String = address.substr(slash) if slash >= 0 else ""
	var url: String = "%s://%s:%d%s" % [
			"wss" if secure else "ws", host, port, path]
	var err: Error = peer.create_client(url, TLSOptions.client() if secure else null)
	if err != OK:
		push_error("NetworkManager: failed to join %s (%s)" % [url, error_string(err)])
		join_failed.emit(error_string(err))
		return err
	multiplayer.multiplayer_peer = peer
	is_client = true
	is_server = false
	print("NetworkManager: joining %s" % url)
	return OK


## A room address can include the reverse-proxy path allocated by the lobby,
## for example play.9-k9.io/rooms/r01. "host" alone still means the default
## port, preserving direct/legacy server addresses.
func join_room_code(code: String, secure: bool = true) -> Error:
	var parsed: Dictionary = parse_room_code(code)
	var address: String = parsed["address"]
	var loopback: bool = address == "localhost" or address == "127.0.0.1" \
			or address == "::1"
	return join(address, parsed["port"], secure and not loopback)


func parse_room_code(code: String) -> Dictionary:
	var text: String = code.strip_edges()
	text = text.trim_prefix("wss://").trim_prefix("ws://")
	var slash: int = text.find("/")
	## Routed lobby addresses are HTTPS/WSS paths and therefore use 443 even
	## when an older lobby link omitted the explicit port. Plain hostnames keep
	## the legacy direct-server default.
	var port: int = 443 if slash >= 0 else DEFAULT_PORT
	var authority: String = text.substr(0, slash) if slash >= 0 else text
	var path: String = text.substr(slash) if slash >= 0 else ""
	var address: String = authority
	var colon: int = authority.rfind(":")
	if colon != -1:
		var tail: String = authority.substr(colon + 1)
		if tail.is_valid_int():
			port = int(tail)
			address = authority.substr(0, colon)
	if address.is_empty():
		address = "127.0.0.1"
	return {"address": address + path, "port": port}


func stop() -> void:
	var was_online: bool = is_client or is_server
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	is_server = false
	is_client = false
	_session_started = false
	_room_leader_peer = 0
	## The online roster was the server's party, not this machine's; leaving
	## it behind would seat ghosts in the next local game.
	if was_online:
		Roster.clear()


## `--server` (or `--server=PORT`) boots straight into a headless dedicated
## server instead of the title screen — the mode this is meant to run as on a
## small always-on VPS/PaaS instance, with nothing to render.
func _maybe_launch_dedicated_server() -> void:
	for arg in OS.get_cmdline_args():
		if arg == "--server" or arg.begins_with("--server="):
			var port: int = DEFAULT_PORT
			if arg.begins_with("--server="):
				var value: String = arg.substr("--server=".length())
				if value.is_valid_int():
					port = int(value)
			call_deferred("_start_dedicated_server", port)
			return


func _start_dedicated_server(port: int) -> void:
	host(port)
	get_tree().change_scene_to_file(IDLE_SCENE)


## Back to an empty lobby, ready for the next party. Run whenever the room
## empties or a match ends, so one finished game never leaves the server
## stuck on a dead floor for everyone who connects afterwards.
func _reset_server_session() -> void:
	_session_started = false
	_room_leader_peer = 0
	_pending_seed = 0
	Roster.clear()
	get_tree().paused = false
	if multiplayer.multiplayer_peer != null:
		for peer_id in multiplayer.get_peers():
			multiplayer.multiplayer_peer.disconnect_peer(peer_id)
	## Only a finished floor needs tearing down; a server that was already
	## idling (or a test harness hosting from its own scene) stays put.
	var scene := get_tree().current_scene
	if scene != null and scene.scene_file_path == MATCH_SCENE:
		get_tree().change_scene_to_file(IDLE_SCENE)
	print("NetworkManager: session reset, waiting for players")


## The match is over for everyone. Tells every client first, so they can
## leave the floor on their own terms, then clears the room.
func end_session(reason: String) -> void:
	if not is_server:
		return
	rpc("receive_match_ended", reason)
	call_deferred("_reset_server_session")


@rpc("authority", "call_remote", "reliable")
func receive_match_ended(reason: String) -> void:
	if not is_client:
		return
	_session_started = false
	match_ended.emit(reason)


func _on_peer_connected(peer_id: int) -> void:
	if not is_server:
		return
	if _session_started:
		push_warning("NetworkManager: refusing late join from peer %d" % peer_id)
		multiplayer.multiplayer_peer.disconnect_peer(peer_id)
		return
	var slot: int = Roster.join_network(peer_id)
	if slot == -1:
		push_warning("NetworkManager: peer %d refused, party is full" % peer_id)
		multiplayer.multiplayer_peer.disconnect_peer(peer_id)
		return
	if _room_leader_peer == 0:
		_room_leader_peer = peer_id
	print("NetworkManager: peer %d joined as slot %d" % [peer_id, slot])
	_send_lobby_state()


func _on_peer_disconnected(peer_id: int) -> void:
	if not is_server:
		return
	var slot: int = Roster.slot_of_peer(peer_id)
	_reset_network_input(slot)
	if not _session_started:
		## Still in the lobby: the seat simply closes up. Holding it open is
		## for a mid-game drop, not for someone who changed their mind.
		if slot != -1:
			Roster.players.remove_at(slot)
			Roster.roster_changed.emit()
	else:
		## Mid-game there is no coming back (a reconnecting client has none of
		## the floor's state), so the character falls where it stood and the
		## rest of the party plays on rather than waiting on a pause screen.
		Roster.drop_peer(peer_id)
		_kill_body_in_slot(slot)
	if _room_leader_peer == peer_id:
		_room_leader_peer = 0
		for entry in _roster_snapshot():
			_room_leader_peer = int(entry["peer_id"])
			break
	print("NetworkManager: peer %d disconnected" % peer_id)
	if multiplayer.get_peers().is_empty():
		_reset_server_session()
		return
	_send_lobby_state()
	if _session_started and _everyone_dead():
		end_session("party_wiped")


func _kill_body_in_slot(slot: int) -> void:
	if slot == -1:
		return
	for body in get_tree().get_nodes_in_group("player"):
		if body is CharacterBody2D and int(body.get("slot")) == slot \
				and body.get("is_dead") == false:
			body.health = 0
			body.is_dead = true
			if body.has_method("_on_death"):
				body.call("_on_death")
			return


func _everyone_dead() -> bool:
	var any := false
	for body in get_tree().get_nodes_in_group("player"):
		if not (body is CharacterBody2D) or not ("is_dead" in body):
			continue
		any = true
		if not body.is_dead:
			return false
	return any


@rpc("any_peer", "call_remote", "unreliable_ordered")
func receive_input_snapshot(actions: Dictionary, move: Vector2, aim: Vector2) -> void:
	if not is_server:
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	var slot: int = Roster.slot_of_peer(peer_id)
	if peer_id <= 1 or slot == -1 or not Roster.is_network(slot):
		return
	if not move.is_finite() or not aim.is_finite():
		return
	for action in actions:
		if not NETWORK_ACTIONS.has(String(action)) \
				or typeof(actions[action]) != TYPE_BOOL:
			return
	var input := _network_input_for_peer(peer_id, slot)
	if input == null:
		return
	var safe_actions: Dictionary = {}
	for action in NETWORK_ACTIONS:
		safe_actions[action] = actions.get(action, false)
	input.apply_snapshot(safe_actions, move.limit_length(1.0), aim.limit_length(1.0))


func _network_input_for_peer(peer_id: int, slot: int) -> NetworkInput:
	for candidate in get_tree().get_nodes_in_group("player"):
		if not (candidate is CharacterBody2D) or not ("slot" in candidate):
			continue
		if int(candidate.get("slot")) != slot:
			continue
		var input: Variant = candidate.get("input")
		if input is NetworkInput:
			input.peer_id = peer_id
			return input
	return null


func _reset_network_input(slot: int) -> void:
	if slot == -1:
		return
	var input := _network_input_for_peer(Roster.peer_id_of(slot), slot)
	if input != null:
		input.reset()


func _on_connected_to_server() -> void:
	joined_server.emit()
	rpc_id(1, "request_lobby_state")


func _on_connection_failed() -> void:
	is_client = false
	join_failed.emit("connection_failed")


func _on_server_disconnected() -> void:
	is_server = false
	is_client = false
	_session_started = false
	server_lost.emit()


func _roster_snapshot() -> Array[Dictionary]:
	var snapshot: Array[Dictionary] = []
	for slot in Roster.players.size():
		if not Roster.is_network(slot) or Roster.players[slot].get("lost", false):
			continue
		snapshot.append({
			"peer_id": Roster.peer_id_of(slot),
			"scheme": Roster.scheme_of(slot),
			"hair": Roster.hair_of(slot),
			"skin": Roster.skin_of(slot),
		})
	return snapshot


func _send_lobby_state() -> void:
	if not is_server:
		return
	var snapshot := _roster_snapshot()
	for entry in snapshot:
		rpc_id(int(entry["peer_id"]), "receive_lobby_state",
				snapshot, _room_leader_peer, _pending_theme)


func _apply_remote_roster(snapshot: Array) -> bool:
	if snapshot.is_empty() or snapshot.size() > Roster.MAX_PLAYERS:
		return false
	var own_peer: int = multiplayer.get_unique_id()
	var seen: Dictionary = {}
	var replacement: Array[Dictionary] = []
	var owns_slot: bool = false
	for entry in snapshot:
		if not (entry is Dictionary) or not entry.has("peer_id"):
			return false
		var peer_id: int = int(entry["peer_id"])
		if peer_id <= 1 or seen.has(peer_id):
			return false
		seen[peer_id] = true
		var device: int = PlayerInput.KEYBOARD if peer_id == own_peer \
				else PlayerInput.NETWORK
		owns_slot = owns_slot or peer_id == own_peer
		replacement.append({
			"device": device,
			"peer_id": peer_id,
			"scheme": int(entry.get("scheme", -1)),
			"hair": int(entry.get("hair", -1)),
			"skin": int(entry.get("skin", -1)),
			"lost": false,
			"bot": false,
		})
	if not owns_slot:
		return false
	Roster.players = replacement
	Roster.roster_changed.emit()
	return true


@rpc("any_peer", "call_remote", "reliable")
func request_lobby_state() -> void:
	if not is_server or _session_started:
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	if Roster.slot_of_peer(peer_id) == -1:
		return
	rpc_id(peer_id, "receive_lobby_state", _roster_snapshot(), _room_leader_peer,
			_pending_theme)


@rpc("authority", "call_remote", "reliable")
func receive_lobby_state(snapshot: Array, leader_peer: int, theme: int) -> void:
	if not is_client or not _apply_remote_roster(snapshot):
		return
	_room_leader_peer = leader_peer
	_pending_theme = theme
	lobby_updated.emit(Roster.count(), is_room_leader())


func lobby_theme() -> int:
	return _pending_theme


func is_room_leader() -> bool:
	return is_client and _room_leader_peer == multiplayer.get_unique_id()


## This client's own seat. Stored locally as a keyboard slot (it is the one
## seat this machine drives), so it is found by peer id alone rather than via
## Roster.slot_of_peer, which only looks at network seats.
func own_slot() -> int:
	if not is_client:
		return -1
	var own_peer: int = multiplayer.get_unique_id()
	for i in Roster.players.size():
		if int(Roster.players[i].get("peer_id", 0)) == own_peer:
			return i
	return -1


## Lobby choices travel to the server, which owns the roster, and come back
## in the next lobby snapshot — so every client sees the same colours.
func choose_scheme(scheme: int) -> void:
	if is_client:
		rpc_id(1, "request_scheme", scheme)


func choose_theme(theme: int) -> void:
	if is_client and is_room_leader():
		rpc_id(1, "request_theme", theme)


@rpc("any_peer", "call_remote", "reliable")
func request_scheme(scheme: int) -> void:
	if not is_server or _session_started:
		return
	var slot: int = Roster.slot_of_peer(multiplayer.get_remote_sender_id())
	if slot == -1 or scheme < 0 or scheme >= PowerState.count() \
			or Roster.scheme_taken(scheme, slot):
		return
	Roster.set_scheme(slot, scheme)
	_send_lobby_state()


@rpc("any_peer", "call_remote", "reliable")
func request_theme(theme: int) -> void:
	if not is_server or _session_started \
			or multiplayer.get_remote_sender_id() != _room_leader_peer:
		return
	_pending_theme = clampi(theme, 0, LevelTheme.NAMES.size() - 1)
	_send_lobby_state()


func start_room() -> void:
	if is_client and is_room_leader():
		rpc_id(1, "request_start_session")


@rpc("any_peer", "call_remote", "reliable")
func request_start_session() -> void:
	if not is_server or _session_started \
			or multiplayer.get_remote_sender_id() != _room_leader_peer \
			or Roster.count() == 0:
		return
	_session_started = true
	_pending_seed = randi()
	Roster.level_theme = _pending_theme
	rpc("receive_session_start", _pending_seed, _pending_theme, _roster_snapshot())
	_start_session_scene()


@rpc("authority", "call_remote", "reliable")
func receive_session_start(seed: int, theme: int, snapshot: Array) -> void:
	if not is_client or not _apply_remote_roster(snapshot):
		return
	_session_started = true
	_pending_seed = seed
	_pending_theme = theme
	Roster.level_theme = theme
	session_started.emit()
	_start_session_scene()


func consume_pending_floor() -> Dictionary:
	if not _session_started:
		return {}
	return {"seed": _pending_seed, "theme": _pending_theme}


func _start_session_scene() -> void:
	get_tree().paused = false
	## Match the solo transition. A direct scene change skips the autoloaded
	## overlay and lets procedural floor construction hold a blank/frozen frame.
	## NetworkManager is PROCESS_MODE_ALWAYS, so transport stays alive while the
	## local client is covered by the loader.
	SceneLoader.go_to(MATCH_SCENE, "DESCENDING")


## --- World events -----------------------------------------------------------
## Everything on a floor that is not a character is placed identically on
## both sides from the shared seed, so a thing is named by where it stands.
## The server announces what happened to it; the client finds its own copy.

static func world_key(node: Node2D) -> Vector2i:
	return Vector2i(node.global_position.round())


func announce_descend(seed: int, depth: int) -> void:
	if is_server:
		rpc("receive_descend", seed, depth)


@rpc("authority", "call_remote", "reliable")
func receive_descend(seed: int, depth: int) -> void:
	if not is_client:
		return
	var world := get_tree().current_scene
	if world != null and world.has_method("descend_to"):
		world.descend_to(seed, depth)


func announce_world_event(kind: String, node: Node2D) -> void:
	if is_server:
		rpc("receive_world_event", kind, world_key(node))


@rpc("authority", "call_remote", "reliable")
func receive_world_event(kind: String, key: Vector2i) -> void:
	if not is_client:
		return
	var group: String = "breakable" if kind == "break" else "pickup"
	var target := _find_world_node(group, key)
	if target == null:
		return
	match kind:
		"break":
			if target.has_method("network_break"):
				target.network_break()
		"pickup_taken":
			if target.has_method("network_taken"):
				target.network_taken()


func _find_world_node(group: String, key: Vector2i) -> Node2D:
	var best: Node2D = null
	var best_distance: float = 9.0 * 9.0
	for node in get_tree().get_nodes_in_group(group):
		if not (node is Node2D):
			continue
		var d: float = Vector2(key).distance_squared_to((node as Node2D).global_position)
		if d < best_distance:
			best = node
			best_distance = d
	return best


func _scroll_state(body: Node) -> Array:
	var inventory: Variant = body.get("scrolls")
	if inventory == null or not ("kinds" in inventory):
		return []
	return [inventory.kinds, inventory.counts, inventory.selected]


func _actor_animation(body: Node) -> Dictionary:
	var sprite := body.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	if sprite == null:
		sprite = body.get_node_or_null("AnimationManager/AnimatedSprite2D") as AnimatedSprite2D
	if sprite == null:
		return {}
	return {
		"animation": String(sprite.animation),
		"frame": sprite.frame,
		"frame_progress": sprite.frame_progress,
		"playing": sprite.is_playing(),
		"speed_scale": sprite.speed_scale,
		"flip_h": sprite.flip_h,
	}


func _broadcast_actor_snapshot() -> void:
	var players: Array[Dictionary] = []
	for body in get_tree().get_nodes_in_group("player"):
		if not (body is CharacterBody2D) or not ("slot" in body):
			continue
		var machine := body.get_node_or_null("FiniteStateMachine") as FiniteStateMachine
		var state: String = machine.current_state.name if machine != null \
				and machine.current_state != null else ""
		players.append({
			"slot": int(body.get("slot")),
			"position": body.global_position,
			"velocity": body.velocity,
			"facing": String(body.get("facing_dir")),
			"state": state,
			"health": float(body.get("health")),
			"max_health": float(body.get("max_health")),
			"is_dead": body.get("is_dead") == true,
			"katana_drawn": body.get("katana_drawn") == true,
			"stealthed": body.get("stealthed") == true,
			"crouched": body.get("crouched") == true,
			"stamina": float(body.get("stamina")),
			"max_stamina": float(body.get("max_stamina")),
			"scrolls": _scroll_state(body),
			"animation_state": _actor_animation(body),
		})
	var enemies: Array[Dictionary] = []
	for enemy in get_tree().get_nodes_in_group("enemy"):
		if not (enemy is CharacterBody2D) or not ("network_id" in enemy):
			continue
		var machine := enemy.get_node_or_null("FiniteStateMachine") as FiniteStateMachine
		var state: String = machine.current_state.name if machine != null \
				and machine.current_state != null else ""
		enemies.append({
			"id": int(enemy.get("network_id")),
			"position": enemy.global_position,
			"velocity": enemy.velocity,
			"facing": String(enemy.get("facing_dir")),
			"state": state,
			"health": float(enemy.get("health")),
			"is_dead": enemy.get("is_dead") == true,
			"animation_state": _actor_animation(enemy),
		})
	rpc("receive_actor_snapshot", players, enemies)


@rpc("authority", "call_remote", "unreliable_ordered")
func receive_actor_snapshot(players: Array, enemies: Array) -> void:
	if not is_client:
		return
	for state in players:
		if not (state is Dictionary):
			continue
		var slot: int = int(state.get("slot", -1))
		if slot < 0:
			continue
		for body in get_tree().get_nodes_in_group("player"):
			if not (body is CharacterBody2D) or int(body.get("slot")) != slot:
				continue
			body.global_position = state.get("position", body.global_position)
			body.velocity = state.get("velocity", Vector2.ZERO)
			body.health = state.get("health", body.health)
			body.max_health = state.get("max_health", body.max_health)
			body.is_dead = state.get("is_dead", false)
			body.katana_drawn = state.get("katana_drawn", false)
			body.stealthed = state.get("stealthed", false)
			body.crouched = state.get("crouched", false)
			if "stamina" in body:
				body.stamina = state.get("stamina", body.stamina)
				body.max_stamina = state.get("max_stamina", body.max_stamina)
			var scrolls: Variant = state.get("scrolls", [])
			if scrolls is Array and scrolls.size() == 3 and body.get("scrolls") != null:
				body.scrolls.kinds = scrolls[0]
				body.scrolls.counts = scrolls[1]
				body.scrolls.selected = int(scrolls[2])
			if "facing_dir" in body:
				body.facing_dir = state.get("facing", body.facing_dir)
			_apply_actor_state(body, String(state.get("state", "")))
			_apply_actor_animation(body, state.get("animation_state", {}))
			break
	for state in enemies:
		if not (state is Dictionary):
			continue
		var network_id: int = int(state.get("id", -1))
		for enemy in get_tree().get_nodes_in_group("enemy"):
			if not ("network_id" in enemy) or int(enemy.get("network_id")) != network_id:
				continue
			enemy.global_position = state.get("position", enemy.global_position)
			enemy.velocity = state.get("velocity", Vector2.ZERO)
			enemy.health = state.get("health", enemy.health)
			if enemy.has_method("_refresh_health_bar"):
				enemy.call("_refresh_health_bar")
			var dead: bool = state.get("is_dead", false)
			if dead and not enemy.is_dead and enemy.has_method("network_death"):
				enemy.call("network_death")
			enemy.is_dead = dead
			if "facing_dir" in enemy:
				enemy.facing_dir = state.get("facing", enemy.facing_dir)
			_apply_actor_state(enemy, String(state.get("state", "")))
			_apply_actor_animation(enemy, state.get("animation_state", {}))
			break


func _apply_actor_state(body: Node, state_name: String) -> void:
	if state_name.is_empty():
		return
	var machine := body.get_node_or_null("FiniteStateMachine") as FiniteStateMachine
	if machine == null or (machine.current_state != null
			and machine.current_state.name == state_name):
		return
	if machine.has_node(state_name):
		machine.change_state(state_name)


func _apply_actor_animation(body: Node, animation_state: Variant) -> void:
	if not (animation_state is Dictionary) or animation_state.is_empty():
		return
	var sprite := body.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	if sprite == null:
		sprite = body.get_node_or_null("AnimationManager/AnimatedSprite2D") as AnimatedSprite2D
	if sprite == null or sprite.sprite_frames == null:
		return
	var animation := StringName(animation_state.get("animation", ""))
	if animation.is_empty() or not sprite.sprite_frames.has_animation(animation):
		return
	if sprite.animation != animation:
		sprite.animation = animation
	sprite.speed_scale = float(animation_state.get("speed_scale", 1.0))
	sprite.flip_h = bool(animation_state.get("flip_h", false))
	var last_frame := maxi(0, sprite.sprite_frames.get_frame_count(animation) - 1)
	var frame := clampi(int(animation_state.get("frame", 0)), 0, last_frame)
	var progress := clampf(float(animation_state.get("frame_progress", 0.0)), 0.0, 1.0)
	sprite.set_frame_and_progress(frame, progress)
	if bool(animation_state.get("playing", false)):
		if not sprite.is_playing():
			sprite.play()
	elif sprite.is_playing():
		sprite.pause()
