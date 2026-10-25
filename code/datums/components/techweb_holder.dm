/datum/component/techweb_holder
	var/datum/techweb/linked_techweb
	/// Once an authority has been selected, its loss requires an explicit rebind.
	var/had_authority = FALSE

/datum/component/techweb_holder/Initialize(...)
	. = ..()
	RegisterSignal(parent, COMSIG_ATOM_TOOL_ACT(TOOL_MULTITOOL), PROC_REF(on_multitool_act))
	RegisterSignal(parent, COMSIG_ATOM_GET_TECHWEB, PROC_REF(GetTechWeb))
	RegisterSignal(parent, COMSIG_ATOM_SET_TECHWEB, PROC_REF(on_set_techweb))

/datum/component/techweb_holder/Destroy(force, silent)
	if(linked_techweb)
		UnregisterSignal(linked_techweb, COMSIG_PARENT_QDELETING)
	. = ..()
	linked_techweb = null

/datum/component/techweb_holder/proc/on_set_techweb(datum/source, datum/techweb/new_web)
	SIGNAL_HANDLER
	if(QDELETED(new_web))
		new_web = null
	// A server's disk is physical memory, never a replica of another server.
	if(istype(parent, /obj/machinery/rnd/server) && new_web)
		var/datum/techweb/proposed = new_web
		if(proposed.research_owner_ref?.resolve() != parent)
			return
	if(linked_techweb == new_web)
		return
	if(linked_techweb)
		UnregisterSignal(linked_techweb, COMSIG_PARENT_QDELETING)
	linked_techweb = new_web
	if(linked_techweb)
		had_authority = TRUE
		RegisterSignal(linked_techweb, COMSIG_PARENT_QDELETING, PROC_REF(research_deleted))
	SEND_SIGNAL(parent, COMSIG_ATOM_TECHWEB_CHANGED, linked_techweb)

/datum/component/techweb_holder/proc/research_deleted(datum/source)
	SIGNAL_HANDLER
	on_set_techweb(parent, null)

/datum/component/techweb_holder/proc/on_multitool_act(datum/source, mob/living/user, obj/item/I, list/mutable_recipes)
	SIGNAL_HANDLER
	var/obj/item/multitool/tool = I
	if(istype(tool.buffer, /datum/techweb))
		var/datum/techweb/new_web = tool.buffer
		if(new_web == linked_techweb)
			to_chat(user, span_notice("Объект уже подключён к [new_web.organization]."))
			return TRUE
		on_set_techweb(parent, new_web)
		to_chat(user, linked_techweb == new_web ? span_notice("Вы подключаете объект к [new_web.organization].") : span_warning("Сервер хранит собственную исследовательскую сеть и не принимает чужую привязку."))
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

	return QDELETED(linked_techweb) ? null : linked_techweb
