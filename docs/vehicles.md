# Vehicles

## A vehicle is a prop with seats in it

dot-vehicle is installed for the half this game would get wrong, and **not** for spawning. Every vehicle arrives through `DotPropSpawner` and is handed over with `DotVehicleSpawner.adopt()` (added to dot-vehicle for this game), so it is a `DotPropInstance` first: budget, undo, removed with its owner, liftable and puntable. The join is one field of `meta`: `{ "kind": "vehicle", "vehicle": "buggy" }`.

`PlaygroundVehicles` is a second catalogue, deliberately not merged with the prop one: `DotPropCatalogue` says what may be put in the world and what it costs, `DotVehicleCatalogue` says how it drives. **The prop rows are derived from the vehicle rows**, so the mass the physics gun checks and the mass the chassis puts on the body are one number.

## Traps

- **A wheel above the bottom of the chassis box is a car that does not move.** `PlaygroundProp` centres the collision box on the origin, so a 0.9 m body reaches 0.45 m down; wheels must reach below that. `wheel_y` is negative for that reason. A raycast vehicle with no wheel in contact has no traction, steering or brakes while every tunable reads correctly. The suite counts wheels separately from the drive, because "no wheels" and "wheels touching nothing" are the same symptom.
- **`configure` before `adopt`.** `DotVehicleWheeled` caches the body's `VehicleWheel3D` children once, at bind.
- **`continuous_cd` is turned back off for a vehicle.** `PlaygroundProp` turns it on (a sandbox throws things); under wheel raycasts it fights the wheel solver and the car judders at speed.
- **`Basis.looking_at(dir)` aims -Z at `dir`, and a vehicle's forward is -Z.** Negating it puts the car on the grid backwards.
- **A rider's node is carried; their movement state is not.** dot-vehicle reparents the rider into the seat (which moves the camera), but a run timer, the NPC list, the HUD and `PlaygroundPlayerNet` read `controller.state.position`. `Playground._carry_riders` writes it back after the vehicles tick and before a run timer ([simulation.md](simulation.md#the-game-owns-the-tick-loop)).
- **The controller is turned off, not ignored**: `PlaygroundPlayer.riding` skips `simulate_tick` while still sampling, because the same keys drive the car. `Playground.drive_command` is the mapping, static so a test can reach it. The brake is `BUTTON_CROUCH`. The handbrake is `BUTTON_JUMP`. S brakes while the car rolls forward and reverses once it has stopped (dot-vehicle's `brake_then_reverse`, applied in `_drive_vehicles` where the vehicle's speed is known): the buggy from 50 km/h stops in 10.6 m on S, as on the brake. The handbrake does not slide (`handbrake_grip_fraction` left at 1.0).
- **Brakes are newtons** (dot-vehicle 4f4afaf; Godot read them as an impulse per step before, and the buggy stopped from 50 km/h in 1.85 m on the brake). The buggy's 5200 N on 620 kg stops it from 50 km/h in 10.5 m, the handbrake's 9000 N on the rear wheels in 7.2 m, and 0-50 km/h is 2.9 s; `headless_playground`'s vehicles section measures both from the plate's south-west corner facing +Z (-Z meets the plate's edge at z = -72 before 50 km/h).
- **A riding client stops predicting**: `PlaygroundPlayerNet` does no `simulate_tick` while riding and writes the server's position onto the node even on a predicted entity. The render-eye blend is skipped while riding (a blend toward a tick nothing simulated lurches backwards).
- **A car parked on the road cannot be got out of above walking pace** (`max_exit_speed`); a test that coasts is not stopped.
- **F gets in and out**, after F's use on a button or door ([sandbox.md](sandbox.md#the-tools)).
- A rider sits: `PlaygroundCharacter.set_seated` puts the person in its made sitting pose (`seated`) with its origin `seat_height()` under the seat; the capsule body drops by its leg height and swings the legs forward.

## Timed driving

There is no circuit here any more: it was `pg_lobby`'s bonus 3 and went with the map and the timer (2026-10-18, [timer.md](timer.md)). With dot-timer linked, a map can say a track is driven (`PlaygroundMap.track_is_driven`), and then getting in does not cancel the run and getting out ends it. **A loop whose start and finish are the same place finishes on the tick it starts**, so such a map puts its grid ahead of the finish line and the car crosses it on the way back.

## What a driver feels, and the decisions taken on it (`[veh-3]`)

dot-vehicle does not predict a vehicle: the driver's keys go to the server and the car they sit in is the client's interpolated mirror. `headless_net`'s vehicle section (`_measure_round_trip`) measures it on a loopback holding every message 3 ticks each way with every third snapshot dropped, and prints the figures. Roughly: the wire adds about 100-120 ms from key to visible on top of the car's own physics, the largest single term being the interpolation buffer. Asserted (generously): the mirror responds to throttle and steering within 40 ticks and **never before the server's car does**, and lands within 5 cm and 1 degree within 64 ticks of the car stopping.

- **No renderer-side smoothing of the mirror's position, and no prediction.** The position is already interpolated and steps evenly; every filter on top is more latency, which is the one thing the driver already has too much of. dot-vehicle's reasoning: a rigid body is not reproducible across machines, so a predicted vehicle is a corrected one, and a correction on something you steer reads worse than latency.
- **The other lever**, the driver's own car drawn with a smaller interpolation buffer than everybody else's (about 60 ms off key-to-visible, bought with visible stepping on every lost snapshot), is Christian's call.
- The heading used to snap at the snapshot rate because the rotation was four INTs; dot-vehicle now sends a `QUATERNION`, which dot-net slerps. `net_steering` and `net_speed` are still INT and step.
- For a heavy vehicle (mg-buses-from-hell's bus) the wire's share is the same ~100-120 ms but a small fraction of a response that already takes a second. Measure there before believing that.

## Harness notes

- In `headless_net` both halves share one physics space, so **the client's mirror is taken out of the physics world for the drive**; otherwise the server's buggy wedges against its own reflection.
- **A car crosses this sandbox in seconds.** Drive tests use the flat empty corner at (-60, -60).
- `PlaygroundClient.present_frame` interpolates only while the client's manager is RUNNING; the measurement calls `interpolate_frame` directly, or it reports a mirror stepping at the snapshot rate that no real client has.
