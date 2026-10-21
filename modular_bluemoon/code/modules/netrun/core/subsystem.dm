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
	/// Общая лента недавних событий сети - её видят все раннеры на карте.
	/// list(list("kind","from","to","t"))
	var/list/events = list()
	var/datum/netrun_topology/topology

/datum/controller/subsystem/netrun/stat_entry(msg)
	msg = "N:[length(nodes_by_address)] C:[length(consoles)] E:[length(entities)]"
	return ..()

/datum/controller/subsystem/netrun/fire(resumed = FALSE)
	if(!resumed)
		currentrun = consoles.Copy()
		currentnodes = nodes_by_address.Copy()
		currentice = ice_processes.Copy()
	// Вложенный предмет не получает MOVED при перемещении носителя. Сверяем топологию
	// независимо от открытых интерфейсов, не создавая сигнал на каждом контейнере.
	while(length(currentnodes))
		var/address = currentnodes[length(currentnodes)]
		var/datum/component/netrun_node/node = currentnodes[address]
		currentnodes.len--
		if(!QDELETED(node))
			node.join_network()
			node.reconcile_state()
		if(MC_TICK_CHECK)
			return
	// Publish new endpoints and carrier movement even when nobody opens a map.
	// Active display routes are server-owned; execution still checks a fresh path.
	ensure_topology().refresh_route_tables()
	var/delta = wait / (1 SECONDS)
	while(length(currentice))
		var/datum/netrun_ice/ice = currentice[length(currentice)]
		currentice.len--
		if(!QDELETED(ice))
			ice.process_ai(delta)
		if(MC_TICK_CHECK)
			return
	while(length(currentrun))
		var/datum/netrun_console/console = currentrun[length(currentrun)]
		currentrun.len--
		if(!QDELETED(console))
			console.access_session.process_events()
			console.process_tick(delta)
			console.flush_ui()
		if(MC_TICK_CHECK)
			return

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
		result.rebuild()
	return result

/// Keys belong to a particular APC, even when multiple APCs serve the same native area.
/datum/controller/subsystem/netrun/proc/get_apc_network(datum/component/netrun_node/apc_node)
	if(QDELETED(apc_node) || apc_node.node_type != NETRUN_NODE_APC)
		return null
	var/id = "apc_[apc_node.address]"
	var/datum/netrun_network/network = networks[id]
	if(!network)
		var/area/source_area
		if(istype(apc_node.parent, /obj/machinery/power/apc))
			var/obj/machinery/power/apc/apc = apc_node.parent
			source_area = apc.area
		if(!source_area)
			source_area = get_area(apc_node.parent)
		source_area = source_area?.base_area || source_area
		network = new(id, source_area)
		networks[id] = network
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
