#define IC_MAX_SIZE_BASE        25
#define IC_COMPLEXITY_BASE      75
#define COMPONENT_MAX_POS 10000
#define PORT_MAX_STRING_DISPLAY 40
#define PORT_MAX_NAME_LENGTH 20
#define IC_MAX_LIST_LENGTH 100

// Глобальный список базовых типов для нового интерфейса (должен совпадать с FUNDAMENTAL_DATA_TYPES)
GLOBAL_LIST_INIT(wiremod_basic_types, list(
	"string",
	"number",
	"entity",
	"datum",
	"signal",
	"option",
	"any"
))

/obj/item/electronic_assembly
	name = "electronic assembly"
	obj_flags = CAN_BE_HIT | UNIQUE_RENAME
	desc = "It's a case, for building small electronics with."
	w_class = WEIGHT_CLASS_SMALL
	icon = 'icons/obj/assemblies/electronic_setups.dmi'
	icon_state = "setup_small"
	item_flags = NOBLUDGEON
	custom_materials = null
	datum_flags = DF_USE_TAG
	var/list/assembly_components = list()
	var/list/ckeys_allowed_to_scan = list()
	var/max_components = IC_MAX_SIZE_BASE
	var/max_complexity = IC_COMPLEXITY_BASE
	var/opened = TRUE
	var/obj/item/stock_parts/cell/battery
	var/cell_type = /obj/item/stock_parts/cell
	var/can_charge = TRUE
	var/can_fire_equipped = FALSE
	var/charge_sections = 4
	var/charge_tick = FALSE
	var/charge_delay = 4
	var/use_cyborg_cell = TRUE
	var/ext_next_use = 0
	var/atom/collw
	var/obj/item/card/id/access_card
	var/allowed_circuit_action_flags = IC_ACTION_COMBAT | IC_ACTION_LONG_RANGE
	var/combat_circuits = 0
	var/long_range_circuits = 0
	var/prefered_hud_icon = "hudstat"
	var/creator
	var/static/next_assembly_id = 0
	var/sealed = FALSE

	// Новые переменные для TGUI
	var/admin_only = FALSE
	var/datum/weakref/linked_component_printer
	var/setter_and_getter_count = 0
	var/max_setters_and_getters = 30
	var/list/datum/circuit_variable/circuit_variables = list()
	var/list/datum/circuit_variable/list_variables = list()
	var/list/datum/circuit_variable/assoc_list_variables = list()
	var/list/datum/circuit_variable/modifiable_circuit_variables = list()
	var/screen_x = 0
	var/screen_y = 0
	var/grid_mode = TRUE
	var/examined_rel_x = 0
	var/examined_rel_y = 0
	var/datum/weakref/examined_component

	hud_possible = list(DIAG_STAT_HUD, DIAG_BATT_HUD, DIAG_TRACK_HUD, DIAG_CIRCUIT_HUD)
	max_integrity = 50
	pass_flags = 0
	armor = list(MELEE = 50, BULLET = 70, LASER = 70, ENERGY = 100, BOMB = 10, BIO = 100, RAD = 100, FIRE = 0, ACID = 0)
	anchored = FALSE
	var/can_anchor = TRUE
	var/detail_color = COLOR_ASSEMBLY_BLACK
	var/list/color_whitelist = list(
		COLOR_ASSEMBLY_BLACK,
		COLOR_FLOORTILE_GRAY,
		COLOR_ASSEMBLY_BGRAY,
		COLOR_ASSEMBLY_WHITE,
		COLOR_ASSEMBLY_RED,
		COLOR_ASSEMBLY_ORANGE,
		COLOR_ASSEMBLY_BEIGE,
		COLOR_ASSEMBLY_BROWN,
		COLOR_ASSEMBLY_GOLD,
		COLOR_ASSEMBLY_YELLOW,
		COLOR_ASSEMBLY_GURKHA,
		COLOR_ASSEMBLY_LGREEN,
		COLOR_ASSEMBLY_GREEN,
		COLOR_ASSEMBLY_LBLUE,
		COLOR_ASSEMBLY_BLUE,
		COLOR_ASSEMBLY_PURPLE
	)

/obj/item/electronic_assembly/New()
	..()
	src.max_components = round(max_components)
	src.max_complexity = round(max_complexity)

/obj/item/electronic_assembly/GenerateTag()
    tag = "assembly_[next_assembly_id++]"

/obj/item/electronic_assembly/examine(mob/user)
	. = ..()
	if(can_anchor)
		. += "<span class='notice'>The anchoring bolts [anchored ? "are" : "can be"] <b>wrenched</b> in place and the maintenance panel [opened ? "can be" : "is"] <b>screwed</b> in place.</span>"
	else
		. += "<span class='notice'>The maintenance panel [opened ? "can be" : "is"] <b>screwed</b> in place.</span>"

	if((isobserver(user) && ckeys_allowed_to_scan[user.ckey]) || IsAdminGhost(user))
		. += "You can <a href='?src=[REF(src)];ghostscan=1'>scan</a> this circuit."

	for(var/obj/item/integrated_circuit/I in assembly_components)
		var/examine_data = I.external_examine(user)
		if(examine_data)
			. += examine_data
	if(opened)
		interact(user)

/obj/item/electronic_assembly/proc/check_interactivity(mob/user)
	if(!istype(user, /mob))
		return
	return user.canUseTopic(src, BE_CLOSE)

/obj/item/electronic_assembly/Bump(atom/AM)
	collw = AM
	.=..()
	if((istype(collw, /obj/machinery/door/airlock) || istype(collw, /obj/machinery/door/window)) && (!isnull(access_card)))
		var/obj/machinery/door/D = collw
		if(D.check_access(access_card))
			D.open()

/obj/item/electronic_assembly/Initialize(mapload)
	LAZYSET(custom_materials, /datum/material/iron, round((max_complexity + max_components) * 0.25) * SScircuit.cost_multiplier)
	.=..()
	START_PROCESSING(SScircuit, src)

	prepare_huds()
	for(var/datum/atom_hud/data/diagnostic/diag_hud in GLOB.huds)
		diag_hud.add_to_hud(src)
	diag_hud_set_circuithealth()
	diag_hud_set_circuitcell()
	diag_hud_set_circuitstat()
	diag_hud_set_circuittracking()

	access_card = new /obj/item/card/id(src)

/obj/item/electronic_assembly/Destroy()
	STOP_PROCESSING(SScircuit, src)
	for(var/datum/atom_hud/data/diagnostic/diag_hud in GLOB.huds)
		diag_hud.remove_from_hud(src)
	QDEL_NULL(access_card)
	return ..()

/obj/item/electronic_assembly/process()
	handle_idle_power()
	check_pulling()
	diag_hud_set_circuithealth()
	diag_hud_set_circuitcell()

/obj/item/electronic_assembly/proc/handle_idle_power()
	for(var/obj/item/integrated_circuit/passive/power/P in assembly_components)
		P.make_energy()
	for(var/obj/item/integrated_circuit/I in assembly_components)
		if(I.power_draw_idle)
			if(!draw_power(I.power_draw_idle))
				I.power_fail()

/obj/item/electronic_assembly/interact(mob/user, circuit)
	ui_interact(user, circuit)

// TGUI Integration
/obj/item/electronic_assembly/ui_interact(mob/user, datum/tgui/ui)
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new(user, src, "IntegratedCircuit", name)
		ui.open()
		ui.set_autoupdate(FALSE)

/obj/item/electronic_assembly/ui_static_data(mob/user)
	. = list()
	.["global_basic_types"] = GLOB.wiremod_basic_types
	.["screen_x"] = screen_x
	.["screen_y"] = screen_y

	// В старой системе нет машинного принтера, поэтому временно отключаем
	// var/obj/item/integrated_circuit_printer/printer = linked_component_printer?.resolve()
	// if(printer)
	//	.["stored_designs"] = printer.current_unlocked_designs // нужно будет реализовать
	.["stored_designs"] = list() // заглушка

/obj/item/electronic_assembly/ui_data(mob/user)
	. = list()
	.["components"] = list()
	for(var/obj/item/integrated_circuit/component as anything in assembly_components)
		var/list/component_data = list()

		// Input ports
		component_data["input_ports"] = list()
		for(var/index in 1 to component.inputs.len)
			var/datum/integrated_io/input_port = component.inputs[index]
			var/current_data = input_port.data
			if(isatom(current_data))
				current_data = null
			var/list/connected_to = list()
			for(var/datum/integrated_io/linked in input_port.linked)
				connected_to += REF(linked)

			component_data["input_ports"] += list(list(
				"name" = input_port.name,
				"type" = "any",
				"ref" = REF(input_port),
				"connected_to" = connected_to,
				"color" = "blue",
				"current_data" = current_data,
				"datatype_data" = null
			))

		// Output ports
		component_data["output_ports"] = list()
		for(var/index in 1 to component.outputs.len)
			var/datum/integrated_io/output_port = component.outputs[index]
			component_data["output_ports"] += list(list(
				"name" = output_port.name,
				"type" = "any",
				"ref" = REF(output_port),
				"color" = "blue",
				"datatype_data" = null
			))

		component_data["name"] = component.displayed_name
		component_data["x"] = component.rel_x
		component_data["y"] = component.rel_y
		component_data["removable"] = component.removable
		component_data["color"] = "blue"
		component_data["category"] = ""
		component_data["ui_alerts"] = list()
		component_data["ui_buttons"] = list()

		.["components"] += list(component_data)

	// Variables (пустой список, если нет поддержки)
	.["variables"] = list()
	// Можно добавить заглушки, чтобы интерфейс не ломался
	// for(var/var_name in circuit_variables)
	// 	var/datum/circuit_variable/variable = circuit_variables[var_name]
	// 	var/list/variable_data = list()
	// 	variable_data["name"] = variable.name
	// 	variable_data["datatype"] = variable.datatype
	// 	variable_data["color"] = variable.color
	// 	if(islist(variable.value))
	// 		variable_data["is_list"] = TRUE
	// 	.["variables"] += list(variable_data)

	.["display_name"] = name

	// Examined component
	var/obj/item/integrated_circuit/examined
	if(examined_component)
		examined = examined_component.resolve()
	.["examined_name"] = examined?.displayed_name
	.["examined_desc"] = examined?.desc
	.["examined_notices"] = list()
	.["examined_rel_x"] = examined_rel_x
	.["examined_rel_y"] = examined_rel_y
	.["grid_mode"] = grid_mode

	// Заменяем isAdminGhostAI на IsAdminGhost
	.["is_admin"] = (admin_only || IsAdminGhost(user)) && check_rights_for(user.client, R_VAREDIT)

#define WITHIN_RANGE(id, table) (id >= 1 && id <= length(table))

/obj/item/electronic_assembly/ui_act(action, list/params, datum/tgui/ui)
	. = ..()
	if(.)
		return

	switch(action)
		if("add_connection")
			var/input_component_id = text2num(params["input_component_id"])
			var/output_component_id = text2num(params["output_component_id"])
			var/input_port_id = text2num(params["input_port_id"])
			var/output_port_id = text2num(params["output_port_id"])
			if(!WITHIN_RANGE(input_component_id, assembly_components) || !WITHIN_RANGE(output_component_id, assembly_components))
				return
			var/obj/item/integrated_circuit/input_component = assembly_components[input_component_id]
			var/obj/item/integrated_circuit/output_component = assembly_components[output_component_id]

			if(!WITHIN_RANGE(input_port_id, input_component.inputs) || !WITHIN_RANGE(output_port_id, output_component.outputs))
				return
			var/datum/integrated_io/input_port = input_component.inputs[input_port_id]
			var/datum/integrated_io/output_port = output_component.outputs[output_port_id]

			input_port.connect_pin(output_port)
			. = TRUE

		if("remove_connection")
			var/component_id = text2num(params["component_id"])
			var/is_input = params["is_input"]
			var/port_id = text2num(params["port_id"])

			if(!WITHIN_RANGE(component_id, assembly_components))
				return
			var/obj/item/integrated_circuit/component = assembly_components[component_id]

			var/list/port_table = is_input ? component.inputs : component.outputs
			if(!WITHIN_RANGE(port_id, port_table))
				return

			var/datum/integrated_io/port = port_table[port_id]
			port.disconnect_all()
			. = TRUE

		if("detach_component")
			var/component_id = text2num(params["component_id"])
			if(!WITHIN_RANGE(component_id, assembly_components))
				return
			var/obj/item/integrated_circuit/component = assembly_components[component_id]
			if(!component.removable)
				return
			try_remove_component(component, ui.user)
			. = TRUE

		if("set_component_coordinates")
			var/component_id = text2num(params["component_id"])
			if(!WITHIN_RANGE(component_id, assembly_components))
				return
			var/obj/item/integrated_circuit/component = assembly_components[component_id]
			component.rel_x = clamp(text2num(params["rel_x"]), -COMPONENT_MAX_POS, COMPONENT_MAX_POS)
			component.rel_y = clamp(text2num(params["rel_y"]), -COMPONENT_MAX_POS, COMPONENT_MAX_POS)
			. = TRUE

		if("set_component_input")
			var/component_id = text2num(params["component_id"])
			var/port_id = text2num(params["port_id"])
			if(!WITHIN_RANGE(component_id, assembly_components))
				return
			var/obj/item/integrated_circuit/component = assembly_components[component_id]
			if(!WITHIN_RANGE(port_id, component.inputs))
				return
			var/datum/integrated_io/port = component.inputs[port_id]

			if(params["set_null"])
				port.set_input(null)
				return TRUE

			if(params["marked_atom"])
				// Упрощённая обработка: только для админов через marked_datum
				var/client/user = usr.client
				if(!check_rights_for(user, R_VAREDIT))
					return TRUE
				var/atom/marked_atom = user.holder?.marked_datum
				if(!marked_atom)
					return TRUE
				port.set_input(marked_atom)
				balloon_alert(usr, "updated [port.name]'s value to marked object.")
				return TRUE

			port.set_input(params["input"])
			. = TRUE

		if("get_component_value")
			var/component_id = text2num(params["component_id"])
			var/port_id = text2num(params["port_id"])
			if(!WITHIN_RANGE(component_id, assembly_components))
				return
			var/obj/item/integrated_circuit/component = assembly_components[component_id]
			if(!WITHIN_RANGE(port_id, component.outputs))
				return

			var/datum/integrated_io/output_port = component.outputs[port_id]
			var/value = output_port.data
			if(isatom(value))
				value = "atom"
			else if(isnull(value))
				value = "null"
			var/string_form = copytext("[value]", 1, PORT_MAX_STRING_DISPLAY)
			if(length(string_form) >= PORT_MAX_STRING_DISPLAY-1)
				string_form += "..."
			balloon_alert(usr, "[output_port.name] value: [string_form]")
			. = TRUE

		if("set_display_name")
			var/new_name = params["display_name"]
			set_display_name(new_name)
			. = TRUE

		if("toggle_grid_mode")
			grid_mode = !grid_mode
			. = TRUE

		if("set_examined_component")
			var/component_id = text2num(params["component_id"])
			if(!WITHIN_RANGE(component_id, assembly_components))
				return
			examined_component = WEAKREF(assembly_components[component_id])
			examined_rel_x = text2num(params["x"])
			examined_rel_y = text2num(params["y"])
			. = TRUE

		if("remove_examined_component")
			examined_component = null
			. = TRUE

		if("save_circuit")
			return attempt_save_to(usr.client)

		// Блоки, связанные с переменными, временно отключены
		/*
		if("add_variable")
			...
		if("remove_variable")
			...
		if("add_setter_or_getter")
			...
		*/

		if("move_screen")
			screen_x = text2num(params["screen_x"])
			screen_y = text2num(params["screen_y"])
			. = TRUE

		if("perform_action")
			var/component_id = text2num(params["component_id"])
			if(!WITHIN_RANGE(component_id, assembly_components))
				return
			var/obj/item/integrated_circuit/component = assembly_components[component_id]
			component.ui_perform_action(ui.user, params["action_name"])
			. = TRUE

#undef WITHIN_RANGE

/obj/item/electronic_assembly/proc/set_display_name(new_name)
	if(new_name)
		name = copytext_char(new_name, 1, 24)
	else
		name = initial(name)

/obj/item/electronic_assembly/proc/clear_setter_or_getter(datum/source)
	SIGNAL_HANDLER
	setter_and_getter_count--

/obj/item/electronic_assembly/proc/attempt_save_to(client/saver)
	if(!check_rights_for(saver, R_VAREDIT))
		return FALSE
	var/temp_file = file("data/CircuitDownloadTempFile")
	fdel(temp_file)
	WRITE_FILE(temp_file, SScircuit.save_electronic_assembly(src))
	DIRECT_OUTPUT(saver, ftp(temp_file, "[name || "circuit"].json"))

/obj/item/electronic_assembly/GenerateTag()
    tag = "assembly_[next_assembly_id++]"

/obj/item/electronic_assembly/Bump(atom/AM)
	collw = AM
	.=..()
	if((istype(collw, /obj/machinery/door/airlock) ||  istype(collw, /obj/machinery/door/window)) && (!isnull(access_card)))
		var/obj/machinery/door/D = collw
		if(D.check_access(access_card))
			D.open()

/obj/item/electronic_assembly/pickup(mob/living/user)
	. = ..()
	diag_hud_set_circuithealth(TRUE)
	diag_hud_set_circuitcell(TRUE)
	diag_hud_set_circuitstat(TRUE)
	diag_hud_set_circuittracking(TRUE)

/obj/item/electronic_assembly/dropped(mob/user)
	. = ..()
	diag_hud_set_circuithealth()
	diag_hud_set_circuitcell()
	diag_hud_set_circuitstat()
	diag_hud_set_circuittracking()

/obj/item/electronic_assembly/proc/rename()
	var/mob/M = usr
	if(!check_interactivity(M))
		return

	var/input = reject_bad_name(input("What do you want to name this?", "Rename", src.name) as null|text, TRUE)
	if(!check_interactivity(M))
		return
	if(src && input)
		to_chat(M, "<span class='notice'>The machine now has a label reading '[input]'.</span>")
		name = input

/obj/item/electronic_assembly/proc/add_allowed_scanner(ckey)
	ckeys_allowed_to_scan[ckey] = TRUE

/obj/item/electronic_assembly/proc/can_move()
	return FALSE

/obj/item/electronic_assembly/update_icon()
	if(opened)
		icon_state = initial(icon_state) + "-open"
	else
		icon_state = initial(icon_state)
	cut_overlays()
	if(detail_color == COLOR_ASSEMBLY_BLACK)
		return
	var/mutable_appearance/detail_overlay = mutable_appearance('icons/obj/assemblies/electronic_setups.dmi', "[icon_state]-color")
	detail_overlay.color = detail_color
	add_overlay(detail_overlay)

/obj/item/electronic_assembly/proc/return_total_complexity()
	var/returnvalue = 0
	for(var/obj/item/integrated_circuit/part in assembly_components)
		returnvalue += part.complexity
	return(returnvalue)

/obj/item/electronic_assembly/proc/return_total_size()
	var/returnvalue = 0
	for(var/obj/item/integrated_circuit/part in assembly_components)
		returnvalue += part.size
	return(returnvalue)

/obj/item/electronic_assembly/proc/try_add_component(obj/item/integrated_circuit/IC, mob/user)
	if(!opened)
		to_chat(user, "<span class='warning'>\The [src]'s hatch is closed, you can't put anything inside.</span>")
		return FALSE

	if(IC.w_class > w_class)
		to_chat(user, "<span class='warning'>\The [IC] is way too big to fit into \the [src].</span>")
		return FALSE
	if(istype(IC, /obj/item/integrated_circuit/manipulation/interacter) && locate(/obj/item/integrated_circuit/manipulation/interacter) in src.assembly_components)
		to_chat(user, "<span class='warning'>Вы не можете вставить две этих детали в один корпус.</span>")
		return FALSE
	var/total_part_size = return_total_size()
	var/total_complexity = return_total_complexity()

	if((total_part_size + IC.size) > max_components)
		to_chat(user, "<span class='warning'>You can't seem to add the '[IC]', as there's insufficient space.</span>")
		return FALSE
	if((total_complexity + IC.complexity) > max_complexity)
		to_chat(user, "<span class='warning'>You can't seem to add the '[IC]', since this setup's too complicated for the case.</span>")
		return FALSE
	if((allowed_circuit_action_flags & IC.action_flags) != IC.action_flags)
		to_chat(user, "<span class='warning'>You can't seem to add the '[IC]', since the case doesn't support the circuit type.</span>")
		return FALSE

	if(!user.transferItemToLoc(IC, src))
		return FALSE

	to_chat(user, "<span class='notice'>You slide [IC] inside [src].</span>")
	playsound(src, 'sound/items/Deconstruct.ogg', 50, 1)
	add_allowed_scanner(user.ckey)
	investigate_log("had [IC]([IC.type]) inserted by [key_name(user)].", INVESTIGATE_CIRCUIT)

	add_component(IC)
	return TRUE

/obj/item/electronic_assembly/proc/add_component(obj/item/integrated_circuit/component)
	component.forceMove(get_object())
	component.assembly = src
	assembly_components |= component

	if(component.action_flags & IC_ACTION_COMBAT)
		combat_circuits += 1
	if(component.action_flags & IC_ACTION_LONG_RANGE)
		long_range_circuits += 1

	diag_hud_set_circuitstat()
	diag_hud_set_circuittracking()

/obj/item/electronic_assembly/proc/try_remove_component(obj/item/integrated_circuit/IC, mob/user, silent)
	if(!opened)
		if(!silent)
			to_chat(user, "<span class='warning'>[src]'s hatch is closed, so you can't fiddle with the internal components.</span>")
		return FALSE

	if(!IC.removable)
		if(!silent)
			to_chat(user, "<span class='warning'>[src] is permanently attached to the case.</span>")
		return FALSE

	remove_component(IC)
	if(!silent)
		to_chat(user, "<span class='notice'>You pop \the [IC] out of the case, and slide it out.</span>")
		playsound(src, 'sound/items/crowbar.ogg', 50, 1)
		user.put_in_hands(IC)
	add_allowed_scanner(user.ckey)
	investigate_log("had [IC]([IC.type]) removed by [key_name(user)].", INVESTIGATE_CIRCUIT)

	return TRUE

/obj/item/electronic_assembly/proc/remove_component(obj/item/integrated_circuit/component)
	component.disconnect_all()
	component.forceMove(drop_location())
	component.assembly = null

	assembly_components -= component

	if(component.action_flags & IC_ACTION_COMBAT)
		combat_circuits -= 1
	if(component.action_flags & IC_ACTION_LONG_RANGE)
		long_range_circuits -= 1

	diag_hud_set_circuitstat()
	diag_hud_set_circuittracking()

/obj/item/electronic_assembly/afterattack(atom/target, mob/user, proximity)
	. = ..()
	for(var/obj/item/integrated_circuit/input/S in assembly_components)
		if(S.sense(target,user,proximity))
			visible_message("<span class='notice'> [user] waves [src] around [target].</span>")

/obj/item/electronic_assembly/screwdriver_act(mob/living/user, obj/item/I)
	if(sealed)
		to_chat(user,"<span class='notice'>The assembly is sealed. Any attempt to force it open would break it.</span>")
		return FALSE
	if(..())
		return TRUE
	I.play_tool_sound(src)
	opened = !opened
	to_chat(user, "<span class='notice'>You [opened ? "open" : "close"] the maintenance hatch of [src].</span>")
	update_icon()
	return TRUE

/obj/item/electronic_assembly/welder_act(mob/living/user, obj/item/I)
	var/type_to_use

	if(!sealed)
		type_to_use = input("What would you like to do?","[src] type setting") as null|anything in list("repair", "seal")
	else
		type_to_use = input("What would you like to do?","[src] type setting") as null|anything in list("repair", "unseal")

	switch(type_to_use)
		if("repair")
			if(obj_integrity < max_integrity)
				obj_integrity = min(obj_integrity + 20,max_integrity)
				to_chat(user,"<span class='notice'>You fix the dents and scratches of the assembly.</span>")
				to_chat(user, "<span class='notice'>Integrity: [obj_integrity] / [max_integrity]</span>")
				return TRUE
			else
				to_chat(user,"<span class='notice'>The assembly is already in impeccable condition.</span>")
				return FALSE
		if("seal")
			if(!opened)
				sealed = TRUE
				if(I.use_tool(src, user, 50, volume=100, amount=3))
					to_chat(user,"<span class='notice'>You seal the assembly, making it impossible to be opened.</span>")
					return TRUE
			else
				to_chat(user,"<span class='notice'>You need to close the assembly first before sealing it indefinitely!</span>")
				return FALSE
		if("unseal")
			to_chat(user,"<span class='notice'>You start unsealing the assembly carefully...</span>")
			if(I.use_tool(src, user, 50, volume=250, amount=3))
				for(var/obj/item/integrated_circuit/IC in assembly_components)
					if(prob(50))
						IC.disconnect_all()
				to_chat(user,"<span class='notice'>You unsealed the assembly.</span>")
				sealed = FALSE
				return TRUE

/obj/item/electronic_assembly/attackby(obj/item/I, mob/living/user)
	if(can_anchor && default_unfasten_wrench(user, I, 20))
		return

	if(istype(I, /obj/item/integrated_circuit))
		if(!user.canUnEquip(I))
			return FALSE
		if(try_add_component(I, user))
			return TRUE
		else
			for(var/obj/item/integrated_circuit/input/S in assembly_components)
				S.attackby_react(I,user,user.a_intent)
			return ..()
	else if(I.tool_behaviour == TOOL_MULTITOOL || istype(I, /obj/item/integrated_electronics/wirer) || istype(I, /obj/item/integrated_electronics/debugger))
		if(opened)
			interact(user)
			return TRUE
		else
			to_chat(user, "<span class='warning'>[src]'s hatch is closed, so you can't fiddle with the internal components.</span>")
			for(var/obj/item/integrated_circuit/input/S in assembly_components)
				S.attackby_react(I,user,user.a_intent)
			return ..()
	else if(istype(I, /obj/item/stock_parts/cell))
		if(!opened)
			to_chat(user, "<span class='warning'>[src]'s hatch is closed, so you can't access \the [src]'s power supplier.</span>")
			for(var/obj/item/integrated_circuit/input/S in assembly_components)
				S.attackby_react(I,user,user.a_intent)
			return ..()
		if(battery)
			to_chat(user, "<span class='warning'>[src] already has \a [battery] installed. Remove it first if you want to replace it.</span>")
			for(var/obj/item/integrated_circuit/input/S in assembly_components)
				S.attackby_react(I,user,user.a_intent)
			return ..()
		I.forceMove(src)
		battery = I
		diag_hud_set_circuitstat()
		playsound(get_turf(src), 'sound/items/Deconstruct.ogg', 50, 1)
		to_chat(user, "<span class='notice'>You slot the [I] inside \the [src]'s power supplier.</span>")
		return TRUE
	else if(istype(I, /obj/item/integrated_electronics/detailer))
		var/obj/item/integrated_electronics/detailer/D = I
		detail_color = D.detail_color
		update_icon()
	else
		if(user.a_intent != INTENT_HELP)
			return ..()
		var/list/input_selection = list()
		for(var/obj/item/integrated_circuit/input in assembly_components)
			if((input.demands_object_input && opened) || (input.demands_object_input && input.can_input_object_when_closed))
				var/i = 0
				for(var/s in input_selection)
					var/obj/item/integrated_circuit/s_circuit = input_selection[s]
					if(s_circuit.name == input.name && s_circuit.displayed_name == input.displayed_name && s_circuit != input)
						i++
				var/disp_name= "[input.displayed_name] \[[input]\]"
				if(i)
					disp_name += " ([i+1])"
				input_selection[disp_name] = input

		var/obj/item/integrated_circuit/choice
		if(input_selection)
			if(input_selection.len == 1)
				choice = input_selection[input_selection[1]]
			else
				var/selection = input(user, "Where do you want to insert that item?", "Interaction") as null|anything in input_selection
				if(!check_interactivity(user))
					return ..()
				if(selection)
					choice = input_selection[selection]
			if(choice)
				choice.additem(I, user)
		for(var/obj/item/integrated_circuit/input/S in assembly_components)
			S.attackby_react(I,user,user.a_intent)
		return ..()

/obj/item/electronic_assembly/attack_self(mob/user)
	set waitfor = FALSE
	if(!check_interactivity(user))
		return
	if(opened)
		interact(user)

	var/list/input_selection = list()
	for(var/obj/item/integrated_circuit/input/input in assembly_components)
		if(input.can_be_asked_input)
			var/i = 0
			for(var/s in input_selection)
				var/obj/item/integrated_circuit/s_circuit = input_selection[s]
				if(s_circuit.name == input.name && s_circuit.displayed_name == input.displayed_name && s_circuit != input)
					i++
			var/disp_name= "[input.displayed_name] \[[input]\]"
			if(i)
				disp_name += " ([i+1])"
			input_selection[disp_name] = input

	var/obj/item/integrated_circuit/input/choice

	if(input_selection)
		if(input_selection.len ==1)
			choice = input_selection[input_selection[1]]
		else
			var/selection = input(user, "What do you want to interact with?", "Interaction") as null|anything in input_selection
			if(!check_interactivity(user))
				return
			if(selection)
				choice = input_selection[selection]

	if(choice)
		choice.ask_for_input(user)

/obj/item/electronic_assembly/emp_act(severity)
	. = ..()
	if(. & EMP_PROTECT_CONTENTS)
		return
	for(var/I in src)
		var/atom/movable/AM = I
		AM.emp_act(severity)

/obj/item/electronic_assembly/proc/draw_power(amount)
	if(battery && battery.use(amount * GLOB.CELLRATE))
		return TRUE
	return FALSE

/obj/item/electronic_assembly/proc/give_power(amount)
	if(battery && battery.give(amount * GLOB.CELLRATE))
		return TRUE
	return FALSE

/obj/item/electronic_assembly/Moved(oldLoc, dir)
	. = ..()
	for(var/I in assembly_components)
		var/obj/item/integrated_circuit/IC = I
		IC.ext_moved(oldLoc, dir)
	if(light)
		update_light()

/obj/item/electronic_assembly/stop_pulling()
	for(var/I in assembly_components)
		var/obj/item/integrated_circuit/IC = I
		IC.stop_pulling()
	..()

/obj/item/electronic_assembly/proc/get_object()
	return src

/obj/item/integrated_circuit/drop_location()
	var/atom/movable/acting_object = get_object()
	if(acting_object == src)
		return ..()
	return acting_object.drop_location()

/obj/item/electronic_assembly/attack_tk(mob/user)
	if(anchored)
		return
	..()

/obj/item/electronic_assembly/on_attack_hand(mob/user, act_intent = user.a_intent, unarmed_attack_flags)
	if(anchored)
		attack_self(user)
		return
	..()

/obj/item/electronic_assembly/default //The /default electronic_assemblys are to allow the introduction of the new naming scheme without breaking old saves.
	name = "type-a electronic assembly"

/obj/item/electronic_assembly/calc
	name = "type-b electronic assembly"
	icon_state = "setup_small_calc"
	desc = "It's a case, for building small electronics with. This one resembles a pocket calculator."

/obj/item/electronic_assembly/clam
	name = "type-c electronic assembly"
	icon_state = "setup_small_clam"
	desc = "It's a case, for building small electronics with. This one has a clamshell design."

/obj/item/electronic_assembly/simple
	name = "type-d electronic assembly"
	icon_state = "setup_small_simple"
	desc = "It's a case, for building small electronics with. This one has a simple design."

/obj/item/electronic_assembly/hook
	name = "type-e electronic assembly"
	icon_state = "setup_small_hook"
	desc = "It's a case, for building small electronics with. This one looks like it has a belt clip, but it's purely decorative."

/obj/item/electronic_assembly/pda
	name = "type-f electronic assembly"
	icon_state = "setup_small_pda"
	desc = "It's a case, for building small electronics with. This one resembles a PDA."
	slot_flags = ITEM_SLOT_ID | ITEM_SLOT_BELT

/obj/item/electronic_assembly/dildo
	name = "type-g electronic assembly"
	icon_state = "setup_dildo_medium"
	desc = "It's a case, for building small electronics with. This one has a phallic design."

/obj/item/electronic_assembly/small
	name = "electronic device"
	icon_state = "setup_device"
	desc = "It's a case, for building tiny-sized electronics with."
	w_class = WEIGHT_CLASS_TINY
	max_components = IC_MAX_SIZE_BASE / 2
	max_complexity = IC_COMPLEXITY_BASE / 2

/obj/item/electronic_assembly/small/default
	name = "type-a electronic device"

/obj/item/electronic_assembly/small/cylinder
	name = "type-b electronic device"
	icon_state = "setup_device_cylinder"
	desc = "It's a case, for building tiny-sized electronics with. This one has a cylindrical design."

/obj/item/electronic_assembly/small/scanner
	name = "type-c electronic device"
	icon_state = "setup_device_scanner"
	desc = "It's a case, for building tiny-sized electronics with. This one has a scanner-like design."

/obj/item/electronic_assembly/small/hook
	name = "type-d electronic device"
	icon_state = "setup_device_hook"
	desc = "It's a case, for building tiny-sized electronics with. This one looks like it has a belt clip, but it's purely decorative."

/obj/item/electronic_assembly/small/box
	name = "type-e electronic device"
	icon_state = "setup_device_box"
	desc = "It's a case, for building tiny-sized electronics with. This one has a boxy design."

/obj/item/electronic_assembly/small/dildo
	name = "type-f electronic device"
	icon_state = "setup_dildo_small"
	desc = "It's a case, for building tiny-sized electronics with. This one has a phallic design."

/obj/item/electronic_assembly/medium
	name = "electronic mechanism"
	icon_state = "setup_medium"
	desc = "It's a case, for building medium-sized electronics with."
	w_class = WEIGHT_CLASS_NORMAL
	max_components = IC_MAX_SIZE_BASE * 2
	max_complexity = IC_COMPLEXITY_BASE * 2

/obj/item/electronic_assembly/medium/default
	name = "type-a electronic mechanism"

/obj/item/electronic_assembly/medium/box
	name = "type-b electronic mechanism"
	icon_state = "setup_medium_box"
	desc = "It's a case, for building medium-sized electronics with. This one has a boxy design."

/obj/item/electronic_assembly/medium/clam
	name = "type-c electronic mechanism"
	icon_state = "setup_medium_clam"
	desc = "It's a case, for building medium-sized electronics with. This one has a clamshell design."

/obj/item/electronic_assembly/medium/medical
	name = "type-d electronic mechanism"
	icon_state = "setup_medium_med"
	desc = "It's a case, for building medium-sized electronics with. This one resembles some type of medical apparatus."

/obj/item/electronic_assembly/medium/gun
	name = "type-e electronic mechanism"
	icon_state = "setup_medium_gun"
	item_state = "circuitgun"
	desc = "It's a case, for building medium-sized electronics with. This one resembles a gun, or some type of tool, if you're feeling optimistic. It can fire guns and throw items while the user is holding it."
	lefthand_file = 'icons/mob/inhands/weapons/guns_lefthand.dmi'
	righthand_file = 'icons/mob/inhands/weapons/guns_righthand.dmi'
	can_fire_equipped = TRUE

/obj/item/electronic_assembly/medium/radio
	name = "type-f electronic mechanism"
	icon_state = "setup_medium_radio"
	desc = "It's a case, for building medium-sized electronics with. This one resembles an old radio."

/obj/item/electronic_assembly/medium/dildo
	name = "type-g electronic mechanism"
	icon_state = "setup_dildo_large"
	desc = "It's a case, for building medium-sized electronics with. This one has a phallic design."


/obj/item/electronic_assembly/large
	name = "electronic machine"
	icon_state = "setup_large"
	desc = "It's a case, for building large electronics with."
	w_class = WEIGHT_CLASS_BULKY
	max_components = IC_MAX_SIZE_BASE * 4
	max_complexity = IC_COMPLEXITY_BASE * 4

/obj/item/electronic_assembly/large/default
	name = "type-a electronic machine"

/obj/item/electronic_assembly/large/scope
	name = "type-b electronic machine"
	icon_state = "setup_large_scope"
	desc = "It's a case, for building large electronics with. This one resembles an oscilloscope."

/obj/item/electronic_assembly/large/terminal
	name = "type-c electronic machine"
	icon_state = "setup_large_terminal"
	desc = "It's a case, for building large electronics with. This one resembles a computer terminal."

/obj/item/electronic_assembly/large/arm
	name = "type-d electronic machine"
	icon_state = "setup_large_arm"
	desc = "It's a case, for building large electronics with. This one resembles a robotic arm."

/obj/item/electronic_assembly/large/tall
	name = "type-e electronic machine"
	icon_state = "setup_large_tall"
	desc = "It's a case, for building large electronics with. This one has a tall design."

/obj/item/electronic_assembly/large/industrial
	name = "type-f electronic machine"
	icon_state = "setup_large_industrial"
	desc = "It's a case, for building large electronics with. This one resembles some kind of industrial machinery."

/obj/item/electronic_assembly/drone
	name = "electronic drone"
	icon_state = "setup_drone"
	desc = "It's a case, for building mobile electronics with."
	w_class = WEIGHT_CLASS_NORMAL
	max_components = IC_MAX_SIZE_BASE * 3
	max_complexity = IC_COMPLEXITY_BASE * 3
	allowed_circuit_action_flags = IC_ACTION_MOVEMENT | IC_ACTION_COMBAT | IC_ACTION_LONG_RANGE
	can_anchor = FALSE

/obj/item/electronic_assembly/drone/can_move()
	return TRUE

/obj/item/electronic_assembly/drone/default
	name = "type-a electronic drone"

/obj/item/electronic_assembly/drone/arms
	name = "type-b electronic drone"
	icon_state = "setup_drone_arms"
	desc = "It's a case, for building mobile electronics with. This one is armed and dangerous."

/obj/item/electronic_assembly/drone/secbot
	name = "type-c electronic drone"
	icon_state = "setup_drone_secbot"
	desc = "It's a case, for building mobile electronics with. This one resembles a Securitron."

/obj/item/electronic_assembly/drone/medbot
	name = "type-d electronic drone"
	icon_state = "setup_drone_medbot"
	desc = "It's a case, for building mobile electronics with. This one resembles a Medibot."

/obj/item/electronic_assembly/drone/genbot
	name = "type-e electronic drone"
	icon_state = "setup_drone_genbot"
	desc = "It's a case, for building mobile electronics with. This one has a generic bot design."

/obj/item/electronic_assembly/drone/android
	name = "type-f electronic drone"
	icon_state = "setup_drone_android"
	desc = "It's a case, for building mobile electronics with. This one has a hominoid design."

/obj/item/electronic_assembly/wallmount
	name = "wall-mounted electronic assembly"
	icon_state = "setup_wallmount_medium"
	desc = "It's a case, for building medium-sized electronics with. It has a magnetized backing to allow it to stick to walls, but you'll still need to wrench the anchoring bolts in place to keep it on."
	w_class = WEIGHT_CLASS_NORMAL
	max_components = IC_MAX_SIZE_BASE * 2
	max_complexity = IC_COMPLEXITY_BASE * 2

/obj/item/electronic_assembly/wallmount/heavy
	name = "heavy wall-mounted electronic assembly"
	icon_state = "setup_wallmount_large"
	desc = "It's a case, for building large electronics with. It has a magnetized backing to allow it to stick to walls, but you'll still need to wrench the anchoring bolts in place to keep it on."
	w_class = WEIGHT_CLASS_BULKY
	max_components = IC_MAX_SIZE_BASE * 4
	max_complexity = IC_COMPLEXITY_BASE * 4

/obj/item/electronic_assembly/wallmount/light
	name = "light wall-mounted electronic assembly"
	icon_state = "setup_wallmount_small"
	desc = "It's a case, for building small electronics with. It has a magnetized backing to allow it to stick to walls, but you'll still need to wrench the anchoring bolts in place to keep it on."
	w_class = WEIGHT_CLASS_SMALL
	max_components = IC_MAX_SIZE_BASE
	max_complexity = IC_COMPLEXITY_BASE

/obj/item/electronic_assembly/wallmount/tiny
	name = "tiny wall-mounted electronic assembly"
	icon_state = "setup_wallmount_tiny"
	desc = "It's a case, for building tiny electronics with. It has a magnetized backing to allow it to stick to walls, but you'll still need to wrench the anchoring bolts in place to keep it on."
	w_class = WEIGHT_CLASS_TINY
	max_components = IC_MAX_SIZE_BASE / 2
	max_complexity = IC_COMPLEXITY_BASE / 2

/obj/item/electronic_assembly/wallmount/proc/mount_assembly(turf/on_wall, mob/user) //Yeah, this is admittedly just an abridged and kitbashed version of the wallframe attach procs.
	if(get_dist(on_wall,user)>1)
		return
	var/ndir = get_dir(on_wall, user)
	if(!(ndir in GLOB.cardinals))
		return
	var/turf/T = get_turf(user)
	if(!isfloorturf(T))
		to_chat(user, "<span class='warning'>You cannot place [src] on this spot!</span>")
		return
	if(gotwallitem(T, ndir))
		to_chat(user, "<span class='warning'>There's already an item on this wall!</span>")
		return
	playsound(src.loc, 'sound/machines/click.ogg', 75, 1)
	user.visible_message("[user.name] attaches [src] to the wall.",
		"<span class='notice'>You attach [src] to the wall.</span>",
		"<span class='italics'>You hear clicking.</span>")
	user.dropItemToGround(src)
	switch(ndir)
		if(NORTH)
			pixel_y = -31
		if(SOUTH)
			pixel_y = 31
		if(EAST)
			pixel_x = -31
		if(WEST)
			pixel_x = 31
	plane = ABOVE_WALL_PLANE

/obj/item/electronic_assembly/wallmount/Moved(atom/OldLoc, Dir, Forced = FALSE) //reset the plane if moved off the wall.
	. = ..()
	plane = GAME_PLANE
