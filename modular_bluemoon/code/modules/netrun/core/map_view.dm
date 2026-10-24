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
	var/list/node_indexes = list()
	var/list/incident_edges = list()
	var/list/shown_addresses = list()
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
	if(!subscribed)
		return
	subscribed = FALSE
	UnregisterSignal(SSnetrun, list(COMSIG_NETRUN_NODE_CHANGED, COMSIG_NETRUN_TOPOLOGY_CHANGED, COMSIG_NETRUN_EVENT_POSTED))
	dirty_nodes.Cut()
	dirty = TRUE

/datum/netrun_map_view/Destroy()
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
	node_indexes.Cut()
	incident_edges.Cut()
	shown_addresses.Cut()
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

/// A single node's status change updates just that node in place; binding and removal are
/// structural (they move edges and membership) and need a full projection rebuild.
/datum/netrun_map_view/proc/on_node_changed(datum/source, datum/component/netrun_node/node, flags)
	SIGNAL_HANDLER
	if(flags & (NETRUN_CHANGED_BINDING | NETRUN_CHANGED_REMOVED))
		structure_dirty = TRUE
	else if(node)
		dirty_nodes[node.address] = TRUE
	if(owner)
		owner.invalidate_ui()

/datum/netrun_map_view/proc/on_topology_changed(datum/source)
	SIGNAL_HANDLER
	structure_dirty = TRUE
	if(owner)
		owner.invalidate_ui()

/datum/netrun_map_view/proc/on_event_posted(datum/source, kind, from_ref, to_ref)
	SIGNAL_HANDLER
	if(subscribed && owner)
		owner.invalidate_ui()

/datum/netrun_map_view/proc/invalidate(sensitive = TRUE)
	dirty = TRUE
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
	var/turf/current = get_turf(owner.route_source()?.parent) || get_turf(owner.host)
	var/current_sector = netrun_sector_for(current)
	if(source_sector != current_sector || source_z != current?.z)
		active_sector = current_sector
		active_z = current?.z
	source_sector = current_sector
	source_z = current?.z
	// Access is included so a credential change (an ID picked up or dropped) refreshes the
	// projection through the context diff - no periodic full pass is needed to catch it.
	var/datum/component/netrun_node/source = owner.route_source()
	var/list/current_context = list(owner.operator, source?.address, source?.is_online(), selected_address, waypoint_address, active_sector, active_z, owner.user_access(), owner.is_locked(), graph.transit_availability_revision)
	if(!netrun_snapshot_equal(context, current_context))
		dirty = TRUE
	context = current_context
	var/list/current_security = list(owner.operator, owner.route_source()?.address, owner.user_access(), owner.is_locked(), authorization_revision)
	if(!netrun_snapshot_equal(security_context, current_security))
		security_context = current_security
		wire_epoch++
	// Fully event-driven: a full rebuild only on a structural change, context change or a new
	// graph revision; a status-only change updates just the affected nodes in place.
	if(dirty || structure_dirty || !snapshot || snapshot["revision"] != graph.revision)
		rebuild(graph)
	else if(length(dirty_nodes))
		apply_incremental(graph)
	var/list/result = snapshot.Copy()
	result["focus"] = focus?.address
	result["route"] = owner.map_route_payload(owner.selected_node() || focus)
	// Readiness/stun can expire without changing the physical projection.
	result["relay_destinations"] = relay_destinations(graph, owner.selected_node(), shown_addresses, node_entries)
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
		invalidate(FALSE)
		return TRUE
	return FALSE

/datum/netrun_map_view/proc/follow_source()
	active_sector = source_sector
	active_z = source_z
	invalidate(FALSE)

/datum/netrun_map_view/proc/rebuild(datum/netrun_topology/graph)
	var/previous_revision = state_revision
	var/list/changed_nodes = list()
	var/list/changed_edges = list()
	var/list/removed_nodes = list()
	var/list/removed_edges = list()
	var/list/revealed = owner.route_reveal_addresses(owner.map_focus_node())
	revealed_addresses = revealed
	var/list/shown = list()
	var/list/networks = list()
	var/list/next_nodes = list()
	var/list/next_edges = list()
	var/list/map_nodes = list()
	var/list/permitted_nodes = list()
	var/list/sector_levels = list()
	var/list/map_edges = list()
	var/list/next_structure = list()
	var/list/next_static_nodes = list()
	var/list/next_static_edges = list()
	node_indexes = list()
	incident_edges = list()
	var/reveal_all = owner.daemon_bonus("mapper")
	for(var/address in graph.nodes)
		var/datum/component/netrun_node/node = graph.nodes[address]
		if(QDELETED(node) || !owner.can_route(node) || (!reveal_all && !(address in revealed) && !owner.node_visible(node)))
			continue
		var/list/entry = project_entry(node, length(graph.neighbors(address)))
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
		if(!shown_addresses[address] || node_entries[address] != entry)
			changed_nodes += list(entry)
		node_indexes[address] = length(map_nodes)
		incident_edges[address] = list()
		shown[address] = TRUE
		next_structure[address] = structure_entry(entry)
		if(!entry["dynamic"])
			next_static_nodes[address] = static_entry(entry)
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
		if(edge_entries[edge["id"]] != entry)
			changed_edges += list(entry)
		map_edges += list(entry)
		var/list/from_edges = incident_edges[edge["from"]]
		var/list/to_edges = incident_edges[edge["to"]]
		from_edges += length(map_edges)
		to_edges += length(map_edges)
		if(!next_nodes[edge["from"]]["dynamic"] && !next_nodes[edge["to"]]["dynamic"])
			next_static_edges[edge["id"]] = entry.Copy()
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
	var/list/new_static = list(next_static_nodes, next_static_edges, apc_zones)
	if(!netrun_snapshot_equal(static_structure, new_static))
		static_revision++
	static_structure = new_static
	if(!netrun_snapshot_equal(structure, new_structure))
		structure_revision++
	if(!snapshot || !netrun_snapshot_equal(snapshot["nodes"], map_nodes) || !netrun_snapshot_equal(snapshot["edges"], map_edges) || !netrun_snapshot_equal(snapshot["gateways"], gateways) || !netrun_snapshot_equal(snapshot["sectors"], sector_catalog) || !netrun_snapshot_equal(snapshot["apc_zones"], apc_zones) || !netrun_snapshot_equal(snapshot["relay_destinations"], destinations))
		state_revision++
	structure = new_structure
	for(var/address in shown_addresses)
		if(!shown[address])
			removed_nodes += address
	for(var/id in edge_entries)
		if(!next_edges[id])
			removed_edges += id
	node_entries = next_nodes
	edge_entries = next_edges
	shown_addresses = shown
	snapshot = list("nodes" = map_nodes, "edges" = map_edges, "gateways" = gateways,
		"revision" = graph.revision, "structure_revision" = structure_revision, "state_revision" = state_revision, "static_revision" = static_revision,
		"source_sector" = source_sector, "source_z" = source_z, "active_sector" = active_sector, "active_z" = active_z,
		"sectors" = sector_catalog, "apc_zones" = apc_zones, "relay_destinations" = destinations)
	record_wire_delta(previous_revision, changed_nodes, changed_edges, removed_nodes, removed_edges)
	dirty = FALSE
	structure_dirty = FALSE
	dirty_nodes.Cut()
	refreshed_at = world.time

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
	// Preflight visibility before mutating the retained snapshot: a late full rebuild must
	// not lose earlier changes from the same batch or publish a partially updated baseline.
	for(var/address in dirty_nodes)
		var/list/previous = node_entries[address]
		var/index = node_indexes[address]
		var/datum/component/netrun_node/node = graph.nodes[address]
		if(QDELETED(node))
			continue
		var/turf/position = get_turf(node.parent)
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
		prepared[address] = entry
	for(var/address in prepared)
		var/list/previous = node_entries[address]
		var/list/entry = prepared[address]
		var/index = node_indexes[address]
		if(netrun_snapshot_equal(previous, entry))
			continue
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
	for(var/key in changed_edges)
		var/index = changed_edges[key]
		var/list/previous = map_edges[index]
		var/list/entry = graph.edge_between(previous["from"], previous["to"]).Copy()
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
	record_wire_delta(previous_revision, node_updates, edge_updates, list(), list())

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
		var/turf/position = get_turf(target.parent)
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
