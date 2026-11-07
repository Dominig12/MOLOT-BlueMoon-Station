

/*
Destructive Analyzer

It is used to destroy hand-held objects and advance technological research. Controls are in the linked R&D console.

Note: Must be placed within 3 tiles of the R&D Console
*/
/obj/machinery/rnd/destructive_analyzer
	name = "destructive analyzer"
	desc = "Learn science by destroying things!"
	icon_state = "d_analyzer"
	circuit = /obj/item/circuitboard/machine/destructive_analyzer
	var/decon_mod = 0

/obj/machinery/rnd/destructive_analyzer/RefreshParts()
	var/T = 0
	for(var/obj/item/stock_parts/S in component_parts)
		T += S.rating
	decon_mod = T


/obj/machinery/rnd/destructive_analyzer/proc/ConvertReqString2List(list/source_list)
	var/list/temp_list = params2list(source_list)
	for(var/O in temp_list)
		temp_list[O] = text2num(temp_list[O])
	return temp_list

/obj/machinery/rnd/destructive_analyzer/disconnect_console()
	linked_console.linked_destroy = null
	..()

/obj/machinery/rnd/destructive_analyzer/default_deconstruction_screwdriver(mob/user, icon_state_open, icon_state_closed, obj/item/I)
	if(user.a_intent == INTENT_DISARM || HAS_TRAIT(I, TRAIT_NODROP))
		return ..()

/obj/machinery/rnd/destructive_analyzer/Insert_Item(obj/item/O, mob/user)
	if(user.a_intent != INTENT_HARM)
		. = 1
		if(!is_insertion_ready(user))
			return
		if(!user.transferItemToLoc(O, src))
			to_chat(user, "<span class='warning'>\The [O] is stuck to your hand, you cannot put it in the [src.name]!</span>")
			return
		busy = TRUE
		loaded_item = O
		to_chat(user, "<span class='notice'>You add the [O.name] to the [src.name]!</span>")
		flick("d_analyzer_la", src)
		addtimer(CALLBACK(src, PROC_REF(finish_loading)), 10)
		if (linked_console)
			linked_console.updateUsrDialog()

/obj/machinery/rnd/destructive_analyzer/proc/finish_loading()
	update_icon()
	reset_busy()

/obj/machinery/rnd/destructive_analyzer/update_icon_state()
	if(loaded_item)
		icon_state = "d_analyzer_l"
	else
		icon_state = initial(icon_state)

/obj/machinery/rnd/destructive_analyzer/proc/reclaim_materials_from(obj/item/thing)
	. = 0
	var/datum/component/material_container/storage = linked_console?.linked_lathe?.materials.mat_container
	if(storage) //Also sends salvaged materials to a linked protolathe, if any.
		for(var/material in thing.custom_materials)
			var/can_insert = min((storage.max_amount - storage.total_amount), (min(thing.custom_materials[material]*(decon_mod/10), thing.custom_materials[material])))
			storage.insert_amount_mat(can_insert, material)
			. += can_insert
		if (.)
			linked_console.linked_lathe.materials.silo_log(src, "reclaimed", 1, "[thing.name]", thing.custom_materials)

/obj/machinery/rnd/destructive_analyzer/proc/destroy_item(obj/item/thing, innermode = FALSE)
	if(QDELETED(thing) || QDELETED(src) || QDELETED(linked_console))
		return FALSE
	if(!innermode)
		flick("d_analyzer_process", src)
		busy = TRUE
		addtimer(CALLBACK(src, PROC_REF(reset_busy)), 24)
		use_power(250)
		if(thing == loaded_item)
			loaded_item = null
		var/list/food = thing.GetDeconstructableContents()
		for(var/obj/item/innerthing in food)
			destroy_item(innerthing, TRUE)
	reclaim_materials_from(thing)
	for(var/mob/M in thing)
		M.death()
	qdel(thing)
	if (!innermode)
		update_icon()
	return TRUE

/obj/machinery/rnd/destructive_analyzer/proc/user_try_decon_id(id, mob/user)
	if(!loaded_item || QDELETED(loaded_item) || !linked_console || QDELETED(linked_console))
		return FALSE
	var/datum/component/techweb_holder/holder = linked_console.GetComponent(/datum/component/techweb_holder)
	if(!holder?.linked_techweb)
		return FALSE
	var/obj/item/target = loaded_item
	var/datum/techweb_node/node
	if(id && id != RESEARCH_MATERIAL_RECLAMATION_ID)
		node = SSresearch.techweb_node_by_id(id)
		if(!node)
			return FALSE
		var/list/boost = node.boost_item_paths[target.type]
		var/list/remote = holder.netdm_snapshot
		var/list/all_boosts = islist(remote) ? remote["boosted_nodes"] : null
		var/list/already = islist(all_boosts) ? all_boosts[node.id] : null
		if(length(boost))
			var/useful = FALSE
			for(var/type in boost)
				if(boost[type] > (already ? already[type] : 0))
					useful = TRUE
					break
			if(!useful)
				return FALSE
	var/list/points = techweb_item_point_check(target)
	var/subject = node ? "boost [node.display_name]" : "reclaim this item"
	var/choice = input(user, "Send [target] to the R&D server to [subject]?", "Remote analysis") in list("Proceed", "Cancel")
	if(choice != "Proceed")
		return FALSE
	if(QDELETED(src) || QDELETED(target) || target != loaded_item || QDELETED(linked_console) || !user.Adjacent(linked_console))
		return FALSE
	if(!holder.request_analyze(src, target, node?.id, user))
		to_chat(user, span_warning("Research network unavailable; the item is still intact."))
		return FALSE
	// Physical destruction and credit both occur on the server upon delivery.
	return TRUE

/obj/machinery/rnd/destructive_analyzer/proc/unload_item()
	if(!loaded_item)
		return FALSE
	loaded_item.forceMove(get_turf(src))
	loaded_item = null
	update_icon()
	return TRUE
