extends RefCounted

## A number in [0, 1) from text, the same on every machine: what furniture, rolls and anything
## else every client must agree with the server about is placed from.
##
## [b]Not hash()[/b]: Godot's string hash is djb2, and strings that differ only at the end
## differ only in its low bits (mg-dangerous-delivery found its zones rolling the same weather
## every period). MD5's first 32 bits mix properly and are identical everywhere.
static func unit(text: String) -> float:
	return float(text.md5_text().substr(0, 8).hex_to_int()) / 4294967296.0
