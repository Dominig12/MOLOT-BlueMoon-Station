/datum/netrun_console
	/// Если задано - состояние tgui для этой консоли (импланты, сущности)
	var/datum/ui_state/state_override
	var/tgui_title = "Сетевой терминал"

/datum/netrun_console/ui_state(mob/user)
	if(state_override)
		return state_override
	return ..()

/datum/netrun_console/ui_interact(mob/user, datum/tgui/ui)
	operator = user
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new(user, src, "NetrunTerminal", tgui_title)
		ui.open()

/datum/netrun_console/ui_data(mob/user)
	// Matrix clicks need no global discovery pass. The live delivery/finish
	// checks own fresh trees; this snapshot only describes the visible panel.
	refresh_route_node(selected_node())
	ui_routes = breach ? null : make_path_tree(TRUE)
	access_cache = user_access()
	network_level_cache = list()
	ui_node_levels = list()
	ui_legit_levels = list()
	ui_latency = list()
	ui_commands = list()
	ui_keys = list()
	ui_bonuses = list()
	ui_files = all_files()
	ui_completion_cache = list()
	. = build_ui_data(user)
	access_cache = null
	network_level_cache = null
	ui_node_levels = null
	ui_legit_levels = null
	ui_latency = null
	ui_commands = null
	ui_keys = null
	ui_bonuses = null
	ui_files = null
	ui_completion_cache = null
	QDEL_NULL(ui_routes)

/datum/netrun_console/proc/build_ui_data(mob/user)
	var/list/data = list()
	data["origin"] = origin
	data["wireless"] = wireless
	if(!breach || world.time >= ui_uplink_refresh)
		ui_uplink_value = has_uplink()
		ui_uplink_refresh = world.time + 1 SECONDS
	data["uplink"] = ui_uplink_value
	data["trace"] = round(trace, 0.1)
	data["locked"] = is_locked() ? round((lockout_until - world.time) / (1 SECONDS)) : 0
	data["can_breach"] = can_breach
	data["log"] = log
	data["jack"] = jack ? list("address" = jack.address, "name" = jack.get_name()) : null
	data["host_actions"] = host_actions()
	// Matrix clicks must not rebuild the hidden graph, global autocomplete,
	// selected-node command help or the native machine UI behind the puzzle.
	if(breach)
		data["networks"] = ui_network_catalog || list()
		data["view"] = null
		data["web"] = null
		data["map"] = null
		data["selected"] = null
		data["selected_network"] = null
		data["ping_route"] = null
		data["events"] = null
		data["waypoint"] = null
		data["storage"] = storage_payload()
		data["shard"] = shard_payload()
		data["breach"] = breach.ui_payload()
		data["entity"] = entity_data()
		data["chat"] = chat_data()
		data["cli"] = cli_payload(FALSE)
		data["windows"] = windows_payload()
		data["window"] = null
		return data
	data["file"] = file_payload()

	var/list/networks = list()
	var/list/homes = home_networks()
	for(var/network_id in SSnetrun.networks)
		var/datum/netrun_network/network = SSnetrun.networks[network_id]
		var/reachable = can_reach(network)
		if(!reachable && network.isolated)
			continue
		networks += list(list(
			"id" = network.id,
			"name" = network.name,
			"short" = network.short_name,
			"code" = network.code,
			"color" = network.color,
			"security" = network.security,
			"isolated" = network.isolated,
			"home" = (network in homes),
			"reachable" = reachable,
			"access" = network_level(network),
			"has_key" = has_key(network),
			"can_breach" = can_breach && reachable && network_level(network) < NETRUN_ACCESS_GUEST,
			"nodes" = length(network.nodes),
		))
	if(web_browsing() && has_uplink() && SSntnet.is_enabled())
		networks += list(list(
			"id" = "web",
			"name" = "NTnet — сайты",
			"short" = "WEB",
			"code" = "WEB",
			"color" = "#5bc0de",
			"security" = 0,
			"isolated" = FALSE,
			"home" = FALSE,
			"reachable" = TRUE,
			"access" = NETRUN_ACCESS_GUEST,
			"has_key" = FALSE,
			"can_breach" = FALSE,
			"nodes" = length(SSntnet.catalog),
		))
	data["networks"] = networks
	ui_network_catalog = networks

	if(viewed_network_id == "web" && web_browsing())
		data["view"] = null
		data["selected"] = null
		data["web"] = web_payload()
		data["storage"] = storage_payload()
		data["shard"] = shard_payload()
		data["breach"] = breach?.ui_payload()
		data["entity"] = entity_data()
		data["chat"] = chat_data()
		data["cli"] = cli_payload()
		data["windows"] = windows_payload()
		data["window"] = active_window ? window_payload() : null
		data["map"] = null
		data["selected_network"] = null
		data["ping_route"] = null
		data["events"] = null
		data["waypoint"] = null
		return data
	data["web"] = null

	data["map"] = map_payload()
	data["waypoint"] = waypoint_payload()
	data["view"] = null

	var/datum/component/netrun_node/node = selected_node()
	var/list/selected = null
	if(node && node_visible(node))
		var/level = node_level(node)
		selected = node.ui_entry(src)
		selected["network"] = node.network?.short_name
		selected["legit"] = legit_node_level(node)
		selected["commands"] = node.command_entries(src)
		selected["logs"] = level >= NETRUN_ACCESS_USER ? node.logs.Copy() : list()
		var/atom/A = node.parent
		selected["status"] = level >= NETRUN_ACCESS_USER ? A.netrun_status() : list()
		if(node.files && level >= NETRUN_ACCESS_USER)
			var/list/files = list()
			for(var/datum/netrun_file/file as anything in node.files)
				files += list(file.ui_entry())
			selected["files"] = files
			selected["storage"] = list("used" = node.used_storage(), "capacity" = node.storage_capacity)
	data["selected"] = selected

	var/datum/netrun_network/selnet = SSnetrun.networks[selected_network]
	if(selnet)
		var/snlevel = network_level(selnet)
		data["selected_network"] = list(
			"id" = selnet.id,
			"code" = selnet.code,
			"name" = selnet.name,
			"color" = selnet.color,
			"security" = selnet.security,
			"access" = snlevel,
			"has_key" = has_key(selnet),
			"can_breach" = can_breach && snlevel < NETRUN_ACCESS_GUEST,
			"log" = snlevel >= NETRUN_ACCESS_USER ? selnet.logs.Copy(max(1, length(selnet.logs) - 14)) : list(),
		)
	else
		data["selected_network"] = null

	data["storage"] = storage_payload()
	data["shard"] = shard_payload()

	data["breach"] = breach?.ui_payload()
	data["entity"] = entity_data()
	data["chat"] = chat_data()
	data["cli"] = cli_payload()
	data["windows"] = windows_payload()
	data["window"] = active_window ? window_payload() : null
	data["ping_route"] = (ping_route && world.time - ping_at < 6 SECONDS) ? ping_route : null
	data["events"] = SSnetrun.recent_events()
	return data

/// Дополнительные кнопки носителя (выдернуть провод, вынуть шард, вернуться в тело...)
/datum/netrun_console/proc/host_actions()
	. = list()
	if(jack)
		. += list(list("id" = "unjack", "name" = "Выдернуть провод", "icon" = "plug-circle-xmark"))
	if(shard)
		. += list(list("id" = "eject_shard", "name" = "Извлечь шард", "icon" = "eject"))

/// Данные для режима сущности - переопределяется у консоли сущности
/datum/netrun_console/proc/entity_data()
	return null

// MARK: Node neighborhoods and graph navigation

/datum/netrun_console/proc/map_focus_node()
	var/datum/component/netrun_node/selected = selected_node()
	if(selected && node_visible(selected))
		return selected
	return route_source()

/datum/netrun_console/proc/map_payload()
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	var/datum/component/netrun_node/focus = map_focus_node()
	var/depth = max(0, map_depth) + (daemon_bonus("mapper") ? 2 : 0)
	var/list/distances = list()
	var/list/queue = list()
	if(focus)
		distances[focus.address] = 0
		queue += focus.address
	for(var/i = 1, i <= length(queue), i++)
		var/address = queue[i]
		if(distances[address] >= depth)
			continue
		for(var/neighbor in graph.neighbors(address))
			if(!isnull(distances[neighbor]))
				continue
			distances[neighbor] = distances[address] + 1
			queue += neighbor
	var/list/shown = list()
	var/list/map_nodes = list()
	var/list/networks = list()
	var/reveal_all = daemon_bonus("mapper")
	for(var/address in queue)
		var/datum/component/netrun_node/node = graph.nodes[address]
		if(QDELETED(node) || !can_route(node) || (!reveal_all && !node_visible(node)))
			continue
		var/list/entry = node.ui_entry(src)
		entry["network"] = node.network?.id
		entry["sector"] = node.binding_sector
		entry["neighbor_count"] = length(graph.neighbors(address))
		map_nodes += list(entry)
		shown[address] = TRUE
		if(node.network)
			networks[node.network.id] = node.network
	var/list/edges = list()
	var/list/edge_ids = list()
	for(var/address in shown)
		for(var/neighbor in graph.neighbors(address))
			if(!shown[neighbor])
				continue
			var/list/edge = graph.edge_between(address, neighbor)
			if(!edge || edge_ids[edge["id"]])
				continue
			edge_ids[edge["id"]] = TRUE
			var/list/entry = edge.Copy()
			entry["online"] = netrun_link_available(graph.nodes[address], graph.nodes[neighbor])
			edges += list(entry)
	var/list/gateways = list()
	for(var/network_id in networks)
		var/datum/netrun_network/network = networks[network_id]
		var/level = network_level(network)
		gateways += list(list(
			"id" = network.id,
			"code" = network.code,
			"name" = network.name,
			"color" = network.color,
			"security" = network.security,
			"access" = level,
			"has_key" = has_key(network),
			"can_breach" = can_breach && level < NETRUN_ACCESS_GUEST,
		))
	return list(
		"nodes" = map_nodes,
		"edges" = edges,
		"gateways" = gateways,
		"focus" = focus?.address,
		"depth" = depth,
		"revision" = graph.revision,
		"route" = map_route_payload(selected_node() || focus),
	)

/// The client receives the selected route, not the whole server routing table.
/datum/netrun_console/proc/map_route_payload(datum/component/netrun_node/target)
	if(!target)
		return null
	var/datum/netrun_path_tree/tree = path_tree()
	var/list/addresses = tree.addresses_to(target.address)
	var/datum/netrun_route/route = route_to(target, tree)
	. = list(
		"route" = addresses,
		"hops" = max(0, length(addresses) - 1),
		"latency" = route.latency * 100,
		"revision" = tree.revision,
		"reachable" = !!length(addresses),
	)
	qdel(route)
	release_path_tree(tree)

/// Network travel uses hops and node addresses, independently of physical tile distance.
/datum/netrun_console/proc/waypoint_payload()
	if(!waypoint_address)
		return null
	var/datum/component/netrun_node/node = SSnetrun.find_node(waypoint_address)
	if(QDELETED(node) || QDELETED(node.parent))
		waypoint_address = null
		return null
	var/datum/netrun_route/route = route_to(node)
	var/list/addresses = list()
	for(var/list/hop as anything in route.hops)
		addresses += hop["ref"]
	. = list(
		"address" = node.address,
		"name" = node.get_name(),
		"type" = node.node_type,
		"reachable" = length(addresses) > 0,
		"hops" = max(0, length(addresses) - 1),
		"route" = addresses,
		"next" = length(addresses) > 1 ? addresses[2] : null,
	)
	qdel(route)

/datum/netrun_console/proc/storage_payload()
	var/list/local = list()
	for(var/datum/netrun_file/file as anything in storage)
		local += list(file.ui_entry(selected_file_uid))
	return list("files" = local, "used" = netrun_storage_used(storage), "capacity" = storage_capacity)

/datum/netrun_console/proc/shard_payload()
	if(!shard)
		return null
	var/list/shard_files = list()
	for(var/datum/netrun_file/file as anything in shard.files)
		shard_files += list(file.ui_entry(selected_file_uid))
	return list("name" = shard.name, "files" = shard_files, "used" = netrun_storage_used(shard.files), "capacity" = shard.capacity)

// MARK: Мост «сайты NTnet в терминале» (только чтение, данные из SSntnet)

/// Можно ли с этой точки просматривать сайты NTnet
/datum/netrun_console/proc/web_browsing()
	return origin != NETRUN_ORIGIN_CIRCUIT

/datum/netrun_console/proc/web_payload()
	SSntnet.last_used = world.time
	SSntnet.refresh_index()
	var/list/sites = list()
	for(var/site_id in SSntnet.sites)
		var/list/site = SSntnet.sites[site_id]
		sites += list(list("id" = site_id, "domain" = site["domain"], "title" = site["title"]))
	var/list/payload = list(
		"available" = SSntnet.available,
		"sites" = sites,
		"site" = null,
		"page" = null,
	)
	var/list/site = web_site_id ? SSntnet.sites[web_site_id] : null
	if(!site)
		web_site_id = null
		web_slug = null
		return payload
	var/list/pages = list()
	for(var/list/page as anything in site["pages"])
		pages += list(list("slug" = page["slug"], "title" = page["title"]))
	payload["site"] = list("id" = web_site_id, "domain" = site["domain"], "title" = site["title"], "pages" = pages)
	if(!web_slug)
		return payload
	SSntnet.request_page(web_site_id, web_slug)
	var/cache_key = json_encode(list(web_site_id, web_slug))
	var/list/cached = SSntnet.pages[cache_key]
	payload["page"] = list(
		"slug" = web_slug,
		"title" = cached ? cached["title"] : web_slug,
		"text" = cached ? cached["text"] : null,
		"loading" = !cached && !SSntnet.page_failed(web_site_id, web_slug),
		"failed" = SSntnet.page_failed(web_site_id, web_slug),
	)
	return payload

/datum/netrun_console/ui_act(action, list/params, datum/tgui/ui, datum/ui_state/state)
	. = ..()
	if(.)
		return
	operator = ui.user
	if(file_act(action, params, ui.user))
		return TRUE
	switch(action)
		if("view_network")
			active_window = null
			if(params["id"] == "web" && web_browsing())
				viewed_network_id = "web"
			else
				viewed_network_id = null
			return TRUE
		if("select_network")
			var/datum/netrun_network/network = SSnetrun.networks[params["id"]]
			if(network && can_reach(network))
				selected_network = network.id
				selected_address = null
			return TRUE
		if("set_waypoint")
			var/datum/component/netrun_node/node = SSnetrun.find_node(params["address"])
			if(node && node_visible(node))
				waypoint_address = node.address
				log_line("Пеленг на [node.get_name()] [node.address].", "label")
			return TRUE
		if("clear_waypoint")
			waypoint_address = null
			return TRUE
		if("select")
			var/datum/component/netrun_node/node = SSnetrun.find_node(params["address"])
			if(node && node_visible(node))
				selected_address = node.address
				selected_network = null
			return TRUE
		if("window_open")
			open_window(params["address"])
			return TRUE
		if("window_close")
			close_window(params["address"])
			return TRUE
		if("window_focus")
			if(params["address"] in windows)
				active_window = params["address"]
				selected_address = active_window
				selected_network = null
			return TRUE
		if("remote_act")
			remote_request(params["address"], params["request"], params["arguments"])
			return TRUE
		if("window_act")
			window_act(params["address"], params["waction"], params)
			return TRUE
		if("command")
			run_command(selected_node(), params["id"])
			return TRUE
		if("breach")
			start_breach(params["kind"] == "network" ? "network" : "node", params["id"])
			return TRUE
		if("breach_pick")
			breach?.choose(text2num("[params["index"]]"))
			return TRUE
		if("breach_abort")
			breach?.finish()
			return TRUE
		if("download")
			transfer_from_node(params["uid"], !!params["to_shard"])
			return TRUE
		if("upload")
			transfer_to_node(params["uid"])
			return TRUE
		if("delete_remote")
			delete_from_node(params["uid"])
			return TRUE
		if("delete_local")
			var/datum/netrun_file/file = find_local_file(params["uid"])
			if(file)
				delete_local_file(file)
			return TRUE
		if("read")
			read_file(ui.user, params["uid"])
			return TRUE
		if("cli")
			cli(params["text"])
			return TRUE
		if("chat_send")
			chat_send(params["text"])
			return TRUE
		if("set_handle")
			var/new_handle = reject_bad_name(params["handle"], allow_numbers = TRUE)
			if(new_handle && origin != NETRUN_ORIGIN_ENTITY)
				handle = copytext_char(new_handle, 1, 24)
			return TRUE
		if("web_site")
			if(SSntnet.sites[params["id"]])
				web_site_id = params["id"]
				web_slug = SSntnet.has_page(web_site_id, "index") ? "index" : null
			return TRUE
		if("web_page")
			if(web_site_id && SSntnet.has_page(web_site_id, params["slug"]))
				web_slug = params["slug"]
			return TRUE
		if("web_back")
			if(web_slug)
				web_slug = null
			else
				web_site_id = null
			return TRUE
		else
			return host_act(action, params, ui.user)

/// Кнопки носителя
/datum/netrun_console/proc/host_act(action, list/params, mob/user)
	switch(action)
		if("unjack")
			set_jack(null)
			log_line("Провод отключён.")
			return TRUE
		if("eject_shard")
			eject_shard(user)
			return TRUE

/datum/netrun_console/proc/insert_shard(obj/item/netrun_shard/new_shard, mob/user)
	if(shard)
		to_chat(user, span_warning("Разъём уже занят."))
		return FALSE
	if(user && !user.transferItemToLoc(new_shard, host))
		return FALSE
	shard = new_shard
	log_line("Шард подключён: [shard.name].")
	return TRUE

/datum/netrun_console/proc/eject_shard(mob/user)
	if(!shard)
		return
	var/obj/item/netrun_shard/old = shard
	shard = null
	old.forceMove(get_turf(host))
	if(user && isliving(user))
		user.put_in_hands(old)
	log_line("Шард извлечён.")

// MARK: Файловые операции

/datum/netrun_console/proc/remote_file(datum/component/netrun_node/node, uid)
	for(var/datum/netrun_file/file as anything in node?.files)
		if(file.uid == uid)
			return file

/datum/netrun_console/proc/transfer_from_node(uid, to_shard, datum/component/netrun_node/node, delivered = FALSE)
	if(!delivered)
		return queue_file_request("download", selected_node(), uid, to_shard)
	if(!node?.files || node_level(node) < NETRUN_ACCESS_USER || !node.is_online(node != jack) || !can_route(node))
		return
	var/datum/netrun_file/file = remote_file(node, uid)
	if(!file)
		return
	var/datum/netrun_file/copy = file.copy()
	if(!store_file(copy, to_shard))
		qdel(copy)
		log_line("Недостаточно места.", "bad")
		return
	node.touch()
	node.add_log("[log_source()]: скачан [file.name].")
	log_line("Скачано: [file.name].", "good")
	var/illegal = legit_node_level(node) < NETRUN_ACCESS_USER
	node.network?.add_log("[log_source()] скачал [file.name] с [node.address][illegal ? " (без авторизации)" : ""]", illegal)
	if(illegal)
		add_trace(4 * node.get_security())

/datum/netrun_console/proc/transfer_to_node(uid, datum/component/netrun_node/node, delivered = FALSE)
	if(!delivered)
		return queue_file_request("upload", selected_node(), uid)
	if(!node?.files || node_level(node) < NETRUN_ACCESS_USER || !node.is_online(node != jack) || !can_route(node))
		return
	var/datum/netrun_file/file = find_local_file(uid)
	if(!file)
		return
	if(node.used_storage() + file.size > node.storage_capacity)
		log_line("На узле нет места.", "bad")
		return
	node.files += file.copy()
	node.touch()
	node.add_log("[log_source()]: загружен [file.name].")
	log_line("Загружено: [file.name].", "good")
	var/illegal = legit_node_level(node) < NETRUN_ACCESS_USER
	node.network?.add_log("[log_source()] загрузил [file.name] на [node.address]")
	if(illegal)
		add_trace(3 * node.get_security())

/datum/netrun_console/proc/delete_from_node(uid, datum/component/netrun_node/node, delivered = FALSE)
	if(!delivered)
		return queue_file_request("delete", selected_node(), uid)
	if(!node?.files || node_level(node) < NETRUN_ACCESS_ROOT || !node.is_online(node != jack) || !can_route(node))
		return
	var/datum/netrun_file/file = remote_file(node, uid)
	if(!file)
		return
	node.files -= file
	log_line("Удалено с узла: [file.name].", "average")
	node.add_log("[log_source()]: удалён [file.name].")
	node.network?.add_log("[log_source()] удалил [file.name] с [node.address]")
	if(legit_node_level(node) < NETRUN_ACCESS_ROOT)
		add_trace(5 * node.get_security())
	qdel(file)

/// Один путь доставки файлов для кнопок, CLI и будущих клиентов.
/datum/netrun_console/proc/queue_file_request(action, datum/component/netrun_node/node, uid, to_shard = FALSE)
	var/required = action == "delete" ? NETRUN_ACCESS_ROOT : NETRUN_ACCESS_USER
	if(!node?.files || !can_route(node) || node_level(node) < required || !node.is_online(node != jack) || is_locked() || world.time < next_command)
		return FALSE
	var/lat = latency_to(node)
	next_command = world.time + max(lat, 0.5 SECONDS)
	if(!lat)
		return deliver_file_request(action, node, uid, to_shard, node.network, operator)
	log_line("[node.address]: файловый запрос отправлен, ~[lat * 100] мс.")
	addtimer(CALLBACK(src, PROC_REF(deliver_file_request), action, node, uid, to_shard, node.network, operator), lat)
	return TRUE

/datum/netrun_console/proc/deliver_file_request(action, datum/component/netrun_node/node, uid, to_shard, datum/netrun_network/sent_network, mob/sender)
	if(QDELETED(node))
		return FALSE
	node.join_network()
	if(sender != operator || node.network != sent_network || is_locked() || !can_route(node) || !node.is_online(node != jack))
		log_line("Файловый запрос отменён: соединение изменилось.", "bad")
		return FALSE
	switch(action)
		if("download")
			transfer_from_node(uid, to_shard, node, TRUE)
		if("upload")
			transfer_to_node(uid, node, TRUE)
		if("delete")
			delete_from_node(uid, node, TRUE)
		if("read")
			if(node_level(node) < NETRUN_ACCESS_USER)
				return FALSE
			var/datum/netrun_file/file = remote_file(node, uid)
			if(!file)
				return FALSE
			file.show(operator)
			node.add_log("[log_source()]: прочитан [file.name].")
			if(legit_node_level(node) < NETRUN_ACCESS_USER)
				add_trace(2 * node.get_security())
	return TRUE

/datum/netrun_console/proc/read_file(mob/user, uid)
	var/datum/netrun_file/file = find_local_file(uid)
	if(!file)
		return queue_file_request("read", selected_node(), uid)
	file?.show(user)

// MARK: Командная строка

