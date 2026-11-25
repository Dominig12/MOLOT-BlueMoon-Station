/obj/item/assembly/control
	name = "blast door controller"
	desc = "A small electronic device able to control a blast door remotely."
	icon_state = "control"
	attachable = TRUE
	/// Our ID. Make the first character ! if you want to obfuscate it as a mapper via randomization.
	var/id
	/// Чурки запретили ставить свой айдишник
	var/can_change_id = TRUE
	/// Show ID?
	var/show_id = TRUE
	var/cooldown = FALSE //Door cooldowns
	/// Should we toggle open/close of doors based on their current state
	var/sync_doors = TRUE

/obj/item/assembly/control/Initialize(mapload)
	if(mapload && id)
		if(copytext(id, 1, 2) == "!")
			id = SSmapping.get_obfuscated_id(id)
	return ..()

/obj/item/assembly/control/examine(mob/user)
	. = ..()
	if(id && show_id)
		. += span_notice("Its channel ID is '[id]'.")
	if(can_change_id)
		. += span_notice("Use in hand to change ID.")

/obj/item/assembly/control/attack_self(mob/living/user)
	. = ..()
	if(!can_change_id)
		return
		// защита от грифа (невозможность тыкать замаппленные бласты, цк в т.ч.)
	var/change_id = tgui_input_text(user, "Set the door controllers ID", "Door Controller ID", id, 100)
	if(!change_id || QDELETED(usr) || QDELETED(src) || !usr.canUseTopic(src, be_close = TRUE, no_dextery = FALSE, no_tk = TRUE))
		return
	id = change_id
	to_chat(user, span_notice("You change the ID to [id]."))
	balloon_alert(user, "id changed")

/obj/item/assembly/control/activate()
	var/datum/netdm_door_shadow/controller = SSnetdm_observe.doors
	var/list/plan = controller?.plan(src)
	if(!plan)
		if(usr)
			to_chat(usr, span_warning("Сетевой контроллер не отправил команду: устройство или маршрут недоступны."))
		return
	cooldown = TRUE
	addtimer(VARSET_CALLBACK(src, cooldown, FALSE), 10)
	controller.mirror(plan)

/// The mapped button prewarms this channel. Other controllers may opt into their own channel.
/obj/item/assembly/control/proc/netdm_mapped_channel()
	return type == /obj/item/assembly/control && id ? "blast:[id]" : null

/// Absolute commands for this press, keyed by the doors selected by this controller.
/obj/item/assembly/control/proc/netdm_plan_doors(authoritative)
	var/list/doors = list()
	var/openclose
	for(var/obj/machinery/door/poddoor/door in GLOB.airlocks)
		if(door.id == id)
			if(isnull(openclose) || !sync_doors)
				openclose = door.density
			doors[door] = list("state" = openclose ? "open" : "closed")
	return doors

/obj/item/assembly/control/airlock
	name = "airlock controller"
	desc = "A small electronic device able to control an airlock remotely."
	id = "badmin" // Set it to null for MEGAFUN.
	var/specialfunctions = OPEN
	/*
	Bitflag, 	1= open (OPEN)
				2= idscan (IDSCAN)
				4= bolts (BOLTS)
				8= shock (SHOCK)
				16= door safties (SAFE)
	*/

/obj/item/assembly/control/airlock/netdm_mapped_channel()
	return type == /obj/item/assembly/control/airlock && id && netdm_functions() ? "airlock:[id]" : null

/obj/item/assembly/control/airlock/proc/netdm_functions()
	return specialfunctions & (OPEN|IDSCAN|BOLTS|SHOCK|SAFE)

/obj/item/assembly/control/airlock/netdm_plan_doors(authoritative)
	var/functions = netdm_functions()
	if(!functions)
		return null
	var/list/doors = list()
	var/close = FALSE
	for(var/obj/machinery/door/airlock/door in GLOB.airlocks)
		if(door.id_tag != id)
			continue
		doors[door] = door.netdm_control_values(functions, authoritative)
		if(!door.density)
			close = TRUE
	if(functions & OPEN)
		for(var/door in doors)
			doors[door]["state"] = close ? "closed" : "open"
	return doors

/obj/item/assembly/control/massdriver
	name = "mass driver controller"
	desc = "A small electronic device able to control a mass driver."

/obj/item/assembly/control/massdriver/activate()
	cooldown = TRUE
	for(var/obj/machinery/door/poddoor/M in GLOB.machines)
		if (M.id == src.id)
			INVOKE_ASYNC(M, TYPE_PROC_REF(/obj/machinery/door/poddoor, open))

	sleep(10)

	for(var/obj/machinery/mass_driver/M in GLOB.machines)
		if(M.id == src.id)
			M.drive()

	sleep(60)

	for(var/obj/machinery/door/poddoor/M in GLOB.machines)
		if (M.id == src.id)
			INVOKE_ASYNC(M, TYPE_PROC_REF(/obj/machinery/door/poddoor, close))

	addtimer(VARSET_CALLBACK(src, cooldown, FALSE), 10)


/obj/item/assembly/control/igniter
	name = "ignition controller"
	desc = "A remote controller for a mounted igniter."

/obj/item/assembly/control/igniter/activate()
	cooldown = TRUE
	for(var/obj/machinery/sparker/M in GLOB.machines)
		if (M.id == src.id)
			INVOKE_ASYNC(M, TYPE_PROC_REF(/obj/machinery/sparker, ignite))

	for(var/obj/machinery/igniter/M in GLOB.machines)
		if(M.id == src.id)
			M.use_power(50)
			M.on = !M.on
			M.icon_state = "igniter[M.on]"

	addtimer(VARSET_CALLBACK(src, cooldown, FALSE), 30)

/obj/item/assembly/control/flasher
	name = "flasher controller"
	desc = "A remote controller for a mounted flasher."

/obj/item/assembly/control/flasher/activate()
	cooldown = TRUE
	for(var/obj/machinery/flasher/M in GLOB.machines)
		if(M.id == src.id)
			INVOKE_ASYNC(M, TYPE_PROC_REF(/obj/machinery/flasher, flash))

	addtimer(VARSET_CALLBACK(src, cooldown, FALSE), 50)

/obj/item/assembly/control/crematorium
	name = "crematorium controller"
	desc = "An evil-looking remote controller for a crematorium."

/obj/item/assembly/control/crematorium/activate()
	cooldown = TRUE
	for (var/obj/structure/bodycontainer/crematorium/C in GLOB.crematoriums)
		if (C.id == id)
			C.cremate(usr)

	addtimer(VARSET_CALLBACK(src, cooldown, FALSE), 50)

/obj/item/assembly/control/electrochromatic
	name = "electrochromatic glazing controller"
	desc = "Toggles linked electrochromatic windows, windoors, and glass-paneled airlocks."
	can_change_id = TRUE
	/// Stores our status to prevent windows from desyncing.
	var/on = FALSE

/obj/item/assembly/control/electrochromatic/activate()
	on = !on
	do_electrochromatic_toggle(on, id)
