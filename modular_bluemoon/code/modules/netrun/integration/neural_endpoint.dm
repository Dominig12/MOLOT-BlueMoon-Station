/// A neural display has its own address; the carrier's cybernetics remain a separate node.
/datum/component/neural_interface/RegisterWithParent()
	. = ..()
	AddComponent(/datum/component/netrun_neural_adapter)

/// Lifecycle adapter, attached to the interface datum rather than the wearer.
/datum/component/netrun_neural_adapter
	var/datum/component/neural_interface/interface
	var/obj/effect/netrun_endpoint/neural/endpoint

/datum/component/netrun_neural_adapter/Initialize()
	if(!istype(parent, /datum/component/neural_interface))
		return COMPONENT_INCOMPATIBLE
	interface = parent
	if(!interface.host_mob)
		return COMPONENT_INCOMPATIBLE
	endpoint = new(interface.host_mob, interface)

/datum/component/netrun_neural_adapter/Destroy()
	QDEL_NULL(endpoint)
	interface = null
	return ..()

/// Invisible addressable service carried by its owner, never a second component on the mob.
/obj/effect/netrun_endpoint
	name = "network endpoint"
	invisibility = INVISIBILITY_ABSTRACT
	mouse_opacity = MOUSE_OPACITY_TRANSPARENT

/obj/effect/netrun_endpoint/neural
	name = "neural interface endpoint"
	var/datum/component/neural_interface/interface

/obj/effect/netrun_endpoint/neural/Initialize(mapload, datum/component/neural_interface/interface)
	. = ..()
	src.interface = interface
	AddComponent(/datum/component/netrun_node, NETRUN_NODE_NEURAL, list("neural_status", "neural_notify", "neural_data", "neural_mark", "neural_toggle"), 3, list())

/obj/effect/netrun_endpoint/neural/Destroy()
	interface = null
	return ..()

/obj/effect/netrun_endpoint/neural/netrun_name()
	return "[interface?.host_mob?.name || "неизвестно"] — нейроинтерфейс"

/obj/effect/netrun_endpoint/neural/netrun_online(remote = TRUE)
	return !QDELETED(interface) && interface.host_mob && interface.host_mob.netrun_online(remote)

/obj/effect/netrun_endpoint/neural/netrun_status()
	if(QDELETED(interface))
		return list("Нейроинтерфейс отключён.")
	return list("Носитель: [interface.host_mob.name]", "Экран: [interface.visible ? "включён" : "выключен"]", "Модулей: [length(interface.modules)], мониторов: [length(interface.monitors)]")

/obj/effect/netrun_endpoint/neural/netrun_owner_access(datum/netrun_console/console)
	if(QDELETED(interface))
		return NETRUN_ACCESS_NONE
	return netrun_console_owner(console) == interface.host_mob ? NETRUN_ACCESS_ROOT : NETRUN_ACCESS_NONE

/datum/netrun_command/neural
	access = NETRUN_ACCESS_USER
	icon = "brain"

/datum/netrun_command/neural/proc/get_interface(datum/component/netrun_node/node)
	var/obj/effect/netrun_endpoint/neural/endpoint = node.parent
	if(istype(endpoint) && !QDELETED(endpoint.interface))
		return endpoint.interface

/datum/netrun_command/neural/status
	id = "neural_status"
	name = "Состояние интерфейса"
	desc = "Получить список модулей и источников нейроинтерфейса."
	trace = 2

/datum/netrun_command/neural/status/execute(datum/component/netrun_node/node, datum/netrun_console/console, arg)
	var/datum/component/neural_interface/interface = get_interface(node)
	if(!interface)
		return
	return "Модули: [jointext(interface.modules, ", ")].\nИсточники: [jointext(interface.sources, ", ")]."

/datum/netrun_command/neural/notify
	id = "neural_notify"
	name = "Послать уведомление"
	desc = "Отправить выбранный локальный текстовый файл в журнал нейроинтерфейса (до 160 символов)."
	trace = 4

/datum/netrun_command/neural/notify/execute(datum/component/netrun_node/node, datum/netrun_console/console, arg, datum/netrun_request/request)
	var/datum/component/neural_interface/interface = get_interface(node)
	var/datum/netrun_file/file = console.selected_local_file(NETRUN_FILE_TEXT, request)
	if(!interface)
		return
	if(!file)
		console.log_line("Выберите локальный текстовый файл для отправки.", "bad")
		return
	SEND_SIGNAL(interface, COMSIG_NEURAL_INTERFACE_WRITE_LOG, html_encode(copytext_char(file.content, 1, 161)), "DATA")
	return "Уведомление доставлено: [file.name]."

/datum/netrun_command/neural/data
	id = "neural_data"
	name = "Передать данные на экран"
	desc = "Показать выбранный локальный текстовый файл в панели данных на 10 секунд."
	trace = 4

/datum/netrun_command/neural/data/execute(datum/component/netrun_node/node, datum/netrun_console/console, arg, datum/netrun_request/request)
	var/datum/component/neural_interface/interface = get_interface(node)
	var/datum/netrun_file/file = console.selected_local_file(NETRUN_FILE_TEXT, request)
	if(!interface)
		return
	if(!file)
		console.log_line("Выберите локальный текстовый файл для отправки.", "bad")
		return
	SEND_SIGNAL(interface, COMSIG_NEURAL_INTERFACE_WRITE_DATA, "NET:[html_encode(file.name)]", html_encode(copytext_char(file.content, 1, 257)), 10 SECONDS)
	return "Данные доставлены: [file.name]."

/datum/netrun_command/neural/mark
	id = "neural_mark"
	name = "Отметить источник связи"
	desc = "Показать на 10 секунд отметку источника отправляющей консоли через штатный модуль подсветки."
	trace = 4

/datum/netrun_command/neural/mark/execute(datum/component/netrun_node/node, datum/netrun_console/console, arg)
	var/datum/component/neural_interface/interface = get_interface(node)
	if(!interface)
		return
	var/atom/target = console.host
	if(istype(target, /mob/camera/netrun_entity))
		var/mob/camera/netrun_entity/entity = target
		target = entity.host_node?.parent
	else if(istype(target, /obj/item/organ))
		var/obj/item/organ/organ = target
		target = organ.owner
	if(!target || !get_turf(target))
		return
	var/image/marker = image('icons/effects/neural_interface_overlays.dmi', icon_state = "circle")
	marker.color = "#4ac0ff"
	SEND_SIGNAL(interface, COMSIG_NEURAL_INTERFACE_WRITE_IMAGE_DATA, "NET:[REF(console)]", marker, target, html_encode(target.name), 10 SECONDS)
	return "Источник связи отмечен на нейроинтерфейсе."

/datum/netrun_command/neural/toggle
	id = "neural_toggle"
	name = "Переключить экран"
	desc = "Включить или выключить отображение нейроинтерфейса."
	access = NETRUN_ACCESS_ROOT
	trace = 8
	danger = TRUE

/datum/netrun_command/neural/toggle/execute(datum/component/netrun_node/node, datum/netrun_console/console, arg)
	var/datum/component/neural_interface/interface = get_interface(node)
	if(!interface)
		return
	if(interface.visible)
		interface.hide()
	else
		interface.show()
	SEND_SIGNAL(interface, COMSIG_NEURAL_INTERFACE_WRITE_LOG, "Удалённая команда: экран [interface.visible ? "включён" : "выключен"].", "WARNING")
	return "Экран нейроинтерфейса [interface.visible ? "включён" : "выключен"]."
