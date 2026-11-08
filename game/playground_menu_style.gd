extends RefCounted

## The look of the spawn menu, as data and small builders: one palette, one set of line icons,
## rounded boxes, a bold face and a key cap. A menu asks this instead of mixing its own
## colours, so a changed accent changes every widget. Nothing here touches a node tree.

const ACCENT := Color(0.38, 0.62, 1.0)
const PANEL := Color(0.055, 0.065, 0.095, 0.97)
const TEXT := Color(0.93, 0.95, 0.98)
const DIM := Color(0.60, 0.66, 0.76)
const FAINT := Color(0.42, 0.47, 0.57)
const DANGER := Color(1.0, 0.42, 0.45)
const LINE := Color(1, 1, 1, 0.07)
const SURFACE := Color(1, 1, 1, 0.045)
const SURFACE_HOVER := Color(1, 1, 1, 0.095)

## 24 x 24 line icons, stroke only. The stroke colour is filled in when one is drawn.
const GLYPHS := {
	"cube": '<path d="M12 3 3 7.5v9L12 21l9-4.5v-9z"/><path d="M3 7.5 12 12l9-4.5M12 12v9"/>',
	"bolt": '<path d="M13 2 4 14h7l-1 8 9-12h-7z"/>',
	"user": '<circle cx="12" cy="8" r="4"/><path d="M4 21c0-4.4 3.6-7 8-7s8 2.6 8 7"/>',
	"target": '<circle cx="12" cy="12" r="7"/><path d="M12 2v5M12 17v5M2 12h5M17 12h5"/>',
	"package": '<path d="M3 8h18v13H3zM3 8l3-5h12l3 5M10 12h4"/>',
	"wrench": '<path d="M14.5 6.5a4.5 4.5 0 0 0 5.5 5.5L11 21a2.1 2.1 0 0 1-3-3z"/><path d="m14.5 6.5 2.5-2.5 3 3-2.5 2.5"/>',
	"layers": '<path d="M12 3 2 8l10 5 10-5z"/><path d="m2 13 10 5 10-5"/>',
	"grid": '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><path d="M17.5 14v7M14 17.5h7"/>',
	"search": '<circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.2-4.2"/>',
	"undo": '<path d="M9 14 4 9l5-5"/><path d="M4 9h10a6 6 0 0 1 0 12h-3"/>',
	"snow": '<path d="M12 2v20M3.5 7l17 10M3.5 17l17-10"/>',
	"trash": '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3"/>',
	"magnet": '<path d="M6 3v8a6 6 0 0 0 12 0V3h-4v8a2 2 0 0 1-4 0V3zM6 7h4M14 7h4"/>',
	"orbit": '<circle cx="12" cy="12" r="2.5"/><ellipse cx="12" cy="12" rx="10" ry="4.5" transform="rotate(-30 12 12)"/>',
	"droplet": '<path d="M12 3s6 6.5 6 11a6 6 0 0 1-12 0c0-4.5 6-11 6-11z"/>',
	"link": '<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>',
	"pin": '<path d="M12 21s7-6.2 7-11.5a7 7 0 0 0-14 0C5 14.8 12 21 12 21z"/><circle cx="12" cy="9.5" r="2.5"/>',
	"sliders": '<path d="M4 7h10M18 7h2M4 17h2M10 17h10"/><circle cx="16" cy="7" r="2"/><circle cx="8" cy="17" r="2"/>',
	"balloon": '<ellipse cx="12" cy="9" rx="6" ry="7"/><path d="m12 16-1.5 3h3zM12 19v3"/>',
	"remove": '<circle cx="12" cy="12" r="8.5"/><path d="m8.5 8.5 7 7M15.5 8.5l-7 7"/>',
	"bag": '<path d="M5 8h14l-1 13H6zM9 8V6a3 3 0 0 1 6 0v2"/>',
}

## Tool gun mode id fragment -> glyph, first match wins; the rest get the wrench.
const TOOL_GLYPHS := [
	["remove", "remove"], ["colour", "droplet"], ["weld", "link"], ["rope", "link"], ["wire", "bolt"],
	["balloon", "balloon"], ["waypoint", "pin"], ["spawn_point", "pin"], ["spawnpoint", "pin"],
	["npc", "user"], ["edit", "sliders"], ["phys", "sliders"], ["resize", "target"],
]

static var _icons: Dictionary = {}
static var _bold: FontVariation = null


## A line icon as a texture, cached per name, size and tint. An unknown name is an empty tile.
static func icon(glyph: String, px: int = 18, tint: Color = TEXT) -> Texture2D:
	var key := "%s|%d|%s" % [glyph, px, tint.to_html()]
	if _icons.has(key):
		return _icons[key]

	var body: String = GLYPHS.get(glyph, "")
	var svg := (
		'<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
		+ 'stroke="#%s" stroke-opacity="%.2f" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">%s</svg>'
	) % [tint.to_html(false), tint.a, body]
	var image := Image.new()
	var made: Texture2D = null

	if image.load_svg_from_string(svg, float(px) / 24.0) == OK:
		made = ImageTexture.create_from_image(image)

	_icons[key] = made
	return made


## The glyph a tool gun mode wears.
static func tool_glyph(mode_id: StringName) -> String:
	for pair: Array in TOOL_GLYPHS:
		if String(mode_id).contains(pair[0]):
			return pair[1]
	return "wrench"


## The theme font made heavier, for titles and card names.
static func bold(weight: float = 0.45) -> FontVariation:
	if _bold == null or not is_equal_approx(_bold.variation_embolden, weight):
		_bold = FontVariation.new()
		_bold.base_font = ThemeDB.fallback_font
		_bold.variation_embolden = weight
	return _bold


## A rounded box. [param pad] is the content margin, x then y.
static func box(
	fill: Color, radius: float, line: Color = Color.TRANSPARENT, line_width: int = 0, pad: Vector2 = Vector2(10, 6)
) -> StyleBoxFlat:
	var made := StyleBoxFlat.new()
	made.bg_color = fill
	made.set_corner_radius_all(int(radius))
	made.set_border_width_all(line_width)
	made.border_color = line
	made.content_margin_left = pad.x
	made.content_margin_right = pad.x
	made.content_margin_top = pad.y
	made.content_margin_bottom = pad.y
	made.anti_aliasing = true
	return made


## The panel itself: dark glass, a hairline, a long soft shadow.
static func panel() -> StyleBoxFlat:
	var made := box(PANEL, 22.0, Color(1, 1, 1, 0.09), 1, Vector2.ZERO)
	made.shadow_color = Color(0, 0, 0, 0.55)
	made.shadow_size = 44
	made.shadow_offset = Vector2(0, 14)
	return made


## A small label that reads as a key: `Q`, `E`, `/`.
static func keycap(text: String) -> PanelContainer:
	var holder := PanelContainer.new()
	holder.add_theme_stylebox_override("panel", box(Color(1, 1, 1, 0.08), 6.0, Color(1, 1, 1, 0.16), 1, Vector2(7, 1)))
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", TEXT)
	holder.add_child(label)
	return holder


## A small dim caps label, for a section of the sidebar.
static func section(text: String) -> Label:
	var label := Label.new()
	label.text = text.to_upper()
	var face := FontVariation.new()
	face.base_font = ThemeDB.fallback_font
	face.spacing_glyph = 1
	face.variation_embolden = 0.3
	label.add_theme_font_override("font", face)
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", FAINT)
	return label
