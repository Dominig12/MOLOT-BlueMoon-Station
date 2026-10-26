/// A dive owns the body link and its subscriptions, independently of resident movement and vision.
/datum/netrun_dive_link
	parent_type = /datum/netrun_delivery
	delivery_kind = "dive_link"
	var/mob/camera/netrun_entity/owner
	var/mob/living/carbon/body
	var/entry_address
	var/list/route_chain = list()
	var/datum/weakref/entry_client_ref
	var/datum/weakref/entry_jack_ref
	/// Returning is terminal: concurrent damage, deletion and cable signals share one exit.
	var/returning = FALSE
	var/checking = FALSE
	var/list/datum/component/netrun_node/watched_nodes = list()

/datum/netrun_dive_link/New(mob/camera/netrun_entity/owner)
	src.owner = owner
	RegisterSignal(owner, COMSIG_NETRUN_ENTITY_NODE_CHANGED, PROC_REF(on_node_changed))

/datum/netrun_dive_link/Destroy()
	release_body()
	UnregisterSignal(owner, COMSIG_NETRUN_ENTITY_NODE_CHANGED)
	owner = null
	return ..()

/datum/netrun_dive_link/proc/attach(mob/living/carbon/new_body, datum/component/netrun_node/entry)
	if(QDELETED(new_body) || QDELETED(entry))
		return FALSE
	release_body()
	body = new_body
	returning = FALSE
	entry_address = entry.address
	route_chain = list(entry.address)
	RegisterSignal(body, COMSIG_MOB_APPLY_DAMAGE, PROC_REF(on_body_damage))
	RegisterSignal(body, COMSIG_LIVING_DEATH, PROC_REF(on_body_death))
	RegisterSignal(body, COMSIG_PARENT_QDELETING, PROC_REF(on_body_deleted))
	RegisterSignal(body, COMSIG_MOVABLE_MOVED, PROC_REF(on_body_moved))
	watch_nodes(list(entry))
	return TRUE

/datum/netrun_dive_link/proc/bind_client(datum/netrun_console/implant/client, datum/component/netrun_node/jack)
	entry_client_ref = WEAKREF(client)
	entry_jack_ref = jack ? WEAKREF(jack) : null
	RegisterSignal(client, COMSIG_PARENT_QDELETING, PROC_REF(on_client_deleted))
	// Establish the physical return path once; later ticks borrow its retained route table.
	check_link(0)

/datum/netrun_dive_link/proc/release_body()
	cancel_delivery()
	if(body)
		UnregisterSignal(body, list(COMSIG_MOB_APPLY_DAMAGE, COMSIG_LIVING_DEATH, COMSIG_PARENT_QDELETING, COMSIG_MOVABLE_MOVED))
	var/datum/netrun_console/implant/client = entry_client_ref?.resolve()
	if(client)
		UnregisterSignal(client, COMSIG_PARENT_QDELETING)
		if(client.dive_ref?.resolve() == owner)
			client.dive_ref = null
	watch_nodes(list())
	body = null
	entry_address = null
	route_chain.Cut()
	entry_client_ref = null
	entry_jack_ref = null

/datum/netrun_dive_link/proc/on_node_changed(datum/source, datum/component/netrun_node/old_node, datum/component/netrun_node/new_node)
	SIGNAL_HANDLER
	track_route(new_node)
	if(body && new_node)
		// Subscribe to the new host immediately; the worker replaces this superset
		// with the precise physical return path after the residency change settles.
		watch_nodes(watched_nodes | list(new_node))
		queue_link_check()

/datum/netrun_dive_link/proc/track_route(datum/component/netrun_node/node)
	if(!body || !node?.address)
		return
	var/existing = route_chain.Find(node.address)
	if(existing)
		route_chain.Cut(existing + 1)
	else
		route_chain += node.address

/datum/netrun_dive_link/proc/on_body_damage(datum/source, damage, damagetype)
	SIGNAL_HANDLER
	if(damage < 5 || !(damagetype in list(BRUTE, BURN)))
		return
	to_chat(owner, span_userdanger("Ваше тело ранено! Аварийный выход из сети!"))
	INVOKE_ASYNC(owner, TYPE_PROC_REF(/mob/camera/netrun_entity, return_to_body))

/datum/netrun_dive_link/proc/on_body_death(datum/source)
	SIGNAL_HANDLER
	INVOKE_ASYNC(owner, TYPE_PROC_REF(/mob/camera/netrun_entity, return_to_body))

/datum/netrun_dive_link/proc/on_body_deleted(datum/source)
	SIGNAL_HANDLER
	// A deleted body cannot receive a mind. Preserve its player as an observer,
	// never leave a formerly neural process occupying the network indefinitely.
	if(returning)
		return
	returning = TRUE
	release_body()
	owner.ghostize(FALSE)
	qdel(owner)

/datum/netrun_dive_link/proc/on_body_moved(datum/source)
	SIGNAL_HANDLER
	var/datum/netrun_console/implant/client = entry_client_ref?.resolve()
	if(entry_jack_ref && (!client || !client.jack_valid()))
		emergency_return("Сервисный кабель нейролинка оборван!")

/datum/netrun_dive_link/proc/on_client_deleted(datum/source)
	SIGNAL_HANDLER
	emergency_return("Нейролинк отключён!")

/// Only the actual return path is subscribed, rather than every endpoint on the station.
/datum/netrun_dive_link/proc/watch_nodes(list/nodes)
	for(var/datum/component/netrun_node/node as anything in watched_nodes.Copy())
		if(node in nodes)
			continue
		UnregisterSignal(node, list(COMSIG_PARENT_QDELETING, COMSIG_NETRUN_NODE_CHANGED))
		watched_nodes -= node
	for(var/datum/component/netrun_node/node as anything in nodes)
		if(QDELETED(node) || (node in watched_nodes))
			continue
		watched_nodes += node
		RegisterSignal(node, COMSIG_PARENT_QDELETING, PROC_REF(on_link_node_deleted))
		RegisterSignal(node, COMSIG_NETRUN_NODE_CHANGED, PROC_REF(on_link_node_changed))

/datum/netrun_dive_link/proc/on_link_node_changed(datum/source, datum/component/netrun_node/changed_node, flags)
	SIGNAL_HANDLER
	var/datum/component/netrun_node/node = source
	if((flags & (NETRUN_CHANGED_BINDING | NETRUN_CHANGED_REMOVED)) || !node.is_online())
		queue_link_check()

/datum/netrun_dive_link/proc/on_link_node_deleted(datum/source)
	SIGNAL_HANDLER
	var/datum/component/netrun_node/node = source
	if(node.address == entry_address)
		emergency_return("Точка входа в сеть уничтожена!")
	else
		// The queued check runs after graph removal. An intact alternative path
		// may still carry the link; no full resident/UI population cycle is needed.
		queue_link_check()

/datum/netrun_dive_link/proc/queue_link_check()
	return queue_delivery()

/datum/netrun_dive_link/can_queue_delivery()
	return body && !returning && !checking

/datum/netrun_dive_link/delivery_priority()
	return NETRUN_TASK_CRITICAL

/datum/netrun_dive_link/delivery_interactive()
	return TRUE

/datum/netrun_dive_link/deliver()
	cancel_delivery()
	check_link(0)
	return TRUE

/datum/netrun_task/dive_link
	parent_type = /datum/netrun_task/delivery
	kind = "dive_link"

/datum/netrun_dive_link/proc/process_tick(delta)
	if(!body)
		return
	body.SetUnconscious(5 SECONDS)
	check_link(delta)

/// Borrow one cached physical tree instead of walking the entire station for each diver.
/datum/netrun_dive_link/proc/link_intact()
	var/datum/component/netrun_node/client_node
	if(entry_client_ref)
		var/datum/netrun_console/implant/client = entry_client_ref.resolve()
		var/obj/item/organ/cyberimp/brain/netlink/implant = client?.host
		if(!client || !istype(implant) || implant.owner != body || !implant.netrun_online() || client.is_locked())
			return FALSE
		if(entry_jack_ref && (!entry_jack_ref.resolve() || client.connection.jack != entry_jack_ref.resolve() || !client.jack_valid()))
			return FALSE
		if(!entry_jack_ref)
			if(!client.connection.wireless)
				return FALSE
			client_node = implant.GetComponent(/datum/component/netrun_node)
			if(QDELETED(client_node))
				return FALSE
			// A sleeping body's implant remains a physical endpoint; console admission
			// correctly rejects unconscious operators and cannot be used for this check.
			client_node.join_network()
	if(!entry_address)
		return TRUE
	var/datum/component/netrun_node/entry = SSnetrun.find_node(entry_address)
	if(QDELETED(entry) || QDELETED(entry.parent) || !entry.is_online())
		return FALSE
	if(QDELETED(owner.host_node) || !owner.host_node.is_online())
		return FALSE
	// Movement signals enqueue topology work; this route consumer reconciles its
	// two actual endpoints before trusting a retained physical path.
	entry.join_network()
	if(owner.host_node != entry)
		owner.host_node.join_network()
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	var/datum/netrun_path_tree/tree = graph.route_snapshot(entry, TRUE)
	if(!tree || !tree.path_available(graph, owner.host_node.address) || (client_node && !tree.path_available(graph, client_node.address)))
		return FALSE
	var/list/path_nodes = list(entry)
	for(var/address in tree.addresses_to(owner.host_node.address))
		path_nodes |= graph.nodes[address]
	if(client_node)
		for(var/address in tree.addresses_to(client_node.address))
			path_nodes |= graph.nodes[address]
	watch_nodes(path_nodes)
	return TRUE

/datum/netrun_dive_link/proc/check_link(delta)
	if(!body || returning || checking)
		return
	checking = TRUE
	var/intact = link_intact()
	checking = FALSE
	if(intact)
		return
	emergency_return("Связь с телом потеряна! Аварийный выход из сети!")

/// Compatibility callers must use the same cleanup policy instead of creating a ghost process.
/datum/netrun_dive_link/proc/strand_in_network()
	return emergency_return("Связь с телом разорвана!")

/datum/netrun_dive_link/proc/emergency_return(reason)
	return return_to_body(TRUE, reason)

/datum/netrun_dive_link/proc/return_to_body(emergency = FALSE, reason)
	if(!body || returning)
		return
	returning = TRUE
	var/mob/living/carbon/linked_body = body
	release_body()
	if(emergency)
		to_chat(owner, span_userdanger(reason || "Аварийный разрыв соединения!"))
		// Native organ damage is capped below lethal brain failure, including repeated dives.
		linked_body.adjustOrganLoss(ORGAN_SLOT_BRAIN, 20, 150)
	if(owner.mind)
		owner.mind.transfer_to(linked_body)
	else if(owner.key)
		linked_body.key = owner.key
	linked_body.SetUnconscious(0)
	if(linked_body.stat != DEAD)
		to_chat(linked_body, span_notice("Вы выныриваете из сети. Голова гудит."))
	qdel(owner)
	return TRUE
