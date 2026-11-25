/// Radio transmissions waiting for the Host's answer at once; more are counted as unsampled.
#define NETDM_RADIO_PENDING 16
/// Transmissions sampled per second at most: radio chatter is never mirrored in full under load.
#define NETDM_RADIO_RATE 4
/// Questions to the Host in flight at once; the lane's control queue is shared with research.
#define NETDM_RADIO_INFLIGHT 4
/// A transmission not asked about within this long is dropped as unsampled.
#define NETDM_RADIO_STALE (5 SECONDS)
/// Listeners asked about per transmission at most (the Host's limit too).
#define NETDM_RADIO_TARGETS 1024
/// Duration of one Host transport tick, in milliseconds.
#define NETDM_RADIO_TICK_MS 100

/**
 * Radio speech in Shadow mode (P8).
 *
 * Every radio (headset, handheld, intercom) is a netDM node: intercoms are fixed and take a wire to
 * the APC of their zone, the rest are mobile and use radio. Telecomms receivers and broadcasters are
 * fixed nodes. Legacy speech keeps going through telecomms. For a sample of subspace transmissions the
 * pilot asks the Host which of the radios that legacy delivered to the network would reach: from the
 * speaker's radio to the nearest receiver, from it to the broadcasters, and from them to each listener,
 * as one analytic broadcast per leg (design §9.5). Each listener is matched or explained (no uplink, no
 * chain, no downlink, not a network node), and the Host's route gives the latency estimate and how many
 * radio cells one transmission would occupy. Nothing is transmitted and nobody hears anything new.
 *
 * Counted, not mirrored: the mundane backup broadcast of non-subspace radios, superspace (independent)
 * radios, and the syndicate-compatible extras of well-known channels.
 */
/datum/netdm_radio_shadow
	parent_type = /datum/netdm_integration
	/// Radio weakrefs that are network nodes, and the telecomms machines that are.
	var/list/radios = list()
	var/list/receivers = list()
	var/list/broadcasters = list()
	/// Transmission ID -> record, oldest first.
	var/list/pending = list()
	var/inflight = 0
	var/serial = 0
	var/second_start = 0
	var/sampled_this_second = 0
	var/list/counters = list("transmissions" = 0, "sampled" = 0, "unsampled" = 0, "asked" = 0, "answered" = 0,
		"listeners" = 0, "matched" = 0, "legacy_only" = 0, "unregistered" = 0, "exceptions" = 0, "cells" = 0, "reached" = 0)
	var/list/reasons = list()
	var/list/exceptions = list()
	/// Estimated end-to-end latency of matched listeners, milliseconds.
	var/list/latencies = list()
	var/list/notes = list()

/datum/netdm_radio_shadow/reset_session()
	// Answers of the old session never come; those transmissions are dropped.
	pending.Cut()
	inflight = 0

/datum/netdm_radio_shadow/proc/add_radio(obj/item/radio/radio)
	if(QDELETED(radio) || radios[WEAKREF(radio)])
		return
	var/mount = istype(radio, /obj/item/radio/intercom) ? NETDM_MOUNT_FIXED : NETDM_MOUNT_MOBILE
	if(netdm_make_node(radio, mount, NETDM_NODE_RADIO_RANGE))
		radios[WEAKREF(radio)] = TRUE

/// Receivers and broadcasters are the ends of the telecomms chain the network has to reach.
/datum/netdm_radio_shadow/proc/add_telecomms(obj/machinery/telecomms/machine)
	var/receives = istype(machine, /obj/machinery/telecomms/receiver) || istype(machine, /obj/machinery/telecomms/allinone)
	var/broadcasts = istype(machine, /obj/machinery/telecomms/broadcaster) || istype(machine, /obj/machinery/telecomms/allinone)
	if(!(receives || broadcasts) || QDELETED(machine) || !netdm_make_node(machine))
		return
	if(receives)
		receivers[WEAKREF(machine)] = TRUE
		offer_receiver(machine)
	if(broadcasts)
		broadcasters[WEAKREF(machine)] = TRUE

/datum/netdm_radio_shadow/proc/node_id(atom/movable/thing)
	var/datum/component/netdm_node/node = thing?.GetComponent(/datum/component/netdm_node)
	return node ? SSnetdm_observe.services?.node_id(node) : null

/// A vocal signal is created: copies through telecomms keep this ID, so broadcasts of one message merge.
/datum/netdm_radio_shadow/proc/stamp(datum/signal/subspace/vocal/signal)
	if(!signal.data["netdm_radio"])
		signal.data["netdm_radio"] = "r-[++serial]"

/// Legacy broadcast of a vocal signal: the radios it reaches become the listeners to compare.
/datum/netdm_radio_shadow/proc/legacy_broadcast(datum/signal/subspace/vocal/signal)
	var/id = signal.data["netdm_radio"]
	if(!id)
		return
	if(authoritative)
		// The uplink went over the network; the broadcast that follows is the legacy subspace one.
		var/list/context = contexts[id]
		if(context && !context["heard"] && signal.transmission_method == TRANSMISSION_SUBSPACE)
			context["heard"] = TRUE
			uplink_counters["heard"]++
		return
	var/list/record = pending[id]
	if(signal.transmission_method != TRANSMISSION_SUBSPACE)
		if(!record)
			counters["exceptions"]++
			exceptions[signal.transmission_method == TRANSMISSION_RADIO ? "backup" : "superspace"]++
		return
	if(!record)
		counters["transmissions"]++
		if(world.time >= second_start + 1 SECONDS)
			second_start = world.time
			sampled_this_second = 0
		var/obj/item/radio/source = signal.source
		if(!istype(source))
			counters["exceptions"]++
			exceptions["machine_source"]++
			return
		if(length(pending) >= NETDM_RADIO_PENDING || sampled_this_second >= NETDM_RADIO_RATE)
			counters["unsampled"]++
			return
		sampled_this_second++
		counters["sampled"]++
		record = list("id" = id, "source" = WEAKREF(source), "frequency" = signal.frequency, "created" = world.time,
			"listeners" = list(), "receivers" = list(), "asked" = FALSE)
		pending[id] = record
		var/list/listening = record["receivers"]
		for(var/datum/weakref/receiver_ref as anything in receivers)
			var/obj/machinery/telecomms/receiver/receiver = receiver_ref.resolve()
			if(receiver?.on && !(receiver.machine_stat & (BROKEN|NOPOWER|EMPED)) && receiver.is_freq_listening(signal))
				listening += receiver_ref
	// Each broadcaster's copy adds the radios on its levels, as the legacy broadcast selects them.
	var/list/listeners = record["listeners"]
	for(var/obj/item/radio/radio in GLOB.all_radios["[signal.frequency]"])
		if(radio.can_receive(signal.frequency, signal.levels) && (!length(GLOB.antag_training_z) || is_antag_training_atom(radio) == signal.from_antag_training))
			listeners[WEAKREF(radio)] = TRUE

/datum/netdm_radio_shadow/tick()
	uplink_tick()
	for(var/id in pending)
		var/list/record = pending[id]
		if(record["asked"])
			continue
		if(world.time > record["created"] + NETDM_RADIO_STALE)
			pending -= id
			counters["unsampled"]++
			continue
		// Every broadcaster of the message has run by the next tick.
		if(world.time <= record["created"] || inflight >= NETDM_RADIO_INFLIGHT)
			continue
		ask(record)

/datum/netdm_radio_shadow/proc/ask(list/record)
	var/datum/weakref/source_ref = record["source"]
	var/source = node_id(source_ref.resolve())
	var/list/targets = list()
	var/list/target_refs = list()
	for(var/datum/weakref/radio_ref as anything in record["listeners"])
		var/id = node_id(radio_ref.resolve())
		if(!id)
			counters["unregistered"]++
			continue
		if(length(targets) >= NETDM_RADIO_TARGETS)
			break
		targets += id
		target_refs += radio_ref
	counters["listeners"] += length(record["listeners"])
	if(!source)
		pending -= record["id"]
		counters["legacy_only"] += length(targets)
		reasons["source_unregistered"] += length(targets)
		return
	var/list/receiver_ids = list()
	for(var/datum/weakref/receiver_ref as anything in record["receivers"])
		var/id = node_id(receiver_ref.resolve())
		if(id)
			receiver_ids += id
	var/list/broadcaster_ids = list()
	for(var/datum/weakref/broadcaster_ref as anything in broadcasters)
		var/obj/machinery/telecomms/broadcaster = broadcaster_ref.resolve()
		var/id = broadcaster?.on && !(broadcaster.machine_stat & (BROKEN|NOPOWER|EMPED)) ? node_id(broadcaster) : null
		if(id)
			broadcaster_ids += id
	record["targets"] = target_refs
	record["asked"] = TRUE
	if(!SSnetdm_observe.services.control("radio_reach", list("source" = source, "receivers" = receiver_ids,
		"broadcasters" = broadcaster_ids, "targets" = targets), CALLBACK(src, PROC_REF(answered), record)))
		record["asked"] = FALSE
		return
	inflight++
	counters["asked"]++

/datum/netdm_radio_shadow/proc/answered(list/record, list/reply)
	inflight = max(0, inflight - 1)
	pending -= record["id"]
	var/list/result = reply["result"]
	if(!reply["ok"] || !islist(result))
		reasons["host_[reply["error"] || "error"]"]++
		return
	counters["answered"]++
	var/list/ticks = result["ticks"]
	var/list/targets = record["targets"]
	var/reason = result["reason"] || "no_downlink"
	for(var/i in 1 to length(targets))
		var/estimate = i <= length(ticks) ? ticks[i] : -1
		if(estimate >= 0)
			counters["matched"]++
			latencies += estimate * NETDM_RADIO_TICK_MS
			if(length(latencies) > 1024)
				latencies.Cut(1, 2)
		else
			counters["legacy_only"]++
			reasons[reason]++
	counters["cells"] += result["transmissions"]
	counters["reached"] += result["reached"]

/datum/netdm_radio_shadow/proc/percentile_ms(fraction)
	if(!length(latencies))
		return null
	var/list/sorted = sortTim(latencies.Copy(), GLOBAL_PROC_REF(cmp_numeric_asc))
	return sorted[clamp(CEILING(length(sorted) * fraction, 1), 1, length(sorted))]

/datum/netdm_radio_shadow/proc/state()
	var/list/reason_text = list()
	for(var/reason in reasons)
		reason_text += "[reason]:[reasons[reason]]"
	var/list/exception_text = list()
	for(var/exception in exceptions)
		exception_text += "[exception]:[exceptions[exception]]"
	return "radio nodes=[length(radios)] receivers=[length(receivers)] broadcasters=[length(broadcasters)] \
		transmissions=[counters["transmissions"]] sampled=[counters["sampled"]] unsampled=[counters["unsampled"]] \
		answered=[counters["answered"]] listeners=[counters["listeners"]] matched=[counters["matched"]] \
		legacy_only=[counters["legacy_only"]] unregistered=[counters["unregistered"]] cells=[counters["cells"]]/[counters["reached"]] \
		p50=[percentile_ms(0.5)]ms p95=[percentile_ms(0.95)]ms reasons=[jointext(reason_text, ",")] exceptions=[jointext(exception_text, ",")] \
		[uplink_state()]"

// ---- Hooks; without Observe they add nothing but a null check --------------------------------

/datum/signal/subspace/vocal/New(obj/source, frequency, atom/movable/virtualspeaker/speaker, datum/language/language, message, spans)
	. = ..()
	SSnetdm_observe.radio?.stamp(src)

/datum/signal/subspace/vocal/broadcast()
	SSnetdm_observe.radio?.legacy_broadcast(src)
	return ..()

#undef NETDM_RADIO_PENDING
#undef NETDM_RADIO_RATE
#undef NETDM_RADIO_INFLIGHT
#undef NETDM_RADIO_STALE
#undef NETDM_RADIO_TARGETS
#undef NETDM_RADIO_TICK_MS
