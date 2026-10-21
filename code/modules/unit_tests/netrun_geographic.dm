/// Initial attachment prefers the APC actually serving the native area, then remains stable.
/datum/unit_test/netrun_geographic_native_apc/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/area/local_room = scene.room(/area/medical/netrun_route_test)
	var/area/foreign_room = scene.room(/area/engineering/netrun_route_test)
	scene.take(origin, local_room)
	var/turf/close_spot = scene.take(get_step(origin, NORTH), foreign_room)
	var/turf/native_spot = scene.take(locate(origin.x + 8, origin.y, origin.z), local_room)
	scene.machine(/obj/machinery/power/apc, close_spot)
	var/obj/machinery/power/apc/native = scene.machine(/obj/machinery/power/apc, native_spot)
	var/obj/machinery/computer/netrun_terminal/terminal = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	var/datum/component/netrun_node/node = terminal.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/native_node = native.GetComponent(/datum/component/netrun_node)
	SSnetrun.ensure_topology()
	TEST_ASSERT_EQUAL(node.bound_apc, native_node, "A native-area APC must beat a physically closer foreign-area APC")
	scene.machine(/obj/machinery/power/apc, scene.take(get_step(origin, EAST), local_room))
	SSnetrun.ensure_topology()
	TEST_ASSERT_EQUAL(node.bound_apc, native_node, "A newly installed closer APC must preserve an established attachment")

/// Two nearest-neighbor clusters receive only their shortest connecting bridge.
/datum/unit_test/netrun_geographic_apc_bridges/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/datum/netrun_topology/graph = allocate(/datum/netrun_topology)
	var/area/room = scene.room(/area/netrun_route_test)
	var/list/addresses = list()
	var/list/ordered_nodes = list()
	for(var/offset in list(0, 1, 2, 20, 21, 22))
		var/obj/machinery/power/apc/apc = scene.machine(/obj/machinery/power/apc, scene.take(locate(origin.x + offset, origin.y, origin.z), room))
		var/datum/component/netrun_node/node = apc.GetComponent(/datum/component/netrun_node)
		ordered_nodes += node
		addresses += node.address
		graph.nodes[node.address] = node
		graph.adjacency[node.address] = list()
	graph.connect_apcs(sort_list(addresses))
	var/datum/component/netrun_node/first_tip = ordered_nodes[3]
	var/datum/component/netrun_node/second_tip = ordered_nodes[4]
	TEST_ASSERT_EQUAL(length(graph.edges), 7, "Two three-APC neighbor triangles need exactly one additional bridge")
	TEST_ASSERT_NOTNULL(graph.edge_between(first_tip.address, second_tip.address), "The bridge must join the physically closest pair between disconnected clusters")
	var/datum/netrun_path_tree/tree = allocate(/datum/netrun_path_tree, graph, ordered_nodes[1])
	var/datum/component/netrun_node/last = ordered_nodes[6]
	TEST_ASSERT(tree.reached[last.address], "The shortest bridge must make both neighbor clusters routable")

/// Weighted routing must prefer a three-edge cable chain to a longer two-edge detour.
/datum/unit_test/netrun_geographic_weighted_path/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_topology/graph = allocate(/datum/netrun_topology)
	var/list/nodes = list()
	for(var/offset in list(0, 1, 2, 3, 10))
		var/obj/item/host = allocate(/obj/item, locate(origin.x + offset, origin.y, origin.z))
		var/datum/component/netrun_node/node = host.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
		nodes += node
		graph.nodes[node.address] = node
		graph.adjacency[node.address] = list()
	var/datum/component/netrun_node/source = nodes[1]
	var/datum/component/netrun_node/near_first = nodes[2]
	var/datum/component/netrun_node/near_second = nodes[3]
	var/datum/component/netrun_node/target = nodes[4]
	var/datum/component/netrun_node/detour = nodes[5]
	graph.add_edge(source.address, detour.address, "apc")
	graph.add_edge(detour.address, target.address, "apc")
	graph.add_edge(source.address, near_first.address, "apc")
	graph.add_edge(near_first.address, near_second.address, "apc")
	graph.add_edge(near_second.address, target.address, "apc")
	var/datum/netrun_path_tree/tree = allocate(/datum/netrun_path_tree, graph, source)
	var/list/expected = list(source.address, near_first.address, near_second.address, target.address)
	TEST_ASSERT_EQUAL(tree.costs[target.address], 3, "Three one-tile links must cost three deciseconds")
	TEST_ASSERT_EQUAL(json_encode(tree.addresses_to(target.address)), json_encode(expected), "Routing must minimize physical latency rather than edge count")

/// Moving a still-bound endpoint changes both live latency and the next cached table.
/datum/unit_test/netrun_geographic_moving_cost/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/area/room = scene.room(/area/netrun_route_test)
	scene.take(origin, room)
	var/turf/apc_spot = scene.take(get_step(origin, NORTH), room)
	var/turf/near_spot = scene.take(get_step(origin, EAST), room)
	var/turf/far_spot = scene.take(locate(origin.x + 10, origin.y, origin.z), room)
	scene.machine(/obj/machinery/power/apc, apc_spot)
	var/obj/machinery/computer/netrun_terminal/source = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	var/obj/machinery/computer/netrun_terminal/target = scene.machine(/obj/machinery/computer/netrun_terminal, near_spot)
	source.console.connection.wireless = FALSE
	var/datum/component/netrun_node/node = target.GetComponent(/datum/component/netrun_node)
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	var/datum/component/netrun_node/apc = node.bound_apc
	var/revision = graph.revision
	var/datum/netrun_path_tree/before = source.console.make_path_tree(TRUE)
	allocated += before
	TEST_ASSERT_EQUAL(before.costs[node.address], 2, "Two adjacent physical cables must cost two deciseconds")
	target.forceMove(far_spot)
	var/datum/netrun_path_tree/after = source.console.make_path_tree(TRUE)
	allocated += after
	TEST_ASSERT_EQUAL(node.bound_apc, apc, "Moving inside the same native area must keep the original APC")
	TEST_ASSERT_EQUAL(graph.revision, revision, "A cable length change must not rebuild structural topology")
	TEST_ASSERT_EQUAL(before.costs[node.address], 2, "The old UI snapshot must remain immutable")
	TEST_ASSERT_EQUAL(after.costs[node.address], 11, "The next server snapshot must refresh a changed cable cost")
	TEST_ASSERT_EQUAL(source.console.latency_to(node), 11, "Live command and ping latency must use actual world distances")
	TEST_ASSERT(after.geometry_revision > before.geometry_revision, "A changed physical cost must advance the table's geometry generation")

/// Uniform relay gateways work within a sector without storing a quadratic clique.
/datum/unit_test/netrun_geographic_relay_bucket/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/area/room = scene.room(/area/netrun_route_test)
	var/turf/first_spot = scene.take(origin, room)
	var/turf/second_spot = scene.take(locate(origin.x + 12, origin.y, origin.z), room)
	scene.machine(/obj/machinery/power/apc, scene.take(get_step(first_spot, NORTH), room))
	scene.machine(/obj/machinery/power/apc, scene.take(get_step(second_spot, NORTH), room))
	var/obj/machinery/ntnet_relay/first = scene.machine(/obj/machinery/ntnet_relay, first_spot)
	var/obj/machinery/ntnet_relay/second = scene.machine(/obj/machinery/ntnet_relay, second_spot)
	var/datum/component/netrun_node/first_node = first.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/second_node = second.GetComponent(/datum/component/netrun_node)
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	SSnetworks.station_network.setting_disabled = FALSE
	TEST_ASSERT(second_node.address in graph.neighbors(first_node.address), "Relays in the same sector must expose a gateway transition")
	var/list/edge = graph.edge_between(first_node.address, second_node.address)
	TEST_ASSERT_EQUAL(edge["kind"], "relay", "A virtual gateway must retain a real relay edge identity")
	for(var/list/physical as anything in graph.edges)
		TEST_ASSERT(physical["kind"] != "relay", "Quantum links must not allocate a quadratic physical edge list")
	var/datum/netrun_path_tree/tree = allocate(/datum/netrun_path_tree, graph, first_node)
	TEST_ASSERT_EQUAL(tree.costs[second_node.address], NETRUN_RELAY_LATENCY, "A same-sector relay transition must cost three deciseconds")
	TEST_ASSERT(tree.remote[second_node.address], "The shortest path must identify its relay transition")
	SSnetworks.station_network.setting_disabled = TRUE
	TEST_ASSERT(!netrun_link_available(first_node, second_node), "NTnet shutdown must disable the quantum gateway")
	var/datum/netrun_path_tree/local = allocate(/datum/netrun_path_tree, graph, first_node)
	TEST_ASSERT(local.costs[second_node.address] > NETRUN_RELAY_LATENCY, "The remaining same-sector physical route must retain its geographic cost")

/// Relay movement keeps the existing lockout, cooldown and destination key requirements.
/datum/unit_test/netrun_geographic_entity_gateway/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/area/first_room = scene.room(/area/engineering/netrun_route_test)
	var/area/second_room = scene.room(/area/medical/netrun_route_test)
	var/list/levels = multiz_gravity_test_levels()
	scene.mark_station(levels[1])
	var/turf/first_spot = scene.take(origin, first_room)
	var/turf/second_spot = scene.take(locate(80, 80, levels[1]), second_room, TRUE)
	scene.machine(/obj/machinery/power/apc, scene.take(get_step(first_spot, NORTH), first_room))
	scene.machine(/obj/machinery/power/apc, scene.take(get_step(second_spot, NORTH), second_room, TRUE))
	var/obj/machinery/ntnet_relay/first = scene.machine(/obj/machinery/ntnet_relay, first_spot)
	var/obj/machinery/ntnet_relay/second = scene.machine(/obj/machinery/ntnet_relay, second_spot)
	var/datum/component/netrun_node/first_node = first.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/second_node = second.GetComponent(/datum/component/netrun_node)
	SSnetrun.ensure_topology()
	SSnetworks.station_network.setting_disabled = FALSE
	var/mob/camera/netrun_entity/entity = allocate(/mob/camera/netrun_entity, origin, first_node)
	TEST_ASSERT(!entity.can_relay_hop(second_node), "An operational gateway must not grant entry into an unauthorized LAN")
	TEST_ASSERT(entity.console.store_file(new /datum/netrun_file("destination.key", NETRUN_FILE_KEY, second_node.network.passcode, 1, second_node.network.id)), "The destination key must occupy actual process memory")
	TEST_ASSERT(entity.console.store_file(new /datum/netrun_file("source.key", NETRUN_FILE_KEY, first_node.network.passcode, 1, first_node.network.id)), "A return key must make the reverse gateway independently authorized")
	TEST_ASSERT(entity.relay_hop(second_node), "A valid key and operational relay pair must permit a sector transition")
	TEST_ASSERT_EQUAL(entity.host_node, second_node, "A gateway transition must enter the real destination relay node")
	TEST_ASSERT_EQUAL(entity.console.node_level(second_node), NETRUN_ACCESS_GUEST, "Relay travel must not invent USER machine rights")
	TEST_ASSERT(entity.can_relay_hop(first_node), "The reverse gateway must otherwise be authorized before its cooldown is tested")
	TEST_ASSERT(!entity.relay_hop(first_node), "The standard hop cooldown must also gate relay transitions")
	entity.next_hop = world.time
	entity.console.intrusion.lockout_until = world.time + 10 SECONDS
	TEST_ASSERT(!entity.can_relay_hop(first_node), "A traced session must not use a relay gateway")
