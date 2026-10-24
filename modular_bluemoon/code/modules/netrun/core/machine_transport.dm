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
		if(!netrun_machine_services[id])
			netrun_machine_services[id] = new path(node, src)

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

/datum/netrun_machine_service/proc/key()
	return "[REF(host)]:[service_id]"

/datum/netrun_machine_service/proc/resolve_node()
	return node

/datum/netrun_machine_service/proc/tag()
	return resolve_node()?.address

/datum/netrun_machine_service/proc/matches(datum/netrun_machine_service/source_service, recipient_tag)
	return isnull(recipient_tag) || tag() == recipient_tag

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
	var/query_key = "[destination_id]|[recipient_tag]"
	var/datum/netrun_machine_directory/entry = directory[query_key]
	var/list/result = list()
	if(entry && entry.expires > world.time && entry.revision == SSnetrun.get_machine_transport().revision && can_reach(entry.resolver, FALSE))
		for(var/datum/weakref/ref as anything in entry.records)
			var/datum/netrun_machine_service/target = ref.resolve()
			if(!QDELETED(target) && target.matches(src, recipient_tag) && can_reach(target, FALSE))
				result += target
		return result
	get_resolution(destination_id, recipient_tag)
	return result

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
	if(QDELETED(target) || !SSnetrun.get_machine_transport().route(src, target))
		return FALSE
	if(!require_dns)
		return TRUE
	for(var/query_key in directory)
		var/datum/netrun_machine_directory/entry = directory[query_key]
		if(entry.expires <= world.time || !SSnetrun.get_machine_transport().route(src, entry.resolver))
			continue
		for(var/datum/weakref/ref as anything in entry.records)
			if(ref.resolve() == target)
				return TRUE
	return FALSE

/datum/netrun_machine_directory
	var/list/records = list()
	var/datum/netrun_machine_service/resolver
	var/expires
	var/revision

/// Registry metadata is local; query, answer and data each cross a real packet boundary.
/datum/netrun_machine_transport
	var/list/services = list()
	var/list/by_id = list()
	var/list/packets = list()
	var/list/last_flow = list()
	var/revision = 0

/datum/netrun_machine_transport/proc/register(datum/netrun_machine_service/service)
	services[service.key()] = service
	var/list/bucket = by_id[service.service_id]
	if(!bucket)
		bucket = list()
		by_id[service.service_id] = bucket
	bucket |= service
	revision++

/datum/netrun_machine_transport/proc/unregister(datum/netrun_machine_service/service)
	services -= service.key()
	var/list/bucket = by_id[service.service_id]
	bucket -= service
	revision++
	for(var/datum/netrun_machine_packet/packet as anything in packets.Copy())
		if(packet.source == service || packet.recipient == service)
			packet.fail("машина отключена")

/datum/netrun_machine_transport/proc/lookup(datum/netrun_machine_service/source, destination_id, recipient_tag)
	. = list()
	var/list/bucket = by_id[destination_id]
	for(var/datum/netrun_machine_service/target as anything in bucket)
		if(!QDELETED(target) && target.matches(source, recipient_tag) && route(source, target))
			. += target

/// Borrowed route trees are shared, but every selected physical edge is checked live.
/datum/netrun_machine_transport/proc/route(datum/netrun_machine_service/source, datum/netrun_machine_service/recipient)
	if(QDELETED(source) || QDELETED(recipient) || QDELETED(source.host) || QDELETED(recipient.host))
		return null
	var/datum/component/netrun_node/start = source.resolve_node()
	var/datum/component/netrun_node/finish = recipient.resolve_node()
	if(QDELETED(start) || QDELETED(finish) || !start.is_online() || !finish.is_online())
		return null
	SSnetrun.ensure_topology()
	var/datum/netrun_topology/graph = SSnetrun.get_topology()
	var/datum/netrun_path_tree/tree = graph.route_snapshot(start, TRUE)
	var/list/path = tree?.addresses_to(finish.address)
	if(!length(path))
		return null
	for(var/i in 2 to length(path))
		if(!netrun_link_available(graph.nodes[path[i - 1]], graph.nodes[path[i]]))
			return null
	var/datum/netrun_route/result = new
	result.hops = path
	result.latency = tree.cost_to(finish.address)
	return result

/datum/netrun_machine_transport/proc/dispatch(datum/netrun_machine_service/source, datum/netrun_machine_service/target, datum/netrun_machine_message/message)
	if(QDELETED(message))
		return FALSE
	var/datum/netrun_machine_packet/data/packet = new(source, target, message)
	return packet.send()

/datum/netrun_machine_transport/proc/record_flow(datum/netrun_machine_service/source, datum/netrun_machine_service/target, kind)
	var/from = source.resolve_node()?.address
	var/to = target.resolve_node()?.address
	if(!from || !to || from == to)
		return
	var/pair = "[from]>[to]"
	if(last_flow[pair] > world.time)
		return
	if(length(last_flow) > 2048)
		last_flow.Cut()
	last_flow[pair] = world.time + 1 SECONDS
	SSnetrun.post_event(kind, from, to)

/// A cancellable packet checks the current route again when its latency elapses.
/datum/netrun_machine_packet
	var/datum/netrun_machine_service/source
	var/datum/netrun_machine_service/recipient
	var/timer_id
	var/finishing = FALSE
	var/kind = "machine"

/datum/netrun_machine_packet/New(datum/netrun_machine_service/source, datum/netrun_machine_service/recipient)
	src.source = source
	src.recipient = recipient

/datum/netrun_machine_packet/Destroy()
	if(timer_id)
		deltimer(timer_id)
	SSnetrun.get_machine_transport().packets -= src
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
	qdel(route)
	finishing = TRUE
	SSnetrun.get_machine_transport().record_flow(source, recipient, kind)
	execute()
	qdel(src)

/datum/netrun_machine_packet/proc/execute()
	return

/datum/netrun_machine_packet/proc/fail(reason)
	if(finishing)
		return
	finishing = TRUE
	qdel(src)

/datum/netrun_machine_packet/data
	var/datum/netrun_machine_message/message

/datum/netrun_machine_packet/data/New(datum/netrun_machine_service/source, datum/netrun_machine_service/recipient, datum/netrun_machine_message/message)
	..(source, recipient)
	src.message = message
	message.source = source
	message.recipient = recipient

/datum/netrun_machine_packet/data/Destroy()
	QDEL_NULL(message)
	return ..()

/datum/netrun_machine_packet/data/execute()
	if(recipient.accepts(message) && recipient.receive(message))
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
	for(var/datum/netrun_machine_message/message as anything in queued)
		message.failed("DNS не ответил")
		qdel(message)
	queued.Cut()
	source = null
	resolver = null
	return ..()

/datum/netrun_machine_resolution/proc/enqueue(datum/netrun_machine_message/message)
	if(length(queued) >= 64 || completed)
		message.failed("очередь DNS заполнена")
		qdel(message)
		return FALSE
	queued += message
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
	var/datum/netrun_machine_packet/dns_reply/packet = new(resolver, source, src)
	packet.send()

/datum/netrun_machine_resolution/proc/finish()
	completed = TRUE
	var/datum/netrun_machine_directory/entry = new
	entry.resolver = resolver
	entry.expires = world.time + (length(records) ? 30 SECONDS : 2 SECONDS)
	entry.revision = SSnetrun.get_machine_transport().revision
	for(var/datum/netrun_machine_service/target as anything in records)
		if(!QDELETED(target))
			entry.records += WEAKREF(target)
	qdel(source.directory[query_key])
	source.directory[query_key] = entry
	source.resolutions -= query_key
	for(var/datum/netrun_machine_message/message as anything in queued)
		if(!length(records))
			message.failed("DNS: получатель не найден")
		else
			for(var/datum/netrun_machine_service/target as anything in records)
				if(!QDELETED(target) && target.matches(source, recipient_tag))
					source.send_to(target, message.copy())
		qdel(message)
	queued.Cut()
	source.directory_ready(destination_id, recipient_tag)
	qdel(src)

/datum/netrun_machine_packet/dns_query
	kind = "dns"
	var/datum/netrun_machine_resolution/query

/datum/netrun_machine_packet/dns_query/New(datum/netrun_machine_service/source, datum/netrun_machine_service/recipient, datum/netrun_machine_resolution/query)
	..(source, recipient)
	src.query = query

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
