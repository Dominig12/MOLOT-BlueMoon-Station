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
	return list()

/// «Живой кадр» для окон-камер: список строк, что видно; null - не камера/нет доступа
/atom/proc/netrun_window_feed(datum/netrun_console/console, datum/component/netrun_node/node)
	return null

/// Обработать оконное действие машины. Возврат - текст результата или null
/atom/proc/netrun_window_act(datum/netrun_console/console, datum/component/netrun_node/node, action, list/params)
	return

// MARK: Консоль: окна

/datum/netrun_console/proc/open_window(address)
	var/datum/component/netrun_node/node = SSnetrun.find_node(address)
	if(!node || node_level(node) < NETRUN_ACCESS_GUEST || !can_route(node))
		return FALSE
	if(!(address in windows))
		if(length(windows) >= NETRUN_MAX_WINDOWS)
			windows.Cut(1, 2)
		windows += address
	active_window = address
	return TRUE

/datum/netrun_console/proc/close_window(address)
	windows -= address
	if(watch_node?.address == address)
		stop_watch()
	if(active_window == address)
		active_window = length(windows) ? windows[length(windows)] : null

/datum/netrun_console/proc/window_payload()
	var/datum/component/netrun_node/node = SSnetrun.find_node(active_window)
	if(!node)
		active_window = null
		return null
	var/level = node_level(node)
	if(level < NETRUN_ACCESS_GUEST)
		return null
	var/atom/A = node.parent
	var/list/commands = list()
	for(var/command_id in node.all_command_ids())
		var/datum/netrun_command/command = SSnetrun.get_command(command_id)
		if(command)
			commands += list(command.ui_entry(node, src, command_id))
	var/list/extra = list()
	for(var/list/entry as anything in A.netrun_window_actions(src, node))
		entry["allowed"] = level >= (entry["access"] || NETRUN_ACCESS_GUEST)
		extra += list(entry)
	return list(
		"address" = node.address,
		"title" = node.get_name(),
		"type" = node.node_type,
		"online" = node.is_online(),
		"access" = level,
		"fields" = level >= NETRUN_ACCESS_USER ? A.netrun_window_fields(src, node) : list(),
		"commands" = commands,
		"extra" = extra,
		"feed" = A.netrun_window_feed(src, node),
		"watching" = watch_node == node,
	)

/datum/netrun_console/proc/windows_payload()
	. = list()
	for(var/address in windows.Copy())
		var/datum/component/netrun_node/node = SSnetrun.find_node(address)
		if(!node || node_level(node) < NETRUN_ACCESS_GUEST)
			windows -= address
			if(active_window == address)
				active_window = null
			continue
		. += list(list("address" = address, "title" = node.get_name(), "type" = node.node_type, "online" = node.is_online()))

/datum/netrun_console/proc/window_act(address, action, list/params)
	var/datum/component/netrun_node/node = SSnetrun.find_node(address)
	if(!node || node_level(node) < NETRUN_ACCESS_GUEST)
		return
	// Команда узла - обычный сетевой запрос с задержкой и трассировкой
	if(action in node.all_command_ids())
		run_command(node, action)
		return
	// Оконное действие машины
	var/atom/A = node.parent
	var/result = A.netrun_window_act(src, node, action, params)
	if(!isnull(result))
		log_line(result)

// MARK: Просмотр камеры

/datum/netrun_console/proc/start_watch(datum/component/netrun_node/node, atom/eye_target)
	if(!operator?.client)
		return
	stop_watch()
	watch_viewer = operator
	watch_node = node
	operator.reset_perspective(eye_target)
	log_line("Подключён видеопоток [node.address].", "good")

/datum/netrun_console/proc/stop_watch()
	if(watch_viewer?.client)
		watch_viewer.reset_perspective(null)
	watch_viewer = null
	watch_node = null

// MARK: Камеры - окно и просмотр

/obj/machinery/camera/netrun_window_feed(datum/netrun_console/console, datum/component/netrun_node/node)
	if(console.node_level(node) < NETRUN_ACCESS_USER || !netrun_online())
		return null
	var/turf/T = get_turf(src)
	if(!T)
		return list("Нет сигнала.")
	var/list/seen = list()
	for(var/mob/living/L in view(7, T))
		seen += "[L.name] — [L.stat == DEAD ? "не двигается" : "движется"]"
	if(!length(seen))
		seen += "В поле зрения пусто."
	return seen

/obj/machinery/camera/netrun_window_actions(datum/netrun_console/console, datum/component/netrun_node/node)
	return list(
		list("id" = "cam_watch", "name" = "Смотреть", "icon" = "eye", "access" = NETRUN_ACCESS_USER, "desc" = "Переключить обзор на эту камеру."),
		list("id" = "cam_unwatch", "name" = "Отключить обзор", "icon" = "eye-slash", "access" = NETRUN_ACCESS_GUEST, "desc" = "Вернуть собственный обзор."),
	)

/obj/machinery/camera/netrun_window_act(datum/netrun_console/console, datum/component/netrun_node/node, action, list/params)
	switch(action)
		if("cam_watch")
			if(console.node_level(node) < NETRUN_ACCESS_USER)
				return "Недостаточно прав."
			if(!status || !netrun_online())
				return "Камера не ведёт запись."
			console.start_watch(node, src)
			return
		if("cam_unwatch")
			console.stop_watch()
			return "Обзор возвращён."

#undef NETRUN_MAX_WINDOWS
