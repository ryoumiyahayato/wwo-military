extends RefCounted
const State = preload("res://experiments/war_resolver/battle_state.gd")
## Replaceable slice rules: severe fresh injury bleeds; one kit and timed care
## stabilize it. Treatment permits one partial recovery, never resurrection.
var _owner: WeakRef
var _trained: Dictionary = {}
var _tickets: Dictionary = {}
var _serial: int = 0
var carried: Dictionary = {} # Reservations in the existing source unit's MEDICAL.
var carry_jobs: Dictionary = {}
const CARRY_CAPACITY: float = 2.0
const HANDLING_SECONDS: float = 5.0
const MAX_TICKETS: int = 2048
const BLEED_PERIOD: float = 30.0
const BLEED_RATE: float = 0.001
const CARE_SECONDS: float = 30.0
const RECOVERY_SECONDS: float = 300.0
const RECOVERY_AMOUNT: float = 0.25

func configure(gameplay: RefCounted) -> void:
	_owner = weakref(gameplay)
	gameplay.participants.medical = self

func admit_healer(actor: String) -> bool:
	var g: RefCounted = _owner.get_ref()
	if g._state.time != 0.0 or not g.participants._units.has(actor) or _trained.size() >= 2:
		return false
	_trained[actor] = true
	return true

func carried_amount(actor: String) -> float:
	var pack: Dictionary = carried.get(actor, {})
	return float(pack.get("amount", 0.0)) if pack.get("status", "") == "HELD" else 0.0

func reserved(unit: String) -> float:
	var result: float = 0.0
	for pack: Dictionary in carried.values():
		if pack.unit_ref == unit:
			result += float(pack.amount)
	for job: Dictionary in carry_jobs.values():
		if job.supply_unit == unit and job.mode == "take":
			result += float(job.quantity)
	return result

func has_carry_responsibility(unit: String) -> bool:
	var p: RefCounted = _owner.get_ref().participants
	for actor: String in carried:
		if float(carried[actor].amount) > 0.000001 and (carried[actor].unit_ref == unit or p._units.get(actor, "") == unit):
			return true
	for job: Dictionary in carry_jobs.values():
		if job.supply_unit == unit or job.actor_unit_ref == unit:
			return true
	return false

func available_at_unit(unit: String) -> float:
	var actual: Dictionary = _owner.get_ref()._state.units.get(unit, {})
	return maxf(0.0, float(actual.get("medical", 0.0)) - reserved(unit))

func _stock_contact(actor: String, unit: String) -> bool:
	var g: RefCounted = _owner.get_ref()
	if not g._state.units.has(unit):
		return false
	var body: Dictionary = g.participants.body_spatial(actor)
	var stock: Dictionary = g._state.units[unit].spatial
	return body.node == stock.node and g._space.local_place(body) == g._space.local_place(stock) and str(body.edge) == "" and str(stock.edge) == "" and str(body.get("local_edge", "")) == "" and str(stock.get("local_edge", "")) == "" and stock.path.is_empty() and g.participants._distance(g.participants.position(actor), g._space.xy(g._state.units[unit])) <= float(g.participants.rules.local_radius_km)

func validate_carry(actor: String, values: Dictionary, executing: bool = false) -> Dictionary:
	var g: RefCounted = _owner.get_ref()
	var p: RefCounted = g.participants
	if values.get("action", "") == "medical_supply" and values.get("medical_action", "") == "cancel":
		return {"ok": true} if values.size() == 2 and carry_jobs.has(actor) and p._units.has(actor) and p._member(actor).action_ref == carry_jobs[actor].action_ref and p._actions.get(p._member(actor).action_ref, {}).get("medical_carry_ref", "") == carry_jobs[actor].id else _reject("existing_owned_medical_handling_required")
	if not p._units.has(actor) or not p.can_intend(actor) or not str(p._member(actor).action_ref).is_empty() or carry_jobs.has(actor) or not executing and p._actions.size() >= p.MAX_ACTIONS or p._physical_unit(actor).spatial.mode != "FOOT" or float(p._member(actor).health) < float(p.rules.minimum_carrier_health):
		return _reject("existing_available_foot_medical_carrier_required")
	if g.tactics.manoeuvre_active(str(p._units[actor])) and g.tactics.manoeuvres[p._units[actor]].phase != "STOPPED" or not g.tactics.supply_job(str(p._units[actor])).is_empty() or g.tactics.weapons.get(actor, {}).get("status", "") in ["AIMING", "RELOADING"] or float(p._member(actor).get("combat_busy_until", 0.0)) > g._state.time:
		return _reject("finish_conflicting_personal_or_part_operation_before_medical_handling")
	if g.tactics._carried_amount(actor) > 0.000001 or not str(p._member(actor).get("carrying_ref", "")).is_empty():
		return _reject("finish_existing_ammunition_or_patient_handling_before_loading_medical_stock")
	if values.get("action", "") != "medical_supply" or values.get("medical_action", "") not in ["take", "return", "recover"] or not g.tactics._positive(values.get("quantity")):
		return _reject("explicit_medical_supply_action_and_quantity_required")
	for key: String in values:
		if key not in ["action", "medical_action", "quantity", "supply_unit", "holder_ref"]:
			return _reject("unsupported_medical_carry_field")
	var mode: String = str(values.medical_action)
	var source_actor: String = str(values.get("holder_ref", actor))
	var pack: Dictionary = carried.get(source_actor, {}) if mode == "recover" else carried.get(actor, {})
	var unit: String = str(values.get("supply_unit", pack.get("unit_ref", p._units[actor])))
	if mode == "recover":
		if pack.get("status", "") != "STRANDED" or pack.get("unit_ref", "") != unit or g._space.local_place(p.body_spatial(actor)) != g._space.local_place(pack.spatial) or str(p.body_spatial(actor).get("local_edge", "")) != "" or p._distance(p.position(actor), pack.xy) > float(p.rules.local_radius_km):
			return _reject("actual_contact_with_existing_stranded_medical_responsibility_required")
	elif not _stock_contact(actor, unit):
		return _reject("actual_contact_with_source_medical_stock_required")
	if not g._state.units.has(unit) or g._state.units[unit].side != p._physical_unit(actor).side or not executing and g.tactics.local_cooperation(str(p._units[actor]), unit).is_empty() or not g.tactics._free(g._state.units[unit]):
		return _reject("current_legal_medical_supply_cooperation_required")
	var held: Dictionary = carried.get(actor, {})
	if float(held.get("amount", 0.0)) > 0.000001 and (held.get("unit_ref", "") != unit or held.get("status", "") != "HELD" and source_actor != actor):
		return _reject("settle_existing_medical_custody_before_mixing_sources")
	var available: float = available_at_unit(unit) if mode == "take" else float(pack.get("amount", 0.0))
	if mode == "return" and pack.get("status", "") != "HELD":
		return _reject("recover_actual_stranded_medical_stock_before_returning_it")
	var room: float = INF if mode == "return" else maxf(0.0, float(p._member(actor).health) * CARRY_CAPACITY - carried_amount(actor))
	var quantity: float = minf(float(values.quantity), minf(available, room))
	if mode == "recover" and source_actor == actor and quantity + 0.000001 < available:
		return _reject("self_recovery_requires_capacity_for_the_existing_whole_pack")
	return {"ok": true, "supply_unit": unit, "quantity": quantity, "holder_ref": source_actor} if quantity > 0.000001 else _reject("finite_existing_medical_stock_and_carry_capacity_required")

func start_carry(actor: String, id: String, values: Dictionary) -> Dictionary:
	var valid: Dictionary = validate_carry(actor, values)
	if not valid.ok:
		return valid
	var g: RefCounted = _owner.get_ref()
	var p: RefCounted = g.participants
	if values.medical_action == "cancel":
		var job: Dictionary = carry_jobs[actor].duplicate(true)
		p.interrupt_action(actor, "received_medical_handling_cancel")
		return {"ok": true, "status": "INTERRUPTED", "changed": [job.actor_unit_ref, job.supply_unit], "retired": []}
	g.tactics.begin_local_duty(actor)
	p._start(actor, id, "MEDICAL_HANDLING", p.position(actor), "", HANDLING_SECONDS + float(valid.quantity))
	var action: Dictionary = p._actions[p._member(actor).action_ref]
	action.medical_carry_ref = id
	carry_jobs[actor] = {"id": id, "mode": values.medical_action, "actor_ref": actor, "actor_unit_ref": p._units[actor], "supply_unit": valid.supply_unit,
		"cooperation_ref": g.tactics.local_cooperation(str(p._units[actor]), str(valid.supply_unit)), "holder_ref": valid.holder_ref, "source_revision": int(carried.get(str(valid.holder_ref), {}).get("revision", 0)) if values.medical_action == "recover" else int(carried.get(actor, {}).get("revision", 0)),
		"quantity": valid.quantity, "requested_quantity": values.quantity, "action_ref": action.id, "started_at": g._state.time, "due": action.due}
	return {"ok": true, "status": "MEDICAL_HANDLING", "quantity": valid.quantity, "changed": [p._units[actor], valid.supply_unit], "retired": []}

func cancel_carry(actor: String, reference: String) -> void:
	if carry_jobs.get(actor, {}).get("id", "") == reference:
		carry_jobs.erase(actor) # Unloaded reservations are released; held stock stays held.

func complete_carry(action: Dictionary) -> Dictionary:
	var g: RefCounted = _owner.get_ref()
	var p: RefCounted = g.participants
	var actor: String = str(action.actor_ref)
	var job: Dictionary = carry_jobs.get(actor, {})
	if job.get("id", "") != action.get("medical_carry_ref", "missing") or job.get("action_ref", "") != action.id:
		if p._member(actor).action_ref == action.id:
			action.status = "OBSOLETE"
			p._member(actor).action_ref = ""
			p._member(actor).state = "STATIONARY" if p._member(actor).actionable else "INCAPACITATED"
		return {"changed": [], "retired": [], "record": {"status": "OBSOLETE_MEDICAL_HANDLING"}}
	carry_jobs.erase(actor)
	var values: Dictionary = {"action": "medical_supply", "medical_action": job.mode, "quantity": job.quantity, "supply_unit": job.supply_unit, "holder_ref": job.holder_ref}
	# Recheck actual contact without treating this action's own occupancy as a conflict.
	p._member(actor).action_ref = ""
	p._member(actor).state = "STATIONARY" if p._member(actor).actionable else "INCAPACITATED"
	var valid: Dictionary = validate_carry(actor, values, true) if p._units[actor] == job.actor_unit_ref else _reject("medical_carrier_membership_changed")
	var stock_holder: String = str(job.holder_ref) if job.mode == "recover" else actor
	if int(carried.get(stock_holder, {}).get("revision", 0)) != int(job.source_revision):
		valid = _reject("medical_custody_changed_since_this_handling_was_accepted")
	var quantity: float = float(valid.get("quantity", 0.0)) if valid.ok else 0.0
	if quantity > 0.000001:
		if not carried.has(actor):
			carried[actor] = {"id": "medical_carry:" + actor, "unit_ref": job.supply_unit, "source_ref": job.supply_unit, "holder_ref": actor, "amount": 0.0, "status": "HELD", "revision": 0, "consumed": 0.0}
		var pack: Dictionary = carried[actor]
		if float(pack.amount) <= 0.000001 and job.mode == "take":
			pack.source_ref = job.supply_unit
		if job.mode == "recover":
			carried[job.holder_ref].amount -= quantity
			pack.source_ref = carried[job.holder_ref].source_ref
			if job.holder_ref != actor:
				carried[job.holder_ref].revision += 1
				carried[job.holder_ref].last_handover = {"id": job.id, "mode": "recovered", "quantity": quantity, "at": g._state.time, "receiver_ref": actor}
		pack.unit_ref = job.supply_unit
		pack.holder_ref = actor
		pack.status = "HELD"
		pack.amount += -quantity if job.mode == "return" else quantity
		pack.revision += 1
		pack.last_handover = {"id": job.id, "mode": job.mode, "quantity": quantity, "at": g._state.time, "source_unit_ref": job.supply_unit, "previous_holder_ref": job.holder_ref}
	action.status = "EXECUTED" if quantity > 0.000001 else "INTERRUPTED"
	action.medical_carry_result = {"quantity": quantity, "requested_quantity": job.requested_quantity, "remaining": float(job.requested_quantity) - quantity, "supply_unit": job.supply_unit, "mode": job.mode, "reason": valid.get("error", "")}
	g.tactics.body_action_finished(actor, str(action.id), str(action.status))
	p._emit(actor, "medical_carry_result", str(job.id), action.medical_carry_result)
	return {"changed": [job.actor_unit_ref, job.supply_unit], "retired": [], "record": action.medical_carry_result.duplicate(true)}

func on_unit(unit: String) -> void:
	var g: RefCounted = _owner.get_ref()
	var p: RefCounted = g.participants
	for actor: String in carried:
		var pack: Dictionary = carried[actor]
		if p._units.get(actor, "") == unit and pack.status == "HELD" and not g.land.body_mounted(actor) and float(pack.amount) > 0.000001 and (not p._member(actor).actionable or float(p._member(actor).health) < float(p.rules.minimum_carrier_health) or float(pack.amount) > float(p._member(actor).health) * CARRY_CAPACITY + 0.000001):
			pack.xy = p.position(actor)
			pack.spatial = p.body_spatial(actor).duplicate(true)
			pack.status = "STRANDED"
			pack.holder_ref = "ground:" + str(pack.id)
			pack.revision += 1
			p._emit(actor, "medical_supply_stranded", str(pack.get("last_handover", {}).get("id", "")), {"quantity": pack.amount, "xy": pack.xy, "source_unit_ref": pack.unit_ref})
	for actor: String in carry_jobs.keys():
		var job: Dictionary = carry_jobs[actor]
		if job.actor_unit_ref == unit and (not p._member(actor).actionable or float(p._member(actor).health) < float(p.rules.minimum_carrier_health)):
			cancel_carry(actor, str(job.id))
			if p._member(actor).action_ref == job.action_ref:
				p.interrupt_action(actor, "medical_carrier_incapacitated")

func _care_contact(actor: String, patient: String) -> bool:
	var g: RefCounted = _owner.get_ref()
	var p: RefCounted = g.participants
	var a: Dictionary = p.body_spatial(actor)
	var b: Dictionary = p.body_spatial(patient)
	return a.node == b.node and g._space.local_place(a) == g._space.local_place(b) and str(a.get("local_edge", "")) == "" and str(b.get("local_edge", "")) == "" and p._distance(p.position(actor), p.position(patient)) <= float(p.rules.local_radius_km)

func _portable_source(actor: String, unit: String) -> String:
	var g: RefCounted = _owner.get_ref()
	var p: RefCounted = g.participants
	for holder: String in State.sorted_ids(carried):
		var pack: Dictionary = carried[holder]
		if pack.unit_ref == unit and pack.status == "HELD" and float(pack.amount) >= 1.0 and p._member(holder).actionable and float(p._member(holder).health) >= float(p.rules.minimum_carrier_health) and p._member(holder).state in ["FOLLOWING", "COVERED", "STATIONARY"] and str(p._member(holder).action_ref).is_empty() and _care_contact(actor, holder):
			return holder
	return ""

func on_hurt(actor: String, dose: float, loss: float, cause_ref: String, cause: String) -> void:
	var g: RefCounted = _owner.get_ref()
	var body: Dictionary = g.participants._member(actor)
	if g.participants.dead(actor):
		if body.has("bleeding"):
			body.bleeding.active = false
		if body.has("treatment"):
			body.treatment.status = "PATIENT_DEAD"
		return
	if cause == "bleeding":
		return
	if body.get("treatment", {}).get("status", "") == "RECOVERING":
		body.treatment.status = "RECOVERY_INTERRUPTED"
		body.care_version = int(body.get("care_version", 0)) + 1
	if loss < 0.25 and dose <= loss:
		return
	# A fresh severe wound interrupts care; minor new damage still blocks recovery.
	body.care_version = int(body.get("care_version", 0)) + 1
	if body.get("bleeding", {}).get("active", false):
		return
	body.bleeding = {"active": true, "rate": BLEED_RATE, "last_at": g._state.time, "cause_ref": cause_ref,
		"version": int(body.get("bleeding", {}).get("version", 0)) + 1}
	_schedule(actor, "bleed", g._state.time + BLEED_PERIOD, int(body.bleeding.version))

func validate(actor: String, values: Dictionary) -> Dictionary:
	var g: RefCounted = _owner.get_ref()
	var p: RefCounted = g.participants
	if values.size() != 4 or values.get("action", "") != "aid" or values.get("mode", "") not in ["stabilize", "treat"] or not values.get("patient_ref") is String or not values.get("supply_unit") is String:
		return _reject("aid_requires_patient_mode_and_actual_supply_unit")
	var patient: String = str(values.patient_ref)
	var supply: String = str(values.supply_unit)
	if not _trained.has(actor) or not p.can_intend(actor) or not p._units.has(patient) or p.dead(patient) or actor == patient:
		return _reject("existing_qualified_helper_and_living_patient_required")
	if _tickets.size() >= MAX_TICKETS - 3 or p._actions.size() >= p.MAX_ACTIONS:
		return _reject("medical_record_capacity")
	if p._member(actor).state not in ["FOLLOWING", "COVERED", "STATIONARY"] or p._member(patient).get("treatment", {}).get("status", "") == "IN_PROGRESS":
		return _reject("conflicting_personal_action")
	if not g.land.patient_job_for(actor).is_empty() or not g.land.patient_job_for(patient).is_empty():
		return _reject("finish_or_cancel_actual_patient_vehicle_handover_before_care")
	if float(p._member(patient).injury) <= 0.0 and float(p._member(patient).trauma) <= 0.0:
		return _reject("no_existing_injury_to_treat")
	if not g._state.units.has(supply) or not g._lod.has_leaf(supply) or not g._state.units[supply].has("medical") or float(g._state.units[supply].medical) < 1.0:
		return _reject("one_existing_medical_kit_required")
	var unit: Dictionary = g._state.units[supply]
	var holder: String = _portable_source(actor, supply)
	if unit.side != p._physical_unit(actor).side or p._physical_unit(patient).side != unit.side or not _care_contact(actor, patient) or holder.is_empty() and (available_at_unit(supply) < 1.0 or not str(unit.spatial.edge).is_empty() or not unit.spatial.path.is_empty() or not _near(actor, patient, supply)):
		return _reject("helper_patient_and_medical_stock_must_be_at_actual_care_location")
	var leaves: Array[String] = [str(p._units[actor])]
	if p._units[patient] not in leaves:
		leaves.append(str(p._units[patient]))
	var admission: Dictionary = g._state.structure_port.get_ref()._members._representation_capacity(leaves)
	if admission.ok:
		admission.supply_holder_ref = holder
	return admission

func _near(actor: String, patient: String, supply: String) -> bool:
	var g: RefCounted = _owner.get_ref()
	var p: RefCounted = g.participants
	var helper: Dictionary = p.body_spatial(actor)
	var body: Dictionary = p.body_spatial(patient)
	var stock: Dictionary = g._state.units[supply].spatial
	return g._space.local_place(helper) == g._space.local_place(body) and g._space.local_place(helper) == g._space.local_place(stock) and str(helper.get("local_edge", "")) == "" and str(body.get("local_edge", "")) == "" and p._distance(p.position(actor), p.position(patient)) <= float(p.rules.local_radius_km) and p._distance(p.position(actor), g._space.xy(g._state.units[supply])) <= float(p.rules.local_radius_km)

func start(actor: String, id: String, values: Dictionary) -> Dictionary:
	var g: RefCounted = _owner.get_ref()
	var valid: Dictionary = validate(actor, values)
	if not valid.ok:
		return valid
	var p: RefCounted = g.participants
	var changed: Dictionary = {}
	var retired: Dictionary = {}
	for leaf: String in [str(p._units[actor]), str(p._units[values.patient_ref])]:
		var expanded: Dictionary = g._lod.materialize_leaf(leaf, "actual_local_medical_care")
		for unit_id: String in expanded.get("changed", []):
			changed[unit_id] = true
		for unit_id: String in expanded.get("retired", []):
			retired[unit_id] = true
	var unit: Dictionary = g._state.units[values.supply_unit]
	var holder: String = str(valid.supply_holder_ref)
	if not holder.is_empty():
		carried[holder].amount -= 1.0
		carried[holder].consumed += 1.0
		carried[holder].revision += 1
		carried[holder].last_consumption = {"id": id, "source_unit_ref": values.supply_unit, "patient_ref": values.patient_ref, "helper_ref": actor, "quantity": 1.0, "at": g._state.time}
		changed[p._units[holder]] = true
	unit.medical -= 1.0
	unit.medical_spent += 1.0
	g._state.logistics_ledger.medical_spent += 1.0
	g.tactics.begin_local_duty(actor)
	p._start(actor, id, "MEDICATING", p.position(actor), "", CARE_SECONDS)
	var action: Dictionary = p._actions[p._member(actor).action_ref]
	action.medical = values.duplicate(true)
	action.medical.supply_holder_ref = holder
	action.medical.supply_kind = "UNIT" if holder.is_empty() else "PERSON"
	action.medical.consumed_at = g._state.time
	action.medical.patient_version = int(p._member(str(values.patient_ref)).get("care_version", 0))
	p._member(str(values.patient_ref)).treatment = {"status": "IN_PROGRESS", "helper_ref": actor, "input_ref": id, "started_at": g._state.time, "due": action.due}
	if not holder.is_empty():
		g.tactics.rejoin_local_duty(holder)
	g.focus_continuity.event_relation(actor, str(values.patient_ref), "medical_contact", id)
	changed[unit.id] = true
	changed[p._units[actor]] = true
	return {"ok": true, "status": "MEDICATING", "changed": State.sorted_ids(changed), "retired": State.sorted_ids(retired)}

func complete(action: Dictionary) -> Dictionary:
	var g: RefCounted = _owner.get_ref()
	var p: RefCounted = g.participants
	var patient: String = str(action.medical.patient_ref)
	var body: Dictionary = p._member(patient)
	var contact: bool = _care_contact(str(action.actor_ref), patient) if action.medical.get("supply_kind", "UNIT") == "PERSON" else g._state.units.has(action.medical.supply_unit) and _near(str(action.actor_ref), patient, str(action.medical.supply_unit))
	if p.dead(patient) or not contact or int(body.get("care_version", 0)) != int(action.medical.patient_version):
		body.treatment.status = "INTERRUPTED"
		return {"status": "CARE_INTERRUPTED"}
	var changed: Array = []
	if body.get("bleeding", {}).get("active", false):
		# Include blood lost since the last ticket up to actual stabilization time.
		var dose: float = float(body.bleeding.rate) * (g._state.time - float(body.bleeding.last_at))
		body.bleeding.last_at = g._state.time
		changed = p.external_damage(patient, dose, str(action.id) + "_bleeding_until_care", "bleeding").changed
		if p.dead(patient):
			return {"status": "PATIENT_DIED_BEFORE_STABILIZATION", "changed": changed}
	body.treatment.status = "STABILIZED"
	body.care_version = int(body.get("care_version", 0)) + 1
	if body.has("bleeding"):
		body.bleeding.active = false
		body.bleeding.version += 1
	if action.medical.mode == "treat":
		body.treatment.status = "RECOVERING"
		_schedule(patient, "recover", g._state.time + RECOVERY_SECONDS, int(body.care_version))
	p._emit(patient, "personal_stabilized", str(action.input_ref), {"helper_ref": action.actor_ref, "mode": action.medical.mode})
	return {"status": body.treatment.status, "changed": changed}

func on_unit_merge(donor: String, survivor: String) -> void:
	var g: RefCounted = _owner.get_ref()
	# At most six bodies; only a current action referencing the retired stock moves.
	for actor: String in g.participants._bodies:
		var body: Dictionary = g.participants._member(actor)
		if body.state != "MEDICATING":
			continue
		var action: Dictionary = g.participants._actions[body.action_ref]
		if action.medical.supply_unit == donor:
			action.medical.supply_unit = survivor
	for pack: Dictionary in carried.values():
		if pack.unit_ref == donor and float(pack.amount) <= 0.000001:
			pack.unit_ref = survivor # Empty current custody; historical source stays unchanged.

func member_moved(actor: String, destination: String) -> void:
	var pack: Dictionary = carried.get(actor, {})
	if not pack.is_empty() and float(pack.amount) <= 0.000001:
		pack.unit_ref = destination
		pack.revision += 1

func _schedule(actor: String, mode: String, due: float, version: int) -> void:
	if _tickets.size() >= MAX_TICKETS:
		return # Capacity limits stop new plans; existing body facts remain.
	_serial += 1
	var id: String = "medical_%d" % _serial
	_tickets[id] = {"actor": actor, "mode": mode, "due": due, "version": version}
	assert(_owner.get_ref()._state.schedule_event(id, due, "gameplay", {"care_id": id}))

func accepts_event(id: String, payload: Dictionary, due: float) -> bool:
	return payload.size() == 1 and payload.get("care_id", "") == id and _tickets.has(id) and _tickets[id].due == due

func process_event(event: Dictionary) -> Dictionary:
	var g: RefCounted = _owner.get_ref()
	var ticket: Dictionary = _tickets[event.id]
	_tickets.erase(event.id)
	var p: RefCounted = g.participants
	var actor: String = str(ticket.actor)
	var body: Dictionary = p._member(actor)
	if p.dead(actor):
		return {"changed": [], "retired": [], "record": {"status": "OBSOLETE"}}
	if ticket.mode == "bleed":
		if not body.get("bleeding", {}).get("active", false) or int(body.bleeding.version) != int(ticket.version):
			return {"changed": [], "retired": [], "record": {"status": "STABILIZED"}}
		var dose: float = float(body.bleeding.rate) * (g._state.time - float(body.bleeding.last_at))
		body.bleeding.last_at = g._state.time
		var result: Dictionary = p.external_damage(actor, dose, str(event.id), "bleeding")
		if not p.dead(actor):
			_schedule(actor, "bleed", g._state.time + BLEED_PERIOD, int(ticket.version))
		result.record = {"kind": "injury_deterioration", "person_ref": actor, "time": g._state.time}
		return result
	if int(body.get("care_version", 0)) != int(ticket.version) or body.get("bleeding", {}).get("active", false):
		return {"changed": [], "retired": [], "record": {"status": "RECOVERY_INTERRUPTED"}}
	var ceiling: float = maxf(0.0, 1.0 - float(body.trauma) * 0.5)
	var amount: float = minf(RECOVERY_AMOUNT, maxf(0.0, ceiling - float(body.health)))
	body.treatment.status = "PARTIALLY_RECOVERED" if amount > 0.000001 else "NO_RESTORABLE_CAPACITY"
	var result: Dictionary = p.recover(actor, amount, str(event.id))
	result.record = {"kind": "partial_recovery", "person_ref": actor, "time": g._state.time}
	return result

static func _reject(reason: String) -> Dictionary:
	return {"ok": false, "error": reason}

const RUNTIME_FIELDS: Array[String] = ["_trained", "_tickets", "carried", "carry_jobs", "_serial"]

func runtime_state() -> Dictionary:
	return preload("res://experiments/war_resolver/battle_state.gd").capture_runtime_fields(self, RUNTIME_FIELDS)

func restore_runtime(image: Dictionary) -> bool:
	return preload("res://experiments/war_resolver/battle_state.gd").restore_runtime_fields(self, image, RUNTIME_FIELDS)

func validate_runtime() -> bool:
	var g: RefCounted = _owner.get_ref()
	var p: RefCounted = g.participants
	if carried.size() > p.MAX_PEOPLE or carry_jobs.size() > p.MAX_PEOPLE:
		return false
	var units: Dictionary = {}
	for actor: String in carried:
		var pack: Dictionary = carried[actor]
		if not p._units.has(actor) or pack.get("id", "") != "medical_carry:" + actor or not g._state.knows_unit(str(pack.get("unit_ref", ""))) or str(pack.get("source_ref", "")).is_empty() or pack.get("status", "") not in ["HELD", "STRANDED"] or not g.tactics._nonnegative(pack.get("amount")) or not g.tactics._nonnegative(pack.get("consumed")) or int(pack.get("revision", -1)) < 0:
			return false
		if pack.status == "HELD" and pack.holder_ref != actor:
			return false
		if pack.status == "HELD" and not g.land.body_mounted(actor) and float(pack.amount) > 0.000001 and (not p._member(actor).actionable or float(pack.amount) > float(p._member(actor).health) * CARRY_CAPACITY + 0.000001):
			return false
		if pack.status == "STRANDED" and (pack.holder_ref != "ground:" + str(pack.id) or not pack.get("spatial") is Dictionary or not g._space.valid_local_spatial(pack.spatial) or not pack.get("xy") is Array or pack.xy.size() != 2):
			return false
		units[pack.unit_ref] = true
	for actor: String in carry_jobs:
		var job: Dictionary = carry_jobs[actor]
		if p._units.get(actor, "") != job.get("actor_unit_ref", "missing") or job.get("actor_ref", "") != actor or job.get("mode", "") not in ["take", "return", "recover"] or not g._state.knows_unit(str(job.get("supply_unit", ""))) or str(job.get("cooperation_ref", "")).is_empty() or int(job.get("source_revision", -1)) < 0 or not g.tactics._positive(job.get("quantity")) or not g.tactics._positive(job.get("requested_quantity")) or float(job.quantity) > float(job.requested_quantity) + 0.000001:
			return false
		var action: Dictionary = p._actions.get(job.get("action_ref", ""), {})
		if action.get("mode", "") != "MEDICAL_HANDLING" or action.get("status", "") != "PENDING" or action.get("medical_carry_ref", "") != job.get("id", "missing") or p._member(actor).action_ref != action.id or float(action.due) != float(job.get("due", -1.0)):
			return false
		units[job.supply_unit] = true
	for unit_id: String in units:
		var unit: Dictionary = g._state.units[unit_id] if g._state.units.has(unit_id) else g._lod.preview_leaf(unit_id)
		if reserved(unit_id) > float(unit.get("medical", 0.0)) + 0.000001:
			return false
	return true
