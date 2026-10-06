extends DotNetInput

## One tick of a player's input: the movement command, nothing else. Using and the flashlight
## are requests (reliable, rare); only what is predicted travels here.

var move: DotFpsCommand = DotFpsCommand.new()


func _write(writer: DotNetWriter) -> void:
	move.write(writer)


func _read(reader: DotNetReader) -> void:
	move = DotFpsCommand.new()
	move.read(reader)


func _sanitise() -> void:
	move.sanitise()


func _equals(other: DotNetInput) -> bool:
	return other != null and other.get("move") != null and move.equals(other.get("move"))
