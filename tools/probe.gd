extends Node3D
const LmGame := preload("res://game/lm_game.gd")
var game
var t := 0.0
func _ready() -> void:
	game = LmGame.new()
	game.draws = false
	add_child(game)
	print(game.describe())
	for n in [1, 16, 32]:
		print(game.levels[n].describe())
	var p = game.join(&"p", "P")
	print("spawn ", p.global_position, " level ", p.level, " step: ", game.step_of(p))
func _physics_process(delta: float) -> void:
	t += delta
	var p = game.players[&"p"]
	if int(t * 60) % 60 == 0:
		print("t=%.0f pos=%s mode=%s meter=%.2f target=%s" % [t, p.global_position.snapped(Vector3.ONE * 0.01), p.controller.state.mode, p.meter, game.target_of(&"p")])
	if t > 3.0:
		get_tree().quit()
