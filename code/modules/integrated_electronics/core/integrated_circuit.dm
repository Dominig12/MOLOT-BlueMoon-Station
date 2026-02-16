/obj/item/integrated_circuit
	name = "integrated circuit"
	desc = "It's a tiny chip!  This one doesn't seem to do much, however."
	icon = 'icons/obj/assemblies/electronic_components.dmi'
	icon_state = "template"
	w_class = WEIGHT_CLASS_TINY
	custom_materials = null
	var/obj/item/electronic_assembly/assembly
	var/extended_desc
	var/list/inputs = list()
	var/list/inputs_default = list()
	var/list/outputs = list()
	var/list/outputs_default = list()
	var/list/activators = list()
	var/next_use = 0
	var/complexity = 1
	var/size = 1
	var/cooldown_per_use = 1
	var/ext_cooldown = 0
	var/power_draw_per_use = 0
	var/power_draw_idle = 0
	var/spawn_flags
	var/action_flags = NONE
	var/category_text = "NO CATEGORY THIS IS A BUG"
	var/removable = TRUE
	var/displayed_name = ""
	var/demands_object_input = FALSE
	var/can_input_object_when_closed = FALSE

	// Координаты для отображения в интерфейсе (добавляем, если нет)
	var/rel_x = 0
	var/rel_y = 0

/obj/item/integrated_circuit/examine(mob/user)
	interact(user)
	external_examine(user)
	. = ..()

/obj/item/integrated_circuit/proc/additem(var/obj/item/I, var/mob/living/user)
	attackby(I, user)

/obj/item/integrated_circuit/proc/internal_examine(mob/user)
	to_chat(user, "This board has [inputs.len] input pin\s, [outputs.len] output pin\s and [activators.len] activation pin\s.")
	for(var/k in inputs)
		var/datum/integrated_io/I = k
		if(I.linked.len)
			to_chat(user, "The '[I]' is connected to [I.get_linked_to_desc()].")
	for(var/k in outputs)
		var/datum/integrated_io/O = k
		if(O.linked.len)
			to_chat(user, "The '[O]' is connected to [O.get_linked_to_desc()].")
	for(var/k in activators)
		var/datum/integrated_io/activate/A = k
		if(A.linked.len)
			to_chat(user, "The '[A]' is connected to [A.get_linked_to_desc()].")
	any_examine(user)
	interact(user)

/obj/item/integrated_circuit/proc/external_examine(mob/user)
	return (any_examine(user))

/obj/item/integrated_circuit/proc/any_examine(mob/user)
	return

/obj/item/integrated_circuit/attack_hand(mob/user, act_intent, attackchain_flags)
	if(!assembly)
		. = ..()

/obj/item/integrated_circuit/proc/attackby_react(var/atom/movable/A,mob/user)
	return

/obj/item/integrated_circuit/proc/sense(var/atom/movable/A,mob/user,prox)
	return

/obj/item/integrated_circuit/proc/check_interactivity(mob/user)
	if(assembly)
		return assembly.check_interactivity(user)
	else
		return user.canUseTopic(src, BE_CLOSE)

/obj/item/integrated_circuit/Initialize(mapload)
	displayed_name = name
	setup_io(inputs, /datum/integrated_io, inputs_default, IC_INPUT)
	setup_io(outputs, /datum/integrated_io, outputs_default, IC_OUTPUT)
	setup_io(activators, /datum/integrated_io/activate, null, IC_ACTIVATOR)
	LAZYSET(custom_materials, /datum/material/iron, w_class * SScircuit.cost_multiplier)
	. = ..()

/obj/item/integrated_circuit/proc/on_data_written()
	return

/obj/item/integrated_circuit/Destroy()
	QDEL_LIST(inputs)
	QDEL_LIST(outputs)
	QDEL_LIST(activators)
	. = ..()

/obj/item/integrated_circuit/emp_act(severity)
	for(var/k in inputs)
		var/datum/integrated_io/I = k
		I.scramble()
	for(var/k in outputs)
		var/datum/integrated_io/O = k
		O.scramble()
	for(var/k in activators)
		var/datum/integrated_io/activate/A = k
		A.scramble()

/obj/item/integrated_circuit/verb/rename_component()
	set name = "Rename Circuit"
	set category = "Object"
	set desc = "Rename your circuit, useful to stay organized."

	var/mob/M = usr
	if(!check_interactivity(M))
		return

	var/input = reject_bad_name(stripped_input(M, "What do you want to name this?", "Rename", name), TRUE)
	if(check_interactivity(M))
		if(!input)
			input = name
		to_chat(M, "<span class='notice'>The circuit '[name]' is now labeled '[input]'.</span>")
		displayed_name = input

/obj/item/integrated_circuit/interact(mob/user)
	ui_interact(user)

/obj/item/integrated_circuit/ui_interact(mob/user)
	. = ..()
	if(!check_interactivity(user))
		return

	if(assembly)
		assembly.ui_interact(user, src)
		return

	// Убираем старый HTML-интерфейс, оставляем только вызов родительского (если нужно)
	// Можно полностью удалить, так как теперь используется TGUI через assembly.
	// Но для одиночных компонентов вне сборки можно оставить старый или тоже перевести на TGUI.
	// Для простоты оставим заглушку.
	to_chat(user, "<span class='notice'>Component inspected outside assembly. Use debugger tools to interact.</span>")

/obj/item/integrated_circuit/Topic(href, href_list)
	if(!check_interactivity(usr))
		return
	if(..())
		return TRUE

	// Устаревший Topic больше не нужен, но оставим для обратной совместимости?
	// Можно удалить полностью, так как взаимодействие идёт через assembly.
	// Для безопасности оставим пустым или с заглушкой.
	return

/obj/item/integrated_circuit/proc/push_data()
	for(var/k in outputs)
		var/datum/integrated_io/O = k
		O.push_data()

/obj/item/integrated_circuit/proc/pull_data()
	for(var/k in inputs)
		var/datum/integrated_io/I = k
		I.push_data()

/obj/item/integrated_circuit/proc/draw_idle_power()
	if(assembly)
		return assembly.draw_power(power_draw_idle)

/obj/item/integrated_circuit/proc/power_fail()
	return

/obj/item/integrated_circuit/proc/check_power()
	if(!assembly)
		return FALSE
	if(assembly.draw_power(power_draw_per_use))
		return TRUE
	return FALSE

/obj/item/integrated_circuit/proc/check_then_do_work(ord,var/ignore_power = FALSE)
	if(world.time < next_use)
		return FALSE
	if(assembly && ext_cooldown && (world.time < assembly.ext_next_use))
		return FALSE
	if(power_draw_per_use && !ignore_power)
		if(!check_power())
			power_fail()
			return FALSE
	next_use = world.time + cooldown_per_use
	if(assembly)
		assembly.ext_next_use = world.time + ext_cooldown
	do_work(ord)
	return TRUE

/obj/item/integrated_circuit/proc/do_work(ord)
	return

/obj/item/integrated_circuit/proc/disconnect_all()
	var/datum/integrated_io/I
	for(var/i in inputs)
		I = i
		I.disconnect_all()
	for(var/i in outputs)
		I = i
		I.disconnect_all()
	for(var/i in activators)
		I = i
		I.disconnect_all()

/obj/item/integrated_circuit/proc/ext_moved(oldLoc, dir)
	return

/obj/item/integrated_circuit/proc/get_object()
	if(assembly)
		return assembly.get_object()
	else
		return src

/obj/item/integrated_circuit/drop_location()
	if(assembly)
		return assembly.drop_location()
	else
		return ..()

/obj/item/integrated_circuit/proc/check_target(atom/target, exclude_contents = FALSE, exclude_components = FALSE, exclude_self = FALSE, exclude_outside = FALSE)
	if(!target)
		return FALSE

	var/atom/movable/acting_object = get_object()

	if(exclude_self && target == acting_object)
		return FALSE

	if(exclude_components && assembly)
		if(target in assembly.assembly_components)
			return FALSE
		if(target == assembly.battery)
			return FALSE

	if(!exclude_outside && target.Adjacent(acting_object) && isturf(target.loc))
		return TRUE

	if(!exclude_contents && (target in acting_object.GetAllContents()))
		return TRUE

	if(target in acting_object.loc)
		return TRUE

	return FALSE

/obj/item/integrated_circuit/can_trigger_gun(mob/living/user)
	if(!user.is_holding(src))
		return FALSE
	return ..()

// Добавляем процедуру для обработки действия из интерфейса (если не определена)
/obj/item/integrated_circuit/proc/ui_perform_action(mob/user, action_name)
	return
