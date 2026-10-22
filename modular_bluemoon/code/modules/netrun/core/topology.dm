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

/// Exact Chebyshev nearest-neighbor index. Z distance only increases XY distance.
#define NETRUN_APC_BUCKET_SIZE 16

/datum/netrun_apc_spatial_index
	var/list/cells = list()
	var/list/positions
	var/list/order = list()
	var/min_x = INFINITY
	var/max_x = -INFINITY
	var/min_y = INFINITY
	var/max_y = -INFINITY

/datum/netrun_apc_spatial_index/New(list/addresses, list/positions_by_address)
	. = ..()
	positions = positions_by_address
	for(var/i in 1 to length(addresses))
		var/address = addresses[i]
		var/turf/point = positions[address]
		if(!point)
			continue
		order[address] = i
		var/cx = round(point.x / NETRUN_APC_BUCKET_SIZE)
		var/cy = round(point.y / NETRUN_APC_BUCKET_SIZE)
		var/key = "[cx]:[cy]"
		var/list/cell = cells[key]
		if(!cell)
			cell = list()
			cells[key] = cell
		cell += address
		min_x = min(min_x, cx)
		max_x = max(max_x, cx)
		min_y = min(min_y, cy)
		max_y = max(max_y, cy)

/datum/netrun_apc_spatial_index/proc/nearest_edges(address)
	var/datum/netrun_apc_neighbor_scan/scan = new(src, address)
	while(!scan.advance())
		continue
	. = scan.best.Copy()
	qdel(scan)

/// Each advance performs at most one cell lookup or one physical distance check.
/datum/netrun_apc_neighbor_scan
	var/datum/netrun_apc_spatial_index/index
	var/address
	var/turf/point
	var/cx
	var/cy
	var/ring = 0
	var/dx = 0
	var/dy = 0
	var/max_ring = 0
	var/list/cell
	var/cell_cursor = 1
	var/list/best = list()
	var/limit = 1
	var/comparisons = 0
	var/done = FALSE

/datum/netrun_apc_neighbor_scan/New(datum/netrun_apc_spatial_index/spatial, source_address)
	. = ..()
	index = spatial
	address = source_address
	point = spatial.positions[address]
	cx = round(point.x / NETRUN_APC_BUCKET_SIZE)
	cy = round(point.y / NETRUN_APC_BUCKET_SIZE)
	limit = max(1, NETRUN_APC_NEIGHBORS)
	max_ring = max(abs(spatial.min_x - cx), abs(spatial.max_x - cx), abs(spatial.min_y - cy), abs(spatial.max_y - cy))

/datum/netrun_apc_neighbor_scan/proc/check_neighbor(other_address)
	if(other_address == address)
		return
	var/turf/other = index.positions[other_address]
	var/first = index.order[address] < index.order[other_address] ? address : other_address
	var/second = first == address ? other_address : address
	var/list/edge = list("from" = first, "to" = second, "distance" = netrun_topology_distance(point, other))
	comparisons++
	if(length(best) >= limit && cmp_netrun_physical_edge(edge, best[length(best)]) >= 0)
		return
	best += list(edge)
	sortTim(best, GLOBAL_PROC_REF(cmp_netrun_physical_edge))
	if(length(best) > limit)
		best.len = limit

/datum/netrun_apc_neighbor_scan/proc/advance()
	if(done)
		return TRUE
	if(cell && cell_cursor <= length(cell))
		check_neighbor(cell[cell_cursor++])
		return FALSE
	cell = null
	if(dx > ring)
		// Outside ring R the XY lower bound is R*BUCKET_SIZE + 1.
		// Strictly larger than the Kth distance also excludes tied candidates.
		if(ring >= max_ring || (length(best) >= limit && best[length(best)]["distance"] <= ring * NETRUN_APC_BUCKET_SIZE))
			done = TRUE
			return TRUE
		ring++
		dx = -ring
		dy = -ring
		return FALSE
	if(abs(dx) == ring || abs(dy) == ring)
		var/key = "[cx + dx]:[cy + dy]"
		cell = index.cells[key]
		cell_cursor = 1
	dy++
	if(dy > ring)
		dx++
		dy = -ring
	return FALSE

/datum/netrun_apc_neighbor_scan/Destroy()
	index = null
	cell = null
	best = null
	return ..()

/// Speculative APC topology construction in bounded work units.
/// Never writes to the published graph. A live route request can still rebuild synchronously.
/datum/netrun_apc_prebuild
	var/datum/netrun_topology/graph
	var/generation
	var/list/sectors
	var/list/sector_apcs = list()
	var/list/captured_positions = list()
	var/list/links_by_sector = list()
	var/sector_index = 1
	var/sector
	var/list/addresses
	var/list/positions
	var/list/input_order
	var/list/nearest
	var/datum/netrun_apc_spatial_index/spatial
	var/datum/netrun_apc_neighbor_scan/active_scan
	var/list/components
	var/list/candidates
	var/list/seen_candidates
	var/select_i = 1
	var/select_j = 1
	var/union_i = 1
	var/group_build_i = 1
	var/list/groups
	var/list/group_order
	var/list/connected
	var/list/bridge
	var/phase = "sector"
	var/pair_i = 1
	var/pair_j = 2
	var/group_i = 2
	var/from_i = 1
	var/to_i = 1
	var/completed = FALSE
	var/comparisons = 0

/datum/netrun_apc_prebuild/New(datum/netrun_topology/owner)
	. = ..()
	graph = owner
	generation = owner.structural_generation
	owner.index_infrastructure()
	sectors = sort_list(owner.apcs_by_sector.Copy())
	for(var/sector_id in sectors)
		var/list/members = owner.apcs_by_sector[sector_id]
		sector_apcs[sector_id] = members.Copy()
		for(var/address in members)
			var/datum/component/netrun_node/node = SSnetrun.nodes_by_address[address]
			captured_positions[address] = get_turf(node?.parent)

/// Full validation is only needed before publication, not on every small work slice.
/datum/netrun_apc_prebuild/proc/valid_inputs()
	if(QDELETED(graph) || !graph.dirty || generation != graph.structural_generation)
		return FALSE
	for(var/address in captured_positions)
		var/datum/component/netrun_node/node = SSnetrun.nodes_by_address[address]
		if(QDELETED(node) || node.node_type != NETRUN_NODE_APC || get_turf(node.parent) != captured_positions[address])
			return FALSE
	return TRUE

/datum/netrun_apc_prebuild/proc/begin_sector()
	if(sector_index > length(sectors))
		phase = "done"
		completed = TRUE
		return
	sector = sectors[sector_index]
	addresses = sector_apcs[sector]
	positions = list()
	input_order = list()
	nearest = list()
	components = list()
	for(var/i in 1 to length(addresses))
		var/address = addresses[i]
		positions[address] = captured_positions[address]
		input_order[address] = i
		nearest[address] = list()
		components[address] = address
	QDEL_NULL(spatial)
	spatial = new(addresses, positions)
	pair_i = 1
	pair_j = 2
	phase = "pairs"

/datum/netrun_apc_prebuild/proc/scan_pair()
	if(pair_i > length(addresses))
		phase = "select"
		return
	if(!active_scan)
		active_scan = new(spatial, addresses[pair_i])
	var/previous = active_scan.comparisons
	var/finished = active_scan.advance()
	comparisons += active_scan.comparisons - previous
	if(!finished)
		return
	nearest[addresses[pair_i]] = active_scan.best.Copy()
	QDEL_NULL(active_scan)
	pair_i++

/// The candidate collection is incremental rather than one large sort/union pass.
/datum/netrun_apc_prebuild/proc/select_pairs()
	if(!candidates)
		candidates = list()
		seen_candidates = list()
		select_i = 1
		select_j = 1
		phase = "collect"
		
/datum/netrun_apc_prebuild/proc/collect_pair()
	if(select_i > length(addresses))
		phase = "sort"
		return
	var/address = addresses[select_i]
	var/list/listing = nearest[address]
	if(select_j > length(listing))
		select_i++
		select_j = 1
		return
	var/list/pair = listing[select_j++]
	var/key = "[pair["from"]]>[pair["to"]]"
	if(seen_candidates[key])
		return
	seen_candidates[key] = TRUE
	candidates += list(pair)

/datum/netrun_apc_prebuild/proc/sort_candidates()
	// Every APC retains at most K neighbors. This bounded set is still sorted once
	// for the exact deterministic ordering used by synchronous connect_apcs().
	sortTim(candidates, GLOBAL_PROC_REF(cmp_netrun_physical_edge))
	union_i = 1
	phase = "union"

/datum/netrun_apc_prebuild/proc/union_pair()
	if(union_i > length(candidates))
		groups = list()
		group_order = list()
		group_build_i = 1
		phase = "groups"
		return
	var/list/pair = candidates[union_i++]
	components[graph.apc_component(components, pair["to"])] = graph.apc_component(components, pair["from"])

/datum/netrun_apc_prebuild/proc/build_group()
	if(group_build_i > length(addresses))
		if(length(group_order) < 2)
			phase = "store"
			return
		connected = groups[group_order[1]].Copy()
		group_i = 2
		from_i = 1
		to_i = 1
		bridge = null
		phase = "bridge"
		return
	var/address = addresses[group_build_i++]
	var/root = graph.apc_component(components, address)
	var/list/members = groups[root]
	if(!members)
		members = list()
		groups[root] = members
		group_order += root
	members += address

/datum/netrun_apc_prebuild/proc/scan_bridge()
	if(group_i > length(group_order))
		phase = "store"
		return
	var/list/members = groups[group_order[group_i]]
	if(from_i > length(connected))
		if(bridge)
			candidates += list(bridge)
		connected += members
		bridge = null
		group_i++
		from_i = 1
		to_i = 1
		return
	var/from_address = connected[from_i]
	var/to_address = members[to_i]
	var/first = input_order[from_address] < input_order[to_address] ? from_address : to_address
	var/second = first == from_address ? to_address : from_address
	var/list/pair = list("from" = first, "to" = second, "distance" = netrun_topology_distance(positions[first], positions[second]))
	if(!bridge || cmp_netrun_physical_edge(pair, bridge) < 0)
		bridge = pair
	comparisons++
	to_i++
	if(to_i > length(members))
		to_i = 1
		from_i++

/datum/netrun_apc_prebuild/proc/store_sector()
	links_by_sector[sector] = candidates
	sector_index++
	QDEL_NULL(active_scan)
	QDEL_NULL(spatial)
	addresses = null
	positions = null
	input_order = null
	nearest = null
	components = null
	candidates = null
	seen_candidates = null
	groups = null
	group_order = null
	connected = null
	bridge = null
	phase = "sector"

/// One bounded advancement, including all phase changes.
/datum/netrun_apc_prebuild/proc/advance(max_operations = 96)
	if(QDELETED(graph) || !graph.dirty || generation != graph.structural_generation)
		return FALSE
	for(var/i in 1 to max_operations)
		switch(phase)
			if("sector")
				begin_sector()
			if("pairs")
				scan_pair()
			if("select")
				select_pairs()
			if("collect")
				collect_pair()
			if("sort")
				sort_candidates()
			if("union")
				union_pair()
			if("groups")
				build_group()
			if("bridge")
				scan_bridge()
			if("store")
				store_sector()
			if("done")
				return TRUE
	return completed

/datum/netrun_apc_prebuild/Destroy()
	QDEL_NULL(active_scan)
	QDEL_NULL(spatial)
	graph = null
	return ..()

/// Registry subscriptions replace full endpoint scans for infrastructure changes.
/datum/netrun_topology/New()
	. = ..()
	RegisterSignal(SSnetrun, COMSIG_NETRUN_NODE_REGISTERED, PROC_REF(on_node_registered))
	RegisterSignal(SSnetrun, COMSIG_NETRUN_NODE_UNREGISTERED, PROC_REF(on_node_unregistered))
	RegisterSignal(SSnetrun, COMSIG_NETRUN_NODE_MOVED, PROC_REF(on_node_moved))
	for(var/address in SSnetrun.nodes_by_address)
		var/datum/component/netrun_node/node = SSnetrun.nodes_by_address[address]
		if(QDELETED(node))
			continue
		if(node.node_type == NETRUN_NODE_APC)
			registered_apcs[address] = node
		else if(is_relay(node))
			registered_relays[address] = node

/datum/netrun_topology/proc/on_node_registered(datum/source, datum/component/netrun_node/node)
	SIGNAL_HANDLER
	if(QDELETED(node))
		return
	if(node.node_type == NETRUN_NODE_APC)
		registered_apcs[node.address] = node
		infrastructure_changed()
	else if(is_relay(node))
		registered_relays[node.address] = node
		infrastructure_changed()
	else
		invalidate()

/datum/netrun_topology/proc/on_node_unregistered(datum/source, datum/component/netrun_node/node)
	SIGNAL_HANDLER
	if(!node)
		return
	registered_apcs -= node.address
	registered_relays -= node.address
	forget_node(node)

/datum/netrun_topology/proc/on_node_moved(datum/source, datum/component/netrun_node/node, turf/old_turf, turf/new_turf)
	SIGNAL_HANDLER
	if(QDELETED(node) || !is_infrastructure(node) || old_turf == new_turf)
		return
	node.topology_turf = new_turf
	infrastructure_changed()

/// Cached structural graph. Online state is deliberately absent: routing validates it live.
/datum/netrun_topology
	var/list/nodes = list()
	var/list/adjacency = list()
	var/list/edges = list()
	var/list/edge_lookup = list()
	var/dirty = TRUE
	var/rebuilding = FALSE
	var/structural_generation = 0
	var/datum/netrun_apc_prebuild/apc_prebuild
	var/revision = 0
	var/deferred_bindings = FALSE
	var/infrastructure_revision = 0
	var/indexed_revision = -1
	var/list/apcs_by_sector = list()
	var/list/relay_addresses = list()
	var/list/registered_apcs = list()
	var/list/registered_relays = list()
	var/indexed_infrastructure_visits = 0
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
	structural_generation++
	SEND_SIGNAL(SSnetrun, COMSIG_NETRUN_TOPOLOGY_DIRTY, src, structural_generation)

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
	// Work scales with infrastructure, not the count of endpoints.
	for(var/address in sort_list(registered_apcs.Copy()))
		var/datum/component/netrun_node/node = registered_apcs[address]
		if(QDELETED(node) || QDELETED(node.parent))
			continue
		indexed_infrastructure_visits++
		var/sector = netrun_sector_for(get_turf(node.parent))
		if(!sector)
			continue
		var/list/sector_apcs = apcs_by_sector[sector]
		if(!sector_apcs)
			sector_apcs = list()
			apcs_by_sector[sector] = sector_apcs
		sector_apcs += address
	for(var/address in sort_list(registered_relays.Copy()))
		var/datum/component/netrun_node/node = registered_relays[address]
		if(QDELETED(node) || QDELETED(node.parent))
			continue
		indexed_infrastructure_visits++
		if(netrun_sector_for(get_turf(node.parent)))
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
	// Exact indexed search: nearby cells first, prune only provably farther cells.
	var/list/nearest = list()
	var/list/components = list()
	var/list/input_order = list()
	var/list/positions = list()
	for(var/i in 1 to length(addresses))
		var/address = addresses[i]
		components[address] = address
		input_order[address] = i
		var/datum/component/netrun_node/apc = nodes[address]
		positions[address] = get_turf(apc.parent)
	var/datum/netrun_apc_spatial_index/spatial = new(addresses, positions)
	for(var/address in addresses)
		nearest[address] = spatial.nearest_edges(address)
	qdel(spatial)
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
	// The nearby-APC edges may form several disconnected groups.
	// Connect every remaining group to the growing network in one bounded pass.
	// Pair endpoints are canonical, NOT necessarily attached->unattached.
	var/list/component_groups = list()
	var/list/group_order = list()
	for(var/address in addresses)
		var/root = apc_component(components, address)
		var/list/members = component_groups[root]
		if(!members)
			members = list()
			component_groups[root] = members
			group_order += root
		members += address
	if(length(group_order) < 2)
		return
	var/list/connected = component_groups[group_order[1]].Copy()
	// Exactly one iteration per remaining component. No unbounded while loop.
	for(var/i in 2 to length(group_order))
		var/list/members = component_groups[group_order[i]]
		var/list/bridge
		for(var/from_address in connected)
			for(var/to_address in members)
				var/first = input_order[from_address] < input_order[to_address] ? from_address : to_address
				var/second = first == from_address ? to_address : from_address
				var/list/pair = list("from" = first, "to" = second,
					"distance" = netrun_topology_distance(positions[first], positions[second]))
				if(!bridge || cmp_netrun_physical_edge(pair, bridge) < 0)
					bridge = pair
		if(bridge)
			add_edge(bridge["from"], bridge["to"], "apc")
		connected += members

/// Prepare expensive APC work without changing published nodes, edges or adjacency.
/datum/netrun_topology/proc/advance_apc_prebuild(max_operations = 96)
	if(!dirty || rebuilding)
		QDEL_NULL(apc_prebuild)
		return TRUE
	if(!apc_prebuild || apc_prebuild.generation != structural_generation)
		QDEL_NULL(apc_prebuild)
		apc_prebuild = new(src)
	if(!apc_prebuild.advance(max_operations))
		return FALSE
	if(apc_prebuild.valid_inputs())
		rebuild()
	else
		QDEL_NULL(apc_prebuild)
	return !dirty

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
	// Precomputed candidates are optional; forced routing requests still rebuild immediately.
	var/datum/netrun_apc_prebuild/prepared = apc_prebuild
	var/valid_prebuild = prepared?.completed && prepared.valid_inputs()
	var/list/sectors = sort_list(apcs_by_sector.Copy())
	for(var/sector in sectors)
		var/list/prebuilt = valid_prebuild ? prepared.links_by_sector[sector] : null
		if(islist(prebuilt))
			for(var/list/pair as anything in prebuilt)
				add_edge(pair["from"], pair["to"], "apc")
		else
			connect_apcs(apcs_by_sector[sector])
	// Relay-to-relay transitions are an implicit uniform-cost bucket.
	for(var/address in adjacency)
		adjacency[address] = sort_list(adjacency[address])
	dirty = FALSE
	revision++
	weight_revision++
	deferred_bindings = SSatoms.initialized != INITIALIZATION_INNEW_REGULAR
	rebuilding = FALSE
	QDEL_NULL(apc_prebuild)
	SEND_SIGNAL(SSnetrun, COMSIG_NETRUN_TOPOLOGY_CHANGED, revision)

/datum/netrun_topology/Destroy()
	UnregisterSignal(SSnetrun, list(COMSIG_NETRUN_NODE_REGISTERED, COMSIG_NETRUN_NODE_UNREGISTERED, COMSIG_NETRUN_NODE_MOVED))
	QDEL_NULL(apc_prebuild)
	clear_route_tables(TRUE)
	nodes.Cut()
	adjacency.Cut()
	edges.Cut()
	edge_lookup.Cut()
	apcs_by_sector.Cut()
	registered_apcs.Cut()
	registered_relays.Cut()
	relay_addresses.Cut()
	nearest_by_turf.Cut()
	return ..()
