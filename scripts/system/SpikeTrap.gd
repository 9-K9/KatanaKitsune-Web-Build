class_name SpikeTrap
extends Area2D

## Floor spikes on a cycle: retracted, a telegraph, then out and dangerous.
##
## Runs on a shared phase rather than a Timer so a corridor lined with traps
## fires in unison instead of drifting into a shimmer, and so the offset can be
## set per trap to make a wave.

enum Phase { HIDDEN, WARNING, OUT }

@export var damage: float = 15.0
## Seconds per full cycle.
@export var period: float = 2.6
## How long the spikes stay out within the cycle.
@export var out_time: float = 0.7
## Warning before they come out, so a death always feels readable.
@export var warn_time: float = 0.45
## Shifts this trap along the cycle. The generator staggers these so a row of
## traps rolls like a wave.
@export var phase_offset: float = 0.0
@export var max_health: float = 25.0
@export var retracted_texture: Texture2D
@export var extended_texture: Texture2D
@export var retracted_position: Vector2 = Vector2.ZERO

@onready var sprite: Sprite2D = $Sprite2D

var phase: Phase = Phase.HIDDEN
var _t: float = 0.0
var health: float = 0.0
var _broken: bool = false
var _flash_material: ShaderMaterial
var _flash_tween: Tween
## Everything standing on the trap right now. Damage is applied on the frame
## the spikes emerge, not on entry, so walking across between cycles is safe.
var _occupants: Array[Node2D] = []
var _extended_position: Vector2


func _ready() -> void:
	_extended_position = sprite.position
	health = max_health
	add_to_group("breakable")
	add_to_group("bot_hazard")
	collision_layer = 2
	monitorable = true
	var shader := Shader.new()
	shader.code = Breakable.HIT_FLASH_SHADER
	_flash_material = ShaderMaterial.new()
	_flash_material.shader = shader
	sprite.material = _flash_material
	_t = phase_offset
	body_entered.connect(func(b): if b not in _occupants: _occupants.append(b))
	body_exited.connect(func(b): _occupants.erase(b))
	_set_phase(Phase.HIDDEN)


func _physics_process(delta: float) -> void:
	if _broken:
		return
	_t = fmod(_t + delta, period)
	var next: Phase = Phase.HIDDEN
	if _t >= period - out_time:
		next = Phase.OUT
	elif _t >= period - out_time - warn_time:
		next = Phase.WARNING
	if next != phase:
		_set_phase(next)


func _set_phase(next: Phase) -> void:
	phase = next
	match phase:
		Phase.HIDDEN:
			sprite.modulate = Color(0.55, 0.55, 0.6, 1.0)
			_show_spikes(false)
		Phase.WARNING:
			AudioManager.play_for("sfx_spike_warn", self, -4.0)
			sprite.modulate = Color(1.0, 0.75, 0.4, 1.0)
			_show_spikes(false)
		Phase.OUT:
			AudioManager.play_for("sfx_spike_strike", self)
			sprite.modulate = Color.WHITE
			_show_spikes(true)
			_strike()


func _show_spikes(extended: bool) -> void:
	if extended_texture != null and retracted_texture != null:
		sprite.texture = extended_texture if extended else retracted_texture
		sprite.position = _extended_position if extended else retracted_position
		sprite.scale = Vector2.ONE
	else:
		sprite.scale = Vector2(1.0, 1.0 if extended else 0.35)


func _strike() -> void:
	if _broken:
		return
	for body in _occupants:
		if not is_instance_valid(body):
			continue
		## Hits monsters as readily as the player — a trap the player can bait
		## a mummy onto is more interesting than one only they can trip.
		if body.has_method("take_damage"):
			## Straight up through the floor: there is no facing that meets it,
			## so it ignores guards and stances alike.
			body.take_damage(damage, global_position, false)


func take_damage(amount: float, _from: Vector2 = Vector2.INF,
		_guardable: bool = true) -> void:
	if _broken:
		return
	health -= amount
	if is_instance_valid(_flash_tween):
		_flash_tween.kill()
	_flash_material.set_shader_parameter("flash_amount", 1.0)
	_flash_tween = create_tween()
	_flash_tween.tween_method(func(value: float) -> void:
		_flash_material.set_shader_parameter("flash_amount", value), 1.0, 0.0, 0.16)
	if health > 0.0:
		return
	_broken = true
	LootDrops.breakable(self)
	NetworkManager.announce_world_event("break", self)
	remove_from_group("breakable")
	remove_from_group("bot_hazard")
	set_physics_process(false)
	set_deferred("collision_layer", 0)
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	_occupants.clear()
	var fade := create_tween()
	fade.tween_property(sprite, "modulate:a", 0.0, 0.32)
	fade.tween_callback(queue_free)


func network_break() -> void:
	if _broken:
		return
	health = 0.0
	take_damage(0.0)
