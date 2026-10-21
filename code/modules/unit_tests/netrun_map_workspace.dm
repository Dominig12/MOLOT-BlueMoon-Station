/// Dedicated pages do not erase active jobs, pinned nodes or local file selection.
/datum/unit_test/netrun_workspace_pages/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/area/room = scene.room(/area/netrun_route_test)
	scene.take(origin, room)
	var/turf/apc_spot = scene.take(get_step(origin, NORTH), room)
	scene.machine(/obj/machinery/power/apc, apc_spot)
	var/obj/machinery/computer/netrun_terminal/terminal = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	var/datum/component/netrun_node/node = terminal.GetComponent(/datum/component/netrun_node)
	var/datum/netrun_console/console = terminal.console
	SSnetrun.ensure_topology()
	console.map_view.selected_address = node.address
	TEST_ASSERT(console.create_text_file("draft.txt", "persistent file"), "The workspace needs a real selected local file")
	var/uid = console.inventory.selected_file_uid
	var/list/data = console.ui_data(null)
	TEST_ASSERT_EQUAL(data["workspace_view"], "terminal", "A new session must start on the dedicated terminal page")
	TEST_ASSERT_NULL(data["map"], "A hidden map must not serialize a full graph")
	TEST_ASSERT(console.start_breach("node", node.address), "The fixture must run a real breach")
	TEST_ASSERT_EQUAL(console.workspace_view, "breach", "A new breach must open its own workspace")
	var/datum/netrun_breach/job = console.intrusion.breach
	data = console.ui_data(null)
	var/list/file = data["file"]
	TEST_ASSERT_EQUAL(file["uid"], uid, "A puzzle must not discard the selected file payload")
	console.workspace_view = "map"
	data = console.ui_data(null)
	TEST_ASSERT_NOTNULL(data["map"], "The map page must be available while a breach is running")
	TEST_ASSERT_NOTNULL(data["breach"], "Browsing the map must preserve the active breach")
	TEST_ASSERT_EQUAL(console.intrusion.breach, job, "Page navigation must never replace the job")
	TEST_ASSERT(console.open_window(node.address), "A permitted node must be pinnable")
	TEST_ASSERT_EQUAL(console.workspace_view, "pinned", "Pinning a node must open the dedicated pinned workspace")
	data = console.ui_data(null)
	TEST_ASSERT_NOTNULL(data["window"], "Pinned nodes must remain operable during a breach")
	TEST_ASSERT_NULL(data["map"], "Pinned workspace must not contain the hidden map")
	console.workspace_view = "files"
	data = console.ui_data(null)
	file = data["file"]
	TEST_ASSERT_EQUAL(file["uid"], uid, "The file workspace must retain the selected local file")
	TEST_ASSERT_NOTNULL(data["selected"], "File upload controls need the selected remote node's permissions")
	TEST_ASSERT_EQUAL(console.remote_session.active_window, node.address, "Leaving the pinned page must preserve its active node")

/// Highlighting an APC transmits actual area tiles rather than its bounding rectangle.
/datum/unit_test/netrun_apc_geographic_area/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/area/room = scene.room(/area/netrun_route_test)
	var/list/tiles = list(origin, get_step(origin, EAST), get_step(origin, NORTH), locate(origin.x + 3, origin.y + 1, origin.z))
	for(var/turf/spot as anything in tiles)
		scene.take(spot, room)
	var/obj/machinery/power/apc/apc = scene.machine(/obj/machinery/power/apc, origin)
	var/obj/machinery/computer/netrun_terminal/terminal = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	var/datum/component/netrun_node/apc_node = apc.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/terminal_node = terminal.GetComponent(/datum/component/netrun_node)
	SSnetrun.ensure_topology()
	terminal.console.workspace_view = "map"
	terminal.console.map_view.selected_address = apc_node.address
	var/list/data = terminal.console.ui_data(null)
	var/list/map = data["map"]
	var/list/zones = map["apc_zones"]
	TEST_ASSERT_EQUAL(length(zones), 1, "Only the selected APC area should be highlighted")
	var/list/zone = zones[1]
	TEST_ASSERT_EQUAL(zone["address"], apc_node.address, "The highlight must identify the selected physical APC")
	var/list/runs = zone["runs"]
	var/list/reconstructed = list()
	for(var/list/run as anything in runs)
		for(var/x = run["x"], x < run["x"] + run["width"], x++)
			reconstructed["[x],[run["y"]]"] = TRUE
	TEST_ASSERT_EQUAL(length(reconstructed), length(tiles), "Runs must preserve holes and disconnected native area tiles")
	for(var/turf/spot as anything in tiles)
		TEST_ASSERT(reconstructed["[spot.x],[spot.y]"], "Every native APC area tile must appear in its shape")
	TEST_ASSERT(!reconstructed["[origin.x + 2],[origin.y]"], "The bounding box's missing tiles must not be filled")
	var/list/entries = map["nodes"]
	for(var/list/entry as anything in entries)
		if(entry["address"] != terminal_node.address)
			continue
		TEST_ASSERT_EQUAL(entry["x"], origin.x, "Map X must match physical turf X")
		TEST_ASSERT_EQUAL(entry["y"], origin.y, "Map Y must match physical turf Y")
		TEST_ASSERT_EQUAL(entry["apc"], apc_node.address, "The endpoint must publish its actual APC binding")

/// Cached ID credentials stay a list while pages serialize their independent payloads.
/datum/unit_test/netrun_cached_id_list/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	console.access_cache = list(ACCESS_MEDICAL, ACCESS_NETWORK)
	TEST_ASSERT(islist(console.user_access()), "A cached access read must return its ID list")
	TEST_ASSERT(ACCESS_MEDICAL in console.user_access(), "Cached ID access must preserve every access code")
	TEST_ASSERT(!(ACCESS_MEDICAL in console.user_access(TRUE)), "A fresh access read must not reuse a cached operator snapshot")

/// Sector browsing filters physical nodes without moving the source or fabricating gateway nodes.
/datum/unit_test/netrun_map_sector_browsing/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/area/local_room = scene.room(/area/netrun_route_test)
	var/area/remote_room = scene.room(/area/netrun_route_test)
	var/list/levels = multiz_gravity_test_levels()
	scene.mark_station(levels[1])
	scene.take(origin, local_room)
	var/turf/apc_spot = scene.take(get_step(origin, NORTH), local_room)
	var/turf/relay_spot = scene.take(get_step(apc_spot, NORTH), local_room)
	var/turf/remote_apc_spot = scene.take(locate(81, 80, levels[1]), remote_room, TRUE)
	var/turf/remote_relay_spot = scene.take(locate(82, 80, levels[1]), remote_room, TRUE)
	scene.machine(/obj/machinery/power/apc, apc_spot)
	scene.machine(/obj/machinery/power/apc, remote_apc_spot)
	var/obj/machinery/computer/netrun_terminal/source = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	var/obj/machinery/ntnet_relay/local_relay = scene.machine(/obj/machinery/ntnet_relay, relay_spot)
	var/obj/machinery/ntnet_relay/remote_relay = scene.machine(/obj/machinery/ntnet_relay, remote_relay_spot)
	var/datum/component/netrun_node/local_node = local_relay.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/remote_node = remote_relay.GetComponent(/datum/component/netrun_node)
	SSnetworks.station_network.setting_disabled = FALSE
	SSnetrun.ensure_topology()
	source.console.workspace_view = "map"
	source.console.map_view.selected_address = local_node.address
	var/list/data = source.console.ui_data(null)
	var/list/map = data["map"]
	TEST_ASSERT(netrun_map_has_node(data, local_node.address), "The initial map must include the current sector's relay")
	TEST_ASSERT(!netrun_map_has_node(data, remote_node.address), "A remote-sector relay must not be drawn among local physical nodes")
	var/list/destinations = map["relay_destinations"]
	var/found = FALSE
	for(var/list/destination as anything in destinations)
		if(destination["to"] == remote_node.address)
			found = TRUE
	TEST_ASSERT(found, "The selected relay must expose its actual remote gateway destination")
	TEST_ASSERT(source.console.map_view.select_sector(remote_node.binding_sector, remote_relay_spot.z), "A disclosed destination sector must be browsable")
	data = source.console.ui_data(null)
	map = data["map"]
	TEST_ASSERT(netrun_map_has_node(data, remote_node.address), "Switching sectors must display remote physical coordinates")
	TEST_ASSERT(!netrun_map_has_node(data, local_node.address), "Sector switching must unload nodes from the other sector")
	TEST_ASSERT_EQUAL(get_turf(source), origin, "Browsing a sector must not teleport the physical client")
	TEST_ASSERT(!source.console.map_view.select_sector("sector:forged", 999), "An undisclosed or forged sector must not be accepted")
	source.console.map_view.follow_source()
	data = source.console.ui_data(null)
	TEST_ASSERT(netrun_map_has_node(data, local_node.address), "Return to source must restore the source sector")
