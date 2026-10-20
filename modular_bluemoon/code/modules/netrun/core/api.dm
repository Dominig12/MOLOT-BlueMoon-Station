/**
 * Явный адаптер штатного ui_data/ui_act машины. Политика и параметры живут
 * на датуме-подтипе, а доставка, права, трассировка и журнал — в консоли.
 * Неопубликованные действия машины через сеть вызвать нельзя.
 */
/datum/netrun_api
	var/atom_type
	var/interface_name
	var/allow_emag = FALSE
	/// action id = list(name, desc, access, danger, params = list(list(id,name,type)))
	var/list/actions = list()

/datum/controller/subsystem/netrun
	var/list/datum/netrun_api/apis

/datum/controller/subsystem/netrun/proc/get_api(atom/A)
	if(!A)
		return
	if(!apis)
		apis = list()
		for(var/datum/netrun_api/path as anything in subtypesof(/datum/netrun_api))
			if(initial(path.atom_type))
				apis += new path
	var/datum/netrun_api/best
	for(var/datum/netrun_api/api as anything in apis)
		if(istype(A, api.atom_type) && (!best || ispath(api.atom_type, best.atom_type)))
			best = api
	return best

/datum/netrun_api/proc/clean_params(action, list/input)
	var/list/entry = actions[action]
	if(!entry || !islist(input))
		return
	var/list/clean = list()
	for(var/list/param as anything in entry["params"])
		var/id = param["id"]
		var/value = input[id]
		if(isnull(value))
			return
		if(!istext(value) && !isnum(value))
			return
		value = trim("[value]")
		if(!length(value) || length(value) > 256)
			return
		if(param["type"] == "number")
			var/numeric = text2num(value)
			if(isnull(numeric) || numeric < (param["min"] || 0) || numeric > (param["max"] || 100000))
				return
			value = numeric
		clean[id] = value
	return clean

/datum/netrun_api/proc/payload(atom/A, datum/netrun_console/console, datum/component/netrun_node/node)
	if(!interface_name || console.node_level(node) < NETRUN_ACCESS_USER || !console.can_route(node) || !node.is_online())
		return null
	var/list/entries = list()
	for(var/action in actions)
		var/list/entry = actions[action]
		var/list/item = entry.Copy()
		item["id"] = action
		item["params"] = entry["params"] || list()
		item["allowed"] = console.node_level(node) >= entry["access"] && !console.is_locked()
		entries += list(item)
	var/list/device_data = A.ui_static_data(console.operator) || list()
	var/list/live_data = A.ui_data(console.operator)
	for(var/key in live_data)
		device_data[key] = live_data[key]
	return list("interface" = interface_name, "data" = device_data, "actions" = entries)

/datum/netrun_console/proc/remote_payload(datum/component/netrun_node/node)
	var/datum/netrun_api/api = SSnetrun.get_api(node.parent)
	return api?.payload(node.parent, src, node)

/datum/netrun_console/proc/remote_request(address, action, list/arguments)
	var/datum/component/netrun_node/node = SSnetrun.find_node(address)
	var/datum/netrun_api/api = node ? SSnetrun.get_api(node.parent) : null
	var/list/entry = api?.actions[action]
	if(!entry || !can_route(node) || !node.is_online() || is_locked() || node_level(node) < entry["access"] || world.time < next_command)
		return FALSE
	var/list/clean = api.clean_params(action, arguments || list())
	if(isnull(clean))
		log_line("Некорректные параметры запроса [action].", "bad")
		return FALSE
	var/lat = latency_to(node)
	next_command = world.time + max(lat, 0.5 SECONDS)
	log_line("[address]: [entry["name"]] — доставка ~[lat * 100] мс.")
	if(!lat)
		return do_remote_request(node, api, action, clean, node.network, operator)
	addtimer(CALLBACK(src, PROC_REF(do_remote_request), node, api, action, clean, node.network, operator), lat)
	return TRUE

/datum/netrun_console/proc/do_remote_request(datum/component/netrun_node/node, datum/netrun_api/api, action, list/params, datum/netrun_network/sent_network, mob/sender)
	if(!QDELETED(node))
		node.join_network()
	var/list/entry = api.actions[action]
	if(QDELETED(node) || !entry || !operator || sender != operator || node.network != sent_network || is_locked() || !can_route(node) || !node.is_online() || node_level(node) < entry["access"])
		log_line("Запрос устройства отменён: связь или доступ изменились.", "bad")
		return FALSE
	var/atom/A = node.parent
	// Синтетический контекст не открывает второе окно и не меняет права моба.
	// Внутренние проверки и ограничения самой машины остаются штатными.
	var/datum/tgui/request = new(operator, A, api.interface_name)
	var/datum/ui_state/netrun_request/request_state = new(src, node)
	request.state = request_state
	request.status = UI_INTERACTIVE
	world.PushUsr(operator, CALLBACK(A, TYPE_PROC_REF(/datum, ui_act), action, params, request, request.state))
	qdel(request)
	qdel(request_state)
	var/illegal = legit_node_level(node) < entry["access"]
	node.touch()
	node.add_log("[log_source()]: [entry["name"]][illegal ? " (без авторизации)" : ""].")
	node.network?.add_log("[log_source()] -> [node.address]: [entry["name"]]", illegal)
	log_game("NETRUN API: [key_name(operator)] [action] -> [node.address] [AREACOORD(A)]")
	log_line("[node.address]: запрос передан интерфейсу устройства.", "good")
	if(illegal)
		add_trace(6 * node.get_security())
	return TRUE

/// Контекст проверенного сетевого запроса: не раздаёт привилегии или доступ мобу.
/datum/ui_state/netrun_request
	var/datum/weakref/console_ref
	var/datum/weakref/node_ref

/datum/ui_state/netrun_request/New(datum/netrun_console/console, datum/component/netrun_node/node)
	console_ref = WEAKREF(console)
	node_ref = WEAKREF(node)

/datum/ui_state/netrun_request/can_use_topic(src_object, mob/user)
	var/datum/netrun_console/console = console_ref?.resolve()
	var/datum/component/netrun_node/node = node_ref?.resolve()
	if(!console || !node || node.parent != src_object || console.operator != user || console.is_locked() || !console.can_route(node) || !node.is_online() || console.node_level(node) < NETRUN_ACCESS_USER)
		return UI_CLOSE
	return UI_INTERACTIVE

/datum/netrun_console/proc/apply_firmware_bypass(datum/component/netrun_node/node)
	var/datum/netrun_api/api = SSnetrun.get_api(node.parent)
	if(!api?.allow_emag)
		return FALSE
	var/atom/A = node.parent
	world.PushUsr(operator, CALLBACK(A, TYPE_PROC_REF(/atom, emag_act), operator))
	node.add_log("[log_source()]: атака защиты прошивки.")
	node.network?.add_log("Атака прошивки [node.address]: [log_source()].", TRUE)
	log_game("NETRUN FIRMWARE: [key_name(operator)] -> [node.address] [AREACOORD(A)]")
	log_line("Атака передана контроллеру прошивки; результат зависит от состояния машины.", "average")
	add_trace(35)
	return TRUE
