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
	var/list/payload = source.console.ui_data(null)
	TEST_ASSERT(netrun_map_has_node(payload, target_node.address), "The complete permitted graph must include endpoints beyond four edges")
	var/list/map = payload["map"]
	var/structural = map["structure_revision"]
	var/state = map["state_revision"]
	payload = source.console.ui_data(null)
	map = payload["map"]
	TEST_ASSERT_EQUAL(map["structure_revision"], structural, "A repeated poll must reuse the structural generation")
	TEST_ASSERT_EQUAL(map["state_revision"], state, "A repeated unchanged poll must reuse the state generation")
	target.set_machine_stat(BROKEN)
	target_node.reconcile_state()
	payload = source.console.ui_data(null)
	map = payload["map"]
	TEST_ASSERT(netrun_map_has_node(payload, target_node.address), "An offline leaf remains a discoverable endpoint")
	TEST_ASSERT_EQUAL(map["structure_revision"], structural, "An offline leaf must not trigger a new layout generation")
	TEST_ASSERT(map["state_revision"] > state, "Native availability changes must publish a new status generation")
	var/old_address = target_node.address
	qdel(target)
	payload = source.console.ui_data(null)
	map = payload["map"]
	TEST_ASSERT(!netrun_map_has_node(payload, old_address), "Deleting a node must remove it on the next update without reopening UI")
	TEST_ASSERT(map["structure_revision"] > structural, "Removing a visible node must advance the projection generation")
	for(var/list/edge as anything in map["edges"])
		TEST_ASSERT(edge["from"] != old_address && edge["to"] != old_address, "Deleted endpoints must not leave dangling map edges")

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
