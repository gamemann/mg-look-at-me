This is a game to demonstrate the capabilities of the [**Dot collection**](https://moddingcommunity.com/co/4-dot-assets) built on-top of [Godot 4](https://godotengine.org/) and [TMC's gaming platform](https://moddingcommunity.com/play). In this 3D game, players make their way through a dark house, thirty-two levels deep, while witches walk its rooms. Find what opens the next door before one of them looks at you for too long.

**This project and the assets under it are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This project, along with every asset it is built on, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** It has its own headless test suite and that suite passes, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## How it plays
You arrive in the lobby, the one lit room in the house and the start of level 1. Every level is a set of rooms behind doors that don't open on their own:

- a coloured key for a coloured door;
- a bucket filled at a tap, to put out a fire in a doorway;
- a fuse for a dead fuse box, a crowbar for a boarded door, a screwdriver for a vent;
- a code from a note for a keypad, or a lever somewhere else that opens a gate.

The top left of the screen always says what to do next. The gold key opens the way out, and the way out is the next level.

**Everybody plays every level for themselves.** What you pick up, open and use is yours: a door you unlocked is open for you and still locked for the player behind you. So people can arrive and leave at any time.

**The witches** walk the rooms in the dark, and their line of sight is drawn as a faint red fan on the floor. While one can see you, the meter at the bottom of the screen fills: faster the closer she is, and much faster with your flashlight on. Crouching and standing still help, and furniture hides you as well as a wall does. Out of sight, the meter drains after a moment. If it fills, you're caught and go back to the start of the level. Level 1 has one witch; the last levels have six, faster and sharper-eyed.

Finish all thirty-two and you get a crown everybody else can see.

There are two **houses**: The House (32 levels) and The Asylum (16). A server plays one at a time, and after 45 minutes the players vote on the next. `!rtv` calls a vote at any time.

## Controls

| Key | Action |
| --- | --- |
| **WASD** / mouse | Move and look |
| **Ctrl** | Crouch |
| **E** | Take, open, use |
| **F** | Flashlight |
| **C** | First or third person |
| **/** | A command: `/r` goes back to the lobby, `/l3` (or `/l 3`) goes to a level you have reached |

## Getting started
You need [Godot 4.7](https://godotengine.org/download). The game is built from many Dot addons, each in its own repository, so the easiest way to get everything is [dot-bootstrap](https://github.com/modcommunity/dot-bootstrap). It clones every project and links the addons into each one:

```bash
git clone https://github.com/modcommunity/dot-bootstrap.git
cd dot-bootstrap
./bootstrap.sh
cd projects/mg-look-at-me
./game.sh
```

On Windows, run `bootstrap.ps1` instead and open the project in Godot.

`game.sh` does everything else:

| Command | What it does |
| --- | --- |
| `./game.sh` | Play offline |
| `./game.sh online` | Start a local server and the browser client, and print the link to open |
| `./game.sh online down` | Stop them |
| `./game.sh server` | Start a local dedicated server only |
| `./game.sh test` | Check every script and run every test suite |
| `./game.sh shot` | Save a screenshot to `screenshots/`. `./game.sh shot --help` lists the views |
| `./game.sh help` | All of the options |

`online` and `server` use [dot-server-deploy](https://github.com/modcommunity/dot-server-deploy), which bootstrap clones next to this one. Run its `./setup.sh` once first.

## Running a server
Console commands:

| Command | |
| --- | --- |
| `lm_status` | What the server is doing |
| `lm_send <name> <level>` | Send a player to a level |
| `lm_winners` | Who has finished the house |
| `lm_house <id>` | Switch to another house (e.g. `lm_house asylum`) |

Everything else is a setting. Put it in `user://cfg/lookatme.json`, or set it with an `LM_*` environment variable or an `--lm-*` argument (the later one wins):

| Setting | |
| --- | --- |
| `exposure_rate`, `decay_rate`, `decay_delay` | How fast the meter fills and drains |
| `flashlight_exposure`, `flashlight_sight`, `crouch_exposure`, `still_exposure` | What changes it |
| `caught_penalty` | What getting caught costs: keep what you hold, or lose the level |
| `witch_speed_scale`, `witch_sight_scale`, `witch_cone_scale`, `witch_head_sweep` | The witches |
| `darkness_ambient`, `flashlight_range`, `flashlight_angle` | The dark |
| `shared_progress` | One player's key opens the door for everybody on that level (off by default) |
| `allow_third_person` | Whether **C** works |
| `house_minutes` | How long a house plays before the vote (45) |

## Writing a level
A level is one JSON file in `levels/`. It describes:

- **rooms** on a grid (a room is `w` by `d` cells of `cell` metres);
- **doors** on the walls two rooms share (or, for the way out, on an outside wall);
- **items**, and **stations** you use an item on (`needs`, `gives`, `opens`);
- **steps**, the text the HUD shows, each done when you hold, open or use something;
- **witches**: a loop of room centres, doorways and points in rooms, a speed, a sight range and a cone.

The shipped levels are written by `tools/build_levels.py`. It grows each level's rooms as a tree, locks every new door behind a puzzle whose parts are already reachable, and refuses to write a level it can't finish.

A house is a folder of levels with a `house.json` (`{"kind": "house", "id": "mine", "name": "My House"}`), in `houses/` or `user://lookatme_houses/`.

## Testing

```bash
./game.sh test                  # every script parses, then every suite runs
./game.sh test headless_run     # one suite
tools/build_levels.py --check   # the shipped levels are what the builder writes
```

| Suite | What it covers |
| --- | --- |
| `headless_run` | The game itself: levels, doors, puzzles, the witches and the meter |
| `headless_net` | A server and a client in one process, over the network code |
| `dedicated` | A real server: boots, loads the game, runs its commands |

[`CLAUDE.md`](CLAUDE.md) has the design decisions and the reasoning behind them.

## Credits
The characters are Kenney's Blocky Characters and the furniture is Kenney's Furniture Kit ([kenney.nl](https://kenney.nl), CC0), in `assets/kenney/` with their licences. Everything else is drawn in code.

## License
MIT. See [LICENSE](LICENSE). The Kenney art is CC0, which is public domain.
