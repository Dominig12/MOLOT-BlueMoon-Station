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
	var/name = "ICE"
	var/datum/component/netrun_node/node
	var/kind = NETRUN_ICE_SENTRY
	var/integrity = 120
	var/max_integrity = 120
	/// Урон по цели за удар
	var/attack_power = 14
	/// Пауза между ударами
	var/attack_interval = 2 SECONDS
	var/next_attack = 0
	var/next_ai = 0
	/// Сторож: узел, который он охраняет (чтобы вернуться)
	var/datum/weakref/anchor_ref
	/// Охотник: сколько тиков без цели он ещё проживёт
	var/patrol_life = 40
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
		attack_power = 18
		attack_interval = 1.5 SECONDS
	else
		name = "ICE-SENTRY"
	SSnetrun.ice_processes += src
	if(start)
		enter_node(start)
		anchor_ref = WEAKREF(start)

/datum/netrun_ice/Destroy()
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
	return TRUE

/datum/netrun_ice/proc/leave_node()
	if(!node)
		return
	LAZYREMOVE(node.netrun_ice, src)
	node = null

/// Узел уничтожен: сторож гибнет вместе с ним, охотник пробует перепрыгнуть.
/datum/netrun_ice/proc/host_lost()
	var/datum/netrun_network/network = node?.network
	LAZYREMOVE(node?.netrun_ice, src)
	node = null
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

/datum/netrun_ice/proc/is_stunned()
	return world.time < combat_stun_until

/datum/netrun_ice/proc/apply_damage(amount, reason, atom/source)
	if(QDELETED(src))
		return
	if(world.time < combat_shield_until)
		amount *= combat_shield_factor
	integrity -= amount
	if(integrity <= 0)
		destroyed(source)

/datum/netrun_ice/proc/apply_stun(duration)
	combat_stun_until = max(combat_stun_until, world.time + duration)

/datum/netrun_ice/proc/apply_shield(pct, duration)
	combat_shield_until = world.time + duration
	combat_shield_factor = clamp(1 - pct / 100, 0.1, 1)

/datum/netrun_ice/proc/apply_heal(amount)
	integrity = min(max_integrity, integrity + amount)

/datum/netrun_ice/proc/destroyed(atom/source)
	if(QDELETED(src))
		return
	node?.network?.add_log("Процесс защиты [name] уничтожен.")
	node?.add_log("[name]: процесс завершён.")
	SSnetrun.post_event("purge", null, node?.address)
	drop_loot()
	qdel(src)

/// Шанс оставить боевую программу тому, кто находится в узле.
/datum/netrun_ice/proc/drop_loot()
	if(kind != NETRUN_ICE_HUNTER && !prob(35))
		return
	var/datum/netrun_file/loot = netrun_program_file(pick("strike", "blackout", "assault"))
	if(!loot)
		return
	// Отдаём добычу первой сущности-игроку в узле; иначе кладём в файлы узла.
	for(var/mob/camera/netrun_entity/entity as anything in node?.entities)
		if(entity.client && entity.console?.store_file(loot))
			to_chat(entity, span_notice("Из обломков процесса вы вытащили файл: [loot.name]."))
			return
	if(node?.files && node.used_storage() + loot.size <= node.storage_capacity)
		node.files += loot
		return
	qdel(loot)

// MARK: Поведение (AI)

/datum/netrun_ice/proc/process_ai(delta)
	if(QDELETED(node) || QDELETED(node.parent))
		host_lost()
		return
	if(is_stunned())
		return
	var/mob/camera/netrun_entity/prey = find_intruder(node)
	if(prey)
		try_attack(prey)
		return
	if(kind == NETRUN_ICE_SENTRY)
		harass_intruders()
		return
	// Охотник: ищем нарушителя по сети и идём к нему.
	patrol_life -= delta
	if(patrol_life <= 0)
		node?.network?.add_log("Охотничий процесс свёрнут: цель не найдена.")
		qdel(src)
		return
	hunt()

/// Нарушитель в узле: сущность без легального доступа ПОЛЬЗОВАТЕЛЯ к узлу.
/datum/netrun_ice/proc/find_intruder(datum/component/netrun_node/where)
	var/mob/camera/netrun_entity/best
	var/best_integrity = INFINITY
	for(var/mob/camera/netrun_entity/entity as anything in where?.entities)
		if(QDELETED(entity))
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
	next_attack = world.time + attack_interval
	prey.take_integrity(attack_power, "атака [name]")
	SSnetrun.post_event("intrusion", null, node?.address)
	if(!QDELETED(prey) && prey.console)
		prey.console.add_trace(attack_power * 0.3)

/// Сторож без прямой цели давит на тех, кто ломает его узел или сеть.
/datum/netrun_ice/proc/harass_intruders()
	if(world.time < next_attack)
		return
	var/datum/netrun_network/network = node?.network
	for(var/datum/netrun_console/console as anything in SSnetrun.consoles)
		if(QDELETED(console))
			continue
		var/datum/netrun_breach/breach = console.breach
		var/hit = FALSE
		if(breach && ((breach.target_kind == "network" && network && breach.target_id == network.id) || (breach.target_kind != "network" && breach.target_id == node?.address)))
			hit = TRUE
		if(hit)
			console.add_trace(node.get_security() * 1.5)
			next_attack = world.time + attack_interval

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

/// Выслать охотника за нарушителем-сущностью (если он есть и до него есть сеть).
/datum/controller/subsystem/netrun/proc/dispatch_hunter(datum/component/netrun_node/near)
	if(QDELETED(near) || QDELETED(near.parent))
		return
	// Не плодим охотников: не больше трёх одновременно.
	var/hunters = 0
	for(var/datum/netrun_ice/ice as anything in ice_processes)
		if(ice.kind == NETRUN_ICE_HUNTER)
			hunters++
	if(hunters >= 3)
		return
	spawn_ice(near, NETRUN_ICE_HUNTER)

/datum/controller/subsystem/netrun/proc/process_ice()
	var/delta = wait / (1 SECONDS)
	for(var/datum/netrun_ice/ice as anything in ice_processes)
		if(QDELETED(ice))
			continue
		ice.process_ai(delta)
