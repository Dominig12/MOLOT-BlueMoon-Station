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
	// Transport updates must run even when the server has no spare background CPU.
	flags = SS_KEEP_TIMING

	var/datum/netdm_bridge/bridge
	// Auto-connect whenever the native DLL is deployed beside the game.
	// Manual disable_bridge() pauses further automatic attempts.
	var/auto_enable_bridge = TRUE
	var/next_bridge_attempt = 0
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
	// A live topology batch stays queued until Host acknowledges it.
	var/live_marker
	var/live_deadline = 0
	var/live_batch_count = 0
	var/sync_marker
	var/sync_stage = "idle"
	var/sync_index = 1
	var/sync_pending_count = 0
	var/sync_deadline = 0
	var/next_sync_retry = 0
	var/sync_dirty = FALSE
	var/list/sync_endpoints = list()
	var/list/sync_links = list()
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
	. = ..()
	// Do not attempt call_ext when the optional DLL has not been deployed.
	// Host can start later; the native worker reconnects by itself.
	if(auto_enable_bridge && fexists("netdm_byond.dll"))
		enable_bridge()
	return .

/datum/controller/subsystem/netdm/Destroy()
	disable_bridge()
	QDEL_NULL(bridge)
	return ..()

/datum/controller/subsystem/netdm/proc/enable_bridge()
	auto_enable_bridge = TRUE
	if(enabled)
		return TRUE
	if(!bridge)
		bridge = new
	if(!bridge.open())
		return FALSE
	known_lost_responses = 0
	enabled = TRUE
	return TRUE

/datum/controller/subsystem/netdm/proc/disable_bridge()
	auto_enable_bridge = FALSE
	if(!enabled)
		return
	fail_outstanding("bridge_disabled")
	bridge.close()
	enabled = FALSE
	connected = FALSE
	synchronized = FALSE
	synchronizing = FALSE
	topology_commands.Cut()
	live_marker = null
	live_batch_count = 0
	sync_marker = null
	sync_stage = "idle"
	sync_endpoints.Cut()
	sync_links.Cut()
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
	if(!connected || synchronizing)
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
	if(synchronizing)
		sync_dirty = TRUE
		return
	if(length(topology_commands) >= max_topology_queue)
		begin_sync()
		return
	topology_commands += list(command)

/datum/controller/subsystem/netdm/proc/begin_sync()
	if(!connected)
		return
	synchronized = FALSE
	synchronizing = TRUE
	sync_stage = "reset"
	sync_marker = null
	sync_index = 1
	sync_pending_count = 0
	sync_dirty = FALSE
	sync_deadline = 0
	next_sync_retry = 0
	topology_commands.Cut()
	live_marker = null
	live_batch_count = 0
	sync_endpoints = endpoints.Copy()
	sync_links = list()
	for(var/key in links)
		sync_links += links[key]
	fail_outstanding("topology_resync")

/datum/controller/subsystem/netdm/proc/sync_retry()
	live_marker = null
	live_batch_count = 0
	synchronized = FALSE
	synchronizing = FALSE
	sync_marker = null
	sync_stage = "idle"
	sync_endpoints.Cut()
	sync_links.Cut()
	next_sync_retry = world.time + 30

/datum/controller/subsystem/netdm/proc/advance_sync()
	if(!synchronizing || sync_marker)
		return
	var/list/changes = list()
	var/list/command
	var/list/source
	var/i
	switch(sync_stage)
		if("reset")
			command = list("op" = "game_reset")
		if("nodes", "radios")
			source = sync_endpoints
			if(sync_index > length(source))
				sync_stage = sync_stage == "nodes" ? "radios" : "links"
				sync_index = 1
				return
			for(i = sync_index, i <= length(source) && i < sync_index + 48, i++)
				var/datum/component/netdm_node/endpoint = source[i]
				if(!endpoint || !endpoint.node_id || QDELETED(endpoint))
					continue
				if(sync_stage == "nodes")
					var/turf/position = endpoint.get_position()
					if(position)
						changes += list(list("op" = "game_add_node", "a" = endpoint.node_id, "x" = position.x, "y" = position.y, "z" = position.z))
				else
					changes += list(list("op" = "game_radio", "a" = endpoint.node_id, "enabled" = endpoint.radio_enabled, "range" = endpoint.radio_range, "channel" = endpoint.radio_channel, "radioCost" = endpoint.radio_cost))
			sync_pending_count = i - sync_index
			if(!length(changes))
				sync_index += sync_pending_count
				return
			command = list("op" = sync_stage == "nodes" ? "game_batch" : "game_radio_batch", "changes" = changes)
		if("links")
			source = sync_links
			if(sync_index > length(source))
				sync_stage = "verify"
				return
			for(i = sync_index, i <= length(source) && i < sync_index + 48, i++)
				var/datum/netdm_link/link = source[i]
				if(link && endpoints_by_id["[link.from_id]"] && endpoints_by_id["[link.to_id]"])
					changes += list(list("op" = "game_connect", "a" = link.from_id, "b" = link.to_id, "cost" = link.cost))
			sync_pending_count = i - sync_index
			if(!length(changes))
				sync_index += sync_pending_count
				return
			command = list("op" = "game_batch", "changes" = changes)
		if("verify")
			command = list("op" = "game_stats")
		else
			return
	sync_marker = bridge.send(command)
	if(sync_marker)
		sync_deadline = world.time + 100

/datum/controller/subsystem/netdm/proc/flush_commands()
	if(!connected)
		return
	if(synchronizing)
		if(sync_marker && world.time > sync_deadline)
			sync_retry()
		else
			advance_sync()
		return
	if(!synchronized)
		if(world.time >= next_sync_retry)
			begin_sync()
		return
	if(live_marker)
		if(world.time > live_deadline)
			// The Host may have applied the update; replay only via a full
			// authoritative snapshot, not by blindly resending the command.
			begin_sync()
		return
	if(!length(topology_commands))
		return
	var/list/command = build_live_batch()
	if(!command)
		return
	var/id = bridge.send(command)
	if(id)
		live_marker = id
		live_deadline = world.time + 100

/// Preserve ordering of create/radio/link changes using two Host batch APIs.
/datum/controller/subsystem/netdm/proc/build_live_batch()
	if(!length(topology_commands))
		return null
	var/list/first = topology_commands[1]
	var/radio = first["op"] == "game_radio"
	var/list/changes = list()
	var/count = min(48, length(topology_commands))
	for(var/i = 1, i <= count, i++)
		var/list/change = topology_commands[i]
		if((change["op"] == "game_radio") != radio)
			break
		changes += list(change)
	live_batch_count = length(changes)
	if(!live_batch_count)
		return null
	return list("op" = radio ? "game_radio_batch" : "game_batch", "changes" = changes)

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
	live_marker = null
	live_batch_count = 0
	sync_stage = "idle"
	sync_endpoints.Cut()
	sync_links.Cut()
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
	if(sync_marker && message["id"] == sync_marker)
		sync_marker = null
		sync_deadline = 0
		if(!message["ok"])
			sync_retry()
			return
		if(sync_stage == "reset")
			sync_stage = "nodes"
			sync_index = 1
		else if(sync_stage == "nodes" || sync_stage == "radios" || sync_stage == "links")
			sync_index += sync_pending_count
		else if(sync_stage == "verify")
			if(sync_dirty)
				begin_sync()
			else
				synchronized = TRUE
				synchronizing = FALSE
				sync_stage = "idle"
				sync_endpoints.Cut()
				sync_links.Cut()
				retired_ids.Cut()
				var/list/game = message["game"]
				if(islist(game))
					stream_id = game["streamId"]
		return
	if(live_marker && message["id"] == live_marker)
		live_marker = null
		if(!message["ok"])
			begin_sync()
		else
			topology_commands.Cut(1, live_batch_count + 1)
		live_batch_count = 0
		return
	if(!isnull(message["id"]) && !message["ok"] && synchronized)
		begin_sync()
		return
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
	if(!enabled && auto_enable_bridge && world.time >= next_bridge_attempt)
		next_bridge_attempt = world.time + 100
		if(fexists("netdm_byond.dll"))
			enable_bridge()
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
	msg = "N:[length(endpoints)] L:[length(links)] Q:[length(topology_commands)] P:[length(transactions)] [!enabled ? "Disabled" : (connected ? (synchronized ? (live_marker ? "Applying" : "Ready") : "Sync") : "Offline")]"
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
