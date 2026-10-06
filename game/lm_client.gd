extends Node3D

## One player in the dark: the camera (first person or behind), the flashlight, the witches
## drawn where the clock says they are, and the HUD — the step you are on, what you hold, what
## you are looking at, and the meter.
##
## [b]Offline today, built to be a mirror later[/b], as mg-dangerous-delivery's was: everything
## the player does goes through [method _act]; everything they see comes from [member game].

const LmGame := preload("lm_game.gd")
const LmPlayer := preload("lm_player.gd")
const LmLevel := preload("lm_level.gd")

const CHANNEL := "lookatme.client"

@export var local_key: StringName = &"you"
@export var local_name: String = "You"

## Level to start on instead of the lobby, for a screenshot.
@export var start_level: int = 1

var game: LmGame = null
var player: LmPlayer = null
var camera: Camera3D = null
var flashlight: SpotLight3D = null
var third_person: bool = false

var _env: Environment = null
var _witch_views: Dictionary = {}
var _hud: Control = null
var _step: Label = null
var _holds: Label = null
var _prompt: Label = null
var _message: Label = null
var _meter_bar: ProgressBar = null
var _vignette: ColorRect = null
var _command: LineEdit = null
var _message_left := 0.0
var _held_sampler: DotFpsSampler = null


func _ready() -> void:
	_build_environment()
	game = LmGame.new()
	game.name = "World"
	add_child(game)
	player = game.join(local_key, local_name)
	player.sampler = DotFpsSampler.new(player.controller.tunables)
	DotFpsSampler.register_default_actions(player.sampler)

	if start_level > 1 and game.levels.has(start_level):
		player.best = start_level
		game.send_to(player, start_level)

	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 75.0
	camera.near = 0.05
	add_child(camera)
	camera.current = true

	flashlight = SpotLight3D.new()
	flashlight.name = "Flashlight"
	flashlight.spot_range = game.config.flashlight_range
	flashlight.spot_angle = game.config.flashlight_angle
	flashlight.light_energy = 2.2
	flashlight.light_color = Color(1.0, 0.95, 0.85)
	flashlight.shadow_enabled = true
	camera.add_child(flashlight)
	flashlight.position = Vector3(0.2, -0.15, 0.0)

	_build_hud()
	game.said.connect(func(key: StringName, text: String) -> void:
		if key == local_key:
			_say(text))
	game.caught.connect(func(key: StringName) -> void:
		if key == local_key:
			_say("SHE SEES YOU", 2.0))

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if not DotPlatform.is_web() else Input.MOUSE_MODE_VISIBLE


func _build_environment() -> void:
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = Color(0.0, 0.0, 0.0)
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.5, 0.55, 0.7)
	_env.ambient_light_energy = 0.04
	_env.fog_enabled = true
	_env.fog_light_color = Color(0.02, 0.02, 0.03)
	_env.fog_density = 0.04
	_env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world := WorldEnvironment.new()
	world.environment = _env
	add_child(world)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Control.new()
	_hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_hud)

	# The meter's own colour, over everything: the closer she is to seeing you, the redder the
	# edges. A bar is read; a screen going red is felt.
	_vignette = ColorRect.new()
	_vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shader := Shader.new()
	shader.code = "shader_type canvas_item;\nuniform float amount = 0.0;\nvoid fragment() {\n\tfloat d = distance(UV, vec2(0.5));\n\tCOLOR = vec4(0.6, 0.0, 0.0, smoothstep(0.25, 0.75, d) * amount + amount * 0.15);\n}\n"
	var material := ShaderMaterial.new()
	material.shader = shader
	_vignette.material = material
	_hud.add_child(_vignette)

	_step = _label("", 22, Vector2(20, 16))
	_holds = _label("", 16, Vector2(20, 52))
	_holds.modulate = Color(0.8, 0.85, 0.9)

	_meter_bar = ProgressBar.new()
	_meter_bar.max_value = 1.0
	_meter_bar.show_percentage = false
	_meter_bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_meter_bar.offset_left = -180
	_meter_bar.offset_right = 180
	_meter_bar.offset_top = -40
	_meter_bar.offset_bottom = -26
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.75, 0.05, 0.05)
	_meter_bar.add_theme_stylebox_override("fill", fill)
	_hud.add_child(_meter_bar)

	_prompt = _label("", 20, Vector2.ZERO)
	_prompt.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_prompt.offset_top = 40
	_prompt.offset_left = -300
	_prompt.offset_right = 300
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_message = _label("", 34, Vector2.ZERO)
	_message.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_message.offset_top = 120
	_message.offset_left = -400
	_message.offset_right = 400
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	var keys := _label("E use   F flashlight   C camera   Ctrl crouch   / command (/r lobby, /l2 a level)", 13, Vector2.ZERO)
	keys.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	keys.offset_top = -26
	keys.offset_left = 16
	keys.offset_right = 900
	keys.modulate = Color(1, 1, 1, 0.5)

	_command = LineEdit.new()
	_command.placeholder_text = "/r  /l3"
	_command.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_command.offset_top = -70
	_command.offset_bottom = -40
	_command.offset_left = 16
	_command.offset_right = 320
	_command.visible = false
	_command.text_submitted.connect(_on_command)
	_hud.add_child(_command)


func _label(text: String, size: int, at: Vector2) -> Label:
	var label := Label.new()
	label.text = text
	label.position = at
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	label.add_theme_constant_override("outline_size", 6)
	_hud.add_child(label)
	return label


func _say(text: String, seconds: float = 2.5) -> void:
	_message.text = text
	_message_left = seconds


# --- Controls ----------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not _command.visible:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	var key := event as InputEventKey

	if key == null or not key.pressed or key.echo or _command.visible:
		return

	match key.keycode:
		KEY_E:
			_act("use")
		KEY_F:
			_act("flashlight")
		KEY_C:
			if game.config.allow_third_person:
				third_person = not third_person
		KEY_SLASH, KEY_ENTER:
			_command.visible = true
			# Typing is not walking: the sampler is detached until the line is sent.
			_held_sampler = player.sampler
			player.sampler = null
			_command.text = "/"
			_command.grab_focus()
			_command.caret_column = 1
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _on_command(text: String) -> void:
	_command.visible = false
	_command.release_focus()

	if _held_sampler != null:
		player.sampler = _held_sampler
		_held_sampler = null

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_act("command", {"text": text})


func _act(action: String, args: Dictionary = {}) -> void:
	match action:
		"use":
			var _said := game.interact(local_key)
		"flashlight":
			game.set_flashlight(local_key, not player.flashlight)
		"command":
			var reply := game.command(local_key, str(args.get("text", "")))
			_say(reply if reply != "" else "Nothing called that")


# --- Every frame -------------------------------------------------------------

func _process(delta: float) -> void:
	if player == null:
		return

	_place_camera()
	flashlight.visible = player.flashlight
	_draw_witches()

	for key: StringName in game.players:
		var other: LmPlayer = game.players[key]
		other.present_body(other == player and not third_person)

	var level := game.level_of(player)
	_step.text = "Level %d of %d — %s" % [player.level, game.last_level(), game.step_of(player)]
	_holds.text = "Holding: %s" % (", ".join(_hold_names(level)) if not player.holds.is_empty() else "nothing")
	var target := game.target_of(local_key)
	_prompt.text = ("[E] %s" % target["text"]) if not target.is_empty() else ""
	_meter_bar.value = player.meter
	_meter_bar.visible = player.meter > 0.01
	(_vignette.material as ShaderMaterial).set_shader_parameter("amount", player.meter * 0.85 if player.caught_left <= 0.0 else 1.0)

	if _message_left > 0.0:
		_message_left -= delta

		if _message_left <= 0.0:
			_message.text = ""


func _hold_names(level: LmLevel) -> PackedStringArray:
	var out := PackedStringArray()

	for item_id in player.holds:
		var named := item_id

		if level != null:
			for item: Dictionary in level.doc.get("items", []):
				if str(item["id"]) == item_id:
					named = str(item["name"])

			for station: Dictionary in level.doc.get("stations", []):
				if str(station.get("gives", "")) == item_id:
					named = "bucket of water" if str(station.get("kind", "")) == "tap" else "a key from the vent"

		out.append(named)

	return out


func _place_camera() -> void:
	var eye := player.eye_position()
	var basis := Basis.from_euler(Vector3(deg_to_rad(player.controller.state.pitch), deg_to_rad(player.controller.state.yaw), 0.0))

	if third_person:
		var back := basis.z * 3.2 + Vector3(0, 0.6, 0)
		camera.global_transform = Transform3D(basis, eye + back)
	else:
		camera.global_transform = Transform3D(basis, eye)


## Each witch where the clock puts her, with her sight drawn faintly on the floor.
func _draw_witches() -> void:
	var seconds := game.seconds_now()

	for n: int in game.levels:
		var level: LmLevel = game.levels[n]

		# Only the level this player is on: thirty-two houses of witches is a lot of nodes
		# for nobody to see.
		if n != player.level:
			continue

		for i in level.witches.size():
			var key := "%d|%d" % [n, i]
			var view: Node3D = _witch_views.get(key, null)

			if view == null:
				view = _witch_view(float(level.witches[i]["sight"]) * game.config.witch_sight_scale, float(level.witches[i]["cone"]) * game.config.witch_cone_scale)
				add_child(view)
				_witch_views[key] = view

			var pose := level.witch_pose(i, seconds, game.config.witch_speed_scale, game.config.witch_head_sweep)
			view.global_position = level.position + (pose["at"] as Vector3)
			view.rotation.y = float(pose["facing"])
			(view.get_node("Head") as Node3D).rotation.y = float(pose["head"])

	for key: String in _witch_views.keys():
		var n := int(key.split("|")[0])
		(_witch_views[key] as Node3D).visible = n == player.level


## A witch: a tall black robe, a pale face, a hat, two red eyes, and the cone of her sight as a
## faint red fan on the floor — being seen should be something a careful player can avoid.
static func _witch_view(sight: float, cone: float) -> Node3D:
	var root := Node3D.new()
	root.name = "Witch"
	var robe := MeshInstance3D.new()
	var cone_mesh := CylinderMesh.new()
	cone_mesh.top_radius = 0.18
	cone_mesh.bottom_radius = 0.6
	cone_mesh.height = 1.9
	robe.mesh = cone_mesh
	robe.position = Vector3(0, 0.95, 0)
	var black := StandardMaterial3D.new()
	black.albedo_color = Color(0.03, 0.03, 0.04)
	robe.material_override = black
	root.add_child(robe)
	var head := Node3D.new()
	head.name = "Head"
	head.position = Vector3(0, 2.05, 0)
	root.add_child(head)
	var face := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.2
	sphere.height = 0.42
	face.mesh = sphere
	var pale := StandardMaterial3D.new()
	pale.albedo_color = Color(0.72, 0.75, 0.68)
	face.material_override = pale
	head.add_child(face)
	var hat := MeshInstance3D.new()
	var hat_mesh := CylinderMesh.new()
	hat_mesh.top_radius = 0.0
	hat_mesh.bottom_radius = 0.32
	hat_mesh.height = 0.7
	hat.mesh = hat_mesh
	hat.position = Vector3(0, 0.45, 0)
	hat.material_override = black
	head.add_child(hat)
	var eyes := StandardMaterial3D.new()
	eyes.albedo_color = Color(1.0, 0.1, 0.05)
	eyes.emission_enabled = true
	eyes.emission = Color(1.0, 0.1, 0.05)
	eyes.emission_energy_multiplier = 4.0

	for side in [-0.07, 0.07]:
		var eye := MeshInstance3D.new()
		var dot := SphereMesh.new()
		dot.radius = 0.035
		dot.height = 0.07
		eye.mesh = dot
		eye.material_override = eyes
		eye.position = Vector3(side, 0.03, -0.18)
		head.add_child(eye)

	var glow := OmniLight3D.new()
	glow.light_color = Color(1.0, 0.15, 0.1)
	glow.light_energy = 0.6
	glow.omni_range = 3.0
	glow.position = Vector3(0, 0.0, -0.3)
	head.add_child(glow)

	# The sight: a fan on the floor, turning with her head.
	var fan := MeshInstance3D.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var steps := 16
	var half := deg_to_rad(cone * 0.5)

	for k in steps:
		var a0 := -half + 2.0 * half * float(k) / float(steps)
		var a1 := -half + 2.0 * half * float(k + 1) / float(steps)
		st.add_vertex(Vector3.ZERO)
		st.add_vertex(Vector3(-sin(a1), 0, -cos(a1)) * sight)
		st.add_vertex(Vector3(-sin(a0), 0, -cos(a0)) * sight)

	fan.mesh = st.commit()
	var red := StandardMaterial3D.new()
	red.albedo_color = Color(0.8, 0.0, 0.0, 0.07)
	red.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	red.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	red.cull_mode = BaseMaterial3D.CULL_DISABLED
	fan.material_override = red
	fan.position = Vector3(0, -2.0, 0)
	head.add_child(fan)
	return root
