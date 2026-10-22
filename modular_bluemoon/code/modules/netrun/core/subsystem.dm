SUBSYSTEM_DEF(netrun)
	name = "Netrun"
	wait = 1 SECONDS
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
	var/list/currentrun = list()
	var/list/currentnodes = list()
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
	msg = "N:[length(nodes_by_address)] P:[length(poll_nodes)] Q:[length(dirty_nodes)] C:[length(active_consoles)]/[length(consoles)] E:[length(entities)] Last N:[last_processed_nodes] C:[last_processed_consoles] T:[topology_rebuilds] F:[camera_feed_scans]/[camera_feed_cache_hits] R:[camera_route_borrows] W:[wire_session_sweeps]"
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
	currentnodes -= node

/datum/controller/subsystem/netrun/fire(resumed = FALSE)
	var/slice_start_usage = TICK_USAGE
	if(!resumed)
		current_pass_cost_ms = 0
		last_processed_nodes = 0
		last_processed_consoles = 0
		currentrun = active_consoles.Copy()
		currentice = ice_processes.Copy()
		currentbreaches = list()
		reconcile_nodes = length(entities) || !patrol_initialized || !lore_initialized
		for(var/datum/netrun_console/console as anything in currentrun)
			if(QDELETED(console))
				continue
			if(console.intrusion.breach)
				currentbreaches += console
			if(console.needs_processing())
				reconcile_nodes = TRUE
		currentnodes = dirty_nodes.Copy()
		if(reconcile_nodes)
			currentnodes |= poll_nodes
		for(var/datum/component/netrun_node/node as anything in timed_nodes)
			if(timed_nodes[node] <= world.time)
				currentnodes[node] = TRUE
		pass_item_count = length(currentrun) + length(currentice) + length(currentnodes)
	var/delta = wait / (1 SECONDS)
	var/profiling = profile_armed
	// ICE snapshots remain resumable across MC slices, without rescanning all terminals.
	while(length(currentice))
		var/datum/netrun_ice/ice = currentice[length(currentice)]
		currentice.len--
		var/item_start_usage = profiling ? TICK_USAGE : 0
		if(!QDELETED(ice))
			breach_snapshot_active = TRUE
			ice.process_ai(delta)
			breach_snapshot_active = FALSE
			if(profiling)
				profile_note(ice.type, max(0, TICK_DELTA_TO_MS(TICK_USAGE - item_start_usage)), ice)
		if(MC_TICK_CHECK)
			current_pass_cost_ms += max(0, TICK_DELTA_TO_MS(TICK_USAGE - slice_start_usage))
			return
	currentbreaches.Cut()
	while(length(currentrun))
		var/datum/netrun_console/console = currentrun[length(currentrun)]
		currentrun.len--
		var/item_start_usage = profiling ? TICK_USAGE : 0
		if(!QDELETED(console))
			console.access_session.process_events()
			console.process_tick(delta)
			console.flush_ui()
			last_processed_consoles++
			if(!console.needs_processing())
				active_consoles -= console
			if(profiling)
				profile_note(console.type, max(0, TICK_DELTA_TO_MS(TICK_USAGE - item_start_usage)), console)
		if(MC_TICK_CHECK)
			current_pass_cost_ms += max(0, TICK_DELTA_TO_MS(TICK_USAGE - slice_start_usage))
			return
	var/datum/netrun_topology/graph = get_topology()
	while(length(currentnodes))
		var/datum/component/netrun_node/node = currentnodes[length(currentnodes)]
		currentnodes.len--
		dirty_nodes -= node
		var/item_start_usage = profiling ? TICK_USAGE : 0
		if(!QDELETED(node))
			if(node.is_dynamic() || !node.binding_checked || node.binding_infra_revision != graph.infrastructure_revision)
				node.join_network()
			node.reconcile_state()
			track_node(node)
			last_processed_nodes++
			if(profiling)
				profile_note(node.parent.type, max(0, TICK_DELTA_TO_MS(TICK_USAGE - item_start_usage)), node.parent)
		if(MC_TICK_CHECK)
			current_pass_cost_ms += max(0, TICK_DELTA_TO_MS(TICK_USAGE - slice_start_usage))
			return
	if(reconcile_nodes)
		graph = ensure_topology()
	graph.refresh_route_tables()
	if(!patrol_initialized && length(networks))
		initialize_patrol()
	if(!lore_initialized && length(nodes_by_address))
		initialize_lore()
	current_pass_cost_ms += max(0, TICK_DELTA_TO_MS(TICK_USAGE - slice_start_usage))
	on_pass_finished(pass_item_count)

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
