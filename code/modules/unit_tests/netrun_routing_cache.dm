/// A real two-APC network keeps cache tests independent of artificial graph fixtures.
/datum/netrun_routing_cache_scene
	parent_type = /datum/netrun_transport_scene
	var/area/remote_room
	var/turf/remote_spot
	var/obj/machinery/power/apc/remote_apc
	var/original_cache_limit

/datum/netrun_routing_cache_scene/New(turf/origin)
	..(origin)
	original_cache_limit = SSnetrun.get_machine_transport().route_cache_limit
	remote_room = room(/area/netrun_route_test)
	remote_spot = take(locate(origin.x + 4, origin.y + 2, origin.z), remote_room)
	var/turf/power_spot = take(get_step(remote_spot, SOUTH), remote_room)
	remote_apc = machine(/obj/machinery/power/apc, power_spot)
	receiver.forceMove(remote_spot)
	SSnetrun.ensure_topology()

/datum/netrun_routing_cache_scene/Destroy()
	SSnetrun.get_machine_transport().route_cache_limit = original_cache_limit
	remote_apc = null
	remote_spot = null
	remote_room = null
	return ..()

/// Discovery, boolean reachability and owned delivery routes reuse one materialized path.
/datum/unit_test/netrun_routing_cache_repeated_path/Run()
	var/datum/netrun_routing_cache_scene/scene = allocate(/datum/netrun_routing_cache_scene, run_loc_floor_bottom_left)
	var/datum/netrun_machine_transport/transport = SSnetrun.get_machine_transport()
	TEST_ASSERT(transport.borrowed_path(scene.source, scene.target), "The real machines must have a physical path")
	var/built = transport.path_builds
	var/trees = transport.tree_builds
	var/hits = transport.path_cache_hits
	for(var/i in 1 to 40)
		TEST_ASSERT(transport.reachable(scene.source, scene.target), "A warm reachability lookup must remain usable")
		var/datum/netrun_route/owned = transport.route(scene.source, scene.target)
		TEST_ASSERT(owned, "Packet delivery must receive an owned route from the same warm path")
		qdel(owned)
	TEST_ASSERT_EQUAL(transport.path_builds, built, "Repeated discovery and delivery must not reconstruct the same physical path")
	TEST_ASSERT_EQUAL(transport.tree_builds, trees, "Repeated queries must not solve another shortest-path tree")
	TEST_ASSERT(transport.path_cache_hits >= hits + 80, "Both reachability and route acquisition must hit the warm cache")

/// Machine routing trees retain only forwarding infrastructure, not every destination device.
/datum/unit_test/netrun_routing_cache_infrastructure_tree/Run()
	var/datum/netrun_routing_cache_scene/scene = allocate(/datum/netrun_routing_cache_scene, run_loc_floor_bottom_left)
	for(var/i in 1 to 20)
		scene.machine(/obj/machinery/netrun_server/transport_fixture, scene.source_spot)
	var/datum/netrun_machine_transport/transport = SSnetrun.get_machine_transport()
	TEST_ASSERT(transport.borrowed_path(scene.source, scene.target), "The two physical APCs must communicate")
	var/datum/component/netrun_node/source_apc = scene.apc.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/target_apc = scene.remote_apc.GetComponent(/datum/component/netrun_node)
	var/datum/netrun_path_tree/tree = transport.route_trees[source_apc.address]
	TEST_ASSERT(tree, "The source APC must retain its reusable infrastructure tree")
	TEST_ASSERT(tree.reached[target_apc.address], "The infrastructure tree must include the destination APC")
	TEST_ASSERT(!tree.reached[scene.source.node.address] && !tree.reached[scene.target.node.address], "Ordinary endpoints must not occupy every APC's retained tree")
	var/datum/component/netrun_node/dns_node = scene.dns.GetComponent(/datum/component/netrun_node)
	TEST_ASSERT(!tree.reached[dns_node.address], "A DNS endpoint is a destination, not forwarding infrastructure")
	TEST_ASSERT_EQUAL(tree.neighbor_visits, 2, "Solving two APCs must visit only their two directed edges, regardless of endpoint population")

/// Moving or rebooting an unrelated leaf must not invalidate the shared infrastructure work.
/datum/unit_test/netrun_routing_cache_unrelated_leaf/Run()
	var/datum/netrun_routing_cache_scene/scene = allocate(/datum/netrun_routing_cache_scene, run_loc_floor_bottom_left)
	var/obj/machinery/netrun_server/transport_fixture/unrelated = scene.machine(/obj/machinery/netrun_server/transport_fixture, scene.source_spot)
	var/area/local_room = get_area(scene.source_spot)
	var/offset = 2 * NETRUN_LINK_TILES_PER_DS
	var/x = scene.source_spot.x + offset <= world.maxx ? scene.source_spot.x + offset : scene.source_spot.x - offset
	var/turf/far_spot = scene.take(locate(x, scene.source_spot.y, scene.source_spot.z), local_room, TRUE)
	var/datum/netrun_machine_transport/transport = SSnetrun.get_machine_transport()
	TEST_ASSERT(transport.borrowed_path(scene.source, scene.target), "Warm the two-APC route after creating the unrelated endpoint")
	var/trees = transport.tree_builds
	var/paths = transport.path_builds
	unrelated.set_machine_stat(BROKEN)
	TEST_ASSERT(transport.borrowed_path(scene.source, scene.target), "Another device's power loss must not cut the working route")
	TEST_ASSERT_EQUAL(transport.tree_builds, trees, "Leaf availability must not rebuild infrastructure trees")
	unrelated.set_machine_stat(0)
	var/datum/netrun_topology/graph = SSnetrun.get_topology()
	var/weights = graph.weight_revision
	unrelated.forceMove(far_spot)
	TEST_ASSERT(graph.weight_revision > weights, "The real move must change a cable's routing cost")
	TEST_ASSERT(transport.borrowed_path(scene.source, scene.target), "The original pair must remain reachable after unrelated cable movement")
	TEST_ASSERT_EQUAL(transport.tree_builds, trees, "An unrelated cable cost must not rerun infrastructure Dijkstra")
	TEST_ASSERT_EQUAL(transport.path_builds, paths, "An unchanged source/destination pair must retain its materialized path")

/// A carried device has no child MOVED signal; route lookup must refresh its actual attachment.
/datum/unit_test/netrun_routing_cache_carried_target/Run()
	var/datum/netrun_routing_cache_scene/scene = allocate(/datum/netrun_routing_cache_scene, run_loc_floor_bottom_left)
	var/obj/item/carrier = allocate(/obj/item, scene.source_spot)
	var/obj/item/modular_computer/pda/pda = allocate(/obj/item/modular_computer/pda, carrier)
	pda.enabled = TRUE
	var/datum/netrun_machine_service/target = pda.get_netrun_machine_service("pda.messenger")
	var/datum/netrun_machine_transport/transport = SSnetrun.get_machine_transport()
	TEST_ASSERT(transport.borrowed_path(scene.source, scene.target), "Warm the source APC's infrastructure tree")
	var/datum/netrun_route/before = transport.route(scene.source, target)
	allocated += before
	TEST_ASSERT(before, "The carried PDA must initially share the sender's APC")
	var/trees = transport.tree_builds
	var/area/original_area = target.node.binding_area
	carrier.forceMove(scene.remote_spot)
	TEST_ASSERT_EQUAL(target.node.binding_area, original_area, "Moving only the carrier must not emit a child movement signal")
	var/datum/netrun_route/after = transport.route(scene.source, target)
	allocated += after
	TEST_ASSERT(after, "A carried target must remain routable after crossing into the other APC's area")
	var/datum/component/netrun_node/remote_node = scene.remote_apc.GetComponent(/datum/component/netrun_node)
	TEST_ASSERT_EQUAL(target.node.bound_apc, remote_node, "Lookup must discover the carried target's current physical attachment")
	TEST_ASSERT(remote_node.address in after.hops, "The new cached route must actually cross the destination APC")
	TEST_ASSERT_NOTEQUAL(json_encode(after.hops), json_encode(before.hops), "A previous pair-cache entry must not keep the old cable")
	TEST_ASSERT(after.latency > before.latency, "The new APC edge must contribute to the carried target's latency")
	TEST_ASSERT_EQUAL(transport.tree_builds, trees, "Rebinding one leaf must not rebuild the unchanged infrastructure mesh")

/// Live availability checks must reject and recover within the same tick, including warm pairs.
/datum/unit_test/netrun_routing_cache_power_recovery/Run()
	var/datum/netrun_routing_cache_scene/scene = allocate(/datum/netrun_routing_cache_scene, run_loc_floor_bottom_left)
	var/datum/netrun_machine_transport/transport = SSnetrun.get_machine_transport()
	TEST_ASSERT(transport.borrowed_path(scene.source, scene.target), "Warm the path before breaking its forwarding APC")
	var/tick = world.time
	scene.remote_apc.set_machine_stat(BROKEN)
	TEST_ASSERT(!transport.borrowed_path(scene.source, scene.target), "A warm cache must immediately reject a broken forwarding APC")
	scene.remote_apc.set_machine_stat(0)
	TEST_ASSERT(transport.borrowed_path(scene.source, scene.target), "A negative result must not survive actual forwarding recovery")
	TEST_ASSERT_EQUAL(world.time, tick, "Outage and recovery checks must not wait for a poll or timer tick")

/// Public delivery routes are caller-owned even when their backing path is retained.
/datum/unit_test/netrun_routing_cache_owned_copy/Run()
	var/datum/netrun_routing_cache_scene/scene = allocate(/datum/netrun_routing_cache_scene, run_loc_floor_bottom_left)
	var/datum/netrun_machine_transport/transport = SSnetrun.get_machine_transport()
	var/datum/netrun_route/first = transport.route(scene.source, scene.target)
	allocated += first
	TEST_ASSERT(first, "The first delivery must have an owned route")
	var/expected_path = json_encode(first.hops)
	var/expected_latency = first.latency
	first.hops.Cut()
	first.latency = -100
	qdel(first)
	var/datum/netrun_route/second = transport.route(scene.source, scene.target)
	allocated += second
	TEST_ASSERT(second, "Releasing one owned route must not delete the private cached route")
	TEST_ASSERT_EQUAL(json_encode(second.hops), expected_path, "Caller mutation must not corrupt the retained path")
	TEST_ASSERT_EQUAL(second.latency, expected_latency, "Caller mutation must not corrupt cached latency")

/// Lowering the cache bound must trim old traffic as well as cap new pairs.
/datum/unit_test/netrun_routing_cache_bounded/Run()
	var/datum/netrun_routing_cache_scene/scene = allocate(/datum/netrun_routing_cache_scene, run_loc_floor_bottom_left)
	var/datum/netrun_machine_transport/transport = SSnetrun.get_machine_transport()
	transport.route_cache_limit = 4
	var/list/targets = list()
	for(var/i in 1 to 8)
		var/obj/machinery/netrun_server/transport_fixture/machine = scene.machine(/obj/machinery/netrun_server/transport_fixture, scene.remote_spot)
		targets += machine.get_netrun_machine_service("transport.fixture")
	for(var/datum/netrun_machine_service/target as anything in targets)
		TEST_ASSERT(transport.borrowed_path(scene.source, target), "Every distinct physical pair must remain routable under eviction")
		TEST_ASSERT(length(transport.pair_routes) <= 4, "The pair cache must remain within its configured bound")
	var/paths = transport.path_builds
	TEST_ASSERT(transport.borrowed_path(scene.source, targets[length(targets)]), "The newest pair must remain usable")
	TEST_ASSERT_EQUAL(transport.path_builds, paths, "The most recently used pair must still be cached")

/// An offline destination remains a visible leaf; an offline source cannot expose onward routes.
/datum/unit_test/netrun_routing_cache_ui_availability/Run()
	var/datum/netrun_routing_cache_scene/scene = allocate(/datum/netrun_routing_cache_scene, run_loc_floor_bottom_left)
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	var/datum/netrun_path_tree/original = graph.route_snapshot(scene.source.node, TRUE)
	TEST_ASSERT(original.reached[scene.target.node.address], "The UI's original source must discover the remote destination")
	scene.receiver.set_machine_stat(BROKEN)
	var/datum/netrun_path_tree/destination_offline = graph.route_snapshot(scene.source.node, TRUE)
	TEST_ASSERT_EQUAL(destination_offline, original, "A destination leaf reboot must not replace a shared UI routing table")
	TEST_ASSERT(destination_offline.reached[scene.target.node.address], "An offline destination must retain its map position and cable")
	scene.sender.set_machine_stat(BROKEN)
	var/datum/netrun_path_tree/source_offline = graph.route_snapshot(scene.source.node, TRUE)
	TEST_ASSERT_NOTEQUAL(source_offline, original, "Source power changes must still invalidate its retained reachability")
	var/datum/component/netrun_node/apc_node = scene.apc.GetComponent(/datum/component/netrun_node)
	TEST_ASSERT(!source_offline.reached[apc_node.address], "An offline source must not retain an onward route to its APC")
	scene.sender.set_machine_stat(0)
	var/datum/netrun_path_tree/restored = graph.route_snapshot(scene.source.node, TRUE)
	TEST_ASSERT(restored.reached[apc_node.address], "Restoring the source must restore its onward UI reachability immediately")

/// APC countdowns update native fields without a power/stat signal. A retained tree is not authority.
/datum/unit_test/netrun_routing_cache_unsigned_apc_state/Run()
	var/datum/netrun_routing_cache_scene/scene = allocate(/datum/netrun_routing_cache_scene, run_loc_floor_bottom_left)
	var/obj/machinery/computer/netrun_terminal/terminal = scene.machine(/obj/machinery/computer/netrun_terminal, scene.source_spot)
	TEST_ASSERT(terminal.console.can_route(scene.target.node), "The real terminal must first warm a working command path")
	var/tick = world.time
	scene.remote_apc.failure_timer = 5
	TEST_ASSERT(!terminal.console.can_route(scene.target.node), "Cached command reachability must inspect actual forwarding availability without waiting for a stat signal")
	TEST_ASSERT_EQUAL(world.time, tick, "A positive cached command path must be revoked without a subsystem poll")
	scene.remote_apc.failure_timer = 0
	sleep(world.tick_lag)
	TEST_ASSERT(terminal.console.can_route(scene.target.node), "An unsignalled APC countdown recovery must restore command routing")
