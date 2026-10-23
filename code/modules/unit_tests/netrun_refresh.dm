/// Observing a live ICE must not turn every subsequent quiet UI into a permanent poll.
/datum/unit_test/netrun_refresh_observed_ice_countdown/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/component/netrun_node/node = host.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
	var/mob/camera/netrun_entity/entity = allocate(/mob/camera/netrun_entity)
	entity.enter_node(node)
	var/datum/netrun_ice/ice = allocate(/datum/netrun_ice, node)
	var/datum/netrun_combat_context/combat = entity.console.combat_context
	combat.observe(ice)
	TEST_ASSERT(!combat.needs_live_refresh(), "An idle observed ICE has no visible countdown")
	TEST_ASSERT(ice.begin_program(SSnetrun.get_program("strike"), entity), "A real ICE must prepare its attack")
	TEST_ASSERT(combat.needs_live_refresh(), "An incoming cast needs live HUD updates on every page")
	ice.cancel_program()
	TEST_ASSERT(!combat.needs_live_refresh(), "Cancelling the cast must allow the UI to become quiet again")
	combat.program_cd["strike"] = world.time + 10 SECONDS
	entity.console.workspace_view = "terminal"
	TEST_ASSERT(!combat.needs_live_refresh(), "Hidden program cooldowns should not poll the terminal")
	entity.console.workspace_view = "combat"
	TEST_ASSERT(combat.needs_live_refresh(), "Visible program cooldowns must keep counting down")

/// Hidden window and map animation data must not wake unrelated workspaces.
/datum/unit_test/netrun_refresh_hidden_workspace/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	console.remote_session.active_window = "pinned-device"
	console.map_view.ping_route = list("route")
	console.map_view.ping_at = world.time
	console.workspace_view = "terminal"
	TEST_ASSERT(!console.needs_live_refresh(), "A hidden window/ping must not poll the terminal")
	console.workspace_view = "files"
	TEST_ASSERT(!console.needs_live_refresh(), "A hidden window/ping must not poll the file editor")
	console.workspace_view = "pinned"
	TEST_ASSERT(console.needs_live_refresh(), "An active native device page must reconcile external state")
	console.workspace_view = "map"
	TEST_ASSERT(console.needs_live_refresh(), "A visible ping must keep animating and expire")

/// Files and pinned tabs must receive external changes while their expensive map is asleep.
/datum/unit_test/netrun_refresh_hidden_map_observer/Run()
	var/obj/item/host = allocate(/obj/item)
	var/obj/item/target = allocate(/obj/item)
	var/datum/component/netrun_node/node = target.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL, list(), 1, null, 8)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	console.note_ui_activity()
	console.map_view.selected_address = node.address
	console.workspace_view = "files"
	console.map_view.subscribe()
	console.process_tick(0)
	TEST_ASSERT(!console.map_view.subscribed, "A hidden map must release its global projection subscriptions")
	console.ui_dirty = FALSE
	node.notify_changed()
	TEST_ASSERT(console.ui_dirty, "A selected device change must still wake its file workspace")
	TEST_ASSERT_EQUAL(length(console.map_view.dirty_nodes), 0, "A hidden map must not accumulate a projection update queue")

	console.map_view.selected_address = null
	console.remote_session.windows += node.address
	console.remote_session.active_window = node.address
	console.workspace_view = "pinned"
	console.ui_dirty = FALSE
	node.notify_changed()
	TEST_ASSERT(console.ui_dirty, "An active pinned device must react independently of the selected map node")

	console.workspace_view = "files"
	console.map_view.selected_address = node.address
	console.ui_dirty = FALSE
	var/datum/netrun_file/file = new("external.txt", NETRUN_FILE_TEXT, "Another runner uploaded this file.")
	TEST_ASSERT(node.file_store.insert(file), "The selected endpoint must accept a real external file")
	TEST_ASSERT(console.ui_dirty, "An external remote-store write must wake the file list")
	console.ui_dirty = FALSE
	node.add_log("Another runner inspected this device.")
	TEST_ASSERT(console.ui_dirty, "A selected device's new log line must wake its observers")
	console.map_view.selected_network = node.network.id
	console.ui_dirty = FALSE
	node.network.add_log("External network activity.")
	TEST_ASSERT(console.ui_dirty, "A selected network log must wake its observers")

/// A backend notification queues one normal task immediately, independently of population.
/datum/unit_test/netrun_refresh_invalidation_coalesces/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	var/datum/netrun_task_scheduler/scheduler = SSnetrun.get_task_scheduler()
	var/key = "console:[REF(console)]"
	console.note_ui_activity()
	scheduler.cancel("console", console)
	var/populations = SSnetrun.task_populations
	console.invalidate_ui()
	var/datum/netrun_task/task = scheduler.by_key[key]
	TEST_ASSERT_NOTNULL(task, "Backend invalidation must queue processing before the next population pass")
	TEST_ASSERT(!task.interactive, "A background notification must preserve the explicit-input lane for player actions")
	console.invalidate_ui()
	TEST_ASSERT_EQUAL(scheduler.by_key[key], task, "Several domain changes must share one queued console task")
	TEST_ASSERT_EQUAL(SSnetrun.task_populations, populations, "Queuing a reactive update must not repopulate all subsystem work")
	qdel(console)
	TEST_ASSERT_NULL(scheduler.by_key[key], "Deleting a console must cancel its pending reactive task")

/// Messages from another session must reach quiet readers without map or timer activity.
/datum/unit_test/netrun_refresh_chat_broadcast/Run()
	var/obj/item/first_host = allocate(/obj/item)
	var/obj/item/second_host = allocate(/obj/item)
	var/datum/netrun_console/first = allocate(/datum/netrun_console, first_host)
	var/datum/netrun_console/second = allocate(/datum/netrun_console, second_host)
	first.note_ui_activity()
	second.note_ui_activity()
	first.workspace_view = "terminal"
	second.workspace_view = "files"
	var/datum/ntnet_conversation/channel = SSnetrun.get_net_channel()
	first.ui_dirty = FALSE
	second.ui_dirty = FALSE
	channel.add_message("Reactive chat test.", "test-runner")
	TEST_ASSERT(first.ui_dirty, "A quiet terminal must receive a new channel message")
	TEST_ASSERT(second.ui_dirty, "A quiet file workspace must receive a new channel message")
	TEST_ASSERT(!first.map_view.subscribed && !second.map_view.subscribed, "Chat delivery must not subscribe hidden map projections")

/// Context listeners follow the current operator and every container carrying the console.
/datum/unit_test/netrun_refresh_observer_lifecycle/Run()
	var/obj/item/carrier = allocate(/obj/item)
	var/obj/item/host = allocate(/obj/item, carrier)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	var/mob/living/first = allocate(/mob/living)
	var/mob/living/second = allocate(/mob/living)
	console.operator = first
	console.note_ui_activity()
	TEST_ASSERT(console.ui_context_sources[first], "The active operator must own a context subscription")
	TEST_ASSERT(console.ui_context_sources[carrier], "A nested console must observe the container moving its host")
	console.ui_dirty = FALSE
	carrier.forceMove(get_step(run_loc_floor_bottom_left, EAST))
	TEST_ASSERT(console.ui_dirty, "Moving a console's carrier must refresh the source without waiting for polling")

	console.operator = second
	console.observe_ui_state()
	TEST_ASSERT(!console.ui_context_sources[first], "Replacing the operator must release the old mob's listeners")
	TEST_ASSERT(console.ui_context_sources[second], "Replacing the operator must observe the new mob immediately")
	console.ui_dirty = FALSE
	SEND_SIGNAL(first, COMSIG_MOB_EQUIPPED_ITEM, host, ITEM_SLOT_HANDS)
	TEST_ASSERT(!console.ui_dirty, "The previous operator's equipment must no longer invalidate the console")
	SEND_SIGNAL(second, COMSIG_MOB_EQUIPPED_ITEM, host, ITEM_SLOT_HANDS)
	TEST_ASSERT(console.ui_dirty, "The new operator's equipment must invalidate derived access")

	var/datum/component/netrun_node/node = host.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
	console.map_view.subscribe()
	console.stop_ui_observation()
	TEST_ASSERT(!console.ui_observing && !length(console.ui_context_sources), "Suspending an inactive viewer must release all context listeners")
	TEST_ASSERT(!console.map_view.subscribed, "Suspending an inactive viewer must also release the map's global subscriptions")
	console.ui_dirty = FALSE
	SEND_SIGNAL(SSnetrun, COMSIG_NETRUN_CHAT_CHANGED)
	SEND_SIGNAL(second, COMSIG_MOB_EQUIPPED_ITEM, host, ITEM_SLOT_HANDS)
	node.notify_changed()
	TEST_ASSERT(!console.ui_dirty, "A suspended viewer must receive neither global nor context broadcasts")
	TEST_ASSERT_EQUAL(length(console.map_view.dirty_nodes), 0, "A suspended map must not collect stale node updates")
	console.note_ui_activity()
	SEND_SIGNAL(SSnetrun, COMSIG_NETRUN_CHAT_CHANGED)
	TEST_ASSERT(console.ui_dirty, "A reopened viewer must subscribe again")

/// Countdown repaint work must end after one task instead of requeuing in the same tick.
/datum/unit_test/netrun_refresh_countdown_does_not_requeue/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	var/datum/netrun_task_scheduler/scheduler = SSnetrun.get_task_scheduler()
	console.note_ui_activity()
	scheduler.cancel("console", console)
	console.intrusion.trace = 5
	console.intrusion.last_illegal = world.time
	console.ui_event_pending = FALSE
	console.ui_dirty = FALSE
	var/key = "console:[REF(console)]"
	var/datum/netrun_task/console/task = allocate(/datum/netrun_task/console, "console", key, NETRUN_TASK_NORMAL, console)
	task.execute(SSnetrun, SSnetrun.get_execution_limits())
	TEST_ASSERT(console.ui_dirty, "A visible trace countdown must still request its next repaint")
	TEST_ASSERT(!console.ui_event_pending, "A countdown repaint must not pretend to be a new domain event")
	TEST_ASSERT_NULL(scheduler.by_key[key], "A countdown task must not queue another same-tick task")
	var/datum/netrun_execution_limits/limits = SSnetrun.get_execution_limits()
	var/previous_flush = limits.interactive_flush
	limits.interactive_flush = FALSE
	console.ui_event_pending = TRUE
	task.execute(SSnetrun, limits)
	limits.interactive_flush = previous_flush
	TEST_ASSERT(console.ui_dirty && console.ui_event_pending, "A throttled domain event must remain pending for a later pass")
	TEST_ASSERT_NULL(scheduler.by_key[key], "Disabling immediate flushes must not create an event requeue loop")

/obj/item/netrun_refresh_status_test
	var/status_value = 1

/obj/item/netrun_refresh_status_test/netrun_status()
	return list("value" = status_value)

/// Legacy status fields without signals are compared locally without quiet panel redraws.
/datum/unit_test/netrun_refresh_selected_legacy_status/Run()
	var/obj/item/host = allocate(/obj/item)
	var/obj/item/netrun_refresh_status_test/target = allocate(/obj/item/netrun_refresh_status_test)
	var/datum/component/netrun_node/node = target.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	console.connection.wireless = FALSE
	console.set_jack(node)
	console.access_session.node_access[node.address] = NETRUN_ACCESS_ROOT
	console.workspace_view = "files"
	console.note_ui_activity()
	console.reconcile_ui_context()
	console.ui_dirty = FALSE
	console.reconcile_ui_context()
	TEST_ASSERT(!console.ui_dirty, "A quiet legacy panel must not repaint an unchanged status")
	target.status_value = 2
	console.reconcile_ui_context()
	TEST_ASSERT(console.ui_dirty, "A native status change without a signal must refresh the visible selected panel")
	console.workspace_view = "terminal"
	console.reconcile_ui_context()
	console.ui_dirty = FALSE
	target.status_value = 3
	console.reconcile_ui_context()
	TEST_ASSERT(!console.ui_dirty, "Changes to a hidden legacy status must not repaint the terminal")

/// Closing the most recent viewer must not leave another open terminal without subscriptions.
/datum/unit_test/netrun_refresh_multiple_viewers/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	var/mob/living/first = allocate(/mob/living)
	var/mob/living/second = allocate(/mob/living)
	var/datum/tgui/first_ui = allocate(/datum/tgui, first, console, "NetrunTerminal")
	var/datum/tgui/second_ui = allocate(/datum/tgui, second, console, "NetrunTerminal")
	var/key = REF(console)
	var/list/previous_viewers = SStgui.open_uis_by_src[key]
	SStgui.open_uis_by_src[key] = list(first_ui, second_ui)
	console.operator = second
	console.note_ui_activity()
	var/both_observed = console.ui_context_sources[first] && console.ui_context_sources[second]
	SStgui.open_uis_by_src[key] = list(first_ui)
	console.last_ui_at = -INFINITY
	var/still_active = console.is_ui_active()
	console.refresh_ui_context_sources()
	var/remaining_observed = console.ui_context_sources[first]
	console.ui_dirty = FALSE
	SEND_SIGNAL(first, COMSIG_MOB_EQUIPPED_ITEM, host, ITEM_SLOT_HANDS)
	var/remaining_invalidated = console.ui_dirty
	if(isnull(previous_viewers))
		SStgui.open_uis_by_src -= key
	else
		SStgui.open_uis_by_src[key] = previous_viewers
	TEST_ASSERT(both_observed, "Every open viewer must receive credential-context subscriptions")
	TEST_ASSERT(still_active, "An older viewer must keep a shared console active after the last operator leaves")
	TEST_ASSERT(remaining_observed, "The remaining viewer must retain its context subscription")
	TEST_ASSERT(remaining_invalidated, "The remaining viewer's equipment must still invalidate the shared console")
