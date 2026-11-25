/**
 * Radio speech on the network.
 *
 * Every radio (headset, handheld, intercom) is a netDM node: intercoms are fixed and take a wire to the APC of
 * their zone, the rest are mobile and use radio. Telecomms receivers and broadcasters are fixed nodes. A
 * transmission now travels the network to the receivers that serve its frequency, and the legacy subspace
 * broadcast follows it as the physical delivery (INT-002). Speech that no receiver on the network serves is
 * handed back to the physical chain instead of being swallowed.
 */
/datum/netdm_radio_shadow
	parent_type = /datum/netdm_integration
	/// Radio weakrefs that are network nodes, and the telecomms machines that are.
	var/list/radios = list()
	var/list/receivers = list()
	var/list/broadcasters = list()
	/// Transmission identity, so copies through telecomms merge into one message.
	var/serial = 0
	/// Why an uplink did not arrive, for the diagnostics line.
	var/list/reasons = list()

/datum/netdm_radio_shadow/reset_session()
	// The old session is gone; nothing is left waiting for its answers.
	return

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
	if(!id || !contexts[id])
		return
	// The uplink went over the network; the broadcast that follows is the legacy subspace one, and it is
	// counted so a transmission that reached a receiver but no listener stays visible.
	var/list/context = contexts[id]
	if(!context["heard"] && signal.transmission_method == TRANSMISSION_SUBSPACE)
		context["heard"] = TRUE
		uplink_counters["heard"]++

/datum/netdm_radio_shadow/tick()
	uplink_tick()


/datum/netdm_radio_shadow/proc/state()
	return "radio nodes=[length(radios)] receivers=[length(receivers)] broadcasters=[length(broadcasters)] [uplink_state()]"
// ---- Hooks; without Observe they add nothing but a null check --------------------------------

/datum/signal/subspace/vocal/New(obj/source, frequency, atom/movable/virtualspeaker/speaker, datum/language/language, message, spans)
	. = ..()
	SSnetdm_observe.radio?.stamp(src)

/datum/signal/subspace/vocal/broadcast()
	SSnetdm_observe.radio?.legacy_broadcast(src)
	return ..()


