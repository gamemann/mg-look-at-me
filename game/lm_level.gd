extends Node3D

## A level document, built: the rooms, their walls with doorways cut in them, the doors, the
## items and the things you use them on, the lamps, and where every witch is at any moment.
##
## [b]A witch's walk is a pure function of time[/b], like mg-wipeout's obstacles: a loop of
## points through room centres and doorways, at the document's speed. Every machine poses
## every witch from the clock it already agrees on, so nothing about a witch is ever sent, and
## the server's "can she see you" and the client's picture of where she is cannot disagree.
##
## [b]Doors are per player.[/b] A door is one StaticBody3D in the world, solid; a player who
## has opened it has its RID in their controller's exclusion list, so it is open for them and
## shut for everybody else (see [LmGame]). The level never knows who opened what.

const CHANNEL := "lookatme.level"

const DOOR_WIDTH := 1.5
const DOOR_HEIGHT := 2.3
const WALL := 0.15
const SLAB := 0.25

var doc: Dictionary = {}

## room id -> {"rect": Rect2 (x, z in metres), "doc": room}.
var rooms: Dictionary = {}

## door id -> {"centre": Vector3, "normal": Vector3 (from a into b), "body": StaticBody3D, "doc": door}.
var doors: Dictionary = {}

## item id -> {"at": Vector3, "node": Node3D, "doc": item}.
var items: Dictionary = {}

## station id -> {"at": Vector3, "node": Node3D, "doc": station}.
var stations: Dictionary = {}

## Each witch's loop: {"points": PackedVector3Array, "lengths": PackedFloat32Array, "total",
## "speed", "sight", "cone"}.
var witches: Array = []

## Whether this level draws (meshes, labels, lamps). Off on a server.
var draws: bool = true

var _materials: Dictionary = {}


func number() -> int:
	return int(doc.get("number", 0))


func build(p_doc: Dictionary, p_draws: bool = true) -> DotResult:
	doc = p_doc
	draws = p_draws
	var cell := float(doc.get("cell", 8.0))

	for room: Dictionary in doc["rooms"]:
		rooms[str(room["id"])] = {
			"rect": Rect2(float(room["x"]) * cell, float(room["z"]) * cell, float(room["w"]) * cell, float(room["d"]) * cell),
			"doc": room,
		}

	for door: Dictionary in doc["doors"]:
		var placed := _place_door(door)

		if placed.is_empty():
			return DotResult.fail(DotError.CODE_INVALID, "door %s is not on a wall its rooms share" % door["id"])

		doors[str(door["id"])] = placed

	for room_id: String in rooms:
		_build_room(room_id)

	for door_id: String in doors:
		_build_door(door_id)

	for item: Dictionary in doc["items"]:
		var at := _room_point(str(item["room"]), item["at"])
		items[str(item["id"])] = {"at": at, "node": _build_item(item, at), "doc": item}

	for station: Dictionary in doc["stations"]:
		var at: Vector3

		if station.has("door"):
			# In front of its door, on the near side: a fire burns in the doorway it blocks.
			var door: Dictionary = doors[str(station["door"])]
			at = door["centre"] - door["normal"] * 1.3
		else:
			at = _room_point(str(station["room"]), station["at"])

		stations[str(station["id"])] = {"at": at, "node": _build_station(station, at), "doc": station}

	for witch: Dictionary in doc["witches"]:
		witches.append(_witch_loop(witch))

	return DotResult.success(self)


# --- Placement ---------------------------------------------------------------

func _place_door(door: Dictionary) -> Dictionary:
	var a: Rect2 = rooms[str(door["a"])]["rect"]

	if bool(door.get("exit", false)) or str(door.get("b", "")) == "":
		var side := str(door.get("side", "n"))
		var centre: Vector3
		var normal: Vector3

		match side:
			"n":
				centre = Vector3(a.position.x + a.size.x * 0.5, 0.0, a.position.y)
				normal = Vector3(0, 0, -1)
			"s":
				centre = Vector3(a.position.x + a.size.x * 0.5, 0.0, a.end.y)
				normal = Vector3(0, 0, 1)
			"w":
				centre = Vector3(a.position.x, 0.0, a.position.y + a.size.y * 0.5)
				normal = Vector3(-1, 0, 0)
			_:
				centre = Vector3(a.end.x, 0.0, a.position.y + a.size.y * 0.5)
				normal = Vector3(1, 0, 0)

		return {"centre": centre, "normal": normal, "doc": door, "body": null}

	var b: Rect2 = rooms[str(door["b"])]["rect"]

	if is_equal_approx(a.end.x, b.position.x) or is_equal_approx(b.end.x, a.position.x):
		var x := a.end.x if is_equal_approx(a.end.x, b.position.x) else a.position.x
		var lo := maxf(a.position.y, b.position.y)
		var hi := minf(a.end.y, b.end.y)

		if hi - lo < DOOR_WIDTH:
			return {}

		return {"centre": Vector3(x, 0.0, (lo + hi) * 0.5), "normal": Vector3(signf(b.position.x - a.position.x), 0, 0), "doc": door, "body": null}

	if is_equal_approx(a.end.y, b.position.y) or is_equal_approx(b.end.y, a.position.y):
		var z := a.end.y if is_equal_approx(a.end.y, b.position.y) else a.position.y
		var lo := maxf(a.position.x, b.position.x)
		var hi := minf(a.end.x, b.end.x)

		if hi - lo < DOOR_WIDTH:
			return {}

		return {"centre": Vector3((lo + hi) * 0.5, 0.0, z), "normal": Vector3(0, 0, signf(b.position.y - a.position.y)), "doc": door, "body": null}

	return {}


func _room_point(room_id: String, at: Variant) -> Vector3:
	var rect: Rect2 = rooms[room_id]["rect"]
	var f: Array = at if at is Array else [0.5, 0.5]
	return Vector3(rect.position.x + rect.size.x * float(f[0]), 0.0, rect.position.y + rect.size.y * float(f[1]))


func room_centre(room_id: String) -> Vector3:
	return _room_point(room_id, [0.5, 0.5])


## The start room's id.
func spawn_room() -> String:
	for room_id: String in rooms:
		if bool(rooms[room_id]["doc"].get("spawn", false)):
			return room_id

	return str(doc["rooms"][0]["id"])


## Where player [param slot] is put down in the start room, local to the level.
func spawn_point(slot: int) -> Vector3:
	var rect: Rect2 = rooms[spawn_room()]["rect"]
	var ring := float(slot % 8) / 8.0 * TAU
	var radius := minf(rect.size.x, rect.size.y) * 0.25 * float(1 + slot / 8 % 2)
	return Vector3(rect.get_center().x + cos(ring) * radius, 0.1, rect.get_center().y + sin(ring) * radius)


## The room [param local] is in, or "".
func room_at(local: Vector3) -> String:
	for room_id: String in rooms:
		if (rooms[room_id]["rect"] as Rect2).grow(0.05).has_point(Vector2(local.x, local.z)):
			return room_id

	return ""


## Whether [param local] is through the exit doorway and out of the house.
func is_out(local: Vector3) -> bool:
	var exit: Dictionary = doors.get("exit", {})

	if exit.is_empty():
		return false

	var past: float = (local - (exit["centre"] as Vector3)).dot(exit["normal"])
	return past > 0.6 and room_at(local) == ""


# --- Witches -----------------------------------------------------------------

func _witch_loop(witch: Dictionary) -> Dictionary:
	var points := PackedVector3Array()

	for step: Array in witch["path"]:
		match str(step[0]):
			"room":
				points.append(room_centre(str(step[1])))
			"door":
				points.append(doors[str(step[1])]["centre"])
			"at":
				points.append(_room_point(str(step[1]), [step[2], step[3]]))

	var lengths := PackedFloat32Array()
	var total := 0.0

	for i in points.size():
		var leg := points[i].distance_to(points[(i + 1) % points.size()])
		lengths.append(leg)
		total += leg

	return {
		"points": points, "lengths": lengths, "total": maxf(total, 0.01),
		"speed": float(witch.get("speed", 1.6)), "sight": float(witch.get("sight", 10.0)), "cone": float(witch.get("cone", 70.0)),
	}


## Where witch [param index] is at [param seconds]: {"at", "facing" (radians), "head" (radians,
## added to facing)}. Local to the level. [param speed_scale] is the server's scaling.
func witch_pose(index: int, seconds: float, speed_scale: float = 1.0, sweep: bool = true) -> Dictionary:
	var loop: Dictionary = witches[index]
	var points: PackedVector3Array = loop["points"]
	var lengths: PackedFloat32Array = loop["lengths"]
	var along := fmod(seconds * float(loop["speed"]) * speed_scale + float(index) * 7.3, float(loop["total"]))
	var i := 0

	while i < lengths.size() - 1 and along > lengths[i]:
		along -= lengths[i]
		i += 1

	var a := points[i]
	var b := points[(i + 1) % points.size()]
	var t := clampf(along / maxf(lengths[i], 0.001), 0.0, 1.0)
	var dir := (b - a)
	var facing := atan2(-dir.x, -dir.z) if dir.length_squared() > 0.0001 else 0.0
	var head := sin(seconds * 0.8 + float(index)) * deg_to_rad(35.0) if sweep else 0.0
	return {"at": a.lerp(b, t), "facing": facing, "head": head}


# --- Geometry ----------------------------------------------------------------

func _material(key: String, colour: Color, emission: float = 0.0) -> StandardMaterial3D:
	if _materials.has(key):
		return _materials[key]

	var m := StandardMaterial3D.new()
	m.albedo_color = colour
	m.roughness = 0.9

	if emission > 0.0:
		m.emission_enabled = true
		m.emission = colour
		m.emission_energy_multiplier = emission

	_materials[key] = m
	return m


func _box(parent: Node, size: Vector3, at: Vector3, material: Material, solid: bool) -> Node3D:
	var node: Node3D

	if solid:
		var body := StaticBody3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		var collider := CollisionShape3D.new()
		collider.shape = shape
		body.add_child(collider)
		node = body
	else:
		node = Node3D.new()

	if draws:
		var mesh := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = size
		mesh.mesh = box
		mesh.material_override = material
		node.add_child(mesh)

	parent.add_child(node)
	node.position = at
	return node


const WALLPAPERS := [Color(0.32, 0.26, 0.24), Color(0.24, 0.27, 0.25), Color(0.27, 0.25, 0.3), Color(0.3, 0.29, 0.24)]


func _build_room(room_id: String) -> void:
	var rect: Rect2 = rooms[room_id]["rect"]
	var height := float(doc.get("height", 3.2))
	var root := Node3D.new()
	root.name = "Room_%s" % room_id
	add_child(root)
	var floor_mat := _material("floor", Color(0.22, 0.17, 0.13))
	var paper: Color = WALLPAPERS[room_id.hash() % WALLPAPERS.size()]
	var wall_mat := _material("wall_%d" % (room_id.hash() % WALLPAPERS.size()), paper)
	var centre := rect.get_center()
	_box(root, Vector3(rect.size.x, SLAB, rect.size.y), Vector3(centre.x, -SLAB * 0.5, centre.y), floor_mat, true)
	_box(root, Vector3(rect.size.x, SLAB, rect.size.y), Vector3(centre.x, height + SLAB * 0.5, centre.y), _material("ceiling", Color(0.12, 0.11, 0.1)), true)

	for side in ["n", "s", "w", "e"]:
		_build_wall(root, rect, side, height, wall_mat)

	var light := float(rooms[room_id]["doc"].get("light", 0.0))

	# Lamps every couple of cells, so a big lit room is lit all over: one lamp in the middle of
	# the lobby left its corners as dark as the house (the first render).
	if draws and light > 0.0:
		var cell := float(doc.get("cell", 8.0))
		var across := maxi(int(round(rect.size.x / (cell * 1.5))), 1)
		var down := maxi(int(round(rect.size.y / (cell * 1.5))), 1)

		for i in across:
			for j in down:
				var lamp := OmniLight3D.new()
				lamp.light_color = Color(1.0, 0.8, 0.55)
				lamp.light_energy = light * 2.4
				lamp.omni_range = cell * 1.6
				lamp.position = Vector3(rect.position.x + rect.size.x * (float(i) + 0.5) / float(across), height - 0.4,
					rect.position.y + rect.size.y * (float(j) + 0.5) / float(down))
				root.add_child(lamp)
				_box(root, Vector3(0.3, 0.2, 0.3), lamp.position + Vector3(0, 0.25, 0), _material("bulb", Color(1.0, 0.85, 0.6), 2.0), false)

	if draws:
		var sign := Label3D.new()
		sign.text = str(rooms[room_id]["doc"].get("name", room_id))
		sign.font_size = 48
		sign.pixel_size = 0.006
		sign.modulate = Color(0.85, 0.8, 0.7, 0.6)
		sign.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		sign.position = Vector3(centre.x, height - 0.5, centre.y)
		root.add_child(sign)


## One wall, cut wherever a door sits on it. Inset by [constant WALL] so two rooms that share a
## wall each have their own face, back to back, and never fight over one.
func _build_wall(root: Node, rect: Rect2, side: String, height: float, material: Material) -> void:
	var along_x := side == "n" or side == "s"
	var fixed: float
	match side:
		"n": fixed = rect.position.y + WALL * 0.5
		"s": fixed = rect.end.y - WALL * 0.5
		"w": fixed = rect.position.x + WALL * 0.5
		_: fixed = rect.end.x - WALL * 0.5
	var start := rect.position.x if along_x else rect.position.y
	var end := rect.end.x if along_x else rect.end.y
	var gaps: Array[float] = []
	var edge := rect.position.y if side == "n" else (rect.end.y if side == "s" else (rect.position.x if side == "w" else rect.end.x))

	for door_id: String in doors:
		var c: Vector3 = doors[door_id]["centre"]
		var on := absf((c.z if along_x else c.x) - edge) < 0.01
		var within := (c.x if along_x else c.z) > start and (c.x if along_x else c.z) < end

		if on and within:
			gaps.append(c.x if along_x else c.z)

	gaps.sort()
	var cursor := start
	var half := DOOR_WIDTH * 0.5

	for gap in gaps:
		_wall_piece(root, along_x, fixed, cursor, gap - half, 0.0, height, material)
		_wall_piece(root, along_x, fixed, gap - half, gap + half, DOOR_HEIGHT, height, material)
		cursor = gap + half

	_wall_piece(root, along_x, fixed, cursor, end, 0.0, height, material)


func _wall_piece(root: Node, along_x: bool, fixed: float, from: float, to: float, bottom: float, top: float, material: Material) -> void:
	if to - from < 0.01 or top - bottom < 0.01:
		return

	var size := Vector3(to - from, top - bottom, WALL) if along_x else Vector3(WALL, top - bottom, to - from)
	var mid := (from + to) * 0.5
	var at := Vector3(mid, (bottom + top) * 0.5, fixed) if along_x else Vector3(fixed, (bottom + top) * 0.5, mid)
	_box(root, size, at, material, true)


const DOOR_COLOURS := {
	"red": Color(0.6, 0.12, 0.1), "blue": Color(0.12, 0.2, 0.6), "green": Color(0.12, 0.45, 0.16),
	"yellow": Color(0.75, 0.62, 0.12), "purple": Color(0.4, 0.15, 0.5), "orange": Color(0.75, 0.38, 0.1),
	"white": Color(0.8, 0.8, 0.78), "black": Color(0.07, 0.07, 0.08), "gold": Color(0.85, 0.65, 0.15),
	"brown": Color(0.3, 0.19, 0.11), "wood": Color(0.42, 0.3, 0.18), "steel": Color(0.45, 0.48, 0.52), "iron": Color(0.2, 0.2, 0.22),
}


func _build_door(door_id: String) -> void:
	var door: Dictionary = doors[door_id]
	var normal: Vector3 = door["normal"]
	var size := Vector3(DOOR_WIDTH, DOOR_HEIGHT, WALL * 2.0) if absf(normal.z) > 0.5 else Vector3(WALL * 2.0, DOOR_HEIGHT, DOOR_WIDTH)
	var colour: Color = DOOR_COLOURS.get(str(door["doc"].get("colour", "brown")), Color(0.3, 0.19, 0.11))
	var body := _box(self, size, (door["centre"] as Vector3) + Vector3(0, DOOR_HEIGHT * 0.5, 0), _material("door_" + str(door["doc"].get("colour", "")), colour), true)
	body.name = "Door_%s" % door_id
	door["body"] = body

	if draws:
		for face in [-1.0, 1.0]:
			var label := Label3D.new()
			label.text = str(door["doc"].get("label", "Door"))
			label.font_size = 40
			label.pixel_size = 0.005
			label.modulate = Color(0.95, 0.9, 0.8)
			label.position = normal * face * (WALL + 0.02) + Vector3(0, 0.5, 0)
			label.rotation.y = atan2(normal.x, normal.z) + (PI if face < 0.0 else 0.0)
			body.add_child(label)


## The door's body, for a player's exclusion list.
func door_rid(door_id: String) -> RID:
	var body: Variant = doors.get(door_id, {}).get("body")
	return (body as CollisionObject3D).get_rid() if body is CollisionObject3D else RID()


func _build_item(item: Dictionary, at: Vector3) -> Node3D:
	var root := Node3D.new()
	root.name = "Item_%s" % item["id"]
	add_child(root)
	root.position = at

	if not draws:
		return root

	# A little stand, so a thing on the floor of a dark room can be found by a flashlight.
	_box(root, Vector3(0.5, 0.8, 0.5), Vector3(0, 0.4, 0), _material("stand", Color(0.25, 0.2, 0.16)), false)
	var colour: Color = DOOR_COLOURS.get(str(item.get("colour", "")), Color(0.75, 0.72, 0.65))
	var size: Vector3 = {"key": Vector3(0.28, 0.06, 0.1), "bucket": Vector3(0.35, 0.35, 0.35), "crowbar": Vector3(0.8, 0.05, 0.06),
		"note": Vector3(0.25, 0.01, 0.18), "fuse": Vector3(0.1, 0.1, 0.22), "screwdriver": Vector3(0.3, 0.04, 0.04)}.get(str(item.get("kind", "")), Vector3(0.2, 0.2, 0.2))
	_box(root, size, Vector3(0, 0.82 + size.y * 0.5, 0), _material("item_" + str(item.get("kind", "")) + str(item.get("colour", "")), colour, 0.6), false)
	return root


func _build_station(station: Dictionary, at: Vector3) -> Node3D:
	var root := Node3D.new()
	root.name = "Station_%s" % station["id"]
	add_child(root)
	root.position = at

	if not draws:
		return root

	match str(station.get("kind", "")):
		"fire":
			_box(root, Vector3(1.2, 1.4, 0.6), Vector3(0, 0.7, 0), _material("fire", Color(1.0, 0.45, 0.1), 3.0), false)
			var glow := OmniLight3D.new()
			glow.light_color = Color(1.0, 0.5, 0.2)
			glow.light_energy = 1.5
			glow.omni_range = 6.0
			glow.position = Vector3(0, 1.2, 0)
			root.add_child(glow)
		"tap":
			_box(root, Vector3(0.9, 0.9, 0.5), Vector3(0, 0.45, 0), _material("sink", Color(0.8, 0.8, 0.78)), false)
		"lever":
			_box(root, Vector3(0.3, 1.0, 0.2), Vector3(0, 0.5, 0), _material("iron", Color(0.2, 0.2, 0.22)), false)
			_box(root, Vector3(0.06, 0.6, 0.06), Vector3(0, 1.2, 0), _material("handle", Color(0.7, 0.1, 0.1), 0.5), false)
		"fusebox":
			_box(root, Vector3(0.6, 0.8, 0.25), Vector3(0, 1.3, 0), _material("fusebox", Color(0.4, 0.42, 0.38)), false)
		"vent":
			_box(root, Vector3(0.7, 0.5, 0.1), Vector3(0, 0.4, 0), _material("vent", Color(0.55, 0.55, 0.55)), false)
		_:
			_box(root, Vector3(0.5, 0.5, 0.5), Vector3(0, 0.25, 0), _material("thing", Color(0.5, 0.5, 0.5)), false)

	return root


func describe() -> Dictionary:
	return {
		"id": str(doc.get("id", "")), "number": number(), "name": str(doc.get("name", "")),
		"rooms": rooms.size(), "doors": doors.size(), "items": items.size(), "stations": stations.size(),
		"witches": witches.size(), "steps": (doc.get("steps", []) as Array).size(),
	}
