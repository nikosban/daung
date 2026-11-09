class_name ShipOrders
extends Node
## The sole authority for receiving and delaying one ship's commands. move() and stop() only receive a command. Each
## waits its own crew reaction delay on this node's physics clock in one FIFO queue and is then activated into
## Movement in receipt order; nothing is cancelled or skipped. Until then the active order stands.
## Runs before every ship's movement (process_physics_priority -20, set in Ships/ship.tscn), so all due commands activate before any ship moves.

@export var ship: ShipMovement
@export var crew: CrewProfile

## Physics clock in seconds: the sum of physics ticks so far.
var _clock := 0.0
## Received commands waiting for activation, in receipt order: {kind, position, received, due, move_receipt}.
var _pending: Array[Dictionary] = []
var _last_move_receipt := 0
## Physics clock of the last receipt and the last activation (-1 = none yet).
var _last_received := -1.0
var _last_activated := -1.0


func _ready() -> void:
	if crew == null or crew.reaction_delay < 0.0 or ship == null:
		push_error("ShipOrders needs a ship and a CrewProfile with reaction_delay at least 0; commands will not activate.")
		set_physics_process(false)


## Receives an order to the point. After the reaction delay it replaces the ship's active order. Y is ignored.
## Returns a positive per-ship receipt ID for observing this particular move.
func move(world_position: Vector3) -> int:
	_last_move_receipt += 1
	_receive("move", world_position, _last_move_receipt)
	return _last_move_receipt


## Receives a stop. After the reaction delay it ends the ship's active order.
func stop() -> void:
	_receive("stop", Vector3.ZERO)


## Physics clock in seconds.
func get_clock() -> float:
	return _clock


## Number of received commands waiting for activation.
func get_pending_count() -> int:
	return _pending.size()


## The next command to activate ({kind, position, received, due}), or an empty Dictionary if none is pending.
func get_next_pending() -> Dictionary:
	if _pending.is_empty():
		return {}
	var command := _pending[0].duplicate()
	command.erase("move_receipt")
	return command


## Physics clock of the last received command, or -1 if none.
func get_last_received_time() -> float:
	return _last_received


## Physics clock of the last activated command, or -1 if none.
func get_last_activated_time() -> float:
	return _last_activated


## The latest move receipt issued to this ship (0 = none yet).
func get_latest_receipt() -> int:
	return _last_move_receipt


## Returns the requested point while this move waits for activation, or null.
func get_pending_destination(move_receipt: int) -> Variant:
	if move_receipt <= 0:
		return null
	for command in _pending:
		if command.move_receipt == move_receipt:
			return command.position
	return null


func _physics_process(delta: float) -> void:
	_clock += delta
	while not _pending.is_empty() and _pending[0].due <= _clock:
		_activate(_pending.pop_front())


func _receive(kind: String, world_position: Vector3, move_receipt := 0) -> void:
	var delay := crew.reaction_delay if crew != null else 0.0
	var command := {kind = kind, position = world_position, received = _clock, due = _clock + delay,
		move_receipt = move_receipt}
	_pending.push_back(command)
	_last_received = _clock
	print("Orders: %s received %s at %.3f s, due %.3f s" % [ship.name, _describe(command), command.received, command.due])


func _activate(command: Dictionary) -> void:
	if command.kind == "move":
		ship.activate_move(command.position, command.move_receipt)
	else:
		ship.activate_stop()
	_last_activated = _clock
	print("Orders: %s activated %s at %.3f s (%.3f s after receipt)" % [ship.name, _describe(command), _clock, _clock - command.received])


func _describe(command: Dictionary) -> String:
	if command.kind == "move":
		return "move (%.1f, %.1f)" % [command.position.x, command.position.z]
	return "stop"
