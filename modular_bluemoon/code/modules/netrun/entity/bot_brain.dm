/**
 * Мозг автономного бота. Думает по одному отменяемому таймеру через задачу
 * планировщика `bot` и за один шаг выполняет не больше одного действия: переход,
 * команду узла, боевую программу или подбор обломков. Бой проверяется первым,
 * затем текущая цель; без целей программа бота составляет план.
 */
/datum/netrun_bot_brain
	var/mob/camera/netrun_entity/bot/owner
	var/list/datum/netrun_bot_goal/goals = list()
	var/state = "запуск"
	var/in_combat = FALSE
	var/timer_id
	/// address -> world.time of the last visit, bounded.
	var/list/visited = list()
	/// address -> expiry: unreachable or dangerous nodes are skipped for a while.
	var/list/blacklist = list()
	/// weakref(process) -> expiry: processes that attacked this bot or were marked as targets.
	var/list/enemies = list()
	var/datum/weakref/pending_attack_ref
	var/pending_attack_at = 0
	/// Agent order and its node (guard post).
	var/order
	var/datum/weakref/order_node_ref
	/// Custodians report rogue processes they meet.
	var/watch_for_rogues = FALSE
	var/next_rogue_report = 0

/datum/netrun_bot_brain/New(mob/camera/netrun_entity/bot/owner)
	src.owner = owner
	RegisterSignal(SSnetrun, COMSIG_NETRUN_ICE_CAST_STARTED, PROC_REF(on_ice_cast))

/datum/netrun_bot_brain/Destroy()
	clear_timer()
	SSnetrun.task_scheduler?.cancel("bot", src)
	UnregisterSignal(SSnetrun, list(COMSIG_NETRUN_ICE_CAST_STARTED, COMSIG_NETRUN_INCIDENT_REPORTED))
	QDEL_LIST(goals)
	pending_attack_ref = null
	order_node_ref = null
	owner = null
	return ..()

// MARK: Такт

/datum/netrun_bot_brain/proc/clear_timer()
	if(timer_id)
		deltimer(timer_id)
	timer_id = null

/datum/netrun_bot_brain/proc/schedule(delay)
	clear_timer()
	if(QDELETED(src) || QDELETED(owner))
		return
	timer_id = addtimer(CALLBACK(src, PROC_REF(wake_now)), max(NETRUN_EXECUTION_MIN_INTERVAL, delay), TIMER_STOPPABLE | TIMER_DELETE_ME)

/datum/netrun_bot_brain/proc/schedule_next()
	if(QDELETED(src) || QDELETED(owner))
		return
	var/datum/netrun_bot_program/program = owner.program
	var/interval = in_combat ? program.think_combat : (length(goals) ? program.think_busy : program.think_idle)
	schedule(interval + rand(-5, 5))

/// Timers and combat events only admit work; thinking runs inside the subsystem budget.
/datum/netrun_bot_brain/proc/wake_now()
	clear_timer()
	if(QDELETED(src) || QDELETED(owner))
		return
	SSnetrun.get_task_scheduler().enqueue("bot", src, NETRUN_TASK_NORMAL)

/datum/netrun_bot_brain/proc/on_ice_cast(datum/source, datum/netrun_ice/ice, datum/netrun_console/victim)
	SIGNAL_HANDLER
	if(victim && victim == owner?.console)
		wake_now()

/datum/netrun_bot_brain/proc/think()
	if(QDELETED(owner) || QDELETED(owner.console) || owner.client)
		return
	prune_memory()
	if(owner.agent_orphaned())
		owner.console.log_line("Связь с владельцем потеряна.", "bad")
		owner.dissolve()
		return
	if(!owner.host_node)
		state = "без узла"
		return
	if(owner.is_stunned())
		state = "оглушён"
		return
	if(watch_for_rogues)
		report_rogues()
	if(combat_step())
		return
	var/datum/netrun_bot_goal/goal = current_goal()
	if(!goal)
		owner.program.plan(src)
		goal = current_goal()
	if(!goal)
		state = "ожидание"
		return
	var/result = goal.advance()
	if(QDELETED(src) || QDELETED(goal))
		return
	if(result != NETRUN_BOT_GOAL_CONTINUE || world.time > goal.expires_at)
		finish_goal(goal)

// MARK: Цели

/datum/netrun_bot_brain/proc/push_goal(datum/netrun_bot_goal/goal)
	if(!goal)
		return
	goals += goal
	while(length(goals) > 4)
		var/datum/netrun_bot_goal/oldest = goals[1]
		goals.Cut(1, 2)
		qdel(oldest)

/datum/netrun_bot_brain/proc/current_goal()
	return length(goals) ? goals[1] : null

/datum/netrun_bot_brain/proc/finish_goal(datum/netrun_bot_goal/goal)
	goals -= goal
	qdel(goal)

/datum/netrun_bot_brain/proc/clear_goals()
	QDEL_LIST(goals)
	goals = list()
	owner?.navigation?.cancel()

/datum/netrun_bot_brain/proc/goal_text()
	var/datum/netrun_bot_goal/goal = current_goal()
	return goal ? goal.describe() : null

// MARK: Память

/datum/netrun_bot_brain/proc/prune_memory()
	for(var/address in blacklist)
		if(blacklist[address] <= world.time)
			blacklist -= address
	for(var/datum/weakref/reference as anything in enemies)
		if(enemies[reference] <= world.time || !reference.resolve())
			enemies -= reference

/datum/netrun_bot_brain/proc/blacklist(address, duration = 2 MINUTES)
	if(!address)
		return
	blacklist[address] = world.time + duration
	while(length(blacklist) > 32)
		blacklist.Cut(1, 2)

/datum/netrun_bot_brain/proc/is_blacklisted(address)
	return blacklist[address] > world.time

/datum/netrun_bot_brain/proc/remember_visit(address)
	visited -= address
	visited[address] = world.time
	while(length(visited) > 64)
		visited.Cut(1, 2)

/datum/netrun_bot_brain/proc/mark_enemy(datum/target, duration = 60 SECONDS)
	if(QDELETED(target) || target == owner)
		return
	enemies[WEAKREF(target)] = world.time + duration
	while(length(enemies) > 16)
		enemies.Cut(1, 2)

/datum/netrun_bot_brain/proc/remembered_enemy(datum/target)
	return enemies[WEAKREF(target)] > world.time

/// The attacking session's own process becomes an enemy; a remote attacker cannot be hit back here.
/datum/netrun_bot_brain/proc/note_attacker(datum/netrun_console/attacker)
	var/datum/self = attacker?.combat_self()
	if(self && self != owner)
		mark_enemy(self)
	wake_now()

// MARK: Перемещение

/// One movement action toward a node: a direct hop, or an authorized auto-travel route.
/datum/netrun_bot_brain/proc/move_toward(datum/component/netrun_node/target)
	if(QDELETED(target) || QDELETED(owner))
		return NETRUN_BOT_MOVE_BLOCKED
	if(owner.host_node == target)
		remember_visit(target.address)
		return NETRUN_BOT_MOVE_ARRIVED
	var/datum/netrun_entity_navigation/navigation = owner.navigation
	if(navigation.is_active())
		if(navigation.destination == target.address)
			state = "в пути"
			return NETRUN_BOT_MOVE_PROGRESS
		navigation.cancel()
	if(world.time < owner.next_hop)
		return NETRUN_BOT_MOVE_PROGRESS
	// A neighbour is entered directly, including one guarded by ICE the bot wants to fight.
	if(owner.can_enter(target))
		state = "в пути"
		if(owner.hop(target))
			remember_visit(target.address)
			return NETRUN_BOT_MOVE_ARRIVED
		return NETRUN_BOT_MOVE_PROGRESS
	if(owner.travel_to(target))
		state = "в пути"
		return NETRUN_BOT_MOVE_PROGRESS
	return NETRUN_BOT_MOVE_BLOCKED

/// Breadth-first search over nodes this bot may enter, bounded to its surroundings.
/// `predicate` is a proc on this brain taking the candidate node.
/datum/netrun_bot_brain/proc/find_nearby_node(predicate, list/scope, limit = 48)
	var/datum/component/netrun_node/start = owner?.host_node
	if(!start)
		return null
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	var/datum/netrun_console/console = owner.console
	var/datum/netrun_path_tree/tree = console.connection.read_path_tree(TRUE)
	var/list/queue = list(start.address)
	var/list/seen = list()
	seen[start.address] = TRUE
	for(var/i = 1, i <= length(queue) && i <= limit, i++)
		var/datum/component/netrun_node/current = graph.nodes[queue[i]]
		if(QDELETED(current))
			continue
		if(current != start && !is_blacklisted(current.address) && call(src, predicate)(current))
			. = current
			break
		for(var/address in graph.neighbors(current.address, FALSE))
			if(seen[address])
				continue
			seen[address] = TRUE
			var/datum/component/netrun_node/next = graph.nodes[address]
			if(QDELETED(next) || !netrun_link_available(current, next))
				continue
			if(scope && !(next.network?.id in scope))
				continue
			if(console.node_level(next, tree) < NETRUN_ACCESS_USER && !console.has_key(next.network, TRUE))
				continue
			queue += address
	console.release_path_tree(tree)

/datum/netrun_bot_brain/proc/node_has_salvage(datum/component/netrun_node/node)
	return length(node.salvage) > 0

/datum/netrun_bot_brain/proc/node_has_ice(datum/component/netrun_node/node)
	return LAZYLEN(node.netrun_ice) > 0

/datum/netrun_bot_brain/proc/node_is_patrol_point(datum/component/netrun_node/node)
	return node.is_online() && !node.is_dynamic() && world.time - (visited[node.address] || -INFINITY) > 2 MINUTES

/// The least recently visited stationary node around the bot.
/datum/netrun_bot_brain/proc/patrol_destination(list/scope)
	return find_nearby_node(TYPE_PROC_REF(/datum/netrun_bot_brain, node_is_patrol_point), scope)

// MARK: Бой

/datum/netrun_bot_brain/proc/hostiles()
	. = list()
	var/datum/component/netrun_node/node = owner.host_node
	if(!node)
		return
	for(var/datum/netrun_ice/ice as anything in node.netrun_ice)
		if(!QDELETED(ice) && (ice.enemy_ref?.resolve() == owner || ice.is_intruder(owner, node)))
			. += ice
	for(var/mob/camera/netrun_entity/entity as anything in node.entities)
		if(entity == owner || QDELETED(entity) || world.time < entity.combat_ignore_until)
			continue
		if(remembered_enemy(entity) || owner.program.is_enemy(src, entity))
			. += entity

/datum/netrun_bot_brain/proc/combat_step()
	var/list/foes = hostiles()
	if(!length(foes))
		in_combat = FALSE
		pending_attack_ref = null
		return FALSE
	in_combat = TRUE
	state = "бой"
	var/ratio = owner.integrity / max(1, owner.max_integrity)
	if(ratio < owner.program.flee_ratio && try_flee())
		return TRUE
	if(ratio < 0.5 && world.time >= owner.combat_shield_until && use_role(NETRUN_PROGRAM_SHIELD, owner))
		return TRUE
	if(ratio < 0.4 && use_role(NETRUN_PROGRAM_REPAIR, owner))
		return TRUE
	var/datum/target = pick_target(foes)
	if(istype(target, /datum/netrun_ice))
		var/datum/netrun_ice/ice = target
		if(ice.pending_program && use_role(NETRUN_PROGRAM_STUN, ice))
			return TRUE
		return use_role(NETRUN_PROGRAM_ATTACK, ice)
	if(!istype(target, /mob/camera/netrun_entity/bot))
		return telegraphed_attack(target)
	return use_role(NETRUN_PROGRAM_ATTACK, target)

/datum/netrun_bot_brain/proc/pick_target(list/foes)
	var/datum/pending = pending_attack_ref?.resolve()
	if(pending && (pending in foes))
		return pending
	var/best_hp = INFINITY
	for(var/datum/foe as anything in foes)
		var/list/hp = netrun_combatant_integrity(foe)
		var/current = hp ? hp["cur"] : INFINITY
		if(!. || current < best_hp)
			. = foe
			best_hp = current

/// Uses the strongest ready program of a role through the ordinary combat pipeline.
/datum/netrun_bot_brain/proc/use_role(role, datum/target)
	var/datum/netrun_console/console = owner.console
	var/datum/netrun_combat_context/combat = console.combat_context
	if(QDELETED(target) || world.time < combat.next_program)
		return FALSE
	var/best_uid
	var/best_power = -1
	for(var/id in console.builtin_program_ids())
		var/datum/netrun_program/program = SSnetrun.get_program(id)
		if(program?.role == role && world.time >= (combat.program_cd[program.id] || 0) && program.power > best_power)
			best_uid = "builtin:[id]"
			best_power = program.power
	for(var/datum/netrun_file/file as anything in console.all_files())
		if(file.kind != NETRUN_FILE_PROGRAM)
			continue
		var/datum/netrun_program/program = SSnetrun.get_program(file.content)
		if(program?.role == role && world.time >= (combat.program_cd[program.id] || 0) && program.power > best_power)
			best_uid = file.uid
			best_power = program.power
	if(!best_uid)
		return FALSE
	return console.program_use(best_uid, REF(target))

/// Player processes get the same warning ICE gives before a hit.
/datum/netrun_bot_brain/proc/telegraphed_attack(mob/camera/netrun_entity/target)
	var/datum/pending = pending_attack_ref?.resolve()
	if(pending == target)
		if(world.time < pending_attack_at)
			return TRUE
		pending_attack_ref = null
		return use_role(NETRUN_PROGRAM_ATTACK, target)
	pending_attack_ref = WEAKREF(target)
	pending_attack_at = world.time + NETRUN_ICE_MIN_TELEGRAPH
	var/seconds = NETRUN_ICE_MIN_TELEGRAPH / (1 SECONDS)
	to_chat(target, span_userdanger("[owner.real_name] готовит атаку на ваш процесс: [seconds] с. Щит снизит урон, уход из узла сорвёт удар."))
	target.console?.log_line("[owner.real_name] готовит атаку: [seconds] с до удара.", "bad")
	return TRUE

/// Leave through an enterable neighbour without hostile ICE.
/datum/netrun_bot_brain/proc/try_flee()
	var/datum/component/netrun_node/here = owner.host_node
	if(!here || world.time < owner.next_hop)
		return FALSE
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	for(var/address in shuffle(graph.neighbors(here.address, FALSE)))
		var/datum/component/netrun_node/next = graph.nodes[address]
		if(QDELETED(next) || is_blacklisted(address) || !owner.can_enter(next))
			continue
		var/dangerous = FALSE
		for(var/datum/netrun_ice/ice as anything in next.netrun_ice)
			if(!QDELETED(ice) && ice.is_intruder(owner, next))
				dangerous = TRUE
				break
		if(dangerous || !owner.hop(next))
			continue
		blacklist(here.address, 30 SECONDS)
		state = "отступление"
		owner.navigation.cancel()
		return TRUE
	return FALSE

// MARK: Наблюдение и агенты

/// Custodians notify the police about rogue processes they meet.
/datum/netrun_bot_brain/proc/report_rogues()
	if(world.time < next_rogue_report)
		return
	for(var/mob/camera/netrun_entity/bot/other in owner.host_node.entities)
		if(other.net_faction == NETRUN_FACTION_ROGUE)
			next_rogue_report = world.time + 20 SECONDS
			SSnetrun.report_incident("rogue", owner.host_node, other, NETRUN_INCIDENT_MEDIUM, "[owner.real_name] сообщает о диком процессе [other.real_name].")
			return

/datum/netrun_bot_brain/proc/post_node()
	RETURN_TYPE(/datum/component/netrun_node)
	var/datum/component/netrun_node/node = order_node_ref?.resolve()
	return node || SSnetrun.find_node(owner.home_address)

/datum/netrun_bot_brain/proc/at_post()
	var/datum/component/netrun_node/post = post_node()
	return post && owner.host_node == post

/// A process without USER on the post that is neither the owner nor one of its agents.
/datum/netrun_bot_brain/proc/trespasser(mob/camera/netrun_entity/entity)
	if(!istype(entity) || entity == owner || QDELETED(entity.console) || !entity.defense_threat())
		return FALSE
	var/datum/netrun_console/master = owner.netrun_owner_console()
	if(master && (entity.console == master || entity.netrun_owner_console() == master))
		return FALSE
	return entity.console.node_level(owner.host_node) < NETRUN_ACCESS_USER

/datum/netrun_task/bot
	kind = "bot"

/datum/netrun_task/bot/execute(datum/controller/subsystem/netrun/worker, datum/netrun_execution_limits/limits)
	var/datum/netrun_bot_brain/brain = target()
	if(QDELETED(brain))
		return FALSE
	brain.think()
	if(!QDELETED(brain))
		brain.schedule_next()
	return TRUE
