/// The test reservation lies in /area/space, which has no wired zone. Tests build their own zones.
/// `new` returns the one instance of an area type, so every distinct zone needs its own type.
/area/netdm_test
	name = "netDM test zone"
	requires_power = FALSE

/area/netdm_test/first
/area/netdm_test/second
/area/netdm_test/third
/area/netdm_test/fourth

/datum/unit_test/netdm_observe
	var/list/original_areas = list()

/datum/unit_test/netdm_observe/Destroy()
	// APCs go before their turfs return to the original zones.
	for(var/obj/machinery/power/apc/apc in allocated)
		qdel(apc, force = TRUE)
	for(var/turf/tile as anything in original_areas)
		assign_area(tile, original_areas[tile])
	return ..()

/// Test zones are never deleted: the next `new` of the type would return the deleted instance.
/// Emptied of turfs, a zone has no geometry and no APC.
/datum/unit_test/netdm_observe/proc/test_zone(zone_type)
	var/area/zone = GLOB.areas_by_type[zone_type]
	return zone || new zone_type

/datum/unit_test/netdm_observe/proc/assign_area(turf/tile, area/replacement)
	var/area/old = get_area(tile)
	if(old == replacement)
		return
	if(!original_areas[tile])
		original_areas[tile] = old
	replacement.contents.Add(tile)
	tile.change_area(old, replacement)

/// The first publication exports the whole map while the test world is busy starting up.
/datum/unit_test/netdm_observe/proc/wait_until_live()
	var/deadline = world.time + 3 MINUTES
	while(world.time < deadline)
		if(SSnetdm_observe.published && SSnetdm_observe.phase == "live" && !SSnetdm_observe.pending)
			return TRUE
		sleep(5)
	return FALSE

/// Every geometry change re-exports the APC map, so a change waits for a whole export.
/datum/unit_test/netdm_observe/proc/wait_for_fact(datum/weakref/key, turf/position)
	var/deadline = world.time + 60 SECONDS
	while(world.time < deadline)
		if(SSnetdm_observe.phase == "live" && !SSnetdm_observe.pending)
			var/list/fact = SSnetdm_observe.known?[key]
			if(!position && !fact)
				return TRUE
			if(position && fact && fact["x"] == position.x && fact["y"] == position.y && fact["z"] == position.z)
				return fact
		sleep(1)
	return FALSE

/datum/unit_test/netdm_observe/Run()
	if(world.GetConfig("env", "NETDM_IPC_MODE") != "v1")
		TEST_ASSERT_NULL(SSnetdm_observe.bridge, "Observe must be disabled by default.")
		return
	TEST_ASSERT(wait_until_live(), "Observe must publish the initial map ([SSnetdm_observe.observe_state()]).")

	var/turf/destination = get_step(run_loc_floor_bottom_left, EAST)
	var/area/zone = test_zone(/area/netdm_test/first)
	assign_area(run_loc_floor_bottom_left, zone)
	assign_area(destination, zone)
	var/obj/machinery/power/apc/apc = allocate(/obj/machinery/power/apc, run_loc_floor_bottom_left)
	var/datum/weakref/key = WEAKREF(apc)
	var/list/initial = wait_for_fact(key, run_loc_floor_bottom_left)
	var/stream = SSnetdm_observe.bridge.stream_id
	apc.forceMove(destination)
	var/list/moved = wait_for_fact(key, destination)
	qdel(apc, force = TRUE)
	var/removed = wait_for_fact(key, null)
	TEST_ASSERT(initial, "Observe must publish a live APC to the Host ([SSnetdm_observe.observe_state()]).")
	TEST_ASSERT(moved, "Observe must publish movement to the Host.")
	TEST_ASSERT_EQUAL(initial["a"], moved["a"], "A move must preserve the APC wire identity.")
	TEST_ASSERT(removed, "Observe must publish deletion to the Host.")
	TEST_ASSERT_EQUAL(SSnetdm_observe.bridge.stream_id, stream, "APC updates must preserve the session stream.")

/datum/unit_test/netdm_observe/area_map
	var/http_base

/datum/unit_test/netdm_observe/area_map/proc/read_map(z)
	var/datum/http_response/response = world_safe_http_get("[http_base]/api/game/map?z=[z]", 3 SECONDS)
	if(response?.status_code == 200)
		return json_decode(response.body)
	return null

/// Failure detail: runs the exporter on the live inventory and keeps the facts of `node_ids`.
/datum/unit_test/netdm_observe/area_map/proc/export_probe(list/node_ids)
	var/datum/netdm_apc_map_export/probe = new(SSnetdm_observe.known.Copy())
	var/deadline = world.time + 60 SECONDS
	while(!probe.advance() && world.time < deadline)
		stoplag()
	var/list/kept = list()
	for(var/list/fact in probe.facts)
		if((fact["a"] in node_ids) || (fact["area"] in node_ids))
			kept += list(fact)
	var/turf/origin = run_loc_floor_bottom_left
	var/list/zone_names = list()
	for(var/area/zone in probe.zones)
		zone_names += "[zone.type]:[REF(zone)]"
	return "probe(error=[probe.error] phase=[probe.phase] zones=[length(probe.zones)] levels=[json_encode(probe.levels)] \
		rows=[length(probe.rows)] origin=[origin.z]/[origin.y] zone_list=[json_encode(zone_names)] facts=[json_encode(kept)])"

/datum/unit_test/netdm_observe/area_map/proc/host_nodes(list/map, list/node_ids)
	var/list/kept = list()
	for(var/list/node in map?["nodes"])
		if(node["id"] in node_ids)
			kept += list(node)
	return kept

/datum/unit_test/netdm_observe/area_map/proc/links_for(list/map, node_id)
	for(var/list/node in map?["nodes"])
		if(node["id"] == node_id)
			return node["links"]
	return null

/datum/unit_test/netdm_observe/area_map/Run()
	if(world.GetConfig("env", "NETDM_IPC_MODE") != "v1")
		return
	http_base = world.GetConfig("env", "NETDM_TEST_HTTP")
	TEST_ASSERT(length(http_base), "NETDM_TEST_HTTP must point to the test Host.")
	TEST_ASSERT(wait_until_live(), "Observe must publish the initial map ([SSnetdm_observe.observe_state()]).")
	var/turf/left = run_loc_floor_bottom_left
	var/turf/middle = get_step(left, EAST)
	var/upper_z = left.z == 1 ? 2 : 1
	var/turf/upper_middle = locate(left.x, left.y, upper_z)
	var/turf/upper_right = get_step(upper_middle, EAST)
	TEST_ASSERT(middle && upper_middle && upper_right, "Expected adjacent test cells on two levels.")

	var/area/left_area = test_zone(/area/netdm_test/first)
	var/area/middle_area = test_zone(/area/netdm_test/second)
	var/area/right_area = test_zone(/area/netdm_test/third)
	var/area/gap_area = test_zone(/area/netdm_test/fourth)
	// One zone on two levels, served by one APC. Runtime areas avoid base_area links:
	// power_change() recursion through sub_areas is not safe for areas created at runtime.
	assign_area(left, left_area)
	assign_area(middle, middle_area)
	assign_area(upper_middle, middle_area)
	assign_area(upper_right, right_area)

	var/obj/machinery/power/apc/left_apc = allocate(/obj/machinery/power/apc, left)
	var/obj/machinery/power/apc/middle_apc = allocate(/obj/machinery/power/apc, middle)
	var/obj/machinery/power/apc/right_apc = allocate(/obj/machinery/power/apc, upper_right)
	var/list/left_fact = wait_for_fact(WEAKREF(left_apc), left)
	var/list/middle_fact = wait_for_fact(WEAKREF(middle_apc), middle)
	var/list/right_fact = wait_for_fact(WEAKREF(right_apc), upper_right)
	TEST_ASSERT(left_fact && middle_fact && right_fact, "Expected all APCs to be published.")
	var/stream = SSnetdm_observe.bridge.stream_id
	var/list/lower_map = read_map(left.z)
	var/found_edge = FALSE
	for(var/list/edge in lower_map?["edges"])
		if((edge["a"] == left_fact["a"] && edge["b"] == middle_fact["a"]) || (edge["b"] == left_fact["a"] && edge["a"] == middle_fact["a"]))
			found_edge = TRUE
			break
	var/datum/weakref/left_root = left_fact["root"]
	var/area/left_known_root = left_root?.resolve()
	var/area/left_tile_area = get_area(left)
	TEST_ASSERT(found_edge, "Shared side on the lower level must create an APC edge. apc.area=[left_apc.area?.type]:[REF(left_apc.area)] \
		tile=[left_tile_area?.type]:[REF(left_tile_area)] zone=[REF(left_area)] root=[left_known_root?.type]:[REF(left_known_root)] \
		primary=[left_fact["primary"]] [export_probe(list(left_fact["a"], middle_fact["a"]))] host=[json_encode(host_nodes(lower_map, list(left_fact["a"], middle_fact["a"])))]")
	var/list/before = read_map(upper_z)
	var/before_links = links_for(before, right_fact["a"])
	TEST_ASSERT(before_links > 0, "The linked area on the upper level must connect its neighbor to the shared APC.")
	TEST_ASSERT_EQUAL(before["streamId"], stream, "Observe and HTTP must show the same stream.")

	var/sequence = SSnetdm_observe.fact_sequence
	assign_area(upper_middle, gap_area)
	// Node deltas also advance the fact sequence: wait for the map revision that includes the edit.
	var/revision = SSnetdm_observe.geometry_revision
	var/deadline = world.time + 60 SECONDS
	while(world.time < deadline && !(SSnetdm_observe.published_revision >= revision && SSnetdm_observe.phase == "live" && !SSnetdm_observe.pending))
		sleep(1)
	TEST_ASSERT(SSnetdm_observe.published_revision >= revision && SSnetdm_observe.fact_sequence > sequence, "Geometry-only edit must publish a live map revision.")
	var/list/after = read_map(upper_z)
	TEST_ASSERT_NOTNULL(after, "Expected the updated graph from the Host.")
	TEST_ASSERT_EQUAL(links_for(after, right_fact["a"]), before_links - 1, "The edit must remove the cross-level APC link.")
	TEST_ASSERT_EQUAL(after["streamId"], stream, "Updating geometry must preserve the stream.")

/obj/netdm_test_node
	name = "netDM test node"
	anchored = TRUE

/obj/netdm_test_crate
	name = "netDM test crate"

/datum/unit_test/netdm_observe/area_map/proc/host_node(z, node_id)
	for(var/list/node in read_map(z)?["nodes"])
		if(node["id"] == node_id)
			return node
	return null

/datum/unit_test/netdm_observe/area_map/proc/has_edge(z, a, b)
	for(var/list/edge in read_map(z)?["edges"])
		if((edge["a"] == a && edge["b"] == b) || (edge["a"] == b && edge["b"] == a))
			return TRUE
	return FALSE

/// The last fact the Host acknowledged for `node`, once it matches the expected effective turf.
/datum/unit_test/netdm_observe/area_map/proc/wait_for_node(datum/component/netdm_node/node, turf/position, anchored)
	var/deadline = world.time + 60 SECONDS
	while(world.time < deadline)
		var/list/fact = SSnetdm_observe.node_facts[node]
		if(fact && !SSnetdm_observe.dirty_nodes[node] && isnull(SSnetdm_observe.inflight_facts) \
			&& fact["x"] == position.x && fact["y"] == position.y && fact["z"] == position.z && fact["anchored"] == (anchored ? 1 : 0))
			return fact
		sleep(1)
	return null

/// A node component reports facts; the Host chooses a wired APC port or radio and follows changes.
/datum/unit_test/netdm_observe/area_map/node_attachment

/datum/unit_test/netdm_observe/area_map/node_attachment/Run()
	if(world.GetConfig("env", "NETDM_IPC_MODE") != "v1")
		var/obj/netdm_test_node/inert = allocate(/obj/netdm_test_node, run_loc_floor_bottom_left)
		TEST_ASSERT_NULL(netdm_make_node(inert), "Without Observe objects must not become nodes.")
		return
	http_base = world.GetConfig("env", "NETDM_TEST_HTTP")
	TEST_ASSERT(length(http_base), "NETDM_TEST_HTTP must point to the test Host.")
	TEST_ASSERT(wait_until_live(), "Observe must publish the initial map ([SSnetdm_observe.observe_state()]).")
	var/turf/left = run_loc_floor_bottom_left
	var/turf/right = get_step(left, EAST)
	TEST_ASSERT_NOTNULL(right, "Expected two adjacent test cells.")
	var/area/served = test_zone(/area/netdm_test/first)
	assign_area(left, served)
	assign_area(right, served)
	var/obj/machinery/power/apc/apc = allocate(/obj/machinery/power/apc, left)
	var/list/apc_fact = wait_for_fact(WEAKREF(apc), left)
	TEST_ASSERT(apc_fact, "Expected the zone APC to be published.")
	var/stream = SSnetdm_observe.bridge.stream_id

	var/obj/netdm_test_node/machine = allocate(/obj/netdm_test_node, right)
	var/datum/component/netdm_node/node = netdm_make_node(machine, NETDM_MOUNT_FIXED, 3)
	TEST_ASSERT_NOTNULL(node, "Observe must turn the object into a node.")
	var/list/fact = wait_for_node(node, right, TRUE)
	TEST_ASSERT(fact, "The anchored node must reach the Host.")
	var/node_id = fact["a"]
	var/list/host = host_node(right.z, node_id)
	TEST_ASSERT(host && host["links"] == 1 && !host["radioEnabled"], "An anchored fixed node takes one wired port.")
	TEST_ASSERT(has_edge(right.z, node_id, apc_fact["a"]), "The wired port leads to the APC of its zone.")

	machine.set_anchored(FALSE)
	TEST_ASSERT(wait_for_node(node, right, FALSE), "Unanchoring must reach the Host.")
	host = host_node(right.z, node_id)
	TEST_ASSERT(host && host["links"] == 0 && host["radioEnabled"], "An unanchored node drops the wired port for radio.")

	var/obj/netdm_test_crate/crate = allocate(/obj/netdm_test_crate, right)
	machine.set_anchored(TRUE)
	machine.forceMove(crate)
	crate.forceMove(left)
	TEST_ASSERT(wait_for_node(node, left, FALSE), "A stored node reports the turf of its container, never anchored.")
	machine.forceMove(right)
	TEST_ASSERT(wait_for_node(node, right, TRUE), "Back on its turf the node is anchored again.")
	TEST_ASSERT(has_edge(right.z, node_id, apc_fact["a"]), "Re-anchoring restores the wired port.")

	var/obj/netdm_test_node/handset = allocate(/obj/netdm_test_node, left)
	var/datum/component/netdm_node/mobile = netdm_make_node(handset, NETDM_MOUNT_MOBILE, 3)
	var/list/mobile_fact = wait_for_node(mobile, left, TRUE)
	TEST_ASSERT(mobile_fact, "The mobile node must reach the Host.")
	host = host_node(left.z, mobile_fact["a"])
	TEST_ASSERT(host && host["radioEnabled"] && !has_edge(left.z, mobile_fact["a"], apc_fact["a"]), "A mobile node stays on radio while anchored.")

	qdel(machine)
	var/deadline = world.time + 60 SECONDS
	while(world.time < deadline && host_node(right.z, node_id))
		sleep(5)
	TEST_ASSERT_NULL(host_node(right.z, node_id), "Destroying the object must remove its node.")
	TEST_ASSERT_EQUAL(SSnetdm_observe.bridge.stream_id, stream, "Node updates must preserve the session stream.")

/// The admin topology screen asks the Host for its level and receives the published graph.
/datum/unit_test/netdm_observe/area_map/topology_view

/datum/unit_test/netdm_observe/area_map/topology_view/Run()
	if(world.GetConfig("env", "NETDM_IPC_MODE") != "v1")
		return
	TEST_ASSERT(wait_until_live(), "Observe must publish the initial map ([SSnetdm_observe.observe_state()]).")
	var/turf/left = run_loc_floor_bottom_left
	assign_area(left, test_zone(/area/netdm_test/first))
	var/obj/machinery/power/apc/apc = allocate(/obj/machinery/power/apc, left)
	var/list/fact = wait_for_fact(WEAKREF(apc), left)
	TEST_ASSERT(fact, "Expected the APC to be published.")

	var/datum/netdm_topology_view/view = new(null)
	view.z = left.z
	SSnetdm_observe.next_view_poll = 0
	var/list/row
	var/deadline = world.time + 60 SECONDS
	while(world.time < deadline && !row)
		var/list/data = view.ui_data(null)
		for(var/list/node in data["nodes"])
			if(node[1] == fact["a"])
				row = node
				break
		if(!row)
			sleep(5)
	var/list/data = view.ui_data(null)
	qdel(view)
	TEST_ASSERT(row, "The view must list the APC of its level ([json_encode(data["error"])]).")
	TEST_ASSERT_EQUAL(row[2], left.x, "The view must report the APC position.")
	TEST_ASSERT(row[4] & 16 && row[4] & 4, "The view must flag an APC with its access point.")
	TEST_ASSERT_NOTNULL(data["version"], "The view must carry the Host version.")
	TEST_ASSERT(!(view in SSnetdm_observe.viewers), "A closed screen must stop polling.")

/obj/machinery/netdm_test_machine
	name = "netDM test machine"
	anchored = TRUE
	use_power = NO_POWER_USE

/// Waits until the Host shows `node_id` on level `z` with `links` links and the given radio state.
/datum/unit_test/netdm_observe/area_map/proc/wait_for_links(z, node_id, links, radio)
	var/deadline = world.time + 60 SECONDS
	while(world.time < deadline)
		var/list/node = host_node(z, node_id)
		if(node && node["links"] == links && !!node["radioEnabled"] == radio)
			return TRUE
		sleep(5)
	return FALSE

/// Waits until Observe has acknowledged `state` for the APC `apc_id`; an APC without an entry is up.
/datum/unit_test/netdm_observe/area_map/proc/wait_for_apc_state(apc_id, state)
	var/deadline = world.time + 10 SECONDS
	while(world.time < deadline)
		var/stored = SSnetdm_observe.apc_states[apc_id]
		if((isnull(stored) ? NETDM_STATE_UP : stored) == state)
			return TRUE
		sleep(1)
	return FALSE

/// network.diagnostics on two neighbouring APCs: the network module of one names the other with its state,
/// and names the cause when the neighbour loses power. The request and the answer are network commands
/// to the APC's own node, answered by the Host on its behalf.
/datum/unit_test/netdm_observe/area_map/network_diagnostics

/datum/unit_test/netdm_observe/area_map/network_diagnostics/proc/ask(obj/machinery/power/apc/apc)
	var/datum/netdm_diagnostics/diagnostics = SSnetdm_observe.diagnostics
	var/answered = diagnostics.counters["answered"]
	if(!diagnostics.inspect(apc, null))
		return null
	var/deadline = world.time + 30 SECONDS
	while(world.time < deadline && diagnostics.counters["answered"] == answered && length(diagnostics.pending))
		sleep(2)
	return diagnostics.counters["answered"] > answered ? diagnostics.last_report : null

/datum/unit_test/netdm_observe/area_map/network_diagnostics
	var/list/page

/datum/unit_test/netdm_observe/area_map/network_diagnostics/proc/take_page(list/answer)
	page = answer

/// One page of the service directory as `asker` gets it from `apc`.
/datum/unit_test/netdm_observe/area_map/network_diagnostics/proc/query(datum/asker, obj/machinery/power/apc/apc, service_type, limit = 8, cursor, prefix, max_hops, projection)
	page = null
	if(!SSnetdm_observe.diagnostics.query_services(asker, apc, service_type, CALLBACK(src, PROC_REF(take_page)), limit, cursor, prefix, max_hops, projection))
		return null
	var/deadline = world.time + 30 SECONDS
	while(world.time < deadline && !page)
		sleep(2)
	return page

/datum/unit_test/netdm_observe/area_map/network_diagnostics/proc/query_instance(datum/asker, obj/machinery/power/apc/apc, instance, read_state = FALSE)
	page = null
	var/datum/netdm_diagnostics/diagnostics = SSnetdm_observe.diagnostics
	var/datum/callback/on_answer = CALLBACK(src, PROC_REF(take_page))
	if(!(read_state ? diagnostics.query_state(asker, apc, instance, on_answer) : diagnostics.query_schema(asker, apc, instance, on_answer)))
		return null
	var/deadline = world.time + 15 SECONDS
	while(world.time < deadline && !page)
		sleep(2)
	return page

/datum/unit_test/netdm_observe/area_map/network_diagnostics/Run()
	if(world.GetConfig("env", "NETDM_IPC_MODE") != "v1")
		return
	http_base = world.GetConfig("env", "NETDM_TEST_HTTP")
	TEST_ASSERT(length(http_base), "NETDM_TEST_HTTP must point to the test Host.")
	TEST_ASSERT(wait_until_live(), "Observe must publish the initial map ([SSnetdm_observe.observe_state()]).")
	var/datum/netdm_diagnostics/diagnostics = SSnetdm_observe.diagnostics
	TEST_ASSERT(diagnostics, "Observe must run network diagnostics.")
	var/turf/left = run_loc_floor_bottom_left
	var/turf/right = get_step(left, EAST)
	TEST_ASSERT_NOTNULL(right, "Expected two adjacent test cells.")
	assign_area(left, test_zone(/area/netdm_test/first))
	assign_area(right, test_zone(/area/netdm_test/second))
	var/obj/machinery/power/apc/near = allocate(/obj/machinery/power/apc, left)
	var/obj/machinery/power/apc/far = allocate(/obj/machinery/power/apc, right)
	var/list/near_fact = wait_for_fact(WEAKREF(near), left)
	var/list/far_fact = wait_for_fact(WEAKREF(far), right)
	TEST_ASSERT(near_fact && far_fact, "Expected both APCs to be published.")
	var/near_id = near_fact["a"]
	var/far_id = far_fact["a"]
	TEST_ASSERT(wait_for_links(left.z, near_id, 1, TRUE), "The two zones must be wired together ([json_encode(host_node(left.z, near_id))]).")

	var/list/report = ask(near)
	TEST_ASSERT(report, "The APC must answer its multitool: [diagnostics.state()] [SSnetdm_observe.services.state()]")
	var/list/neighbors = report["neighbors"]
	TEST_ASSERT(report["state"] == "active" && report["wired"] == 1 && report["wired_up"] == 1 && neighbors[far_id] == "up",
		"A healthy APC reports its neighbour up: [json_encode(report)]")
	TEST_ASSERT(report["radio"], "The APC reports its radio access point: [json_encode(report)]")
	TEST_ASSERT(findtext(jointext(report["lines"], " "), get_area_name(far, TRUE)), "The report names the neighbour's zone: [json_encode(report["lines"])]")

	// The neighbour's breaker opens: the cable carries nothing, and the report says whose fault it is.
	far.operating = FALSE
	TEST_ASSERT(wait_for_links(left.z, near_id, 0, TRUE), "The cable to a dead APC carries nothing ([json_encode(host_node(left.z, near_id))]).")
	report = ask(near)
	neighbors = report?["neighbors"]
	TEST_ASSERT(report && report["state"] == "active" && report["wired"] == 1 && report["wired_up"] == 0 && neighbors[far_id] == "unpowered",
		"The APC names its unpowered neighbour: [json_encode(report)] [diagnostics.state()]")
	// The dead module itself answers nothing: a device without power is silent.
	var/silent = diagnostics.counters["no_answer"]
	TEST_ASSERT(isnull(ask(far)), "An APC without power must not answer.")
	var/deadline = world.time + 15 SECONDS
	while(world.time < deadline && diagnostics.counters["no_answer"] == silent)
		sleep(5)
	TEST_ASSERT_EQUAL(diagnostics.counters["no_answer"], silent + 1, "The silent APC is reported as no answer: [diagnostics.state()]")

	far.operating = TRUE
	TEST_ASSERT(wait_for_links(left.z, near_id, 1, TRUE), "Closing the breaker restores the cable.")
	report = ask(far)
	neighbors = report?["neighbors"]
	TEST_ASSERT(report && report["state"] == "active" && neighbors[near_id] == "up", "The repaired APC answers again: [json_encode(report)] [diagnostics.state()]")
	TEST_ASSERT_EQUAL(diagnostics.counters["refused"], 0, "No request may be refused: [diagnostics.state()]")

	// State watch: a machine on the near APC's port subscribes to that APC. Its state arrives without a
	// request, and again whenever a port changes.
	var/obj/machinery/netdm_test_machine/watcher = allocate(/obj/machinery/netdm_test_machine, left)
	var/datum/component/netdm_node/watcher_node = netdm_make_node(watcher, NETDM_MOUNT_FIXED, 3)
	TEST_ASSERT(wait_for_node(watcher_node, left, TRUE), "The watching machine must reach the Host.")
	var/instance = diagnostics.watch(watcher_node, near)
	TEST_ASSERT(instance, "The machine must be able to watch the APC: [diagnostics.state()]")
	var/list/seen
	deadline = world.time + 30 SECONDS
	while(world.time < deadline)
		seen = diagnostics.link_states[instance]
		if(seen?["neighbors"]?[far_id] == "up" && seen["devices"] >= 1)
			break
		sleep(5)
	TEST_ASSERT(seen?["neighbors"]?[far_id] == "up" && seen["state"] == "active",
		"A watched APC publishes its state: [json_encode(seen)] [diagnostics.state()] [SSnetdm_observe.services.state()]")
	far.operating = FALSE
	deadline = world.time + 30 SECONDS
	while(world.time < deadline)
		seen = diagnostics.link_states[instance]
		if(seen["neighbors"][far_id] == "unpowered")
			break
		sleep(5)
	TEST_ASSERT(seen["neighbors"][far_id] == "unpowered" && seen["wired_up"] == 0,
		"The watcher learns of the dead neighbour without asking: [json_encode(seen)] [diagnostics.state()]")
	var/events = diagnostics.counters["events"]
	sleep(3 SECONDS)
	TEST_ASSERT_EQUAL(diagnostics.counters["events"], events, "An unchanged state is not published again.")
	far.operating = TRUE
	deadline = world.time + 30 SECONDS
	while(world.time < deadline)
		seen = diagnostics.link_states[instance]
		if(seen["neighbors"][far_id] == "up")
			break
		sleep(5)
	TEST_ASSERT(seen["neighbors"][far_id] == "up", "The watcher learns of the repair: [json_encode(seen)] [diagnostics.state()]")

	// network.query: the machine asks its APC which services the network offers. Two pumps stand behind
	// the far APC; they are listed while the network reaches them and absent when it does not.
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	var/obj/machinery/netdm_test_machine/pump = allocate(/obj/machinery/netdm_test_machine, right)
	var/datum/component/netdm_node/pump_node = netdm_make_node(pump, NETDM_MOUNT_FIXED, 3)
	TEST_ASSERT(wait_for_node(pump_node, right, TRUE), "The pump must reach the Host.")
	var/datum/netdm_service_endpoint/pump_endpoint = lane.endpoint_for(pump_node)
	var/list/pumps = list("qtest.[pump_endpoint.id].a", "qtest.[pump_endpoint.id].b")
	for(var/name in pumps)
		lane.offer(pump_node, name, "machine.control", "machine.power_state", 1)
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && !(lane.ready(pump_node, pumps[1]) && lane.ready(pump_node, pumps[2])))
		sleep(5)
	TEST_ASSERT(lane.ready(pump_node, pumps[2]), "The pumps must be registered: [lane.state()]")
	var/list/schema = query_instance(watcher_node, near, pumps[1])
	TEST_ASSERT(schema?["status"] == "complete" && schema["schema"] == "machine.power_state" && schema["major"] == 1 && schema["commands"] == "set_power",
		"The query returns the pump's registered contract: [json_encode(schema)]")
	var/list/publication = query_instance(watcher_node, near, pumps[1], TRUE)
	TEST_ASSERT(publication?["status"] == "complete" && publication["publication"] == "idle" && publication["sequence"] == "0",
		"A reachable pump has not published yet: [json_encode(publication)]")
	TEST_ASSERT(lane.publish(pump_node, pumps[1], list("on" = TRUE, "changed" = TRUE)), "The pump can publish a value.")
	publication = query_instance(watcher_node, near, pumps[1], TRUE)
	TEST_ASSERT(publication?["publication"] == "published" && publication["sequence"] == "1" && isnull(publication["on"]),
		"The publication sequence is visible without exposing the value: [json_encode(publication)]")
	var/list/listed = query(watcher_node, near, "machine.control")
	var/list/names = list()
	for(var/list/row in listed?["items"])
		names += row["instance"]
	TEST_ASSERT(listed?["status"] == "complete" && (pumps[1] in names) && (pumps[2] in names),
		"The query lists the services the network reaches: [json_encode(listed)] [diagnostics.state()]")
	for(var/list/row in listed["items"])
		if(row["instance"] == pumps[1])
			TEST_ASSERT_EQUAL(row["hops"], 2, "The pump is two hops from the near APC: [json_encode(row)]")
	var/list/first_page = query(watcher_node, near, "machine.control", 1)
	TEST_ASSERT(first_page?["status"] == "partial" && length(first_page["items"]) == 1 && first_page["cursor"],
		"A page of one names its cursor: [json_encode(first_page)]")
	var/list/second_page = query(watcher_node, near, "machine.control", 1, first_page["cursor"])
	TEST_ASSERT(length(second_page?["items"]) == 1 && second_page["items"][1]["instance"] != first_page["items"][1]["instance"],
		"The cursor continues after the first page: [json_encode(second_page)]")
	var/list/near_only = query(watcher_node, near, "machine.control", max_hops = 1, projection = "instance")
	var/list/far_named = query(watcher_node, near, null, prefix = pumps[1], projection = "instance_type")
	var/pumps_near = 0
	for(var/list/row in near_only?["items"])
		if(row["instance"] in pumps)
			pumps_near++
	TEST_ASSERT(near_only?["status"] && near_only["status"] != "invalid_cursor" && !pumps_near && length(far_named?["items"]) == 1 && far_named["items"][1]["instance"] == pumps[1] && far_named["items"][1]["type"] == "machine.control" && isnull(far_named["items"][1]["hops"]),
		"Hops, prefix and projection narrow the page: [json_encode(near_only)] [json_encode(far_named)]")
	far.operating = FALSE
	TEST_ASSERT(wait_for_links(left.z, near_id, 1, TRUE), "The near APC keeps only its machine while the far one is dead.")
	listed = query(watcher_node, near, "machine.control")
	names = list()
	for(var/list/row in listed?["items"])
		names += row["instance"]
	TEST_ASSERT(listed && !(pumps[1] in names) && !(pumps[2] in names),
		"Services behind a dead APC are absent from the answer: [json_encode(listed)]")
	schema = query_instance(watcher_node, near, pumps[1])
	TEST_ASSERT_EQUAL(schema?["status"], "empty", "A cut-off service no longer exposes its contract.")
	publication = query_instance(watcher_node, near, pumps[1], TRUE)
	TEST_ASSERT_EQUAL(publication?["status"], "empty", "A cut-off service no longer exposes its publication state.")
	far.operating = TRUE
	TEST_ASSERT(wait_for_links(left.z, near_id, 2, TRUE), "The cable returns with the far APC.")
	listed = query(watcher_node, near, "machine.control")
	TEST_ASSERT(length(listed?["items"]) >= 2, "The repaired network lists the pumps again: [json_encode(listed)]")
	publication = query_instance(watcher_node, near, pumps[1], TRUE)
	TEST_ASSERT_EQUAL(publication?["sequence"], "1", "Reconnecting the APC exposes the same service publication again.")

	// WatchQuery: the machine watches the directory its APC reaches. It hears that the set changed,
	// without names, when a service appears and when the network stops reaching some.
	var/watched = diagnostics.watch_services(watcher_node, near)
	TEST_ASSERT(watched, "The machine must be able to watch the directory: [diagnostics.state()]")
	var/list/directory
	deadline = world.time + 30 SECONDS
	while(world.time < deadline)
		directory = diagnostics.directory_states[watched]
		if(directory?["services"] >= 2)
			break
		sleep(5)
	TEST_ASSERT(directory?["services"] >= 2 && length(directory["digest"]) == 16, "A watched directory publishes its state: [json_encode(directory)] [diagnostics.state()] [lane.state()]")
	var/known_services = directory["services"]
	var/known_digest = directory["digest"]
	lane.offer(pump_node, "qtest.[pump_endpoint.id].c", "machine.control", "machine.power_state", 1)
	deadline = world.time + 30 SECONDS
	while(world.time < deadline)
		directory = diagnostics.directory_states[watched]
		if(directory["services"] == known_services + 1)
			break
		sleep(5)
	TEST_ASSERT(directory["services"] == known_services + 1 && directory["digest"] != known_digest,
		"A new service moves the watched digest: [json_encode(directory)] was [known_services]/[known_digest]")
	far.operating = FALSE
	deadline = world.time + 30 SECONDS
	while(world.time < deadline)
		directory = diagnostics.directory_states[watched]
		if(directory["services"] <= known_services - 2)
			break
		sleep(5)
	TEST_ASSERT(directory["services"] <= known_services - 2, "Services behind a dead APC leave the watched set: [json_encode(directory)] was [known_services]")
	far.operating = TRUE
	TEST_ASSERT(wait_for_links(left.z, near_id, 2, TRUE), "The cable returns with the far APC again.")
	log_world("netDM network diagnostics: [diagnostics.state()]")

/// Power, breakage, maintenance and EMP switch the links of a node off and back on.
/// The node keeps its wire ID, and a wired machine behind a dead APC does not fall back to radio.
/datum/unit_test/netdm_observe/area_map/power_state

/datum/unit_test/netdm_observe/area_map/power_state/Run()
	if(world.GetConfig("env", "NETDM_IPC_MODE") != "v1")
		return
	http_base = world.GetConfig("env", "NETDM_TEST_HTTP")
	TEST_ASSERT(length(http_base), "NETDM_TEST_HTTP must point to the test Host.")
	TEST_ASSERT(wait_until_live(), "Observe must publish the initial map ([SSnetdm_observe.observe_state()]).")
	var/turf/left = run_loc_floor_bottom_left
	var/turf/right = get_step(left, EAST)
	TEST_ASSERT_NOTNULL(right, "Expected two adjacent test cells.")
	var/area/served = test_zone(/area/netdm_test/first)
	assign_area(left, served)
	assign_area(right, served)
	var/obj/machinery/power/apc/apc = allocate(/obj/machinery/power/apc, left)
	var/list/apc_fact = wait_for_fact(WEAKREF(apc), left)
	TEST_ASSERT(apc_fact, "Expected the zone APC to be published.")
	var/apc_id = apc_fact["a"]
	var/stream = SSnetdm_observe.bridge.stream_id

	var/obj/machinery/netdm_test_machine/machine = allocate(/obj/machinery/netdm_test_machine, right)
	var/datum/component/netdm_node/node = netdm_make_node(machine, NETDM_MOUNT_FIXED, 3)
	var/list/fact = wait_for_node(node, right, TRUE)
	TEST_ASSERT(fact, "The machine must reach the Host.")
	var/node_id = fact["a"]
	TEST_ASSERT(wait_for_links(right.z, node_id, 1, FALSE), "A working machine takes its wired port ([json_encode(host_node(right.z, node_id))]).")

	machine.set_machine_stat(machine.machine_stat | NOPOWER)
	TEST_ASSERT(wait_for_links(right.z, node_id, 0, FALSE), "A machine without power has neither wire nor radio ([json_encode(host_node(right.z, node_id))]).")
	machine.set_machine_stat(machine.machine_stat & ~NOPOWER)
	TEST_ASSERT(wait_for_links(right.z, node_id, 1, FALSE), "Restored power brings the port back.")
	machine.set_machine_stat(machine.machine_stat | EMPED)
	TEST_ASSERT(wait_for_links(right.z, node_id, 0, FALSE), "An EMP-disabled machine leaves the network.")
	machine.set_machine_stat(machine.machine_stat & ~EMPED)
	TEST_ASSERT(wait_for_links(right.z, node_id, 1, FALSE), "The machine returns after the EMP.")

	apc.emp_act(50)
	// An EMP also pulses random APC wires; a pulsed power wire shorts the APC. Undo that chance
	// so the check is about the EMP state itself.
	apc.shorted = FALSE
	TEST_ASSERT(wait_for_links(left.z, apc_id, 0, FALSE), "An EMP-hit APC loses its links and access point ([json_encode(host_node(left.z, apc_id))]).")
	TEST_ASSERT(wait_for_links(right.z, node_id, 0, FALSE), "The wired machine behind a dead APC does not switch to radio.")
	TEST_ASSERT(wait_for_apc_state(apc_id, NETDM_STATE_POWERED), "Observe must remember the acknowledged APC state ([SSnetdm_observe.apc_states[apc_id]]).")
	apc.reset("emp")
	TEST_ASSERT(wait_for_links(left.z, apc_id, 1, TRUE), "The APC returns after the EMP reset.")
	TEST_ASSERT(wait_for_links(right.z, node_id, 1, FALSE), "The machine regains its port with the APC.")

	apc.operating = FALSE
	TEST_ASSERT(wait_for_links(right.z, node_id, 0, FALSE), "The main breaker cuts the APC network.")
	apc.operating = TRUE
	TEST_ASSERT(wait_for_links(right.z, node_id, 1, FALSE), "Closing the breaker restores it.")
	apc.set_broken()
	TEST_ASSERT(wait_for_links(left.z, apc_id, 0, FALSE), "A broken APC leaves the network.")
	apc.set_machine_stat(apc.machine_stat & ~BROKEN)
	apc.operating = TRUE
	TEST_ASSERT(wait_for_links(right.z, node_id, 1, FALSE), "A repaired APC serves its machine again.")
	TEST_ASSERT(wait_for_apc_state(apc_id, NETDM_STATE_UP) && isnull(SSnetdm_observe.apc_states[apc_id]), "An APC back up has no stored state.")

	TEST_ASSERT_EQUAL(SSnetdm_observe.known[WEAKREF(apc)]?["a"], apc_id, "State changes keep the APC wire ID.")
	TEST_ASSERT_EQUAL(SSnetdm_observe.node_ids[node], node_id, "State changes keep the node wire ID.")
	TEST_ASSERT_EQUAL(SSnetdm_observe.bridge.stream_id, stream, "State changes preserve the session stream.")

/obj/machinery/air_sensor/netdm_test
	id_tag = "netdm_test_sensor"

/obj/machinery/computer/atmos_control/netdm_test
	sensors = list("netdm_test_sensor" = "netDM test sensor")

/// Network telemetry: a powered console receives the sample through a service delivery.
/// A broken console cannot acquire a fresh sample by listening to the old radio frequency.
/datum/unit_test/netdm_observe/area_map/atmos_telemetry

/datum/unit_test/netdm_observe/area_map/atmos_telemetry/Run()
	if(world.GetConfig("env", "NETDM_IPC_MODE") != "v1")
		return
	TEST_ASSERT(wait_until_live(), "Host must publish the network.")
	var/turf/left = run_loc_floor_bottom_left
	var/turf/middle = get_step(left, EAST)
	var/turf/right = get_step(middle, EAST)
	TEST_ASSERT(middle && right, "Three adjacent turfs required.")
	var/area/served = test_zone(/area/netdm_test/first)
	assign_area(left, served)
	assign_area(middle, served)
	assign_area(right, served)
	var/obj/machinery/power/apc/apc = allocate(/obj/machinery/power/apc, left)
	TEST_ASSERT(wait_for_fact(WEAKREF(apc), left), "APC must be visible.")
	var/obj/machinery/air_sensor/netdm_test/sensor = allocate(/obj/machinery/air_sensor/netdm_test, middle)
	var/obj/machinery/computer/atmos_control/netdm_test/online = allocate(/obj/machinery/computer/atmos_control/netdm_test, right)
	var/obj/machinery/computer/atmos_control/netdm_test/broken = allocate(/obj/machinery/computer/atmos_control/netdm_test, left)
	var/instance = netdm_atmos_instance(sensor.frequency, sensor.id_tag)
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	var/datum/component/netdm_node/sensor_node = sensor.GetComponent(/datum/component/netdm_node)
	var/datum/component/netdm_node/online_node = online.GetComponent(/datum/component/netdm_node)
	var/datum/component/netdm_node/broken_node = broken.GetComponent(/datum/component/netdm_node)
	TEST_ASSERT(sensor_node && online_node && broken_node, "Network endpoints required.")
	broken.set_machine_stat(broken.machine_stat | BROKEN)
	var/datum/netdm_service_endpoint/online_endpoint = lane.by_node[online_node]
	var/datum/netdm_service_endpoint/broken_endpoint = lane.by_node[broken_node]
	var/deadline = world.time + 60 SECONDS
	while(world.time < deadline && !(lane.ready(sensor_node, instance) && online_endpoint?.subscribed[instance] && broken_endpoint?.subscribed[instance]))
		sleep(2)
	TEST_ASSERT(lane.ready(sensor_node, instance), "Sensor must offer service: [lane.state()]")
	TEST_ASSERT(online_endpoint?.subscribed[instance], "Console must subscribe: [lane.state()]")
	sensor.next_forced_report = 0
	TEST_ASSERT(sensor.try_report(), "Sensor should sample.")
	deadline = world.time + 20 SECONDS
	while(world.time < deadline && !online.sensor_information[sensor.id_tag])
		sleep(2)
	TEST_ASSERT(online.sensor_information[sensor.id_tag], "The network-delivered sample updates the console.")
	TEST_ASSERT(!broken.sensor_information[sensor.id_tag], "The broken console cannot receive a radio bypass.")
	var/list/payload = online.sensor_information[sensor.id_tag]
	TEST_ASSERT(islist(payload["gases"]), "The network preserves gas composition.")

/// P5 canary on the runtime station: the Host ledger takes over the station web. A second server gets the
/// web's knowledge but not its balance, each server earns into its own wallet, a console buys on its bound
/// server at the ledger's price, the bounty is paid once, and the legacy web only projects the servers.
/datum/unit_test/netdm_observe/research_authoritative

/datum/unit_test/netdm_observe/research_authoritative/proc/host_storages()
	var/datum/http_response/response = world_safe_http_get("[world.GetConfig("env", "NETDM_TEST_HTTP")]/api/research/status", 5 SECONDS)
	var/list/host = response?.status_code == 200 ? json_decode(response.body) : null
	. = list("totals" = host?["totals"])
	for(var/list/row in host?["storages"])
		var/list/available = row["availableMilli"]
		.[row["storage"]] = netdm_number(islist(available) ? available[TECHWEB_POINT_TYPE_GENERIC] : 0) / 1000

/datum/unit_test/netdm_observe/research_authoritative/proc/wait_answer(datum/netdm_research_shadow/shadow, list/binding)
	var/deadline = world.time + 30 SECONDS
	while(world.time < deadline && binding["busy"])
		sleep(2)
	return !binding["busy"]

/datum/unit_test/netdm_observe/research_authoritative/proc/wait_bound(list/binding)
	var/deadline = world.time + 30 SECONDS
	while(world.time < deadline && !binding["bound"])
		sleep(2)
	return binding["bound"]

/// An available node of the web, not researched or boosted, whose exported cost lies in the range.
/datum/unit_test/netdm_observe/research_authoritative/proc/pick_node(datum/netdm_research_shadow/shadow, datum/techweb/web, low, high, except)
	for(var/id in web.available_nodes)
		if(id == except || web.researched_nodes[id] || web.boosted_nodes[id])
			continue
		var/cost = shadow.catalog_costs[id]
		if(cost >= low && cost <= high)
			return id

/datum/unit_test/netdm_observe/research_authoritative/Run()
	if(world.GetConfig("env", "NETDM_IPC_MODE") != "v1")
		return
	TEST_ASSERT(wait_until_live(), "Observe must publish the map ([SSnetdm_observe.observe_state()]).")
	var/datum/netdm_research_shadow/shadow = SSnetdm_observe.research
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	var/obj/machinery/rnd/server/server = locate(/obj/machinery/rnd/server) in SSresearch.servers
	TEST_ASSERT(shadow && lane && server, "The research pilot needs the placed R&D server.")
	var/datum/techweb/web = server.stored_research
	var/obj/machinery/computer/rdconsole/console
	for(var/obj/machinery/computer/rdconsole/candidate in GLOB.machines)
		if(candidate.stored_research == web)
			console = candidate
			break
	TEST_ASSERT(console, "The runtime station needs an R&D console on the station web.")

	// A second server of the same web, next to the console.
	var/obj/machinery/rnd/server/second
	for(var/range in 1 to 4)
		for(var/turf/open/floor/spot in orange(range, console))
			if(!spot.is_blocked_turf(TRUE) && !(locate(/obj/machinery/rnd/server) in spot))
				second = allocate(/obj/machinery/rnd/server, spot)
				break
		if(second)
			break
	TEST_ASSERT(second?.stored_research == web, "The second server must join the station web.")
	var/datum/component/netdm_node/second_node = second.GetComponent(/datum/component/netdm_node)
	var/second_storage = shadow.servers[WEAKREF(second)]
	var/treasury = shadow.treasury_of(web)
	TEST_ASSERT(second_storage && treasury && second_storage != treasury, "Both servers need storages: [shadow.state()]")
	var/deadline = world.time + 2 MINUTES
	while(world.time < deadline && !(shadow.synchronized() && lane.ready(second_node, "research.[second_storage]")))
		sleep(5)
	TEST_ASSERT(shadow.synchronized(), "The mirror must catch up before the switch: [shadow.state()] [json_encode(shadow.notes)]")

	// The switch: the treasury keeps the web's pool, the second server gets knowledge only.
	web.add_point_list(list(TECHWEB_POINT_TYPE_GENERIC = 30000), FALSE)
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && !shadow.synchronized())
		sleep(2)
	TEST_ASSERT(shadow.authorize(), "The ledger must take over: [shadow.state()]")
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && !shadow.synchronized())
		sleep(2)
	var/list/wallets = host_storages()
	TEST_ASSERT(wallets[treasury] >= 30000, "The treasury keeps the web's pool: [json_encode(wallets)]")
	TEST_ASSERT(wallets[second_storage] < 100, "The second server gets no copy of the balance: [json_encode(wallets)]")

	// Legacy writers reach the treasury; the legacy balance is only a projection.
	var/legacy_before = web.research_points[TECHWEB_POINT_TYPE_GENERIC]
	web.add_point_list(list(TECHWEB_POINT_TYPE_GENERIC = 1000), FALSE)
	TEST_ASSERT_EQUAL(web.research_points[TECHWEB_POINT_TYPE_GENERIC], legacy_before, "Legacy points must not change the projection directly.")
	// The price never rewrites the shared node, even with a boost.
	var/boosted_id = pick_node(shadow, web, 200, 100000)
	TEST_ASSERT(boosted_id, "The station web needs a node to price.")
	var/datum/techweb_node/boosted = SSresearch.techweb_node_by_id(boosted_id)
	var/list/costs_before = boosted.research_costs.Copy()
	web.boosted_nodes[boosted_id] = list(TECHWEB_POINT_TYPE_GENERIC = 100)
	var/list/first_price = boosted.get_price(web)
	var/list/second_price = boosted.get_price(web)
	web.boosted_nodes -= boosted_id
	TEST_ASSERT_EQUAL(first_price[TECHWEB_POINT_TYPE_GENERIC], second_price[TECHWEB_POINT_TYPE_GENERIC], "A price read twice must not change.")
	TEST_ASSERT_EQUAL(boosted.research_costs[TECHWEB_POINT_TYPE_GENERIC], costs_before[TECHWEB_POINT_TYPE_GENERIC], "get_price must not rewrite the node cost.")

	// A purchase on the treasury: the ledger's price, the node in the legacy web, one bounty.
	shadow.bind_server(console, treasury)
	var/list/binding = shadow.bindings[WEAKREF(console)]
	TEST_ASSERT(wait_bound(binding), "The console must be confirmed by its server over the network: [json_encode(binding)]")
	var/node_id = pick_node(shadow, web, 1, 20000)
	TEST_ASSERT(node_id, "The station web needs an affordable node.")
	var/datum/bank_account/science = SSeconomy.get_dep_account(ACCOUNT_SCI)
	var/money = science?.account_balance
	TEST_ASSERT(console.research_node(node_id, null), "The console must send the purchase.")
	TEST_ASSERT(wait_answer(shadow, binding), "The server must answer the purchase.")
	TEST_ASSERT(web.researched_nodes[node_id], "The purchase must reach the legacy web for lathes: [json_encode(shadow.notes)] [shadow.state()]")
	if(science)
		TEST_ASSERT_EQUAL(science.account_balance - money, web.pays_research_bounty ? SSeconomy.techweb_bounty : 0, "One purchase pays one bounty.")
	var/list/after = host_storages()
	TEST_ASSERT(after[treasury] <= wallets[treasury] + 1000 + 300 - shadow.catalog_costs[node_id] + 1, "The treasury pays the price: [json_encode(after)]")

	// The second server holds only its own income, yet its console spends the network's account: the
	// treasury it reaches pays what it lacks. A node above the whole account is refused by the ledger.
	shadow.bind_server(console, second_storage)
	binding = shadow.bindings[WEAKREF(console)]
	TEST_ASSERT(wait_bound(binding), "The console must reach the second server.")
	var/list/pool_before = host_storages()
	TEST_ASSERT(binding["available"] >= pool_before[treasury] - 1, "The console sees the network's account: [json_encode(binding)] [json_encode(pool_before)]")
	var/expensive = pick_node(shadow, web, 2000, min(binding["available"] - 1, 1000000000))
	TEST_ASSERT(expensive, "The station web needs an expensive node within the account.")
	TEST_ASSERT(console.research_node(expensive, null), "The console must send the second purchase.")
	TEST_ASSERT(wait_answer(shadow, binding), "The second server must answer.")
	TEST_ASSERT(web.researched_nodes[expensive], "The network's account pays for the empty server: [shadow.state()] [json_encode(shadow.notes)]")
	var/list/pool_after = host_storages()
	TEST_ASSERT(pool_after[treasury] < pool_before[treasury] - 1000 && pool_after[second_storage] >= 0,
		"The treasury pays what the second server lacks: [json_encode(pool_before)] -> [json_encode(pool_after)]")
	var/unaffordable = pick_node(shadow, web, binding["available"] + 1, 1000000000, expensive)
	if(unaffordable)
		var/refused_before = shadow.purchase_outcomes["insufficient_points"] || 0
		TEST_ASSERT(console.research_node(unaffordable, null), "The console must send the third purchase.")
		TEST_ASSERT(wait_answer(shadow, binding), "The second server must answer.")
		TEST_ASSERT(!web.researched_nodes[unaffordable], "A node above the whole account cannot be bought.")
		TEST_ASSERT_EQUAL((shadow.purchase_outcomes["insufficient_points"] || 0) - refused_before, 1, "The refusal comes from the ledger.")

	// A forced unlock pays no bounty; each server earns its own income.
	money = science?.account_balance
	var/forced = pick_node(shadow, web, 0, 1000000000, expensive)
	web.research_node_id(forced, TRUE, FALSE)
	if(science)
		TEST_ASSERT_EQUAL(science.account_balance, money, "A forced unlock pays no bounty.")
	// Income depends on the room: two servers heat it past their tolerance within a minute and earn nothing,
	// as in legacy. The test raises the tolerance so that the measured window has income.
	server.temp_tolerance_high = 1000
	second.temp_tolerance_high = 1000
	sleep(4 SECONDS)
	var/list/earlier = host_storages()
	sleep(4 SECONDS)
	deadline = world.time + 20 SECONDS
	while(world.time < deadline && !shadow.synchronized())
		sleep(2)
	var/list/later = host_storages()
	TEST_ASSERT(later[treasury] > earlier[treasury] && later[second_storage] > earlier[second_storage],
		"Both servers must earn into their own wallets: [json_encode(earlier)] -> [json_encode(later)]")
	var/list/rate_a = shadow.server_rates[treasury]
	var/list/rate_b = shadow.server_rates[second_storage]
	TEST_ASSERT(rate_a && rate_b && rate_a[TECHWEB_POINT_TYPE_GENERIC] > 0 && abs(rate_a[TECHWEB_POINT_TYPE_GENERIC] - rate_b[TECHWEB_POINT_TYPE_GENERIC]) < 0.01,
		"Diminishing returns count the servers of the domain: [json_encode(rate_a)] [json_encode(rate_b)]")
	var/list/totals = later["totals"]
	TEST_ASSERT(totals?["balanced"], "The Host ledger must stay balanced: [json_encode(totals)]")
	TEST_ASSERT_EQUAL(shadow.counters["rejected"] + shadow.counters["dropped"], 0, "Every ledger event must be accepted: [json_encode(shadow.notes)]")
	log_world("netDM research ledger: [shadow.state()] wallets=[json_encode(later)]")

/// P6 on the runtime station under the ledger: two servers of the station web exchange knowledge over the
/// network, points move between them only by a transfer that commits once, and a disk carries knowledge
/// without points or bounty.
/datum/unit_test/netdm_observe/research_p6

/// Storage ID -> list("unlocked", "available") from the Host ledger, plus "totals".
/datum/unit_test/netdm_observe/research_p6/proc/host_rows()
	var/datum/http_response/response = world_safe_http_get("[world.GetConfig("env", "NETDM_TEST_HTTP")]/api/research/status", 5 SECONDS)
	var/list/host = response?.status_code == 200 ? json_decode(response.body) : null
	. = list("totals" = host?["totals"])
	for(var/list/row in host?["storages"])
		var/list/available = row["availableMilli"]
		.[row["storage"]] = list("unlocked" = netdm_number(row["unlocked"]),
			"available" = netdm_number(islist(available) ? available[TECHWEB_POINT_TYPE_GENERIC] : 0) / 1000)

/datum/unit_test/netdm_observe/research_p6/proc/wait_bound(datum/netdm_research_shadow/shadow, console)
	var/list/binding = shadow.bindings[WEAKREF(console)]
	var/deadline = world.time + 30 SECONDS
	while(world.time < deadline && !binding?["bound"])
		sleep(2)
	return binding?["bound"]

/datum/unit_test/netdm_observe/research_p6/Run()
	if(world.GetConfig("env", "NETDM_IPC_MODE") != "v1")
		return
	TEST_ASSERT(wait_until_live(), "Observe must publish the map ([SSnetdm_observe.observe_state()]).")
	var/datum/netdm_research_shadow/shadow = SSnetdm_observe.research
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	var/obj/machinery/rnd/server/server = locate(/obj/machinery/rnd/server) in SSresearch.servers
	TEST_ASSERT(shadow && lane && server, "The research pilot needs the placed R&D server.")
	var/datum/techweb/web = server.stored_research
	var/obj/machinery/computer/rdconsole/console
	for(var/obj/machinery/computer/rdconsole/candidate in GLOB.machines)
		if(candidate.stored_research == web)
			console = candidate
			break
	TEST_ASSERT(console, "The runtime station needs an R&D console on the station web.")
	var/deadline = world.time + 2 MINUTES
	while(world.time < deadline && !shadow.authoritative)
		shadow.authorize()
		sleep(5)
	TEST_ASSERT(shadow.authoritative, "The ledger must take over: [shadow.state()]")

	var/obj/machinery/rnd/server/second
	for(var/range in 1 to 4)
		for(var/turf/open/floor/spot in orange(range, console))
			if(!spot.is_blocked_turf(TRUE) && !(locate(/obj/machinery/rnd/server) in spot))
				second = allocate(/obj/machinery/rnd/server, spot)
				break
		if(second)
			break
	TEST_ASSERT(second?.stored_research == web, "The second server must join the station web.")
	var/datum/component/netdm_node/second_node = second.GetComponent(/datum/component/netdm_node)
	var/second_storage = shadow.servers[WEAKREF(second)]
	var/treasury = shadow.treasury_of(web)
	deadline = world.time + 60 SECONDS
	while(world.time < deadline && !(shadow.storage_domains[second_storage] && shadow.synchronized() && lane.ready(second_node, "research.[second_storage]")))
		sleep(5)
	TEST_ASSERT(shadow.storage_domains[second_storage] == "station", "The second server serves the station domain: [shadow.state()]")

	// Knowledge sync: the new server learns everything the treasury knows, over the network.
	var/list/rows
	deadline = world.time + 90 SECONDS
	while(world.time < deadline)
		rows = host_rows()
		if(rows[second_storage] && rows[treasury] && rows[second_storage]["unlocked"] >= rows[treasury]["unlocked"])
			break
		sleep(1 SECONDS)
	TEST_ASSERT(rows[second_storage]["unlocked"] >= rows[treasury]["unlocked"],
		"The second server must learn the treasury's knowledge: [json_encode(rows)] [json_encode(shadow.sync_pairs)]")
	TEST_ASSERT(rows[second_storage]["available"] < 1000, "Knowledge sync moves no points: [json_encode(rows)]")

	// The console of the second server sees the network's account, not only its server's wallet.
	shadow.bind_server(console, second_storage)
	TEST_ASSERT(wait_bound(shadow, console), "The console must reach the second server.")
	var/list/before = host_rows()
	var/list/binding = shadow.bindings[WEAKREF(console)]
	TEST_ASSERT(binding["available"] >= before[second_storage]["available"] + before[treasury]["available"] - 100,
		"The account sums the servers the console's server reaches: [json_encode(binding)] [json_encode(before)]")
	var/list/after
	var/list/totals = before["totals"]
	TEST_ASSERT(totals?["balanced"], "The ledger balances: [json_encode(totals)]")

	// A disk: written from the treasury without a bounty, restored into the second server without points.
	console.t_disk = new /obj/item/disk/tech_disk(console)
	shadow.bind_server(console, treasury)
	TEST_ASSERT(wait_bound(shadow, console), "The console must reach the treasury.")
	var/datum/bank_account/science = SSeconomy.get_dep_account(ACCOUNT_SCI)
	var/money = science?.account_balance
	TEST_ASSERT(shadow.console_disk(console, "loadTech", list()), "The console must write the disk through its server.")
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && length(shadow.disk_ops))
		sleep(2)
	TEST_ASSERT(console.t_disk.netdm_disk && (shadow.counters["disk_written"] || shadow.counters["disk_unchanged"]),
		"The server must write the disk: [shadow.state()]")
	if(science)
		TEST_ASSERT_EQUAL(science.account_balance, money, "Writing a disk pays no bounty.")
	shadow.bind_server(console, second_storage)
	TEST_ASSERT(wait_bound(shadow, console), "The console must reach the second server again.")
	before = host_rows()
	// The disk's legacy copy is not what it holds: a node put there by hand must not reach the web.
	var/leak
	for(var/id in shadow.catalog_costs)
		if(!console.stored_research.researched_nodes[id] && !console.stored_research.hidden_nodes[id] && !SSresearch.techweb_nodes_starting[id] && SSresearch.techweb_node_by_id(id))
			leak = id
			break
	TEST_ASSERT(leak, "The catalog needs a node the console's web has not researched.")
	console.t_disk.stored_research.research_node_id(leak, TRUE, FALSE)
	TEST_ASSERT(shadow.console_disk(console, "uploadDisk", list("type" = "tech")), "The console must restore the disk through its server.")
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && length(shadow.disk_ops))
		sleep(2)
	TEST_ASSERT(shadow.counters["disk_restored"] || shadow.counters["disk_unchanged"], "The server must answer the restore: [shadow.state()]")
	after = host_rows()
	TEST_ASSERT(after[second_storage]["available"] - before[second_storage]["available"] < 100, "A restore brings no points: [json_encode(after)]")
	sleep(3 SECONDS) // The knowledge log is read after the answer.
	TEST_ASSERT(!console.stored_research.researched_nodes[leak], "A restore loads what the ledger wrote, not the disk's legacy copy.")

	// ResearchEvidence: points from an analyzer go to the server its console is bound to, not to the coordinator.
	var/obj/machinery/rnd/destructive_analyzer/analyzer = allocate(/obj/machinery/rnd/destructive_analyzer, get_turf(console))
	analyzer.linked_console = console
	before = host_rows()
	web.add_point_list(list(TECHWEB_POINT_TYPE_GENERIC = 100000), source = analyzer)
	deadline = world.time + 30 SECONDS
	after = before
	while(world.time < deadline && after[second_storage]["available"] - before[second_storage]["available"] < 100000)
		sleep(1 SECONDS)
		after = host_rows()
	TEST_ASSERT(after[second_storage]["available"] - before[second_storage]["available"] >= 100000 && after[treasury]["available"] - before[treasury]["available"] < 100000,
		"Evidence points reach the analyzer's server, not the coordinator: [json_encode(before)] -> [json_encode(after)] [shadow.state()]")
	analyzer.linked_console = null

	// A disk restored into a server of another web while the answer to the console is lost (§13.6, §13.8).
	// The world learns what a server knows from the server's own log, so the node still reaches the web
	// its machines read, without a bounty. A forced unlock gives the station web a node no fresh web has.
	var/extra
	for(var/id in shadow.catalog_costs)
		if(!web.researched_nodes[id] && !web.hidden_nodes[id] && !SSresearch.techweb_nodes_starting[id] && SSresearch.techweb_node_by_id(id))
			extra = id
			break
	TEST_ASSERT(extra, "The catalog needs a node the station web has not researched.")
	web.research_node_id(extra, TRUE, FALSE)
	shadow.bind_server(console, treasury)
	TEST_ASSERT(wait_bound(shadow, console), "The console must reach the treasury for the second disk.")
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && !shadow.synchronized())
		sleep(2)
	TEST_ASSERT(shadow.synchronized(), "The forced unlock must reach the ledger: [shadow.state()]")
	TEST_ASSERT(shadow.console_disk(console, "loadTech", list()), "The console must write the disk again.")
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && length(shadow.disk_ops))
		sleep(2)
	TEST_ASSERT(!length(shadow.disk_ops), "The server must write the second disk: [shadow.state()]")

	var/datum/techweb/isolated/foreign = allocate(/datum/techweb/isolated)
	var/obj/machinery/rnd/server/outpost
	for(var/range in 1 to 5)
		for(var/turf/open/floor/spot in orange(range, console))
			if(!spot.is_blocked_turf(TRUE) && !(locate(/obj/machinery/rnd/server) in spot))
				outpost = allocate(/obj/machinery/rnd/server, spot)
				break
		if(outpost)
			break
	TEST_ASSERT(outpost, "The outpost server needs a free tile.")
	// The web is set before the pilot's next round registers the storage: its domain is that web for life.
	SEND_SIGNAL(outpost, COMSIG_ATOM_SET_TECHWEB, foreign)
	TEST_ASSERT(outpost.stored_research == foreign && !foreign.researched_nodes[extra], "The outpost serves a fresh web of its own.")
	var/outpost_storage = shadow.servers[WEAKREF(outpost)]
	var/datum/component/netdm_node/outpost_node = outpost.GetComponent(/datum/component/netdm_node)
	deadline = world.time + 60 SECONDS
	while(world.time < deadline && !(shadow.storage_domains[outpost_storage] && shadow.owns(foreign) && shadow.synchronized() && lane.ready(outpost_node, "research.[outpost_storage]")))
		sleep(5)
	TEST_ASSERT(shadow.owns(foreign) && shadow.storage_domains[outpost_storage] && shadow.storage_domains[outpost_storage] != "station",
		"The outpost must be the server of its own research domain: [shadow.storage_domains[outpost_storage]] [shadow.state()]")

	var/projected = shadow.counters["projected"]
	var/restored = shadow.counters["disk_restored"]
	money = science?.account_balance
	// Sent from the console's node without a pending disk operation: the answer that returns finds nobody
	// waiting, exactly as after a console that gave up, was rebuilt or lost its session.
	var/datum/component/netdm_node/console_node = console.GetComponent(/datum/component/netdm_node)
	TEST_ASSERT(lane.invoke(console_node, "research.[outpost_storage]", "restore", "dk-lost-[rand(1, 99999)]",
		list("disk" = console.t_disk.netdm_disk), null), "The restore must be sent over the network.")
	deadline = world.time + 90 SECONDS
	while(world.time < deadline && !foreign.researched_nodes[extra])
		sleep(1 SECONDS)
	after = host_rows()
	TEST_ASSERT(foreign.researched_nodes[extra],
		"The restored node must reach the outpost's web without the answer: [json_encode(after[outpost_storage])] due=[json_encode(shadow.knowledge_due)] [shadow.state()] [json_encode(shadow.notes)]")
	TEST_ASSERT(shadow.counters["projected"] > projected, "The node came from the server's knowledge log: [shadow.state()]")
	TEST_ASSERT_EQUAL(shadow.counters["disk_restored"], restored, "No answer was applied for the lost restore.")
	TEST_ASSERT(after[outpost_storage]["unlocked"] >= length(SSresearch.techweb_nodes_starting) + 1, "The ledger holds the restored knowledge: [json_encode(after)]")
	if(science)
		TEST_ASSERT_EQUAL(science.account_balance, money, "Projected knowledge pays no bounty.")
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && (length(shadow.knowledge_due) || shadow.knowledge_inflight))
		sleep(5)
	TEST_ASSERT(!length(shadow.knowledge_due) && shadow.knowledge_upto[outpost_storage] > 0,
		"Every knowledge log must be read to its end: [json_encode(shadow.knowledge_due)] [json_encode(shadow.knowledge_upto)]")

	// The console chooses its server by asking the network (design 13.3, 14.5): the APC of its zone lists
	// the research servers it reaches, and the console takes one of its own web. The outpost server
	// is reachable too, but serves another web and is never chosen.
	var/list/fillers = list()
	for(var/index in 1 to 3)
		var/obj/machinery/netdm_test_machine/device = allocate(/obj/machinery/netdm_test_machine, get_turf(console))
		var/datum/component/netdm_node/device_node = netdm_make_node(device, NETDM_MOUNT_FIXED, 3)
		for(var/slot in 1 to 8)
			var/instance = "research.0-p10.[index].[slot]"
			lane.offer(device_node, instance, "research.server", "research.status", 1)
			fillers[instance] = device_node
	deadline = world.time + 30 SECONDS
	var/ready_fillers = 0
	while(world.time < deadline)
		ready_fillers = 0
		for(var/instance in fillers)
			ready_fillers += !!lane.ready(fillers[instance], instance)
		if(ready_fillers == length(fillers))
			break
		sleep(2)
	TEST_ASSERT_EQUAL(ready_fillers, length(fillers), "The first page must be filled with services that have no eligible R&D storage.")
	var/list/selection = list("best_hops" = INFINITY)
	shadow.consider_server_page(selection, list("items" = list(list("instance" = "research.[treasury]", "hops" = 4))), web)
	shadow.consider_server_page(selection, list("items" = list(list("instance" = "research.[second_storage]", "hops" = 2))), web)
	TEST_ASSERT_EQUAL(selection["best"], second_storage, "A nearer server on a later page replaces the current candidate.")
	var/pages_before = SSnetdm_observe.diagnostics.counters["pages"]
	var/chosen_by_query = shadow.counters["server_by_query"]
	shadow.bindings -= WEAKREF(console)
	TEST_ASSERT(shadow.bind_nearest(console), "The console must look for a server.")
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && !shadow.bindings[WEAKREF(console)])
		sleep(2)
	binding = shadow.bindings[WEAKREF(console)]
	TEST_ASSERT(binding && (binding["storage"] == treasury || binding["storage"] == second_storage),
		"The console must choose a server of its own web: [json_encode(binding)] [shadow.state()] [SSnetdm_observe.diagnostics.state()]")
	TEST_ASSERT_EQUAL(shadow.counters["server_by_query"], chosen_by_query + 1, "The choice came from the network's answer, not from the map distance.")
	TEST_ASSERT(SSnetdm_observe.diagnostics.counters["pages"] >= pages_before + 2, "R&D must read past the first page.")
	TEST_ASSERT(wait_bound(shadow, console), "The chosen server must confirm the binding over the network.")
	TEST_ASSERT_EQUAL(shadow.counters["rejected"] + shadow.counters["dropped"], 0, "Every ledger event must be accepted: [json_encode(shadow.notes)]")
	log_world("netDM research P6: [shadow.state()] rows=[json_encode(after)]")

/// The outbox of purchases (§13.5) on the runtime station under the ledger. A purchase whose answer never
/// reaches the console is still applied to the world from the ledger's outbox: the node for lathes, one
/// bounty, the research log. An effect the Host delivers again is not applied again, and a purchase whose
/// answer arrives is settled once by the answer and never a second time by the outbox.
/datum/unit_test/netdm_observe/research_authoritative/outbox

/// The outbox as the Host ledger sees it: list("pending", "settled" = list(result -> count)).
/datum/unit_test/netdm_observe/research_authoritative/outbox/proc/host_effects()
	var/datum/http_response/response = world_safe_http_get("[world.GetConfig("env", "NETDM_TEST_HTTP")]/api/research/status", 5 SECONDS)
	var/list/host = response?.status_code == 200 ? json_decode(response.body) : null
	return host?["effects"]

/// Waits until this world reported every settlement and the ledger has nothing pending.
/datum/unit_test/netdm_observe/research_authoritative/outbox/proc/wait_reported(datum/netdm_research_shadow/shadow)
	var/deadline = world.time + 30 SECONDS
	while(world.time < deadline)
		if(!length(shadow.effect_acks) && !shadow.effects_inflight)
			var/list/effects = host_effects()
			if(effects && !effects["pending"])
				return effects
		sleep(5)
	return null

/datum/unit_test/netdm_observe/research_authoritative/outbox/proc/settled_total(list/effects)
	. = 0
	var/list/settled = effects?["settled"]
	for(var/result in settled)
		. += settled[result]

/datum/unit_test/netdm_observe/research_authoritative/outbox/Run()
	if(world.GetConfig("env", "NETDM_IPC_MODE") != "v1")
		return
	TEST_ASSERT(wait_until_live(), "Observe must publish the map ([SSnetdm_observe.observe_state()]).")
	var/datum/netdm_research_shadow/shadow = SSnetdm_observe.research
	var/obj/machinery/rnd/server/server = locate(/obj/machinery/rnd/server) in SSresearch.servers
	TEST_ASSERT(shadow && server, "The research pilot needs the placed R&D server.")
	var/datum/techweb/web = server.stored_research
	var/obj/machinery/computer/rdconsole/console
	for(var/obj/machinery/computer/rdconsole/candidate in GLOB.machines)
		if(candidate.stored_research == web)
			console = candidate
			break
	TEST_ASSERT(console, "The runtime station needs an R&D console on the station web.")
	var/deadline = world.time + 2 MINUTES
	while(world.time < deadline && !shadow.authoritative)
		shadow.authorize()
		sleep(5)
	TEST_ASSERT(shadow.authoritative, "The ledger must take over: [shadow.state()]")
	var/treasury = shadow.treasury_of(web)
	web.add_point_list(list(TECHWEB_POINT_TYPE_GENERIC = 30000), FALSE)
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && !shadow.synchronized())
		sleep(2)
	shadow.bind_server(console, treasury)
	var/list/binding = shadow.bindings[WEAKREF(console)]
	TEST_ASSERT(wait_bound(binding), "The console must be confirmed by its server over the network: [json_encode(binding)]")
	var/list/outbox_before = wait_reported(shadow)
	TEST_ASSERT(outbox_before, "Earlier purchases must be settled first: [json_encode(host_effects())] [shadow.state()]")
	var/datum/bank_account/science = SSeconomy.get_dep_account(ACCOUNT_SCI)
	var/bounty = (science && web.pays_research_bounty) ? SSeconomy.techweb_bounty : 0

	// The answer is lost: the console gives up on the purchase the way its timeout does, and the answer
	// that still arrives finds nothing to finish. Only the ledger's outbox can bring the purchase to the world.
	var/lost_node = pick_node(shadow, web, 1, 12000)
	TEST_ASSERT(lost_node, "The station web needs an affordable node.")
	var/money = science?.account_balance
	var/logs = length(web.research_logs)
	var/recovered = shadow.effect_counters["recovered"]
	TEST_ASSERT(console.research_node(lost_node, null), "The console must send the purchase.")
	var/key = binding["busy"]
	var/list/purchase = shadow.purchases[key]
	TEST_ASSERT(key && purchase, "The purchase must be in flight: [json_encode(binding)]")
	shadow.purchases -= key
	shadow.finish_purchase(purchase, "no_answer", null, key)
	TEST_ASSERT(!web.researched_nodes[lost_node] && shadow.unanswered[key], "A purchase without an answer changes nothing yet.")
	var/effect_id = "[treasury]/[key]"
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && !shadow.settled_effects[effect_id])
		sleep(2)
	TEST_ASSERT(shadow.settled_effects[effect_id] == (bounty ? "paid" : "unpaid"),
		"The outbox must bring the lost purchase to the world: [shadow.settled_effects[effect_id]] [shadow.state()] [json_encode(shadow.notes)]")
	TEST_ASSERT(web.researched_nodes[lost_node], "The node must reach the legacy web for lathes.")
	TEST_ASSERT_EQUAL(length(web.research_logs), logs + 1, "The purchase is logged once.")
	TEST_ASSERT_EQUAL(shadow.effect_counters["recovered"], recovered + 1, "The purchase is counted as recovered from the outbox.")
	TEST_ASSERT(!shadow.unanswered[key], "The recovered purchase is no longer waiting.")
	if(science)
		TEST_ASSERT_EQUAL(science.account_balance - money, bounty, "The lost answer still pays one bounty.")
	var/list/outbox_after = wait_reported(shadow)
	TEST_ASSERT(outbox_after, "The settlement must reach the ledger: [json_encode(host_effects())] [shadow.state()]")
	TEST_ASSERT_EQUAL(settled_total(outbox_after), settled_total(outbox_before) + 1, "The ledger records one settlement.")

	// The Host delivers the same effect again (its settlement was lost with a reply or a Host process):
	// nothing is applied again, and the settlement is reported again.
	money = science?.account_balance
	var/reported_again = shadow.effect_counters["reported_again"]
	shadow.effects_answered(list(), list("ok" = TRUE, "result" = list("settled" = 0, "pending" = 1, "effects" = list(list(
		"id" = effect_id, "kind" = "researched", "storage" = treasury, "op" = key, "node" = lost_node, "price" = "1", "revision" = "1")))))
	TEST_ASSERT_EQUAL(length(web.research_logs), logs + 1, "A delivered-again effect is not logged again.")
	TEST_ASSERT_EQUAL(shadow.effect_counters["reported_again"], reported_again + 1, "Its settlement is reported again.")
	if(science)
		TEST_ASSERT_EQUAL(science.account_balance, money, "A delivered-again effect pays nothing.")
	outbox_after = wait_reported(shadow)
	TEST_ASSERT(outbox_after, "The repeated report must be accepted: [json_encode(host_effects())] [shadow.state()]")
	TEST_ASSERT_EQUAL(settled_total(outbox_after), settled_total(outbox_before) + 1, "A repeated report records nothing more.")

	// The answer arrives: the purchase is settled by it, and the outbox adds nothing afterwards.
	var/answered_node = pick_node(shadow, web, 1, 12000, lost_node)
	TEST_ASSERT(answered_node, "The station web needs a second affordable node.")
	money = science?.account_balance
	recovered = shadow.effect_counters["recovered"]
	TEST_ASSERT(console.research_node(answered_node, null), "The console must send the second purchase.")
	TEST_ASSERT(wait_answer(shadow, binding), "The server must answer the second purchase.")
	TEST_ASSERT(web.researched_nodes[answered_node], "The answered purchase reaches the legacy web: [shadow.state()] [json_encode(shadow.notes)]")
	outbox_after = wait_reported(shadow)
	TEST_ASSERT(outbox_after, "The second settlement must reach the ledger: [json_encode(host_effects())] [shadow.state()]")
	sleep(6 SECONDS) // One more outbox round: it must find nothing to apply.
	TEST_ASSERT_EQUAL(settled_total(host_effects()), settled_total(outbox_before) + 2, "Two purchases, two settlements.")
	TEST_ASSERT_EQUAL(length(web.research_logs), logs + 2, "Each purchase is logged once.")
	TEST_ASSERT_EQUAL(shadow.effect_counters["recovered"], recovered, "An answered purchase is not recovered from the outbox.")
	if(science)
		TEST_ASSERT_EQUAL(science.account_balance - money, bounty, "The answered purchase pays one bounty.")
	var/list/totals = host_storages()["totals"]
	TEST_ASSERT(totals?["balanced"], "The Host ledger must stay balanced: [json_encode(totals)]")
	TEST_ASSERT_EQUAL(shadow.counters["rejected"] + shadow.counters["dropped"], 0, "Every ledger event must be accepted: [json_encode(shadow.notes)]")
	log_world("netDM research outbox: [shadow.state()] host=[json_encode(host_effects())]")

/// P4 on a real station map: the map's own gas sensors and atmos consoles run the Shadow pilot.
/// P7 authoritative: PDAs message each other through a message server node, without telecomms. The
/// server logs a message once, the recipient shows it once and can reply, and the sender learns each
/// recipient's outcome. A server that is off refuses; a recipient that cannot take the message, or is
/// out of the network, is reported back to the sender.
/datum/unit_test/netdm_observe/area_map/messenger_authoritative

/datum/unit_test/netdm_observe/area_map/messenger_authoritative/Destroy()
	var/datum/netdm_messenger_shadow/shadow = SSnetdm_observe.messenger
	if(shadow)
		shadow.delivery_ttl_ticks = initial(shadow.delivery_ttl_ticks)
	return ..()

/// Messages a messenger received from a peer and showed.
/datum/unit_test/netdm_observe/area_map/messenger_authoritative/proc/received(datum/computer_file/program/messenger/owner, datum/computer_file/program/messenger/peer)
	var/datum/pda_chat/chat = owner.find_chat_by_recipient(REF(peer))
	. = 0
	for(var/datum/pda_message/message as anything in chat?.messages)
		if(!message.outgoing)
			.++

/// A floor-or-space corner of the station level farther than any APC access point reaches.
/datum/unit_test/netdm_observe/area_map/proc/isolated_turf()
	var/z = SSmapping.levels_by_trait(ZTRAIT_STATION)[1]
	// The space edge can move a test actor again as soon as it enters, even via forceMove.
	var/near_edge = TRANSITIONEDGE + 2
	var/far_x = world.maxx - TRANSITIONEDGE - 1
	var/far_y = world.maxy - TRANSITIONEDGE - 1
	for(var/list/corner in list(list(near_edge, near_edge), list(far_x, near_edge), list(near_edge, far_y), list(far_x, far_y)))
		var/turf/candidate = locate(corner[1], corner[2], z)
		var/near = FALSE
		for(var/obj/machinery/power/apc/apc as anything in GLOB.apcs_list)
			if(apc.z == z && get_dist(apc, candidate) <= NETDM_APC_ACCESS_RANGE * 2)
				near = TRUE
				break
		if(candidate && !near)
			return candidate
	return null

/datum/unit_test/netdm_observe/area_map/messenger_authoritative/proc/wait_counter(datum/netdm_messenger_shadow/shadow, list/counters, name, above, timeout = 20 SECONDS)
	var/deadline = world.time + timeout
	while(world.time < deadline && counters[name] <= above)
		sleep(2)
	return counters[name] > above

/datum/unit_test/netdm_observe/area_map/messenger_authoritative/Run()
	if(world.GetConfig("env", "NETDM_IPC_MODE") != "v1")
		return
	TEST_ASSERT(wait_until_live(), "Observe must publish the map ([SSnetdm_observe.observe_state()]).")
	var/datum/netdm_messenger_shadow/shadow = SSnetdm_observe.messenger
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	TEST_ASSERT(shadow && lane, "Observe must run the messenger pilot.")
	var/list/turfs = list(run_loc_floor_bottom_left)
	for(var/i in 1 to 4)
		turfs += get_step(turfs[length(turfs)], EAST)
	var/area/served = test_zone(/area/netdm_test/first)
	for(var/turf/tile as anything in turfs)
		assign_area(tile, served)
	var/obj/machinery/power/apc/apc = allocate(/obj/machinery/power/apc, turfs[1])
	TEST_ASSERT(wait_for_fact(WEAKREF(apc), turfs[1]), "Expected the zone APC to be published.")
	var/obj/machinery/telecomms/message_server/server = allocate(/obj/machinery/telecomms/message_server, turfs[2])
	var/obj/item/modular_computer/pda/alice_pda = allocate(/obj/item/modular_computer/pda, turfs[3])
	var/obj/item/modular_computer/pda/bob_pda = allocate(/obj/item/modular_computer/pda, turfs[4])
	var/obj/item/modular_computer/pda/carol_pda = allocate(/obj/item/modular_computer/pda, turfs[5])
	var/datum/computer_file/program/messenger/alice = locate(/datum/computer_file/program/messenger) in alice_pda.get_all_files()
	var/datum/computer_file/program/messenger/bob = locate(/datum/computer_file/program/messenger) in bob_pda.get_all_files()
	var/datum/computer_file/program/messenger/carol = locate(/datum/computer_file/program/messenger) in carol_pda.get_all_files()
	TEST_ASSERT(alice && bob && carol, "PDAs come with the messenger.")
	alice_pda.saved_identification = "Alice"
	bob_pda.saved_identification = "Bob"
	carol_pda.saved_identification = "Carol"
	add_messenger(alice)
	add_messenger(bob)
	add_messenger(carol)

	var/server_instance = shadow.server_instances[WEAKREF(server)]
	TEST_ASSERT(server_instance, "The message server offers msgsrv: [shadow.state()]")
	var/datum/component/netdm_node/server_node = server.GetComponent(/datum/component/netdm_node)
	var/list/pdas = list(alice_pda, bob_pda, carol_pda)
	var/list/messengers = list(alice, bob, carol)
	var/deadline = world.time + 60 SECONDS
	var/ready = FALSE
	while(world.time < deadline && !ready)
		ready = lane.ready(server_node, server_instance)
		for(var/index in 1 to 3)
			var/obj/item/modular_computer/pda/pda = pdas[index]
			ready = ready && lane.ready(pda.GetComponent(/datum/component/netdm_node), shadow.instances[WEAKREF(messengers[index])])
		if(!ready)
			sleep(2)
	TEST_ASSERT(ready, "The server and the messengers must register: [lane.state()]")

	// No telecomms in this zone and no debug bypass: only the network can carry it.
	var/old_bypass = SSnetworks.ntnet_debug_global_signal
	SSnetworks.ntnet_debug_global_signal = FALSE
	var/logged = length(server.pda_msgs)
	var/list/counters = shadow.relay_counters
	var/delivered = counters["delivered"]
	TEST_ASSERT(alice.send_message(alice_pda, "netDM relay: hello Bob", list(bob)), "Alice's message must leave for the server.")
	TEST_ASSERT(wait_counter(shadow, counters, "delivered", delivered), "Alice must learn Bob got it: [shadow.state()] [json_encode(shadow.reasons)]")
	TEST_ASSERT_EQUAL(received(bob, alice), 1, "Bob sees the message once.")
	TEST_ASSERT_EQUAL(length(server.pda_msgs) - logged, 1, "The server logs it once for the message monitor.")
	var/datum/data_pda_msg/entry = server.pda_msgs[length(server.pda_msgs)]
	TEST_ASSERT(findtext(entry.message, "hello Bob") && findtext(entry.recipient, "Bob"), "The log names the recipient and the text.")

	// The server's delivery replayed: a duplicate, nothing shown again.
	var/last_key = shadow.shown[length(shadow.shown)]
	var/id = copytext(last_key, 1, findtext(last_key, "/"))
	var/list/again = shadow.show(bob_pda, list("payload" = list("id" = id, "text" = "x", "sender" = "y", "from" = shadow.instances[WEAKREF(alice)]),
		"instance" = shadow.instances[WEAKREF(bob)]))
	TEST_ASSERT(islist(again) && again["result"]["state"] == "duplicate" && received(bob, alice) == 1, "A message ID is shown once.")

	// Bob replies through the same server; his chat with Alice works both ways.
	delivered = counters["delivered"]
	TEST_ASSERT(bob.send_message(bob_pda, "netDM relay: hi Alice", list(alice)), "Bob's reply must leave.")
	TEST_ASSERT(wait_counter(shadow, counters, "delivered", delivered), "The reply must be delivered: [shadow.state()]")
	TEST_ASSERT_EQUAL(received(alice, bob), 1, "Alice sees Bob's reply in their chat.")

	// A server that is off refuses: Bob gets nothing, Alice is told.
	server.toggled = FALSE
	sleep(1.1 SECONDS)
	var/offline = shadow.reasons["relay_offline"]
	logged = length(server.pda_msgs)
	TEST_ASSERT(alice.send_message(alice_pda, "netDM relay: server off", list(bob)), "The send itself goes out.")
	TEST_ASSERT(wait_counter(shadow, shadow.reasons, "relay_offline", offline), "Alice must learn the server is off: [shadow.state()]")
	TEST_ASSERT_EQUAL(received(bob, alice), 1, "Nothing reaches Bob while the server is off.")
	TEST_ASSERT_EQUAL(length(server.pda_msgs), logged, "A server that is off logs nothing.")
	server.toggled = TRUE

	// Carol turns receiving off after the send: the server reports it to Alice.
	sleep(1.1 SECONDS)
	var/disabled = counters["disabled"]
	TEST_ASSERT(alice.send_message(alice_pda, "netDM relay: to Carol", list(carol)), "The message to Carol must leave.")
	carol.sending_and_receiving = FALSE
	TEST_ASSERT(wait_counter(shadow, counters, "disabled", disabled), "Alice must learn Carol does not receive: [shadow.state()]")
	TEST_ASSERT_EQUAL(received(carol, alice), 0, "Carol shows nothing.")
	carol.sending_and_receiving = TRUE

	// Carol's PDA leaves for a corner of the station level with no access point in reach: the server
	// reports her unreachable once its delivery can no longer arrive.
	shadow.delivery_ttl_ticks = 30
	var/turf/away = isolated_turf()
	TEST_ASSERT(away, "The station level needs a corner without an APC nearby.")
	carol_pda.forceMove(away)
	sleep(2 SECONDS)
	var/unreachable = counters["unreachable"]
	TEST_ASSERT(alice.send_message(alice_pda, "netDM relay: Carol is away", list(carol)), "The message to Carol must leave.")
	TEST_ASSERT(wait_counter(shadow, counters, "unreachable", unreachable, 30 SECONDS), "Alice must learn Carol is unreachable: [shadow.state()] [json_encode(shadow.reasons)]")
	TEST_ASSERT_EQUAL(received(carol, alice), 0, "Carol shows nothing.")

	// If the preferred server explicitly refuses before logging, a backup may relay the same message.
	var/obj/machinery/telecomms/message_server/backup = allocate(/obj/machinery/telecomms/message_server, turfs[3])
	shadow.add_server(backup)
	var/backup_instance = shadow.server_instances[WEAKREF(backup)]
	var/datum/component/netdm_node/backup_node = backup.GetComponent(/datum/component/netdm_node)
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && !lane.ready(backup_node, backup_instance))
		sleep(2)
	TEST_ASSERT(lane.ready(backup_node, backup_instance), "The backup message server registers.")
	TEST_ASSERT_EQUAL(shadow.choose_server(alice_pda), server_instance, "The preferred server is tried first.")
	server.toggled = FALSE
	logged = length(server.pda_msgs)
	var/backup_logged = length(backup.pda_msgs)
	delivered = counters["delivered"]
	TEST_ASSERT(alice.send_message(alice_pda, "netDM relay: backup server", list(bob)), "Alice can try sending with the preferred server off.")
	TEST_ASSERT(wait_counter(shadow, counters, "delivered", delivered), "The backup server delivers after explicit refusal: [shadow.state()]")
	TEST_ASSERT_EQUAL(received(bob, alice), 2, "Bob receives the backup delivery exactly once.")
	TEST_ASSERT_EQUAL(length(server.pda_msgs), logged, "The preferred server did not log the refused message.")
	TEST_ASSERT_EQUAL(length(backup.pda_msgs), backup_logged + 1, "The backup server logs the message once.")
	server.toggled = TRUE

	SSnetworks.ntnet_debug_global_signal = old_bypass
	TEST_ASSERT_EQUAL(counters["duplicates"], 1, "Only the replayed delivery was a duplicate: [shadow.state()]")
	log_world("netDM messenger authoritative: [shadow.state()] reasons=[json_encode(shadow.reasons)]")

/// P8 authoritative uplink: a radio's speech reaches a telecomms mainframe over the network, not at
/// once by subspace. Nothing is broadcast before the uplink arrives; a repeat is a duplicate, an uplink
/// after the legacy backup is late, a speaker out of the network is lost, an unknown context expired.
/datum/unit_test/netdm_observe/area_map/radio_uplink

/datum/unit_test/netdm_observe/area_map/radio_uplink/Destroy()
	return ..()

/datum/unit_test/netdm_observe/area_map/radio_uplink/proc/speak(obj/item/radio/radio, text)
	var/obj/item/paper/someone = allocate(/obj/item/paper, run_loc_floor_bottom_left)
	var/atom/movable/virtualspeaker/voice = new(null, someone, radio)
	var/datum/signal/subspace/vocal/signal = new(radio, FREQ_COMMON, voice, /datum/language/common, text, list())
	signal.send_to_receivers()
	return signal

/datum/unit_test/netdm_observe/area_map/radio_uplink/proc/wait_counter(list/counters, name, above, timeout = 20 SECONDS)
	var/deadline = world.time + timeout
	while(world.time < deadline && counters[name] <= above)
		sleep(2)
	return counters[name] > above

/datum/unit_test/netdm_observe/area_map/radio_uplink/Run()
	if(world.GetConfig("env", "NETDM_IPC_MODE") != "v1")
		return
	TEST_ASSERT(wait_until_live(), "Observe must publish the map ([SSnetdm_observe.observe_state()]).")
	var/datum/netdm_radio_shadow/shadow = SSnetdm_observe.radio
	TEST_ASSERT(shadow, "Observe must run the radio pilot.")
	var/list/turfs = list(run_loc_floor_bottom_left)
	for(var/i in 1 to 3)
		turfs += get_step(turfs[length(turfs)], EAST)
	var/area/served = test_zone(/area/netdm_test/first)
	for(var/turf/tile as anything in turfs)
		assign_area(tile, served)
	var/obj/machinery/power/apc/apc = allocate(/obj/machinery/power/apc, turfs[1])
	TEST_ASSERT(wait_for_fact(WEAKREF(apc), turfs[1]), "Expected the zone APC to be published.")
	var/obj/machinery/telecomms/allinone/mainframe = allocate(/obj/machinery/telecomms/allinone, turfs[2])
	var/obj/item/radio/speaker = allocate(/obj/item/radio, turfs[3])
	var/obj/item/radio/away = allocate(/obj/item/radio, turfs[4])
	var/turf/corner = isolated_turf()
	TEST_ASSERT(corner, "The station level needs a corner without an APC nearby.")
	away.forceMove(corner)
	var/instance = shadow.rx_instances[WEAKREF(mainframe)]
	TEST_ASSERT(instance, "The mainframe takes uplinks: [shadow.state()]")
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	var/datum/component/netdm_node/mainframe_node = mainframe.GetComponent(/datum/component/netdm_node)
	var/deadline = world.time + 60 SECONDS
	while(world.time < deadline && !(lane.ready(mainframe_node, instance) && shadow.node_id(speaker) && shadow.node_id(away)))
		sleep(2)
	TEST_ASSERT(lane.ready(mainframe_node, instance), "The mainframe must register: [lane.state()]")
	sleep(2 SECONDS) // The corner radio's move reaches the Host.
	var/list/counters = shadow.uplink_counters

	var/heard = counters["heard"]
	var/datum/signal/subspace/vocal/signal = speak(speaker, "netDM uplink: hello")
	TEST_ASSERT(!signal.data["done"], "Nothing is broadcast before the uplink arrives over the network.")
	TEST_ASSERT(wait_counter(counters, "heard", heard), "The mainframe must broadcast it: [shadow.state()]")
	TEST_ASSERT(signal.data["done"] && counters["relayed"] >= 1 && shadow.uplink_percentile_ms(0.5) > 0, "Relayed with a latency: [shadow.state()]")

	var/list/again = shadow.received_uplink(mainframe, list("payload" = list("id" = signal.data["netdm_radio"], "frequency" = FREQ_COMMON),
		"instance" = instance))
	TEST_ASSERT(islist(again) && again["result"]["state"] == "duplicate", "A repeated uplink is a duplicate.")

	// The legacy backup went first: the uplink that arrives later is not relayed again.
	var/late = counters["late"]
	var/datum/signal/subspace/vocal/backed_up = speak(speaker, "netDM uplink: too late")
	backed_up.transmission_method = TRANSMISSION_RADIO
	TEST_ASSERT(wait_counter(counters, "late", late), "An uplink after the backup is late: [shadow.state()]")
	TEST_ASSERT(!backed_up.data["done"], "A late uplink is never broadcast.")

	var/lost = counters["lost"]
	var/datum/signal/subspace/vocal/unheard = speak(away, "netDM uplink: nobody hears")
	TEST_ASSERT(wait_counter(counters, "lost", lost, 15 SECONDS), "A speaker out of the network is lost: [shadow.state()]")
	TEST_ASSERT(!unheard.data["done"], "Speech that never reached a receiver is never broadcast.")

	var/list/expired = shadow.received_uplink(mainframe, list("payload" = list("id" = "r-none", "frequency" = FREQ_COMMON), "instance" = instance))
	TEST_ASSERT(islist(expired) && expired["result"]["state"] == "expired", "An unknown context has expired.")
	log_world("netDM radio uplink: [shadow.state()]")


/**
 * Audit of the APC network on the loaded station map.
 *
 * It rebuilds the export of the published APC inventory and applies the Host rules to it: a served
 * segment is the connected part of a zone that holds the zone anchor cell on a level, and two APCs
 * link where their served segments share a side. One walk over the station levels finds zones
 * without an APC and zone cells the export left out. Findings go to a report; nothing is changed.
 */
/datum/netdm_map_audit
	var/list/report = list()
	var/error
	/// Span records from the export: list(zone id, z, y, first x, last x).
	var/list/spans = list()
	var/list/parent = list()

/datum/netdm_map_audit/proc/find(index)
	while(parent[index] != index)
		parent[index] = parent[parent[index]]
		index = parent[index]
	return index

/datum/netdm_map_audit/proc/join(left, right)
	left = find(left)
	right = find(right)
	if(left != right)
		parent[max(left, right)] = min(left, right)

/datum/netdm_map_audit/proc/describe(area/zone)
	return zone ? "[zone.type] ([zone.name])" : "none"

/datum/netdm_map_audit/proc/run_audit()
	var/datum/netdm_apc_map_export/export = new(SSnetdm_observe.known.Copy())
	while(!export.advance())
		stoplag()
	if(export.error)
		error = "export failed: [export.error]"
		return

	// Zone names by serving APC, and the cell each zone is served from on every level.
	var/list/zone_area = list()
	for(var/area/root as anything in export.zones)
		var/datum/netdm_apc_zone/zone = export.zones[root]
		if(zone.apc) // Duct zones without an APC are counted by the Host's graph below.
			zone_area[zone.apc["a"]] = root
	var/list/nodes = list()
	var/list/anchors = list()
	for(var/list/fact in export.facts)
		switch(fact["op"])
			if("add_node")
				nodes[fact["a"]] = fact
			if("area_span")
				// The DM figures keep the rule of 11.11.2026 (zones with an APC only) for comparison.
				if(zone_area[fact["area"]])
					spans += list(list(fact["area"], fact["z"], fact["y"], fact["x"], fact["endX"]))
			if("area_apc")
				anchors["[fact["a"]]/[fact["z"]]"] = fact

	// Segments: spans of one zone on one level that touch by a side. Rows come in x order.
	var/list/rows = list()
	for(var/index in 1 to length(spans))
		parent += index
		var/list/span = spans[index]
		var/key = "[span[2]]/[span[3]]"
		if(!rows[key])
			rows[key] = list()
		rows[key] += index
	var/list/contacts = list()
	for(var/index in 1 to length(spans))
		var/list/span = spans[index]
		var/list/row = rows["[span[2]]/[span[3]]"]
		var/position = row.Find(index)
		if(position > 1)
			var/left = row[position - 1]
			var/list/neighbor = spans[left]
			if(neighbor[5] + 1 == span[4])
				contacts += list(list(left, index))
		for(var/above in rows["[span[2]]/[span[3] - 1]"])
			var/list/other = spans[above]
			if(other[4] > span[5] || other[5] < span[4])
				continue
			if(other[1] == span[1])
				join(above, index)
			else
				contacts += list(list(above, index))
		CHECK_TICK

	// The served segment of a zone on a level holds its anchor; the rest are islands.
	var/list/served_root = list()
	for(var/index in 1 to length(spans))
		var/list/span = spans[index]
		var/list/anchor = anchors["[span[1]]/[span[2]]"]
		if(anchor && anchor["y"] == span[3] && anchor["x"] >= span[4] && anchor["x"] <= span[5])
			served_root["[span[1]]/[span[2]]"] = find(index)
	var/list/exported = list()
	var/list/island_tiles = list()
	var/list/island_parts = list()
	for(var/index in 1 to length(spans))
		var/list/span = spans[index]
		var/key = "[span[1]]/[span[2]]"
		var/tiles = span[5] - span[4] + 1
		exported[key] += tiles
		var/root = find(index)
		if(served_root[key] == root)
			continue
		island_tiles[key] += tiles
		if(!island_parts[key])
			island_parts[key] = list()
		island_parts[key]["[root]"] = TRUE

	// Graph figures cover the station levels: CentCom and loaded away levels are counted apart.
	var/list/station_levels = SSmapping.levels_by_trait(ZTRAIT_STATION)
	var/list/station_z = list()
	for(var/level in station_levels)
		station_z["[level]"] = TRUE
	var/list/station_nodes = list()
	for(var/id in nodes)
		var/list/fact = nodes[id]
		if(station_z["[fact["z"]]"])
			station_nodes[id] = fact

	// Wired APC links where two served segments meet, and the components of that graph.
	var/list/links = list()
	var/list/degree = list()
	for(var/list/pair in contacts)
		var/list/first = spans[pair[1]]
		var/list/second = spans[pair[2]]
		if(!station_z["[first[2]]"])
			continue
		if(served_root["[first[1]]/[first[2]]"] != find(pair[1]) || served_root["[second[1]]/[second[2]]"] != find(pair[2]))
			continue
		var/a = first[1]
		var/b = second[1]
		var/link = text2num(a, 16) < text2num(b, 16) ? "[a]-[b]" : "[b]-[a]"
		if(links[link])
			continue
		links[link] = list(a, b)
		degree[a] += 1
		degree[b] += 1
	var/list/component = list()
	for(var/id in station_nodes)
		component[id] = id
	for(var/link in links)
		var/list/ends = links[link]
		var/a = ends[1]
		var/b = ends[2]
		while(component[a] != a)
			a = component[a]
		while(component[b] != b)
			b = component[b]
		if(a != b)
			component[b] = a
	var/list/sizes = list()
	for(var/id in station_nodes)
		var/root = id
		while(component[root] != root)
			root = component[root]
		sizes[root] += 1
	var/list/component_sizes = list()
	for(var/root in sizes)
		component_sizes += sizes[root]
	sortTim(component_sizes, GLOBAL_PROC_REF(cmp_numeric_dsc))

	// One walk over the station levels: power zones without an APC and zone cells left out.
	var/list/zone_tiles = list()
	for(var/level in station_levels)
		for(var/y in 1 to world.maxy)
			for(var/x in 1 to world.maxx)
				var/turf/tile = locate(x, y, level)
				var/area/root = netdm_power_area(tile?.loc)
				if(!root || istype(root, /area/space) || !root.requires_power || root.always_unpowered)
					continue
				if(!zone_tiles[root])
					zone_tiles[root] = list()
				zone_tiles[root]["[level]"] += 1
			CHECK_TICK
	var/list/apc_roots = list()
	var/list/apc_by_root = list()
	var/list/mismatched = list()
	var/list/in_space = list()
	var/list/unpublished = list()
	for(var/obj/machinery/power/apc/apc as anything in GLOB.apcs_list)
		var/turf/position = get_turf(apc)
		if(QDELETED(apc) || !position)
			continue
		var/area/root = netdm_power_area(apc.area)
		var/list/entry = SSnetdm_observe.known[WEAKREF(apc)]
		var/id = entry?["a"]
		if(!id)
			unpublished += "[describe(root)] at [position.x],[position.y],[position.z]"
			continue
		apc_roots[root] = TRUE
		if(!apc_by_root[root])
			apc_by_root[root] = list()
		apc_by_root[root] += id
		if(istype(root, /area/space))
			in_space += list(list("apc" = id, "x" = position.x, "y" = position.y, "z" = position.z))
		var/area/standing = netdm_power_area(get_area(apc))
		if(standing != root)
			mismatched += list(list("apc" = id, "serves" = describe(root), "stands_in" = describe(standing),
				"x" = position.x, "y" = position.y, "z" = position.z))
	var/list/without_apc = list()
	var/no_apc_tiles = 0
	var/list/unexported = list()
	for(var/area/root as anything in zone_tiles)
		var/list/per_level = zone_tiles[root]
		var/total = 0
		for(var/level in per_level)
			total += per_level[level]
		if(!apc_roots[root])
			// Station areas are the ones the station is built of; ruins and the like are listed apart.
			var/station_area = (root.type in GLOB.the_station_areas)
			if(station_area)
				no_apc_tiles += total
			without_apc += list(list("area" = describe(root), "tiles" = total, "levels" = per_level, "station" = station_area))
			continue
		var/datum/netdm_apc_zone/zone = export.zones[root]
		if(!zone?.apc)
			continue
		for(var/level in per_level)
			var/missing = per_level[level] - exported["[zone.apc["a"]]/[level]"]
			if(missing > 0)
				unexported += list(list("area" = describe(root), "z" = text2num(level), "tiles" = missing))
	var/list/multiple = list()
	for(var/area/root as anything in apc_by_root)
		var/list/ids = apc_by_root[root]
		if(length(ids) > 1)
			var/datum/netdm_apc_zone/zone = export.zones[root]
			multiple += list(list("area" = describe(root), "apcs" = ids, "serving" = zone?.apc["a"]))
	var/list/islands = list()
	var/total_island_tiles = 0
	for(var/key in island_tiles)
		var/list/parts = splittext(key, "/")
		if(!station_z[parts[2]])
			continue
		total_island_tiles += island_tiles[key]
		islands += list(list("area" = describe(zone_area[parts[1]]), "apc" = parts[1], "z" = text2num(parts[2]),
			"islands" = length(island_parts[key]), "tiles" = island_tiles[key]))
	var/list/isolated = list()
	for(var/id in station_nodes)
		if(!degree[id])
			var/area/root = zone_area[id]
			var/list/fact = nodes[id]
			isolated += list(list("apc" = id, "area" = root ? describe(root) : "not serving a zone",
				"x" = fact["x"], "y" = fact["y"], "z" = fact["z"]))
	var/station_zones = 0
	for(var/id in zone_area)
		if(station_nodes[id])
			station_zones++
	var/list/levels = list()
	for(var/level in export.levels)
		levels += export.levels[level]

	report = list(
		"map" = SSmapping.config?.map_name,
		"station_levels" = station_levels,
		"walked_levels" = levels,
		"apcs" = length(station_nodes),
		"off_station_apcs" = length(nodes) - length(station_nodes),
		"zones" = station_zones,
		"links" = length(links),
		"components" = length(component_sizes),
		"component_sizes" = component_sizes,
		"isolated" = isolated,
		"islands" = islands,
		"island_tiles" = total_island_tiles,
		"without_apc" = without_apc,
		"without_apc_tiles" = no_apc_tiles,
		"unexported" = unexported,
		"multiple_apcs" = multiple,
		"mismatched_apcs" = mismatched,
		"apcs_in_space" = in_space,
		"unpublished_apcs" = unpublished,
		"facts" = length(export.facts),
		"cells" = export.cells_visited,
	)

/**
 * The wired APC graph the Host built (decision of 14.11.2026: ducts and several APCs per segment), on the
 * station levels: APC-to-APC links of cost 1 are wires, the costlier ones radio bridges. Components count
 * the station APCs; "host_isolated" are APCs without a wire to another APC.
 */
/datum/unit_test/netdm_observe/area_map/map_audit/proc/host_graph(list/report)
	var/list/apc_ids = list()
	for(var/key in SSnetdm_observe.known)
		var/list/entry = SSnetdm_observe.known[key]
		if(entry?["a"])
			apc_ids["[entry["a"]]"] = entry["z"]
	var/list/station_levels = SSmapping.levels_by_trait(ZTRAIT_STATION)
	var/list/edges = list()
	var/list/station_apcs = list()
	for(var/level in station_levels)
		var/datum/http_response/response = world_safe_http_get("[http_base]/api/game/map?z=[level]&limit=8000&outer=true", 30 SECONDS)
		var/list/map = response?.status_code == 200 ? json_decode(response.body) : null
		if(!map)
			report["host_graph_error"] = "no map for level [level]"
			return
		for(var/list/node in map["nodes"])
			if(!isnull(apc_ids[node["id"]]))
				station_apcs[node["id"]] = node["id"]
		// An APC link to another level is listed from both levels: it is counted once.
		for(var/list/edge in map["edges"])
			var/key = text2num(edge["a"]) < text2num(edge["b"]) ? "[edge["a"]]-[edge["b"]]" : "[edge["b"]]-[edge["a"]]"
			edges[key] = edge
	var/list/wired = list()
	var/list/bridged = list()
	for(var/key in edges)
		var/list/edge = edges[key]
		if(!station_apcs[edge["a"]] || !station_apcs[edge["b"]])
			continue
		var/list/pair = list(edge["a"], edge["b"])
		if(edge["cost"] == 1)
			wired += list(pair)
		bridged += list(pair)
	report["host_wires"] = length(wired)
	report["host_bridges"] = length(bridged) - length(wired)
	var/list/wired_sizes = components_of(station_apcs, wired)
	var/list/grouped_sizes = components_of(station_apcs, bridged)
	report["host_components"] = length(wired_sizes)
	report["host_component_sizes"] = wired_sizes
	report["host_groups"] = length(grouped_sizes)
	var/list/degree = list()
	for(var/list/pair in wired)
		degree[pair[1]] = TRUE
		degree[pair[2]] = TRUE
	var/isolated = 0
	for(var/id in station_apcs)
		if(!degree[id])
			isolated++
	report["host_isolated"] = isolated

/datum/unit_test/netdm_observe/area_map/map_audit/proc/components_of(list/ids, list/pairs)
	var/list/root = list()
	for(var/id in ids)
		root[id] = id
	for(var/list/pair in pairs)
		var/a = pair[1]
		var/b = pair[2]
		while(root[a] != a)
			a = root[a]
		while(root[b] != b)
			b = root[b]
		if(a != b)
			root[b] = a
	var/list/sizes = list()
	for(var/id in ids)
		var/top = id
		while(root[top] != top)
			top = root[top]
		sizes[top] += 1
	. = list()
	for(var/top in sizes)
		. += sizes[top]
	sortTim(., GLOBAL_PROC_REF(cmp_numeric_dsc))

/// Runs the map audit on the loaded station and writes netdm_map_audit.json to the round logs.
/// Only contract breaches fail: the export must complete and every APC must reach the Host.
/datum/unit_test/netdm_observe/area_map/map_audit

/datum/unit_test/netdm_observe/area_map/map_audit/Run()
	if(world.GetConfig("env", "NETDM_IPC_MODE") != "v1")
		return
	http_base = world.GetConfig("env", "NETDM_TEST_HTTP")
	// A full station map publishes slower than the test reservation.
	var/deadline = world.time + 10 MINUTES
	while(world.time < deadline && !(SSnetdm_observe.published && SSnetdm_observe.phase == "live" && !SSnetdm_observe.pending))
		sleep(10)
	TEST_ASSERT(SSnetdm_observe.published, "Observe must publish the station map ([SSnetdm_observe.observe_state()]).")
	var/datum/netdm_map_audit/audit = new
	audit.run_audit()
	TEST_ASSERT(!audit.error, "The map audit must complete: [audit.error].")
	var/list/report = audit.report
	var/datum/http_response/response = world_safe_http_get("[http_base]/api/game/summary", 5 SECONDS)
	var/list/summary = response?.status_code == 200 ? json_decode(response.body) : null
	report["host_nodes"] = summary?["nodes"]
	report["host_links"] = summary?["links"]
	host_graph(report)
	var/path = "[GLOB.log_directory]/netdm_map_audit.json"
	fdel(path)
	text2file(json_encode(report), path)
	log_world("netDM map audit: [report["map"]] apcs=[report["apcs"]] zones=[report["zones"]] links=[report["links"]] \
		components=[report["components"]] isolated=[length(report["isolated"])] islands=[length(report["islands"])] \
		without_apc=[length(report["without_apc"])] unexported=[length(report["unexported"])] host_nodes=[report["host_nodes"]]")
	TEST_ASSERT(!length(report["unpublished_apcs"]), "Every APC must be published: [json_encode(report["unpublished_apcs"])].")
	var/published_apcs = report["apcs"] + report["off_station_apcs"]
	TEST_ASSERT(report["host_nodes"] >= published_apcs, "The Host must hold every published APC ([report["host_nodes"]] of [published_apcs]).")

/datum/unit_test/netdm_door_dispatch/Run()
	var/channel = "netdm-door-[REF(src)]"
	var/obj/item/assembly/control/blast_control = allocate(/obj/item/assembly/control)
	blast_control.id = channel
	var/obj/item/assembly/control/airlock/airlock_control = allocate(/obj/item/assembly/control/airlock)
	airlock_control.id = channel
	airlock_control.specialfunctions = OPEN|BOLTS|IDSCAN

	var/obj/machinery/door/poddoor/blast_closed = allocate(/obj/machinery/door/poddoor)
	blast_closed.id = channel
	var/obj/machinery/door/poddoor/blast_open = allocate(/obj/machinery/door/poddoor)
	blast_open.id = channel
	blast_open.density = FALSE
	var/obj/machinery/door/airlock/airlock_closed = allocate(/obj/machinery/door/airlock)
	airlock_closed.id_tag = channel
	var/obj/machinery/door/airlock/airlock_open = allocate(/obj/machinery/door/airlock)
	airlock_open.id_tag = channel
	airlock_open.density = FALSE

	var/list/blast_plan = blast_control.netdm_plan_doors(TRUE)
	TEST_ASSERT_EQUAL(length(blast_plan), 2, "A blast-door controller selects only its own doors.")
	TEST_ASSERT_EQUAL(blast_plan[blast_closed]["state"], "open", "The first blast door determines the synchronized state.")
	TEST_ASSERT_EQUAL(blast_plan[blast_open]["state"], "open", "The other blast door takes the same state.")
	blast_control.sync_doors = FALSE
	blast_plan = blast_control.netdm_plan_doors(TRUE)
	TEST_ASSERT_EQUAL(blast_plan[blast_open]["state"], "closed", "An independent door toggles its own state.")

	airlock_closed.locked = FALSE
	airlock_closed.aiDisabledIdScanner = TRUE
	var/list/airlock_plan = airlock_control.netdm_plan_doors(TRUE)
	TEST_ASSERT_EQUAL(length(airlock_plan), 2, "An airlock controller selects only airlocks on its channel.")
	TEST_ASSERT_EQUAL(airlock_plan[airlock_closed]["state"], "closed", "An open airlock makes the group close.")
	TEST_ASSERT_EQUAL(airlock_plan[airlock_closed]["bolted"], TRUE, "The plan carries an absolute bolt state.")
	TEST_ASSERT_EQUAL(airlock_plan[airlock_closed]["id_scan"], TRUE, "The plan enables the disabled scanner.")
	airlock_control.specialfunctions = 0
	TEST_ASSERT_NULL(airlock_control.netdm_plan_doors(TRUE), "A controller without functions cannot construct a press.")

	airlock_closed.set_machine_stat(airlock_closed.machine_stat | NOPOWER)
	var/list/receipt = airlock_closed.netdm_apply_controls(list("bolted" = TRUE, "id_scan" = TRUE), null, "test")
	TEST_ASSERT_EQUAL(receipt["reason"], "refused_bolts", "An unpowered airlock refuses a bolt change.")
	TEST_ASSERT_EQUAL(receipt["bolted"], FALSE, "The receipt reports the actual bolt state.")
	TEST_ASSERT(!airlock_closed.aiDisabledIdScanner && receipt["changed"], "The independent scanner change still applies.")

	var/datum/netdm_door_shadow/transport = SSnetdm_observe?.doors
	if(!transport)
		return
	var/datum/weakref/door_ref = WEAKREF(airlock_closed)
	var/instance = transport.add_door(airlock_closed)
	TEST_ASSERT(instance && transport.instances[door_ref] == instance && transport.by_instance[instance] == door_ref, "The door registers both lookup indexes.")
	qdel(airlock_closed)
	TEST_ASSERT_NULL(transport.instances[door_ref], "Deletion removes the door's forward index.")
	TEST_ASSERT_NULL(transport.by_instance[instance], "Deletion removes the reverse index.")

/datum/unit_test/netdm_airlock_panel_actuator/Run()
	var/obj/machinery/door/airlock/door = allocate(/obj/machinery/door/airlock)
	TEST_ASSERT(!door.netdm_panel_allowed(null), "Network panel control requires an operator.")
	TEST_ASSERT(!door.apply_panel_action("unsupported", null, null, "test"), "Unknown panel actions are rejected.")

	door.density = TRUE
	door.welded = TRUE
	TEST_ASSERT(!door.apply_panel_action("open", null, null, "test") && door.density, "Opening retains the weld guard.")
	TEST_ASSERT(door.apply_panel_action("close", null, null, "test") && door.density, "Closing a closed door is a no-op.")

	door.locked = FALSE
	TEST_ASSERT(door.apply_panel_action("bolt", null, null, "test") && door.locked, "Lowering bolts uses normal door control.")
	TEST_ASSERT(door.apply_panel_action("bolt", null, null, "test") && door.locked, "Repeating an absolute bolt action cannot raise the bolts.")
	door.set_machine_stat(door.machine_stat | NOPOWER)
	TEST_ASSERT(!door.apply_panel_action("unbolt", null, null, "test") && door.locked, "Raising the bolts still requires power.")

/// P9.1 on the station: map buttons pressed there and back; every door they control is reached over the
/// network or missed with a Host reason. Writes netdm_door_station.json.
/datum/unit_test/netdm_observe/area_map/door_station

/datum/unit_test/netdm_observe/area_map/door_station/proc/doors_of(obj/item/assembly/control/control)
	. = list()
	if(istype(control, /obj/item/assembly/control/airlock))
		var/obj/item/assembly/control/airlock/airlock_control = control
		if(!(airlock_control.specialfunctions & (OPEN|IDSCAN|BOLTS|SHOCK|SAFE)))
			return
		for(var/obj/machinery/door/airlock/door in GLOB.airlocks)
			if(door.id_tag == control.id)
				. += door
	else
		for(var/obj/machinery/door/poddoor/door in GLOB.airlocks)
			if(door.id == control.id)
				. += door

/datum/unit_test/netdm_observe/area_map/door_station/Run()
	if(world.GetConfig("env", "NETDM_IPC_MODE") != "v1")
		return
	var/datum/netdm_door_shadow/shadow = SSnetdm_observe.doors
	TEST_ASSERT(shadow, "Observe must run the door pilot.")
	var/deadline = world.time + 10 MINUTES
	while(world.time < deadline && !(SSnetdm_observe.published && SSnetdm_observe.phase == "live" && !SSnetdm_observe.pending))
		sleep(10)
	TEST_ASSERT(SSnetdm_observe.published, "Observe must publish the station map ([SSnetdm_observe.observe_state()]).")
	var/list/candidates = list()
	for(var/obj/machinery/button/button in GLOB.machines)
		var/obj/item/assembly/control/control = button.device
		var/turf/position = get_turf(button)
		if(!position || !is_station_level(position.z) || !istype(control) || !(control.type in list(/obj/item/assembly/control, /obj/item/assembly/control/airlock)))
			continue
		var/list/doors = doors_of(control)
		if(length(doors) && length(doors) <= 32)
			candidates[button] = doors
	TEST_ASSERT(length(candidates) >= 4, "The station needs door buttons: [length(candidates)].")
	var/list/chosen = list()
	var/step = max(1, round(length(candidates) / 16))
	for(var/index = 1; index <= length(candidates) && length(chosen) < 16; index += step)
		chosen[candidates[index]] = candidates[candidates[index]]
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	var/total = 0
	for(var/obj/machinery/button/button as anything in chosen)
		total += length(chosen[button])
	var/list/before = shadow.counters.Copy()
	var/list/reasons_before = shadow.reasons.Copy()
	var/latency_start = length(shadow.arrivals)
	var/cold_start = length(shadow.cold_arrivals)
	// There and back: the first pass brings the buttons and doors into the network and waits for them,
	// the second finds them attached and returns the doors to their map state.
	for(var/pass in 1 to 2)
		for(var/obj/machinery/button/button as anything in chosen)
			var/obj/item/assembly/control/control = button.device
			control.activate()
			sleep(2)
		sleep(4 SECONDS)
	deadline = world.time + 60 SECONDS
	while(world.time < deadline && length(shadow.presses))
		sleep(5)
	sleep(3 SECONDS) // Status answers explain the misses.
	var/list/delta = list()
	for(var/name in shadow.counters)
		if(shadow.counters[name] != before[name])
			delta[name] = shadow.counters[name] - before[name]
	var/list/invalid = list("unanswered", "not_attached", "lane_full", "unknown")
	var/list/reason_deltas = list()
	var/unexplained = 0
	for(var/reason in shadow.reasons)
		var/change = shadow.reasons[reason] - reasons_before[reason]
		if(!change)
			continue
		reason_deltas[reason] = change
		if((reason in invalid) || findtext(reason, "status_") == 1 || findtext(reason, "host_") == 1)
			unexplained += change
	var/list/window = shadow.arrivals.Copy(min(length(shadow.arrivals) + 1, latency_start + 1))
	var/p50 = shadow.percentile_ms(window, 0.5)
	var/p95 = shadow.percentile_ms(window, 0.95)
	var/list/cold_window = shadow.cold_arrivals.Copy(min(length(shadow.cold_arrivals) + 1, cold_start + 1))
	var/cold_p50 = shadow.percentile_ms(cold_window, 0.5)
	var/cold_p95 = shadow.percentile_ms(cold_window, 0.95)
	var/list/report = list(
		"map" = SSmapping.config?.map_name,
		"candidates" = length(candidates),
		"buttons" = length(chosen),
		"doors" = total,
		"door_nodes" = length(shadow.instances),
		"button_nodes" = shadow.counters["buttons"],
		"counters" = delta,
		"reasons" = reason_deltas,
		"p50_ms" = p50,
		"p95_ms" = p95,
		"cold_p50_ms" = cold_p50,
		"cold_p95_ms" = cold_p95,
		"notes" = shadow.notes,
		"lane" = lane.state(),
	)
	var/path = "[GLOB.log_directory]/netdm_door_station.json"
	fdel(path)
	text2file(json_encode(report), path)
	log_world("netDM door station: [report["map"]] buttons=[length(chosen)] doors=[total] counters=[json_encode(delta)] \
		reasons=[json_encode(reason_deltas)] p50=[p50]ms p95=[p95]ms cold_p50=[cold_p50]ms cold_p95=[cold_p95]ms [shadow.state()]")
	TEST_ASSERT_EQUAL(delta["mirrored"], 2 * length(chosen), "Every press is mirrored: [json_encode(report)]")
	TEST_ASSERT_EQUAL(delta["compared"], 2 * total, "Every door of every press is compared: [json_encode(report)]")
	TEST_ASSERT(delta["reached"] > 0, "The network reaches the station's doors: [json_encode(report)]")
	TEST_ASSERT_EQUAL(unexplained, 0, "Every miss needs a Host reason: [json_encode(reason_deltas)]")

/datum/unit_test/netdm_observe/area_map/network_cameras

/datum/unit_test/netdm_observe/area_map/network_cameras/proc/wait_feed(obj/machinery/computer/security/console, obj/machinery/camera/expected, status)
	var/deadline = world.time + 20 SECONDS
	while(world.time < deadline)
		if(console.active_camera == expected && console.netdm_camera_status == status)
			return TRUE
		sleep(2)
	return FALSE

/datum/unit_test/netdm_observe/area_map/network_cameras/Run()
	if(world.GetConfig("env", "NETDM_CAMERA_MODE") != "authoritative")
		return
	http_base = world.GetConfig("env", "NETDM_TEST_HTTP")
	TEST_ASSERT(wait_until_live(), "Observe must publish the map.")
	var/turf/left = run_loc_floor_bottom_left
	var/turf/right = get_step(left, EAST)
	assign_area(left, test_zone(/area/netdm_test/first))
	assign_area(right, test_zone(/area/netdm_test/second))
	var/obj/machinery/power/apc/near = allocate(/obj/machinery/power/apc, left)
	var/obj/machinery/power/apc/far = allocate(/obj/machinery/power/apc, right)
	var/list/near_fact = wait_for_fact(WEAKREF(near), left)
	TEST_ASSERT(near_fact && wait_for_fact(WEAKREF(far), right), "Both APCs are published.")
	TEST_ASSERT(wait_for_links(left.z, near_fact["a"], 1, TRUE), "The two APCs are linked.")
	var/obj/machinery/computer/security/console = allocate(/obj/machinery/computer/security, left)
	var/obj/machinery/camera/camera = allocate(/obj/machinery/camera, right)
	var/obj/machinery/camera/private_camera = allocate(/obj/machinery/camera, right)
	var/datum/component/netdm_node/camera_node = camera.GetComponent(/datum/component/netdm_node)
	TEST_ASSERT(camera_node && SSnetdm_observe.services.by_node[camera_node], "The camera joins the network before selection.")
	TEST_ASSERT(console.GetComponent(/datum/component/netdm_node), "The console has a node before interaction.")
	private_camera.network = list("private-test")
	console.set_machine_stat(console.machine_stat & ~(NOPOWER|BROKEN|EMPED))
	camera.set_machine_stat(camera.machine_stat & ~(NOPOWER|BROKEN|EMPED))
	camera.status = TRUE
	TEST_ASSERT(!console.netdm_camera_select(private_camera), "A camera from another network is denied.")
	TEST_ASSERT(console.netdm_camera_select(camera) && !console.active_camera, "Selection waits for the network result.")
	TEST_ASSERT(wait_feed(console, camera, "ready"), "The camera is only shown after the round trip.")
	var/list/camera_fact = wait_for_node(camera_node, right, TRUE)
	TEST_ASSERT(camera_fact && wait_for_links(right.z, camera_fact["a"], 1, FALSE), "The camera is wired to the far APC.")
	var/obj/machinery/computer/security/second_console = allocate(/obj/machinery/computer/security, left)
	second_console.set_machine_stat(second_console.machine_stat & ~(NOPOWER|BROKEN|EMPED))
	TEST_ASSERT(second_console.netdm_camera_select(camera), "A second console can request the same camera.")
	TEST_ASSERT(wait_feed(second_console, camera, "ready"), "Each console receives its own confirmation for the same camera.")
	far.operating = FALSE
	TEST_ASSERT(wait_for_links(right.z, camera_fact["a"], 0, FALSE), "Cut the camera's wired route.")
	TEST_ASSERT(wait_feed(console, null, "offline"), "A broken route expires the feed.")
	far.operating = TRUE
	TEST_ASSERT(wait_feed(console, camera, "ready"), "Restoring the route renews the feed.")
	console.network = list("private-test")
	TEST_ASSERT(wait_feed(console, null, "denied"), "Changing the console's camera network revokes its feed.")

/datum/unit_test/netdm_observe/area_map/network_air_alarm/Run()
	if(world.GetConfig("env", "NETDM_IPC_MODE") != "v1")
		return
	http_base = world.GetConfig("env", "NETDM_TEST_HTTP")
	TEST_ASSERT(wait_until_live(), "Observe must publish the station map.")
	var/obj/machinery/power/apc/station_apc
	for(var/obj/machinery/power/apc/apc as anything in GLOB.apcs_list)
		if(is_station_level(apc.z) && apc.netdm_state() == NETDM_STATE_UP && !is_antag_training_atom(apc))
			station_apc = apc
			break
	TEST_ASSERT(station_apc, "The station has a powered network access point.")
	var/obj/machinery/airalarm/alarm = allocate(/obj/machinery/airalarm, get_turf(station_apc))
	alarm.set_machine_stat(alarm.machine_stat & ~(NOPOWER|BROKEN|MAINT|EMPED))
	var/datum/component/netdm_node/node = alarm.GetComponent(/datum/component/netdm_node)
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	var/datum/netdm_service_endpoint/endpoint = lane.by_node[node]
	TEST_ASSERT(endpoint, "A station air alarm registers before local interaction.")
	var/datum/netdm_service_endpoint/apc_endpoint = lane.by_node[station_apc]
	TEST_ASSERT(apc_endpoint?.services["netshell.[apc_endpoint.id]"], "The mapped APC offers its shell before its terminal opens.")
	var/instance = "atmos.alarm.[endpoint.id]"
	var/deadline = world.time + 30 SECONDS
	while(world.time < deadline && !lane.ready(node, instance))
		sleep(2)
	TEST_ASSERT(lane.ready(node, instance), "The air alarm registers a service.")
	var/datum/netdm_terminal/terminal = allocate(/datum/netdm_terminal, station_apc)
	var/datum/netdm_space/space = new(terminal)
	TEST_ASSERT(space.enter(), "Open a presence at the station APC.")
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && space.presence?["state"] != "active")
		sleep(2)
	TEST_ASSERT(space.presence?["state"] == "active" && space.scan(3), "An active presence scans for the alarm.")
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && !space.items["s|[instance]"])
		space.refresh()
		sleep(5)
	TEST_ASSERT(space.read_alarm(instance), "The map requests a sample from the known alarm.")
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && !findtext(jointext(space.log, " | "), "кПа"))
		space.check_alarm()
		sleep(2)
	TEST_ASSERT(findtext(jointext(space.log, " | "), "[instance] ·") && findtext(jointext(space.log, " | "), "кПа"),
		"The result returns to the network window: [json_encode(space.log)].")

/// The terminal of an APC's network module (network.shell): lines typed at the APC run as pipelines on its
/// module, the records come back over the network, and invoke sends ordinary commands as the APC.
/datum/unit_test/netdm_observe/area_map/network_terminal

/// Sends a line and waits for its entry to be answered.
/datum/unit_test/netdm_observe/area_map/network_terminal/proc/type_line(datum/netdm_terminal/terminal, line, script = FALSE)
	if(!terminal.submit(line, script))
		return null
	var/list/entry = terminal.entries[length(terminal.entries)]
	var/deadline = world.time + 30 SECONDS
	while(world.time < deadline && entry["pending"])
		sleep(2)
	return entry

/// The value of a field in a record of an answered entry.
/datum/unit_test/netdm_observe/area_map/network_terminal/proc/field(list/record, name)
	for(var/list/pair in record)
		if(pair["name"] == name)
			return pair["value"]
	return null

/datum/unit_test/netdm_observe/area_map/network_terminal/Run()
	if(world.GetConfig("env", "NETDM_IPC_MODE") != "v1")
		return
	http_base = world.GetConfig("env", "NETDM_TEST_HTTP")
	TEST_ASSERT(length(http_base), "NETDM_TEST_HTTP must point to the test Host.")
	TEST_ASSERT(wait_until_live(), "Observe must publish the initial map ([SSnetdm_observe.observe_state()]).")
	var/datum/netdm_diagnostics/diagnostics = SSnetdm_observe.diagnostics
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	var/turf/left = run_loc_floor_bottom_left
	var/turf/right = get_step(left, EAST)
	TEST_ASSERT_NOTNULL(right, "Expected two adjacent test cells.")
	assign_area(left, test_zone(/area/netdm_test/first))
	assign_area(right, test_zone(/area/netdm_test/second))
	var/obj/machinery/power/apc/near = allocate(/obj/machinery/power/apc, left)
	var/obj/machinery/power/apc/far = allocate(/obj/machinery/power/apc, right)
	var/list/near_fact = wait_for_fact(WEAKREF(near), left)
	var/list/far_fact = wait_for_fact(WEAKREF(far), right)
	TEST_ASSERT(near_fact && far_fact, "Expected both APCs to be published.")
	var/near_id = near_fact["a"]
	var/far_id = far_fact["a"]
	TEST_ASSERT(wait_for_links(left.z, near_id, 1, TRUE), "The two zones must be wired together.")
	// Opening the terminal shows what the multitool used to print: the module and its ports.
	var/datum/netdm_terminal/terminal = allocate(/datum/netdm_terminal, near)
	TEST_ASSERT_EQUAL(length(terminal.entries), 2, "A new terminal asks for the module and its ports.")
	var/deadline = world.time + 30 SECONDS
	while(world.time < deadline && (terminal.entries[1]["pending"] || terminal.entries[2]["pending"]))
		sleep(2)
	var/list/own = terminal.entries[1]
	var/list/ports = terminal.entries[2]
	TEST_ASSERT(own["status"] == "ok" && length(own["records"]) == 1 && field(own["records"][1], "state") == "active" && field(own["records"][1], "wired") == "1",
		"The module describes itself: [json_encode(own)] [diagnostics.state()] [lane.state()]")
	TEST_ASSERT(ports["status"] == "ok" && length(ports["records"]) == 1 && field(ports["records"][1], "node") == far_id && field(ports["records"][1], "state") == "up",
		"The module lists its port to the neighbour: [json_encode(ports)]")

	var/list/counted = type_line(terminal, "links | where state -eq up | count")
	TEST_ASSERT(counted?["status"] == "ok" && field(counted["records"][1], "count") == "1" && counted["fuel"] > 0, "A pipeline runs on the module: [json_encode(counted)]")
	var/list/wrong = type_line(terminal, "links | explode")
	TEST_ASSERT(wrong?["status"] == "unknown_command" && wrong["position"] == 8 && !length(wrong["records"]),
		"A wrong line is answered with its place: [json_encode(wrong)]")
	TEST_ASSERT(!terminal.submit("") && !terminal.submit(jointext(new /list(1100), "a")), "An empty or oversized line is not sent.")

	// A device with a service behind the far APC: the terminal finds it and sends it a command.
	var/obj/machinery/netdm_test_machine/pump = allocate(/obj/machinery/netdm_test_machine, right)
	var/datum/component/netdm_node/pump_node = netdm_make_node(pump, NETDM_MOUNT_FIXED, 3)
	TEST_ASSERT(wait_for_node(pump_node, right, TRUE), "The pump must reach the Host.")
	var/datum/netdm_service_endpoint/pump_endpoint = lane.endpoint_for(pump_node)
	var/pump_instance = "tterm.[pump_endpoint.id]"
	lane.offer(pump_node, pump_instance, "machine.control", "machine.power_state", 1)
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && !lane.ready(pump_node, pump_instance))
		sleep(5)
	TEST_ASSERT(lane.ready(pump_node, pump_instance), "The pump service must be registered: [lane.state()]")
	var/list/found = type_line(terminal, "services -type machine.control | where instance -eq [pump_instance] | select instance hops")
	TEST_ASSERT(found?["status"] == "ok" && length(found["records"]) == 1 && field(found["records"][1], "hops") == "2",
		"The terminal finds the service two hops away: [json_encode(found)]")
	var/list/sent = type_line(terminal, "services -type machine.control | where instance -eq [pump_instance] | invoke set_power on=true")
	TEST_ASSERT(sent?["status"] == "ok" && length(sent["records"]) == 1 && field(sent["records"][1], "status") == "sent" && length(field(sent["records"][1], "operation")),
		"The terminal sends a command to what it found: [json_encode(sent)]")
	var/list/refused = type_line(terminal, "invoke [pump_instance] set_power on=maybe")
	TEST_ASSERT(refused?["status"] == "ok" && field(refused["records"][1], "status") != "sent", "A command outside its schema is not sent: [json_encode(refused)]")
	var/list/scripted = type_line(terminal, "if links | where state -eq up\n  services -type machine.control | where instance -eq [pump_instance] | invoke set_power on=true\nend", TRUE)
	TEST_ASSERT(scripted?["status"] == "ok" && length(scripted["records"]) == 1 && field(scripted["records"][1], "status") == "sent",
		"A script sends a command when the port is up: [json_encode(scripted)]")

	// Carry a standard data disk to another terminal. Reading it only copies text into the editor.
	var/mob/living/carbon/human/test_user = allocate(/mob/living/carbon/human, left)
	var/obj/item/computer_hardware/hard_drive/portable/disk = allocate(/obj/item/computer_hardware/hard_drive/portable, left)
	var/obj/item/multitool/tool = allocate(/obj/item/multitool, left)
	TEST_ASSERT(test_user.put_in_active_hand(tool) && test_user.put_in_hands(disk), "The operator can hold a multitool and data disk.")
	var/disk_id = REF(disk)
	var/script_source = "if self | where state -eq active\n  self | select node\nend"
	terminal.script_disk_action(test_user, "save_disk", disk_id, "", script_source)
	var/datum/computer_file/data/netdm_script/file = terminal.script_file(disk)
	TEST_ASSERT(file && file.stored_data == script_source && disk.used_capacity == file.size, "The script is stored as a file on the disk.")
	var/file_id = REF(file)
	disk.max_capacity = file.size
	terminal.script_disk_action(test_user, "save_disk", disk_id, file_id, jointext(new /list(400), "self"))
	TEST_ASSERT(file.stored_data == script_source && disk.used_capacity == file.size, "A failed overwrite leaves the file intact.")

	test_user.forceMove(right)
	var/datum/netdm_terminal/other_terminal = allocate(/datum/netdm_terminal, far)
	var/entries_before = length(other_terminal.entries)
	var/lines_before = diagnostics.counters["lines"]
	other_terminal.script_disk_action(test_user, "load_disk", disk_id, file_id)
	TEST_ASSERT_EQUAL(other_terminal.loaded_script?["source"], script_source, "The next terminal can read the same file.")
	TEST_ASSERT(length(other_terminal.entries) == entries_before && diagnostics.counters["lines"] == lines_before, "Loading the file does not submit a script.")
	TEST_ASSERT(test_user.dropItemToGround(disk), "The operator can drop the disk.")
	other_terminal.script_disk_action(test_user, "run_disk", disk_id, file_id)
	TEST_ASSERT_EQUAL(length(other_terminal.entries), entries_before, "A stale disk action cannot run a file outside the operator's hands.")
	TEST_ASSERT(test_user.put_in_hands(disk), "The operator can pick the disk up again.")
	other_terminal.script_disk_action(test_user, "run_disk", disk_id, file_id)
	TEST_ASSERT_EQUAL(length(other_terminal.entries), entries_before + 1, "Running from the disk submits one script.")
	var/list/disk_result = other_terminal.entries[length(other_terminal.entries)]
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && disk_result["pending"])
		sleep(2)
	TEST_ASSERT(disk_result["status"] == "ok" && length(disk_result["records"]) == 1 && field(disk_result["records"][1], "node") == far_id,
		"The script runs from the receiving APC: [json_encode(disk_result)]")

	// The neighbour dies: its port says why, and what stood behind it is gone from the answers.
	far.operating = FALSE
	TEST_ASSERT(wait_for_links(left.z, near_id, 0, TRUE), "The cable to a dead APC carries nothing.")
	var/list/dead = type_line(terminal, "links | where state -ne up | select node state")
	TEST_ASSERT(dead?["status"] == "ok" && length(dead["records"]) == 1 && field(dead["records"][1], "node") == far_id && field(dead["records"][1], "state") == "unpowered",
		"The dead port is named with its cause: [json_encode(dead)]")
	var/list/gone = type_line(terminal, "services -type machine.control | where instance -eq [pump_instance] | count")
	TEST_ASSERT(gone?["status"] == "ok" && field(gone["records"][1], "count") == "0", "A service behind a dead APC is not listed: [json_encode(gone)]")
	var/list/skipped = type_line(terminal, "if links | where state -eq up\n  invoke [pump_instance] set_power on=true\nend", TRUE)
	TEST_ASSERT(skipped?["status"] == "ok" && !length(skipped["records"]), "A script skips its action when the port is down: [json_encode(skipped)]")
	far.operating = TRUE
	TEST_ASSERT(wait_for_links(left.z, near_id, 1, TRUE), "Closing the breaker restores the cable.")

	// A PDA runs the same shell locally and its commands reach the pump over radio and wire.
	TEST_ASSERT(test_user.dropItemToGround(tool), "Free a hand for the PDA while keeping the script disk.")
	var/obj/item/modular_computer/pda/pda = allocate(/obj/item/modular_computer/pda, right)
	TEST_ASSERT(test_user.put_in_hands(pda) && pda.turn_on(test_user, FALSE), "The operator can hold and power on a PDA.")
	var/datum/component/netdm_node/pda_node = pda.GetComponent(/datum/component/netdm_node)
	TEST_ASSERT(pda_node, "The PDA already has a network node for its messenger.")
	var/list/pda_fact = wait_for_node(pda_node, right, FALSE)
	TEST_ASSERT(pda_fact, "The carried PDA must be published as a mobile node.")
	var/datum/netdm_terminal/local/pda/mobile = allocate(/datum/netdm_terminal/local/pda, pda, pda_node, test_user)
	var/list/mobile_self = type_line(mobile, "self | select node radio")
	TEST_ASSERT(mobile_self?["status"] == "ok" && length(mobile_self["records"]) == 1 && field(mobile_self["records"][1], "node") == pda_fact["a"] && field(mobile_self["records"][1], "radio") == "true",
		"The PDA shell reads its own mobile node: [json_encode(mobile_self)]")
	var/pda_endpoint_id = lane.endpoint_for(pda_node).id
	var/list/private_shell = type_line(terminal, "services -type network.shell | where instance -eq netshell.[pda_endpoint_id] | count")
	TEST_ASSERT(private_shell?["status"] == "ok" && field(private_shell["records"][1], "count") == "0", "Another device cannot discover the PDA's local shell.")
	var/list/mobile_sent = type_line(mobile, "services -type machine.control | where instance -eq [pump_instance] | invoke set_power on=true", TRUE)
	TEST_ASSERT(mobile_sent?["status"] == "ok" && length(mobile_sent["records"]) == 1 && field(mobile_sent["records"][1], "status") == "sent",
		"The PDA finds and sends a command to a wired service via radio: [json_encode(mobile_sent)]")
	var/turf/out_of_range = isolated_turf()
	TEST_ASSERT(out_of_range, "The test map has a spot outside APC radio coverage.")
	TEST_ASSERT(mobile.start_program("pda-watch", "on trace [far_id] | select state\nself"), "The PDA can start a background rule.")
	var/list/pda_started = mobile.entries[length(mobile.entries)]
	deadline = world.time + 20 SECONDS
	while(pda_started["pending"] && world.time < deadline)
		sleep(2)
	TEST_ASSERT_EQUAL(pda_started["status"], "started", "The PDA receives its program number.")
	var/pda_program = field(pda_started["records"][1], "program")
	var/list/baseline
	deadline = world.time + 20 SECONDS
	while(world.time < deadline)
		baseline = type_line(mobile, "programs | select program state runs fuel")
		if(baseline?["status"] == "ok" && length(baseline["records"]) && text2num(field(baseline["records"][1], "fuel")) > 0)
			break
		sleep(2)
	TEST_ASSERT(baseline?["status"] == "ok" && length(baseline["records"]) == 1 && field(baseline["records"][1], "runs") == "0" && text2num(field(baseline["records"][1], "fuel")) > 0,
		"The PDA rule has observed its initial route: [json_encode(baseline)]")
	pda.shutdown_computer()
	TEST_ASSERT(!mobile.submit("self"), "A powered-off PDA cannot submit commands.")
	deadline = world.time + 20 SECONDS
	while(world.time < deadline && SSnetdm_observe.node_facts[pda_node]?["executionPowered"] != 0)
		sleep(2)
	TEST_ASSERT_EQUAL(SSnetdm_observe.node_facts[pda_node]?["executionPowered"], 0, "Host acknowledges the standby fact without removing the node.")
	test_user.forceMove(out_of_range)
	TEST_ASSERT(wait_for_node(pda_node, out_of_range, FALSE), "The PDA follows the operator while off.")
	sleep(2 SECONDS)
	test_user.forceMove(right)
	TEST_ASSERT(wait_for_node(pda_node, right, FALSE), "The powered-off PDA returns to its original route.")
	TEST_ASSERT(pda.turn_on(test_user, FALSE), "The operator boots the PDA.")
	deadline = world.time + 20 SECONDS
	while(world.time < deadline && SSnetdm_observe.node_facts[pda_node]?["executionPowered"] != 1)
		sleep(2)
	TEST_ASSERT_EQUAL(SSnetdm_observe.node_facts[pda_node]?["executionPowered"], 1, "Host acknowledges the boot fact.")
	var/list/resumed = type_line(mobile, "programs | select program state runs")
	TEST_ASSERT(resumed?["status"] == "ok" && length(resumed["records"]) == 1 && field(resumed["records"][1], "program") == pda_program && field(resumed["records"][1], "runs") == "0",
		"The same rule survives shutdown and ignores changes while off: [json_encode(resumed)]")
	test_user.forceMove(out_of_range)
	TEST_ASSERT(wait_for_node(pda_node, out_of_range, FALSE), "The PDA follows the operator out of range.")
	var/list/lost = type_line(mobile, "trace [far_id] | select state")
	TEST_ASSERT(lost?["status"] == "ok" && field(lost["records"][1], "state") == "unreachable",
		"The PDA shell runs locally, but can no longer reach the far APC: [json_encode(lost)]")
	var/list/fired
	deadline = world.time + 20 SECONDS
	while(world.time < deadline)
		fired = type_line(mobile, "programs | select program state runs")
		if(fired?["status"] == "ok" && length(fired["records"]) && field(fired["records"][1], "runs") == "1")
			break
		sleep(2)
	TEST_ASSERT(fired?["status"] == "ok" && length(fired["records"]) == 1 && field(fired["records"][1], "program") == pda_program && field(fired["records"][1], "state") == "watching" && field(fired["records"][1], "runs") == "1",
		"The resumed rule fires once for a change while powered: [json_encode(fired)]")
	TEST_ASSERT(mobile.stop_program(pda_program), "The operator can stop the program.")
	var/list/pda_stopped = mobile.entries[length(mobile.entries)]
	deadline = world.time + 20 SECONDS
	while(pda_stopped["pending"] && world.time < deadline)
		sleep(2)
	TEST_ASSERT_EQUAL(pda_stopped["status"], "stopped", "The PDA receives the stop result.")
	TEST_ASSERT(test_user.dropItemToGround(pda), "The operator can put the PDA down.")
	TEST_ASSERT(!mobile.submit("self"), "The previous operator cannot submit after dropping the PDA.")

	test_user.forceMove(right)
	var/obj/item/implant/netdm_terminal/implant = allocate(/obj/item/implant/netdm_terminal, right)
	TEST_ASSERT(implant.implant(test_user, test_user, TRUE) && implant.node, "Installing the implant creates its own network component.")
	var/list/implant_fact = wait_for_node(implant.node, right, FALSE)
	TEST_ASSERT(implant_fact && implant_fact["a"] != pda_fact["a"] && !implant.loc, "The implant has a separate node at its wearer even though the item is in nullspace.")
	var/datum/netdm_terminal/local/implant/implanted = allocate(/datum/netdm_terminal/local/implant, implant, implant.node, test_user)
	var/list/implant_self = type_line(implanted, "if self | where radio -eq true\n  self | select node\nend", TRUE)
	TEST_ASSERT(implant_self?["status"] == "ok" && length(implant_self["records"]) == 1 && field(implant_self["records"][1], "node") == implant_fact["a"],
		"The implant runs a script from its own radio node: [json_encode(implant_self)]")
	var/list/implant_sent = type_line(implanted, "services -type machine.control | where instance -eq [pump_instance] | invoke set_power on=true", TRUE)
	TEST_ASSERT(implant_sent?["status"] == "ok" && length(implant_sent["records"]) == 1 && field(implant_sent["records"][1], "status") == "sent",
		"The implant sends commands to services within radio reach: [json_encode(implant_sent)]")
	TEST_ASSERT(implanted.start_program("watch", "on self | select radio\nself"), "The implant can start a resident rule.")
	var/list/started = implanted.entries[length(implanted.entries)]
	deadline = world.time + 20 SECONDS
	while(started["pending"] && world.time < deadline)
		sleep(2)
	TEST_ASSERT_EQUAL(started["status"], "started", "The start result reaches the implant's terminal.")
	var/program_id = field(started["records"][1], "program")
	var/list/listed_programs = type_line(implanted, "programs | select program name")
	TEST_ASSERT(listed_programs?["status"] == "ok" && length(listed_programs["records"]) == 1 && field(listed_programs["records"][1], "program") == program_id,
		"The implant sees its own program.")
	TEST_ASSERT(implanted.stop_program(program_id), "The implant can stop its rule.")
	var/list/stopped = implanted.entries[length(implanted.entries)]
	deadline = world.time + 20 SECONDS
	while(stopped["pending"] && world.time < deadline)
		sleep(2)
	TEST_ASSERT_EQUAL(stopped["status"], "stopped", "The stop result reaches the implant's terminal.")
	TEST_ASSERT(implanted.start_program("kept", "on self | select radio\nself", TRUE), "The implant can keep a rule on its media.")
	var/list/kept_start = implanted.entries[length(implanted.entries)]
	deadline = world.time + 20 SECONDS
	while(kept_start["pending"] && world.time < deadline)
		sleep(2)
	TEST_ASSERT_EQUAL(kept_start["status"], "started", "A kept rule starts like any program.")
	var/list/kept_on_media = implanted.kept_names()
	var/kept_record = json_encode(implant.netdm_programs)
	TEST_ASSERT(length(kept_on_media) == 1 && kept_on_media[1] == "kept" && length(implant.netdm_programs) == 1, "The rule is written to the implant: [kept_record]")
	test_user.forceMove(left)
	TEST_ASSERT(wait_for_node(implant.node, left, FALSE)?["a"] == implant_fact["a"], "The implant keeps its node as its wearer moves.")
	var/datum/component/netdm_node/extracted_node = implant.node
	TEST_ASSERT(implant.removed(test_user, TRUE) && QDELETED(extracted_node) && !implanted.submit("self"), "Removing the implant retires its node and closes the execution path.")
	// The implant carries what it keeps: installed again, its new node starts the rule by itself.
	TEST_ASSERT(implant.implant(test_user, test_user, TRUE) && implant.node && implant.node != extracted_node, "The implant can be installed again.")
	var/datum/netdm_terminal/local/implant/reinstalled = allocate(/datum/netdm_terminal/local/implant, implant, implant.node, test_user)
	var/list/kept_listed
	deadline = world.time + 40 SECONDS
	while(world.time < deadline)
		kept_listed = type_line(reinstalled, "programs | select program name")
		if(kept_listed?["status"] == "ok" && length(kept_listed["records"]) == 1 && field(kept_listed["records"][1], "name") == "kept")
			break
		sleep(5)
	TEST_ASSERT(kept_listed?["status"] == "ok" && length(kept_listed["records"]) == 1 && field(kept_listed["records"][1], "name") == "kept",
		"The reinstalled implant starts its kept rule on attach: [json_encode(kept_listed)]")
	var/kept_id = text2num(field(kept_listed["records"][1], "program"))
	deadline = world.time + 10 SECONDS
	while(world.time < deadline && !(length(implant.netdm_programs) && implant.netdm_programs[1]["program"] == kept_id))
		sleep(2)
	var/media_record = json_encode(implant.netdm_programs)
	TEST_ASSERT(length(implant.netdm_programs) && implant.netdm_programs[1]["program"] == kept_id, "The implant's media learns the entity's number: [media_record]")
	// NetEntity: the rule moves to the APC's shell, while the implant's media still names it.
	var/datum/netdm_service_endpoint/apc_endpoint = SSnetdm_observe.services.endpoint_for(near)
	var/list/moved_entry = null
	if(apc_endpoint && reinstalled.migrate_program(kept_id, "netshell.[apc_endpoint.id]"))
		moved_entry = reinstalled.entries[length(reinstalled.entries)]
		deadline = world.time + 20 SECONDS
		while(moved_entry["pending"] && world.time < deadline)
			sleep(2)
	TEST_ASSERT_EQUAL(moved_entry?["status"], "migrated", "The implant moves its rule to the APC: [json_encode(moved_entry)]")
	extracted_node = implant.node
	TEST_ASSERT(implant.removed(test_user, TRUE) && QDELETED(extracted_node), "The implant is removed again.")
	// Installed once more, the implant asks for the copy its media names and learns it moved: no second copy runs.
	TEST_ASSERT(implant.implant(test_user, test_user, TRUE) && implant.node, "The implant goes in a third time.")
	deadline = world.time + 40 SECONDS
	while(world.time < deadline && length(implant.netdm_programs))
		sleep(5)
	media_record = json_encode(implant.netdm_programs)
	TEST_ASSERT(!length(implant.netdm_programs), "A moved entity leaves the media instead of starting twice: [media_record]")
	extracted_node = implant.node
	TEST_ASSERT(implant.removed(test_user, TRUE) && QDELETED(extracted_node), "The implant is removed for the rest of the test.")

	var/obj/item/netdm_adapter/adapter = allocate(/obj/item/netdm_adapter, left)
	TEST_ASSERT(test_user.put_in_hands(adapter), "The operator can hold the adapter and data disk.")
	TEST_ASSERT(!adapter.connect_to(pump, test_user), "The adapter cannot connect through a closed service panel.")
	pump.panel_open = TRUE
	TEST_ASSERT(adapter.connect_to(pump, test_user) && adapter.connected(), "The adapter physically docks to a networked machine.")
	var/list/adapter_fact = wait_for_node(adapter.node, right, TRUE)
	TEST_ASSERT(adapter_fact && adapter_fact["a"] != far_id && adapter_fact["a"] != SSnetdm_observe.node_ids[pump_node] && has_edge(right.z, adapter_fact["a"], far_id),
		"The adapter has its own wired port to the local APC.")
	var/datum/netdm_terminal/local/adapter/docked = allocate(/datum/netdm_terminal/local/adapter, adapter, adapter.node, test_user)
	var/list/adapter_self = type_line(docked, "self | select node devices radio", TRUE)
	TEST_ASSERT(adapter_self?["status"] == "ok" && length(adapter_self["records"]) == 1 && field(adapter_self["records"][1], "node") == adapter_fact["a"] && field(adapter_self["records"][1], "devices") == "1" && field(adapter_self["records"][1], "radio") == "false",
		"The docked adapter executes on its own wired node: [json_encode(adapter_self)]")
	var/datum/component/netdm_node/docked_node = adapter.node
	pump.forceMove(left)
	TEST_ASSERT(!adapter.connected() && QDELETED(docked_node) && !docked.submit("self"), "Moving the machine disconnects the adapter and invalidates its terminal.")
	TEST_ASSERT(test_user.put_in_hands(adapter) && adapter.connect_to(near, test_user), "The adapter can also connect directly to an APC.")
	adapter.disconnect()
	TEST_ASSERT(!adapter.connected() && !adapter.anchored, "The detached adapter is portable again.")

	// P12.4: the network window of the APC terminal. The APC is the operator; its presence stands on its shell.
	var/datum/netdm_space/space = new(terminal)
	var/datum/netdm_space_actor/terminal/source = space.actor
	TEST_ASSERT(istype(source) && source.window == space && source.network_node() == terminal.node_ref?.resolve() && source.shell_provider() == terminal.shell_provider(),
		"A legacy terminal is adapted into a network-space actor without changing its real endpoint.")
	TEST_ASSERT(terminal.space == space && space.enter(), "The window sends the presence command.")
	deadline = world.time + 20 SECONDS
	while(world.time < deadline && space.presence?["state"] != "active")
		sleep(2)
	TEST_ASSERT_EQUAL(space.presence?["state"], "active", "The operator enters the network: [json_encode(space.presence)] [json_encode(space.log)]")
	TEST_ASSERT(space.scan(2), "The window scans from the presence.")
	deadline = world.time + 20 SECONDS
	while(world.time < deadline && !findtext(jointext(space.log, " | "), "Сканирование:"))
		sleep(2)
	var/scan_log = jointext(space.log, " | ")
	TEST_ASSERT(findtext(scan_log, "Сканирование:"), "The scan is answered: [scan_log]")
	deadline = world.time + 20 SECONDS
	while(world.time < deadline && !(space.items["n|[near_id]"] && space.host_node() == near_id))
		space.refresh()
		sleep(5)
	var/list/view = space.ui_data(null)
	var/known_record = json_encode(space.items)
	TEST_ASSERT(space.items["n|[near_id]"] && space.host_node() == near_id && length(view["nodes"]) >= 1,
		"The window knows its APC and shows the presence there: host=[space.host_node()] [known_record]")
	TEST_ASSERT(space.act_line("self | select node"), "The window sends a line to the presence.")
	deadline = world.time + 20 SECONDS
	while(world.time < deadline && !findtext(jointext(space.log, " | "), "> self | select node:"))
		sleep(2)
	var/act_log = jointext(space.log, " | ")
	TEST_ASSERT(findtext(act_log, "> self | select node: node=[near_id]"), "The line runs where the presence stands: [act_log]")
	TEST_ASSERT(space.leave(), "The window sends leave.")
	deadline = world.time + 20 SECONDS
	while(world.time < deadline && space.presence?["state"] != "ended")
		sleep(2)
	TEST_ASSERT_EQUAL(space.presence?["state"], "ended", "The operator leaves the network: [json_encode(space.presence)]")
	qdel(space)
	TEST_ASSERT(!terminal.space, "Closing the window detaches it from the terminal.")

	// A terminal at a dead module is not opened.
	TEST_ASSERT(!diagnostics.open_terminal(near, null), "A terminal needs someone to open it.")
	// The APC terminal opens like the APC interface: access, or an unlocked or emagged interface.
	var/was_locked = near.locked
	near.locked = TRUE
	TEST_ASSERT(!diagnostics.terminal_access(near, test_user), "Without engineering access a locked APC keeps its terminal closed.")
	near.locked = FALSE
	TEST_ASSERT(diagnostics.terminal_access(near, test_user), "An unlocked APC interface opens its terminal.")
	near.locked = TRUE
	var/obj/item/card/id/engineer_id = allocate(/obj/item/card/id, left)
	engineer_id.access = list(ACCESS_ENGINE_EQUIP)
	test_user.drop_all_held_items()
	TEST_ASSERT(test_user.put_in_active_hand(engineer_id) && diagnostics.terminal_access(near, test_user),
		"Engineering access opens the terminal of a locked APC.")
	near.locked = was_locked
	log_world("netDM network terminal: lines=[diagnostics.counters["lines"]] [diagnostics.state()]")

/// Headless test users have no client. Grant only this door's panel authority to this fixture's operator.
/obj/machinery/door/airlock/netdm_panel_test
	var/datum/weakref/test_operator

/obj/machinery/door/airlock/netdm_panel_test/netdm_panel_allowed(mob/user)
	return user && user == test_operator?.resolve()

/obj/machinery/door/airlock/netdm_panel_test/user_allowed(mob/user)
	return netdm_panel_allowed(user)

/datum/unit_test/netdm_observe/area_map/network_airlock_panel/Run()
	if(world.GetConfig("env", "NETDM_IPC_MODE") != "v1")
		return
	http_base = world.GetConfig("env", "NETDM_TEST_HTTP")
	TEST_ASSERT(wait_until_live(), "Observe must publish the initial map.")
	var/turf/left = run_loc_floor_bottom_left
	var/turf/right = get_step(left, EAST)
	assign_area(left, test_zone(/area/netdm_test/first))
	assign_area(right, test_zone(/area/netdm_test/second))
	var/obj/machinery/power/apc/near = allocate(/obj/machinery/power/apc, left)
	var/obj/machinery/power/apc/far = allocate(/obj/machinery/power/apc, right)
	TEST_ASSERT(wait_for_fact(WEAKREF(near), left) && wait_for_fact(WEAKREF(far), right), "Both APCs must be published.")
	var/mob/living/carbon/human/operator = allocate(/mob/living/carbon/human, left)
	var/obj/machinery/door/airlock/netdm_panel_test/door = allocate(/obj/machinery/door/airlock/netdm_panel_test, right)
	door.test_operator = WEAKREF(operator)
	door.locked = FALSE
	door.welded = FALSE
	var/instance = SSnetdm_observe.doors.add_door(door)
	var/datum/component/netdm_node/node = door.GetComponent(/datum/component/netdm_node)
	TEST_ASSERT(instance && node, "The test airlock must offer its command service.")
	var/deadline = world.time + 40 SECONDS
	while(world.time < deadline && !SSnetdm_observe.services.ready(node, instance))
		sleep(2)
	TEST_ASSERT(SSnetdm_observe.services.ready(node, instance), "Host registered the airlock service.")
	var/datum/netdm_terminal/terminal = allocate(/datum/netdm_terminal, near)
	var/datum/netdm_space/space = allocate(/datum/netdm_space, terminal)
	TEST_ASSERT(space.enter(), "The terminal can enter the network.")
	deadline = world.time + 20 SECONDS
	while(world.time < deadline && space.presence?["state"] != "active")
		sleep(2)
	TEST_ASSERT_EQUAL(space.presence?["state"], "active", "The operator has an active presence.")
	TEST_ASSERT(space.scan(3), "The presence can discover the airlock.")
	deadline = world.time + 20 SECONDS
	while(world.time < deadline && !space.items["s|[instance]"])
		space.refresh()
		sleep(5)
	TEST_ASSERT(space.items["s|[instance]"], "The presence has seen the airlock: [jointext(space.log, " | ")]")

	var/list/action = list("instance" = instance, "command" = "open")
	var/datum/netdm_command_handler/airlock_panel/handler = new
	TEST_ASSERT_EQUAL(handler.execute(door, list("payload" = list("action" = "open", "ticket" = "invented"))), "access_denied",
		"A direct wire call cannot invent a panel ticket.")
	qdel(handler)
	TEST_ASSERT(space.dispatch_ui_action("device_action", action, null, GLOB.always_state), "An unauthorized attempt returns an explicit refusal.")
	TEST_ASSERT(space.machine_command?["reason"] == "access_denied" && !space.machine_command?["ticket"] && door.density,
		"The refusal does not queue or open the door.")
	TEST_ASSERT(!space.dispatch_ui_action("device_action", list("instance" = instance, "command" = "toggle"), operator, GLOB.always_state),
		"The panel API accepts absolute actions.")
	TEST_ASSERT(space.dispatch_ui_action("device_action", action, operator, GLOB.always_state), "The authorized operator can issue an Open request.")
	deadline = world.time + 25 SECONDS
	while(world.time < deadline && space.machine_pending())
		sleep(2)
	var/list/receipt = space.machine_command
	TEST_ASSERT(receipt?["status"] == "applied" && receipt["receipt_received"] && receipt["door_open"] && !door.density,
		"Delivery and the finished opening are both required: [receipt?["status"]] [receipt?["reason"]].")
	qdel(door)

/// P13 immersion: the dive layer is opt-in, and the access point of the body is a working APC of its zone.
/datum/unit_test/netdm_observe/area_map/network_immersion/Run()
	if(world.GetConfig("env", "NETDM_IPC_MODE") != "v1")
		return
	http_base = world.GetConfig("env", "NETDM_TEST_HTTP")
	TEST_ASSERT(wait_until_live(), "Observe must publish the station map.")
	var/flagged = world.GetConfig("env", "NETDM_NET_IMMERSION") == "1"
	TEST_ASSERT_EQUAL(netdm_immersion_enabled(), flagged, "The dive layer is off unless the round starts it.")
	TEST_ASSERT_EQUAL(immersion_reason_text("implant_lost"), "имплант извлечён или уничтожен", "A lost implant is named.")
	TEST_ASSERT_EQUAL(immersion_reason_text("access_point_lost"), "потеряна точка доступа", "A lost access point is named.")
	var/obj/machinery/power/apc/station_apc
	for(var/obj/machinery/power/apc/apc as anything in GLOB.apcs_list)
		if(is_station_level(apc.z) && apc.netdm_state() == NETDM_STATE_UP && !is_antag_training_atom(apc))
			station_apc = apc
			break
	TEST_ASSERT(station_apc, "The station has a powered APC.")
	var/turf/here = get_turf(station_apc)
	var/area/zone = netdm_power_area(get_area(here))
	var/mob/living/carbon/human/body = allocate(/mob/living/carbon/human, here)
	var/obj/machinery/power/apc/resolved = netdm_access_point(body)
	TEST_ASSERT(resolved, "A working APC of the body's zone is an access point ([station_apc] state [station_apc.netdm_state()], zone [zone], zone APC [zone?.power_apc]).")
	TEST_ASSERT(netdm_access_point_ok(resolved), "The access point is powered, operational and networked.")
	TEST_ASSERT_EQUAL(netdm_access_point(body), resolved, "The access point of the zone is stable while it works.")
	var/list/zone_apcs = list()
	for(var/obj/machinery/power/apc/candidate as anything in GLOB.apcs_list)
		if(netdm_power_area(get_area(candidate)) == netdm_power_area(get_area(resolved)))
			zone_apcs += candidate
	for(var/obj/machinery/power/apc/candidate as anything in zone_apcs)
		candidate.operating = FALSE
	TEST_ASSERT(isnull(netdm_access_point(body)), "A zone without a working APC has no access point.")
	for(var/obj/machinery/power/apc/candidate as anything in zone_apcs)
		candidate.operating = TRUE
	TEST_ASSERT(netdm_access_point(body), "The repaired zone is an access point again.")


/// P13 dive: a conscious body with a neuro-link at a working access point enters the network; losing the
/// access point ends the dive and gives the body back its hands. The window is the same one operators
/// use: the dive adds presentation and a body state, not a second channel of commands.
/datum/unit_test/netdm_observe/area_map/network_immersion_dive/Run()
	if(world.GetConfig("env", "NETDM_IPC_MODE") != "v1")
		return
	http_base = world.GetConfig("env", "NETDM_TEST_HTTP")
	TEST_ASSERT(wait_until_live(), "Observe must publish the station map.")
	TEST_ASSERT(netdm_immersion_enabled(), "The test round enables the dive layer.")
	var/obj/machinery/power/apc/station_apc
	for(var/obj/machinery/power/apc/apc as anything in GLOB.apcs_list)
		if(!is_station_level(apc.z) || apc.netdm_state() != NETDM_STATE_UP || is_antag_training_atom(apc) || !SSnetdm_observe.apc_node_id(apc))
			continue
		station_apc = apc
		break
	TEST_ASSERT(station_apc, "The station has a published APC access point.")
	var/area/zone = netdm_power_area(get_area(station_apc))
	var/list/zone_apcs = list()
	for(var/obj/machinery/power/apc/candidate as anything in GLOB.apcs_list)
		if(netdm_power_area(get_area(candidate)) == zone)
			zone_apcs += candidate
	var/turf/here = get_turf(station_apc)
	var/mob/living/carbon/human/body = allocate(/mob/living/carbon/human, here)
	var/obj/item/implant/netdm_terminal/link = allocate(/obj/item/implant/netdm_terminal, here)
	link.implant(body)
	TEST_ASSERT_EQUAL(link.imp_in, body, "The neuro-link sits in the body.")
	var/deadline = world.time + 30 SECONDS
	while(world.time < deadline && !link.node)
		sleep(2)
	TEST_ASSERT(link.node, "The neuro-link joins the network.")
	var/datum/netdm_terminal/local/implant/terminal = allocate(/datum/netdm_terminal/local/implant, link, link.node, body)
	var/datum/netdm_space/space = new(terminal)
	TEST_ASSERT(space.immerse(), "The dive starts from the network window.")
	TEST_ASSERT(netdm_click_blocked(body), "The dive blocks clicks into the room.")
	TEST_ASSERT(space.immersed, "The window presents the immersion.")
	TEST_ASSERT(HAS_TRAIT(body, TRAIT_HANDS_BLOCKED), "The body loses its hands while the mind is elsewhere.")
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && space.presence?["state"] != "active")
		sleep(2)
	TEST_ASSERT_EQUAL(space.presence?["state"], "active", "The presence entered the network from the access point.")
	// The neuro-link keeps its owner's identity: a fresh endpoint restores it over the network.
	link.netdm_persona = list("name" = "tester", "signature" = "T", "colour" = 1)
	space.persona_restored = FALSE
	space.restore_persona()
	deadline = world.time + 20 SECONDS
	while(world.time < deadline && (!islist(space.presence) || "[space.presence["personaName"]]" != "tester"))
		sleep(2)
	TEST_ASSERT(islist(space.presence), "The presence is known while restoring the identity.")
	TEST_ASSERT_EQUAL("[space.presence["personaName"]]", "tester", "A re-implanted neuro-link restores its owner's identity.")
	TEST_ASSERT_EQUAL(text2num("[space.presence["personaColour"]]"), 1, "The stored colour is restored too.")
	// A presence that leaves the network ends the dive at once: the operator's own exit does not wait
	// for a poll, and the mind returns to the body.
	space.leave()
	deadline = world.time + 10 SECONDS
	while(world.time < deadline && space.immersed)
		sleep(1)
	TEST_ASSERT(!space.immersed, "A presence that leaves the network ends the dive.")
	TEST_ASSERT_EQUAL(space.immersed_reason, "presence_lost", "The dive names the lost presence.")
	TEST_ASSERT(!HAS_TRAIT(body, TRAIT_HANDS_BLOCKED), "The body gets its hands back when the presence leaves.")
	TEST_ASSERT(!netdm_click_blocked(body), "The room answers clicks again after the dive.")
	// The window can enter the network again: the access point is still there.
	var/redived = FALSE
	deadline = world.time + 20 SECONDS
	while(world.time < deadline && !redived)
		redived = space.immerse()
		if(!redived)
			sleep(5)
	TEST_ASSERT(redived && space.immersed, "The dive can start again after the presence left: [json_encode(space.log)]")
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && (!islist(space.presence) || "[space.presence["state"]]" != "active"))
		sleep(2)
	TEST_ASSERT(islist(space.presence) && "[space.presence["state"]]" == "active", "The presence is active again.")

	// The access point disappears: the dive ends with the reason and the body comes back to its senses.
	for(var/obj/machinery/power/apc/candidate as anything in zone_apcs)
		candidate.operating = FALSE
	deadline = world.time + 20 SECONDS
	while(world.time < deadline && space.immersed)
		sleep(2)
	TEST_ASSERT(!space.immersed, "A broken access point ends the dive.")
	TEST_ASSERT_EQUAL(space.immersed_reason, "access_point_lost", "The dive names the lost access point.")
	TEST_ASSERT(!HAS_TRAIT(body, TRAIT_HANDS_BLOCKED), "The body gets its hands back after the dive.")
	TEST_ASSERT(!netdm_click_blocked(body), "The room answers clicks after the lost access point.")
	for(var/obj/machinery/power/apc/candidate as anything in zone_apcs)
		candidate.operating = TRUE
	qdel(space)
/datum/unit_test/netdm_observe/area_map/network_life_physical/Run()
	if(world.GetConfig("env", "NETDM_IPC_MODE") != "v1")
		return
	http_base = world.GetConfig("env", "NETDM_TEST_HTTP")
	TEST_ASSERT(wait_until_live(), "Observe must publish the station map.")
	var/obj/machinery/power/apc/station_apc
	for(var/obj/machinery/power/apc/apc as anything in GLOB.apcs_list)
		if(!is_station_level(apc.z) || apc.netdm_state() != NETDM_STATE_UP || is_antag_training_atom(apc) || !SSnetdm_observe.apc_node_id(apc))
			continue
		station_apc = apc
		break
	TEST_ASSERT(station_apc, "The station has a published APC module.")
	var/node = SSnetdm_observe.apc_node_id(station_apc)
	// The population is seeded asynchronously by the Host: wait for an agent to stand on the APC
	// instead of assuming it is there the moment the map is live (the seeding is a control round trip).
	var/pinged = FALSE
	var/deadline = world.time + 20 SECONDS
	while(world.time < deadline && !pinged)
		pinged = SSnetdm_observe.netdm_ambient_ping(station_apc)
		if(!pinged)
			sleep(5)
	// A busy agent leaves an audible trace next to the APC, once per cooldown.
	TEST_ASSERT(pinged, "An agent on the APC pings it.")
	TEST_ASSERT(!SSnetdm_observe.netdm_ambient_ping(station_apc), "The ambient ping respects its cooldown.")
	// An intruder trips the breaker; engineers can restore it by hand afterwards.
	station_apc.operating = TRUE
	TEST_ASSERT(SSnetdm_observe.netdm_sabotage(station_apc, node), "An intruder trips the APC breaker.")
	TEST_ASSERT(!station_apc.operating, "The breaker is off after the intrusion.")
	TEST_ASSERT(!SSnetdm_observe.netdm_sabotage(station_apc, node), "Sabotage respects its cooldown.")
	station_apc.operating = TRUE


/// Host-accepted shell watches are declarations, not local subscriptions.
/// They survive a Host reset, retain delivery settings, and disappear on unwatch.
/datum/unit_test/netdm_shell_watch_reconnect/Run()
	var/datum/netdm_service_lane/lane = new
	var/datum/netdm_service_endpoint/endpoint = new
	endpoint.id = "watch-test"
	lane.endpoints[endpoint.id] = endpoint
	TEST_ASSERT(lane.remember_shell_watch(endpoint, "oxygen", "atmos.sensor",
		"atmos.sample", 1, "full", "queue", 4), "Accepted watch should be remembered.")
	var/list/declaration = endpoint.subscriptions["oxygen"]
	TEST_ASSERT_EQUAL(declaration["schema"], "atmos.sample", "Reconciliation must keep the authorized schema.")
	TEST_ASSERT_EQUAL(declaration["mode"], "queue", "Reconciliation must keep the queue delivery mode.")
	TEST_ASSERT_EQUAL(declaration["pending"], 4, "Reconciliation must keep the pending queue limit.")
	TEST_ASSERT(endpoint.subscribed["oxygen"], "A Host-accepted watch must not be subscribed twice.")
	endpoint.event_journal += list(list("key" = "oxygen"))
	lane.reset_session()
	TEST_ASSERT(endpoint.event_watches["oxygen"], "Host reset must retain the player's watch declaration.")
	TEST_ASSERT(endpoint.subscriptions["oxygen"], "Host reset must retain the reconciliation specification.")
	TEST_ASSERT(!endpoint.subscribed["oxygen"], "Host reset must invalidate prior transport acceptance.")
	TEST_ASSERT(!length(endpoint.event_journal), "Events from the old transport must not be replayed.")
	TEST_ASSERT(lane.forget_shell_watch(endpoint, "oxygen"), "Unwatch should forget accepted shell watch.")
	TEST_ASSERT(!endpoint.subscriptions["oxygen"] && !endpoint.event_watches["oxygen"],
		"Unwatch must not allow subscription resurrection after reconnect.")
	TEST_ASSERT(!lane.wanted_by["atmos.sensor"], "Unwatch must remove provider tracking.")
	qdel(lane)

/datum/netdm_bridge/v1/staged/lane_test
	var/block_publish = FALSE
	var/list/requests = list()

/datum/netdm_bridge/v1/staged/lane_test/request(list/fields)
	if(block_publish && fields["op"] == "publish")
		return null
	requests += fields["op"]
	return "lane-test-[length(requests)]"

/datum/netdm_service_lane/test/node_id(datum/node)
	return "1"

/datum/unit_test/netdm_service_lane_progress/Run()
	var/datum/netdm_service_lane/test/lane = new
	var/datum/netdm_bridge/v1/staged/lane_test/bridge = new
	var/datum/netdm_service_endpoint/endpoint = new
	var/obj/item/device = allocate(/obj/item)
	var/datum/component/netdm_node/node = device.AddComponent(/datum/component/netdm_node)
	endpoint.node = node
	endpoint.id = "lane-source"
	endpoint.attached_node = "1"
	lane.endpoints[endpoint.id] = endpoint
	lane.by_node[node] = endpoint
	lane.next_poll = world.time + 10 SECONDS

	for(var/index in 1 to 16)
		var/instance = "atmos.test.[index]"
		endpoint.registered[instance] = TRUE
		lane.publish(node, instance, list("pressureKPa" = index))
	bridge.block_publish = TRUE
	lane.pump(bridge)
	TEST_ASSERT_EQUAL(length(lane.publishes), 16, "A native queue refusal must not discard the pending publication.")
	TEST_ASSERT(!length(bridge.requests), "A refused publication must not count as an admitted request.")
	bridge.block_publish = FALSE
	TEST_ASSERT(lane.invoke(node, "camera.test", "acquire", "sample", list("request" = "sample")), "The command should queue.")
	TEST_ASSERT(lane.query_command(node, "1", null), "The status query should queue.")
	lane.pump(bridge)
	TEST_ASSERT("invoke" in bridge.requests, "Queued telemetry must leave room to send the command.")
	TEST_ASSERT("command_status" in bridge.requests, "Queued telemetry must leave room to confirm an operation.")
	TEST_ASSERT(length(lane.publishes), "Only part of the telemetry backlog should be sent.")
	TEST_ASSERT_EQUAL(length(lane.inflight), 14, "An ACK and poll must still fit in the in-flight budget.")

	lane.pending_acks += list(list("deliveryId" = "1", "applied" = TRUE))
	lane.pump(bridge)
	TEST_ASSERT("delivery_ack" in bridge.requests, "An ACK must progress before ordinary requests are answered.")
	TEST_ASSERT("delivery_poll" in bridge.requests, "A poll must progress before ordinary requests are answered.")
	TEST_ASSERT_EQUAL(length(lane.inflight), 16, "Inbox work must respect the total in-flight budget.")
	qdel(bridge)
	qdel(lane)
	qdel(endpoint)


/// A new network-space source has no implicit rights, and survives the destruction
/// of a UI window that it did not create. Digital entities must supply their own
/// authenticated endpoint and UI policy rather than borrowing an APC terminal.
/datum/unit_test/netdm_space_actor_default_denied/Run()
	var/datum/netdm_space_actor/source = new
	TEST_ASSERT(!source.can_submit() && !source.network_node() && !source.shell_provider(), "Unbound actors cannot issue commands.")
	TEST_ASSERT(!source.send("enter", list("note" = "test"), null), "An unbound actor cannot send packets to Host.")
	TEST_ASSERT_EQUAL(source.ui_status(null, GLOB.never_state), UI_CLOSE, "Unbound actors cannot expose an interactive UI.")
	TEST_ASSERT(!source.can_operate_alarm(null), "Unbound actors have no world-action permission.")
	var/datum/netdm_space/space = new(source)
	TEST_ASSERT(space.actor == source && source.window == space && !space.owns_actor, "Externally owned actors may attach one network view.")
	TEST_ASSERT(!space.enter() && !space.scan(1), "UI requests cannot acquire missing source authority.")
	TEST_ASSERT(!space.ui_data(null)["terminal"] && !space.dispatch_ui_action("terminal", list("command" = "clear"), null, GLOB.always_state), "Actors without a physical terminal cannot render or route its actions.")
	qdel(space)
	TEST_ASSERT(!QDELETED(source) && !source.window, "Closing a window releases, but does not destroy, an independently owned actor.")
	var/datum/netdm_space/second_window = new(source)
	TEST_ASSERT(source.window == second_window, "An independent actor may open another view after its old view closed.")
	qdel(source)
	TEST_ASSERT(QDELETED(second_window), "Retiring a network actor closes its existing UI rather than leaving an orphaned window.")

/// DreamDaemon lacks a browser. Use the live local-terminal owner guard with an in-memory UI state.
/datum/netdm_terminal/local/workspace_test/ui_state(mob/user)
	return GLOB.always_state

/// Logical console operators share the mapped device, while each Host shell and inbox is private.
/datum/unit_test/netdm_observe/area_map/network_console_operators/Run()
	if(world.GetConfig("env", "NETDM_IPC_MODE") != "v1")
		return
	http_base = world.GetConfig("env", "NETDM_TEST_HTTP")
	TEST_ASSERT(wait_until_live(), "Observe must publish the initial map.")
	var/turf/location = run_loc_floor_bottom_left
	assign_area(location, test_zone(/area/netdm_test/first))
	var/obj/machinery/power/apc/apc = allocate(/obj/machinery/power/apc, location)
	TEST_ASSERT(wait_for_fact(WEAKREF(apc), location), "The console's APC must be published.")
	var/datum/netdm_diagnostics/diagnostics = SSnetdm_observe.diagnostics
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	var/obj/machinery/computer/rdconsole/console = allocate(/obj/machinery/computer/rdconsole, location)
	var/datum/component/netdm_node/console_node = netdm_make_node(console)
	TEST_ASSERT(wait_for_node(console_node, location, TRUE), "The R&D console must be published.")
	var/mob/living/carbon/human/first_viewer = allocate(/mob/living/carbon/human, location)
	var/mob/living/carbon/human/second_viewer = allocate(/mob/living/carbon/human, location)
	var/datum/netdm_terminal_operator/console/first = diagnostics.terminal_operator(/datum/netdm_terminal_operator/console, console, first_viewer)
	var/datum/netdm_terminal_operator/console/second = diagnostics.terminal_operator(/datum/netdm_terminal_operator/console, console, second_viewer)
	allocated += list(first, second)
	TEST_ASSERT(first && second, "Both console operators must have Host endpoints.")
	TEST_ASSERT_EQUAL(lane.node_id(first), lane.node_id(console_node), "The first operator must use the physical R&D console node.")
	TEST_ASSERT_EQUAL(lane.node_id(second), lane.node_id(console_node), "The second operator must use the physical R&D console node.")
	TEST_ASSERT(first.shell_provider() == first && second.shell_provider() == second, "Each operator owns a private shell on the console.")
	TEST_ASSERT(lane.by_node[first]?.id && lane.by_node[second]?.id && lane.by_node[first].id != lane.by_node[second].id, "The operators must have distinct session and inbox identities.")
	qdel(first)
	qdel(second)

/datum/unit_test/netdm_unified_terminal/Run()
	var/mob/living/carbon/human/operator = allocate(/mob/living/carbon/human)
	var/mob/living/carbon/human/other_player = allocate(/mob/living/carbon/human)
	var/obj/item/device = allocate(/obj/item)
	var/datum/netdm_terminal/local/terminal = allocate(/datum/netdm_terminal/local/workspace_test, device, device, operator)
	var/datum/netdm_space/space = allocate(/datum/netdm_space, terminal)
	var/datum/netdm_space/previous = allocate(/datum/netdm_space)
	previous.reserve_opening(operator)
	TEST_ASSERT(previous.finish_opening(operator, TRUE), "The first workspace becomes active after its window opens.")
	space.reserve_opening(operator)
	var/datum/netdm_space/reserved = operator.netdm_pending_workspace?.resolve()
	TEST_ASSERT(operator.netdm_workspace?.resolve() == previous && reserved == space, "A pending source preserves the previously open workspace.")
	TEST_ASSERT(reserved.actor.matching_terminal(terminal.type, device, device, operator) == terminal, "Another click can find the pending terminal for the same source.")
	var/datum/netdm_space/replacement = allocate(/datum/netdm_space)
	replacement.reserve_opening(operator)
	TEST_ASSERT(!space.finish_opening(operator, TRUE) && operator.netdm_pending_workspace?.resolve() == replacement, "A superseded open cannot steal a later reservation.")
	TEST_ASSERT(!replacement.finish_opening(operator, FALSE) && !operator.netdm_pending_workspace && operator.netdm_workspace?.resolve() == previous, "An unsuccessful open leaves the active window available.")
	replacement.reserve_opening(operator)
	qdel(replacement)
	TEST_ASSERT(!operator.netdm_pending_workspace && operator.netdm_workspace?.resolve() == previous, "Destroying the pending window releases only its own reservation.")
	space.reserve_opening(operator)
	TEST_ASSERT(space.finish_opening(operator, TRUE) && QDELETED(previous) && operator.netdm_workspace?.resolve() == space, "A successful open installs the new workspace and closes the previous one.")
	var/list/sentinel = list("line" = "self")
	terminal.entries += list(sentinel)
	var/entries_before = length(terminal.entries)
	var/list/view = space.ui_data(operator)
	var/list/terminal_data = view["terminal"]
	TEST_ASSERT(terminal.space == space && terminal_data && terminal_data["entries"] == terminal.entries, "A physical workspace exposes its own terminal model.")
	TEST_ASSERT(!space.ui_data(other_player)["terminal"], "A different viewer cannot read the terminal model.")
	var/list/clear_action = list("command" = "clear", "params" = list())
	TEST_ASSERT(!space.dispatch_ui_action("terminal", clear_action, other_player, GLOB.always_state), "A different viewer cannot drive the terminal.")
	TEST_ASSERT(!space.dispatch_ui_action("terminal", list("command" = "enter"), operator, GLOB.always_state), "A terminal action cannot select a presence proc.")
	TEST_ASSERT(!space.dispatch_ui_action("terminal", list("command" = "open_space"), operator, GLOB.always_state), "The old window action is not part of the allowlist.")
	TEST_ASSERT(!space.dispatch_ui_action("terminal", list("command" = "clear", "params" = "bad"), operator, GLOB.always_state), "A malformed nested payload is refused.")
	TEST_ASSERT_EQUAL(length(terminal.entries), entries_before, "Rejected requests do not mutate terminal history.")
	TEST_ASSERT(space.dispatch_ui_action("terminal", clear_action, operator, GLOB.always_state), "The owner may clear the terminal from the unified view.")
	TEST_ASSERT(!length(terminal.entries), "The command reached the same mounted terminal.")
	qdel(space)
	TEST_ASSERT(!terminal.space && !QDELETED(terminal), "Closing the workspace releases its model while queued replies finish.")
	TEST_ASSERT(!operator.netdm_workspace, "Destroying the active workspace clears the player reference.")
	var/datum/callback/queued = terminal.send_guard()
	TEST_ASSERT(queued.Invoke(), "Terminal requests remain valid during normal retirement.")
	terminal.revoke_client(operator)
	TEST_ASSERT(!queued.Invoke(), "Logout revokes a queued terminal request even during retirement.")

/// DreamDaemon has no interactive client. Bypass only the client ownership check for this fixture.
/datum/netdm_space_actor/entity/test/can_submit()
	return !QDELETED(src) && !QDELETED(entry) && SSnetdm_observe?.published

/datum/unit_test/netdm_observe/area_map/network_entity/Run()
	if(world.GetConfig("env", "NETDM_IPC_MODE") != "v1")
		return
	http_base = world.GetConfig("env", "NETDM_TEST_HTTP")
	TEST_ASSERT(wait_until_live(), "Observe must publish the initial map.")
	var/turf/left = run_loc_floor_bottom_left
	var/turf/right = get_step(left, EAST)
	assign_area(left, test_zone(/area/netdm_test/first))
	assign_area(right, test_zone(/area/netdm_test/second))
	var/obj/machinery/power/apc/entry_apc = allocate(/obj/machinery/power/apc, left)
	var/obj/machinery/power/apc/target_apc = allocate(/obj/machinery/power/apc, right)
	var/list/entry_fact = wait_for_fact(WEAKREF(entry_apc), left)
	var/list/target_fact = wait_for_fact(WEAKREF(target_apc), right)
	TEST_ASSERT(entry_fact && target_fact, "Both APCs are published.")
	var/entry_node = entry_fact["a"]
	var/target_node = target_fact["a"]
	TEST_ASSERT(wait_for_links(left.z, entry_node, 1, TRUE), "The entity has a real wired route.")
	var/datum/netdm_diagnostics/diagnostics = SSnetdm_observe.diagnostics
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	var/dest = diagnostics.offer_shell(target_apc)
	TEST_ASSERT(dest, "The destination publishes its normal shell.")
	var/mob/dead/netdm_entity/controller = new(null)
	allocated += controller
	var/datum/netdm_space_actor/entity/denied = allocate(/datum/netdm_space_actor/entity, controller, entry_apc, null)
	TEST_ASSERT(!denied.can_submit() && denied.ui_status(controller, GLOB.always_state) == UI_CLOSE, "An unowned entity cannot submit or expose a UI.")
	TEST_ASSERT(!controller.forceMove(left) && !controller.loc && !denied.physical_body() && !denied.can_operate_alarm(null), "The role has no physical position or authority.")
	qdel(denied)
	var/datum/netdm_space_actor/entity/test/source = allocate(/datum/netdm_space_actor/entity/test, controller, entry_apc, null)
	var/datum/netdm_apc_operator/entity/entry = source.entry
	var/datum/netdm_service_endpoint/owned_endpoint = lane.by_node[entry]
	TEST_ASSERT(owned_endpoint && owned_endpoint != lane.by_node[entry_apc] && lane.node_id(entry) == entry_node, \
		"The entity has a separate Host endpoint on the published wire node.")

	var/datum/netdm_space/space = new(source)
	var/list/view = space.ui_data(null)
	TEST_ASSERT(view["entityRole"], "The controller exposes the entity role to its network view.")
	TEST_ASSERT(!space.dispatch_ui_action("Destroy", list(), controller, GLOB.always_state), "Only allowlisted UI actions may dispatch.")
	TEST_ASSERT(!space.dispatch_ui_action("leave_role", list(), controller, GLOB.always_state), "A controller without an owning client cannot leave through the UI.")
	TEST_ASSERT(space.dispatch_ui_action("enter", list(), controller, GLOB.always_state), "The entity enters through its own network view.")
	var/deadline = world.time + 25 SECONDS
	while(world.time < deadline && space.presence?["state"] != "active")
		sleep(2)
	TEST_ASSERT_EQUAL(space.presence?["node"], entry_node, "Presence starts at the entry APC.")
	deadline = world.time + 20 SECONDS
	while(world.time < deadline && !lane.ready(target_apc, dest))
		sleep(2)
	TEST_ASSERT(lane.ready(target_apc, dest) && space.dispatch_ui_action("scan", list("radius" = 2), controller, GLOB.always_state), "The entity scans for the destination.")
	deadline = world.time + 25 SECONDS
	while(world.time < deadline && !space.items["s|[dest]"])
		sleep(2)
	TEST_ASSERT(space.items["s|[dest]"] && space.dispatch_ui_action("preview_move", list("to" = dest), controller, GLOB.always_state), "The entity discovers the shell and checks a route.")
	deadline = world.time + 20 SECONDS
	while(world.time < deadline && space.route_preview?["status"] == "pending")
		sleep(2)
	TEST_ASSERT(space.route_preview?["status"] == "ready" && space.dispatch_ui_action("move", list("to" = dest), controller, GLOB.always_state), "Host verifies the path before the move.")
	deadline = world.time + 25 SECONDS
	while(world.time < deadline && (space.presence?["state"] != "active" || space.host_node() != target_node))
		sleep(2)
	TEST_ASSERT_EQUAL(space.host_node(), target_node, "The entity migrated to the target in the simulated network.")

	TEST_ASSERT(space.dispatch_ui_action("hack_start", list("node" = target_node), controller, GLOB.always_state), "The entity starts a challenge at its current APC.")
	deadline = world.time + 15 SECONDS
	while(world.time < deadline && !space.hack_code)
		sleep(1)
	TEST_ASSERT(space.hack_code && space.dispatch_ui_action("hack_answer", list("code" = space.hack_code), controller, GLOB.always_state), "The routed challenge can be answered.")
	deadline = world.time + 20 SECONDS
	while(world.time < deadline && space.hack_status == "checking")
		sleep(2)
	TEST_ASSERT(space.hack_status == "ok" && length(space.hack_keys) && space.dispatch_ui_action("hack_use", list("node" = target_node), controller, GLOB.always_state), "Host grants a key for the target APC.")
	deadline = world.time + 20 SECONDS
	while(world.time < deadline && target_apc.operating)
		sleep(2)
	TEST_ASSERT(!target_apc.operating && entry_apc.operating, "The Host-approved action flips only the target's physical breaker.")
	qdel(source)
	TEST_ASSERT(QDELETED(space) && !lane.by_node[entry], "Retirement closes the view and invalidates the entity endpoint.")

/**
 * The NETRUN device adapter without a network: names, classes and refusal to invent anything from missing
 * input. The live path (declare → grant → execute) is covered by the Host integration checks.
 */
/datum/unit_test/netdm_observe/netrun_adapter

/datum/unit_test/netdm_observe/netrun_adapter/Run()
	TEST_ASSERT_EQUAL(netrun_host_name("door.a"), "svc.door.a", "a service instance becomes a host name")
	TEST_ASSERT_EQUAL(length(netrun_host_name("x")), length("svc.x"), "a short instance keeps its name")
	TEST_ASSERT(length(netrun_host_name("")) <= 68, "an empty instance still produces a bounded name")
	TEST_ASSERT_EQUAL(netrun_host_class("research.server"), "Server", "a research server is a server")
	TEST_ASSERT_EQUAL(netrun_host_class("machine.door"), "Terminal", "a door is a terminal")
	TEST_ASSERT_EQUAL(netrun_host_class("atmos.telemetry"), "Terminal", "a sensor is a terminal")
	TEST_ASSERT_EQUAL(netrun_host_class("network.shell"), "Terminal", "unknown services still get a shape")

	// A declaration without a lane or an instance must be refused, not crash the lane.
	var/datum/netrun_adapter/adapter = new
	adapter.service_registered(null, null, "door.a")
	adapter.service_registered(null, null, null)
	adapter.service_registered(null, null, 42)
	TEST_ASSERT_EQUAL(length(adapter.hosts), 0, "no host is declared without a lane")
	TEST_ASSERT_EQUAL(adapter.pending, 0, "a refused declaration leaves nothing pending")
	TEST_ASSERT(isnull(adapter.host_of("door.a")), "an undeclared instance has no host")
	qdel(adapter)
/**
 * The NETRUN client in a real world: the window asks the Host for one filtered projection, the operator is
 * given the rights of its own device, and an action started from the window is reported back. This is the
 * whole player-facing path of the digital layer, not a compile check.
 */
/datum/unit_test/netdm_observe/netrun_client

/datum/unit_test/netdm_observe/netrun_client/Run()
	if(world.GetConfig("env", "NETDM_IPC_MODE") != "v1")
		return
	TEST_ASSERT(wait_until_live(), "Observe must publish the initial map ([SSnetdm_observe.observe_state()]).")
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	TEST_ASSERT(lane, "The service lane must exist.")
	var/datum/netrun_adapter/adapter = SSnetdm_observe.netrun
	TEST_ASSERT(adapter, "The NETRUN adapter must exist.")

	// A device that publishes a service becomes a digital host. Wait for the first one the Host confirmed.
	var/deadline = world.time + 60 SECONDS
	var/datum/device_node = null
	var/instance = null
	while(world.time < deadline && !instance)
		for(var/datum/node as anything in adapter.devices)
			var/candidate = adapter.devices[node]
			if(!adapter.host_of(candidate))
				continue
			device_node = node
			instance = candidate
			break
		if(!instance)
			sleep(5)
	TEST_ASSERT(instance, "At least one device must be declared as a digital host.")
	TEST_ASSERT(adapter.host_of(instance), "The declaration must be confirmed by the Host.")

	var/mob/operator = allocate(/mob)
	var/datum/netrun_client/window = new(operator)
	window.bind_device(lane, device_node, instance)
	TEST_ASSERT_EQUAL(window.principal, netrun_principal_of(operator), "The window derives its principal from the operator.")
	TEST_ASSERT(window.endpoint_id, "The window knows which endpoint speaks for it.")

	// The operator gets the rights of its own equipment. Knowledge is separate: it starts with an action.
	TEST_ASSERT(adapter.grant_operator(lane, window.principal, instance), "The operator is granted the rights of its device.")
	var/id = adapter.host_of(instance)["id"]
	window.notice = null
	TEST_ASSERT(window.execute(list("action" = "net.inspect", "target" = id)), "The window sends the first action.")
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && window.notice == null)
		sleep(5)
	TEST_ASSERT(window.notice, "The Host reports the outcome of the first action.")

	window.next_poll = 0
	TEST_ASSERT(window.request_panel(), "The window asks the Host for a projection.")
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && !islist(window.panel))
		sleep(5)
	TEST_ASSERT(islist(window.panel), "The Host answers with a projection: [window.error]")
	var/list/hosts = window.panel["hosts"]
	var/list/actions = window.panel["actions"]
	TEST_ASSERT(islist(hosts) && length(hosts) > 0, "The projection carries the host the operator may see.")
	TEST_ASSERT(islist(actions) && length(actions) > 0, "The projection carries the action catalogue.")
	var/list/own = null
	for(var/list/host as anything in hosts)
		if("[host["host"]]" == "[id]")
			own = host
			break
	TEST_ASSERT(own, "The operator's own device is in its view.")
	TEST_ASSERT(own["identified"], "A device the operator owns is identified, so it is shown by name.")

	// A second action from the same window: discovery, which needs no prior knowledge of the neighbourhood.
	window.notice = null
	TEST_ASSERT(window.execute(list("action" = "net.scan", "target" = id)), "The window sends the action.")
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && window.notice == null)
		sleep(5)
	TEST_ASSERT(window.notice, "The Host reports the outcome of the action.")
	TEST_ASSERT(findtext(window.notice, "Итог") || findtext(window.notice, "отправлено") || findtext(window.notice, "запущена"),
		"The notice is an outcome, not a silent success: [window.notice]")

	// Leave nothing behind: the next tests share this world.
	qdel(window)
	qdel(operator)
