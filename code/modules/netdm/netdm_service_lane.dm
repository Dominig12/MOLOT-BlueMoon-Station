/// Requests of the service lane that may wait for a reply at once. The ACK and the inbox poll go first,
/// so the budget leaves room for a station's sensors reporting in the same tick: with 4, the last of
/// nine publications waited three more fires (Box Station p95 550 ms against 250-350 ms).
#define NETDM_LANE_INFLIGHT 16
/// Inbox poll cadence while nothing was sent lately; right after a publish or command the
/// inbox is polled every fire, so a delivery does not wait for the idle cadence.
#define NETDM_LANE_POLL (1 SECONDS)
#define NETDM_LANE_HOT (3 SECONDS)
/// Real time a service request may wait for its reply before a new session.
#define NETDM_LANE_TIMEOUT (20 SECONDS)
/// Retry delay of a subscription whose provider is not registered yet; it doubles up to the cap,
/// so a console listing a sensor that the map does not have stops asking every few seconds.
#define NETDM_LANE_SUBSCRIBE_RETRY (5 SECONDS)
#define NETDM_LANE_SUBSCRIBE_RETRY_MAX (60 SECONDS)
#define NETDM_LANE_ACK_BATCH 64
/// Delivery status queries waiting to be sent at most.
#define NETDM_LANE_QUERIES 16
/// What one reconcile step did: sent a request, found nothing to do, or must look again later.
#define NETDM_LANE_SETTLED 0
#define NETDM_LANE_SENT 1
#define NETDM_LANE_WAIT 2

/// One service endpoint on a netDM node. The ID lives for the round; what the Host acknowledged
/// lives for one session and is rebuilt after every new snapshot.
/datum/netdm_service_endpoint
	var/domain = "station"
	var/id
	var/generation = 1
	var/datum/node
	/// instance -> list("type", "schema", "major", "minor")
	var/list/services = list()
	/// key -> list("instance", "schema", "major", "projection")
	var/list/subscriptions = list()
	/// Node wire ID the endpoint is attached to in this session.
	var/attached_node
	var/list/registered = list()
	var/list/subscribed = list()
	/// Subscriptions explicitly confirmed by the shell (key -> TRUE).
	/// Kept across Host sessions; only these unknown-schema events enter the generic UI journal.
	var/list/event_watches = list()
	/// Recent delivered events for this endpoint alone; never a station-wide feed.
	var/list/event_journal = list()
	var/list/terminal_listeners = list()
	/// Refused for good in this session: instance or key -> Host reason.
	var/list/refused = list()
	/// key -> world.time before which a refused-for-now subscription is not retried.
	var/list/retry_at = list()
	/// key -> current retry delay of that subscription.
	var/list/retry_delay = list()
	/// Instance or key -> world.time the request that the Host accepted was sent in this session.
	/// A publication sent before a subscription was not counted for that subscriber.
	var/list/acknowledged_at = list()
	/// Request in flight for this endpoint: one at a time keeps attach, register and subscribe in order.
	var/busy


/// Opt-in UI capture: a wire event has already reached this endpoint and passed Host authorization.
/// No command handler or game effect may be invoked from its payload.
/datum/netdm_service_endpoint/proc/capture_event(list/item)
	var/key = item?["subscriptionKey"]
	if(!istext(key) || !event_watches[key] || !islist(item["payload"]))
		return FALSE
	var/encoded = json_encode(item["payload"])
	var/cut = length_char(encoded) > 1200
	var/list/event = list("delivery" = "[item["deliveryId"]]", "key" = key,
		"instance" = "[item["instance"]]", "schema" = "[item["schema"]]",
		"payload" = cut ? copytext_char(encoded, 1, 1201) : encoded,
		"truncated" = cut, "at" = world.time)
	event_journal += list(event)
	if(length(event_journal) > 32)
		event_journal.Cut(1, length(event_journal) - 32 + 1)
	// Weak references do not keep a closed terminal alive; stale ones are removed.
	for(var/datum/weakref/observer as anything in terminal_listeners.Copy())
		var/datum/netdm_terminal/terminal = observer?.resolve()
		if(QDELETED(terminal))
			terminal_listeners -= observer
		else
			SStgui.update_uis(terminal)
	return TRUE

/datum/netdm_service_endpoint/proc/observe_terminal(datum/netdm_terminal/terminal)
	if(QDELETED(terminal))
		return
	for(var/datum/weakref/observer as anything in terminal_listeners.Copy())
		if(QDELETED(observer?.resolve()))
			terminal_listeners -= observer
	if(length(terminal_listeners) >= 8)
		terminal_listeners.Cut(1, 2)
	terminal_listeners += WEAKREF(terminal)

/**
 * Service control plane of the observing session. Game code declares what an endpoint offers and
 * wants; the lane sends only what the Host does not have yet, keeps a bounded number of requests
 * in flight, coalesces telemetry to the latest value and acknowledges inbox items through the
 * allowlisted dispatcher. Everything is rebuilt after a new session.
 */
/datum/netdm_service_lane
	var/datum/netdm_endpoint_registry/weak/registry = new
	var/datum/netdm_effect_dispatcher/dispatcher = new
	/// endpoint ID -> /datum/netdm_service_endpoint
	var/list/endpoints = list()
	/// local endpoint owner (node component, APC or APC operator) -> endpoint
	var/list/by_node = list()
	/// Endpoint IDs whose declared state the Host may not have yet. Only these are reconciled: a station
	/// has hundreds of endpoints (every door and button), and nearly all of them are settled.
	var/list/unsettled = list()
	/// Retired APC operator IDs and their generations waiting for detach from a live node.
	var/list/pending_detaches = list()
	/// request ID -> list("op", ...)
	var/list/inflight = list()
	/// instance -> queued publication; a newer value replaces one not sent yet.
	var/list/publishes = list()
	/// instance -> last producer sequence, monotonic for the round.
	var/list/sequences = list()
	/// Commands waiting to be sent.
	var/list/invokes = list()
	/// Delivery status queries waiting to be sent: list(message ID, callback).
	var/list/queries = list()
	/// Research control requests (P5) waiting to be sent, in order: list(op, payload, callback).
	var/list/controls = list()
	/// Own command status queries waiting to be sent: list(endpoint, operation ID, callback).
	var/list/command_queries = list()
	var/list/pending_acks = list()
	var/next_poll = 0
	var/poll_inflight = FALSE
	/// Until then the inbox is polled every fire: something was sent and a delivery is due.
	var/hot_until = 0
	/// instance -> list(endpoint ID -> subscription key): the subscribers to tell when its provider changes.
	var/list/wanted_by = list()
	/// instance -> provider changes in this session. A subscribe reply sent before the last change is not trusted:
	/// the Host drops every subscription with the provider and never moves one to a new provider by itself.
	var/list/provider_epochs = list()
	var/list/counters = list("published" = 0, "superseded" = 0, "not_ready" = 0, "refused" = 0,
		"items" = 0, "acks" = 0, "invoked" = 0, "resubscribed" = 0)
	/// Diagnostics, real microseconds: the longest pause between inbox polls and the slowest Host reply.
	/// A long reply means the Host was late; a long pause with short replies means the lane held the poll back.
	var/last_poll_us = 0
	var/max_poll_gap_us = 0
	var/max_reply_us = 0
	var/max_reply_op

/datum/netdm_service_lane/proc/endpoint_for(datum/node, domain)
	var/datum/netdm_service_endpoint/endpoint = by_node[node]
	if(endpoint)
		return !domain || endpoint.domain == domain ? endpoint : null
	// The Host can keep a presence between connections. A new player session must never inherit its key.
	var/id_prefix = istype(node, /datum/netdm_apc_operator) ? "p-[rustg_generate_uuid_v4()]-" : null
	var/id = registry.register(owner_of(node), id_prefix)
	if(!id)
		return null
	endpoint = new
	if(domain)
		endpoint.domain = domain
	endpoint.id = id
	endpoint.node = node
	endpoints[id] = endpoint
	by_node[node] = endpoint
	unsettled[id] = TRUE
	return endpoint

/// The owner used to resolve deliveries: the parent of a device node, the APC, or its operator.
/datum/netdm_service_lane/proc/owner_of(datum/node)
	var/datum/component/netdm_node/component = node
	return istype(component) ? component.parent : node

/// Declares a service instance offered by the node.
/datum/netdm_service_lane/proc/offer(datum/component/netdm_node/node, instance, service_type, schema, major, minor = 0, scope = "domain")
	var/datum/netdm_service_endpoint/endpoint = endpoint_for(node)
	if(endpoint)
		endpoint.services[instance] = list("type" = service_type, "schema" = schema, "major" = major, "minor" = minor, "scope" = scope)
		unsettled[endpoint.id] = TRUE
	return endpoint

/// Declares a subscription of the node; it is retried until the provider exists.
/datum/netdm_service_lane/proc/want(datum/component/netdm_node/node, key, instance, schema, major, projection)
	var/datum/netdm_service_endpoint/endpoint = endpoint_for(node)
	if(!endpoint)
		return null
	var/list/previous = endpoint.subscriptions[key]
	if(previous && previous["instance"] != instance)
		unindex_want(endpoint, key, previous["instance"])
		endpoint.subscribed -= key
	endpoint.subscriptions[key] = list("instance" = instance, "schema" = schema, "major" = major, "projection" = projection)
	unsettled[endpoint.id] = TRUE
	var/list/wanting = wanted_by[instance]
	if(!wanting)
		wanting = list()
		wanted_by[instance] = wanting
	wanting[endpoint.id] = key
	return endpoint

/datum/netdm_service_lane/proc/unindex_want(datum/netdm_service_endpoint/endpoint, key, instance)
	var/list/wanting = wanted_by[instance]
	if(!wanting || wanting[endpoint.id] != key)
		return
	wanting -= endpoint.id
	if(!length(wanting))
		wanted_by -= instance

/// A successful shell watch is a desired network subscription, not only a local UI filter.
/// Reconciliation uses the existing Host subscribe protocol after a new session/attachment.
/// No event is fabricated, and no DM gameplay handler is called here.
/datum/netdm_service_lane/proc/remember_shell_watch(datum/netdm_service_endpoint/endpoint, key, instance, schema, major, projection, mode, max_pending)
	if(!endpoint || endpoints[endpoint.id] != endpoint || !istext(key) || !istext(instance) || !istext(schema) || !istext(projection))
		return FALSE
	if(!(mode in list("latest_value", "queue")) || !isnum(major) || !isnum(max_pending) || max_pending < 1 || max_pending > 16)
		return FALSE
	var/list/previous = endpoint.subscriptions[key]
	// A shell cannot take over a gameplay-owned subscription key.
	if(previous && !previous["shell"])
		return FALSE
	if(previous)
		unindex_want(endpoint, key, previous["instance"])
	endpoint.subscriptions[key] = list("instance" = instance, "schema" = schema, "major" = major,
		"projection" = projection, "mode" = mode, "pending" = max_pending, "shell" = TRUE)
	endpoint.event_watches[key] = TRUE
	// The Host already accepted the current subscription. Reconciliation is only needed
	// when its provider/session is replaced, unless the declared parameters changed.
	endpoint.subscribed[key] = TRUE
	var/list/wanting = wanted_by[instance]
	if(!wanting)
		wanting = list()
		wanted_by[instance] = wanting
	wanting[endpoint.id] = key
	return TRUE

/// Explicit unwatch revokes both the local view and the desired subscription.
/// No reconnect may resurrect a subscription after an accepted unwatch.
/datum/netdm_service_lane/proc/forget_shell_watch(datum/netdm_service_endpoint/endpoint, key)
	if(!endpoint || endpoints[endpoint.id] != endpoint || !endpoint.event_watches[key])
		return FALSE
	var/list/previous = endpoint.subscriptions[key]
	if(previous && previous["shell"])
		unindex_want(endpoint, key, previous["instance"])
		endpoint.subscriptions -= key
		endpoint.subscribed -= key
		endpoint.retry_at -= key
		endpoint.retry_delay -= key
		endpoint.refused -= key
	endpoint.event_watches -= key
	return TRUE

/// The Host removes an endpoint with its world node. An operator's retirement keeps the APC live.
/datum/netdm_service_lane/proc/drop(datum/node)
	var/datum/netdm_service_endpoint/endpoint = by_node[node]
	if(!endpoint)
		return
	if(istype(node, /datum/netdm_apc_operator))
		var/list/setup = inflight[endpoint.busy]
		if(endpoint.attached_node || setup?["op"] == "attach")
			pending_detaches[endpoint.id] = endpoint.generation
		// A command queued before retirement still holds this endpoint datum.
		endpoint.attached_node = null
	for(var/instance in endpoint.registered)
		provider_changed(instance)
	for(var/key in endpoint.subscriptions)
		var/list/subscription = endpoint.subscriptions[key]
		unindex_want(endpoint, key, subscription["instance"])
	by_node -= node
	endpoints -= endpoint.id
	unsettled -= endpoint.id
	registry.retire(endpoint.id)
	for(var/instance in endpoint.services)
		publishes -= instance

/// The provider of an instance left or registered it anew. The Host keeps no subscription across that,
/// so the subscribers of this lane ask again now; one that is still in place answers as a duplicate.
/datum/netdm_service_lane/proc/provider_changed(instance)
	provider_epochs[instance] = (provider_epochs[instance] || 0) + 1
	var/list/wanting = wanted_by[instance]
	for(var/id in wanting)
		var/datum/netdm_service_endpoint/subscriber = endpoints[id]
		if(!subscriber)
			continue
		var/key = wanting[id]
		subscriber.retry_at -= key
		subscriber.retry_delay -= key
		unsettled[id] = TRUE
		if(subscriber.subscribed[key])
			subscriber.subscribed -= key
			counters["resubscribed"]++

/// The node's acknowledged wire ID changed or went away: its endpoint attaches anew.
/datum/netdm_service_lane/proc/node_moved(datum/node)
	var/datum/netdm_service_endpoint/endpoint = by_node[node]
	if(endpoint)
		unsettled[endpoint.id] = TRUE

/// Map publication makes APC nodes visible to the lane, including their logical operators.
/datum/netdm_service_lane/proc/refresh_apc_attachments()
	for(var/id in endpoints)
		var/datum/netdm_service_endpoint/endpoint = endpoints[id]
		var/datum/node = endpoint.node
		if((istype(node, /obj/machinery/power/apc) || istype(node, /datum/netdm_apc_operator)) && endpoint.attached_node != node_id(node))
			unsettled[id] = TRUE

/// True while the instance of this node can publish in the current session.
/datum/netdm_service_lane/proc/ready(datum/component/netdm_node/node, instance)
	var/datum/netdm_service_endpoint/endpoint = by_node[node]
	return endpoint && endpoint.attached_node && endpoint.registered[instance]

/// Queues the latest value of an instance. on_accept receives the queued entry and the Host reply.
/datum/netdm_service_lane/proc/publish(datum/component/netdm_node/node, instance, list/payload, datum/callback/on_accept)
	if(!ready(node, instance))
		counters["not_ready"]++
		return null
	if(publishes[instance])
		counters["superseded"]++
	sequences[instance] = (sequences[instance] || 0) + 1
	var/list/entry = list("endpoint" = by_node[node], "instance" = instance, "sequence" = sequences[instance],
		"payload" = payload, "queued_us" = netdm_now_us(), "callback" = on_accept)
	publishes[instance] = entry
	return entry

/// Queues a command. on_accept receives the entry and the Host reply with the operation; a command
/// that never left because its node detached meanwhile gets a reply with the error "detached".
/// timeout_ticks is how long the network may carry it (Host ticks of 100 ms, at most 900).
/datum/netdm_service_lane/proc/invoke(datum/node, instance, command, idempotency_key, list/arguments, datum/callback/on_accept, timeout_ticks = 50)
	var/datum/netdm_service_endpoint/endpoint = by_node[node]
	if(!endpoint?.attached_node || length(invokes) >= 64)
		return null
	var/list/entry = list("endpoint" = endpoint, "instance" = instance, "command" = command, "key" = idempotency_key,
		"arguments" = arguments, "callback" = on_accept, "timeout" = timeout_ticks)
	invokes += list(entry)
	return entry

/// Queues a research control request; the callback receives the Host reply. FALSE while the queue is full.
/datum/netdm_service_lane/proc/control(op, list/payload, datum/callback/on_reply)
	if(length(controls) >= 16)
		return FALSE
	controls += list(list(op, payload, on_reply))
	return TRUE

/// Asks for the outcome of a command this node initiated; the callback receives the Host reply.
/datum/netdm_service_lane/proc/query_command(datum/node, operation_id, datum/callback/on_reply)
	var/datum/netdm_service_endpoint/endpoint = by_node[node]
	if(!endpoint?.attached_node || length(command_queries) >= NETDM_LANE_QUERIES)
		return FALSE
	command_queries += list(list(endpoint, operation_id, on_reply))
	return TRUE

/datum/netdm_service_lane/proc/can_query()
	return length(queries) < NETDM_LANE_QUERIES

/// Asks for every delivery of a message; the callback receives the Host reply.
/datum/netdm_service_lane/proc/query_status(message_id, datum/callback/on_reply)
	if(!can_query())
		return FALSE
	queries += list(list(message_id, on_reply))
	return TRUE

/// A new Host session: endpoints, services, subscriptions and deliveries start over there.
/datum/netdm_service_lane/proc/reset_session()
	inflight.Cut()
	pending_detaches.Cut()
	publishes.Cut()
	invokes.Cut()
	queries.Cut()
	controls.Cut()
	command_queries.Cut()
	pending_acks.Cut()
	poll_inflight = FALSE
	next_poll = 0
	last_poll_us = 0
	dispatcher.reset_cursor()
	for(var/id in endpoints)
		var/datum/netdm_service_endpoint/endpoint = endpoints[id]
		endpoint.attached_node = null
		endpoint.registered.Cut()
		endpoint.subscribed.Cut()
		// Desired shell watches survive the Host restart; their transport state does not.
		endpoint.event_journal.Cut()
		endpoint.refused.Cut()
		endpoint.retry_at.Cut()
		endpoint.retry_delay.Cut()
		endpoint.acknowledged_at.Cut()
		endpoint.busy = null
		unsettled[id] = TRUE

/// Node wire ID acknowledged by the Host, or null while it is not in the network. APC operators
/// share their APC's published wire ID and keep their own endpoint IDs.
/datum/netdm_service_lane/proc/node_id(datum/node)
	if(istype(node, /obj/machinery/power/apc))
		return SSnetdm_observe.apc_node_id(node)
	var/datum/netdm_apc_operator/operator = node
	if(istype(operator))
		var/obj/machinery/power/apc/apc = operator.apc_ref?.resolve()
		return apc ? SSnetdm_observe.apc_node_id(apc) : null
	return SSnetdm_observe.node_facts[node] ? SSnetdm_observe.node_ids[node] : null

/// Sends what the Host misses, within the in-flight budget. Returns the number of requests sent,
/// or -1 after a lost reply started a new session.
/datum/netdm_service_lane/proc/pump(datum/netdm_bridge/v1/staged/bridge)
	. = 0
	for(var/request_id in inflight)
		var/list/op = inflight[request_id]
		if(REALTIMEOFDAY >= op["deadline"])
			SSnetdm_observe.resynchronize("service_ack_timeout in [op["op"]]")
			return -1
	if(length(pending_acks))
		var/list/batch = pending_acks.Copy(1, min(length(pending_acks), NETDM_LANE_ACK_BATCH) + 1)
		if(!send(bridge.delivery_ack(batch), list("op" = "ack", "acks" = batch)))
			return
		pending_acks.Cut(1, length(batch) + 1)
		.++
	// The inbox comes before new work: what waits there is already delivered, and only a poll hands it over.
	// Status queries are diagnostics and never hold it back.
	if(!poll_inflight && (world.time >= next_poll || world.time < hot_until) && length(inflight) < NETDM_LANE_INFLIGHT && receiving())
		var/now = netdm_now_us()
		if(send(bridge.delivery_poll(dispatcher.cursor, 32), list("op" = "poll")))
			poll_inflight = TRUE
			next_poll = world.time + NETDM_LANE_POLL
			if(last_poll_us)
				max_poll_gap_us = max(max_poll_gap_us, now - last_poll_us)
			last_poll_us = now
			.++
	while(length(pending_detaches) && length(inflight) < NETDM_LANE_INFLIGHT)
		var/id = pending_detaches[1]
		var/generation = pending_detaches[id]
		if(!send(bridge.endpoint_detach(id, generation), list("op" = "detach", "id" = id, "generation" = generation)))
			return
		pending_detaches -= id
		.++
	if(length(unsettled))
		var/list/settled = list()
		for(var/id in unsettled)
			if(length(inflight) >= NETDM_LANE_INFLIGHT)
				break
			var/datum/netdm_service_endpoint/endpoint = endpoints[id]
			if(!endpoint)
				settled += id
				continue
			if(endpoint.busy)
				continue
			var/step = reconcile(bridge, endpoint)
			if(step == NETDM_LANE_SENT)
				.++
			else if(step == NETDM_LANE_SETTLED)
				settled += id
		unsettled -= settled
		if(length(inflight) >= NETDM_LANE_INFLIGHT)
			return
	while(length(publishes) && length(inflight) < NETDM_LANE_INFLIGHT)
		var/instance = publishes[1]
		var/list/entry = publishes[instance]
		publishes.Cut(1, 2)
		var/datum/netdm_service_endpoint/endpoint = entry["endpoint"]
		if(!endpoint.registered[instance])
			counters["not_ready"]++
			continue
		entry["sent_us"] = netdm_now_us()
		entry["sent_at"] = world.time
		if(!send(bridge.publish(endpoint.id, endpoint.generation, instance, entry["sequence"], entry["payload"]), list("op" = "publish", "entry" = entry)))
			return
		counters["published"]++
		hot_until = world.time + NETDM_LANE_HOT
		.++
	var/invoked = send_invokes(bridge)
	if(invoked < 0)
		return
	. += invoked
	while(length(controls) && length(inflight) < NETDM_LANE_INFLIGHT)
		var/list/control = controls[1]
		controls.Cut(1, 2)
		var/request_id = copytext(control[1], 1, 7) == "radio_" ? bridge.radio(control[1], control[2]) : bridge.research(control[1], control[2])
		if(!send(request_id, list("op" = "control", "callback" = control[3])))
			// The bridge did not take it (a full queue): it stays first in line. Dropping it here would leave
			// its owner waiting for a reply that never comes, until the next session.
			controls.Insert(1, list(control))
			return
		.++
	while(length(command_queries) && length(inflight) < NETDM_LANE_INFLIGHT)
		var/list/command_query = command_queries[1]
		command_queries.Cut(1, 2)
		var/datum/netdm_service_endpoint/asker = command_query[1]
		if(!send(bridge.command_status(asker.id, asker.generation, command_query[2]), list("op" = "status", "callback" = command_query[3])))
			return
		.++
	while(length(queries) && length(inflight) < NETDM_LANE_INFLIGHT)
		var/list/query = queries[1]
		queries.Cut(1, 2)
		if(!send(bridge.delivery_status_message(query[1]), list("op" = "status", "callback" = query[2])))
			return
		.++

/// Anything that can receive an inbox item: a subscription or a provider of a service.
/datum/netdm_service_lane/proc/receiving()
	for(var/id in endpoints)
		var/datum/netdm_service_endpoint/endpoint = endpoints[id]
		if(length(endpoint.subscribed) || length(endpoint.registered) || length(endpoint.event_watches))
			return TRUE
	return FALSE

/// One step towards the declared state of an endpoint: attach, then services, then subscriptions.
/// Returns NETDM_LANE_SENT, NETDM_LANE_SETTLED when nothing is left until the endpoint changes, or NETDM_LANE_WAIT.
/// An endpoint without a node ID is settled: node_moved() brings it back when its node is acknowledged.
/datum/netdm_service_lane/proc/reconcile(datum/netdm_bridge/v1/staged/bridge, datum/netdm_service_endpoint/endpoint)
	var/current = node_id(endpoint.node)
	if(endpoint.attached_node && endpoint.attached_node != current)
		// The node left the network or took a new wire ID; the Host removed the endpoint with it,
		// and only a larger generation is accepted again.
		SSnetdm_observe.log_issue("endpoint [endpoint.id] reattaches: node [endpoint.attached_node] -> [current || "none"]")
		endpoint.attached_node = null
		for(var/instance in endpoint.registered)
			provider_changed(instance)
		endpoint.registered.Cut()
		endpoint.subscribed.Cut()
		endpoint.generation = registry.rebind(endpoint.id, owner_of(endpoint.node)) || endpoint.generation + 1
	if(!current)
		return NETDM_LANE_SETTLED
	if(!endpoint.attached_node)
		return send(bridge.endpoint_attach(endpoint.id, endpoint.generation, current, endpoint.domain),
			list("op" = "attach", "endpoint" = endpoint, "node" = current)) ? NETDM_LANE_SENT : NETDM_LANE_WAIT
	for(var/instance in endpoint.services)
		if(endpoint.registered[instance] || endpoint.refused[instance])
			continue
		var/list/service = endpoint.services[instance]
		var/scope = service["scope"]
		return send(bridge.service_register(endpoint.id, endpoint.generation, instance, service["type"], service["schema"],
			service["major"], service["minor"], scope, scope, scope),
			list("op" = "register", "endpoint" = endpoint, "instance" = instance)) ? NETDM_LANE_SENT : NETDM_LANE_WAIT
	. = NETDM_LANE_SETTLED
	for(var/key in endpoint.subscriptions)
		if(endpoint.subscribed[key] || endpoint.refused[key])
			continue
		if(world.time < endpoint.retry_at[key])
			. = NETDM_LANE_WAIT // A subscription waiting out its retry delay keeps the endpoint in the pass.
			continue
		var/list/subscription = endpoint.subscriptions[key]
		return send(bridge.subscribe(endpoint.id, endpoint.generation, key, subscription["instance"], subscription["schema"],
			subscription["major"], subscription["projection"], subscription["mode"] || "latest_value", subscription["pending"] || 1),
			list("op" = "subscribe", "endpoint" = endpoint, "key" = key,
			"instance" = subscription["instance"], "epoch" = provider_epochs[subscription["instance"]])) ? NETDM_LANE_SENT : NETDM_LANE_WAIT

/datum/netdm_service_lane/proc/send(request_id, list/op)
	if(!request_id)
		return FALSE
	op["deadline"] = REALTIMEOFDAY + NETDM_LANE_TIMEOUT
	// The Host takes requests in order: what was sent at an earlier world.time, or earlier in this pump, came first.
	op["sent_at"] = world.time
	op["sent_us"] = netdm_now_us()
	inflight[request_id] = op
	var/datum/netdm_service_endpoint/endpoint = op["endpoint"]
	if(endpoint && op["op"] != "publish" && op["op"] != "invoke")
		endpoint.busy = request_id
	return TRUE

/// Sends queued commands within the in-flight budget. Returns how many, or -1 when the bridge refused one.
/datum/netdm_service_lane/proc/send_invokes(datum/netdm_bridge/v1/staged/bridge)
	. = 0
	while(length(invokes) && length(inflight) < NETDM_LANE_INFLIGHT)
		var/list/entry = invokes[1]
		invokes.Cut(1, 2)
		var/datum/netdm_service_endpoint/endpoint = entry["endpoint"]
		if(!endpoint.attached_node)
			var/datum/callback/on_detached = entry["callback"]
			on_detached?.Invoke(entry, list("ok" = FALSE, "error" = "detached"))
			continue
		if(!send(bridge.invoke(endpoint.id, endpoint.generation, entry["instance"], entry["command"], entry["key"], entry["arguments"], entry["timeout"]), list("op" = "invoke", "entry" = entry)))
			invokes.Insert(1, list(entry))
			return -1
		entry["sent_us"] = netdm_now_us()
		counters["invoked"]++
		hot_until = world.time + NETDM_LANE_HOT
		.++

/// Speech cannot wait for the next fire: queued commands leave now, outside the subsystem's pump.
/datum/netdm_service_lane/proc/flush_invokes()
	var/datum/netdm_bridge/v1/staged/bridge = SSnetdm_observe.bridge
	if(bridge && SSnetdm_observe.published && length(invokes))
		send_invokes(bridge)

/// Takes a reply of this lane. Returns TRUE when it was one.
/datum/netdm_service_lane/proc/accept(list/reply)
	var/request_id = reply["id"]
	var/list/op = inflight[request_id]
	if(!op)
		return FALSE
	inflight -= request_id
	var/reply_us = netdm_now_us() - op["sent_us"]
	if(reply_us > max_reply_us)
		max_reply_us = reply_us
		max_reply_op = op["op"]
	var/datum/netdm_service_endpoint/endpoint = op["endpoint"]
	if(endpoint?.busy == request_id)
		endpoint.busy = null
	// An endpoint dropped while its request was in flight has nothing left to update.
	if(endpoint && endpoints[endpoint.id] != endpoint)
		return TRUE
	// Its next step, if any, is taken in the next pass.
	if(endpoint)
		unsettled[endpoint.id] = TRUE
	var/ok = reply["ok"]
	var/error = reply["error"]
	switch(op["op"])
		if("detach")
			if(!ok && error != "unknown_endpoint" && error != "stale_generation")
				pending_detaches[op["id"]] = op["generation"]
		if("attach")
			if(ok)
				endpoint.attached_node = op["node"]
				// Programs kept on the device's media start again: after a new session or a new generation.
				SSnetdm_observe.diagnostics?.endpoint_attached(endpoint.node)
		if("register")
			if(ok)
				endpoint.registered[op["instance"]] = TRUE
				endpoint.acknowledged_at[op["instance"]] = op["sent_at"]
				// Subscribers waiting out a retry delay for this instance ask now.
				provider_changed(op["instance"])
			else
				refuse(endpoint, op["instance"], error)
		if("subscribe")
			var/key = op["key"]
			if(op["epoch"] != provider_epochs[op["instance"]])
				// The provider changed while this request was in flight: the answer may be outdated either way,
				// a confirmation as much as unknown_service. The subscription is asked again at once.
				endpoint.retry_delay -= key
			else if(ok)
				endpoint.subscribed[key] = TRUE
				endpoint.retry_delay -= key
				var/list/result = reply["result"]
				// A duplicate confirms the subscription that was in place since its first request.
				if(!(islist(result) && result["status"] == "duplicate" && !isnull(endpoint.acknowledged_at[key])))
					endpoint.acknowledged_at[key] = op["sent_at"]
			else if(error == "unknown_service" || error == "unknown_endpoint")
				var/delay = endpoint.retry_delay[key] ? min(endpoint.retry_delay[key] * 2, NETDM_LANE_SUBSCRIBE_RETRY_MAX) : NETDM_LANE_SUBSCRIBE_RETRY
				endpoint.retry_delay[key] = delay
				endpoint.retry_at[key] = world.time + delay
			else
				refuse(endpoint, key, error)
		if("publish", "invoke")
			var/list/entry = op["entry"]
			entry["accepted_us"] = netdm_now_us()
			var/datum/callback/on_accept = entry["callback"]
			on_accept?.Invoke(entry, reply)
		if("status", "control")
			var/datum/callback/on_reply = op["callback"]
			on_reply?.Invoke(reply)
		if("poll")
			poll_inflight = FALSE
			var/list/page = reply["result"]
			if(ok && islist(page))
				var/list/acks = dispatcher.handle_page(page, registry)
				counters["items"] += length(page["items"])
				// A command delivered to a provider is answered, and its result comes back soon.
				if(length(page["items"]))
					hot_until = max(hot_until, world.time + NETDM_LANE_HOT)
				pending_acks += acks
				counters["acks"] += length(acks)
				// More is waiting: poll again without the cadence pause.
				if(text2num(page["pending"]) > 0)
					next_poll = 0
	return TRUE

/datum/netdm_service_lane/proc/refuse(datum/netdm_service_endpoint/endpoint, name, reason)
	endpoint.refused[name] = reason || "refused"
	counters["refused"]++
	SSnetdm_observe.log_issue("service request refused for [endpoint.id] [name]: [reason]")

/datum/netdm_service_lane/proc/state()
	var/attached = 0
	var/services = 0
	var/subscriptions = 0
	for(var/id in endpoints)
		var/datum/netdm_service_endpoint/endpoint = endpoints[id]
		if(endpoint.attached_node)
			attached++
		services += length(endpoint.registered)
		subscriptions += length(endpoint.subscribed)
	return "endpoints=[attached]/[length(endpoints)] unsettled=[length(unsettled)] services=[services] subscriptions=[subscriptions] \
		inflight=[length(inflight)] queued=[length(publishes)] published=[counters["published"]] \
		superseded=[counters["superseded"]] not_ready=[counters["not_ready"]] items=[counters["items"]] refused=[counters["refused"]] \
		resubscribed=[counters["resubscribed"]] poll_gap=[round(max_poll_gap_us / 1000)]ms \
		reply_max=[round(max_reply_us / 1000)]ms/[max_reply_op || "none"]"

/// Monotonic microseconds for latency figures; world.timeofday steps by a tenth of a second.
/proc/netdm_now_us()
	return rustg_time_microseconds("netdm")

#undef NETDM_LANE_INFLIGHT
#undef NETDM_LANE_POLL
#undef NETDM_LANE_HOT
#undef NETDM_LANE_TIMEOUT
#undef NETDM_LANE_SUBSCRIBE_RETRY
#undef NETDM_LANE_SUBSCRIBE_RETRY_MAX
#undef NETDM_LANE_ACK_BATCH
#undef NETDM_LANE_QUERIES
#undef NETDM_LANE_SETTLED
#undef NETDM_LANE_SENT
#undef NETDM_LANE_WAIT
