/// Time a mirrored message waits for its receipts before the comparison with the legacy delivery.
#define NETDM_MESSENGER_SETTLE (10 SECONDS)
/// Mirrored messages kept for comparison at once; the oldest is compared early beyond this.
#define NETDM_MESSENGER_SENDS 256

/**
 * pda.messenger pilot in Shadow mode (P7).
 *
 * Every computer with the messenger program becomes a mobile netDM node with the service
 * `pda.<endpoint>`. The legacy messenger keeps delivering through telecomms and the message server.
 * After a legacy send, each recipient also gets an addressed `deliver` command over the network with
 * a scalar message DTO: ID, sanitized text, sender display name and flags, never DM references.
 * The recipient records it once per message ID (a repeat is never shown twice) and answers with a
 * receipt, the result leg back to the sender. Each (message, recipient) is then compared: delivered by
 * legacy, by netDM, by both, and the reason when one side missed it.
 *
 * Compatibility exceptions, counted but not mirrored: photos (V1 has no attachment lifecycle), messages
 * to everyone and fanouts above NETDM_MESSENGER_FANOUT, rigged and automated messages, oversize text.
 * A legacy send that built its signal but failed ("Server is not responding") is still mirrored: it
 * shows what the network would deliver without a message server.
 */
/datum/netdm_messenger_shadow
	/// Computer weakref -> messenger weakref; instance -> messenger weakref.
	var/list/by_computer = list()
	var/list/by_instance = list()
	/// Messenger weakref -> its instance.
	var/list/instances = list()
	/// The legacy send in progress: its ID stamps the signal it builds, so receipts find it.
	var/current_id
	var/current_stamped = FALSE
	/// Message ID -> record, oldest first.
	var/list/sends = list()
	/// Operation ID -> list(message ID, target instance).
	var/list/operations = list()
	/// "message/instance" -> TRUE: what a recipient already took over netDM; a repeat is never shown again.
	var/list/shown = list()
	var/serial = 0
	/// Send -> receipt back at the sender (round trip), and send -> arrival at the recipient, microseconds.
	var/list/latencies = list()
	var/list/arrivals = list()
	var/list/counters = list("sent" = 0, "mirrored" = 0, "compared" = 0, "matched" = 0, "legacy_only" = 0, "netdm_only" = 0,
		"legacy_duplicates" = 0, "netdm_duplicates" = 0, "exceptions" = 0, "unmirrored" = 0)
	var/list/reasons = list()
	var/list/exceptions = list()
	var/list/notes = list()

/datum/netdm_messenger_shadow/proc/setup(datum/netdm_service_lane/lane)
	lane.dispatcher.allow_command("pda.messenger", "deliver", new /datum/netdm_command_handler/pda_deliver)
	lane.dispatcher.allow_result("deliver", new /datum/netdm_effect_handler/pda_receipt, "pda.messenger")
	setup_relay(lane)

/datum/netdm_messenger_shadow/proc/reset_session()
	// Receipts of the old session never arrive; those messages are compared with what arrived so far.
	operations.Cut()
	reset_relay_session()

/// A messenger program on a computer: the computer becomes a mobile node offering pda.<endpoint>.
/datum/netdm_messenger_shadow/proc/add_messenger(datum/computer_file/program/messenger/messenger)
	var/obj/item/modular_computer/computer = messenger.computer || messenger.holder?.holder
	if(!istype(computer) || QDELETED(computer) || instances[WEAKREF(messenger)])
		return
	var/datum/component/netdm_node/node = netdm_make_node(computer, NETDM_MOUNT_MOBILE, NETDM_NODE_RADIO_RANGE)
	var/datum/netdm_service_endpoint/endpoint = node ? SSnetdm_observe.services?.endpoint_for(node) : null
	if(!endpoint)
		return
	var/instance = "pda.[endpoint.id]"
	SSnetdm_observe.services.offer(node, instance, "pda.messenger", "pda.message", 1)
	instances[WEAKREF(messenger)] = instance
	by_instance[instance] = WEAKREF(messenger)
	by_computer[WEAKREF(computer)] = WEAKREF(messenger)

/// The messenger is gone; its node leaves with the computer, the lane drops the endpoint then.
/datum/netdm_messenger_shadow/proc/remove_messenger(datum/computer_file/program/messenger/messenger)
	var/datum/weakref/messenger_ref = WEAKREF(messenger)
	var/instance = instances[messenger_ref]
	if(!instance)
		return
	instances -= messenger_ref
	by_instance -= instance
	for(var/computer_ref in by_computer)
		if(by_computer[computer_ref] == messenger_ref)
			by_computer -= computer_ref
			break

/datum/netdm_messenger_shadow/proc/messenger_of(atom/computer)
	var/datum/weakref/messenger_ref = by_computer[WEAKREF(computer)]
	return messenger_ref?.resolve()

// ---- Legacy side -----------------------------------------------------------------------------

/// The record exists before the legacy send: telecomms delivers inside that call.
/datum/netdm_messenger_shadow/proc/begin_send(datum/computer_file/program/messenger/sender)
	current_id = "m-[++serial]-[copytext(md5("[world.time][rand()]"), 1, 7)]"
	current_stamped = FALSE
	current_sender = sender
	current_relayed = FALSE
	sends[current_id] = list("id" = current_id, "created" = world.time, "targets" = list(), "legacy" = list(), "netdm" = list(),
		"arrived" = list(), "states" = list(), "ops" = list(), "pending" = TRUE)
	return current_id

/// The signal of the legacy send carries the message ID; copies keep it.
/datum/netdm_messenger_shadow/proc/stamp(datum/signal/subspace/messaging/signal)
	if(current_id && !signal.data["netdm_id"])
		signal.data["netdm_id"] = current_id
		current_stamped = TRUE

/// The legacy send finished. A sent message, or one that failed only for want of a server, is mirrored.
/datum/netdm_messenger_shadow/proc/end_send(datum/computer_file/program/messenger/sender, id, sent, message, list/targets,
	photo_path, everyone, rigged, fake_name, fake_job)
	var/stamped = current_stamped
	var/relayed = current_relayed
	current_id = null
	current_stamped = FALSE
	current_sender = null
	current_relayed = FALSE
	var/list/record = sends[id]
	if(!sent && !stamped)
		sends -= id
		return // Refused before any signal: cooldown, no targets, a jammer, an unusable PDA.
	counters["sent"]++
	var/exception = rigged ? "rigged" : everyone ? "everyone" : photo_path ? "photo" : length(targets) > NETDM_MESSENGER_FANOUT ? "fanout" \
		: length(message) > NETDM_MESSENGER_TEXT ? "oversize" : null
	if(authoritative)
		// The server path reports for itself; a compatibility exception went through telecomms.
		sends -= id
		if(!relayed && sent)
			relay_counters["legacy"]++
			if(exception)
				exceptions[exception]++
		return
	var/instance = instances[WEAKREF(sender)]
	var/datum/component/netdm_node/node = sender.computer?.GetComponent(/datum/component/netdm_node)
	if(exception || !instance || !node || !record)
		sends -= id
		if(exception)
			counters["exceptions"]++
			exceptions[exception]++
		else
			counters["unmirrored"]++
		return
	record -= "pending"
	record["sender"] = instance
	record["queued_us"] = netdm_now_us()
	if(length(sends) > NETDM_MESSENGER_SENDS)
		compare(sends[sends[1]])
	var/sender_name = get_messenger_name(sender) || "Unknown"
	for(var/datum/computer_file/program/messenger/target as anything in targets)
		var/target_instance = instances[WEAKREF(target)]
		if(!target_instance)
			counters["unmirrored"]++
			continue
		record["targets"][target_instance] = TRUE
		var/list/entry = SSnetdm_observe.services.invoke(node, target_instance, "deliver", "[id].[copytext(target_instance, 5)]",
			list("id" = id, "text" = message, "sender" = copytext(sender_name, 1, 128), "photo" = FALSE),
			CALLBACK(src, PROC_REF(accepted), id, target_instance))
		if(!entry)
			record["states"][target_instance] = "not_sent"
	counters["mirrored"]++
	// A legacy failure is remembered: the recipients missed it on the radio path.
	if(stamped && !sent)
		record["legacy_failed"] = TRUE

/// A legacy delivery reached a messenger program; a second one for the same message is a legacy duplicate.
/datum/netdm_messenger_shadow/proc/legacy_received(datum/computer_file/program/messenger/recipient, datum/signal/subspace/messaging/signal)
	if(authoritative)
		return
	var/id = signal?.data["netdm_id"]
	var/list/record = id ? sends[id] : null
	var/instance = instances[WEAKREF(recipient)]
	if(!record || !instance)
		return
	if(record["legacy"][instance])
		counters["legacy_duplicates"]++
		note("legacy showed [id] twice to [instance]")
	record["legacy"][instance] = TRUE

// ---- netDM side ------------------------------------------------------------------------------

/datum/netdm_messenger_shadow/proc/accepted(id, target_instance, list/entry, list/reply)
	var/list/record = sends[id]
	if(!record)
		return
	var/list/result = reply["result"]
	var/list/value = islist(result) ? result["value"] : null
	if(reply["ok"] && islist(value) && !isnull(value["operationId"]))
		operations["[value["operationId"]]"] = list(id, target_instance)
		record["ops"] += list("[value["operationId"]]" = target_instance)
	else
		record["states"][target_instance] = "host_[reply["error"] || "refused"]"

/// The message reached the recipient's node. Shadow records it once per message ID and never shows it.
/datum/netdm_messenger_shadow/proc/delivered(atom/computer, list/item)
	if(authoritative)
		return show(computer, item)
	var/list/payload = item["payload"]
	var/id = islist(payload) ? payload["id"] : null
	var/instance = item["instance"]
	if(!istext(id))
		return "invalid_message"
	var/key = "[id]/[instance]"
	if(shown[key])
		counters["netdm_duplicates"]++
		return list("result" = list("id" = id, "state" = "duplicate"))
	shown[key] = world.time
	var/list/record = sends[id]
	if(record && !isnull(record["queued_us"]))
		record["arrived"][instance] = netdm_now_us() - record["queued_us"]
	return list("result" = list("id" = id, "state" = "recorded"))

/// The receipt came back to the sender over the network.
/datum/netdm_messenger_shadow/proc/receipt(atom/computer, list/item)
	if(istype(computer, /obj/machinery/telecomms/message_server))
		return relay_receipt(computer, item)
	var/list/link = operations["[item["operationId"]]"]
	if(!link)
		return TRUE
	operations -= "[item["operationId"]]"
	var/list/record = sends[link[1]]
	if(!record)
		return TRUE
	var/list/payload = item["payload"]
	var/state = islist(payload) ? payload["state"] : (item["outcome"] || "no_result")
	record["states"][link[2]] = state
	if(state == "recorded" || state == "shown" || state == "duplicate")
		record["netdm"][link[2]] = netdm_now_us() - record["queued_us"]
	return TRUE

// ---- Comparison ------------------------------------------------------------------------------

/datum/netdm_messenger_shadow/proc/tick()
	relay_tick()
	while(length(sends))
		var/list/record = sends[sends[1]]
		if(record["pending"] || world.time < record["created"] + NETDM_MESSENGER_SETTLE)
			break
		sends.Cut(1, 2)
		compare(record)
	// Presentation dedup lives as long as a retry could still arrive.
	if(length(shown) > 2048)
		shown.Cut(1, length(shown) - 1024)

/// Each recipient of a mirrored message: delivered by both, by one of them (with a reason), or by neither.
/datum/netdm_messenger_shadow/proc/compare(list/record)
	if(sends[record["id"]])
		sends -= record["id"]
	for(var/instance in record["targets"])
		counters["compared"]++
		var/legacy = record["legacy"][instance]
		var/netdm = !isnull(record["netdm"][instance])
		if(legacy && netdm)
			counters["matched"]++
			push(latencies, record["netdm"][instance])
			if(!isnull(record["arrived"][instance]))
				push(arrivals, record["arrived"][instance])
		else if(legacy)
			counters["legacy_only"]++
			explain(record, instance)
		else if(netdm)
			counters["netdm_only"]++
			var/reason = record["legacy_failed"] ? "legacy_server" : "legacy_missed"
			reasons[reason]++
			note("[record["id"]] -> [instance]: netDM delivered, legacy did not ([reason])")
		else
			reasons["neither"]++

/// Why netDM missed a recipient the radio reached: the receipt state, or the command's outcome from the Host.
/datum/netdm_messenger_shadow/proc/explain(list/record, instance)
	var/state = record["states"][instance]
	var/operation
	for(var/op in record["ops"])
		if(record["ops"][op] == instance)
			operation = op
	var/datum/weakref/sender_ref = by_instance[record["sender"]]
	var/datum/computer_file/program/messenger/sender = sender_ref?.resolve()
	var/datum/component/netdm_node/node = sender?.computer?.GetComponent(/datum/component/netdm_node)
	if(state || !operation || !node || !SSnetdm_observe.services.query_command(node, operation, CALLBACK(src, PROC_REF(explained), record["id"], instance)))
		reasons[state || "unanswered"]++
		note("[record["id"]] -> [instance]: legacy delivered, netDM [state || "unanswered"]")

/datum/netdm_messenger_shadow/proc/explained(id, instance, list/reply)
	var/list/result = reply["result"]
	var/list/value = islist(result) ? result["value"] : null
	var/reason = islist(value) ? (value["outcomeReason"] || value["outcome"]) : "status_[reply["error"]]"
	reasons[reason || "unknown"]++
	note("[id] -> [instance]: legacy delivered, netDM [reason]")

/datum/netdm_messenger_shadow/proc/push(list/samples, value)
	samples += value
	if(length(samples) > 256)
		samples.Cut(1, 2)

/datum/netdm_messenger_shadow/proc/note(text)
	notes += text
	if(length(notes) > 16)
		notes.Cut(1, 2)

/datum/netdm_messenger_shadow/proc/percentile_ms(list/samples, fraction)
	if(!length(samples))
		return null
	var/list/sorted = sortTim(samples.Copy(), GLOBAL_PROC_REF(cmp_numeric_asc))
	return round(sorted[clamp(CEILING(length(sorted) * fraction, 1), 1, length(sorted))] / 1000, 0.1)

/datum/netdm_messenger_shadow/proc/state()
	var/list/reason_text = list()
	for(var/reason in reasons)
		reason_text += "[reason]:[reasons[reason]]"
	var/list/exception_text = list()
	for(var/exception in exceptions)
		exception_text += "[exception]:[exceptions[exception]]"
	return "messenger pdas=[length(instances)] sent=[counters["sent"]] mirrored=[counters["mirrored"]] compared=[counters["compared"]] \
		matched=[counters["matched"]] legacy_only=[counters["legacy_only"]] netdm_only=[counters["netdm_only"]] \
		duplicates=[counters["legacy_duplicates"]]/[counters["netdm_duplicates"]] arrival_p50=[percentile_ms(arrivals, 0.5)]ms \
		arrival_p95=[percentile_ms(arrivals, 0.95)]ms receipt_p50=[percentile_ms(latencies, 0.5)]ms receipt_p95=[percentile_ms(latencies, 0.95)]ms \
		reasons=[jointext(reason_text, ",")] exceptions=[jointext(exception_text, ",")] [relay_state()]"

/datum/netdm_command_handler/pda_deliver/execute(datum/target, list/item)
	if(!SSnetdm_observe.messenger?.messenger_of(target))
		return "no_messenger"
	return SSnetdm_observe.messenger.delivered(target, item)

/datum/netdm_effect_handler/pda_receipt/apply(datum/target, list/item)
	if(!SSnetdm_observe.messenger)
		return "no_messenger"
	return SSnetdm_observe.messenger.receipt(target, item)

// ---- Hooks; without Observe they add nothing but a null check --------------------------------

// PDAs and tablets store their programs on the hard drive, which never calls on_install; a computer
// without a drive stores them directly and does. Running the program covers a drive installed later.
/obj/item/computer_hardware/hard_drive/store_file(datum/computer_file/F)
	. = ..()
	if(. && istype(F, /datum/computer_file/program/messenger))
		SSnetdm_observe.messenger?.add_messenger(F)

/datum/signal/subspace/messaging/New(init_source, init_data)
	. = ..()
	SSnetdm_observe.messenger?.stamp(src)

#undef NETDM_MESSENGER_SETTLE
#undef NETDM_MESSENGER_SENDS
