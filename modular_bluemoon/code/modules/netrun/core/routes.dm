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
			if(!netrun_link_available(current, next, TRUE))
				continue
			var/quantum = netrun_quantum_link(current, next)
			if(quantum)
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
	. = list()
	if(!reached[address])
		return
	while(address)
		.Insert(1, address)
		address = previous[address]

/datum/netrun_console/proc/route_source()
	if(ui_routes)
		return ui_routes.source
	if(jack && jack_valid())
		return refresh_route_node(jack)
	var/datum/component/netrun_node/source = refresh_route_node(netrun_find_node(host))
	if(source)
		return source
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	return graph.nearest_apc(get_turf(host))

/datum/netrun_console/entity/route_source()
	if(ui_routes)
		return ui_routes.source
	var/mob/camera/netrun_entity/entity = host
	return refresh_route_node(entity?.host_node)

/// Nested items can cross an area with their carrier without receiving MOVED.
/datum/netrun_console/proc/refresh_route_node(datum/component/netrun_node/node)
	if(QDELETED(node) || QDELETED(node.parent))
		return null
	var/datum/netrun_network/previous = node.network
	node.join_network()
	if(previous != node.network)
		network_level_cache?.Cut()
	return node

/datum/netrun_console/proc/path_tree()
	if(ui_routes)
		return ui_routes
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	var/datum/component/netrun_node/start = route_source()
	// A source can move its nested node while being resolved.
	graph = SSnetrun.ensure_topology()
	var/datum/netrun_path_tree/tree = new(graph, start)
	var/turf/here = get_turf(host)
	if(wireless && origin != NETRUN_ORIGIN_ENTITY && !jack_valid() && (!here || (!is_station_level(here.z) && !is_mining_level(here.z))))
		tree.reached.Cut()
		if(start && start == netrun_find_node(host))
			tree.reached[start.address] = TRUE
	return tree

/datum/netrun_console/proc/release_path_tree(datum/netrun_path_tree/tree)
	if(tree != ui_routes)
		qdel(tree)

/datum/netrun_console/proc/route_to(datum/component/netrun_node/node)
	var/datum/netrun_route/route = new
	node = refresh_route_node(node)
	if(!node)
		return route
	var/datum/netrun_path_tree/tree = path_tree()
	var/list/addresses = tree.addresses_to(node.address)
	if(!length(addresses))
		route.latency = 3
		release_path_tree(tree)
		return route
	for(var/address in addresses)
		route.hops += list(list("kind" = "node", "ref" = address))
	if(length(addresses) == 1)
		route.name = "прямое подключение"
	else
		route.name = tree.remote[node.address] ? "через реле NTnet" : "цепочка APC"
		route.latency = tree.costs[node.address] + (wireless && origin != NETRUN_ORIGIN_ENTITY && !jack_valid() ? 1 : 0)
		if(daemon_bonus("overclock"))
			route.latency = max(1, round(route.latency / 3))
	release_path_tree(tree)
	return route
