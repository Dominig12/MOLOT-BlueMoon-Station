/// Replacing an autopilot route during cooldown must cancel the old callback and wait.
/datum/unit_test/netrun_navigation_replace_and_cancel/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = netrun_connected_test_area()
	var/obj/machinery/computer/netrun_terminal/source = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	var/obj/machinery/computer/netrun_terminal/target = scene.machine(/obj/machinery/computer/netrun_terminal, get_step(origin, EAST))
	var/datum/component/netrun_node/source_node = source.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/target_node = target.GetComponent(/datum/component/netrun_node)
	var/mob/camera/netrun_entity/entity = new(origin, source_node)
	scene.owned.Insert(1, entity)
	entity.console.operator = entity
	TEST_ASSERT(entity.console.store_file(new /datum/netrun_file("route.key", NETRUN_FILE_KEY, source_node.network.passcode, 1, source_node.network.id)), "Traversal key must fit")
	entity.next_hop = world.time + 5 SECONDS
	TEST_ASSERT(entity.travel_to(target_node), "Starting a route during cooldown should succeed")
	var/datum/netrun_entity_navigation/navigation = entity.navigation
	TEST_ASSERT(navigation.is_active() && navigation.timer, "The route must wait on a cancellable timer")
	TEST_ASSERT_EQUAL(entity.host_node, source_node, "Cooldown must still prevent movement")
	var/old_generation = navigation.generation
	var/old_timer = navigation.timer
	TEST_ASSERT(entity.travel_to(target_node), "Replacing a waiting route should succeed")
	TEST_ASSERT_NOTEQUAL(navigation.timer, old_timer, "The old route timer must be replaced")
	var/current_timer = navigation.timer
	navigation.advance_route(old_generation)
	TEST_ASSERT_EQUAL(navigation.timer, current_timer, "An already-dispatched stale callback must not modify the new route")
	TEST_ASSERT_EQUAL(entity.host_node, source_node, "A stale callback must never move the entity")
	entity.next_hop = world.time
	TEST_ASSERT(entity.hop(source_node.bound_apc), "A manual hop should still work")
	TEST_ASSERT(!navigation.is_active() && !navigation.timer, "Manual movement must cancel autopilot and its timer")

/// Each step revalidates the live link; a deleted or offline next hop cancels the route.
/datum/unit_test/netrun_navigation_revalidates_next_hop/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = netrun_connected_test_area()
	var/obj/machinery/computer/netrun_terminal/source = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	var/obj/machinery/computer/netrun_terminal/target = scene.machine(/obj/machinery/computer/netrun_terminal, get_step(origin, EAST))
	var/datum/component/netrun_node/source_node = source.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/target_node = target.GetComponent(/datum/component/netrun_node)
	var/mob/camera/netrun_entity/entity = new(origin, source_node)
	scene.owned.Insert(1, entity)
	entity.console.operator = entity
	TEST_ASSERT(entity.console.store_file(new /datum/netrun_file("route.key", NETRUN_FILE_KEY, source_node.network.passcode, 1, source_node.network.id)), "Traversal key must fit")
	TEST_ASSERT(entity.travel_to(target_node), "A valid route must start")
	var/datum/netrun_entity_navigation/navigation = entity.navigation
	TEST_ASSERT(navigation.is_active() && navigation.timer, "The second hop must wait for cooldown")
	var/datum/component/netrun_node/current = entity.host_node
	target.set_machine_stat(BROKEN)
	entity.next_hop = world.time
	// Simulate the actual scheduled callback without leaving another timer behind.
	deltimer(navigation.timer)
	navigation.advance_route(navigation.generation)
	TEST_ASSERT_EQUAL(entity.host_node, current, "An offline destination must not be entered")
	TEST_ASSERT(!navigation.is_active() && !navigation.timer, "A failed route must release its timer and queue")
	TEST_ASSERT_NULL(navigation.ui_payload(), "Finished/cancelled navigation must clear the HUD")

/// A station can have hundreds of endpoints; discover a permitted destination after 200 leaves.
/datum/unit_test/netrun_navigation_large_network/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = netrun_connected_test_area()
	var/obj/machinery/computer/netrun_terminal/source = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	var/datum/component/netrun_node/source_node = source.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/target_node
	for(var/i in 1 to 205)
		var/obj/item/endpoint = new(origin)
		scene.owned += endpoint
		target_node = endpoint.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
	var/mob/camera/netrun_entity/entity = new(origin, source_node)
	scene.owned.Insert(1, entity)
	entity.console.operator = entity
	TEST_ASSERT(entity.console.store_file(new /datum/netrun_file("route.key", NETRUN_FILE_KEY, source_node.network.passcode, 1, source_node.network.id)), "Traversal key must fit")
	var/list/path = entity.enterable_path(target_node)
	TEST_ASSERT_EQUAL(length(path), 2, "The full authorized graph must be searched without the former 200-node cutoff")
	TEST_ASSERT_EQUAL(path[2], target_node.address, "The path must end at the requested endpoint")

/// A removed entity must not leave its navigation controller/timer alive.
/datum/unit_test/netrun_navigation_teardown/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = netrun_connected_test_area()
	var/obj/machinery/computer/netrun_terminal/source = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	var/datum/component/netrun_node/source_node = source.GetComponent(/datum/component/netrun_node)
	var/mob/camera/netrun_entity/entity = new(origin, source_node)
	scene.owned.Insert(1, entity)
	entity.console.operator = entity
	TEST_ASSERT(entity.console.store_file(new /datum/netrun_file("route.key", NETRUN_FILE_KEY, source_node.network.passcode, 1, source_node.network.id)), "Traversal key must fit")
	entity.next_hop = world.time + 10 SECONDS
	TEST_ASSERT(entity.travel_to(source_node.bound_apc), "Navigation fixture must start")
	var/datum/netrun_entity_navigation/navigation = entity.navigation
	qdel(entity)
	TEST_ASSERT(QDELETED(navigation), "Entity teardown must delete its navigation controller")
	TEST_ASSERT_NULL(navigation.timer, "Navigation teardown must cancel the pending callback")

/// Extension subscriber replaces a route synchronously while arrival is announced.
/datum/netrun_navigation_redirect
	var/mob/camera/netrun_entity/entity
	var/datum/component/netrun_node/destination

/datum/netrun_navigation_redirect/New(mob/camera/netrun_entity/entity, datum/component/netrun_node/destination)
	src.entity = entity
	src.destination = destination
	RegisterSignal(entity, COMSIG_NETRUN_ENTITY_NODE_CHANGED, PROC_REF(on_arrival))

/datum/netrun_navigation_redirect/proc/on_arrival(datum/source, datum/component/netrun_node/old, datum/component/netrun_node/next)
	SIGNAL_HANDLER
	if(!next)
		return
	UnregisterSignal(entity, COMSIG_NETRUN_ENTITY_NODE_CHANGED)
	entity.navigation.start(destination)

/datum/netrun_navigation_redirect/Destroy()
	if(entity)
		UnregisterSignal(entity, COMSIG_NETRUN_ENTITY_NODE_CHANGED)
	entity = null
	destination = null
	return ..()

/datum/unit_test/netrun_navigation_arrival_reentrancy/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = netrun_connected_test_area()
	var/obj/machinery/computer/netrun_terminal/source = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	var/obj/machinery/computer/netrun_terminal/target = scene.machine(/obj/machinery/computer/netrun_terminal, get_step(origin, EAST))
	var/obj/machinery/computer/netrun_terminal/replacement = scene.machine(/obj/machinery/computer/netrun_terminal, get_step(origin, NORTH))
	var/datum/component/netrun_node/source_node = source.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/target_node = target.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/replacement_node = replacement.GetComponent(/datum/component/netrun_node)
	var/mob/camera/netrun_entity/entity = new(origin, source_node)
	scene.owned.Insert(1, entity)
	entity.console.operator = entity
	TEST_ASSERT(entity.console.store_file(new /datum/netrun_file("route.key", NETRUN_FILE_KEY, source_node.network.passcode, 1, source_node.network.id)), "Traversal key must fit")
	allocate(/datum/netrun_navigation_redirect, entity, replacement_node)
	TEST_ASSERT(entity.travel_to(target_node), "The first route must start")
	TEST_ASSERT_EQUAL(entity.navigation.destination, replacement_node.address, "An arrival extension may replace the current route")
	TEST_ASSERT_EQUAL(length(entity.navigation.queue), 1, "The old callback must not consume the new route's next hop")
	TEST_ASSERT(entity.navigation.timer, "The replacement route must retain its own cooldown timer")
/datum/unit_test/netrun_implant_entry_local_area/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_client_scene/scene = allocate(/datum/netrun_client_scene, origin)
	var/datum/netrun_console/implant/console = scene.implant.console
	var/area/local_room = get_base_area(scene.user)
	var/area/remote_room = scene.room(/area/engineering/netrun_route_test)
	scene.take(scene.far_spot, remote_room)
	scene.take(get_step(scene.far_spot, NORTH), remote_room)
	scene.machine(/obj/machinery/power/apc, get_step(scene.far_spot, NORTH))
	var/obj/machinery/computer/netrun_terminal/remote = scene.machine(/obj/machinery/computer/netrun_terminal, scene.far_spot)
	var/datum/component/netrun_node/remote_node = remote.GetComponent(/datum/component/netrun_node)
	SSnetrun.ensure_topology()
	scene.authorize()
	console.access_session.node_access[remote_node.address] = NETRUN_ACCESS_USER
	TEST_ASSERT_EQUAL(scene.target_node.network, remote_node.network, "The remote room must share the department LAN, otherwise this does not test the isolation boundary")
	TEST_ASSERT(console.can_route(remote_node), "The remote endpoint must remain reachable through the shared infrastructure")
	TEST_ASSERT(console.is_local_entry(scene.target_node, scene.user), "A node in the same room must be a local entrance")
	TEST_ASSERT(!console.is_local_entry(remote_node, scene.user), "A node in another room of the same LAN must not be a local entrance")
	var/list/choices = console.entry_choices()
	TEST_ASSERT_EQUAL(choices["[scene.target_node.get_name()] — [scene.target_node.address]"], scene.target_node, "An authorized local endpoint must be offered")
	TEST_ASSERT_NULL(choices["[remote_node.get_name()] — [remote_node.address]"], "A reachable remote room must not appear in the entry chooser")
	TEST_ASSERT(!console.select_entry(remote_node, scene.user), "A forged entry choice must reject the remote endpoint")
	TEST_ASSERT(console.dive_denial(remote_node, scene.user), "The direct dive action must reject the remote endpoint")
	TEST_ASSERT(console.select_entry(scene.target_node, scene.user), "The local endpoint must remain selectable")
	scene.user.forceMove(scene.far_spot)
	TEST_ASSERT(!console.is_local_entry(scene.target_node, scene.user), "Moving after selection must invalidate the former local entrance immediately")
	TEST_ASSERT(!scene.implant.complete_dive(scene.target_node, scene.user), "Final admission must revalidate the body's location after preparation")
	TEST_ASSERT_EQUAL(scene.user.mind.current, scene.user, "A denied entry must leave the mind in its body")
	scene.user.forceMove(origin)
	var/obj/item/storage/backpack/container = new(scene.user)
	scene.owned += container
	var/obj/item/nested = new(container)
	var/datum/component/netrun_node/nested_node = nested.AddComponent(/datum/component/netrun_node, NETRUN_NODE_IMPLANT)
	TEST_ASSERT(console.is_local_entry(nested_node, scene.user), "A node inside a worn container must follow the owner's physical position")
	var/area/subroom = scene.room(/area/engineering/netrun_route_test)
	local_room.sub_areas = list(subroom)
	subroom.base_area = local_room
	var/turf/subroom_spot = scene.take(locate(origin.x + 2, origin.y, origin.z), subroom)
	nested.forceMove(subroom_spot)
	TEST_ASSERT(console.is_local_entry(nested_node, scene.user), "Sub-areas of the same base area must remain local")
	nested.forceMove(scene.far_spot)
	TEST_ASSERT(!console.is_local_entry(nested_node, scene.user), "Moving the endpoint to another room must invalidate its stale selection")
	qdel(nested)
	scene.take(subroom_spot, local_room)
	scene.rooms -= subroom
	qdel(subroom)
	TEST_ASSERT_NULL(local_room.sub_areas, "Deleting a sub-area must unlink it from the base area without a runtime")

