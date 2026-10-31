extends Control

## Pick a colour scheme. The preview on the left cycles her animations in the
## highlighted scheme so it can be judged in motion rather than from a portrait.
##
## Purely cosmetic for now: the choice repaints her and the title art, and
## carries no stats.

## Clips worth showing off, in an order that reads as a short performance.
const SHOWCASE: Array[String] = [
	"idle", "katanaDraw", "katanaSlashMid", "katanaCounterSlash",
	"forwardRoll", "fastRun", "flair", "katanaIdle",
]
const SECONDS_PER_CLIP: float = 1.6
## The slow clips read as a pose, not a flurry: at native speed the idle sway
## and the flair dance looked jittery on both heroines. Everything else runs
## as it does in play.
const CLIP_SPEED := {"idle": 0.5, "katanaIdle": 0.5, "flair": 0.6}
## Slowed clips are held for proportionally longer so they still finish.
const CLIP_HOLD := {"idle": 2.6, "katanaIdle": 2.6, "flair": 3.0}
const DIRECTION := "southEast"

## Hair/skin recolour turned out to be unreliable in practice — it also
## retints boots, straps and other grey-painted gear that happens to share
## the exact same ramp as hair/fur, with no clean way to mask it out per
## pixel. Archived rather than deleted: PowerState/Roster/the shader all
## still carry full hair/skin support in case a future masked version fixes
## it, but the selection screen skips straight from COLOUR to the next
## player (or BEGIN) without ever showing the HAIR/SKIN steps.
const HAIR_SKIN_SELECTION_ENABLED := false

## The preview is a Node2D, so it sits in a plain Control rather than a
## container — containers do not lay out Node2D children, which left it pinned
## tiny in the corner.
@onready var preview: AnimatedSprite2D = $PreviewHolder/Preview
@onready var icons: GridContainer = $Right/Icons
@onready var scheme_name: Label = $Right/SchemeName
@onready var element: Label = $Right/Element
@onready var clip_label: Label = $PreviewHolder/ClipName
@onready var cover: TextureRect = $Cover
## Full-screen cover for "set the player count" and "press a button to join" —
## both used to share a thin label with the colour-pick screen behind them,
## easy to mistake for the character grid itself rather than a step of its own.
@onready var prompt_overlay: Control = $PromptOverlay
@onready var prompt_title: Label = $PromptOverlay/Box/Title
@onready var prompt_count_row: Label = $PromptOverlay/Box/CountRow
@onready var prompt_devices: Label = $PromptOverlay/Box/Devices

## Built at runtime rather than in the scene file, the same reason Icons'
## buttons are: there is one per HAIR_TONES/SKIN_TONES entry, and that list is
## PowerState's to own, not something to keep in sync by hand in the .tscn.
var hair_icons: GridContainer = null
var skin_icons: GridContainer = null
var _highlighted_hair: int = 0
var _highlighted_skin: int = 0

var _highlighted: int = 0
var _clip: int = 0
var _elapsed: float = 0.0
var _base_frames: SpriteFrames = null

## How many are playing, who is choosing right now, and on what.
##
## The screen runs as three phases rather than one. Godot's focus system is
## device-blind — it answers to every pad at once — so once players are picking
## in turn the highlight is driven by hand from the active player's own device
## and focus is left out of it entirely.
enum Phase { COUNT, BOTS, BOT_MODES, CLAIM, COLOUR, HAIR, SKIN, LEVEL }

var _level_select: Control = null

var _phase: int = Phase.COUNT
## One behaviour per AI teammate, chosen right after the head count.
var _bot_modes: Array[int] = []
var _bot_cursor: int = 0
var _wanted: int = 1
var _bot_count: int = 0
var _active: int = 0
## One probe per unclaimed device, watched during CLAIM so whichever pad presses
## first takes the slot. Rebuilt whenever the roster changes.
var _probes: Array[PlayerInput] = []
## The device driving the highlight during COLOUR.
var _driver: PlayerInput = null
## Repeat throttle for stick navigation — an analogue stick held over is a level,
## not an edge, and without this one nudge runs the whole row.
var _repeat: float = 0.0
const REPEAT_DELAY: float = 0.18
## Kept alive between frames, and that matters: a PlayerInput works out a press
## by comparing against what it saw last frame, so rebuilding these every frame
## would make every held button look freshly pressed and one nudge would run the
## whole list. Rebuilt only when a pad is plugged in or out.
var _menu_probes: Array[PlayerInput] = []


func _ready() -> void:
	## Borrow the player's own SpriteFrames so the preview cannot drift from
	## what the game actually plays.
	var player: Node = load(CheatManager.player_scene_path()).instantiate()
	var sprite: AnimatedSprite2D = player.get_node("AnimationManager/AnimatedSprite2D")
	_base_frames = sprite.sprite_frames
	## And her material: the clothing key differs per heroine (Kitsune's hair
	## and skirt need a wider one than the shader's defaults), and the scene's
	## own material only has the defaults, which left her lighter hair unkeyed.
	if sprite.material is ShaderMaterial:
		preview.material = sprite.material.duplicate()
	player.queue_free()

	_build_icons()
	_level_select = preload("res://scenes/menuscreens/levelSelect.tscn").instantiate()
	add_child(_level_select)
	_level_select.selected.connect(_take_level)
	_level_select.cancelled.connect(_go_back)
	if HAIR_SKIN_SELECTION_ENABLED:
		_build_hair_icons()
		_build_skin_icons()
	_link_focus()
	_highlighted = PowerState.chosen
	_show(_highlighted)
	## Deferred: grabbing focus before the containers have laid out does not
	## stick, which is why the screen opened with nothing selected.
	## Two frames, not one: the first lays the containers out, and a grab before
	## that silently does nothing — which is why the screen opened on a button.
	await get_tree().process_frame
	await get_tree().process_frame
	## A fresh roster every time the screen opens, or backing out to the title
	## and coming back would stack yesterday's players on top of today's.
	Roster.clear()
	Input.joy_connection_changed.connect(_on_menu_joy_changed)
	_rebuild_menu_probes()
	_enter_count()


## A pad plugged in at the menu joins the probes immediately, so a player can
## pick up a controller and claim a slot without backing out and returning.
func _on_menu_joy_changed(_device: int, _connected: bool) -> void:
	_rebuild_menu_probes()
	if _phase == Phase.CLAIM:
		_enter_claim()


func _build_icons() -> void:
	for i in PowerState.count():
		var button := TextureButton.new()
		button.texture_normal = load(PowerState.icon_path(i))
		button.ignore_texture_size = true
		button.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		button.custom_minimum_size = Vector2(124, 124)
		## Reachable with a pad. Icons are built here rather than in the scene,
		## so nothing in the editor would have set this.
		button.focus_mode = Control.FOCUS_ALL
		button.tooltip_text = "%s — %s" % [PowerState.info(i)["element"], PowerState.info(i)["name"]]
		button.pressed.connect(_on_icon_pressed.bind(i))
		## Moving onto an icon previews it. Focus and selection were separate,
		## so a pad could walk the grid with nothing changing but a thin
		## outline — no name, no preview, no telling where you were.
		button.focus_entered.connect(_show.bind(i))
		icons.add_child(button)


## A swatch button has no art of its own — it's a tone, not a costume — so it
## shows as a plain coloured square in the highlight shade of its ramp,
## bordered the same way as every other button on this screen.
func _make_swatch_button(highlight: Color, tooltip: String) -> Button:
	var button := Button.new()
	button.custom_minimum_size = Vector2(56, 56)
	button.focus_mode = Control.FOCUS_ALL
	button.tooltip_text = tooltip
	var normal := StyleBoxFlat.new()
	normal.bg_color = highlight
	normal.set_border_width_all(3)
	normal.border_color = Color(0.72, 0.52, 0.24, 1)
	normal.set_corner_radius_all(3)
	var focused := StyleBoxFlat.new()
	focused.bg_color = highlight
	focused.set_border_width_all(3)
	focused.border_color = Color(0.96, 0.78, 0.4, 1)
	focused.set_corner_radius_all(3)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", focused)
	button.add_theme_stylebox_override("pressed", focused)
	button.add_theme_stylebox_override("focus", focused)
	return button


## Built after Icons so VBoxContainer order puts it right below the clothing
## grid; hidden until the COLOUR choice is confirmed and HAIR begins.
func _build_hair_icons() -> void:
	hair_icons = GridContainer.new()
	hair_icons.columns = 8
	hair_icons.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	hair_icons.add_theme_constant_override("h_separation", 12)
	hair_icons.add_theme_constant_override("v_separation", 12)
	hair_icons.visible = false
	var right: VBoxContainer = $Right
	right.add_child(hair_icons)
	right.move_child(hair_icons, icons.get_index() + 1)
	for i in PowerState.hair_count():
		var tone: Dictionary = PowerState.hair_info(i)
		var ramp: Array = tone["ramp"]
		var button := _make_swatch_button(ramp[1], tone["name"])
		button.pressed.connect(_on_hair_pressed.bind(i))
		button.focus_entered.connect(_show_hair.bind(i))
		hair_icons.add_child(button)


func _build_skin_icons() -> void:
	skin_icons = GridContainer.new()
	skin_icons.columns = 7
	skin_icons.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	skin_icons.add_theme_constant_override("h_separation", 12)
	skin_icons.add_theme_constant_override("v_separation", 12)
	skin_icons.visible = false
	var right: VBoxContainer = $Right
	right.add_child(skin_icons)
	right.move_child(skin_icons, hair_icons.get_index() + 1)
	for i in PowerState.skin_count():
		var tone: Dictionary = PowerState.skin_info(i)
		var ramp: Array = tone["ramp"]
		var button := _make_swatch_button(ramp[1], tone["name"])
		button.pressed.connect(_on_skin_pressed.bind(i))
		button.focus_entered.connect(_show_skin.bind(i))
		skin_icons.add_child(button)


## Wires the grid by hand. Godot works focus neighbours out geometrically, and
## it was not finding the icons from the buttons at all — navigation just cycled
## BACK and BEGIN. Stating them removes the guesswork.
func _link_focus() -> void:
	var count: int = icons.get_child_count()
	var columns: int = icons.columns
	var begin := get_node_or_null("Right/Buttons/Confirm") as Control
	var back := get_node_or_null("Right/Buttons/Back") as Control
	for i in count:
		var icon: Control = icons.get_child(i)
		var column: int = i % columns
		if column > 0:
			icon.focus_neighbor_left = icon.get_path_to(icons.get_child(i - 1))
		if column < columns - 1 and i + 1 < count:
			icon.focus_neighbor_right = icon.get_path_to(icons.get_child(i + 1))
		if i - columns >= 0:
			icon.focus_neighbor_top = icon.get_path_to(icons.get_child(i - columns))
		if i + columns < count:
			icon.focus_neighbor_bottom = icon.get_path_to(icons.get_child(i + columns))
		elif begin != null:
			## Bottom row drops onto BEGIN, so the screen reads downward.
			icon.focus_neighbor_bottom = icon.get_path_to(begin)
	## And back up from the buttons into the last row.
	if count > 0:
		var last_row_start: int = count - (count % columns if count % columns > 0 else columns)
		for button in [begin, back]:
			if button != null:
				button.focus_neighbor_top = button.get_path_to(icons.get_child(last_row_start))


## Confirming an icon moves on to BEGIN, so the pad walks the screen in the
## order the screen is read: pick an aspect, then commit to it.
func _on_icon_pressed(index: int) -> void:
	_show(index)
	var begin := get_node_or_null("Right/Buttons/Confirm") as Control
	if begin != null:
		begin.grab_focus()


func _on_hair_pressed(index: int) -> void:
	_show_hair(index)
	var begin := get_node_or_null("Right/Buttons/Confirm") as Control
	if begin != null:
		begin.grab_focus()


func _on_skin_pressed(index: int) -> void:
	_show_skin(index)
	var begin := get_node_or_null("Right/Buttons/Confirm") as Control
	if begin != null:
		begin.grab_focus()


## Back to the icons. Cancel is the pad's right-hand face button — B on an Xbox
## pad, Circle on a DualShock, A on a Switch controller.
func _unhandled_input(event: InputEvent) -> void:
	## Cancel belongs to the party flow now, which routes it to the right player
	## rather than to whichever device happened to press. Left in place only so
	## nothing else claims the event.
	if not event.is_action_pressed("ui_cancel"):
		return
	get_viewport().set_input_as_handled()




## Repaints the preview and the backdrop in one scheme.
func _show(index: int) -> void:
	_highlighted = index
	var data: Dictionary = PowerState.info(index)
	scheme_name.text = data["name"]
	element.text = "◆  %s  ◆" % data["element"]
	cover.texture = load(PowerState.cover_path(index))

	preview.sprite_frames = _base_frames
	PowerState.apply_to(preview, index, _highlighted_hair, _highlighted_skin)
	_clip = 0
	_elapsed = 0.0
	_play_current()

	## Dim every icon but the highlighted one, so the selection is unmistakable.
	for i in icons.get_child_count():
		var button: TextureButton = icons.get_child(i)
		## Three states, not two: the one being previewed is full brightness, the
		## rest are dimmed, and the focused one is brighter still so it stands
		## out against the preview when a pad is driving.
		if i == index:
			button.modulate = Color.WHITE
		else:
			button.modulate = Color(0.45, 0.42, 0.45)
		if button.has_focus():
			button.modulate = Color(1.35, 1.3, 1.1)


## Same trick as _show, but for the hair row: the clothing scheme, skin tone
## and preview keep whatever they already were, only hair changes.
func _show_hair(index: int) -> void:
	_highlighted_hair = index
	scheme_name.text = PowerState.hair_info(index)["name"]
	element.text = "◆  HAIR  ◆"
	preview.sprite_frames = _base_frames
	PowerState.apply_to(preview, _highlighted, index, _highlighted_skin)
	_dim_swatches(hair_icons, index)


func _show_skin(index: int) -> void:
	_highlighted_skin = index
	scheme_name.text = PowerState.skin_info(index)["name"]
	element.text = "◆  SKIN TONE  ◆"
	preview.sprite_frames = _base_frames
	PowerState.apply_to(preview, _highlighted, _highlighted_hair, index)
	_dim_swatches(skin_icons, index)


func _dim_swatches(grid: GridContainer, index: int) -> void:
	for i in grid.get_child_count():
		var button: Button = grid.get_child(i)
		if i == index:
			button.modulate = Color.WHITE
		else:
			button.modulate = Color(0.55, 0.52, 0.55)
		if button.has_focus():
			button.modulate = Color(1.35, 1.3, 1.1)


func _play_current() -> void:
	var clip: String = SHOWCASE[_clip % SHOWCASE.size()]
	var anim := "%s_%s" % [clip, DIRECTION]
	if preview.sprite_frames != null and preview.sprite_frames.has_animation(anim):
		preview.speed_scale = CLIP_SPEED.get(clip, 1.0)
		preview.play(anim)
		clip_label.text = clip
	else:
		clip_label.text = ""


func _process(delta: float) -> void:
	_drive(delta)
	_elapsed += delta
	if _elapsed >= CLIP_HOLD.get(SHOWCASE[_clip % SHOWCASE.size()], SECONDS_PER_CLIP):
		_elapsed = 0.0
		_clip += 1
		_play_current()


func _on_confirm_pressed() -> void:
	## The on-screen button belongs to whoever is choosing now.
	match _phase:
		Phase.LEVEL:
			return
		Phase.HAIR:
			_take_hair()
		Phase.SKIN:
			_take_skin()
		_:
			_take_colour()


func _on_back_pressed() -> void:
	_go_back()


## Runs the current phase off real devices. Everything here reads a specific
## device rather than the global Input, which is the whole point: during COLOUR
## only the player whose turn it is may move the highlight.
func _drive(delta: float) -> void:
	_repeat = maxf(_repeat - delta, 0.0)
	match _phase:
		Phase.COUNT:
			_drive_count()
		Phase.BOTS:
			_drive_bots()
		Phase.BOT_MODES:
			_drive_bot_modes()
		Phase.CLAIM:
			_drive_claim()
		Phase.COLOUR:
			_drive_colour()
		Phase.HAIR:
			_drive_hair()
		Phase.SKIN:
			_drive_skin()


## Before anyone has claimed anything, so any device may set the number.
func _drive_count() -> void:
	var step: int = 0
	for probe in _all_devices():
		if probe.just_pressed("MenuRight") or probe.just_pressed("MenuDown"):
			step = 1
		elif probe.just_pressed("MenuLeft") or probe.just_pressed("MenuUp"):
			step = -1
		if probe.confirm_pressed():
			_active = 0
			if _wanted == Roster.MAX_PLAYERS:
				_bot_count = 0
				_enter_claim()
			else:
				_phase = Phase.BOTS
				_bot_count = mini(_bot_count, Roster.MAX_PLAYERS - _wanted)
				for menu in _all_devices():
					menu.prime()
				_show_bot_prompt()
			return
		if probe.cancel_pressed():
			_go_back()
			return
	if step != 0:
		_wanted = clampi(_wanted + step, 1, Roster.MAX_PLAYERS)
		_show_count_prompt()


func _drive_bots() -> void:
	var step: int = 0
	for probe in _all_devices():
		if probe.just_pressed("MenuRight") or probe.just_pressed("MenuDown"):
			step = 1
		elif probe.just_pressed("MenuLeft") or probe.just_pressed("MenuUp"):
			step = -1
		if probe.confirm_pressed():
			if _bot_count > 0:
				_enter_bot_modes()
			else:
				_enter_claim()
			return
		if probe.cancel_pressed():
			_enter_count()
			return
	if step != 0:
		_bot_count = clampi(_bot_count + step, 0, Roster.MAX_PLAYERS - _wanted)
		_show_bot_prompt()


func _enter_bot_modes() -> void:
	_phase = Phase.BOT_MODES
	while _bot_modes.size() < _bot_count:
		_bot_modes.append(Roster.DEFAULT_BOT_MODE)
	_bot_cursor = clampi(_bot_cursor, 0, _bot_count - 1)
	for menu in _all_devices():
		menu.prime()
	_show_bot_mode_prompt()


## Up / down picks the teammate, left / right picks how it fights.
func _drive_bot_modes() -> void:
	var row: int = 0
	var step: int = 0
	for probe in _all_devices():
		if probe.just_pressed("MenuDown"):
			row = 1
		elif probe.just_pressed("MenuUp"):
			row = -1
		elif probe.just_pressed("MenuRight"):
			step = 1
		elif probe.just_pressed("MenuLeft"):
			step = -1
		if probe.confirm_pressed():
			_enter_claim()
			return
		if probe.cancel_pressed():
			_go_back()
			return
	if row == 0 and step == 0:
		return
	_bot_cursor = posmod(_bot_cursor + row, _bot_count)
	if step != 0:
		_bot_modes[_bot_cursor] = posmod(_bot_modes[_bot_cursor] + step,
				Roster.BOT_MODE_NAMES.size())
	_show_bot_mode_prompt()


## Whichever free device presses first takes this slot.
func _drive_claim() -> void:
	for probe in _probes:
		if probe.cancel_pressed():
			_go_back()
			return
	for probe in _probes:
		if not probe.confirm_pressed():
			continue
		if Roster.join(probe.device) < 0:
			continue
		_enter_colour()
		return


## Only the active player's device moves the highlight.
func _drive_colour() -> void:
	if _driver == null:
		return
	if _driver.cancel_pressed():
		_go_back()
		return
	if _driver.confirm_pressed():
		_take_colour()
		return
	if _repeat > 0.0:
		return
	var across: int = icons.columns if icons.columns > 0 else 6
	var step: int = 0
	if _driver.pressed("MenuRight"):
		step = 1
	elif _driver.pressed("MenuLeft"):
		step = -1
	elif _driver.pressed("MenuDown"):
		step = across
	elif _driver.pressed("MenuUp"):
		step = -across
	if step == 0:
		return
	_repeat = REPEAT_DELAY
	var total: int = PowerState.count()
	## Steps over schemes an earlier player already wears, so held navigation
	## never parks on a choice that cannot be confirmed.
	var next: int = _highlighted
	for _i in total:
		next = wrapi(next + step, 0, total)
		if not Roster.scheme_taken(next, _active):
			break
	_highlighted = next
	_show(_highlighted)


## Same stepping as _drive_colour, but over the hair row — no uniqueness
## constraint, since two players can share a hairstyle.
func _drive_hair() -> void:
	if _driver == null:
		return
	if _driver.cancel_pressed():
		_go_back()
		return
	if _driver.confirm_pressed():
		_take_hair()
		return
	if _repeat > 0.0:
		return
	var across: int = hair_icons.columns if hair_icons.columns > 0 else 8
	var step: int = _nav_step(across)
	if step == 0:
		return
	_repeat = REPEAT_DELAY
	_show_hair(wrapi(_highlighted_hair + step, 0, PowerState.hair_count()))


func _drive_skin() -> void:
	if _driver == null:
		return
	if _driver.cancel_pressed():
		_go_back()
		return
	if _driver.confirm_pressed():
		_take_skin()
		return
	if _repeat > 0.0:
		return
	var across: int = skin_icons.columns if skin_icons.columns > 0 else 7
	var step: int = _nav_step(across)
	if step == 0:
		return
	_repeat = REPEAT_DELAY
	_show_skin(wrapi(_highlighted_skin + step, 0, PowerState.skin_count()))


## Shared four-way reading of the driving device, factored out once a third
## screen needed the exact same Right/Left/Down/Up -> step mapping as COLOUR.
func _nav_step(across: int) -> int:
	if _driver.pressed("MenuRight"):
		return 1
	elif _driver.pressed("MenuLeft"):
		return -1
	elif _driver.pressed("MenuDown"):
		return across
	elif _driver.pressed("MenuUp"):
		return -across
	return 0


## Keyboard plus every connected pad, for the phases open to all comers.
func _all_devices() -> Array[PlayerInput]:
	if _menu_probes.is_empty():
		_rebuild_menu_probes()
	return _menu_probes


func _rebuild_menu_probes() -> void:
	_menu_probes = [PlayerInput.new(PlayerInput.KEYBOARD)]
	for id in Input.get_connected_joypads():
		_menu_probes.append(PlayerInput.new(id))


## ---------------------------------------------------------------- party flow

func _enter_count() -> void:
	_phase = Phase.COUNT
	_wanted = maxi(_wanted, 1)
	_show_count_prompt()


func _enter_claim() -> void:
	_phase = Phase.CLAIM
	_probes.clear()
	for id in Roster.free_devices():
		var probe := PlayerInput.new(id)
		## Same reason: a button still held from the previous phase must not
		## instantly claim the next slot.
		probe.prime()
		_probes.append(probe)
	if _probes.is_empty():
		## Nothing left to claim with — more players were asked for than there
		## are devices, so settle for the ones already in.
		_enter_level()
		return
	_show_claim_prompt()


func _enter_colour() -> void:
	_phase = Phase.COLOUR
	_hide_prompt()
	_driver = Roster.input_for(_active)
	## The button that claimed this pad is very likely still held. Priming makes
	## it count as already-down, so the colour screen waits for a fresh press
	## instead of confirming the first scheme and skipping the choice entirely.
	_driver.prime()
	icons.visible = true
	if hair_icons != null:
		hair_icons.visible = false
	if skin_icons != null:
		skin_icons.visible = false
	## Opens on a scheme nobody has taken, so the first thing shown is a legal
	## choice rather than one that silently refuses to confirm.
	_highlighted = _first_free_scheme()
	_show(_highlighted)
	_banner("PLAYER %d — %s" % [_active + 1, _driver.device_name()])


## Every scheme not already worn by an earlier player.
func _first_free_scheme() -> int:
	for i in PowerState.count():
		if not Roster.scheme_taken(i, _active):
			return i
	return 0


func _take_colour() -> void:
	if _phase != Phase.COLOUR or Roster.scheme_taken(_highlighted, _active):
		return
	Roster.set_scheme(_active, _highlighted)
	if HAIR_SKIN_SELECTION_ENABLED:
		_enter_hair()
	else:
		_active += 1
		if _active >= _wanted:
			_enter_level()
			return
		_enter_claim()


func _enter_hair() -> void:
	_phase = Phase.HAIR
	icons.visible = false
	hair_icons.visible = true
	skin_icons.visible = false
	_highlighted_hair = Roster.hair_of(_active)
	_show_hair(_highlighted_hair)
	_banner("PLAYER %d — CHOOSE A HAIR COLOUR" % (_active + 1))


func _take_hair() -> void:
	if _phase != Phase.HAIR:
		return
	Roster.set_hair(_active, _highlighted_hair)
	_enter_skin()


func _enter_skin() -> void:
	_phase = Phase.SKIN
	hair_icons.visible = false
	skin_icons.visible = true
	_highlighted_skin = Roster.skin_of(_active)
	_show_skin(_highlighted_skin)
	_banner("PLAYER %d — CHOOSE A SKIN TONE" % (_active + 1))


func _take_skin() -> void:
	if _phase != Phase.SKIN:
		return
	Roster.set_skin(_active, _highlighted_skin)
	_active += 1
	if _active >= _wanted:
		_enter_level()
		return
	_enter_claim()


## Back always hands control to the player before, so a wrong colour is one
## press away from being redone rather than a reason to restart the screen.
func _go_back() -> void:
	match _phase:
		Phase.LEVEL:
			_active = maxi(Roster.count() - 1, 0)
			$Right.visible = true
			$PreviewHolder.visible = true
			_enter_colour()
			_highlighted = Roster.scheme_of(_active)
			_show(_highlighted)
		Phase.COUNT:
			get_tree().change_scene_to_file("res://scenes/title_screen.tscn")
		Phase.BOTS:
			_enter_count()
		Phase.BOT_MODES:
			_phase = Phase.BOTS
			_show_bot_prompt()
		Phase.CLAIM:
			## Nobody has claimed this slot yet, so step back over the player
			## before and let them choose again.
			if _active == 0:
				Roster.clear()
				if _bot_count > 0:
					_enter_bot_modes()
				else:
					_enter_count()
			else:
				_active -= 1
				Roster.drop_last()
				_enter_claim()
		Phase.COLOUR:
			## Give up this device and re-claim, so a player who grabbed the
			## wrong pad can hand it back.
			Roster.drop_last()
			_enter_claim()
		Phase.HAIR:
			## One step back into the scheme grid, same player, same device.
			_enter_colour()
		Phase.SKIN:
			_enter_hair()


func _enter_level() -> void:
	if Roster.count() == 0:
		_enter_count()
		return
	_phase = Phase.LEVEL
	_hide_prompt()
	## The party is complete, so settle who is P1, P2… by the device
	## assignments saved in Settings before the level is picked.
	Roster.apply_device_assignments()
	$Right.visible = false
	$PreviewHolder.visible = false
	var focused := get_viewport().gui_get_focus_owner()
	if focused != null:
		focused.release_focus()
	_level_select.open()


func _take_level(index: int) -> void:
	Roster.level_theme = index
	_start_game()


func _start_game() -> void:
	for i in mini(_bot_count, Roster.MAX_PLAYERS - Roster.count()):
		var slot := Roster.add_bot()
		if slot < 0:
			push_error("CharacterSelect: could not add the selected AI teammate.")
			return
		if i < _bot_modes.size():
			Roster.set_mode(slot, _bot_modes[i])
	Score.begin_run()
	Progression.begin_run()
	## Player one's scheme stays the global one, so the title art and anything
	## else still reading PowerState.chosen keeps working.
	if Roster.count() > 0:
		PowerState.select(Roster.scheme_of(0))
		PowerState.select_hair(Roster.hair_of(0))
		PowerState.select_skin(Roster.skin_of(0))
	## Through SceneLoader rather than a direct change_scene_to_file: it is the
	## thing that makes the bar visible before the dungeon's own hold()/step()
	## calls in its _ready() have anything to draw onto. A direct swap leaves
	## those calls as no-ops against a screen that never came up.
	SceneLoader.go_to("res://scenes/world/mazeDemo.tscn", "DESCENDING")


func _count_bar() -> String:
	var bar := ""
	for i in Roster.MAX_PLAYERS:
		bar += ("[%d]" % (i + 1)) if (i + 1) == _wanted else (" %d " % (i + 1))
	return bar


## A full-screen stop before the character grid even shows, so setting the
## head count reads as its own step rather than a line of text floating over
## a screen that looks like it is already asking you to pick a colour.
func _show_count_prompt() -> void:
	prompt_overlay.visible = true
	prompt_title.text = tr("HOW MANY HUMAN PLAYERS?")
	prompt_count_row.text = _count_bar()
	prompt_devices.text = tr("LEFT / RIGHT TO CHANGE   •   %s TO CONFIRM") \
			% PlayerInput.new(PlayerInput.KEYBOARD).confirm_button_label()


func _show_bot_prompt() -> void:
	prompt_overlay.visible = true
	prompt_title.text = tr("HOW MANY AI TEAMMATES?")
	var bar := ""
	for i in Roster.MAX_PLAYERS - _wanted + 1:
		bar += ("[%d]" % i) if i == _bot_count else (" %d " % i)
	prompt_count_row.text = bar
	prompt_devices.text = "LEFT / RIGHT TO CHANGE   •   CONFIRM TO CONTINUE\n" \
			+ "FOLLOW, FIGHT AND AVOID TRAPS   •   FOUR PARTY MEMBERS MAX"


func _show_bot_mode_prompt() -> void:
	prompt_overlay.visible = true
	prompt_title.text = tr("AI TEAMMATE BEHAVIOUR")
	var rows := PackedStringArray()
	for i in _bot_count:
		var mode: int = _bot_modes[i]
		var shown: String = "< %s >" % Roster.BOT_MODE_NAMES[mode] if i == _bot_cursor \
				else "  %s  " % Roster.BOT_MODE_NAMES[mode]
		rows.append("AI%d  %s" % [_wanted + i + 1, shown])
	prompt_count_row.text = "\n".join(rows)
	prompt_devices.text = "UP / DOWN TO PICK   •   LEFT / RIGHT TO CHANGE   •   CONFIRM TO CONTINUE\n" \
			+ Roster.BOT_MODE_HINTS[_bot_modes[_bot_cursor]]


## A fixed legend rather than one line per device actually plugged in — a pad
## that is not connected yet still deserves to be on the card, so whoever is
## about to go find an Xbox pad from another room knows what it will say
## before they are holding it. Shortened from the raw joypad name
## ("Nintendo Switch Pro Controller"), which ran long enough to crowd the row.
const DEVICE_LEGEND: Array[Array] = [
	["KEYBOARD", "SPACE"],
	["XBOX", "A"],
	["PLAYSTATION", "X"],
	["NINTENDO PRO", "B"],
]


## One overlay per unclaimed device so a PS pad, an Xbox pad and the keyboard
## sitting at the same table are each told their own button, rather than a
## single "press a button" nobody owns the wording of.
func _show_claim_prompt() -> void:
	prompt_overlay.visible = true
	prompt_title.text = tr("PLAYER %d — PRESS A BUTTON TO JOIN") % (_active + 1)
	prompt_count_row.text = ""
	var lines: Array[String] = []
	for entry in DEVICE_LEGEND:
		lines.append("%s: %s" % [entry[0], entry[1]])
	prompt_devices.text = "   •   ".join(lines)


func _hide_prompt() -> void:
	prompt_overlay.visible = false


## True while the live preview labels (scheme/hair/skin name) own
## SchemeName/Element, so a status banner must not stomp on them.
func _showing_preview_labels() -> bool:
	return _phase == Phase.COLOUR or _phase == Phase.HAIR or _phase == Phase.SKIN


func _banner(text: String) -> void:
	var label := get_node_or_null("Right/SchemeName") as Label
	if label != null and not _showing_preview_labels():
		label.text = text
	var hint := get_node_or_null("Right/Element") as Label
	if hint != null:
		hint.text = text if not _showing_preview_labels() else hint.text
