// netDM network immersion (P13): the neuro-link implant lets a conscious operator dive into the network
// from an access point. The body stays behind in a trance: it cannot walk, it drops what it held, it is
// visible to the crew and it can be hurt, robbed or have the implant taken. Losing the implant, the access
// point or life ends the dive at once. The layer is off unless the round is started with
// NETDM_NET_IMMERSION=1: an ordinary round does not get network bodies by default.
//
// The dive adds no authority: every action still goes through the implant's endpoint and the entry
// device's permissions. The immersive screen is a presentation of the same window, not a second channel.

/// One operator's dive. SSnetdm_observe keeps the registry, keyed by the body's weakref.
/datum/netdm_immersion
	var/mob/living/operator
	var/datum/weakref/operator_ref
	var/obj/item/implant/netdm_terminal/implant
	var/datum/weakref/implant_ref
	var/datum/netdm_space/window
	var/blip_timer
	var/check_timer
	var/ended = FALSE

/datum/netdm_immersion/New(mob/living/user, obj/item/implant/netdm_terminal/link, datum/netdm_space/space)
	operator = user
	operator_ref = WEAKREF(user)
	implant = link
	implant_ref = WEAKREF(link)
	window = space
	check_timer = addtimer(CALLBACK(src, PROC_REF(pass)), 2 SECONDS, TIMER_STOPPABLE)
	if(user)
		RegisterSignal(user, COMSIG_PARENT_QDELETING, PROC_REF(on_body_gone))
	if(link)
		RegisterSignal(link, COMSIG_PARENT_QDELETING, PROC_REF(on_implant_gone))
	return ..()

/datum/netdm_immersion/Destroy()
	deltimer(check_timer)
	ended = TRUE
	if(operator)
		UnregisterSignal(operator, COMSIG_PARENT_QDELETING)
	if(implant)
		UnregisterSignal(implant, COMSIG_PARENT_QDELETING)
	operator = null
	implant = null
	window = null
	return ..()

/datum/netdm_immersion/proc/on_body_gone(datum/source)
	SIGNAL_HANDLER
	if(!ended)
		surface("body_lost")

/datum/netdm_immersion/proc/on_implant_gone(datum/source)
	SIGNAL_HANDLER
	if(!ended)
		surface("implant_lost")

/// The trance keeps the body planted and its hands empty; the screen overlay and sounds are the dive.
/datum/netdm_immersion/proc/pass()
	if(ended)
		return
	check_timer = addtimer(CALLBACK(src, PROC_REF(pass)), 2 SECONDS, TIMER_STOPPABLE)
	var/mob/living/user = operator_ref?.resolve()
	var/obj/item/implant/netdm_terminal/link = implant_ref?.resolve()
	if(!user || user.stat == DEAD || user.incapacitated())
		surface("body_unfit")
		return
	if(!link || link.imp_in != user || !SSnetdm_observe?.observing())
		surface("implant_lost")
		return
	if(!window || QDELETED(window))
		surface("window_closed")
		return
	if(islist(window.presence) && window.presence["state"] != "active")
	{
		// The network threw the operator out (an intrusion) or the session ended under it: the mind returns.
		surface("presence_lost")
		return
	}
	if(!netdm_access_point(user))
		surface("access_point_lost")
		return
	// The body does not move while the mind is elsewhere. A short refresh leaves other systems in charge
	// of their own stun/sleep timers instead of faking a second source of truth.
	user.Immobilize(4 SECONDS)

/// P13: a quiet reminder that the mind is still connected: a terminal prompt every ~45 seconds.
/datum/netdm_immersion/proc/blip()
	blip_timer = null
	var/mob/living/user = operator_ref?.resolve()
	if(ended || !user || QDELETED(user))
		return
	if(user.client)
		SEND_SOUND(user, sound('sound/machines/terminal_prompt.ogg', volume = 18))
	blip_timer = addtimer(CALLBACK(src, PROC_REF(blip)), 45 SECONDS, TIMER_STOPPABLE)

/datum/netdm_immersion/proc/surface(reason, silent = FALSE)
	if(ended)
		return
	ended = TRUE
	deltimer(check_timer)
	deltimer(blip_timer)
	var/mob/living/user = operator_ref?.resolve()
	if(window && !QDELETED(window))
		window.immersed = FALSE
		window.immersed_reason = reason
	if(user && !QDELETED(user))
		user.clear_fullscreen("netdm_immersion", 0)
		REMOVE_TRAIT(user, TRAIT_HANDS_BLOCKED, NETDM_IMMERSION_TRAIT)
		REMOVE_TRAIT(user, NETDM_IMMERSION_TRAIT, NETDM_IMMERSION_TRAIT)
		if(user.client)
			SEND_SOUND(user, sound('sound/machines/terminal_off.ogg'))
		if(!silent)
			to_chat(user, span_warning("Погружение завершено: [immersion_reason_text(reason)]."))
		user.visible_message(span_notice("[user] приходит в себя, взгляд снова осмысленный."), null, null, null, list(user))
	SSnetdm_observe?.netdm_immersions -= operator_ref
	qdel(src)

/proc/immersion_reason_text(reason)
	switch(reason)
		if("implant_lost")
			return "имплант извлечён или уничтожен"
		if("access_point_lost")
			return "потеряна точка доступа"
		if("body_unfit")
			return "тело потеряло сознание"
		if("body_lost")
			return "тело погибло"
		if("presence_lost")
			return "присутствие потеряно (вторжение или разрыв сессии)"
		if("window_closed")
			return "окно сети закрыто"
		if("cancelled")
			return "прервано"
	return "[reason]"

/// The access point the body is served by: a working APC of its zone with a network module. A body in a
/// zone without one cannot dive: only an APC's access point can carry the implant's traffic.
/proc/netdm_access_point(atom/where)
	var/area/physical = get_area(where)
	if(!physical)
		return null
	var/area/zone = netdm_power_area(physical)
	if(!zone)
		return null
	var/obj/machinery/power/apc/apc = zone.power_apc
	if(apc && !QDELETED(apc) && netdm_access_point_ok(apc))
		return apc
	// A zone may hold several APCs (decided 14.11.2026). Use the zone's registered one when it works,
	// otherwise the first working APC of the same zone: the body still has a physical access point.
	for(var/obj/machinery/power/apc/other as anything in GLOB.apcs_list)
		if(netdm_power_area(get_area(other)) != zone)
			continue
		if(netdm_access_point_ok(other))
			return other
	return null

/// A powered, operational APC of the published network can carry the implant's traffic. APCs are access
/// points in the exported APC map; unlike machines they have no component of their own.
/proc/netdm_access_point_ok(obj/machinery/power/apc/apc)
	if(!apc || QDELETED(apc))
		return FALSE
	if((apc.netdm_state() & NETDM_STATE_UP) != NETDM_STATE_UP)
		return FALSE
	return !!SSnetdm_observe?.apc_node_id(apc)

/// TRUE when the round allows diving at all: the layer is opt-in.
/proc/netdm_immersion_enabled()
	return world.GetConfig("env", "NETDM_NET_IMMERSION") == "1"

/// Starts the dive from an open network window of the neuro-link implant.
/datum/netdm_space/proc/immerse()
	if(immersed)
		return TRUE
	if(!netdm_immersion_enabled())
		note("Погружение выключено на этом раунде.")
		return FALSE
	var/datum/netdm_terminal/local/implant/lens = terminal
	var/mob/living/user = lens?.user_ref?.resolve()
	var/obj/item/implant/netdm_terminal/implant = lens?.device_ref?.resolve()
	if(!user || !implant || implant.imp_in != user || !implant.neural)
		note("Нужен исправный нейролинк в голове.")
		return FALSE
	if(user.stat != CONSCIOUS || user.incapacitated())
		note("Тело должно быть в сознании.")
		return FALSE
	if(!netdm_access_point(user))
		note("Нет работающей точки доступа: нужен исправный АПЦ зоны с сетевым модулем.")
		return FALSE
	if(presence && presence["state"] == "moving")
		note("Присутствие в пути: погружение начнётся после прибытия.")
		return FALSE
	if(!enter())
		return FALSE
	var/datum/netdm_immersion/dive = new(user, implant, src)
	dive.blip_timer = addtimer(CALLBACK(dive, TYPE_PROC_REF(/datum/netdm_immersion, blip)), 45 SECONDS, TIMER_STOPPABLE)
	SSnetdm_observe.netdm_immersions[WEAKREF(user)] = dive
	immersed = TRUE
	immersed_reason = ""
	ADD_TRAIT(user, TRAIT_HANDS_BLOCKED, NETDM_IMMERSION_TRAIT)
	ADD_TRAIT(user, NETDM_IMMERSION_TRAIT, NETDM_IMMERSION_TRAIT)
	user.overlay_fullscreen("netdm_immersion", /atom/movable/screen/fullscreen/scaled/blind)
	user.drop_all_held_items()
	playsound(user, 'sound/machines/terminal_on.ogg', 40, TRUE)
	user.visible_message(span_notice("[user] замирает, взгляд стекленеет: нейролинк подключён к сети."), null, null, null, list(user))
	to_chat(user, span_notice("Нейролинк подключён. Тело осталось у точки доступа."))
	note("Погружение начато.")
	return TRUE

/datum/netdm_space/proc/immersion_of()
	for(var/key in SSnetdm_observe?.netdm_immersions)
		var/datum/netdm_immersion/dive = SSnetdm_observe.netdm_immersions[key]
		if(dive && dive.window == src)
			return dive
	return null

/datum/netdm_space/proc/surface_immersion(reason = "cancelled")
	var/datum/netdm_immersion/dive = immersion_of()
	if(dive)
		dive.surface(reason)
	immersed = FALSE
	return TRUE

/// A window closing while the operator is diving ends the dive, like any other loss of the lens.
/datum/netdm_space/proc/immersion_closed()
	var/datum/netdm_immersion/dive = immersion_of()
	if(dive)
		dive.surface("window_closed")
	immersed = FALSE


// ---- Admin tools (P13) ---------------------------------------------------------------------

/// Seeds a few NPC agents over the Host control plane. A tool for interested rounds, not content:
/// without the layer this does nothing at all.
/client/proc/netdm_network_life()
	set name = "netDM: Seed Network Agents"
	set category = "Admin"
	if(!check_rights(R_ADMIN))
		return
	if(!SSnetdm_observe?.observing() || !SSnetdm_observe.services)
		to_chat(src, span_warning("netDM Observe не запущен."))
		return
	if(world.GetConfig("env", "NETDM_NET_LIFE") != "1")
		to_chat(src, span_warning("Слой сетевой жизни выключен: нужны NETDM_NET_LIFE=1 у мира и NetDM__NetLife=1 у Host."))
		return
	var/action = input(src, "Действие с населением сети", "Сетевая жизнь") as null|anything in list("Посмотреть", "Добавить", "Убрать")
	if(!action)
		return
	if(action == "Посмотреть")
		if(!SSnetdm_observe.services.control("network_life", list("action" = "inspect"),
			CALLBACK(GLOBAL_PROC, GLOBAL_PROC_REF(netdm_network_life_status), src)))
			to_chat(src, span_warning("Сеть занята: повторите через секунду."))
		return
	var/count_text = input(src, "Сколько агентов", "Сетевая жизнь") as null|anything in list("1", "2", "3", "4", "8")
	if(!count_text)
		return
	var/count = text2num("[count_text]")
	var/list/payload = list("action" = action == "Добавить" ? "spawn" : "retire", "count" = count)
	if(action == "Добавить")
		var/goal = input(src, "Цель агента", "Сетевая жизнь") as null|anything in list("sentinel", "watcher", "archivist", "courier", "intruder")
		if(!goal)
			return
		payload["goal"] = goal
	if(!SSnetdm_observe.services.control("network_life", payload,
		CALLBACK(GLOBAL_PROC, GLOBAL_PROC_REF(netdm_network_life_answered), src)))
		to_chat(src, span_warning("Сеть занята: повторите через секунду."))

/proc/netdm_network_life_answered(client/admin, list/reply)
	if(!admin)
		return
	var/list/result = reply?["result"]
	if(reply?["ok"])
		to_chat(admin, span_notice("Сетевая жизнь: агентов добавлено [result?["spawned"]], всего [result?["total"]]."))
	else
		to_chat(admin, span_warning("Сеть отказала: [reply?["error"] || "нет ответа"]."))

/// P13: true while the operator is diving; world clicks belong to the network window then.
/proc/netdm_click_blocked(mob/user)
	return isliving(user) && HAS_TRAIT(user, NETDM_IMMERSION_TRAIT)

/// P13 admin: the current population as the operator sees it (an 'inspect' control answer).
/proc/netdm_network_life_status(client/admin, list/reply)
	if(!admin)
		return
	if(!reply?["ok"])
		to_chat(admin, span_warning("Сеть отказала: [reply?["error"] || "нет ответа"]."))
		return
	var/list/result = reply?["result"]
	to_chat(admin, span_notice("Население сети: [result?["total"] || "?"] агентов, узлы: [result?["nodes"] ? jointext(result["nodes"], ", ") : "—"]."))