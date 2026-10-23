/// Creating distant component B before nearer C must not force an unnecessarily long A-B cable.
/datum/unit_test/netrun_apc_minimum_component_bridges/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/area/room = scene.room(/area/netrun_route_test)
	var/list/groups = list()
	var/list/all_addresses = list()
	var/component_size = max(2, NETRUN_APC_NEIGHBORS + 1)
	for(var/x in list(30, 150, 60))
		var/list/members = list()
		for(var/offset in 0 to component_size - 1)
			var/turf/spot = scene.take(locate(x + offset, 30, origin.z), room, TRUE)
			var/obj/machinery/power/apc/apc = scene.machine(/obj/machinery/power/apc, spot)
			var/datum/component/netrun_node/node = apc.GetComponent(/datum/component/netrun_node)
			members += node.address
			all_addresses += node.address
		groups += list(members)
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	var/bridge_length = 0
	var/bridge_count = 0
	for(var/list/edge as anything in graph.edges)
		if(edge["kind"] != "apc" || !(edge["from"] in all_addresses) || !(edge["to"] in all_addresses))
			continue
		var/same_group = FALSE
		for(var/list/members as anything in groups)
			if((edge["from"] in members) && (edge["to"] in members))
				same_group = TRUE
		if(!same_group)
			bridge_count++
			bridge_length += edge["distance"]
	TEST_ASSERT_EQUAL(bridge_count, 2, "Three components require exactly two additional cables")
	TEST_ASSERT_EQUAL(bridge_length, 120 - 2 * (component_size - 1), "Bridge selection must minimize total added distance regardless of registration order")
	var/synchronous = json_encode(graph.edges)
	graph.invalidate()
	var/datum/netrun_apc_prebuild/prepared = new(graph)
	graph.apc_prebuild = prepared
	var/finished = FALSE
	for(var/i in 1 to 20000)
		var/before = prepared.comparisons
		if(prepared.advance(1))
			finished = TRUE
			break
		TEST_ASSERT(prepared.comparisons - before <= 1, "A background work unit must evaluate at most one physical distance")
	TEST_ASSERT(finished && prepared.valid_inputs(), "Incremental mesh construction must complete with valid inputs")
	graph.rebuild()
	TEST_ASSERT_EQUAL(json_encode(graph.edges), synchronous, "Background and immediate requests must publish the same deterministic mesh")

/// Endpoint churn must not discard valid speculative infrastructure work.
/datum/unit_test/netrun_apc_prebuild_survives_endpoint_changes/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = netrun_connected_test_area()
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	graph.invalidate()
	var/datum/netrun_apc_prebuild/job = new(graph)
	graph.apc_prebuild = job
	var/generation = job.generation
	var/obj/machinery/computer/netrun_terminal/client = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	TEST_ASSERT(job.valid_inputs(), "Registering/binding an endpoint does not change APC positions or neighbors")
	TEST_ASSERT_EQUAL(job.generation, generation, "The APC work item must retain its infrastructure generation")
	var/complete = FALSE
	for(var/i in 1 to 1000)
		if(job.advance(1))
			complete = TRUE
			break
	TEST_ASSERT(complete, "The original job must finish even while endpoints are added")
	graph.rebuild()
	TEST_ASSERT(!graph.dirty && QDELETED(job), "Publication must consume the original speculative job")
	var/datum/component/netrun_node/client_node = client.GetComponent(/datum/component/netrun_node)
	TEST_ASSERT_NOTNULL(graph.edge_between(client_node.address, client_node.bound_apc.address), "The same graph publication must include the new endpoint's cable")

/// Every resident must leave a destroyed host even though leave_node mutates its resident list.
/datum/unit_test/netrun_node_evacuation_keeps_all_residents/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = netrun_connected_test_area()
	var/obj/machinery/computer/netrun_terminal/source = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	var/datum/component/netrun_node/source_node = source.GetComponent(/datum/component/netrun_node)
	var/list/residents = list()
	for(var/i in 1 to 3)
		var/mob/camera/netrun_entity/entity = new(origin, source_node)
		scene.owned.Insert(1, entity)
		residents += entity
	TEST_ASSERT_EQUAL(length(source_node.entities), 3, "All fixture residents must share the doomed endpoint")
	qdel(source)
	for(var/mob/camera/netrun_entity/entity as anything in residents)
		TEST_ASSERT(!QDELETED(entity) && entity.host_node && entity.host_node != source_node, "Deleting a host must evacuate every resident, without skipping entries removed during iteration")

/// A sparse sector with fewer peers than K must not walk thousands of empty buckets.
/datum/unit_test/netrun_apc_spatial_sparse_sector/Run()
	var/list/addresses = list("A", "B", "C")
	var/list/positions = list("A" = locate(1, 1, run_loc_floor_bottom_left.z), "B" = locate(230, 230, run_loc_floor_bottom_left.z), "C" = locate(1, 230, run_loc_floor_bottom_left.z))
	var/datum/netrun_apc_spatial_index/spatial = allocate(/datum/netrun_apc_spatial_index, addresses, positions)
	var/datum/netrun_apc_neighbor_scan/scan = allocate(/datum/netrun_apc_neighbor_scan, spatial, "A")
	var/steps = 0
	while(!scan.advance() && steps < 10)
		steps++
	TEST_ASSERT(scan.done && steps <= 3, "A three-APC sector should finish after scanning its three occupied positions")
	TEST_ASSERT_EQUAL(scan.comparisons, 2, "Each actual peer must be measured once")
	TEST_ASSERT_EQUAL(length(scan.best), 2, "A small sector must retain every existing peer")

/// Native machine resources can already be gone when its node announces removal.
/datum/unit_test/netrun_node_online_after_teardown/Run()
	var/obj/machinery/door/airlock/door = allocate(/obj/machinery/door/airlock)
	var/datum/component/netrun_node/node = door.GetComponent(/datum/component/netrun_node)
	TEST_ASSERT_NOTNULL(node, "A real airlock must expose a network endpoint")
	qdel(door)
	TEST_ASSERT(QDELETED(node), "Deleting a machine must delete its endpoint")
	TEST_ASSERT(!node.is_online(), "A deleted endpoint must be offline without reading torn-down native wires")
