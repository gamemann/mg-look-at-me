extends Node3D

## The house: every level at once, side by side, every player on whichever level they are on,
## and the witches. Headless; [LmClient] draws.
##
## [b]A server that never ends.[/b] Nobody waits for a round: a player arrives in the lobby
## (level 1's start room), goes through the levels at their own pace, and the next person can
## arrive at any moment. So there are no rounds and no sides, only each player's own progress.
##
## [b]Being seen is a meter, not a moment.[/b] Every tick each witch on a player's level asks
## whether she can see them — in range, inside her cone, nothing in the way — and how well:
## nearer is faster, a lit flashlight faster, a crouch or standing still slower. The meter
## climbs while she does and drains after a pause when she does not, and full is caught.

const LmConfig := preload("lm_config.gd")
const LmLevel := preload("lm_level.gd")
const LmPlayer := preload("lm_player.gd")
const LmPaths := preload("lm_paths.gd")

const CHANNEL := "lookatme.game"
const SERVICE := &"lookatme.game"

## Metres between levels laid side by side.
const LEVEL_GAP := 60.0

## The physics layer walls and doors are on, and the one players are on.
const LAYER_WORLD := 1
const LAYER_PLAYERS := 2

## The netcode's numbers, read by the module and the client from here, so both ends agree.
const NET_SNAPSHOT_RATE := 30

## Metres from the origin a position may be: 32 levels side by side reach a long way.
const NET_WORLD_EXTENT := 8192.0

signal said(key: StringName, text: String)
signal took(key: StringName, item_id: String)
signal opened_door(key: StringName, door_id: String)
signal caught(key: StringName)
signal level_done(key: StringName, number: int)
signal won(key: StringName)
signal player_joined(key: StringName)
signal player_left(key: StringName)

@export var authoritative: bool = true
@export var draws: bool = true
@export var self_tick: bool = true
@export var register_service: bool = true

var config: LmConfig = null

## level number -> LmLevel, and the documents by number.
var levels: Dictionary = {}
var documents: Dictionary = {}
var refused: Dictionary = {}

## key -> LmPlayer.
var players: Dictionary = {}

## Keys of everybody who has ever won here, kept in config.winners_file.
var winners: Dictionary = {}

var tick_rate: int = 60
var tick: int = 0


func _init() -> void:
	config = LmConfig.new()


func _ready() -> void:
	var _loaded := config.load_layered("user://cfg/lookatme.json")
	tick_rate = Engine.physics_ticks_per_second

	if authoritative:
		var dir := config.level_directory
		var _n := load_directory(dir if dir.begins_with("res://") or dir.begins_with("user://") else LmPaths.rebase("res://%s" % dir))
		build_levels()
		_read_winners()

	if register_service:
		DotRegistry.register(SERVICE, self)

	set_physics_process(self_tick)
	DotLog.info(CHANNEL, "the house is ready", {"levels": levels.size(), "refused": refused.size()})


func _exit_tree() -> void:
	if register_service:
		DotRegistry.unregister_instance(SERVICE, self)


func load_directory(directory: String) -> int:
	var dir := DirAccess.open(directory)

	if dir == null:
		DotLog.warn(CHANNEL, "no level directory", {"path": directory})
		return 0

	for file in dir.get_files():
		if file.get_extension() != "json":
			continue

		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join(file)))

		if not (parsed is Dictionary) or str((parsed as Dictionary).get("kind", "")) != "level" or int((parsed as Dictionary).get("number", 0)) < 1:
			refused[file] = "not a level document"
			continue

		documents[int(parsed["number"])] = parsed

	return documents.size()


## Builds every level, laid side by side along +X.
func build_levels() -> void:
	for n: int in levels:
		(levels[n] as Node).queue_free()

	levels.clear()
	var numbers: Array = documents.keys()
	numbers.sort()
	var next_x := 0.0

	for n: int in numbers:
		var level := LmLevel.new()
		level.name = "Level_%02d" % n
		add_child(level)
		var built := level.build(documents[n], draws)

		if not built.ok:
			refused["level %d" % n] = built.error.message
			level.queue_free()
			continue

		var lo := INF
		var hi := -INF

		for room_id: String in level.rooms:
			var rect: Rect2 = level.rooms[room_id]["rect"]
			lo = minf(lo, rect.position.x)
			hi = maxf(hi, rect.end.x)

		level.position = Vector3(next_x - lo, 0.0, 0.0)
		next_x += (hi - lo) + LEVEL_GAP
		levels[n] = level


func last_level() -> int:
	var numbers: Array = levels.keys()
	return int(numbers.max()) if not numbers.is_empty() else 0


func level_of(player: LmPlayer) -> LmLevel:
	return levels.get(player.level, null)


# --- People ------------------------------------------------------------------

func join(key: StringName, name_text: String, avatar: DotAvatar = null) -> LmPlayer:
	if players.has(key):
		return players[key]

	var player := LmPlayer.new()
	player.name = "Player_%s" % String(key)
	player.player_key = key
	player.display_name = name_text
	player.avatar = avatar
	player.config = config
	player.tick_rate = tick_rate
	add_child(player)
	players[key] = player
	player.won = winners.has(String(key))
	send_to(player, 1)
	player_joined.emit(key)
	return player


func leave(key: StringName) -> void:
	var player: LmPlayer = players.get(key, null)

	if player == null:
		return

	players.erase(key)
	player.queue_free()
	player_left.emit(key)


## Puts [param player] in the start room of level [param number] with that level's progress
## fresh. What the lobby is, what a catch does under "reset", and what /l does.
func send_to(player: LmPlayer, number: int) -> void:
	var level: LmLevel = levels.get(number, levels.get(1, null))

	if level == null:
		return

	player.level = level.number()
	player.best = maxi(player.best, player.level)
	player.reset_level()
	_apply_doors(player)
	var slot := players.keys().find(player.player_key)
	player.place_at(level.position + level.spawn_point(maxi(slot, 0)), 180.0)


func _apply_doors(player: LmPlayer) -> void:
	var level := level_of(player)
	var rids: Array[RID] = []

	if level != null:
		for door_id: String in player.opened:
			var rid := level.door_rid(door_id)

			if rid.is_valid():
				rids.append(rid)

	player.set_open_doors(rids)


# --- Doing things --------------------------------------------------------------

## What [param key] would interact with now: {"kind": item|door|station, "id", "text"} or {}.
func target_of(key: StringName) -> Dictionary:
	var player: LmPlayer = players.get(key, null)
	var level := level_of(player) if player != null else null

	if level == null or player.caught_left > 0.0:
		return {}

	var eye := player.eye_position() - level.position
	var look := player.look_direction()
	var best := {}
	var best_d := config.reach + 0.6

	for item_id: String in level.items:
		if player.taken.has(item_id):
			continue

		var at: Vector3 = (level.items[item_id]["at"] as Vector3) + Vector3(0, 0.9, 0)
		var d := _reach_to(eye, look, at)

		if d < best_d:
			best_d = d
			best = {"kind": "item", "id": item_id, "text": "Take the %s" % str(level.items[item_id]["doc"]["name"]).to_lower()}

	for station_id: String in level.stations:
		var station: Dictionary = level.stations[station_id]["doc"]

		if player.used.has(station_id) and not _repeatable(station):
			continue

		var d := _reach_to(eye, look, (level.stations[station_id]["at"] as Vector3) + Vector3(0, 0.8, 0))

		if d < best_d:
			best_d = d
			best = {"kind": "station", "id": station_id, "text": str(station.get("verb", "Use it"))}

	for door_id: String in level.doors:
		if player.opened.has(door_id):
			continue

		var d := _reach_to(eye, look, (level.doors[door_id]["centre"] as Vector3) + Vector3(0, 1.2, 0))

		if d < best_d:
			best_d = d
			best = {"kind": "door", "id": door_id, "text": "Open the %s" % str(level.doors[door_id]["doc"].get("label", "door")).to_lower()}

	return best


static func _repeatable(_station: Dictionary) -> bool:
	return false


## Distance to [param at], or INF when it is behind or beside the eye: what you interact with
## is what you are looking at, not what is behind you.
func _reach_to(eye: Vector3, look: Vector3, at: Vector3) -> float:
	var to := at - eye
	var d := to.length()

	if d > config.reach + 0.6 or (d > 0.8 and look.dot(to / d) < 0.55):
		return INF

	return d


## Presses E. Returns the line the player is told.
func interact(key: StringName) -> String:
	var player: LmPlayer = players.get(key, null)
	var target := target_of(key)

	if player == null or target.is_empty():
		return ""

	var level := level_of(player)
	var text := ""

	match str(target["kind"]):
		"item":
			var item_id := str(target["id"])
			player.taken[item_id] = true
			player.holds.append(item_id)
			text = "Took the %s" % str(level.items[item_id]["doc"]["name"]).to_lower()
			_share(player, func(other: LmPlayer) -> void:
				other.taken[item_id] = true
				if not other.holds.has(item_id):
					other.holds.append(item_id))
			took.emit(key, item_id)
		"station":
			text = _use(player, level, str(target["id"]))
		"door":
			text = _open(player, level, str(target["id"]))

	if text != "":
		said.emit(key, text)

	return text


func _use(player: LmPlayer, level: LmLevel, station_id: String) -> String:
	var station: Dictionary = level.stations[station_id]["doc"]
	var needs := str(station.get("needs", ""))

	if needs != "" and not player.holds.has(needs):
		return "You need %s" % _name_of(level, needs)

	if needs != "" and bool(station.get("consumes", false)):
		player.holds.erase(needs)

	player.used[station_id] = true
	var gives := str(station.get("gives", ""))

	if gives != "" and not player.holds.has(gives):
		player.holds.append(gives)

	var opens := str(station.get("opens", ""))

	if opens != "":
		_unlock(player, opens)

	_share(player, func(other: LmPlayer) -> void:
		other.used[station_id] = true
		if opens != "":
			_unlock(other, opens))

	if level.stations[station_id]["node"] is Node3D and str(station.get("kind", "")) == "fire":
		(level.stations[station_id]["node"] as Node3D).visible = not _everyone_used(level, station_id)

	return str(station.get("verb", "Done")) + (": now you have %s" % _name_of(level, gives) if gives != "" else "")


func _open(player: LmPlayer, level: LmLevel, door_id: String) -> String:
	var door: Dictionary = level.doors[door_id]["doc"]
	var lock := str(door.get("lock", ""))

	if lock.begins_with("@"):
		return "It will not open from here"

	if lock != "" and not player.holds.has(lock):
		return "It is locked. You need %s" % _name_of(level, lock)

	_unlock(player, door_id)
	_share(player, func(other: LmPlayer) -> void: _unlock(other, door_id))
	return "Opened the %s" % str(door.get("label", "door")).to_lower()


func _unlock(player: LmPlayer, door_id: String) -> void:
	if player.opened.has(door_id):
		return

	player.opened[door_id] = true
	_apply_doors(player)
	opened_door.emit(player.player_key, door_id)


## Under shared progress, everybody on the same level gets the same effect.
func _share(player: LmPlayer, effect: Callable) -> void:
	if not config.shared_progress:
		return

	for key: StringName in players:
		var other: LmPlayer = players[key]

		if other != player and other.level == player.level:
			effect.call(other)


func _everyone_used(_level: LmLevel, _station_id: String) -> bool:
	return false


func _name_of(level: LmLevel, item_id: String) -> String:
	for item: Dictionary in level.doc.get("items", []):
		if str(item["id"]) == item_id:
			return "the %s" % str(item["name"]).to_lower()

	for station: Dictionary in level.doc.get("stations", []):
		if str(station.get("gives", "")) == item_id:
			return "something from the %s" % str(station["name"]).to_lower()

	return "something"


## The step a player is on: the first in the document they have not done.
func step_of(player: LmPlayer) -> String:
	var level := level_of(player)

	if level == null:
		return ""

	for step: Dictionary in level.doc.get("steps", []):
		var when: Dictionary = step.get("when", {})

		if when.has("holds") and (player.holds.has(str(when["holds"])) or player.taken.has(str(when["holds"]))):
			continue
		if when.has("opened") and player.opened.has(str(when["opened"])):
			continue
		if when.has("used") and player.used.has(str(when["used"])):
			continue

		return str(step["text"])

	return "Get out"


## A typed command: /r (back to the lobby), /l N (a level you have reached). Returns the reply.
func command(key: StringName, text: String) -> String:
	var player: LmPlayer = players.get(key, null)

	if player == null:
		return ""

	var words := text.strip_edges().trim_prefix("/").trim_prefix("!").split(" ", false)

	if words.is_empty():
		return ""

	var verb := words[0].to_lower()

	if verb == "r" or verb == "restart" or verb == "lobby":
		send_to(player, 1)
		return "Back to the lobby"

	if verb.begins_with("l") and (verb.substr(1).is_valid_int() or (words.size() > 1 and words[1].is_valid_int())):
		var n := int(verb.substr(1)) if verb.substr(1).is_valid_int() else int(words[1])

		if not levels.has(n):
			return "There is no level %d" % n

		if n > player.best:
			return "You have not reached level %d yet" % n

		send_to(player, n)
		return "Level %d" % n

	return ""


func set_flashlight(key: StringName, on: bool) -> void:
	var player: LmPlayer = players.get(key, null)

	if player != null:
		player.flashlight = on


# --- The tick ------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	step(delta)


func step(delta: float) -> void:
	tick += 1

	if not authoritative:
		return

	var seconds := float(tick) / float(maxi(tick_rate, 1))

	for key: StringName in players:
		var player: LmPlayer = players[key]

		if player.caught_left > 0.0:
			player.caught_left -= delta

			if player.caught_left <= 0.0:
				_put_back(player)

			continue

		player.simulate(tick, delta)
		_watch(player, seconds, delta)
		_check_exit(player)


func seconds_now() -> float:
	return float(tick) / float(maxi(tick_rate, 1))


## Every witch on [param player]'s level looks for them, and the meter moves.
func _watch(player: LmPlayer, seconds: float, delta: float) -> void:
	var level := level_of(player)

	if level == null:
		return

	var best_rate := 0.0
	var seen := 0

	for i in level.witches.size():
		var rate := exposure(player, level, i, seconds)

		if rate > 0.0:
			seen += 1
			best_rate = maxf(best_rate, rate)

	player.seen_by = seen

	if seen > 0:
		# Two witches watching is worse than one, but not twice as bad: the nearest is most of it.
		player.meter += best_rate * (1.0 + 0.35 * float(seen - 1)) * delta
		player.unseen_for = 0.0
	else:
		player.unseen_for += delta

		if player.unseen_for >= config.decay_delay:
			player.meter = maxf(player.meter - config.decay_rate * delta, 0.0)

	if player.meter >= 1.0:
		player.meter = 1.0
		player.caught_left = maxf(config.caught_seconds, 0.01)
		caught.emit(player.player_key)
		said.emit(player.player_key, "SHE SEES YOU")


## How fast witch [param index] fills [param player]'s meter, per second, or 0 when she cannot
## see them. Public so a suite can ask the question the tick asks.
func exposure(player: LmPlayer, level: LmLevel, index: int, seconds: float) -> float:
	var loop: Dictionary = level.witches[index]
	var pose := level.witch_pose(index, seconds, config.witch_speed_scale, config.witch_head_sweep)
	var eye: Vector3 = level.position + (pose["at"] as Vector3) + Vector3(0, 2.0, 0)
	var target := player.eye_position()
	var to := target - eye
	var sight := float(loop["sight"]) * config.witch_sight_scale * (config.flashlight_sight if player.flashlight else 1.0)
	var distance := to.length()

	if distance > sight or distance < 0.01:
		return 0.0

	var facing := float(pose["facing"]) + float(pose["head"])
	var forward := Vector3(-sin(facing), 0.0, -cos(facing))
	var flat := Vector3(to.x, 0.0, to.z).normalized()
	var half_cone := deg_to_rad(float(loop["cone"]) * config.witch_cone_scale * 0.5)

	if forward.dot(flat) < cos(half_cone):
		return 0.0

	if not _clear_between(eye, target, player):
		return 0.0

	var rate := config.exposure_rate * clampf(1.0 - distance / sight, 0.15, 1.0)

	if player.flashlight:
		rate *= config.flashlight_exposure
	if player.is_crouching():
		rate *= config.crouch_exposure
	if player.horizontal_speed() < 0.3:
		rate *= config.still_exposure

	return rate


## Nothing solid between a witch's eye and a player's: walls, and doors still shut for THAT
## player (one they opened is open for them, and she sees through it).
func _clear_between(from: Vector3, to: Vector3, player: LmPlayer) -> bool:
	var space := get_world_3d().direct_space_state if is_inside_tree() else null

	if space == null:
		return true

	var query := PhysicsRayQueryParameters3D.create(from, to, LAYER_WORLD)
	var exclude: Array[RID] = [player.get_rid()]
	var level := level_of(player)

	for door_id: String in player.opened:
		var rid := level.door_rid(door_id) if level != null else RID()

		if rid.is_valid():
			exclude.append(rid)

	query.exclude = exclude
	return space.intersect_ray(query).is_empty()


func _put_back(player: LmPlayer) -> void:
	var keep := player.holds.duplicate()
	var keep_opened := player.opened.duplicate()
	var keep_used := player.used.duplicate()
	var keep_taken := player.taken.duplicate()
	send_to(player, player.level)

	if config.caught_penalty == 0:
		player.holds.assign(keep)
		player.opened = keep_opened
		player.used = keep_used
		player.taken = keep_taken
		_apply_doors(player)


func _check_exit(player: LmPlayer) -> void:
	var level := level_of(player)

	if level == null or not player.opened.has("exit"):
		return

	if not level.is_out(player.global_position - level.position):
		return

	var done := player.level
	level_done.emit(player.player_key, done)

	if done >= last_level():
		player.won = true
		winners[String(player.player_key)] = Time.get_datetime_string_from_system()
		_write_winners()
		won.emit(player.player_key)
		said.emit(player.player_key, "YOU GOT OUT. ALL OF IT.")
		send_to(player, 1)
		return

	said.emit(player.player_key, "LEVEL %d" % (done + 1))
	send_to(player, done + 1)


func _read_winners() -> void:
	if not FileAccess.file_exists(config.winners_file):
		return

	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(config.winners_file))

	if parsed is Dictionary:
		winners = parsed


func _write_winners() -> void:
	DirAccess.make_dir_recursive_absolute(config.winners_file.get_base_dir())
	var file := FileAccess.open(config.winners_file, FileAccess.WRITE)

	if file != null:
		file.store_string(JSON.stringify(winners, "\t"))
		file.close()
		DotWeb.sync_filesystem()


func describe() -> Dictionary:
	return {"levels": levels.size(), "players": players.size(), "winners": winners.size(), "tick": tick}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["look at me: %s" % describe()])

	for key: StringName in players:
		lines.append("  %s %s" % [(players[key] as LmPlayer).display_name, (players[key] as LmPlayer).describe()])

	return lines
