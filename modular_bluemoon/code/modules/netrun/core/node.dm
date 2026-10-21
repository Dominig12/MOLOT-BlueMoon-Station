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
	/// Co-located intermediary node (same turf machine) this endpoint chains through,
	/// so stacked nodes form APC-Camera-Neuro instead of a star to the APC. Rebuild-owned.
	var/datum/component/netrun_node/bound_host
	var/area/binding_area
	var/binding_sector
	var/binding_checked = FALSE
	var/binding_infra_revision = -1
	/// Infrastructure geometry changes invalidate the shared graph even inside one area.
	var/turf/topology_turf
	var/list/last_state

/datum/component/netrun_node/Initialize(node_type, list/command_ids, security = 1, list/required_access, storage_capacity = 0)
	if(!isatom(parent))
		return COMPONENT_INCOMPATIBLE
	src.node_type = node_type
	src.command_ids = list("scan", "ping", "node_log", "extract") | (command_ids || list())
	base_security = security
	src.required_access = required_access
	if(storage_capacity)
		file_store = new(src, storage_capacity)
	address = SSnetrun.make_address()
	SSnetrun.nodes_by_address[address] = src
	topology_turf = get_turf(parent)
	var/datum/netrun_topology/topology = SSnetrun.get_topology()
	if(topology.is_infrastructure(src))
		topology.infrastructure_changed()
	else
		topology.invalidate()
	join_network()
	notify_changed(NETRUN_CHANGED_BINDING)

/datum/component/netrun_node/RegisterWithParent()
	RegisterSignal(parent, COMSIG_ATOM_EMP_ACT, PROC_REF(on_emp))
	RegisterSignal(parent, list(COMSIG_ATOM_UPDATE_NAME, COMSIG_MACHINERY_POWER_LOST, COMSIG_MACHINERY_POWER_RESTORED, COMSIG_MACHINERY_BROKEN), PROC_REF(on_state_changed))
	if(ismovable(parent))
		RegisterSignal(parent, COMSIG_MOVABLE_MOVED, PROC_REF(on_moved))

/datum/component/netrun_node/UnregisterFromParent()
	UnregisterSignal(parent, list(COMSIG_ATOM_EMP_ACT, COMSIG_MOVABLE_MOVED))
	UnregisterSignal(parent, list(COMSIG_ATOM_UPDATE_NAME, COMSIG_MACHINERY_POWER_LOST, COMSIG_MACHINERY_POWER_RESTORED, COMSIG_MACHINERY_BROKEN))

/datum/component/netrun_node/Destroy()
	var/datum/netrun_topology/topology = SSnetrun.get_topology()
	SSnetrun.nodes_by_address -= address
	notify_changed(NETRUN_CHANGED_REMOVED)
	topology.forget_node(src)
	for(var/mob/camera/netrun_entity/entity as anything in entities)
		entity.host_lost()
	entities = null
	for(var/datum/netrun_ice/ice as anything in netrun_ice)
		ice.host_lost()
	netrun_ice = null
	leave_network()
	bound_apc = null
	bound_host = null
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
		new_net = SSnetrun.get_apc_network(bound_apc)
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
	join_network()
	notify_changed(NETRUN_CHANGED_BINDING)

/datum/component/netrun_node/proc/on_state_changed(datum/source)
	SIGNAL_HANDLER
	notify_changed(NETRUN_CHANGED_STATE)

/// The fallback samples only fields exposed by the graph, including timed states.
/datum/component/netrun_node/proc/reconcile_state()
	var/list/state = list(get_name(), is_online(), get_security(), length(entities), length(netrun_ice), world.time - last_activity < 5 SECONDS)
	if(netrun_snapshot_equal(last_state, state))
		return
	last_state = state
	notify_changed(NETRUN_CHANGED_STATE)

/datum/component/netrun_node/proc/notify_changed(flags = NETRUN_CHANGED_STATE)
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
	var/datum/netrun_api/api = SSnetrun.get_api(A)
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

/// Every endpoint, including a real relay, has at most one cached APC attachment.
/datum/component/netrun_node/proc/uplink_node()
	if(node_type == NETRUN_NODE_APC)
		return null
	join_network()
	// Если узел стоит в одной клетке с машиной-посредником, цепляемся к ней (APC-Камера-Нейроинтерфейс).
	if(!QDELETED(bound_host) && SSnetrun.nodes_by_address[bound_host.address] == bound_host)
		return bound_host
	return bound_apc

/datum/component/netrun_node/proc/ui_entry(datum/netrun_console/console)
	var/turf/T = get_turf(parent)
	var/datum/component/netrun_node/uplink = uplink_node()
	. = list(
		"address" = address,
		"name" = get_name(),
		"type" = node_type,
		"x" = T ? T.x : 0,
		"y" = T ? T.y : 0,
		"z" = T ? T.z : 0,
		"security" = get_security(),
		"online" = is_online(),
		"access" = console.node_level(src),
		"entities" = length(entities),
		"ice" = LAZYLEN(netrun_ice),
		"active" = world.time - last_activity < 5 SECONDS,
		"uplink" = uplink?.address,
	)
	if(console.origin == NETRUN_ORIGIN_ENTITY && istype(console.host, /mob/camera/netrun_entity))
		var/mob/camera/netrun_entity/entity = console.host
		.["can_hop"] = entity.can_enter(src)

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
