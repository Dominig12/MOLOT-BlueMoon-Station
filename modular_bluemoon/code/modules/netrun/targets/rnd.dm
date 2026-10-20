// MARK: Серверы РнД как узлы сети
//
// Сервер исследований становится узлом: можно снять сводку (сеть, очки, число открытых узлов),
// слить часть очков исследований себе в хранилище (кража) и временно обрушить его доход.

/obj/machinery/rnd/server/LateInitialize()
	. = ..()
	AddComponent(/datum/component/netrun_node, NETRUN_NODE_SERVER, list("rnd_report", "rnd_nodes", "rnd_siphon", "rnd_grab", "rnd_push", "rnd_choke"), 3, list(ACCESS_RD))

/obj/machinery/rnd/server/netrun_online(remote = TRUE)
	return working && !(machine_stat & (NOPOWER | BROKEN))

/obj/machinery/rnd/server/netrun_status()
	. = list()
	. += "Состояние: [working ? "работает" : "простой"]"
	. += "Сеть РнД: [network_id]"
	if(stored_research)
		var/total = 0
		for(var/point_type in stored_research.research_points)
			total += stored_research.research_points[point_type]
		. += "Очки в банке: [round(total)]"

/datum/netrun_command/rnd_report
	id = "rnd_report"
	name = "Сводка исследований"
	desc = "Показать сеть, запас очков и число открытых узлов техвеба."
	access = NETRUN_ACCESS_USER
	icon = "flask"
	trace = 3
	works_offline = TRUE

/datum/netrun_command/rnd_report/execute(datum/component/netrun_node/node, datum/netrun_console/console)
	var/obj/machinery/rnd/server/server = node.parent
	if(!server.stored_research)
		return "Техвеб не подключён."
	var/list/lines = list("Сеть: [server.network_id]", "Открыто узлов: [length(server.stored_research.researched_nodes)]")
	for(var/point_type in server.stored_research.research_points)
		lines += "[point_type]: [round(server.stored_research.research_points[point_type])]"
	return jointext(lines, "\n")

/datum/netrun_command/rnd_siphon
	id = "rnd_siphon"
	name = "Слить данные"
	desc = "Скопировать себе часть очков исследований, вычтя их из банка сети."
	access = NETRUN_ACCESS_ROOT
	icon = "download"
	trace = 10
	danger = TRUE

/datum/netrun_command/rnd_siphon/execute(datum/component/netrun_node/node, datum/netrun_console/console)
	var/obj/machinery/rnd/server/server = node.parent
	if(!server.stored_research)
		return "Техвеб не подключён."
	var/list/stolen = list()
	var/total = 0
	for(var/point_type in server.stored_research.research_points)
		var/amount = round(server.stored_research.research_points[point_type] * 0.25)
		if(amount <= 0)
			continue
		stolen[point_type] = amount
		total += amount
	if(!total)
		return "В банке сети нечего сливать."
	server.stored_research.remove_point_list(stolen)
	var/list/report = list()
	for(var/point_type in stolen)
		report += "[point_type]: [stolen[point_type]]"
	var/datum/netrun_file/file = new("rnd_[server.server_id].dat", NETRUN_FILE_TEXT, "Выгрузка исследований с сервера [server.network_id]:\n[jointext(report, "\n")]", 2)
	if(!console.store_file(file))
		qdel(file)
		console.log_line("Нет места в хранилище - данные не сохранены, но очки уже списаны.", "bad")
	return "Слито очков: [total]. Данные записаны в хранилище."

/datum/netrun_command/rnd_choke
	id = "rnd_choke"
	name = "Заглушить сервер"
	desc = "Сбить сервер исследований в простой на 30 секунд - он перестаёт приносить доход."
	access = NETRUN_ACCESS_ROOT
	icon = "hourglass-half"
	trace = 8
	danger = TRUE

/datum/netrun_command/rnd_choke/execute(datum/component/netrun_node/node, datum/netrun_console/console)
	var/obj/machinery/rnd/server/server = node.parent
	if(!server.working)
		return "Сервер и так в простое."
	server.working = FALSE
	addtimer(CALLBACK(server, TYPE_PROC_REF(/obj/machinery/rnd/server, refresh_working)), 30 SECONDS)
	return "Сервер заглушён на 30 секунд."

// MARK: Кража и выгрузка узлов techweb

/datum/netrun_command/rnd_nodes
	id = "rnd_nodes"
	name = "Список технологий"
	desc = "Показать открытые узлы техвеба сервера."
	access = NETRUN_ACCESS_USER
	icon = "sitemap"
	trace = 3
	works_offline = TRUE

/datum/netrun_command/rnd_nodes/execute(datum/component/netrun_node/node, datum/netrun_console/console)
	var/obj/machinery/rnd/server/server = node.parent
	if(!server.stored_research)
		return "Техвеб не подключён."
	var/list/names = list()
	var/count = 0
	for(var/node_id in server.stored_research.researched_nodes)
		count++
		if(count > 14)
			continue
		var/datum/techweb_node/tnode = SSresearch.techweb_nodes[node_id]
		if(tnode)
			names += tnode.display_name
	return "Открыто узлов: [length(server.stored_research.researched_nodes)]\n[jointext(names, "\n")][count > 14 ? "\n…" : ""]"

/datum/netrun_command/rnd_grab
	id = "rnd_grab"
	name = "Скопировать техвеб"
	desc = "Снять дамп всех открытых узлов техвеба в файл хранилища."
	access = NETRUN_ACCESS_ROOT
	icon = "download"
	trace = 9
	danger = TRUE

/datum/netrun_command/rnd_grab/execute(datum/component/netrun_node/node, datum/netrun_console/console)
	var/obj/machinery/rnd/server/server = node.parent
	if(!server.stored_research || !length(server.stored_research.researched_nodes))
		return "Нечего копировать."
	var/list/ids = list()
	for(var/node_id in server.stored_research.researched_nodes)
		ids += node_id
	var/datum/netrun_file/file = new("techweb_[server.server_id].web", NETRUN_FILE_TECHWEB, jointext(ids, ";"), max(1, round(length(ids) / 20)))
	if(!console.store_file(file))
		qdel(file)
		return "Нет места в хранилище."
	return "Снят дамп техвеба: [length(ids)] узлов в [file.name]."

/datum/netrun_command/rnd_push
	id = "rnd_push"
	name = "Залить техвеб"
	desc = "Разблокировать на этом сервере узлы из сохранённого дампа техвеба."
	access = NETRUN_ACCESS_ROOT
	icon = "upload"
	trace = 11
	danger = TRUE

/datum/netrun_command/rnd_push/execute(datum/component/netrun_node/node, datum/netrun_console/console)
	var/obj/machinery/rnd/server/server = node.parent
	if(!server.stored_research)
		return "Техвеб не подключён."
	var/datum/netrun_file/source
	for(var/datum/netrun_file/file as anything in console.all_files())
		if(file.kind == NETRUN_FILE_TECHWEB)
			source = file
	if(!source)
		return "В хранилище нет дампа техвеба."
	var/count = 0
	for(var/node_id in splittext(source.content, ";"))
		if(!SSresearch.techweb_nodes[node_id])
			continue
		if(server.stored_research.researched_nodes[node_id])
			continue
		if(server.stored_research.research_node_id(node_id, force = TRUE, auto_update_points = FALSE))
			count++
	return "Залито узлов техвеба: [count]."
