/**
 * Offline tests of the clean-master NetDM module. No native DLL or Host
 * required: the registry and object lifecycle must remain usable alone.
 */
/datum/unit_test/netdm_bridge_strict_radio_booleans/Run()
	var/datum/netdm_bridge/bridge = new
	var/json_enabled = bridge.netdm_serialize_command(list("op" = "game_radio", "a" = 1, "enabled" = TRUE))
	var/json_disabled = bridge.netdm_serialize_command(list("op" = "game_radio", "a" = 1, "enabled" = FALSE))
	TEST_ASSERT(findtext(json_enabled, "\"enabled\":true"), "Radio on must emit a strict JSON boolean")
	TEST_ASSERT(findtext(json_disabled, "\"enabled\":false"), "Radio off must emit a strict JSON boolean")
	TEST_ASSERT(findtext(bridge.netdm_serialize_command(list("op" = "packet_send", "trafficClass" = 1)),
		"\"trafficClass\":1"), "Packet class must remain a number")
	var/list/radio_batch = list("op" = "game_radio_batch", "changes" = list(
		list("op" = "game_radio", "a" = 1, "enabled" = TRUE),
		list("op" = "game_radio", "a" = 2, "enabled" = FALSE)))
	var/batch_json = bridge.netdm_serialize_command(radio_batch)
	TEST_ASSERT(findtext(batch_json, "\"enabled\":true"), "Radio batch enable must be a JSON boolean")
	TEST_ASSERT(findtext(batch_json, "\"enabled\":false"), "Radio batch disable must be a JSON boolean")
	qdel(bridge)

/datum/unit_test/netdm_component_registry/Run()
	var/obj/a = allocate(/obj, run_loc_floor_bottom_left)
	var/obj/b = allocate(/obj, get_step(run_loc_floor_bottom_left, EAST))
	var/datum/component/netdm_node/node_a = a.netdm_connect()
	var/datum/component/netdm_node/node_b = b.netdm_connect()
	TEST_ASSERT_NOTNULL(node_a, "The first network component must attach")
	TEST_ASSERT_NOTNULL(node_b, "The second network component must attach")
	TEST_ASSERT(node_a.node_id > 0 && node_b.node_id > 0, "Endpoint IDs must be positive")
	TEST_ASSERT_NOTEQUAL(node_a.node_id, node_b.node_id, "Endpoint IDs must be unique")

	var/id_a = node_a.node_id
	var/id_b = node_b.node_id
	TEST_ASSERT_EQUAL(SSnetdm.endpoints_by_id["[id_a]"], node_a, "First endpoint must be registered")
	TEST_ASSERT_EQUAL(SSnetdm.endpoints_by_id["[id_b]"], node_b, "Second endpoint must be registered")
	TEST_ASSERT_EQUAL(a.netdm_interface(), node_a, "Component lookup must not allocate duplicates")

	TEST_ASSERT(SSnetdm.connect_nodes(node_a, node_b), "Wired connection must succeed")
	TEST_ASSERT(SSnetdm.connect_nodes(node_a, node_b), "Connecting twice must be idempotent")
	TEST_ASSERT_EQUAL(length(SSnetdm.links), 1, "Must keep one physical link")
	TEST_ASSERT(SSnetdm.disconnect_nodes(node_a, node_b), "Physical disconnection must succeed")
	TEST_ASSERT_EQUAL(length(SSnetdm.links), 0, "Removed link must disappear")
	TEST_ASSERT(SSnetdm.connect_nodes(node_a, node_b), "A disconnected pair can reconnect")

	var/turf/target = get_step(run_loc_floor_bottom_left, NORTH)
	a.forceMove(target)
	node_a.sync_position()
	TEST_ASSERT_EQUAL(node_a.last_x, target.x, "Moved endpoint must update X")
	TEST_ASSERT_EQUAL(node_a.last_y, target.y, "Moved endpoint must update Y")

	qdel(a)
	TEST_ASSERT_NULL(SSnetdm.endpoints_by_id["[id_a]"], "Deleted object must unregister its endpoint")
	TEST_ASSERT_EQUAL(length(SSnetdm.links), 0, "Removing an endpoint must clean up its links")
	qdel(b)
	TEST_ASSERT_NULL(SSnetdm.endpoints_by_id["[id_b]"], "Second object must unregister")

/// Regression: newly spawned network objects must enqueue live Host mutations.
/datum/unit_test/netdm_live_registration_updates/Run()
	var/was_connected = SSnetdm.connected
	var/was_synchronized = SSnetdm.synchronized
	var/was_synchronizing = SSnetdm.synchronizing
	var/list/previous_commands = SSnetdm.topology_commands.Copy()
	SSnetdm.connected = TRUE
	SSnetdm.synchronized = TRUE
	SSnetdm.synchronizing = FALSE
	SSnetdm.topology_commands.Cut()

	var/obj/device = allocate(/obj, run_loc_floor_bottom_left)
	var/datum/component/netdm_node/endpoint = device.netdm_connect()
	var/id = endpoint.node_id
	TEST_ASSERT_EQUAL(length(SSnetdm.topology_commands), 2, "New node must queue add + radio without bridge restart")
	var/list/add_command = SSnetdm.topology_commands[1]
	var/list/radio_command = SSnetdm.topology_commands[2]
	TEST_ASSERT_EQUAL(add_command["op"], "game_add_node", "First mutation must register the node")
	TEST_ASSERT_EQUAL(radio_command["op"], "game_radio", "Second mutation must configure radio")

	var/list/first_batch = SSnetdm.build_live_batch()
	TEST_ASSERT_EQUAL(first_batch["op"], "game_batch", "Node mutations use the game topology batch")
	TEST_ASSERT_EQUAL(SSnetdm.live_batch_count, 1, "Batch must stop before a radio command")
	SSnetdm.topology_commands.Cut(1, 2)
	var/list/second_batch = SSnetdm.build_live_batch()
	TEST_ASSERT_EQUAL(second_batch["op"], "game_radio_batch", "Radio mutations use the strict radio batch")

	SSnetdm.connected = FALSE
	qdel(device)
	SSnetdm.retired_ids -= "[id]"
	SSnetdm.topology_commands = previous_commands
	SSnetdm.live_batch_count = 0
	SSnetdm.connected = was_connected
	SSnetdm.synchronized = was_synchronized
	SSnetdm.synchronizing = was_synchronizing

/// Any anchored machine routes through its area's APC; moving devices use radio.
/datum/unit_test/netdm_apc_area_and_backbone/Run()
	var/turf/spot = run_loc_floor_bottom_left
	var/obj/machinery/power/apc/apc = allocate(/obj/machinery/power/apc, spot)
	var/obj/machinery/computer/console = allocate(/obj/machinery/computer, spot)
	var/datum/component/netdm_node/apc_node = apc.netdm_interface()
	var/datum/component/netdm_node/console_node = console.netdm_interface()
	TEST_ASSERT_NOTNULL(apc_node, "Standard APC automatically registers with NetDM")
	TEST_ASSERT_NOTNULL(console_node, "Standard stationary computer automatically registers with NetDM")
	TEST_ASSERT(apc_node.radio_enabled, "APC must provide wireless access into its wired backbone")
	TEST_ASSERT(!console_node.radio_enabled, "Anchored computer must be wired")
	TEST_ASSERT(SSnetdm.apc_backbone.Find(apc_node), "APC must participate in backbone")
	qdel(console)
	qdel(apc)

/// APCs must never be joined solely by their location in a global
/// coordinate-sorted list. Only the boundary scanner can add those edges.
/datum/unit_test/netdm_apc_backbone_requires_border/Run()
	var/turf/first_position = run_loc_floor_bottom_left
	var/turf/second_position = locate(first_position.x, first_position.y, first_position.z)
	var/obj/machinery/power/apc/first = allocate(/obj/machinery/power/apc, first_position)
	var/obj/machinery/power/apc/second = allocate(/obj/machinery/power/apc, second_position)
	var/datum/component/netdm_node/first_node = first.netdm_interface()
	var/datum/component/netdm_node/second_node = second.netdm_interface()
	TEST_ASSERT_NOTNULL(first_node, "First APC must register")
	TEST_ASSERT_NOTNULL(second_node, "Second APC must register")
	var/key = SSnetdm.link_key(first_node.node_id, second_node.node_id)
	TEST_ASSERT_NULL(SSnetdm.links[key], "APC insertion must not create an arbitrary direct link")
	qdel(first)
	qdel(second)

/datum/unit_test/netdm_relay_sector_identity/Run()
	var/turf/position = run_loc_floor_bottom_left
	TEST_ASSERT(!!SSnetdm.sector_key(position), "Any world turf must have an addressable sector")
	TEST_ASSERT_EQUAL(SSnetdm.sector_key(position), SSnetdm.sector_key(position), "Sector addressing must be stable")


/// Cluster state is shared by all R&D servers in one research network.
/// A second purchase request cannot spend points or grant a bounty twice.
/datum/unit_test/netdm_rnd_cluster_atomic_research/Run()
	var/datum/techweb/isolated/web = new
	allocated += web
	var/datum/netdm_rnd_cluster/cluster = new(web)
	allocated += cluster
	var/node_id
	for(var/id in web.available_nodes)
		if(!web.researched_nodes[id])
			node_id = id
			break
	TEST_ASSERT_NOTNULL(node_id, "Isolated techweb must have at least one researchable node")
	web.add_point_list(list(TECHWEB_POINT_TYPE_GENERIC = 100000), FALSE)
	var/list/request = list("rpc_id" = "netdm-test-write-1",
		"op" = "research", "node_id" = node_id, "actor" = "unit_test")
	var/list/first = cluster.execute(request)
	TEST_ASSERT(first["ok"], "Cluster must accept an affordable research purchase")
	var/balance = web.research_points[TECHWEB_POINT_TYPE_GENERIC]
	var/list/replay = cluster.execute(request)
	TEST_ASSERT(replay["ok"], "Duplicate request receives its original result")
	TEST_ASSERT_EQUAL(web.research_points[TECHWEB_POINT_TYPE_GENERIC], balance, "Request replay must not spend points again")
	TEST_ASSERT(web.researched_nodes[node_id], "Cluster research must update the authoritative web")
	var/list/next = cluster.execute(list("rpc_id" = "netdm-test-write-2", "op" = "research",
		"node_id" = node_id, "actor" = "unit_test"))
	TEST_ASSERT(!next["ok"], "A different request cannot research an already unlocked node")

/// No R&D server means no available cluster endpoint.
/datum/unit_test/netdm_rnd_cluster_requires_server/Run()
	var/datum/techweb/isolated/web = new
	allocated += web
	var/datum/netdm_rnd_cluster/cluster = new(web)
	allocated += cluster
	TEST_ASSERT_NULL(cluster.find_server(run_loc_floor_bottom_left), "Empty R&D cluster must be offline")


/// Server snapshots must not permanently reduce globally shared costs
/// when a network has boosted one node.
/datum/unit_test/netdm_research_price_snapshot_immutable/Run()
	var/datum/techweb/web = new
	allocated += web
	var/datum/techweb_node/chosen
	for(var/id in SSresearch.techweb_nodes)
		var/datum/techweb_node/candidate = SSresearch.techweb_nodes[id]
		if(candidate.research_costs[TECHWEB_POINT_TYPE_GENERIC] > 1)
			chosen = candidate
			break
	TEST_ASSERT_NOTNULL(chosen, "Expected a research node with a nonzero generic point cost")
	var/initial_price = chosen.research_costs[TECHWEB_POINT_TYPE_GENERIC]
	web.boosted_nodes[chosen.id] = list(TECHWEB_POINT_TYPE_GENERIC = 1)
	var/list/price = chosen.get_price(web)
	TEST_ASSERT_EQUAL(price[TECHWEB_POINT_TYPE_GENERIC], initial_price - 1, "Boost must reduce the local price")
	TEST_ASSERT_EQUAL(chosen.research_costs[TECHWEB_POINT_TYPE_GENERIC], initial_price, "Snapshot pricing must never mutate the shared global design")


/// One networked problem answer consumes one shared charge and applies
/// its reward exactly once, even if another server receives a retry.
/datum/unit_test/netdm_problem_computer_atomic_charge/Run()
	var/datum/techweb/isolated/web = new
	allocated += web
	var/datum/netdm_rnd_cluster/cluster = new(web)
	allocated += cluster
	var/old_charges = web.get_problem_computer_charges()
	var/old_points = web.research_points[TECHWEB_POINT_TYPE_GENERIC] || 0
	TEST_ASSERT(old_charges > 0, "Fresh research web must have problem charges")
	var/list/request = list("op" = "solve_problem", "rpc_id" = "netdm-problem-once", "difficulty" = "Easy", "correct" = TRUE)
	var/list/result = cluster.execute(request)
	TEST_ASSERT(result["ok"], "Problem Computer answer accepted")
	TEST_ASSERT_EQUAL(web.get_problem_computer_charges(), old_charges - 1, "One charge was consumed")
	TEST_ASSERT_EQUAL(web.research_points[TECHWEB_POINT_TYPE_GENERIC], old_points + 750, "Server credited the correct reward")
	cluster.execute(request)
	TEST_ASSERT_EQUAL(web.get_problem_computer_charges(), old_charges - 1, "Retry must not consume another charge")
	TEST_ASSERT_EQUAL(web.research_points[TECHWEB_POINT_TYPE_GENERIC], old_points + 750, "Retry must not credit again")
