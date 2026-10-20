/// Сетевой мост для интегральных схем: команды узлам по ключу ЛВС. Взламывать не умеет.
/obj/item/integrated_circuit/input/netrun_link
	name = "network node uplink"
	desc = "Отправляет команды узлам локальных сетей станции. Нужен ключ ЛВС - его выпускает сетевой терминал."
	extended_desc = "Адрес узла в формате XXXX:XXXX, id команды (например door_open, apc_breaker, cam_toggle) и ключ ЛВС. \
	Без ключа схема работает только на гостевых командах вроде scan. Результат выполнения - на первом выходе."
	icon_state = "signal"
	complexity = 6
	cooldown_per_use = 2 SECONDS
	inputs = list(
		"node address" = IC_PINTYPE_STRING,
		"command" = IC_PINTYPE_STRING,
		"network key" = IC_PINTYPE_STRING,
	)
	outputs = list(
		"result" = IC_PINTYPE_STRING,
		"node name" = IC_PINTYPE_STRING,
	)
	activators = list(
		"execute" = IC_PINTYPE_PULSE_IN,
		"on success" = IC_PINTYPE_PULSE_OUT,
		"on failure" = IC_PINTYPE_PULSE_OUT,
	)
	spawn_flags = IC_SPAWN_RESEARCH
	action_flags = IC_ACTION_LONG_RANGE
	power_draw_per_use = 60
	var/datum/netrun_console/circuit/console

/obj/item/integrated_circuit/input/netrun_link/Initialize(mapload)
	. = ..()
	console = new(src, NETRUN_ORIGIN_CIRCUIT)

/obj/item/integrated_circuit/input/netrun_link/Destroy()
	QDEL_NULL(console)
	return ..()

/obj/item/integrated_circuit/input/netrun_link/do_work()
	var/datum/component/netrun_node/node = SSnetrun.find_node(get_pin_data(IC_INPUT, 1))
	var/command_id = lowertext(trim("[get_pin_data(IC_INPUT, 2)]"))
	QDEL_LIST(console.storage)
	if(node?.network)
		var/key = "[get_pin_data(IC_INPUT, 3)]"
		if(length(key))
			console.storage += new /datum/netrun_file("key", NETRUN_FILE_KEY, uppertext(trim(key)), 1, node.network.id)
	console.log.Cut()
	var/success = node && console.run_command(node, command_id)
	var/list/last = length(console.log) ? console.log[length(console.log)] : null
	set_pin_data(IC_OUTPUT, 1, last ? last["text"] : "Узел не найден.")
	set_pin_data(IC_OUTPUT, 2, node ? node.get_name() : null)
	push_data()
	activate_pin(success ? 2 : 3)

/datum/netrun_console/circuit
	name = "сетевой мост"
	origin = NETRUN_ORIGIN_CIRCUIT
	can_breach = FALSE
	storage_capacity = 1

/datum/netrun_console/circuit/New(atom/host, origin)
	. = ..()
	SSnetrun.consoles -= src // схеме не нужна трассировка по таймеру

/datum/netrun_console/circuit/home_networks()
	. = list()
	var/lan = netrun_lan_for_turf(get_turf(host))
	if(lan)
		. += SSnetrun.get_network(lan)

/datum/netrun_console/circuit/user_access()
	return list()

/datum/netrun_console/circuit/log_source()
	return "интегральная схема"

/datum/netrun_console/circuit/run_command(datum/component/netrun_node/node, command_id)
	// Схема работает только легально: без нужного доступа команда просто не выполняется
	var/datum/netrun_command/command = SSnetrun.get_command(command_id)
	if(command && node && legit_node_level(node) < command.access)
		log_line("Недостаточно прав: нужен ключ ЛВС.", "bad")
		return FALSE
	next_command = 0
	return ..()

/datum/netrun_console/circuit/log_line(text, kind)
	log += list(list("text" = text, "kind" = kind))

/datum/netrun_console/circuit/add_trace(amount)
	return
