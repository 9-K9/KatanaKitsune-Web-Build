extends CanvasLayer
var game_paused : bool = false
## get_parent() rather than an absolute "/root/Main" path, so this keeps working
## if the map root is renamed or the scene is run on its own.
@onready var gameManager = get_parent()
@onready var main_menu: VBoxContainer = $Center/Panel/Margin/MainMenu
@onready var cheats_menu: VBoxContainer = $Center/Panel/Margin/CheatsMenu
@onready var settings_menu: VBoxContainer = $Center/Panel/Margin/SettingsMenu
@onready var teammates_menu: VBoxContainer = $Center/Panel/Margin/TeammatesMenu
@onready var teammate_rows: VBoxContainer = $Center/Panel/Margin/TeammatesMenu/Rows
@onready var teammate_hint: Label = $Center/Panel/Margin/TeammatesMenu/Hint
@onready var teammates_button: Button = $Center/Panel/Margin/MainMenu/Teammates
@onready var immortality_toggle: CheckButton = $Center/Panel/Margin/CheatsMenu/Immortality

## Whoever pressed Pause owns the menu: only their device drives it, through
## every sub-menu, until they resume. After TAKEOVER_IDLE seconds without a
## press from them, any other player's press takes the menu over instead, so a
## pauser who walked away cannot hold the whole party hostage.
const TAKEOVER_IDLE: float = 5.0
const NO_OWNER: int = -1
## [slot, PlayerInput] per local human, polled for the Pause edge per device —
## Input.is_action_just_pressed cannot say *who* pressed.
var _pausers: Array = []
var _owner_slot: int = NO_OWNER
var _owner_device: int = PlayerInput.BOT
var _idle: float = 0.0
## The frame a takeover happened on, so the press that took the menu is not
## also read as that player's Pause and resumes the game in the same breath.
var _took_over_frame: int = -1
var _owner_label: Label

func _ready():
	## The tree is paused while this menu is up, so it has to keep processing
	## or its own buttons would be dead.
	process_mode = Node.PROCESS_MODE_ALWAYS
	## The same cover the title screen shows, so pausing frames the character
	## rather than a flat wash over the level.
	var art := get_node_or_null("Cover")
	if art != null:
		art.texture = load(PowerState.cover_path())
	## Cheats are a development aid; a release export never shows them, unless
	## Karmageisha has been woken, in which case her immortality is yours to
	## toggle here.
	if not CheatManager.cheats_visible():
		var cheats := main_menu.get_node_or_null("Cheats") as Control
		if cheats != null:
			cheats.queue_free()
		CheatManager.set_immortality(false)
	_owner_label = Label.new()
	_owner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_owner_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_owner_label.add_theme_font_size_override("font_size", 11)
	main_menu.add_child(_owner_label)
	main_menu.move_child(_owner_label, 0)
	if settings_menu is SettingsPanel and (settings_menu as SettingsPanel).controls != null:
		(settings_menu as SettingsPanel).controls.input_filter = _event_allowed
	Roster.roster_changed.connect(_rebuild_pausers)
	_rebuild_pausers()
	_show_main_menu()
	_sync_immortality_label()

func _process(delta: float):
	## Owns the pause toggle either way, because this node keeps processing while
	## the tree is frozen; GameManager stops dead the instant the pause takes
	## effect, so it could never un-pause the game itself.
	if visible:
		_idle += delta
		_sync_owner_label()
	if _has_manager():
		_process_with_manager()
	else:
		_process_standalone()


## Maps built around GameManager route pause through its state machine, so
## game_over stays excluded and the key cannot be used to un-die.
func _process_with_manager() -> void:
	var state: String = gameManager.getState()
	if state != "game_over":
		var who := _pause_pressed()
		if who != NO_OWNER and _may_toggle(who):
			gameManager.setState("game_play" if state == "game_paused" else "game_paused")
			state = gameManager.getState()
			_owner_changed(who if state == "game_paused" else NO_OWNER)
	_set_shown(state == "game_paused")


## The maze's root is its generator, not a GameManager, so there is no state
## machine to ask — the menu pauses the tree itself. Without this the key did
## nothing at all on the level the game actually starts on.
func _process_standalone() -> void:
	## Death has its own screen, and it pauses the tree to show it. Without this
	## the pause menu reads that pause as its own, opens behind the Game Over
	## panel and takes the focus off CONTINUE — two menus up at once, neither
	## driveable.
	if _player_dead():
		_set_shown(false)
		return
	## A pad pulled out also pauses the tree, to say whose. Same trap as death:
	## without this the menu reads that pause as its own and opens behind the
	## reconnect notice, so two things are up at once and the player whose
	## controller is missing is the one being asked to drive the menu.
	if Roster.any_lost():
		_set_shown(false)
		return
	## Floor upgrades pause the tree too, and own it until every player is ready.
	if get_tree().get_first_node_in_group("level_up_screen") != null:
		_set_shown(false)
		return
	var who := _pause_pressed()
	if who != NO_OWNER and _may_toggle(who):
		if NetworkManager.is_client:
			# The server keeps the match running when one player opens a menu.
			# Freezing this client's SceneTree would stop cameras, interpolation,
			# weather and remote actors while the authoritative world moved on.
			game_paused = not game_paused
			_owner_changed(who if game_paused else NO_OWNER)
		else:
			get_tree().paused = not get_tree().paused
			game_paused = get_tree().paused
			_owner_changed(who if game_paused else NO_OWNER)
	_set_shown(game_paused if NetworkManager.is_client else get_tree().paused)


## ------------------------------------------------------------ ownership

## One PlayerInput per local human so the Pause edge can be read per device.
## With no roster (a level run straight from the editor) the keyboard and every
## pad count, so pause still works there.
func _rebuild_pausers() -> void:
	_pausers.clear()
	for slot in Roster.count():
		if Roster.is_bot(slot) or Roster.is_network(slot):
			continue
		var input := PlayerInput.new(Roster.device_of(slot), slot)
		input.prime()
		_pausers.append([slot, input])
	if _pausers.is_empty():
		_pausers.append([0, PlayerInput.new(PlayerInput.KEYBOARD)])
		for id in Input.get_connected_joypads():
			_pausers.append([_pausers.size(), PlayerInput.new(id)])
	if _owner_slot != NO_OWNER and _slot_device(_owner_slot) != _owner_device:
		_owner_changed(NO_OWNER)


## The slot whose Pause was pressed this frame, or NO_OWNER.
func _pause_pressed() -> int:
	for pair in _pausers:
		if (pair[1] as PlayerInput).just_pressed("Pause"):
			return pair[0]
	return NO_OWNER


## Opening is anyone's; closing belongs to the owner, or to anyone once the
## owner has gone quiet.
func _may_toggle(slot: int) -> bool:
	if not visible or _owner_slot == NO_OWNER:
		return true
	if Engine.get_process_frames() == _took_over_frame:
		return false
	return slot == _owner_slot or _idle >= TAKEOVER_IDLE


func _owner_changed(slot: int) -> void:
	_owner_slot = slot
	_owner_device = _slot_device(slot) if slot != NO_OWNER else PlayerInput.BOT
	_idle = 0.0
	_sync_owner_label()


func _slot_device(slot: int) -> int:
	for pair in _pausers:
		if pair[0] == slot:
			return (pair[1] as PlayerInput).device
	return PlayerInput.BOT


func _sync_owner_label() -> void:
	if _owner_label == null:
		return
	if _owner_slot == NO_OWNER:
		_owner_label.text = ""
		return
	var name := "P%d" % (_owner_slot + 1) if Roster.count() > 0 \
			else _slot_input(_owner_slot).device_name()
	_owner_label.modulate = Roster.colour_of(_owner_slot)
	_owner_label.text = tr("%s PAUSED") % name if _idle < TAKEOVER_IDLE \
			else tr("%s PAUSED — IDLE, ANY PLAYER MAY TAKE OVER") % name


func _slot_input(slot: int) -> PlayerInput:
	for pair in _pausers:
		if pair[0] == slot:
			return pair[1]
	return PlayerInput.new()


## Keyboard and mouse are one player's; a pad event names its own device.
func _event_device(event: InputEvent) -> int:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		return (event as InputEvent).device
	return PlayerInput.KEYBOARD


func _event_allowed(event: InputEvent) -> bool:
	return _owner_slot == NO_OWNER or _event_device(event) == _owner_device


## A deliberate press, as opposed to a release, a key repeat or a stick drift.
func _is_press(event: InputEvent) -> bool:
	if event is InputEventKey:
		var key := event as InputEventKey
		return key.pressed and not key.echo
	if event is InputEventJoypadButton:
		return (event as InputEventJoypadButton).pressed
	if event is InputEventMouseButton:
		return (event as InputEventMouseButton).pressed
	if event is InputEventJoypadMotion:
		return absf((event as InputEventJoypadMotion).axis_value) >= PlayerInput.DEADZONE
	return false


## Everything that is not the owner's is stopped here before Godot's UI sees
## it. Mouse motion is let through so hovering still works for the owner and
## stays harmless for anyone else.
func _input(event: InputEvent) -> void:
	if not visible or _owner_slot == NO_OWNER or event is InputEventMouseMotion:
		return
	if _event_allowed(event):
		if _is_press(event):
			_idle = 0.0
		return
	if _idle >= TAKEOVER_IDLE and _is_press(event):
		var device := _event_device(event)
		for pair in _pausers:
			if (pair[1] as PlayerInput).device == device:
				_owner_changed(pair[0])
				_took_over_frame = Engine.get_process_frames()
				break
	get_viewport().set_input_as_handled()


func _player_dead() -> bool:
	for node in get_tree().get_nodes_in_group("player"):
		if node is CharacterBody2D and "is_dead" in node and node.is_dead:
			return true
	return false


func _has_manager() -> bool:
	return is_instance_valid(gameManager) and gameManager.has_method("getState")


func _set_shown(should_show: bool) -> void:
	if should_show == visible:
		return
	visible = should_show
	if not should_show:
		_owner_changed(NO_OWNER)
	## Focus has to be taken when the menu appears, not when it is built. The
	## grab in _ready ran while this was still hidden, and a grab on a hidden
	## tree does not stick — so a pad opened onto nothing.
	if should_show:
		_show_main_menu()

func _on_resume_pressed():
	if _has_manager():
		gameManager.setState("game_play")
	elif NetworkManager.is_client:
		game_paused = false
	else:
		get_tree().paused = false
	_owner_changed(NO_OWNER)
	_set_shown(false)
	_show_main_menu()

func _on_cheats_pressed() -> void:
	main_menu.visible = false
	cheats_menu.visible = true
	TitleScreen.focus_first_button(cheats_menu)
	immortality_toggle.button_pressed = CheatManager.immortality_enabled
	_sync_immortality_label()

func _on_immortality_toggled(enabled: bool) -> void:
	CheatManager.set_immortality(enabled)
	_sync_immortality_label()

func _on_cheats_back_pressed() -> void:
	_show_main_menu()

func _on_settings_pressed() -> void:
	main_menu.visible = false
	settings_menu.visible = true
	TitleScreen.focus_first_button(settings_menu)

func _on_settings_back_pressed() -> void:
	_show_main_menu()

## One button per AI teammate; pressing it steps that bot to the next mode.
## Built on open rather than in the scene because the party size is not known
## until the run starts.
func _on_teammates_pressed() -> void:
	main_menu.visible = false
	teammates_menu.visible = true
	_build_teammate_rows()
	TitleScreen.focus_first_button(teammates_menu)

func _on_teammates_back_pressed() -> void:
	_show_main_menu()

func _build_teammate_rows() -> void:
	for child in teammate_rows.get_children():
		teammate_rows.remove_child(child)
		child.queue_free()
	for slot in Roster.count():
		if not Roster.is_bot(slot):
			continue
		var button := Button.new()
		button.add_theme_font_size_override("font_size", 12)
		button.pressed.connect(_on_teammate_row_pressed.bind(slot, button))
		button.focus_entered.connect(_show_mode_hint.bind(slot))
		teammate_rows.add_child(button)
		_label_teammate_row(slot, button)

func _on_teammate_row_pressed(slot: int, button: Button) -> void:
	Roster.cycle_mode(slot)
	_label_teammate_row(slot, button)
	_show_mode_hint(slot)

func _label_teammate_row(slot: int, button: Button) -> void:
	button.text = "%s: %s" % [Roster.label_of(slot), Roster.BOT_MODE_NAMES[Roster.mode_of(slot)]]

func _show_mode_hint(slot: int) -> void:
	teammate_hint.text = Roster.BOT_MODE_HINTS[Roster.mode_of(slot)]

func _has_bots() -> bool:
	for slot in Roster.count():
		if Roster.is_bot(slot):
			return true
	return false

func _show_main_menu() -> void:
	main_menu.visible = true
	cheats_menu.visible = false
	settings_menu.visible = false
	teammates_menu.visible = false
	teammates_button.visible = _has_bots()
	## Focus follows whichever list is showing, so a pad can drive both.
	TitleScreen.focus_first_button(main_menu)

func _sync_immortality_label() -> void:
	immortality_toggle.text = tr("IMMORTALITY IS ON") if CheatManager.immortality_enabled else tr("IMMORTALITY IS OFF")

func _on_quit_pressed():
	## Leaving the map has to lift the pause too, or the title screen loads
	## into a frozen tree.
	get_tree().paused = false
	game_paused = false
	NetworkManager.stop()
	if _has_manager():
		gameManager.setState("game_title")
	else:
		get_tree().change_scene_to_file("res://scenes/title_screen.tscn")
