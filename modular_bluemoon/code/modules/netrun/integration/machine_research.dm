/// Research information is copied only by delivered machine packets. A holder's
/// logical techweb selects its server; it never replaces physical routing/DNS.
/atom/netrun_machine_service_types()
	. = ..()
	if(GetComponent(/datum/component/techweb_holder) && !istype(src, /obj/machinery/rnd/server))
		. |= /datum/netrun_machine_service/research_client

/// Selection may inspect physical connectivity; data still travels through DNS and packets.
/proc/netrun_research_route_available(atom/source, obj/machinery/rnd/server/server)
	if(QDELETED(source) || QDELETED(server) || !server.netrun_online())
		return FALSE
	var/datum/component/netrun_node/source_node = source.netrun_machine_service_node()
	var/datum/component/netrun_node/server_node = server.netrun_machine_service_node()
	if(!source_node || !server_node)
		return FALSE
	var/datum/netrun_machine_service/research_client/client = source.get_netrun_machine_service("research.client")
	var/datum/netrun_machine_service/research_server/authority = server.get_netrun_machine_service("research.server")
	if(!client || !authority || !SSnetrun.get_machine_transport().is_ready())
		return FALSE
	return client.can_reach(authority, FALSE)

/// Revalidate grants at the native resource/technology boundary, including route loss.
/proc/netrun_research_authorizes(atom/source, datum/techweb/web, design_id)
	if(QDELETED(source) || QDELETED(web) || netrun_atom_techweb(source) != web)
		return FALSE
	var/datum/netrun_machine_service/research_client/client = source.get_netrun_machine_service("research.client")
	if(client?.live_authority() != web)
		return FALSE
	return !design_id || web.researched_designs[design_id]

/atom/proc/netrun_research_snapshot()
	var/datum/netrun_machine_service/research_client/client = get_netrun_machine_service("research.client")
	if(!client)
		return null
	if(client.live_authority())
		if(istype(src, /obj/machinery/computer/rdconsole))
			var/obj/machinery/computer/rdconsole/console = src
			return console.netrun_research_cache
		if(istype(src, /obj/machinery/rnd/production))
			var/obj/machinery/rnd/production/production = src
			return production.stored_research
		if(istype(src, /obj/machinery/mecha_part_fabricator))
			var/obj/machinery/mecha_part_fabricator/fabricator = src
			return fabricator.stored_research
		if(client.snapshot_cache)
			return client.snapshot_cache
	client.request()
	return null

/atom/proc/netrun_research_request(operation, list/data, mob/user)
	var/datum/netrun_machine_service/research_client/client = get_netrun_machine_service("research.client")
	return client?.request(operation, user, data)
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
	var/datum/netrun_machine_service/research_client/client = requester_ref?.resolve()
	client?.finish_design(payload["design_token"], null)
	var/mob/user = user_ref?.resolve()
	if(user)
		to_chat(user, span_warning("Исследовательский пакет не доставлен: [reason]."))

/datum/netrun_machine_message/research
	var/datum/weakref/requester_ref

/datum/netrun_machine_message/research/copy()
	var/datum/netrun_machine_message/research/result = ..()
	result.requester_ref = requester_ref
	return result

/datum/netrun_machine_message/research/coalescing_key()
	var/requested = payload["requested_operation"]
	if(requested && !(requested in list("snapshot", "watch")))
		return null
	if(payload["operation"] in list("snapshot", "watch"))
		return "research.[payload["operation"]]|[payload["binding"]]|[payload["generation"]]"
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

/// Each physical server has a distinct authority; another server cannot answer for it.
/datum/netrun_machine_service/research_server/matches(datum/netrun_machine_service/source_service, recipient_tag)
	return ..() && research_peer(source_service)

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
		"available_nodes" = web.available_nodes.Copy(), "tiers" = web.tiers.Copy(),
		"custom_designs" = web.custom_designs.Copy(), "hidden_nodes" = web.hidden_nodes.Copy(),
		"visible_nodes" = web.visible_nodes.Copy(), "boosted_nodes" = deepCopyList(web.boosted_nodes),
		"research_points" = web.research_points.Copy(), "last_bitcoins" = web.last_bitcoins.Copy(),
		"discovered_mutations" = web.discovered_mutations.Copy(), "deconstructed_items" = web.deconstructed_items.Copy(),
		"problem_computer_charges" = web.get_problem_computer_charges(), "problem_computer_max_charges" = web.problem_computer_max_charges)

/datum/netrun_machine_service/research_server/proc/publish()
	publish_timer = null
	bind_research()
	if(!web)
		return
	var/list/data = snapshot()
	for(var/address in subscribers.Copy())
		var/list/subscription = subscribers[address]
		var/datum/weakref/reference = subscription["client"]
		var/datum/netrun_machine_service/client = reference?.resolve()
		if(QDELETED(client) || !research_peer(client) || client:binding_generation != subscription["generation"])
			subscribers -= address
			continue
		data["generation"] = subscription["generation"]
		// Message construction already owns a deep copy of its payload.
		send_to(client, new /datum/netrun_machine_message/research(data))

/datum/netrun_machine_service/research_server/proc/research_peer(datum/netrun_machine_service/peer)
	return peer?.service_id == "research.client" && !QDELETED(web) && web.research_owner_ref?.resolve() == host && netrun_atom_techweb(peer.host) == web

/datum/netrun_machine_service/research_server/accepts(datum/netrun_machine_message/message)
	bind_research()
	var/datum/netrun_machine_service/research_client/client = message.source
	return ..() && research_peer(client) && message.payload["binding"] == REF(web) && message.payload["generation"] == client.binding_generation

/datum/netrun_machine_service/research_server/receive(datum/netrun_machine_message/message)
	if(!accepts(message))
		return FALSE
	var/operation = message.payload["operation"]
	if(operation in list("snapshot", "watch"))
		subscribers[message.source.node.address] = list("client" = WEAKREF(message.source), "generation" = message.payload["generation"])
	var/success = TRUE
	if(operation == "watch")
		if(message.payload["revision"] == web.netrun_research_revision)
			message.reply(new /datum/netrun_machine_message/research(list("operation" = "current", "binding" = REF(web), "revision" = web.netrun_research_revision, "generation" = message.payload["generation"])))
			return TRUE
		operation = "snapshot"
	if(operation == "design")
		var/id = message.payload["design_id"]
		message.reply(new /datum/netrun_machine_message/research(list("operation" = "design", "binding" = REF(web), "generation" = message.payload["generation"], "design_token" = message.payload["design_token"], "design_id" = id, "success" = !!web.researched_designs[id])))
		return TRUE
	if(operation == "credit")
		web.add_point_list(message.payload["points"])
		// Delivery already has an outcome; credit-only telemetry needs no database reply.
		return TRUE
	if(operation == "explosion")
		var/obj/machinery/doppler_array/research/sensor = message.source.host
		var/value = message.payload["value"]
		if(!istype(sensor) || !isnum(value) || value <= 0)
			return FALSE
		var/previous = web.largest_values[LARGEST_BOMB] || 0
		if(value > previous)
			var/points = value - previous
			web.largest_values[LARGEST_BOMB] = value
			web.add_point_type(TECHWEB_POINT_TYPE_DEFAULT, points)
			var/datum/bank_account/account = SSeconomy.get_dep_account(ACCOUNT_SCI)
			account?.adjust_money(points)
			sensor.say("Explosion analyzed: [points] research points and credits received.")
		else
			sensor.say("Data already captured. Aborting.")
		operation = "snapshot"
	if(operation == "problem")
		var/obj/item/computermath/science/computer = message.source.host
		var/mob/user = message.user_ref?.resolve()
		if(!istype(computer) || QDELETED(user) || !(message.payload["difficulty"] in list("Easy", "Medium", "Hard")))
			return FALSE
		if(web.consume_problem_computer_charge())
			computer.handle_reward(user, "Science", !!message.payload["correct"], message.payload["difficulty"], web)
		else
			computer.last_points = 0
			computer.last_message = "На сервере закончились задачи."
		web.netrun_research_changed()
		SStgui.update_uis(computer)
		operation = "snapshot"
	if(operation == "mutation")
		var/path = message.payload["mutation"]
		if(!ispath(path, /datum/mutation/human))
			return FALSE
		web.discovered_mutations |= path
		web.netrun_research_changed()
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
				success = console.perform_research_node(message.payload["node_id"], user, web)
			if("analyze")
				success = console.perform_research_analysis(message.payload, user, web)
			if("boost")
				var/datum/techweb_node/node = SSresearch.techweb_node_by_id(message.payload["node_id"])
				success = web.boost_with_path(node, message.payload["item_type"])
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
	data["generation"] = message.payload["generation"]
	data["success"] = success
	data["requested_operation"] = operation
	data["disk"] = message.payload["disk"]
	var/datum/netrun_machine_message/research/response = new(data)
	response.user_ref = message.user_ref
	message.reply(response)
	return TRUE

/datum/netrun_machine_service/research_client
	service_id = "research.client"
	var/wants_snapshots = FALSE
	var/binding_generation = 0
	var/datum/techweb/snapshot_cache
	var/list/pending_designs = list()
	var/design_serial = 0
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
	for(var/token in pending_designs.Copy())
		finish_design(token, null)
	QDEL_NULL(snapshot_cache)
	subscription_ref = null
	return ..()

/datum/netrun_machine_service/research_client/proc/binding_changed(datum/source, datum/techweb/new_web)
	SIGNAL_HANDLER
	binding_generation++
	for(var/token in pending_designs.Copy())
		finish_design(token, null)
	QDEL_NULL(snapshot_cache)
	snapshot_binding = null
	snapshot_revision = -1
	subscription_ref = null
	if(wants_snapshots)
		INVOKE_ASYNC(src, PROC_REF(request))

/datum/netrun_machine_service/research_client/proc/resolve_binding()
	var/datum/techweb/binding = netrun_atom_techweb(host)
	if(binding)
		return binding
	var/datum/component/techweb_holder/holder = host.GetComponent(/datum/component/techweb_holder)
	if(!holder || holder.had_authority)
		return null
	var/selector = ("network_id" in host.vars) ? host.vars["network_id"] : RND_NETWORK_AUTO
	binding = SSresearch.get_rnd_network_for(host, selector)
	if(binding)
		SEND_SIGNAL(host, COMSIG_ATOM_SET_TECHWEB, binding)
	return binding

/datum/netrun_machine_service/research_client/proc/live_authority()
	var/datum/techweb/binding = netrun_atom_techweb(host)
	var/obj/machinery/rnd/server/owner = binding?.research_owner_ref?.resolve()
	if(QDELETED(owner) || !owner.netrun_online())
		return null
	var/datum/netrun_machine_service/research_server/server = owner.get_netrun_machine_service("research.server")
	return can_reach(server) ? binding : null

/// One design request yields one grant; no retry can replay native resource consumption.
/datum/netrun_machine_service/research_client/proc/request_design(design_id, datum/callback/complete)
	if(!live_authority() || length(pending_designs) >= 1)
		qdel(complete)
		return FALSE
	var/token = "[binding_generation]:[++design_serial]"
	pending_designs[token] = list("design" = design_id, "complete" = complete)
	addtimer(CALLBACK(src, PROC_REF(finish_design), token, null), 5 SECONDS)
	if(request("design", extra = list("design_id" = design_id, "design_token" = token)))
		return TRUE
	finish_design(token, null)
	return FALSE

/datum/netrun_machine_service/research_client/proc/finish_design(token, datum/techweb/granted)
	if(!istext(token))
		return
	var/list/pending = pending_designs[token]
	if(!pending)
		return
	pending_designs -= token
	var/datum/callback/complete = pending["complete"]
	complete?.Invoke(granted)
	qdel(complete)

/// A small revision watch repairs missed pushes, including outages between checks.
/// Full snapshots are returned only when the local revision differs.
/datum/netrun_machine_service/research_client/proc/check_subscription()
	resync_timer = null
	var/datum/techweb/binding = wants_snapshots ? resolve_binding() : null
	if(wants_snapshots && !binding && istype(host, /obj/machinery/mecha_part_fabricator))
		var/obj/machinery/mecha_part_fabricator/fabricator = host
		fabricator.sync(TRUE, TRUE)
	if(binding)
		request("watch", extra = list("revision" = snapshot_binding == REF(binding) ? snapshot_revision : -1))
	resync_timer = addtimer(CALLBACK(src, PROC_REF(check_subscription)), 30 SECONDS, TIMER_STOPPABLE | TIMER_DELETE_ME)

/datum/netrun_machine_service/research_client/proc/request(operation = "snapshot", mob/user, list/extra)
	if(QDELETED(host))
		return FALSE
	if(operation in list("snapshot", "watch"))
		wants_snapshots = TRUE
	var/datum/techweb/binding = resolve_binding()
	if(!binding)
		return FALSE
	var/list/data = extra ? extra.Copy() : list()
	data["operation"] = operation
	data["binding"] = REF(binding)
	data["generation"] = binding_generation
	var/datum/netrun_machine_message/research/message = new(data)
	message.requester_ref = WEAKREF(src)
	if(user)
		message.user_ref = WEAKREF(user)
	return send("research.server", message, REF(binding))

/datum/netrun_machine_service/research_client/accepts(datum/netrun_machine_message/message)
	var/datum/techweb/binding = netrun_atom_techweb(host)
	return !QDELETED(binding) && message.source?.service_id == "research.server" && binding.research_owner_ref?.resolve() == message.source.host && netrun_atom_techweb(message.source.host) == binding && message.payload["binding"] == REF(binding) && message.payload["generation"] == binding_generation

/datum/netrun_machine_service/research_client/receive(datum/netrun_machine_message/message)
	if(!accepts(message))
		return FALSE
	var/list/data = message.payload
	if(data["operation"] == "design")
		var/list/pending = pending_designs[data["design_token"]]
		if(!pending || pending["design"] != data["design_id"])
			return FALSE
		var/datum/techweb/granted = data["success"] ? live_authority() : null
		finish_design(data["design_token"], granted)
		return TRUE
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
		if(istype(console))
			if(!console.netrun_research_cache)
				console.netrun_research_cache = new /datum/techweb/netrun_snapshot(TRUE)
			netrun_apply_research_snapshot(console.netrun_research_cache, data)
			console.receive_research_disk_snapshot(data)
		else
			if(!snapshot_cache)
				snapshot_cache = new /datum/techweb/netrun_snapshot(TRUE)
			netrun_apply_research_snapshot(snapshot_cache, data)
			if(istype(host, /obj/machinery/computer/operating))
				var/obj/machinery/computer/operating/operating = host
				operating.sync_surgeries()
			host.update_static_data_for_all_viewers()
	SStgui.update_uis(host)
	SEND_SIGNAL(host, COMSIG_NETRUN_SERVICE_STATE_CHANGED)
	return TRUE

/// This is a cache assignment, not research: no points are spent and no science bounty is paid.
/proc/netrun_apply_research_snapshot(datum/techweb/cache, list/data)
	cache.researched_nodes = data["researched_nodes"].Copy()
	cache.available_nodes = data["available_nodes"].Copy()
	cache.tiers = data["tiers"].Copy()
	cache.researched_designs = data["researched_designs"].Copy()
	cache.custom_designs = data["custom_designs"].Copy()
	cache.hidden_nodes = data["hidden_nodes"].Copy()
	cache.visible_nodes = data["visible_nodes"].Copy()
	cache.boosted_nodes = deepCopyList(data["boosted_nodes"])
	cache.research_points = data["research_points"].Copy()
	cache.last_bitcoins = data["last_bitcoins"].Copy()
	cache.organization = data["organization"]
	cache.discovered_mutations = data["discovered_mutations"].Copy()
	cache.deconstructed_items = data["deconstructed_items"].Copy()
	cache.problem_computer_charges = data["problem_computer_charges"]
	cache.problem_computer_max_charges = data["problem_computer_max_charges"]
	// Derived server state is already consistent. Replaying node recalculation here
	// used to yield with half-applied data and mutate cached designs while deleting hosts.

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
/datum/techweb/netrun_snapshot/New(empty = FALSE)
	hidden_nodes = SSresearch.techweb_nodes_hidden.Copy()
	if(empty)
		return
	for(var/id in SSresearch.techweb_nodes_starting)
		var/datum/techweb_node/node = SSresearch.techweb_node_by_id(id)
		researched_nodes[id] = TRUE
		for(var/design_id in node.design_ids)
			researched_designs[design_id] = TRUE
		for(var/unlock_id in node.unlock_ids)
			visible_nodes[unlock_id] = TRUE
	var/list/initial_nodes = researched_nodes | visible_nodes
	for(var/id in initial_nodes)
		update_node_status(SSresearch.techweb_node_by_id(id), FALSE)

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
