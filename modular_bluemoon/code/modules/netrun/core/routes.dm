/// Ping, requests and the map consume the same physical node graph.
/datum/netrun_route
	var/list/hops = list()
	var/latency = 0
	var/name = "нет маршрута"

/proc/netrun_quantum_link(datum/component/netrun_node/first, datum/component/netrun_node/second)
	return first != second && istype(first?.parent, /obj/machinery/ntnet_relay) && istype(second?.parent, /obj/machinery/ntnet_relay)

/// A local reboot never causes structural rebinding; only forwarding stops.
/proc/netrun_link_available(datum/component/netrun_node/first, datum/component/netrun_node/second, allow_offline_destination = FALSE)
	if(QDELETED(first) || QDELETED(second) || !first.is_online() || (!allow_offline_destination && !second.is_online()))
		return FALSE
	if(netrun_quantum_link(first, second))
		var/obj/machinery/ntnet_relay/from_relay = first.parent
		var/obj/machinery/ntnet_relay/to_relay = second.parent
		return !SSnetworks.station_network.setting_disabled && from_relay.is_operational() && to_relay.is_operational()
	return TRUE

/// Request-local weighted shortest paths. UI serialization shares one snapshot; later requests
/// revalidate live APC and relay availability instead of caching working routes.
/datum/netrun_path_tree
	var/datum/component/netrun_node/source
	var/revision = 0
	var/updated_at = 0
	var/list/reached = list()
	var/list/previous = list()
	var/list/costs = list()
	var/list/remote = list()
	var/geometry_revision = 0
	var/availability_revision = 0
	/// A flat binary heap avoids one disposable datum for every relaxed endpoint.
	var/list/frontier_addresses = list()
	var/list/frontier_costs = list()
	var/popped_cost = 0

/datum/netrun_path_tree/New(datum/netrun_topology/graph, datum/component/netrun_node/start)
	source = start
	geometry_revision = graph?.weight_revision || 0
	availability_revision = graph?.availability_revision || 0
	if(QDELETED(start) || !graph.nodes[start.address])
		return
	var/list/settled = list()
	var/relays_expanded = FALSE
	reached[start.address] = TRUE
	costs[start.address] = 0
	push_candidate(start.address, 0)
	while(length(frontier_addresses))
		var/address = pop_candidate()
		if(settled[address] || popped_cost != costs[address])
			continue
		settled[address] = TRUE
		var/datum/component/netrun_node/current = graph.nodes[address]
		// Offline destinations are leaves: they cannot forward traffic.
		if(QDELETED(current) || !current.is_online())
			continue
		for(var/neighbor in graph.neighbors(address, FALSE))
			var/datum/component/netrun_node/next = graph.nodes[neighbor]
			if(settled[neighbor] || QDELETED(next) || !netrun_link_available(current, next, TRUE))
				continue
			relax(neighbor, address, costs[address] + graph.cached_edge_cost(address, neighbor), remote[address])
		// Every operational relay can reach every other relay at the same cost.
		// The cheapest settled entry expands this virtual bucket exactly once.
		if(relays_expanded || !graph.is_relay(current))
			continue
		var/obj/machinery/ntnet_relay/relay = current.parent
		if(!relay.is_operational() || SSnetworks.station_network.setting_disabled)
			continue
		relays_expanded = TRUE
		for(var/relay_address in graph.relay_addresses)
			if(relay_address == address || settled[relay_address])
				continue
			var/datum/component/netrun_node/next = graph.nodes[relay_address]
			if(!netrun_link_available(current, next, TRUE))
				continue
			relax(relay_address, address, costs[address] + NETRUN_RELAY_LATENCY, TRUE)
	frontier_addresses.Cut()
	frontier_costs.Cut()

/datum/netrun_path_tree/proc/relax(address, from_address, cost, quantum)
	if(!isnull(costs[address]) && costs[address] <= cost)
		return
	reached[address] = TRUE
	previous[address] = from_address
	costs[address] = cost
	remote[address] = quantum
	push_candidate(address, cost)

/datum/netrun_path_tree/proc/frontier_before(first, second)
	if(frontier_costs[first] != frontier_costs[second])
		return frontier_costs[first] < frontier_costs[second]
	return sorttext(frontier_addresses[first], frontier_addresses[second]) == 1

/datum/netrun_path_tree/proc/push_candidate(address, cost)
	frontier_addresses += address
	frontier_costs += cost
	var/index = length(frontier_addresses)
	while(index > 1)
		var/parent_index = round(index / 2)
		if(!frontier_before(index, parent_index))
			break
		frontier_addresses.Swap(index, parent_index)
		frontier_costs.Swap(index, parent_index)
		index = parent_index

/datum/netrun_path_tree/proc/pop_candidate()
	. = frontier_addresses[1]
	popped_cost = frontier_costs[1]
	var/last = length(frontier_addresses)
	frontier_addresses[1] = frontier_addresses[last]
	frontier_costs[1] = frontier_costs[last]
	frontier_addresses.len--
	frontier_costs.len--
	var/index = 1
	while(index * 2 <= length(frontier_addresses))
		var/child = index * 2
		if(child < length(frontier_addresses) && frontier_before(child + 1, child))
			child++
		if(!frontier_before(child, index))
			break
		frontier_addresses.Swap(index, child)
		frontier_costs.Swap(index, child)
		index = child

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
	snapshot.geometry_revision = geometry_revision
	snapshot.availability_revision = availability_revision
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

/// Unsigned native relay toggles and backbone settings have no common change signal.
/// Their small infrastructure index is reconciled without walking the full graph.
/datum/netrun_topology/proc/reconcile_availability()
	var/disabled = !!SSnetworks.station_network?.setting_disabled
	if(disabled != backbone_disabled)
		backbone_disabled = disabled
		availability_revision++
	for(var/address in relay_addresses)
		var/datum/component/netrun_node/node = nodes[address]
		if(QDELETED(node))
			continue
		var/online = node.is_online()
		if(online != node.last_online)
			node.notify_changed(NETRUN_CHANGED_STATE)

/// Geometry is already maintained by structural/movement signals. Reuse its cached
/// edge weights while solving a tree instead of measuring every cable again.
/datum/netrun_topology/proc/cached_edge_cost(first, second)
	var/list/edge = edge_lookup["[first]>[second]"]
	return edge ? edge["latency"] : edge_cost(first, second)

/// A source unused for two intervals expires. Active tables are rebuilt only after
/// forwarding or geometry changes, rather than unconditionally every second.
/datum/netrun_topology/proc/refresh_route_tables()
	if(world.time < route_refresh_at)
		return
	route_refresh_at = world.time + SSnetrun.wait
	if(length(route_tables))
		reconcile_availability()
	for(var/address in route_used.Copy())
		var/datum/component/netrun_node/start = nodes[address]
		if(QDELETED(start) || route_used[address] < world.time - 2 * SSnetrun.wait)
			qdel(route_tables[address])
			route_tables -= address
			route_used -= address
			continue
		var/datum/netrun_path_tree/table = route_tables[address]
		if(!table || table.geometry_revision != weight_revision || table.availability_revision != availability_revision)
			store_route_table(start)

/datum/netrun_topology/proc/route_snapshot(datum/component/netrun_node/start)
	if(QDELETED(start) || nodes[start.address] != start)
		return new /datum/netrun_path_tree
	route_used[start.address] = world.time
	reconcile_availability()
	refresh_route_tables()
	var/datum/netrun_path_tree/table = route_tables[start.address]
	if(!table || table.geometry_revision != weight_revision || table.availability_revision != availability_revision)
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
