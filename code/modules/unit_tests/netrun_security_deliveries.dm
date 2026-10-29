/// One authoritative event per accepted delivery, independent of UI log projections.
/datum/unit_test/proc/netrun_illegal_delivery_reports(datum/component/netrun_node/node)
	. = 0
	for(var/datum/netrun_incident/incident as anything in SSnetrun.incidents)
		if(incident.kind == "intrusion" && incident.address == node.address)
			. += incident.reports

/// Custom providers share the same delivery boundary as native APIs and report only handled actions.
/datum/unit_test/netrun_security_api_delivery/Run()
	var/datum/netrun_fortress_scene/scene = allocate(/datum/netrun_fortress_scene, run_loc_floor_bottom_left)
	var/obj/item/netrun_provider_test/conditional/target = allocate(/obj/item/netrun_provider_test/conditional, run_loc_floor_bottom_left)
	target.anchored = TRUE
	var/datum/component/netrun_node/node = target.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL, list(), 1, list(ACCESS_RD))
	var/atom/source_host = scene.node_a.parent
	var/datum/netrun_console/console = allocate(/datum/netrun_console, source_host)
	console.operator = allocate(/mob)
	console.connection.wireless = FALSE
	console.access_session.node_access[node.address] = NETRUN_ACCESS_USER
	TEST_ASSERT(console.remote_request(node.address, "write", list("value" = -2)), "An acquired USER grant admits the ordinary provider request")
	var/datum/netrun_request/remote/packet = netrun_operation_packet(console, /datum/netrun_request/remote)
	TEST_ASSERT_NOTNULL(packet, "The API action first owns a real delivery packet")
	TEST_ASSERT_EQUAL(netrun_illegal_delivery_reports(node), 0, "Admission cannot accuse an actor before the device handles its request")
	var/trace_before = console.intrusion.trace
	TEST_ASSERT(packet.deliver(), "The available provider handles the validated request")
	TEST_ASSERT_EQUAL(target.deliveries, 1, "The actual provider side effect executes once")
	TEST_ASSERT_EQUAL(netrun_illegal_delivery_reports(node), 1, "A successful unauthorized API delivery reports exactly one incident")
	TEST_ASSERT_EQUAL(console.intrusion.trace, trace_before + 6 * node.get_security(), "Reporting must preserve the API's existing trace price")
	console.next_command = world.time
	TEST_ASSERT(console.remote_request(node.address, "write", list("value" = -3)), "A second operation may be admitted before service withdrawal")
	packet = netrun_operation_packet(console, /datum/netrun_request/remote)
	target.service_enabled = FALSE
	trace_before = console.intrusion.trace
	TEST_ASSERT(!packet.deliver(), "A withdrawn provider must reject its queued operation")
	TEST_ASSERT_EQUAL(target.deliveries, 1, "A rejected operation never reaches the provider")
	TEST_ASSERT_EQUAL(netrun_illegal_delivery_reports(node), 1, "A rejected API delivery must not create another accusation")
	TEST_ASSERT_EQUAL(console.intrusion.trace, trace_before, "A rejected API operation spends no successful-execution trace")

/// Full disks and missing files cannot produce tracking evidence for a mutation that never occurred.
/datum/unit_test/netrun_security_file_delivery/Run()
	var/datum/netrun_fortress_scene/scene = allocate(/datum/netrun_fortress_scene, run_loc_floor_bottom_left)
	var/atom/source_host = scene.node_a.parent
	var/datum/netrun_console/console = allocate(/datum/netrun_console, source_host)
	console.operator = allocate(/mob)
	console.connection.wireless = FALSE
	console.access_session.node_access[scene.node_b.address] = NETRUN_ACCESS_USER
	var/datum/netrun_file/file = new("evidence-payload.txt", NETRUN_FILE_TEXT, "Personal payload", 1)
	TEST_ASSERT(console.store_file(file), "The sender owns an actual source file")
	scene.node_b.file_store.capacity = 0
	TEST_ASSERT(console.queue_file_request("upload", scene.node_b, file.uid), "A file is admitted before checking the receiving disk's free space")
	var/datum/netrun_request/file/packet = netrun_operation_packet(console, /datum/netrun_request/file)
	var/trace_before = console.intrusion.trace
	TEST_ASSERT(!packet.deliver(), "A full disk rejects its actual write")
	TEST_ASSERT_EQUAL(netrun_illegal_delivery_reports(scene.node_b), 0, "An unhandled file write cannot produce an intrusion report")
	TEST_ASSERT_EQUAL(console.intrusion.trace, trace_before, "Failed disk writes preserve the existing no-trace behavior")
	scene.node_b.file_store.capacity = 8
	console.next_command = world.time
	TEST_ASSERT(console.queue_file_request("upload", scene.node_b, file.uid), "A repaired destination admits a new upload")
	packet = netrun_operation_packet(console, /datum/netrun_request/file)
	TEST_ASSERT(packet.deliver(), "The actual upload succeeds after free space returns")
	TEST_ASSERT_EQUAL(netrun_illegal_delivery_reports(scene.node_b), 1, "Successful acquired-access file writes emit exactly one report")
	TEST_ASSERT_EQUAL(console.intrusion.trace, trace_before + 3 * scene.node_b.get_security(), "The file wrapper must not add a second trace charge")
	console.next_command = world.time
	TEST_ASSERT(console.queue_file_request("download", scene.node_b, "missing-file-uid"), "A syntactically valid request still rechecks file identity at delivery")
	packet = netrun_operation_packet(console, /datum/netrun_request/file)
	trace_before = console.intrusion.trace
	TEST_ASSERT(!packet.deliver(), "A missing source file cannot be downloaded")
	TEST_ASSERT_EQUAL(netrun_illegal_delivery_reports(scene.node_b), 1, "A missing UID does not create a duplicate intrusion report")
	TEST_ASSERT_EQUAL(console.intrusion.trace, trace_before, "The rejected missing-file delivery cannot spend a success trace charge")
