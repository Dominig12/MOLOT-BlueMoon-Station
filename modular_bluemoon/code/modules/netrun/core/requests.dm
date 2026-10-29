/// A queued packet owns its immutable sender/target context and its cancellable timer.
/// UI route snapshots never survive the delivery boundary.
/datum/netrun_request/delivery
	delivery_kind = "request_delivery"
	var/datum/netrun_console/console
	var/datum/component/netrun_node/node
	var/datum/netrun_network/sent_network
	var/mob/sender
	var/list/dependencies = list()
	var/delivering = FALSE
	var/cancelled = FALSE
	/// A packet may be dispatched once, whether immediately or through its owned timer.
	var/sent = FALSE
	/// Owned copy of the dispatch snapshot's path; interest never builds a second route tree.
	var/list/poll_route = list()
	var/datum/netrun_packet_context/operation
	var/operation_kind = "request"
	var/operation_label = "Сетевой запрос"

/datum/netrun_request/delivery/New(datum/netrun_console/console, datum/component/netrun_node/node, datum/netrun_network/sent_network, mob/sender, file_uid, datum/netrun_packet_context/context)
	..(file_uid)
	src.console = console
	src.node = node
	src.sent_network = sent_network
	src.sender = sender
	operation = context || new /datum/netrun_packet_context(operation_kind, operation_label,
		console?.route_source()?.address, node?.address, operation_kind, console)
	for(var/datum/dependency as anything in list(console, node, sent_network, sender))
		if(QDELETED(dependency) || (dependency in dependencies))
			continue
		dependencies += dependency
		RegisterSignal(dependency, COMSIG_PARENT_QDELETING, PROC_REF(on_dependency_deleted))

/datum/netrun_request/delivery/Destroy()
	cancel_delivery()
	SSnetrun.pending_requests -= src
	QDEL_NULL(operation)
	poll_route.Cut()
	for(var/datum/dependency as anything in dependencies)
		UnregisterSignal(dependency, COMSIG_PARENT_QDELETING)
	dependencies.Cut()
	console = null
	node = null
	sent_network = null
	sender = null
	return ..()

/datum/netrun_request/delivery/proc/on_dependency_deleted(datum/source)
	SIGNAL_HANDLER
	cancelled = TRUE
	if(!delivering)
		operation?.finish("cancelled", "Доставка отменена: сеанс или узел удалён.")
	if(!delivering)
		qdel(src)

/datum/netrun_request/delivery/proc/send(delay = 0, list/route_hops)
	if(sent || delivering || QDELETED(src))
		return FALSE
	if(cancelled || QDELETED(console) || QDELETED(node))
		qdel(src)
		return FALSE
	if(length(SSnetrun.pending_requests) >= NETRUN_MAX_PENDING_REQUESTS)
		operation.finish("rejected", "Очередь доставки запросов переполнена.")
		qdel(src)
		return FALSE
	sent = TRUE
	poll_route = route_hops ? route_hops.Copy() : list()
	operation.queued(poll_route, delay)
	SSnetrun.pending_requests[src] = TRUE
	SSnetrun.collect_request_node_interest(src)
	// Circuits and bots are autonomous; explicit player packets enter the interactive lane.
	if(!console.autonomous())
		console.note_user_action()
	return schedule_delivery(delay)

/// Timer callbacks only admit ready work; execution shares the subsystem budget.
/datum/netrun_request/delivery/can_queue_delivery()
	return !delivering && !cancelled

/datum/netrun_request/delivery/delivery_priority()
	var/datum/netrun_execution_limits/limits = SSnetrun.get_execution_limits()
	return delivery_interactive() ? limits.interactive_priority : NETRUN_TASK_NORMAL

/datum/netrun_request/delivery/delivery_interactive()
	return console && !console.autonomous()

/datum/netrun_request/delivery/deliver()
	set waitfor = FALSE
	if(delivering || QDELETED(src))
		return FALSE
	// Trusted direct callers keep their explicit execution boundary. Native input
	// may yield; the packet keeps its lifetime, while the scheduler can continue.
	cancel_delivery()
	if(!sent)
		operation.queued(poll_route)
		SSnetrun.pending_requests[src] = TRUE
	sent = TRUE
	delivering = TRUE
	if(!cancelled && !QDELETED(console) && !QDELETED(node))
		operation.running()
		. = execute()
		if(!operation.finished)
			operation.finish(. ? "completed" : (cancelled ? "cancelled" : "rejected"), . ? null : "Устройство не приняло запрос.")
		if(!QDELETED(console) && !console.autonomous())
			console.finish_user_action(QDELETED(node) ? null : node)
	else
		operation.finish("cancelled", "Доставка отменена: сеанс или узел удалён.")
	qdel(src)
	return .

/datum/netrun_request/delivery/proc/reject(reason)
	operation.finish("rejected", reason)
	return FALSE

/datum/netrun_request/delivery/proc/execute()
	return FALSE

/// The console facade retains command polymorphism; this object owns packet delivery.
/datum/netrun_request/command
	parent_type = /datum/netrun_request/delivery
	var/datum/netrun_command/command
	var/command_id
	var/packet_id
	operation_kind = "command"
	operation_label = "Команда устройства"

/datum/netrun_request/command/New(datum/netrun_console/console, datum/component/netrun_node/node, datum/netrun_command/command, command_id, datum/netrun_network/sent_network, mob/sender, file_uid, datum/netrun_packet_context/context, packet_id)
	..(console, node, sent_network, sender, file_uid, context)
	src.command = command
	src.command_id = command_id
	src.packet_id = packet_id
	console.track_command_packet(src)

/datum/netrun_request/command/Destroy()
	command = null
	command_id = null
	return ..()

/datum/netrun_request/command/execute()
	return console.do_command(node, command, command_id, FALSE, sent_network, sender, file_uid, operation, packet_id)

/// Published native API actions share packet lifecycle with ordinary commands.
/datum/netrun_request/remote
	parent_type = /datum/netrun_request/delivery
	var/datum/netrun_provider/api
	var/action
	var/list/arguments
	operation_kind = "remote"
	operation_label = "Запрос устройства"

/datum/netrun_request/remote/New(datum/netrun_console/console, datum/component/netrun_node/node, datum/netrun_provider/api, action, list/arguments, datum/netrun_network/sent_network, mob/sender, datum/netrun_packet_context/context)
	..(console, node, sent_network, sender, null, context)
	src.api = api
	src.action = action
	src.arguments = arguments ? arguments.Copy() : list()
	operation.capture(list("action" = action, "arguments" = src.arguments))

/datum/netrun_request/remote/Destroy()
	api = null
	arguments = null
	return ..()

/datum/netrun_request/remote/execute()
	node.join_network()
	var/list/entry = api?.actions[action]
	var/datum/netrun_path_tree/tree = console.make_path_tree()
	var/reachable = console.can_route(node, tree)
	if(reachable)
		operation.receive(tree.addresses_to(node.address))
	if(!entry || QDELETED(api) || SSnetrun.get_provider(node.parent) != api || !console.operator || sender != console.operator || node.network != sent_network || console.is_locked() || !reachable || !node.is_online() || console.node_level(node, tree) < api.action_access(action))
		qdel(tree)
		console.log_line("Запрос устройства отменён: связь или доступ изменились.", "bad")
		return reject("Связь, оператор или доступ к устройству изменились.")
	var/illegal = console.legit_node_level(node, tree) < api.action_access(action)
	qdel(tree)
	var/atom/target = node.parent
	var/reason = api.action_unavailable_reason(target, action, console, node)
	if(reason)
		console.log_line("Запрос устройства отменён: [reason]", "bad")
		return reject(reason)
	// Also validate callers of do_remote_request and packets whose schema changed
	// in flight. The provider only receives its published primitive arguments.
	var/list/clean = api.clean_params(action, arguments)
	if(isnull(clean))
		console.log_line("Запрос устройства отменён: некорректные параметры.", "bad")
		return reject("Некорректные параметры запроса.")
	if(!api.execute(target, action, clean, console, node))
		if(!QDELETED(console))
			console.log_line("Сервис устройства не принял запрос.", "bad")
		return reject("Штатный интерфейс устройства не принял запрос.")
	// Native actions may yield, delete their host, or close the originating session.
	if(QDELETED(console) || QDELETED(node))
		return TRUE
	node.touch()
	node.add_log("[console.log_source()]: [entry["name"]][illegal ? " (без авторизации)" : ""].")
	node.network?.add_log("[console.log_source()] -> [node.address]: [entry["name"]]", illegal)
	log_game("NETRUN API: [key_name(sender)] [action] -> [node.address] [AREACOORD(target)]")
	console.log_line("[node.address]: запрос передан интерфейсу устройства.", "good")
	operation.set_result("[entry["name"]]: запрос обработан интерфейсом устройства.")
	if(illegal)
		var/trace_cost = 6 * node.get_security()
		console.report_illegal_activity(node, entry["name"], api.action_access(action))
		if(!QDELETED(console))
			console.add_trace(trace_cost)
	return TRUE

/// Window adapters keep their native authorization policy behind the console facade.
/datum/netrun_request/window
	parent_type = /datum/netrun_request/delivery
	var/action
	var/list/arguments
	operation_kind = "window"
	operation_label = "Действие устройства"

/datum/netrun_request/window/New(datum/netrun_console/console, datum/component/netrun_node/node, action, list/arguments, datum/netrun_network/sent_network, mob/sender, datum/netrun_packet_context/context)
	..(console, node, sent_network, sender, null, context)
	src.action = action
	src.arguments = arguments ? arguments.Copy() : list()
	operation.capture(list("action" = action, "arguments" = src.arguments))

/datum/netrun_request/window/Destroy()
	arguments = null
	return ..()

/datum/netrun_request/window/execute()
	return console.do_window_act(node, action, arguments, sent_network, sender, operation)

/// A file request fixes the UID at send time; a later selection cannot substitute another file.
/datum/netrun_request/file
	parent_type = /datum/netrun_request/delivery
	var/action
	var/to_shard = FALSE
	operation_kind = "file"
	operation_label = "Файловый запрос"

/datum/netrun_request/file/New(datum/netrun_console/console, datum/component/netrun_node/node, action, file_uid, to_shard, datum/netrun_network/sent_network, mob/sender, datum/netrun_packet_context/context)
	..(console, node, sent_network, sender, file_uid, context)
	src.action = action
	src.to_shard = to_shard
	operation.capture(list("action" = action, "file_uid" = file_uid, "to_shard" = to_shard))

/datum/netrun_request/file/execute()
	. = console.deliver_file_request(action, node, file_uid, to_shard, sent_network, sender, operation)
	// File callbacks own validation and their existing trace prices. Report only
	// accepted mutations/reads, never an invalid UID or a full destination disk.
	if(!. || QDELETED(console) || QDELETED(node))
		return .
	var/required = action == "delete" ? NETRUN_ACCESS_ROOT : NETRUN_ACCESS_USER
	required = max(required, node.fortress?.file_access_level(console) || 0)
	if(console.compute_legit_node_level(node, TRUE) < required)
		var/list/labels = list("download" = "Скачивание файла", "upload" = "Загрузка файла", "delete" = "Удаление файла", "read" = "Чтение файла")
		console.report_illegal_activity(node, labels[action] || "Файловая операция", required)
	return .
