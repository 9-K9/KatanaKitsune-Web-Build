extends Control

const ALIGNMENT_PATH := "res://assets/sprites/ui/blink_overlays/alignment.tres"
const KITSUNE_OPEN := preload("res://assets/sprites/ui/title_cover_kitsune.png")
const KITSUNE_CLOSED := preload("res://assets/sprites/ui/blink_overlays/kitsune_closed_eyes.png")
const KARMA_OPEN := preload("res://assets/sprites/ui/title_cover.png")
const KARMA_CLOSED := preload("res://assets/sprites/ui/blink_overlays/karma_geisha_closed_eyes.png")

var alignment: Resource
var canvas: Control
var base: TextureRect
var overlay: TextureRect
var status: Label
var offset_label: Label
var showing_karma := false
var dragging := false
var drag_origin := Vector2.ZERO
var offset_origin := Vector2.ZERO


func _ready() -> void:
	DisplayServer.window_set_size(Vector2i(1040, 540))
	alignment = ResourceLoader.load(ALIGNMENT_PATH, "", ResourceLoader.CACHE_MODE_IGNORE)
	_build_ui()
	_show_character(false)


func _build_ui() -> void:
	var backdrop := ColorRect.new()
	backdrop.color = Color("171018")
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)

	var title := Label.new()
	title.text = "BLINK OVERLAY ALIGNMENT"
	title.position = Vector2(24, 14)
	title.add_theme_font_size_override("font_size", 22)
	add_child(title)

	var help := Label.new()
	help.text = "Drag anywhere on the image, or use the arrow keys for 1-pixel nudges. Shift + arrow moves 5 pixels."
	help.position = Vector2(24, 46)
	add_child(help)

	canvas = Control.new()
	canvas.position = Vector2(24, 76)
	canvas.size = Vector2(768, 432)
	canvas.clip_contents = true
	canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	canvas.focus_mode = Control.FOCUS_ALL
	canvas.gui_input.connect(_on_canvas_input)
	add_child(canvas)

	base = TextureRect.new()
	base.size = canvas.size
	base.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	base.stretch_mode = TextureRect.STRETCH_SCALE
	base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(base)

	overlay = TextureRect.new()
	overlay.size = canvas.size
	overlay.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	overlay.stretch_mode = TextureRect.STRETCH_SCALE
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(overlay)

	var kitsune := Button.new()
	kitsune.text = "KITSUNE"
	kitsune.position = Vector2(820, 88)
	kitsune.size = Vector2(190, 42)
	kitsune.pressed.connect(func() -> void: _show_character(false))
	add_child(kitsune)

	var karma := Button.new()
	karma.text = "KARMA GEISHA"
	karma.position = Vector2(820, 140)
	karma.size = Vector2(190, 42)
	karma.pressed.connect(func() -> void: _show_character(true))
	add_child(karma)

	offset_label = Label.new()
	offset_label.position = Vector2(820, 210)
	offset_label.size = Vector2(190, 50)
	add_child(offset_label)

	var reset := Button.new()
	reset.text = "RESET TO 0, 0"
	reset.position = Vector2(820, 280)
	reset.size = Vector2(190, 42)
	reset.pressed.connect(_reset_offset)
	add_child(reset)

	var save := Button.new()
	save.text = "CONFIRM & SAVE"
	save.position = Vector2(820, 342)
	save.size = Vector2(190, 54)
	save.pressed.connect(_save_alignment)
	add_child(save)

	status = Label.new()
	status.position = Vector2(820, 414)
	status.size = Vector2(200, 90)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(status)


func _show_character(karma: bool) -> void:
	showing_karma = karma
	base.texture = KARMA_OPEN if karma else KITSUNE_OPEN
	overlay.texture = KARMA_CLOSED if karma else KITSUNE_CLOSED
	overlay.position = alignment.karma_geisha_offset if karma else alignment.kitsune_offset
	status.text = ("Editing Karma Geisha" if karma else "Editing Kitsune")
	_update_offset_label()
	canvas.grab_focus()


func _on_canvas_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		dragging = event.pressed
		if dragging:
			drag_origin = event.position
			offset_origin = overlay.position
		accept_event()
	elif event is InputEventMouseMotion and dragging:
		overlay.position = (offset_origin + event.position - drag_origin).round()
		_update_current_offset()
		accept_event()
	elif event is InputEventKey and event.pressed:
		var step := 5.0 if event.shift_pressed else 1.0
		var movement := Vector2.ZERO
		match event.keycode:
			KEY_LEFT: movement.x = -step
			KEY_RIGHT: movement.x = step
			KEY_UP: movement.y = -step
			KEY_DOWN: movement.y = step
		if movement != Vector2.ZERO:
			overlay.position += movement
			_update_current_offset()
			accept_event()


func _update_current_offset() -> void:
	if showing_karma:
		alignment.karma_geisha_offset = overlay.position
	else:
		alignment.kitsune_offset = overlay.position
	_update_offset_label()
	status.text = "Position changed — press Confirm & Save"


func _update_offset_label() -> void:
	offset_label.text = "Offset\nX: %d   Y: %d" % [roundi(overlay.position.x), roundi(overlay.position.y)]


func _reset_offset() -> void:
	overlay.position = Vector2.ZERO
	_update_current_offset()


func _save_alignment() -> void:
	_update_current_offset()
	var error := ResourceSaver.save(alignment, ALIGNMENT_PATH)
	status.text = "Saved successfully." if error == OK else "Save failed: %s" % error_string(error)
