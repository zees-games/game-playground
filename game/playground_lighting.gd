extends RefCounted

## A map's sun, sky and air: a dot-lighting document turned into a sun and an environment
## under the map's own node, so they arrive and leave with the map.
##
## [b]Every map carries a document[/b]: a built-in map takes [constant DAYLIGHT], a custom
## map document may name its own under `lighting` (the same keys, dot-lighting's), and a
## map that says nothing gets [constant DAYLIGHT] too. [DotLightRig] does the work; what
## stays here is this game's: which [DotLightProfile] a machine gets and the zenith
## (`sky_top`). The reasoning is in docs/maps.md, "The look".

## A clear afternoon: a warm sun high in the south-west, a blue sky, a little haze far off.
##
## [b]The sun angles are in dot-lighting's source convention[/b] (a negative pitch is a sun
## in the sky). The brightness is divided by the profile's reference and square-rooted, so
## 380 is an energy of about 1.4 under Forward+. The ambient is the light in the shade: a
## pale cool grey rather than a sky blue, because at the ambient's strength a saturated
## blue turns every shaded face navy. The fog distances are source units (metres / 0.01905):
## the haze starts 80 m out, because the sandbox is 200 m across and its far corner should
## read as far, not vanish.
##
## `sky_top` is this game's, not dot-lighting's (the document ignores keys it does not
## know): the rig draws the zenith in the ambient colour, which here is paler than any sky.
const DAYLIGHT := {
	"sun": {
		"pitch_src": -50.0,
		"yaw_src": -35.0,
		"colour": [1.0, 0.93, 0.80],
		"brightness": 380.0,
		"spread_degrees": 1.0,
		"ambient_colour": [0.74, 0.78, 0.92],
	},
	"fog": {
		"enabled": true,
		"colour": [0.80, 0.89, 1.0],
		"start": 4200.0,
		"end": 26000.0,
		"max_density": 0.25,
	},
	"sky_top": [0.30, 0.56, 0.96],
}

## How far the sun's shadows reach, in metres. The sandbox is 200 m across and the surf
## maps longer; past this a shadow is a few pixels nobody reads, and the split it would
## cost is better spent near the player.
const SHADOW_DISTANCE := 140.0


## Adds [param lighting] (a dot-lighting document; empty means [constant DAYLIGHT]) under
## [param parent] and returns the sun.
static func build(parent: Node3D, lighting: Dictionary = {}) -> DirectionalLight3D:
	var doc := lighting if not lighting.is_empty() else DAYLIGHT
	var sun := DotLightRig.apply(parent, DotLightDocument.from_dictionary(doc), profile())
	_paint_sky_top(parent, doc)
	if sun != null and sun.shadow_enabled:
		sun.directional_shadow_max_distance = SHADOW_DISTANCE
		# Softer than the default edge, which is what makes the shadow read as a sunny day
		# rather than a stage light.
		sun.shadow_blur = 1.5
	return sun


## The zenith in the document's `sky_top`, where it gives one. game-arena and g2gfast
## repaint their skies after the rig the same way.
static func _paint_sky_top(parent: Node3D, lighting: Dictionary) -> void:
	var top: Variant = lighting.get("sky_top", null)
	if not (top is Array and (top as Array).size() >= 3):
		return
	for node in parent.get_children():
		if node is WorldEnvironment and (node as WorldEnvironment).environment.sky != null:
			var material := (node as WorldEnvironment).environment.sky.sky_material as ProceduralSkyMaterial
			if material != null:
				material.sky_top_color = Color(float(top[0]), float(top[1]), float(top[2]))
				material.ground_bottom_color = material.sky_top_color


## What this machine draws of a map's lighting: dot-lighting's `painted()`.
##
## [b]`painted()` is the family's profile for flat-painted worlds[/b] (dot-lighting API 3):
## a longer filmic shoulder and a lower exposure, a contrast and saturation grade, ambient
## occlusion where Forward+ has it, and a shadowless fill from the side the sun is not on, so
## a ramp's two shaded faces are two shades under Compatibility, which has no occlusion. Its
## light numbers are per renderer, because Compatibility (the project's and the client
## shell's) clips before it tone maps. Under the hand-set numbers it replaced (sun / 700, a
## fill of 0.62) the lobby from a player's eye was still a fifth pure white.
##
## [b]The sky continues under the horizon[/b]: the sandbox and the surf maps float in the
## air, and from a ramp or a tower the default dark ground half is a brown void under the
## world. [b]A browser keeps dot-lighting's `web()`, shadows off[/b]: these maps are large
## (the sandbox alone is 200 m with a hundred boxes and whatever the players spawn) and
## the shadow pass draws all of it again.
static func profile() -> DotLightProfile:
	var p := DotLightProfile.painted()
	p.sky_below_horizon = true
	return p
