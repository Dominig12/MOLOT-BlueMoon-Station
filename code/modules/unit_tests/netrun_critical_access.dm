/// A concrete endpoint can opt into isolation without adding a type switch to a console.
/obj/item/netrun_critical_access_test
	name = "isolated controller fixture"

/obj/item/netrun_critical_access_test/netrun_inherited_access_cap()
	return NETRUN_ACCESS_GUEST

/obj/item/netrun_critical_access_test/netrun_security_floor()
	return 5

/// Legacy/elevated LAN grants must not impersonate controller grants or native credentials.
/datum/unit_test/netrun_critical_access_lan_isolation/Run()
	var/datum/netrun_route_scene/scene = netrun_connected_test_area()
	var/turf/origin = run_loc_floor_bottom_left
	var/obj/machinery/power/apc/apc = locate() in scene.owned
	var/datum/component/netrun_node/apc_node = apc.GetComponent(/datum/component/netrun_node)
	var/obj/machinery/computer/netrun_terminal/source = scene.machine(/obj/machinery/computer/netrun_terminal, get_step(origin, EAST))
	var/obj/machinery/computer/netrun_terminal/ordinary = scene.machine(/obj/machinery/computer/netrun_terminal, get_step(origin, NORTH))
	var/datum/component/netrun_node/source_node = source.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/ordinary_node = ordinary.GetComponent(/datum/component/netrun_node)
	var/mob/camera/netrun_entity/entity = new(origin, source_node)
	scene.owned.Insert(1, entity)
	var/datum/netrun_console/console = entity.console
	console.operator = entity
	SSnetrun.ensure_topology()
	TEST_ASSERT(console.can_route(apc_node), "The protected controller must have a real route")
	console.access_session.network_access[apc_node.network.id] = NETRUN_ACCESS_ROOT
	TEST_ASSERT_EQUAL(console.node_level(apc_node), NETRUN_ACCESS_GUEST, "A LAN ROOT grant must not control its isolated APC")
	TEST_ASSERT_EQUAL(console.node_level(ordinary_node), NETRUN_ACCESS_ROOT, "Ordinary endpoints must retain their existing inherited-access policy")
	console.workspace_view = "map"
	console.map_view.selected_address = apc_node.address
	var/list/ui = console.ui_data(null)
	var/list/selected = ui["selected"]
	var/list/status = selected?["status"]
	TEST_ASSERT(apc.netrun_access_policy_status() in status, "A guest must see the controller policy before starting a breach")
	console.access_session.node_access[apc_node.address] = NETRUN_ACCESS_USER
	TEST_ASSERT_EQUAL(console.node_level(apc_node), NETRUN_ACCESS_USER, "A separate controller USER grant must survive its LAN cap")
	console.access_session.node_access[apc_node.address] = NETRUN_ACCESS_ROOT
	TEST_ASSERT_EQUAL(console.node_level(apc_node), NETRUN_ACCESS_ROOT, "A separate controller ROOT grant must survive its LAN cap")
	console.access_session.node_access -= apc_node.address
	var/datum/netrun_file/access/engineering = new("engineer.access", list(ACCESS_ENGINE_EQUIP))
	TEST_ASSERT(console.store_file(engineering), "Matching native credentials must occupy real process memory")
	TEST_ASSERT_EQUAL(console.node_level(apc_node), NETRUN_ACCESS_USER, "The real engineering ID must retain its normal APC USER rights")
	TEST_ASSERT_EQUAL(console.legit_node_level(apc_node), NETRUN_ACCESS_USER, "Isolation must not turn native engineering access into an illegal grant")
	console.delete_local_file(engineering)
	TEST_ASSERT_EQUAL(console.node_level(apc_node), NETRUN_ACCESS_GUEST, "Removing native credentials must leave only isolated LAN transport")
	var/datum/netrun_file/access/administrator = new("administrator.access", list(ACCESS_ENGINE_EQUIP, ACCESS_NETWORK))
	TEST_ASSERT(console.store_file(administrator), "Matching administrator credentials must fit")
	TEST_ASSERT_EQUAL(console.node_level(apc_node), NETRUN_ACCESS_ROOT, "Native administrator rights must retain ROOT without a breach")

/// The first critical breach cannot jump directly from GUEST to ROOT, even with a forged reward.
/datum/unit_test/netrun_critical_access_breach_stages/Run()
	var/obj/item/netrun_critical_access_test/host = allocate(/obj/item/netrun_critical_access_test)
	var/datum/component/netrun_node/node = host.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
	var/mob/camera/netrun_entity/entity = allocate(/mob/camera/netrun_entity)
	entity.enter_node(node)
	var/datum/netrun_console/console = entity.console
	TEST_ASSERT_EQUAL(node.base_security, 5, "A policy floor must also apply to generic component registration")
	TEST_ASSERT_EQUAL(console.node_level(node), NETRUN_ACCESS_GUEST, "The fixture must begin without controller authority")
	TEST_ASSERT(console.start_breach("node", node.address), "The transport stage must allow a separate controller breach")
	var/datum/netrun_breach/first = console.intrusion.breach
	TEST_ASSERT_EQUAL(first.initial_access_level, NETRUN_ACCESS_GUEST, "A breach must snapshot its initial controller authority")
	var/list/payload = first.ui_payload()
	TEST_ASSERT_EQUAL(payload["access_cap"], NETRUN_ACCESS_USER, "The first stage must not promise ROOT in its UI")
	for(var/list/reward as anything in first.daemons)
		TEST_ASSERT(reward["reward"] <= NETRUN_ACCESS_USER, "Generated first-stage rewards must honor its advertised cap")
	// Final delivery must enforce the policy independently of generation/UI metadata.
	first.daemons = list(list("reward" = NETRUN_ACCESS_ROOT, "done" = TRUE))
	first.finish()
	TEST_ASSERT_EQUAL(console.node_level(node), NETRUN_ACCESS_USER, "A completed first stage must grant at most USER")
	TEST_ASSERT(console.start_breach("node", node.address), "ROOT escalation must use a separate breach")
	var/datum/netrun_breach/second = console.intrusion.breach
	TEST_ASSERT_EQUAL(second.initial_access_level, NETRUN_ACCESS_USER, "The second stage must start with an actual USER grant")
	payload = second.ui_payload()
	TEST_ASSERT_EQUAL(payload["access_cap"], NETRUN_ACCESS_ROOT, "A separate authorized escalation may advertise ROOT")
	second.daemons = list(list("reward" = NETRUN_ACCESS_ROOT, "done" = TRUE))
	second.finish()
	TEST_ASSERT_EQUAL(console.node_level(node), NETRUN_ACCESS_ROOT, "A completed separate escalation must grant controller ROOT")

/// A borrowed USER credential must remain valid through a critical ROOT escalation.
/datum/unit_test/netrun_critical_access_escalation_revocation/Run()
	var/obj/item/netrun_critical_access_test/host = allocate(/obj/item/netrun_critical_access_test)
	var/datum/component/netrun_node/node = host.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL, list(), 1, list(ACCESS_RD))
	var/mob/camera/netrun_entity/entity = allocate(/mob/camera/netrun_entity)
	entity.enter_node(node)
	var/datum/netrun_console/console = entity.console
	var/datum/netrun_file/access/credential = new("borrowed.access", list(ACCESS_RD))
	TEST_ASSERT(console.store_file(credential), "A borrowed native credential must fit")
	TEST_ASSERT_EQUAL(console.node_level(node), NETRUN_ACCESS_USER, "The credential must supply a real USER prerequisite")
	TEST_ASSERT(console.start_breach("node", node.address), "An initial USER credential must allow escalation")
	var/datum/netrun_breach/job = console.intrusion.breach
	TEST_ASSERT_EQUAL(job.initial_access_level, NETRUN_ACCESS_USER, "The escalation must capture its actual initial prerequisite")
	console.delete_local_file(credential)
	TEST_ASSERT_EQUAL(console.node_level(node), NETRUN_ACCESS_GUEST, "Deleting the credential must revoke the live prerequisite")
	job.daemons = list(list("reward" = NETRUN_ACCESS_ROOT, "done" = TRUE))
	job.finish()
	TEST_ASSERT_EQUAL(console.node_level(node), NETRUN_ACCESS_USER, "A lost prerequisite must cap final delivery at USER instead of granting ROOT")

/// Real infrastructure adapters opt in, while AI ownership remains authoritative.
/datum/unit_test/netrun_critical_access_infrastructure_policy/Run()
	var/datum/netrun_route_scene/scene = netrun_connected_test_area()
	var/turf/origin = run_loc_floor_bottom_left
	var/obj/machinery/power/apc/apc = locate() in scene.owned
	var/obj/machinery/ntnet_relay/relay = scene.machine(/obj/machinery/ntnet_relay, get_step(origin, EAST))
	var/obj/machinery/telecomms/server/telecomms = scene.machine(/obj/machinery/telecomms/server, get_step(origin, NORTH))
	var/obj/machinery/rnd/server/research = scene.machine(/obj/machinery/rnd/server, origin)
	var/obj/machinery/computer/rdconsole/research_console = scene.machine(/obj/machinery/computer/rdconsole, get_step(origin, EAST))
	for(var/atom/target as anything in list(apc, relay, telecomms, research, research_console))
		var/datum/component/netrun_node/node = target.GetComponent(/datum/component/netrun_node)
		TEST_ASSERT_EQUAL(target.netrun_inherited_access_cap(), NETRUN_ACCESS_GUEST, "Critical infrastructure must isolate controller rights from the LAN")
		TEST_ASSERT(node && node.base_security >= target.netrun_security_floor(), "Every native critical node must honor its policy security floor")
		TEST_ASSERT_EQUAL(target.netrun_breach_access_cap(NETRUN_ACCESS_GUEST), NETRUN_ACCESS_USER, "Each critical endpoint must require a separate ROOT stage")
	var/mob/living/carbon/human/donor = allocate(/mob/living/carbon/human)
	var/mob/living/silicon/ai/ai = allocate(/mob/living/silicon/ai, origin, null, donor)
	var/datum/component/netrun_node/core = ai.GetComponent(/datum/component/netrun_node)
	TEST_ASSERT_EQUAL(ai.netrun_inherited_access_cap(), NETRUN_ACCESS_GUEST, "An AI core must not inherit LAN controller authority")
	TEST_ASSERT_EQUAL(core.base_security, 5, "The AI core must retain maximum base protection")
	TEST_ASSERT_EQUAL(ai.netrun_console.node_level(core), NETRUN_ACCESS_ROOT, "The AI must retain native ROOT over its own core")
	TEST_ASSERT_EQUAL(ai.netrun_console.node_level(apc.GetComponent(/datum/component/netrun_node)), NETRUN_ACCESS_ROOT, "The AI's real station credentials must retain normal infrastructure control")
