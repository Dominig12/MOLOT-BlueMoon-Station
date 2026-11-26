/**
 * NETRUN client window.
 *
 * One bounded projection per refresh and one action per interaction: the window never receives a host the
 * observer may not see, because the filtering happens in the Host before the payload is sent (UI-003). The
 * refresh is driven by the client itself, so a closed window costs nothing on the server.
 *
 * Until the device adapter maps a physical terminal to a NETRUN execution host, the window is a read-only
 * observer console opened from the debug tab. Attempting an action answers with a clear reason instead of
 * pretending that something happened.
 */
#define NETRUN_CLIENT_REFRESH (2 SECONDS)
#define NETRUN_CLIENT_HOSTS 64
#define NETRUN_CLIENT_ACTIONS 64
#define NETRUN_CLIENT_OPERATIONS 12

/datum/netrun_client
	/// Who is looking. The principal is derived from this, never chosen by the client.
	var/mob/owner
	/// The observer identity the Host knows this window by.
	var/principal
	/// Last projection accepted from the Host; null until the first answer.
	var/list/panel
	/// Last failure, shown instead of the map.
	var/error
	/// Last action answer, shown above the map.
	var/notice
	/// When the next request may be sent; keeps one refresh per window per interval.
	var/next_poll = 0
	/// Service instance of the device this window was opened from, when there is one.
	var/device_instance
	/// Network identity the actions travel as; null until the device is on the network.
	var/endpoint_id
	var/endpoint_generation = 0

/datum/netrun_client/New(mob/user)
	owner = user
	principal = netrun_principal_of(user)

/datum/netrun_client/Destroy()
	owner = null
	panel = null
	return ..()

/// Stable observer name for one player: the ckey, or "observer" for anything without one.
/proc/netrun_principal_of(mob/user)
	var/name = user?.ckey
	if(!name)
		return "observer"
	return copytext(name, 1, 64)

/datum/netrun_client/ui_state(mob/user)
	return GLOB.admin_state

/datum/netrun_client/ui_interact(mob/user, datum/tgui/ui)
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new(user, src, "NetrunView")
		ui.set_autoupdate(TRUE)
		ui.open()
	request_panel()

/datum/netrun_client/ui_close(mob/user)
	qdel(src)

/datum/netrun_client/ui_data(mob/user)
	// The window drives its own refresh: closed windows send nothing, open ones send one request per interval.
	if(world.time >= next_poll)
		request_panel()
	return list(
		"panel" = panel,
		"error" = error,
		"notice" = notice,
	)

/datum/netrun_client/ui_act(action, list/params, datum/tgui/ui, datum/ui_state/state)
	. = ..()
	if(.)
		return
	switch(action)
		if("refresh")
			next_poll = 0
			notice = null
			return TRUE
		if("execute")
			return execute(params)
		if("import")
			return import_program(params)
		if("travel")
			return travel(params)
		if("life")
			return life(params)

/**
 * Runs one action from this window. It travels as the operator's own network identity, so the Host
 * authorizes the same subject that the window shows, and the outcome is reported as a notice.
 */
/datum/netrun_client/proc/execute(list/params)
	var/action_id = params["action"]
	var/target = text2num(params["target"])
	if(!istext(action_id) || !target)
		return TRUE
	var/datum/controller/subsystem/netdm_observe/network = SSnetdm_observe
	if(!network?.services)
		notice = "Сеть недоступна."
		return TRUE
	var/list/execution = netrun_execution_host()
	if(!execution)
		notice = "Действия недоступны: терминал не привязан к цифровому хосту."
		return TRUE
	var/list/payload = list(
		"principal" = principal,
		"action" = action_id,
		"execution" = execution["id"],
		"target" = target,
		"key" = "ui-[world.time]-[rand(1, 1000000)]",
	)
	if(endpoint_id)
		payload["endpoint"] = endpoint_id
		payload["generation"] = endpoint_generation
	if(!network.services.control("netrun_execute", payload, CALLBACK(src, PROC_REF(on_action))))
		notice = "Канал занят, повторю позже."
		return TRUE
	return TRUE

/**
 * Presence and travel: enter where this device's host stands, move to another host over a route the transport
 * plans, or abort a move that has not landed. The answer carries where the presence stands and when it arrives.
 */
/**
 * Digital life from the window: make a backup on the selected host, move the core there, or restore it from a
 * backup. The Host decides everything; the window only names the intent and shows the answer.
 */
/datum/netrun_client/proc/life(list/params)
	var/verb = params["action"]
	var/target = text2num(params["target"])
	if(!istext(verb))
		return TRUE
	if(!SSnetdm_observe?.services)
		notice = "Сеть недоступна."
		return TRUE
	var/presence = panel?["presence"]
	var/identity = text2num(presence?["identity"])
	var/core = panel?["lives"]?[1]
	var/list/payload = list("action" = verb)
	if(verb == "create")
		payload["principal"] = principal
		payload["host"] = target
	else if(identity)
		payload["identity"] = identity
	else if(core)
		payload["identity"] = core["identity"]
	else
		notice = "Нет цифрового ядра: сначала создайте его на выбранном хосте."
		return TRUE
	if(verb != "create")
		if(!target)
			notice = "Выберите хост."
			return TRUE
		payload["host"] = target
		if(verb == "migrate")
			payload["destination"] = target
	if(!SSnetdm_observe.services.control("netrun_life", payload, CALLBACK(src, PROC_REF(on_life))))
		notice = "Канал занят, повторю позже."
		return TRUE
	return TRUE

/datum/netrun_client/proc/on_life(list/reply)
	if(QDELETED(src) || !islist(reply))
		return
	var/list/result = reply["result"]
	if(!reply["ok"] || !islist(result))
		notice = "Сеть отказала: [reply["error"] || "нет ответа"]"
		SStgui.update_uis(src)
		return
	switch(result["status"])
		if("ok")
			notice = "Ядро: [result["state"]], целостность [result["integrity"]], поколение [result["control"]]."
		if("insufficient_resources")
			notice = "Не хватает ресурсов на этом хосте."
		if("unknown_identity")
			notice = "Ядро не найдено."
		else
			notice = "Отказ: [result["status"]]"
	next_poll = 0
	SStgui.update_uis(src)

/datum/netrun_client/proc/travel(list/params)
	var/verb = params["mode"]
	var/destination = text2num(params["target"])
	if(!istext(verb) || (verb != "leave" && !destination))
		return TRUE
	if(!SSnetdm_observe?.services)
		notice = "Сеть недоступна."
		return TRUE
	var/list/presence = panel?["presence"]
	var/identity = text2num(presence?["identity"])
	if(verb != "enter" && !identity)
		notice = "Нет присутствия: сначала войдите на свой терминал."
		return TRUE
	var/list/payload = list("action" = verb)
	if(identity)
		payload["identity"] = identity
	if(verb == "enter")
		var/list/execution = netrun_execution_host()
		if(!execution)
			notice = "Вход невозможен: терминал не привязан к цифровому хосту."
			return TRUE
		var/presence_core = panel?["lives"]?[1]
		if(text2num(presence_core?["identity"]))
			payload["identity"] = text2num(presence_core?["identity"])
		payload["host"] = execution["id"]
	else
		payload["destination"] = destination
	if(!SSnetdm_observe.services.control("netrun_presence", payload, CALLBACK(src, PROC_REF(on_presence))))
		notice = "Канал занят, повторю позже."
		return TRUE
	return TRUE

/datum/netrun_client/proc/on_presence(list/reply)
	if(QDELETED(src) || !islist(reply))
		return
	var/list/result = reply["result"]
	if(!reply["ok"] || !islist(result))
		notice = "Сеть отказала: [reply["error"] || "нет ответа"]"
		SStgui.update_uis(src)
		return
	switch(result["status"])
		if("ok")
			notice = result["state"] == "traveling" ? "В пути: [result["hops"]] переходов." : "Присутствие активно."
		if("already_there")
			notice = "Вы уже здесь."
		if("no_transport")
			notice = "Маршрутов нет: сеть не знает дороги."
		if("no_route")
			notice = "Маршрут недоступен."
		if("busy")
			notice = "Вы уже в пути."
		if("host_unavailable")
			notice = "Этот хост не принимает присутствие."
		else
			notice = "Отказ: [result["status"]]"
	next_poll = 0
	SStgui.update_uis(src)

/datum/netrun_client/proc/on_action(list/reply)
	if(QDELETED(src) || !islist(reply))
		return
	var/list/result = reply["result"]
	if(!reply["ok"] || !islist(result))
		notice = "Сеть отказала: [reply["error"] || "нет ответа"]"
		return
	notice = "Итог: [result["status"]]"
	next_poll = 0
	SStgui.update_uis(src)

/**
 * Imports program text and starts it as this operator on this device. The text carries no rights: the Host
 * compiles it, starts it as the operator's principal and checks every action it invokes.
 */
/datum/netrun_client/proc/import_program(list/params)
	var/source = params["source"]
	if(!istext(source) || !length(source))
		notice = "Текст программы пуст."
		return TRUE
	if(length(source) > 8192)
		notice = "Программа слишком длинная."
		return TRUE
	var/datum/controller/subsystem/netdm_observe/network = SSnetdm_observe
	if(!network?.services)
		notice = "Сеть недоступна."
		return TRUE
	var/list/execution = netrun_execution_host()
	if(!execution)
		notice = "Действия недоступны: терминал не привязан к цифровому хосту."
		return TRUE
	var/list/payload = list(
		"principal" = principal,
		"source" = source,
		"execution" = execution["id"],
		// The player pressed the button: the import and the deployment are one deliberate act here.
		"confirm" = TRUE,
	)
	if(endpoint_id)
		payload["endpoint"] = endpoint_id
		payload["generation"] = endpoint_generation
	if(!network.services.control("netrun_program", payload, CALLBACK(src, PROC_REF(on_program))))
		notice = "Канал занят, повторю позже."
		return TRUE
	return TRUE

/datum/netrun_client/proc/on_program(list/reply)
	if(QDELETED(src) || !islist(reply))
		return
	var/list/result = reply["result"]
	if(!reply["ok"] || !islist(result))
		notice = "Программа отклонена: [reply["error"] || "нет ответа"]"
		return
	notice = "Программа запущена: [result["name"] || result["status"]]"
	next_poll = 0
	SStgui.update_uis(src)

/// The digital host this window acts from: the one declared for the device it was opened on.
/datum/netrun_client/proc/netrun_execution_host()
	var/datum/netrun_adapter/adapter = SSnetdm_observe?.netrun
	if(!adapter || !device_instance)
		return null
	return adapter.host_of(device_instance)

/// Binds the window to the device it was opened from and to the operator's network identity.
/datum/netrun_client/proc/bind_device(datum/netdm_service_lane/lane, datum/node, instance)
	device_instance = instance
	var/datum/netdm_service_endpoint/endpoint = lane?.endpoint_for(node)
	if(endpoint)
		endpoint_id = endpoint.id
		endpoint_generation = endpoint.generation
	return endpoint

/// Asks the Host for one projection. FALSE when the network cannot take the request right now.
/datum/netrun_client/proc/request_panel()
	next_poll = world.time + NETRUN_CLIENT_REFRESH
	var/datum/controller/subsystem/netdm_observe/network = SSnetdm_observe
	if(!network)
		error = "Сеть ещё не инициализирована."
		return FALSE
	if(!network.services)
		error = "Сетевой канал не готов."
		return FALSE
	var/list/payload = list(
		"principal" = principal,
		"hosts" = NETRUN_CLIENT_HOSTS,
		"actions" = NETRUN_CLIENT_ACTIONS,
		"operations" = NETRUN_CLIENT_OPERATIONS,
	)
	if(!network.services.control("netrun_panel", payload, CALLBACK(src, PROC_REF(on_panel))))
		error = "Канал занят, повторю позже."
		return FALSE
	return TRUE

/datum/netrun_client/proc/on_panel(list/reply)
	if(QDELETED(src))
		return
	if(!islist(reply) || !reply["ok"])
		var/reason = islist(reply) ? reply["error"] : null
		error = "Сеть не ответила: [reason || "нет ответа"]"
		return
	var/list/result = reply["result"]
	if(!islist(result))
		error = "Некорректный ответ сети."
		return
	panel = result
	error = null
	SStgui.update_uis(src)

/client/proc/netrun_console()
	set category = "Debug"
	set name = "NETRUN"
	if(!check_rights(R_DEBUG))
		return
	if(!SSnetdm_observe?.observing())
		to_chat(usr, span_warning("netDM Observe is disabled on this server."))
		return
	var/datum/netrun_client/client_window = new(usr)
	client_window.ui_interact(usr)

#undef NETRUN_CLIENT_REFRESH
#undef NETRUN_CLIENT_HOSTS
#undef NETRUN_CLIENT_ACTIONS
#undef NETRUN_CLIENT_OPERATIONS


/**
 * Opens the NETRUN window from a PDA that is already on the network. The window acts as the owner of the
 * device: it declares the device's host, gives the operator the rights of its own equipment and shows what
 * that operator may see.
 */
/obj/item/modular_computer/pda/verb/netrun_console()
	set name = "NETRUN"
	set category = "Object"
	set src in usr
	if(!usr || usr.incapacitated())
		return
	var/datum/controller/subsystem/netdm_observe/network = SSnetdm_observe
	if(!network?.observing())
		to_chat(usr, span_warning("Сеть недоступна на этом устройстве."))
		return
	var/datum/netdm_service_lane/lane = network.services
	if(!lane)
		to_chat(usr, span_warning("Сетевой канал ещё не готов."))
		return
	var/datum/netrun_adapter/adapter = network.netrun
	if(!adapter)
		to_chat(usr, span_warning("Цифровой слой ещё не готов."))
		return
	var/datum/node = adapter.node_for_device(src)
	var/instance = adapter.instance_for_node(node)
	if(!node || !instance)
		to_chat(usr, span_warning("Устройство не публикует сетевых сервисов."))
		return
	var/datum/netrun_client/window = new(usr)
	window.bind_device(lane, node, instance)
	var/principal = window.principal
	adapter.grant_operator(lane, principal, instance)
	window.ui_interact(usr)
