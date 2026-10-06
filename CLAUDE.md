# mg-look-at-me

A dark house, thirty-two levels deep, with witches walking its rooms. Find what opens the next door before one of them looks at you.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first, and dot-player-controller's `CLAUDE.md` before touching movement. This file is only about what this game decides.

**Built 2026-10-06, in one session, offline-first**, the way mg-dangerous-delivery was: the house, the 32 levels, the witches, the meter, per-player doors, the commands, winning, and a client you can play (`godot --path .`). **Not networked yet**; see the plan at the bottom. Remote set (`gamemann/mg-look-at-me`), nothing pushed.

## Layout

```
game/
  lm_config.gd   every rule (LM_*, --lm-*): the meter, what changes it, what a catch costs, the witches, the dark
  lm_level.gd    a level document built: rooms, walls cut for doors, doors (one StaticBody each), items, stations, lamps; witch_pose()
  lm_player.gd   a CharacterBody3D with dot-player-controller's first person, EXTERNAL drive; holds/opened/used/taken; the meter; the crown
  lm_game.gd     the house: every level side by side, join/leave, interact, exposure, caught, exits, /r and /l, winners
  lm_client.gd   offline play: the dark, the flashlight, first/third person, witches drawn with a sight fan, the HUD
  lm_figure.gd, lm_avatars.gd, lm_paths.gd   mg-deathrun's, renamed (Kenney blocky characters, the avatar schema, mount paths)
levels/          lm_01 .. lm_32, written by tools/build_levels.py
examples/        headless_run (8 sections, 27 checks)
tools/           build_levels.py; shot.sh/.gd (render: eyes, third, witch, above); probe.gd (a quick look)
```

## Decision 1: doors are per player, and that is an exclusion list

The brief: everybody does every level themselves, which is what makes a server that never ends. So a door is one solid `StaticBody3D` in the world, and a player who has opened it has its RID in their controller's collision exclusions (`DotFpsController.body.exclude`, rebuilt by `LmGame._apply_doors`). It is open for them and shut for everybody else, and nothing about the level changes. A witch's line of sight to a player ignores the doors THAT player opened (`_clear_between`), because for them it is open. `shared_progress` (off) copies every take, open and use to everybody on the level. `headless_run` walks two players at one door: the one who opened it is 6 m through, the other stops at it.

## Decision 2: a witch's walk is a pure function of time

mg-wipeout's idea again: a witch walks a loop of points (room centres, doorways, points in a room) at a speed, and `LmLevel.witch_pose(index, seconds)` is where she is and which way she and her head face. Every machine poses every witch from the clock, so nothing about her will ever need sending, and the server's "can she see you" and the client's picture of her cannot disagree. She does not chase; she sees. Witches never walk into a start room: start rooms are safe, and the lobby is level 1's.

## Decision 3: being seen is a meter

Each tick, every witch on a player's level asks: in range (`sight`, × `flashlight_sight` with the light on), inside her cone (`cone`, turning with her head), nothing solid between. The rate is `exposure_rate` × nearness, × `flashlight_exposure`, × `crouch_exposure`, × `still_exposure`; a second witch adds 35%. Out of sight for `decay_delay` it drains at `decay_rate`. Full is caught: `caught_seconds` of a red screen, then the level's start room, with the level lost under `caught_penalty` 1 (the default) or kept under 0. Her sight is drawn on the floor as a faint red fan, because a meter a careful player cannot see coming is a lottery.

## Decision 4: levels are generated, and proven

`tools/build_levels.py` grows each level's rooms as a tree on a grid, from a start room (the lobby is 3×3 cells, the biggest room in the game), and locks every door into a new room behind a puzzle whose parts it puts in rooms already reachable: so every level is finishable by construction, and `solve()` plays the logic and refuses to write one that is not. Later levels have more rooms (4 + n/2, up to 20), put the parts in older rooms (further from their doors), and send more witches (1 + (n-1)/4, up to 6), faster (1.5 + 0.05n m/s), sharper (8 + 0.35n m, cone 70 + 1.2n°). `headless_run`'s solver then plays all 32 in the ENGINE — standing in front of each thing and pressing E through `LmGame.interact` — so a document the game reads differently from the builder fails there.

## What running and rendering found

- **dot-player-controller needs dot_player and dot_net linked**; without them `DotFpsController` does not parse and every script that names it fails with it.
- **Level 1 had no witch**: its rooms each hang off the lobby, so there was no loop that avoided a start room. A witch with nowhere to go walks the corners of one room.
- **The lobby was as dark as the house** with one lamp in the middle of a 24 m room. Lit rooms get a lamp every cell and a half.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' -not -path './addons/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"; done
godot --headless --path . res://examples/headless_run.tscn   # 8 sections, 27 checks
tools/build_levels.py --check
tools/shot.sh; tools/shot.sh --view=witch --level=8; tools/shot.sh --view=third
```

## Still to do

In the order they are worth doing.

1. **Networking**, on mg-deathrun's skeleton for the people (DotFpsController is predicted there: `DrPlayer`, `DrPlayerNet`, the bridge's input path) and mg-dangerous-delivery's for everything else (JSON events, HELLO with the documents). What travels: HELLO (the level documents, the clock), each player's movement (predicted, as deathrun's), and per-player state to its OWNER only (level, holds, opened, used, taken, meter, caught) — a door one player opened must be excluded on that player's client too, so its prediction walks through it. Witches are never sent (Decision 2). A `DotGameModule`, `DotGameServices` for chat and voice (the brief: a lobby to socialise in), a server scene, a dedicated suite, and dot-server-deploy's real-client check.
2. **dot-map and dot-vote**: the brief asks that the house be a map an owner can replace and vote on. A map is a directory of level documents; dot-vote's list source over the directories, as mg-deathrun's course vote does over courses.
3. **TMC avatars** through dot-platform (the figure and the avatar schema are mg-deathrun's and already translate the site's), and an achievement for winning through dot-achievements (the crown and the winners file are here).
4. **Sound**: footsteps, her breathing as she nears, the meter's heartbeat. The meter is the whole game and it is silent.
5. **Kenney furniture** (the Furniture Kit) in rooms, for something to hide behind; today a room is four walls and a stand.
6. **The GitHub repository** is the owner's to create.
