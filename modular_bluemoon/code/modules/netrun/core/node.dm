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
	var/list/datum/netrun_file/files
	var/storage_capacity = 0
	var/last_activity = -INFINITY
	/// Сущности, живущие в этом узле
	var/list/mob/camera/netrun_entity/entities
	/// Узел оглушён ЭМИ или командой и до этого времени не отвечает
	var/offline_until = 0

/datum/component/netrun_node/Initialize(node_type, list/command_ids, security = 1, list/required_access, storage_capacity = 0)
	if(!isatom(parent))
		return COMPONENT_INCOMPATIBLE
	src.node_type = node_type
	src.command_ids = list("scan") + (command_ids || list())
	base_security = security
	src.required_access = required_access
	src.storage_capacity = storage_capacity
	if(storage_capacity)
		files = list()
	address = SSnetrun.make_address()
	SSnetrun.nodes_by_address[address] = src
	join_network()

/datum/component/netrun_node/RegisterWithParent()
	RegisterSignal(parent, COMSIG_ATOM_EMP_ACT, PROC_REF(on_emp))
	if(ismovable(parent))
		RegisterSignal(parent, COMSIG_MOVABLE_MOVED, PROC_REF(on_moved))

/datum/component/netrun_node/UnregisterFromParent()
	UnregisterSignal(parent, list(COMSIG_ATOM_EMP_ACT, COMSIG_MOVABLE_MOVED))

/datum/component/netrun_node/Destroy()
	for(var/mob/camera/netrun_entity/entity as anything in entities)
		entity.host_lost()
	entities = null
	leave_network()
	SSnetrun.nodes_by_address -= address
	QDEL_LIST(files)
	return ..()

/datum/component/netrun_node/proc/join_network()
	var/lan = netrun_lan_for_turf(get_turf(parent))
	if(network?.id == lan)
		return
	leave_network()
	if(!lan)
		return
	network = SSnetrun.get_network(lan)
	network.nodes += src

/datum/component/netrun_node/proc/leave_network()
	if(!network)
		return
	network.nodes -= src
	network = null

/datum/component/netrun_node/proc/on_moved(datum/source)
	SIGNAL_HANDLER
	join_network()

/datum/component/netrun_node/proc/on_emp(datum/source, severity)
	SIGNAL_HANDLER
	offline_until = max(offline_until, world.time + (severity >= 50 ? 60 SECONDS : 30 SECONDS))
	for(var/mob/camera/netrun_entity/entity as anything in entities)
		entity.take_integrity(severity >= 50 ? 40 : 20, "электромагнитный импульс")

/datum/component/netrun_node/proc/get_security()
	return clamp(base_security + (network ? network.security - 1 : 0), 1, 5)

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

/datum/component/netrun_node/proc/used_storage()
	. = 0
	for(var/datum/netrun_file/file as anything in files)
		. += file.size

/// Узел-аплинк в подсети: APC отсека для обычных машин, иначе корень сети (null).
/// Глубина дерева - 2: корень ЛВС -> APC отсека -> машины за ним.
/datum/component/netrun_node/proc/uplink_node()
	if(node_type == NETRUN_NODE_APC || node_type == NETRUN_NODE_GATEWAY)
		return null
	var/turf/T = get_turf(parent)
	if(!T)
		return null
	var/area/A = get_area(parent)
	var/area/root_area = A?.base_area || A
	var/obj/machinery/power/apc/apc = root_area?.power_apc
	if(!apc || apc == parent)
		return null
	var/datum/component/netrun_node/apc_node = apc.GetComponent(/datum/component/netrun_node)
	if(apc_node && apc_node.network == network)
		return apc_node
	return null

/datum/component/netrun_node/proc/ui_entry(datum/netrun_console/console)
	var/turf/T = get_turf(parent)
	var/datum/component/netrun_node/uplink = uplink_node()
	return list(
		"address" = address,
		"name" = get_name(),
		"type" = node_type,
		"x" = T ? T.x : 0,
		"y" = T ? T.y : 0,
		"security" = get_security(),
		"online" = is_online(),
		"access" = console.node_level(src),
		"entities" = length(entities),
		"active" = world.time - last_activity < 5 SECONDS,
		"uplink" = uplink?.address,
	)

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
