/// ICE profiles compose independent program memory and behavior; a disabled
/// capability cannot silently fall through to an old hardcoded AI branch.
/datum/unit_test/netrun_ice_agent_profiles/Run()
	var/datum/netrun_fortress_scene/scene = allocate(/datum/netrun_fortress_scene, run_loc_floor_bottom_left)
	var/mob/camera/netrun_entity/entity = allocate(/mob/camera/netrun_entity, run_loc_floor_bottom_left, scene.node_a)
	var/datum/netrun_ice/legal = allocate(/datum/netrun_ice, scene.node_a)
	var/datum/netrun_ice/black = allocate(/datum/netrun_ice, scene.node_a, NETRUN_ICE_BLACK)
	TEST_ASSERT_NOTNULL(legal.agent.memory, "Protection agents own program memory")
	TEST_ASSERT(legal.agent.memory != black.agent.memory, "Agent storage is never shared")
	TEST_ASSERT_EQUAL(length(legal.agent.memory.files), 3, "The guard receives its declared loadout")
	TEST_ASSERT(!legal.is_intruder(entity), "Ordinary ICE respects legitimate host residency")
	TEST_ASSERT(black.is_intruder(entity), "Illegal ICE remains dangerous even to a USER")
	legal.process_ai(1)
	TEST_ASSERT_NULL(legal.pending_program, "A legitimate resident does not trigger ordinary protection")
	for(var/datum/netrun_ice_behavior/local_combat/behavior in black.agent.behaviors)
		behavior.enabled = FALSE
	black.process_ai(1)
	TEST_ASSERT_NULL(black.pending_program, "Removing combat behavior removes the attack")
	for(var/datum/netrun_ice_behavior/local_combat/behavior in black.agent.behaviors)
		behavior.enabled = TRUE
	black.process_ai(1)
	TEST_ASSERT_NOTNULL(black.pending_program, "The same agent attacks once its combat capability is enabled")
	TEST_ASSERT(black.attack_at >= world.time + NETRUN_ICE_MIN_TELEGRAPH, "Illegal protection retains a counterplay telegraph")
	black.cancel_program()
	black.deployer_ref = WEAKREF(entity.console)
	TEST_ASSERT(!black.is_intruder(entity), "The deploying principal is not attacked by its own ICE")
	TEST_ASSERT(entity.console.start_breach("node", scene.node_a.address), "The deploying principal can begin its ordinary host breach")
	TEST_ASSERT(!black.valid_trace_target(entity.console), "Its own ICE cannot attack its deployer through countertrace either")
	entity.console.intrusion.breach.finish()

/// Feedback is delivered only after a valid hostile program. Leaving cancels
/// both digital damage and body damage; shields mitigate both effects.
/datum/unit_test/netrun_black_ice_feedback/Run()
	var/datum/netrun_fortress_scene/scene = allocate(/datum/netrun_fortress_scene, run_loc_floor_bottom_left)
	var/mob/living/carbon/human/body = allocate(/mob/living/carbon/human)
	var/mob/camera/netrun_entity/entity = allocate(/mob/camera/netrun_entity, run_loc_floor_bottom_left, scene.node_a)
	entity.dive_link.attach(body, scene.node_a)
	var/datum/netrun_ice/black = allocate(/datum/netrun_ice, scene.node_a, NETRUN_ICE_BLACK)
	var/datum/netrun_program/program = SSnetrun.get_program("assault")
	var/before = body.getOrganLoss(ORGAN_SLOT_BRAIN)
	TEST_ASSERT(black.begin_program(program, entity), "A hostile ICE can prepare its normal program")
	entity.apply_shield(50, 10 SECONDS)
	black.attack_at = world.time
	black.resolve_program()
	TEST_ASSERT_EQUAL(body.getOrganLoss(ORGAN_SLOT_BRAIN) - before, 3, "A 50 percent shield also halves feedback")
	black.next_attack = 0
	black.program_cd.Cut()
	TEST_ASSERT(black.begin_program(program, entity), "Another attack is announced independently")
	before = body.getOrganLoss(ORGAN_SLOT_BRAIN)
	entity.leave_node()
	black.attack_at = world.time
	black.resolve_program()
	TEST_ASSERT_EQUAL(body.getOrganLoss(ORGAN_SLOT_BRAIN), before, "Leaving the node prevents physical feedback")
	TEST_ASSERT_NULL(black.pending_program, "An invalid delivery cancels its prepared program")
	entity.release_body()

/// Contraband is not a free generic command: it needs a real executable and
/// ROOT, then deploys one illegal agent and reports an authoritative incident.
/datum/unit_test/netrun_black_ice_deployment/Run()
	var/datum/netrun_fortress_scene/scene = allocate(/datum/netrun_fortress_scene, run_loc_floor_bottom_left)
	var/mob/camera/netrun_entity/entity = allocate(/mob/camera/netrun_entity, run_loc_floor_bottom_left, scene.node_a)
	var/datum/netrun_console/console = entity.console
	console.operator = entity
	var/datum/netrun_command/deploy = SSnetrun.get_command("black_ice")
	TEST_ASSERT(!deploy.visible_to(console), "Contraband actions are hidden without their executable")
	TEST_ASSERT(!console.run_command(scene.node_a, "black_ice"), "A bare process cannot dispatch illegal protection")
	var/datum/netrun_daemon/definition = SSnetrun.get_daemon("black_ice")
	var/datum/netrun_file/file = definition.create_file()
	TEST_ASSERT(console.store_file(file), "The real contraband executable fits in local memory")
	TEST_ASSERT(deploy.visible_to(console), "Owning its executable reveals the action")
	console.next_command = 0
	TEST_ASSERT(!console.run_command(scene.node_a, "black_ice"), "The executable cannot replace ROOT authority")
	console.access_session.node_access[scene.node_a.address] = NETRUN_ACCESS_ROOT
	console.next_command = 0
	TEST_ASSERT(console.run_command(scene.node_a, "black_ice"), "An authorized operator can deliver the deploy command")
	var/datum/netrun_request/command/packet = netrun_operation_packet(console, /datum/netrun_request/command)
	TEST_ASSERT_NOTNULL(packet, "Deployment owns its ordinary routed command packet")
	TEST_ASSERT(packet.deliver(), "The deploy packet must pass live command authority checks")
	var/datum/netrun_ice/deployed
	for(var/datum/netrun_ice/ice as anything in scene.node_a.netrun_ice)
		if(ice.kind == NETRUN_ICE_BLACK)
			deployed = ice
	TEST_ASSERT_NOTNULL(deployed, "Delivery creates the declared agent profile")
	TEST_ASSERT_EQUAL(deployed.deployer_ref.resolve(), console, "The deployment records its actual principal")
	TEST_ASSERT(!deployed.get_netrun_combatant().protected_by_station(), "Station law does not protect illegal ICE")
	TEST_ASSERT(console.next_black_ice > world.time, "A deployment has a lasting per-client cooldown")
	console.delete_local_file(file)
	TEST_ASSERT(!deploy.visible_to(console), "Detaching the executable removes its capability")

/// An address is not a microphone. The optional physical transceiver is checked
/// at transmission, while the entity's internal bus remains independent.
/datum/unit_test/netrun_entity_audio_capability/Run()
	var/datum/netrun_fortress_scene/scene = allocate(/datum/netrun_fortress_scene, run_loc_floor_bottom_left)
	var/mob/camera/netrun_entity/entity = allocate(/mob/camera/netrun_entity, run_loc_floor_bottom_left, scene.node_a)
	TEST_ASSERT(!(SEND_SIGNAL(entity, COMSIG_NETRUN_ENTITY_SPEAK, "test", list())), "A terminal or APC cannot speak merely because it has a network node")
	var/obj/item/radio/intercom/intercom = allocate(/obj/item/radio/intercom, run_loc_floor_bottom_left)
	intercom.on = TRUE
	intercom.listening = TRUE
	intercom.broadcasting = FALSE
	var/datum/component/netrun_node/node = intercom.GetComponent(/datum/component/netrun_node)
	entity.enter_node(node)
	TEST_ASSERT(SEND_SIGNAL(entity, COMSIG_NETRUN_ENTITY_SPEAK, "test", list()), "An operational transceiver permits local voice")
	intercom.listening = FALSE
	TEST_ASSERT(!(SEND_SIGNAL(entity, COMSIG_NETRUN_ENTITY_SPEAK, "test", list())), "Turning off the native speaker prevents output")
	intercom.listening = TRUE
	TEST_ASSERT(entity.remove_module("audio"), "Speech is an optional entity capability")
	TEST_ASSERT(!(SEND_SIGNAL(entity, COMSIG_NETRUN_ENTITY_SPEAK, "test", list())), "Removing speech unsubscribes its reaction")

/// Offline markers retain an observation, while command authority and delivery
/// keep using the real endpoint. A probe deliberately refreshes the observation.
/datum/unit_test/netrun_offline_location_probe/Run()
	var/datum/netrun_fortress_scene/scene = allocate(/datum/netrun_fortress_scene, run_loc_floor_bottom_left)
	var/datum/component/netrun_node/node = scene.node_a
	var/mob/camera/netrun_entity/entity = allocate(/mob/camera/netrun_entity, run_loc_floor_bottom_left, node)
	var/datum/netrun_console/console = entity.console
	var/turf/initial_position = node.observe_location(TRUE)
	node.offline_until = world.time + 1 MINUTES
	var/atom/movable/machine = node.parent
	machine.forceMove(get_step(initial_position, EAST))
	TEST_ASSERT(node.physical_turf() != initial_position, "The physical endpoint must really move while disconnected")
	var/list/entry = node.ui_entry(console)
	TEST_ASSERT_EQUAL(entry["x"], initial_position.x, "Passive map reads retain last known X")
	TEST_ASSERT_EQUAL(entry["y"], initial_position.y, "Passive map reads retain last known Y")
	var/datum/netrun_command/probe = SSnetrun.get_command("probe_location")
	probe.execute(node, console)
	entry = node.ui_entry(console)
	TEST_ASSERT_EQUAL(entry["x"], node.physical_turf().x, "An explicit probe refreshes X without enabling the endpoint")
	TEST_ASSERT(!node.is_online(), "Probing cannot reconnect an offline endpoint")
