/// Map tests control only their own queued view; routes still use real APC connectivity.
/datum/netrun_console/netrun_async_map_probe
	var/hold_routes = FALSE

/datum/netrun_console/netrun_async_map_probe/push_ui_update()
	return

/datum/netrun_console/netrun_async_map_probe/acquire_ui_routes()
	if(!hold_routes)
		return ..()
	ui_routes_pending = TRUE
	ui_routes_borrowed = FALSE
	var/datum/netrun_path_tree/tree = new
	tree.network_index_ready = TRUE
	tree.source = physical_route_source()
	if(tree.source)
		tree.source_online = tree.source.is_online()
		tree.reached[tree.source.address] = TRUE
	return tree

/datum/netrun_map_view/netrun_async_map_probe
	var/projected_entries = 0

/datum/netrun_map_view/netrun_async_map_probe/project_entry(datum/component/netrun_node/node, neighbor_count)
	projected_entries++
	return ..()

/datum/netrun_async_map_scene
	parent_type = /datum/netrun_route_scene
	var/obj/item/source
	var/datum/component/netrun_node/source_node
	var/datum/component/netrun_node/engineering_target
	var/datum/component/netrun_node/medical_target
	var/datum/netrun_console/netrun_async_map_probe/console
	var/datum/netrun_map_view/netrun_async_map_probe/view
	var/turf/medical_destination
	var/list/fixture_nodes = list()
	var/list/engineering_devices = list()

/datum/netrun_async_map_scene/New(turf/origin)
	..(origin.z)
	var/area/engineering = room(/area/engineering/netrun_route_test)
	var/area/medical = room(/area/medical/netrun_route_test)
	for(var/turf/spot as anything in block(origin, locate(origin.x + 5, origin.y + 2, origin.z)))
		take(spot, engineering)
	for(var/turf/spot as anything in block(locate(origin.x + 8, origin.y, origin.z), locate(origin.x + 11, origin.y + 2, origin.z)))
		take(spot, medical)
	var/obj/machinery/power/apc/first = machine(/obj/machinery/power/apc, get_step(origin, NORTH))
	var/obj/machinery/power/apc/second = machine(/obj/machinery/power/apc, locate(origin.x + 8, origin.y + 1, origin.z))
	fixture_nodes += first.GetComponent(/datum/component/netrun_node)
	fixture_nodes += second.GetComponent(/datum/component/netrun_node)
	source = new(origin)
	owned += source
	source_node = source.AddComponent(/datum/component/netrun_node, NETRUN_NODE_DECK)
	fixture_nodes += source_node
	for(var/i in 1 to 8)
		var/obj/item/device = new(locate(origin.x + 1 + i % 4, origin.y + 2, origin.z))
		owned += device
		engineering_devices += device
		var/datum/component/netrun_node/node = device.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
		fixture_nodes += node
		if(!engineering_target)
			engineering_target = node
	var/obj/item/medical_device = new(locate(origin.x + 10, origin.y + 2, origin.z))
	owned += medical_device
	medical_target = medical_device.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
	fixture_nodes += medical_target
	medical_destination = locate(origin.x + 9, origin.y, origin.z)
	console = new(source)
	console.connection.wireless = FALSE
	QDEL_NULL(console.map_view)
	view = new(console)
	console.map_view = view
	console.workspace_view = "map"
	SSnetworks.station_network.setting_disabled = TRUE
	SSnetrun.ensure_topology()
	for(var/datum/component/netrun_node/node as anything in fixture_nodes)
		node.join_network()
		node.reconcile_state()
		node.publish_changes()
	warm_routes()

/datum/netrun_async_map_scene/Destroy()
	QDEL_NULL(console)
	view = null
	return ..()

/// Gameplay routing warms a real completed tree without coupling map tests to solve budgets.
/datum/netrun_async_map_scene/proc/warm_routes()
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	graph.route_snapshot(source_node, TRUE)

/// Use the real clock barrier; never reset projection_advanced_at to bypass production rules.
/datum/netrun_async_map_scene/proc/step_map(operations = 16)
	SSnetrun.get_task_scheduler().cancel("map_projection", view)
	sleep(world.tick_lag)
	SSnetrun.get_task_scheduler().cancel("map_projection", view)
	return view.advance_projection(operations)

/datum/netrun_async_map_scene/proc/settle_map()
	var/deadline = world.time + 30 SECONDS
	var/list/data = console.ui_data(null)
	while(world.time < deadline)
		if(!view.projection && !view.dirty && !view.structure_dirty && !length(view.dirty_nodes) && !console.ui_routes_pending)
			return data
		step_map()
		data = console.ui_data(null)
	return null

/// Empty initial transport and independently versioned slices keep UI callbacks bounded.
/datum/unit_test/netrun_async_map_progressive_discovery/Run()
	var/datum/netrun_async_map_scene/scene = allocate(/datum/netrun_async_map_scene, run_loc_floor_bottom_left)
	var/list/data = scene.console.ui_data(null)
	var/list/map = data["map"]
	TEST_ASSERT_NOTNULL(map, "Opening a map must publish an explicit empty baseline while discovery is queued")
	TEST_ASSERT_EQUAL(length(map["nodes"]), 0, "The opening UI callback must not synchronously project the graph")
	TEST_ASSERT_NOTNULL(scene.view.projection, "Initial discovery must have a resumable worker")
	SSnetrun.get_task_scheduler().cancel("map_projection", scene.view)
	var/list/session = list("id" = 1)
	var/list/wire = scene.view.encode_wire(map, session)
	TEST_ASSERT(wire["full"], "An empty first snapshot is still a valid full transport baseline")
	var/previous_revision = scene.view.state_revision
	scene.view.advance_projection(1)
	var/first_cursor = scene.view.projection.cursor
	var/first_phase = scene.view.projection.phase
	scene.view.advance_projection(1)
	TEST_ASSERT_EQUAL(scene.view.projection.cursor, first_cursor, "Repeated dispatch within one world tick must not advance the discovery cursor")
	TEST_ASSERT_EQUAL(scene.view.projection.phase, first_phase, "Repeated dispatch within one world tick must not advance the discovery phase")
	TEST_ASSERT_EQUAL(scene.view.projected_entries, 0, "The first operation only enters reachable-node discovery")
	scene.step_map(1)
	data = scene.console.ui_data(null)
	map = data["map"]
	TEST_ASSERT_EQUAL(scene.view.projected_entries, 1, "A one-operation slice must serialize at most one reachable node")
	TEST_ASSERT_EQUAL(length(map["nodes"]), 1, "The first reachable marker must appear before discovery finishes")
	TEST_ASSERT(scene.view.state_revision > previous_revision, "A progressive upsert must advance the wire state revision")
	wire = scene.view.encode_wire(map, session)
	TEST_ASSERT(!wire["full"], "The first discovered marker must use a delta against the empty baseline")
	TEST_ASSERT_EQUAL(wire["base_revision"], previous_revision, "The progressive journal must preserve its contiguous baseline revision")
	TEST_ASSERT_EQUAL(length(wire["nodes"]), 1, "The first wire delta must contain only the discovered marker")
	data = scene.settle_map()
	TEST_ASSERT_NOTNULL(data, "Bounded discovery must finish without reopening the UI")
	TEST_ASSERT(netrun_map_has_node(data, scene.engineering_target.address), "The source LAN's reachable endpoint must eventually appear")
	TEST_ASSERT(!netrun_map_has_node(data, scene.medical_target.address), "Progressive routing must not disclose a protected remote LAN endpoint")

/// A new home LAN may change grants while the physical source keeps its address.
/datum/unit_test/netrun_async_map_lan_revocation/Run()
	var/datum/netrun_async_map_scene/scene = allocate(/datum/netrun_async_map_scene, run_loc_floor_bottom_left)
	var/list/data = scene.settle_map()
	TEST_ASSERT_NOTNULL(data, "The old authorization projection must finish")
	TEST_ASSERT(netrun_map_has_node(data, scene.engineering_target.address), "The original home LAN must initially disclose its endpoint")
	var/old_epoch = scene.view.wire_epoch
	scene.source.forceMove(scene.medical_destination)
	scene.source_node.join_network()
	scene.warm_routes()
	data = scene.console.ui_data(null)
	var/list/map = data["map"]
	TEST_ASSERT(scene.view.wire_epoch > old_epoch, "Changing a source LAN's grants must replace the transport epoch")
	TEST_ASSERT_EQUAL(length(map["nodes"]), 0, "A new authorization epoch must immediately revoke the old graph baseline")
	TEST_ASSERT_EQUAL(length(map["gateways"]), 0, "A new authorization epoch must explicitly revoke old gateway metadata")
	TEST_ASSERT_EQUAL(length(map["sectors"]), 0, "A new authorization epoch must explicitly revoke old sector metadata")
	TEST_ASSERT_EQUAL(length(map["apc_zones"]), 0, "A new authorization epoch must explicitly revoke old area highlights")
	TEST_ASSERT(!scene.console.node_visible(scene.engineering_target), "Gameplay permission checks must revoke the old home LAN before asynchronous discovery finishes")
	data = scene.settle_map()
	TEST_ASSERT_NOTNULL(data, "The replacement authorization projection must finish")
	TEST_ASSERT(!netrun_map_has_node(data, scene.engineering_target.address), "The old private endpoint must remain absent after completion")
	TEST_ASSERT(netrun_map_has_node(data, scene.medical_target.address), "The new home LAN's endpoint must appear incrementally")

/// Swap deletion must keep every retained index and cable endpoint consistent.
/datum/unit_test/netrun_async_map_deletion_indexes/Run()
	var/datum/netrun_async_map_scene/scene = allocate(/datum/netrun_async_map_scene, run_loc_floor_bottom_left)
	var/list/data = scene.settle_map()
	TEST_ASSERT_NOTNULL(data, "The baseline must finish before deleting endpoints")
	var/list/session = list("id" = 2)
	scene.view.encode_wire(data["map"], session)
	var/obj/item/first = scene.engineering_devices[1]
	var/obj/item/last = scene.engineering_devices[length(scene.engineering_devices)]
	var/datum/component/netrun_node/first_node = first.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/last_node = last.GetComponent(/datum/component/netrun_node)
	var/first_address = first_node.address
	var/last_address = last_node.address
	qdel(first)
	qdel(last)
	scene.warm_routes()
	scene.console.ui_data(null)
	var/projected_before_pruning = scene.view.projected_entries
	var/deadline = world.time + 10 SECONDS
	while(scene.view.shown_addresses[first_address] && scene.view.projection && world.time < deadline)
		scene.step_map(1)
	TEST_ASSERT(!scene.view.shown_addresses[first_address], "An old marker must disappear during bounded pruning, before the new graph finishes")
	TEST_ASSERT_NOTNULL(scene.view.projection, "Removing the first marker must leave the remaining discovery work resumable")
	TEST_ASSERT_EQUAL(scene.view.projected_entries, projected_before_pruning, "Revocations must publish before replacement-node discovery begins")
	var/list/wire = scene.view.encode_wire(scene.view.snapshot, session)
	TEST_ASSERT(!wire["full"], "Reactive deletion must use the retained journal instead of replacing the full graph")
	var/list/removed = wire["removed_nodes"]
	TEST_ASSERT(first_address in removed, "The progressive wire delta must explicitly revoke the deleted marker")
	data = scene.settle_map()
	TEST_ASSERT_NOTNULL(data, "A projection with deleted first/last leaves must finish rather than loop on a stale final slot")
	TEST_ASSERT(!netrun_map_has_node(data, first_address) && !netrun_map_has_node(data, last_address), "Both deleted leaves must disappear reactively")
	var/list/map = data["map"]
	var/list/nodes = map["nodes"]
	var/list/edges = map["edges"]
	TEST_ASSERT_EQUAL(length(nodes), length(scene.view.shown_addresses), "Every shown marker must have exactly one dense node slot")
	TEST_ASSERT_EQUAL(length(edges), length(scene.view.edge_indexes), "Every cable must have exactly one dense edge slot")
	for(var/index in 1 to length(nodes))
		var/list/entry = nodes[index]
		TEST_ASSERT_EQUAL(scene.view.node_indexes[entry["address"]], index, "Swap deletion must update the surviving marker's slot")
	for(var/index in 1 to length(edges))
		var/list/entry = edges[index]
		TEST_ASSERT_EQUAL(scene.view.edge_indexes[entry["id"]], index, "Swap deletion must update the surviving cable's slot")
		TEST_ASSERT(scene.view.shown_addresses[entry["from"]] && scene.view.shown_addresses[entry["to"]], "A published cable must never reference a removed marker")
		var/list/from_incident = scene.view.incident_edges[entry["from"]]
		var/list/to_incident = scene.view.incident_edges[entry["to"]]
		TEST_ASSERT((index in from_incident) && (index in to_incident), "Both endpoint indexes must retain the cable's current slot")

/// An unfinished route solve is private and must not be projected as a completed graph.
/datum/unit_test/netrun_async_map_pending_routes/Run()
	var/datum/netrun_async_map_scene/scene = allocate(/datum/netrun_async_map_scene, run_loc_floor_bottom_left)
	scene.console.hold_routes = TRUE
	var/list/data = scene.console.ui_data(null)
	TEST_ASSERT_EQUAL(length(data["map"]["nodes"]), 0, "A pending route solve must open on an empty safe map")
	TEST_ASSERT_NOTNULL(scene.view.projection, "Map discovery must remain queued while routes are pending")
	scene.step_map(128)
	TEST_ASSERT(scene.console.ui_routes_pending, "The route-pending state must survive a deferred map slice")
	TEST_ASSERT_EQUAL(scene.view.projected_entries, 0, "A provisional source-only route tree must never be serialized as completed discovery")
	TEST_ASSERT_EQUAL(length(scene.view.snapshot["nodes"]), 0, "Pending routes must not expose new map markers")
	TEST_ASSERT_NULL(scene.console.ui_routes, "A paused slice must release its request-local provisional tree")
	scene.console.hold_routes = FALSE
	scene.warm_routes()
	data = scene.settle_map()
	TEST_ASSERT_NOTNULL(data, "Discovery must resume after a complete route tree becomes available")
	TEST_ASSERT(netrun_map_has_node(data, scene.engineering_target.address), "Resumed discovery must publish the real reachable LAN")

/// Access events can delete a projection; they must be drained before entering its step().
/datum/unit_test/netrun_async_map_firewall_cancel/Run()
	var/datum/netrun_async_map_scene/scene = allocate(/datum/netrun_async_map_scene, run_loc_floor_bottom_left)
	scene.console.ui_data(null)
	TEST_ASSERT_NOTNULL(scene.view.projection, "The fixture must have an active projection to cancel")
	scene.console.access_session.node_access[scene.engineering_target.address] = NETRUN_ACCESS_ROOT
	scene.engineering_target.raise_firewall()
	TEST_ASSERT(length(scene.console.access_session.pending_firewalls), "A native firewall signal must queue a real access event")
	SSnetrun.get_task_scheduler().cancel("map_projection", scene.view)
	TEST_ASSERT(scene.view.advance_projection(16), "A firewall-cancelled projection must terminate its continuation safely")
	TEST_ASSERT_NULL(scene.view.projection, "The cancelled job must not enter a later discovery operation")
	TEST_ASSERT_EQUAL(length(scene.console.access_session.pending_firewalls), 0, "The worker must drain queued firewall events before reading node permissions")
	TEST_ASSERT_NULL(scene.console.access_session.node_access[scene.engineering_target.address], "Firewall revocation must remain effective after cancelling discovery")
	TEST_ASSERT_NULL(scene.console.ui_routes, "Early event cancellation must leave no borrowed routes on the live console")
	var/list/data = scene.settle_map()
	TEST_ASSERT_NOTNULL(data, "A fresh projection must recover after the cancelled firewall generation")

/// A stale worker cannot publish its old LAN after a same-address source transition.
/datum/unit_test/netrun_async_map_source_change/Run()
	var/datum/netrun_async_map_scene/scene = allocate(/datum/netrun_async_map_scene, run_loc_floor_bottom_left)
	scene.console.ui_data(null)
	scene.step_map(2)
	var/datum/netrun_map_projection/old_job = scene.view.projection
	TEST_ASSERT_NOTNULL(old_job, "A small slice must leave its original source projection unfinished")
	scene.source.forceMove(scene.medical_destination)
	scene.source_node.join_network()
	scene.warm_routes()
	var/list/data = scene.console.ui_data(null)
	TEST_ASSERT(QDELETED(old_job), "Changing the source LAN must cancel the unfinished old generation")
	TEST_ASSERT_EQUAL(length(data["map"]["nodes"]), 0, "The replacement generation must start from a safe baseline")
	data = scene.settle_map()
	TEST_ASSERT_NOTNULL(data, "Discovery must finish for the replacement source context")
	TEST_ASSERT(!netrun_map_has_node(data, scene.engineering_target.address), "The cancelled generation must never reintroduce the old private endpoint")
	TEST_ASSERT(netrun_map_has_node(data, scene.medical_target.address), "The new generation must use the source's current home LAN")

/// Hidden/closed maps release both queued and deferred continuations immediately.
/datum/unit_test/netrun_async_map_suspend/Run()
	var/datum/netrun_async_map_scene/scene = allocate(/datum/netrun_async_map_scene, run_loc_floor_bottom_left)
	scene.console.ui_data(null)
	var/key = "map_projection:[REF(scene.view)]"
	TEST_ASSERT_NOTNULL(SSnetrun.get_task_scheduler().by_key[key], "Opening a map must queue its own worker task")
	scene.view.suspend()
	TEST_ASSERT_NULL(scene.view.projection, "Suspending a map must release its unfinished discovery state")
	TEST_ASSERT_NULL(SSnetrun.get_task_scheduler().by_key[key], "Suspending a map must unlink its queued task")
	TEST_ASSERT_NULL(SSnetrun.get_task_scheduler().deferred[key], "Suspending a map must cancel its deferred retry")
	sleep(2 * world.tick_lag)
	TEST_ASSERT(scene.view.advance_projection(128), "A stale callback for a suspended map must finish without doing work")
	TEST_ASSERT(!scene.view.subscribed, "A stale callback must not resubscribe a hidden map")
	TEST_ASSERT_EQUAL(length(scene.view.snapshot["nodes"]), 0, "A suspended initial map must not discover markers in the background")
