/**
 * The first NetDM gameplay RPC: authoritative research services.
 *
 * A cluster represents one logical /datum/techweb database shared by all
 * R&D servers with the same network. Existing passive research mining still
 * updates this database through SSresearch; client reads and research
 * purchases travel through NetDM packets and can fail when disconnected.
 *
 * Game payloads never leave DreamDaemon: the native Host routes their
 * byte counts and receipts, while DM dispatches the retained payload on
 * successful delivery. Avoid treating a transport receipt as an app ACK.
 */

/datum/controller/subsystem/research
	var/list/netdm_rnd_clusters = list()

/datum/controller/subsystem/research/proc/netdm_cluster_for(datum/techweb/web, create = FALSE)
	if(!web)
		return null
	var/datum/netdm_rnd_cluster/cluster = netdm_rnd_clusters[web]
	if(!cluster && create)
		cluster = new(web)
		netdm_rnd_clusters[web] = cluster
	return cluster

/datum/controller/subsystem/research/proc/netdm_attach_rnd_server(obj/machinery/rnd/server/server)
	if(!server?.stored_research)
		return
	var/datum/netdm_rnd_cluster/cluster = netdm_cluster_for(server.stored_research, TRUE)
	cluster.servers |= server
	server.netdm_cluster = cluster

/datum/controller/subsystem/research/proc/netdm_detach_rnd_server(obj/machinery/rnd/server/server)
	var/datum/netdm_rnd_cluster/cluster = server?.netdm_cluster
	if(!cluster)
		return
	cluster.servers -= server
	server.netdm_cluster = null
	// Keep a round-scoped cluster record for request deduplication even if
	// all physical servers are destroyed or temporarily unavailable.

/datum/netdm_rnd_cluster
	var/datum/techweb/web
	var/list/obj/machinery/rnd/server/servers = list()
	/// Last results are shared between all servers to avoid duplicate writes.
	var/list/completed_requests = list()
	var/list/completed_order = list()
	var/max_completed = 512
	/// Excludes overlapping writes if techweb code yields via CHECK_TICK.
	var/processing = FALSE

/datum/netdm_rnd_cluster/New(datum/techweb/network)
	. = ..()
	web = network

/datum/netdm_rnd_cluster/proc/find_server(atom/source)
	var/obj/machinery/rnd/server/best
	var/best_distance = INFINITY
	var/turf/origin = get_turf(source)
	for(var/obj/machinery/rnd/server/candidate as anything in servers)
		if(!candidate || QDELETED(candidate) || !candidate.stored_research || !candidate.working || (candidate.machine_stat & (NOPOWER | BROKEN | EMPED)))
			continue
		var/datum/component/netdm_node/endpoint = candidate.netdm_interface()
		if(!endpoint?.node_id)
			continue
		var/turf/location = get_turf(candidate)
		var/distance = origin && location && origin.z == location.z ? get_dist(origin, location) : 100000
		if(!best || distance < best_distance)
			best = candidate
			best_distance = distance
	return best

/// The UI and fabricators receive snapshots, never the authoritative datum.
/// All lists are copied so later updates cannot mutate an in-flight reply.
/datum/netdm_rnd_cluster/proc/snapshot()
	var/list/visible = list()
	for(var/id in web.tiers)
		if(web.hidden_nodes[id])
			continue
		var/datum/techweb_node/node = SSresearch.techweb_node_by_id(id)
		if(!node)
			continue
		var/list/price = node.get_price(web)
		visible += list(list("id" = id,
			"tier" = web.tiers[id],
			"costs" = price.Copy(),
			"can_unlock" = !!web.available_nodes[id] && !web.researched_nodes[id] && web.can_afford(price)))
	return list(
		"organization" = web.organization,
		"points" = web.research_points.Copy(),
		"points_last_tick" = web.last_bitcoins.Copy(),
		"researched_nodes" = web.researched_nodes.Copy(),
		"researched_designs" = web.researched_designs.Copy(),
		"nodes" = visible)

/// Safe request processing is serialized in the DM tick. Only one successful
/// purchase may consume the same node, regardless of which server received it.
/datum/netdm_rnd_cluster/proc/execute(list/request)
	var/op = request["op"]
	var/key = request["rpc_id"]
	if(!istext(key) || length(key) > 128)
		return list("ok" = FALSE, "reason" = "invalid_request")
	if(processing)
		return list("ok" = FALSE, "reason" = "cluster_busy")
	if(op == "snapshot" || op == "download_tech")
		return list("ok" = TRUE, "reason" = "ok")
	var/list/previous = completed_requests[key]
	if(islist(previous))
		return previous.Copy()
	processing = TRUE
	var/list/result = list("ok" = FALSE, "reason" = "unsupported_operation")
	switch(op)
		if("research")
			var/id = request["node_id"]
			var/datum/techweb_node/node = SSresearch.techweb_node_by_id(id)
			if(!node || !web.available_nodes[id] || web.researched_nodes[id])
				result["reason"] = "unavailable_node"
			else
				var/list/price = node.get_price(web)
				if(!web.can_afford(price))
					result["reason"] = "insufficient_points"
				else if(web.research_node_id(id, FALSE, TRUE))
					result["ok"] = TRUE
					result["reason"] = "researched"
					SSresearch.on_node_researched(id, web)
					SEND_GLOBAL_SIGNAL(COMSIG_GLOB_RESEARCH_NODE_UNLOCKED, id)
					log_game("NetDM research [id] on techweb [web.id] by [request["actor"]].")
		if("add_design")
			var/design_id = request["design_id"]
			if(SSresearch.techweb_design_by_id(design_id))
				web.add_design_by_id(design_id, TRUE)
				result["ok"] = TRUE
				result["reason"] = "design_added"
		if("upload_tech")
			var/list/ids = request["node_ids"]
			var/list/design_ids = request["design_ids"]
			if(!islist(ids) || length(ids) > 2048 || !islist(design_ids) || length(design_ids) > 4096)
				result["reason"] = "invalid_upload"
			else
				for(var/node_id in ids)
					if(web.researched_nodes[node_id] || !SSresearch.techweb_node_by_id(node_id))
						continue
					web.research_node_id(node_id, TRUE, FALSE)
					SSresearch.on_node_researched(node_id, web)
					SEND_GLOBAL_SIGNAL(COMSIG_GLOB_RESEARCH_NODE_UNLOCKED, node_id)
				for(var/design_id in design_ids)
					if(SSresearch.techweb_design_by_id(design_id))
						web.add_design_by_id(design_id, TRUE)
				result["ok"] = TRUE
				result["reason"] = "uploaded"
	processing = FALSE
	completed_requests[key] = result.Copy()
	completed_order += key
	if(length(completed_order) > max_completed)
		var/oldest = completed_order[1]
		completed_order.Cut(1, 2)
		completed_requests -= oldest
	return result

/// Called only after the transport DELIVERED receipt arrives.
/obj/machinery/rnd/server/proc/netdm_serve_techweb(list/request,
	datum/component/netdm_node/sender)
	if(!islist(request) || request["kind"] != "techweb_request" || !sender?.node_id)
		return
	var/datum/component/netdm_node/mine = netdm_interface()
	if(!mine?.node_id || !working || (machine_stat & (NOPOWER | BROKEN | EMPED)))
		return
	var/obj/client = sender.parent
	var/datum/component/techweb_holder/client_holder = client?.GetComponent(/datum/component/techweb_holder)
	if(!client_holder || !netdm_cluster || client_holder.linked_techweb != stored_research)
		return
	// Write operations require an actual unlocked R&D console.
	var/op = request["op"]
	var/allowed = TRUE
	if(op == "research" || op == "add_design" || op == "upload_tech")
		if(!istype(client, /obj/machinery/computer/rdconsole))
			allowed = FALSE
		else
			var/obj/machinery/computer/rdconsole/console = client
			if(console.locked || (op == "research" && !console.research_control))
				allowed = FALSE
	var/list/result = allowed ? netdm_cluster.execute(request) : list("ok" = FALSE, "reason" = "forbidden")
	var/list/research_snapshot = result["reason"] == "cluster_busy" ? null : netdm_cluster.snapshot()
	var/list/reply = list("kind" = "techweb_reply",
		"rpc_id" = request["rpc_id"], "web" = stored_research,
		"ok" = result["ok"], "reason" = result["reason"],
		"snapshot" = research_snapshot)
	var/estimated_bytes = 256
	if(research_snapshot)
		estimated_bytes = min(1000000, estimated_bytes + length(research_snapshot["researched_designs"]) * 12 + length(research_snapshot["nodes"]) * 48)
	mine.send_to(sender, reply, estimated_bytes, TRUE, 90)
