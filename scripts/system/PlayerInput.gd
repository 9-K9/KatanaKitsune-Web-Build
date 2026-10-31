class_name PlayerInput
extends RefCounted

## One player's controls, bound to one device.
##
## The whole reason this exists: `Input.is_action_pressed("Attack")` is true if
## *any* device pressed Attack. With four pads plugged in, every player would
## drive every character. Godot has no per-device action query, so this reads
## raw device state instead — `Input.is_joy_button_pressed(device, button)` for
## pads, `Input.is_key_pressed(key)` for the keyboard.
##
## The bindings are not hardcoded here. They come from ControlSettings, which
## reads project.godot's InputMap for the defaults and keeps one editable copy
## per player slot, so each player can have their own keys. An input with no
## slot (a join probe, a test) learns the defaults straight from the InputMap.
##
## `device` is a joypad index, or KEYBOARD for the player on the keys.

const KEYBOARD: int = -1
const BOT: int = -2
## A slot filled by a remote player over the network rather than local
## hardware or AI. See NetworkInput and NETWORKING.md.
const NETWORK: int = -3

## Below this an axis is treated as centred. Sticks rest a little off zero, and
## without it a resting pad walks the character into a wall forever.
const DEADZONE: float = 0.35

var device: int = KEYBOARD
## The roster slot whose control profile this reads, or -1 for the defaults.
var slot: int = -1
## ControlSettings.version these bindings were learnt from; a mismatch means
## the player saved new controls and this should relearn.
var _learnt_version: int = -1

## action -> what to look at on this device, gathered once from the InputMap.
var _keys: Dictionary = {}		## action -> Array[int] of physical keycodes
var _buttons: Dictionary = {}	## action -> Array[int] of JoyButton
var _axes: Dictionary = {}		## action -> Array of [axis, sign]

## This frame's and last frame's state, so just_pressed can be an edge rather
## than a level. Godot tracks this for actions; it cannot for a raw device read.
##
## Rolled over on demand rather than by an explicit poll() from the character.
## A poll call would have to happen after every state had read the input, and
## states are children of the character — Godot ticks parents first, so the
## character would clear last frame's record before anyone had compared against
## it and no press would ever register as an edge.
var _now: Dictionary = {}
var _was: Dictionary = {}
var _frame: int = -1
var _held_until_release: Dictionary = {}
var _bound_body: WeakRef


func _init(for_device: int = KEYBOARD, for_slot: int = -1) -> void:
	device = for_device
	slot = for_slot
	relearn()


func bind_body(body: CharacterBody2D) -> void:
	_bound_body = weakref(body)


func _gameplay_active() -> bool:
	if _bound_body == null:
		return true
	var body := _bound_body.get_ref() as CharacterBody2D
	if not is_instance_valid(body) or body.get("is_dead") == true:
		return false
	var world := body.get_parent()
	return world != null and (not world.has_method("bot_controls_active") \
			or world.bot_controls_active())


func update(_delta: float) -> void:
	pass


func reset() -> void:
	prime()


func aim_vector() -> Vector2:
	return Vector2.ZERO


## Learns (or re-learns) this player's bindings. A slot takes its profile from
## ControlSettings; anything else reads the defaults out of the InputMap.
func relearn() -> void:
	_keys = {}
	_buttons = {}
	_axes = {}
	var settings := _settings()
	if settings != null:
		_learnt_version = settings.version
		_learn_from(settings.bindings_for(slot))
	else:
		_learn_bindings()


## The ControlSettings autoload, or null when this is a slotless input or the
## script is running somewhere the autoload does not exist (a headless check).
func _settings() -> Node:
	if slot < 0:
		return null
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return null
	return loop.root.get_node_or_null("ControlSettings")


func _learn_from(bindings: Dictionary) -> void:
	for name in bindings:
		var entry: Dictionary = bindings[name]
		var keys: Array[int] = []
		for code in entry.get("keys", []):
			keys.append(int(code))
		var buttons: Array[int] = []
		for idx in entry.get("buttons", []):
			buttons.append(int(idx))
		var axes: Array = []
		for pair in entry.get("axes", []):
			axes.append([int(pair[0]), float(pair[1])])
		if not keys.is_empty():
			_keys[name] = keys
		if not buttons.is_empty():
			_buttons[name] = buttons
		if not axes.is_empty():
			_axes[name] = axes


## Reads every action's events out of the InputMap and files them by the kind of
## hardware they came from. Actions that start "ui_" are skipped: menus use
## Godot's own handling and should keep answering to any device.
func _learn_bindings() -> void:
	for action in InputMap.get_actions():
		var name := String(action)
		if name.begins_with("ui_") or name.begins_with("dialogic"):
			continue
		var keys: Array[int] = []
		var buttons: Array[int] = []
		var axes: Array = []
		for event in InputMap.action_get_events(action):
			if event is InputEventKey:
				var code: int = (event as InputEventKey).physical_keycode
				if code == 0:
					code = (event as InputEventKey).keycode
				keys.append(code)
			elif event is InputEventJoypadButton:
				buttons.append((event as InputEventJoypadButton).button_index)
			elif event is InputEventJoypadMotion:
				var motion := event as InputEventJoypadMotion
				axes.append([motion.axis, signf(motion.axis_value)])
		if not keys.is_empty():
			_keys[name] = keys
		if not buttons.is_empty():
			_buttons[name] = buttons
		if not axes.is_empty():
			_axes[name] = axes


## Brings this frame's snapshot up to date, once per rendered frame however
## many times it is asked. Every action is sampled together rather than lazily,
## so an action queried for the first time mid-press does not read as a fresh
## edge.
func _sync() -> void:
	var frame: int = Engine.get_process_frames()
	if frame == _frame:
		return
	_frame = frame
	## Saved controls reach a live player here, the next frame after saving.
	if _learnt_version >= 0:
		var settings := _settings()
		if settings != null and settings.version != _learnt_version:
			relearn()
	_was = _now
	_now = {}
	for action in _every_action():
		var held: bool = _read(action)
		if _held_until_release.has(action):
			if not held:
				_held_until_release.erase(action)
			held = false
		_now[action] = held
	for menu in ["__confirm", "__cancel"]:
		_now[menu] = _read_menu(menu)


## Treats everything currently held as already-held, so a button still down from
## whatever created this object does not read as a fresh press.
##
## Without it, claiming a pad with Confirm immediately confirms the next screen
## too: the new object's record of "last frame" is empty, so the held button
## looks like an edge and the player never gets to choose anything.
func prime() -> void:
	_sync()
	_was = _now.duplicate()


## Handoffs should not continue a held attack or spend a second body's scroll.
## Movement remains responsive; these actions become available on release.
func suppress_held_actions() -> void:
	_sync()
	for action in _now:
		if not _now[action]:
			continue
		if action in ["Attack", "Defend", "Katana", "Stealth", "Dodge", "Jump"] \
				or action == "RescueAI" \
				or String(action).begins_with("Scroll"):
			_held_until_release[action] = true
			_now[action] = false
			_was[action] = false


## Is this player holding `action` right now.
func pressed(action: String) -> bool:
	_sync()
	return _gameplay_active() and _now.get(action, false)


## The live hardware read, before any frame bookkeeping.
func _read(action: String) -> bool:
	if device == BOT or device == NETWORK:
		return false
	if device == KEYBOARD:
		for code in _keys.get(action, []):
			if Input.is_key_pressed(code):
				return true
		return false
	for button in _buttons.get(action, []):
		if Input.is_joy_button_pressed(device, button):
			return true
	for pair in _axes.get(action, []):
		var value: float = Input.get_joy_axis(device, pair[0])
		## Compared with the sign the binding was made for, so the left half of
		## an axis does not also fire the action bound to its right half.
		if absf(value) >= DEADZONE and signf(value) == pair[1]:
			return true
	return false


## Did this player press `action` this frame.
func just_pressed(action: String) -> bool:
	_sync()
	return _gameplay_active() and _now.get(action, false) and not _was.get(action, false)


func just_released(action: String) -> bool:
	_sync()
	return _gameplay_active() and not _now.get(action, false) and _was.get(action, false)


func _every_action() -> Array:
	var names := {}
	for d in [_keys, _buttons, _axes]:
		for key in d:
			names[key] = true
	return names.keys()


## The movement stick or keys, as a direction. Mirrors Input.get_vector, which
## is likewise device-blind.
func vector() -> Vector2:
	var move := Vector2(
		(1.0 if pressed("Right") else 0.0) - (1.0 if pressed("Left") else 0.0),
		(1.0 if pressed("Down") else 0.0) - (1.0 if pressed("Up") else 0.0))
	return move.normalized() if move != Vector2.ZERO else Vector2.ZERO




## Menu confirm and cancel, per device.
##
## Spelled out here rather than taken from ui_accept/ui_cancel because those are
## deliberately device-blind — menus should answer to any pad — but the party
## select has to know *which* player pressed. Face buttons 0 and 1 are A/B on an
## Xbox pad, Cross/Circle on a PlayStation one, and B/A on a Switch pad, which
## is the mapping already agreed for this game.
const CONFIRM_BUTTON: int = JOY_BUTTON_A
const CANCEL_BUTTON: int = JOY_BUTTON_B


## Nintendo pads swap these two relative to everyone else.
##
## The agreed rule is positional — the BOTTOM face button confirms on every pad,
## which is A on an Xbox pad, Cross on a PlayStation one and B on a Switch one.
## Xbox and PlayStation pads report that bottom button as JOY_BUTTON_A, but
## Nintendo pads report by Nintendo's own labels, where A is the right-hand
## button. Taking JOY_BUTTON_A at face value therefore lands on the wrong
## physical button for exactly one brand.
func _nintendo() -> bool:
	if device == KEYBOARD:
		return false
	var name := Input.get_joy_name(device).to_lower()
	return name.contains("nintendo") or name.contains("switch") \
			or name.contains("joy-con") or name.contains("pro controller")


func _confirm_button() -> int:
	return CANCEL_BUTTON if _nintendo() else CONFIRM_BUTTON


func _cancel_button() -> int:
	return CONFIRM_BUTTON if _nintendo() else CANCEL_BUTTON


func confirm_pressed() -> bool:
	_sync()
	return _edge("__confirm")


func cancel_pressed() -> bool:
	_sync()
	return _edge("__cancel")


## Raw menu-button state, kept in the same per-frame snapshot as the actions so
## these are edges too and a held button does not scroll the whole list.
func _read_menu(which: String) -> bool:
	if device == BOT or device == NETWORK:
		return false
	if device == KEYBOARD:
		if which == "__confirm":
			return Input.is_key_pressed(KEY_ENTER) or Input.is_key_pressed(KEY_SPACE) \
					or Input.is_key_pressed(KEY_KP_ENTER)
		return Input.is_key_pressed(KEY_ESCAPE) or Input.is_key_pressed(KEY_BACKSPACE)
	return Input.is_joy_button_pressed(device,
			_confirm_button() if which == "__confirm" else _cancel_button())


func _edge(which: String) -> bool:
	return _now.get(which, false) and not _was.get(which, false)


## A human-readable name for the pad, so the select screen can say which is
## which. Keyboard is not a joypad and has no name of its own.
func device_name() -> String:
	if device == KEYBOARD:
		return "KEYBOARD"
	if device == NETWORK:
		return "NETWORK"
	var raw := Input.get_joy_name(device)
	return raw.to_upper() if raw != "" else "GAMEPAD %d" % (device + 1)


## What the player actually has to press to confirm, printed rather than
## assumed — "press a button" told nobody which one, and a bare face-button
## letter is the wrong one for two brands out of three. Mirrors
## _confirm_button()'s own bottom-face-button rule, so the label can never
## disagree with what the game is actually listening for.
func confirm_button_label() -> String:
	if device == KEYBOARD:
		return "SPACE"
	if _nintendo():
		return "B"
	if _is_playstation():
		return "X"
	return "A"


func _is_playstation() -> bool:
	var name := Input.get_joy_name(device).to_lower()
	return name.contains("sony") or name.contains("playstation") \
			or name.contains("dualshock") or name.contains("dualsense") \
			or name.contains("ps3") or name.contains("ps4") or name.contains("ps5")
