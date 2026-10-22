/datum/netrun_console
	/// Если задано - состояние tgui для этой консоли (импланты, сущности)
	var/datum/ui_state/state_override
	var/tgui_title = "Сетевой терминал"
	var/list/ui_catalog_context

/datum/netrun_console/ui_state(mob/user)
	if(state_override)
		return state_override
	return ..()

/datum/netrun_console/ui_interact(mob/user, datum/tgui/ui)
	operator = user
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new(user, src, "NetrunTerminal", tgui_title)
		// Event-driven: SSnetrun pushes updates through flush_ui only when state actually changes
		// or a live countdown is ticking, instead of tgui re-serializing the graph every tick.
		ui.set_autoupdate(FALSE)
		ui.open()

/datum/netrun_console/ui_data(mob/user, datum/ui_source)
	note_ui_activity()
	if(user)
		if(operator != user)
			ui_network_catalog = null
		operator = user
	// Matrix clicks need no global discovery pass. The live delivery/finish
	// checks own fresh trees; this snapshot only describes the visible panel.
	refresh_route_node(selected_node())
	if(!intrusion.breach || (workspace_view in list("map", "files", "pinned", "terminal", "web")))
		ui_routes = acquire_ui_routes()
	else
		ui_routes = null
		ui_routes_borrowed = FALSE
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
	ui_projection_cache = null
	ui_selected_resolved = FALSE
	ui_serializing = TRUE
	var/list/session
	if(user)
		ui_source = ui_source || src
		session = map_view.wire_session(user, ui_source, SStgui.get_open_ui(user, ui_source))
	. = build_ui_data(user, ui_source, session)
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
	ui_projection_cache = null
	ui_selected_node_cache = null
	ui_selected_resolved = FALSE
	ui_serializing = FALSE
	if(ui_routes_borrowed)
		// Borrowed the server's shared routing table; never destroy it on teardown.
		ui_routes = null
		ui_routes_borrowed = FALSE
	else
		QDEL_NULL(ui_routes)

/datum/netrun_console/ui_static_data(mob/user)
	if(user)
		operator = user
	return list("cli" = cli_payload(workspace_view == "terminal"), "networks" = network_catalog())

/datum/netrun_console/proc/build_ui_data(mob/user, datum/ui_source, list/session)
	var/list/data = list()
	data["origin"] = origin
	data["workspace_view"] = workspace_view
	data["wireless"] = connection.wireless
	if(!intrusion.breach || world.time >= ui_uplink_refresh)
		ui_uplink_value = has_uplink()
		ui_uplink_refresh = world.time + 1 SECONDS
	data["uplink"] = ui_uplink_value
	data["trace"] = round(intrusion.trace, 0.1)
	data["locked"] = is_locked() ? round((intrusion.lockout_until - world.time) / (1 SECONDS)) : 0
	data["can_breach"] = intrusion.can_breach
	data["can_autobreach"] = intrusion.can_breach && !!daemon_bonus("autobreach")
	data["log"] = log
	data["jack"] = connection.jack ? list("address" = connection.jack.address, "name" = connection.jack.get_name()) : null
	data["host_actions"] = host_actions()
	data["file"] = file_payload()
	// Matrix clicks must not rebuild the hidden graph, global autocomplete,
	// selected-node command help or the native machine UI behind the puzzle.
	if(intrusion.breach && !(workspace_view in list("map", "files", "pinned", "terminal", "web")))
		append_network_catalog(data, session, FALSE)
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
		data["breach"] = intrusion.breach.ui_payload()
		data["entity"] = entity_data()
		data["combat"] = combat_payload()
		data["chat"] = chat_data()
		append_cli_payload(data, FALSE, session)
		data["windows"] = windows_payload()
		data["window"] = null
		return data

	append_network_catalog(data, session)

	if(workspace_view == "web" && web_browsing())
		data["view"] = null
		data["selected"] = null
		data["web"] = web_payload()
		data["storage"] = storage_payload()
		data["shard"] = shard_payload()
		data["breach"] = intrusion.breach?.ui_payload()
		data["entity"] = entity_data()
		data["combat"] = combat_payload()
		data["chat"] = chat_data()
		append_cli_payload(data, FALSE, session)
		data["windows"] = windows_payload()
		data["window"] = null
		data["map"] = null
		data["selected_network"] = null
		data["ping_route"] = null
		data["events"] = null
		data["waypoint"] = null
		return data
	data["web"] = null

	data["map"] = workspace_view == "map" ? map_payload(user, ui_source, session) : null
	data["waypoint"] = workspace_view == "map" ? waypoint_payload() : null
	data["view"] = null

	var/datum/component/netrun_node/node = selected_node()
	var/list/selected = null
	if((workspace_view in list("map", "files", "pinned")) && node && node_visible(node))
		var/level = node_level(node)
		selected = node.ui_entry(src)
		selected["network"] = node.network?.short_name
		selected["legit"] = legit_node_level(node)
		selected["commands"] = node.command_entries(src)
		// APC/шлюз - это точка входа в ЛВС: отдаём доступ и взлом сети прямо на узле, без верхней панели.
		if((node.node_type in list(NETRUN_NODE_APC, NETRUN_NODE_GATEWAY)) && node.network)
			var/datum/netrun_network/lan = node.network
			var/lan_level = network_level(lan)
			selected["lan"] = list(
				"id" = lan.id,
				"code" = lan.code,
				"name" = lan.name,
				"color" = lan.color,
				"security" = lan.security,
				"access" = lan_level,
				"has_key" = has_key(lan),
				"can_breach" = intrusion.can_breach && lan_level < NETRUN_ACCESS_GUEST,
			)
		selected["logs"] = level >= NETRUN_ACCESS_USER ? node.logs.Copy() : list()
		var/atom/A = node.parent
		selected["status"] = level >= NETRUN_ACCESS_USER ? A.netrun_status() : list()
		if(node.file_store && level >= NETRUN_ACCESS_USER)
			var/list/files = list()
			for(var/datum/netrun_file/file as anything in node.file_store.files)
				files += list(file.ui_entry())
			selected["files"] = files
			selected["storage"] = list("used" = node.used_storage(), "capacity" = node.file_store?.capacity)
	data["selected"] = selected

	var/datum/netrun_network/selnet = SSnetrun.networks[map_view.selected_network]
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
			"can_breach" = intrusion.can_breach && snlevel < NETRUN_ACCESS_GUEST,
			"log" = snlevel >= NETRUN_ACCESS_USER ? selnet.logs.Copy(max(1, length(selnet.logs) - 14)) : list(),
		)
	else
		data["selected_network"] = null

	data["storage"] = storage_payload()
	data["shard"] = shard_payload()

	data["breach"] = intrusion.breach?.ui_payload()
	data["entity"] = entity_data()
	data["combat"] = combat_payload()
	data["chat"] = chat_data()
	append_cli_payload(data, workspace_view == "terminal", session)
	data["windows"] = windows_payload()
	data["window"] = workspace_view == "pinned" && remote_session.active_window ? window_payload() : null
	data["ping_route"] = (map_view.ping_route && world.time - map_view.ping_at < 6 SECONDS) ? map_view.ping_route : null
	data["events"] = SSnetrun.recent_events()
	data["search"] = workspace_view == "map" ? search_payload() : null
	return data

/// Поиск по всей сети: находит достижимые узлы по имени/адресу, чтобы проложить
/// к ним маршрут даже если они ещё не открыты на карте. Доступ к узлу этим не выдаётся.
/datum/netrun_console/proc/search_payload()
	if(!map_view.search_query)
		return null
	var/query = lowertext(map_view.search_query)
	. = list()
	var/count = 0
	for(var/address in SSnetrun.nodes_by_address)
		if(count >= 24)
			break
		var/datum/component/netrun_node/node = SSnetrun.nodes_by_address[address]
		if(QDELETED(node) || QDELETED(node.parent))
			continue
		if(!findtext(lowertext(node.get_name()), query) && !findtext(lowertext(address), query))
			continue
		if(!can_route(node))
			continue
		count++
		. += list(list(
			"address" = node.address,
			"name" = node.get_name(),
			"type" = node.node_type,
			"network" = node.network?.short_name,
			"online" = node.is_online(),
			"visible" = node_visible(node),
		))

/// Дополнительные кнопки носителя (выдернуть провод, вынуть шард, вернуться в тело...)
/datum/netrun_console/proc/host_actions()
	. = list()
	if(connection.jack)
		. += list(list("id" = "unjack", "name" = "Выдернуть провод", "icon" = "plug-circle-xmark"))
	if(inventory.shard)
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

/datum/netrun_console/proc/map_payload(mob/user, datum/ui_source, list/session)
	return map_view.wire_payload(user, ui_source, session)

/datum/netrun_console/proc/route_reveal_addresses(datum/component/netrun_node/focus)
	. = list()
	var/datum/component/netrun_node/waypoint = map_view.waypoint_address ? SSnetrun.find_node(map_view.waypoint_address) : null
	if(waypoint && can_route(waypoint))
		var/datum/netrun_route/route = route_to(waypoint)
		for(var/list/hop as anything in route.hops)
			. += hop["ref"]
		qdel(route)
	var/datum/component/netrun_node/selected = selected_node() || focus
	if(selected && can_route(selected))
		var/datum/netrun_route/route = route_to(selected)
		for(var/list/hop as anything in route.hops)
			. += hop["ref"]
		qdel(route)

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
	if(!map_view.waypoint_address)
		return null
	var/datum/component/netrun_node/node = SSnetrun.find_node(map_view.waypoint_address)
	if(QDELETED(node) || QDELETED(node.parent))
		map_view.waypoint_address = null
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
	for(var/datum/netrun_file/file as anything in inventory.local_store.files)
		local += list(file.ui_entry(inventory.selected_file_uid))
	return list("files" = local, "used" = netrun_storage_used(inventory.local_store.files), "capacity" = inventory.local_store.capacity)

/datum/netrun_console/proc/shard_payload()
	if(!inventory.shard)
		return null
	var/list/shard_files = list()
	for(var/datum/netrun_file/file as anything in inventory.shard.file_store.files)
		shard_files += list(file.ui_entry(inventory.selected_file_uid))
	return list("name" = inventory.shard.name, "files" = shard_files, "used" = netrun_storage_used(inventory.shard.file_store.files), "capacity" = inventory.shard.file_store.capacity)

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
	var/list/site = remote_session.web_site_id ? SSntnet.sites[remote_session.web_site_id] : null
	if(!site)
		remote_session.web_site_id = null
		remote_session.web_slug = null
		return payload
	var/list/pages = list()
	for(var/list/page as anything in site["pages"])
		pages += list(list("slug" = page["slug"], "title" = page["title"]))
	payload["site"] = list("id" = remote_session.web_site_id, "domain" = site["domain"], "title" = site["title"], "pages" = pages)
	if(!remote_session.web_slug)
		return payload
	SSntnet.request_page(remote_session.web_site_id, remote_session.web_slug)
	var/cache_key = json_encode(list(remote_session.web_site_id, remote_session.web_slug))
	var/list/cached = SSntnet.pages[cache_key]
	payload["page"] = list(
		"slug" = remote_session.web_slug,
		"title" = cached ? cached["title"] : remote_session.web_slug,
		"text" = cached ? cached["text"] : null,
		"loading" = !cached && !SSntnet.page_failed(remote_session.web_site_id, remote_session.web_slug),
		"failed" = SSntnet.page_failed(remote_session.web_site_id, remote_session.web_slug),
	)
	return payload

/datum/netrun_console/ui_act(action, list/params, datum/tgui/ui, datum/ui_state/state)
	note_ui_activity()
	invalidate_ui()
	. = ..()
	if(.)
		return
	operator = ui.user
	if(action == "map_resync")
		map_view.resync(ui)
		return TRUE
	if(file_act(action, params, ui.user))
		return TRUE
	switch(action)
		if("workspace_view")
			var/page = params["page"]
			if(page in list("terminal", "map", "files", "pinned", "combat", "breach", "web"))
				if(page != "web" || web_browsing())
					workspace_view = page
					map_view.viewed_network_id = page == "web" ? "web" : null
			return TRUE
		if("map_sector")
			map_view.select_sector(params["id"], params["z"])
			return TRUE
		if("relay_hop")
			if(origin == NETRUN_ORIGIN_ENTITY && istype(host, /mob/camera/netrun_entity))
				var/mob/camera/netrun_entity/entity = host
				var/datum/component/netrun_node/target = SSnetrun.find_node(params["address"])
				if(SSnetrun.get_topology().is_relay(entity.host_node) && SSnetrun.get_topology().is_relay(target))
					entity.relay_hop(target)
			return TRUE
		if("view_network")
			if(params["id"] == "web" && web_browsing())
				workspace_view = "web"
				map_view.viewed_network_id = "web"
			else
				workspace_view = "map"
				map_view.viewed_network_id = null
			return TRUE
		if("select_network")
			var/datum/netrun_network/network = SSnetrun.networks[params["id"]]
			if(network && can_reach(network))
				map_view.selected_network = network.id
				map_view.selected_address = null
			return TRUE
		if("set_waypoint")
			var/datum/component/netrun_node/node = SSnetrun.find_node(params["address"])
			// Пеленг можно ставить на любой достижимый узел, даже ещё не открытый на карте.
			if(node && (node_visible(node) || can_route(node)))
				map_view.waypoint_address = node.address
				log_line("Пеленг на [node.get_name()] [node.address].", "label")
			else
				log_line("К этому узлу нет маршрута для пеленга.", "bad")
			return TRUE
		if("clear_waypoint")
			map_view.waypoint_address = null
			return TRUE
		if("focus_host")
			var/datum/component/netrun_node/here = route_source()
			if(here)
				map_view.selected_address = here.address
				map_view.selected_network = null
				map_view.follow_source()
			return TRUE
		if("search")
			var/text = params["text"]
			map_view.search_query = istext(text) ? trim(copytext_char(sanitize(text), 1, 40)) : null
			if(!length(map_view.search_query))
				map_view.search_query = null
			return TRUE
		if("select")
			var/datum/component/netrun_node/node = SSnetrun.find_node(params["address"])
			if(node && node_visible(node))
				map_view.selected_address = node.address
				map_view.selected_network = null
				var/turf/position = get_turf(node.parent)
				if(node.binding_sector != map_view.active_sector || position?.z != map_view.active_z)
					map_view.select_sector(node.binding_sector, position?.z)
			return TRUE
		if("window_open")
			open_window(params["address"])
			return TRUE
		if("window_close")
			close_window(params["address"])
			return TRUE
		if("window_focus")
			if(params["address"] in remote_session.windows)
				workspace_view = "pinned"
				remote_session.active_window = params["address"]
				map_view.selected_address = remote_session.active_window
				map_view.selected_network = null
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
			start_breach(params["kind"] == "network" ? "network" : "node", params["id"], !!params["automatic"])
			return TRUE
		if("recover_salvage")
			recover_salvage(params["uid"])
			return TRUE
		if("breach_pick")
			intrusion.breach?.choose(text2num("[params["index"]]"))
			return TRUE
		if("breach_abort")
			intrusion.breach?.finish()
			return TRUE
		if("program_use")
			program_use(params["uid"], params["target"])
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
				remote_session.web_site_id = params["id"]
				remote_session.web_slug = SSntnet.has_page(remote_session.web_site_id, "index") ? "index" : null
			return TRUE
		if("web_page")
			if(remote_session.web_site_id && SSntnet.has_page(remote_session.web_site_id, params["slug"]))
				remote_session.web_slug = params["slug"]
			return TRUE
		if("web_back")
			if(remote_session.web_slug)
				remote_session.web_slug = null
			else
				remote_session.web_site_id = null
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
	if(inventory.shard)
		to_chat(user, span_warning("Разъём уже занят."))
		return FALSE
	if(user && !user.transferItemToLoc(new_shard, host))
		return FALSE
	inventory.set_shard(new_shard)
	log_line("Шард подключён: [inventory.shard.name].")
	return TRUE

/datum/netrun_console/proc/eject_shard(mob/user)
	if(!inventory.shard)
		return
	var/obj/item/netrun_shard/old = inventory.shard
	inventory.set_shard(null)
	old.forceMove(get_turf(host))
	if(user && isliving(user))
		user.put_in_hands(old)
	log_line("Шард извлечён.")

// MARK: Файловые операции

/datum/netrun_console/proc/remote_file(datum/component/netrun_node/node, uid)
	for(var/datum/netrun_file/file as anything in node?.file_store?.files)
		if(file.uid == uid)
			return file

/datum/netrun_console/proc/transfer_from_node(uid, to_shard, datum/component/netrun_node/node, delivered = FALSE)
	if(!delivered)
		return queue_file_request("download", selected_node(), uid, to_shard)
	if(!node?.file_store?.files || node_level(node) < NETRUN_ACCESS_USER || !node.is_online(node != connection.jack) || !can_route(node))
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
	if(!node?.file_store?.files || node_level(node) < NETRUN_ACCESS_USER || !node.is_online(node != connection.jack) || !can_route(node))
		return
	var/datum/netrun_file/file = find_local_file(uid)
	if(!file)
		return
	if(node.used_storage() + file.size > node.file_store?.capacity)
		log_line("На узле нет места.", "bad")
		return
	node.file_store.insert(file.copy())
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
	if(!node?.file_store?.files || node_level(node) < NETRUN_ACCESS_ROOT || !node.is_online(node != connection.jack) || !can_route(node))
		return
	var/datum/netrun_file/file = remote_file(node, uid)
	if(!file)
		return
	node.file_store.remove(file)
	log_line("Удалено с узла: [file.name].", "average")
	node.add_log("[log_source()]: удалён [file.name].")
	node.network?.add_log("[log_source()] удалил [file.name] с [node.address]")
	if(legit_node_level(node) < NETRUN_ACCESS_ROOT)
		add_trace(5 * node.get_security())
	qdel(file)

/// Один путь доставки файлов для кнопок, CLI и будущих клиентов.
/datum/netrun_console/proc/queue_file_request(action, datum/component/netrun_node/node, uid, to_shard = FALSE)
	var/required = action == "delete" ? NETRUN_ACCESS_ROOT : NETRUN_ACCESS_USER
	if(!node?.file_store?.files || !can_route(node) || node_level(node) < required || !node.is_online(node != connection.jack) || is_locked() || world.time < next_command)
		return FALSE
	var/lat = latency_to(node)
	next_command = world.time + max(lat, 0.5 SECONDS)
	if(lat)
		log_line("[node.address]: файловый запрос отправлен, ~[lat * 100] мс.")
	var/datum/netrun_request/file/packet = new(src, node, action, uid, to_shard, node.network, operator)
	return packet.send(lat)

/datum/netrun_console/proc/deliver_file_request(action, datum/component/netrun_node/node, uid, to_shard, datum/netrun_network/sent_network, mob/sender)
	if(QDELETED(node))
		return FALSE
	node.join_network()
	var/datum/netrun_path_tree/tree = make_path_tree()
	var/required = action == "delete" ? NETRUN_ACCESS_ROOT : NETRUN_ACCESS_USER
	if(sender != operator || node.network != sent_network || is_locked() || !can_route(node, tree) || !node.is_online(node != connection.jack) || node_level(node, tree) < required)
		qdel(tree)
		log_line("Файловый запрос отменён: соединение изменилось.", "bad")
		return FALSE
	qdel(tree)
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


/datum/netrun_console/proc/network_catalog()
	var/list/catalog_context = ui_projection_context()
	if(ui_network_catalog && netrun_snapshot_equal(ui_catalog_context, catalog_context))
		return ui_network_catalog
	ui_catalog_context = catalog_context
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
			"can_breach" = intrusion.can_breach && reachable && network_level(network) < NETRUN_ACCESS_GUEST,
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
	ui_network_catalog = networks
	return networks

/// The backend retains omitted fields, so unchanged LAN catalogs need no repeated JSON.
/datum/netrun_console/proc/append_network_catalog(list/data, list/session, refresh = TRUE)
	var/list/catalog = refresh ? network_catalog() : ui_network_catalog
	if(!catalog)
		catalog = list()
	if(session && session["network_catalog"] == catalog)
		return
	data["networks"] = catalog
	if(session)
		session["network_catalog"] = catalog

/// Small authorization/connectivity key shared by catalog and completion projections.
/// File-store revisions cover keys, daemons and renamed/deleted completion candidates.
/datum/netrun_console/proc/ui_projection_context()
	// Within one ui_data pass every input below is fixed, and catalog/CLI validity checks each
	// rebuild this list; compute it once per pass. Standalone callers still get a fresh snapshot.
	if(ui_serializing && ui_projection_cache)
		return ui_projection_cache
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	var/datum/component/netrun_node/source = route_source()
	var/list/access = user_access()
	. = list(operator, source?.address, source?.is_online(), graph.revision, graph.transit_availability_revision,
		map_view.authorization_revision, access.Copy(), is_locked(), intrusion.can_breach,
		inventory.local_store?.revision, inventory.shard, inventory.shard?.file_store?.revision,
		connection.wireless, connection.jack?.address, web_browsing(), ui_uplink_value,
		SSntnet.is_enabled(), length(SSntnet.catalog))
	if(ui_serializing)
		ui_projection_cache = .
