extends "playground_entity.gd"

## A patrol waypoint: a flat marker an armed NPC of the same owner walks to when it has
## nothing to fight, and on from it along its [member links].
##
## [b]A prop, so it replicates, is undone, is counted and is cleaned up with its owner for
## free.[/b] A separate waypoint system would have needed its own wire message to be seen on a
## client; a frozen prop is drawn by the path every other prop takes. The link between two
## points is a rope in [PlaygroundConstraints] (not counted, and between two frozen bodies it
## moves nothing), which is what gets a line drawn on every screen; the routes the NPCs
## walk are read from [member links], never from the ropes.
##
## [b]Extended by PATH[/b], like every entity: a pack cannot name a `class_name`.

## The waypoints this one leads on to. Linked both ways by [method link].
var links: Array = []


func _entity_ready() -> void:
	# Frozen where it lands, and flat enough to walk over: a post a player cannot step over
	# is a post in the way of the NPCs it is meant to guide.
	freeze = true
	freeze_mode = RigidBody3D.FREEZE_MODE_STATIC

	if game != null:
		game.register_waypoint(self)


func _exit_tree() -> void:
	for other in links:
		if is_instance_valid(other):
			(other.get("links") as Array).erase(self)

	links.clear()


## Joins this to [param other], both ways. False when it was linked already or is itself.
func link(other: Node) -> bool:
	if other == self or other == null or links.has(other):
		return false

	links.append(other)
	(other.get("links") as Array).append(self)
	return true


## The linked waypoints still in the world.
func neighbours() -> Array:
	var live: Array = []

	for other in links:
		if is_instance_valid(other) and other.is_inside_tree():
			live.append(other)

	return live


func describe() -> Dictionary:
	var out := super.describe()
	out["links"] = links.size()
	return out
