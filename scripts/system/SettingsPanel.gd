class_name SettingsPanel
extends VBoxContainer

## Shared title/pause settings. The visible pages are height-limited scroll
## areas so every action remains reachable on short windows and web canvases.

signal back_pressed

const DEVICE_REFRESH_SECONDS := 1.0
const ROW_BACKGROUND := Color(0.025, 0.02, 0.035, 0.94)
const ROW_BORDER := Color(0.64, 0.43, 0.19, 0.95)

@export var font_size: int = 12
@export var panel_height: int = 320

var _toggles := {}
var _title: Label
var _audio_heading: Label
var _display_heading: Label
var _language_label: Label
var _language_picker: OptionButton
var _output_label: Label
var _output_picker: OptionButton
var _audio_sliders: Dictionary = {}
var _audio_values: Dictionary = {}
var _audio_labels: Dictionary = {}
var _test_button: Button
var _reset_button: Button
var _audio_help: Label
var _controls_button: Button
var _back_button: Button
var _settings_scroll: ScrollContainer
var _settings_content: VBoxContainer
var _controls_scroll: ScrollContainer
var _known_devices := PackedStringArray()
var _device_refresh_left: float = 0.0
var controls: ControlsPanel


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	_settings_scroll = _scroll_page()
	add_child(_settings_scroll)
	_settings_content = VBoxContainer.new()
	_settings_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_settings_content.add_theme_constant_override("separation", 6)
	_settings_scroll.add_child(_settings_content)

	_title = _heading("", font_size + 2)
	_settings_content.add_child(_title)

	_audio_heading = _heading("", font_size)
	_settings_content.add_child(_audio_heading)
	_add_output_row()
	for bus in AudioManager.VOLUME_KEYS:
		_add_volume_row(bus)

	_test_button = _button("", AudioManager.play_test_sound)
	_settings_content.add_child(_test_button)
	_reset_button = _button("", _reset_audio)
	_settings_content.add_child(_reset_button)
	_audio_help = Label.new()
	_audio_help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_audio_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_audio_help.add_theme_font_size_override("font_size", maxi(font_size - 2, 9))
	_settings_content.add_child(_backed(_audio_help))

	_display_heading = _heading("", font_size)
	_settings_content.add_child(_display_heading)
	_add_language_row()
	for id in RetroFX.EFFECTS:
		var toggle := CheckButton.new()
		toggle.add_theme_font_size_override("font_size", font_size)
		toggle.toggled.connect(_on_toggled.bind(id))
		_settings_content.add_child(toggle)
		_toggles[id] = toggle

	_controls_button = _button("", _open_controls)
	_settings_content.add_child(_controls_button)
	_back_button = _button("", func() -> void: back_pressed.emit())
	_settings_content.add_child(_back_button)

	_controls_scroll = _scroll_page()
	_controls_scroll.visible = false
	add_child(_controls_scroll)
	controls = ControlsPanel.new()
	controls.font_size = font_size
	controls.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	controls.back_pressed.connect(_close_controls)
	_controls_scroll.add_child(controls)

	visibility_changed.connect(_sync)
	set_process(true)
	_sync()


func _scroll_page() -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = panel_height
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	return scroll


func _add_output_row() -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	_output_label = Label.new()
	_output_label.custom_minimum_size.x = 105
	_output_label.add_theme_font_size_override("font_size", font_size)
	row.add_child(_output_label)
	_output_picker = OptionButton.new()
	_output_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_output_picker.custom_minimum_size.x = 135
	_output_picker.add_theme_font_size_override("font_size", font_size)
	_output_picker.item_selected.connect(_on_output_device_selected)
	row.add_child(_output_picker)
	_settings_content.add_child(_backed(row))


func _add_volume_row(bus: StringName) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 6)
	var label := Label.new()
	label.custom_minimum_size.x = 105
	label.add_theme_font_size_override("font_size", font_size)
	row.add_child(label)
	var slider := HSlider.new()
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size.x = 72
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.step = 5.0
	slider.add_theme_icon_override("grabber", get_theme_icon("grabber", "HSlider"))
	slider.value_changed.connect(_on_volume_changed.bind(bus))
	row.add_child(slider)
	var value_label := Label.new()
	value_label.custom_minimum_size.x = 42
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.add_theme_font_size_override("font_size", font_size)
	row.add_child(value_label)
	_audio_labels[bus] = label
	_audio_sliders[bus] = slider
	_audio_values[bus] = value_label
	_settings_content.add_child(_backed(row))


func _add_language_row() -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	_language_label = Label.new()
	_language_label.custom_minimum_size.x = 105
	_language_label.add_theme_font_size_override("font_size", font_size)
	row.add_child(_language_label)
	_language_picker = OptionButton.new()
	_language_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_language_picker.custom_minimum_size.x = 135
	_language_picker.add_theme_font_size_override("font_size", font_size)
	for entry in LanguageCatalog.LANGUAGES:
		_language_picker.add_item(entry[1])
		_language_picker.set_item_metadata(_language_picker.item_count - 1, entry[0])
	_language_picker.item_selected.connect(_on_language_selected)
	row.add_child(_language_picker)
	_settings_content.add_child(_backed(row))


func _backed(content: Control) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = ROW_BACKGROUND
	style.border_color = ROW_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	style.content_margin_left = 8.0
	style.content_margin_top = 5.0
	style.content_margin_right = 8.0
	style.content_margin_bottom = 5.0
	panel.add_theme_stylebox_override("panel", style)
	panel.add_child(content)
	return panel


func _heading(text: String, size: int) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_shadow_color", Color(0.02, 0.01, 0.025, 1.0))
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	return label


func _button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.add_theme_font_size_override("font_size", font_size + 1)
	button.pressed.connect(callback)
	return button


func _process(delta: float) -> void:
	if not visible or not _settings_scroll.visible or OS.get_name() == "Web":
		return
	_device_refresh_left -= delta
	if _device_refresh_left <= 0.0:
		_device_refresh_left = DEVICE_REFRESH_SECONDS
		_refresh_device_picker(false)


func _sync() -> void:
	if visible and _controls_scroll != null and _controls_scroll.visible:
		_close_controls()
	_refresh_language_ui()
	_refresh_device_picker(true)
	for id in _toggles:
		var toggle: CheckButton = _toggles[id]
		toggle.set_pressed_no_signal(RetroFX.is_enabled(id))
		_update_label(id)
	for bus in _audio_sliders:
		var percent := roundi(AudioManager.volume(bus) * 100.0)
		(_audio_sliders[bus] as HSlider).set_value_no_signal(percent)
		(_audio_values[bus] as Label).text = "%d%%" % percent


func _refresh_device_picker(force: bool) -> void:
	if _output_picker == null:
		return
	var devices := AudioManager.refresh_output_device()
	if not force and devices == _known_devices:
		return
	_known_devices = devices
	_output_picker.clear()
	var preferred := AudioManager.preferred_output_device()
	var selected := 0
	for device in devices:
		var name := str(device)
		var display := name
		if name == AudioManager.DEFAULT_OUTPUT_DEVICE:
			display = "BROWSER / SYSTEM DEFAULT" if OS.get_name() == "Web" else "SYSTEM DEFAULT"
		_output_picker.add_item(display)
		_output_picker.set_item_metadata(_output_picker.item_count - 1, name)
		if name == preferred:
			selected = _output_picker.item_count - 1
	_output_picker.select(selected)
	_output_picker.disabled = OS.get_name() == "Web" or _output_picker.item_count <= 1
	_output_picker.tooltip_text = str(_output_picker.get_item_metadata(selected))


func _open_controls() -> void:
	_settings_scroll.visible = false
	_controls_scroll.visible = true
	controls.visible = true
	TitleScreen.focus_first_button(controls)


func _close_controls() -> void:
	controls.visible = false
	_controls_scroll.visible = false
	_settings_scroll.visible = true
	if visible:
		TitleScreen.focus_first_button(_settings_scroll)


func _on_toggled(enabled: bool, id: String) -> void:
	RetroFX.set_enabled(id, enabled)
	_update_label(id)


func _on_volume_changed(value: float, bus: StringName) -> void:
	AudioManager.set_volume(bus, value / 100.0)
	(_audio_values[bus] as Label).text = "%d%%" % roundi(value)


func _on_output_device_selected(index: int) -> void:
	var device := str(_output_picker.get_item_metadata(index))
	AudioManager.set_output_device(device)
	_output_picker.tooltip_text = device


func _reset_audio() -> void:
	AudioManager.reset_audio_settings()
	_sync()
	AudioManager.play_test_sound()


func _audio_name(bus: StringName) -> String:
	match bus:
		AudioManager.BUS_MASTER:
			return tr("MASTER")
		AudioManager.BUS_MUSIC:
			return tr("MUSIC")
		AudioManager.BUS_VOICE:
			return tr("VOICES")
		_:
			return tr("SOUND EFFECTS")


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
	_title.text = tr("SETTINGS")
	_audio_heading.text = tr("AUDIO")
	_display_heading.text = tr("DISPLAY")
	_output_label.text = tr("AUDIO OUTPUT")
	_language_label.text = tr("LANGUAGE")
	_test_button.text = tr("TEST AUDIO")
	_reset_button.text = tr("RESET AUDIO")
	_audio_help.text = tr("NO SOUND? CHECK YOUR SYSTEM OR BROWSER VOLUME MIXER.")
	_controls_button.text = tr("CONTROLS")
	_back_button.text = tr("BACK")
	for bus in _audio_labels:
		(_audio_labels[bus] as Label).text = _audio_name(bus)
	var current := TranslationServer.get_locale()
	for index in _language_picker.item_count:
		if LanguageCatalog.locale_matches(str(_language_picker.get_item_metadata(index)), current):
			_language_picker.select(index)
			break


func _update_label(id: String) -> void:
	var toggle: CheckButton = _toggles[id]
	toggle.text = "%s: %s" % [tr(RetroFX.EFFECTS[id]["label"]), tr("ON") if toggle.button_pressed else tr("OFF")]
