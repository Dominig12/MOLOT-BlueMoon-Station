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

/// Losing the first resolver must switch discovery, preserving one original data delivery.
/datum/unit_test/netrun_delivery_dns_query_failover/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	var/obj/machinery/netrun_server/dns/backup = scene.machine(/obj/machinery/netrun_server/dns, scene.dns_spot)
	var/list/outcomes = list()
	TEST_ASSERT(scene.source.send("transport.fixture", new /datum/netrun_machine_message/transport_fixture(list("value" = "failover"), outcomes), scene.target.service_tag()), "Cold discovery must admit the original command")
	var/datum/netrun_machine_resolution/query = scene.source.resolutions["transport.fixture|[scene.target.service_tag()]"]
	var/old_generation = query.attempt_generation
	var/datum/netrun_machine_service/first_resolver = query.resolver
	var/datum/netrun_machine_packet/dns_query/first = query.active_packet_ref.resolve()
	first.fail("fixture first DNS lost")
	TEST_ASSERT(!QDELETED(query), "A reachable untried resolver must preserve discovery")
	TEST_ASSERT(!query.is_current(old_generation), "Retiring the failed attempt must invalidate its callbacks immediately")
	query.finish(old_generation)
	query.answer(old_generation)
	TEST_ASSERT(!length(scene.source.directory), "Stale query/reply callbacks must not install an obsolete directory")
	var/delivered = netrun_wait_delivery(outcomes)
	TEST_ASSERT(delivered, "Backup DNS must deliver the original queued message: [outcomes["reason"]]; source journal [json_encode(scene.source.node.packet_logs)]; backup journal [json_encode(backup.GetComponent(/datum/component/netrun_node):packet_logs)]")
	TEST_ASSERT_EQUAL(scene.target.received, 1, "Resolver failover must execute data exactly once")
	TEST_ASSERT_EQUAL(outcomes["delivered"], 1, "Failover must acknowledge the original command once")
	TEST_ASSERT(!outcomes["failed"], "A recoverable DNS attempt must not fail its queued command")
	var/datum/netrun_machine_directory/entry = scene.source.directory["transport.fixture|[scene.target.service_tag()]"]
	TEST_ASSERT(entry.resolver_ref.resolve() != first_resolver, "The completed cache must identify the backup that actually replied")
	TEST_ASSERT(backup, "The backup fixture must remain physically present")

/// Failure after the DNS query is handled must retry discovery, not replay a data command.
/datum/unit_test/netrun_delivery_dns_reply_failover/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	scene.machine(/obj/machinery/netrun_server/dns, scene.dns_spot)
	var/list/outcomes = list()
	scene.source.send("transport.fixture", new /datum/netrun_machine_message/transport_fixture(list(), outcomes), scene.target.service_tag())
	var/datum/netrun_machine_resolution/query = scene.source.resolutions["transport.fixture|[scene.target.service_tag()]"]
	var/datum/netrun_machine_packet/dns_query/first = query.active_packet_ref.resolve()
	first.deliver()
	var/datum/netrun_machine_packet/dns_reply/reply = query.active_packet_ref.resolve()
	TEST_ASSERT(istype(reply) && !QDELETED(reply), "The real query must produce an independently routed DNS reply")
	reply.fail("fixture reply lost")
	TEST_ASSERT(netrun_wait_delivery(outcomes), "Losing the first reply must recover through another resolver")
	TEST_ASSERT_EQUAL(scene.target.received, 1, "A reply retry must not duplicate the eventual data command")
	TEST_ASSERT(!outcomes["failed"] && outcomes["delivered"] == 1, "The caller must see exactly one successful terminal outcome")

/// Watchdogs and total deadlines are bounded even when obsolete timer callbacks arrive.
/datum/unit_test/netrun_delivery_dns_watchdog_bounds/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	scene.machine(/obj/machinery/netrun_server/dns, scene.dns_spot)
	var/list/outcomes = list()
	scene.source.send("transport.fixture", new /datum/netrun_machine_message/transport_fixture(list(), outcomes), scene.target.service_tag())
	var/datum/netrun_machine_resolution/query = scene.source.resolutions["transport.fixture|[scene.target.service_tag()]"]
	var/generation = query.attempt_generation
	var/datum/netrun_machine_packet/dns_query/first = query.active_packet_ref.resolve()
	query.attempt_expired(generation)
	TEST_ASSERT(QDELETED(first), "An expired attempt must cancel its owned in-flight packet")
	var/retry_generation = query.attempt_generation
	query.attempt_expired(generation)
	TEST_ASSERT_EQUAL(query.attempt_generation, retry_generation, "A stale watchdog must not consume another attempt")
	query.deadline = world.time
	query.begin()
	TEST_ASSERT(QDELETED(query), "The shared discovery deadline must prevent another resolver attempt")
	TEST_ASSERT_EQUAL(outcomes["failed"], 1, "An expired resolution must fail its queued message once")
	TEST_ASSERT_EQUAL(scene.target.received, 0, "An expired discovery must not send data")
	TEST_ASSERT_EQUAL(length(scene.source.resolutions), 0, "Deadline failure must release the coalesced query")

/datum/unit_test/netrun_delivery_dns_attempt_limit/Run()
	var/datum/netrun_transport_scene/scene = allocate(/datum/netrun_transport_scene, run_loc_floor_bottom_left)
	scene.machine(/obj/machinery/netrun_server/dns, scene.dns_spot)
	var/list/outcomes = list()
	scene.source.send("transport.fixture", new /datum/netrun_machine_message/transport_fixture(list(), outcomes), scene.target.service_tag())
	var/datum/netrun_machine_resolution/query = scene.source.resolutions["transport.fixture|[scene.target.service_tag()]"]
	query.attempts = NETRUN_DNS_MAX_ATTEMPTS
	query.retry("fixture attempt limit", query.attempt_generation)
	TEST_ASSERT(QDELETED(query), "Even a reachable backup must not bypass the maximum attempts")
	TEST_ASSERT_EQUAL(outcomes["failed"], 1, "Attempt exhaustion must report one terminal failure")
	TEST_ASSERT_EQUAL(scene.target.received, 0, "Attempt exhaustion must not execute queued data")
