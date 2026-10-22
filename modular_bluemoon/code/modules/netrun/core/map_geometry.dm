/// Compressed native APC area tiles. Runs preserve holes and disconnected shapes.
/datum/netrun_map_geometry
	var/list/cache = list()

/datum/netrun_map_geometry/proc/apc_zone(datum/component/netrun_node/node, z)
	if(QDELETED(node) || !istype(node.parent, /obj/machinery/power/apc) || !z)
		return null
	var/obj/machinery/power/apc/apc = node.parent
	var/area/room = apc.area || get_area(apc)
	room = room?.base_area || room
	if(!room)
		return null
	var/key = "[node.address]:[z]:[REF(room)]"
	var/list/previous = cache[key]
	if(previous && world.time < previous["expires"])
		return previous["zone"]
	var/list/rows = list()
	var/list/areas = list(room)
	areas |= room.sub_areas || list()
	for(var/area/member as anything in areas)
		for(var/turf/tile as anything in member)
			if(tile.z != z)
				continue
			var/row_key = "[tile.y]"
			if(!rows[row_key])
				rows[row_key] = list()
			var/list/columns = rows[row_key]
			columns |= tile.x
	var/list/runs = list()
	var/list/row_numbers = list()
	for(var/row_key in rows)
		row_numbers += text2num(row_key)
	sortTim(row_numbers, GLOBAL_PROC_REF(cmp_numeric_asc))
	for(var/y in row_numbers)
		var/list/columns = rows["[y]"]
		sortTim(columns, GLOBAL_PROC_REF(cmp_numeric_asc))
		var/start
		var/last
		for(var/x in columns)
			if(!isnull(last) && x != last + 1)
				runs += list(list("x" = start, "y" = y, "width" = last - start + 1))
				start = null
			if(isnull(start))
				start = x
			last = x
		if(!isnull(start))
			runs += list(list("x" = start, "y" = y, "width" = last - start + 1))
	var/list/zone = list("address" = node.address, "name" = room.name, "z" = z,
		"color" = node.network?.color, "runs" = runs)
	// Only the selected APC is retained; ordinary graph polls do not rescan world areas.
	cache = list()
	cache[key] = list("expires" = world.time + 1 SECONDS, "zone" = zone)
	return zone

/datum/netrun_map_geometry/Destroy()
	cache.Cut()
	return ..()
