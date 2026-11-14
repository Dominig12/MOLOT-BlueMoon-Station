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
	if(world.GetConfig("env", "NETDM_OBSERVE") != "1")
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
	if(world.GetConfig("env", "NETDM_OBSERVE") != "1")
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
	if(world.GetConfig("env", "NETDM_OBSERVE") != "1")
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
	if(world.GetConfig("env", "NETDM_OBSERVE") != "1")
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
	if(world.GetConfig("env", "NETDM_OBSERVE") != "1")
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
	if(world.GetConfig("env", "NETDM_OBSERVE") != "1")
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

/// P4 gate: the atmos.telemetry pilot in Shadow mode against the radio path in a real DreamDaemon.
/// A console on the network receives every report and a snapshot within the latency budget; a broken
/// console still takes the radio report, and the comparison names why netDM did not deliver to it.
/datum/unit_test/netdm_observe/area_map/atmos_telemetry

/datum/unit_test/netdm_observe/area_map/atmos_telemetry/Run()
	if(world.GetConfig("env", "NETDM_OBSERVE") != "1")
		return
	TEST_ASSERT(wait_until_live(), "Observe must publish the initial map ([SSnetdm_observe.observe_state()]).")
	var/datum/netdm_telemetry_shadow/telemetry = SSnetdm_observe.telemetry
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	TEST_ASSERT(telemetry && lane, "Observe must run the telemetry pilot.")
	var/turf/left = run_loc_floor_bottom_left
	var/turf/middle = get_step(left, EAST)
	var/turf/right = get_step(middle, EAST)
	TEST_ASSERT(middle && right, "Expected three adjacent test cells.")
	var/area/served = test_zone(/area/netdm_test/first)
	assign_area(left, served)
	assign_area(middle, served)
	assign_area(right, served)
	var/obj/machinery/power/apc/apc = allocate(/obj/machinery/power/apc, left)
	TEST_ASSERT(wait_for_fact(WEAKREF(apc), left), "Expected the zone APC to be published.")

	var/obj/machinery/air_sensor/netdm_test/sensor = allocate(/obj/machinery/air_sensor/netdm_test, middle)
	var/obj/machinery/computer/atmos_control/netdm_test/online = allocate(/obj/machinery/computer/atmos_control/netdm_test, right)
	var/obj/machinery/computer/atmos_control/netdm_test/broken = allocate(/obj/machinery/computer/atmos_control/netdm_test, left)
	var/instance = netdm_atmos_instance(sensor.frequency, sensor.id_tag)
	var/datum/component/netdm_node/sensor_node = sensor.GetComponent(/datum/component/netdm_node)
	var/datum/component/netdm_node/online_node = online.GetComponent(/datum/component/netdm_node)
	var/datum/component/netdm_node/broken_node = broken.GetComponent(/datum/component/netdm_node)
	TEST_ASSERT(sensor_node && online_node && broken_node, "Pilot devices must become nodes.")
	// A broken console keeps its radio receiver and loses the network.
	broken.set_machine_stat(broken.machine_stat | BROKEN)

	var/datum/netdm_service_endpoint/online_endpoint = lane.by_node[online_node]
	var/datum/netdm_service_endpoint/broken_endpoint = lane.by_node[broken_node]
	var/deadline = world.time + 60 SECONDS
	while(world.time < deadline && !(lane.ready(sensor_node, instance) && online_endpoint.subscribed[instance] && broken_endpoint.subscribed[instance]))
		sleep(2)
	TEST_ASSERT(lane.ready(sensor_node, instance), "The sensor must register its instance ([lane.state()]).")
	TEST_ASSERT(online_endpoint.subscribed[instance] && broken_endpoint.subscribed[instance], "Both consoles must subscribe ([lane.state()]).")

	var/list/before = telemetry.counters.Copy()
	var/list/reasons_before = telemetry.reasons.Copy()
	// A queued value replaced by a newer report never leaves DM: latest-value telemetry, not a loss.
	var/coalesced_before = lane.counters["superseded"]
	var/latency_start = length(telemetry.latencies)
	// Real sensors report every two seconds at most; one report a second keeps samples apart.
	// Thirty samples keep p95 below the maximum, so one stall of the test host is not the verdict.
	var/reports = 30
	for(var/i in 1 to reports)
		sensor.next_forced_report = 0
		sensor.try_report()
		sleep(1 SECONDS)
	// A radio-only console is explained by a network state; a newer value may replace a late one.
	var/list/network_reasons = list("invalid_route", "no_route", "expired", "deadline", "transport_ttl", "newer_value", "receiver_gone")
	var/compared = 0
	var/radio_only = 0
	var/explained = 0
	var/unexplained = 0
	deadline = world.time + 60 SECONDS
	while(world.time < deadline)
		compared = telemetry.counters["compared"] - before["compared"]
		radio_only = telemetry.counters["legacy_only"] - before["legacy_only"]
		explained = 0
		unexplained = 0
		for(var/reason in telemetry.reasons)
			var/delta = telemetry.reasons[reason] - reasons_before[reason]
			if(reason in network_reasons)
				explained += delta
			else
				unexplained += delta
		if(compared + lane.counters["superseded"] - coalesced_before >= reports && explained + unexplained >= radio_only 			&& telemetry.counters["snapshots"] > before["snapshots"])
			break
		sleep(5)
	var/matched = telemetry.counters["matched"] - before["matched"]
	var/netdm_only = telemetry.counters["netdm_only"] - before["netdm_only"]
	var/superseded = telemetry.reasons["newer_value"] - reasons_before["newer_value"]
	var/list/new_latencies = telemetry.latencies.Copy(max(1, latency_start + 1))
	var/p95 = telemetry.percentile_ms(new_latencies, 0.95)
	var/list/latency_ms = list()
	for(var/sample in sortTim(new_latencies.Copy(), GLOBAL_PROC_REF(cmp_numeric_asc)))
		latency_ms += round(sample / 1000)
	var/datum/http_response/status_response = world_safe_http_get("[world.GetConfig("env", "NETDM_TEST_HTTP")]/api/game/status", 5 SECONDS)
	var/list/host_status = status_response?.status_code == 200 ? json_decode(status_response.body) : null
	var/list/packet = host_status?["packet"]
	var/list/runner = host_status?["runner"]
	var/host_detail = "host packets: expired=[packet?["expired"]] reroutes=[packet?["reroutes"]] reroute_deferrals=[packet?["rerouteQueueDeferrals"]] no_route_deferrals=[packet?["noRouteDeferrals"]] age_p95_ticks=[packet?["deliveryAgeP95Ticks"]] runner=[json_encode(runner)]"
	var/detail = "[SSnetdm_observe.observe_state()] [host_detail] latencies_ms=[json_encode(latency_ms)] mismatches=[json_encode(telemetry.mismatches)]"
	var/coalesced = lane.counters["superseded"] - coalesced_before
	TEST_ASSERT(compared + coalesced >= reports, "Every report must be compared or replaced by a newer one ([compared] + [coalesced] of [reports]): [detail]")
	TEST_ASSERT_EQUAL(matched + superseded, compared, "The console on the network must receive every report it was not given a newer one for: [detail]")
	TEST_ASSERT_EQUAL(radio_only, compared + superseded, "The radio must still reach the broken console: [detail]")
	TEST_ASSERT_EQUAL(netdm_only, 0, "netDM must not deliver where the radio does not: [detail]")
	TEST_ASSERT_EQUAL(unexplained, 0, "Every radio-only console needs a network reason: [detail]")
	TEST_ASSERT(telemetry.counters["snapshots"] > before["snapshots"], "A subscribing console must receive a snapshot: [detail]")
	TEST_ASSERT(!isnull(p95) && p95 <= 500, "End-to-end p95 must stay within 500 ms, got [p95] ms: [detail]")
	TEST_ASSERT(online.sensor_information[sensor.id_tag], "The console screen keeps the radio report in Shadow mode.")
	log_world("netDM telemetry gate: [detail] p95_window=[p95]ms")

	// The sensor is rebuilt. The Host drops the subscriptions with the old provider and never moves them
	// to a new one, so the console must subscribe again by itself instead of waiting for nothing.
	var/resubscribed_before = lane.counters["resubscribed"]
	qdel(sensor)
	var/obj/machinery/air_sensor/netdm_test/rebuilt = allocate(/obj/machinery/air_sensor/netdm_test, middle)
	var/datum/component/netdm_node/rebuilt_node = rebuilt.GetComponent(/datum/component/netdm_node)
	TEST_ASSERT(rebuilt_node, "The rebuilt sensor must become a node.")
	deadline = world.time + 60 SECONDS
	while(world.time < deadline && !(lane.ready(rebuilt_node, instance) && online_endpoint.subscribed[instance]))
		sleep(2)
	TEST_ASSERT(lane.ready(rebuilt_node, instance), "The rebuilt sensor must register the instance again ([lane.state()]).")
	TEST_ASSERT(online_endpoint.subscribed[instance], "The console must subscribe to the rebuilt sensor ([lane.state()]).")
	TEST_ASSERT(lane.counters["resubscribed"] > resubscribed_before, "The dropped subscription must be asked again ([lane.state()]).")
	var/matched_before = telemetry.counters["matched"]
	var/compared_before = telemetry.counters["compared"]
	for(var/i in 1 to 3)
		rebuilt.next_forced_report = 0
		rebuilt.try_report()
		sleep(1 SECONDS)
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && telemetry.counters["compared"] - compared_before < 3)
		sleep(5)
	TEST_ASSERT(telemetry.counters["matched"] - matched_before >= 2, "The console must receive the rebuilt sensor: \
		[lane.state()] [json_encode(telemetry.mismatches)]")

/// P5 Shadow on the runtime station: Observe placed an R&D server next to the R&D console. A purchase
/// on the legacy console is decided again by the Host ledger, over the network, and the server's
/// treasury storage keeps the web's balance and knowledge.
/datum/unit_test/netdm_observe/research_shadow

/datum/unit_test/netdm_observe/research_shadow/Run()
	if(world.GetConfig("env", "NETDM_OBSERVE") != "1")
		return
	TEST_ASSERT(wait_until_live(), "Observe must publish the map ([SSnetdm_observe.observe_state()]).")
	var/datum/netdm_research_shadow/shadow = SSnetdm_observe.research
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	TEST_ASSERT(shadow && lane, "Observe must run the research pilot.")
	var/obj/machinery/rnd/server/server = locate(/obj/machinery/rnd/server) in SSresearch.servers
	TEST_ASSERT(server, "The runtime station must get an R&D server under Observe.")
	var/datum/techweb/web = server.stored_research
	TEST_ASSERT(web == SSresearch.science_tech, "The placed server must join the station web.")
	var/obj/machinery/computer/rdconsole/console
	for(var/obj/machinery/computer/rdconsole/candidate in GLOB.machines)
		if(candidate.stored_research == web)
			console = candidate
			break
	TEST_ASSERT(console, "The runtime station needs an R&D console on the station web.")
	var/datum/component/netdm_node/server_node = server.GetComponent(/datum/component/netdm_node)
	var/datum/component/netdm_node/console_node = console.GetComponent(/datum/component/netdm_node)
	TEST_ASSERT(server_node && console_node, "The server and the console must become nodes.")

	var/deadline = world.time + 2 MINUTES
	var/storage
	while(world.time < deadline)
		storage = shadow.treasury_of(web)
		var/datum/netdm_service_endpoint/console_endpoint = lane.by_node[console_node]
		if(storage && shadow.synchronized() && lane.ready(server_node, "research.[storage]") && console_endpoint?.attached_node)
			break
		sleep(5)
	TEST_ASSERT(storage, "The station web needs a treasury storage: [shadow.state()]")
	TEST_ASSERT(shadow.synchronized(), "The mirror must catch up: [shadow.state()] [json_encode(shadow.notes)]")
	TEST_ASSERT(lane.ready(server_node, "research.[storage]"), "The server must offer research.server: [lane.state()]")

	// Legacy points written straight to the balance reach the treasury through the mirror.
	web.add_point_list(list(TECHWEB_POINT_TYPE_GENERIC = 50000), FALSE)
	var/node_id
	for(var/id in web.available_nodes)
		if(web.researched_nodes[id] || web.boosted_nodes[id])
			continue
		var/datum/techweb_node/candidate_node = SSresearch.techweb_node_by_id(id)
		var/cost = candidate_node.research_costs[TECHWEB_POINT_TYPE_GENERIC] || 0
		if(cost > 0 && cost <= 50000)
			node_id = id
			break
	TEST_ASSERT(node_id, "The station web needs an affordable node without a boost.")
	var/matched_before = shadow.counters["matched"]
	var/mismatched_before = shadow.counters["mismatched"]
	TEST_ASSERT(console.research_node(node_id, null), "The legacy console must buy [node_id].")
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && shadow.counters["matched"] == matched_before && shadow.counters["mismatched"] == mismatched_before)
		sleep(2)
	TEST_ASSERT_EQUAL(shadow.counters["matched"] - matched_before, 1,
		"The Host ledger must decide [node_id] like the legacy web: [shadow.state()] [json_encode(shadow.notes)]")
	TEST_ASSERT(!console.research_node(node_id, null), "A researched node is not bought twice.")

	// Balance and knowledge of the treasury against the web, with passive income flowing meanwhile.
	sleep(3 SECONDS)
	var/compares = shadow.counters["compares"]
	shadow.next_compare = 0
	deadline = world.time + 60 SECONDS
	while(world.time < deadline && shadow.counters["compares"] == compares)
		sleep(5)
	TEST_ASSERT(shadow.counters["compares"] > compares, "The treasury must be compared with the web: [shadow.state()]")
	TEST_ASSERT_EQUAL(shadow.counters["drifts"], 0, "The treasury must hold the web's points: [shadow.state()] [json_encode(shadow.notes)]")
	TEST_ASSERT(shadow.last_drift < 0.1, "The treasury balance must match within float error: [shadow.state()]")
	TEST_ASSERT_EQUAL(shadow.counters["knowledge_drifts"], 0, "The treasury must know the web's nodes: [json_encode(shadow.notes)]")
	TEST_ASSERT_EQUAL(shadow.counters["rejected"] + shadow.counters["dropped"], 0, "Every mirror event must be accepted: [json_encode(shadow.notes)]")
	var/datum/http_response/response = world_safe_http_get("[world.GetConfig("env", "NETDM_TEST_HTTP")]/api/research/status", 5 SECONDS)
	var/list/host = response?.status_code == 200 ? json_decode(response.body) : null
	var/list/totals = host?["totals"]
	TEST_ASSERT(totals?["balanced"], "The Host ledger must stay balanced: [response?.body]")
	log_world("netDM research shadow: [shadow.state()] host=[response?.body]")

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
	if(world.GetConfig("env", "NETDM_OBSERVE") != "1")
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
		var/refused_before = shadow.mismatch_reasons["ledger_insufficient_points"] || 0
		TEST_ASSERT(console.research_node(unaffordable, null), "The console must send the third purchase.")
		TEST_ASSERT(wait_answer(shadow, binding), "The second server must answer.")
		TEST_ASSERT(!web.researched_nodes[unaffordable], "A node above the whole account cannot be bought.")
		TEST_ASSERT_EQUAL((shadow.mismatch_reasons["ledger_insufficient_points"] || 0) - refused_before, 1, "The refusal comes from the ledger.")

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
	if(world.GetConfig("env", "NETDM_OBSERVE") != "1")
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
	if(world.GetConfig("env", "NETDM_OBSERVE") != "1")
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

/// P7 Shadow: two PDAs in a powered test zone. A legacy message is mirrored as an addressed network
/// delivery, the receipt comes back to the sender, and the radio and network paths are compared.
/// A replayed delivery of the same message is recorded once.
/datum/unit_test/netdm_observe/area_map/messenger_shadow

/datum/unit_test/netdm_observe/area_map/messenger_shadow/proc/wait_compared(datum/netdm_messenger_shadow/shadow, compared)
	var/deadline = world.time + 30 SECONDS
	while(world.time < deadline && shadow.counters["compared"] <= compared)
		sleep(5)
	return shadow.counters["compared"] > compared

/datum/unit_test/netdm_observe/area_map/messenger_shadow/Run()
	if(world.GetConfig("env", "NETDM_OBSERVE") != "1")
		return
	TEST_ASSERT(wait_until_live(), "Observe must publish the map ([SSnetdm_observe.observe_state()]).")
	var/datum/netdm_messenger_shadow/shadow = SSnetdm_observe.messenger
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	TEST_ASSERT(shadow && lane, "Observe must run the messenger pilot.")
	var/turf/left = run_loc_floor_bottom_left
	var/turf/middle = get_step(left, EAST)
	var/turf/right = get_step(middle, EAST)
	var/area/served = test_zone(/area/netdm_test/first)
	assign_area(left, served)
	assign_area(middle, served)
	assign_area(right, served)
	var/obj/machinery/power/apc/apc = allocate(/obj/machinery/power/apc, left)
	TEST_ASSERT(wait_for_fact(WEAKREF(apc), left), "Expected the zone APC to be published.")

	var/obj/item/modular_computer/pda/alice_pda = allocate(/obj/item/modular_computer/pda, middle)
	var/obj/item/modular_computer/pda/bob_pda = allocate(/obj/item/modular_computer/pda, right)
	var/datum/computer_file/program/messenger/alice = locate(/datum/computer_file/program/messenger) in alice_pda.get_all_files()
	var/datum/computer_file/program/messenger/bob = locate(/datum/computer_file/program/messenger) in bob_pda.get_all_files()
	TEST_ASSERT(alice && bob, "PDAs come with the messenger.")
	// The legacy contact list holds a messenger once its program runs; a drive install never adds it.
	add_messenger(alice)
	add_messenger(bob)
	var/alice_instance = shadow.instances[WEAKREF(alice)]
	var/bob_instance = shadow.instances[WEAKREF(bob)]
	TEST_ASSERT(alice_instance && bob_instance, "Each messenger offers pda.messenger: [shadow.state()]")
	var/datum/component/netdm_node/alice_node = alice_pda.GetComponent(/datum/component/netdm_node)
	var/datum/component/netdm_node/bob_node = bob_pda.GetComponent(/datum/component/netdm_node)
	var/deadline = world.time + 60 SECONDS
	while(world.time < deadline && !(lane.ready(bob_node, bob_instance) && lane.by_node[alice_node]?.attached_node))
		sleep(2)
	TEST_ASSERT(lane.ready(bob_node, bob_instance), "The recipient's messenger must register: [lane.state()]")

	// The radio path delivers through telecomms; the debug bypass stands in for a station's servers here.
	var/old_bypass = SSnetworks.ntnet_debug_global_signal
	SSnetworks.ntnet_debug_global_signal = TRUE
	var/compared = shadow.counters["compared"]
	TEST_ASSERT(alice.send_message(alice_pda, "netDM test: hello Bob", list(bob)), "The legacy messenger must send.")
	TEST_ASSERT(wait_compared(shadow, compared), "The message must be compared: [shadow.state()]")
	TEST_ASSERT_EQUAL(shadow.counters["matched"], 1, "Radio and network must both deliver: [shadow.state()] [json_encode(shadow.notes)]")
	TEST_ASSERT_EQUAL(shadow.counters["legacy_duplicates"] + shadow.counters["netdm_duplicates"], 0, "Nothing is delivered twice.")

	// A replayed network delivery of the same message is recorded once and answered as a duplicate.
	var/list/replay = list("payload" = list("id" = "replayed", "text" = "x", "sender" = "y"), "instance" = bob_instance)
	shadow.delivered(bob_pda, replay)
	var/list/again = shadow.delivered(bob_pda, replay)
	TEST_ASSERT(islist(again) && again["result"]["state"] == "duplicate" && shadow.counters["netdm_duplicates"] == 1,
		"A message ID is taken once per recipient.")

	// Without the bypass, the radio path needs a message server. Whatever this map has, the network
	// path still delivers: either both did, or the comparison names the missing server.
	SSnetworks.ntnet_debug_global_signal = FALSE
	sleep(1.2 SECONDS)
	compared = shadow.counters["compared"]
	alice.send_message(alice_pda, "netDM test: without the bypass", list(bob))
	SSnetworks.ntnet_debug_global_signal = old_bypass
	TEST_ASSERT(wait_compared(shadow, compared), "The second message must be compared: [shadow.state()]")
	TEST_ASSERT(shadow.counters["matched"] == 2 || shadow.reasons["legacy_server"] == 1,
		"The network delivers with or without the message server: [shadow.state()] [json_encode(shadow.notes)]")
	TEST_ASSERT_EQUAL(shadow.counters["legacy_only"], 0, "netDM must reach a PDA the radio reached: [shadow.state()] [json_encode(shadow.notes)]")
	log_world("netDM messenger shadow: [shadow.state()]")

/// P4 on a real station map: the map's own gas sensors and atmos consoles run the Shadow pilot.
/// P7 authoritative: PDAs message each other through a message server node, without telecomms. The
/// server logs a message once, the recipient shows it once and can reply, and the sender learns each
/// recipient's outcome. A server that is off refuses; a recipient that cannot take the message, or is
/// out of the network, is reported back to the sender.
/datum/unit_test/netdm_observe/area_map/messenger_authoritative

/datum/unit_test/netdm_observe/area_map/messenger_authoritative/Destroy()
	var/datum/netdm_messenger_shadow/shadow = SSnetdm_observe.messenger
	if(shadow)
		shadow.set_authoritative(FALSE)
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
	for(var/list/corner in list(list(3, 3), list(world.maxx - 2, 3), list(3, world.maxy - 2), list(world.maxx - 2, world.maxy - 2)))
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
	if(world.GetConfig("env", "NETDM_OBSERVE") != "1")
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

	shadow.set_authoritative(TRUE)
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
	SSnetworks.ntnet_debug_global_signal = old_bypass
	TEST_ASSERT_EQUAL(counters["duplicates"], 1, "Only the replayed delivery was a duplicate: [shadow.state()]")
	log_world("netDM messenger authoritative: [shadow.state()] reasons=[json_encode(shadow.reasons)]")

/// P8 Shadow: a receiver, a broadcaster and radios in a powered test zone. A transmission's listeners
/// are matched when the network reaches them and explained when it does not: a listener in a corner of
/// the station level without an access point is no_downlink, a speaker there is no_uplink.
/datum/unit_test/netdm_observe/area_map/radio_shadow

/datum/unit_test/netdm_observe/area_map/radio_shadow/proc/transmit(datum/netdm_radio_shadow/shadow, id, obj/item/radio/source,
	list/listeners, obj/machinery/telecomms/receiver)
	var/list/heard = list()
	for(var/obj/item/radio/radio as anything in listeners)
		heard[WEAKREF(radio)] = TRUE
	shadow.pending[id] = list("id" = id, "source" = WEAKREF(source), "frequency" = FREQ_COMMON, "created" = world.time - 1,
		"listeners" = heard, "receivers" = list(WEAKREF(receiver)), "asked" = FALSE)
	var/answered = shadow.counters["answered"]
	var/deadline = world.time + 20 SECONDS
	while(world.time < deadline && shadow.counters["answered"] <= answered)
		sleep(2)
	return shadow.counters["answered"] > answered

/datum/unit_test/netdm_observe/area_map/radio_shadow/Run()
	if(world.GetConfig("env", "NETDM_OBSERVE") != "1")
		return
	TEST_ASSERT(wait_until_live(), "Observe must publish the map ([SSnetdm_observe.observe_state()]).")
	var/datum/netdm_radio_shadow/shadow = SSnetdm_observe.radio
	TEST_ASSERT(shadow, "Observe must run the radio pilot.")
	var/list/turfs = list(run_loc_floor_bottom_left)
	for(var/i in 1 to 4)
		turfs += get_step(turfs[length(turfs)], EAST)
	var/area/served = test_zone(/area/netdm_test/first)
	for(var/turf/tile as anything in turfs)
		assign_area(tile, served)
	var/obj/machinery/power/apc/apc = allocate(/obj/machinery/power/apc, turfs[1])
	TEST_ASSERT(wait_for_fact(WEAKREF(apc), turfs[1]), "Expected the zone APC to be published.")
	var/obj/machinery/telecomms/receiver/receiver = allocate(/obj/machinery/telecomms/receiver, turfs[2])
	var/obj/machinery/telecomms/broadcaster/broadcaster = allocate(/obj/machinery/telecomms/broadcaster, turfs[3])
	var/obj/item/radio/speaker = allocate(/obj/item/radio, turfs[4])
	var/obj/item/radio/listener = allocate(/obj/item/radio, turfs[5])
	var/obj/item/radio/away = allocate(/obj/item/radio, turfs[5])
	TEST_ASSERT(shadow.receivers[WEAKREF(receiver)] && shadow.broadcasters[WEAKREF(broadcaster)] && shadow.radios[WEAKREF(speaker)],
		"Radios and telecomms ends become nodes: [shadow.state()]")
	var/turf/corner = isolated_turf()
	TEST_ASSERT(corner, "The station level needs a corner without an APC nearby.")
	away.forceMove(corner)
	var/list/things = list(receiver, broadcaster, speaker, listener, away)
	var/deadline = world.time + 60 SECONDS
	var/ready = FALSE
	while(world.time < deadline && !ready)
		ready = TRUE
		for(var/atom/movable/thing as anything in things)
			ready = ready && shadow.node_id(thing)
		if(!ready)
			sleep(2)
	TEST_ASSERT(ready, "Every radio and telecomms end must be a published node: [shadow.state()]")
	sleep(2 SECONDS) // The corner radio's move reaches the Host.

	var/matched = shadow.counters["matched"]
	TEST_ASSERT(transmit(shadow, "t-near", speaker, list(listener, away), receiver), "The Host must answer: [shadow.state()]")
	TEST_ASSERT_EQUAL(shadow.counters["matched"] - matched, 1, "The zone listener is reached: [shadow.state()]")
	TEST_ASSERT_EQUAL(shadow.reasons["no_downlink"], 1, "The corner listener is explained: [shadow.state()]")
	TEST_ASSERT(shadow.percentile_ms(0.5) > 0, "A matched listener has a latency estimate: [shadow.state()]")

	TEST_ASSERT(transmit(shadow, "t-away", away, list(listener), receiver), "The Host must answer: [shadow.state()]")
	TEST_ASSERT_EQUAL(shadow.reasons["no_uplink"], 1, "A speaker out of reach never gets to the receiver: [shadow.state()]")
	log_world("netDM radio shadow: [shadow.state()]")

/// P8 authoritative uplink: a radio's speech reaches a telecomms mainframe over the network, not at
/// once by subspace. Nothing is broadcast before the uplink arrives; a repeat is a duplicate, an uplink
/// after the legacy backup is late, a speaker out of the network is lost, an unknown context expired.
/datum/unit_test/netdm_observe/area_map/radio_uplink

/datum/unit_test/netdm_observe/area_map/radio_uplink/Destroy()
	SSnetdm_observe.radio?.set_authoritative(FALSE)
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
	if(world.GetConfig("env", "NETDM_OBSERVE") != "1")
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
	shadow.set_authoritative(TRUE)
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

/// Authoritative uplink on the station: the speakers reach the map's receivers over the network and
/// the legacy broadcast follows. Writes netdm_radio_station.json.
/datum/unit_test/netdm_observe/area_map/radio_station/proc/authoritative_station(datum/netdm_radio_shadow/shadow, list/speakers, ready, unpublished)
	var/list/counters = shadow.uplink_counters
	// First words attach each radio's endpoint; they are measured apart from the steady window.
	var/first_start = length(shadow.uplink_latencies)
	for(var/obj/item/radio/radio as anything in speakers)
		var/obj/item/paper/warmup = allocate(/obj/item/paper, get_turf(radio))
		var/datum/signal/subspace/vocal/first = new(radio, FREQ_COMMON, new /atom/movable/virtualspeaker(null, warmup, radio),
			/datum/language/common, "netDM uplink first word [REF(radio)]", list()) // Broadcasters drop repeats within a second.
		first.send_to_receivers()
		sleep(3)
	var/settle = world.time + 30 SECONDS
	while(world.time < settle && length(shadow.contexts))
		sleep(5)
	var/list/first_words = list()
	for(var/sample in shadow.uplink_latencies.Copy(max(1, first_start + 1)))
		first_words += round(sample / 1000)
	sleep(2 SECONDS) // Out of the cooldown of each radio and the last result legs.
	var/list/before = counters.Copy()
	var/latency_start = length(shadow.uplink_latencies)
	var/list/signals = list()
	for(var/index in 1 to length(speakers))
		var/obj/item/radio/radio = speakers[index]
		var/obj/item/paper/someone = allocate(/obj/item/paper, get_turf(radio))
		var/atom/movable/virtualspeaker/voice = new(null, someone, radio)
		var/datum/signal/subspace/vocal/signal = new(radio, FREQ_COMMON, voice, /datum/language/common, "netDM uplink test [index]", list())
		signal.send_to_receivers()
		signals += signal
		sleep(3)
	var/deadline = world.time + 30 SECONDS
	while(world.time < deadline && length(shadow.contexts))
		sleep(5)
	var/list/delta = list()
	for(var/name in counters)
		if(counters[name] != before[name])
			delta[name] = counters[name] - before[name]
	var/broadcast = 0
	for(var/datum/signal/subspace/vocal/signal as anything in signals)
		if(signal.data["done"])
			broadcast++
	var/list/window = shadow.uplink_latencies.Copy(max(1, latency_start + 1))
	var/list/sorted = sortTim(window.Copy(), GLOBAL_PROC_REF(cmp_numeric_asc))
	var/p50 = length(sorted) ? round(sorted[clamp(CEILING(length(sorted) * 0.5, 1), 1, length(sorted))] / 1000, 0.1) : null
	var/p95 = length(sorted) ? round(sorted[clamp(CEILING(length(sorted) * 0.95, 1), 1, length(sorted))] / 1000, 0.1) : null
	var/list/latency_ms = list()
	for(var/sample in sorted)
		latency_ms += round(sample / 1000)
	var/datum/http_response/status_response = world_safe_http_get("[http_base]/api/game/status", 5 SECONDS)
	var/list/host_status = status_response?.status_code == 200 ? json_decode(status_response.body) : null
	var/list/report = list(
		"map" = SSmapping.config?.map_name,
		"mode" = "authoritative",
		"speakers" = length(speakers),
		"ready" = ready,
		"unpublished_radios" = unpublished,
		"receivers_offered" = length(shadow.rx_instances),
		"broadcast" = broadcast,
		"counters" = delta,
		"uplink_p50_ms" = p50,
		"uplink_p95_ms" = p95,
		"uplink_ms" = latency_ms,
		"first_word_ms" = sortTim(first_words, GLOBAL_PROC_REF(cmp_numeric_asc)),
		"apc_bridges" = host_status?["apcBridges"],
		"host_runner" = host_status?["runner"],
		"host_process" = host_status?["process"],
		"lane" = SSnetdm_observe.services.state(),
	)
	var/path = "[GLOB.log_directory]/netdm_radio_station.json"
	fdel(path)
	text2file(json_encode(report), path)
	log_world("netDM radio station: [report["map"]] authoritative speakers=[length(speakers)] broadcast=[broadcast] \
		counters=[json_encode(delta)] uplink p50=[p50]ms p95=[p95]ms [shadow.uplink_state()]")
	TEST_ASSERT_EQUAL(delta["transmissions"], length(speakers), "Every speaker's transmission goes to the network: [json_encode(report)]")
	TEST_ASSERT_EQUAL(broadcast, length(speakers), "Every transmission reaches a receiver and is broadcast: [json_encode(report)]")
	TEST_ASSERT_EQUAL(delta["lost"], null, "No speech is lost on the way to telecomms: [json_encode(report)]")

/// P8 Shadow on the station: radios by APCs across departments speak on the common channel through the
/// map's own telecomms. Every radio that legacy delivered to is compared with the network's reach.
/// Writes netdm_radio_station.json; fails only when the Host does not answer or a listener stays unexplained.
/datum/unit_test/netdm_observe/area_map/radio_station

/datum/unit_test/netdm_observe/area_map/radio_station/Run()
	if(world.GetConfig("env", "NETDM_OBSERVE") != "1")
		return
	var/datum/netdm_radio_shadow/shadow = SSnetdm_observe.radio
	TEST_ASSERT(shadow, "Observe must run the radio pilot.")
	http_base = world.GetConfig("env", "NETDM_TEST_HTTP")
	var/deadline = world.time + 10 MINUTES
	while(world.time < deadline && !(SSnetdm_observe.published && SSnetdm_observe.phase == "live" && !SSnetdm_observe.pending))
		sleep(10)
	TEST_ASSERT(SSnetdm_observe.published, "Observe must publish the station map ([SSnetdm_observe.observe_state()]).")
	var/list/apcs = list()
	for(var/obj/machinery/power/apc/apc as anything in GLOB.apcs_list)
		var/turf/position = get_turf(apc)
		if(position && is_station_level(position.z) && !(apc.machine_stat & BROKEN))
			apcs += apc
	TEST_ASSERT(length(apcs) >= 4, "The station needs APCs to place radios by.")
	var/step = max(1, round(length(apcs) / 12))
	var/list/speakers = list()
	for(var/index = 1; index <= length(apcs) && length(speakers) < 12; index += step)
		var/obj/item/radio/radio = allocate(/obj/item/radio, get_turf(apcs[index]))
		radio.set_frequency(FREQ_COMMON)
		speakers += radio
	// Map radios and the speakers become nodes; then the map settles before the window.
	deadline = world.time + 90 SECONDS
	var/ready = 0
	while(world.time < deadline)
		ready = 0
		for(var/obj/item/radio/radio as anything in speakers)
			if(shadow.node_id(radio))
				ready++
		if(ready == length(speakers))
			break
		sleep(10)
	// The map's own radios publish over the first minutes; the window starts once they have settled.
	var/unpublished = -1
	var/steady = 0
	deadline = world.time + 3 MINUTES
	while(world.time < deadline && steady < 3)
		var/count = 0
		for(var/datum/weakref/radio_ref as anything in shadow.radios)
			var/obj/item/radio/radio = radio_ref.resolve()
			if(radio && !shadow.node_id(radio))
				count++
		steady = count == unpublished ? steady + 1 : 0
		unpublished = count
		if(!count)
			break
		sleep(5 SECONDS)
	sleep(5 SECONDS) // Attachments of the last published radios reach the Host's routes.
	if(shadow.authoritative)
		authoritative_station(shadow, speakers, ready, unpublished)
		return
	var/list/before = shadow.counters.Copy()
	var/list/reasons_before = shadow.reasons.Copy()
	var/latency_start = length(shadow.latencies)
	for(var/index in 1 to length(speakers))
		var/obj/item/radio/radio = speakers[index]
		// The voice belongs to someone by the radio; the radio itself as the speaker would register its signals twice.
		var/obj/item/paper/someone = allocate(/obj/item/paper, get_turf(radio))
		var/atom/movable/virtualspeaker/voice = new(null, someone, radio)
		var/datum/signal/subspace/vocal/signal = new(radio, FREQ_COMMON, voice, /datum/language/common, "netDM radio test [index]", list())
		signal.send_to_receivers()
		sleep(3) // Within the pilot's sampling rate.
	deadline = world.time + 60 SECONDS
	while(world.time < deadline && length(shadow.pending))
		sleep(5)
	var/list/delta = list()
	for(var/name in shadow.counters)
		if(shadow.counters[name] != before[name])
			delta[name] = shadow.counters[name] - before[name]
	var/list/known = list("no_uplink", "no_chain", "no_downlink", "no_source", "source_unregistered")
	var/list/reason_deltas = list()
	var/unexplained = 0
	for(var/reason in shadow.reasons)
		var/change = shadow.reasons[reason] - reasons_before[reason]
		if(!change)
			continue
		reason_deltas[reason] = change
		if(!(reason in known))
			unexplained += change
	var/list/window = shadow.latencies.Copy(max(1, latency_start + 1))
	var/list/sorted = sortTim(window.Copy(), GLOBAL_PROC_REF(cmp_numeric_asc))
	var/p50 = length(sorted) ? sorted[clamp(CEILING(length(sorted) * 0.5, 1), 1, length(sorted))] : null
	var/p95 = length(sorted) ? sorted[clamp(CEILING(length(sorted) * 0.95, 1), 1, length(sorted))] : null
	var/list/latency_histogram = list()
	for(var/sample in sorted)
		latency_histogram["[sample]"]++
	var/datum/http_response/status_response = world_safe_http_get("[http_base]/api/game/status", 5 SECONDS)
	var/list/host_status = status_response?.status_code == 200 ? json_decode(status_response.body) : null
	var/list/report = list(
		"map" = SSmapping.config?.map_name,
		"speakers" = length(speakers),
		"ready" = ready,
		"radio_nodes" = length(shadow.radios),
		"unpublished_radios" = unpublished,
		"receivers" = length(shadow.receivers),
		"broadcasters" = length(shadow.broadcasters),
		"counters" = delta,
		"reasons" = reason_deltas,
		"p50_ms" = p50,
		"p95_ms" = p95,
		"latency_ms" = latency_histogram,
		"apc_bridges" = host_status?["apcBridges"],
		"host_runner" = host_status?["runner"],
		"host_process" = host_status?["process"],
		"lane" = SSnetdm_observe.services.state(),
	)
	var/path = "[GLOB.log_directory]/netdm_radio_station.json"
	fdel(path)
	text2file(json_encode(report), path)
	log_world("netDM radio station: [report["map"]] speakers=[length(speakers)] ready=[ready] counters=[json_encode(delta)] \
		reasons=[json_encode(reason_deltas)] p50=[p50]ms p95=[p95]ms [shadow.state()]")
	TEST_ASSERT(delta["sampled"] > 0, "Legacy telecomms must broadcast the speakers' transmissions: [json_encode(report)]")
	TEST_ASSERT_EQUAL(delta["answered"], delta["asked"], "The Host answers every question: [json_encode(report)]")
	TEST_ASSERT_EQUAL(unexplained, 0, "Every listener the network misses needs a reason: [json_encode(reason_deltas)]")

/// Writes netdm_atmos_station.json and fails only on contract breaches: a delivery the radio did not
/// make, a radio-only console without a reason, or p95 above the budget.
/datum/unit_test/netdm_observe/area_map/atmos_station

/datum/unit_test/netdm_observe/area_map/atmos_station/proc/endpoint_of(atom/movable/thing)
	var/datum/component/netdm_node/node = thing.GetComponent(/datum/component/netdm_node)
	return node ? SSnetdm_observe.services.by_node[node] : null

/// Every sensor registered or refused, every console subscribed to the sensors that exist or refused.
/datum/unit_test/netdm_observe/area_map/atmos_station/proc/pilot_settled(datum/netdm_telemetry_shadow/telemetry)
	for(var/datum/weakref/sensor_ref as anything in telemetry.sensors)
		var/obj/machinery/air_sensor/sensor = sensor_ref.resolve()
		var/datum/netdm_service_endpoint/endpoint = sensor ? endpoint_of(sensor) : null
		if(!endpoint)
			continue
		for(var/instance in endpoint.services)
			if(!endpoint.registered[instance] && !endpoint.refused[instance])
				return FALSE
	for(var/datum/weakref/console_ref as anything in telemetry.consoles)
		var/obj/machinery/computer/atmos_control/console = console_ref.resolve()
		var/datum/netdm_service_endpoint/endpoint = console ? endpoint_of(console) : null
		if(!endpoint)
			continue
		for(var/key in endpoint.subscriptions)
			if(telemetry.sensor_instances[key] && !endpoint.subscribed[key] && !endpoint.refused[key])
				return FALSE
	return TRUE

/datum/unit_test/netdm_observe/area_map/atmos_station/proc/place(atom/thing)
	var/turf/position = get_turf(thing)
	var/area/zone = get_area(thing)
	return "[zone?.type] [position?.x],[position?.y],[position?.z]"

/// How the Host attached the device: its links and whether it is on radio.
/datum/unit_test/netdm_observe/area_map/atmos_station/proc/attachment(atom/movable/thing)
	var/datum/component/netdm_node/node = thing.GetComponent(/datum/component/netdm_node)
	var/node_id = node ? SSnetdm_observe.node_ids[node] : null
	var/turf/position = get_turf(thing)
	var/list/host = node_id && position ? host_node(position.z, node_id) : null
	return host ? "links=[host["links"]] radio=[host["radioEnabled"] ? "yes" : "no"]" : "absent"

/datum/unit_test/netdm_observe/area_map/atmos_station/Run()
	if(world.GetConfig("env", "NETDM_OBSERVE") != "1")
		return
	var/datum/netdm_telemetry_shadow/telemetry = SSnetdm_observe.telemetry
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	if(!telemetry || !length(telemetry.sensors) || !length(telemetry.consoles))
		log_world("netDM atmos station: no pilot devices on [SSmapping.config?.map_name].")
		return
	http_base = world.GetConfig("env", "NETDM_TEST_HTTP")
	var/deadline = world.time + 10 MINUTES
	while(world.time < deadline && !(SSnetdm_observe.published && SSnetdm_observe.phase == "live" && !SSnetdm_observe.pending))
		sleep(10)
	TEST_ASSERT(SSnetdm_observe.published, "Observe must publish the station map ([SSnetdm_observe.observe_state()]).")
	deadline = world.time + 3 MINUTES
	while(world.time < deadline && !pilot_settled(telemetry))
		sleep(10)
	TEST_ASSERT(pilot_settled(telemetry), "Sensors must register and consoles subscribe ([lane.state()]).")

	var/window_start = world.time
	lane.max_poll_gap_us = 0
	lane.max_reply_us = 0
	lane.max_reply_op = null
	var/list/before = telemetry.counters.Copy()
	var/list/reasons_before = telemetry.reasons.Copy()
	var/list/consoles_before = list()
	for(var/id in telemetry.per_console)
		var/list/stats = telemetry.per_console[id]
		consoles_before[id] = stats.Copy()
	var/latency_start = length(telemetry.latencies)
	var/coalesced_before = lane.counters["superseded"]
	// The map's own sensors report every two seconds for a minute; their radio reports are the reference.
	for(var/pass in 1 to 30)
		for(var/datum/weakref/sensor_ref as anything in telemetry.sensors)
			var/obj/machinery/air_sensor/sensor = sensor_ref.resolve()
			if(sensor?.on)
				sensor.next_forced_report = 0
				sensor.try_report()
		sleep(2 SECONDS)
	deadline = world.time + 60 SECONDS
	while(world.time < deadline && (length(telemetry.reports) || length(lane.queries) || lane.inflight.len))
		sleep(5)
	sleep(2 SECONDS)

	// A sample published before a console's subscription reached the Host was never addressed to it.
	// "deadline" and "transport_ttl" are the Host reasons of an expired delivery.
	var/list/network_reasons = list("invalid_route", "no_route", "expired", "deadline", "newer_value", "receiver_gone",
		"transport_ttl", "not_subscribed", "subscribed_later")
	var/list/reason_deltas = list()
	var/unexplained = 0
	for(var/reason in telemetry.reasons)
		var/delta = telemetry.reasons[reason] - reasons_before[reason]
		if(!delta)
			continue
		reason_deltas[reason] = delta
		if(!(reason in network_reasons))
			unexplained += delta
	var/list/console_rows = list()
	for(var/datum/weakref/console_ref as anything in telemetry.consoles)
		var/obj/machinery/computer/atmos_control/console = console_ref.resolve()
		var/datum/netdm_service_endpoint/endpoint = console ? endpoint_of(console) : null
		if(!endpoint)
			continue
		var/list/now = telemetry.per_console[endpoint.id] || list()
		var/list/then = consoles_before[endpoint.id] || list()
		var/list/delta = list()
		for(var/key in now)
			if(now[key] - then[key])
				delta[key] = now[key] - then[key]
		var/list/subscribed = list()
		for(var/key in endpoint.subscribed)
			subscribed += key
		console_rows += list(list("endpoint" = endpoint.id, "type" = "[console.type]", "place" = place(console), "attachment" = attachment(console),
			"broken" = !!(console.machine_stat & (BROKEN|NOPOWER|MAINT|EMPED)), "subscribed" = subscribed, "window" = delta,
			"acknowledged" = endpoint.acknowledged_at.Copy()))
	var/list/sensor_rows = list()
	for(var/datum/weakref/sensor_ref as anything in telemetry.sensors)
		var/obj/machinery/air_sensor/sensor = sensor_ref.resolve()
		var/datum/netdm_service_endpoint/endpoint = sensor ? endpoint_of(sensor) : null
		if(!endpoint)
			continue
		var/list/registered = list()
		for(var/instance in endpoint.services)
			registered[instance] = endpoint.registered[instance] ? "registered" : (endpoint.refused[instance] || "pending")
		sensor_rows += list(list("endpoint" = endpoint.id, "type" = "[sensor.type]", "place" = place(sensor), "attachment" = attachment(sensor), "instances" = registered,
			"acknowledged" = endpoint.acknowledged_at.Copy(), "id_tag" = sensor.id_tag, "frequency" = sensor.frequency))
	var/list/window = telemetry.latencies.Copy(max(1, latency_start + 1))
	var/list/latency_ms = list()
	for(var/sample in sortTim(window.Copy(), GLOBAL_PROC_REF(cmp_numeric_asc)))
		latency_ms += round(sample / 1000)
	var/compared = telemetry.counters["compared"] - before["compared"]
	var/matched = telemetry.counters["matched"] - before["matched"]
	var/netdm_only = telemetry.counters["netdm_only"] - before["netdm_only"]
	var/p95 = telemetry.percentile_ms(window, 0.95)
	// Host transport and tick counters tell a stall of the Host from a delay in DM.
	var/datum/http_response/status_response = world_safe_http_get("[http_base]/api/game/status", 5 SECONDS)
	var/list/host_status = status_response?.status_code == 200 ? json_decode(status_response.body) : null
	var/list/report = list(
		"map" = SSmapping.config?.map_name,
		"window_start" = window_start,
		"lane" = lane.state(),
		"host_runner" = host_status?["runner"],
		"host_packet" = host_status?["packet"],
		"host_process" = host_status?["process"],
		"compared" = compared,
		"matched" = matched,
		"radio_only" = telemetry.counters["legacy_only"] - before["legacy_only"],
		"netdm_only" = netdm_only,
		"unmirrored" = telemetry.counters["unmirrored"] - before["unmirrored"],
		"coalesced" = lane.counters["superseded"] - coalesced_before,
		"reasons" = reason_deltas,
		"p50_ms" = telemetry.percentile_ms(window, 0.5),
		"p95_ms" = p95,
		"max_ms" = telemetry.percentile_ms(window, 1),
		"latencies_ms" = latency_ms,
		"sensors" = sensor_rows,
		"consoles" = console_rows,
		"observe" = SSnetdm_observe.observe_state(),
		"mismatches" = telemetry.mismatches,
	)
	var/path = "[GLOB.log_directory]/netdm_atmos_station.json"
	fdel(path)
	text2file(json_encode(report), path)
	log_world("netDM atmos station: [report["map"]] compared=[compared] matched=[matched] radio_only=[report["radio_only"]] \
		netdm_only=[netdm_only] reasons=[json_encode(reason_deltas)] p50=[report["p50_ms"]]ms p95=[p95]ms max=[report["max_ms"]]ms")
	TEST_ASSERT(compared > 0, "The station pilot must compare reports: [json_encode(report)]")
	TEST_ASSERT_EQUAL(netdm_only, 0, "netDM must not deliver where the radio does not: [json_encode(report)]")
	TEST_ASSERT_EQUAL(unexplained, 0, "Every radio-only console needs a reason: [json_encode(reason_deltas)]")
	if(matched >= 20)
		TEST_ASSERT(p95 <= 500, "End-to-end p95 must stay within 500 ms on the station, got [p95] ms: [json_encode(latency_ms)]")

/// P7 Shadow on the station: PDAs by APCs across departments message each other through the map's own
/// telecomms, then through the debug bypass. Writes netdm_messenger_station.json; fails only on contract
/// breaches: a message shown twice, a radio-only recipient without a network reason, or arrival p95 above
/// the budget.
/datum/unit_test/netdm_observe/area_map/messenger_station

/datum/unit_test/netdm_observe/area_map/messenger_station/proc/exchange(datum/netdm_messenger_shadow/shadow, datum/netdm_service_lane/lane, list/messengers, list/pdas, label)
	var/compared = shadow.counters["compared"]
	var/count = length(messengers)
	var/sent = 0
	for(var/index in 1 to count)
		var/datum/computer_file/program/messenger/sender = messengers[index]
		var/datum/computer_file/program/messenger/target = messengers[(index + round(count / 2) - 1) % count + 1]
		if(sender.send_message(pdas[index], "netDM station [label] [index]", list(target)))
			sent++
		sleep(2)
	var/deadline = world.time + 40 SECONDS
	while(world.time < deadline && (length(shadow.sends) || length(lane.command_queries)))
		sleep(5)
	sleep(1 SECONDS)
	return list("label" = label, "legacy_sent" = sent, "compared" = shadow.counters["compared"] - compared)

/// Authoritative mode on the station: the PDAs send through the map's own message server, then once
/// more while it is off. Writes netdm_messenger_station.json.
/datum/unit_test/netdm_observe/area_map/messenger_station/proc/authoritative_station(datum/netdm_messenger_shadow/shadow,
	datum/netdm_service_lane/lane, list/messengers, list/pdas, ready)
	var/list/counters = shadow.relay_counters
	var/list/map_servers = list()
	for(var/instance in shadow.servers)
		var/datum/weakref/server_ref = shadow.servers[instance]
		var/obj/machinery/telecomms/message_server/server = server_ref.resolve()
		if(server)
			map_servers += server
	TEST_ASSERT(length(map_servers), "The station's message server must offer msgsrv: [shadow.state()]")
	var/deadline = world.time + 60 SECONDS
	while(world.time < deadline && !shadow.choose_server(pdas[1]))
		sleep(10)
	var/list/before = counters.Copy()
	var/list/reasons_before = shadow.reasons.Copy()
	var/arrivals_start = length(shadow.arrivals)
	var/answers_start = length(shadow.relay_latencies)
	var/list/logged_before = list()
	for(var/obj/machinery/telecomms/message_server/server as anything in map_servers)
		logged_before[server] = length(server.pda_msgs)
	var/old_bypass = SSnetworks.ntnet_debug_global_signal
	SSnetworks.ntnet_debug_global_signal = FALSE
	var/count = length(messengers)
	var/sent = 0
	for(var/index in 1 to count)
		var/datum/computer_file/program/messenger/sender = messengers[index]
		var/datum/computer_file/program/messenger/target = messengers[(index + round(count / 2) - 1) % count + 1]
		if(sender.send_message(pdas[index], "netDM station server [index]", list(target)))
			sent++
		sleep(2)
	deadline = world.time + 60 SECONDS
	while(world.time < deadline && length(shadow.outgoing))
		sleep(5)
	var/list/delta = list()
	for(var/name in counters)
		if(counters[name] != before[name])
			delta[name] = counters[name] - before[name]
	var/list/window = shadow.arrivals.Copy(max(1, arrivals_start + 1))
	var/list/answers = shadow.relay_latencies.Copy(max(1, answers_start + 1))
	var/logged = 0
	for(var/obj/machinery/telecomms/message_server/server as anything in map_servers)
		logged += length(server.pda_msgs) - logged_before[server]

	// The same messages with the server off: refused, nothing shown, nothing logged.
	for(var/obj/machinery/telecomms/message_server/server as anything in map_servers)
		server.toggled = FALSE
	sleep(1.2 SECONDS)
	var/shown_on = counters["shown"]
	var/offline_before = shadow.reasons["relay_offline"]
	for(var/index in 1 to count)
		var/datum/computer_file/program/messenger/sender = messengers[index]
		var/datum/computer_file/program/messenger/target = messengers[(index + round(count / 2) - 1) % count + 1]
		sender.send_message(pdas[index], "netDM station server off [index]", list(target))
		sleep(2)
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && length(shadow.outgoing))
		sleep(5)
	for(var/obj/machinery/telecomms/message_server/server as anything in map_servers)
		server.toggled = TRUE
	SSnetworks.ntnet_debug_global_signal = old_bypass
	var/list/reason_deltas = list()
	for(var/reason in shadow.reasons)
		if(shadow.reasons[reason] != reasons_before[reason])
			reason_deltas[reason] = shadow.reasons[reason] - reasons_before[reason]
	var/list/arrival_ms = list()
	for(var/sample in sortTim(window.Copy(), GLOBAL_PROC_REF(cmp_numeric_asc)))
		arrival_ms += round(sample / 1000)
	var/datum/http_response/status_response = world_safe_http_get("[http_base]/api/game/status", 5 SECONDS)
	var/list/host_status = status_response?.status_code == 200 ? json_decode(status_response.body) : null
	var/p95 = shadow.percentile_ms(window, 0.95)
	var/list/server_rows = list()
	for(var/obj/machinery/telecomms/message_server/server as anything in map_servers)
		var/datum/component/netdm_node/node = server.GetComponent(/datum/component/netdm_node)
		var/turf/position = get_turf(server)
		var/area/zone = get_area(server)
		var/node_id = node ? SSnetdm_observe.node_ids[node] : null
		var/list/host = node_id && position ? host_node(position.z, node_id) : null
		server_rows += list(list("place" = "[zone?.type] [position?.x],[position?.y],[position?.z]", "attached" = lane.by_node[node]?.attached_node,
			"links" = host?["links"], "radio" = host?["radioEnabled"], "powered" = !(server.machine_stat & NOPOWER)))
	var/list/report = list(
		"map" = SSmapping.config?.map_name,
		"mode" = "authoritative",
		"pdas" = length(pdas),
		"ready" = ready,
		"servers" = length(map_servers),
		"server_rows" = server_rows,
		"apc_bridges" = host_status?["apcBridges"],
		"sent" = sent,
		"counters" = delta,
		"logged" = logged,
		"offline_refused" = shadow.reasons["relay_offline"] - offline_before,
		"shown_while_off" = counters["shown"] - shown_on,
		"reasons" = reason_deltas,
		"arrival_p50_ms" = shadow.percentile_ms(window, 0.5),
		"arrival_p95_ms" = p95,
		"answer_p95_ms" = shadow.percentile_ms(answers, 0.95),
		"arrival_ms" = arrival_ms,
		"lane" = lane.state(),
		"host_runner" = host_status?["runner"],
		"host_process" = host_status?["process"],
	)
	var/path = "[GLOB.log_directory]/netdm_messenger_station.json"
	fdel(path)
	text2file(json_encode(report), path)
	log_world("netDM messenger station: [report["map"]] authoritative pdas=[length(pdas)] ready=[ready] sent=[sent] \
		counters=[json_encode(delta)] logged=[logged] offline_refused=[report["offline_refused"]] shown_while_off=[report["shown_while_off"]] \
		reasons=[json_encode(reason_deltas)] arrival p50=[report["arrival_p50_ms"]]ms p95=[p95]ms answer p95=[report["answer_p95_ms"]]ms 		bridges=[json_encode(report["apc_bridges"])]")
	TEST_ASSERT_EQUAL(delta["relayed"], sent, "Every message leaves through the server: [json_encode(report)]")
	TEST_ASSERT_EQUAL(delta["shown"], delta["delivered"], "What was shown is what the senders were told: [json_encode(report)]")
	TEST_ASSERT_EQUAL(delta["delivered"] + delta["unreachable"], sent, "Each recipient is delivered or reported unreachable: [json_encode(report)]")
	TEST_ASSERT_EQUAL(delta["duplicates"], null, "Nothing is shown twice: [json_encode(report)]")
	TEST_ASSERT_EQUAL(logged, delta["queued"], "The server logs each message it takes once: [json_encode(report)]")
	TEST_ASSERT_EQUAL(report["offline_refused"], count, "A server that is off refuses every message: [json_encode(report)]")
	TEST_ASSERT_EQUAL(report["shown_while_off"], 0, "Nothing is shown while the server is off: [json_encode(report)]")
	if(delta["delivered"] >= 10)
		TEST_ASSERT(p95 <= 1000, "Arrival p95 through the server must stay within 1000 ms, got [p95] ms: [json_encode(arrival_ms)]")

/datum/unit_test/netdm_observe/area_map/messenger_station/Run()
	if(world.GetConfig("env", "NETDM_OBSERVE") != "1")
		return
	var/datum/netdm_messenger_shadow/shadow = SSnetdm_observe.messenger
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	TEST_ASSERT(shadow && lane, "Observe must run the messenger pilot.")
	http_base = world.GetConfig("env", "NETDM_TEST_HTTP")
	var/deadline = world.time + 10 MINUTES
	while(world.time < deadline && !(SSnetdm_observe.published && SSnetdm_observe.phase == "live" && !SSnetdm_observe.pending))
		sleep(10)
	TEST_ASSERT(SSnetdm_observe.published, "Observe must publish the station map ([SSnetdm_observe.observe_state()]).")

	// One PDA by every few station APCs, spread across the map in a stable order.
	var/list/apcs = list()
	for(var/obj/machinery/power/apc/apc as anything in GLOB.apcs_list)
		var/turf/position = get_turf(apc)
		if(position && is_station_level(position.z) && !(apc.machine_stat & BROKEN))
			apcs += apc
	TEST_ASSERT(length(apcs) >= 4, "The station needs APCs to place PDAs by.")
	var/step = max(1, round(length(apcs) / 12))
	var/list/pdas = list()
	var/list/messengers = list()
	for(var/index = 1; index <= length(apcs) && length(pdas) < 12; index += step)
		var/obj/machinery/power/apc/apc = apcs[index]
		var/obj/item/modular_computer/pda/pda = allocate(/obj/item/modular_computer/pda, get_turf(apc))
		var/datum/computer_file/program/messenger/messenger = locate(/datum/computer_file/program/messenger) in pda.get_all_files()
		TEST_ASSERT(messenger, "PDAs come with the messenger.")
		pda.saved_identification = "netDM [index]"
		add_messenger(messenger)
		pdas += pda
		messengers += messenger
	var/pdas_before = length(shadow.instances)

	// Each messenger registers its instance, or stays pending where its node has no attachment.
	deadline = world.time + 90 SECONDS
	var/ready = 0
	while(world.time < deadline)
		ready = 0
		for(var/index in 1 to length(pdas))
			var/obj/item/modular_computer/pda/pda = pdas[index]
			var/datum/component/netdm_node/node = pda.GetComponent(/datum/component/netdm_node)
			if(node && lane.ready(node, shadow.instances[WEAKREF(messengers[index])]))
				ready++
		if(ready == length(pdas))
			break
		sleep(10)
	if(shadow.authoritative)
		authoritative_station(shadow, lane, messengers, pdas, ready)
		return

	var/list/before = shadow.counters.Copy()
	var/list/reasons_before = shadow.reasons.Copy()
	var/arrivals_start = length(shadow.arrivals)
	lane.max_poll_gap_us = 0
	lane.max_reply_us = 0
	lane.max_reply_op = null
	var/old_bypass = SSnetworks.ntnet_debug_global_signal
	SSnetworks.ntnet_debug_global_signal = FALSE
	var/list/passes = list()
	passes += list(exchange(shadow, lane, messengers, pdas, "telecomms"))
	sleep(1.2 SECONDS)
	SSnetworks.ntnet_debug_global_signal = TRUE
	passes += list(exchange(shadow, lane, messengers, pdas, "bypass"))
	SSnetworks.ntnet_debug_global_signal = old_bypass

	// Reasons the network gives for a recipient the radio reached and netDM did not.
	var/list/network_reasons = list("invalid_route", "no_route", "expired", "deadline", "transport_ttl", "receiver_gone", "provider_gone",
		"unknown_instance", "no_messenger")
	var/list/reason_deltas = list()
	var/unexplained = 0
	for(var/reason in shadow.reasons)
		var/delta = shadow.reasons[reason] - reasons_before[reason]
		if(!delta)
			continue
		reason_deltas[reason] = delta
		if(!(reason in network_reasons) && reason != "legacy_server" && reason != "legacy_missed")
			unexplained += delta
	var/list/rows = list()
	for(var/index in 1 to length(pdas))
		var/obj/item/modular_computer/pda/pda = pdas[index]
		var/datum/component/netdm_node/node = pda.GetComponent(/datum/component/netdm_node)
		var/datum/netdm_service_endpoint/endpoint = node ? lane.by_node[node] : null
		var/turf/position = get_turf(pda)
		var/node_id = node ? SSnetdm_observe.node_ids[node] : null
		var/list/host = node_id && position ? host_node(position.z, node_id) : null
		var/area/zone = get_area(pda)
		rows += list(list("instance" = shadow.instances[WEAKREF(messengers[index])], "place" = "[zone?.type] [position?.x],[position?.y],[position?.z]",
			"attached" = endpoint?.attached_node, "links" = host?["links"], "radio" = host?["radioEnabled"]))
	var/list/window = shadow.arrivals.Copy(max(1, arrivals_start + 1))
	var/list/arrival_ms = list()
	for(var/sample in sortTim(window.Copy(), GLOBAL_PROC_REF(cmp_numeric_asc)))
		arrival_ms += round(sample / 1000)
	var/datum/http_response/status_response = world_safe_http_get("[http_base]/api/game/status", 5 SECONDS)
	var/list/host_status = status_response?.status_code == 200 ? json_decode(status_response.body) : null
	var/matched = shadow.counters["matched"] - before["matched"]
	var/p95 = shadow.percentile_ms(window, 0.95)
	var/list/report = list(
		"map" = SSmapping.config?.map_name,
		"pdas" = length(pdas),
		"pdas_on_map" = pdas_before - length(pdas),
		"ready" = ready,
		"passes" = passes,
		"compared" = shadow.counters["compared"] - before["compared"],
		"matched" = matched,
		"radio_only" = shadow.counters["legacy_only"] - before["legacy_only"],
		"netdm_only" = shadow.counters["netdm_only"] - before["netdm_only"],
		"legacy_duplicates" = shadow.counters["legacy_duplicates"] - before["legacy_duplicates"],
		"netdm_duplicates" = shadow.counters["netdm_duplicates"] - before["netdm_duplicates"],
		"unmirrored" = shadow.counters["unmirrored"] - before["unmirrored"],
		"reasons" = reason_deltas,
		"arrival_p50_ms" = shadow.percentile_ms(window, 0.5),
		"arrival_p95_ms" = p95,
		"arrival_ms" = arrival_ms,
		"lane" = lane.state(),
		"host_runner" = host_status?["runner"],
		"host_process" = host_status?["process"],
		"rows" = rows,
		"notes" = shadow.notes,
	)
	var/path = "[GLOB.log_directory]/netdm_messenger_station.json"
	fdel(path)
	text2file(json_encode(report), path)
	log_world("netDM messenger station: [report["map"]] pdas=[length(pdas)] ready=[ready] passes=[json_encode(passes)] \
		matched=[matched] radio_only=[report["radio_only"]] netdm_only=[report["netdm_only"]] reasons=[json_encode(reason_deltas)] \
		arrival p50=[report["arrival_p50_ms"]]ms p95=[p95]ms [shadow.state()]")
	TEST_ASSERT(report["compared"] > 0, "The station pilot must compare messages: [json_encode(report)]")
	TEST_ASSERT_EQUAL(report["legacy_duplicates"] + report["netdm_duplicates"], 0, "Nothing is shown twice: [json_encode(report)]")
	TEST_ASSERT_EQUAL(unexplained, 0, "Every one-sided delivery needs a reason: [json_encode(reason_deltas)] [json_encode(shadow.notes)]")
	if(matched >= 10)
		TEST_ASSERT(p95 <= 500, "Arrival p95 must stay within 500 ms on the station, got [p95] ms: [json_encode(arrival_ms)]")

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
	if(world.GetConfig("env", "NETDM_OBSERVE") != "1")
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

/// P9.1: a press keeps its legacy effect and reaches the button's doors over the network as set_state commands.
/// The button and its doors join the network at the first press, which waits for them; a door out of the
/// network is missed with the Host's reason.
/datum/unit_test/netdm_observe/area_map/door_shadow

/datum/unit_test/netdm_observe/area_map/door_shadow/proc/explained(datum/netdm_door_shadow/shadow)
	. = 0
	for(var/reason in shadow.reasons)
		. += shadow.reasons[reason]

/// Waits for the comparison, then for the status answers that explain its misses.
/datum/unit_test/netdm_observe/area_map/door_shadow/proc/wait_compared(datum/netdm_door_shadow/shadow, compared, timeout = 20 SECONDS)
	var/deadline = world.time + timeout
	while(world.time < deadline && (shadow.counters["compared"] < compared || length(shadow.presses)))
		sleep(2)
	deadline = world.time + 5 SECONDS
	while(world.time < deadline && explained(shadow) < shadow.counters["missed"])
		sleep(2)
	return shadow.counters["compared"] >= compared

/datum/unit_test/netdm_observe/area_map/door_shadow/proc/last_press(datum/netdm_door_shadow/shadow)
	return length(shadow.presses) ? shadow.presses[shadow.presses[length(shadow.presses)]] : null

/datum/unit_test/netdm_observe/area_map/door_shadow/proc/new_reasons(datum/netdm_door_shadow/shadow, list/reasons_before)
	. = list()
	for(var/reason in shadow.reasons)
		if(shadow.reasons[reason] != reasons_before[reason])
			. += reason

/datum/unit_test/netdm_observe/area_map/door_shadow/Run()
	if(world.GetConfig("env", "NETDM_OBSERVE") != "1")
		return
	TEST_ASSERT(wait_until_live(), "Observe must publish the map ([SSnetdm_observe.observe_state()]).")
	var/datum/netdm_door_shadow/shadow = SSnetdm_observe.doors
	TEST_ASSERT(shadow, "Observe must run the door pilot.")
	var/list/turfs = list(run_loc_floor_bottom_left)
	for(var/i in 1 to 3)
		turfs += get_step(turfs[length(turfs)], EAST)
	var/area/served = test_zone(/area/netdm_test/first)
	for(var/turf/tile as anything in turfs)
		assign_area(tile, served)
	var/obj/machinery/power/apc/apc = allocate(/obj/machinery/power/apc, turfs[1])
	TEST_ASSERT(wait_for_fact(WEAKREF(apc), turfs[1]), "Expected the zone APC to be published.")
	var/tag = "netdm-doors-[rand(1000, 9999)]"
	var/obj/machinery/button/door/blast_button = allocate(/obj/machinery/button/door, turfs[2])
	var/obj/item/assembly/control/blast_control = blast_button.device
	TEST_ASSERT(istype(blast_control), "A door button carries a blast door controller.")
	blast_control.id = tag
	var/obj/machinery/door/poddoor/first = allocate(/obj/machinery/door/poddoor, turfs[3])
	var/obj/machinery/door/poddoor/second = allocate(/obj/machinery/door/poddoor, turfs[4])
	var/obj/machinery/door/poddoor/away = allocate(/obj/machinery/door/poddoor, turfs[4])
	var/turf/corner = isolated_turf()
	TEST_ASSERT(corner, "The station level needs a corner without an APC nearby.")
	away.forceMove(corner)
	for(var/obj/machinery/door/poddoor/door as anything in list(first, second, away))
		door.id = tag
	var/obj/machinery/button/door/airlock_button = allocate(/obj/machinery/button/door, turfs[2])
	qdel(airlock_button.device)
	var/obj/item/assembly/control/airlock/airlock_control = new(airlock_button)
	airlock_button.device = airlock_control
	airlock_control.id = "[tag]-airlock"
	airlock_control.specialfunctions = OPEN | SAFE
	var/obj/machinery/door/airlock/airlock = allocate(/obj/machinery/door/airlock, turfs[2])
	airlock.id_tag = "[tag]-airlock"
	TEST_ASSERT(!first.GetComponent(/datum/component/netdm_node) && !blast_button.GetComponent(/datum/component/netdm_node),
		"Buttons and doors join the network only when pressed.")
	var/list/invalid = list("unanswered", "not_attached", "lane_full", "unknown")

	// The first press brings the button and its doors into the network and waits for them.
	var/list/before = shadow.counters.Copy()
	var/list/reasons_before = shadow.reasons.Copy()
	blast_control.activate()
	var/list/press = last_press(shadow)
	TEST_ASSERT(press && length(press["targets"]) == 3, "The press is mirrored to its three doors: [shadow.state()]")
	TEST_ASSERT_EQUAL(press["wanted"][shadow.instances[WEAKREF(first)]]["state"], "open", "Closed blast doors are opened.")
	TEST_ASSERT(wait_compared(shadow, before["compared"] + 3), "The press is compared: [shadow.state()]")
	TEST_ASSERT_EQUAL(shadow.counters["reached"] - before["reached"], 2, "Both doors of the zone are reached: [shadow.state()] [json_encode(shadow.notes)]")
	TEST_ASSERT_EQUAL(shadow.counters["cold"] - before["cold"], 2, "The first press waits for its endpoints: [shadow.state()]")
	TEST_ASSERT_EQUAL(shadow.counters["missed"] - before["missed"], 1, "The door out of the network is missed: [shadow.state()]")
	TEST_ASSERT_EQUAL(shadow.counters["kept"] - before["kept"], 2, "Legacy opened both doors as the press said: [json_encode(shadow.notes)]")
	TEST_ASSERT(!first.density && !second.density, "The press keeps its legacy effect.")
	var/list/missed_reasons = new_reasons(shadow, reasons_before)
	TEST_ASSERT(length(missed_reasons) == 1 && !(missed_reasons[1] in invalid),
		"The Host explains the miss: [json_encode(shadow.reasons)] [json_encode(shadow.notes)]")
	TEST_ASSERT(shadow.percentile_ms(shadow.cold_arrivals, 0.5) > 0, "A first press has a latency: [shadow.state()]")

	// The next press finds them attached.
	before = shadow.counters.Copy()
	reasons_before = shadow.reasons.Copy()
	blast_control.activate()
	press = last_press(shadow)
	TEST_ASSERT_EQUAL(press?["wanted"][shadow.instances[WEAKREF(first)]]["state"], "closed", "Open blast doors are closed.")
	TEST_ASSERT(wait_compared(shadow, before["compared"] + 3), "The second press is compared: [shadow.state()]")
	TEST_ASSERT_EQUAL(shadow.counters["reached"] - before["reached"], 2, "Both doors are reached again: [shadow.state()] [json_encode(shadow.notes)]")
	TEST_ASSERT_EQUAL(shadow.counters["cold"], before["cold"], "Attached doors take the command at once: [shadow.state()]")
	missed_reasons = new_reasons(shadow, reasons_before)
	TEST_ASSERT(length(missed_reasons) == 1 && !(missed_reasons[1] in invalid), "The corner door is missed again: [json_encode(shadow.reasons)]")
	TEST_ASSERT(shadow.percentile_ms(shadow.arrivals, 0.5) > 0, "Arrivals have a latency: [shadow.state()]")

	before = shadow.counters.Copy()
	airlock_control.activate()
	var/airlock_instance = shadow.instances[WEAKREF(airlock)]
	TEST_ASSERT(airlock_instance, "The press brings the airlock into the network.")
	TEST_ASSERT(wait_compared(shadow, before["compared"] + 1), "The airlock press is compared: [shadow.state()]")
	TEST_ASSERT_EQUAL(shadow.counters["reached"] - before["reached"], 1, "The airlock is reached: [shadow.state()] [json_encode(shadow.notes)]")
	var/deadline = world.time + 10 SECONDS
	while(world.time < deadline && (airlock.density || airlock.operating))
		sleep(2)
	TEST_ASSERT(!airlock.density, "The airlock opened: [shadow.state()]")

	before = shadow.counters.Copy()
	airlock_control.activate()
	press = last_press(shadow)
	var/list/wanted = press?["wanted"][airlock_instance]
	TEST_ASSERT(wanted && wanted["state"] == "closed" && wanted["safety"] == TRUE,
		"An open airlock is closed, with the safety the legacy press left: [json_encode(wanted)]")
	deadline = world.time + 10 SECONDS
	while(world.time < deadline && isnull(press["arrived"][airlock_instance]))
		sleep(1)
	TEST_ASSERT(!isnull(press["arrived"][airlock_instance]), "The command reaches the airlock: [shadow.state()]")
	var/list/again = shadow.received(airlock, list("payload" = list("press" = press["id"]), "instance" = airlock_instance))
	TEST_ASSERT(islist(again) && again["result"]["reason"] == "shadow" && shadow.counters["duplicates"] == before["duplicates"] + 1,
		"A repeated command is recorded once: [shadow.state()]")
	TEST_ASSERT(wait_compared(shadow, before["compared"] + 1), "The second airlock press is compared: [shadow.state()]")
	TEST_ASSERT_EQUAL(shadow.counters["reached"] - before["reached"], 1, "The registered airlock is reached: [shadow.state()] [json_encode(shadow.notes)]")

	var/not_button = shadow.exceptions["not_button"] || 0
	var/obj/item/assembly/control/loose = allocate(/obj/item/assembly/control, turfs[1])
	loose.id = "[tag]-none"
	loose.activate()
	TEST_ASSERT(shadow.exceptions["not_button"] == not_button + 1, "A controller outside a button is an exception: [shadow.state()]")

	// Authoritative: the press moves nothing itself; each door moves when its command arrives over the network,
	// and the door the network does not reach stays as it was.
	shadow.set_authoritative(TRUE)
	sleep(11) // The buttons' cooldown from the presses above.
	TEST_ASSERT(first.density && second.density && away.density, "The blast doors start closed.")
	before = shadow.counters.Copy()
	blast_control.activate()
	TEST_ASSERT(first.density && second.density, "Under authority a press does not move the doors itself.")
	deadline = world.time + 10 SECONDS
	while(world.time < deadline && (first.density || second.density))
		sleep(1)
	TEST_ASSERT(!first.density && !second.density, "The doors open when the command reaches them: [shadow.state()] [json_encode(shadow.notes)]")
	TEST_ASSERT(away.density, "A door the network does not reach stays closed.")
	TEST_ASSERT(wait_compared(shadow, before["compared"] + 3), "The authoritative press is compared: [shadow.state()]")
	TEST_ASSERT_EQUAL(shadow.counters["kept"] - before["kept"], 2, "Both reached doors ended where the press put them: [json_encode(shadow.notes)]")
	var/safe_before = airlock.safe
	var/airlock_closed = airlock.density
	before = shadow.counters.Copy()
	airlock_control.activate()
	press = last_press(shadow)
	TEST_ASSERT(airlock.safe == safe_before && airlock.density == airlock_closed, "The airlock waits for its command.")
	TEST_ASSERT(press?["wanted"][airlock_instance]["safety"] == !safe_before, "The command carries where the safety toggle leads: [json_encode(press?["wanted"])]")
	deadline = world.time + 10 SECONDS
	while(world.time < deadline && airlock.safe == safe_before)
		sleep(1)
	TEST_ASSERT(airlock.safe == !safe_before, "The airlock takes its safety from the command.")
	var/list/repeated = shadow.received(airlock, list("payload" = list("press" = press["id"], "safety" = safe_before), "instance" = airlock_instance))
	TEST_ASSERT(repeated?["result"]["reason"] == "duplicate" && airlock.safe == !safe_before, "A repeated command does not apply twice.")
	TEST_ASSERT(wait_compared(shadow, before["compared"] + 1), "The authoritative airlock press is compared: [shadow.state()]")
	shadow.set_authoritative(FALSE)
	log_world("netDM door shadow: [shadow.state()] notes=[json_encode(shadow.notes)]")

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
	if(world.GetConfig("env", "NETDM_OBSERVE") != "1")
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
	if(world.GetConfig("env", "NETDM_OBSERVE") != "1")
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
