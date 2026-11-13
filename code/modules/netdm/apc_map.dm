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

/datum/netdm_apc_zone
	var/list/apc
	var/list/anchors = list()

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
	var/datum/netdm_apc_zone/zone = zones[netdm_power_area(tile?.loc)]
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
	var/area_id = zone.apc["a"]
	facts += list(list("op" = "area_span", "area" = area_id, "x" = first, "endX" = last, "y" = row_y, "z" = row_z))
	var/level = "[row_z]"
	var/list/anchor = zone.anchors[level]
	var/body_x = zone.apc["x"]
	var/body_here = row_z == zone.apc["z"] && row_y == zone.apc["y"] && first <= body_x && body_x <= last
	if(body_here || !anchor || (!anchor["body"] && (row_y < anchor["y"] || (row_y == anchor["y"] && first < anchor["x"]))))
		zone.anchors[level] = list("x" = body_here ? body_x : first, "y" = row_y, "z" = row_z, "body" = body_here)

/datum/netdm_apc_map_export/proc/add_bindings(datum/netdm_apc_zone/zone)
	var/node = zone.apc["a"]
	var/body_z = zone.apc["z"]
	if(!zone.anchors["[body_z]"])
		return
	for(var/level in zone.anchors)
		var/list/anchor = zone.anchors[level]
		facts += list(list("op" = "area_apc", "a" = node, "area" = node, "x" = anchor["x"], "y" = anchor["y"], "z" = anchor["z"]))

#undef NETDM_APC_MAP_FACTS
#undef NETDM_APC_MAP_WORK
#undef NETDM_APC_MAP_WORK_SLICE
#undef NETDM_APC_MAP_CELL_BUDGET
#undef NETDM_APC_MAP_TICK_SHARE
