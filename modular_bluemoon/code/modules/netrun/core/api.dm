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
	/// Adapter selection depends only on the atom type. A wrapper also caches no match.
	var/list/api_type_cache

/datum/controller/subsystem/netrun/proc/get_api(atom/A)
	if(!A)
		return
	if(!apis)
		apis = list()
		api_type_cache = list()
		for(var/datum/netrun_api/path as anything in subtypesof(/datum/netrun_api))
			if(initial(path.atom_type))
				apis += new path
	if(!api_type_cache)
		api_type_cache = list()
	var/list/cached = api_type_cache[A.type]
	if(cached)
		return cached[1]
	var/datum/netrun_api/best
	for(var/datum/netrun_api/api as anything in apis)
		if(istype(A, api.atom_type) && (!best || ispath(api.atom_type, best.atom_type)))
			best = api
	api_type_cache[A.type] = list(best)
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
	var/datum/component/netrun_node/node = refresh_route_node(SSnetrun.find_node(address))
	var/datum/netrun_api/api = node ? SSnetrun.get_api(node.parent) : null
	var/list/entry = api?.actions[action]
	if(!entry)
		return FALSE
	var/datum/netrun_path_tree/tree = make_path_tree()
	if(!can_route(node, tree) || !node.is_online() || is_locked() || node_level(node, tree) < entry["access"] || world.time < next_command)
		qdel(tree)
		return FALSE
	var/list/clean = api.clean_params(action, arguments || list())
	if(isnull(clean))
		qdel(tree)
		log_line("Некорректные параметры запроса [action].", "bad")
		return FALSE
	var/lat = latency_to(node, tree)
	qdel(tree)
	next_command = world.time + max(lat, 0.5 SECONDS)
	log_line("[address]: [entry["name"]] — доставка ~[lat * 100] мс.")
	var/datum/netrun_request/remote/request = new(src, node, api, action, clean, node.network, operator)
	return request.send(lat)

/datum/netrun_console/proc/do_remote_request(datum/component/netrun_node/node, datum/netrun_api/api, action, list/params, datum/netrun_network/sent_network, mob/sender)
	var/datum/netrun_request/remote/request = new(src, node, api, action, params, sent_network, sender)
	return request.send()

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
	if(!console || !node || node.parent != src_object || console.operator != user || console.is_locked() || !node.is_online())
		return UI_CLOSE
	node.join_network()
	var/datum/netrun_path_tree/tree = console.make_path_tree()
	var/allowed = console.can_route(node, tree) && console.node_level(node, tree) >= NETRUN_ACCESS_USER
	qdel(tree)
	return allowed ? UI_INTERACTIVE : UI_CLOSE

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
