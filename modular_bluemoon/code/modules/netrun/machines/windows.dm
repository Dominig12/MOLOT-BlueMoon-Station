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
	return remote_session.open_window(address)

/datum/netrun_remote_session/proc/open_window(address)
	var/datum/component/netrun_node/node = SSnetrun.find_node(address)
	if(!node || !owner.node_visible(node))
		return FALSE
	if(!(address in windows))
		if(length(windows) >= NETRUN_MAX_WINDOWS)
			windows.Cut(1, 2)
		windows += address
	active_window = address
	owner.workspace_view = "pinned"
	owner.map_view.selected_address = address
	owner.map_view.selected_network = null
	return TRUE

/datum/netrun_console/proc/close_window(address)
	return remote_session.close_window(address)

/datum/netrun_remote_session/proc/close_window(address)
	windows -= address
	if(watch_node?.address == address)
		owner.stop_watch()
	if(active_window == address)
		active_window = length(windows) ? windows[length(windows)] : null
		owner.map_view.selected_address = active_window
		owner.map_view.selected_network = null

/datum/netrun_console/proc/window_payload()
	return remote_session.window_payload()

/datum/netrun_remote_session/proc/window_payload()
	var/datum/component/netrun_node/node = SSnetrun.find_node(active_window)
	if(!node)
		active_window = null
		return null
	var/level = owner.node_level(node)
	var/atom/A = node.parent
	var/list/extra = list()
	for(var/list/entry as anything in A.netrun_window_actions(owner, node))
		entry["allowed"] = level >= (entry["access"] || NETRUN_ACCESS_GUEST) && owner.can_route(node) && node.is_online() && !owner.is_locked()
		extra += list(entry)
	var/datum/netrun_network/network = node.network
	return list(
		"address" = node.address,
		"title" = node.get_name(),
		"type" = node.node_type,
		"online" = node.is_online(),
		"access" = level,
		"legit" = owner.legit_node_level(node),
		"security" = node.get_security(),
		"can_breach" = owner.intrusion.can_breach && level >= NETRUN_ACCESS_GUEST && level < NETRUN_ACCESS_ROOT && owner.can_route(node),
		"network" = network ? list("id" = network.id, "name" = network.name, "code" = network.code, "access" = owner.network_level(network), "can_breach" = owner.intrusion.can_breach && owner.can_reach(network) && owner.network_level(network) < NETRUN_ACCESS_GUEST) : null,
		"fields" = level >= NETRUN_ACCESS_USER ? A.netrun_window_fields(owner, node) : list(),
		"commands" = node.command_entries(owner),
		"logs" = level >= NETRUN_ACCESS_USER ? node.logs.Copy() : list(),
		"remote" = owner.remote_payload(node),
		"extra" = extra,
		"feed" = level >= NETRUN_ACCESS_USER ? A.netrun_window_feed(owner, node) : null,
		"watching" = watch_node == node,
	)

/datum/netrun_console/proc/windows_payload()
	return remote_session.windows_payload()

/datum/netrun_remote_session/proc/windows_payload()
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
	return remote_session.window_act(address, action, params)

/datum/netrun_remote_session/proc/window_act(address, action, list/params)
	var/datum/component/netrun_node/node = owner.refresh_route_node(SSnetrun.find_node(address))
	if(!node)
		return
	var/datum/netrun_path_tree/tree = owner.make_path_tree()
	if(owner.node_level(node, tree) < NETRUN_ACCESS_GUEST || !owner.can_route(node, tree) || owner.is_locked())
		qdel(tree)
		return
	// Команда узла - обычный сетевой запрос с задержкой и трассировкой
	if(action in node.all_command_ids())
		qdel(tree)
		owner.run_command(node, action)
		return
	// Оконное действие машины
	if(world.time < owner.next_command || !node.is_online())
		qdel(tree)
		return
	var/list/entry = owner.window_action(node, action)
	if(!entry || owner.node_level(node, tree) < (entry["access"] || NETRUN_ACCESS_GUEST))
		qdel(tree)
		owner.log_line("Действие окна не разрешено.", "bad")
		return
	var/lat = owner.latency_to(node, tree)
	qdel(tree)
	owner.next_command = world.time + max(0.5 SECONDS, lat)
	owner.log_line("[node.address]: запрос «[entry["name"]]» отправлен, ~[lat * 100] мс.")
	var/datum/netrun_request/window/packet = new(owner, node, action, params, node.network, owner.operator)
	return packet.send(max(1, lat))

/datum/netrun_console/proc/window_action(datum/component/netrun_node/node, action)
	return remote_session.window_action(node, action)

/datum/netrun_remote_session/proc/window_action(datum/component/netrun_node/node, action)
	var/atom/A = node.parent
	for(var/list/entry as anything in A.netrun_window_actions(owner, node))
		if(entry["id"] == action)
			return entry

/datum/netrun_console/proc/do_window_act(datum/component/netrun_node/node, action, list/params, datum/netrun_network/sent_network, mob/sender)
	return remote_session.do_window_act(node, action, params, sent_network, sender)

/datum/netrun_remote_session/proc/do_window_act(datum/component/netrun_node/node, action, list/params, datum/netrun_network/sent_network, mob/sender)
	if(!QDELETED(node))
		node.join_network()
	var/datum/netrun_path_tree/tree = owner.make_path_tree()
	if(QDELETED(node) || owner.is_locked() || !owner.can_route(node, tree) || !node.is_online() || node.network != sent_network || sender != owner.operator)
		qdel(tree)
		owner.log_line("Запрос окна отменён: связь изменилась.", "bad")
		return
	var/list/entry = owner.window_action(node, action)
	var/required = entry?["access"] || NETRUN_ACCESS_GUEST
	if(!entry || owner.node_level(node, tree) < required)
		qdel(tree)
		return
	// The native window action owns its execution context and may yield.
	var/illegal = owner.legit_node_level(node, tree) < required
	qdel(tree)
	var/atom/A = node.parent
	var/result = world.PushUsr(owner.operator, CALLBACK(A, TYPE_PROC_REF(/atom, netrun_window_act), owner, node, action, params))
	if(QDELETED(src) || QDELETED(owner) || QDELETED(node))
		return
	if(!isnull(result))
		owner.log_line(result)
	node.add_log("[owner.log_source()]: [entry["name"]][illegal ? " (без авторизации)" : ""].")
	node.network?.add_log("[owner.log_source()] -> [node.address]: [entry["name"]]", illegal)
	if(illegal)
		owner.add_trace(4 * node.get_security())

// MARK: Видеопотоки

/// Revalidate the source on every tick, including worn optics and disabled implants.
/datum/netrun_console/proc/watch_target()
	return remote_session.watch_target()

/datum/netrun_remote_session/proc/watch_target()
	if(QDELETED(watch_node) || QDELETED(owner.operator) || watch_viewer != owner.operator || owner.is_locked())
		return null
	if(!watch_node.is_online() || !owner.can_route(watch_node) || owner.node_level(watch_node) < NETRUN_ACCESS_USER)
		return null
	var/atom/source = watch_node.parent
	return source.netrun_view_target()

/datum/netrun_console/proc/start_watch(datum/component/netrun_node/node)
	return remote_session.start_watch(node)

/datum/netrun_remote_session/proc/start_watch(datum/component/netrun_node/node)
	if(!owner.operator?.client || QDELETED(node))
		return FALSE
	owner.stop_watch()
	watch_viewer = owner.operator
	watch_node = node
	var/atom/eye = owner.watch_target()
	if(!eye)
		owner.stop_watch()
		return FALSE
	if(owner.operator.netrun_watch_console && owner.operator.netrun_watch_console != owner)
		owner.operator.netrun_watch_console.stop_watch()
	owner.operator.netrun_watch_console = owner
	watch_eye = new(get_turf(eye), owner)
	owner.operator.reset_perspective(watch_eye)
	if(istype(owner.operator, /mob/camera/netrun_entity))
		var/mob/camera/netrun_entity/entity = owner.operator
		entity.update_vision()
	return TRUE

/datum/netrun_console/proc/stop_watch()
	return remote_session.stop_watch()

#undef NETRUN_MAX_WINDOWS
