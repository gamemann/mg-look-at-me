extends DotNetBehaviour

## One player on the wire: movement (dot-player-controller's own sync, predicted by the owner),
## plus what everybody needs to draw them and what only they need to play.
##
## mg-deathrun's DrPlayerNet, without the weapons and the round: the same split between the
## server simulating for real and the owner predicting with the same controller.

const LmNetCommand := preload("lm_net_command.gd")
const LmPlayer := preload("../lm_player.gd")

var player: LmPlayer = null
var bridge: Node = null

var net_position: Vector3 = Vector3.ZERO
var net_velocity: Vector3 = Vector3.ZERO
var net_yaw: float = 0.0
var net_pitch: float = 0.0
var net_crouch: float = 0.0
var net_flags: int = 0
var net_modifiers: int = 0

## Which level they are on: everybody's, so a client draws only the people in its own house.
var net_level: int = 1
var net_flashlight: bool = true
var net_won: bool = false
## The owner's alone: how close she is to seeing them, and whether she has.
var net_meter: float = 0.0
var net_caught: bool = false
var net_warp: int = 0

var last_move: DotFpsCommand = DotFpsCommand.new()
var _seen_warp: int = -1


func _register_net_vars() -> void:
	for spec in DotFpsNetSync.state_specs():
		var declaration := replicate(spec["property"], DotNetVar.Type[spec["type"]])

		if int(spec["bits"]) > 0:
			declaration.bits(int(spec["bits"]))
		if bool(spec["interpolated"]):
			declaration.interpolated()
		if spec["property"] == &"net_crouch":
			declaration.range_of(0.0, 1.0)

	replicate(&"net_level", DotNetVar.Type.UINT).bits(7)
	replicate(&"net_flashlight", DotNetVar.Type.BOOL)
	replicate(&"net_won", DotNetVar.Type.BOOL)
	var _meter := replicate(&"net_meter", DotNetVar.Type.FLOAT_RANGE).range_of(0.0, 1.0).bits(8).to_owner_only()
	var _caught := replicate(&"net_caught", DotNetVar.Type.BOOL).to_owner_only()
	replicate(&"net_warp", DotNetVar.Type.UINT).bits(4)


func _net_apply_input(input: DotNetInput, _tick: int) -> void:
	var command := input as LmNetCommand

	if command != null:
		last_move = command.move


func _net_simulate(tick: int, delta: float) -> void:
	if player == null:
		return

	if identity != null and identity.is_authoritative:
		if bridge != null:
			bridge.ensure_game_ticked(tick)
	else:
		# The prediction: the same controller, the same command, the same doors excluded.
		player.controller.apply_command(last_move.duplicate_command())
		player.controller.simulate_tick(tick, delta)

	pull()


func pull() -> void:
	if player == null:
		return

	DotFpsNetSync.pull(player.controller.state, self)
	net_level = clampi(player.level, 0, 127)
	net_flashlight = player.flashlight
	net_won = player.won
	net_meter = clampf(player.meter, 0.0, 1.0)
	net_caught = player.caught_left > 0.0
	net_warp = player.warps & 0xF


func _net_state_applied(_tick: int) -> void:
	if player == null:
		return

	# A teleport (a catch, a level, /r) is a jump the interpolator must not draw as a slide.
	if identity != null and not identity.is_authoritative and not identity.is_predicted():
		if _seen_warp >= 0 and net_warp != _seen_warp and bridge != null:
			var manager: Variant = bridge.get(&"net")

			if manager is DotNetManager and (manager as DotNetManager).interpolator != null:
				(manager as DotNetManager).interpolator.forget(identity.net_id)

	_seen_warp = net_warp
	DotFpsNetSync.push(self, player.controller.state)
	_adopt()

	# Not the node on a predicted entity: the predictor reads the node as what is shown.
	if identity == null or not identity.is_predicted():
		player.global_position = player.controller.state.position


func _net_interpolated(_tick: int) -> void:
	if player == null:
		return

	DotFpsNetSync.push(self, player.controller.state)
	player.global_position = player.controller.state.position


func _adopt() -> void:
	if player == null or identity == null or identity.is_authoritative:
		return

	player.level = net_level
	player.flashlight = net_flashlight
	player.won = net_won
	player.meter = net_meter
	player.caught_left = 1.0 if net_caught else 0.0
