class_name BotInput
extends PlayerInput

const THINK_INTERVAL: float = 0.25
const FOLLOW_REACH: float = 155.0
const LEASH: float = 650.0
const NOTICE_REACH: float = 400.0
const ATTACK_REACH: float = 210.0
const ATTACK_INTERVAL: float = 0.85
const TAP_TIME: float = 0.10
const READY_STATES: Array[StringName] = [&"katanaIdle"]
const THREAT_STATES: Array[StringName] = [
	&"Attack", &"Heavy", &"Charge", &"Stomp", &"Crit",
	&"attack", &"heavy", &"charge", &"stomp", &"crit",
]
const EVADE_STATES: Array[StringName] = [&"heavy", &"charge", &"stomp", &"crit"]
## Within the player's 190 reach, but outside two restored bodies even on the
## squashed vertical axis, so standing up never spawns inside the rescuer.
const REVIVE_DISTANCE: float = 160.0
## Sneaking states a stealth strike (`flair`) can be thrown from.
const SNEAK_READY_STATES: Array[StringName] = [&"stealthIdle", &"stealthWalk"]
const DRAWN_STATES: Array[StringName] = [&"katanaIdle", &"katanaWalk", &"katanaRun"]
## Personal space between party members, in ground units (bodies touch at ~70).
const SPACE_RADIUS: float = 130.0
## Crowding above this (0..1 per neighbour) makes an idle bot step aside.
const CROWDED: float = 0.4
## A chosen heading is kept this long unless it swings more than ~45 degrees.
const HEADING_HOLD: float = 0.3
## Standing still this long while trying to move counts as blocked...
const BLOCKED_GRACE: float = 0.2
## ...and a blocked bot waits this long before it picks a new way.
const BLOCKED_WAIT: float = 0.25
## Recovery is deliberately conservative: only a companion that has repeatedly
## failed to make progress while more than a screen away may rejoin the leader.
const RECOVERY_DISTANCE: float = 1200.0
const RECOVERY_FAILURE_TIME: float = 7.5
const RECOVERY_RADII: Array[float] = [150.0, 210.0, 280.0]

var navigation := BotNavigation.new()
var _body: WeakRef
var _anchor: WeakRef
var _target: WeakRef
var _fallen: WeakRef
## Until when the bot sees its current fight through; see BotTactics.ENGAGE_MS.
var _engaged_until_ms: int = 0
var _move := Vector2.ZERO
var _aim := Vector2.ZERO
var _think_left: float = 0.0
var _attack_left: float = 0.0
var _tap_left: float = 0.0
var _draw_left: float = 0.0
var _goal := Vector2.INF
var _repath_left: float = 0.0
var _heading := Vector2.ZERO
var _heading_left: float = 0.0
var _wait_left: float = 0.0
var _blocked_for: float = 0.0
var _failure_for: float = 0.0
var _was_moving: bool = false
var _last_position := Vector2.INF
var _yielding: bool = false
var _yield_heading := Vector2.ZERO
var _edge_frames: Dictionary[String, int] = {}


func _init() -> void:
	super(PlayerInput.BOT)


func bind_body(body: CharacterBody2D) -> void:
	_body = weakref(body)
	navigation.bind_body(body)
	reset()


func _sync() -> void:
	pass


## Decisions tick in physics, states tick in render. An edge must not toggle a
## stance twice when two rendered frames share the same physics snapshot.
func just_pressed(action: String) -> bool:
	if not super.just_pressed(action):
		return false
	return _edge_in_frame("press:" + action)


func just_released(action: String) -> bool:
	if not super.just_released(action):
		return false
	return _edge_in_frame("release:" + action)


func _edge_in_frame(key: String) -> bool:
	var frame := Engine.get_process_frames()
	if not _edge_frames.has(key):
		_edge_frames[key] = frame
	return _edge_frames[key] == frame


func vector() -> Vector2:
	return _move


func aim_vector() -> Vector2:
	return _aim


func reset() -> void:
	_now.clear()
	_was.clear()
	_edge_frames.clear()
	_move = Vector2.ZERO
	_aim = Vector2.ZERO
	_anchor = null
	_target = null
	_fallen = null
	_think_left = 0.0
	_attack_left = 0.0
	_tap_left = 0.0
	_draw_left = 0.0
	_goal = Vector2.INF
	_repath_left = 0.0
	_heading = Vector2.ZERO
	_heading_left = 0.0
	_wait_left = 0.0
	_blocked_for = 0.0
	_failure_for = 0.0
	_was_moving = false
	_last_position = Vector2.INF
	_yielding = false
	_yield_heading = Vector2.ZERO
	navigation.reset()


func update(delta: float) -> void:
	_was = _now
	_now = {}
	_edge_frames.clear()
	_move = Vector2.ZERO
	_aim = Vector2.ZERO
	var body := _body.get_ref() as CharacterBody2D if _body != null else null
	if not is_instance_valid(body) or body.get("is_dead") == true:
		reset()
		return
	var world := body.get_parent()
	if body.get_tree().paused or (world.has_method("bot_controls_active") \
			and not world.bot_controls_active()):
		reset()
		return
	_attack_left = maxf(_attack_left - delta, 0.0)
	_draw_left = maxf(_draw_left - delta, 0.0)
	_tap_left = maxf(_tap_left - delta, 0.0)
	_think_left -= delta
	_repath_left -= delta
	if _think_left <= 0.0:
		_think_left = THINK_INTERVAL
		_choose_anchor(body)
		_choose_target(body)
		_choose_fallen(body)
	_decide(body)
	_steer(body, delta)


func _decide(body: CharacterBody2D) -> void:
	var fallen := _dead(_fallen)
	var anchor := _living(_anchor)
	if anchor == null and fallen == null:
		return
	var target := _living(_target)
	if target != null and anchor != null and _distance(target, anchor) > LEASH:
		target = null
		_target = null
	if body.get("actionBlockInput") == true:
		return
	var state := _state(body)
	var mode := BotTactics.mode_for(body)
	var sneaking := BotTactics.sneaking_with(mode, body, anchor)
	if target != null and fallen == null:
		var target_offset := BotNavigation.ground(target.global_position - body.global_position)
		var target_dist: float = target_offset.length()
		var immediate_threat: bool = target_dist <= ATTACK_REACH and _state(target) in THREAT_STATES
		if immediate_threat or fallen == null:
			## A sneaking bot stalks with the blade sheathed and strikes from
			## cover; anything else fights with the katana out.
			var stalking: bool = sneaking and not immediate_threat
			if stalking and body.get("stealthed") != true:
				if body.get("katana_drawn") == true:
					if _draw_left <= 0.0 and state in DRAWN_STATES:
						_now["Katana"] = true
						_draw_left = 1.0
					return
				if _draw_left <= 0.0:
					_now["Stealth"] = true
					_draw_left = 0.5
				return
			if not stalking and body.get("katana_drawn") != true and _draw_left <= 0.0:
				_now["Katana"] = true
				_draw_left = 1.0
				return
			var offset := target_offset
			var distance: float = target_dist
			_aim = offset.normalized()
			if distance <= ATTACK_REACH and _state(target) in EVADE_STATES:
				var away := -_aim.round()
				var retreat := body.global_position + Vector2(away.x, away.y * 0.5) * 48.0
				if navigation.safe_segment(body.global_position, retreat):
					_move = -_aim
					_goal = Vector2.INF
					navigation.reset()
					return
			var facing := IsoFacing.name_of(_aim.round())
			var in_blade: bool = false
			if distance <= ATTACK_REACH and body.has_method("can_slash_target"):
				in_blade = body.can_slash_target(target, facing)
			if distance <= ATTACK_REACH and in_blade and _visible(body, target):
				navigation.reset()
				_goal = Vector2.INF
				if _state(target) in THREAT_STATES and state in [&"katanaIdle", &"katanaBlock"]:
					_now["Defend"] = true
					return
				var ready: bool = state in SNEAK_READY_STATES if stalking \
						else state in READY_STATES
				if ready and _attack_left <= 0.0:
					_tap_left = TAP_TIME
					_attack_left = ATTACK_INTERVAL
				_now["Attack"] = _tap_left > 0.0
				return
			# Stop at the actual collision surface, not an arbitrary centre distance.
			var travel := target.global_position - body.global_position
			var collision := KinematicCollision2D.new()
			if body.test_move(body.global_transform, travel, collision, 0.5):
				travel = collision.get_travel()
				travel = travel.limit_length(maxf(travel.length() - 2.0, 0.0))
			var approach := body.global_position + travel
			if body.has_method("can_slash_target") and not \
					body.can_slash_target(target, facing, approach):
				approach = _strike_position(body, target, approach)
			_follow(body, approach, false, 2.0)
			return
	if fallen != null:
		var reach: float = _distance(body, fallen)
		if reach <= REVIVE_DISTANCE and _visible(body, fallen):
			navigation.reset()
			_goal = Vector2.INF
			if body.get("katana_drawn") == true:
				if _draw_left <= 0.0 and (state in DRAWN_STATES or state == &""):
					_now["Katana"] = true
					_draw_left = 1.0
				return
			if not (body.get("stealthed") == true or body.get("crouched") == true):
				## Stealth is edge-triggered by the player state machine. A
				## continuous hold can be ignored by a hurt/transition state and
				## then never produce another just_pressed event.
				if _draw_left <= 0.0:
					_now["Stealth"] = true
					_draw_left = 0.5
			return
		_follow(body, fallen.global_position, reach > 240.0, 22.0, REVIVE_DISTANCE)
		return
	## Nothing to fight: match the blade and the sneaking to the mode.
	var drawn: bool = body.get("katana_drawn") == true
	var wants_blade: bool = BotTactics.wants_blade(mode, body, anchor, false)
	if _draw_left <= 0.0:
		if wants_blade and not drawn:
			_now["Katana"] = true
			_draw_left = 1.0
			return
		if not wants_blade and drawn and state in DRAWN_STATES:
			_now["Katana"] = true
			_draw_left = 1.0
			return
		if not drawn and sneaking != (body.get("stealthed") == true):
			_now["Stealth"] = true
			_draw_left = 0.5
			return
	if anchor != null:
		var distance: float = _distance(body, anchor)
		if distance <= BotTactics.follow_reach(mode, FOLLOW_REACH):
			navigation.reset()
			_goal = Vector2.INF
			return
		## Running out of stealth would give the party away.
		_follow(body, anchor.global_position, distance > 340.0 and not sneaking,
				22.0, BotTactics.follow_reach(mode, FOLLOW_REACH))


func _follow(body: CharacterBody2D, goal: Vector2, running: bool,
		stop_distance: float = 22.0, arrival_reach: float = 0.0) -> void:
	if _goal == Vector2.INF or (_repath_left <= 0.0 and \
			BotNavigation.ground(goal - _goal).length() > 96.0) \
			or (navigation.path.is_empty() and not navigation.searching and _repath_left <= 0.0):
		_goal = goal
		_repath_left = 0.75
		navigation.begin(body.global_position, goal, arrival_reach)
	navigation.advance()
	## Skip any near waypoint that the full collision shape can already reach.
	## This smooths the grid path and prevents tiny doorway corrections from
	## making a companion oscillate between adjacent cells.
	while navigation.path.size() > 1 and \
			navigation.safe_segment(body.global_position, navigation.path[1]):
		navigation.path.remove_at(0)
	while not navigation.path.is_empty() and \
			BotNavigation.ground(navigation.path[0] - body.global_position).length() \
			< stop_distance and (navigation.path.size() == 1 or
			navigation.safe_segment(body.global_position, navigation.path[1])):
		navigation.path.remove_at(0)
	if navigation.path.is_empty():
		return
	var offset := BotNavigation.ground(navigation.path[0] - body.global_position)
	var direction := offset.normalized()
	# The player moves in eight rounded directions; validate that exact step.
	var actual := direction.round()
	var ahead := body.global_position + Vector2(actual.x, actual.y * 0.5) \
			* minf(48.0, offset.length() / actual.length())
	if not navigation.safe_segment(body.global_position, ahead):
		var best := Vector2.ZERO
		var alignment: float = 0.05
		for step in BotNavigation.DIRECTIONS:
			var candidate := Vector2(step).normalized()
			var score: float = candidate.dot(direction)
			if score <= alignment:
				continue
			var probe := body.global_position + Vector2(step.x, step.y * 0.5) \
					* minf(24.0, offset.length() / Vector2(step).length())
			if navigation.safe_segment(body.global_position, probe):
				best = candidate
				alignment = score
		if best == Vector2.ZERO:
			_begin_wait()
			return
		direction = best
	_move = direction
	_now["Run"] = running and not body.winded()


## Runs after every decision: keeps party members out of each other's space,
## holds a heading long enough that the sprite stops flickering between
## directions, and parks a blocked bot for a moment before it tries elsewhere.
func _steer(body: CharacterBody2D, delta: float) -> void:
	var position := body.global_position
	var moved: float = BotNavigation.ground(position - _last_position).length() \
			if _last_position != Vector2.INF else INF
	_last_position = position
	if body.get("actionBlockInput") == true or _now.get("Katana", false) \
			or _now.get("Stealth", false):
		_move = Vector2.ZERO
		_was_moving = false
		return
	# Reviving is stationary. Nearby allies must not steer the rescuer away.
	var fallen := _dead(_fallen)
	if fallen != null and _distance(body, fallen) <= REVIVE_DISTANCE and _visible(body, fallen):
		_move = Vector2.ZERO
		_was_moving = false
		return
	var expected: float = maxf(float(body.get("speed")), 1.0) * delta
	if _was_moving and moved < expected * 0.2:
		_blocked_for += delta
		_failure_for += delta
	else:
		_blocked_for = 0.0
		if moved >= expected * 0.5:
			_failure_for = maxf(_failure_for - delta * 2.0, 0.0)
	var anchor := _living(_anchor)
	var following_leader: bool = anchor != null and _living(_target) == null \
			and _dead(_fallen) == null
	if following_leader and _distance(body, anchor) >= RECOVERY_DISTANCE \
			and _failure_for >= RECOVERY_FAILURE_TIME:
		if _recover_near_anchor(body, anchor):
			return
	elif not following_leader or (anchor != null and _distance(body, anchor) < RECOVERY_DISTANCE * 0.75):
		_failure_for = 0.0
	if _wait_left > 0.0:
		_wait_left -= delta
		_move = Vector2.ZERO
		_now.erase("Run")
		if _wait_left <= 0.0:
			navigation.reset()
			_goal = Vector2.INF
			_repath_left = 0.0
	elif _blocked_for >= BLOCKED_GRACE and _move != Vector2.ZERO:
		_begin_wait()
	_was_moving = _move != Vector2.ZERO
	if _wait_left > 0.0:
		return
	var fighting: bool = _now.get("Attack", false) or _now.get("Defend", false)
	var push := Vector2.ZERO if fighting else _separation(body)
	# Contact owns the heading until the neighbour has cleared personal space.
	# If this heading hits a wall, keep still; never hunt for sideways escapes.
	if not _yielding and push.length() >= CROWDED:
		_yielding = true
		_yield_heading = push.normalized().round()
	if _yielding:
		if push.length() < 0.1:
			_yielding = false
			_heading_left = 0.0
		else:
			var ahead := position + Vector2(_yield_heading.x, _yield_heading.y * 0.5) * 16.0
			_move = _yield_heading if navigation.safe_segment(position, ahead) else Vector2.ZERO
			_aim = Vector2.ZERO
			_now.erase("Run")
			_was_moving = _move != Vector2.ZERO
			return
	var wanted := _move
	if wanted == Vector2.ZERO:
		if push.length() < CROWDED:
			_heading_left = 0.0
			return
		## Crowded while standing: walk clear instead of standing in a pile.
		wanted = push.normalized()
		_now["Run"] = false
	_heading_left -= delta
	if _heading_left > 0.0 and _heading != Vector2.ZERO and _heading.dot(wanted) > 0.7:
		wanted = _heading
	else:
		_heading = wanted
		_heading_left = HEADING_HOLD
	var step := wanted.round()
	var ahead := position + Vector2(step.x, step.y * 0.5) * maxf(expected, 1.0)
	if step != Vector2.ZERO and not navigation.safe_segment(position, ahead):
		## Pushed into a wall by a neighbour: hold still rather than jitter.
		_move = Vector2.ZERO
		_heading_left = 0.0
		_was_moving = false
		return
	_move = wanted
	_was_moving = _move != Vector2.ZERO


func _begin_wait() -> void:
	_wait_left = BLOCKED_WAIT
	_blocked_for = 0.0
	_heading_left = 0.0
	_move = Vector2.ZERO
	_now.erase("Run")
	## Rebuild the route after a collision instead of retrying the same stale
	## waypoint. The short wait still gives a sliding door time to open.
	navigation.reset()
	_goal = Vector2.INF
	_repath_left = 0.0


## Finds clear floor beside the human leader and moves a hopelessly stranded
## bot there. Every candidate is collision-checked with the bot's real shape;
## this can never place one inside a wall, prop, closed door, or hazard.
func _recover_near_anchor(body: CharacterBody2D, anchor: Node2D) -> bool:
	for radius in RECOVERY_RADII:
		for direction in BotNavigation.DIRECTIONS:
			var ground_offset := Vector2(direction).normalized() * radius
			var candidate := anchor.global_position + Vector2(ground_offset.x, ground_offset.y * 0.5)
			if not navigation.safe_segment(candidate, candidate):
				continue
			body.global_position = candidate
			body.velocity = Vector2.ZERO
			_failure_for = 0.0
			_blocked_for = 0.0
			_wait_left = 0.0
			_goal = Vector2.INF
			navigation.reset()
			_last_position = candidate
			return true
	## No safe landing spot: keep navigating and try again later.
	_failure_for = RECOVERY_FAILURE_TIME * 0.75
	return false


## Summed repulsion from every living party member inside SPACE_RADIUS, in
## ground units, each contributing 0 at the edge up to 1 when overlapping.
func _separation(body: CharacterBody2D) -> Vector2:
	var push := Vector2.ZERO
	for other in Roster.bodies(body.get_tree()):
		if other == body:
			continue
		var offset := BotNavigation.ground(body.global_position - other.global_position)
		var distance: float = offset.length()
		if distance >= SPACE_RADIUS:
			continue
		var away := offset / distance if distance > 1.0 \
				else Vector2.RIGHT.rotated(float(body.get_instance_id() % 628) * 0.01)
		push += away * (1.0 - distance / SPACE_RADIUS)
	return push


func _strike_position(body: CharacterBody2D, target: Node2D, fallback: Vector2) -> Vector2:
	var best := fallback
	var distance: float = INF
	for direction in BotNavigation.DIRECTIONS:
		var aim := Vector2(direction).normalized()
		var candidate := target.global_position - Vector2(aim.x, aim.y * 0.5) * 150.0
		var facing := IsoFacing.name_of(Vector2(direction))
		var reach: float = BotNavigation.ground(candidate - body.global_position).length()
		if reach >= distance or not navigation.safe_segment(candidate, candidate):
			continue
		if body.can_slash_target(target, facing, candidate):
			best = candidate
			distance = reach
	return best


func _choose_anchor(body: CharacterBody2D) -> void:
	var best: CharacterBody2D = null
	var distance: float = INF
	for candidate in Roster.bodies(body.get_tree()):
		if candidate == body or Roster.is_ai_controlled(int(candidate.get("slot"))):
			continue
		if int(candidate.get("slot")) == Roster.controlled_bot_slot:
			best = candidate
			break
		var reach: float = _distance(body, candidate)
		if reach < distance:
			best = candidate
			distance = reach
	var previous := _living(_anchor)
	if best != previous and _dead(_fallen) == null:
		navigation.reset()
		_goal = Vector2.INF
	_anchor = weakref(best) if best != null else null


func _choose_target(body: CharacterBody2D) -> void:
	var anchor := _living(_anchor)
	var best: Node2D = null
	var distance: float = NOTICE_REACH
	var mode := BotTactics.mode_for(body)
	var previous := _living(_target)
	var now := Time.get_ticks_msec()
	## A stalk is abandoned the moment the monster notices; any other fight is
	## seen through for a few seconds after the last provocation.
	var stick: bool = now < _engaged_until_ms \
			and not BotTactics.sneaking_with(mode, body, anchor)
	if anchor != null and _distance(body, anchor) <= LEASH:
		for candidate in body.get_tree().get_nodes_in_group("enemy"):
			if not (candidate is CharacterBody2D) or candidate.get("is_dead") == true \
					or candidate.is_queued_for_deletion():
				continue
			var reach: float = _distance(body, candidate)
			if reach < distance and _distance(candidate, anchor) <= LEASH \
					and _visible(body, candidate) \
					and ((stick and candidate == previous)
						or BotTactics.provokes(mode, body, anchor, candidate)):
				best = candidate
				distance = reach
	if best != null and BotTactics.provokes(mode, body, anchor, best):
		_engaged_until_ms = now + BotTactics.ENGAGE_MS
	_target = weakref(best) if best != null else null


func _visible(body: CharacterBody2D, target: Node2D) -> bool:
	var ray := PhysicsRayQueryParameters2D.create(body.global_position,
			target.global_position, body.collision_mask)
	ray.exclude = [body.get_rid()]
	for other in Roster.bodies(body.get_tree()):
		if other != body:
			ray.exclude.append(other.get_rid())
	var hit := body.get_world_2d().direct_space_state.intersect_ray(ray)
	return hit.is_empty() or hit["collider"] == target


func _living(reference: WeakRef) -> Node2D:
	var node := reference.get_ref() as Node2D if reference != null else null
	return node if is_instance_valid(node) and not node.is_queued_for_deletion() \
			and node.get("is_dead") != true else null


func _dead(reference: WeakRef) -> Node2D:
	var node := reference.get_ref() as Node2D if reference != null else null
	return node if is_instance_valid(node) and not node.is_queued_for_deletion() \
			and node.get("is_dead") == true else null


func _choose_fallen(body: CharacterBody2D) -> void:
	if Roster.controlled_bot_slot >= 0:
		if _fallen != null:
			navigation.reset()
			_goal = Vector2.INF
		_fallen = null
		return
	var previous := _dead(_fallen) as CharacterBody2D
	# A detour can temporarily take us nearer another body. Finish this rescue
	# instead of swapping goals at every corner of the route.
	if previous != null and not Roster.is_bot(int(previous.get("slot"))):
		return
	var best: CharacterBody2D = null
	var distance: float = INF
	for candidate in body.get_tree().get_nodes_in_group("player"):
		if candidate == body or not (candidate is CharacterBody2D):
			continue
		if candidate.get("is_dead") != true or candidate.is_queued_for_deletion():
			continue
		# Humans are always rescued before fallen AI teammates.
		var reach: float = _distance(body, candidate)
		if Roster.is_bot(int(candidate.get("slot"))):
			reach += 1.0e12
		if reach < distance:
			best = candidate
			distance = reach
	if previous != null and best != null and Roster.is_bot(int(best.get("slot"))):
		best = previous
	if best != previous:
		navigation.reset()
		_goal = Vector2.INF
	_fallen = weakref(best) if best != null else null


func _state(body: Node2D) -> StringName:
	var machine := body.get_node_or_null("FiniteStateMachine") as FiniteStateMachine
	return machine.current_state.name if machine != null and machine.current_state != null else &""


func _distance(a: Node2D, b: Node2D) -> float:
	return BotNavigation.ground(a.global_position - b.global_position).length()
