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

/datum/netrun_network/New(new_id)
	id = new_id
	passcode = "[uppertext(copytext(md5("[new_id][world.time][rand(1, 999999)]"), 1, 17))]"
	code = "NET-[uppertext(copytext(md5("[new_id][passcode]"), 1, 6))]"
	switch(id)
		if(NETRUN_LAN_PUBLIC)
			name = "Общая сеть станции"
			short_name = "ОБЩ"
			security = 1
			guest_access = list()
			color = "#8b93a3"
		if(NETRUN_LAN_CARGO)
			name = "Сеть снабжения"
			short_name = "СНБ"
			security = 1
			guest_access = list(ACCESS_CARGO)
			color = "#c9a227"
		if(NETRUN_LAN_ENGINEERING)
			name = "Инженерная сеть"
			short_name = "ИНЖ"
			security = 2
			guest_access = list(ACCESS_ENGINE, ACCESS_ENGINE_EQUIP)
			color = "#f0a030"
		if(NETRUN_LAN_MEDICAL)
			name = "Медицинская сеть"
			short_name = "МЕД"
			security = 2
			guest_access = list(ACCESS_MEDICAL)
			color = "#5bc0de"
		if(NETRUN_LAN_SCIENCE)
			name = "Научная сеть"
			short_name = "НИО"
			security = 2
			guest_access = list(ACCESS_RESEARCH, ACCESS_TOX, ACCESS_ROBOTICS)
			color = "#b07cff"
		if(NETRUN_LAN_SECURITY)
			name = "Сеть службы безопасности"
			short_name = "СБ"
			security = 3
			guest_access = list(ACCESS_SECURITY)
			color = "#ff5050"
		if(NETRUN_LAN_COMMAND)
			name = "Командная сеть"
			short_name = "КОМ"
			security = 4
			guest_access = list(ACCESS_HEADS)
			color = "#3cdc8c"
		else
			name = "Внешний сегмент [id]"
			short_name = "ВНШ"
			security = 2
			isolated = TRUE
			guest_access = list()
			color = "#d05090"
	add_log("Сеть инициализирована.")

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

/// В какую ЛВС попадает машина, стоящая в этой зоне
/proc/netrun_lan_for_turf(turf/T)
	if(!T)
		return
	if(!is_station_level(T.z) && !is_mining_level(T.z))
		return "ext[T.z]"
	var/area/A = T.loc
	if(istype(A, /area/security))
		return NETRUN_LAN_SECURITY
	if(istype(A, /area/command) || istype(A, /area/ai_monitored))
		return NETRUN_LAN_COMMAND
	if(istype(A, /area/engineering))
		return NETRUN_LAN_ENGINEERING
	if(istype(A, /area/medical))
		return NETRUN_LAN_MEDICAL
	if(istype(A, /area/science))
		return NETRUN_LAN_SCIENCE
	if(istype(A, /area/cargo))
		return NETRUN_LAN_CARGO
	return NETRUN_LAN_PUBLIC

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
