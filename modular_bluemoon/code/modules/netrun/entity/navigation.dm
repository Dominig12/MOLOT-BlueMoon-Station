/// An entity owns one navigation operation. Replacing/cancelling it releases its timer;
/// generation checks also reject a callback already dispatched for an older operation.
/datum/netrun_entity_navigation
	var/mob/camera/netrun_entity/owner
	var/list/queue = list()
	var/destination
	var/expected_source
	var/timer
	var/generation = 0

/datum/netrun_entity_navigation/New(mob/camera/netrun_entity/entity)
	owner = entity

/datum/netrun_entity_navigation/Destroy()
	cancel()
	owner = null
	return ..()

/datum/netrun_entity_navigation/proc/is_active()
	return !!length(queue)

/datum/netrun_entity_navigation/proc/cancel()
	generation++
	if(timer)
		deltimer(timer)
		timer = null
	queue.Cut()
	destination = null
	expected_source = null
	owner?.console?.invalidate_ui()

/// Search the entire reachable graph once. One request-owned path tree keeps permission
/// checks fresh without rebuilding Dijkstra for each candidate or imposing a 200-node cap.
/datum/netrun_entity_navigation/proc/path_to(datum/component/netrun_node/target)
	if(QDELETED(target) || QDELETED(owner) || !owner.host_node || owner.console.is_locked())
		return list()
	var/datum/netrun_path_tree/tree = owner.console.make_path_tree()
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	var/start = owner.host_node.address
	var/list/visited = list()
	visited[start] = TRUE
	var/list/previous = list()
	var/list/frontier = list(start)
	var/list/result = list()
	for(var/i = 1, i <= length(frontier), i++)
		var/address = frontier[i]
		if(address == target.address)
			while(address && address != start)
				result.Insert(1, address)
				address = previous[address]
			break
		var/datum/component/netrun_node/current = graph.nodes[address]
		for(var/neighbor in graph.neighbors(address))
			if(visited[neighbor])
				continue
			var/datum/component/netrun_node/node = graph.nodes[neighbor]
			if(QDELETED(node) || !netrun_link_available(current, node))
				continue
			if(owner.console.node_level(node, tree) < NETRUN_ACCESS_USER && !owner.console.has_key(node.network, TRUE))
				continue
			visited[neighbor] = TRUE
			previous[neighbor] = address
			frontier += neighbor
	qdel(tree)
	return result

/datum/netrun_entity_navigation/proc/start(datum/component/netrun_node/target)
	if(QDELETED(owner) || target == owner.host_node || owner.is_stunned())
		return FALSE
	var/list/path = path_to(target)
	if(!length(path))
		return FALSE
	cancel()
	queue = path
	destination = target.address
	expected_source = owner.host_node.address
	advance_route(generation)
	return TRUE

/datum/netrun_entity_navigation/proc/schedule_step()
	if(timer)
		deltimer(timer)
	timer = addtimer(CALLBACK(src, PROC_REF(advance_route), generation), max(1, owner.next_hop - world.time), TIMER_STOPPABLE)

/// Keys permit travel, but do not make an unauthorized process safe from ICE.
/// Check each live step so a newly arrived patrol cannot be crossed on a stale route.
/datum/netrun_entity_navigation/proc/threat_at(datum/component/netrun_node/next)
	if(QDELETED(next) || !next.is_online() || !length(next.netrun_ice))
		return null
	var/datum/netrun_path_tree/tree = owner.console.make_path_tree()
	for(var/datum/netrun_ice/ice as anything in next.netrun_ice)
		if(!QDELETED(ice) && ice.is_intruder(owner, next, tree) && owner.can_enter(next, tree))
			. = ice
			break
	qdel(tree)

/datum/netrun_entity_navigation/proc/advance_route(expected_generation)
	if(expected_generation != generation || QDELETED(owner) || !is_active())
		return
	timer = null
	if(owner.host_node?.address != expected_source)
		cancel()
		return
	// Issuing/replacing a route during a hop cooldown should wait, not lose the route.
	if(world.time < owner.next_hop)
		schedule_step()
		return
	var/datum/component/netrun_node/next = SSnetrun.find_node(queue[1])
	var/datum/netrun_ice/threat = threat_at(next)
	if(threat)
		var/message = "Автопроход остановлен перед [next.get_name()] ([next.address]): [threat.name] враждебен вашему процессу. Изучите узел; для боя войдите вручную."
		cancel()
		owner.console.log_line(message, "average")
		to_chat(owner, span_warning(message))
		return
	if(!owner.hop(next, TRUE))
		var/reason = owner.hop_denial(next)
		cancel()
		owner.console.log_line("Автопроход прерван. [reason]", "bad")
		to_chat(owner, span_warning("Автопроход прерван. [reason]"))
		return
	// Arrival emits extension signals. A listener may replace/cancel navigation,
	// end the dive or delete its owner; this callback no longer owns that state.
	if(QDELETED(src) || QDELETED(owner) || expected_generation != generation || !owner.host_node)
		return
	queue.Cut(1, 2)
	expected_source = owner.host_node.address
	if(is_active())
		schedule_step()
	else
		cancel()
		owner.console.log_line("Автопроход завершён.", "good")
		to_chat(owner, span_notice("Автопроход завершён."))
	owner.console.invalidate_ui()

/datum/netrun_entity_navigation/proc/ui_payload()
	if(!is_active())
		return null
	return list("target" = destination, "remaining" = length(queue))
