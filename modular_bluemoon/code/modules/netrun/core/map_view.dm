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
	/// A structural change (binding, removal, topology) needs a full projection rebuild.
	var/structure_dirty = TRUE
	/// Addresses whose status changed since the last payload - updated in place, no full pass.
	var/list/dirty_nodes = list()
	var/refreshed_at = -INFINITY
	var/list/snapshot
	var/list/structure
	var/list/node_entries = list()
	var/list/edge_entries = list()
	var/list/context
	var/active_sector
	var/active_z
	var/source_sector
	var/source_z
	var/list/sector_catalog = list()
	var/datum/netrun_map_geometry/geometry

/datum/netrun_map_view/New(datum/netrun_console/owner)
	src.owner = owner
	geometry = new
	RegisterSignal(SSnetrun, COMSIG_NETRUN_NODE_CHANGED, PROC_REF(on_node_changed))
	RegisterSignal(SSnetrun, COMSIG_NETRUN_TOPOLOGY_CHANGED, PROC_REF(on_topology_changed))

/datum/netrun_map_view/Destroy()
	UnregisterSignal(SSnetrun, list(COMSIG_NETRUN_NODE_CHANGED, COMSIG_NETRUN_TOPOLOGY_CHANGED))
	QDEL_NULL(geometry)
	snapshot = null
	structure = null
	context = null
	node_entries.Cut()
	edge_entries.Cut()
	owner = null
	return ..()

/// A single node's status change updates just that node in place; binding and removal are
/// structural (they move edges and membership) and need a full projection rebuild.
/datum/netrun_map_view/proc/on_node_changed(datum/source, datum/component/netrun_node/node, flags)
	SIGNAL_HANDLER
	if(flags & (NETRUN_CHANGED_BINDING | NETRUN_CHANGED_REMOVED))
		structure_dirty = TRUE
	else if(node)
		dirty_nodes[node.address] = TRUE
	if(owner)
		owner.ui_dirty = TRUE

/datum/netrun_map_view/proc/on_topology_changed(datum/source)
	SIGNAL_HANDLER
	structure_dirty = TRUE
	if(owner)
		owner.ui_dirty = TRUE

/datum/netrun_map_view/proc/invalidate()
	dirty = TRUE
	if(owner)
		owner.ui_dirty = TRUE

/// Reconciliation catches credentials and native state that have no change signal.
/// One UI request shares a path tree; clicks during a puzzle never call this method.
/datum/netrun_map_view/proc/payload()
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	var/datum/component/netrun_node/focus = owner.map_focus_node()
	var/turf/current = get_turf(owner.route_source()?.parent) || get_turf(owner.host)
	var/current_sector = netrun_sector_for(current)
	if(source_sector != current_sector || source_z != current?.z)
		active_sector = current_sector
		active_z = current?.z
	source_sector = current_sector
	source_z = current?.z
	// Access is included so a credential change (an ID picked up or dropped) refreshes the
	// projection through the context diff - no periodic full pass is needed to catch it.
	var/list/current_context = list(owner.operator, owner.route_source()?.address, selected_address, waypoint_address, active_sector, active_z, owner.user_access())
	if(!netrun_snapshot_equal(context, current_context))
		dirty = TRUE
	context = current_context
	// Fully event-driven: a full rebuild only on a structural change, context change or a new
	// graph revision; a status-only change updates just the affected nodes in place.
	if(dirty || structure_dirty || !snapshot || snapshot["revision"] != graph.revision)
		rebuild(graph)
	else if(length(dirty_nodes))
		apply_incremental(graph)
	var/list/result = snapshot.Copy()
	result["focus"] = focus?.address
	result["route"] = owner.map_route_payload(owner.selected_node() || focus)
	return result

/// Browsing a different sector never moves the runner or grants permissions.
/datum/netrun_map_view/proc/select_sector(id, z)
	for(var/list/sector as anything in sector_catalog)
		if(sector["id"] != id)
			continue
		var/list/levels = sector["levels"]
		var/requested_z = isnum(z) ? z : text2num("[z]")
		active_sector = id
		active_z = (requested_z in levels) ? requested_z : ((source_z in levels) ? source_z : levels[1])
		invalidate()
		return TRUE
	return FALSE

/datum/netrun_map_view/proc/follow_source()
	active_sector = source_sector
	active_z = source_z
	invalidate()

/datum/netrun_map_view/proc/rebuild(datum/netrun_topology/graph)
	var/list/revealed = owner.route_reveal_addresses(owner.map_focus_node())
	var/list/shown = list()
	var/list/networks = list()
	var/list/next_nodes = list()
	var/list/next_edges = list()
	var/list/map_nodes = list()
	var/list/permitted_nodes = list()
	var/list/sector_levels = list()
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
		permitted_nodes[address] = entry
		if(entry["sector"] && entry["z"])
			var/list/levels = sector_levels[entry["sector"]]
			if(!levels)
				levels = list()
				sector_levels[entry["sector"]] = levels
			levels |= entry["z"]
	sector_catalog = list()
	for(var/id in sort_list(sector_levels.Copy()))
		var/list/levels = sector_levels[id]
		sortTim(levels, GLOBAL_PROC_REF(cmp_numeric_asc))
		var/datum/space_level/level = SSmapping.z_list[levels[1]]
		sector_catalog += list(list("id" = id, "name" = level?.name || "Сектор [levels[1]]", "levels" = levels))
	if(!sector_levels[active_sector] && length(sector_catalog))
		var/list/first = sector_catalog[1]
		active_sector = first["id"]
		var/list/levels = first["levels"]
		active_z = levels[1]
	var/list/active_levels = sector_levels[active_sector]
	if(length(active_levels) && !(active_z in active_levels))
		active_z = active_levels[1]
	for(var/address in permitted_nodes)
		var/list/entry = permitted_nodes[address]
		if(entry["sector"] != active_sector || entry["z"] != active_z)
			continue
		map_nodes += list(entry)
		shown[address] = TRUE
		next_structure[address] = list(entry["type"], entry["uplink"], entry["network"], entry["sector"], entry["x"], entry["y"], entry["z"])
		var/datum/component/netrun_node/node = graph.nodes[address]
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
	var/list/apc_zones = list()
	var/datum/component/netrun_node/selected = owner.selected_node()
	if(selected?.node_type == NETRUN_NODE_APC && shown[selected.address])
		var/list/zone = geometry.apc_zone(selected, active_z)
		if(zone)
			apc_zones += list(zone)
	var/list/destinations = relay_destinations(graph, selected, shown, permitted_nodes)
	var/list/new_structure = list(active_sector, active_z, next_structure, edge_structure)
	if(!netrun_snapshot_equal(structure, new_structure))
		structure_revision++
	if(!snapshot || !netrun_snapshot_equal(snapshot["nodes"], map_nodes) || !netrun_snapshot_equal(snapshot["edges"], map_edges) || !netrun_snapshot_equal(snapshot["gateways"], gateways) || !netrun_snapshot_equal(snapshot["sectors"], sector_catalog) || !netrun_snapshot_equal(snapshot["apc_zones"], apc_zones) || !netrun_snapshot_equal(snapshot["relay_destinations"], destinations))
		state_revision++
	structure = new_structure
	node_entries = next_nodes
	edge_entries = next_edges
	snapshot = list("nodes" = map_nodes, "edges" = map_edges, "gateways" = gateways,
		"revision" = graph.revision, "structure_revision" = structure_revision, "state_revision" = state_revision,
		"source_sector" = source_sector, "source_z" = source_z, "active_sector" = active_sector, "active_z" = active_z,
		"sectors" = sector_catalog, "apc_zones" = apc_zones, "relay_destinations" = destinations)
	dirty = FALSE
	structure_dirty = FALSE
	dirty_nodes.Cut()
	refreshed_at = world.time

/// Refresh only the nodes whose status changed (and their incident edges) without a full
/// O(graph) pass. Membership and layout are unchanged, so only state_revision advances.
/datum/netrun_map_view/proc/apply_incremental(datum/netrun_topology/graph)
	var/list/map_nodes = snapshot["nodes"]
	var/list/map_edges = snapshot["edges"]
	var/bumped = FALSE
	for(var/address in dirty_nodes)
		var/list/previous = node_entries[address]
		if(!previous)
			continue // node is not part of the shown projection; its status does not affect the view
		var/datum/component/netrun_node/node = graph.nodes[address]
		if(QDELETED(node))
			continue
		var/list/entry = node.ui_entry(owner)
		entry["network"] = node.network?.id
		entry["sector"] = node.binding_sector
		entry["neighbor_count"] = length(graph.neighbors(address))
		if(netrun_snapshot_equal(previous, entry))
			continue
		var/index = map_nodes.Find(previous)
		if(index)
			map_nodes[index] = entry
		node_entries[address] = entry
		bumped = TRUE
		for(var/list/edge_entry as anything in map_edges)
			if(edge_entry["from"] != address && edge_entry["to"] != address)
				continue
			var/online = netrun_link_available(graph.nodes[edge_entry["from"]], graph.nodes[edge_entry["to"]])
			if(edge_entry["online"] != online)
				edge_entry["online"] = online
	dirty_nodes.Cut()
	if(bumped)
		state_revision++
		snapshot["state_revision"] = state_revision

/datum/netrun_map_view/proc/relay_destinations(datum/netrun_topology/graph, datum/component/netrun_node/selected, list/shown, list/permitted)
	. = list()
	if(!graph.is_relay(selected) || !shown[selected.address])
		return
	var/mob/camera/netrun_entity/entity = owner.origin == NETRUN_ORIGIN_ENTITY ? owner.host : null
	for(var/address in graph.relay_addresses)
		if(address == selected.address || !permitted[address])
			continue
		var/datum/component/netrun_node/target = graph.nodes[address]
		var/turf/position = get_turf(target.parent)
		var/online = netrun_link_available(selected, target)
		var/can_hop = entity && entity.host_node == selected && world.time >= entity.next_hop && !entity.is_stunned() && entity.can_enter(target)
		var/reason
		if(!entity)
			reason = "Переход доступен сетевой сущности."
		else if(entity.host_node != selected)
			reason = "Сначала перейдите в выбранное реле."
		else if(!online)
			reason = "Нет связи между реле."
		else if(!can_hop)
			reason = "Нет доступа к реле назначения или переход ещё не готов."
		. += list(list("from" = selected.address, "to" = address, "name" = target.get_name(),
			"sector" = target.binding_sector, "z" = position?.z, "online" = online,
			"can_hop" = !!can_hop, "unavailable_reason" = reason))

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
