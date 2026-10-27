/// Real departmental APCs keep async routing tests on the same graph as gameplay.
/datum/netrun_async_route_scene
	parent_type = /datum/netrun_route_scene
	var/area/local_room
	var/area/remote_room
	var/turf/source_spot
	var/turf/target_spot
	var/turf/far_spot
	var/turf/remote_spot
	var/obj/machinery/power/apc/local_apc
	var/obj/machinery/power/apc/remote_apc
	var/obj/machinery/computer/netrun_terminal/source
	var/obj/machinery/computer/netrun_terminal/target
	var/obj/machinery/computer/netrun_terminal/remote_target
	var/list/leaves = list()
	var/datum/netrun_topology/graph

/datum/netrun_async_route_scene/New(turf/origin)
	..(origin.z)
	local_room = room(/area/medical/netrun_route_test)
	remote_room = room(/area/engineering/netrun_route_test)
	source_spot = take(origin, local_room, TRUE)
	target_spot = take(get_step(origin, EAST), local_room, TRUE)
	far_spot = take(locate(origin.x + 2 * NETRUN_LINK_TILES_PER_DS + 1, origin.y, origin.z), local_room, TRUE)
	remote_spot = take(locate(origin.x + 5, origin.y + 4, origin.z), remote_room, TRUE)
	local_apc = machine(/obj/machinery/power/apc, take(get_step(source_spot, NORTH), local_room, TRUE))
	remote_apc = machine(/obj/machinery/power/apc, take(get_step(remote_spot, NORTH), remote_room, TRUE))
	source = machine(/obj/machinery/computer/netrun_terminal, source_spot)
	target = machine(/obj/machinery/computer/netrun_terminal, target_spot)
	remote_target = machine(/obj/machinery/computer/netrun_terminal, remote_spot)
	source.console.connection.wireless = FALSE
	target.console.connection.wireless = FALSE
	remote_target.console.connection.wireless = FALSE
	SSnetworks.station_network.setting_disabled = TRUE
	graph = SSnetrun.ensure_topology()
	graph.reconcile_availability(TRUE)
	graph.clear_route_tables(TRUE)

/datum/netrun_async_route_scene/proc/add_leaves(count)
	for(var/i in 1 to count)
		var/obj/item/host = new(target_spot)
		owned += host
		leaves += host.AddComponent(/datum/component/netrun_node, NETRUN_NODE_DECK)
	graph = SSnetrun.ensure_topology()
	graph.reconcile_availability(TRUE)

/// Drive worker slices without sleeping into unrelated subsystem tasks. The
/// once-per-world.time guard itself is tested separately before this helper runs.
/datum/netrun_async_route_scene/proc/finish_ui(max_operations = 3)
	var/limit = 12 * length(graph.nodes) + 128
	for(var/i in 1 to limit)
		graph.ui_route_advanced_at = -INFINITY
		if(graph.advance_ui_routes(max_operations))
			return TRUE
	return FALSE

/datum/unit_test/proc/netrun_async_assert_equivalent(datum/netrun_path_tree/actual, datum/netrun_path_tree/expected, datum/netrun_topology/graph)
	TEST_ASSERT_EQUAL(length(actual.reached), length(expected.reached), "Sliced and synchronous solves must discover the same number of nodes")
	for(var/address in graph.nodes)
		TEST_ASSERT_EQUAL(!!actual.reached[address], !!expected.reached[address], "Slicing must preserve reachability for [address]")
		if(!expected.reached[address])
			continue
		TEST_ASSERT_EQUAL(actual.cost_to(address), expected.cost_to(address), "Slicing must preserve the weighted latency to [address]")
		TEST_ASSERT_EQUAL(json_encode(actual.addresses_to(address)), json_encode(expected.addresses_to(address)), "Slicing must preserve the predecessor chain to [address]")
		TEST_ASSERT_EQUAL(!!actual.remote[address], !!expected.remote[address], "Slicing must preserve gateway classification for [address]")
	TEST_ASSERT(actual.network_index_ready, "Only a complete solve may publish its network index")
	TEST_ASSERT_EQUAL(length(actual.reached_networks), length(expected.reached_networks), "Slicing must preserve the reachable LAN index")
	for(var/network_id in expected.reached_networks)
		TEST_ASSERT(actual.reached_networks[network_id], "The sliced LAN index must include [network_id]")

/// An APC fan-out must consume the neighbor budget instead of expanding inline.
/datum/unit_test/netrun_async_route_budget/Run()
	var/datum/netrun_async_route_scene/scene = allocate(/datum/netrun_async_route_scene, run_loc_floor_bottom_left)
	scene.add_leaves(32)
	var/datum/component/netrun_node/source = scene.source.GetComponent(/datum/component/netrun_node)
	var/datum/netrun_path_tree/tree = allocate(/datum/netrun_path_tree, scene.graph, source, FALSE, TRUE)
	TEST_ASSERT_EQUAL(length(tree.reached), 1, "Constructing a deferred solve must expose only the source")
	TEST_ASSERT_EQUAL(tree.neighbor_visits, 0, "Constructing a deferred solve must not inspect neighbors")
	TEST_ASSERT(!tree.advance(1), "One operation may settle the source but cannot solve the graph")
	TEST_ASSERT_EQUAL(tree.neighbor_visits, 0, "Settling the source must leave its cable for a later operation")
	TEST_ASSERT(!tree.advance(1), "One cable relaxation must not expand the APC's terminal fan-out")
	TEST_ASSERT_EQUAL(tree.neighbor_visits, 1, "The next operation must inspect exactly the source cable")
	var/passes = 0
	var/limit = 12 * length(scene.graph.nodes) + 128
	while(!tree.solve_complete && passes++ < limit)
		var/visited = tree.neighbor_visits
		var/reached = length(tree.reached)
		tree.advance(3)
		TEST_ASSERT(tree.neighbor_visits - visited <= 3, "A three-operation slice must never scan an APC's full neighbor list")
		TEST_ASSERT(length(tree.reached) - reached <= 3, "A three-operation slice must discover at most three new destinations")
	TEST_ASSERT(tree.solve_complete, "Bounded slices must eventually exhaust the reachable graph")
	var/datum/netrun_path_tree/reference = allocate(/datum/netrun_path_tree, scene.graph, source)
	netrun_async_assert_equivalent(tree, reference, scene.graph)

/// An offline forwarding APC is a destination, never a route to its children.
/datum/unit_test/netrun_async_route_offline_forwarder/Run()
	var/datum/netrun_async_route_scene/scene = allocate(/datum/netrun_async_route_scene, run_loc_floor_bottom_left)
	var/datum/component/netrun_node/source = scene.source.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/target = scene.target.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/remote = scene.remote_target.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/remote_apc = scene.remote_apc.GetComponent(/datum/component/netrun_node)
	scene.remote_apc.set_machine_stat(BROKEN)
	target.offline_until = world.time + 1 MINUTES
	target.notify_changed()
	scene.graph.reconcile_availability(TRUE)
	var/datum/netrun_path_tree/tree = allocate(/datum/netrun_path_tree, scene.graph, source, FALSE, TRUE)
	var/passes = 0
	while(!tree.solve_complete && passes++ < 128)
		tree.advance(2)
	TEST_ASSERT(tree.solve_complete, "Offline forwarding must terminate the search rather than leave it pending")
	TEST_ASSERT(tree.reached[target.address], "An offline terminal leaf must remain discoverable")
	TEST_ASSERT(tree.reached[remote_apc.address], "The failed forwarding APC must remain discoverable as a destination")
	TEST_ASSERT(!tree.reached[remote.address], "The failed APC must stop propagation to its downstream terminal")
	var/datum/netrun_path_tree/reference = allocate(/datum/netrun_path_tree, scene.graph, source)
	netrun_async_assert_equivalent(tree, reference, scene.graph)
	source.offline_until = world.time + 1 MINUTES
	var/datum/netrun_path_tree/offline_source = allocate(/datum/netrun_path_tree, scene.graph, source, FALSE, TRUE)
	offline_source.advance(3)
	TEST_ASSERT(offline_source.solve_complete, "An offline source must finish without traversing a cable")
	TEST_ASSERT_EQUAL(length(offline_source.reached), 1, "An offline source must expose only itself")
	TEST_ASSERT_EQUAL(offline_source.neighbor_visits, 0, "An offline source must never propagate to its APC")

/// A source crossing a departmental boundary must discard its unfinished old root.
/datum/unit_test/netrun_async_route_source_crossing/Run()
	var/datum/netrun_async_route_scene/scene = allocate(/datum/netrun_async_route_scene, run_loc_floor_bottom_left)
	var/datum/component/netrun_node/source = scene.source.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/remote_apc = scene.remote_apc.GetComponent(/datum/component/netrun_node)
	var/datum/netrun_network/old_network = source.network
	var/datum/netrun_path_tree/provisional = scene.source.console.acquire_ui_routes()
	TEST_ASSERT(scene.source.console.ui_routes_pending, "The first UI acquisition must queue its route solve")
	TEST_ASSERT(!scene.source.console.ui_routes_borrowed, "A pending UI tree must be owned by the caller")
	TEST_ASSERT(provisional.network_index_ready && length(provisional.reached) == 1, "The provisional tree must provide indexed loopback only")
	qdel(provisional)
	var/datum/netrun_path_tree/stale = scene.graph.ui_route_jobs[source.address]
	TEST_ASSERT_NOTNULL(stale, "The private solve must be retained outside the UI request")
	TEST_ASSERT(!scene.graph.advance_ui_routes(1), "A single worker operation must leave the solve pending")
	var/visited = stale.neighbor_visits
	var/cursor = stale.neighbor_cursor
	TEST_ASSERT(!scene.graph.advance_ui_routes(128), "A second worker call in the same world tick must yield")
	TEST_ASSERT_EQUAL(stale.neighbor_visits, visited, "A repeated same-tick call must perform no neighbor work")
	TEST_ASSERT_EQUAL(stale.neighbor_cursor, cursor, "A repeated same-tick call must preserve the cursor")
	scene.source.forceMove(scene.remote_spot)
	source.join_network()
	TEST_ASSERT_EQUAL(source.bound_apc, remote_apc, "The real source must attach to the destination APC")
	TEST_ASSERT_NOTEQUAL(source.network, old_network, "The source must actually cross a departmental LAN boundary")
	provisional = scene.source.console.acquire_ui_routes()
	TEST_ASSERT(scene.source.console.ui_routes_pending && length(provisional.reached) == 1, "The new LAN must never borrow routes rooted at the old APC")
	TEST_ASSERT(provisional.reached_networks[source.network.id] && !provisional.reached_networks[old_network.id], "Pending loopback must index only the source's current LAN")
	qdel(provisional)
	scene.graph.ui_route_advanced_at = -INFINITY
	scene.graph.advance_ui_routes(1)
	TEST_ASSERT(QDELETED(stale), "The first new-generation slice must release the unfinished old-root solve")
	TEST_ASSERT_NOTEQUAL(scene.graph.ui_route_jobs[source.address], stale, "The worker must restart from the source's new APC")
	TEST_ASSERT(scene.finish_ui(), "The replacement solve must eventually publish")
	var/datum/netrun_path_tree/ready = scene.graph.route_tables[source.address]
	TEST_ASSERT(ready && ready.solve_complete, "Only a complete replacement tree may enter the retained cache")
	TEST_ASSERT_EQUAL(ready.previous[remote_apc.address], source.address, "The published first hop must use the new APC")
	var/datum/netrun_path_tree/reference = allocate(/datum/netrun_path_tree, scene.graph, source)
	netrun_async_assert_equivalent(ready, reference, scene.graph)
	TEST_ASSERT_EQUAL(scene.source.console.acquire_ui_routes(), ready, "The next UI request must borrow the completed replacement tree")
	TEST_ASSERT(!scene.source.console.ui_routes_pending && scene.source.console.ui_routes_borrowed, "Completion must leave the UI ready without transferring cache ownership")

/// Cable changes repair pending work, including mutation of a partially visited APC list.
/datum/unit_test/netrun_async_route_movement_progress/Run()
	var/datum/netrun_async_route_scene/scene = allocate(/datum/netrun_async_route_scene, run_loc_floor_bottom_left)
	scene.add_leaves(12)
	var/datum/component/netrun_node/source = scene.source.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/local_apc = scene.local_apc.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/first_leaf
	var/datum/component/netrun_node/last_leaf
	// Addresses are random; choose by the actual adjacency order, not creation order.
	for(var/address in scene.graph.adjacency[local_apc.address])
		var/datum/component/netrun_node/candidate = scene.graph.nodes[address]
		if(!(candidate in scene.leaves))
			continue
		if(!first_leaf)
			first_leaf = candidate
		last_leaf = candidate
	TEST_ASSERT_NULL(scene.graph.request_ui_routes(source, scene.source.console), "The UI must start with a private pending tree")
	var/datum/netrun_path_tree/tree = scene.graph.ui_route_jobs[source.address]
	tree.advance(1)
	var/initial_prefix = tree.source_cost_offset
	scene.source.forceMove(scene.far_spot)
	source.join_network()
	TEST_ASSERT_EQUAL(source.bound_apc, local_apc, "Ordinary movement must preserve the source's native APC")
	TEST_ASSERT_EQUAL(scene.graph.ui_route_jobs[source.address], tree, "Ordinary source movement must retain the pending solve")
	TEST_ASSERT(tree.source_cost_offset > initial_prefix, "The source cable must shift the prefix before its first relaxation")
	TEST_ASSERT_EQUAL(tree.geometry_revision, scene.graph.weight_revision, "A cable repair must carry the partial tree into the current geometry generation")
	var/steps = 0
	while(!(tree.working_address == local_apc.address && tree.reached[first_leaf.address]) && !tree.solve_complete && steps++ < 256)
		tree.advance(1)
	TEST_ASSERT(!tree.solve_complete && tree.reached[first_leaf.address], "The fixture must pause partway through its APC fan-out")
	TEST_ASSERT(!tree.reached[last_leaf.address], "A later neighbor must remain unvisited when the earlier slot is removed")
	var/obj/item/first_host = first_leaf.parent
	var/obj/item/last_host = last_leaf.parent
	first_host.forceMove(scene.remote_spot)
	first_leaf.join_network()
	last_host.forceMove(scene.remote_spot)
	last_leaf.join_network()
	TEST_ASSERT_EQUAL(scene.graph.ui_route_jobs[source.address], tree, "Unrelated leaf rebinding must preserve the same pending tree")
	TEST_ASSERT_EQUAL(tree.geometry_revision, scene.graph.weight_revision, "Unrelated leaf rebinding must repair the partial generation")
	TEST_ASSERT(scene.finish_ui(), "A moving station must allow the original partial solve to finish")
	TEST_ASSERT_EQUAL(scene.graph.route_tables[source.address], tree, "Movement must repair and publish the original tree instead of restarting it")
	var/datum/netrun_path_tree/reference = allocate(/datum/netrun_path_tree, scene.graph, source)
	netrun_async_assert_equivalent(tree, reference, scene.graph)

/// One viewer closing cannot cancel another; the last viewer and loopback both clean up.
/datum/unit_test/netrun_async_route_waiter_cleanup/Run()
	var/datum/netrun_async_route_scene/scene = allocate(/datum/netrun_async_route_scene, run_loc_floor_bottom_left)
	var/datum/component/netrun_node/source = scene.source.GetComponent(/datum/component/netrun_node)
	scene.graph.request_ui_routes(source, scene.source.console)
	scene.graph.request_ui_routes(source, scene.target.console)
	var/datum/netrun_path_tree/shared = scene.graph.ui_route_jobs[source.address]
	var/list/waiters = scene.graph.ui_route_waiters[source.address]
	TEST_ASSERT_EQUAL(length(waiters), 2, "Viewers of one source must share its private solve")
	scene.source.console.stop_ui_observation()
	TEST_ASSERT_EQUAL(scene.graph.ui_route_jobs[source.address], shared, "Closing one viewer must preserve the other viewer's work")
	TEST_ASSERT_EQUAL(length(waiters), 1, "Closing one viewer must remove only its waiter")
	scene.target.console.stop_ui_observation()
	TEST_ASSERT_NULL(scene.graph.ui_route_jobs[source.address], "The last viewer must release its abandoned solve")
	TEST_ASSERT_NULL(scene.graph.ui_route_waiters[source.address], "The last viewer must release its waiter bucket")
	TEST_ASSERT(QDELETED(shared), "An abandoned partial tree must be deleted")
	scene.graph.request_ui_routes(source, scene.source.console)
	var/datum/netrun_path_tree/outside = scene.graph.ui_route_jobs[source.address]
	scene.source.console.connection.wireless = TRUE
	scene.source.forceMove(null)
	source.join_network()
	var/datum/netrun_path_tree/loopback = scene.source.console.acquire_ui_routes()
	allocated += loopback
	TEST_ASSERT(!scene.source.console.ui_routes_pending, "An out-of-zone wireless session must not wait for a graph solve")
	TEST_ASSERT(loopback.network_index_ready && loopback.reached[source.address] && length(loopback.reached) == 1, "Out-of-zone wireless access must expose indexed source loopback only")
	TEST_ASSERT_NULL(scene.graph.ui_route_jobs[source.address], "Wireless loopback must cancel its previous pending graph solve")
	TEST_ASSERT(QDELETED(outside), "Wireless loopback must release the previous partial tree")
