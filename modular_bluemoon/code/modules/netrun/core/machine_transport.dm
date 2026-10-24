/// Machine services share physical routing, while each adapter retains native authorization.
/atom
	var/list/netrun_machine_services

/atom/proc/netrun_machine_service_types()
	return list()

/atom/proc/netrun_machine_service_node()
	var/datum/component/netrun_node/node = GetComponent(/datum/component/netrun_node)
	if(!node && length(netrun_machine_service_types()))
		node = AddComponent(/datum/component/netrun_node, NETRUN_NODE_SERVER, list(), 1)
	return node

/atom/proc/ensure_netrun_machine_services(datum/component/netrun_node/node)
	if(!node || QDELETED(src))
		return
	if(!netrun_machine_services)
		netrun_machine_services = list()
	for(var/datum/netrun_machine_service/path as anything in netrun_machine_service_types())
		var/id = initial(path.service_id)
		var/datum/netrun_machine_service/service = netrun_machine_services[id]
		if(QDELETED(service))
			netrun_machine_services[id] = new path(node, src)
		else
			// HIGHLANDER replaces a component after registering the new one.
			service.node = node

/atom/proc/get_netrun_machine_service(service_id)
	var/datum/component/netrun_node/node = netrun_machine_service_node()
	ensure_netrun_machine_services(node)
	var/datum/netrun_machine_service/service = netrun_machine_services?[service_id]
	if(!QDELETED(service))
		service.node = node
		return service

/datum/controller/subsystem/netrun
	var/datum/netrun_machine_transport/machine_transport

/datum/controller/subsystem/netrun/proc/get_machine_transport()
	if(!machine_transport)
		machine_transport = new
	return machine_transport

/// Every message is owned by its delivery. Payload lists never alias native state.
/datum/netrun_machine_message
	var/list/payload
	var/datum/netrun_machine_service/source
	var/datum/netrun_machine_service/recipient
	var/datum/weakref/user_ref
	var/correlation_id

/datum/netrun_machine_message/New(list/payload)
	src.payload = payload ? deepCopyList(payload) : list()

/datum/netrun_machine_message/Destroy()
	payload = null
	source = null
	recipient = null
	user_ref = null
	return ..()

/datum/netrun_machine_message/proc/copy()
	var/datum/netrun_machine_message/result = new type()
	result.payload = deepCopyList(payload)
	result.user_ref = user_ref
	result.correlation_id = correlation_id
	return result

/datum/netrun_machine_message/proc/reply(datum/netrun_machine_message/response)
	return recipient.send_to(source, response)

/datum/netrun_machine_message/proc/failed(reason)
	return

/datum/netrun_machine_message/proc/delivered(datum/netrun_machine_service/recipient_service)
	return

/// Only replaceable state snapshots opt in; commands retain their own delivery.
/datum/netrun_machine_message/proc/coalescing_key()
	return null

/datum/netrun_machine_service
	var/service_id
	var/atom/host
	var/datum/component/netrun_node/node
	var/list/directory = list()
	var/list/resolutions = list()

/datum/netrun_machine_service/New(datum/component/netrun_node/node, atom/host_override)
	src.node = node
	host = host_override || node?.parent
	if(host)
		RegisterSignal(host, COMSIG_PARENT_QDELETING, PROC_REF(host_deleted))
	SSnetrun.get_machine_transport().register(src)

/datum/netrun_machine_service/Destroy()
	SSnetrun.get_machine_transport().unregister(src)
	if(host)
		UnregisterSignal(host, COMSIG_PARENT_QDELETING)
		if(host.netrun_machine_services?[service_id] == src)
			host.netrun_machine_services -= service_id
	for(var/key in resolutions.Copy())
		qdel(resolutions[key])
	resolutions.Cut()
	for(var/key in directory)
		qdel(directory[key])
	directory.Cut()
	host = null
	node = null
	return ..()

/datum/netrun_machine_service/proc/host_deleted()
	SIGNAL_HANDLER
	qdel(src)

/datum/netrun_machine_service/proc/service_key()
	return "[REF(host)]:[service_id]"

/datum/netrun_machine_service/proc/resolve_node()
	return node

/datum/netrun_machine_service/proc/service_tag()
	return resolve_node()?.address

/datum/netrun_machine_service/proc/matches(datum/netrun_machine_service/source_service, recipient_tag)
	return isnull(recipient_tag) || service_tag() == recipient_tag

/datum/netrun_machine_service/proc/accepts(datum/netrun_machine_message/message)
	return !QDELETED(host) && resolve_node()?.is_online() && message.source?.resolve_node()?.is_online()

/datum/netrun_machine_service/proc/receive(datum/netrun_machine_message/message)
	return FALSE

/datum/netrun_machine_service/proc/directory_ready(destination_id, recipient_tag)
	if(!QDELETED(host))
		SEND_SIGNAL(host, COMSIG_NETRUN_SERVICE_STATE_CHANGED)
		SStgui.update_uis(host)

/datum/netrun_machine_service/proc/send(destination_id, datum/netrun_machine_message/message, recipient_tag)
	if(QDELETED(message))
		return FALSE
	var/datum/netrun_machine_directory/entry = cached_directory(destination_id, recipient_tag)
	if(entry)
		var/list/targets = resolve(destination_id, recipient_tag)
		var/admitted = FALSE
		for(var/datum/netrun_machine_service/target as anything in targets)
			admitted = send_to(target, message.copy()) || admitted
		if(!length(targets))
			message.failed("DNS: получатель недоступен")
		qdel(message)
		return admitted
	var/datum/netrun_machine_resolution/query = get_resolution(destination_id, recipient_tag)
	if(!query)
		message.failed("источник недоступен")
		qdel(message)
		return FALSE
	return query.enqueue(message)

/// Replies and peers already obtained through service discovery do not repeat DNS.
/datum/netrun_machine_service/proc/send_to(datum/netrun_machine_service/target, datum/netrun_machine_message/message)
	return SSnetrun.get_machine_transport().dispatch(src, target, message)

/datum/netrun_machine_service/proc/resolve(destination_id, recipient_tag)
	var/datum/netrun_machine_directory/entry = cached_directory(destination_id, recipient_tag)
	var/list/result = list()
	if(entry)
		for(var/datum/weakref/ref as anything in entry.records)
			var/datum/netrun_machine_service/target = ref.resolve()
			if(!QDELETED(target) && target.matches(src, recipient_tag) && can_reach(target, FALSE))
				result += target
		return result
	get_resolution(destination_id, recipient_tag)
	return result

/datum/netrun_machine_service/proc/cached_directory(destination_id, recipient_tag)
	var/query_key = "[destination_id]|[recipient_tag]"
	var/datum/netrun_machine_directory/entry = directory[query_key]
	if(entry && entry.expires > world.time && entry.revision == SSnetrun.get_machine_transport().service_revisions[destination_id] && can_reach(entry.resolver_ref?.resolve(), FALSE))
		return entry
	return null

/datum/netrun_machine_service/proc/get_resolution(destination_id, recipient_tag)
	if(QDELETED(host) || !resolve_node()?.is_online())
		return null
	var/query_key = "[destination_id]|[recipient_tag]"
	var/datum/netrun_machine_resolution/query = resolutions[query_key]
	if(query)
		return query
	if(length(resolutions) >= 64)
		return null
	query = new(src, destination_id, recipient_tag)
	resolutions[query_key] = query
	query.begin()
	return QDELETED(query) ? null : query

/datum/netrun_machine_service/proc/can_reach(datum/netrun_machine_service/target, require_dns = TRUE)
	if(QDELETED(target) || !SSnetrun.get_machine_transport().reachable(src, target))
		return FALSE
	if(!require_dns)
		return TRUE
	for(var/query_key in directory)
		var/datum/netrun_machine_directory/entry = directory[query_key]
		if(entry.expires <= world.time || !SSnetrun.get_machine_transport().reachable(src, entry.resolver_ref?.resolve()))
			continue
		for(var/datum/weakref/ref as anything in entry.records)
			if(ref.resolve() == target)
				return TRUE
	return FALSE

/datum/netrun_machine_directory
	var/list/records = list()
	var/datum/weakref/resolver_ref
	var/expires
	var/revision

/// Registry metadata is local; query, answer and data each cross a real packet boundary.
/datum/netrun_machine_transport
	var/list/services = list()
	var/list/by_id = list()
	var/list/service_revisions = list()
	var/list/packets = list()
	var/list/interactive_packets = list()
	var/queued_messages = 0
	var/list/last_flow = list()
	var/flow_window = 0
	var/flow_count = 0
	var/revision = 0
	var/list/route_trees = list()
	var/list/route_used = list()
	var/last_availability_check = -INFINITY

/datum/netrun_machine_transport/New()
	RegisterSignal(SSnetrun, COMSIG_NETRUN_NODE_UNREGISTERED, PROC_REF(node_deleted))

/datum/netrun_machine_transport/proc/node_deleted(datum/source, datum/component/netrun_node/node)
	SIGNAL_HANDLER
	qdel(route_trees[node.address])
	route_trees -= node.address
	route_used -= node.address

/datum/netrun_machine_transport/Destroy()
	UnregisterSignal(SSnetrun, COMSIG_NETRUN_NODE_UNREGISTERED)
	QDEL_LIST(packets)
	for(var/address in route_trees)
		qdel(route_trees[address])
	route_trees.Cut()
	route_used.Cut()
	return ..()

/datum/netrun_machine_transport/proc/register(datum/netrun_machine_service/service)
	services[service.service_key()] = service
	var/list/bucket = by_id[service.service_id]
	if(!bucket)
		bucket = list()
		by_id[service.service_id] = bucket
	bucket |= service
	revision++
	service_revisions[service.service_id] = (service_revisions[service.service_id] || 0) + 1

/datum/netrun_machine_transport/proc/unregister(datum/netrun_machine_service/service)
	services -= service.service_key()
	var/list/bucket = by_id[service.service_id]
	bucket -= service
	revision++
	service_revisions[service.service_id] = (service_revisions[service.service_id] || 0) + 1
	for(var/datum/netrun_machine_packet/packet as anything in packets.Copy())
		if(packet.source == service || packet.recipient == service)
			packet.fail("машина отключена")

/datum/netrun_machine_transport/proc/lookup(datum/netrun_machine_service/source, destination_id, recipient_tag)
	. = list()
	var/list/bucket = by_id[destination_id]
	for(var/datum/netrun_machine_service/target as anything in bucket)
		if(!QDELETED(target) && target.matches(source, recipient_tag) && reachable(source, target))
			. += target

/datum/netrun_machine_transport/proc/reachable(datum/netrun_machine_service/source, datum/netrun_machine_service/recipient)
	var/datum/netrun_route/path = route(source, recipient)
	. = !!path
	qdel(path)

/// Most endpoints have one APC cable. Share one tree at that attachment instead of
/// keeping a station-sized table for each vent, camera and carried computer.
/datum/netrun_machine_transport/proc/path_tree(datum/netrun_topology/graph, datum/component/netrun_node/root)
	if(last_availability_check != world.time)
		last_availability_check = world.time
		graph.reconcile_availability()
	var/datum/netrun_path_tree/tree = route_trees[root.address]
	if(!tree || tree.source != root || tree.geometry_revision != graph.weight_revision || tree.availability_revision != graph.availability_revision)
		qdel(tree)
		if(!tree && length(route_trees) >= 64)
			var/oldest
			for(var/address in route_used)
				if(!oldest || route_used[address] < route_used[oldest])
					oldest = address
			qdel(route_trees[oldest])
			route_trees -= oldest
			route_used -= oldest
		tree = new(graph, root)
		route_trees[root.address] = tree
	route_used[root.address] = world.time
	return tree

/// Cached geometry is bounded; every selected physical edge is still checked live.
/datum/netrun_machine_transport/proc/route(datum/netrun_machine_service/source, datum/netrun_machine_service/recipient)
	if(QDELETED(source) || QDELETED(recipient) || QDELETED(source.host) || QDELETED(recipient.host))
		return null
	var/datum/component/netrun_node/start = source.resolve_node()
	var/datum/component/netrun_node/finish = recipient.resolve_node()
	if(QDELETED(start) || QDELETED(finish) || !start.is_online() || !finish.is_online())
		return null
	// A carried endpoint does not receive its container's MOVED signal.
	start.join_network()
	if(start != finish)
		finish.join_network()
	SSnetrun.ensure_topology()
	var/datum/netrun_topology/graph = SSnetrun.get_topology()
	if(graph.nodes[start.address] != start || graph.nodes[finish.address] != finish)
		return null
	if(start == finish)
		var/datum/netrun_route/local = new
		local.hops = list(start.address)
		return local
	var/datum/component/netrun_node/root = start
	var/prefix_cost = 0
	var/list/neighbors = graph.adjacency[start.address]
	if(!graph.is_infrastructure(start) && length(neighbors) == 1)
		root = graph.nodes[neighbors[1]]
		if(!netrun_link_available(start, root))
			return null
		prefix_cost = graph.cached_edge_cost(start.address, root.address)
	var/datum/netrun_path_tree/tree = path_tree(graph, root)
	var/list/path = tree?.addresses_to(finish.address)
	if(!length(path))
		return null
	if(root != start)
		path.Insert(1, start.address)
	for(var/i in 2 to length(path))
		if(!netrun_link_available(graph.nodes[path[i - 1]], graph.nodes[path[i]]))
			return null
	var/datum/netrun_route/result = new
	result.hops = path
	result.latency = prefix_cost + tree.cost_to(finish.address)
	return result

/datum/netrun_machine_transport/proc/dispatch(datum/netrun_machine_service/source, datum/netrun_machine_service/target, datum/netrun_machine_message/message)
	if(QDELETED(message))
		return FALSE
	var/datum/netrun_machine_packet/data/packet = new(source, target, message)
	return packet.send()

/datum/netrun_machine_transport/proc/record_flow(datum/netrun_machine_service/source, datum/netrun_machine_service/target, kind, list/path)
	// Bound visualization work independently of the number of delivered packets.
	if(world.time >= flow_window)
		flow_window = world.time + 1 SECONDS
		flow_count = 0
	if(flow_count >= 20)
		return
	var/from = source.resolve_node()?.address
	var/destination = target.resolve_node()?.address
	if(!from || !destination || from == destination)
		return
	var/pair = "[from]>[destination]"
	if(last_flow[pair] > world.time)
		return
	if(length(last_flow) > 2048)
		last_flow.Cut()
	last_flow[pair] = world.time + 1 SECONDS
	flow_count++
	SSnetrun.post_event(kind, from, destination, path)

/// A cancellable packet checks the current route again when its latency elapses.
/datum/netrun_machine_packet
	var/datum/netrun_machine_service/source
	var/datum/netrun_machine_service/recipient
	var/timer_id
	var/finishing = FALSE
	var/kind = "machine"
	var/list/interest_route

/datum/netrun_machine_packet/New(datum/netrun_machine_service/source, datum/netrun_machine_service/recipient)
	src.source = source
	src.recipient = recipient

/datum/netrun_machine_packet/Destroy()
	if(timer_id)
		deltimer(timer_id)
	SSnetrun.get_machine_transport().packets -= src
	SSnetrun.get_machine_transport().interactive_packets -= src
	interest_route = null
	source = null
	recipient = null
	return ..()

/datum/netrun_machine_packet/proc/send()
	var/datum/netrun_machine_transport/transport = SSnetrun.get_machine_transport()
	var/datum/netrun_route/route = transport.route(source, recipient)
	if(!route || length(transport.packets) >= 2048)
		qdel(route)
		fail("нет сетевого маршрута")
		return FALSE
	transport.packets |= src
	var/mob/user = interest_user()
	var/mob/camera/netrun_entity/entity = user
	if(user?.client || (istype(entity) && entity.dive_link?.body?.client))
		interest_route = route.hops.Copy()
		transport.interactive_packets |= src
		SSnetrun.retain_route_interest(interest_route, world.time + NETRUN_NODE_INTEREST_LEASE)
	var/delay = clamp(route.latency, 1, 10 SECONDS)
	qdel(route)
	timer_id = addtimer(CALLBACK(src, PROC_REF(deliver)), delay, TIMER_STOPPABLE | TIMER_DELETE_ME)
	return TRUE

/datum/netrun_machine_packet/proc/deliver()
	timer_id = null
	if(finishing)
		return
	var/datum/netrun_route/route = SSnetrun.get_machine_transport().route(source, recipient)
	if(!route)
		fail("маршрут разорван")
		return
	finishing = TRUE
	SSnetrun.get_machine_transport().record_flow(source, recipient, kind, route.hops)
	qdel(route)
	execute()
	qdel(src)

/datum/netrun_machine_packet/proc/execute()
	return

/datum/netrun_machine_packet/proc/interest_user()
	return null

/datum/netrun_machine_packet/proc/fail(reason)
	if(finishing)
		return
	finishing = TRUE
	qdel(src)

/datum/netrun_machine_packet/data
	var/datum/netrun_machine_message/message
	var/recipient_tag

/datum/netrun_machine_packet/data/New(datum/netrun_machine_service/source, datum/netrun_machine_service/recipient, datum/netrun_machine_message/message)
	..(source, recipient)
	src.message = message
	message.source = source
	message.recipient = recipient
	recipient_tag = recipient?.service_tag()

/datum/netrun_machine_packet/data/Destroy()
	QDEL_NULL(message)
	return ..()

/datum/netrun_machine_packet/data/interest_user()
	return message.user_ref?.resolve()

/datum/netrun_machine_packet/data/execute()
	if(recipient.matches(source, recipient_tag) && recipient.accepts(message) && recipient.receive(message))
		message.delivered(recipient)
	else
		message.failed("получатель отклонил пакет")

/datum/netrun_machine_packet/data/fail(reason)
	if(!finishing)
		message?.failed(reason)
	return ..()

/// One in-flight query per service/tag coalesces telemetry without repeating commands.
/datum/netrun_machine_resolution
	var/datum/netrun_machine_service/source
	var/destination_id
	var/recipient_tag
	var/query_key
	var/list/queued = list()
	var/list/records = list()
	var/records_revision
	var/datum/netrun_machine_service/resolver
	var/timer_id
	var/attempts = 0
	var/completed = FALSE

/datum/netrun_machine_resolution/New(datum/netrun_machine_service/source, destination_id, recipient_tag)
	src.source = source
	src.destination_id = destination_id
	src.recipient_tag = recipient_tag
	query_key = "[destination_id]|[recipient_tag]"

/datum/netrun_machine_resolution/Destroy()
	if(timer_id)
		deltimer(timer_id)
	if(source?.resolutions[query_key] == src)
		source.resolutions -= query_key
	var/list/abandoned = queued.Copy()
	SSnetrun.get_machine_transport().queued_messages -= length(queued)
	queued.Cut()
	for(var/datum/netrun_machine_message/message as anything in abandoned)
		message.failed("DNS не ответил")
		qdel(message)
	records.Cut()
	source = null
	resolver = null
	return ..()

/datum/netrun_machine_resolution/proc/enqueue(datum/netrun_machine_message/message)
	var/coalescing_key = message.coalescing_key()
	if(!completed && !isnull(coalescing_key))
		for(var/i in 1 to length(queued))
			var/datum/netrun_machine_message/previous = queued[i]
			if(previous.coalescing_key() == coalescing_key)
				queued[i] = message
				qdel(previous)
				return TRUE
	var/datum/netrun_machine_transport/transport = SSnetrun.get_machine_transport()
	if(length(queued) >= 64 || completed || transport.queued_messages >= 4096)
		message.failed("очередь DNS заполнена")
		qdel(message)
		return FALSE
	queued += message
	transport.queued_messages++
	return TRUE

/datum/netrun_machine_resolution/proc/begin()
	timer_id = null
	var/list/servers = SSnetrun.get_machine_transport().lookup(source, "dns", null)
	if(!length(servers))
		if(++attempts >= 5)
			qdel(src)
			return
		timer_id = addtimer(CALLBACK(src, PROC_REF(begin)), 2 SECONDS, TIMER_STOPPABLE | TIMER_DELETE_ME)
		return
	resolver = servers[1]
	var/datum/netrun_machine_packet/dns_query/packet = new(source, resolver, src)
	packet.send()

/datum/netrun_machine_resolution/proc/answer()
	if(QDELETED(source) || QDELETED(resolver))
		qdel(src)
		return
	records = SSnetrun.get_machine_transport().lookup(source, destination_id, recipient_tag)
	records_revision = SSnetrun.get_machine_transport().service_revisions[destination_id]
	var/datum/netrun_machine_packet/dns_reply/packet = new(resolver, source, src)
	packet.send()

/datum/netrun_machine_resolution/proc/finish()
	completed = TRUE
	var/datum/netrun_machine_directory/entry = new
	entry.resolver_ref = WEAKREF(resolver)
	entry.expires = world.time + (length(records) ? 30 SECONDS : 2 SECONDS)
	entry.revision = records_revision
	for(var/datum/netrun_machine_service/target as anything in records)
		if(!QDELETED(target))
			entry.records += WEAKREF(target)
	qdel(source.directory[query_key])
	if(!(query_key in source.directory) && length(source.directory) >= 128)
		var/oldest = source.directory[1]
		qdel(source.directory[oldest])
		source.directory -= oldest
	source.directory[query_key] = entry
	source.resolutions -= query_key
	var/list/messages = queued.Copy()
	SSnetrun.get_machine_transport().queued_messages -= length(queued)
	queued.Cut()
	for(var/datum/netrun_machine_message/message as anything in messages)
		var/eligible = 0
		for(var/datum/netrun_machine_service/target as anything in records)
			if(!QDELETED(target) && target.matches(source, recipient_tag))
				eligible++
				source.send_to(target, message.copy())
		if(!eligible)
			message.failed("DNS: получатель не найден")
		qdel(message)
	source.directory_ready(destination_id, recipient_tag)
	qdel(src)

/datum/netrun_machine_packet/dns_query
	kind = "dns"
	var/datum/netrun_machine_resolution/query

/datum/netrun_machine_packet/dns_query/New(datum/netrun_machine_service/source, datum/netrun_machine_service/recipient, datum/netrun_machine_resolution/query)
	..(source, recipient)
	src.query = query
	RegisterSignal(query, COMSIG_PARENT_QDELETING, PROC_REF(query_deleted))

/datum/netrun_machine_packet/dns_query/proc/query_deleted()
	SIGNAL_HANDLER
	if(!finishing)
		fail("DNS-запрос отменён")

/datum/netrun_machine_packet/dns_query/Destroy()
	if(query)
		UnregisterSignal(query, COMSIG_PARENT_QDELETING)
	query = null
	return ..()

/datum/netrun_machine_packet/dns_query/execute()
	if(!QDELETED(query))
		query.answer()

/datum/netrun_machine_packet/dns_query/fail(reason)
	qdel(query)
	return ..()

/datum/netrun_machine_packet/dns_reply
	parent_type = /datum/netrun_machine_packet/dns_query

/datum/netrun_machine_packet/dns_reply/execute()
	if(!QDELETED(query))
		query.finish()
