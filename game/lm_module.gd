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


func _make_identity() -> Node:
	return null


func _game_load() -> DotResult:
	var world := game as LmGame

	if world == null:
		return DotResult.fail(DotError.CODE_STATE, "The registered game is not the house.")

	add_command("lm_status", _cmd_status, "Show the house and who is on which level")
	add_command("lm_send", _cmd_send, "Send a player to a level: lm_send <name> <level>", DotAdminFlags.CHANGEMAP)
	add_command("lm_winners", _cmd_winners, "List everybody who has got out")

	if bridge != null:
		bridge.connect("say_requested", _on_say_requested)

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
	var lines := PackedStringArray(["winners (%d)" % (game as LmGame).winners.size()])

	for key: String in (game as LmGame).winners:
		lines.append("  %s  %s" % [key, (game as LmGame).winners[key]])

	ctx.reply_lines(lines)
