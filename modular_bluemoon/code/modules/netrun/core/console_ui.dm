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
	access_cache = user_access()
	network_level_cache = list()
	. = build_ui_data(user)
	access_cache = null
	network_level_cache = null

/datum/netrun_console/proc/build_ui_data(mob/user)
	var/list/data = list()
	data["origin"] = origin
	data["wireless"] = wireless
	data["uplink"] = has_uplink()
	data["trace"] = round(trace, 0.1)
	data["locked"] = is_locked() ? round((lockout_until - world.time) / (1 SECONDS)) : 0
	data["can_breach"] = can_breach
	data["log"] = log
	data["jack"] = jack ? list("address" = jack.address, "name" = jack.get_name()) : null
	data["host_actions"] = host_actions()

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

	if(viewed_network_id == "web" && web_browsing())
		data["view"] = null
		data["selected"] = null
		data["web"] = web_payload()
		data["storage"] = storage_payload()
		data["shard"] = shard_payload()
		data["breach"] = breach?.ui_payload()
		data["entity"] = entity_data()
		data["chat"] = chat_data()
		return data
	data["web"] = null

	var/datum/netrun_network/viewed = SSnetrun.networks[viewed_network_id]
	if(!viewed && length(homes))
		viewed = homes[1]
		viewed_network_id = viewed.id
	var/list/view = null
	if(viewed)
		var/level = network_level(viewed)
		var/list/nodes = list()
		if(level >= NETRUN_ACCESS_GUEST)
			for(var/datum/component/netrun_node/node as anything in viewed.nodes)
				nodes += list(node.ui_entry(src))
		view = list(
			"id" = viewed.id,
			"name" = viewed.name,
			"code" = viewed.code,
			"color" = viewed.color,
			"access" = level,
			"nodes" = nodes,
			"log" = level >= NETRUN_ACCESS_USER ? viewed.logs.Copy(max(1, length(viewed.logs) - 14)) : list(),
		)
	data["view"] = view

	var/datum/component/netrun_node/node = selected_node()
	var/list/selected = null
	if(node && node_level(node) >= NETRUN_ACCESS_GUEST)
		var/level = node_level(node)
		selected = node.ui_entry(src)
		selected["network"] = node.network?.short_name
		selected["legit"] = legit_node_level(node)
		var/list/commands = list()
		for(var/command_id in node.command_ids)
			var/datum/netrun_command/command = SSnetrun.get_command(command_id)
			if(command)
				commands += list(command.ui_entry(node, src, command_id))
		selected["commands"] = commands
		var/atom/A = node.parent
		selected["status"] = level >= NETRUN_ACCESS_USER ? A.netrun_status() : list()
		if(node.files && level >= NETRUN_ACCESS_USER)
			var/list/files = list()
			for(var/datum/netrun_file/file as anything in node.files)
				files += list(file.ui_entry())
			selected["files"] = files
			selected["storage"] = list("used" = node.used_storage(), "capacity" = node.storage_capacity)
	data["selected"] = selected

	data["storage"] = storage_payload()
	data["shard"] = shard_payload()

	data["breach"] = breach?.ui_payload()
	data["entity"] = entity_data()
	data["chat"] = chat_data()
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

/datum/netrun_console/proc/storage_payload()
	var/list/local = list()
	for(var/datum/netrun_file/file as anything in storage)
		local += list(file.ui_entry())
	return list("files" = local, "used" = netrun_storage_used(storage), "capacity" = storage_capacity)

/datum/netrun_console/proc/shard_payload()
	if(!shard)
		return null
	var/list/shard_files = list()
	for(var/datum/netrun_file/file as anything in shard.files)
		shard_files += list(file.ui_entry())
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
	switch(action)
		if("view_network")
			if(params["id"] == "web")
				if(web_browsing())
					viewed_network_id = "web"
				return TRUE
			var/datum/netrun_network/network = SSnetrun.networks[params["id"]]
			if(network && can_reach(network))
				viewed_network_id = network.id
			return TRUE
		if("select")
			var/datum/component/netrun_node/node = SSnetrun.find_node(params["address"])
			if(node && node_level(node) >= NETRUN_ACCESS_GUEST)
				selected_address = node.address
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

/datum/netrun_console/proc/transfer_from_node(uid, to_shard)
	var/datum/component/netrun_node/node = selected_node()
	if(!node?.files || node_level(node) < NETRUN_ACCESS_USER || !node.is_online(node != jack))
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
	log_line("Скачано: [file.name].", "good")
	var/illegal = legit_node_level(node) < NETRUN_ACCESS_USER
	node.network?.add_log("[log_source()] скачал [file.name] с [node.address][illegal ? " (без авторизации)" : ""]", illegal)
	if(illegal)
		add_trace(4 * node.get_security())

/datum/netrun_console/proc/transfer_to_node(uid)
	var/datum/component/netrun_node/node = selected_node()
	if(!node?.files || node_level(node) < NETRUN_ACCESS_USER || !node.is_online(node != jack))
		return
	var/datum/netrun_file/file = find_local_file(uid)
	if(!file)
		return
	if(node.used_storage() + file.size > node.storage_capacity)
		log_line("На узле нет места.", "bad")
		return
	node.files += file.copy()
	node.touch()
	log_line("Загружено: [file.name].", "good")
	var/illegal = legit_node_level(node) < NETRUN_ACCESS_USER
	node.network?.add_log("[log_source()] загрузил [file.name] на [node.address]")
	if(illegal)
		add_trace(3 * node.get_security())

/datum/netrun_console/proc/delete_from_node(uid)
	var/datum/component/netrun_node/node = selected_node()
	if(!node?.files || node_level(node) < NETRUN_ACCESS_ROOT || !node.is_online(node != jack))
		return
	var/datum/netrun_file/file = remote_file(node, uid)
	if(!file)
		return
	node.files -= file
	log_line("Удалено с узла: [file.name].", "average")
	node.network?.add_log("[log_source()] удалил [file.name] с [node.address]")
	if(legit_node_level(node) < NETRUN_ACCESS_ROOT)
		add_trace(5 * node.get_security())
	qdel(file)

/datum/netrun_console/proc/read_file(mob/user, uid)
	var/datum/netrun_file/file = find_local_file(uid)
	if(!file)
		file = remote_file(selected_node(), uid)
		if(file && node_level(selected_node()) < NETRUN_ACCESS_USER)
			return
	if(!file || file.kind != NETRUN_FILE_TEXT)
		return
	var/datum/browser/popup = new(user, "netrun_file_[file.uid]", file.name, 450, 500)
	popup.set_content("<tt>[replacetext(html_encode(file.content), "\n", "<br>")]</tt>")
	popup.open()

// MARK: Командная строка

/datum/netrun_console/proc/cli(text)
	text = trim(copytext_char("[text]", 1, 200))
	if(!length(text))
		return
	log_line("$ [text]", "label")
	var/list/words = splittext(text, " ")
	var/verb_name = lowertext(words[1])
	var/argument = length(words) > 1 ? words[2] : null
	switch(verb_name)
		if("help", "?")
			log_line("net \[id\] — сети / открыть сеть; sel <адрес> — выбрать узел; run <команда> — выполнить; \
				breach \[адрес | id сети\] — взлом; scan — сканировать выбранный; ls — локальные файлы; clear — очистить экран")
		if("clear")
			log.Cut()
		if("net")
			if(!argument)
				for(var/network_id in SSnetrun.networks)
					var/datum/netrun_network/network = SSnetrun.networks[network_id]
					if(can_reach(network))
						log_line("[network.code] ([network.id]) — [network.name], узлов: [length(network.nodes)], доступ: [netrun_access_name(network_level(network))]")
				return
			var/datum/netrun_network/network = SSnetrun.find_network(argument)
			if(!network || !can_reach(network))
				log_line("Сеть недоступна.", "bad")
				return
			viewed_network_id = network.id
		if("sel")
			var/datum/component/netrun_node/node = SSnetrun.find_node(argument)
			if(!node || node_level(node) < NETRUN_ACCESS_GUEST)
				log_line("Узел не найден.", "bad")
				return
			selected_address = node.address
			log_line("Выбран [node.get_name()] [node.address].")
		if("run")
			run_command(selected_node(), lowertext(argument))
		if("scan")
			run_command(selected_node(), "scan")
		if("breach")
			if(argument && SSnetrun.networks[lowertext(argument)])
				start_breach("network", lowertext(argument))
			else
				start_breach("node", argument || selected_address)
		if("ls")
			for(var/datum/netrun_file/file as anything in all_files())
				log_line("[file.name] ([file.kind], [file.size])")
		else
			log_line("Неизвестная команда. help — справка.", "bad")
