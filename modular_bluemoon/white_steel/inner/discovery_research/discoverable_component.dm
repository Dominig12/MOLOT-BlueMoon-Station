/datum/component/discoverable
	dupe_mode = COMPONENT_DUPE_UNIQUE
	//Amount of discovery points awarded when researched.
	var/scanned = FALSE
	var/unique = FALSE
	var/point_reward = 0

/datum/component/discoverable/Initialize(_point_reward, _unique = FALSE)
	if(!isatom(parent))
		return COMPONENT_INCOMPATIBLE

	RegisterSignal(parent, COMSIG_PARENT_EXAMINE, .proc/examine)
	RegisterSignal(parent, COMSIG_CLICK, .proc/tryScan)

	point_reward = _point_reward
	unique = _unique

/datum/component/discoverable/proc/tryScan(datum/source, location, control, params, mob/user)
	SIGNAL_HANDLER
	if(!isliving(user))
		return
	var/mob/living/L = user
	if(istype(L.get_active_held_item(), /obj/item/discovery_scanner))
		INVOKE_ASYNC(L.get_active_held_item(), /obj/item/discovery_scanner.proc/begin_scanning, user, src)

/datum/component/discoverable/proc/examine(datum/source, mob/user, atom/thing)
	SIGNAL_HANDLER
	if(!HAS_TRAIT(user, TRAIT_RESEARCH_SCANNER))
		return
	to_chat(user, span_notice("Научная ценность обнаружена."))
	to_chat(user, span_notice("Сканирование: [scanned ? "Истина" : "Ложь"]."))
	to_chat(user, span_notice("Награда: [point_reward]."))

/datum/component/discoverable/proc/discovery_scan(obj/item/discovery_scanner/scanner, mob/living/user)
	var/atom/object = parent
	if(scanned || !scanner || !user || !object)
		return FALSE
	var/datum/component/techweb_holder/holder = scanner.GetComponent(/datum/component/techweb_holder)
	if(!holder?.request_discovery(src, user))
		to_chat(user, span_warning("Исследовательский сервер недоступен. Объект не отмечен изученным."))
		return FALSE
	to_chat(user, span_notice("Данные [object] отправлены исследовательскому серверу."))
	return TRUE
