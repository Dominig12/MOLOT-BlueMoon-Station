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
	/// Тело нетраннера, если это погружение
	var/mob/living/carbon/dive_body
	var/datum/action/innate/netrun_console/console_action
	var/datum/action/innate/netrun_rename/rename_action

/mob/camera/netrun_entity/Initialize(mapload, datum/component/netrun_node/start)
	. = ..()
	console = new(src, NETRUN_ORIGIN_ENTITY)
	SSnetrun.entities += src
	console_action = new
	console_action.Grant(src)
	rename_action = new
	rename_action.Grant(src)
	if(start)
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
	to_chat(src, span_notice("Вы — процесс в сети станции. Физически вы видите мир только через камеры, к которым у вас есть доступ: \
		перейдите в узел-камеру. Говорить и слышать можно через интеркомы — включите микрофон или динамик. Стрелки — переход \
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
	return TRUE

/mob/camera/netrun_entity/proc/leave_node()
	if(!host_node)
		return
	LAZYREMOVE(host_node.entities, src)
	host_node = null

/// Можно ли перепрыгнуть в узел
/mob/camera/netrun_entity/proc/can_enter(datum/component/netrun_node/node)
	return node && node != host_node && node.is_online() && console.node_level(node) >= NETRUN_ACCESS_USER

/mob/camera/netrun_entity/proc/hop(datum/component/netrun_node/node)
	if(world.time < next_hop || !can_enter(node))
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
	for(var/datum/component/netrun_node/node as anything in host_node.network.nodes)
		var/turf/there = get_turf(node.parent)
		if(!there || there.z != here.z || there == here)
			continue
		var/dist = get_dist(here, there)
		if(dist > 9 || dist >= best_dist || !(get_dir(here, there) & direct))
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
	update_vision()

// MARK: Зрение - только через доступные камеры

/mob/camera/netrun_entity/proc/current_camera()
	if(host_node?.node_type != NETRUN_NODE_CAMERA || !host_node.is_online())
		return null
	if(console.node_level(host_node) < NETRUN_ACCESS_GUEST)
		return null
	var/obj/machinery/camera/cam = host_node.parent
	return cam.status ? cam : null

/mob/camera/netrun_entity/proc/update_vision()
	if(!client)
		return
	var/obj/machinery/camera/cam = current_camera()
	if(cam)
		if(blinded)
			clear_fullscreen("netrun_blind")
			blinded = FALSE
		if(client.eye != cam)
			reset_perspective(cam)
		see_in_dark = 7
	else
		if(client.eye != src)
			reset_perspective(null)
		if(!blinded)
			overlay_fullscreen("netrun_blind", /atom/movable/screen/fullscreen/scaled/blind)
			blinded = TRUE

// MARK: Урон

/mob/camera/netrun_entity/proc/take_integrity(amount, reason)
	if(QDELETED(src))
		return
	integrity -= amount
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
	var/atom/movable/speaker = host_node?.parent
	if(!istype(speaker))
		to_chat(src, span_warning("Здесь нет динамика."))
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
	var/mob/camera/netrun_entity/entity = host
	var/datum/netrun_network/network = entity?.host_node?.network
	if(!network || network.isolated)
		return FALSE
	var/turf/T = get_turf(entity)
	return T && SSnetrun.backbone_online(T.z)

/datum/netrun_console/entity/user_access()
	return list()

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
