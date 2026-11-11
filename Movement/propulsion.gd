class_name ShipPropulsion
extends RefCounted
## V4 propulsion (#102, MOV-01–MOV-04) as one pure step: applies main, retro and RCS commands within the profile's
## limits and writes the new planar velocity, yaw and turn rate back into the state. It never moves the position and
## never chooses commands; ShipMovement supplies them and integrates the position with move_and_slide().
##
## - Main engines accelerate along the bow only; retro thrusters toward the stern only. RCS only rotates the hull.
## - The three are independent: each has its own capacity and none reduces another.
## - Velocity changes only by applied main/retro acceleration. Rotating the hull never rotates, damps or cancels it,
##   so existing sideways drift is kept.
## - Speed limits restrict thrust, never velocity: main adds no speed along the bow beyond max_speed, retro adds none
##   toward the stern beyond max_reverse_speed.
## - RCS builds turn rate by turn_acceleration_curve(actual speed) up to turn_rate_curve(actual speed) while commanded;
##   without an RCS command the hull does not rotate (owner decision, #102).


## Planar ship state.
class State:
	var position := Vector3.ZERO
	## Planar velocity (Y is ignored on input and 0 on output).
	var velocity := Vector3.ZERO
	## Yaw in radians (0 = bow toward -Z, positive = counter-clockwise seen from above).
	var yaw := 0.0
	## Turn rate in rad/s.
	var turn_rate := 0.0


## Commands for one step: each engine's throttle and the RCS direction.
class Command:
	## Main engines, 0–1 of main_acceleration.
	var main := 0.0
	## Retro thrusters, 0–1 of retro_acceleration.
	var retro := 0.0
	## RCS, -1 (clockwise, right) to 1 (counter-clockwise, left) of the turn acceleration at the actual speed.
	var rcs := 0.0


## Last step's applied values, for the read-only debug getters.
class Output:
	## Applied acceleration along the bow (m/s²) and toward the stern (m/s²), after the speed limits.
	var main_acceleration := 0.0
	var retro_acceleration := 0.0
	## Applied angular acceleration (rad/s², signed), the RCS acceleration available and the turn-rate limit at the
	## actual speed (rad/s², rad/s).
	var turn_acceleration := 0.0
	var turn_authority := 0.0
	var turn_rate_limit := 0.0


static func step(profile: MovementProfile, state: State, command: Command, delta: float, out: Output) -> void:
	var velocity := Vector3(state.velocity.x, 0.0, state.velocity.z)
	var speed := velocity.length()
	var bow := bow_of(state.yaw)
	var along := velocity.dot(bow)

	# Main and retro: independent, each limited only by its own capacity and its own speed limit along the hull axis.
	var main := clampf(command.main, 0.0, 1.0) * profile.main_acceleration
	main = clampf(main, 0.0, maxf(profile.max_speed - along, 0.0) / delta)
	var retro := clampf(command.retro, 0.0, 1.0) * profile.retro_acceleration
	retro = clampf(retro, 0.0, maxf(profile.max_reverse_speed + along, 0.0) / delta)

	# RCS: rotation only. It adds turn rate toward the commanded side up to the limit; with no command, no rotation.
	var authority := deg_to_rad(maxf(profile.turn_acceleration_curve.sample(speed), 0.0))
	var rate_limit := deg_to_rad(maxf(profile.turn_rate_curve.sample(speed), 0.0))
	var rcs := clampf(command.rcs, -1.0, 1.0)
	var turn_acceleration := 0.0
	if rcs == 0.0:
		state.turn_rate = 0.0
	else:
		var side := signf(rcs)
		turn_acceleration = rcs * authority
		# The rate toward the commanded side never grows past the limit; turning back from the other side is unlimited
		# by it.
		var room := rate_limit - side * state.turn_rate
		turn_acceleration = side * clampf(absf(turn_acceleration), 0.0, maxf(room, 0.0) / delta)
		state.turn_rate += turn_acceleration * delta

	velocity += bow * (main - retro) * delta
	state.velocity = velocity
	state.yaw += state.turn_rate * delta

	out.main_acceleration = main
	out.retro_acceleration = retro
	out.turn_acceleration = turn_acceleration
	out.turn_authority = authority
	out.turn_rate_limit = rate_limit


## Unit planar bow for a yaw (0 = −Z, positive = counter-clockwise seen from above).
static func bow_of(yaw: float) -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))
