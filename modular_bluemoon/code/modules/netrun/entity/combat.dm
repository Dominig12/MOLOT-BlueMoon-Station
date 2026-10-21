/**
 * Сетевой бой. Участники - сущности (мобы) и ICE (датумы), стоящие в одном узле.
 * Оружие - боевые программы ("карточки") из памяти консоли: запуск по цели в узле,
 * у каждой своя перезарядка, часть расходуется. ICE бьёт в ответ на своём тике.
 *
 * Консоль ведёт бой в своём «боевом узле»: у сущности это узел-носитель, у терминала
 * или деки - выбранный узел, к которому есть маршрут и доступ.
 */
/datum/netrun_console
	/// id программы = время, когда она снова доступна
	var/list/program_cd = list()
	/// Combat reaction is independent from a queued remote machine operation.
	var/next_program = 0

/// Узел, в котором эта консоль может вести бой.
/datum/netrun_console/proc/combat_node()
	var/datum/component/netrun_node/node = selected_node()
	if(node && can_route(node) && node.is_online(node != jack) && node_level(node) >= NETRUN_ACCESS_GUEST)
		return node
	return null

/datum/netrun_console/entity/combat_node()
	var/mob/camera/netrun_entity/entity = host
	return entity?.host_node

/// Собственная сущность консоли (для программ на себя). У терминала её нет.
/datum/netrun_console/proc/combat_self()
	return null

/datum/netrun_console/entity/combat_self()
	return host

// MARK: Описание участников

/proc/netrun_combatant_integrity(thing)
	if(istype(thing, /mob/camera/netrun_entity))
		var/mob/camera/netrun_entity/entity = thing
		return list("cur" = round(entity.integrity), "max" = entity.max_integrity, "stunned" = entity.is_stunned(), "shielded" = world.time < entity.combat_shield_until)
	if(istype(thing, /datum/netrun_ice))
		var/datum/netrun_ice/ice = thing
		return list("cur" = round(ice.integrity), "max" = ice.max_integrity, "stunned" = ice.is_stunned(), "shielded" = world.time < ice.combat_shield_until)
	return null

/proc/netrun_combatant_name(thing)
	if(istype(thing, /mob/camera/netrun_entity))
		var/mob/camera/netrun_entity/entity = thing
		return entity.combat_name()
	if(istype(thing, /datum/netrun_ice))
		var/datum/netrun_ice/ice = thing
		return ice.combat_name()
	return "?"

/// Список целей в боевом узле консоли (кроме себя).
/datum/netrun_console/proc/combat_targets()
	var/datum/component/netrun_node/node = combat_node()
	. = list()
	if(!node)
		return
	var/self = combat_self()
	for(var/mob/camera/netrun_entity/entity as anything in node.entities)
		if(entity == self || QDELETED(entity))
			continue
		var/list/hp = netrun_combatant_integrity(entity)
		. += list(list(
			"ref" = REF(entity),
			"name" = entity.combat_name(),
			"shielded" = hp["shielded"],
			"kind" = "entity",
			"hostile" = FALSE,
			"integrity" = hp["cur"],
			"max_integrity" = hp["max"],
			"stunned" = hp["stunned"],
		))
	for(var/datum/netrun_ice/ice as anything in node.netrun_ice)
		if(QDELETED(ice))
			continue
		var/list/hp = netrun_combatant_integrity(ice)
		. += list(list(
			"ref" = REF(ice),
			"name" = ice.combat_name(),
			"shielded" = hp["shielded"],
			"kind" = "ice",
			"hostile" = TRUE,
			"integrity" = hp["cur"],
			"max_integrity" = hp["max"],
			"stunned" = hp["stunned"],
			"programs" = ice.program_payload(),
			"casting" = ice.casting_payload(),
		))

/// Доступные боевые программы и их готовность: сперва встроенная атака процесса, затем из памяти.
/datum/netrun_console/proc/builtin_program_ids()
	return combat_self() ? list("sting", "shell") : list()

/datum/netrun_console/proc/combat_programs()
	. = list()
	if(combat_self())
		for(var/builtin_id in builtin_program_ids())
			var/datum/netrun_program/builtin = SSnetrun.get_program(builtin_id)
			if(!builtin)
				continue
			var/list/entry = builtin.ui_entry()
			entry["uid"] = "builtin:[builtin_id]"
			entry["builtin"] = TRUE
			entry["ready_in"] = max(0, round(((program_cd[builtin.id] || 0) - world.time) / (1 SECONDS), 0.1))
			. += list(entry)
	for(var/datum/netrun_file/file as anything in all_files())
		if(file.kind != NETRUN_FILE_PROGRAM)
			continue
		var/datum/netrun_program/program = SSnetrun.get_program(file.content)
		if(!program || program.role == NETRUN_PROGRAM_TRACE)
			continue
		var/ready_at = program_cd[program.id] || 0
		var/list/entry = program.ui_entry()
		entry["uid"] = file.uid
		entry["ready_in"] = max(0, round((ready_at - world.time) / (1 SECONDS), 0.1))
		. += list(entry)

/datum/netrun_console/proc/combat_payload()
	var/datum/component/netrun_node/node = combat_node()
	if(!node)
		return null
	var/self = combat_self()
	var/list/self_hp = self ? netrun_combatant_integrity(self) : null
	return list(
		"node" = node.address,
		"node_name" = node.get_name(),
		"self" = self_hp ? list("integrity" = self_hp["cur"], "max_integrity" = self_hp["max"], "stunned" = self_hp["stunned"], "shielded" = self_hp["shielded"]) : null,
		"targets" = combat_targets(),
		"programs" = combat_programs(),
		"incoming" = incoming_programs(),
		"loot" = salvage_payload(),
	)

/datum/netrun_console/proc/incoming_programs()
	. = list()
	for(var/datum/netrun_ice/ice as anything in SSnetrun.ice_processes)
		if(QDELETED(ice) || !ice.pending_program)
			continue
		var/datum/target = ice.pending_target()
		if(target != src && target != combat_self())
			continue
		var/list/entry = ice.casting_payload()
		entry["source"] = ice.name
		. += list(entry)

/// Remote runners only need live attack warnings during a puzzle, without
/// rebuilding the hidden map or querying all target permissions on every click.
/datum/netrun_console/proc/breach_combat_payload()
	if(combat_self())
		return combat_payload()
	return list("node" = breach.target_id, "node_name" = breach.target_name,
		"self" = null, "targets" = list(), "programs" = list(),
		"incoming" = incoming_programs(), "loot" = list())

/datum/netrun_console/proc/salvage_payload()
	. = list()
	var/datum/component/netrun_node/node = combat_node()
	if(!combat_self() || !node)
		return
	for(var/datum/netrun_file/file as anything in node.salvage)
		. += list(file.ui_entry())

/datum/netrun_console/proc/recover_salvage(uid)
	var/mob/camera/netrun_entity/entity = combat_self()
	var/datum/component/netrun_node/node = entity?.host_node
	if(!istype(entity) || !node?.is_online() || is_locked() || entity.is_stunned())
		return FALSE
	for(var/datum/netrun_file/file as anything in node.salvage)
		if(file.uid != uid)
			continue
		if(!store_file(file))
			log_line("Нет места для [file.name]. Освободите память.", "bad")
			return FALSE
		node.salvage -= file
		log_line("Получено из обломков: [file.name].", "good")
		return TRUE
	return FALSE

// MARK: Применение программ

/datum/netrun_console/proc/program_use(uid, target_ref)
	if(is_locked() || world.time < next_program)
		return FALSE
	// Встроенная атака не хранится в файле и не расходуется.
	var/builtin = findtext("[uid]", "builtin:") == 1
	var/datum/netrun_file/file
	var/datum/netrun_program/program
	if(builtin)
		var/id = copytext("[uid]", length("builtin:") + 1)
		if(!(id in builtin_program_ids()))
			return FALSE
		program = SSnetrun.get_program(id)
		if(!program || !combat_self())
			return FALSE
	else
		file = find_local_file(uid)
		if(!file || file.kind != NETRUN_FILE_PROGRAM)
			return FALSE
		program = SSnetrun.get_program(file.content)
	if(!program || program.role == NETRUN_PROGRAM_TRACE)
		return FALSE
	if(world.time < (program_cd[program.id] || 0))
		log_line("[program.name]: идёт перезарядка.", "bad")
		return FALSE
	var/datum/component/netrun_node/node = combat_node()
	if(!node)
		log_line("Нет боевого контакта: выберите доступный узел с целью.", "bad")
		return FALSE
	var/self = combat_self()
	if(istype(self, /mob/camera/netrun_entity))
		var/mob/camera/netrun_entity/own = self
		if(own.is_stunned())
			log_line("Ваш процесс оглушён и не может запускать программы.", "bad")
			return FALSE
	var/target
	if(program.needs_target)
		target = locate(target_ref)
		if(!netrun_combatant_in_node(target, node) || target == self)
			log_line("Цель недоступна в этом узле.", "bad")
			return FALSE
	else
		target = self
		if(!target)
			log_line("[program.name]: нужна собственная сущность в сети.", "bad")
			return FALSE
	next_program = world.time + 0.5 SECONDS
	program_cd[program.id] = world.time + program.cooldown
	apply_program_effect(program, target, node)
	if(program.trace)
		add_trace(program.trace)
	SSnetrun.post_event("intrusion", node.network?.id, node.address)
	if(program.consumable)
		delete_local_file(file)
		log_line("Карточка [program.name] израсходована.", "average")
	return TRUE

/proc/netrun_combatant_in_node(thing, datum/component/netrun_node/node)
	if(istype(thing, /mob/camera/netrun_entity))
		var/mob/camera/netrun_entity/entity = thing
		return entity.host_node == node
	if(istype(thing, /datum/netrun_ice))
		var/datum/netrun_ice/ice = thing
		return ice.node == node
	return FALSE

/datum/netrun_console/proc/apply_program_effect(datum/netrun_program/program, target, datum/component/netrun_node/node)
	var/target_name = netrun_combatant_name(target)
	netrun_apply_program(program, target, src)
	switch(program.role)
		if(NETRUN_PROGRAM_ATTACK)
			log_line("[program.name] -> [target_name]: урон [program.power].", "good")
		if(NETRUN_PROGRAM_STUN)
			log_line("[program.name] -> [target_name]: цель оглушена.", "good")
		if(NETRUN_PROGRAM_SHIELD)
			log_line("[program.name]: защитный контур поднят.", "good")
		if(NETRUN_PROGRAM_REPAIR)
			log_line("[program.name]: целостность восстановлена.", "good")
	node.touch()
	node.add_log("[log_source()]: запущена программа [program.name].")

// MARK: Диспетчеры эффектов (сущность или ICE)

/proc/netrun_combatant_hit(thing, amount, reason, datum/netrun_console/attacker)
	if(istype(thing, /mob/camera/netrun_entity))
		var/mob/camera/netrun_entity/entity = thing
		entity.apply_damage(amount, reason, attacker)
	else if(istype(thing, /datum/netrun_ice))
		var/datum/netrun_ice/ice = thing
		ice.apply_damage(amount, reason, attacker)

/proc/netrun_combatant_stun(thing, duration)
	if(istype(thing, /mob/camera/netrun_entity))
		var/mob/camera/netrun_entity/entity = thing
		entity.apply_stun(duration)
	else if(istype(thing, /datum/netrun_ice))
		var/datum/netrun_ice/ice = thing
		ice.apply_stun(duration)

/proc/netrun_combatant_shield(thing, pct, duration)
	if(istype(thing, /mob/camera/netrun_entity))
		var/mob/camera/netrun_entity/entity = thing
		entity.apply_shield(pct, duration)
	else if(istype(thing, /datum/netrun_ice))
		var/datum/netrun_ice/ice = thing
		ice.apply_shield(pct, duration)

/proc/netrun_combatant_heal(thing, amount)
	if(istype(thing, /mob/camera/netrun_entity))
		var/mob/camera/netrun_entity/entity = thing
		entity.apply_heal(amount)
	else if(istype(thing, /datum/netrun_ice))
		var/datum/netrun_ice/ice = thing
		ice.apply_heal(amount)
