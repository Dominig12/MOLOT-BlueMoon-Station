/// Addressed process communication uses the same authorized routes as device commands.
/datum/netrun_console
	var/next_entity_signal = 0

/// A closed LAN never publishes its resident processes through a gateway card.
/datum/netrun_console/proc/entity_contacts(datum/component/netrun_node/node)
	. = list()
	if(QDELETED(node) || !node.is_online() || !node_visible(node) || node_level(node) < NETRUN_ACCESS_GUEST)
		return
	var/list/occupants = list()
	occupants |= node.entities
	occupants |= node.netrun_ice
	for(var/datum/occupant as anything in occupants)
		if(QDELETED(occupant))
			continue
		var/datum/component/netrun_combatant/combatant = occupant.get_netrun_combatant()
		if(!combatant || combatant.node() != node)
			continue
		var/list/entry = combatant.ui_entry()
		var/is_self = occupant == host
		entry["self"] = is_self
		var/mob/camera/netrun_entity/resident = istype(occupant, /mob/camera/netrun_entity) ? occupant : null
		entry["can_signal"] = resident && !QDELETED(resident.console) && !is_self && !is_locked()
		entry["can_message"] = entry["can_signal"]
		if(istype(occupant, /mob/camera/netrun_entity))
			var/mob/camera/netrun_entity/entity = occupant
			entry["state"] = entity.is_stunned() ? "оглушён" : (entity.dive_link?.body ? "погружение" : "резидент")
		else if(istype(occupant, /datum/netrun_ice))
			var/datum/netrun_ice/ice = occupant
			entry["state"] = ice.is_stunned() ? "оглушён" : (ice.pending_program ? "готовит атаку" : (ice.enemy_ref?.resolve() ? "преследует" : (ice.kind == NETRUN_ICE_HUNTER ? "патрулирует" : "охраняет узел")))
		. += list(entry)

/// Reused at dispatch and delivery: a stale card cannot address an arbitrary mob REF.
/datum/netrun_console/proc/entity_contact_denial(datum/component/netrun_node/node, mob/camera/netrun_entity/recipient, datum/netrun_path_tree/tree)
	if(is_locked())
		return "точка подключения заблокирована"
	if(QDELETED(node) || QDELETED(recipient) || QDELETED(recipient.console) || recipient == host || recipient.host_node != node || !(recipient in node.entities))
		return "процесс уже покинул узел"
	if(!node.is_online() || !can_route(node, tree) || node_level(node, tree) < NETRUN_ACCESS_GUEST)
		return "нет связи или доступа к узлу"
	return null

/// Null text is a presence signal; nonempty text is a private addressed message.
/datum/netrun_console/proc/signal_entity(datum/component/netrun_node/node, recipient_ref, text)
	if(!istext(recipient_ref))
		return FALSE
	if(world.time < next_entity_signal)
		log_line("Канал связи с процессами ещё занят.", "average")
		return FALSE
	var/mob/camera/netrun_entity/recipient = locate(recipient_ref)
	if(!istype(recipient))
		return FALSE
	var/datum/netrun_path_tree/tree = make_path_tree()
	var/reason = entity_contact_denial(node, recipient, tree)
	if(reason)
		qdel(tree)
		log_line("Связь с процессом недоступна: [reason].", "bad")
		return FALSE
	if(!isnull(text))
		if(!istext(text))
			qdel(tree)
			return FALSE
		text = trim(copytext_char(sanitize(text), 1, 241))
		if(!length(text))
			qdel(tree)
			return FALSE
	var/latency = latency_to(node, tree)
	var/list/route_hops = tree.addresses_to(node.address)
	qdel(tree)
	next_entity_signal = world.time + 2 SECONDS
	var/datum/netrun_request/entity_contact/packet = new(src, node, recipient, text)
	return packet.send(latency, route_hops)

/// The delivery owns its recipient and message snapshot, without borrowing a UI route.
/datum/netrun_request/entity_contact
	parent_type = /datum/netrun_request/delivery
	var/datum/weakref/recipient_ref
	var/message
	var/sender_name
	var/source_address
	var/packet_id
	var/packet_kind

/datum/netrun_request/entity_contact/New(datum/netrun_console/console, datum/component/netrun_node/node, mob/camera/netrun_entity/recipient, text)
	..(console, node, node?.network, console.operator)
	recipient_ref = WEAKREF(recipient)
	message = text
	sender_name = console.get_handle()
	source_address = console.route_source()?.address
	packet_id = REF(src)
	packet_kind = isnull(message) ? "entity.signal" : "entity.message"

/datum/netrun_request/entity_contact/Destroy()
	if(sent && !delivering)
		journal(source_address, "DROP", "отправка отменена: сеанс или узел удалён")
	recipient_ref = null
	return ..()

/datum/netrun_request/entity_contact/send(delay = 0, list/route_hops)
	if(!sent)
		journal(source_address, "SEND")
	return ..()

/datum/netrun_request/entity_contact/proc/journal(address, phase, reason)
	var/datum/component/netrun_node/hop = SSnetrun.find_node(address)
	if(!QDELETED(hop))
		hop.add_packet_log(packet_id, phase, packet_kind, source_address, node?.address, "entity_contact", reason)

/datum/netrun_request/entity_contact/execute()
	if(QDELETED(console) || QDELETED(node))
		return FALSE
	var/mob/camera/netrun_entity/recipient = recipient_ref?.resolve()
	node.join_network()
	var/datum/netrun_path_tree/tree = console.make_path_tree()
	var/reason = console.entity_contact_denial(node, recipient, tree)
	if(!reason && (sender != console.operator || node.network != sent_network))
		reason = "сеанс отправителя изменился"
	if(reason)
		qdel(tree)
		journal(source_address, "DROP", reason)
		console.log_line("Доставка процессу отменена: [reason].", "bad")
		return FALSE
	var/list/route_hops = tree.addresses_to(node.address)
	qdel(tree)
	for(var/i = 2; i < length(route_hops); i++)
		journal(route_hops[i], "FORWARD")
	journal(node.address, "RECEIVE")
	var/line = isnull(message) ? "Адресный сигнал от [sender_name] ([source_address])." : "Личное сообщение от [sender_name] ([source_address]): [message]"
	recipient.console.log_line(line, "good")
	to_chat(recipient, span_notice(line))
	console.log_line(isnull(message) ? "Сигнал доставлен: [recipient.real_name] @ [node.address]." : "Сообщение доставлено: [recipient.real_name] @ [node.address].", "good")
	node.add_log("[sender_name]: [isnull(message) ? "сигнал" : "личное сообщение"] процессу [recipient.real_name].")
	if(!isnull(message) && sender)
		sender.log_talk(message, LOG_CHAT, tag = "NETRUN private to [recipient.real_name]")
	SSnetrun.post_event("command", node.network?.id, node.address)
	return TRUE
