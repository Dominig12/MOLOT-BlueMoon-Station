/// Real machine components and timers exercise discovery and delivery together.
/obj/machinery/netrun_server/transport_fixture/netrun_machine_service_types()
	return ..() + list(/datum/netrun_machine_service/transport_fixture)

/datum/netrun_machine_service/transport_fixture
	service_id = "transport.fixture"
	var/received = 0
	var/list/last_payload
	var/received_at
	var/match_checks = 0

/datum/netrun_machine_service/transport_fixture/matches(datum/netrun_machine_service/source_service, recipient_tag)
	match_checks++
	return ..()

/datum/netrun_machine_service/transport_fixture/receive(datum/netrun_machine_message/message)
	received++
	received_at = world.time
	last_payload = deepCopyList(message.payload)
	if(message.payload["reply"])
		message.reply(new /datum/netrun_machine_message(list("answer" = message.payload["value"])))
	return TRUE

/datum/netrun_machine_message/transport_fixture
	var/list/outcomes

/datum/netrun_machine_message/transport_fixture/New(list/payload, list/outcomes)
	..(payload)
	src.outcomes = outcomes

/datum/netrun_machine_message/transport_fixture/copy()
	var/datum/netrun_machine_message/transport_fixture/result = ..()
	result.outcomes = outcomes
	return result

/datum/netrun_machine_message/transport_fixture/failed(reason)
	if(outcomes)
		outcomes["failed"] = (outcomes["failed"] || 0) + 1
		outcomes["reason"] = reason

/datum/netrun_machine_message/transport_fixture/delivered(datum/netrun_machine_service/recipient_service)
	if(outcomes)
		outcomes["delivered"] = (outcomes["delivered"] || 0) + 1
		outcomes["at"] = world.time

/// Observe native receiver admission without requiring the rest of its radio chain.
/obj/machinery/telecomms/receiver/prerelease_fixture
	var/received_packets = 0

/obj/machinery/telecomms/receiver/prerelease_fixture/receive_signal(datum/signal/subspace/signal)
	received_packets++

/obj/machinery/atmospherics/components/unary/vent_pump/prerelease_poll_fixture
	var/status_polls = 0

/obj/machinery/atmospherics/components/unary/vent_pump/prerelease_poll_fixture/receive_signal(datum/signal/signal)
	if("status" in signal.data)
		status_polls++
	return ..()

/// Discovery completion replays its queued poll; it must not generate another one.
/datum/unit_test/netrun_transport_atmos_poll_no_echo/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/machinery/airalarm/alarm = scene.machine(/obj/machinery/airalarm, scene.source_spot)
	var/obj/machinery/atmospherics/components/unary/vent_pump/prerelease_poll_fixture/vent = scene.machine(/obj/machinery/atmospherics/components/unary/vent_pump/prerelease_poll_fixture, scene.target_spot)
	TEST_ASSERT(alarm.send_signal(vent.id_tag, list("status" = TRUE)), "A cold native status poll must be admitted")
	var/deadline = world.time + 4 SECONDS
	while(!alarm.netrun_vent_info[vent.id_tag] && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT(alarm.netrun_vent_info[vent.id_tag], "The native poll must return real vent telemetry")
	sleep(1 SECONDS)
	TEST_ASSERT_EQUAL(vent.status_polls, 1, "A cold DNS completion must not echo the already replayed native poll")

/// Two real sectors, joined only by the native telecommunications relay/hub link.
/datum/netrun_communication_scene
	parent_type = /datum/netrun_transport_scene
	var/obj/item/radio/radio
	var/obj/machinery/telecomms/relay/relay
	var/obj/machinery/telecomms/hub/hub
	var/obj/machinery/telecomms/receiver/prerelease_fixture/receiver_port
	var/datum/netrun_machine_service/radio_port
	var/datum/netrun_machine_service/receiver_service

/datum/netrun_communication_scene/New(turf/origin)
	..(origin)
	var/list/levels = multiz_gravity_test_levels()
	mark_station(levels[1])
	var/area/remote_room = room(/area/netrun_route_test)
	var/turf/remote = take(locate(80, 80, levels[1]), remote_room, TRUE)
	var/turf/remote_apc = take(locate(81, 80, levels[1]), remote_room, TRUE)
	machine(/obj/machinery/power/apc, remote_apc)
	dns.forceMove(remote)
	receiver.forceMove(remote)
	radio = new(source_spot)
	owned += radio
	relay = machine(/obj/machinery/telecomms/relay, source_spot)
	hub = machine(/obj/machinery/telecomms/hub, remote)
	receiver_port = machine(/obj/machinery/telecomms/receiver/prerelease_fixture, remote)
	relay.links = list(hub)
	hub.links = list(relay, receiver_port)
	receiver_port.links = list(hub)
	radio_port = radio.get_netrun_machine_service("telecomms.origin")
	receiver_service = receiver_port.get_netrun_machine_service("telecomms.receiver")
	SSnetrun.ensure_topology()

/datum/netrun_communication_scene/proc/signal()
	var/datum/signal/subspace/result = new
	result.source = radio
	result.frequency = FREQ_COMMON
	result.levels = list(radio.z)
	return result

/datum/unit_test/netrun_transport_native_relay_policy/Run()
	var/datum/netrun_communication_scene/scene = allocate(/datum/netrun_communication_scene, run_loc_floor_bottom_left)
	var/datum/signal/subspace/signal = scene.signal()
	allocated += signal
	TEST_ASSERT(scene.radio_port.send("telecomms.receiver", new /datum/netrun_machine_message/telecomms(signal), scene.receiver_service.service_tag()), "Communication discovery must be admitted across a native relay")
	var/deadline = world.time + 4 SECONDS
	while(!scene.receiver_port.received_packets && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT_EQUAL(scene.receiver_port.received_packets, 1, "Cold DNS query, reply and communication must cross telecomms without an NTnet relay")
	var/datum/netrun_machine_transport/transport = SSnetrun.get_machine_transport()
	TEST_ASSERT(!transport.reachable(scene.source, scene.target), "A communication path must not enter the ordinary machine route cache")
	var/datum/component/netrun_node/start = scene.source.resolve_node()
	var/datum/netrun_path_tree/tree = new(SSnetrun.ensure_topology(), start)
	allocated += tree
	TEST_ASSERT(!tree.reached[scene.target.resolve_node().address], "Telecommunications must not widen runner, research or atmosphere topology")
	scene.relay.receiving = FALSE
	TEST_ASSERT(!transport.reachable(scene.radio_port, scene.receiver_service), "A disabled native receive direction must revoke a cached communication route")
	scene.relay.receiving = TRUE
	scene.relay.set_machine_stat(BROKEN)
	TEST_ASSERT(!transport.reachable(scene.radio_port, scene.receiver_service), "Broken native relays must revoke cached communication routes")

/datum/unit_test/netrun_transport_native_relay_delivery_revalidation/Run()
	var/datum/netrun_communication_scene/scene = allocate(/datum/netrun_communication_scene, run_loc_floor_bottom_left)
	var/datum/signal/subspace/signal = scene.signal()
	allocated += signal
	var/datum/netrun_machine_packet/data/packet = new(scene.radio_port, scene.receiver_service, new /datum/netrun_machine_message/telecomms(signal))
	TEST_ASSERT(packet.send(), "A live native relay must admit the communication packet")
	scene.relay.freq_listening = list(FREQ_SCIENCE)
	packet.deliver()
	TEST_ASSERT_EQUAL(scene.receiver_port.received_packets, 0, "A frequency change in flight must reject the packet at delivery")

/datum/unit_test/netrun_transport_atmos_late_controller_registration/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/machinery/atmospherics/components/unary/vent_pump/vent = scene.machine(/obj/machinery/atmospherics/components/unary/vent_pump, scene.target_spot)
	vent.broadcast_status()
	sleep(3 SECONDS)
	var/obj/machinery/airalarm/alarm = scene.machine(/obj/machinery/airalarm, scene.source_spot)
	alarm.buildstage = 2
	var/deadline = world.time + 12 SECONDS
	while(!alarm.netrun_vent_info[vent.id_tag] && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT(alarm.netrun_vent_info[vent.id_tag], "An idle vent must retry after its initial discovery found no air alarm")
	var/received_at = alarm.netrun_vent_info[vent.id_tag]["timestamp"]
	sleep(11 SECONDS)
	TEST_ASSERT_EQUAL(alarm.netrun_vent_info[vent.id_tag]["timestamp"], received_at, "Acknowledged devices must stop periodic registration packets")
	qdel(alarm)
	alarm = scene.machine(/obj/machinery/airalarm, scene.source_spot)
	alarm.buildstage = 2
	deadline = world.time + 12 SECONDS
	while(!alarm.netrun_vent_info[vent.id_tag] && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT(alarm.netrun_vent_info[vent.id_tag], "Deleting and replacing the controller must rearm idle device registration")

/datum/unit_test/netrun_roundstart_telecommunications_placement/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/area/science/server/science = scene.room(/area/science/server)
	var/area/tcommsat/server/telecomms = scene.room(/area/tcommsat/server)
	scene.take(locate(scene.source_spot.x + 3, scene.source_spot.y + 2, scene.source_spot.z), science)
	scene.take(locate(scene.source_spot.x + 4, scene.source_spot.y + 2, scene.source_spot.z), telecomms)
	var/list/saved_areas = GLOB.sortedAreas
	GLOB.sortedAreas = list(science, telecomms)
	var/turf/selected = SSnetrun.find_server_spot()
	GLOB.sortedAreas = saved_areas
	TEST_ASSERT(istype(get_area(selected), /area/tcommsat), "Roundstart DNS and information servers must choose telecommunications before science")
	TEST_ASSERT(SSnetrun.runlevels & RUNLEVEL_LOBBY, "Network preparation must run during the lobby after subsystem initialization")

/datum/netrun_transport_scene
	parent_type = /datum/netrun_route_scene
	var/list/saved_dns
	var/turf/source_spot
	var/turf/target_spot
	var/turf/apc_spot
	var/turf/dns_spot
	var/obj/machinery/netrun_server/transport_fixture/sender
	var/obj/machinery/netrun_server/transport_fixture/receiver
	var/obj/machinery/netrun_server/dns/dns
	var/obj/machinery/power/apc/apc
	var/datum/netrun_machine_service/transport_fixture/source
	var/datum/netrun_machine_service/transport_fixture/target
	var/answer_count = 0
	var/list/previous_delivery_trace

/datum/netrun_transport_scene/proc/answered()
	answer_count++

/// Count only this producer's packets; unrelated station automation may remain active.
/datum/netrun_transport_scene/proc/pending_packets()
	var/count = 0
	for(var/datum/netrun_machine_packet/packet as anything in SSnetrun.get_machine_transport().packets)
		if(packet.source == source && packet.recipient == target)
			count++
	return count

/// Warm DNS must not bypass backpressure for replaceable telemetry.
/datum/unit_test/netrun_transport_replaceable_burst/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/list/outcomes = list()
	for(var/i in 1 to 256)
		TEST_ASSERT(scene.source.send_to(scene.target, new /datum/netrun_machine_message/transport_fixture/queue_snapshot(list("value" = i), outcomes)), "A replaceable snapshot burst must remain admissible")
	TEST_ASSERT_EQUAL(scene.pending_packets(), 1, "256 superseded snapshots must own one transport packet and one delivery task")
	var/datum/netrun_machine_packet/data/latest
	for(var/datum/netrun_machine_packet/data/packet as anything in SSnetrun.get_machine_transport().packets)
		if(packet.source == scene.source && packet.recipient == scene.target)
			latest = packet
	TEST_ASSERT_EQUAL(latest.message.payload["value"], 256, "The retained packet must carry the producer's latest snapshot")
	var/replacement_key = latest.replacement_key
	TEST_ASSERT(replacement_key, "A replaceable delivery must own its bounded coalescing index")
	if(latest.timer_id)
		deltimer(latest.timer_id)
	latest.queue_delivery()
	for(var/i in 257 to 512)
		scene.source.send_to(scene.target, new /datum/netrun_machine_message/transport_fixture/queue_snapshot(list("value" = i), outcomes))
	TEST_ASSERT_EQUAL(scene.pending_packets(), 1, "A ready delivery must also absorb superseded state without adding scheduler tasks")
	TEST_ASSERT_EQUAL(latest.message.payload["value"], 512, "Ready-but-unexecuted state must remain replaceable")
	TEST_ASSERT(netrun_wait_delivery(outcomes), "The retained latest snapshot must actually be delivered")
	TEST_ASSERT_EQUAL(scene.target.received, 1, "Superseded states must not execute the recipient repeatedly")
	TEST_ASSERT_EQUAL(scene.pending_packets(), 0, "Delivered snapshots must release packet capacity")
	TEST_ASSERT_NULL(SSnetrun.get_machine_transport().replaceable_packets[replacement_key], "Completion must release the coalescing index as well as packet capacity")

/// Sustained producers stop, their finite commands complete, and the delivery queue drains.
/datum/unit_test/netrun_transport_sustained_burst_drain/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/list/commands = list()
	var/list/snapshots = list()
	var/peak = 0
	var/started = world.time
	for(var/wave in 1 to 8)
		for(var/i in 1 to 128)
			TEST_ASSERT(scene.source.send_to(scene.target, new /datum/netrun_machine_message/transport_fixture/queue_snapshot(list("value" = wave * 128 + i), snapshots)), "Sustained replaceable state must remain admitted")
		for(var/i in 1 to 4)
			TEST_ASSERT(scene.source.send_to(scene.target, new /datum/netrun_machine_message/transport_fixture(list("command" = wave * 4 + i), commands)), "Finite commands must remain separate from replaceable state")
		peak = max(peak, scene.pending_packets())
		sleep(world.tick_lag)
	var/deadline = world.time + 6 SECONDS
	while(scene.pending_packets() && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT(peak <= 33, "1024 replaceable states plus 32 commands must never retain more than one snapshot and all commands")
	TEST_ASSERT_EQUAL(commands["delivered"], 32, "Every nonreplaceable command must execute exactly once")
	TEST_ASSERT_EQUAL(scene.pending_packets(), 0, "Stopping the producer must drain all owned packet and delivery capacity")
	var/settled = scene.target.received
	sleep(1 SECONDS)
	TEST_ASSERT_EQUAL(scene.target.received, settled, "A quiescent transport must not generate further deliveries")
	log_world("NETRUN LOAD transport: snapshots=1024 commands=32 waves=8 pending_peak=[peak] snapshot_deliveries=[snapshots["delivered"]] drained_ds=[world.time - started] retained_pairs=[length(SSnetrun.get_machine_transport().pair_routes)] roots=[length(SSnetrun.get_machine_transport().route_trees)]")

/// A station-sized working set must survive a complete second pass without rebuilding.
/datum/unit_test/netrun_transport_station_route_working_set/Run()
	var/datum/netrun_routing_cache_scene/scene = allocate(/datum/netrun_routing_cache_scene, run_loc_floor_bottom_left)
	var/list/sources = list()
	var/list/targets = list()
	for(var/i in 1 to 64)
		var/obj/machinery/netrun_server/transport_fixture/sender = scene.machine(/obj/machinery/netrun_server/transport_fixture, scene.source_spot)
		var/obj/machinery/netrun_server/transport_fixture/receiver = scene.machine(/obj/machinery/netrun_server/transport_fixture, scene.remote_spot)
		sources += sender.get_netrun_machine_service("transport.fixture")
		targets += receiver.get_netrun_machine_service("transport.fixture")
	SSnetrun.ensure_topology()
	var/datum/netrun_machine_transport/transport = SSnetrun.get_machine_transport()
	var/list/retained = list()
	var/started = REALTIMEOFDAY
	for(var/datum/netrun_machine_service/source as anything in sources)
		for(var/datum/netrun_machine_service/target as anything in targets)
			var/datum/netrun_machine_path/path = transport.borrowed_path(source, target)
			TEST_ASSERT(path, "Every source/target pair must have a physical path")
			retained += WEAKREF(path)
		CHECK_TICK
	var/index = 0
	for(var/datum/netrun_machine_service/source as anything in sources)
		for(var/datum/netrun_machine_service/target as anything in targets)
			var/datum/weakref/previous = retained[++index]
			TEST_ASSERT_EQUAL(transport.borrowed_path(source, target), previous.resolve(), "4096 active machine pairs must retain their cached paths across a full station poll")
		CHECK_TICK
	log_world("NETRUN LOAD routing: sources=64 targets=64 pairs=4096 polls=2 elapsed_ms=[(REALTIMEOFDAY - started) * 100] retained_pairs=[length(transport.pair_routes)] roots=[length(transport.route_trees)]")

/datum/netrun_transport_scene/New(turf/origin, with_dns = TRUE, with_apc = TRUE)
	..(origin.z)
	var/datum/netrun_machine_transport/transport = SSnetrun.get_machine_transport()
	previous_delivery_trace = transport.delivery_trace
	saved_dns = transport.by_id["dns"]
	transport.by_id["dns"] = list()
	var/area/room = room(/area/netrun_route_test)
	for(var/turf/spot as anything in block(origin, locate(origin.x + 4, origin.y + 2, origin.z)))
		take(spot, room)
	source_spot = origin
	target_spot = get_step(origin, EAST)
	apc_spot = get_step(origin, NORTH)
	dns_spot = get_step(target_spot, NORTH)
	if(with_apc)
		apc = machine(/obj/machinery/power/apc, apc_spot)
	sender = machine(/obj/machinery/netrun_server/transport_fixture, source_spot)
	receiver = machine(/obj/machinery/netrun_server/transport_fixture, target_spot)
	if(with_dns)
		dns = machine(/obj/machinery/netrun_server/dns, dns_spot)
	source = sender.get_netrun_machine_service("transport.fixture")
	target = receiver.get_netrun_machine_service("transport.fixture")
	SSnetrun.ensure_topology()

/datum/netrun_transport_scene/Destroy()
	. = ..()
	SSnetrun.get_machine_transport().by_id["dns"] = saved_dns
	SSnetrun.get_machine_transport().delivery_trace = previous_delivery_trace
	saved_dns = null
	source = null
	target = null
	sender = null
	receiver = null
	dns = null
	apc = null

/datum/unit_test/proc/netrun_wait_delivery(list/outcomes, timeout = 5 SECONDS)
	var/deadline = world.time + timeout
	while(!outcomes["delivered"] && !outcomes["failed"] && world.time < deadline)
		sleep(world.tick_lag)
	return outcomes["delivered"]

/// Cold DNS must really deliver a packet, rather than just admit it to a queue.
/datum/unit_test/netrun_transport_cold_delivery/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	TEST_ASSERT(scene.source && scene.target, "Both physical machines must register services")
	var/list/outcomes = list()
	var/started = world.time
	TEST_ASSERT(scene.source.send("transport.fixture", new /datum/netrun_machine_message/transport_fixture(list("value" = 42), outcomes), scene.target.service_tag()), "A cold request must be admitted")
	TEST_ASSERT(netrun_wait_delivery(outcomes), "Cold DNS/data delivery failed: [outcomes["reason"]]")
	TEST_ASSERT_EQUAL(scene.target.received, 1, "The destination must receive exactly once")
	TEST_ASSERT_EQUAL(scene.target.last_payload["value"], 42, "The wire payload must survive discovery")
	TEST_ASSERT(outcomes["at"] - started <= 1 SECONDS, "A short local machine exchange must complete within one second")
	TEST_ASSERT_EQUAL(length(scene.source.resolutions), 0, "Completed discovery must retire its pending query")
	TEST_ASSERT(length(scene.source.directory), "The actual DNS reply must populate its caller's cache")

/// A cached query sends data immediately; a request/reply does not start another DNS loop.
/datum/unit_test/netrun_transport_cached_reply/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/list/first = list()
	scene.source.send("transport.fixture", new /datum/netrun_machine_message/transport_fixture(list("value" = 1), first), scene.target.service_tag())
	TEST_ASSERT(netrun_wait_delivery(first), "Initial discovery must succeed before checking cache reuse")
	var/list/second = list()
	var/started = world.time
	scene.source.send("transport.fixture", new /datum/netrun_machine_message/transport_fixture(list("value" = 2, "reply" = TRUE), second), scene.target.service_tag())
	TEST_ASSERT_EQUAL(length(scene.source.resolutions), 0, "Fresh cached discovery must not issue another query")
	TEST_ASSERT(netrun_wait_delivery(second), "Cached delivery must succeed")
	var/deadline = world.time + 1 SECONDS
	while(!scene.source.received && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT_EQUAL(scene.source.last_payload?["answer"], 2, "The reply must return to the real source service")
	TEST_ASSERT(world.time - started <= 1 SECONDS, "An established local request/reply must not have gameplay animation delays")

/// Machines created before their infrastructure must attach without a thirty-second poll.
/datum/unit_test/netrun_transport_late_infrastructure/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left, FALSE, FALSE)
	var/list/outcomes = list()
	scene.source.send("transport.fixture", new /datum/netrun_machine_message/transport_fixture(list("value" = "late"), outcomes), scene.target.service_tag())
	scene.apc = scene.machine(/obj/machinery/power/apc, scene.apc_spot)
	scene.dns = scene.machine(/obj/machinery/netrun_server/dns, scene.dns_spot)
	var/ready_at = world.time
	TEST_ASSERT(netrun_wait_delivery(outcomes), "A pending exchange must recover when its APC and DNS appear")
	TEST_ASSERT(outcomes["at"] - ready_at <= 1 SECONDS, "DNS registration must wake queued discovery, rather than wait for an old retry deadline")

/// Replacing a generic early component must preserve its published services and routes.
/datum/unit_test/netrun_transport_component_replacement/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/datum/netrun_machine_service/previous = scene.source
	var/datum/component/netrun_node/replacement = scene.sender.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL, list(), 3)
	TEST_ASSERT_EQUAL(scene.sender.get_netrun_machine_service("transport.fixture"), previous, "Component replacement must preserve the service identity")
	TEST_ASSERT_EQUAL(previous.node, replacement, "The published service must move to the new component")
	TEST_ASSERT(!QDELETED(previous), "Old component teardown must not remove the replacement's service")
	var/list/outcomes = list()
	previous.send("transport.fixture", new /datum/netrun_machine_message/transport_fixture(list("value" = "rebound"), outcomes), scene.target.service_tag())
	TEST_ASSERT(netrun_wait_delivery(outcomes), "A rebound service must perform actual DNS and delivery")

/// A power loss after admission must fail once, with a useful route failure reason.
/datum/unit_test/netrun_transport_route_failure/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/list/outcomes = list()
	var/datum/netrun_machine_packet/data/packet = new(scene.source, scene.target, new /datum/netrun_machine_message/transport_fixture(list(), outcomes))
	TEST_ASSERT(packet.send(), "The initial physical route must be usable")
	scene.apc.set_machine_stat(BROKEN)
	packet.deliver()
	TEST_ASSERT_EQUAL(outcomes["failed"], 1, "A lost route must fail its message once")
	TEST_ASSERT(outcomes["reason"] && !outcomes["delivered"], "Failure must report its cause without acknowledging delivery")
	TEST_ASSERT_EQUAL(scene.target.received, 0, "There is no direct receive fallback after a cable failure")

/// A client must not route through a partially initialized map or exhaust its retry budget there.
/datum/unit_test/netrun_transport_mapload_barrier/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/list/outcomes = list()
	SSatoms.map_loader_begin()
	scene.sender.set_machine_stat(NOPOWER)
	scene.source.send("transport.fixture", new /datum/netrun_machine_message/transport_fixture(list("value" = "startup"), outcomes), scene.target.service_tag())
	var/query_key = "transport.fixture|[scene.target.service_tag()]"
	var/datum/netrun_machine_resolution/query = scene.source.resolutions[query_key]
	var/deferred = query && !query.resolver && query.attempts == 0
	scene.sender.set_machine_stat(0)
	SSatoms.map_loader_stop()
	SSnetrun.get_machine_transport().prepare_network()
	TEST_ASSERT(deferred, "Mapload requests must wait for native initialization without spending DNS retries")
	TEST_ASSERT(netrun_wait_delivery(outcomes), "Finishing bootstrap must resume the original request")

/// A missing DNS is distinguishable from a lost cable or a rejected receiver.
/datum/unit_test/netrun_transport_missing_dns_reason/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left, FALSE)
	var/list/outcomes = list()
	scene.source.send("transport.fixture", new /datum/netrun_machine_message/transport_fixture(list(), outcomes), scene.target.service_tag())
	var/query_key = "transport.fixture|[scene.target.service_tag()]"
	var/datum/netrun_machine_resolution/query = scene.source.resolutions[query_key]
	for(var/i in 1 to 5)
		if(!QDELETED(query))
			query.next_attempt_at = world.time
			query.begin()
	TEST_ASSERT_EQUAL(outcomes["failed"], 1, "An exhausted discovery must fail once")
	TEST_ASSERT(findtext(outcomes["reason"], "не зарегистрирован"), "The failure must identify missing DNS rather than an unexplained timeout")
	TEST_ASSERT_EQUAL(length(scene.source.resolutions), 0, "Failed discovery must not leave a dangling queue")

/// Exact recipient discovery must not scan every device of the same service type.
/datum/unit_test/netrun_transport_tag_index/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/list/extras = list()
	for(var/i in 1 to 20)
		var/obj/machinery/netrun_server/transport_fixture/extra = scene.machine(/obj/machinery/netrun_server/transport_fixture, scene.source_spot)
		extras += extra.get_netrun_machine_service("transport.fixture")
	var/list/result = SSnetrun.get_machine_transport().lookup(scene.source, "transport.fixture", scene.target.service_tag())
	TEST_ASSERT_EQUAL(length(result), 1, "Tagged discovery must return the intended endpoint")
	TEST_ASSERT_EQUAL(result[1], scene.target, "The tag index must identify the real service")
	for(var/datum/netrun_machine_service/transport_fixture/extra as anything in extras)
		TEST_ASSERT_EQUAL(extra.match_checks, 0, "Unrelated endpoint authorization must not run during exact-address lookup")
	var/old_tag = scene.target.service_tag()
	scene.receiver.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
	TEST_ASSERT_EQUAL(length(SSnetrun.get_machine_transport().lookup(scene.source, "transport.fixture", old_tag)), 0, "Replacing an address must remove its old index entry")
	TEST_ASSERT_EQUAL(length(SSnetrun.get_machine_transport().lookup(scene.source, "transport.fixture", scene.target.service_tag())), 1, "The replacement must be discoverable immediately")

/// Every actual data hop has metadata, while payloads never leak into node packet journals.
/datum/unit_test/netrun_transport_packet_journal/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/list/outcomes = list()
	scene.source.send("transport.fixture", new /datum/netrun_machine_message/transport_fixture(list("private" = "SECRET_PACKET_BODY"), outcomes), scene.target.service_tag())
	TEST_ASSERT(netrun_wait_delivery(outcomes), "The journal scenario must really deliver a message")
	var/packet_id
	for(var/list/entry as anything in scene.source.node.packet_logs)
		if(entry["kind"] == "machine" && entry["phase"] == "SEND")
			packet_id = entry["id"]
	TEST_ASSERT(packet_id, "The sender must record an identifiable packet")
	var/datum/component/netrun_node/apc_node = scene.apc.GetComponent(/datum/component/netrun_node)
	var/forwarded = FALSE
	for(var/list/entry as anything in apc_node.packet_logs)
		if(entry["id"] == packet_id && entry["phase"] == "FORWARD")
			forwarded = TRUE
	TEST_ASSERT(forwarded, "The actual forwarding APC must journal the same packet")
	var/accepted = FALSE
	for(var/list/entry as anything in scene.target.node.packet_logs)
		if(entry["id"] == packet_id && entry["phase"] == "ACCEPT")
			accepted = TRUE
	TEST_ASSERT(accepted, "The recipient must distinguish receipt from acceptance")
	TEST_ASSERT(!findtext(json_encode(scene.target.node.packet_logs), "SECRET_PACKET_BODY"), "Node metadata must not expose private message contents")
	for(var/i in 1 to NETRUN_MAX_PACKET_LOG + 20)
		scene.target.node.add_packet_log(i, "SEND", "machine", "A", "B", "fixture")
	TEST_ASSERT_EQUAL(length(scene.target.node.packet_logs), NETRUN_MAX_PACKET_LOG, "Per-node packet history must remain bounded")

/// Actual PDA -> receiver -> bus -> processor -> bus -> message server -> hub,
/// relay probe/return -> broadcaster -> PDA, using cold DNS and native messenger.
/datum/unit_test/netrun_transport_pda_chain/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/item/modular_computer/pda/sender = allocate(/obj/item/modular_computer/pda, scene.source_spot)
	var/obj/item/modular_computer/pda/recipient = allocate(/obj/item/modular_computer/pda, scene.target_spot)
	sender.enabled = TRUE
	recipient.enabled = TRUE
	sender.toff = FALSE
	recipient.toff = FALSE
	sender.imprint_id("Transport sender", "Assistant")
	recipient.imprint_id("Transport recipient", "Assistant")
	var/datum/computer_file/program/messenger/sending = locate(/datum/computer_file/program/messenger) in sender.get_all_files()
	var/datum/computer_file/program/messenger/receiving = locate(/datum/computer_file/program/messenger) in recipient.get_all_files()
	TEST_ASSERT(sending && receiving && sending.computer == sender && receiving.computer == recipient, "The native PDAs must contain real installed messenger programs")
	TEST_ASSERT(GLOB.pda_messengers[REF(sending)] == sending && GLOB.pda_messengers[REF(receiving)] == receiving, "Native imprinting must publish both messenger contacts")
	sending.alert_able = FALSE
	receiving.alert_able = FALSE
	var/obj/machinery/telecomms/receiver/receiver = scene.machine(/obj/machinery/telecomms/receiver, scene.source_spot)
	var/obj/machinery/telecomms/bus/bus = scene.machine(/obj/machinery/telecomms/bus, scene.source_spot)
	var/obj/machinery/telecomms/processor/processor = scene.machine(/obj/machinery/telecomms/processor, scene.source_spot)
	var/obj/machinery/telecomms/message_server/server = scene.machine(/obj/machinery/telecomms/message_server, scene.target_spot)
	var/obj/machinery/telecomms/hub/hub = scene.machine(/obj/machinery/telecomms/hub, scene.target_spot)
	var/obj/machinery/telecomms/relay/relay = scene.machine(/obj/machinery/telecomms/relay, scene.target_spot)
	var/obj/machinery/telecomms/broadcaster/broadcaster = scene.machine(/obj/machinery/telecomms/broadcaster, scene.target_spot)
	receiver.links = list(bus)
	bus.links = list(processor, server)
	processor.links = list(bus)
	server.links = list(hub)
	hub.links = list(relay, broadcaster)
	relay.links = list(hub)
	SSnetrun.get_machine_transport().delivery_trace = list()
	var/start = world.time
	TEST_ASSERT(sending.send_message(sender, "Real routed message", list(receiving)), "The native PDA must admit a routed transmission")
	var/deadline = world.time + 5 SECONDS
	while(sending.netrun_pending_messages && world.time < deadline)
		sleep(world.tick_lag)
	log_world("NETRUN LOAD PDA: elapsed_ds=[world.time - start] hops=[json_encode(SSnetrun.get_machine_transport().delivery_trace)]")
	var/list/rejections = list()
	for(var/atom/device as anything in scene.owned + list(sender, recipient))
		var/datum/component/netrun_node/node = device.GetComponent(/datum/component/netrun_node)
		for(var/list/entry as anything in node?.packet_logs)
			if(entry["phase"] in list("REJECT", "DROP", "DNS_FAIL"))
				rejections += "[device.type]: [json_encode(entry)]"
	TEST_ASSERT(!sending.netrun_delivery_error && !sending.netrun_pending_messages, "The native delivery must finish successfully: [sending.netrun_delivery_status]; [jointext(rejections, "; ")]")
	var/datum/pda_chat/chat = receiving.find_chat_by_recipient(REF(sending))
	TEST_ASSERT_EQUAL(length(chat?.messages), 1, "The actual recipient must receive one chat message")
	var/datum/pda_message/message = chat.messages[1]
	TEST_ASSERT_EQUAL(message.message, "Real routed message", "The full telecomms route must preserve its payload")
	TEST_ASSERT_EQUAL(length(sending.find_chat_by_recipient(REF(receiving))?.messages), 1, "Only actual receipt must commit one outgoing message")
	TEST_ASSERT_EQUAL(length(server.pda_msgs), 2, "The real message server must log the transmission once, in addition to its startup notice")
	TEST_ASSERT(world.time - start <= 2 SECONDS, "A cold multi-machine PDA route must not accumulate multi-second gameplay delays at every hop")

/// Native camera discovery/handshake must survive construction before its tag is assigned.
/datum/unit_test/netrun_transport_camera_handshake/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/machinery/computer/security/console = scene.machine(/obj/machinery/computer/security, scene.source_spot)
	var/obj/machinery/camera/camera = scene.machine(/obj/machinery/camera, scene.target_spot)
	camera.c_tag = "Transport camera"
	camera.network = list("ss13")
	console.network = list("ss13")
	var/datum/netrun_machine_service/camera_viewer/viewer = console.get_netrun_machine_service("camera.viewer")
	var/started = world.time
	TEST_ASSERT(viewer.request_feed(camera.c_tag), "The camera handshake must be admitted")
	var/deadline = world.time + 3 SECONDS
	while(console.active_camera != camera && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT_EQUAL(console.active_camera, camera, "The native console must acquire the camera through real DNS and a reply")
	TEST_ASSERT(world.time - started <= 1 SECONDS, "A local camera handshake must not use runner animation latency")
	scene.apc.set_machine_stat(BROKEN)
	TEST_ASSERT(!viewer.feed_available(), "A broken actual cable must revoke an established feed")

/// Delivered atmospheric telemetry is controller-local, with matching area/channel policy.
/datum/unit_test/netrun_transport_atmos_status/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/machinery/airalarm/alarm = scene.machine(/obj/machinery/airalarm, scene.source_spot)
	var/obj/machinery/atmospherics/components/unary/vent_pump/vent = scene.machine(/obj/machinery/atmospherics/components/unary/vent_pump, scene.target_spot)
	alarm.buildstage = 2
	vent.id_tag = "TRANSPORT-VENT"
	var/datum/netrun_machine_service/atmos/device/service = vent.get_netrun_machine_service("atmos.device")
	TEST_ASSERT(service, "The real vent must publish its machine service")
	TEST_ASSERT(vent.netrun_atmos_send("atmos.device", "atmos.controller", list("sigtype" = "status", "device" = "VP", "tag" = vent.id_tag, "power" = TRUE)), "Native atmosphere status must enter the transport")
	var/deadline = world.time + 3 SECONDS
	while(!alarm.netrun_vent_info[vent.id_tag] && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT(alarm.netrun_vent_info[vent.id_tag], "The actual controller must receive its own vent's routed status")

/// Research uses a delivered cache and subscribes to server changes over the same wire.
/datum/unit_test/netrun_transport_research_snapshot/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/machinery/rnd/server/server = scene.machine(/obj/machinery/rnd/server, scene.target_spot)
	var/obj/machinery/computer/rdconsole/console = scene.machine(/obj/machinery/computer/rdconsole, scene.source_spot)
	TEST_ASSERT(server.stored_research && console.stored_research, "Native late initialization must bind the research machines")
	TEST_ASSERT_EQUAL(server.stored_research, console.stored_research, "The scene must share a logical research authority")
	console.request_research_snapshot()
	var/deadline = world.time + 3 SECONDS
	while(!console.netrun_research_cache && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT(console.netrun_research_cache, "Initial research data must arrive despite late service creation")
	TEST_ASSERT(console.netrun_research_cache != server.stored_research, "The UI must keep a delivered cache instead of a direct authority reference")
	var/datum/netrun_machine_service/research_client/client = console.get_netrun_machine_service("research.client")
	var/previous = client.snapshot_revision
	server.stored_research.netrun_research_changed()
	deadline = world.time + 3 SECONDS
	while(client.snapshot_revision == previous && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT(client.snapshot_revision > previous, "Authoritative changes must push a new delivered research snapshot")

/// Losing the resolver during an actual query settles the original transaction once.
/datum/unit_test/netrun_transport_dns_deleted/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/list/outcomes = list()
	scene.source.send("transport.fixture", new /datum/netrun_machine_message/transport_fixture(list(), outcomes), scene.target.service_tag())
	qdel(scene.dns)
	TEST_ASSERT_EQUAL(outcomes["failed"], 1, "Deleting an in-flight DNS host must report exactly one failure")
	TEST_ASSERT(findtext(outcomes["reason"], "DNS:"), "DNS cancellation must retain the failed discovery stage")
	TEST_ASSERT_EQUAL(length(scene.source.resolutions), 0, "Deleting the resolver must release the pending query")
	TEST_ASSERT_EQUAL(scene.target.received, 0, "An abandoned DNS query must not deliver its data")

/// Both native manufacturing adapters must receive their own delivered research cache.
/datum/unit_test/netrun_transport_manufacturing_snapshot/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/machinery/rnd/server/server = scene.machine(/obj/machinery/rnd/server, scene.target_spot)
	var/obj/machinery/rnd/production/protolathe/lathe = scene.machine(/obj/machinery/rnd/production/protolathe, scene.source_spot)
	var/obj/machinery/mecha_part_fabricator/fabricator = scene.machine(/obj/machinery/mecha_part_fabricator, scene.source_spot)
	var/datum/netrun_machine_service/research_client/lathe_client = lathe.get_netrun_machine_service("research.client")
	var/datum/netrun_machine_service/research_client/fabricator_client = fabricator.get_netrun_machine_service("research.client")
	TEST_ASSERT(lathe_client.request() && fabricator_client.request(), "Both native machines must admit research discovery")
	var/deadline = world.time + 3 SECONDS
	while((lathe_client.snapshot_revision < 0 || fabricator_client.snapshot_revision < 0) && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT(lathe_client.snapshot_revision >= 0 && fabricator_client.snapshot_revision >= 0, "Both native manufacturing caches must arrive through actual packets")
	TEST_ASSERT(lathe.stored_research != server.stored_research && fabricator.stored_research != server.stored_research, "Manufacturing caches must not alias the authoritative techweb")
	TEST_ASSERT_EQUAL(length(lathe.stored_research.researched_nodes), length(server.stored_research.researched_nodes), "The lathe must receive the server's research nodes")
	for(var/id in fabricator.stored_research.researched_designs)
		var/datum/design/design = SSresearch.techweb_design_by_id(id)
		TEST_ASSERT(design.build_type & MECHFAB, "The real mechfab must retain its native recipe filter")

/// Unique external mail travels to real consoles; an answer returns to one canonical record.
/datum/unit_test/netrun_transport_communications_answer/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/machinery/computer/communications/ingress = scene.machine(/obj/machinery/computer/communications, scene.source_spot)
	var/obj/machinery/computer/communications/terminal = scene.machine(/obj/machinery/computer/communications, scene.target_spot)
	terminal.authenticated = TRUE
	var/mob/living/carbon/human/user = allocate(/mob/living/carbon/human, scene.target_spot)
	var/datum/comm_message/canonical = allocate(/datum/comm_message, "Transport question", "Choose an answer", list("Yes", "No"))
	canonical.answer_callback = CALLBACK(scene, TYPE_PROC_REF(/datum/netrun_transport_scene, answered))
	var/datum/netrun_machine_service/communications_gateway/gateway = ingress.get_netrun_machine_service("communications.gateway")
	gateway.broadcast(canonical, FALSE, TRUE)
	var/deadline = world.time + 3 SECONDS
	while(!length(terminal.messages) && world.time < deadline)
		sleep(world.tick_lag)
	var/datum/comm_message/inbox = terminal.messages[1]
	TEST_ASSERT(inbox && inbox != canonical, "The console must receive its own packet-delivered inbox copy")
	TEST_ASSERT_EQUAL(inbox.title, canonical.title, "Inbox delivery must preserve message data")
	TEST_ASSERT(terminal.queue_netrun_answer(inbox, 1, user), "The authenticated answer must enter the actual return route")
	while(!inbox.answered && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT_EQUAL(canonical.answered, 1, "The original ingress record must receive the answer")
	TEST_ASSERT_EQUAL(inbox.answered, 1, "The answer acknowledgement must return to the console")
	TEST_ASSERT(!inbox.netrun_answer_pending, "Acknowledged answers must clear the UI's pending state")
	TEST_ASSERT_EQUAL(scene.answer_count, 1, "A unique message callback must run once")
	terminal.queue_netrun_answer(inbox, 2, user)
	sleep(0.5 SECONDS)
	TEST_ASSERT_EQUAL(canonical.answered, 1, "A duplicate answer must not overwrite the canonical choice")
	TEST_ASSERT_EQUAL(scene.answer_count, 1, "A repeated answer must not repeat the external callback")

/// Startup signal storms must not turn a timed retry budget into a handful of ticks.
/datum/unit_test/netrun_transport_event_retry_budget/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left, FALSE)
	var/list/outcomes = list()
	scene.source.send("transport.fixture", new /datum/netrun_machine_message/transport_fixture(list(), outcomes), scene.target.service_tag())
	var/datum/netrun_machine_resolution/query = scene.source.resolutions["transport.fixture|[scene.target.service_tag()]"]
	for(var/i in 1 to 8)
		scene.machine(/obj/machinery/netrun_server/transport_fixture, scene.source_spot)
		SSnetrun.get_machine_transport().wake_resolutions()
		sleep(world.tick_lag)
	TEST_ASSERT(!QDELETED(query) && !outcomes["failed"], "Unrelated registration and power events must not exhaust DNS retries")
	TEST_ASSERT_EQUAL(query.attempts, 1, "Early readiness probes must preserve the original two-second deadline")
	scene.dns = scene.machine(/obj/machinery/netrun_server/dns, scene.dns_spot)
	TEST_ASSERT(netrun_wait_delivery(outcomes), "The original queued message must recover when DNS finally registers")

/// Preloaded drive software must bind without ever opening its UI, including reinstallation.
/datum/unit_test/netrun_transport_preloaded_messenger/Run()
	var/obj/item/modular_computer/tablet/computer = allocate(/obj/item/modular_computer/tablet, run_loc_floor_bottom_left)
	var/obj/item/computer_hardware/hard_drive/drive = allocate(/obj/item/computer_hardware/hard_drive, run_loc_floor_bottom_left)
	var/datum/computer_file/program/messenger/app = new
	TEST_ASSERT(drive.store_file(app), "The detached drive must accept a preloaded messenger")
	TEST_ASSERT(!app.computer && !GLOB.pda_messengers[REF(app)], "Detached software must not publish a contact")
	computer.install_component(drive)
	TEST_ASSERT_EQUAL(drive.holder, computer, "The native tablet must accept the preloaded drive")
	TEST_ASSERT_EQUAL(app.computer, computer, "Installing a populated drive must bind its programs")
	TEST_ASSERT_EQUAL(GLOB.pda_messengers[REF(app)], app, "A preloaded messenger must register before its UI opens")
	var/datum/netrun_machine_service/service = computer.get_netrun_machine_service("pda.messenger")
	TEST_ASSERT_EQUAL(service.indexed_tag, REF(app), "The installed program must have a current DNS index")
	computer.uninstall_component(drive)
	TEST_ASSERT(!app.computer && !GLOB.pda_messengers[REF(app)], "Removing the drive must detach its contact and host")
	TEST_ASSERT(isnull(service.indexed_tag), "Removing the drive must retire its old DNS tag")
	computer.install_component(drive)
	TEST_ASSERT_EQUAL(GLOB.pda_messengers[REF(app)], app, "Reinstallation must restore the contact without duplicate signal listeners")
	TEST_ASSERT_EQUAL(service.indexed_tag, REF(app), "Reinstallation must republish the actual program")
	computer.update_id_imprint(null, null)
	TEST_ASSERT(!GLOB.pda_messengers[REF(app)], "A reinstalled program must receive native imprint-reset signals")
	computer.update_id_imprint("Reinstalled sender", "Assistant")
	TEST_ASSERT_EQUAL(GLOB.pda_messengers[REF(app)], app, "Native imprint updates must restore its contact")

/// Removing/replacing an app in an installed HDD must update both native and DNS directories.
/datum/unit_test/netrun_transport_messenger_replacement/Run()
	var/obj/item/modular_computer/pda/computer = allocate(/obj/item/modular_computer/pda, run_loc_floor_bottom_left)
	var/obj/item/computer_hardware/hard_drive/drive = computer.all_components[MC_HDD]
	var/datum/computer_file/program/messenger/previous = locate(/datum/computer_file/program/messenger) in computer.get_all_files()
	TEST_ASSERT(drive && previous, "The native PDA must install a real HDD messenger")
	var/datum/netrun_machine_service/service = computer.get_netrun_machine_service("pda.messenger")
	computer.active_program = previous
	previous.program_state = PROGRAM_STATE_ACTIVE
	TEST_ASSERT(drive.remove_file(previous), "Removing the installed app must succeed")
	TEST_ASSERT(!computer.active_program && previous.program_state == PROGRAM_STATE_KILLED, "Removing a running app must retire its active execution before unbinding")
	TEST_ASSERT(!previous.computer && !GLOB.pda_messengers[REF(previous)], "Removed software must leave no live contact")
	TEST_ASSERT(isnull(service.indexed_tag), "Removed software must leave no old DNS tag")
	qdel(previous)
	var/datum/computer_file/program/messenger/replacement = new
	TEST_ASSERT(drive.store_file(replacement), "The installed HDD must accept its replacement app")
	TEST_ASSERT_EQUAL(replacement.computer, computer, "The new app must bind to its physical computer immediately")
	TEST_ASSERT_EQUAL(GLOB.pda_messengers[REF(replacement)], replacement, "The replacement must publish before opening its UI")
	TEST_ASSERT_EQUAL(service.indexed_tag, REF(replacement), "DNS must publish the replacement program's identity")
	computer.idle_threads |= replacement
	replacement.program_state = PROGRAM_STATE_BACKGROUND
	TEST_ASSERT(drive.remove_file(replacement), "Removing a background app must succeed")
	TEST_ASSERT(!(replacement in computer.idle_threads) && replacement.program_state == PROGRAM_STATE_KILLED, "Removed software must not remain in the computer's background execution list")
	qdel(replacement)
