#!/usr/bin/env python3
"""Writes every level document in levels/ (32 of them) and proves each can be finished.

    tools/build_levels.py            # rewrite levels/*.json
    tools/build_levels.py --check    # exit 1 if a file on disk is not what this writes

A level is rooms on a grid (a room is cells; a cell is CELL metres), joined by doors on the
walls they share. Rooms are grown as a tree from the start room, and every door into a new
room is locked behind a PUZZLE whose parts are put in rooms already reachable: so a level
can always be finished, by construction, and solve() checks it anyway before writing.

The puzzles are the genre's: a coloured key for a coloured door, a bucket filled at a tap to
put out a fire, a fuse for a dead fuse box, a crowbar for a boarded door, a code found on a
note for a keypad, a lever somewhere else, a screwdriver for a vent with a key behind it.
Later levels chain more of them, put the parts further from their doors, and send more,
faster, sharper-eyed witches round more rooms.

game/lm_level_doc.gd is the format and its validator. Every number is written as a float
where the format says float, so a document that round-trips through a parser comes back the
same (mg-wipeout's finding).
"""
import json
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "levels")

CELL = 8.0
HEIGHT = 3.2
LEVELS = 32

COLOURS = ["red", "blue", "green", "yellow", "purple", "orange", "white", "black"]

ROOM_NAMES = [
    "Hall", "Kitchen", "Bathroom", "Pantry", "Study", "Bedroom", "Nursery", "Cellar", "Parlour",
    "Library", "Laundry", "Chapel", "Attic", "Boiler Room", "Conservatory", "Gallery", "Servants' Hall",
    "Dining Room", "Music Room", "Storeroom", "Wine Cellar", "Workshop", "Sewing Room", "Larder",
]

LEVEL_NAMES = [
    "The Front Door", "Supper", "Bath Time", "The Pantry", "Lessons", "Lights Out", "The Nursery",
    "Down Below", "Visitors", "Quiet, Please", "Wash Day", "Evensong", "Up the Stairs", "Pressure",
    "Glasshouse", "Portraits", "Below Stairs", "Dinner Is Served", "Out of Tune", "Inventory",
    "Vintage", "Tools Down", "Needlework", "Leftovers", "The Long Corridor", "Two Witches", "Hide",
    "Hush", "The Whole House", "No Light", "Almost Home", "Look At Me",
]


# Every house the builder writes: id -> (directory, how many levels, seed base, level names,
# what the start room of level 1 is called). A server plays one house at a time and votes
# between them (game/lm_vote.gd); an owner's own house is a directory of the same documents.
ASYLUM_NAMES = [
    "Admissions", "The Day Room", "Lights Out", "Ward B", "Solitary", "The Dispensary", "Visiting Hours",
    "Night Shift", "The Records Room", "Hydrotherapy", "The East Wing", "The Chapel", "Restraints",
    "The Director's Office", "The Basement", "Discharge",
]

HOUSES = {
    "house": ("levels", LEVELS, 1000, None, "The Lobby", "The House"),
    "asylum": ("houses/asylum", 16, 5000, ASYLUM_NAMES, "Reception", "The Asylum"),
}


def level(n, seed_base=1000, level_names=None, lobby_name="The Lobby", total=LEVELS, prefix="lm"):
    rng = random.Random(seed_base + n)
    rooms = []
    occupied = {}

    def free(x, z, w, d):
        return all((x + i, z + j) not in occupied for i in range(w) for j in range(d))

    def put(name, x, z, w, d, parent, spawn=False):
        rid = "r%d" % len(rooms)
        for i in range(w):
            for j in range(d):
                occupied[(x + i, z + j)] = rid
        rooms.append({"id": rid, "name": name, "x": x, "z": z, "w": w, "d": d, "parent": parent,
                      "spawn": spawn, "light": 0.0})
        return rooms[-1]

    # The start room. Level 1's is the lobby: the biggest room in the game, lit, where everybody
    # arrives and talks before anybody goes through a door.
    if n == 1:
        put(lobby_name, 0, 0, 3, 3, None, True)
        rooms[0]["light"] = 0.8
    else:
        put("Landing", 0, 0, 2, 1, None, True)
        rooms[0]["light"] = 0.45

    count = min(4 + n // 2, 20)
    names = ROOM_NAMES[:]
    rng.shuffle(names)
    tries = 0

    while len(rooms) < count and tries < 4000:
        tries += 1
        parent = rng.choice(rooms[max(0, len(rooms) - 4):]) if rng.random() < 0.7 else rng.choice(rooms)
        w, d = rng.choice([(1, 1), (1, 1), (2, 1), (1, 2), (2, 2)])
        side = rng.choice("nsew")
        px, pz, pw, pd = parent["x"], parent["z"], parent["w"], parent["d"]
        if side == "n":
            x, z = px + rng.randint(-(w - 1), pw - 1), pz - d
        elif side == "s":
            x, z = px + rng.randint(-(w - 1), pw - 1), pz + pd
        elif side == "w":
            x, z = px - w, pz + rng.randint(-(d - 1), pd - 1)
        else:
            x, z = px + pw, pz + rng.randint(-(d - 1), pd - 1)
        if not free(x, z, w, d):
            continue
        room = put(names[len(rooms) % len(names)], x, z, w, d, parent["id"])
        # A lamp in one room in five: somewhere to catch your breath, and somewhere you are seen.
        room["light"] = 0.35 if rng.random() < 0.2 else 0.0

    doors, items, stations, steps = [], [], [], []
    colours = COLOURS[:]
    rng.shuffle(colours)
    reachable = [rooms[0]["id"]]

    def spot(room_id):
        return [round(rng.uniform(0.2, 0.8), 2), round(rng.uniform(0.2, 0.8), 2)]

    def far_room():
        # Later levels put the parts further from where they are needed: the oldest rooms.
        pool = reachable[:max(1, len(reachable) - (n // 6))] if n > 6 else reachable
        return rng.choice(pool)

    kinds = ["key", "key", "lever", "crowbar", "fuse", "bucket", "code", "vent"]

    for room in rooms[1:]:
        did = "d%d" % len(doors)
        door = {"id": did, "a": room["parent"], "b": room["id"], "lock": "", "label": "Door", "colour": "brown"}
        # The first door of level 1 is open: the lobby is a lobby, and the game starts past it.
        kind = "open" if (n == 1 and len(doors) == 0) or rng.random() < 0.15 else rng.choice(kinds[: 3 + min(n // 3, 5)])
        tag = "%s%d" % (kind, len(doors))

        if kind == "key":
            colour = colours[len(doors) % len(colours)]
            item = "key_%s_%d" % (colour, len(doors))
            items.append({"id": item, "name": "%s key" % colour.capitalize(), "kind": "key", "room": far_room(), "at": spot(None), "colour": colour})
            door.update({"lock": item, "label": "%s door" % colour.capitalize(), "colour": colour})
            steps.append({"text": "Find the %s key" % colour, "when": {"holds": item}})
            steps.append({"text": "Open the %s door" % colour, "when": {"opened": did}})
        elif kind == "crowbar":
            item = "crowbar_%d" % len(doors)
            items.append({"id": item, "name": "Crowbar", "kind": "crowbar", "room": far_room(), "at": spot(None)})
            door.update({"lock": item, "label": "Boarded door", "colour": "wood"})
            steps.append({"text": "Find something to pry the boards off", "when": {"holds": item}})
            steps.append({"text": "Pry the boarded door open", "when": {"opened": did}})
        elif kind == "code":
            item = "note_%d" % len(doors)
            code = "%04d" % rng.randint(0, 9999)
            items.append({"id": item, "name": "Note: %s" % code, "kind": "note", "room": far_room(), "at": spot(None)})
            door.update({"lock": item, "label": "Keypad door", "colour": "steel"})
            steps.append({"text": "Find the keypad's code", "when": {"holds": item}})
            steps.append({"text": "Enter the code at the keypad door", "when": {"opened": did}})
        elif kind == "lever":
            sid = "lever_%d" % len(doors)
            stations.append({"id": sid, "name": "Lever", "kind": "lever", "room": far_room(), "at": spot(None), "needs": "", "gives": "", "opens": did, "verb": "Pull the lever"})
            door.update({"lock": "@" + sid, "label": "Gate", "colour": "iron"})
            steps.append({"text": "Find the lever that opens the gate", "when": {"used": sid}})
        elif kind == "fuse":
            item = "fuse_%d" % len(doors)
            sid = "fusebox_%d" % len(doors)
            items.append({"id": item, "name": "Fuse", "kind": "fuse", "room": far_room(), "at": spot(None)})
            stations.append({"id": sid, "name": "Fuse box", "kind": "fusebox", "room": far_room(), "at": spot(None), "needs": item, "gives": "", "opens": did, "consumes": True, "verb": "Fit the fuse"})
            door.update({"lock": "@" + sid, "label": "Electric gate", "colour": "steel"})
            steps.append({"text": "Find a fuse", "when": {"holds": item}})
            steps.append({"text": "Fit it in the fuse box", "when": {"used": sid}})
        elif kind == "bucket":
            bucket = "bucket_%d" % len(doors)
            water = "water_%d" % len(doors)
            tap = "tap_%d" % len(doors)
            fire = "fire_%d" % len(doors)
            items.append({"id": bucket, "name": "Bucket", "kind": "bucket", "room": far_room(), "at": spot(None)})
            stations.append({"id": tap, "name": "Tap", "kind": "tap", "room": far_room(), "at": spot(None), "needs": bucket, "gives": water, "consumes": True, "verb": "Fill the bucket"})
            # The fire burns in front of its door, on the near side.
            stations.append({"id": fire, "name": "Fire", "kind": "fire", "room": room["parent"], "door": did, "needs": water, "gives": bucket, "opens": did, "consumes": True, "verb": "Put out the fire"})
            door.update({"lock": "@" + fire, "label": "Door behind the fire", "colour": "brown"})
            steps.append({"text": "Find a bucket", "when": {"holds": bucket}})
            steps.append({"text": "Fill it with water", "when": {"holds": water}})
            steps.append({"text": "Put out the fire", "when": {"used": fire}})
        elif kind == "vent":
            driver = "screwdriver_%d" % len(doors)
            key = "key_vent_%d" % len(doors)
            vent = "vent_%d" % len(doors)
            items.append({"id": driver, "name": "Screwdriver", "kind": "screwdriver", "room": far_room(), "at": spot(None)})
            stations.append({"id": vent, "name": "Vent", "kind": "vent", "room": far_room(), "at": spot(None), "needs": driver, "gives": key, "consumes": False, "verb": "Unscrew the vent"})
            door.update({"lock": key, "label": "Locked door", "colour": "brown"})
            steps.append({"text": "Find a screwdriver", "when": {"holds": driver}})
            steps.append({"text": "Something is behind a vent", "when": {"holds": key}})
            steps.append({"text": "Open the locked door", "when": {"opened": did}})

        doors.append(door)
        reachable.append(room["id"])

    # The way out: a door on the last room's outer wall, locked behind the gold key, which is in
    # the room furthest from it.
    last = rooms[-1]
    side = exit_side(last, occupied)
    gold = "key_gold"
    items.append({"id": gold, "name": "Gold key", "kind": "key", "room": far_room(), "at": spot(None), "colour": "gold"})
    doors.append({"id": "exit", "a": last["id"], "b": "", "side": side, "lock": gold, "label": "The way out", "colour": "gold", "exit": True})
    steps.append({"text": "Find the gold key", "when": {"holds": gold}})
    steps.append({"text": "Get out", "when": {"opened": "exit"}})

    witches = []
    witch_count = min(1 + (n - 1) // 4, 6)
    for k in range(witch_count):
        path = patrol(rng, rooms, doors)
        if path:
            witches.append({"path": path, "speed": round(1.5 + 0.05 * n + 0.1 * k, 2),
                            "sight": round(8.0 + 0.35 * n, 2), "cone": round(min(70.0 + 1.2 * n, 120.0), 1)})

    for room in rooms:
        del room["parent"]
        room["light"] = float(room["light"])

    return {
        "format": 1, "kind": "level", "id": "%s_%02d" % (prefix, n), "number": n,
        "name": (level_names or LEVEL_NAMES)[n - 1], "author": "mg-look-at-me",
        "blurb": "Level %d of %d." % (n, total),
        "cell": CELL, "height": HEIGHT,
        "rooms": rooms, "doors": doors, "items": items, "stations": stations,
        "steps": steps, "witches": witches,
    }


def exit_side(room, occupied):
    for side in "nesw":
        cells = []
        for i in range(room["w"]):
            cells.append((room["x"] + i, room["z"] - 1) if side == "n" else (room["x"] + i, room["z"] + room["d"]))
        if side in "ew":
            cells = [((room["x"] + room["w"]) if side == "e" else (room["x"] - 1), room["z"] + j) for j in range(room["d"])]
        if all(c not in occupied for c in cells):
            return side
    return "n"


def patrol(rng, rooms, doors):
    """An out-and-back walk along the room tree, never into a start room: start rooms are safe.

    Points are room centres and door centres, in cells, so a witch walks through doorways and
    never through a wall."""
    by_id = {r["id"]: r for r in rooms}
    links = {}
    for door in doors:
        if door.get("exit"):
            continue
        links.setdefault(door["a"], []).append((door["b"], door))
        links.setdefault(door["b"], []).append((door["a"], door))
    candidates = [r["id"] for r in rooms if not r["spawn"]]
    if len(candidates) < 2:
        return []
    here = rng.choice(candidates)
    route = [here]
    seen = {here}
    for _ in range(rng.randint(2, 5)):
        options = [(b, d) for (b, d) in links.get(route[-1], []) if b not in seen and not by_id[b]["spawn"]]
        if not options:
            break
        nxt, door = rng.choice(options)
        route.append(("door", door["id"]))
        route.append(nxt)
        seen.add(nxt)
    rooms_only = [p for p in route if isinstance(p, str)]
    if len(rooms_only) < 2:
        # Nowhere to walk to: round the inside of the one room, corner to corner. Level 1's
        # rooms each hang off the lobby, and level 1 still has its witch.
        return [["at", here, 0.2, 0.2], ["at", here, 0.8, 0.2], ["at", here, 0.8, 0.8], ["at", here, 0.2, 0.8]]
    forward = route
    back = list(reversed(route))[1:-1]
    out = []
    for point in forward + back:
        if isinstance(point, tuple):
            out.append(["door", point[1]])
        else:
            out.append(["room", point])
    return out


def solve(doc):
    """Plays a level's logic: opens what can be opened with what can be reached, until nothing
    changes. True when the way out opens. Every room must be reachable by the end, too."""
    rooms = {r["id"] for r in doc["rooms"]}
    start = [r["id"] for r in doc["rooms"] if r["spawn"]][0]
    reach = {start}
    holds, used, opened = set(), set(), set()
    changed = True
    while changed:
        changed = False
        for item in doc["items"]:
            if item["room"] in reach and item["id"] not in holds:
                holds.add(item["id"])
                changed = True
        for st in doc["stations"]:
            room = st.get("room")
            if room in reach and st["id"] not in used and (st["needs"] == "" or st["needs"] in holds):
                used.add(st["id"])
                if st.get("gives"):
                    holds.add(st["gives"])
                if st.get("opens"):
                    opened.add(st["opens"])
                changed = True
        for door in doc["doors"]:
            if door["id"] in opened:
                pass
            elif door["a"] in reach and (door["lock"] == "" or door["lock"] in holds):
                opened.add(door["id"])
                changed = True
            else:
                continue
            if door.get("b") and door["b"] not in reach and door["a"] in reach:
                reach.add(door["b"])
                changed = True
    return "exit" in opened and reach == rooms


def text_of(doc):
    return json.dumps(doc, indent="\t") + "\n"


def main():
    check = "--check" in sys.argv
    stale, broken = [], []
    written = 0

    for house_id, (directory, total, seed_base, names, lobby_name, title) in HOUSES.items():
        out = os.path.join(HERE, "..", directory)
        os.makedirs(out, exist_ok=True)
        prefix = "lm" if house_id == "house" else house_id
        meta = os.path.join(out, "house.json")
        meta_text = json.dumps({"kind": "house", "id": house_id, "name": title}, indent="\t") + "\n"
        if check:
            if not os.path.exists(meta) or open(meta).read() != meta_text:
                stale.append(house_id + "/house.json")
        else:
            with open(meta, "w") as f:
                f.write(meta_text)

        for n in range(1, total + 1):
            doc = level(n, seed_base, names, lobby_name, total, prefix)
            if not solve(doc):
                broken.append(doc["id"])
            path = os.path.join(out, doc["id"] + ".json")
            text = text_of(doc)
            if check:
                if not os.path.exists(path) or open(path).read() != text:
                    stale.append(doc["id"])
                continue
            with open(path, "w") as f:
                f.write(text)
            written += 1

    if broken:
        print("cannot be finished:", ", ".join(broken))
        return 1
    if check and stale:
        print("not what tools/build_levels.py writes:", ", ".join(stale))
        return 1
    if not check:
        print("wrote %d levels in %d houses, every one finishable" % (written, len(HOUSES)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
