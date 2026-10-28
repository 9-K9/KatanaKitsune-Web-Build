extends Control

const TITLE_SCENE := "res://scenes/title_screen.tscn"
const SPLASH_SECONDS := 1.25

@onready var splash: Control = $Splash
@onready var language_panel: Control = $LanguagePanel
@onready var language_list: VBoxContainer = $LanguagePanel/Panel/Margin/VBox/Languages/List


func _ready() -> void:
	language_panel.visible = false
	for entry in LanguageCatalog.LANGUAGES:
		var button := Button.new()
		button.text = entry[1]
		button.custom_minimum_size = Vector2(250, 42)
		button.pressed.connect(_choose_language.bind(entry[0]))
		language_list.add_child(button)
	await get_tree().create_timer(SPLASH_SECONDS).timeout
	var tween := create_tween()
	tween.tween_property(splash, "modulate:a", 0.0, 0.35)
	await tween.finished
	splash.visible = false
	language_panel.visible = true
	var first := language_list.get_child(0) as Button
	first.grab_focus()


func _choose_language(locale: String) -> void:
	TranslationServer.set_locale(locale)
	get_tree().change_scene_to_file(TITLE_SCENE)
