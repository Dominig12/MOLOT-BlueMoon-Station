/// ICE is a lightweight agent: the public combat facade owns residency, while
/// its profile composes programs, storage and ordered behavioral capabilities.
/// It needs neither a camera mob nor an idle console per guarded machine.
/datum/netrun_ice_profile
	var/id = NETRUN_ICE_SENTRY
	var/name = "ICE-SENTRY"
	var/integrity = 90
	var/damage_factor = 0.78
	var/storage = 32
	var/illegal = FALSE
	var/list/program_ids = list("strike", "barrier", "trace")
	var/list/behavior_types = list(/datum/netrun_ice_behavior/lifecycle, /datum/netrun_ice_behavior/availability,
		/datum/netrun_ice_behavior/cast, /datum/netrun_ice_behavior/local_combat, /datum/netrun_ice_behavior/trace)

/datum/netrun_ice_profile/hunter
	id = NETRUN_ICE_HUNTER
	name = "ICE-HUNTER"
	program_ids = list("assault", "strike", "blackout", "trace")

/datum/netrun_ice_profile/hunter/New()
	behavior_types = behavior_types.Copy()
	behavior_types += /datum/netrun_ice_behavior/pursuit

/datum/netrun_ice_profile/black
	id = NETRUN_ICE_BLACK
	name = "BLACK ICE"
	integrity = 120
	damage_factor = 1
	illegal = TRUE
	program_ids = list("assault", "barrier", "trace")

/datum/netrun_ice_profile/black/New()
	behavior_types = behavior_types.Copy()
	behavior_types += /datum/netrun_ice_behavior/biofeedback

/datum/controller/subsystem/netrun
	var/list/ice_profiles

/datum/controller/subsystem/netrun/proc/get_ice_profile(id)
	if(!ice_profiles)
		ice_profiles = list()
		for(var/path in typesof(/datum/netrun_ice_profile))
			var/datum/netrun_ice_profile/profile = new path
			ice_profiles[profile.id] = profile
	return ice_profiles[id] || ice_profiles[NETRUN_ICE_SENTRY]

/datum/netrun_ice_agent
	var/datum/netrun_ice/owner
	var/datum/netrun_ice_profile/profile
	var/datum/netrun_file_store/memory
	var/list/datum/netrun_ice_behavior/behaviors = list()
	var/state = "охрана"

/datum/netrun_ice_agent/New(datum/netrun_ice/owner, datum/netrun_ice_profile/profile)
	src.owner = owner
	src.profile = profile
	memory = new(src, profile.storage)
	for(var/id in profile.program_ids)
		memory.insert(netrun_program_file(id))
	for(var/path in profile.behavior_types)
		var/datum/netrun_ice_behavior/behavior = new path(owner)
		behaviors += behavior
	sortTim(behaviors, GLOBAL_PROC_REF(cmp_netrun_agent_behavior))

/datum/netrun_ice_agent/Destroy()
	QDEL_LIST(behaviors)
	QDEL_NULL(memory)
	owner = null
	profile = null
	return ..()

/// Exactly one capability may perform an action; passive reactions return FALSE.
/datum/netrun_ice_agent/proc/advance(delta)
	for(var/datum/netrun_ice_behavior/behavior as anything in behaviors)
		if(QDELETED(owner))
			return
		if(behavior.enabled && behavior.advance(delta))
			return

/datum/netrun_ice_behavior
	parent_type = /datum/netrun_agent_behavior
	var/datum/netrun_ice/owner

/datum/netrun_ice_behavior/New(datum/netrun_ice/owner)
	src.owner = owner
	on_install()

/datum/netrun_ice_behavior/Destroy()
	owner = null
	return ..()

/datum/netrun_ice_behavior/proc/on_install()
	return

/datum/netrun_ice_behavior/proc/advance(delta)
	return FALSE

/datum/netrun_ice_behavior/lifecycle
	id = "lifecycle"
	priority = 10

/datum/netrun_ice_behavior/lifecycle/advance(delta)
	if(QDELETED(owner.node) || QDELETED(owner.node.parent) || (owner.kind == NETRUN_ICE_HUNTER && owner.node.network != owner.defense_network()))
		owner.host_lost()
		return TRUE
	if(owner.kind == NETRUN_ICE_HUNTER && !owner.persistent && !owner.pending_program && world.time >= owner.idle_expires_at)
		owner.node.network?.add_log("Охотничий процесс свёрнут: цель не найдена.")
		qdel(owner)
		return TRUE
	return FALSE

/datum/netrun_ice_behavior/availability
	id = "availability"
	priority = 20

/datum/netrun_ice_behavior/availability/advance(delta)
	if(owner.is_stunned() || !owner.node.is_online())
		owner.cancel_program()
		return TRUE
	return FALSE

/datum/netrun_ice_behavior/cast
	id = "cast"
	priority = 30

/datum/netrun_ice_behavior/cast/advance(delta)
	if(!owner.pending_program)
		return FALSE
	owner.agent.state = "программа: [owner.pending_program.name]"
	owner.resolve_program()
	return TRUE

/datum/netrun_ice_behavior/local_combat
	id = "local_combat"
	priority = 40

/datum/netrun_ice_behavior/local_combat/advance(delta)
	var/mob/camera/netrun_entity/prey = owner.find_intruder(owner.node)
	if(!prey)
		return FALSE
	owner.agent.state = "бой: [prey.real_name]"
	owner.idle_expires_at = world.time + owner.patrol_life * (1 SECONDS)
	owner.try_attack(prey)
	return TRUE

/datum/netrun_ice_behavior/trace
	id = "trace"
	priority = 50

/datum/netrun_ice_behavior/trace/advance(delta)
	if(owner.harass_intruders())
		owner.agent.state = "контртрассировка"
		return TRUE
	owner.agent.state = "охрана"
	return FALSE

/datum/netrun_ice_behavior/pursuit
	id = "pursuit"
	priority = 60

/datum/netrun_ice_behavior/pursuit/advance(delta)
	if(world.time < owner.hop_cooldown)
		return FALSE
	owner.agent.state = owner.hunt() ? "преследование" : "патруль"
	if(owner.agent.state == "патруль")
		owner.patrol()
	return TRUE

/// Illegal neural feedback uses the same telegraph, cancellation and shields as
/// every other ICE program. Only a delivered hostile effect can reach the body.
/datum/netrun_ice_behavior/biofeedback
	id = "biofeedback"
	priority = 70

/datum/netrun_ice_behavior/biofeedback/on_install()
	listen(owner, COMSIG_NETRUN_ICE_PROGRAM_RESOLVED, PROC_REF(on_resolved))

/datum/netrun_ice_behavior/biofeedback/proc/on_resolved(datum/source, datum/netrun_program/program, datum/target)
	SIGNAL_HANDLER
	if(!enabled || !(program.role in list(NETRUN_PROGRAM_ATTACK, NETRUN_PROGRAM_TRACE)))
		return
	var/mob/living/carbon/body
	if(istype(target, /mob/camera/netrun_entity))
		var/mob/camera/netrun_entity/entity = target
		body = entity.dive_link?.body
	else if(istype(target, /datum/netrun_console))
		var/datum/netrun_console/victim = target
		if(istype(victim.operator, /mob/living/carbon) && (victim.origin == NETRUN_ORIGIN_IMPLANT))
			body = victim.operator
	if(QDELETED(body) || body.stat == DEAD)
		return
	// Neural shielding mitigates feedback too; ordinary deck users only take trace.
	var/damage = 6
	if(istype(target, /mob/camera/netrun_entity))
		var/mob/camera/netrun_entity/entity = target
		if(world.time < entity.combat_shield_until)
			damage *= entity.combat_shield_factor
	body.adjustOrganLoss(ORGAN_SLOT_BRAIN, damage)
	body.adjustStaminaLoss(10)
	to_chat(body, span_userdanger("Чёрный ICE пробивает нейронный канал! Прервите взлом или покиньте узел."))

/// Contraband deployment is explicit, noisy and capped. It cannot appear as
/// ordinary station protection or in the public research loot pool.
/datum/netrun_daemon/black_ice
	id = "black_ice"
	name = "black_ice.exe"
	desc = "Нелегальный защитный агент с опасной нейронной обратной связью. Развёртывание требует ROOT и вызывает тревогу."
	size = 12
	bonus_kind = "black_ice"
	bonus = 1
	loot_weight = 0

/obj/item/netrun_shard/black_ice
	name = "data shard (BLACK ICE)"
	desc = "Контрабандный комплекс нейронного поражения. Не является штатной системой защиты."
	icon_state = "datadisk3"
	preload_daemons = list("black_ice")

/datum/uplink_item/stealthy_weapons/netrun_black_ice
	name = "Black ICE shard"
	desc = "Нелегальный сетевой защитник с нейронной обратной связью. Требует ROOT на выбранном узле и нейролинк у жертвы для поражения тела."
	item = /obj/item/netrun_shard/black_ice
	cost = 6

/datum/netrun_command/black_ice
	id = "black_ice"
	required_daemon = "black_ice"
	name = "Развернуть чёрный ICE"
	desc = "Запустить нелегального агента в узле. Опасен для всех, кроме развёрнувшего клиента. Поднимает тревогу."
	access = NETRUN_ACCESS_ROOT
	trace = 20
	danger = TRUE
	icon = "skull"

/datum/netrun_console
	var/next_black_ice = 0

/datum/netrun_command/black_ice/execute(datum/component/netrun_node/node, datum/netrun_console/console)
	if(!console.daemon_bonus("black_ice"))
		return "Нужен контрабандный black_ice.exe."
	if(world.time < console.next_black_ice)
		return "Развёртывание чёрного ICE ещё восстанавливается."
	var/count = 0
	for(var/datum/netrun_ice/ice as anything in SSnetrun.ice_processes)
		if(ice.kind != NETRUN_ICE_BLACK)
			continue
		count++
		if(ice.node == node)
			return "В этом узле уже есть чёрный ICE."
	if(count >= 4)
		return "Достигнут предел активных нелегальных агентов."
	var/datum/netrun_ice/ice = SSnetrun.spawn_ice(node, NETRUN_ICE_BLACK)
	if(!ice)
		return "Развёртывание не удалось."
	ice.deployer_ref = WEAKREF(console)
	console.next_black_ice = world.time + 2 MINUTES
	SSnetrun.report_incident("black_ice", node, null, NETRUN_INCIDENT_HIGH, "Обнаружен нелегальный BLACK ICE.")
	return "Чёрный ICE активен. Нейронная обратная связь опасна для подключённых раннеров; доступ USER не защищает от этого агента."
