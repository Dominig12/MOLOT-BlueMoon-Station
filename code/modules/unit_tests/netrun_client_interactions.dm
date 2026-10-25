/// Real implanted organs and APC routes exercise admission independently of the map widget.
/datum/netrun_client_scene
	parent_type = /datum/netrun_route_scene
	var/mob/living/carbon/human/user
	var/obj/item/organ/cyberimp/brain/netlink/implant
	var/obj/machinery/computer/netrun_terminal/target
	var/obj/machinery/power/apc/apc
	var/datum/component/netrun_node/target_node
	var/turf/far_spot

/datum/netrun_client_scene/New(turf/origin)
	..(origin.z)
	var/area/room = room(/area/engineering/netrun_route_test)
	for(var/turf/spot as anything in block(origin, locate(origin.x + 4, origin.y + 2, origin.z)))
		take(spot, room)
	far_spot = locate(origin.x + 4, origin.y, origin.z)
	apc = machine(/obj/machinery/power/apc, get_step(origin, NORTH))
	target = machine(/obj/machinery/computer/netrun_terminal, get_step(origin, EAST))
	target_node = target.GetComponent(/datum/component/netrun_node)
	user = new(origin)
	owned += user
	user.mind_initialize()
	implant = new(origin)
	owned += implant
	implant.Insert(user)
	SSnetrun.ensure_topology()

/datum/netrun_client_scene/Destroy()
	if(!QDELETED(implant))
		implant.console.disconnect_client(TRUE)
	return ..()

/datum/netrun_client_scene/proc/authorize()
	implant.console.access_session.node_access[target_node.address] = NETRUN_ACCESS_USER
	implant.console.access_session.network_access[target_node.network.id] = NETRUN_ACCESS_GUEST

/datum/unit_test/netrun_implant_entry_selection/Run()
	var/datum/netrun_client_scene/scene = allocate(/datum/netrun_client_scene, run_loc_floor_bottom_left)
	var/datum/netrun_console/implant/console = scene.implant.console
	TEST_ASSERT_EQUAL(console.operator, scene.user, "Installing the implant must bind the owner before the first UI poll")
	TEST_ASSERT(console.available_to(scene.user), "The installed implant must admit its conscious owner")
	TEST_ASSERT(!console.select_entry(scene.target_node, scene.user), "Selecting an entry must not grant rights to a closed LAN")
	scene.authorize()
	var/list/choices = console.entry_choices()
	TEST_ASSERT_EQUAL(choices["[scene.target_node.get_name()] — [scene.target_node.address]"], scene.target_node, "The chooser must include reachable nodes with acquired user access")
	TEST_ASSERT(console.select_entry(scene.target_node, scene.user), "A reachable authorized node must be selectable outside the map workspace")
	TEST_ASSERT_EQUAL(console.selected_node(), scene.target_node, "The chooser must update the node used by the native dive action")
	TEST_ASSERT_EQUAL(console.workspace_view, "map", "Choosing an entry must reveal its card and dive action")
	TEST_ASSERT_NULL(console.dive_denial(scene.target_node), "A conscious mind with a valid route must be allowed to dive")
	var/list/data = console.ui_data(scene.user)
	var/list/selected = data["selected"]
	var/list/actions = selected?["interactions"]
	var/has_dive = FALSE
	for(var/list/entry as anything in actions)
		if(entry["id"] == "dive" && entry["enabled"])
			has_dive = TRUE
	TEST_ASSERT(has_dive, "The selected-node wire payload must expose the enabled dive action")

/datum/unit_test/netrun_implant_direct_connection/Run()
	var/datum/netrun_client_scene/scene = allocate(/datum/netrun_client_scene, run_loc_floor_bottom_left)
	var/datum/netrun_console/implant/console = scene.implant.console
	TEST_ASSERT_NULL(console.connection.connect_denial(scene.target_node, scene.user), "An adjacent service port must be available before LAN authorization")
	var/list/choices = console.local_connection_choices(scene.user)
	TEST_ASSERT_EQUAL(choices["[scene.target_node.get_name()] — [scene.target_node.address]"], scene.target_node, "A closed LAN must still expose the physically reachable service port in the chooser")
	TEST_ASSERT(console.connection.connect_node(scene.target_node, scene.user), "The implanted lead must establish a local physical connection")
	TEST_ASSERT_EQUAL(console.route_source(), scene.target_node, "Physical entry must use the selected machine rather than a fallback APC")
	TEST_ASSERT_EQUAL(console.selected_node(), scene.target_node, "Connecting must select the actual endpoint")
	TEST_ASSERT_EQUAL(console.node_level(scene.target_node), NETRUN_ACCESS_GUEST, "Plugging in must not create user or root machine privileges")
	scene.user.forceMove(scene.far_spot)
	TEST_ASSERT(!console.jack_valid(), "A short lead cannot remain attached after walking away")
	console.process_tick(1)
	TEST_ASSERT_NULL(console.connection.jack, "The physical disconnect must be processed without another UI click")
	TEST_ASSERT(!console.connection.connect_node(scene.target_node, scene.user), "A stale card must not reconnect to a distant port")

/datum/unit_test/netrun_implant_owner_admission/Run()
	var/datum/netrun_client_scene/scene = allocate(/datum/netrun_client_scene, run_loc_floor_bottom_left)
	var/mob/living/carbon/human/outsider = allocate(/mob/living/carbon/human)
	var/datum/netrun_console/implant/console = scene.implant.console
	scene.authorize()
	TEST_ASSERT_EQUAL(console.ui_status(outsider, GLOB.always_state), UI_CLOSE, "Conscious-only UI state must not expose an implant to another mob")
	TEST_ASSERT_EQUAL(length(console.ui_data(outsider)), 0, "A foreign UI read must not serialize the owner's network")
	TEST_ASSERT_EQUAL(length(console.ui_static_data(outsider)), 0, "A static UI read must not change implant identity")
	TEST_ASSERT_EQUAL(console.operator, scene.user, "Rejected UI access must preserve the actual operator")
	TEST_ASSERT(!console.select_entry(scene.target_node, outsider), "A forged entry selector must reject another character")
	TEST_ASSERT(!scene.implant.complete_dive(scene.target_node, outsider), "The final dive admission must reject a changed owner")
	scene.user.SetUnconscious(10 SECONDS)
	TEST_ASSERT(!console.available_to(scene.user), "An unconscious body must not operate its implant")
	TEST_ASSERT(!console.can_route(scene.target_node), "Queued actions must lose the implant route when the owner loses consciousness")
	TEST_ASSERT(console.dive_denial(scene.target_node), "The native dive action must observe the same consciousness restriction")

/datum/unit_test/netrun_implant_dive_lifecycle/Run()
	var/datum/netrun_client_scene/scene = allocate(/datum/netrun_client_scene, run_loc_floor_bottom_left)
	var/datum/netrun_console/implant/console = scene.implant.console
	scene.authorize()
	console.select_entry(scene.target_node, scene.user)
	var/datum/mind/mind = scene.user.mind
	TEST_ASSERT(scene.implant.complete_dive(scene.target_node, scene.user), "The final authorized admission must create a real resident process")
	var/mob/camera/netrun_entity/entity = console.dive_ref?.resolve()
	TEST_ASSERT_NOTNULL(entity, "The implant must track its actual resident rather than only a selected address")
	TEST_ASSERT_EQUAL(mind.current, entity, "The same mind must transfer into the selected network node")
	TEST_ASSERT_EQUAL(entity.host_node, scene.target_node, "The resident must start at the selected endpoint")
	TEST_ASSERT_EQUAL(entity.dive_link.body, scene.user, "The dive must retain its original body link")
	TEST_ASSERT_EQUAL(entity.console.access_session.node_access[scene.target_node.address], NETRUN_ACCESS_USER, "Acquired node rights must survive the dive")
	entity.console.access_session.node_access[scene.target_node.address] = NETRUN_ACCESS_ROOT
	TEST_ASSERT_EQUAL(console.access_session.node_access[scene.target_node.address], NETRUN_ACCESS_USER, "Resident and implant grants must not share mutable lists")
	scene.implant.Remove()
	TEST_ASSERT(QDELETED(entity), "Removing the implant must end its active dive")
	TEST_ASSERT_EQUAL(mind.current, scene.user, "Removing the implant must return the mind to its original body")
	TEST_ASSERT_NULL(console.operator, "An extracted implant must release its former operator")
	TEST_ASSERT_NULL(scene.implant.interface, "Extraction must also detach the implant's neural display source")
	TEST_ASSERT_EQUAL(length(console.access_session.node_access), 0, "An extracted implant must not retain acquired session access")

/datum/unit_test/netrun_implant_dive_revalidation/Run()
	var/datum/netrun_client_scene/scene = allocate(/datum/netrun_client_scene, run_loc_floor_bottom_left)
	var/datum/netrun_console/implant/console = scene.implant.console
	scene.authorize()
	console.diving = TRUE
	TEST_ASSERT(console.dive_denial(scene.target_node), "A second click must not start a simultaneous dive")
	console.diving = FALSE
	console.access_session.revoke_all()
	TEST_ASSERT(!scene.implant.complete_dive(scene.target_node, scene.user), "Revoked permissions during preparation must cancel the dive")
	scene.authorize()
	scene.apc.set_machine_stat(BROKEN)
	TEST_ASSERT(!scene.implant.complete_dive(scene.target_node, scene.user), "A route failure during preparation must cancel the dive")
	TEST_ASSERT_EQUAL(scene.user.mind.current, scene.user, "Failed preparation must leave the original mind in its body")

/datum/unit_test/netrun_implant_wired_dive/Run()
	var/datum/netrun_client_scene/scene = allocate(/datum/netrun_client_scene, run_loc_floor_bottom_left)
	var/datum/netrun_console/implant/console = scene.implant.console
	scene.authorize()
	TEST_ASSERT(console.connection.connect_node(scene.target_node, scene.user), "A wired dive must begin at a reachable physical port")
	TEST_ASSERT(scene.implant.complete_dive(scene.target_node, scene.user), "An authorized physical entry must admit the resident")
	var/mob/camera/netrun_entity/entity = console.dive_ref?.resolve()
	console.process_tick(1)
	TEST_ASSERT_EQUAL(console.connection.jack, scene.target_node, "The dive's normal unconscious body must not immediately unplug its own lead")
	TEST_ASSERT(entity.dive_link.link_intact(), "A plugged-in dive must retain its physical entrance")
	scene.target_node.offline_until = world.time + 10 SECONDS
	TEST_ASSERT(!entity.dive_link.link_intact(), "An offline entrance must sever the body link even while the resident occupies that same endpoint")
	scene.target_node.offline_until = 0
	TEST_ASSERT(entity.dive_link.link_intact(), "A recovered entrance must restore the still-attached return link")
	console.set_jack(null)
	TEST_ASSERT(!entity.dive_link.link_intact(), "Unplugging the original service lead must sever the resident's body link")
	entity.return_to_body()
	TEST_ASSERT_EQUAL(scene.user.mind.current, scene.user, "Manual return must still work after losing a physical entrance")

/datum/unit_test/netrun_implant_self_entry/Run()
	var/datum/netrun_client_scene/scene = allocate(/datum/netrun_client_scene, run_loc_floor_bottom_left)
	var/datum/netrun_console/implant/console = scene.implant.console
	var/datum/component/netrun_node/entry = scene.implant.GetComponent(/datum/component/netrun_node)
	TEST_ASSERT_EQUAL(length(console.access_session.node_access), 0, "This dive must begin with native ownership rather than acquired grants")
	TEST_ASSERT(scene.implant.complete_dive(entry, scene.user), "The wearer's own neural endpoint must provide an initial network entrance")
	var/mob/camera/netrun_entity/entity = console.dive_ref?.resolve()
	TEST_ASSERT_EQUAL(entity.console.node_level(entry), NETRUN_ACCESS_USER, "Transferring an empty acquired-grant list must preserve the resident's initial USER grant")
	entity.return_to_body()

/datum/unit_test/netrun_implant_wearer_movement/Run()
	var/datum/netrun_client_scene/scene = allocate(/datum/netrun_client_scene, run_loc_floor_bottom_left)
	var/datum/component/netrun_node/node = scene.implant.GetComponent(/datum/component/netrun_node)
	TEST_ASSERT_NULL(scene.implant.loc, "The real installed organ must remain in native nullspace")
	TEST_ASSERT_EQUAL(node.physical_turf(), get_turf(scene.user), "An implanted endpoint must resolve its wearer rather than nullspace")
	TEST_ASSERT_EQUAL(node.bound_apc, scene.apc.GetComponent(/datum/component/netrun_node), "The installed endpoint must join its wearer's physical LAN")
	var/area/destination = scene.room(/area/medical/netrun_route_test)
	scene.take(scene.far_spot, destination)
	var/turf/remote_apc_spot = scene.take(get_step(scene.far_spot, NORTH), destination)
	var/obj/machinery/power/apc/remote_apc = scene.machine(/obj/machinery/power/apc, remote_apc_spot)
	SSnetrun.ensure_topology()
	scene.user.forceMove(scene.far_spot)
	TEST_ASSERT_EQUAL(node.physical_turf(), scene.far_spot, "The implant must follow its wearer without moving the native organ")
	TEST_ASSERT_EQUAL(node.bound_apc, remote_apc.GetComponent(/datum/component/netrun_node), "The wearer's movement signal must rebind the endpoint before another UI poll")
	var/datum/netrun_console/implant/console = scene.implant.console
	console.workspace_view = "map"
	console.map_view.selected_address = node.address
	var/list/data = console.ui_data(scene.user)
	var/list/selected = data["selected"]
	TEST_ASSERT_EQUAL(selected?["x"], scene.far_spot.x, "The selected card must publish actual wearer coordinates")
	TEST_ASSERT_EQUAL(selected?["y"], scene.far_spot.y, "The reactive map must not place internal organs at coordinate zero")
	scene.implant.Remove()
	TEST_ASSERT_NULL(node.physical_carrier, "Extraction must unsubscribe the previous wearer from endpoint movement")

/datum/unit_test/netrun_client_lead_ownership/Run()
	var/datum/netrun_client_scene/scene = allocate(/datum/netrun_client_scene, run_loc_floor_bottom_left)
	var/obj/item/netrun_deck/deck = allocate(/obj/item/netrun_deck)
	deck.forceMove(get_turf(scene.user))
	deck.console.operator = scene.user
	TEST_ASSERT(!deck.console.connection.connect_node(scene.target_node, scene.user), "A floor deck must not lend its lead to a previous UI operator")
	deck.forceMove(scene.user)
	TEST_ASSERT(deck.console.connection.connect_node(scene.target_node, scene.user), "A carried deck must share the same physical connection checks as the implant")
	deck.console.set_jack(null)
	deck.console.intrusion.lockout_until = world.time + 10 SECONDS
	TEST_ASSERT(!deck.console.connection.connect_node(scene.target_node, scene.user), "Lockout must also forbid connection through a stale chooser")

/datum/unit_test/netrun_client_device_shortcuts/Run()
	var/datum/netrun_client_scene/scene = allocate(/datum/netrun_client_scene, run_loc_floor_bottom_left)
	var/datum/netrun_console/implant/console = scene.implant.console
	var/obj/machinery/door/airlock/door = scene.machine(/obj/machinery/door/airlock, scene.far_spot)
	var/datum/component/netrun_node/door_node = door.GetComponent(/datum/component/netrun_node)
	SSnetrun.ensure_topology()
	TEST_ASSERT(!console.node_interact(door_node, "manage", scene.user), "An arbitrary device shortcut must not reveal a closed machine")
	console.access_session.network_access[door_node.network.id] = NETRUN_ACCESS_GUEST
	console.access_session.node_access[door_node.address] = NETRUN_ACCESS_USER
	TEST_ASSERT(console.node_interact(door_node, "manage", scene.user), "An authorized device shortcut must open its existing network provider UI")
	TEST_ASSERT_EQUAL(console.remote_session.active_window, door_node.address, "The shortcut must select the intended native device")
	TEST_ASSERT_EQUAL(console.workspace_view, "pinned", "Device management must navigate to its control workspace")
	TEST_ASSERT(!console.node_interact(door_node, "invented_action", scene.user), "An unadvertised shortcut must never dispatch an arbitrary action")
