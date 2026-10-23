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
	var/datum/netrun_apc_bridges/bridges
	var/phase = "sector"
	var/pair_i = 1
	var/completed = FALSE
	var/comparisons = 0

/datum/netrun_apc_prebuild/New(datum/netrun_topology/owner)
	. = ..()
	graph = owner
	generation = owner.infrastructure_revision
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
	if(QDELETED(graph) || !graph.dirty || generation != graph.infrastructure_revision)
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
		bridges = new(groups, group_order, positions, input_order)
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
	var/previous_comparisons = bridges.comparisons
	var/finished = bridges.advance()
	comparisons += bridges.comparisons - previous_comparisons
	if(finished)
		candidates += bridges.links
		QDEL_NULL(bridges)
		phase = "store"

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
	QDEL_NULL(bridges)
	phase = "sector"

/// One bounded advancement, including all phase changes.
/datum/netrun_apc_prebuild/proc/advance(max_operations = 96)
	if(QDELETED(graph) || !graph.dirty || generation != graph.infrastructure_revision)
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
	QDEL_NULL(bridges)
	QDEL_NULL(active_scan)
	QDEL_NULL(spatial)
	graph = null
	return ..()

