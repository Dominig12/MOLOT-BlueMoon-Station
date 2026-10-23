// NETRUN ADAPTIVE TASK SCHEDULER V1
#define NETRUN_TASK_CRITICAL 1
#define NETRUN_TASK_NORMAL 2
#define NETRUN_TASK_BACKGROUND 3

/datum/netrun_task
	var/kind
	var/key
	var/priority
	var/datum/weakref/target_ref
	var/enqueued_at

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

/// Aggregate statistics without keeping references to processed objects.
/datum/netrun_task_profile
	var/calls = 0
	var/total_ms = 0
	var/peak_ms = 0
	var/average_ms = 0
	var/total_wait_ds = 0
	var/peak_wait_ds = 0
	var/overdue = 0

/// Tasks are merged by kind and target; tombstones allow cheap promotions.
/datum/netrun_task_scheduler
	var/list/by_key = list()
	var/list/critical = list()
	var/list/normal = list()
	var/list/background = list()
	var/critical_read = 1
	var/normal_read = 1
	var/background_read = 1
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

/datum/netrun_task_scheduler/proc/pending()
	return length(by_key)

/datum/netrun_task_scheduler/proc/append_task(datum/netrun_task/task)
	switch(task.priority)
		if(NETRUN_TASK_CRITICAL)
			critical += task
		if(NETRUN_TASK_NORMAL)
			normal += task
		if(NETRUN_TASK_BACKGROUND)
			background += task

/datum/netrun_task_scheduler/proc/enqueue(kind, datum/target, priority = NETRUN_TASK_NORMAL)
	if(!kind || (target && QDELETED(target)))
		return FALSE
	priority = clamp(priority, NETRUN_TASK_CRITICAL, NETRUN_TASK_BACKGROUND)
	var/key = "[kind]:[target ? REF(target) : "global"]"
	var/datum/netrun_task/existing = by_key[key]
	if(existing && !QDELETED(existing))
		merged++
		if(priority < existing.priority)
			counts[existing.priority]--
			existing.priority = priority
			counts[priority]++
			peak_queued_by_priority[priority] = max(peak_queued_by_priority[priority], counts[priority])
			append_task(existing)
			promoted++
		return FALSE
	var/datum/netrun_task/task = new(kind, key, priority, target)
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
	var/list/queue
	var/read_at
	switch(priority)
		if(NETRUN_TASK_CRITICAL)
			queue = critical
			read_at = critical_read
		if(NETRUN_TASK_NORMAL)
			queue = normal
			read_at = normal_read
		if(NETRUN_TASK_BACKGROUND)
			queue = background
			read_at = background_read
	if(!queue)
		return null
	var/datum/netrun_task/result
	var/scanned = 0
	while(read_at <= length(queue) && scanned < 32)
		scanned++
		var/datum/netrun_task/task = queue[read_at]
		queue[read_at] = null
		read_at++
		if(QDELETED(task) || task.priority != priority || by_key[task.key] != task)
			continue
		by_key -= task.key
		counts[priority]--
		result = task
		break
	if(read_at > length(queue))
		queue.Cut()
		read_at = 1
	else if(read_at > 64 && read_at > length(queue) / 2)
		queue.Cut(1, read_at)
		read_at = 1
	switch(priority)
		if(NETRUN_TASK_CRITICAL)
			critical_read = read_at
		if(NETRUN_TASK_NORMAL)
			normal_read = read_at
		if(NETRUN_TASK_BACKGROUND)
			background_read = read_at
	return result

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
	critical.Cut()
	normal.Cut()
	background.Cut()
	return ..()

