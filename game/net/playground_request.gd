extends DotNetMessage

const PlaygroundEvents := preload("playground_events.gd")

## Anything a client asks the authority for. Reliable, rare, to the server only.
##
## Small on purpose: every one of these costs the server work — a spawn is a rigid body
## and a budget check — and the manager rate-limits them per peer. A client sending
## thousands is broken or hostile, and in a sandbox the difference does not matter.

const NAME := &"pg.request"
## Room for 32 asks. It was 4 bits with [enum PlaygroundEvents.Ask] at 16 of 16, so the
## next ask added would have gone out as READY: the writer masks a value to its field without
## a word (game-zombie-zone sent HURT and AMMO as HELLO and MAP that way). headless_net
## checks every ask fits ([method fits]).
const KIND_BITS := 5
const MAX_BODY := 2048

var kind: int = 0
var body: PackedByteArray = PackedByteArray()


## [b]Built with [code]new(kind, body)[/code], and this file does not preload itself.[/b]
## It used to, for a typed [code]static func of() -> PlaygroundRequest[/code] factory. A script that
## [code]extends DotNetMessage[/code] and preloads ITSELF, first loaded from a module a
## running [DotServer] loads at runtime — which is how every deployed server loads this
## game — leaks the whole script graph at exit on Godot 4.7.2. Measured in
## mg-buses-from-hell (8ed866c) with a two-line reproduction. The registry decodes with a
## bare [code]new()[/code], which is why both arguments default.
func _init(p_kind: int = 0, p_body: PackedByteArray = PackedByteArray()) -> void:
	kind = p_kind
	body = p_body


func _type_name() -> StringName:
	return NAME


func _write(writer: DotNetWriter) -> void:
	writer.write_uint(kind, KIND_BITS)
	writer.write_bytes(body)


func _read(reader: DotNetReader) -> void:
	kind = reader.read_uint(KIND_BITS)
	body = reader.read_bytes(MAX_BODY)


func _validate() -> DotResult:
	if kind < 0 or kind >= PlaygroundEvents.Ask.size():
		return DotResult.fail(DotError.CODE_INVALID, "Unknown request kind %d." % kind)
	return DotResult.success(true)


## Whether every [enum PlaygroundEvents.Ask] fits in [constant KIND_BITS]. What a check reads: the writer
## masks a value to its field, so a kind past it goes out as a smaller one and nothing errors.
static func fits() -> bool:
	return int(PlaygroundEvents.Ask.values().max()) < (1 << KIND_BITS)


func reader() -> DotNetReader:
	return DotNetReader.new(body)


func _to_string() -> String:
	return "PlaygroundRequest(%s, %d bytes)" % [PlaygroundEvents.ask_name(kind), body.size()]
