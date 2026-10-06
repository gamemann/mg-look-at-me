extends Node

## Renders one frame for a person to look at. See shot.sh.

const LmClient := preload("res://game/lm_client.gd")

var _args: Dictionary = {}


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--") and arg.contains("="):
			_args[arg.substr(2, arg.find("=") - 2)] = arg.substr(arg.find("=") + 1)

	var client := LmClient.new()
	client.start_level = int(_args.get("level", "1"))
	add_child(client)
	var view := str(_args.get("view", "eyes"))
	client.third_person = view == "third"
	await get_tree().physics_frame

	# Somewhere worth looking: facing the nearest witch, a few metres away, or a room by id.
	var player = client.player
	var level = client.game.level_of(player)
	var room := str(_args.get("room", ""))

	if room != "" and level.rooms.has(room):
		player.place_at(level.position + level.room_centre(room) + Vector3(0, 0.1, 0), float(_args.get("yaw", "0")))
	elif view == "witch" and not level.witches.is_empty():
		var pose: Dictionary = level.witch_pose(0, client.game.seconds_now())
		var at: Vector3 = level.position + (pose["at"] as Vector3)
		var from := at + Vector3(sin(float(pose["facing"])), 0, cos(float(pose["facing"]))) * -5.0
		player.place_at(from + Vector3(0, 0.1, 0), rad_to_deg(atan2(-(at - from).x, -(at - from).z)))

	client.game.set_flashlight(player.player_key, str(_args.get("light", "on")) != "off")
	await get_tree().create_timer(float(_args.get("seconds", "1"))).timeout

	if view == "above":
		var cam := Camera3D.new()
		add_child(cam)
		var rect := Rect2()
		var first := true
		for id: String in level.rooms:
			rect = level.rooms[id]["rect"] if first else rect.merge(level.rooms[id]["rect"])
			first = false
		var centre: Vector3 = level.position + Vector3(rect.get_center().x, 0, rect.get_center().y)
		cam.global_position = centre + Vector3(0, maxf(rect.size.x, rect.size.y) * 1.1, 0.1)
		cam.look_at(centre)
		cam.current = true
		client._env.ambient_light_energy = 1.2
		client._env.fog_enabled = false
		for id in level.rooms:
			pass

	for _i in 3:
		await RenderingServer.frame_post_draw

	var path := ProjectSettings.globalize_path(str(_args.get("out", "res://screenshots/shot.png")))
	var saved := get_viewport().get_texture().get_image().save_png(path)
	print("saved %s (%s)" % [path, error_string(saved)])
	get_tree().quit()
