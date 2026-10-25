/// The implant owns a client, while a dive owns a separate resident process and body link.
/datum/netrun_console/implant
	name = "нейролинк"
	tgui_title = "Нейролинк"
	var/diving = FALSE
	var/datum/weakref/dive_ref

/datum/netrun_console/implant/New(atom/host, origin)
	. = ..()
	state_override = GLOB.conscious_state

/datum/netrun_console/implant/proc/available_to(mob/user = operator)
	var/obj/item/organ/cyberimp/brain/netlink/implant = host
	return istype(implant) && implant.owner && user == implant.owner && user.stat == CONSCIOUS && !user.incapacitated() && implant.netrun_online()

/datum/netrun_console/implant/ui_status(mob/user, datum/ui_state/state)
	if(!available_to(user))
		return UI_CLOSE
	return ..()

/datum/netrun_console/implant/ui_interact(mob/user, datum/tgui/ui)
	if(!available_to(user))
		return
	return ..()

/datum/netrun_console/implant/ui_static_data(mob/user)
	if(!available_to(user || operator))
		return list()
	return ..()

/datum/netrun_console/implant/ui_data(mob/user, datum/ui_source)
	if(!available_to(user || operator))
		return list()
	return ..()

/datum/netrun_console/implant/can_route(datum/component/netrun_node/node, datum/netrun_path_tree/tree)
	return available_to() && ..()

/datum/netrun_console/implant/physical_route_source()
	if(!available_to())
		return
	return ..()

/datum/netrun_console/implant/has_uplink()
	return available_to() && ..()

/datum/netrun_console/implant/proc/disconnect_client(return_body = FALSE)
	if(return_body)
		var/mob/camera/netrun_entity/entity = dive_ref?.resolve()
		if(entity?.dive_link.body && !QDELETED(entity.dive_link.body))
			entity.dive_link.emergency_return("Нейролинк принудительно отключён!")
		dive_ref = null
	set_jack(null)
	stop_watch()
	for(var/datum/component/netrun_node/node as anything in listening.Copy())
		node.stop_listening(src)
	access_session.revoke_all()
	QDEL_NULL(intrusion.breach)
	SStgui.close_uis(src)

/datum/netrun_console/implant/set_jack(datum/component/netrun_node/node)
	. = ..()
	var/mob/camera/netrun_entity/entity = dive_ref?.resolve()
	if(entity?.dive_link.entry_jack_ref && entity.dive_link.entry_jack_ref.resolve() != connection.jack)
		entity.dive_link.emergency_return("Сервисный кабель нейролинка отключён!")

/datum/netrun_console/implant/process_tick(delta)
	var/mob/camera/netrun_entity/entity = dive_ref?.resolve()
	var/obj/item/organ/cyberimp/brain/netlink/implant = host
	var/active_dive = entity?.dive_link.body && entity.dive_link.body == implant?.owner
	if(!available_to() && !active_dive && (connection.jack || remote_session.watch_node || length(listening)))
		disconnect_client()
	return ..()

/datum/netrun_console/implant/proc/dive_denial(datum/component/netrun_node/node, mob/user = operator)
	if(!available_to(user))
		return "Имплант доступен только его владельцу в сознании."
	if(is_locked())
		return "Нейролинк заблокирован."
	if(diving)
		return "Погружение уже выполняется."
	if(QDELETED(node) || !node.is_online() || !can_route(node) || node_level(node) < NETRUN_ACCESS_USER)
		return "Нужны действующий маршрут и доступ пользователя к работающему узлу."
	if(!user.mind)
		return "Сознание не готово к погружению."
	return null

/// Node selection is useful even when the map shows a different sector or workspace.
/datum/netrun_console/implant/proc/entry_choices()
	. = list()
	if(!available_to())
		return
	var/datum/netrun_path_tree/tree = make_path_tree()
	for(var/address in tree.reached)
		var/datum/component/netrun_node/node = SSnetrun.find_node(address)
		if(!QDELETED(node) && node.is_online() && can_route(node, tree) && node_level(node, tree) >= NETRUN_ACCESS_USER)
			.["[node.get_name()] — [node.address]"] = node
	qdel(tree)

/datum/netrun_console/implant/proc/select_entry(datum/component/netrun_node/node, mob/user)
	if(!available_to(user) || QDELETED(node) || !node.is_online() || !can_route(node) || node_level(node) < NETRUN_ACCESS_USER)
		return FALSE
	map_view.selected_address = node.address
	map_view.selected_network = null
	var/turf/position = node.physical_turf()
	map_view.select_sector(node.binding_sector, position?.z)
	workspace_view = "map"
	log_line("Узел погружения выбран: [node.get_name()] [node.address].", "good")
	finish_user_action(node)
	return TRUE

/datum/netrun_console/implant/proc/choose_entry(mob/user)
	var/list/choices = entry_choices()
	if(!length(choices))
		log_line("Нет узлов с доступом пользователя. Получите доступ или подключитесь к сервисному порту.", "average")
		return
	var/choice = tgui_input_list(user, "Выберите узел входа в сеть. Для погружения используйте кнопку в его карточке.", "Нейролинк: узел погружения", choices)
	if(!QDELETED(src) && choice)
		select_entry(choices[choice], user)

/datum/netrun_console/implant/host_actions()
	. = ..()
	. += list(list("id" = "choose_entry", "name" = "Выбрать узел погружения", "icon" = "person-walking-arrow-right"))

/datum/netrun_console/implant/host_act(action, list/params, mob/user)
	if(action == "choose_entry")
		if(available_to(user))
			INVOKE_ASYNC(src, PROC_REF(choose_entry), user)
		return TRUE
	return ..()

/datum/netrun_console/implant/node_interactions(datum/component/netrun_node/node)
	. = ..()
	var/reason = dive_denial(node)
	. += list(list("id" = "dive", "name" = "Погрузиться в узел", "icon" = "person-walking-arrow-right", "enabled" = !reason, "reason" = reason))

/datum/netrun_console/implant/node_interact(datum/component/netrun_node/node, id, mob/user)
	if(id != "dive")
		return ..()
	var/reason = dive_denial(node, user)
	if(reason)
		log_line(reason, "bad")
		return FALSE
	var/obj/item/organ/cyberimp/brain/netlink/implant = host
	INVOKE_ASYNC(implant, TYPE_PROC_REF(/obj/item/organ/cyberimp/brain/netlink, try_dive), node)
	return TRUE
