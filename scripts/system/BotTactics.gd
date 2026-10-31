class_name BotTactics
extends RefCounted

## Which fights an AI teammate picks, per the behaviour chosen for it in
## Roster. BotInput still does the walking and the swinging; this only answers
## "is this monster mine to fight?" and "should I be sneaking right now?".
##
##   AGGRESSIVE  hunts the nearest living monster anywhere on the floor, keeps
##               fighting it until it dies, then finds the next one.
##   DEFENSIVE   monsters that just hurt a human or that a human just struck.
##   STEALTH     while its human sneaks, it sneaks too and only strikes
##               monsters that have not noticed anyone. Otherwise DEFENSIVE.
##   PASSIVE     prioritises revives and healing dances; only fights a monster
##               that directly hurt it.

## How long a blow is remembered when deciding who started it.
const HURT_WINDOW_MS: int = 4000
## Once a fight is joined, how long the bot sees it through after the last
## provocation, so it does not walk away mid-exchange.
const ENGAGE_MS: int = 6000
## A Passive bot's comfort distance from its human; the default follow reach
## is 155.
const PASSIVE_FOLLOW_REACH: float = 105.0
## Enemy states that mean the monster has not noticed anyone yet.
const UNAWARE_STATES: Array[StringName] = [&"idle"]


static func mode_for(body: Node) -> int:
	return Roster.mode_of(int(body.get("slot"))) if body != null else Roster.DEFAULT_BOT_MODE


## True when the bot should match its human's sneaking this frame.
static func sneaking_with(mode: int, body: Node, anchor: Node) -> bool:
	if mode != Roster.BotMode.STEALTH or anchor == null or anchor.get("stealthed") != true:
		return false
	## A bot under attack stops pretending to hide and fights back.
	return not _hurt_recently(body)


## Whether this monster provokes the bot under its mode. Stickiness for a
## fight already joined is BotInput's job; this is only the trigger.
static func provokes(mode: int, body: Node, anchor: Node, enemy: Node) -> bool:
	if mode == Roster.BotMode.AGGRESSIVE:
		return true
	if mode == Roster.BotMode.PASSIVE:
		return _hurt_by(body, enemy)
	if mode == Roster.BotMode.STEALTH:
		if sneaking_with(mode, body, anchor):
			return is_unaware(enemy) and _can_strike_unseen(body)
		return _hurt_by(body, enemy) or _defensive(body, enemy)
	return _defensive(body, enemy)


## A sneaking bot still has to have the meter for the strike.
static func _can_strike_unseen(body: Node) -> bool:
	return float(body.get("sneak")) >= float(body.get("flair_sneak_cost"))


static func is_unaware(enemy: Node) -> bool:
	var machine := enemy.get_node_or_null("FiniteStateMachine") as FiniteStateMachine
	if machine == null or machine.current_state == null:
		return false
	return machine.current_state.name in UNAWARE_STATES


## A sheathed blade is what lets a bot sneak, and keeps a Passive bot from
## looking like it is spoiling for a fight.
static func wants_blade(mode: int, body: Node, anchor: Node, has_target: bool) -> bool:
	if sneaking_with(mode, body, anchor):
		return false
	if mode == Roster.BotMode.PASSIVE:
		return has_target
	return true


static func follow_reach(mode: int, default_reach: float) -> float:
	return PASSIVE_FOLLOW_REACH if mode == Roster.BotMode.PASSIVE else default_reach


static func _defensive(body: Node, enemy: Node) -> bool:
	if _hurt_any_human(body, enemy):
		return true
	if enemy.has_method("last_hit_slot"):
		var slot: int = enemy.last_hit_slot(HURT_WINDOW_MS)
		return slot >= 0 and not Roster.is_ai_controlled(slot)
	return false


static func _hurt_by(body: Node, enemy: Node) -> bool:
	return body.has_method("hurt_recently_by") and body.hurt_recently_by(enemy, HURT_WINDOW_MS)


static func _hurt_recently(body: Node) -> bool:
	return body.has_method("attacker_recent") and body.attacker_recent(HURT_WINDOW_MS) != null


static func _hurt_any_human(body: Node, enemy: Node) -> bool:
	if not body.is_inside_tree():
		return false
	for human in Roster.bodies(body.get_tree()):
		if Roster.is_ai_controlled(int(human.get("slot"))):
			continue
		if _hurt_by(human, enemy):
			return true
	return false
