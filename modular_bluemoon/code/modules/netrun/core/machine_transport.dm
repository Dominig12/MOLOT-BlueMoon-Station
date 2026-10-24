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
	return recipient.send_to(source, response)

/datum/netrun_machine_message/proc/failed(reason)
	return

/datum/netrun_machine_message/proc/delivered(datum/netrun_machine_service/recipient_service)
	return

/// Only replaceable state snapshots opt in; commands retain their own delivery.
/datum/netrun_machine_message/proc/coalescing_key()
	return null

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
		var/list/targets = resolve(destination_id, recipient_tag, entry)
		var/admitted = FALSE
		for(var/datum/netrun_machine_service/target as anything in targets)
			admitted = send_to(target, message.copy()) || admitted
		if(!length(targets))
			message.failed("DNS: получатель недоступен")
		qdel(message)
		return admitted
	var/datum/netrun_machine_resolution/query = get_resolution(destination_id, recipient_tag)
	if(!query)
		message.failed("источник недоступен")
		qdel(message)
		return FALSE
	return query.enqueue(message)

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
	if(entry && entry.expires > world.time && entry.revision == SSnetrun.get_machine_transport().service_revisions[destination_id] && can_reach(entry.resolver_ref?.resolve(), FALSE))
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
		if(entry.expires <= world.time || !SSnetrun.get_machine_transport().reachable(src, entry.resolver_ref?.resolve()))
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
	var/route_cache_limit = 1024
	var/pair_serial = 0
	var/path_builds = 0
	var/path_cache_hits = 0
	var/tree_builds = 0

/datum/netrun_machine_transport/New()
	RegisterSignal(SSnetrun, COMSIG_NETRUN_NODE_UNREGISTERED, PROC_REF(node_deleted))
	RegisterSignal(SSatoms, COMSIG_SUBSYSTEM_POST_INITIALIZE, PROC_REF(atoms_initialized))
	RegisterSignal(SSnetrun, COMSIG_NETRUN_NODE_CHANGED, PROC_REF(network_changed))

/datum/netrun_machine_transport/proc/atoms_initialized()
	SIGNAL_HANDLER
	prepare_network()

/datum/netrun_machine_transport/proc/is_ready()
	return bootstrap_complete && !preparing && SSnetrun.initialized && SSatoms.initialized == INITIALIZATION_INNEW_REGULAR

/// Finalize map bindings and names after native Initialize/LateInitialize, before clients run.
/datum/netrun_machine_transport/proc/prepare_network()
	if(preparing || !SSnetrun.initialized || SSatoms.initialized != INITIALIZATION_INNEW_REGULAR)
		return
	preparing = TRUE
	SSnetrun.ensure_station_dns()
	SSnetrun.ensure_topology()
	for(var/key in services.Copy())
		var/datum/netrun_machine_service/service = services[key]
		if(!QDELETED(service))
			index_service(service)
	bootstrap_complete = TRUE
	preparing = FALSE
	wake_resolutions()

/datum/netrun_machine_transport/proc/network_changed(datum/source, datum/component/netrun_node/node, flags)
	SIGNAL_HANDLER
	if(length(waiting_resolutions) && (node.node_type == NETRUN_NODE_APC || istype(node.parent, /obj/machinery/ntnet_relay) || istype(node.parent, /obj/machinery/netrun_server/dns)))
		wake_resolutions()

/// Registration/power restoration wakes pending discovery once, after construction unwinds.
/datum/netrun_machine_transport/proc/wake_resolutions()
	if(length(waiting_resolutions) && !wake_timer)
		wake_timer = addtimer(CALLBACK(src, PROC_REF(resume_resolutions)), world.tick_lag, TIMER_STOPPABLE | TIMER_DELETE_ME)

/datum/netrun_machine_transport/proc/resume_resolutions()
	wake_timer = null
	for(var/datum/netrun_machine_resolution/query as anything in waiting_resolutions.Copy())
		if(!QDELETED(query))
			query.begin()

/datum/netrun_machine_transport/proc/node_deleted(datum/source, datum/component/netrun_node/node)
	SIGNAL_HANDLER
	qdel(route_trees[node.address])
	route_trees -= node.address
	route_used -= node.address

/datum/netrun_machine_transport/Destroy()
	UnregisterSignal(SSnetrun, list(COMSIG_NETRUN_NODE_UNREGISTERED, COMSIG_NETRUN_NODE_CHANGED))
	UnregisterSignal(SSatoms, COMSIG_SUBSYSTEM_POST_INITIALIZE)
	if(wake_timer)
		deltimer(wake_timer)
	QDEL_LIST(packets)
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

/datum/netrun_machine_transport/proc/lookup(datum/netrun_machine_service/source, destination_id, recipient_tag)
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
		if(!QDELETED(target) && target.matches(source, recipient_tag) && reachable(source, target))
			. += target

/datum/netrun_machine_transport/proc/reachable(datum/netrun_machine_service/source, datum/netrun_machine_service/recipient)
	return !!borrowed_path(source, recipient)

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

/datum/netrun_machine_transport/proc/store_pair_route(key, datum/netrun_machine_path/path)
	qdel(pair_routes[key])
	pair_routes -= key
	pair_used -= key
	while(length(pair_routes) >= max(1, route_cache_limit))
		var/oldest
		for(var/candidate in pair_used)
			if(!oldest || pair_used[candidate] < pair_used[oldest])
				oldest = candidate
		qdel(pair_routes[oldest])
		pair_routes -= oldest
		pair_used -= oldest
	pair_routes[key] = path
	pair_used[key] = ++pair_serial

/// Most endpoints have one APC cable. Share one tree at that attachment instead of
/// keeping a station-sized table for each vent, camera and carried computer.
/datum/netrun_machine_transport/proc/path_tree(datum/netrun_topology/graph, datum/component/netrun_node/root, availability_reconciled = FALSE)
	if(!availability_reconciled)
		graph.reconcile_availability()
	var/datum/netrun_path_tree/tree = route_trees[root.address]
	if(!tree || tree.graph_ref?.resolve() != graph || tree.source != root || tree.geometry_revision != graph.infrastructure_revision || tree.transit_availability_revision != graph.transit_availability_revision)
		graph.reconcile_availability(TRUE)
		qdel(tree)
		if(!tree && length(route_trees) >= 64)
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
/datum/netrun_machine_transport/proc/route(datum/netrun_machine_service/source, datum/netrun_machine_service/recipient)
	var/datum/netrun_machine_path/path = borrowed_path(source, recipient)
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
			pair_used[key] = ++pair_serial
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
	var/datum/netrun_machine_packet/data/packet = new(source, target, message)
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
	var/datum/netrun_machine_service/source
	var/datum/netrun_machine_service/recipient
	var/timer_id
	var/finishing = FALSE
	var/kind = "machine"
	var/list/interest_route
	var/packet_id
	var/source_address
	var/destination_address

/datum/netrun_machine_packet/New(datum/netrun_machine_service/source, datum/netrun_machine_service/recipient)
	src.source = source
	src.recipient = recipient
	packet_id = ++SSnetrun.get_machine_transport().packet_serial
	source_address = source?.resolve_node()?.address
	destination_address = recipient?.resolve_node()?.address

/datum/netrun_machine_packet/Destroy()
	if(timer_id)
		deltimer(timer_id)
	SSnetrun.get_machine_transport().packets -= src
	SSnetrun.get_machine_transport().interactive_packets -= src
	interest_route = null
	source = null
	recipient = null
	return ..()

/datum/netrun_machine_packet/proc/send()
	var/datum/netrun_machine_transport/transport = SSnetrun.get_machine_transport()
	var/datum/netrun_route/route = transport.route(source, recipient)
	if(!route || length(transport.packets) >= 2048)
		qdel(route)
		fail("нет сетевого маршрута")
		return FALSE
	transport.packets |= src
	journal(source_address, "SEND")
	var/mob/user = interest_user()
	var/mob/camera/netrun_entity/entity = user
	if(user?.client || (istype(entity) && entity.dive_link?.body?.client))
		interest_route = route.hops.Copy()
		transport.interactive_packets |= src
		SSnetrun.retain_route_interest(interest_route, world.time + NETRUN_NODE_INTEREST_LEASE)
	var/delay = clamp(route.latency * NETRUN_MACHINE_LATENCY_SCALE, world.tick_lag, NETRUN_MACHINE_MAX_LATENCY)
	qdel(route)
	timer_id = addtimer(CALLBACK(src, PROC_REF(deliver)), delay, TIMER_STOPPABLE | TIMER_DELETE_ME)
	return TRUE

/datum/netrun_machine_packet/proc/deliver()
	timer_id = null
	if(finishing)
		return
	var/datum/netrun_route/route = SSnetrun.get_machine_transport().route(source, recipient)
	if(!route)
		fail("маршрут разорван")
		return
	finishing = TRUE
	destination_address = route.hops[length(route.hops)]
	for(var/i in 2 to length(route.hops) - 1)
		journal(route.hops[i], "FORWARD")
	journal(destination_address, "RECEIVE")
	SSnetrun.get_machine_transport().record_flow(source, recipient, kind, route.hops)
	qdel(route)
	execute()
	qdel(src)

/datum/netrun_machine_packet/proc/execute()
	return

/datum/netrun_machine_packet/proc/interest_user()
	return null

/datum/netrun_machine_packet/proc/journal(address, phase, reason)
	var/datum/component/netrun_node/node = SSnetrun.nodes_by_address[address]
	if(!QDELETED(node))
		node.add_packet_log(packet_id, phase, kind, source_address, destination_address, recipient?.service_id, reason)

/datum/netrun_machine_packet/proc/fail(reason)
	if(finishing)
		return
	finishing = TRUE
	journal(source_address, "DROP", reason)
	qdel(src)

/datum/netrun_machine_packet/data
	var/datum/netrun_machine_message/message
	var/recipient_tag

/datum/netrun_machine_packet/data/New(datum/netrun_machine_service/source, datum/netrun_machine_service/recipient, datum/netrun_machine_message/message)
	..(source, recipient)
	src.message = message
	message.source = source
	message.recipient = recipient
	recipient_tag = recipient?.service_tag()

/datum/netrun_machine_packet/data/Destroy()
	QDEL_NULL(message)
	return ..()

/datum/netrun_machine_packet/data/interest_user()
	return message.user_ref?.resolve()

/datum/netrun_machine_packet/data/execute()
	if(recipient.matches(source, recipient_tag) && recipient.accepts(message) && recipient.receive(message))
		journal(destination_address, "ACCEPT")
		message.delivered(recipient)
	else
		var/reason = recipient.rejection_reason(message)
		journal(destination_address, "REJECT", reason)
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

/datum/netrun_machine_resolution/New(datum/netrun_machine_service/source, destination_id, recipient_tag)
	src.source = source
	src.destination_id = destination_id
	src.recipient_tag = recipient_tag
	query_key = "[destination_id]|[recipient_tag]"
	query_id = ++SSnetrun.get_machine_transport().packet_serial

/datum/netrun_machine_resolution/Destroy()
	SSnetrun.get_machine_transport().waiting_resolutions -= src
	if(timer_id)
		deltimer(timer_id)
	if(source?.resolutions[query_key] == src)
		source.resolutions -= query_key
	var/list/abandoned = queued.Copy()
	if(length(abandoned) && !QDELETED(source))
		var/datum/component/netrun_node/node = source.resolve_node()
		if(!QDELETED(node))
			node.add_packet_log(query_id, "DNS_FAIL", "dns", node.address, resolver?.resolve_node()?.address, destination_id, failure_reason)
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
	var/list/servers = SSnetrun.get_machine_transport().lookup(source, "dns", null)
	if(!length(servers))
		failure_reason = length(transport.by_id["dns"]) ? "DNS: сервер выключен или нет физического маршрута" : "DNS: сервер не зарегистрирован в сети"
		// Readiness events can probe immediately, but cannot spend the timed retry
		// budget repeatedly while unrelated initialization/power signals arrive.
		if(world.time >= next_attempt_at)
			next_attempt_at = world.time + 2 SECONDS
			if(++attempts >= 5)
				qdel(src)
				return
		transport.waiting_resolutions |= src
		timer_id = addtimer(CALLBACK(src, PROC_REF(begin)), max(world.tick_lag, next_attempt_at - world.time), TIMER_STOPPABLE | TIMER_DELETE_ME)
		return
	transport.waiting_resolutions -= src
	resolver = servers[1]
	var/datum/netrun_machine_packet/dns_query/packet = new(source, resolver, src)
	packet.send()

/datum/netrun_machine_resolution/proc/answer()
	if(QDELETED(source) || QDELETED(resolver))
		qdel(src)
		return
	records = SSnetrun.get_machine_transport().lookup(source, destination_id, recipient_tag)
	records_revision = SSnetrun.get_machine_transport().service_revisions[destination_id]
	var/datum/netrun_machine_packet/dns_reply/packet = new(resolver, source, src)
	packet.send()

/datum/netrun_machine_resolution/proc/finish()
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
		var/eligible = 0
		for(var/datum/netrun_machine_service/target as anything in records)
			if(!QDELETED(target) && target.matches(source, recipient_tag))
				eligible++
				source.send_to(target, message.copy())
		if(!eligible)
			message.failed("DNS: получатель не найден")
		qdel(message)
	source.directory_ready(destination_id, recipient_tag)
	qdel(src)

/datum/netrun_machine_packet/dns_query
	kind = "dns"
	var/datum/netrun_machine_resolution/query

/datum/netrun_machine_packet/dns_query/New(datum/netrun_machine_service/source, datum/netrun_machine_service/recipient, datum/netrun_machine_resolution/query)
	..(source, recipient)
	src.query = query
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
		query.answer()

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
		pending.failure_reason = "DNS: [reason]"
		qdel(pending)
	return ..()

/datum/netrun_machine_packet/dns_reply
	parent_type = /datum/netrun_machine_packet/dns_query

/datum/netrun_machine_packet/dns_reply/execute()
	if(!QDELETED(query))
		query.finish()
