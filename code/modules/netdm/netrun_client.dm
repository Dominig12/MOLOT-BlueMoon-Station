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
			notice = "Действия недоступны: терминал не привязан к цифровому хосту."
			return TRUE

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
