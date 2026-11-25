/// A transmission's speech stays this long, in real time, for receivers to take it.
#define NETDM_UPLINK_CONTEXT (5 SECONDS)
/// Speech contexts kept at once; the oldest is dropped beyond this.
#define NETDM_UPLINK_CONTEXTS 256
/// A radio whose endpoint is not attached yet waits this long before its transmission is lost.
#define NETDM_UPLINK_ATTACH (1 SECONDS)
/// How long the network may carry an uplink, in Host ticks: the legacy backup fires at 2 seconds.
#define NETDM_UPLINK_TTL_TICKS 20
/// Relays waiting for the tick budget at once; beyond this a relay runs at its arrival.
#define NETDM_UPLINK_RELAYS 64

/**
 * Radio speech, uplink over the network (P8, decided 12.11.2026).
 *
 * A speaker's radio no longer hands its subspace transmission to every receiver on the level at once.
 * It sends the command `uplink` over the network to each telecomms receiver that listens on the
 * frequency; a receiver it cannot reach never gets it. The speech itself (speaker, language, spans)
 * stays in DM as a presentation context, and only its ID and frequency travel (design §8.4). A
 * receiver that takes the uplink runs the legacy telecomms chain, and the broadcaster still reaches
 * every radio on its levels by subspace: hearing is unchanged, speaking needs the network.
 *
 * The legacy rules decide the rest: a receiver that is off, deaf to the frequency or on another level
 * ignores it; a signal already broadcast or already taken by another receiver is a duplicate; a signal
 * the legacy backup already sent as a mundane broadcast (two seconds without telecomms) is late and is
 * not relayed again. The receiver answers at arrival from the same guards; the legacy chain and its
 * broadcast, a walk over every radio on the frequency, run from a queue within the tick budget.
 */
/datum/netdm_radio_shadow
	/// NETDM_RADIO_MODE=authoritative, or set_authoritative() at runtime.
	var/authoritative = FALSE
	/// Receiver weakref -> its instance rx.<endpoint>, and back.
	var/list/rx_instances = list()
	var/list/rx_by_instance = list()
	/// Transmission ID -> speech context, oldest first.
	var/list/contexts = list()
	/// Transmission ID -> real time it waits for its radio's endpoint.
	var/list/waiting = list()
	var/list/uplink_counters = list("transmissions" = 0, "no_receiver" = 0, "sent" = 0, "lane_full" = 0, "unattached" = 0,
		"relayed" = 0, "ignored" = 0, "duplicate" = 0, "late" = 0, "expired" = 0, "heard" = 0, "lost" = 0, "receipts" = 0,
		"relay_dropped" = 0, "relay_refused" = 0, "relayed_unheard" = 0)
	/// Speech to receiver arrival, microseconds; and its parts: waiting to leave DM, and from leaving to arrival.
	var/list/uplink_latencies = list()
	var/list/uplink_waits = list()
	var/list/uplink_transits = list()
	/// Taken uplinks waiting to run the legacy chain: list(receiver weakref, transmission ID), oldest first.
	var/list/relays = list()
	/// "holder type f=frequency z=level" -> count of relayed transmissions that were never broadcast.
	var/list/unheard_sample = list()

/datum/netdm_radio_shadow/setup(datum/netdm_service_lane/lane)
	lane.dispatcher.allow_command("radio.receiver", "uplink", new /datum/netdm_command_handler/radio_uplink)
	lane.dispatcher.allow_result("uplink", new /datum/netdm_effect_handler/radio_uplink_receipt, "radio.receiver")
	if(world.GetConfig("env", "NETDM_RADIO_MODE") == "authoritative")
		set_authoritative(TRUE)

/datum/netdm_radio_shadow/proc/set_authoritative(enabled)
	authoritative = !!enabled
	if(!authoritative)
		return
	for(var/datum/weakref/receiver_ref as anything in receivers)
		offer_receiver(receiver_ref.resolve())

/// A receiver takes uplinks as the provider of rx.<endpoint>.
/datum/netdm_radio_shadow/proc/offer_receiver(obj/machinery/telecomms/receiver)
	if(!authoritative || QDELETED(receiver) || rx_instances[WEAKREF(receiver)])
		return
	var/datum/component/netdm_node/node = receiver.GetComponent(/datum/component/netdm_node)
	var/datum/netdm_service_endpoint/endpoint = node ? SSnetdm_observe.services?.endpoint_for(node) : null
	if(!endpoint)
		return
	var/instance = "rx.[endpoint.id]"
	SSnetdm_observe.services.offer(node, instance, "radio.receiver", "radio.uplink", 1)
	rx_instances[WEAKREF(receiver)] = instance
	rx_by_instance[instance] = WEAKREF(receiver)

/// The legacy send_to_receivers of a vocal signal. TRUE when the network took it over.
/datum/netdm_radio_shadow/proc/uplink(datum/signal/subspace/vocal/signal)
	var/obj/item/radio/source = signal.source
	var/id = signal.data["netdm_radio"]
	var/datum/component/netdm_node/node = istype(source) && radios[WEAKREF(source)] ? source.GetComponent(/datum/component/netdm_node) : null
	if(!id || !node)
		return FALSE // Machines and radios outside the network keep the legacy path.
	uplink_counters["transmissions"]++
	// The radio knows which receivers serve its frequency; whether one is on is the receiver's to say.
	var/list/targets = list()
	for(var/datum/weakref/receiver_ref as anything in rx_instances)
		var/obj/machinery/telecomms/receiver = receiver_ref.resolve()
		var/datum/component/netdm_node/receiver_node = receiver?.GetComponent(/datum/component/netdm_node)
		if(receiver_node && receiver.is_freq_listening(signal) && SSnetdm_observe.services.ready(receiver_node, rx_instances[receiver_ref]))
			targets += rx_instances[receiver_ref]
	if(!length(targets))
		uplink_counters["no_receiver"]++
		return TRUE // Nothing on the network serves this frequency; as with no receiver at all, nothing happens.
	contexts[id] = list("signal" = signal, "source" = WEAKREF(source), "created_rt" = REALTIMEOFDAY, "created_us" = netdm_now_us(),
		"targets" = targets, "states" = list())
	if(length(contexts) > NETDM_UPLINK_CONTEXTS)
		expire_context(contexts[1])
	var/datum/netdm_service_endpoint/endpoint = SSnetdm_observe.services.endpoint_for(node)
	if(endpoint?.attached_node)
		send_uplink(id)
	else
		waiting[id] = REALTIMEOFDAY // A radio's endpoint attaches on its first word.
	return TRUE

/datum/netdm_radio_shadow/proc/send_uplink(id)
	var/list/context = contexts[id]
	var/datum/weakref/source_ref = context?["source"]
	var/obj/item/radio/source = source_ref?.resolve()
	var/datum/component/netdm_node/node = source?.GetComponent(/datum/component/netdm_node)
	if(!node)
		return
	var/datum/signal/subspace/vocal/signal = context["signal"]
	var/list/entries = list()
	context["entries"] = entries
	for(var/target in context["targets"])
		var/list/entry = SSnetdm_observe.services.invoke(node, target, "uplink", "[id].[copytext(target, 4)]",
			list("id" = id, "frequency" = signal.frequency), null, NETDM_UPLINK_TTL_TICKS)
		if(entry)
			entries[target] = entry
			uplink_counters["sent"]++
		else
			uplink_counters["lane_full"]++
	SSnetdm_observe.services.flush_invokes()

/// The uplink reached a receiver: the legacy receiver decides, on the same signal legacy would hand it.
/datum/netdm_radio_shadow/proc/received_uplink(obj/machinery/telecomms/receiver, list/item)
	var/list/payload = item["payload"]
	var/id = islist(payload) ? payload["id"] : null
	var/list/context = istext(id) ? contexts[id] : null
	var/state
	if(!context)
		state = "expired"
	else
		var/datum/signal/subspace/vocal/signal = context["signal"]
		if(signal.transmission_method != TRANSMISSION_SUBSPACE)
			state = "late" // The legacy backup already broadcast it without telecomms.
		else if(signal.data["done"] || context["taken"])
			state = "duplicate"
		else if(!would_take(receiver, signal))
			state = "ignored"
		else
			state = "relayed"
			context["taken"] = TRUE
			if(length(relays) < NETDM_UPLINK_RELAYS)
				relays += list(list(WEAKREF(receiver), id))
			else
				relay(receiver, id)
		context["states"][item["instance"]] = state
		if(state == "relayed")
			var/now = netdm_now_us()
			push(uplink_latencies, now - context["created_us"])
			var/list/entry = context["entries"]?[item["instance"]]
			if(entry?["sent_us"])
				push(uplink_waits, entry["sent_us"] - context["created_us"])
				push(uplink_transits, now - entry["sent_us"])
	uplink_counters[state]++
	return list("result" = list("id" = "[id]", "state" = state))

/// The legacy receiver's own guards, without its side effects: on, listening, and on a level the signal reaches.
/datum/netdm_radio_shadow/proc/would_take(obj/machinery/telecomms/receiver, datum/signal/subspace/vocal/signal)
	if(!receiver.on || !receiver.is_freq_listening(signal))
		return FALSE
	if(istype(receiver, /obj/machinery/telecomms/allinone))
		var/obj/machinery/telecomms/allinone/mainframe = receiver
		return mainframe.intercept || (receiver.z in signal.levels) || (0 in signal.levels)
	var/obj/machinery/telecomms/receiver/dish = receiver
	return istype(dish) && dish.check_receive_level(signal)

/// The legacy chain runs on the signal the receiver took; a receiver that changed meanwhile is counted.
/datum/netdm_radio_shadow/proc/relay(obj/machinery/telecomms/receiver, id)
	var/list/context = contexts[id]
	var/datum/signal/subspace/vocal/signal = context?["signal"]
	if(QDELETED(receiver) || !signal || signal.data["done"] || signal.transmission_method != TRANSMISSION_SUBSPACE)
		uplink_counters["relay_dropped"]++
		return
	var/list/levels = signal.levels
	receiver.receive_signal(signal)
	if(!signal.data["done"] && signal.levels == levels)
		uplink_counters["relay_refused"]++

/datum/netdm_radio_shadow/proc/push(list/samples, value)
	samples += value
	if(length(samples) > 1024)
		samples.Cut(1, 2)

/datum/netdm_radio_shadow/proc/expire_context(id)
	var/list/context = contexts[id]
	contexts -= id
	waiting -= id
	if(!context)
		return
	var/relayed = FALSE
	for(var/instance in context["states"])
		if(context["states"][instance] == "relayed")
			relayed = TRUE
	if(!relayed && !context["heard"])
		uplink_counters["lost"]++
		reasons["uplink_lost"]++
	else if(relayed && !context["heard"])
		// Taken by a receiver but never broadcast by subspace: the legacy chain behind it did not finish.
		uplink_counters["relayed_unheard"]++
		// Which radios these are: the legacy chain behind the receiver decides, the source tells why.
		var/datum/weakref/source_ref = context["source"]
		var/obj/item/radio/source = source_ref?.resolve()
		var/datum/signal/subspace/vocal/signal = context["signal"]
		var/turf/position = get_turf(source)
		unheard_sample["[source?.loc?.type || source?.type] f=[signal?.frequency] z=[position?.z]"]++
		if(length(unheard_sample) > 8)
			unheard_sample.Cut(1, 2)

/datum/netdm_radio_shadow/proc/uplink_tick()
	while(length(relays) && !TICK_CHECK)
		var/list/next = relays[1]
		relays.Cut(1, 2)
		var/datum/weakref/receiver_ref = next[1]
		relay(receiver_ref.resolve(), next[2])
	var/now = REALTIMEOFDAY
	for(var/id in waiting)
		var/list/context = contexts[id]
		var/datum/weakref/source_ref = context?["source"]
		var/obj/item/radio/source = source_ref?.resolve()
		var/datum/component/netdm_node/node = source?.GetComponent(/datum/component/netdm_node)
		var/datum/netdm_service_endpoint/endpoint = node ? SSnetdm_observe.services.by_node[node] : null
		if(endpoint?.attached_node)
			waiting -= id
			send_uplink(id)
		else if(!context || now > waiting[id] + NETDM_UPLINK_ATTACH)
			waiting -= id
			uplink_counters["unattached"]++
	for(var/id in contexts)
		var/list/context = contexts[id]
		if(now <= context["created_rt"] + NETDM_UPLINK_CONTEXT)
			break
		expire_context(id)

/datum/netdm_radio_shadow/proc/uplink_percentile_ms(fraction, list/samples = uplink_latencies)
	if(!length(samples))
		return null
	var/list/sorted = sortTim(samples.Copy(), GLOBAL_PROC_REF(cmp_numeric_asc))
	return round(sorted[clamp(CEILING(length(sorted) * fraction, 1), 1, length(sorted))] / 1000, 0.1)

/datum/netdm_radio_shadow/proc/uplink_state()
	return "mode=[authoritative ? "authoritative" : "shadow"] receivers_offered=[length(rx_instances)] \
		uplinks=[uplink_counters["transmissions"]] sent=[uplink_counters["sent"]] relayed=[uplink_counters["relayed"]] \
		heard=[uplink_counters["heard"]] ignored=[uplink_counters["ignored"]] duplicate=[uplink_counters["duplicate"]] \
		late=[uplink_counters["late"]] expired=[uplink_counters["expired"]] lost=[uplink_counters["lost"]] \
		no_receiver=[uplink_counters["no_receiver"]] unattached=[uplink_counters["unattached"]] lane_full=[uplink_counters["lane_full"]] \
		relay_dropped=[uplink_counters["relay_dropped"]] relay_refused=[uplink_counters["relay_refused"]] relayed_unheard=[uplink_counters["relayed_unheard"]] unheard=[json_encode(unheard_sample)] \
		contexts=[length(contexts)] relays=[length(relays)] uplink_p50=[uplink_percentile_ms(0.5)]ms uplink_p95=[uplink_percentile_ms(0.95)]ms \
		wait_p95=[uplink_percentile_ms(0.95, uplink_waits)]ms transit_p50=[uplink_percentile_ms(0.5, uplink_transits)]ms \
		transit_p95=[uplink_percentile_ms(0.95, uplink_transits)]ms"

/datum/netdm_command_handler/radio_uplink/execute(datum/target, list/item)
	if(!SSnetdm_observe.radio || !istype(target, /obj/machinery/telecomms))
		return "not_receiver"
	return SSnetdm_observe.radio.received_uplink(target, item)

/datum/netdm_effect_handler/radio_uplink_receipt/apply(datum/target, list/item)
	SSnetdm_observe.radio?.uplink_counters["receipts"]++
	return TRUE

/// In authoritative mode a radio's subspace transmission reaches receivers over the network.
/datum/signal/subspace/vocal/send_to_receivers()
	// Non-subspace analogue transmission is not a network service.
	if(transmission_method != TRANSMISSION_SUBSPACE)
		return ..()
	var/datum/netdm_radio_shadow/radio = SSnetdm_observe.radio
	// Telecomms cannot deliver a subspace signal when the Host or endpoint is absent.
	// The uplink either enters the packet network or is lost.
	radio?.uplink(src)

#undef NETDM_UPLINK_CONTEXT
#undef NETDM_UPLINK_CONTEXTS
#undef NETDM_UPLINK_ATTACH
#undef NETDM_UPLINK_TTL_TICKS
#undef NETDM_UPLINK_RELAYS
