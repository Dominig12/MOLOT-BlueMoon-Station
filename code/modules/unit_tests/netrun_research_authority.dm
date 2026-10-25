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
	TEST_ASSERT(client.snapshot_revision >= 0, "The fabricator must have received cached recipes before the outage")
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
