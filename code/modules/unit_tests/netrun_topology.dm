/// Inspect the public map payload rather than duplicating its BFS implementation.
/datum/unit_test/proc/netrun_map_has_node(list/payload, address)
	var/list/map = payload["map"]
	for(var/list/node as anything in map?["nodes"])
		if(node["address"] == address)
			return TRUE
	return FALSE

/// Map initialization registers an early distant APC, then a client, then its actual nearest APC.
/datum/unit_test/netrun_topology_mapload_binding_order/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/area/room = scene.room(/area/netrun_route_test)
	scene.take(origin, room)
	var/turf/early_spot = scene.take(run_loc_floor_top_right, room)
	var/turf/nearest_spot = scene.take(get_step(origin, NORTH), room)
	var/list/created = list()
	SSatoms.map_loader_begin()
	var/obj/machinery/power/apc/early = new(early_spot)
	created += early
	var/obj/machinery/computer/netrun_terminal/client = new(origin)
	created += client
	var/obj/machinery/power/apc/nearest = new(nearest_spot)
	created += nearest
	SSatoms.map_loader_stop()
	scene.owned += created
	SSatoms.InitializeAtoms(created)
	for(var/obj/machinery/machine as anything in created)
		machine.set_machine_stat(0)
	SSnetrun.ensure_topology()
	var/datum/component/netrun_node/client_node = client.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/nearest_node = nearest.GetComponent(/datum/component/netrun_node)
	TEST_ASSERT_EQUAL(client_node.uplink_node(), nearest_node, "A maploaded client must choose the nearest APC after all mapped infrastructure is registered, rather than retaining the early distant APC")
	var/obj/machinery/power/apc/later = scene.machine(/obj/machinery/power/apc, origin)
	SSnetrun.ensure_topology()
	TEST_ASSERT_EQUAL(client_node.uplink_node(), nearest_node, "After normal startup a newly installed closer APC must preserve the established binding")
	TEST_ASSERT(!QDELETED(later), "The closer post-startup fixture must exist when binding stability is checked")

/// Endpoints initialized before map infrastructure must acquire one structural, stable uplink.
/datum/unit_test/netrun_topology_binding_lifecycle/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/area/client_room = scene.room(/area/medical/netrun_route_test)
	var/area/power_room = scene.room(/area/engineering/netrun_route_test)
	scene.take(origin, client_room)
	var/turf/first_spot = scene.take(locate(origin.x + 3, origin.y, origin.z), power_room)
	var/turf/closer_spot = scene.take(get_step(origin, EAST), power_room)
	var/obj/machinery/computer/netrun_terminal/client = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	var/datum/component/netrun_node/client_node = client.GetComponent(/datum/component/netrun_node)
	SSnetrun.ensure_topology()
	TEST_ASSERT_NULL(client_node.uplink_node(), "An endpoint must not invent an APC before any infrastructure exists in its sector")
	var/obj/machinery/power/apc/first = scene.machine(/obj/machinery/power/apc, first_spot)
	var/datum/component/netrun_node/first_node = first.GetComponent(/datum/component/netrun_node)
	SSnetrun.ensure_topology()
	TEST_ASSERT_EQUAL(client_node.uplink_node(), first_node, "A previously unbound endpoint must discover an APC created later in another area")
	TEST_ASSERT_EQUAL(client_node.network, first_node.network, "The bound APC must define the endpoint's security domain instead of its own area")
	var/datum/netrun_network/original_network = client_node.network
	first.set_machine_stat(BROKEN)
	var/obj/machinery/power/apc/closer = scene.machine(/obj/machinery/power/apc, closer_spot)
	var/datum/component/netrun_node/closer_node = closer.GetComponent(/datum/component/netrun_node)
	var/datum/netrun_topology/topology = SSnetrun.ensure_topology()
	TEST_ASSERT_EQUAL(client_node.uplink_node(), first_node, "Failure and a newly installed closer APC must not silently steal an established endpoint")
	TEST_ASSERT_EQUAL(client_node.network, original_network, "An offline APC must retain its endpoint's key and access domain")
	var/list/neighbors = topology.adjacency[client_node.address]
	TEST_ASSERT_EQUAL(length(neighbors), 1, "An endpoint must have exactly one structural attachment")
	TEST_ASSERT(first_node.address in neighbors, "The sole edge must still terminate at the original offline APC")
	qdel(first)
	SSnetrun.ensure_topology()
	TEST_ASSERT_EQUAL(client_node.uplink_node(), closer_node, "Deleting the bound APC must release the dead binding and select remaining infrastructure")
	TEST_ASSERT_EQUAL(client_node.network, original_network, "Rebinding to another APC of the same department keeps the clustered LAN security domain")

/// Movement inside one root area preserves the cable; crossing a root area or sector rebinds it.
/datum/unit_test/netrun_topology_binding_movement/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/area/first_room = scene.room(/area/engineering/netrun_route_test)
	var/area/second_room = scene.room(/area/medical/netrun_route_test)
	scene.take(origin, first_room)
	var/turf/near_second = scene.take(locate(origin.x + 3, origin.y, origin.z), first_room)
	var/turf/across_area = scene.take(locate(origin.x + 3, origin.y + 1, origin.z), second_room)
	var/turf/first_apc_spot = scene.take(get_step(origin, NORTH), first_room)
	var/turf/second_apc_spot = scene.take(locate(origin.x + 4, origin.y, origin.z), second_room)
	var/list/levels = multiz_gravity_test_levels()
	scene.mark_station(levels[1])
	var/turf/remote_spot = scene.take(locate(80, 80, levels[1]), second_room, TRUE)
	var/turf/remote_apc_spot = scene.take(locate(81, 80, levels[1]), second_room, TRUE)
	var/obj/machinery/power/apc/first = scene.machine(/obj/machinery/power/apc, first_apc_spot)
	var/obj/machinery/power/apc/second = scene.machine(/obj/machinery/power/apc, second_apc_spot)
	var/obj/machinery/power/apc/remote = scene.machine(/obj/machinery/power/apc, remote_apc_spot)
	var/obj/machinery/computer/netrun_terminal/client = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	var/datum/component/netrun_node/client_node = client.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/first_node = first.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/second_node = second.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/remote_node = remote.GetComponent(/datum/component/netrun_node)
	SSnetrun.ensure_topology()
	TEST_ASSERT_EQUAL(client_node.uplink_node(), first_node, "Initial attachment must use the closest APC in the local sector")
	client.forceMove(near_second)
	SSnetrun.ensure_topology()
	TEST_ASSERT_EQUAL(client_node.uplink_node(), first_node, "Moving closer to another APC inside the same root area must preserve the binding")
	client.forceMove(across_area)
	SSnetrun.ensure_topology()
	TEST_ASSERT_EQUAL(client_node.uplink_node(), second_node, "Crossing into a new root area must choose the closest structural APC again")
	client.forceMove(remote_spot)
	SSnetrun.ensure_topology()
	TEST_ASSERT_EQUAL(client_node.uplink_node(), remote_node, "Crossing sectors must rebind even when the root area instance is unchanged")

/// The sector backbone is a connected tree with one copy of each undirected APC edge.
/datum/unit_test/netrun_topology_apc_tree/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/area/room = scene.room(/area/engineering/netrun_route_test)
	var/list/addresses = list()
	for(var/x_offset in list(0, 2, 4))
		var/turf/spot = scene.take(locate(origin.x + x_offset, origin.y, origin.z), room)
		var/obj/machinery/power/apc/apc = scene.machine(/obj/machinery/power/apc, spot)
		var/datum/component/netrun_node/node = apc.GetComponent(/datum/component/netrun_node)
		addresses += node.address
	var/turf/fourth_spot = scene.take(locate(origin.x + 4, origin.y + 3, origin.z), room)
	var/obj/machinery/power/apc/fourth = scene.machine(/obj/machinery/power/apc, fourth_spot)
	var/datum/component/netrun_node/fourth_node = fourth.GetComponent(/datum/component/netrun_node)
	addresses += fourth_node.address
	var/turf/relay_spot = scene.take(get_step(origin, NORTH), room)
	var/obj/machinery/ntnet_relay/relay = scene.machine(/obj/machinery/ntnet_relay, relay_spot)
	var/datum/component/netrun_node/relay_node = relay.GetComponent(/datum/component/netrun_node)
	var/datum/netrun_topology/topology = SSnetrun.ensure_topology()
	var/list/pairs = list()
	var/edge_count = 0
	for(var/list/edge as anything in topology.edges)
		if(edge["kind"] != "apc" || !(edge["from"] in addresses) || !(edge["to"] in addresses))
			continue
		TEST_ASSERT(edge["from"] != edge["to"], "The APC tree must not include self-loops")
		var/forward = "[edge["from"]]|[edge["to"]]"
		var/backward = "[edge["to"]]|[edge["from"]]"
		TEST_ASSERT(!pairs[forward] && !pairs[backward], "An undirected APC edge must be published only once")
		pairs[forward] = TRUE
		edge_count++
	TEST_ASSERT_EQUAL(edge_count, length(addresses) - 1, "Four APCs must form a minimal tree with exactly N-1 edges")
	var/list/visited = list(addresses[1])
	var/list/frontier = list(addresses[1])
	while(length(frontier))
		var/address = frontier[1]
		frontier.Cut(1, 2)
		for(var/neighbor in topology.adjacency[address])
			if((neighbor in addresses) && !(neighbor in visited))
				visited += neighbor
				frontier += neighbor
	TEST_ASSERT_EQUAL(length(visited), length(addresses), "The N-1 APC edges must connect all actual APCs, rather than leave a cycle and an orphan")
	var/list/relay_neighbors = topology.adjacency[relay_node.address]
	TEST_ASSERT_EQUAL(length(relay_neighbors), 1, "A lone quantum relay must attach to exactly one APC in its sector")
	var/datum/component/netrun_node/relay_apc = relay_node.uplink_node()
	TEST_ASSERT_NOTNULL(relay_apc, "A real quantum relay must have a structural APC uplink")
	TEST_ASSERT(relay_apc.address in relay_neighbors, "The published relay edge must match the relay's cached APC binding")
	var/previous_revision = topology.revision
	var/previous_edges = json_encode(topology.edges)
	fourth.set_machine_stat(BROKEN)
	SSnetrun.ensure_topology()
	TEST_ASSERT_EQUAL(topology.revision, previous_revision, "A temporary APC failure must not rebuild the structural graph")
	TEST_ASSERT_EQUAL(json_encode(topology.edges), previous_edges, "An offline APC must retain the cached tree's edges")

/// The full permitted map follows connectivity, independently of distance or old BFS depth.
/datum/unit_test/netrun_topology_map_depth_and_latency/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/area/room = scene.room(/area/engineering/netrun_route_test)
	for(var/turf/spot as anything in block(origin, locate(origin.x + 4, origin.y + 1, origin.z)))
		scene.take(spot, room)
	var/obj/machinery/power/apc/first = scene.machine(/obj/machinery/power/apc, get_step(origin, NORTH))
	var/obj/machinery/power/apc/second = scene.machine(/obj/machinery/power/apc, locate(origin.x + 2, origin.y + 1, origin.z))
	var/obj/machinery/power/apc/third = scene.machine(/obj/machinery/power/apc, locate(origin.x + 4, origin.y + 1, origin.z))
	var/obj/machinery/computer/netrun_terminal/source = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	var/obj/machinery/computer/netrun_terminal/far_peer = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	var/obj/machinery/computer/netrun_terminal/near_peer = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	var/obj/machinery/computer/netrun_terminal/three_hops = scene.machine(/obj/machinery/computer/netrun_terminal, locate(origin.x + 2, origin.y, origin.z))
	SSnetrun.ensure_topology()
	var/datum/component/netrun_node/source_node = source.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/far_node = far_peer.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/near_node = near_peer.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/three_hops_node = three_hops.GetComponent(/datum/component/netrun_node)
	var/far_x = origin.x > world.maxx / 2 ? origin.x - 60 : origin.x + 60
	var/far_y = origin.y > world.maxy / 2 ? origin.y - 60 : origin.y + 60
	var/turf/far_spot = scene.take(locate(far_x, far_y, origin.z), room, TRUE)
	far_peer.forceMove(far_spot)
	three_hops.forceMove(get_step(origin, EAST))
	SSnetrun.ensure_topology()
	TEST_ASSERT(get_dist(source, far_peer) > 40, "The far fixture must lie outside the former tile radius")
	TEST_ASSERT_EQUAL(get_dist(source, three_hops), 1, "The excluded three-hop fixture must be physically adjacent")
	TEST_ASSERT_EQUAL(far_node.uplink_node(), source_node.uplink_node(), "The far peer must retain its original APC across movement inside the same root area")
	TEST_ASSERT_NOTEQUAL(three_hops_node.uplink_node(), source_node.uplink_node(), "The physically nearby peer must retain the other APC attachment")
	for(var/obj/machinery/power/apc/apc as anything in list(first, second, third))
		var/datum/component/netrun_node/node = apc.GetComponent(/datum/component/netrun_node)
		TEST_ASSERT(source.console.store_file(new /datum/netrun_file("[node.address].key", NETRUN_FILE_KEY, node.network.passcode, 1, node.network.id)), "The public map test needs legitimate keys for its security domains")
	source.console.map_view.selected_address = source_node.address
	var/list/payload = source.console.ui_data(null)
	TEST_ASSERT(netrun_map_has_node(payload, far_node.address), "A two-edge peer must be loaded even when physically far away")
	TEST_ASSERT(netrun_map_has_node(payload, three_hops_node.address), "A permitted peer beyond the old two-edge neighborhood must be included")
	TEST_ASSERT_EQUAL(source.console.latency_to(far_node), source.console.latency_to(near_node), "Equal graph paths must have equal latency regardless of tile distance")
	TEST_ASSERT(source.console.latency_to(three_hops_node) > source.console.latency_to(far_node), "An extra APC edge must increase latency even when its target is physically close")
	TEST_ASSERT(source.console.store_file(netrun_daemon_file("mapper")), "The mapper daemon must fit in the test console")
	payload = source.console.ui_data(null)
	TEST_ASSERT(netrun_map_has_node(payload, three_hops_node.address), "Installing mapper must preserve already permitted distant endpoints")

/// Permissions do not let an entity jump over intermediate graph nodes.
/datum/unit_test/netrun_topology_entity_neighbors/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/area/room = scene.room(/area/engineering/netrun_route_test)
	scene.take(origin, room)
	var/turf/apc_spot = scene.take(get_step(origin, NORTH), room)
	var/turf/peer_spot = scene.take(get_step(origin, EAST), room)
	var/obj/machinery/power/apc/apc = scene.machine(/obj/machinery/power/apc, apc_spot)
	var/obj/machinery/computer/netrun_terminal/source = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	var/obj/machinery/computer/netrun_terminal/peer = scene.machine(/obj/machinery/computer/netrun_terminal, peer_spot)
	SSnetrun.ensure_topology()
	var/datum/component/netrun_node/source_node = source.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/peer_node = peer.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/apc_node = apc.GetComponent(/datum/component/netrun_node)
	var/mob/camera/netrun_entity/entity = new(origin, source_node)
	scene.owned.Insert(1, entity)
	TEST_ASSERT(entity.console.store_file(new /datum/netrun_file/access("network-engineer.access", list(ACCESS_NETWORK, ACCESS_ENGINE_EQUIP))), "The entity needs actual matching credentials for actions independently of LAN traversal")
	TEST_ASSERT(entity.console.node_level(peer_node) >= NETRUN_ACCESS_USER, "The peer must be authorized independently of graph adjacency")
	TEST_ASSERT(!entity.can_enter(peer_node), "An entity must not jump directly between two endpoints behind the same APC")
	TEST_ASSERT(entity.can_enter(apc_node), "The immediate online APC neighbor must be eligible")
	TEST_ASSERT(entity.hop(apc_node), "A legal hop must enter the adjacent APC")
	TEST_ASSERT_EQUAL(entity.host_node, apc_node, "The successful hop must update the entity's actual host")
	TEST_ASSERT(entity.can_enter(peer_node), "After entering the APC its endpoint must become an immediate neighbor")

/// Shared CLI pools keep protected endpoints hidden and cannot retain a revoked key across updates.
/datum/unit_test/netrun_cli_completion_access_scope/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/area/engineering = scene.room(/area/engineering/netrun_route_test)
	var/area/medical = scene.room(/area/medical/netrun_route_test)
	scene.take(origin, engineering)
	var/turf/first_apc_spot = scene.take(get_step(origin, NORTH), engineering)
	var/turf/target_spot = scene.take(locate(origin.x + 4, origin.y, origin.z), medical)
	var/turf/second_apc_spot = scene.take(get_step(target_spot, NORTH), medical)
	scene.machine(/obj/machinery/power/apc, first_apc_spot)
	var/obj/machinery/power/apc/medical_apc = scene.machine(/obj/machinery/power/apc, second_apc_spot)
	var/obj/machinery/computer/netrun_terminal/source = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	var/obj/machinery/computer/netrun_terminal/target = scene.machine(/obj/machinery/computer/netrun_terminal, target_spot)
	SSnetrun.ensure_topology()
	var/datum/component/netrun_node/target_node = target.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/apc_node = medical_apc.GetComponent(/datum/component/netrun_node)
	TEST_ASSERT(source.console.can_route(target_node), "The protected endpoint must be physically reachable before testing disclosure")
	TEST_ASSERT(source.console.store_file(netrun_daemon_file("mapper")), "The mapper must fit so map visibility cannot accidentally grant CLI disclosure")
	var/list/payload = source.console.ui_data(null)
	var/list/cli = payload["cli"]
	var/list/pools = cli["completions"]
	var/list/node_addresses = pools["nodes"]
	TEST_ASSERT_NOTNULL(node_addresses, "The public CLI payload must expose its shared address completion pool")
	TEST_ASSERT(!(target_node.address in node_addresses), "Mapper must not leak a locked endpoint into ordinary CLI completion")
	TEST_ASSERT(apc_node.address in node_addresses, "The protected LAN's structural APC must remain discoverable")
	TEST_ASSERT(!(apc_node.network.code in node_addresses), "Combining breach targets must not append network codes to the shared node-address pool")
	var/datum/netrun_file/key = new("medical.key", NETRUN_FILE_KEY, target_node.network.passcode, 1, target_node.network.id)
	TEST_ASSERT(source.console.store_file(key), "The legitimate network key must fit in memory")
	TEST_ASSERT(key in source.console.all_files(TRUE), "The new key must belong to the current inventory before its UI projection is requested")
	TEST_ASSERT(source.console.has_key(target_node.network, TRUE), "Fresh key authorization must recognize the stored file before generating CLI disclosure")
	payload = source.console.ui_data(null)
	cli = payload["cli"]
	pools = cli["completions"]
	node_addresses = pools["nodes"]
	TEST_ASSERT(target_node.address in node_addresses, "The next UI update must include an endpoint revealed by its legitimate key")
	source.console.delete_local_file(key)
	payload = source.console.ui_data(null)
	cli = payload["cli"]
	pools = cli["completions"]
	node_addresses = pools["nodes"]
	TEST_ASSERT(!(target_node.address in node_addresses), "A shared completion cache must expire with the request and honor key revocation on the next update")

/// Display paths are retained on the server, copied for clients, and refreshed
/// periodically; a stale display path must never authorize a real request.
/datum/unit_test/netrun_server_route_tables/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/area/room = scene.room(/area/netrun_route_test)
	scene.take(origin, room)
	var/turf/apc_spot = scene.take(get_step(origin, NORTH), room)
	var/turf/target_spot = scene.take(get_step(origin, EAST), room)
	var/obj/machinery/power/apc/apc = scene.machine(/obj/machinery/power/apc, apc_spot)
	var/obj/machinery/computer/netrun_terminal/source = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	var/obj/machinery/computer/netrun_terminal/target = scene.machine(/obj/machinery/computer/netrun_terminal, target_spot)
	var/datum/component/netrun_node/source_node = source.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/target_node = target.GetComponent(/datum/component/netrun_node)
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	var/datum/netrun_path_tree/snapshot = source.console.make_path_tree(TRUE)
	allocated += snapshot
	var/datum/netrun_path_tree/stored = graph.route_tables[source_node.address]
	TEST_ASSERT_NOTNULL(stored, "Opening a map must retain its routing table on the server")
	TEST_ASSERT_NOTEQUAL(snapshot, stored, "A UI request must receive a copy rather than own the retained routing table")
	snapshot.reached.Cut()
	TEST_ASSERT(stored.reached[target_node.address], "A client-specific routing restriction must not mutate the shared server table")
	var/previous_revision = stored.revision
	apc.set_machine_stat(BROKEN)
	TEST_ASSERT(stored.reached[target_node.address], "The previous display snapshot must remain stable until its scheduled refresh")
	TEST_ASSERT(!source.console.can_route(target_node), "A real request must immediately detect a broken APC without trusting the retained display path")
	graph.route_refresh_at = world.time
	graph.refresh_route_tables()
	stored = graph.route_tables[source_node.address]
	TEST_ASSERT(stored.revision > previous_revision, "The scheduled refresh must advance the retained route revision")
	TEST_ASSERT(!stored.reached[target_node.address], "A refreshed server table must remove a path through broken infrastructure")
	source.console.map_view.selected_address = target_node.address
	var/list/payload = source.console.ui_data(null)
	var/list/map = payload["map"]
	var/list/selected_route = map["route"]
	TEST_ASSERT(!selected_route["reachable"], "The map must publish the selected target's unreachable server route, rather than a fictitious direct path")
	graph.route_used[source_node.address] = world.time - 3 * SSnetrun.wait
	graph.route_refresh_at = world.time
	graph.refresh_route_tables()
	TEST_ASSERT_NULL(graph.route_tables[source_node.address], "An inactive map's routing table must expire instead of doing BFS forever")

/// Nested targets need no movement signal: the subsystem's membership poll
/// invalidates their cached paths, and the next server snapshot uses the new APC.
/datum/unit_test/netrun_server_routes_carried_target/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/area/first_room = scene.room(/area/netrun_route_test)
	var/area/second_room = scene.room(/area/netrun_route_test)
	scene.take(origin, first_room)
	var/turf/first_spot = scene.take(get_step(origin, NORTH), first_room)
	var/turf/second_spot = scene.take(locate(origin.x + 4, origin.y, origin.z), second_room)
	var/turf/second_apc_spot = scene.take(get_step(second_spot, NORTH), second_room)
	scene.machine(/obj/machinery/power/apc, first_spot)
	var/obj/machinery/power/apc/second = scene.machine(/obj/machinery/power/apc, second_apc_spot)
	var/obj/machinery/computer/netrun_terminal/source = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	var/obj/item/carrier = allocate(/obj/item, origin)
	var/obj/item/target = allocate(/obj/item, carrier)
	var/datum/component/netrun_node/target_node = target.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
	var/datum/component/netrun_node/second_node = second.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/source_node = source.GetComponent(/datum/component/netrun_node)
	var/datum/netrun_path_tree/before = source.console.make_path_tree(TRUE)
	allocated += before
	var/list/old_path = before.addresses_to(target_node.address)
	carrier.forceMove(second_spot)
	TEST_ASSERT_EQUAL(target_node.binding_area, first_room, "Moving a carrier must not fake a MOVED signal on its nested item")
	target_node.join_network() // The same membership poll used by SSnetrun.fire().
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	graph.refresh_route_tables()
	var/datum/netrun_path_tree/after = source.console.make_path_tree(TRUE)
	allocated += after
	var/list/new_path = after.addresses_to(target_node.address)
	TEST_ASSERT_EQUAL(target_node.bound_apc, second_node, "The periodic membership poll must bind a carried target to its destination APC")
	TEST_ASSERT_NOTEQUAL(json_encode(old_path), json_encode(new_path), "The retained route must change after a carried target crosses its root area")
	TEST_ASSERT_EQUAL(after.previous[target_node.address], second_node.address, "The saved route's final forwarding hop must be the new APC")
	TEST_ASSERT_NOTNULL(graph.route_tables[source_node.address], "The changed path must remain stored on the server after the UI copy is released")
