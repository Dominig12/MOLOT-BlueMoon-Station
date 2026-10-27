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
	var/ping_id = 0
	var/ping_until = 0
	var/ping_timer
	var/structure_revision = 0
	var/state_revision = 0
	/// Only stationary geometry and paint data invalidate the cached canvas.
	var/static_revision = 0
	var/list/static_structure
	var/subscribed = FALSE
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
	var/list/edge_indexes = list()
	var/list/node_indexes = list()
	var/list/incident_edges = list()
	var/list/shown_addresses = list()
	var/list/shown_network_counts = list()
	/// Access before a source move, including networks on floors outside the current view.
	var/list/projected_network_levels = list()
	var/list/revealed_addresses = list()
	var/list/context
	/// Authorization changes replace every UI baseline, including credentials lost by an operator.
	var/authorization_revision = 0
	var/list/security_context
	var/wire_epoch = 0
	var/wire_session_id = 0
	/// REF strings and timestamps only: closed windows/users are never retained by this cache.
	var/list/wire_sessions = list()
	/// Avoid walking every viewer on each TGUI poll.
	var/wire_cleanup_at = -INFINITY
	var/list/wire_journal = list()
	var/wire_journal_entries = 0
	var/active_sector
	var/active_z
	var/source_sector
	var/source_z
	var/list/sector_catalog = list()
	var/datum/netrun_map_geometry/geometry
	var/datum/netrun_map_projection/projection
	var/projection_advanced_at = -INFINITY

/datum/netrun_map_view/New(datum/netrun_console/owner)
	src.owner = owner
	geometry = new

/datum/netrun_map_view/proc/subscribe()
	if(subscribed)
		return
	subscribed = TRUE
	dirty = TRUE
	RegisterSignal(SSnetrun, COMSIG_NETRUN_NODE_CHANGED, PROC_REF(on_node_changed))
	RegisterSignal(SSnetrun, COMSIG_NETRUN_TOPOLOGY_CHANGED, PROC_REF(on_topology_changed))
	RegisterSignal(SSnetrun, COMSIG_NETRUN_EVENT_POSTED, PROC_REF(on_event_posted))

/// Closed/hidden maps do not receive every process movement elsewhere in the world.
/datum/netrun_map_view/proc/suspend()
	cancel_projection()
	if(!subscribed)
		return
	subscribed = FALSE
	UnregisterSignal(SSnetrun, list(COMSIG_NETRUN_NODE_CHANGED, COMSIG_NETRUN_TOPOLOGY_CHANGED, COMSIG_NETRUN_EVENT_POSTED))
	dirty_nodes.Cut()
	dirty = TRUE

/datum/netrun_map_view/Destroy()
	cancel_projection()
	if(ping_timer)
		deltimer(ping_timer)
	ping_timer = null
	UnregisterSignal(SSnetrun, list(COMSIG_NETRUN_NODE_CHANGED, COMSIG_NETRUN_TOPOLOGY_CHANGED, COMSIG_NETRUN_EVENT_POSTED))
	QDEL_NULL(geometry)
	snapshot = null
	structure = null
	context = null
	node_entries.Cut()
	edge_entries.Cut()
	edge_indexes.Cut()
	node_indexes.Cut()
	incident_edges.Cut()
	shown_addresses.Cut()
	shown_network_counts.Cut()
	projected_network_levels.Cut()
	revealed_addresses.Cut()
	static_structure = null
	wire_sessions.Cut()
	wire_journal.Cut()
	security_context = null
	owner = null
	return ..()

/// A ping is one finite event. Repeating the same path must still have a new identity.
/datum/netrun_map_view/proc/start_ping(list/hops, duration = 6 SECONDS)
	if(ping_timer)
		deltimer(ping_timer)
	ping_route = hops.Copy()
	ping_at = world.time
	ping_until = world.time + duration
	ping_id++
	ping_timer = addtimer(CALLBACK(src, PROC_REF(on_ping_expired), ping_id), duration, TIMER_STOPPABLE)
	SSnetrun.retain_route_interest(ping_route, ping_until)
	owner?.invalidate_ui()

/datum/netrun_map_view/proc/ping_deadline()
	return ping_until || ping_at + 6 SECONDS

/datum/netrun_map_view/proc/has_ping()
	return ping_route && world.time < ping_deadline()

/datum/netrun_map_view/proc/ping_metadata()
	if(!has_ping())
		return null
	return list("id" = ping_id, "remaining_ms" = max(0, (ping_deadline() - world.time) * 100))

/datum/netrun_map_view/proc/on_ping_expired(sequence)
	if(sequence != ping_id)
		return
	ping_timer = null
	expire_ping(sequence)

/// The scheduler also closes an overdue ping if its timer has not run yet.
/datum/netrun_map_view/proc/expire_ping(sequence)
	if((!isnull(sequence) && sequence != ping_id) || !ping_route || world.time < ping_deadline())
		return FALSE
	if(ping_timer)
		deltimer(ping_timer)
	ping_timer = null
	ping_route = null
	owner?.invalidate_ui()
	return TRUE

/// A leaf changing its APC is repaired incrementally while both ends and the
/// gateway set remain visible. Permission changes fall back to rebuild().
/datum/netrun_map_view/proc/on_node_changed(datum/source, datum/component/netrun_node/node, flags)
	SIGNAL_HANDLER
	if(flags & NETRUN_CHANGED_REMOVED)
		structure_dirty = TRUE
		cancel_projection()
	else if(node)
		dirty_nodes[node.address] = TRUE
	if(owner)
		owner.invalidate_ui()

/datum/netrun_map_view/proc/on_topology_changed(datum/source)
	SIGNAL_HANDLER
	structure_dirty = TRUE
	cancel_projection()
	if(owner)
		owner.invalidate_ui()

/datum/netrun_map_view/proc/on_event_posted(datum/source, kind, from_ref, to_ref)
	SIGNAL_HANDLER
	if(subscribed && owner)
		owner.invalidate_ui()

/datum/netrun_map_view/proc/invalidate(sensitive = TRUE)
	dirty = TRUE
	cancel_projection()
	if(sensitive)
		authorization_revision++
	if(owner)
		owner.invalidate_ui()

/// Reconciliation catches credentials and native state that have no change signal.
/// One UI request shares a path tree; clicks during a puzzle never call this method.
/datum/netrun_map_view/proc/payload()
	subscribe()
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	var/datum/component/netrun_node/focus = owner.map_focus_node()
	var/turf/current = owner.route_source()?.physical_turf() || owner.physical_turf()
	var/current_sector = netrun_sector_for(current)
	if(source_sector != current_sector || source_z != current?.z)
		active_sector = current_sector
		active_z = current?.z
	source_sector = current_sector
	source_z = current?.z
	// Access is included so a credential change (an ID picked up or dropped) refreshes the
	// projection through the context diff - no periodic full pass is needed to catch it.
	var/datum/component/netrun_node/source = owner.route_source()
	var/list/current_access = owner.user_access().Copy()
	var/list/current_context = list(owner.operator, source?.address, source?.is_online(), source?.network?.id, selected_address, waypoint_address, active_sector, active_z, current_access, owner.is_locked(), graph.transit_availability_revision)
	var/retained_context = netrun_snapshot_equal(context, current_context) || source_network_projection_unchanged(graph, source, current_context)
	if(!retained_context)
		dirty = TRUE
	context = current_context
	var/list/current_security = list(owner.operator, source?.address, source?.network?.id, source?.is_online(), current_access, owner.is_locked(), authorization_revision, owner.connection.wireless, owner.connection.jack?.address)
	if(!netrun_snapshot_equal(security_context, current_security))
		// A new credential domain cannot receive the old graph as a full baseline.
		if(security_context && (!retained_context || security_context[7] != current_security[7] || security_context[8] != current_security[8] || security_context[9] != current_security[9]))
			clear_authorized_projection()
		security_context = current_security
		wire_epoch++
	// Fully event-driven: a full rebuild only on a structural change, context change or a new
	// graph revision; a status-only change updates just the affected nodes in place.
	if(dirty || structure_dirty || !snapshot || snapshot["revision"] != graph.revision)
		rebuild(graph)
	else if(!projection && length(dirty_nodes))
		if(incremental_within_budget())
			apply_incremental(graph)
		else
			rebuild(graph)
	var/list/result = snapshot.Copy()
	result["focus"] = focus?.address
	result["route"] = owner.map_route_payload(owner.selected_node() || focus)
	// Readiness/stun can expire without changing the physical projection.
	result["relay_destinations"] = relay_destinations(graph, owner.selected_node(), shown_addresses, node_entries)
	return result

/// Crossing departments need not replace the projection when both LAN grants stay
/// identical and the old APC is still in the new source's forwarding component.
/datum/netrun_map_view/proc/source_network_projection_unchanged(datum/netrun_topology/graph, datum/component/netrun_node/source, list/current_context)
	if(!context || !snapshot || dirty || structure_dirty || snapshot["revision"] != graph.revision || context[4] == current_context[4])
		return FALSE
	var/list/without_network_change = current_context.Copy()
	without_network_change[4] = context[4]
	if(!netrun_snapshot_equal(context, without_network_change))
		return FALSE
	var/list/previous_source = node_entries[source?.address]
	var/datum/component/netrun_node/old_apc = graph.nodes[previous_source?["uplink"]]
	if(!old_apc || !old_apc.is_online() || !source?.is_online() || !source.bound_apc?.is_online() || !owner.can_route(old_apc))
		return FALSE
	var/datum/netrun_network/old_network = SSnetrun.networks[context[4]]
	var/datum/netrun_network/new_network = source.network
	if(!old_network || !new_network || isnull(projected_network_levels[old_network.id]) || isnull(projected_network_levels[new_network.id]))
		return FALSE
	return projected_network_levels[old_network.id] == owner.network_level(old_network) && projected_network_levels[new_network.id] == owner.network_level(new_network)

/// Browsing a different sector never moves the runner or grants permissions.
/datum/netrun_map_view/proc/select_sector(id, z)
	for(var/list/sector as anything in sector_catalog)
		if(sector["id"] != id)
			continue
		var/list/levels = sector["levels"]
		var/requested_z = isnum(z) ? z : text2num("[z]")
		active_sector = id
		active_z = (requested_z in levels) ? requested_z : ((source_z in levels) ? source_z : levels[1])
		invalidate(FALSE)
		return TRUE
	return FALSE

/datum/netrun_map_view/proc/follow_source()
	active_sector = source_sector
	active_z = source_z
	invalidate(FALSE)

/datum/netrun_map_view/proc/cancel_projection()
	SSnetrun.get_task_scheduler().cancel("map_projection", src)
	QDEL_NULL(projection)

/// Replace retained collections immediately; the worker discovers the new domain.
/datum/netrun_map_view/proc/clear_authorized_projection()
	cancel_projection()
	snapshot = null
	structure = null
	static_structure = null
	node_entries = list()
	edge_entries = list()
	edge_indexes = list()
	node_indexes = list()
	incident_edges = list()
	shown_addresses = list()
	shown_network_counts = list()
	projected_network_levels = list()
	revealed_addresses = list()
	sector_catalog = list()
	wire_journal = list()
	wire_journal_entries = 0
	structure_revision++
	static_revision++
	dirty = TRUE

/// The UI only requests work. Discovery and serialization run in bounded worker slices.
/datum/netrun_map_view/proc/rebuild(datum/netrun_topology/graph)
	if(projection && projection.matches(graph))
		return
	cancel_projection()
	if(!snapshot)
		structure = list(active_sector, active_z, list(), list())
		static_structure = list(list(), list(), list())
		snapshot = list("nodes" = list(), "edges" = list(), "gateways" = list(),
			"revision" = graph.revision, "structure_revision" = structure_revision, "state_revision" = state_revision, "static_revision" = static_revision,
			"source_sector" = source_sector, "source_z" = source_z, "active_sector" = active_sector, "active_z" = active_z,
			"sectors" = list(), "apc_zones" = list(), "relay_destinations" = list())
	// New authorization and topology contexts must explicitly revoke old catalogs.
	var/previous_revision = state_revision
	var/had_zones = length(snapshot["apc_zones"])
	snapshot["gateways"] = list()
	snapshot["sectors"] = list()
	snapshot["apc_zones"] = list()
	snapshot["relay_destinations"] = list()
	static_structure[3] = snapshot["apc_zones"]
	snapshot["state_revision"] = ++state_revision
	if(had_zones)
		snapshot["static_revision"] = ++static_revision
	record_wire_delta(previous_revision, list(), list(), list(), list())
	projection = new(src, graph)
	dirty = FALSE
	structure_dirty = FALSE
	dirty_nodes.Cut()
	SSnetrun.get_task_scheduler().enqueue("map_projection", src, NETRUN_TASK_NORMAL)
	SSnetrun.wake_ready_delivery()

/// TRUE ends the continuation; pending routes and exhausted slices resume next tick.
/datum/netrun_map_view/proc/advance_projection(max_operations)
	if(!projection || QDELETED(owner) || !subscribed)
		cancel_projection()
		return TRUE
	// Draining firewall events can invalidate and delete this job. Do it before
	// entering its nonyielding slice, then check whether work still exists.
	owner.access_session.process_events()
	if(!projection)
		return TRUE
	if(projection_advanced_at == world.time || owner.ui_serializing || owner.ui_routes)
		return FALSE
	projection_advanced_at = world.time
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	owner.ui_routes = owner.acquire_ui_routes()
	if(owner.ui_routes_pending)
		release_projection_routes()
		return FALSE
	// A fresh context must be reconciled by ui_data before another old slice is published.
	if(!projection.matches(graph) || !projection.source_matches())
		release_projection_routes()
		cancel_projection()
		dirty = TRUE
		owner.invalidate_ui()
		return TRUE
	owner.access_cache = owner.user_access(TRUE)
	owner.network_level_cache = list()
	owner.ui_node_levels = list()
	owner.ui_legit_levels = list()
	owner.ui_bonuses = list()
	owner.ui_keys = list()
	var/finished = projection.advance(max_operations)
	owner.access_cache = null
	owner.network_level_cache = null
	owner.ui_node_levels = null
	owner.ui_legit_levels = null
	owner.ui_bonuses = null
	owner.ui_keys = null
	release_projection_routes()
	if(finished)
		QDEL_NULL(projection)
		owner.invalidate_ui()
	return finished

/datum/netrun_map_view/proc/release_projection_routes()
	if(owner.ui_routes_borrowed)
		owner.ui_routes = null
		owner.ui_routes_borrowed = FALSE
	else
		QDEL_NULL(owner.ui_routes)

/// A burst of updates or a high-fanout APC must use the sliced worker too.
/datum/netrun_map_view/proc/incremental_within_budget()
	var/remaining = SSnetrun.get_execution_limits().map_projection_operations
	if(length(dirty_nodes) > remaining)
		return FALSE
	for(var/address in dirty_nodes)
		remaining -= 1 + length(incident_edges[address])
		if(remaining < 0)
			return FALSE
	return TRUE

/// Only O(changed nodes + their incident edges) work for a live map update.
/datum/netrun_map_view/proc/apply_incremental(datum/netrun_topology/graph)
	var/previous_revision = state_revision
	var/list/node_updates = list()
	var/list/edge_updates = list()
	var/list/map_nodes = snapshot["nodes"]
	var/list/map_edges = snapshot["edges"]
	var/list/paint_nodes = static_structure[1]
	var/list/paint_edges = static_structure[2]
	var/list/structural_nodes = structure[3]
	var/bumped = FALSE
	var/static_changed = FALSE
	var/geometry_changed = FALSE
	var/list/changed_edges = list()
	var/list/prepared = list()
	var/list/rewired_edges = list()
	var/list/removed_edge_ids = list()
	var/list/network_changes = list()
	// Preflight visibility before mutating the retained snapshot: a late full rebuild must
	// not lose earlier changes from the same batch or publish a partially updated baseline.
	for(var/address in dirty_nodes)
		var/list/previous = node_entries[address]
		var/index = node_indexes[address]
		var/datum/component/netrun_node/node = graph.nodes[address]
		if(QDELETED(node))
			continue
		var/turf/position = node.physical_turf()
		// Known offscreen nodes still contribute to the sector catalog. A move
		// across floors/LANs must revoke that catalog, even while another floor is viewed.
		if(previous && !index && (previous["sector"] != node.binding_sector || previous["z"] != position?.z || previous["network"] != node.network?.id))
			rebuild(graph)
			return
		var/now_shown = node.binding_sector == active_sector && position?.z == active_z && owner.can_route(node) && (owner.daemon_bonus("mapper") || (address in revealed_addresses) || owner.node_visible(node))
		// Floor changes and a personal endpoint changing owner can change visibility
		// without changing its APC attachment. Ordinary same-floor motion stays local.
		if(!!index != !!now_shown)
			rebuild(graph)
			return
		if(!previous || !index)
			continue
		var/list/entry = project_entry(node, previous["neighbor_count"])
		// Anchoring/unanchoring transfers a marker between canvas and DOM layers.
		if(previous["dynamic"] != entry["dynamic"])
			rebuild(graph)
			return
		// Retain gateways only while both LANs remain represented in this view.
		// Permission/visibility changes were checked above; source grants are checked in payload().
		if(previous["network"] != entry["network"] && (shown_network_counts[previous["network"]] <= 1 || !shown_network_counts[entry["network"]]))
			rebuild(graph)
			return
		if(previous["network"] != entry["network"])
			network_changes[previous["network"]]--
			network_changes[entry["network"]]++
		if(previous["uplink"] != entry["uplink"])
			var/list/incident = incident_edges[address]
			var/list/neighbors = graph.adjacency[address]
			if(length(incident) != 1 || length(neighbors) != 1 || neighbors[1] != entry["uplink"] || !shown_addresses[entry["uplink"]])
				rebuild(graph)
				return
			var/index_old = incident[1]
			var/list/old_edge = map_edges[index_old]
			var/list/new_edge = graph.edge_between(address, entry["uplink"])
			if(!old_edge || !new_edge || (old_edge["from"] != address && old_edge["to"] != address))
				rebuild(graph)
				return
			var/old_parent = old_edge["from"] == address ? old_edge["to"] : old_edge["from"]
			rewired_edges[address] = list("index" = index_old, "old_parent" = old_parent, "new_parent" = entry["uplink"], "edge" = new_edge)
		prepared[address] = entry
	// Several coalesced moves can remove a LAN's last visible markers together.
	for(var/network_id in network_changes)
		if(shown_network_counts[network_id] + network_changes[network_id] <= 0)
			rebuild(graph)
			return
	for(var/address in prepared)
		var/list/previous = node_entries[address]
		var/list/entry = prepared[address]
		var/index = node_indexes[address]
		if(netrun_snapshot_equal(previous, entry))
			continue
		if(previous["network"] != entry["network"])
			shown_network_counts[previous["network"]]--
			shown_network_counts[entry["network"]]++
		map_nodes[index] = entry
		node_entries[address] = entry
		node_updates += list(entry)
		bumped = TRUE
		var/list/node_structure = structure_entry(entry)
		if(!netrun_snapshot_equal(structural_nodes[address], node_structure))
			structural_nodes[address] = node_structure
			geometry_changed = TRUE
		if(!entry["dynamic"])
			var/list/paint_entry = static_entry(entry)
			if(!netrun_snapshot_equal(paint_nodes[address], paint_entry))
				paint_nodes[address] = paint_entry
				static_changed = TRUE
		for(var/edge_index in incident_edges[address])
			changed_edges["[edge_index]"] = edge_index
	// Swap the retained edge in place so all other edges keep their client indices.
	// The wire journal emits one removal and one upsert, not a full graph payload.
	for(var/address in rewired_edges)
		var/list/rewire = rewired_edges[address]
		var/index = rewire["index"]
		var/list/previous_edge = map_edges[index]
		var/list/entry = rewire["edge"].Copy()
		entry["online"] = netrun_link_available(graph.nodes[entry["from"]], graph.nodes[entry["to"]])
		var/old_id = previous_edge["id"]
		var/new_id = entry["id"]
		map_edges[index] = entry
		edge_entries -= old_id
		edge_entries[new_id] = entry
		edge_indexes -= old_id
		edge_indexes[new_id] = index
		structure[4][index] = new_id
		var/list/old_incident = incident_edges[rewire["old_parent"]]
		old_incident -= index
		var/list/new_incident = incident_edges[rewire["new_parent"]]
		new_incident += index
		if(paint_edges[old_id])
			paint_edges -= old_id
			paint_edges[new_id] = entry.Copy()
			static_changed = TRUE
		removed_edge_ids += old_id
		edge_updates += list(entry)
		geometry_changed = TRUE
		bumped = TRUE
	for(var/key in changed_edges)
		var/index = changed_edges[key]
		var/list/previous = map_edges[index]
		var/list/current_edge = graph.edge_between(previous["from"], previous["to"])
		if(!current_edge)
			rebuild(graph)
			return
		var/list/entry = current_edge.Copy()
		entry["online"] = netrun_link_available(graph.nodes[entry["from"]], graph.nodes[entry["to"]])
		if(netrun_snapshot_equal(previous, entry))
			continue
		map_edges[index] = entry
		edge_entries[entry["id"]] = entry
		edge_updates += list(entry)
		bumped = TRUE
		if(paint_edges[entry["id"]])
			paint_edges[entry["id"]] = entry.Copy()
			static_changed = TRUE
	dirty_nodes.Cut()
	if(bumped)
		snapshot["state_revision"] = ++state_revision
	if(geometry_changed)
		snapshot["structure_revision"] = ++structure_revision
	if(static_changed)
		snapshot["static_revision"] = ++static_revision
	record_wire_delta(previous_revision, node_updates, edge_updates, list(), removed_edge_ids)

/// One serialization seam makes incremental work measurable without constructing fake topology.
/datum/netrun_map_view/proc/project_entry(datum/component/netrun_node/node, neighbor_count)
	var/list/entry = node.ui_entry(owner)
	entry["network"] = node.network?.id
	entry["sector"] = node.binding_sector
	entry["neighbor_count"] = neighbor_count
	return entry

/datum/netrun_map_view/proc/structure_entry(list/entry)
	return list(entry["type"], entry["uplink"], entry["network"], entry["sector"], entry["x"], entry["y"], entry["z"], entry["dynamic"])

/// Transient occupants, activity, can_hop and selection belong to the live overlay.
/datum/netrun_map_view/proc/static_entry(list/entry)
	return list(entry["name"], entry["type"], entry["x"], entry["y"], entry["z"], entry["security"], entry["online"], entry["access"], entry["uplink"], entry["network"], entry["sector"])

/datum/netrun_map_view/proc/relay_destinations(datum/netrun_topology/graph, datum/component/netrun_node/selected, list/shown, list/permitted)
	. = list()
	if(!graph.is_relay(selected) || !shown[selected.address])
		return
	var/mob/camera/netrun_entity/entity = owner.origin == NETRUN_ORIGIN_ENTITY ? owner.host : null
	for(var/address in graph.relay_addresses)
		if(address == selected.address || !permitted[address])
			continue
		var/datum/component/netrun_node/target = graph.nodes[address]
		var/turf/position = target.physical_turf()
		var/online = netrun_link_available(selected, target)
		var/can_hop = entity && entity.host_node == selected && world.time >= entity.next_hop && !entity.is_stunned() && entity.can_enter(target, owner.ui_routes)
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

/// Bounded immutable change batches are shared by viewers; no quiet poll walks map entries.
/datum/netrun_map_view/proc/record_wire_delta(previous_revision, list/nodes, list/edges, list/removed_nodes, list/removed_edges)
	if(state_revision == previous_revision)
		return
	var/count = length(nodes) + length(edges) + length(removed_nodes) + length(removed_edges)
	wire_journal += list(list("base_revision" = previous_revision, "state_revision" = state_revision,
		"nodes" = nodes, "edges" = edges, "removed_nodes" = removed_nodes, "removed_edges" = removed_edges, "count" = count))
	wire_journal_entries += count
	while(length(wire_journal) > 32 || wire_journal_entries > 4096)
		var/list/oldest = wire_journal[1]
		wire_journal_entries -= oldest["count"]
		wire_journal.Cut(1, 2)

/// A UI is identified by its actual source, including the containing NTOS program.
/// The first registered poll binds the provisional opening snapshot without resending it.
/datum/netrun_map_view/proc/wire_session(mob/user, datum/ui_source, datum/tgui/ui)
	var/key = "[REF(user)]:[REF(ui_source)]"
	var/list/session = wire_sessions[key]
	var/ui_reference = ui ? REF(ui) : null
	if(!session || !ui || (session["ui"] && session["ui"] != ui_reference))
		session = list("id" = ++wire_session_id, "ui" = ui_reference)
		wire_sessions[key] = session
	else if(!session["ui"])
		session["ui"] = ui_reference
	session["seen"] = world.time
	// The session map is read on every poll, but full expiry scans are periodic.
	if(world.time >= wire_cleanup_at)
		wire_cleanup_at = world.time + 1 MINUTES
		SSnetrun.wire_session_sweeps++
		for(var/stale_key in wire_sessions)
			var/list/stale = wire_sessions[stale_key]
			if(world.time > stale["seen"] + 5 MINUTES)
				wire_sessions -= stale_key
	return session

/datum/netrun_map_view/proc/wire_payload(mob/user, datum/ui_source, list/session)
	var/list/full = payload()
	if(!user)
		return full
	ui_source = ui_source || owner
	var/datum/tgui/ui = SStgui.get_open_ui(user, ui_source)
	return encode_wire(full, session ? session : wire_session(user, ui_source, ui))

/// A refresh or skipped delivery cannot silently merge a patch into the wrong baseline.
/// The frontend requests resync through its validated UI action when it detects that case.
/datum/netrun_map_view/proc/resync(datum/tgui/ui)
	if(!ui?.user || !ui.src_object)
		return
	var/key = "[REF(ui.user)]:[REF(ui.src_object)]"
	var/list/session = wire_sessions[key]
	if(!session)
		session = list("id" = ++wire_session_id, "ui" = REF(ui))
		wire_sessions[key] = session
	// Sending a snapshot does not prove TGUI delivered it. Keep this viewer
	// on full snapshots until its frontend explicitly acknowledges the epoch.
	session["force_full"] = TRUE
	session["revision"] = null
	owner?.invalidate_ui()

/// Acknowledge a full snapshot only from the UI that owns the wire cursor.
/// A delayed receipt for an older epoch/revision must never unlock a new stream.
/datum/netrun_map_view/proc/ack_full(datum/tgui/ui, epoch, revision)
	if(!ui?.user || !ui.src_object || !istext(epoch))
		return FALSE
	// TGUI action transports may encode a numeric revision as text.
	var/confirmed_revision = isnum(revision) ? revision : (istext(revision) ? text2num(revision) : null)
	if(isnull(confirmed_revision))
		return FALSE
	var/key = "[REF(ui.user)]:[REF(ui.src_object)]"
	var/list/session = wire_sessions[key]
	if(!session || !session["force_full"] || session["epoch"] != epoch || session["revision"] != confirmed_revision)
		return FALSE
	session["force_full"] = FALSE
	return TRUE

/datum/netrun_map_view/proc/encode_wire(list/full, list/session)
	var/epoch = "[REF(src)]:[wire_epoch]:[session["id"]]"
	var/previous = session["revision"]
	var/list/result = full.Copy()
	var/list/node_updates = list()
	var/list/edge_updates = list()
	var/list/removed_nodes = list()
	var/list/removed_edges = list()
	var/send_full = !!session["force_full"] || isnull(previous) || session["epoch"] != epoch || previous > state_revision
	if(!send_full && previous != state_revision)
		var/cursor = previous
		for(var/list/batch as anything in wire_journal)
			if(batch["state_revision"] <= previous)
				continue
			if(batch["base_revision"] != cursor)
				break
			for(var/address in batch["removed_nodes"])
				node_updates -= address
				removed_nodes[address] = TRUE
			for(var/id in batch["removed_edges"])
				edge_updates -= id
				removed_edges[id] = TRUE
			for(var/list/entry as anything in batch["nodes"])
				node_updates[entry["address"]] = entry
				removed_nodes -= entry["address"]
			for(var/list/entry as anything in batch["edges"])
				edge_updates[entry["id"]] = entry
				removed_edges -= entry["id"]
			cursor = batch["state_revision"]
		send_full = cursor != state_revision
	result["epoch"] = epoch
	result["full"] = send_full
	if(!send_full)
		result["base_revision"] = previous
		// Selected APC shapes and sector catalogs can be large despite being immutable.
		// Omit unchanged metadata rather than re-encoding their tiles every poll.
		for(var/key in list("gateways", "sectors", "apc_zones"))
			if(session[key] == full[key])
				result -= key
		result["nodes"] = list()
		result["edges"] = list()
		var/list/wire_nodes = result["nodes"]
		var/list/wire_edges = result["edges"]
		for(var/address in node_updates)
			wire_nodes += list(node_updates[address])
		for(var/id in edge_updates)
			wire_edges += list(edge_updates[id])
		// Associative keys are emitted as arrays, never as address=>TRUE objects.
		result["removed_nodes"] = list()
		result["removed_edges"] = list()
		var/list/wire_removed_nodes = result["removed_nodes"]
		var/list/wire_removed_edges = result["removed_edges"]
		for(var/address in removed_nodes)
			wire_removed_nodes += address
		for(var/id in removed_edges)
			wire_removed_edges += id
	session["epoch"] = epoch
	session["revision"] = state_revision
	for(var/key in list("gateways", "sectors", "apc_zones"))
		session[key] = full[key]
	return result

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

/// A view walks only the ready route tree and the real neighbors it discovers.
/// Old markers are pruned first; each completed slice has its own wire revision.
/datum/netrun_map_projection
	var/datum/netrun_map_view/view
	var/datum/netrun_topology/graph
	var/list/context
	var/revision
	var/transit_revision
	var/authorization_revision
	var/list/connection_context
	var/phase = 1
	var/cursor = 1
	var/neighbor_cursor = 1
	var/removing_address
	var/list/revealed
	var/reveal_all
	var/list/next_nodes = list()
	var/list/next_shown = list()
	var/list/network_levels = list()
	var/list/sector_levels = list()
	var/list/networks = list()
	var/list/sectors = list()
	var/list/gateways = list()
	var/list/node_updates
	var/list/edge_updates
	var/list/removed_nodes
	var/list/removed_edges
	var/geometry_changed
	var/static_changed

/datum/netrun_map_projection/New(datum/netrun_map_view/view, datum/netrun_topology/graph)
	src.view = view
	src.graph = graph
	context = view.context
	revision = graph.revision
	transit_revision = graph.transit_availability_revision
	authorization_revision = view.authorization_revision
	connection_context = list(view.owner.connection.wireless, view.owner.connection.jack?.address)

/datum/netrun_map_projection/Destroy()
	view = null
	graph = null
	context = null
	return ..()

/datum/netrun_map_projection/proc/matches(datum/netrun_topology/current)
	return graph == current && revision == current.revision && transit_revision == current.transit_availability_revision && authorization_revision == view.authorization_revision && netrun_snapshot_equal(context, view.context)

/// Domain permissions remain live between slices, even before the next UI poll.
/datum/netrun_map_projection/proc/source_matches()
	var/datum/netrun_console/owner = view.owner
	var/datum/component/netrun_node/source = owner.route_source()
	var/turf/here = source?.physical_turf() || owner.physical_turf()
	return context && context[1] == owner.operator && context[2] == source?.address && context[3] == source?.is_online() && context[4] == source?.network?.id && context[10] == owner.is_locked() && view.source_sector == netrun_sector_for(here) && view.source_z == here?.z && netrun_snapshot_equal(context[9], owner.user_access(TRUE)) && netrun_snapshot_equal(connection_context, list(owner.connection.wireless, owner.connection.jack?.address))

/datum/netrun_map_projection/proc/permitted(datum/component/netrun_node/node)
	return !QDELETED(node) && view.owner.can_route(node) && (reveal_all || (node.address in revealed) || view.owner.node_visible(node))

/datum/netrun_map_projection/proc/on_floor(datum/component/netrun_node/node)
	return node.binding_sector == view.active_sector && node.physical_turf()?.z == view.active_z

/datum/netrun_map_projection/proc/advance(max_operations)
	if(isnull(revealed))
		revealed = view.owner.route_reveal_addresses(view.owner.map_focus_node())
		reveal_all = view.owner.daemon_bonus("mapper")
	node_updates = list()
	edge_updates = list()
	removed_nodes = list()
	removed_edges = list()
	geometry_changed = FALSE
	static_changed = FALSE
	var/previous_revision = view.state_revision
	var/finished = FALSE
	for(var/operation in 1 to max(1, max_operations))
		if(advance_operation())
			finished = TRUE
			break
	if(length(node_updates) || length(edge_updates) || length(removed_nodes) || length(removed_edges) || finished)
		view.snapshot["state_revision"] = ++view.state_revision
		if(geometry_changed)
			view.snapshot["structure_revision"] = ++view.structure_revision
		if(static_changed)
			view.snapshot["static_revision"] = ++view.static_revision
		view.record_wire_delta(previous_revision, node_updates, edge_updates, removed_nodes, removed_edges)
		view.owner.invalidate_ui()
	return finished

/datum/netrun_map_projection/proc/advance_operation()
	var/list/map_nodes = view.snapshot["nodes"]
	var/list/map_edges = view.snapshot["edges"]
	// A node with many cables removes only one cable per operation.
	if(removing_address)
		var/list/incident = view.incident_edges[removing_address]
		if(length(incident))
			var/list/edge = map_edges[incident[1]]
			remove_edge(edge["id"])
		else
			remove_node(removing_address)
			removing_address = null
		return FALSE
	if(phase == 1)
		if(cursor > length(map_nodes))
			phase = 2
			cursor = 1
			return FALSE
		var/list/previous = map_nodes[cursor]
		var/datum/component/netrun_node/node = graph.nodes[previous["address"]]
		if(!permitted(node) || !on_floor(node))
			removing_address = previous["address"]
		else
			cursor++
		return FALSE
	if(phase == 2)
		var/list/reached = view.owner.ui_routes.reached
		if(cursor > length(reached))
			phase = 3
			cursor = 1
			return FALSE
		var/address = reached[cursor++]
		var/datum/component/netrun_node/node = graph.nodes[address]
		if(!permitted(node))
			return FALSE
		var/list/entry = view.project_entry(node, length(graph.neighbors(address)))
		if(netrun_snapshot_equal(view.node_entries[address], entry))
			entry = view.node_entries[address]
		next_nodes[address] = entry
		if(node.network && isnull(network_levels[node.network.id]))
			network_levels[node.network.id] = view.owner.network_level(node.network)
		if(entry["sector"] && entry["z"])
			var/list/levels = sector_levels[entry["sector"]]
			if(!levels)
				levels = list()
				sector_levels[entry["sector"]] = levels
			levels |= entry["z"]
		if(on_floor(node))
			next_shown[address] = TRUE
			if(node.network)
				networks[node.network.id] = node.network
			upsert_node(entry)
		return FALSE
	if(phase == 3)
		if(cursor > length(map_edges))
			phase = 4
			cursor = 1
			return FALSE
		var/list/previous = map_edges[cursor]
		if(!next_shown[previous["from"]] || !next_shown[previous["to"]] || !graph.edge_between(previous["from"], previous["to"]))
			remove_edge(previous["id"])
		else
			cursor++
		return FALSE
	if(phase == 4)
		if(cursor > length(next_shown))
			phase = 5
			cursor = 1
			return FALSE
		var/address = next_shown[cursor]
		var/list/neighbors = graph.adjacency[address]
		if(neighbor_cursor > length(neighbors))
			cursor++
			neighbor_cursor = 1
			return FALSE
		var/neighbor = neighbors[neighbor_cursor++]
		if(next_shown[neighbor] && sorttext(address, neighbor) == 1)
			var/list/edge = graph.edge_between(address, neighbor)
			if(edge)
				var/list/entry = edge.Copy()
				entry["online"] = netrun_link_available(graph.nodes[address], graph.nodes[neighbor])
				upsert_edge(entry)
		return FALSE
	if(phase == 5)
		if(cursor > length(sector_levels))
			phase = 6
			cursor = 1
			return FALSE
		var/id = sector_levels[cursor++]
		var/list/levels = sector_levels[id]
		sortTim(levels, GLOBAL_PROC_REF(cmp_numeric_asc))
		var/datum/space_level/level = SSmapping.z_list[levels[1]]
		sectors += list(list("id" = id, "name" = level?.name || "Сектор [levels[1]]", "levels" = levels))
		return FALSE
	if(phase == 6)
		if(cursor > length(networks))
			phase = 7
			return FALSE
		var/datum/netrun_network/network = networks[networks[cursor++]]
		var/level = view.owner.network_level(network)
		gateways += list(list("id" = network.id, "code" = network.code, "name" = network.name,
			"color" = network.color, "security" = network.security, "access" = level,
			"has_key" = view.owner.has_key(network), "can_breach" = view.owner.intrusion.can_breach && level < NETRUN_ACCESS_GUEST))
		return FALSE
	finish()
	return TRUE

/datum/netrun_map_projection/proc/remove_node(address)
	var/list/nodes = view.snapshot["nodes"]
	var/index = view.node_indexes[address]
	var/list/previous = nodes[index]
	var/list/last = nodes[length(nodes)]
	if(index < length(nodes))
		nodes[index] = last
		view.node_indexes[last["address"]] = index
	nodes.len--
	view.node_indexes -= address
	view.shown_addresses -= address
	view.node_entries -= address
	view.incident_edges -= address
	view.shown_network_counts[previous["network"]]--
	view.structure[3] -= address
	if(view.static_structure[1][address])
		view.static_structure[1] -= address
		static_changed = TRUE
	removed_nodes += address
	geometry_changed = TRUE

/datum/netrun_map_projection/proc/remove_edge(id)
	var/list/edges = view.snapshot["edges"]
	var/index = view.edge_indexes[id]
	var/list/previous = edges[index]
	var/last_index = length(edges)
	var/list/last = edges[last_index]
	var/list/from_incident = view.incident_edges[previous["from"]]
	var/list/to_incident = view.incident_edges[previous["to"]]
	from_incident -= index
	to_incident -= index
	if(index != last_index)
		edges[index] = last
		view.edge_indexes[last["id"]] = index
		view.structure[4][index] = last["id"]
		var/list/last_from = view.incident_edges[last["from"]]
		var/list/last_to = view.incident_edges[last["to"]]
		last_from -= last_index
		last_to -= last_index
		last_from += index
		last_to += index
	edges.len--
	var/list/ids = view.structure[4]
	ids.len--
	view.edge_entries -= id
	view.edge_indexes -= id
	if(view.static_structure[2][id])
		view.static_structure[2] -= id
		static_changed = TRUE
	removed_edges += id
	geometry_changed = TRUE

/datum/netrun_map_projection/proc/upsert_node(list/entry)
	var/address = entry["address"]
	var/index = view.node_indexes[address]
	var/list/nodes = view.snapshot["nodes"]
	var/list/previous = index ? nodes[index] : null
	if(previous == entry)
		return
	if(index)
		nodes[index] = entry
	else
		nodes += list(entry)
		view.node_indexes[address] = length(nodes)
		view.incident_edges[address] = list()
		view.shown_addresses[address] = TRUE
	if(previous?["network"] != entry["network"])
		if(previous)
			view.shown_network_counts[previous["network"]]--
		view.shown_network_counts[entry["network"]]++
	view.node_entries[address] = entry
	var/list/shape = view.structure_entry(entry)
	if(!netrun_snapshot_equal(view.structure[3][address], shape))
		view.structure[3][address] = shape
		geometry_changed = TRUE
	var/list/paint = entry["dynamic"] ? null : view.static_entry(entry)
	if(!netrun_snapshot_equal(view.static_structure[1][address], paint))
		if(paint)
			view.static_structure[1][address] = paint
		else
			view.static_structure[1] -= address
		static_changed = TRUE
	node_updates += list(entry)

/datum/netrun_map_projection/proc/upsert_edge(list/entry)
	var/id = entry["id"]
	var/list/previous = view.edge_entries[id]
	if(netrun_snapshot_equal(previous, entry))
		return
	var/list/edges = view.snapshot["edges"]
	var/index = view.edge_indexes[id]
	if(index)
		edges[index] = entry
	else
		edges += list(entry)
		index = length(edges)
		view.edge_indexes[id] = index
		var/list/from_incident = view.incident_edges[entry["from"]]
		var/list/to_incident = view.incident_edges[entry["to"]]
		from_incident += index
		to_incident += index
		var/list/ids = view.structure[4]
		ids += id
		geometry_changed = TRUE
	view.edge_entries[id] = entry
	var/list/paint = !next_nodes[entry["from"]]["dynamic"] && !next_nodes[entry["to"]]["dynamic"] ? entry.Copy() : null
	if(!netrun_snapshot_equal(view.static_structure[2][id], paint))
		if(paint)
			view.static_structure[2][id] = paint
		else
			view.static_structure[2] -= id
		static_changed = TRUE
	edge_updates += list(entry)

/datum/netrun_map_projection/proc/finish()
	var/list/zones = list()
	var/datum/component/netrun_node/selected = view.owner.selected_node()
	if(selected?.node_type == NETRUN_NODE_APC && next_shown[selected.address])
		var/list/zone = view.geometry.apc_zone(selected, view.active_z)
		if(zone)
			zones += list(zone)
	if(!netrun_snapshot_equal(view.snapshot["apc_zones"], zones))
		view.snapshot["apc_zones"] = zones
		view.static_structure[3] = zones
		static_changed = TRUE
	view.node_entries = next_nodes
	view.revealed_addresses = revealed
	view.projected_network_levels = network_levels
	view.sector_catalog = sectors
	view.snapshot["gateways"] = gateways
	view.snapshot["sectors"] = sectors
	view.snapshot["revision"] = revision
	view.snapshot["source_sector"] = view.source_sector
	view.snapshot["source_z"] = view.source_z
	view.snapshot["active_sector"] = view.active_sector
	view.snapshot["active_z"] = view.active_z
	view.snapshot["relay_destinations"] = view.relay_destinations(graph, selected, next_shown, next_nodes)
	view.structure[1] = view.active_sector
	view.structure[2] = view.active_z
	view.refreshed_at = world.time
	// A revoked remote sector falls back to a newly permitted floor on the next job.
	if(!sector_levels[view.active_sector] && length(sectors))
		var/list/first = sectors[1]
		view.active_sector = first["id"]
		var/list/levels = first["levels"]
		view.active_z = levels[1]
		view.dirty = TRUE
	else
		var/list/active_levels = sector_levels[view.active_sector]
		if(length(active_levels) && !(view.active_z in active_levels))
			view.active_z = active_levels[1]
			view.dirty = TRUE
