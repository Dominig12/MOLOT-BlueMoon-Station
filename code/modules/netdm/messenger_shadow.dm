/**
 * PDA messaging on the network (P7).
 *
 * Every computer with the messenger program becomes a mobile netDM node with the service `pda.<endpoint>`.
 * A message is taken by the relay on a message server and delivered to the recipient over the network; the
 * arrival is shown once per message ID. The legacy chain is no longer mirrored or compared: the network is
 * the delivery path, and a transmission it cannot take falls back to the physical one.
 */

/datum/netdm_messenger_shadow
	parent_type = /datum/netdm_integration
	/// Computer weakref -> messenger weakref; instance -> messenger weakref; messenger weakref -> instance.
	var/list/by_computer = list()
	var/list/by_instance = list()
	var/list/instances = list()
	/// The send in progress: its ID stamps the signal it builds, so receipts find it.
	var/current_id
	var/current_stamped = FALSE
	var/serial = 0
	/// "message/instance" -> TRUE: what a recipient already took over netDM; a repeat is never shown again.
	var/list/shown = list()
	/// Arrival latency at the recipient, microseconds.
	var/list/arrivals = list()
	/// Why a message did not arrive, for the diagnostics line.
	var/list/reasons = list()

/datum/netdm_messenger_shadow/setup(datum/netdm_service_lane/lane)
	lane.dispatcher.allow_command("pda.messenger", "deliver", new /datum/netdm_command_handler/pda_deliver)
	lane.dispatcher.allow_result("deliver", new /datum/netdm_effect_handler/pda_receipt, "pda.messenger")
	setup_relay(lane)

/datum/netdm_messenger_shadow/reset_session()
	// Nothing of the old session is left waiting for answers.
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
	if(!sent && !stamped)
		return // Refused before any signal: cooldown, no targets, a jammer, an unusable PDA.
	// The relay reports for itself; a message that fell back to the physical chain is counted, not mirrored.
	if(!relayed && sent)
		relay_counters["legacy"]++
/// The message reached the recipient: the relay shows it once per message ID.
/datum/netdm_messenger_shadow/proc/delivered(atom/computer, list/item)
	return show(computer, item)

/// A receipt came back. Message servers answer for themselves; nothing else is tracked here.
/datum/netdm_messenger_shadow/proc/receipt(atom/computer, list/item)
	if(istype(computer, /obj/machinery/telecomms/message_server))
		return relay_receipt(computer, item)
	return TRUE

// ---- Comparison ------------------------------------------------------------------------------

/datum/netdm_messenger_shadow/tick()
	relay_tick()
	// Presentation dedup lives as long as a retry could still arrive.
	if(length(shown) > 2048)
		shown.Cut(1, length(shown) - 1024)

/// Each recipient of a mirrored message: delivered by both, by one of them (with a reason), or by neither.
/datum/netdm_messenger_shadow/proc/push(list/samples, value)
	samples += value
	if(length(samples) > 256)
		samples.Cut(1, 2)

/datum/netdm_messenger_shadow/proc/percentile_ms(list/samples, fraction)
	if(!length(samples))
		return null
	var/list/sorted = sortTim(samples.Copy(), GLOBAL_PROC_REF(cmp_numeric_asc))
	return round(sorted[clamp(CEILING(length(sorted) * fraction, 1), 1, length(sorted))] / 1000, 0.1)

/datum/netdm_messenger_shadow/proc/state()
	var/list/reason_text = list()
	for(var/reason in reasons)
		reason_text += "[reason]:[reasons[reason]]"
	return "messenger pdas=[length(instances)] arrival_p50=[percentile_ms(arrivals, 0.5)]ms \
		arrival_p95=[percentile_ms(arrivals, 0.95)]ms reasons=[jointext(reason_text, ",")] [relay_state()]"

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

