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
	/// Owned subscription list, including every statically matching provider's signals.
	var/list/subscribed_state_signals

/datum/component/netrun_node/Initialize(node_type, list/command_ids, security = 1, list/required_access, storage_capacity = 0)
	if(!isatom(parent))
		return COMPONENT_INCOMPATIBLE
	src.node_type = node_type
	src.command_ids = list("scan", "ping", "node_log", "extract", "traceroute", "siphon", "spoof_log") | (command_ids || list())
	base_security = security
	src.required_access = required_access
	if(storage_capacity)
		file_store = new(src, storage_capacity)
	address = SSnetrun.make_address()
	SSnetrun.nodes_by_address[address] = src
	topology_turf = get_turf(parent)
	// Publish registry event: topology listens and indexes APC/relay membership.
	SSnetrun.get_topology()
	SEND_SIGNAL(SSnetrun, COMSIG_NETRUN_NODE_REGISTERED, src)
	join_network()
	notify_changed(NETRUN_CHANGED_BINDING)

/datum/component/netrun_node/RegisterWithParent()
	RegisterSignal(parent, COMSIG_ATOM_EMP_ACT, PROC_REF(on_emp))
	subscribed_state_signals = list(COMSIG_ATOM_UPDATE_NAME, COMSIG_MACHINERY_POWER_LOST, COMSIG_MACHINERY_POWER_RESTORED, COMSIG_MACHINERY_BROKEN, COMSIG_MACHINERY_STAT_CHANGED, COMSIG_AIRLOCK_NETWORK_CHANGED, COMSIG_OBJ_SETANCHORED) | SSnetrun.get_provider_state_signals(parent)
	RegisterSignal(parent, subscribed_state_signals, PROC_REF(on_state_changed))
	if(ismovable(parent))
		RegisterSignal(parent, COMSIG_MOVABLE_MOVED, PROC_REF(on_moved))

/datum/component/netrun_node/UnregisterFromParent()
	UnregisterSignal(parent, list(COMSIG_ATOM_EMP_ACT, COMSIG_MOVABLE_MOVED))
	UnregisterSignal(parent, subscribed_state_signals)
	subscribed_state_signals = null

/datum/component/netrun_node/Destroy()
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
	QDEL_NULL(file_store)
	QDEL_LIST(salvage)
	return ..()

/datum/component/netrun_node/proc/join_network()
	var/datum/netrun_topology/topology = SSnetrun.get_topology()
	topology.refresh_node(src)
	var/datum/netrun_network/new_net
	if(node_type == NETRUN_NODE_APC)
		new_net = SSnetrun.get_apc_network(src)
	else if(bound_apc)
		// The APC already resolved its own LAN; reuse it instead of recomputing the lookup per endpoint.
		new_net = bound_apc.network || SSnetrun.get_apc_network(bound_apc)
	else
		new_net = netrun_fallback_network_for(get_turf(parent))
	if(network == new_net)
		return
	leave_network()
	if(!new_net)
		return
	network = new_net
	network.nodes += src
	add_log("Подключение к [network.code].")
	notify_changed(NETRUN_CHANGED_BINDING)

/datum/component/netrun_node/proc/leave_network()
	if(!network)
		return
	network.add_log("Узел [address] отключён.")
	network.nodes -= src
	network = null
	notify_changed(NETRUN_CHANGED_BINDING)

/datum/component/netrun_node/proc/on_moved(datum/source)
	SIGNAL_HANDLER
	SEND_SIGNAL(SSnetrun, COMSIG_NETRUN_NODE_MOVED, src, topology_turf, get_turf(parent))
	join_network()
	// refresh_node emits BINDING only when the actual APC attachment changes.
	notify_changed(NETRUN_CHANGED_STATE)

/datum/component/netrun_node/proc/on_state_changed(datum/source)
	SIGNAL_HANDLER
	pending_state_notification = TRUE
	SSnetrun.queue_node(src)

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
	if(online != last_online)
		last_online = online
		SSnetrun.get_topology().availability_changed(src)
	SEND_SIGNAL(src, COMSIG_NETRUN_NODE_CHANGED, src, flags)
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
	var/turf/T = get_turf(parent)
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
