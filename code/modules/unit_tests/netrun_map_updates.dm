/// Full-map projection revisions describe actual composition and status changes.
/datum/unit_test/netrun_map_full_projection_updates/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/area/room = scene.room(/area/netrun_route_test)
	for(var/turf/spot as anything in block(origin, locate(origin.x + 10, origin.y + 1, origin.z)))
		scene.take(spot, room)
	for(var/i in 1 to 6)
		scene.machine(/obj/machinery/power/apc, locate(origin.x + (i - 1) * 2, origin.y + 1, origin.z))
	var/obj/machinery/computer/netrun_terminal/source = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	var/obj/machinery/computer/netrun_terminal/target = scene.machine(/obj/machinery/computer/netrun_terminal, locate(origin.x + 10, origin.y, origin.z))
	var/datum/component/netrun_node/target_node = target.GetComponent(/datum/component/netrun_node)
	SSnetrun.ensure_topology()
	source.console.workspace_view = "map"
	var/list/payload = netrun_settled_ui_data(source.console)
	TEST_ASSERT(netrun_map_has_node(payload, target_node.address), "The complete permitted graph must include endpoints beyond four edges")
	var/list/map = payload["map"]
	var/structural = map["structure_revision"]
	var/state = map["state_revision"]
	payload = netrun_settled_ui_data(source.console)
	map = payload["map"]
	TEST_ASSERT_EQUAL(map["structure_revision"], structural, "A repeated poll must reuse the structural generation")
	TEST_ASSERT_EQUAL(map["state_revision"], state, "A repeated unchanged poll must reuse the state generation")
	target.set_machine_stat(BROKEN)
	target_node.reconcile_state()
	payload = netrun_settled_ui_data(source.console)
	map = payload["map"]
	TEST_ASSERT(netrun_map_has_node(payload, target_node.address), "An offline leaf remains a discoverable endpoint")
	TEST_ASSERT_EQUAL(map["structure_revision"], structural, "An offline leaf must not trigger a new layout generation")
	TEST_ASSERT(map["state_revision"] > state, "Native availability changes must publish a new status generation")
	var/old_address = target_node.address
	qdel(target)
	payload = netrun_settled_ui_data(source.console)
	map = payload["map"]
	TEST_ASSERT(!netrun_map_has_node(payload, old_address), "Deleting a node must remove it on the next update without reopening UI")
	TEST_ASSERT(map["structure_revision"] > structural, "Removing a visible node must advance the projection generation")
	for(var/list/edge as anything in map["edges"])
		TEST_ASSERT(edge["from"] != old_address && edge["to"] != old_address, "Deleted endpoints must not leave dangling map edges")

/// Work counters verify that live overlays do not rebuild the stationary projection.
/datum/netrun_map_view/netrun_performance_test
	var/rebuilds = 0
	var/serialized_nodes = 0
	var/list/projected_by_address = list()

/datum/netrun_map_view/netrun_performance_test/rebuild(datum/netrun_topology/graph)
	rebuilds++
	return ..()

/datum/netrun_map_view/netrun_performance_test/project_entry(datum/component/netrun_node/node, neighbor_count)
	serialized_nodes++
	projected_by_address[node.address]++
	return ..()

/// Walking a carried terminal must update its marker, not rebuild every permitted endpoint.
/datum/unit_test/netrun_map_carrier_motion_work/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/area/room = scene.room(/area/netrun_route_test)
	for(var/turf/spot as anything in block(origin, locate(origin.x + 8, origin.y + 2, origin.z)))
		scene.take(spot, room)
	scene.machine(/obj/machinery/power/apc, get_step(origin, NORTH))
	var/mob/living/carbon/human/carrier = allocate(/mob/living/carbon/human, origin)
	var/obj/item/netrun_deck/deck = allocate(/obj/item/netrun_deck, carrier)
	for(var/i in 1 to 100)
		var/obj/item/device = allocate(/obj/item, locate(origin.x + i % 8, origin.y + 2, origin.z))
		device.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
	var/datum/netrun_console/console = deck.console
	qdel(console.map_view)
	var/datum/netrun_map_view/netrun_performance_test/view = new(console)
	console.map_view = view
	console.workspace_view = "map"
	netrun_settled_ui_data(console)
	var/builds = view.rebuilds
	var/entries = view.serialized_nodes
	var/paint = view.static_revision
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	var/graph_revision = graph.revision
	var/datum/component/netrun_node/source = deck.GetComponent(/datum/component/netrun_node)
	var/datum/netrun_path_tree/table = graph.route_tables[source.address]
	var/started = TICK_USAGE
	for(var/i in 1 to 20)
		carrier.forceMove(locate(origin.x + i % 2, origin.y, origin.z))
		netrun_settled_ui_data(console)
	world.log << "NETRUN_LOAD 100 endpoints, 20 carrier moves: [round(TICK_DELTA_TO_MS(TICK_USAGE - started), 0.01)]ms; map rebuilds [view.rebuilds - builds], projected [view.serialized_nodes - entries]."
	TEST_ASSERT_EQUAL(view.rebuilds, builds, "Twenty same-area carrier moves must not rebuild the full permitted map")
	TEST_ASSERT(view.serialized_nodes <= entries + 20, "Movement must project only the moving endpoint, independent of the other hundred nodes")
	TEST_ASSERT_EQUAL(view.static_revision, paint, "Carried endpoint movement must retain the stationary Pixi canvas")
	TEST_ASSERT_EQUAL(graph.revision, graph_revision, "A moving leaf must retain the structural topology")
	TEST_ASSERT_EQUAL(graph.route_tables[source.address], table, "Movement must reuse the retained source tree")

/// Many simultaneous moving viewers must keep stationary projection work out of the hot path.
/datum/unit_test/netrun_map_station_motion_load/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/area/room = scene.room(/area/netrun_route_test)
	for(var/turf/spot as anything in block(origin, locate(origin.x + 8, origin.y + 2, origin.z)))
		scene.take(spot, room)
	var/obj/machinery/power/apc/apc = scene.machine(/obj/machinery/power/apc, get_step(origin, NORTH))
	var/list/fixture_nodes = list(apc.GetComponent(/datum/component/netrun_node))
	var/list/stationary_nodes = list()
	for(var/i in 1 to 2000)
		var/obj/item/device = allocate(/obj/item, locate(origin.x + i % 8, origin.y + 2, origin.z))
		var/datum/component/netrun_node/node = device.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
		fixture_nodes += node
		stationary_nodes += node
		if(!(i % 100))
			CHECK_TICK
	var/list/carriers = list()
	var/list/consoles = list()
	var/list/builds = list()
	var/list/entries = list()
	var/list/address_entries = list()
	for(var/i in 1 to 8)
		var/mob/living/carbon/human/carrier = allocate(/mob/living/carbon/human, origin)
		var/obj/item/netrun_deck/deck = allocate(/obj/item/netrun_deck, carrier)
		fixture_nodes += deck.GetComponent(/datum/component/netrun_node)
		carriers += carrier
		var/datum/netrun_console/console = deck.console
		qdel(console.map_view)
		var/datum/netrun_map_view/netrun_performance_test/view = new(console)
		console.map_view = view
		console.workspace_view = "map"
		consoles += console
	SSnetrun.ensure_topology()
	// Initialization queues the first native status reconciliation. Complete that
	// separate workload before measuring movement so a CHECK_TICK cannot make it
	// look as if the first motion changed every stationary fixture's occupancy.
	var/settle_ms = 0
	for(var/datum/component/netrun_node/node as anything in fixture_nodes)
		var/started = TICK_USAGE
		node.join_network()
		node.reconcile_state()
		node.publish_changes()
		settle_ms += max(0, TICK_DELTA_TO_MS(TICK_USAGE - started))
		CHECK_TICK
	var/warm_ms = 0
	for(var/datum/netrun_console/console as anything in consoles)
		var/started = TICK_USAGE
		netrun_settled_ui_data(console)
		warm_ms += max(0, TICK_DELTA_TO_MS(TICK_USAGE - started))
		var/datum/netrun_map_view/netrun_performance_test/view = console.map_view
		builds[console] = view.rebuilds
		entries[console] = view.serialized_nodes
		address_entries[console] = view.projected_by_address.Copy()
		CHECK_TICK
	for(var/datum/netrun_console/console as anything in consoles)
		netrun_settled_ui_data(console)
		var/datum/netrun_map_view/netrun_performance_test/view = console.map_view
		log_world("NETRUN LOAD movement warmup: viewer=[consoles.Find(console)] initial_projected=[entries[console]] quiet_projected=[view.serialized_nodes - entries[console]] rebuilds=[view.rebuilds - builds[console]] dirty=[length(view.dirty_nodes)]")
		TEST_ASSERT_EQUAL(view.serialized_nodes, entries[console], "A settled stationary fixture must have a quiet projection before measuring movement")
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	var/revision = graph.revision
	var/elapsed_ms = 0
	var/peak_poll_ms = 0
	var/move_ms = 0
	var/peak_move_ms = 0
	for(var/step in 1 to 24)
		var/move_started = TICK_USAGE
		for(var/mob/living/carbon/human/carrier as anything in carriers)
			carrier.forceMove(locate(origin.x + step % 2, origin.y, origin.z))
		var/move_cost_ms = max(0, TICK_DELTA_TO_MS(TICK_USAGE - move_started))
		move_ms += move_cost_ms
		peak_move_ms = max(peak_move_ms, move_cost_ms)
		for(var/datum/netrun_console/console as anything in consoles)
			var/started = TICK_USAGE
			netrun_settled_ui_data(console)
			var/cost_ms = max(0, TICK_DELTA_TO_MS(TICK_USAGE - started))
			elapsed_ms += cost_ms
			peak_poll_ms = max(peak_poll_ms, cost_ms)
		CHECK_TICK
	var/projected = 0
	var/stationary_projected = 0
	for(var/datum/netrun_console/console as anything in consoles)
		var/datum/netrun_map_view/netrun_performance_test/view = console.map_view
		var/changed = view.serialized_nodes - entries[console]
		var/static_changed = 0
		var/list/baseline = address_entries[console]
		for(var/datum/component/netrun_node/node as anything in stationary_nodes)
			static_changed += view.projected_by_address[node.address] - baseline[node.address]
		log_world("NETRUN LOAD movement observations: viewer=[consoles.Find(console)] projected=[changed] stationary_projected=[static_changed] full_rebuilds=[view.rebuilds - builds[console]]")
		projected += changed
		stationary_projected += static_changed
	log_world("NETRUN LOAD movement: stationary=2000 carriers=8 steps=24 ui_polls=192 projected=[projected] stationary_projected=[stationary_projected] settle_cpu_ms=[round(settle_ms, 0.01)] warm_cpu_ms=[round(warm_ms, 0.01)] move_cpu_ms=[round(move_ms, 0.01)] peak_move_ms=[round(peak_move_ms, 0.01)] poll_cpu_ms=[round(elapsed_ms, 0.01)] peak_poll_ms=[round(peak_poll_ms, 0.01)]")
	for(var/datum/netrun_console/console as anything in consoles)
		var/datum/netrun_map_view/netrun_performance_test/view = console.map_view
		TEST_ASSERT_EQUAL(view.rebuilds, builds[console], "Concurrent carried endpoints must retain all eight complete map projections")
		TEST_ASSERT(view.serialized_nodes - entries[console] <= 8 * 24, "Projection work must depend on moving endpoints, not the two thousand stationary devices")
	TEST_ASSERT_EQUAL(stationary_projected, 0, "Repeated movement must never reproject the two thousand unchanged devices")
	TEST_ASSERT_EQUAL(graph.revision, revision, "Repeated same-area player movement must not rebuild station topology")

/// A movement signal must not measure cables, scan APCs or walk active route tables inline.
/datum/unit_test/netrun_movement_queues_binding/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/area/room = scene.room(/area/netrun_route_test)
	scene.take(origin, room)
	var/turf/destination = scene.take(get_step(origin, EAST), room)
	scene.machine(/obj/machinery/power/apc, scene.take(get_step(origin, NORTH), room))
	var/obj/item/endpoint = allocate(/obj/item, origin)
	var/datum/component/netrun_node/node = endpoint.AddComponent(/datum/component/netrun_node, NETRUN_NODE_DECK)
	SSnetrun.ensure_topology()
	var/turf/previous = node.topology_turf
	endpoint.forceMove(destination)
	TEST_ASSERT_EQUAL(node.topology_turf, previous, "Movement must defer binding/weight work until the queued task or explicit route consumer")
	TEST_ASSERT(SSnetrun.get_task_scheduler().by_key["node:[REF(node)]"], "Movement must queue one bounded node update")
	var/datum/netrun_task/node/task = allocate(/datum/netrun_task/node, "node", "motion-test", NETRUN_TASK_NORMAL, node)
	task.execute(SSnetrun)
	TEST_ASSERT_EQUAL(node.topology_turf, destination, "The worker must reconcile the latest physical position")

/datum/unit_test/netrun_map_incremental_work/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/area/room = scene.room(/area/netrun_route_test)
	scene.take(origin, room)
	var/turf/apc_spot = scene.take(get_step(origin, NORTH), room)
	var/turf/target_spot = scene.take(get_step(origin, EAST), room)
	scene.machine(/obj/machinery/power/apc, apc_spot)
	var/obj/machinery/computer/netrun_terminal/source = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	var/obj/machinery/computer/netrun_terminal/target = scene.machine(/obj/machinery/computer/netrun_terminal, target_spot)
	var/datum/component/netrun_node/node = target.GetComponent(/datum/component/netrun_node)
	var/datum/netrun_console/console = source.console
	qdel(console.map_view)
	var/datum/netrun_map_view/netrun_performance_test/view = new(console)
	console.map_view = view
	console.workspace_view = "map"
	SSnetrun.ensure_topology()
	var/list/payload = netrun_settled_ui_data(console)
	var/list/map = payload["map"]
	var/paint = map["static_revision"]
	var/generation = map["state_revision"]
	var/builds = view.rebuilds
	var/entries = view.serialized_nodes
	console.process_tick(1)
	netrun_settled_ui_data(console)
	TEST_ASSERT_EQUAL(view.rebuilds, builds, "An idle console tick must reuse its permitted map instead of rebuilding every node")
	TEST_ASSERT_EQUAL(view.serialized_nodes, entries, "A quiet UI request must serialize zero node entries")
	node.touch()
	payload = netrun_settled_ui_data(console)
	map = payload["map"]
	TEST_ASSERT_EQUAL(view.rebuilds, builds, "Activity must update its indexed entry without rebuilding the full projection")
	TEST_ASSERT_EQUAL(view.serialized_nodes, entries + 1, "One activity invalidation must serialize exactly one indexed node")
	TEST_ASSERT(map["state_revision"] > generation, "The live overlay must receive activity changes")
	TEST_ASSERT_EQUAL(map["static_revision"], paint, "Activity must not invalidate the cached stationary canvas")
	entries = view.serialized_nodes
	target.set_machine_stat(BROKEN)
	node.reconcile_state()
	netrun_settled_ui_data(console)
	TEST_ASSERT_EQUAL(view.rebuilds, builds, "An unavailable leaf must not rebuild the reachable network projection")
	TEST_ASSERT_EQUAL(view.serialized_nodes, entries + 1, "An unavailable leaf must serialize just itself and update its incident edge")
	console.workspace_view = "terminal"
	console.process_tick(1)
	TEST_ASSERT(!view.subscribed, "A hidden map must stop receiving global node-change broadcasts")
	node.touch()
	TEST_ASSERT_EQUAL(length(view.dirty_nodes), 0, "Hidden maps must not collect per-node update queues")
	console.workspace_view = "map"
	netrun_settled_ui_data(console)
	TEST_ASSERT(view.subscribed && view.rebuilds > builds, "Returning to a suspended map must subscribe and reconcile changes once")

/// A carried endpoint remains directly attached to its APC when crossing other machines.
/datum/unit_test/netrun_topology_nested_host_rebind/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/area/room = scene.room(/area/netrun_route_test)
	scene.take(origin, room)
	var/turf/peer_spot = scene.take(get_step(origin, EAST), room)
	var/turf/apc_spot = scene.take(get_step(origin, NORTH), room)
	scene.machine(/obj/machinery/power/apc, apc_spot)
	var/obj/machinery/computer/netrun_terminal/first = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	var/obj/machinery/computer/netrun_terminal/second = scene.machine(/obj/machinery/computer/netrun_terminal, peer_spot)
	var/obj/item/carrier = allocate(/obj/item, origin)
	var/obj/item/endpoint = allocate(/obj/item, carrier)
	var/datum/component/netrun_node/node = endpoint.AddComponent(/datum/component/netrun_node, NETRUN_NODE_DECK)
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	var/datum/component/netrun_node/first_node = first.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/second_node = second.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/apc = node.bound_apc
	TEST_ASSERT_EQUAL(node.uplink_node(), apc, "A personal endpoint must connect directly to its bound APC")
	TEST_ASSERT_NULL(graph.edge_between(node.address, first_node.address), "Co-location must not create a machine-intermediary edge")
	carrier.forceMove(peer_spot)
	// The subsystem's fallback calls join_network even when the child receives no MOVED.
	node.join_network()
	SSnetrun.ensure_topology()
	TEST_ASSERT_EQUAL(node.bound_apc, apc, "Movement within one root area must retain the existing APC binding")
	TEST_ASSERT_EQUAL(node.uplink_node(), apc, "Same-area movement must preserve the direct APC attachment")
	TEST_ASSERT_NULL(graph.edge_between(node.address, first_node.address), "The previous co-located machine must have no endpoint edge")
	TEST_ASSERT_NULL(graph.edge_between(node.address, second_node.address), "The new co-located machine must have no endpoint edge")
	TEST_ASSERT_NOTNULL(graph.edge_between(node.address, apc.address), "The physical cable must still terminate at the original APC")

/// A firewall notification revokes acquired rights before an immediate request can use them.
/datum/unit_test/netrun_firewall_signal_revocation/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/component/netrun_node/node = host.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
	var/mob/camera/netrun_entity/entity = allocate(/mob/camera/netrun_entity)
	entity.enter_node(node)
	entity.console.access_session.node_access[node.address] = NETRUN_ACCESS_ROOT
	TEST_ASSERT_EQUAL(entity.console.node_level(node), NETRUN_ACCESS_ROOT, "The fixture must begin with an acquired grant")
	node.raise_firewall()
	TEST_ASSERT(entity.console.node_level(node) < NETRUN_ACCESS_ROOT, "A permission read must drain pending firewall revocations immediately")
	TEST_ASSERT(!entity.console.access_session.node_access[node.address], "The access session must own and remove its revoked grant")

/// Transport work depends on changed entries, not the size of an already delivered map.
/datum/unit_test/netrun_map_wire_delta_size/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	var/datum/netrun_map_view/view = console.map_view
	var/list/nodes = list()
	for(var/i in 1 to 6000)
		nodes += list(list("address" = "N[i]", "name" = "Camera [i]", "type" = "camera", "x" = i % 80,
			"y" = round(i / 80), "z" = 1, "online" = TRUE, "access" = 1, "entities" = 0, "ice" = 0, "active" = FALSE))
	view.state_revision = 1
	var/list/full = list("nodes" = nodes, "edges" = list(), "gateways" = list(), "sectors" = list(), "apc_zones" = list(),
		"state_revision" = 1, "structure_revision" = 1, "static_revision" = 1, "revision" = 1)
	var/list/session = list("id" = 1)
	var/list/baseline = view.encode_wire(full, session)
	TEST_ASSERT(baseline["full"], "A new UI must receive its complete baseline")
	TEST_ASSERT_EQUAL(length(baseline["nodes"]), 6000, "The first snapshot must contain every permitted physical node")
	var/baseline_bytes = length(json_encode(baseline))
	var/list/quiet = view.encode_wire(full, session)
	TEST_ASSERT(!quiet["full"], "An already synchronized UI must receive a delta")
	TEST_ASSERT_EQUAL(length(quiet["nodes"]), 0, "A quiet poll must not encode any of its 6000 known nodes")
	TEST_ASSERT_EQUAL(length(quiet["edges"]), 0, "A quiet poll must not encode unchanged edges")
	TEST_ASSERT(length(json_encode(quiet)) < 2000, "A quiet map update must remain a small metadata packet")
	TEST_ASSERT(length(json_encode(quiet)) * 100 < baseline_bytes, "A quiet update must be below one percent of the large baseline")
	TEST_ASSERT(!("apc_zones" in quiet), "An unchanged APC shape must not be serialized again")

	var/list/changed = nodes[42].Copy()
	changed["entities"] = 2
	nodes[42] = changed
	full["state_revision"] = ++view.state_revision
	view.record_wire_delta(1, list(changed), list(), list(), list())
	var/list/delta = view.encode_wire(full, session)
	TEST_ASSERT(!delta["full"], "An individual live change must keep its baseline")
	TEST_ASSERT_EQUAL(length(delta["nodes"]), 1, "One changed node must produce one upsert")
	TEST_ASSERT_EQUAL(delta["base_revision"], 1, "The delta must name the exact baseline it extends")
	TEST_ASSERT_EQUAL(delta["state_revision"], 2, "The upsert must advance the client state generation")
	nodes.Cut(42, 43)
	full["state_revision"] = ++view.state_revision
	view.record_wire_delta(2, list(), list(), list("N42"), list())
	delta = view.encode_wire(full, session)
	TEST_ASSERT("N42" in delta["removed_nodes"], "Deletion must remove the client's previously delivered marker")
	TEST_ASSERT_EQUAL(length(delta["nodes"]), 0, "Deletion must not resend all surviving nodes")

	var/list/other_session = list("id" = 2)
	TEST_ASSERT(view.encode_wire(full, other_session)["full"], "A second UI must have an independent complete baseline")
	TEST_ASSERT(!view.encode_wire(full, session)["full"], "A second viewer must not reset the first viewer's cursor")
	view.wire_epoch++
	TEST_ASSERT(view.encode_wire(full, session)["full"], "An authorization epoch change must replace every previously known node set")
	var/list/slow_session = session.Copy()
	for(var/i in 1 to 34)
		var/previous = view.state_revision
		full["state_revision"] = ++view.state_revision
		view.record_wire_delta(previous, list(changed), list(), list(), list())
	TEST_ASSERT(view.encode_wire(full, slow_session)["full"], "A gap beyond bounded history must send a fresh baseline instead of an incomplete delta")

/// A missing or discarded TGUI update must not leave the client stuck with deltas.
/// The snapshot is repeated only for the recovering viewer until its receipt.
/datum/unit_test/netrun_map_resync_ack/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	var/datum/netrun_map_view/view = console.map_view
	var/mob/living/user = allocate(/mob/living)
	var/datum/tgui/ui = allocate(/datum/tgui, user, console, "NetrunTerminal")
	var/list/session = view.wire_session(user, console, ui)
	view.state_revision = 10
	var/list/full = list("state_revision" = 10, "structure_revision" = 1, "static_revision" = 1,
		"revision" = 1, "nodes" = list(), "edges" = list(), "gateways" = list(),
		"sectors" = list(), "apc_zones" = list())
	var/list/baseline = view.encode_wire(full, session)
	TEST_ASSERT(baseline["full"], "Initial viewer must receive a full baseline")
	TEST_ASSERT(!view.encode_wire(full, session)["full"], "An acknowledged ordinary cursor can receive deltas")
	view.resync(ui)
	TEST_ASSERT(view.encode_wire(full, session)["full"], "Resync must force a complete baseline")
	var/list/repeated = view.encode_wire(full, session)
	TEST_ASSERT(repeated["full"], "An unacknowledged full packet must be repeated if TGUI drops it")
	TEST_ASSERT(!view.ack_full(ui, "forged", 10), "A forged epoch must not release the recovery cursor")
	TEST_ASSERT(!view.ack_full(ui, repeated["epoch"], 9), "An out-of-date generation cannot release the cursor")
	TEST_ASSERT(view.encode_wire(full, session)["full"], "Rejected receipts must leave the full baseline active")
	TEST_ASSERT(view.ack_full(ui, repeated["epoch"], 10), "The matching UI can confirm the delivered baseline")
	TEST_ASSERT(!view.encode_wire(full, session)["full"], "After confirmation the lightweight delta stream resumes")

/// Reopening and NTOS program ownership must never share a cursor by accident.
/datum/unit_test/netrun_map_wire_ui_sessions/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	var/mob/living/user = allocate(/mob/living)
	var/datum/tgui/first_ui = allocate(/datum/tgui, user, console, "NetrunTerminal")
	var/list/opening = console.map_view.wire_session(user, console, null)
	var/list/bound = console.map_view.wire_session(user, console, first_ui)
	TEST_ASSERT_EQUAL(opening, bound, "The first registered poll must bind its opening baseline without repeating it")
	var/datum/tgui/reopened = allocate(/datum/tgui, user, console, "NetrunTerminal")
	var/list/replacement = console.map_view.wire_session(user, console, reopened)
	TEST_ASSERT_NOTEQUAL(replacement["id"], bound["id"], "A reopened UI datum must start a new stream epoch")
	var/datum/computer_file/program/netrun/program = allocate(/datum/computer_file/program/netrun)
	var/datum/tgui/ntos_ui = allocate(/datum/tgui, user, program, "NtosNetrun")
	var/list/ntos_session = console.map_view.wire_session(user, program, ntos_ui)
	TEST_ASSERT_NOTEQUAL(ntos_session["id"], replacement["id"], "NTOS must bind its containing program rather than a hidden console UI")
	console.map_view.resync(ntos_ui)
	var/list/recovering = console.map_view.wire_session(user, program, ntos_ui)
	TEST_ASSERT_EQUAL(recovering, ntos_session, "Recovery must keep its viewer's cursor stable while waiting for an acknowledged baseline")
	TEST_ASSERT(recovering["force_full"] && isnull(recovering["revision"]), "Recovery must invalidate only the selected viewer's delta baseline")
	TEST_ASSERT_EQUAL(console.map_view.wire_session(user, console, reopened), replacement, "NTOS resync must preserve another valid viewer")

/// A terminal poll retains shared completion pools while storage changes invalidate disclosure.
/datum/unit_test/netrun_cli_wire_cache/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	var/list/session = list("id" = 1)
	var/list/data = list()
	console.append_cli_payload(data, TRUE, session)
	TEST_ASSERT_NOTNULL(data["cli"], "A terminal stream needs an initial completion baseline")
	var/revision = console.cli_cached_revision
	data = list()
	console.append_cli_payload(data, TRUE, session)
	TEST_ASSERT(!("cli" in data), "A quiet terminal poll must omit large completion pools preserved by TGUI")
	TEST_ASSERT_EQUAL(console.cli_cached_revision, revision, "Quiet polls must reuse their completion projection")
	console.map_view.invalidate()
	data = list()
	console.append_cli_payload(data, TRUE, session)
	TEST_ASSERT_NOTNULL(data["cli"], "An authorization invalidation must replace cached completions")
	TEST_ASSERT_NOTNULL(console.ui_static_data(null)["cli"], "Full refresh must always restore completions even with the same UI cursor")
	data = list()
	console.append_network_catalog(data, session)
	TEST_ASSERT_NOTNULL(data["networks"], "A new stream must receive its network catalog")
	data = list()
	console.append_network_catalog(data, session)
	TEST_ASSERT(!("networks" in data), "A quiet poll must not JSON-encode the same full LAN catalog")
	TEST_ASSERT_NOTNULL(console.ui_static_data(null)["networks"], "A refreshed browser must restore its network catalog baseline")


/// Only live map subscribers need network-event update notifications.
/datum/unit_test/netrun_map_event_signal_lifecycle/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	var/datum/netrun_map_view/view = console.map_view
	view.subscribe()
	console.ui_dirty = FALSE
	SSnetrun.post_event("trace", null, "test-event")
	TEST_ASSERT(console.ui_dirty, "Subscribed maps receive global network event signals")
	view.suspend()
	console.ui_dirty = FALSE
	SSnetrun.post_event("trace", null, "test-event")
	TEST_ASSERT(!console.ui_dirty, "Suspended maps do not receive network event signals")

/// Switching between APCs in one department must update one retained edge.
/datum/unit_test/netrun_map_apc_rebind_incremental/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/area/first_room = scene.room(/area/engineering/netrun_route_test)
	var/area/second_room = scene.room(/area/engineering/netrun_route_test)
	var/turf/source_spot = scene.take(origin, first_room)
	var/turf/target_spot = scene.take(get_step(origin, EAST), first_room)
	var/turf/destination = scene.take(locate(origin.x + 4, origin.y, origin.z), second_room)
	var/turf/first_apc_spot = scene.take(get_step(origin, NORTH), first_room)
	var/turf/second_apc_spot = scene.take(locate(origin.x + 5, origin.y, origin.z), second_room)
	scene.machine(/obj/machinery/power/apc, first_apc_spot)
	var/obj/machinery/power/apc/second = scene.machine(/obj/machinery/power/apc, second_apc_spot)
	var/obj/machinery/computer/netrun_terminal/source = scene.machine(/obj/machinery/computer/netrun_terminal, source_spot)
	var/obj/machinery/computer/netrun_terminal/target = scene.machine(/obj/machinery/computer/netrun_terminal, target_spot)
	var/datum/netrun_console/console = source.console
	qdel(console.map_view)
	var/datum/netrun_map_view/netrun_performance_test/view = new(console)
	console.map_view = view
	console.workspace_view = "map"
	SSnetrun.ensure_topology()
	var/list/map = netrun_settled_ui_data(console)["map"]
	var/builds = view.rebuilds
	var/datum/component/netrun_node/node = target.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/second_node = second.GetComponent(/datum/component/netrun_node)
	TEST_ASSERT(netrun_map_has_node(list("map" = map), node.address), "The target must be present before moving")
	target.forceMove(destination)
	node.join_network()
	TEST_ASSERT_EQUAL(node.bound_apc, second_node, "The leaf must change its APC")
	map = netrun_settled_ui_data(console)["map"]
	TEST_ASSERT_EQUAL(view.rebuilds, builds, "An APC-to-APC move within one LAN must avoid rebuilding the entire viewer map")
	TEST_ASSERT(netrun_map_has_node(list("map" = map), node.address), "The moved leaf must remain visible")
