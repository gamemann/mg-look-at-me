extends Node

## A server and a client in one process, over the link's loopback, each in its own physics
## world, with the client predicting its own player as a real one does.
##
##   godot --headless --path . res://examples/headless_net.tscn

const LmGame := preload("res://game/lm_game.gd")
const LmNetBridge := preload("res://game/net/lm_net_bridge.gd")
const LmPlayer := preload("res://game/lm_player.gd")
const LmLevel := preload("res://game/lm_level.gd")

const SECTIONS := 6
const CHECKS := 22
const LmAvatars := preload("res://game/lm_avatars.gd")
const CLIENT_PEER := 7
const SESSION := 42
const INPUT_LEAD := 2

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _finished := 0

var _server_game: LmGame = null
var _client_game: LmGame = null
var _server_net: DotNetManager = null
var _client_net: DotNetManager = null
var _server_bridge: LmNetBridge = null
var _client_bridge: LmNetBridge = null
var _to_client: Array = []
var _to_server: Array = []
var _tick := 0
var _key: StringName = &""


func _ready() -> void:
	print("look at me, over the wire")

	if await _build():
		await _test_joining()
		await _test_walking()
		await _test_a_door_for_one()
		await _test_the_witches_agree()
		await _test_progress_and_meter()

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


func _make_game(authoritative: bool, parent: Node) -> LmGame:
	var world := LmGame.new()
	world.name = "World"
	world.authoritative = authoritative
	world.draws = false
	world.register_service = false
	world.self_tick = false
	world.config.winners_file = "user://test_net_winners.json"
	parent.add_child(world)
	return world


func _make_manager(is_server: bool, parent: Node) -> DotNetManager:
	var manager := DotNetManager.new()
	manager.name = "Net"
	manager.is_server = is_server
	manager.local_peer_id = 1 if is_server else CLIENT_PEER
	manager.auto_tick = false
	manager.config_file = ""
	var config := DotNetConfig.new()
	config.tick_rate = 60
	config.snapshot_rate = LmGame.NET_SNAPSHOT_RATE
	config.world_extent = LmGame.NET_WORLD_EXTENT
	config.enable_prediction = true
	config.enable_lag_compensation = false
	manager.config = config
	parent.add_child(manager)
	var _s := manager.setup()
	return manager


func _build() -> bool:
	_section("both halves")
	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)
	var client_view := SubViewport.new()
	client_view.own_world_3d = true
	client_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(client_view)
	var client_side := Node.new()
	client_side.name = "ClientSide"
	client_view.add_child(client_side)
	_server_game = _make_game(true, server_side)
	_client_game = _make_game(false, client_side)
	await get_tree().process_frame
	_check(_server_game.levels.size() == 32 and _client_game.levels.is_empty(), "the server reads the levels; the client reads none")
	_server_net = _make_manager(true, server_side)
	_client_net = _make_manager(false, client_side)
	_server_bridge = LmNetBridge.new()
	_server_bridge.name = "Bridge"
	server_side.add_child(_server_bridge)
	_client_bridge = LmNetBridge.new()
	_client_bridge.name = "Bridge"
	client_side.add_child(_client_bridge)
	var a := _server_bridge.attach(_server_game, _server_net)
	var b := _client_bridge.attach(_client_game, _client_net)
	_server_bridge.open_link(server_side)
	_client_bridge.open_link(client_side)
	_server_net.messages.seal()
	_client_net.messages.seal()
	_check(a.ok and b.ok and _server_net.messages.schema_hash() == _client_net.messages.schema_hash(), "both attach, on one schema")
	_server_bridge.link.loopback = func(method: StringName, _peer: int, payload: PackedByteArray) -> void:
		_to_client.append({"method": method, "payload": payload})
	_client_bridge.link.loopback = func(method: StringName, _peer: int, payload: PackedByteArray) -> void:
		_to_server.append({"method": method, "payload": payload})
	_client_bridge.rtt_source = func() -> float: return 40.0
	var _s := _server_net.start()
	var _c := _client_net.start()
	_finished_section()
	return _failed == 0


func _test_joining() -> void:
	_section("a client joins")
	var seated := _server_bridge.add_player(CLIENT_PEER, SESSION, "Ada")
	_key = seated.value if seated.ok else &""
	_client_bridge.ask_ready()
	_exchange()
	await _steps(30)
	_check(_client_bridge.local_key == _key and _client_game.levels.size() == 32, "it is told who it is, and builds all 32 levels from the documents")
	var mine: LmPlayer = _client_game.players.get(_key, null)
	var identity: DotNetIdentity = mine.get_node_or_null("Identity") if mine != null else null
	_check(identity != null and identity.is_predicted(), "and predicts its own player")
	_check(absf(_client_game.levels[16].position.x - _server_game.levels[16].position.x) < 0.001, "its house is laid out where the server's is")
	var server_mine: LmPlayer = _server_game.players.get(_key, null)
	_check(mine != null and server_mine != null and LmAvatars.skin_index(mine.avatar) == LmAvatars.skin_index(server_mine.avatar),
		"it draws its player in the face the server seated them with")
	# The platform's answer arriving after the seat: another skin, and the same JOIN again.
	var other := DotAvatar.make(LmAvatars.SCHEMA_ID)
	var next_skin: StringName = LmAvatars.SKINS[(maxi(LmAvatars.skin_index(server_mine.avatar), 0) + 1) % LmAvatars.SKINS.size()]
	other.set_part(LmAvatars.SLOT_SKIN, next_skin)
	var refreshed := _server_bridge.refresh_player(SESSION, "Ada Lovelace", other)
	_exchange()
	await _steps(5)
	mine = _client_game.players.get(_key, null)
	_check(refreshed and mine != null and mine.avatar.part_in(LmAvatars.SLOT_SKIN) == next_skin and mine.display_name == "Ada Lovelace"
		and _client_game.players.size() == 1,
		"a face and a name that arrive later replace the first ones, and are not a second player",
		"%s %s" % [mine.avatar.to_dict() if mine != null else null, mine.display_name if mine != null else ""])
	_finished_section()


func _test_walking() -> void:
	_section("walking, predicted")
	var server_player: LmPlayer = _server_game.players[_key]
	var start := server_player.global_position
	var go := DotFpsCommand.new()
	go.yaw = 90.0
	go.move = Vector2(0, 1)
	await _steps(90, go)
	await _steps(15)
	var moved := server_player.global_position.distance_to(start)
	_check(moved > 2.0, "the client's keys move the server's player", "%.1f m" % moved)
	var mine: LmPlayer = _client_game.players[_key]
	var gap := mine.controller.state.position.distance_to(server_player.controller.state.position)
	_check(gap < 0.3, "and its prediction ends where the server does", "%.3f m" % gap)
	_finished_section()


## The point of this game's prediction: a door open for one player only, walked through on both
## ends without the client being dragged back.
func _test_a_door_for_one() -> void:
	_section("a door that is open only for this player")
	var server_player: LmPlayer = _server_game.players[_key]
	var level: LmLevel = _server_game.levels[1]
	var door: Dictionary = level.doors["d1"] if level.doors.has("d1") else level.doors["d0"]
	var door_id := "d1" if level.doors.has("d1") else "d0"
	_server_game._unlock(server_player, door_id)
	_exchange()
	await _steps(4)
	var mine: LmPlayer = _client_game.players[_key]
	_check(mine.opened.has(door_id), "the client is told it opened it")
	_check(mine.controller.body.exclude.has(_client_game.levels[1].door_rid(door_id)), "and its own controller now walks through it")
	var normal: Vector3 = door["normal"]
	var yaw := rad_to_deg(atan2(-normal.x, -normal.z))
	var at := level.position + (door["centre"] as Vector3) - normal * 2.0 + Vector3(0, 0.1, 0)
	server_player.place_at(at, yaw)
	_exchange()
	await _steps(20)
	var go := DotFpsCommand.new()
	go.yaw = yaw
	go.move = Vector2(0, 1)
	await _steps(80, go)
	await _steps(15)
	var past: float = (server_player.global_position - level.position - (door["centre"] as Vector3)).dot(normal)
	_check(past > 1.0, "the server walks it through", "%.2f m" % past)
	var gap := mine.controller.state.position.distance_to(server_player.controller.state.position)
	_check(gap < 0.3, "and the client was predicting the same walk, not a wall", "%.3f m" % gap)
	_finished_section()


func _test_the_witches_agree() -> void:
	_section("the witches agree")
	var ok := true

	for n in [1, 9, 32]:
		var a: LmLevel = _server_game.levels[n]
		var b: LmLevel = _client_game.levels[n]
		for i in a.witches.size():
			var pa := a.witch_pose(i, _server_game.seconds_now())
			var pb := b.witch_pose(i, _server_game.seconds_now())
			if (pa["at"] as Vector3).distance_to(pb["at"]) > 0.001:
				ok = false
	_check(ok, "every witch is where the server has her, posed from the clock alone")
	_check(absi(_client_game.tick - _server_game.tick) <= INPUT_LEAD + 6, "and the clocks agree", "%d vs %d" % [_client_game.tick, _server_game.tick])
	_finished_section()


func _test_progress_and_meter() -> void:
	_section("progress and the meter")
	var server_player: LmPlayer = _server_game.players[_key]
	server_player.meter = 0.6
	await _steps(6)
	var mine: LmPlayer = _client_game.players[_key]
	# Against the server's own value: out of sight it drains while the snapshot travels.
	_check(server_player.meter > 0.5 and absf(mine.meter - server_player.meter) < 0.03, "the meter reaches its owner",
		"%.2f vs %.2f" % [mine.meter, server_player.meter])
	_client_bridge.ask_act("flashlight", {"on": false})
	_exchange()
	await _steps(6)
	_check(not server_player.flashlight, "the flashlight switch reaches the server")
	server_player.best = 3
	_client_bridge.ask_act("command", {"text": "/l3"})
	_exchange()
	await _steps(10)
	_exchange()
	await _steps(4)
	_check(server_player.level == 3 and mine.level == 3, "/l3 moves them on both ends", "%d / %d" % [server_player.level, mine.level])
	_check(mine.opened.is_empty() and mine.controller.body.exclude.size() == 1, "with a fresh level: no doors open for them there")
	var _changed := _server_game.change_house(&"asylum")
	_exchange()
	await _steps(6)
	_exchange()
	await _steps(4)
	_check(_client_game.levels.size() == 16 and _client_game.house_id == &"asylum" and mine.level == 1,
		"a new house reaches the client: it rebuilds sixteen levels and stands in the new lobby (%d, %s, %d)" % [_client_game.levels.size(), _client_game.house_id, mine.level])
	_server_bridge.remove_peer(CLIENT_PEER)
	_check(not _server_game.players.has(_key), "a peer that leaves takes its player with it")
	_check(_server_net.registry.all().is_empty(), "and its entity")
	_finished_section()


# --- Harness -----------------------------------------------------------------

func _flush() -> void:
	var to_client := _to_client.duplicate()
	var to_server := _to_server.duplicate()
	_to_client.clear()
	_to_server.clear()

	for entry in to_client:
		_client_bridge.link.deliver(entry["method"], 1, entry["payload"])

	for entry in to_server:
		_server_bridge.link.deliver(entry["method"], CLIENT_PEER, entry["payload"])


func _exchange() -> void:
	_flush()
	_flush()


func _step(command: DotFpsCommand = null) -> void:
	_tick += 1
	var _t := _client_net.clock.advance(1.0 / 60.0)
	_server_bridge.server_tick(_tick)
	_flush()
	_client_bridge.client_tick(_tick + INPUT_LEAD, command if command != null else DotFpsCommand.new())
	_flush()
	await get_tree().physics_frame


func _steps(count: int, command: DotFpsCommand = null) -> void:
	for _i in count:
		await _step(command)


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
