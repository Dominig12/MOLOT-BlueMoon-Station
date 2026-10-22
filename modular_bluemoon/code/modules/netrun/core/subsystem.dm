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

SUBSYSTEM_DEF(netrun)
	name = "Netrun"
	wait = 2
	flags = SS_BACKGROUND
	runlevels = RUNLEVEL_GAME | RUNLEVEL_POSTGAME

	/// id = /datum/netrun_network
	var/list/networks = list()
	/// адрес = /datum/component/netrun_node
	var/list/nodes_by_address = list()
	var/list/datum/netrun_console/consoles = list()
	var/list/mob/camera/netrun_entity/entities = list()
	/// id = /datum/netrun_command
	var/list/commands
	var/datum/netrun_task_scheduler/task_scheduler
	var/next_task_population = 0
	var/task_populations = 0
	var/apc_prebuild_steps = 0
	/// HUD profiling: a single response may have many targets but at most one route snapshot.
	var/combat_full_payloads = 0
	var/combat_summary_payloads = 0
	var/combat_ui_tree_builds = 0
	var/combat_full_payload_ms = 0
	var/combat_full_payload_peak_ms = 0
	/// Only sessions with timers, a live UI or an entity are processed.
	var/list/active_consoles = list()
	/// Moving devices and native states that genuinely lack notifications.
	var/list/poll_nodes = list()
	var/list/dirty_nodes = list()
	/// node -> next transient expiry (activity, reboot, firewall).
	var/list/timed_nodes = list()
	var/last_processed_nodes = 0
	var/last_processed_consoles = 0
	/// Topology rebuild instrumentation; timing only while adaptive profiling is armed.
	var/topology_rebuilds = 0
	var/topology_rebuild_ms = 0
	var/topology_rebuild_peak_ms = 0
	/// Counters in the subsystem status panel (since world startup).
	var/camera_feed_scans = 0
	var/camera_feed_cache_hits = 0
	var/camera_route_borrows = 0
	var/wire_session_sweeps = 0
	var/camera_feed_scan_ms = 0
	var/camera_feed_scan_max_ms = 0
	var/camera_route_check_ms = 0
	var/camera_route_check_max_ms = 0
	var/pass_item_count = 0
	var/list/currentbreaches = list()
	var/breach_snapshot_active = FALSE
	var/reconcile_nodes = FALSE
	/// Общая лента недавних событий сети - её видят все раннеры на карте.
	/// list(list("kind","from","to","t"))
	var/list/events = list()
	var/datum/netrun_topology/topology

/datum/controller/subsystem/netrun/stat_entry(msg)
	msg = "N:[length(nodes_by_address)] P:[length(poll_nodes)] Q:[length(dirty_nodes)] C:[length(active_consoles)]/[length(consoles)] E:[length(entities)] Last N:[last_processed_nodes] C:[last_processed_consoles] T:[topology_rebuilds] F:[camera_feed_scans]/[camera_feed_cache_hits] R:[camera_route_borrows] W:[wire_session_sweeps] I:[topology?.indexed_infrastructure_visits || 0]"
	if(task_scheduler)
		var/datum/netrun_task_scheduler/scheduler = task_scheduler
		msg += " Tasks:[scheduler.pending()] Q:[scheduler.counts[1]]/[scheduler.counts[2]]/[scheduler.counts[3]] Qpeak:[scheduler.peak_pending] Done:[scheduler.completed] Merge:[scheduler.merged] Pr:[scheduler.promoted] Budget:[round(scheduler.last_execution_ms, 0.1)]/[round(scheduler.last_budget_ms, 0.1)]ms"
		msg += " APWork:[apc_prebuild_steps] APCmp:[topology?.apc_prebuild?.comparisons || 0] Combat UI:[combat_full_payloads]/[combat_summary_payloads] Paths:[combat_ui_tree_builds]"
		if(profile_armed)
			msg += " Combat ms total/max:[round(combat_full_payload_ms, 0.1)]/[round(combat_full_payload_peak_ms, 0.1)]"
		msg += " Exec:[scheduler.executed_by_priority[1]]/[scheduler.executed_by_priority[2]]/[scheduler.executed_by_priority[3]] WaitMax:[round(scheduler.max_wait_by_priority[1] / (1 SECONDS), 0.1)]/[round(scheduler.max_wait_by_priority[2] / (1 SECONDS), 0.1)]/[round(scheduler.max_wait_by_priority[3] / (1 SECONDS), 0.1)]s Late:[scheduler.overdue_by_priority[1]]/[scheduler.overdue_by_priority[2]]/[scheduler.overdue_by_priority[3]] Ovr:[scheduler.budget_overruns]/[scheduler.task_overruns]"
	if(profile_armed)
		msg += " Cam ms total/max F:[round(camera_feed_scan_ms, 0.1)]/[round(camera_feed_scan_max_ms, 0.1)] R:[round(camera_route_check_ms, 0.1)]/[round(camera_route_check_max_ms, 0.1)]"
	return ..()

/// Coalescing worksets keep quiet machines and terminals out of the one-second pass.
/datum/controller/subsystem/netrun/proc/queue_node(datum/component/netrun_node/node)
	if(!QDELETED(node))
		dirty_nodes[node] = TRUE

/// A display snapshot can be requested before the next one-second node pass.
/// Inspect only queued native changes; command execution still builds fresh routes.
/datum/controller/subsystem/netrun/proc/reconcile_dirty_availability()
	for(var/datum/component/netrun_node/node as anything in dirty_nodes)
		if(QDELETED(node))
			continue
		var/online = node.is_online()
		if(online != node.last_online)
			node.last_online = online
			get_topology().availability_changed(node)

/datum/controller/subsystem/netrun/proc/track_node(datum/component/netrun_node/node)
	if(QDELETED(node))
		return
	var/atom/endpoint = node.parent
	if(node.is_dynamic() || endpoint.netrun_needs_poll())
		poll_nodes[node] = TRUE
	else
		poll_nodes -= node
	var/next_expiry = INFINITY
	if(node.offline_until > world.time)
		next_expiry = min(next_expiry, node.offline_until)
	if(node.firewall_until > world.time)
		next_expiry = min(next_expiry, node.firewall_until)
	if(node.last_activity + 5 SECONDS > world.time)
		next_expiry = min(next_expiry, node.last_activity + 5 SECONDS)
	if(next_expiry < INFINITY)
		timed_nodes[node] = next_expiry
	else
		timed_nodes -= node

/datum/controller/subsystem/netrun/proc/untrack_node(datum/component/netrun_node/node)
	poll_nodes -= node
	dirty_nodes -= node
	timed_nodes -= node
	task_scheduler?.cancel("node", node)

/datum/controller/subsystem/netrun/proc/get_task_scheduler()
	if(!task_scheduler)
		task_scheduler = new
		RegisterSignal(src, COMSIG_NETRUN_TOPOLOGY_DIRTY, PROC_REF(on_topology_dirty))
	return task_scheduler

/datum/controller/subsystem/netrun/proc/on_topology_dirty(datum/source, datum/netrun_topology/graph, generation)
	SIGNAL_HANDLER
	task_scheduler?.enqueue("apc_prebuild", graph, NETRUN_TASK_BACKGROUND)

/datum/controller/subsystem/netrun/proc/populate_tasks()
	task_populations++
	var/datum/netrun_task_scheduler/scheduler = get_task_scheduler()
	currentbreaches.Cut()
	var/reconcile = length(entities) || !patrol_initialized || !lore_initialized
	for(var/datum/netrun_console/console as anything in active_consoles)
		if(QDELETED(console))
			active_consoles -= console
			continue
		if(console.intrusion.breach)
			currentbreaches += console
		if(!console.needs_processing())
			active_consoles -= console
			continue
		reconcile = TRUE
		var/priority = console.intrusion.breach || console.is_locked() ? NETRUN_TASK_CRITICAL : NETRUN_TASK_NORMAL
		scheduler.enqueue("console", console, priority)
	for(var/datum/netrun_ice/ice as anything in ice_processes)
		if(QDELETED(ice))
			continue
		scheduler.enqueue("ice", ice, ice.pending_program ? NETRUN_TASK_CRITICAL : NETRUN_TASK_NORMAL)
	for(var/datum/component/netrun_node/node as anything in dirty_nodes)
		if(!QDELETED(node))
			scheduler.enqueue("node", node, NETRUN_TASK_NORMAL)
	if(reconcile)
		for(var/datum/component/netrun_node/node as anything in poll_nodes)
			if(!QDELETED(node))
				scheduler.enqueue("node", node, NETRUN_TASK_BACKGROUND)
	for(var/datum/component/netrun_node/node as anything in timed_nodes)
		if(timed_nodes[node] <= world.time && !QDELETED(node))
			scheduler.enqueue("node", node, NETRUN_TASK_NORMAL)
	scheduler.enqueue("housekeeping", null, NETRUN_TASK_BACKGROUND)
	if(get_topology().dirty)
		scheduler.enqueue("apc_prebuild", get_topology(), NETRUN_TASK_BACKGROUND)

/datum/controller/subsystem/netrun/proc/execute_task(datum/netrun_task/task)
	var/datum/target = task.target()
	if(task.kind != "housekeeping" && QDELETED(target))
		return
	switch(task.kind)
		if("ice")
			var/datum/netrun_ice/ice = target
			var/delta = ice.last_netrun_tick ? max(0, world.time - ice.last_netrun_tick) / (1 SECONDS) : 1
			ice.last_netrun_tick = world.time
			breach_snapshot_active = TRUE
			ice.process_ai(delta)
			breach_snapshot_active = FALSE
		if("console")
			var/datum/netrun_console/console = target
			var/delta = console.last_netrun_tick ? max(0, world.time - console.last_netrun_tick) / (1 SECONDS) : 1
			console.last_netrun_tick = world.time
			console.access_session.process_events()
			console.process_tick(delta)
			console.flush_ui()
			last_processed_consoles++
			if(!QDELETED(console) && !console.needs_processing())
				active_consoles -= console
		if("node")
			var/datum/component/netrun_node/node = target
			dirty_nodes -= node
			var/datum/netrun_topology/graph = get_topology()
			if(node.is_dynamic() || !node.binding_checked || node.binding_infra_revision != graph.infrastructure_revision)
				node.join_network()
			node.reconcile_state()
			track_node(node)
			last_processed_nodes++
		if("apc_prebuild")
			var/datum/netrun_topology/graph = target
			if(graph.dirty)
				apc_prebuild_steps++
				if(!graph.advance_apc_prebuild(96) && graph.dirty)
					get_task_scheduler().enqueue("apc_prebuild", graph, NETRUN_TASK_BACKGROUND)
		if("housekeeping")
			var/datum/netrun_topology/graph = get_topology()
			if(graph.dirty)
				get_task_scheduler().enqueue("apc_prebuild", graph, NETRUN_TASK_BACKGROUND)
			graph.refresh_route_tables()
			if(!patrol_initialized && length(networks))
				initialize_patrol()
			if(!lore_initialized && length(nodes_by_address))
				initialize_lore()

/datum/controller/subsystem/netrun/fire(resumed = FALSE)
	var/slice_start_usage = TICK_USAGE
	if(!resumed)
		current_pass_cost_ms = 0
	var/datum/netrun_task_scheduler/scheduler = get_task_scheduler()
	if(!resumed && world.time >= next_task_population)
		last_processed_nodes = 0
		last_processed_consoles = 0
		populate_tasks()
		next_task_population = world.time + 1 SECONDS
	var/pressure = clamp(TICK_USAGE / 100, 0, 1)
	var/budget_ms = clamp(2.0 * (1 - pressure), 0.30, 2.0)
	var/max_items = clamp(round(budget_ms / max(scheduler.average_ms, 0.05)), 2, 48)
	var/executed = 0
	while(executed < max_items)
		if(executed && max(0, TICK_DELTA_TO_MS(TICK_USAGE - slice_start_usage)) >= budget_ms)
			break
		var/datum/netrun_task/task = scheduler.take()
		if(!task)
			break
		var/task_started = TICK_USAGE
		var/datum/target = task.target()
		execute_task(task)
		var/cost_ms = max(0, TICK_DELTA_TO_MS(TICK_USAGE - task_started))
		scheduler.note_execution(task, cost_ms)
		if(cost_ms > budget_ms)
			scheduler.task_overruns++
		if(profile_armed)
			profile_note("netrun/task/[task.kind]", cost_ms, QDELETED(target) ? null : target)
		qdel(task)
		executed++
		if(MC_TICK_CHECK)
			scheduler.last_executed = executed
			scheduler.last_budget_ms = budget_ms
			scheduler.last_execution_ms = max(0, TICK_DELTA_TO_MS(TICK_USAGE - slice_start_usage))
			scheduler.peak_pass_ms = max(scheduler.peak_pass_ms, scheduler.last_execution_ms)
			if(scheduler.last_execution_ms > budget_ms)
				scheduler.budget_overruns++
			current_pass_cost_ms += scheduler.last_execution_ms
			return
	scheduler.last_executed = executed
	scheduler.last_budget_ms = budget_ms
	scheduler.last_execution_ms = max(0, TICK_DELTA_TO_MS(TICK_USAGE - slice_start_usage))
	scheduler.peak_pass_ms = max(scheduler.peak_pass_ms, scheduler.last_execution_ms)
	if(scheduler.last_execution_ms > budget_ms)
		scheduler.budget_overruns++
	current_pass_cost_ms += scheduler.last_execution_ms
	on_pass_finished(executed)

/datum/controller/subsystem/netrun/proc/get_network(id)
	if(!id)
		return
	var/datum/netrun_network/network = networks[id]
	if(!network)
		network = new(id)
		networks[id] = network
	return network

/// Allocation only: node lifecycle and bindings must never recursively build the graph.
/datum/controller/subsystem/netrun/proc/get_topology()
	if(!topology)
		topology = new
	return topology

/datum/controller/subsystem/netrun/proc/ensure_topology()
	var/datum/netrun_topology/result = get_topology()
	if(result.deferred_bindings && SSatoms.initialized == INITIALIZATION_INNEW_REGULAR)
		result.invalidate()
	if(result.dirty && !result.rebuilding)
		var/rebuild_started = profile_armed ? TICK_USAGE : 0
		result.rebuild()
		topology_rebuilds++
		if(profile_armed)
			var/rebuild_ms = max(0, TICK_DELTA_TO_MS(TICK_USAGE - rebuild_started))
			topology_rebuild_ms += rebuild_ms
			topology_rebuild_peak_ms = max(topology_rebuild_peak_ms, rebuild_ms)
			profile_note("topology/rebuild", rebuild_ms, result)
	return result

/// ЛВС кластеризуется по отделу внутри физического сектора: все APC одного отдела делят
/// одну сеть, ключ и защиту (= максимум среди узлов). Один ключ открывает весь отдел.
/datum/controller/subsystem/netrun/proc/get_apc_network(datum/component/netrun_node/apc_node)
	if(QDELETED(apc_node) || apc_node.node_type != NETRUN_NODE_APC)
		return null
	var/turf/here = get_turf(apc_node.parent)
	// The department lookup (sector + area type + string id) only changes when the APC moves,
	// so cache the resolved LAN per turf instead of recomputing it for every tick.
	if(apc_node.network && apc_node.apc_network_turf == here && networks[apc_node.network.id] == apc_node.network)
		return apc_node.network
	var/area/source_area
	if(istype(apc_node.parent, /obj/machinery/power/apc))
		var/obj/machinery/power/apc/apc = apc_node.parent
		source_area = apc.area
	if(!source_area)
		source_area = get_area(apc_node.parent)
	source_area = source_area?.base_area || source_area
	var/sector = netrun_sector_for(here)
	var/id = "dept_[sector || "none"]:[netrun_department_key(source_area)]"
	var/datum/netrun_network/network = networks[id]
	if(!network)
		network = new(id, source_area)
		networks[id] = network
	apc_node.apc_network_turf = here
	return network

/// ЛВС отсека: по одной на APC-зону, свойства берутся из типа отсека.
/datum/controller/subsystem/netrun/proc/get_area_network(area/root_area)
	if(!root_area)
		return
	var/datum/component/netrun_node/apc_node = root_area.power_apc?.GetComponent(/datum/component/netrun_node)
	if(apc_node)
		return get_apc_network(apc_node)
	if(!root_area.netrun_lan_id)
		root_area.netrun_lan_id = "lan_[REF(root_area)]"
	var/datum/netrun_network/network = networks[root_area.netrun_lan_id]
	if(!network)
		network = new(root_area.netrun_lan_id, root_area)
		networks[network.id] = network
	return network

/// Зарегистрировать событие сети: его отрисуют карты всех активных раннеров.
/datum/controller/subsystem/netrun/proc/post_event(kind, from_ref, to_ref)
	events += list(list("kind" = kind, "from" = from_ref, "to" = to_ref, "t" = world.time))
	if(length(events) > 40)
		events.Cut(1, length(events) - 40 + 1)
	SEND_SIGNAL(src, COMSIG_NETRUN_EVENT_POSTED, kind, from_ref, to_ref)

/// Недавние события (последние секунды) для интерфейса
/datum/controller/subsystem/netrun/proc/recent_events()
	. = list()
	for(var/list/event as anything in events)
		var/age = world.time - event["t"]
		if(age > 4 SECONDS)
			continue
		. += list(list("kind" = event["kind"], "from" = event["from"], "to" = event["to"], "age" = round(age / (1 SECONDS), 0.1)))

/datum/controller/subsystem/netrun/proc/get_command(id)
	if(!commands)
		commands = list()
		for(var/datum/netrun_command/path as anything in subtypesof(/datum/netrun_command))
			if(!initial(path.id))
				continue
			var/datum/netrun_command/command = new path
			commands[command.id] = command
	return commands[netrun_command_base(id)]

/// Команда может нести аргумент после «@» (например, слот органа): door_open, heart_stop@heart
/proc/netrun_command_base(id)
	var/at = findtext("[id]", "@")
	return at ? copytext(id, 1, at) : id

/proc/netrun_command_arg(id)
	var/at = findtext("[id]", "@")
	return at ? copytext(id, at + 1) : null

/datum/controller/subsystem/netrun/proc/make_address()
	var/static/list/hex = list("0","1","2","3","4","5","6","7","8","9","A","B","C","D","E","F")
	for(var/attempt in 1 to 20)
		var/address = ""
		for(var/i in 1 to 8)
			address += pick(hex)
			if(i == 4)
				address += ":"
		if(!nodes_by_address[address])
			return address

/datum/controller/subsystem/netrun/proc/find_network(token)
	if(!token)
		return
	token = trim("[token]")
	var/datum/netrun_network/by_id = networks[lowertext(token)]
	if(by_id)
		return by_id
	var/up = uppertext(token)
	for(var/network_id in networks)
		var/datum/netrun_network/net = networks[network_id]
		if(net.code == up || uppertext(net.short_name) == up)
			return net

/datum/controller/subsystem/netrun/proc/find_node(address)
	return nodes_by_address[uppertext(trim("[address]"))]

/// Работает ли магистраль NTnet для указанного Z-уровня
/datum/controller/subsystem/netrun/proc/backbone_online(z)
	var/datum/ntnet/station/station = SSnetworks.station_network
	if(!station || station.setting_disabled)
		return FALSE
	return station.check_relay_operation(z)

/// Пишет событие в журнал NTnet - его видит мониторинг сети станции
/datum/controller/subsystem/netrun/proc/ntnet_log(text, intrusion = FALSE)
	var/datum/ntnet/station/station = SSnetworks.station_network
	if(!station)
		return
	station.add_log("NETRUN: [text]")
	if(intrusion && station.intrusion_detection_enabled)
		station.intrusion_detection_alarm = TRUE
