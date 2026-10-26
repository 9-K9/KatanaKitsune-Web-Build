extends Control

const FULL_VERSION_URL := "https://play.9-k9.io"
const DISPLAY_NAMES: Array[String] = [
	"Sakura Gardens", "Bamboo Woodland", "Abandoned Shrines", "Desert Ruins", "Frozen Pass",
]
const LOCKED_DESCRIPTIONS: Array[String] = [
	"",
	"Locked in the itch.io Web Edition. Play the full version at 9-k9.io.",
	"Locked in the itch.io Web Edition. Play the full version at 9-k9.io.",
	"Locked in the itch.io Web Edition. Play the full version at 9-k9.io.",
	"Locked in the itch.io Web Edition. Play the full version at 9-k9.io.",
]
const ICON_PATHS: Array[String] = [
	"res://assets/pixellab/level_icons/sakura_gardens.png",
	"res://assets/pixellab/level_icons/bamboo_woodland.png",
	"res://assets/pixellab/level_icons/abandoned_shrines.png",
	"res://assets/pixellab/level_icons/desert_ruins.png",
	"res://assets/pixellab/level_icons/frozen_pass.png",
]

signal selected(theme_id: int)
signal cancelled()

@onready var cards: HBoxContainer = $Center/Content/Cards
@onready var description: Label = $Center/Content/Description
@onready var begin: Button = $Center/Content/Buttons/Begin

var _driver: PlayerInput = null
var _highlighted: int = 0
var _repeat: float = 0.0
var _arming: float = 0.0
var _buttons: Array[Button] = []
var _sakura: LevelTheme = null


func _ready() -> void:
	_sakura = LevelTheme.definition(LevelTheme.Id.SAKURA_GARDENS)
	for i in LevelTheme.NAMES.size():
		var button := Button.new()
		button.custom_minimum_size = Vector2(260, 300)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# Device-specific navigation owns selection, not global GUI joypad focus.
		button.focus_mode = Control.FOCUS_NONE
		var content := VBoxContainer.new()
		content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		content.offset_left = 12
		content.offset_top = 12
		content.offset_right = -12
		content.offset_bottom = -12
		content.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var icon := TextureRect.new()
		icon.texture = load(ICON_PATHS[i]) as Texture2D
		if icon.texture == null:
			push_error("LevelSelect: missing theme icon: " + ICON_PATHS[i])
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		icon.custom_minimum_size = Vector2(220, 220)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		content.add_child(icon)
		var label := Label.new()
		label.text = DISPLAY_NAMES[i] if i == 0 else "🔒 " + DISPLAY_NAMES[i]
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 24)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		content.add_child(label)
		button.add_child(content)
		button.pressed.connect(_show.bind(i))
		cards.add_child(button)
		_buttons.append(button)
	_show(0)


func open() -> void:
	visible = true
	_driver = Roster.input_for(0)
	if _driver != null:
		_driver.prime()
	_repeat = 0.0
	_arming = 0.2
	_show(_highlighted)


func _show(index: int) -> void:
	_highlighted = index
	description.text = _sakura.description if index == 0 else LOCKED_DESCRIPTIONS[index]
	for i in _buttons.size():
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.2, 0.09, 0.14, 0.98) if i == index else Color(0.06, 0.04, 0.08, 0.96)
		style.set_border_width_all(4 if i == index else 2)
		style.border_color = Color(1.0, 0.8, 0.4) if i == index else Color(0.4, 0.3, 0.22)
		for state in ["normal", "hover", "pressed"]:
			_buttons[i].add_theme_stylebox_override(state, style)
	begin.text = (tr("BEGIN") + " — " + DISPLAY_NAMES[index]) if index == 0 else "PLAY FULL VERSION — 9-K9.IO"


func _process(delta: float) -> void:
	if not visible:
		return
	_arming = maxf(0.0, _arming - delta)
	_repeat = maxf(0.0, _repeat - delta)
	if _driver == null:
		return
	if _driver.cancel_pressed():
		_back()
		return
	if _driver.confirm_pressed() and _arming <= 0.0:
		_begin()
		return
	if _repeat <= 0.0:
		var step := 0
		if _driver.pressed("MenuRight") or _driver.pressed("MenuDown"):
			step = 1
		elif _driver.pressed("MenuLeft") or _driver.pressed("MenuUp"):
			step = -1
		if step != 0:
			_show(wrapi(_highlighted + step, 0, DISPLAY_NAMES.size()))
			_repeat = 0.18


func _begin() -> void:
	if not visible or _arming > 0.0:
		return
	if _highlighted != LevelTheme.Id.SAKURA_GARDENS:
		OS.shell_open(FULL_VERSION_URL)
		return
	visible = false
	selected.emit(LevelTheme.Id.SAKURA_GARDENS)


func _back() -> void:
	if not visible:
		return
	visible = false
	cancelled.emit()
