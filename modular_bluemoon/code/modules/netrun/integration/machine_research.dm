/// Research information is copied only by delivered machine packets. A holder's
/// logical techweb selects its server; it never replaces physical routing/DNS.
/obj/machinery/rnd/server/netrun_machine_service_types()
	. = ..()
	. |= /datum/netrun_machine_service/research_server

/obj/machinery/computer/rdconsole/netrun_machine_service_types()
	. = ..()
	. |= /datum/netrun_machine_service/research_client

/obj/machinery/rnd/production/netrun_machine_service_types()
	. = ..()
	. |= /datum/netrun_machine_service/research_client

/obj/machinery/mecha_part_fabricator/netrun_machine_service_types()
	. = ..()
	. |= /datum/netrun_machine_service/research_client

/datum/netrun_machine_message/research/failed(reason)
	var/mob/user = user_ref?.resolve()
	if(user)
		to_chat(user, span_warning("Исследовательский пакет не доставлен: [reason]."))

/datum/netrun_machine_message/research/coalescing_key()
	if(payload["operation"] in list("snapshot", "watch"))
		return "research.snapshot|[payload["binding"]]"
	return null

/datum/netrun_machine_service/research_server
	service_id = "research.server"
	var/datum/techweb/web
	var/list/subscribers = list()
	var/publish_timer

/datum/netrun_machine_service/research_server/New(datum/component/netrun_node/node, atom/host_override)
	..(node, host_override)
	bind_research()

/datum/netrun_machine_service/research_server/Destroy()
	if(publish_timer)
		deltimer(publish_timer)
	if(web)
		UnregisterSignal(web, COMSIG_NETRUN_RESEARCH_CHANGED)
	web = null
	subscribers.Cut()
	return ..()

/datum/netrun_machine_service/research_server/service_tag()
	var/obj/machinery/rnd/server/server = host
	return server.stored_research ? REF(server.stored_research) : null

/// A farm is one logical authority: DNS selects one reachable physical endpoint.
/datum/netrun_machine_service/research_server/matches(datum/netrun_machine_service/source_service, recipient_tag)
	if(!..() || !research_peer(source_service))
		return FALSE
	var/datum/netrun_machine_transport/transport = SSnetrun.get_machine_transport()
	var/list/servers = transport.by_id[service_id]
	for(var/datum/netrun_machine_service/research_server/server as anything in servers)
		if(QDELETED(server) || server.service_tag() != recipient_tag)
			continue
		var/datum/netrun_route/route = transport.route(source_service, server)
		if(!route)
			continue
		qdel(route)
		return server == src
	return FALSE

/datum/netrun_machine_service/research_server/proc/bind_research()
	var/obj/machinery/rnd/server/server = host
	if(web == server.stored_research)
		return
	if(web)
		UnregisterSignal(web, COMSIG_NETRUN_RESEARCH_CHANGED)
	web = server.stored_research
	subscribers.Cut()
	if(web)
		RegisterSignal(web, COMSIG_NETRUN_RESEARCH_CHANGED, PROC_REF(on_research_changed))

/datum/netrun_machine_service/research_server/proc/on_research_changed(datum/source)
	SIGNAL_HANDLER
	if(!length(subscribers))
		return
	if(!publish_timer)
		publish_timer = addtimer(CALLBACK(src, PROC_REF(publish)), 1.5 SECONDS, TIMER_STOPPABLE | TIMER_DELETE_ME)

/datum/netrun_machine_service/research_server/proc/snapshot()
	return list("operation" = "snapshot", "binding" = REF(web), "revision" = web.netrun_research_revision, "organization" = web.organization,
		"researched_nodes" = web.researched_nodes.Copy(), "researched_designs" = web.researched_designs.Copy(),
		"custom_designs" = web.custom_designs.Copy(), "hidden_nodes" = web.hidden_nodes.Copy(),
		"visible_nodes" = web.visible_nodes.Copy(), "boosted_nodes" = deepCopyList(web.boosted_nodes),
		"research_points" = web.research_points.Copy(), "last_bitcoins" = web.last_bitcoins.Copy())

/datum/netrun_machine_service/research_server/proc/publish()
	publish_timer = null
	bind_research()
	if(!web)
		return
	var/list/data = snapshot()
	for(var/address in subscribers.Copy())
		var/datum/weakref/reference = subscribers[address]
		var/datum/netrun_machine_service/client = reference?.resolve()
		if(QDELETED(client) || !research_peer(client))
			subscribers -= address
			continue
		send_to(client, new /datum/netrun_machine_message/research(deepCopyList(data)))

/datum/netrun_machine_service/research_server/proc/research_peer(datum/netrun_machine_service/peer)
	return peer?.service_id == "research.client" && web && netrun_atom_techweb(peer.host) == web

/datum/netrun_machine_service/research_server/accepts(datum/netrun_machine_message/message)
	bind_research()
	return research_peer(message.source) && message.payload["binding"] == REF(web)

/datum/netrun_machine_service/research_server/receive(datum/netrun_machine_message/message)
	if(!accepts(message))
		return FALSE
	subscribers[message.source.node.address] = WEAKREF(message.source)
	var/operation = message.payload["operation"]
	var/success = TRUE
	if(operation == "watch")
		if(message.payload["revision"] == web.netrun_research_revision)
			message.reply(new /datum/netrun_machine_message/research(list("operation" = "current", "binding" = REF(web), "revision" = web.netrun_research_revision)))
			return TRUE
		operation = "snapshot"
	if(operation != "snapshot")
		var/obj/machinery/computer/rdconsole/console = message.source.host
		var/mob/user = message.user_ref?.resolve()
		if(!istype(console) || QDELETED(user) || console.locked)
			return FALSE
		switch(operation)
			if("research")
				if(!console.research_control)
					return FALSE
				success = console.perform_research_node(message.payload["node_id"], user)
			if("upload_nodes")
				var/list/ids = message.payload["nodes"]
				if(!islist(ids))
					return FALSE
				for(var/id in ids)
					if(SSresearch.techweb_nodes[id] && !web.researched_nodes[id])
						web.research_node_id(id, TRUE, FALSE)
				var/list/design_ids = message.payload["designs"]
				for(var/id in design_ids)
					web.add_design_by_id(id, TRUE)
				web.netrun_research_changed()
			if("upload_designs")
				var/list/ids = message.payload["designs"]
				if(!islist(ids))
					return FALSE
				for(var/id in ids)
					var/datum/design/design = SSresearch.techweb_design_by_id(id)
					if(istype(design))
						web.add_design(design, TRUE)
				web.netrun_research_changed()
			if("download_disk")
				// The response carries copied data; a changed/ejected disk is not overwritten.
				success = TRUE
			else
				return FALSE
	var/list/data = snapshot()
	data["success"] = success
	data["requested_operation"] = operation
	data["disk"] = message.payload["disk"]
	var/datum/netrun_machine_message/research/response = new(data)
	response.user_ref = message.user_ref
	message.reply(response)
	return TRUE

/datum/netrun_machine_service/research_client
	service_id = "research.client"
	var/snapshot_binding
	var/snapshot_revision = -1
	var/datum/weakref/subscription_ref
	var/resync_timer

/datum/netrun_machine_service/research_client/New(datum/component/netrun_node/node, atom/host_override)
	..(node, host_override)
	RegisterSignal(host, COMSIG_ATOM_TECHWEB_CHANGED, PROC_REF(binding_changed))
	resync_timer = addtimer(CALLBACK(src, PROC_REF(check_subscription)), 30 SECONDS, TIMER_STOPPABLE | TIMER_DELETE_ME)

/datum/netrun_machine_service/research_client/Destroy()
	if(resync_timer)
		deltimer(resync_timer)
	if(host)
		UnregisterSignal(host, COMSIG_ATOM_TECHWEB_CHANGED)
	subscription_ref = null
	return ..()

/datum/netrun_machine_service/research_client/proc/binding_changed(datum/source, datum/techweb/new_web)
	SIGNAL_HANDLER
	snapshot_binding = null
	snapshot_revision = -1
	subscription_ref = null

/// A small revision watch repairs missed pushes, including outages between checks.
/// Full snapshots are returned only when the local revision differs.
/datum/netrun_machine_service/research_client/proc/check_subscription()
	resync_timer = null
	var/datum/techweb/binding = netrun_atom_techweb(host)
	if(!binding && istype(host, /obj/machinery/mecha_part_fabricator))
		var/obj/machinery/mecha_part_fabricator/fabricator = host
		fabricator.sync(TRUE, TRUE)
	if(binding)
		request("watch", extra = list("revision" = snapshot_binding == REF(binding) ? snapshot_revision : -1))
	resync_timer = addtimer(CALLBACK(src, PROC_REF(check_subscription)), 30 SECONDS, TIMER_STOPPABLE | TIMER_DELETE_ME)

/datum/netrun_machine_service/research_client/proc/request(operation = "snapshot", mob/user, list/extra)
	var/datum/techweb/binding = netrun_atom_techweb(host)
	if(!binding)
		return FALSE
	var/list/data = extra ? extra.Copy() : list()
	data["operation"] = operation
	data["binding"] = REF(binding)
	var/datum/netrun_machine_message/research/message = new(data)
	if(user)
		message.user_ref = WEAKREF(user)
	return send("research.server", message, REF(binding))

/datum/netrun_machine_service/research_client/accepts(datum/netrun_machine_message/message)
	var/datum/techweb/binding = netrun_atom_techweb(host)
	return binding && message.source?.service_id == "research.server" && netrun_atom_techweb(message.source.host) == binding && message.payload["binding"] == REF(binding)

/datum/netrun_machine_service/research_client/receive(datum/netrun_machine_message/message)
	if(!accepts(message))
		return FALSE
	var/list/data = message.payload
	if(data["operation"] == "current")
		if(snapshot_binding != data["binding"] || snapshot_revision < data["revision"])
			request()
		else
			subscription_ref = WEAKREF(message.source)
		return TRUE
	if(data["operation"] != "snapshot")
		return FALSE
	if(snapshot_binding == data["binding"] && snapshot_revision > data["revision"])
		var/obj/machinery/computer/rdconsole/console = host
		if(istype(console))
			console.receive_research_disk_snapshot(data)
		return TRUE
	snapshot_binding = data["binding"]
	snapshot_revision = data["revision"]
	subscription_ref = WEAKREF(message.source)
	var/obj/machinery/rnd/production/production = host
	if(istype(production))
		production.receive_research_snapshot(data)
	else if(istype(host, /obj/machinery/mecha_part_fabricator))
		var/obj/machinery/mecha_part_fabricator/fabricator = host
		var/list/known = fabricator.stored_research.researched_nodes.Copy()
		netrun_apply_research_snapshot(fabricator.stored_research, data)
		for(var/id in fabricator.stored_research.researched_designs.Copy())
			var/datum/design/design = SSresearch.techweb_design_by_id(id)
			if(!(design.build_type & MECHFAB))
				fabricator.stored_research.researched_designs -= id
		var/list/new_nodes = data["researched_nodes"] - known
		fabricator.update_static_data_for_all_viewers()
		INVOKE_ASYNC(fabricator, TYPE_PROC_REF(/obj/machinery/mecha_part_fabricator, handle_research_batch_complete), new_nodes)
	else
		var/obj/machinery/computer/rdconsole/console = host
		if(!istype(console))
			return FALSE
		if(!console.netrun_research_cache)
			console.netrun_research_cache = new /datum/techweb/netrun_snapshot
		netrun_apply_research_snapshot(console.netrun_research_cache, data)
		console.receive_research_disk_snapshot(data)
	SStgui.update_uis(host)
	SEND_SIGNAL(host, COMSIG_NETRUN_SERVICE_STATE_CHANGED)
	return TRUE

/// This is a cache assignment, not research: no points are spent and no science bounty is paid.
/proc/netrun_apply_research_snapshot(datum/techweb/cache, list/data)
	cache.researched_nodes = data["researched_nodes"].Copy()
	cache.researched_designs = data["researched_designs"].Copy()
	cache.custom_designs = data["custom_designs"].Copy()
	cache.hidden_nodes = data["hidden_nodes"].Copy()
	cache.visible_nodes = data["visible_nodes"].Copy()
	cache.boosted_nodes = deepCopyList(data["boosted_nodes"])
	cache.research_points = data["research_points"].Copy()
	cache.last_bitcoins = data["last_bitcoins"].Copy()
	cache.organization = data["organization"]
	cache.recalculate_nodes()

/obj/machinery/computer/rdconsole
	var/datum/techweb/netrun_research_cache

/obj/machinery/computer/rdconsole/proc/request_research_snapshot()
	var/datum/netrun_machine_service/research_client/client = get_netrun_machine_service("research.client")
	return client?.request()

/obj/machinery/computer/rdconsole/proc/request_research_action(operation, mob/user, list/data)
	var/datum/netrun_machine_service/research_client/client = get_netrun_machine_service("research.client")
	return client?.request(operation, user, data)

/obj/machinery/computer/rdconsole/proc/receive_research_disk_snapshot(list/data)
	if(data["requested_operation"] != "download_disk" || !t_disk || REF(t_disk) != data["disk"])
		return
	var/datum/techweb/disk = t_disk.stored_research
	disk.researched_nodes |= data["researched_nodes"]
	disk.researched_designs |= data["researched_designs"]
	disk.custom_designs |= data["custom_designs"]
	for(var/id in disk.hidden_nodes.Copy())
		if(!data["hidden_nodes"][id])
			disk.hidden_nodes -= id
	disk.recalculate_nodes()
	say("Техвеб получен по сети и записан на диск.")
	SStgui.update_uis(src)

/obj/machinery/rnd/production/proc/receive_research_snapshot(list/data)
	var/list/known = designs_cache_built ? stored_research.researched_designs.Copy() : null
	netrun_apply_research_snapshot(stored_research, data)
	if(known && !length(known - stored_research.researched_designs))
		update_designs_incremental(known)
	else
		update_designs()
	INVOKE_ASYNC(src, PROC_REF(handle_research_batch_complete))

/// Authoritative web mutations publish once per batch; received caches never emit this signal.
/datum/techweb
	var/netrun_research_revision = 0

/datum/techweb/proc/netrun_research_changed()
	netrun_research_revision++
	SEND_SIGNAL(src, COMSIG_NETRUN_RESEARCH_CHANGED)

/// Local recipes may exist before the first packet without paying research bounties.
/datum/techweb/netrun_snapshot/New()
	hidden_nodes = SSresearch.techweb_nodes_hidden.Copy()
	for(var/id in SSresearch.techweb_nodes_starting)
		var/datum/techweb_node/node = SSresearch.techweb_node_by_id(id)
		researched_nodes[id] = TRUE
		for(var/design_id in node.design_ids)
			researched_designs[design_id] = TRUE
		for(var/unlock_id in node.unlock_ids)
			visible_nodes[unlock_id] = TRUE
	recalculate_nodes()

/obj/machinery/rnd/server/proc/refresh_research_service()
	var/datum/netrun_machine_service/research_server/service = get_netrun_machine_service("research.server")
	service?.bind_research()

/obj/machinery/mecha_part_fabricator/proc/on_netrun_techweb_changed(datum/source, datum/techweb/new_web)
	SIGNAL_HANDLER
	QDEL_NULL(stored_research)
	stored_research = new /datum/techweb/netrun_snapshot
	INVOKE_ASYNC(src, PROC_REF(sync), TRUE, TRUE)

/obj/machinery/mecha_part_fabricator/LateInitialize()
	. = ..()
	sync(TRUE, TRUE)
