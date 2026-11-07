/datum/component/techweb_holder
	var/datum/techweb/linked_techweb
	/// Last state obtained after a real NetDM server response.
	var/list/netdm_snapshot
	var/netdm_last_snapshot = 0
	var/netdm_next_snapshot_request = 0
	var/netdm_request_serial = 0
	var/list/netdm_pending = list()

/datum/component/techweb_holder/Initialize(...)
	. = ..()
	RegisterSignal(parent, COMSIG_ATOM_TOOL_ACT(TOOL_MULTITOOL), PROC_REF(on_multitool_act))
	RegisterSignal(parent, COMSIG_ATOM_GET_TECHWEB, PROC_REF(GetTechWeb))
	RegisterSignal(parent, COMSIG_ATOM_SET_TECHWEB, PROC_REF(on_set_techweb))
	RegisterSignal(parent, "netdm_packet_received", PROC_REF(on_netdm_received))
	RegisterSignal(parent, "netdm_packet_delivery", PROC_REF(on_netdm_delivery))

/datum/component/techweb_holder/Destroy(force, silent)
	. = ..()
	linked_techweb = null
	netdm_snapshot = null
	netdm_pending = null

/datum/component/techweb_holder/proc/on_set_techweb(datum/source, new_web)
	SIGNAL_HANDLER
	if(!new_web)
		return null

	linked_techweb = new_web
	invalidate_netdm_cache()
	SEND_SIGNAL(parent, COMSIG_ATOM_TECHWEB_CHANGED, linked_techweb)

/datum/component/techweb_holder/proc/on_multitool_act(datum/source, mob/living/user, obj/item/I, list/mutable_recipes)
	SIGNAL_HANDLER
	var/obj/item/multitool/tool = I
	if(istype(tool.buffer, /datum/techweb))
		var/datum/techweb/new_web = tool.buffer
		if(new_web == linked_techweb)
			to_chat(user, span_notice("Объект уже подключён к [new_web.organization]."))
			return TRUE
		linked_techweb = new_web
		invalidate_netdm_cache()
		SEND_SIGNAL(parent, COMSIG_ATOM_TECHWEB_CHANGED, linked_techweb)
		to_chat(user, span_notice("Вы подключаете объект к [new_web.organization]."))
	else if(!tool.buffer)
		if(linked_techweb)
			tool.buffer = linked_techweb
			to_chat(user, span_notice("Вы сохраняете базу данных исследований [linked_techweb.organization] в буфер мультитула."))
		else
			to_chat(user, span_notice("Объект не подключён ни к одной исследовательской сети."))
	else
		to_chat(user, span_notice("Буфер мультитула занят посторонним объектом."))

/datum/component/techweb_holder/proc/GetTechWeb()
	SIGNAL_HANDLER

	return linked_techweb

/datum/component/techweb_holder/proc/invalidate_netdm_cache()
	netdm_snapshot = null
	netdm_last_snapshot = 0
	netdm_next_snapshot_request = 0
	netdm_pending.Cut()

/// The linked datum is a network identity for legacy code. Research state
/// must be fetched from servers; it is never read here for the UI.
/datum/component/techweb_holder/proc/request_snapshot(force = FALSE)
	if(istype(parent, /obj/machinery/rnd/server))
		return FALSE
	if(!force && world.time < netdm_next_snapshot_request)
		return FALSE
	for(var/id in netdm_pending)
		var/list/entry = netdm_pending[id]
		if(entry["op"] == "snapshot")
			return FALSE
	netdm_next_snapshot_request = world.time + 30
	return netdm_request("snapshot")

/datum/component/techweb_holder/proc/request_research(node_id, mob/user)
	if(!istext(node_id) || !SSresearch.techweb_node_by_id(node_id))
		return FALSE
	return netdm_request("research", list("node_id" = node_id, "actor" = user ? "[user]" : "unknown"))

/// The server validates and destroys the still-loaded item on receipt;
/datum/component/techweb_holder/proc/request_analyze(obj/machinery/rnd/destructive_analyzer/analyzer, obj/item/target, node_id, mob/user)
	if(!analyzer || !target || !user)
		return FALSE
	return netdm_request("analyze", list("analyzer" = analyzer,
		"item" = target, "node_id" = node_id, "user" = user))

/datum/component/techweb_holder/proc/request_boost(obj/machinery/rnd/experimentor/experimentor, node_id, item_path)
	if(!experimentor || !ispath(item_path))
		return FALSE
	return netdm_request("boost", list("experimentor" = experimentor,
		"node_id" = node_id, "item_path" = item_path))

/datum/component/techweb_holder/proc/request_relic_discovery(obj/machinery/rnd/experimentor/experimentor, obj/item/relic/relic)
	if(!experimentor || !relic)
		return FALSE
	return netdm_request("relic_discovery", list("experimentor" = experimentor, "relic" = relic))

/datum/component/techweb_holder/proc/request_add_design(design_id)
	if(!istext(design_id) || !SSresearch.techweb_design_by_id(design_id))
		return FALSE
	return netdm_request("add_design", list("design_id" = design_id))

/datum/component/techweb_holder/proc/request_upload_tech(datum/techweb/disk_web)
	if(!disk_web)
		return FALSE
	return netdm_request("upload_tech", list(
		"node_ids" = disk_web.researched_nodes.Copy(),
		"design_ids" = disk_web.researched_designs.Copy()))

/datum/component/techweb_holder/proc/request_upload_designs(list/design_ids)
	if(!islist(design_ids))
		return FALSE
	return netdm_request("upload_tech", list(
		"node_ids" = list(), "design_ids" = design_ids.Copy()))

/datum/component/techweb_holder/proc/request_download_tech(obj/item/disk/tech_disk/disk)
	if(!disk || QDELETED(disk))
		return FALSE
	return netdm_request("download_tech", null, disk)

/// Success here means queued locally, not accepted by the remote application.
/datum/component/techweb_holder/proc/netdm_request(operation, list/arguments, obj/item/disk/tech_disk/download_disk)
	if(!linked_techweb || !ismovable(parent) || length(netdm_pending) >= 16)
		return FALSE
	if(!SSnetdm.enabled || !SSnetdm.connected || !SSnetdm.synchronized)
		return FALSE
	var/atom/movable/device = parent
	var/datum/component/netdm_node/sender = device.netdm_interface()
	var/datum/netdm_rnd_cluster/cluster = SSresearch.netdm_cluster_for(linked_techweb)
	var/obj/machinery/rnd/server/server = cluster?.find_server(device)
	var/datum/component/netdm_node/recipient = server?.netdm_interface()
	if(!sender?.node_id || !recipient?.node_id)
		return FALSE
	netdm_request_serial++
	var/id = "\ref[parent]-[world.realtime]-[netdm_request_serial]"
	var/list/message = list("kind" = "techweb_request", "rpc_id" = id, "op" = operation)
	if(arguments)
		for(var/key in arguments)
			message[key] = arguments[key]
	var/bytes = 128
	if(operation == "upload_tech")
		bytes += 12 * (length(message["node_ids"]) + length(message["design_ids"]))
	var/datum/netdm_transaction/transaction = sender.send_to(recipient, message, bytes, TRUE, 90)
	if(!transaction)
		return FALSE
	netdm_pending[id] = list("op" = operation,
		"transaction" = transaction.request_id, "disk" = download_disk)
	addtimer(CALLBACK(src, PROC_REF(netdm_request_timeout), id), 20 SECONDS)
	return TRUE

/datum/component/techweb_holder/proc/netdm_request_timeout(id)
	var/list/entry = netdm_pending ? netdm_pending[id] : null
	if(!entry)
		return
	netdm_pending -= id
	if(entry["op"] == "snapshot")
		netdm_next_snapshot_request = world.time + 30
	else if(istype(parent, /obj/machinery))
		var/obj/machinery/device = parent
		device.say("Research network request timed out.")

/datum/component/techweb_holder/proc/on_netdm_delivery(datum/source, request_id, state, reason)
	SIGNAL_HANDLER
	if(state == "delivered")
		return
	for(var/id in netdm_pending.Copy())
		var/list/entry = netdm_pending[id]
		if(entry["transaction"] != request_id)
			continue
		netdm_pending -= id
		if(entry["op"] != "snapshot" && istype(parent, /obj/machinery))
			var/obj/machinery/device = parent
			device.say("Research network unavailable: [reason].")
		return

/datum/component/techweb_holder/proc/on_netdm_received(datum/source,
	list/message, datum/component/netdm_node/sender, request_id)
	SIGNAL_HANDLER
	if(!islist(message))
		return
	if(message["kind"] == "techweb_request")
		if(istype(parent, /obj/machinery/rnd/server))
			var/obj/machinery/rnd/server/server = parent
			server.netdm_serve_techweb(message, sender)
		return
	if(message["kind"] != "techweb_reply" || message["web"] != linked_techweb)
		return
	var/obj/machinery/rnd/server/server = sender?.parent
	if(!istype(server) || QDELETED(server) || server.stored_research != linked_techweb)
		return
	var/id = message["rpc_id"]
	var/list/entry = netdm_pending[id]
	if(!islist(entry))
		return
	netdm_pending -= id
	var/list/snapshot = message["snapshot"]
	if(islist(snapshot))
		netdm_snapshot = snapshot
		netdm_last_snapshot = world.time
		netdm_next_snapshot_request = world.time + 30
		if(istype(parent, /obj/machinery/rnd/production))
			var/obj/machinery/rnd/production/producer = parent
			producer.techweb_netdm_snapshot_changed(snapshot)
		if(istype(parent, /obj/machinery/computer/rdconsole))
			var/obj/machinery/computer/rdconsole/console = parent
			console.ui_update()
		if(istype(parent, /obj/machinery/nanite_program_hub))
			var/obj/machinery/nanite_program_hub/hub = parent
			hub.update_static_data()
	if(entry["op"] == "download_tech" && message["ok"])
		var/obj/item/disk/tech_disk/disk = entry["disk"]
		if(disk && !QDELETED(disk) && disk.loc == parent && disk.stored_research && islist(snapshot))
			var/list/nodes = snapshot["researched_nodes"]
			for(var/node_id in nodes)
				if(!disk.stored_research.researched_nodes[node_id])
					disk.stored_research.research_node_id(node_id, TRUE, FALSE)
			var/list/designs = snapshot["researched_designs"]
			for(var/design_id in designs)
				if(!disk.stored_research.researched_designs[design_id])
					disk.stored_research.add_design_by_id(design_id)
	if(entry["op"] != "snapshot" && istype(parent, /obj/machinery))
		var/obj/machinery/device = parent
		device.say(message["ok"] ? "Research server: [message["reason"]]." : "Research server rejected request: [message["reason"]].")
