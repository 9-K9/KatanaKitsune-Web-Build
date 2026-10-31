extends Control

## The online co-op lobby. Type (or keep) the room address, join, pick an
## aspect, and the room leader — whoever arrived first — picks the area and
## starts. Everything shown here comes back from the server's lobby snapshot,
## so every player in the room sees the same seats.

const TITLE := "res://scenes/title_screen.tscn"
const DEFAULT_ROOM := "209-97-138-84.sslip.io:443"
const GOLD := Color(0.94, 0.78, 0.45, 1)
const DIM := Color(0.62, 0.56, 0.48, 1)

var _code: LineEdit
var _status: Label
var _device_label: Label
var _join_box: VBoxContainer
var _room_box: VBoxContainer
var _seats: VBoxContainer
var _aspect_button: Button
var _area_button: Button
var _start_button: Button
var _joining: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().paused = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()
	NetworkManager.joined_server.connect(_on_joined)
	NetworkManager.join_failed.connect(_on_join_failed)
	NetworkManager.server_lost.connect(_on_server_lost)
	NetworkManager.lobby_updated.connect(_on_lobby_updated)
	NetworkManager.match_ended.connect(_on_match_ended)
	_show_join()


func _exit_tree() -> void:
	for sig in [NetworkManager.joined_server, NetworkManager.join_failed,
			NetworkManager.server_lost, NetworkManager.lobby_updated,
			NetworkManager.match_ended]:
		for connection in sig.get_connections():
			if connection["callable"].get_object() == self:
				sig.disconnect(connection["callable"])


## Whoever presses a pad button first drives this machine's character.
func _input(event: InputEvent) -> void:
	if event is InputEventJoypadButton and event.pressed:
		if NetworkManager.client_device != event.device:
			NetworkManager.set_client_device(event.device)
			_refresh_device()
	elif event is InputEventKey and event.pressed and not _code.has_focus():
		if NetworkManager.client_device != PlayerInput.KEYBOARD:
			NetworkManager.set_client_device(PlayerInput.KEYBOARD)
			_refresh_device()


func _build() -> void:
	var shade := ColorRect.new()
	shade.color = Color(0.05, 0.02, 0.03, 1)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(shade)

	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(centre)
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(420, 0)
	column.add_theme_constant_override("separation", 10)
	centre.add_child(column)

	column.add_child(_label("ONLINE CO-OP", 22, GOLD))
	_status = _label("", 13, DIM)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)

	_join_box = VBoxContainer.new()
	_join_box.add_theme_constant_override("separation", 8)
	column.add_child(_join_box)
	_join_box.add_child(_label("ROOM ADDRESS", 12, DIM))
	_code = LineEdit.new()
	_code.text = _room_from_web_url()
	_code.custom_minimum_size = Vector2(0, 34)
	_code.text_submitted.connect(func(_t): _on_join_pressed())
	_join_box.add_child(_code)
	_join_box.add_child(_button("◆   JOIN ROOM   ◆", _on_join_pressed))

	_room_box = VBoxContainer.new()
	_room_box.add_theme_constant_override("separation", 8)
	column.add_child(_room_box)
	_room_box.add_child(_label("PARTY", 12, DIM))
	_seats = VBoxContainer.new()
	_room_box.add_child(_seats)
	_aspect_button = _button("", _on_aspect_pressed)
	_room_box.add_child(_aspect_button)
	_area_button = _button("", _on_area_pressed)
	_room_box.add_child(_area_button)
	_start_button = _button("◆   START   ◆", _on_start_pressed)
	_room_box.add_child(_start_button)

	_device_label = _label("", 11, DIM)
	column.add_child(_device_label)
	column.add_child(_button("◆   BACK   ◆", _on_back_pressed))
	_refresh_device()


func _room_from_web_url() -> String:
	if not OS.has_feature("web"):
		return DEFAULT_ROOM
	var href: String = str(JavaScriptBridge.eval("window.location.href"))
	var marker := "?room="
	var start := href.find(marker)
	if start < 0:
		return DEFAULT_ROOM
	var encoded := href.substr(start + marker.length()).get_slice("&", 0)
	var room := encoded.uri_decode().strip_edges()
	return room if not room.is_empty() else DEFAULT_ROOM


func _label(text: String, size: int, colour: Color) -> Label:
	var label := Label.new()
	label.text = tr(text)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", colour)
	return label


func _button(text: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = tr(text)
	button.custom_minimum_size = Vector2(310, 38)
	button.add_theme_font_size_override("font_size", 16)
	button.add_theme_color_override("font_color", GOLD)
	button.pressed.connect(handler)
	return button


func _show_join() -> void:
	_join_box.visible = true
	_room_box.visible = false
	TitleScreen.focus_first_button(_join_box)


func _show_room() -> void:
	_join_box.visible = false
	_room_box.visible = true
	_refresh_room()


func _refresh_device() -> void:
	var device: int = NetworkManager.client_device
	var name: String = "KEYBOARD" if device == PlayerInput.KEYBOARD \
			else "PAD %d" % (device + 1)
	_device_label.text = tr("PLAYING WITH: %s   •   PRESS A BUTTON ON ANOTHER DEVICE TO SWITCH") % name


func _refresh_room() -> void:
	for child in _seats.get_children():
		child.queue_free()
	var own: int = NetworkManager.own_slot()
	var leader: bool = NetworkManager.is_room_leader()
	for slot in Roster.count():
		var scheme: int = Roster.players[slot].get("scheme", -1)
		var aspect: String = PowerState.info(scheme)["name"] if scheme >= 0 else "—"
		var tags := ""
		if slot == own:
			tags += "  (YOU)"
		if slot == 0:
			tags += "  (LEADER)"
		_seats.add_child(_label("PLAYER %d   %s%s" % [slot + 1, aspect, tags], 14,
				GOLD if slot == own else DIM))
	for slot in range(Roster.count(), Roster.MAX_PLAYERS):
		_seats.add_child(_label("PLAYER %d   waiting…" % (slot + 1), 14, DIM))
	var own_scheme: int = Roster.players[own].get("scheme", -1) if own >= 0 else -1
	_aspect_button.text = "<   ASPECT: %s   >" % (
			PowerState.info(own_scheme)["name"] if own_scheme >= 0 else "—")
	_area_button.text = "<   AREA: %s   >" % LevelTheme.NAMES[
			clampi(NetworkManager.lobby_theme(), 0, LevelTheme.NAMES.size() - 1)].to_upper()
	_area_button.disabled = not leader
	_start_button.disabled = not leader
	_status.text = tr("YOU LEAD THE ROOM. PRESS START WHEN EVERYONE IS IN.") if leader \
			else tr("WAITING FOR THE ROOM LEADER TO START…")
	if get_viewport().gui_get_focus_owner() == null:
		TitleScreen.focus_first_button(_room_box)


func _on_join_pressed() -> void:
	if _joining:
		return
	var code: String = _code.text.strip_edges()
	if code.is_empty():
		_status.text = tr("TYPE THE ROOM ADDRESS FIRST.")
		return
	_joining = true
	_status.text = tr("CONNECTING TO %s…") % code
	var err: Error = NetworkManager.join_room_code(code)
	if err != OK:
		_joining = false
		_status.text = tr("COULD NOT CONNECT (%s).") % error_string(err)


func _on_joined() -> void:
	AudioManager.play("ui_online_joined")
	_joining = false
	_status.text = tr("CONNECTED. WAITING FOR THE ROOM…")


func _on_join_failed(reason: String) -> void:
	AudioManager.play("ui_online_failed")
	_joining = false
	_status.text = tr("COULD NOT REACH THE SERVER (%s). CHECK THE ADDRESS AND TRY AGAIN.") % reason
	_show_join()


func _on_server_lost() -> void:
	AudioManager.play("ui_online_server_lost")
	_joining = false
	NetworkManager.stop()
	_status.text = tr("LOST THE SERVER. TRY JOINING AGAIN.")
	_show_join()


func _on_match_ended(_reason: String) -> void:
	_on_server_lost()


func _on_lobby_updated(_count: int, _leader: bool) -> void:
	if not _room_box.visible:
		_show_room()
	else:
		_refresh_room()


## Next aspect nobody else in the room has taken.
func _on_aspect_pressed() -> void:
	AudioManager.play("ui_aspect_cycle")
	var own: int = NetworkManager.own_slot()
	if own < 0:
		return
	var current: int = Roster.players[own].get("scheme", -1)
	for step in range(1, PowerState.count() + 1):
		var candidate: int = (current + step) % PowerState.count()
		if not Roster.scheme_taken(candidate, own):
			NetworkManager.choose_scheme(candidate)
			return


func _on_area_pressed() -> void:
	AudioManager.play("ui_area_cycle")
	NetworkManager.choose_theme((NetworkManager.lobby_theme() + 1) % LevelTheme.NAMES.size())


func _on_start_pressed() -> void:
	AudioManager.play("ui_online_match_start")
	_status.text = tr("STARTING…")
	NetworkManager.start_room()


func _on_back_pressed() -> void:
	NetworkManager.stop()
	get_tree().change_scene_to_file(TITLE)
