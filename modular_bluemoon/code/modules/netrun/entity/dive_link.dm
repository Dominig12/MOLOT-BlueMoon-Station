/// A dive owns the body link and its subscriptions, independently of resident movement and vision.
/datum/netrun_dive_link
	var/mob/camera/netrun_entity/owner
	var/mob/living/carbon/body
	var/entry_address
	var/list/route_chain = list()
	var/severed_at = 0
	var/datum/weakref/entry_client_ref
	var/datum/weakref/entry_jack_ref

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
	entry_address = entry.address
	route_chain = list(entry.address)
	RegisterSignal(body, COMSIG_MOB_APPLY_DAMAGE, PROC_REF(on_body_damage))
	RegisterSignal(body, COMSIG_LIVING_DEATH, PROC_REF(on_body_death))
	RegisterSignal(body, COMSIG_PARENT_QDELETING, PROC_REF(on_body_deleted))
	return TRUE

/datum/netrun_dive_link/proc/release_body()
	if(body)
		UnregisterSignal(body, list(COMSIG_MOB_APPLY_DAMAGE, COMSIG_LIVING_DEATH, COMSIG_PARENT_QDELETING))
	body = null
	entry_address = null
	route_chain.Cut()
	severed_at = 0
	entry_client_ref = null
	entry_jack_ref = null

/datum/netrun_dive_link/proc/on_node_changed(datum/source, datum/component/netrun_node/old_node, datum/component/netrun_node/new_node)
	SIGNAL_HANDLER
	track_route(new_node)

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
	// A deleted body cannot receive a mind; release the reference immediately.
	strand_in_network()

/datum/netrun_dive_link/proc/process_tick(delta)
	if(!body)
		return
	body.SetUnconscious(5 SECONDS)
	check_link(delta)

/// Preserve the physical return-path rules, including relay availability.
/datum/netrun_dive_link/proc/link_intact()
	if(entry_client_ref)
		var/datum/netrun_console/implant/client = entry_client_ref.resolve()
		var/obj/item/organ/cyberimp/brain/netlink/implant = client?.host
		if(!client || !istype(implant) || implant.owner != body || !implant.netrun_online() || client.is_locked())
			return FALSE
		if(entry_jack_ref && (!entry_jack_ref.resolve() || client.connection.jack != entry_jack_ref.resolve() || !client.jack_valid()))
			return FALSE
	if(!entry_address)
		return TRUE
	var/datum/component/netrun_node/entry = SSnetrun.find_node(entry_address)
	if(QDELETED(entry) || QDELETED(entry.parent) || !entry.is_online())
		return FALSE
	if(!owner.host_node)
		return FALSE
	if(owner.host_node == entry)
		return TRUE
	var/datum/netrun_topology/graph = SSnetrun.ensure_topology()
	var/list/queue = list(owner.host_node.address)
	var/list/seen = list()
	seen[owner.host_node.address] = TRUE
	for(var/i = 1, i <= length(queue), i++)
		var/address = queue[i]
		var/datum/component/netrun_node/current = graph.nodes[address]
		if(QDELETED(current) || !current.is_online())
			continue
		for(var/neighbor in graph.neighbors(address))
			if(seen[neighbor])
				continue
			if(!netrun_link_available(current, graph.nodes[neighbor]))
				continue
			if(neighbor == entry.address)
				return TRUE
			seen[neighbor] = TRUE
			queue += neighbor
	return FALSE

/datum/netrun_dive_link/proc/check_link(delta)
	if(!body)
		return
	if(link_intact())
		if(severed_at)
			severed_at = 0
			to_chat(owner, span_notice("Канал связи с телом восстановлен."))
		return
	if(!severed_at)
		severed_at = world.time
		to_chat(owner, span_userdanger("СВЯЗЬ С ТЕЛОМ ПОТЕРЯНА! Маршрут к точке входа обрезан — срочно восстановите путь!"))
		SEND_SOUND(owner, sound('sound/machines/warning-buzzer.ogg', volume = 60))
	var/mob/living/carbon/linked_body = body
	linked_body.adjustOrganLoss(ORGAN_SLOT_BRAIN, 3 * delta)
	if(world.time - severed_at < 15 SECONDS)
		return
	var/datum/component/netrun_node/entry = SSnetrun.find_node(entry_address)
	if(QDELETED(entry) || QDELETED(entry.parent))
		to_chat(owner, span_userdanger("Точка входа уничтожена. Ваше тело гибнет, а процесс остаётся заперт в сети."))
		linked_body.adjustOrganLoss(ORGAN_SLOT_BRAIN, 80)
		linked_body.death()
		strand_in_network()
		return
	to_chat(owner, span_userdanger("Аварийный разрыв соединения!"))
	linked_body.adjustOrganLoss(ORGAN_SLOT_BRAIN, 55)
	return_to_body()

/datum/netrun_dive_link/proc/strand_in_network()
	if(!body)
		return
	release_body()
	if(QDELETED(owner))
		return
	owner.set_net_name("GHOST-[uppertext(copytext(md5("[world.time][rand(1, 99999)]"), 1, 5))]", "Заблудший процесс")
	to_chat(owner, span_warning("Вы больше не связаны с телом. Вы — процесс, застрявший в сети станции."))

/datum/netrun_dive_link/proc/return_to_body()
	if(!body)
		return
	var/mob/living/carbon/linked_body = body
	release_body()
	if(owner.mind)
		owner.mind.transfer_to(linked_body)
	linked_body.SetUnconscious(0)
	if(linked_body.stat != DEAD)
		to_chat(linked_body, span_notice("Вы выныриваете из сети. Голова гудит."))
	qdel(owner)
