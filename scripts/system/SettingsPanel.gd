class_name SettingsPanel
extends VBoxContainer

## Display settings list. Shared by the title screen and the pause menu; the
## owner shows or hides it and listens for back_pressed.

signal back_pressed

@export var font_size: int = 12

var _toggles := {}
var _display: Array[Control] = []
var _title: Label
var _language_label: Label
var _language_picker: OptionButton
var _controls_button: Button
var _back_button: Button
var controls: ControlsPanel


func _ready() -> void:
	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", font_size + 1)
	add_child(_title)
	_display.append(_title)

	var language_row := HBoxContainer.new()
	language_row.alignment = BoxContainer.ALIGNMENT_CENTER
	language_row.add_theme_constant_override("separation", 10)
	_language_label = Label.new()
	_language_label.add_theme_font_size_override("font_size", font_size)
	language_row.add_child(_language_label)
	_language_picker = OptionButton.new()
	_language_picker.custom_minimum_size.x = 170
	_language_picker.add_theme_font_size_override("font_size", font_size)
	for entry in LanguageCatalog.LANGUAGES:
		_language_picker.add_item(entry[1])
		_language_picker.set_item_metadata(_language_picker.item_count - 1, entry[0])
	_language_picker.item_selected.connect(_on_language_selected)
	language_row.add_child(_language_picker)
	add_child(language_row)
	_display.append(language_row)

	for id in RetroFX.EFFECTS:
		var toggle := CheckButton.new()
		toggle.add_theme_font_size_override("font_size", font_size)
		toggle.toggled.connect(_on_toggled.bind(id))
		add_child(toggle)
		_toggles[id] = toggle
		_display.append(toggle)

	_controls_button = Button.new()
	_controls_button.add_theme_font_size_override("font_size", font_size + 1)
	_controls_button.pressed.connect(_open_controls)
	add_child(_controls_button)
	_display.append(_controls_button)

	_back_button = Button.new()
	_back_button.add_theme_font_size_override("font_size", font_size + 1)
	_back_button.pressed.connect(func() -> void: back_pressed.emit())
	add_child(_back_button)
	_display.append(_back_button)

	controls = ControlsPanel.new()
	controls.font_size = font_size
	controls.visible = false
	controls.back_pressed.connect(_close_controls)
	add_child(controls)

	visibility_changed.connect(_sync)
	_sync()


func _sync() -> void:
	if visible and controls.visible:
		_close_controls()
	_refresh_language_ui()
	for id in _toggles:
		var toggle: CheckButton = _toggles[id]
		toggle.set_pressed_no_signal(RetroFX.is_enabled(id))
		_update_label(id)


func _open_controls() -> void:
	for node in _display:
		node.visible = false
	controls.visible = true
	TitleScreen.focus_first_button(controls)


func _close_controls() -> void:
	controls.visible = false
	for node in _display:
		node.visible = true
	if visible:
		TitleScreen.focus_first_button(self)


func _on_toggled(enabled: bool, id: String) -> void:
	RetroFX.set_enabled(id, enabled)
	_update_label(id)


func _on_language_selected(index: int) -> void:
	var locale := str(_language_picker.get_item_metadata(index))
	TranslationServer.set_locale(locale)
	get_tree().root.propagate_notification(NOTIFICATION_TRANSLATION_CHANGED)
	_refresh_language_ui()
	for id in _toggles:
		_update_label(id)


func _refresh_language_ui() -> void:
	if _language_picker == null:
		return
	_title.text = tr("DISPLAY")
	_language_label.text = tr("LANGUAGE")
	_controls_button.text = tr("CONTROLS")
	_back_button.text = tr("BACK")
	var current := TranslationServer.get_locale()
	for index in _language_picker.item_count:
		if LanguageCatalog.locale_matches(str(_language_picker.get_item_metadata(index)), current):
			_language_picker.select(index)
			break


func _update_label(id: String) -> void:
	var toggle: CheckButton = _toggles[id]
	toggle.text = "%s: %s" % [tr(RetroFX.EFFECTS[id]["label"]), tr("ON") if toggle.button_pressed else tr("OFF")]
