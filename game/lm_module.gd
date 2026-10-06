extends DotGameModule

## This game, as a module a dedicated server loads. Over dot-game, like the others.
##
## What is this game's: the netcode's numbers, the commands an operator types, where who won is
## kept, and the key a player's progress is kept under. A chat line beginning with / that the
## house understands (/r, /l3) is the house's; everything else goes to chat.
##
## [b]No `class_name`[/b]: a module delivered inside a dot-cloud pack cannot have one.

const LmNetBridge := preload("net/lm_net_bridge.gd")
const LmServices := preload("lm_services.gd")
const LmGame := preload("lm_game.gd")
const LmProgress := preload("lm_progress.gd")
const LmVote := preload("lm_vote.gd")
const LmAvatars := preload("lm_avatars.gd")

## The players' vote for the next house, or null.
var vote: LmVote = null

## Players' numbers and achievements, or null when the server keeps none.
var progress: LmProgress = null


func _module_name() -> String:
	return "lookatme"


func _game_service() -> StringName:
	return LmGame.SERVICE


func _game_missing_hint() -> String:
	return "load scenes/lm_server.tscn as the game scene: it builds the house this module drives"


func _net_config() -> DotNetConfig:
	var config := DotNetConfig.new()
	config.tick_rate = (game as LmGame).tick_rate
	config.snapshot_rate = LmGame.NET_SNAPSHOT_RATE
	config.world_extent = LmGame.NET_WORLD_EXTENT
	# Players are predicted by their owners, as in every first-person game here.
	config.enable_prediction = true
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 64
	return config


func _make_bridge() -> Node:
	var made := LmNetBridge.new()
	# A win and a level reached are kept under the account, so a reconnect is the same person.
	made.key_fn = func(_peer_id: int, session_id: int) -> StringName:
		var session := server.session_by_userid(session_id) if server != null else null
		var uid := session.uid() if session != null else ""
		return StringName("uid:%s" % uid) if uid != "" else &""
	return made


func _make_services() -> Node:
	return LmServices.new()


## Profiles, names and faces: dot-platform's identity over mg-deathrun's one-slot schema, so a
## TMC account walks the house as the avatar it picked on the site. Authentication is the
## host's, as for every game; with it off everybody is a guest with a stock face.
func _make_identity() -> Node:
	var identity_layer := DotPlatformIdentity.new()
	identity_layer.avatar_schema = LmAvatars.schema()
	identity_layer.stock_avatar_fn = LmAvatars.stock_avatar
	identity_layer.avatar_translate_fn = LmAvatars.from_site
	return identity_layer


func _game_load() -> DotResult:
	var world := game as LmGame

	if world == null:
		return DotResult.fail(DotError.CODE_STATE, "The registered game is not the house.")

	add_command("lm_status", _cmd_status, "Show the house and who is on which level")
	add_command("lm_send", _cmd_send, "Send a player to a level: lm_send <name> <level>", DotAdminFlags.CHANGEMAP)
	add_command("lm_winners", _cmd_winners, "List everybody who has got out of this house")
	add_command("lm_house", _cmd_house, "Play another house now: lm_house <id>, or the list with none", DotAdminFlags.CHANGEMAP)

	if bridge != null:
		bridge.connect("say_requested", _on_say_requested)

	_wire_identity()

	_build_vote(world)

	progress = LmProgress.new()
	progress.name = "Progress"
	add_child(progress)
	var made := progress.setup(world, "user://lookatme_achievements", true)

	if not made.ok:
		DotLog.result(CHANNEL, "progress is off", made)
		progress.queue_free()
		progress = null
	else:
		progress.earned.connect(func(key: StringName, title: String, points: int) -> void:
			var peer: int = bridge.call("peer_of", key) if bridge != null else 0

			if peer > 0:
				bridge.call("notice", peer, "Achievement: %s (+%d)" % [title, points]))

	if not world.levels.is_empty():
		var _reported := report_map(str((world.levels[1] as Node).get("doc").get("id", "lm_01")))

	return DotResult.success(null)


## A chat line: the house's when it is one of its commands, the chat router's otherwise.
func _on_say_requested(peer_id: int, channel_id: StringName, text: String) -> void:
	var key: StringName = bridge.call("key_of_peer", peer_id)

	if text.begins_with("/") and key != &"":
		var reply := (game as LmGame).command(key, text)

		if reply != "":
			bridge.call("notice", peer_id, reply)
			return

	if services == null:
		return

	var said: DotResult = services.call("say", peer_id, channel_id, text)

	if not said.ok:
		bridge.call("notice", peer_id, said.error.message)


## dot-vote over the houses: a time limit (house_minutes), rock the vote, nominations. The
## ballot is drawn on clients from a `map_ballot` notice, as every game's map vote is.
func _build_vote(world: LmGame) -> void:
	vote = LmVote.new()
	vote.name = "HouseVote"
	vote.house_minutes = world.config.house_minutes
	vote.houses_fn = func() -> Array:
		var out: Array = []

		for id: StringName in world.houses:
			out.append([id, str(world.houses[id]["name"])])

		return out
	vote.apply_fn = func(id: StringName) -> DotResult:
		return world.change_house(id)
	vote.voters_fn = func() -> Array:
		var out: Array = []

		for key: StringName in world.players:
			var peer: int = bridge.call("peer_of", key) if bridge != null else 0
			var session := server.session_of(peer) if server != null and peer > 0 else null

			if session != null:
				out.append(StringName(str(session.userid)))

		return out
	vote.announce_fn = func(line: String) -> void:
		if server != null:
			server.broadcast_message(line)
	vote.is_admin_fn = func(voter: StringName) -> bool:
		var session := server.session_by_userid(String(voter).to_int()) if server != null else null
		return session != null and session.has_permission(DotAdminFlags.CHANGEMAP)
	vote.ballot_fn = func(state: Dictionary) -> void:
		if server == null:
			return

		for session in server.playing_sessions():
			var data := state.duplicate()
			data["you"] = str(session.userid)
			server.send_notice(session, DotNotice.make(&"", "", float(state.get("seconds", -1.0)), &"map_ballot", data))
	add_child(vote)
	var ready := vote.setup()

	if not ready.ok:
		DotLog.result(CHANNEL, "the house vote; the server stays on its house", ready)
		vote.queue_free()
		vote = null
		return

	DotLog.result(CHANNEL, "the house vote's commands", vote.install_commands(self))
	vote.note_house(world.house_id)
	world.house_changed.connect(func(id: StringName) -> void:
		if vote != null:
			vote.note_house(id))

	if server != null:
		server.client_disconnected.connect(func(session: DotClientSession, _reason: String) -> void:
			if vote != null:
				vote.forget_voter(StringName(str(session.userid))))


func _game_tick(_tick: int, delta: float) -> void:
	if vote != null:
		vote.advance(delta)


func _cmd_house(ctx: DotCmdContext) -> void:
	var world := game as LmGame
	var id := ctx.arg(0)

	if id == "":
		var lines := PackedStringArray(["houses (playing %s)" % String(world.house_id)])

		for key: StringName in world.houses:
			lines.append("  %-10s %s" % [key, world.houses[key]["name"]])

		ctx.reply_lines(lines)
		return

	var changed := world.change_house(StringName(id))

	if not changed.ok:
		ctx.reply_error(changed)
		return

	ctx.reply("Now playing %s." % world.house_name())


func _cmd_status(ctx: DotCmdContext) -> void:
	ctx.reply_lines((game as LmGame).describe_lines())


func _cmd_send(ctx: DotCmdContext) -> void:
	var world := game as LmGame
	var who := ctx.arg(0)
	var n := ctx.arg_int(1, 1)

	for key: StringName in world.players:
		var player: Node = world.players[key]

		if str(player.get("display_name")).to_lower() == who.to_lower():
			player.set("best", maxi(int(player.get("best")), n))
			world.send_to(player, n)
			ctx.reply("%s is on level %d." % [who, n])
			return

	ctx.reply("Nobody called '%s' is here." % who)


func _cmd_winners(ctx: DotCmdContext) -> void:
	var world := game as LmGame
	var lines := PackedStringArray(["winners (%d) of %s" % [world.winners.size(), world.house_name()]])

	for key: String in world.winners:
		lines.append("  %s  %s" % [key, world.winners[key]])

	var everywhere := world.all_winners()

	for house: String in everywhere:
		if house != String(world.house_id) and not (everywhere[house] as Dictionary).is_empty():
			lines.append("  and %d out of %s" % [(everywhere[house] as Dictionary).size(), house])

	ctx.reply_lines(lines)


## Admission finishes after a player is seated, so the real name and face arrive as
## `player_admitted`; a wardrobe change and an operator's rename are the same thing later. All
## three end in [method LmNetBridge.refresh_player], a JOIN every client already applies.
func _wire_identity() -> void:
	var link := bridge as LmNetBridge

	if link == null:
		return

	link.avatar_fn = _avatar_for
	hook_post("player_admitted", _on_profile)
	hook_post("player_avatar_changed", _on_profile)
	hook_post("player_renamed", _on_profile)


## Through the platform module's `player_for`, never the hub by a key made here: the hub keys
## a player by the scoped profile key only admission knows (mg-deathrun found a lookup by any
## other key finds nobody, every time, and reads as "no avatar"). Duck-typed, because a server
## without dot-platform is a configuration.
func _avatar_for(session_id: int) -> DotAvatar:
	var session := server.session_by_userid(session_id) if server != null else null
	var platform: Object = server.modules.get_module("platform") \
		if server != null and server.modules != null else null

	if session != null and platform != null and platform.has_method("player_for"):
		var player: Variant = platform.call("player_for", session)

		if player is Object and (player as Object).get("avatar") is DotAvatar:
			return (player as Object).get("avatar") as DotAvatar

	return null


func _on_profile(event: DotEvent) -> void:
	var session_id := event.get_int("userid")
	var session := server.session_by_userid(session_id) if server != null else null
	var link := bridge as LmNetBridge

	if session == null or link == null:
		return

	var _refreshed := link.refresh_player(session_id, session.display_name, _avatar_for(session_id))
