/// A queued packet owns its immutable sender/target context and its cancellable timer.
/// UI route snapshots never survive the delivery boundary.
/datum/netrun_request/delivery
	var/datum/netrun_console/console
	var/datum/component/netrun_node/node
	var/datum/netrun_network/sent_network
	var/mob/sender
	var/list/dependencies = list()
	var/timer_id
	var/delivering = FALSE
	var/cancelled = FALSE
	/// A packet may be dispatched once, whether immediately or through its owned timer.
	var/sent = FALSE

/datum/netrun_request/delivery/New(datum/netrun_console/console, datum/component/netrun_node/node, datum/netrun_network/sent_network, mob/sender, file_uid)
	..(file_uid)
	src.console = console
	src.node = node
	src.sent_network = sent_network
	src.sender = sender
	for(var/datum/dependency as anything in list(console, node, sent_network, sender))
		if(QDELETED(dependency) || (dependency in dependencies))
			continue
		dependencies += dependency
		RegisterSignal(dependency, COMSIG_PARENT_QDELETING, PROC_REF(on_dependency_deleted))

/datum/netrun_request/delivery/Destroy()
	if(timer_id)
		deltimer(timer_id)
		timer_id = null
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
		qdel(src)

/datum/netrun_request/delivery/proc/send(delay = 0)
	if(sent || delivering || QDELETED(src))
		return FALSE
	if(cancelled || QDELETED(console) || QDELETED(node))
		qdel(src)
		return FALSE
	sent = TRUE
	if(delay <= 0)
		return deliver()
	timer_id = addtimer(CALLBACK(src, PROC_REF(deliver)), delay, TIMER_STOPPABLE | TIMER_DELETE_ME)
	return TRUE

/datum/netrun_request/delivery/proc/deliver()
	if(delivering || QDELETED(src))
		return FALSE
	// Direct delivery also consumes this packet; an early delivery cancels its timer.
	sent = TRUE
	if(timer_id)
		deltimer(timer_id)
	timer_id = null
	delivering = TRUE
	if(!cancelled && !QDELETED(console) && !QDELETED(node))
		. = execute()
	qdel(src)

/datum/netrun_request/delivery/proc/execute()
	return FALSE

/// The console facade retains command polymorphism; this object owns packet delivery.
/datum/netrun_request/command
	parent_type = /datum/netrun_request/delivery
	var/datum/netrun_command/command
	var/command_id

/datum/netrun_request/command/New(datum/netrun_console/console, datum/component/netrun_node/node, datum/netrun_command/command, command_id, datum/netrun_network/sent_network, mob/sender, file_uid)
	..(console, node, sent_network, sender, file_uid)
	src.command = command
	src.command_id = command_id

/datum/netrun_request/command/Destroy()
	command = null
	command_id = null
	return ..()

/datum/netrun_request/command/execute()
	return console.do_command(node, command, command_id, FALSE, sent_network, sender, file_uid)

/// Published native API actions share packet lifecycle with ordinary commands.
/datum/netrun_request/remote
	parent_type = /datum/netrun_request/delivery
	var/datum/netrun_provider/api
	var/action
	var/list/arguments

/datum/netrun_request/remote/New(datum/netrun_console/console, datum/component/netrun_node/node, datum/netrun_provider/api, action, list/arguments, datum/netrun_network/sent_network, mob/sender)
	..(console, node, sent_network, sender)
	src.api = api
	src.action = action
	src.arguments = arguments ? arguments.Copy() : list()

/datum/netrun_request/remote/Destroy()
	api = null
	arguments = null
	return ..()

/datum/netrun_request/remote/execute()
	node.join_network()
	var/list/entry = api?.actions[action]
	var/datum/netrun_path_tree/tree = console.make_path_tree()
	if(!entry || QDELETED(api) || SSnetrun.get_provider(node.parent) != api || !console.operator || sender != console.operator || node.network != sent_network || console.is_locked() || !console.can_route(node, tree) || !node.is_online() || console.node_level(node, tree) < api.action_access(action))
		qdel(tree)
		console.log_line("Запрос устройства отменён: связь или доступ изменились.", "bad")
		return FALSE
	var/illegal = console.legit_node_level(node, tree) < api.action_access(action)
	qdel(tree)
	var/atom/target = node.parent
	var/reason = api.action_unavailable_reason(target, action, console, node)
	if(reason)
		console.log_line("Запрос устройства отменён: [reason]", "bad")
		return FALSE
	// Also validate callers of do_remote_request and packets whose schema changed
	// in flight. The provider only receives its published primitive arguments.
	var/list/clean = api.clean_params(action, arguments)
	if(isnull(clean))
		console.log_line("Запрос устройства отменён: некорректные параметры.", "bad")
		return FALSE
	if(!api.execute(target, action, clean, console, node))
		if(!QDELETED(console))
			console.log_line("Сервис устройства не принял запрос.", "bad")
		return FALSE
	// Native actions may yield, delete their host, or close the originating session.
	if(QDELETED(console) || QDELETED(node))
		return TRUE
	node.touch()
	node.add_log("[console.log_source()]: [entry["name"]][illegal ? " (без авторизации)" : ""].")
	node.network?.add_log("[console.log_source()] -> [node.address]: [entry["name"]]", illegal)
	log_game("NETRUN API: [key_name(sender)] [action] -> [node.address] [AREACOORD(target)]")
	console.log_line("[node.address]: запрос передан интерфейсу устройства.", "good")
	if(illegal)
		console.add_trace(6 * node.get_security())
	return TRUE

/// Window adapters keep their native authorization policy behind the console facade.
/datum/netrun_request/window
	parent_type = /datum/netrun_request/delivery
	var/action
	var/list/arguments

/datum/netrun_request/window/New(datum/netrun_console/console, datum/component/netrun_node/node, action, list/arguments, datum/netrun_network/sent_network, mob/sender)
	..(console, node, sent_network, sender)
	src.action = action
	src.arguments = arguments ? arguments.Copy() : list()

/datum/netrun_request/window/Destroy()
	arguments = null
	return ..()

/datum/netrun_request/window/execute()
	return console.do_window_act(node, action, arguments, sent_network, sender)

/// A file request fixes the UID at send time; a later selection cannot substitute another file.
/datum/netrun_request/file
	parent_type = /datum/netrun_request/delivery
	var/action
	var/to_shard = FALSE

/datum/netrun_request/file/New(datum/netrun_console/console, datum/component/netrun_node/node, action, file_uid, to_shard, datum/netrun_network/sent_network, mob/sender)
	..(console, node, sent_network, sender, file_uid)
	src.action = action
	src.to_shard = to_shard

/datum/netrun_request/file/execute()
	return console.deliver_file_request(action, node, file_uid, to_shard, sent_network, sender)
