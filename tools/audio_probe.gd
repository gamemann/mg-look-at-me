extends Node

## Under xvfb-run (never --headless, whose audio driver is Dummy): does the house make a noise?
##   xvfb-run -a godot --path . res://tools/audio_probe.tscn

const LmClient := preload("res://game/lm_client.gd")


func _ready() -> void:
	var client := LmClient.new()
	client.start_level = 8
	add_child(client)
	await get_tree().physics_frame
	client.player.meter = 0.9
	var heard_heart := false

	for _i in 120:
		await get_tree().process_frame
		client.player.meter = 0.9
		heard_heart = heard_heart or client.sounds._heart.playing

	var drones := 0
	for view in client._witch_views.values():
		for child in (view as Node).get_children():
			if child is AudioStreamPlayer3D and (child as AudioStreamPlayer3D).playing:
				drones += 1

	print("driver=%s heartbeat=%s drones=%d of %d witches" % [AudioServer.get_driver_name(), heard_heart, drones, client._witch_views.size()])
	get_tree().quit(0 if heard_heart and drones > 0 else 1)
