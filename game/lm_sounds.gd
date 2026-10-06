extends Node

## What the house sounds like: a heartbeat that quickens and loudens as she sees you, a low
## drone from every witch that you hear before you see her, and a click for each thing you
## take or open. Synthesised, so the game carries no audio files.
##
## [b]The meter is the whole game, and a meter that is only a bar is one you stop watching.[/b]
## The heartbeat is the same number, heard: nothing at 0, a slow thud past a quarter, racing
## at the top.

const RATE := 22050

var _heart: AudioStreamPlayer = null
var _click: AudioStreamPlayer = null
var _until_beat := 0.0
var _beat_second := false

## 0 to 1: how close she is to seeing you. Set by the client every frame.
var meter: float = 0.0


func _ready() -> void:
	_heart = AudioStreamPlayer.new()
	_heart.stream = _thump()
	_heart.bus = &"Master"
	add_child(_heart)
	_click = AudioStreamPlayer.new()
	_click.stream = _blip()
	add_child(_click)


func _process(delta: float) -> void:
	if meter < 0.2:
		_until_beat = 0.0
		return

	_until_beat -= delta

	if _until_beat > 0.0:
		return

	# A real heart's lub-dub: two beats close together, then the gap, which shortens with fear.
	var gap := lerpf(1.0, 0.32, clampf((meter - 0.2) / 0.8, 0.0, 1.0))
	_until_beat = 0.18 if not _beat_second else gap - 0.18
	_beat_second = not _beat_second
	_heart.volume_db = lerpf(-18.0, 0.0, meter)
	_heart.pitch_scale = 1.0 if _beat_second else 0.85
	_heart.play()


## A click for something taken or opened.
func click() -> void:
	if _click != null:
		_click.play()


## A witch's drone, positional, for the client to hang on her.
static func drone() -> AudioStreamPlayer3D:
	var player := AudioStreamPlayer3D.new()
	player.stream = _hum()
	player.unit_size = 3.0
	player.max_distance = 18.0
	player.volume_db = -6.0
	player.autoplay = true
	return player


static func _wav(samples: PackedFloat32Array, loop: bool = false) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)

	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = data

	if loop:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_end = samples.size()

	return wav


## A low thud: a falling sine with a fast decay.
static func _thump() -> AudioStreamWAV:
	var n := int(RATE * 0.16)
	var out := PackedFloat32Array()
	out.resize(n)

	for i in n:
		var t := float(i) / RATE
		out[i] = sin(TAU * lerpf(70.0, 40.0, t / 0.16) * t) * exp(-t * 28.0)

	return _wav(out)


static func _blip() -> AudioStreamWAV:
	var n := int(RATE * 0.06)
	var out := PackedFloat32Array()
	out.resize(n)

	for i in n:
		var t := float(i) / RATE
		out[i] = sin(TAU * 880.0 * t) * exp(-t * 60.0) * 0.4

	return _wav(out)


## Two low sines a few hertz apart, beating against each other, with a slow breath on top: the
## sound of something standing in a dark room. Two seconds, looped seamlessly (whole cycles).
static func _hum() -> AudioStreamWAV:
	var n := RATE * 2
	var out := PackedFloat32Array()
	out.resize(n)

	for i in n:
		var t := float(i) / RATE
		var breath := 0.6 + 0.4 * sin(TAU * 0.5 * t)
		out[i] = (sin(TAU * 55.0 * t) * 0.5 + sin(TAU * 58.0 * t) * 0.4 + sin(TAU * 110.0 * t) * 0.1) * breath * 0.5

	return _wav(out, true)
