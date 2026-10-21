/**
 * Сетевая сущность: разум, живущий внутри узлов сети.
 * Видит и слышит вокруг узла-носителя, говорит его динамиком, прыгает по узлам.
 */
/mob/camera/netrun_entity
	name = "сетевая сущность"
	real_name = "сетевая сущность"
	desc = "Процесс, которому кто-то дал имя."
	see_in_dark = 2
	var/datum/component/netrun_node/host_node
	var/datum/netrun_console/entity/console
	var/blinded = FALSE
	var/integrity = 100
	var/max_integrity = 100
	var/next_hop = 0
	// Боевые состояния
	var/combat_stun_until = 0
	var/combat_shield_until = 0
	var/combat_shield_factor = 1
	/// Маршрут погружения: цепочка адресов узлов от точки входа
	var/list/route_chain = list()
	/// Адрес узла-точки входа при погружении (куда нужно вернуться телу)
	var/dive_entry_address
	/// Момент, с которого потеряна связь с точкой входа (0 - связь есть)
	var/severed_at = 0
	/// Тело нетраннера, если это погружение
	var/mob/living/carbon/dive_body
	var/datum/action/innate/netrun_console/console_action
	var/datum/action/innate/netrun_rename/rename_action

/mob/camera/netrun_entity/Initialize(mapload, datum/component/netrun_node/start)
	. = ..()
	console = new(src, NETRUN_ORIGIN_ENTITY)
	RegisterSignal(src, COMSIG_MOB_ALLOWED, PROC_REF(on_credential_access_check))
	SSnetrun.entities += src
	console_action = new
	console_action.Grant(src)
	rename_action = new
	rename_action.Grant(src)
	if(start)
		// Initial residency authorizes only this host, without opening its LAN.
		console.node_access[start.address] = NETRUN_ACCESS_USER
		enter_node(start)

/mob/camera/netrun_entity/Destroy()
	SSnetrun.entities -= src
	leave_node()
	QDEL_NULL(console)
	QDEL_NULL(console_action)
	QDEL_NULL(rename_action)
	if(dive_body)
		release_body()
	return ..()

/mob/camera/netrun_entity/Login()
	. = ..()
	if(!client)
		return
	to_chat(src, span_notice("Вы — процесс в сети станции. Мир виден через доступную оптику: камеры, киберглаза и взломанные HUD-очки. \
		В окне устройства включите «Смотреть». Говорить и слышать можно через интеркомы — включите микрофон или динамик. Стрелки — переход \
		к ближайшему узлу, кнопка «Сеть» открывает карту, взлом и переходы."))
	INVOKE_ASYNC(console, TYPE_PROC_REF(/datum, ui_interact), src)
	update_vision()

/mob/camera/netrun_entity/get_status_tab_items()
	. = ..()
	. += "Целостность: [integrity]/[max_integrity]"
	. += "Узел: [host_node ? "[host_node.get_name()] [host_node.address]" : "нет"]"
	if(console)
		. += "Трассировка: [round(console.trace)]%"

// MARK: Узлы

/mob/camera/netrun_entity/proc/enter_node(datum/component/netrun_node/node)
	if(!node)
		return FALSE
	leave_node()
	host_node = node
	LAZYADD(node.entities, src)
	abstract_move(get_turf(node.parent))
	console.viewed_network_id = node.network?.id
	console.selected_address = node.address
	node.touch()
	update_vision()
	track_route(node)
	SEND_SIGNAL(src, COMSIG_NETRUN_ENTITY_NODE_CHANGED, null, node)
	return TRUE

/// Запоминаем пройденный путь погружения. При возврате на уже пройденный узел
/// петля срезается - цепочка остаётся кратчайшей фактически пройденной.
/mob/camera/netrun_entity/proc/track_route(datum/component/netrun_node/node)
	if(!dive_body || !node?.address)
		return
	var/existing = route_chain.Find(node.address)
	if(existing)
		route_chain.Cut(existing + 1)
	else
		route_chain += node.address

/mob/camera/netrun_entity/proc/leave_node()
	if(!host_node)
		return
	var/datum/component/netrun_node/old = host_node
	LAZYREMOVE(host_node.entities, src)
	host_node = null
	SEND_SIGNAL(src, COMSIG_NETRUN_ENTITY_NODE_CHANGED, old, null)

/// Можно ли перепрыгнуть в узел
/mob/camera/netrun_entity/proc/can_enter(datum/component/netrun_node/node)
	if(!node || node == host_node || !host_node || console.is_locked())
		return FALSE
	console.refresh_route_node(host_node)
	console.refresh_route_node(node)
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	return (node.address in graph.neighbors(host_node.address)) && netrun_link_available(host_node, node) && (console.node_level(node) >= NETRUN_ACCESS_USER || console.has_key(node.network, TRUE))

/mob/camera/netrun_entity/proc/hop(datum/component/netrun_node/node)
	if(world.time < next_hop || is_stunned() || !can_enter(node))
		return FALSE
	next_hop = world.time + 1 SECONDS
	enter_node(node)
	return TRUE

/mob/camera/netrun_entity/Move(NewLoc, direct)
	if(!direct || !host_node?.network)
		return FALSE
	var/turf/here = get_turf(host_node.parent)
	var/datum/component/netrun_node/best
	var/best_dist = INFINITY
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	for(var/address in graph.neighbors(host_node.address))
		var/datum/component/netrun_node/node = graph.nodes[address]
		var/turf/there = get_turf(node.parent)
		if(!there || there.z != here.z || there == here)
			continue
		var/dist = get_dist(here, there)
		if(dist >= best_dist || !(get_dir(here, there) & direct))
			continue
		if(!can_enter(node))
			continue
		best = node
		best_dist = dist
	if(best)
		hop(best)
	return FALSE

/mob/camera/netrun_entity/forceMove(atom/destination)
	return abstract_move(destination)

/// Синхронизация с носителем, вызывается консолью раз в секунду
/mob/camera/netrun_entity/proc/process_tick(delta)
	if(host_node)
		var/turf/T = get_turf(host_node.parent)
		if(T && loc != T)
			abstract_move(T)
	if(integrity < max_integrity && world.time - console.last_illegal > 20 SECONDS)
		integrity = min(max_integrity, integrity + delta * 0.5)
	if(dive_body)
		dive_body.SetUnconscious(5 SECONDS)
		check_dive_link(delta)
		if(QDELETED(src))
			return
	update_vision()
	SEND_SIGNAL(src, COMSIG_NETRUN_ENTITY_TICK, delta)

/// Есть ли ещё физический маршрут от текущего узла назад к точке входа погружения.
/mob/camera/netrun_entity/proc/dive_link_intact()
	if(!dive_entry_address)
		return TRUE
	var/datum/component/netrun_node/entry = SSnetrun.find_node(dive_entry_address)
	if(QDELETED(entry) || QDELETED(entry.parent))
		return FALSE
	if(!host_node)
		return FALSE
	if(host_node == entry)
		return TRUE
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	var/list/queue = list(host_node.address)
	var/list/seen = list()
	seen[host_node.address] = TRUE
	for(var/i = 1, i <= length(queue), i++)
		var/address = queue[i]
		var/datum/component/netrun_node/current = graph.nodes[address]
		if(QDELETED(current) || !current.is_online())
			continue
		for(var/neighbor in graph.neighbors(address))
			if(seen[neighbor])
				continue
			if(!netrun_link_available(current, graph.nodes[neighbor]))
				continue
			if(neighbor == entry.address)
				return TRUE
			seen[neighbor] = TRUE
			queue += neighbor
	return FALSE

/// Обрезали маршрут к телу: сначала нарастающий урон мозгу, затем - либо гибель
/// тела с остаточным процессом в сети, либо жёсткий аварийный выход.
/mob/camera/netrun_entity/proc/check_dive_link(delta)
	if(!dive_body)
		return
	if(dive_link_intact())
		if(severed_at)
			severed_at = 0
			to_chat(src, span_notice("Канал связи с телом восстановлен."))
		return
	if(!severed_at)
		severed_at = world.time
		to_chat(src, span_userdanger("СВЯЗЬ С ТЕЛОМ ПОТЕРЯНА! Маршрут к точке входа обрезан — срочно восстановите путь!"))
		SEND_SOUND(src, sound('sound/machines/warning-buzzer.ogg', volume = 60))
	var/mob/living/carbon/body = dive_body
	body.adjustOrganLoss(ORGAN_SLOT_BRAIN, 3 * delta)
	var/severed_for = world.time - severed_at
	if(severed_for < 15 SECONDS)
		return
	// Точка входа уничтожена безвозвратно - тело гибнет, процесс остаётся в сети.
	var/datum/component/netrun_node/entry = SSnetrun.find_node(dive_entry_address)
	if(QDELETED(entry) || QDELETED(entry.parent))
		to_chat(src, span_userdanger("Точка входа уничтожена. Ваше тело гибнет, а процесс остаётся заперт в сети."))
		body.adjustOrganLoss(ORGAN_SLOT_BRAIN, 80)
		body.death()
		strand_in_network()
		return
	// Путь восстановить ещё можно, но система рвёт соединение с тяжёлым уроном мозгу.
	to_chat(src, span_userdanger("Аварийный разрыв соединения!"))
	body.adjustOrganLoss(ORGAN_SLOT_BRAIN, 55)
	return_to_body()

/// Процесс теряет связь с мёртвым телом и остаётся самостоятельной сущностью в сети.
/mob/camera/netrun_entity/proc/strand_in_network()
	if(!dive_body)
		return
	release_body()
	dive_entry_address = null
	severed_at = 0
	set_net_name("GHOST-[uppertext(copytext(md5("[world.time][rand(1, 99999)]"), 1, 5))]", "Заблудший процесс")
	to_chat(src, span_warning("Вы больше не связаны с телом. Вы — процесс, застрявший в сети станции."))

// MARK: Зрение через доступные оптические устройства

/mob/camera/netrun_entity/proc/vision_source()
	// An explicitly opened stream takes priority over the entity's physical host.
	var/datum/netrun_console/view_console = netrun_watch_console || console
	if(view_console?.watch_target())
		return view_console.watch_node.parent
	if(QDELETED(host_node) || !host_node.is_online())
		return null
	if(console.node_level(host_node) < NETRUN_ACCESS_USER)
		return null
	var/atom/source = host_node.parent
	return source.netrun_view_target() ? source : null

/mob/camera/netrun_entity/proc/current_vision_target()
	var/atom/source = vision_source()
	return source?.netrun_view_target()

/mob/camera/netrun_entity/proc/update_vision()
	if(!client)
		return
	var/atom/source = vision_source()
	var/atom/eye = source?.netrun_view_target()
	if(eye)
		var/datum/netrun_console/view_console = netrun_watch_console || console
		if(view_console?.watch_target() && view_console.watch_eye)
			eye = view_console.watch_eye
		if(blinded)
			clear_fullscreen("netrun_blind")
			blinded = FALSE
		if(client.eye != eye)
			reset_perspective(eye)
		var/list/settings = source.netrun_view_settings()
		see_in_dark = settings["see_in_dark"]
		sight = settings["sight"]
		see_invisible = settings["see_invisible"]
		clear_fullscreen("remote_view", 0)
		var/atom/source_eye = source.netrun_view_target()
		source_eye?.get_remote_view_fullscreens(src)
	else
		clear_fullscreen("remote_view", 0)
		see_in_dark = initial(see_in_dark)
		sight = initial(sight)
		see_invisible = initial(see_invisible)
		if(client.eye != src)
			reset_perspective(null)
		if(!blinded)
			overlay_fullscreen("netrun_blind", /atom/movable/screen/fullscreen/scaled/blind)
			blinded = TRUE

// MARK: Боевой интерфейс

/mob/camera/netrun_entity/proc/combat_name()
	return real_name

/mob/camera/netrun_entity/proc/is_stunned()
	return world.time < combat_stun_until

/mob/camera/netrun_entity/proc/apply_damage(amount, reason, datum/netrun_console/attacker)
	if(world.time < combat_shield_until)
		amount *= combat_shield_factor
	take_integrity(amount, reason)

/mob/camera/netrun_entity/proc/apply_stun(duration)
	combat_stun_until = max(combat_stun_until, world.time + duration)
	to_chat(src, span_userdanger("Ваш процесс оглушён!"))

/mob/camera/netrun_entity/proc/apply_shield(pct, duration)
	combat_shield_until = world.time + duration
	combat_shield_factor = clamp(1 - pct / 100, 0.1, 1)

/mob/camera/netrun_entity/proc/apply_heal(amount)
	integrity = min(max_integrity, integrity + amount)
	to_chat(src, span_notice("Целостность восстановлена: [round(integrity)]/[max_integrity]."))

// MARK: Урон

/mob/camera/netrun_entity/proc/take_integrity(amount, reason)
	if(QDELETED(src))
		return
	integrity -= amount
	SEND_SIGNAL(src, COMSIG_NETRUN_ENTITY_INTEGRITY, integrity, max_integrity, reason)
	to_chat(src, span_userdanger("Целостность нарушена[reason ? ": [reason]" : ""]! ([max(0, round(integrity))]/[max_integrity])"))
	if(integrity <= 0)
		dissolve()

/// Принудительно выбросить сущность из текущего узла (команда purge)
/mob/camera/netrun_entity/proc/eject_from_node()
	var/datum/component/netrun_node/old = host_node
	var/datum/netrun_network/network = old?.network
	var/list/candidates = list()
	for(var/datum/component/netrun_node/candidate as anything in network?.nodes)
		if(candidate != old && candidate.is_online())
			candidates += candidate
	if(!length(candidates))
		var/datum/netrun_network/public = SSnetrun.get_network(NETRUN_LAN_PUBLIC)
		for(var/datum/component/netrun_node/candidate as anything in public.nodes)
			if(candidate.is_online())
				candidates += candidate
	to_chat(src, span_userdanger("Вас вычищают из узла [old?.address]!"))
	if(length(candidates))
		enter_node(pick(candidates))
	else
		leave_node()
		update_vision()

/mob/camera/netrun_entity/proc/host_lost()
	var/datum/netrun_network/network = host_node?.network
	leave_node()
	if(QDELETED(src))
		return
	var/list/candidates = list()
	for(var/datum/component/netrun_node/node as anything in network?.nodes)
		if(node.is_online() && !QDELETED(node.parent))
			candidates += node
	if(!length(candidates))
		to_chat(src, span_userdanger("Узел-носитель уничтожен, бежать некуда."))
		dissolve()
		return
	enter_node(pick(candidates))
	take_integrity(30, "узел-носитель уничтожен")

/mob/camera/netrun_entity/netrun_traced(datum/netrun_console/traced)
	take_integrity(40, "ответный удар системы защиты")
	if(QDELETED(src))
		return
	var/datum/netrun_network/public = SSnetrun.get_network(NETRUN_LAN_PUBLIC)
	if(length(public.nodes))
		enter_node(pick(public.nodes))

/mob/camera/netrun_entity/proc/dissolve()
	if(QDELETED(src))
		return
	if(dive_body)
		to_chat(src, span_userdanger("Связь с сетью разорвана! Вас выбрасывает обратно в тело."))
		var/mob/living/carbon/body = dive_body
		return_to_body()
		body.adjustOrganLoss(ORGAN_SLOT_BRAIN, 30)
		body.Paralyze(10 SECONDS)
		return
	to_chat(src, span_userdanger("Ваш процесс распадается на шум."))
	host_node?.network?.add_log("Резидентный процесс [real_name] завершён.")
	ghostize(FALSE)
	qdel(src)

// MARK: Речь

/mob/camera/netrun_entity/say(message, bubble_type, list/spans = list(), sanitize = TRUE, datum/language/language = null, ignore_spam = FALSE, forced = null)
	if(!message)
		return
	if(client)
		if(client.prefs.muted & MUTE_IC)
			to_chat(src, span_danger("Вы не можете говорить (мут)."))
			return
		if(!(ignore_spam || forced) && client.handle_spam_prevention(message, MUTE_IC))
			return
	message = trim(copytext_char(sanitize(message), 1, MAX_MESSAGE_LEN))
	if(!length(message))
		return
	// Процессы, делящие узел, слышат друг друга напрямую по внутренней шине -
	// даже если у узла нет динамика для внешнего мира.
	var/heard_locally = FALSE
	for(var/mob/camera/netrun_entity/other as anything in host_node?.entities)
		to_chat(other, span_notice("\[шина [host_node.address]] [span_name(real_name)]: [message]"))
		if(other != src)
			heard_locally = TRUE
	var/atom/movable/speaker = host_node?.parent
	if(!istype(speaker))
		if(!heard_locally)
			to_chat(src, span_warning("Здесь нет ни динамика, ни других процессов."))
		return
	log_talk(message, LOG_SAY, tag = "netrun via [speaker]")
	if(istype(speaker, /obj/item/radio/intercom))
		var/obj/item/radio/intercom/intercom = speaker
		if(!intercom.on || intercom.emped)
			to_chat(src, span_warning("Интерком обесточен."))
			return
		if(intercom.broadcasting) // микрофон включён — голос уходит в эфир
			intercom.talk_into(src, message, null, spans)
		// динамик интеркома: локальный вывод голоса
		intercom.audible_message(span_name("[intercom]") + span_radio(" передаёт, \"[message]\""), null, intercom.canhear_range)
		return
	speaker.audible_message(span_name("[speaker]") + span_radio(" передаёт, \"[message]\""))

/mob/camera/netrun_entity/emote(act, m_type = 1, message = null, intentional = FALSE, forced = FALSE)
	return

// MARK: Погружение

/// Нетраннер уходит в сеть: тело без сознания, разум - в сущности
/proc/netrun_start_dive(mob/living/carbon/body, datum/component/netrun_node/start)
	if(!body?.mind || !start)
		return
	var/mob/camera/netrun_entity/entity = new(get_turf(start.parent), start)
	entity.set_net_name(body.real_name, "Нетраннер")
	entity.dive_body = body
	entity.dive_entry_address = start.address
	entity.route_chain = list(start.address)
	entity.RegisterSignal(body, COMSIG_MOB_APPLY_DAMAGE, TYPE_PROC_REF(/mob/camera/netrun_entity, on_body_damage))
	entity.RegisterSignal(body, COMSIG_LIVING_DEATH, TYPE_PROC_REF(/mob/camera/netrun_entity, on_body_death))
	body.SetUnconscious(5 SECONDS)
	body.mind.transfer_to(entity)
	body.visible_message(span_notice("[body] обмякает, глаза закатываются под веки."))
	return entity

/mob/camera/netrun_entity/proc/on_body_damage(datum/source, damage, damagetype)
	SIGNAL_HANDLER
	if(damage < 5 || !(damagetype in list(BRUTE, BURN)))
		return
	to_chat(src, span_userdanger("Ваше тело ранено! Аварийный выход из сети!"))
	INVOKE_ASYNC(src, PROC_REF(return_to_body))

/mob/camera/netrun_entity/proc/on_body_death(datum/source)
	SIGNAL_HANDLER
	INVOKE_ASYNC(src, PROC_REF(return_to_body))

/mob/camera/netrun_entity/proc/return_to_body()
	if(!dive_body)
		return
	var/mob/living/carbon/body = dive_body
	release_body()
	if(mind)
		mind.transfer_to(body)
	body.SetUnconscious(0)
	if(body.stat != DEAD)
		to_chat(body, span_notice("Вы выныриваете из сети. Голова гудит."))
	qdel(src)

/mob/camera/netrun_entity/proc/release_body()
	UnregisterSignal(dive_body, list(COMSIG_MOB_APPLY_DAMAGE, COMSIG_LIVING_DEATH))
	dive_body = null

// MARK: Консоль сущности

/datum/netrun_console/entity
	name = "сознание"
	origin = NETRUN_ORIGIN_ENTITY
	tgui_title = "Сеть"
	storage_capacity = 10

/datum/netrun_console/entity/New(atom/host, origin)
	. = ..()
	state_override = GLOB.always_state

/datum/netrun_console/entity/proc/entity()
	return host

/datum/netrun_console/entity/home_networks()
	. = list()
	var/mob/camera/netrun_entity/entity = host
	if(entity?.host_node?.network)
		. += entity.host_node.network

/datum/netrun_console/entity/has_uplink()
	return ..()

/datum/netrun_console/entity/user_access(fresh = FALSE)
	if(!fresh && access_cache)
		return access_cache
	return credential_access(fresh)

/datum/netrun_console/entity/log_source()
	return "резидентный процесс"

/datum/netrun_console/entity/process_tick(delta)
	. = ..()
	var/mob/camera/netrun_entity/entity = host
	entity?.process_tick(delta)

/datum/netrun_console/entity/host_actions()
	. = ..()
	var/mob/camera/netrun_entity/entity = host
	if(entity?.dive_body)
		. += list(list("id" = "return", "name" = "Вернуться в тело", "icon" = "person-walking-arrow-right"))

/datum/netrun_console/entity/host_act(action, list/params, mob/user)
	var/mob/camera/netrun_entity/entity = host
	switch(action)
		if("hop")
			if(!entity.hop(SSnetrun.find_node(params["address"])))
				log_line("Переход невозможен: нужен доступ ПОЛЬЗОВАТЕЛЯ к узлу.", "bad")
			return TRUE
		if("return")
			entity.return_to_body()
			return TRUE
	return ..()

/datum/netrun_console/entity/entity_data()
	var/mob/camera/netrun_entity/entity = host
	if(!entity)
		return null
	return list(
		"name" = entity.real_name,
		"integrity" = round(entity.integrity),
		"max_integrity" = entity.max_integrity,
		"host" = entity.host_node?.address,
		"host_name" = entity.host_node?.get_name(),
		"diving" = !!entity.dive_body,
	)

/datum/action/innate/netrun_console
	name = "Сеть"
	desc = "Открыть карту сети."
	button_icon_state = "camera_jump"
	icon_icon = 'icons/mob/actions/actions_silicon.dmi'
	background_icon_state = "bg_tech_blue"

/datum/action/innate/netrun_console/Activate()
	var/mob/camera/netrun_entity/entity = owner
	if(istype(entity))
		entity.console.ui_interact(entity)

/datum/action/innate/netrun_rename
	name = "Переименовать"
	desc = "Задать имя процесса."
	button_icon_state = "repeat"
	icon_icon = 'icons/mob/actions/actions_silicon.dmi'
	background_icon_state = "bg_tech_blue"

/datum/action/innate/netrun_rename/Activate()
	var/mob/camera/netrun_entity/entity = owner
	if(!istype(entity))
		return
	var/new_name = tgui_input_text(entity, "Имя процесса", "Переименование", entity.real_name, 42)
	new_name = reject_bad_name(new_name, allow_numbers = TRUE)
	if(!new_name)
		return
	entity.set_net_name(new_name)
	to_chat(entity, span_notice("Имя изменено на [new_name]."))
