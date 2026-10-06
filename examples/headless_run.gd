extends Node

## The house, headless: every level built and finished, doors that are open for one player and
## shut for another, what a witch can see, being caught, the commands, and winning.
##
##   godot --headless --path . res://examples/headless_run.tscn

const LmGame := preload("res://game/lm_game.gd")
const LmLevel := preload("res://game/lm_level.gd")
const LmPlayer := preload("res://game/lm_player.gd")

const SECTIONS := 8
const CHECKS := 27

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _finished := 0
var game: LmGame = null


func _ready() -> void:
	print("look at me, headless")
	game = LmGame.new()
	game.draws = false
	game.self_tick = false
	game.config.winners_file = "user://test_lookatme_winners.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(game.config.winners_file))
	add_child(game)
	await get_tree().physics_frame

	_test_levels()
	_test_every_level_finishes()
	await _test_doors_are_per_player()
	_test_sight()
	await _test_caught()
	_test_commands()
	await _test_winning()
	_test_shared()

	print("")
	print("%d sections entered, %d finished" % [_entered, _finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	if _entered != SECTIONS or _finished != SECTIONS:
		push_error("%d of %d sections finished, %d declared." % [_finished, _entered, SECTIONS])
		code = 1

	if _passed + _failed != CHECKS:
		push_error("%d checks ran, %d declared." % [_passed + _failed, CHECKS])
		code = 1

	get_tree().quit(code)


func _test_levels() -> void:
	_section("thirty-two levels")
	_check(game.levels.size() == 32 and game.refused.is_empty(), "every document is a level, and none is refused", str(game.refused))
	var doors_placed := true

	for n: int in game.levels:
		var level: LmLevel = game.levels[n]
		if level.doors.size() != (level.doc["doors"] as Array).size():
			doors_placed = false

	_check(doors_placed, "every door sits on a wall its rooms share")
	_check((game.levels[1] as LmLevel).witches.size() == 1 and (game.levels[32] as LmLevel).witches.size() == 6, "one witch on level 1, six on level 32")
	var lobby: Rect2 = (game.levels[1] as LmLevel).rooms[(game.levels[1] as LmLevel).spawn_room()]["rect"]
	var biggest := true

	for n: int in game.levels:
		var level: LmLevel = game.levels[n]
		for id: String in level.rooms:
			if (level.rooms[id]["rect"] as Rect2).get_area() > lobby.get_area():
				biggest = false

	_check(biggest, "the lobby is the biggest room in the game")
	_finished_section()


## Plays every level's logic in the engine, standing in front of each thing and pressing E:
## the documents' puzzles are only as finishable as the game's own interact makes them.
func _test_every_level_finishes() -> void:
	_section("every level can be finished")
	var solver := game.join(&"solver", "Solver")
	var stuck := PackedStringArray()

	for n in range(1, 33):
		game.send_to(solver, n)
		var level: LmLevel = game.levels[n]
		var progress := true

		while progress and not solver.opened.has("exit"):
			progress = false

			for kind in ["item", "station", "door"]:
				for id: String in (level.items if kind == "item" else (level.stations if kind == "station" else level.doors)):
					var at: Vector3 = (level.items[id]["at"] if kind == "item" else (level.stations[id]["at"] if kind == "station" else level.doors[id]["centre"])) as Vector3
					var lift := 0.9 if kind == "item" else (0.8 if kind == "station" else 1.2)
					var before := solver.holds.size() + solver.opened.size() + solver.used.size() + solver.taken.size()
					_stand_before(solver, level, at + Vector3(0, lift, 0))
					var _said := game.interact(&"solver")
					if solver.holds.size() + solver.opened.size() + solver.used.size() + solver.taken.size() > before:
						progress = true

		if not solver.opened.has("exit"):
			stuck.append("%d (%s)" % [n, game.step_of(solver)])

	_check(stuck.is_empty(), "the solver opens the way out of all 32", ", ".join(stuck))
	game.leave(&"solver")
	_finished_section()


## Puts [param player] 1.2 m back from [param at] (level-local), looking straight at it.
func _stand_before(player: LmPlayer, level: LmLevel, at: Vector3) -> void:
	var world_at := level.position + at
	var back := Vector3(0, 0, 1.2)
	var eye := world_at + back
	player.place_at(eye - Vector3(0, player.EYE_HEIGHT, 0), 0.0)
	var to := (world_at - eye).normalized()
	player.controller.state.pitch = rad_to_deg(asin(clampf(to.y, -1.0, 1.0)))
	player.controller.state.yaw = 0.0


func _test_doors_are_per_player() -> void:
	_section("a door is open for whoever opened it")
	var a := game.join(&"a", "A")
	var b := game.join(&"b", "B")
	var level: LmLevel = game.levels[1]
	var door: Dictionary = level.doors["d0"]
	_unlock(a, "d0")
	_check(a.opened.has("d0") and not b.opened.has("d0"), "A opened it; B did not")
	# Both walk at it from the same side for two seconds.
	var normal: Vector3 = door["normal"]
	var start: Vector3 = level.position + (door["centre"] as Vector3) - normal * 2.0
	var yaw := rad_to_deg(atan2(-normal.x, -normal.z))
	a.place_at(start + Vector3(0.0, 0.1, 0.0), yaw)
	b.place_at(start + Vector3(0.0, 0.1, 0.0), yaw)
	var go := DotFpsCommand.new()
	go.yaw = yaw
	go.move = Vector2(0, 1)

	for _i in 120:
		a.controller.apply_command(go)
		b.controller.apply_command(go)
		game.step(1.0 / 60.0)
		await get_tree().physics_frame

	var past_a: float = (a.global_position - level.position - (door["centre"] as Vector3)).dot(normal)
	var past_b: float = (b.global_position - level.position - (door["centre"] as Vector3)).dot(normal)
	_check(past_a > 1.0, "A walks through it", "%.2f m past" % past_a)
	_check(past_b < 0.0, "B walks into it", "%.2f m past" % past_b)
	game.leave(&"b")
	_finished_section()


func _unlock(player: LmPlayer, door_id: String) -> void:
	player.opened[door_id] = true
	game._apply_doors(player)


func _test_sight() -> void:
	_section("what a witch can see")
	var p: LmPlayer = game.players[&"a"]
	game.send_to(p, 8)
	var level: LmLevel = game.levels[8]
	var seconds := 3.0
	var pose := level.witch_pose(0, seconds, game.config.witch_speed_scale, game.config.witch_head_sweep)
	var facing := float(pose["facing"]) + float(pose["head"])
	var ahead := Vector3(-sin(facing), 0, -cos(facing))
	var witch_at: Vector3 = level.position + (pose["at"] as Vector3)
	var room := level.room_at(pose["at"])
	p.place_at(witch_at + ahead * 2.5, 0.0)
	_check(game.exposure(p, level, 0, seconds) > 0.0, "in front of her, near, in the same room: seen", room)
	p.place_at(witch_at - ahead * 2.5, 0.0)
	_check(game.exposure(p, level, 0, seconds) == 0.0, "behind her: not")
	p.place_at(witch_at + ahead * 2.5, 0.0)
	p.flashlight = true
	var lit := game.exposure(p, level, 0, seconds)
	p.flashlight = false
	var dark := game.exposure(p, level, 0, seconds)
	_check(lit > dark and dark > 0.0, "a lit flashlight is seen faster", "%.2f vs %.2f" % [lit, dark])
	p.place_at(witch_at + ahead * (float(level.witches[0]["sight"]) * game.config.witch_sight_scale + 3.0), 0.0)
	_check(game.exposure(p, level, 0, seconds) == 0.0, "beyond her sight: not")
	_check(level.witch_pose(0, 12.5) == level.witch_pose(0, 12.5), "her walk is a pure function of time")
	var again := LmLevel.new()
	add_child(again)
	var _b := again.build(level.doc, false)
	_check(again.witch_pose(1, 40.0)["at"] == level.witch_pose(1, 40.0)["at"], "and every machine that builds the level puts her in the same place")
	again.queue_free()
	_finished_section()


func _test_caught() -> void:
	_section("being caught")
	var p: LmPlayer = game.players[&"a"]
	game.send_to(p, 8)
	var level: LmLevel = game.levels[8]
	p.holds.append("something")
	p.meter = 0.99
	game.config.caught_seconds = 0.2
	# In front of her, re-placed every tick at her own time, until the meter fills: one tick of
	# exposure from 0.99 is not enough on its own, which is the point of a meter.
	var caught := [false]
	game.caught.connect(func(key: StringName) -> void:
		if key == &"a":
			caught[0] = true)

	for _i in 120:
		var seconds := game.seconds_now() + 1.0 / 60.0
		var pose := level.witch_pose(0, seconds, game.config.witch_speed_scale, game.config.witch_head_sweep)
		var facing := float(pose["facing"]) + float(pose["head"])
		p.place_at(level.position + (pose["at"] as Vector3) + Vector3(-sin(facing), 0, -cos(facing)) * 2.0, 0.0)
		game.step(1.0 / 60.0)

		if caught[0]:
			break

	_check(caught[0] and p.caught_left > 0.0, "a full meter is a catch")

	for _i in 20:
		game.step(1.0 / 60.0)

	var home := level.room_at(p.global_position - level.position)
	_check(home == level.spawn_room() and p.meter == 0.0, "and they are put back in the level's start room", home)
	_check(p.holds.is_empty(), "with the level's progress lost, as the server is set")
	p.meter = 0.5
	p.unseen_for = 10.0
	p.place_at(level.position + level.spawn_point(0), 0.0)
	game.step(1.0)
	_check(p.meter < 0.5, "out of sight, the meter drains")
	_finished_section()


func _test_commands() -> void:
	_section("commands")
	var p: LmPlayer = game.players[&"a"]
	p.best = 2
	_check(game.command(&"a", "/l5").begins_with("You have not"), "/l5 before reaching level 5 is refused")
	_check(game.command(&"a", "/l2") == "Level 2" and p.level == 2, "/l2 after reaching it goes there")
	_check(game.command(&"a", "/r") == "Back to the lobby" and p.level == 1, "/r goes back to the lobby")
	_check(game.command(&"a", "/l 2") == "Level 2", "and /l 2 with a space")
	_finished_section()


func _test_winning() -> void:
	_section("getting out")
	var p: LmPlayer = game.players[&"a"]
	game.send_to(p, 1)
	var level: LmLevel = game.levels[1]
	_unlock(p, "exit")
	var exit: Dictionary = level.doors["exit"]
	p.place_at(level.position + (exit["centre"] as Vector3) + (exit["normal"] as Vector3) * 2.0, 0.0)
	game.step(1.0 / 60.0)
	_check(p.level == 2 and p.best == 2, "through the way out is the next level")
	game.send_to(p, 32)
	var last: LmLevel = game.levels[32]
	_unlock(p, "exit")
	var way: Dictionary = last.doors["exit"]
	var winner := [false]
	game.won.connect(func(key: StringName) -> void:
		if key == &"a":
			winner[0] = true)
	p.place_at(last.position + (way["centre"] as Vector3) + (way["normal"] as Vector3) * 2.0, 0.0)
	game.step(1.0 / 60.0)
	_check(winner[0] and p.won and p.level == 1, "out of the last one is a win, and back to the lobby")
	_check(FileAccess.file_exists(game.config.winners_file) and game.winners.has("a"), "kept, so it outlives the server")
	p.present_body(false)
	_check(p.get_node_or_null("Crown") != null and (p.get_node("Crown") as Node3D).visible, "with a crown everybody else sees")
	_finished_section()


func _test_shared() -> void:
	_section("shared progress, when a server wants it")
	var a: LmPlayer = game.players[&"a"]
	var c := game.join(&"c", "C")
	game.send_to(a, 3)
	game.send_to(c, 3)
	game.config.shared_progress = true
	var level: LmLevel = game.levels[3]
	var item_id: String = level.items.keys()[0]
	_stand_before(a, level, (level.items[item_id]["at"] as Vector3) + Vector3(0, 0.9, 0))
	var _said := game.interact(&"a")
	_check(not (a.taken.is_empty() and a.opened.is_empty() and a.used.is_empty()) and c.taken == a.taken and c.opened == a.opened and c.used == a.used,
		"what one does, everybody on the level has", "%s / %s" % [a.describe(), c.describe()])
	game.config.shared_progress = false
	_finished_section()


# --- Harness -----------------------------------------------------------------

func _section(name: String) -> void:
	_entered += 1
	print("")
	print(name)


func _finished_section() -> void:
	_finished += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	else:
		_failed += 1
		var line := what if detail == "" else "%s  (%s)" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)
