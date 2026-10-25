/// A delivery owns its metadata. Consoles retain bounded value snapshots, never live packets.
/datum/controller/subsystem/netrun
	var/packet_context_serial = 0

/datum/netrun_packet_context
	var/id
	var/operation_id
	var/nonce
	var/kind
	var/label
	var/from_address
	var/to_address
	var/service_id
	var/phase = "queued"
	var/reason
	var/started_at
	var/updated_at
	/// Replaced atomically; journal entries may share this immutable address snapshot.
	var/list/route = list()
	var/datum/weakref/console_ref
	var/sent = FALSE
	var/received = FALSE
	var/finished = FALSE

/datum/netrun_packet_context/New(kind, label, from_address, to_address, service_id, datum/netrun_console/console, nonce, operation_id)
	id = "packet-[++SSnetrun.packet_context_serial]"
	src.operation_id = istext(operation_id) ? copytext_char(operation_id, 1, 129) : id
	src.kind = istext(kind) ? copytext_char(kind, 1, 65) : "request"
	src.label = istext(label) ? copytext_char(label, 1, 129) : src.kind
	src.from_address = istext(from_address) ? copytext_char(from_address, 1, 129) : null
	src.to_address = istext(to_address) ? copytext_char(to_address, 1, 129) : null
	src.service_id = istext(service_id) ? copytext_char(service_id, 1, 129) : src.kind
	if(istext(nonce) && length(nonce) <= NETRUN_INPUT_ACK_MAX_LENGTH)
		src.nonce = nonce
	if(!QDELETED(console))
		console_ref = WEAKREF(console)
	started_at = world.time
	updated_at = world.time
	publish()

/datum/netrun_packet_context/Destroy()
	if(!finished)
		finish("cancelled", "Доставка отменена.")
	console_ref = null
	route = null
	return ..()

/datum/netrun_packet_context/proc/snapshot()
	return list("id" = id, "operation_id" = operation_id, "nonce" = nonce, "kind" = kind,
		"label" = label, "from" = from_address, "to" = to_address, "service" = service_id,
		"phase" = phase, "reason" = reason, "started_at" = started_at, "updated_at" = updated_at,
		"route" = route.Copy())

/datum/netrun_packet_context/proc/publish()
	updated_at = world.time
	var/datum/netrun_console/console = console_ref?.resolve()
	if(!QDELETED(console))
		console.record_operation(src)

/// Accept the two existing route representations without retaining the caller's lists.
/datum/netrun_packet_context/proc/set_route(list/hops)
	var/list/addresses = list()
	for(var/hop as anything in hops)
		var/address = hop
		if(islist(hop))
			var/list/entry = hop
			if(entry["kind"] && entry["kind"] != "node")
				continue
			address = entry["ref"]
		if(istext(address))
			addresses += address
	route = addresses

/datum/netrun_packet_context/proc/queued(list/hops)
	if(finished || sent)
		return FALSE
	sent = TRUE
	set_route(hops)
	if(!from_address && length(route))
		from_address = route[1]
	journal(from_address, "SEND")
	publish()
	return TRUE

/datum/netrun_packet_context/proc/running()
	if(finished)
		return FALSE
	phase = "running"
	publish()
	return TRUE

/// Only a freshly validated delivery path may produce forwarding records.
/datum/netrun_packet_context/proc/receive(list/hops)
	if(finished || received)
		return FALSE
	received = TRUE
	set_route(hops)
	for(var/i = 2; i < length(route); i++)
		journal(route[i], "FORWARD")
	journal(to_address, "RECEIVE")
	publish()
	return TRUE

/datum/netrun_packet_context/proc/journal(address, packet_phase, failure_reason)
	var/datum/component/netrun_node/node = SSnetrun.nodes_by_address[address]
	if(!QDELETED(node))
		node.add_packet_log(id, packet_phase, kind, from_address, to_address, service_id,
			failure_reason, operation_id, route)

/// A terminal outcome is immutable. Completion means handling, not a promised physical effect.
/datum/netrun_packet_context/proc/finish(outcome, failure_reason, at_address)
	if(finished || !(outcome in list("completed", "rejected", "cancelled")))
		return FALSE
	finished = TRUE
	phase = outcome
	reason = istext(failure_reason) ? copytext_char(failure_reason, 1, 513) : null
	if(outcome == "completed")
		journal(at_address || to_address || from_address, "ACCEPT")
	else if(outcome == "rejected")
		journal(at_address || (received ? to_address : from_address), "REJECT", reason)
	else if(sent)
		journal(at_address || from_address, "DROP", reason)
	publish()
	return TRUE

/datum/netrun_console
	var/list/operation_snapshots = list()

/datum/netrun_console/proc/record_operation(datum/netrun_packet_context/operation)
	if(QDELETED(src))
		return
	for(var/i = length(operation_snapshots); i >= 1; i--)
		var/list/previous = operation_snapshots[i]
		if(previous["id"] == operation.id)
			operation_snapshots.Cut(i, i + 1)
			break
	operation_snapshots += list(operation.snapshot())
	if(length(operation_snapshots) > 32)
		operation_snapshots.Cut(1, length(operation_snapshots) - 31)
	invalidate_ui()

/// operation_snapshots is an indexed list whose elements are themselves assoc lists.
/// deepCopyList() on such a container would treat each element-list as an associative
/// key (mapping it to null), turning the result into an assoc list that json_encode
/// then serializes as an object instead of an array. Copy each snapshot individually.
/datum/netrun_console/proc/operations_payload()
	var/list/payload = list()
	for(var/list/snapshot as anything in operation_snapshots)
		payload += list(deepCopyList(snapshot))
	return payload

/// Preflight failure has an operation result but never pretends to have crossed the network.
/datum/netrun_console/proc/reject_operation(datum/netrun_packet_context/operation, reason)
	operation?.finish("rejected", reason, operation.from_address)
	qdel(operation)
	return FALSE
