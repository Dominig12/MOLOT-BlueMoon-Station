/// Relations and visitor pools are data, shared by combat, population and UI.
/datum/netrun_faction
	var/id
	var/name
	var/color = "#9ba8b7"
	var/list/enemies = list()
	var/arrival_weight = 0
	var/list/visitors = list()

/datum/netrun_faction/proc/hostile_to(other)
	if(!other || other == id)
		return FALSE
	var/datum/netrun_faction/faction = SSnetrun.get_netrun_faction(other)
	return (other in enemies) || (id in faction?.enemies)

/datum/netrun_faction/rogue
	id = NETRUN_FACTION_ROGUE
	name = "Дикие процессы"
	color = "#ed7687"
	enemies = list(NETRUN_FACTION_STATION, NETRUN_FACTION_OWNER, "redshift", "collective", "archivists")
	arrival_weight = 2
	visitors = list(NETRUN_BOT_RAIDER, "scavenger")

/datum/netrun_faction/station
	id = NETRUN_FACTION_STATION
	name = "Защита станции"
	color = "#72ddea"

/datum/netrun_faction/private
	id = NETRUN_FACTION_OWNER
	name = "Частные агенты"
	color = "#77d9ad"

/datum/netrun_faction/redshift
	id = "redshift"
	name = "Красное смещение"
	color = "#f18f65"
	enemies = list(NETRUN_FACTION_STATION, NETRUN_FACTION_OWNER, "collective", "archivists")
	arrival_weight = 3
	visitors = list("redshift_raider", "redshift_hacker")

/datum/netrun_faction/collective
	id = "collective"
	name = "Осколочный коллектив"
	color = "#b7a0ff"
	enemies = list("redshift")
	arrival_weight = 3
	visitors = list("collective_guard")

/datum/netrun_faction/archivists
	id = "archivists"
	name = "Вольный архив"
	color = "#d5c77d"
	enemies = list("redshift")
	arrival_weight = 2
	visitors = list("archive_collector")

/datum/controller/subsystem/netrun
	var/list/netrun_factions

/datum/controller/subsystem/netrun/proc/get_netrun_faction(id)
	RETURN_TYPE(/datum/netrun_faction)
	if(!netrun_factions)
		netrun_factions = list()
		for(var/path in subtypesof(/datum/netrun_faction))
			var/datum/netrun_faction/faction = new path
			if(faction.id)
				netrun_factions[faction.id] = faction
			else
				qdel(faction)
	return netrun_factions[id]

/datum/controller/subsystem/netrun/proc/count_network_visitors()
	. = 0
	for(var/mob/camera/netrun_entity/bot/bot as anything in bots)
		if(!QDELETED(bot) && !bot.launched_by_owner && get_netrun_faction(bot.net_faction)?.arrival_weight)
			.++

/// At most two arrivals per due wave, through the same real entry points.
/datum/controller/subsystem/netrun/proc/spawn_visitor_wave()
	get_netrun_faction(null)
	for(var/index in 1 to 2)
		if(count_network_visitors() >= 8 || length(bots) >= NETRUN_MAX_BOTS)
			break
		var/list/pool = list()
		for(var/id in netrun_factions)
			var/datum/netrun_faction/faction = netrun_factions[id]
			if(faction.arrival_weight && count_bot_faction(id) < 3)
				pool[id] = faction.arrival_weight
		if(!length(pool))
			break
		var/datum/netrun_faction/faction = get_netrun_faction(pickweight(pool))
		var/mob/camera/netrun_entity/bot/visitor = spawn_bot(pick(faction.visitors), bot_entry_node())
		if(visitor && faction.hostile_to(NETRUN_FACTION_STATION))
			report_incident("rogue", visitor.host_node, visitor, NETRUN_INCIDENT_MEDIUM, "Вторжение: [faction.name], процесс [visitor.real_name].")

/datum/netrun_bot_program/raider/redshift
	id = "redshift_raider"
	name = "Налётчик Красного смещения"
	faction = "redshift"
	name_prefix = "RIFT"
	accent = "rose"
	programs = list("strike", "blackout", "barrier")
	max_integrity = 100
	lifetime = 6 MINUTES

/datum/netrun_bot_program/hacker/redshift
	id = "redshift_hacker"
	name = "Диверсант Красного смещения"
	faction = "redshift"
	name_prefix = "WRAITH"
	file_size = 0
	lifetime = 5 MINUTES

/datum/netrun_bot_program/raider/collective
	id = "collective_guard"
	name = "Страж Осколочного коллектива"
	faction = "collective"
	name_prefix = "SHARD"
	accent = "violet"
	programs = list("strike", "barrier", "patch")
	lifetime = 7 MINUTES

/datum/netrun_bot_program/scavenger/archivist
	id = "archive_collector"
	name = "Собиратель Вольного архива"
	faction = "archivists"
	name_prefix = "SCRIBE"
	accent = "amber"
	programs = list("blackout", "patch")
	lifetime = 6 MINUTES
