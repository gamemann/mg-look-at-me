extends DotConfig

## Every rule a level is played under: the witches, the meter, the light, the penalties. The
## levels themselves are documents (`levels/`). Layered like every DotConfig in the family:
## exported defaults < JSON file < LM_* environment < --lm-* command line.
##
## [b]"Configurable down to the tee" was the brief[/b], so every number about being seen is
## here: how far a witch sees, how wide, how a flashlight or a crouch changes it, how fast the
## meter climbs and falls, and what being caught costs.

@export_group("Players")

@export_range(1.0, 15.0, 0.1) var run_speed: float = 4.6
@export_range(0.1, 1.0, 0.05) var walk_speed_scale: float = 0.5
@export_range(0.0, 3.0, 0.05) var jump_height: float = 0.9
@export_range(1.0, 40.0, 0.5) var gravity: float = 18.0

## Whether a player may switch to third person.
@export var allow_third_person: bool = true

## Metres a player can reach to take an item, open a door or use something.
@export_range(0.5, 6.0, 0.1) var reach: float = 2.2

## Whether objectives are shared by everybody on a level (one key opens the door for all).
## Off by default, as the brief asks: everybody does every level themselves, which is what
## makes a server that never ends possible.
@export var shared_progress: bool = false

@export_group("The meter")

## How fast the caught meter fills, per second, for a player in full view at point-blank range.
@export_range(0.05, 5.0, 0.05) var exposure_rate: float = 0.9

## How fast it drains, per second, out of sight.
@export_range(0.01, 5.0, 0.01) var decay_rate: float = 0.22

## Seconds after being seen before it starts to drain.
@export_range(0.0, 10.0, 0.25) var decay_delay: float = 1.0

## A lit flashlight multiplies how fast you are seen, and how far.
@export_range(1.0, 5.0, 0.05) var flashlight_exposure: float = 1.8
@export_range(1.0, 3.0, 0.05) var flashlight_sight: float = 1.5

## Crouching multiplies how fast you are seen.
@export_range(0.05, 1.0, 0.05) var crouch_exposure: float = 0.55

## Standing still multiplies it too: a witch notices movement.
@export_range(0.05, 1.0, 0.05) var still_exposure: float = 0.6

@export_group("Being caught")

## What a catch costs: 0 back to the level's start room keeping what you hold, 1 back to the
## start with the level's progress lost.
@export_enum("keep", "reset") var caught_penalty: int = 1

## Seconds the screen is the witch's before the player is put back.
@export_range(0.0, 10.0, 0.25) var caught_seconds: float = 2.0

@export_group("Witches")

## Each witch's own numbers are the level document's; these scale every one, so an owner can
## make a whole server easier or harder without editing 32 files.
@export_range(0.1, 5.0, 0.05) var witch_speed_scale: float = 1.0
@export_range(0.1, 5.0, 0.05) var witch_sight_scale: float = 1.0
@export_range(0.1, 3.0, 0.05) var witch_cone_scale: float = 1.0

## Whether witches turn their heads as they walk, sweeping the cone.
@export var witch_head_sweep: bool = true

@export_group("The world")

## How dark: the ambient light everywhere a lamp is not.
@export_range(0.0, 1.0, 0.01) var darkness_ambient: float = 0.04

## The flashlight's reach in metres, and its cone.
@export_range(2.0, 60.0, 0.5) var flashlight_range: float = 18.0
@export_range(5.0, 90.0, 1.0) var flashlight_angle: float = 32.0

## Where the built-in house's level documents are read from.
@export var level_directory: String = "levels"

## Where other houses are: every subdirectory with a house.json in it is one. An owner's own
## house is a directory of level documents dropped in here.
@export var houses_directory: String = "houses"

## The house a server opens with.
@export var house: String = "house"

## Minutes a house is played before the players vote on the next (the same house is on the
## ballot). 0 is no limit: the house changes only when players rock the vote.
@export_range(0.0, 600.0, 1.0) var house_minutes: float = 45.0

## Where who has won is kept, so a winner's mark survives a restart.
@export var winners_file: String = "user://lookatme_winners.json"

@export var seed_value: int = 0


func env_prefix() -> String:
	return "LM_"


func cli_prefix() -> String:
	return "--lm-"


func validate() -> DotResult:
	if exposure_rate <= 0.0:
		return DotResult.fail(DotError.CODE_INVALID, "exposure_rate must be above 0, or nobody is ever caught.")

	return DotResult.success(null)


func describe() -> Dictionary:
	return {
		"meter": "+%.2f/s seen, -%.2f/s hidden after %.1f s" % [exposure_rate, decay_rate, decay_delay],
		"light": "flashlight x%.1f seen, x%.1f sight" % [flashlight_exposure, flashlight_sight],
		"caught": ["keep what you hold", "lose the level"][caught_penalty],
		"witches": "speed x%.2f, sight x%.2f" % [witch_speed_scale, witch_sight_scale],
		"shared": shared_progress,
	}
