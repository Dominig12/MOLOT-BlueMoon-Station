/**
 * Консоль - общий датум для всех точек подключения к сети.
 * Терминал, кибердека, имплант, NTOS-программа и сущность держат свою консоль
 * и отличаются только тем, откуда идёт подключение (origin) и куда бьёт трассировка.
 */
/datum/netrun_console
	var/name = "консоль"
	/// Физический носитель: терминал, дека, имплант, компьютер или сущность
	var/atom/host
	var/origin = NETRUN_ORIGIN_TERMINAL
	/// Беспроводная точка - нужна станция/шахта и рабочие ретрансляторы
	var/wireless = TRUE
	/// Может ли консоль запускать взлом
	var/can_breach = TRUE
	var/trace = 0
	var/trace_mult = 1
	var/last_illegal = -INFINITY
	var/lockout_until = 0
	var/buffer_bonus = 0
	/// адрес = уровень доступа, полученный взломом
	var/list/node_access = list()
	/// id сети = уровень доступа к шлюзу, полученный взломом
	var/list/network_access = list()
	var/viewed_network_id
	var/selected_address
	var/datum/netrun_breach/breach
	var/list/log = list()
	var/list/datum/netrun_file/storage = list()
	var/storage_capacity = 6
	var/obj/item/netrun_shard/shard
	/// Узел, к которому консоль подключена проводом (дека)
	var/datum/component/netrun_node/jack
	/// Последний оператор - от его ID считается легальный доступ
	var/mob/operator
	var/next_command = 0
	/// Мост «сайты в терминале»: выбранный сайт NTnet и страница
	var/web_site_id
	var/web_slug
	/// Выбранный на карте гейтвей подсети
	var/selected_network
	/// Маршрут последнего ping для подсветки на карте
	var/list/ping_route
	var/ping_at = 0
	/// Открытые окна машин (адреса узлов) и активное окно
	var/list/windows = list()
	var/active_window
	/// Просмотр камеры: кто смотрит и через какой узел
	var/mob/watch_viewer
	var/datum/component/netrun_node/watch_node
	/// Кеш на время одного ui_data: доступы оператора и уровни сетей
	var/list/access_cache
	var/list/network_level_cache

/datum/netrun_console/New(atom/host, origin)
	src.host = host
	if(origin)
		src.origin = origin
	SSnetrun.consoles += src
	log_line("Сеанс открыт.", "good")

/datum/netrun_console/Destroy()
	stop_watch()
	SSnetrun.consoles -= src
	QDEL_NULL(breach)
	QDEL_LIST(storage)
	set_jack(null)
	operator = null
	shard = null
	host = null
	return ..()

/datum/netrun_console/ui_host(mob/user)
	return host || src

// MARK: Маршрутизация

/// Сети, в которых консоль находится физически
/datum/netrun_console/proc/home_networks()
	. = list()
	if(jack?.network)
		. += jack.network
	if(!wireless)
		var/lan = netrun_lan_for_turf(get_turf(host))
		if(lan)
			. |= SSnetrun.get_network(lan)

/// Есть ли выход в NTnet
/datum/netrun_console/proc/has_uplink()
	var/turf/T = get_turf(host)
	if(!T)
		return FALSE
	if(wireless && !is_station_level(T.z) && !is_mining_level(T.z))
		return FALSE
	return SSnetrun.backbone_online(T.z)

/datum/netrun_console/proc/can_reach(datum/netrun_network/network)
	if(!network)
		return FALSE
	if(network in home_networks())
		return TRUE
	return !network.isolated && has_uplink()

/datum/netrun_console/proc/is_locked()
	return world.time < lockout_until

// MARK: Доступ

/datum/netrun_console/proc/user_access()
	return access_cache || netrun_mob_access(operator)

/datum/netrun_console/proc/has_key(datum/netrun_network/network)
	for(var/datum/netrun_file/file as anything in all_files())
		if(file.kind == NETRUN_FILE_KEY && file.network_id == network.id && file.content == network.passcode)
			return TRUE
	return FALSE

/datum/netrun_console/proc/legit_network_level(datum/netrun_network/network)
	if(has_key(network))
		return NETRUN_ACCESS_USER
	return network.legit_guest(user_access()) ? NETRUN_ACCESS_GUEST : NETRUN_ACCESS_NONE

/datum/netrun_console/proc/network_level(datum/netrun_network/network)
	if(network_level_cache && !isnull(network_level_cache[network.id]))
		return network_level_cache[network.id]
	if(!can_reach(network) || is_locked())
		. = NETRUN_ACCESS_NONE
	else
		. = max(network_access[network.id] || 0, legit_network_level(network))
		if(network in home_networks())
			. = max(., NETRUN_ACCESS_GUEST)
	if(network_level_cache)
		network_level_cache[network.id] = .

/datum/netrun_console/proc/legit_node_level(datum/component/netrun_node/node)
	if(!node.network)
		return NETRUN_ACCESS_NONE
	. = legit_network_level(node.network) ? NETRUN_ACCESS_GUEST : NETRUN_ACCESS_NONE
	if(has_key(node.network))
		. = NETRUN_ACCESS_USER
	var/list/access = user_access()
	if(!length(access))
		return
	var/user_ok
	if(node.required_access)
		user_ok = FALSE
		for(var/needed in node.required_access)
			if(needed in access)
				user_ok = TRUE
				break
	else if(isobj(node.parent))
		var/obj/O = node.parent
		user_ok = O.check_access_list(access)
	if(!user_ok)
		return
	. = max(., NETRUN_ACCESS_USER)
	if((ACCESS_CAPTAIN in access) || (ACCESS_NETWORK in access))
		. = NETRUN_ACCESS_ROOT

/datum/netrun_console/proc/node_level(datum/component/netrun_node/node)
	if(!node?.network || is_locked())
		return NETRUN_ACCESS_NONE
	var/net_level = network_level(node.network)
	if(net_level < NETRUN_ACCESS_GUEST)
		return NETRUN_ACCESS_NONE
	. = max(NETRUN_ACCESS_GUEST, net_level, node_access[node.address] || 0, legit_node_level(node))
	if(node == jack)
		. = max(., NETRUN_ACCESS_GUEST)

// MARK: Действия

/datum/netrun_console/proc/selected_node()
	return SSnetrun.find_node(selected_address)

/datum/netrun_console/proc/run_command(datum/component/netrun_node/node, command_id)
	if(world.time < next_command)
		return FALSE
	next_command = world.time + 0.5 SECONDS
	if(!node || !(command_id in node.command_ids))
		return FALSE
	var/datum/netrun_command/command = SSnetrun.get_command(command_id)
	if(!command)
		return FALSE
	if(is_locked())
		log_line("Точка подключения заблокирована.", "bad")
		return FALSE
	if(!command.works_offline && !node.is_online(node != jack))
		log_line("[node.address]: узел не отвечает.", "bad")
		return FALSE
	var/level = node_level(node)
	if(level < command.access)
		log_line("[node.address]: недостаточно прав для «[command.name]».", "bad")
		return FALSE
	var/illegal = legit_node_level(node) < command.access
	node.touch()
	// Задержка маршрута: прямое/близкое подключение - почти мгновенно, дальнее через реле - с лагом.
	var/lat = command.ignores_latency ? 0 : latency_to(node)
	if(lat <= 0)
		log_line("> [command_id] @ [node.address]")
		do_command(node, command, command_id, illegal)
	else
		log_line("> [command_id] @ [node.address] (отправка, ~[lat * 100]мс)")
		next_command = world.time + max(0.5 SECONDS, lat)
		addtimer(CALLBACK(src, PROC_REF(do_command), node, command, command_id, illegal), lat)
	return TRUE

/// Собственно выполнение команды - может вызываться с задержкой маршрута
/datum/netrun_console/proc/do_command(datum/component/netrun_node/node, datum/netrun_command/command, command_id, illegal)
	if(QDELETED(src) || QDELETED(node) || !command)
		return
	if(is_locked())
		return
	if(!command.works_offline && !node.is_online(node != jack))
		log_line("[node.address]: узел не отвечает.", "bad")
		return
	var/result = command.execute(node, src, netrun_command_arg(command_id))
	if(isnull(result))
		return
	log_line(result, illegal ? "average" : "good")
	var/atom/target = node.parent
	log_game("NETRUN: [key_name(operator)] ([origin]) [command.id] -> [node.get_name()] [node.address][illegal ? " (взлом)" : ""] [AREACOORD(target)]")
	node.network?.add_log("[log_source()] -> [node.address]: [command.name][illegal ? " (без авторизации)" : ""]", illegal && command.access >= NETRUN_ACCESS_ROOT)
	if(illegal)
		add_trace(command.trace * node.get_security())

/// Задержка маршрута до узла в децисекундах: 0 - прямое/рядом, больше - дальше и через реле
/datum/netrun_console/proc/latency_to(datum/component/netrun_node/node)
	if(!node || node == jack)
		return 0
	var/turf/here = get_turf(host)
	var/turf/there = get_turf(node.parent)
	if(!here || !there)
		return 2
	var/wired = (node.network in home_networks()) && !wireless
	if(wired)
		return here.z == there.z ? clamp(round(get_dist(here, there) / 40), 0, 2) : 3
	var/lat = 3 // прыжок через квантовое реле
	if(here.z == there.z)
		lat += clamp(round(get_dist(here, there) / 25), 0, 4)
	else
		lat += 5
	return clamp(lat, 1, 15)

/datum/netrun_console/proc/log_source()
	if(operator && !wireless)
		return "[operator.real_name || operator.name] ([get_area_name(host, TRUE)])"
	return "узел [origin] [REF(src)]"

/datum/netrun_console/proc/add_trace(amount)
	if(amount <= 0)
		return
	last_illegal = world.time
	trace = min(NETRUN_TRACE_MAX, trace + amount * effective_trace_mult())
	if(trace >= NETRUN_TRACE_MAX)
		traced()

/datum/netrun_console/proc/traced()
	trace = 0
	lockout_until = world.time + NETRUN_TRACE_LOCKOUT
	node_access.Cut()
	network_access.Cut()
	QDEL_NULL(breach)
	stop_watch()
	windows.Cut()
	active_window = null
	var/where = get_area_name(host, TRUE) || "неизвестно"
	log_line("ВАС ОТСЛЕДИЛИ. Соединение разорвано.", "bad")
	SSnetrun.ntnet_log("Нарушитель отслежен: точка [origin], район: [where].", TRUE)
	for(var/network_id in SSnetrun.networks)
		var/datum/netrun_network/network = SSnetrun.networks[network_id]
		if(!network.isolated)
			network.add_log("Трассировка завершена: нарушитель в районе [where].")
	host?.netrun_traced(src)

/datum/netrun_console/proc/process_tick(delta)
	if(breach)
		if(breach.time_left() <= 0)
			breach.finish()
		else
			add_trace(0.6 * breach.security * delta)
	else if(trace > 0 && world.time - last_illegal > 10 SECONDS)
		trace = max(0, trace - NETRUN_TRACE_DECAY * delta)
	if(jack && !jack_valid())
		log_line("Провод выдернут.", "average")
		set_jack(null)
	if(watch_node && (QDELETED(watch_node) || !watch_node.is_online() || watch_viewer != operator || is_locked()))
		stop_watch()

// MARK: Взлом

/datum/netrun_console/proc/start_breach(kind, id)
	if(!can_breach || breach || is_locked())
		return FALSE
	var/security
	var/target_name
	if(kind == "network")
		var/datum/netrun_network/network = SSnetrun.networks[id]
		if(!network || !can_reach(network))
			return FALSE
		security = network.security
		target_name = "шлюз [network.short_name]"
	else
		var/datum/component/netrun_node/node = SSnetrun.find_node(id)
		if(!node || node_level(node) < NETRUN_ACCESS_GUEST || !node.is_online(node != jack))
			return FALSE
		security = node.get_security() - (node == jack ? 1 : 0)
		target_name = "[node.get_name()] [node.address]"
		node.touch()
	breach = new(src, kind, id, target_name, security)
	log_line("Запущен взлом: [target_name].", "average")
	return TRUE

/datum/netrun_console/proc/breach_finished(datum/netrun_breach/finished)
	if(finished != breach)
		return
	var/reward = NETRUN_ACCESS_NONE
	var/clean = FALSE
	for(var/list/daemon as anything in finished.daemons)
		if(!daemon["done"])
			continue
		if(daemon["reward"])
			reward = max(reward, daemon["reward"])
		else
			clean = TRUE
	breach = null
	if(finished.target_kind == "network")
		reward = min(reward, NETRUN_ACCESS_GUEST)
	if(!reward && !clean)
		log_line("Взлом провален.", "bad")
		add_trace(25)
	else
		if(finished.target_kind == "network")
			network_access[finished.target_id] = max(network_access[finished.target_id] || 0, reward)
		else
			node_access[finished.target_id] = max(node_access[finished.target_id] || 0, reward)
		log_line("Взлом завершён: [finished.target_name], уровень [netrun_access_name(reward)].", "good")
		if(clean)
			trace = 0
			log_line("Следы заметены.", "good")
	qdel(finished)

// MARK: Файлы

/datum/netrun_console/proc/all_files()
	. = storage.Copy()
	if(shard)
		. += shard.files

/datum/netrun_console/proc/store_file(datum/netrun_file/file, to_shard = FALSE)
	if(to_shard)
		if(!shard || netrun_storage_used(shard.files) + file.size > shard.capacity)
			return FALSE
		shard.files += file
		return TRUE
	if(netrun_storage_used(storage) + file.size > storage_capacity)
		return FALSE
	storage += file
	return TRUE

/datum/netrun_console/proc/find_local_file(uid)
	for(var/datum/netrun_file/file as anything in all_files())
		if(file.uid == uid)
			return file

/datum/netrun_console/proc/delete_local_file(datum/netrun_file/file)
	storage -= file
	shard?.files -= file
	qdel(file)

/// Бонус от установленных демонов (каждый тип считается один раз)
/datum/netrun_console/proc/daemon_bonus(id)
	for(var/datum/netrun_file/file as anything in all_files())
		if(file.kind == NETRUN_FILE_DAEMON && file.content == id)
			return 1
	return 0

/datum/netrun_console/proc/effective_trace_mult()
	return trace_mult * (daemon_bonus("cloak") ? 0.7 : 1)

// MARK: Провод

/datum/netrun_console/proc/set_jack(datum/component/netrun_node/node)
	if(jack)
		UnregisterSignal(jack, COMSIG_PARENT_QDELETING)
	jack = node
	if(jack)
		RegisterSignal(jack, COMSIG_PARENT_QDELETING, PROC_REF(on_jack_deleted))
		viewed_network_id = jack.network?.id
		selected_address = jack.address

/datum/netrun_console/proc/on_jack_deleted(datum/source)
	SIGNAL_HANDLER
	set_jack(null)

/datum/netrun_console/proc/jack_valid()
	return jack && get_dist(get_turf(host), get_turf(jack.parent)) <= 1

// MARK: Журнал

/datum/netrun_console/proc/log_line(text, kind = "label")
	log += list(list("time" = STATION_TIME_TIMESTAMP("hh:mm:ss", world.time), "text" = text, "kind" = kind))
	host?.netrun_console_event(src, text, kind)
	if(length(log) > NETRUN_MAX_CONSOLE_LOG)
		log.Cut(1, length(log) - NETRUN_MAX_CONSOLE_LOG + 1)

/proc/netrun_access_name(level)
	switch(level)
		if(NETRUN_ACCESS_GUEST)
			return "ГОСТЬ"
		if(NETRUN_ACCESS_USER)
			return "ПОЛЬЗОВАТЕЛЬ"
		if(NETRUN_ACCESS_ROOT)
			return "ROOT"
	return "НЕТ"
