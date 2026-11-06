/**
 * NetDM subsystem. Fresh master-based architecture; unrelated to NTNet.
 * The external Win32 DLL is opt-in: call SSnetdm.enable_bridge() after
 * deploying netdm_byond.dll and starting the x64 NetDM.Host.
 *
 * BYOND retains all gameplay payloads and dispatches them only after
 * the external transport emits a Delivered receipt. No implicit retries.
 */
SUBSYSTEM_DEF(netdm)
	name = "NetDM Network"
	wait = 2
	flags = SS_BACKGROUND

	var/datum/netdm_bridge/bridge
	var/enabled = FALSE
	var/connected = FALSE
	var/synchronized = FALSE
	var/synchronizing = FALSE

	var/list/endpoints_by_id = list()
	var/list/datum/component/netdm_node/endpoints = list()
	var/next_endpoint_id = 1
	var/scan_index = 1
	var/list/links = list()
	/// Tombstones retain offline removals across a local pipe reconnect.
	var/list/retired_ids = list()

	var/list/topology_commands = list()
	var/sync_marker
	var/sync_errors = 0
	var/receipt_request
	var/receipt_cursor = 0
	var/stream_id
	var/next_poll = 0
	var/next_native_check = 0
	var/known_lost_responses = 0

	var/list/transactions = list()
	var/next_request_id = 0
	var/max_transactions = 512
	var/max_topology_queue = 4096

/datum/controller/subsystem/netdm/Initialize(start_timeofday)
	bridge = new
	return ..()

/datum/controller/subsystem/netdm/Destroy()
	disable_bridge()
	QDEL_NULL(bridge)
	return ..()

/datum/controller/subsystem/netdm/proc/enable_bridge()
	if(enabled)
		return TRUE
	if(!bridge)
		bridge = new
	if(!bridge.open())
		return FALSE
	enabled = TRUE
	return TRUE

/datum/controller/subsystem/netdm/proc/disable_bridge()
	if(!enabled)
		return
	fail_outstanding("bridge_disabled")
	bridge.close()
	enabled = FALSE
	connected = FALSE
	synchronized = FALSE
	synchronizing = FALSE
	topology_commands.Cut()
	sync_marker = null
	receipt_request = null

/datum/controller/subsystem/netdm/proc/register_endpoint(datum/component/netdm_node/endpoint)
	if(!endpoint || endpoint.node_id || QDELETED(endpoint))
		return FALSE
	var/turf/position = endpoint.get_position()
	if(!position)
		return FALSE
	// BYOND and JSON can represent these integer IDs without precision loss.
	if(next_endpoint_id >= 10000000)
		stack_trace("NetDM endpoint address space exhausted.")
		return FALSE
	var/id = next_endpoint_id++
	endpoint.node_id = id
	endpoint.last_x = position.x
	endpoint.last_y = position.y
	endpoint.last_z = position.z
	endpoints_by_id["[id]"] = endpoint
	endpoints += endpoint
	if(connected)
		queue_endpoint(endpoint)
	return TRUE

/datum/controller/subsystem/netdm/proc/unregister_endpoint(datum/component/netdm_node/endpoint)
	if(!endpoint || !endpoint.node_id)
		return
	var/id = endpoint.node_id
	for(var/key in links.Copy())
		var/datum/netdm_link/link = links[key]
		if(link && (link.from_id == id || link.to_id == id))
			remove_link(link)
	endpoints_by_id -= "[id]"
	endpoints -= endpoint
	retired_ids["[id]"] = id
	if(connected)
		queue_topology(list("op" = "game_remove_node", "a" = id))
	endpoint.node_id = 0
	scan_index = 1

/datum/controller/subsystem/netdm/proc/update_endpoint_position(datum/component/netdm_node/endpoint)
	if(!connected || !endpoint?.node_id)
		return
	queue_topology(list("op" = "game_move_node", "a" = endpoint.node_id,
		"x" = endpoint.last_x, "y" = endpoint.last_y, "z" = endpoint.last_z))

/datum/controller/subsystem/netdm/proc/update_endpoint_radio(datum/component/netdm_node/endpoint)
	if(connected && endpoint?.node_id)
		queue_radio(endpoint)

/datum/controller/subsystem/netdm/proc/link_key(a, b)
	return "[min(a, b)]:[max(a, b)]"

/datum/controller/subsystem/netdm/proc/connect_nodes(datum/component/netdm_node/a,
	datum/component/netdm_node/b, cost = 1)
	if(!a || !b || a == b || !a.node_id || !b.node_id)
		return FALSE
	var/key = link_key(a.node_id, b.node_id)
	if(links[key])
		return TRUE
	var/datum/netdm_link/link = new(a.node_id, b.node_id, max(1, round(cost)))
	links[key] = link
	if(connected)
		queue_topology(list("op" = "game_connect",
			"a" = link.from_id, "b" = link.to_id, "cost" = link.cost))
	return TRUE

/datum/controller/subsystem/netdm/proc/disconnect_nodes(datum/component/netdm_node/a,
	datum/component/netdm_node/b)
	if(!a || !b || !a.node_id || !b.node_id)
		return FALSE
	var/datum/netdm_link/link = links[link_key(a.node_id, b.node_id)]
	if(!link)
		return FALSE
	remove_link(link)
	return TRUE

/datum/controller/subsystem/netdm/proc/remove_link(datum/netdm_link/link)
	links -= link_key(link.from_id, link.to_id)
	if(connected)
		queue_topology(list("op" = "game_disconnect",
			"a" = link.from_id, "b" = link.to_id))
	qdel(link)

/datum/controller/subsystem/netdm/proc/queue_endpoint(datum/component/netdm_node/endpoint)
	if(!endpoint?.node_id)
		return
	var/turf/position = endpoint.get_position()
	if(!position)
		return
	endpoint.last_x = position.x
	endpoint.last_y = position.y
	endpoint.last_z = position.z
	queue_topology(list("op" = "game_add_node", "a" = endpoint.node_id,
		"x" = position.x, "y" = position.y, "z" = position.z))
	queue_radio(endpoint)

/datum/controller/subsystem/netdm/proc/queue_radio(datum/component/netdm_node/endpoint)
	queue_topology(list("op" = "game_radio", "a" = endpoint.node_id,
		"enabled" = endpoint.radio_enabled, "range" = endpoint.radio_range,
		"channel" = endpoint.radio_channel, "radioCost" = endpoint.radio_cost))

/datum/controller/subsystem/netdm/proc/queue_topology(list/command)
	if(!connected || !islist(command))
		return
	if(length(topology_commands) >= max_topology_queue)
		synchronized = FALSE
		synchronizing = FALSE
		topology_commands.Cut()
		sync_marker = null
		stack_trace("NetDM topology queue overflow. Manual resync is required.")
		return
	topology_commands += list(command)

/datum/controller/subsystem/netdm/proc/begin_sync()
	if(!connected)
		return
	synchronized = FALSE
	synchronizing = TRUE
	sync_marker = null
	sync_errors = 0
	topology_commands.Cut()
	// Remove every node we deleted during an offline interval before adds.
	for(var/key in retired_ids)
		queue_topology(list("op" = "game_remove_node", "a" = retired_ids[key]))
	for(var/datum/component/netdm_node/endpoint as anything in endpoints)
		if(!QDELETED(endpoint))
			queue_endpoint(endpoint)
	for(var/key in links)
		var/datum/netdm_link/link = links[key]
		queue_topology(list("op" = "game_connect", "a" = link.from_id,
			"b" = link.to_id, "cost" = link.cost))

/datum/controller/subsystem/netdm/proc/flush_commands()
	if(!connected)
		return
	var/count = min(32, length(topology_commands))
	for(var/i = 1, i <= count, i++)
		var/list/command = topology_commands[1]
		if(!bridge.send(command))
			break
		topology_commands.Cut(1, 2)
	if(synchronizing && !length(topology_commands) && !sync_marker)
		sync_marker = bridge.send(list("op" = "game_stats"))

/datum/controller/subsystem/netdm/proc/fail_outstanding(reason)
	for(var/request_id in transactions.Copy())
		var/datum/netdm_transaction/transaction = transactions[request_id]
		transactions -= request_id
		if(transaction)
			transaction.finish("unknown", reason)

/datum/controller/subsystem/netdm/proc/on_connected()
	connected = TRUE
	receipt_cursor = 0
	stream_id = null
	receipt_request = null
	fail_outstanding("connection_reset")
	begin_sync()

/datum/controller/subsystem/netdm/proc/on_disconnected()
	connected = FALSE
	synchronized = FALSE
	synchronizing = FALSE
	receipt_request = null
	sync_marker = null
	topology_commands.Cut()
	fail_outstanding("connection_lost")

/datum/controller/subsystem/netdm/proc/handle_submission(list/submission)
	var/request_id = submission["requestId"]
	var/datum/netdm_transaction/transaction = transactions[request_id]
	if(!transaction)
		return
	if(!submission["accepted"])
		transactions -= request_id
		transaction.finish("rejected", "host_rejection_[submission["rejection"]]")
		return
	if(stream_id && submission["streamId"] != stream_id)
		fail_outstanding("stream_changed")
		stream_id = submission["streamId"]
		return
	stream_id = submission["streamId"]
	transaction.packet_id = submission["packetId"]
	transaction.state = "accepted"

/datum/controller/subsystem/netdm/proc/handle_receipts(list/page)
	if(stream_id && stream_id != page["streamId"])
		fail_outstanding("stream_changed")
		receipt_cursor = 0
		stream_id = page["streamId"]
		return
	stream_id = page["streamId"]
	if(page["gap"])
		fail_outstanding("receipt_gap")
	var/list/receipts = page["receipts"]
	if(islist(receipts))
		for(var/list/receipt in receipts)
			var/datum/netdm_transaction/transaction = transactions[receipt["requestId"]]
			if(!transaction)
				continue
			if(transaction.packet_id && transaction.packet_id != receipt["packetId"])
				continue
			transactions -= transaction.request_id
			if(receipt["status"] == 0)
				transaction.deliver()
			else
				transaction.finish("failed", "transport_[receipt["status"]]_[receipt["reason"]]")
	receipt_cursor = page["nextSequence"]

/datum/controller/subsystem/netdm/proc/handle_message(list/message)
	switch(message["bridge"])
		if("connected")
			on_connected()
			return
		if("disconnected")
			on_disconnected()
			return
	if(message["id"] == sync_marker && sync_marker)
		sync_marker = null
		synchronizing = FALSE
		synchronized = !!message["ok"] && !sync_errors
		if(synchronized)
			var/list/game = message["game"]
			if(islist(game))
				stream_id = game["streamId"]
	else if(synchronizing && !message["ok"] && !isnull(message["id"]))
		sync_errors++
	if(message["id"] == receipt_request)
		receipt_request = null
	if(message["error"] == "stream_changed")
		fail_outstanding("stream_changed")
		synchronized = FALSE
		begin_sync()
		return
	var/list/submission = message["submission"]
	if(islist(submission))
		handle_submission(submission)
	var/list/page = message["receiptPage"]
	if(islist(page))
		handle_receipts(page)

/datum/controller/subsystem/netdm/proc/send_payload(datum/component/netdm_node/sender,
	datum/component/netdm_node/recipient, list/payload, bytes = 96,
	interactive = TRUE, timeout_ticks = 30)
	if(!enabled || !connected || !synchronized)
		return null
	if(!sender?.node_id || !recipient?.node_id)
		return null
	if(!islist(payload) || length(transactions) >= max_transactions)
		return null
	bytes = round(bytes)
	timeout_ticks = round(timeout_ticks)
	if(bytes < 1 || bytes > 1000000 || timeout_ticks < 1 || timeout_ticks > 900)
		return null
	next_request_id++
	var/request_id = "ss13-[world.realtime]-[next_request_id]"
	var/datum/netdm_transaction/transaction = new(request_id, sender, recipient,
		payload.Copy(), world.time + max(200, timeout_ticks * 3))
	if(!bridge.send(list("op" = "packet_send", "a" = sender.node_id,
		"b" = recipient.node_id, "requestId" = request_id, "bytes" = bytes,
		"trafficClass" = !!interactive, "timeoutTicks" = timeout_ticks)))
		qdel(transaction)
		return null
	transactions[request_id] = transaction
	return transaction

/datum/controller/subsystem/netdm/fire(resumed = FALSE)
	if(!enabled || !bridge)
		return
	for(var/list/message as anything in bridge.read(64))
		handle_message(message)
	if(world.time >= next_native_check)
		next_native_check = world.time + 10
		var/list/status = bridge.status()
		if(islist(status) && status["lostResponses"] > known_lost_responses)
			known_lost_responses = status["lostResponses"]
			fail_outstanding("native_mailbox_overflow")
			synchronized = FALSE
			if(connected)
				begin_sync()
	if(!connected)
		return
	flush_commands()
	if(!synchronized)
		return
	if(world.time >= next_poll && !receipt_request)
		receipt_request = bridge.send(list("op" = "packet_receipts",
			"afterSequence" = receipt_cursor, "limit" = 128, "streamId" = stream_id))
		next_poll = world.time + 2
	var/count = min(32, length(endpoints))
	for(var/i = 1, i <= count, i++)
		if(scan_index > length(endpoints))
			scan_index = 1
		var/datum/component/netdm_node/endpoint = endpoints[scan_index++]
		if(endpoint && !QDELETED(endpoint))
			endpoint.sync_position()
	for(var/request_id in transactions.Copy())
		var/datum/netdm_transaction/transaction = transactions[request_id]
		if(transaction && world.time >= transaction.deadline)
			transactions -= request_id
			transaction.finish("unknown", "dm_wait_timeout")
			CHECK_TICK

/datum/controller/subsystem/netdm/stat_entry(msg)
	msg = "N:[length(endpoints)] L:[length(links)] P:[length(transactions)] [connected ? (synchronized ? "Ready" : "Sync") : "Offline"]"
	return ..()

/datum/netdm_link
	var/from_id
	var/to_id
	var/cost

/datum/netdm_link/New(from_id, to_id, cost)
	. = ..()
	src.from_id = from_id
	src.to_id = to_id
	src.cost = cost

/datum/netdm_transaction
	var/request_id
	var/datum/component/netdm_node/sender
	var/datum/component/netdm_node/recipient
	var/list/payload
	var/packet_id = 0
	var/state = "submitted"
	var/deadline

/datum/netdm_transaction/New(request_id, datum/component/netdm_node/sender,
	datum/component/netdm_node/recipient, list/payload, deadline)
	. = ..()
	src.request_id = request_id
	src.sender = sender
	src.recipient = recipient
	src.payload = payload
	src.deadline = deadline

/datum/netdm_transaction/proc/deliver()
	if(state == "delivered" || state == "unknown" || state == "failed" || state == "rejected")
		return
	var/datum/source_object = sender?.parent
	var/datum/target_object = recipient?.parent
	if(!target_object || QDELETED(target_object))
		finish("failed", "recipient_deleted")
		return
	state = "delivered"
	var/id = request_id
	var/list/data = payload
	var/datum/component/netdm_node/origin = sender
	spawn(0)
		if(target_object && !QDELETED(target_object))
			target_object.netdm_receive(data, origin, id)
		if(source_object && !QDELETED(source_object))
			source_object.netdm_delivery(id, "delivered", "transport_delivered")
	qdel(src)

/datum/netdm_transaction/proc/finish(final_status, reason)
	if(state == "delivered" || state == "unknown" || state == "failed" || state == "rejected")
		return
	state = final_status
	var/datum/source_object = sender?.parent
	var/id = request_id
	spawn(0)
		if(source_object && !QDELETED(source_object))
			source_object.netdm_delivery(id, final_status, reason)
	qdel(src)
