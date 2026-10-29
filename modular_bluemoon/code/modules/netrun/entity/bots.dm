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
	var/expires_at = 0
	var/return_pending = FALSE
	var/static/serial = 0

/mob/camera/netrun_entity/bot/entity_module_types()
	var/list/types = ..()
	// Autonomous agents do not need a rendered HUD, its fastprocess monitors,
	// or a second moving network endpoint. A player login can add the capability.
	types -= /datum/netrun_entity_module/neural_feedback
	var/navigation_slot = types.Find(/datum/netrun_entity_module/navigation)
	if(navigation_slot)
		types[navigation_slot] = /datum/netrun_entity_module/navigation/bot
	types |= program.behavior_modules
	types |= program.extra_behavior_modules
	types |= /datum/netrun_entity_module/agent_extensions
	return types

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
	if(QDELETED(src) || QDELETED(console))
		return
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
	if(!owner && program.lifetime)
		expires_at = world.time + program.lifetime + rand(0, 2 MINUTES)
	brain = new(src)
	program.equip(src)
	SSnetrun.bots |= src
	program.on_spawn(src)
	SEND_SIGNAL(src, COMSIG_NETRUN_ENTITY_MODULE_READY, null)
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

/// Player possession suspends the autonomous clock. Returning control is a fact
/// that resumes behavior and releases presentation-only resources immediately.
/mob/camera/netrun_entity/bot/Logout()
	. = ..()
	remove_module("neural_feedback")
	brain?.wake_now()

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
	var/datum/netrun_console/owner = owner_ref?.resolve()
	return launched_by_owner && QDELETED(owner)

/// Visiting processes depart without being destroyed or generating free combat loot.
/mob/camera/netrun_entity/bot/proc/retire()
	host_node?.network?.add_log("Автономный процесс [real_name] завершил обход и покинул сеть.")
	qdel(src)

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
	if(SSnetrun.get_netrun_faction(net_faction)?.arrival_weight)
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
	if(return_pending || !node || !source || !agent_file)
		return FALSE
	var/datum/netrun_path_tree/tree = master.make_path_tree()
	if(master.is_locked() || !master.can_route(node, tree))
		qdel(tree)
		return FALSE
	var/list/route = reverseRange(tree.addresses_to(node.address))
	var/eta = master.latency_to(node, tree)
	qdel(tree)
	var/datum/netrun_request/agent_recall/packet = new(master, src, source)
	return_pending = TRUE
	return packet.send(eta, route)

/mob/camera/netrun_entity/bot/proc/agent_entry()
	var/datum/netrun_file_store/store = console.inventory.local_store
	var/list/orders = agent_orders()
	var/list/files = list()
	for(var/datum/netrun_file/file as anything in store.files)
		files += list(file.ui_entry(null))
	var/list/goals = list()
	for(var/datum/netrun_bot_goal/goal as anything in brain.goals)
		goals += list(list("id" = REF(goal), "name" = goal.name, "desc" = goal.describe(), "selected" = goal == brain.current_goal()))
	return list("ref" = REF(src), "name" = real_name, "bot_kind" = bot_kind,
		"node" = host_node?.address, "node_name" = host_node?.get_name(),
		"integrity" = round(integrity), "max_integrity" = max_integrity,
		"state" = contact_state(), "goal" = brain?.goal_text(),
		"storage" = list("used" = store.used(), "capacity" = store.capacity), "orders" = orders,
		"persona" = get_persona().ui_payload(FALSE), "files" = files, "programs" = console.combat_context.programs(), "goals" = goals)

/mob/camera/netrun_entity/bot/proc/agent_orders()
	var/list/orders = list(list("id" = "recall", "name" = "Отозвать"), list("id" = "guard", "name" = "Перевести на выбранный узел", "needs_node" = TRUE), list("id" = "terminate", "name" = "Завершить"))
	orders += list(list("id" = "patrol", "name" = "Патрулировать доступную сеть"), list("id" = "command", "name" = "Команда выбранного узла", "needs_node" = TRUE))
	orders += list(list("id" = "persona", "name" = "Личность"), list("id" = "upload", "name" = "Передать файл"), list("id" = "download", "name" = "Забрать файл"))
	SEND_SIGNAL(src, COMSIG_NETRUN_AGENT_ORDER_LIST, orders)
	return orders

// MARK: Консоль бота

/datum/netrun_console/entity/bot
	name = "автономный процесс"

/datum/netrun_console/entity/bot/autonomous()
	return TRUE

/datum/netrun_console/entity/bot/note_user_action()
	return

/datum/netrun_console/entity/bot/note_ui_activity(defer_context_refresh = FALSE)
	return

/// Autonomous logs/operations have no terminal observer. Wake only actual timed gameplay.
/datum/netrun_console/entity/bot/invalidate_ui(immediate = TRUE)
	ui_dirty = TRUE
	if(needs_processing())
		activate()
	var/mob/camera/netrun_entity/bot/bot = host
	var/datum/netrun_console/master = bot?.netrun_owner_console()
	if(master?.is_ui_active())
		master.invalidate_ui(immediate)

/datum/netrun_console/entity/bot/record_operation(datum/netrun_packet_context/operation)
	. = ..()
	var/mob/camera/netrun_entity/bot/bot = host
	bot?.brain?.command_updated(operation)

/datum/netrun_console/proc/track_command_packet(datum/netrun_request/command/packet)
	return

/datum/netrun_console/entity/bot/track_command_packet(datum/netrun_request/command/packet)
	var/mob/camera/netrun_entity/bot/bot = host
	if(bot?.brain?.command_nonce && packet.operation?.nonce == bot.brain.command_nonce)
		bot.brain.command_packet_ref = WEAKREF(packet)

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
	if(istype(file, /datum/netrun_file/bot))
		var/datum/netrun_file/bot/saved = file
		if(!saved.restore_agent(agent))
			agent.agent_file = null
			qdel(agent)
			store.insert(file, TRUE)
			return FALSE
	// A snapshot of the owner's acquired grants; legal ID access is never copied.
	for(var/address_key in access_session.node_access)
		agent.console.access_session.node_access[address_key] = max(agent.console.access_session.node_access[address_key] || 0, min(access_session.node_access[address_key], NETRUN_ACCESS_USER))
	for(var/network_key in access_session.network_access)
		agent.console.access_session.network_access[network_key] = access_session.network_access[network_key]
	log_line("Агент [agent.real_name] запущен в узле [site.get_name()] [site.address].", "good")
	site.add_log("[log_source()]: запущен агент [agent.real_name].")
	return TRUE

/datum/netrun_console/proc/agent_order(ref, order, address, list/options)
	var/mob/camera/netrun_entity/bot/agent = locate(ref)
	if(!istype(agent) || QDELETED(agent) || agent.netrun_owner_console() != src)
		log_line("Агент не найден.", "bad")
		return FALSE
	var/known_order = FALSE
	for(var/list/entry as anything in agent.agent_orders())
		if(entry["id"] == order)
			known_order = TRUE
			break
	if(!known_order)
		log_line("Неизвестный приказ агенту.", "bad")
		return FALSE
	var/datum/component/netrun_node/site = agent.host_node
	var/datum/netrun_path_tree/tree = make_path_tree()
	if(!site || is_locked() || !can_route(site, tree))
		qdel(tree)
		log_line("Нет действующего маршрута к агенту.", "bad")
		return FALSE
	var/eta = latency_to(site, tree)
	var/list/route = tree.addresses_to(site.address)
	qdel(tree)
	var/list/arguments = list("order" = order, "address" = address || selected_node()?.address)
	for(var/key in list("command", "uid", "name", "avatar", "accent", "tagline", "theme"))
		if(options && (key in options))
			arguments[key] = options[key]
	var/datum/netrun_request/agent_control/packet = new(src, agent, arguments)
	return packet.send(eta, route)

/// Called only by an authenticated, freshly delivered control packet.
/datum/netrun_console/proc/apply_agent_order(mob/camera/netrun_entity/bot/agent, list/options)
	if(SEND_SIGNAL(agent, COMSIG_NETRUN_AGENT_CONTROL, src, options))
		return TRUE
	var/order = options["order"]
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
			var/datum/component/netrun_node/node = SSnetrun.find_node(options["address"])
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
		if("patrol")
			agent.brain.clear_goals()
			agent.brain.order = "patrol"
			agent.brain.push_goal(new /datum/netrun_bot_goal/patrol(agent.brain))
			agent.brain.wake_now()
			return TRUE
		if("command")
			var/datum/component/netrun_node/node = SSnetrun.find_node(options["address"])
			var/command = options["command"]
			if(!node || !istext(command) || !(command in node.all_command_ids()))
				return FALSE
			agent.brain.clear_goals()
			agent.brain.order = "command"
			agent.brain.order_command = command
			agent.brain.order_command_address = node.address
			agent.brain.push_goal(new /datum/netrun_bot_goal/command(agent.brain, node, command))
			agent.brain.wake_now()
			return TRUE
		if("persona")
			if(("theme" in options) && !(options["theme"] in netrun_theme_ids()))
				return FALSE
			if(!agent.console.update_persona(options, agent))
				return FALSE
			if("theme" in options)
				agent.console.set_ui_theme(options["theme"], agent)
			return TRUE
		if("upload", "download")
			var/datum/netrun_console/source = order == "upload" ? src : agent.console
			var/datum/netrun_console/destination = order == "upload" ? agent.console : src
			var/datum/netrun_file/file = source.find_local_file(options["uid"])
			var/datum/netrun_file_store/store = source.inventory.store_for(file)
			return !!store?.transfer_to(destination.inventory.local_store, file, TRUE)
	return FALSE

/// Owner controls cross exactly the same cancellable delivery boundary as device commands.
/datum/netrun_request/agent_control
	parent_type = /datum/netrun_request/delivery
	var/mob/camera/netrun_entity/bot/agent
	var/list/arguments
	operation_kind = "agent"
	operation_label = "Приказ агенту"

/datum/netrun_request/agent_control/New(datum/netrun_console/master, mob/camera/netrun_entity/bot/agent, list/arguments)
	..(master, agent.host_node, agent.host_node.network, master.operator)
	src.agent = agent
	src.arguments = arguments.Copy()
	dependencies += agent
	RegisterSignal(agent, COMSIG_PARENT_QDELETING, TYPE_PROC_REF(/datum/netrun_request/delivery, on_dependency_deleted))
	operation.capture(src.arguments)

/datum/netrun_request/agent_control/Destroy()
	agent = null
	arguments = null
	return ..()

/datum/netrun_request/agent_control/execute()
	if(QDELETED(agent) || agent.netrun_owner_console() != console || agent.host_node != node || sender != console.operator || console.is_locked())
		return reject("Агент, владелец или место назначения изменились.")
	node.join_network()
	var/datum/netrun_path_tree/tree = console.make_path_tree()
	var/valid = node.network == sent_network && node.is_online() && console.can_route(node, tree)
	if(valid)
		operation.receive(tree.addresses_to(node.address))
	qdel(tree)
	if(!valid)
		return reject("Действующего маршрута к агенту больше нет.")
	return console.apply_agent_order(agent, arguments)

/// Returning an agent is a real in-flight file. The live process retains everything until acceptance.
/datum/netrun_request/agent_recall
	parent_type = /datum/netrun_request/delivery
	var/mob/camera/netrun_entity/bot/agent
	var/datum/component/netrun_node/owner_node
	operation_kind = "file"
	operation_label = "Возврат агента"

/datum/netrun_request/agent_recall/New(datum/netrun_console/master, mob/camera/netrun_entity/bot/agent, datum/component/netrun_node/owner_node)
	var/datum/netrun_packet_context/context = new("file", "Возврат агента [agent.real_name]", agent.host_node.address, owner_node.address, "agent_recall", master)
	..(master, agent.host_node, agent.host_node.network, master.operator, null, context)
	src.agent = agent
	src.owner_node = owner_node
	for(var/datum/dependency as anything in list(agent, owner_node))
		if(dependency in dependencies)
			continue
		dependencies += dependency
		RegisterSignal(dependency, COMSIG_PARENT_QDELETING, TYPE_PROC_REF(/datum/netrun_request/delivery, on_dependency_deleted))

/datum/netrun_request/agent_recall/Destroy()
	if(!QDELETED(agent))
		agent.return_pending = FALSE
		agent.brain?.wake_now()
	agent = null
	owner_node = null
	return ..()

/datum/netrun_request/agent_recall/execute()
	if(QDELETED(agent) || !agent.agent_file || agent.netrun_owner_console() != console || agent.host_node != node || sender != console.operator || console.is_locked())
		return reject("Процесс или его владелец изменились до возврата.")
	var/datum/component/netrun_node/current_source = console.route_source()
	var/datum/netrun_path_tree/tree = console.make_path_tree()
	var/valid = current_source == owner_node && node.network == sent_network && node.is_online() && console.can_route(node, tree)
	if(valid)
		operation.receive(reverseRange(tree.addresses_to(node.address)))
	qdel(tree)
	if(!valid)
		return reject("Маршрут возврата агента потерян.")
	var/datum/netrun_file/file = agent.agent_file
	var/previous_size = file.size
	if(istype(file, /datum/netrun_file/bot))
		file.size = agent.program.file_size + agent.console.inventory.local_store.used()
	if(!console.store_file(file))
		file.size = previous_size
		return reject("В памяти владельца нет места для агента с его файлами.")
	if(istype(file, /datum/netrun_file/bot))
		var/datum/netrun_file/bot/saved = file
		saved.remember_agent(agent)
	agent.agent_file = null
	console.log_line("Агент [agent.real_name] вернулся: [file.name] и его память сохранены.", "good")
	node.network?.add_log("Автономный процесс [agent.real_name] отозван владельцем.")
	qdel(agent)
	return TRUE

/// Agent files own recalled inventory and cosmetics; copies have independent contents.
/datum/netrun_file/bot
	var/list/datum/netrun_file/stored_files
	var/list/stored_persona
	var/stored_name
	var/stored_order
	var/stored_post
	var/stored_command
	var/stored_command_address

/datum/netrun_file/bot/Destroy()
	QDEL_LIST(stored_files)
	stored_persona = null
	return ..()

/datum/netrun_file/bot/copy()
	var/datum/netrun_file/bot/result = new(name, kind, content, size, network_id)
	result.stored_persona = stored_persona?.Copy()
	result.stored_name = stored_name
	result.stored_order = stored_order
	result.stored_post = stored_post
	result.stored_command = stored_command
	result.stored_command_address = stored_command_address
	if(!isnull(stored_files))
		result.stored_files = list()
		for(var/datum/netrun_file/file as anything in stored_files)
			result.stored_files += file.copy()
	return result

/datum/netrun_file/bot/proc/remember_agent(mob/camera/netrun_entity/bot/agent)
	stored_persona = agent.get_persona().ui_payload(FALSE)
	stored_name = agent.real_name
	stored_order = agent.brain.order
	stored_post = agent.brain.post_node()?.address
	stored_command = agent.brain.order_command
	stored_command_address = agent.brain.order_command_address
	stored_files = list()
	var/datum/netrun_file_store/store = agent.console.inventory.local_store
	for(var/datum/netrun_file/file as anything in store.files.Copy())
		store.remove(file)
		stored_files += file

/datum/netrun_file/bot/proc/restore_agent(mob/camera/netrun_entity/bot/agent)
	if(isnull(stored_files))
		return TRUE
	var/required = 0
	for(var/datum/netrun_file/file as anything in stored_files)
		required += file.size
	var/datum/netrun_file_store/store = agent.console.inventory.local_store
	if(required > store.capacity)
		return FALSE
	for(var/datum/netrun_file/file as anything in store.files.Copy())
		store.delete_file(file)
	for(var/datum/netrun_file/file as anything in stored_files)
		store.insert(file)
	stored_files = null
	var/datum/netrun_persona/profile = agent.get_persona()
	if(stored_persona)
		profile.avatar = stored_persona["avatar"]
		profile.accent = stored_persona["accent"]
		profile.tagline = stored_persona["tagline"]
		profile.alias = stored_persona["alias"]
		profile.theme = stored_persona["theme"]
	if(stored_name)
		agent.set_net_name(stored_name)
	agent.brain.order = stored_order
	var/datum/component/netrun_node/post = SSnetrun.find_node(stored_post)
	agent.brain.order_node_ref = post ? WEAKREF(post) : null
	agent.brain.order_command = stored_command
	agent.brain.order_command_address = stored_command_address
	var/datum/component/netrun_node/target = SSnetrun.find_node(stored_command_address)
	if(stored_order == "command" && target && (stored_command in target.all_command_ids()))
		agent.brain.push_goal(new /datum/netrun_bot_goal/command(agent.brain, target, stored_command))
	size = agent.program.file_size
	return TRUE

// MARK: Население

/datum/controller/subsystem/netrun
	var/list/mob/camera/netrun_entity/bot/bots = list()
	/// Unit tests spawn their own bots.
	var/bots_enabled = NETRUN_AUTONOMOUS_CONTENT
	var/next_bot_census = 0
	var/rogue_wave_at = 0
	var/police_respawn_at = 0
	var/custodian_respawn_at = 0
	/// Spawn candidates are addresses cached at a topology boundary, not polled every census.
	var/list/bot_spawn_pools
	var/bot_spawn_revision = -1
	var/bot_spawn_index_builds = 0
	var/bot_spawn_candidate_checks = 0

/datum/controller/subsystem/netrun/proc/spawn_bot(program_id, datum/component/netrun_node/node, datum/netrun_console/owner)
	if(QDELETED(node) || QDELETED(node.parent) || !node.is_online() || length(bots) >= NETRUN_MAX_BOTS)
		return null
	var/turf/spot = node.physical_turf()
	if(!spot)
		return null
	var/mob/camera/netrun_entity/bot/bot = new(spot, node, program_id, owner)
	return QDELETED(bot) ? null : bot

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

/datum/controller/subsystem/netrun/proc/count_bot_faction(faction)
	. = 0
	for(var/mob/camera/netrun_entity/bot/bot as anything in bots)
		if(!QDELETED(bot) && bot.net_faction == faction)
			.++

/// Department key of a LAN, from the area its APC serves.
/proc/netrun_network_department(datum/netrun_network/network)
	return network?.area ? netrun_department_key(network.area) : null

/// A stationary, online, unfortified node of the given departments (any station LAN when null).
/datum/controller/subsystem/netrun/proc/bot_spawn_node(list/departments)
	var/datum/netrun_topology/graph = ensure_topology()
	if(!bot_spawn_pools || bot_spawn_revision != graph.revision)
		bot_spawn_revision = graph.revision
		bot_spawn_index_builds++
		bot_spawn_pools = list("all" = list())
		for(var/id in networks)
			var/datum/netrun_network/network = networks[id]
			if(network.isolated)
				continue
			var/department = netrun_network_department(network) || "general"
			if(!bot_spawn_pools[department])
				bot_spawn_pools[department] = list()
			for(var/datum/component/netrun_node/node as anything in network.nodes)
				if(QDELETED(node) || QDELETED(node.parent) || node.is_dynamic())
					continue
				bot_spawn_pools["all"] += node.address
				bot_spawn_pools[department] += node.address
	var/list/pools = departments || list("all")
	for(var/attempt in 1 to 16)
		var/list/candidates = bot_spawn_pools[pick(pools)]
		if(!length(candidates))
			continue
		var/datum/component/netrun_node/node = find_node(pick(candidates))
		bot_spawn_candidate_checks++
		if(!QDELETED(node) && !QDELETED(node.parent) && !node.fortress && !node.is_dynamic() && node.is_online())
			return node
	return null

/// Visitors enter at a functioning external network relay. Without one they can
/// arrive only on a low-security public/cargo endpoint, never inside a closed department.
/datum/controller/subsystem/netrun/proc/bot_entry_node()
	var/datum/netrun_topology/graph = ensure_topology()
	var/list/entries = list()
	for(var/address in graph.registered_relays)
		var/datum/component/netrun_node/node = graph.registered_relays[address]
		if(!QDELETED(node) && !node.network?.isolated && !node.fortress && node.is_online())
			entries += node
	if(length(entries))
		return pick(entries)
	var/datum/component/netrun_node/fallback = bot_spawn_node(list("general", "cargo"))
	return fallback?.network?.security <= 2 ? fallback : null

/// Housekeeping: keep the police and maintenance processes alive, let rogue raiders appear.
/datum/controller/subsystem/netrun/proc/maintain_bots()
	if(!bots_enabled || world.time < next_bot_census)
		return
	next_bot_census = world.time + 20 SECONDS
	for(var/mob/camera/netrun_entity/bot/bot as anything in bots.Copy())
		if(QDELETED(bot))
			bots -= bot
	if(!rogue_wave_at)
		rogue_wave_at = world.time + rand(60 SECONDS, 120 SECONDS)
	if(count_bots(NETRUN_BOT_POLICE) < NETRUN_POLICE_QUOTA && world.time >= police_respawn_at)
		var/datum/component/netrun_node/node = bot_entry_node()
		var/mob/camera/netrun_entity/bot/police = spawn_bot(NETRUN_BOT_POLICE, node)
		police?.host_node?.network?.add_log("На дежурство заступил процесс сетевой полиции [police.real_name].")
		if(police)
			return
	if(world.time >= custodian_respawn_at && count_bots(NETRUN_BOT_CUSTODIAN) < NETRUN_CUSTODIAN_QUOTA)
		spawn_custodian()
	if(world.time >= rogue_wave_at)
		rogue_wave_at = world.time + rand(90 SECONDS, 180 SECONDS)
		spawn_visitor_wave()

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
