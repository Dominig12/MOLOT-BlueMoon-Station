/// The ordinary allocator supplies a turf to argument-less constructors; this one takes limits.
/datum/unit_test/proc/netrun_scheduler_fixture()
	var/datum/netrun_task_scheduler/result = new
	allocated += result
	return result

/// Scheduler tests do not mutate the live SSnetrun queues.
/datum/unit_test/netrun_scheduler_dedup_and_priority/Run()
	var/datum/netrun_task_scheduler/scheduler = netrun_scheduler_fixture()
	var/datum/sample = allocate(/datum)
	TEST_ASSERT(scheduler.enqueue("probe", sample, NETRUN_TASK_BACKGROUND), "First task must enqueue")
	TEST_ASSERT(!scheduler.enqueue("probe", sample, NETRUN_TASK_BACKGROUND), "Duplicate task must coalesce")
	TEST_ASSERT(!scheduler.enqueue("probe", sample, NETRUN_TASK_CRITICAL), "Priority promotion must not duplicate")
	TEST_ASSERT_EQUAL(scheduler.pending(), 1, "Only one task must remain")
	var/datum/netrun_task/task = scheduler.take()
	TEST_ASSERT_EQUAL(task.priority, NETRUN_TASK_CRITICAL, "Promoted task must be served at new priority")
	qdel(task)
	TEST_ASSERT_EQUAL(scheduler.pending(), 0, "No pending task remains")
	TEST_ASSERT_NULL(scheduler.take(), "Promotion tombstone must not replay")
/datum/unit_test/netrun_scheduler_cancel_and_fairness/Run()
	var/datum/netrun_task_scheduler/scheduler = netrun_scheduler_fixture()
	var/list/samples = list()
	for(var/i in 1 to 21)
		var/datum/sample = allocate(/datum)
		samples += sample
		var/priority = i <= 9 ? NETRUN_TASK_CRITICAL : (i <= 16 ? NETRUN_TASK_NORMAL : NETRUN_TASK_BACKGROUND)
		scheduler.enqueue("probe", sample, priority)
	TEST_ASSERT(scheduler.cancel("probe", samples[21]), "Cancellation succeeds")
	TEST_ASSERT_EQUAL(scheduler.pending(), 20, "Cancellation drops pending count")
	var/list/served = list(0, 0, 0)
	for(var/i in 1 to 14)
		var/datum/netrun_task/task = scheduler.take()
		TEST_ASSERT(!isnull(task), "Sufficient tasks remain")
		served[task.priority]++
		qdel(task)
	TEST_ASSERT(served[1] && served[2] && served[3], "All priorities receive execution")
	TEST_ASSERT_EQUAL(scheduler.pending(), 6, "Exactly 14 tasks returned")

/// Profiling must capture CPU cost and time spent waiting without retaining a target.
/datum/unit_test/netrun_scheduler_profiles/Run()
	var/datum/netrun_task_scheduler/scheduler = netrun_scheduler_fixture()
	var/datum/subject = allocate(/datum)
	TEST_ASSERT(scheduler.enqueue("probe", subject, NETRUN_TASK_CRITICAL), "A measured task is queued")
	var/datum/netrun_task/task = scheduler.take()
	TEST_ASSERT(!isnull(task), "A measured task is returned")
	task.enqueued_at = world.time - 3 SECONDS
	scheduler.note_execution(task, 1.25)
	qdel(task)
	var/datum/netrun_task_profile/profile = scheduler.profiles["probe"]
	TEST_ASSERT_EQUAL(profile.calls, 1, "One completed sample recorded")
	TEST_ASSERT_EQUAL(profile.total_ms, 1.25, "CPU work is recorded")
	TEST_ASSERT_EQUAL(profile.peak_wait_ds, 3 SECONDS, "Queue latency is recorded")
	TEST_ASSERT_EQUAL(profile.overdue, 1, "Delayed critical task is counted")
	TEST_ASSERT_EQUAL(scheduler.overdue_by_priority[NETRUN_TASK_CRITICAL], 1, "Per-priority late counter matches profile")
	TEST_ASSERT_EQUAL(scheduler.peak_pending, 1, "High-water mark records queue size")
	TEST_ASSERT_EQUAL(scheduler.pending(), 0, "Stats do not create extra tasks")

/// Promotion affects the current priority bucket without inflating pending metrics.
/datum/unit_test/netrun_scheduler_profile_promotion/Run()
	var/datum/netrun_task_scheduler/scheduler = netrun_scheduler_fixture()
	var/datum/subject = allocate(/datum)
	scheduler.enqueue("probe", subject, NETRUN_TASK_BACKGROUND)
	scheduler.enqueue("probe", subject, NETRUN_TASK_CRITICAL)
	TEST_ASSERT_EQUAL(scheduler.pending(), 1, "Promotion leaves one pending task")
	TEST_ASSERT_EQUAL(scheduler.counts[NETRUN_TASK_BACKGROUND], 0, "Old priority has no pending task")
	TEST_ASSERT_EQUAL(scheduler.counts[NETRUN_TASK_CRITICAL], 1, "New priority has the task")
	TEST_ASSERT_EQUAL(scheduler.peak_queued_by_priority[NETRUN_TASK_BACKGROUND], 1, "Original queue high-water survives promotion")
	TEST_ASSERT_EQUAL(scheduler.peak_queued_by_priority[NETRUN_TASK_CRITICAL], 1, "Promoted queue high-water is recorded")

/// Previously a burst of cancellations hid a live background task behind scan tombstones.
/datum/unit_test/netrun_scheduler_cancel_burst/Run()
	var/datum/netrun_task_scheduler/scheduler = netrun_scheduler_fixture()
	for(var/i in 1 to 160)
		var/datum/subject = allocate(/datum)
		scheduler.enqueue("probe", subject, NETRUN_TASK_BACKGROUND)
		TEST_ASSERT(scheduler.cancel("probe", subject), "Every obsolete task must cancel")
	var/datum/live = allocate(/datum)
	scheduler.enqueue("probe", live, NETRUN_TASK_BACKGROUND)
	TEST_ASSERT_EQUAL(scheduler.pending(), 1, "Only the live task remains")
	var/datum/netrun_task/task = scheduler.take()
	TEST_ASSERT_NOTNULL(task, "A pending live task must be returned on this pass regardless of prior cancellations")
	TEST_ASSERT_EQUAL(task.target(), live, "Cancellation must not reorder or hide the live task")
	qdel(task)
	TEST_ASSERT_EQUAL(scheduler.counts[NETRUN_TASK_BACKGROUND], 0, "Cancellation and service must release all queue capacity")
	TEST_ASSERT_NULL(scheduler.take(), "No cancelled entry may be replayed")

/// Promotion unlinks the old entry and preserves its original age for diagnostics.
/datum/unit_test/netrun_scheduler_promotion_fifo/Run()
	var/datum/netrun_task_scheduler/scheduler = netrun_scheduler_fixture()
	var/datum/first = allocate(/datum)
	var/datum/promoted = allocate(/datum)
	var/datum/last = allocate(/datum)
	scheduler.enqueue("probe", first, NETRUN_TASK_BACKGROUND)
	scheduler.enqueue("probe", promoted, NETRUN_TASK_BACKGROUND)
	scheduler.enqueue("probe", last, NETRUN_TASK_BACKGROUND)
	var/datum/netrun_task/middle = scheduler.by_key["probe:[REF(promoted)]"]
	middle.enqueued_at = world.time - 30 SECONDS
	scheduler.enqueue("probe", promoted, NETRUN_TASK_CRITICAL)
	var/datum/netrun_task/task = scheduler.take()
	TEST_ASSERT_EQUAL(task, middle, "Promotion must preserve task identity")
	TEST_ASSERT_EQUAL(task.enqueued_at, world.time - 30 SECONDS, "Promotion must preserve the wait clock")
	qdel(task)
	task = scheduler.take()
	TEST_ASSERT_EQUAL(task.target(), first, "Unlinking a middle task must preserve FIFO order")
	qdel(task)
	task = scheduler.take()
	TEST_ASSERT_EQUAL(task.target(), last, "The original tail must remain reachable after unlinking")
	qdel(task)
	for(var/datum/netrun_task_queue/queue as anything in scheduler.queues)
		TEST_ASSERT_NULL(queue.first, "Drained queue must release its head reference")
		TEST_ASSERT_NULL(queue.last, "Drained queue must release its tail reference")

/// Test probes exercise lifecycle without opening TGUI or waiting on a real clock.
/datum/netrun_console/netrun_scheduler_probe
	var/list/test_deltas = list()
	var/delete_during_tick = FALSE

/datum/netrun_console/netrun_scheduler_probe/process_tick(delta)
	test_deltas += delta
	if(delete_during_tick)
		qdel(src)

/datum/netrun_console/netrun_scheduler_probe/flush_ui()
	test_deltas += "flush"

/datum/unit_test/netrun_scheduler_wake_clock/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/netrun_console/netrun_scheduler_probe/console = allocate(/datum/netrun_console/netrun_scheduler_probe, host)
	SSnetrun.active_consoles -= console
	console.last_netrun_tick = world.time - 10 MINUTES
	console.activate()
	TEST_ASSERT_EQUAL(console.last_netrun_tick, world.time, "Waking an idle session must start a new active interval")
	var/datum/netrun_task_scheduler/scheduler = netrun_scheduler_fixture()
	scheduler.enqueue("console", console)
	var/datum/netrun_task/task = scheduler.take()
	TEST_ASSERT(istype(task, /datum/netrun_task/console), "The task registry must select polymorphic console processing")
	var/previous_count = SSnetrun.last_processed_consoles
	task.execute(SSnetrun)
	SSnetrun.last_processed_consoles = previous_count
	qdel(task)
	TEST_ASSERT_EQUAL(console.test_deltas[1], 0, "Minutes asleep must not become trace or damage on wake")
	// Reactivation while processing is live must not lose real elapsed time.
	console.activate()
	console.last_netrun_tick = world.time - 3 SECONDS
	console.activate()
	TEST_ASSERT_EQUAL(console.last_netrun_tick, world.time - 3 SECONDS, "Repeated events must preserve an already active clock")

/datum/unit_test/netrun_scheduler_console_deleted_during_tick/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/netrun_console/netrun_scheduler_probe/console = allocate(/datum/netrun_console/netrun_scheduler_probe, host)
	var/list/samples = console.test_deltas
	console.delete_during_tick = TRUE
	var/datum/netrun_task_scheduler/scheduler = netrun_scheduler_fixture()
	scheduler.enqueue("console", console)
	var/datum/netrun_task/task = scheduler.take()
	task.execute(SSnetrun)
	qdel(task)
	TEST_ASSERT(QDELETED(console), "Dive processing may delete its own console")
	TEST_ASSERT_EQUAL(length(samples), 1, "A deleted console must never be asked to flush its UI")
	console.activate()
	TEST_ASSERT(!(console in SSnetrun.active_consoles), "A signal during teardown must not reactivate a deleted console")

/datum/unit_test/netrun_scheduler_client_teardown/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	var/datum/netrun_task_scheduler/scheduler = SSnetrun.get_task_scheduler()
	scheduler.enqueue("console", console)
	var/key = "console:[REF(console)]"
	qdel(console)
	TEST_ASSERT_NULL(scheduler.by_key[key], "Deleting a session must cancel its queued work immediately")
	var/datum/netrun_ice/ice = new(null)
	allocated += ice
	scheduler.enqueue("ice", ice)
	key = "ice:[REF(ice)]"
	qdel(ice)
	TEST_ASSERT_NULL(scheduler.by_key[key], "Deleting an ICE must cancel its queued work immediately")

/// A delivery cannot acquire two timers, execute reentrantly or replay after early dispatch.
/datum/netrun_request/delivery/netrun_scheduler_probe
	var/list/executions = list()

/datum/netrun_request/delivery/netrun_scheduler_probe/execute()
	executions += "execute"
	deliver()
	return TRUE

/datum/unit_test/netrun_request_single_dispatch/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/component/netrun_node/node = host.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	var/datum/netrun_request/delivery/netrun_scheduler_probe/packet = allocate(/datum/netrun_request/delivery/netrun_scheduler_probe, console, node, node.network)
	var/list/executions = packet.executions
	TEST_ASSERT(packet.send(30 SECONDS), "The first send must acquire one timer")
	var/timer_id = packet.timer_id
	TEST_ASSERT(!packet.send(60 SECONDS), "A second send must not create an unowned timer")
	TEST_ASSERT_EQUAL(packet.timer_id, timer_id, "Rejected redispatch must retain the original timer")
	TEST_ASSERT(packet.deliver(), "Early delivery must execute the original packet")
	TEST_ASSERT_EQUAL(length(executions), 1, "Reentrant delivery must not execute the request twice")
	TEST_ASSERT(QDELETED(packet), "A delivered packet must release its dependencies")
	TEST_ASSERT_NULL(packet.timer_id, "Early delivery must cancel its pending timer")
	TEST_ASSERT_NULL(SStimer.timer_id_dict[timer_id], "A consumed packet must not leave a timer behind")
