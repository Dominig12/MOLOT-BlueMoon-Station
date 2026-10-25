/// This worker never registers as SSnetrun or populates real station work.
/datum/controller/subsystem/netrun/netrun_execution_test
	var/probe_calls = 0
	var/probe_populations = 0

/datum/controller/subsystem/netrun/netrun_execution_test/New()
	return

/datum/controller/subsystem/netrun/netrun_execution_test/Destroy()
	QDEL_NULL(task_scheduler)
	QDEL_NULL(execution_limits)
	QDEL_NULL(topology)
	return ..()

/datum/controller/subsystem/netrun/netrun_execution_test/populate_tasks()
	probe_populations++

/// Direct fixture calls bypass MC dispatch, so supply its running state and restore globals.
/datum/controller/subsystem/netrun/netrun_execution_test/proc/run_pass()
	var/previous_state = state
	var/previous_ticklimit = Master.current_ticklimit
	state = SS_RUNNING
	Master.current_ticklimit = INFINITY
	fire()
	Master.current_ticklimit = previous_ticklimit
	state = previous_state

/datum/netrun_task/execution_probe
	kind = "execution_probe"

/datum/netrun_task/execution_probe/execute(datum/controller/subsystem/netrun/netrun_execution_test/worker, datum/netrun_execution_limits/limits)
	worker.probe_calls++
	return TRUE

/// A previous expensive task must not turn a cheap packet burst into two tasks per pass.
/datum/unit_test/netrun_execution_mixed_cost_drain/Run()
	var/datum/controller/subsystem/netrun/netrun_execution_test/worker = allocate(/datum/controller/subsystem/netrun/netrun_execution_test)
	worker.task_adaptive_budget = FALSE
	worker.task_budget_ms = NETRUN_EXECUTION_MAX_BUDGET_MS
	worker.task_max_per_pass = 32
	worker.next_task_population = INFINITY
	var/datum/netrun_task_scheduler/scheduler = worker.get_task_scheduler()
	var/datum/netrun_task/prior = allocate(/datum/netrun_task/execution_probe, "execution_probe", "prior-expensive", NETRUN_TASK_NORMAL)
	scheduler.note_execution(prior, NETRUN_EXECUTION_MAX_BUDGET_MS)
	for(var/i in 1 to 96)
		scheduler.enqueue("execution_probe", allocate(/datum), NETRUN_TASK_NORMAL)
	for(var/pass in 1 to 3)
		worker.run_pass()
		TEST_ASSERT_EQUAL(worker.probe_calls, pass * 32, "Cheap work must use the actual remaining CPU budget, independently of an old expensive task sample")
	TEST_ASSERT_EQUAL(scheduler.pending(), 0, "A finite burst must leave no pending task after its bounded worker passes")
	TEST_ASSERT_EQUAL(scheduler.counts[NETRUN_TASK_NORMAL], 0, "Draining must reconcile the per-priority counters")

/// Every kind of admitted backlog needs fast follow-up, including prewarm and node work.
/datum/unit_test/netrun_execution_backlog_cadence/Run()
	var/datum/controller/subsystem/netrun/netrun_execution_test/worker = allocate(/datum/controller/subsystem/netrun/netrun_execution_test)
	worker.get_task_scheduler().enqueue("execution_probe", allocate(/datum), NETRUN_TASK_BACKGROUND)
	worker.refresh_delivery_interval()
	TEST_ASSERT_EQUAL(worker.wait, world.tick_lag, "A pending non-delivery task must not wait for the idle subsystem interval")
	qdel(worker.task_scheduler.take())
	worker.refresh_delivery_interval()
	TEST_ASSERT_EQUAL(worker.wait, NETRUN_DEFAULT_FIRE_INTERVAL, "A drained queue must return to its idle cadence")

/datum/unit_test/netrun_execution_live_limits/Run()
	var/datum/controller/subsystem/netrun/original = SSnetrun
	var/datum/controller/subsystem/netrun/netrun_execution_test/worker = allocate(/datum/controller/subsystem/netrun/netrun_execution_test)
	TEST_ASSERT_EQUAL(SSnetrun, original, "The fixture must not replace the running subsystem")
	worker.task_adaptive_budget = FALSE
	worker.task_budget_ms = NETRUN_EXECUTION_MAX_BUDGET_MS
	worker.task_max_per_pass = 3
	worker.task_min_per_pass = 3
	worker.task_population_interval = 17
	var/datum/netrun_task_scheduler/scheduler = worker.get_task_scheduler()
	for(var/i in 1 to 7)
		scheduler.enqueue("execution_probe", allocate(/datum), NETRUN_TASK_CRITICAL, TRUE)
	worker.run_pass()
	TEST_ASSERT_EQUAL(worker.probe_calls, 3, "Even interactive input must obey the configured per-fire task limit")
	TEST_ASSERT_EQUAL(worker.next_task_population, world.time + 17, "Population interval must come from subsystem tuning")
	worker.task_max_per_pass = 1
	worker.run_pass()
	TEST_ASSERT_EQUAL(worker.probe_calls, 4, "Changing the public maximum must apply on the next pass without rebuilding the scheduler")
	TEST_ASSERT_EQUAL(worker.probe_populations, 1, "Extra responsive passes must not repopulate all background work")
	worker.task_budget_ms = 4
	worker.task_min_budget_ms = 0.5
	worker.task_pressure_tick_usage = 80
	worker.task_adaptive_budget = TRUE
	var/datum/netrun_execution_limits/limits = worker.get_execution_limits(TRUE)
	TEST_ASSERT_EQUAL(limits.budget_for(40), 2, "Adaptive CPU budget must use the configured pressure threshold")
	TEST_ASSERT_EQUAL(limits.budget_for(160), 0.5, "CPU pressure must retain the configured bounded minimum")
	worker.task_adaptive_budget = FALSE
	limits = worker.get_execution_limits(TRUE)
	TEST_ASSERT_EQUAL(limits.budget_for(160), 4, "Fixed mode must retain the configured normal budget")

/datum/unit_test/netrun_execution_invalid_limits_and_fairness/Run()
	var/datum/controller/subsystem/netrun/netrun_execution_test/worker = allocate(/datum/controller/subsystem/netrun/netrun_execution_test)
	worker.task_budget_ms = "bad"
	worker.task_min_budget_ms = INFINITY
	worker.task_max_per_pass = -3
	worker.task_min_per_pass = 100000
	worker.apc_prebuild_operations = 100000
	worker.task_population_interval = -1
	worker.task_interactive_burst = 0
	worker.task_priority_rotation = list(NETRUN_TASK_CRITICAL, NETRUN_TASK_CRITICAL, "bad", 1.5)
	var/datum/netrun_execution_limits/limits = worker.get_execution_limits(TRUE)
	TEST_ASSERT_EQUAL(limits.budget_ms, NETRUN_DEFAULT_TASK_BUDGET_MS, "Invalid numeric input must fall back to a finite budget")
	TEST_ASSERT(limits.min_budget_ms > 0 && limits.min_budget_ms <= limits.budget_ms, "Minimum CPU budget must remain bounded")
	TEST_ASSERT_EQUAL(limits.max_per_pass, 1, "Negative task counts must retain progress through one bounded task")
	TEST_ASSERT_EQUAL(limits.min_per_pass, 1, "An inverted minimum cannot bypass the maximum")
	TEST_ASSERT_EQUAL(limits.apc_operations, NETRUN_EXECUTION_MAX_PREBUILD_OPERATIONS, "A topology slice must have a finite upper bound")
	TEST_ASSERT_EQUAL(limits.population_interval, NETRUN_EXECUTION_MIN_INTERVAL, "A negative interval cannot spin without advancing time")
	var/datum/netrun_task_scheduler/scheduler = allocate(/datum/netrun_task_scheduler, limits)
	for(var/priority in NETRUN_TASK_CRITICAL to NETRUN_TASK_BACKGROUND)
		scheduler.enqueue("probe", allocate(/datum), priority)
	var/list/seen = list()
	for(var/i in 1 to 3)
		var/datum/netrun_task/task = scheduler.take()
		TEST_ASSERT_NOTNULL(task, "Malformed rotation must still make pending work reachable")
		seen |= task.priority
		qdel(task)
	TEST_ASSERT_EQUAL(length(seen), 3, "Repairing a malformed rotation must preserve all priority classes")

/datum/unit_test/netrun_execution_interactive_preemption/Run()
	var/datum/netrun_execution_limits/limits = allocate(/datum/netrun_execution_limits)
	limits.interactive_burst = 2
	var/datum/netrun_task_scheduler/scheduler = allocate(/datum/netrun_task_scheduler, limits)
	scheduler.dispatch_cursor = 3 // The weighted rotation would dispatch background next.
	var/datum/background = allocate(/datum)
	var/datum/player = allocate(/datum)
	scheduler.enqueue("probe", background, NETRUN_TASK_BACKGROUND)
	scheduler.enqueue("probe", player, NETRUN_TASK_BACKGROUND)
	scheduler.enqueue("probe", player, NETRUN_TASK_CRITICAL, TRUE)
	scheduler.enqueue("probe", player, NETRUN_TASK_CRITICAL, TRUE)
	scheduler.enqueue("probe", allocate(/datum), NETRUN_TASK_CRITICAL, TRUE)
	scheduler.enqueue("probe", allocate(/datum), NETRUN_TASK_CRITICAL, TRUE)
	TEST_ASSERT_EQUAL(scheduler.pending(), 4, "Repeated player input must promote and coalesce the existing work item")
	var/datum/netrun_task/task = scheduler.take()
	TEST_ASSERT_EQUAL(task.target(), player, "Input must preempt already queued background regardless of rotation cursor")
	qdel(task)
	task = scheduler.take()
	TEST_ASSERT(task.interactive, "A bounded input burst must retain highest service priority")
	qdel(task)
	task = scheduler.take()
	TEST_ASSERT_EQUAL(task.target(), background, "Sustained input must still allow maintenance after the configured burst")
	qdel(task)
