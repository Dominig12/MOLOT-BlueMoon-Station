/// The scheduler owns pending tasks; tasks own their worker behavior and weak target.
/datum/netrun_task
	var/kind
	var/key
	var/priority
	var/datum/weakref/target_ref
	var/enqueued_at
	/// Intrusive FIFO links: cancellation and promotion unlink in constant time.
	var/datum/netrun_task_queue/queue
	var/datum/netrun_task/previous
	var/datum/netrun_task/next

/datum/netrun_task/New(new_kind, new_key, new_priority, datum/target)
	. = ..()
	kind = new_kind
	key = new_key
	priority = new_priority
	enqueued_at = world.time
	if(target)
		target_ref = WEAKREF(target)

/datum/netrun_task/proc/target()
	return target_ref?.resolve()

/datum/netrun_task/Destroy()
	queue?.remove(src)
	target_ref = null
	return ..()

/datum/netrun_task/proc/execute(datum/controller/subsystem/netrun/worker)
	return FALSE

/// A queue never contains cancelled tasks or obsolete priority entries.
/datum/netrun_task_queue
	var/datum/netrun_task/first
	var/datum/netrun_task/last

/datum/netrun_task_queue/proc/append(datum/netrun_task/task)
	if(task.queue)
		task.queue.remove(task)
	task.queue = src
	task.previous = last
	if(last)
		last.next = task
	else
		first = task
	last = task

/datum/netrun_task_queue/proc/remove(datum/netrun_task/task)
	if(task.queue != src)
		return FALSE
	if(task.previous)
		task.previous.next = task.next
	else
		first = task.next
	if(task.next)
		task.next.previous = task.previous
	else
		last = task.previous
	task.queue = null
	task.previous = null
	task.next = null
	return TRUE

/datum/netrun_task_queue/proc/take()
	var/datum/netrun_task/task = first
	if(task)
		remove(task)
	return task

/datum/netrun_task_queue/Destroy()
	while(first)
		qdel(take())
	return ..()

/// Each work kind is independently extensible, without a switch in SSnetrun.
/datum/netrun_task/node
	kind = "node"

/datum/netrun_task/node/execute(datum/controller/subsystem/netrun/worker)
	var/datum/component/netrun_node/node = target()
	if(QDELETED(node))
		return FALSE
	worker.dirty_nodes -= node
	var/datum/netrun_topology/graph = worker.get_topology()
	if(node.is_dynamic() || !node.binding_checked || node.binding_infra_revision != graph.infrastructure_revision)
		node.join_network()
	node.reconcile_state()
	worker.track_node(node)
	worker.last_processed_nodes++
	return TRUE

/datum/netrun_task/console
	kind = "console"

/datum/netrun_task/console/execute(datum/controller/subsystem/netrun/worker)
	var/datum/netrun_console/console = target()
	if(QDELETED(console))
		return FALSE
	var/delta = isnull(console.last_netrun_tick) ? 0 : max(0, world.time - console.last_netrun_tick) / (1 SECONDS)
	console.last_netrun_tick = world.time
	console.access_session.process_events()
	console.process_tick(delta)
	// Dive-link processing can end the dive and destroy the originating console.
	if(QDELETED(console))
		return TRUE
	console.flush_ui()
	worker.last_processed_consoles++
	if(!QDELETED(console) && !console.needs_processing())
		worker.active_consoles -= console
	return TRUE

/datum/netrun_task/ice
	kind = "ice"

/datum/netrun_task/ice/execute(datum/controller/subsystem/netrun/worker)
	var/datum/netrun_ice/ice = target()
	if(QDELETED(ice))
		return FALSE
	var/delta = max(0, world.time - ice.last_netrun_tick) / (1 SECONDS)
	ice.last_netrun_tick = world.time
	worker.breach_snapshot_active = TRUE
	ice.process_ai(delta)
	worker.breach_snapshot_active = FALSE
	return TRUE

/datum/netrun_task/housekeeping
	kind = "housekeeping"

/datum/netrun_task/housekeeping/execute(datum/controller/subsystem/netrun/worker)
	var/datum/netrun_topology/graph = worker.get_topology()
	if(graph.dirty)
		worker.get_task_scheduler().enqueue("apc_prebuild", graph, NETRUN_TASK_BACKGROUND)
	graph.refresh_route_tables()
	if(!worker.patrol_initialized && length(worker.networks))
		worker.initialize_patrol()
	if(!worker.lore_initialized && length(worker.nodes_by_address))
		worker.initialize_lore()
	return TRUE

/// Bounded upstream topology preparation stays behind its own task implementation.
/datum/netrun_task/apc_prebuild
	kind = "apc_prebuild"

/datum/netrun_task/apc_prebuild/execute(datum/controller/subsystem/netrun/worker)
	var/datum/netrun_topology/graph = target()
	if(QDELETED(graph) || !graph.dirty)
		return FALSE
	worker.apc_prebuild_steps++
	if(!graph.advance_apc_prebuild(96) && graph.dirty)
		worker.get_task_scheduler().enqueue(kind, graph, NETRUN_TASK_BACKGROUND)
	return TRUE

/// Aggregate statistics without keeping references to processed objects.
/datum/netrun_task_profile
	var/calls = 0
	var/total_ms = 0
	var/peak_ms = 0
	var/average_ms = 0
	var/total_wait_ds = 0
	var/peak_wait_ds = 0
	var/overdue = 0

/// Tasks are merged by kind and target, with fair service for all three priorities.
/datum/netrun_task_scheduler
	var/list/by_key = list()
	var/list/queues
	var/list/counts = list(0, 0, 0)
	var/dispatch_cursor = 0
	var/merged = 0
	var/promoted = 0
	var/completed = 0
	var/cancelled = 0
	var/last_budget_ms = 0
	var/last_execution_ms = 0
	var/last_executed = 0
	var/average_ms = 0.1
	var/max_task_ms = 0
	/// Keys are task kinds; values are /datum/netrun_task_profile.
	var/list/profiles = list()
	var/list/executed_by_priority = list(0, 0, 0)
	var/list/peak_queued_by_priority = list(0, 0, 0)
	var/list/max_wait_by_priority = list(0, 0, 0)
	var/list/overdue_by_priority = list(0, 0, 0)
	var/peak_pending = 0
	var/budget_overruns = 0
	var/task_overruns = 0
	var/peak_pass_ms = 0

/datum/netrun_task_scheduler/New()
	. = ..()
	queues = list(new /datum/netrun_task_queue, new /datum/netrun_task_queue, new /datum/netrun_task_queue)

/datum/netrun_task_scheduler/proc/pending()
	return length(by_key)

/datum/netrun_task_scheduler/proc/append_task(datum/netrun_task/task)
	var/datum/netrun_task_queue/queue = queues[task.priority]
	queue.append(task)

/// Registry metadata is read once; new work kinds only add a task subtype.
/datum/netrun_task_scheduler/proc/task_type(kind)
	var/static/list/types_by_kind
	if(!types_by_kind)
		types_by_kind = list()
		for(var/datum/netrun_task/path as anything in subtypesof(/datum/netrun_task))
			if(initial(path.kind))
				types_by_kind[initial(path.kind)] = path
	return types_by_kind[kind] ? types_by_kind[kind] : /datum/netrun_task

/datum/netrun_task_scheduler/proc/enqueue(kind, datum/target, priority = NETRUN_TASK_NORMAL)
	if(!kind || (target && QDELETED(target)))
		return FALSE
	priority = clamp(priority, NETRUN_TASK_CRITICAL, NETRUN_TASK_BACKGROUND)
	var/key = "[kind]:[target ? REF(target) : "global"]"
	var/datum/netrun_task/existing = by_key[key]
	if(existing && !QDELETED(existing))
		merged++
		if(priority < existing.priority)
			existing.queue.remove(existing)
			counts[existing.priority]--
			existing.priority = priority
			counts[priority]++
			peak_queued_by_priority[priority] = max(peak_queued_by_priority[priority], counts[priority])
			append_task(existing)
			promoted++
		return FALSE
	var/path = task_type(kind)
	var/datum/netrun_task/task = new path(kind, key, priority, target)
	by_key[key] = task
	counts[priority]++
	peak_queued_by_priority[priority] = max(peak_queued_by_priority[priority], counts[priority])
	peak_pending = max(peak_pending, length(by_key))
	append_task(task)
	return TRUE

/datum/netrun_task_scheduler/proc/cancel(kind, datum/target)
	var/key = "[kind]:[target ? REF(target) : "global"]"
	var/datum/netrun_task/task = by_key[key]
	if(!task)
		return FALSE
	counts[task.priority]--
	by_key -= key
	cancelled++
	qdel(task)
	return TRUE

/datum/netrun_task_scheduler/proc/take_priority(priority)
	if(priority < NETRUN_TASK_CRITICAL || priority > NETRUN_TASK_BACKGROUND)
		return null
	var/datum/netrun_task_queue/queue = queues[priority]
	var/datum/netrun_task/task = queue.take()
	if(!task)
		return null
	by_key -= task.key
	counts[priority]--
	return task

/datum/netrun_task_scheduler/proc/take()
	var/static/list/rotation = list(NETRUN_TASK_CRITICAL, NETRUN_TASK_NORMAL, NETRUN_TASK_CRITICAL, NETRUN_TASK_BACKGROUND, NETRUN_TASK_CRITICAL, NETRUN_TASK_NORMAL, NETRUN_TASK_CRITICAL)
	for(var/i in 1 to length(rotation))
		dispatch_cursor = (dispatch_cursor % length(rotation)) + 1
		var/datum/netrun_task/task = take_priority(rotation[dispatch_cursor])
		if(task)
			return task
	return null

/// Time is measured on the worker side; enqueue-to-start delay is also recorded.
/datum/netrun_task_scheduler/proc/note_execution(datum/netrun_task/task, cost_ms)
	if(!task)
		return
	completed++
	var/priority = task.priority
	var/wait_ds = max(0, world.time - task.enqueued_at)
	var/deadline_ds = 20 SECONDS
	switch(priority)
		if(NETRUN_TASK_CRITICAL)
			deadline_ds = 2 SECONDS
		if(NETRUN_TASK_NORMAL)
			deadline_ds = 5 SECONDS
	executed_by_priority[priority]++
	max_wait_by_priority[priority] = max(max_wait_by_priority[priority], wait_ds)
	max_task_ms = max(max_task_ms, cost_ms)
	average_ms = average_ms * 0.85 + cost_ms * 0.15
	var/datum/netrun_task_profile/profile = profiles[task.kind]
	if(!profile)
		profile = new
		profiles[task.kind] = profile
	profile.calls++
	profile.total_ms += cost_ms
	profile.peak_ms = max(profile.peak_ms, cost_ms)
	profile.average_ms = profile.total_ms / profile.calls
	profile.total_wait_ds += wait_ds
	profile.peak_wait_ds = max(profile.peak_wait_ds, wait_ds)
	if(wait_ds > deadline_ds)
		profile.overdue++
		overdue_by_priority[priority]++

/// Compact per-kind snapshot, safe for administrator diagnostics.
/datum/netrun_task_scheduler/proc/profile_summary()
	var/list/parts = list()
	for(var/kind in profiles)
		var/datum/netrun_task_profile/profile = profiles[kind]
		parts += "[kind]:[profile.calls]x avg=[round(profile.average_ms, 0.01)]ms max=[round(profile.peak_ms, 0.01)]ms wait=[round(profile.peak_wait_ds / (1 SECONDS), 0.1)]s"
	return jointext(parts, " | ")

/datum/netrun_task_scheduler/Destroy()
	for(var/key in by_key)
		qdel(by_key[key])
	by_key.Cut()
	for(var/kind in profiles)
		qdel(profiles[kind])
	profiles.Cut()
	QDEL_LIST(queues)
	return ..()

