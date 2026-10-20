/// Локальная сеть. Узлы попадают в неё по зоне, в которой стоят.
/datum/netrun_network
	var/id
	var/name = "Локальная сеть"
	var/short_name = "ЛВС"
	/// Защита шлюза ЛВС (1-5), прибавляется к защите узлов
	var/security = 1
	/// Нет маршрута через NTnet - попасть можно только физически
	var/isolated = FALSE
	/// Любой из этих доступов даёт легальный гостевой вход в ЛВС
	var/list/guest_access
	var/list/datum/component/netrun_node/nodes = list()
	var/list/logs = list()
	/// Ключ ЛВС: файл с ним даёт легальный доступ ПОЛЬЗОВАТЕЛЯ ко всей сети
	var/passcode
	/// Цвет сети на карте терминала
	var/color = "#4a9eff"
	/// Короткий код сети для подключения (показывается в интерфейсе как адрес сети)
	var/code
	/// Зона-носитель ЛВС (для APC-сетей). Общая и внешние сегменты - без зоны.
	var/area/area

/datum/netrun_network/New(new_id, area/source_area)
	id = new_id
	area = source_area
	passcode = "[uppertext(copytext(md5("[new_id][world.time][rand(1, 999999)]"), 1, 17))]"
	code = "NET-[uppertext(copytext(md5("[new_id][passcode]"), 1, 6))]"
	if(new_id == NETRUN_LAN_PUBLIC)
		name = "Общая сеть станции"
		short_name = "ОБЩ"
		security = 1
		guest_access = list()
		color = "#8b93a3"
	else if(copytext(new_id, 1, 4) == "ext")
		name = "Внешний сегмент"
		short_name = "ВНШ"
		security = 2
		isolated = TRUE
		guest_access = list()
		color = "#d05090"
	else if(source_area)
		apply_area_profile(source_area)
	else
		name = "Локальная сеть [new_id]"
		short_name = "ЛВС"
	add_log("Сеть инициализирована.")

/// Свойства ЛВС выводятся из типа отсека, в котором стоит её APC.
/datum/netrun_network/proc/apply_area_profile(area/A)
	name = "ЛВС: [A.name]"
	short_name = copytext_char(A.name, 1, 10)
	if(istype(A, /area/security))
		security = 3
		guest_access = list(ACCESS_SECURITY)
		color = "#ff5050"
	else if(istype(A, /area/command) || istype(A, /area/ai_monitored))
		security = 4
		guest_access = list(ACCESS_HEADS)
		color = "#3cdc8c"
	else if(istype(A, /area/engineering))
		security = 2
		guest_access = list(ACCESS_ENGINE, ACCESS_ENGINE_EQUIP)
		color = "#f0a030"
	else if(istype(A, /area/medical))
		security = 2
		guest_access = list(ACCESS_MEDICAL)
		color = "#5bc0de"
	else if(istype(A, /area/science))
		security = 2
		guest_access = list(ACCESS_RESEARCH, ACCESS_TOX, ACCESS_ROBOTICS)
		color = "#b07cff"
	else if(istype(A, /area/cargo))
		security = 1
		guest_access = list(ACCESS_CARGO)
		color = "#c9a227"
	else
		security = 1
		guest_access = list()
		color = "#8b93a3"

/datum/netrun_network/Destroy()
	nodes.Cut()
	SSnetrun.networks -= id
	return ..()

/datum/netrun_network/proc/add_log(text, important = FALSE)
	logs += "[STATION_TIME_TIMESTAMP("hh:mm:ss", world.time)] [text]"
	if(length(logs) > NETRUN_MAX_LOG)
		logs.Cut(1, length(logs) - NETRUN_MAX_LOG + 1)
	if(important)
		SSnetrun.ntnet_log("[short_name]: [text]", important)

/// Легальный гостевой доступ в ЛВС по списку доступов
/datum/netrun_network/proc/legit_guest(list/access)
	if(!length(guest_access))
		return TRUE
	if(ACCESS_NETWORK in access)
		return TRUE
	for(var/needed in guest_access)
		if(needed in access)
			return TRUE
	return FALSE

/datum/netrun_network/proc/node_count_by_type()
	. = list()
	for(var/datum/component/netrun_node/node as anything in nodes)
		.[node.node_type] = (.[node.node_type] || 0) + 1

/// Ключ всей сети ценнее доступа к одному устройству: шлюз учитывает сильнейшего участника.
/datum/netrun_network/proc/breach_security()
	. = security
	for(var/datum/component/netrun_node/node as anything in nodes)
		. = max(., node.get_security())
	return clamp(., 1, 5)

/// ЛВС = отсек с APC. Каждый APC-отсек — отдельная локальная сеть, между ними переходят.
/// Вне станции — изолированный внешний сегмент по Z. Отсеки без APC — общая сеть.
/proc/netrun_network_for(turf/T)
	if(!T)
		return null
	if(!is_station_level(T.z) && !is_mining_level(T.z))
		return SSnetrun.get_network("ext[T.z]")
	var/area/A = get_area(T)
	if(!A)
		return SSnetrun.get_network(NETRUN_LAN_PUBLIC)
	var/area/root_area = A.base_area || A
	if(!root_area.power_apc)
		return SSnetrun.get_network(NETRUN_LAN_PUBLIC)
	return SSnetrun.get_area_network(root_area)

/// Доступы, которые несёт моб (ID в руке, на поясе/шее; у силиконов - всё)
/proc/netrun_mob_access(mob/user)
	. = list()
	if(!user)
		return
	if((issilicon(user) && !ispAI(user)) || IsAdminGhost(user))
		return get_all_accesses()
	if(ishuman(user))
		var/mob/living/carbon/human/H = user
		for(var/obj/item/I in list(H.get_active_held_item(), H.get_inactive_held_item(), H.wear_id, H.wear_neck))
			. |= I.GetAccess()
		return
	if(isliving(user))
		var/mob/living/L = user
		var/obj/item/held = L.get_active_held_item()
		if(held)
			. |= held.GetAccess()

// Кэш идентификатора ЛВС отсека, чтобы одна зона всегда давала одну сеть.
/area
	var/netrun_lan_id
