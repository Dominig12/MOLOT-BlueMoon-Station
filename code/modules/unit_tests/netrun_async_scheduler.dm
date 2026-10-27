/// Exercise the real continuation timer while keeping all dispatch in an isolated worker.
/datum/netrun_async_scheduler_probe
	var/list/executed_at = list()
	var/queue_inside_slice = FALSE

/datum/netrun_task/async_scheduler_probe
	parent_type = /datum/netrun_task/tick_continuation
	kind = "async_scheduler_probe"

/datum/netrun_task/async_scheduler_probe/advance(datum/controller/subsystem/netrun/worker, datum/netrun_execution_limits/limits)
	var/datum/netrun_async_scheduler_probe/probe = target()
	probe.executed_at += world.time
	if(length(probe.executed_at) >= 2)
		return TRUE
	if(probe.queue_inside_slice)
		// Domain signals can admit the same key while its old task is executing.
		worker.get_task_scheduler().enqueue(kind, probe, priority)
	return FALSE

/datum/unit_test/proc/netrun_async_worker_fixture()
	var/datum/controller/subsystem/netrun/netrun_execution_test/worker = allocate(/datum/controller/subsystem/netrun/netrun_execution_test)
	worker.task_adaptive_budget = FALSE
	worker.task_budget_ms = NETRUN_EXECUTION_MAX_BUDGET_MS
	worker.task_max_per_pass = NETRUN_DEFAULT_TASK_MAX_PER_PASS
	worker.next_task_population = INFINITY
	return worker

/// Spare MC budget and a same-key signal must never execute both slices in one tick.
/datum/unit_test/netrun_async_tick_barrier/Run()
	var/datum/controller/subsystem/netrun/netrun_execution_test/worker = netrun_async_worker_fixture()
	var/datum/netrun_task_scheduler/scheduler = worker.get_task_scheduler()
	var/datum/netrun_async_scheduler_probe/probe = allocate(/datum/netrun_async_scheduler_probe)
	probe.queue_inside_slice = TRUE
	var/key = "async_scheduler_probe:[REF(probe)]"
	scheduler.enqueue("async_scheduler_probe", probe, NETRUN_TASK_NORMAL)
	worker.run_pass()
	TEST_ASSERT_EQUAL(length(probe.executed_at), 1, "A signal raised inside the first slice must also respect the tick barrier")
	TEST_ASSERT_EQUAL(scheduler.pending(), 0, "The continuation must wait on its timer rather than remain runnable")
	TEST_ASSERT_EQUAL(length(scheduler.deferred), 1, "An incomplete slice must own exactly one resume timer")
	var/timer_id = scheduler.deferred[key]
	TEST_ASSERT_NOTNULL(SStimer.timer_id_dict[timer_id], "The tick barrier must use a real stoppable timer")
	TEST_ASSERT(!scheduler.enqueue("async_scheduler_probe", probe, NETRUN_TASK_CRITICAL, TRUE), "Input arriving before the timer must not bypass the tick barrier")
	TEST_ASSERT_EQUAL(scheduler.deferred[key], timer_id, "Repeated admission must retain the original deadline")
	worker.run_pass()
	TEST_ASSERT_EQUAL(length(probe.executed_at), 1, "Another worker pass in the same tick must not execute the continuation")
	var/deadline = world.time + 2 SECONDS
	while(!scheduler.pending() && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT_EQUAL(scheduler.pending(), 1, "The real timer must admit exactly one follow-up task")
	TEST_ASSERT_EQUAL(length(scheduler.deferred), 0, "A fired timer must release the deferred key before admission")
	worker.run_pass()
	TEST_ASSERT_EQUAL(length(probe.executed_at), 2, "The next admitted slice must finish the work")
	TEST_ASSERT(probe.executed_at[2] >= probe.executed_at[1] + world.tick_lag, "Continuation execution must cross a real server tick")
	TEST_ASSERT_EQUAL(scheduler.pending(), 0, "Finished work must drain its runnable task")
	TEST_ASSERT_EQUAL(length(scheduler.deferred), 0, "Finished work must not create another timer")

/// Cancellation owns the timer as well as the runnable queue entry.
/datum/unit_test/netrun_async_cancel_deferred/Run()
	var/datum/netrun_task_scheduler/scheduler = netrun_scheduler_fixture()
	var/datum/subject = allocate(/datum)
	var/key = "async_cancel_probe:[REF(subject)]"
	scheduler.defer("async_cancel_probe", subject, NETRUN_TASK_BACKGROUND)
	var/timer_id = scheduler.deferred[key]
	TEST_ASSERT_NOTNULL(SStimer.timer_id_dict[timer_id], "Deferring work must acquire a timer")
	for(var/attempt in 1 to 8)
		scheduler.defer("async_cancel_probe", subject, NETRUN_TASK_BACKGROUND)
		TEST_ASSERT(!scheduler.enqueue("async_cancel_probe", subject), "A deferred key must coalesce repeated admissions")
	TEST_ASSERT_EQUAL(length(scheduler.deferred), 1, "A burst of requests must own only one timer")
	TEST_ASSERT_EQUAL(scheduler.deferred[key], timer_id, "Coalescing must not postpone the timer")
	TEST_ASSERT(scheduler.cancel("async_cancel_probe", subject), "Cancellation must report a deferred task as cancelled")
	TEST_ASSERT_EQUAL(length(scheduler.deferred), 0, "Cancellation must remove the deferred key")
	TEST_ASSERT_NULL(SStimer.timer_id_dict[timer_id], "Cancellation must remove the actual timer")
	sleep(2 * world.tick_lag)
	TEST_ASSERT_EQUAL(scheduler.pending(), 0, "A cancelled timer must never admit its work later")
	TEST_ASSERT(!scheduler.cancel("async_cancel_probe", subject), "A drained key must not report another cancellation")

/// The timer must not retain a strong target or resurrect work after its target is deleted.
/datum/unit_test/netrun_async_deleted_target/Run()
	var/datum/netrun_task_scheduler/scheduler = netrun_scheduler_fixture()
	var/datum/subject = allocate(/datum)
	var/key = "async_deleted_probe:[REF(subject)]"
	scheduler.defer("async_deleted_probe", subject, NETRUN_TASK_BACKGROUND)
	var/datum/timedevent/timer = SStimer.timer_id_dict[scheduler.deferred[key]]
	TEST_ASSERT_NOTNULL(timer, "The deferred target needs a live timer")
	TEST_ASSERT(!(subject in timer.callBack.arguments), "A deferred callback must hold the work through a weak reference")
	var/datum/weakref/target_ref = timer.callBack.arguments[3]
	TEST_ASSERT(istype(target_ref), "The callback must carry the target weak reference")
	qdel(subject)
	TEST_ASSERT_NULL(target_ref.resolve(), "Deleting the work target must invalidate its weak reference immediately")
	var/deadline = world.time + 2 SECONDS
	while(length(scheduler.deferred) && world.time < deadline)
		sleep(world.tick_lag)
	TEST_ASSERT_EQUAL(length(scheduler.deferred), 0, "The real timer must release a deleted target's deferred key")
	TEST_ASSERT_EQUAL(scheduler.pending(), 0, "A deleted target must never enter a runnable queue")

/// Tearing down an isolated scheduler must release every owned timer immediately.
/datum/unit_test/netrun_async_scheduler_teardown/Run()
	var/datum/netrun_task_scheduler/scheduler = netrun_scheduler_fixture()
	var/datum/subject = allocate(/datum)
	var/key = "async_teardown_probe:[REF(subject)]"
	scheduler.defer("async_teardown_probe", subject, NETRUN_TASK_BACKGROUND)
	var/timer_id = scheduler.deferred[key]
	TEST_ASSERT_NOTNULL(SStimer.timer_id_dict[timer_id], "The scheduler must own the timer before destruction")
	qdel(scheduler)
	TEST_ASSERT_NULL(SStimer.timer_id_dict[timer_id], "Scheduler destruction must cancel the actual timer")
	TEST_ASSERT_EQUAL(length(scheduler.deferred), 0, "Scheduler destruction must release its deferred registry")
