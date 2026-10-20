/// Один результат маршрутизации используют задержка, Ping и подсветка карты.
/datum/netrun_route
	var/list/hops = list()
	var/latency = 0
	var/name = "через реле NTnet"

/datum/component/netrun_node/proc/route_chain()
	. = list(list("kind" = "node", "ref" = address))
	var/datum/component/netrun_node/uplink = uplink_node()
	if(uplink)
		. += list(list("kind" = "node", "ref" = uplink.address))
	if(network)
		. += list(list("kind" = "gateway", "ref" = network.id))

/datum/netrun_console/proc/route_source()
	if(jack && jack_valid())
		return refresh_route_node(jack)
	return refresh_route_node(netrun_find_node(host))

/datum/netrun_console/entity/route_source()
	var/mob/camera/netrun_entity/entity = host
	return refresh_route_node(entity?.host_node)

/// Nested items need an immediate topology check as well as the periodic subsystem sweep.
/// Invalidate per-UI routing-derived access when a carrier crossed into another LAN.
/datum/netrun_console/proc/refresh_route_node(datum/component/netrun_node/node)
	if(!node || QDELETED(node) || QDELETED(node.parent))
		return null
	var/datum/netrun_network/previous = node.network
	node.join_network()
	if(previous != node.network)
		network_level_cache?.Cut()
	return node

/datum/netrun_console/proc/route_to(datum/component/netrun_node/node)
	var/datum/netrun_route/route = new
	if(!node || QDELETED(node) || !can_route(node))
		route.name = "нет маршрута"
		// An unavailable connection must never look like an instantaneous cable.
		route.latency = 3
		return route
	var/datum/component/netrun_node/source = route_source()
	if((node == jack && jack_valid()) || node == source)
		route.name = "прямое подключение"
		route.hops = list(list("kind" = "node", "ref" = node.address))
		return route
	var/turf/here = get_turf(host)
	var/turf/there = get_turf(node.parent)
	var/list/source_path = source ? source.route_chain() : list()
	var/list/target_path = node.route_chain()
	// A logical LAN (including its APC) can span linked floors. A different Z
	// changes latency, not the common-ancestor route into an unnecessary NTnet hop.
	var/local = node.network && (source?.network == node.network || (node.network in home_networks()))
	if(local)
		if(!length(source_path))
			source_path = list(list("kind" = "gateway", "ref" = node.network.id))
		// Путь обрезается по общему предку: общий APC не требует даже шлюза ЛВС.
		var/source_join = 0
		var/target_join = 0
		for(var/i in 1 to length(source_path))
			var/list/from_hop = source_path[i]
			for(var/j in 1 to length(target_path))
				var/list/to_hop = target_path[j]
				if(from_hop["kind"] == to_hop["kind"] && from_hop["ref"] == to_hop["ref"])
					source_join = i
					target_join = j
					break
			if(source_join)
				break
		if(source_join)
			route.hops = source_path.Copy(1, source_join + 1)
			for(var/i = target_join - 1, i >= 1, i--)
				route.hops += list(target_path[i])
			route.name = source_join < length(source_path) ? "подсеть APC" : "локальная сеть"
			var/local_latency = (here && there) ? (here.z == there.z ? clamp(round(get_dist(here, there) / 40), 0, 2) : 3) : 1
			route.latency = local_latency + (wireless && origin != NETRUN_ORIGIN_ENTITY && !jack_valid() ? 1 : 0)
			return route
	route.hops = source_path.Copy()
	route.hops += list(list("kind" = "hub"))
	for(var/i = length(target_path), i >= 1, i--)
		route.hops += list(target_path[i])
	route.latency = 3
	if(here && there)
		route.latency += here.z == there.z ? clamp(round(get_dist(here, there) / 25), 0, 4) : 5
	if(daemon_bonus("overclock"))
		route.latency = max(0, round(route.latency / 3))
	return route
