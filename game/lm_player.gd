extends CharacterBody3D

## One person in the house: movement (dot-player-controller's first person, driven by the
## world's tick), a flashlight, and what they carry and have done on the level they are on.
##
## [b]Progress is the player's own[/b] (the brief: everybody does every level themselves, so
## the server never has to end). What they hold, the doors they have opened, the things they
## have used and the items they have taken are fields here, not facts about the level.

const LmConfig := preload("lm_config.gd")
const LmFigure := preload("lm_figure.gd")
const LmAvatars := preload("lm_avatars.gd")

const EYE_HEIGHT := 1.6

var player_key: StringName = &""
var display_name: String = "Player"
var avatar: DotAvatar = null
var config: LmConfig = null
var controller: DotFpsController = null
var sampler: DotFpsSampler = null
var figure: LmFigure = null

## The level they are on (1-based), the highest they have reached, and whether they have
## finished the last one.
var level: int = 1
var best: int = 1
var won: bool = false

var holds: Array[String] = []
var opened: Dictionary = {}
var used: Dictionary = {}
var taken: Dictionary = {}

var flashlight: bool = true

## 0 to 1. Full is caught.
var meter: float = 0.0
var unseen_for: float = 0.0
var seen_by: int = 0

## Seconds left of being caught, before they are put back. 0 when not caught.
var caught_left: float = 0.0

var tick_rate: int = 60


func _ready() -> void:
	collision_layer = 2
	collision_mask = 1
	var shape := CapsuleShape3D.new()
	shape.radius = 0.35
	shape.height = 1.8
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position = Vector3(0, 0.9, 0)
	add_child(collider)

	controller = DotFpsController.new()
	controller.name = "Controller"
	controller.tick_rate = tick_rate
	# External even offline: the world owns the tick, as a dedicated server's does.
	controller.drive = DotFpsController.Drive.EXTERNAL
	controller.tunables = tunables_for(config)
	add_child(controller)


static func tunables_for(config: LmConfig) -> DotFpsTunables:
	var t := DotFpsTunables.new()
	t.max_speed = config.run_speed if config != null else 4.6
	t.gravity = config.gravity if config != null else 18.0
	t.jump_height = config.jump_height if config != null else 0.9
	t.walk_speed_scale = config.walk_speed_scale if config != null else 0.5
	t.can_walk = true
	t.can_sprint = false
	t.can_crouch = true
	t.crouch_speed_scale = 0.45
	t.accelerate = 9.0
	t.friction = 7.0
	t.collision_mask = 1
	return t


func simulate(tick: int, delta: float) -> void:
	if sampler != null:
		controller.apply_command(sampler.sample(delta))

	controller.simulate_tick(tick, delta)
	global_position = controller.state.position


func eye_position() -> Vector3:
	return controller.state.position + Vector3(0.0, EYE_HEIGHT * (0.6 if is_crouching() else 1.0), 0.0)


func look_direction() -> Vector3:
	var view := Basis.from_euler(Vector3(deg_to_rad(controller.state.pitch), deg_to_rad(controller.state.yaw), 0.0))
	return -view.z


func is_crouching() -> bool:
	return controller != null and controller.state.crouch_fraction > 0.5


func horizontal_speed() -> float:
	var v := controller.state.velocity
	return Vector2(v.x, v.z).length()


func place_at(at: Vector3, yaw_degrees: float) -> void:
	global_position = at
	controller.teleport(at, yaw_degrees, 0.0)

	if sampler != null:
		sampler.look_at_angles(yaw_degrees, 0.0)


## The doors this player passes through: their own body plus every door they opened.
func set_open_doors(rids: Array[RID]) -> void:
	if controller == null or controller.body == null:
		return

	var list: Array[RID] = [get_rid()]
	list.append_array(rids)
	controller.body.exclude = list


## A fresh go at a level: nothing held, nothing opened.
func reset_level() -> void:
	holds.clear()
	opened.clear()
	used.clear()
	taken.clear()
	meter = 0.0
	unseen_for = 0.0
	caught_left = 0.0


## What somebody else sees: a Kenney figure in this player's avatar, and a crown over a winner.
func present_body(own_view: bool) -> void:
	if figure == null:
		figure = LmFigure.new()
		figure.name = "Figure"
		add_child(figure)
		var index := LmAvatars.skin_index(avatar)
		figure.build(1.8, LmFigure.ATLASES[clampi(index, 0, LmFigure.ATLASES.size() - 1)], Color.WHITE)

	figure.visible = not own_view
	figure.pose(global_position, deg_to_rad(controller.state.yaw), horizontal_speed())
	var crown: Label3D = get_node_or_null("Crown")

	if won and crown == null:
		crown = Label3D.new()
		crown.name = "Crown"
		crown.text = "♛"
		crown.font_size = 160
		crown.pixel_size = 0.004
		crown.modulate = Color(1.0, 0.82, 0.2)
		crown.outline_modulate = Color(0.3, 0.2, 0.0)
		crown.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		crown.position = Vector3(0, 2.35, 0)
		add_child(crown)

	if crown != null:
		crown.visible = won and not own_view


func describe() -> Dictionary:
	return {
		"key": String(player_key), "level": level, "best": best, "won": won,
		"holds": holds, "opened": opened.keys(), "meter": "%.2f" % meter, "flashlight": flashlight,
	}
