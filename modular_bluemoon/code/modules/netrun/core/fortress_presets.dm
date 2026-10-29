/**
 * Готовые крепости важных узлов. Шаблон описывает модули и типы машин, которые он
 * укрепляет; модули шаблона стоят сразу, без стройки. Новый шаблон - подтип.
 */
/datum/netrun_fortress_preset
	var/id
	var/name
	var/faction = NETRUN_FACTION_STATION
	/// kind -> count
	var/list/modules = list()
	var/list/target_types = list()
	/// Zero means every matching node of the station is fortified.
	var/max_instances = 0

/datum/netrun_fortress_preset/proc/matches(datum/component/netrun_node/node)
	var/atom/host = node.parent
	for(var/path in target_types)
		if(istype(host, path))
			return TRUE
	return FALSE

/datum/netrun_fortress_preset/ai_citadel
	id = "ai_citadel"
	name = "Цитадель ядра ИИ"
	modules = list(NETRUN_FORT_WALL = 3, NETRUN_FORT_GATE = 1, NETRUN_FORT_TURRET = 2, NETRUN_FORT_TRAP = 1, NETRUN_FORT_ALARM = 1, NETRUN_FORT_REGEN = 1)
	target_types = list(/mob/living/silicon/ai)

/datum/netrun_fortress_preset/rnd_archive
	id = "rnd_archive"
	name = "Архив РнД"
	modules = list(NETRUN_FORT_WALL = 2, NETRUN_FORT_TURRET = 1, NETRUN_FORT_ALARM = 1, NETRUN_FORT_VAULT = 1)
	target_types = list(/obj/machinery/rnd/server)

/datum/netrun_fortress_preset/telecomms_hub
	id = "telecomms_hub"
	name = "Узел связи"
	modules = list(NETRUN_FORT_WALL = 2, NETRUN_FORT_GATE = 1, NETRUN_FORT_TURRET = 1, NETRUN_FORT_ALARM = 1)
	target_types = list(/obj/machinery/telecomms/hub, /obj/machinery/telecomms/message_server)

/datum/netrun_fortress_preset/command_bastion
	id = "command_bastion"
	name = "Командный бастион"
	modules = list(NETRUN_FORT_WALL = 2, NETRUN_FORT_GATE = 1, NETRUN_FORT_TRAP = 1, NETRUN_FORT_ALARM = 1)
	target_types = list(/obj/machinery/computer/communications)
	max_instances = 1

/datum/netrun_fortress_preset/relay_outpost
	id = "relay_outpost"
	name = "Шлюзовая застава"
	modules = list(NETRUN_FORT_WALL = 1, NETRUN_FORT_TURRET = 1, NETRUN_FORT_ALARM = 1)
	target_types = list(/obj/machinery/ntnet_relay)

/// Underground caches defend their loot against everybody except rogue processes.
/datum/netrun_fortress_preset/stash_cache
	id = "stash_cache"
	name = "Тайник"
	faction = NETRUN_FACTION_ROGUE
	modules = list(NETRUN_FORT_WALL = 1, NETRUN_FORT_TRAP = 1, NETRUN_FORT_TURRET = 1)
	target_types = list(/obj/machinery/netrun_server/stash)

/datum/controller/subsystem/netrun
	var/list/datum/netrun_fortress_preset/fortress_presets
	var/fortress_topology_revision = -1
	/// Unit tests build presets explicitly instead of fortifying the test station.
	var/fortress_presets_enabled = NETRUN_AUTONOMOUS_CONTENT
	/// address -> TRUE: a fortress destroyed by players is never re-seeded.
	var/list/fortress_presets_seeded = list()

/datum/controller/subsystem/netrun/proc/get_fortress_preset(id)
	RETURN_TYPE(/datum/netrun_fortress_preset)
	if(!fortress_presets)
		fortress_presets = list()
		for(var/datum/netrun_fortress_preset/path as anything in subtypesof(/datum/netrun_fortress_preset))
			if(initial(path.id))
				var/datum/netrun_fortress_preset/preset = new path
				fortress_presets[preset.id] = preset
	return istext(id) ? fortress_presets[id] : null

/// Housekeeping: fortify important nodes once the published graph is complete, including later builds.
/datum/controller/subsystem/netrun/proc/initialize_fortresses()
	var/datum/netrun_topology/graph = get_topology()
	if(graph.dirty)
		return
	fortress_topology_revision = graph.revision
	if(!fortress_presets_enabled || length(fortress_presets_seeded) >= NETRUN_MAX_FORTRESS_PRESETS)
		return
	get_fortress_preset(null)
	var/list/instances = list()
	for(var/address in fortress_presets_seeded)
		var/datum/component/netrun_node/seeded = nodes_by_address[address]
		if(seeded?.fortress?.preset_id)
			instances[seeded.fortress.preset_id] = (instances[seeded.fortress.preset_id] || 0) + 1
	for(var/address in nodes_by_address)
		if(length(fortress_presets_seeded) >= NETRUN_MAX_FORTRESS_PRESETS)
			return
		if(fortress_presets_seeded[address])
			continue
		var/datum/component/netrun_node/node = nodes_by_address[address]
		if(QDELETED(node) || QDELETED(node.parent) || node.fortress || netrun_fortress_slots(node) <= 0)
			continue
		for(var/preset_id in fortress_presets)
			var/datum/netrun_fortress_preset/preset = fortress_presets[preset_id]
			if(!preset.matches(node) || (preset.max_instances && instances[preset_id] >= preset.max_instances))
				continue
			if(build_fortress_preset(node, preset_id))
				fortress_presets_seeded[address] = TRUE
				instances[preset_id] = (instances[preset_id] || 0) + 1
			break

/// Deploy a ready fortress with every module standing. Returns the existing one if the node is already fortified.
/datum/controller/subsystem/netrun/proc/build_fortress_preset(datum/component/netrun_node/node, preset_id)
	var/datum/netrun_fortress_preset/preset = get_fortress_preset(preset_id)
	if(!preset || QDELETED(node))
		return null
	if(node.fortress)
		return node.fortress
	var/datum/netrun_fortress/fortress = new(node, preset.name, preset.faction)
	fortress.preset_id = preset.id
	fortress.preset_name = preset.name
	node.fortress = fortress
	for(var/kind in preset.modules)
		for(var/i in 1 to preset.modules[kind])
			fortress.add_module(kind, TRUE)
	fortress.refresh_vault()
	node.add_log("Развёрнута крепость «[preset.name]».")
	fortress.changed()
	return fortress
