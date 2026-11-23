/// The sender waits this long, in real time, for the server's answer before "Server is not responding".
#define NETDM_RELAY_ANSWER (10 SECONDS)
/// A status query may prove that a missing answer is safe to retry.
#define NETDM_RELAY_STATUS_ANSWER (5 SECONDS)
/// A sender's message keeps waiting for recipient statuses this long, in real time.
#define NETDM_RELAY_STATUS_WAIT (60 SECONDS)
/// Deliveries and statuses a message server holds before it refuses new messages.
#define NETDM_RELAY_OUTBOX 256
/// Messages a sender tracks at once; the oldest is dropped beyond this.
#define NETDM_RELAY_OUTGOING 256
/// Relays a server remembers, so a retried relay is not logged or delivered twice.
#define NETDM_RELAY_SEEN 2048

/**
 * pda.messenger in authoritative mode (P7), through the message server.
 *
 * A message server is a fixed netDM node with the service `msgsrv.<endpoint>` (`pda.server`). An eligible
 * message (the Shadow compatibility exceptions keep the legacy path) leaves the sender's PDA as the
 * command `relay` to a server instead of a telecomms signal. The server refuses while it is off or
 * unpowered; otherwise it logs the message for the message monitor, answers `queued`, and delivers it to
 * each recipient with `deliver`. The recipient shows a message ID once through the legacy presentation
 * (chat, reply, block, ringtone) and returns a receipt to the server; the server reports each recipient's
 * outcome to the sender with `status`. The network never says what the sender cannot know: a missing
 * answer is the sender's own timeout, a missing receipt the server's.
 */
/datum/netdm_messenger_shadow
	/// NETDM_MESSENGER_MODE=authoritative, or set_authoritative() at runtime.
	var/authoritative = TRUE
	/// Server instance -> server weakref, and back.
	var/list/servers = list()
	var/list/server_instances = list()
	/// The current legacy send: who sends it and whether it left through a server.
	var/datum/computer_file/program/messenger/current_sender
	var/current_relayed = FALSE
	/// Sender side: message ID -> record, oldest first.
	var/list/outgoing = list()
	/// Server side: deliveries and statuses waiting for the lane, oldest first.
	var/list/outbox = list()
	/// Server side: operation ID -> delivery in flight.
	var/list/relaying = list()
	/// Server side: "server/message" -> world.time of relays already taken.
	var/list/relayed = list()
	/// How long a server delivery may travel, in Host ticks of 100 ms: a recipient briefly out of
	/// coverage still gets it. The server waits for the receipt until the delivery can no longer arrive.
	var/delivery_ttl_ticks = 300
	var/list/relay_counters = list("relayed" = 0, "queued" = 0, "offline" = 0, "no_answer" = 0, "refused" = 0, "logged" = 0,
		"shown" = 0, "duplicates" = 0, "delivered" = 0, "unreachable" = 0, "blocked" = 0, "disabled" = 0, "legacy" = 0,
		"status_missing" = 0, "outbox_full" = 0)
	/// Send -> server answer at the sender, microseconds.
	var/list/relay_latencies = list()

/datum/netdm_messenger_shadow/proc/setup_relay(datum/netdm_service_lane/lane)
	lane.dispatcher.allow_command("pda.server", "relay", new /datum/netdm_command_handler/pda_relay)
	lane.dispatcher.allow_result("relay", new /datum/netdm_effect_handler/pda_relay_answer, "pda.server")
	lane.dispatcher.allow_command("pda.messenger", "status", new /datum/netdm_command_handler/pda_status)
	lane.dispatcher.allow_result("status", new /datum/netdm_effect_handler/pda_status_receipt, "pda.messenger")
	// All tablet messages must pass through the addressable message server.

/// Switches the delivery owner. Shadow again: messages already on their way finish or time out.
/datum/netdm_messenger_shadow/proc/set_authoritative(enabled)
	// Legacy bypass is not a supported delivery mode.
	if(!enabled)
		return FALSE
	for(var/obj/machinery/telecomms/message_server/server in GLOB.telecomms_list)
		add_server(server)

/datum/netdm_messenger_shadow/proc/reset_relay_session()
	// Operations of the old session never answer; the timeouts of senders and servers report them.
	relaying.Cut()

/// A message server becomes a fixed node offering msgsrv.<endpoint>.
/datum/netdm_messenger_shadow/proc/add_server(obj/machinery/telecomms/message_server/server)
	if(!authoritative || QDELETED(server) || server_instances[WEAKREF(server)])
		return
	var/datum/component/netdm_node/node = netdm_make_node(server)
	var/datum/netdm_service_endpoint/endpoint = node ? SSnetdm_observe.services?.endpoint_for(node) : null
	if(!endpoint)
		return
	var/instance = "msgsrv.[endpoint.id]"
	SSnetdm_observe.services.offer(node, instance, "pda.server", "pda.relay", 1)
	servers[instance] = WEAKREF(server)
	server_instances[WEAKREF(server)] = instance

/// The server a PDA sends to: a registered one on its own level first. A PDA is configured with its
/// server; whether that server is on is something it learns only from the answer.
/datum/netdm_messenger_shadow/proc/choose_server(atom/computer, excluded_instance)
	var/turf/position = get_turf(computer)
	var/fallback
	for(var/instance in servers)
		if(instance == excluded_instance)
			continue
		var/datum/weakref/server_ref = servers[instance]
		var/obj/machinery/telecomms/message_server/server = server_ref.resolve()
		if(!server)
			servers -= instance
			continue
		var/datum/component/netdm_node/node = server.GetComponent(/datum/component/netdm_node)
		if(!node || !SSnetdm_observe.services.ready(node, instance))
			continue
		var/turf/server_turf = get_turf(server)
		if(position && server_turf?.z == position.z)
			return instance
		if(!fallback)
			fallback = instance
	return fallback

/// Real time after which a server delivery can no longer arrive: its TTL (a Host tick is a decisecond) and a margin.
/datum/netdm_messenger_shadow/proc/delivery_wait()
	return delivery_ttl_ticks + 5 SECONDS

/datum/netdm_messenger_shadow/proc/notify(datum/computer_file/program/messenger/messenger, text, error = TRUE)
	var/obj/item/modular_computer/computer = messenger?.computer
	if(QDELETED(computer))
		return
	var/mob/living/holder = isliving(computer.loc) ? computer.loc : (isliving(computer.loc?.loc) ? computer.loc.loc : null)
	if(holder)
		to_chat(holder, span_notice(text))
	if(error && messenger.alert_able && !messenger.alert_silenced)
		playsound(computer, 'sound/machines/terminal_error.ogg', 15, TRUE)

// ---- Sender ----------------------------------------------------------------------------------

/**
 * The legacy send built its tablet signal. Returns "legacy" for a compatibility exception (telecomms
 * carries it), "sent" when it left for a server, "failed" when it cannot leave: the legacy send then
 * reports the server not responding, or a silicon or debug bypass delivers it directly.
 */
/datum/netdm_messenger_shadow/proc/relay(datum/signal/subspace/messaging/tablet_message/signal)
	var/id = signal.data["netdm_id"]
	var/datum/computer_file/program/messenger/sender = current_sender
	if(!id || id != current_id || !sender)
		return "failed"
	var/list/targets = signal.data["targets"]
	var/text = signal.data["message"]
	if(signal.data["rigged"] || signal.data["everyone"] || signal.data["photo"] || signal.data["automated"] \
		|| !length(targets) || length(targets) > NETDM_MESSENGER_FANOUT || length(text) > NETDM_MESSENGER_TEXT)
		return "failed"
	var/list/names = list()
	for(var/datum/computer_file/program/messenger/target as anything in targets)
		var/target_instance = instances[WEAKREF(target)]
		if(!target_instance)
			reasons["relay_target_unregistered"]++
			return "failed" // A missing endpoint cannot be delivered through a second transport.
		names[target_instance] = get_messenger_name(target) || "Unknown"
	var/instance = instances[WEAKREF(sender)]
	var/datum/component/netdm_node/node = sender.computer?.GetComponent(/datum/component/netdm_node)
	var/server = instance && node ? choose_server(sender.computer) : null
	if(!server)
		reasons["relay_no_server"]++
		return "failed"
	var/sender_name = copytext(get_messenger_name(sender) || "Unknown", 1, 128)
	var/list/record = list("id" = id, "sender" = WEAKREF(sender), "instance" = instance, "names" = names,
		"statuses" = list(), "state" = "relaying", "sent_us" = netdm_now_us(), "stream" = SSnetdm_observe.bridge?.stream_id,
		"arguments" = list("id" = id, "text" = text, "sender" = sender_name, "to" = jointext(names, ",")))
	if(!queue_relay(record, node, server))
		reasons["relay_lane_full"]++
		return "failed"
	outgoing[id] = record
	if(length(outgoing) > NETDM_RELAY_OUTGOING)
		outgoing.Cut(1, 2)
	current_relayed = TRUE
	relay_counters["relayed"]++
	return "sent"

/datum/netdm_messenger_shadow/proc/queue_relay(list/record, datum/component/netdm_node/node, server)
	var/id = record["id"]
	if(!SSnetdm_observe.services.invoke(node, server, "relay", id, record["arguments"], CALLBACK(src, PROC_REF(relay_accepted), id)))
		return FALSE
	record["server"] = server
	record["op"] = null
	record["status_deadline"] = null
	record["sent_rt"] = REALTIMEOFDAY
	return TRUE

/// The original relay must be known not to have taken effect before trying another provider.
/datum/netdm_messenger_shadow/proc/try_backup_relay(list/record)
	if(record["tried_backup"] || !record["stream"] || record["stream"] != SSnetdm_observe.bridge?.stream_id)
		return FALSE
	var/datum/weakref/sender_ref = record["sender"]
	var/datum/computer_file/program/messenger/sender = sender_ref?.resolve()
	var/datum/component/netdm_node/node = sender?.computer?.GetComponent(/datum/component/netdm_node)
	var/backup = node ? choose_server(sender.computer, record["server"]) : null
	if(!backup || !queue_relay(record, node, backup))
		return FALSE
	record["tried_backup"] = TRUE
	return TRUE

/datum/netdm_messenger_shadow/proc/relay_accepted(id, list/entry, list/reply)
	var/list/record = outgoing[id]
	if(!record || record["server"] != entry["instance"])
		return
	var/list/result = reply["result"]
	var/list/value = islist(result) ? result["value"] : null
	if(reply["ok"] && islist(value) && !isnull(value["operationId"]))
		record["op"] = "[value["operationId"]]"
	else if(reply["error"] != "unknown_service" || !try_backup_relay(record))
		relay_failed(record, "host_[reply["error"] || "refused"]")

/// The server's answer came back over the network.
/datum/netdm_messenger_shadow/proc/relay_answered(atom/computer, list/item)
	var/list/payload = item["payload"]
	var/id = islist(payload) ? payload["id"] : null
	var/list/record = id ? outgoing[id] : null
	if(!record)
		for(var/key in outgoing)
			var/list/candidate = outgoing[key]
			if(candidate["op"] == "[item["operationId"]]")
				record = candidate
				break
	if(!record || record["state"] != "relaying" || record["stream"] != SSnetdm_observe.bridge?.stream_id \
		|| "msgsrv.[item["producer"]]" != record["server"])
		return TRUE
	var/state = islist(payload) ? payload["state"] : null
	if(state == "queued")
		record["state"] = "queued"
		record["arguments"] = null
		relay_counters["queued"]++
		push(relay_latencies, netdm_now_us() - record["sent_us"])
		return TRUE
	if(item["outcome"] == "rejected_by_world" && item["reason"] == "offline" && try_backup_relay(record))
		return TRUE
	relay_failed(record, state || item["reason"] || item["outcome"] || "refused")
	return TRUE

/datum/netdm_messenger_shadow/proc/relay_failed(list/record, reason)
	if(record["state"] != "relaying")
		return
	record["state"] = "failed"
	record["reason"] = reason
	relay_counters[reason == "offline" ? "offline" : reason == "no_answer" ? "no_answer" : "refused"]++
	reasons["relay_[reason]"]++
	var/datum/weakref/sender_ref = record["sender"]
	notify(sender_ref?.resolve(), "ERROR: Server is not responding.")

/// The Host can tell whether a timed-out relay ever reached the server.
/datum/netdm_messenger_shadow/proc/explain_relay(list/record)
	var/datum/weakref/sender_ref = record["sender"]
	var/datum/computer_file/program/messenger/sender = sender_ref?.resolve()
	var/datum/component/netdm_node/node = sender?.computer?.GetComponent(/datum/component/netdm_node)
	if(!record["op"] || !node || !record["stream"] || record["stream"] != SSnetdm_observe.bridge?.stream_id \
		|| !SSnetdm_observe.services.query_command(node, record["op"], CALLBACK(src, PROC_REF(relay_explained), record["id"], record["op"])))
		reasons["relay_unexplained"]++
		relay_failed(record, "no_answer")
		return
	record["status_deadline"] = REALTIMEOFDAY + NETDM_RELAY_STATUS_ANSWER

/datum/netdm_messenger_shadow/proc/relay_explained(id, operation, list/reply)
	var/list/record = outgoing[id]
	if(!record || record["state"] != "relaying" || record["op"] != operation \
		|| record["stream"] != SSnetdm_observe.bridge?.stream_id)
		return
	var/list/result = reply["result"]
	var/list/value = islist(result) ? result["value"] : null
	reasons["relay_route_[islist(value) ? (value["outcomeReason"] || value["outcome"] || "unknown") : "status_[reply["error"]]"]"]++
	if(reply["ok"] && value?["outcome"] == "not_applied" && try_backup_relay(record))
		return
	relay_failed(record, "no_answer")

/// A recipient's outcome, reported by the server that relayed the message.
/datum/netdm_messenger_shadow/proc/status_received(atom/computer, list/item)
	var/list/payload = item["payload"]
	var/id = islist(payload) ? payload["id"] : null
	var/recipient = islist(payload) ? payload["recipient"] : null
	var/list/record = istext(id) ? outgoing[id] : null
	if(!record || !istext(recipient) || isnull(record["names"][recipient]) || "msgsrv.[item["producer"]]" != record["server"])
		return "unknown_message"
	var/datum/weakref/sender_ref = record["sender"]
	var/datum/computer_file/program/messenger/sender = sender_ref?.resolve()
	if(!sender || messenger_of(computer) != sender)
		return "unknown_message"
	var/state = payload["state"]
	if(!isnull(record["statuses"][recipient]))
		return list("result" = list("id" = id, "state" = "recorded"))
	record["statuses"][recipient] = state
	relay_counters[state]++
	var/name = record["names"][recipient]
	switch(state)
		if("blocked")
			notify(sender, "Пользователь вас заблокировал.", FALSE)
		if("disabled")
			notify(sender, "ERROR: [name] has receiving disabled.")
		if("unreachable")
			notify(sender, "ERROR: Message to [name] was not delivered: no connection.")
	if(length(record["statuses"]) >= length(record["names"]))
		outgoing -= id
	return list("result" = list("id" = id, "state" = "recorded"))

// ---- Message server --------------------------------------------------------------------------

/datum/netdm_messenger_shadow/proc/relay_received(obj/machinery/telecomms/message_server/server, list/item)
	var/server_instance = server_instances[WEAKREF(server)]
	if(!server_instance)
		return "not_relaying"
	if(!server.toggled || (server.machine_stat & (BROKEN|NOPOWER|EMPED)))
		relay_counters["offline"]++
		return "offline"
	var/list/payload = item["payload"]
	var/id = islist(payload) ? payload["id"] : null
	var/text = islist(payload) ? payload["text"] : null
	var/sender_name = islist(payload) ? payload["sender"] : null
	var/from = "pda.[item["producer"]]"
	if(!istext(id) || !istext(text) || !istext(sender_name) || !by_instance[from])
		return "invalid_message"
	var/list/targets = list()
	for(var/target in splittext(payload["to"], ","))
		if(findtext(target, "pda.") == 1 && length(target) <= 64 && !(target in targets))
			targets += target
	if(!length(targets) || length(targets) > NETDM_MESSENGER_FANOUT)
		return "invalid_recipients"
	var/seen = "[server_instance]/[id]"
	if(relayed[seen])
		return list("result" = list("id" = id, "state" = "queued", "recipients" = length(targets)))
	if(length(outbox) + length(targets) > NETDM_RELAY_OUTBOX)
		relay_counters["outbox_full"]++
		return list("result" = list("id" = id, "state" = "refused", "reason" = "busy"))
	relayed[seen] = world.time
	if(length(relayed) > NETDM_RELAY_SEEN)
		relayed.Cut(1, length(relayed) - NETDM_RELAY_SEEN / 2)
	// The log the message monitor reads, as the legacy server writes it.
	var/list/names = list()
	for(var/target in targets)
		var/datum/weakref/target_ref = by_instance[target]
		names += get_messenger_name(target_ref?.resolve()) || "Unknown"
	var/datum/weakref/sender_ref = by_instance[from]
	var/datum/computer_file/program/messenger/sender = sender_ref?.resolve()
	server.pda_msgs += new /datum/data_pda_msg(jointext(names, ", "), sender_name, text, null, xyz_coords(sender?.computer))
	server.trim_pda_msgs()
	relay_counters["logged"]++
	for(var/target in targets)
		outbox += list(list("kind" = "deliver", "server" = WEAKREF(server), "to" = target, "id" = id, "from" = from,
			"key" = "[id].[copytext(target, 5)]", "queued_rt" = REALTIMEOFDAY,
			"arguments" = list("id" = id, "text" = text, "sender" = sender_name, "from" = from)))
	pump_outbox() // Queued while the lane takes this reply, the deliveries leave in the same fire.
	return list("result" = list("id" = id, "state" = "queued", "recipients" = length(targets)))

/// The server sends what waits in its outbox while the lane takes commands.
/datum/netdm_messenger_shadow/proc/pump_outbox()
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	while(length(outbox))
		var/list/entry = outbox[1]
		var/datum/weakref/server_ref = entry["server"]
		var/obj/machinery/telecomms/message_server/server = server_ref.resolve()
		var/datum/component/netdm_node/node = server?.GetComponent(/datum/component/netdm_node)
		if(!node || REALTIMEOFDAY > entry["queued_rt"] + delivery_wait())
			outbox.Cut(1, 2)
			reasons["outbox_[node ? "expired" : "server_gone"]"]++
			continue
		var/is_delivery = entry["kind"] == "deliver"
		if(!lane.invoke(node, entry["to"], is_delivery ? "deliver" : "status", entry["key"], entry["arguments"],
			is_delivery ? CALLBACK(src, PROC_REF(delivery_accepted), entry) : null, is_delivery ? delivery_ttl_ticks : 50))
			return // The lane is full or the server's node is not attached yet: try on the next tick.
		outbox.Cut(1, 2)

/datum/netdm_messenger_shadow/proc/delivery_accepted(list/delivery, list/entry, list/reply)
	var/list/result = reply["result"]
	var/list/value = islist(result) ? result["value"] : null
	if(reply["ok"] && islist(value) && !isnull(value["operationId"]))
		delivery["sent_rt"] = REALTIMEOFDAY
		relaying["[value["operationId"]]"] = delivery
		return
	if(reply["error"] == "busy" && length(outbox) < NETDM_RELAY_OUTBOX)
		outbox.Insert(1, list(delivery)) // The server's endpoint runs as many operations as it may.
		return
	report_status(delivery, "unreachable", "host_[reply["error"] || "refused"]")

/// A recipient's receipt came back to the server.
/datum/netdm_messenger_shadow/proc/relay_receipt(obj/machinery/telecomms/message_server/server, list/item)
	var/list/delivery = relaying["[item["operationId"]]"]
	if(!delivery)
		return TRUE
	relaying -= "[item["operationId"]]"
	var/list/payload = item["payload"]
	var/state
	switch(islist(payload) ? payload["state"] : null)
		if("shown")
			state = "delivered"
		if("duplicate", "blocked", "disabled")
			state = payload["state"]
	report_status(delivery, state || "unreachable", state ? null : (item["reason"] || item["outcome"] || "no_result"))
	return TRUE

/// No receipt in time: the server asks the Host about its own delivery and reports the recipient unreachable.
/datum/netdm_messenger_shadow/proc/delivery_timed_out(operation, list/delivery)
	relaying -= operation
	var/datum/weakref/server_ref = delivery["server"]
	var/obj/machinery/telecomms/message_server/server = server_ref.resolve()
	var/datum/component/netdm_node/node = server?.GetComponent(/datum/component/netdm_node)
	if(!node || !SSnetdm_observe.services.query_command(node, operation, CALLBACK(src, PROC_REF(delivery_explained), delivery)))
		report_status(delivery, "unreachable", "no_receipt")

/datum/netdm_messenger_shadow/proc/delivery_explained(list/delivery, list/reply)
	var/list/result = reply["result"]
	var/list/value = islist(result) ? result["value"] : null
	report_status(delivery, "unreachable", islist(value) ? (value["outcomeReason"] || value["outcome"] || "no_receipt") : "no_receipt")

/datum/netdm_messenger_shadow/proc/report_status(list/delivery, state, reason)
	if(state == "unreachable")
		reasons["unreachable_[reason || "unknown"]"]++
	if(length(outbox) >= NETDM_RELAY_OUTBOX)
		relay_counters["outbox_full"]++
		return
	var/list/arguments = list("id" = delivery["id"], "recipient" = delivery["to"], "state" = state)
	if(reason)
		arguments["reason"] = copytext("[reason]", 1, 64)
	outbox += list(list("kind" = "status", "server" = delivery["server"], "to" = delivery["from"], "id" = delivery["id"],
		"key" = "[delivery["id"]].[copytext(delivery["to"], 5)].s", "queued_rt" = REALTIMEOFDAY, "arguments" = arguments))
	pump_outbox()

// ---- Recipient -------------------------------------------------------------------------------

/// The server's delivery reached the recipient: shown once per message ID through the legacy presentation.
/datum/netdm_messenger_shadow/proc/show(atom/computer, list/item)
	var/datum/computer_file/program/messenger/recipient = messenger_of(computer)
	var/list/payload = item["payload"]
	var/id = islist(payload) ? payload["id"] : null
	var/text = islist(payload) ? payload["text"] : null
	var/instance = item["instance"]
	if(!recipient || QDELETED(recipient.computer))
		return "receiver_gone"
	if(!istext(id) || !istext(text))
		return "invalid_message"
	var/key = "[id]/[instance]"
	if(shown[key])
		relay_counters["duplicates"]++
		return list("result" = list("id" = id, "state" = "duplicate"))
	if(!recipient.sending_and_receiving)
		return list("result" = list("id" = id, "state" = "disabled"))
	var/datum/weakref/sender_ref = by_instance[payload["from"]]
	var/datum/computer_file/program/messenger/sender = sender_ref?.resolve()
	var/sender_key = sender ? REF(sender) : null
	if(sender && !(sender_key in GLOB.pda_messengers))
		call(/proc/add_messenger)(sender) // A reply needs the sender in the contact list, as the legacy fallback does.
	var/fake_name = sender ? null : "[payload["sender"]]"
	var/datum/pda_chat/chat = recipient.find_chat_by_recipient(sender ? sender_key : fake_name, !sender)
	if(chat?.blocked)
		return list("result" = list("id" = id, "state" = "blocked"))
	shown[key] = world.time
	var/datum/signal/subspace/messaging/tablet_message/signal = new(sender?.computer || recipient.computer, list(
		"ref" = sender_key, "message" = text, "targets" = list(recipient), "rigged" = FALSE, "everyone" = FALSE,
		"photo" = null, "automated" = FALSE, "fakename" = fake_name, "fakejob" = null, "netdm_id" = id))
	recipient.receive_message(signal)
	relay_counters["shown"]++
	var/list/record = outgoing[id]
	if(record)
		push(arrivals, netdm_now_us() - record["sent_us"])
	return list("result" = list("id" = id, "state" = "shown"))

// ---- Timeouts --------------------------------------------------------------------------------

/datum/netdm_messenger_shadow/proc/relay_tick()
	if(length(outbox))
		pump_outbox()
	var/now = REALTIMEOFDAY
	for(var/operation in relaying)
		var/list/delivery = relaying[operation]
		if(now > delivery["sent_rt"] + delivery_wait())
			delivery_timed_out(operation, delivery)
	for(var/id in outgoing)
		var/list/record = outgoing[id]
		if(record["state"] == "relaying")
			if(record["status_deadline"])
				if(now > record["status_deadline"])
					relay_failed(record, "no_answer")
			else if(now > record["sent_rt"] + NETDM_RELAY_ANSWER)
				explain_relay(record)
		else if(record["state"] == "failed" || now > record["sent_rt"] + NETDM_RELAY_STATUS_WAIT)
			if(record["state"] == "queued")
				relay_counters["status_missing"] += length(record["names"]) - length(record["statuses"])
			outgoing -= id
	if(length(relayed) > NETDM_RELAY_SEEN)
		relayed.Cut(1, length(relayed) - NETDM_RELAY_SEEN / 2)

/datum/netdm_messenger_shadow/proc/relay_state()
	return "mode=[authoritative ? "authoritative" : "shadow"] servers=[length(servers)] relayed=[relay_counters["relayed"]] \
		queued=[relay_counters["queued"]] offline=[relay_counters["offline"]] no_answer=[relay_counters["no_answer"]] \
		refused=[relay_counters["refused"]] logged=[relay_counters["logged"]] shown=[relay_counters["shown"]] \
		delivered=[relay_counters["delivered"]] unreachable=[relay_counters["unreachable"]] blocked=[relay_counters["blocked"]] \
		disabled=[relay_counters["disabled"]] duplicates=[relay_counters["duplicates"]] legacy=[relay_counters["legacy"]] \
		status_missing=[relay_counters["status_missing"]] outbox=[length(outbox)] relaying=[length(relaying)] \
		answer_p95=[percentile_ms(relay_latencies, 0.95)]ms"

// ---- Handlers --------------------------------------------------------------------------------

/datum/netdm_command_handler/pda_relay/execute(datum/target, list/item)
	if(!SSnetdm_observe.messenger || !istype(target, /obj/machinery/telecomms/message_server))
		return "not_server"
	return SSnetdm_observe.messenger.relay_received(target, item)

/datum/netdm_effect_handler/pda_relay_answer/apply(datum/target, list/item)
	if(!SSnetdm_observe.messenger)
		return "no_messenger"
	return SSnetdm_observe.messenger.relay_answered(target, item)

/datum/netdm_command_handler/pda_status/execute(datum/target, list/item)
	if(!SSnetdm_observe.messenger?.messenger_of(target))
		return "no_messenger"
	return SSnetdm_observe.messenger.status_received(target, item)

/// The sender took the status; nothing more to do at the server.
/datum/netdm_effect_handler/pda_status_receipt/apply(datum/target, list/item)
	return TRUE

// ---- Hooks -----------------------------------------------------------------------------------

/// In authoritative mode an eligible message leaves through a message server instead of telecomms.
/datum/signal/subspace/messaging/tablet_message/send_to_receivers()
	var/datum/netdm_messenger_shadow/messenger = SSnetdm_observe.messenger
	// The absence of a network is not permission to use telecomms.
	if(!messenger)
		return
	switch(messenger.relay(src))
		if("sent")
			mark_done()
		if("failed")
			messenger.notify(messenger.current_sender, "ERROR: Network message could not be sent.")

#undef NETDM_RELAY_ANSWER
#undef NETDM_RELAY_STATUS_ANSWER
#undef NETDM_RELAY_STATUS_WAIT
#undef NETDM_RELAY_OUTBOX
#undef NETDM_RELAY_OUTGOING
#undef NETDM_RELAY_SEEN
