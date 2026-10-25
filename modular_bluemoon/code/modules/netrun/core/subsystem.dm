SUBSYSTEM_DEF(netrun)
	name = "Netrun"
	wait = NETRUN_DEFAULT_FIRE_INTERVAL
	// Machine traffic now shares this worker. Ordinary MC service prevents unrelated
	// foreground work starving delivery; the internal scheduler still bounds CPU/tasks.
	flags = 0
	runlevels = RUNLEVEL_LOBBY | RUNLEVEL_SETUP | RUNLEVEL_GAME | RUNLEVEL_POSTGAME

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
	/// Moving/legacy endpoints -> next fallback deadline; native signals bypass this schedule.
	var/list/poll_nodes = list()
	/// Short, renewable player/request interest. NPC activity does not renew these leases.
	var/list/node_interest_until = list()
	var/list/pending_requests = list()
	var/list/dirty_nodes = list()
	/// Routing drains native availability changes separately from presentation work.
	var/list/availability_nodes = list()
	/// Only temporary outages need an availability deadline; activity/firewall timers do not.
	var/list/offline_nodes = list()
	var/next_offline_expiry = INFINITY
	var/availability_checks = 0
	var/availability_expiry_visits = 0
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

/// Repeated cold inputs share one fixed trailing deadline measured from completed processing.
/datum/controller/subsystem/netrun/proc/queue_node(datum/component/netrun_node/node, urgent = FALSE)
	if(!QDELETED(node))
		node.urgent_update ||= urgent
		var/due = (urgent || node_interest_until[node] > world.time) ? world.time : max(world.time, node.last_processed_at + get_execution_limits().node_update_interval)
		if(!isnull(dirty_nodes[node]))
			due = min(due, dirty_nodes[node])
		dirty_nodes[node] = due
		if(due <= world.time)
			get_task_scheduler().enqueue("node", node, NETRUN_TASK_NORMAL)

/// A route can be requested before the next node pass, including twice in one tick.
/datum/controller/subsystem/netrun/proc/queue_availability(datum/component/netrun_node/node)
	if(!QDELETED(node))
		availability_nodes[node] = TRUE

/// Packet journals and other display changes never require native power checks.
/// The earliest outage deadline gates the small expiry index until recovery is due.
/datum/controller/subsystem/netrun/proc/reconcile_dirty_availability()
	if(world.time >= next_offline_expiry)
		next_offline_expiry = INFINITY
		for(var/datum/component/netrun_node/node as anything in offline_nodes)
			availability_expiry_visits++
			if(QDELETED(node))
				offline_nodes -= node
				continue
			if(node.offline_until <= world.time)
				offline_nodes -= node
				queue_availability(node)
			else
				offline_nodes[node] = node.offline_until
				next_offline_expiry = min(next_offline_expiry, node.offline_until)
	if(!length(availability_nodes))
		return
	var/list/pending = availability_nodes
	availability_nodes = list()
	for(var/datum/component/netrun_node/node as anything in pending)
		if(QDELETED(node))
			continue
		availability_checks++
		var/online = node.is_online()
		if(online != node.last_online)
			node.last_online = online
			get_topology().availability_changed(node)

/datum/controller/subsystem/netrun/proc/track_node(datum/component/netrun_node/node)
	if(QDELETED(node))
		return
	var/atom/endpoint = node.parent
	if(node.is_dynamic() || endpoint.netrun_needs_poll())
		if(isnull(poll_nodes[node]))
			poll_nodes[node] = world.time + get_execution_limits().node_idle_poll_interval
	else
		poll_nodes -= node
	var/next_expiry = INFINITY
	var/datum/netrun_execution_limits/limits = get_execution_limits()
	if(node.offline_until > world.time)
		next_expiry = min(next_expiry, node.offline_until)
		offline_nodes[node] = node.offline_until
		next_offline_expiry = min(next_offline_expiry, node.offline_until)
	else
		offline_nodes -= node
	if(node.firewall_until > world.time)
		next_expiry = min(next_expiry, node.firewall_until)
	if(node.last_activity + limits.node_activity_duration > world.time)
		next_expiry = min(next_expiry, node.last_activity + limits.node_activity_duration)
	if(next_expiry < INFINITY)
		timed_nodes[node] = next_expiry
	else
		timed_nodes -= node

/datum/controller/subsystem/netrun/proc/untrack_node(datum/component/netrun_node/node)
	poll_nodes -= node
	dirty_nodes -= node
	availability_nodes -= node
	offline_nodes -= node
	timed_nodes -= node
	node_interest_until -= node
	task_scheduler?.cancel("node", node)

/// Legacy fallback cadence is independent of the cold dirty/publication throttle.
/datum/controller/subsystem/netrun/proc/finish_node_poll(datum/component/netrun_node/node)
	if(isnull(poll_nodes[node]))
		return
	var/datum/netrun_execution_limits/limits = get_execution_limits()
	poll_nodes[node] = world.time + (node_interest_until[node] > world.time ? limits.node_poll_interval : limits.node_idle_poll_interval)

/// Absolute deadlines let packets/pings reuse their already calculated route without a new tree.
/datum/controller/subsystem/netrun/proc/retain_node_interest(datum/component/netrun_node/node, until)
	if(QDELETED(node) || !IS_FINITE(until) || until <= world.time)
		return FALSE
	until = min(until, world.time + NETRUN_NODE_INTEREST_LEASE)
	var/was_interested = node_interest_until[node] > world.time
	node_interest_until[node] = max(node_interest_until[node] || 0, until)
	if(!was_interested && !isnull(poll_nodes[node]))
		poll_nodes[node] = min(poll_nodes[node], world.time)
	if(!was_interested && !isnull(dirty_nodes[node]))
		queue_node(node)
	return TRUE

/// Accept either node addresses or the existing ping/packet hop representation.
/datum/controller/subsystem/netrun/proc/retain_route_interest(list/hops, until)
	for(var/hop as anything in hops)
		var/address = hop
		if(islist(hop))
			var/list/entry = hop
			if(entry["kind"] && entry["kind"] != "node")
				continue
			address = entry["ref"]
		retain_node_interest(nodes_by_address[address], until)

/// Read only retained topology/path data. Interest must not perform global discovery or routing.
/datum/controller/subsystem/netrun/proc/collect_console_node_interest(datum/netrun_console/console)
	if(QDELETED(console))
		return
	var/mob/camera/netrun_entity/entity = istype(console.host, /mob/camera/netrun_entity) ? console.host : null
	if(entity && !entity.client && !entity.dive_link?.body?.client)
		var/datum/ui_source = QDELETED(console.netrun_ui_source) ? console : console.netrun_ui_source
		if(!length(SStgui.get_all_open_uis(ui_source)))
			return
	if(!console.is_ui_active() && !entity?.client && !entity?.dive_link?.body?.client)
		return
	var/until = world.time + NETRUN_NODE_INTEREST_LEASE
	var/datum/component/netrun_node/source = console.connection.jack || entity?.host_node || netrun_find_node(console.host) || nodes_by_address[console.ui_source_address]
	retain_node_interest(source, until)
	var/list/targets = list(console.map_view.selected_address, console.remote_session.active_window, console.remote_session.watch_node?.address)
	if(console.map_view.waypoint_address)
		targets |= console.map_view.waypoint_address
	if(console.intrusion.breach && console.intrusion.breach.target_kind != "network")
		targets |= console.intrusion.breach.target_id
	var/datum/netrun_path_tree/table = (source && topology) ? topology.route_tables[source.address] : null
	for(var/address as anything in targets)
		retain_node_interest(nodes_by_address[address], until)
		if(table && address)
			retain_route_interest(table.addresses_to(address), until)
	if(entity)
		retain_route_interest(entity.navigation?.queue, until)
		retain_route_interest(entity.dive_link?.route_chain, until)
	// Neighbor lookup is confined to this attachment, then filtered by physical distance.
	// Being on an APC must not turn its whole department into a fast poll set.
	var/datum/component/netrun_node/apc = source?.node_type == NETRUN_NODE_APC ? source : source?.bound_apc
	retain_node_interest(apc, until)
	var/turf/here = source?.physical_turf()
	if(here && apc)
		var/list/neighbors = topology ? topology.adjacency[apc.address] : null
		for(var/address in neighbors)
			var/datum/component/netrun_node/neighbor = nodes_by_address[address]
			var/turf/there = neighbor?.physical_turf()
			if(there && here.z == there.z && get_dist(here, there) <= NETRUN_NODE_INTEREST_RADIUS)
				retain_node_interest(neighbor, until)

/datum/controller/subsystem/netrun/proc/collect_request_node_interest(datum/netrun_request/delivery/request)
	if(QDELETED(request) || QDELETED(request.console))
		return
	var/until = world.time + NETRUN_NODE_INTEREST_LEASE
	retain_route_interest(request.poll_route, until)
	retain_node_interest(request.node, until)
	var/datum/netrun_console/console = request.console
	var/mob/camera/netrun_entity/entity = istype(console.host, /mob/camera/netrun_entity) ? console.host : null
	retain_node_interest(console.connection.jack || entity?.host_node || netrun_find_node(console.host) || nodes_by_address[console.ui_source_address], until)

/datum/controller/subsystem/netrun/proc/populate_node_tasks()
	var/datum/netrun_task_scheduler/scheduler = get_task_scheduler()
	for(var/datum/component/netrun_node/node as anything in node_interest_until)
		if(QDELETED(node) || node_interest_until[node] <= world.time)
			node_interest_until -= node
	for(var/datum/component/netrun_node/node as anything in dirty_nodes)
		if(!QDELETED(node) && dirty_nodes[node] <= world.time)
			scheduler.enqueue("node", node, NETRUN_TASK_NORMAL)
	for(var/datum/component/netrun_node/node as anything in poll_nodes)
		if(QDELETED(node))
			poll_nodes -= node
			continue
		if(poll_nodes[node] <= world.time)
			scheduler.enqueue("node", node, NETRUN_TASK_BACKGROUND)
	for(var/datum/component/netrun_node/node as anything in timed_nodes)
		if(timed_nodes[node] <= world.time && !QDELETED(node))
			queue_node(node, TRUE)

/datum/controller/subsystem/netrun/proc/get_task_scheduler()
	RETURN_TYPE(/datum/netrun_task_scheduler)
	if(!task_scheduler)
		task_scheduler = new(get_execution_limits())
		RegisterSignal(src, COMSIG_NETRUN_TOPOLOGY_DIRTY, PROC_REF(on_topology_dirty))
	return task_scheduler

/datum/controller/subsystem/netrun/proc/on_topology_dirty(datum/source, datum/netrun_topology/graph, generation)
	SIGNAL_HANDLER
	task_scheduler?.enqueue("apc_prebuild", graph, NETRUN_TASK_BACKGROUND)

/datum/controller/subsystem/netrun/proc/populate_tasks()
	task_populations++
	var/datum/netrun_task_scheduler/scheduler = get_task_scheduler()
	currentbreaches.Cut()
	for(var/datum/netrun_console/console as anything in active_consoles)
		if(QDELETED(console))
			active_consoles -= console
			continue
		if(console.intrusion.breach)
			currentbreaches += console
		if(!console.needs_processing())
			console.stop_ui_observation()
			active_consoles -= console
			continue
		collect_console_node_interest(console)
		var/priority = console.intrusion.breach || console.is_locked() ? NETRUN_TASK_CRITICAL : NETRUN_TASK_NORMAL
		scheduler.enqueue("console", console, priority)
	for(var/datum/netrun_ice/ice as anything in ice_processes)
		if(QDELETED(ice))
			continue
		if(ice.needs_netrun_tick())
			scheduler.enqueue("ice", ice, ice.pending_program ? NETRUN_TASK_CRITICAL : NETRUN_TASK_NORMAL)
	for(var/datum/netrun_request/delivery/request as anything in pending_requests)
		if(QDELETED(request))
			pending_requests -= request
		else
			collect_request_node_interest(request)
	for(var/datum/netrun_machine_packet/packet as anything in machine_transport?.interactive_packets)
		retain_route_interest(packet.interest_route, world.time + NETRUN_NODE_INTEREST_LEASE)
	populate_node_tasks()
	scheduler.enqueue("housekeeping", null, NETRUN_TASK_BACKGROUND)
	if(get_topology().dirty)
		scheduler.enqueue("apc_prebuild", get_topology(), NETRUN_TASK_BACKGROUND)

/datum/controller/subsystem/netrun/proc/execute_task(datum/netrun_task/task)
	return task.execute(src, get_execution_limits())

/// Timers admit ready I/O to the existing MC worker, never execute it themselves.
/datum/controller/subsystem/netrun/proc/wake_ready_delivery()
	wait = world.tick_lag
	next_fire = min(next_fire, world.time + world.tick_lag)

/datum/controller/subsystem/netrun/proc/refresh_delivery_interval()
	wait = task_scheduler?.pending() ? world.tick_lag : NETRUN_DEFAULT_FIRE_INTERVAL

/datum/controller/subsystem/netrun/fire(resumed = FALSE)
	var/slice_start_usage = TICK_USAGE
	if(!resumed && initialized)
		get_machine_transport().prepare_network()
	if(!resumed)
		current_pass_cost_ms = 0
	var/datum/netrun_execution_limits/limits = get_execution_limits(TRUE)
	var/datum/netrun_task_scheduler/scheduler = get_task_scheduler()
	scheduler.configure(limits)
	if(!resumed && world.time >= next_task_population)
		last_processed_nodes = 0
		last_processed_consoles = 0
		if(SSticker.current_state < GAME_STATE_PLAYING)
			// Lobby preparation must not start patrols or autonomous game processes.
			populate_node_tasks()
		else
			populate_tasks()
		next_task_population = world.time + limits.population_interval
	var/budget_ms = limits.budget_for(TICK_USAGE)
	// A previous expensive UI/topology task must not ration a following burst of
	// cheap machine deliveries. Actual elapsed CPU and MC_TICK_CHECK bound the
	// work; the item ceiling remains a separate hard stop for near-zero-cost tasks.
	var/max_items = limits.max_per_pass
	var/executed = 0
	while(executed < max_items)
		if(executed && max(0, TICK_DELTA_TO_MS(TICK_USAGE - slice_start_usage)) >= budget_ms)
			break
		var/datum/netrun_task/task = scheduler.take()
		if(!task)
			break
		var/task_started = TICK_USAGE
		var/task_started_at = world.time
		var/datum/target = task.target()
		execute_task(task)
		var/cost_ms = max(0, TICK_DELTA_TO_MS(TICK_USAGE - task_started))
		scheduler.note_execution(task, cost_ms, task_started_at)
		if(cost_ms > budget_ms)
			scheduler.task_overruns++
		if(profile_armed)
			profile_note("netrun/task/[task.kind]", cost_ms, QDELETED(target) ? null : target)
		qdel(task)
		executed++
		if(MC_TICK_CHECK)
			refresh_delivery_interval()
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
	refresh_delivery_interval()
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
	RETURN_TYPE(/datum/netrun_topology)
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
	var/turf/here = apc_node.physical_turf()
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
/datum/controller/subsystem/netrun/proc/post_event(kind, from_ref, to_ref, list/route)
	events += list(list("kind" = kind, "from" = from_ref, "to" = to_ref, "t" = world.time, "route" = route?.Copy()))
	if(length(events) > 40)
		events.Cut(1, length(events) - 40 + 1)
	SEND_SIGNAL(src, COMSIG_NETRUN_EVENT_POSTED, kind, from_ref, to_ref)

/// Недавние события (последние секунды) для интерфейса
/datum/controller/subsystem/netrun/proc/recent_events(datum/netrun_console/viewer)
	. = list()
	for(var/list/event as anything in events)
		var/age = world.time - event["t"]
		if(age > 4 SECONDS)
			continue
		var/list/path = event["route"]
		if(path && viewer)
			path = path.Copy()
			for(var/i in 1 to length(path))
				if(!viewer.map_view.shown_addresses[path[i]])
					path[i] = ""
		. += list(list("kind" = event["kind"], "from" = event["from"], "to" = event["to"], "age" = round(age / (1 SECONDS), 0.1), "route" = path))

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
	RETURN_TYPE(/datum/component/netrun_node)
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
