/// A newly available second-level node must survive the delivered research snapshot.
/datum/unit_test/netrun_research_prerequisite_chain/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/machinery/rnd/server/server = scene.machine(/obj/machinery/rnd/server, scene.target_spot)
	var/obj/machinery/computer/rdconsole/console = scene.machine(/obj/machinery/computer/rdconsole, scene.source_spot)
	SEND_SIGNAL(console, COMSIG_ATOM_SET_TECHWEB, server.stored_research)
	server.base_mining_income = list()
	server.stored_research.next_income = list()
	server.stored_research.research_points = list(TECHWEB_POINT_TYPE_GENERIC = 10000)
	var/mob/living/carbon/human/user = allocate(/mob/living/carbon/human, scene.source_spot)
	console.request_research_snapshot()
	var/deadline = world.time + 3 SECONDS
	while(!console.netrun_research_cache && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT(console.netrun_research_cache?.available_nodes["datatheory"], "The initial delivered console must offer Data Theory")
	TEST_ASSERT(console.research_node("datatheory", user), "The first research request must enter the wire")
	deadline = world.time + 3 SECONDS
	while(!console.netrun_research_cache?.researched_nodes["datatheory"] && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT(console.netrun_research_cache?.available_nodes["comptech"], "Researching Data Theory must make Computer Consoles actionable in the delivered UI")
	TEST_ASSERT_EQUAL(server.stored_research.research_points[TECHWEB_POINT_TYPE_GENERIC], 8000, "The first research must debit exactly 2000 points")
	TEST_ASSERT(console.research_node("comptech", user), "The second research request must enter the wire")
	deadline = world.time + 3 SECONDS
	while(!console.netrun_research_cache?.researched_nodes["comptech"] && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT(console.netrun_research_cache?.researched_nodes["comptech"], "Computer Consoles must actually research through the network")
	TEST_ASSERT_EQUAL(server.stored_research.research_points[TECHWEB_POINT_TYPE_GENERIC], 6000, "Both research operations must debit their own price once")

/// Servers sharing the default network selector must never replicate their memory.
/datum/unit_test/netrun_research_independent_servers/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/machinery/rnd/server/first = scene.machine(/obj/machinery/rnd/server, scene.target_spot)
	var/obj/machinery/rnd/server/second = scene.machine(/obj/machinery/rnd/server, scene.source_spot)
	TEST_ASSERT(first.stored_research != second.stored_research, "Each physical server must own an independent authoritative techweb")
	first.stored_research.research_node_id("datatheory", TRUE, FALSE)
	TEST_ASSERT(!second.stored_research.researched_nodes["datatheory"], "Research on one server must not appear in another server")
	var/datum/techweb/old_web = first.stored_research
	qdel(first)
	TEST_ASSERT(QDELETED(old_web), "Destroying the physical owner must delete its authority")
	var/obj/machinery/rnd/server/replacement = scene.machine(/obj/machinery/rnd/server, scene.target_spot)
	TEST_ASSERT(!replacement.stored_research.researched_nodes["datatheory"], "A rebuilt server must start with baseline research")

/// Clients must lose access and cached presentation when the selected owner dies.
/datum/unit_test/netrun_research_owner_deleted/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/machinery/rnd/server/server = scene.machine(/obj/machinery/rnd/server, scene.target_spot)
	var/obj/machinery/computer/rdconsole/console = scene.machine(/obj/machinery/computer/rdconsole, scene.source_spot)
	SEND_SIGNAL(console, COMSIG_ATOM_SET_TECHWEB, server.stored_research)
	console.request_research_snapshot()
	var/deadline = world.time + 3 SECONDS
	while(!console.netrun_research_cache && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT(console.netrun_research_cache, "The console must receive a real snapshot before destruction")
	var/datum/techweb/old_web = server.stored_research
	qdel(server)
	TEST_ASSERT(QDELETED(old_web), "The destroyed server's data must not outlive the server")
	TEST_ASSERT(!netrun_atom_techweb(console) && !console.stored_research, "Destroying the server must clear both holder and native console binding")
	TEST_ASSERT(!console.netrun_research_cache, "The console must discard the destroyed server's presentation cache")
	TEST_ASSERT(!console.request_research_snapshot(), "A bound client must not silently recover the destroyed authority")

/// An old reply cannot restore research after unbind/rebind to the same authority.
/datum/unit_test/netrun_research_stale_reply/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/machinery/rnd/server/server = scene.machine(/obj/machinery/rnd/server, scene.target_spot)
	var/obj/machinery/computer/rdconsole/console = scene.machine(/obj/machinery/computer/rdconsole, scene.source_spot)
	SEND_SIGNAL(console, COMSIG_ATOM_SET_TECHWEB, server.stored_research)
	console.request_research_snapshot()
	var/deadline = world.time + 3 SECONDS
	while(!console.netrun_research_cache && world.time < deadline)
		sleep(world.tick_lag)
	var/datum/netrun_machine_service/research_client/client = console.get_netrun_machine_service("research.client")
	var/datum/netrun_machine_service/research_server/service = server.get_netrun_machine_service("research.server")
	var/list/old_snapshot = service.snapshot()
	old_snapshot["generation"] = ("binding_generation" in client.vars) ? client.vars["binding_generation"] : 0
	var/datum/netrun_machine_message/research/stale = allocate(/datum/netrun_machine_message/research, old_snapshot)
	stale.source = service
	SEND_SIGNAL(console, COMSIG_ATOM_SET_TECHWEB, null)
	SEND_SIGNAL(console, COMSIG_ATOM_SET_TECHWEB, server.stored_research)
	TEST_ASSERT(!client.receive(stale), "A reply from before unbind/rebind must be rejected even when its authority matches")
	TEST_ASSERT(!console.netrun_research_cache, "Rejected old replies must not recreate presentation state")

/// A cached recipe must not spend resources when its physical server is offline.
/datum/unit_test/netrun_research_disconnected_fabrication/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/machinery/rnd/server/server = scene.machine(/obj/machinery/rnd/server, scene.target_spot)
	var/obj/machinery/rnd/production/protolathe/lathe = scene.machine(/obj/machinery/rnd/production/protolathe, scene.source_spot)
	lathe.requires_console = FALSE
	SEND_SIGNAL(lathe, COMSIG_ATOM_SET_TECHWEB, server.stored_research)
	lathe.update_research()
	var/datum/netrun_machine_service/research_client/client = lathe.get_netrun_machine_service("research.client")
	var/deadline = world.time + 3 SECONDS
	while(client.snapshot_revision < 0 && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT(client.snapshot_revision >= 0, "The fabricator must receive cached recipes before the outage (server working=[server.working], stat=[server.machine_stat], binding=[netrun_atom_techweb(lathe) == server.stored_research], queued=[SSnetrun.get_machine_transport().queued_messages], queries=[length(client.resolutions)])")
	var/datum/design/design = SSresearch.techweb_design_by_id("micro_mani")
	var/datum/component/material_container/materials = lathe.materials.mat_container
	for(var/path in design.materials)
		materials.insert_amount_mat(design.materials[path] * 5, GET_MATERIAL_REF(path))
	var/before = materials.total_amount
	server.set_machine_stat(NOPOWER)
	TEST_ASSERT(!lathe.user_try_print_id("micro_mani", 1), "An offline authority must reject new cached fabrication")
	TEST_ASSERT_EQUAL(materials.total_amount, before, "Rejected fabrication must leave all materials intact")
	TEST_ASSERT(!lathe.busy, "Rejected fabrication must not start the machine")
	TEST_ASSERT(server.stored_research, "Power loss must retain the physical server's data")

/// A queued mechfab recipe also needs a fresh live-server authorization before spending.
/datum/unit_test/netrun_research_queued_fabrication_revoked/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/machinery/rnd/server/server = scene.machine(/obj/machinery/rnd/server, scene.target_spot)
	server.stored_research.add_design_by_id("mmi")
	var/obj/machinery/mecha_part_fabricator/fabricator = scene.machine(/obj/machinery/mecha_part_fabricator, scene.source_spot)
	SEND_SIGNAL(fabricator, COMSIG_ATOM_SET_TECHWEB, server.stored_research)
	fabricator.sync(TRUE, TRUE)
	var/datum/netrun_machine_service/research_client/client = fabricator.get_netrun_machine_service("research.client")
	var/deadline = world.time + 3 SECONDS
	while(client.snapshot_revision < 0 && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT(fabricator.stored_research.researched_designs["mmi"], "The queue test must start with a real delivered mechfab recipe")
	var/datum/design/design = SSresearch.techweb_design_by_id("mmi")
	var/datum/component/material_container/materials = fabricator.rmat.mat_container
	for(var/path in design.materials)
		materials.insert_amount_mat(design.materials[path] * 5, GET_MATERIAL_REF(path))
	var/before = materials.total_amount
	fabricator.queue += design
	server.set_machine_stat(NOPOWER)
	TEST_ASSERT(!fabricator.build_next_in_queue(), "A queued recipe must stop when its server loses power")
	TEST_ASSERT_EQUAL(length(fabricator.queue), 1, "A denied queued recipe must remain queued")
	TEST_ASSERT(!fabricator.being_built, "An offline queue must not start construction")
	TEST_ASSERT_EQUAL(materials.total_amount, before, "An offline queue must not consume materials")

/// Destruction between a design request and its response cannot start fabrication.
/datum/unit_test/netrun_research_pending_fabrication_deleted/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/machinery/rnd/server/server = scene.machine(/obj/machinery/rnd/server, scene.target_spot)
	var/obj/machinery/rnd/production/protolathe/lathe = scene.machine(/obj/machinery/rnd/production/protolathe, scene.source_spot)
	lathe.requires_console = FALSE
	SEND_SIGNAL(lathe, COMSIG_ATOM_SET_TECHWEB, server.stored_research)
	lathe.update_research()
	var/datum/netrun_machine_service/research_client/client = lathe.get_netrun_machine_service("research.client")
	var/deadline = world.time + 3 SECONDS
	while(client.snapshot_revision < 0 && world.time < deadline)
		sleep(world.tick_lag)
	var/datum/design/design = SSresearch.techweb_design_by_id("micro_mani")
	var/datum/component/material_container/materials = lathe.materials.mat_container
	for(var/path in design.materials)
		materials.insert_amount_mat(design.materials[path] * 5, GET_MATERIAL_REF(path))
	var/before = materials.total_amount
	TEST_ASSERT(lathe.user_try_print_id("micro_mani", 1), "A reachable server must admit the initial design request")
	TEST_ASSERT_EQUAL(materials.total_amount, before, "Admitting a request must not consume materials before the server replies")
	qdel(server)
	sleep(1 SECONDS)
	TEST_ASSERT_EQUAL(materials.total_amount, before, "A deleted owner must revoke the pending print before resource consumption")
	TEST_ASSERT(!lathe.busy, "No pending print may start after its authority is destroyed")

/// An operating console may retain physical disk protocols but not disconnected server protocols.
/datum/unit_test/netrun_research_peripheral_revocation/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/machinery/rnd/server/server = scene.machine(/obj/machinery/rnd/server, scene.target_spot)
	server.stored_research.add_design_by_id("surgery_lobotomy")
	var/obj/machinery/computer/operating/console = scene.machine(/obj/machinery/computer/operating, scene.source_spot)
	SEND_SIGNAL(console, COMSIG_ATOM_SET_TECHWEB, server.stored_research)
	console.sync_surgeries()
	var/deadline = world.time + 3 SECONDS
	while(!(/datum/surgery/advanced/lobotomy in console.advanced_surgeries) && world.time < deadline)
		console.sync_surgeries()
		sleep(world.tick_lag)
	TEST_ASSERT(/datum/surgery/advanced/lobotomy in console.advanced_surgeries, "An operating console must obtain a researched surgery through its server")
	server.set_machine_stat(NOPOWER)
	console.sync_surgeries()
	TEST_ASSERT(!(/datum/surgery/advanced/lobotomy in console.advanced_surgeries), "Server-provided surgical protocols must become unavailable while the authority is offline")

/// Only the external browser window is replaced: native refresh and transport stay real.
/datum/tgui/netrun_research_headless/process_status()
	status = UI_INTERACTIVE
	return FALSE

/datum/tgui/netrun_research_headless/send_update(custom_data, force)
	return

/// A packet-driven UI refresh must not generate another snapshot request forever.
/datum/unit_test/netrun_research_ui_refresh_drain/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/machinery/rnd/server/server = scene.machine(/obj/machinery/rnd/server, scene.target_spot)
	var/obj/machinery/computer/rdconsole/console = scene.machine(/obj/machinery/computer/rdconsole, scene.source_spot)
	SEND_SIGNAL(console, COMSIG_ATOM_SET_TECHWEB, server.stored_research)
	console.request_research_snapshot()
	var/deadline = world.time + 3 SECONDS
	while(!console.netrun_research_cache && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT(console.netrun_research_cache, "The drain test must begin after a real delivered research response")
	var/mob/living/carbon/human/user = allocate(/mob/living/carbon/human, scene.source_spot)
	var/datum/tgui/ui = allocate(/datum/tgui/netrun_research_headless, user, console, "Techweb")
	var/datum/netrun_machine_transport/transport = SSnetrun.get_machine_transport()
	var/packets = length(transport.packets)
	var/queued = transport.queued_messages
	for(var/index in 1 to 20)
		console.ui_interact(user, ui)
	TEST_ASSERT_EQUAL(length(transport.packets), packets, "Refreshing an existing research UI must not create any new machine packets")
	TEST_ASSERT_EQUAL(transport.queued_messages, queued, "Refreshing an existing research UI must not queue new discovery work")

/datum/unit_test/netrun_research_ui_refresh_drain_mechfab/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/machinery/rnd/server/server = scene.machine(/obj/machinery/rnd/server, scene.target_spot)
	var/obj/machinery/mecha_part_fabricator/fabricator = scene.machine(/obj/machinery/mecha_part_fabricator, scene.source_spot)
	SEND_SIGNAL(fabricator, COMSIG_ATOM_SET_TECHWEB, server.stored_research)
	fabricator.sync(TRUE, TRUE)
	var/datum/netrun_machine_service/research_client/client = fabricator.get_netrun_machine_service("research.client")
	var/deadline = world.time + 3 SECONDS
	while(client.snapshot_revision < 0 && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT(client.snapshot_revision >= 0, "The mechfab drain test needs a delivered research cache")
	var/mob/living/carbon/human/user = allocate(/mob/living/carbon/human, scene.source_spot)
	var/datum/tgui/ui = allocate(/datum/tgui/netrun_research_headless, user, fabricator, "ExosuitFabricator")
	var/datum/netrun_machine_transport/transport = SSnetrun.get_machine_transport()
	var/packets = length(transport.packets)
	var/queued = transport.queued_messages
	for(var/index in 1 to 20)
		fabricator.ui_interact(user, ui)
	TEST_ASSERT_EQUAL(length(transport.packets), packets, "Refreshing an existing mechfab UI must not create any new machine packets")
	TEST_ASSERT_EQUAL(transport.queued_messages, queued, "A mechfab refresh must not queue discovery work")

/// A telemetry-only credit source must not receive a full research database or subscribe to pushes.
/datum/unit_test/netrun_research_credit_source_quiet/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/machinery/rnd/server/server = scene.machine(/obj/machinery/rnd/server, scene.target_spot)
	server.base_mining_income = list()
	server.stored_research.research_points = list()
	server.stored_research.next_income = list()
	var/obj/machinery/power/tesla_coil/coil = scene.machine(/obj/machinery/power/tesla_coil, scene.source_spot)
	SEND_SIGNAL(coil, COMSIG_ATOM_SET_TECHWEB, server.stored_research)
	var/datum/netrun_machine_service/research_client/client = coil.get_netrun_machine_service("research.client")
	TEST_ASSERT(coil.netrun_research_request("credit", list("points" = list(TECHWEB_POINT_TYPE_GENERIC = 37))), "The real credit source must enter the research transport")
	var/deadline = world.time + 3 SECONDS
	while((server.stored_research.next_income[TECHWEB_POINT_TYPE_GENERIC] + server.stored_research.research_points[TECHWEB_POINT_TYPE_GENERIC]) < 37 && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT_EQUAL(server.stored_research.next_income[TECHWEB_POINT_TYPE_GENERIC] + server.stored_research.research_points[TECHWEB_POINT_TYPE_GENERIC], 37, "The credit must reach authoritative research exactly once")
	sleep(0.5 SECONDS)
	TEST_ASSERT(!client.snapshot_cache, "A credit-only source must not download a complete research cache")
	var/datum/netrun_machine_service/research_server/service = server.get_netrun_machine_service("research.server")
	TEST_ASSERT(!service.subscribers[client.node.address], "A credit-only source must not subscribe to full database pushes")

/// A physical disk/action response is a transaction outcome, not replaceable telemetry.
/datum/unit_test/netrun_research_outcome_not_coalesced/Run()
	var/datum/netrun_machine_message/research/result = allocate(/datum/netrun_machine_message/research, list("operation" = "snapshot", "requested_operation" = "download_disk", "binding" = "test", "generation" = 1, "disk" = "physical disk"))
	TEST_ASSERT(!result.coalescing_key(), "Physical disk download responses must never be discarded as replaceable research state")

/// Exporting a new physical blueprint needs the live server, just like starting fabrication.
/datum/unit_test/netrun_research_offline_blueprint_export/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/machinery/rnd/server/server = scene.machine(/obj/machinery/rnd/server, scene.target_spot)
	var/obj/machinery/computer/rdconsole/console = scene.machine(/obj/machinery/computer/rdconsole, scene.source_spot)
	SEND_SIGNAL(console, COMSIG_ATOM_SET_TECHWEB, server.stored_research)
	console.request_research_snapshot()
	var/deadline = world.time + 3 SECONDS
	while(!console.netrun_research_cache && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT(console.netrun_research_cache?.researched_designs["micro_mani"], "The export test needs a delivered recipe before the outage")
	console.d_disk = allocate(/obj/item/disk/design_disk, console)
	var/mob/living/carbon/human/user = allocate(/mob/living/carbon/human, scene.source_spot)
	var/datum/tgui/ui = allocate(/datum/tgui/netrun_research_headless, user, console, "Techweb")
	ui.status = UI_INTERACTIVE
	server.set_machine_stat(NOPOWER)
	usr = user
	console.ui_act("writeDesign", list("slot" = "1", "selectedDesign" = "micro_mani"), ui)
	usr = null
	TEST_ASSERT(!console.d_disk.blueprints[1], "An offline server must not export a cached recipe onto a physical disk")

/// The asynchronous grant must start a legitimate build exactly once, not merely reject outages.
/datum/unit_test/netrun_research_connected_fabrication/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/machinery/rnd/server/server = scene.machine(/obj/machinery/rnd/server, scene.target_spot)
	var/obj/machinery/rnd/production/protolathe/lathe = scene.machine(/obj/machinery/rnd/production/protolathe, scene.source_spot)
	lathe.requires_console = FALSE
	SEND_SIGNAL(lathe, COMSIG_ATOM_SET_TECHWEB, server.stored_research)
	lathe.update_research()
	var/datum/netrun_machine_service/research_client/client = lathe.get_netrun_machine_service("research.client")
	var/deadline = world.time + 3 SECONDS
	while(client.snapshot_revision < 0 && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT(client.snapshot_revision >= 0, "The connected print must begin with a real delivered recipe cache")
	var/datum/component/material_container/materials = lathe.materials.mat_container
	materials.insert_amount_mat(500, GET_MATERIAL_REF(/datum/material/iron))
	var/expected_cost = 100 * lathe.print_cost_coeff
	var/before = materials.total_amount
	TEST_ASSERT(lathe.user_try_print_id("micro_mani", 1), "A connected server must admit the legitimate fabrication request")
	TEST_ASSERT_EQUAL(materials.total_amount, before, "The client must wait for the actual design reply before spending")
	deadline = world.time + 3 SECONDS
	while(materials.total_amount == before && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT_EQUAL(materials.total_amount, before - expected_cost, "A delivered grant must consume exactly one recipe's material cost")
	sleep(0.5 SECONDS)
	TEST_ASSERT_EQUAL(materials.total_amount, before - expected_cost, "Late/duplicate state updates must not print the granted item twice")

/// The native mechfab sync path cannot silently select another server after owner loss.
/datum/unit_test/netrun_research_mechfab_no_silent_failover/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/machinery/rnd/server/original = scene.machine(/obj/machinery/rnd/server, scene.target_spot)
	var/obj/machinery/rnd/server/other = scene.machine(/obj/machinery/rnd/server, scene.source_spot)
	var/obj/machinery/mecha_part_fabricator/fabricator = scene.machine(/obj/machinery/mecha_part_fabricator, scene.source_spot)
	SEND_SIGNAL(fabricator, COMSIG_ATOM_SET_TECHWEB, original.stored_research)
	qdel(original)
	fabricator.sync(TRUE, TRUE)
	TEST_ASSERT(!netrun_atom_techweb(fabricator), "A lost owner must leave the mechfab disconnected until an explicit authority binding")
	TEST_ASSERT(other.stored_research, "The regression needs another reachable live server that must not be selected silently")

/// Empty income and re-adding an existing recipe cannot manufacture changed revisions forever.
/datum/unit_test/netrun_research_noop_publication/Run()
	var/datum/techweb/web = allocate(/datum/techweb)
	var/revision = web.netrun_research_revision
	web.add_point_list(list(), FALSE)
	TEST_ASSERT_EQUAL(web.netrun_research_revision, revision, "Empty income must not publish a changed research database")
	web.add_point_list(list(TECHWEB_POINT_TYPE_GENERIC = 0), FALSE)
	TEST_ASSERT_EQUAL(web.netrun_research_revision, revision, "Zero income must not publish a changed research database")
	web.add_design_by_id("micro_mani")
	TEST_ASSERT_EQUAL(web.netrun_research_revision, revision, "Re-adding a known starting recipe must not trigger database replication")

/// Archaeology sends a real tool request; the artifact is consumed only by the receiving authority.
/datum/unit_test/netrun_research_artifact_request/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/machinery/rnd/server/server = scene.machine(/obj/machinery/rnd/server, scene.target_spot)
	server.base_mining_income = list()
	server.stored_research.research_points = list()
	server.stored_research.next_income = list()
	var/mob/living/carbon/human/user = allocate(/mob/living/carbon/human, scene.source_spot)
	var/obj/item/xenoarch/help/research/tool = allocate(/obj/item/xenoarch/help/research, user)
	var/obj/item/ancientartifact/useless/artifact = allocate(/obj/item/ancientartifact/useless, scene.source_spot)
	SEND_SIGNAL(tool, COMSIG_ATOM_SET_TECHWEB, server.stored_research)
	TEST_ASSERT(tool.netrun_research_request("artifact", list("artifact" = REF(artifact)), user), "A real archaeology tool must submit its research to the selected physical server")
	TEST_ASSERT(!QDELETED(artifact), "Admitting the request must not consume the artifact before delivery")
	var/deadline = world.time + 3 SECONDS
	while(!QDELETED(artifact) && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT(QDELETED(artifact), "The delivered request must consume the researched artifact once")
	TEST_ASSERT_EQUAL(server.stored_research.research_points[TECHWEB_POINT_TYPE_GENERIC] + server.stored_research.next_income[TECHWEB_POINT_TYPE_GENERIC], 4500, "The server must award the actual artifact's 4500 points exactly once")
