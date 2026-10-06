# Look At Me

A dark house, thirty-two levels deep, with witches walking its rooms. Find what opens the next door before one of them looks at you.

A minigame for the TMC platform, built on the dot-* addons.

## Playing

You arrive in the lobby, the one lit room in the house and the start of level 1. Every level is a set of rooms behind doors that do not open on their own: a coloured key for a coloured door, a bucket filled at a tap to put out a fire in a doorway, a fuse for a dead fuse box, a crowbar for a boarded door, a code found on a note for a keypad, a lever somewhere else that opens a gate, a screwdriver for a vent with a key behind it. The top left always says what to do next. The gold key opens the way out, and the way out is the next level.

**Everybody plays every level themselves.** What you pick up, open and use is yours: the door you unlocked is open for you and still locked for the person behind you. That is what lets the house run for ever, with people arriving and leaving at any time.

**The witches.** They walk the rooms in the dark. One that can see you fills the meter at the bottom of the screen, faster the nearer you are and much faster with your flashlight on; crouching and standing still help. Out of her sight it drains, after a moment. Full is caught: back to the start of the level, and the level's progress with you. There is one witch on level 1 and six by the end, faster and sharper-eyed each level. Their sight is drawn as a faint red fan on the floor.

Finish all thirty-two and you get a crown everybody else can see.

| Key | |
| --- | --- |
| WASD, mouse | Move, look |
| Ctrl | Crouch |
| E | Take, open, use |
| F | Flashlight |
| C | First / third person |
| / | A command: `/r` back to the lobby, `/l3` (or `/l 3`) a level you have reached |

## Running a server

Every rule is a setting, layered like everything in the family: defaults < `user://cfg/lookatme.json` < `LM_*` environment < `--lm-*` command line. The meter (`exposure_rate`, `decay_rate`, `decay_delay`), what changes it (`flashlight_exposure`, `flashlight_sight`, `crouch_exposure`, `still_exposure`), what a catch costs (`caught_penalty`: keep what you hold, or lose the level), the witches (`witch_speed_scale`, `witch_sight_scale`, `witch_cone_scale`, `witch_head_sweep`), the dark (`darkness_ambient`, `flashlight_range`, `flashlight_angle`), `shared_progress` (one player's key opens the door for everybody on the level; off by default) and `allow_third_person`.

## Writing a level

A level is one JSON file in `levels/`: rooms on a grid (a room is `w` by `d` cells of `cell` metres), doors on the walls rooms share (or, for the way out, on an outside wall), items, stations (things you use an item on: `needs`, `gives`, `opens`), steps (the text the HUD shows, each done when you hold, opened or used something), and witches (a loop of room centres, doorways and points in rooms, a speed, a sight range and a cone). The shipped thirty-two are written by `tools/build_levels.py`, which grows each level's rooms as a tree, locks every new door behind a puzzle whose parts are already reachable, and refuses to write a level it cannot finish.

## Checking it

```bash
godot --headless --path . --import
godot --headless --path . res://examples/headless_run.tscn   # 8 sections, 27 checks
tools/build_levels.py --check
tools/shot.sh --view=witch --level=8
```

## Credits

- Characters: [Kenney](https://kenney.nl) Blocky Characters, CC0 1.0 (`assets/kenney/characters/`, licence beside them).
- Everything else is drawn in code.

MIT licence; see [LICENSE](LICENSE).
