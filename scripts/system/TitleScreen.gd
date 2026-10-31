class_name TitleScreen
extends Node2D

## Title screen. GameManager sends the player here on "game_title".

const SELECT := "res://scenes/menuscreens/characterSelect.tscn"
const LOBBY := "res://scenes/menuscreens/onlineLobby.tscn"

## The first button anywhere under `root`, focused so a controller has somewhere
## to start. Found by walking rather than by path, so moving a button in the
## scene does not quietly break pad navigation.
static func focus_first_button(root: Node) -> bool:
	for child in root.get_children():
		if child is Button and (child as Button).visible:
			(child as Button).grab_focus()
			return true
		if focus_first_button(child):
			return true
	return false


func _ready() -> void:
	## The cover follows whichever aspect is chosen, so quitting to the title
	## shows the character actually being played rather than a fixed image.
	var background := get_node_or_null("UI/Background")
	if background != null:
		background.texture = load(PowerState.cover_path())
	focus_first_button(self)


func _on_new_game_pressed():
	## A Game Over leaves the tree paused if the player quits to title from it.
	get_tree().paused = false
	get_tree().change_scene_to_file(SELECT)


func _on_online_coop_pressed() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file(LOBBY)


func _on_settings_pressed() -> void:
	$UI/SafeArea/VBox/ButtonBox.visible = false
	var panel := $UI/SafeArea/VBox/SettingsPanel
	panel.visible = true
	focus_first_button(panel)


func _on_settings_back_pressed() -> void:
	$UI/SafeArea/VBox/SettingsPanel.visible = false
	var buttons := $UI/SafeArea/VBox/ButtonBox
	buttons.visible = true
	focus_first_button(buttons)


func _on_quit_pressed():
	get_tree().quit()
