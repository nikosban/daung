class_name ShipVisualBank
extends Node3D
## Model-only roll for a ship's visual wrapper. Reads Movement; never writes it.
## Broad maneuvers heel outward, sharp maneuvers bank inward; the class is fixed per order.

@export var profile: ShipBankProfile
@export var movement: ShipMovement

var _roll := 0.0


func _physics_process(delta: float) -> void:
	var target := 0.0
	var deflection := movement.get_turn_deflection()
	var planar_velocity := Vector3(movement.velocity.x, 0.0, movement.velocity.z)
	var to_goal := movement.get_guidance_target() - movement.global_position
	to_goal.y = 0.0
	if movement.has_destination() and deflection != 0.0 and not planar_velocity.is_zero_approx() and not to_goal.is_zero_approx():
		# Still turning while the actual course is off the goal by at least the settle angle.
		if rad_to_deg(planar_velocity.angle_to(to_goal)) >= profile.settle_angle:
			var size := absf(deflection)
			var sharp := size >= profile.sharp_turn_angle or is_equal_approx(size, profile.sharp_turn_angle)
			# Positive roll about local +Z lowers the left side; a left turn has positive deflection.
			target = signf(deflection) * (profile.inward_bank if sharp else -profile.outward_heel)

	_roll = move_toward(_roll, target, profile.roll_rate * delta)
	rotation = Vector3(0.0, 0.0, deg_to_rad(_roll))
