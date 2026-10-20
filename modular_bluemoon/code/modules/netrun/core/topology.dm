/// Native linked floors form one physical sector. Never mutate mapping's shared stack cache.
/proc/netrun_sector_for(turf/position)
	if(!position)
		return null
	var/min_z = position.z
	for(var/z in SSmapping.get_connected_levels(position.z))
		min_z = min(min_z, z)
	return "sector:[min_z]"

/// Geometry is used only when binding a new endpoint or rebuilding infrastructure.
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
	var/dirty = TRUE
	var/rebuilding = FALSE
	var/infrastructure_revision = 0
	var/indexed_revision = -1
	var/list/apcs_by_sector = list()
	var/list/relay_addresses = list()
	var/list/nearest_by_turf = list()

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
	// Coordinates avoid keeping replaced turfs alive in a long-lived cache.
	var/cache_key = "[sector]:[position.x],[position.y],[position.z]"
	if(cache_key in nearest_by_turf)
		return nearest_by_turf[cache_key]
	var/list/candidates = apcs_by_sector[sector]
	var/datum/component/netrun_node/best
	var/best_distance = INFINITY
	// The index is address-sorted, so equal distances have a total, stable tie-break.
	for(var/address in candidates)
		var/datum/component/netrun_node/candidate = SSnetrun.nodes_by_address[address]
		if(QDELETED(candidate) || netrun_sector_for(get_turf(candidate.parent)) != sector)
			continue
		var/distance = netrun_topology_distance(position, get_turf(candidate.parent))
		if(distance < best_distance)
			best = candidate
			best_distance = distance
	nearest_by_turf[cache_key] = best
	return best

/// Re-evaluate only a changed binding context, a lost APC, or a formerly empty sector.
/// Existing valid bindings survive added nearer APCs and ordinary movement within their root area.
/datum/netrun_topology/proc/refresh_node(datum/component/netrun_node/node)
	if(QDELETED(node) || QDELETED(node.parent))
		return
	var/turf/position = get_turf(node.parent)
	var/sector = netrun_sector_for(position)
	var/area/room = position ? get_area(position) : null
	var/area/root_area = room?.base_area || room
	if(is_infrastructure(node) && node.topology_turf != position)
		node.topology_turf = position
		infrastructure_changed()
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
		invalidate()

/datum/netrun_topology/proc/neighbors(address)
	return adjacency[address] || list()

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
	edges += list(list("id" = "[kind]:[first]>[second]", "from" = first, "to" = second, "kind" = kind))

/// Deterministic Prim tree per sector: exactly N-1 APC links, including offline infrastructure.
/datum/netrun_topology/proc/connect_apcs(list/addresses)
	if(length(addresses) < 2)
		return
	var/list/joined = list(addresses[1])
	var/list/pending = addresses.Copy(2)
	while(length(pending))
		var/best_from
		var/best_to
		var/best_distance = INFINITY
		// Both sets stay sorted. Loop order resolves all equal-distance ties deterministically.
		for(var/from_address in joined)
			var/datum/component/netrun_node/from_node = nodes[from_address]
			for(var/to_address in pending)
				var/datum/component/netrun_node/to_node = nodes[to_address]
				var/distance = netrun_topology_distance(get_turf(from_node.parent), get_turf(to_node.parent))
				if(distance < best_distance)
					best_distance = distance
					best_from = from_address
					best_to = to_address
		if(!best_to)
			break
		add_edge(best_from, best_to, "apc")
		pending -= best_to
		joined += best_to
		joined = sort_list(joined)

/datum/netrun_topology/proc/rebuild()
	if(rebuilding)
		return
	rebuilding = TRUE
	nodes = list()
	adjacency = list()
	edges = list()
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
	for(var/address in nodes)
		var/datum/component/netrun_node/node = nodes[address]
		if(node.bound_apc)
			add_edge(address, node.bound_apc.address, "endpoint")
	var/list/sectors = sort_list(apcs_by_sector.Copy())
	for(var/sector in sectors)
		connect_apcs(apcs_by_sector[sector])
	for(var/i in 1 to length(relay_addresses))
		var/from_address = relay_addresses[i]
		var/datum/component/netrun_node/from_node = nodes[from_address]
		for(var/j = i + 1, j <= length(relay_addresses), j++)
			var/to_address = relay_addresses[j]
			var/datum/component/netrun_node/to_node = nodes[to_address]
			if(from_node.binding_sector != to_node.binding_sector)
				add_edge(from_address, to_address, "relay")
	for(var/address in adjacency)
		adjacency[address] = sort_list(adjacency[address])
	dirty = FALSE
	rebuilding = FALSE

/datum/netrun_topology/Destroy()
	nodes.Cut()
	adjacency.Cut()
	edges.Cut()
	apcs_by_sector.Cut()
	relay_addresses.Cut()
	nearest_by_turf.Cut()
	return ..()
