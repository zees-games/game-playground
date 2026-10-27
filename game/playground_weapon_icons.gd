extends RefCounted

## The playground's weapon pictures: zee weapon id to sprite tag; the rest is dot-ui's [DotWeaponIconStyle].

const TAGS := {
	&"battle_rifle": &"battle_rifle", &"beamer": &"energy_rifle", &"bullpup": &"bullpup",
	&"burst_rifle": &"assault_rifle", &"carbine": &"carbine", &"charge_rifle": &"charge_rifle",
	&"derringer": &"derringer", &"drum_shotgun": &"drum_shotgun", &"frag": &"grenade",
	&"hatchet": &"hatchet", &"knife": &"knife", &"launcher": &"launcher",
	&"machine_pistol": &"machine_pistol", &"mallet": &"hammer", &"marksman": &"marksman",
	&"minigun": &"lmg", &"pickaxe": &"pickaxe", &"pistol": &"pistol", &"revolver": &"revolver",
	&"rifle": &"rifle", &"shiv": &"dagger", &"shotgun": &"shotgun", &"smg": &"smg",
	&"sniper": &"sniper", &"spade": &"axe", &"sticky": &"sticky",
}

## The one instance the client, HUD and menu share.
static var shared: DotWeaponIconStyle = _make()


static func _make() -> DotWeaponIconStyle:
	var s := DotWeaponIconStyle.new()
	s.tags = TAGS
	return s
