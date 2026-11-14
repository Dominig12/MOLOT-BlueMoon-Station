#define NETDM_APC_MAP_FACTS 32768
#define NETDM_APC_MAP_WORK 16384
/// Work units between tick checks: one unit is a cheap per-cell step.
#define NETDM_APC_MAP_WORK_SLICE 256
#define NETDM_APC_MAP_CELL_BUDGET 2000000
/// Share of a tick one advance may take. The export is not urgent; service deliveries share the subsystem.
#define NETDM_APC_MAP_TICK_SHARE 15

/// Power grouping is a world fact. The observer must not call get_apc(), which can mutate it.
/proc/netdm_power_area(area/physical)
	return physical?.base_area || physical

/// Area IDs of zones without an APC start here: far above any APC node ID (at most 16 million).
#define NETDM_APC_MAP_DUCT_PREFIX "9900000000"

/datum/netdm_apc_zone
	/// The zone's primary APC; null for a zone without an APC, which is a passive cable duct (14.11.2026).
	var/list/apc
	/// Every APC of the zone. The others serve the part of the zone nearest to them (decided 14.11.2026).
	var/list/apcs = list()
	var/list/anchors = list()
	/// Area ID of a duct zone.
	var/duct_id

/// A temporary export of the current APC inventory. Only the wire facts leave this datum.
/datum/netdm_apc_map_export
	var/list/facts = list()
	var/error
	var/list/inventory
	var/list/zones = list()
	/// Levels that hold an APC of a served zone: "z" -> z. Only these levels are walked.
	var/list/levels = list()
	var/list/rows = list()
	var/phase = "nodes"
	var/index = 1
	var/offset
	var/cells_visited = 0
	var/datum/netdm_apc_zone/run_zone
	var/run_start
	var/ducts = 0

/datum/netdm_apc_map_export/New(list/sample)
	inventory = sample

/**
 * Walks every row of the levels that hold an APC of a served zone and emits runs of served cells.
 * Every step is one cell and the walk yields to the tick check. Bounding the walk by area.contents
 * is not used: on a live station one read of it costs a whole tick or more.
 */
/datum/netdm_apc_map_export/proc/advance()
	var/started = TICK_USAGE
	for(var/work = 1 to NETDM_APC_MAP_WORK)
		switch(phase)
			if("nodes")
				if(index > length(inventory))
					plan_rows()
					phase = "spans"
					index = 1
					offset = null
				else
					add_node(inventory[inventory[index++]])
			if("spans")
				if(index > length(rows))
					phase = "bindings"
					index = 1
				else
					scan_row(rows[index])
			if("bindings")
				if(index > length(zones))
					return TRUE
				add_bindings(zones[zones[index++]])
		if(error || length(facts) > NETDM_APC_MAP_FACTS || cells_visited > NETDM_APC_MAP_CELL_BUDGET)
			if(!error)
				error = "geometry_budget"
			return TRUE
		if(work % NETDM_APC_MAP_WORK_SLICE == 0 && (TICK_CHECK || TICK_USAGE - started > NETDM_APC_MAP_TICK_SHARE))
			return FALSE
	return FALSE

/datum/netdm_apc_map_export/proc/add_node(list/fact)
	// Every APC carries a radio access point for mobile, unanchored and APC-less nodes in range.
	facts += list(list("op" = "add_node", "a" = fact["a"], "x" = fact["x"], "y" = fact["y"], "z" = fact["z"],
		"accessRange" = NETDM_APC_ACCESS_RANGE))
	var/datum/weakref/root_ref = fact["root"]
	var/area/root = root_ref?.resolve()
	// Space is not a served zone: an APC there has no wired segment, only its own node.
	if(!root || istype(root, /area/space))
		return
	levels["[fact["z"]]"] = fact["z"]
	var/datum/netdm_apc_zone/zone = zones[root]
	if(!zone)
		zone = new
		zone.apc = fact
		zones[root] = zone
	else if(fact["primary"] || (!zone.apc["primary"] && text2num(fact["a"]) < text2num(zone.apc["a"])))
		zone.apc = fact
	zone.apcs += list(fact)

/// Whole rows of every walked level. A zone reaching a level without any of its APCs is not seen there.
/datum/netdm_apc_map_export/proc/plan_rows()
	if(length(levels) * world.maxx * world.maxy > NETDM_APC_MAP_CELL_BUDGET)
		error = "geometry_budget"
		return
	for(var/level in levels)
		var/z = levels[level]
		for(var/y in 1 to world.maxy)
			rows += list(list("y" = y, "z" = z, "first" = 1, "last" = world.maxx))

/datum/netdm_apc_map_export/proc/scan_row(list/row)
	if(isnull(offset))
		offset = row["first"]
	var/last = row["last"]
	var/row_y = row["y"]
	var/row_z = row["z"]
	var/turf/tile = locate(offset, row_y, row_z)
	var/area/tile_zone = netdm_power_area(tile?.loc)
	var/datum/netdm_apc_zone/zone = zones[tile_zone]
	if(!zone && tile_zone && !istype(tile_zone, /area/space))
		// A zone without an APC is exported as a duct: the Host joins the APCs that touch it.
		zone = new
		zone.duct_id = "[NETDM_APC_MAP_DUCT_PREFIX][++ducts]"
		zones[tile_zone] = zone
	cells_visited++
	if(zone != run_zone)
		if(run_zone)
			add_span(run_zone, run_start, offset - 1, row_y, row_z)
		run_zone = zone
		run_start = offset
	if(offset == last)
		if(run_zone)
			add_span(run_zone, run_start, last, row_y, row_z)
		run_zone = null
		offset = null
		index++
	else
		offset++

/datum/netdm_apc_map_export/proc/add_span(datum/netdm_apc_zone/zone, first, last, row_y, row_z)
	var/area_id = zone.apc ? zone.apc["a"] : zone.duct_id
	facts += list(list("op" = "area_span", "area" = area_id, "x" = first, "endX" = last, "y" = row_y, "z" = row_z))
	if(!zone.apc)
		return
	var/level = "[row_z]"
	var/list/anchor = zone.anchors[level]
	var/body_x = zone.apc["x"]
	var/body_here = row_z == zone.apc["z"] && row_y == zone.apc["y"] && first <= body_x && body_x <= last
	if(body_here || !anchor || (!anchor["body"] && (row_y < anchor["y"] || (row_y == anchor["y"] && first < anchor["x"]))))
		zone.anchors[level] = list("x" = body_here ? body_x : first, "y" = row_y, "z" = row_z, "body" = body_here)

/datum/netdm_apc_map_export/proc/add_bindings(datum/netdm_apc_zone/zone)
	if(!zone.apc)
		return
	var/node = zone.apc["a"]
	var/body_z = zone.apc["z"]
	if(!zone.anchors["[body_z]"])
		return
	for(var/level in zone.anchors)
		var/list/anchor = zone.anchors[level]
		facts += list(list("op" = "area_apc", "a" = node, "area" = node, "x" = anchor["x"], "y" = anchor["y"], "z" = anchor["z"]))
	// Another APC of the zone serves the part nearest to it, from its own cell when that cell is in the zone.
	// One standing on a wall of another zone stays a node without a segment, as before.
	var/datum/weakref/root_ref = zone.apc["root"]
	var/area/root = root_ref?.resolve()
	for(var/list/extra in zone.apcs)
		if(extra == zone.apc)
			continue
		var/turf/cell = locate(extra["x"], extra["y"], extra["z"])
		if(!cell || netdm_power_area(cell.loc) != root)
			continue
		facts += list(list("op" = "area_apc", "a" = extra["a"], "area" = node, "x" = extra["x"], "y" = extra["y"], "z" = extra["z"]))

#undef NETDM_APC_MAP_FACTS
#undef NETDM_APC_MAP_WORK
#undef NETDM_APC_MAP_WORK_SLICE
#undef NETDM_APC_MAP_CELL_BUDGET
#undef NETDM_APC_MAP_TICK_SHARE
#undef NETDM_APC_MAP_DUCT_PREFIX
