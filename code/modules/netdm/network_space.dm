/// How often an open network window reads the changes of its operator's knowledge and presence.
#define NETDM_SPACE_REFRESH (2 SECONDS)
/// The last occupancy reply stays visible through short gaps between polls.
#define NETDM_SPACE_OTHERS_LIFETIME (6 SECONDS)
#define NETDM_SPACE_CHAT_LIFETIME (6 SECONDS)
#define NETDM_SPACE_CHAT_LENGTH 160
/// An item unconfirmed for this long is drawn as stale (decision Р3 of the P12 design).
#define NETDM_SPACE_FRESH (60 SECONDS)
/// Items a window keeps whatever the Host sends; the Host keeps at most 512 nodes, 1024 links, 512 services.
#define NETDM_SPACE_ITEMS 2048
/// Lines of the window's action log.
#define NETDM_SPACE_LOG 12
/// Requests of one window in flight at once.
#define NETDM_SPACE_PENDING 4
/// A read can wait for the outer shell command and the inner typed result.
#define NETDM_SPACE_ALARM_WAIT (12 SECONDS)
/// One read-only poll per watch window every fifteen seconds.
#define NETDM_SPACE_ALARM_INTERVAL (15 SECONDS)
#define NETDM_SPACE_ACTION_WAIT (22 SECONDS)
#define NETDM_SPACE_ACTION_LIMIT 64

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
	var/opening = FALSE
	/// Item key -> fields. Keys: "n|id", "l|a|b", "s|instance".
	var/list/items = list()
	var/revision = 0
	/// The last answer about the presence.
	var/list/presence
	var/presence_poll_pending = FALSE
	var/list/other_presences = list()
	var/other_presences_at = 0
	var/other_presences_stream
	var/list/route_preview
	var/route_request = 0
	var/list/log = list()
	var/z
	var/pending = 0
	var/refresh_timer
	var/list/alarm_request
	var/list/alarm_watch
	var/next_alarm_watch = 0
	var/list/machine_command
	var/chat_epoch = 0
	var/pending_departures = 0
	var/next_chat_poll = 0
	var/chat_read_pending = FALSE
	var/chat_send_pending = FALSE
	var/chat_node
	/// Host-issued permission for this stay on the node. Only sent back to the Host.
	var/chat_scope
	var/chat_stream
	var/chat_received_at = 0
	var/chat_received = 0
	var/list/chat_messages = list()
	var/chat_status

/datum/netdm_space/New(datum/netdm_terminal/opener)
	terminal = opener
	terminal.space = src
	refresh()

/datum/netdm_space/Destroy()
	deltimer(refresh_timer)
	forget_machine_ticket()
	// Р6: a closed window leaves the presence suspended where it stands.
	var/datum/netdm_apc_operator/operator = terminal?.node_ref?.resolve()
	if(istype(operator))
		// The terminal can be closing too. Queue from the durable actor while its own endpoint still exists.
		operator.detach_needed = TRUE
	else if(presence && presence["state"] != "ended" && presence["status"] != "none")
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
	if(opening)
		return TRUE
	ui = SStgui.try_update_ui(user, src, ui)
	if(ui)
		return TRUE
	opening = TRUE
	ui = new(user, src, "NetdmSpace")
	. = ui.open()
	if(!QDELETED(src))
		opening = FALSE

/datum/netdm_space/ui_close(mob/user)
	qdel(src)

/// Sends one network.shell command from the terminal's node. FALSE when it cannot even be queued. An empty DM list
/// encodes as a JSON array, so commands without arguments send the optional "note".
/datum/netdm_space/proc/send(command, list/arguments, datum/callback/on_answer, datum/callback/can_send)
	var/datum/node = terminal?.node_ref?.resolve()
	var/datum/netdm_diagnostics/diagnostics = SSnetdm_observe.diagnostics
	if(!node || !diagnostics || !terminal.can_submit())
		return FALSE
	return diagnostics.queue_shell_request(node, terminal.shell_provider(), command, arguments, on_answer, can_send || terminal.send_guard())

/// Reads the knowledge changed since the last revision and the presence; re-arms itself.
/datum/netdm_space/proc/refresh()
	deltimer(refresh_timer)
	refresh_timer = addtimer(CALLBACK(src, PROC_REF(refresh)), NETDM_SPACE_REFRESH, TIMER_STOPPABLE)
	if(length(other_presences) && !has_current_other_presences())
		other_presences.Cut()
		SStgui.update_uis(src)
	if(chat_scope && !has_current_chat())
		clear_chat()
		SStgui.update_uis(src)
	check_alarm()
	poll_alarm_watch()
	check_machine_command()
	if(pending >= NETDM_SPACE_PENDING)
		return
	if(send("knowledge", list("since" = revision), CALLBACK(src, PROC_REF(knowledge_answered))))
		pending++
	if(pending < NETDM_SPACE_PENDING && !presence_poll_pending && send("presence", list("others" = TRUE), CALLBACK(src, PROC_REF(presence_answered))))
		presence_poll_pending = TRUE
		pending++
	poll_chat()

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
	presence_poll_pending = FALSE
	if(islist(output) && output["status"] != "no_answer" && output["status"] != "refused")
		var/others = output["others"]
		output -= "others"
		set_presence(output)
		read_other_presences(others)
	SStgui.update_uis(src)

/// A snapshot of "node|count" pairs; IDs stay text to preserve their full wire precision.
/datum/netdm_space/proc/read_other_presences(snapshot)
	other_presences.Cut()
	other_presences_at = world.time
	other_presences_stream = SSnetdm_observe.bridge?.stream_id
	if(!istext(snapshot) || !length(snapshot))
		return
	for(var/pair in splittext(snapshot, ","))
		var/list/parts = splittext(pair, "|")
		if(length(parts) != 2 || !length(parts[1]))
			continue
		var/count = text2num(parts[2])
		if(count > 0)
			other_presences[parts[1]] = count

/datum/netdm_space/proc/has_current_other_presences()
	return other_presences_stream && other_presences_stream == SSnetdm_observe.bridge?.stream_id && world.time - other_presences_at < NETDM_SPACE_OTHERS_LIFETIME

/datum/netdm_space/proc/set_presence(list/output)
	if(output["route"])
		output["route"] = route_nodes(output["route"])
		output["radioLegs"] = route_radio_legs(output["radioLegs"])
	if(presence?["state"] != output["state"] || presence?["host"] != output["host"])
		other_presences.Cut()
		clear_chat()
	else if(presence?["presence"] != output["presence"] || presence?["generation"] != output["generation"])
		clear_chat()
	presence = output
	if(presence["state"] != "active" && route_preview)
		clear_route_preview()

/datum/netdm_space/proc/route_nodes(path)
	var/list/nodes = length(path) ? splittext(path, "|") : list()
	for(var/index in 1 to length(nodes))
		if(nodes[index] == "?")
			nodes[index] = null
	return nodes

/datum/netdm_space/proc/route_radio_legs(path)
	var/list/legs = list()
	if(length(path))
		for(var/index in splittext(path, "|"))
			legs += text2num(index)
	return legs

/datum/netdm_space/proc/is_stale(list/fields)
	return fields["stale"] || world.time - fields["confirmed"] >= NETDM_SPACE_FRESH

/datum/netdm_space/proc/note(text)
	log += "[time2text(world.timeofday, "hh:mm:ss")] [text]"
	if(length(log) > NETDM_SPACE_LOG)
		log.Cut(1, length(log) - NETDM_SPACE_LOG + 1)
	SStgui.update_uis(src)

// ---- Node chat ----------------------------------------------------------------------------------

/datum/netdm_space/proc/has_current_chat()
	return chat_scope && chat_stream == SSnetdm_observe.bridge?.stream_id && presence?["state"] == "active" && world.time - chat_received_at < NETDM_SPACE_CHAT_LIFETIME

/datum/netdm_space/proc/clear_chat()
	chat_epoch++
	chat_node = null
	chat_scope = null
	chat_stream = null
	chat_received = 0
	chat_messages = list()
	chat_status = null

/datum/netdm_space/proc/poll_chat()
	if(presence?["state"] != "active" || pending_departures || chat_read_pending || pending >= NETDM_SPACE_PENDING || world.time < next_chat_poll)
		return
	var/stream = SSnetdm_observe.bridge?.stream_id
	if(!stream)
		return
	var/list/arguments = list("presence" = presence["presence"], "generation" = presence["generation"])
	if(send("chat_read", arguments, CALLBACK(src, PROC_REF(chat_read_answered), chat_epoch, stream)))
		chat_read_pending = TRUE
		pending++
		next_chat_poll = world.time + NETDM_SPACE_REFRESH

/datum/netdm_space/proc/chat_read_answered(epoch, stream, list/output)
	pending = max(0, pending - 1)
	chat_read_pending = FALSE
	if(chat_epoch != epoch || stream != SSnetdm_observe.bridge?.stream_id || presence?["state"] != "active")
		return
	if(output?["status"] != "ok" || !istext(output["node"]) || !length(output["node"]) || !istext(output["scope"]) || !length(output["scope"]))
		clear_chat()
		SStgui.update_uis(src)
		return
	if(chat_scope && (chat_scope != output["scope"] || chat_node != output["node"]))
		clear_chat()
	chat_node = output["node"]
	chat_scope = output["scope"]
	chat_stream = stream
	chat_received_at = world.time
	chat_received = netdm_number(output["received"])
	var/list/snapshot
	if(istext(output["messages"]))
		try
			snapshot = json_decode(output["messages"])
		catch
			snapshot = null
	var/list/messages = list()
	if(islist(snapshot))
		for(var/list/entry in snapshot)
			if(istext(entry["id"]) && istext(entry["text"]) && istext(entry["sender"]))
				messages += list(list("id" = entry["id"], "text" = entry["text"], "sender" = entry["sender"], "own" = !!entry["own"]))
	chat_messages = messages
	SStgui.update_uis(src)

/datum/netdm_space/proc/send_chat(mob/living/user, node, text)
	if(!isliving(user) || !user.client || !has_current_chat() || node != chat_node || chat_send_pending)
		return FALSE
	if(!istext(text) || length_char(text) > NETDM_SPACE_CHAT_LENGTH)
		chat_status = "invalid_text"
		return TRUE
	text = trim(text)
	if(!length(text))
		chat_status = "invalid_text"
		return TRUE
	if(pending >= NETDM_SPACE_PENDING)
		chat_status = "busy"
		return TRUE
	if(!user.can_speak_basic(text))
		chat_status = "refused"
		return TRUE
	var/datum/callback/guard = CALLBACK(src, PROC_REF(can_send_chat), chat_epoch)
	if(!send("chat_send", list("scope" = chat_scope, "text" = text), CALLBACK(src, PROC_REF(chat_send_answered), chat_epoch, chat_stream), guard))
		chat_status = "busy"
		return TRUE
	chat_send_pending = TRUE
	chat_status = "sending"
	pending++
	return TRUE

/datum/netdm_space/proc/can_send_chat(epoch)
	return !QDELETED(src) && chat_epoch == epoch && has_current_chat() && terminal?.can_submit()

/datum/netdm_space/proc/chat_send_answered(epoch, stream, list/output)
	pending = max(0, pending - 1)
	chat_send_pending = FALSE
	if(chat_epoch != epoch || stream != SSnetdm_observe.bridge?.stream_id || !has_current_chat())
		return
	chat_status = output?["status"] || "no_answer"
	if(chat_status == "sent" && output["node"] == chat_node)
		next_chat_poll = world.time
		poll_chat()
	else if(chat_status in list("stale_chat", "no_presence", "suspended", "moving", "out_of_reach"))
		clear_chat()
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
	return send_departure("leave", list("note" = "window"), "Выход")

/datum/netdm_space/proc/preview_move(target)
	if(!istext(target) || !length(target) || length(target) > 64 || presence?["state"] != "active" || route_preview?["status"] == "pending")
		return FALSE
	var/list/service = items["s|[target]"]
	if(service?["type"] != "network.shell" || is_stale(service))
		return FALSE
	var/request = ++route_request
	if(!send("preview_move", list("to" = target), CALLBACK(src, PROC_REF(route_answered), target, request)))
		return FALSE
	route_preview = list("target" = target, "status" = "pending", "nodes" = list(), "radioLegs" = list())
	return TRUE

/datum/netdm_space/proc/clear_route_preview()
	route_request++
	route_preview = null
	return TRUE

/datum/netdm_space/proc/route_answered(target, request, list/output)
	if(request != route_request || target != route_preview?["target"])
		return
	route_preview = list("target" = target, "status" = output?["status"] || "no_answer", "nodes" = route_nodes(output?["path"]),
		"radioLegs" = route_radio_legs(output?["radioLegs"]), "seconds" = output?["seconds"], "hops" = output?["hops"],
		"radioHops" = output?["radioHops"], "limited" = !!output?["limited"])
	SStgui.update_uis(src)

/datum/netdm_space/proc/move(target)
	if(!istext(target) || !length(target) || length(target) > 64)
		return FALSE
	if(!send_departure("move", list("to" = target), "Переход"))
		return FALSE
	return clear_route_preview()

/// A queued departure cannot leave an older chat response visible while the Host processes it.
/datum/netdm_space/proc/send_departure(command, list/arguments, what)
	if(!send(command, arguments, CALLBACK(src, PROC_REF(departure_answered), what)))
		return FALSE
	pending_departures++
	clear_chat()
	return TRUE

/datum/netdm_space/proc/departure_answered(what, list/output)
	pending_departures--
	presence_changed(what, output)

/datum/netdm_space/proc/presence_changed(what, list/output)
	var/status = output?["status"]
	if(islist(output) && output["presence"])
		set_presence(output)
		poll_chat()
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

/datum/netdm_space/proc/first_record(list/output)
	var/list/rows = output?["records"]
	var/list/row = length(rows) ? rows[1] : null
	var/list/fields = list()
	for(var/list/pair in row)
		fields[pair["name"]] = pair["value"]
	return fields

/datum/netdm_space/proc/machine_pending()
	var/status = machine_command?["status"]
	return status == "sending" || status == "sent"

/datum/netdm_space/proc/can_operate_alarm(mob/living/operator)
	if(!istype(operator) || !operator.client || operator.stat || operator.incapacitated() || !terminal?.can_submit() || ui_status(operator, ui_state(operator)) != UI_INTERACTIVE)
		return FALSE
	var/obj/machinery/power/apc/apc = terminal.device_ref?.resolve()
	return !istype(apc) || SSnetdm_observe.diagnostics?.terminal_access(apc, operator)

/datum/netdm_space/proc/alarm_for_service(instance)
	if(!istext(instance) || copytext(instance, 1, 13) != "atmos.alarm.")
		return null
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	var/datum/netdm_service_endpoint/endpoint = lane?.endpoints[copytext(instance, 13)]
	if(!endpoint?.services[instance])
		return null
	var/obj/machinery/airalarm/alarm = lane.registry.resolve(endpoint.id, endpoint.generation)
	return istype(alarm) ? alarm : null

/datum/netdm_space/proc/operate_alarm(instance, enabled, mob/living/operator)
	if(!istext(instance) || length(instance) > 64 || !isnum(enabled) || !(enabled in list(0, 1)) || machine_pending() || presence?["state"] != "active")
		return FALSE
	var/list/service = items["s|[instance]"]
	if(service?["type"] != "atmos.alarm" || is_stale(service))
		return FALSE
	var/obj/machinery/airalarm/alarm = alarm_for_service(instance)
	if(!can_operate_alarm(operator) || !alarm?.netdm_can_set_alert(operator))
		machine_command = list("instance" = instance, "enabled" = enabled, "status" = "rejected", "reason" = alarm ? "access_denied" : "alarm_offline")
		return TRUE
	var/datum/node = terminal.node_ref?.resolve()
	var/datum/netdm_service_endpoint/endpoint = node ? SSnetdm_observe.services?.by_node[node] : null
	var/datum/netdm_diagnostics/diagnostics = SSnetdm_observe.diagnostics
	if(!endpoint?.attached_node || !diagnostics || length(diagnostics.alarm_actions) >= NETDM_SPACE_ACTION_LIMIT)
		machine_command = list("instance" = instance, "enabled" = enabled, "status" = "not_delivered", "reason" = endpoint?.attached_node ? "busy" : "offline")
		return TRUE
	var/ticket = rustg_generate_uuid_v4()
	var/list/request = list("ticket" = ticket, "window" = WEAKREF(src), "operator" = WEAKREF(operator), "target" = WEAKREF(alarm),
		"instance" = instance, "enabled" = enabled, "status" = "sending", "entry" = endpoint.id, "generation" = "[endpoint.generation]",
		"stream" = SSnetdm_observe.bridge?.stream_id, "deadline" = world.time + NETDM_SPACE_ACTION_WAIT, "next_query" = world.time + 3 SECONDS)
	if(!send("alarm_action", list("instance" = instance, "ticket" = ticket, "enabled" = enabled), CALLBACK(src, PROC_REF(machine_accepted), request)))
		machine_command = list("instance" = instance, "enabled" = enabled, "status" = "not_delivered", "reason" = "busy")
		return TRUE
	machine_command = request
	diagnostics.alarm_actions[ticket] = request
	return TRUE

/datum/netdm_diagnostics/proc/consume_alarm_action(list/item, obj/machinery/airalarm/alarm, list/payload)
	var/ticket = payload?["ticket"]
	var/list/request = istext(ticket) ? alarm_actions[ticket] : null
	if(!request || request["used"] || world.time >= request["deadline"] || request["stream"] != SSnetdm_observe.bridge?.stream_id ||
		request["instance"] != item["instance"] || request["entry"] != item["producer"] || request["generation"] != "[item["producerGeneration"]]" || request["enabled"] != !!payload["enabled"])
		return null
	var/datum/weakref/target_ref = request["target"]
	var/datum/weakref/window_ref = request["window"]
	var/datum/weakref/operator_ref = request["operator"]
	var/datum/netdm_space/window = window_ref?.resolve()
	var/mob/living/operator = operator_ref?.resolve()
	if(target_ref?.resolve() != alarm || window?.machine_command != request || !window.can_operate_alarm(operator))
		return null
	request["used"] = TRUE
	request["operation"] = "[item["operationId"]]"
	return operator

/datum/netdm_diagnostics/proc/alarm_action_received(list/item)
	var/list/payload = item["payload"]
	var/ticket = payload?["ticket"]
	var/list/request = istext(ticket) ? alarm_actions[ticket] : null
	if(!request?["used"] || request["operation"] != "[item["operationId"]]" || request["instance"] != item["instance"] ||
		request["entry"] != item["recipient"] || request["generation"] != "[item["recipientGeneration"]]" || request["stream"] != SSnetdm_observe.bridge?.stream_id)
		return
	var/datum/weakref/window_ref = request["window"]
	var/datum/netdm_space/window = window_ref?.resolve()
	if(window?.machine_command == request)
		request["zoneAlarm"] = payload["zoneAlarm"]
		request["sourceActive"] = payload["sourceActive"]
		request["changed"] = payload["changed"]
		window.finish_machine_command("applied")

/datum/netdm_space/proc/machine_accepted(list/request, list/output)
	if(machine_command != request)
		return
	var/list/fields = first_record(output)
	if(fields["instance"] == request["instance"] && fields["status"] == "sent" && length(fields["operation"]))
		request["source"] = fields["origin"]
		if(machine_pending())
			request["operation"] = fields["operation"]
			request["status"] = "sent"
		SStgui.update_uis(src)
	else if(machine_pending())
		var/reason = fields["status"] || output?["status"]
		if(reason && reason != "no_answer")
			finish_machine_command("not_delivered", reason)

/datum/netdm_space/proc/check_machine_command()
	if(!machine_pending())
		return
	var/list/request = machine_command
	if(request["stream"] != SSnetdm_observe.bridge?.stream_id || world.time >= request["deadline"])
		finish_machine_command(request["applied_by_host"] ? "no_receipt" : "unknown", "no_answer")
		return
	if(!request["operation"] || world.time < request["next_query"])
		return
	request["next_query"] = world.time + 3 SECONDS
	var/datum/node = terminal?.node_ref?.resolve()
	SSnetdm_observe.services?.query_command(node, request["operation"], CALLBACK(src, PROC_REF(machine_status_answered), request))

/datum/netdm_space/proc/machine_status_answered(list/request, list/reply)
	if(machine_command != request || !machine_pending() || request["stream"] != SSnetdm_observe.bridge?.stream_id)
		return
	var/list/status = reply?["result"]?["value"]
	var/reason = status?["outcomeReason"]
	switch(status?["outcome"])
		if("not_applied")
			finish_machine_command("not_delivered", reason)
		if("rejected_by_world")
			finish_machine_command("rejected", reason)
		if("unknown")
			finish_machine_command("unknown", reason)
		if("applied")
			request["applied_by_host"] = TRUE
			if(status["result"] == "failed" || status["result"] == "delivered")
				finish_machine_command("no_receipt", status["resultReason"])

/datum/netdm_space/proc/forget_machine_ticket()
	if(machine_command?["ticket"])
		var/datum/netdm_diagnostics/diagnostics = SSnetdm_observe?.diagnostics
		if(diagnostics)
			diagnostics.alarm_actions -= machine_command["ticket"]

/datum/netdm_space/proc/finish_machine_command(status, reason)
	forget_machine_ticket()
	machine_command["status"] = status
	machine_command["reason"] = reason
	SStgui.update_uis(src)

/datum/netdm_space/proc/read_alarm(instance)
	if(!istext(instance) || length(instance) > 64 || alarm_request || presence?["state"] != "active")
		return FALSE
	var/list/service = items["s|[instance]"]
	if(service?["type"] != "atmos.alarm" || is_stale(service))
		return FALSE
	var/datum/node = terminal?.node_ref?.resolve()
	var/datum/netdm_service_endpoint/endpoint = node ? SSnetdm_observe.services?.by_node[node] : null
	if(!endpoint)
		return FALSE
	var/list/request = list("instance" = instance, "recipient" = endpoint.id, "generation" = "[endpoint.generation]",
		"deadline" = world.time + NETDM_SPACE_ALARM_WAIT, "stream" = SSnetdm_observe.bridge?.stream_id)
	if(!send("act", list("line" = "invoke [instance] read reason=inspect"), CALLBACK(src, PROC_REF(alarm_accepted), request)))
		return FALSE
	alarm_request = request
	return TRUE

/datum/netdm_space/proc/watch_alarm(instance, mob/user)
	if(!istext(instance) || length(instance) > 64 || presence?["state"] != "active" || !terminal?.can_submit())
		return FALSE
	var/list/service = items["s|[instance]"]
	if(service?["type"] != "atmos.alarm" || is_stale(service))
		return FALSE
	if(alarm_watch?["instance"] == instance)
		return TRUE
	stop_alarm_watch()
	var/node_id = service["node"]
	var/list/node = items["n|[node_id]"]
	alarm_watch = list("instance" = instance, "node" = node_id, "z" = node?["z"], "state" = "waiting", "operator" = WEAKREF(user))
	note("Наблюдение за атмосферой на узле [node_id] включено.")
	poll_alarm_watch()
	return TRUE

/datum/netdm_space/proc/stop_alarm_watch()
	if(!alarm_watch)
		return FALSE
	if(alarm_request?["watch"] == alarm_watch)
		alarm_request = null
	alarm_watch = null
	return TRUE

/datum/netdm_space/proc/poll_alarm_watch()
	if(!alarm_watch || alarm_request || world.time < next_alarm_watch || presence?["state"] != "active" || !terminal?.can_submit())
		return
	var/datum/node = terminal.node_ref?.resolve()
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	var/datum/netdm_service_endpoint/endpoint = node ? lane?.by_node[node] : null
	if(!endpoint?.attached_node)
		next_alarm_watch = world.time + NETDM_SPACE_ALARM_INTERVAL
		update_alarm_watch(null)
		return
	var/instance = alarm_watch["instance"]
	var/list/request = list("instance" = instance, "recipient" = endpoint.id, "generation" = "[endpoint.generation]",
		"deadline" = world.time + NETDM_SPACE_ALARM_WAIT, "stream" = SSnetdm_observe.bridge?.stream_id, "watch" = alarm_watch)
	if(!send("poll_alarm", list("instance" = instance), CALLBACK(src, PROC_REF(alarm_accepted), request)))
		return
	next_alarm_watch = world.time + NETDM_SPACE_ALARM_INTERVAL
	alarm_request = request

/datum/netdm_space/proc/update_alarm_watch(list/sample)
	var/list/watch = alarm_watch
	if(!watch)
		return
	var/previous = watch["state"]
	var/current = "offline"
	if(sample)
		current = sample["alarm"] ? "alarm" : (sample["danger"] >= 2 ? "danger" : (sample["danger"] == 1 ? "warning" : "clear"))
		watch["sample"] = sample
		watch["at"] = world.time
	watch["state"] = current
	if(previous == current)
		SStgui.update_uis(src)
		return
	var/node = watch["node"]
	var/message
	switch(current)
		if("offline")
			message = "Нет ответа от атмосферной панели на узле [node]."
		if("alarm", "danger")
			message = "Опасная атмосфера на узле [node]. Проверьте зону."
		if("warning")
			message = "Атмосферная панель узла [node] сообщила об отклонении."
		if("clear")
			message = previous == "waiting" ? "Панель узла [node] на связи. Показания в норме." : "Атмосфера на узле [node] в норме."
	if(previous == "offline" && sample)
		message = "Связь восстановлена. [message]"
	note(message)
	if(watch == alarm_watch && (current == "alarm" || current == "danger" || current == "offline" || previous == "offline"))
		var/datum/weakref/operator_ref = watch["operator"]
		var/mob/operator = operator_ref?.resolve()
		if(operator && ui_status(operator, ui_state(operator)) >= UI_UPDATE)
			to_chat(operator, current == "clear" ? span_notice(message) : span_warning(message))

/datum/netdm_space/proc/alarm_accepted(list/request, list/output)
	if(alarm_request != request)
		return
	var/list/fields = first_record(output)
	if(fields["status"] == "sent" && fields["instance"] == alarm_request["instance"] && length(fields["operation"]))
		alarm_request["operation"] = fields["operation"]
		check_alarm()
		return
	alarm_request = null
	if(request["watch"])
		if(!(output?["status"] in list("moving", "suspended", "no_presence")))
			update_alarm_watch(null)
		return
	note("Датчик атмосферы не принял запрос ([fields["status"] || output?["status"] || "нет ответа"]).")

/datum/netdm_space/proc/check_alarm()
	if(!alarm_request)
		return
	var/list/watch = alarm_request["watch"]
	if(!terminal?.can_submit() || (watch && presence?["state"] != "active"))
		alarm_request = null
		return
	if(alarm_request["stream"] != SSnetdm_observe.bridge?.stream_id)
		alarm_request = null
		if(watch)
			update_alarm_watch(null)
		return
	var/operation = alarm_request["operation"]
	var/list/sample = operation ? SSnetdm_observe.telemetry?.take_alarm_result(operation, alarm_request["instance"],
		alarm_request["recipient"], alarm_request["generation"]) : null
	if(sample)
		var/instance = alarm_request["instance"]
		alarm_request = null
		if(watch)
			update_alarm_watch(sample)
			return
		var/danger = sample["danger"]
		var/state = danger >= 2 ? "опасно" : (danger == 1 ? "предупреждение" : "норма")
		note("[instance] · [sample["pressureKPa"]] кПа · [sample["temperatureK"]] K · [state][sample["alarm"] ? " · тревога в зоне" : ""].")
	else if(world.time >= alarm_request["deadline"])
		alarm_request = null
		if(watch)
			update_alarm_watch(null)
		else
			note("Датчик атмосферы не ответил.")

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
	var/list/occupants_on_level = list()
	var/show_other_presences = has_current_other_presences()
	for(var/key in items)
		var/list/fields = items[key]
		if(fields["kind"] != "n" || fields["z"] != z)
			continue
		on_level[fields["id"]] = TRUE
		if(show_other_presences && other_presences[fields["id"]])
			occupants_on_level[fields["id"]] = other_presences[fields["id"]]
		var/flags = fields["role"] == "relay" ? NETDM_SPACE_FLAG_APC : NETDM_SPACE_FLAG_DEVICE
		if(is_stale(fields))
			flags |= NETDM_SPACE_FLAG_UNPOWERED
		nodes += list(list(fields["id"], fields["x"], fields["y"], flags))
	var/list/edges = list()
	var/list/down = list()
	var/list/services = list()
	var/may_control_alarm = presence?["state"] == "active" && can_operate_alarm(user)
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
				var/obj/machinery/airalarm/alarm
				if(may_control_alarm && on_level[fields["node"]] && fields["type"] == "atmos.alarm" && !is_stale(fields))
					alarm = alarm_for_service(fields["instance"])
				services += list(list("instance" = fields["instance"], "type" = fields["type"], "node" = fields["node"],
					"stale" = is_stale(fields), "canControlAlarm" = !!alarm?.netdm_can_set_alert(user)))
	var/list/watch_data
	if(alarm_watch)
		watch_data = list("instance" = alarm_watch["instance"], "node" = alarm_watch["node"], "z" = alarm_watch["z"],
			"state" = presence?["state"] == "active" && terminal?.can_submit() ? alarm_watch["state"] : "paused",
			"sample" = alarm_watch["sample"], "age" = isnull(alarm_watch["at"]) ? null : floor((world.time - alarm_watch["at"]) / 10))
	var/list/command_data
	if(machine_command)
		command_data = list("instance" = machine_command["instance"], "enabled" = machine_command["enabled"], "status" = machine_command["status"],
			"operation" = machine_command["operation"], "reason" = machine_command["reason"], "source" = machine_command["source"],
			"zoneAlarm" = machine_command["zoneAlarm"], "sourceActive" = machine_command["sourceActive"], "changed" = machine_command["changed"])
	var/list/chat_data
	if(has_current_chat())
		// The UI can identify a visit across missed polls without receiving its write scope.
		chat_data = list("node" = chat_node, "visit" = md5(chat_scope), "received" = chat_received,
			"messages" = chat_messages, "status" = chat_status)
	return list("title" = terminal ? terminal.device_title(terminal.device_ref?.resolve()) : "нет связи", "z" = z, "levels" = levels,
		"nodes" = nodes, "edges" = edges, "down" = down, "services" = services, "presence" = presence, "hostNode" = host,
		"otherPresences" = occupants_on_level,
		"chat" = chat_data,
		"log" = log, "revision" = revision, "alarmPending" = !!alarm_request, "alarmWatch" = watch_data,
		"routePreview" = route_preview, "machineCommand" = command_data)

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
		if("preview_move")
			return preview_move(params["to"])
		if("clear_route_preview")
			return clear_route_preview()
		if("abort_move")
			if(presence?["state"] == "moving")
				return send("abort_move", list("note" = "window"), CALLBACK(src, PROC_REF(presence_changed), "Отмена перехода"))
		if("act")
			return act_line("[params["line"]]")
		if("send_chat")
			return send_chat(ui.user, params["node"], params["text"])
		if("read_alarm")
			return read_alarm(params["instance"])
		if("watch_alarm")
			return watch_alarm(params["instance"], ui.user)
		if("stop_alarm_watch")
			return stop_alarm_watch()
		if("machine_alert")
			return operate_alarm(params["instance"], params["enabled"], ui.user)
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
	var/datum/netdm_space/window = space
	if(!window)
		window = new(src)
	if(window.ui_interact(user))
		return TRUE
	qdel(window)
	return FALSE

#undef NETDM_SPACE_REFRESH
#undef NETDM_SPACE_OTHERS_LIFETIME
#undef NETDM_SPACE_CHAT_LIFETIME
#undef NETDM_SPACE_CHAT_LENGTH
#undef NETDM_SPACE_FRESH
#undef NETDM_SPACE_ITEMS
#undef NETDM_SPACE_LOG
#undef NETDM_SPACE_PENDING
#undef NETDM_SPACE_ALARM_WAIT
#undef NETDM_SPACE_ALARM_INTERVAL
#undef NETDM_SPACE_ACTION_WAIT
#undef NETDM_SPACE_ACTION_LIMIT
#undef NETDM_SPACE_FLAG_DEVICE
#undef NETDM_SPACE_FLAG_APC
#undef NETDM_SPACE_FLAG_UNPOWERED
