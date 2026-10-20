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
	/// Neighborhood depth in real graph edges.
	var/map_depth = 2
	/// One consistent, request-local topology snapshot during ui_data serialization.
	var/datum/netrun_path_tree/ui_routes
	/// Пеленг: адрес целевого узла для навигации
	var/waypoint_address
	/// Открытые окна машин (адреса узлов) и активное окно
	var/list/windows = list()
	var/active_window
	/// Просмотр камеры: кто смотрит и через какой узел
	var/mob/watch_viewer
	var/datum/component/netrun_node/watch_node
	/// Native remote-sight adapter for physical viewers; entities apply the same settings themselves.
	var/obj/effect/netrun_view_eye/watch_eye
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
	if(jack?.network && jack_valid())
		. += jack.network
	if(!wireless)
		var/datum/component/netrun_node/source = route_source()
		if(source?.network)
			. |= source.network

/// Есть ли выход в NTnet
/datum/netrun_console/proc/has_uplink()
	var/datum/netrun_path_tree/tree = path_tree()
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	. = FALSE
	for(var/address in tree.reached)
		var/datum/component/netrun_node/node = graph.nodes[address]
		if(!istype(node?.parent, /obj/machinery/ntnet_relay) || !node.is_online())
			continue
		var/obj/machinery/ntnet_relay/relay = node.parent
		if(relay.is_operational() && !SSnetworks.station_network.setting_disabled)
			. = TRUE
			break
	release_path_tree(tree)

/datum/netrun_console/proc/can_reach(datum/netrun_network/network)
	if(!network)
		return FALSE
	var/datum/netrun_path_tree/tree = path_tree()
	. = FALSE
	for(var/datum/component/netrun_node/node as anything in network.nodes)
		if(tree.reached[node.address])
			. = TRUE
			break
	release_path_tree(tree)

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
	var/atom/target = node.parent
	. = max(., target.netrun_owner_access(src))
	if(has_key(node.network))
		. = max(., NETRUN_ACCESS_USER)
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
	var/atom/target = node.parent
	var/owner_level = target.netrun_owner_access(src)
	var/local_endpoint = node == route_source()
	if(net_level < NETRUN_ACCESS_GUEST && !local_endpoint && (!owner_level || !can_route(node)))
		return NETRUN_ACCESS_NONE
	. = max(NETRUN_ACCESS_GUEST, owner_level, net_level, node_access[node.address] || 0, legit_node_level(node))
	if(node == jack)
		. = max(., NETRUN_ACCESS_GUEST)

// MARK: Действия

/datum/netrun_console/proc/selected_node()
	return SSnetrun.find_node(selected_address)

/// Закрытая сеть публикует лишь шлюз и APC. Владелец видит собственное устройство.
/datum/netrun_console/proc/node_visible(datum/component/netrun_node/node)
	if(!node?.network || !can_route(node))
		return FALSE
	return node_level(node) >= NETRUN_ACCESS_GUEST || (node.node_type in list(NETRUN_NODE_APC, NETRUN_NODE_GATEWAY)) || daemon_bonus("mapper")

/datum/netrun_console/proc/run_command(datum/component/netrun_node/node, command_id)
	if(world.time < next_command)
		return FALSE
	next_command = world.time + 0.5 SECONDS
	if(!node || !(command_id in node.all_command_ids()))
		return FALSE
	var/datum/netrun_command/command = SSnetrun.get_command(command_id)
	if(!command)
		return FALSE
	if(is_locked())
		log_line("Точка подключения заблокирована.", "bad")
		return FALSE
	if(!can_route(node))
		log_line("[node.address]: нет маршрута к узлу.", "bad")
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
		return do_command(node, command, command_id, illegal, node.network, operator, selected_file_uid || "none")
	else
		log_line("> [command_id] @ [node.address] (отправка, ~[lat * 100]мс)")
		next_command = world.time + max(0.5 SECONDS, lat)
		addtimer(CALLBACK(src, PROC_REF(do_command), node, command, command_id, illegal, node.network, operator, selected_file_uid || "none"), lat)
	return TRUE

/// Собственно выполнение команды - может вызываться с задержкой маршрута
/datum/netrun_console/proc/do_command(datum/component/netrun_node/node, datum/netrun_command/command, command_id, illegal, datum/netrun_network/sent_network, mob/sender, file_uid)
	if(QDELETED(src) || QDELETED(node) || !command)
		return
	node.join_network()
	if(is_locked())
		return FALSE
	if(sender != operator || !can_route(node) || node.network != sent_network || !(command_id in node.all_command_ids()) || node_level(node) < command.access)
		log_line("[node.address]: запрос отменён — маршрут, оператор или права изменились.", "bad")
		return FALSE
	if(!command.works_offline && !node.is_online(node != jack))
		log_line("[node.address]: узел не отвечает.", "bad")
		return FALSE
	illegal = legit_node_level(node) < command.access
	var/datum/netrun_request/request = new(file_uid)
	var/result = world.PushUsr(operator, CALLBACK(command, TYPE_PROC_REF(/datum/netrun_command, execute), node, src, netrun_command_arg(command_id), request))
	qdel(request)
	if(isnull(result))
		return FALSE
	log_line(result, illegal ? "average" : "good")
	node.add_log("[log_source()]: [command.name][illegal ? " (без авторизации)" : ""].")
	SSnetrun.post_event(illegal ? "intrusion" : "command", node.network?.id, node.address)
	var/atom/target = node.parent
	log_game("NETRUN: [key_name(operator)] ([origin]) [command.id] -> [node.get_name()] [node.address][illegal ? " (взлом)" : ""] [AREACOORD(target)]")
	node.network?.add_log("[log_source()] -> [node.address]: [command.name][illegal ? " (без авторизации)" : ""]", illegal && command.access >= NETRUN_ACCESS_ROOT)
	if(illegal)
		add_trace(command.trace * node.get_security())
	return TRUE

/// Есть ли вообще маршрут к узлу (иначе узел отрезан - подключиться нельзя)
/datum/netrun_console/proc/can_route(datum/component/netrun_node/node)
	node = refresh_route_node(node)
	if(!node)
		return FALSE
	var/datum/netrun_path_tree/tree = path_tree()
	. = !!tree.reached[node.address]
	release_path_tree(tree)

/// Ответ ping приходит после round-trip
/datum/netrun_console/proc/ping_reply(address, lat, route_name)
	var/datum/component/netrun_node/node = SSnetrun.find_node(address)
	if(!node || !can_route(node))
		log_line("ping [address]: ответа нет (узел отрезан).", "bad")
		return
	log_line("[address]: [lat * 2 * 100]мс туда-обратно ([route_name]).", "good")

/// Задержка маршрута до узла в децисекундах: 0 - прямое/рядом, больше - дальше и через реле
/datum/netrun_console/proc/latency_to(datum/component/netrun_node/node)
	var/datum/netrun_route/route = route_to(node)
	. = route.latency
	qdel(route)

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
	SSnetrun.post_event("trace", null, selected_address)
	SSnetrun.ntnet_log("Нарушитель отслежен: точка [origin], район: [where].", TRUE)
	for(var/network_id in SSnetrun.networks)
		var/datum/netrun_network/network = SSnetrun.networks[network_id]
		if(!network.isolated)
			network.add_log("Трассировка завершена: нарушитель в районе [where].")
	host?.netrun_traced(src)

/datum/netrun_console/proc/process_tick(delta)
	if(breach)
		if(!breach.valid_target())
			log_line("Взлом отменён: цель недоступна или переменила сеть.", "bad")
			QDEL_NULL(breach)
		else if(breach.time_left() <= 0)
			breach.finish()
		else
			add_trace(0.6 * breach.security * delta * (breach.target_kind == "network" ? 1.25 : 1))
	else if(trace > 0 && world.time - last_illegal > 10 SECONDS)
		trace = max(0, trace - NETRUN_TRACE_DECAY * delta * (1 + daemon_bonus("scrub")))
	if(jack && !jack_valid())
		log_line("Провод выдернут.", "average")
		set_jack(null)
	if(watch_node && !watch_target())
		stop_watch()
	else if(watch_eye && watch_viewer?.client?.eye != watch_eye)
		stop_watch()
	else if(watch_eye)
		watch_eye.forceMove(get_turf(watch_target()))
		if(isliving(watch_viewer))
			watch_eye.update_remote_sight(watch_viewer)

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
		security = network.breach_security()
		target_name = "шлюз [network.short_name]"
	else
		var/datum/component/netrun_node/node = SSnetrun.find_node(id)
		if(!node || node_level(node) < NETRUN_ACCESS_GUEST || !node.is_online(node != jack) || !can_route(node))
			return FALSE
		security = node.get_security() - (node == jack ? 1 : 0)
		target_name = "[node.get_name()] [node.address]"
		if(kind == "firmware")
			var/datum/netrun_api/api = SSnetrun.get_api(node.parent)
			if(!api?.allow_emag || node_level(node) < NETRUN_ACCESS_ROOT || !daemon_bonus("icepick"))
				return FALSE
			security = 5
			target_name = "прошивка [target_name]"
		node.touch()
	breach = new(src, kind, id, target_name, security)
	if(kind != "network")
		var/datum/component/netrun_node/target = SSnetrun.find_node(id)
		breach.target_network = target.network
	if(kind == "firmware")
		breach.security = 5
		breach.size = 7
		breach.deadline = world.time + 20 SECONDS
		breach.buffer_size = min(breach.buffer_size, 7)
		breach.generate()
	SSnetrun.post_event("breach", kind == "network" ? id : null, kind == "network" ? null : id)
	log_line("Запущен взлом: [target_name].", "average")
	return TRUE

/datum/netrun_console/proc/breach_finished(datum/netrun_breach/finished)
	if(finished != breach)
		return
	if(!finished.valid_target())
		breach = null
		log_line("Взлом отменён: соединение с целью потеряно.", "bad")
		qdel(finished)
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
	if(finished.target_kind == "firmware")
		var/datum/component/netrun_node/node = SSnetrun.find_node(finished.target_id)
		if(reward >= NETRUN_ACCESS_ROOT && node && can_route(node) && node.is_online(node != jack) && node_level(node) >= NETRUN_ACCESS_ROOT && daemon_bonus("icepick"))
			apply_firmware_bypass(node)
		else
			log_line("Взлом прошивки не завершён или соединение потеряно.", "bad")
			add_trace(25)
		qdel(finished)
		return
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
	. = 0
	for(var/datum/netrun_file/file as anything in all_files())
		if(file.kind != NETRUN_FILE_DAEMON)
			continue
		var/datum/netrun_daemon/daemon = SSnetrun.get_daemon(file.content)
		if(daemon && daemon.bonus_kind == id)
			. = max(., daemon.bonus)

/datum/netrun_console/proc/effective_trace_mult()
	return trace_mult * max(0.1, 1 - daemon_bonus("cloak"))

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
	var/turf/source_turf = get_turf(host)
	var/turf/target_turf = get_turf(jack?.parent)
	return source_turf && target_turf && source_turf.z == target_turf.z && get_dist(source_turf, target_turf) <= 1

// MARK: Журнал

/datum/netrun_console/proc/log_line(text, kind = "label")
	log += list(list("time" = STATION_TIME_TIMESTAMP("hh:mm:ss", world.time), "text" = text, "kind" = kind))
	host?.netrun_console_event(src, text, kind)
	SEND_SIGNAL(src, COMSIG_NETRUN_CONSOLE_EVENT, text, kind)
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
