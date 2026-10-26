/// Delivery fixtures keep their observations outside the packet's owned lifetime.
/datum/netrun_request/delivery/netrun_queue_probe
	var/list/observations = list()
	var/pause = 0

/datum/netrun_request/delivery/netrun_queue_probe/execute()
	observations += "start"
	if(pause)
		sleep(pause)
	observations += cancelled ? "cancelled" : "finish"
	return !cancelled

/// Ready I/O wakes the existing worker; quiet maintenance keeps its ordinary cadence.
/datum/unit_test/netrun_delivery_worker_wake/Run()
	var/datum/controller/subsystem/netrun/netrun_execution_test/worker = allocate(/datum/controller/subsystem/netrun/netrun_execution_test)
	var/datum/netrun_task_scheduler/scheduler = worker.get_task_scheduler()
	var/datum/target = allocate(/datum)
	scheduler.enqueue("machine_delivery", target, NETRUN_TASK_BACKGROUND)
	scheduler.enqueue("machine_delivery", target, NETRUN_TASK_CRITICAL)
	TEST_ASSERT_EQUAL(scheduler.ready_deliveries, 1, "Promotion/coalescing must retain one ready delivery")
	worker.next_fire = world.time + 10 SECONDS
	worker.wake_ready_delivery()
	TEST_ASSERT_EQUAL(worker.next_fire, world.time, "Already ready I/O must not pay another tick before MC admission")
	TEST_ASSERT_EQUAL(worker.wait, world.tick_lag, "A ready backlog must be served at tick cadence")
	var/datum/netrun_task/task = scheduler.take()
	qdel(task)
	TEST_ASSERT_EQUAL(scheduler.ready_deliveries, 0, "Taking a delivery must release the ready-work count")
	worker.refresh_delivery_interval()
	TEST_ASSERT_EQUAL(worker.wait, NETRUN_DEFAULT_FIRE_INTERVAL, "A drained worker must return to its quiet cadence")
	scheduler.enqueue("request_delivery", target, NETRUN_TASK_CRITICAL, TRUE)
	scheduler.cancel("request_delivery", target)
	TEST_ASSERT_EQUAL(scheduler.ready_deliveries, 0, "Cancelled interactive packets must not keep the worker hot")
	scheduler.enqueue("probe", target)
	worker.refresh_delivery_interval()
	TEST_ASSERT_EQUAL(worker.wait, world.tick_lag, "Every admitted backlog needs bounded fast follow-up until drained")

/// Admitted input must obey the same finite pass budget as other runnable work.
/datum/unit_test/netrun_delivery_request_budget/Run()
	var/obj/item/host = allocate(/obj/item, run_loc_floor_bottom_left)
	var/datum/component/netrun_node/node = host.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	var/datum/controller/subsystem/netrun/netrun_execution_test/worker = allocate(/datum/controller/subsystem/netrun/netrun_execution_test)
	worker.task_adaptive_budget = FALSE
	worker.task_budget_ms = NETRUN_EXECUTION_MAX_BUDGET_MS
	worker.task_max_per_pass = 3
	worker.task_min_per_pass = 3
	var/list/samples = list()
	for(var/i in 1 to 7)
		var/datum/netrun_request/delivery/netrun_queue_probe/packet = allocate(/datum/netrun_request/delivery/netrun_queue_probe, console, node, node.network)
		samples += list(packet.observations)
		TEST_ASSERT(packet.send(), "A ready request must be admitted without executing synchronously")
		TEST_ASSERT_EQUAL(length(packet.observations), 0, "send() must return before native handling")
		var/datum/netrun_task/task = SSnetrun.get_task_scheduler().by_key["request_delivery:[REF(packet)]"]
		TEST_ASSERT(istype(task, /datum/netrun_task/request_delivery) && task.interactive, "Explicit input must use its registered interactive delivery task")
		SSnetrun.task_scheduler.cancel("request_delivery", packet)
		worker.get_task_scheduler().enqueue("request_delivery", packet, NETRUN_TASK_CRITICAL, TRUE)
	worker.run_pass()
	var/started = 0
	for(var/list/sample as anything in samples)
		started += !!length(sample)
	TEST_ASSERT_EQUAL(started, 3, "A burst of input may execute only the configured number of packets per pass")
	TEST_ASSERT_EQUAL(worker.get_task_scheduler().pending(), 4, "Undispatched packets must remain owned and runnable")
	worker.run_pass()
	worker.run_pass()
	for(var/list/sample as anything in samples)
		TEST_ASSERT_EQUAL(length(sample), 2, "Every admitted request must execute exactly once across later passes")

/// A yielding callback cannot suspend the worker, and dependency cancellation must settle once.
/datum/unit_test/netrun_delivery_yield_and_cancel/Run()
	var/obj/item/host = allocate(/obj/item, run_loc_floor_bottom_left)
	var/datum/component/netrun_node/node = host.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	var/datum/netrun_request/delivery/netrun_queue_probe/slow = allocate(/datum/netrun_request/delivery/netrun_queue_probe, console, node, node.network)
	var/datum/netrun_request/delivery/netrun_queue_probe/fast = allocate(/datum/netrun_request/delivery/netrun_queue_probe, console, node, node.network)
	slow.pause = 0.3 SECONDS
	var/list/slow_samples = slow.observations
	var/list/fast_samples = fast.observations
	var/slow_id = slow.operation.id
	slow.send()
	fast.send()
	var/datum/netrun_task/slow_task = new /datum/netrun_task/request_delivery("request_delivery", "slow", NETRUN_TASK_CRITICAL, slow)
	var/datum/netrun_task/fast_task = new /datum/netrun_task/request_delivery("request_delivery", "fast", NETRUN_TASK_CRITICAL, fast)
	var/started_at = world.time
	slow_task.execute(SSnetrun)
	fast_task.execute(SSnetrun)
	qdel(slow_task)
	qdel(fast_task)
	TEST_ASSERT_EQUAL(world.time, started_at, "The delivery task must not sleep with a native callback")
	TEST_ASSERT_EQUAL(length(slow_samples), 1, "The yielding callback must still be in progress")
	TEST_ASSERT_EQUAL(length(fast_samples), 2, "Another ready packet must complete while the first callback waits")
	TEST_ASSERT(slow in SSnetrun.pending_requests, "Executing callbacks must retain their owned packet")
	qdel(node)
	TEST_ASSERT(!QDELETED(slow) && slow.cancelled, "Dependency deletion must mark an executing callback instead of destroying its stack")
	sleep(0.5 SECONDS)
	TEST_ASSERT(QDELETED(slow), "A resumed cancelled callback must release its packet")
	TEST_ASSERT_EQUAL(slow_samples[2], "cancelled", "The resumed callback must observe its cancellation")
	var/list/result = netrun_operation_result(console, slow_id)
	TEST_ASSERT_EQUAL(result?["phase"], "cancelled", "Cancellation during a native wait must have a terminal result")

/datum/unit_test/netrun_delivery_cancel_before_dispatch/Run()
	var/obj/item/host = allocate(/obj/item, run_loc_floor_bottom_left)
	var/datum/component/netrun_node/node = host.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	console.origin = NETRUN_ORIGIN_CIRCUIT
	var/datum/netrun_request/delivery/netrun_queue_probe/packet = allocate(/datum/netrun_request/delivery/netrun_queue_probe, console, node, node.network)
	var/list/samples = packet.observations
	packet.send()
	var/key = "request_delivery:[REF(packet)]"
	var/datum/netrun_task/task = SSnetrun.get_task_scheduler().by_key[key]
	TEST_ASSERT(task && !task.interactive && task.priority == NETRUN_TASK_NORMAL, "Autonomous circuits must not impersonate interactive input")
	qdel(node)
	TEST_ASSERT(QDELETED(packet), "An undispatched request must be cancelled with its endpoint")
	TEST_ASSERT_NULL(SSnetrun.task_scheduler.by_key[key], "Cancellation must remove the ready scheduler entry")
	TEST_ASSERT_EQUAL(length(samples), 0, "A cancelled packet must never execute")

/datum/netrun_machine_message/transport_fixture/queue_snapshot/coalescing_key()
	return "replaceable-status"

/datum/netrun_machine_service/transport_fixture
	var/resolve_calls = 0

/datum/netrun_machine_service/transport_fixture/resolve(destination_id, recipient_tag)
	resolve_calls++
	return ..()

/// Command bursts share one lookup and yield admission before consuming the batch.
/datum/unit_test/netrun_delivery_discovery_burst_slices/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/list/outcomes = list()
	for(var/i in 1 to 17)
		TEST_ASSERT(scene.source.send("transport.fixture", new /datum/netrun_machine_message/transport_fixture(list("value" = i), outcomes), scene.target.service_tag()), "A finite command burst must be admitted")
	var/datum/netrun_machine_resolution/query = scene.source.resolutions["transport.fixture|[scene.target.service_tag()]"]
	TEST_ASSERT_EQUAL(scene.source.resolve_calls, 0, "Sending a burst must not resolve synchronously")
	query.deliver()
	TEST_ASSERT(!QDELETED(query) && length(query.queued), "The first slice must retain the undispatched burst")
	TEST_ASSERT(scene.pending_packets() > 0 && scene.pending_packets() <= 8, "One discovery slice must bound packet admission")
	TEST_ASSERT_EQUAL(scene.source.resolve_calls, 1, "One burst must use one recipient lookup")
	var/deadline = world.time + 5 SECONDS
	while(outcomes["delivered"] != 17 && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT_EQUAL(outcomes["delivered"], 17, "Every original command must execute exactly once after later slices")
	TEST_ASSERT(!outcomes["failed"], "Yielding a valid burst must not lose commands")
	TEST_ASSERT_EQUAL(scene.source.resolve_calls, 1, "Continuation slices must reuse the original recipient lookup")
	TEST_ASSERT(QDELETED(query), "A drained burst must release its lookup and scheduler task")

/// Source teardown must cancel later slices as well as already admitted packets.
/datum/unit_test/netrun_delivery_discovery_burst_source_deleted/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/datum/netrun_machine_transport/transport = SSnetrun.get_machine_transport()
	var/queued_before = transport.queued_messages
	var/list/outcomes = list()
	for(var/i in 1 to 17)
		scene.source.send("transport.fixture", new /datum/netrun_machine_message/transport_fixture(list(), outcomes), scene.target.service_tag())
	var/datum/netrun_machine_resolution/query = scene.source.resolutions["transport.fixture|[scene.target.service_tag()]"]
	query.deliver()
	var/key = "service_discovery:[REF(query)]"
	TEST_ASSERT(SSnetrun.get_task_scheduler().by_key[key], "A partial burst must own a continuation")
	qdel(scene.source)
	TEST_ASSERT(QDELETED(query), "Source deletion must immediately cancel an active continuation")
	TEST_ASSERT_NULL(SSnetrun.task_scheduler.by_key[key], "Source deletion must remove the continuation task")
	TEST_ASSERT_EQUAL(transport.queued_messages, queued_before, "Cancelling a partial burst must release all owned message capacity")
	TEST_ASSERT_EQUAL(outcomes["failed"], 17, "Every unicast command must fail once across pending and already admitted work")
	TEST_ASSERT_EQUAL(scene.target.received, 0, "Deleted-source commands must never reach the recipient")

/// Telemetry is ordinary background work even when its native message identifies an actor.
/datum/unit_test/netrun_delivery_machine_lane_and_cleanup/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/datum/netrun_machine_message/transport_fixture/queue_snapshot/message = new(list(), list())
	var/mob/actor = allocate(/mob, scene.source_spot)
	message.user_ref = WEAKREF(actor)
	var/datum/netrun_machine_packet/data/packet = new(scene.source, scene.target, message)
	TEST_ASSERT(packet.send(), "A telemetry packet must acquire a real physical route")
	TEST_ASSERT(packet.delivery_queued && !packet.timer_id, "Sub-tick local traffic must enter the shared asynchronous queue without a per-hop timer")
	// Exercise the same owner with a genuine representable latency deadline too.
	packet.cancel_delivery()
	TEST_ASSERT(packet.schedule_delivery(5 SECONDS), "A delayed machine packet must retain cancellable admission")
	var/owned_timer = packet.timer_id
	deltimer(owned_timer)
	packet.queue_delivery()
	var/key = "machine_delivery:[REF(packet)]"
	var/datum/netrun_task/task = SSnetrun.get_task_scheduler().by_key[key]
	TEST_ASSERT(istype(task, /datum/netrun_task/machine_delivery), "Ready machine packets must use their registered delivery task")
	TEST_ASSERT(!task.interactive && task.priority == NETRUN_TASK_BACKGROUND, "An actor reference must not promote automated snapshots")
	TEST_ASSERT_EQUAL(scene.target.received, 0, "Ready telemetry must wait for dispatch")
	packet.fail("fixture cancellation")
	TEST_ASSERT_NULL(SSnetrun.task_scheduler.by_key[key], "Cancelling ready telemetry must remove its scheduler entry")
	TEST_ASSERT(!(packet in SSnetrun.get_machine_transport().packets), "Cancelling telemetry must release packet capacity")
	TEST_ASSERT_NULL(SStimer.timer_id_dict[owned_timer], "Cancelled telemetry must not retain its latency timer")
	TEST_ASSERT_EQUAL(scene.target.received, 0, "Cancelled telemetry must not reach its native recipient")

/// Admission backpressure must explain capacity separately from a missing route.
/datum/unit_test/netrun_delivery_capacity_reasons/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, scene.sender)
	var/datum/netrun_request/delivery/netrun_queue_probe/request = allocate(/datum/netrun_request/delivery/netrun_queue_probe, console, scene.source.node, scene.source.node.network)
	var/id = request.operation.id
	var/list/previous_requests = SSnetrun.pending_requests
	SSnetrun.pending_requests = new /list(NETRUN_MAX_PENDING_REQUESTS)
	var/admitted = request.send()
	SSnetrun.pending_requests = previous_requests
	TEST_ASSERT(!admitted && QDELETED(request), "A full request queue must refuse admission and release the rejected packet")
	var/list/result = netrun_operation_result(console, id)
	TEST_ASSERT_EQUAL(result?["phase"], "rejected", "Capacity refusal must be a final rejected outcome")
	TEST_ASSERT(findtext(result["reason"], "переполнена"), "Request capacity must have an actionable reason")
	var/datum/netrun_machine_transport/transport = SSnetrun.get_machine_transport()
	var/list/outcomes = list()
	var/datum/netrun_machine_packet/data/packet = new(scene.source, scene.target, new /datum/netrun_machine_message/transport_fixture(list(), outcomes))
	var/list/previous_packets = transport.packets
	transport.packets = new /list(NETRUN_MAX_MACHINE_PACKETS)
	admitted = packet.send()
	transport.packets = previous_packets
	TEST_ASSERT(!admitted && QDELETED(packet), "Full machine capacity must refuse and consume the packet")
	TEST_ASSERT_EQUAL(outcomes["failed"], 1, "Capacity refusal must notify its native sender once")
	TEST_ASSERT(findtext(outcomes["reason"], "переполнена"), "Machine capacity must not masquerade as a missing route")
	scene.apc.set_machine_stat(BROKEN)
	outcomes = list()
	packet = new(scene.source, scene.target, new /datum/netrun_machine_message/transport_fixture(list(), outcomes))
	TEST_ASSERT(!packet.send(), "A packet without a physical route must fail admission")
	TEST_ASSERT(findtext(outcomes["reason"], "маршрута"), "Route failure must remain distinguishable from backpressure")

/// Every addressed send must wait for the same budgeted service-discovery task.
/datum/unit_test/netrun_delivery_discovery_admission/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/list/outcomes = list()
	TEST_ASSERT(scene.source.send("transport.fixture", new /datum/netrun_machine_message/transport_fixture(list("value" = "queued", "reply" = TRUE), outcomes), scene.target.service_tag()), "Addressed discovery must admit the original command")
	var/datum/netrun_machine_resolution/query = scene.source.resolutions["transport.fixture|[scene.target.service_tag()]"]
	TEST_ASSERT(!QDELETED(query), "The original command must own one pending service lookup")
	TEST_ASSERT(SSnetrun.get_task_scheduler().by_key["service_discovery:[REF(query)]"], "Service lookup must use the existing worker queue")
	TEST_ASSERT_EQUAL(scene.pending_packets(), 0, "Admission must not allocate routed data packets outside the worker")
	TEST_ASSERT_EQUAL(scene.target.received, 0, "Admission must not call the recipient inline")
	TEST_ASSERT(netrun_wait_delivery(outcomes), "The worker must deliver the original queued command")
	TEST_ASSERT_EQUAL(scene.target.received, 1, "Queued discovery must execute the command exactly once")
	TEST_ASSERT_EQUAL(outcomes["delivered"], 1, "Queued discovery must acknowledge the original command once")
	TEST_ASSERT(!outcomes["failed"], "A valid APC route must not fail the queued command")
	var/deadline = world.time + 1 SECONDS
	while(!scene.source.received && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT_EQUAL(scene.source.last_payload?["answer"], "queued", "The real reply must return through data delivery")

/// A cable lost before lookup fails finally; restoring it requires a fresh command.
/datum/unit_test/netrun_delivery_discovery_apc_unavailable/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/list/outcomes = list()
	TEST_ASSERT(scene.source.send("transport.fixture", new /datum/netrun_machine_message/transport_fixture(list("value" = "lost"), outcomes), scene.target.service_tag()), "A command must be admitted while its APC is available")
	scene.apc.set_machine_stat(BROKEN)
	TEST_ASSERT(!netrun_wait_delivery(outcomes), "Unavailable APC routing must reject the pending lookup")
	TEST_ASSERT_EQUAL(outcomes["failed"], 1, "An unavailable route must report one final failure")
	TEST_ASSERT_EQUAL(scene.target.received, 0, "There is no native receive fallback after an APC failure")
	TEST_ASSERT_EQUAL(length(scene.source.resolutions), 0, "Final route failure must release the pending lookup")
	scene.apc.set_machine_stat(0)
	var/list/recovered = list()
	TEST_ASSERT(scene.source.send("transport.fixture", new /datum/netrun_machine_message/transport_fixture(list("value" = "fresh"), recovered), scene.target.service_tag()), "A restored APC must admit a fresh command")
	TEST_ASSERT(netrun_wait_delivery(recovered), "The fresh command must use the restored physical route")
	TEST_ASSERT_EQUAL(scene.target.received, 1, "Route restoration must not replay the failed earlier command")
	TEST_ASSERT_EQUAL(scene.target.last_payload["value"], "fresh", "Only the newly submitted command may execute")
	TEST_ASSERT_EQUAL(outcomes["failed"], 1, "Later restoration must not change the previous terminal outcome")

/// Loading waiters own their command until completion or explicit cancellation.
/datum/unit_test/netrun_delivery_discovery_loading_cancel/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/list/outcomes = list()
	SSatoms.map_loader_begin()
	scene.source.send("transport.fixture", new /datum/netrun_machine_message/transport_fixture(list(), outcomes), scene.target.service_tag())
	var/datum/netrun_machine_resolution/query = scene.source.resolutions["transport.fixture|[scene.target.service_tag()]"]
	var/key = "service_discovery:[REF(query)]"
	var/was_pending = !QDELETED(query) && !outcomes["failed"] && !outcomes["delivered"]
	qdel(query)
	SSatoms.map_loader_stop()
	TEST_ASSERT(was_pending, "A loading request must wait without receiving a premature failure")
	TEST_ASSERT_EQUAL(outcomes["failed"], 1, "Cancelling a loading lookup must fail its queued command once")
	TEST_ASSERT_EQUAL(scene.target.received, 0, "A cancelled loading lookup must not send data")
	TEST_ASSERT_EQUAL(length(scene.source.resolutions), 0, "Cancellation must release the coalesced source lookup")
	TEST_ASSERT_NULL(SSnetrun.get_task_scheduler().by_key[key], "Cancellation must remove its admitted discovery task")

/// An indexed recipient identity is revalidated by the worker, never cached past replacement.
/datum/unit_test/netrun_delivery_service_tag_revocation/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/original_tag = scene.target.service_tag()
	var/list/outcomes = list()
	TEST_ASSERT(scene.source.send("transport.fixture", new /datum/netrun_machine_message/transport_fixture(list(), outcomes), original_tag), "The old indexed identity must be admitted before replacement")
	scene.receiver.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL, list(), 3)
	var/current_tag = scene.target.service_tag()
	TEST_ASSERT(current_tag != original_tag, "Replacing the physical component must retire its former address")
	TEST_ASSERT(!netrun_wait_delivery(outcomes), "The worker must reject a recipient identity revoked before lookup")
	TEST_ASSERT_EQUAL(outcomes["failed"], 1, "A revoked recipient identity must report one terminal failure")
	TEST_ASSERT_EQUAL(scene.target.received, 0, "An old identity cannot silently target the replacement")
	var/list/current = list()
	TEST_ASSERT(scene.source.send("transport.fixture", new /datum/netrun_machine_message/transport_fixture(list(), current), current_tag), "The actual replacement identity must accept a fresh request")
	TEST_ASSERT(netrun_wait_delivery(current), "The indexed replacement must be reachable through its real APC")
	TEST_ASSERT_EQUAL(scene.target.received, 1, "Only the fresh identity's command may execute")

/// Deleting the sender also owns and cancels its admitted discovery operation.
/datum/unit_test/netrun_delivery_discovery_source_deleted/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/list/outcomes = list()
	TEST_ASSERT(scene.source.send("transport.fixture", new /datum/netrun_machine_message/transport_fixture(list(), outcomes), scene.target.service_tag()), "Source deletion needs a real admitted lookup")
	var/datum/netrun_machine_resolution/query = scene.source.resolutions["transport.fixture|[scene.target.service_tag()]"]
	var/key = "service_discovery:[REF(query)]"
	qdel(scene.sender)
	TEST_ASSERT(QDELETED(query), "Deleting the physical source must destroy its admitted lookup")
	TEST_ASSERT_EQUAL(outcomes["failed"], 1, "Source deletion must settle its queued message once")
	TEST_ASSERT_EQUAL(scene.target.received, 0, "A deleted sender cannot execute a queued command")
	TEST_ASSERT_NULL(SSnetrun.get_task_scheduler().by_key[key], "Source deletion must release its discovery scheduler entry")

/// Observe domain matching rather than relying on elapsed time for area scoping.
/datum/netrun_machine_service/atmos/controller/discovery_scope_fixture
	var/match_checks = 0

/datum/netrun_machine_service/atmos/controller/discovery_scope_fixture/matches(datum/netrun_machine_service/source_service, recipient_tag)
	match_checks++
	return ..()

/obj/machinery/airalarm/discovery_scope_fixture/netrun_machine_service_types()
	. = ..()
	. -= /datum/netrun_machine_service/atmos/controller
	. += /datum/netrun_machine_service/atmos/controller/discovery_scope_fixture

/// One vent registers natively without matching every air alarm on the station.
/datum/unit_test/netrun_delivery_atmos_area_candidates/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/machinery/airalarm/discovery_scope_fixture/alarm = scene.machine(/obj/machinery/airalarm/discovery_scope_fixture, scene.source_spot)
	var/obj/machinery/atmospherics/components/unary/vent_pump/vent = scene.machine(/obj/machinery/atmospherics/components/unary/vent_pump, scene.target_spot)
	var/obj/machinery/atmospherics/components/unary/outlet_injector/injector = scene.machine(/obj/machinery/atmospherics/components/unary/outlet_injector, scene.target_spot)
	var/datum/netrun_machine_service/atmos/controller/discovery_scope_fixture/local_controller = alarm.get_netrun_machine_service("atmos.controller")
	var/datum/netrun_machine_service/atmos/device/device = vent.get_netrun_machine_service("atmos.device")
	var/datum/netrun_machine_service/atmos/device/injector/injector_service = injector.get_netrun_machine_service("atmos.device")
	var/list/levels = multiz_gravity_test_levels()
	scene.mark_station(levels[1])
	var/list/unrelated = list()
	var/turf/other_spot
	var/datum/netrun_machine_service/atmos/controller/discovery_scope_fixture/other_controller
	for(var/i in 1 to 64)
		var/area/room = scene.room(/area/netrun_route_test)
		var/turf/spot = scene.take(locate(80 + (i - 1) % 8, 80 + round((i - 1) / 8), levels[1]), room, TRUE)
		var/obj/machinery/airalarm/discovery_scope_fixture/other_alarm = scene.machine(/obj/machinery/airalarm/discovery_scope_fixture, spot)
		var/datum/netrun_machine_service/atmos/controller/discovery_scope_fixture/controller = other_alarm.get_netrun_machine_service("atmos.controller")
		unrelated += controller
		if(i == 1)
			other_spot = spot
			other_controller = controller
	SSnetrun.ensure_topology()
	for(var/datum/netrun_machine_service/atmos/controller/discovery_scope_fixture/controller as anything in unrelated)
		controller.match_checks = 0
	local_controller.match_checks = 0
	// Native initialization may already have delivered the first broadcast.
	// Require a new real delivery after resetting the observations.
	alarm.netrun_vent_info.Cut()
	vent.broadcast_status()
	var/deadline = world.time + 5 SECONDS
	while(!alarm.netrun_vent_info[vent.id_tag] && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT(alarm.netrun_vent_info[vent.id_tag], "The real vent status must register with its own native air alarm")
	TEST_ASSERT(local_controller.match_checks > 0, "The local controller must still run native channel and area authorization")
	var/datum/weakref/ack = device.acknowledged_controllers[REF(local_controller)]
	TEST_ASSERT_EQUAL(ack?.resolve(), local_controller, "Successful native delivery must acknowledge the actual local controller")
	for(var/datum/netrun_machine_service/atmos/controller/discovery_scope_fixture/controller as anything in unrelated)
		TEST_ASSERT_EQUAL(controller.match_checks, 0, "A status lookup must not call matches on any of the 64 unrelated area controllers")
	var/list/candidates = local_controller.discovery_candidates("atmos.device", null)
	TEST_ASSERT((device in candidates) && (injector_service in candidates), "The shared area index must include both registering vents and command-only injectors")
	injector.forceMove(other_spot)
	candidates = local_controller.discovery_candidates("atmos.device", null)
	TEST_ASSERT(!(injector_service in candidates), "Moving a command-only device must remove it from its old area's candidates")
	candidates = other_controller.discovery_candidates("atmos.device", null)
	TEST_ASSERT(injector_service in candidates, "Moving a command-only device must index it in its actual new area")
	qdel(injector)
	TEST_ASSERT(!(injector_service in candidates), "Device deletion must remove the borrowed area's candidate entry")
	var/old_controller_key = REF(local_controller)
	qdel(alarm)
	alarm = scene.machine(/obj/machinery/airalarm/discovery_scope_fixture, scene.source_spot)
	local_controller = alarm.get_netrun_machine_service("atmos.controller")
	candidates = device.discovery_candidates("atmos.controller", null)
	TEST_ASSERT_EQUAL(length(candidates), 1, "Replacing an air alarm must leave exactly one live local discovery candidate")
	TEST_ASSERT(local_controller in candidates, "A fresh lookup must discover the replacement air alarm")
	vent.broadcast_status()
	deadline = world.time + 5 SECONDS
	while(!alarm.netrun_vent_info[vent.id_tag] && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT(alarm.netrun_vent_info[vent.id_tag], "The replacement controller must receive actual native registration")
	TEST_ASSERT(!device.acknowledged_controllers[old_controller_key], "A deleted controller must not retain a registration acknowledgement")
	ack = device.acknowledged_controllers[REF(local_controller)]
	TEST_ASSERT_EQUAL(ack?.resolve(), local_controller, "Registration must acknowledge the replacement's service identity")
