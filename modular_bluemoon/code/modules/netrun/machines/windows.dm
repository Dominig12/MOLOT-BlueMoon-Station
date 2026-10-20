// MARK: Вкладки и окна машин
//
// Любой узел можно открыть «окном» во вкладке терминала: его состояние, команды и особые
// действия (у некоторых машин - свои механики, часть под взломом). Камеру можно смотреть
// по подключению. Команды окна - это те же сетевые запросы к машине, что и в панели узла,
// плюс оконные действия, которые машина объявляет через хуки ниже.

#define NETRUN_MAX_WINDOWS 5

// MARK: Хуки машин

/// Дополнительные поля окна (строки состояния сверх netrun_status). По умолчанию - статус.
/atom/proc/netrun_window_fields(datum/netrun_console/console, datum/component/netrun_node/node)
	return netrun_status()

/// Особые оконные действия машины: list(list("id","name","icon","access","danger","desc"))
/atom/proc/netrun_window_actions(datum/netrun_console/console, datum/component/netrun_node/node)
	if(!netrun_view_capable())
		return list()
	return list(
		list("id" = "view_watch", "name" = "Смотреть", "icon" = "eye", "access" = NETRUN_ACCESS_USER, "desc" = "Подключиться к видеопотоку устройства."),
		list("id" = "view_unwatch", "name" = "Отключить обзор", "icon" = "eye-slash", "access" = NETRUN_ACCESS_GUEST, "desc" = "Вернуть собственный обзор."),
	)

/// «Живой кадр» для окон-камер: список строк, что видно; null - не камера/нет доступа
/atom/proc/netrun_window_feed(datum/netrun_console/console, datum/component/netrun_node/node)
	if(!netrun_view_capable() || console.node_level(node) < NETRUN_ACCESS_USER)
		return null
	var/atom/eye = node.is_online() && console.can_route(node) ? netrun_view_target() : null
	if(!eye)
		return list("Нет видеосигнала: проверьте питание, состояние оптики и прошивку.")
	var/list/seen = list()
	for(var/mob/living/person in view(7, eye))
		if(person == eye)
			continue
		seen += "[person.name] — [person.stat == DEAD ? "не двигается" : "движется"]"
	if(!length(seen))
		seen += "В поле зрения пусто."
	return seen

/// Обработать оконное действие машины. Возврат - текст результата или null
/atom/proc/netrun_window_act(datum/netrun_console/console, datum/component/netrun_node/node, action, list/params)
	if(!netrun_view_capable())
		return
	switch(action)
		if("view_watch")
			return console.start_watch(node) ? "Видеопоток подключён." : "Видеопоток недоступен."
		if("view_unwatch")
			console.stop_watch()
			return "Обзор возвращён."

// MARK: Консоль: окна

/datum/netrun_console/proc/open_window(address)
	var/datum/component/netrun_node/node = SSnetrun.find_node(address)
	if(!node || !node_visible(node))
		return FALSE
	if(!(address in windows))
		if(length(windows) >= NETRUN_MAX_WINDOWS)
			windows.Cut(1, 2)
		windows += address
	active_window = address
	selected_address = address
	selected_network = null
	return TRUE

/datum/netrun_console/proc/close_window(address)
	windows -= address
	if(watch_node?.address == address)
		stop_watch()
	if(active_window == address)
		active_window = length(windows) ? windows[length(windows)] : null
		selected_address = active_window
		selected_network = null

/datum/netrun_console/proc/window_payload()
	var/datum/component/netrun_node/node = SSnetrun.find_node(active_window)
	if(!node)
		active_window = null
		return null
	var/level = node_level(node)
	var/atom/A = node.parent
	var/list/extra = list()
	for(var/list/entry as anything in A.netrun_window_actions(src, node))
		entry["allowed"] = level >= (entry["access"] || NETRUN_ACCESS_GUEST) && can_route(node) && node.is_online() && !is_locked()
		extra += list(entry)
	var/datum/netrun_network/network = node.network
	return list(
		"address" = node.address,
		"title" = node.get_name(),
		"type" = node.node_type,
		"online" = node.is_online(),
		"access" = level,
		"legit" = legit_node_level(node),
		"security" = node.get_security(),
		"can_breach" = can_breach && level >= NETRUN_ACCESS_GUEST && level < NETRUN_ACCESS_ROOT && can_route(node),
		"network" = network ? list("id" = network.id, "name" = network.name, "code" = network.code, "access" = network_level(network), "can_breach" = can_breach && can_reach(network) && network_level(network) < NETRUN_ACCESS_GUEST) : null,
		"fields" = level >= NETRUN_ACCESS_USER ? A.netrun_window_fields(src, node) : list(),
		"commands" = node.command_entries(src),
		"logs" = level >= NETRUN_ACCESS_USER ? node.logs.Copy() : list(),
		"remote" = remote_payload(node),
		"extra" = extra,
		"feed" = level >= NETRUN_ACCESS_USER ? A.netrun_window_feed(src, node) : null,
		"watching" = watch_node == node,
	)

/datum/netrun_console/proc/windows_payload()
	. = list()
	for(var/address in windows.Copy())
		var/datum/component/netrun_node/node = SSnetrun.find_node(address)
		if(!node)
			windows -= address
			if(active_window == address)
				active_window = null
			continue
		. += list(list("address" = address, "title" = node.get_name(), "type" = node.node_type, "online" = node.is_online()))

/datum/netrun_console/proc/window_act(address, action, list/params)
	var/datum/component/netrun_node/node = SSnetrun.find_node(address)
	if(!node || node_level(node) < NETRUN_ACCESS_GUEST || !can_route(node) || is_locked())
		return
	// Команда узла - обычный сетевой запрос с задержкой и трассировкой
	if(action in node.all_command_ids())
		run_command(node, action)
		return
	// Оконное действие машины
	if(world.time < next_command || !node.is_online())
		return
	var/list/entry = window_action(node, action)
	if(!entry || node_level(node) < (entry["access"] || NETRUN_ACCESS_GUEST))
		log_line("Действие окна не разрешено.", "bad")
		return
	var/lat = latency_to(node)
	next_command = world.time + max(0.5 SECONDS, lat)
	addtimer(CALLBACK(src, PROC_REF(do_window_act), node, action, params.Copy(), node.network, operator), max(1, lat))
	log_line("[node.address]: запрос «[entry["name"]]» отправлен, ~[lat * 100] мс.")

/datum/netrun_console/proc/window_action(datum/component/netrun_node/node, action)
	var/atom/A = node.parent
	for(var/list/entry as anything in A.netrun_window_actions(src, node))
		if(entry["id"] == action)
			return entry

/datum/netrun_console/proc/do_window_act(datum/component/netrun_node/node, action, list/params, datum/netrun_network/sent_network, mob/sender)
	if(!QDELETED(node))
		node.join_network()
	if(QDELETED(node) || is_locked() || !can_route(node) || !node.is_online() || node.network != sent_network || sender != operator)
		log_line("Запрос окна отменён: связь изменилась.", "bad")
		return
	var/list/entry = window_action(node, action)
	var/required = entry?["access"] || NETRUN_ACCESS_GUEST
	if(!entry || node_level(node) < required)
		return
	var/atom/A = node.parent
	var/result = world.PushUsr(operator, CALLBACK(A, TYPE_PROC_REF(/atom, netrun_window_act), src, node, action, params))
	if(!isnull(result))
		log_line(result)
	var/illegal = legit_node_level(node) < required
	node.add_log("[log_source()]: [entry["name"]][illegal ? " (без авторизации)" : ""].")
	node.network?.add_log("[log_source()] -> [node.address]: [entry["name"]]", illegal)
	if(illegal)
		add_trace(4 * node.get_security())

// MARK: Видеопотоки

/// Revalidate the source on every tick, including worn optics and disabled implants.
/datum/netrun_console/proc/watch_target()
	if(QDELETED(watch_node) || QDELETED(operator) || watch_viewer != operator || is_locked())
		return null
	if(!watch_node.is_online() || !can_route(watch_node) || node_level(watch_node) < NETRUN_ACCESS_USER)
		return null
	var/atom/source = watch_node.parent
	return source.netrun_view_target()

/datum/netrun_console/proc/start_watch(datum/component/netrun_node/node)
	if(!operator?.client || QDELETED(node))
		return FALSE
	stop_watch()
	watch_viewer = operator
	watch_node = node
	var/atom/eye = watch_target()
	if(!eye)
		stop_watch()
		return FALSE
	if(operator.netrun_watch_console && operator.netrun_watch_console != src)
		operator.netrun_watch_console.stop_watch()
	operator.netrun_watch_console = src
	watch_eye = new(get_turf(eye), src)
	operator.reset_perspective(watch_eye)
	if(istype(operator, /mob/camera/netrun_entity))
		var/mob/camera/netrun_entity/entity = operator
		entity.update_vision()
	return TRUE

/datum/netrun_console/proc/stop_watch()
	var/mob/previous_viewer = watch_viewer
	var/owns_perspective = previous_viewer?.client?.eye == watch_eye && watch_eye
	if(previous_viewer?.netrun_watch_console == src)
		previous_viewer.netrun_watch_console = null
	watch_viewer = null
	watch_node = null
	QDEL_NULL(watch_eye)
	if(owns_perspective && previous_viewer?.client)
		previous_viewer.reset_perspective(null)
		if(istype(previous_viewer, /mob/camera/netrun_entity))
			var/mob/camera/netrun_entity/entity = previous_viewer
			entity.update_vision()

#undef NETRUN_MAX_WINDOWS
