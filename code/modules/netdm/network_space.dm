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
/// Bounded replies for the schema-backed context panel.
#define NETDM_SPACE_ACTION_ENTRIES 16
#define NETDM_SPACE_ACTION_RECORDS 64
#define NETDM_SPACE_ACTION_FIELDS 16
/// Requests of one window in flight at once.
#define NETDM_SPACE_PENDING 4
/// A read can wait for the outer shell command and the inner typed result.
#define NETDM_SPACE_ALARM_WAIT (12 SECONDS)
/// One read-only poll per watch window every fifteen seconds.
#define NETDM_SPACE_ALARM_INTERVAL (15 SECONDS)
#define NETDM_SPACE_ACTION_WAIT (22 SECONDS)
#define NETDM_SPACE_ACTION_LIMIT 64
#define NETDM_SPACE_HACK_WINDOW (15 SECONDS)

/// Topology screen flags reused by the window's map (tgui NetdmTopology/model.ts).
#define NETDM_SPACE_FLAG_DEVICE 8
#define NETDM_SPACE_FLAG_APC 16
#define NETDM_SPACE_FLAG_UNPOWERED 32

/mob
	/// The player's currently open network workspace.
	var/datum/weakref/netdm_workspace
	/// The workspace reserved while TGUI sends its opening assets.
	var/datum/weakref/netdm_pending_workspace

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
	/// Source of authority and network transport; no assumption of a physical terminal.
	var/datum/netdm_space_actor/actor
	/// An adapter constructed for a legacy terminal is owned by this window.
	var/owns_actor = FALSE
	var/opening = FALSE
	var/datum/weakref/viewer_ref
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
	/// Per-window Host replies, never persisted across actors.
	var/list/action_entries = list()
	var/list/action_queries = list()
	var/action_serial = 0
	var/z
	var/pending = 0
	var/refresh_timer
	var/list/alarm_request
	var/list/alarm_watch
	var/next_alarm_watch = 0
	var/list/machine_command
	var/chat_epoch = 0
	/// P13: true when the operator speaks on the shared channel instead of the node visit.
	var/chat_channel = FALSE
	/// P13.5: hacking, the stolen key ring and persona masking.
	var/hack_status
	var/hack_code
	var/hack_target
	var/hack_expires = 0
	var/list/hack_keys = list()
	var/hack_masked = FALSE
	var/hack_use_pending = FALSE
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
	/// P13 immersion: the operator's body is left in a trance and the screen shows the network instead.
	var/immersed = FALSE
	var/immersed_reason = ""
	/// P13: when the current dive started, for the in-window dive clock.
	var/immersed_at = 0
	/// P13 network life: the last activity page and the entities standing on known nodes.
	var/list/life = list("bots" = list(), "activity" = list(), "operators" = list())
	/// P13: the newest intrusion event already turned into a physical effect, and the first-poll baseline.
	var/last_intrusion_seq = 0
	var/intrusion_baseline = FALSE
	var/life_since = 0
	var/life_pending = FALSE
	/// The neuro-link's stored identity was sent once for this window.
	var/persona_restored = FALSE
	/// The last intruder named by the presence, so one warning is played per newcomer.
	var/last_threat = ""

/datum/netdm_space/New(datum/source)
	if(istype(source, /datum/netdm_terminal))
		// Existing callers keep new(terminal), but the window only sees the actor interface.
		var/datum/netdm_terminal/opener = source
		actor = new /datum/netdm_space_actor/terminal(opener)
		owns_actor = TRUE
	else if(istype(source, /datum/netdm_space_actor))
		actor = source
	if(!actor?.attach_window(src))
		if(owns_actor)
			QDEL_NULL(actor)
		else
			actor = null
		return
	refresh()

/datum/netdm_space/Destroy()
	deltimer(refresh_timer)
	forget_machine_ticket()
	var/mob/viewer = viewer_ref?.resolve()
	if(viewer && viewer.netdm_workspace == weak_reference)
		viewer.netdm_workspace = null
	if(viewer && viewer.netdm_pending_workspace == weak_reference)
		viewer.netdm_pending_workspace = null
	// Close the authenticated view; independently owned actors may outlive it.
	var/datum/netdm_space_actor/source = actor
	if(source && !QDELETED(source))
		source.on_window_close(src, presence)
		source.release_window(src)
		if(owns_actor)
			qdel(source)
	actor = null
	return ..()

/datum/netdm_space/ui_host(mob/user)
	return actor?.ui_host(user) || src

/datum/netdm_space/ui_state(mob/user)
	return actor ? actor.ui_state(user) : GLOB.never_state

/datum/netdm_space/ui_status(mob/user, datum/ui_state/state)
	return actor && !QDELETED(actor) ? actor.ui_status(user, state) : UI_CLOSE

/datum/netdm_space/ui_interact(mob/user, datum/tgui/ui)
	if(!user?.client)
		return FALSE
	if(opening)
		return user.netdm_pending_workspace == weak_reference
	ui = SStgui.try_update_ui(user, src, ui)
	if(QDELETED(src))
		return FALSE
	if(ui)
		if(user.netdm_workspace == weak_reference)
			user.netdm_pending_workspace = null
		return TRUE
	reserve_opening(user)
	ui = new(user, src, "NetdmSpace")
	var/opened = ui.open()
	if(!QDELETED(src) && finish_opening(user, opened && user.client))
		return TRUE
	if(opened && !QDELETED(ui))
		ui.close()
	return FALSE

/datum/netdm_space/proc/reserve_opening(mob/user)
	opening = TRUE
	viewer_ref = WEAKREF(user)
	user.netdm_pending_workspace = WEAKREF(src)

/datum/netdm_space/proc/finish_opening(mob/user, opened)
	opening = FALSE
	if(user.netdm_pending_workspace != weak_reference)
		return FALSE
	user.netdm_pending_workspace = null
	if(!opened)
		return FALSE
	var/datum/netdm_space/previous = user.netdm_workspace?.resolve()
	user.netdm_workspace = weak_reference
	if(previous && previous != src)
		SStgui.close_uis(previous)
		if(!QDELETED(previous))
			qdel(previous)
	return TRUE

/datum/netdm_space/ui_close(mob/user)
	immersion_closed()
	qdel(src)

/// All network actions go through the owning actor's authenticated Host command path.
/// An empty DM list encodes as an array, so argument-free commands retain their "note".
/datum/netdm_space/proc/send(command, list/arguments, datum/callback/on_answer, datum/callback/can_send)
	if(!actor || QDELETED(actor))
		return FALSE
	return actor.send(command, arguments, on_answer, can_send) || FALSE

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
	check_action_delivery()
	if(pending >= NETDM_SPACE_PENDING)
		return
	if(send("knowledge", list("since" = revision), CALLBACK(src, PROC_REF(knowledge_answered))))
		pending++
	if(pending < NETDM_SPACE_PENDING && !presence_poll_pending && send("presence", list("others" = TRUE), CALLBACK(src, PROC_REF(presence_answered))))
		presence_poll_pending = TRUE
		pending++
	poll_chat()
	// P13: the entities and activity of the network. Read only while the layer is enabled on this round;
	// one request in flight keeps it from piling up behind a slow Host.
	if(netdm_immersion_enabled() && !life_pending && pending < NETDM_SPACE_PENDING && send("life", list("since" = life_since, "limit" = 32), CALLBACK(src, PROC_REF(life_answered))))
		life_pending = TRUE
		pending++

/// The neuro-link keeps the owner's identity in its own memory: a new endpoint (re-implanted implant, new
/// session) gets it back once the presence is known. Only the entry device's stored identity is restored.
/datum/netdm_space/proc/restore_persona()
	if(persona_restored || !islist(presence))
		return
	var/obj/item/implant/netdm_terminal/implant = actor?.neural_implant()
	if(!istype(implant) || !implant.imp_in || !islist(implant.netdm_persona))
		return
	var/list/identity = implant.netdm_persona
	persona_restored = TRUE
	var/same = "[identity["name"]]" == "[presence["personaName"]]"
	same = same && "[identity["signature"]]" == "[presence["personaSignature"]]"
	same = same && "[identity["status"]]" == "[presence["personaStatus"]]"
	same = same && "[identity["role"]]" == "[presence["personaRole"]]"
	same = same && text2num("[identity["colour"]]") == text2num("[presence["personaColour"]]")
	if(same)
		return
	send("persona", list("name" = identity["name"], "signature" = identity["signature"], "statusLine" = identity["status"],
		"role" = identity["role"], "colour" = text2num("[identity["colour"]]")),
		CALLBACK(src, PROC_REF(persona_answered)))

/datum/netdm_space/proc/set_persona(list/params, mob/living/user)
	var/list/arguments = list()
	if(!isnull(params["name"]) && "[params["name"]]" != "")
		arguments["name"] = "[params["name"]]"
	if(!isnull(params["signature"]))
		arguments["signature"] = "[params["signature"]]"
	if(!isnull(params["colour"]))
		arguments["colour"] = text2num("[params["colour"]]")
	if(!isnull(params["status"]))
		arguments["statusLine"] = "[params["status"]]"
	if(!length(arguments))
		return TRUE
	if(user)
		arguments["role"] = netdm_persona_role(user)
	return send("persona", arguments, CALLBACK(src, PROC_REF(persona_answered)))

/datum/netdm_space/proc/persona_answered(list/output)
	if(islist(output) && output["status"] == "ok")
		if(islist(presence))
			presence["personaName"] = output["personaName"]
			presence["personaSignature"] = output["personaSignature"]
			presence["personaColour"] = output["personaColour"]
		presence["personaStatus"] = output["personaStatus"]
		presence["personaRole"] = output["personaRole"]
		var/obj/item/implant/netdm_terminal/implant = actor?.neural_implant()
		if(istype(implant))
			implant.netdm_persona = list("name" = "[output["personaName"]]", "signature" = "[output["personaSignature"]]",
				"colour" = text2num("[output["personaColour"]]"))
		note("Личность сохранена.")
	else
		note("Личность не принята: [islist(output) ? (output["reason"] || "ошибка") : "нет ответа"].")
	SStgui.update_uis(src)

/datum/netdm_space/proc/life_answered(list/output)
	life_pending = FALSE
	pending = max(0, pending - 1)
	if(!islist(output) || output["status"] != "ok")
		return
	var/list/bots = list()
	for(var/line in splittext("[output["bots"]]", ";"))
		var/list/parts = splittext(line, "|")
		if(length(parts) < 8)
			continue
		bots += list(list("bot" = text2num(parts[1]), "name" = parts[2], "signature" = parts[3], "colour" = text2num(parts[4]),
			"goal" = parts[5], "node" = parts[6], "state" = parts[7], "moves" = text2num(parts[8])))
	var/list/activity = islist(life["activity"]) ? life["activity"] : list()
	for(var/line in splittext("[output["activity"]]", ";"))
		var/list/parts = splittext(line, "|")
		if(length(parts) < 5)
			continue
		activity += list(list("seq" = text2num(parts[1]), "kind" = parts[2], "node" = parts[3], "name" = parts[4],
			"text" = jointext(parts.Copy(5), "|")))
	if(length(activity) > 64)
		activity.Cut(1, length(activity) - 64)
	var/list/operators = list()
	for(var/line in splittext("[output["presences"]]", ";"))
		var/list/parts = splittext(line, "|")
		if(length(parts) < 8)
			continue
		operators += list(list("node" = parts[1], "name" = parts[2], "signature" = parts[3], "colour" = text2num(parts[4]),
			"status" = parts[5], "role" = parts[6], "state" = parts[7], "threat" = parts[8]))
	life = list("bots" = bots, "activity" = activity, "operators" = operators)
	// P13: a cheap projection the physical APC panel can read without the window.
	var/list/life_nodes = list()
	for(var/list/bot in bots)
		life_nodes["[bot["node"]]"] = (life_nodes["[bot["node"]]"] || 0) + 1
	SSnetdm_observe.netdm_life_nodes = life_nodes
	// P13: the population leaves physical traces on the station: beeps near busy APCs, and an
	// intruder trips the breaker of the APC it invaded (engineers restore it by hand).
	for(var/list/bot in bots)
		var/obj/machinery/power/apc/bot_apc = SSnetdm_observe.apc_by_node_id(bot["node"])
		if(!bot_apc)
			continue
		SSnetdm_observe.netdm_ambient_ping(bot_apc)
		// P13: the population works the grid: saboteurs trip the breaker, engineers restore it.
		switch("[bot["goal"]]")
			if("saboteur")
				if(bot_apc.operating)
					SSnetdm_observe.netdm_sabotage(bot_apc, bot["node"])
			if("engineer")
				if(!bot_apc.operating)
					SSnetdm_observe.netdm_repair(bot_apc, bot["node"])
	if(!intrusion_baseline)
		intrusion_baseline = TRUE
		for(var/list/event in activity)
			last_intrusion_seq = max(last_intrusion_seq, event["seq"])
	else
		for(var/list/event in activity)
			if(event["kind"] != "intrusion" || event["seq"] <= last_intrusion_seq)
				continue
			last_intrusion_seq = event["seq"]
			var/obj/machinery/power/apc/hit = SSnetdm_observe.apc_by_node_id(event["node"])
			if(hit)
				SSnetdm_observe.netdm_sabotage(hit, event["node"])
	// The dive hears the network: a newcomer on the operator's node is a sound and a warning, once.
	var/current_threat = islist(presence) ? "[presence["threat"]]" : ""
	if(immersed && current_threat != "" && current_threat != last_threat)
		var/mob/living/diver = actor?.physical_body()
		if(diver)
			SEND_SOUND(diver, sound('sound/machines/warning-buzzer.ogg'))
			to_chat(diver, span_warning("Вторжение в сеть: [current_threat] на вашем узле."))
			SSnetdm_observe?.netdm_incident("intrusion", presence?["node"], "Вторжение в сеть: [current_threat].")
	last_threat = current_threat
	life_since = netdm_number(output["since"])
	SStgui.update_uis(src)

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
		restore_persona()
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
	if(chat_channel)
		arguments["channel"] = TRUE
	if(send("chat_read", arguments, CALLBACK(src, PROC_REF(chat_read_answered), chat_epoch, stream)))
		chat_read_pending = TRUE
		pending++
		next_chat_poll = world.time + NETDM_SPACE_REFRESH

/datum/netdm_space/proc/chat_read_answered(epoch, stream, list/output)
	pending = max(0, pending - 1)
	chat_read_pending = FALSE
	if(chat_epoch != epoch || stream != SSnetdm_observe.bridge?.stream_id || presence?["state"] != "active")
		return
	if(chat_channel && output?["channel"])
		var/list/channel_snapshot
		if(istext(output["messages"]))
			try
				channel_snapshot = json_decode(output["messages"])
			catch
				channel_snapshot = null
		var/list/channel_messages = list()
		if(islist(channel_snapshot))
			for(var/list/entry in channel_snapshot)
				if(istext(entry["id"]) && istext(entry["text"]) && istext(entry["sender"]))
					channel_messages += list(list("id" = entry["id"], "text" = entry["text"], "sender" = entry["sender"], "own" = !!entry["own"]))
		chat_messages = channel_messages
		chat_node = null
		chat_scope = "channel"
		chat_stream = stream
		chat_received_at = world.time
		SStgui.update_uis(src)
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
	if(!isliving(user) || !user.client || !has_current_chat() || chat_send_pending)
		return FALSE
	if(!chat_channel && node != chat_node)
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
	var/list/send_arguments = list("scope" = chat_channel ? "channel" : chat_scope, "text" = text)
	if(chat_channel)
		send_arguments["channel"] = TRUE
	if(!send("chat_send", send_arguments, CALLBACK(src, PROC_REF(chat_send_answered), chat_epoch, chat_stream), guard))
		chat_status = "busy"
		return TRUE
	chat_send_pending = TRUE
	chat_status = "sending"
	pending++
	return TRUE

/datum/netdm_space/proc/can_send_chat(epoch)
	return !QDELETED(src) && chat_epoch == epoch && has_current_chat() && actor?.can_submit()

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
	// Leaving the presence ends the dive at once: the operator's own command does not wait for a poll.
	surface_immersion("presence_lost")
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
	line = trim(line)
	var/entry_id = 0
	var/list/entry
	// Capture structured answers for service discovery, commands and their replies.
	if(findtext(line, "api ") == 1 || findtext(line, "invoke ") == 1 || findtext(line, "result ") == 1)
		entry_id = ++action_serial
		entry = list("id" = entry_id, "line" = line, "pending" = TRUE, "status" = null,
			"error" = null, "records" = list())
		action_entries += list(entry)
		if(length(action_entries) > NETDM_SPACE_ACTION_ENTRIES)
			var/list/oldest = action_entries[1]
			action_queries -= "[oldest["id"]]"
			action_entries.Cut(1, 2)
	var/queued = send("act", list("line" = line), CALLBACK(src, PROC_REF(acted), line, entry_id, SSnetdm_observe.bridge?.stream_id))
	if(!queued && entry)
		entry["pending"] = FALSE
		entry["status"] = "refused"
		entry["error"] = "Запрос не принят сетевым транспортом."
		SStgui.update_uis(src)
	return queued

/datum/netdm_space/proc/acted(line, entry_id, stream, list/output)
	var/status = output?["status"]
	if(entry_id)
		for(var/list/entry in action_entries)
			if(entry["id"] != entry_id)
				continue
			entry["pending"] = FALSE
			entry["status"] = status || "no_answer"
			entry["error"] = copytext("[output?["error"]]", 1, 257)
			var/list/rows = list()
			var/list/reply_records = output?["records"]
			if(islist(reply_records))
				for(var/list/record in reply_records)
					if(length(rows) >= NETDM_SPACE_ACTION_RECORDS)
						break
					if(!islist(record))
						continue
					var/list/pairs = list()
					for(var/list/pair in record)
						if(length(pairs) >= NETDM_SPACE_ACTION_FIELDS)
							break
						if(!islist(pair))
							continue
						pairs += list(list("name" = copytext("[pair["name"]]", 1, 81),
							"value" = copytext("[pair["value"]]", 1, 257)))
					rows += list(pairs)
			entry["records"] = rows
			if(status == "ok" && findtext(line, "invoke ") == 1)
				track_action_delivery(entry, stream, first_record(output))
			break
	if(status == "ok")
		var/list/log_rows = list()
		for(var/list/record in output["records"])
			var/list/pairs = list()
			for(var/list/pair in record)
				pairs += "[pair["name"]]=[pair["value"]]"
			log_rows += jointext(pairs, " ")
		note("> [line]: [length(log_rows) ? jointext(log_rows, "; ") : "пусто"]")
	else
		note("> [line]: [status || "нет ответа"] [output?["error"]]")

/datum/netdm_space/proc/track_action_delivery(list/entry, stream, list/fields)
	var/operation = fields["operation"]
	var/instance = fields["instance"]
	if(fields["status"] != "sent" || !istext(operation) || !length(operation) || !istext(instance) || !length(instance))
		return
	var/list/delivery = list("operation" = operation, "instance" = instance, "state" = "queued", "reason" = null)
	entry["delivery"] = delivery
	var/key = "[entry["id"]]"
	if(!stream || stream != SSnetdm_observe.bridge?.stream_id)
		delivery["state"] = "unknown"
		return
	action_queries[key] = list("delivery" = delivery, "stream" = stream, "deadline" = world.time + NETDM_SPACE_ACTION_WAIT, "next_query" = world.time)

/datum/netdm_space/proc/check_action_delivery()
	var/stream = SSnetdm_observe.bridge?.stream_id
	var/datum/node = actor?.network_node()
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	for(var/key in action_queries)
		var/list/query = action_queries[key]
		if(query["stream"] != stream || world.time >= query["deadline"])
			var/list/delivery = query["delivery"]
			finish_action_delivery(key, query["stream"] == stream && delivery["state"] == "applied" ? "applied" : "unknown", "no_answer")
		if(action_queries[key] && node && world.time >= query["next_query"])
			var/list/delivery = query["delivery"]
			query["next_query"] = world.time + 3 SECONDS
			if(lane?.query_command(node, delivery["operation"], CALLBACK(src, PROC_REF(action_delivery_answered), key)))
				break

/datum/netdm_space/proc/action_delivery_answered(key, list/reply)
	var/list/query = action_queries[key]
	if(!query || query["stream"] != SSnetdm_observe.bridge?.stream_id)
		return
	var/list/status = reply?["result"]?["value"]
	var/list/delivery = query["delivery"]
	switch(status?["outcome"])
		if("not_applied")
			finish_action_delivery(key, "not_delivered", status["outcomeReason"])
		if("rejected_by_world")
			finish_action_delivery(key, "rejected", status["outcomeReason"])
		if("unknown")
			finish_action_delivery(key, "unknown", status["outcomeReason"])
		if("applied")
			if(status["result"] == "delivered")
				finish_action_delivery(key, "delivered")
			else if(status["result"] == "none")
				finish_action_delivery(key, "applied")
			else if(delivery["state"] != "applied")
				delivery["state"] = "applied"
				SStgui.update_uis(src)

/datum/netdm_space/proc/finish_action_delivery(key, state, reason)
	var/list/query = action_queries[key]
	var/list/delivery = query["delivery"]
	delivery["state"] = state
	delivery["reason"] = reason
	action_queries -= key
	SStgui.update_uis(src)

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
	return actor?.can_operate_alarm(operator) || FALSE

/datum/netdm_space/proc/alarm_for_service(instance)
	if(!istext(instance) || copytext(instance, 1, 13) != "atmos.alarm.")
		return null
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	var/datum/netdm_service_endpoint/endpoint = lane?.endpoints[copytext(instance, 13)]
	if(!endpoint?.services[instance])
		return null
	var/obj/machinery/airalarm/alarm = lane.registry.resolve(endpoint.id, endpoint.generation)
	return istype(alarm) ? alarm : null

/datum/netdm_space/proc/active_camera_console(mob/living/user)
	var/obj/machinery/computer/security/console = actor?.physical_device()
	if(!istype(console) || !istype(user) || !user.client || !netdm_cameras_enabled() || !actor.can_submit())
		return null
	if(!(REF(user) in console.netdm_camera_viewers) || console.ui_status(user, console.ui_state(user)) != UI_INTERACTIVE)
		return null
	return console

/datum/netdm_space/proc/camera_for_service(instance)
	if(!istext(instance) || copytext(instance, 1, 8) != "camera.")
		return null
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	var/datum/netdm_service_endpoint/endpoint = lane?.endpoints[copytext(instance, 8)]
	if(!endpoint?.services[instance])
		return null
	var/obj/machinery/camera/camera = lane.registry.resolve(endpoint.id, endpoint.generation)
	return istype(camera) ? camera : null

/// Reuse the user's open security console and its ordinary, routed acquisition.
/datum/netdm_space/proc/select_camera(instance, mob/living/user)
	var/list/service = items["s|[instance]"]
	if(service?["type"] != "camera.access" || is_stale(service))
		return FALSE
	var/obj/machinery/computer/security/console = active_camera_console(user)
	var/obj/machinery/camera/camera = camera_for_service(instance)
	if(!console || !console.netdm_camera_allowed(camera))
		return FALSE
	if(!console.netdm_camera_select(camera))
		return FALSE
	SStgui.update_uis(console)
	return TRUE

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
	var/list/request = prepare_machine_command("alarm", instance, operator, alarm, list("enabled" = enabled))
	if(request)
		queue_machine_command(request, "alarm_action", list("instance" = instance, "ticket" = request["ticket"], "enabled" = enabled))
	return TRUE

/// Player controls use the same actions as AiAirlock, routed from the current presence.
/datum/netdm_space/proc/device_action(instance, command, mob/living/operator)
	if(!istext(command) || !(command in list("open", "close", "bolt", "unbolt")) || !istext(instance) || length(instance) > 64 || machine_pending() || presence?["state"] != "active" || !actor?.can_submit())
		return FALSE
	var/list/service = items["s|[instance]"]
	if(service?["type"] != "machine.door" || is_stale(service))
		return FALSE
	var/obj/machinery/door/airlock/door = airlock_for_service(instance)
	if(!door?.netdm_panel_allowed(operator))
		machine_command = list("kind" = "door", "instance" = instance, "action" = command, "status" = "rejected", "reason" = door ? "access_denied" : "door_gone")
		return TRUE
	var/list/request = prepare_machine_command("door", instance, operator, door, list("action" = command))
	if(request)
		queue_machine_command(request, "act", list("line" = "invoke [instance] control ticket=[request["ticket"]] action=[command]"))
	return TRUE

/datum/netdm_space/proc/airlock_for_service(instance)
	var/datum/weakref/door_ref = SSnetdm_observe?.doors?.by_instance[instance]
	var/obj/machinery/door/airlock/door = door_ref?.resolve()
	return istype(door) ? door : null

/datum/netdm_space/proc/prepare_machine_command(kind, instance, mob/living/operator, atom/target, list/fields)
	var/datum/node = actor?.network_node()
	var/datum/netdm_service_endpoint/endpoint = node ? SSnetdm_observe.services?.by_node[node] : null
	var/datum/netdm_diagnostics/diagnostics = SSnetdm_observe.diagnostics
	if(!endpoint?.attached_node || !diagnostics || length(diagnostics.machine_actions) >= NETDM_SPACE_ACTION_LIMIT)
		machine_command = list("kind" = kind, "instance" = instance, "status" = "not_delivered",
			"reason" = endpoint?.attached_node ? "busy" : "offline") + fields
		return null
	var/ticket = rustg_generate_uuid_v4()
	return list("ticket" = ticket, "kind" = kind, "window" = WEAKREF(src), "operator" = WEAKREF(operator), "target" = WEAKREF(target),
		"instance" = instance, "status" = "sending", "entry" = endpoint.id, "generation" = "[endpoint.generation]",
		"stream" = SSnetdm_observe.bridge?.stream_id, "deadline" = world.time + NETDM_SPACE_ACTION_WAIT, "next_query" = world.time + 3 SECONDS) + fields

/datum/netdm_space/proc/queue_machine_command(list/request, protocol, list/arguments)
	machine_command = request
	if(!send(protocol, arguments, CALLBACK(src, PROC_REF(machine_accepted), request)))
		finish_machine_command("not_delivered", "busy")
		return
	SSnetdm_observe.diagnostics.machine_actions[request["ticket"]] = request

/datum/netdm_diagnostics/proc/claim_machine_action(list/item, atom/target, list/payload, kind, field)
	var/ticket = payload?["ticket"]
	var/list/request = istext(ticket) ? machine_actions[ticket] : null
	if(!request || request["kind"] != kind || request["used"] || world.time >= request["deadline"] || request["stream"] != SSnetdm_observe.bridge?.stream_id || \
		request["instance"] != item["instance"] || request["entry"] != item["producer"] || request["generation"] != "[item["producerGeneration"]]" || request[field] != payload[field])
		return null
	var/datum/weakref/target_ref = request["target"]
	if(target_ref?.resolve() != target || !machine_action_window(request))
		return null
	request["used"] = TRUE
	request["operation"] = "[item["operationId"]]"
	return request

/datum/netdm_diagnostics/proc/machine_action_window(list/request)
	if(!request || request["stream"] != SSnetdm_observe.bridge?.stream_id || world.time >= request["deadline"])
		return null
	var/datum/weakref/window_ref = request?["window"]
	var/datum/netdm_space/window = window_ref?.resolve()
	return window?.machine_command == request && window?.actor?.can_submit() ? window : null

/datum/netdm_diagnostics/proc/machine_action_receipt(list/item, kind)
	var/list/payload = item["payload"]
	var/ticket = payload?["ticket"]
	var/list/request = istext(ticket) ? machine_actions[ticket] : null
	if(!request?["used"] || request["kind"] != kind || request["operation"] != "[item["operationId"]]" || request["instance"] != item["instance"] || \
		request["entry"] != item["recipient"] || request["generation"] != "[item["recipientGeneration"]]" || request["stream"] != SSnetdm_observe.bridge?.stream_id)
		return null
	return request

/datum/netdm_diagnostics/proc/consume_alarm_action(list/item, obj/machinery/airalarm/alarm, list/payload)
	var/list/request = claim_machine_action(item, alarm, payload, "alarm", "enabled")
	var/datum/netdm_space/window = machine_action_window(request)
	var/datum/weakref/operator_ref = request?["operator"]
	var/mob/living/operator = operator_ref?.resolve()
	return window?.can_operate_alarm(operator) ? operator : null

/datum/netdm_diagnostics/proc/alarm_action_received(list/item)
	var/list/request = machine_action_receipt(item, "alarm")
	var/datum/netdm_space/window = machine_action_window(request)
	if(window)
		var/list/payload = item["payload"]
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
	var/datum/node = actor?.network_node()
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
			if(!request["receipt_received"] && (status["result"] == "failed" || status["result"] == "delivered"))
				finish_machine_command("no_receipt", status["resultReason"])

/datum/netdm_space/proc/forget_machine_ticket()
	if(machine_command?["ticket"])
		var/datum/netdm_diagnostics/diagnostics = SSnetdm_observe?.diagnostics
		if(diagnostics)
			diagnostics.machine_actions -= machine_command["ticket"]

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
	var/datum/node = actor?.network_node()
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
	if(!istext(instance) || length(instance) > 64 || presence?["state"] != "active" || !actor?.can_submit())
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
	if(!alarm_watch || alarm_request || world.time < next_alarm_watch || presence?["state"] != "active" || !actor?.can_submit())
		return
	var/datum/node = actor?.network_node()
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
	if(!actor?.can_submit() || (watch && presence?["state"] != "active"))
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
	var/may_control_door = presence?["state"] == "active" && actor?.can_submit()
	var/obj/machinery/computer/security/console = active_camera_console(user)
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
				var/obj/machinery/camera/camera
				if(console && on_level[fields["node"]] && fields["type"] == "camera.access" && !is_stale(fields))
					camera = camera_for_service(fields["instance"])
				var/list/door_panel
				if(may_control_door && on_level[fields["node"]] && fields["type"] == "machine.door" && !is_stale(fields))
					var/obj/machinery/door/airlock/door = airlock_for_service(fields["instance"])
					if(door?.netdm_panel_allowed(user))
						door_panel = list("opened" = !door.density, "bolted" = !!door.locked)
				services += list(list("instance" = fields["instance"], "type" = fields["type"], "node" = fields["node"],
					"stale" = is_stale(fields), "canControlAlarm" = !!alarm?.netdm_can_set_alert(user),
					"cameraName" = camera && console.netdm_camera_allowed(camera) ? camera.c_tag : null,
					"doorPanel" = door_panel))
	var/list/watch_data
	if(alarm_watch)
		watch_data = list("instance" = alarm_watch["instance"], "node" = alarm_watch["node"], "z" = alarm_watch["z"],
			"state" = presence?["state"] == "active" && actor?.can_submit() ? alarm_watch["state"] : "paused",
			"sample" = alarm_watch["sample"], "age" = isnull(alarm_watch["at"]) ? null : floor((world.time - alarm_watch["at"]) / 10))
	var/list/command_data
	if(machine_command)
		command_data = list("kind" = machine_command["kind"], "instance" = machine_command["instance"], "enabled" = machine_command["enabled"], "status" = machine_command["status"],
			"operation" = machine_command["operation"], "reason" = machine_command["reason"], "source" = machine_command["source"],
			"zoneAlarm" = machine_command["zoneAlarm"], "sourceActive" = machine_command["sourceActive"], "changed" = machine_command["changed"],
			"doorAction" = machine_command["action"], "doorOpen" = machine_command["door_open"], "doorBolted" = machine_command["door_bolted"])
	var/list/chat_data
	if(has_current_chat())
		// The UI can identify a visit across missed polls without receiving its write scope.
		chat_data = list("node" = chat_node, "channel" = chat_channel, "visit" = chat_channel ? "channel" : md5(chat_scope), "received" = chat_received,
			"messages" = chat_messages, "status" = chat_status)
	return list("title" = actor?.title() || "нет связи", "entityRole" = !!actor?.is_entity_role(), "z" = z, "levels" = levels,
		"terminal" = actor?.terminal_data(user),
		"nodes" = nodes, "edges" = edges, "down" = down, "services" = services, "presence" = presence, "hostNode" = host,
		"otherPresences" = occupants_on_level,
		"immersed" = immersed, "immersionEnabled" = netdm_immersion_enabled() && !!actor?.neural_implant(), "immersionReason" = immersed_reason,
		"immersedSeconds" = (immersed && immersed_at) ? round((world.time - immersed_at) / 10) : 0,
		"life" = life, "incidents" = SSnetdm_observe?.netdm_incidents || list(), "hack" = list("status" = hack_status, "code" = hack_code, "target" = hack_target, "remaining" = max(0, (hack_expires - world.time) / (1 SECONDS)), "keys" = hack_keys, "masked" = hack_masked), "persona" = islist(presence) ? list("name" = presence["personaName"], "signature" = presence["personaSignature"], "status" = presence["personaStatus"], "role" = presence["personaRole"], "colour" = text2num("[presence["personaColour"]]")) : null,
		"chat" = chat_data,
		"log" = log, "actionEntries" = action_entries, "revision" = revision, "alarmPending" = !!alarm_request, "alarmWatch" = watch_data,
		"routePreview" = route_preview, "machineCommand" = command_data)

/datum/netdm_space/ui_act(action, list/params, datum/tgui/ui, datum/ui_state/state)
	. = ..()
	if(.)
		return
	return dispatch_ui_action(action, params, ui.user, state)

#define NETDM_UI_USER 1
#define NETDM_UI_STATE 2
#define NETDM_UI_PARAMS 3

/// Each public action binds only its own parameters. Only allowlisted, local methods can run.
/datum/netdm_space/proc/dispatch_ui_action(action, list/params, mob/user, datum/ui_state/state)
	var/static/list/actions = list(
		"scan" = list(PROC_REF(scan_from_ui), "radius"),
		"enter" = list(PROC_REF(enter)),
		"leave" = list(PROC_REF(leave)),
		"leave_role" = list(PROC_REF(leave_role), NETDM_UI_USER, NETDM_UI_STATE),
		"move" = list(PROC_REF(move), "to"),
		"preview_move" = list(PROC_REF(preview_move), "to"),
		"clear_route_preview" = list(PROC_REF(clear_route_preview)),
		"abort_move" = list(PROC_REF(abort_move)),
		"act" = list(PROC_REF(act_from_ui), "line"),
		"terminal" = list(PROC_REF(terminal_from_ui), "command", "params", NETDM_UI_USER),
		"device_action" = list(PROC_REF(device_action), "instance", "command", NETDM_UI_USER),
		"select_camera" = list(PROC_REF(select_camera), "instance", NETDM_UI_USER),
		"send_chat" = list(PROC_REF(send_chat), NETDM_UI_USER, "node", "text"),
		"read_alarm" = list(PROC_REF(read_alarm), "instance"),
		"watch_alarm" = list(PROC_REF(watch_alarm), "instance", NETDM_UI_USER),
		"stop_alarm_watch" = list(PROC_REF(stop_alarm_watch)),
		"machine_alert" = list(PROC_REF(operate_alarm), "instance", "enabled", NETDM_UI_USER),
		"level" = list(PROC_REF(select_level), "z"),
		"immerse" = list(PROC_REF(immerse)),
		"surface" = list(PROC_REF(surface_immersion)),
		"persona" = list(PROC_REF(set_persona), NETDM_UI_PARAMS, NETDM_UI_USER),
		"chat_channel" = list(PROC_REF(toggle_chat_channel)),
		"banish" = list(PROC_REF(banish_intruder)),
		"call_courier" = list(PROC_REF(call_courier)),
		"call_engineer" = list(PROC_REF(call_engineer)),
		"call_agent" = list(PROC_REF(call_agent_from_ui), "goal"),
		"hack_start" = list(PROC_REF(hack_start), "node"),
		"hack_answer" = list(PROC_REF(hack_submit), "code"),
		"hack_keys" = list(PROC_REF(hack_refresh_keys)),
		"hack_mask" = list(PROC_REF(hack_toggle_mask)),
		"hack_use" = list(PROC_REF(hack_use), "node"),
	)
	var/list/route = istext(action) ? actions[action] : null
	if(!route)
		return FALSE
	var/handler = route[1]
	if(length(route) == 1)
		return call(src, handler)()
	var/list/context = list(user, state, params)
	var/list/arguments = list()
	for(var/index in 2 to length(route))
		var/parameter = route[index]
		arguments += list(isnum(parameter) ? context[parameter] : params?[parameter])
	return call(src, handler)(arglist(arguments))

#undef NETDM_UI_USER
#undef NETDM_UI_STATE
#undef NETDM_UI_PARAMS

/datum/netdm_space/proc/scan_from_ui(radius)
	return scan(text2num("[radius]") || 3)

/datum/netdm_space/proc/act_from_ui(line)
	return act_line("[line]")

/datum/netdm_space/proc/terminal_from_ui(command, params, mob/user)
	return actor?.terminal_action(command, params, user) || FALSE

/datum/netdm_space/proc/select_level(level)
	level = text2num("[level]")
	if(isnum(level))
		z = level
	return TRUE

/datum/netdm_space/proc/leave_role(mob/user, datum/ui_state/state)
	return actor?.leave_role(user, state) || FALSE

/datum/netdm_space/proc/abort_move()
	if(presence?["state"] != "moving")
		return FALSE
	return send("abort_move", list("note" = "window"), CALLBACK(src, PROC_REF(presence_changed), "Отмена перехода"))

/datum/netdm_space/proc/toggle_chat_channel()
	chat_channel = !chat_channel
	clear_chat()
	return TRUE

/datum/netdm_space/proc/call_agent_from_ui(goal)
	var/static/list/available_goals = list("courier", "engineer", "sentinel", "watcher", "archivist")
	goal = "[goal]"
	return (goal in available_goals) && call_agent(goal)

/// A detach sent by a closing window: its answer has nobody to show it to.
/datum/netdm_diagnostics/proc/space_ignored(list/output)
	return

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

/// P13: counterplay for the operator: push a hostile agent off this node through the Host.
/datum/netdm_space/proc/banish_intruder()
	if(!SSnetdm_observe?.services || !islist(presence))
		note("Сеть занята.")
		return FALSE
	var/node = presence?["node"]
	if("[node]" == "")
		note("Присутствие ещё не имеет узла.")
		return FALSE
	if(!SSnetdm_observe.services.control("network_life", list("action" = "banish", "node" = "[node]"),
		CALLBACK(src, PROC_REF(banish_answered))))
		note("Сеть занята: повторите через секунду.")
		return FALSE
	return TRUE

/datum/netdm_space/proc/banish_answered(list/reply)
	if(!reply?["ok"])
		note("Сеть отказала: [reply?["error"] || "нет ответа"].")
		return
	var/list/result = reply?["result"]
	if(text2num("[result?["banished"]]") > 0)
		note("Враждебный агент выгнан из сети.")
		SSnetdm_observe?.netdm_incident("banish", presence?["node"], "Оператор [presence?["personaName"]] выгнал вторженца.")
		SStgui.update_uis(src)
	else
		note("На вашем узле нет враждебных агентов.")

/// P13: the operator asks the network for an agent of a goal: a courier, an engineer, a watcher.
/datum/netdm_space/proc/call_agent(goal)
	if(!SSnetdm_observe?.services || !islist(presence))
		note("Сеть занята.")
		return FALSE
	var/node = presence?["node"]
	if("[node]" == "")
		note("Присутствие ещё не имеет узла.")
		return FALSE
	if(!SSnetdm_observe.services.control("network_life", list("action" = "spawn", "count" = 1, "goal" = "[goal]",
		"node" = "[node]"), CALLBACK(src, PROC_REF(agent_called), "[goal]")))
		note("Сеть занята: повторите через секунду.")
		return FALSE
	return TRUE

/datum/netdm_space/proc/call_courier()
	return call_agent("courier")

/datum/netdm_space/proc/call_engineer()
	return call_agent("engineer")

/datum/netdm_space/proc/agent_called(list/reply, goal)
	if(!reply?["ok"])
		note("Сеть отказала: [reply?["error"] || "нет ответа"].")
		return
	var/list/titles = list("courier" = "Курьер", "engineer" = "Инженер", "watcher" = "Наблюдатель", "sentinel" = "Страж", "archivist" = "Архивист")
	note("[titles[goal] || "Агент"] вызван к вашему узлу.")
	SSnetdm_observe?.netdm_incident(goal, presence?["node"], "Оператор [presence?["personaName"]] вызвал агента: [titles[goal] || goal].")
	SStgui.update_uis(src)

/// P13: the persona role is the station job the operator already has; it is shown, not granted.
/proc/netdm_persona_role(mob/living/user)
	var/title = "неизвестно"
	if(user)
		var/datum/mind/mind = user.mind
		if(mind && mind.assigned_role)
			title = "[mind.assigned_role]"
		else if(user.job)
			title = "[user.job]"
	return copytext(title, 1, 25)

/// Starts a breach against a known APC, the type whose key can operate a machine.
/datum/netdm_space/proc/hack_start(node)
	node = "[node]"
	if(!SSnetdm_observe?.services || !islist(presence))
		note("Сеть занята.")
		return FALSE
	if(hack_status == "waiting" || hack_status == "checking" || (hack_code && world.time < hack_expires))
		return FALSE
	if(pending_departures || presence["state"] != "active" || "[presence["node"]]" != node)
		return FALSE
	var/list/known_node = items["n|[node]"]
	if(!known_node || is_stale(known_node) || !SSnetdm_observe.apc_by_node_id(node))
		return FALSE
	hack_target = node
	hack_code = null
	if(!send("hack_start", list("node" = "[node]"), CALLBACK(src, PROC_REF(hack_start_answered))))
		hack_status = "busy"
		note("Сеть занята: повторите через секунду.")
		return FALSE
	hack_status = "waiting"
	// The UI budgets from submission, so time spent delivering the challenge counts.
	hack_expires = world.time + NETDM_SPACE_HACK_WINDOW
	return TRUE

/datum/netdm_space/proc/hack_start_answered(list/output)
	hack_status = output?["status"] || "no_answer"
	if(hack_status == "challenge")
		hack_code = "[output["code"]]"
		hack_target = "[output["target"]]"
	else if(hack_status == "cooldown")
		note("Взлом на перезарядке: ещё [output["retryIn"] || 0] с.")
	else if(hack_status == "no_knowledge")
		note("Узел ещё не изучен: сначала просканируйте сеть.")
	else
		note("Взлом не начат: [hack_status].")
	SStgui.update_uis(src)

/datum/netdm_space/proc/hack_submit(code)
	code = "[code]"
	if(!SSnetdm_observe?.services || !islist(presence))
		note("Сеть занята.")
		return FALSE
	if(hack_status != "challenge" || !hack_code || length(code) != length(hack_code))
		return FALSE
	if(pending_departures || presence["state"] != "active" || "[presence["node"]]" != hack_target)
		return FALSE
	if(world.time >= hack_expires)
		hack_status = "expired"
		hack_code = null
		SStgui.update_uis(src)
		return FALSE
	if(!send("hack_answer", list("code" = code), CALLBACK(src, PROC_REF(hack_answer_answered))))
		hack_status = "busy"
		hack_code = null
		note("Сеть занята: повторите через секунду.")
		return FALSE
	hack_status = "checking"
	return TRUE

/datum/netdm_space/proc/hack_answer_answered(list/output)
	hack_status = output?["status"] || "no_answer"
	if(hack_status == "ok")
		hack_code = null
		hack_target = "[output["node"]]"
		hack_keys = parse_hack_keys("[output["keys"]]")
		note("Доступ получен: [output["label"] || "узел"] (ещё [output["expiresIn"] || 0] с).")
	else if(hack_status == "failed")
		note("Взлом провален: система заметила попытку. Перезарядка [output["retryIn"] || 0] с.")
		hack_code = null
	else
		note("Взлом: [hack_status].")
		hack_code = null
	SStgui.update_uis(src)

/datum/netdm_space/proc/hack_refresh_keys()
	if(!SSnetdm_observe?.services || !islist(presence))
		return FALSE
	if(!send("hack_keys", list("since" = 0), CALLBACK(src, PROC_REF(hack_keys_answered))))
		return FALSE
	return TRUE

/datum/netdm_space/proc/hack_keys_answered(list/output)
	if(output?["status"] != "ok")
		return
	hack_keys = parse_hack_keys("[output["keys"]]")
	hack_masked = !!output["masked"]
	SStgui.update_uis(src)

/datum/netdm_space/proc/hack_toggle_mask()
	if(!SSnetdm_observe?.services || !islist(presence))
		note("Сеть занята.")
		return FALSE
	if(!send("mask", list("on" = hack_masked ? FALSE : TRUE), CALLBACK(src, PROC_REF(hack_mask_answered))))
		note("Сеть занята: повторите через секунду.")
		return FALSE
	return TRUE

/datum/netdm_space/proc/hack_mask_answered(list/output)
	if(output?["status"] == "masked" || output?["status"] == "unmasked")
		hack_masked = !!output["masked"]
		note(hack_masked ? "Личность скрыта от других операторов." : "Личность снова видна.")
	else if(output?["status"] == "cooldown")
		note("Маскировка на перезарядке: ещё [output["retryIn"] || 0] с.")
	else
		note("Маскировка не удалась: [output?["status"] || "нет ответа"].")
	SStgui.update_uis(src)

/// Uses a stolen key for a physical effect the Host authorises: currently the APC breaker.
/datum/netdm_space/proc/hack_use(node)
	node = "[node]"
	if(!SSnetdm_observe?.services || !islist(presence))
		note("Сеть занята.")
		return FALSE
	if(hack_use_pending || pending_departures || presence["state"] != "active" || "[presence["node"]]" != node)
		return FALSE
	if(!send("hack_use", list("node" = node, "purpose" = "breaker"),
			CALLBACK(src, PROC_REF(hack_use_answered), node, presence["presence"], presence["generation"])))
		note("Сеть занята: повторите через секунду.")
		return FALSE
	hack_use_pending = TRUE
	return TRUE

/datum/netdm_space/proc/hack_use_answered(node, presence_id, generation, list/reply)
	hack_use_pending = FALSE
	if(reply?["status"] != "ok" || reply["node"] != node || reply["purpose"] != "breaker")
		note("Доступ к узлу не подтверждён: [reply?["status"] || "нет ответа"].")
		return
	if(pending_departures || presence?["state"] != "active" || "[presence["node"]]" != node || \
			presence["presence"] != presence_id || presence["generation"] != generation)
		note("Команда отменена: присутствие сменило узел.")
		return
	var/obj/machinery/power/apc/apc = SSnetdm_observe.apc_by_node_id(node)
	if(!apc)
		note("По этому узлу нет АПЦ, которым можно управлять отсюда.")
		return
	apc.operating = !apc.operating
	apc.update()
	apc.update_appearance()
	apc.visible_message(span_warning("Индикаторы [apc] переключились: питание изменено по сети."))
	playsound(apc, 'sound/machines/terminal_button01.ogg', 40, TRUE)
	SSnetdm_observe?.netdm_incident("key_use", node, "Питание [apc] переключено по украденному доступу.")
	note("Питание [apc] переключено по украденному доступу.")
	SStgui.update_uis(src)

/datum/netdm_space/proc/parse_hack_keys(text)
	var/list/result = list()
	for(var/line in splittext("[text]", ";"))
		var/list/parts = splittext(line, "|")
		if(length(parts) < 3)
			continue
		result += list(list("node" = parts[1], "label" = parts[2], "ttl" = text2num(parts[3])))
	return result

#undef NETDM_SPACE_HACK_WINDOW
