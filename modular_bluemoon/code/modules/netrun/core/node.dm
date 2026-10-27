/// Native organs live in nullspace while installed; their wearer is their physical endpoint.
/atom/proc/netrun_physical_host()
	return src

/obj/item/organ/netrun_physical_host()
	return owner || src

/atom/proc/netrun_turf()
	return get_turf(netrun_physical_host())

/// Сетевой узел: делает атом адресуемым в сети и даёт ему набор команд
/datum/component/netrun_node
	var/address
	var/node_type
	/// Базовая защита узла (1-5), к ней прибавляется защита ЛВС
	var/base_security = 1
	var/datum/netrun_network/network
	var/list/command_ids
	/// Если задан - легальный ПОЛЬЗОВАТЕЛЬ только с одним из этих доступов, иначе проверяется доступ самой машины
	var/list/required_access
	/// Хранилище файлов узла
	var/datum/netrun_file_store/file_store
	/// Recoverable process debris does not grant access to the machine's own files.
	var/list/datum/netrun_file/salvage = list()
	var/last_activity = -INFINITY
	/// Сущности, живущие в этом узле
	var/list/mob/camera/netrun_entity/entities
	/// Враждебные процессы (ICE), стоящие в этом узле
	var/list/datum/netrun_ice/netrun_ice
	/// Узел оглушён ЭМИ или командой и до этого времени не отвечает
	var/offline_until = 0
	/// До этого времени на узле поднят сетевой экран (усиленная защита)
	var/firewall_until = 0
	/// Ограниченный журнал самого узла, сохраняется при переходе между ЛВС.
	var/list/logs = list()
	/// Packet metadata has its own bounded journal; payloads and datum refs are never retained.
	var/list/packet_logs = list()
	/// One structural APC attachment, independent of power and temporary online state.
	var/datum/component/netrun_node/bound_apc
	var/area/binding_area
	var/binding_sector
	var/binding_checked = FALSE
	var/binding_infra_revision = -1
	/// Infrastructure geometry changes invalidate the shared graph even inside one area.
	var/turf/topology_turf
	/// APC only: turf its resolved LAN was cached for, so the department lookup runs once per move.
	var/turf/apc_network_turf
	/// Last reconciled status fields; compared as scalars to avoid per-tick list allocation.
	var/last_online
	var/last_security
	var/last_entities = -1
	var/last_ice = -1
	var/last_active
	var/last_dynamic
	var/pending_state_notification = FALSE
	/// Movement handlers only enqueue; routing consumers may reconcile before the worker.
	var/pending_physical_update = FALSE
	/// Cold display notifications are coalesced from the last completed processing, not input.
	var/last_processed_at = -INFINITY
	var/pending_changed_flags = 0
	var/urgent_update = FALSE
	var/processing_update = FALSE
	/// Owned subscription list, including every statically matching provider's signals.
	var/list/subscribed_state_signals
	/// Outermost movable carrier; physical containment never grants machine ownership.
	var/atom/movable/physical_carrier
	/// Every movable ancestor, nearest first. Nullspace organs start at their wearer.
	var/list/physical_carriers

/datum/component/netrun_node/Initialize(node_type, list/command_ids, security = 1, list/required_access, storage_capacity = 0)
	if(!isatom(parent))
		return COMPONENT_INCOMPATIBLE
	src.node_type = node_type
	src.command_ids = list("scan", "ping", "node_log", "packet_log", "packet_decrypt", "extract", "traceroute", "siphon", "spoof_log") | (command_ids || list())
	var/atom/host = parent
	base_security = clamp(max(security, host.netrun_security_floor()), 1, 5)
	src.required_access = required_access
	// Firmware documentation is available even on endpoints without writable storage.
	file_store = new(src, storage_capacity || 0)
	RegisterSignal(file_store, COMSIG_NETRUN_STORAGE_CHANGED, PROC_REF(on_storage_changed))
	address = SSnetrun.make_address()
	SSnetrun.nodes_by_address[address] = src
	topology_turf = physical_turf()
	// Publish registry event: topology listens and indexes APC/relay membership.
	SSnetrun.get_topology()
	SEND_SIGNAL(SSnetrun, COMSIG_NETRUN_NODE_REGISTERED, src)
	join_network()
	notify_changed(NETRUN_CHANGED_BINDING)

/datum/component/netrun_node/RegisterWithParent()
	RegisterSignal(parent, COMSIG_ATOM_EMP_ACT, PROC_REF(on_emp))
	subscribed_state_signals = list(COMSIG_ATOM_UPDATE_NAME, COMSIG_MACHINERY_POWER_LOST, COMSIG_MACHINERY_POWER_RESTORED, COMSIG_MACHINERY_BROKEN, COMSIG_MACHINERY_STAT_CHANGED, COMSIG_AIRLOCK_NETWORK_CHANGED, COMSIG_OBJ_SETANCHORED, COMSIG_NETRUN_SERVICE_STATE_CHANGED) | SSnetrun.get_provider_state_signals(parent)
	var/list/availability_signals = list(COMSIG_MACHINERY_POWER_LOST, COMSIG_MACHINERY_POWER_RESTORED, COMSIG_MACHINERY_BROKEN, COMSIG_MACHINERY_STAT_CHANGED, COMSIG_AIRLOCK_NETWORK_CHANGED)
	RegisterSignal(parent, availability_signals, PROC_REF(on_availability_changed))
	RegisterSignal(parent, subscribed_state_signals - availability_signals, PROC_REF(on_state_changed))
	if(ismovable(parent))
		RegisterSignal(parent, COMSIG_MOVABLE_MOVED, PROC_REF(on_moved))
		RegisterSignal(parent, COMSIG_MOVABLE_ENTERED_NULLSPACE, PROC_REF(on_entered_nullspace))
	refresh_physical_host()
	var/atom/host = parent
	host.ensure_netrun_machine_services(src)
	host.ensure_netrun_manual(src)

/datum/component/netrun_node/UnregisterFromParent()
	clear_physical_carrier()
	UnregisterSignal(parent, list(COMSIG_ATOM_EMP_ACT, COMSIG_MOVABLE_MOVED, COMSIG_MOVABLE_ENTERED_NULLSPACE))
	UnregisterSignal(parent, subscribed_state_signals)
	subscribed_state_signals = null

/datum/component/netrun_node/Destroy()
	clear_physical_carrier()
	var/atom/host = parent
	for(var/id in host.netrun_machine_services?.Copy())
		var/datum/netrun_machine_service/service = host.netrun_machine_services[id]
		if(service.node == src)
			qdel(service)
	SSnetrun.untrack_node(src)
	SSnetrun.nodes_by_address -= address
	SEND_SIGNAL(SSnetrun, COMSIG_NETRUN_NODE_UNREGISTERED, src)
	notify_changed(NETRUN_CHANGED_REMOVED)
	for(var/mob/camera/netrun_entity/entity as anything in entities?.Copy())
		entity.host_lost()
	entities = null
	for(var/datum/netrun_ice/ice as anything in netrun_ice?.Copy())
		ice.host_lost()
	netrun_ice = null
	leave_network()
	bound_apc = null
	binding_area = null
	topology_turf = null
	if(file_store)
		UnregisterSignal(file_store, COMSIG_NETRUN_STORAGE_CHANGED)
		QDEL_NULL(file_store)
	QDEL_LIST(salvage)
	return ..()

/datum/component/netrun_node/proc/join_network()
	var/datum/netrun_topology/topology = SSnetrun.get_topology()
	var/datum/component/netrun_node/previous_apc = bound_apc
	topology.refresh_node(src)
	pending_physical_update = FALSE
	var/datum/netrun_network/new_net
	if(node_type == NETRUN_NODE_APC)
		new_net = SSnetrun.get_apc_network(src)
	else if(bound_apc)
		// The APC already resolved its own LAN; reuse it instead of recomputing the lookup per endpoint.
		new_net = bound_apc.network || SSnetrun.get_apc_network(bound_apc)
	else
		new_net = netrun_fallback_network_for(physical_turf())
	if(network == new_net)
		if(previous_apc != bound_apc)
			notify_changed(NETRUN_CHANGED_BINDING)
		return
	// Publish the completed transition once; observers must not rebuild against
	// the old LAN or a temporary null network while this node is being rebound.
	leave_network(FALSE)
	if(new_net)
		network = new_net
		network.nodes += src
		add_log("Подключение к [network.code].")
	notify_changed(NETRUN_CHANGED_BINDING)

/datum/component/netrun_node/proc/leave_network(announce = TRUE)
	if(!network)
		return
	network.add_log("Узел [address] отключён.")
	network.nodes -= src
	network = null
	if(announce)
		notify_changed(NETRUN_CHANGED_BINDING)

/datum/component/netrun_node/proc/physical_turf()
	var/atom/host = parent
	return host?.netrun_turf()

/datum/component/netrun_node/proc/clear_physical_carrier()
	for(var/atom/movable/carrier as anything in physical_carriers)
		UnregisterSignal(carrier, list(COMSIG_MOVABLE_MOVED, COMSIG_MOVABLE_ENTERED_NULLSPACE, COMSIG_PARENT_QDELETING))
	physical_carriers = null
	physical_carrier = null

/// Watch ancestors rather than walking every carried item when its owner steps.
/// Rebind only when containment/native ownership changes, never on ordinary walking.
/datum/component/netrun_node/proc/rebind_physical_carriers()
	var/atom/host = parent
	var/atom/location = host?.netrun_physical_host()
	var/list/next_carriers = list()
	while(ismovable(location) && !QDELETED(location))
		if(location != parent)
			next_carriers += location
		location = location.loc
	for(var/atom/movable/carrier as anything in physical_carriers)
		if(!(carrier in next_carriers))
			UnregisterSignal(carrier, list(COMSIG_MOVABLE_MOVED, COMSIG_MOVABLE_ENTERED_NULLSPACE, COMSIG_PARENT_QDELETING))
	for(var/atom/movable/carrier as anything in next_carriers)
		if(!(carrier in physical_carriers))
			RegisterSignal(carrier, COMSIG_MOVABLE_MOVED, PROC_REF(on_moved))
			RegisterSignal(carrier, COMSIG_MOVABLE_ENTERED_NULLSPACE, PROC_REF(on_entered_nullspace))
			RegisterSignal(carrier, COMSIG_PARENT_QDELETING, PROC_REF(on_carrier_deleted))
	physical_carriers = length(next_carriers) ? next_carriers : null
	physical_carrier = length(next_carriers) ? next_carriers[length(next_carriers)] : null

/// Native ownership can change without loc changing (installed organs and MODs).
/datum/component/netrun_node/proc/refresh_physical_host()
	rebind_physical_carriers()
	queue_physical_update()

/datum/component/netrun_node/proc/on_moved(atom/movable/source, atom/old_loc)
	SIGNAL_HANDLER
	// A turf-to-turf step retains all watched objects. An intermediate bag being
	// handed to somebody else must replace the old outer subscriptions immediately.
	if(old_loc != source.loc && (!isturf(old_loc) || !isturf(source.loc)))
		rebind_physical_carriers()
	queue_physical_update()

/datum/component/netrun_node/proc/on_entered_nullspace()
	SIGNAL_HANDLER
	// Native moveToNullspace does not emit MOVED, including inventory descendants.
	rebind_physical_carriers()
	queue_physical_update()

/datum/component/netrun_node/proc/on_carrier_deleted(atom/movable/source)
	SIGNAL_HANDLER
	var/index = physical_carriers?.Find(source)
	if(!index)
		return
	// A deleting container still has its old loc. Keep only the live inner chain;
	// spilling its contents will rebind it through their normal movement events.
	for(var/slot in index to length(physical_carriers))
		var/atom/movable/carrier = physical_carriers[slot]
		UnregisterSignal(carrier, list(COMSIG_MOVABLE_MOVED, COMSIG_MOVABLE_ENTERED_NULLSPACE, COMSIG_PARENT_QDELETING))
	physical_carriers.Cut(index)
	physical_carrier = length(physical_carriers) ? physical_carriers[length(physical_carriers)] : null
	if(!length(physical_carriers))
		physical_carriers = null
	queue_physical_update()

/datum/component/netrun_node/proc/queue_physical_update()
	if(QDELETED(src))
		return
	SEND_SIGNAL(SSnetrun, COMSIG_NETRUN_NODE_MOVED, src, topology_turf, physical_turf())
	// Never scan bindings or repair every retained route inside the character's move.
	// The existing node task coalesces several moves, and explicit route consumers
	// call join_network() themselves before authorizing a packet or serializing UI.
	pending_physical_update = TRUE
	pending_changed_flags |= NETRUN_CHANGED_STATE
	SSnetrun.queue_node(src, TRUE)

/datum/component/netrun_node/proc/on_state_changed(datum/source)
	SIGNAL_HANDLER
	pending_state_notification = TRUE
	// Native forwarding state (for example APC failure_timer) can use provider
	// icon/UI signals instead of machine_stat. Leaves cannot change other routes.
	var/datum/netrun_topology/graph = SSnetrun.get_topology()
	if(graph.is_infrastructure(src) || length(graph.adjacency[address]) > 1)
		SSnetrun.queue_availability(src)
	SSnetrun.queue_node(src)

/datum/component/netrun_node/proc/on_availability_changed(datum/source)
	SIGNAL_HANDLER
	pending_state_notification = TRUE
	SSnetrun.queue_availability(src)
	SSnetrun.queue_node(src, TRUE)

/datum/component/netrun_node/proc/on_storage_changed(datum/source)
	SIGNAL_HANDLER
	notify_changed()

/// The fallback samples only fields exposed by the graph, including timed states.
/// Polls the timed/native status that has no change signal (power, firewall expiry, occupants,
/// activity window). Name changes arrive via COMSIG_ATOM_UPDATE_NAME, so no string is built here.
/// Scalar comparison avoids allocating and deep-comparing a fresh list for every node each tick.
/datum/component/netrun_node/proc/reconcile_state()
	var/online = is_online()
	var/security = get_security()
	var/entity_count = length(entities)
	var/ice_count = length(netrun_ice)
	var/datum/netrun_execution_limits/limits = SSnetrun.get_execution_limits()
	var/active = world.time - last_activity < limits.node_activity_duration
	var/dynamic = is_dynamic()
	if(!pending_state_notification && online == last_online && security == last_security && entity_count == last_entities && ice_count == last_ice && active == last_active && dynamic == last_dynamic)
		return
	if(online != last_online)
		SSnetrun.get_topology().availability_changed(src)
	pending_state_notification = FALSE
	last_online = online
	last_security = security
	last_entities = entity_count
	last_ice = ice_count
	last_active = active
	last_dynamic = dynamic
	notify_changed(NETRUN_CHANGED_STATE)

/datum/component/netrun_node/proc/notify_changed(flags = NETRUN_CHANGED_STATE)
	if(!QDELETED(src) && !(flags & NETRUN_CHANGED_REMOVED))
		SSnetrun.track_node(src)
	// Availability is a separate routing generation: occupant/activity changes do not
	// rebuild shortest paths, while power/EMP changes invalidate retained display paths.
	var/online = is_online()
	var/availability_changed = online != last_online
	if(online != last_online)
		last_online = online
		SSnetrun.get_topology().availability_changed(src)
	SEND_SIGNAL(src, COMSIG_NETRUN_NODE_CHANGED, src, flags)
	pending_changed_flags |= flags
	if(processing_update)
		return
	if((flags & (NETRUN_CHANGED_BINDING | NETRUN_CHANGED_REMOVED)) || urgent_update || availability_changed || SSnetrun.node_interest_until[src] > world.time)
		publish_changes()
	else
		SSnetrun.queue_node(src)

/// Only the global presentation stream is batched; gameplay fields and local signals are live.
/datum/component/netrun_node/proc/publish_changes()
	var/flags = pending_changed_flags
	if(!flags)
		return
	pending_changed_flags = 0
	SEND_SIGNAL(SSnetrun, COMSIG_NETRUN_NODE_CHANGED, src, flags)

/datum/component/netrun_node/proc/on_emp(datum/source, severity)
	SIGNAL_HANDLER
	offline_until = max(offline_until, world.time + (severity >= 50 ? 60 SECONDS : 30 SECONDS))
	for(var/mob/camera/netrun_entity/entity as anything in entities)
		entity.take_integrity(severity >= 50 ? 40 : 20, "электромагнитный импульс")
	notify_changed()

/datum/component/netrun_node/proc/get_security()
	var/firewall = world.time < firewall_until ? 2 : 0
	return clamp(base_security + (network ? network.security - 1 : 0) + firewall, 1, 5)

/// Поднять сетевой экран: сбросить взломанные доступы к узлу и прервать взлом цели.
/datum/component/netrun_node/proc/raise_firewall(duration = 20 SECONDS)
	firewall_until = world.time + duration
	add_log("Поднят сетевой экран.")
	network?.add_log("Узел [address]: активирован сетевой экран.")
	SEND_SIGNAL(SSnetrun, COMSIG_NETRUN_FIREWALL_CHANGED, src)
	notify_changed()
	SSnetrun.post_event("trace", null, address)

/// Отвечает ли узел на удалённые запросы
/datum/component/netrun_node/proc/is_online(remote = TRUE)
	// Parent teardown may already have removed wires, organs or other native resources.
	if(QDELETED(src) || QDELETED(parent))
		return FALSE
	if(world.time < offline_until)
		return FALSE
	var/atom/A = parent
	return A.netrun_online(remote)

/datum/component/netrun_node/proc/get_name()
	var/atom/A = parent
	return A.netrun_name()

/datum/component/netrun_node/proc/touch()
	last_activity = world.time
	notify_changed()

/datum/component/netrun_node/proc/add_log(text)
	logs += "[STATION_TIME_TIMESTAMP("hh:mm:ss", world.time)] [text]"
	if(length(logs) > NETRUN_MAX_LOG)
		logs.Cut(1, length(logs) - NETRUN_MAX_LOG + 1)
	notify_changed()

/datum/component/netrun_node/proc/add_packet_log(packet_id, phase, kind, from_address, to_address, service_id, reason, operation_id, list/route, list/headers)
	packet_logs += list(list("id" = packet_id, "time" = world.time, "phase" = phase, "kind" = kind,
		"from" = from_address, "to" = to_address, "service" = service_id, "reason" = reason,
		"operation_id" = operation_id || packet_id, "route" = route, "headers" = headers))
	if(length(packet_logs) > NETRUN_MAX_PACKET_LOG)
		packet_logs.Cut(1, length(packet_logs) - NETRUN_MAX_PACKET_LOG + 1)
	// Logging does not broadcast per packet or keep unrelated nodes in the hot lane.
	pending_changed_flags |= NETRUN_CHANGED_STATE
	SSnetrun.queue_node(src)

/datum/component/netrun_node/proc/packet_log_text()
	var/list/lines = list()
	for(var/list/entry as anything in packet_logs)
		lines += "[round(entry["time"] / (1 SECONDS), 0.1)]s #[entry["id"]] [entry["phase"]] [entry["kind"]] [entry["from"]] -> [entry["to"]] ([entry["service"]])[entry["reason"] ? ": [entry["reason"]]" : ""]"
		if(entry["headers"])
			lines += "  [json_encode(entry["headers"])]"
	return length(lines) ? jointext(lines, "\n") : "Журнал пакетов пуст."

/datum/component/netrun_node/proc/packet_headers_payload()
	var/list/output = list()
	for(var/i = length(packet_logs); i >= max(1, length(packet_logs) - 19); i--)
		var/list/entry = packet_logs[i]
		var/list/header = entry.Copy()
		// Long routes belong to delivery/operation diagnostics; do not repeat the
		// full station path twenty times on every selected-node movement update.
		header -= "route"
		output += list(header)
	return output

/datum/component/netrun_node/proc/decode_packet(packet_id)
	for(var/list/entry as anything in packet_logs)
		if(entry["id"] == packet_id)
			var/body = SSnetrun.packet_captures[packet_id]
			return body ? "Пакет [packet_id]\n[json_encode(entry["headers"])]\n[body]" : "Содержимое пакета уже вытеснено из буфера захвата."
	return "Пакет отсутствует в журнале этого узла."

/// Все команды узла: базовые плюс зависящие от компонентов атома
/datum/component/netrun_node/proc/all_command_ids()
	var/atom/A = parent
	. = command_ids.Copy()
	. |= A.netrun_extra_commands()
	var/datum/netrun_provider/api = SSnetrun.get_provider(A)
	if(api?.allow_emag)
		. |= "firmware"

/// Одинаковый набор действий для карточки, вкладки и других клиентов.
/datum/component/netrun_node/proc/command_entries(datum/netrun_console/console)
	if(console.ui_commands && islist(console.ui_commands[address]))
		return console.ui_commands[address]
	. = list()
	for(var/command_id in all_command_ids())
		var/datum/netrun_command/command = SSnetrun.get_command(command_id)
		if(command)
			. += list(command.ui_entry(src, console, command_id))
	if(console.ui_commands)
		console.ui_commands[address] = .

/datum/component/netrun_node/proc/used_storage()
	return file_store?.used() || 0

/// Anchored machines on a turf belong to the cached canvas; carried endpoints and mobs
/// retain live positions and links in the reactive layer. Machines are movable atoms too.
/datum/component/netrun_node/proc/is_dynamic()
	if(ismob(parent))
		return TRUE
	if(!ismovable(parent))
		return FALSE
	var/atom/movable/endpoint = parent
	return !endpoint.anchored || !isturf(endpoint.loc)

/// Every endpoint, including a real relay, has at most one cached APC attachment.
/datum/component/netrun_node/proc/uplink_node()
	if(node_type == NETRUN_NODE_APC)
		return null
	join_network()
	return bound_apc

/datum/component/netrun_node/proc/ui_entry(datum/netrun_console/console)
	var/datum/netrun_execution_limits/limits = SSnetrun.get_execution_limits()
	var/turf/T = physical_turf()
	var/datum/component/netrun_node/uplink = uplink_node()
	. = list(
		"address" = address,
		"name" = get_name(),
		"type" = istype(parent, /obj/machinery/ntnet_relay) ? "relay" : node_type,
		"dynamic" = is_dynamic(),
		"x" = T ? T.x : 0,
		"y" = T ? T.y : 0,
		"z" = T ? T.z : 0,
		"security" = get_security(),
		"online" = is_online(),
		"access" = console.node_level(src),
		"entities" = length(entities),
		"ice" = LAZYLEN(netrun_ice),
		"active" = world.time - last_activity < limits.node_activity_duration,
		"uplink" = uplink?.address,
		"apc" = bound_apc?.address,
	)
	if(console.origin == NETRUN_ORIGIN_ENTITY && istype(console.host, /mob/camera/netrun_entity))
		var/mob/camera/netrun_entity/entity = console.host
		.["can_hop"] = entity.can_enter(src, console.ui_routes)

/// Найти узел на атоме или внутри него (для подключения деки и сканеров)
/proc/netrun_find_node(atom/A)
	if(!A)
		return
	var/datum/component/netrun_node/node = A.GetComponent(/datum/component/netrun_node)
	if(node)
		return node
	for(var/atom/inner in A.contents)
		node = inner.GetComponent(/datum/component/netrun_node)
		if(node)
			return node

// Хуки, которые машины переопределяют под себя

/// Имя узла в интерфейсе сети (консоли показывают имя корпуса, а не внутренней платы)
/atom/proc/netrun_name()
	return name

/// Доп. команды узла, зависящие от компонентов атома (например, привязка техвеба)
/atom/proc/netrun_extra_commands()
	return list()

/// Отвечает ли атом на сетевые запросы. remote = запрос пришёл не по проводу
/atom/proc/netrun_online(remote = TRUE)
	return TRUE

/obj/machinery/netrun_online(remote = TRUE)
	return !(machine_stat & (BROKEN | NOPOWER | EMPED))

/// Строки состояния для панели узла
/atom/proc/netrun_status()
	return list()

/// Событие в журнале консоли - носитель может продублировать его (например, в нейроинтерфейс)
/atom/proc/netrun_console_event(datum/netrun_console/console, text, kind)
	return

/// Ответный удар по носителю консоли при полной трассировке
/atom/proc/netrun_traced(datum/netrun_console/console)
	return

/// Нелегальное сетевое действие над этим атомом (носитель узла может отреагировать)
/atom/proc/netrun_on_illegal(datum/netrun_console/console, datum/component/netrun_node/node)
	return

/// Объект может навязать конкретную мини-игру взлома ("matrix" / "sequence"); null - по умолчанию.
/atom/proc/netrun_breach_minigame()
	return null

/// Native custom states without notifications retain a one-second fallback. Generic
/// machinery is driven by stat signals; its transient netrun timers are tracked separately.
/atom/proc/netrun_needs_poll()
	return TRUE

/obj/machinery/netrun_needs_poll()
	return FALSE

/obj/machinery/power/apc/netrun_needs_poll()
	return TRUE

/obj/machinery/ntnet_relay/netrun_needs_poll()
	return TRUE

/obj/machinery/rnd/server/netrun_needs_poll()
	return TRUE

/obj/machinery/telecomms/netrun_needs_poll()
	return TRUE
