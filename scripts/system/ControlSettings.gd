extends Node

## Per-player control profiles and device assignments, saved to disk.
##
## project.godot's InputMap stays the single source of *defaults*; this reads
## them once at startup and keeps one editable copy per player slot. PlayerInput
## reads its bindings from here rather than from the InputMap, so each player
## can have their own keys without touching Godot's device-blind action system
## (menus built on ui_* keep answering to everyone, as before).
##
## A slot may also be tied to a device — "P1 is the keyboard, P2 is pad 1" —
## which the select screen honours when the party is finalised.
##
## Edits are staged: set_binding / assign_device change the working copy, and
## nothing reaches disk or live players until save(). revert() throws the
## staged edits away. `version` ticks on every save so PlayerInput can notice
## and relearn without holding a signal connection on a RefCounted.

signal changed

const SAVE_PATH := "user://controls.cfg"
const UNASSIGNED: int = -99

## The actions a player can rebind, in the order the Controls page lists them.
## Menu* and ui_* are deliberately absent: menus must keep answering to every
## device or a bad rebind could lock a player out of the menu that fixes it.
const REBINDABLE: PackedStringArray = [
	"Up", "Down", "Left", "Right",
	"Attack", "Katana", "Defend", "Dodge", "Action", "Jump", "Run", "Stealth",
	"RescueAI",
	"ScrollUse", "ScrollPrevious", "ScrollNext",
	"Scroll1", "Scroll2", "Scroll3", "Scroll4", "Scroll5", "Scroll6",
	"Pause",
]

const LABELS := {
	"Up": "MOVE UP", "Down": "MOVE DOWN", "Left": "MOVE LEFT", "Right": "MOVE RIGHT",
	"Attack": "ATTACK", "Katana": "KATANA", "Defend": "DEFEND", "Dodge": "DODGE",
	"Action": "ACTION", "Jump": "JUMP", "Run": "RUN", "Stealth": "STEALTH",
	"RescueAI": "CALL AI",
	"ScrollUse": "USE SCROLL", "ScrollPrevious": "PREV SCROLL", "ScrollNext": "NEXT SCROLL",
	"Scroll1": "SCROLL 1", "Scroll2": "SCROLL 2", "Scroll3": "SCROLL 3",
	"Scroll4": "SCROLL 4", "Scroll5": "SCROLL 5", "Scroll6": "SCROLL 6",
	"Pause": "PAUSE",
}

const BUTTON_NAMES := {
	JOY_BUTTON_A: "A", JOY_BUTTON_B: "B", JOY_BUTTON_X: "X", JOY_BUTTON_Y: "Y",
	JOY_BUTTON_BACK: "BACK", JOY_BUTTON_GUIDE: "GUIDE", JOY_BUTTON_START: "START",
	JOY_BUTTON_LEFT_STICK: "L3", JOY_BUTTON_RIGHT_STICK: "R3",
	JOY_BUTTON_LEFT_SHOULDER: "LB", JOY_BUTTON_RIGHT_SHOULDER: "RB",
	JOY_BUTTON_DPAD_UP: "D-UP", JOY_BUTTON_DPAD_DOWN: "D-DOWN",
	JOY_BUTTON_DPAD_LEFT: "D-LEFT", JOY_BUTTON_DPAD_RIGHT: "D-RIGHT",
	JOY_BUTTON_MISC1: "MISC",
}

const AXIS_NAMES := {
	JOY_AXIS_LEFT_X: ["LS LEFT", "LS RIGHT"], JOY_AXIS_LEFT_Y: ["LS UP", "LS DOWN"],
	JOY_AXIS_RIGHT_X: ["RS LEFT", "RS RIGHT"], JOY_AXIS_RIGHT_Y: ["RS UP", "RS DOWN"],
	JOY_AXIS_TRIGGER_LEFT: ["LT", "LT"], JOY_AXIS_TRIGGER_RIGHT: ["RT", "RT"],
}

## Ticks on save; PlayerInput compares against it to know when to relearn.
var version: int = 0

## action -> {"keys": [codes], "buttons": [idx], "axes": [[axis, sign]]}
var _defaults: Dictionary = {}
## slot -> {"device": int, "bindings": {action -> {...}}}
var _slots: Array[Dictionary] = []
## What is on disk, for revert().
var _saved: Array[Dictionary] = []


func _ready() -> void:
	_learn_defaults()
	for slot in Roster.MAX_PLAYERS:
		_slots.append(_fresh_slot())
	load_from_disk()


## ------------------------------------------------------------------ queries

## Every action's bindings for `slot`, in the shape PlayerInput learns from.
func bindings_for(slot: int) -> Dictionary:
	if slot < 0 or slot >= _slots.size():
		return _defaults
	return _slots[slot]["bindings"]


func assigned_device(slot: int) -> int:
	if slot < 0 or slot >= _slots.size():
		return UNASSIGNED
	return _slots[slot]["device"]


## The slot `device` has been tied to, or -1 for none.
func slot_for_device(device: int) -> int:
	for i in _slots.size():
		if _slots[i]["device"] == device:
			return i
	return -1


func has_unsaved_changes() -> bool:
	return _slots != _saved


## Human-readable summary of what differs from disk, for the confirm dialog.
func pending_changes() -> PackedStringArray:
	var lines: PackedStringArray = []
	for slot in _slots.size():
		var now: Dictionary = _slots[slot]
		var was: Dictionary = _saved[slot]
		if now["device"] != was["device"]:
			lines.append("P%d DEVICE: %s > %s" % [slot + 1,
					device_label(was["device"]), device_label(now["device"])])
		for action in REBINDABLE:
			var a: Dictionary = was["bindings"].get(action, {})
			var b: Dictionary = now["bindings"].get(action, {})
			if a.get("keys", []) != b.get("keys", []):
				lines.append("P%d %s: %s > %s" % [slot + 1, LABELS.get(action, action),
						keyboard_label(slot, action, was), keyboard_label(slot, action, now)])
			if a.get("buttons", []) != b.get("buttons", []) or a.get("axes", []) != b.get("axes", []):
				lines.append("P%d %s (PAD): %s > %s" % [slot + 1, LABELS.get(action, action),
						pad_label(slot, action, was), pad_label(slot, action, now)])
	return lines


## ------------------------------------------------------------------- edits

## Binds the event to `action` for `slot`, replacing that action's other
## bindings of the same kind (keyboard or pad). If another action on the same
## kind already used this input it loses it — one input, one action — unless
## that would leave Pause with nothing, in which case the bind is refused.
## Returns "" on success or a reason to show the player.
func set_binding(slot: int, action: String, event: InputEvent) -> String:
	if slot < 0 or slot >= _slots.size() or action not in REBINDABLE:
		return "NOT REBINDABLE"
	var bindings: Dictionary = _slots[slot]["bindings"]
	if event is InputEventKey:
		var code: int = (event as InputEventKey).physical_keycode
		if code == 0:
			code = (event as InputEventKey).keycode
		if code == KEY_ESCAPE and action != "Pause":
			return "ESC IS RESERVED"
		var victim := _owner_of(bindings, "keys", code)
		if victim == "Pause" and victim != action and bindings[victim]["keys"].size() <= 1:
			return "PAUSE NEEDS A KEY"
		if victim != "" and victim != action:
			bindings[victim]["keys"].erase(code)
		_entry(bindings, action)["keys"] = [code]
		return ""
	if event is InputEventJoypadButton:
		var idx: int = (event as InputEventJoypadButton).button_index
		var victim := _owner_of(bindings, "buttons", idx)
		if victim == "Pause" and victim != action and _pad_count(bindings[victim]) <= 1:
			return "PAUSE NEEDS A BUTTON"
		if victim != "" and victim != action:
			bindings[victim]["buttons"].erase(idx)
		var e := _entry(bindings, action)
		e["buttons"] = [idx]
		e["axes"] = []
		return ""
	if event is InputEventJoypadMotion:
		var motion := event as InputEventJoypadMotion
		var pair := [motion.axis, signf(motion.axis_value)]
		var victim := _owner_of(bindings, "axes", pair)
		if victim == "Pause" and victim != action and _pad_count(bindings[victim]) <= 1:
			return "PAUSE NEEDS A BUTTON"
		if victim != "" and victim != action:
			_erase_pair(bindings[victim]["axes"], pair)
		var e := _entry(bindings, action)
		e["buttons"] = []
		e["axes"] = [pair]
		return ""
	return "UNSUPPORTED INPUT"


## Puts one slot's bindings back to project.godot's defaults. The device
## assignment is separate and untouched.
func reset(slot: int) -> void:
	if slot < 0 or slot >= _slots.size():
		return
	_slots[slot]["bindings"] = _defaults.duplicate(true)


## Ties `device` to `slot`. A device can only sit in one slot, so if another
## slot had it the two swap, which keeps "P1 keyboard, P2 pad" one step away
## from "P1 pad, P2 keyboard" rather than two.
func assign_device(slot: int, device: int) -> void:
	if slot < 0 or slot >= _slots.size():
		return
	var previous: int = _slots[slot]["device"]
	if device != UNASSIGNED:
		var other := slot_for_device(device)
		if other >= 0 and other != slot:
			_slots[other]["device"] = previous
	_slots[slot]["device"] = device


## ----------------------------------------------------------------- storage

func save() -> void:
	var cfg := ConfigFile.new()
	for slot in _slots.size():
		var section := "slot%d" % slot
		cfg.set_value(section, "device", _slots[slot]["device"])
		cfg.set_value(section, "bindings", _slots[slot]["bindings"])
	cfg.save(SAVE_PATH)
	_saved = _slots.duplicate(true)
	version += 1
	changed.emit()


func revert() -> void:
	_slots = _saved.duplicate(true)


func load_from_disk() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		for slot in _slots.size():
			var section := "slot%d" % slot
			_slots[slot]["device"] = int(cfg.get_value(section, "device", UNASSIGNED))
			var stored: Variant = cfg.get_value(section, "bindings", {})
			if stored is Dictionary:
				_merge_bindings(_slots[slot]["bindings"], stored)
	_saved = _slots.duplicate(true)
	version += 1


## ------------------------------------------------------------------ labels

func device_label(device: int) -> String:
	if device == UNASSIGNED:
		return "ANY"
	if device == PlayerInput.KEYBOARD:
		return "KEYBOARD"
	if device >= 0:
		var raw := Input.get_joy_name(device)
		var name := raw.to_upper() if raw != "" else "GAMEPAD"
		if name.length() > 14:
			name = name.substr(0, 14)
		return "%s %d" % [name, device + 1]
	return "NONE"


func keyboard_label(slot: int, action: String, from: Dictionary = {}) -> String:
	var bindings: Dictionary = from["bindings"] if not from.is_empty() else bindings_for(slot)
	var names: PackedStringArray = []
	for code in bindings.get(action, {}).get("keys", []):
		names.append(key_name(code))
	return ", ".join(names) if not names.is_empty() else "---"


func pad_label(slot: int, action: String, from: Dictionary = {}) -> String:
	var bindings: Dictionary = from["bindings"] if not from.is_empty() else bindings_for(slot)
	var entry: Dictionary = bindings.get(action, {})
	var names: PackedStringArray = []
	for idx in entry.get("buttons", []):
		names.append(BUTTON_NAMES.get(idx, "BTN %d" % idx))
	for pair in entry.get("axes", []):
		names.append(axis_name(pair[0], pair[1]))
	return ", ".join(names) if not names.is_empty() else "---"


static func key_name(physical: int) -> String:
	## Shown as the key's printed label on the player's own layout; the headless
	## server has no layout, so there the physical name is used.
	var code: int = 0
	if DisplayServer.get_name() != "headless":
		code = DisplayServer.keyboard_get_keycode_from_physical(physical)
	var text := OS.get_keycode_string(code if code != 0 else physical)
	return text.to_upper() if text != "" else "KEY %d" % physical


static func axis_name(axis: int, sign: float) -> String:
	if AXIS_NAMES.has(axis):
		return AXIS_NAMES[axis][1 if sign > 0.0 else 0]
	return "AXIS %d%s" % [axis, "+" if sign > 0.0 else "-"]


## ---------------------------------------------------------------- internals

func _learn_defaults() -> void:
	for action in InputMap.get_actions():
		var name := String(action)
		if name.begins_with("ui_") or name.begins_with("dialogic"):
			continue
		var entry := {"keys": [], "buttons": [], "axes": []}
		for event in InputMap.action_get_events(action):
			if event is InputEventKey:
				var code: int = (event as InputEventKey).physical_keycode
				if code == 0:
					code = (event as InputEventKey).keycode
				entry["keys"].append(code)
			elif event is InputEventJoypadButton:
				entry["buttons"].append((event as InputEventJoypadButton).button_index)
			elif event is InputEventJoypadMotion:
				var motion := event as InputEventJoypadMotion
				entry["axes"].append([motion.axis, signf(motion.axis_value)])
		_defaults[name] = entry


func _fresh_slot() -> Dictionary:
	return {"device": UNASSIGNED, "bindings": _defaults.duplicate(true)}


## Only actions that still exist are taken from disk, so a stale save from an
## older build cannot bind keys to actions the game no longer has.
func _merge_bindings(into: Dictionary, stored: Dictionary) -> void:
	for action in stored:
		if not into.has(action) or not (stored[action] is Dictionary):
			continue
		var entry: Dictionary = stored[action]
		into[action] = {
			"keys": Array(entry.get("keys", [])),
			"buttons": Array(entry.get("buttons", [])),
			"axes": Array(entry.get("axes", [])),
		}


func _entry(bindings: Dictionary, action: String) -> Dictionary:
	if not bindings.has(action):
		bindings[action] = {"keys": [], "buttons": [], "axes": []}
	return bindings[action]


func _owner_of(bindings: Dictionary, kind: String, value: Variant) -> String:
	for action in bindings:
		for held in bindings[action].get(kind, []):
			if held == value:
				return action
	return ""


func _pad_count(entry: Dictionary) -> int:
	return entry.get("buttons", []).size() + entry.get("axes", []).size()


func _erase_pair(axes: Array, pair: Array) -> void:
	for i in range(axes.size() - 1, -1, -1):
		if axes[i] == pair:
			axes.remove_at(i)
