extends SceneTree
## Independent reference is the original synchronous call over identical inputs.
const F = preload("res://experiments/war_resolver/aggregation/fixtures.gd")
const Scenario = preload("res://experiments/war_resolver/continuity/scenario.gd")
var checks: int = 0
var failures: int = 0
var evidence: Dictionary = {}

func _initialize() -> void:
	var cases: Array[String] = ["equivalence", "pending", "same_time", "combined", "mixed_events", "varying", "public_ports"]
	var selected: String = ""
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--case="):
			selected = argument.trim_prefix("--case=")
			if selected.is_empty() or not selected in cases:
				push_error("Unknown continuous case: " + selected)
				quit(2)
				return
	var owner: F.Authority = F.Authority.new()
	owner.configure(F.battle(4))
	check(owner.has_method("advance_bounded"), "bounded continuation API exists")
	if owner.has_method("advance_bounded"):
		for name: String in cases:
			if selected.is_empty() or selected == name:
				call("_" + name)
	print("CONTINUOUS_EVIDENCE_JSON=" + JSON.stringify(evidence))
	print("Task9 continuous: %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("FAIL " + label)

func physical(state: F.State) -> Dictionary:
	var result: Dictionary = state.snapshot()
	result.erase("counters")
	return result

func run(owner: F.Authority, target: float, quota: int, call_limit: int = 1000000) -> Dictionary:
	var calls: int = 0
	var max_units: int = 0
	var max_usec: int = 0
	var result: Dictionary = {}
	var exit_reason: String = "CALL_LIMIT"
	while calls < call_limit:
		var start: int = Time.get_ticks_usec()
		result = owner.advance_bounded(target, quota)
		max_usec = maxi(max_usec, Time.get_ticks_usec()-start)
		calls += 1
		if not result.get("ok", false):
			exit_reason = "ADVANCE_ERROR"
			break
		max_units = maxi(max_units, int(result.work_units))
		if int(result.work_units) > quota:
			exit_reason = "QUOTA_EXCEEDED"
			break
		if result.status == "COMPLETE":
			exit_reason = "COMPLETE"
			break
		if result.status != "PENDING" or int(result.work_units) <= 0:
			exit_reason = "UNEXPECTED_STATUS_OR_NO_WORK"
			break
	return {"result": result, "calls": calls, "call_limit": call_limit, "exit_reason": exit_reason, "max_units": max_units, "max_call_usec": max_usec}

func _equivalence_work_budget(count: int, segments: int) -> int:
	# This fixture has one homogeneous scope, no external events, and no
	# arrival/ammo cut in 120 seconds. N=40, balanced sides; P=N*N/2 contacts.
	var levels: int = ceili(log(float(count)) / log(2.0))
	# Merge copies N*levels plus at most 2*N merge-pair transitions.
	var sort_steps: int = count * levels + 2 * count
	# Two binary searches and phase transitions, gather, then stable-ID sort.
	var query_steps: int = 2 * (levels + 1) + 3 + count + sort_steps
	var pairs: int = count * count / 2
	# Candidate visits; five contact passes (weight/fire/incoming/diagnostic/
	# old-contact release); index sort; 27 other applicable phase paths, each
	# at most N+2 records/transitions in AdvanceWork/SegmentWork for this input.
	var per_segment: int = count * query_steps + count * (count + 1)
	per_segment += 5 * (pairs + count + 1) + sort_steps + 27 * (count + 2)
	# One extra boundary covers initial commit and final plan cleanup.
	return (segments + 1) * per_segment


func _first_difference(left: Variant, right: Variant, path: String) -> Dictionary:
	if left == right:
		return {}
	if left is Dictionary and right is Dictionary:
		for key: String in F.State.sorted_ids(left):
			if not right.has(key):
				return {"field": path + "." + key, "reason": "missing_actual_field"}
			var child: Dictionary = _first_difference(left[key], right[key], path + "." + key)
			if not child.is_empty():
				return child
		for key: String in F.State.sorted_ids(right):
			if not left.has(key):
				return {"field": path + "." + key, "reason": "extra_actual_field"}
	if left is Array and right is Array:
		for index: int in range(mini(left.size(), right.size())):
			var child: Dictionary = _first_difference(left[index], right[index], path + "[%d]" % index)
			if not child.is_empty():
				return child
		return {"field": path + ".size", "expected": left.size(), "actual": right.size()}
	return {"field": path, "expected": left, "actual": right}


func _equivalence() -> void:
	var normal: F.State = F.battle(40)
	var reference: F.Authority = F.Authority.new()
	reference.configure(normal)
	var synchronous: Dictionary = reference.advance(120.0)
	var reference_complete: bool = synchronous.get("ok", false) and normal.time == 120.0 and not normal.public_pending()
	check(reference_complete, "synchronous reference completes requested time")
	if not reference_complete:
		evidence.short_equivalence = {"comparison": "NOT_RUN", "reason": "reference_incomplete"}
		return
	var expected: Dictionary = physical(normal)
	var reference_events: Array = synchronous.events
	# Fix this input envelope explicitly; never derive a larger cap by retrying.
	check(normal.counters.segments == 120 and normal.counters.events_processed == 0, "equivalence fixture stays within one-second work envelope")
	var work_budget: int = _equivalence_work_budget(40, 120)
	var values: Array[Dictionary] = []
	var phase_counts: Dictionary = {}
	for quota: int in [1, 7, 31]:
		var state: F.State = F.battle(40)
		var owner: F.Authority = F.Authority.new()
		owner.configure(state)
		var observed_events: Array[Dictionary] = []
		owner.physical_event_sink = func(event: Dictionary) -> void: observed_events.append(event.duplicate(true))
		var call_budget: int = ceili(float(work_budget) / float(quota))
		var initial: Dictionary = run(owner, 120.0, quota, mini(1000000, call_budget))
		var measured: Dictionary = initial.duplicate(true)
		var row: Dictionary = {"quota": quota, "work_budget": work_budget, "initial": initial, "comparison": "NOT_RUN"}
		if initial.exit_reason == "CALL_LIMIT" and initial.result.get("status") == "PENDING":
			# Preserve the old failure point before one finite continuation on this
			# exact owner/target/quota. No snapshot of partial physical facts.
			row.initial_view = state.snapshot()
			print("CONTINUOUS_CASE_RESULT=" + JSON.stringify({"stage": "original_limit", "quota": quota, "measurement": initial, "comparison": "NOT_RUN", "view": row.initial_view}))
			var remaining: int = call_budget - int(initial.calls)
			if initial.result.get("ok", false) and float(initial.result.committed_time) > 0.0 and remaining > 0:
				var continued: Dictionary = run(owner, 120.0, quota, remaining)
				row.continuation = continued
				measured = continued.duplicate(true)
				measured.calls += int(initial.calls)
				measured.max_units = maxi(int(initial.max_units), int(continued.max_units))
				measured.max_call_usec = maxi(int(initial.max_call_usec), int(continued.max_call_usec))
				measured.call_limit = call_budget
		var complete: bool = measured.exit_reason == "COMPLETE" and measured.result.get("ok", false) and measured.result.get("status") == "COMPLETE" and state.time == 120.0 and measured.result.get("requested_time") == 120.0 and measured.result.get("committed_time") == 120.0 and measured.result.get("pending_boundary") == -1.0 and measured.result.get("commit_count") == 121 and not state.public_pending()
		check(complete, "quota completes same requested time")
		check(measured.max_units <= quota and measured.calls > 1 and measured.calls <= call_budget and int(measured.result.get("total_work_units", work_budget + 1)) <= work_budget, "actual primitive allowance and finite work budget respected")
		row.measurement = measured
		if complete:
			var actual: Dictionary = physical(state)
			var same_physics: bool = expected == actual
			var same_events: bool = reference_events == observed_events
			check(same_physics, "quota does not alter physics, order or keyed draws")
			check(same_events, "completed physical event sequence matches synchronous reference")
			check(expected.totals == actual.totals and expected.random_state == actual.random_state, "completed resource totals and random state remain exact")
			row.comparison = "PASSED" if same_physics and same_events else "FAILED"
			row.event_count = observed_events.size()
			if not same_physics or not same_events:
				print("CONTINUOUS_FIRST_DIFFERENCE=" + JSON.stringify({"physical": _first_difference(expected, actual, "state"), "event": _first_difference(reference_events, observed_events, "events")}))
			var current_counts: Dictionary = measured.result.phase_work_counts
			if phase_counts.is_empty():
				phase_counts = current_counts.duplicate()
			check(phase_counts == current_counts, "quota and continuation do not repeat cursor phases")
		else:
			row.comparison_reason = "bounded_target_incomplete"
		print("CONTINUOUS_CASE_RESULT=" + JSON.stringify(row))
		values.append(row)
	evidence.short_equivalence = values


func _pending() -> void:
	var state: F.State = F.battle(40)
	var owner: F.Authority = F.Authority.new()
	owner.configure(state)
	check(not owner.advance_bounded(30.0, 0).ok and not owner.advance_bounded(NAN, 1).ok and not owner.advance_bounded(-1.0, 1).ok, "invalid budget/time is atomic")
	var first: Dictionary = owner.advance_bounded(30.0, 1)
	check(first.ok and first.status == "PENDING" and first.committed_time == 0.0 and state.time == 0.0, "first yield exposes old committed timestamp")
	var before: Dictionary = state.counters.duplicate()
	check(state.snapshot().get("status") == "PENDING" and owner.macro_summary().get("status") == "PENDING" and owner.snapshot().get("status") == "PENDING", "public query cannot read partial physical state")
	check(before == state.counters, "pending reads never settle")
	check(not owner.advance(30.0).ok and not owner.zoom_in("field").ok, "synchronous settlement and representation change cannot race pending work")
	check(not owner.advance_bounded(31.0, 1).ok, "request cannot change target during unfinished causal work")
	check(run(owner, 30.0, 7).result.status == "COMPLETE" and state.time == 30.0, "resume retains original target")

func _same_time() -> void:
	var pair: Array[Dictionary] = []
	for index: int in range(2):
		var state: F.State = F.battle(4)
		var owner: F.Authority = F.Authority.new()
		owner.configure(state)
		var admitted: bool = true
		for event: int in range(1000):
			admitted = state.schedule_event("same_%04d" % event, 10.0, "area_change", {"area_id": "field", "cover": 0.1 if event % 2 == 0 else 0.9}) and admitted
		check(admitted, "thousand same-time input fixture")
		pair.append({"state": state, "owner": owner})
	pair[0].owner.advance(30.0)
	var measured: Dictionary = run(pair[1].owner, 30.0, 7)
	check(measured.result.get("ok", false) and measured.result.status == "COMPLETE", "same-time batches complete")
	check(pair[1].state.counters.events_processed == 1000 and pair[1].state.events.is_empty() and pair[1].state.areas.field.cover == 0.9, "all same-time events preserve original ID order")
	check(physical(pair[0].state) == physical(pair[1].state), "same-time batching cannot shift physical timestamps")
	evidence.same_time = measured

func _combined() -> void:
	var reference: Scenario = Scenario.new()
	check(reference.configure(), "normal combined reference")
	reference.advance(1800.0)
	var observations: Array[Dictionary] = []
	for quota: int in [1, 7, 31]:
		var scenario: Scenario = Scenario.new()
		check(scenario.configure(), "budgeted combined reference")
		var measured: Dictionary = run(scenario.env.lod, 1800.0, quota)
		check(measured.result.get("ok", false) and measured.result.status == "COMPLETE", "combined quota completes")
		check(reference.physical() == scenario.physical() and scenario.ledger_balanced(), "combined route/report/command/stock physics unchanged by quota")
		check(reference.env.information._knowledge == scenario.env.information._knowledge and reference.env.information._messages == scenario.env.information._messages, "quota keeps exact knowledge and command timestamps")
		check(reference.env.decisions.snapshot() == scenario.env.decisions.snapshot(), "same opportunities/provider results despite yields")
		observations.append({"quota": quota, "measurement": measured})
	evidence.combined = observations

func _mixed_fixture() -> Scenario:
	var scenario: Scenario = Scenario.new()
	check(scenario.configure(71, {"repeated": false, "keep_only": true, "bridge_cut": false, "command_latency": 10.0}), "mixed initial scenario")
	var env: Dictionary = scenario.env
	check(env.structure.submit("company", {"id": "mixed_attachment", "kind": "attach", "effective_time": 10.0, "values": {"target": "node_unit_000", "parent": "blue_destination", "until": 20.0}}).ok, "mixed Task5 event")
	check(env.logistics.submit("company", {"id": "mixed_request", "kind": "request", "target_kind": "formation", "target": "blue_platoon", "resource_class": "AMMUNITION", "quantity": 1.0}).ok and env.logistics.submit("company", {"id": "mixed_delivery", "kind": "allocate", "request_id": "mixed_request", "source_ref": "source", "delivery_time": 10.0}).ok, "mixed finite Task6 event")
	check(env.decisions.schedule("company", "mixed_decision", 10.0).ok, "mixed registered Task8 event")
	check(env.information.issue_command("squad", {"id": "mixed_command", "channel_ref": "command", "command": {"id": "mixed_command", "kind": "tactical_intent", "target": "node_unit_000", "values": {"posture": "hold"}}}).ok, "mixed delayed Task7 event")
	var admitted: bool = true
	for index: int in range(498):
		admitted = env.space.schedule_fact("mixed_space_%04d" % index, 10.0, "bridge_BD", index % 2 == 0).ok and admitted
		admitted = env.state.schedule_event("mixed_area_%04d" % index, 10.0, "area_change", {"area_id": "cell_037", "cover": 0.1 if index % 2 == 0 else 0.9}) and admitted
	check(admitted, "498+498 mixed external facts admitted")
	return scenario

func _mixed_events() -> void:
	var normal: Scenario = _mixed_fixture()
	var bounded: Scenario = _mixed_fixture()
	normal.advance(30.0)
	var measured: Dictionary = run(bounded.env.lod, 30.0, 7)
	check(measured.result.get("ok", false) and measured.result.status == "COMPLETE", "mixed thousand batch completes")
	check(normal.physical() == bounded.physical() and bounded.ledger_balanced(), "mixed structure/supply/command/decision/space exact physical equivalence")
	var actual: Array[String] = []
	var cursor: int = 0
	while cursor >= 0:
		var page: Dictionary = bounded.env.lod.continuation_ticket_page(cursor, 256)
		for event: Dictionary in page.entries:
			if event.time == 10.0:
				actual.append(event.id)
		cursor = page.next
	var expected: Array[String] = ["structure_mixed_attachment", "logistics_delivery_mixed_delivery", "decision_mixed_decision", "communication_mixed_command"]
	for index: int in range(498):
		expected.append("mixed_area_%04d" % index)
	for index: int in range(498):
		expected.append("spatial_mixed_space_%04d" % index)
	check(actual == expected and actual.size() == 1000, "original phase1/2/5/6/9 and ID order without timestamp drift")
	check(bounded.env.information._messages.mixed_command.processed_at == 10.0 and bounded.env.logistics._deliveries.mixed_delivery.receipt_time == 10.0, "mixed domain effects still use exact original world time")
	evidence.mixed_same_time = {"measurement": measured, "count_at_ten": actual.size(), "phase_order": [1, 2, 5, 6, 9]}

func _varying() -> void:
	var expected: F.State = F.battle(40)
	var reference: F.Authority = F.Authority.new()
	reference.configure(expected)
	reference.advance(120.0)
	var actual: F.State = F.battle(40)
	var owner: F.Authority = F.Authority.new()
	owner.configure(actual)
	var result: Dictionary = {}
	var quotas: Array[int] = [1, 64, 3, 17, 2, 9]
	var calls: int = 0
	while calls < 200000:
		var quota: int = quotas[calls % quotas.size()]
		result = owner.advance_bounded(120.0, quota)
		calls += 1
		if not result.ok or result.work_units > quota or result.status != "PENDING":
			break
	check(result.ok and result.status == "COMPLETE" and physical(expected) == physical(actual), "changing quota at arbitrary cursor positions preserves physical results")
	evidence.varying = {"quotas": quotas, "calls": calls, "result": result}

func _public_ports() -> void:
	var scenario: Scenario = Scenario.new()
	check(scenario.configure(), "pending public-port fixture")
	var env: Dictionary = scenario.env
	var first: Dictionary = env.lod.advance_bounded(1800.0, 1)
	var counters: Dictionary = env.state.counters.duplicate()
	var messages: int = env.information._messages.size()
	var events: int = env.state.events.size()
	var views: Array[Dictionary] = [env.information.knowledge("company"), env.information.inbox("company"), env.information.snapshot(),
		env.logistics.audit(), env.logistics.snapshot(), env.structure.node("blue_platoon"), env.structure.relation("node_unit_000"), env.structure.snapshot(),
		env.space.edge_view("bridge_BD"), env.space.facility_summary("region_50"), env.decisions.preview("company"), env.decisions.snapshot(), scenario.trace.page()]
	var guarded: bool = first.status == "PENDING"
	for view: Dictionary in views:
		guarded = guarded and view.get("status") == "PENDING" and view.get("committed_time") == 0.0
	check(guarded, "all observer domain views expose only pending/old stamp")
	check(not env.logistics.submit("company", {}).ok and not env.structure.submit("company", {}).ok and not env.space.load_cell("cell_037").ok and not env.decisions.schedule("company", "forged", 0.0).ok and not env.information.issue_command("company", {}).ok, "pending writes cannot modify unfinished inputs")
	check(counters == env.state.counters and messages == env.information._messages.size() and events == env.state.events.size(), "pending reads/writes have no physical or queue side effects")
	check(run(env.lod, 1800.0, 31).result.status == "COMPLETE" and scenario.ledger_balanced(), "guarded state can finish original request")
