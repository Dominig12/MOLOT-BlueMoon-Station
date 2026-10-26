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

/// Transport borrows the graph's physical cache and retains only its solve diagnostic.
/datum/netrun_machine_transport/proc/path_tree(datum/netrun_topology/graph, datum/component/netrun_node/root, availability_reconciled = FALSE)
	var/builds_before = graph.infrastructure_tree_builds
	var/datum/netrun_path_tree/tree = graph.borrow_infrastructure_tree(root, availability_reconciled)
	tree_builds += graph.infrastructure_tree_builds - builds_before
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


/datum/netrun_machine_transport/proc/reachable(datum/netrun_machine_service/source, datum/netrun_machine_service/recipient, communications)
	if(isnull(communications))
		communications = netrun_communication_policy(source, recipient?.service_id)
	return !!(borrowed_path(source, recipient) || (communications && communication_path(source, recipient)))

