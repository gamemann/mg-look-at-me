extends Node

## The only file that names both the house and the netcode. Both ends.
##
## [b]Movement is mg-deathrun's[/b]: a [LmNetCommand] a tick into dot-net's input buffer, the
## owner predicting with the same controller the server simulates, snapshots reconciling it.
## [b]Everything else is mg-dangerous-delivery's[/b]: a few JSON events and requests.
##
## [b]What makes this game's prediction work is the doors.[/b] A door is open for the player
## who opened it and nobody else ([LmGame._apply_doors]); the owner's client must exclude the
## same doors from its predicting controller, or it predicts a wall the server walks them
## through and every snapshot drags them back. PROGRESS carries `opened` to the owner, and the
## client applies it before its next predicted tick.

const LmEvent := preload("lm_event.gd")
const LmEvents := preload("lm_events.gd")
const LmNetCommand := preload("lm_net_command.gd")
const LmNetLink := preload("lm_net_link.gd")
const LmPlayerNet := preload("lm_player_net.gd")
const LmRequest := preload("lm_request.gd")

const LmGame := preload("../lm_game.gd")
const LmPlayer := preload("../lm_player.gd")
const LmAvatars := preload("../lm_avatars.gd")

const CHANNEL := "lookatme.net"

const ACK_BYTES := 4

signal hello_received(key: StringName)
signal progress_received(data: Dictionary)
signal said(text: String)
signal notice_received(text: String)
signal chat_received(wire: Dictionary)
signal voice_arrived(payload: PackedByteArray)
signal say_requested(peer_id: int, channel_id: StringName, text: String)

var game: LmGame = null
var net: DotNetManager = null
var link: LmNetLink = null

var local_key: StringName = &""
var voice_relay_fn: Callable = Callable()
var rtt_source: Callable = Callable()

## [code]func(peer_id, session_id) -> StringName[/code]: the key a player's progress and win are
## kept under. The module returns the account uid; unset, the session.
var key_fn: Callable = Callable()

var _key_of_peer: Dictionary = {}
var _peer_of_key: Dictionary = {}
var _ready_peers: Dictionary = {}
var _behaviours: Dictionary = {}
var _game_ticked_for: int = -1
var _client_ticked_for: int = -1
var _levels_expected: int = -1
var _levels_got: Array = []


func attach(p_game: Object, p_net: DotNetManager) -> DotResult:
	var world := p_game as LmGame

	if world == null or p_net == null:
		return DotResult.fail(DotError.CODE_INVALID, "A bridge needs a house and a manager.")

	if world.authoritative != p_net.is_server:
		return DotResult.fail(DotError.CODE_STATE, "The house and the manager disagree about who is authoritative.")

	game = world
	net = p_net
	net.send_fn = _send

	var event := net.messages.register(LmEvent.NAME, LmEvent, DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_CLIENT)

	if not event.ok:
		return event

	var request := net.messages.register(LmRequest.NAME, LmRequest, DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_SERVER)

	if not request.ok:
		return request

	net.messages.on(LmEvent.NAME, _on_event)
	net.messages.on(LmRequest.NAME, _on_request)
	game.self_tick = false
	game.set_physics_process(false)

	if net.is_server:
		game.said.connect(func(key: StringName, text: String) -> void: _tell_key(key, LmEvents.Kind.SAY, {"text": text}))
		for changed in [game.took, game.opened_door]:
			changed.connect(func(key: StringName, _what: String) -> void: _send_progress(key))
		game.caught.connect(_send_progress)
		game.level_done.connect(func(key: StringName, _n: int) -> void: _send_progress.call_deferred(key))
		game.player_left.connect(func(key: StringName) -> void: _broadcast(LmEvents.Kind.LEAVE, {"key": String(key)}))

	return DotResult.success(true)


func open_link(parent: Node) -> void:
	if parent == null or link != null:
		return

	link = LmNetLink.attached_to(parent, self, net != null and net.is_server)


func _send(peer_id: int, payload: PackedByteArray, delivery: int) -> void:
	if link == null:
		return

	if delivery == DotNetMessage.Delivery.UNRELIABLE:
		link.send_snapshot(peer_id, payload)
	elif net.is_server:
		link.send_event(peer_id, payload)
	else:
		link.send_request(payload)


static func session_key(session_id: int) -> StringName:
	return StringName("s%d" % session_id)


# --- Server: people --------------------------------------------------------------

func add_player(peer_id: int, session_id: int, display_name: String) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server adds players.")

	var key: StringName = key_fn.call(peer_id, session_id) if key_fn.is_valid() else session_key(session_id)

	if key == &"":
		key = session_key(session_id)

	_key_of_peer[peer_id] = key
	_peer_of_key[key] = peer_id
	var player := game.join(key, display_name, LmAvatars.stock_avatar(key))
	_build_entity(player, peer_id)
	return DotResult.success(key)


func remove_peer(peer_id: int) -> void:
	var key: StringName = _key_of_peer.get(peer_id, &"")
	_key_of_peer.erase(peer_id)
	_ready_peers.erase(peer_id)

	if key == &"":
		return

	_peer_of_key.erase(key)
	var behaviour: LmPlayerNet = _behaviours.get(key, null)
	_behaviours.erase(key)

	if behaviour != null and behaviour.identity != null and net.registry.has(behaviour.identity.net_id):
		net.registry.unregister(behaviour.identity.net_id)

	game.leave(key)

	if net.peers().has(peer_id):
		var _gone := net.remove_peer(peer_id)


func key_of_peer(peer_id: int) -> StringName:
	return _key_of_peer.get(peer_id, &"")


func peer_of(key: StringName) -> int:
	return int(_peer_of_key.get(key, 0))


## Behaviour before identity: [DotNetIdentity] collects its behaviours in `_ready`.
func _build_entity(player: LmPlayer, peer_id: int, net_id: int = 0) -> DotNetIdentity:
	var behaviour := LmPlayerNet.new()
	behaviour.name = "Net"
	behaviour.player = player
	behaviour.bridge = self
	player.add_child(behaviour)
	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = peer_id
	# SHARED: the server corrects, the owner predicts. Walking a dark corridor a round trip
	# behind your own keys is the thing nobody forgives a first-person game.
	identity.authority = DotNetIdentity.Authority.SHARED
	identity.always_relevant = true
	player.add_child(identity)
	var registered := net.registry.register(identity, net_id, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a player", {"error": str(registered.error)})

	_behaviours[player.player_key] = behaviour
	behaviour.pull()
	return identity


func _admit(peer_id: int) -> void:
	var key: StringName = _key_of_peer.get(peer_id, &"")

	if key == &"":
		return

	_ready_peers[peer_id] = true

	if not net.peers().has(peer_id):
		net.add_peer(peer_id)

	var numbers: Array = game.levels.keys()
	numbers.sort()
	_tell(peer_id, LmEvents.Kind.HELLO, {
		"you": String(key), "tick_rate": game.tick_rate, "tick": net.clock.tick, "levels": numbers.size(),
		"config": {"allow_third_person": game.config.allow_third_person, "witch_speed_scale": game.config.witch_speed_scale,
			"witch_sight_scale": game.config.witch_sight_scale, "witch_cone_scale": game.config.witch_cone_scale,
			"witch_head_sweep": game.config.witch_head_sweep, "reach": game.config.reach,
			"flashlight_range": game.config.flashlight_range, "flashlight_angle": game.config.flashlight_angle},
	})

	for n: int in numbers:
		_tell(peer_id, LmEvents.Kind.LEVEL, game.documents[n])

	for other: StringName in _behaviours:
		_tell(peer_id, LmEvents.Kind.JOIN, _join_body(other))

	_broadcast(LmEvents.Kind.JOIN, _join_body(key))
	_send_progress(key)


func _join_body(key: StringName) -> Dictionary:
	var behaviour: LmPlayerNet = _behaviours.get(key, null)

	if behaviour == null or behaviour.identity == null:
		return {}

	return {"key": String(key), "name": behaviour.player.display_name, "net_id": behaviour.identity.net_id,
		"skin": LmAvatars.skin_index(behaviour.player.avatar)}


func _send_progress(key: StringName) -> void:
	var player: LmPlayer = game.players.get(key, null)

	if player == null:
		return

	_tell_key(key, LmEvents.Kind.PROGRESS, {
		"level": player.level, "best": player.best, "won": player.won, "holds": player.holds,
		"opened": player.opened.keys(), "used": player.used.keys(), "taken": player.taken.keys(),
	})


# --- Server: the tick ----------------------------------------------------------------

func server_tick(tick: int) -> void:
	_game_ticked_for = -1

	if net != null:
		net.server_tick(tick)

	# A server with nobody on it has no behaviours to call this; the witches keep walking.
	ensure_game_ticked(tick)


func ensure_game_ticked(tick: int) -> void:
	if _game_ticked_for == tick or game == null:
		return

	_game_ticked_for = tick

	for key: StringName in _behaviours:
		var behaviour: LmPlayerNet = _behaviours[key]

		if behaviour.player != null and behaviour.identity != null and behaviour.identity.owner_peer_id > 0:
			behaviour.player.controller.apply_command(behaviour.last_move.duplicate_command())

	# The house's tick is the server's: step() counts one, so it starts one short. The witches
	# are posed from it on both ends, and a house a tick off from its clients is a witch a tick
	# off from where they see her.
	game.tick = tick - 1
	game.step(net.clock.tick_duration())


# --- Requests ----------------------------------------------------------------------

func receive_input(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server takes input.")

	if not _key_of_peer.has(peer_id):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "That peer has no player.")

	if payload.size() <= ACK_BYTES:
		return DotResult.fail(DotError.CODE_PARSE, "Input packet is too short.")

	var _acked := net.receive_ack_payload(peer_id, payload.slice(0, ACK_BYTES))
	var packet := LmNetCommand.new()
	packet.read(DotNetReader.new(payload.slice(ACK_BYTES)))
	return net.input_buffer_for(peer_id).push(packet)


func receive_request(peer_id: int, payload: PackedByteArray) -> DotResult:
	return net.receive(payload, peer_id) if net != null else DotResult.fail(DotError.CODE_STATE, "No manager.")


func receive_event(payload: PackedByteArray) -> DotResult:
	return net.receive(payload, 1) if net != null else DotResult.fail(DotError.CODE_STATE, "No manager.")


func receive_snapshot(payload: PackedByteArray) -> DotResult:
	if net == null or net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only a client receives these.")

	if rtt_source.is_valid():
		net.stats.note_rtt(float(rtt_source.call()))

	return net.receive_snapshot(payload)


func _on_request(message: DotNetMessage) -> void:
	var ask := message as LmRequest

	if ask == null or net == null or not net.is_server:
		return

	var peer_id := ask.sender_peer_id

	match ask.kind:
		LmEvents.Ask.READY:
			_admit(peer_id)
		LmEvents.Ask.ACT:
			var key: StringName = _key_of_peer.get(peer_id, &"")

			if key == &"":
				return

			var args := LmEvents.read_json(ask.reader())

			match str(args.get("action", "")):
				"use":
					var _text := game.interact(key)
				"flashlight":
					game.set_flashlight(key, bool(args.get("on", true)))
				"command":
					var reply := game.command(key, str(args.get("text", "")))
					_tell(peer_id, LmEvents.Kind.SAY, {"text": reply if reply != "" else "Nothing called that"})
					_send_progress(key)
				"say":
					say_requested.emit(peer_id, StringName(str(args.get("channel", "all"))), str(args.get("text", "")))


func notice(peer_id: int, text: String) -> void:
	_tell(peer_id, LmEvents.Kind.SAY, {"text": text, "notice": true})


func _broadcast(kind: int, data: Dictionary) -> void:
	if data.is_empty():
		return

	for peer_id in _ready_peers.keys():
		_tell(int(peer_id), kind, data)


func _tell_key(key: StringName, kind: int, data: Dictionary) -> void:
	var peer := peer_of(key)

	if peer > 0 and _ready_peers.has(peer):
		_tell(peer, kind, data)


## One peer, never zero: `net.send(msg, 0)` is a broadcast in dot-net.
func _tell(peer_id: int, kind: int, data: Dictionary) -> void:
	if peer_id <= 0 or net == null:
		return

	net.send(LmEvent.new(kind, LmEvents.write_json(data)), peer_id)


# --- Client ------------------------------------------------------------------------

func ask_ready() -> void:
	_ask(LmEvents.Ask.READY, {})


func ask_act(action: String, args: Dictionary = {}) -> void:
	var body := args.duplicate()
	body["action"] = action
	_ask(LmEvents.Ask.ACT, body)


func ask_say(channel_id: StringName, text: String) -> void:
	ask_act("say", {"channel": String(channel_id), "text": text})


func _ask(kind: int, data: Dictionary) -> void:
	if net == null or net.is_server:
		return

	net.send(LmRequest.new(kind, LmEvents.write_json(data)), 1)


## One tick on a connected client: the command into the history, predicted, and sent.
func client_tick(tick: int, command: DotFpsCommand) -> void:
	if net == null or net.is_server or game == null:
		return

	var packet := LmNetCommand.new()
	packet.tick = tick
	packet.delta = net.clock.tick_duration()
	packet.move = command if command != null else DotFpsCommand.new()
	net.local_inputs().push(packet)
	var mine: LmPlayerNet = _behaviours.get(local_key, null)

	if mine != null:
		mine.last_move = packet.move

	if link != null:
		var payload := net.encode_ack()
		var writer := DotNetWriter.new()
		packet.write(writer)
		payload.append_array(writer.to_bytes())
		link.send_input(payload)

	if _client_ticked_for != tick:
		_client_ticked_for = tick
		game.tick = tick

		for identity in net.registry.predicted():
			for behaviour in identity.behaviours:
				behaviour._net_simulate(tick, net.clock.tick_duration())


func _on_event(message: DotNetMessage) -> void:
	var event := message as LmEvent

	if event == null or game == null or net == null or net.is_server:
		return

	var data := LmEvents.read_json(event.reader())

	match event.kind:
		LmEvents.Kind.HELLO:
			local_key = StringName(str(data.get("you", "")))
			_levels_expected = int(data.get("levels", 0))
			_levels_got = []
			var settings: Dictionary = data.get("config", {})

			for setting: String in settings:
				if setting in game.config:
					game.config.set(setting, settings[setting])

			if _levels_expected == 0:
				hello_received.emit(local_key)
		LmEvents.Kind.LEVEL:
			_levels_got.append(data)

			if _levels_got.size() == _levels_expected:
				game.documents.clear()

				for doc: Dictionary in _levels_got:
					game.documents[int(doc["number"])] = doc

				game.build_levels()
				hello_received.emit(local_key)
		LmEvents.Kind.JOIN:
			_apply_join(data)
		LmEvents.Kind.LEAVE:
			var key := StringName(str(data.get("key", "")))
			var behaviour: LmPlayerNet = _behaviours.get(key, null)
			_behaviours.erase(key)

			if behaviour != null and behaviour.identity != null and net.registry.has(behaviour.identity.net_id):
				net.registry.unregister(behaviour.identity.net_id)

			game.leave(key)
		LmEvents.Kind.PROGRESS:
			_apply_progress(data)
		LmEvents.Kind.SAY:
			if bool(data.get("notice", false)):
				notice_received.emit(str(data.get("text", "")))
			else:
				said.emit(str(data.get("text", "")))
		LmEvents.Kind.CHAT:
			chat_received.emit(data)


func _apply_join(data: Dictionary) -> void:
	var key := StringName(str(data.get("key", "")))

	if key == &"" or _behaviours.has(key):
		return

	var avatar := LmAvatars.stock_avatar(key)
	var player := game.join(key, str(data.get("name", key)), avatar)
	var mine := key == local_key
	var identity := _build_entity(player, net.local_peer_id if mine else 0, int(data.get("net_id", 0)))

	if mine:
		var _claimed := net.registry.change_owner(identity.net_id, net.local_peer_id)


## The owner's own progress: what to show, and the doors its prediction must walk through.
func _apply_progress(data: Dictionary) -> void:
	var player: LmPlayer = game.players.get(local_key, null)

	if player == null:
		return

	player.level = int(data.get("level", player.level))
	player.best = int(data.get("best", player.best))
	player.won = bool(data.get("won", player.won))
	player.holds.assign(data.get("holds", []))
	player.opened = _set_of(data.get("opened", []))
	player.used = _set_of(data.get("used", []))
	player.taken = _set_of(data.get("taken", []))
	game._apply_doors(player)
	progress_received.emit(data)


static func _set_of(list: Variant) -> Dictionary:
	var out := {}

	if list is Array:
		for id: Variant in list:
			out[str(id)] = true

	return out


# --- Chat and voice: dot-game's services reach the wire through these -----------------

func send_chat(peer_id: int, wire: Dictionary) -> void:
	_tell(peer_id, LmEvents.Kind.CHAT, wire)


func receive_voice(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net != null and net.is_server:
		if voice_relay_fn.is_valid():
			voice_relay_fn.call(peer_id, payload)
	else:
		voice_arrived.emit(payload)

	return DotResult.success(true)


func send_voice_up(payload: PackedByteArray) -> void:
	if link != null:
		link.send_voice(1, payload)


func describe() -> Dictionary:
	return {"server": net != null and net.is_server, "players": _behaviours.size(), "peers": _ready_peers.size(), "local": String(local_key)}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["bridge %s" % describe()])

	if link != null:
		lines.append_array(link.describe_lines())

	return lines
