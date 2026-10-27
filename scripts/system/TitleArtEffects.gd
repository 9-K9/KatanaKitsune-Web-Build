class_name TitleArtEffects
extends Control

## Lightweight shared polish for every screen that displays title-cover art.
## The whole component processes while paused so the pause menu remains alive.

@export var cover_path: NodePath
@export var blink_enabled: bool = true
@export_range(2.0, 12.0, 0.1) var blink_min_seconds: float = 3.0
@export_range(2.0, 12.0, 0.1) var blink_max_seconds: float = 6.5

const KITSUNE_BLINK := preload("res://assets/sprites/ui/blink_overlays/kitsune_closed_eyes-noHair.png")
const KARMA_BLINK := preload("res://assets/sprites/ui/blink_overlays/karma_geisha_closed_eyes-noHair.png")
const BLINK_ALIGNMENT := preload("res://assets/sprites/ui/blink_overlays/alignment.tres")
const LEAF_TEXTURE := preload("res://assets/sprites/ui/title_leaf.svg")
const BLINK_CLOSE_TIME: float = 0.075
const BLINK_HOLD_TIME: float = 0.045
const BLINK_OPEN_TIME: float = 0.095

var _cover: TextureRect
var _blink_overlay: TextureRect
var _leaves: CPUParticles2D
var _blink_wait: float = 0.0
var _blink_clock: float = -1.0
var _double_blink: bool = false
var _karma: bool = false
var _last_texture: Texture2D


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cover = get_node_or_null(cover_path) as TextureRect
	if _cover == null:
		push_warning("TitleArtEffects has no TextureRect at %s" % cover_path)
		return
	if blink_enabled:
		_build_blink_overlay()
	_sync_cover_texture()
	_sync_heroine()
	_build_leaves()
	_reschedule_blink()
	resized.connect(_layout_leaves)
	if not CheatManager.karmageisha_changed.is_connected(_on_karmageisha_changed):
		CheatManager.karmageisha_changed.connect(_on_karmageisha_changed)


func _process(delta: float) -> void:
	if _blink_overlay == null:
		return
	if _cover.texture != _last_texture:
		_sync_cover_texture()
	if _blink_clock < 0.0:
		_blink_wait -= delta
		if _blink_wait <= 0.0:
			_blink_clock = 0.0
			_double_blink = randf() < 0.18
		return
	_blink_clock += delta
	var total := BLINK_CLOSE_TIME + BLINK_HOLD_TIME + BLINK_OPEN_TIME
	var amount: float
	if _blink_clock < BLINK_CLOSE_TIME:
		amount = _blink_clock / BLINK_CLOSE_TIME
	elif _blink_clock < BLINK_CLOSE_TIME + BLINK_HOLD_TIME:
		amount = 1.0
	elif _blink_clock < total:
		amount = 1.0 - ((_blink_clock - BLINK_CLOSE_TIME - BLINK_HOLD_TIME) / BLINK_OPEN_TIME)
	else:
		_set_blink_amount(0.0)
		_blink_clock = -1.0
		if _double_blink:
			_double_blink = false
			_blink_wait = randf_range(0.11, 0.2)
		else:
			_reschedule_blink()
		return
	_set_blink_amount(smoothstep(0.0, 1.0, amount))


func _reschedule_blink() -> void:
	_blink_wait = randf_range(blink_min_seconds, blink_max_seconds)


func _sync_cover_texture() -> void:
	_last_texture = _cover.texture


func _on_karmageisha_changed(_active: bool) -> void:
	_sync_heroine()


func _sync_heroine() -> void:
	_karma = CheatManager.karmageisha_active
	if _blink_overlay == null:
		return
	## These painted overlays contain only the closed eyes; hair was cropped out,
	## so one PNG stays correct across all twelve recoloured covers.
	_blink_overlay.texture = KARMA_BLINK if _karma else KITSUNE_BLINK
	_layout_blink_overlay()


func _build_blink_overlay() -> void:
	_blink_overlay = TextureRect.new()
	_blink_overlay.name = "ClosedEyeOverlay"
	_blink_overlay.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_blink_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_blink_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_blink_overlay.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_blink_overlay.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_blink_overlay.modulate.a = 0.0
	add_child(_blink_overlay)
	resized.connect(_layout_blink_overlay)


func _set_blink_amount(amount: float) -> void:
	if _blink_overlay != null:
		_blink_overlay.modulate.a = clampf(amount, 0.0, 1.0)


func _layout_blink_overlay() -> void:
	if _blink_overlay == null:
		return
	var reference_offset: Vector2 = (BLINK_ALIGNMENT.karma_geisha_offset
		if _karma else BLINK_ALIGNMENT.kitsune_offset)
	var scale_factor := maxf(size.x / 768.0, size.y / 432.0)
	_blink_overlay.position = reference_offset * scale_factor


func _build_leaves() -> void:
	_leaves = CPUParticles2D.new()
	_leaves.name = "WindblownRedLeaves"
	_leaves.texture = LEAF_TEXTURE
	_leaves.amount = 30
	_leaves.lifetime = 7.5
	_leaves.preprocess = 7.5
	_leaves.randomness = 0.7
	_leaves.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	_leaves.direction = Vector2(-1.0, 0.26)
	_leaves.spread = 18.0
	_leaves.initial_velocity_min = 105.0
	_leaves.initial_velocity_max = 185.0
	_leaves.gravity = Vector2(0.0, 15.0)
	_leaves.angular_velocity_min = -150.0
	_leaves.angular_velocity_max = 150.0
	_leaves.scale_amount_min = 0.3
	_leaves.scale_amount_max = 0.58
	_leaves.z_index = 1
	add_child(_leaves)
	_layout_leaves()


func _layout_leaves() -> void:
	if _leaves == null:
		return
	var view := size
	if view.x <= 1.0 or view.y <= 1.0:
		view = get_viewport_rect().size
	# Emit just beyond the upper/right edge, across the whole screen height.
	# Particles then cross the composition diagonally instead of raining in a
	# uniform curtain over the menu text.
	_leaves.position = Vector2(view.x + 24.0, view.y * 0.35)
	_leaves.emission_rect_extents = Vector2(20.0, view.y * 0.58)
