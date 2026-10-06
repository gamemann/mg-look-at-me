extends Node

## What a dedicated server loads as this game's scene: the house, drawing nothing. The module
## (lm_module.gd) builds the netcode around it.

const LmGame := preload("lm_game.gd")

const CHANNEL := "lookatme.server"

var game: LmGame = null


func _ready() -> void:
	game = LmGame.new()
	game.name = "World"
	game.draws = false
	game.self_tick = false
	add_child(game)
	DotLog.info(CHANNEL, "the house is up", game.describe())
