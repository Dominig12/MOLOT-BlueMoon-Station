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

/datum/netrun_machine_message/research/failed(reason)
	var/mob/user = user_ref?.resolve()
	if(user)
		to_chat(user, span_warning("Исследовательский пакет не доставлен: [reason]."))

/datum/netrun_machine_service/research_server
	service_id = "research.server"
	var/datum/techweb/web
	var/list/subscribers = list()
	var/publish_timer

/datum/netrun_machine_service/research_server/New(datum/component/netrun_node/node)
	..()
	bind_research()

/datum/netrun_machine_service/research_server/Destroy()
	if(publish_timer)
		deltimer(publish_timer)
	if(web)
		UnregisterSignal(web, COMSIG_NETRUN_RESEARCH_CHANGED)
	web = null
	subscribers.Cut()
	return ..()

/datum/netrun_machine_service/research_server/tag()
	var/obj/machinery/rnd/server/server = host
	return server.stored_research ? REF(server.stored_research) : null

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
	if(!publish_timer)
		publish_timer = addtimer(CALLBACK(src, PROC_REF(publish)), 1.5 SECONDS, TIMER_STOPPABLE | TIMER_DELETE_ME)

/datum/netrun_machine_service/research_server/proc/snapshot()
	return list("operation" = "snapshot", "binding" = REF(web), "organization" = web.organization,
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
	if(operation != "snapshot")
		var/obj/machinery/computer/rdconsole/console = message.source.host
		var/mob/user = message.user_ref?.resolve()
		if(!istype(console) || QDELETED(user) || console.locked || !console.research_control)
			return FALSE
		switch(operation)
			if("research")
				success = console.perform_research_node(message.payload["node_id"], user)
			if("upload_nodes")
				var/list/ids = message.payload["nodes"]
				if(!islist(ids))
					return FALSE
				for(var/id in ids)
					if(SSresearch.techweb_nodes[id] && !web.researched_nodes[id])
						web.research_node_id(id, TRUE, FALSE)
				SEND_SIGNAL(web, COMSIG_NETRUN_RESEARCH_CHANGED)
			if("upload_designs")
				var/list/ids = message.payload["designs"]
				if(!islist(ids))
					return FALSE
				for(var/id in ids)
					var/datum/design/design = SSresearch.techweb_design_by_id(id)
					if(istype(design))
						web.add_design(design, TRUE)
				SEND_SIGNAL(web, COMSIG_NETRUN_RESEARCH_CHANGED)
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
	return binding && message.source?.service_id == "research.server" && message.payload["binding"] == REF(binding)

/datum/netrun_machine_service/research_client/receive(datum/netrun_machine_message/message)
	if(!accepts(message))
		return FALSE
	var/list/data = message.payload
	if(data["operation"] != "snapshot")
		return FALSE
	var/obj/machinery/rnd/production/production = host
	if(istype(production))
		production.receive_research_snapshot(data)
	else
		var/obj/machinery/computer/rdconsole/console = host
		if(!istype(console))
			return FALSE
		if(!console.netrun_research_cache)
			console.netrun_research_cache = new
		netrun_apply_research_snapshot(console.netrun_research_cache, data)
		if(data["requested_operation"] == "download_disk" && console.t_disk && REF(console.t_disk) == data["disk"])
			netrun_apply_research_snapshot(console.t_disk.stored_research, data)
			console.say("Техвеб получен по сети и записан на диск.")
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

/obj/machinery/rnd/production/proc/receive_research_snapshot(list/data)
	var/list/known = designs_cache_built ? stored_research.researched_designs.Copy() : null
	netrun_apply_research_snapshot(stored_research, data)
	if(known)
		update_designs_incremental(known)
	else
		update_designs()
	handle_research_batch_complete()

/obj/machinery/rnd/server/proc/refresh_research_service()
	var/datum/netrun_machine_service/research_server/service = get_netrun_machine_service("research.server")
	service?.bind_research()
