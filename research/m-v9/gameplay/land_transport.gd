extends RefCounted
## Cargo and passenger duties claim the same existing ground transport equipment.
var _owner: WeakRef
var carriers: Dictionary = {}
var jobs: Dictionary = {}
var _unit_jobs: Dictionary = {}
var _tickets: Dictionary = {}
var _serial: int = 0
var _report_serial: int = 0
var passenger_capacity: Dictionary = {}
var passenger_rides: Dictionary = {}
var passenger_trips: Dictionary = {}
var patient_jobs: Dictionary = {}
var passenger_rules: Dictionary = {"handling_seconds": 15.0, "contact_km": 0.02, "patient_capacity": 1.0}
var rules: Dictionary = {"crew": 2.0, "handling_seconds": 30.0, "cargo_per_second": 1.0,
	"loaded_speed_factor": 0.65, "aircraft_load": 30.0, "aircraft_handling_seconds": 90.0,
	"local_radius_km": 0.03, "drag_speed_km_s": 0.0005, "aircraft_spares": 0.25}

func configure(gameplay: RefCounted) -> void:
	_owner = weakref(gameplay)

func admit(unit_ref: String, capacity: float, heavy_aircraft: bool = false) -> bool:
	var g: RefCounted = _owner.get_ref()
	if g._state.time != 0.0 or carriers.size() >= 2 or carriers.has(unit_ref) or not g._state.units.has(unit_ref) or capacity <= 0.0:
		return false
	var unit: Dictionary = g._state.units[unit_ref]
	if not unit.has("spatial") or unit.spatial.mode != "MOTORIZED" or float(unit.serviceable_equipment) < 1.0:
		return false
	carriers[unit_ref] = {"capacity": capacity, "initial_equipment": unit.serviceable_equipment,
		"transport_equipment": 2.0, "heavy_aircraft": heavy_aircraft, "report_source": "land_dispatch_" + unit_ref}
	var s: RefCounted = g._state.structure_port.get_ref()
	return g._state.information_port.get_ref().register_platform_source(str(carriers[unit_ref].report_source), str(s._path(str(s._unit_nodes[unit_ref])).back()), self)

func capacity(unit: Dictionary) -> float:
	if not carriers.has(unit.id) or minf(float(unit.effective), float(unit.get("gameplay_personnel", {}).get("anonymous", unit.effective))) < float(rules.crew):
		return 0.0
	var fraction: float = minf(1.0, float(unit.serviceable_equipment) / float(carriers[unit.id].initial_equipment))
	return float(carriers[unit.id].capacity) * fraction if float(carriers[unit.id].transport_equipment) * fraction >= 0.5 else 0.0

func _position(unit: Dictionary) -> Dictionary:
	return {"node_ref": unit.spatial.node, "edge_ref": unit.spatial.edge, "progress": unit.spatial.progress,
		"xy": _owner.get_ref()._space.xy(unit).duplicate()}

func _at(unit: Dictionary, node: String) -> bool:
	return str(unit.spatial.edge) == "" and unit.spatial.node == node

func _quantity(cargo: Dictionary) -> float:
	var total: float = 0.0
	for resource: String in cargo:
		total += float(cargo[resource])
	return total

func route(actor: String, unit: Dictionary, node: String, path: Array, returning: bool = false) -> Dictionary:
	var g: RefCounted = _owner.get_ref()
	if not g._known.get(actor, {}).get(node, []).has(path):
		return g._reject("land_route_not_in_person_known_map")
	if path.is_empty():
		return {"ok": true} if _at(unit, node) or returning and unit.spatial.edge != "" and unit.spatial.from == node else g._reject("actual_route_or_leg_return_required")
	var route_unit: Dictionary = unit
	if str(unit.spatial.edge) != "" and not returning:
		if path[0] != unit.spatial.edge:
			return g._reject("continue_the_actual_road_leg_before_new_connections")
		route_unit = unit.duplicate(true)
		route_unit.spatial.node = unit.spatial.from
		route_unit.spatial.edge = ""
	var valid: Dictionary = g._space.validate_path(route_unit, path, returning)
	if not valid.ok:
		return valid
	var current: String = str(unit.spatial.from) if unit.spatial.edge != "" else str(unit.spatial.node)
	for edge_id: String in path:
		var edge: Dictionary = g._space._edges[edge_id]
		current = str(edge.to) if current == edge.from else str(edge.from)
	return {"ok": true} if current == node else g._reject("land_route_must_reach_handover_node")

func _free(actor: String, unit_ref: String) -> bool:
	if passenger_busy(unit_ref):
		return false
	var g: RefCounted = _owner.get_ref()
	var l: RefCounted = g._state.logistics_port.get_ref()
	if not carriers.has(unit_ref) or not g._state.units.has(unit_ref) or _unit_jobs.has(unit_ref) or g.air.recovery._unit_jobs.has(unit_ref) or g.operations.occupied_ground(unit_ref) or g.tactics.occupied(unit_ref) or not l._allowed(actor, "unit", unit_ref, 3):
		return false
	var unit: Dictionary = g._state.units[unit_ref]
	return capacity(unit) > 0.0 and float(unit.fuel) > 0.0 and str(unit.spatial.edge) == "" and unit.spatial.path.is_empty() and g._state.coordination.get(unit_ref, {}).is_empty()

func validate(actor: String, target: String, values: Dictionary, id: String) -> Dictionary:
	if values.has("passenger_action"):
		return validate_passenger_drive(actor, target, values)
	var g: RefCounted = _owner.get_ref()
	var l: RefCounted = g._state.logistics_port.get_ref()
	if target != g._state.structure_port.get_ref().command_person(actor).formation_id:
		return g._reject("land_duty_requires_current_owning_command_position")
	if values.get("operation", "") != "transport":
		return _validate_change(actor, values, id)
	for key: String in values:
		if key not in ["operation", "unit_ref", "source_ref", "recipient_kind", "recipient_ref", "target_node", "approach_path", "path", "cargo", "request_ref", "notify"]:
			return g._reject("unknown_land_transport_parameter")
	if jobs.size() >= 64 or jobs.has(id) or l._deliveries.size() >= 128 or l._deliveries.has(id) or not values.get("unit_ref") is String or not _free(actor, str(values.unit_ref)) or not values.get("source_ref") is String or not l._depots.has(values.source_ref) or not values.get("cargo") is Dictionary or values.cargo.is_empty() or not values.get("approach_path") is Array or not values.get("path") is Array or not values.get("target_node") is String:
		return g._reject("finite_free_ground_carrier_source_manifest_and_routes_required")
	if values.get("recipient_kind", "") not in ["unit", "depot"] or not values.get("recipient_ref") is String or not l._allowed(actor, "depot", str(values.source_ref), 3) or not l._allowed(actor, str(values.recipient_kind), str(values.recipient_ref), 3):
		return g._reject("actual_supply_and_receiver_authority_required")
	var unit: Dictionary = g._state.units[values.unit_ref]
	for resource: String in values.cargo:
		if not l.CLASSES.has(resource) or not l._positive(values.cargo[resource]) or float(values.cargo[resource]) > l.available_stock(str(values.source_ref), resource):
			return g._reject("actual_available_Task6_cargo_required")
		if resource == "FUEL" and values.recipient_kind == "unit" and not g._lod.preview_leaf(str(values.recipient_ref)).get("supply_capability", {}).get("fuel_dependent", false):
			return g._reject("fuel_receiver_capability_required")
	if _quantity(values.cargo) > capacity(unit):
		return g._reject("manifest_exceeds_actual_ground_capacity")
	if values.recipient_kind == "depot" and l._depots[values.recipient_ref].node_ref != values.target_node:
		return g._reject("depot_requires_its_actual_handover_node")
	var source_node: String = str(l._depots[values.source_ref].node_ref)
	var valid: Dictionary = route(actor, unit, source_node, values.approach_path)
	if not valid.ok:
		return valid
	var projected: Dictionary = unit.duplicate(true)
	projected.spatial.node = source_node
	projected.spatial.edge = ""
	valid = route(actor, projected, str(values.target_node), values.path)
	if not valid.ok:
		return valid
	var request_ref: String = str(values.get("request_ref", ""))
	if request_ref != "":
		if not l._requests.has(request_ref):
			return g._reject("existing_supply_request_required")
		var request: Dictionary = l._requests[request_ref]
		if request.status != "REQUESTED" or request.target_kind != values.recipient_kind or request.target != values.recipient_ref or not values.cargo.has(request.resource_class) or float(values.cargo[request.resource_class]) > float(request.quantity) - float(request.get("received_quantity", 0.0)):
			return g._reject("compatible_waiting_request_and_remaining_quantity_required")
		if request.get("sea_required", false):
			var sea_ref: String = str(request.get("sea_delivery_ref", ""))
			if not l._deliveries.has(sea_ref) or l._deliveries[sea_ref].status not in ["RECEIVED", "ONBOARD"] or l.physical_balance(request_ref).get("port_depot_ref", "") != values.source_ref:
				return g._reject("sea_cargo_requires_actual_destination_port_stock")
			for resource: String in values.cargo:
				if float(values.cargo[resource]) > l.sea_port_remaining(sea_ref, resource, request_ref, str(values.source_ref)) + 0.000001:
					return g._reject("land_manifest_must_use_unforwarded_port_batch")
	return _notify_allowed(actor, values.get("notify", []))

func _notify_allowed(actor: String, recipients: Variant) -> Dictionary:
	var g: RefCounted = _owner.get_ref()
	var s: RefCounted = g._state.structure_port.get_ref()
	if not recipients is Array or recipients.size() > 3:
		return g._reject("bounded_transport_report_recipients_required")
	for person: Variant in recipients:
		if not person is String or not s._people.has(person) or s._nodes[s._people[person].formation_id].side != s._nodes[s.command_person(actor).formation_id].side:
			return g._reject("existing_same_side_report_recipient_required")
	return {"ok": true}

func _validate_change(actor: String, values: Dictionary, command_id: String) -> Dictionary:
	var g: RefCounted = _owner.get_ref()
	if not values.get("transport_ref") is String or not jobs.has(values.transport_ref):
		return g._reject("existing_land_transport_required")
	var job: Dictionary = jobs[values.transport_ref]
	var l: RefCounted = g._state.logistics_port.get_ref()
	if not l._allowed(actor, "unit", str(job.unit_ref), 3) or job.status in ["RECEIVED", "CANCELLED_BEFORE_LOADING"]:
		return g._reject("current_unfinished_carrier_command_required")
	if values.get("operation", "") == "stop_transport":
		return {"ok": true} if values.size() == 2 else g._reject("explicit_transport_stop_required")
	var subject: String = str(job.asset_ref) if job.payload_kind == "AIRCRAFT" else str(l._deliveries[job.id].recipient_ref)
	var subject_kind: String = "aircraft" if job.payload_kind == "AIRCRAFT" else str(l._deliveries[job.id].recipient_kind)
	var learned: bool = false
	for claim: Dictionary in g._state.information_port.get_ref().knowledge(actor, subject_kind, subject, "land_supply_status").get("entries", []):
		if claim.claimed_value.get("transport_ref", "") == job.id and claim.claimed_value.get("status", "") == job.status and float(claim.reliability) > 0.0:
			learned = true
	if not learned:
		return g._reject("delivered_current_transport_obstruction_or_handover_report_required")
	if values.get("operation", "") == "continue_transport":
		return {"ok": true} if values.size() == 2 and job.payload_kind == "CARGO" and job.status not in ["LOST", "CARGO_LOST"] else g._reject("existing_unfinished_cargo_responsibility_required")
	if values.get("operation", "") == "recover_cargo":
		if values.size() != 3 or job.payload_kind != "CARGO" or job.status != "STRANDED" or not values.get("unit_ref") is String or not _free(actor, str(values.unit_ref)) or not g.operations.permits_carrier_recovery(str(values.unit_ref), command_id):
			return g._reject("stranded_cargo_and_free_actual_recovery_carrier_required")
		var unit: Dictionary = g._state.units[values.unit_ref]
		return {"ok": true} if _at(unit, str(job.stranded_position.node_ref)) and job.stranded_position.edge_ref == "" and g.air._distance(g._space.xy(unit), job.stranded_position.xy) <= 0.000001 and capacity(unit) >= _quantity(l._deliveries[job.id].cargo) else g._reject("actual_stranded_cargo_rendezvous_and_capacity_required")
	if values.get("operation", "") not in ["resume_transport", "redirect_transport", "unload"]:
		return g._reject("unknown_land_transport_operation")
	if values.operation == "unload":
		return {"ok": true} if values.size() == 2 and job.status in ["WAITING_RECIPIENT", "STOPPED", "BLOCKED"] and _at(g._state.units[job.unit_ref], str(job.target_node)) else g._reject("actual_handover_location_required")
	if job.status not in ["BLOCKED", "STOPPED", "WAITING_RECIPIENT", "CAPACITY_LOST", "FUEL_EXHAUSTED", "TEMPORARILY_IMMOBILE"] or not values.get("path") is Array or not values.get("target_node") is String or not values.get("return_to_start", false) is bool:
		return g._reject("stopped_actual_transport_and_explicit_known_route_required")
	var unit: Dictionary = g._state.units[job.unit_ref]
	if capacity(unit) < _load(job) or float(unit.fuel) <= 0.0:
		return g._reject("actual_carrier_capacity_and_fuel_required")
	var leg_target: String = str(job.target_node) if job.loaded else str(job.source_node)
	if job.payload_kind == "AIRCRAFT" and values.target_node != leg_target:
		return g._reject("aircraft_return_keeps_declared_receiving_base")
	if job.payload_kind == "CARGO" and values.operation == "redirect_transport":
		var kind: String = str(values.get("recipient_kind", ""))
		var recipient: String = str(values.get("recipient_ref", ""))
		if kind not in ["unit", "depot"] or not l._allowed(actor, kind, recipient, 3) or kind == "depot" and l._depots[recipient].node_ref != values.target_node:
			return g._reject("explicit_authorized_redirect_receiver_required")
		var reference: String = str(values.get("request_ref", ""))
		if reference != "" and reference != str(l._deliveries[job.id].request_id):
			var request: Dictionary = l._requests.get(reference, {})
			var cargo: Dictionary = l._deliveries[job.id].cargo
			if not job.loaded or request.get("status", "") != "REQUESTED" or request.get("target_kind", "") != kind or request.get("target", "") != recipient or cargo.size() != 1 or not cargo.has(request.get("resource_class", "")) or float(cargo.get(request.get("resource_class", ""), 0.0)) > float(l.physical_balance(reference).get("uncommitted_quantity", 0.0)):
				return g._reject("compatible_uncommitted_request_for_same_actual_loaded_cargo_required")
	elif values.target_node != leg_target:
		return g._reject("resume_preserves_handover_location")
	return route(actor, unit, str(values.target_node), values.path, bool(values.get("return_to_start", false)))

func apply(actor: String, values: Dictionary, id: String) -> Dictionary:
	if values.has("passenger_action"):
		return passenger_drive(actor, str(values.get("carrier_ref", "")), id, values)
	var g: RefCounted = _owner.get_ref()
	if values.operation == "continue_transport":
		var continued: Dictionary = jobs[values.transport_ref]
		continued.previous_issuer = continued.issuer
		continued.issuer = actor
		continued.responsibility_revision = int(continued.get("responsibility_revision", 0)) + 1
		_report(continued, "RESPONSIBILITY_CONTINUED")
		return {"ok": true, "changed": [], "retired": [], "state_delta": {"land_transport": {"transport_ref": continued.id}}}
	if values.operation == "transport":
		g._state.logistics_port.get_ref().reserve_land(actor, id, str(values.source_ref), str(values.recipient_kind), str(values.recipient_ref), values.cargo, str(values.unit_ref), str(values.target_node), str(values.get("request_ref", "")))
		var source_node: String = str(g._state.logistics_port.get_ref()._depots[values.source_ref].node_ref)
		_start(actor, id, str(values.unit_ref), source_node, str(values.target_node), values.approach_path, values.path, "CARGO", "", values.get("notify", []))
	else:
		var job: Dictionary = jobs[values.transport_ref]
		job.issuer = actor
		job.version += 1
		job.pending = ""
		if values.operation == "stop_transport":
			if job.payload_kind == "AIRCRAFT" and not job.loaded:
				_end(job, "CANCELLED_BEFORE_LOADING")
			elif job.payload_kind == "CARGO" and g._state.logistics_port.get_ref()._deliveries[job.id].status == "RESERVED_AT_SOURCE":
				g._state.logistics_port.get_ref().cancel_land_reservation(str(job.id))
				_end(job, "CANCELLED_BEFORE_LOADING")
			else:
				_pause(job, "STOPPED")
		elif values.operation == "recover_cargo":
			_unit_jobs.erase(job.unit_ref)
			job.unit_ref = values.unit_ref
			_unit_jobs[job.unit_ref] = job.id
			g._state.logistics_port.get_ref()._deliveries[job.id].carrier_ref = job.unit_ref
			g._state.logistics_port.get_ref()._deliveries[job.id].status = "ONBOARD"
			job.loaded = true
			job.status = "STOPPED"
			_report(job, "CARGO_RECOVERED_AT_ACTUAL_POSITION")
		elif values.operation == "unload":
			_begin_unload(job)
		else:
			if values.operation == "redirect_transport" and job.payload_kind == "CARGO":
				var delivery: Dictionary = g._state.logistics_port.get_ref()._deliveries[job.id]
				var reference: String = str(values.get("request_ref", delivery.request_id if delivery.recipient_ref == values.recipient_ref else ""))
				if delivery.request_id != "" and delivery.request_id != reference:
					g._state.logistics_port.get_ref()._requests[delivery.request_id].status = "REQUESTED"
					if g._state.logistics_port.get_ref()._requests[delivery.request_id].get("land_delivery_ref", "") == delivery.delivery_id:
						g._state.logistics_port.get_ref()._requests[delivery.request_id].erase("land_delivery_ref")
					if not delivery.has("original_request_ref"):
						delivery.original_request_ref = delivery.request_id
					delivery.previous_request_ref = delivery.request_id
					delivery.request_id = ""
				if reference != "":
					delivery.request_id = reference
					g._state.logistics_port.get_ref()._requests[reference].land_delivery_ref = delivery.delivery_id
					g._state.logistics_port.get_ref()._requests[reference].status = "ALLOCATED_LAND"
				delivery.recipient_kind = values.recipient_kind
				delivery.recipient_ref = values.recipient_ref
				delivery.required_node = values.target_node
			if job.loaded:
				job.target_node = values.target_node
			_move(job, str(values.target_node), values.path, "IN_TRANSIT" if job.loaded else "APPROACHING_SOURCE", bool(values.get("return_to_start", false)))
	return {"ok": true, "changed": [str(values.get("unit_ref", jobs.get(values.get("transport_ref", ""), {}).get("unit_ref", "")))], "retired": [], "state_delta": {"land_transport": {"transport_ref": id if values.operation == "transport" else values.transport_ref}}}

func start_aircraft(actor: String, id: String, unit_ref: String, asset_ref: String, pickup: String, base: String, approach: Array, path: Array) -> void:
	_start(actor, id, unit_ref, pickup, base, approach, path, "AIRCRAFT", asset_ref, [])

func _start(actor: String, id: String, unit_ref: String, source: String, target: String, approach: Array, path: Array, kind: String, asset_ref: String, notify: Array) -> void:
	var g: RefCounted = _owner.get_ref()
	jobs[id] = {"id": id, "issuer": actor, "unit_ref": unit_ref, "source_node": source, "target_node": target,
		"path": path.duplicate(), "payload_kind": kind, "asset_ref": asset_ref, "loaded": false,
		"status": "APPROACHING_SOURCE", "notify": notify.duplicate(), "version": 0, "pending": "",
		"started_at": g._state.time, "fuel_spent": 0.0, "distance_km": 0.0, "loss_notice": false}
	_unit_jobs[unit_ref] = id
	_move(jobs[id], source, approach, "APPROACHING_SOURCE")

func _move(job: Dictionary, node: String, path: Array, status: String, returning: bool = false) -> void:
	var g: RefCounted = _owner.get_ref()
	job.status = status
	job.motion_blocked = false
	job.version += 1
	var result: Dictionary = g._assign(str(job.unit_ref), str(job.id) + "_leg_%d" % int(job.version), str(job.issuer), {"intent": "advance", "target_node": node, "path": path.duplicate(), "return_to_start": returning})
	if not result.ok:
		if job.get("payload_kind", "") == "PASSENGERS":
			_stop_passenger_vehicle(str(job.unit_ref), "BLOCKED")
			return
		_pause(job, "BLOCKED")
		return
	job.mission_ref = result.mission_id
	if job.get("payload_kind", "") == "PASSENGERS":
		on_unit(str(job.unit_ref))
		return
	_report(job, status)
	_queue(job, "CHECK", g._state.time + 0.000001)

func _load(job: Dictionary) -> float:
	if job.payload_kind == "AIRCRAFT":
		return float(rules.aircraft_load)
	return _quantity(_owner.get_ref()._state.logistics_port.get_ref()._deliveries[job.id].cargo)

func posture(unit_ref: String) -> String:
	if passenger_trips.has(unit_ref):
		return "advance" if passenger_trips[unit_ref].status == "DRIVING" else "reserve"
	if not _unit_jobs.has(unit_ref):
		return ""
	var job: Dictionary = jobs[_unit_jobs[unit_ref]]
	return "advance" if job.status in ["APPROACHING_SOURCE", "IN_TRANSIT"] else "reserve"

func prepare(unit: Dictionary, plan: Dictionary) -> void:
	if passenger_busy(str(unit.id)):
		plan.commitment = 0.0
		prepare_passenger_damage(unit, plan)
	if _unit_jobs.has(unit.id):
		plan.commitment = 0.0

func constrain(unit: Dictionary, plan: Dictionary) -> void:
	if passenger_busy(str(unit.id)):
		var trip: Dictionary = passenger_trips.get(unit.id, {})
		var ended: bool = not trip.is_empty() and trip.get("mission_ref", "") == unit.mission_id and _owner.get_ref()._state.missions[unit.mission_id].status != "active"
		if trip.get("status", "") != "DRIVING" or ended or passenger_handling(str(unit.id)) or passenger_load(str(unit.id)) > seats(str(unit.id)):
			plan.speed = 0.0
		return
	if not _unit_jobs.has(unit.id):
		return
	var job: Dictionary = jobs[_unit_jobs[unit.id]]
	if job.status not in ["APPROACHING_SOURCE", "IN_TRANSIT"] or capacity(unit) < _load(job):
		plan.speed = 0.0
	elif job.loaded:
		plan.speed *= float(rules.loaded_speed_factor)

func after_unit(unit: Dictionary, travelled: float, spent_before: float, plan: Dictionary) -> void:
	if passenger_trips.has(unit.id):
		var trip: Dictionary = passenger_trips[unit.id]
		trip.distance_km += travelled
		trip.fuel_spent += maxf(0.0, float(unit.fuel_spent) - spent_before)
		if trip.status == "DRIVING" and (plan.get("advance_inhibited", false) or plan.posture == "withdraw" or float(unit.mobility) <= 0.0 or float(unit.readiness) <= 0.0 or not _owner.get_ref()._space.can_move(unit)):
			_stop_passenger_vehicle(str(unit.id), "BLOCKED")
	_sync_passengers(str(unit.id))
	if not _unit_jobs.has(unit.id):
		return
	var job: Dictionary = jobs[_unit_jobs[unit.id]]
	job.distance_km += travelled
	job.fuel_spent += maxf(0.0, float(unit.fuel_spent) - spent_before)
	if job.status in ["APPROACHING_SOURCE", "IN_TRANSIT"] and (unit.spatial.edge != "" or not unit.spatial.path.is_empty()):
		if plan.get("advance_inhibited", false) or plan.posture == "withdraw" or float(unit.mobility) <= 0.0 or float(unit.readiness) <= 0.0 or not _owner.get_ref()._space.can_move(unit):
			job.motion_blocked = true
			_queue(job, "CHECK", _owner.get_ref()._state.time + 0.000001)
	on_unit(str(unit.id))

func on_capacity_loss(unit: Dictionary, equipment_loss: float) -> void:
	if not _unit_jobs.has(unit.id):
		return
	var job: Dictionary = jobs[_unit_jobs[unit.id]]
	if job.loaded and equipment_loss > 0.0:
		if job.payload_kind == "CARGO":
			_owner.get_ref()._state.logistics_port.get_ref().lose_land_cargo(str(job.id), minf(0.5, equipment_loss / maxf(1.0, float(unit.equipment) + equipment_loss)), _position(unit))
		else:
			var asset: Dictionary = _owner.get_ref().air.assets[job.asset_ref]
			_owner.get_ref().air.damage(str(asset.id), 0.1 * equipment_loss / maxf(1.0, float(unit.equipment) + equipment_loss), "ground_transport_loss_" + str(job.id))
		job.loss_notice = true
	on_unit(str(unit.id))

func on_unit(unit_ref: String) -> void:
	_passenger_changed(unit_ref)
	if not _unit_jobs.has(unit_ref):
		return
	var g: RefCounted = _owner.get_ref()
	var job: Dictionary = jobs[_unit_jobs[unit_ref]]
	var unit: Dictionary = g._state.units[unit_ref]
	if job.status not in ["APPROACHING_SOURCE", "IN_TRANSIT", "LOADING", "UNLOADING"] and not job.loss_notice:
		return
	var destination: String = str(job.source_node) if not job.loaded else str(job.target_node)
	var handling_interrupted: bool = job.status in ["LOADING", "UNLOADING"] and capacity(unit) < _load(job)
	if handling_interrupted and job.pending != "":
		job.version += 1
		job.pending = ""
	if job.loss_notice or capacity(unit) < _load(job) or job.status in ["APPROACHING_SOURCE", "IN_TRANSIT"] and (float(unit.fuel) <= 0.0 or str(unit.spatial.blocked_edge) != "" or _at(unit, destination)):
		_queue(job, "CHECK", g._state.time + 0.000001)

func _queue(job: Dictionary, kind: String, due: float) -> void:
	if job.pending != "":
		return
	var g: RefCounted = _owner.get_ref()
	_serial += 1
	var id: String = "land_" + str(job.id) + "_%d" % _serial
	_tickets[id] = {"job_ref": job.id, "version": job.version, "kind": kind, "due": due, "status": "PENDING"}
	job.pending = id
	g._state.schedule_event(id, due, "gameplay", {"land_id": id})

func accepts_event(id: String, payload: Dictionary, due: float) -> bool:
	if _tickets.has(id) and (str(_tickets[id].kind).begins_with("PASSENGER_") or str(_tickets[id].kind).begins_with("PATIENT_")):
		return payload.get("land_id", "") == id and _tickets[id].status == "PENDING" and _tickets[id].due == due
	return payload.get("land_id", "") == id and _tickets.has(id) and _tickets[id].status == "PENDING" and _tickets[id].due == due and jobs[_tickets[id].job_ref].version == _tickets[id].version

func process_event(event: Dictionary) -> Dictionary:
	if str(_tickets[event.id].kind).begins_with("PATIENT_"):
		return _finish_vehicle_patient(event)
	if str(_tickets[event.id].kind).begins_with("PASSENGER_"):
		return _finish_passenger(event)
	var ticket: Dictionary = _tickets[event.id]
	ticket.status = "PROCESSED"
	var job: Dictionary = jobs[ticket.job_ref]
	job.pending = ""
	var g: RefCounted = _owner.get_ref()
	var unit: Dictionary = g._state.units[job.unit_ref]
	var changed: Array = [job.unit_ref]
	var retired: Array = []
	if job.status in ["RECEIVED", "CANCELLED_BEFORE_LOADING"]:
		return {"changed": [], "retired": [], "record": {"kind": "land_transport", "status": job.status}}
	if job.loss_notice:
		job.loss_notice = false
		_report(job, "PARTIAL_CARGO_LOSS" if job.payload_kind == "CARGO" else "AIRCRAFT_DAMAGED_IN_TRANSIT", true)
	if job.status == "STRANDED":
		return {"changed": changed, "retired": [], "record": {"kind": "land_transport", "status": "STRANDED"}}
	if job.payload_kind == "AIRCRAFT" and g.air.assets[job.asset_ref].status == "DESTROYED":
		_end(job, "AIRCRAFT_DESTROYED")
	elif capacity(unit) < _load(job):
		if capacity(unit) <= 0.0 and job.loaded:
			job.stranded_position = _position(unit)
			if job.payload_kind == "CARGO":
				var delivery: Dictionary = g._state.logistics_port.get_ref()._deliveries[job.id]
				delivery.status = "STRANDED"
				delivery.actual_position = job.stranded_position.duplicate(true)
			else:
				_drop_aircraft(job)
			_pause(job, "STRANDED")
		else:
			_pause(job, "CAPACITY_LOST")
	elif ticket.kind == "LOAD":
		if not _at(unit, str(job.source_node)):
			_pause(job, "LOADING_INTERRUPTED")
		elif job.payload_kind == "CARGO" and not g._state.logistics_port.get_ref().load_land(str(job.id)):
			_pause(job, "LOADING_INTERRUPTED")
		else:
			if job.payload_kind == "AIRCRAFT":
				var asset: Dictionary = g.air.assets[job.asset_ref]
				if asset.status != "GROUND_LOADING" or asset.recovery_ref != job.id:
					_end(job, "AIRCRAFT_LOADING_INTERRUPTED")
					return {"changed": changed, "retired": [], "record": {"status": job.status}}
				asset.xy = g._space.xy(unit)
				asset.status = "CARRIED_LAND"
			job.loaded = true
			_move(job, str(job.target_node), job.path, "IN_TRANSIT")
	elif ticket.kind == "UNLOAD":
		if not _at(unit, str(job.target_node)):
			_pause(job, "UNLOADING_INTERRUPTED")
		elif job.payload_kind == "CARGO":
			var receipt: Dictionary = g._state.logistics_port.get_ref().receive_land(str(job.id))
			if receipt.ok:
				changed.append_array(receipt.get("changed", []))
				retired.append_array(receipt.get("retired", []))
				_end(job, "RECEIVED")
			else:
				_pause(job, "WAITING_RECIPIENT")
		else:
			var asset: Dictionary = g.air.assets[job.asset_ref]
			if not g.air.support.bases.has(job.target_node) or g.air.support.bases[job.target_node].owner != asset.owner or not g._space._nodes[job.target_node].get("airfield_open", false):
				_pause(job, "WAITING_RECIPIENT")
			else:
				asset.xy = g._space.xy(unit)
				asset.node = job.target_node
				asset.base = job.target_node
				asset.status = "GROUNDED"
				asset.serviceable = false
				asset.recovery_ref = ""
				asset.landing.recovered_at = g._state.time
				_end(job, "RECEIVED")
	elif job.status in ["APPROACHING_SOURCE", "IN_TRANSIT"]:
		var destination: String = str(job.source_node) if not job.loaded else str(job.target_node)
		if _at(unit, destination):
			if job.loaded:
				_begin_unload(job)
			else:
				_begin_load(job)
		elif float(unit.fuel) <= 0.0:
			_pause(job, "FUEL_EXHAUSTED")
		elif str(unit.spatial.blocked_edge) != "" or g._state.missions[unit.mission_id].status != "active":
			_pause(job, "BLOCKED")
		elif job.get("motion_blocked", false):
			job.motion_blocked = false
			_pause(job, "TEMPORARILY_IMMOBILE")
	return {"changed": changed, "retired": retired, "record": {"kind": "land_transport", "transport_ref": job.id, "status": job.status}}

func _begin_load(job: Dictionary) -> void:
	var g: RefCounted = _owner.get_ref()
	var seconds: float = float(rules.handling_seconds) + _load(job) / float(rules.cargo_per_second)
	if job.payload_kind == "AIRCRAFT":
		var asset: Dictionary = g.air.assets[job.asset_ref]
		if asset.status != "AWAITING_RECOVERY" or asset.landing.surface != "LAND" or g.air._distance(asset.xy, g._space._nodes[job.source_node].xy) > float(rules.local_radius_km) or g._space.movement_factor(g._space._nodes[job.source_node].ground, "MOTORIZED") <= 0.0:
			_end(job, "AIRCRAFT_NOT_ACCESSIBLE_AT_DECLARED_ROAD_NODE")
			return
		var unit: Dictionary = g._state.units[job.unit_ref]
		if float(unit.spares) < float(rules.aircraft_spares):
			_pause(job, "LOADING_INTERRUPTED")
			return
		unit.spares -= float(rules.aircraft_spares)
		unit.spares_spent += float(rules.aircraft_spares)
		g._state.logistics_ledger.spares_spent += float(rules.aircraft_spares)
		seconds = float(rules.aircraft_handling_seconds) + g.air._distance(asset.xy, g._space._nodes[job.source_node].xy) / float(rules.drag_speed_km_s)
		job.local_from = asset.xy.duplicate()
		job.local_to = g._space._nodes[job.source_node].xy.duplicate()
		job.local_started_at = g._state.time + float(rules.aircraft_handling_seconds)
		job.local_due = g._state.time + seconds
		asset.status = "GROUND_LOADING"
	job.status = "LOADING"
	_report(job, "LOADING")
	_queue(job, "LOAD", g._state.time + seconds)

func _begin_unload(job: Dictionary) -> void:
	job.status = "UNLOADING"
	var seconds: float = float(rules.aircraft_handling_seconds) if job.payload_kind == "AIRCRAFT" else float(rules.handling_seconds) + _load(job) / float(rules.cargo_per_second)
	_report(job, "UNLOADING")
	_queue(job, "UNLOAD", _owner.get_ref()._state.time + seconds)

func _pause(job: Dictionary, status: String) -> void:
	var g: RefCounted = _owner.get_ref()
	if job.payload_kind == "AIRCRAFT" and g.air.assets[job.asset_ref].status == "GROUND_LOADING":
		var asset: Dictionary = g.air.assets[job.asset_ref]
		asset.xy = aircraft_position(asset)
		asset.status = "AWAITING_RECOVERY"
	job.version += 1
	job.pending = ""
	job.status = status
	var unit: Dictionary = g._state.units[job.unit_ref]
	unit.spatial.path = []
	unit.spatial.returning = false
	g._state.wake(str(unit.area_id))
	_report(job, status)

func _end(job: Dictionary, status: String) -> void:
	var g: RefCounted = _owner.get_ref()
	if job.payload_kind == "AIRCRAFT":
		var asset: Dictionary = g.air.assets[job.asset_ref]
		if status != "RECEIVED" and asset.status != "DESTROYED":
			_drop_aircraft(job)
		asset.recovery_ref = ""
		job.loaded = false
	elif status == "RECEIVED":
		job.loaded = false
	_pause(job, status)
	_unit_jobs.erase(job.unit_ref)
	job.finished_at = g._state.time
	var unit: Dictionary = g._state.units[job.unit_ref]
	var mission: Dictionary = g._state.missions[unit.mission_id]
	if mission.status == "active":
		g._finish(unit, mission, "complete" if status == "RECEIVED" else "cancelled", "physical_transport_finished", str(job.id))

func _drop_aircraft(job: Dictionary) -> void:
	var g: RefCounted = _owner.get_ref()
	var asset: Dictionary = g.air.assets[job.asset_ref]
	asset.xy = aircraft_position(asset)
	asset.status = "AWAITING_RECOVERY"
	asset.node = g._space.landing_site(asset.xy, str(g._state.units[job.unit_ref].spatial.node)).node_ref
	asset.landing = {"surface": "LAND", "node_ref": asset.node, "xy": asset.xy.duplicate(), "at": g._state.time}
	asset.recovery_ref = ""

func aircraft_position(asset: Dictionary) -> Array:
	var job: Dictionary = jobs[asset.recovery_ref]
	if asset.status == "GROUND_LOADING":
		var fraction: float = clampf((_owner.get_ref()._state.time - float(job.local_started_at)) / maxf(0.000001, float(job.local_due) - float(job.local_started_at)), 0.0, 1.0)
		return [lerpf(float(job.local_from[0]), float(job.local_to[0]), fraction), lerpf(float(job.local_from[1]), float(job.local_to[1]), fraction)]
	return _owner.get_ref()._space.xy(_owner.get_ref()._state.units[job.unit_ref]) if job.loaded else asset.xy

func _report(job: Dictionary, status: String, force: bool = false) -> void:
	if not force and job.get("reported_status", "") == status:
		return
	job.reported_status = status
	_report_serial += 1
	var g: RefCounted = _owner.get_ref()
	var unit: Dictionary = g._state.units[job.unit_ref]
	var value: Dictionary = _position(unit)
	value.blocked_edge = unit.spatial.blocked_edge
	value.blocked_at = unit.spatial.get("blocked_at", 0.0)
	value.merge({"transport_ref": job.id, "status": status, "target_node": job.target_node, "payload_kind": job.payload_kind,
		"carrier_ref": job.unit_ref, "source_node": job.source_node, "report_revision": _report_serial,
		"transport_status": job.status, "loaded": job.loaded, "fuel_spent": job.fuel_spent, "distance_km": job.distance_km})
	var recipients: Array = job.notify.duplicate()
	if job.issuer not in recipients:
		recipients.append(job.issuer)
	var structure: RefCounted = g._state.structure_port.get_ref()
	for scope: String in structure._path(str(structure._unit_nodes.get(job.unit_ref, ""))):
		var current: String = str(structure._positions.get(scope, {}).get("person", ""))
		if current != "" and current not in recipients:
			recipients.append(current)
	value.responsibility_revision = job.get("responsibility_revision", 0)
	var subject: String = str(job.asset_ref)
	if job.payload_kind == "CARGO":
		var delivery: Dictionary = g._state.logistics_port.get_ref()._deliveries[job.id]
		value.request_ref = delivery.get("request_id", "")
		value.sea_delivery_ref = delivery.get("sea_delivery_ref", "")
		value.delivery_status = delivery.status
		value.source_ref = delivery.source_ref
		value.recipient_ref = delivery.recipient_ref
		value.recipient_kind = delivery.recipient_kind
		value.original_request_ref = delivery.get("original_request_ref", "")
		value.cargo_owner_ref = delivery.source_ref if delivery.status == "RESERVED_AT_SOURCE" else delivery.recipient_ref if delivery.status == "RECEIVED" else job.unit_ref
		value.cargo = delivery.cargo.duplicate()
		value.lost_cargo = delivery.get("lost_cargo", {}).duplicate()
		value.received_cargo = delivery.get("received_cargo", {}).duplicate()
		subject = str(delivery.recipient_ref)
		if delivery.request_id != "":
			var request: Dictionary = g._state.logistics_port.get_ref()._requests[delivery.request_id]
			value.requested_quantity = request.quantity
			value.received_quantity = request.get("received_quantity", 0.0)
			value.cumulative_received_quantity = value.received_quantity
			value.request_balance = g._state.logistics_port.get_ref().physical_balance(str(delivery.request_id))
			value.resource_class = request.resource_class
			var requester: String = str(request.actor)
			if requester not in recipients:
				recipients.append(requester)
	else:
		var asset: Dictionary = g.air.assets[job.asset_ref]
		value.asset_status = asset.status
		value.surface = asset.get("landing", {}).get("surface", "UNKNOWN")
		value.xy = g.air.position(str(asset.id))
		value.integrity = asset.integrity
		value.base = asset.base
		value.serviceable = asset.serviceable
		value.recovery_ref = asset.get("recovery_ref", "")
	var platform: String = str(carriers[job.unit_ref].report_source)
	var claim: Dictionary = {"id": str(job.id) + "_%d" % _report_serial, "source_ref": platform, "observer_ref": platform,
		"subject_kind": str(value.recipient_kind) if job.payload_kind == "CARGO" else "aircraft", "subject_ref": subject,
		"fact_kind": "land_supply_status", "value": value, "observed_at": g._state.time, "precision": "actual_ground_handover", "quality": 1.0, "origin": "GROUND_TRANSPORT"}
	_serial += 1
	for recipient: String in recipients:
		var sent: Dictionary = claim.duplicate(true)
		if job.payload_kind == "CARGO" and value.get("request_ref", "") != "":
			var l: RefCounted = g._state.logistics_port.get_ref()
			var delivery: Dictionary = l._deliveries[job.id]
			var resource: String = str(l._requests[delivery.request_id].resource_class)
			var local: Dictionary = {"land_delivery_ref": delivery.delivery_id, "land_status": delivery.status,
				"land_committed": float(delivery.cargo.get(resource, 0.0)) if delivery.status in ["RESERVED_AT_SOURCE", "ONBOARD", "STRANDED"] else 0.0}
			if delivery.status == "RECEIVED":
				local.received_quantity = l._requests[delivery.request_id].get("received_quantity", 0.0)
			if _at(unit, str(job.source_node)) and delivery.get("sea_delivery_ref", "") != "":
				local.port_remaining = l.sea_port_remaining(str(delivery.sea_delivery_ref), resource, str(delivery.request_id), str(delivery.source_ref))
				local.port_depot_ref = delivery.source_ref
			sent.value.request_balance = g._state.information_port.get_ref().reported_supply_balance(recipient, str(delivery.request_id), value.request_balance, local)
		var claims: Array[Dictionary] = [sent]
		g._state.information_port.get_ref().send_platform_report(self, str(carriers[job.unit_ref].report_source), recipient, "land_report_" + str(job.id) + "_%d_" % _serial + recipient, claims)

func known_view(actor: String) -> Array[Dictionary]:
	var latest: Dictionary = {}
	for claim: Dictionary in _owner.get_ref()._state.information_port.get_ref().knowledge(actor).get("entries", []):
		if claim.fact_kind == "land_supply_status" and float(claim.reliability) > 0.0:
			var id: String = str(claim.claimed_value.transport_ref)
			if not latest.has(id) or float(claim.observed_at) > float(latest[id].observed_at) or float(claim.observed_at) == float(latest[id].observed_at) and int(claim.claimed_value.get("report_revision", 0)) >= int(latest[id].get("report_revision", 0)):
				latest[id] = claim.claimed_value.duplicate(true)
				latest[id].observed_at = claim.observed_at
				latest[id].received_at = claim.received_at
	var result: Array[Dictionary] = []
	for id: String in latest:
		result.append(latest[id])
	return result

const RUNTIME_FIELDS: Array[String] = ["carriers", "jobs", "_unit_jobs", "_tickets", "_serial", "_report_serial", "rules", "passenger_capacity", "passenger_rides", "passenger_trips", "passenger_rules", "patient_jobs"]

func runtime_state() -> Dictionary:
	return preload("res://experiments/war_resolver/battle_state.gd").capture_runtime_fields(self, RUNTIME_FIELDS)

func restore_runtime(image: Dictionary) -> bool:
	return preload("res://experiments/war_resolver/battle_state.gd").restore_runtime_fields(self, image, RUNTIME_FIELDS)

# A deck is a claim on existing MOTORIZED equipment, not a new vehicle asset.
func admit_passengers(unit_ref: String, quantity: float, equipment_share: float) -> bool:
	var g: RefCounted = _owner.get_ref()
	if g._state.time != 0.0 or not carriers.has(unit_ref) or passenger_capacity.has(unit_ref) or quantity <= 0.0 or equipment_share <= 0.0:
		return false
	var unit: Dictionary = g._state.units[unit_ref]
	if unit.spatial.mode != "MOTORIZED" or equipment_share < 0.5 or equipment_share > float(unit.serviceable_equipment):
		return false
	passenger_capacity[unit_ref] = {"id": "passenger-deck:" + unit_ref, "source_unit_ref": unit_ref, "capacity": quantity,
		"equipment_share": equipment_share, "initial_equipment": unit.serviceable_equipment}
	return true

func seats(unit_ref: String) -> float:
	if not passenger_capacity.has(unit_ref):
		return 0.0
	var unit: Dictionary = _owner.get_ref()._state.units[unit_ref]
	var declaration: Dictionary = passenger_capacity[unit_ref]
	var fraction: float = minf(1.0, float(unit.serviceable_equipment) / float(declaration.initial_equipment))
	var crew: float = float(unit.get("gameplay_personnel", {}).get("anonymous", unit.effective))
	return float(declaration.capacity) * fraction if crew >= float(rules.crew) and float(unit.mobility) > 0.0 and float(declaration.equipment_share) * fraction >= 0.5 else 0.0

func passenger_busy(unit_ref: String) -> bool:
	return passenger_trips.has(unit_ref) or _vehicle_has_occupancy(unit_ref) or passenger_handling(unit_ref)

func _vehicle_has_occupancy(unit_ref: String) -> bool:
	for ride: Dictionary in passenger_rides.values():
		if ride.carrier_ref == unit_ref and ride.status in ["BOARDING", "MOUNTED", "ALIGHTING"]:
			return true
	return false

func passenger_load(unit_ref: String) -> float:
	var total: float = 0.0
	for job: Dictionary in patient_jobs.values():
		if job.status == "PENDING" and job.kind == "LOAD" and job.vehicle_ref == unit_ref:
			total += float(job.quantity)
	for ride: Dictionary in passenger_rides.values():
		if ride.carrier_ref == unit_ref and ride.status in ["BOARDING", "MOUNTED", "ALIGHTING"]:
			total += float(ride.capacity_claim)
	return total

func passenger_handling(unit_ref: String) -> bool:
	for job: Dictionary in patient_jobs.values():
		if job.status == "PENDING" and job.vehicle_ref == unit_ref:
			return true
	for ride: Dictionary in passenger_rides.values():
		if ride.carrier_ref == unit_ref and ride.status in ["BOARDING", "ALIGHTING"]:
			return true
	return false

func passenger_responsibility(unit_ref: String) -> bool:
	for job: Dictionary in patient_jobs.values():
		if job.status == "PENDING" and unit_ref in [job.patient_unit_ref, job.helper_unit_ref, job.vehicle_ref]:
			return true
	if passenger_busy(unit_ref):
		return true
	for ride: Dictionary in passenger_rides.values():
		if ride.unit_ref == unit_ref and ride.status in ["BOARDING", "MOUNTED", "ALIGHTING"]:
			return true
	return false

func body_ride(actor: String) -> Dictionary:
	for ride: Dictionary in passenger_rides.values():
		if actor in ride.members and ride.status in ["BOARDING", "MOUNTED", "ALIGHTING"]:
			return ride
	return {}

func body_mounted(actor: String) -> bool:
	return body_ride(actor).get("status", "") in ["MOUNTED", "ALIGHTING"]

func part_mounted(part: Dictionary) -> bool:
	return part.get("passenger_ref", "") != "" and passenger_rides.get(part.passenger_ref, {}).get("part_aboard", false) and passenger_rides.get(part.passenger_ref, {}).get("status", "") in ["MOUNTED", "ALIGHTING"]

func body_vehicle_spatial(actor: String) -> Dictionary:
	var ride: Dictionary = body_ride(actor)
	return _owner.get_ref()._state.units[ride.carrier_ref].spatial.duplicate(true) if not ride.is_empty() else {}

func _passenger_part(ride: Dictionary) -> Dictionary:
	var g: RefCounted = _owner.get_ref()
	if ride.part_ref == "" or not g.tactics.manoeuvre_active(str(ride.unit_ref)):
		return {}
	return g.tactics.manoeuvres[ride.unit_ref].parts.get(ride.part_ref, {})

func _stopped_endpoint(unit_ref: String) -> bool:
	var g: RefCounted = _owner.get_ref()
	var unit: Dictionary = g._state.units[unit_ref]
	return str(unit.spatial.edge) == "" and unit.spatial.path.is_empty() and g._space.local_place(unit.spatial) == "node:" + str(unit.spatial.node) and passenger_trips.get(unit_ref, {}).get("status", "") != "DRIVING"

func _boarding_contact(ride: Dictionary) -> bool:
	var g: RefCounted = _owner.get_ref()
	if not _stopped_endpoint(str(ride.carrier_ref)):
		return false
	var vehicle: Dictionary = g._state.units[ride.carrier_ref]
	var point: Array = g._space.xy(vehicle)
	var part: Dictionary = _passenger_part(ride)
	if ride.part_ref != "":
		if part.is_empty() or str(part.spatial.get("edge", "")) != "" or str(part.spatial.get("local_edge", "")) != "" or g._space.local_place(part.spatial) != "node:" + str(vehicle.spatial.node) or g.tactics.StateDistance(g._space.xy(g.tactics.part_source(g._state.units[ride.unit_ref], part)), point) > float(passenger_rules.contact_km):
			return false
	for actor: String in ride.members:
		var body: Dictionary = g.participants._member(actor)
		if not body.actionable or float(body.health) < float(g.participants.rules.minimum_carrier_health) or g._space.local_place(g.participants.body_spatial(actor)) != "node:" + str(vehicle.spatial.node) or g.tactics.StateDistance(g.participants.position(actor), point) > float(passenger_rules.contact_km):
			return false
	return true

func validate_passenger(actor: String, source: String, values: Dictionary, personal: bool = false) -> Dictionary:
	var g: RefCounted = _owner.get_ref()
	var action: String = str(values.get("passenger_action", ""))
	var carrier: String = str(values.get("carrier_ref", ""))
	for key: String in values:
		if key not in ["action", "passenger_action", "carrier_ref", "part_ref"]:
			return g._reject("unknown_passenger_handling_parameter")
	if action not in ["board", "alight", "cancel"] or not g._state.units.has(source) or not passenger_capacity.has(carrier):
		return g._reject("explicit_existing_passenger_deck_and_source_required")
	if action != "cancel" and _tickets.size() >= 256:
		return g._reject("finite_land_event_ticket_capacity")
	var source_unit: Dictionary = g._state.units[source]
	var vehicle: Dictionary = g._state.units[carrier]
	if source_unit.spatial.mode != "FOOT" or source == carrier or source_unit.side != vehicle.side or action == "board" and g.tactics.local_cooperation(source, carrier).is_empty():
		return g._reject("current_friendly_cooperation_and_FOOT_source_required")
	var part_ref: String = "" if personal else str(values.get("part_ref", ""))
	var members: Array = [actor]
	var part: Dictionary = {}
	var reference: String = "passenger-person:" + actor
	var claim: float = 0.0
	if personal:
		if values.has("part_ref") or g.participants._units.get(actor, "") != source:
			return g._reject("own_existing_body_required")
		claim = float(g.participants._member(actor).health)
		if action != "board" and not body_ride(actor).is_empty():
			reference = str(body_ride(actor).id)
	else:
		if not g.tactics.manoeuvre_active(source) or g.tactics.manoeuvres[source].phase != "STOPPED" or part_ref not in ["front", "rear"]:
			return g._reject("stopped_existing_two_parts_required")
		var order: Dictionary = g.tactics.manoeuvres[source]
		part = order.parts[part_ref]
		if part_ref == order.stock_part:
			return g._reject("stock_anchor_part_vehicle_transport_not_yet_supported")
		members = part.members.duplicate()
		claim = g.tactics.part_capacity(part)
		reference = "passenger-part:" + str(part.id)
	var old: Dictionary = passenger_rides.get(reference, {})
	if action == "cancel":
		return {"ok": true, "ride_ref": reference} if old.get("status", "") in ["BOARDING", "ALIGHTING"] and old.carrier_ref == carrier and (not personal or old.get("handling_actor", "") == actor) else g._reject("own_unfinished_passenger_handling_required")
	if action == "alight":
		if old.get("status", "") != "MOUNTED" or old.carrier_ref != carrier or not _stopped_endpoint(carrier) or passenger_handling(carrier):
			return g._reject("actual_mounted_occupancy_at_stopped_road_endpoint_required")
		var selected: Array = []
		for person: String in ([actor] if personal else old.members):
			if person in old.members and g.participants._member(person).actionable and str(g.participants._member(person).action_ref).is_empty() and patient_job_for(person).is_empty():
				selected.append(person)
		var occupied_part: Dictionary = _passenger_part(old)
		var exit_part: bool = not personal and old.part_aboard and (not selected.is_empty() or not occupied_part.is_empty() and float(occupied_part.anonymous) > 0.000001)
		if personal and old.part_aboard and old.members.size() == 1 and not occupied_part.is_empty() and float(occupied_part.anonymous) <= 0.000001 and not selected.is_empty():
			exit_part = true
		if selected.is_empty() and not exit_part:
			return g._reject("no_self_mobile_occupancy_requires_actual_patient_unloading")
		return {"ok": true, "ride_ref": reference, "exiting_members": selected, "exit_part": exit_part}
	if not old.is_empty() and old.status in ["BOARDING", "MOUNTED", "ALIGHTING"] or claim <= 0.000001 or passenger_rides.size() >= 16 and old.is_empty():
		return g._reject("finite_unoccupied_actual_passenger_capacity_required")
	if _unit_jobs.has(carrier) or g.air.recovery._unit_jobs.has(carrier) or g.operations.occupied_ground(carrier) or g.tactics.occupied(carrier) or not g._state.coordination.get(carrier, {}).is_empty() or not _stopped_endpoint(carrier) or passenger_load(carrier) + claim > seats(carrier) + 0.000001:
		return g._reject("actual_free_vehicle_equipment_and_remaining_seats_required")
	if not g.tactics.supply_job(source).is_empty() or g.operations.occupied_ground(source) or g.tactics._gun_crew(source) > 0.000001 or _unit_jobs.has(source) or g.air.recovery._unit_jobs.has(source):
		return g._reject("settle_source_engineering_gun_or_supply_work_before_boarding")
	for person: String in members:
		var body: Dictionary = g.participants._member(person)
		if not body_ride(person).is_empty() or not patient_job_for(person).is_empty() or not g.participants.can_intend(person) or not str(body.action_ref).is_empty() or not str(body.get("carrying_ref", "")).is_empty() or g.participants.relay_involves(person) or g.medical.carry_jobs.has(person) or float(body.get("combat_busy_until", 0.0)) > g._state.time:
			return g._reject("passenger_has_another_actual_body_duty")
		if not personal and body.get("local_duty", false):
			return g._reject("part_member_currently_detached_for_local_support")
	var proposed: Dictionary = {"unit_ref": source, "carrier_ref": carrier, "part_ref": part_ref, "members": members}
	if not _boarding_contact(proposed):
		return g._reject("actual_shared_road_endpoint_contact_required")
	return {"ok": true, "ride_ref": reference, "members": members, "capacity_claim": claim, "part_ref": part_ref}
func passenger_action(actor: String, source: String, id: String, values: Dictionary, personal: bool = false) -> Dictionary:
	var valid: Dictionary = validate_passenger(actor, source, values, personal)
	if not valid.ok:
		return valid
	var g: RefCounted = _owner.get_ref()
	var action: String = str(values.passenger_action)
	var reference: String = str(valid.ride_ref)
	var carrier: String = str(values.carrier_ref)
	g._lod.materialize_leaf(source, "actual_passenger_source")
	g._lod.materialize_leaf(carrier, "actual_passenger_deck")
	if action == "cancel":
		_interrupt_passenger(passenger_rides[reference], "received_handling_cancel")
		return {"ok": true, "status": passenger_rides[reference].status, "changed": [source, carrier], "retired": []}
	var ride: Dictionary
	if action == "board":
		var prior: Dictionary = passenger_rides.get(reference, {})
		ride = {"id": reference, "unit_ref": source, "carrier_ref": carrier, "deck_ref": passenger_capacity[carrier].id, "issuer": actor,
			"part_ref": valid.part_ref, "members": valid.members.duplicate(), "capacity_claim": valid.capacity_claim, "mission_ref": g._state.units[source].mission_id,
			"status": "BOARDING", "version": int(prior.get("version", 0)) + 1, "started_at": g._state.time, "pending": "", "command_ref": id,
			"origin_spatial": g._state.units[carrier].spatial.duplicate(true), "origin_xy": g._space.xy(g._state.units[carrier]), "last_damage_ref": "", "part_aboard": valid.part_ref != "", "member_claims": {}, "anonymous_claim": 0.0, "exiting_members": [], "exit_part": false, "handling_actor": actor, "roster": valid.members.duplicate(), "payload_kind": "PERSONNEL"}
		for person: String in ride.members:
			ride.member_claims[person] = float(g.participants._member(person).health)
		if ride.part_ref != "":
			ride.anonymous_claim = float(g.tactics.manoeuvres[source].parts[ride.part_ref].anonymous)
		passenger_rides[reference] = ride
		for person: String in ride.members:
			var body: Dictionary = g.participants._member(person)
			body.xy = g.participants.position(person)
			body.anchor_node = g.participants.body_spatial(person).node
			body.body_revision = int(body.get("body_revision", 0)) + 1
			if personal:
				g.tactics.begin_local_duty(person)
			g.tactics.body_action_started(person)
			g.participants._member(person).vehicle_action_ref = reference
			g.participants._member(person).state = "EMBARKING"
		var part: Dictionary = _passenger_part(ride)
		if not part.is_empty():
			part.passenger_ref = reference
			part.revision += 1
			part.role = "BOARDING"
	else:
		ride = passenger_rides[reference]
		ride.version += 1
		ride.status = "ALIGHTING"
		ride.command_ref = id
		ride.handling_actor = actor
		ride.exiting_members = valid.exiting_members.duplicate()
		ride.exit_part = valid.exit_part
		for person: String in ride.exiting_members:
			g.participants._member(person).state = "ALIGHTING"
		var part: Dictionary = _passenger_part(ride)
		if not part.is_empty() and ride.exit_part:
			part.role = "ALIGHTING"
			part.revision += 1
	ride.due = g._state.time + float(passenger_rules.handling_seconds)
	_serial += 1
	var ticket: String = "land_passenger_%d" % _serial
	_tickets[ticket] = {"job_ref": reference, "version": ride.version, "kind": "PASSENGER_" + action.to_upper(), "due": ride.due, "status": "PENDING"}
	ride.pending = ticket
	g._state.schedule_event(ticket, ride.due, "gameplay", {"land_id": ticket})
	for unit_ref: String in [source, carrier]:
		g._state.wake(str(g._state.units[unit_ref].area_id))
	_passenger_report(ride, str(ride.status))
	return {"ok": true, "status": ride.status, "ride_ref": reference, "changed": [source, carrier], "retired": []}

func _release_passenger_marks(ride: Dictionary, mounted: bool) -> void:
	var g: RefCounted = _owner.get_ref()
	var vehicle: Dictionary = g._state.units[ride.carrier_ref]
	for actor: String in ride.members:
		var body: Dictionary = g.participants._member(actor)
		if body.get("vehicle_action_ref", "") != ride.id:
			continue
		if mounted:
			if body.actionable:
				body.state = "RIDING"
		else:
			body.erase("vehicle_action_ref")
			if ride.status == "GROUND":
				body.xy = g._space.xy(vehicle)
				body.anchor_node = vehicle.spatial.node
				body.anchor_edge = ""
				body.local_ref = "node:" + str(vehicle.spatial.node)
				body.local_edge = ""
				body.erase("entered_site_ref")
				body.cover_ref = ""
			if body.actionable:
				body.state = "STATIONARY"
			body.body_revision = int(body.get("body_revision", 0)) + 1
	var part: Dictionary = _passenger_part(ride)
	if not part.is_empty() and ride.part_aboard and part.get("passenger_ref", "") == ride.id:
		part.role = "MOUNTED" if mounted else "WATCH"
		if not mounted:
			part.erase("passenger_ref")
			if ride.status == "GROUND":
				part.spatial = vehicle.spatial.duplicate(true)
				part.spatial.mode = "FOOT"
				part.spatial.path = []
		part.revision += 1

func _interrupt_passenger(ride: Dictionary, reason: String) -> void:
	var mounted: bool = ride.status == "ALIGHTING"
	ride.version += 1
	ride.pending = ""
	ride.status = "MOUNTED" if mounted else "INTERRUPTED"
	ride.reason = reason
	ride.exiting_members = []
	ride.exit_part = false
	_release_passenger_marks(ride, mounted)
	_passenger_report(ride, str(ride.status))

func _finish_passenger(event: Dictionary) -> Dictionary:
	var ticket: Dictionary = _tickets[event.id]
	_tickets.erase(event.id)
	var ride: Dictionary = passenger_rides.get(ticket.job_ref, {})
	if ride.is_empty() or ride.version != ticket.version or ride.pending != event.id:
		return {"changed": [], "retired": [], "record": {"kind": "passenger", "status": "STALE"}}
	var g: RefCounted = _owner.get_ref()
	ride.pending = ""
	ride.last_event_ref = event.id
	var able: bool = _stopped_endpoint(str(ride.carrier_ref)) and g._space.movement_factor(g._space._nodes[g._state.units[ride.carrier_ref].spatial.node].ground, "FOOT") > 0.0
	if ride.status == "BOARDING":
		for actor: String in ride.members:
			var body: Dictionary = g.participants._member(actor)
			able = able and body.actionable and body.get("vehicle_action_ref", "") == ride.id and str(body.action_ref).is_empty()
		able = able and _boarding_contact(ride) and passenger_load(str(ride.carrier_ref)) <= seats(str(ride.carrier_ref)) + 0.000001
		var part: Dictionary = _passenger_part(ride)
		if ride.part_ref != "":
			able = able and not part.is_empty() and g.tactics.part_capacity(part) > 0.000001
		if able:
			ride.status = "MOUNTED"
			_release_passenger_marks(ride, true)
		else:
			_interrupt_passenger(ride, "actual_boarding_conditions_changed")
	elif able:
		_disembark_mobile_members(ride)
	else:
		_interrupt_passenger(ride, "actual_unloading_endpoint_lost")
	ride.finished_at = g._state.time
	_sync_passengers(str(ride.carrier_ref))
	_passenger_report(ride, str(ride.status))
	return {"changed": [ride.unit_ref, ride.carrier_ref], "retired": [], "record": {"kind": "passenger", "ride_ref": ride.id, "status": ride.status, "disembarked": ride.get("last_disembarked", [])}}
func validate_passenger_drive(actor: String, target: String, values: Dictionary) -> Dictionary:
	var g: RefCounted = _owner.get_ref()
	var carrier: String = str(values.get("carrier_ref", ""))
	var action: String = str(values.get("passenger_action", ""))
	for key: String in values:
		if key not in ["passenger_action", "carrier_ref", "target_node", "path", "return_to_start"]:
			return g._reject("unknown_passenger_drive_parameter")
	if target != str(g._state.structure_port.get_ref().command_person(actor).formation_id) or not passenger_capacity.has(carrier) or not g._state.logistics_port.get_ref()._allowed(actor, "unit", carrier, 3):
		return g._reject("current_motor_transport_command_authority_required")
	if action in ["stop", "release"]:
		return {"ok": true} if passenger_busy(carrier) and (action != "release" or not _vehicle_has_occupancy(carrier) and not passenger_handling(carrier) and _stopped_endpoint(carrier)) else g._reject("actual_passenger_duty_or_empty_stopped_vehicle_required")
	if action != "drive" or passenger_handling(carrier) or _unit_jobs.has(carrier) or g.air.recovery._unit_jobs.has(carrier) or g.operations.occupied_ground(carrier) or g.tactics.occupied(carrier) or not values.get("path") is Array or values.path.size() > 4 or not values.get("target_node") is String:
		return g._reject("free_equipment_completed_boarding_and_known_bounded_road_route_required")
	var unit: Dictionary = g._state.units[carrier]
	for ride: Dictionary in passenger_rides.values():
		if ride.carrier_ref == carrier and ride.status == "MOUNTED" and ride.part_ref != "":
			var cells: Array[String] = g._space.scope_cells(str(g._state.units[ride.unit_ref].area_id))
			for reference: Variant in values.path:
				var edge: Dictionary = g._space._edges.get(reference, {})
				if edge.is_empty() or str(g._space._nodes[edge.from].cell) not in cells or str(g._space._nodes[edge.to].cell) not in cells:
					return g._reject("passenger_part_road_leg_must_remain_in_original_local_scope")
	if seats(carrier) < passenger_load(carrier) or seats(carrier) <= 0.0 or float(unit.fuel) <= 0.0 or not g._state.coordination.get(carrier, {}).is_empty():
		return g._reject("actual_vehicle_crew_equipment_and_fuel_required")
	return route(actor, unit, str(values.target_node), values.path, bool(values.get("return_to_start", false)))

func passenger_drive(actor: String, target: String, id: String, values: Dictionary) -> Dictionary:
	var g: RefCounted = _owner.get_ref()
	var valid: Dictionary = validate_passenger_drive(actor, str(g._state.structure_port.get_ref().command_person(actor).formation_id), values)
	if not valid.ok:
		return valid
	var carrier: String = str(values.carrier_ref)
	if values.passenger_action in ["stop", "release"]:
		_stop_passenger_vehicle(carrier, "STOPPED")
		if values.passenger_action == "release":
			for ride: Dictionary in passenger_rides.values():
				if ride.carrier_ref == carrier and ride.status == "GROUND":
					_passenger_report(ride, "RELEASED")
			passenger_trips.erase(carrier)
	else:
		g._lod.materialize_leaf(carrier, "actual_motor_passenger_road_leg")
		var trip: Dictionary = passenger_trips.get(carrier, {"id": "passenger-trip:" + carrier, "unit_ref": carrier, "distance_km": 0.0, "fuel_spent": 0.0, "version": 0})
		trip.issuer = actor
		trip.notify = []
		trip.payload_kind = "PASSENGERS"
		trip.asset_ref = carrier
		trip.loaded = passenger_load(carrier) > 0.000001
		trip.source_node = g._state.units[carrier].spatial.node
		trip.target_node = values.target_node
		trip.command_ref = id
		trip.version += 1
		passenger_trips[carrier] = trip
		_move(trip, str(values.target_node), values.path, "DRIVING", bool(values.get("return_to_start", false)))
		for ride: Dictionary in passenger_rides.values():
			if ride.carrier_ref == carrier and ride.status in ["MOUNTED", "GROUND"]:
				_passenger_report(ride, "DRIVING")
	return {"ok": true, "changed": [carrier], "retired": [], "status": passenger_trips.get(carrier, {}).get("status", "RELEASED")}

func _stop_passenger_vehicle(carrier: String, status: String) -> void:
	if not passenger_trips.has(carrier):
		return
	var g: RefCounted = _owner.get_ref()
	var trip: Dictionary = passenger_trips[carrier]
	var changed: bool = trip.status != status
	trip.status = status
	trip.version += 1
	g._state.units[carrier].spatial.path = []
	g._state.units[carrier].spatial.returning = false
	if changed:
		for ride: Dictionary in passenger_rides.values():
			if ride.carrier_ref == carrier and ride.status in ["MOUNTED", "ALIGHTING", "GROUND"]:
				_passenger_report(ride, status)

func _sync_passengers(carrier: String) -> void:
	var g: RefCounted = _owner.get_ref()
	for ride: Dictionary in passenger_rides.values():
		if ride.carrier_ref != carrier or ride.status not in ["MOUNTED", "ALIGHTING"]:
			continue
		var vehicle: Dictionary = g._state.units[carrier]
		for actor: String in ride.members:
			var body: Dictionary = g.participants._member(actor)
			body.xy = g._space.xy(vehicle)
			body.anchor_node = vehicle.spatial.node
			body.anchor_edge = vehicle.spatial.edge
			body.local_ref = "node:" + str(vehicle.spatial.node)
			body.local_edge = ""
			body.cover_ref = ""
			body.erase("entered_site_ref")
		var part: Dictionary = _passenger_part(ride)
		if not part.is_empty() and ride.part_aboard:
			part.spatial = vehicle.spatial.duplicate(true)
			part.spatial.mode = "FOOT"
			part.spatial.path = []
			part.settled_at = g._state.time

func _passenger_changed(unit_ref: String) -> void:
	var g: RefCounted = _owner.get_ref()
	var vehicles: Dictionary = {}
	if passenger_trips.has(unit_ref):
		vehicles[unit_ref] = true
	for job: Dictionary in patient_jobs.values():
		if job.status == "PENDING" and unit_ref in [job.helper_unit_ref, job.patient_unit_ref, job.vehicle_ref] and not _patient_job_valid(job):
			_cancel_patient_job(job, "actual_patient_handling_interrupted")
	for ride: Dictionary in passenger_rides.values():
		if unit_ref not in [ride.unit_ref, ride.carrier_ref] or ride.status not in ["BOARDING", "MOUNTED", "ALIGHTING"]:
			continue
		vehicles[ride.carrier_ref] = true
		_refresh_ride_claim(ride)
		var states: Dictionary = {}
		for actor: String in ride.members:
			states[actor] = g.participants._member(actor).life_state
		if ride.get("reported_body_states", {}) != states:
			_passenger_report(ride, "ONBOARD_BODY_STATE_CHANGED")
		if ride.status in ["BOARDING", "ALIGHTING"]:
			var able: bool = _stopped_endpoint(str(ride.carrier_ref))
			if ride.status == "BOARDING":
				for actor: String in ride.members:
					able = able and g.participants._member(actor).actionable and g.participants._member(actor).get("vehicle_action_ref", "") == ride.id
			if not able:
				_interrupt_passenger(ride, "person_or_vehicle_handling_interrupted")
	for vehicle_ref: String in vehicles:
		if passenger_trips.has(vehicle_ref) and passenger_trips[vehicle_ref].status == "DRIVING":
			var unit: Dictionary = g._state.units[vehicle_ref]
			if seats(vehicle_ref) < passenger_load(vehicle_ref) or float(unit.fuel) <= 0.0 or float(unit.readiness) <= 0.0 or not g._space.can_move(unit):
				_stop_passenger_vehicle(vehicle_ref, "BLOCKED")
			elif _at(unit, str(passenger_trips[vehicle_ref].target_node)) and unit.spatial.path.is_empty():
				_stop_passenger_vehicle(vehicle_ref, "ARRIVED")
			elif passenger_trips[vehicle_ref].get("mission_ref", "") == unit.mission_id and g._state.missions[unit.mission_id].status != "active":
				passenger_trips[vehicle_ref].reason = "native_motor_task_ended"
				_stop_passenger_vehicle(vehicle_ref, "BLOCKED")
		_sync_passengers(vehicle_ref)

func _passenger_report(ride: Dictionary, status: String) -> void:
	var g: RefCounted = _owner.get_ref()
	_report_serial += 1
	var recipients: Array = [ride.issuer]
	var structure: RefCounted = g._state.structure_port.get_ref()
	for unit_ref: String in [ride.unit_ref, ride.carrier_ref]:
		for scope: String in structure._path(str(structure._unit_nodes.get(unit_ref, ""))):
			var officer: String = str(structure._positions.get(scope, {}).get("person", ""))
			if officer != "" and officer not in recipients:
				recipients.append(officer)
	var value: Dictionary = {"ride_ref": ride.id, "source_unit_ref": ride.unit_ref, "carrier_ref": ride.carrier_ref, "part_ref": ride.part_ref, "status": status, "ride_status": ride.status,
		"capacity_claim": ride.capacity_claim, "position": _position(g._state.units[ride.carrier_ref]), "mission_ref": ride.mission_ref, "command_ref": ride.command_ref, "revision": ride.version}
	value.trip_status = passenger_trips.get(ride.carrier_ref, {}).get("status", "IDLE")
	value.remaining_seats = maxf(0.0, seats(str(ride.carrier_ref)) - passenger_load(str(ride.carrier_ref)))
	value.part_aboard = ride.part_aboard
	value.reason = ride.get("reason", "")
	value.anonymous_aboard = float(_passenger_part(ride).get("anonymous", 0.0)) if ride.part_aboard else 0.0
	value.remaining_members = ride.members.duplicate()
	value.last_partial_exit = ride.get("last_partial_exit", {}).duplicate(true)
	value.body_states = {}
	for actor: String in ride.members:
		value.body_states[actor] = g.participants._member(actor).life_state
	ride.reported_body_states = value.body_states.duplicate()
	var platform: String = str(carriers[ride.carrier_ref].report_source)
	var claims: Array[Dictionary] = [{"id": ride.id + "_%d" % _report_serial, "source_ref": platform, "observer_ref": platform, "subject_kind": "unit", "subject_ref": ride.unit_ref,
		"fact_kind": "passenger_status", "value": value, "observed_at": g._state.time, "precision": "actual_motor_passenger_contact", "quality": 1.0, "origin": "GROUND_TRANSPORT"}]
	for actor: String in ride.members:
		if ride.status not in ["MOUNTED", "ALIGHTING"]:
			continue
		var body: Dictionary = g.participants._member(actor)
		claims.append({"id": ride.id + "_%d_body_" % _report_serial + actor, "source_ref": platform, "observer_ref": platform, "subject_kind": "person", "subject_ref": actor, "fact_kind": "person_status",
			"value": {"person_ref": actor, "life_state": body.life_state, "body_status": body.state, "vehicle_ref": ride.carrier_ref, "ride_ref": ride.id, "xy": g.participants.position(actor), "node_ref": g._state.units[ride.carrier_ref].spatial.node},
			"observed_at": g._state.time, "precision": "actual_onboard_body", "quality": 1.0, "origin": "GROUND_TRANSPORT"})
	for recipient: String in recipients:
		g._state.information_port.get_ref().send_platform_report(self, platform, recipient, "passenger_report_%d_" % _report_serial + recipient, claims)
	for actor: String in ride.members:
		g.participants._emit(actor, "passenger_status", str(ride.command_ref), {"ride_ref": ride.id, "carrier_ref": ride.carrier_ref, "status": status})

# Partition the original incoming effect; no second shot or casualty adoption.
func prepare_passenger_damage(unit: Dictionary, plan: Dictionary) -> void:
	var entries: Array = []
	var crew_weight: float = maxf(0.0, float(plan.get("personal_ledger", {}).get("exposure_capacity", unit.effective)))
	var weight: float = crew_weight
	for ride: Dictionary in passenger_rides.values():
		if ride.carrier_ref != unit.id or ride.status not in ["MOUNTED", "ALIGHTING"]:
			continue
		var part: Dictionary = _passenger_part(ride)
		if not part.is_empty() and ride.part_aboard and float(part.anonymous) > 0.0:
			entries.append({"unit_ref": ride.unit_ref, "part_ref": part.id, "actor_ref": "", "weight": part.anonymous, "incoming": 0.0, "pressure": 0.0})
			weight += float(part.anonymous)
		for actor: String in ride.members:
			var body: Dictionary = _owner.get_ref().participants._member(actor)
			var health: float = float(body.health)
			if body.life_state != "DEAD":
				var exposed: float = health if body.actionable else maxf(1.0, health)
				entries.append({"unit_ref": ride.unit_ref, "part_ref": "", "actor_ref": actor, "weight": exposed, "incoming": 0.0, "pressure": 0.0})
				weight += exposed
	if not entries.is_empty():
		plan.passenger_damage = entries
		plan.passenger_weight = weight
		plan.vehicle_crew_fraction = crew_weight / maxf(0.000001, weight)

func passenger_incoming(plan: Dictionary, dose: float, pressure: float) -> float:
	for entry: Dictionary in plan.get("passenger_damage", []):
		var fraction: float = float(entry.weight) / maxf(0.000001, float(plan.passenger_weight))
		entry.incoming += dose * float(plan.exposure) * fraction
		entry.pressure += pressure * float(plan.exposure) * fraction
	return float(plan.get("vehicle_crew_fraction", 1.0))

func settle_passenger_damage(plan: Dictionary, minutes: float, cause: String) -> Array:
	var g: RefCounted = _owner.get_ref()
	var changed: Array = []
	for entry: Dictionary in plan.get("passenger_damage", []):
		if entry.actor_ref != "":
			var body: Dictionary = g.participants._member(str(entry.actor_ref))
			var decay: float = exp(-g._lod._kernel.SUPPRESSION_DECAY * minutes)
			body.local_suppression = clampf(g.participants.body_suppression(str(entry.actor_ref)) * decay + float(entry.pressure) * ((1.0 - decay) / g._lod._kernel.SUPPRESSION_DECAY if minutes > 0.0 else 1.0), 0.0, 1.0)
			body.pressure_at = g._state.time
			if float(entry.incoming) > 0.0:
				g.participants.external_damage(str(entry.actor_ref), float(entry.incoming), cause + ":body:" + str(entry.actor_ref), "motor_passenger_shared_incoming")
		else:
			g.tactics.apply_part_damage(str(entry.unit_ref), str(entry.part_ref), float(entry.incoming), float(entry.pressure), minutes, cause + ":part:" + str(entry.part_ref))
		if entry.unit_ref not in changed:
			changed.append(entry.unit_ref)
	return changed

func passenger_view(actor: String) -> Dictionary:
	var ride: Dictionary = body_ride(actor)
	return {} if ride.is_empty() else {"ride_ref": ride.id, "carrier_ref": ride.carrier_ref, "status": ride.status, "part_ref": ride.part_ref, "command_ref": ride.command_ref, "payload_kind": ride.payload_kind, "own_capacity_claim": ride.member_claims.get(actor, 0.0), "own_exit_pending": actor in ride.exiting_members}

func validate_runtime() -> bool:
	var g: RefCounted = _owner.get_ref()
	var p: RefCounted = g.participants
	if passenger_capacity.size() > 2 or passenger_rides.size() > 16 or patient_jobs.size() > 6 or not g.tactics._positive(passenger_rules.get("patient_capacity")):
		return false
	var people: Dictionary = {}
	var parts: Dictionary = {}
	var helpers: Dictionary = {}
	var pending_patients: Dictionary = {}
	for carrier: String in passenger_capacity:
		var deck: Dictionary = passenger_capacity[carrier]
		if not carriers.has(carrier) or not g._state.units.has(carrier) or g._state.units[carrier].spatial.mode != "MOTORIZED" or deck.id != "passenger-deck:" + carrier or deck.source_unit_ref != carrier or not g.tactics._positive(deck.initial_equipment) or not g.tactics._positive(deck.capacity) or not g.tactics._positive(deck.equipment_share) or float(deck.equipment_share) > float(deck.initial_equipment):
			return false
	for reference: String in passenger_rides:
		var ride: Dictionary = passenger_rides[reference]
		if ride.get("id", "") != reference or not g._state.knows_unit(str(ride.get("unit_ref", ""))) or not passenger_capacity.has(ride.get("carrier_ref", "")):
			return false
		if ride.get("deck_ref", "") != passenger_capacity[ride.carrier_ref].id or not ride.get("members") is Array or not ride.get("roster") is Array or not ride.get("member_claims") is Dictionary or not ride.get("part_aboard") is bool or not ride.get("exit_part") is bool or not ride.get("exiting_members") is Array or not ride.get("part_ref") is String or ride.get("payload_kind", "") not in ["PERSONNEL", "PATIENT"] or not g.tactics._nonnegative(ride.get("capacity_claim")) or not g.tactics._nonnegative(ride.get("anonymous_claim")) or ride.get("status", "") not in ["BOARDING", "MOUNTED", "ALIGHTING", "GROUND", "INTERRUPTED"]:
			return false
		if ride.status not in ["BOARDING", "MOUNTED", "ALIGHTING"]:
			continue
		if not g._state.units.has(ride.unit_ref) or g._state.units[ride.unit_ref].side != g._state.units[ride.carrier_ref].side or g._state.units[ride.unit_ref].spatial.mode != "FOOT" or not g.tactics._nonnegative(ride.get("version")) or not ride.get("pending") is String or not ride.get("mission_ref") is String or not g._state.missions.has(ride.mission_ref):
			return false
		if _unit_jobs.has(ride.carrier_ref) or g.air.recovery._unit_jobs.has(ride.carrier_ref) or ride.member_claims.size() != ride.members.size():
			return false
		var claim: float = float(ride.anonymous_claim) if ride.part_aboard else 0.0
		for actor: Variant in ride.members:
			if not actor is String or people.has(actor) or actor not in ride.roster or p._units.get(actor, "") != ride.unit_ref or not g.tactics._positive(ride.member_claims.get(actor)) or p._member(actor).get("vehicle_action_ref", "") != reference or p._member(actor).has("carrier_ref"):
				return false
			if float(ride.member_claims[actor]) + 0.000001 < float(p._member(actor).health):
				return false
			claim += float(ride.member_claims[actor])
			people[actor] = reference
		if absf(claim - float(ride.capacity_claim)) > 0.000001 or not ride.part_aboard and ride.members.is_empty():
			return false
		if ride.part_ref != "":
			var part: Dictionary = _passenger_part(ride)
			if part.is_empty() or part.members != ride.roster or ride.part_ref == g.tactics.manoeuvres[ride.unit_ref].stock_part:
				return false
			if ride.part_aboard:
				var expected: String = "BOARDING" if ride.status == "BOARDING" else "ALIGHTING" if ride.status == "ALIGHTING" and ride.exit_part else "MOUNTED"
				if parts.has(part.id) or part.get("passenger_ref", "") != reference or part.role != expected or float(part.anonymous) > float(ride.anonymous_claim) + 0.000001:
					return false
				if part_mounted(part) and (part.spatial.node != g._state.units[ride.carrier_ref].spatial.node or part.spatial.edge != g._state.units[ride.carrier_ref].spatial.edge or g.tactics.StateDistance(g._space.xy(g.tactics.part_source(g._state.units[ride.unit_ref], part)), g._space.xy(g._state.units[ride.carrier_ref])) > 0.000001):
					return false
				parts[part.id] = reference
			else:
				if part.get("passenger_ref", "") == reference:
					return false
				for actor: String in ride.members:
					if not p._member(actor).get("local_duty", false) or p._member(actor).get("local_duty_part_ref", "") != part.id:
						return false
		elif ride.part_aboard or float(ride.anonymous_claim) != 0.0 or ride.members.size() != 1 or not p._member(str(ride.members[0])).get("local_duty", false) and not g.tactics.roster_part(str(ride.members[0])).is_empty():
			return false
		for actor: Variant in ride.exiting_members:
			if not actor is String or actor not in ride.members:
				return false
		if ride.status in ["BOARDING", "ALIGHTING"]:
			var ticket: Dictionary = _tickets.get(ride.pending, {})
			if ticket.get("job_ref", "") != reference or ticket.get("version", -1) != ride.version or ticket.get("status", "") != "PENDING" or ticket.get("due", -1.0) != ride.due or ticket.get("kind", "") != ("PASSENGER_BOARD" if ride.status == "BOARDING" else "PASSENGER_ALIGHT"):
				return false
	for helper: String in patient_jobs:
		var job: Dictionary = patient_jobs[helper]
		if job.get("helper_ref", "") != helper or not p._units.has(helper) or not p._units.has(job.get("patient_ref", "")) or helper == job.patient_ref or not passenger_capacity.has(job.get("vehicle_ref", "")) or job.get("kind", "") not in ["LOAD", "UNLOAD"] or job.get("status", "") not in ["PENDING", "INTERRUPTED", "LOADED", "RECEIVED_BY_HELPER"] or not g.tactics._positive(job.get("quantity")) or not g.tactics._nonnegative(job.get("version")) or not job.get("id") is String or not job.get("ride_ref") is String:
			return false
		if job.status != "PENDING":
			continue
		var body: Dictionary = p._member(helper)
		var patient: Dictionary = p._member(str(job.patient_ref))
		if helpers.has(helper) or pending_patients.has(job.patient_ref) or p._units[helper] != job.get("helper_unit_ref", "") or p._units[job.patient_ref] != job.get("patient_unit_ref", "") or body.get("vehicle_patient_job_ref", "") != job.id or body.get("body_revision", -1) != job.get("helper_body_revision", -2) or str(body.action_ref) != "" or body.has("vehicle_action_ref") or not g._state.missions.has(job.get("mission_ref", "")):
			return false
		if not body.actionable or patient.life_state == "DEAD" or body.state != ("VEHICLE_LOADING" if job.kind == "LOAD" else "VEHICLE_UNLOADING"):
			return false
		var ticket: Dictionary = _tickets.get(job.get("pending", ""), {})
		if ticket.get("job_ref", "") != helper or ticket.get("kind", "") != "PATIENT_" + str(job.kind) or ticket.get("version", -1) != job.version or ticket.get("due", -1.0) != job.get("due", -2.0) or ticket.get("status", "") != "PENDING":
			return false
		if job.kind == "LOAD":
			if patient.get("carrier_ref", "") != helper or body.get("carrying_ref", "") != job.patient_ref or people.has(job.patient_ref):
				return false
		else:
			var ride: Dictionary = passenger_rides.get(job.ride_ref, {})
			if ride.get("status", "") != "MOUNTED" or ride.get("carrier_ref", "") != job.vehicle_ref or ride.get("version", -1) != job.get("ride_version", -2) or job.patient_ref not in ride.members or patient.has("carrier_ref") or str(body.get("carrying_ref", "")) != "":
				return false
		helpers[helper] = job.id
		pending_patients[job.patient_ref] = helper
	for helper: String in helpers:
		if pending_patients.has(helper):
			return false
	for actor: String in p._units:
		var body: Dictionary = p._member(actor)
		if body.has("vehicle_action_ref") and not people.has(actor) or body.has("vehicle_patient_job_ref") and not helpers.has(actor):
			return false
	for order: Dictionary in g.tactics.manoeuvres.values():
		for part: Dictionary in order.parts.values():
			if part.get("passenger_ref", "") != "" and not parts.has(part.id):
				return false
	for carrier: String in passenger_trips:
		if not passenger_capacity.has(carrier) or passenger_trips[carrier].unit_ref != carrier or passenger_trips[carrier].status not in ["DRIVING", "BLOCKED", "STOPPED", "ARRIVED"]:
			return false
	return true
func _refresh_ride_claim(ride: Dictionary) -> void:
	var total: float = float(ride.anonymous_claim) if ride.part_aboard else 0.0
	for actor: String in ride.members:
		# Injury/death does not vacate a berth; actual recovery can require more space.
		ride.member_claims[actor] = maxf(float(ride.member_claims[actor]), float(_owner.get_ref().participants._member(actor).health))
		total += float(ride.member_claims[actor])
	ride.capacity_claim = total

func _place_dismounted_body(actor: String, vehicle: Dictionary, ride: Dictionary) -> void:
	var g: RefCounted = _owner.get_ref()
	var body: Dictionary = g.participants._member(actor)
	if body.get("vehicle_action_ref", "") != ride.id:
		return
	body.erase("vehicle_action_ref")
	body.xy = g._space.xy(vehicle)
	body.anchor_node = vehicle.spatial.node
	body.anchor_edge = ""
	body.local_ref = "node:" + str(vehicle.spatial.node)
	body.local_edge = ""
	body.cover_ref = ""
	body.erase("entered_site_ref")
	body.body_revision = int(body.get("body_revision", 0)) + 1
	body.state = "STATIONARY" if body.actionable else "DEAD" if body.life_state == "DEAD" else "INCAPACITATED"
	body.last_vehicle_exit = {"ride_ref": ride.id, "vehicle_ref": ride.carrier_ref, "command_ref": ride.command_ref, "at": g._state.time}

func _disembark_mobile_members(ride: Dictionary) -> void:
	var g: RefCounted = _owner.get_ref()
	var vehicle: Dictionary = g._state.units[ride.carrier_ref]
	var selected: Array = []
	for actor: String in ride.exiting_members:
		var body: Dictionary = g.participants._member(actor)
		if actor in ride.members and body.actionable and str(body.action_ref).is_empty() and body.get("vehicle_action_ref", "") == ride.id:
			selected.append(actor)
	var part: Dictionary = _passenger_part(ride)
	var exit_core: bool = ride.exit_part and not part.is_empty() and (float(part.anonymous) > 0.000001 or not selected.is_empty())
	if exit_core:
		# The part remains one stable ground aggregate; residual bodies are detached.
		for actor: String in ride.members:
			if actor not in selected:
				g.tactics.begin_local_duty(actor)
		part.erase("passenger_ref")
		part.spatial = vehicle.spatial.duplicate(true)
		part.spatial.mode = "FOOT"
		part.spatial.path = []
		part.role = "WATCH"
		part.revision += 1
		ride.part_aboard = false
		ride.anonymous_claim = 0.0
	for actor: String in selected:
		if not exit_core:
			g.tactics.begin_local_duty(actor)
		_place_dismounted_body(actor, vehicle, ride)
		ride.members.erase(actor)
		ride.member_claims.erase(actor)
	_refresh_ride_claim(ride)
	ride.status = "MOUNTED" if ride.part_aboard or not ride.members.is_empty() else "GROUND"
	ride.reason = "no_self_mobile_occupancy_at_completion" if selected.is_empty() and not exit_core else "remaining_onboard_body_requires_actual_handover" if ride.status == "MOUNTED" else ""
	ride.last_disembarked = selected.duplicate()
	ride.last_partial_exit = {"at": g._state.time, "command_ref": ride.command_ref, "members": selected.duplicate(), "part_dismounted": exit_core, "remaining_members": ride.members.duplicate()}
	ride.exiting_members = []
	ride.exit_part = false
	_release_passenger_marks(ride, ride.status == "MOUNTED")
	for actor: String in selected:
		g.participants._emit(actor, "actual_passenger_disembarked", str(ride.command_ref), {"ride_ref": ride.id, "vehicle_ref": ride.carrier_ref, "xy": g.participants.position(actor)})

func patient_job_for(actor: String) -> Dictionary:
	for job: Dictionary in patient_jobs.values():
		if job.status == "PENDING" and actor in [job.patient_ref, job.helper_ref]:
			return job
	return {}

func _patient_contact(helper: String, vehicle_ref: String) -> bool:
	var g: RefCounted = _owner.get_ref()
	if not _stopped_endpoint(vehicle_ref) or body_mounted(helper):
		return false
	var here: Dictionary = g.participants.body_spatial(helper)
	var unit: Dictionary = g._state.units[vehicle_ref]
	return g._space.movement_factor(g._space._nodes[unit.spatial.node].ground, "FOOT") > 0.0 and g._space.local_place(here) == "node:" + str(unit.spatial.node) and str(here.edge) == "" and str(here.get("local_edge", "")) == "" and g.tactics.StateDistance(g.participants.position(helper), g._space.xy(unit)) <= float(passenger_rules.contact_km)

func validate_vehicle_patient(helper: String, values: Dictionary, issuer: String = "") -> Dictionary:
	var g: RefCounted = _owner.get_ref()
	var p: RefCounted = g.participants
	if issuer.is_empty():
		issuer = helper
	if values.get("action", "") != "rescue":
		return g._reject("explicit_vehicle_patient_rescue_action_required")
	var action: String = str(values.get("rescue_action", ""))
	if action == "vehicle_cancel":
		return {"ok": true} if patient_jobs.get(helper, {}).get("status", "") == "PENDING" else g._reject("own_pending_vehicle_patient_handover_required")
	for key: String in values:
		if key not in ["action", "rescue_action", "patient_ref", "vehicle_ref"]:
			return g._reject("unknown_vehicle_patient_parameter")
	var patient: String = str(values.get("patient_ref", ""))
	var vehicle: String = str(values.get("vehicle_ref", ""))
	if action not in ["vehicle_load", "vehicle_unload"] or helper == patient or not p._units.has(helper) or not p._units.has(patient) or not passenger_capacity.has(vehicle) or p.dead(patient):
		return g._reject("existing_living_patient_helper_and_declared_motor_deck_required")
	if not patient_job_for(helper).is_empty() or not patient_job_for(patient).is_empty() or passenger_handling(vehicle) or _tickets.size() >= 256:
		return g._reject("one_unfinished_actual_patient_handover_per_helper_and_body")
	var body: Dictionary = p._member(helper)
	var patient_body: Dictionary = p._member(patient)
	if not body.actionable or float(body.health) < float(p.rules.minimum_carrier_health) or p._physical_unit(helper).spatial.mode != "FOOT" or not body_ride(helper).is_empty() or str(body.action_ref) != "" or float(body.get("combat_busy_until", 0.0)) > g._state.time or p.relay_involves(helper) or p.relay_involves(patient) or g.medical.carry_jobs.has(helper) or g.tactics.weapons.get(helper, {}).get("status", "") in ["AIMING", "RELOADING"]:
		return g._reject("able_ground_helper_without_conflicting_actual_duty_required")
	if g.tactics._carried_amount(helper) > 0.000001:
		return g._reject("settle_actual_ammunition_carrying_before_patient_vehicle_handover")
	var helper_unit: String = str(p._units[helper])
	var patient_unit: String = str(p._units[patient])
	var quantity: float = maxf(float(passenger_rules.patient_capacity), float(patient_body.health))
	if not g.tactics._free(p._physical_unit(helper)) or not g.tactics.supply_job(helper_unit).is_empty() or g.tactics.manoeuvre_active(helper_unit) and g.tactics.manoeuvres[helper_unit].phase != "STOPPED" or g._state.units[vehicle].side != p._physical_unit(patient).side or g.tactics.local_cooperation(helper_unit, vehicle).is_empty() or not p._known_patient(issuer, patient) or not _patient_contact(helper, vehicle):
		return g._reject("known_patient_legal_cooperation_and_actual_stopped_endpoint_contact_required")
	if patient_body.get("treatment", {}).get("status", "") == "IN_PROGRESS":
		return g._reject("finish_or_interrupt_current_patient_care_before_vehicle_handover")
	if action == "vehicle_load":
		if not p.transport_check(patient, helper, true).ok or not body_ride(patient).is_empty() or _unit_jobs.has(vehicle) or g.air.recovery._unit_jobs.has(vehicle) or g.operations.occupied_ground(vehicle) or g.tactics.occupied(vehicle) or not g._state.coordination.get(vehicle, {}).is_empty() or passenger_load(vehicle) + quantity > seats(vehicle) + 0.000001:
			return g._reject("actual_carried_patient_and_free_existing_passenger_capacity_required")
		var reference: String = "passenger-person:" + patient
		if passenger_rides.size() >= 16 and not passenger_rides.has(reference):
			return g._reject("finite_passenger_record_capacity")
	else:
		var ride: Dictionary = body_ride(patient)
		if ride.get("status", "") != "MOUNTED" or ride.carrier_ref != vehicle or patient_body.has("carrier_ref") or not str(body.get("carrying_ref", "")).is_empty() or patient_body.life_state not in ["WOUNDED", "INCAPACITATED"] and ride.payload_kind != "PATIENT":
			return g._reject("actual_onboard_patient_and_unoccupied_receiving_helper_required")
		if g.tactics.local_cooperation(helper_unit, patient_unit).is_empty():
			return g._reject("current_friendly_patient_relay_cooperation_required")
	var leaves: Array[String] = [helper_unit]
	for unit_ref: String in [patient_unit, vehicle]:
		if unit_ref not in leaves:
			leaves.append(unit_ref)
	var admission: Dictionary = g._state.structure_port.get_ref()._members._representation_capacity(leaves)
	if not admission.ok:
		return admission
	return {"ok": true, "patient_ref": patient, "vehicle_ref": vehicle, "quantity": quantity}

func vehicle_patient_action(helper: String, id: String, values: Dictionary, issuer: String = "") -> Dictionary:
	var valid: Dictionary = validate_vehicle_patient(helper, values, issuer)
	if not valid.ok:
		return valid
	if values.rescue_action == "vehicle_cancel":
		var cancelled: Dictionary = patient_jobs[helper]
		_cancel_patient_job(cancelled, "received_patient_vehicle_cancel")
		return {"ok": true, "status": "INTERRUPTED", "changed": [cancelled.patient_unit_ref, cancelled.helper_unit_ref, cancelled.vehicle_ref], "retired": []}
	var g: RefCounted = _owner.get_ref()
	var p: RefCounted = g.participants
	var patient: String = str(valid.patient_ref)
	var vehicle: String = str(valid.vehicle_ref)
	for unit_ref: String in [str(p._units[helper]), str(p._units[patient]), vehicle]:
		g._lod.materialize_leaf(unit_ref, "actual_vehicle_patient_handover")
	var body: Dictionary = p._member(helper)
	body.xy = p.position(helper)
	body.anchor_node = p.body_spatial(helper).node
	g.tactics.begin_local_duty(helper)
	g.tactics.body_action_started(helper)
	body.body_revision = int(body.get("body_revision", 0)) + 1
	var prior: Dictionary = patient_jobs.get(helper, {})
	var ride: Dictionary = body_ride(patient)
	var job: Dictionary = {"id": id, "helper_ref": helper, "patient_ref": patient, "helper_unit_ref": p._units[helper], "patient_unit_ref": p._units[patient], "vehicle_ref": vehicle,
		"issuer": helper if issuer.is_empty() else issuer, "kind": "LOAD" if values.rescue_action == "vehicle_load" else "UNLOAD", "status": "PENDING", "started_at": g._state.time,
		"due": g._state.time + float(passenger_rules.handling_seconds), "version": int(prior.get("version", 0)) + 1, "pending": "", "quantity": valid.quantity,
		"ride_ref": str(ride.get("id", "passenger-person:" + patient)), "ride_version": int(ride.get("version", -1)), "helper_body_revision": body.body_revision,
		"predecessor_ref": p._member(patient).get("transport_ref", ride.get("id", "")), "mission_ref": p._physical_unit(patient).mission_id, "original_xy": p.position(patient).duplicate()}
	patient_jobs[helper] = job
	body.vehicle_patient_job_ref = id
	body.state = "VEHICLE_LOADING" if job.kind == "LOAD" else "VEHICLE_UNLOADING"
	_serial += 1
	var ticket: String = "land_vehicle_patient_%d" % _serial
	job.pending = ticket
	_tickets[ticket] = {"job_ref": helper, "version": job.version, "kind": "PATIENT_" + str(job.kind), "due": job.due, "status": "PENDING"}
	g._state.schedule_event(ticket, job.due, "gameplay", {"land_id": ticket})
	_report_patient_job(job, "PENDING")
	return {"ok": true, "status": body.state, "patient_ref": patient, "changed": [job.patient_unit_ref, job.helper_unit_ref, vehicle], "retired": []}

func _patient_job_valid(job: Dictionary) -> bool:
	var g: RefCounted = _owner.get_ref()
	var p: RefCounted = g.participants
	var helper: Dictionary = p._member(str(job.helper_ref))
	var patient: Dictionary = p._member(str(job.patient_ref))
	if p.dead(str(job.patient_ref)) or not helper.actionable or float(helper.health) < float(p.rules.minimum_carrier_health) or helper.get("vehicle_patient_job_ref", "") != job.id or int(helper.get("body_revision", -1)) != int(job.helper_body_revision) or str(helper.action_ref) != "" or not _patient_contact(str(job.helper_ref), str(job.vehicle_ref)) or p._units[job.helper_ref] != job.helper_unit_ref or p._units[job.patient_ref] != job.patient_unit_ref or patient.get("treatment", {}).get("status", "") == "IN_PROGRESS":
		return false
	if p.body_suppression(str(job.helper_ref)) >= float(g._state.missions[p._physical_unit(str(job.helper_ref)).mission_id].stop_suppression):
		return false
	if job.kind == "LOAD":
		return patient.get("carrier_ref", "") == job.helper_ref and helper.get("carrying_ref", "") == job.patient_ref and body_ride(str(job.patient_ref)).is_empty() and passenger_load(str(job.vehicle_ref)) <= seats(str(job.vehicle_ref)) + 0.000001
	var ride: Dictionary = body_ride(str(job.patient_ref))
	return ride.get("id", "") == job.ride_ref and ride.get("status", "") == "MOUNTED" and int(ride.version) == int(job.ride_version) and ride.carrier_ref == job.vehicle_ref and str(helper.get("carrying_ref", "")) == "" and not patient.has("carrier_ref")

func _clear_patient_helper(job: Dictionary) -> void:
	var p: RefCounted = _owner.get_ref().participants
	var body: Dictionary = p._member(str(job.helper_ref))
	if body.get("vehicle_patient_job_ref", "") == job.id:
		body.erase("vehicle_patient_job_ref")
		body.body_revision = int(body.get("body_revision", 0)) + 1
		body.state = "STATIONARY" if body.actionable else "DEAD" if body.life_state == "DEAD" else "INCAPACITATED"
		_owner.get_ref().tactics.rejoin_local_duty(str(job.helper_ref))

func _cancel_patient_job(job: Dictionary, reason: String) -> void:
	if job.status != "PENDING":
		return
	job.status = "INTERRUPTED"
	job.version += 1
	job.pending = ""
	job.reason = reason
	job.finished_at = _owner.get_ref()._state.time
	_clear_patient_helper(job)
	_report_patient_job(job, "INTERRUPTED")

func _finish_vehicle_patient(event: Dictionary) -> Dictionary:
	var ticket: Dictionary = _tickets[event.id]
	_tickets.erase(event.id)
	var job: Dictionary = patient_jobs.get(ticket.job_ref, {})
	if job.is_empty() or job.status != "PENDING" or int(job.version) != int(ticket.version) or job.pending != event.id:
		return {"changed": [], "retired": [], "record": {"kind": "vehicle_patient", "status": "STALE"}}
	var g: RefCounted = _owner.get_ref()
	var p: RefCounted = g.participants
	if not _patient_job_valid(job):
		_cancel_patient_job(job, "actual_patient_helper_or_endpoint_condition_changed")
	else:
		job.status = "LOADED" if job.kind == "LOAD" else "RECEIVED_BY_HELPER"
		job.pending = ""
		job.finished_at = g._state.time
		job.last_event_ref = event.id
		if job.kind == "LOAD":
			var reference: String = "passenger-person:" + str(job.patient_ref)
			var previous: Dictionary = passenger_rides.get(reference, {})
			g.tactics.begin_local_duty(str(job.patient_ref))
			var members: Array = [job.patient_ref]
			var ride: Dictionary = {"id": reference, "unit_ref": job.patient_unit_ref, "carrier_ref": job.vehicle_ref, "deck_ref": passenger_capacity[job.vehicle_ref].id, "issuer": job.issuer,
				"part_ref": "", "part_aboard": false, "anonymous_claim": 0.0, "members": members, "roster": members.duplicate(), "member_claims": {job.patient_ref: job.quantity}, "capacity_claim": job.quantity,
				"status": "MOUNTED", "version": int(previous.get("version", 0)) + 1, "started_at": job.started_at, "finished_at": job.finished_at, "pending": "", "command_ref": job.id,
				"mission_ref": job.mission_ref, "predecessor_ref": job.predecessor_ref, "origin_xy": job.original_xy.duplicate(), "origin_spatial": g._state.units[job.vehicle_ref].spatial.duplicate(true),
				"last_damage_ref": "", "exiting_members": [], "exit_part": false, "handling_actor": job.helper_ref, "payload_kind": "PATIENT"}
			p.commit_vehicle_loading(str(job.patient_ref), str(job.helper_ref), reference, str(job.id))
			passenger_rides[reference] = ride
			p._member(str(job.patient_ref)).vehicle_action_ref = reference
			_sync_passengers(str(job.vehicle_ref))
			_clear_patient_helper(job)
			_passenger_report(ride, "PATIENT_LOADED")
		else:
			var ride: Dictionary = passenger_rides[job.ride_ref]
			g.tactics.begin_local_duty(str(job.patient_ref))
			_place_dismounted_body(str(job.patient_ref), g._state.units[job.vehicle_ref], ride)
			ride.members.erase(job.patient_ref)
			ride.member_claims.erase(job.patient_ref)
			ride.version += 1
			var part: Dictionary = _passenger_part(ride)
			if ride.part_aboard and ride.members.is_empty() and not part.is_empty() and float(part.anonymous) <= 0.000001:
				# The final actual unloading also leaves the empty part's gear here.
				part.erase("passenger_ref")
				part.spatial = g._state.units[job.vehicle_ref].spatial.duplicate(true)
				part.spatial.mode = "FOOT"
				part.spatial.path = []
				part.role = "WATCH"
				part.revision += 1
				ride.part_aboard = false
				ride.anonymous_claim = 0.0
			_refresh_ride_claim(ride)
			ride.status = "MOUNTED" if ride.part_aboard or not ride.members.is_empty() else "GROUND"
			p.commit_vehicle_unloading(str(job.patient_ref), str(job.helper_ref), str(job.ride_ref), str(job.id), str(job.issuer))
			_clear_patient_helper(job)
			_passenger_report(ride, "PATIENT_RECEIVED_BY_HELPER")
		_report_patient_job(job, str(job.status))
	return {"changed": [job.patient_unit_ref, job.helper_unit_ref, job.vehicle_ref], "retired": [], "record": {"kind": "vehicle_patient", "patient_ref": job.patient_ref, "status": job.status, "job_ref": job.id}}

func _report_patient_job(job: Dictionary, status: String) -> void:
	var g: RefCounted = _owner.get_ref()
	var platform: String = str(carriers[job.vehicle_ref].report_source)
	_report_serial += 1
	var recipients: Array = [job.issuer]
	var structure: RefCounted = g._state.structure_port.get_ref()
	for unit_ref: String in [job.helper_unit_ref, job.patient_unit_ref, job.vehicle_ref]:
		for node: String in structure._path(str(structure._unit_nodes.get(unit_ref, ""))):
			var officer: String = str(structure._positions.get(node, {}).get("person", ""))
			if officer != "" and officer not in recipients:
				recipients.append(officer)
	var body: Dictionary = g.participants._member(str(job.patient_ref))
	var value: Dictionary = {"person_ref": job.patient_ref, "life_state": body.life_state, "body_status": body.state, "vehicle_ref": job.vehicle_ref, "vehicle_job_ref": job.id,
		"vehicle_handover_status": status, "helper_ref": job.helper_ref, "transport_ref": body.get("transport_ref", ""), "xy": g.participants.position(str(job.patient_ref)), "node_ref": g.participants.body_spatial(str(job.patient_ref)).node}
	var claims: Array[Dictionary] = [{"id": job.id + "_%d" % _report_serial, "source_ref": platform, "observer_ref": platform, "subject_kind": "person", "subject_ref": job.patient_ref, "fact_kind": "person_status", "value": value, "observed_at": g._state.time, "precision": "actual_vehicle_patient_handover", "quality": 1.0, "origin": "GROUND_TRANSPORT"}]
	for recipient: String in recipients:
		g._state.information_port.get_ref().send_platform_report(self, platform, recipient, "vehicle_patient_report_%d_" % _report_serial + recipient, claims)
	g.participants._emit(str(job.helper_ref), "vehicle_patient_handover", str(job.id), {"patient_ref": job.patient_ref, "vehicle_ref": job.vehicle_ref, "status": status})
