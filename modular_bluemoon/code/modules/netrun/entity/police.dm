/**
 * Сетевая полиция: станционный процесс с законным доступом ПОЛЬЗОВАТЕЛЯ во всех
 * станционных ЛВС. Обходит сеть, осматривает узлы обычными командами и работает
 * с журналом инцидентов: приходит на место, предупреждает нарушителя, при отказе
 * уйти атакует с телеграфом, отслеживает удалённый взлом и пишет рапорт СБ.
 */
/datum/netrun_bot_program/police
	id = NETRUN_BOT_POLICE
	name = "Сетевая полиция"
	desc = "Станционный процесс правопорядка: патрулирует всю сеть, расследует инциденты и обезвреживает нарушителей."
	faction = NETRUN_FACTION_STATION
	sanctioned = TRUE
	max_integrity = 160
	programs = list("assault", "strike", "blackout", "barrier", "patch")
	name_prefix = "NETPOL"
	avatar = "eye"
	accent = "cyan"
	tagline = "служит и защищает сеть"
	console_type = /datum/netrun_console/entity/bot/police
	think_idle = 3 SECONDS
	flee_ratio = 0.15

/datum/netrun_bot_program/police/on_spawn(mob/camera/netrun_entity/bot/bot)
	bot.brain.listen_incidents()

/datum/netrun_bot_program/police/plan(datum/netrun_bot_brain/brain)
	var/datum/netrun_incident/incident = brain.claimed_incident() || brain.claim_incident()
	if(incident)
		brain.push_goal(new /datum/netrun_bot_goal/investigate(brain, incident))
		return
	brain.push_goal(new /datum/netrun_bot_goal/police_patrol(brain))

/// Legal USER on every station LAN; never ROOT, never on isolated segments.
/datum/netrun_console/entity/bot/police

/datum/netrun_console/entity/bot/police/New(atom/host, origin)
	. = ..()
	intrusion.trace_mult = 0

/datum/netrun_console/entity/bot/police/compute_legit_node_level(datum/component/netrun_node/node, fresh = FALSE)
	. = ..()
	if(node?.network && !node.network.isolated)
		. = max(., NETRUN_ACCESS_USER)

/datum/netrun_console/entity/bot/police/legit_network_level(datum/netrun_network/network, fresh = FALSE)
	. = ..()
	if(network && !network.isolated)
		. = max(., NETRUN_ACCESS_GUEST)

// MARK: Инциденты

/datum/netrun_bot_brain
	var/datum/weakref/incident_ref
	/// weakref(process) -> world.time of the warning.
	var/list/warned = list()
	var/listening_incidents = FALSE

/datum/netrun_bot_brain/proc/listen_incidents()
	if(listening_incidents)
		return
	listening_incidents = TRUE
	RegisterSignal(SSnetrun, COMSIG_NETRUN_INCIDENT_REPORTED, PROC_REF(on_incident_reported))

/datum/netrun_bot_brain/proc/on_incident_reported(datum/source, datum/netrun_incident/incident)
	SIGNAL_HANDLER
	if(QDELETED(owner) || claimed_incident() || incident.severity < NETRUN_INCIDENT_MEDIUM)
		return
	var/datum/claimer = incident.claimed_by()
	if(!claimer || claimer == src)
		wake_now()

/datum/netrun_bot_brain/proc/claimed_incident()
	var/datum/netrun_incident/incident = incident_ref?.resolve()
	if(incident && incident.is_open() && incident.claimed_by() == src)
		return incident
	incident_ref = null
	return null

/// The most severe open incident nobody else handles; single low reports wait for a repeat.
/datum/netrun_bot_brain/proc/claim_incident()
	for(var/datum/netrun_incident/incident as anything in SSnetrun.open_incidents())
		var/datum/claimer = incident.claimed_by()
		if(claimer && claimer != src)
			continue
		if(incident.severity < NETRUN_INCIDENT_MEDIUM && incident.reports < 2)
			continue
		if(incident.address && is_blacklisted(incident.address))
			continue
		incident.claim(src)
		incident_ref = WEAKREF(incident)
		return incident
	return null

/// Close the record and file a report with the security LAN and the NTnet IDS.
/datum/netrun_bot_brain/proc/police_report(datum/netrun_incident/incident, resolution)
	if(!incident || incident.closed)
		return
	incident.close(resolution)
	incident_ref = null
	var/text = "[owner.real_name]: [incident.id] ([incident.kind])[incident.address ? " в узле [incident.address]" : ""]: [resolution]."
	SSnetrun.ntnet_log(text, TRUE)
	for(var/id in SSnetrun.networks)
		var/datum/netrun_network/network = SSnetrun.networks[id]
		if(!network.isolated && netrun_network_department(network) == "security")
			network.add_log(text, TRUE)
	var/datum/netrun_file_store/store = owner.console.inventory.local_store
	var/list/reports = list()
	for(var/datum/netrun_file/file as anything in store.files)
		if(file.kind == NETRUN_FILE_TEXT && findtext(file.name, "report-") == 1)
			reports += file
	while(length(reports) >= 4)
		var/datum/netrun_file/oldest = reports[1]
		reports.Cut(1, 2)
		store.delete_file(oldest)
	owner.console.store_file(new /datum/netrun_file("report-[lowertext(incident.id)].txt", NETRUN_FILE_TEXT, "[STATION_TIME_TIMESTAMP("hh:mm:ss", world.time)] [text]\nПодозреваемый: [incident.suspect_name || "не установлен"]. Отчётов: [incident.reports]."))

/// A suspect is a rogue process, or a process without USER here that is a real threat.
/datum/netrun_bot_brain/proc/is_suspect(mob/camera/netrun_entity/entity, datum/component/netrun_node/node)
	if(!istype(entity) || entity == owner || QDELETED(entity) || QDELETED(entity.console))
		return FALSE
	if(entity.netrun_faction() == NETRUN_FACTION_ROGUE)
		return TRUE
	if(!entity.defense_threat())
		return FALSE
	return entity.console.node_level(node) < NETRUN_ACCESS_USER

/datum/netrun_bot_brain/proc/find_suspect(datum/component/netrun_node/node, datum/netrun_incident/incident)
	var/datum/named = incident?.suspect()
	if(istype(named, /mob/camera/netrun_entity))
		var/mob/camera/netrun_entity/entity = named
		if(entity.host_node == node && is_suspect(entity, node))
			return entity
	for(var/mob/camera/netrun_entity/entity as anything in node.entities)
		if(is_suspect(entity, node))
			return entity
	return null

/// Rogue processes are engaged at once; a player process is warned and gets five seconds to leave.
/datum/netrun_bot_brain/proc/confront(mob/camera/netrun_entity/suspect, datum/component/netrun_node/node)
	if(istype(suspect, /mob/camera/netrun_entity/bot))
		mark_enemy(suspect)
		return
	var/datum/weakref/reference = WEAKREF(suspect)
	var/warned_at = warned[reference]
	if(!warned_at)
		warned[reference] = world.time
		while(length(warned) > 16)
			warned.Cut(1, 2)
		owner.console.signal_entity(node, REF(suspect), "Сетевая полиция [owner.real_name]: несанкционированный процесс в узле [node.address]. Покиньте узел в течение 5 секунд, иначе процесс будет обезврежен.")
		to_chat(suspect, span_warning("Сетевая полиция [owner.real_name] требует покинуть узел [node.address] в течение 5 секунд."))
		return
	if(world.time - warned_at >= 5 SECONDS)
		mark_enemy(suspect)

/// Remote breaches against this node or its LAN are traced back while the police stands here.
/datum/netrun_bot_brain/proc/counter_trace(datum/component/netrun_node/node)
	. = FALSE
	for(var/datum/netrun_console/console as anything in SSnetrun.currentbreaches)
		if(QDELETED(console) || console == owner.console || console.is_locked())
			continue
		var/datum/netrun_breach/breach = console.intrusion.breach
		if(!breach)
			continue
		if(breach.target_id != node.address && !(breach.target_kind == "network" && node.network && breach.target_id == node.network.id))
			continue
		console.add_trace(8)
		console.log_line("Сетевая полиция [owner.real_name] отслеживает ваш взлом: трассировка растёт.", "bad")
		. = TRUE
	if(.)
		SSnetrun.post_event("trace", null, node.address)

// MARK: Обход сети

/datum/controller/subsystem/netrun
	/// LAN id -> world.time of the last police inspection, shared by all officers.
	var/list/police_inspected = list()

/// The least recently inspected reachable station LAN; recent activity draws the officer first.
/datum/netrun_bot_brain/proc/police_destination()
	var/datum/netrun_console/console = owner.console
	var/datum/netrun_network/best
	var/best_time = INFINITY
	for(var/id in SSnetrun.networks)
		var/datum/netrun_network/network = SSnetrun.networks[id]
		if(network.isolated || !length(network.nodes) || !console.can_reach(network))
			continue
		var/inspected = SSnetrun.police_inspected[id] || 0
		if(inspected < best_time)
			best = network
			best_time = inspected
	if(!best)
		return null
	SSnetrun.police_inspected[best.id] = world.time
	var/list/active = list()
	var/list/quiet = list()
	for(var/datum/component/netrun_node/node as anything in best.nodes)
		if(QDELETED(node) || node.is_dynamic() || !node.is_online() || is_blacklisted(node.address))
			continue
		if(world.time - node.last_activity < 30 SECONDS)
			active += node
		else
			quiet += node
	if(length(active))
		return pick(active)
	return length(quiet) ? pick(quiet) : null

/// Read the node journal with the ordinary command and look for repeated refusals.
/datum/netrun_bot_brain/proc/inspect(datum/component/netrun_node/node)
	owner.console.run_command(node, "packet_log")
	var/list/rejects = list()
	for(var/list/entry as anything in node.packet_logs)
		if(entry["phase"] != "REJECT" || world.time - entry["time"] > 60 SECONDS || !entry["from"])
			continue
		rejects[entry["from"]] = (rejects[entry["from"]] || 0) + 1
	for(var/address in rejects)
		if(rejects[address] >= 3)
			var/datum/component/netrun_node/source = SSnetrun.find_node(address)
			if(source && source != node)
				SSnetrun.report_incident("intrusion", source, null, NETRUN_INCIDENT_LOW, "Серия отклонённых пакетов с узла [address].")
	var/mob/camera/netrun_entity/suspect = find_suspect(node, null)
	if(suspect)
		SSnetrun.report_incident(suspect.netrun_faction() == NETRUN_FACTION_ROGUE ? "rogue" : "intrusion", node, suspect, NETRUN_INCIDENT_MEDIUM, "[owner.real_name] застал процесс [suspect.real_name] без доступа.")

/datum/netrun_bot_goal/police_patrol
	name = "обход сети"
	var/datum/weakref/target_ref
	var/target_name

/datum/netrun_bot_goal/police_patrol/New(datum/netrun_bot_brain/brain)
	..(brain, 2 MINUTES)

/datum/netrun_bot_goal/police_patrol/describe()
	return target_name ? "обход: [target_name]" : name

/datum/netrun_bot_goal/police_patrol/advance()
	// A fresh serious incident interrupts the round.
	if(brain.claimed_incident() || brain.claim_incident())
		return NETRUN_BOT_GOAL_DONE
	var/datum/component/netrun_node/target = target_ref?.resolve()
	if(!target)
		target = brain.police_destination()
		if(!target)
			return NETRUN_BOT_GOAL_FAILED
		target_ref = WEAKREF(target)
		target_name = "[target.network?.short_name] · [target.get_name()]"
	brain.state = "обход сети"
	switch(approach(target))
		if(NETRUN_BOT_MOVE_ARRIVED)
			brain.inspect(target)
			return NETRUN_BOT_GOAL_DONE
		if(NETRUN_BOT_MOVE_BLOCKED)
			return NETRUN_BOT_GOAL_FAILED
	return NETRUN_BOT_GOAL_CONTINUE

/datum/netrun_bot_goal/investigate
	name = "расследование"
	var/datum/weakref/incident_ref
	var/incident_id
	var/scanned = FALSE
	var/arrived_at = 0
	var/engaged = FALSE

/datum/netrun_bot_goal/investigate/New(datum/netrun_bot_brain/brain, datum/netrun_incident/incident)
	..(brain, 3 MINUTES)
	incident_ref = WEAKREF(incident)
	incident_id = incident.id

/datum/netrun_bot_goal/investigate/describe()
	return "расследование [incident_id]"

/datum/netrun_bot_goal/investigate/advance()
	var/datum/netrun_incident/incident = incident_ref?.resolve()
	if(!incident || !incident.is_open())
		return NETRUN_BOT_GOAL_DONE
	var/datum/component/netrun_node/node = incident.node()
	if(!node)
		brain.police_report(incident, "место происшествия недоступно")
		return NETRUN_BOT_GOAL_DONE
	if(brain.owner.host_node != node)
		if(approach(node) == NETRUN_BOT_MOVE_BLOCKED)
			brain.police_report(incident, "нет пути к месту происшествия")
			return NETRUN_BOT_GOAL_FAILED
		return NETRUN_BOT_GOAL_CONTINUE
	brain.state = "расследование"
	var/datum/netrun_console/console = brain.owner.console
	if(!scanned)
		if(world.time >= console.next_command)
			console.run_command(node, "scan")
			scanned = TRUE
			arrived_at = world.time
		return NETRUN_BOT_GOAL_CONTINUE
	if(brain.counter_trace(node))
		engaged = TRUE
		return NETRUN_BOT_GOAL_CONTINUE
	var/mob/camera/netrun_entity/suspect = brain.find_suspect(node, incident)
	if(suspect)
		engaged = TRUE
		arrived_at = world.time
		brain.confront(suspect, node)
		return NETRUN_BOT_GOAL_CONTINUE
	if(world.time - arrived_at < 8 SECONDS)
		return NETRUN_BOT_GOAL_CONTINUE
	brain.police_report(incident, engaged ? "нарушитель обезврежен или покинул узел" : "нарушений не обнаружено")
	return NETRUN_BOT_GOAL_DONE
