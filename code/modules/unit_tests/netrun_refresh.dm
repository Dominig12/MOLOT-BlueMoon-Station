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
