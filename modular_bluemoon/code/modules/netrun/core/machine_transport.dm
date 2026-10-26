/// Machine services share physical routing, while each adapter retains native authorization.
/atom
	var/list/netrun_machine_services

/atom/proc/netrun_machine_service_types()
	return list()

/atom/proc/netrun_machine_service_node()
	var/datum/component/netrun_node/node = GetComponent(/datum/component/netrun_node)
	if(!node && length(netrun_machine_service_types()))
		node = AddComponent(/datum/component/netrun_node, NETRUN_NODE_SERVER, list(), 1)
	return node

/atom/proc/ensure_netrun_machine_services(datum/component/netrun_node/node)
	if(!node || QDELETED(src))
		return
	if(!netrun_machine_services)
		netrun_machine_services = list()
	for(var/datum/netrun_machine_service/path as anything in netrun_machine_service_types())
		var/id = initial(path.service_id)
		var/datum/netrun_machine_service/service = netrun_machine_services[id]
		if(QDELETED(service))
			netrun_machine_services[id] = new path(node, src)
		else
			// HIGHLANDER replaces a component after registering the new one.
			service.node = node
			SSnetrun.get_machine_transport().index_service(service)

/atom/proc/get_netrun_machine_service(service_id)
	var/datum/component/netrun_node/node = netrun_machine_service_node()
	ensure_netrun_machine_services(node)
	var/datum/netrun_machine_service/service = netrun_machine_services?[service_id]
	if(!QDELETED(service))
		service.node = node
		SSnetrun.get_machine_transport().index_service(service)
		return service

/datum/controller/subsystem/netrun
	var/datum/netrun_machine_transport/machine_transport

/datum/controller/subsystem/netrun/proc/get_machine_transport() as /datum/netrun_machine_transport
	RETURN_TYPE(/datum/netrun_machine_transport)
	if(!machine_transport)
		machine_transport = new
	return machine_transport

/// Every message is owned by its delivery. Payload lists never alias native state.
/datum/netrun_machine_message
	var/list/payload
	var/datum/netrun_machine_service/source
	var/datum/netrun_machine_service/recipient
	var/datum/weakref/user_ref
	var/correlation_id

/datum/netrun_machine_message/New(list/payload)
	src.payload = payload ? deepCopyList(payload) : list()

/datum/netrun_machine_message/Destroy()
	payload = null
	source = null
	recipient = null
	user_ref = null
	return ..()

/datum/netrun_machine_message/proc/copy()
	var/datum/netrun_machine_message/result = new type()
	result.payload = deepCopyList(payload)
	result.user_ref = user_ref
	result.correlation_id = correlation_id
	return result

/datum/netrun_machine_message/proc/reply(datum/netrun_machine_message/response)
	response.correlation_id = correlation_id
	return recipient.send_to(source, response)

/datum/netrun_machine_message/proc/failed(reason)
	return

/datum/netrun_machine_message/proc/delivered(datum/netrun_machine_service/recipient_service)
	return

/// Only replaceable state snapshots opt in; commands retain their own delivery.
/datum/netrun_machine_message/proc/coalescing_key()
	return null

/// Replaceable telemetry yields to ordinary traffic. An actor reference is not
/// evidence of explicit input: radio speech and automated notices also have one.
/datum/netrun_machine_message/proc/delivery_priority()
	return isnull(coalescing_key()) ? NETRUN_TASK_NORMAL : NETRUN_TASK_BACKGROUND

/datum/netrun_machine_service
	var/service_id
	var/atom/host
	var/datum/component/netrun_node/node
	var/list/directory = list()
	var/list/resolutions = list()
	var/indexed_tag

/datum/netrun_machine_service/New(datum/component/netrun_node/node, atom/host_override)
	src.node = node
	host = host_override || node?.parent
	if(host)
		RegisterSignal(host, COMSIG_PARENT_QDELETING, PROC_REF(host_deleted))
		RegisterSignal(host, list(COMSIG_ATOM_AFTER_SUCCESSFUL_INITIALIZE, COMSIG_ATOM_UPDATE_NAME, COMSIG_NETRUN_SERVICE_STATE_CHANGED, COMSIG_MODULAR_COMPUTER_FILE_STORE, COMSIG_MODULAR_COMPUTER_FILE_DELETE), PROC_REF(host_initialized))
	SSnetrun.get_machine_transport().register(src)

/datum/netrun_machine_service/Destroy()
	SSnetrun.get_machine_transport().unregister(src)
	if(host)
		UnregisterSignal(host, list(COMSIG_PARENT_QDELETING, COMSIG_ATOM_AFTER_SUCCESSFUL_INITIALIZE, COMSIG_ATOM_UPDATE_NAME, COMSIG_NETRUN_SERVICE_STATE_CHANGED, COMSIG_MODULAR_COMPUTER_FILE_STORE, COMSIG_MODULAR_COMPUTER_FILE_DELETE))
		if(host.netrun_machine_services?[service_id] == src)
			host.netrun_machine_services -= service_id
	for(var/key in resolutions.Copy())
		qdel(resolutions[key])
	resolutions.Cut()
	for(var/key in directory)
		qdel(directory[key])
	directory.Cut()
	host = null
	node = null
	return ..()

/datum/netrun_machine_service/proc/host_deleted()
	SIGNAL_HANDLER
	qdel(src)

/datum/netrun_machine_service/proc/host_initialized()
	SIGNAL_HANDLER
	SSnetrun.get_machine_transport().index_service(src)

/datum/netrun_machine_service/proc/service_key()
	return "[REF(host)]:[service_id]"

/datum/netrun_machine_service/proc/resolve_node()
	RETURN_TYPE(/datum/component/netrun_node)
	return node

/datum/netrun_machine_service/proc/service_tag()
	return resolve_node()?.address

/datum/netrun_machine_service/proc/matches(datum/netrun_machine_service/source_service, recipient_tag)
	return isnull(recipient_tag) || service_tag() == recipient_tag

/datum/netrun_machine_service/proc/accepts(datum/netrun_machine_message/message)
	return !QDELETED(host) && resolve_node()?.is_online() && message.source?.resolve_node()?.is_online()

/datum/netrun_machine_service/proc/receive(datum/netrun_machine_message/message)
	return FALSE

/datum/netrun_machine_service/proc/rejection_reason(datum/netrun_machine_message/message)
	return "получатель отклонил пакет"

/datum/netrun_machine_service/proc/directory_ready(destination_id, recipient_tag)
	if(!QDELETED(host))
		SEND_SIGNAL(host, COMSIG_NETRUN_SERVICE_STATE_CHANGED)
		SStgui.update_uis(host)

/datum/netrun_machine_service/proc/send(destination_id, datum/netrun_machine_message/message, recipient_tag)
	if(QDELETED(message))
		return FALSE
	var/datum/netrun_machine_directory/entry = cached_directory(destination_id, recipient_tag)
	if(entry)
		return send_resolved(destination_id, message, recipient_tag, entry)
	var/datum/netrun_machine_resolution/query = get_resolution(destination_id, recipient_tag)
	if(!query)
		message.failed("источник недоступен")
		qdel(message)
		return FALSE
	return query.enqueue(message)

/// Cold discovery and cache hits use the same target policy. Domain services may
/// select a single replica; transport must never turn one mutation into a broadcast.
/datum/netrun_machine_service/proc/send_resolved(destination_id, datum/netrun_machine_message/message, recipient_tag, datum/netrun_machine_directory/entry)
	var/list/targets = resolve(destination_id, recipient_tag, entry)
	var/admitted = FALSE
	for(var/datum/netrun_machine_service/target as anything in targets)
		admitted = send_to(target, message.copy()) || admitted
	if(!length(targets))
		message.failed("DNS: получатель недоступен")
	qdel(message)
	return admitted

/// Replies and peers already obtained through service discovery do not repeat DNS.
/datum/netrun_machine_service/proc/send_to(datum/netrun_machine_service/target, datum/netrun_machine_message/message)
	return SSnetrun.get_machine_transport().dispatch(src, target, message)

/datum/netrun_machine_service/proc/resolve(destination_id, recipient_tag, datum/netrun_machine_directory/entry)
	entry = entry || cached_directory(destination_id, recipient_tag)
	var/list/result = list()
	if(entry)
		for(var/datum/weakref/ref as anything in entry.records)
			var/datum/netrun_machine_service/target = ref.resolve()
			if(!QDELETED(target) && target.matches(src, recipient_tag) && can_reach(target, FALSE))
				result += target
		return result
	get_resolution(destination_id, recipient_tag)
	return result

/datum/netrun_machine_service/proc/cached_directory(destination_id, recipient_tag)
	if(!SSnetrun.get_machine_transport().is_ready())
		return null
	var/query_key = "[destination_id]|[recipient_tag]"
	var/datum/netrun_machine_directory/entry = directory[query_key]
	var/datum/netrun_machine_transport/transport = SSnetrun.get_machine_transport()
	if(entry && entry.expires > world.time && entry.revision == transport.service_revisions[destination_id] && transport.reachable(src, entry.resolver_ref?.resolve(), netrun_communication_policy(src, destination_id)))
		return entry
	return null

/datum/netrun_machine_service/proc/get_resolution(destination_id, recipient_tag)
	if(QDELETED(host) || QDELETED(resolve_node()))
		return null
	// Native power/area bindings are not authoritative until map initialization ends.
	if(SSnetrun.get_machine_transport().is_ready() && !resolve_node().is_online())
		return null
	var/query_key = "[destination_id]|[recipient_tag]"
	var/datum/netrun_machine_resolution/query = resolutions[query_key]
	if(query)
		return query
	if(length(resolutions) >= 64)
		return null
	query = new(src, destination_id, recipient_tag)
	resolutions[query_key] = query
	query.begin()
	return QDELETED(query) ? null : query

/datum/netrun_machine_service/proc/can_reach(datum/netrun_machine_service/target, require_dns = TRUE)
	if(QDELETED(target) || !SSnetrun.get_machine_transport().reachable(src, target))
		return FALSE
	if(!require_dns)
		return TRUE
	for(var/query_key in directory)
		var/datum/netrun_machine_directory/entry = directory[query_key]
		if(entry.expires <= world.time || !SSnetrun.get_machine_transport().reachable(src, entry.resolver_ref?.resolve(), netrun_communication_policy(src, target.service_id)))
			continue
		for(var/datum/weakref/ref as anything in entry.records)
			if(ref.resolve() == target)
				return TRUE
	return FALSE

/datum/netrun_machine_directory
	var/list/records = list()
	var/datum/weakref/resolver_ref
	var/expires
	var/revision

/// Registry metadata is local; query, answer and data each cross a real packet boundary.
/datum/netrun_machine_transport
	var/list/services = list()
	var/list/by_id = list()
	var/list/by_tag = list()
	var/list/waiting_resolutions = list()
	var/wake_timer
	/// Readiness notifications share one bounded common-worker continuation.
	var/wake_queued = FALSE
	var/list/wake_queries
	var/wake_cursor = 1
	var/wake_again = FALSE
	var/preparing = FALSE
	var/bootstrap_complete = FALSE
	var/packet_serial = 0
	var/list/service_revisions = list()
	var/list/packets = list()
	var/list/interactive_packets = list()
	var/queued_messages = 0
	var/list/last_flow = list()
	var/flow_window = 0
	var/flow_count = 0
	var/revision = 0
	var/list/route_trees = list()
	var/list/route_used = list()
	var/list/pair_routes = list()
	var/list/pair_used = list()
	var/list/pair_previous = list()
	var/list/pair_next = list()
	var/pair_oldest
	var/pair_newest
	var/route_cache_limit = 8192
	var/root_cache_limit = 512
	var/pair_serial = 0
	var/path_builds = 0
	var/path_cache_hits = 0
	var/tree_builds = 0
	var/list/prewarm_roots = list()
	var/prewarm_revision = -1
	var/prewarm_infrastructure = -1
	var/prewarm_steps = 0
	var/prewarm_limit = 512
	var/bootstrap_at
	/// Source/recipient/contract key -> one replaceable, not-yet-executing packet.
	var/list/replaceable_packets = list()
	var/coalesced_packets = 0
	/// Opt-in diagnostics: value snapshots only, bounded independently of packet lifetime.
	var/list/delivery_trace

/datum/netrun_machine_transport/proc/trace_delivery(datum/netrun_machine_packet/packet)
	if(!islist(delivery_trace))
		return
	delivery_trace += list(list("id" = packet.packet_id, "kind" = packet.kind,
		"source" = "[packet.source?.host?.type]", "destination" = "[packet.recipient?.host?.type]",
		"sent" = packet.sent_at, "due" = packet.due_at, "ready" = packet.ready_at, "run" = world.time,
		"timer_late" = max(0, packet.ready_at - packet.due_at), "queue_wait" = max(0, world.time - packet.ready_at)))
	if(length(delivery_trace) > 256)
		delivery_trace.Cut(1, length(delivery_trace) - 255)

/datum/netrun_machine_transport/New()
	RegisterSignal(SSnetrun, COMSIG_NETRUN_NODE_UNREGISTERED, PROC_REF(node_deleted))
	RegisterSignal(SSatoms, COMSIG_SUBSYSTEM_POST_INITIALIZE, PROC_REF(atoms_initialized))
	RegisterSignal(SSnetrun, COMSIG_NETRUN_NODE_CHANGED, PROC_REF(network_changed))

/datum/netrun_machine_transport/proc/atoms_initialized()
	SIGNAL_HANDLER
	prepare_network()

/datum/netrun_machine_transport/proc/is_ready()
	return bootstrap_complete && !preparing && SSnetrun.initialized && SSatoms.initialized == INITIALIZATION_INNEW_REGULAR

/// Master starts subsystem fire only after its whole initialization loop. The atom
/// post-init signal alone is too early: power, research and native links can change.
/datum/netrun_machine_transport/proc/prepare_network()
	if(preparing || !SSnetrun.initialized || SSatoms.initialized != INITIALIZATION_INNEW_REGULAR || Master.initializing_subsystem || !Master.current_runlevel)
		return
	var/pregame = SSticker.current_state < GAME_STATE_PLAYING
	if(bootstrap_complete && !pregame)
		return
	var/datum/netrun_topology/graph = SSnetrun.get_topology()
	if(!bootstrap_complete || graph.dirty || prewarm_revision != graph.revision || length(prewarm_roots))
		SSnetrun.get_task_scheduler().enqueue("network_bootstrap", src, NETRUN_TASK_BACKGROUND)

/// One topology preparation slice or one retained infrastructure tree per task.
/datum/netrun_machine_transport/proc/advance_bootstrap(datum/netrun_execution_limits/limits)
	if(preparing || Master.initializing_subsystem || SSatoms.initialized != INITIALIZATION_INNEW_REGULAR)
		return FALSE
	preparing = TRUE
	if(!bootstrap_complete)
		SSnetrun.spawn_roundstart_servers()
	var/datum/netrun_topology/graph = SSnetrun.get_topology()
	if(graph.dirty)
		if(!graph.advance_apc_prebuild(limits.apc_operations))
			preparing = FALSE
			return FALSE
	if(!bootstrap_complete)
		for(var/key in services.Copy())
			var/datum/netrun_machine_service/service = services[key]
			if(!QDELETED(service))
				index_service(service)
		bootstrap_complete = TRUE
		bootstrap_at = world.time
		wake_resolutions()
	if(prewarm_revision != graph.revision || prewarm_infrastructure != graph.infrastructure_revision)
		prewarm_roots.Cut()
		prewarm_revision = graph.revision
		prewarm_infrastructure = graph.infrastructure_revision
		// Discovery and native communications are useful first. Store APC anchors,
		// never a whole station-sized routing table per vent, radio or PDA.
		for(var/id in list("dns", "research.server", "telecomms.relay", "research.client"))
			for(var/datum/netrun_machine_service/service as anything in by_id[id])
				var/datum/component/netrun_node/node = service.resolve_node()
				var/datum/component/netrun_node/root = graph.is_infrastructure(node) ? node : node?.bound_apc
				if(root && length(prewarm_roots) < prewarm_limit)
					prewarm_roots |= root.address
		for(var/address in graph.registered_apcs)
			if(length(prewarm_roots) >= prewarm_limit)
				break
			prewarm_roots |= address
	if(length(prewarm_roots))
		var/address = prewarm_roots[1]
		prewarm_roots.Cut(1, 2)
		var/datum/component/netrun_node/root = graph.nodes[address]
		if(!QDELETED(root) && root.is_online())
			path_tree(graph, root)
			prewarm_steps++
	preparing = FALSE
	return !length(prewarm_roots)

/datum/netrun_task/network_bootstrap
	parent_type = /datum/netrun_task/continuation
	kind = "network_bootstrap"

/datum/netrun_task/network_bootstrap/advance(datum/controller/subsystem/netrun/worker, datum/netrun_execution_limits/limits)
	var/datum/netrun_machine_transport/transport = target()
	return transport.advance_bootstrap(limits)

/datum/netrun_machine_transport/proc/network_changed(datum/source, datum/component/netrun_node/node, flags)
	SIGNAL_HANDLER
	if(length(waiting_resolutions) && (node.node_type == NETRUN_NODE_APC || istype(node.parent, /obj/machinery/ntnet_relay) || istype(node.parent, /obj/machinery/netrun_server/dns)))
		wake_resolutions()

/// Registration/power restoration wakes pending discovery once, after construction unwinds.
/datum/netrun_machine_transport/proc/wake_resolutions()
	if(!length(waiting_resolutions) || wake_timer)
		return
	if(wake_queued)
		wake_again = TRUE
		return
	wake_timer = addtimer(CALLBACK(src, PROC_REF(resume_resolutions)), world.tick_lag, TIMER_STOPPABLE | TIMER_DELETE_ME)

/datum/netrun_machine_transport/proc/resume_resolutions()
	if(wake_timer)
		deltimer(wake_timer)
	wake_timer = null
	if(!length(waiting_resolutions))
		return
	if(wake_queued)
		wake_again = TRUE
		return
	wake_queued = TRUE
	SSnetrun.get_task_scheduler().enqueue("dns_wake", src, NETRUN_TASK_BACKGROUND)
	SSnetrun.wake_ready_delivery()

/// Copying the wave and native begin() both run inside the shared MC budget.
/// A notification during a wave coalesces into one fresh snapshot afterwards.
/datum/netrun_machine_transport/proc/advance_resolutions()
	if(!wake_queries)
		wake_queries = waiting_resolutions.Copy()
		wake_cursor = 1
		wake_again = FALSE
	var/stop = min(length(wake_queries), wake_cursor + 7)
	while(wake_cursor <= stop)
		var/datum/netrun_machine_resolution/query = wake_queries[wake_cursor++]
		if(!QDELETED(query) && (query in waiting_resolutions))
			query.begin()
	if(wake_cursor <= length(wake_queries))
		return FALSE
	wake_queries = null
	if(wake_again && length(waiting_resolutions))
		wake_again = FALSE
		return FALSE
	wake_again = FALSE
	wake_queued = FALSE
	return TRUE

/datum/netrun_task/dns_wake
	parent_type = /datum/netrun_task/continuation
	kind = "dns_wake"

/datum/netrun_task/dns_wake/advance(datum/controller/subsystem/netrun/worker, datum/netrun_execution_limits/limits)
	var/datum/netrun_machine_transport/transport = target()
	return transport.advance_resolutions()

/datum/netrun_machine_transport/proc/node_deleted(datum/source, datum/component/netrun_node/node)
	SIGNAL_HANDLER
	qdel(route_trees[node.address])
	route_trees -= node.address
	route_used -= node.address

/datum/netrun_machine_transport/Destroy()
	SSnetrun.task_scheduler?.cancel("network_bootstrap", src)
	SSnetrun.task_scheduler?.cancel("dns_wake", src)
	UnregisterSignal(SSnetrun, list(COMSIG_NETRUN_NODE_UNREGISTERED, COMSIG_NETRUN_NODE_CHANGED))
	UnregisterSignal(SSatoms, COMSIG_SUBSYSTEM_POST_INITIALIZE)
	if(wake_timer)
		deltimer(wake_timer)
	wake_queued = FALSE
	wake_queries = null
	wake_again = FALSE
	QDEL_LIST(packets)
	replaceable_packets.Cut()
	for(var/address in route_trees)
		qdel(route_trees[address])
	route_trees.Cut()
	route_used.Cut()
	clear_pair_routes()
	return ..()

/datum/netrun_machine_transport/proc/register(datum/netrun_machine_service/service)
	services[service.service_key()] = service
	var/list/bucket = by_id[service.service_id]
	if(!bucket)
		bucket = list()
		by_id[service.service_id] = bucket
	bucket |= service
	revision++
	service_revisions[service.service_id] = (service_revisions[service.service_id] || 0) + 1
	index_service(service)
	if(service.service_id == "dns" || service.node?.node_type == NETRUN_NODE_APC || istype(service.host, /obj/machinery/ntnet_relay))
		wake_resolutions()

/datum/netrun_machine_transport/proc/index_service(datum/netrun_machine_service/service)
	var/tag = service.service_tag()
	if(service.indexed_tag == tag)
		return
	var/previous_key = "[service.service_id]|[service.indexed_tag]"
	var/list/previous = by_tag[previous_key]
	if(previous)
		previous -= service
	if(!length(previous))
		by_tag -= previous_key
	service.indexed_tag = tag
	if(!isnull(tag))
		var/key = "[service.service_id]|[tag]"
		var/list/bucket = by_tag[key]
		if(!bucket)
			bucket = list()
			by_tag[key] = bucket
		bucket |= service
	service_revisions[service.service_id] = (service_revisions[service.service_id] || 0) + 1

/datum/netrun_machine_transport/proc/unregister(datum/netrun_machine_service/service)
	services -= service.service_key()
	var/list/bucket = by_id[service.service_id]
	if(bucket)
		bucket -= service
	var/tag_key = "[service.service_id]|[service.indexed_tag]"
	var/list/tag_bucket = by_tag[tag_key]
	if(tag_bucket)
		tag_bucket -= service
	if(!length(tag_bucket))
		by_tag -= tag_key
	revision++
	service_revisions[service.service_id] = (service_revisions[service.service_id] || 0) + 1
	for(var/datum/netrun_machine_packet/packet as anything in packets.Copy())
		if(packet.source == service || packet.recipient == service)
			packet.fail("машина отключена")

/datum/netrun_machine_transport/proc/lookup(datum/netrun_machine_service/source, destination_id, recipient_tag, communications)
	. = list()
	var/list/bucket = isnull(recipient_tag) ? by_id[destination_id] : by_tag["[destination_id]|[recipient_tag]"]
	// A few native tag setters still write fields directly. Repair a stale/missing
	// index once on cache miss; ordinary exact-address traffic stays indexed.
	if(!isnull(recipient_tag) && !length(bucket))
		bucket = list()
		for(var/datum/netrun_machine_service/candidate as anything in by_id[destination_id])
			if(!QDELETED(candidate) && candidate.service_tag() == recipient_tag)
				index_service(candidate)
				bucket |= candidate
	for(var/datum/netrun_machine_service/target as anything in bucket)
		if(!QDELETED(target) && target.matches(source, recipient_tag) && reachable(source, target, communications))
			. += target

/datum/netrun_machine_transport/proc/reachable(datum/netrun_machine_service/source, datum/netrun_machine_service/recipient, communications)
	if(isnull(communications))
		communications = netrun_communication_policy(source, recipient?.service_id)
	return !!(borrowed_path(source, recipient) || (communications && communication_path(source, recipient)))

/// This cache owns its paths; only route() exposes mutable request-owned copies.
/datum/netrun_machine_path
	parent_type = /datum/netrun_route
	var/datum/weakref/graph_ref
	var/geometry_revision
	var/transit_revision
	var/from_anchor
	var/to_anchor
	var/prefix_cost
	var/suffix_cost

/datum/netrun_machine_transport/proc/clear_pair_routes()
	for(var/key in pair_routes)
		qdel(pair_routes[key])
	pair_routes.Cut()
	pair_used.Cut()
	pair_previous.Cut()
	pair_next.Cut()
	pair_oldest = null
	pair_newest = null

/// Pair capacity is large enough for a station poll, so eviction must not scan it.
/datum/netrun_machine_transport/proc/unlink_pair_route(key)
	var/previous = pair_previous[key]
	var/next = pair_next[key]
	if(previous)
		pair_next[previous] = next
	else if(pair_oldest == key)
		pair_oldest = next
	if(next)
		pair_previous[next] = previous
	else if(pair_newest == key)
		pair_newest = previous
	pair_previous -= key
	pair_next -= key

/datum/netrun_machine_transport/proc/touch_pair_route(key)
	pair_used[key] = ++pair_serial
	if(pair_newest == key)
		return
	unlink_pair_route(key)
	pair_previous[key] = pair_newest
	pair_next[key] = null
	if(pair_newest)
		pair_next[pair_newest] = key
	else
		pair_oldest = key
	pair_newest = key

/datum/netrun_machine_transport/proc/forget_pair_route(key)
	unlink_pair_route(key)
	qdel(pair_routes[key])
	pair_routes -= key
	pair_used -= key

/datum/netrun_machine_transport/proc/store_pair_route(key, datum/netrun_machine_path/path)
	forget_pair_route(key)
	while(length(pair_routes) >= max(1, route_cache_limit))
		forget_pair_route(pair_oldest)
	pair_routes[key] = path
	touch_pair_route(key)

/// Most endpoints have one APC cable. Share one tree at that attachment instead of
/// keeping a station-sized table for each vent, camera and carried computer.
/datum/netrun_machine_transport/proc/path_tree(datum/netrun_topology/graph, datum/component/netrun_node/root, availability_reconciled = FALSE)
	if(!availability_reconciled)
		graph.reconcile_availability()
	var/datum/netrun_path_tree/tree = route_trees[root.address]
	if(!tree || tree.graph_ref?.resolve() != graph || tree.source != root || tree.geometry_revision != graph.infrastructure_revision || tree.transit_availability_revision != graph.transit_availability_revision)
		graph.reconcile_availability(TRUE)
		qdel(tree)
		if(!tree && length(route_trees) >= max(1, root_cache_limit))
			var/oldest
			for(var/address in route_used)
				if(!oldest || route_used[address] < route_used[oldest])
					oldest = address
			qdel(route_trees[oldest])
			route_trees -= oldest
			route_used -= oldest
		tree = new(graph, root, TRUE)
		route_trees[root.address] = tree
		tree_builds++
	route_used[root.address] = world.time
	return tree

/// Return a mutable request-owned route; boolean checks borrow cached paths directly.
/datum/netrun_machine_transport/proc/route(datum/netrun_machine_service/source, datum/netrun_machine_service/recipient, communications, frequency)
	var/datum/netrun_machine_path/path = borrowed_path(source, recipient)
	if(isnull(communications))
		communications = netrun_communication_policy(source, recipient?.service_id)
	if(!path && communications)
		path = communication_path(source, recipient, frequency)
	if(!path)
		return null
	var/datum/netrun_route/result = new
	result.hops = path.hops.Copy()
	result.latency = path.latency
	return result

/// Only infrastructure participates in shortest-path solving. Endpoint attachment and
/// cable costs are checked separately, so unrelated leaf movement/power cannot flush it.
/datum/netrun_machine_transport/proc/borrowed_path(datum/netrun_machine_service/source, datum/netrun_machine_service/recipient)
	if(QDELETED(source) || QDELETED(recipient) || QDELETED(source.host) || QDELETED(recipient.host))
		return null
	var/datum/component/netrun_node/start = source.resolve_node()
	var/datum/component/netrun_node/finish = recipient.resolve_node()
	if(QDELETED(start) || QDELETED(finish) || !start.is_online() || !finish.is_online())
		return null
	// A carried endpoint does not receive its container's MOVED signal.
	start.join_network()
	if(start != finish)
		finish.join_network()
	SSnetrun.ensure_topology()
	var/datum/netrun_topology/graph = SSnetrun.get_topology()
	if(graph.nodes[start.address] != start || graph.nodes[finish.address] != finish)
		return null
	graph.reconcile_availability()
	var/datum/component/netrun_node/root = start
	var/datum/component/netrun_node/destination = finish
	var/prefix_cost = 0
	var/suffix_cost = 0
	var/list/neighbors = graph.adjacency[start.address]
	if(start != finish && !graph.is_infrastructure(start) && length(neighbors) == 1)
		root = graph.nodes[neighbors[1]]
		if(!netrun_link_available(start, root))
			return null
		prefix_cost = graph.cached_edge_cost(start.address, root.address)
	neighbors = graph.adjacency[finish.address]
	if(start != finish && !graph.is_infrastructure(finish) && length(neighbors) == 1)
		destination = graph.nodes[neighbors[1]]
		if(!netrun_link_available(destination, finish))
			return null
		suffix_cost = graph.cached_edge_cost(destination.address, finish.address)
	var/key = "[start.address]>[finish.address]"
	var/datum/netrun_machine_path/cached = pair_routes[key]
	if(cached && cached.graph_ref?.resolve() == graph && cached.geometry_revision == graph.infrastructure_revision && cached.transit_revision == graph.transit_availability_revision && cached.from_anchor == root.address && cached.to_anchor == destination.address && cached.prefix_cost == prefix_cost && cached.suffix_cost == suffix_cost)
		if(!length(cached.hops) || path_available(graph, cached.hops))
			touch_pair_route(key)
			path_cache_hits++
			return length(cached.hops) ? cached : null
		// Legacy native writes can change a forwarding node without its usual signal.
		// Reconcile only this failed path, then allow an alternate route immediately.
		reconcile_path(graph, cached.hops)
	var/datum/netrun_machine_path/result = new
	result.graph_ref = WEAKREF(graph)
	result.from_anchor = root.address
	result.to_anchor = destination.address
	result.prefix_cost = prefix_cost
	result.suffix_cost = suffix_cost
	path_builds++
	if(start == finish)
		result.hops = list(start.address)
	else
		var/datum/netrun_path_tree/tree
		if(root == destination)
			result.hops = list(root.address)
		else
			tree = path_tree(graph, root, TRUE)
			result.hops = tree.addresses_to(destination.address)
		if(length(result.hops))
			if(root != start)
				result.hops.Insert(1, start.address)
			if(destination != finish)
				result.hops += finish.address
			result.latency = prefix_cost + (tree ? tree.cost_to(destination.address) : 0) + suffix_cost
			if(!path_available(graph, result.hops))
				// Never cache a stale usable route. The next lookup rebuilds after the
				// discovered native availability change instead of extending its lifetime.
				reconcile_path(graph, result.hops)
				qdel(result)
				return null
	result.geometry_revision = graph.infrastructure_revision
	result.transit_revision = graph.transit_availability_revision
	store_pair_route(key, result)
	return length(result.hops) ? result : null

/datum/netrun_machine_transport/proc/path_available(datum/netrun_topology/graph, list/path)
	for(var/i in 2 to length(path))
		if(!netrun_link_available(graph.nodes[path[i - 1]], graph.nodes[path[i]]))
			return FALSE
	return TRUE

/datum/netrun_machine_transport/proc/reconcile_path(datum/netrun_topology/graph, list/path)
	for(var/address in path)
		var/datum/component/netrun_node/node = graph.nodes[address]
		if(QDELETED(node))
			continue
		var/online = node.is_online()
		if(node.last_online != online)
			node.notify_changed(NETRUN_CHANGED_STATE)

/datum/netrun_machine_transport/proc/dispatch(datum/netrun_machine_service/source, datum/netrun_machine_service/target, datum/netrun_machine_message/message)
	if(QDELETED(message))
		return FALSE
	var/contract_key = message.coalescing_key()
	var/key
	if(!isnull(contract_key) && !QDELETED(source) && !QDELETED(target))
		// A replaced component/tag creates a distinct delivery context. Never place
		// a new binding's state into a packet admitted for an old recipient tag.
		key = "[source.service_key()]|[source.resolve_node()?.address]|[target.service_key()]|[target.service_tag()]|[contract_key]"
		var/datum/netrun_machine_packet/data/previous = replaceable_packets[key]
		if(!QDELETED(previous) && !previous.finishing)
			message.source = source
			message.recipient = target
			message.correlation_id = previous.operation.operation_id
			qdel(previous.message)
			previous.message = message
			coalesced_packets++
			return TRUE
	var/datum/netrun_machine_packet/data/packet = new(source, target, message)
	if(key)
		packet.replacement_key = key
		replaceable_packets[key] = packet
	return packet.send()

/datum/netrun_machine_transport/proc/record_flow(datum/netrun_machine_service/source, datum/netrun_machine_service/target, kind, list/path)
	// Bound visualization work independently of the number of delivered packets.
	if(world.time >= flow_window)
		flow_window = world.time + 1 SECONDS
		flow_count = 0
	if(flow_count >= 20)
		return
	var/from = source.resolve_node()?.address
	var/destination = target.resolve_node()?.address
	if(!from || !destination || from == destination)
		return
	var/pair = "[from]>[destination]"
	if(last_flow[pair] > world.time)
		return
	if(length(last_flow) > 2048)
		last_flow.Cut()
	last_flow[pair] = world.time + 1 SECONDS
	flow_count++
	SSnetrun.post_event(kind, from, destination, path)

/// A cancellable packet checks the current route again when its latency elapses.
/datum/netrun_machine_packet
	parent_type = /datum/netrun_delivery
	delivery_kind = "machine_delivery"
	var/datum/netrun_machine_service/source
	var/datum/netrun_machine_service/recipient
	var/finishing = FALSE
	var/kind = "machine"
	var/list/interest_route
	var/packet_id
	var/source_address
	var/destination_address
	var/datum/netrun_packet_context/operation
	var/sent_at
	var/due_at

/datum/netrun_machine_packet/New(datum/netrun_machine_service/source, datum/netrun_machine_service/recipient, operation_id)
	src.source = source
	src.recipient = recipient
	source_address = source?.resolve_node()?.address
	destination_address = recipient?.resolve_node()?.address
	operation = new(kind, kind == "dns" ? "Обнаружение службы DNS" : "Обмен между машинами",
		source_address, destination_address, recipient?.service_id, operation_id = operation_id)
	packet_id = operation.id

/datum/netrun_machine_packet/Destroy()
	cancel_delivery()
	SSnetrun.get_machine_transport().packets -= src
	SSnetrun.get_machine_transport().interactive_packets -= src
	QDEL_NULL(operation)
	interest_route = null
	source = null
	recipient = null
	return ..()

/datum/netrun_machine_packet/proc/send()
	var/datum/netrun_machine_transport/transport = SSnetrun.get_machine_transport()
	if(finishing || delivery_queued || timer_id || (src in transport.packets))
		return FALSE
	if(length(transport.packets) >= NETRUN_MAX_MACHINE_PACKETS)
		fail("очередь транспортных пакетов переполнена")
		return FALSE
	var/datum/netrun_route/route = transport.route(source, recipient, communication_policy(), communication_frequency())
	if(!route)
		qdel(route)
		fail("нет сетевого маршрута")
		return FALSE
	transport.packets |= src
	operation.queued(route.hops)
	var/mob/user = interest_user()
	var/mob/camera/netrun_entity/entity = user
	if(user?.client || (istype(entity) && entity.dive_link?.body?.client))
		interest_route = route.hops.Copy()
		transport.interactive_packets |= src
		SSnetrun.retain_route_interest(interest_route, world.time + NETRUN_NODE_INTEREST_LEASE)
	var/delay = clamp(route.latency * NETRUN_MACHINE_LATENCY_SCALE, 0, NETRUN_MACHINE_MAX_LATENCY)
	// Scaled local hops are shorter than one representable world tick. Admit
	// them asynchronously to MC directly instead of adding a timer tick and a
	// second dispatch tick at every native telecomms/DNS stage.
	if(delay < world.tick_lag)
		delay = 0
	sent_at = world.time
	due_at = world.time + delay
	qdel(route)
	return schedule_delivery(delay)

/datum/netrun_machine_packet/can_queue_delivery()
	return !finishing

/// DNS explicitly carries its caller's restricted policy; arbitrary data never opts in.
/datum/netrun_machine_packet/proc/communication_policy()
	return FALSE

/datum/netrun_machine_packet/proc/communication_frequency()
	return null

/datum/netrun_machine_packet/deliver()
	set waitfor = FALSE
	cancel_delivery()
	if(finishing)
		return
	var/datum/netrun_route/route = SSnetrun.get_machine_transport().route(source, recipient, communication_policy(), communication_frequency())
	if(!route)
		fail("маршрут разорван")
		return
	finishing = TRUE
	SSnetrun.get_machine_transport().trace_delivery(src)
	destination_address = route.hops[length(route.hops)]
	operation.running()
	operation.receive(route.hops)
	SSnetrun.get_machine_transport().record_flow(source, recipient, kind, route.hops)
	qdel(route)
	execute()
	if(!operation.finished)
		operation.finish("completed")
	qdel(src)

/datum/netrun_machine_packet/proc/execute()
	return

/datum/netrun_machine_packet/proc/interest_user()
	return null

/datum/netrun_machine_packet/proc/journal(address, phase, reason)
	operation.journal(address, phase, reason)

/datum/netrun_machine_packet/proc/fail(reason)
	if(finishing)
		return
	finishing = TRUE
	operation.finish(operation.sent ? "cancelled" : "rejected", reason, source_address)
	qdel(src)

/datum/netrun_machine_packet/data
	var/datum/netrun_machine_message/message
	var/recipient_tag
	var/replacement_key

/datum/netrun_machine_packet/data/New(datum/netrun_machine_service/source, datum/netrun_machine_service/recipient, datum/netrun_machine_message/message)
	..(source, recipient, message.correlation_id)
	src.message = message
	message.source = source
	message.recipient = recipient
	message.correlation_id = operation.operation_id
	recipient_tag = recipient?.service_tag()

/datum/netrun_machine_packet/data/Destroy()
	var/datum/netrun_machine_transport/transport = SSnetrun.get_machine_transport()
	if(replacement_key && transport.replaceable_packets[replacement_key] == src)
		transport.replaceable_packets -= replacement_key
	replacement_key = null
	QDEL_NULL(message)
	return ..()

/datum/netrun_machine_packet/data/interest_user()
	return message.user_ref?.resolve()

/datum/netrun_machine_packet/data/delivery_priority()
	return message.delivery_priority()

/datum/netrun_machine_packet/data/communication_policy()
	return netrun_communication_policy(source, recipient?.service_id) && (istype(message, /datum/netrun_machine_message/telecomms) || istype(message, /datum/netrun_machine_message/communications))

/datum/netrun_machine_packet/data/communication_frequency()
	var/datum/netrun_machine_message/telecomms/packet = message
	return istype(packet) ? packet.signal?.frequency : null

/datum/netrun_machine_packet/data/execute()
	if(recipient.matches(source, recipient_tag) && recipient.accepts(message) && recipient.receive(message))
		operation.finish("completed")
		message.delivered(recipient)
	else
		var/reason = recipient.rejection_reason(message)
		operation.finish("rejected", reason)
		message.failed(reason)

/datum/netrun_machine_packet/data/fail(reason)
	if(!finishing)
		message?.failed(reason)
	return ..()

/// One in-flight query per service/tag coalesces telemetry without repeating commands.
/datum/netrun_machine_resolution
	var/datum/netrun_machine_service/source
	var/destination_id
	var/recipient_tag
	var/query_key
	var/list/queued = list()
	var/list/records = list()
	var/records_revision
	var/datum/netrun_machine_service/resolver
	var/timer_id
	var/attempts = 0
	var/next_attempt_at = 0
	var/completed = FALSE
	var/failure_reason = "DNS: запрос отменён"
	var/query_id
	var/operation_id
	var/deadline = 0
	var/attempt_generation = 0
	var/list/tried_resolvers = list()
	var/datum/weakref/active_packet_ref
	var/communications = FALSE

/datum/netrun_machine_resolution/New(datum/netrun_machine_service/source, destination_id, recipient_tag)
	src.source = source
	src.destination_id = destination_id
	src.recipient_tag = recipient_tag
	communications = netrun_communication_policy(source, destination_id)
	query_key = "[destination_id]|[recipient_tag]"
	query_id = ++SSnetrun.get_machine_transport().packet_serial
	operation_id = "discovery-[query_id]"

/datum/netrun_machine_resolution/Destroy()
	active_packet_ref = null
	SSnetrun.get_machine_transport().waiting_resolutions -= src
	if(timer_id)
		deltimer(timer_id)
	if(source?.resolutions[query_key] == src)
		source.resolutions -= query_key
	var/list/abandoned = queued.Copy()
	if(length(abandoned) && !QDELETED(source))
		var/datum/component/netrun_node/node = source.resolve_node()
		if(!QDELETED(node))
			node.add_packet_log(query_id, "DNS_FAIL", "dns", node.address, resolver?.resolve_node()?.address, destination_id, failure_reason, operation_id)
	SSnetrun.get_machine_transport().queued_messages -= length(queued)
	queued.Cut()
	for(var/datum/netrun_machine_message/message as anything in abandoned)
		message.failed(failure_reason)
		qdel(message)
	records.Cut()
	source = null
	resolver = null
	return ..()

/datum/netrun_machine_resolution/proc/enqueue(datum/netrun_machine_message/message)
	if(!message.correlation_id)
		message.correlation_id = operation_id
	var/coalescing_key = message.coalescing_key()
	if(!completed && !isnull(coalescing_key))
		for(var/i in 1 to length(queued))
			var/datum/netrun_machine_message/previous = queued[i]
			if(previous.coalescing_key() == coalescing_key)
				queued[i] = message
				qdel(previous)
				return TRUE
	var/datum/netrun_machine_transport/transport = SSnetrun.get_machine_transport()
	if(length(queued) >= 64 || completed || transport.queued_messages >= 4096)
		message.failed("очередь DNS заполнена")
		qdel(message)
		return FALSE
	queued += message
	transport.queued_messages++
	return TRUE

/datum/netrun_machine_resolution/proc/begin()
	if(timer_id)
		deltimer(timer_id)
	timer_id = null
	var/datum/netrun_machine_transport/transport = SSnetrun.get_machine_transport()
	if(!transport.is_ready())
		transport.waiting_resolutions |= src
		timer_id = addtimer(CALLBACK(src, PROC_REF(begin)), 1 SECONDS, TIMER_STOPPABLE | TIMER_DELETE_ME)
		return
	if(QDELETED(source) || QDELETED(source.host))
		failure_reason = "DNS: источник недоступен"
		qdel(src)
		return
	if(!deadline)
		deadline = world.time + NETRUN_DNS_TIMEOUT
	if(world.time >= deadline || attempts >= NETRUN_DNS_MAX_ATTEMPTS)
		failure_reason = "DNS: исчерпан срок или лимит попыток обнаружения"
		qdel(src)
		return
	var/list/servers = SSnetrun.get_machine_transport().lookup(source, "dns", null, communications)
	var/datum/netrun_machine_service/next_resolver
	for(var/datum/netrun_machine_service/candidate as anything in servers)
		if(!(REF(candidate) in tried_resolvers))
			next_resolver = candidate
			break
	if(length(servers) && !next_resolver)
		failure_reason = "DNS: доступные резервные серверы уже проверены"
		qdel(src)
		return
	if(!next_resolver)
		failure_reason = length(transport.by_id["dns"]) ? "DNS: сервер выключен или нет физического маршрута" : "DNS: сервер не зарегистрирован в сети"
		// Readiness events can probe immediately, but cannot spend the timed retry
		// budget repeatedly while unrelated initialization/power signals arrive.
		if(world.time >= next_attempt_at)
			next_attempt_at = world.time + 2 SECONDS
			if(++attempts >= NETRUN_DNS_MAX_ATTEMPTS)
				qdel(src)
				return
		transport.waiting_resolutions |= src
		timer_id = addtimer(CALLBACK(src, PROC_REF(begin)), max(world.tick_lag, next_attempt_at - world.time), TIMER_STOPPABLE | TIMER_DELETE_ME)
		return
	transport.waiting_resolutions -= src
	resolver = next_resolver
	tried_resolvers |= REF(resolver)
	attempts++
	attempt_generation++
	timer_id = addtimer(CALLBACK(src, PROC_REF(attempt_expired), attempt_generation), min(NETRUN_DNS_ATTEMPT_TIMEOUT, deadline - world.time), TIMER_STOPPABLE | TIMER_DELETE_ME)
	var/datum/netrun_machine_packet/dns_query/packet = new(source, resolver, src)
	active_packet_ref = WEAKREF(packet)
	packet.send()

/datum/netrun_machine_resolution/proc/is_current(generation)
	return !completed && generation == attempt_generation && !QDELETED(src)

/datum/netrun_machine_resolution/proc/attempt_expired(generation)
	if(!is_current(generation))
		return
	timer_id = null
	retry("истёк срок ответа выбранного DNS", generation)

/// Failover is discovery-only: no already-executed machine command is retried.
/datum/netrun_machine_resolution/proc/retry(reason, generation)
	if(!is_current(generation))
		return
	attempt_generation++
	if(timer_id)
		deltimer(timer_id)
	timer_id = null
	var/datum/netrun_machine_packet/dns_query/previous = active_packet_ref?.resolve()
	active_packet_ref = null
	if(!QDELETED(previous))
		previous.abandon_attempt(reason)
	failure_reason = "DNS: [reason]"
	var/list/alternatives = SSnetrun.get_machine_transport().lookup(source, "dns", null, communications)
	var/has_alternative = FALSE
	for(var/datum/netrun_machine_service/candidate as anything in alternatives)
		if(!(REF(candidate) in tried_resolvers))
			has_alternative = TRUE
			break
	if(!has_alternative || attempts >= NETRUN_DNS_MAX_ATTEMPTS || world.time >= deadline)
		qdel(src)
		return
	// Defer until unregister/power callbacks have unwound; no recursive send chain.
	timer_id = addtimer(CALLBACK(src, PROC_REF(begin)), world.tick_lag, TIMER_STOPPABLE | TIMER_DELETE_ME)

/datum/netrun_machine_resolution/proc/answer(generation)
	if(!is_current(generation))
		return
	if(QDELETED(source) || QDELETED(resolver))
		qdel(src)
		return
	records = SSnetrun.get_machine_transport().lookup(source, destination_id, recipient_tag, communications)
	records_revision = SSnetrun.get_machine_transport().service_revisions[destination_id]
	var/datum/netrun_machine_packet/dns_reply/packet = new(resolver, source, src)
	active_packet_ref = WEAKREF(packet)
	packet.send()

/datum/netrun_machine_resolution/proc/finish(generation)
	if(!is_current(generation))
		return
	completed = TRUE
	var/datum/netrun_machine_directory/entry = new
	entry.resolver_ref = WEAKREF(resolver)
	entry.expires = world.time + (length(records) ? 30 SECONDS : 2 SECONDS)
	entry.revision = records_revision
	for(var/datum/netrun_machine_service/target as anything in records)
		if(!QDELETED(target))
			entry.records += WEAKREF(target)
	qdel(source.directory[query_key])
	if(!(query_key in source.directory) && length(source.directory) >= 128)
		var/oldest = source.directory[1]
		qdel(source.directory[oldest])
		source.directory -= oldest
	source.directory[query_key] = entry
	source.resolutions -= query_key
	var/list/messages = queued.Copy()
	SSnetrun.get_machine_transport().queued_messages -= length(queued)
	queued.Cut()
	for(var/datum/netrun_machine_message/message as anything in messages)
		source.send_resolved(destination_id, message, recipient_tag, entry)
	source.directory_ready(destination_id, recipient_tag)
	qdel(src)

/datum/netrun_machine_packet/dns_query
	kind = "dns"
	var/datum/netrun_machine_resolution/query
	var/query_generation

/datum/netrun_machine_packet/dns_query/New(datum/netrun_machine_service/source, datum/netrun_machine_service/recipient, datum/netrun_machine_resolution/query)
	..(source, recipient, query.operation_id)
	src.query = query
	query_generation = query.attempt_generation
	RegisterSignal(query, COMSIG_PARENT_QDELETING, PROC_REF(query_deleted))

/datum/netrun_machine_packet/dns_query/proc/query_deleted()
	SIGNAL_HANDLER
	if(!finishing)
		fail("DNS-запрос отменён")

/datum/netrun_machine_packet/dns_query/Destroy()
	if(query)
		UnregisterSignal(query, COMSIG_PARENT_QDELETING)
	query = null
	return ..()

/datum/netrun_machine_packet/dns_query/execute()
	if(!QDELETED(query))
		query.answer(query_generation)

/datum/netrun_machine_packet/dns_query/communication_policy()
	return query?.communications

/// A retired attempt cannot call back into the new resolver generation.
/datum/netrun_machine_packet/dns_query/proc/abandon_attempt(reason)
	if(query)
		UnregisterSignal(query, COMSIG_PARENT_QDELETING)
		query = null
	fail(reason)

/datum/netrun_machine_packet/dns_query/fail(reason)
	if(finishing)
		return
	// Deleting the query emits the cancellation signal synchronously. Detach first
	// so packet failure cannot recursively delete the same query during its Destroy.
	var/datum/netrun_machine_resolution/pending = query
	if(pending)
		UnregisterSignal(pending, COMSIG_PARENT_QDELETING)
		query = null
	if(!QDELETED(pending))
		if(pending.active_packet_ref?.resolve() == src)
			pending.active_packet_ref = null
		pending.retry(reason, query_generation)
	return ..()

/datum/netrun_machine_packet/dns_reply
	parent_type = /datum/netrun_machine_packet/dns_query

/datum/netrun_machine_packet/dns_reply/execute()
	if(!QDELETED(query))
		query.finish(query_generation)
