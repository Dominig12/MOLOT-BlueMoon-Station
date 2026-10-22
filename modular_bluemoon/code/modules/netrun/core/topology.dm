/// Native linked floors form one physical sector. Never mutate mapping's shared stack cache.
/proc/netrun_sector_for(turf/position)
	if(!position)
		return null
	var/min_z = position.z
	for(var/z in SSmapping.get_connected_levels(position.z))
		min_z = min(min_z, z)
	return "sector:[min_z]"

/// Physical distance determines endpoint binding, APC neighbors, and cable latency.
/proc/netrun_topology_distance(turf/first, turf/second)
	if(!first || !second)
		return INFINITY
	var/list/levels = SSmapping.get_connected_levels(first.z)
	var/first_floor = levels.Find(first.z)
	var/second_floor = levels.Find(second.z)
	var/floor_distance = first_floor && second_floor ? abs(first_floor - second_floor) : abs(first.z - second.z)
	return max(abs(first.x - second.x), abs(first.y - second.y), floor_distance)

/// Cached structural graph. Online state is deliberately absent: routing validates it live.
/datum/netrun_topology
	var/list/nodes = list()
	var/list/adjacency = list()
	var/list/edges = list()
	var/list/edge_lookup = list()
	var/dirty = TRUE
	var/rebuilding = FALSE
	var/revision = 0
	var/deferred_bindings = FALSE
	var/infrastructure_revision = 0
	var/indexed_revision = -1
	var/list/apcs_by_sector = list()
	var/list/relay_addresses = list()
	var/list/nearest_by_turf = list()
	/// Moving an endpoint updates route costs without replacing its structural parent.
	var/weight_revision = 0
	/// Forwarding availability changes independently from graph geometry and occupancy.
	var/availability_revision = 0
	/// Only forwarding nodes can change visibility beyond their own marker.
	var/transit_availability_revision = 0
	var/backbone_disabled

/datum/netrun_topology/proc/availability_changed(datum/component/netrun_node/node)
	availability_revision++
	if(is_infrastructure(node) || length(adjacency[node.address]) > 1)
		transit_availability_revision++

/datum/netrun_topology/proc/invalidate()
	dirty = TRUE

/datum/netrun_topology/proc/infrastructure_changed()
	infrastructure_revision++
	nearest_by_turf.Cut()
	invalidate()

/// Drop strong cache references immediately; an unopened map must not retain deleted nodes.
/datum/netrun_topology/proc/forget_node(datum/component/netrun_node/node)
	if(!node)
		return
	nodes -= node.address
	adjacency -= node.address
	for(var/address in adjacency)
		var/list/connected = adjacency[address]
		connected -= node.address
	if(is_infrastructure(node))
		infrastructure_changed()
	else
		invalidate()
	if(node.node_type != NETRUN_NODE_APC)
		return
	for(var/address in SSnetrun.nodes_by_address)
		var/datum/component/netrun_node/dependent = SSnetrun.nodes_by_address[address]
		if(dependent.bound_apc == node)
			dependent.bound_apc = null
			dependent.binding_infra_revision = -1
			dependent.join_network()

/datum/netrun_topology/proc/is_relay(datum/component/netrun_node/node)
	return node && istype(node.parent, /obj/machinery/ntnet_relay)

/datum/netrun_topology/proc/is_infrastructure(datum/component/netrun_node/node)
	return node && (node.node_type == NETRUN_NODE_APC || is_relay(node))

/// A mapped APC may be mounted outside the area it actually supplies.
/datum/netrun_topology/proc/apc_area(datum/component/netrun_node/node)
	var/area/room
	if(istype(node?.parent, /obj/machinery/power/apc))
		var/obj/machinery/power/apc/apc = node.parent
		room = apc.area
	room = room || get_area(node?.parent)
	return room?.base_area || room

/// Allocation and index refresh do not build the graph or call join_network().
/datum/netrun_topology/proc/index_infrastructure()
	if(indexed_revision == infrastructure_revision)
		return
	apcs_by_sector = list()
	relay_addresses = list()
	var/list/addresses = sort_list(SSnetrun.nodes_by_address.Copy())
	for(var/address in addresses)
		var/datum/component/netrun_node/node = SSnetrun.nodes_by_address[address]
		if(QDELETED(node) || QDELETED(node.parent))
			continue
		var/sector = netrun_sector_for(get_turf(node.parent))
		if(!sector)
			continue
		if(node.node_type == NETRUN_NODE_APC)
			var/list/sector_apcs = apcs_by_sector[sector]
			if(!sector_apcs)
				sector_apcs = list()
				apcs_by_sector[sector] = sector_apcs
			sector_apcs += address
		else if(is_relay(node))
			relay_addresses += address
	indexed_revision = infrastructure_revision

/datum/netrun_topology/proc/nearest_apc(turf/position)
	if(!position)
		return null
	index_infrastructure()
	var/sector = netrun_sector_for(position)
	var/area/room = get_area(position)
	var/area/root_area = room?.base_area || room
	// Coordinates avoid keeping replaced turfs alive in a long-lived cache.
	var/cache_key = "[sector]:[REF(root_area)]:[position.x],[position.y],[position.z]"
	if(cache_key in nearest_by_turf)
		return nearest_by_turf[cache_key]
	var/list/candidates = apcs_by_sector[sector]
	var/datum/component/netrun_node/best
	var/best_distance = INFINITY
	var/best_native = FALSE
	// The index is address-sorted, so equal distances have a total, stable tie-break.
	for(var/address in candidates)
		var/datum/component/netrun_node/candidate = SSnetrun.nodes_by_address[address]
		if(QDELETED(candidate) || netrun_sector_for(get_turf(candidate.parent)) != sector)
			continue
		var/distance = netrun_topology_distance(position, get_turf(candidate.parent))
		var/native = apc_area(candidate) == root_area
		if((native && !best_native) || (native == best_native && distance < best_distance))
			best = candidate
			best_distance = distance
			best_native = native
	nearest_by_turf[cache_key] = best
	return best

/// Re-evaluate only a changed binding context, a lost APC, or a formerly empty sector.
/// Existing valid bindings survive added nearer APCs and ordinary movement within their root area.
/datum/netrun_topology/proc/refresh_node(datum/component/netrun_node/node)
	if(QDELETED(node) || QDELETED(node.parent))
		return
	var/turf/position = get_turf(node.parent)
	// Fast path: an already-bound node that has not moved, under unchanged infrastructure,
	// keeps its binding - skip the sector/area/nearest-APC work entirely.
	if(position == node.topology_turf && node.binding_checked && node.binding_infra_revision == infrastructure_revision)
		return
	var/sector = netrun_sector_for(position)
	var/area/room = position ? get_area(position) : null
	var/area/root_area = room?.base_area || room
	// The endpoint stays on its APC while its geographic cable length changes.
	if(!is_infrastructure(node) && node.topology_turf != position)
		node.topology_turf = position
		refresh_node_weights(node)
		node.notify_changed(NETRUN_CHANGED_STATE)
	if(is_infrastructure(node) && (node.topology_turf != position || (node.binding_checked && node.binding_sector != sector)))
		node.topology_turf = position
		infrastructure_changed()
	// Map initialization order must not pin a machine to an early, distant APC.
	// The first normal graph build binds all mapped endpoints after registration.
	if(!node.binding_checked && SSatoms.initialized != INITIALIZATION_INNEW_REGULAR)
		deferred_bindings = TRUE
		return
	var/context_changed = !node.binding_checked || node.binding_area != root_area || node.binding_sector != sector
	var/datum/component/netrun_node/previous = node.bound_apc
	var/valid_binding = !QDELETED(previous) && previous.node_type == NETRUN_NODE_APC && SSnetrun.nodes_by_address[previous.address] == previous && sector && netrun_sector_for(get_turf(previous.parent)) == sector
	if(node.node_type == NETRUN_NODE_APC)
		node.bound_apc = null
	else if(context_changed || (previous && !valid_binding) || (!previous && node.binding_infra_revision != infrastructure_revision))
		node.bound_apc = nearest_apc(position)
	node.binding_checked = TRUE
	node.binding_area = root_area
	node.binding_sector = sector
	node.binding_infra_revision = infrastructure_revision
	if(previous != node.bound_apc)
		if(!rebind_leaf(node))
			invalidate()
		node.notify_changed(NETRUN_CHANGED_BINDING)

/// Changing one endpoint's APC does not change the infrastructure mesh. Update
/// its single edge directly rather than rebuilding every APC pair and endpoint.
/datum/netrun_topology/proc/rebind_leaf(datum/component/netrun_node/node)
	if(dirty || rebuilding || is_infrastructure(node) || nodes[node.address] != node)
		return FALSE
	var/list/neighbors = adjacency[node.address]
	if(length(neighbors) > 1 || (node.bound_apc && nodes[node.bound_apc.address] != node.bound_apc))
		return FALSE
	for(var/neighbor in neighbors)
		var/list/edge = edge_lookup["[node.address]>[neighbor]"]
		edges -= list(edge)
		edge_lookup -= "[node.address]>[neighbor]"
		edge_lookup -= "[neighbor]>[node.address]"
		var/list/peers = adjacency[neighbor]
		peers -= node.address
	adjacency[node.address] = list()
	if(node.bound_apc)
		add_edge(node.address, node.bound_apc.address, "endpoint")
	clear_route_tables()
	revision++
	weight_revision++
	SEND_SIGNAL(SSnetrun, COMSIG_NETRUN_TOPOLOGY_CHANGED, revision)
	return TRUE

/datum/netrun_topology/proc/neighbors(address, include_relays = TRUE)
	var/list/local = adjacency[address] || list()
	if(!include_relays || !(address in relay_addresses))
		return local
	// Quantum connectivity is a bucket, not a quadratic list of materialized edges.
	. = local.Copy()
	for(var/relay_address in relay_addresses)
		if(relay_address != address && nodes[relay_address])
			. += relay_address

/datum/netrun_topology/proc/edge_between(first, second)
	var/list/edge = edge_lookup["[first]>[second]"]
	if(edge)
		return edge
	if(first != second && (first in relay_addresses) && (second in relay_addresses) && nodes[first] && nodes[second])
		var/list/pair = sort_list(list(first, second))
		return list("id" = "relay:[pair[1]]>[pair[2]]", "from" = pair[1], "to" = pair[2], "kind" = "relay", "latency" = NETRUN_RELAY_LATENCY)

/datum/netrun_topology/proc/edge_cost(first, second)
	if(netrun_quantum_link(nodes[first], nodes[second]))
		return NETRUN_RELAY_LATENCY
	var/datum/component/netrun_node/from_node = nodes[first]
	var/datum/component/netrun_node/to_node = nodes[second]
	return max(1, CEILING(netrun_topology_distance(get_turf(from_node?.parent), get_turf(to_node?.parent)) / NETRUN_LINK_TILES_PER_DS, 1))

/datum/netrun_topology/proc/refresh_node_weights(datum/component/netrun_node/node)
	var/changed = FALSE
	var/delta = 0
	var/list/neighbors = adjacency[node.address]
	for(var/neighbor in neighbors)
		var/list/edge = edge_lookup["[node.address]>[neighbor]"]
		var/datum/component/netrun_node/peer = nodes[neighbor]
		var/cost = edge_cost(node.address, neighbor)
		if(edge["latency"] != cost)
			delta = cost - edge["latency"]
			edge["latency"] = cost
			changed = TRUE
		edge["distance"] = netrun_topology_distance(get_turf(node.parent), get_turf(peer.parent))
	if(changed)
		var/previous_geometry = weight_revision
		weight_revision++
		if(!is_infrastructure(node) && length(neighbors) == 1)
			reweight_leaf_routes(node.address, neighbors[1], delta, previous_geometry)

/// All edges are undirected and canonicalized by address, including endpoint bindings.
/datum/netrun_topology/proc/add_edge(first, second, kind)
	if(!first || !second || first == second || !nodes[first] || !nodes[second])
		return
	var/list/pair = sort_list(list(first, second))
	first = pair[1]
	second = pair[2]
	var/list/first_neighbors = adjacency[first]
	if(second in first_neighbors)
		return
	first_neighbors += second
	var/list/second_neighbors = adjacency[second]
	second_neighbors += first
	var/datum/component/netrun_node/from_node = nodes[first]
	var/datum/component/netrun_node/to_node = nodes[second]
	var/list/edge = list("id" = "[kind]:[first]>[second]", "from" = first, "to" = second, "kind" = kind,
		"latency" = edge_cost(first, second), "distance" = netrun_topology_distance(get_turf(from_node.parent), get_turf(to_node.parent)))
	edges += list(edge)
	edge_lookup["[first]>[second]"] = edge
	edge_lookup["[second]>[first]"] = edge

/// Stable distance ordering, then canonical endpoint addresses for equal lengths.
/proc/cmp_netrun_physical_edge(list/first, list/second)
	var/order = first["distance"] - second["distance"]
	if(order)
		return order
	order = sorttext(second["from"], first["from"])
	if(order)
		return order
	return sorttext(second["to"], first["to"])

/datum/netrun_topology/proc/apc_component(list/components, address)
	var/root = address
	while(components[root] != root)
		root = components[root]
	while(address != root)
		var/next = components[address]
		components[address] = root
		address = next
	return root

/// Each APC selects its two nearest peers. Kruskal adds only the shortest
/// bridges between remaining components; no artificial hub or relay is involved.
/datum/netrun_topology/proc/connect_apcs(list/addresses)
	if(length(addresses) < 2)
		return
	// Keep only the K closest pairs for each APC, not every O(N^2) candidate.
	// The union exactly matches the original sorted quota-selection pass.
	var/list/nearest = list()
	var/list/components = list()
	var/list/input_order = list()
	var/list/positions = list()
	var/limit = max(1, NETRUN_APC_NEIGHBORS)
	for(var/i in 1 to length(addresses))
		var/address = addresses[i]
		nearest[address] = list()
		components[address] = address
		input_order[address] = i
		var/datum/component/netrun_node/apc = nodes[address]
		positions[address] = get_turf(apc.parent)
	for(var/i in 1 to length(addresses))
		var/first = addresses[i]
		var/list/first_nearest = nearest[first]
		for(var/j = i + 1, j <= length(addresses), j++)
			var/second = addresses[j]
			var/list/second_nearest = nearest[second]
			var/distance = netrun_topology_distance(positions[first], positions[second])
			var/list/first_worst = length(first_nearest) >= limit ? first_nearest[length(first_nearest)] : null
			var/list/second_worst = length(second_nearest) >= limit ? second_nearest[length(second_nearest)] : null
			if(first_worst && second_worst && distance > first_worst["distance"] && distance > second_worst["distance"])
				continue
			var/list/pair = list("from" = first, "to" = second, "distance" = distance)
			if(!first_worst || cmp_netrun_physical_edge(pair, first_worst) < 0)
				first_nearest += list(pair)
				sortTim(first_nearest, GLOBAL_PROC_REF(cmp_netrun_physical_edge))
				if(length(first_nearest) > limit)
					first_nearest.len = limit
			if(!second_worst || cmp_netrun_physical_edge(pair, second_worst) < 0)
				second_nearest += list(pair)
				sortTim(second_nearest, GLOBAL_PROC_REF(cmp_netrun_physical_edge))
				if(length(second_nearest) > limit)
					second_nearest.len = limit
	// Deduplicate each selected pair and preserve deterministic edge ordering.
	var/list/candidate_pairs = list()
	var/list/seen_pairs = list()
	for(var/address in addresses)
		var/list/listing = nearest[address]
		for(var/list/pair as anything in listing)
			var/key = "[pair["from"]]>[pair["to"]]"
			if(seen_pairs[key])
				continue
			seen_pairs[key] = TRUE
			candidate_pairs += list(pair)
	sortTim(candidate_pairs, GLOBAL_PROC_REF(cmp_netrun_physical_edge))
	for(var/list/pair as anything in candidate_pairs)
		var/first = pair["from"]
		var/second = pair["to"]
		add_edge(first, second, "apc")
		components[apc_component(components, second)] = apc_component(components, first)
	// Join any disconnected clusters using the cheapest next bridge. Every APC
	// enters the connected set only once, so this is O(N^2) time, O(N) memory.
	var/initial_root = apc_component(components, addresses[1])
	var/list/attached = list()
	var/list/unattached = list()
	for(var/address in addresses)
		if(apc_component(components, address) == initial_root)
			attached[address] = TRUE
		else
			unattached[address] = TRUE
	if(!length(unattached))
		return
	var/list/best_bridges = list()
	for(var/from_address in attached)
		for(var/to_address in unattached)
			var/first = input_order[from_address] < input_order[to_address] ? from_address : to_address
			var/second = first == from_address ? to_address : from_address
			var/list/pair = list("from" = first, "to" = second,
				"distance" = netrun_topology_distance(positions[first], positions[second]))
			var/list/current = best_bridges[to_address]
			if(!current || cmp_netrun_physical_edge(pair, current) < 0)
				best_bridges[to_address] = pair
	while(length(unattached))
		var/list/bridge
		for(var/to_address in unattached)
			var/list/candidate = best_bridges[to_address]
			if(!bridge || cmp_netrun_physical_edge(candidate, bridge) < 0)
				bridge = candidate
		if(!bridge)
			break
		add_edge(bridge["from"], bridge["to"], "apc")
		var/new_root = apc_component(components, bridge["to"])
		var/list/just_attached = list()
		for(var/address in unattached)
			if(apc_component(components, address) == new_root)
				just_attached += address
		for(var/address in just_attached)
			unattached -= address
			attached[address] = TRUE
			best_bridges -= address
		for(var/from_address in just_attached)
			for(var/to_address in unattached)
				var/first = input_order[from_address] < input_order[to_address] ? from_address : to_address
				var/second = first == from_address ? to_address : from_address
				var/list/pair = list("from" = first, "to" = second,
					"distance" = netrun_topology_distance(positions[first], positions[second]))
				var/list/current = best_bridges[to_address]
				if(!current || cmp_netrun_physical_edge(pair, current) < 0)
					best_bridges[to_address] = pair

/datum/netrun_topology/proc/rebuild()
	if(rebuilding)
		return
	rebuilding = TRUE
	clear_route_tables()
	nodes = list()
	adjacency = list()
	edges = list()
	edge_lookup = list()
	var/list/addresses = sort_list(SSnetrun.nodes_by_address.Copy())
	// A carrier can move infrastructure without a MOVED signal on the nested machine.
	// Refresh every infrastructure position before any endpoint consults the spatial index.
	var/moved_infrastructure = FALSE
	for(var/address in addresses)
		var/datum/component/netrun_node/node = SSnetrun.nodes_by_address[address]
		if(QDELETED(node) || !is_infrastructure(node))
			continue
		var/turf/position = get_turf(node.parent)
		if(node.topology_turf != position)
			node.topology_turf = position
			moved_infrastructure = TRUE
	if(moved_infrastructure)
		infrastructure_changed()
	// This only refreshes bindings and LANs; neither path calls ensure_topology().
	for(var/address in addresses)
		var/datum/component/netrun_node/node = SSnetrun.nodes_by_address[address]
		if(QDELETED(node) || QDELETED(node.parent))
			continue
		node.join_network()
		nodes[address] = node
		adjacency[address] = list()
	index_infrastructure()
	// Every endpoint has one physical cable to its APC, including personal nodes.
	for(var/address in nodes)
		var/datum/component/netrun_node/node = nodes[address]
		if(!node.bound_apc)
			continue
		add_edge(address, node.bound_apc.address, "endpoint")
	var/list/sectors = sort_list(apcs_by_sector.Copy())
	for(var/sector in sectors)
		connect_apcs(apcs_by_sector[sector])
	// Relay-to-relay transitions are an implicit uniform-cost bucket.
	for(var/address in adjacency)
		adjacency[address] = sort_list(adjacency[address])
	dirty = FALSE
	revision++
	weight_revision++
	deferred_bindings = SSatoms.initialized != INITIALIZATION_INNEW_REGULAR
	rebuilding = FALSE
	SEND_SIGNAL(SSnetrun, COMSIG_NETRUN_TOPOLOGY_CHANGED, revision)

/datum/netrun_topology/Destroy()
	clear_route_tables(TRUE)
	nodes.Cut()
	adjacency.Cut()
	edges.Cut()
	edge_lookup.Cut()
	apcs_by_sector.Cut()
	relay_addresses.Cut()
	nearest_by_turf.Cut()
	return ..()
