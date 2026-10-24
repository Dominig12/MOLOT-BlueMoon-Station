/// Telecomms keeps its link/frequency policy; each machine hop uses the shared transport.
/obj/machinery/netrun_machine_service_types()
	return ..() + list(/datum/netrun_machine_service/telecomms_origin)

/obj/item/radio/netrun_machine_service_types()
	return ..() + list(/datum/netrun_machine_service/telecomms_origin)

/obj/machinery/telecomms/netrun_machine_service_types()
	return ..() + list(/datum/netrun_machine_service/telecomms_relay)

/obj/machinery/telecomms/receiver/netrun_machine_service_types()
	return ..() + list(/datum/netrun_machine_service/telecomms_receiver)

/obj/machinery/telecomms/allinone/netrun_machine_service_types()
	return ..() + list(/datum/netrun_machine_service/telecomms_receiver)

/// A source-only endpoint does not accept remote operations.
/datum/netrun_machine_service/telecomms_origin
	service_id = "telecomms.origin"

/datum/netrun_machine_service/telecomms_origin/accepts(datum/netrun_machine_message/message)
	return FALSE

/datum/netrun_machine_service/telecomms_relay
	service_id = "telecomms.relay"

/datum/netrun_machine_service/telecomms_relay/accepts(datum/netrun_machine_message/message)
	var/obj/machinery/telecomms/machine = host
	var/datum/netrun_machine_message/telecomms/packet = message
	if(!istype(machine) || !machine.on || !istype(packet) || !packet.signal)
		return FALSE
	var/obj/machinery/telecomms/machine_from = packet.machine_from?.resolve()
	// Relinking while a packet is travelling revokes that logical connection.
	if(machine_from && !(machine in machine_from.links))
		return FALSE
	if(machine_from && machine_from.z != machine.z && !machine_from.long_range_link && !machine.long_range_link)
		return FALSE
	return TRUE

/datum/netrun_machine_service/telecomms_relay/receive(datum/netrun_machine_message/telecomms/message)
	if(!accepts(message))
		return FALSE
	var/obj/machinery/telecomms/machine = host
	machine.receive_information(message.signal, message.machine_from?.resolve())
	return TRUE

/datum/netrun_machine_service/telecomms_receiver
	service_id = "telecomms.receiver"

/datum/netrun_machine_service/telecomms_receiver/accepts(datum/netrun_machine_message/message)
	var/datum/netrun_machine_message/telecomms/packet = message
	var/obj/machinery/telecomms/machine = host
	if(!istype(packet) || !packet.signal || !istype(machine) || !machine.on)
		return FALSE
	var/datum/signal/subspace/signal = packet.signal
	if(signal.transmission_method != TRANSMISSION_SUBSPACE || !machine.is_freq_listening(signal))
		return FALSE
	if(istype(machine, /obj/machinery/telecomms/receiver))
		var/obj/machinery/telecomms/receiver/receiver = machine
		return receiver.check_receive_level(signal)
	if(istype(machine, /obj/machinery/telecomms/allinone))
		var/obj/machinery/telecomms/allinone/mainframe = machine
		return mainframe.intercept || (mainframe.z in signal.levels) || (0 in signal.levels)
	return FALSE

/datum/netrun_machine_service/telecomms_receiver/receive(datum/netrun_machine_message/telecomms/message)
	if(!accepts(message))
		return FALSE
	if(istype(host, /obj/machinery/telecomms/receiver))
		var/obj/machinery/telecomms/receiver/receiver = host
		receiver.receive_signal(message.signal)
	else
		var/obj/machinery/telecomms/allinone/mainframe = host
		mainframe.receive_signal(message.signal)
	return TRUE

/// Find an actual sending device, including a virtual PDA's explicitly proxied host.
/proc/netrun_telecomms_origin(atom/source)
	if(QDELETED(source))
		return
	if(istype(source, /obj/item/modular_computer))
		return source.get_netrun_machine_service("pda.messenger")
	if(istype(source, /obj/machinery/telecomms))
		return source.get_netrun_machine_service("telecomms.relay")
	if(ismob(source))
		if(istype(source, /mob/camera/netrun_entity))
			var/mob/camera/netrun_entity/entity = source
			return entity.messenger_pda?.get_netrun_machine_service("pda.messenger")
		for(var/obj/item/modular_computer/computer in source.GetAllContents(/obj/item/modular_computer))
			var/datum/netrun_machine_service/service = computer.get_netrun_machine_service("pda.messenger")
			if(service)
				return service
		for(var/obj/item/radio/radio in source.GetAllContents(/obj/item/radio))
			return radio.get_netrun_machine_service("telecomms.origin")
		return
	return source.get_netrun_machine_service("telecomms.origin")

/datum/signal/subspace
	/// Shared transaction state, never used to deliver across machines directly.
	var/datum/netrun_telecomms_transmission/netrun_transmission
	/// The most recent physical transmitter supplies the source of the final PDA hop.
	var/datum/weakref/netrun_transmitter

/// Each packet owns its signal snapshot. The original stays alive until all branches settle.
/proc/netrun_telecomms_snapshot(datum/signal/subspace/signal)
	var/datum/signal/subspace/snapshot = signal.copy()
	snapshot.data = deepCopyList(signal.data)
	snapshot.levels = signal.levels?.Copy()
	snapshot.frequency = signal.frequency
	snapshot.server_type = signal.server_type
	snapshot.transmission_method = signal.transmission_method
	snapshot.original = signal.netrun_transmission?.signal || signal.original || signal
	snapshot.netrun_transmission = signal.netrun_transmission
	snapshot.netrun_transmitter = signal.netrun_transmitter
	if(istype(signal, /datum/signal/subspace/pda))
		var/datum/signal/subspace/pda/pda_signal = signal
		var/datum/signal/subspace/pda/pda_snapshot = snapshot
		pda_snapshot.logged = pda_signal.logged
	return snapshot

/datum/netrun_machine_message/telecomms
	var/datum/signal/subspace/signal
	var/datum/weakref/machine_from
	var/datum/netrun_telecomms_transmission/transmission
	var/settled = FALSE

/datum/netrun_machine_message/telecomms/New(datum/signal/subspace/source_signal, obj/machinery/telecomms/from)
	..()
	if(source_signal)
		signal = netrun_telecomms_snapshot(source_signal)
		transmission = source_signal.netrun_transmission
		transmission?.retain_packet()
	if(from)
		machine_from = WEAKREF(from)

/datum/netrun_machine_message/telecomms/copy()
	var/datum/netrun_machine_message/telecomms/duplicate = ..()
	if(signal)
		duplicate.signal = netrun_telecomms_snapshot(signal)
	duplicate.machine_from = machine_from
	duplicate.transmission = transmission
	duplicate.transmission?.retain_packet()
	return duplicate

/datum/netrun_machine_message/telecomms/delivered(datum/netrun_machine_service/recipient)
	settle()

/datum/netrun_machine_message/telecomms/failed(reason)
	settle(reason)

/datum/netrun_machine_message/telecomms/proc/settle(reason)
	if(settled)
		return
	settled = TRUE
	transmission?.release_packet(reason)

/datum/netrun_machine_message/telecomms/Destroy()
	settle("Пакет отменён.")
	if(signal)
		signal.netrun_transmission = null
		QDEL_NULL(signal)
	transmission = null
	machine_from = null
	return ..()

/// Tracks outstanding branches so an admitted ingress is not mistaken for delivery.
/datum/netrun_telecomms_transmission
	var/datum/signal/subspace/signal
	var/pending_packets = 0
	var/dispatching = 0
	var/finished = FALSE
	var/failure_reason
	var/list/received_by = list()

/datum/netrun_telecomms_transmission/New(datum/signal/subspace/signal)
	src.signal = signal
	signal.netrun_transmission = src

/datum/netrun_telecomms_transmission/proc/retain_packet()
	pending_packets++

/datum/netrun_telecomms_transmission/proc/release_packet(reason)
	pending_packets = max(0, pending_packets - 1)
	if(reason)
		failure_reason = reason
	check_finished()

/datum/netrun_telecomms_transmission/proc/check_finished()
	if(finished || pending_packets || dispatching)
		return
	finished = TRUE
	complete()
	qdel(src)

/datum/netrun_telecomms_transmission/proc/complete()
	return

/datum/netrun_telecomms_transmission/Destroy()
	if(signal)
		signal.netrun_transmission = null
		signal = null
	received_by = null
	return ..()
