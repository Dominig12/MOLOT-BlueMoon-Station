/// Lines kept on a terminal's screen; older ones scroll away.
#define NETDM_TERMINAL_LINES 40
/// Longest line the shell takes.
#define NETDM_TERMINAL_LINE_LENGTH 1024
/// Longest source accepted by run_script.
#define NETDM_TERMINAL_SCRIPT_LENGTH 2048
/// Records shown for one line; the shell itself answers at most 64.
#define NETDM_TERMINAL_ROWS 64
/// Lines and queries waiting for the network at once.
#define NETDM_TERMINAL_PENDING 32
/// A line without an answer for this long shows as unanswered.
#define NETDM_TERMINAL_TIMEOUT (10 SECONDS)

/// Source code for the v1 shell, kept in the standard removable drive filesystem.
/datum/computer_file/data/netdm_script
	filename = "netdm"
	filetype = "NDS1"

/**
 * network.shell (design 14.6): one line of the network shell, run by an APC for a network node.
 *
 * The line is a pipeline over typed records (services, links, self, trace, then where, select, sort, first,
 * last, count) and may end in invoke. It travels to the APC as a network command and the records come back
 * over the network; invoke sends ordinary commands as the asker. on_output receives the shell.output DTO
 * with "records" parsed into a list of field lists, or the status "no_answer" or "refused".
 * Returns FALSE when the line cannot even be queued.
 */
/datum/netdm_diagnostics/proc/run_line(datum/asker, datum/provider, line, datum/callback/on_output, datum/callback/can_send)
	return queue_shell(asker, provider, "run", "line", line, NETDM_TERMINAL_LINE_LENGTH, on_output, can_send)

/datum/netdm_diagnostics/proc/run_script(datum/asker, datum/provider, source, datum/callback/on_output, datum/callback/can_send)
	return queue_shell(asker, provider, "run_script", "source", source, NETDM_TERMINAL_SCRIPT_LENGTH, on_output, can_send)

/datum/netdm_diagnostics/proc/queue_shell(datum/asker, datum/provider, command, argument, source, max_length, datum/callback/on_output, datum/callback/can_send)
	if(!istext(source) || !length(source) || length_char(source) > max_length)
		return FALSE
	var/list/arguments = list()
	arguments[argument] = source
	return queue_shell_request(asker, provider, command, arguments, on_output, can_send)

/datum/netdm_diagnostics/proc/queue_shell_request(datum/asker, datum/provider, command, list/arguments, datum/callback/on_output, datum/callback/can_send)
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	if(!lane || QDELETED(asker) || QDELETED(provider) || !on_output)
		return FALSE
	var/local_shell = istype(provider, /datum/component/netdm_node)
	if(length(queries) >= NETDM_TERMINAL_PENDING || (local_shell ? (asker != provider || !can_send) : !lane.node_id(provider)))
		return FALSE
	var/datum/netdm_service_endpoint/endpoint = lane.endpoint_for(provider)
	if(!endpoint)
		return FALSE
	var/instance = "netshell.[endpoint.id]"
	if(!endpoint.services[instance])
		lane.offer(provider, instance, "network.shell", "shell.output", 1, scope = local_shell ? "none" : "domain")
	counters["lines"] = (counters["lines"] || 0) + 1
	queries["sh-[++serial]"] = list("asker" = WEAKREF(asker), "provider" = WEAKREF(provider), "instance" = instance, "command" = command,
		"arguments" = arguments, "callback" = CALLBACK(src, PROC_REF(line_answered), on_output),
		"deadline" = world.time + NETDM_TERMINAL_TIMEOUT, "sent" = FALSE, "may_act" = TRUE, "can_send" = can_send)
	return TRUE

/// The shell's answer: "rows" as name=value,name=value;… becomes a list of records in field order.
/datum/netdm_diagnostics/proc/line_answered(datum/callback/on_output, list/output)
	var/list/records = list()
	for(var/row in splittext("[output?["rows"]]", ";"))
		if(!length(row))
			continue
		var/list/fields = list()
		for(var/pair in splittext(row, ","))
			var/split = findtext(pair, "=")
			if(split > 1)
				fields += list(list("name" = copytext(pair, 1, split), "value" = copytext(pair, split + 1)))
		records += list(fields)
		if(length(records) >= NETDM_TERMINAL_ROWS)
			break
	var/list/answer = islist(output) ? output.Copy() : list("status" = "no_answer")
	if(answer["program"])
		records += list(list(list("name" = "program", "value" = "[answer["program"]]"), list("name" = "status", "value" = answer["status"])))
	answer["records"] = records
	on_output.Invoke(answer)

/// A multitool on a closed APC opens the terminal of its network module. TRUE when the click was taken.
/datum/netdm_diagnostics/proc/open_terminal(obj/machinery/power/apc/apc, mob/user)
	if(!SSnetdm_observe.services || !SSnetdm_observe.published || !user)
		return FALSE
	if(!SSnetdm_observe.apc_node_id(apc))
		tell(user, span_warning("Сетевой модуль этого АПЦ не входит в карту сети."))
		return TRUE
	if(apc.netdm_state() != NETDM_STATE_UP)
		tell(user, span_warning("Сетевой модуль АПЦ не отвечает: нет питания или неисправен."))
		return TRUE
	var/datum/netdm_terminal/terminal = new(apc)
	terminal.ui_interact(user)
	return TRUE

/// A terminal runs lines and scripts at its own endpoint. The UI host is the device the user operates.
/datum/netdm_terminal
	var/datum/weakref/device_ref
	var/datum/weakref/node_ref
	/// Screen, oldest first: list("id", "line", "status", "error", "position", "fuel", "records", "pending").
	var/list/entries = list()
	var/serial = 0
	var/disk_notice
	var/list/loaded_script

/datum/netdm_terminal/New(atom/device, datum/node = device)
	device_ref = WEAKREF(device)
	node_ref = WEAKREF(node)
	submit("self")
	if(device == node)
		submit("links")

/datum/netdm_terminal/ui_host(mob/user)
	return device_ref?.resolve() || src

/datum/netdm_terminal/ui_state(mob/user)
	return GLOB.physical_state

/datum/netdm_terminal/ui_interact(mob/user, datum/tgui/ui)
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new(user, src, "NetdmTerminal")
		ui.open()

/datum/netdm_terminal/ui_close(mob/user)
	qdel(src)

/datum/netdm_terminal/ui_data(mob/user)
	var/atom/device = device_ref?.resolve()
	var/obj/item/computer_hardware/hard_drive/portable/disk = held_script_disk(user)
	var/datum/computer_file/data/netdm_script/file = script_file(disk)
	var/list/media = disk ? list("id" = REF(disk), "name" = disk.name, "file" = file ? REF(file) : "") : null
	return list("title" = device ? device_title(device) : "нет связи", "entries" = entries,
		"limit" = NETDM_TERMINAL_LINE_LENGTH, "scriptLimit" = NETDM_TERMINAL_SCRIPT_LENGTH,
		"disk" = media, "diskNotice" = disk_notice, "loadedScript" = loaded_script, "programsEnabled" = supports_programs(),
		"kept" = supports_programs() ? kept_names() : null)

/datum/netdm_terminal/proc/device_title(atom/device)
	return get_area_name(device, TRUE)

/datum/netdm_terminal/ui_act(action, list/params, datum/tgui/ui, datum/ui_state/state)
	. = ..()
	if(.)
		return
	switch(action)
		if("run")
			return submit(trim("[params["line"]]"))
		if("run_script")
			return submit(params["source"], TRUE)
		if("start_program")
			return start_program(params["name"], params["source"], !!params["keep"])
		if("forget_program")
			return forget_program(params["name"])
		if("list_programs")
			return submit("programs")
		if("stop_program")
			return stop_program(params["program"])
		if("save_disk", "load_disk", "run_disk")
			return script_disk_action(ui.user, action, params["disk"], params["file"], params["source"])
		if("clear")
			entries.Cut()
			return TRUE

/// Resolve media from the user's hands on each action. The browser only identifies the disk it displayed.
/datum/netdm_terminal/proc/held_script_disk(mob/user)
	var/obj/item/held = user?.get_active_held_item()
	if(istype(held, /obj/item/computer_hardware/hard_drive/portable) && !QDELETED(held))
		return held
	held = user?.get_inactive_held_item()
	if(istype(held, /obj/item/computer_hardware/hard_drive/portable) && !QDELETED(held))
		return held
	return null

/datum/netdm_terminal/proc/script_file(obj/item/computer_hardware/hard_drive/portable/disk)
	for(var/datum/computer_file/data/netdm_script/file in disk?.stored_files)
		if(file.filename == "netdm" && file.filetype == "NDS1")
			return file
	return null

/datum/netdm_terminal/proc/script_disk_action(mob/user, action, disk_id, file_id, source)
	var/obj/item/computer_hardware/hard_drive/portable/disk = held_script_disk(user)
	var/datum/computer_file/data/netdm_script/file = script_file(disk)
	if(!disk || disk_id != REF(disk) || file_id != (file ? REF(file) : ""))
		disk_notice = "Диск или файл сменился. Выбери действие ещё раз."
		return TRUE
	if(action == "save_disk")
		disk_notice = save_script(disk, file, source)
		return TRUE
	if(!file || !disk.check_functionality() || !valid_source(file.stored_data, NETDM_TERMINAL_SCRIPT_LENGTH))
		disk_notice = "Не удалось прочитать netdm.NDS1."
		return TRUE
	if(action == "load_disk")
		loaded_script = list("id" = ++serial, "source" = file.stored_data)
		disk_notice = "netdm.NDS1 загружен в редактор."
	else if(action == "run_disk")
		disk_notice = submit(file.stored_data, TRUE) ? null : "Не удалось запустить netdm.NDS1."
	return TRUE

/datum/netdm_terminal/proc/save_script(obj/item/computer_hardware/hard_drive/portable/disk, datum/computer_file/data/netdm_script/file, source)
	if(!valid_source(source, NETDM_TERMINAL_SCRIPT_LENGTH))
		return "Скрипт пуст или превышает лимит."
	if(file)
		var/new_size = max(1, round(length(source) / file.block_size))
		if(file.undeletable || !disk.check_functionality() || disk.used_capacity - file.size + new_size > disk.max_capacity)
			return "Не удалось перезаписать netdm.NDS1."
		file.stored_data = source
		file.calculate_size()
		disk.recalculate_size()
	else
		file = new
		file.stored_data = source
		file.calculate_size()
		if(!disk.store_file(file))
			qdel(file)
			return "Не удалось записать netdm.NDS1. Проверь свободное место и состояние диска."
	return "netdm.NDS1 сохранён на диске."

/datum/netdm_terminal/proc/valid_source(source, max_length)
	return istext(source) && length_char(source) <= max_length && length(trim(source))

/// Puts a line or script on the screen and sends it; the answer fills the entry in.
/datum/netdm_terminal/proc/submit(line, script = FALSE)
	var/max_length = script ? NETDM_TERMINAL_SCRIPT_LENGTH : NETDM_TERMINAL_LINE_LENGTH
	if(!valid_source(line, max_length))
		return FALSE
	var/list/arguments = script ? list("source" = line) : list("line" = line)
	return submit_request(line, script ? "run_script" : "run", arguments)

/// keep: the program is also written to the device's media and comes back on every attach.
/datum/netdm_terminal/proc/start_program(name, source, keep = FALSE)
	if(!supports_programs() || !istext(name) || !length(name) || length_char(name) > 32 || !valid_source(source, NETDM_TERMINAL_SCRIPT_LENGTH))
		return FALSE
	var/list/arguments = list("name" = name, "source" = source)
	if(keep)
		var/error = keep_program(name, source)
		if(error)
			disk_notice = error
			return TRUE
		arguments["ensure"] = TRUE
		disk_notice = "[name] хранится на устройстве и запускается при каждом подключении."
	return submit_request("start [name]", "start", arguments)

/datum/netdm_terminal/proc/supports_programs()
	return TRUE

/datum/netdm_terminal/proc/stop_program(program)
	var/id = istext(program) ? text2num(program) : program
	if(!isnum(id) || id < 1 || id > 1000000000 || round(id) != id)
		return FALSE
	return submit_request("stop [id]", "stop", list("program" = id))

/datum/netdm_terminal/proc/submit_request(line, command, list/arguments)
	var/datum/node = node_ref?.resolve()
	var/datum/netdm_diagnostics/diagnostics = SSnetdm_observe.diagnostics
	if(!node || !diagnostics || !can_submit())
		return FALSE
	var/list/entry = list("id" = ++serial, "line" = line, "pending" = TRUE, "status" = null, "error" = null, "position" = null,
		"fuel" = null, "records" = list())
	entries += list(entry)
	if(length(entries) > NETDM_TERMINAL_LINES)
		entries.Cut(1, length(entries) - NETDM_TERMINAL_LINES + 1)
	var/datum/callback/on_output = CALLBACK(src, PROC_REF(answered), entry)
	var/datum/callback/can_send = send_guard()
	var/queued = diagnostics.queue_shell_request(node, node, command, arguments, on_output, can_send)
	if(!queued)
		entry["pending"] = FALSE
		entry["status"] = "refused"
		entry["error"] = "очередь занята"
	return TRUE

/datum/netdm_terminal/proc/can_submit()
	return TRUE

/datum/netdm_terminal/proc/send_guard()
	return null

/datum/netdm_terminal/proc/answered(list/entry, list/output)
	entry["pending"] = FALSE
	entry["status"] = output["status"]
	entry["error"] = output["error"] || output["reason"]
	entry["position"] = output["position"]
	entry["fuel"] = output["fuel"]
	entry["records"] = output["records"]
	SStgui.update_uis(src)

/datum/netdm_terminal/local
	var/datum/weakref/user_ref

/datum/netdm_terminal/local/New(atom/device, datum/component/netdm_node/node, mob/user)
	user_ref = WEAKREF(user)
	return ..(device, node)

/datum/netdm_terminal/local/ui_status(mob/user, datum/ui_state/state)
	return user == user_ref?.resolve() && can_submit() ? ..() : UI_CLOSE

/datum/netdm_terminal/local/device_title(atom/device)
	return device.name

/datum/netdm_terminal/local/can_submit()
	var/mob/living/user = user_ref?.resolve()
	return !QDELETED(src) && istype(user) && !user.stat && !user.incapacitated() && (user.mobility_flags & MOBILITY_UI)

/datum/netdm_terminal/local/send_guard()
	return CALLBACK(src, PROC_REF(can_submit))

/datum/netdm_terminal/local/pda/ui_state(mob/user)
	return GLOB.hands_state

/datum/netdm_terminal/local/pda/can_submit()
	var/obj/item/modular_computer/pda/pda = device_ref?.resolve()
	var/mob/user = user_ref?.resolve()
	return ..() && pda && user.is_holding(pda) && pda.netdm_terminal_powered()

/obj/item/modular_computer/pda/proc/netdm_terminal_powered()
	return screen_on && netdm_execution_powered()

/obj/item/modular_computer/pda/proc/netdm_execution_powered()
	return enabled && get_battery_percent() > 0

/obj/item/modular_computer/pda/proc/open_netdm_terminal(mob/user)
	if(!SSnetdm_observe?.services || GLOB.hands_state.can_use_topic(src, user) != UI_INTERACTIVE || !netdm_terminal_powered())
		return FALSE
	var/datum/component/netdm_node/node = GetComponent(/datum/component/netdm_node)
	if(!node)
		node = netdm_make_node(src, NETDM_MOUNT_MOBILE)
	if(!node)
		return FALSE
	var/datum/netdm_terminal/local/pda/terminal = new(src, node, user)
	terminal.ui_interact(user)
	return TRUE

/datum/netdm_terminal/local/implant/ui_host(mob/user)
	return user_ref?.resolve() || src

/datum/netdm_terminal/local/implant/ui_status(mob/user, datum/ui_state/state)
	return user == user_ref?.resolve() && can_submit() ? user.shared_ui_interaction(user) : UI_CLOSE

/datum/netdm_terminal/local/implant/can_submit()
	var/obj/item/implant/netdm_terminal/implant = device_ref?.resolve()
	return ..() && implant?.imp_in == user_ref?.resolve() && node_ref?.resolve()

/datum/action/item_action/hands_free/activate/netdm_terminal
	name = "Сетевой терминал"

/obj/item/implant/netdm_terminal
	name = "сетевой имплант"
	desc = "Встроенный радиотерминал для запуска сетевых команд и скриптов."
	actions_types = list(/datum/action/item_action/hands_free/activate/netdm_terminal)
	var/datum/component/netdm_node/node

/obj/item/implant/netdm_terminal/implant(mob/living/target, mob/user, silent = FALSE, force = FALSE)
	. = ..()
	if(. && !QDELETED(src) && imp_in == target && SSnetdm_observe?.observing())
		node = AddComponent(/datum/component/netdm_node/implant, NETDM_MOUNT_MOBILE)

/obj/item/implant/netdm_terminal/removed(mob/living/source, silent = FALSE, special = 0)
	QDEL_NULL(node)
	return ..()

/obj/item/implant/netdm_terminal/ui_action_click(mob/living/user)
	if(!user || user != imp_in || !node || user.shared_ui_interaction(user) != UI_INTERACTIVE)
		return
	var/datum/netdm_terminal/local/implant/terminal = new(src, node, user)
	terminal.ui_interact(user)

/obj/item/implantcase/netdm_terminal
	name = "футляр сетевого импланта"
	imp_type = /obj/item/implant/netdm_terminal

/obj/item/implanter/netdm_terminal
	name = "имплантер сетевого терминала"
	imp_type = /obj/item/implant/netdm_terminal

/datum/design/netdm_terminal_implant
	name = "Network Terminal Implant Case"
	id = "netdm_terminal_implant"
	build_type = PROTOLATHE
	materials = list(/datum/material/glass = 1000, /datum/material/gold = 500)
	build_path = /obj/item/implantcase/netdm_terminal
	category = list("Implants")
	departmental_flags = DEPARTMENTAL_FLAG_MEDICAL | DEPARTMENTAL_FLAG_SCIENCE

/obj/item/netdm_adapter
	name = "проводной сетевой адаптер"
	desc = "Подключается к АПЦ или открытому сервисному порту закреплённого сетевого устройства. Нажми на подключённый адаптер, чтобы открыть терминал, или Alt+ЛКМ, чтобы отсоединить."
	icon = 'icons/obj/device.dmi'
	icon_state = "multitool"
	w_class = WEIGHT_CLASS_SMALL
	force = 0
	var/datum/weakref/dock_ref
	var/datum/component/netdm_node/node

/obj/item/netdm_adapter/pre_attack(atom/target, mob/living/user, params, attackchain_flags, damage_multiplier)
	. = ..()
	if(. & STOP_ATTACK_PROC_CHAIN)
		return
	if(connect_to(target, user))
		to_chat(user, span_notice("Ты подключаешь [src] к [target]."))
	else
		to_chat(user, span_warning("Здесь нет доступного сервисного порта для [src]."))
	return STOP_ATTACK_PROC_CHAIN

/obj/item/netdm_adapter/proc/connect_to(atom/movable/target, mob/living/user)
	if(!SSnetdm_observe?.published || dock_ref || !istype(user) || user.incapacitated() || !user.is_holding(src))
		return FALSE
	if(!istype(target) || QDELETED(target) || istype(target, /obj/item/netdm_adapter) || !user.Adjacent(target))
		return FALSE
	var/turf/position = get_turf(target)
	if(!position || target.loc != position || !target.anchored)
		return FALSE
	if(istype(target, /obj/machinery/power/apc))
		if(!SSnetdm_observe.apc_node_id(target))
			return FALSE
	else
		var/obj/machinery/machine = target
		var/datum/component/netdm_node/target_node = target.GetComponent(/datum/component/netdm_node)
		if(target_node?.mount != NETDM_MOUNT_FIXED || (istype(machine) && !machine.panel_open))
			return FALSE
	if(!user.temporarilyRemoveItemFromInventory(src))
		return FALSE
	if(QDELETED(src))
		return FALSE
	forceMove(position)
	set_anchored(TRUE)
	dock_ref = WEAKREF(target)
	RegisterSignal(target, list(COMSIG_PARENT_QDELETING, COMSIG_MOVABLE_MOVED, COMSIG_OBJ_SETANCHORED), PROC_REF(on_dock_changed))
	node = netdm_make_node(src, NETDM_MOUNT_FIXED, 0)
	return TRUE

/obj/item/netdm_adapter/proc/connected()
	var/atom/movable/target = dock_ref?.resolve()
	return target && node && anchored && target.anchored && isturf(loc) && loc == target.loc

/obj/item/netdm_adapter/proc/disconnect()
	var/atom/movable/target = dock_ref?.resolve()
	if(target)
		UnregisterSignal(target, list(COMSIG_PARENT_QDELETING, COMSIG_MOVABLE_MOVED, COMSIG_OBJ_SETANCHORED))
	dock_ref = null
	QDEL_NULL(node)
	set_anchored(FALSE)

/obj/item/netdm_adapter/proc/on_dock_changed(datum/source)
	SIGNAL_HANDLER
	disconnect()

/obj/item/netdm_adapter/Moved(atom/old_loc, movement_dir, forced)
	. = ..()
	if(dock_ref && old_loc != loc)
		disconnect()

/obj/item/netdm_adapter/Destroy()
	disconnect()
	return ..()

/obj/item/netdm_adapter/on_attack_hand(mob/user, act_intent = user.a_intent, unarmed_attack_flags)
	if(!connected())
		return ..()
	if(GLOB.physical_state.can_use_topic(src, user) == UI_INTERACTIVE)
		var/datum/netdm_terminal/local/adapter/terminal = new(src, node, user)
		terminal.ui_interact(user)
	return TRUE

/obj/item/netdm_adapter/AltClick(mob/user)
	if(!dock_ref || !user.canUseTopic(src, BE_CLOSE, FALSE, NO_TK))
		return ..()
	disconnect()
	user.put_in_hands(src)
	to_chat(user, span_notice("Ты отсоединяешь [src]."))

/datum/netdm_terminal/local/adapter/can_submit()
	var/obj/item/netdm_adapter/adapter = device_ref?.resolve()
	var/mob/user = user_ref?.resolve()
	return ..() && adapter?.connected() && adapter.node == node_ref?.resolve() && user.Adjacent(adapter)

/datum/design/netdm_adapter
	name = "Wired Network Adapter"
	id = "netdm_adapter"
	build_type = AUTOLATHE
	materials = list(/datum/material/iron = 300, /datum/material/glass = 100)
	build_path = /obj/item/netdm_adapter
	category = list("initial", "Tools", "Tool Designs")
	departmental_flags = DEPARTMENTAL_FLAG_ENGINEERING | DEPARTMENTAL_FLAG_SCIENCE

/// Programs one device keeps on its own media; the Host runs at most as many per device.
#define NETDM_KEPT_PROGRAMS 4

/// The kept program file of a PDA drive: a JSON list of list("name", "source").
/datum/computer_file/data/netdm_programs
	filename = "netdm_programs"
	filetype = "NDP1"

/obj/machinery/power/apc
	/// Programs the APC's network module keeps and starts on every attach.
	var/list/netdm_programs

/obj/item/implant/netdm_terminal
	var/list/netdm_programs

/obj/item/netdm_adapter
	var/list/netdm_programs

/**
 * Programs kept on a device's media: list of list("name", "source"), empty when there are none, or null when
 * the device has no media for them (a PDA without a working drive). The device starts each of them with
 * "ensure" whenever its endpoint attaches, so they come back after a Host restart or a new endpoint
 * generation and leave with the media: a removed drive, a destroyed implant.
 */
/proc/netdm_kept_programs(atom/device)
	if(istype(device, /obj/item/modular_computer/pda))
		var/obj/item/modular_computer/pda/pda = device
		var/obj/item/computer_hardware/hard_drive/drive = pda.all_components[MC_HDD]
		if(!drive?.check_functionality())
			return null
		var/datum/computer_file/data/netdm_programs/file = drive.find_file_by_name("netdm_programs")
		if(!istype(file))
			return list()
		var/list/decoded = safe_json_decode(file.stored_data)
		return netdm_valid_kept(decoded)
	var/list/stored
	if(istype(device, /obj/machinery/power/apc))
		var/obj/machinery/power/apc/apc = device
		stored = apc.netdm_programs
	else if(istype(device, /obj/item/implant/netdm_terminal))
		var/obj/item/implant/netdm_terminal/implant = device
		stored = implant.netdm_programs
	else if(istype(device, /obj/item/netdm_adapter))
		var/obj/item/netdm_adapter/adapter = device
		stored = adapter.netdm_programs
	else
		return null
	return netdm_valid_kept(stored)

/// Only well-formed entries count; a damaged file reads as fewer programs, never as foreign data.
/proc/netdm_valid_kept(list/entries)
	var/list/valid = list()
	if(!islist(entries))
		return valid
	for(var/list/entry in entries)
		if(length(valid) >= NETDM_KEPT_PROGRAMS)
			break
		var/name = entry["name"]
		var/source = entry["source"]
		if(istext(name) && length(name) && length_char(name) <= 32 && istext(source) && length(source) && length_char(source) <= NETDM_TERMINAL_SCRIPT_LENGTH)
			valid += list(list("name" = name, "source" = source))
	return valid

/// Writes the kept programs back. FALSE when the device has no media or the media refuses the write.
/proc/netdm_store_kept(atom/device, list/programs)
	if(istype(device, /obj/item/modular_computer/pda))
		var/obj/item/modular_computer/pda/pda = device
		var/obj/item/computer_hardware/hard_drive/drive = pda.all_components[MC_HDD]
		if(!drive?.check_functionality())
			return FALSE
		var/datum/computer_file/data/netdm_programs/file = drive.find_file_by_name("netdm_programs")
		if(file && !istype(file))
			return FALSE
		if(!length(programs))
			if(file)
				drive.remove_file(file)
			return TRUE
		var/text = json_encode(programs)
		if(file)
			var/new_size = max(1, round(length(text) / file.block_size))
			if(file.undeletable || drive.used_capacity - file.size + new_size > drive.max_capacity)
				return FALSE
			file.stored_data = text
			file.calculate_size()
			drive.recalculate_size()
			return TRUE
		file = new
		file.stored_data = text
		file.calculate_size()
		if(!drive.store_file(file))
			qdel(file)
			return FALSE
		return TRUE
	var/list/copy = length(programs) ? programs.Copy() : null
	if(istype(device, /obj/machinery/power/apc))
		var/obj/machinery/power/apc/apc = device
		apc.netdm_programs = copy
	else if(istype(device, /obj/item/implant/netdm_terminal))
		var/obj/item/implant/netdm_terminal/implant = device
		implant.netdm_programs = copy
	else if(istype(device, /obj/item/netdm_adapter))
		var/obj/item/netdm_adapter/adapter = device
		adapter.netdm_programs = copy
	else
		return FALSE
	return TRUE

/// The endpoint of a node attached in this session: the device starts what it keeps. Answers are logged.
/datum/netdm_diagnostics/proc/endpoint_attached(datum/node)
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	var/atom/device = lane?.owner_of(node)
	if(!istype(device) || QDELETED(device))
		return
	var/list/kept = netdm_kept_programs(device)
	if(!length(kept))
		return
	var/datum/weakref/device_ref = WEAKREF(device)
	for(var/list/entry in kept)
		var/list/arguments = list("name" = entry["name"], "source" = entry["source"], "ensure" = TRUE)
		if(!queue_shell_request(node, node, "start", arguments, CALLBACK(src, PROC_REF(kept_answered), device_ref, entry["name"]),
			CALLBACK(src, PROC_REF(kept_device_present), device_ref)))
			SSnetdm_observe.log_issue("kept program [entry["name"]] of [device] not queued")
	counters["kept_starts"] = (counters["kept_starts"] || 0) + length(kept)

/datum/netdm_diagnostics/proc/kept_device_present(datum/weakref/device_ref)
	var/atom/device = device_ref?.resolve()
	return device && !QDELETED(device)

/datum/netdm_diagnostics/proc/kept_answered(datum/weakref/device_ref, name, list/output)
	var/status = output?["status"]
	if(status == "started" || status == "running")
		return
	var/atom/device = device_ref?.resolve()
	SSnetdm_observe.log_issue("kept program [name] of [device || "a gone device"]: [status || "no answer"] [output?["error"]]")

/// Keeps a program on the terminal's device, replacing one of the same name. Returns an error text or null.
/datum/netdm_terminal/proc/keep_program(name, source)
	var/atom/device = device_ref?.resolve()
	var/list/kept = device && netdm_kept_programs(device)
	if(!islist(kept))
		return "У устройства нет носителя для программ."
	for(var/list/entry in kept.Copy())
		if(entry["name"] == name)
			kept -= list(entry)
	if(length(kept) >= NETDM_KEPT_PROGRAMS)
		return "На устройстве уже [NETDM_KEPT_PROGRAMS] программы."
	kept += list(list("name" = name, "source" = source))
	return netdm_store_kept(device, kept) ? null : "Носитель не принял запись: проверь место и состояние диска."

/datum/netdm_terminal/proc/forget_program(name)
	var/atom/device = device_ref?.resolve()
	var/list/kept = device && netdm_kept_programs(device)
	if(!istext(name) || !islist(kept))
		return FALSE
	var/found = FALSE
	for(var/list/entry in kept.Copy())
		if(entry["name"] == name)
			kept -= list(entry)
			found = TRUE
	if(!found || !netdm_store_kept(device, kept))
		return FALSE
	disk_notice = "[name] больше не хранится на устройстве. Запущенная программа работает, пока её не остановят."
	return TRUE

/datum/netdm_terminal/proc/kept_names()
	var/atom/device = device_ref?.resolve()
	var/list/kept = device && netdm_kept_programs(device)
	if(!islist(kept))
		return null
	var/list/names = list()
	for(var/list/entry in kept)
		names += entry["name"]
	return names

#undef NETDM_KEPT_PROGRAMS
#undef NETDM_TERMINAL_LINES
#undef NETDM_TERMINAL_LINE_LENGTH
#undef NETDM_TERMINAL_SCRIPT_LENGTH
#undef NETDM_TERMINAL_ROWS
#undef NETDM_TERMINAL_PENDING
#undef NETDM_TERMINAL_TIMEOUT
