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

/// Physical evidence reveals equipment and sectors, then expires without idle polling.
/datum/unit_test/netrun_station_interference_evidence/Run()
	var/datum/netrun_fortress_scene/scene = allocate(/datum/netrun_fortress_scene, run_loc_floor_bottom_left)
	var/obj/machinery/computer/netrun_terminal/target = scene.machine(/obj/machinery/computer/netrun_terminal, get_turf(scene.node_b.parent))
	var/datum/component/netrun_node/node = netrun_find_node(target)
	var/datum/netrun_console/attacker = allocate(/datum/netrun_console, scene.node_a.parent)
	var/list/examine_list = list()
	SEND_SIGNAL(target, COMSIG_PARENT_EXAMINE, null, examine_list)
	TEST_ASSERT(!findtext(jointext(examine_list, " "), "сетевого вмешательства"), "Untouched equipment cannot accuse an operator")
	attacker.report_illegal_activity(node, "station evidence fixture", NETRUN_ACCESS_ROOT)
	TEST_ASSERT(node.interference_until > world.time, "A completed illegal action leaves a physical diagnostic trace")
	TEST_ASSERT(scene.apc_node.suspicious_traffic_until > world.time, "The actual sector APC exposes the suspicious traffic")
	SEND_SIGNAL(target, COMSIG_PARENT_EXAMINE, null, examine_list)
	TEST_ASSERT(findtext(jointext(examine_list, " "), "сетевого вмешательства"), "Physical examination describes recent interference")
	var/feedback_deadline = node.next_interference_feedback
	attacker.report_illegal_activity(node, "repeated station evidence fixture", NETRUN_ACCESS_ROOT)
	TEST_ASSERT_EQUAL(node.next_interference_feedback, feedback_deadline, "Repeated interference cannot spam physical sound and visible feedback")
	examine_list.Cut()
	SEND_SIGNAL(scene.apc, COMSIG_PARENT_EXAMINE, null, examine_list)
	TEST_ASSERT(findtext(jointext(examine_list, " "), "Изолируйте сетевой интерфейс"), "The physical APC clue explains how to interrupt the connection")
	node.interference_until = world.time
	examine_list.Cut()
	SEND_SIGNAL(target, COMSIG_PARENT_EXAMINE, null, examine_list)
	TEST_ASSERT(!findtext(jointext(examine_list, " "), "сетевого вмешательства"), "Expired evidence disappears without waking an idle node")

/// A local network switch invalidates retained routes independently of power and acquired keys.
/datum/unit_test/netrun_station_apc_isolation/Run()
	var/datum/netrun_fortress_scene/scene = allocate(/datum/netrun_fortress_scene, run_loc_floor_bottom_left)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, scene.node_a.parent)
	TEST_ASSERT(console.can_route(scene.node_b), "The sector initially has a real route through its APC")
	var/power_before = scene.apc.operating
	var/epoch_before = scene.apc_node.access_key_epoch
	TEST_ASSERT(scene.apc.set_netrun_isolated(TRUE), "Physical isolation can disconnect the sector network")
	TEST_ASSERT(!console.can_route(scene.node_b), "A retained route cannot pass the isolated APC")
	TEST_ASSERT_EQUAL(scene.node_a.uplink_node(), scene.apc_node, "Isolated endpoints cannot escape to another APC")
	TEST_ASSERT_EQUAL(scene.apc.operating, power_before, "Network isolation preserves the sector power breaker")
	TEST_ASSERT(scene.apc.set_netrun_isolated(FALSE), "A local operator can reconnect the interface")
	TEST_ASSERT(console.can_route(scene.node_b), "Reconnection restores the real physical route")
	TEST_ASSERT_EQUAL(scene.apc_node.access_key_epoch, epoch_before, "A reversible disconnect does not revoke acquired keys or rebind equipment")

/// The switch is a physical APC control, with the native lock and an independent locality check.
/datum/unit_test/netrun_station_apc_isolation_authority/Run()
	var/datum/netrun_client_scene/scene = allocate(/datum/netrun_client_scene, run_loc_floor_bottom_left)
	var/datum/tgui/ui = allocate(/datum/tgui, scene.user, scene.apc, "Apc")
	ui.status = UI_INTERACTIVE
	scene.apc.locked = TRUE
	usr = scene.user
	scene.apc.ui_act("netrun_isolate", list(), ui)
	usr = null
	TEST_ASSERT(!scene.apc.netrun_isolated, "A locked physical panel rejects network isolation")
	scene.apc.locked = FALSE
	scene.user.forceMove(scene.far_spot)
	usr = scene.user
	scene.apc.ui_act("netrun_isolate", list(), ui)
	usr = null
	TEST_ASSERT(!scene.apc.netrun_isolated, "Even a stale interactive UI cannot isolate a distant APC")
	scene.user.forceMove(run_loc_floor_bottom_left)
	usr = scene.user
	scene.apc.ui_act("netrun_isolate", list(), ui)
	usr = null
	TEST_ASSERT(scene.apc.netrun_isolated, "An adjacent operator can use an unlocked APC's physical network switch")
	usr = scene.user
	scene.apc.ui_act("netrun_isolate", list(), ui)
	usr = null
	TEST_ASSERT(!scene.apc.netrun_isolated, "The same local panel restores the network while the APC is isolated")
	scene.apc.failure_timer = 1
	usr = scene.user
	scene.apc.ui_act("netrun_isolate", list(), ui)
	usr = null
	TEST_ASSERT(!scene.apc.netrun_isolated, "The APC reboot exception cannot bypass the network switch guard")
	var/datum/netrun_provider/provider = SSnetrun.get_provider(scene.apc)
	TEST_ASSERT(!("netrun_isolate" in provider.actions), "The local switch cannot be reversed through a compromised netrun API")

/// Physical security consoles receive bounded, anonymous alerts through actual routed packets.
/datum/unit_test/netrun_station_security_subscription/Run()
	var/datum/netrun_fortress_scene/scene = allocate(/datum/netrun_fortress_scene, run_loc_floor_bottom_left)
	var/obj/machinery/computer/security/console = scene.machine(/obj/machinery/computer/security, get_turf(scene.node_b.parent))
	var/datum/netrun_machine_service/security_events/publisher = scene.apc.get_netrun_machine_service("security.events")
	var/datum/netrun_machine_service/security_monitor/monitor = console.get_netrun_machine_service("security.monitor")
	var/datum/netrun_machine_transport/transport = SSnetrun.get_machine_transport()
	var/deadline = world.time + 5 SECONDS
	while(!transport.is_ready() && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT(transport.is_ready(), "Physical security subscriptions use the machine transport readiness barrier")
	TEST_ASSERT_NOTNULL(publisher, "One physical APC aggregates its sector's station alarms")
	TEST_ASSERT_NOTNULL(monitor, "The native camera console owns a security monitor")
	publisher.subscribers.Cut()
	monitor.alerts.Cut()
	TEST_ASSERT(monitor.send_to(publisher, new /datum/netrun_machine_message(list("operation" = "subscribe"))), "An operational security console may request a real subscription")
	var/datum/netrun_machine_packet/data/packet = netrun_security_packet(monitor, publisher, "subscribe")
	TEST_ASSERT_NOTNULL(packet, "Subscription is a normal routed machine packet")
	TEST_ASSERT(!length(publisher.subscribers), "Admission alone cannot subscribe the console")
	packet.deliver()
	TEST_ASSERT_EQUAL(length(publisher.subscribers), 1, "Subscription becomes effective on delivery")
	var/datum/netrun_incident/incident = SSnetrun.report_incident("intrusion", scene.apc_node, null, NETRUN_INCIDENT_MEDIUM, "Station security fixture")
	TEST_ASSERT(!length(publisher.pending_events), "An isolated medium incident cannot flood physical security")
	SSnetrun.report_incident("intrusion", scene.apc_node, null, NETRUN_INCIDENT_MEDIUM, "Repeated station security fixture")
	TEST_ASSERT_EQUAL(length(monitor.alerts), 0, "The global incident hook does not bypass network delivery")
	publisher.publish_slice()
	packet = netrun_security_packet(publisher, monitor, "event")
	TEST_ASSERT_NOTNULL(packet, "Repeated medium incidents enter ordinary machine delivery")
	packet.deliver()
	TEST_ASSERT_EQUAL(length(monitor.alerts), 1, "The physical console receives the delivered incident")
	var/list/received = monitor.alerts[1]
	TEST_ASSERT_EQUAL(received["id"], incident.id, "The public journal retains the authoritative incident ID")
	TEST_ASSERT_EQUAL(received["reports"], 2, "The public journal records repeat count")
	TEST_ASSERT_NULL(received["suspect"], "A public station alarm does not disclose the actor's identity")
	TEST_ASSERT(received["area"], "The physical crew receives a useful area-level clue")
	var/list/data = console.ui_data()
	TEST_ASSERT_EQUAL(length(data["network_alerts"]), 1, "The native security console exposes its delivered journal")
	SSnetrun.report_incident("intrusion", scene.apc_node, null, NETRUN_INCIDENT_MEDIUM, "Third station security fixture")
	publisher.publish_slice()
	packet = netrun_security_packet(publisher, monitor, "event")
	TEST_ASSERT_NOTNULL(packet, "Updated incidents still travel through packets")
	packet.deliver()
	TEST_ASSERT_EQUAL(length(monitor.alerts), 1, "Repeats replace the existing journal row instead of flooding it")
	received = monitor.alerts[1]
	TEST_ASSERT_EQUAL(received["reports"], 3, "An incident update refreshes the same row")
	SSnetrun.report_incident("trace", scene.apc_node, null, NETRUN_INCIDENT_HIGH, "Disconnected station security fixture")
	publisher.publish_slice()
	packet = netrun_security_packet(publisher, monitor, "event")
	TEST_ASSERT_NOTNULL(packet, "High incidents also use real packets")
	console.set_machine_stat(NOPOWER)
	TEST_ASSERT(!packet.deliver(), "A console disconnected in flight cannot receive an alert")
	TEST_ASSERT_EQUAL(length(monitor.alerts), 1, "Disconnected equipment retains only its previously delivered journal")
	publisher.prune_subscribers()
	TEST_ASSERT(!length(publisher.subscribers), "An unpowered monitor may lose its stale subscription")
	console.set_machine_stat(0)
	deadline = world.time + 5 SECONDS
	while(!publisher.subscribers[monitor.service_key()] && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT(publisher.subscribers[monitor.service_key()], "Restoring power resubscribes the physical console through queued network discovery")
	SSnetrun.report_incident("trace", scene.apc_node, null, NETRUN_INCIDENT_HIGH, "Restored station security fixture")
	publisher.publish_slice()
	packet = netrun_security_packet(publisher, monitor, "event")
	TEST_ASSERT_NOTNULL(packet, "Restored consoles can receive new routed alarms")
	packet.deliver()
	TEST_ASSERT_EQUAL(length(monitor.alerts), 2, "Power restoration resumes the physical security journal")

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
	scene.node_b.file_store.capacity = 8
	var/baseline_files = length(scene.node_b.file_store.files)
	TEST_ASSERT(console.queue_file_request("upload", scene.node_b, file.uid), "An initially writable disk admits the ordinary file request")
	var/datum/netrun_request/file/packet = netrun_operation_packet(console, /datum/netrun_request/file)
	var/trace_before = console.intrusion.trace
	scene.node_b.file_store.capacity = 0
	TEST_ASSERT(!packet.deliver(), "A disk that becomes read-only in flight rejects its actual write")
	TEST_ASSERT_EQUAL(length(scene.node_b.file_store.files), baseline_files, "The rejected upload adds no remote file")
	TEST_ASSERT(file in console.inventory.local_store.files, "A failed copy preserves the sender's original")
	TEST_ASSERT_EQUAL(netrun_illegal_delivery_reports(scene.node_b), 0, "An unhandled file write cannot produce an intrusion report")
	TEST_ASSERT_EQUAL(console.intrusion.trace, trace_before, "Failed disk writes preserve the existing no-trace behavior")
	scene.node_b.file_store.capacity = 8
	console.next_command = world.time
	TEST_ASSERT(console.queue_file_request("upload", scene.node_b, file.uid), "A repaired destination admits a new upload")
	packet = netrun_operation_packet(console, /datum/netrun_request/file)
	TEST_ASSERT(packet.deliver(), "The actual upload succeeds after free space returns")
	TEST_ASSERT_EQUAL(netrun_illegal_delivery_reports(scene.node_b), 1, "Successful acquired-access file writes emit exactly one report")
	TEST_ASSERT_EQUAL(console.intrusion.trace, trace_before + 3 * scene.node_b.get_security(), "The file wrapper must not add a second trace charge")
	var/datum/netrun_file/remote_copy
	for(var/datum/netrun_file/candidate as anything in scene.node_b.file_store.files)
		if(candidate.name == file.name && candidate.kind == file.kind)
			remote_copy = candidate
			break
	TEST_ASSERT_NOTNULL(remote_copy, "The successful upload owns a real independent remote file")
	console.next_command = world.time
	TEST_ASSERT(console.queue_file_request("download", scene.node_b, remote_copy.uid), "The real remote file initially admits a download")
	packet = netrun_operation_packet(console, /datum/netrun_request/file)
	TEST_ASSERT(scene.node_b.file_store.remove(remote_copy), "The fixture withdraws the exact source after dispatch without deleting its pending packet")
	trace_before = console.intrusion.trace
	var/local_files_before = length(console.inventory.local_store.files)
	TEST_ASSERT(!packet.deliver(), "A source withdrawn after dispatch cannot be downloaded")
	TEST_ASSERT_EQUAL(netrun_illegal_delivery_reports(scene.node_b), 1, "A missing UID does not create a duplicate intrusion report")
	TEST_ASSERT_EQUAL(console.intrusion.trace, trace_before, "The rejected missing-file delivery cannot spend a success trace charge")
	TEST_ASSERT_EQUAL(length(console.inventory.local_store.files), local_files_before, "The rejected download cannot create a local copy")
	qdel(remote_copy)
