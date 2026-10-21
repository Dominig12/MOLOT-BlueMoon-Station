/// A console owns a permitted projection, never a second physical topology.
/datum/netrun_map_view
	var/datum/netrun_console/owner
	var/selected_address
	var/selected_network
	var/viewed_network_id
	var/waypoint_address
	var/search_query
	var/list/ping_route
	var/ping_at = 0
	var/structure_revision = 0
	var/state_revision = 0
	var/dirty = TRUE
	var/refreshed_at = -INFINITY
	var/list/snapshot
	var/list/structure
	var/list/node_entries = list()
	var/list/edge_entries = list()
	var/list/context

/datum/netrun_map_view/New(datum/netrun_console/owner)
	src.owner = owner
	RegisterSignal(SSnetrun, list(COMSIG_NETRUN_NODE_CHANGED, COMSIG_NETRUN_TOPOLOGY_CHANGED), PROC_REF(on_graph_changed))

/datum/netrun_map_view/Destroy()
	UnregisterSignal(SSnetrun, list(COMSIG_NETRUN_NODE_CHANGED, COMSIG_NETRUN_TOPOLOGY_CHANGED))
	snapshot = null
	structure = null
	context = null
	node_entries.Cut()
	edge_entries.Cut()
	owner = null
	return ..()

/datum/netrun_map_view/proc/on_graph_changed(datum/source)
	SIGNAL_HANDLER
	invalidate()

/datum/netrun_map_view/proc/invalidate()
	dirty = TRUE
	if(owner)
		owner.ui_dirty = TRUE

/// Reconciliation catches credentials and native state that have no change signal.
/// One UI request shares a path tree; clicks during a puzzle never call this method.
/datum/netrun_map_view/proc/payload()
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	var/datum/component/netrun_node/focus = owner.map_focus_node()
	var/list/current_context = list(owner.operator, owner.route_source()?.address, selected_address, waypoint_address)
	if(!netrun_snapshot_equal(context, current_context))
		dirty = TRUE
	context = current_context
	if(dirty || !snapshot || snapshot["revision"] != graph.revision || world.time >= refreshed_at + SSnetrun.wait)
		rebuild(graph)
	var/list/result = snapshot.Copy()
	result["focus"] = focus?.address
	result["route"] = owner.map_route_payload(owner.selected_node() || focus)
	return result

/datum/netrun_map_view/proc/rebuild(datum/netrun_topology/graph)
	var/list/revealed = owner.route_reveal_addresses(owner.map_focus_node())
	var/list/shown = list()
	var/list/networks = list()
	var/list/next_nodes = list()
	var/list/next_edges = list()
	var/list/map_nodes = list()
	var/list/map_edges = list()
	var/list/next_structure = list()
	var/reveal_all = owner.daemon_bonus("mapper")
	for(var/address in graph.nodes)
		var/datum/component/netrun_node/node = graph.nodes[address]
		if(QDELETED(node) || !owner.can_route(node) || (!reveal_all && !(address in revealed) && !owner.node_visible(node)))
			continue
		var/list/entry = node.ui_entry(owner)
		entry["network"] = node.network?.id
		entry["sector"] = node.binding_sector
		entry["neighbor_count"] = length(graph.neighbors(address))
		if(netrun_snapshot_equal(node_entries[address], entry))
			entry = node_entries[address]
		next_nodes[address] = entry
		map_nodes += list(entry)
		shown[address] = TRUE
		next_structure[address] = list(node.node_type, entry["uplink"], node.network?.id, node.binding_sector)
		if(node.network)
			networks[node.network.id] = node.network
	var/list/edge_structure = list()
	for(var/list/edge as anything in graph.edges)
		if(!shown[edge["from"]] || !shown[edge["to"]])
			continue
		var/list/entry = edge.Copy()
		entry["online"] = netrun_link_available(graph.nodes[edge["from"]], graph.nodes[edge["to"]])
		if(netrun_snapshot_equal(edge_entries[edge["id"]], entry))
			entry = edge_entries[edge["id"]]
		next_edges[edge["id"]] = entry
		map_edges += list(entry)
		edge_structure += edge["id"]
	var/list/gateways = list()
	for(var/network_id in networks)
		var/datum/netrun_network/network = networks[network_id]
		var/level = owner.network_level(network)
		gateways += list(list("id" = network.id, "code" = network.code, "name" = network.name,
			"color" = network.color, "security" = network.security, "access" = level,
			"has_key" = owner.has_key(network), "can_breach" = owner.intrusion.can_breach && level < NETRUN_ACCESS_GUEST))
	var/list/new_structure = list(next_structure, edge_structure)
	if(!netrun_snapshot_equal(structure, new_structure))
		structure_revision++
	if(!snapshot || !netrun_snapshot_equal(snapshot["nodes"], map_nodes) || !netrun_snapshot_equal(snapshot["edges"], map_edges) || !netrun_snapshot_equal(snapshot["gateways"], gateways))
		state_revision++
	structure = new_structure
	node_entries = next_nodes
	edge_entries = next_edges
	snapshot = list("nodes" = map_nodes, "edges" = map_edges, "gateways" = gateways,
		"revision" = graph.revision, "structure_revision" = structure_revision, "state_revision" = state_revision)
	dirty = FALSE
	refreshed_at = world.time

/// Compare wire data without serializing the whole graph into another JSON string.
/proc/netrun_snapshot_equal(first, second)
	if(islist(first) && islist(second))
		var/list/left = first
		var/list/right = second
		if(length(left) != length(right))
			return FALSE
		for(var/i in 1 to length(left))
			var/key = left[i]
			if(!netrun_snapshot_equal(key, right[i]))
				return FALSE
			if(istext(key) && !netrun_snapshot_equal(left[key], right[key]))
				return FALSE
		return TRUE
	return first == second
