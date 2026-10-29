/**
 * Автономный бот - сетевая сущность без клиента. Он ходит, выполняет команды узлов
 * и сражается теми же путями, что игрок: права проверяются при доставке, пакеты
 * видны на карте, ICE считает его нарушителем без доступа ПОЛЬЗОВАТЕЛЯ.
 */
/mob/camera/netrun_entity/bot
	has_messenger = FALSE
	var/bot_kind
	var/net_faction = NETRUN_FACTION_ROGUE
	var/datum/netrun_bot_program/program
	var/datum/netrun_bot_brain/brain
	/// Agents: the launching console.
	var/datum/weakref/owner_ref
	var/launched_by_owner = FALSE
	/// Agents: the program file returns to the owner on recall.
	var/datum/netrun_file/agent_file
	var/home_address
	var/static/serial = 0

/mob/camera/netrun_entity/bot/Initialize(mapload, datum/component/netrun_node/start, program_id, datum/netrun_console/owner)
	program = SSnetrun.get_bot_program(program_id) || SSnetrun.get_bot_program(NETRUN_BOT_RAIDER)
	bot_kind = program.id
	net_faction = program.faction
	console_type = program.console_type
	max_integrity = program.max_integrity
	integrity = max_integrity
	if(owner)
		owner_ref = WEAKREF(owner)
		launched_by_owner = TRUE
	. = ..(mapload, start)
	console.operator = src
	console.inventory.local_store.capacity = program.storage
	serial++
	set_net_name("[program.name_prefix]-[serial < 10 ? "0" : ""][serial]", program.name)
	var/datum/netrun_persona/persona = get_persona()
	if(persona)
		persona.avatar = program.avatar
		persona.accent = program.accent
		persona.tagline = program.tagline
	home_address = start?.address
	brain = new(src)
	program.equip(src)
	SSnetrun.bots |= src
	program.on_spawn(src)
	host_node?.network?.add_log("Запущен автономный процесс [real_name] ([program.name]).")
	brain.schedule(1 SECONDS)

/mob/camera/netrun_entity/bot/Destroy()
	SSnetrun.bots -= src
	SSnetrun.note_bot_lost(src)
	QDEL_NULL(brain)
	QDEL_NULL(agent_file)
	owner_ref = null
	program = null
	return ..()

/mob/camera/netrun_entity/bot/netrun_bot_kind()
	return bot_kind

/mob/camera/netrun_entity/bot/defense_threat()
	return !program?.sanctioned

/mob/camera/netrun_entity/bot/netrun_faction()
	return net_faction

/mob/camera/netrun_entity/bot/netrun_owner_console()
	return owner_ref?.resolve()

/mob/camera/netrun_entity/bot/contact_state()
	if(is_stunned())
		return "оглушён"
	return brain?.state || "ожидание"

/mob/camera/netrun_entity/bot/get_netrun_combatant()
	RETURN_TYPE(/datum/component/netrun_combatant)
	return LoadComponent(/datum/component/netrun_combatant/entity/bot)

/// An agent whose launching console is gone has nobody to report to.
/mob/camera/netrun_entity/bot/proc/agent_orphaned()
	return launched_by_owner && QDELETED(owner_ref?.resolve())

/mob/camera/netrun_entity/bot/dissolve()
	if(QDELETED(src))
		return
	var/datum/component/netrun_node/node = host_node
	drop_remains(node)
	var/datum/netrun_console/master = netrun_owner_console()
	master?.log_line("Агент [real_name] уничтожен[node ? " в узле [node.address]" : ""].", "bad")
	node?.network?.add_log("Автономный процесс [real_name] завершён.")
	if(node)
		SSnetrun.post_event("purge", null, node.address)
	qdel(src)

/// Rogue processes leave one combat program in the debris; agents leave their program file.
/mob/camera/netrun_entity/bot/proc/drop_remains(datum/component/netrun_node/node)
	if(QDELETED(node))
		return
	var/list/remains = list()
	if(agent_file)
		remains += agent_file
		agent_file = null
	if(net_faction == NETRUN_FACTION_ROGUE)
		var/list/programs = list()
		for(var/datum/netrun_file/file as anything in console.inventory.local_store.files)
			if(file.kind == NETRUN_FILE_PROGRAM)
				programs += file
		if(length(programs))
			var/datum/netrun_file/loot = pick(programs)
			console.inventory.local_store.remove(loot)
			remains += loot
	for(var/datum/netrun_file/file as anything in remains)
		while(length(node.salvage) >= NETRUN_MAX_SALVAGE_FILES)
			var/datum/netrun_file/expired = node.salvage[1]
			node.salvage.Cut(1, 2)
			qdel(expired)
		node.salvage += file
		node.add_log("В обломках процесса [real_name] остался файл: [file.name].")

/// Recall: the agent becomes a file in its owner's memory again (or debris when there is no room).
/mob/camera/netrun_entity/bot/proc/return_to_owner()
	var/datum/netrun_console/master = netrun_owner_console()
	var/datum/component/netrun_node/node = host_node
	if(QDELETED(master))
		dissolve()
		return
	var/datum/component/netrun_node/source = master.route_source()
	if(node && source)
		var/datum/netrun_path_tree/tree = master.make_path_tree()
		var/list/route = tree.addresses_to(node.address)
		var/eta = master.latency_to(node, tree)
		qdel(tree)
		SSnetrun.post_event("packet", node.address, source.address, reverseRange(route.Copy()),
			list("id" = "agent-[REF(src)]", "packet" = "file", "phase" = "send", "duration" = eta, "label" = "Возврат агента [real_name]", "owner" = REF(master)))
	if(agent_file)
		if(master.store_file(agent_file))
			master.log_line("Агент [real_name] вернулся: файл [agent_file.name] снова в памяти.", "good")
			agent_file = null
		else
			master.log_line("Нет места для [agent_file.name]: файл агента остался в обломках узла [node?.address].", "average")
	launched_by_owner = FALSE
	owner_ref = null
	drop_remains(node)
	node?.network?.add_log("Автономный процесс [real_name] отозван владельцем.")
	qdel(src)

/mob/camera/netrun_entity/bot/proc/agent_entry()
	var/datum/netrun_file_store/store = console.inventory.local_store
	var/list/orders = list(list("id" = "recall", "name" = "Отозвать"), list("id" = "guard", "name" = "Перевести на выбранный узел", "needs_node" = TRUE), list("id" = "terminate", "name" = "Завершить"))
	return list("ref" = REF(src), "name" = real_name, "bot_kind" = bot_kind,
		"node" = host_node?.address, "node_name" = host_node?.get_name(),
		"integrity" = round(integrity), "max_integrity" = max_integrity,
		"state" = contact_state(), "goal" = brain?.goal_text(),
		"storage" = list("used" = store.used(), "capacity" = store.capacity), "orders" = orders)

// MARK: Консоль бота

/datum/netrun_console/entity/bot
	name = "автономный процесс"

/datum/netrun_console/entity/bot/autonomous()
	return TRUE

/datum/netrun_console/entity/bot/note_user_action()
	return

/datum/netrun_console/entity/bot/note_ui_activity(defer_context_refresh = FALSE)
	return

/// Arrival still reacts on the machine side; there is no player UI to wake.
/datum/netrun_console/entity/bot/finish_user_action(datum/component/netrun_node/node)
	if(QDELETED(node))
		return
	node.reconcile_state()
	node.wake_defenses()

/// Nobody watches a bot terminal: keep a bounded log without waking UI machinery.
/datum/netrun_console/entity/bot/log_line(text, kind = "label")
	log += list(list("time" = STATION_TIME_TIMESTAMP("hh:mm:ss", world.time), "text" = text, "kind" = kind))
	if(length(log) > NETRUN_MAX_CONSOLE_LOG)
		log.Cut(1, length(log) - NETRUN_MAX_CONSOLE_LOG + 1)
	SEND_SIGNAL(src, COMSIG_NETRUN_CONSOLE_EVENT, text, kind)

/datum/netrun_console/entity/bot/log_source()
	var/mob/camera/netrun_entity/bot/bot = host
	return "автономный процесс [bot?.real_name]"

/// A station custodian works legally inside its department LANs.
/datum/netrun_console/entity/bot/custodian
	/// LAN ids of the custodian's department.
	var/list/jurisdiction = list()

/datum/netrun_console/entity/bot/custodian/compute_legit_node_level(datum/component/netrun_node/node, fresh = FALSE)
	. = ..()
	if(node?.network && (node.network.id in jurisdiction))
		. = max(., NETRUN_ACCESS_USER)

/datum/netrun_console/entity/bot/custodian/legit_network_level(datum/netrun_network/network, fresh = FALSE)
	. = ..()
	if(network && (network.id in jurisdiction))
		. = max(., NETRUN_ACCESS_GUEST)

// MARK: Боевой интерфейс бота

/datum/component/netrun_combatant/entity/bot
	kind = "bot"

/datum/component/netrun_combatant/entity/bot/Initialize()
	if(!istype(parent, /mob/camera/netrun_entity/bot))
		return COMPONENT_INCOMPATIBLE

/datum/component/netrun_combatant/entity/bot/damage(amount, reason, datum/netrun_console/attacker)
	var/mob/camera/netrun_entity/bot/bot = parent
	. = ..()
	if(!QDELETED(bot))
		bot.brain?.note_attacker(attacker)

/datum/component/netrun_combatant/entity/bot/stun(duration)
	var/mob/camera/netrun_entity/bot/bot = parent
	. = ..()
	bot.brain?.wake_now()

/datum/component/netrun_combatant/entity/bot/protected_by_station()
	var/mob/camera/netrun_entity/bot/bot = parent
	return bot.net_faction == NETRUN_FACTION_STATION

/datum/component/netrun_combatant/entity/bot/ui_entry()
	. = ..()
	var/mob/camera/netrun_entity/bot/bot = parent
	.["bot_kind"] = bot.bot_kind
	.["faction"] = bot.net_faction
	.["goal"] = bot.brain?.goal_text()
	.["hostile"] = bot.net_faction == NETRUN_FACTION_ROGUE

// MARK: Агенты игроков

/datum/netrun_console/proc/agents()
	. = list()
	for(var/mob/camera/netrun_entity/bot/bot as anything in SSnetrun.bots)
		if(!QDELETED(bot) && bot.netrun_owner_console() == src)
			. += bot

/datum/netrun_console/proc/agents_payload()
	if(!length(SSnetrun.bots))
		return null
	var/list/entries = list()
	for(var/mob/camera/netrun_entity/bot/bot as anything in agents())
		entries += list(bot.agent_entry())
	return length(entries) ? entries : null

/// The entity's own node, otherwise the requested/selected node with USER and a route.
/datum/netrun_console/proc/agent_launch_site(address)
	var/mob/camera/netrun_entity/self = combat_self()
	if(istype(self))
		return self.host_node
	var/datum/component/netrun_node/node = SSnetrun.find_node(address) || selected_node()
	if(!node || !can_route(node) || !node.is_online(node != connection.jack) || node_level(node) < NETRUN_ACCESS_USER)
		return null
	return node

/datum/netrun_console/proc/launch_bot_file(uid, address)
	var/datum/netrun_file/file = find_local_file(uid)
	if(!file || file.kind != NETRUN_FILE_BOT)
		log_line("Файл агента не найден.", "bad")
		return FALSE
	var/datum/netrun_bot_program/program = SSnetrun.get_bot_program(file.content)
	if(!program?.file_size)
		log_line("Программа агента [file.name] повреждена.", "bad")
		return FALSE
	if(is_locked())
		log_line("Точка подключения заблокирована.", "bad")
		return FALSE
	if(length(agents()) >= NETRUN_MAX_AGENTS_PER_CONSOLE)
		log_line("Уже работают [NETRUN_MAX_AGENTS_PER_CONSOLE] агента. Отзовите одного из них.", "bad")
		return FALSE
	if(length(SSnetrun.bots) >= NETRUN_MAX_BOTS)
		log_line("Сеть перегружена автономными процессами: запуск отклонён.", "bad")
		return FALSE
	var/datum/component/netrun_node/site = agent_launch_site(address)
	if(!site)
		log_line("Агента негде запустить: нужен выбранный узел с доступом ПОЛЬЗОВАТЕЛЯ и маршрутом.", "bad")
		return FALSE
	var/datum/netrun_file_store/store = inventory.store_for(file)
	if(!store?.remove(file))
		return FALSE
	if(inventory.selected_file_uid == file.uid)
		inventory.selected_file_uid = null
	var/mob/camera/netrun_entity/bot/agent = SSnetrun.spawn_bot(program.id, site, src)
	if(!agent)
		store.insert(file, TRUE)
		log_line("Агента не удалось запустить.", "bad")
		return FALSE
	agent.agent_file = file
	// A snapshot of the owner's acquired grants; legal ID access is never copied.
	for(var/address_key in access_session.node_access)
		agent.console.access_session.node_access[address_key] = max(agent.console.access_session.node_access[address_key] || 0, min(access_session.node_access[address_key], NETRUN_ACCESS_USER))
	for(var/network_key in access_session.network_access)
		agent.console.access_session.network_access[network_key] = access_session.network_access[network_key]
	log_line("Агент [agent.real_name] запущен в узле [site.get_name()] [site.address].", "good")
	site.add_log("[log_source()]: запущен агент [agent.real_name].")
	return TRUE

/datum/netrun_console/proc/agent_order(ref, order, address)
	var/mob/camera/netrun_entity/bot/agent = locate(ref)
	if(!istype(agent) || QDELETED(agent) || agent.netrun_owner_console() != src)
		log_line("Агент не найден.", "bad")
		return FALSE
	switch(order)
		if("recall")
			agent.brain.clear_goals()
			agent.brain.push_goal(new /datum/netrun_bot_goal/recall(agent.brain))
			agent.brain.wake_now()
			log_line("Агенту [agent.real_name] отдан приказ вернуться.")
			return TRUE
		if("terminate")
			log_line("Агент [agent.real_name] завершён: его файл остаётся в обломках узла.", "average")
			agent.dissolve()
			return TRUE
		if("guard")
			var/datum/component/netrun_node/node = SSnetrun.find_node(address) || selected_node()
			if(!node || !can_route(node) || node_level(node) < NETRUN_ACCESS_USER)
				log_line("Новый пост агента должен быть узлом с вашим доступом ПОЛЬЗОВАТЕЛЯ.", "bad")
				return FALSE
			// The owner delegates residency on the new post.
			agent.console.access_session.node_access[node.address] = max(agent.console.access_session.node_access[node.address] || 0, NETRUN_ACCESS_USER)
			agent.brain.order = "guard"
			agent.brain.order_node_ref = WEAKREF(node)
			agent.brain.clear_goals()
			agent.brain.wake_now()
			log_line("Агент [agent.real_name] переводится на узел [node.get_name()] [node.address].")
			return TRUE
	log_line("Неизвестный приказ агенту.", "bad")
	return FALSE

// MARK: Население

/datum/controller/subsystem/netrun
	var/list/mob/camera/netrun_entity/bot/bots = list()
	/// Unit tests spawn their own bots.
	var/bots_enabled = NETRUN_AUTONOMOUS_CONTENT
	var/next_bot_census = 0
	var/rogue_wave_at = 0
	var/police_respawn_at = 0
	var/custodian_respawn_at = 0

/datum/controller/subsystem/netrun/proc/spawn_bot(program_id, datum/component/netrun_node/node, datum/netrun_console/owner)
	if(QDELETED(node) || QDELETED(node.parent) || length(bots) >= NETRUN_MAX_BOTS)
		return null
	var/turf/spot = node.physical_turf()
	if(!spot)
		return null
	return new /mob/camera/netrun_entity/bot(spot, node, program_id, owner)

/datum/controller/subsystem/netrun/proc/note_bot_lost(mob/camera/netrun_entity/bot/bot)
	switch(bot.bot_kind)
		if(NETRUN_BOT_POLICE)
			police_respawn_at = world.time + 5 MINUTES
		if(NETRUN_BOT_CUSTODIAN)
			custodian_respawn_at = world.time + 8 MINUTES

/datum/controller/subsystem/netrun/proc/count_bots(kind)
	. = 0
	for(var/mob/camera/netrun_entity/bot/bot as anything in bots)
		if(!QDELETED(bot) && bot.bot_kind == kind)
			.++

/// Department key of a LAN, from the area its APC serves.
/proc/netrun_network_department(datum/netrun_network/network)
	return network?.area ? netrun_department_key(network.area) : null

/// A stationary, online, unfortified node of the given departments (any station LAN when null).
/datum/controller/subsystem/netrun/proc/bot_spawn_node(list/departments)
	var/list/candidates = list()
	for(var/id in networks)
		var/datum/netrun_network/network = networks[id]
		if(network.isolated || (departments && !(netrun_network_department(network) in departments)))
			continue
		for(var/datum/component/netrun_node/node as anything in network.nodes)
			if(!QDELETED(node) && !QDELETED(node.parent) && !node.fortress && !node.is_dynamic() && node.is_online())
				candidates += node
	return length(candidates) ? pick(candidates) : null

/// Housekeeping: keep the police and maintenance processes alive, let rogue raiders appear.
/datum/controller/subsystem/netrun/proc/maintain_bots()
	if(!bots_enabled || world.time < next_bot_census)
		return
	next_bot_census = world.time + 20 SECONDS
	for(var/mob/camera/netrun_entity/bot/bot as anything in bots.Copy())
		if(QDELETED(bot))
			bots -= bot
	if(!rogue_wave_at)
		rogue_wave_at = world.time + 5 MINUTES
	if(count_bots(NETRUN_BOT_POLICE) < NETRUN_POLICE_QUOTA && world.time >= police_respawn_at)
		var/datum/component/netrun_node/node = bot_spawn_node(list("security")) || bot_spawn_node(null)
		var/mob/camera/netrun_entity/bot/police = spawn_bot(NETRUN_BOT_POLICE, node)
		police?.host_node?.network?.add_log("На дежурство заступил процесс сетевой полиции [police.real_name].")
		return
	if(world.time >= custodian_respawn_at && count_bots(NETRUN_BOT_CUSTODIAN) < NETRUN_CUSTODIAN_QUOTA)
		spawn_custodian()
	if(world.time >= rogue_wave_at && count_bots(NETRUN_BOT_RAIDER) < NETRUN_ROGUE_QUOTA)
		rogue_wave_at = world.time + rand(6 MINUTES, 10 MINUTES)
		var/mob/camera/netrun_entity/bot/raider = spawn_bot(NETRUN_BOT_RAIDER, bot_spawn_node(list("general", "cargo")))
		if(raider)
			report_incident("rogue", raider.host_node, raider, NETRUN_INCIDENT_MEDIUM, "Обнаружен дикий процесс [raider.real_name].")

/// One custodian per department without one, among departments that keep patrols.
/datum/controller/subsystem/netrun/proc/spawn_custodian()
	var/list/covered = list()
	for(var/mob/camera/netrun_entity/bot/bot as anything in bots)
		var/datum/netrun_console/entity/bot/custodian/console = bot.console
		if(!QDELETED(bot) && istype(console))
			for(var/id in console.jurisdiction)
				covered[netrun_network_department(networks[id])] = TRUE
	for(var/department in list("engineering", "medical", "science", "command", "security"))
		if(covered[department])
			continue
		var/list/jurisdiction = list()
		for(var/id in networks)
			var/datum/netrun_network/network = networks[id]
			if(!network.isolated && network.security >= 2 && netrun_network_department(network) == department)
				jurisdiction += id
		if(!length(jurisdiction))
			continue
		var/mob/camera/netrun_entity/bot/custodian = spawn_bot(NETRUN_BOT_CUSTODIAN, bot_spawn_node(list(department)))
		var/datum/netrun_console/entity/bot/custodian/console = custodian?.console
		if(istype(console))
			console.jurisdiction = jurisdiction
		return custodian
	return null
