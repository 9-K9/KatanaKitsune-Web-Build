extends CanvasLayer

## The loading screen, and the only way scenes should change.
##
## Two jobs. It loads the next scene on a worker thread so the main thread keeps
## drawing, and it stays up afterwards while the incoming scene does its own
## setup — which for the dungeon is most of the work. A screen that disappeared
## the moment the .tscn finished loading would hand back a frozen window while
## sixteen rooms were built, which is the stall it exists to cover.
##
## An incoming scene opts into the second part by calling `hold()` in its
## `_ready` and `finish()` when it is done. Anything that does not is released
## automatically, so every other scene in the project keeps working untouched.

const FONT := "res://assets/fonts/KatanaKitsuneUI.ttf"
const INK := Color(0.85, 0.72, 0.42)
const BACKDROP := Color(0.045, 0.03, 0.055)
const FILL := Color(0.72, 0.52, 0.24)
const TRACK := Color(0.16, 0.12, 0.14)

## How much of the bar belongs to loading the .tscn, leaving the rest for the
## scene's own setup. Weighted towards setup deliberately: the dungeon's rooms,
## maze carve and population cost more than parsing the scene that describes
## them, and a bar that sits at full for the slow half is worse than no bar.
const LOAD_SHARE := 0.45

## Long enough for any honest load, short enough that a scene which holds and
## then fails does not leave a dead screen up forever.
const HOLD_LIMIT := 60.0

## Bar easing. The thread reports progress in jumps — a chunk of dependencies at
## a time — and a bar that teleports reads as broken.
const EASE_SPEED := 6.0

var _path := ""
var _loading := false
var _held := false
var _held_for := 0.0
var _target := 0.0
var _shown := 0.0

var _veil: ColorRect = null
var _title: Label = null
var _note: Label = null
var _track: ColorRect = null
var _fill: ColorRect = null


func _ready() -> void:
	## Above the dungeon's own overlays, which sit at 80 and 90.
	layer = 128
	## A pause left over from a Game Over must not stop the screen that is
	## replacing it — the loader is the one thing that has to keep running.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_set_visible(false)


func _build_ui() -> void:
	_veil = ColorRect.new()
	_veil.color = BACKDROP
	_veil.set_anchors_preset(Control.PRESET_FULL_RECT)
	_veil.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_veil)

	var font: Font = load(FONT) if ResourceLoader.exists(FONT) else null

	_title = Label.new()
	_title.text = tr("LOADING")
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_title.add_theme_font_size_override("font_size", 38)
	_title.add_theme_color_override("font_color", INK)
	if font != null:
		_title.add_theme_font_override("font", font)
	_veil.add_child(_title)

	_note = Label.new()
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_note.add_theme_font_size_override("font_size", 18)
	_note.add_theme_color_override("font_color", Color(INK, 0.65))
	if font != null:
		_note.add_theme_font_override("font", font)
	_veil.add_child(_note)

	_track = ColorRect.new()
	_track.color = TRACK
	_veil.add_child(_track)

	_fill = ColorRect.new()
	_fill.color = FILL
	_track.add_child(_fill)

	_veil.resized.connect(_lay_out)
	_lay_out()


## Laid out against the veil's real size rather than anchored, because the bar's
## fill is sized by fraction and wants a width in pixels to multiply.
func _lay_out() -> void:
	if _veil == null:
		return
	var box: Vector2 = _veil.size
	var bar := Vector2(minf(560.0, box.x * 0.6), 14.0)
	var at := Vector2((box.x - bar.x) * 0.5, box.y * 0.62)
	_title.position = Vector2(0.0, box.y * 0.42)
	_title.size.x = box.x
	_note.position = Vector2(0.0, box.y * 0.62 + 30.0)
	_note.size.x = box.x
	_track.position = at
	_track.size = bar
	_fill.position = Vector2.ZERO
	_fill.size = Vector2(bar.x * clampf(_shown, 0.0, 1.0), bar.y)


func _set_visible(on: bool) -> void:
	visible = on
	if _veil != null:
		_veil.visible = on


func is_active() -> bool:
	return visible


## Shows the screen without changing scene, for work done in place — the next
## floor of the dungeon is rebuilt around the player rather than reloaded, and
## that rebuild stalls exactly as hard as a fresh load.
func begin(title: String = "LOADING", note: String = "") -> void:
	_title.text = title
	_note.text = note
	_target = 0.0
	_shown = 0.0
	_held = true
	_held_for = 0.0
	_set_visible(true)
	_lay_out()


## Loads `path` on a worker thread, swaps to it, then waits for the incoming
## scene to release the screen.
func go_to(path: String, title: String = "LOADING") -> void:
	if _loading:
		push_warning("SceneLoader: already loading %s, ignoring %s" % [_path, path])
		return
	if not ResourceLoader.exists(path):
		push_error("SceneLoader: no scene at %s" % path)
		return
	_path = path
	_loading = true
	begin(title, path.get_file())
	## Wait for an actual draw, not merely the next process tick, before asking
	## the loader to touch the destination. On Web a warm resource cache can
	## finish immediately, and procedural setup can then occupy the main thread
	## before the browser ever composites a process-frame-only overlay.
	await RenderingServer.frame_post_draw
	if not _loading or _path != path:
		return

	## Sub-threads matter here: the dungeon's scene pulls in a deep tree of
	## rooms, props and characters, and loading those dependencies one after
	## another on a single worker is most of the wait.
	ResourceLoader.load_threaded_request(path, "", true)


## Called by an incoming scene that wants the screen kept up while it builds.
## A no-op when the screen is not up, so a scene run straight from the editor
## behaves exactly as it did before.
func hold() -> void:
	if not visible:
		return
	_held = true
	_held_for = 0.0


## Where the incoming scene has got to, 0 to 1 across its own setup. Mapped into
## the part of the bar left over after the load.
func step(fraction: float, note: String = "") -> void:
	if not visible:
		return
	_target = maxf(_target, LOAD_SHARE + clampf(fraction, 0.0, 1.0) * (1.0 - LOAD_SHARE))
	if note != "":
		_note.text = note


func finish() -> void:
	if not visible:
		return
	_held = false
	_loading = false
	_path = ""
	_target = 1.0
	## Let the bar reach the end before the screen goes, so a fast load reads as
	## a load rather than as a flicker.
	var close := create_tween()
	close.tween_interval(0.12)
	close.tween_property(_veil, "modulate:a", 0.0, 0.18)
	close.tween_callback(func() -> void:
		_set_visible(false)
		_veil.modulate.a = 1.0)


func _process(delta: float) -> void:
	if _loading:
		_poll()
	if _held:
		_held_for += delta
		if _held_for > HOLD_LIMIT:
			push_error("SceneLoader: %.0fs with no finish() — releasing" % HOLD_LIMIT)
			finish()

	if visible:
		_shown = move_toward(_shown, _target, delta * EASE_SPEED * maxf(_target - _shown, 0.15))
		_lay_out()


func _poll() -> void:
	var progress: Array = []
	match ResourceLoader.load_threaded_get_status(_path, progress):
		ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			if not progress.is_empty():
				_target = float(progress[0]) * LOAD_SHARE
		ResourceLoader.THREAD_LOAD_LOADED:
			_target = LOAD_SHARE
			_swap(ResourceLoader.load_threaded_get(_path) as PackedScene)
		ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			push_error("SceneLoader: failed to load %s" % _path)
			_loading = false
			finish()


func _swap(packed: PackedScene) -> void:
	_loading = false
	if packed == null:
		push_error("SceneLoader: %s is not a PackedScene" % _path)
		finish()
		return
	## Flagged before the swap so an incoming _ready that calls hold() is not
	## mistaken for a scene that never did.
	_held = false
	get_tree().change_scene_to_packed(packed)
	_release_unless_held()


## The swap is deferred, so the new scene's _ready has not run yet. Two frames
## later it has, and anything that wanted the screen has said so.
func _release_unless_held() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if not _held:
		finish()
