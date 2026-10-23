/**
 * ICE (Intrusion Countermeasure) - враждебный сетевой процесс.
 *
 * Два вида:
 *  - СТОРОЖ (sentry): закреплён за узлом, атакует несанкционированных гостей и
 *    поднимает трассировку тем, кто ломает его узел.
 *  - ОХОТНИК (hunter): путешествует по сети, преследует нарушителей по графу узлов
 *    и бьёт их, догнав. Живёт ограниченное время без целей.
 *
 * ICE - лёгкий датум, а не моб: он не смотрит камерами и не говорит, только дерётся.
 * Обрабатывается в SSnetrun.fire().
 */
/datum/netrun_ice
	var/last_netrun_tick = 0 // scheduler
	var/name = "ICE"
	var/datum/component/netrun_node/node
	var/kind = NETRUN_ICE_SENTRY
	var/integrity = 90
	var/max_integrity = 90
	/// ICE hits softer than a runner with the same program, so a dive is survivable.
	var/damage_factor = 0.78
	/// Programs are registry definitions, with the same power and cooldown as player files.
	var/list/program_ids = list("strike", "barrier", "trace")
	var/list/program_cd = list()
	var/next_attack = 0
	var/datum/netrun_program/pending_program
	var/datum/weakref/pending_target_ref
	var/datum/weakref/enemy_ref
	var/attack_at = 0
	var/next_ai = 0
	/// Сторож: узел, который он охраняет (чтобы вернуться)
	var/datum/weakref/anchor_ref
	/// Охотник: сколько тиков без цели он ещё проживёт
	var/patrol_life = 40
	/// Персистентный патруль (с начала раунда) не сворачивается без цели и роняет ключ своей ЛВС.
	var/persistent = FALSE
	var/patrol_network_id
	var/hop_cooldown = 0
	// Боевые состояния (как у сущностей)
	var/combat_stun_until = 0
	var/combat_shield_until = 0
	var/combat_shield_factor = 1

/datum/netrun_ice/New(datum/component/netrun_node/start, ice_kind)
	if(ice_kind)
		kind = ice_kind
	if(kind == NETRUN_ICE_HUNTER)
		name = "ICE-HUNTER"
		integrity = 90
		max_integrity = 90
		program_ids = list("assault", "strike", "blackout", "trace")
	else
		name = "ICE-SENTRY"
	SSnetrun.ice_processes += src
	if(start)
		enter_node(start)
		anchor_ref = WEAKREF(start)

/datum/netrun_ice/Destroy()
	cancel_program()
	SSnetrun.ice_processes -= src
	leave_node()
	anchor_ref = null
	return ..()

/datum/netrun_ice/proc/anchor()
	return anchor_ref?.resolve()

/datum/netrun_ice/proc/enter_node(datum/component/netrun_node/new_node)
	if(!new_node)
		return FALSE
	leave_node()
	node = new_node
	LAZYADD(new_node.netrun_ice, src)
	new_node.notify_changed(NETRUN_CHANGED_OCCUPANTS)
	SEND_SIGNAL(src, COMSIG_NETRUN_ICE_NODE_CHANGED, null, new_node)
	return TRUE

/datum/netrun_ice/proc/leave_node()
	cancel_program()
	if(!node)
		return
	var/datum/component/netrun_node/old_node = node
	LAZYREMOVE(node.netrun_ice, src)
	old_node.notify_changed(NETRUN_CHANGED_OCCUPANTS)
	node = null
	SEND_SIGNAL(src, COMSIG_NETRUN_ICE_NODE_CHANGED, old_node, null)

/// Узел уничтожен: сторож гибнет вместе с ним, охотник пробует перепрыгнуть.
/datum/netrun_ice/proc/host_lost()
	var/datum/netrun_network/network = node?.network
	leave_node()
	if(kind == NETRUN_ICE_SENTRY)
		qdel(src)
		return
	var/list/candidates = list()
	for(var/datum/component/netrun_node/candidate as anything in network?.nodes)
		if(candidate.is_online() && !QDELETED(candidate.parent))
			candidates += candidate
	if(!length(candidates))
		qdel(src)
		return
	enter_node(pick(candidates))

// MARK: Боевой интерфейс

/datum/netrun_ice/proc/combat_name()
	return name

/datum/netrun_ice/proc/program_payload()
	. = list()
	for(var/id in program_ids)
		var/datum/netrun_program/program = SSnetrun.get_program(id)
		if(!program)
			continue
		var/list/entry = program.ui_entry()
		entry["ready_in"] = max(0, CEILING(((program_cd[id] || 0) - world.time) / (1 SECONDS), 0.1))
		. += list(entry)

/datum/netrun_ice/proc/casting_payload()
	if(!pending_program)
		return null
	return list("name" = pending_program.name, "role" = pending_program.role,
		"power" = pending_program.power, "remaining" = max(0, CEILING((attack_at - world.time) / (1 SECONDS), 0.1)))

/datum/netrun_ice/proc/is_stunned()
	return world.time < combat_stun_until

/datum/netrun_ice/proc/apply_damage(amount, reason, datum/netrun_console/attacker)
	if(QDELETED(src))
		return
	var/mob/camera/netrun_entity/enemy = attacker?.combat_self()
	if(istype(enemy) && enemy.host_node == node)
		enemy_ref = WEAKREF(enemy)
	if(world.time < combat_shield_until)
		amount *= combat_shield_factor
	integrity -= amount
	if(integrity <= 0)
		destroyed(attacker)
	else
		SEND_SIGNAL(src, COMSIG_NETRUN_COMBAT_CHANGED)

/datum/netrun_ice/proc/apply_stun(duration)
	combat_stun_until = max(combat_stun_until, world.time + duration)
	cancel_program()
	SEND_SIGNAL(src, COMSIG_NETRUN_COMBAT_CHANGED)

/datum/netrun_ice/proc/apply_shield(pct, duration)
	combat_shield_until = world.time + duration
	combat_shield_factor = clamp(1 - pct / 100, 0.1, 1)
	SEND_SIGNAL(src, COMSIG_NETRUN_COMBAT_CHANGED)

/datum/netrun_ice/proc/apply_heal(amount)
	integrity = min(max_integrity, integrity + amount)
	SEND_SIGNAL(src, COMSIG_NETRUN_COMBAT_CHANGED)

/datum/netrun_ice/proc/destroyed(datum/netrun_console/killer)
	if(QDELETED(src))
		return
	node?.network?.add_log("Процесс защиты [name] уничтожен.")
	node?.add_log("[name]: процесс завершён.")
	SSnetrun.post_event("purge", null, node?.address)
	drop_loot(killer)
	qdel(src)

/// Лут с ICE. В первую очередь - в память убившей консоли (включая раннера за терминалом/декой),
/// затем сущности-игроку в узле, затем в ограниченный кеш обломков узла.
/datum/netrun_ice/proc/drop_loot(datum/netrun_console/killer)
	// A daemon is guaranteed; hunters also leave a combat program.
	SSnetrun.get_daemon(null)
	var/list/pool = list()
	for(var/id in SSnetrun.daemons)
		var/datum/netrun_daemon/daemon = SSnetrun.daemons[id]
		if(daemon.loot_weight > 0)
			pool[id] = daemon.loot_weight
	if(length(pool))
		deliver_loot(netrun_daemon_file(pickweight(pool)), killer)
	if(kind == NETRUN_ICE_HUNTER)
		SSnetrun.get_program(null)
		var/list/program_pool = list()
		for(var/id in SSnetrun.programs)
			var/datum/netrun_program/program = SSnetrun.programs[id]
			if(program.size > 0 && program.role != NETRUN_PROGRAM_TRACE)
				program_pool += id
		if(length(program_pool))
			deliver_loot(netrun_program_file(pick(program_pool)), killer)
	// Патруль несёт ключ своей ЛВС: его уничтожение открывает свободное перемещение по отделу.
	if(persistent)
		var/datum/netrun_network/net = SSnetrun.networks[patrol_network_id] || node?.network
		if(net)
			deliver_loot(new /datum/netrun_file("[net.id].key", NETRUN_FILE_KEY, net.passcode, 1, net.id), killer)

/datum/netrun_ice/proc/deliver_loot(datum/netrun_file/loot, datum/netrun_console/killer)
	if(!loot)
		return
	if(!QDELETED(killer) && killer.store_file(loot))
		killer.log_line("Из обломков [name] извлечён файл: [loot.name].", "good")
		if(ismob(killer.host))
			to_chat(killer.host, span_notice("Из обломков процесса вы вытащили файл: [loot.name]."))
		return
	for(var/mob/camera/netrun_entity/entity as anything in node?.entities)
		if(entity.client && entity.console?.store_file(loot))
			to_chat(entity, span_notice("Из обломков процесса вы вытащили файл: [loot.name]."))
			return
	if(!QDELETED(node))
		// Debris is recoverable without USER privileges on the host machine.
		// Bounded separately: defeating ICE never expands the machine's disk.
		while(length(node.salvage) >= NETRUN_MAX_SALVAGE_FILES)
			var/datum/netrun_file/expired = node.salvage[1]
			node.salvage.Cut(1, 2)
			node.add_log("Старые обломки [expired.name] вытеснены новой добычей.")
			qdel(expired)
		node.salvage += loot
		node.add_log("В обломках процесса остался файл: [loot.name].")
		killer?.log_line("Нет места в памяти. [loot.name] можно забрать из обломков в узле [node.address].", "average")
		return
	// Нет места нигде в сети - роняем физический шард рядом с убившим (у кого есть тело/машина).
	var/turf/drop_turf = (!QDELETED(killer) && isatom(killer.host)) ? get_turf(killer.host) : get_turf(node?.parent)
	if(drop_turf)
		var/obj/item/netrun_shard/shard = new(drop_turf)
		shard.name = "data shard ([loot.name])"
		shard.file_store.insert(loot, TRUE)
		killer?.log_line("Нет места в памяти - лут выпал физическим шардом.", "average")
		return
	qdel(loot)

// MARK: Поведение (AI)

/datum/netrun_ice/proc/process_ai(delta)
	if(QDELETED(node) || QDELETED(node.parent))
		host_lost()
		return
	if(is_stunned() || !node.is_online())
		cancel_program()
		return
	if(pending_program)
		resolve_program()
		return
	var/mob/camera/netrun_entity/prey = find_intruder(node)
	if(prey)
		try_attack(prey)
		return
	if(kind == NETRUN_ICE_SENTRY)
		harass_intruders()
		return
	// Охотник: ищем нарушителя по сети и идём к нему.
	if(!persistent)
		patrol_life -= delta
		if(patrol_life <= 0)
			node?.network?.add_log("Охотничий процесс свёрнут: цель не найдена.")
			qdel(src)
			return
	// Нет ни одной сетевой сущности - преследовать некого, дорогой BFS не нужен.
	if(length(SSnetrun.entities))
		hunt()

/// Нарушитель в узле: сущность без легального доступа ПОЛЬЗОВАТЕЛЯ к узлу.
/datum/netrun_ice/proc/find_intruder(datum/component/netrun_node/where)
	var/mob/camera/netrun_entity/enemy = enemy_ref?.resolve()
	if(!QDELETED(enemy) && enemy.host_node == where)
		return enemy
	var/mob/camera/netrun_entity/best
	var/best_integrity = INFINITY
	for(var/mob/camera/netrun_entity/entity as anything in where?.entities)
		if(QDELETED(entity))
			continue
		if(world.time < entity.combat_ignore_until)
			continue
		if(entity.console?.node_level(where) >= NETRUN_ACCESS_USER)
			continue
		if(entity.integrity < best_integrity)
			best = entity
			best_integrity = entity.integrity
	return best

/datum/netrun_ice/proc/try_attack(mob/camera/netrun_entity/prey)
	if(world.time < next_attack || QDELETED(prey))
		return
	for(var/id in program_ids)
		var/datum/netrun_program/program = SSnetrun.get_program(id)
		if(!program || world.time < (program_cd[id] || 0) || program.role == NETRUN_PROGRAM_TRACE)
			continue
		if(program.role == NETRUN_PROGRAM_SHIELD && (integrity > max_integrity * 0.75 || world.time < combat_shield_until))
			continue
		if(begin_program(program, program.needs_target ? prey : src))
			return

/datum/netrun_ice/proc/pending_target()
	return pending_target_ref?.resolve()

/// A console is a valid trace target only while it is still attacking this node/LAN.
/datum/netrun_ice/proc/valid_trace_target(datum/netrun_console/console)
	if(!istype(console) || QDELETED(console))
		return FALSE
	var/datum/netrun_breach/breach = console?.intrusion.breach
	return !QDELETED(console) && !console.is_locked() && breach && ((breach.target_kind == "network" && node?.network && breach.target_id == node.network.id) || (breach.target_kind != "network" && breach.target_id == node?.address))

/datum/netrun_ice/proc/begin_program(datum/netrun_program/program, datum/target)
	if(QDELETED(target) || !program || (program.role == NETRUN_PROGRAM_TRACE ? !valid_trace_target(target) : !netrun_combatant_in_node(target, node)))
		return FALSE
	if(pending_program || is_stunned() || !node?.is_online() || world.time < next_attack || !(program.id in program_ids) || world.time < (program_cd[program.id] || 0))
		return FALSE
	pending_program = program
	pending_target_ref = WEAKREF(target)
	attack_at = world.time + program.windup
	program_cd[program.id] = attack_at + program.cooldown
	var/datum/netrun_console/victim
	if(istype(target, /mob/camera/netrun_entity))
		var/mob/camera/netrun_entity/entity = target
		victim = entity.console
		to_chat(entity, span_userdanger("[name] готовит [program.name]: до срабатывания [program.windup / (1 SECONDS)] с! Щит, оглушение или переход помогут избежать атаки."))
	else if(istype(target, /datum/netrun_console))
		victim = target
	SEND_SIGNAL(SSnetrun, COMSIG_NETRUN_ICE_CAST_STARTED, src, victim)
	SEND_SIGNAL(src, COMSIG_NETRUN_COMBAT_CHANGED)
	victim?.log_line("[name] готовит [program.name], срабатывание через [program.windup / (1 SECONDS)] с.", "bad")
	node.add_log("[name]: подготовка [program.name].")
	return TRUE

/datum/netrun_ice/proc/cancel_program()
	var/had_program = !!pending_program
	pending_program = null
	pending_target_ref = null
	attack_at = 0
	if(had_program)
		SEND_SIGNAL(src, COMSIG_NETRUN_COMBAT_CHANGED)

/datum/netrun_ice/proc/resolve_program()
	if(!pending_program)
		return
	var/datum/target = pending_target()
	if(QDELETED(target) || (pending_program.role == NETRUN_PROGRAM_TRACE ? !valid_trace_target(target) : !netrun_combatant_in_node(target, node)))
		cancel_program()
		return
	if(world.time < attack_at)
		return
	var/datum/netrun_program/program = pending_program
	cancel_program()
	next_attack = world.time + 0.5 SECONDS
	netrun_apply_program(program, target, null, damage_factor)
	SSnetrun.post_event("intrusion", null, node?.address)
	if(!QDELETED(target) && istype(target, /mob/camera/netrun_entity))
		var/mob/camera/netrun_entity/entity = target
		entity.console?.log_line("[name]: сработала [program.name].", "bad")

/// Сторож без прямой цели давит на тех, кто ломает его узел или сеть.
/datum/netrun_ice/proc/harass_intruders()
	var/datum/netrun_program/program = SSnetrun.get_program("trace")
	if(world.time < next_attack || world.time < (program_cd[program.id] || 0))
		return
	// During the subsystem pass this is one shared, bounded breach snapshot.
	// Standalone callers still inspect live consoles; execution checks every candidate.
	var/list/candidates = SSnetrun.breach_snapshot_active ? SSnetrun.currentbreaches : SSnetrun.consoles
	for(var/datum/netrun_console/console as anything in candidates)
		if(valid_trace_target(console) && begin_program(program, console))
			return

/datum/netrun_ice/proc/hunt()
	if(world.time < hop_cooldown)
		return
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	// BFS от текущего узла до ближайшего узла с нарушителем.
	var/list/queue = list(node.address)
	var/list/came_from = list()
	came_from[node.address] = null
	var/target_address
	for(var/i = 1, i <= length(queue) && i <= 60, i++)
		var/address = queue[i]
		var/datum/component/netrun_node/current = graph.nodes[address]
		if(QDELETED(current) || !current.is_online())
			continue
		if(address != node.address && find_intruder(current))
			target_address = address
			break
		for(var/neighbor in graph.neighbors(address))
			if(!isnull(came_from[neighbor]) || neighbor == node.address)
				continue
			if(!netrun_link_available(current, graph.nodes[neighbor]))
				continue
			came_from[neighbor] = address
			queue += neighbor
	if(!target_address)
		return
	// Восстанавливаем первый шаг пути.
	var/step = target_address
	while(came_from[step] && came_from[step] != node.address)
		step = came_from[step]
	var/datum/component/netrun_node/next_node = graph.nodes[step]
	if(next_node && next_node != node)
		enter_node(next_node)
		hop_cooldown = world.time + 1.5 SECONDS
		SSnetrun.post_event("trace", null, next_node.address)

// MARK: Подсистема

/datum/controller/subsystem/netrun
	var/list/datum/netrun_ice/ice_processes = list()
	var/list/currentice = list()
	/// Патрульные процессы поднимаются один раз за раунд при первом игровом тике.
	var/patrol_initialized = FALSE
	/// Лорные документы раскладываются по серверам один раз за раунд.
	var/lore_initialized = FALSE
	/// Узлы защиты со спящими ячейками льда: address -> сколько ячеек ещё можно пробудить.
	var/list/defense_nests = list()
	var/datum/netrun_defense_director/defense_director

/// Создать ICE в узле. Возвращает процесс.
/datum/controller/subsystem/netrun/proc/spawn_ice(datum/component/netrun_node/where, ice_kind = NETRUN_ICE_SENTRY)
	if(QDELETED(where) || QDELETED(where.parent))
		return null
	var/datum/netrun_ice/ice = new(where, ice_kind)
	where.network?.add_log("Активирован процесс защиты: [ice.name].")
	where.add_log("[ice.name]: процесс защиты запущен.")
	return ice

/// Сколько ICE уже стоит в узле (не плодим бесконечно).
/datum/controller/subsystem/netrun/proc/ice_count(datum/component/netrun_node/where)
	return LAZYLEN(where?.netrun_ice)

/// Среагировать на нелегальную активность: закалённый узел ставит сторожа,
/// а при высокой трассировке с ближайшего реле/сервера выходит охотник.
/datum/controller/subsystem/netrun/proc/raise_defenses(datum/netrun_console/console, datum/component/netrun_node/target)
	if(QDELETED(target) || QDELETED(target.parent))
		return
	if(target.get_security() >= 3 && ice_count(target) < 1)
		spawn_ice(target, NETRUN_ICE_SENTRY)

/// Пассивный патруль с начала раунда: по одному персистентному охотнику на крупные
/// отдельские ЛВС. Патруль не сворачивается без цели и роняет ключ своей ЛВС при гибели.
/datum/controller/subsystem/netrun/proc/initialize_patrol()
	patrol_initialized = TRUE
	var/count = 0
	for(var/net_id in networks)
		if(count >= NETRUN_MAX_PATROLS)
			break
		var/datum/netrun_network/net = networks[net_id]
		if(net.security < 2 || net.isolated)
			continue
		var/list/candidates = list()
		for(var/datum/component/netrun_node/node as anything in net.nodes)
			if(!QDELETED(node) && !QDELETED(node.parent) && node.is_online())
				candidates += node
		if(!length(candidates))
			continue
		var/datum/component/netrun_node/anchor = pick(candidates)
		var/datum/netrun_ice/patrol = spawn_ice(anchor, NETRUN_ICE_HUNTER)
		if(patrol)
			patrol.persistent = TRUE
			patrol.patrol_network_id = net.id
			net.add_log("В сети активен патрульный процесс защиты.")
			count++
		// В хорошо защищённых отделах один узел становится гнездом спящих ячеек льда.
		if(net.security >= 3)
			var/datum/component/netrun_node/nest
			for(var/datum/component/netrun_node/candidate as anything in candidates)
				if(candidate.node_type == NETRUN_NODE_SERVER)
					nest = candidate
					break
			nest ||= anchor
			if(nest)
				defense_nests[nest.address] = 2
				nest.add_log("Узел защиты: спящие ячейки ICE в резерве.")

/// A dedicated domain service owns network-local retaliation policy.
/// Persistent hunters patrol independently; only temporary response units consume the dispatch cap.
/datum/netrun_defense_director
	var/datum/controller/subsystem/netrun/owner

/datum/netrun_defense_director/New(datum/controller/subsystem/netrun/subsystem)
	. = ..()
	owner = subsystem

/datum/netrun_defense_director/Destroy()
	owner = null
	return ..()

/datum/netrun_defense_director/proc/alert(datum/component/netrun_node/target)
	if(QDELETED(target) || !target.network)
		return
	var/datum/netrun_network/network = target.network
	for(var/datum/netrun_ice/ice as anything in owner.ice_processes)
		if(QDELETED(ice) || ice.kind != NETRUN_ICE_HUNTER || ice.node?.network != network)
			continue
		ice.hop_cooldown = 0
		if(!ice.persistent)
			ice.patrol_life = max(ice.patrol_life, 40)
	for(var/nest_address in owner.defense_nests)
		if(owner.defense_nests[nest_address] <= 0)
			continue
		var/datum/component/netrun_node/nest = owner.nodes_by_address[nest_address]
		if(QDELETED(nest) || QDELETED(nest.parent) || nest.network != network || !nest.is_online())
			continue
		// Consume a cell only after a response process was actually created.
		var/datum/netrun_ice/awoken = owner.spawn_ice(nest, NETRUN_ICE_HUNTER)
		if(!awoken)
			continue
		owner.defense_nests[nest_address]--
		awoken.hop_cooldown = 0
		network.add_log("Пробуждена ячейка защиты: процесс направлен к нарушителю.")

/datum/netrun_defense_director/proc/dispatch(datum/component/netrun_node/near)
	if(QDELETED(near) || QDELETED(near.parent) || !near.network)
		return
	var/datum/netrun_network/network = near.network
	var/active_responses = 0
	for(var/datum/netrun_ice/ice as anything in owner.ice_processes)
		if(QDELETED(ice) || ice.kind != NETRUN_ICE_HUNTER || ice.persistent || ice.node?.network != network)
			continue
		active_responses++
		if(active_responses >= 3)
			return
	owner.spawn_ice(near, NETRUN_ICE_HUNTER)

/// Backward-compatible public API. Network rules live in the defense director.
/datum/controller/subsystem/netrun/proc/get_defense_director()
	if(!defense_director)
		defense_director = new(src)
	return defense_director

/datum/controller/subsystem/netrun/proc/alert_defenses(datum/component/netrun_node/target, datum/netrun_console/intruder)
	get_defense_director().alert(target)

/datum/controller/subsystem/netrun/proc/dispatch_hunter(datum/component/netrun_node/near)
	get_defense_director().dispatch(near)
