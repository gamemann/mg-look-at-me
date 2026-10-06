extends RefCounted

## What the server tells a client and what a client asks, by kind. Kinds are their index on the
## wire: append, never reorder.
##
## Movement is in snapshots, predicted, as in mg-deathrun. Everything here is small and rare, so
## it is JSON, as in mg-dangerous-delivery: the hello with every level document, a player
## arriving or leaving, and a player's own progress (what they hold, have opened, used and
## taken) to that player alone — nobody else's business, and the doors in it are the ones the
## owner's prediction has to walk through.

enum Kind {
	## You, the clock, how many levels follow, the settings a client needs.
	HELLO,
	## One level document. One per message, never all in the HELLO: the 32 together are 210 KB,
	## and a WebSocket's outbound buffer is 64 KiB by default, so a browser client would never
	## be told the house it is standing in.
	LEVEL,
	## A player is here, or has a new name or face: key, name, net id, the avatar document.
	JOIN,
	## A player left.
	LEAVE,
	## Your progress: level, best, holds, opened, used, taken. To the owner only.
	PROGRESS,
	## A line for the middle of your screen. To one player.
	SAY,
	## A chat line, as the server's chat router addressed it.
	CHAT,
}

enum Ask {
	## The scene is loaded; send the world.
	READY,
	## {"action": use | flashlight | command | say, ...}.
	ACT,
}


static func kind_name(kind: int) -> String:
	return Kind.keys()[kind] if kind >= 0 and kind < Kind.size() else "?%d" % kind


static func ask_name(kind: int) -> String:
	return Ask.keys()[kind] if kind >= 0 and kind < Ask.size() else "?%d" % kind


const MAX_TEXT := 60000


static func write_json(data: Variant) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_string(JSON.stringify(data), MAX_TEXT)
	return writer.to_bytes()


static func read_json(reader: DotNetReader) -> Dictionary:
	var text := reader.read_string(MAX_TEXT)

	if not reader.ok():
		return {}

	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}
