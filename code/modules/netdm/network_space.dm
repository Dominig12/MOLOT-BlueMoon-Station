/// How often an open network window reads the changes of its operator's knowledge and presence.
#define NETDM_SPACE_REFRESH (2 SECONDS)
/// An item unconfirmed for this long is drawn as stale (decision Р3 of the P12 design).
#define NETDM_SPACE_FRESH (60 SECONDS)
/// Items a window keeps whatever the Host sends; the Host keeps at most 512 nodes, 1024 links, 512 services.
#define NETDM_SPACE_ITEMS 2048
/// Lines of the window's action log.
#define NETDM_SPACE_LOG 12
/// Requests of one window in flight at once.
#define NETDM_SPACE_PENDING 4

/// Topology screen flags reused by the window's map (tgui NetdmTopology/model.ts).
#define NETDM_SPACE_FLAG_DEVICE 8
#define NETDM_SPACE_FLAG_APC 16
#define NETDM_SPACE_FLAG_UNPOWERED 32

/**
 * P12.4 · the player's network window (docs/network-space-design.ru.md, decisions Р1–Р6 of 14.11.2026).
 *
 * Opened from a network terminal, it shows what the operator knows of the network (the terminal's
 * endpoint is the operator) and its presence, and sends the presence commands of network.shell:
 * scan, enter, leave, move and act. Everything is a network command answered by the Host: the window
 * only draws what came back. Closing the window detaches the presence (Р6: it is suspended, and ends
 * after 5 minutes away). It refreshes every NETDM_SPACE_REFRESH while open.
 */
/datum/netdm_space
	var/datum/netdm_terminal/terminal
	/// Item key -> fields. Keys: "n|id", "l|a|b", "s|instance".
	var/list/items = list()
	var/revision = 0
	/// The last answer about the presence.
	var/list/presence
	var/list/log = list()
	var/z
	var/pending = 0
	var/refresh_timer

/datum/netdm_space/New(datum/netdm_terminal/opener)
	terminal = opener
	terminal.space = src
	refresh()

/datum/netdm_space/Destroy()
	deltimer(refresh_timer)
	// Р6: a closed window leaves the presence suspended where it stands.
	if(presence && presence["state"] != "ended" && presence["status"] != "none")
		send("detach", list("note" = "window"), CALLBACK(SSnetdm_observe.diagnostics, TYPE_PROC_REF(/datum/netdm_diagnostics, space_ignored)))
	if(terminal?.space == src)
		terminal.space = null
	terminal = null
	return ..()

/datum/netdm_space/ui_host(mob/user)
	return terminal?.ui_host(user) || src

/datum/netdm_space/ui_state(mob/user)
	return terminal ? terminal.ui_state(user) : GLOB.never_state

/datum/netdm_space/ui_status(mob/user, datum/ui_state/state)
	return terminal && !QDELETED(terminal) ? terminal.ui_status(user, state) : UI_CLOSE

/datum/netdm_space/ui_interact(mob/user, datum/tgui/ui)
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new(user, src, "NetdmSpace")
		ui.open()

/datum/netdm_space/ui_close(mob/user)
	qdel(src)

/// Sends one network.shell command from the terminal's node. FALSE when it cannot even be queued. An empty DM list
/// encodes as a JSON array, so commands without arguments send the optional "note".
/datum/netdm_space/proc/send(command, list/arguments, datum/callback/on_answer)
	var/datum/node = terminal?.node_ref?.resolve()
	var/datum/netdm_diagnostics/diagnostics = SSnetdm_observe.diagnostics
	if(!node || !diagnostics || !terminal.can_submit())
		return FALSE
	return diagnostics.queue_shell_request(node, node, command, arguments, on_answer, terminal.send_guard())

/// Reads the knowledge changed since the last revision and the presence; re-arms itself.
/datum/netdm_space/proc/refresh()
	deltimer(refresh_timer)
	refresh_timer = addtimer(CALLBACK(src, PROC_REF(refresh)), NETDM_SPACE_REFRESH, TIMER_STOPPABLE)
	if(pending >= NETDM_SPACE_PENDING)
		return
	if(send("knowledge", list("since" = revision), CALLBACK(src, PROC_REF(knowledge_answered))))
		pending++
	if(send("presence", list("note" = "window"), CALLBACK(src, PROC_REF(presence_answered))))
		pending++

/datum/netdm_space/proc/knowledge_answered(list/output)
	pending = max(0, pending - 1)
	var/status = output?["status"]
	if(status == "reset")
		items.Cut()
		revision = 0
		return
	if(status != "complete" && status != "partial")
		return
	for(var/line in splittext("[output["items"]]", ","))
		apply(line)
	revision = max(revision, netdm_number(output["revision"]))
	if(status == "partial" && send("knowledge", list("since" = revision), CALLBACK(src, PROC_REF(knowledge_answered))))
		pending++
	SStgui.update_uis(src)

/// One knowledge line: "n|id|role|x|y|z|age|fresh", "l|a|b|state|age|fresh", "s|instance|type|node|age|fresh" or "r|<key>".
/datum/netdm_space/proc/apply(line)
	var/list/parts = splittext(line, "|")
	if(!length(parts))
		return
	switch(parts[1])
		if("r")
			items -= copytext(line, 3)
		if("n")
			if(length(parts) == 8)
				store("n|[parts[2]]", list("kind" = "n", "id" = parts[2], "role" = parts[3], "x" = text2num(parts[4]),
					"y" = text2num(parts[5]), "z" = text2num(parts[6])), parts[7], parts[8])
		if("l")
			if(length(parts) == 6)
				store("l|[parts[2]]|[parts[3]]", list("kind" = "l", "a" = parts[2], "b" = parts[3], "state" = parts[4]), parts[5], parts[6])
		if("s")
			if(length(parts) == 6)
				store("s|[parts[2]]", list("kind" = "s", "instance" = parts[2], "type" = parts[3], "node" = parts[4]), parts[5], parts[6])

/datum/netdm_space/proc/store(key, list/fields, age, fresh)
	if(!items[key] && length(items) >= NETDM_SPACE_ITEMS)
		return
	fields["confirmed"] = world.time - (text2num(age) || 0) * 10
	fields["stale"] = fresh != "fresh"
	items[key] = fields

/datum/netdm_space/proc/presence_answered(list/output)
	pending = max(0, pending - 1)
	if(islist(output) && output["status"] != "no_answer" && output["status"] != "refused")
		presence = output
	SStgui.update_uis(src)

/datum/netdm_space/proc/is_stale(list/fields)
	return fields["stale"] || world.time - fields["confirmed"] >= NETDM_SPACE_FRESH

/datum/netdm_space/proc/note(text)
	log += "[time2text(world.timeofday, "hh:mm:ss")] [text]"
	if(length(log) > NETDM_SPACE_LOG)
		log.Cut(1, length(log) - NETDM_SPACE_LOG + 1)
	SStgui.update_uis(src)

// ---- Actions: each is one network command; its answer lands in the log --------------------------

/datum/netdm_space/proc/scan(radius = 3)
	return send("scan", list("radius" = clamp(round(radius), 1, 8)), CALLBACK(src, PROC_REF(scanned)))

/datum/netdm_space/proc/scanned(list/output)
	switch(output?["status"])
		if("complete", "partial")
			note("Сканирование: узлов [output["nodes"]], связей [output["links"]], сервисов [output["services"]].")
			refresh()
		if("busy")
			note("Сканер перезаряжается: ещё [output["retryAfter"]] с.")
		else
			note("Сканирование не удалось: [output?["status"] || "нет ответа"].")

/datum/netdm_space/proc/enter()
	return send("enter", list("note" = "window"), CALLBACK(src, PROC_REF(presence_changed), "Вход"))

/datum/netdm_space/proc/leave()
	return send("leave", list("note" = "window"), CALLBACK(src, PROC_REF(presence_changed), "Выход"))

/datum/netdm_space/proc/move(target)
	if(!istext(target) || !length(target) || length(target) > 64)
		return FALSE
	return send("move", list("to" = target), CALLBACK(src, PROC_REF(presence_changed), "Переход"))

/datum/netdm_space/proc/presence_changed(what, list/output)
	var/status = output?["status"]
	if(islist(output) && output["presence"])
		presence = output
	note("[what]: [status || "нет ответа"][output?["reason"] ? " ([output["reason"]])" : ""][output?["to"] ? " → [output["to"]], [output["arriveIn"]] с" : ""].")

/datum/netdm_space/proc/act_line(line)
	if(!istext(line) || !length(trim(line)) || length_char(line) > 1024)
		return FALSE
	return send("act", list("line" = trim(line)), CALLBACK(src, PROC_REF(acted), trim(line)))

/datum/netdm_space/proc/acted(line, list/output)
	var/status = output?["status"]
	if(status == "ok")
		var/list/rows = list()
		for(var/list/record in output["records"])
			var/list/pairs = list()
			for(var/list/pair in record)
				pairs += "[pair["name"]]=[pair["value"]]"
			rows += jointext(pairs, " ")
		note("> [line]: [length(rows) ? jointext(rows, "; ") : "пусто"]")
	else
		note("> [line]: [status || "нет ответа"] [output?["error"]]")

// ---- Window ------------------------------------------------------------------------------------

/// The node a presence stands on, found through the shell service it stands at, if the operator knows it.
/datum/netdm_space/proc/host_node()
	var/list/service = items["s|[presence?["host"]]"]
	return service?["node"]

/datum/netdm_space/ui_data(mob/user)
	var/list/levels = list()
	for(var/key in items)
		var/list/fields = items[key]
		if(fields["kind"] == "n")
			levels |= fields["z"]
	var/host = host_node()
	var/list/host_fields = host ? items["n|[host]"] : null
	if(isnull(z) || !(z in levels))
		z = host_fields ? host_fields["z"] : (length(levels) ? levels[1] : 1)
	var/list/nodes = list()
	var/list/on_level = list()
	for(var/key in items)
		var/list/fields = items[key]
		if(fields["kind"] != "n" || fields["z"] != z)
			continue
		on_level[fields["id"]] = TRUE
		var/flags = fields["role"] == "relay" ? NETDM_SPACE_FLAG_APC : NETDM_SPACE_FLAG_DEVICE
		if(is_stale(fields))
			flags |= NETDM_SPACE_FLAG_UNPOWERED
		nodes += list(list(fields["id"], fields["x"], fields["y"], flags))
	var/list/edges = list()
	var/list/down = list()
	var/list/services = list()
	for(var/key in items)
		var/list/fields = items[key]
		switch(fields["kind"])
			if("l")
				if(on_level[fields["a"]] && on_level[fields["b"]])
					if(fields["state"] == "up" && !is_stale(fields))
						edges += list(list(fields["a"], fields["b"]))
					else
						down += list(list(fields["a"], fields["b"]))
			if("s")
				services += list(list("instance" = fields["instance"], "type" = fields["type"], "node" = fields["node"],
					"stale" = is_stale(fields)))
	return list("title" = terminal ? terminal.device_title(terminal.device_ref?.resolve()) : "нет связи", "z" = z, "levels" = levels,
		"nodes" = nodes, "edges" = edges, "down" = down, "services" = services, "presence" = presence, "hostNode" = host,
		"log" = log, "revision" = revision)

/datum/netdm_space/ui_act(action, list/params, datum/tgui/ui, datum/ui_state/state)
	. = ..()
	if(.)
		return
	switch(action)
		if("scan")
			return scan(text2num("[params["radius"]]") || 3)
		if("enter")
			return enter()
		if("leave")
			return leave()
		if("move")
			return move(params["to"])
		if("act")
			return act_line("[params["line"]]")
		if("level")
			var/level = text2num("[params["z"]]")
			if(isnum(level))
				z = level
			return TRUE

/// A detach sent by a closing window: its answer has nobody to show it to.
/datum/netdm_diagnostics/proc/space_ignored(list/output)
	return

/datum/netdm_terminal
	/// The network window opened from this terminal, if any.
	var/datum/netdm_space/space

/datum/netdm_terminal/Destroy()
	QDEL_NULL(space)
	return ..()

/// Opens the network window of this terminal's operator.
/datum/netdm_terminal/proc/open_space(mob/user)
	if(!can_submit())
		return FALSE
	if(!space)
		new /datum/netdm_space(src)
	space.ui_interact(user)
	return TRUE

#undef NETDM_SPACE_REFRESH
#undef NETDM_SPACE_FRESH
#undef NETDM_SPACE_ITEMS
#undef NETDM_SPACE_LOG
#undef NETDM_SPACE_PENDING
#undef NETDM_SPACE_FLAG_DEVICE
#undef NETDM_SPACE_FLAG_APC
#undef NETDM_SPACE_FLAG_UNPOWERED
