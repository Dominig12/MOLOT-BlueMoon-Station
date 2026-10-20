/proc/netrun_manual_text()
	return {"СЕТЕВОЙ ТЕРМИНАЛ — КРАТКАЯ СПРАВКА

Станция разбита на локальные сети (ЛВС) по отделам. Все они связаны магистралью NTnet,
которая работает, пока жив хотя бы один квантовый ретранслятор.

УРОВНИ ДОСТУПА: НЕТ, ГОСТЬ, ПОЛЬЗОВАТЕЛЬ, ROOT.
Ваш ID-карта даёт легальный доступ: к ЛВС своего отдела и к машинам, которые она открывает.
Доступ сетевого администратора (Network Access) или капитана даёт ROOT.

КЛЮЧИ ЛВС выпускаются командой «Выпустить ключ ЛВС» и дают доступ пользователя ко всей сети —
например, для интегральных схем. Храните их как пароли.

ТРАССИРОВКА: система защиты отслеживает действия без авторизации. Если к вам подключается
кто-то посторонний — смотрите журнал сети, перезагружайте узлы и выполняйте «Очистку».

Командная строка: help."}

// MARK: Сетевой терминал

/obj/machinery/computer/netrun_terminal
	name = "network terminal"
	desc = "Проводной терминал локальной сети. Показывает топологию, узлы и журналы; с нужным доступом - управляет ими."
	icon_screen = "comm_logs"
	icon_keyboard = "tech_key"
	circuit = /obj/item/circuitboard/computer/netrun_terminal
	light_color = "#4a9eff"
	var/datum/netrun_console/console

/obj/machinery/computer/netrun_terminal/Initialize(mapload, obj/item/circuitboard/C)
	. = ..()
	console = new(src, NETRUN_ORIGIN_TERMINAL)
	console.wireless = FALSE
	console.storage_capacity = 12
	console.tgui_title = "Сетевой терминал"
	console.store_file(new /datum/netrun_file("readme.txt", NETRUN_FILE_TEXT, netrun_manual_text()))
	AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL, list("purge", "issue_key"), 2, list(ACCESS_NETWORK), 12)

/obj/machinery/computer/netrun_terminal/Destroy()
	QDEL_NULL(console)
	return ..()

/obj/machinery/computer/netrun_terminal/ui_interact(mob/user, datum/tgui/ui)
	if(!is_operational())
		return
	console.ui_interact(user, ui)

/obj/machinery/computer/netrun_terminal/attackby(obj/item/I, mob/living/user, params)
	if(istype(I, /obj/item/netrun_shard))
		console.insert_shard(I, user)
		return TRUE
	return ..()

/obj/machinery/computer/netrun_terminal/netrun_traced(datum/netrun_console/traced)
	playsound(src, 'sound/machines/buzz-sigh.ogg', 50, TRUE)
	say("Сеанс прерван системой защиты сети.")

/obj/item/circuitboard/computer/netrun_terminal
	name = "Network Terminal (Computer Board)"
	icon_state = "engineering"
	build_path = /obj/machinery/computer/netrun_terminal

// MARK: Сервер данных

/obj/machinery/netrun_server
	name = "data server"
	desc = "Стойка хранения данных локальной сети. В ней хранят журналы, ключи и всё, что не должно попасть в чужие руки."
	icon = 'icons/obj/machines/research.dmi'
	icon_state = "server"
	density = TRUE
	use_power = IDLE_POWER_USE
	idle_power_usage = 200
	circuit = /obj/item/circuitboard/machine/netrun_server
	/// Файлы, которые лежат на сервере с самого начала
	var/list/preload_files

/obj/machinery/netrun_server/Initialize(mapload)
	. = ..()
	var/capacity = 40
	for(var/obj/item/stock_parts/matter_bin/bin in component_parts)
		capacity += bin.rating * 10
	var/datum/component/netrun_node/node = AddComponent(/datum/component/netrun_node, NETRUN_NODE_SERVER, list("purge", "issue_key", "reboot"), 2, list(ACCESS_NETWORK), capacity)
	for(var/file_name in preload_files)
		node.files += new /datum/netrun_file(file_name, NETRUN_FILE_TEXT, preload_files[file_name])

/obj/machinery/netrun_server/netrun_status()
	var/datum/component/netrun_node/node = GetComponent(/datum/component/netrun_node)
	. = list("Хранилище: [node.used_storage()] / [node.storage_capacity]")

/obj/machinery/netrun_server/examine(mob/user)
	. = ..()
	var/datum/component/netrun_node/node = GetComponent(/datum/component/netrun_node)
	if(node)
		. += span_notice("Сетевой адрес: [node.address][node.network ? " ([node.network.short_name])" : ""].")

/obj/machinery/netrun_server/attackby(obj/item/I, mob/living/user, params)
	if(default_deconstruction_screwdriver(user, "server", "server", I))
		return TRUE
	if(default_deconstruction_crowbar(I))
		return TRUE
	return ..()

/obj/item/circuitboard/machine/netrun_server
	name = "Data Server (Machine Board)"
	icon_state = "science"
	build_path = /obj/machinery/netrun_server
	req_components = list(
		/obj/item/stack/cable_coil = 2,
		/obj/item/stock_parts/matter_bin = 2,
		/obj/item/stock_parts/subspace/filter = 1)
