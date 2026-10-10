extends RefCounted
## What a person in the sandbox looks like, as a dot-user-avatar document: face, top and legs,
## each one of the eighteen painted skins of the character kit.
##
## [b]Three slots because the site has three.[/b] A member picks a face, a top and legs on
## the site, each a skin `a`-`r`; the kit's figure has a separate mesh per body part over
## one shared UV layout, so each part can wear a different atlas and a member is drawn as
## they dressed rather than as their shirt. The minigames draw one atlas for the whole
## figure; that is a choice those games made with six skins, not a limit of the art.
##
## [b]Data only, and loads nothing.[/b] The server checks a document against this schema
## without holding the art; [code]playground_figure.gd[/code] is what turns the three
## indices into atlases, on a client. [constant SKINS] is the kit's letter order, which
## is also the index on the wire (JOIN carries index + 1, 0 meaning "the stock one").

const SCHEMA_ID := &"pg_people"

const SLOT_FACE := &"face"
const SLOT_TOP := &"top"
const SLOT_LEGS := &"legs"
const SLOTS: Array[StringName] = [SLOT_FACE, SLOT_TOP, SLOT_LEGS]

const LETTERS := "abcdefghijklmnopqr"


static func skin_id(index: int) -> StringName:
	return StringName("skin_%s" % LETTERS[clampi(index, 0, LETTERS.length() - 1)])


static func schema() -> DotAvatarSchema:
	var s := DotAvatarSchema.new()
	s.id = SCHEMA_ID
	s.version = 1

	for slot_id in SLOTS:
		var slot := DotAvatarSlot.new()
		slot.id = slot_id
		slot.display_name = String(slot_id).capitalize()
		slot.required = true
		slot.default_part = StringName("%s_skin_a" % slot_id)
		s.slots.append(slot)

		for i in range(LETTERS.length()):
			var part := DotAvatarPart.new()
			part.id = StringName("%s_%s" % [slot_id, skin_id(i)])
			part.slot = slot_id
			part.display_name = "%s %s" % [String(slot_id).capitalize(), LETTERS[i].to_upper()]
			# Free and shipped in the pack: nobody has to own a face.
			part.free = true
			part.colour_channels = 0
			s.parts.append(part)

	return s


## The look a player without one of their own wears: one skin, chosen from their id, so
## every client dresses the same guest the same way.
static func stock_avatar(player_id: StringName) -> DotAvatar:
	var avatar := DotAvatar.make(SCHEMA_ID)
	var index := stock_index(String(player_id))
	for slot_id in SLOTS:
		avatar.set_part(slot_id, StringName("%s_%s" % [slot_id, skin_id(index)]))
	return avatar


static func stock_index(key: String) -> int:
	return int(hash(key) & 0x7fffffff) % LETTERS.length()


## [face, top, legs] as skin indices, or -1 for a slot the document does not fill.
static func skins_of(avatar: DotAvatar) -> PackedInt32Array:
	var out := PackedInt32Array([-1, -1, -1])
	if avatar == null or avatar.schema_id != SCHEMA_ID:
		return out
	for i in range(SLOTS.size()):
		var part := String(avatar.part_in(SLOTS[i]))
		var letter := part.trim_prefix("%s_skin_" % SLOTS[i])
		if letter.length() == 1:
			out[i] = LETTERS.find(letter)
	return out


## A member's site avatar in this game's terms, or null when it is not the site's.
static func from_site(foreign: DotAvatar) -> DotAvatar:
	var avatar := DotAvatar.make(SCHEMA_ID)
	var any := false

	for slot_id in SLOTS:
		var letter := _site_skin(foreign, slot_id)
		if letter == "":
			continue
		avatar.set_part(slot_id, StringName("%s_skin_%s" % [slot_id, letter]))
		any = true

	if not any:
		return null

	# A slot the site left empty takes the top's skin (or the face's), so a partly dressed
	# member is one person rather than a person with somebody else's legs.
	var fallback := avatar.part_in(SLOT_TOP)
	if String(fallback) == "":
		fallback = avatar.part_in(SLOT_FACE)
	var fill_letter := String(fallback).get_slice("_skin_", 1)
	for slot_id in SLOTS:
		if String(avatar.part_in(slot_id)) == "" and fill_letter != "":
			avatar.set_part(slot_id, StringName("%s_skin_%s" % [slot_id, fill_letter]))

	return avatar


## The letter of the site's skin in [param slot], or "". The site files a part as
## `<slot>.<option>` (`top.skin-k`); a bare `skin-k` is read too.
static func _site_skin(foreign: DotAvatar, slot: StringName) -> String:
	if foreign == null or foreign.schema_id != &"builtin":
		return ""

	var part := String(foreign.part_in(slot)).trim_prefix(String(slot) + ".")

	if part.length() != 6 or not part.begins_with("skin-"):
		return ""

	var letter := part.substr(5, 1)
	return letter if LETTERS.contains(letter) else ""
