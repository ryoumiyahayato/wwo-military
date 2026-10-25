extends RefCounted
## Research-side professional boundary. Owns references and export receipts only.
## Formal objects are injected and read; this port never advances their clock.
const SCHEMA: String = "military-host-boundary-v1"
const PAGE: int = 64
const MAX_SECONDS: float = 86400.0
const STOCK_FIELDS: Array[String] = ["ammunition", "fuel", "fuel_spent", "spares", "spares_spent", "medical", "medical_spent", "equipment", "serviceable_equipment", "ammo_spent", "equipment_lost", "casualties", "personnel_recovered"]
var _session: WeakRef
var _formal: WeakRef
var _step: WeakRef
var _binding: Dictionary = {}
var _origin_minute: int = 0
var _origin_seconds: float = 0.0
var _minute: int = 0
var _requested_minute: int = -1
var _sequence: int = 0
var _before: Dictionary = {}
var _before_logistics: Dictionary = {}
var _last_result: Dictionary = {}
var _completed: bool = false
var _solver_call: bool = false

func _env() -> Dictionary:
	return _session.get_ref().world.env

func _host() -> RefCounted:
	return _formal.get_ref() if _formal != null else null

func _clock() -> RefCounted:
	return _host().get("game_clock") if _host() != null else null

func _safe() -> bool:
	return _step != null and _step.get_ref() != null and not bool(_step.get_ref().get("processing"))

func waiting() -> bool:
	return _requested_minute >= 0 or _env().state.settlement_pending

func _seconds(minute: int) -> float:
	# Subtract integers before converting. A late calendar epoch keeps precision.
	return _origin_seconds + float(minute - _origin_minute) * 60.0

func bind(session: RefCounted, formal_world: RefCounted, formal_step: RefCounted, binding: Dictionary) -> Dictionary:
	if _session != null or session.world.env.is_empty() or session.world.env.state.settlement_pending or session.mode != "PAUSED" or session.target >= 0.0:
		return _error("bind_requires_existing_committed_paused_research_world")
	_session = weakref(session)
	_formal = weakref(formal_world) if formal_world != null else null
	_step = weakref(formal_step) if formal_step != null else null
	var valid: Dictionary = _validate_source(binding)
	if not valid.ok:
		return valid
	_binding = binding.duplicate(true)
	_origin_minute = int(_clock().call("total_minutes"))
	_origin_seconds = float(_env().state.time)
	_minute = _origin_minute
	var current: Dictionary = _current_references()
	if not current.ok:
		return current
	_install_hooks()
	return {"ok": true, "status": "REFERENCE_BOUND_CANDIDATE_ONLY", "host_minute": _minute, "research_seconds": _origin_seconds, "formal_installed": false}

func _validate_source(binding: Dictionary) -> Dictionary:
	if _host() == null or _clock() == null or not _clock().has_method("total_minutes") or not _clock().has_method("current_hour") or _step == null or _step.get_ref() == null or _step.get_ref().get("_clock") != _clock() or not _safe():
		return _error("actual_WorldState_GameClock_and_safe_SimulationStep_required")
	if binding.get("mode", "") != "candidate_only" or not binding.get("world_ref") is String or str(binding.world_ref).is_empty() or not binding.get("research_units") is Array or binding.research_units.is_empty() or binding.research_units.size() > 16:
		return _error("explicit_world_reference_scope_and_candidate_only_contract_required")
	for key: String in ["people", "units", "offices", "nodes", "links", "resource_refs", "permissions"]:
		if not binding.get(key, {}) is Dictionary:
			return _error("invalid_reference_table_" + key)
		if binding.get(key, {}).size() > (8 if key in ["people", "permissions"] else 32):
			return _error("finite_reference_capacity_" + key)
	var env: Dictionary = _env()
	if env.information.external_authority_guard.is_valid() and env.information.external_authority_guard != Callable(self, "authorize") or env.decisions.external_intent_guard.is_valid() and env.decisions.external_intent_guard != Callable(self, "authorize_intent") or env.lod.external_time_guard.is_valid() and env.lod.external_time_guard != Callable(self, "authorize_time"):
		return _error("existing_external_boundary_must_not_be_overwritten")
	var seen: Dictionary = {}
	for id: Variant in binding.research_units:
		if not id is String or seen.has(id) or not env.lod.has_leaf(id):
			return _error("existing_unique_research_unit_scope_required")
		seen[id] = true
	var persons: RefCounted = _host().get("person_overlay")
	var population: RefCounted = _host().get("population_state")
	var organization: RefCounted = _host().get("organization_state")
	var catalog: RefCounted = _host().get("spatial_catalog")
	if persons == null or population == null or organization == null or catalog == null or not persons.has_method("person") or not population.has_method("unit_for_person") or not organization.has_method("appointment") or not catalog.has_method("get_place"):
		return _error("existing_population_person_organization_and_spatial_owners_required")
	seen.clear()
	for actor: String in binding.get("people", {}):
		var person: Variant = binding.people[actor]
		if not person is String or not env.structure._people.has(actor) or seen.has(person) or not persons.call("has_person", person) or str(population.call("unit_for_person", person)).is_empty():
			return _error("one_existing_formal_population_claim_per_research_person_required")
		var claim: Dictionary = persons.call("population_claim", person)
		if claim.get("coverage", 0) != 1 or str(claim.get("claim_id", "")).is_empty():
			return _error("named_person_population_reference_missing")
		seen[person] = true
	seen.clear()
	var military: RefCounted = _host().get("military_state")
	for unit: String in binding.get("units", {}):
		var formation: Variant = binding.units[unit]
		if unit not in binding.research_units or not formation is String or seen.has(formation) or military == null or not military.has_method("get_formation") or military.call("get_formation", formation) == null:
			return _error("existing_unique_formal_formation_reference_required")
		seen[formation] = true
	for node: String in binding.get("offices", {}):
		var office: Variant = binding.offices[node]
		if not env.structure._nodes.has(node) or not office is Dictionary or not organization.call("has_organization", str(office.get("organization_ref", ""))) or organization.call("position", str(office.get("organization_ref", "")), str(office.get("position_ref", ""))).is_empty():
			return _error("existing_formal_organization_and_position_required")
	for node: String in binding.get("nodes", {}):
		var place: Variant = binding.nodes[node]
		if not env.space._nodes.has(node) or not place is Dictionary or not str(place.get("place_ref", "")).begins_with("place:") or catalog.call("get_place", str(place.place_ref)).is_empty() or not place.get("research_xy") is Array or place.research_xy != env.space._nodes[node].xy or not place.get("frame_ref") is String or str(place.frame_ref).is_empty() or not place.get("basis_ref") is String or str(place.basis_ref).is_empty():
			return _error("existing_place_explicit_km_anchor_frame_and_basis_required")
	for edge: String in binding.get("links", {}):
		var link: Variant = binding.links[edge]
		var road: Dictionary = env.space._edges.get(edge, {})
		if not link is String or road.is_empty() or not binding.get("nodes", {}).has(road.from) or not binding.nodes.has(road.to):
			return _error("explicit_mapped_existing_road_endpoints_required")
		var actual: Dictionary = catalog.call("get_link", link)
		if actual.is_empty() or actual.get("link_type", "") != "road" or actual.get("from_place_id", "") != binding.nodes[road.from].place_ref or actual.get("to_place_id", "") != binding.nodes[road.to].place_ref:
			return _error("formal_road_link_endpoints_do_not_match_declared_anchors")
		var military_map: RefCounted = _host().get("military_map")
		var metric: Dictionary = military_map.get("links").get(link, {}) if military_map != null else {}
		if not metric.has("distance_km") or not is_finite(float(metric.distance_km)) or absf(float(metric.distance_km) - float(road.length_km)) > 0.000001:
			return _error("formal_and_research_road_metric_lengths_do_not_match")
	var economy: RefCounted = _host().get("economy_r1")
	for resource: String in binding.get("resource_refs", {}):
		if resource not in ["AMMUNITION", "FUEL", "SPARES", "MEDICAL"] or not binding.resource_refs[resource] is String or economy == null or not economy.has_method("personal_commodity") or economy.call("personal_commodity", str(binding.resource_refs[resource])).is_empty():
			return _error("existing_native_commodity_reference_required_no_quantity_conversion")
	for actor: String in binding.get("permissions", {}):
		var permission: Variant = binding.permissions[actor]
		if not binding.get("people", {}).has(actor) or not permission is Dictionary or not permission.get("commands") is Dictionary or permission.commands.size() > 16 or not permission.get("context") is Dictionary or binding.get("authorization_time_unit", "") != "hour":
			return _error("explicit_actor_capability_context_and_hour_contract_required")
		var context: Dictionary = permission.context
		if context.size() != 8 or context.get("person_id", "") != binding.people[actor]:
			return _error("formal_acting_context_identity_mismatch")
		for key: String in ["person_id", "acting_organization_id", "appointment_id", "membership_basis", "represented_organization_id", "authority_basis", "decision_id", "delegation_id"]:
			if not context.has(key):
				return _error("formal_acting_context_field_missing")
		for kind: String in permission.commands:
			if not permission.commands[kind] is String or str(permission.commands[kind]).is_empty():
				return _error("formal_operation_reference_required")
	return {"ok": true}

func _install_hooks() -> void:
	_env().information.external_authority_guard = Callable(self, "authorize")
	_env().decisions.external_intent_guard = Callable(self, "authorize_intent")
	_env().lod.external_time_guard = Callable(self, "authorize_time")

func detach_hooks() -> void:
	if _session == null or _session.get_ref() == null:
		return
	var env: Dictionary = _env()
	if env.information.external_authority_guard == Callable(self, "authorize"):
		env.information.external_authority_guard = Callable()
	if env.decisions.external_intent_guard == Callable(self, "authorize_intent"):
		env.decisions.external_intent_guard = Callable()
	if env.lod.external_time_guard == Callable(self, "authorize_time"):
		env.lod.external_time_guard = Callable()

func authorize_time(seconds: float) -> Dictionary:
	return {"ok": true} if _solver_call and _requested_minute >= 0 and _clock() != null and int(_clock().call("total_minutes")) == _requested_minute and absf(seconds - _seconds(_requested_minute)) <= 0.000001 else _error("military_cursor_owned_by_external_clock_boundary")

func authorize_intent(_actor: String, intent: Dictionary) -> Dictionary:
	if intent.get("kind", "") in ["keep", "command", "local_action", "report_forward"]:
		return {"ok": true} # Command/action authorization runs on the original Information port.
	return _error("formal_structure_and_resource_proposal_mapping_not_installed")

func authorize(actor: String, command: Dictionary, _phase: String) -> Dictionary:
	if _host() == null or not _binding.get("people", {}).has(actor):
		return _error("unmapped_research_actor_has_no_formal_command_identity")
	var env: Dictionary = _env()
	var permission: Dictionary = _binding.get("permissions", {}).get(actor, {})
	var operation: String = str(permission.get("commands", {}).get(str(command.get("kind", "")), ""))
	var context: Dictionary = permission.get("context", {})
	if operation.is_empty() or context.is_empty():
		return _error("formal_capability_translation_missing")
	var person: String = str(_binding.people[actor])
	var persons: RefCounted = _host().get("person_overlay")
	var organization: RefCounted = _host().get("organization_state")
	var auth: RefCounted = _host().get("authorization_check")
	var office: Dictionary = env.structure.command_person(actor)
	var mapped: Dictionary = _binding.get("offices", {}).get(str(office.get("formation_id", "")), {})
	if auth == null or not auth.has_method("resolve_authority") or not persons.call("is_alive", person) or mapped.is_empty() or context.get("acting_organization_id", "") != mapped.organization_ref or not organization.call("is_organization_active", str(mapped.organization_ref)):
		return _error("current_formal_person_organization_or_position_unavailable")
	var appointment: Dictionary = organization.call("appointment", str(mapped.organization_ref), str(context.get("appointment_id", "")))
	if appointment.get("person_id", "") != person or appointment.get("position_id", "") != mapped.position_ref:
		return _error("current_formal_appointment_no_longer_matches_executor")
	# Formal appointments have no subminute history port. Never invent one or round delivery.
	var host_minute: int = int(_clock().call("total_minutes"))
	if absf(float(env.state.time) - _seconds(host_minute)) > 0.000001:
		return _error("formal_delivered_time_authority_history_not_available_for_this_second")
	var target: String = str(command.get("target", ""))
	var formal_target: String = str(_binding.get("units", {}).get(target, ""))
	var target_unit: String = str(env.structure._nodes.get(target, {}).get("unit_id", ""))
	if not target_unit.is_empty() and _binding.get("units", {}).has(target_unit):
		formal_target = str(_binding.units[target_unit])
	if formal_target.is_empty() and _binding.get("offices", {}).has(target):
		formal_target = str(_binding.offices[target].organization_ref)
	if target == actor:
		formal_target = person
	if formal_target.is_empty():
		return _error("formal_command_target_reference_missing")
	var values: Dictionary = command.get("values", {})
	var place: String = ""
	var node: String = str(values.get("target_node", values.get("destination_node", "")))
	if not node.is_empty():
		if not _binding.get("nodes", {}).has(node):
			return _error("formal_command_place_reference_missing")
		place = str(_binding.nodes[node].place_ref)
	if values.has("quantity"):
		return _error("formal_quantity_authorization_conversion_not_defined")
	for key: String in ["rescue_order", "medical_order", "passenger_order"]:
		if values.get(key, {}).has("quantity"):
			return _error("formal_quantity_authorization_conversion_not_defined")
	var result: Dictionary = auth.call("resolve_authority", context.duplicate(true), operation, "domain_execution", formal_target, place, person, 0.0, int(_clock().call("current_hour")), "")
	return {"ok": true} if result.get("status", "") == "ALLOWED" else {"ok": false, "error": "formal_permission_denied", "formal_reason": result.get("reason", "ERROR")}

func advance_to(host_minute: int, quota: int = 31) -> Dictionary:
	if _host() == null or host_minute < _minute or int(_clock().call("total_minutes")) != host_minute or quota < 1 or quota > 8192:
		return _error("external_target_must_be_the_actual_formal_clock_with_bounded_quota")
	var references: Dictionary = _current_references()
	if not references.ok:
		return references
	if _requested_minute >= 0 and host_minute != _requested_minute:
		return _error("finish_original_external_boundary_without_restarting")
	var seconds: float = _seconds(host_minute)
	if not is_finite(seconds) or seconds < float(_env().state.time) or seconds > MAX_SECONDS:
		return _error("target_outside_existing_research_time_scope")
	if _requested_minute < 0:
		if host_minute == _minute and _env().state.next_event_time() > seconds and not _last_result.is_empty():
			return {"ok": true, "status": "COMPLETE", "duplicate": true, "result": _last_result.duplicate(true)}
		_requested_minute = host_minute
		_before = _env().state.totals.duplicate(true)
		_before_logistics = _env().state.logistics_ledger.duplicate(true)
		_completed = false
	if not _completed:
		_solver_call = true
		var result: Dictionary = _env().lod.advance_bounded(seconds, quota)
		_solver_call = false
		if not result.get("ok", false):
			return {"ok": false, "status": "BLOCKED", "error": result.get("error", "military_boundary_blocked"), "committed_host_minute": _minute, "requested_host_minute": _requested_minute}
		if result.status != "COMPLETE":
			return status()
		_completed = true
	if not _safe() or int(_clock().call("total_minutes")) != _requested_minute:
		return status()
	var from: int = _minute
	_minute = _requested_minute
	_requested_minute = -1
	_sequence += 1
	_last_result = professional_state()
	_last_result.receipt_ref = str(_binding.world_ref) + ":military-boundary:%d" % _sequence
	_last_result.from_host_minute = from
	_last_result.host_minute = _minute
	_last_result.research_capacity_delta = {}
	for key: String in _env().state.totals:
		_last_result.research_capacity_delta[key] = float(_env().state.totals[key]) - float(_before.get(key, 0.0))
	_last_result.resource_effects = {"receipt_ref": _last_result.receipt_ref, "source_authority": "RESEARCH_TASK6", "quantity_basis": "SYNTHETIC_FLOAT", "resource_refs": _binding.get("resource_refs", {}).duplicate(true), "ammunition_spent": _last_result.research_capacity_delta.get("ammo_spent", 0.0), "formal_adoption": "UNSUPPORTED", "cargo_lost": {}}
	for key: String in ["fuel_spent", "spares_spent", "medical_spent", "wear_damage", "repair_restored"]:
		if _env().state.logistics_ledger.has(key):
			_last_result.resource_effects[key] = float(_env().state.logistics_ledger[key]) - float(_before_logistics.get(key, 0.0))
	for resource: String in _env().state.logistics_ledger.get("cargo_lost", {}):
		_last_result.resource_effects.cargo_lost[resource] = float(_env().state.logistics_ledger.cargo_lost[resource]) - float(_before_logistics.get("cargo_lost", {}).get(resource, 0.0))
	_last_result.formal_adoption = "NOT_IMPLEMENTED"
	_before.clear()
	_before_logistics.clear()
	_session.get_ref().target = -1.0
	_session.get_ref()._harvest()
	_session.get_ref()._refresh()
	return {"ok": true, "status": "COMPLETE", "result": _last_result.duplicate(true)}

func resume(quota: int = 31) -> Dictionary:
	return advance_to(_requested_minute, quota) if _requested_minute >= 0 else _error("no_external_boundary_to_resume")

func status() -> Dictionary:
	return {"ok": true, "status": "AWAITING_FORMAL_SAFE_BOUNDARY" if _completed and _requested_minute >= 0 else "PENDING" if waiting() else "READY", "committed_host_minute": _minute, "requested_host_minute": _requested_minute, "formal_installed": false, "publication": "PROFESSIONAL_CANDIDATE_ONLY"}

func input_boundary() -> Dictionary:
	if waiting() or not _safe() or _clock() == null or int(_clock().call("total_minutes")) != _minute or absf(float(_env().state.time) - _seconds(_minute)) > 0.000001:
		return _error("input_requires_aligned_complete_external_boundary")
	return _current_references()

func _current_references() -> Dictionary:
	var persons: RefCounted = _host().get("person_overlay")
	for actor: String in _binding.get("people", {}):
		var person: String = str(_binding.people[actor])
		if not persons.call("has_person", person):
			return _error("formal_person_reference_removed_requires_host_reconciliation")
		if _env().gameplay.participants._units.has(actor) and not _env().gameplay.participants.dead(actor) and not persons.call("is_alive", person):
			return _error("formal_death_requires_explicit_body_lifecycle_import_not_free_research_activity")
	var military: RefCounted = _host().get("military_state")
	for formation: String in _binding.get("units", {}).values():
		if military == null or military.call("get_formation", formation) == null:
			return _error("formal_formation_reference_removed_requires_host_reconciliation")
	return {"ok": true}

func has_person(actor: String) -> bool:
	return _binding.get("people", {}).has(actor)

func world_reference() -> String:
	return str(_binding.world_ref)

func update_authority(offices: Dictionary, permissions: Dictionary) -> Dictionary:
	var ready: Dictionary = input_boundary()
	if not ready.ok:
		return ready
	var next: Dictionary = _binding.duplicate(true)
	next.offices = offices.duplicate(true)
	next.permissions = permissions.duplicate(true)
	var valid: Dictionary = _validate_source(next)
	if not valid.ok:
		return valid
	_binding = next # Existing orders/messages keep their IDs and historical issuers.
	return {"ok": true, "status": "CURRENT_AUTHORITY_REFERENCES_UPDATED", "formal_installed": false}

func _records(records: Dictionary) -> Dictionary:
	var rows: Dictionary = {}
	for id: String in records:
		if rows.size() >= PAGE:
			break
		var value: Variant = records[id]
		if value is Dictionary or value is Array:
			rows[id] = value.duplicate(true)
		else:
			rows[id] = {"mapping": "UNSUPPORTED_LIVE_REFERENCE"} if value is Object else value
	return {"records": rows, "total": records.size(), "complete": rows.size() == records.size()}

func _position(spatial: Dictionary, xy: Array) -> Dictionary:
	var node: String = str(spatial.get("node", ""))
	var anchor: Dictionary = _binding.get("nodes", {}).get(node, {})
	return {"research_spatial": spatial.duplicate(true), "xy_km": xy.duplicate(), "formal_anchor": anchor.duplicate(true), "mapping": "DECLARED_LOCAL_METRIC_ANCHOR" if not anchor.is_empty() else "RESEARCH_ONLY", "formal_link_ref": _binding.get("links", {}).get(str(spatial.get("edge", "")), ""), "global_coordinate_projection": "NOT_IMPLEMENTED"}

func professional_state() -> Dictionary:
	var ready: Dictionary = input_boundary()
	if not ready.ok:
		return ready
	var env: Dictionary = _env()
	var units: Dictionary = {}
	var tasks: Dictionary = {}
	for id: String in _binding.research_units:
		var unit: Dictionary = env.lod.preview_leaf(id)
		var stock: Dictionary = {}
		for key: String in STOCK_FIELDS:
			if unit.has(key):
				stock[key] = unit[key]
		var position: Dictionary = _position(unit.spatial, env.space.xy(unit)) if unit.get("spatial") is Dictionary else {"mapping": "UNSUPPORTED_NO_RESEARCH_SPATIAL_FACTS"}
		units[id] = {"research_ref": id, "formal_formation_ref": _binding.get("units", {}).get(id, ""), "effective_capacity": unit.effective, "position": position, "research_stock": stock, "mission_ref": unit.mission_id, "body_members": unit.get("gameplay_personnel", {}).get("members", {}).keys(), "execution_ownership": "RESEARCH_CANDIDATE_ONLY"}
		if env.gameplay.tactics.manoeuvre_active(id):
			units[id].parts = env.gameplay.tactics.manoeuvres[id].duplicate(true)
		tasks[unit.mission_id] = env.state.missions[unit.mission_id].duplicate(true)
	var people: Dictionary = {}
	var person_ids: Dictionary = {}
	for actor: String in _binding.get("people", {}):
		person_ids[actor] = true
	for actor: String in env.gameplay.participants._units:
		var body: Dictionary = env.gameplay.participants._member(actor)
		var vehicle: Dictionary = env.gameplay.land.body_ride(actor)
		if env.gameplay.participants._units[actor] in _binding.research_units or vehicle.get("carrier_ref", "") in _binding.research_units or env.gameplay.participants._units.get(str(body.get("carrier_ref", "")), "") in _binding.research_units:
			person_ids[actor] = true
	for actor: String in person_ids:
		var formal_person: String = str(_binding.get("people", {}).get(actor, ""))
		var person: Dictionary = {"research_person_ref": actor, "formal_person_ref": formal_person, "identity_mapping": "EXISTING_NAMED_REFERENCE" if not formal_person.is_empty() else "RESEARCH_ONLY", "research_office": env.structure.command_person(actor), "body_mapping": "NO_BODY_IN_RESEARCH"}
		if not formal_person.is_empty():
			person.population_claim = _host().get("person_overlay").call("population_claim", formal_person)
			person.formal_alive = _host().get("person_overlay").call("is_alive", formal_person)
			person.formal_office_reference = _binding.get("offices", {}).get(str(person.research_office.get("formation_id", "")), {}).duplicate(true)
			var context: Dictionary = _binding.get("permissions", {}).get(actor, {}).get("context", {})
			person.formal_appointment = _host().get("organization_state").call("appointment", str(context.get("acting_organization_id", "")), str(context.get("appointment_id", ""))) if not context.is_empty() else {}
		if env.gameplay.participants._units.has(actor):
			var p: RefCounted = env.gameplay.participants
			person.body_mapping = "EXISTING_BODY_REFERENCE_ONLY"
			person.body = p._member(actor).duplicate(true)
			person.position = _position(p.body_spatial(actor), p.position(actor))
			person.knowledge = env.information.knowledge(actor).duplicate(true)
		people[actor] = person
	var communication: Dictionary = {}
	for actor: String in _binding.get("people", {}):
		var inbox: Array = env.information._inboxes.get(actor, [])
		var outbox: Array = env.information._outboxes.get(actor, [])
		var messages: Dictionary = {}
		for ids: Array in [inbox.slice(maxi(0, inbox.size() - PAGE)), outbox.slice(maxi(0, outbox.size() - PAGE))]:
			for id: String in ids:
				if env.information._messages.has(id):
					messages[id] = env.information._messages[id].duplicate(true)
		communication[actor] = {"messages": messages, "inbox_total": inbox.size(), "outbox_total": outbox.size(), "history_complete": inbox.size() <= PAGE and outbox.size() <= PAGE}
	var g: RefCounted = env.gameplay
	var responsibilities: Dictionary = {"body_actions": _records(g.participants._actions), "patient_relays": _records(g.participants.patient_relays), "local_rescues": _records(g.participants.local_rescues), "passenger_rides": _records(g.land.passenger_rides), "patient_vehicle_jobs": _records(g.land.patient_jobs), "passenger_trips": _records(g.land.passenger_trips), "land_jobs": _records(g.land.jobs), "sea_deliveries": _records(env.logistics._deliveries), "ammunition_custody": _records(g.tactics.ammunition_custody), "ammunition_jobs": _records(g.tactics.supply_jobs), "medical_custody": _records(g.medical.carried), "medical_jobs": _records(g.medical.carry_jobs), "weapons": _records(g.tactics.weapons), "gun_crews": _records(g.tactics.guns), "operations": _records(g.operations._records), "engineering": _records(g.operations._work_units)}
	responsibilities.air_assets = _records(g.air.assets)
	responsibilities.air_missions = _records(g.air.missions)
	responsibilities.sea_vessels = _records(g.sea.vessels)
	responsibilities.sea_missions = _records(g.sea.missions)
	responsibilities.sea_transport = _records(g.sea.freight.transports)
	responsibilities.sea_transshipments = _records(g.sea.freight.transfers)
	responsibilities.medical_events = _records(g.medical._tickets)
	responsibilities.task6_depots = _records(env.logistics._depots)
	var focus: String = str(g.focused_person)
	responsibilities.control_focus = {"research_person_ref": focus, "formal_person_ref": _binding.get("people", {}).get(focus, ""), "formal_player_state_mutated": false}
	return {"ok": true, "kind": "MILITARY_PROFESSIONAL_AUTHORITY_COPY", "world_ref": _binding.world_ref, "time_axis": {"host_origin_minute": _origin_minute, "research_origin_seconds": _origin_seconds, "seconds_per_minute": 60, "event_times": "RESEARCH_SECONDS"}, "host_minute": _minute, "research_seconds": env.state.time, "units": units, "people": people, "tasks": tasks, "communication": communication, "responsibilities": responsibilities, "future_events": env.state.events.slice(0, mini(PAGE, env.state.events.size())).duplicate(true), "future_event_total": env.state.events.size(), "future_events_complete": env.state.events.size() <= PAGE, "research_totals": env.state.totals.duplicate(), "task6_reservations": _records(env.logistics._reserved), "task6_asset_stock": _records(env.logistics._assets), "task6_requests": _records(env.logistics._requests), "resource_refs": _binding.get("resource_refs", {}).duplicate(true), "formal_resource_transfer": "UNSUPPORTED", "population_conversion": "UNDECIDED", "formal_installed": false}

func result() -> Dictionary:
	var ready: Dictionary = input_boundary()
	if not ready.ok:
		return ready
	return _last_result.duplicate(true) if not _last_result.is_empty() else _error("no_completed_external_interval_result")

func runtime_binding() -> Dictionary:
	var ready: Dictionary = input_boundary()
	if not ready.ok:
		return ready
	return {"ok": true, "schema": SCHEMA, "binding": _binding.duplicate(true), "origin_host_minute": _origin_minute, "origin_research_seconds": _origin_seconds, "host_minute": _minute, "sequence": _sequence, "last_result": _last_result.duplicate(true)}

func restore_binding(session: RefCounted, formal_world: RefCounted, formal_step: RefCounted, image: Dictionary) -> Dictionary:
	if image.get("schema", "") != SCHEMA or not image.get("binding") is Dictionary or not image.get("origin_host_minute") is int or not image.get("host_minute") is int or not image.get("sequence") is int or not image.get("last_result") is Dictionary or not (image.get("origin_research_seconds") is int or image.get("origin_research_seconds") is float):
		return _error("invalid_external_boundary_checkpoint")
	_session = weakref(session)
	_formal = weakref(formal_world) if formal_world != null else null
	_step = weakref(formal_step) if formal_step != null else null
	var valid: Dictionary = _validate_source(image.binding)
	if not valid.ok:
		return valid
	_binding = image.binding.duplicate(true)
	_origin_minute = image.origin_host_minute
	_origin_seconds = float(image.origin_research_seconds)
	_minute = image.host_minute
	_sequence = image.sequence
	if _origin_minute < 0 or _minute < _origin_minute or _sequence < 0 or not is_finite(_origin_seconds) or _origin_seconds < 0.0 or _seconds(_minute) > MAX_SECONDS or absf(float(_env().state.time) - _seconds(_minute)) > 0.000001 or int(_clock().call("total_minutes")) != _minute:
		return _error("formal_and_research_candidate_time_origins_do_not_match")
	_last_result = image.last_result.duplicate(true)
	if not _last_result.is_empty() and (_last_result.get("host_minute", -1) != _minute or _last_result.get("receipt_ref", "") != str(_binding.world_ref) + ":military-boundary:%d" % _sequence):
		return _error("external_result_receipt_mismatch")
	var current: Dictionary = _current_references()
	if not current.ok:
		return current
	_install_hooks()
	return {"ok": true}

func install_session(session: RefCounted) -> void:
	_session = weakref(session) # Installation changes the owner, never replays domain work.

func _formal_world() -> RefCounted:
	return _host()

func _formal_step() -> RefCounted:
	return _step.get_ref() if _step != null else null

static func _error(reason: String) -> Dictionary:
	return {"ok": false, "error": reason, "formal_installed": false}
