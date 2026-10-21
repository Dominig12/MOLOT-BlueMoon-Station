/// Ping, requests and the map consume the same physical node graph.
/datum/netrun_route
	var/list/hops = list()
	var/latency = 0
	var/name = "нет маршрута"

/proc/netrun_quantum_link(datum/component/netrun_node/first, datum/component/netrun_node/second)
	return istype(first?.parent, /obj/machinery/ntnet_relay) && istype(second?.parent, /obj/machinery/ntnet_relay) && first.binding_sector != second.binding_sector

/// A local reboot never causes structural rebinding; only forwarding stops.
/proc/netrun_link_available(datum/component/netrun_node/first, datum/component/netrun_node/second, allow_offline_destination = FALSE)
	if(QDELETED(first) || QDELETED(second) || !first.is_online() || (!allow_offline_destination && !second.is_online()))
		return FALSE
	if(netrun_quantum_link(first, second))
		var/obj/machinery/ntnet_relay/from_relay = first.parent
		var/obj/machinery/ntnet_relay/to_relay = second.parent
		return !SSnetworks.station_network.setting_disabled && from_relay.is_operational() && to_relay.is_operational()
	return TRUE

/// Request-local BFS. UI serialization shares one snapshot; later requests
/// revalidate live APC and relay availability instead of caching working routes.
/datum/netrun_path_tree
	var/datum/component/netrun_node/source
	var/revision = 0
	var/updated_at = 0
	var/list/reached = list()
	var/list/previous = list()
	var/list/costs = list()
	var/list/remote = list()

/datum/netrun_path_tree/New(datum/netrun_topology/graph, datum/component/netrun_node/start)
	source = start
	if(QDELETED(start) || !graph.nodes[start.address])
		return
	var/list/queue = list(start.address)
	reached[start.address] = TRUE
	costs[start.address] = 0
	for(var/i = 1, i <= length(queue), i++)
		var/address = queue[i]
		var/datum/component/netrun_node/current = graph.nodes[address]
		// Offline destinations are leaves: they cannot forward traffic.
		if(QDELETED(current) || !current.is_online())
			continue
		for(var/neighbor in graph.neighbors(address))
			if(reached[neighbor])
				continue
			var/datum/component/netrun_node/next = graph.nodes[neighbor]
			if(QDELETED(next))
				continue
			var/quantum = netrun_quantum_link(current, next)
			if(quantum)
				if(!netrun_link_available(current, next, TRUE))
					continue
				// Quantum relays connect sectors directly. They cannot provide a
				// detour around a broken APC in the source sector via another Z.
				if(remote[address] || next.binding_sector == start.binding_sector)
					continue
			reached[neighbor] = TRUE
			previous[neighbor] = address
			costs[neighbor] = costs[address] + (quantum ? 3 : 1)
			remote[neighbor] = remote[address] || quantum
			queue += neighbor

/datum/netrun_path_tree/proc/addresses_to(address)
	var/list/path = list()
	if(!reached[address])
		return path
	while(address)
		path.Insert(1, address)
		address = previous[address]
	return path

/// Return a request-owned copy, never the server's retained routing table.
/datum/netrun_path_tree/proc/copy()
	var/datum/netrun_path_tree/snapshot = new
	snapshot.source = source
	snapshot.revision = revision
	snapshot.updated_at = updated_at
	snapshot.reached = reached.Copy()
	snapshot.previous = previous.Copy()
	snapshot.costs = costs.Copy()
	snapshot.remote = remote.Copy()
	return snapshot

/// Only physical paths are retained. Permissions and command authorization
/// deliberately remain outside this cache and are evaluated for each request.
/datum/netrun_topology
	var/list/route_tables = list()
	var/list/route_used = list()
	var/route_revision = 0
	var/route_refresh_at = -INFINITY

/datum/netrun_topology/proc/clear_route_tables(release_sources = FALSE)
	for(var/address in route_tables)
		qdel(route_tables[address])
	route_tables.Cut()
	if(release_sources)
		route_used.Cut()
	route_refresh_at = -INFINITY

/datum/netrun_topology/proc/store_route_table(datum/component/netrun_node/start)
	var/datum/netrun_path_tree/table = new(src, start)
	table.revision = ++route_revision
	table.updated_at = world.time
	qdel(route_tables[start.address])
	route_tables[start.address] = table
	return table

/// SSnetrun refreshes active routes once per subsystem interval. A source
/// unused for two intervals expires, so hidden maps do not keep doing BFS.
/datum/netrun_topology/proc/refresh_route_tables()
	if(world.time < route_refresh_at)
		return
	route_refresh_at = world.time + SSnetrun.wait
	for(var/address in route_used.Copy())
		var/datum/component/netrun_node/start = nodes[address]
		if(QDELETED(start) || route_used[address] < world.time - 2 * SSnetrun.wait)
			qdel(route_tables[address])
			route_tables -= address
			route_used -= address
			continue
		store_route_table(start)

/datum/netrun_topology/proc/route_snapshot(datum/component/netrun_node/start)
	if(QDELETED(start) || nodes[start.address] != start)
		return new /datum/netrun_path_tree
	route_used[start.address] = world.time
	refresh_route_tables()
	var/datum/netrun_path_tree/table = route_tables[start.address]
	if(!table)
		table = store_route_table(start)
	return table.copy()

/datum/netrun_console/proc/route_source()
	return connection.route_source()

/datum/netrun_connection/proc/route_source()
	if(owner.ui_routes)
		return owner.ui_routes.source
	return owner.physical_route_source()

/datum/netrun_console/proc/physical_route_source()
	return connection.physical_route_source()

/datum/netrun_connection/proc/physical_route_source()
	if(jack && owner.jack_valid())
		return owner.refresh_route_node(jack)
	var/datum/component/netrun_node/source = owner.refresh_route_node(netrun_find_node(owner.host))
	if(source)
		return source
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	return graph.nearest_apc(get_turf(owner.host))

/datum/netrun_console/entity/physical_route_source()
	var/mob/camera/netrun_entity/entity = host
	return refresh_route_node(entity?.host_node)

/// Nested items can cross an area with their carrier without receiving MOVED.
/datum/netrun_console/proc/refresh_route_node(datum/component/netrun_node/node)
	return connection.refresh_route_node(node)

/datum/netrun_connection/proc/refresh_route_node(datum/component/netrun_node/node)
	if(QDELETED(node) || QDELETED(node.parent))
		return null
	var/datum/netrun_network/previous = node.network
	node.join_network()
	if(previous != node.network)
		owner.network_level_cache?.Cut()
	return node

/datum/netrun_console/proc/path_tree()
	return connection.path_tree()

/datum/netrun_connection/proc/path_tree()
	if(owner.ui_routes)
		return owner.ui_routes
	return owner.make_path_tree()

/// Explicit request trees are local variables, so concurrent yielding device
/// operations cannot borrow another request's path or an old UI snapshot.
/datum/netrun_console/proc/make_path_tree(use_stored_routes = FALSE)
	return connection.make_path_tree(use_stored_routes)

/datum/netrun_connection/proc/make_path_tree(use_stored_routes = FALSE)
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	var/datum/component/netrun_node/start = owner.physical_route_source()
	// A source can move its nested node while being resolved.
	graph = SSnetrun.ensure_topology()
	var/datum/netrun_path_tree/tree = use_stored_routes ? graph.route_snapshot(start) : new(graph, start)
	var/turf/here = get_turf(owner.host)
	if(wireless && owner.origin != NETRUN_ORIGIN_ENTITY && !owner.jack_valid() && (!here || (!is_station_level(here.z) && !is_mining_level(here.z))))
		tree.reached.Cut()
		if(start && start == netrun_find_node(owner.host))
			tree.reached[start.address] = TRUE
	return tree

/datum/netrun_console/proc/release_path_tree(datum/netrun_path_tree/tree)
	return connection.release_path_tree(tree)

/datum/netrun_connection/proc/release_path_tree(datum/netrun_path_tree/tree)
	if(tree != owner.ui_routes)
		qdel(tree)

/datum/netrun_console/proc/route_to(datum/component/netrun_node/node, datum/netrun_path_tree/tree)
	return connection.route_to(node, tree)

/datum/netrun_connection/proc/route_to(datum/component/netrun_node/node, datum/netrun_path_tree/tree)
	var/datum/netrun_route/route = new
	node = owner.refresh_route_node(node)
	if(!node)
		return route
	var/owns_tree = !tree
	if(owns_tree)
		tree = owner.path_tree()
	var/list/addresses = tree.addresses_to(node.address)
	if(!length(addresses))
		route.latency = 3
		if(owns_tree)
			owner.release_path_tree(tree)
		return route
	for(var/address in addresses)
		route.hops += list(list("kind" = "node", "ref" = address))
	if(length(addresses) == 1)
		route.name = "прямое подключение"
	else
		route.name = tree.remote[node.address] ? "через реле NTnet" : "цепочка APC"
		route.latency = tree.costs[node.address] + (wireless && owner.origin != NETRUN_ORIGIN_ENTITY && !owner.jack_valid() ? 1 : 0)
		if(owner.daemon_bonus("overclock"))
			route.latency = max(1, round(route.latency / 3))
	if(owns_tree)
		owner.release_path_tree(tree)
	return route
